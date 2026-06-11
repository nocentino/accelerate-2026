#############################################################################
# ActiveDR Failover / Failback Demo — TPCC-4T-ADR (RDM volumes) to Azure
# Using Pure Storage ActiveDR (continuous pod replication) + SQL Server
#
# Storyline (run the PARTS in order — each prints what it is proving):
#
#   PART 0 — Baseline. Prod (aen-sql-25-c) owns TPCC-4T-ADR on its E:/M: RDM
#            volumes, in pod 'aen-sql-25-c-adr', continuously replicating to a
#            DEMOTED pod 'aen-sql-25-c-adr-dr' on the Azure array. A demo marker
#            table (dbo.DR_DemoLog) is seeded with a PROD row.
#
#   PART 1 — NON-DISRUPTIVE DR TEST. Promote the DR pod, bring the database up
#            on aen-sql-25-e, and perform a READ/WRITE at the DR site — all while
#            production keeps running untouched. Then demote the DR pod (the test
#            write is discarded) and replication resumes. Proves you can rehearse
#            DR with full read/write and ZERO production impact.
#
#   PART 2 — UNPLANNED FAILOVER. Production "fails." Promote the DR pod to bring
#            TPCC-4T-ADR live on aen-sql-25-e, and write a row IN DR. The DR site
#            is now serving the application.
#
#   PART 3 — REVERSE + FAILBACK. Reverse the ActiveDR direction (production
#            becomes the target and resyncs the DR changes home), then fail back
#            to on-prem and online the database. The row written in DR is now
#            present on-prem.
#
#   KEY POINT: failback is driven by ActiveDR's storage-optimized replication —
#   only the CHANGED BLOCKS since the failover move, never the full 4.5 TB
#   dataset. So failback time is a function of CHANGE, not database size.
#
# Prerequisites:
#   - PureStoragePowerShellSDK2 + dbatools on this host.
#   - WinRM to aen-sql-25-c; SSH key remoting to aen-sql-25-e.
#   - FA_Cred.xml (FlashArray) + SA_Cred.xml (SQL) in $HOME.
#   - ActiveDR link 'aen-sql-25-c-adr' -> 'gso-cbs-azure::aen-sql-25-c-adr-dr'
#     already established (see Setup-ActiveDR-RdmToCloud-sql25.ps1) and replicating.
#   - TPCC-4T-ADR already attached on BOTH instances (online in prod, may be
#     offline in DR). Drive letters E: (data) and M: (log) on each guest.
#
# Disclaimer:
#   Provided AS-IS for demos. It performs REAL failover/failback on TPCC-4T-ADR
#   (offlines the database on each side as ownership moves). It does NOT touch
#   the AG database TPCC-4T or any other database.
#############################################################################

Import-Module dbatools
Import-Module PureStoragePowerShellSDK2
$ErrorActionPreference = 'Stop'


#region --- Variables ---
$DbName          = 'TPCC-4T-ADR'

$ProdSqlServer   = 'aen-sql-25-c'                                  # WinRM
$DrSqlServer     = 'aen-sql-25-e'                                  # SSH key remoting

$ProdArray       = 'sn1-x90r2-f06-33.fsa.lab'     # production FlashArray
$DrArray         = 'gso-cbs-azure.fsa.lab'                                 # Azure EPC FlashArray

$ProdPod         = 'aen-sql-25-c-adr'                             # local (source) pod
$DrPod           = 'aen-sql-25-c-adr-dr'                          # remote (DR) pod
$DrConnName      = 'gso-cbs-azure'                               # array connection prod -> DR

$DataLetter      = 'E'    # data volume drive letter on both guests
$LogLetter       = 'M'    # log  volume drive letter on both guests

$SshUser         = 'anocentino'
$SshKeyPath      = "$HOME\.ssh\id_ed25519_aen_sql25"
$Credential      = Import-CliXml -Path "$HOME\FA_Cred.xml"
$SqlCredential   = Import-CliXml -Path "$HOME\SA_Cred.xml"

$ReplicaWaitMin  = 30     # bounded wait (minutes) for a resync to reach its target state
#endregion


#region --- Helpers ---
function Write-Banner { param($Text, $Color = 'Cyan')
    $w = 58
    Write-Host "`n$('╔' + ('═' * $w) + '╗')" -ForegroundColor $Color
    Write-Host   "$('║' + ('  ' + $Text).PadRight($w) + '║')" -ForegroundColor $Color
    Write-Host   "$('╚' + ('═' * $w) + '╝')" -ForegroundColor $Color
}

