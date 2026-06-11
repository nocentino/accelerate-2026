# Accelerate 2026 — SQL Server Disaster Recovery on Pure Storage

**Session: _Maximizing Hybrid SQL Server 2025 on Azure with EverPure Cloud_**

PowerShell demos showing **SQL Server 2022/2025 disaster recovery on Pure Storage FlashArray**,
spanning on-premises and Azure. They combine SQL Server's T‑SQL Snapshot Backup with Pure
Storage array snapshots, asynchronous PGroup replication, and **ActiveDR** continuous
replication to move databases between sites quickly — independent of database size.

> These are demo/teaching scripts, provided **AS‑IS**. They are tailored to a specific lab
> (hostnames, drive layouts, volume serials, etc.) and are meant to be read and adapted, not
> run blind. **Do not run them against production.**

## Topology

| Role | SQL instance | FlashArray | Notes |
|------|--------------|------------|-------|
| On‑prem primary   | `aen-sql-25-c` | `sn1-x90r2-f06-33.fsa.lab` | vVol + RDM volumes |
| On‑prem secondary | `aen-sql-25-d` | `sn1-x90r2-f06-27.fsa.lab` | |
| Azure secondary   | `aen-sql-25-e` | `gso-cbs-azure.fsa.lab` (EverPure Cloud, iSCSI/EPC) | |
| Object storage    | — | `s200.fsa.lab` (FlashBlade S3) | metadata + log backups |

## The three demos (`Maximizing-Hybrid-SQL-Server-2025-on-Azure-with-EverPure-Cloud/`)

### 1. `Invoke-AGSeedFromSnapshot-sql25.ps1`
Seeds an Availability Group database from the on‑prem primary to **both** an on‑prem secondary
and the Azure secondary using a **single** T‑SQL Snapshot Backup + FlashArray PGroup snapshot,
replicated to both target arrays, then a `METADATA_ONLY` restore to join each replica. Shows how
AG seeding becomes a near‑instant, storage‑driven operation instead of a full data copy.

### 2. `Invoke-AGFailoverToCloud-sql25.ps1`
End‑to‑end AG **failover to Azure and back**:
1. Forced failover to the Azure replica (simulated on‑prem outage)
2. Review AG state
3. Snapshot the cloud primary and replicate back on‑prem
4–5. Reseed both on‑prem replicas from the cloud snapshot
6. **Planned failback** to on‑prem (sync‑commit handoff, then return the cloud replica to async)

### 3. `Invoke-ActiveDRFailoverDemo-sql25.ps1`
**ActiveDR** (continuous pod replication) of an RDM‑backed database to Azure, in four parts:
- **PART 0** — baseline (prod owns the DB, replicating to a demoted DR pod)
- **PART 1** — **non‑disruptive DR test**: promote DR, prove read/write at the DR site, demote (zero production impact)
- **PART 2** — **unplanned failover**: bring the DB live in DR and write data there
- **PART 3** — **reverse + failback**: resync the DR changes home and fail back on‑prem

**Key point the demo makes:** failback replicates only the **changed blocks** since the
failover — never the full multi‑TB database — so recovery time scales with *change*, not data
size. That is Pure's storage‑optimized, thin, deduplicated replication.

## `setup/` — environment build (dependencies)

The demos assume the lab is already built. These scripts create it:

| Script | Purpose |
|--------|---------|
| `Setup-PSRemoting-sql25.ps1` | WinRM (on‑prem) + SSH key remoting (Azure) to the SQL hosts |
| `New-SqlServerVM.ps1` | Provision the Azure SQL Server 2025 VM |
| `Configure-EPC.ps1` | Connect Pure EverPure Cloud (EPC) iSCSI volumes on the Azure VM |
| `Setup-CloudPGroup-sql25.ps1` | Configure the cloud protection group / replication |
| `Convert-VVolToRdm-sql25.ps1` | Convert a VM's vVol drives to physical‑mode RDMs |
| `Setup-ActiveDR-RdmToCloud-sql25.ps1` | Establish ActiveDR pod replication of the RDM volumes to Azure |
| `Create-ClusterlessAG-CertAuth.ps1` | Create a clusterless AG using certificate authentication |

## Prerequisites

- **PowerShell 7+**
- Modules: [`dbatools`](https://dbatools.io), [`PureStoragePowerShellSDK2`](https://www.powershellgallery.com/packages/PureStoragePowerShellSDK2),
  and `VMware.VimAutomation.Core` (PowerCLI) for the vVol/RDM scripts
- Credentials stored as encrypted CLIXML in your home directory (never in the scripts):
  - `~/FA_Cred.xml` — FlashArray
  - `~/SA_Cred.xml` — SQL Server
- Remoting: WinRM to the on‑prem hosts; SSH key auth to the Azure host

## Important notes on credentials

- `Invoke-AGSeedFromSnapshot-sql25.ps1` creates a SQL `CREDENTIAL` for FlashBlade S3. The secret
  is **redacted** here (`REPLACE_WITH_S3_ACCESS_KEY:REPLACE_WITH_S3_SECRET_KEY`) — supply your own.
- Some `setup/` scripts use **sample demo passwords** (e.g. `Create-ClusterlessAG-CertAuth.ps1`).
  Change them before using anywhere real.
- All array/SQL credentials are loaded from the external CLIXML files above — keep real secrets
  out of source control.

## Disclaimer

Provided **AS‑IS** as building blocks to adapt to your own environment. No warranty. Test in a
non‑production lab. Failover/failback scripts perform real, disruptive operations on the targeted
databases and storage objects.
