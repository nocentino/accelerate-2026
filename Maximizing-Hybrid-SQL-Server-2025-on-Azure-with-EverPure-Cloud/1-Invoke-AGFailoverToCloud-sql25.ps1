#############################################################################
# AG Unplanned Failover to Azure Cloud + On-Prem Reseed - Accelerate Demo
# Using SQL Server 2022+ T-SQL Snapshot Backup + Pure Storage FlashArray
#
# Scenario:
#    An unplanned outage has taken down the on-prem site (aen-sql-25-c and
#    aen-sql-25-d).  We force failover AG1 to the Azure EverPure Cloud replica
#    (aen-sql-25-e / gso-cbs-azure.fsa.lab) to restore service.
#
#    Once the on-prem site recovers, we reseed both on-prem replicas from a
#    PGroup snapshot taken on the Azure array and replicated back to the
#    on-prem arrays, using the T-SQL Snapshot Backup feature to generate the
#    .bkm metadata file needed to rejoin the AG.
#
#    Part 1 - Forced failover to aen-sql-25-e (Azure EverPure Cloud)
#    Part 2 - Show AG status; observe on-prem replicas need reseeding
#    Part 3 - On-prem site recovers; freeze the cloud primary and snapshot it,
#             replicating back to both on-prem arrays
#    Part 4 - Reseed aen-sql-25-c from the replicated Azure snapshot
#    Part 5 - Reseed aen-sql-25-d from the replicated Azure snapshot
#    Part 6 - Planned failback to on-prem (aen-sql-25-c): convert to synchronous
#             commit, fail over, then return the cloud replica to async
#
# Prerequisites:
#    1. dbatools and PureStoragePowerShellSDK2 installed on this machine.
#    2. Connect-DbaInstance -NonPooledConnection keeps the freeze session alive.
#    3. Protection Group 'aen-sql-25-e-pg' on gso-cbs-azure.fsa.lab containing
#       gso-an-win-1-SQLDATA1 and gso-an-win-1-SQLLOG1, with async replication
#       configured back to BOTH sn1-x90r2-f06-33 and sn1-x90r2-f06-27.
#    4. AG1 already has all three instances configured as replicas.
#    5. All SQL instances have network access to s200.fsa.lab.
#
# Usage Notes:
#    This script is built to run end-to-end in a single execution (F5, or
#    .\Invoke-AGFailoverToCloud-sql25.ps1). $ErrorActionPreference = 'Stop'
#    halts the run on the first failure so you never continue past a failed
#    failover/snapshot. The sections remain ordered and labeled, so you can
#    still step through them interactively if you prefer.
#
#    PART 1 is destructive: FORCE_FAILOVER_ALLOW_DATA_LOSS can drop in-flight
#    transactions. Only run against a site you intend to fail over.
#
# Disclaimer:
#    This example script is provided AS-IS and is meant to be a building
#    block to be adapted to fit an individual organization's infrastructure.
#
#    THIS IS A SAMPLE SCRIPT WE USE FOR DEMOS! PLEASE do not save your
#    passwords in cleartext here. Use NTFS secured, encrypted files or
#    whatever else -- never cleartext!
#############################################################################

Import-Module dbatools
Import-Module PureStoragePowerShellSDK2

# Stop on the first error so an unattended one-shot run never continues past a
# failed step (e.g. a failed snapshot while the database is still frozen).
$ErrorActionPreference = 'Stop'

function Wait-Spacebar {
    param([string]$Summary, [string]$Highlight)
    Write-Host "`n$('─' * 62)" -ForegroundColor DarkCyan
    Write-Host "  WHAT JUST HAPPENED" -ForegroundColor White
    Write-Host "  $Summary" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  KEY POINT" -ForegroundColor White
    Write-Host "  $Highlight" -ForegroundColor Yellow
    Write-Host "$('─' * 62)" -ForegroundColor DarkCyan
    Write-Host "`n  Press SPACEBAR to continue..." -ForegroundColor DarkGray
    do { $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } while ($key.Character -ne ' ')
    Write-Host ""
}


#region --- Variables ---
# Variables are named by machine identity so the SAME box uses the SAME name in
# both this script and Invoke-AGSeedFromSnapshot-sql25.ps1:
#   Cloud   = aen-sql-25-e (Azure)   OnPrem1 = aen-sql-25-c   OnPrem2 = aen-sql-25-d
# In THIS failover the cloud (aen-sql-25-e) is the new primary / snapshot source.

# SQL Server instances
$CloudSqlServer   = 'aen-sql-25-e'   # Azure EverPure Cloud - becomes new primary after failover
$OnPremSqlServer1 = 'aen-sql-25-c'   # On-prem replica 1 - needs reseed after recovery
$OnPremSqlServer2 = 'aen-sql-25-d'   # On-prem replica 2 - needs reseed after recovery
$AgName           = 'ag1'
$DbName           = 'TPCC-4T'   # same DB the companion seed script (Invoke-AGSeedFromSnapshot-sql25.ps1) uses

# FlashArray endpoints
$CloudArrayName   = 'gso-cbs-azure.fsa.lab'                              # Azure EverPure Cloud (new primary array)
$OnPremArrayName1 = 'sn1-x90r2-f06-33.fsa.lab'  # On-prem array for aen-sql-25-c
$OnPremArrayName2 = 'sn1-x90r2-f06-27.fsa.lab'  # On-prem array for aen-sql-25-d

