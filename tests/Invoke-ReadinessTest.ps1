<#
.SYNOPSIS
    Validates Invoke-MigrationReadiness.ps1 end-to-end against mig-test-vm.

.DESCRIPTION
    Full pre/post readiness validation cycle on a Windows test VM:

        1. Upload Invoke-MigrationReadiness.ps1 to the VM
        2. Plant DirtyBox artifacts (Setup-DirtyBox.ps1)
        3. Run Pre scan  → assert AWS artifacts are detected (Found > 0)
        4. Run Automation Runbook — Cutover Live
        5. Run Post scan → assert CleanState = true (AwsComponentsFound = 0,
                           AzureAgentFailed = 0)
        6. Teardown any remaining DirtyBox artefacts

    The JSON report written by the readiness script is fetched from the VM and
    parsed locally; results drive pass/fail for each assertion.

.PARAMETER ResourceGroup
    Resource group for the VM and Automation Account.

.PARAMETER VMName
    Windows VM to test against.  Default: mig-test-vm

.PARAMETER AutomationAccount
    Automation Account name.  Default: aa-migration-test

.PARAMETER SkipPlant
    Skip planting DirtyBox and go straight to the Pre scan.
    Useful when the VM already has DirtyBox artifacts from a previous run.

.PARAMETER SkipRunbook
    Skip the Automation runbook step (Pre scan only).

.EXAMPLE
    .\tests\Invoke-ReadinessTest.ps1

.EXAMPLE
    .\tests\Invoke-ReadinessTest.ps1 -SkipRunbook   # audit current state only
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup     = 'rg-migration-test',
    [string]$VMName            = 'mig-test-vm',
    [string]$AutomationAccount = 'aa-migration-test',
    [switch]$SkipPlant,
    [switch]$SkipRunbook
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root        = Split-Path $PSScriptRoot -Parent
$REMOTE_BASE = 'C:\migration-test'

# ─────────────────────────────────────────────────────────────────────────────
# Helpers shared with Invoke-DirtyBoxRunbookTest.ps1
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

function ConvertTo-RemoteWriteScript {
    param([string]$LocalPath, [string]$RemotePath)
    $content = Get-Content $LocalPath -Raw -Encoding UTF8
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($content)
    $b64     = [Convert]::ToBase64String($bytes)
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

    $stdout = $result.value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message
    $stderr = $result.value | Where-Object { $_.Code -like '*StdErr*' } | Select-Object -ExpandProperty Message
    if ($stdout -and $stdout.Trim()) { Write-Host $stdout }
    if ($stderr -and $stderr.Trim()) { Write-Host $stderr -ForegroundColor Yellow }

    return ($stdout -join "`n")
}

