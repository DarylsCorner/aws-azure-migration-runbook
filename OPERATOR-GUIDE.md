# AWS → Azure Migration: Operator Guide

Step-by-step instructions for running the in-guest cleanup runbook against a migrated VM.
This guide is written for the operator who will execute the migration, not the engineer who built the tooling.

---

## Before You Begin

### Prerequisites

| Requirement | How to verify |
|---|---|
| Azure Automation Account provisioned | `az automation account show -g rg-migration-test -n aa-migration-test` |
| Automation Account has system-assigned Managed Identity | Check Identity tab in Azure Portal, or see README Setup section |
| Managed Identity has `Virtual Machine Contributor` on the VM's resource group | `az role assignment list --assignee <mi-principal-id>` |
| `az` CLI installed and logged in | `az account show` |

If the Automation Account is not yet provisioned, see the **Setup** section in [README.md](README.md) or run:

```powershell
.\tests\Setup-AutomationInfra.ps1
```

---

## Overview

The cleanup runs in **two phases** matching the Azure Migrate workflow:

| Phase | When to run | What it does |
|---|---|---|
| `TestMigration` | After Azure Migrate creates the test VM | Disables all AWS services, removes credentials/env vars, reconfigures cloud-init. MSI/package uninstalls **deferred**. |
| `Cutover` | After Azure Migrate creates the production VM | All of TestMigration **plus** uninstalls AWS packages, removes log directories, purges cfn residuals. |

Always run `TestMigration` first on the test VM before touching the production cutover VM.

---

## Step 1 — Take a Snapshot (Required)

The runbook will **refuse to run** unless the VM's OS disk has been snapshotted and tagged.
This is a safety gate that ensures you have a recovery point before any changes are made.

### 1a. Find the OS disk ID

```bash
DISK_ID=$(az vm show \
  --resource-group <your-resource-group> \
  --name <vm-name> \
  --query "storageProfile.osDisk.managedDisk.id" \
  --output tsv)

echo $DISK_ID
```

### 1b. Create a snapshot

```bash
az snapshot create \
  --resource-group <your-resource-group> \
  --name <vm-name>-pre-cleanup-snapshot \
  --source "$DISK_ID"
```

This typically completes in 1–3 minutes. You can verify it in the Azure Portal under **Snapshots** in the resource group.

> **Tip:** If Azure Migrate already created a restore point during replication, you may use that as your recovery point and skip directly to step 1c. Confirm with your Azure Migrate administrator.

### 1c. Tag the disk

This tag signals to the runbook that a recovery point exists and cleanup may proceed.

```bash
az resource tag \
  --ids "$DISK_ID" \
  --tags MigrationSnapshot=true
```

Verify the tag was applied:

```bash
az resource show --ids "$DISK_ID" --query tags
# Expected output: { "MigrationSnapshot": "true" }
```

> **Important:** Use `az resource tag`, not `az disk update --set tags...`. The `--set` flag silently fails to write a string-typed tag value in some CLI versions.

---

## Step 2 — Dry Run (Recommended)

Run in dry-run mode first. No changes are made to the VM — the runbook reports what **would** happen.
This lets you review the action list and catch anything unexpected before committing.

```powershell
.\tests\Invoke-RunbookTest.ps1 `
  -VMName        <vm-name> `
  -ResourceGroup <your-resource-group> `
  -Phase         TestMigration `
  -DryRun `
  -RequireSnapshotTag $true
```

Review the output. Look for any actions with `Status: Error` — investigate those before proceeding.

A clean dry-run on a freshly migrated VM typically shows **all Skipped** (no AWS software installed yet by Azure Migrate). On a real AWS-origin VM you will see `DryRun` entries for each component that would be removed.

---

## Step 3 — TestMigration Phase (Live)

Once the dry-run looks correct, run live:

```powershell
.\tests\Invoke-RunbookTest.ps1 `
  -VMName        <vm-name> `
  -ResourceGroup <your-resource-group> `
  -Phase         TestMigration `
  -RequireSnapshotTag $true
