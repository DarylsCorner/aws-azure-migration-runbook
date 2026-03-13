# AWS → Azure Migration: Operator Guide

Step-by-step instructions for running the in-guest cleanup runbook against a migrated VM.
This guide is written for the operator who will execute the migration, not the engineer who built the tooling.

---

## Before You Begin

### Prerequisites

| Requirement | How to verify |
|---|---|
| `az` CLI installed and logged in | `az account show` |
| Correct subscription active | `az account set --subscription "6f9c9b05-871f-4edd-8183-893998be6ec3"` |
| Test or production VM is running in Azure | Portal → Virtual Machines → VM shows **Running** |
| Azure VM Agent is installed on the VM | Portal → VM → Properties → Agent status: **Ready** |

```powershell
# Set the correct subscription before running any az commands
az account set --subscription "6f9c9b05-871f-4edd-8183-893998be6ec3"
az account show --query "{Sub:name, ID:id}" -o table
```

> **Automation Account path:** If your organisation uses Azure Automation, see `tests/Invoke-RunbookTest.ps1` and `tests/Setup-AutomationInfra.ps1`. That path adds a snapshot gate, centralized job history, and managed identity execution. The steps below use `az vm run-command` which is simpler and suitable for hands-on operator-led migrations.

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

Take a snapshot of the VM's OS disk before any changes are made. This is your rollback point.

### 1a. Find the OS disk ID

```powershell
$VM_NAME = "<vm-name>"          # e.g. EC2AMAZ-NJ9HDHK-test
$RG      = "rg-mig-landing"

$DISK_ID = az vm show `
  --resource-group $RG `
  --name $VM_NAME `
  --query "storageProfile.osDisk.managedDisk.id" `
  --output tsv

Write-Host $DISK_ID
```

### 1b. Create a snapshot

```powershell
az snapshot create `
  --resource-group $RG `
  --name "$VM_NAME-pre-cleanup-snapshot" `
  --source $DISK_ID
```

Typically completes in 1–3 minutes. Verify in Portal under **Snapshots** in the resource group.

> **Tip:** If Azure Migrate already created a restore point during replication, you may use that as your recovery point. Confirm with your Azure Migrate administrator.

### 1c. Tag the disk

This tag signals to the Automation Runbook path that a recovery point exists. Not enforced when running via `az vm run-command` directly, but apply it anyway as a record.

```powershell
az resource tag `
  --ids $DISK_ID `
  --tags MigrationSnapshot=true

# Verify
az resource show --ids $DISK_ID --query tags -o json
# Expected: { "MigrationSnapshot": "true" }
```

---

## Step 2 — Dry Run (Recommended)

Run in dry-run mode first. No changes are made to the VM — the script reports what **would** happen.

```powershell
$VM_NAME = "<vm-name>"          # e.g. EC2AMAZ-NJ9HDHK-test
$RG      = "rg-mig-landing"

az vm run-command invoke `
  -g $RG -n $VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=TestMigration" "DryRun=true" `
  --query "value[0].message" -o tsv
```

Review the output. Look for any lines with `[ERROR]` — investigate those before proceeding.

A clean dry-run on a freshly migrated VM typically shows **many Skipped** plus **DryRun** entries for each AWS component that would be removed. No `[ERROR]` lines means the script is safe to run live.

---

## Step 3 — TestMigration Phase (Live)

Once the dry-run looks correct, run live:

```powershell
az vm run-command invoke `
  -g $RG -n $VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=TestMigration" `
  --query "value[0].message" -o tsv
```

**Expected outcome:** All AWS services stopped and disabled, credentials and env vars removed. MSI/package uninstalls are deferred to the Cutover phase.

After the run, check the summary lines at the end of the output:

```
  Total   : <n>
  Done    : <n>    ← actions completed
  Skipped : <n>    ← components not present (fine)
  Errors  : 0      ← must be 0
```

Then confirm the VM is still healthy:
- RDP or Bastion in and confirm the application starts correctly
- No AWS services running: paste this into the VM or run via run-command:
  ```powershell
  Get-Service | Where-Object { $_.DisplayName -match 'amazon|aws|ec2' }
  ```

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

1. **Portal: Planned Failover** — ASR shuts down the source VM, replicates the final delta, and creates the production VM in Azure
2. Wait for the production VM to appear in `rg-mig-landing` and reach **Running** state
3. **Repeat Steps 1a–1c** on the production VM's OS disk (snapshot + tag)
4. Set `$VM_NAME` to the production VM name, then run the Cutover dry-run:

```powershell
$VM_NAME = "<production-vm-name>"   # the VM created by Planned Failover
$RG      = "rg-mig-landing"

