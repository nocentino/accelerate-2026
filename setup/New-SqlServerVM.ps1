#Requires -Module Az.Compute, Az.Network, Az.Resources, Az.SqlVirtualMachine

<#
.SYNOPSIS
    Creates an Azure VM running SQL Server 2025 Developer Edition with
    Pure Storage EPC iSCSI volumes for data and log.

.DESCRIPTION
    Provisions a Windows VM from the latest SQL Server 2025 Developer Edition
    Marketplace image in the GSO Azure (MCA) tenant, attached to the existing
    core VNet/subnet, with no public IP.

    Storage is provided by Pure Storage EPC via iSCSI:
      D:\SQLDATA1 — SQLData volume  (10 TB)
      L:\SQLLOG1  — SQLLog volume   (512 GB)

    TempDB is left on the local ephemeral (temporary) disk (D:\SQLTemp).

    After VM deployment the script:
      1. Runs Configure-EPC.ps1 on the VM via Run Command to connect EPC volumes.
      2. Registers the SQL Server IaaS extension for portal management.

.NOTES
    Tenant  : GSO Azure (MCA) — 3918983b-49d8-4d7f-bd90-73a70aa911e7
    RG      : gso-fsa-an-westus2
    VNet    : gso-core-westus2-vnet / gso-core-westus2-subnet-default
    EPC     : Configure-EPC.ps1 must be in the same directory as this script.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$TenantId       = '5a3d1859-f4b7-4151-beae-773895b989fd'
$SubscriptionId = '3918983b-49d8-4d7f-bd90-73a70aa911e7'
$Location       = 'westus2'
$ResourceGroup  = 'gso-fsa-an-westus2'
$VNetName       = 'gso-core-westus2-vnet'
$SubnetName     = 'gso-core-westus2-subnet-default'
$VmName         = 'gso-fsa-an-win-1'
$ComputerName   = 'gso-an-win-1'       # Windows NetBIOS name — 15 char max
$VmSize         = 'Standard_E4s_v5'
$AdminCredential = Import-Clixml -Path "~/aencred.xml"

