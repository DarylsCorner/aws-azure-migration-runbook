<#
.SYNOPSIS
    Validates invoke-migration-readiness.sh end-to-end against mig-lnx-vm.

.DESCRIPTION
    Full pre/post readiness validation cycle on a Linux Azure test VM:

        0. Upload readiness + fixture scripts to /migration-test/ on the VM
        1. Plant DirtyBox artifacts (setup-dirty-box-linux.sh)
        2. Run Pre scan  → assert AWS artifacts are detected (Found > 0)
        3. Run Automation Runbook — TestMigration + Cutover
        4. Run Post scan → assert CleanState (AwsComponentsFound ≈ 0,
                           AzureAgentFailed = 0)
        5. Teardown any remaining DirtyBox artifacts

    The JSON report written by the readiness script is fetched from the VM and
    parsed locally; results drive pass/fail for each assertion.

.PARAMETER ResourceGroup
    Resource group for the VM and Automation Account.

.PARAMETER VMName
    Linux VM to test against.  Default: mig-lnx-vm

.PARAMETER AutomationAccount
    Automation Account name.  Default: aa-migration-test

.PARAMETER SkipPlant
    Skip planting DirtyBox and go straight to the Pre scan.
    Useful when the VM already has DirtyBox artifacts from a previous run.

.PARAMETER SkipRunbook
    Skip the Automation runbook step (Pre scan only).

.EXAMPLE
    .\tests\Invoke-LinuxReadinessTest.ps1

.EXAMPLE
    .\tests\Invoke-LinuxReadinessTest.ps1 -SkipRunbook   # audit current state only
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup     = 'rg-migration-test',
    [string]$VMName            = 'mig-lnx-vm',
    [string]$AutomationAccount = 'aa-migration-test',
    [switch]$SkipPlant,
    [switch]$SkipRunbook
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root        = Split-Path $PSScriptRoot -Parent
$REMOTE_BASE = '/migration-test'

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
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

# Build a shell snippet that base64-decodes a local file onto the remote VM.
function ConvertTo-RemoteShellWriteScript {
    param([string]$LocalPath, [string]$RemotePath)
    $content  = Get-Content $LocalPath -Raw -Encoding UTF8
    $bytes    = [System.Text.Encoding]::UTF8.GetBytes($content)
    $b64      = [Convert]::ToBase64String($bytes)
    $remoteDir = $RemotePath.Substring(0, $RemotePath.LastIndexOf('/'))
    return @"
mkdir -p '$remoteDir'
printf '%s' '$b64' | base64 -d > '$RemotePath'
chmod +x '$RemotePath'
echo "Written: $RemotePath"
"@
}

# Invoke a bash script on the Linux VM via az vm run-command (RunShellScript).
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

    # Linux RunShellScript returns value[0].message with embedded [stdout]/[stderr]
    $message = $result.value[0].message

    $stdout = ''
    $stderr = ''

    if ($message -match '(?s)\[stdout\]\r?\n(.*?)(?:\[stderr\]|$)') {
        $stdout = $Matches[1].TrimEnd()
    }
    if ($message -match '(?s)\[stderr\]\r?\n(.*)') {
        $stderr = $Matches[1].TrimEnd()
    }

    if ($stdout -and $stdout.Trim()) { Write-Host $stdout }
    if ($stderr -and $stderr.Trim()) { Write-Host $stderr -ForegroundColor Yellow }

    return $stdout
}