# Online the pod's two disks on a guest (by Pure serial) and pin the drive letters.
function Online-Disks { param($Session, $DataSerial, $LogSerial, $DataLetter, $LogLetter)
    Invoke-Command -Session $Session -ScriptBlock {
        Update-HostStorageCache; Start-Sleep -Seconds 6; Update-HostStorageCache
        foreach ($m in @(@{S=$using:DataSerial; L=$using:DataLetter}, @{S=$using:LogSerial; L=$using:LogLetter})) {
            $d = Get-Disk | Where-Object { $_.SerialNumber -eq $m.S }
            if (-not $d) { Write-Output "  WARN: disk serial $($m.S) not visible"; continue }
            Set-Disk -Number $d.Number -IsReadOnly $false -ErrorAction SilentlyContinue
            Set-Disk -Number $d.Number -IsOffline  $false -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $p = Get-Partition -DiskNumber $d.Number | Where-Object { $_.Size -gt 1GB } | Sort-Object Size -Descending | Select-Object -First 1
            if ($p -and $p.DriveLetter -ne $m.L) {
                try { Set-Partition -DiskNumber $d.Number -PartitionNumber $p.PartitionNumber -NewDriveLetter $m.L } catch { Write-Output "  letter $($m.L): $_" }
            }
        }
    }
}

function Offline-Disks { param($Session, $DataSerial, $LogSerial)
    Invoke-Command -Session $Session -ScriptBlock {
        Get-Disk | Where-Object { $_.SerialNumber -in @($using:DataSerial, $using:LogSerial) } | Set-Disk -IsOffline $true
    }
}

# State = ONLINE | OFFLINE. Only OFFLINE accepts the connection-termination clause.
# $DbName is read from script scope (PowerShell dynamic scoping).
function Set-DbState { param($SqlInstance, $State)
    $clause = if ($State -eq 'OFFLINE') { ' WITH ROLLBACK IMMEDIATE' } else { '' }
    Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query "ALTER DATABASE [$DbName] SET $State$clause"
}

# Wait until a pod reaches a promotion state, bounded.
function Wait-PodState { param($Array, $Name, $State)
    $deadline = (Get-Date).AddMinutes($ReplicaWaitMin)
    do {
        Start-Sleep -Seconds 5
        $p = Get-Pfa2Pod -Array $Array -Name $Name
        Write-Host "      $Name promotion-status: $($p.PromotionStatus)" -ForegroundColor DarkGray
        if ((Get-Date) -gt $deadline) { Write-Warning "      timed out waiting for $Name = $State"; break }
    } while ($p.PromotionStatus -ne $State)
    return $p
}
#endregion


#region --- Connections + serial discovery ---
Write-Banner 'Connecting & discovering volume serials'
$ProdFa = Connect-Pfa2Array -EndPoint $ProdArray -Credential $Credential -IgnoreCertificateError
$DrFa   = $null
for ($i=1; $i -le 5 -and -not $DrFa; $i++) { try { $DrFa = Connect-Pfa2Array -EndPoint $DrArray -Credential $Credential -IgnoreCertificateError } catch { Start-Sleep -Seconds 6 } }
if (-not $DrFa) { throw "Could not connect to DR array $DrArray." }

$ProdInst = Connect-DbaInstance -SqlInstance $ProdSqlServer -SqlCredential $SqlCredential -TrustServerCertificate
$DrInst   = Connect-DbaInstance -SqlInstance $DrSqlServer   -SqlCredential $SqlCredential -TrustServerCertificate
$ProdSession = New-PSSession -ComputerName $ProdSqlServer
$DrSession   = New-PSSession -HostName $DrSqlServer -UserName $SshUser -KeyFilePath $SshKeyPath -SSHTransport

