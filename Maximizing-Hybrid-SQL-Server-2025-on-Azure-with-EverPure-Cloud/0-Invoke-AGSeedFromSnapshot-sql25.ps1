#############################################################################
# Seeding an Availability Group - Accelerate Demo
# Using SQL Server 2022+ T-SQL Snapshot Backup + Pure Storage FlashArray
#
# Scenario:
#    Seed AG1 with TPCC-4T from aen-sql-25-c (primary) to two secondaries:
#      Part 1 - aen-sql-25-d  (on-prem,  sn1-x90r2-f06-27)
#      Part 2 - aen-sql-25-e  (Azure,    gso-cbs-azure.fsa.lab  EverPure Cloud Dedicated)
#
#    A single PGroup snapshot is taken on the primary array and replicated to
#    both target arrays simultaneously.  The metadata backup (.bkm) and the
#    bridging log backup are written to FlashBlade S3 (s200.fsa.lab).
#
# Prerequisites:
#    1. dbatools and PureStoragePowerShellSDK2 installed on this machine.
#    2. Connect-DbaInstance -NonPooledConnection is required so the session that
#       freezes the database stays alive until the snapshot is taken.
#    3. Protection Group 'aen-sql-25-c-pg' on sn1-x90r2-f06-33 with async
#       replication configured to BOTH sn1-x90r2-f06-27 and gso-cbs-azure.fsa.lab.
#    4. AG1 already created with all three instances as replicas,
#       SEEDING_MODE = MANUAL on each secondary.
#    5. TPCC-4T is online on aen-sql-25-c; not yet joined on -d or -e.
#    6. Target volumes on -d and -e are provisioned and drive letters / file
#       paths match the primary (required for METADATA_ONLY restore).
#    7. All three SQL instances have network access to s200.fsa.lab.
#    8. Populate the $OnPrem*DiskSN2 / $Cloud*DiskSN values before running:
#         Invoke-Command -ComputerName <server> { Get-Disk | Format-Table Number,SerialNumber,Size }
#
# Usage Notes:
#    This script is built to run end-to-end in a single execution (F5, or
#    .\Invoke-AGSeedFromSnapshot-sql25.ps1). $ErrorActionPreference = 'Stop'
#    halts the run on the first failure so you never continue past a failed
#    freeze/snapshot. The sections remain ordered and labeled, so you can
#    still step through them interactively if you prefer.
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
# both this script and Invoke-AGFailoverToCloud-sql25.ps1:
#   Cloud   = aen-sql-25-e (Azure)   OnPrem1 = aen-sql-25-c   OnPrem2 = aen-sql-25-d
# In THIS seed the source/primary happens to be OnPrem1 (aen-sql-25-c).

# SQL Server instances
$OnPremSqlServer1 = 'aen-sql-25-c'   # on-prem        — PRIMARY / snapshot source in this seed
$OnPremSqlServer2 = 'aen-sql-25-d'   # on-prem        — secondary
$CloudSqlServer   = 'aen-sql-25-e'   # Azure EverPure — secondary
$AgName           = 'ag1'
$DbName           = 'TPCC-4T'

# FlashArray endpoints
$OnPremArrayName1 = 'sn1-x90r2-f06-33.fsa.lab'   # aen-sql-25-c (source array)
$OnPremArrayName2 = 'sn1-x90r2-f06-27.fsa.lab'   # aen-sql-25-d
$CloudArrayName   = 'gso-cbs-azure.fsa.lab'                               # aen-sql-25-e (Azure EverPure)

# Protection Group names
$OnPremPGroupName1   = 'aen-sql-25-c-pg'                    # source PGroup on aen-sql-25-c's array
$OnPremTargetPGroup2 = 'sn1-x90r2-f06-33:aen-sql-25-c-pg'   # replicated PGroup as seen on aen-sql-25-d's array
$CloudTargetPGroup   = 'sn1-x90r2-f06-33:aen-sql-25-c-pg'   # replicated PGroup as seen on aen-sql-25-e's array

# FlashArray volume names  (data = D: drive, log = L: drive)
$OnPremFaDataVol1 = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-0a463e4a'   # aen-sql-25-c data vol (20 TB, Hard disk 4, D:) — source
$OnPremFaLogVol1  = 'vvol-aen-sql-25-c-a55a37f5-vg/Data-441252f7'   # aen-sql-25-c log vol  (512 GB, Hard disk 5, L:) — source