# Protection Group on the Azure array (new source for replication back to on-prem)
$CloudPGroupName    = 'aen-sql-25-e-pg'
# Replicated PGroup names as seen on each on-prem array: [source_array_name]:[pg_name]
# $CloudArrayFaName is resolved at runtime from $FlashArrayCloud.ArrayName
$OnPremTargetPGroup1 = $null  # set after connecting: "$CloudArrayFaName:$CloudPGroupName"
$OnPremTargetPGroup2 = $null  # set after connecting: "$CloudArrayFaName:$CloudPGroupName"

# FlashArray volume names on the Azure array (new primary source)
$CloudFaDataVol = 'gso-an-win-1-SQLDATA1'  # Azure data vol (20 TB,  Disk 1)
$CloudFaLogVol  = 'gso-an-win-1-SQLLOG1'   # Azure log vol  (512 GB, Disk 2)

# FlashArray volume names on-prem (overwrite targets during reseed)
$OnPremFaDataVol1 = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-0a463e4a'  # aen-sql-25-c data vol (20 TB,  Hard disk 4, D:)
$OnPremFaLogVol1  = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-441252f7'  # aen-sql-25-c log vol  (512 GB, Hard disk 5, L:)
$OnPremFaDataVol2 = 'vvol-aen-sql-25-d-a9ecd10d-vg/Data-769a59a9'  # aen-sql-25-d data vol (20 TB,  D:)
$OnPremFaLogVol2  = 'vvol-aen-sql-25-d-a9ecd10d-vg/Data-3f854849'  # aen-sql-25-d log vol  (512 GB, L:)

# Windows disk serial numbers on the on-prem servers (from Get-Disk)
$OnPremDataDiskSN1 = '6000c29f3954ac54e78cfddf283aaae7'  # aen-sql-25-c D: data disk (20 TB,  Disk 3)
$OnPremLogDiskSN1  = '6000c29af911842f6dd25fd7bd55a8bc'  # aen-sql-25-c L: log disk  (512 GB, Disk 5)
$OnPremDataDiskSN2 = '6000c292e84613da877cc244d52bd78a'  # aen-sql-25-d D: data disk (20 TB,  Disk 3)
$OnPremLogDiskSN2  = '6000c2961b1c81cd6cd067157dcb0836'  # aen-sql-25-d L: log disk  (512 GB, Disk 5)

# S3 backup endpoint (FlashBlade s200.fsa.lab)
$S3CredentialName = 's3://s200.fsa.lab'
$S3BackupPath     = 's3://s200.fsa.lab/aen-sql-backups'

#endregion


##############################################################################################################################
#
#   PART 1 — Forced Failover to Azure Cloud (aen-sql-25-e)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 1 — Forced Failover to Azure Cloud (aen-sql-25-e)  ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n  [!] The on-prem site is down. Forcing AG [$AgName] over to the Azure replica." -ForegroundColor Red
Write-Host   "      FORCE_FAILOVER_ALLOW_DATA_LOSS — transactions not yet hardened to $CloudSqlServer may be lost." -ForegroundColor Red

# ── [1] Connect to the new primary (cloud) ──────────────────────────────────────
Write-Host "`n  [1] Connecting to $CloudSqlServer (new primary)..." -ForegroundColor Yellow
$SqlCredential    = Import-Clixml -Path "$HOME\SA_Cred.xml"
$SqlInstanceCloud = Connect-DbaInstance -SqlInstance $CloudSqlServer -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection
Write-Host "      ✓ Connected to $CloudSqlServer" -ForegroundColor Green



# ── [2] Force the AG to failover to the cloud replica ───────────────────────────
Write-Host "`n  [2] Forcing AG [$AgName] failover to $CloudSqlServer..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query
Write-Host "      ✓ Failover complete — $CloudSqlServer is the new primary" -ForegroundColor Green

Wait-Spacebar `
    -Summary  "Issued FORCE_FAILOVER_ALLOW_DATA_LOSS on $CloudSqlServer. The Azure EverPure Cloud replica is now the AG primary. Transactions not yet replicated from the failed on-prem site are permanently lost — this is the accepted cost of an unplanned failover." `
    -Highlight "SQL Server requires you to name the risk explicitly in T-SQL: FORCE_FAILOVER_ALLOW_DATA_LOSS. Without Pure Storage snapshot-based reseed, recovering the on-prem secondaries would require a full database backup stream. We are about to show a better way."


##############################################################################################################################
#
#   PART 2 — Review AG Status (on-prem replicas disconnected, need reseed)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 2 — Review AG Status                               ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n  $CloudSqlServer is the new primary. $OnPremSqlServer1 and $OnPremSqlServer2 will show as" -ForegroundColor DarkGray
Write-Host   "  CONNECTED / NOT SYNCHRONIZING and must be reseeded before they can rejoin." -ForegroundColor DarkGray

# ── [1] Show replica status ─────────────────────────────────────────────────────
Write-Host "`n  [1] AG replica status..." -ForegroundColor Yellow
$SqlInstanceCloud = Connect-DbaInstance -SqlInstance $CloudSqlServer -TrustServerCertificate -nonPooledConnection 
Get-DbaAgReplica -SqlInstance $SqlInstanceCloud | Select-Object Name, Role, ConnectionState, RollupSynchronizationState | Format-Table