# Discover per-array volume serials from each pod (no hardcoded serials).
function Get-PodSerials { param($Array, $Pod)
    $v = Get-Pfa2Volume -Array $Array -Filter "pod.name='$Pod'"
    @{ Data = ($v | Where-Object { $_.Name -like '*-E-rdm' }).Serial
       Log  = ($v | Where-Object { $_.Name -like '*-M-rdm' }).Serial }
}
$ProdSer = Get-PodSerials -Array $ProdFa -Pod $ProdPod
$DrSer   = Get-PodSerials -Array $DrFa   -Pod $DrPod
Write-Host "  Prod serials  data=$($ProdSer.Data)  log=$($ProdSer.Log)" -ForegroundColor DarkGray
Write-Host "  DR   serials  data=$($DrSer.Data)  log=$($DrSer.Log)" -ForegroundColor DarkGray
#endregion


##############################################################################################################################
#  PART 0 — Baseline (production owns TPCC-4T-ADR; replicating to demoted DR pod)
##############################################################################################################################
Write-Banner 'PART 0 — Baseline on production' 'Green'

Write-Host "  Ensuring $DbName is ONLINE on $ProdSqlServer..." -ForegroundColor Yellow
if ((Get-DbaDbState -SqlInstance $ProdInst | Where-Object { $_.DatabaseName -eq $DbName }).Status -ne 'ONLINE') {
    Set-DbState -SqlInstance $ProdInst -State 'ONLINE'
}

Write-Host "  Seeding marker table dbo.DR_DemoLog with a PROD row..." -ForegroundColor Yellow
$seed = @"
IF OBJECT_ID('dbo.DR_DemoLog') IS NULL
    CREATE TABLE dbo.DR_DemoLog (Id INT IDENTITY PRIMARY KEY, Site SYSNAME, Note NVARCHAR(200), WrittenAt DATETIME2 DEFAULT SYSDATETIME());
INSERT dbo.DR_DemoLog (Site, Note) VALUES ('PROD', 'baseline written on production before any failover');
"@
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query $seed
Write-Host "  Current DR_DemoLog on PROD:" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize

Write-Host "  Replica link status:" -ForegroundColor Cyan
Get-Pfa2PodReplicaLink -Array $ProdFa -LocalPodName $ProdPod | Format-Table Status, Direction, RecoveryPoint -AutoSize
# Let the table/insert replicate to the DR pod before the test promotes it.
Write-Host "  Allowing the baseline write to replicate to DR..." -ForegroundColor DarkGray
Start-Sleep -Seconds 20


##############################################################################################################################
#  PART 1 — Non-disruptive DR TEST (read/write at DR, production untouched)
##############################################################################################################################
Write-Banner 'PART 1 — Non-disruptive DR test (R/W at DR)'

Write-Host "  [1] Promoting DR pod $DrPod (test) — production keeps running..." -ForegroundColor Yellow
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'promoted' | Out-Null

Write-Host "  [2] Bringing $DbName up on $DrSqlServer (online disks + database)..." -ForegroundColor Yellow
Online-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $DrInst -State 'ONLINE'

Write-Host "  [3] READ/WRITE at the DR site — inserting a TEST row on $DrSqlServer..." -ForegroundColor Yellow
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "INSERT dbo.DR_DemoLog (Site, Note) VALUES ('DR-TEST', 'read/write proven at DR during NON-DISRUPTIVE test')"
Write-Host "      DR_DemoLog as seen at DR (note the DR-TEST row):" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize

Write-Host "  [4] Ending the test: offline DB+disks at DR and DEMOTE (discards the test write)..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $DrInst -State 'OFFLINE'
Offline-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'demoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'demoted' | Out-Null

Write-Host "  [5] Production was untouched — DR_DemoLog on PROD has NO DR-TEST row:" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "  ✓ DR rehearsed with full read/write and ZERO production impact." -ForegroundColor Green


##############################################################################################################################
#  PART 2 — Unplanned failover to DR
##############################################################################################################################
Write-Banner 'PART 2 — UNPLANNED failover to DR' 'Red'
Write-Host "  [!] Simulated production outage. Promote DR to restore service." -ForegroundColor Red

Write-Host "  [1] Promoting DR pod $DrPod (failover)..." -ForegroundColor Yellow
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'promoted' | Out-Null

Write-Host "  [2] Bringing $DbName live on $DrSqlServer..." -ForegroundColor Yellow
Online-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $DrInst -State 'ONLINE'

Write-Host "  [3] Application now runs in DR — writing a row IN DR (this is the change we track)..." -ForegroundColor Yellow
$drStamp = "FAILOVER write in DR — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "INSERT dbo.DR_DemoLog (Site, Note) VALUES ('DR', N'$drStamp')"
Write-Host "      DR_DemoLog at DR (now the system of record):" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "  ✓ DR is serving the application. Remember the row: '$drStamp'" -ForegroundColor Green


