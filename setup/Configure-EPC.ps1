<#
.SYNOPSIS
    Configures Pure Storage EPC iSCSI volumes on a Windows Azure VM
    for use as SQL Server data and log storage.

.DESCRIPTION
    Run directly on the VM (or via Azure Run Command from New-SqlServerVM.ps1).
    It performs the following steps:
      1. Installs the PureStoragePowershellSDK2 module.
      2. Enables and starts the Windows iSCSI initiator service.
      3. Connects to the EPC array and creates a host record for this VM.
      4. Provisions two volumes: SQLData, SQLLog.
      5. Connects those volumes to the host.
      6. Connects EPC iSCSI portals (CT0: 172.17.52.12, CT1: 172.17.52.17).
      7. Initializes, partitions, and formats the new disks:
             H:\SQLData  — data volume
             I:\SQLLog   — log volume

    TempDB is left on the local ephemeral disk (D:\SQLTemp) — not touched here.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$PureManagementIP = 'gso-cbs-azure.fsa.lab'
$PureCred         = Get-Credential -Message 'Enter credentials for EPC management (admin account)'
$DataSizeGB       = 20480   # 20 TB
$LogSizeGB        = 512

# ---------------------------------------------------------------------------
# 0. Relocate CD-ROM from D: to Z: so D: is free for the EPC data volume
# ---------------------------------------------------------------------------
Write-Output 'Relocating CD-ROM drive from D: to Z: ...'
$CdRom = Get-WmiObject -Class Win32_CDROMDrive | Where-Object { $_.Drive -eq 'D:' }
if ($CdRom) {
    $Drive = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter = 'D:' AND DriveType = 5"
    if ($Drive) {
        Set-CimInstance -InputObject $Drive -Property @{ DriveLetter = 'Z:' }
        Write-Output '  CD-ROM relocated to Z:.'
    } else {
        Write-Output '  WARNING: CD-ROM volume not found via CIM — skipping relocation.'
    }
} else {
    Write-Output '  No CD-ROM found on D: — skipping.'
}

# ---------------------------------------------------------------------------
# 1. Install NuGet provider and Pure Storage PowerShell SDK v2
# ---------------------------------------------------------------------------
Write-Output 'Installing NuGet provider ...'
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null

Write-Output 'Installing PureStoragePowershellSDK2 ...'
Install-Module PureStoragePowershellSDK2 -Confirm:$false -Force
Import-Module PureStoragePowershellSDK2 -Force

# ---------------------------------------------------------------------------
# 2. Enable Windows iSCSI initiator
# ---------------------------------------------------------------------------
Write-Output 'Enabling iSCSI initiator service ...'
Set-Service -Name msiscsi -StartupType Automatic
Start-Service -Name msiscsi

# Give the service a moment to fully start and register the initiator port
Start-Sleep -Seconds 5

# ---------------------------------------------------------------------------
# 3. Connect to EPC and build host + volume objects
# ---------------------------------------------------------------------------
Write-Output "Connecting to EPC array at $PureManagementIP ..."
$Array = Connect-Pfa2Array -Endpoint $PureManagementIP -Credential $PureCred -IgnoreCertificateError

$HostName  = [System.Net.Dns]::GetHostName()
$Iqn       = (Get-InitiatorPort | Where-Object { $_.ConnectionType -eq 'iSCSI' } | Select-Object -First 1).NodeAddress

if (-not $Iqn) {
    throw 'No iSCSI initiator IQN found. Verify the iSCSI initiator service is running.'
}
Write-Output "  Host IQN : $Iqn"

Write-Output "Creating EPC host '$HostName' ..."
$PureHost = New-Pfa2Host -Array $Array -Name $HostName -Iqns $Iqn

# ---------------------------------------------------------------------------
# 4. Provision EPC volumes
# ---------------------------------------------------------------------------
Write-Output "Creating EPC volumes (Data=${DataSizeGB}GB, Log=${LogSizeGB}GB) ..."
$VolData = New-Pfa2Volume -Array $Array -Name "$HostName-SQLDATA1" -Provisioned ($DataSizeGB * 1GB)
$VolLog  = New-Pfa2Volume -Array $Array -Name "$HostName-SQLLOG1"  -Provisioned ($LogSizeGB  * 1GB)