$OnPremFaDataVol2 = 'vvol-aen-sql-25-d-a9ecd10d-vg/Data-769a59a9'   # aen-sql-25-d data vol (20 TB,  SCSI 0:3, Disk 3)
$OnPremFaLogVol2  = 'vvol-aen-sql-25-d-a9ecd10d-vg/Data-3f854849'   # aen-sql-25-d log vol  (512 GB, SCSI 2:3, Disk 5)

$CloudFaDataVol   = 'gso-an-win-1-SQLDATA1'                         # aen-sql-25-e data vol (Azure, 20 TB,  Disk 1)
$CloudFaLogVol    = 'gso-an-win-1-SQLLOG1'                          # aen-sql-25-e log vol  (Azure, 512 GB, Disk 2)

# Windows disk serial numbers  (from Get-Disk on each server)
$OnPremDataDiskSN2 = '6000c292e84613da877cc244d52bd78a'             # aen-sql-25-d D: data disk (20 TB,  Disk 3)
$OnPremLogDiskSN2  = '6000c2961b1c81cd6cd067157dcb0836'             # aen-sql-25-d L: log disk  (512 GB, Disk 5)
$CloudDataDiskSN   = 'B6E5BF390BDB4D5A0001A1CD'                     # aen-sql-25-e D: data disk (20 TB,  Disk 1)
$CloudLogDiskSN    = 'B6E5BF390BDB4D5A0001A1CE'                     # aen-sql-25-e L: log disk  (512 GB, Disk 2)

# S3 backup endpoint (FlashBlade s200.fsa.lab)
$S3CredentialName = 's3://s200.fsa.lab'
$S3BackupPath     = 's3://s200.fsa.lab/aen-sql-backups'

# SSH key for aen-sql-25-e (Azure — uses SSH-based remoting instead of WinRM)
$SshUser    = 'anocentino'
$SshKeyPath = "$HOME\.ssh\id_ed25519_aen_sql25"

#endregion Variables



#region --- Connections ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  Connecting to Resources on-prem and in Azure...         ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# aen-sql-25-d is on-prem: WinRM
$OnPremSession2 = New-PSSession -ComputerName $OnPremSqlServer2
# aen-sql-25-e is Azure: SSH key-based remoting
$CloudSession   = New-PSSession -HostName $CloudSqlServer -UserName $SshUser -KeyFilePath $SshKeyPath -SSHTransport

# Persistent SMO connections (-NonPooledConnection keeps the session alive while the database is frozen)
$SqlCredential = Import-Clixml -Path "$HOME\SA_Cred.xml"
$SqlInstanceOnPrem1 = Connect-DbaInstance -SqlInstance $OnPremSqlServer1 -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection
$SqlInstanceOnPrem2 = Connect-DbaInstance -SqlInstance $OnPremSqlServer2 -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection
$SqlInstanceCloud   = Connect-DbaInstance -SqlInstance $CloudSqlServer   -SqlCredential $SqlCredential -TrustServerCertificate -NonPooledConnection

$Credential        = Import-CliXml -Path "$HOME\FA_Cred.xml"
$FlashArrayOnPrem1 = Connect-Pfa2Array -EndPoint $OnPremArrayName1 -Credential $Credential -IgnoreCertificateError
$FlashArrayOnPrem2 = Connect-Pfa2Array -EndPoint $OnPremArrayName2 -Credential $Credential -IgnoreCertificateError
$FlashArrayCloud   = Connect-Pfa2Array -EndPoint $CloudArrayName   -Credential $Credential -IgnoreCertificateError
#endregion


#region One-time Setup: Create S3 credential on all three SQL instances
# Run this block once per instance. Safe to re-run - skips if credential exists.
$S3CredQuery = @"
IF NOT EXISTS (SELECT * FROM sys.credentials WHERE name = '$S3CredentialName')
    CREATE CREDENTIAL [$S3CredentialName]
    WITH IDENTITY = 'S3 Access Key',
         SECRET   = 'REPLACE_WITH_S3_ACCESS_KEY:REPLACE_WITH_S3_SECRET_KEY';
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Query $S3CredQuery
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Query $S3CredQuery
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud   -Query $S3CredQuery
#endregion


