<#
.SYNOPSIS
    Pushes the Linux integration test suite to an Azure Linux test VM and
    runs it remotely via az vm run-command.

.DESCRIPTION
    Uses az vm run-command invoke (RunShellScript) to:
      1. Provision the Linux test VM if it does not exist (Ubuntu 22.04)
      2. Copy all required scripts to /home/azureuser/migration-test/ on the VM
      3. Run the DirtyBox integration test as root
      4. Stream output back to this terminal and retrieve the JSON summary

    No SSH required.

.PARAMETER ResourceGroup
    Resource group containing (or to contain) the test VM.

.PARAMETER VMName
    Name of the Linux test VM.  Created if it does not already exist.

.PARAMETER Phase
    test-migration (default) or cutover.

.PARAMETER SkipProvision
    Skip VM creation even if the VM does not exist (fail instead).

.EXAMPLE
    # Full pipeline, test-migration phase
    .\tests\Invoke-VMLinuxIntegrationTest.ps1

.EXAMPLE
    # Cutover phase
    .\tests\Invoke-VMLinuxIntegrationTest.ps1 -Phase cutover

.EXAMPLE
    # VM already exists, skip provisioning check
    .\tests\Invoke-VMLinuxIntegrationTest.ps1 -SkipProvision
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-migration-test',
    [string]$VMName        = 'mig-lnx-vm',

    [ValidateSet('test-migration','cutover')]
    [string]$Phase = 'test-migration',

    [switch]$SkipProvision
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

function Write-Step {
    param([string]$Msg)
    Write-Host ""
    Write-Host "── $Msg" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke a shell script on the Linux VM via run-command.
# Writes the script to a temp file to avoid the 8191-char CLI limit and to
# prevent any special characters in the script body from causing escaping issues.
# ─────────────────────────────────────────────────────────────────────────────
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

    # Linux RunShellScript returns a single value[0] entry whose message embeds
    # both streams as:  "Enable succeeded: \n[stdout]\n...\n[stderr]\n..."
    # Windows RunPowerShellScript returns two entries with code *StdOut* / *StdErr*.
    $entry = $result.value[0]
    $message = $entry.message

    $stdout = ''
    $stderr = ''

    if ($message -match '(?s)\[stdout\]\r?\n(.*?)(?:\[stderr\]|$)') {
        $stdout = $Matches[1].TrimEnd()
    }
    if ($message -match '(?s)\[stderr\]\r?\n(.*)') {
        $stderr = $Matches[1].TrimEnd()
    }

    if ($stdout -and $stdout.Trim()) { Write-Host $stdout }
    if ($stderr -and $stderr.Trim())  { Write-Host $stderr -ForegroundColor Yellow }

    return $stdout
}

# ─────────────────────────────────────────────────────────────────────────────
# Build a shell command that base64-decodes a local file onto the remote VM.
# Uses /usr/bin/base64 (coreutils) which is always present on Ubuntu/RHEL.
# ─────────────────────────────────────────────────────────────────────────────
function ConvertTo-RemoteShellWriteScript {
    param([string]$LocalPath, [string]$RemotePath)

    $content = Get-Content $LocalPath -Raw -Encoding UTF8
    $bytes   = [System.Text.Encoding]::UTF8.GetBytes($content)
    $b64     = [Convert]::ToBase64String($bytes)

    # Use string manipulation (not Split-Path) to get the Linux parent dir.
    # Split-Path on Windows converts forward slashes to backslashes.
    $remoteDir = $RemotePath.Substring(0, $RemotePath.LastIndexOf('/'))

    return @"
mkdir -p '$remoteDir'
printf '%s' '$b64' | base64 -d > '$RemotePath'
chmod +x '$RemotePath'
echo "Written: $RemotePath"
"@
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 0 — Ensure the Linux VM exists (create if needed)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 0/5 — Checking / provisioning Linux test VM '$VMName'..."

$vmJson = az vm show --resource-group $ResourceGroup --name $VMName `
          --query 'provisioningState' -o tsv 2>$null

if ($LASTEXITCODE -eq 0 -and $vmJson -and $vmJson.Trim() -eq 'Succeeded') {
    Write-Host "  VM '$VMName' already exists and is in Succeeded state." -ForegroundColor Green
} elseif ($SkipProvision) {
    Write-Host "  [ERROR] VM '$VMName' not found and -SkipProvision is set." -ForegroundColor Red
    exit 1
} else {
    Write-Host "  VM '$VMName' not found — creating Ubuntu 22.04 VM..." -ForegroundColor Yellow
    Write-Host "  (This takes ~2-3 minutes)" -ForegroundColor DarkGray

    az vm create `
        --resource-group    $ResourceGroup `
        --name              $VMName `
        --image             Ubuntu2204 `
        --size              Standard_B2s `
        --admin-username    azureuser `
        --generate-ssh-keys `
        --output            none

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] az vm create failed (exit $LASTEXITCODE)" -ForegroundColor Red
        exit 1
    }

    Write-Host "  VM '$VMName' created." -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Verify environment on the VM