Write-Host "      ✓ Both on-prem replicas ($OnPremSqlServer1 and $OnPremSqlServer2) are CONNECTED  / NOT SYNCHRONIZING — they fell behind the forced failover point and cannot self-heal." -ForegroundColor DarkGray

Wait-Spacebar `
    -Summary  "Queried replica and database sync states from the new primary $CloudSqlServer. Both on-prem replicas ($OnPremSqlServer1 and $OnPremSqlServer2) are CONNECTED / NOT SYNCHRONIZING — they fell behind the forced failover point and cannot self-heal." `
    -Highlight "After a forced failover, secondaries not at the same LSN as the new primary are permanently out of sync. The only path back is a reseed. Pure Storage makes that a storage-speed operation regardless of database size — we are about to prove it."


##############################################################################################################################
#
#   PART 3 — On-prem site recovers; freeze + snapshot the cloud primary
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 3 — Connect, Freeze, Snapshot (cloud primary)      ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n  The on-prem site has now RECOVERED. With $CloudSqlServer serving as primary," -ForegroundColor DarkGray
Write-Host   "  reconnect to all three sites and snapshot the cloud to reseed the on-prem replicas." -ForegroundColor DarkGray

# ── [1] Connect to all three FlashArrays ────────────────────────────────────────
Write-Host "`n  [1] Connecting to FlashArrays..." -ForegroundColor Yellow
$Credential        = Import-CliXml -Path "$HOME\FA_Cred.xml"
$FlashArrayCloud   = Connect-Pfa2Array -EndPoint $CloudArrayName   -Credential $Credential -IgnoreCertificateError
$FlashArrayOnPrem1 = Connect-Pfa2Array -EndPoint $OnPremArrayName1 -Credential $Credential -IgnoreCertificateError
$FlashArrayOnPrem2 = Connect-Pfa2Array -EndPoint $OnPremArrayName2 -Credential $Credential -IgnoreCertificateError
Write-Host "      ✓ Connected to $CloudArrayName, $OnPremArrayName1, $OnPremArrayName2" -ForegroundColor Green



# ── [2] Resolve replicated PGroup names on each on-prem array ───────────────────
# Use Get-Pfa2Array to get the Purity internal array name — this is what the
# on-prem arrays record as the replication source in transfer snapshot names.
# $FlashArrayCloud.ArrayName returns the connection endpoint (FQDN), which does
# NOT match the prefix the on-prem arrays put on replicated snapshots.
Write-Host "`n  [2] Resolving replicated PGroup names..." -ForegroundColor Yellow
$CloudArrayFaName    = (Get-Pfa2Array -Array $FlashArrayCloud).Name
$OnPremTargetPGroup1 = "$($CloudArrayFaName):$CloudPGroupName"
$OnPremTargetPGroup2 = "$($CloudArrayFaName):$CloudPGroupName"
Write-Host "      ✓ Cloud array (Purity name) : $CloudArrayFaName" -ForegroundColor Green
Write-Host "        Target PGroup (-c)        : $OnPremTargetPGroup1" -ForegroundColor White
Write-Host "        Target PGroup (-d)        : $OnPremTargetPGroup2" -ForegroundColor White



# ── [3] Persistent connections to all SQL instances ─────────────────────────────
# $SqlInstanceCloud is refreshed here with a NEW NonPooledConnection so that the
# SUSPEND_FOR_SNAPSHOT_BACKUP (step 4) and the BACKUP METADATA_ONLY (step 6) share
# the exact same SQL session. SUSPEND is session-scoped — if the connection from
# Part 1 timed out and reconnected internally, step 6 would land on a different
# session and see "database is not suspended".
Write-Host "`n  [3] Connecting to all SQL instances..." -ForegroundColor Yellow
$SqlInstanceCloud   = Connect-DbaInstance -SqlInstance $CloudSqlServer   -TrustServerCertificate -NonPooledConnection
$SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $OnPremSqlServer1 -TrustServerCertificate -NonPooledConnection
$SqlInstanceOnPrem2 = Connect-DbaInstance -SqlInstance $OnPremSqlServer2 -TrustServerCertificate -NonPooledConnection
# Local admin credential for workgroup WinRM sessions
$LocalCredential = Import-Clixml -Path "$HOME\anocentino_Cred.xml"
$OnPremSession1 = New-PSSession -ComputerName $OnPremSqlServer1 
$OnPremSession2 = New-PSSession -ComputerName $OnPremSqlServer2
Write-Host "      ✓ Connected to $CloudSqlServer, $OnPremSqlServer1, $OnPremSqlServer2" -ForegroundColor Green



# ── [4] Freeze write I/O on the new primary (cloud) ─────────────────────────────
Write-Host "`n  [4] Freezing write I/O on $CloudSqlServer..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Query $Query
Write-Host "      ✓ [$DbName] write I/O suspended — snapshot window is open" -ForegroundColor Green



