#############################################################################
# Setup ActiveDR — replicate aen-sql-25-c's two RDM volumes to Azure
#
# Scenario:
#   aen-sql-25-c has two physical-mode RDM volumes on FlashArray
#   sn1-x90r2-f06-33 holding TPCC-4T (data on E:, log on M:):
#       aen-sql-25-c-E-rdm  (20 TB,  E:, SQLDATA1)
#       aen-sql-25-c-M-rdm  (512 GB, M:, SQLLOG1)
#
#   This sets up ActiveDR (Pure's continuous, near-zero-RPO pod replication) to
#   replicate BOTH volumes to the Azure Pure array (gso-cbs-azure / gso-cbs-azure.fsa.lab)
#   so they can later be iSCSI-attached to aen-sql-25-e.
#
#   Putting both volumes in ONE pod also gives write-order consistency across the
#   data and log volumes — the right foundation for SQL crash-consistency at the
#   DR site.
#
# Scope (PHASE A — what this script does):
#   1. Create a dedicated pod on the source array.
#   2. Move the two RDM volumes into the pod — LIVE and NON-DISRUPTIVE (volume
#      serials are preserved, so aen-sql-25-c's RDM connections keep serving I/O).
#   3. Verify on the guest that E:/M: stayed online and TPCC-4T is healthy.
#   4. Create the ActiveDR pod replica link to the Azure array. This auto-creates a
#      DEMOTED target pod on Azure and begins continuous (baseline) replication.
#   5. Monitor until the link reaches the 'replicating' state, then stop.
#
#   Mounting the replica on aen-sql-25-e is intentionally NOT done here — see the
#   "PHASE B (DEFERRED)" reference block at the bottom of this script.
#
# Run order:
#   1. Run with -WhatIf first to preview every mutating action without changing
#      anything.
#   2. Re-run with -Confirm:$false to perform Phase A.
#
# Prerequisites:
#   - PureStoragePowerShellSDK2 and dbatools installed on this machine.
#   - WinRM access to aen-sql-25-c (Invoke-Command) for the health check.
#   - FA_Cred.xml (FlashArray) and SA_Cred.xml (SQL) in $HOME.
#   - The 'gso-cbs-azure' array connection already exists and is connected on
#     sn1-x90r2-f06-33 (it does — replication transport is already established).
#
# Disclaimer:
#   Provided AS-IS as a building block. TEST in a non-production environment first.
#############################################################################

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    # Bounded wait for baseline replication to reach 'replicating'. A 20 TB baseline
    # over the WAN can take a while; raise if your link is slow.
    [int] $BaselineTimeoutMinutes = 240
)

Import-Module PureStoragePowerShellSDK2
Import-Module dbatools

$ErrorActionPreference = 'Stop'


#region --- Variables ---
$SourceArrayEndpoint = 'sn1-x90r2-f06-33.fsa.lab'   # array hosting aen-sql-25-c + the RDMs
$AzureConnName       = 'gso-cbs-azure'                              # existing array connection -> gso-cbs-azure.fsa.lab
$PodName             = 'aen-sql-25-c-adr'                       # dedicated ActiveDR pod (local / source)
$RemotePodName       = "$PodName-dr"                            # demoted target pod on Azure — MUST differ from the local name
$RdmVolumeNames      = @('aen-sql-25-c-E-rdm', 'aen-sql-25-c-M-rdm')
$SqlServer           = 'aen-sql-25-c'                               # for the post-move health check
$AdrDatabase         = 'TPCC-4T'                               # source DB (lives on D:/L:); its data was cloned onto the E:/M: RDMs
$Credential          = Import-CliXml -Path "$HOME\FA_Cred.xml"
$SqlCredential       = Import-CliXml -Path "$HOME\SA_Cred.xml"
#endregion


#region --- Connect ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  Connecting to source FlashArray...                      ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host "  $SourceArrayEndpoint" -ForegroundColor DarkGray
$src = Connect-Pfa2Array -EndPoint $SourceArrayEndpoint -Credential $Credential -IgnoreCertificateError
#endregion