# ─────────────────────────────────────────────────────────────────────────────
Invoke-ShellCommand "Step 1/5 — Verify VM environment" @'
echo "=== VM environment ==="
uname -a
. /etc/os-release && echo "OS: $PRETTY_NAME"
python3 --version
bash --version | head -1
systemctl --version | head -1
echo "=== Ready ==="
'@

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Copy production scripts
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 2/5 — Copying production scripts to VM"

$REMOTE_BASE = '/migration-test'

$prodFiles = @(
    @{
        Local  = Join-Path $root 'linux\invoke-aws-cleanup.sh'
        Remote = "$REMOTE_BASE/linux/invoke-aws-cleanup.sh"
    }
)

$prodCopyScript = ($prodFiles | ForEach-Object {
    ConvertTo-RemoteShellWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-ShellCommand "  Writing production scripts" $prodCopyScript

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3 — Copy test fixtures and integration test
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 3/5 — Copying test fixtures and integration test to VM"

$testFiles = @(
    @{
        Local  = Join-Path $root 'tests\Fixture\setup-dirty-box-linux.sh'
        Remote = "$REMOTE_BASE/tests/Fixture/setup-dirty-box-linux.sh"
    }
    @{
        Local  = Join-Path $root 'tests\Fixture\teardown-dirty-box-linux.sh'
        Remote = "$REMOTE_BASE/tests/Fixture/teardown-dirty-box-linux.sh"
    }
    @{
        Local  = Join-Path $root 'tests\Integration\invoke-dirty-box-integration-linux.sh'
        Remote = "$REMOTE_BASE/tests/Integration/invoke-dirty-box-integration-linux.sh"
    }
)

$testCopyScript = ($testFiles | ForEach-Object {
    ConvertTo-RemoteShellWriteScript -LocalPath $_.Local -RemotePath $_.Remote
}) -join "`n"

Invoke-ShellCommand "  Writing test files" $testCopyScript

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — Run integration test as root
# RunShellScript already executes as root on Azure VMs.
# ─────────────────────────────────────────────────────────────────────────────
# Build in two parts so that the literal bash $? is never inside a PS double-quoted string.
$exitCapture = 'echo "EXIT_CODE:$?"'   # single-quoted ⇒ $? is literal bash variable
$runScript = "bash '$REMOTE_BASE/tests/Integration/invoke-dirty-box-integration-linux.sh' --phase $Phase --report-dir '$REMOTE_BASE/reports'; " + $exitCapture

$output = Invoke-ShellCommand "Step 4/5 — Running integration test (Phase: $Phase)" $runScript

# Check if the script signalled failure via its exit code echo
if ($output -match 'EXIT_CODE:(\d+)') {
    $exitCode = [int]$Matches[1]
    if ($exitCode -ne 0) {
        Write-Host "  Integration test exited with code $exitCode" -ForegroundColor Red
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Retrieve and display JSON summary report
# ─────────────────────────────────────────────────────────────────────────────
$summaryOutput = Invoke-ShellCommand "Step 5/5 — Retrieving summary report" @'
REPORT=$(ls -t '/migration-test/reports/integration-summary-'*.json 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
    cat "$REPORT"
else
    echo '{"error":"No summary report found"}'
fi
'@

if ($summaryOutput -and $summaryOutput.Trim()) {
    # Extract the JSON block (strip any leading/trailing log lines)
    $jsonMatch = [regex]::Match($summaryOutput, '\{[\s\S]+\}')
    if ($jsonMatch.Success) {
        try {
            $summary = $jsonMatch.Value | ConvertFrom-Json

            $color = if ($summary.failed -eq 0) { 'Green' } else { 'Red' }
            Write-Host ""
            Write-Host ("═" * 58) -ForegroundColor $color
            Write-Host "  Linux Integration Test Results — $VMName ($Phase)" -ForegroundColor $color
            Write-Host "  Passed   : $($summary.passed)" -ForegroundColor Green
            if ($summary.failed -gt 0) {
                Write-Host "  Failed   : $($summary.failed)" -ForegroundColor Red
                Write-Host ""
                Write-Host "  Failing assertions:" -ForegroundColor Red
                $summary.assertions |
                    Where-Object { $_.result -eq 'FAIL' } |
                    ForEach-Object { Write-Host "    [FAIL] $($_.assertion)" -ForegroundColor Red }
            } else {
                Write-Host "  Failed   : 0"
            }
            Write-Host "  Duration : $($summary.durationSec)s"
            Write-Host ("═" * 58) -ForegroundColor $color

            if ($summary.failed -gt 0) { exit $summary.failed }
        } catch {
            Write-Host "Could not parse summary JSON: $_" -ForegroundColor Yellow
        }
    } else {
        Write-Host "No JSON found in step 5 output." -ForegroundColor Yellow
    }
}
