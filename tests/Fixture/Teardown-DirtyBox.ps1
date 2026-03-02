#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes all fake AWS artifacts created by Setup-DirtyBox.ps1.

.DESCRIPTION
    Reads the manifest written by Setup-DirtyBox.ps1 and removes exactly what
    was created. Can also run without a manifest by removing all known artifact
    patterns — use -Force for that mode.

.PARAMETER Force
    Remove all known DirtyBox artifact patterns even without a manifest.
    Use this if the manifest is missing or you want a guaranteed clean state.

.EXAMPLE
    # Normal teardown using manifest
    .\tests\Fixture\Teardown-DirtyBox.ps1

.EXAMPLE
    # Full scan-and-remove (no manifest needed)
    .\tests\Fixture\Teardown-DirtyBox.ps1 -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Step { param([string]$Msg) Write-Host "[TEARDOWN] $Msg" -ForegroundColor Magenta }
function Write-OK   { param([string]$Msg) Write-Host "  [-] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "  [~] SKIP: $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  [!] ERROR: $Msg" -ForegroundColor Red }

$removed = 0

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions
# ─────────────────────────────────────────────────────────────────────────────
function Remove-FakeService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-Skip "Service $Name not found"; return }

    # Only remove if it has the MIGRATION-TEST marker in its display name
    if ($svc.DisplayName -notmatch 'MIGRATION-TEST' -and -not $Force) {
        Write-Skip "Service $Name exists but was not created by DirtyBox (DisplayName: $($svc.DisplayName)). Use -Force to remove."
        return
    }

    try {
        if ($svc.Status -ne 'Stopped') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
        sc.exe delete $Name | Out-Null
        Write-OK "Service $Name deleted"
        $script:removed++
    } catch {
        Write-Err "Service $Name : $($_.Exception.Message)"
    }
}

function Remove-FakeRegKey {
    param([string]$KeyPath)
    if (-not (Test-Path $KeyPath)) { Write-Skip "Registry $KeyPath not found"; return }

    # Verify it's a DirtyBox key by checking the marker property
    $marker = (Get-ItemProperty -Path $KeyPath -Name 'MigrationTestMarker' -ErrorAction SilentlyContinue)?.MigrationTestMarker
    $isUninstallEntry = (Get-ItemProperty -Path $KeyPath -Name 'MigrationTest' -ErrorAction SilentlyContinue)?.MigrationTest

    if ($null -eq $marker -and $null -eq $isUninstallEntry -and -not $Force) {
        Write-Skip "Registry $KeyPath has no DirtyBox marker — skipping. Use -Force to remove."
        return
    }

    try {
        Remove-Item -Path $KeyPath -Recurse -Force -ErrorAction Stop
        Write-OK "Registry $KeyPath removed"
        $script:removed++
    } catch {
        Write-Err "Registry $KeyPath : $($_.Exception.Message)"
    }
}

function Remove-FakeEnvVar {
    param([string]$Name)
    $val = [System.Environment]::GetEnvironmentVariable($Name, 'Machine')
    if ($null -eq $val) { Write-Skip "Env var $Name not set"; return }
    try {
        [System.Environment]::SetEnvironmentVariable($Name, $null, 'Machine')
        Write-OK "Env var $Name removed"
        $script:removed++
    } catch {
        Write-Err "Env var $Name : $($_.Exception.Message)"
    }
}

function Remove-FakeHostsEntries {
    $hostsFile   = "$env:windir\System32\drivers\etc\hosts"
    $markerBegin = '# --- MIGRATION-TEST AWS entries (Setup-DirtyBox.ps1) ---'
    $markerEnd   = '# --- end MIGRATION-TEST AWS entries ---'

    $lines = Get-Content $hostsFile -ErrorAction SilentlyContinue
    if (-not ($lines -match [regex]::Escape($markerBegin))) {
        Write-Skip "No MIGRATION-TEST hosts entries found"
        return
    }

    try {
        $inBlock = $false
        $cleaned = foreach ($line in $lines) {
            if ($line -match [regex]::Escape($markerBegin)) { $inBlock = $true }
            if (-not $inBlock) { $line }
            if ($line -match [regex]::Escape($markerEnd))   { $inBlock = $false }
        }
        $cleaned | Set-Content -Path $hostsFile -Encoding ASCII -ErrorAction Stop
        Write-OK "MIGRATION-TEST hosts entries removed"
        $script:removed++
    } catch {
        Write-Err "Hosts file: $($_.Exception.Message)"
    }
}

function Remove-FakeTask {
    param([string]$Name, [string]$Path)
    $t = Get-ScheduledTask -TaskName $Name -TaskPath $Path -ErrorAction SilentlyContinue
    if (-not $t) { Write-Skip "Task $Path$Name not found"; return }

    if ($t.Description -notmatch 'MIGRATION-TEST' -and -not $Force) {
        Write-Skip "Task $Path$Name has no DirtyBox marker — skipping. Use -Force."
        return
    }

    try {
        Unregister-ScheduledTask -TaskName $Name -TaskPath $Path -Confirm:$false -ErrorAction Stop
        Write-OK "Task $Path$Name removed"
        $script:removed++
    } catch {
        Write-Err "Task $Name : $($_.Exception.Message)"
    }
}

