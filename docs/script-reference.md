# Script Reference

Detailed reference for every script in this repository. For step-by-step migration instructions see [OPERATOR-GUIDE.md](../OPERATOR-GUIDE.md).

---

## `windows/Invoke-AWSCleanup.ps1`

Runs **inside the Windows VM** (directly or via `az vm run-command`). Requires local admin. Every section is idempotent — safe to run more than once.

| Section | Action | Phase |
|---------|--------|-------|
| 2 | Stop and disable AWS services (SSM Agent, CloudWatch Agent, EC2Config, EC2Launch v1/v2, Kinesis Agent, CodeDeploy Agent) | Both |
| 3 | Remove machine-scope AWS environment variables and service-account `.aws` credential directories | Both |
| 4 | Remove AWS-specific EC2-internal entries from `hosts` file | Both |
| 5 | Remove known AWS scheduled tasks; flag unknown Amazon tasks for review | Both |
| 6 | Remove AWS service registry hives (EC2Config, EC2Launch, SSM, CloudWatch) | Both |
| 7 | Uninstall AWS MSIs (SSM Agent, CloudWatch Agent, EC2Config, EC2Launch, Kinesis Agent) | **Cutover only** |
| 8 | Verify Azure VM Agent (`WindowsAzureGuestAgent`) is running | Both |
| 9 | Write JSON report to `C:\ProgramData\MigrationLogs\` | Both |

**AWS CLI is intentionally not uninstalled.** Application code may call `aws` commands — flag for app owner review.

**PV/ENA/NVMe drivers are not touched.** Azure Migrate replaces boot-critical drivers during replication.

---

## `linux/invoke-aws-cleanup.sh`

Runs **inside the Linux VM** (directly or via `az vm run-command`). Requires root. Supports Amazon Linux, RHEL/CentOS (yum/dnf), Ubuntu/Debian (apt).

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

## `runbook/Start-MigrationCleanup.ps1`

Azure Automation PowerShell Runbook that orchestrates in-guest cleanup from the Azure control plane.

**Flow:**
1. Authenticates via the Automation Account's **system-assigned Managed Identity**
2. Retrieves the target VM and detects its OS type
3. **PS version gate** (Windows only) — aborts if PowerShell < 5.1 is detected
4. **Snapshot gate** — aborts unless the VM's OS disk has tag `MigrationSnapshot=true` (bypass with `-RequireSnapshotTag $false`)
5. Uses the in-guest cleanup script **embedded at publish time** (no storage access needed at runtime). Pass `-CleanupScriptStorageAccountName` to download a fresh copy from Blob Storage instead (useful for Hybrid Runbook Worker deployments).
6. Invokes the script via **Run Command** (`RunPowerShellScript` / `RunShellScript`)
7. Retrieves the JSON report written inside the VM and surfaces it to the Runbook output stream

---

## `validation/Invoke-MigrationReadiness.ps1`

Read-only **in-guest auditor** for Windows. Produces a JSON report listing every AWS component found or not found. Never modifies the VM.

Run in three modes:

| Mode | When to use |
|------|-------------|
| `-Mode Pre` | Before any cleanup — inventory what's present (no pass/fail assertion) |
| `-Mode Post` | After cleanup — asserts `Found = 0` and Azure agent is healthy |
| (default) | Both modes combined |

Output is written to `C:\ProgramData\MigrationLogs\readiness-<Phase>-<timestamp>.*`.

> **Expected post-Cutover result:** `Found: 0, Clean: 46, Warnings: 0`

---

## `validation/invoke-migration-readiness.sh`

Read-only **in-guest auditor** for Linux. Same Pre/Post/Both modes as the Windows version. Produces a JSON-format report covering: AWS services, packages, credential directories, environment variables, hosts entries, cloud-init datasource, kernel modules, and Azure Linux Agent health. Supports Amazon Linux, RHEL/CentOS, Ubuntu/Debian.

```bash
# Pre-cleanup discovery
sudo bash validation/invoke-migration-readiness.sh --mode pre

