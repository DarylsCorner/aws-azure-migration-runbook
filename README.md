# AWS → Azure Migration: In-Guest Cleanup Runbook

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Azure](https://img.shields.io/badge/Azure-Compatible-0078D4?logo=microsoft-azure)](https://azure.microsoft.com)
[![Azure Migrate](https://img.shields.io/badge/Azure_Migrate-Integrated-0078D4?logo=microsoft-azure)](https://learn.microsoft.com/en-us/azure/migrate/)
[![Unit Tests](https://github.com/DarylsCorner/aws-azure-migration-runbook/actions/workflows/unit-tests.yml/badge.svg)](https://github.com/DarylsCorner/aws-azure-migration-runbook/actions/workflows/unit-tests.yml)

Removes AWS-specific in-guest components from VMs migrated to Azure via **Azure Migrate**.  
Every action is **idempotent** and **non-destructive to application binaries**, making it safe to run during Test Migration and again at final cutover.

> **Running a migration?** See [OPERATOR-GUIDE.md](OPERATOR-GUIDE.md) for step-by-step instructions including snapshot requirements, dry-run procedure, and rollback.

---

## Prerequisites

| Requirement | Details |
|-------------|----------|
| Azure subscription | Operator needs Contributor on the resource group containing the Automation Account; VM Contributor on VMs being cleaned |
| Azure CLI | `az` — for setup and role assignment |
| PowerShell | 7.0+ on the operator machine (runbook itself runs in the Automation sandbox at PS 7.2) |
| Target VMs — Windows | **PowerShell 5.1+** on the VM (ships with Windows Server 2016+). VMs running WS2012 R2 (PS 4.0) are hard-blocked; Azure Migrate assessment should flag these for an in-place OS upgrade first. |
| Target VMs — Linux | Bash 4+, Python 3, systemd or SysV init |
| Azure VM Agent | Must be installed and running on target VMs (installed automatically by Azure Migrate) |

---

## Repository Layout

```
.
├── windows/
│   └── Invoke-AWSCleanup.ps1          # Windows in-guest cleanup (PowerShell, requires admin)
├── linux/
│   └── invoke-aws-cleanup.sh          # Linux in-guest cleanup (Bash, requires root)
├── runbook/
│   └── Start-MigrationCleanup.ps1     # Azure Automation Runbook orchestrator
├── validation/
│   ├── Invoke-MigrationReadiness.ps1  # Windows in-guest readiness auditor (read-only)
│   └── invoke-migration-readiness.sh  # Linux in-guest readiness auditor (read-only)
└── tests/
    ├── Setup-AutomationInfra.ps1      # Provisions Azure Automation Account + optional storage
    ├── TESTING.md                     # Test strategy, log, and open items
    └── Unit/                          # Pester unit tests (175 tests, no Azure dependency)
```

---

## What each script does

### `windows/Invoke-AWSCleanup.ps1`

Runs **inside the Windows VM** (directly or via Run Command).

| Section | Action | Phase |
|---------|--------|-------|
| 2 | Stop and disable AWS services (SSM Agent, CloudWatch Agent, EC2Config, EC2Launch v1/v2, Kinesis Agent, CodeDeploy Agent) | Both |
| 3 | Remove machine-scope AWS environment variables and service-account `.aws` credential directories | Both |
| 4 | Remove AWS-specific EC2-internal entries from `hosts` file | Both |
| 5 | Remove known AWS scheduled tasks; flag unknown Amazon tasks for review | Both |
| 6 | Remove AWS service registry hives (EC2Config, EC2Launch, SSM, CloudWatch) | Both |
| 7 | Uninstall AWS MSIs (SSM Agent, CloudWatch Agent, EC2Config, EC2Launch, Kinesis Agent) | **Cutover only** |
| 8 | Verify Azure VM Agent (`WindowsAzureGuestAgent`) is running | Both |

**AWS CLI is intentionally not uninstalled.** Application code may call `aws` commands. Flag for application owner review.

**PV/ENA/NVMe drivers are not touched.** Azure Migrate replaces boot-critical drivers during the replication phase.

---

### `linux/invoke-aws-cleanup.sh`

Runs **inside the Linux VM** (directly or via Run Command). Supports Amazon Linux, RHEL/CentOS (yum/dnf), Ubuntu/Debian (apt).

| Section | Action | Phase |
|---------|--------|-------|
| 2 | Stop and disable AWS services (SSM Agent, CloudWatch Agent, awslogs, EC2 Instance Connect, cfn-hup, CodeDeploy Agent) | Both |
| 3 | Remove AWS packages via the host's package manager | Both |
| 4 | Remove root and service-account `.aws` credential directories; flag `/home/*/.aws` for review | Both |
| 5 | Remove AWS environment variables from `/etc/environment`, `/etc/profile`, `/etc/bashrc` | Both |
| 6 | Remove AWS-specific EC2-internal entries from `/etc/hosts` | Both |
| 7 | Reconfigure cloud-init: comment out AWS datasource, write Azure datasource drop-in; purge cloud-init instance cache | Both |
| 8 | Log loaded AWS/Xen kernel modules — **not removed** | Informational |
| 9 | Remove AWS log directories, cfn residuals, EC2 Instance Connect config | **Cutover only** |
| 10 | Enable and start `waagent` (Azure Linux Agent) | Both |

**AWS CLI is intentionally not removed.** `/home/*/.aws` directories are intentionally not auto-removed.

---

### `runbook/Start-MigrationCleanup.ps1`

Azure Automation PowerShell Runbook that orchestrates the in-guest cleanup from the Azure control plane.

**Flow:**
1. Authenticates via the Automation Account's **system-assigned Managed Identity**
2. Retrieves the target VM and detects its OS type
3. **PS version gate** (Windows only) — aborts with a clear error if the VM has PowerShell < 5.1; Azure Migrate assessment should have flagged these VMs for an in-place OS upgrade to WS2016+ first
4. **Snapshot gate** — aborts unless the VM's OS disk has tag `MigrationSnapshot=true` (bypass with `-RequireSnapshotTag $false`)
5. Uses the in-guest cleanup script **embedded at publish time** (no storage access needed at runtime). Pass `-CleanupScriptStorageAccountName` to download a fresh copy from Blob Storage instead (useful for Hybrid Runbook Worker deployments).
6. Invokes the script via **Run Command** (`RunPowerShellScript` / `RunShellScript`)
7. Retrieves the JSON report written inside the VM and surfaces it to the Runbook output stream

---

### `validation/Invoke-MigrationReadiness.ps1`

Read-only **in-guest auditor** for Windows. Produces a JSON report listing every AWS component found or not found. Run it:

- **Before cleanup** (`-Mode Pre`) to understand the blast radius
- **After cleanup** (`-Mode Post`) to verify the VM is clean and Azure agent is healthy
- **Both** (default) for a complete picture with pass/fail assertions

---

### `validation/invoke-migration-readiness.sh`

Read-only **in-guest auditor** for Linux. Same Pre/Post/Both modes as the Windows version. Produces a JSON-format report covering: AWS services, packages, credential directories, environment variables, hosts entries, cloud-init datasource, kernel modules, and Azure Linux Agent health. Supports Amazon Linux, RHEL/CentOS, Ubuntu/Debian.

```bash
# Pre-cleanup discovery
sudo bash validation/invoke-migration-readiness.sh --mode pre

# Post-cleanup verification
sudo bash validation/invoke-migration-readiness.sh --mode post
```

---

## Recommended Workflow

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AZURE MIGRATE TEST MIGRATION                                               │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. Azure Migrate creates test VM                                           │
│  2. Take manual Azure snapshot / restore point of the OS disk               │
│  3. Tag the OS disk:  MigrationSnapshot=true                                │
│  4. Run Readiness Audit (-Mode Pre)  →  review findings                     │
│  5. Run Start-MigrationCleanup  -Phase TestMigration  -DryRun $true         │
│     Review dry-run output                                                   │
│  6. Run Start-MigrationCleanup  -Phase TestMigration  -DryRun $false        │
│  7. Run Readiness Audit (-Mode Post)  →  confirm clean                      │
│  8. Test application functionality                                           │
│  9. Azure Migrate: clean up test VM                                         │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  CUTOVER                                                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│  1. Azure Migrate final replication sync                                    │
│  2. Azure Migrate: Migrate (create production VM)                           │
│  3. Take snapshot / restore point of the OS disk                            │
│  4. Tag the OS disk:  MigrationSnapshot=true                                │
│  5. Run Start-MigrationCleanup  -Phase Cutover  -DryRun $true               │
│     Review dry-run output                                                   │
│  6. Run Start-MigrationCleanup  -Phase Cutover  -DryRun $false              │
│  7. Run Readiness Audit (-Mode Post)  →  confirm clean                      │
│  8. Decommission source AWS instance                                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Setup

### Recommended: automated setup

`tests/Setup-AutomationInfra.ps1` provisions everything in one step: Automation Account, system-assigned Managed Identity, role assignments, and the published runbook with **in-guest scripts embedded** (no storage account needed at runtime).

```powershell
# Provision Automation Account + publish runbook with embedded scripts
.\tests\Setup-AutomationInfra.ps1 -ResourceGroup <rg> -Location <region>

# Optional: also provision a storage account (Hybrid Runbook Worker / private-storage scenarios)
.\tests\Setup-AutomationInfra.ps1 -ResourceGroup <rg> -Location <region> -WithStorage
```

The script is **idempotent** — safe to re-run; it skips resources that already exist.

### Manual setup (alternative)

#### 1. Azure Automation Account

```bash
# Create Automation Account with system-assigned Managed Identity
az automation account create \
  --name "migration-automation" \
  --resource-group "<rg>" \
  --location "<region>" \
  --assign-identity "[system]"

# Grant the Managed Identity VM Contributor on the target resource group
az role assignment create \
  --role "Virtual Machine Contributor" \
  --assignee-object-id "<managed-identity-object-id>" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>"
```

#### 2. Publish runbook

The runbook embeds `windows/Invoke-AWSCleanup.ps1` and `linux/invoke-aws-cleanup.sh` as base64 at publish time. Use `Setup-AutomationInfra.ps1` to handle this automatically, or base64-encode and inject the placeholders `__WINDOWS_SCRIPT_B64__` / `__LINUX_SCRIPT_B64__` manually before uploading.

#### 3. Storage account (Hybrid Runbook Worker / private-storage only)

Only required if you pass `-CleanupScriptStorageAccountName` at runtime:

```bash
az storage account create --name "<storageaccount>" --resource-group "<rg>" --sku Standard_LRS
az storage container create --name "migration-scripts" --account-name "<storageaccount>"

# Grant Managed Identity Storage Blob Data Reader
az role assignment create \
  --role "Storage Blob Data Reader" \
  --assignee-object-id "<managed-identity-object-id>" \
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storageaccount>"

az storage blob upload --account-name "<storageaccount>" --container-name "migration-scripts" \
  --name "Invoke-AWSCleanup.ps1" --file "windows/Invoke-AWSCleanup.ps1" --auth-mode login
az storage blob upload --account-name "<storageaccount>" --container-name "migration-scripts" \
  --name "invoke-aws-cleanup.sh" --file "linux/invoke-aws-cleanup.sh" --auth-mode login
```

#### 4. Tag the OS disk before running

```bash
DISK_NAME=$(az vm show -g <rg> -n <vmname> --query storageProfile.osDisk.name -o tsv)
az disk update --name "$DISK_NAME" --resource-group "<rg>" \
  --set tags.MigrationSnapshot=true
```

---

## Running the scripts directly (without Automation)

### Windows — in-guest

```powershell
# Dry-run discovery
.\windows\Invoke-AWSCleanup.ps1 -DryRun -Phase TestMigration

# Test-migration cleanup
.\windows\Invoke-AWSCleanup.ps1 -Phase TestMigration

# Cutover cleanup
.\windows\Invoke-AWSCleanup.ps1 -Phase Cutover -ReportPath C:\Logs\cleanup.json
```

### Linux — in-guest

```bash
# Dry-run discovery
sudo bash linux/invoke-aws-cleanup.sh --dry-run --phase test-migration

# Test-migration cleanup
sudo bash linux/invoke-aws-cleanup.sh --phase test-migration

# Cutover cleanup
sudo bash linux/invoke-aws-cleanup.sh --phase cutover --report /var/log/migration-cleanup.json
```

### Validation / Readiness Audit

```powershell
# Pre-cleanup: discover what AWS components exist
.\validation\Invoke-MigrationReadiness.ps1 -Mode Pre

# Post-cleanup: verify everything is gone
.\validation\Invoke-MigrationReadiness.ps1 -Mode Post
```

---

## What is intentionally NOT done

| Item | Reason |
|------|--------|
| AWS CLI binaries | Application code may invoke `aws` commands. Must be reviewed by app owner. |
| `/home/*/.aws` directories | User credentials belong to app owners, not the migration team. |
| ENA / NVMe / Xen kernel modules | Azure Migrate replaces these during replication. Removing them in-guest risks connectivity loss. |
| `/etc/fstab` EBS entries | Mount points are application-specific. |
| Application configuration files | Changing app config that references S3, SQS, SNS, etc. is in-scope for the application migration, not this runbook. |
| Auto-run without gates | The snapshot gate and dry-run mode exist to prevent accidental data loss. |

---

## JSON Report Schema

Both in-guest cleanup scripts produce a JSON report:

```json
{
  "schemaVersion": "1.0",
  "timestamp": "2026-02-25T14:30:00Z",
  "ComputerName": "VM-NAME",
  "phase": "TestMigration",
  "dryRun": false,
  "actions": [
    {
      "Name": "Disable Service: AWS SSM Agent",
      "Status": "Completed",
      "Detail": "Stopped and disabled"
    }
  ],
  "summary": {
    "total": 42,
    "completed": 18,
    "skipped": 22,
    "dryRun": 0,
    "errors": 2
  }
}
```

`Status` values:

| Value | Meaning |
|-------|---------|
| `Completed` | Action was taken successfully |
| `Skipped` | Component was not present — nothing to do |
| `DryRun` | Would have acted but DryRun mode is on |
| `Error` | Action attempted but failed — review the `Detail` field |

---

## Testing

Unit tests live in `tests/Unit/` and cover all three PowerShell scripts. They have no Azure dependency and run anywhere PowerShell 7 + Pester 5 is available.

```powershell
# Install Pester if needed
Install-Module Pester -Force -Scope CurrentUser

# Run all unit tests
Invoke-Pester .\tests\Unit\
```

Current status: **175 tests, 0 failures** across `Start-MigrationCleanup`, `Invoke-AWSCleanup`, and `Invoke-MigrationReadiness`.

See [tests/TESTING.md](tests/TESTING.md) for the full four-layer test strategy (unit, integration, dirty-box, readiness) and the test log.

---

## Contributing / Extending

To add a new AWS component to the Windows cleanup:

1. Add a `Disable-ServiceIfPresent` or `Uninstall-ProgramIfPresent` call in `Invoke-AWSCleanup.ps1`
2. Add the corresponding `Check-Service` or `Check-InstalledProgram` call in `Invoke-MigrationReadiness.ps1`
3. Test with `-DryRun` first
4. Re-upload the updated scripts to the Storage Account blob container

---

## Known Limitations / Future Enhancements

| # | Area | Description |
|---|---|---|
| 1 | **Database-hosting VMs** | VMs running databases may carry additional AWS artifacts not currently discovered or cleaned: RDS CA certificates (`C:\Program Files\Amazon\RDS\`, `/etc/ssl/certs/rds-ca-*.pem`), connection strings referencing `*.rds.amazonaws.com` / `*.cache.amazonaws.com` in app config files, S3-backed DB dump jobs in Task Scheduler or cron, Secrets Manager / SSM Parameter Store ARNs in config files, and the DMS replication agent. Plan: add a `-ScanDatabases` opt-in module to `Invoke-PreScan.ps1` and corresponding cleanup steps. |
| 2 | **Scheduled task creation under SYSTEM** | `Plant-TestArtifacts.ps1` cannot create scheduled tasks via SSM (runs as SYSTEM, no SID mapping). Tasks must be planted via RDP or a domain-joined runner. Impact: scheduled task cleanup path is not exercised in the AWS test environment. |
