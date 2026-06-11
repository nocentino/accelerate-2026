#############################################################################
# AG Unplanned Failover to Azure Cloud + On-Prem Reseed - Accelerate Demo
# Using SQL Server 2022+ T-SQL Snapshot Backup + Pure Storage FlashArray
#
# Scenario:
#    An unplanned outage has taken down the on-prem site (aen-sql-25-c and
#    aen-sql-25-d).  We force failover AG1 to the Azure EverPure replica
#    (aen-sql-25-e / gso-cbs-azure.fsa.lab) to restore service.
#
#    Once the on-prem site recovers, we reseed both on-prem replicas from a
#    PGroup snapshot taken on the Azure array and replicated back to the
#    on-prem arrays, using the T-SQL Snapshot Backup feature to generate the
#    .bkm metadata file needed to rejoin the AG.
#
#    Part 1 - Forced failover to aen-sql-25-e (Azure EverPure)
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


#region --- Variables ---
# Variables are named by machine identity so the SAME box uses the SAME name in
# both this script and Invoke-AGSeedFromSnapshot-sql25.ps1:
#   Cloud   = aen-sql-25-e (Azure)   OnPrem1 = aen-sql-25-c   OnPrem2 = aen-sql-25-d
# In THIS failover the cloud (aen-sql-25-e) is the new primary / snapshot source.

# SQL Server instances
$CloudSqlServer   = 'aen-sql-25-e'   # Azure EverPure - becomes new primary after failover
$OnPremSqlServer1 = 'aen-sql-25-c'   # On-prem replica 1 - needs reseed after recovery
$OnPremSqlServer2 = 'aen-sql-25-d'   # On-prem replica 2 - needs reseed after recovery
$AgName           = 'ag1'
$DbName           = 'TPCC-4T'   # same DB the companion seed script (Invoke-AGSeedFromSnapshot-sql25.ps1) uses

# FlashArray endpoints
$CloudArrayName   = 'gso-cbs-azure.fsa.lab'                              # Azure EverPure (new primary array)
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
$OnPremFaDataVol1 = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-c8f8057c'  # aen-sql-25-c data vol (20 TB,  Disk 3)
$OnPremFaLogVol1  = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-441252f7'  # aen-sql-25-c log vol  (512 GB, Disk 5)
$OnPremFaDataVol2 = 'vvol-aen-sql-25-d-7050d50f-vg/Data-fd4e545a'  # aen-sql-25-d data vol (20 TB,  Disk 3)
$OnPremFaLogVol2  = 'vvol-aen-sql-25-d-7050d50f-vg/Data-3c4b9c97'  # aen-sql-25-d log vol  (512 GB, Disk 5)

# Windows disk serial numbers on the on-prem servers (from Get-Disk)
$OnPremDataDiskSN1 = '6000c29a29d8a15135d8972104b80024'  # aen-sql-25-c D: data disk (20 TB,  Disk 3)
$OnPremLogDiskSN1  = '6000c29af911842f6dd25fd7bd55a8bc'  # aen-sql-25-c L: log disk  (512 GB, Disk 5)
$OnPremDataDiskSN2 = '6000c29668589f61a386218139e21bb0'  # aen-sql-25-d D: data disk (20 TB,  Disk 3)
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
Write-Host   "      (Demo note: the outage is simulated — nothing on-prem is actually stopped.)" -ForegroundColor DarkGray

# ── [1] Connect to the new primary (cloud) ──────────────────────────────────────
Write-Host "`n  [1] Connecting to $CloudSqlServer (new primary)..." -ForegroundColor Yellow
$SqlInstanceCloud = Connect-DbaInstance -SqlInstance $CloudSqlServer -TrustServerCertificate -NonPooledConnection
Write-Host "      ✓ Connected to $CloudSqlServer" -ForegroundColor Green



# ── [2] Force the AG to failover to the cloud replica ───────────────────────────
Write-Host "`n  [2] Forcing AG [$AgName] failover to $CloudSqlServer..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] FORCE_FAILOVER_ALLOW_DATA_LOSS"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose
Write-Host "      ✓ Failover complete — $CloudSqlServer is the new primary" -ForegroundColor Green



