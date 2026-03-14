# AWS → Azure Migration: In-Guest Cleanup Runbook

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![Bash](https://img.shields.io/badge/Bash-4.0+-green.svg)](https://www.gnu.org/software/bash/)
[![Azure Migrate](https://img.shields.io/badge/Azure_Migrate-Integrated-0078D4?logo=microsoft-azure)](https://learn.microsoft.com/en-us/azure/migrate/)
[![CI](https://github.com/DarylsCorner/aws-azure-migration-runbook/actions/workflows/ci.yml/badge.svg)](https://github.com/DarylsCorner/aws-azure-migration-runbook/actions/workflows/ci.yml)

Removes AWS-specific in-guest components from Windows and Linux VMs migrated to Azure via **Azure Migrate / ASR**. Every action is **idempotent** and **non-destructive to application binaries** — safe to run during Test Migration and again at final Cutover.

> **Ready to run a migration?** Go straight to [OPERATOR-GUIDE.md](OPERATOR-GUIDE.md) for the complete step-by-step runbook.

---

## What it does

When you migrate a VM from AWS to Azure, AWS agents, services, registry keys, scheduled tasks, and credential directories remain on disk. Left in place they cause noise, failed health checks, and potential credential exposure. This runbook removes them in two phases:

| Phase | When | What is removed |
|-------|------|-----------------|
| **TestMigration** | After Test Failover, before committing | AWS services stopped/disabled, environment variables and hosts entries cleaned, registry hives removed |
| **Cutover** | After Planned Failover, before commit | Everything in TestMigration **plus** MSI uninstalls and remaining filesystem artifacts |

Both phases verify that the Azure VM Agent is healthy before finishing. A structured JSON report is written inside the VM for audit purposes.

**A dry-run mode is always available.** Pass `-DryRun` (Windows) or `--dry-run` (Linux) to preview every action without making changes.

---

## Repository layout

```
.
├── OPERATOR-GUIDE.md                       # Step-by-step migration runbook (start here)
├── windows/
│   └── Invoke-AWSCleanup.ps1              # Windows in-guest cleanup
├── linux/
│   └── invoke-aws-cleanup.sh              # Linux in-guest cleanup
├── validation/
│   ├── Invoke-MigrationReadiness.ps1      # Windows readiness auditor (read-only)
│   └── invoke-migration-readiness.sh      # Linux readiness auditor (read-only)
├── runbook/
│   └── Start-MigrationCleanup.ps1        # Azure Automation Runbook orchestrator
├── reports/
│   └── examples/                          # Example JSON output from each phase
└── docs/
    └── script-reference.md               # Detailed script internals and JSON schema
```

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| Azure subscription | Contributor on the resource group; VM Contributor on migrated VMs |
| Azure CLI (`az`) | 2.50+ |
| PowerShell | 7.2+ on the operator machine |
| Target VMs — Windows | PowerShell 5.1+ on the VM (Windows Server 2016+ ships this by default) |
| Target VMs — Linux | Bash 4+, systemd or SysV init |
| Azure VM Agent | Installed and Running (Azure Migrate installs this automatically) |

---

## How to use it

### Step 1 — Clone the repo

```powershell
git clone https://github.com/DarylsCorner/aws-azure-migration-runbook.git
Set-Location aws-azure-migration-runbook
```

### Step 2 — Follow the Operator Guide

[OPERATOR-GUIDE.md](OPERATOR-GUIDE.md) covers every step from pre-failover baseline through final commit:

- Phase 0 — Session bootstrap (set variables once)
- Phase 1 — Pre-failover baseline on source VM (AWS, via SSM)
- Phases 2–7 — Test Failover, in-guest cleanup, validation, teardown
- Phases 8–12 — Planned Failover, Cutover cleanup, commit

### Running scripts directly (without Azure Automation)

**Windows — in-guest:**
```powershell
# Dry-run to preview all actions
.\windows\Invoke-AWSCleanup.ps1 -Phase TestMigration -DryRun

# Live TestMigration cleanup
.\windows\Invoke-AWSCleanup.ps1 -Phase TestMigration

# Readiness check (read-only — never modifies the VM)
.\validation\Invoke-MigrationReadiness.ps1 -Phase Cutover
```

**Linux — in-guest:**
```bash
# Dry-run
sudo bash linux/invoke-aws-cleanup.sh --phase test-migration --dry-run

# Live Cutover cleanup
sudo bash linux/invoke-aws-cleanup.sh --phase cutover
```

---

## What is intentionally not removed

| Item | Reason |
|------|--------|
| AWS CLI binaries | Application code may invoke `aws` — must be reviewed by the app owner |
| `/home/*/.aws` credential directories | User credentials belong to app owners, not the migration team |
| ENA / NVMe / Xen kernel modules | Azure Migrate replaces these during replication; removing in-guest risks connectivity loss |
| `/etc/fstab` EBS entries | Mount points are application-specific |
| Application config files referencing AWS | Changing S3/SQS/SNS endpoints is in scope for the application migration, not this runbook |

---

## Example reports

The `reports/examples/` folder contains real JSON output from each phase of a completed migration:

| File | What it shows |
|------|---------------|
| [`readiness-Pre-…json`](reports/examples/readiness-Pre-20260313-140012.json) | Source VM baseline — 14 AWS components found before any cleanup |
| [`cleanup-Cutover-…json`](reports/examples/cleanup-Cutover-20260313-225302.json) | Cutover cleanup run — actions completed, errors: 0 |
| [`readiness-Cutover-…json`](reports/examples/readiness-Cutover-20260313-230544.json) | Post-Cutover validation — Found: 0, Clean: 46, Warnings: 0 |

---

## Reference

- [docs/script-reference.md](docs/script-reference.md) — detailed per-section action tables, JSON schema, Azure Automation setup, and extending the scripts
- [OPERATOR-GUIDE.md](OPERATOR-GUIDE.md) — the complete operator runbook
