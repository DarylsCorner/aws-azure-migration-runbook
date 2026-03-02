#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes or disables AWS-specific in-guest components from a Windows VM
    migrated to Azure via Azure Migrate.

.DESCRIPTION
    Idempotent cleanup script that removes AWS agents, credentials, scheduled
    tasks, environment variables, and metadata references. Each action is
    individually gated so the script is safe to run during Test Migration and
    again at cutover.

    Drivers (ENA, NVMe, PV) are intentionally NOT removed by this script.
    Azure Migrate replaces boot-critical drivers during the replication phase.
    Removing NICs or storage drivers inside the guest risks connectivity loss.

.PARAMETER DryRun
    Log every action that WOULD be taken without making any changes.

.PARAMETER Phase
    TestMigration  - Conservative: stop/disable services, clean credentials & env vars.
    Cutover        - Full: everything from TestMigration plus MSI uninstalls and
                     scheduled-task removal.

.PARAMETER SkipAzureAgentCheck
    Do not verify that the Azure VM Agent is installed and running.
    Use only if waagent has already been validated by another process.

.PARAMETER ReportPath
    Write a JSON report to this file path. Defaults to the script directory.

.EXAMPLE
    .\Invoke-AWSCleanup.ps1 -DryRun -Phase TestMigration

.EXAMPLE
    .\Invoke-AWSCleanup.ps1 -Phase Cutover -ReportPath C:\Logs\cleanup-report.json
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,

    [ValidateSet('TestMigration', 'Cutover')]
    [string]$Phase = 'TestMigration',

    [switch]$SkipAzureAgentCheck,

    [string]$ReportPath = (Join-Path $PSScriptRoot "aws-cleanup-report_$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'   # Non-fatal: log and keep going

# ─────────────────────────────────────────────────────────────────────────────
# Logging & report infrastructure
# ─────────────────────────────────────────────────────────────────────────────
$script:Actions = [System.Collections.Generic.List[hashtable]]::new()

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'WARN'  { '[WARN ] ' }
        'ERROR' { '[ERROR] ' }
        'DRY'   { '[DRY  ] ' }
        default { '[INFO ] ' }
    }
    Write-Host "$ts $prefix$Message"
}

