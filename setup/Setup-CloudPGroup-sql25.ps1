#############################################################################
# Create Protection Group on Azure EverPure Array for AG Failover Demo
#
# Creates 'aen-sql-25-e-pg' on gso-cbs-azure.fsa.lab containing:
#   - gso-an-win-1-SQLDATA1  (20 TB  D: drive)
#   - gso-an-win-1-SQLLOG1   (512 GB L: drive)
#
# Configures async replication targets back to both on-prem arrays:
#   - sn1-x90r2-f06-33  (aen-sql-25-c array)
#   - sn1-x90r2-f06-27  (aen-sql-25-d array)
#
# Run each section independently.
#############################################################################

Import-Module PureStoragePowerShellSDK2


#region Variables
$CloudArrayName   = 'gso-cbs-azure.fsa.lab'
$PGroupName       = 'aen-sql-25-e-pg'
$DataVolName      = 'gso-an-win-1-SQLDATA1'
$LogVolName       = 'gso-an-win-1-SQLLOG1'
#endregion Variables


# Connect to the Azure EverPure FlashArray
$Credential       = Import-CliXml -Path "$HOME\FA_Cred.xml"
$FlashArrayCloud  = Connect-Pfa2Array -EndPoint $CloudArrayName -Credential $Credential -IgnoreCertificateError



##################################################
# STEP 1: Inspect existing array connections
# Verify the on-prem arrays are already peered to gso-cbs-azure.fsa.lab
# The Name shown here is what you must pass to New-Pfa2ProtectionGroupTarget
##################################################
$ArrayConnections = Get-Pfa2ArrayConnection -Array $FlashArrayCloud
$ArrayConnections | Format-Table Name, Id, ManagementAddress, ReplicationAddresses, Status, Type

# Expected output: two rows — one for sn1-x90r2-f06-33, one for sn1-x90r2-f06-27
# If the arrays are not listed, the arrays must be peered before continuing.
# Use the FlashArray GUI or:
#   New-Pfa2ArrayConnection -Array $FlashArrayCloud -ManagementAddress <ip> -ConnectionKey <key>



##################################################
# STEP 2: Create the Protection Group
##################################################
$PGroup = New-Pfa2ProtectionGroup -Array $FlashArrayCloud -Name $PGroupName
Write-Warning "Created protection group: $($PGroup.Name)"



##################################################
# STEP 3: Add volumes to the Protection Group
##################################################
New-Pfa2ProtectionGroupVolume -Array $FlashArrayCloud `
    -GroupName $PGroupName `
    -MemberName $DataVolName
Write-Warning "Added volume: $DataVolName"

New-Pfa2ProtectionGroupVolume -Array $FlashArrayCloud `
    -GroupName $PGroupName `
    -MemberName $LogVolName
Write-Warning "Added volume: $LogVolName"



##################################################
# STEP 4: Add replication targets (both on-prem arrays)
# Use the array Name values from Step 1 — typically the short FlashArray name
# (e.g. 'sn1-x90r2-f06-33'), not the FQDN.
##################################################

# Resolve the on-prem array names as known to the Azure array
$OnPremTarget1 = ($ArrayConnections | Where-Object { $_.Name -like '*f06-33*' }).Name
$OnPremTarget2 = ($ArrayConnections | Where-Object { $_.Name -like '*f06-27*' }).Name

if (-not $OnPremTarget1) { throw "Could not find f06-33 in array connections. Check Step 1 output and set manually." }
if (-not $OnPremTarget2) { throw "Could not find f06-27 in array connections. Check Step 1 output and set manually." }

Write-Warning "Resolved on-prem target 1: $OnPremTarget1"
Write-Warning "Resolved on-prem target 2: $OnPremTarget2"

New-Pfa2ProtectionGroupTarget -Array $FlashArrayCloud `
    -GroupName $PGroupName `
    -MemberName $OnPremTarget1
Write-Warning "Added replication target: $OnPremTarget1"

New-Pfa2ProtectionGroupTarget -Array $FlashArrayCloud `
    -GroupName $PGroupName `
    -MemberName $OnPremTarget2
Write-Warning "Added replication target: $OnPremTarget2"



##################################################
# STEP 5: Verify the final configuration
##################################################
Write-Warning "--- Protection Group ---"
Get-Pfa2ProtectionGroup -Array $FlashArrayCloud -Name $PGroupName |
    Format-List Name, TargetCount, VolumeCount, HostCount, HostGroupCount

Write-Warning "--- Volumes in PGroup ---"
Get-Pfa2ProtectionGroupVolume -Array $FlashArrayCloud -GroupName $PGroupName |
    Format-Table Member

Write-Warning "--- Replication Targets ---"
Get-Pfa2ProtectionGroupTarget -Array $FlashArrayCloud -GroupName $PGroupName |
    Format-Table Member