##############################################################################################################################
#
#   FREEZE / SNAPSHOT / METADATA BACKUP
#   Shared by PART 1 and PART 2 — taken once on the primary.
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  Freeze / Snapshot / Metadata Backup                     ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [1] Freeze write I/O on the primary ─────────────────────────────────────────
Write-Host "`n  [1] Freezing write I/O on $OnPremSqlServer1..." -ForegroundColor Yellow
$Query = "ALTER DATABASE [$DbName] SET SUSPEND_FOR_SNAPSHOT_BACKUP = ON"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Query $Query -Verbose
Write-Host "      ✓ [$DbName] write I/O suspended — snapshot window is open" -ForegroundColor Green



# ── [2] Take PGroup snapshot and replicate to both arrays ───────────────────────
Write-Host "`n  [2] Taking PGroup snapshot on $OnPremArrayName1..." -ForegroundColor Yellow
Write-Host "      Targeting $OnPremArrayName2 and $CloudArrayName" -ForegroundColor DarkGray
$OnPremSnapshot1 = New-Pfa2ProtectionGroupSnapshot -Array $FlashArrayOnPrem1 `
    -SourceName $OnPremPGroupName1 `
    -ForReplication $true `
    -ReplicateNow $true
Write-Host "      ✓ Snapshot created  : $($OnPremSnapshot1.Name)" -ForegroundColor Green



# ── [3] Release freeze — metadata backup to S3 ──────────────────────────────────
Write-Host "`n  [3] Releasing write I/O freeze and writing metadata backup to S3..." -ForegroundColor Yellow
$BackupUrl = "$S3BackupPath/$DbName-$(Get-Date -Format FileDateTime).bkm"
$Query = @"
BACKUP DATABASE [$DbName]
    TO URL = '$BackupUrl'
    WITH METADATA_ONLY,
         MEDIADESCRIPTION = '$($OnPremSnapshot1.Name)|$($FlashArrayOnPrem1.ArrayName)'
"@
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Query $Query -Verbose
Write-Host "      ✓ [$DbName] is writeable again — freeze released" -ForegroundColor Green
Write-Host "        Backup URL  : $BackupUrl" -ForegroundColor White

Write-Host "`n  ── Snapshot phase complete ──────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     Snapshot : $($OnPremSnapshot1.Name)" -ForegroundColor White
Write-Host "     Backup   : $BackupUrl" -ForegroundColor White
Write-Host "     Status   : Replicating asynchronously to both target arrays" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Froze write I/O on $OnPremSqlServer1 with SUSPEND_FOR_SNAPSHOT_BACKUP, triggered a Pure Storage PGroup snapshot on $OnPremArrayName1, then immediately released the freeze and wrote a METADATA_ONLY .bkm file to FlashBlade S3. The snapshot is now replicating async to both $OnPremArrayName2 and $CloudArrayName." `
    -Highlight "The production freeze lasted milliseconds. The 20 TB data volume never moved through SQL Server — it travels as an array-level block copy via PGroup replication. Seed time is bounded by storage speed, not database size."