# ── [5] Take PGroup snapshot on the cloud array and replicate to both on-prem arrays ──
Write-Host "`n  [5] Taking PGroup snapshot on $CloudArrayName..." -ForegroundColor Yellow
Write-Host "      Targeting $OnPremArrayName1 and $OnPremArrayName2" -ForegroundColor DarkGray
$CloudSnapshot = New-Pfa2ProtectionGroupSnapshot -Array $FlashArrayCloud `
    -SourceName $CloudPGroupName `
    -ForReplication $true `
    -ReplicateNow $true
Write-Host "      ✓ Snapshot created  : $($CloudSnapshot.Name)" -ForegroundColor Green



# ── [6] Release freeze — metadata backup to S3 ──────────────────────────────────
Write-Host "`n  [6] Releasing write I/O freeze and writing metadata backup to S3..." -ForegroundColor Yellow
$BackupUrl = "$S3BackupPath/$DbName-cloud-$(Get-Date -Format FileDateTime).bkm"
$Query = @"
BACKUP DATABASE [$DbName]
    TO URL = '$BackupUrl'
    WITH METADATA_ONLY,
         MEDIADESCRIPTION = '$($CloudSnapshot.Name)|$($FlashArrayCloud.ArrayName)'
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Query $Query 
Write-Host "      ✓ [$DbName] is writeable again — freeze released" -ForegroundColor Green
Write-Host "        Backup URL  : $BackupUrl" -ForegroundColor White


Write-Host "`n  ── Cloud snapshot phase complete ────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($CloudSnapshot.Name)" -ForegroundColor White
Write-Host "     Backup   : $BackupUrl" -ForegroundColor White
Write-Host "     Status   : Replicating asynchronously to both on-prem arrays" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Reconnected to all instances. Froze $CloudSqlServer, took a PGroup snapshot on $CloudArrayName, then released the freeze with a METADATA_ONLY .bkm backup to S3. The snapshot is replicating to both on-prem arrays simultaneously (each on-prem reseed takes its own bridging log backup in Part 4/5)." `
    -Highlight "Replication direction has reversed: Azure EverPure Cloud is now the snapshot SOURCE and both on-prem arrays are the targets. The same Pure Storage + T-SQL Snapshot Backup workflow operates identically cloud-to-on-prem and on-prem-to-cloud."


##############################################################################################################################
#
#   PART 4 — Reseed aen-sql-25-c  (sn1-x90r2-f06-33)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 4 — Reseed aen-sql-25-c  (sn1-x90r2-f06-33)        ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [A] Wait for replication to on-prem array 1 ─────────────────────────────────
Write-Host "`n  [A] Waiting for snapshot to replicate to $OnPremArrayName1..." -ForegroundColor Yellow
Write-Host "      Searching for PGroup : $OnPremTargetPGroup1" -ForegroundColor DarkGray
Write-Host "      Snapshot suffix      : $($CloudSnapshot.Suffix)" -ForegroundColor DarkGray
$OnPremTargetSnapshot1 = $null
$WaitDeadline1 = (Get-Date).AddMinutes(30)
do {
    if ((Get-Date) -gt $WaitDeadline1) { throw "Timed out waiting for snapshot transfer to appear on $OnPremArrayName1. Check that the PGroup '$OnPremTargetPGroup1' is a configured replication target and that the FlashArray name resolved correctly." }
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    # Wildcard suffix on -Name so it matches all snapshot transfers from this PGroup.
    $OnPremTargetSnapshot1 = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem1 -Name "$OnPremTargetPGroup1*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$OnPremTargetPGroup1.$($CloudSnapshot.Suffix)" }

    if ($OnPremTargetSnapshot1) {
        Write-Host "      Progress: $([math]::Round($OnPremTargetSnapshot1.Progress * 100))%" -ForegroundColor DarkGray
    } else {
        # Show all visible transfers from any cloud PGroup so we can spot name mismatches
        $allTransfers = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem1 -ErrorAction SilentlyContinue
        if ($allTransfers) {
            Write-Host "      Available transfers on $OnPremArrayName1 (check for name mismatch):" -ForegroundColor DarkGray
            $allTransfers | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        } else {
            Write-Host "      Waiting for transfer to appear on $OnPremArrayName1..." -ForegroundColor DarkGray
        }
    }
} while ([string]::IsNullOrEmpty($OnPremTargetSnapshot1.Completed) -or ($OnPremTargetSnapshot1.Progress -ne 1.0))
Write-Host "      ✓ Snapshot available on $OnPremArrayName1 at $($OnPremTargetSnapshot1.Completed)" -ForegroundColor Green



# ── [A1] Detach database from AG on this secondary before touching disks ──────────────
# Must happen while the original files are still accessible. SQL Server will
# return error 21 (device not ready) if SET HADR OFF runs after the disks are
# overwritten with snapshot data.
Write-Host "`n  [A1] Removing [$DbName] from AG and dropping on $OnPremSqlServer1 (secondary only)..." -ForegroundColor Yellow
# SET HADR OFF works whether the database is ONLINE or RESTORING (common after a forced failover).
# DROP DATABASE unconditionally releases all file handles regardless of database state —
# safer than SET OFFLINE, which fails on a RESTORING database.
$Query = "ALTER DATABASE [$DbName] SET HADR OFF"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
$Query = "DROP DATABASE [$DbName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ [$DbName] dropped on $OnPremSqlServer1 — file handles released, safe to overwrite disks" -ForegroundColor Green



# ── [B] Offline data and log disks on aen-sql-25-c ──────────────────────────────
Write-Host "`n  [B] Offlining data and log disks on $OnPremSqlServer1..." -ForegroundColor Yellow
Invoke-Command -Session $OnPremSession1 -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremDataDiskSN1 } | Set-Disk -IsOffline $True
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremLogDiskSN1  } | Set-Disk -IsOffline $True
}
Write-Host "      ✓ Data and log disks are offline on $OnPremSqlServer1" -ForegroundColor Green