# Dry-run first
az vm run-command invoke `
  -g $RG -n $VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=Cutover" "DryRun=true" `
  --query "value[0].message" -o tsv
```

Review the dry-run output — confirm the expected MSI uninstalls and service deletions appear. Then run live:

```powershell
az vm run-command invoke `
  -g $RG -n $VM_NAME `
  --command-id RunPowerShellScript `
  --scripts "@windows/Invoke-AWSCleanup.ps1" `
  --parameters "Phase=Cutover" `
  --query "value[0].message" -o tsv
```

Expected summary: `Errors: 0`. Proceed to Step 6.

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

Both the cleanup and readiness scripts print the paths of their output files at the end of every run:

```
Report     : C:\ProgramData\MigrationLogs\readiness-Cutover-20260313-021606.json
Transcript : C:\ProgramData\MigrationLogs\readiness-Cutover-20260313-021606.log
```

See the **Log Files** section below for how to list and retrieve these from the VM.

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
# 0. Set subscription and variables
az account set --subscription "6f9c9b05-871f-4edd-8183-893998be6ec3"
$RG      = "rg-mig-landing"
$VM_NAME = "<vm-name>"    # test VM: EC2AMAZ-NJ9HDHK-test  |  prod VM: EC2AMAZ-NJ9HDHK

# 1. Snapshot the OS disk
$DISK_ID = az vm show -g $RG -n $VM_NAME --query "storageProfile.osDisk.managedDisk.id" -o tsv
az snapshot create -g $RG --name "$VM_NAME-pre-cleanup-snapshot" --source $DISK_ID
az resource tag --ids $DISK_ID --tags MigrationSnapshot=true

# 2. Dry-run (TestMigration)
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "@windows/Invoke-AWSCleanup.ps1" --parameters "Phase=TestMigration" "DryRun=true" --query "value[0].message" -o tsv

# 3. Live TestMigration
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "@windows/Invoke-AWSCleanup.ps1" --parameters "Phase=TestMigration" --query "value[0].message" -o tsv

# 5a. Dry-run (Cutover)
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "@windows/Invoke-AWSCleanup.ps1" --parameters "Phase=Cutover" "DryRun=true" --query "value[0].message" -o tsv

# 5b. Live Cutover
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "@windows/Invoke-AWSCleanup.ps1" --parameters "Phase=Cutover" --query "value[0].message" -o tsv

# 6. Readiness check
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "@validation/Invoke-MigrationReadiness.ps1" --parameters "Phase=Cutover" --query "value[0].message" -o tsv

# List log files on the VM
az vm run-command invoke -g $RG -n $VM_NAME --command-id RunPowerShellScript --scripts "Get-ChildItem C:\ProgramData\MigrationLogs\ | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize" --query "value[0].message" -o tsv
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

## Log Files

Every script run writes two files to **`C:\ProgramData\MigrationLogs\`** on the VM:

| File | Contents |
|------|----------|
| `cleanup-<Phase>-<timestamp>.log` | Full console transcript — every log line printed during the cleanup run |
| `cleanup-<Phase>-<timestamp>.json` | Structured JSON action report (one entry per action with Name, Status, Detail) |
| `readiness-<Phase>-<timestamp>.log` | Full console transcript of the readiness check run |
| `readiness-<Phase>-<timestamp>.json` | Structured JSON findings report |

Files are timestamped and never overwritten — each run appends a new pair. For a VM that has gone through Test + Cutover, you will have four files minimum.

### Retrieving logs from the VM

**List all migration logs:**

```powershell
az vm run-command invoke `
  -g <resource-group> -n <vm-name> `
  --command-id RunPowerShellScript `
  --scripts "Get-ChildItem C:\ProgramData\MigrationLogs\ | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize" `
  --query "value[0].message" -o tsv
```

**Read a specific log file:**

```powershell
az vm run-command invoke `
  -g <resource-group> -n <vm-name> `
  --command-id RunPowerShellScript `
  --scripts "Get-Content 'C:\ProgramData\MigrationLogs\cleanup-Cutover-<timestamp>.log'" `
  --query "value[0].message" -o tsv
```

**Copy logs to local machine** (requires VM to be reachable via WinRM or Bastion file copy):

```powershell
# Via Invoke-Command (if WinRM is open)
$session = New-PSSession -ComputerName <vm-ip> -Credential (Get-Credential)
Copy-Item -FromSession $session `
  -Path 'C:\ProgramData\MigrationLogs\*' `
  -Destination '.\vm-logs\' -Recurse
Remove-PSSession $session
```

---

## Related Documents

| Document | Purpose |
|---|---|
| [README.md](README.md) | Technical reference — script internals, JSON schema, setup details |
| [tests/TESTING.md](tests/TESTING.md) | Test strategy, test log, known issues found during development |
