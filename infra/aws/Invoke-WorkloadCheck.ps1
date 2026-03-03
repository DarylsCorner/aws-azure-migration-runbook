#Requires -Version 5.1
<#
.SYNOPSIS
    Snapshot the health of the test workload on both AWS VMs (IIS/nginx + app config).
    Run BEFORE cleanup to save a baseline, then AFTER cleanup to assert nothing broke.

.DESCRIPTION
    Sends SSM Run Commands to both VMs that check:
      Windows : IIS (W3SVC) running, HTTP 200 from /healthz/index.html,
                HKLM:\SOFTWARE\MyApp\Config registry key intact
      Linux   : nginx running, HTTP 200 from /healthz/index.html,
                /etc/myapp/config.env intact

    Results are saved to infra/aws/workload-reports/workload-check-<Phase>-<ts>.json.

    In -Phase After mode the script loads the most recent Before snapshot, diffs
    every non-AWS field, and exits 1 if any app-layer value changed.

.PARAMETER Phase
    'Before' -- save baseline (run before cleanup)
    'After'  -- compare against baseline (run after cleanup)

.PARAMETER Region
    AWS region.  Defaults to value in test-env.json.

.EXAMPLE
    # Before running the cleanup runbook:
    .\Invoke-WorkloadCheck.ps1 -Phase Before

    # After running the cleanup runbook:
    .\Invoke-WorkloadCheck.ps1 -Phase After
#>
[CmdletBinding()]
param(
    [ValidateSet('Before','After')]
    [string] $Phase  = 'Before',
    [string] $Region = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Load env -----------------------------------------------------------------

$EnvFile = Join-Path $PSScriptRoot 'test-env.json'
if (-not (Test-Path $EnvFile)) {
    Write-Error "test-env.json not found.  Run Deploy-TestEnv.ps1 first."
    exit 1
}
$envData = Get-Content $EnvFile | ConvertFrom-Json
if (-not $Region) { $Region = if ($envData.Region) { $envData.Region } else { 'us-east-1' } }

$winId = $envData.WindowsInstanceId
$lnxId = $envData.LinuxInstanceId

$reportDir = Join-Path $PSScriptRoot 'workload-reports'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null

# -- SSM helper ---------------------------------------------------------------

function Invoke-SsmCheck {
    param(
        [string] $InstanceId,
        [string] $DocumentName,
        [string] $Script,
        [string] $Label
    )
    Write-Host "  Checking $Label..." -ForegroundColor Gray -NoNewline
    $tmpFile = [System.IO.Path]::GetTempFileName() + '.json'
    $scriptLines = @($Script -split "`r?`n")
    $json = @{ commands = $scriptLines } | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.UTF8Encoding]::new($false))

    $cmd = aws ssm send-command `
               --instance-ids $InstanceId `
               --document-name $DocumentName `
               --parameters "file://$tmpFile" `
               --region $Region `
               --output json 2>&1 | ConvertFrom-Json
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) { Write-Warning "send-command failed for $Label"; return $null }

    $cmdId   = $cmd.Command.CommandId
    $deadline = (Get-Date).AddMinutes(3)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 5
        $status = aws ssm get-command-invocation `
                      --command-id $cmdId --instance-id $InstanceId `
                      --region $Region --query 'Status' --output text 2>$null
        if ($status -in @('Success','Failed','TimedOut','Cancelled')) {
            $color = if ($status -eq 'Success') { 'Green' } else { 'Red' }
            Write-Host " $status" -ForegroundColor $color
            if ($status -eq 'Success') {
                return aws ssm get-command-invocation `
                           --command-id $cmdId --instance-id $InstanceId `
                           --region $Region --query 'StandardOutputContent' --output text 2>$null
            }
            $errOut = aws ssm get-command-invocation `
                          --command-id $cmdId --instance-id $InstanceId `
                          --region $Region --query 'StandardErrorContent' --output text 2>$null
            if ($errOut) { Write-Warning $errOut }
            return $null
        }
        Write-Host '.' -NoNewline
    }
    Write-Warning "Timed out waiting for $Label check."
    return $null
}

# -- Check scripts ------------------------------------------------------------

# Windows: checks IIS, HTTP 200 from healthz, non-AWS app config registry key
$winCheck = @'
$r = @{}
$iis = Get-Service W3SVC -ErrorAction SilentlyContinue
$r.iis_running = ($null -ne $iis -and $iis.Status -eq 'Running')
try {
    $h = Invoke-WebRequest -Uri 'http://localhost/healthz/index.html' -UseBasicParsing -TimeoutSec 5
    $r.healthz_status = [int]$h.StatusCode
} catch { $r.healthz_status = 0 }
$appCfg = Get-ItemProperty 'HKLM:\SOFTWARE\MyApp\Config' -ErrorAction SilentlyContinue
$r.app_config_present = ($null -ne $appCfg)
$r.app_name = if ($appCfg) { $appCfg.AppName } else { 'MISSING' }
$r | ConvertTo-Json -Compress
'@

# Linux: checks nginx, HTTP 200 from healthz, non-AWS app config file
$lnxCheck = @'
#!/bin/bash
nginx_running=false
systemctl is-active nginx >/dev/null 2>&1 && nginx_running=true
hs=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/healthz/index.html 2>/dev/null)
[[ -z "$hs" ]] && hs=0
app_cfg=false
app_name=MISSING
if [[ -f /etc/myapp/config.env ]]; then
    app_cfg=true
    app_name=$(grep '^APP_NAME=' /etc/myapp/config.env | cut -d= -f2)
fi
echo "{\"nginx_running\":$nginx_running,\"healthz_status\":$hs,\"app_config_present\":$app_cfg,\"app_name\":\"$app_name\"}"
'@

# -- Run checks ---------------------------------------------------------------

Write-Host "`n=== Workload Health Check ($Phase) ===" -ForegroundColor Cyan
Write-Host "  Windows : $winId"
Write-Host "  Linux   : $lnxId"
Write-Host "  Region  : $Region"
Write-Host ""