# ── [C] Overwrite FA volumes from replicated snapshot ───────────────────────────
Write-Host "`n  [C] Overwriting $OnPremSqlServer1 data and log volumes from cloud snapshot..." -ForegroundColor Yellow
New-Pfa2Volume -Array $FlashArrayOnPrem1 `
    -Name $OnPremFaDataVol1 `
    -SourceName ($OnPremTargetSnapshot1.Name + ".$CloudFaDataVol") `
    -Overwrite $true

New-Pfa2Volume -Array $FlashArrayOnPrem1 `
    -Name $OnPremFaLogVol1 `
    -SourceName ($OnPremTargetSnapshot1.Name + ".$CloudFaLogVol") `
    -Overwrite $true
Write-Host "      ✓ Volumes overwritten — data and log disks contain snapshot data" -ForegroundColor Green



# ── [D] Online data and log disks on aen-sql-25-c ───────────────────────────────
Write-Host "`n  [D] Bringing data and log disks online on $OnPremSqlServer1..." -ForegroundColor Yellow
Invoke-Command -Session $OnPremSession1 -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremDataDiskSN1 } | Set-Disk -IsOffline $False
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremLogDiskSN1  } | Set-Disk -IsOffline $False
}
Write-Host "      ✓ Data and log disks are online on $OnPremSqlServer1" -ForegroundColor Green



# ── [E] Restore metadata backup (NORECOVERY) ────────────────────────────────────
Write-Host "`n  [E] Restoring metadata backup on $OnPremSqlServer1 (NORECOVERY)..." -ForegroundColor Yellow
# No REPLACE needed — database was dropped in [A1] so there is nothing to overwrite.
$Query = "RESTORE DATABASE [$DbName] FROM URL = '$BackupUrl' WITH METADATA_ONLY, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ [$DbName] is in RESTORING state on $OnPremSqlServer1" -ForegroundColor Green


# ── [E1] Take bridging log backup on the cloud primary ───────────────────────────────
Write-Host "`n  [E1] Taking bridging log backup on $CloudSqlServer..." -ForegroundColor Yellow
$LogBackupUrl = "$S3BackupPath/$DbName-cloud-seed-$(Get-Date -Format FileDateTime).trn"
$Query = "BACKUP LOG [$DbName] TO URL = '$LogBackupUrl'"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query
Write-Host "      ✓ Log backup written : $LogBackupUrl" -ForegroundColor Green


# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $OnPremSqlServer1..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG rejoin on $OnPremSqlServer1" -ForegroundColor Green



# ── [G] Rejoin secondary to AG ──────────────────────────────────────────────────
Write-Host "`n  [G] Rejoining $OnPremSqlServer1 to AG [$AgName]..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ $OnPremSqlServer1 rejoined [$AgName] as a synchronizing replica" -ForegroundColor Green



# ── [H] Verify sync state on aen-sql-25-c ───────────────────────────────────────
Write-Host "`n  [H] Verifying sync state on $OnPremSqlServer1..." -ForegroundColor Yellow
$SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $OnPremSqlServer1 -TrustServerCertificate -NonPooledConnection
Get-DbaAgReplica -SqlInstance $SqlInstanceOnPrem1 -Replica $OnPremSqlServer1 | Select-Object Name, Role, ConnectionState, RollupSynchronizationState | Format-Table


Write-Host "  ── Part 4 complete (aen-sql-25-c reseeded) ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($OnPremTargetSnapshot1.Name)" -ForegroundColor White
Write-Host "     Log      : $LogBackupUrl" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Waited for the Azure snapshot to arrive on $OnPremArrayName1. Offlined $OnPremSqlServer1 disks, overwrote the volumes from the replicated snapshot, onlined the disks, restored the .bkm metadata file and bridging log, then rejoined $OnPremSqlServer1 to $AgName as a synchronizing replica." `
    -Highlight "A 4 TB replica reseeded from a flash copy entirely in storage — no network backup transfer, no SQL Server I/O for the data files. The METADATA_ONLY restore just registers the database headers so SQL Server can rejoin the AG."


