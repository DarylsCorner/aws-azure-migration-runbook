<#
.SYNOPSIS
    Layer 3 × Dirty VM: plants DirtyBox artifacts on a test VM and runs the
    Start-MigrationCleanup Automation runbook against them.

.DESCRIPTION
    Orchestrates all four scenarios for a single VM:

        Phase             DryRun
        ────────────────  ──────
        TestMigration     true     plant → runbook DryRun  → re-plant
        TestMigration     false    plant → runbook Live    → teardown
        Cutover           true     plant → runbook DryRun  → re-plant
        Cutover           false    plant → runbook Live    → teardown

    Supports both Linux VMs (RunShellScript, base64 upload) and Windows VMs
    (RunPowerShellScript, base64 upload).

.PARAMETER ResourceGroup
    Resource group containing the Automation Account and the VM.

.PARAMETER VMName
    Name of the VM to test against.  Default: mig-lnx-vm (Linux).
    Use mig-test-vm for the Windows scenario.

.PARAMETER OsType
    Linux (default) or Windows.

.PARAMETER AutomationAccount
    Automation Account name (default: aa-migration-test).

.PARAMETER Phases
    Which phases to run.  Default: TestMigration,Cutover.

.PARAMETER DryRunOnly
    Run only the DryRun scenario for each phase (skip Live).

.PARAMETER SkipTeardown
    Do not run the teardown fixture after each live run.

.EXAMPLE
    # Full Linux dirty-box test (all 4 scenarios)
    .\tests\Invoke-DirtyBoxRunbookTest.ps1

.EXAMPLE
    # Windows dirty-box test
    .\tests\Invoke-DirtyBoxRunbookTest.ps1 -VMName mig-test-vm -OsType Windows

.EXAMPLE
    # DryRun only, Linux
    .\tests\Invoke-DirtyBoxRunbookTest.ps1 -DryRunOnly
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup    = 'rg-migration-test',
    [string]$VMName           = 'mig-lnx-vm',

    [ValidateSet('Linux', 'Windows')]
    [string]$OsType           = 'Linux',

    [string]$AutomationAccount = 'aa-migration-test',

    [ValidateSet('TestMigration', 'Cutover')]
    [string[]]$Phases          = @('TestMigration', 'Cutover'),

    [switch]$DryRunOnly,
    [switch]$SkipTeardown
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root    = Split-Path $PSScriptRoot -Parent
$results = [System.Collections.Generic.List[pscustomobject]]::new()

# ─────────────────────────────────────────────────────────────────────────────
# Helper: pretty step header
# ─────────────────────────────────────────────────────────────────────────────
function Write-Step {
    param([string]$Msg)
    Write-Host ""
    Write-Host "── $Msg" -ForegroundColor Cyan
}

function Write-Banner {
    param([string]$Msg, [string]$Color = 'Cyan')
    $sep = '═' * 60
    Write-Host ""
    Write-Host $sep -ForegroundColor $Color
    Write-Host "  $Msg" -ForegroundColor $Color
    Write-Host $sep -ForegroundColor $Color
}

# ─────────────────────────────────────────────────────────────────────────────
# Linux helpers — base64-upload + RunShellScript
# (same pattern used by Invoke-VMLinuxIntegrationTest.ps1)
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-RemoteShellWriteScript {
    param([string]$LocalPath, [string]$RemotePath)
    $content = Get-Content $LocalPath -Raw -Encoding UTF8
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($content)
    $b64     = [Convert]::ToBase64String($bytes)
    $remoteDir = $RemotePath.Substring(0, $RemotePath.LastIndexOf('/'))
    return @"
mkdir -p '$remoteDir'
printf '%s' '$b64' | base64 -d > '$RemotePath'
chmod +x '$RemotePath'
echo "Written: $RemotePath"
"@
}

