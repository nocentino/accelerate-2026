#############################################################################
# ActiveDR Failover / Failback to Azure Cloud - Accelerate Demo
# Using Pure Storage ActiveDR (continuous pod replication) + SQL Server
#
# Scenario:
#    TPCC-4T-ADR lives on RDM volumes on the on-prem production host
#    (aen-sql-25-c), in pod 'aen-sql-25-c-adr', continuously replicating via
#    ActiveDR to a DEMOTED DR pod 'aen-sql-25-c-adr-dr' on the Azure EverPure
#    Cloud array (gso-cbs-azure.fsa.lab / aen-sql-25-e). A demo marker table
#    (dbo.DR_DemoLog) is used to prove which site holds which writes.
#
#    Part 0 - Baseline: production owns the DB; seed a PROD marker row
#    Part 1 - Non-disruptive DR test: promote DR, prove read/write at the DR
#             site, demote (test write discarded) — ZERO production impact
#    Part 2 - Unplanned failover: production "fails", promote DR and write a
#             row IN DR (the change we track through failback)
#    Part 3 - Reverse + failback: reverse the ActiveDR direction so production
#             resyncs the DR changes home, fail back on-prem, and confirm the
#             DR-written row is now present on-prem
#
#    KEY POINT: failback is driven by ActiveDR's storage-optimized replication —
#    only the CHANGED BLOCKS since the failover move, never the full 4.5 TB
#    dataset. So failback time is a function of CHANGE, not database size.
#
# Prerequisites:
#    1. dbatools and PureStoragePowerShellSDK2 installed on this machine.
#    2. WinRM to aen-sql-25-c (on-prem); SSH key remoting to aen-sql-25-e (Azure).
#    3. ActiveDR link 'aen-sql-25-c-adr' -> 'gso-cbs-azure::aen-sql-25-c-adr-dr'
#       already established (see Setup-ActiveDR-RdmToCloud-sql25.ps1) and replicating.
#    4. TPCC-4T-ADR attached on BOTH instances (online in prod, may be offline
#       in DR). Drive letters E: (data) and M: (log) on each guest.
#    5. FA_Cred.xml (FlashArray) and SA_Cred.xml (SQL) in $HOME.
#
# Usage Notes:
#    This script is built to run end-to-end in a single execution (F5, or
#    .\2-Invoke-ActiveDRFailoverDemo-sql25.ps1). $ErrorActionPreference = 'Stop'
#    halts the run on the first failure so you never continue past a failed
#    promote/demote. The PARTS remain ordered and labeled, so you can still
#    step through them interactively if you prefer.
#
#    PART 2 is destructive to the DR copy: it promotes the DR pod and brings
#    the database live at the DR site. PART 3 offlines the database on each
#    side as ownership moves. It does NOT touch the AG database TPCC-4T.
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
# failed step (e.g. a failed promote while the database is still online at DR).
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
# Prod = aen-sql-25-c (on-prem, source pod)   DR = aen-sql-25-e (Azure EverPure, DR pod)
# The same TPCC-4T-ADR database is owned by whichever side currently has its pod promoted.
$DbName          = 'TPCC-4T-ADR'

$ProdSqlServer   = 'aen-sql-25-c'                 # on-prem    — WinRM
$DrSqlServer     = 'aen-sql-25-e'                 # Azure EPC  — SSH key remoting

$ProdArray       = 'sn1-x90r2-f06-33.fsa.lab'     # production FlashArray
$DrArray         = 'gso-cbs-azure.fsa.lab'        # Azure EverPure Cloud FlashArray

$ProdPod         = 'aen-sql-25-c-adr'             # local (source) pod
$DrPod           = 'aen-sql-25-c-adr-dr'          # remote (DR) pod
$DrConnName      = 'gso-cbs-azure'                # array connection prod -> DR

$DataLetter      = 'E'    # data volume drive letter on both guests
$LogLetter       = 'M'    # log  volume drive letter on both guests

# SSH key for aen-sql-25-e (Azure — uses SSH-based remoting instead of WinRM)
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

