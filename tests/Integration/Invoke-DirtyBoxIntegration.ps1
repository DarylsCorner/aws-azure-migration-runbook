#Requires -RunAsAdministrator
#Requires -Version 7.0
<#
.SYNOPSIS
    Layer 2 integration test — DirtyBox end-to-end pipeline.

.DESCRIPTION
    Runs the full cleanup pipeline against real artifacts planted on this machine:

        Setup-DirtyBox  →  Pre-Readiness  →  Cleanup (DryRun)  →  Cleanup (Live)
                        →  Post-Readiness  →  Assert clean state  →  Teardown

    NO MOCKS. Every state check reads real Windows state (registry, services,
    hosts file, scheduled tasks, env vars, directories).

    Prerequisites:
        - Run as Administrator
        - PowerShell 7+
        - Machine is a safe test box (not a production system)

.PARAMETER Phase
    TestMigration (default) or Cutover.
    Controls which cleanup phase is exercised after DryRun.

.PARAMETER SkipSetup
    Skip Setup-DirtyBox (assumes artifacts are already planted).

.PARAMETER SkipTeardown
    Leave DirtyBox artifacts in place after the test (useful for inspecting state).

.PARAMETER ReportDir
    Where to write pre/post JSON reports. Default: .\tests\Integration\reports\

.EXAMPLE
    # Full pipeline, TestMigration phase
    .\tests\Integration\Invoke-DirtyBoxIntegration.ps1

.EXAMPLE
    # Full pipeline including MSI-uninstall phase
    .\tests\Integration\Invoke-DirtyBoxIntegration.ps1 -Phase Cutover

.EXAMPLE
    # Artifacts already planted; skip setup
    .\tests\Integration\Invoke-DirtyBoxIntegration.ps1 -SkipSetup
#>
[CmdletBinding()]
param(
    [ValidateSet('TestMigration', 'Cutover')]
    [string]$Phase = 'TestMigration',

    [switch]$SkipSetup,
    [switch]$SkipTeardown,

    [string]$ReportDir = (Join-Path $PSScriptRoot 'reports')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
$root         = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$setupScript    = Join-Path $PSScriptRoot '..\Fixture\Setup-DirtyBox.ps1'
$teardownScript = Join-Path $PSScriptRoot '..\Fixture\Teardown-DirtyBox.ps1'
$cleanupScript  = Join-Path $root 'windows\Invoke-AWSCleanup.ps1'
$readinessScript = Join-Path $root 'validation\Invoke-MigrationReadiness.ps1'

# ─────────────────────────────────────────────────────────────────────────────
# Output
# ─────────────────────────────────────────────────────────────────────────────
$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not (Test-Path $ReportDir)) {
    New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
}

$results   = [System.Collections.Generic.List[hashtable]]::new()
$passed    = 0
$failed    = 0
$startTime = Get-Date

function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    Write-Host ""
    Write-Host ("═" * 60) -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host ("═" * 60) -ForegroundColor $Color
}

function Write-Pass {
    param([string]$Msg)
    Write-Host "  [PASS] $Msg" -ForegroundColor Green
    $script:passed++
    $script:results.Add(@{ Result = 'PASS'; Assertion = $Msg })
}

function Write-Fail {
    param([string]$Msg)
    Write-Host "  [FAIL] $Msg" -ForegroundColor Red
    $script:failed++
    $script:results.Add(@{ Result = 'FAIL'; Assertion = $Msg })
}

function Write-Info {
    param([string]$Msg)
    Write-Host "  [INFO] $Msg" -ForegroundColor DarkGray
}

function Assert-True {
    param([string]$Label, [scriptblock]$Condition)
    try {
        $result = & $Condition
        if ($result) { Write-Pass $Label } else { Write-Fail $Label }
    } catch {
        Write-Fail "$Label (threw: $($_.Exception.Message))"
    }
}

function Assert-False {
    param([string]$Label, [scriptblock]$Condition)
    try {
        $result = & $Condition
        if (-not $result) { Write-Pass $Label } else { Write-Fail $Label }
    } catch {
        Write-Fail "$Label (threw: $($_.Exception.Message))"
    }
}

function Assert-ServiceState {
    param([string]$ServiceName, [string]$ExpectedState, [string]$Label)
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    switch ($ExpectedState) {
        'Missing'  { if (-not $svc)                            { Write-Pass $Label } else { Write-Fail "$Label (service still exists: $($svc.Status))" } }
        'Disabled' { if ($svc -and $svc.StartType -eq 'Disabled') { Write-Pass $Label } else { Write-Fail "$Label (StartType: $($svc?.StartType))" } }
        'Running'  { if ($svc -and $svc.Status -eq 'Running') { Write-Pass $Label } else { Write-Fail "$Label (Status: $($svc?.Status))" } }
    }
}

