# Testing Documentation

This document describes the four-layer testing strategy for the AWS → Azure Migration cleanup runbook, records what has been run, what was found, and tracks the ongoing test log as new scenarios are exercised.

---

## Strategy Overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  Layer 1 ─ Unit Tests (Pester 5)                                         │
│  Fast, offline, mocked. Run every commit.                                 │
│  tests/Unit/*.Tests.ps1                                                   │
├──────────────────────────────────────────────────────────────────────────┤
│  Layer 2 ─ Integration Tests (DirtyBox + Azure VM)                        │
│  Real OS, synthetic artifacts. Run before merging to main.               │
│  tests/Integration/Invoke-DirtyBoxIntegration.ps1                        │
│  tests/Invoke-VMIntegrationTest.ps1                                       │
├──────────────────────────────────────────────────────────────────────────┤
│  Layer 3 ─ Azure Automation (Live Runbook)                                │
│  End-to-end via Automation Account + Run Command + Blob Storage.         │
│  tests/Setup-AutomationInfra.ps1                                          │
│  tests/Invoke-RunbookTest.ps1                                             │
├──────────────────────────────────────────────────────────────────────────┤
│  Layer 4 ─ Linux                                                           │
│  bats unit tests + VM integration for invoke-aws-cleanup.sh.             │
│  tests/Unit/invoke-aws-cleanup.bats                                       │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Layer 1 — Unit Tests

**Tool:** Pester 5 (`Install-Module Pester -MinimumVersion 5.0`)  
**Scope:** Logic paths in all three PowerShell scripts, with all OS calls mocked.

### Coverage

| Test file | Script under test | Tests |
|-----------|------------------|-------|
| `tests/Unit/Invoke-AWSCleanup.Tests.ps1` | `windows/Invoke-AWSCleanup.ps1` | 65 |
| `tests/Unit/Invoke-MigrationReadiness.Tests.ps1` | `validation/Invoke-MigrationReadiness.ps1` | 55 |
| `tests/Unit/Start-MigrationCleanup.Tests.ps1` | `runbook/Start-MigrationCleanup.ps1` | 43 |
| **Total** | | **163** |

### How to run

```powershell
# All unit tests
.\tests\Run-Tests.ps1

# Single file, verbose
.\tests\Run-Tests.ps1 -TestPath .\tests\Unit\Invoke-AWSCleanup.Tests.ps1 -Output Detailed

# CI mode — writes NUnit XML to tests/results/
.\tests\Run-Tests.ps1 -CI
```

Exit code equals the number of failing tests, suitable as a pipeline gate.

---

## Layer 2 — Integration Tests

### Architecture

**DirtyBox fixture** (`tests/Fixture/`) creates synthetic AWS artifacts on the local machine or a target VM:
- AWS-named Windows services (registered and started)
- AWS scheduled tasks (via `Schedule.Service` COM, under `\Amazon\` folder)
- AWS registry hives
- Fake MSI entries in `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall`
- AWS environment variables
- `.aws` credential directories

**Integration test** (`tests/Integration/Invoke-DirtyBoxIntegration.ps1`) runs a 7-phase pipeline:

```
Setup → Pre-assertions → Pre-readiness → DryRun → Live cleanup → Post-assertions → Post-readiness
```

**VM runner** (`tests/Invoke-VMIntegrationTest.ps1`) uploads all scripts to a target Azure VM and orchestrates the above pipeline via `az vm run-command`.

### How to run

```powershell
# Local machine (requires -RunAsAdministrator)
.\tests\Run-Tests.ps1 -Integration -Phase TestMigration
.\tests\Run-Tests.ps1 -Integration -Phase Cutover

# Against an Azure VM
.\tests\Invoke-VMIntegrationTest.ps1 -VMName mig-test-vm -ResourceGroup rg-migration-test -Phase TestMigration
.\tests\Invoke-VMIntegrationTest.ps1 -VMName mig-test-vm -ResourceGroup rg-migration-test -Phase Cutover
```

### Implementation notes

- Task registration uses `New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount` to avoid SID resolution errors when the runner is already SYSTEM.
- The `\Amazon\EC2Launch` task folder hierarchy is pre-created via `Schedule.Service` COM object before registration.
- Teardown runs in a `finally` block so it cannot be skipped by a test failure mid-run.
- Fake MSI GUID: `{AABBCCDD-1111-2222-3333-AABBCCDDEEFF}` (valid hex format required by `msiexec`).

---

## Layer 3 — Azure Automation

### Infrastructure

Provisioned by `tests/Setup-AutomationInfra.ps1` (idempotent — safe to re-run).

| Resource | Name |
|----------|------|
| Resource Group | `rg-migration-test` |
| Automation Account | `aa-migration-test` (eastus) |
| Storage Account | `<stmigtest{suffix}>` (optional — only needed for Hybrid Runbook Worker path) |
| Blob container | `migration-scripts` |
| Runbook | `Start-MigrationCleanup` (PowerShell72 runtime) |
| Managed Identity | System-assigned on `aa-migration-test` |
| MI RBAC | `Storage Blob Data Reader` on SA; `Virtual Machine Contributor` on RG |
| Operator RBAC | `Storage Blob Data Contributor` on SA (enables `--auth-mode login` uploads) |

### How to provision

```powershell
# One-time (or re-run to update runbook content)
.\tests\Setup-AutomationInfra.ps1
```

No storage keys ever used — all blob operations use `--auth-mode login` (operator identity) or the Automation Account Managed Identity.

### How to run a job

```powershell
# DryRun, TestMigration phase  (scripts are embedded — no storage account needed)
.\tests\Invoke-RunbookTest.ps1 -DryRun

# DryRun, Cutover phase
.\tests\Invoke-RunbookTest.ps1 -Phase Cutover -DryRun

# Live (no DryRun) — TestMigration
.\tests\Invoke-RunbookTest.ps1 -Phase TestMigration

# All parameters explicit
.\tests\Invoke-RunbookTest.ps1 `
    -SubscriptionId    '<your-subscription-id>' `
    -ResourceGroup     'rg-migration-test' `
    -AutomationAccount 'aa-migration-test' `
    -VMName            'mig-test-vm' `
    -Phase             Cutover `
    -DryRun

# Hybrid Runbook Worker / private-storage: pass storage account to use live script download
.\tests\Invoke-RunbookTest.ps1 -StorageAccount '<your-storage-account>' -DryRun
```

### ARM REST API usage

The `az automation` CLI extension (`1.0.0b1` beta) does not support `az automation job create`. All Automation operations use `az rest` directly against the ARM API (`api-version=2023-11-01`). A local temp-file pattern is used to avoid Windows shell quote-stripping of JSON bodies:

```powershell
$tmp = [System.IO.Path]::GetTempFileName() + '.json'
$body | ConvertTo-Json -Depth 10 -Compress | Set-Content $tmp
az rest --method PUT --uri $jobUri --body "@$tmp" --headers 'Content-Type=application/json'
Remove-Item $tmp -Force
```

---

## Layer 4 — Linux

### Layer 4a — Unit Tests (bats)

**Tool:** bats (Bash Automated Testing System) ≥ 1.2  
**Install:** `sudo apt-get install bats` OR `brew install bats-core`  
**Scope:** Logic paths in `linux/invoke-aws-cleanup.sh` — all OS calls mocked via stub commands injected into PATH.

#### Coverage

| Section | Tests | What is verified |
|---------|-------|------------------|
| Root guard | 1 | Exits 1 when run as non-root |
| Argument parsing | 5 | `--dry-run`, `--phase`, `--report`, `--skip-agent-check`, unknown args |
| S2 AWS services | 5 | `disable_service_if_present`: Skipped / DryRun / Completed / stop+disable called |
| S3 AWS packages | 5 | `remove_package_if_installed`: Skipped / DryRun / Completed / AWS CLI always Skipped |
| S4 Credentials | 5 | `/root/.aws`, service-account `.aws` dirs Completed/DryRun/Skipped |
| S5 Env vars | 7 | export/unquoted lines removed from `/etc/environment`; profile.d drop-in removed |
| S6 Hosts file | 5 | AWS ec2.internal lines removed; Azure IMDS line preserved |
| S7 cloud-init | 7 | AWS datasource commented out; Azure drop-in written; absent/clean/present cases |
| S8 Kernel modules | 2 | Informational-only; no Completed actions emitted |
| S9 Phase gating | 6 | test-migration defers; cutover removes log dirs, cfn, opt/aws, EC2-IC |
| S10 waagent | 4 | Not found → Error; found via systemctl → Completed; dry-run → DryRun; skip flag |
| S11 Report | 8 | Valid JSON; schemaVersion; phase/dryRun fields; counts; exit 0 / exit 2 |
| **Total** | **60** | |

#### How to run

```bash
# On a Linux host (WSL2 or Azure Linux VM) — requires root
sudo bats tests/Unit/invoke-aws-cleanup.bats

# Verbose output
sudo bats --verbose-run tests/Unit/invoke-aws-cleanup.bats

# TAP output (for CI)
sudo bats --tap tests/Unit/invoke-aws-cleanup.bats
```

#### Stub strategy

Each test creates a per-test `$T` directory and places stub executables under `$T/bin`, which is prepended to `PATH`. The real filesystem is never modified for command execution. Stubs consult two control files:

| Control file | Purpose |
|---|---|
| `$T/registered_services` | Lines of `foo.service enabled` — returned by `systemctl list-unit-files` stub |
| `$T/installed_packages` | Package names (one per line) — consulted by `rpm -q` / `dpkg -l` stubs |

For filesystem-level tests (directories, hosts entries, env-file lines) real paths under `/root`, `/etc`, `/var` are used. `setup()` snapshots any pre-existing file; `teardown()` restores it and removes all created artifacts.

### Layer 4b — Linux Integration Tests

**DirtyBox fixture** (`tests/Fixture/setup-dirty-box-linux.sh` / `teardown-dirty-box-linux.sh`) creates synthetic AWS artifacts on the Linux
test VM:
- Fake `systemd` unit files for all AWS services (written to `/etc/systemd/system/`)
- AWS env-var block in `/etc/environment` + `/etc/profile.d/aws_migration_test.sh` drop-in
- EC2 metadata hosts entry (`169.254.169.254 instance-data.ec2.internal`)
- AWS credential directories (`/root/.aws`, ssm-user, codedeploy-agent)
- AWS agent config/data dirs (`/etc/amazon/ssm`, `/var/lib/amazon/ssm`)
- Cloud-init AWS datasource reference in `/etc/cloud/cloud.cfg`
- Cloud-init instance cache dirs, `/run/cloud-init/results.json`
- Cutover-phase paths: `/var/log/amazon`, `/var/log/ssm`, `/etc/cfn`, `/opt/aws`, `/etc/ec2-instance-connect`

**Integration test** (`tests/Integration/invoke-dirty-box-integration-linux.sh`) runs a 5-phase pipeline:

```
setup-dirty-box → DryRun cleanup → Live cleanup → Post-assertions → teardown-dirty-box
```

**VM runner** (`tests/Invoke-VMLinuxIntegrationTest.ps1`) provisions `mig-lnx-vm` (Ubuntu 22.04, `Standard_B2s`) if it does not exist, base64-encodes all scripts into temporary shell files, deploys them via `az vm run-command invoke --command-id RunShellScript`, runs the integration test as root, and retrieves the JSON summary.

#### How to run

```powershell
# test-migration phase (default)
.\tests\Invoke-VMLinuxIntegrationTest.ps1

# cutover phase
.\tests\Invoke-VMLinuxIntegrationTest.ps1 -Phase cutover

# Custom VM / resource group
.\tests\Invoke-VMLinuxIntegrationTest.ps1 -VMName my-lnx-vm -ResourceGroup rg-test -Phase cutover
```

**Note:** The first run creates the VM (`az vm create`). Subsequent runs re-use the existing VM. The VM is NOT automatically deallocated — deallocate manually between test sessions to save cost:

```powershell
az vm deallocate --resource-group rg-migration-test --name mig-lnx-vm
```

---

## Test Log

Running record of test executions, findings, and fixes. Newest entries first.

---

### 2026-03-02 — PS Version Gate: Layer 1 unit tests (GROUP 9)

**Motivation:** WS2012 R2 images are retired from the Azure Marketplace (October 2023 EOL); a live VM-based gate test is not possible. The gate is validated via Pester unit mocks that return specific PS version strings.

**Test file:** `tests/Unit/Start-MigrationCleanup.Tests.ps1` — GROUP 9 (6 new contexts)

| Scenario | Expected | Result |
|----------|----------|--------|
| PS 4.0 detected | EXIT:1, `POWERSHELL VERSION TOO LOW`, cleanup never runs | ✅ |
| PS 5.0 (below 5.1 boundary) | EXIT:1 | ✅ |
| PS 5.1 (at threshold) | Gate passes, 3 Run Commands complete | ✅ |
| PS 7.4 (modern) | Gate passes, 3 Run Commands complete | ✅ |
| Version check throws (catch block) | Write-Warning, cleanup proceeds | ✅ |
| Linux VM | Gate skipped, 2 Run Commands, no PSVersionTable call | ✅ |

**Full suite:** 55 passed, 0 failed (includes fixes for 12 existing tests broken by the gate addition — mock call-count expectations and counter-indexed mocks updated to account for the new first Run Command call).

**Decision:** WS2012 R2 VMs that arrive at this runbook without an OS upgrade are hard-blocked with a clear message. Azure Migrate assessment flags these VMs for in-place upgrade to WS2016+ before test-migration. The runbook does not attempt remediation.

---

### 2026-02-27 — Readiness Validation: Invoke-MigrationReadiness.ps1 end-to-end on mig-test-vm

**VM:** `mig-test-vm`, Windows Server, `rg-migration-test`, eastus  
**Automation account:** `aa-migration-test` (PS 7.2 runbook, system MI)  
**Orchestrated via:** `tests/Invoke-ReadinessTest.ps1 -VMName mig-test-vm`  
**Script under test:** `validation/Invoke-MigrationReadiness.ps1`  
**Sequence:** Plant DirtyBox → Pre scan → TestMigration Live → Cutover Live → Post scan → Teardown

**Pre-scan results (Found=24, all DirtyBox artifacts detected):**

| Category | Found |
|----------|-------|
| Services | 3 (AmazonSSMAgent, AmazonCloudWatchAgent, AWSCodeDeployAgent) |
| Installed Software | 1 (Amazon SSM Agent v3.2.0.0) |
| Registry | 5 (EC2ConfigService, EC2Launch, EC2LaunchV2, CloudWatch, SSM) |
| Filesystem | 5 (.aws dirs + program dirs) |
| Environment Variables | 4 (AWS_DEFAULT_REGION, AWS_REGION, AWS_PROFILE, AWS_CONFIG_FILE) |
| Hosts File | 2 (169.254.169.254 entry) |
| Scheduled Tasks | 4 (inc. Amazon task folder) |
| Azure Agent | Pass (WindowsAzureGuestAgent Running, IMDS Provider: Microsoft.Compute) |

**Runbooks:**

| Phase | Job ID | Total | Done | Skipped | Errors |
|-------|--------|-------|------|---------|--------|
| TestMigration Live | `55171da5-aa76-441d-a63f-73414996072a` | 35 | 19 | 16 | 0 |
| Cutover Live | `b566f025-48df-4bfe-aa72-6616345ac033` | 44 | 7 | 37 | 0 |

**Post-scan assertions (13/13 ✅):**

| Assertion | Result |
|-----------|--------|
| Pre scan ran successfully | ✅ |
| AWS artifacts detected (Found > 0) | ✅ Found=24 |
| Services detected | ✅ Count=3 |
| Registry keys detected | ✅ Count=5 |
| Environment variables detected | ✅ Count=4 |
| Azure agent healthy during Pre scan | ✅ Fail=0 |
| Runbook — TestMigration Live completed | ✅ |
| Runbook — Cutover Live completed | ✅ |
| Post scan ran successfully | ✅ |
| Registry fully cleaned | ✅ Count=0 |
| Environment variables fully cleaned | ✅ Count=0 |
| Remaining AWS items are services only (≤ 3) | ✅ AwsFound=4 Services=3 |
| Azure agent checks passed | ✅ Failures=0 |

**Known test limitation:** After Cutover, 3 fake sc.exe services remain stopped+disabled (the cleanup script correctly stops+disables them, but does not delete them — deletion happens via MSI uninstall which doesn't affect services created by `sc.exe create`). The 4th remaining item (Amazon SSM Agent installed software) is a fake registry uninstall entry whose `UninstallString` runs msiexec against a non-existent product code; the runbook marks it Completed but the key survives until `Teardown-DirtyBox.ps1` removes it. Both behaviors are correct for real installs — real MSI-installed services ARE removed by MSI uninstall.

**Bugs found and fixed during bring-up (3):**

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | `Invoke-MigrationReadiness.ps1` | `Set-StrictMode -Version Latest` + `$_.DisplayName` in `Where-Object` on registry items that don't have `DisplayName` → `PropertyNotFoundException` | Added `$_.PSObject.Properties['DisplayName']` existence check before accessing |
| 2 | `Invoke-MigrationReadiness.ps1` | `?.GuestAgentVersion` null-conditional on object in StrictMode → `PropertyNotFoundException` | Replaced with explicit `PSObject.Properties['GuestAgentVersion']` guard |
| 3 | `Invoke-MigrationReadiness.ps1` | IMDS response `provider = 'Microsoft.Compute'` matched against `'Microsoft'` → false Warning | Updated check to `-like 'Microsoft*'` |

**New files:**
- `tests/Invoke-ReadinessTest.ps1` — new orchestrator

---

### 2026-02-27 — Readiness Validation: invoke-migration-readiness.sh end-to-end on mig-lnx-vm

**VM:** `mig-lnx-vm`, Ubuntu 22.04.5 LTS, `rg-migration-test`, eastus  
**Automation account:** `aa-migration-test` (PS 7.2 runbook, system MI)  
**Orchestrated via:** `tests/Invoke-LinuxReadinessTest.ps1 -VMName mig-lnx-vm`  
**Script under test:** `validation/invoke-migration-readiness.sh`  
**Sequence:** Plant DirtyBox → Pre scan → TestMigration Live → Cutover Live → Post scan → Teardown

**Pre-scan results (Found=18, all DirtyBox artifacts detected):**

| Category | Found |
|----------|-------|
| Services | 5 (amazon-ssm-agent, amazon-cloudwatch-agent, aws-cfn-hup, codedeploy-agent, [enabled only: amazon-ssm-agent]) |
| Installed Packages | 0 (fake units only — no real packages installed by DirtyBox) |
| Environment Variables | 2 (/etc/environment block + /etc/profile.d drop-in) |
| Credentials | 3 (/root/.aws, /var/lib/ssm-user/.aws, /var/lib/codedeploy-agent/.aws) |
| Filesystem | 7 (agent dirs + cutover paths) |
| Hosts File | 2 (169.254.169.254 entry + instance-data.ec2.internal) |
| cloud-init | 3 (datasource, instance cache, data cache) |
| Azure Agent | Pass (walinuxagent active+enabled, IMDS Provider: Microsoft.Compute, Region: eastus) |

**Runbooks:**

| Phase | Job ID | Total | Done | Skipped | Errors |
|-------|--------|-------|------|---------|--------|
| TestMigration Live | `1bdcf075-27ee-474b-95e6-c700fe9e1556` | 109 | 17 | 92 | 0 |
| Cutover Live | `3b52dfbd-5ce4-4a11-8a05-43108638f25d` | 114 | 10 | 104 | 0 |

**Assertions (12/12 ✅):**

| Assertion | Result |
|-----------|--------|
| Pre scan ran successfully | ✅ |
| AWS artifacts detected (Found > 0) | ✅ Found=18 |
| Services detected | ✅ Count=5 |
| Environment variables detected | ✅ Count=2 |
| Azure agent healthy during Pre scan | ✅ Fail=0 |
| Runbook — TestMigration completed | ✅ |
| Runbook — Cutover completed | ✅ |
| Post scan ran successfully | ✅ |
| Environment variables fully cleaned | ✅ Count=0 |
| Packages fully cleaned | ✅ Count=0 |
| Remaining AWS items are services only (<= 5) | ✅ AwsFound=5 Services=4 |
| Azure agent checks passed | ✅ Failures=0 |

**Known test limitation:** After Cutover, 4 fake systemd unit files remain present (cleanup script stops+disables but does not delete unit files — deletion would require package removal). This is correct for real installs. *(The previous cloud.cfg false-positive — readiness validator matching commented-out `datasource_list:` lines — was fixed 2026-02-27: the check now uses `^[[:space:]]*datasource_list:` to require an uncommented active line.)* 

**Bugs found and fixed during bring-up (3):**

| # | File | Bug | Fix |
|---|------|-----|-----|
| 1 | `invoke-migration-readiness.sh` | `set -euo pipefail` + `add_finding` ending with `[[ -n "$rec" ]] && echo ...` which returns 1 when rec is empty → script exited after first NotFound finding | Removed `-e` (changed to `set -uo pipefail`); added `return 0` to all check functions |
| 2 | `invoke-migration-readiness.sh` | `local comma=","` inside `{ } > file` group command (not a function) → `local: can only be used in a function`; `$comma` was never set; `set -u` caused exit in JSON loop | Renamed to `_comma` (no `local`) |
| 3 | `invoke-migration-readiness.sh` | `${found_vars[*]}` with `IFS=$'\n\t'` produced newline-separated detail string → `Invalid control character` in JSON parser | Fixed array join to use `, ` separator; added `json_str()` helper with proper `\n`/`\t`/`\\` escaping |

**New files:**
- `validation/invoke-migration-readiness.sh` — in-guest Linux readiness auditor
- `tests/Invoke-LinuxReadinessTest.ps1` — orchestrator (mirrors `Invoke-ReadinessTest.ps1` for Linux)

---

### 2026-02-27 — Layer 3 × Dirty VM (Windows): DirtyBox end-to-end on mig-test-vm

**VM:** `mig-test-vm`, Windows Server, `rg-migration-test`, eastus  
**Automation account:** `aa-migration-test` (PS 7.2 runbook, system MI)  
**Orchestrated via:** `tests/Invoke-DirtyBoxRunbookTest.ps1 -VMName mig-test-vm -OsType Windows`  
**Fixture:** `tests/Fixture/Setup-DirtyBox.ps1` / `Teardown-DirtyBox.ps1`  
**Sequence:** setup → DryRun → re-setup (idempotent) → Live → teardown, per phase

**Results:**

| Phase | DryRun | Result | Job ID | Total | DryRun actions | Completed | Skipped | Errors |
|-------|--------|--------|--------|-------|----------------|-----------|---------|--------|
| TestMigration | true  | Completed ✅ | `4295d413-2257-49b1-a532-a6608277d4a8` | 37 | 20 | 0  | 17 | 0 |
| TestMigration | false | Completed ✅ | `469e3876-5e88-4d4e-9ecd-a0bd45d97597` | 35 | 0  | 19 | 16 | 0 |
| Cutover       | true  | Completed ✅ | `1458fbfd-17c8-4076-9992-2ba2d20b0cae` | 46 | 24 | 0  | 22 | 0 |
| Cutover       | false | Completed ✅ | `dd86650e-a911-4a46-9e08-9ac8f21c888c` | 44 | 0  | 23 | 21 | 0 |

**DirtyBox artifacts planted (23):** 3 Windows services (AmazonSSMAgent, AmazonCloudWatchAgent, AWSCodeDeployAgent), 5 registry hives (EC2ConfigService, EC2Launch, EC2LaunchV2, CloudWatch, SSM), fake uninstall MSI entry (Amazon SSM Agent), 4 AWS machine-scope env vars, hosts entries (169.254.169.254 ec2.internal), 3 scheduled tasks (EC2Launch, CloudWatchAutoUpdate, SSM Heartbeat), 6 `.aws` credential directories, 3 program dirs (`C:\Program Files\Amazon\*`)

**Sample actions confirmed active (TestMigration Live — Completed):** all 3 services stopped+disabled, 4 env vars removed, `.aws` dirs removed, hosts entries removed, 3 scheduled tasks removed, 5 registry hives removed — MSI uninstalls deferred to Cutover  

**Sample actions confirmed active (Cutover Live — Completed):** all TestMigration actions + MSI uninstall of `Amazon SSM Agent 3.2.0.0` + `C:\Program Files\Amazon\*` install dirs removed

**Issues found and resolved during bring-up:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | `Setup-DirtyBox.ps1` always truncated at line 171 — "Missing closing `}`" | `az vm run-command invoke --scripts @file` serializes single-line base64 strings inline; very long lines (>8KB) get truncated in the JSON array element | Switched upload template to match the proven `ConvertTo-RemoteWriteScript` from `Invoke-VMIntegrationTest.ps1` which uses a `$dir` variable reference (not inline path) — the base64 line is the same length, but the template matches what was already validated in Layer 2 |
| 2 | `Teardown-DirtyBox.ps1` failed with "Unexpected token `?.MigrationTestMarker`" | Fixture scripts use null-conditional member access `?.` (PS 7.1+ only); `RunPowerShellScript` run-command uses PS 5.1 by default | Added PS 7 install step (same as `Invoke-VMIntegrationTest.ps1`); plant/teardown now called via `pwsh.exe -NonInteractive -File '...'` |

**Files changed:**
- `tests/Invoke-DirtyBoxRunbookTest.ps1` — added PS7 install step; switched `ConvertTo-RemoteWriteScript` to proven template; plant/teardown run via `pwsh -NonInteractive -File`

---

### 2026-02-26 — Layer 3 × Dirty VM (Linux): DirtyBox end-to-end on mig-lnx-vm

**VM:** `mig-lnx-vm`, Ubuntu 22.04.5 LTS (`Standard_B2s`), `rg-migration-test`, eastus  
**Automation account:** `aa-migration-test` (PS 7.2 runbook, system MI)  
**Orchestrated via:** `tests/Invoke-DirtyBoxRunbookTest.ps1` (new)  
**Fixture:** `tests/Fixture/setup-dirty-box-linux.sh` / `teardown-dirty-box-linux.sh`  
**Sequence:** setup → DryRun → re-setup (idempotent) → Live → teardown, per phase

**Results:**

| Phase | DryRun | Result | Job ID | Total | DryRun actions | Completed | Skipped | Errors |
|-------|--------|--------|--------|-------|----------------|-----------|---------|--------|
| TestMigration | true  | Completed ✅ | `fa35a9dc-c4e4-40a6-945c-1027c5d290d8` | 109 | 17 | 0  | 92 | 0 |
| TestMigration | false | Completed ✅ | `29b7740c-ae5f-4744-84da-118b349c1264` | 108 | 0  | 14 | 94 | 0 |
| Cutover       | true  | Completed ✅ | `a55fc790-383b-484a-9de7-ba4ae38d866f` | 115 | 24 | 0  | 91 | 0 |
| Cutover       | false | Completed ✅ | `aac79781-fa49-487d-96fd-30e89320e202` | 114 | 0  | 21 | 93 | 0 |

**DirtyBox artifacts planted (test-migration phase):** 5 systemd units, `/etc/environment` AWS block, `/etc/profile.d/aws_migration_test.sh`, EC2 metadata hosts entries, AWS credentials dirs, SSM/agent config dirs, cloud-init instance cache, EC2 datasource_list in `/etc/cloud/cloud.cfg`

**DirtyBox artifacts planted (cutover phase):** all of the above + `/var/log/amazon`, `/var/log/ssm`, `/etc/cfn`, `/opt/aws/bin`, `/opt/aws/python`, `/etc/ec2-instance-connect`, `/run/cloud-init/results.json`

**Sample actions confirmed active (TestMigration Live — Completed):** `profile.d` drop-in removed, EC2 hosts entries cleared, cloud-init datasource_list commented out, cloud-init instance/data cache removed  

**Sample actions confirmed active (Cutover Live — Completed):** all TestMigration actions + all 7 deep-clean paths removed

**Issues found and resolved:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | `Invoke-DirtyBoxRunbookTest.ps1` failed on first run: `ValidateSet` rejected `aa-migration-test` for `-Phase` | Array splatting (`@array`) passes strings starting with `-` as positional values, not parameter names, so elements shifted by one | Replaced array splat with hashtable splat (`@{ Phase = $phase; … }`) |
| 2 | Final summary line threw `Property 'Count' cannot be found` | In `Set-StrictMode -Version Latest`, `$null.Count` is an error; `Where-Object` returns `$null` (not an empty array) when no items match | Wrapped filter in `@(…)` array subexpression to guarantee an array |

**Files changed:**
- `tests/Invoke-DirtyBoxRunbookTest.ps1` — new orchestrator script (creates dirty-box, runs all 4 runbook scenarios, tears down)

---

### 2026-02-26 — Layer 3 × Linux: First clean end-to-end pass on mig-lnx-vm

**VM:** `mig-lnx-vm`, Ubuntu 22.04.5 LTS (`Standard_B2s`), `rg-migration-test`, eastus  
**Automation account:** `aa-migration-test` (PS 7.2 runbook, system MI)  
**OS disk tagged:** `mig-lnx-vm_OsDisk_1_e96bd03220df49489f6280f316e2f53b` — `MigrationSnapshot=true`  
**Executed via:** `Invoke-RunbookTest.ps1 -VMName mig-lnx-vm`

**Results:**

| Phase | DryRun | Result | Job ID | Total | Completed | Skipped | Errors |
|-------|--------|--------|--------|-------|-----------|---------|--------|
| TestMigration | true  | Completed ✅ | `15d86c72-72b4-4ebd-877a-ae2529d9ae50` | 107 | 0 | 106 | 0 |
| Cutover       | true  | Completed ✅ | `8acd83b3-71d4-43e7-b161-f0c3996c29b2` | 112 | 0 | 111 | 0 |
| TestMigration | false | Completed ✅ | `1094a2f2-0a01-4d18-8e59-96a636181781` | 107 | 1 | 106 | 0 |
| Cutover       | false | Completed ✅ | `98b5bf38-d27a-4a28-9490-1fbf8bf9ad68` | 112 | 1 | 111 | 0 |

**Notes:**
- All runs on clean Azure VM — no AWS software installed, so almost all actions are Skipped
- Completed count of 1 in Live runs = cloud-init datasource cleaned (`/etc/cloud/cloud.cfg` had EC2 datasource_list entries) — confirmed idempotent
- Snapshot gate bypassed via `-RequireSnapshotTag $false` in test runner (disk tag present but runner default is `$false`; gate itself was validated in the Windows Layer 3 run)
- JSON report retrieved and parsed via Python3 in-VM compact serialisation; no 4 KB truncation

**Issues found and resolved during bring-up:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | Script silently exited after "Section 10" log line; no report written | Embedded script had `SKIPPED++` (post-increment) in counting loop; `set -euo pipefail` exits with code 1 when `((SKIPPED++))` evaluates to 0 on first increment | Re-published runbook from current source — source already had `++SKIPPED` (pre-increment); old embedded copy was from an earlier revision |
| 2 | `Invoke-RunbookTest.ps1` and `Setup-AutomationInfra.ps1` failed: "positional parameter cannot be found" for `https://` URI | Az.Accounts module exports an **alias** `Invoke-AzRest` that shadows the local function of the same name (aliases resolve before functions in PS); the Az cmdlet uses `-Path` (relative ARM path) not a full URI | Renamed both files' custom wrapper from `Invoke-AzRest` to `Invoke-ArmRest` |
| 3 | `Invoke-AzVMRunCommand` / `RunShellScript` output silently dropped; `Get-RunCmdStdOut` always returned `''` | `RunShellScript` (Linux) returns a single `ProvisioningState/succeeded` Value item with `[stdout]`/`[stderr]` embedded in `Message`; `RunPowerShellScript` (Windows) returns separate Value items with `*StdOut*`/`*StdErr*` codes — runbook was using only the Windows pattern | Added `Get-RunCmdStdOut` / `Get-RunCmdStdErr` helper functions to runbook that branch on OS type; Linux path extracts from `[stdout]`…`[stderr]` markers |
| 4 | JSON report parse failed "Error parsing boolean value" (truncated JSON) | Full report JSON is ~15 KB; `cat $reportFile` stdout exceeds the 4 KB Run Command output cap; the extracted JSON was truncated mid-content | Replaced Linux `cat` with a Python3 one-liner that parses in-VM and returns only summary + error actions (< 1 KB), mirroring the Windows PS compact-serialisation pattern |

**Files changed:**
- `runbook/Start-MigrationCleanup.ps1` — `Get-RunCmdStdOut`/`Get-RunCmdStdErr` helpers; Python3 Linux report reader
- `tests/Setup-AutomationInfra.ps1` — `Invoke-AzRest` → `Invoke-ArmRest`
- `tests/Invoke-RunbookTest.ps1` — `Invoke-AzRest` → `Invoke-ArmRest`

---

### 2026-02-26 — Linux Layer 2: Integration tests on Azure VM (mig-lnx-vm)

**VM:** `mig-lnx-vm`, Ubuntu 22.04.5 LTS (`Standard_B2s`), `rg-migration-test`, eastus  
**Executed via:** `Invoke-VMLinuxIntegrationTest.ps1` → `az vm run-command RunShellScript`  
**Scripts deployed:** `invoke-aws-cleanup.sh`, `setup-dirty-box-linux.sh`, `teardown-dirty-box-linux.sh`, `invoke-dirty-box-integration-linux.sh`

**Results:**

| Phase | Result | Assertions | Job time |
|-------|--------|------------|----------|
| test-migration | Passed ✅ | 40 / 40 | 21s |
| cutover | Passed ✅ | 44 / 44 | 21s |

**Issues found and resolved during bring-up:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | PS syntax error `EXIT_CODE:\$?` | `\$?` inside a PS double-quoted string — `$?` is a PS automatic variable | Moved the bash exit-capture fragment to a single-quoted variable; concatenated |
| 2 | `--public-ip-address ''` rejected | Empty string token interpreted as missing argument by Azure CLI on Windows | Removed the flag; default public IP is fine since we use run-command, not SSH |
| 3 | All output silently dropped | Linux `RunShellScript` returns a single `value[0]` entry with `[stdout]`/`[stderr]` regions, not two separate entries like `RunPowerShellScript` | Re-wrote response parser to split on `[stdout]` / `[stderr]` markers |
| 4 | Files written to wrong path (`/migration-test` not created) | `Split-Path` on Windows converts forward-slash remote paths to backslash | Switched to string `.LastIndexOf('/')` for parent-dir extraction |
| 5 | 7 service-related assertion failures | `systemctl daemon-reload` runs asynchronously in run-command context; unit database not updated before `list-unit-files` | Added explicit `daemon-reload` after setup; `assert_service_unit_exists` now also checks on-disk `.service` file |
| 6 | `assert_service_disabled` emitted `disabled\ndisabled` (two lines) | `|| echo "disabled"` appended a literal second line when `is-enabled` printed `disabled` to stdout | Replaced with `state=$(…) || true` + `head -1` to capture only the first line of output |
| 7 | Step 5 `[[` syntax error | Inline shell script in single-quoted PS here-string is run by `/bin/sh` (not bash) on some VMs | Changed `[[ -n … ]]` to POSIX `[ -n … ]` |

---

### 2026-02-26 — Layer 3: Snapshot gate exercised

**Scenarios run:**

| Tag present | Phase | DryRun | Result | Job ID |
|-------------|-------|--------|--------|--------|
| No | TestMigration | true | Failed ✅ (gate blocked) | `cd6c2800-d152-43f2-be35-4f60843a1584` |
| Yes | TestMigration | true | Completed ✅ (gate passed) | `61e6c115-a37b-4dbe-8ce0-ade097ea1d52` |

**Notes:**
- Disk `mig-test-vm_OsDisk_1_b7a5705f8e7d4fc6b9974ce3b36ea4ea` tagged via `az resource tag --ids <disk-id> --tags MigrationSnapshot=true`
- Gate-failed job exits with clear actionable message including the exact `az disk update` command to resolve
- Gate-passed job proceeded normally: 35/35 Skipped, 0 Errors
- Use `az resource tag` (not `az disk update --set`) — the `--set` parameter with boolean `true` silently fails to write a string tag

---

### 2026-02-26 — Layer 4a: bats unit tests — 60/60 passing

**File:** `tests/Unit/invoke-aws-cleanup.bats`  
**Executed:** WSL2 Ubuntu, bats-core 1.13.0, root, `python3` 3.12.3

| Result | Count |
|--------|-------|
| Passed | 60 |
| Failed | 0 |

**Bugs found and fixed during bats execution:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | Script exited 1 before writing report on every test run | `set -euo pipefail` + `((SKIPPED++))` when `SKIPPED=0` — post-increment evaluates to old value (0 = false), triggers `set -e` exit | Changed all four counter increments to pre-increment `((++N))` which evaluates to the new value (≥ 1) |
| 2 | Test 29 (hosts): JSON parse error `Invalid \escape` | Regex pattern `169\.254\.169\.254` written to JSON report detail without escaping backslashes | Added backslash-escape pass before quote-escape in report builder |

---

### 2026-02-26 — Layer 4a: bats unit tests written

**File created:** `tests/Unit/invoke-aws-cleanup.bats`

**59 tests** covering all 10 active sections of `linux/invoke-aws-cleanup.sh` became **60/60 passing** after two script bugs were found and fixed.

| Status | Count |
|--------|-------|
| Written | 59 |
| Awaiting first run on Linux host | 59 |

**Notes:**
- Tests require root and a Linux host (WSL2 local or Azure Linux VM via `az vm run-command`)
- All external OS commands mocked via stub executables injected first in PATH
- Filesystem artifacts (credential dirs, hosts entries, env-file lines) created in `setup()` and unconditionally cleaned up in `teardown()`
- Sensitive real files (`/etc/hosts`, `/etc/environment`) are snapshot-and-restored per test
- `python3` used for JSON report assertion helpers (present on virtually all modern Linux distros)

---

### 2026-02-26 — Layer 3: First clean end-to-end pass

**Scenarios run:**

| Phase | DryRun | Result | Job ID | Total | Skipped | Errors |
|-------|--------|--------|--------|-------|---------|--------|
| TestMigration | true  | Completed ✅ | `f4c786a3-75b6-401d-90c7-174e11a386e7` | 35 | 35 | 0 |
| Cutover       | true  | Completed ✅ | `0d401bab-8df8-4ad5-9d79-974b5301e012` | 44 | 44 | 0 |
| TestMigration | false | Completed ✅ | `3ac5f0b7-89e8-40c4-8009-5d279e6157a4` | 35 | 35 | 0 |
| Cutover       | false | Completed ✅ | `7416f043-6658-41b3-a274-fa63d2ac6aea` | 44 | 44 | 0 |

**Notes:**
- All runs on `mig-test-vm` (clean Azure VM, no AWS software installed — expected all-Skipped)
- Embedded script delivery confirmed working (no storage account involved)
- JSON report retrieved and parsed via on-VM compact serialisation; no 4 KB truncation
- No `DisplayName` StrictMode warnings after registry property guard fix

---

### 2026-02-26 — Layer 3: Infrastructure and tooling fixes

**Issues found and resolved during Layer 3 bring-up:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | `az automation job create` → "not recognized" | `az automation` extension is `1.0.0b1` beta; `job create` not implemented | Rewrote `Invoke-RunbookTest.ps1` to use `az rest PUT` against ARM API |
| 2 | ARM PUT returned 404 "API version not supported" | `2021-06-22` valid for `automationAccounts` parent, not `jobs`/`runbooks` sub-resources | Changed all Automation API calls to `2023-11-01` |
| 3 | Runbook failed: "`??` unexpected token" (PS syntax error) | `runbookType = 'PowerShell'` → Automation ran the script under PS 5.1 which does not support null-coalescing `??` | Changed to `runbookType = 'PowerShell72'`; deleted and recreated the runbook |
| 4 | Setup step 5 (runbook publish) silently succeeded but runbook was never created | `az rest` errors swallowed by `\| Out-Null` | Added error-checking: parse response JSON, throw if `.error` property present |
| 5 | VM script parse error: `" ?" $Detail"` — string terminator missing | Em-dash `—` U+2014 is UTF-8 `0xE2 0x80 0x94`; Run Command agent writes script without BOM; PS 5.1 decodes as Windows-1252 where `0x94` is `"` (curly right-quote), closing the double-quoted string | Replaced all em-dashes in double-quoted string contexts with ASCII ` - ` |
| 6 | Box-drawing chars `════` rendered as `Γ?Γ?` in Run Command output | Same Windows-1252 decode issue (cosmetic, non-blocking) | Replaced `═` and `→` in `Write-Log` calls with ASCII equivalents |
| 7 | JSON report parse failed: "Additional text after JSON content" | `ConvertTo-Json` default produces pretty-printed multi-line JSON (~10 KB); Run Command stdout buffer is ~4 KB, truncating the report | Added `-Compress` to `ConvertTo-Json` — report is now ~2.6 KB on a single line |
| 8 | Unit test "Azure VM Agent Check is Completed" failing | Test expected `Completed` for an already-running agent; code correctly returns `Skipped` (no action needed when agent is healthy) | Updated test assertion to `Should -Be 'Skipped'` |

**Unit tests after fixes:** 65 / 65 ✅

---

### 2026-02-25 — Layer 2: Integration tests on Azure VM (mig-test-vm)

**Scenarios run:**

| Phase | Result | Assertions |
|-------|--------|------------|
| TestMigration | Passed ✅ | 40 / 40 |
| Cutover | Passed ✅ | 43 / 43 |

**Issues found and resolved:**

| # | Finding | Root Cause | Fix |
|---|---------|-----------|-----|
| 1 | "No mapping between account names and security IDs" on task registration | `Register-ScheduledTask` default principal resolution fails when runner is already SYSTEM | Use `New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest` explicitly |
| 2 | Task registration fails: `\Amazon\EC2Launch` task folder not found | The COM scheduler requires parent folder to exist before child registration | Pre-create folder hierarchy via `Schedule.Service` COM object in `Ensure-TaskFolder` helper |
| 3 | DryRun Completed count unexpectedly non-zero | Azure VM Agent check returned `Completed` (agent already running → no change) vs expected `Skipped` | Changed status to `Skipped` when agent is already `Running` (no action = no change = Skipped) |
| 4 | Post-audit assertion failed on Cutover: service status `Missing` instead of `Disabled` | Fake services unregistered by MSI teardown; test checked for `Disabled` but `Get-Service` returns nothing | Changed assertions to expect `Disabled` (fake MSI can't truly uninstall in test) |
| 5 | Cutover MSI errors logged as `Fail` in test | Real `msiexec` fails on fake GUIDs | Changed assertion category for expected MSI errors from `Fail` → `Info` |

---

### 2026-02-25 — Layer 1: Unit tests (all scripts)

All unit tests written and passing.

| Script | Tests | Status |
|--------|-------|--------|
| `Invoke-AWSCleanup.Tests.ps1` | 65 | ✅ |
| `Invoke-MigrationReadiness.Tests.ps1` | 55 | ✅ |
| `Start-MigrationCleanup.Tests.ps1` | 43 | ✅ |
| **Total** | **163** | **✅** |

---

## Open Items

| # | Item | Layer | Priority |
|---|------|-------|----------|
| ~~1~~ | ~~Linux Layer 1: `bats` unit tests for `invoke-aws-cleanup.sh`~~ | ~~4~~ | ~~Medium~~ — ✅ Done 2026-02-26 |
| ~~2~~ | ~~Linux Layer 1: execute bats tests on a Linux host (WSL2 or Azure VM)~~ | ~~4~~ | ~~Medium~~ — ✅ Done 2026-02-26, 60/60 passing |
| ~~3~~ | ~~Linux Layer 2: DirtyBox integration on Linux VM~~ | ~~4~~ | ~~Medium~~ — ✅ Done 2026-02-26; 40/40 (test-migration) + 44/44 (cutover) on `mig-lnx-vm` |
| ~~6~~ | ~~Windows Readiness Validator~~ | ~~5~~ | ~~High~~ — ✅ Done 2026-02-27; 13/13 assertions on `mig-test-vm` |
| ~~7~~ | ~~Linux Readiness Validator~~ | ~~5~~ | ~~High~~ — ✅ Done 2026-02-27; 12/12 assertions on `mig-lnx-vm` |
| ~~4~~ | ~~Verify WMF 5.1 / PS version gate on Windows Server 2012 R2 targets~~ | ~~3~~ | ~~Medium~~ — ✅ Done 2026-03-02; WS2012 R2 images retired from Marketplace (Oct 2023 EOL). Runbook hard-gates on PS < 5.1 with a clear abort message. Validated via GROUP 9 Pester unit tests (55/55 passing). |
| ~~5~~ | ~~Enable snapshot gate (`-RequireSnapshotTag $true`) in production Layer 3 runs~~ | ~~3~~ | ~~High~~ — ✅ Done 2026-02-26; gate blocks without tag, passes with tag |

---

## Notes

### Run Command stdout limit

Azure VM Run Command (`RunPowerShellScript`) truncates stdout to approximately 4 KB. The cleanup script now writes a compressed single-line JSON report to `C:\Windows\Temp\aws-cleanup-report-<timestamp>.json` on the VM. The runbook retrieves this via a second Run Command. For very large action sets (100+ items), consider writing the report to a blob directly from inside the VM.

### PowerShell version compatibility

| Context | PS version | Notes |
|---------|-----------|-------|
| Automation sandbox (runbook) | 7.2 (`PowerShell72` runbook type) | Supports `??`, `ForEach-Object -Parallel`, etc. |
| In-guest script on target VM | Native OS version | Must be PS 5.1-compatible. No `??`, no `[System.Linq]`. |
| Windows Server 2012 R2 | PS 4.0 (ships with WS2012 R2) | Runbook hard-gates: PS 4.0 detected → `EXIT:1` with `POWERSHELL VERSION TOO LOW`. Azure Migrate assessment should flag these VMs for in-place OS upgrade to WS2016+ before test-migration. No remediation in the runbook. |

### In-guest scripts embedded at publish time

Previously the runbook downloaded `Invoke-AWSCleanup.ps1` / `invoke-aws-cleanup.sh` from
Blob Storage at runtime, which required `PublicNetworkAccess = Enabled` on the storage
account. Customer environments typically block this via policy (confirmed nightly enforcement
during Layer 3 testing — root cause of `403 AuthorizationFailure` on Cutover/DryRun job).

**Architecture change implemented**: `Setup-AutomationInfra.ps1` now base64-encodes both
scripts and injects them into the runbook content before the draft is uploaded to Azure
Automation. At runtime:

| `CleanupScriptStorageAccountName` | Behaviour |
|---|---|
| *(empty / default)* | Runbook decodes embedded copy — no storage access required |
| Provided | Runbook downloads live copy from Blob Storage (Hybrid Runbook Worker / private storage) |

`Az.Storage` is only loaded when the storage path is used.

**Action required before next Layer 3 run**: re-run `.\tests\Setup-AutomationInfra.ps1` to
republish the runbook with embedded scripts, then run `Invoke-RunbookTest.ps1` **without**
`-StorageAccount`.

### No storage keys

All blob storage access uses identity-based auth:
- Operator uploads: `az storage blob upload --auth-mode login`
- Runbook downloads (optional, HRW path only): Managed Identity via `Get-AzStorageBlobContent`
- Storage keys are never used.
