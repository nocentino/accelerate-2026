#############################################################################
# Convert vVols to physical-mode RDMs — aen-sql-25-c (E: and M: drives only)
#
# Scenario:
#   aen-sql-25-c currently has its E: and M: drives on Pure Storage vVols.
#   This converts ONLY those two drives to physical-mode Raw Device Mappings
#   (RDMs), preserving the data via a block-level FlashArray volume copy.
#   All other drives on the VM are left untouched.
#
# Approach (per drive):
#   1. Identify the vVol backing volume for the drive via the VASA PURE_VVOL_ID
#      tag -> vSphere BackingObjectId match (same technique as
#      Get-DriveLetterVVolMapping.ps1).
#   2. Offline the affected SQL databases (those with files on E:/M:) so the
#      filesystem is quiesced and the copy is clean.
#   3. Offline the old vVol disk in Windows (flush NTFS).
#   4. FlashArray: create a NEW standard volume as an instant copy of the vVol
#      backing volume (New-Pfa2Volume -SourceName). The copy is byte-identical,
#      so it already contains the partition table, NTFS filesystem, drive letter
#      and data.
#   5. Connect the new volume to the ESXi cluster's host group.
#   6. Rescan HBAs, then attach the new volume to the VM as a PHYSICAL-mode RDM.
#   7. Online the new RDM disk in Windows; it mounts as E:/M: with all data.
#   8. Bring the affected databases back online.
#
# The OLD vVol disks are LEFT IN PLACE (still attached to the VM but offline in
# Windows). Decommission them manually after verifying — see the notes printed
# in the summary at the end.
#
# Run order:
#   1. Run with -WhatIf first to preview the full conversion plan and every
#      mutating action without changing anything.
#   2. Re-run without -WhatIf to perform the conversion.
#
# Prerequisites:
#   - PowerCLI, PureStoragePowerShellSDK2 and dbatools installed.
#   - WinRM access to aen-sql-25-c (Invoke-Command).
#   - FA_Cred.xml (FlashArray) and SA_Cred.xml (SQL) in $HOME.
#   - The ESXi cluster hosts running aen-sql-25-c are already in a single
#     FlashArray host group (they are — that is how the vVols are presented).
#
# Disclaimer:
#   Provided AS-IS as a building block. TEST in a non-production environment
#   first. This script changes storage presentation and offlines databases.
#############################################################################

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

Import-Module PureStoragePowerShellSDK2
# Import VimAutomation.Core directly (not the VMware.PowerCLI meta-module): two
# PowerCLI versions are installed (13.3.0 + 13.4.0) and the 13.3 meta-module fails
# on a VMware.Vim version mismatch. Pin to the 13.4 build whose VMware.Vim is present.
Import-Module VMware.VimAutomation.Core -RequiredVersion 13.4.0.24798382
Import-Module dbatools

$ErrorActionPreference = 'Stop'


#region --- Variables ---
$VmName             = 'aen-sql-25-c'
$VCenterServer      = 'vc01.fsa.lab'
$FlashArrayEndpoint = 'sn1-x90r2-f06-33.fsa.lab'   # array hosting aen-sql-25-c
$Credential         = Import-CliXml -Path "$HOME\FA_Cred.xml"
$SqlCredential      = Import-CliXml -Path "$HOME\SA_Cred.xml"
$SqlPort            = 1433

# Drives to convert. Everything else on the VM is left alone.
$DriveLettersToConvert = @('E', 'M')

# New standard FlashArray volumes are named <vm>-<letter>-rdm (top-level, NOT in
# the vVol volume group). Adjust the template to match your naming convention.
$RdmVolumeNameFormat = '{0}-{1}-rdm'    # e.g. aen-sql-25-c-E-rdm

# VASA namespace where Purity stores the VMware vVol tags.
$vasaNamespace = 'vasa-integration.purestorage.com'