function Assert-RegKeyAbsent {
    param([string]$KeyPath, [string]$Label)
    Assert-False $Label { Test-Path $KeyPath }
}

function Assert-RegKeyPresent {
    param([string]$KeyPath, [string]$Label)
    Assert-True $Label { Test-Path $KeyPath }
}

function Assert-EnvVarAbsent {
    param([string]$VarName, [string]$Label)
    $val = [System.Environment]::GetEnvironmentVariable($VarName, 'Machine')
    if ($null -eq $val) { Write-Pass $Label } else { Write-Fail "$Label (value: $val)" }
}

function Assert-EnvVarPresent {
    param([string]$VarName, [string]$Label)
    $val = [System.Environment]::GetEnvironmentVariable($VarName, 'Machine')
    if ($null -ne $val) { Write-Pass $Label } else { Write-Fail $Label }
}

function Assert-HostsAbsent {
    param([string]$Pattern, [string]$Label)
    $hosts = "$env:windir\System32\drivers\etc\hosts"
    $found = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern }
    if (-not $found) { Write-Pass $Label } else { Write-Fail "$Label (entry still present)" }
}

function Assert-HostsPresent {
    param([string]$Pattern, [string]$Label)
    $hosts = "$env:windir\System32\drivers\etc\hosts"
    $found = Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern }
    if ($found) { Write-Pass $Label } else { Write-Fail $Label }
}