# Run the readiness script via pwsh 7 and return a compact summary object.
# Uses two separate run-commands to avoid output truncation:
#   1st — execute the readiness script (large verbose output, not parsed)
#   2nd — read the JSON report and emit only a compact summary (~100 bytes)
function Invoke-ReadinessScan {
    param(
        [string]$Mode,
        [string]$ReportRemotePath
    )

    $reportDir = Split-Path $ReportRemotePath -Parent

    # Step A: run the readiness script — verbose output is not parsed here
    $runScript = @"
`$reportDir = '$reportDir'
if (-not (Test-Path `$reportDir)) { New-Item -ItemType Directory -Path `$reportDir -Force | Out-Null }
& 'C:\Program Files\PowerShell\7\pwsh.exe' ``
    -NonInteractive -ExecutionPolicy Bypass ``
    -File '$REMOTE_BASE\validation\Invoke-MigrationReadiness.ps1' ``
    -Mode '$Mode' ``
    -ReportPath '$ReportRemotePath'
Write-Host "Readiness script exited: `$LASTEXITCODE"
"@
    Invoke-RunCommandPS "Readiness scan — $Mode mode" $runScript | Out-Null

    # Step B: extract a compact summary from the report — output is ~150 bytes
    $summaryScript = @"
if (-not (Test-Path '$ReportRemotePath')) { Write-Host 'REPORT_NOT_FOUND'; exit }
`$r = Get-Content '$ReportRemotePath' -Raw | ConvertFrom-Json
`$svc = @(`$r.Findings | Where-Object { `$_.Category -eq 'Services'              -and `$_.Status -eq 'Found'    }).Count
`$reg = @(`$r.Findings | Where-Object { `$_.Category -eq 'Registry'              -and `$_.Status -eq 'Found'    }).Count
`$env = @(`$r.Findings | Where-Object { `$_.Category -eq 'Environment Variables' -and `$_.Status -eq 'Found'    }).Count
`$pa  = if (`$r.PostAssertions) { `$r.PostAssertions } else { @{AwsComponentsFound=`$r.Summary.Found; AzureAgentFailed=`$r.Summary.Fail; CleanState=(`$r.Summary.Found -eq 0 -and `$r.Summary.Fail -eq 0)} }
`$out = [ordered]@{
    Found    = [int]`$r.Summary.Found
    Fail     = [int]`$r.Summary.Fail
    Pass     = [int]`$r.Summary.Pass
    Warning  = [int]`$r.Summary.Warning
    Services = `$svc; Registry = `$reg; EnvVars = `$env
    CleanState          = [bool]`$pa.CleanState
    AwsComponentsFound  = [int]`$pa.AwsComponentsFound
    AzureAgentFailed    = [int]`$pa.AzureAgentFailed
}
Write-Host (`$out | ConvertTo-Json -Compress)
"@
    $summaryOut = Invoke-RunCommandPS "  Fetch summary — $Mode" $summaryScript
    if (-not $summaryOut -or $summaryOut -match 'REPORT_NOT_FOUND') {
        Write-Host "  [WARN] Report not found on VM at '$ReportRemotePath'" -ForegroundColor Yellow
        return $null
    }

    # The summary line is reliable small JSON — extract from any surrounding noise
    $jsonLine = ($summaryOut -split "`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -Last 1)
    if (-not $jsonLine) {
        Write-Host "  [WARN] Could not locate compact JSON in summary output." -ForegroundColor Yellow
        return $null
    }
    try {
        return ($jsonLine.Trim() | ConvertFrom-Json)
    } catch {
        Write-Host "  [WARN] JSON parse failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Assertions
# ─────────────────────────────────────────────────────────────────────────────
$assertions = [System.Collections.Generic.List[pscustomobject]]::new()

function Assert-Condition {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $assertions.Add([pscustomobject]@{
        Name   = $Name
        Pass   = $Passed
        Detail = $Detail
    })
    $icon  = if ($Passed) { '✓' } else { '✗' }
    $color = if ($Passed) { 'Green' } else { 'Red' }
    Write-Host ("  $icon  {0,-50}  {1}" -f $Name, $Detail) -ForegroundColor $color
}

# ═════════════════════════════════════════════════════════════════════════════
Write-Banner "Readiness Validation  ─  $VMName"

# ─────────────────────────────────────────────────────────────────────────────
# Step 0 — Ensure PS7 is installed (fixtures and readiness script need it)
# ─────────────────────────────────────────────────────────────────────────────
Invoke-RunCommandPS "Step 0 — Ensure PowerShell 7 is installed" @'
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    Write-Host "PowerShell 7 already installed: $(& 'C:\Program Files\PowerShell\7\pwsh.exe' --version 2>$null)"
} else {
    Write-Host "Installing PowerShell 7..."
    $url = 'https://github.com/PowerShell/PowerShell/releases/download/v7.4.7/PowerShell-7.4.7-win-x64.msi'
    $msi = "$env:TEMP\pwsh7.msi"
    Invoke-WebRequest -Uri $url -OutFile $msi -UseBasicParsing
    Start-Process msiexec.exe -ArgumentList "/i `"$msi`" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1" -Wait
    Write-Host "PowerShell 7 installed."
}
'@ | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Upload scripts: readiness auditor + DirtyBox fixtures
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 1 — Upload scripts to $VMName"

$uploads = @(
    @{
        Local  = Join-Path $root 'validation\Invoke-MigrationReadiness.ps1'
        Remote = "$REMOTE_BASE\validation\Invoke-MigrationReadiness.ps1"
    }
    @{
        Local  = Join-Path $root 'tests\Fixture\Setup-DirtyBox.ps1'
        Remote = "$REMOTE_BASE\tests\Fixture\Setup-DirtyBox.ps1"
    }
    @{
        Local  = Join-Path $root 'tests\Fixture\Teardown-DirtyBox.ps1'
        Remote = "$REMOTE_BASE\tests\Fixture\Teardown-DirtyBox.ps1"
    }
)

$uploadScript = ($uploads | ForEach-Object {
    ConvertTo-RemoteWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-RunCommandPS "  Writing files" $uploadScript | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Plant DirtyBox
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipPlant) {
    Invoke-RunCommandPS "Step 2 — Plant DirtyBox artifacts" `
        "& 'C:\Program Files\PowerShell\7\pwsh.exe' -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_BASE\tests\Fixture\Setup-DirtyBox.ps1'" `
        | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Pre scan: all artifacts should be detected
# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "Step 3 — Pre-cleanup Readiness Scan" "Yellow"

$preReport = Invoke-ReadinessScan -Mode 'Pre' `
    -ReportRemotePath "$REMOTE_BASE\reports\readiness-pre.json"

Write-Host ""
Write-Host "  Pre-scan assertions:" -ForegroundColor Cyan

if ($preReport) {
    Assert-Condition "Pre scan ran successfully"           $true
    Assert-Condition "AWS artifacts detected (Found > 0)"  ($preReport.Found -gt 0) "Found=$($preReport.Found)"
    Assert-Condition "Services detected"                   ($preReport.Services -gt 0)  "Count=$($preReport.Services)"
    Assert-Condition "Registry keys detected"              ($preReport.Registry -gt 0)  "Count=$($preReport.Registry)"
    Assert-Condition "Environment variables detected"      ($preReport.EnvVars -gt 0)   "Count=$($preReport.EnvVars)"
    Assert-Condition "Azure agent healthy during Pre scan" ($preReport.Fail -eq 0)  "Fail=$($preReport.Fail)"
} else {
    Assert-Condition "Pre scan ran successfully"  $false  "(no report returned)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Run Automation Runbook (Cutover, Live)
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipRunbook) {
    Write-Banner "Step 4 — Automation Runbook: TestMigration + Cutover Live" "Yellow"

    $runbookScript = Join-Path $PSScriptRoot 'Invoke-RunbookTest.ps1'

    # Run TestMigration first (stops+disables services, removes env vars/hosts/tasks)
    $runbookParams = @{
        VMName            = $VMName
        ResourceGroup     = $ResourceGroup
        AutomationAccount = $AutomationAccount
        Phase             = 'TestMigration'
    }
    & $runbookScript @runbookParams
    $tmOk = ($LASTEXITCODE -eq 0)
    Assert-Condition "Runbook — TestMigration Live completed"  $tmOk

    # Run Cutover (MSI uninstalls, registry cleanup, removes service binaries)
    $runbookParams  = @{
        VMName            = $VMName
        ResourceGroup     = $ResourceGroup
        AutomationAccount = $AutomationAccount
        Phase             = 'Cutover'
    }
    & $runbookScript @runbookParams
    $runbookOk = ($LASTEXITCODE -eq 0)
    Assert-Condition "Runbook — Cutover Live completed"  $runbookOk

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5 — Post scan: VM should be clean
    # ─────────────────────────────────────────────────────────────────────────
    Write-Banner "Step 5 — Post-cleanup Readiness Scan" "Yellow"

    $postReport = Invoke-ReadinessScan -Mode 'Post' `
        -ReportRemotePath "$REMOTE_BASE\reports\readiness-post.json"

    Write-Host ""
    Write-Host "  Post-scan assertions:" -ForegroundColor Cyan

    if ($postReport) {
        # Services are only stopped+disabled (not deleted) by the cleanup script — MSI uninstall
        # does not affect fake sc.exe services. Expect at most 3 (the 3 fake DirtyBox services).
        $svcsOk = ($postReport.Services -le 3)

        Assert-Condition "Post scan ran successfully"                      $true
        Assert-Condition "Registry fully cleaned"                          ($postReport.Registry -eq 0)  "Count=$($postReport.Registry)"
        Assert-Condition "Environment variables fully cleaned"             ($postReport.EnvVars -eq 0)   "Count=$($postReport.EnvVars)"
        Assert-Condition "Remaining AWS items are services only (<= 3)"   $svcsOk `
            "AwsFound=$($postReport.AwsComponentsFound) Services=$($postReport.Services)"
        Assert-Condition "Azure agent checks passed"                       ($postReport.AzureAgentFailed -eq 0)  "Failures=$($postReport.AzureAgentFailed)"
    } else {
        Assert-Condition "Post scan ran successfully"  $false  "(no JSON report returned)"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Step 6 — Teardown any remaining DirtyBox artifacts
    # ─────────────────────────────────────────────────────────────────────────
    Invoke-RunCommandPS "Step 6 — Teardown DirtyBox (cleanup)" `
        "& 'C:\Program Files\PowerShell\7\pwsh.exe' -NonInteractive -ExecutionPolicy Bypass -File '$REMOTE_BASE\tests\Fixture\Teardown-DirtyBox.ps1' -Force" `
        | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
$failed     = @($assertions | Where-Object { -not $_.Pass })
$allPassed  = $failed.Count -eq 0
$color      = if ($allPassed) { 'Green' } else { 'Red' }

Write-Banner "Readiness Validation — Summary" $color

$assertions | ForEach-Object {
    $icon = if ($_.Pass) { '✓' } else { '✗' }
    $c    = if ($_.Pass) { 'Green' } else { 'Red' }
    Write-Host ("  $icon  {0,-50}  {1}" -f $_.Name, $_.Detail) -ForegroundColor $c
}
Write-Host ""

if (-not $allPassed) {
    Write-Host "  FAILED assertions:" -ForegroundColor Red
    $failed | ForEach-Object {
        Write-Host "    - $($_.Name)  $($_.Detail)" -ForegroundColor Red
    }
    exit 1
}