# Datastore for the RDM pointer (mapping) VMDK. RDM pointers MUST live on a VMFS
# datastore (NOT NFS — fails with RdmBackingOnUnsupportedDs — and NOT a vVol
# datastore). Leave $null to auto-pick the VMFS datastore with the most free space
# visible to the VM's host. Set explicitly to co-locate on the VM's own array.
$RdmPointerDatastore = 'sn1-x90r2-f06-33-vc01-ds01'

# Optional override: FlashArray host group the new volumes are connected to.
# Leave $null to auto-discover from the VM's ESXi cluster (matched by HBA WWN/IQN).
$HostGroupNameOverride = $null
#endregion



#region --- Connect ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  Connecting to FlashArray, vCenter and SQL Server...     ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

Write-Host "  Connecting to FlashArray $FlashArrayEndpoint..." -ForegroundColor Cyan
$FA = Connect-Pfa2Array -EndPoint $FlashArrayEndpoint -Credential $Credential -IgnoreCertificateError

Write-Host "  Connecting to vCenter $VCenterServer..." -ForegroundColor Cyan
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false -WhatIf:$false | Out-Null
Connect-VIServer -Server $VCenterServer -Credential $Credential | Out-Null

Write-Host "  Connecting to SQL instance $VmName,$SqlPort..." -ForegroundColor Cyan
$SqlInstance = Connect-DbaInstance -SqlInstance "$VmName,$SqlPort" -SqlCredential $SqlCredential -TrustServerCertificate

# WinRM session to the guest for disk online/offline operations.
$GuestSession = New-PSSession -ComputerName $VmName
#endregion



#region --- Discover the FlashArray host group for the VM's ESXi cluster ---
# RDM volumes must be connected to every ESXi host that could run the VM, i.e. the
# whole cluster's host group. Discover it by matching ESXi HBA WWNs/IQNs to FA hosts.
Write-Host "`n  Resolving ESXi cluster host group on the FlashArray..." -ForegroundColor Cyan

$VM       = Get-VM -Name $VmName
$VMHost   = $VM.VMHost
$Cluster  = $VMHost | Get-Cluster
$ClusterHosts = $Cluster | Get-VMHost
Write-Host "    VM host : $($VMHost.Name)    Cluster : $($Cluster.Name)" -ForegroundColor DarkGray

if ($HostGroupNameOverride) {
    $HostGroupName = $HostGroupNameOverride
    Write-Host "    Using host group override: $HostGroupName" -ForegroundColor DarkGray
} else {
    # Collect normalized port identifiers (FC WWNs and iSCSI IQNs) from the cluster's ESXi hosts.
    $esxiPorts = foreach ($h in $ClusterHosts) {
        foreach ($hba in (Get-VMHostHba -VMHost $h)) {
            if ($hba.Type -eq 'FibreChannel' -and $hba.PortWorldWideName) {
                # Int64 WWN -> 16 lowercase hex chars
                ('{0:x16}' -f $hba.PortWorldWideName)
            } elseif ($hba.Type -eq 'IScsi' -and $hba.IScsiName) {
                $hba.IScsiName.ToLower()
            }
        }
    }
    $esxiPorts = $esxiPorts | Sort-Object -Unique

    # Match against FA hosts; collect their host groups.
    $faHosts = Get-Pfa2Host -Array $FA
    $matchedGroups = foreach ($fh in $faHosts) {
        $faPorts = @()
        if ($fh.Wwns) { $faPorts += ($fh.Wwns | ForEach-Object { ($_ -replace '[:\-]', '').ToLower() }) }
        if ($fh.Iqns) { $faPorts += ($fh.Iqns | ForEach-Object { $_.ToLower() }) }
        if ($faPorts | Where-Object { $esxiPorts -contains $_ }) {
            $fh.HostGroup.Name
        }
    }
    $matchedGroups = $matchedGroups | Where-Object { $_ } | Sort-Object -Unique

    # In a fleet, the same host group is also surfaced as a remote-context entry
    # named 'sourcearray:groupname'. The new volume lives on the LOCAL array, so
    # prefer the unprefixed (local) host group and ignore remote-context views.
    $localGroups   = $matchedGroups | Where-Object { $_ -notmatch ':' }
    $HostGroupName = if ($localGroups) { $localGroups } else { $matchedGroups }

    if (-not $HostGroupName) {
        throw "Could not auto-discover a FlashArray host group for cluster '$($Cluster.Name)'. " +
              "Set `$HostGroupNameOverride and re-run."
    }
    if (@($HostGroupName).Count -gt 1) {
        throw "Cluster '$($Cluster.Name)' hosts map to multiple local FA host groups: $($HostGroupName -join ', '). " +
              "Set `$HostGroupNameOverride to the correct one and re-run."
    }
    Write-Host "    Discovered host group: $HostGroupName" -ForegroundColor DarkGray
}