# Connect volumes to the host in order: Data (LUN1), Log (LUN2)
Write-Output 'Connecting volumes to host ...'
New-Pfa2Connection -Array $Array `
    -HostNames   $PureHost.Name `
    -VolumeNames $VolData.Name, $VolLog.Name

# ---------------------------------------------------------------------------
# 5. Connect iSCSI portals on the EPC array
#
# EPC iSCSI network layout
#   CT0 iSCSI : 172.17.51.12
#   CT1 iSCSI : 172.17.51.17
#   CT0 Repl  : 172.17.52.10  \  replication-only — excluded from iSCSI
#   CT1 Repl  : 172.17.52.11  /
# ---------------------------------------------------------------------------
[string[]] $HardcodedIscsiPortals = @('172.17.51.12', '172.17.51.17')

if ($HardcodedIscsiPortals.Count -gt 0) {
    Write-Output 'Using hardcoded EPC iSCSI portal IPs ...'
    $PortalIPs = $HardcodedIscsiPortals
} else {
    Write-Output 'Discovering iSCSI interfaces on EPC array via API ...'
    $IscsiInterfaces = Get-Pfa2NetworkInterface -Array $Array |
        Where-Object { $_.Services -contains 'iscsi' }

    if ($IscsiInterfaces.Count -lt 1) {
        throw 'No iSCSI interfaces found on EPC array. Verify EPC iSCSI is configured.'
    }
    $PortalIPs = $IscsiInterfaces | ForEach-Object { $_.Eth.Address }
}

$LocalIP = (Get-NetIPAddress |
    Where-Object { $_.InterfaceAlias -like 'Ethernet*' -and $_.AddressFamily -eq 'IPv4' } |
    Select-Object -First 1).IPAddress

Write-Output "  Local iSCSI initiator IP : $LocalIP"

foreach ($PortalIP in $PortalIPs) {
    Write-Output "  Connecting iSCSI portal $PortalIP ..."
    if ((Get-IscsiTargetPortal -ErrorAction SilentlyContinue).TargetPortalAddress -notcontains $PortalIP) {
        New-IscsiTargetPortal -TargetPortalAddress $PortalIP | Out-Null
    }

    Get-IscsiTarget | Connect-IscsiTarget `
        -InitiatorPortalAddress $LocalIP `
        -TargetPortalAddress    $PortalIP `
        -IsPersistent           $true `
        -ErrorAction            SilentlyContinue | Out-Null
}

# ---------------------------------------------------------------------------
# 6. Initialize, partition, format, and label the new disks
# ---------------------------------------------------------------------------
Write-Output 'Rescanning storage bus for new disks ...'
Update-HostStorageCache
Start-Sleep -Seconds 10      # allow iSCSI LUN discovery to settle
Update-HostStorageCache

$RawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' } | Sort-Object Number

if ($RawDisks.Count -lt 2) {
    Write-Output "WARNING: Expected 2 new RAW disks but found $($RawDisks.Count). Check EPC volume connections before proceeding."
}

$DiskConfig = @(
    @{ Letter = 'D'; Label = 'SQLDATA1'; Folder = 'SQLDATA1' }
    @{ Letter = 'L'; Label = 'SQLLOG1';  Folder = 'SQLLOG1'  }
)

