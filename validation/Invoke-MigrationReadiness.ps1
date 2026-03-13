<#
.SYNOPSIS
    In-guest migration readiness auditor -- detects AWS components and validates
    Azure agent health. Run BEFORE and AFTER cleanup to track progress.

.DESCRIPTION
    Performs a read-only audit of the VM. Produces a structured JSON report that
    can be compared between pre-cleanup and post-cleanup runs.

    Does NOT make any changes. Safe to run at any time.

.PARAMETER Mode
    Pre  -- discovery: report everything AWS-related found on the VM.
    Post -- verification: assert that AWS components are gone and Azure is healthy.
    Both (default) -- full report with pass/fail assertions.

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

    # TestMigration: MSI uninstalls are deferred; stopped/disabled services and
    # installed software are acceptable -- they will be removed at Cutover.
    # Cutover (default): everything must be gone.
    [ValidateSet('TestMigration', 'Cutover')]
    [string]$Phase = 'Cutover',

    [string]$ReportPath = ''
)

# Resolve ReportPath default here (not in param block) so $PSScriptRoot empty-string
# does not cause a binding failure when run via az vm run-command / Azure Automation.
$script:LogDir = 'C:\ProgramData\MigrationLogs'
if (-not (Test-Path $script:LogDir)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}
$script:RunStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if (-not $ReportPath) {
    $ReportPath = Join-Path $script:LogDir "readiness-$Phase-$($script:RunStamp).json"
}
$TranscriptPath = Join-Path $script:LogDir "readiness-$Phase-$($script:RunStamp).log"
Start-Transcript -Path $TranscriptPath -Append -Force | Out-Null

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# -----------------------------------------------------------------------------
# Finding infrastructure
# -----------------------------------------------------------------------------
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
        Write-Host "          -> $($f.Recommendation)"
    }
}

# -----------------------------------------------------------------------------
# Check helpers
# -----------------------------------------------------------------------------
function Check-Service {
    param([string]$ServiceName, [string]$FriendlyName, [string]$Category = 'Services')
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        $isMitigated = ($Phase -eq 'TestMigration') -and
                       ($svc.Status -in 'Stopped','StopPending') -and
                       ($svc.StartType -in 'Disabled','Manual')
        if ($isMitigated) {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Info `
                -Detail "Status=$($svc.Status) StartType=$($svc.StartType) -- stopped/disabled, MSI uninstall deferred to Cutover"
        } else {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Found `
                -Detail "Status=$($svc.Status) StartType=$($svc.StartType)" `
                -Recommendation "Stop and disable service '$ServiceName', then uninstall on Cutover"
        }
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
        if ($Phase -eq 'TestMigration') {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Info `
                -Detail "$($entry.DisplayName) v$($entry.DisplayVersion) -- present, uninstall deferred to Cutover"
        } else {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Found `
                -Detail "$($entry.DisplayName) v$($entry.DisplayVersion)" `
                -Recommendation "Uninstall during Cutover phase"
        }
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
        if ($Phase -eq 'TestMigration') {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Info -Detail "Path: $Path  Size: ${szKb} KB -- present, removal deferred to Cutover"
        } else {
            Add-Finding -Category $Category -Name $FriendlyName `
                -Status Found -Detail "Path: $Path  Size: ${szKb} KB" `
                -Recommendation "Remove directory"
        }
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
    # Azure IMDS -- check that it responds with Azure metadata (not AWS)
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
                -Detail "IMDS responded but provider is '$prov' -- expected 'Microsoft.Compute'"
        }
    } catch {
        Add-Finding -Category 'Azure IMDS' -Name 'IMDS endpoint' `
            -Status Warning `
            -Detail "IMDS did not respond: $($_.Exception.Message)" `
            -Recommendation "Verify the VM is running on Azure and Azure networking is configured"
    }
}

# -----------------------------------------------------------------------------
# Heuristic scans -- surface unknown AWS artifacts not in the specific checklist.
# These log as Warning so they appear in the report without failing assertions.
# -----------------------------------------------------------------------------

# Any service whose DisplayName or Description contains Amazon/AWS/EC2 keywords
# that is NOT already covered by the specific Check-Service calls above.
function Scan-AllAwsServices {
    $knownNames = @(
        'AmazonSSMAgent','AmazonCloudWatchAgent','EC2Config','EC2Launch',
        'Amazon EC2Launch','KinesisAgent','AWSNitroEnclaves','AWSCodeDeployAgent',
        'AWSLiteAgent'
    )
    $awsPattern = 'amazon|\baws\b|\bec2\b|\bssm\b'
    $allServices = Get-Service -ErrorAction SilentlyContinue
    foreach ($svc in $allServices) {
        if ($knownNames -contains $svc.Name) { continue }   # already checked specifically
        $displayName = $svc.DisplayName
        $description = (Get-CimInstance Win32_Service -Filter "Name='$($svc.Name)'" -ErrorAction SilentlyContinue).Description
        if ($displayName -match $awsPattern -or $description -match $awsPattern) {
            Add-Finding -Category 'Services (Heuristic)' -Name $svc.Name `
                -Status Warning `
                -Detail "DisplayName='$displayName' Status=$($svc.Status) -- matches AWS keyword, not in known list" `
                -Recommendation "Review service '$($svc.Name)' to determine if it should be removed"
        }
    }
}