function Invoke-ShellCommand {
    param([string]$StepName, [string]$Script)
    Write-Step $StepName
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.sh'
    [System.IO.File]::WriteAllText($tmpScript, $Script, [System.Text.Encoding]::UTF8)
    try {
        $resultJson = az vm run-command invoke `
            --resource-group $ResourceGroup `
            --name           $VMName `
            --command-id     RunShellScript `
            --scripts        "@$tmpScript" `
            --output         json
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ERROR] run-command failed (exit $LASTEXITCODE)" -ForegroundColor Red
            return $null
        }
        $result = $resultJson | ConvertFrom-Json
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }
    if (-not $result -or -not $result.value) { return $null }
    $entry   = $result.value[0]
    $message = $entry.message
    $stdout  = if ($message -match '(?s)\[stdout\]\r?\n(.*?)(?:\[stderr\]|$)') { $Matches[1].TrimEnd() } else { '' }
    $stderr  = if ($message -match '(?s)\[stderr\]\r?\n(.*)') { $Matches[1].TrimEnd() } else { '' }
    if ($stdout -and $stdout.Trim()) { Write-Host $stdout }
    if ($stderr -and $stderr.Trim()) { Write-Host $stderr -ForegroundColor Yellow }
    return $stdout
}

# ─────────────────────────────────────────────────────────────────────────────
# Windows helpers — base64-upload + RunPowerShellScript
# Uses the same proven template as Invoke-VMIntegrationTest.ps1.
# Fixtures require PS 7 (?.  null-conditional syntax) so we install pwsh first
# and invoke fixtures via pwsh -NonInteractive -File.
# ─────────────────────────────────────────────────────────────────────────────
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

function Invoke-RunCommandPS {
    param([string]$StepName, [string]$Script)
    Write-Step $StepName
    $tmpScript = [System.IO.Path]::GetTempFileName() + '.ps1'
    [System.IO.File]::WriteAllText($tmpScript, $Script, [System.Text.Encoding]::UTF8)
    try {
        $resultJson = az vm run-command invoke `
            --resource-group $ResourceGroup `
            --name           $VMName `
            --command-id     RunPowerShellScript `
            --scripts        "@$tmpScript" `
            --output         json
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [ERROR] run-command failed (exit $LASTEXITCODE)" -ForegroundColor Red
            return $null
        }
        $result = $resultJson | ConvertFrom-Json
    } finally {
        Remove-Item $tmpScript -Force -ErrorAction SilentlyContinue
    }
    if (-not $result -or -not $result.value) { return $null }
    # Windows returns separate Value entries for StdOut / StdErr
    $stdout = $result.value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message
    $stderr = $result.value | Where-Object { $_.Code -like '*StdErr*' } | Select-Object -ExpandProperty Message
    if ($stdout -and $stdout.Trim()) { Write-Host $stdout }
    if ($stderr -and $stderr.Trim()) { Write-Host $stderr -ForegroundColor Yellow }
    return ($stdout -join "`n")
}

# ─────────────────────────────────────────────────────────────────────────────
# Upload fixture scripts to the VM (once, reused for all scenarios)
# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "Layer 3 × Dirty VM  ─  $VMName  ($OsType)"

