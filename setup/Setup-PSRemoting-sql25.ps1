#############################################################################
# Configure PowerShell Remoting for aen-sql-25-c / d / e
#
# aen-sql-25-c and aen-sql-25-d  - WinRM (run from THIS host)
# aen-sql-25-e                   - SSH key-based (commands to run ON aen-sql-25-e)
#
# Run each section independently, not all at once.
#############################################################################


##################################################
# STEP 1: Generate SSH key pair on THIS host
# (needed for key-based auth to aen-sql-25-e)
##################################################

$KeyPath = "$HOME\.ssh\id_ed25519_aen_sql25"

# Generate a new ed25519 key pair (no passphrase for unattended demo use)
ssh-keygen -t ed25519 -f $KeyPath -C "aen-sql-25-remoting" -N '""'

# Display the public key — copy this value, you'll paste it on aen-sql-25-e
Write-Host "`n--- PUBLIC KEY (copy this) ---" -ForegroundColor Cyan
Get-Content "$KeyPath.pub"
Write-Host "--- END PUBLIC KEY ---`n" -ForegroundColor Cyan



##################################################
# STEP 2: WinRM remoting to aen-sql-25-c and aen-sql-25-d
# (run from THIS host)
##################################################

# If this host and c/d are not in the same domain, add them to TrustedHosts
Set-Item WSMan:\localhost\Client\TrustedHosts -Value 'aen-sql-25-c,aen-sql-25-d' -Concatenate -Force

# Verify WinRM is reachable on port 5985
Test-NetConnection -ComputerName 'aen-sql-25-c' -Port 5985
Test-NetConnection -ComputerName 'aen-sql-25-d' -Port 5985

# Create test sessions to confirm connectivity
$SessionC = New-PSSession -ComputerName 'aen-sql-25-c'
$SessionD = New-PSSession -ComputerName 'aen-sql-25-d'

Invoke-Command -Session $SessionC { $env:COMPUTERNAME }
Invoke-Command -Session $SessionD { $env:COMPUTERNAME }

Remove-PSSession $SessionC, $SessionD



##################################################
# STEP 3: Test SSH remoting to aen-sql-25-e from THIS host
# (run AFTER completing Step 4 on aen-sql-25-e)
##################################################

$SshUser = 'anocentino'
$SshHost = 'aen-sql-25-e'

# Test connectivity
Test-NetConnection -ComputerName $SshHost -Port 22

# Open a test SSH session using the key
$SessionE = New-PSSession -HostName $SshHost -UserName $SshUser -KeyFilePath $KeyPath -SSHTransport
Invoke-Command -Session $SessionE { $env:COMPUTERNAME }
Remove-PSSession $SessionE



##################################################
# STEP 4: Commands to run ON aen-sql-25-e
# (paste these into an elevated PowerShell session on that machine)
##################################################

<#
--- PASTE AND RUN THE FOLLOWING ON aen-sql-25-e ---

# Install OpenSSH Server
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0

# Start the service and set it to auto-start
Start-Service sshd
Set-Service -Name sshd -StartupType Automatic

# Open port 22 in the firewall (may already exist after capability install)
$existing = Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
if (-not $existing) {
    New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' `
        -DisplayName 'OpenSSH Server (sshd)' `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}

# Register PowerShell 7 as the SSH subsystem
$sshdConfig = "$env:ProgramData\ssh\sshd_config"
$subsystemLine = 'Subsystem powershell "c:/program files/powershell/7/pwsh.exe" -sshs -nologo'
if (-not (Select-String -Path $sshdConfig -Pattern 'Subsystem powershell' -Quiet)) {
    Add-Content -Path $sshdConfig -Value $subsystemLine
}

# Enable public key authentication (uncomment if commented out)
$config = Get-Content $sshdConfig
$config = $config -replace '^#PubkeyAuthentication', 'PubkeyAuthentication'
Set-Content -Path $sshdConfig -Value $config

# For Administrator-level accounts, authorized_keys lives here (not in the user profile).
# Windows SSH overrides the per-user file for any account in the Administrators group.
$adminKeyFile = "$env:ProgramData\ssh\administrators_authorized_keys"

# Paste the public key from Step 1 (the output of Get-Content "$KeyPath.pub")
$publicKey = 'PASTE_PUBLIC_KEY_HERE'
Set-Content -Path $adminKeyFile -Value $publicKey

# Lock down permissions on the file — SSH will reject it if ACLs are too broad
icacls.exe $adminKeyFile /inheritance:r
icacls.exe $adminKeyFile /grant 'SYSTEM:(F)'
icacls.exe $adminKeyFile /grant 'Administrators:(F)'

# Restart sshd to apply all changes
Restart-Service sshd

--- END OF COMMANDS FOR aen-sql-25-e ---
#>