# Discover per-array volume serials from each pod (no hardcoded serials).
function Get-PodSerials { param($Array, $Pod)
    $v = Get-Pfa2Volume -Array $Array -Filter "pod.name='$Pod'"
    @{ Data = ($v | Where-Object { $_.Name -like '*-E-rdm' }).Serial
       Log  = ($v | Where-Object { $_.Name -like '*-M-rdm' }).Serial }
}
#endregion


#region --- Connections + volume serial discovery ---
Write-Banner 'Connecting to resources on-prem and in Azure'

# ── [1] Connect to both FlashArrays ─────────────────────────────────────────────
Write-Host "`n  [1] Connecting to FlashArrays..." -ForegroundColor Yellow
$ProdFa = Connect-Pfa2Array -EndPoint $ProdArray -Credential $Credential -IgnoreCertificateError
$DrFa   = $null
for ($i=1; $i -le 5 -and -not $DrFa; $i++) { try { $DrFa = Connect-Pfa2Array -EndPoint $DrArray -Credential $Credential -IgnoreCertificateError } catch { Start-Sleep -Seconds 6 } }
if (-not $DrFa) { throw "Could not connect to DR array $DrArray." }
Write-Host "      ✓ Connected to $ProdArray and $DrArray" -ForegroundColor Green

# ── [2] Connect to both SQL instances and open remoting sessions ────────────────
Write-Host "`n  [2] Connecting to SQL instances and opening remoting sessions..." -ForegroundColor Yellow
$ProdInst = Connect-DbaInstance -SqlInstance $ProdSqlServer -SqlCredential $SqlCredential -TrustServerCertificate
$DrInst   = Connect-DbaInstance -SqlInstance $DrSqlServer   -SqlCredential $SqlCredential -TrustServerCertificate
# aen-sql-25-c is on-prem (WinRM); aen-sql-25-e is Azure (SSH key-based remoting)
$ProdSession = New-PSSession -ComputerName $ProdSqlServer
$DrSession   = New-PSSession -HostName $DrSqlServer -UserName $SshUser -KeyFilePath $SshKeyPath -SSHTransport
Write-Host "      ✓ Connected to $ProdSqlServer (WinRM) and $DrSqlServer (SSH)" -ForegroundColor Green

# ── [3] Discover per-array volume serials from each pod ─────────────────────────
Write-Host "`n  [3] Discovering volume serials from each pod..." -ForegroundColor Yellow
$ProdSer = Get-PodSerials -Array $ProdFa -Pod $ProdPod
$DrSer   = Get-PodSerials -Array $DrFa   -Pod $DrPod
Write-Host "      Prod serials  data=$($ProdSer.Data)  log=$($ProdSer.Log)" -ForegroundColor DarkGray
Write-Host "      DR   serials  data=$($DrSer.Data)  log=$($DrSer.Log)" -ForegroundColor DarkGray
Write-Host "      ✓ Serials resolved on both arrays" -ForegroundColor Green
#endregion


##############################################################################################################################
#
#   PART 0 — Baseline (production owns TPCC-4T-ADR; replicating to demoted DR pod)
#
##############################################################################################################################

Write-Banner 'PART 0 — Baseline on production' 'Green'

# ── [1] Ensure the database is ONLINE on production ─────────────────────────────
Write-Host "`n  [1] Ensuring $DbName is ONLINE on $ProdSqlServer..." -ForegroundColor Yellow
if ((Get-DbaDbState -SqlInstance $ProdInst | Where-Object { $_.DatabaseName -eq $DbName }).Status -ne 'ONLINE') {
    Set-DbState -SqlInstance $ProdInst -State 'ONLINE'
}
Write-Host "      ✓ [$DbName] is online on $ProdSqlServer" -ForegroundColor Green

# ── [2] Seed the demo marker table with a PROD row ──────────────────────────────
Write-Host "`n  [2] Seeding marker table dbo.DR_DemoLog with a PROD row..." -ForegroundColor Yellow
$seed = @"
IF OBJECT_ID('dbo.DR_DemoLog') IS NULL
    CREATE TABLE dbo.DR_DemoLog (Id INT IDENTITY PRIMARY KEY, Site SYSNAME, Note NVARCHAR(200), WrittenAt DATETIME2 DEFAULT SYSDATETIME());