```

**Expected outcome:** All AWS services stopped and disabled, credentials/env vars removed, cloud-init reconfigured. MSI/package uninstalls are deferred to the Cutover phase.

After the job completes, validate the VM is healthy:

- Confirm the application still starts correctly
- Check no AWS services are running: `Get-Service | Where Name -like 'amazon*'` (Windows) or `systemctl list-units | grep amazon` (Linux)
- Review the JSON report saved in the runbook output

---

## Step 4 — Application Validation

Before proceeding to cutover, verify the application functions correctly in Azure:

- All application services start and respond to health checks
- Network connectivity to Azure services works (DNS, storage endpoints, etc.)
- No application dependencies on AWS-specific endpoints (e.g., EC2 metadata `169.254.169.254`, S3 paths)
- Logs show no AWS credential errors

If the application is broken, **restore from the snapshot** (see Rollback below) before proceeding.

---

## Step 5 — Cutover Phase

When you are ready for final cutover:

1. **Azure Migrate: trigger final replication sync** — ensures the production VM has the latest data
2. **Azure Migrate: Migrate** — creates the production VM
3. **Repeat Steps 1a–1c** on the production VM's OS disk (take a new snapshot, apply the tag)
4. Run the Cutover phase:

```powershell
.\tests\Invoke-RunbookTest.ps1 `
  -VMName        <vm-name> `
  -ResourceGroup <your-resource-group> `
  -Phase         Cutover `
  -DryRun `
  -RequireSnapshotTag $true
```

Review the dry-run, then run live:

```powershell
.\tests\Invoke-RunbookTest.ps1 `
  -VMName        <vm-name> `
  -ResourceGroup <your-resource-group> `
  -Phase         Cutover `
  -RequireSnapshotTag $true
```

---

## Step 6 — Post-Cutover Validation

Run the readiness auditor to verify the VM is fully clean.

### Windows — via az vm run-command (preferred)

```powershell
az vm run-command invoke `
  -g <resource-group> `
  -n <vm-name> `
  --command-id RunPowerShellScript `
  --scripts "@validation/Invoke-MigrationReadiness.ps1" `
  --parameters "Phase=Cutover" `
  --query "value[0].message" -o tsv
```

### Windows — directly inside the VM (via RDP or Bastion)

```powershell
.\validation\Invoke-MigrationReadiness.ps1 -Mode Post -Phase Cutover
```

A passing post-audit shows:

```
[PASS   ] No AWS components detected on this VM.
[PASS   ] All Azure agent checks passed.
  Found AWS components : 0
  Clean (not found)    : 39
  Azure checks passed  : 2
```

If any `[WARN ]` lines appear under **Heuristic Scans**, review them manually — they flag unlisted AWS artifacts (unknown services, registry keys, software, or directories matching `Amazon`/`AWS`/`EC2` keywords) that were not in the standard checklist. Decide whether each one should be removed before completing the migration.

### Linux

```bash
# Run inside the VM or via Run Command
sudo bash validation/invoke-migration-readiness.sh --mode post
```

A passing post-audit shows:
- All AWS service and package checks: `NotFound`
- All AWS credential directories: `NotFound`
- Azure Linux Agent (`waagent`): `Pass` (active and enabled)
- cloud-init datasource: Azure drop-in present, no Ec2 datasource
- Exit code `0`

---

## Rollback

If anything goes wrong after cleanup and the application is broken:

### Restore from snapshot (Azure Portal)

1. Stop the VM
2. Portal → Disks → Swap OS disk → select the snapshot (or create a new disk from the snapshot)
3. Start the VM

### Restore from snapshot (CLI)

```bash
# Create a new disk from the snapshot
az disk create \
  --resource-group <rg> \
  --name <vm-name>-restored-disk \
  --source <snapshot-name>

# Swap the OS disk (VM must be stopped)
az vm stop --resource-group <rg> --name <vm-name>
az vm update \
  --resource-group <rg> \
  --name <vm-name> \
  --os-disk <vm-name>-restored-disk
az vm start --resource-group <rg> --name <vm-name>
```

---

## Running the Cleanup Directly (Without Automation Account)

If you need to run the scripts directly inside the VM (e.g., via SSH or RDP without Automation):

### Windows

```powershell
# Dry-run first
.\windows\Invoke-AWSCleanup.ps1 -DryRun -Phase TestMigration

# Live TestMigration
.\windows\Invoke-AWSCleanup.ps1 -Phase TestMigration

# Live Cutover
.\windows\Invoke-AWSCleanup.ps1 -Phase Cutover -ReportPath C:\Logs\cleanup.json
```

### Linux