# Any sub-key under HKLM:\SOFTWARE\Amazon\ not covered by specific Check-RegistryKey calls
function Scan-AmazonRegistrySubkeys {
    $knownKeys = @(
        'EC2ConfigService','EC2Launch','EC2LaunchV2','AmazonCloudWatchAgent','SSM','PVDriver',
        'MachineImage','WarmBoot'
    )
    $amazonRoot = 'HKLM:\SOFTWARE\Amazon'
    if (-not (Test-Path $amazonRoot)) { return }
    $subkeys = Get-ChildItem $amazonRoot -ErrorAction SilentlyContinue
    foreach ($key in $subkeys) {
        $leaf = Split-Path $key.Name -Leaf
        if ($knownKeys -contains $leaf) { continue }   # already checked or intentionally kept
        Add-Finding -Category 'Registry (Heuristic)' -Name "HKLM:\SOFTWARE\Amazon\$leaf" `
            -Status Warning `
            -Detail "Unlisted sub-key present under HKLM:\SOFTWARE\Amazon\" `
            -Recommendation "Review registry key 'HKLM:\SOFTWARE\Amazon\$leaf' and remove if AWS-specific"
    }
}

# Any installed program whose DisplayName contains Amazon or AWS not in the known list
function Scan-AllAwsSoftware {
    $knownPatterns = @(
        'Amazon SSM Agent*','Amazon CloudWatch Agent*','EC2ConfigService*',
        'EC2Launch*','Amazon EC2Launch*','Amazon Kinesis Agent*','AWS CodeDeploy Agent*',
        'AWS Command Line Interface*','Amazon Web Services*',
        'aws-cfn-bootstrap*','AWS PV Drivers*'
    )
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $awsEntries = $regPaths | ForEach-Object {
        Get-ItemProperty $_ -ErrorAction SilentlyContinue
    } | Where-Object {
        $_ -ne $null -and
        $_.PSObject.Properties['DisplayName'] -ne $null -and
        $_.DisplayName -match '(?i)(\bamazon\b|\baws\b|\bEC2\b)'
    }
    foreach ($entry in $awsEntries) {
        $alreadyKnown = $false
        foreach ($p in $knownPatterns) {
            if ($entry.DisplayName -like $p) { $alreadyKnown = $true; break }
        }
        if ($alreadyKnown) { continue }
        Add-Finding -Category 'Installed Software (Heuristic)' -Name $entry.DisplayName `
            -Status Warning `
            -Detail "v$($entry.DisplayVersion) -- matches AWS keyword, not in known list" `
            -Recommendation "Review '$($entry.DisplayName)' to determine if it should be uninstalled"
    }
}

# Any subdirectory under C:\Program Files\Amazon\ not in the known list
function Scan-AmazonDirectory {
    $knownDirs = @('SSM','AmazonCloudWatchAgent','EC2ConfigService','EC2Launch','Ec2ConfigService','cfn-bootstrap','XenTools')
    $amazonRoot = 'C:\Program Files\Amazon'
    if (-not (Test-Path $amazonRoot)) { return }
    $subdirs = Get-ChildItem -Path $amazonRoot -Directory -ErrorAction SilentlyContinue
    foreach ($dir in $subdirs) {
        if ($knownDirs -contains $dir.Name) { continue }   # already checked specifically
        Add-Finding -Category 'Filesystem (Heuristic)' -Name $dir.FullName `
            -Status Warning `
            -Detail "Unlisted directory under C:\Program Files\Amazon\" `
            -Recommendation "Review '$($dir.FullName)' and remove if AWS-specific"
    }
    # Also flag if the root Amazon dir still exists after Cutover (subdirs gone but root may linger)
    if ($Phase -eq 'Cutover' -and -not $subdirs) {
        Add-Finding -Category 'Filesystem (Heuristic)' -Name $amazonRoot `
            -Status Warning `
            -Detail "Amazon root directory is empty but still present" `
            -Recommendation "Remove empty directory '$amazonRoot'"
    }
}

# Also scan Amazon-prefixed task folders dynamically
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

# =============================================================================
# Run all checks
# =============================================================================
Write-Host ""
Write-Host "================================================"
Write-Host " AWS -> Azure Migration Readiness Check"
Write-Host " Mode    : $Mode"
Write-Host " Phase   : $Phase"
Write-Host " Host    : $env:COMPUTERNAME"
Write-Host " Time    : $(Get-Date -Format 'u')"
Write-Host "================================================"
Write-Host ""

# -- Services -----------------------------------------------------------------
Write-Host "--- Services ---"
Check-Service 'AmazonSSMAgent'        'AWS SSM Agent'
Check-Service 'AmazonCloudWatchAgent' 'AWS CloudWatch Agent'
Check-Service 'EC2Config'             'EC2Config (legacy)'
Check-Service 'EC2Launch'             'EC2Launch v1'
Check-Service 'Amazon EC2Launch'      'EC2Launch v2'
Check-Service 'KinesisAgent'          'AWS Kinesis Agent'
Check-Service 'AWSNitroEnclaves'      'AWS Nitro Enclaves'
Check-Service 'AWSCodeDeployAgent'    'AWS CodeDeploy Agent'
Check-Service 'AWSLiteAgent'          'AWS Lite Guest Agent'

# -- Installed Software --------------------------------------------------------
Write-Host "--- Installed Software ---"
Check-InstalledProgram 'Amazon SSM Agent*'            'AWS SSM Agent'
Check-InstalledProgram 'Amazon CloudWatch Agent*'     'AWS CloudWatch Agent'
Check-InstalledProgram 'EC2ConfigService*'            'EC2Config'
Check-InstalledProgram 'EC2Launch*'                   'EC2Launch'
Check-InstalledProgram 'Amazon Kinesis Agent*'        'AWS Kinesis Agent'
Check-InstalledProgram 'AWS CodeDeploy Agent*'        'AWS CodeDeploy Agent'
Check-InstalledProgram 'AWS Command Line Interface*'  'AWS CLI'
Check-InstalledProgram 'Amazon Web Services*'         'Amazon Web Services (generic)'
Check-InstalledProgram 'Amazon EC2Launch*'            'EC2Launch v2 (MSI)'
Check-InstalledProgram 'aws-cfn-bootstrap*'           'AWS CloudFormation Bootstrap'

# AWS PV Drivers -- intentionally NOT flagged as Found; Azure Migrate replaces these
# during ASR replication. Report as Info so they never fail Post assertions.
$pvEntry = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
) | ForEach-Object { Get-ItemProperty $_ -ErrorAction SilentlyContinue } |
    Where-Object { $_ -ne $null -and $_.PSObject.Properties['DisplayName'] -ne $null -and $_.DisplayName -like 'AWS PV Drivers*' } |
    Select-Object -First 1
if ($pvEntry) {
    Add-Finding -Category 'Installed Software' -Name 'AWS PV Drivers' -Status Info `
        -Detail "v$($pvEntry.DisplayVersion) -- intentionally retained; Azure Migrate replaces PV drivers during ASR replication"
} else {
    Add-Finding -Category 'Installed Software' -Name 'AWS PV Drivers' -Status NotFound
}

# -- Registry -----------------------------------------------------------------
Write-Host "--- Registry ---"
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2ConfigService' 'EC2ConfigService registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2Launch'        'EC2Launch v1 registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\EC2LaunchV2'      'EC2Launch v2 registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent' 'CloudWatch Agent registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\SSM'              'SSM Agent registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\MachineImage'     'MachineImage registry hive'
Check-RegistryKey 'HKLM:\SOFTWARE\Amazon\WarmBoot'         'WarmBoot registry hive'

# -- Filesystem ----------------------------------------------------------------
Write-Host "--- Filesystem ---"
Check-DirectoryExists 'C:\Program Files\Amazon\SSM'                'SSM Agent binaries'
Check-DirectoryExists 'C:\Program Files\Amazon\AmazonCloudWatchAgent' 'CloudWatch Agent binaries'
Check-DirectoryExists 'C:\Program Files\Amazon\EC2ConfigService'   'EC2Config binaries'
Check-DirectoryExists "$env:SystemRoot\system32\config\systemprofile\.aws" 'SYSTEM .aws credentials'
Check-DirectoryExists "$env:SystemRoot\ServiceProfiles\NetworkService\.aws" 'NetworkService .aws credentials'
Check-DirectoryExists 'C:\Program Files\Amazon\cfn-bootstrap' 'CloudFormation Bootstrap directory'
Check-DirectoryExists 'C:\Program Files\Amazon\XenTools'      'XenTools directory'

# -- Environment Variables -----------------------------------------------------
Write-Host "--- Environment Variables ---"
foreach ($v in @(
    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN',
    'AWS_DEFAULT_REGION', 'AWS_REGION', 'AWS_PROFILE',
    'AWS_CONFIG_FILE', 'AWS_ROLE_ARN', 'AWS_WEB_IDENTITY_TOKEN_FILE'
)) {
    Check-MachineEnvVar $v
}

# -- Hosts File ----------------------------------------------------------------
Write-Host "--- Hosts File ---"
Check-HostsEntry '169\.254\.169\.254.*ec2\.internal' 'AWS EC2-internal metadata hostname'
Check-HostsEntry 'instance-data\.ec2\.internal'      'AWS instance-data hostname'

# -- Scheduled Tasks -----------------------------------------------------------
Write-Host "--- Scheduled Tasks ---"
Check-ScheduledTask 'Amazon EC2Launch - Instance Initialization'
Check-ScheduledTask 'AmazonCloudWatchAutoUpdate' '\Amazon\AmazonCloudWatch\'
Scan-AmazonScheduledTasks

# -- Heuristic Scans (unknown artifacts) ---------------------------------------
Write-Host "--- Heuristic Scans ---"
Scan-AllAwsServices
Scan-AmazonRegistrySubkeys
Scan-AllAwsSoftware
Scan-AmazonDirectory

# -- Azure Agent & IMDS --------------------------------------------------------
Write-Host "--- Azure Agent & IMDS ---"
Check-AzureAgent
Check-IMDSReachable

# -----------------------------------------------------------------------------
# Post mode: assert clean state
# -----------------------------------------------------------------------------
$postModeAssertions = [System.Collections.Generic.List[hashtable]]::new()

if ($Mode -in 'Post', 'Both') {
    Write-Host ""
    Write-Host "--- Post-Cleanup Assertions ---"

    # In TestMigration phase, Info-status items are intentionally deferred -- do not count as failures.
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
                Write-Host "          -> $($fi.Recommendation)"
            }
        }
    }

    $postModeAssertions.Add(@{
        AwsComponentsFound = $foundItems.Count
        AzureAgentFailed   = $failItems.Count
        CleanState         = ($foundItems.Count -eq 0 -and $failItems.Count -eq 0)
    }) | Out-Null
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
$counts = @{
    Found    = @($script:Findings | Where-Object Status -eq 'Found').Count
    NotFound = @($script:Findings | Where-Object Status -eq 'NotFound').Count
    Pass     = @($script:Findings | Where-Object Status -eq 'Pass').Count
    Fail     = @($script:Findings | Where-Object Status -eq 'Fail').Count
    Warning  = @($script:Findings | Where-Object Status -eq 'Warning').Count
    Info     = @($script:Findings | Where-Object Status -eq 'Info').Count
}

Write-Host ""
Write-Host "============ Summary ============"
Write-Host "  Found AWS components : $($counts.Found)"
Write-Host "  Clean (not found)    : $($counts.NotFound)"
Write-Host "  Azure checks passed  : $($counts.Pass)"
Write-Host "  Azure checks failed  : $($counts.Fail)"
Write-Host "  Warnings             : $($counts.Warning)"
Write-Host "================================="

# -----------------------------------------------------------------------------
# Write JSON report
# -----------------------------------------------------------------------------
$report = @{
    SchemaVersion    = '1.0'
    Timestamp        = (Get-Date -Format 'o')
    ComputerName     = $env:COMPUTERNAME
    Mode             = $Mode
    Phase            = $Phase
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

Write-Host "Transcript: $TranscriptPath"
Stop-Transcript | Out-Null

return $report