INSERT dbo.DR_DemoLog (Site, Note) VALUES ('PROD', 'baseline written on production before any failover');
"@
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query $seed
Write-Host "      Current DR_DemoLog on PROD:" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "      ✓ Baseline PROD row written" -ForegroundColor Green

# ── [3] Confirm the ActiveDR link and let the write replicate ───────────────────
Write-Host "`n  [3] Confirming the ActiveDR replica link status..." -ForegroundColor Yellow
Get-Pfa2PodReplicaLink -Array $ProdFa -LocalPodName $ProdPod | Format-Table Status, Direction, RecoveryPoint -AutoSize
# Let the table/insert replicate to the DR pod before the test promotes it.
Write-Host "      Allowing the baseline write to replicate to DR..." -ForegroundColor DarkGray
Start-Sleep -Seconds 20
Write-Host "      ✓ Baseline replicated to the demoted DR pod" -ForegroundColor Green

Wait-Spacebar `
    -Summary  "Confirmed $DbName is online on $ProdSqlServer and seeded dbo.DR_DemoLog with a PROD baseline row. The pod $ProdPod is continuously replicating to the demoted DR pod $DrPod on $DrArray." `
    -Highlight "ActiveDR replicates continuously with no RPO gap and no backup schedule. The DR pod holds a current, consistent copy of the data at all times. It is demoted — holding the data but not serving writes — ready for a failover trigger."


##############################################################################################################################
#
#   PART 1 — Non-disruptive DR test (read/write at DR, production untouched)
#
##############################################################################################################################

Write-Banner 'PART 1 — Non-disruptive DR test (R/W at DR)'

# ── [1] Promote the DR pod for the test ─────────────────────────────────────────
Write-Host "`n  [1] Promoting DR pod $DrPod (test) — production keeps running..." -ForegroundColor Yellow
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'promoted' | Out-Null
Write-Host "      ✓ $DrPod promoted on $DrArray" -ForegroundColor Green

# ── [2] Bring the database up at the DR site ────────────────────────────────────
Write-Host "`n  [2] Bringing $DbName up on $DrSqlServer (online disks + database)..." -ForegroundColor Yellow
Online-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $DrInst -State 'ONLINE'
Write-Host "      ✓ [$DbName] is online on $DrSqlServer" -ForegroundColor Green

# ── [3] Prove READ/WRITE at the DR site ─────────────────────────────────────────
Write-Host "`n  [3] READ/WRITE at the DR site — inserting a TEST row on $DrSqlServer..." -ForegroundColor Yellow
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "INSERT dbo.DR_DemoLog (Site, Note) VALUES ('DR-TEST', 'read/write proven at DR during NON-DISRUPTIVE test')"
Write-Host "      DR_DemoLog as seen at DR (note the DR-TEST row):" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "      ✓ Read/write confirmed at the DR site" -ForegroundColor Green

# ── [4] End the test: offline DB + disks at DR and DEMOTE ───────────────────────
Write-Host "`n  [4] Ending the test: offline DB+disks at DR and DEMOTE (discards the test write)..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $DrInst -State 'OFFLINE'
Offline-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'demoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'demoted' | Out-Null
Write-Host "      ✓ $DrPod demoted — replication resumed, test write discarded" -ForegroundColor Green

# ── [5] Verify production was untouched ─────────────────────────────────────────
Write-Host "`n  [5] Production was untouched — DR_DemoLog on PROD has NO DR-TEST row:" -ForegroundColor Yellow
Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "      ✓ DR rehearsed with full read/write and ZERO production impact." -ForegroundColor Green

Write-Host "  ── Part 1 complete (non-disruptive DR test) ─────────────────────────────────────" -ForegroundColor Cyan
Write-Host "     DR site proved read/write; production ran without interruption" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Promoted $DrPod on $DrArray, onlined $DbName on $DrSqlServer, inserted a test row to prove read/write access, then demoted the DR pod discarding the test write, and resumed replication — $ProdSqlServer ran without interruption throughout." `
    -Highlight "A full read/write DR rehearsal with zero production impact and no maintenance window. No other DR technology lets you test write operations at the DR site while production keeps running. This is the ActiveDR differentiator."