# Resolve the RDM pointer datastore (VMFS/NFS only — never a vVol datastore).
if ($RdmPointerDatastore) {
    $PointerDS = Get-Datastore -Name $RdmPointerDatastore
} else {
    $PointerDS = $VMHost | Get-Datastore |
        Where-Object { $_.Type -eq 'VMFS' } |
        Sort-Object FreeSpaceGB -Descending |
        Select-Object -First 1
    if (-not $PointerDS) {
        throw "No VMFS datastore visible to $($VMHost.Name) for the RDM pointer VMDK. " +
              "Set `$RdmPointerDatastore and re-run."
    }
}
Write-Host "    RDM pointer datastore: $($PointerDS.Name) ($([math]::Round($PointerDS.FreeSpaceGB))GB free)" -ForegroundColor DarkGray
#endregion



#region --- Build the conversion plan (drive letter -> vVol backing volume) ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  Building conversion plan for $($DriveLettersToConvert -join ', ') drive(s)...                   ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# All volumes in this VM's vVol volume group (single array, so no fleet fan-out needed).
$vgVolumes = Get-Pfa2Volume -Array $FA -Filter "name='vvol-$VmName*'"
if (-not $vgVolumes) { throw "No vVols found for $VmName on $FlashArrayEndpoint." }

# VASA tags: PURE_VVOL_ID matches the vSphere BackingObjectId (rfc4122.<uuid>).
$vasaResults = foreach ($vol in $vgVolumes) {
    $tags = Get-Pfa2VolumeTag -Array $FA -ResourceNames $vol.Name -Namespaces $vasaNamespace
    [PSCustomObject]@{
        PureVolumeName = $vol.Name
        Serial         = $vol.Serial
        ProvisionedGB  = [math]::Round($vol.Provisioned / 1GB, 0)
        PURE_VVOL_ID   = ($tags | Where-Object { $_.Key -eq 'PURE_VVOL_ID' }).Value
        VMW_VVolType   = ($tags | Where-Object { $_.Key -eq 'VMW_VVolType' }).Value
    }
}

# vSphere disks (sorted by Id) + their backing UUIDs.
$vSphereDisks = $VM | Get-HardDisk | Sort-Object Id | ForEach-Object {
    [PSCustomObject]@{
        HardDisk       = $_
        HardDiskName   = $_.Name
        VSphereDiskKey = $_.ExtensionData.Key
        CapacityGB     = $_.CapacityGB
        BackingUUID    = $_.ExtensionData.Backing.BackingObjectId
    }
}