##############################################################################################################################
#
#   PART 1 — Seed aen-sql-25-d  (on-prem, sn1-x90r2-f06-27)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 1 — Seed aen-sql-25-d  (on-prem)                   ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [A] Wait for replication to sn1-x90r2-f06-27 ────────────────────────────────
Write-Host "`n  [A] Waiting for snapshot to replicate to $OnPremArrayName2..." -ForegroundColor Yellow
$OnPremTargetSnapshot2 = $null
do {
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    $OnPremTargetSnapshot2 = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayOnPrem2 -Name $OnPremTargetPGroup2 -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$OnPremTargetPGroup2.$($OnPremSnapshot1.Suffix)" }

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



# ── [C] Overwrite FA volumes from replicated snapshot ────────────────────────────
Write-Host "`n  [C] Overwriting data and log volumes on $OnPremArrayName2 from snapshot..." -ForegroundColor Yellow
New-Pfa2Volume -Array $FlashArrayOnPrem2 `
    -Name $OnPremFaDataVol2 `
    -SourceName ($OnPremTargetSnapshot2.Name + ".$OnPremFaDataVol1") `
    -Overwrite $true

New-Pfa2Volume -Array $FlashArrayOnPrem2 `
    -Name $OnPremFaLogVol2 `
    -SourceName ($OnPremTargetSnapshot2.Name + ".$OnPremFaLogVol1") `
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



# ── [E1] Take bridging log backup on the primary ────────────────────────────────
Write-Host "`n  [E1] Taking bridging log backup on $OnPremSqlServer1..." -ForegroundColor Yellow
$LogBackupUrl = "$S3BackupPath/$DbName-Log-$(Get-Date -Format FileDateTime).trn"
$Query = "BACKUP LOG [$DbName] TO URL = '$LogBackupUrl'"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Query $Query -Verbose
Write-Host "      ✓ Log backup written  : $LogBackupUrl" -ForegroundColor Green



# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $OnPremSqlServer2..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query -Verbose
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG join on $OnPremSqlServer2" -ForegroundColor Green



# ── [G] Add database to the AG and join the secondary ───────────────────────────
# Manual seeding: $OnPremSqlServer2 already has [$DbName] restored WITH NORECOVERY
# (steps E–F above). So (1) ensure that SECONDARY replica uses MANUAL seeding,
# (2) ADD the database to the AG on the primary — an AG-wide action, done once — then
# (3) join the secondary by running SET HADR AVAILABILITY GROUP *on the secondary*.
# Part 2 joins $CloudSqlServer with the exact same mechanism.
Write-Host "`n  [G] Adding [$DbName] to [$AgName] and joining $OnPremSqlServer2..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$OnPremSqlServer2' WITH (SEEDING_MODE = MANUAL)"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose   # on the PRIMARY
$Query = "ALTER AVAILABILITY GROUP [$AgName] ADD DATABASE [$DbName];"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose   # on the PRIMARY (once for the AG)
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem2 -Database master -Query $Query -Verbose   # on the SECONDARY ($OnPremSqlServer2)
Write-Host "      ✓ [$DbName] joined [$AgName] — $OnPremSqlServer2 is a synchronizing replica" -ForegroundColor Green



# ── [H] Verify AG sync state ────────────────────────────────────────────────────
Write-Host "`n  [H] Verifying AG sync state..." -ForegroundColor Yellow
Get-DbaAgDatabase -SqlInstance $SqlInstanceOnPrem1 -AvailabilityGroup $AgName |
    Select-Object ComputerName, AvailabilityGroup, Name, SynchronizationState, IsJoined, IsSuspended |
    Format-Table -AutoSize

Write-Host "  ── Part 1 complete ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     [$DbName] seeded and synchronizing on $OnPremSqlServer2" -ForegroundColor White
Write-Host "     Snapshot   : $($OnPremTargetSnapshot2.Name)" -ForegroundColor White
Write-Host "     Log backup : $LogBackupUrl" -ForegroundColor White

Wait-Spacebar `
    -Summary  "The snapshot landed on $OnPremArrayName2. Disks were offlined on $OnPremSqlServer2, volumes were overwritten from the replicated snapshot, disks were brought back online, and the .bkm metadata + bridging log were restored. $OnPremSqlServer2 has joined $AgName as a synchronizing replica." `
    -Highlight "No backup stream crossed any network. A 20 TB secondary was seeded entirely by a storage-level volume overwrite from a replicated Flash snapshot — the same operation that takes seconds on any size database."


##############################################################################################################################
#
#   PART 2 — Seed aen-sql-25-e  (Azure EverPure, gso-cbs-azure.fsa.lab)
#
##############################################################################################################################

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  PART 2 — Seed aen-sql-25-e  (Azure EverPure)            ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ── [A] Wait for replication to gso-cbs-azure.fsa.lab ────────────────────────────────────
Write-Host "`n  [A] Waiting for snapshot to replicate to $CloudArrayName..." -ForegroundColor Yellow
$CloudTargetSnapshot = $null
do {
    Start-Sleep -Seconds 3
    # -ErrorAction SilentlyContinue: the transfer record may not exist yet — don't let
    # a transient "not found" abort the run now that $ErrorActionPreference = 'Stop'.
    $CloudTargetSnapshot = Get-Pfa2ProtectionGroupSnapshotTransfer -Array $FlashArrayCloud -Name $CloudTargetPGroup -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq "$CloudTargetPGroup.$($OnPremSnapshot1.Suffix)" }

    if ($CloudTargetSnapshot) {
        Write-Host "      Progress: $([math]::Round($CloudTargetSnapshot.Progress * 100))%" -ForegroundColor DarkGray
    } else {
        Write-Host "      Waiting for transfer to appear on $CloudArrayName..." -ForegroundColor DarkGray
    }
} while ([string]::IsNullOrEmpty($CloudTargetSnapshot.Completed) -or ($CloudTargetSnapshot.Progress -ne 1.0))
Write-Host "      ✓ Snapshot available on $CloudArrayName at $($CloudTargetSnapshot.Completed)" -ForegroundColor Green