#region --- [1] Pre-checks (read-only; abort on failure) ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [1] Pre-flight checks                                   ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Resolve each RDM volume by its current (bare or pod-qualified) name and capture serials.
# A volume already in a DIFFERENT pod is a hard stop.
$volSerials = @{}     # bare name -> Pure volume serial (also the guest Get-Disk SerialNumber for a physical RDM)
foreach ($vol in $RdmVolumeNames) {
    $bare = Get-Pfa2Volume -Array $src -Name $vol -ErrorAction SilentlyContinue
    $podQ = Get-Pfa2Volume -Array $src -Name "$PodName::$vol" -ErrorAction SilentlyContinue

    if ($bare) {
        $volSerials[$vol] = $bare.Serial
        if ($bare.Pod.Name -and $bare.Pod.Name -ne $PodName) {
            throw "Volume '$vol' is already in pod '$($bare.Pod.Name)'. Resolve this before continuing."
        }
        # A volume cannot be in both an array-level protection group and a pod, so report
        # its pgroup membership now — it must be removed as part of the move (Step 3).
        $pg = @((Get-Pfa2ProtectionGroupVolume -Array $src -MemberNames $vol -ErrorAction SilentlyContinue).Group.Name)
        Write-Host "  Found $vol  serial $($bare.Serial)  pod=$($bare.Pod.Name)  pgroups=$($pg -join ',')" -ForegroundColor DarkGray
    } elseif ($podQ) {
        $volSerials[$vol] = $podQ.Serial
        Write-Host "  Found $PodName::$vol  serial $($podQ.Serial)  (already moved)" -ForegroundColor DarkGray
    } else {
        throw "Volume '$vol' not found as either '$vol' or '$PodName::$vol' on $SourceArrayEndpoint."
    }
}

# Confirm the Azure array connection is up and capture the remote array name for the replica link.
$azureConn = Get-Pfa2ArrayConnection -Array $src -Name $AzureConnName -ErrorAction SilentlyContinue
if (-not $azureConn) { throw "Array connection '$AzureConnName' not found on $SourceArrayEndpoint." }
if ($azureConn.Status -ne 'connected') {
    throw "Array connection '$AzureConnName' status is '$($azureConn.Status)' (expected 'connected')."
}
$RemoteArrayName = $azureConn.Name
Write-Host "  Azure connection '$AzureConnName' is connected (remote array: $RemoteArrayName)" -ForegroundColor DarkGray
Write-Host "  Target pod: $PodName   Volumes: $($RdmVolumeNames -join ', ')" -ForegroundColor Yellow
if ($WhatIfPreference) {
    Write-Host "`n  -WhatIf: previewing actions only. Re-run with -Confirm:`$false to execute.`n" -ForegroundColor Magenta
}
#endregion


#region --- [2] Create the dedicated pod ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [2] Create ActiveDR pod                                 ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
$existingPod = Get-Pfa2Pod -Array $src -Name $PodName -ErrorAction SilentlyContinue
if ($existingPod) {
    Write-Host "  Pod $PodName already exists — reusing." -ForegroundColor DarkGray
} elseif ($PSCmdlet.ShouldProcess($PodName, "New-Pfa2Pod")) {
    New-Pfa2Pod -Array $src -Name $PodName | Out-Null
    Write-Host "  ✓ Created pod $PodName" -ForegroundColor Green
}
#endregion


#region --- [3] Move the RDM volumes into the pod (live, non-disruptive) ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [3] Move RDM volumes into the pod (non-disruptive)      ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
# Moving a volume into a pod preserves its serial, so aen-sql-25-c keeps serving I/O.
# The volume name becomes '<pod>::<volume>'.
foreach ($vol in $RdmVolumeNames) {
    $bare = Get-Pfa2Volume -Array $src -Name $vol -ErrorAction SilentlyContinue
    if ($bare -and $bare.Pod.Name -eq $PodName) {
        Write-Host "  $vol already in $PodName — skipping." -ForegroundColor DarkGray
        continue
    }
    if (-not $bare) {
        # Not present under the bare name → already moved to $PodName::$vol.
        Write-Host "  $vol already moved ($PodName::$vol) — skipping." -ForegroundColor DarkGray
        continue
    }
    # A volume cannot be in both an array-level pgroup and a pod. Purity requires the
    # FULL pgroup membership to be listed on the move, so discover it and remove it here.
    $pgNames = @((Get-Pfa2ProtectionGroupVolume -Array $src -MemberNames $vol -ErrorAction SilentlyContinue).Group.Name)
    $moveDesc = if ($pgNames) {
        "Update-Pfa2Volume -PodName $PodName -RemoveFromProtectionGroupNames $($pgNames -join ',') (move into pod)"
    } else {
        "Update-Pfa2Volume -PodName $PodName (move into pod)"
    }
    if ($PSCmdlet.ShouldProcess($vol, $moveDesc)) {
        Write-Host "  Moving $vol into $PodName..." -ForegroundColor Yellow
        if ($pgNames) {
            Write-Host "    Removing from protection group(s): $($pgNames -join ', ')" -ForegroundColor DarkGray
            Update-Pfa2Volume -Array $src -Name $vol -PodName $PodName -RemoveFromProtectionGroupNames $pgNames | Out-Null
        } else {
            Update-Pfa2Volume -Array $src -Name $vol -PodName $PodName | Out-Null
        }
        Write-Host "    ✓ $vol -> $PodName::$vol" -ForegroundColor Green
    }
}
#endregion


