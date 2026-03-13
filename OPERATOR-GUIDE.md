# AWS → Azure Migration: Operator Guide

End-to-end runbook for migrating a Windows VM from AWS to Azure using Azure Migrate/ASR.
Covers pre-failover source inventory, test failover validation, production cutover, and final readiness verification.

All site-specific details are collected at the start of each session.

---

## Setup — Do This Once

Complete this section once on the machine from which you will run the migration. Skip steps you have already done.

### 1. Required tools

| Tool | Minimum version | Install |
|---|---|---|
| PowerShell | 7.2+ | [aka.ms/powershell](https://aka.ms/powershell) |
| Azure CLI (`az`) | 2.50+ | `winget install Microsoft.AzureCLI` |
| AWS CLI (`aws`) | 2.x | [docs.aws.amazon.com/cli](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| Git | any | `winget install Git.Git` |
| AWS Session Manager plugin | any | `winget install Amazon.SessionManagerPlugin` |

Verify versions:

```powershell
pwsh --version
az --version | Select-String "azure-cli"
aws --version
git --version
```

### 2. Clone the runbook repository

**If you have not yet cloned the repo:**

```powershell
$REPO_DIR = Read-Host "Local path to clone into (e.g. C:\Migrations\runbook)"
git clone https://github.com/DarylsCorner/aws-azure-migration-runbook.git $REPO_DIR
Set-Location $REPO_DIR
```

**If you have already cloned the repo**, navigate to it and pull the latest:

```powershell
Set-Location "C:\path\to\your\cloned\repo"
git pull
```

All `az vm run-command` calls in this guide use `@`-prefixed script paths (e.g. `--scripts "@windows/Invoke-AWSCleanup.ps1"`). These paths are **relative to the directory where your terminal is currently running**. You must always be in the root of the cloned repo when running those commands.

```powershell
# Confirm you are in the right place
Get-Location
Get-ChildItem  # Should show: .github/  infra/  linux/  runbook/  tests/  validation/  windows/  README.md
```

### 3. Authenticate

```powershell
# Azure — interactive browser login
az login

# AWS — configure credentials (skip if already configured or using an instance role)
aws configure
# Prompts for: Access Key ID, Secret Access Key, Default region, Output format
```

Verify both:

```powershell
az account show --query "{Name:name, ID:id, State:state}" -o table
# Expected: State = Enabled
aws sts get-caller-identity --output table
```

### 4. Set the correct Azure subscription

If you have access to multiple subscriptions, list them first to find the right ID:

```powershell
az account list --query "[].{Name:name, ID:id, State:state}" -o table
```

Then set the one you want. **`$SUBSCRIPTION_ID` is required — it is used throughout this guide and in Phase 0.**

```powershell
$SUBSCRIPTION_ID = Read-Host "Azure Subscription ID"
az account set --subscription $SUBSCRIPTION_ID
az account show --query "{Name:name, ID:id, State:state}" -o table
# Confirm State = Enabled and the correct subscription is shown
```

> **Note:** `az account set` only persists for the current shell session. Repeat this step (or run Phase 0 below) whenever you open a new terminal.

---

## Workflow Overview

```
Phase 0  Bootstrap session variables
Phase 1  Pre-failover baseline — run readiness check on SOURCE VM (AWS, via SSM)
Phase 2  Test Failover (Portal)
Phase 3  Prepare test VM — snapshot + tag OS disk
Phase 4  TestMigration cleanup on test VM — dry-run → live → readiness check
Phase 5  Application validation
Phase 6  Retrieve & review logs from test VM
Phase 7  Cleanup test failover (Portal)
Phase 8  Planned Failover (Portal)
Phase 9  Prepare production VM — snapshot + tag OS disk
Phase 10 Cutover cleanup on production VM — dry-run → live → readiness check
Phase 11 Retrieve & review logs from production VM
Phase 12 Complete cutover (Portal)
```

---

## Phase 0 — Session Bootstrap

Paste this entire block into your PowerShell terminal at the start of every session.
You will be prompted for all site-specific values.

> **Note:** All `$variables` are in-memory only. If you restart or open a new terminal, re-run this entire Phase 0 block before continuing.

```powershell
# ── Azure ─────────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($SUBSCRIPTION_ID)) {
    $SUBSCRIPTION_ID = Read-Host "Azure Subscription ID"
}
$RG              = Read-Host "Azure Resource Group [press Enter for rg-mig-landing]"
if ([string]::IsNullOrWhiteSpace($RG)) { $RG = "rg-mig-landing" }

az account set --subscription $SUBSCRIPTION_ID
az account show --query "{Subscription:name, ID:id, State:state}" -o table

# ── AWS ───────────────────────────────────────────────────────────────────────
$AWS_REGION          = Read-Host "AWS Region [press Enter for us-east-1]"
if ([string]::IsNullOrWhiteSpace($AWS_REGION)) { $AWS_REGION = "us-east-1" }

$SOURCE_INSTANCE_ID  = Read-Host "Source EC2 Instance ID (e.g. i-0abc123def456)"

# ── Derived (populated later) ─────────────────────────────────────────────────
# $TEST_VM_NAME   — set in Phase 2 once the test VM appears in Azure
# $PROD_VM_NAME   — set in Phase 8 once the production VM appears in Azure
# $DISK_ID        — set per-VM in Phases 3 and 9

Write-Host ""
Write-Host "Session variables:" -ForegroundColor Cyan
Write-Host "  Subscription  : $SUBSCRIPTION_ID"
Write-Host "  Resource group: $RG"
Write-Host "  AWS Region    : $AWS_REGION"
Write-Host "  Source EC2    : $SOURCE_INSTANCE_ID"
```

### Prerequisites check

```powershell
# Verify AWS CLI + SSM access to source VM
aws ssm describe-instance-information `
  --filters "Key=InstanceIds,Values=$SOURCE_INSTANCE_ID" `
  --region $AWS_REGION `
  --query "InstanceInformationList[0].{ID:InstanceId,Status:PingStatus,Platform:PlatformType}" `
  --output table
# Expected: PingStatus = Online
```

---

## Phase 1 — Pre-Failover Baseline (Source VM in AWS)

Run the readiness script against the **source VM while it is still in AWS**. This captures a full inventory of every AWS artifact on the machine before anything is touched. Save this output — it is your reference for what was present and what needs to be removed.

> **Note:** The readiness script is too large to pass inline via `aws ssm send-command`. Use one of the two approaches below.

### Option A — SSM Session Manager (interactive, no RDP needed)

Requires the Session Manager plugin. If you see `SessionManagerPlugin is not found`, install it first:

```powershell
winget install Amazon.SessionManagerPlugin
# Restart your terminal after installing
```

If it still fails after restarting, the winget installer did not add itself to PATH. Fix for the **current session only**:

```powershell
$env:PATH += ";C:\Program Files\Amazon\SessionManagerPlugin\bin"
```

To fix it **permanently** (requires an admin terminal — right-click PowerShell → Run as Administrator):

```powershell
[System.Environment]::SetEnvironmentVariable(
    "PATH",
    [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";C:\Program Files\Amazon\SessionManagerPlugin\bin",
    "Machine"
)
# Then restart your terminal
```

```powershell
# Open an interactive PowerShell session on the source VM
aws ssm start-session `
  --target $SOURCE_INSTANCE_ID `
  --region $AWS_REGION `
  --document-name AWS-StartInteractiveCommand `
  --parameters command="powershell"
```

Once connected, in the remote session run:

```powershell
# Note: if you have forked this repo, replace 'DarylsCorner' with your own org name
$uri = "https://raw.githubusercontent.com/DarylsCorner/aws-azure-migration-runbook/main/validation/Invoke-MigrationReadiness.ps1"
$script = (Invoke-WebRequest -Uri $uri -UseBasicParsing).Content
& ([scriptblock]::Create($script)) -Mode Pre -Phase TestMigration
# Output is written to C:\ProgramData\MigrationLogs\ on this VM
```

> **Expected:** Every AWS component on the source VM will show as `[FOUND  ]`. This is correct — the source VM is untouched. The script runs in inventory-only mode (`-Mode Pre`) and does **not** assert a clean state.
>
> **Audit note:** Passing `-Phase TestMigration` names the output file `readiness-TestMigration-<timestamp>.*`. Since ASR replicates the full disk, this file will be present on the Azure VMs after failover alongside the post-cleanup `readiness-Cutover-<timestamp>.*` files — making before/after clearly distinguishable without relying on timestamps alone.

### Review the baseline report

While still in the SSM session, you can read the JSON report before closing:

```powershell
$report = Get-ChildItem "C:\ProgramData\MigrationLogs\readiness-TestMigration-*.json" |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-Content $report.FullName | ConvertFrom-Json | ConvertTo-Json -Depth 10
```

Type `exit` to close the session when done.

### Download the report to your local machine

From your **local terminal** (not inside the SSM session), pull the report without needing RDP or S3:

```powershell
$cmdId = aws ssm send-command `
  --instance-ids $SOURCE_INSTANCE_ID `
  --region $AWS_REGION `
  --document-name "AWS-RunPowerShellScript" `
  --parameters 'commands=["$f = Get-ChildItem C:\\ProgramData\\MigrationLogs\\readiness-TestMigration-*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1; Get-Content $f.FullName -Raw"]' `
  --query "Command.CommandId" --output text

Start-Sleep -Seconds 5

aws ssm get-command-invocation `
  --command-id $cmdId `
  --instance-id $SOURCE_INSTANCE_ID `
  --region $AWS_REGION `
  --query "StandardOutputContent" `
  --output text | Out-File "readiness-TestMigration-source.json"
```

The report is saved locally as `readiness-TestMigration-source.json` in whatever directory your terminal is running from.

> **Tip:** Open it in VS Code with `code readiness-TestMigration-source.json` for readable JSON formatting.

### Option B — RDP directly to the source VM

1. RDP into the source EC2 instance
2. Open PowerShell and run:

```powershell
# If you have the repo cloned on the source VM:
cd C:\path\to\aws-azure-migration-runbook
.\validation\Invoke-MigrationReadiness.ps1 -Mode Pre -Phase TestMigration
```

Or download from GitHub as in Option A.

Output is written to `C:\ProgramData\MigrationLogs\` on the source VM.

---

**Save the output.** This is your pre-migration state capture, recorded as `readiness-TestMigration-<timestamp>.*` on the VM. Any artifact listed as `[FOUND  ]` here should appear as `[CLEAN  ]` in the post-Cutover `readiness-Cutover-<timestamp>.*` report.

---

## Phase 2 — Test Failover (Portal)

1. **Portal** → Recovery Services Vault → select the vault → **Replicated Items** → select the VM
2. Verify **Replication health: Healthy** and **RPO** shows a recent timestamp (< 1 hour)
3. Click **Test Failover**
   - Recovery point: **Latest**
   - Virtual network: select the landing zone VNet
   - Click **OK**
4. Monitor under **Jobs** — wait until the job status reaches **Successful** (~5–10 min)
5. Go to **Resource Groups** → confirm a new VM ending in `-test` is present and **Running**

Once the test VM is running, capture its name:

```powershell
$TEST_VM_NAME = Read-Host "Test VM name shown in portal (e.g. EC2AMAZ-NJ9HDHK-test)"
Write-Host "Test VM: $TEST_VM_NAME"
```

---

## Phase 3 — Prepare Test VM (Snapshot + Tag)

Take a snapshot of the test VM's OS disk before any changes are made. This is your rollback point.

```powershell
# Get the OS disk resource ID
$DISK_ID = az vm show `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --query "storageProfile.osDisk.managedDisk.id" `
  --output tsv

Write-Host "Disk ID: $DISK_ID"

# Create a snapshot
az snapshot create `
  --resource-group $RG `
  --name "$TEST_VM_NAME-pre-cleanup-snapshot" `
  --source $DISK_ID

# Tag the disk as having a recovery point
az resource tag `
  --ids $DISK_ID `
  --tags MigrationSnapshot=true

# Verify
az resource show --ids $DISK_ID --query tags -o json
# Expected: { "MigrationSnapshot": "true" }
```

Snapshot typically completes in 1–3 minutes. Confirm it appears in Portal under **Snapshots** in the resource group.

---

## Phase 4 — TestMigration Cleanup on Test VM

> **Requirement:** Before running any `az vm run-command` below, confirm the Azure VM Agent is installed and **Ready** on the test VM: Portal → VM → Properties → Agent status.

### 4a. Dry-run first (no changes made to the VM)

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=TestMigration" "DryRun=true" `
  --query "value[0].message" -o tsv
```

Review the output. Every AWS component present on the VM will appear with status `[DryRun]`. Components not present will show `[Skipped]`.

**Before proceeding, verify:**
- No `[ERROR ]` lines
- Expected AWS components appear under `[DryRun]` (cross-reference with the Phase 1 baseline)
- `Errors: 0` in the summary at the end

### 4b. Live TestMigration run

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=TestMigration" `
  --query "value[0].message" -o tsv
```

**Expected summary:**
```
Total   : <n>
Done    : <n>    ← actions completed
Skipped : <n>    ← components not present (fine)
Errors  : 0      ← must be 0
```

### 4c. Post-TestMigration readiness check

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@validation/Invoke-MigrationReadiness.ps1" `
  --parameters "Phase=TestMigration" `
  --query "value[0].message" -o tsv
```

**Expected output:**
```
[PASS   ] No AWS components detected on this VM.
[PASS   ] All Azure agent checks passed.
  Found AWS components : 0
  Clean (not found)    : 34
  Azure checks passed  : 2
  Warnings             : 0
```

> **Note:** MSI/package uninstalls are **deferred to Cutover phase** — this is by design. The TestMigration readiness check asserts that services and credentials are clean, not that packages are removed. Deferred items (binaries, MSIs) appear as `[INFO]` and are not counted in the summary — they do not fail the assertion.

If any `[WARN ]` heuristic entries appear, review them manually before proceeding (see **Readiness Script Reference**).

---

## Phase 5 — Application Validation

Before cleaning up the test failover, verify the application functions correctly in Azure:

- [ ] All application services start and respond to health checks
- [ ] Network connectivity to Azure services (DNS, storage endpoints, Key Vault, etc.) works
- [ ] No dependency on AWS-specific endpoints (EC2 metadata `169.254.169.254`, S3 paths, SQS, etc.)
- [ ] Application logs show no AWS credential errors
- [ ] Azure Monitor / Log Analytics receiving data from the VM

**Verify no AWS services are running:**

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "Get-Service | Where-Object { `$_.DisplayName -match 'amazon|aws|ec2|ssm' } | Select-Object Name, DisplayName, Status | Format-Table -AutoSize" `
  --query "value[0].message" -o tsv
```

If the application is broken, **restore from the snapshot** before proceeding (see **Rollback** section).

---

## Phase 6 — Retrieve and Review Logs from Test VM

Every script run writes a `.log` (transcript) and `.json` (structured report) to `C:\ProgramData\MigrationLogs\` on the VM.

### List all migration log files

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "Get-ChildItem C:\ProgramData\MigrationLogs\ | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize" `
  --query "value[0].message" -o tsv
```

### Read the most recent readiness report (JSON)

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "(Get-ChildItem C:\ProgramData\MigrationLogs\readiness-*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw)" `
  --query "value[0].message" -o tsv
```

### Read the most recent cleanup report (JSON)

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "(Get-ChildItem C:\ProgramData\MigrationLogs\cleanup-*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw)" `
  --query "value[0].message" -o tsv
```

### Read the most recent transcript

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $TEST_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "(Get-ChildItem C:\ProgramData\MigrationLogs\cleanup-*.log | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw)" `
  --query "value[0].message" -o tsv
```

**Compare with Phase 1 baseline:** Every artifact that appeared as `[FOUND  ]` in the pre-failover baseline should now show as `[CLEAN  ]` in the TestMigration readiness report.

---

## Phase 7 — Cleanup Test Failover (Portal)

Once Phases 4–6 pass:

1. **Portal** → Recovery Services Vault → select the vault → **Replicated Items** → select the VM
2. Click **Cleanup test failover**
3. Check **"Testing is complete. Delete test failover virtual machine"**
4. Click **OK**

Wait for the cleanup job to complete (~2–3 min). The `-test` VM will be deleted from the resource group.

---

## Phase 8 — Planned Failover (Portal)

1. **Portal** → Recovery Services Vault → select the vault → **Replicated Items** → select the VM
2. Verify **Replication health: Healthy** and RPO is recent
3. Click **Failover** (Planned Failover)
   - Direction: AWS → Azure
   - Recovery point: **Latest**
   - Check **"Shut down machine before beginning failover"** for a zero-data-loss cutover (the source VM will be powered off)
   - Click **OK**
4. Monitor under **Jobs** — wait until **Successful** (~5–15 min)
5. Go to **Resource Groups** → confirm the production VM is **Running**

Once the production VM is running, capture its name:

```powershell
$PROD_VM_NAME = Read-Host "Production VM name shown in portal (e.g. EC2AMAZ-NJ9HDHK)"
Write-Host "Production VM: $PROD_VM_NAME"
```

---

## Phase 9 — Prepare Production VM (Snapshot + Tag)

```powershell
# Get the OS disk resource ID for the production VM
$DISK_ID = az vm show `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --query "storageProfile.osDisk.managedDisk.id" `
  --output tsv

Write-Host "Disk ID: $DISK_ID"

# Create a snapshot
az snapshot create `
  --resource-group $RG `
  --name "$PROD_VM_NAME-pre-cleanup-snapshot" `
  --source $DISK_ID

# Tag the disk
az resource tag `
  --ids $DISK_ID `
  --tags MigrationSnapshot=true

# Verify
az resource show --ids $DISK_ID --query tags -o json
# Expected: { "MigrationSnapshot": "true" }
```

---

## Phase 10 — Cutover Cleanup on Production VM

### 10a. Dry-run (Cutover phase)

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=Cutover" "DryRun=true" `
  --query "value[0].message" -o tsv
```

Review carefully. The Cutover phase includes MSI/package uninstalls and scheduled-task removal that TestMigration deferred. Confirm these appear under `[DryRun]` before proceeding.

### 10b. Live Cutover run

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=Cutover" `
  --query "value[0].message" -o tsv
```

**Expected summary:** `Errors: 0`

### 10c. Post-Cutover readiness check

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@validation/Invoke-MigrationReadiness.ps1" `
  --parameters "Phase=Cutover" `
  --query "value[0].message" -o tsv
```

**Expected output (full clean):**
```
[PASS   ] No AWS components detected on this VM.
[PASS   ] All Azure agent checks passed.
  Found AWS components : 0
  Clean (not found)    : 39
  Azure checks passed  : 2
```

If any `[FOUND  ]` or `[WARN ]` items remain, **do not complete the cutover** until they are resolved. Refer to the **Readiness Script Reference** for what each finding means.

---

## Phase 11 — Retrieve and Review Logs from Production VM

### List log files

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "Get-ChildItem C:\ProgramData\MigrationLogs\ | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize" `
  --query "value[0].message" -o tsv
```

### Read most recent readiness report

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "(Get-ChildItem C:\ProgramData\MigrationLogs\readiness-*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw)" `
  --query "value[0].message" -o tsv
```

### Read most recent cleanup report

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "(Get-ChildItem C:\ProgramData\MigrationLogs\cleanup-*.json | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | Get-Content -Raw)" `
  --query "value[0].message" -o tsv
```

**Final validation:** Compare this readiness report against the Phase 1 pre-failover baseline. Every `[FOUND  ]` item from the baseline should now be `[CLEAN  ]` in this report.

### Remove migration log directory (manual)

The `C:\ProgramData\MigrationLogs\` directory is **not** removed automatically. Once you have finished reviewing all logs and are satisfied with the migration, clean it up manually:

```powershell
az vm run-command invoke `
  --resource-group $RG `
  --name $PROD_VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "Remove-Item -Path 'C:\ProgramData\MigrationLogs' -Recurse -Force" `
  --query "value[0].message" -o tsv
```

---

## Phase 12 — Complete Cutover (Portal)

Once Phase 10 readiness check passes and Phase 11 log review is complete:

1. **Portal** → Recovery Services Vault → select the vault → **Replicated Items** → select the VM
2. Click **Complete Cutover**
3. Confirm — this commits the migration and stops replication billing
4. Optionally: delete the Recovery Services Vault item now that replication is no longer needed

The source EC2 instance can now be stopped/terminated per your decommission plan.

---

## Rollback

If anything goes wrong after cleanup and the application is broken:

### Restore from snapshot (Portal)

1. Stop the VM in Portal
2. Portal → **Snapshots** → find `<vm-name>-pre-cleanup-snapshot` → **Create disk**
3. Portal → VM → **Stop** → **Disks** → **Swap OS disk** → select the newly created disk
4. Start the VM

### Restore from snapshot (CLI)

```powershell
$SNAPSHOT_NAME = Read-Host "Snapshot name to restore from"
$VM_TO_RESTORE = Read-Host "VM name to restore"

# Create a new disk from the snapshot
az disk create `
  --resource-group $RG `
  --name "$VM_TO_RESTORE-restored-disk" `
  --source $SNAPSHOT_NAME

# Stop the VM
az vm stop --resource-group $RG --name $VM_TO_RESTORE

# Swap the OS disk
az vm update `
  --resource-group $RG `
  --name $VM_TO_RESTORE `
  --os-disk "$VM_TO_RESTORE-restored-disk"

# Start the VM
az vm start --resource-group $RG --name $VM_TO_RESTORE
```

---

## Common Issues

| Symptom | Cause | Resolution |
|---|---|---|
| `az vm run-command` times out | VM Agent not ready or VM unresponsive | Check VM health in Portal; verify Agent status = Ready |
| SSM command fails: `InvalidInstanceId` | Instance not SSM-managed or not Online | Verify `aws ssm describe-instance-information` shows `PingStatus = Online` |
| `aws ssm start-session` fails | Session Manager plugin not installed | Install the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |
| `[FOUND  ]` items remain after Cutover cleanup | Artifact not covered by cleanup script | Remove manually, then update the specific checklist in both scripts |
| `[WARN ]` heuristic entries in readiness report | Unlisted AWS artifact detected | Review manually — see Heuristic Scans section below; add to checklist if confirmed AWS-specific |
| AWS services still running after TestMigration | MSI uninstall deferred to Cutover | Expected — MSI uninstalls run only at Cutover phase |
| `WindowsAzureGuestAgent` check fails | Azure VM Agent stopped or uninstalled | Reinstall from [Microsoft Download Center](https://go.microsoft.com/fwlink/p/?LinkID=394789) |
| Readiness shows `Errors: 0` but `Found: >0` | Artifacts survived cleanup | Re-run cleanup (non-dry-run) and investigate the specific items in the JSON report |
| Planned Failover job fails | Replication not healthy / RPO too stale | Wait for replication to return to Healthy; re-check RPO before retrying |

---

## Log File Reference

Every script run writes two files to **`C:\ProgramData\MigrationLogs\`** on the VM:

| File pattern | Contents |
|---|---|
| `cleanup-<Phase>-<timestamp>.log` | Full console transcript of the cleanup run |
| `cleanup-<Phase>-<timestamp>.json` | Structured JSON action report (one entry per action: Name, Status, Detail) |
| `readiness-<Phase>-<timestamp>.log` | Full console transcript of the readiness check |
| `readiness-<Phase>-<timestamp>.json` | Structured JSON findings report (one entry per check) |

Files are timestamped and never overwritten. A VM that has gone through TestMigration + Cutover will have at least four files.

---

## Readiness Script Reference

All checks performed by `validation/Invoke-MigrationReadiness.ps1`. The script is **read-only** — it never modifies the VM.

### Status codes

| Status | Meaning |
|---|---|
| `[CLEAN  ]` | Artifact not found — expected post-cleanup |
| `[FOUND  ]` | Artifact present — counted as a failure in Post assertions |
| `[PASS   ]` | Azure check passed |
| `[FAIL   ]` | Azure check failed (blocks migration readiness) |
| `[WARN   ]` | Heuristic scan found something not in the known list — needs manual review |
| `[INFO   ]` | Informational (e.g. agent version) |

### Specific checklist

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
| `AWSLiteAgent` | AWS Lite Guest Agent |

#### Installed Software

| Pattern | Description |
|---|---|
| `Amazon SSM Agent*` | SSM Agent MSI |
| `Amazon CloudWatch Agent*` | CloudWatch Agent MSI |
| `EC2ConfigService*` | EC2Config MSI |
| `EC2Launch*` | EC2Launch v1 MSI |
| `Amazon EC2Launch*` | EC2Launch v2 MSI |
| `Amazon Kinesis Agent*` | Kinesis Agent MSI |
| `AWS CodeDeploy Agent*` | CodeDeploy Agent MSI |
| `AWS Command Line Interface*` | AWS CLI |
| `Amazon Web Services*` | Generic AWS entry |
| `aws-cfn-bootstrap*` | CloudFormation Bootstrap |
| `AWS PV Drivers*` | **Intentionally retained** — ASR replaces PV drivers during replication |

#### Registry Keys

| Key Path | Description |
|---|---|
| `HKLM:\SOFTWARE\Amazon\EC2ConfigService` | EC2Config configuration |
| `HKLM:\SOFTWARE\Amazon\EC2Launch` | EC2Launch v1 configuration |
| `HKLM:\SOFTWARE\Amazon\EC2LaunchV2` | EC2Launch v2 configuration |
| `HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent` | CloudWatch Agent configuration |
| `HKLM:\SOFTWARE\Amazon\SSM` | SSM Agent configuration |
| `HKLM:\SOFTWARE\Amazon\MachineImage` | AMI metadata |
| `HKLM:\SOFTWARE\Amazon\WarmBoot` | EC2 warm boot marker |
| `HKLM:\SOFTWARE\Amazon\PVDriver` | **Intentionally retained** — PV driver; do not remove |

#### Filesystem Paths

| Path | Description |
|---|---|
| `C:\Program Files\Amazon\SSM` | SSM Agent binaries |
| `C:\Program Files\Amazon\AmazonCloudWatchAgent` | CloudWatch Agent binaries |
| `C:\Program Files\Amazon\EC2ConfigService` | EC2Config binaries |
| `C:\Program Files\Amazon\cfn-bootstrap` | CloudFormation Bootstrap files |
| `C:\Program Files\Amazon\XenTools` | Xen/legacy paravirtual driver files |
| `%SystemRoot%\System32\config\systemprofile\.aws` | SYSTEM-context AWS credentials |
| `%SystemRoot%\ServiceProfiles\NetworkService\.aws` | NetworkService-context AWS credentials |

#### Environment Variables

`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`, `AWS_DEFAULT_REGION`,
`AWS_REGION`, `AWS_PROFILE`, `AWS_CONFIG_FILE`, `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE`

#### Hosts File Entries

| Pattern | Description |
|---|---|
| `169\.254\.169\.254.*ec2\.internal` | EC2 metadata hostname alias |
| `instance-data\.ec2\.internal` | EC2 instance-data alias |

#### Scheduled Tasks

| Task | Path |
|---|---|
| `Amazon EC2Launch - Instance Initialization` | `\` |
| `AmazonCloudWatchAutoUpdate` | `\Amazon\AmazonCloudWatch\` |
| Any task under `\Amazon\*` | Dynamic scan |

#### Azure Readiness Checks

| Check | Pass condition |
|---|---|
| `WindowsAzureGuestAgent` service | Running, StartType = Automatic |
| Azure IMDS (`169.254.169.254`) | Responds with `provider = Microsoft.Compute` |

### Heuristic scans

These catch **unknown or unlisted** AWS artifacts. They appear as `[WARN ]` and do not fail the Post assertion, but every warning should be reviewed manually.

| Scan | What it looks for |
|---|---|
| **Services** | All services whose `DisplayName` or `Description` matches `amazon`, `aws`, `ec2`, or `ssm` — excluding the 8 in the specific list |
| **Registry** | All sub-keys directly under `HKLM:\SOFTWARE\Amazon\` not in the specific list (excluding `PVDriver`) |
| **Installed Software** | All programs in the uninstall registry whose `DisplayName` matches `\bAmazon\b`, `\bAWS\b`, or `\bEC2\b` — excluding the 8 in the specific list |
| **Filesystem** | All subdirectories under `C:\Program Files\Amazon\` not in the specific list; flags empty root at Cutover phase |
| **Scheduled Tasks** | Any task under `\Amazon\*` not in the specific list |

> **Workflow:** After any readiness check, search the JSON report for `"Status": "Warning"`. For each warning, determine whether the artifact is AWS-specific. If yes, remove manually and add to the specific checklist in both `Invoke-MigrationReadiness.ps1` and `Invoke-AWSCleanup.ps1`.

---

## Related Documents

| Document | Purpose |
|---|---|
| [README.md](README.md) | Technical reference — script internals, JSON schema, setup details |
| [tests/TESTING.md](tests/TESTING.md) | Test strategy, test log, known issues found during development |