if ($OsType -eq 'Linux') {
    $REMOTE_BASE = '/migration-test'

    Write-Step "Uploading DirtyBox fixture scripts to $VMName"

    $fixtureScript = (
        (ConvertTo-RemoteShellWriteScript `
            -LocalPath  (Join-Path $root 'tests\Fixture\setup-dirty-box-linux.sh') `
            -RemotePath "$REMOTE_BASE/tests/Fixture/setup-dirty-box-linux.sh"),
        (ConvertTo-RemoteShellWriteScript `
            -LocalPath  (Join-Path $root 'tests\Fixture\teardown-dirty-box-linux.sh') `
            -RemotePath "$REMOTE_BASE/tests/Fixture/teardown-dirty-box-linux.sh")
    ) -join "`n"

    Invoke-ShellCommand "  Writing fixture scripts" $fixtureScript | Out-Null

} else {
    # Windows
    $REMOTE_BASE = 'C:\migration-test'

    # ── Install PowerShell 7 (fixtures use ?. null-conditional syntax) ───────
    Invoke-RunCommandPS "Step 0 — Install PowerShell 7 (if needed)" @'
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
'@ | Out-Null

    Write-Step "Uploading DirtyBox fixture scripts to $VMName"

    # Upload all fixture files in one run-command (same pattern as Invoke-VMIntegrationTest.ps1)
    $fixtureCopyScript = @(
        @{
            Local  = Join-Path $root 'tests\Fixture\Setup-DirtyBox.ps1'
            Remote = "$REMOTE_BASE\tests\Fixture\Setup-DirtyBox.ps1"
        }
        @{
            Local  = Join-Path $root 'tests\Fixture\Teardown-DirtyBox.ps1'
            Remote = "$REMOTE_BASE\tests\Fixture\Teardown-DirtyBox.ps1"
        }
    ) | ForEach-Object {
        ConvertTo-RemoteWriteScript -LocalPath $_.Local -RemotePath $_.Remote
    }

    Invoke-RunCommandPS "  Writing fixture scripts" ($fixtureCopyScript -join "`n") | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Main loop — iterate over requested phases and DryRun/Live
# ─────────────────────────────────────────────────────────────────────────────
$dryRunValues = if ($DryRunOnly) { @($true) } else { @($true, $false) }

foreach ($phase in $Phases) {

    # Linux phase flag: TestMigration→test-migration, Cutover→cutover
    $linuxPhaseFlag = if ($phase -eq 'TestMigration') { 'test-migration' } else { 'cutover' }

    foreach ($isDryRun in $dryRunValues) {

        $label = "$phase / $(if ($isDryRun) { 'DryRun' } else { 'Live' })"
        Write-Banner "Scenario: $label" "Yellow"

        # ── 1. Plant DirtyBox ────────────────────────────────────────────────
        if ($OsType -eq 'Linux') {
            Invoke-ShellCommand "Plant DirtyBox  ($linuxPhaseFlag)" `
                "bash '$REMOTE_BASE/tests/Fixture/setup-dirty-box-linux.sh' --phase $linuxPhaseFlag" | Out-Null
        } else {
            # Run via PS7 (pwsh) — fixture uses ?. null-conditional member access
            Invoke-RunCommandPS "Plant DirtyBox  ($phase)" `
                "& 'C:\Program Files\PowerShell\7\pwsh.exe' -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_BASE\tests\Fixture\Setup-DirtyBox.ps1'" | Out-Null
        }

        # ── 2. Run Automation runbook ────────────────────────────────────────
        Write-Step "Running runbook  [$label]"

        $runbookScript = Join-Path $PSScriptRoot 'Invoke-RunbookTest.ps1'
        $runbookArgs = @{
            VMName            = $VMName
            ResourceGroup     = $ResourceGroup
            AutomationAccount = $AutomationAccount
            Phase             = $phase
        }
        if ($isDryRun) { $runbookArgs['DryRun'] = $true }

        & $runbookScript @runbookArgs
        $jobOk = ($LASTEXITCODE -eq 0)

        $results.Add([pscustomobject]@{
            Scenario  = $label
            JobStatus = if ($jobOk) { 'Completed' } else { 'FAILED' }
            Pass      = $jobOk
        })

        # ── 3. Teardown (only after Live, unless SkipTeardown) ───────────────
        if (-not $isDryRun -and -not $SkipTeardown) {
            if ($OsType -eq 'Linux') {
                Invoke-ShellCommand "Teardown DirtyBox" `
                    "bash '$REMOTE_BASE/tests/Fixture/teardown-dirty-box-linux.sh' --force" | Out-Null
            } else {
                Invoke-RunCommandPS "Teardown DirtyBox" `
                    "& 'C:\Program Files\PowerShell\7\pwsh.exe' -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_BASE\tests\Fixture\Teardown-DirtyBox.ps1' -Force" | Out-Null
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
$failed       = @($results | Where-Object { -not $_.Pass })
$allPassed    = $failed.Count -eq 0
$summaryColor = if ($allPassed) { 'Green' } else { 'Red' }

Write-Banner "Layer 3 × Dirty VM  ─  Summary" $summaryColor

$results | ForEach-Object {
    $icon = if ($_.Pass) { '✓' } else { '✗' }
    $c    = if ($_.Pass) { 'Green' } else { 'Red' }
    Write-Host ("  $icon  {0,-42}  {1}" -f $_.Scenario, $_.JobStatus) -ForegroundColor $c
}
Write-Host ""

if (-not $allPassed) { exit 1 }