##############################################################################################################################
#  PART 3 — Reverse replication + failback to production
##############################################################################################################################
Write-Banner 'PART 3 — Reverse + failback to production' 'Green'

# (a) Production "recovers." Quiesce it so the prod pod can become the target.
Write-Host "  [1] Production recovered — offline $DbName + disks on $ProdSqlServer to reverse the link..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $ProdInst -State 'OFFLINE'
Offline-Disks -Session $ProdSession -DataSerial $ProdSer.Data -LogSerial $ProdSer.Log

# (b) Reverse: demote PROD pod -> it becomes the target and resyncs the DR changes home.
#     This is the moment to highlight: only CHANGED BLOCKS travel, not the 4.5 TB DB.
Write-Host "  [2] Reversing replication — demoting prod pod (delta resync from DR)..." -ForegroundColor Yellow
$swReverse = [System.Diagnostics.Stopwatch]::StartNew()
Update-Pfa2Pod -Array $ProdFa -Name $ProdPod -RequestedPromotionState 'demoted' | Out-Null
Wait-PodState -Array $ProdFa -Name $ProdPod -State 'demoted' | Out-Null

# Wait for the prod (now target) link to be caught up (recovery point current).
Write-Host "      Waiting for prod to catch up (link replicating inbound)..." -ForegroundColor DarkGray
$deadline = (Get-Date).AddMinutes($ReplicaWaitMin)
do {
    Start-Sleep -Seconds 5
    $link = Get-Pfa2PodReplicaLink -Array $ProdFa -LocalPodName $ProdPod
    Write-Host "      status=$($link.Status)  direction=$($link.Direction)  recovery_point=$($link.RecoveryPoint)" -ForegroundColor DarkGray
    if ((Get-Date) -gt $deadline) { Write-Warning "      reverse resync wait timed out"; break }
} while ($link.Status -ne 'replicating')
$swReverse.Stop()

# (c) Fail back: quiesce DR, then promote prod (this demotes DR) and resume prod -> DR.
Write-Host "  [3] Failing back: offline $DbName + disks at DR, then promote prod..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $DrInst -State 'OFFLINE'
Offline-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log
Update-Pfa2Pod -Array $ProdFa -Name $ProdPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $ProdFa -Name $ProdPod -State 'promoted' | Out-Null

# (d) Online the database back on production.
Write-Host "  [4] Onlining $DbName on $ProdSqlServer..." -ForegroundColor Yellow
Online-Disks -Session $ProdSession -DataSerial $ProdSer.Data -LogSerial $ProdSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $ProdInst -State 'ONLINE'

# (e) THE PAYOFF — the row written in DR is now present on-prem.
Write-Banner 'RESULT — the DR change is now back on-prem' 'Green'
Write-Host "  DR_DemoLog on PRODUCTION after failback:" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
$found = Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT COUNT(*) AS n FROM dbo.DR_DemoLog WHERE Note = N'$drStamp'"
if ($found.n -ge 1) {
    Write-Host "  ✓ The row written IN DR ('$drStamp') is now ON-PREM." -ForegroundColor Green
} else {
    Write-Warning "  Expected the DR-written row on-prem but did not find it — investigate replication state."
}

Write-Host "`n  ── Why this is fast ─────────────────────────────────────────────────────────────" -ForegroundColor Magenta
Write-Host "     Reverse + catch-up completed in $([math]::Round($swReverse.Elapsed.TotalSeconds,1)) seconds." -ForegroundColor White
Write-Host "     ActiveDR replicated only the CHANGED BLOCKS since failover — NOT the 4.5 TB" -ForegroundColor White
Write-Host "     database. Failback time scales with how much DATA CHANGED, not database size." -ForegroundColor White
Write-Host "     That is Purity's storage-optimized, always-thin, deduped replication at work." -ForegroundColor White

Write-Host "`n  Final link state (prod -> DR, replicating again):" -ForegroundColor Cyan
Get-Pfa2PodReplicaLink -Array $ProdFa -LocalPodName $ProdPod | Format-Table Status, Direction, RecoveryPoint -AutoSize


#region --- Cleanup ---
Remove-PSSession $ProdSession, $DrSession
#endregion