# Post-cleanup verification
sudo bash validation/invoke-migration-readiness.sh --mode post
```

---

## JSON Report Schema

### Cleanup report (`cleanup-<Phase>-<timestamp>.json`)

```json
{
  "SchemaVersion": "1.0",
  "Timestamp": "2026-02-25T14:30:00Z",
  "ComputerName": "VM-NAME",
  "Phase": "Cutover",
  "DryRun": false,
  "Actions": [
    {
      "Name": "Disable Service: AmazonSSMAgent",
      "Status": "Completed",
      "Detail": "Stopped and disabled"
    }
  ],
  "Summary": {
    "Total": 42,
    "Completed": 18,
    "Skipped": 22,
    "DryRun": 0,
    "Errors": 0
  }
}
```

`Status` values:

| Value | Meaning |
|-------|---------|
| `Completed` | Action taken successfully |
| `Skipped` | Component was not present — nothing to do |
| `DryRun` | Would have acted but DryRun mode is on |
| `Error` | Action attempted but failed — review the `Detail` field |

### Readiness report (`readiness-<Phase>-<timestamp>.json`)

```json
{
  "SchemaVersion": "1.0",
  "Timestamp": "2026-02-25T15:00:00Z",
  "ComputerName": "VM-NAME",
  "Mode": "Post",
  "Phase": "Cutover",
  "Findings": [
    {
      "Category": "Services",
      "Name": "AmazonSSMAgent",
      "Status": "Clean",
      "Detail": "Service not found"
    }
  ],
  "Summary": {
    "Found": 0,
    "NotFound": 46,
    "Pass": 2,
    "Fail": 0,
    "Warning": 0,
    "Info": 0
  },
  "PostAssertions": {
    "AwsComponentsFound": false,
    "AzureAgentFailed": false,
    "CleanState": true
  }
}
```

See [reports/examples/](../reports/examples/) for real output samples from each phase.

---

## Setup — Azure Automation

### Automation Account

```powershell
# Create Automation Account with system-assigned Managed Identity
az automation account create `
  --name "migration-automation" `
  --resource-group "<rg>" `
  --location "<region>" `
  --assign-identity "[system]"

# Grant the Managed Identity VM Contributor on the target resource group
az role assignment create `
  --role "Virtual Machine Contributor" `
  --assignee-object-id "<managed-identity-object-id>" `
  --scope "/subscriptions/<sub>/resourceGroups/<rg>"
```

### Publish runbook

The runbook embeds `windows/Invoke-AWSCleanup.ps1` and `linux/invoke-aws-cleanup.sh` as base64 at publish time. Base64-encode and inject the placeholders `__WINDOWS_SCRIPT_B64__` / `__LINUX_SCRIPT_B64__` before uploading.

### Storage account (Hybrid Runbook Worker / private-storage only)

Only required if you pass `-CleanupScriptStorageAccountName` at runtime:

```powershell
az storage account create --name "<storageaccount>" --resource-group "<rg>" --sku Standard_LRS
az storage container create --name "migration-scripts" --account-name "<storageaccount>"

# Grant Managed Identity Storage Blob Data Reader
az role assignment create `
  --role "Storage Blob Data Reader" `
  --assignee-object-id "<managed-identity-object-id>" `
  --scope "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<storageaccount>"

az storage blob upload --account-name "<storageaccount>" --container-name "migration-scripts" `
  --name "Invoke-AWSCleanup.ps1" --file "windows/Invoke-AWSCleanup.ps1" --auth-mode login
az storage blob upload --account-name "<storageaccount>" --container-name "migration-scripts" `
  --name "invoke-aws-cleanup.sh" --file "linux/invoke-aws-cleanup.sh" --auth-mode login
```

---

## Extending the scripts

To add a new AWS component to the Windows cleanup:

1. Add a `Disable-ServiceIfPresent`, `Remove-RegistryKey`, or `Uninstall-ProgramIfPresent` call in `windows/Invoke-AWSCleanup.ps1`
2. Add the corresponding `Check-Service`, `Check-RegistryKey`, or `Check-InstalledProgram` call in `validation/Invoke-MigrationReadiness.ps1`
3. Test with `-DryRun` first before running live
4. If using the Azure Automation runbook, re-publish with the updated embedded scripts

---

## Known Limitations

| # | Area | Description |
|---|------|-------------|
| 1 | **Database-hosting VMs** | VMs with RDS CA certificates, SSM Parameter Store ARNs in app config, or S3-backed DB dump jobs require additional scan steps not covered by the current scripts. |
| 2 | **Scheduled task creation under SYSTEM** | When using SSM to plant test artifacts, tasks created as SYSTEM may not map correctly. Use RDP or a domain-joined runner for test environment setup. |
