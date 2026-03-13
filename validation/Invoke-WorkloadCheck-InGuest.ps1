#Requires -RunAsAdministrator
<#
.SYNOPSIS
    In-guest workload health check for Windows. Mirrors the checks performed
    by infra/aws/Invoke-WorkloadCheck-SSM.ps1 but runs inside the Azure VM via
    az vm run-command rather than via SSM.

.DESCRIPTION
    Checks:
      - IIS (W3SVC) service is running
      - GET /healthz/index.html returns HTTP 200
      - HKLM:\SOFTWARE\MyApp\Config registry key is present and app_name matches

    Outputs a compact JSON object so the caller can compare against the
    infra/aws/workload-reports/workload-check-Before-*.json baseline.
#>

$r = @{}

# IIS
$iis = Get-Service W3SVC -ErrorAction SilentlyContinue
$r.iis_running = ($null -ne $iis -and $iis.Status -eq 'Running')

# HTTP healthz
try {
    $h = Invoke-WebRequest -Uri 'http://localhost/healthz/index.html' -UseBasicParsing -TimeoutSec 5
    $r.healthz_status = [int]$h.StatusCode
} catch {
    $r.healthz_status = 0
}

# App config registry key
$appCfg = Get-ItemProperty 'HKLM:\SOFTWARE\MyApp\Config' -ErrorAction SilentlyContinue
$r.app_config_present = ($null -ne $appCfg)
$r.app_name           = if ($appCfg -and $appCfg.PSObject.Properties['AppName']) {
    $appCfg.AppName
} else { 'MISSING' }

$r | ConvertTo-Json -Compress