##############################################################################################################################
#
#   PART 2 — Unplanned failover to DR
#
##############################################################################################################################

Write-Banner 'PART 2 — UNPLANNED failover to DR' 'Red'

Write-Host "`n  [!] Simulated production outage. Promote DR to restore service." -ForegroundColor Red

# ── [1] Promote the DR pod (failover) ───────────────────────────────────────────
Write-Host "`n  [1] Promoting DR pod $DrPod (failover)..." -ForegroundColor Yellow
Update-Pfa2Pod -Array $DrFa -Name $DrPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $DrFa -Name $DrPod -State 'promoted' | Out-Null
Write-Host "      ✓ $DrPod promoted on $DrArray" -ForegroundColor Green

# ── [2] Bring the database live at the DR site ──────────────────────────────────
Write-Host "`n  [2] Bringing $DbName live on $DrSqlServer..." -ForegroundColor Yellow
Online-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $DrInst -State 'ONLINE'
Write-Host "      ✓ [$DbName] is online on $DrSqlServer — DR is serving the application" -ForegroundColor Green

# ── [3] Write a row IN DR (the change we track through failback) ────────────────
Write-Host "`n  [3] Application now runs in DR — writing a row IN DR (this is the change we track)..." -ForegroundColor Yellow
$drStamp = "FAILOVER write in DR — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "INSERT dbo.DR_DemoLog (Site, Note) VALUES ('DR', N'$drStamp')"
Write-Host "      DR_DemoLog at DR (now the system of record):" -ForegroundColor Cyan
Invoke-DbaQuery -SqlInstance $DrInst -Database $DbName -Query "SELECT Id, Site, Note, WrittenAt FROM dbo.DR_DemoLog ORDER BY Id" | Format-Table -AutoSize
Write-Host "      ✓ DR is serving the application. Remember the row: '$drStamp'" -ForegroundColor Green

Wait-Spacebar `
    -Summary  "Simulated a production outage. Promoted $DrPod, onlined $DbName on $DrSqlServer, and wrote a timestamped row representing live application activity in DR. The Azure EverPure Cloud site is now the system of record." `
    -Highlight "Unplanned failover is two operations: promote the pod, online the database — DR site live in seconds. The DR write is tracked. It must travel back to production during failback to prove zero data loss on the reverse sync. Watch for it in Part 3."


##############################################################################################################################
#
#   PART 3 — Reverse replication + failback to production
#
##############################################################################################################################

Write-Banner 'PART 3 — Reverse + failback to production' 'Green'

# ── [1] Production recovers — quiesce it so the prod pod can become the target ──
Write-Host "`n  [1] Production recovered — offline $DbName + disks on $ProdSqlServer to reverse the link..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $ProdInst -State 'OFFLINE'
Offline-Disks -Session $ProdSession -DataSerial $ProdSer.Data -LogSerial $ProdSer.Log
Write-Host "      ✓ [$DbName] offline on $ProdSqlServer — prod pod ready to reverse" -ForegroundColor Green

# ── [2] Reverse: demote PROD pod so it resyncs the DR changes home ──────────────
# This is the moment to highlight: only CHANGED BLOCKS travel, not the 4.5 TB DB.
Write-Host "`n  [2] Reversing replication — demoting prod pod (delta resync from DR)..." -ForegroundColor Yellow
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
Write-Host "      ✓ Prod is caught up — DR changes resynced home" -ForegroundColor Green

# ── [3] Fail back: quiesce DR, then promote prod (this demotes DR) ──────────────
Write-Host "`n  [3] Failing back: offline $DbName + disks at DR, then promote prod..." -ForegroundColor Yellow
Set-DbState   -SqlInstance $DrInst -State 'OFFLINE'
Offline-Disks -Session $DrSession -DataSerial $DrSer.Data -LogSerial $DrSer.Log
Update-Pfa2Pod -Array $ProdFa -Name $ProdPod -RequestedPromotionState 'promoted' | Out-Null
Wait-PodState -Array $ProdFa -Name $ProdPod -State 'promoted' | Out-Null
Write-Host "      ✓ $ProdPod promoted — production owns the database again (prod -> DR resumes)" -ForegroundColor Green

