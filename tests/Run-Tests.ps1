<#
.SYNOPSIS
    Convenience runner for all Pester unit tests in this repository.

.DESCRIPTION
    Installs Pester 5 if not present, then runs all *.Tests.ps1 files under
    the tests/ directory. Exit code mirrors Pester's failed-test count so CI
    pipelines can use it as a gate.

    For the Layer 2 integration (DirtyBox) test, use -Integration. That test
    requires administrator rights and makes real changes to the machine.

.PARAMETER TestPath
    Specific test file or directory to run. Defaults to all unit tests.

.PARAMETER Tag
    Run only tests with these Pester tags.

.PARAMETER Output
    Pester output verbosity: None, Normal (default), Detailed, Diagnostic.

.PARAMETER CI
    Enable CI mode: writes NUnit XML results to tests/results/ and suppresses
    interactive prompts. Use in Azure Pipelines / GitHub Actions.

.PARAMETER Integration
    Run the Layer 2 DirtyBox integration test instead of unit tests.
    Requires -RunAsAdministrator. Accepts -Phase and -SkipTeardown.

.PARAMETER Phase
    Passed to the integration test: TestMigration (default) or Cutover.

.PARAMETER SkipTeardown
    Passed to the integration test: leave DirtyBox artifacts after the run.

.EXAMPLE
    # Run all unit tests
    .\tests\Run-Tests.ps1

.EXAMPLE
    # Run one file verbosely
    .\tests\Run-Tests.ps1 -TestPath .\tests\Unit\Invoke-AWSCleanup.Tests.ps1 -Output Detailed

.EXAMPLE
    # CI mode (produces NUnit XML for Azure Pipelines)
    .\tests\Run-Tests.ps1 -CI

.EXAMPLE
    # Layer 2 integration test (requires admin)
    .\tests\Run-Tests.ps1 -Integration

.EXAMPLE
    # Layer 2 integration, Cutover phase, leave artifacts for inspection
    .\tests\Run-Tests.ps1 -Integration -Phase Cutover -SkipTeardown
#>
[CmdletBinding()]
param(
    [string]$TestPath = (Join-Path $PSScriptRoot 'Unit'),

    [string[]]$Tag,

    [ValidateSet('None','Normal','Detailed','Diagnostic')]
    [string]$Output = 'Normal',

    [switch]$CI,

    [switch]$Integration,

    [ValidateSet('TestMigration','Cutover')]
    [string]$Phase = 'TestMigration',

    [switch]$SkipTeardown
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Integration test shortcut — bypass Pester entirely
# ─────────────────────────────────────────────────────────────────────────────
if ($Integration) {
    $integrationScript = Join-Path $PSScriptRoot 'Integration\Invoke-DirtyBoxIntegration.ps1'
    if (-not (Test-Path $integrationScript)) {
        Write-Host "[ERROR] Integration script not found: $integrationScript" -ForegroundColor Red
        exit 1
    }
    $integArgs = @{ Phase = $Phase }
    if ($SkipTeardown) { $integArgs['SkipTeardown'] = $true }
    & $integrationScript @integArgs
    exit $LASTEXITCODE
}

# ─────────────────────────────────────────────────────────────────────────────
# Ensure Pester 5 is available
# ─────────────────────────────────────────────────────────────────────────────
$pester = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester -or $pester.Version.Major -lt 5) {
    Write-Host "Pester 5 not found — installing from PSGallery..." -ForegroundColor Yellow
    Install-Module Pester -MinimumVersion 5.0.0 -Scope CurrentUser -Force -SkipPublisherCheck
}
Import-Module Pester -MinimumVersion 5.0.0

# ─────────────────────────────────────────────────────────────────────────────
# Build Pester configuration
# ─────────────────────────────────────────────────────────────────────────────
$config = New-PesterConfiguration

$config.Run.Path      = $TestPath
$config.Output.Verbosity = $Output
$config.Run.PassThru  = $true

if ($Tag) {
    $config.Filter.Tag = $Tag
}

if ($CI) {
    $resultsDir  = Join-Path $PSScriptRoot 'results'
    $resultsFile = Join-Path $resultsDir "TestResults-$(Get-Date -Format 'yyyyMMdd-HHmmss').xml"
    if (-not (Test-Path $resultsDir)) {
        New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
    }
    $config.TestResult.Enabled      = $true
    $config.TestResult.OutputPath   = $resultsFile
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.Output.Verbosity        = 'Normal'
    Write-Host "CI mode: results will be written to $resultsFile"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " AWS → Azure Migration Runbook — Test Suite  " -ForegroundColor Cyan
Write-Host " Path   : $TestPath"                            -ForegroundColor Cyan
Write-Host " Output : $Output"                             -ForegroundColor Cyan
Write-Host "══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$result = Invoke-Pester -Configuration $config

Write-Host ""
if ($result.FailedCount -gt 0) {
    Write-Host "FAILED: $($result.FailedCount) test(s) failed." -ForegroundColor Red
} else {
    Write-Host "PASSED: All $($result.PassedCount) test(s) passed." -ForegroundColor Green
}

# Return non-zero exit code for CI gates
exit $result.FailedCount