#region --- [4] Verify non-disruption on aen-sql-25-c ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [4] Verify E:/M: and TPCC-4T are unaffected         ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  -WhatIf: skipping guest health check (nothing was moved)." -ForegroundColor Magenta
} else {
    $serials = @($volSerials.Values)
    Write-Host "  Checking guest disks (by serial) on $SqlServer..." -ForegroundColor Yellow
    Invoke-Command -ComputerName $SqlServer -ScriptBlock {
        Get-Disk | Where-Object { $_.SerialNumber -in $using:serials } |
            Select-Object Number,
                @{n='SizeGB';e={[math]::Round($_.Size/1GB)}},
                IsOffline, SerialNumber,
                @{n='DriveLetter';e={ (Get-Partition -DiskNumber $_.Number | Where-Object DriveLetter).DriveLetter -join ',' }} |
            Sort-Object Number | Format-Table -AutoSize
    }

    Write-Host "  Checking $AdrDatabase state..." -ForegroundColor Yellow
    $inst = Connect-DbaInstance -SqlInstance "$SqlServer,1433" -SqlCredential $SqlCredential -TrustServerCertificate
    Get-DbaDbState -SqlInstance $inst | Where-Object { $_.DatabaseName -eq $AdrDatabase } |
        Format-Table DatabaseName, Status -AutoSize

    $dbState = (Get-DbaDbState -SqlInstance $inst | Where-Object { $_.DatabaseName -eq $AdrDatabase }).Status
    if ($dbState -ne 'ONLINE') {
        throw "$AdrDatabase is '$dbState' after the volume move (expected ONLINE). Stopping before the replica link is created."
    }
    Write-Host "  ✓ E:/M: serials unchanged and $AdrDatabase is ONLINE — move was non-disruptive." -ForegroundColor Green
}
#endregion


#region --- [5] Create the ActiveDR pod replica link ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [5] Create ActiveDR replica link to Azure               ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
# Creating the link auto-creates a DEMOTED target pod on the Azure array and begins
# continuous (baseline) replication over the existing gso-cbs-azure connection.
$existingLink = Get-Pfa2PodReplicaLink -Array $src -LocalPodName $PodName -ErrorAction SilentlyContinue
if ($existingLink) {
    Write-Host "  Replica link for $PodName already exists (status: $($existingLink.Status)) — skipping create." -ForegroundColor DarkGray
} elseif ($PSCmdlet.ShouldProcess("$PodName -> $RemoteArrayName::$RemotePodName", "New-Pfa2PodReplicaLink")) {
    # A pod cannot be stretched while it contains a protection group with hosts, host
    # groups, or targets. Volumes often inherit a pod-scoped 'pgroup-auto' carrying the
    # array's default replication target — clear those targets first.
    foreach ($pg in (Get-Pfa2ProtectionGroup -Array $src -Filter "pod.name='$PodName'" -ErrorAction SilentlyContinue)) {
        foreach ($tgt in (Get-Pfa2ProtectionGroupTarget -Array $src -GroupNames $pg.Name -ErrorAction SilentlyContinue)) {
            Write-Host "  Clearing target $($tgt.Member.Name) from in-pod pgroup $($pg.Name)..." -ForegroundColor DarkGray
            Remove-Pfa2ProtectionGroupTarget -Array $src -GroupNames $pg.Name -MemberNames $tgt.Member.Name | Out-Null
        }
    }
    # The remote pod name MUST differ from the local pod name for an ActiveDR link.
    Write-Host "  Creating replica link $PodName -> $RemoteArrayName::$RemotePodName..." -ForegroundColor Yellow
    New-Pfa2PodReplicaLink -Array $src `
        -LocalPodName  $PodName `
        -RemoteName    $RemoteArrayName `
        -RemotePodName $RemotePodName | Out-Null
    Write-Host "  ✓ Replica link created — Azure now has a demoted '$RemotePodName' and baseline replication has begun" -ForegroundColor Green
}
#endregion


#region --- [6] Monitor baseline replication (bounded wait) ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [6] Monitor until link reaches 'replicating'            ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
if ($WhatIfPreference) {
    Write-Host "  -WhatIf: skipping replication monitor (no link was created)." -ForegroundColor Magenta
} else {
    $deadline = (Get-Date).AddMinutes($BaselineTimeoutMinutes)
    do {
        Start-Sleep -Seconds 15
        $link   = Get-Pfa2PodReplicaLink -Array $src -LocalPodName $PodName
        $status = $link.Status
        Write-Host "  status=$status   recovery point=$($link.RecoveryPoint)" -ForegroundColor DarkGray
        if ((Get-Date) -gt $deadline) {
            Write-Warning "  Baseline did not reach 'replicating' within $BaselineTimeoutMinutes minute(s)."
            Write-Warning "  Replication continues in the background — re-check with: Get-Pfa2PodReplicaLink -Array `$src -LocalPodName '$PodName'"
            break
        }
    } while ($status -ne 'replicating')
    if ($status -eq 'replicating') {
        Write-Host "  ✓ Link is replicating — recovery point $($link.RecoveryPoint)" -ForegroundColor Green
    }
}
#endregion