$winRaw = Invoke-SsmCheck -InstanceId $winId -DocumentName 'AWS-RunPowerShellScript' `
                          -Script $winCheck -Label 'Windows'
$lnxRaw = Invoke-SsmCheck -InstanceId $lnxId -DocumentName 'AWS-RunShellScript' `
                          -Script $lnxCheck -Label 'Linux'

# -- Parse output -------------------------------------------------------------

function Parse-Json {
    param([string]$Raw, [string]$Label)
    if (-not $Raw) { return [pscustomobject]@{ error = 'no SSM output' } }
    # SSM output sometimes has trailing whitespace or extra lines; grab first { line
    $jsonLine = $Raw -split "`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1
    if (-not $jsonLine) {
        Write-Warning "$Label : could not find JSON in output:`n$Raw"
        return [pscustomobject]@{ parse_error = $Raw.Trim() }
    }
    try   { return $jsonLine.Trim() | ConvertFrom-Json }
    catch { return [pscustomobject]@{ parse_error = $jsonLine.Trim() } }
}

$winResult = Parse-Json -Raw $winRaw -Label 'Windows'
$lnxResult = Parse-Json -Raw $lnxRaw -Label 'Linux'

# -- Display ------------------------------------------------------------------

function Write-CheckRow {
    param([string]$Name, $Got, $Expected)
    $pass  = ("$Got".ToLower() -eq "$Expected".ToLower())
    $tag   = if ($pass) { 'PASS' } else { 'FAIL' }
    $color = if ($pass) { 'Green' } else { 'Red' }
    Write-Host ("    {0,-28} [{1}]  (got: {2})" -f $Name, $tag, $Got) -ForegroundColor $color
}

Write-Host "`n  Windows" -ForegroundColor Yellow
Write-CheckRow 'IIS running'          $winResult.iis_running          $true
Write-CheckRow 'Healthz HTTP status'  $winResult.healthz_status        200
Write-CheckRow 'App config present'   $winResult.app_config_present   $true
Write-CheckRow 'App name'             $winResult.app_name             'MigTestApp'

Write-Host "`n  Linux" -ForegroundColor Yellow
Write-CheckRow 'nginx running'        $lnxResult.nginx_running        $true
Write-CheckRow 'Healthz HTTP status'  $lnxResult.healthz_status       200
Write-CheckRow 'App config present'   $lnxResult.app_config_present   $true
Write-CheckRow 'App name'             $lnxResult.app_name             'MigTestApp'

# -- Save snapshot ------------------------------------------------------------

$snapshot = [ordered]@{
    Phase     = $Phase
    Timestamp = (Get-Date -Format 'o')
    Windows   = $winResult
    Linux     = $lnxResult
}
$ts      = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $reportDir "workload-check-$Phase-$ts.json"
$snapshot | ConvertTo-Json -Depth 10 | Set-Content $outFile
Write-Host "`n  Snapshot saved: $outFile" -ForegroundColor DarkGray

# -- After: diff against Before baseline --------------------------------------

if ($Phase -eq 'After') {
    Write-Host ""
    $baseline = Get-ChildItem $reportDir -Filter 'workload-check-Before-*.json' -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $baseline) {
        Write-Warning "No Before baseline found in $reportDir.  Run with -Phase Before first."
        exit 0
    }

    Write-Host "  Comparing against baseline: $($baseline.Name)" -ForegroundColor Cyan
    $before = Get-Content $baseline.FullName | ConvertFrom-Json

    $regressions = [System.Collections.Generic.List[string]]::new()

    # Fields that must be UNCHANGED (app layer must survive cleanup)
    $winFields = @('iis_running','app_config_present','app_name')
    $lnxFields = @('nginx_running','app_config_present','app_name')

    foreach ($f in $winFields) {
        $bv = "$($before.Windows.$f)".ToLower()
        $av = "$($winResult.$f)".ToLower()
        if ($bv -ne $av) { $regressions.Add("Windows.$f : '$bv' -> '$av'") }
    }
    foreach ($f in $lnxFields) {
        $bv = "$($before.Linux.$f)".ToLower()
        $av = "$($lnxResult.$f)".ToLower()
        if ($bv -ne $av) { $regressions.Add("Linux.$f : '$bv' -> '$av'") }
    }

    # healthz HTTP must still return 200 (changed == regression)
    foreach ($pair in @(
        @{ VM = 'Windows'; Before = $before.Windows.healthz_status; After = $winResult.healthz_status },
        @{ VM = 'Linux';   Before = $before.Linux.healthz_status;   After = $lnxResult.healthz_status }
    )) {
        $bv = "$($pair.Before)"; $av = "$($pair.After)"
        if ($bv -ne $av) { $regressions.Add("$($pair.VM).healthz_status : $bv -> $av") }
    }

    if ($regressions.Count -gt 0) {
        Write-Host ""
        Write-Host "  REGRESSION: Cleanup changed app-layer state!" -ForegroundColor Red
        $regressions | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
        Write-Host ""
        exit 1
    }

    Write-Host "  PASS: All app-layer checks unchanged post-cleanup." -ForegroundColor Green
}