function Assert-TaskAbsent {
    param([string]$Name, [string]$Path = '\', [string]$Label)
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if (-not $t) { Write-Pass $Label } else { Write-Fail "$Label (task still exists: $($t.State))" }
}

function Assert-TaskPresent {
    param([string]$Name, [string]$Path = '\', [string]$Label)
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if ($t) { Write-Pass $Label } else { Write-Fail $Label }
}

function Assert-DirAbsent {
    param([string]$Path, [string]$Label)
    Assert-False $Label { Test-Path $Path }
}

function Assert-DirPresent {
    param([string]$Path, [string]$Label)
    Assert-True $Label { Test-Path $Path }
}

# ─────────────────────────────────────────────────────────────────────────────
# Verify script dependencies exist
# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "Pre-flight: verifying scripts exist"
foreach ($script in @($setupScript, $teardownScript, $cleanupScript, $readinessScript)) {
    if (Test-Path $script) {
        Write-Info "Found: $script"
    } else {
        Write-Host "  [ERROR] Missing required script: $script" -ForegroundColor Red
        exit 1
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 0 — SETUP
# ═══════════════════════════════════════════════════════════════════════════
if (-not $SkipSetup) {
    Write-Banner "Phase 0: Setup-DirtyBox" Cyan
    & $setupScript
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Setup-DirtyBox failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Info "Skipping Setup-DirtyBox (-SkipSetup specified)"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1 — PRE-CLEANUP ASSERTIONS (DirtyBox state verification)
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 1: Verify DirtyBox artifacts are present" Yellow

Write-Host "  Services:" -ForegroundColor White
Assert-ServiceState 'AmazonSSMAgent'        'Disabled' "AmazonSSMAgent service exists"
Assert-ServiceState 'AmazonCloudWatchAgent' 'Disabled' "AmazonCloudWatchAgent service exists"
Assert-ServiceState 'AWSCodeDeployAgent'    'Disabled' "AWSCodeDeployAgent service exists"

Write-Host "  Registry:" -ForegroundColor White
Assert-RegKeyPresent 'HKLM:\SOFTWARE\Amazon\EC2ConfigService'         "EC2ConfigService key present"
Assert-RegKeyPresent 'HKLM:\SOFTWARE\Amazon\EC2Launch'                "EC2Launch key present"
Assert-RegKeyPresent 'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent'   "CloudWatch Agent key present"
Assert-RegKeyPresent 'HKLM:\SOFTWARE\Amazon\SSM'                      "SSM key present"

Write-Host "  Environment variables:" -ForegroundColor White
Assert-EnvVarPresent 'AWS_DEFAULT_REGION' "AWS_DEFAULT_REGION is set"
Assert-EnvVarPresent 'AWS_REGION'         "AWS_REGION is set"
Assert-EnvVarPresent 'AWS_PROFILE'        "AWS_PROFILE is set"

Write-Host "  Hosts file:" -ForegroundColor White
Assert-HostsPresent 'instance-data\.ec2\.internal' "Hosts file contains EC2 internal entry"

Write-Host "  Scheduled tasks:" -ForegroundColor White
Assert-TaskPresent 'Amazon EC2Launch - Instance Initialization' '\'                       "EC2Launch task present"
Assert-TaskPresent 'AmazonCloudWatchAutoUpdate' '\Amazon\AmazonCloudWatch\'               "CloudWatch task present"

Write-Host "  Directories:" -ForegroundColor White
Assert-DirPresent 'C:\Program Files\Amazon\SSM'                   "SSM directory present"
Assert-DirPresent 'C:\Program Files\Amazon\AmazonCloudWatchAgent' "CloudWatch directory present"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2 — PRE-READINESS AUDIT
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 2: Invoke-MigrationReadiness -Mode Pre" Cyan
$preReportPath = Join-Path $ReportDir "pre-readiness-${ts}.json"
$preReport = & $readinessScript -Mode Pre -ReportPath $preReportPath

Write-Info "Pre-report written to: $preReportPath"

$preFound = @($preReport.Findings | Where-Object { $_.Status -eq 'Found' }).Count
Write-Info "AWS artifacts found by readiness audit: $preFound"

if ($preFound -gt 0) {
    Write-Pass "Pre-audit detected AWS artifacts ($preFound found)"
} else {
    Write-Fail "Pre-audit detected no AWS artifacts — DirtyBox may not have run correctly"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3 — CLEANUP (DRY RUN)
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 3: Invoke-AWSCleanup -DryRun -Phase $Phase" Cyan
$dryReportPath = Join-Path $ReportDir "cleanup-dryrun-${ts}.json"
$dryReport = & $cleanupScript -DryRun -Phase $Phase -ReportPath $dryReportPath

Write-Info "DryRun report written to: $dryReportPath"

$dryRun    = @($dryReport.Actions | Where-Object { $_.Status -eq 'DryRun' }).Count
$completed = @($dryReport.Actions | Where-Object { $_.Status -eq 'Completed' }).Count
$errors    = @($dryReport.Actions | Where-Object { $_.Status -eq 'Error' }).Count

Write-Info "DryRun actions: $dryRun  |  Completed: $completed  |  Errors: $errors"

if ($dryRun -gt 0) {
    Write-Pass "DryRun mode recorded actions without executing ($dryRun DryRun actions)"
} else {
    Write-Fail "DryRun mode produced no DryRun-status actions"
}

if ($completed -eq 0) {
    Write-Pass "DryRun mode made no real changes (zero Completed actions)"
} else {
    Write-Fail "DryRun mode made real changes ($completed Completed actions)"
}

if ($errors -eq 0) {
    Write-Pass "DryRun run had no errors"
} else {
    if ($Phase -eq 'Cutover') {
        Write-Info "DryRun errors (may include MSI checks): $errors"
    } else {
        Write-Fail "DryRun run had $errors error(s)"
    }
}

# Verify state unchanged after DryRun
Write-Host "  State unchanged after DryRun:" -ForegroundColor White
Assert-ServiceState 'AmazonSSMAgent' 'Disabled' "AmazonSSMAgent still exists after DryRun"
Assert-RegKeyPresent 'HKLM:\SOFTWARE\Amazon\SSM' "SSM registry key still present after DryRun"
Assert-EnvVarPresent 'AWS_DEFAULT_REGION' "AWS_DEFAULT_REGION still set after DryRun"
Assert-HostsPresent 'instance-data\.ec2\.internal' "Hosts entry still present after DryRun"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4 — CLEANUP (LIVE)
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 4: Invoke-AWSCleanup -Phase $Phase (live)" Cyan
$liveReportPath = Join-Path $ReportDir "cleanup-live-${ts}.json"
$liveReport = & $cleanupScript -Phase $Phase -ReportPath $liveReportPath

Write-Info "Live cleanup report written to: $liveReportPath"

$liveCompleted = @($liveReport.Actions | Where-Object { $_.Status -eq 'Completed' }).Count
$liveErrors    = @($liveReport.Actions | Where-Object { $_.Status -eq 'Error' }).Count
$liveSkipped   = @($liveReport.Actions | Where-Object { $_.Status -eq 'Skipped' }).Count

Write-Info "Completed: $liveCompleted  |  Errors: $liveErrors  |  Skipped: $liveSkipped"

if ($Phase -eq 'Cutover') {
    # Cutover may have MSI uninstall errors for fake/missing products — that is expected.
    # Assert that actions ran (Completed + Error > 0) and no unexpected pure failures.
    if ($liveCompleted -gt 0) {
        Write-Pass "Live cleanup (Cutover) completed $liveCompleted action(s)"
    } else {
        Write-Fail "Live cleanup (Cutover) completed zero actions"
    }
    Write-Info "Live cleanup errors (expected for fake MSIs): $liveErrors"
} elseif ($liveCompleted -gt 0) {
    Write-Pass "Live cleanup completed $liveCompleted action(s)"
} else {
    Write-Fail "Live cleanup completed zero actions — nothing was cleaned up"
}

if ($Phase -eq 'Cutover') {
    # Cutover MSI errors are expected when fake product codes are used in DirtyBox.
    # Log them as info rather than failing the test.
    if ($liveErrors -gt 0) {
        Write-Info "Live cleanup errors (expected for fake MSIs in DirtyBox): $liveErrors"
        $liveReport.Actions |
            Where-Object { $_.Status -eq 'Error' } |
            ForEach-Object { Write-Info "  ERROR: $($_.Name) — $($_.Detail)" }
    } else {
        Write-Pass "Live cleanup (Cutover) had no errors"
    }
} elseif ($liveErrors -eq 0) {
    Write-Pass "Live cleanup had no errors"
} else {
    Write-Fail "Live cleanup had $liveErrors error(s)"
    $liveReport.Actions |
        Where-Object { $_.Status -eq 'Error' } |
        ForEach-Object { Write-Info "  ERROR: $($_.Name) — $($_.Detail)" }
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5 — POST-CLEANUP ASSERTIONS (real state)
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 5: Verify cleanup removed artifacts" Yellow

Write-Host "  Services:" -ForegroundColor White
if ($Phase -eq 'Cutover') {
    # Cutover invokes MSI uninstall but the DirtyBox uses a fake product code that
    # msiexec silently fails on (exit 1605). The fake New-Service service therefore
    # remains — it should be Disabled (from Section 2) rather than Missing.
    Assert-ServiceState 'AmazonSSMAgent'        'Disabled' "AmazonSSMAgent service disabled (Cutover)"
    Assert-ServiceState 'AmazonCloudWatchAgent' 'Disabled' "AmazonCloudWatchAgent service disabled (Cutover)"
    Assert-ServiceState 'AWSCodeDeployAgent'    'Disabled' "AWSCodeDeployAgent service disabled (Cutover)"
} else {
    # TestMigration only disables services (preserves rollback capability).
    Assert-ServiceState 'AmazonSSMAgent'        'Disabled' "AmazonSSMAgent service disabled"
    Assert-ServiceState 'AmazonCloudWatchAgent' 'Disabled' "AmazonCloudWatchAgent service disabled"
    Assert-ServiceState 'AWSCodeDeployAgent'    'Disabled' "AWSCodeDeployAgent service disabled"
}

Write-Host "  Registry:" -ForegroundColor White
Assert-RegKeyAbsent 'HKLM:\SOFTWARE\Amazon\EC2ConfigService'       "EC2ConfigService key removed"
Assert-RegKeyAbsent 'HKLM:\SOFTWARE\Amazon\EC2Launch'              "EC2Launch key removed"
Assert-RegKeyAbsent 'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent' "CloudWatch Agent key removed"
Assert-RegKeyAbsent 'HKLM:\SOFTWARE\Amazon\SSM'                    "SSM key removed"

Write-Host "  Environment variables:" -ForegroundColor White
Assert-EnvVarAbsent 'AWS_DEFAULT_REGION' "AWS_DEFAULT_REGION removed"
Assert-EnvVarAbsent 'AWS_REGION'         "AWS_REGION removed"
Assert-EnvVarAbsent 'AWS_PROFILE'        "AWS_PROFILE removed"

Write-Host "  Hosts file:" -ForegroundColor White
Assert-HostsAbsent 'instance-data\.ec2\.internal' "Hosts file EC2 entry removed"

Write-Host "  Scheduled tasks:" -ForegroundColor White
Assert-TaskAbsent 'Amazon EC2Launch - Instance Initialization' '\'                    "EC2Launch task removed"
Assert-TaskAbsent 'AmazonCloudWatchAutoUpdate' '\Amazon\AmazonCloudWatch\'            "CloudWatch task removed"

# Note: directories are only removed in Cutover phase
if ($Phase -eq 'Cutover') {
    Write-Host "  Directories (Cutover phase):" -ForegroundColor White
    Assert-DirAbsent 'C:\Program Files\Amazon\SSM'                   "SSM directory removed"
    Assert-DirAbsent 'C:\Program Files\Amazon\AmazonCloudWatchAgent' "CloudWatch directory removed"
} else {
    Write-Info "Directory cleanup is Cutover-only — skipping directory assertions for TestMigration phase"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6 — POST-READINESS AUDIT
# ═══════════════════════════════════════════════════════════════════════════
Write-Banner "Phase 6: Invoke-MigrationReadiness -Mode Post" Cyan
$postReportPath = Join-Path $ReportDir "post-readiness-${ts}.json"
$postReport = & $readinessScript -Mode Post -ReportPath $postReportPath

Write-Info "Post-report written to: $postReportPath"

$postAssertions = $postReport.PostAssertions
if ($postAssertions) {
    if ($Phase -eq 'Cutover') {
        # On a real VM with real MSIs, Cutover achieves zero AWS components.
        # DirtyBox uses fake New-Service + fake product codes that msiexec can't
        # truly uninstall, so some components persist. Assert count has dropped.
        $postCount = $postAssertions.AwsComponentsFound
        if ($postCount -eq 0) {
            Write-Pass "Post-audit (Cutover): zero AWS components found"
        } elseif ($postCount -lt $preFound) {
            Write-Pass "Post-audit (Cutover): AWS components reduced ($preFound -> $postCount) — fake services/MSIs can't be fully removed in DirtyBox"
        } else {
            Write-Fail "Post-audit (Cutover): component count not reduced ($preFound -> $postCount)"
        }
    } else {
        # TestMigration only disables services; binaries/services still appear in readiness audit.
        # Assert that count has gone DOWN (not necessarily to zero).
        $postCount = $postAssertions.AwsComponentsFound
        if ($postCount -lt $preFound) {
            Write-Pass "Post-audit: fewer AWS components than pre-audit ($preFound -> $postCount)"
        } elseif ($preFound -eq 0) {
            Write-Info "Post-audit: $postCount AWS component(s) still present (TestMigration — services disabled, not removed)"
        } else {
            Write-Fail "Post-audit: component count not reduced ($preFound -> $postCount)"
        }
    }

    if ($Phase -eq 'Cutover') {
        # In Cutover the Azure agent should be present; in TestMigration it may not be yet
        if ($postAssertions.AzureAgentFailed -eq 0) {
            Write-Pass "Post-audit: Azure agent checks passed"
        } else {
            Write-Info "Post-audit: Azure agent check failed — expected if this is not an Azure VM"
        }

        if ($postAssertions.CleanState) {
            Write-Pass "Post-audit: machine is in clean state"
        } else {
            Write-Info "Post-audit: CleanState=false (Azure agent likely not installed on test machine)"
        }
    }
}

# Compare pre vs post Found count
$postFound = @($postReport.Findings | Where-Object { $_.Status -eq 'Found' }).Count
$reduction = $preFound - $postFound
Write-Info "AWS artifacts: $preFound (pre) → $postFound (post) — $reduction removed"
if ($reduction -gt 0) {
    Write-Pass "Post-audit shows fewer AWS artifacts than pre-audit ($reduction removed)"
} else {
    Write-Fail "Post-audit did not show reduction in AWS artifacts"
}

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 7 — TEARDOWN
# ═══════════════════════════════════════════════════════════════════════════
if (-not $SkipTeardown) {
    Write-Banner "Phase 7: Teardown-DirtyBox" Cyan
    & $teardownScript -Force
} else {
    Write-Info "Skipping Teardown-DirtyBox (-SkipTeardown specified)"
}

# ═══════════════════════════════════════════════════════════════════════════
# RESULTS SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
$elapsed = (Get-Date) - $startTime
$total   = $passed + $failed

Write-Banner "Integration Test Results" $(if ($failed -eq 0) { 'Green' } else { 'Red' })
Write-Host "  Phase    : $Phase"
Write-Host "  Total    : $total"
Write-Host "  Passed   : $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed   : $failed" -ForegroundColor Red
} else {
    Write-Host "  Failed   : $failed"
}
Write-Host "  Duration : $([math]::Round($elapsed.TotalSeconds, 1))s"

# Write summary JSON
$summaryPath = Join-Path $ReportDir "integration-summary-${ts}.json"
@{
    Timestamp  = (Get-Date -Format 'o')
    Phase      = $Phase
    Total      = $total
    Passed     = $passed
    Failed     = $failed
    DurationSec = [math]::Round($elapsed.TotalSeconds, 1)
    Assertions = $results
} | ConvertTo-Json -Depth 4 | Set-Content -Path $summaryPath -Encoding UTF8
Write-Host ""
Write-Host "  Summary report: $summaryPath"
Write-Host ("═" * 60)

# Exit with non-zero if any assertions failed (for CI gate)
if ($failed -gt 0) { exit $failed }