# ── [B] Offline data and log disks on aen-sql-25-e ──────────────────────────────
Write-Host "`n  [B] Offlining data and log disks on $CloudSqlServer..." -ForegroundColor Yellow
Invoke-Command -Session $CloudSession -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:CloudDataDiskSN } | Set-Disk -IsOffline $True
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:CloudLogDiskSN  } | Set-Disk -IsOffline $True
}
Write-Host "      ✓ Data and log disks are offline on $CloudSqlServer" -ForegroundColor Green




# ── [C] Overwrite FA volumes from replicated snapshot ────────────────────────────
Write-Host "`n  [C] Overwriting data and log volumes on $CloudArrayName from snapshot..." -ForegroundColor Yellow
New-Pfa2Volume -Array $FlashArrayCloud `
    -Name $CloudFaDataVol `
    -SourceName ($CloudTargetSnapshot.Name + ".$OnPremFaDataVol1") `
    -Overwrite $true

New-Pfa2Volume -Array $FlashArrayCloud `
    -Name $CloudFaLogVol `
    -SourceName ($CloudTargetSnapshot.Name + ".$OnPremFaLogVol1") `
    -Overwrite $true
Write-Host "      ✓ Volumes overwritten — data and log disks contain snapshot data" -ForegroundColor Green



# ── [D] Online data and log disks on aen-sql-25-e ───────────────────────────────
Write-Host "`n  [D] Bringing data and log disks online on $CloudSqlServer..." -ForegroundColor Yellow
Invoke-Command -Session $CloudSession -ScriptBlock {
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:CloudDataDiskSN } | Set-Disk -IsOffline $False
    Get-Disk | Where-Object { $_.SerialNumber -eq $using:CloudLogDiskSN  } | Set-Disk -IsOffline $False
}
Write-Host "      ✓ Data and log disks are online on $CloudSqlServer" -ForegroundColor Green



# ── [E] Restore metadata backup (NORECOVERY) ────────────────────────────────────
Write-Host "`n  [E] Restoring metadata backup on $CloudSqlServer (NORECOVERY)..." -ForegroundColor Yellow
$Query = "RESTORE DATABASE [$DbName] FROM URL = '$BackupUrl' WITH METADATA_ONLY, REPLACE, NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose
Write-Host "      ✓ [$DbName] is in RESTORING state on $CloudSqlServer" -ForegroundColor Green



# ── [F] Restore bridging log backup ─────────────────────────────────────────────
Write-Host "`n  [F] Restoring bridging log backup on $CloudSqlServer..." -ForegroundColor Yellow
$Query = "RESTORE LOG [$DbName] FROM URL = '$LogBackupUrl' WITH NORECOVERY"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose
Write-Host "      ✓ Log backup applied — [$DbName] ready for AG join on $CloudSqlServer" -ForegroundColor Green



# ── [G] Join the secondary to the AG ────────────────────────────────────────────
# Same mechanism as Part 1: ensure $CloudSqlServer uses MANUAL seeding, then join it
# with SET HADR AVAILABILITY GROUP *on the secondary*. The database was already ADDed
# to the AG on the primary in Part 1 (an AG-wide action), so it isn't repeated here.
Write-Host "`n  [G] Joining $CloudSqlServer to [$AgName]..." -ForegroundColor Yellow
$Query = "ALTER AVAILABILITY GROUP [$AgName] MODIFY REPLICA ON N'$CloudSqlServer' WITH (SEEDING_MODE = MANUAL)"
Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose   # on the PRIMARY
$Query = "ALTER DATABASE [$DbName] SET HADR AVAILABILITY GROUP = [$AgName]"
Invoke-DbaQuery -SqlInstance $SqlInstanceCloud -Database master -Query $Query -Verbose   # on the SECONDARY ($CloudSqlServer)
Write-Host "      ✓ $CloudSqlServer joined [$AgName] as secondary replica" -ForegroundColor Green