function Add-ActionResult {
    param(
        [string]$Name,
        [ValidateSet('Completed', 'Skipped', 'DryRun', 'Error')]
        [string]$Status,
        [string]$Detail = ''
    )
    $script:Actions.Add(@{ Name = $Name; Status = $Status; Detail = $Detail })
    $level = if ($Status -eq 'Error') { 'ERROR' } elseif ($Status -eq 'DryRun') { 'DRY' } else { 'INFO' }
    Write-Log "[$Status] $Name$(if ($Detail) { " - $Detail" })" -Level $level
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: stop + disable a Windows service (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Disable-ServiceIfPresent {
    param([string]$ServiceName, [string]$FriendlyName)

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-ActionResult -Name "Disable Service: $FriendlyName" -Status Skipped -Detail 'Service not found'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Disable Service: $FriendlyName" `
            -Status DryRun -Detail "Would stop ($($svc.Status)) and set StartType=Disabled"
        return
    }

    try {
        if ($svc.Status -ne 'Stopped') {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
        }
        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
        Add-ActionResult -Name "Disable Service: $FriendlyName" -Status Completed -Detail 'Stopped and disabled'
    } catch {
        Add-ActionResult -Name "Disable Service: $FriendlyName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: uninstall an MSI product by display name pattern (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Uninstall-ProgramIfPresent {
    param(
        [string]$DisplayNamePattern,
        [string]$FriendlyName,
        [string]$UninstallArgs = '/quiet /norestart'
    )

    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    $entry = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object { $_ -ne $null -and $_.PSObject.Properties['DisplayName'] -ne $null -and $_.DisplayName -like $DisplayNamePattern } | Select-Object -First 1

    if (-not $entry) {
        Add-ActionResult -Name "Uninstall: $FriendlyName" -Status Skipped -Detail 'Not installed'
        return
    }

    $uninstallStr = $entry.UninstallString
    if ($DryRun) {
        Add-ActionResult -Name "Uninstall: $FriendlyName" `
            -Status DryRun -Detail "Would run: $uninstallStr"
        return
    }

    try {
        if ($uninstallStr -match 'MsiExec') {
            $productCode = [regex]::Match($uninstallStr, '\{[A-F0-9\-]+\}').Value
            Start-Process msiexec.exe -ArgumentList "/x $productCode $UninstallArgs" -Wait -ErrorAction Stop
        } else {
            # EXE-based uninstaller
            Start-Process -FilePath $uninstallStr -ArgumentList $UninstallArgs -Wait -ErrorAction Stop
        }
        Add-ActionResult -Name "Uninstall: $FriendlyName" -Status Completed -Detail "Removed: $($entry.DisplayName) $($entry.DisplayVersion)"
    } catch {
        Add-ActionResult -Name "Uninstall: $FriendlyName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a registry key tree (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Remove-RegistryKeyIfPresent {
    param([string]$KeyPath, [string]$FriendlyName)

    if (-not (Test-Path $KeyPath)) {
        Add-ActionResult -Name "Remove Registry: $FriendlyName" -Status Skipped -Detail 'Key not found'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Remove Registry: $FriendlyName" -Status DryRun -Detail "Would remove: $KeyPath"
        return
    }

    try {
        Remove-Item -Path $KeyPath -Recurse -Force -ErrorAction Stop
        Add-ActionResult -Name "Remove Registry: $FriendlyName" -Status Completed -Detail "Removed: $KeyPath"
    } catch {
        Add-ActionResult -Name "Remove Registry: $FriendlyName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a directory (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Remove-DirectoryIfPresent {
    param([string]$DirectoryPath, [string]$FriendlyName)

    if (-not (Test-Path $DirectoryPath)) {
        Add-ActionResult -Name "Remove Directory: $FriendlyName" -Status Skipped -Detail 'Path not found'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Remove Directory: $FriendlyName" `
            -Status DryRun -Detail "Would remove: $DirectoryPath"
        return
    }

    try {
        Remove-Item -Path $DirectoryPath -Recurse -Force -ErrorAction Stop
        Add-ActionResult -Name "Remove Directory: $FriendlyName" -Status Completed -Detail "Removed: $DirectoryPath"
    } catch {
        Add-ActionResult -Name "Remove Directory: $FriendlyName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a scheduled task (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Remove-ScheduledTaskIfPresent {
    param([string]$TaskName, [string]$TaskPath = '\')

    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if (-not $task) {
        Add-ActionResult -Name "Remove Task: $TaskName" -Status Skipped -Detail 'Task not found'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Remove Task: $TaskName" -Status DryRun -Detail "Would remove scheduled task '$TaskPath$TaskName'"
        return
    }

    try {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction Stop
        Add-ActionResult -Name "Remove Task: $TaskName" -Status Completed -Detail 'Task removed'
    } catch {
        Add-ActionResult -Name "Remove Task: $TaskName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove lines from hosts file matching a pattern (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Remove-HostsEntryIfPresent {
    param([string]$Pattern, [string]$FriendlyName)

    $hostsFile = "$env:windir\System32\drivers\etc\hosts"
    $content   = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if (-not ($content -match $Pattern)) {
        Add-ActionResult -Name "Hosts File: $FriendlyName" -Status Skipped -Detail 'Entry not found'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Hosts File: $FriendlyName" -Status DryRun `
            -Detail "Would remove lines matching: $Pattern"
        return
    }

    try {
        $lines   = Get-Content $hostsFile
        $cleaned = $lines | Where-Object { $_ -notmatch $Pattern }
        $cleaned | Set-Content $hostsFile -Force -ErrorAction Stop
        Add-ActionResult -Name "Hosts File: $FriendlyName" -Status Completed `
            -Detail "Removed line(s) matching: $Pattern"
    } catch {
        Add-ActionResult -Name "Hosts File: $FriendlyName" -Status Error -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: clear a system-wide or machine environment variable (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Remove-MachineEnvVarIfPresent {
    param([string]$VariableName)

    $val = [System.Environment]::GetEnvironmentVariable($VariableName, 'Machine')
    if ($null -eq $val) {
        Add-ActionResult -Name "Env Var: $VariableName" -Status Skipped -Detail 'Variable not set'
        return
    }

    if ($DryRun) {
        Add-ActionResult -Name "Env Var: $VariableName" -Status DryRun -Detail "Would remove machine-scope variable (current value redacted)"
        return
    }

    try {
        [System.Environment]::SetEnvironmentVariable($VariableName, $null, 'Machine')
        Add-ActionResult -Name "Env Var: $VariableName" -Status Completed -Detail 'Variable removed'
    } catch {
        Add-ActionResult -Name "Env Var: $VariableName" -Status Error -Detail $_.Exception.Message
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 1 — Pre-flight
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "================================================"
Write-Log " AWS -> Azure In-Guest Cleanup (Windows)"
Write-Log " Phase   : $Phase"
Write-Log " DryRun  : $DryRun"
Write-Log " Host    : $env:COMPUTERNAME"
Write-Log " Started : $(Get-Date -Format 'u')"
Write-Log "================================================"

if ($DryRun) {
    Write-Log "DRY-RUN MODE - no changes will be made" -Level WARN
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 2 — Stop and disable AWS services (TestMigration + Cutover)
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 2: AWS Services ---"

$awsServices = @(
    @{ Name = 'AmazonSSMAgent';        Friendly = 'AWS SSM Agent' },
    @{ Name = 'AmazonCloudWatchAgent'; Friendly = 'AWS CloudWatch Agent' },
    @{ Name = 'EC2Config';             Friendly = 'EC2Config (legacy)' },
    @{ Name = 'EC2Launch';             Friendly = 'EC2Launch v1' },
    @{ Name = 'AmazonEC2Launch';       Friendly = 'EC2Launch v2' },
    @{ Name = 'KinesisAgent';          Friendly = 'AWS Kinesis Agent for Windows' },
    @{ Name = 'AWSNitroEnclaves';      Friendly = 'AWS Nitro Enclaves' },
    @{ Name = 'AWSCodeDeployAgent';    Friendly = 'AWS CodeDeploy Agent' }
)

foreach ($svc in $awsServices) {
    Disable-ServiceIfPresent -ServiceName $svc.Name -FriendlyName $svc.Friendly
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 3 — Credential and profile cleanup (TestMigration + Cutover)
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 3: AWS Credentials & Profiles ---"

# Machine-scope credential environment variables — never appropriate post-migration
$awsEnvVars = @(
    'AWS_ACCESS_KEY_ID',
    'AWS_SECRET_ACCESS_KEY',
    'AWS_SESSION_TOKEN',
    'AWS_DEFAULT_REGION',
    'AWS_REGION',
    'AWS_PROFILE',
    'AWS_CONFIG_FILE',
    'AWS_SHARED_CREDENTIALS_FILE',
    'AWS_ROLE_ARN',
    'AWS_WEB_IDENTITY_TOKEN_FILE'
)
foreach ($v in $awsEnvVars) {
    Remove-MachineEnvVarIfPresent -VariableName $v
}

# Shared-profile credentials under the system/service accounts that ran EC2 workloads.
# We target SYSTEM and the default profile only — user home dirs are intentionally
# left for application owners to review before cutover.
$systemAwsDir = Join-Path $env:SystemRoot 'system32\config\systemprofile\.aws'
Remove-DirectoryIfPresent -DirectoryPath $systemAwsDir -FriendlyName 'SYSTEM account .aws credentials'

$networkServiceAwsDir = Join-Path $env:SystemRoot 'ServiceProfiles\NetworkService\.aws'
Remove-DirectoryIfPresent -DirectoryPath $networkServiceAwsDir -FriendlyName 'NetworkService .aws credentials'

$localServiceAwsDir = Join-Path $env:SystemRoot 'ServiceProfiles\LocalService\.aws'
Remove-DirectoryIfPresent -DirectoryPath $localServiceAwsDir -FriendlyName 'LocalService .aws credentials'

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 4 — Hosts file: AWS metadata endpoint (TestMigration + Cutover)
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 4: Hosts File ---"

# 169.254.169.254 is the AWS (and Azure) IMDS address.
# Azure VMs use this address natively; we only remove explicit pinning lines that
# were added inside the guest to point to AWS-specific hostnames.
Remove-HostsEntryIfPresent -Pattern '169\.254\.169\.254.*ec2\.internal' `
    -FriendlyName 'AWS EC2 internal metadata hostname'

Remove-HostsEntryIfPresent -Pattern 'instance-data\.ec2\.internal' `
    -FriendlyName 'AWS instance-data hostname'

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 5 — AWS Scheduled Tasks (TestMigration + Cutover)
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 5: Scheduled Tasks ---"

$awsTasks = @(
    @{ Name = 'Amazon EC2Launch - Instance Initialization'; Path = '\' },
    @{ Name = 'Amazon EC2Launch - TemporaryDesktopBackground'; Path = '\' },
    @{ Name = 'AmazonCloudWatchAutoUpdate'; Path = '\Amazon\AmazonCloudWatch\' },
    @{ Name = 'Amazon SSM Agent Heartbeat'; Path = '\Amazon\' },
    @{ Name = 'AWSCodeDeployAgent'; Path = '\Amazon\' }
)

foreach ($task in $awsTasks) {
    Remove-ScheduledTaskIfPresent -TaskName $task.Name -TaskPath $task.Path
}

# Scan for any remaining tasks under \Amazon\ task folder (discovery + optional remove)
$amazonTaskFolder = Get-ScheduledTask -TaskPath '\Amazon\*' -ErrorAction SilentlyContinue
if ($amazonTaskFolder) {
    foreach ($t in $amazonTaskFolder) {
        Write-Log "Found additional Amazon task: $($t.TaskPath)$($t.TaskName)" -Level WARN
        Add-ActionResult -Name "Found Amazon Task: $($t.TaskName)" `
            -Status Skipped `
            -Detail "Path: $($t.TaskPath) - Manual review recommended before removal"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 6 — Registry cleanup (TestMigration + Cutover)
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 6: Registry ---"

# EC2Config / EC2Launch user-data execution markers — prevents re-execution.
# Safe to remove; they will not be written again as no EC2 service is running.
Remove-RegistryKeyIfPresent `
    -KeyPath 'HKLM:\SOFTWARE\Amazon\EC2ConfigService' `
    -FriendlyName 'EC2ConfigService registry hive'

Remove-RegistryKeyIfPresent `
    -KeyPath 'HKLM:\SOFTWARE\Amazon\EC2Launch' `
    -FriendlyName 'EC2Launch v1 registry hive'

Remove-RegistryKeyIfPresent `
    -KeyPath 'HKLM:\SOFTWARE\Amazon\EC2LaunchV2' `
    -FriendlyName 'EC2Launch v2 registry hive'

Remove-RegistryKeyIfPresent `
    -KeyPath 'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent' `
    -FriendlyName 'CloudWatch Agent registry hive'

Remove-RegistryKeyIfPresent `
    -KeyPath 'HKLM:\SOFTWARE\Amazon\SSM' `
    -FriendlyName 'SSM Agent registry hive'

# Retain: HKLM:\SOFTWARE\Amazon\PVDriver — driver registry; do not remove.

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 7 — Cutover-only: MSI uninstalls
# Only runs during Cutover phase. TestMigration leaves binaries in place so
# the machine can roll back cleanly via Azure Migrate test-failover revert.
# ═════════════════════════════════════════════════════════════════════════════
if ($Phase -eq 'Cutover') {
    Write-Log "--- Section 7: Cutover-only MSI Uninstalls ---"

    Uninstall-ProgramIfPresent -DisplayNamePattern 'Amazon SSM Agent*' `
        -FriendlyName 'AWS SSM Agent'

    Uninstall-ProgramIfPresent -DisplayNamePattern 'Amazon CloudWatch Agent*' `
        -FriendlyName 'AWS CloudWatch Agent'

    Uninstall-ProgramIfPresent -DisplayNamePattern 'EC2ConfigService*' `
        -FriendlyName 'EC2Config Service'

    Uninstall-ProgramIfPresent -DisplayNamePattern 'EC2Launch*' `
        -FriendlyName 'EC2Launch'

    Uninstall-ProgramIfPresent -DisplayNamePattern 'Amazon Kinesis Agent*' `
        -FriendlyName 'AWS Kinesis Agent for Windows'

    Uninstall-ProgramIfPresent -DisplayNamePattern 'AWS CodeDeploy Agent*' `
        -FriendlyName 'AWS CodeDeploy Agent'

    # AWS CLI — only uninstall if explicitly understood; apps may call 'aws' commands.
    # This is flagged as informational. Uncomment to enable.
    # Uninstall-ProgramIfPresent -DisplayNamePattern 'AWS Command Line Interface*' `
    #     -FriendlyName 'AWS CLI'
    Add-ActionResult -Name "Uninstall: AWS CLI" -Status Skipped `
        -Detail 'Intentionally skipped - application binaries may depend on AWS CLI. Review manually.'

    # Residual installation directories
    Remove-DirectoryIfPresent -DirectoryPath 'C:\Program Files\Amazon\SSM' `
        -FriendlyName 'SSM Agent install directory'
    Remove-DirectoryIfPresent -DirectoryPath 'C:\Program Files\Amazon\AmazonCloudWatchAgent' `
        -FriendlyName 'CloudWatch Agent install directory'
    Remove-DirectoryIfPresent -DirectoryPath 'C:\Program Files\Amazon\EC2ConfigService' `
        -FriendlyName 'EC2Config install directory'

} else {
    Write-Log "--- Section 7: Skipped (TestMigration phase - MSI uninstalls deferred to Cutover) ---"
    Add-ActionResult -Name 'MSI Uninstalls' -Status Skipped `
        -Detail 'Deferred to Cutover phase to preserve rollback capability'
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 8 — Azure VM Agent verification
# ═════════════════════════════════════════════════════════════════════════════
Write-Log "--- Section 8: Azure VM Agent ---"

if ($SkipAzureAgentCheck) {
    Add-ActionResult -Name 'Azure VM Agent Check' -Status Skipped -Detail 'Skipped by parameter'
} else {
    $waagent = Get-Service -Name 'WindowsAzureGuestAgent' -ErrorAction SilentlyContinue
    if (-not $waagent) {
        Add-ActionResult -Name 'Azure VM Agent Check' -Status Error `
            -Detail 'WindowsAzureGuestAgent service not found. VM Agent must be installed before the VM is usable on Azure. Download from: https://aka.ms/vmagentwin'
    } elseif ($waagent.Status -ne 'Running') {
        if (-not $DryRun) {
            try {
                Start-Service -Name 'WindowsAzureGuestAgent' -ErrorAction Stop
                Set-Service  -Name 'WindowsAzureGuestAgent' -StartupType Automatic -ErrorAction Stop
                Add-ActionResult -Name 'Azure VM Agent Check' -Status Completed `
                    -Detail 'Agent was stopped - started and set to Automatic'
            } catch {
                Add-ActionResult -Name 'Azure VM Agent Check' -Status Error -Detail $_.Exception.Message
            }
        } else {
            Add-ActionResult -Name 'Azure VM Agent Check' -Status DryRun `
                -Detail "Agent exists but status is '$($waagent.Status)' - would start and set to Automatic"
        }
    } else {
        # Agent is running — no action needed. Always Skipped (no change required).
        Add-ActionResult -Name 'Azure VM Agent Check' -Status Skipped `
            -Detail "WindowsAzureGuestAgent is Running (StartType: $($waagent.StartType))"
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# SECTION 9 — Report
# ═════════════════════════════════════════════════════════════════════════════
$summary = @{
    Total     = $script:Actions.Count
    Completed = @($script:Actions | Where-Object Status -eq 'Completed').Count
    Skipped   = @($script:Actions | Where-Object Status -eq 'Skipped').Count
    DryRun    = @($script:Actions | Where-Object Status -eq 'DryRun').Count
    Errors    = @($script:Actions | Where-Object Status -eq 'Error').Count
}

$report = @{
    SchemaVersion = '1.0'
    Timestamp     = (Get-Date -Format 'o')
    ComputerName  = $env:COMPUTERNAME
    Phase         = $Phase
    DryRun        = $DryRun.IsPresent
    Actions       = $script:Actions
    Summary       = $summary
}

$reportJson = $report | ConvertTo-Json -Depth 5 -Compress

# Write to file
try {
    $reportDir = Split-Path $ReportPath -Parent
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    $reportJson | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Log "Report written to: $ReportPath"
} catch {
    Write-Log "Could not write report file: $($_.Exception.Message)" -Level ERROR
}

Write-Log "============ Summary ============"
Write-Log "  Total   : $($summary.Total)"
Write-Log "  Done    : $($summary.Completed)"
Write-Log "  Skipped : $($summary.Skipped)"
Write-Log "  DryRun  : $($summary.DryRun)"
Write-Log "  Errors  : $($summary.Errors)"
Write-Log "================================="

# Return the report object so callers (e.g. Automation Runbook) can inspect it
return $report