function Remove-FakeDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) { Write-Skip "Directory $Path not found"; return }

    # Verify DirtyBox marker file
    $marker = Join-Path $Path 'MIGRATION-TEST.txt'
    if (-not (Test-Path $marker) -and -not $Force) {
        Write-Skip "$Path has no MIGRATION-TEST.txt marker — skipping. Use -Force."
        return
    }

    try {
        Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
        Write-OK "Directory $Path removed"
        $script:removed++
    } catch {
        Write-Err "Directory $Path : $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SERVICES
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake services..."
@('AmazonSSMAgent', 'AmazonCloudWatchAgent', 'AWSCodeDeployAgent') |
    ForEach-Object { Remove-FakeService -Name $_ }

# ─────────────────────────────────────────────────────────────────────────────
# REGISTRY
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake registry hives..."
@(
    'HKLM:\SOFTWARE\Amazon\EC2ConfigService',
    'HKLM:\SOFTWARE\Amazon\EC2Launch',
    'HKLM:\SOFTWARE\Amazon\EC2LaunchV2',
    'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent',
    'HKLM:\SOFTWARE\Amazon\SSM',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AmazonSSMAgent-MIGRATIONTEST'
) | ForEach-Object { Remove-FakeRegKey -KeyPath $_ }

# Also remove parent \Amazon key if now empty
$amazonRoot = 'HKLM:\SOFTWARE\Amazon'
if (Test-Path $amazonRoot) {
    $children = Get-ChildItem $amazonRoot -ErrorAction SilentlyContinue
    if ($null -eq $children -or $children.Count -eq 0) {
        try {
            Remove-Item $amazonRoot -Force -ErrorAction Stop
            Write-OK "Empty HKLM:\SOFTWARE\Amazon parent key removed"
            $script:removed++
        } catch {
            Write-Err "Amazon root key: $($_.Exception.Message)"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ENVIRONMENT VARIABLES
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake environment variables..."
@('AWS_DEFAULT_REGION','AWS_REGION','AWS_PROFILE','AWS_CONFIG_FILE') |
    ForEach-Object { Remove-FakeEnvVar -Name $_ }

# ─────────────────────────────────────────────────────────────────────────────
# HOSTS FILE
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake hosts entries..."
Remove-FakeHostsEntries

# ─────────────────────────────────────────────────────────────────────────────
# SCHEDULED TASKS
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake scheduled tasks..."
Remove-FakeTask -Name 'Amazon EC2Launch - Instance Initialization' -Path '\'
Remove-FakeTask -Name 'AmazonCloudWatchAutoUpdate'                 -Path '\Amazon\AmazonCloudWatch\'
Remove-FakeTask -Name 'Amazon SSM Agent Heartbeat'                 -Path '\Amazon\'

# Remove \Amazon\ task folder if now empty
try {
    $amazonFolder = Get-ScheduledTask -TaskPath '\Amazon\*' -ErrorAction SilentlyContinue
    if (-not $amazonFolder) {
        # Remove the folder via COM
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $root = $svc.GetFolder('\')
        try { $root.DeleteFolder('Amazon', 0) } catch { }
        Write-OK "\Amazon\ task folder cleaned up"
    }
} catch { }

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Removing fake directories..."
@(
    'C:\Program Files\Amazon\SSM',
    'C:\Program Files\Amazon\AmazonCloudWatchAgent',
    'C:\Program Files\Amazon\EC2ConfigService',
    "$env:SystemRoot\system32\config\systemprofile\.aws",
    "$env:SystemRoot\ServiceProfiles\NetworkService\.aws",
    "$env:SystemRoot\ServiceProfiles\LocalService\.aws"
) | ForEach-Object { Remove-FakeDirectory -Path $_ }

# Clean up the parent \Amazon\ dir if empty
$amazonPF = 'C:\Program Files\Amazon'
if ((Test-Path $amazonPF) -and -not (Get-ChildItem $amazonPF -ErrorAction SilentlyContinue)) {
    Remove-Item $amazonPF -Force -ErrorAction SilentlyContinue
    Write-OK "Empty 'C:\Program Files\Amazon' removed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Remove manifest
# ─────────────────────────────────────────────────────────────────────────────
$manifestPath = Join-Path $PSScriptRoot 'dirtybox-manifest.json'
if (Test-Path $manifestPath) {
    Remove-Item $manifestPath -Force -ErrorAction SilentlyContinue
    Write-OK "Manifest file removed"
}

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Magenta
Write-Host " Teardown complete. $removed artifact(s) removed." -ForegroundColor Magenta
Write-Host "════════════════════════════════════════════" -ForegroundColor Magenta