# ── [H] Verify final AG sync state across all three replicas ────────────────────
Write-Host "`n  [H] Verifying final AG sync state across all three replicas..." -ForegroundColor Yellow
Get-DbaAgDatabase -SqlInstance $SqlInstanceOnPrem1 -AvailabilityGroup $AgName |
    Select-Object ComputerName, AvailabilityGroup, Name, SynchronizationState, IsJoined, IsSuspended |
    Format-Table -AutoSize

Write-Host "  ── Part 2 complete ──────────────────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     [$DbName] seeded and synchronizing on $CloudSqlServer" -ForegroundColor White
Write-Host "     Snapshot   : $($CloudTargetSnapshot.Name)" -ForegroundColor White
Write-Host "     Log backup : $LogBackupUrl" -ForegroundColor White

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Demo complete — all replicas seeded and synchronizing   ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     Primary    : $OnPremSqlServer1 (FlashArray on-prem)" -ForegroundColor White
Write-Host "     Secondary1 : $OnPremSqlServer2 (FlashArray on-prem)" -ForegroundColor White
Write-Host "     Secondary2 : $CloudSqlServer (Azure EverPure)" -ForegroundColor White
Write-Host "     Database   : [$DbName] in AG [$AgName]" -ForegroundColor White



#region --- Reset / Teardown (optional) ---
# Flip $ResetDemo to $true to tear the database back down so the whole demo can be
# re-run from a clean slate. It:
#   1. Removes [$DbName] from [$AgName] (issued on the primary; applies to all replicas).
#   2. Drops [$DbName] on both secondaries so the next METADATA_ONLY restore is clean.
# The copy on the primary ($OnPremSqlServer1) is left online standalone to re-seed from.
# Runs BEFORE the connection cleanup so it can reuse the authenticated SMO connections.
$ResetDemo = $true

if ($ResetDemo) {
    Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host   "║  RESET — tear down so the demo can re-run                ║" -ForegroundColor Magenta
    Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Magenta

    # ── [1] Remove the database from the AG (issued on the primary) ─────────────────
    Write-Host "`n  [1] Removing [$DbName] from [$AgName] on $OnPremSqlServer1..." -ForegroundColor Yellow
    $Query = @"
IF EXISTS (SELECT 1 FROM sys.availability_databases_cluster WHERE database_name = '$DbName')
    ALTER AVAILABILITY GROUP [$AgName] REMOVE DATABASE [$DbName];
"@
    Invoke-DbaQuery -SqlInstance $SqlInstanceOnPrem1 -Database master -Query $Query -Verbose
    Write-Host "      ✓ [$DbName] is no longer a member of [$AgName]" -ForegroundColor Green

    # ── [2] Drop the database on both secondaries ───────────────────────────────────
    foreach ($SqlInstanceSecondary in $SqlInstanceOnPrem2, $SqlInstanceCloud) {
        Write-Host "`n  [2] Dropping [$DbName] on $($SqlInstanceSecondary.Name)..." -ForegroundColor Yellow
        Remove-DbaDatabase -SqlInstance $SqlInstanceSecondary -Database $DbName -Confirm:$false | Out-Null
        Write-Host "      ✓ [$DbName] dropped on $($SqlInstanceSecondary.Name)" -ForegroundColor Green
    }

    Write-Host "`n  ── Reset complete — re-run the script to seed again ─────────────────────────────" -ForegroundColor Magenta
    Write-Host "     [$DbName] left online standalone on $OnPremSqlServer1 (the seed source)" -ForegroundColor White
} else {
    Write-Host "`n  (Reset skipped — set `$ResetDemo = `$true to tear down for a clean re-run.)" -ForegroundColor DarkGray
}
#endregion


#region --- Cleanup ---
Get-DbaConnectedInstance | Disconnect-DbaInstance
Remove-PSSession $OnPremSession2
Remove-PSSession $CloudSession
#endregion