# A vVol-backed disk exposes a VMware virtual-disk serial to the guest (6000c29...),
# NOT the Pure volume serial — only the underlying vVol carries PURE_VVOL_ID. So map
# drive letter -> vVol by positionally aligning the vSphere hard disks (sorted by Id)
# with the guest physical disks (sorted by PhysicalLocation, DeviceID), then matching
# PURE_VVOL_ID -> BackingObjectId. Same technique as Get-DriveLetterVVolMapping.ps1.
$partitions = Invoke-Command -Session $GuestSession -ScriptBlock {
    Get-Partition | Where-Object { $_.DriveLetter -and $_.DriveLetter -ne [char]0 } |
        Select-Object DriveLetter, DiskNumber
}
$windowsDisks = Invoke-Command -Session $GuestSession -ScriptBlock {
    Get-PhysicalDisk | Sort-Object PhysicalLocation, DeviceID | Select-Object DeviceID
}
$diskNumToDrive = @{}
foreach ($p in $partitions) { $diskNumToDrive["$($p.DiskNumber)"] = "$($p.DriveLetter)" }

# Full positional drive-letter -> vVol map.
$allMappings = for ($i = 0; $i -lt $vSphereDisks.Count; $i++) {
    $bareUuid  = $vSphereDisks[$i].BackingUUID -replace '^rfc4122\.', ''
    $pureVol   = $vasaResults | Where-Object { ($_.PURE_VVOL_ID -replace '^rfc4122\.', '') -eq $bareUuid }
    $winDiskId = $windowsDisks[$i].DeviceID
    [PSCustomObject]@{
        DriveLetter   = $diskNumToDrive["$winDiskId"]
        DiskNumber    = $winDiskId
        VVolName      = $pureVol.PureVolumeName
        ProvisionedGB = $pureVol.ProvisionedGB
        VMW_VVolType  = $pureVol.VMW_VVolType
        HardDisk      = $vSphereDisks[$i].HardDisk
        HardDiskName  = $vSphereDisks[$i].HardDiskName
        BackingUUID   = $vSphereDisks[$i].BackingUUID
    }
}

# Filter to the target drive letters and build the conversion plan.
$conversionPlan = foreach ($letter in $DriveLettersToConvert) {
    $m = $allMappings | Where-Object { $_.DriveLetter -eq $letter }
    if (-not $m) {
        Write-Warning "  Drive ${letter}: not found on $VmName — skipping."
        continue
    }
    if (-not $m.VVolName) {
        Write-Warning "  Drive ${letter}: (disk $($m.DiskNumber)) did not resolve to a vVol — skipping."
        continue
    }

    [PSCustomObject]@{
        DriveLetter     = "${letter}:"
        DiskNumber      = [int]$m.DiskNumber
        OldVVolName     = $m.VVolName
        ProvisionedGB   = $m.ProvisionedGB
        OldHardDisk     = $m.HardDisk
        OldHardDiskName = $m.HardDiskName
        BackingUUID     = $m.BackingUUID
        NewVolumeName   = ($RdmVolumeNameFormat -f $VmName, $letter)
    }
}

if (-not $conversionPlan) { throw "No drives resolved for conversion. Nothing to do." }

# Which databases have files on the target drives? These get offlined during the swap.
$targetDriveRoots = $conversionPlan.DriveLetter   # e.g. 'E:', 'M:'
$dbFiles = Get-DbaDbFile -SqlInstance $SqlInstance |
    Where-Object { $_.Database -notin 'master', 'model', 'msdb', 'tempdb' }
$AffectedDatabases = $dbFiles |
    Where-Object { $_.PhysicalName -and ("$($_.PhysicalName[0]):" -in $targetDriveRoots) } |
    Select-Object -ExpandProperty Database -Unique |
    Sort-Object

Write-Host "`n  === Conversion plan for $VmName ===" -ForegroundColor Green
$conversionPlan |
    Select-Object DriveLetter, DiskNumber, ProvisionedGB, OldVVolName, NewVolumeName, OldHardDiskName |
    Format-Table -AutoSize
Write-Host "  Databases to offline during cutover: $((($AffectedDatabases) -join ', '))" -ForegroundColor Yellow
Write-Host "  RDM mode: Physical (pass-through)   Host group: $HostGroupName   Pointer DS: $($PointerDS.Name)" -ForegroundColor Yellow
Write-Host "  Old vVol disks will be LEFT IN PLACE (attached, offline) for manual decommission." -ForegroundColor Yellow