##############################################################################################################################
#
#   PART 2 — Review AG Status (on-prem replicas disconnected, need reseed)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 2 — Review AG Status                               ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "`n  $CloudSqlServer is the new primary. $OnPremSqlServer1 and $OnPremSqlServer2 will show" -ForegroundColor DarkGray
Write-Host   "  DISCONNECTED / NOT SYNCHRONIZING and must be reseeded before they can rejoin." -ForegroundColor DarkGray

# ── [1] Show replica status ─────────────────────────────────────────────────────
Write-Host "`n  [1] AG replica status..." -ForegroundColor Yellow
Get-DbaAgReplica  -SqlInstance $CloudSqlServer -AvailabilityGroup $AgName |
    Format-Table AvailabilityGroup, Name, Role, ConnectionState, SynchronizationHealth

# ── [2] Show database sync status ───────────────────────────────────────────────
Write-Host "  [2] AG database sync status..." -ForegroundColor Yellow
Get-DbaAgDatabase -SqlInstance $CloudSqlServer -AvailabilityGroup $AgName |
    Format-Table AvailabilityGroup, Replica, Name, SynchronizationState, SynchronizationHealth



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
Write-Host "`n  [2] Resolving replicated PGroup names..." -ForegroundColor Yellow
$CloudArrayFaName    = $FlashArrayCloud.ArrayName
$OnPremTargetPGroup1 = "$($CloudArrayFaName):$CloudPGroupName"
$OnPremTargetPGroup2 = "$($CloudArrayFaName):$CloudPGroupName"
Write-Host "      ✓ Cloud array         : $CloudArrayFaName" -ForegroundColor Green
Write-Host "        Target PGroup (-c)  : $OnPremTargetPGroup1" -ForegroundColor White
Write-Host "        Target PGroup (-d)  : $OnPremTargetPGroup2" -ForegroundColor White



# ── [3] Persistent connections to on-prem instances ─────────────────────────────
Write-Host "`n  [3] Connecting to on-prem SQL instances ($OnPremSqlServer1, $OnPremSqlServer2)..." -ForegroundColor Yellow
$SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $OnPremSqlServer1 -TrustServerCertificate -NonPooledConnection
$SqlInstanceOnPrem2 = Connect-DbaInstance -SqlInstance $OnPremSqlServer2 -TrustServerCertificate -NonPooledConnection
$OnPremSession1 = New-PSSession -ComputerName $OnPremSqlServer1
$OnPremSession2 = New-PSSession -ComputerName $OnPremSqlServer2
Write-Host "      ✓ Connected" -ForegroundColor Green



# ── [4] Freeze write I/O on the new primary (cloud) ─────────────────────────────
Write-Host "`n  [4] Freezing write I/O on $CloudSqlServer..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Query $Query -Verbose
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
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Query $Query -Verbose
Write-Host "      ✓ [$DbName] is writeable again — freeze released" -ForegroundColor Green
Write-Host "        Backup URL  : $BackupUrl" -ForegroundColor White



# ── [7] Bridging log backup for both on-prem secondaries ────────────────────────
Write-Host "`n  [7] Taking bridging log backup for both on-prem secondaries..." -ForegroundColor Yellow
$LogBackupUrl = "$S3BackupPath/$DbName-cloud-seed-$(Get-Date -Format FileDateTime).trn"
$Query = "BACKUP LOG [$DbName] TO URL = '$LogBackupUrl' WITH FORMAT, INIT"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose
Write-Host "      ✓ Log backup written : $LogBackupUrl" -ForegroundColor Green