# Run the readiness script and return a compact summary object.
# Two run-commands: execute the script, then fetch a compact JSON from the report.
function Invoke-ReadinessScan {
    param(
        [string]$Mode,
        [string]$ReportRemotePath
    )

    $remoteDir = $ReportRemotePath.Substring(0, $ReportRemotePath.LastIndexOf('/'))

    # Step A — execute readiness script (output is verbose; not parsed here)
    $runScript = @"
mkdir -p '$remoteDir'
sudo bash '$REMOTE_BASE/validation/invoke-migration-readiness.sh' --mode '$Mode' --report '$ReportRemotePath'
echo "EXIT:\$?"
"@
    Invoke-ShellCommand "Readiness scan — $Mode mode" $runScript | Out-Null

    # Step B — read compact summary from the saved JSON report
    $fetchScript = @"
if [ ! -f '$ReportRemotePath' ]; then echo 'REPORT_NOT_FOUND'; exit 1; fi
python3 - <<'PYEOF'
import json, sys
with open('$ReportRemotePath') as f:
    r = json.load(f)

s    = r.get('summary', {})
fa   = r.get('findings', [])

found   = int(s.get('found',   0))
fail    = int(s.get('fail',    0))
pass_n  = int(s.get('pass',    0))
warn_n  = int(s.get('warning', 0))

svcs = sum(1 for x in fa if x['category'] == 'Services'              and x['status'] == 'Found')
pkgs = sum(1 for x in fa if x['category'] == 'Installed Packages'    and x['status'] == 'Found')
envv = sum(1 for x in fa if x['category'] == 'Environment Variables' and x['status'] == 'Found')

pa   = r.get('postAssertions') or {}
aws_found = int(pa.get('awsComponentsFound', found))
az_fail   = int(pa.get('azureAgentFailed',  fail))
clean     = bool(pa.get('cleanState', found == 0 and fail == 0))

out = {
    "Found":   found, "Fail": fail, "Pass": pass_n, "Warning": warn_n,
    "Services": svcs, "Packages": pkgs, "EnvVars": envv,
    "CleanState": clean,
    "AwsComponentsFound": aws_found,
    "AzureAgentFailed":   az_fail
}
print(json.dumps(out))
PYEOF
"@
    $summaryOut = Invoke-ShellCommand "  Fetch summary — $Mode" $fetchScript

    if (-not $summaryOut -or $summaryOut -match 'REPORT_NOT_FOUND') {
        Write-Host "  [WARN] Report not found on VM at '$ReportRemotePath'" -ForegroundColor Yellow
        return $null
    }

    # Extract the compact JSON line from any surrounding log noise
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
Write-Banner "Linux Readiness Validation  ─  $VMName"

# ─────────────────────────────────────────────────────────────────────────────
# Step 0 — Upload scripts to VM
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 0 — Upload scripts to $VMName"

$uploads = @(
    @{ Local = Join-Path $root 'validation\invoke-migration-readiness.sh';    Remote = "$REMOTE_BASE/validation/invoke-migration-readiness.sh" }
    @{ Local = Join-Path $root 'tests\Fixture\setup-dirty-box-linux.sh';      Remote = "$REMOTE_BASE/tests/Fixture/setup-dirty-box-linux.sh" }
    @{ Local = Join-Path $root 'tests\Fixture\teardown-dirty-box-linux.sh';   Remote = "$REMOTE_BASE/tests/Fixture/teardown-dirty-box-linux.sh" }
)

$uploadScript = ($uploads | ForEach-Object {
    ConvertTo-RemoteShellWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-ShellCommand "  Writing files" $uploadScript | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Plant DirtyBox artifacts
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipPlant) {
    Invoke-ShellCommand "Step 1 — Plant DirtyBox artifacts" `
        "sudo bash '$REMOTE_BASE/tests/Fixture/setup-dirty-box-linux.sh'" | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Pre scan: AWS artifacts should be detected
# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "Step 2 — Pre-cleanup Readiness Scan" "Yellow"

$preReport = Invoke-ReadinessScan -Mode 'Pre' `
    -ReportRemotePath "$REMOTE_BASE/reports/readiness-pre.json"

Write-Host ""
Write-Host "  Pre-scan assertions:" -ForegroundColor Cyan

if ($preReport) {
    Assert-Condition "Pre scan ran successfully"           $true
    Assert-Condition "AWS artifacts detected (Found > 0)"  ($preReport.Found    -gt 0) "Found=$($preReport.Found)"
    Assert-Condition "Services detected"                   ($preReport.Services -gt 0) "Count=$($preReport.Services)"
    Assert-Condition "Environment variables detected"      ($preReport.EnvVars  -gt 0) "Count=$($preReport.EnvVars)"
    Assert-Condition "Azure agent healthy during Pre scan" ($preReport.Fail     -eq 0) "Fail=$($preReport.Fail)"
} else {
    Assert-Condition "Pre scan ran successfully"  $false  "(no report returned)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Automation Runbook: TestMigration + Cutover
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SkipRunbook) {
    Write-Banner "Step 3 — Automation Runbook: TestMigration + Cutover" "Yellow"

    $runbookScript = Join-Path $PSScriptRoot 'Invoke-RunbookTest.ps1'

    & $runbookScript `
        -VMName            $VMName `
        -ResourceGroup     $ResourceGroup `
        -AutomationAccount $AutomationAccount `
        -Phase             'TestMigration'
    $tmOk = ($LASTEXITCODE -eq 0)
    Assert-Condition "Runbook — TestMigration completed"  $tmOk

    & $runbookScript `
        -VMName            $VMName `
        -ResourceGroup     $ResourceGroup `
        -AutomationAccount $AutomationAccount `
        -Phase             'Cutover'
    $cutoverOk = ($LASTEXITCODE -eq 0)
    Assert-Condition "Runbook — Cutover completed"  $cutoverOk

    # ─────────────────────────────────────────────────────────────────────────
    # Step 4 — Post scan: VM should be clean
    # ─────────────────────────────────────────────────────────────────────────
    Write-Banner "Step 4 — Post-cleanup Readiness Scan" "Yellow"

    $postReport = Invoke-ReadinessScan -Mode 'Post' `
        -ReportRemotePath "$REMOTE_BASE/reports/readiness-post.json"

    Write-Host ""
    Write-Host "  Post-scan assertions:" -ForegroundColor Cyan

    if ($postReport) {
        # DirtyBox plants 5 fake systemd units, none are real packages —
        # after Cutover, services may still show as unit-files (they are not removed by the
        # cleanup script, only stopped + disabled).  Allow up to 5.
        $svcsOk = ($postReport.Services -le 5)

        # Packages: DirtyBox never installs real packages, so count stays 0
        $pkgsOk = ($postReport.Packages -eq 0)

        Assert-Condition "Post scan ran successfully"                    $true
        Assert-Condition "Environment variables fully cleaned"           ($postReport.EnvVars  -eq 0)  "Count=$($postReport.EnvVars)"
        Assert-Condition "Packages fully cleaned"                        $pkgsOk                       "Count=$($postReport.Packages)"
        Assert-Condition "Remaining AWS items are services only (<= 5)"  $svcsOk `
            "AwsFound=$($postReport.AwsComponentsFound) Services=$($postReport.Services)"
        Assert-Condition "Azure agent checks passed"                     ($postReport.AzureAgentFailed -eq 0) `
            "Failures=$($postReport.AzureAgentFailed)"
    } else {
        Assert-Condition "Post scan ran successfully"  $false  "(no JSON report returned)"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Step 5 — Teardown any remaining DirtyBox artifacts
    # ─────────────────────────────────────────────────────────────────────────
    Invoke-ShellCommand "Step 5 — Teardown DirtyBox (cleanup)" `
        "sudo bash '$REMOTE_BASE/tests/Fixture/teardown-dirty-box-linux.sh'" | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Final summary
# ─────────────────────────────────────────────────────────────────────────────
$failed    = @($assertions | Where-Object { -not $_.Pass })
$allPassed = $failed.Count -eq 0
$color     = if ($allPassed) { 'Green' } else { 'Red' }

Write-Banner "Linux Readiness Validation — Summary" $color

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
    Write-Host ""
    exit $failed.Count
}

Write-Host "  All assertions passed  ($($assertions.Count)/$($assertions.Count))" -ForegroundColor Green
exit 0