for ($i = 0; $i -lt $RawDisks.Count -and $i -lt $DiskConfig.Count; $i++) {
    $Disk   = $RawDisks[$i]
    $Config = $DiskConfig[$i]

    Write-Output "  Disk $($Disk.Number) -> $($Config.Letter): ($($Config.Label))"
    Initialize-Disk -Number $Disk.Number -PartitionStyle GPT
    New-Partition -DiskNumber $Disk.Number -UseMaximumSize -DriveLetter $Config.Letter | Out-Null

    # 64 KB allocation unit size is recommended for SQL Server data files
    Format-Volume `
        -DriveLetter        $Config.Letter `
        -FileSystem         NTFS `
        -NewFileSystemLabel $Config.Label `
        -AllocationUnitSize 65536 `
        -Confirm:$false | Out-Null

    # Create the SQL directory
    New-Item -Path "$($Config.Letter):\$($Config.Folder)" -ItemType Directory -Force | Out-Null
    Write-Output "  $($Config.Letter):\$($Config.Folder) ready."
}

Write-Output 'EPC volume configuration complete.'
Write-Output "  D:\SQLDATA1  ($DataSizeGB GB) — SQL Server data files  [EPC iSCSI]"
Write-Output "  L:\SQLLOG1   ($LogSizeGB GB)  — SQL Server log files   [EPC iSCSI]"
Write-Output '  TempDB left on local ephemeral disk (D:\SQLTemp)       [SQL Server will configure]'


# ---------------------------------------------------------------------------
# Cleanup : offline disks, disconnect iSCSI sessions, remove EPC host record
# ---------------------------------------------------------------------------
Write-Output 'Starting EPC cleanup ...'

# 1. Connect to the EPC array
$Array    = Connect-Pfa2Array -Endpoint $PureManagementIP -Credential $PureCred -IgnoreCertificateError
$HostName = [System.Net.Dns]::GetHostName()

# 2. Offline and remove the drive letters for the EPC-backed disks
foreach ($Letter in @('D', 'L')) {
    $Disk = Get-Partition | Where-Object { $_.DriveLetter -eq $Letter } |
            Get-Disk -ErrorAction SilentlyContinue
    if ($Disk) {
        Write-Output "  Offlining disk $($Disk.Number) (${Letter}:) ..."
        Set-Disk -Number $Disk.Number -IsOffline $true
    }
}

# 3. Disconnect persistent iSCSI sessions to EPC portals and remove portals
[string[]] $EpcPortals = @('172.17.51.12', '172.17.51.17')

foreach ($PortalIP in $EpcPortals) {
    Write-Output "  Disconnecting iSCSI sessions to $PortalIP ..."
    Get-IscsiSession | Where-Object { $_.TargetAddress -eq $PortalIP } |
        Disconnect-IscsiTarget -Confirm:$false -ErrorAction SilentlyContinue

    $Portal = Get-IscsiTargetPortal -ErrorAction SilentlyContinue |
              Where-Object { $_.TargetPortalAddress -eq $PortalIP }
    if ($Portal) {
        Remove-IscsiTargetPortal -TargetPortalAddress $PortalIP -Confirm:$false
        Write-Output "  Portal $PortalIP removed."
    }
}

# 4. Remove EPC volume connections and volumes
Write-Output "  Removing EPC volume connections for host '$HostName' ..."
$Connections = Get-Pfa2Connection -Array $Array | Where-Object { $_.Host.Name -eq $HostName }
foreach ($Conn in $Connections) {
    Remove-Pfa2Connection -Array $Array -HostName $HostName -VolumeName $Conn.Volume.Name
    Write-Output "  Disconnected volume $($Conn.Volume.Name)."
}

Write-Output "  Deleting EPC volumes ..."
foreach ($VolName in @("$HostName-SQLData1", "$HostName-SQLLog1")) {
    $Vol = Get-Pfa2Volume -Array $Array -Name $VolName -ErrorAction SilentlyContinue
    if ($Vol) {
        Remove-Pfa2Volume -Array $Array -Name $VolName -Confirm:$false
        Remove-Pfa2Volume -Array $Array -Name $VolName -Eradicate 
        Write-Output "  Volume $VolName deleted and eradicated."
    }
}

# 5. Remove the EPC host record
$PureHost = Get-Pfa2Host -Array $Array -Name $HostName -ErrorAction SilentlyContinue
if ($PureHost) {
    Write-Output "  Removing EPC host record '$HostName' ..."
    Remove-Pfa2Host -Array $Array -Name $HostName
    Write-Output "  Host record removed."
}

Write-Output 'EPC cleanup complete.'