Write-Host "`n  ── Cloud snapshot phase complete ────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($CloudSnapshot.Name)" -ForegroundColor White
Write-Host "     Backup   : $BackupUrl" -ForegroundColor White
Write-Host "     Log      : $LogBackupUrl" -ForegroundColor White
Write-Host "     Status   : Replicating asynchronously to both on-prem arrays" -ForegroundColor White



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
$OnPremTargetSnapshot1 = $null
do {
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    $OnPremTargetSnapshot1 = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem1 -Name $OnPremTargetPGroup1 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$OnPremTargetPGroup1.$($CloudSnapshot.Suffix)" }

    if ($OnPremTargetSnapshot1) {
        Write-Host "      Progress: $([math]::Round($OnPremTargetSnapshot1.Progress * 100))%" -ForegroundColor DarkGray
    } else {
        Write-Host "      Waiting for transfer to appear on $OnPremArrayName1..." -ForegroundColor DarkGray
    }
} while ([string]::IsNullOrEmpty($OnPremTargetSnapshot1.Completed) -or ($OnPremTargetSnapshot1.Progress -ne 1.0))
Write-Host "      ✓ Snapshot available on $OnPremArrayName1 at $($OnPremTargetSnapshot1.Completed)" -ForegroundColor Green



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
$Query = "RESTORE DATABASE [$DbName] FROM URL = '$BackupUrl' WITH METADATA_ONLY, REPLACE, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
Write-Host "      ✓ [$DbName] is in RESTORING state on $OnPremSqlServer1" -ForegroundColor Green



# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $OnPremSqlServer1..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG rejoin on $OnPremSqlServer1" -ForegroundColor Green



# ── [G] Rejoin secondary to AG ──────────────────────────────────────────────────
Write-Host "`n  [G] Rejoining $OnPremSqlServer1 to AG [$AgName]..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
Write-Host "      ✓ $OnPremSqlServer1 rejoined [$AgName] as a synchronizing replica" -ForegroundColor Green



# ── [H] Verify sync state on aen-sql-25-c ───────────────────────────────────────
Write-Host "`n  [H] Verifying sync state on $OnPremSqlServer1..." -ForegroundColor Yellow
Get-DbaAgDatabase -SqlInstance $CloudSqlServer -AvailabilityGroup $AgName |
    Select-Object ComputerName, AvailabilityGroup, Name, SynchronizationState, IsJoined, IsSuspended |
    Format-Table -AutoSize

Write-Host "  ── Part 4 complete (aen-sql-25-c reseeded) ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($OnPremTargetSnapshot1.Name)" -ForegroundColor White
Write-Host "     Log      : $LogBackupUrl" -ForegroundColor White



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
$OnPremTargetSnapshot2 = $null
do {
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    $OnPremTargetSnapshot2 = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem2 -Name $OnPremTargetPGroup2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$OnPremTargetPGroup2.$($CloudSnapshot.Suffix)" }

    if ($OnPremTargetSnapshot2) {
        Write-Host "      Progress: $([math]::Round($OnPremTargetSnapshot2.Progress * 100))%" -ForegroundColor DarkGray
    } else {
        Write-Host "      Waiting for transfer to appear on $OnPremArrayName2..." -ForegroundColor DarkGray
    }
} while ([string]::IsNullOrEmpty($OnPremTargetSnapshot2.Completed) -or ($OnPremTargetSnapshot2.Progress -ne 1.0))
Write-Host "      ✓ Snapshot available on $OnPremArrayName2 at $($OnPremTargetSnapshot2.Completed)" -ForegroundColor Green



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
$Query = "RESTORE DATABASE [$DbName] FROM URL = '$BackupUrl' WITH METADATA_ONLY, REPLACE, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query -Verbose
Write-Host "      ✓ [$DbName] is in RESTORING state on $OnPremSqlServer2" -ForegroundColor Green



# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $OnPremSqlServer2..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query -Verbose
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG rejoin on $OnPremSqlServer2" -ForegroundColor Green



# ── [G] Rejoin secondary to AG ──────────────────────────────────────────────────
Write-Host "`n  [G] Rejoining $OnPremSqlServer2 to AG [$AgName]..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query -Verbose
Write-Host "      ✓ $OnPremSqlServer2 rejoined [$AgName] as a synchronizing replica" -ForegroundColor Green



# ── [H] Final AG status across all three replicas ───────────────────────────────
Write-Host "`n  [H] Final AG status across all three replicas..." -ForegroundColor Yellow
Get-DbaAgReplica  -SqlInstance $CloudSqlServer -AvailabilityGroup $AgName |
    Format-Table AvailabilityGroup, Name, Role, ConnectionState, SynchronizationHealth