##############################################################################################################################
#
#   PART 5 — Reseed aen-sql-25-d  (sn1-x90r2-f06-27)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 5 — Reseed aen-sql-25-d  (sn1-x90r2-f06-27)        ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [A] Wait for replication to on-prem array 2 ─────────────────────────────────
Write-Host "`n  [A] Waiting for snapshot to replicate to $OnPremArrayName2..." -ForegroundColor Yellow
Write-Host "      Searching for PGroup : $OnPremTargetPGroup2" -ForegroundColor DarkGray
Write-Host "      Snapshot suffix      : $($CloudSnapshot.Suffix)" -ForegroundColor DarkGray
$OnPremTargetSnapshot2 = $null
$WaitDeadline2 = (Get-Date).AddMinutes(30)
do {
    if ((Get-Date) -gt $WaitDeadline2) { throw "Timed out waiting for snapshot transfer to appear on $OnPremArrayName2. Check that the PGroup '$OnPremTargetPGroup2' is a configured replication target and that the FlashArray name resolved correctly." }
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    # Wildcard suffix on -Name so it matches all snapshot transfers from this PGroup.
    $OnPremTargetSnapshot2 = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem2 -Name "$OnPremTargetPGroup2*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$OnPremTargetPGroup2.$($CloudSnapshot.Suffix)" }

    if ($OnPremTargetSnapshot2) {
        Write-Host "      Progress: $([math]::Round($OnPremTargetSnapshot2.Progress * 100))%" -ForegroundColor DarkGray
    } else {
        # Show all visible transfers from any cloud PGroup so we can spot name mismatches
        $allTransfers = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem2 -ErrorAction SilentlyContinue
        if ($allTransfers) {
            Write-Host "      Available transfers on $OnPremArrayName2 (check for name mismatch):" -ForegroundColor DarkGray
            $allTransfers | Select-Object -ExpandProperty Name | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        } else {
            Write-Host "      Waiting for transfer to appear on $OnPremArrayName2..." -ForegroundColor DarkGray
        }
    }
} while ([string]::IsNullOrEmpty($OnPremTargetSnapshot2.Completed) -or ($OnPremTargetSnapshot2.Progress -ne 1.0))
Write-Host "      ✓ Snapshot available on $OnPremArrayName2 at $($OnPremTargetSnapshot2.Completed)" -ForegroundColor Green



# ── [A1] Detach database from AG on this secondary before touching disks ──────────────
# Must happen while the original files are still accessible. SQL Server will
# return error 21 (device not ready) if SET HADR OFF runs after the disks are
# overwritten with snapshot data.
Write-Host "`n  [A1] Removing [$DbName] from AG and dropping on $OnPremSqlServer2 (secondary only)..." -ForegroundColor Yellow
# SET HADR OFF works whether the database is ONLINE or RESTORING (common after a forced failover).
# DROP DATABASE unconditionally releases all file handles regardless of database state —
# safer than SET OFFLINE, which fails on a RESTORING database.
$Query = "ALTER DATABASE [$DbName] SET HADR OFF"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query 
$Query = "DROP DATABASE [$DbName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query 
Write-Host "      ✓ [$DbName] dropped on $OnPremSqlServer2 — file handles released, safe to overwrite disks" -ForegroundColor Green



# ── [B] Offline data and log disks on aen-sql-25-d ──────────────────────────────
Write-Host "`n  [B] Offlining data and log disks on $OnPremSqlServer2..." -ForegroundColor Yellow
Invoke-Command -Session $OnPremSession2 -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremDataDiskSN2 } | Set-Disk -IsOffline $True
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremLogDiskSN2  } | Set-Disk -IsOffline $True
}
Write-Host "      ✓ Data and log disks are offline on $OnPremSqlServer2" -ForegroundColor Green



# ── [C] Overwrite FA volumes from replicated snapshot ───────────────────────────
Write-Host "`n  [C] Overwriting $OnPremSqlServer2 data and log volumes from cloud snapshot..." -ForegroundColor Yellow
New-Pfa2Volume -Array $FlashArrayOnPrem2 `
    -Name $OnPremFaDataVol2 `
    -SourceName ($OnPremTargetSnapshot2.Name + ".$CloudFaDataVol") `
    -Overwrite $true

New-Pfa2Volume -Array $FlashArrayOnPrem2 `
    -Name $OnPremFaLogVol2 `
    -SourceName ($OnPremTargetSnapshot2.Name + ".$CloudFaLogVol") `
    -Overwrite $true
Write-Host "      ✓ Volumes overwritten — data and log disks contain snapshot data" -ForegroundColor Green



# ── [D] Online data and log disks on aen-sql-25-d ───────────────────────────────
Write-Host "`n  [D] Bringing data and log disks online on $OnPremSqlServer2..." -ForegroundColor Yellow
Invoke-Command -Session $OnPremSession2 -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremDataDiskSN2 } | Set-Disk -IsOffline $False
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:OnPremLogDiskSN2  } | Set-Disk -IsOffline $False
}
Write-Host "      ✓ Data and log disks are online on $OnPremSqlServer2" -ForegroundColor Green



# ── [E] Restore metadata backup (NORECOVERY) ────────────────────────────────────
Write-Host "`n  [E] Restoring metadata backup on $OnPremSqlServer2 (NORECOVERY)..." -ForegroundColor Yellow
# No REPLACE needed — database was dropped in [A1] so there is nothing to overwrite.
$Query = "RESTORE DATABASE [$DbName] FROM URL = '$BackupUrl' WITH METADATA_ONLY, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query 
Write-Host "      ✓ [$DbName] is in RESTORING state on $OnPremSqlServer2" -ForegroundColor Green



# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $OnPremSqlServer2..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query 
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG rejoin on $OnPremSqlServer2" -ForegroundColor Green



# ── [G] Rejoin secondary to AG ──────────────────────────────────────────────────
Write-Host "`n  [G] Rejoining $OnPremSqlServer2 to AG [$AgName]..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query 
Write-Host "      ✓ $OnPremSqlServer2 rejoined [$AgName] as a synchronizing replica" -ForegroundColor Green



# ── [H] Final AG status across all three replicas ───────────────────────────────
# Query from the primary (cloud) — secondaries only see their own local state and
# report other replicas as Unknown.
Write-Host "`n  [H] Final AG status across all three replicas..." -ForegroundColor Yellow
$sqlinstanceCloud = Connect-DbaInstance -SqlInstance $CloudSqlServer -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection
Get-DbaAgReplica -SqlInstance $SqlInstanceCloud  | Select-Object Name, Role, ConnectionState, RollupSynchronizationState | Format-Table


