#Requires -Modules SqlServer

<#
.SYNOPSIS
    Creates a clusterless Always On AG with certificate-based endpoint authentication.

.DESCRIPTION
    Configures three SQL Server instances for a CLUSTER_TYPE=NONE Availability Group
    using certificate-based hadr endpoint authentication (no Windows auth required).

    What this script does on each server:
      1. Creates a database master key (if absent)
      2. Creates SQL logins for all three replicas
      3. Creates database users in master for each login (required for ALTER AUTHORIZATION)
      4. Creates the local server certificate and exports the public key to $CertPath
      5. Imports the other two servers' public certs and assigns ownership to their logins
      6. Creates the Hadr_endpoint using the local cert
      7. Grants CONNECT on the endpoint to all replica logins
      8. Adds an inbound Windows Firewall rule for $EndpointPort
    Then on the primary: creates AG1
    Then on each secondary: JOINs the AG and grants CREATE ANY DATABASE

    Prerequisites:
      - SQL Server HADR feature enabled on all instances
        (verify: SELECT SERVERPROPERTY('IsHadrEnabled'); if 0, enable and restart SQL)
      - $DatabaseName exists on $PrimaryServer in FULL recovery mode with a full backup
      - PowerShell remoting enabled on all servers (for firewall rule + cert directory creation)
      - Windows admin rights to all three servers
      - For cross-subnet replicas where DNS doesn't resolve the short hostname:
        add hosts file entries on those servers BEFORE running this script.
        Example: on aen-sql-25-e, add to C:\Windows\System32\drivers\etc\hosts:
            10.21.229.112   aen-sql-25-c
            10.21.229.114   aen-sql-25-d

.EXAMPLE
    .\Create-ClusterlessAG-CertAuth.ps1

.EXAMPLE
    .\Create-ClusterlessAG-CertAuth.ps1 -PrimaryServer 'sql-01' -Secondary1Server 'sql-02' `
        -Secondary2Server 'sql-03' -AGName 'MyAG' -DatabaseName 'MyDB'
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [string]$PrimaryServer    = 'aen-sql-25-c',
    [string]$Secondary1Server = 'aen-sql-25-d',
    [string]$Secondary2Server = 'aen-sql-25-e',
    [string]$AGName           = 'AG1',
    [string]$DatabaseName     = 'TestDB1',
    [string]$EndpointName     = 'Hadr_endpoint',
    [int]   $EndpointPort     = 5022,
    [string]$CertPath         = 'C:\cert',

    # Passwords - change these before running
    [string]$MasterKeyPassword = 'P@ssw0rd_MasterKey1!',
    [string]$LoginPassword     = 'P@ssw0rd_Login1!'
)

$ErrorActionPreference = 'Stop'
$AllServers = @($PrimaryServer, $Secondary1Server, $Secondary2Server)

function Invoke-AgSql {
    param(
        [string]$ServerInstance,
        [string]$Query,
        [string]$Database = 'master'
    )
    Invoke-Sqlcmd -ServerInstance $ServerInstance -Database $Database `
        -Query $Query -TrustServerCertificate -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Step 1: On each server — master key, logins, users, local cert, cert export
# ---------------------------------------------------------------------------
foreach ($server in $AllServers) {
    Write-Host "`n=== [$server] Creating logins, users, and local certificate ===" -ForegroundColor Cyan

    # Create the C:\cert directory via PowerShell remoting
    Invoke-Command -ComputerName $server -ScriptBlock {
        param($path)
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path | Out-Null
            Write-Host "  Created $path"
        }
    } -ArgumentList $CertPath

    # Database master key
    Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$MasterKeyPassword';
"@

    # Logins (one per replica, on every server)
    foreach ($s in $AllServers) {
        Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = '${s}_Login')
    CREATE LOGIN [${s}_Login] WITH PASSWORD = '$LoginPassword';
"@
    }

    # Database users in master (required: ALTER AUTHORIZATION ON CERTIFICATE needs a db user, not just a login)
    foreach ($s in $AllServers) {
        Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = '${s}_Login')
    CREATE USER [${s}_Login] FOR LOGIN [${s}_Login];
"@
    }

    # Local certificate
    Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '${server}_Cert')
    CREATE CERTIFICATE [${server}_Cert]
        WITH SUBJECT = 'AG Endpoint Cert for $server',
        EXPIRY_DATE = '2027-05-01';
"@

    # Assign cert ownership to the matching login
    Invoke-AgSql $server "ALTER AUTHORIZATION ON CERTIFICATE::[${server}_Cert] TO [${server}_Login];"

    # Export public cert (no password needed — public key only)
    Invoke-AgSql $server "BACKUP CERTIFICATE [${server}_Cert] TO FILE = '$CertPath\${server}_Cert.cer';"

    Write-Host "  [$server] Local cert created and exported" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 2: Copy each server's public cert to the other two servers
# ---------------------------------------------------------------------------
Write-Host "`n=== Copying public certificates between servers ===" -ForegroundColor Cyan