Get-DbaAgDatabase -SqlInstance $CloudSqlServer -AvailabilityGroup $AgName |
    Select-Object ComputerName, AvailabilityGroup, Name, SynchronizationState, IsJoined, IsSuspended |
    Format-Table -AutoSize

Write-Host "  ── Part 5 complete (aen-sql-25-d reseeded) ──────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($OnPremTargetSnapshot2.Name)" -ForegroundColor White
Write-Host "     Log      : $LogBackupUrl" -ForegroundColor White

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Failover + reseed complete — AG healthy                 ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     New primary : $CloudSqlServer  (Azure EverPure)" -ForegroundColor White
Write-Host "     Reseeded    : $OnPremSqlServer1, $OnPremSqlServer2  (on-prem)" -ForegroundColor White
Write-Host "     Database    : [$DbName] in AG [$AgName]" -ForegroundColor White



##############################################################################################################################
#
#   PART 6 — Planned Failback to On-Prem (aen-sql-25-c)
#
#   With all three replicas healthy again, fail the AG back to on-prem with a
#   PLANNED (no data loss) failover:
#     [1] Switch the cloud primary and the on-prem failback target to
#         SYNCHRONOUS_COMMIT (a no-data-loss failover requires BOTH ends sync).
#     [2] Wait for aen-sql-25-c to reach the SYNCHRONIZED state.
#     [3] Issue a planned manual failover from aen-sql-25-c (becomes primary).
#     [4] Return the cloud replica (aen-sql-25-e) to ASYNCHRONOUS_COMMIT so the
#         WAN link is no longer in the synchronous commit path.
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
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose
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
# FAILOVER (not FORCE_FAILOVER_ALLOW_DATA_LOSS) is issued ON the target secondary
# that is becoming the new primary.
Write-Host "`n  [3] Performing planned failover of [$AgName] to $OnPremSqlServer1..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] FAILOVER"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
Write-Host "      ✓ Failover complete — $OnPremSqlServer1 is the new primary" -ForegroundColor Green



# ── [4] Return the cloud replica to ASYNCHRONOUS_COMMIT ─────────────────────────
# Issued on the NEW primary (aen-sql-25-c) so the WAN replica is out of the
# synchronous commit path and on-prem write latency is unaffected.
Write-Host "`n  [4] Returning $CloudSqlServer to ASYNCHRONOUS_COMMIT..." -ForegroundColor Yellow
$Query = @"
ALTER AVAILABILITY GROUP [$AgName]
    MODIFY REPLICA ON N'$CloudSqlServer' WITH (AVAILABILITY_MODE = ASYNCHRONOUS_COMMIT);
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
Write-Host "      ✓ $CloudSqlServer set back to asynchronous commit" -ForegroundColor Green



# ── [5] Verify roles and sync state after failback ──────────────────────────────
Write-Host "`n  [5] Verifying AG roles and sync state after failback..." -ForegroundColor Yellow
Get-DbaAgReplica  -SqlInstance $OnPremSqlServer1 -AvailabilityGroup $AgName |
    Format-Table AvailabilityGroup, Name, Role, AvailabilityMode, ConnectionState, SynchronizationHealth

Get-DbaAgDatabase -SqlInstance $OnPremSqlServer1 -AvailabilityGroup $AgName |
    Select-Object ComputerName, AvailabilityGroup, Name, SynchronizationState, IsJoined, IsSuspended |
    Format-Table -AutoSize

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Part 6 complete — failed back to on-prem                ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     Primary       : $OnPremSqlServer1 (on-prem)" -ForegroundColor White
Write-Host "     Cloud replica : $CloudSqlServer (asynchronous commit)" -ForegroundColor White



#region --- Reset (optional; gated by $ResetDemo flag) ---
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
    Invoke-DbaQuery -SqlInstance $PrimaryInstance -Database master -Query $Query -Verbose
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


#region --- Cleanup ---
Get-DbaConnectedInstance | Disconnect-DbaInstance
Remove-PSSession $OnPremSession1
Remove-PSSession $OnPremSession2
#endregion