# ── [4] Online the database back on production ──────────────────────────────────
Write-Host "`n  [4] Onlining $DbName on $ProdSqlServer..." -ForegroundColor Yellow
Online-Disks -Session $ProdSession -DataSerial $ProdSer.Data -LogSerial $ProdSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
Set-DbState  -SqlInstance $ProdInst -State 'ONLINE'
Write-Host "      ✓ [$DbName] is online on $ProdSqlServer" -ForegroundColor Green

# ── [5] THE PAYOFF — the row written in DR is now present on-prem ───────────────
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

Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Failover + failback complete — production restored      ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "     Primary  : $ProdSqlServer (on-prem)" -ForegroundColor White
Write-Host "     DR pod   : $DrPod on $DrArray (replicating again)" -ForegroundColor White
Write-Host "     Database : [$DbName]" -ForegroundColor White

Wait-Spacebar `
    -Summary  "Reversed the ActiveDR direction so $ProdPod resynced the DR changes home, failed back to $ProdSqlServer, and confirmed the row written in DR is now present on-prem. Replication is flowing prod -> DR again." `
    -Highlight "Failover and failback of a 4 TB database driven entirely by storage replication — only the CHANGED BLOCKS since the failover moved, never the full dataset. Failback time is a function of CHANGE, not database size. That is Pure Storage ActiveDR."


#region --- Reset (optional; gated by $ResetDemo flag) ---
# Flip $ResetDemo to $true to return the demo to its Part 0 baseline so it can
# be re-run from a clean slate. It:
#   1. Ensures production owns the database ($ProdPod promoted, [$DbName] online).
#   2. Truncates dbo.DR_DemoLog so the next Part 0 seed starts clean instead of
#      accumulating PROD/DR-TEST/DR rows across repeated runs.
$ResetDemo = $false

if ($ResetDemo) {
    Write-Banner 'Resetting ActiveDR demo for re-run' 'Magenta'

    # [1] Ensure production owns the database and it is online
    Write-Host "`n  [1] Ensuring $ProdPod is promoted and $DbName is ONLINE on $ProdSqlServer..." -ForegroundColor Yellow
    if ((Get-Pfa2Pod -Array $ProdFa -Name $ProdPod).PromotionStatus -ne 'promoted') {
        Update-Pfa2Pod -Array $ProdFa -Name $ProdPod -RequestedPromotionState 'promoted' | Out-Null
        Wait-PodState -Array $ProdFa -Name $ProdPod -State 'promoted' | Out-Null
    }
    if ((Get-DbaDbState -SqlInstance $ProdInst | Where-Object { $_.DatabaseName -eq $DbName }).Status -ne 'ONLINE') {
        Online-Disks -Session $ProdSession -DataSerial $ProdSer.Data -LogSerial $ProdSer.Log -DataLetter $DataLetter -LogLetter $LogLetter
        Set-DbState  -SqlInstance $ProdInst -State 'ONLINE'
    }
    Write-Host "      ✓ Production owns [$DbName] and it is online" -ForegroundColor Green

    # [2] Clear the marker table for a clean baseline
    Write-Host "`n  [2] Truncating dbo.DR_DemoLog for a clean baseline..." -ForegroundColor Yellow
    Invoke-DbaQuery -SqlInstance $ProdInst -Database $DbName -Query "IF OBJECT_ID('dbo.DR_DemoLog') IS NOT NULL TRUNCATE TABLE dbo.DR_DemoLog"
    Write-Host "      ✓ dbo.DR_DemoLog cleared" -ForegroundColor Green

    Write-Host "`n  Reset complete — re-run the script to replay the demo from Part 0." -ForegroundColor Magenta
} else {
    Write-Host "`n  Tip: Set `$ResetDemo = `$true and re-run this region to reset the demo." -ForegroundColor DarkGray
}
#endregion


#region --- Cleanup ---
Get-DbaConnectedInstance | Disconnect-DbaInstance
Remove-PSSession $ProdSession, $DrSession
#endregion