foreach ($srcServer in $AllServers) {
    $srcFile = "\\$srcServer\c$\cert\${srcServer}_Cert.cer"
    foreach ($dstServer in $AllServers) {
        if ($srcServer -ne $dstServer) {
            $dstDir = "\\$dstServer\c$\cert"
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
            Copy-Item -Path $srcFile -Destination "$dstDir\${srcServer}_Cert.cer" -Force
            Write-Host "  Copied ${srcServer}_Cert.cer  -->  $dstServer" -ForegroundColor Green
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: On each server — import remote certs, create endpoint, grant CONNECT
# ---------------------------------------------------------------------------
foreach ($server in $AllServers) {
    Write-Host "`n=== [$server] Importing remote certs and creating endpoint ===" -ForegroundColor Cyan

    # Import the other two servers' public certs and assign ownership
    foreach ($remoteServer in $AllServers) {
        if ($remoteServer -ne $server) {
            Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.certificates WHERE name = '${remoteServer}_Cert')
    CREATE CERTIFICATE [${remoteServer}_Cert]
        FROM FILE = '$CertPath\${remoteServer}_Cert.cer';
ALTER AUTHORIZATION ON CERTIFICATE::[${remoteServer}_Cert] TO [${remoteServer}_Login];
"@
        }
    }

    # Create the hadr endpoint (uses the LOCAL server's cert for its own identity)
    Invoke-AgSql $server @"
IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = '$EndpointName')
    CREATE ENDPOINT [$EndpointName]
        STATE = STARTED
        AS TCP (LISTENER_PORT = $EndpointPort, LISTENER_IP = ALL)
        FOR DATABASE_MIRRORING (
            AUTHENTICATION = CERTIFICATE [${server}_Cert],
            ROLE = ALL,
            ENCRYPTION = REQUIRED ALGORITHM AES
        );
ELSE
    ALTER ENDPOINT [$EndpointName] STATE = STARTED;
"@

    # Grant CONNECT on the endpoint to all replica logins
    foreach ($s in $AllServers) {
        Invoke-AgSql $server "GRANT CONNECT ON ENDPOINT::[$EndpointName] TO [${s}_Login];"
    }

    Write-Host "  [$server] Endpoint configured" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 4: Inbound firewall rule for the endpoint port on each server
# ---------------------------------------------------------------------------
Write-Host "`n=== Adding inbound firewall rules for port $EndpointPort ===" -ForegroundColor Cyan

foreach ($server in $AllServers) {
    Invoke-Command -ComputerName $server -ScriptBlock {
        param($port, $epName)
        $ruleName = "SQL AG $epName - Port $port"
        if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $ruleName `
                -Direction Inbound -Protocol TCP -LocalPort $port `
                -Action Allow -Enabled True | Out-Null
            Write-Host "  [$env:COMPUTERNAME] Firewall rule added"
        } else {
            Write-Host "  [$env:COMPUTERNAME] Firewall rule already exists"
        }
    } -ArgumentList $EndpointPort, $EndpointName
}

# ---------------------------------------------------------------------------
# Step 5: Create the Availability Group on the primary
# ---------------------------------------------------------------------------
Write-Host "`n=== Creating AG '$AGName' on $PrimaryServer ===" -ForegroundColor Cyan

$replicaDefs = ($AllServers | ForEach-Object {
    "N'$_' WITH (ENDPOINT_URL = N'TCP://${_}:$EndpointPort', FAILOVER_MODE = MANUAL, AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, SEEDING_MODE = AUTOMATIC, SECONDARY_ROLE (ALLOW_CONNECTIONS = ALL))"
}) -join ",`n        "

Invoke-AgSql $PrimaryServer @"
CREATE AVAILABILITY GROUP [$AGName]
    WITH (CLUSTER_TYPE = NONE, DB_FAILOVER = OFF, DTC_SUPPORT = NONE)
    FOR DATABASE [$DatabaseName]
    REPLICA ON
        $replicaDefs;
"@

Write-Host "  AG '$AGName' created" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 6: Join secondaries to the AG and allow automatic seeding
# ---------------------------------------------------------------------------
foreach ($secondary in @($Secondary1Server, $Secondary2Server)) {
    Write-Host "`n=== Joining $secondary to AG '$AGName' ===" -ForegroundColor Cyan

    Invoke-AgSql $secondary "ALTER AVAILABILITY GROUP [$AGName] JOIN WITH (CLUSTER_TYPE = NONE);"
    Invoke-AgSql $secondary "ALTER AVAILABILITY GROUP [$AGName] GRANT CREATE ANY DATABASE;"

    Write-Host "  $secondary joined AG '$AGName'" -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Step 7: Health check
# ---------------------------------------------------------------------------
Write-Host "`n=== AG Health Check ===" -ForegroundColor Cyan

Invoke-AgSql $PrimaryServer @"
SELECT ar.replica_server_name,
       ars.role_desc,
       ars.connected_state_desc,
       ars.synchronization_health_desc
FROM   sys.availability_replicas ar
JOIN   sys.dm_hadr_availability_replica_states ars ON ar.replica_id = ars.replica_id
JOIN   sys.availability_groups ag ON ar.group_id = ag.group_id
WHERE  ag.name = '$AGName';
"@ | Format-Table -AutoSize

Invoke-AgSql $PrimaryServer @"
SELECT ar.replica_server_name,
       adc.database_name,
       drs.synchronization_state_desc,
       drs.synchronization_health_desc
FROM   sys.dm_hadr_database_replica_states drs
JOIN   sys.availability_replicas ar  ON drs.replica_id      = ar.replica_id
JOIN   sys.availability_groups ag    ON ar.group_id         = ag.group_id
JOIN   sys.availability_databases_cluster adc ON drs.group_database_id = adc.group_database_id
WHERE  ag.name = '$AGName';
"@ | Format-Table -AutoSize

Write-Host "`nDone." -ForegroundColor Green