#region --- Summary ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Phase A complete — ActiveDR replicating to Azure        ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "  Pod          : $PodName (promoted on $SourceArrayEndpoint)" -ForegroundColor White
Write-Host "  Volumes      : $(( $RdmVolumeNames | ForEach-Object { "$PodName::$_" }) -join ', ')" -ForegroundColor White
Write-Host "  Replicating  : -> $RemoteArrayName (demoted '$RemotePodName')" -ForegroundColor White
Write-Host "  Next         : mount on aen-sql-25-e (PHASE B — see reference block below)" -ForegroundColor White
#endregion


<#
=============================================================================
 PHASE B (DEFERRED) — Mount the replica on aen-sql-25-e   [NOT executed here]
=============================================================================
 Storage-only, reusing aen-sql-25-e's existing EPC iSCSI host object. First open a
 connection to the Azure array ($az = Connect-Pfa2Array -EndPoint gso-cbs-azure.fsa.lab ...),
 or run these from a host that can reach it, since Phase B MUTATES the Azure array.

 Decide ONE of:

   (a) PROMOTE (true failover — volumes become read-write, replication flips):
       Update-Pfa2Pod -Array $az -Name 'aen-sql-25-c-adr-dr' `
           -RequestedPromotionState 'promoted'

   (b) NON-DISRUPTIVE CLONE / DR TEST (keeps replication + RPO intact):
       Snapshot the demoted pod's volumes into a test pod / new volumes on the
       Azure array, then connect the CLONES to aen-sql-25-e instead of the live
       replica targets. (See ADR_Testing/ActiveDR-Failover-Test.ps1.)

 Then, on the Azure array:
   # Reuse aen-sql-25-e's existing EPC iSCSI host object (the one EPC created for
   # gso-an-win-1-SQLDATA1 / -SQLLOG1). Discover it by matching the guest IQN:
   #   Invoke-Command -HostName aen-sql-25-e -SSHTransport ... { (Get-InitiatorPort).NodeAddress }
   $epcHost = (Get-Pfa2Host -Array $az | Where-Object { $_.Iqns -contains $eIqn }).Name
   New-Pfa2Connection -Array $az -HostName $epcHost `
       -VolumeNames 'aen-sql-25-c-adr-dr::aen-sql-25-c-E-rdm',
                    'aen-sql-25-c-adr-dr::aen-sql-25-c-M-rdm'

 Then, on aen-sql-25-e (SSH remoting — see Invoke-AGSeedFromSnapshot-sql25.ps1):
   # iSCSI rescan, online the new disks by serial, assign E:/M:. STORAGE ONLY —
   # do NOT attach the database (per agreed scope).
   Update-HostStorageCache
   Get-Disk | Where-Object SerialNumber -in $eMSerials | Set-Disk -IsOffline $false
   # ...assign drive letters E: and M:
=============================================================================
#>
