<#
.SYNOPSIS
    In-guest migration readiness auditor — detects AWS components and validates
    Azure agent health. Run BEFORE and AFTER cleanup to track progress.

.DESCRIPTION
    Performs a read-only audit of the VM. Produces a structured JSON report that
    can be compared between pre-cleanup and post-cleanup runs.

    Does NOT make any changes. Safe to run at any time.

.PARAMETER Mode
    Pre  — discovery: report everything AWS-related found on the VM.
    Post — verification: assert that AWS components are gone and Azure is healthy.
    Both (default) — full report with pass/fail assertions.

.PARAMETER ReportPath
    File path for the JSON output report.
    Default: script directory / readiness-report-<timestamp>.json

.EXAMPLE
    # Run before cleanup to understand the blast radius
    .\Invoke-MigrationReadiness.ps1 -Mode Pre

.EXAMPLE
    # Run after cleanup to validate it's clean
    .\Invoke-MigrationReadiness.ps1 -Mode Post

.EXAMPLE
    # Called via Run Command from Automation Runbook
    .\Invoke-MigrationReadiness.ps1 -Mode Both -ReportPath C:\Temp\readiness.json
#>
[CmdletBinding()]
param(
    [ValidateSet('Pre', 'Post', 'Both')]
    [string]$Mode = 'Both',

    [string]$ReportPath = (Join-Path $PSScriptRoot "readiness-report_$(Get-Date -Format 'yyyyMMdd-HHmmss').json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ─────────────────────────────────────────────────────────────────────────────
# Finding infrastructure
# ─────────────────────────────────────────────────────────────────────────────
$script:Findings = [System.Collections.Generic.List[hashtable]]::new()

function Add-Finding {
    param(
        [string]$Category,
        [string]$Name,
        [ValidateSet('Found', 'NotFound', 'Pass', 'Fail', 'Warning', 'Info')]
        [string]$Status,
        [string]$Detail = '',
        [string]$Recommendation = ''
    )
    $script:Findings.Add(@{
        Category       = $Category
        Name           = $Name
        Status         = $Status
        Detail         = $Detail
        Recommendation = $Recommendation
    })
}

function Write-FindingLine {
    param([hashtable]$f)
    $icon = switch ($f.Status) {
        'Found'    { '[FOUND  ]' }
        'NotFound' { '[CLEAN  ]' }
        'Pass'     { '[PASS   ]' }
        'Fail'     { '[FAIL   ]' }
        'Warning'  { '[WARN   ]' }
        'Info'     { '[INFO   ]' }
        default    { '[?      ]' }
    }
    Write-Host "$icon $($f.Category) / $($f.Name)$(if ($f.Detail) { ": $($f.Detail)" })"
    if ($f.Recommendation) {
        Write-Host "          → $($f.Recommendation)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Check helpers
# ─────────────────────────────────────────────────────────────────────────────
function Check-Service {
    param([string]$ServiceName, [string]$FriendlyName, [string]$Category = 'Services')
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Add-Finding -Category $Category -Name $FriendlyName `
            -Status Found `
            -Detail "Status=$($svc.Status) StartType=$($svc.StartType)" `
            -Recommendation "Stop and disable service '$ServiceName', then uninstall on Cutover"
    } else {
        Add-Finding -Category $Category -Name $FriendlyName -Status NotFound
    }
}

function Check-InstalledProgram {
    param([string]$DisplayNamePattern, [string]$FriendlyName, [string]$Category = 'Installed Software')
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $entry = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object {
        $_ -ne $null -and
        $_.PSObject.Properties['DisplayName'] -and
        $_.DisplayName -like $DisplayNamePattern
    } | Select-Object -First 1

    if ($entry) {
        Add-Finding -Category $Category -Name $FriendlyName `
            -Status Found `
            -Detail "$($entry.DisplayName) v$($entry.DisplayVersion)" `
            -Recommendation "Uninstall during Cutover phase"
    } else {
        Add-Finding -Category $Category -Name $FriendlyName -Status NotFound
    }
}

function Check-RegistryKey {
    param([string]$KeyPath, [string]$FriendlyName, [string]$Category = 'Registry')
    if (Test-Path $KeyPath) {
        Add-Finding -Category $Category -Name $FriendlyName `
            -Status Found -Detail $KeyPath `
            -Recommendation "Remove registry key '$KeyPath'"
    } else {
        Add-Finding -Category $Category -Name $FriendlyName -Status NotFound
    }
}

function Check-DirectoryExists {
    param([string]$Path, [string]$FriendlyName, [string]$Category = 'Filesystem')
    if (Test-Path $Path) {
        $sz = (Get-ChildItem $Path -Recurse -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        $szKb = [math]::Round(($sz / 1KB), 1)
        Add-Finding -Category $Category -Name $FriendlyName `
            -Status Found -Detail "Path: $Path  Size: ${szKb} KB" `
            -Recommendation "Remove directory"
    } else {
        Add-Finding -Category $Category -Name $FriendlyName -Status NotFound
    }
}

function Get-MachineEnvVar {
    param([string]$Name)
    [System.Environment]::GetEnvironmentVariable($Name, 'Machine')
}

function Check-MachineEnvVar {
    param([string]$VariableName, [string]$Category = 'Environment Variables')
    $val = Get-MachineEnvVar -Name $VariableName
    if ($null -ne $val) {
        Add-Finding -Category $Category -Name $VariableName `
            -Status Found -Detail 'Variable is set (value redacted)' `
            -Recommendation "Remove machine-scope environment variable '$VariableName'"
    } else {
        Add-Finding -Category $Category -Name $VariableName -Status NotFound
    }
}

function Check-HostsEntry {
    param([string]$Pattern, [string]$FriendlyName, [string]$Category = 'Hosts File')
    $hosts = "$env:windir\System32\drivers\etc\hosts"
    if (Get-Content $hosts -ErrorAction SilentlyContinue | Where-Object { $_ -match $Pattern }) {
        Add-Finding -Category $Category -Name $FriendlyName `
            -Status Found -Detail "Pattern '$Pattern' found in hosts file" `
            -Recommendation "Remove AWS-specific hosts entries"
    } else {
        Add-Finding -Category $Category -Name $FriendlyName -Status NotFound
    }
}

function Check-ScheduledTask {
    param([string]$TaskName, [string]$TaskPath = '\', [string]$Category = 'Scheduled Tasks')
    $t = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($t) {
        Add-Finding -Category $Category -Name $TaskName `
            -Status Found -Detail "State=$($t.State)" `
            -Recommendation "Remove scheduled task '$TaskPath$TaskName'"
    } else {
        Add-Finding -Category $Category -Name $TaskName -Status NotFound
    }
}

function Check-AzureAgent {
    $svc = Get-Service -Name 'WindowsAzureGuestAgent' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Add-Finding -Category 'Azure Agent' -Name 'WindowsAzureGuestAgent' `
            -Status Fail `
            -Detail 'Service not found' `
            -Recommendation 'Install the Azure VM Agent: https://aka.ms/vmagentwin'
    } elseif ($svc.Status -ne 'Running') {
        Add-Finding -Category 'Azure Agent' -Name 'WindowsAzureGuestAgent' `
            -Status Fail `
            -Detail "Service exists but is '$($svc.Status)'" `
            -Recommendation "Start-Service WindowsAzureGuestAgent and set to Automatic"
    } else {
        Add-Finding -Category 'Azure Agent' -Name 'WindowsAzureGuestAgent' `
            -Status Pass `
            -Detail "Running (StartType: $($svc.StartType))"
    }

    # Check Azure VM Agent version via registry
    $agentRegKey = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\GuestAgent' -ErrorAction SilentlyContinue
    $agentVersion = if ($agentRegKey -and $agentRegKey.PSObject.Properties['GuestAgentVersion']) {
        $agentRegKey.GuestAgentVersion
    } else { $null }
    if ($agentVersion) {
        Add-Finding -Category 'Azure Agent' -Name 'Agent Version' -Status Info `
            -Detail "v$agentVersion"
    }
}

function Check-IMDSReachable {
    # Azure IMDS — check that it responds with Azure metadata (not AWS)
    try {
        $resp = Invoke-RestMethod `
            -Uri 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' `
            -Headers @{ 'Metadata' = 'true' } `
            -TimeoutSec 3 `
            -ErrorAction Stop
        # Azure IMDS returns provider as 'Microsoft.Compute' (not plain 'Microsoft')
        if ($resp.compute -and $resp.compute.PSObject.Properties['provider'] -and
            $resp.compute.provider -like 'Microsoft*') {
            Add-Finding -Category 'Azure IMDS' -Name 'IMDS endpoint' `
                -Status Pass `
                -Detail "Azure IMDS responding. Provider: $($resp.compute.provider), Region: $($resp.compute.location)"
        } else {
            $prov = if ($resp.compute -and $resp.compute.PSObject.Properties['provider']) { $resp.compute.provider } else { '(unknown)' }
            Add-Finding -Category 'Azure IMDS' -Name 'IMDS endpoint' `
                -Status Warning `
                -Detail "IMDS responded but provider is '$prov' — expected 'Microsoft.Compute'"
        }
    } catch {
        Add-Finding -Category 'Azure IMDS' -Name 'IMDS endpoint' `
            -Status Warning `
            -Detail "IMDS did not respond: $($_.Exception.Message)" `
            -Recommendation "Verify the VM is running on Azure and Azure networking is configured"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Also scan Amazon-prefixed task folders dynamically
# ─────────────────────────────────────────────────────────────────────────────
function Scan-AmazonScheduledTasks {
    $amazonTasks = Get-ScheduledTask -TaskPath '\Amazon\*' -ErrorAction SilentlyContinue
    if ($amazonTasks) {
        foreach ($t in $amazonTasks) {
            Add-Finding -Category 'Scheduled Tasks' -Name $t.TaskName `
                -Status Found `
                -Detail "Path=$($t.TaskPath) State=$($t.State)" `
                -Recommendation "Review and remove task under Amazon task folder"
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
# Run all checks
# ═════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "════════════════════════════════════════════════"
Write-Host " AWS → Azure Migration Readiness Check"
Write-Host " Mode    : $Mode"
Write-Host " Host    : $env:COMPUTERNAME"
Write-Host " Time    : $(Get-Date -Format 'u')"
Write-Host "════════════════════════════════════════════════"
Write-Host ""

# ── Services ─────────────────────────────────────────────────────────────────
Write-Host "--- Services ---"
Check-Service 'AmazonSSMAgent'        'AWS SSM Agent'
Check-Service 'AmazonCloudWatchAgent' 'AWS CloudWatch Agent'
Check-Service 'EC2Config'             'EC2Config (legacy)'
Check-Service 'EC2Launch'             'EC2Launch v1'
Check-Service 'AmazonEC2Launch'       'EC2Launch v2'
Check-Service 'KinesisAgent'          'AWS Kinesis Agent'
Check-Service 'AWSNitroEnclaves'      'AWS Nitro Enclaves'
Check-Service 'AWSCodeDeployAgent'    'AWS CodeDeploy Agent'

# ── Installed Software ────────────────────────────────────────────────────────
Write-Host "--- Installed Software ---"
Check-InstalledProgram 'Amazon SSM Agent*'            'AWS SSM Agent'
Check-InstalledProgram 'Amazon CloudWatch Agent*'     'AWS CloudWatch Agent'
Check-InstalledProgram 'EC2ConfigService*'            'EC2Config'
Check-InstalledProgram 'EC2Launch*'                   'EC2Launch'
Check-InstalledProgram 'Amazon Kinesis Agent*'        'AWS Kinesis Agent'
Check-InstalledProgram 'AWS CodeDeploy Agent*'        'AWS CodeDeploy Agent'
Check-InstalledProgram 'AWS Command Line Interface*'  'AWS CLI'
Check-InstalledProgram 'Amazon Web Services*'         'Amazon Web Services (generic)'

# ── Registry ─────────────────────────────────────────────────────────────────
Write-Host "--- Registry ---"
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2ConfigService' 'EC2ConfigService registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2Launch'        'EC2Launch v1 registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2LaunchV2'      'EC2Launch v2 registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent' 'CloudWatch Agent registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\SSM'              'SSM Agent registry hive'

# ── Filesystem ────────────────────────────────────────────────────────────────
Write-Host "--- Filesystem ---"
Check-DirectoryExists 'C:\Program Files\Amazon\SSM'                'SSM Agent binaries'
Check-DirectoryExists 'C:\Program Files\Amazon\AmazonCloudWatchAgent' 'CloudWatch Agent binaries'
Check-DirectoryExists 'C:\Program Files\Amazon\EC2ConfigService'   'EC2Config binaries'
Check-DirectoryExists "$env:SystemRoot\system32\config\systemprofile\.aws" 'SYSTEM .aws credentials'
Check-DirectoryExists "$env:SystemRoot\ServiceProfiles\NetworkService\.aws" 'NetworkService .aws credentials'

# ── Environment Variables ─────────────────────────────────────────────────────
Write-Host "--- Environment Variables ---"
foreach ($v in @(
    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
    'AWS_DEFAULT_REGION', 'AWS_REGION', 'AWS_PROFILE',
    'AWS_CONFIG_FILE', 'AWS_ROLE_ARN', 'AWS_WEB_IDENTITY_TOKEN_FILE'
)) {
    Check-MachineEnvVar $v
}

# ── Hosts File ────────────────────────────────────────────────────────────────
Write-Host "--- Hosts File ---"
Check-HostsEntry '169\.254\.169\.254.*ec2\.internal' 'AWS EC2-internal metadata hostname'
Check-HostsEntry 'instance-data\.ec2\.internal'      'AWS instance-data hostname'

# ── Scheduled Tasks ───────────────────────────────────────────────────────────
Write-Host "--- Scheduled Tasks ---"
Check-ScheduledTask 'Amazon EC2Launch - Instance Initialization'
Check-ScheduledTask 'AmazonCloudWatchAutoUpdate' '\Amazon\AmazonCloudWatch\'
Scan-AmazonScheduledTasks

# ── Azure Agent & IMDS ────────────────────────────────────────────────────────
Write-Host "--- Azure Agent & IMDS ---"
Check-AzureAgent
Check-IMDSReachable

# ─────────────────────────────────────────────────────────────────────────────
# Post mode: assert clean state
# ─────────────────────────────────────────────────────────────────────────────
$postModeAssertions = [System.Collections.Generic.List[hashtable]]::new()

if ($Mode -in 'Post', 'Both') {
    Write-Host ""
    Write-Host "--- Post-Cleanup Assertions ---"

    $foundItems = @($script:Findings | Where-Object {
        $_.Status -eq 'Found' -and $_.Category -ne 'Azure Agent' -and $_.Category -ne 'Azure IMDS'
    })
    $failItems  = @($script:Findings | Where-Object { $_.Status -eq 'Fail' })

    if ($foundItems.Count -eq 0) {
        Write-Host "[PASS   ] No AWS components detected on this VM."
    } else {
        Write-Host "[FAIL   ] $($foundItems.Count) AWS component(s) still present:"
        foreach ($fi in $foundItems) {
            Write-Host "          - $($fi.Category) / $($fi.Name): $($fi.Detail)"
        }
    }

    if ($failItems.Count -eq 0) {
        Write-Host "[PASS   ] All Azure agent checks passed."
    } else {
        foreach ($fi in $failItems) {
            Write-Host "[FAIL   ] $($fi.Category) / $($fi.Name): $($fi.Detail)"
            if ($fi.Recommendation) {
                Write-Host "          → $($fi.Recommendation)"
            }
        }
    }

    $postModeAssertions.Add(@{
        AwsComponentsFound = $foundItems.Count
        AzureAgentFailed   = $failItems.Count
        CleanState         = ($foundItems.Count -eq 0 -and $failItems.Count -eq 0)
    }) | Out-Null
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
$counts = @{
    Found    = @($script:Findings | Where-Object Status -eq 'Found').Count
    NotFound = @($script:Findings | Where-Object Status -eq 'NotFound').Count
    Pass     = @($script:Findings | Where-Object Status -eq 'Pass').Count
    Fail     = @($script:Findings | Where-Object Status -eq 'Fail').Count
    Warning  = @($script:Findings | Where-Object Status -eq 'Warning').Count
    Info     = @($script:Findings | Where-Object Status -eq 'Info').Count
}

Write-Host ""
Write-Host "════════════ Summary ════════════"
Write-Host "  Found AWS components : $($counts.Found)"
Write-Host "  Clean (not found)    : $($counts.NotFound)"
Write-Host "  Azure checks passed  : $($counts.Pass)"
Write-Host "  Azure checks failed  : $($counts.Fail)"
Write-Host "  Warnings             : $($counts.Warning)"
Write-Host "═════════════════════════════════"

# ─────────────────────────────────────────────────────────────────────────────
# Write JSON report
# ─────────────────────────────────────────────────────────────────────────────
$report = @{
    SchemaVersion    = '1.0'
    Timestamp        = (Get-Date -Format 'o')
    ComputerName     = $env:COMPUTERNAME
    Mode             = $Mode
    Findings         = $script:Findings
    Summary          = $counts
    PostAssertions   = if ($postModeAssertions.Count -gt 0) { $postModeAssertions[0] } else { $null }
}

try {
    $reportDir = Split-Path $ReportPath -Parent
    if (-not (Test-Path $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    $report | ConvertTo-Json -Depth 5 | Set-Content -Path $ReportPath -Encoding UTF8
    Write-Host "Report: $ReportPath"
} catch {
    Write-Warning "Could not write report: $($_.Exception.Message)"
}

return $report
