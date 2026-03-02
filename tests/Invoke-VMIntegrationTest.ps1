<#
.SYNOPSIS
    Pushes the integration test suite to the Azure test VM and runs it remotely.

.DESCRIPTION
    Uses az vm run-command to:
      1. Install PowerShell 7 on the VM (if not present)
      2. Copy all required scripts to C:\migration-test\ on the VM
      3. Run the DirtyBox integration test as SYSTEM (admin-equivalent)
      4. Stream output back to this terminal

    No RDP required. The VM at $PublicIP is the only prerequisite.

.PARAMETER ResourceGroup
    Resource group containing the test VM.

.PARAMETER VMName
    Name of the test VM.

.PARAMETER Phase
    TestMigration (default) or Cutover.

.EXAMPLE
    .\tests\Invoke-VMIntegrationTest.ps1

.EXAMPLE
    .\tests\Invoke-VMIntegrationTest.ps1 -Phase Cutover
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-migration-test',
    [string]$VMName        = 'mig-test-vm',

    [ValidateSet('TestMigration','Cutover')]
    [string]$Phase = 'TestMigration'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

function Write-Step {
    param([string]$Msg)
    Write-Host ""
    Write-Host "── $Msg" -ForegroundColor Cyan
}

function Invoke-RunCommand {
    param([string]$StepName, [string]$Script)

    Write-Step $StepName

    # Write script to a temp file — avoids Windows 8191-char command-line limit
    # and prevents shell-escaping issues with special characters in the script body.
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
    [System.IO.File]::WriteAllText($tmpScript, $Script, [System.Text.Encoding]::UTF8)

    try {
        $result = az vm run-command invoke `
            --resource-group $ResourceGroup `
            --name           $VMName `
            --command-id     RunPowerShellScript `
            --scripts        "@$tmpScript" `
            --output         json | ConvertFrom-Json
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }

    $stdout = $result.value | Where-Object { $_.code -like '*StdOut*' } |
              Select-Object -ExpandProperty message
    $stderr = $result.value | Where-Object { $_.code -like '*StdErr*' } |
              Select-Object -ExpandProperty message

    if ($stdout -and $stdout.Trim()) {
        Write-Host $stdout
    }
    if ($stderr -and $stderr.Trim()) {
        Write-Host $stderr -ForegroundColor Yellow
    }

    return $stdout
}

function ConvertTo-RemoteWriteScript {
    param([string]$LocalPath, [string]$RemotePath)

    $content  = Get-Content $LocalPath -Raw -Encoding UTF8
    $bytes    = [System.Text.Encoding]::UTF8.GetBytes($content)
    $b64      = [Convert]::ToBase64String($bytes)

    return @"
`$dir = Split-Path '$RemotePath' -Parent
if (-not (Test-Path `$dir)) { New-Item -ItemType Directory -Path `$dir -Force | Out-Null }
[System.IO.File]::WriteAllBytes('$RemotePath', [Convert]::FromBase64String('$b64'))
Write-Host "Written: $RemotePath"
"@
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Install PowerShell 7
# ─────────────────────────────────────────────────────────────────────────────
Invoke-RunCommand "Step 1/5 — Install PowerShell 7 (if needed)" @'
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    Write-Host "PowerShell 7 already installed: $(pwsh --version)"
} else {
    Write-Host "Installing PowerShell 7..."
    $url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/PowerShell-7.4.7-win-x64.msi'
    $msi = "$env:TEMP\pwsh7.msi"
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1" -Wait
    Write-Host "PowerShell 7 installed."
}
'@

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Copy production scripts
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 2/5 — Copying production scripts to VM"

$filesToCopy = @(
    @{
        Local  = Join-Path $root 'windows\Invoke-AWSCleanup.ps1'
        Remote = 'C:\migration-test\windows\Invoke-AWSCleanup.ps1'
    }
    @{
        Local  = Join-Path $root 'validation\Invoke-MigrationReadiness.ps1'
        Remote = 'C:\migration-test\validation\Invoke-MigrationReadiness.ps1'
    }
)

# Send both in one run-command to minimise round trips
$copyScript = ($filesToCopy | ForEach-Object {
    ConvertTo-RemoteWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-RunCommand "  Writing production scripts" $copyScript

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Copy test fixtures and integration test
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 3/5 — Copying test fixtures and integration test to VM"

$testFiles = @(
    @{
        Local  = Join-Path $root 'tests\Fixture\Setup-DirtyBox.ps1'
        Remote = 'C:\migration-test\tests\Fixture\Setup-DirtyBox.ps1'
    }
    @{
        Local  = Join-Path $root 'tests\Fixture\Teardown-DirtyBox.ps1'
        Remote = 'C:\migration-test\tests\Fixture\Teardown-DirtyBox.ps1'
    }
    @{
        Local  = Join-Path $root 'tests\Integration\Invoke-DirtyBoxIntegration.ps1'
        Remote = 'C:\migration-test\tests\Integration\Invoke-DirtyBoxIntegration.ps1'
    }
)

$testCopyScript = ($testFiles | ForEach-Object {
    ConvertTo-RemoteWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-RunCommand "  Writing test files" $testCopyScript

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Run integration test via PowerShell 7
# ─────────────────────────────────────────────────────────────────────────────
# Build the run script as a single-line command (no line continuations) to
# avoid the remote shell interpreting -Phase/-ReportDir as separate statements.
$runScript = @"
`$out = & 'C:\Program Files\PowerShell\7\pwsh.exe' -NonInteractive -ExecutionPolicy Bypass -File 'C:\migration-test\tests\Integration\Invoke-DirtyBoxIntegration.ps1' -Phase $Phase -ReportDir 'C:\migration-test\reports' 2>&1; `$out | ForEach-Object { `$_.ToString() }; exit `$LASTEXITCODE
"@

$output = Invoke-RunCommand "Step 4/5 — Running integration test (Phase: $Phase)" $runScript

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Retrieve summary report
# ─────────────────────────────────────────────────────────────────────────────
$summaryOutput = Invoke-RunCommand "Step 5/5 — Retrieving summary report" @'
$report = Get-ChildItem 'C:\migration-test\reports\integration-summary-*.json' -ErrorAction SilentlyContinue |
          Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($report) {
    Get-Content $report.FullName -Raw
} else {
    Write-Host "No summary report found."
}
'@

if ($summaryOutput -and $summaryOutput.Trim()) {
    try {
        $summary = $summaryOutput | ConvertFrom-Json
        Write-Host ""
        Write-Host ("═" * 55) -ForegroundColor $(if ($summary.Failed -eq 0) { 'Green' } else { 'Red' })
        Write-Host "  Integration Test Results — $VMName ($Phase)" -ForegroundColor $(if ($summary.Failed -eq 0) { 'Green' } else { 'Red' })
        Write-Host "  Passed : $($summary.Passed)" -ForegroundColor Green
        if ($summary.Failed -gt 0) {
            Write-Host "  Failed : $($summary.Failed)" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Failing assertions:" -ForegroundColor Red
            $summary.Assertions |
                Where-Object { $_.Result -eq 'FAIL' } |
                ForEach-Object { Write-Host "    [FAIL] $($_.Assertion)" -ForegroundColor Red }
        } else {
            Write-Host "  Failed : 0"
        }
        Write-Host "  Duration: $($summary.DurationSec)s"
        Write-Host ("═" * 55) -ForegroundColor $(if ($summary.Failed -eq 0) { 'Green' } else { 'Red' })

        if ($summary.Failed -gt 0) { exit $summary.Failed }
    } catch {
        Write-Host "Could not parse summary JSON: $_" -ForegroundColor Yellow
    }
}