Write-Host "  ── Part 5 complete (aen-sql-25-d reseeded) ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($OnPremTargetSnapshot2.Name)" -ForegroundColor White
Write-Host "     Log      : $LogBackupUrl" -ForegroundColor White

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Failover + reseed complete — AG healthy                 ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     New primary : $CloudSqlServer  (Azure EverPure Cloud)" -ForegroundColor White
Write-Host "     Reseeded    : $OnPremSqlServer1, $OnPremSqlServer2  (on-prem)" -ForegroundColor White
Write-Host "     Database    : [$DbName] in AG [$AgName]" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Both on-prem replicas ($OnPremSqlServer1 and $OnPremSqlServer2) are now synchronizing against the Azure primary $CloudSqlServer. A single Azure PGroup snapshot was used to reseed two independent on-prem targets in parallel." `
    -Highlight "From a total on-prem outage to a fully healthy 3-replica AG — no backup streams, no network data transfer of the database files, no dependency on the failed primary. This is EverPure Cloud Dedicated + T-SQL Snapshot Backup at any scale."


##############################################################################################################################
#
#   PART 6 — Planned Failback to On-Prem (aen-sql-25-c)
#
#   With all three replicas healthy again, fail the AG back to on-prem with a
#   zero-data-loss failover, by:
#     [1] Switch the cloud primary and the on-prem failback target to
#         SYNCHRONOUS_COMMIT (both ends must be sync for a safe failover).
#     [2] Wait for aen-sql-25-c to reach the SYNCHRONIZED state.
#     [3] Issue FORCE_FAILOVER_ALLOW_DATA_LOSS from aen-sql-25-c (becomes primary).
#         A clusterless AG (CLUSTER_TYPE = NONE) uses this syntax even for a planned
#         failover; it is safe because SYNCHRONIZED guarantees both LSNs match — no data lost.
#     [4] Return the cloud replica (aen-sql-25-e) to ASYNCHRONOUS_COMMIT so the
#         WAN link is no longer in the synchronous commit path.
#     [5] Resume data movement on the on-prem secondary and the cloud replica.
#     [6] Verify AG roles and sync state after failback.
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 6 — Planned Failback to On-Prem (aen-sql-25-c)     ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [1] Convert to synchronous commit (cloud primary + on-prem target) ──────────
# AVAILABILITY_MODE changes are issued on the CURRENT primary (the cloud replica).
Write-Host "`n  [1] Switching $CloudSqlServer and $OnPremSqlServer1 to SYNCHRONOUS_COMMIT..." -ForegroundColor Yellow
$Query = @"
ALTER AVAILABILITY GROUP [$AgName]
    MODIFY REPLICA ON N'$CloudSqlServer'   WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
ALTER AVAILABILITY GROUP [$AgName]
    MODIFY REPLICA ON N'$OnPremSqlServer1' WITH (AVAILABILITY_MODE = SYNCHRONOUS_COMMIT);
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query
Write-Host "      ✓ $CloudSqlServer and $OnPremSqlServer1 set to synchronous commit" -ForegroundColor Green



# ── [2] Wait for aen-sql-25-c to become SYNCHRONIZED ────────────────────────────
# Only a SYNCHRONIZED synchronous-commit secondary can accept a no-data-loss failover.
Write-Host "`n  [2] Waiting for $OnPremSqlServer1 to reach SYNCHRONIZED..." -ForegroundColor Yellow
$SyncQuery = @"
SELECT drs.synchronization_state_desc AS SyncState
FROM sys.dm_hadr_database_replica_states drs
JOIN sys.availability_replicas ar ON drs.replica_id = ar.replica_id
WHERE ar.replica_server_name = '$OnPremSqlServer1'
  AND drs.database_id = DB_ID('$DbName');
"@
do {
    Start-Sleep -Seconds 3
    $SyncState = (Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $SyncQuery).SyncState
    Write-Host "      $OnPremSqlServer1 sync state: $SyncState" -ForegroundColor DarkGray
} while ($SyncState -ne 'SYNCHRONIZED')
Write-Host "      ✓ $OnPremSqlServer1 is SYNCHRONIZED — safe to fail back with no data loss" -ForegroundColor Green



# ── [3] Planned manual failover to aen-sql-25-c ─────────────────────────────────
Write-Host "`n  [3] Performing planned failover of [$AgName] to $OnPremSqlServer1..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ Failover complete — $OnPremSqlServer1 is the new primary" -ForegroundColor Green



# ── [4] Return the cloud replica to ASYNCHRONOUS_COMMIT ─────────────────────────
# Issued on the NEW primary (aen-sql-25-c) so the WAN replica is out of the
# synchronous commit path and on-prem write latency is unaffected.
Write-Host "`n  [4] Returning $CloudSqlServer to ASYNCHRONOUS_COMMIT..." -ForegroundColor Yellow
$Query = @"
ALTER AVAILABILITY GROUP [$AgName]
    MODIFY REPLICA ON N'$CloudSqlServer' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query 
Write-Host "      ✓ $CloudSqlServer set back to asynchronous commit" -ForegroundColor Green