```bash
# Dry-run first
sudo bash linux/invoke-aws-cleanup.sh --dry-run --phase test-migration

# Live TestMigration
sudo bash linux/invoke-aws-cleanup.sh --phase test-migration

# Live Cutover
sudo bash linux/invoke-aws-cleanup.sh --phase cutover --report /var/log/migration-cleanup.json
```

> **Note:** Running directly bypasses the snapshot gate. Ensure you have a recovery point before running live.

---

## Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| Job fails: `SNAPSHOT GATE FAILED` | OS disk does not have `MigrationSnapshot=true` tag | Take a snapshot and apply the tag (Steps 1a–1c) |
| Job fails: `waagent not found` (Linux) | Azure Linux Agent not installed | `sudo apt-get install walinuxagent` or `sudo dnf install WALinuxAgent` and re-run |
| Job fails: `WindowsAzureGuestAgent is not Running` | Azure VM Agent stopped or uninstalled | Reinstall from [Microsoft Download Center](https://go.microsoft.com/fwlink/p/?LinkID=394789) |
| AWS services still present after TestMigration | Services come back on reboot (e.g., MSI re-enables them) | MSI uninstalls run on Cutover — this is expected for TestMigration |
| Report shows `Error` actions | A specific cleanup step failed | Review the `Detail` field for each Error action; re-run after fixing the underlying issue |
| Runbook job stuck in `Running` > 15 min | Run Command timed out on VM | VM may be unresponsive; check VM health in Azure Portal |

---

## Quick Reference

```powershell
# ---------- One-liner equivalents ----------

# TestMigration dry-run
.\tests\Invoke-RunbookTest.ps1 -VMName <vm> -Phase TestMigration -DryRun -RequireSnapshotTag $true

# TestMigration live
.\tests\Invoke-RunbookTest.ps1 -VMName <vm> -Phase TestMigration -RequireSnapshotTag $true

# Cutover dry-run
.\tests\Invoke-RunbookTest.ps1 -VMName <vm> -Phase Cutover -DryRun -RequireSnapshotTag $true

# Cutover live
.\tests\Invoke-RunbookTest.ps1 -VMName <vm> -Phase Cutover -RequireSnapshotTag $true

# Tag a disk (after taking snapshot)
az resource tag --ids $(az vm show -g <rg> -n <vm> --query "storageProfile.osDisk.managedDisk.id" -o tsv) --tags MigrationSnapshot=true
```

---

## Readiness Script Reference

Documents every check performed by `validation/Invoke-MigrationReadiness.ps1` and what it logs.
All checks are **read-only** — the script never modifies the VM.

### Check categories and status codes

| Status | Meaning |
|--------|---------|
| `[CLEAN  ]` | Artifact not found — expected post-cleanup |
| `[FOUND  ]` | Artifact present — counts as a failure in Post assertions |
| `[PASS   ]` | Azure check passed |
| `[FAIL   ]` | Azure check failed (blocks migration readiness) |
| `[WARN   ]` | Heuristic scan found something not in the known list — needs manual review |
| `[INFO   ]` | Informational only (e.g. agent version) |

---

### Specific checklist (hardcoded)

These are checked by name/path. Result is `FOUND` or `CLEAN`. In Post mode, any `FOUND` item fails the assertion.

#### Services

| Service Name | Description |
|---|---|
| `AmazonSSMAgent` | AWS Systems Manager Agent |
| `AmazonCloudWatchAgent` | AWS CloudWatch Agent |
| `EC2Config` | EC2Config (legacy, pre-2016 AMIs) |
| `EC2Launch` | EC2Launch v1 |
| `Amazon EC2Launch` | EC2Launch v2 |
| `KinesisAgent` | AWS Kinesis Agent for Windows |
| `AWSNitroEnclaves` | AWS Nitro Enclaves |
| `AWSCodeDeployAgent` | AWS CodeDeploy Agent |

#### Installed Software (uninstall registry)

| Pattern | Description |
|---|---|
| `Amazon SSM Agent*` | AWS Systems Manager Agent MSI |
| `Amazon CloudWatch Agent*` | CloudWatch Agent MSI |
| `EC2ConfigService*` | EC2Config MSI |
| `EC2Launch*` | EC2Launch MSI |
| `Amazon Kinesis Agent*` | Kinesis Agent MSI |
| `AWS CodeDeploy Agent*` | CodeDeploy Agent MSI |
| `AWS Command Line Interface*` | AWS CLI |
| `Amazon Web Services*` | Generic Amazon Web Services entry |

#### Registry keys

| Key Path | Description |
|---|---|
| `HKLM:\SOFTWARE\Amazon\EC2ConfigService` | EC2Config configuration hive |
| `HKLM:\SOFTWARE\Amazon\EC2Launch` | EC2Launch v1 configuration hive |
| `HKLM:\SOFTWARE\Amazon\EC2LaunchV2` | EC2Launch v2 configuration hive |
| `HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent` | CloudWatch Agent configuration hive |
| `HKLM:\SOFTWARE\Amazon\SSM` | SSM Agent configuration hive |
| `HKLM:\SOFTWARE\Amazon\PVDriver` | **Intentionally retained** — PV driver; do not remove |

#### Filesystem paths

| Path | Description |
|---|---|
| `C:\Program Files\Amazon\SSM` | SSM Agent binaries |
| `C:\Program Files\Amazon\AmazonCloudWatchAgent` | CloudWatch Agent binaries |
| `C:\Program Files\Amazon\EC2ConfigService` | EC2Config binaries |
| `%SystemRoot%\System32\config\systemprofile\.aws` | SYSTEM-context AWS credentials |
| `%SystemRoot%\ServiceProfiles\NetworkService\.aws` | NetworkService-context AWS credentials |

#### Environment variables (machine-scope)

`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`,
`AWS_REGION`, `AWS_PROFILE`, `AWS_CONFIG_FILE`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`

#### Hosts file entries

| Pattern | Description |
|---|---|
| `169\.254\.169\.254.*ec2\.internal` | EC2 metadata hostname alias |
| `instance-data\.ec2\.internal` | EC2 instance-data alias |

#### Scheduled tasks

| Task | Path |
|---|---|
| `Amazon EC2Launch - Instance Initialization` | `\` |
| `AmazonCloudWatchAutoUpdate` | `\Amazon\AmazonCloudWatch\` |
| Any task under `\Amazon\*` | Dynamic scan |

#### Azure readiness checks

| Check | Pass condition |
|---|---|
| `WindowsAzureGuestAgent` service | Running, StartType = Automatic |
| Azure IMDS (`169.254.169.254`) | Responds with `provider = Microsoft.Compute` |

---

### Heuristic scans (dynamic — logs as `[WARN ]`)

These scans catch **unknown or unlisted** AWS artifacts. They do not fail the Post assertion but appear in the report for manual review. Use them to identify novel artifacts on VMs that have custom tooling not covered by the specific checklist.

| Scan | What it looks for | Trigger |
|---|---|---|
| **Services (Heuristic)** | All services whose `DisplayName` or `Description` matches `amazon`, `aws`, `ec2`, or `ssm` (case-insensitive) — excluding the 8 already in the specific list | Any non-standard AWS service registration |
| **Registry (Heuristic)** | All sub-keys directly under `HKLM:\SOFTWARE\Amazon\` not in the specific list (excluding `PVDriver`) | Custom tools that write to the Amazon registry hive |
| **Installed Software (Heuristic)** | All programs in the uninstall registry whose `DisplayName` matches `\bAmazon\b`, `\bAWS\b`, or `\bEC2\b` — excluding the 8 already in the specific list | Bundled or third-party AWS-integrated software |
| **Filesystem (Heuristic)** | All subdirectories under `C:\Program Files\Amazon\` not in the specific list; also flags an empty `C:\Program Files\Amazon\` root at Cutover phase | Custom agent installations |
| **Scheduled Tasks (Heuristic)** | Any task under the `\Amazon\*` task folder not in the specific list | Agent update or reporting tasks |

> **Workflow:** After a readiness check, search the report for `"Status": "Warning"`. For each warning, determine whether the artifact is AWS-specific. If yes, remove it manually and add it to the specific checklist in both `Invoke-MigrationReadiness.ps1` and `Invoke-AWSCleanup.ps1` so future VMs are handled automatically.

---

## Related Documents

| Document | Purpose |
|---|---|
| [README.md](README.md) | Technical reference — script internals, JSON schema, setup details |
| [tests/TESTING.md](tests/TESTING.md) | Test strategy, test log, known issues found during development |