$Tags = @{
    owner         = 'worldwide_sys_eng'
    org           = 'revenue'
    team          = 'FSA'
    'ext-facing'  = 'false'
    importance    = 'low'
    env           = 'sandbox'
    service       = 'demo'
    administrator = 'anthony_nocentino'
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------
Write-Host "Connecting to Azure tenant $TenantId ..." -ForegroundColor Cyan
Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId

# ---------------------------------------------------------------------------
# Resolve the latest SQL Server 2025 Developer marketplace image
# ---------------------------------------------------------------------------
Write-Host 'Resolving latest SQL Server 2025 Developer Edition image ...' -ForegroundColor Cyan

$Publisher = 'MicrosoftSQLServer'

# Find the offer that matches SQL Server 2025 Developer on Windows Server
$Offer = Get-AzVMImageOffer -Location $Location -PublisherName $Publisher |
    Where-Object { $_.Offer -like 'sql2025*' } |
    Select-Object -First 1

if (-not $Offer) {
    throw "No SQL Server 2025 marketplace offer found in $Location. " +
          "Run: Get-AzVMImageOffer -Location '$Location' -PublisherName '$Publisher' | Select Offer"
}

Write-Host "  Offer : $($Offer.Offer)" -ForegroundColor Gray

$Sku = Get-AzVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer.Offer |
    Where-Object { $_.Skus -like '*entdev*' } |
    Select-Object -First 1

if (-not $Sku) {
    throw "No Developer SKU found under offer '$($Offer.Offer)'. " +
          "Run: Get-AzVMImageSku -Location '$Location' -PublisherName '$Publisher' -Offer '$($Offer.Offer)'"
}

Write-Host "  SKU   : $($Sku.Skus)" -ForegroundColor Gray

$LatestImage = Get-AzVMImage -Location $Location `
    -PublisherName $Publisher `
    -Offer        $Offer.Offer `
    -Skus         $Sku.Skus |
    Sort-Object   { [version]($_.Version -replace '[^0-9.]', '') } |
    Select-Object -Last 1

Write-Host "  Version: $($LatestImage.Version)" -ForegroundColor Gray

$ImageRef = @{
    PublisherName = $Publisher
    Offer         = $Offer.Offer
    Skus          = $Sku.Skus
    Version       = $LatestImage.Version
}

# ---------------------------------------------------------------------------
# Accept the marketplace plan terms (required on first use per subscription)
# ---------------------------------------------------------------------------
Write-Output 'Accepting marketplace image terms ...'
$Plan = Get-AzMarketplaceTerms -Publisher $Publisher -Product $Offer.Offer -Name $Sku.Skus
if (-not $Plan.Accepted) {
    $Plan | Set-AzMarketplaceTerms -Accept | Out-Null
    Write-Output '  Terms accepted.'
} else {
    Write-Output '  Terms already accepted.'
}

# ---------------------------------------------------------------------------
# Resolve VNet / subnet (may live in a different resource group)
# ---------------------------------------------------------------------------
Write-Host "Resolving VNet '$VNetName' ..." -ForegroundColor Cyan

$VNet = Get-AzVirtualNetwork -Name $VNetName -ErrorAction SilentlyContinue
if (-not $VNet) {
    # Search across all resource groups in the subscription
    $VNet = Get-AzVirtualNetwork | Where-Object { $_.Name -eq $VNetName } | Select-Object -First 1
}

if (-not $VNet) {
    throw "VNet '$VNetName' not found. Verify the name and that it exists in the current subscription."
}

$Subnet = $VNet.Subnets | Where-Object { $_.Name -eq $SubnetName }
if (-not $Subnet) {
    throw "Subnet '$SubnetName' not found in VNet '$VNetName'."
}

Write-Host "  VNet RG : $($VNet.ResourceGroupName)" -ForegroundColor Gray
Write-Host "  Subnet  : $($Subnet.Name) ($($Subnet.AddressPrefix))" -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Build NIC (no public IP)
# ---------------------------------------------------------------------------
Write-Host 'Creating network interface ...' -ForegroundColor Cyan

$NicName = "$VmName-nic1"
$NicConfig = New-AzNetworkInterfaceIpConfig `
    -Name      'ipconfig1' `
    -SubnetId  $Subnet.Id `
    -Primary

# Accelerated networking is required for iSCSI throughput to EPC
$Nic = New-AzNetworkInterface `
    -Name                       $NicName `
    -ResourceGroupName          $ResourceGroup `
    -Location                   $Location `
    -IpConfiguration            $NicConfig `
    -EnableAcceleratedNetworking `
    -Tag                        $Tags

Write-Host "  NIC '$NicName' created." -ForegroundColor Gray


# ---------------------------------------------------------------------------
# Build VM configuration
# ---------------------------------------------------------------------------
Write-Host 'Building VM configuration ...' -ForegroundColor Cyan

$VmConfig = New-AzVMConfig -VMName $VmName -VMSize $VmSize -Tags $Tags |
    Set-AzVMOperatingSystem `
        -Windows `
        -ComputerName    $ComputerName `
        -Credential      $AdminCredential `
        -ProvisionVMAgent `
        -EnableAutoUpdate |
    Set-AzVMSourceImage `
        -PublisherName $ImageRef.PublisherName `
        -Offer         $ImageRef.Offer `
        -Skus          $ImageRef.Skus `
        -Version       $ImageRef.Version |
    Set-AzVMOSDisk `
        -CreateOption  FromImage `
        -StorageAccountType Premium_LRS `
        -DiskSizeInGB  128 `
        -Caching       ReadWrite |
    Add-AzVMNetworkInterface -Id $Nic.Id -Primary

# Enable Boot Diagnostics with managed storage
$VmConfig = Set-AzVMBootDiagnostic -VM $VmConfig -Enable

# ---------------------------------------------------------------------------
# Deploy the VM
# ---------------------------------------------------------------------------
Write-Host "Deploying VM '$VmName' in resource group '$ResourceGroup' ..." -ForegroundColor Cyan
Write-Output "  Image  : $Publisher / $($Offer.Offer) / $($Sku.Skus) @ $($LatestImage.Version)"
Write-Output "  Size   : $VmSize"
Write-Output "  Subnet : $($Subnet.Name)"
Write-Output ''

$VM = New-AzVM `
    -ResourceGroupName $ResourceGroup `
    -Location          $Location `
    -VM                $VmConfig `
    -Tag               $Tags

Write-Output ''
Write-Host "VM '$VmName' deployed successfully." -ForegroundColor Green
Write-Output "  Provisioning state : $($VM.ProvisioningState)"
Write-Output "  Resource ID        : $($VM.Id)"

# ---------------------------------------------------------------------------
# Configure Pure Storage EPC volumes via Run Command
# ---------------------------------------------------------------------------
Write-Output ''
Write-Host 'Waiting 60 seconds for VM agent to become ready ...' -ForegroundColor Cyan
Start-Sleep -Seconds 60

$EpcScriptPath = Join-Path $PSScriptRoot 'Configure-EPC.ps1'
if (-not (Test-Path $EpcScriptPath)) {
    throw "Configure-EPC.ps1 not found at '$EpcScriptPath'. It must be in the same directory as this script."
}

Write-Host "Running EPC configuration script on '$VmName' ..." -ForegroundColor Cyan
Write-Output '  This installs the Pure Storage SDK2, connects iSCSI volumes, and formats disks.'
Write-Output '  This may take 5-10 minutes.'

$EpcRunResult = Invoke-AzVMRunCommand `
    -ResourceGroupName $ResourceGroup `
    -VMName            $VmName `
    -CommandId         'RunPowerShellScript' `
    -ScriptPath        $EpcScriptPath

if ($EpcRunResult.Value) {
    Write-Host '  --- EPC script output ---' -ForegroundColor Gray
    $EpcRunResult.Value | ForEach-Object { Write-Host "  $($_.Message)" -ForegroundColor Gray }
}

# ---------------------------------------------------------------------------
# Register SQL Server IaaS extension
# ---------------------------------------------------------------------------
Write-Output ''
Write-Host 'Registering SQL Server IaaS extension ...' -ForegroundColor Cyan

# Register the subscription with the Microsoft.SqlVirtualMachine resource provider
Register-AzResourceProvider -ProviderNamespace Microsoft.SqlVirtualMachine 

# Register the SQL Server VM with the extension
New-AzSqlVM -Name              $VmName `
            -ResourceGroupName $ResourceGroup `
            -Location          $Location `
            -LicenseType       PAYG

Write-Host '  SQL IaaS extension registered (may take a few minutes to reach Full mode).' -ForegroundColor Gray

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Output ''
Write-Host '===============================================================' -ForegroundColor Green
Write-Host " Deployment complete: $VmName" -ForegroundColor Green
Write-Host '===============================================================' -ForegroundColor Green
Write-Output "  Resource Group : $ResourceGroup"
Write-Output "  Location       : $Location"
Write-Output "  VM Size        : $VmSize"
Write-Output "  SQL Image      : $Publisher / $($Offer.Offer) / $($Sku.Skus)"
Write-Output "  EPC Array      : gso-cbs-azure.fsa.lab"
Write-Output "  Data volume    : D:\SQLData  [EPC iSCSI]"
Write-Output "  Log  volume    : L:\SQLLog   [EPC iSCSI]"
Write-Output "  TempDB         : D:\SQLTemp                       [local ephemeral disk]"