if ($WhatIfPreference) {
    Write-Host "`n  -WhatIf: previewing actions only. Re-run without -WhatIf to perform the conversion.`n" -ForegroundColor Magenta
}
#endregion



#region --- [1] Offline affected databases ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [1] Offlining affected databases...                     ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
foreach ($db in $AffectedDatabases) {
    if ($PSCmdlet.ShouldProcess($db, "SET OFFLINE WITH ROLLBACK IMMEDIATE")) {
        Write-Host "  Offlining [$db]..." -ForegroundColor Yellow
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database master `
            -Query "ALTER DATABASE [$db] SET OFFLINE WITH ROLLBACK IMMEDIATE"
        Write-Host "    ✓ [$db] offline" -ForegroundColor Green
    }
}
#endregion



#region --- [2..7] Per-drive conversion ---
foreach ($plan in $conversionPlan) {
    Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host   "║  Converting $($plan.DriveLetter) drive  (vVol -> physical RDM)              ║" -ForegroundColor Cyan
    Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host "    Old vVol : $($plan.OldVVolName)" -ForegroundColor DarkGray
    Write-Host "    New vol  : $($plan.NewVolumeName)" -ForegroundColor DarkGray

    # ── [2] Offline the old vVol disk in Windows (flush NTFS for a clean copy) ──
    if ($PSCmdlet.ShouldProcess("$VmName disk $($plan.DiskNumber) ($($plan.DriveLetter))", "Set-Disk -IsOffline `$true")) {
        Write-Host "  [2] Offlining old disk $($plan.DiskNumber) in guest..." -ForegroundColor Yellow
        Invoke-Command -Session $GuestSession -ScriptBlock {
            Set-Disk -Number $using:plan.DiskNumber -IsOffline $true
        }
        Write-Host "    ✓ Old disk offline" -ForegroundColor Green
    }

    # ── [3] FlashArray: clone the vVol backing volume into a new standard volume ──
    if ($PSCmdlet.ShouldProcess($plan.NewVolumeName, "New-Pfa2Volume -SourceName $($plan.OldVVolName) (instant copy)")) {
        # Idempotent: reuse the clone if a prior run already created it.
        $newVol = Get-Pfa2Volume -Array $FA -Name $plan.NewVolumeName -ErrorAction SilentlyContinue
        if ($newVol) {
            Write-Host "  [3] Volume $($plan.NewVolumeName) already exists — reusing (serial $($newVol.Serial))." -ForegroundColor DarkGray
        } else {
            Write-Host "  [3] Creating new volume $($plan.NewVolumeName) as a copy of the vVol..." -ForegroundColor Yellow
            $newVol = New-Pfa2Volume -Array $FA -Name $plan.NewVolumeName -SourceName $plan.OldVVolName
            Write-Host "    ✓ Created $($newVol.Name)  serial $($newVol.Serial)" -ForegroundColor Green
        }
    } else {
        # -WhatIf: read the (not-yet-created) volume info if it happens to exist, else fabricate for preview.
        $newVol = Get-Pfa2Volume -Array $FA -Name $plan.NewVolumeName -ErrorAction SilentlyContinue
    }

    # ── [4] Connect the new volume to the cluster host group ──
    if ($PSCmdlet.ShouldProcess("$($plan.NewVolumeName) -> host group $HostGroupName", "New-Pfa2Connection")) {
        # Idempotent: skip if a prior run already connected it.
        $existingConn = Get-Pfa2Connection -Array $FA -HostGroupNames $HostGroupName -VolumeNames $plan.NewVolumeName -ErrorAction SilentlyContinue
        if ($existingConn) {
            Write-Host "  [4] $($plan.NewVolumeName) already connected to $HostGroupName — skipping." -ForegroundColor DarkGray
        } else {
            Write-Host "  [4] Connecting $($plan.NewVolumeName) to host group $HostGroupName..." -ForegroundColor Yellow
            New-Pfa2Connection -Array $FA -HostGroupNames $HostGroupName -VolumeNames $plan.NewVolumeName | Out-Null
            Write-Host "    ✓ Connected" -ForegroundColor Green
        }
    }

    # ── [5] Rescan ESXi HBAs so the new LUN is visible ──
    if ($PSCmdlet.ShouldProcess("cluster $($Cluster.Name)", "Rescan all HBAs / VMFS")) {
        Write-Host "  [5] Rescanning storage on cluster hosts..." -ForegroundColor Yellow
        $ClusterHosts | Get-VMHostStorage -RescanAllHba -RescanVmfs | Out-Null
        Write-Host "    ✓ Rescan complete" -ForegroundColor Green
    }

    # ── [6] Attach the new volume to the VM as a PHYSICAL-mode RDM ──
    # Discover the ESXi canonical name by matching the FA volume serial (no fixed
    # naa-prefix assumption) — the canonical name is what New-HardDisk -DeviceName needs.
    if ($PSCmdlet.ShouldProcess($VmName, "Add physical RDM for $($plan.NewVolumeName) (pointer on $($PointerDS.Name))")) {
        $newSerialLower = $newVol.Serial.ToLower()
        $lun = $null
        for ($t = 0; $t -lt 15 -and -not $lun; $t++) {
            $lun = $VMHost | Get-ScsiLun -LunType disk -ErrorAction SilentlyContinue |
                Where-Object { $_.CanonicalName.ToLower().EndsWith($newSerialLower) } |
                Select-Object -First 1
            if (-not $lun) { Start-Sleep -Seconds 2; $ClusterHosts | Get-VMHostStorage -RescanAllHba | Out-Null }
        }
        if (-not $lun) {
            throw "New volume $($plan.NewVolumeName) (serial $($newVol.Serial)) did not appear as a SCSI disk on $($VMHost.Name) after rescan."
        }
        $devicePath = "/vmfs/devices/disks/$($lun.CanonicalName)"
        # Idempotent: skip if this RDM is already attached to the VM.
        $existingRdm = Get-HardDisk -VM $VM | Where-Object { $_.ScsiCanonicalName -eq $lun.CanonicalName }
        if ($existingRdm) {
            Write-Host "  [6] RDM $($lun.CanonicalName) already attached to $VmName — skipping." -ForegroundColor DarkGray
        } else {
            Write-Host "  [6] Adding physical RDM to $VmName ($($lun.CanonicalName))..." -ForegroundColor Yellow
            New-HardDisk -VM $VM -DiskType RawPhysical -DeviceName $devicePath -Datastore $PointerDS | Out-Null
            Write-Host "    ✓ RDM attached" -ForegroundColor Green
        }
    }

    # ── [7] Online the new RDM disk in the guest; assign the drive letter ──
    if ($PSCmdlet.ShouldProcess("$VmName ($($plan.DriveLetter))", "Online new RDM disk, assign drive letter")) {
        Write-Host "  [7] Onlining new RDM disk in guest and assigning $($plan.DriveLetter)..." -ForegroundColor Yellow
        $newSerial      = $newVol.Serial
        $wantDriveLetter = $plan.DriveLetter.TrimEnd(':')
        Invoke-Command -Session $GuestSession -ScriptBlock {
            # Rescan so the new RDM disk appears, then locate it by FA volume serial.
            Update-HostStorageCache
            $disk = $null
            for ($i = 0; $i -lt 30 -and -not $disk; $i++) {
                $disk = Get-Disk | Where-Object { $_.SerialNumber -eq $using:newSerial }
                if (-not $disk) { Start-Sleep -Seconds 2 }
            }
            if (-not $disk) { throw "New RDM disk (serial $using:newSerial) did not appear in the guest." }

            Set-Disk -Number $disk.Number -IsReadOnly $false
            Set-Disk -Number $disk.Number -IsOffline  $false

            # The clone carries the original partition + drive letter. Force the
            # intended letter in case Windows assigned a different one on import.
            $part = Get-Partition -DiskNumber $disk.Number |
                        Where-Object { $_.Type -eq 'Basic' -or $_.DriveLetter } |
                        Sort-Object Size -Descending | Select-Object -First 1
            if ($part.DriveLetter -ne $using:wantDriveLetter) {
                Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber `
                    -NewDriveLetter $using:wantDriveLetter
            }
        }
        Write-Host "    ✓ New RDM online as $($plan.DriveLetter)" -ForegroundColor Green
    }

    Write-Host "  ── $($plan.DriveLetter) converted. Old vVol disk left attached + offline. ──" -ForegroundColor Cyan
}
#endregion



#region --- [8] Bring affected databases back online ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host   "║  [8] Bringing affected databases back online...          ║" -ForegroundColor Cyan
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
foreach ($db in $AffectedDatabases) {
    if ($PSCmdlet.ShouldProcess($db, "SET ONLINE")) {
        Write-Host "  Onlining [$db]..." -ForegroundColor Yellow
        Invoke-DbaQuery -SqlInstance $SqlInstance -Database master -Query "ALTER DATABASE [$db] SET ONLINE"
        Write-Host "    ✓ [$db] online" -ForegroundColor Green
    }
}
#endregion



#region --- Verify ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Verification                                            ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green

if (-not $WhatIfPreference) {
    Write-Host "`n  Guest disks (E:/M: should now be the new RDM serials):" -ForegroundColor Cyan
    Invoke-Command -Session $GuestSession -ScriptBlock {
        Get-Partition | Where-Object { $_.DriveLetter } |
            Select-Object DriveLetter, DiskNumber,
                @{n='SizeGB';e={[math]::Round($_.Size/1GB)}} |
            Sort-Object DriveLetter | Format-Table -AutoSize
    }

    Write-Host "  Database states:" -ForegroundColor Cyan
    Get-DbaDbState -SqlInstance $SqlInstance |
        Where-Object { $_.DatabaseName -in $AffectedDatabases } |
        Select-Object DatabaseName, Status | Format-Table -AutoSize
}
#endregion



#region --- Summary + manual decommission notes ---
Write-Host "`n╔══════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host   "║  Conversion complete                                     ║" -ForegroundColor Green
Write-Host   "╚══════════════════════════════════════════════════════════╝" -ForegroundColor Green
foreach ($plan in $conversionPlan) {
    Write-Host "  $($plan.DriveLetter)  $($plan.OldVVolName)  ->  $($plan.NewVolumeName) (physical RDM)" -ForegroundColor White
}
Write-Host "`n  OLD vVol disks are still attached to $VmName and OFFLINE in Windows." -ForegroundColor Yellow
Write-Host "  After you have verified E: and M: are healthy on the new RDMs, decommission them:" -ForegroundColor Yellow
Write-Host "    1. vSphere: remove the old vVol hard disk(s) from the VM" -ForegroundColor DarkGray
Write-Host "       (DO NOT check 'Delete files from datastore' if you want the vVol kept)." -ForegroundColor DarkGray
foreach ($plan in $conversionPlan) {
    Write-Host "         old hard disk: $($plan.OldHardDiskName)  (vVol $($plan.OldVVolName))" -ForegroundColor DarkGray
}
Write-Host "    2. FlashArray: once the vVol is unreferenced, destroy it if desired:" -ForegroundColor DarkGray
foreach ($plan in $conversionPlan) {
    Write-Host "         Remove-Pfa2Volume -Array `$FA -Name '$($plan.OldVVolName)'  # then Remove-Pfa2VolumeEradicate to purge" -ForegroundColor DarkGray
}
#endregion



#region --- Cleanup ---
Remove-PSSession $GuestSession
#endregion
