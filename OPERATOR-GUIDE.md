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

### Windows

```powershell
# Run inside the VM or via Run Command
.\validation\Invoke-MigrationReadiness.ps1 -Mode Post
```

A passing post-audit shows:
- All AWS service checks: `NotFound` or `Disabled`
- All AWS credential directories: `NotFound`
- Azure VM Agent: `Running`
- No `Error` status items

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

## Related Documents

| Document | Purpose |
|---|---|
| [README.md](README.md) | Technical reference — script internals, JSON schema, setup details |
| [tests/TESTING.md](tests/TESTING.md) | Test strategy, test log, known issues found during development |