# ── [5] Resume data movement on the on-prem secondary and the cloud replica ─────
# Re-syncs aen-sql-25-d and the cloud replica as secondaries after the failback.
Write-Host "`n  [5] Resuming data movement on $SqlInstanceOnPrem2 and $SqlInstanceCloud..." -ForegroundColor Yellow
Resume-DbaAgDbDataMovement -SqlInstance $SqlInstanceOnPrem2 -Database $DbName -Confirm:$false
Write-Host "      ✓ Data movement resumed on $SqlInstanceOnPrem2" -ForegroundColor Green

Resume-DbaAgDbDataMovement -SqlInstance $SqlInstanceCloud -Database $DbName -Confirm:$false
Write-Host "      ✓ Data movement resumed on $CloudSqlServer" -ForegroundColor Green


# ── [6] Verify roles and sync state after failback ──────────────────────────────
# Query from the NEW primary (aen-sql-25-c) — aen-sql-25-e is now a secondary
# and would show the other replicas as Unknown.
Write-Host "`n  [6] Verifying AG roles and sync state after failback..." -ForegroundColor Yellow
$SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $OnPremSqlServer1 -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection
Get-DbaAgReplica -SqlInstance $SqlInstanceOnPrem1 | Select-Object Name, Role, ConnectionState, RollupSynchronizationState | Format-Table



Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Part 6 complete — failed back to on-prem                ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     Primary       : $OnPremSqlServer1 (on-prem)" -ForegroundColor White
Write-Host "     Cloud replica : $CloudSqlServer (asynchronous commit)" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Switched $CloudSqlServer and $OnPremSqlServer1 to SYNCHRONOUS_COMMIT, waited for $OnPremSqlServer1 to reach SYNCHRONIZED state, issued FAILOVER from $OnPremSqlServer1 then returned $CloudSqlServer to ASYNCHRONOUS_COMMIT." `
    -Highlight "Failover and failback of a 4 TB AG in minutes, independent of the size of data. The same T-SQL commands and Everpure snapshot backup workflow operate identically for failover in either direction — on-prem to cloud or cloud to on-prem."

#region --- Reset (optional; gated by \$ResetDemo flag) ---
$ResetDemo = $false

if ($ResetDemo) {
    Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host   "║  Resetting failover demo for re-run                      ║" -ForegroundColor Magenta
    Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    # [0] Resolve the CURRENT primary dynamically. The primary depends on how far
    #     the script ran: the cloud (aen-sql-25-e) after Part 1, but on-prem
    #     (aen-sql-25-c) after the Part 5 failback. REMOVE DATABASE must run on the
    #     primary; the other two replicas are the secondaries to drop.
    $InstanceMap = @{
        $CloudSqlServer   = $SqlInstanceCloud
        $OnPremSqlServer1 = $SqlInstanceOnPrem1
        $OnPremSqlServer2 = $SqlInstanceOnPrem2
    }
    $SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $SqlInstanceOnPrem1 -TrustServerCertificate -NonPooledConnection
    $PrimaryName  = (Get-DbaAgReplica -SqlInstance $SqlInstanceOnPrem1 -AvailabilityGroup $AgName |
                         Where-Object { $_.Role -eq 'Primary' } | Select-Object -First 1).Name
    $ShortPrimary = ($PrimaryName -split '\.')[0]
    $PrimaryKey   = $InstanceMap.Keys | Where-Object { ($_ -split '\.')[0] -ieq $ShortPrimary } | Select-Object -First 1
    if (-not $PrimaryKey) { throw "Could not match AG primary '$PrimaryName' to a known instance connection." }
    $PrimaryInstance = $InstanceMap[$PrimaryKey]
    $SecondaryNames  = $InstanceMap.Keys | Where-Object { $_ -ne $PrimaryKey }
    Write-Host "`n  Current primary: $PrimaryKey   Secondaries: $($SecondaryNames -join ', ')" -ForegroundColor DarkGray

    # [1] Remove database from the AG on the CURRENT primary
    Write-Host "`n  [1] Removing [$DbName] from AG on $PrimaryKey..." -ForegroundColor Yellow
    $Query = @"
        IF EXISTS (
            SELECT 1 FROM sys.availability_databases_cluster WHERE database_name = '$DbName'
        )
        BEGIN
            ALTER AVAILABILITY GROUP [$AgName] REMOVE DATABASE [$DbName]
        END
"@
    Invoke-DbaQuery -SqlInstance $PrimaryInstance -Database master -Query $Query
    Write-Host "      ✓ [$DbName] removed from AG on $PrimaryKey" -ForegroundColor Green

    # [2] Drop database from the secondaries
    Write-Host "`n  [2] Dropping [$DbName] from the secondaries ($($SecondaryNames -join ', '))..." -ForegroundColor Yellow
    foreach ($SecName in $SecondaryNames) {
        Remove-DbaDatabase -SqlInstance $InstanceMap[$SecName] -Database $DbName -Confirm:$false
        Write-Host "      ✓ [$DbName] dropped from $SecName" -ForegroundColor Green
    }

    Write-Host "`n  Reset complete. Primary [$PrimaryKey] copy of [$DbName] retained; secondaries cleared." -ForegroundColor Magenta
} else {
    Write-Host "`n  Tip: Set `$ResetDemo = `$true and re-run this region to reset the demo." -ForegroundColor DarkGray
}
#endregion


