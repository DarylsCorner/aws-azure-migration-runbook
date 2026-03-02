#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Plants fake AWS in-guest artifacts on a Windows VM so that
    Invoke-AWSCleanup.ps1 and Invoke-MigrationReadiness.ps1 have real targets
    to act on — without needing to install actual AWS software.

.DESCRIPTION
    Creates the same registry keys, services, directories, environment variables,
    hosts entries, and scheduled tasks that a real EC2-migrated VM would have.

    SAFE TO RUN ON ANY WINDOWS MACHINE that is used purely for testing.
    All artifacts are clearly labelled "FAKE" or "MIGRATION-TEST".

    Run BEFORE executing the cleanup or readiness scripts in Layer 2 / Layer 3
    testing. Pair with Teardown-DirtyBox.ps1 to restore the machine.

.PARAMETER IncludeServices
    Create fake Windows services (requires admin, uses cmd.exe as binary).

.PARAMETER IncludeEnvVars
    Set machine-scope AWS environment variables.

.PARAMETER IncludeHostsEntry
    Append AWS EC2-internal hostname entries to the hosts file.

.PARAMETER IncludeScheduledTasks
    Register fake Amazon scheduled tasks.

.PARAMETER IncludeDirectories
    Create empty AWS program-files directories.

.PARAMETER IncludeRegistry
    Create AWS registry hive keys.

.EXAMPLE
    # Plant everything (full dirty-box)
    .\tests\Fixture\Setup-DirtyBox.ps1

.EXAMPLE
    # Plant only registry and environment variables
    .\tests\Fixture\Setup-DirtyBox.ps1 -IncludeServices:$false -IncludeHostsEntry:$false `
        -IncludeScheduledTasks:$false -IncludeDirectories:$false
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [bool]$IncludeServices       = $true,
    [bool]$IncludeEnvVars        = $true,
    [bool]$IncludeHostsEntry     = $true,
    [bool]$IncludeScheduledTasks = $true,
    [bool]$IncludeDirectories    = $true,
    [bool]$IncludeRegistry       = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$script:Created = [System.Collections.Generic.List[string]]::new()

function Write-Step { param([string]$Msg) Write-Host "[SETUP] $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "  [+] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "  [~] SKIP: $Msg" -ForegroundColor Yellow }
function Write-Err  { param([string]$Msg) Write-Host "  [!] ERROR: $Msg" -ForegroundColor Red }

# ─────────────────────────────────────────────────────────────────────────────
# SERVICES
# Fake services using cmd.exe as the binary path; start type Disabled so they
# don't try to start automatically.
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeServices) {
    Write-Step "Creating fake AWS services..."

    $fakeServices = @(
        @{ Name = 'AmazonSSMAgent';        Display = 'Amazon SSM Agent (MIGRATION-TEST)' },
        @{ Name = 'AmazonCloudWatchAgent'; Display = 'Amazon CloudWatch Agent (MIGRATION-TEST)' },
        @{ Name = 'AWSCodeDeployAgent';    Display = 'AWS CodeDeploy Agent (MIGRATION-TEST)' }
    )

    foreach ($svc in $fakeServices) {
        $existing = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Skip "$($svc.Name) already exists (skipping creation)"
            continue
        }
        try {
            New-Service -Name $svc.Name `
                        -BinaryPathName "$env:SystemRoot\System32\cmd.exe" `
                        -DisplayName $svc.Display `
                        -StartupType Disabled `
                        -ErrorAction Stop | Out-Null
            # Manually set status to Running in the registry so the script sees it running
            # (Start-Service on cmd.exe would fail; we fake it via registry StartType only)
            Write-OK "$($svc.Name) created (Disabled)"
            $script:Created.Add("SERVICE:$($svc.Name)")
        } catch {
            Write-Err "Could not create service $($svc.Name): $($_.Exception.Message)"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# REGISTRY HIVES
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeRegistry) {
    Write-Step "Creating fake AWS registry hives..."

    $regKeys = @(
        'HKLM:\SOFTWARE\Amazon\EC2ConfigService',
        'HKLM:\SOFTWARE\Amazon\EC2Launch',
        'HKLM:\SOFTWARE\Amazon\EC2LaunchV2',
        'HKLM:\SOFTWARE\Amazon\AmazonCloudWatchAgent',
        'HKLM:\SOFTWARE\Amazon\SSM'
    )

    foreach ($key in $regKeys) {
        try {
            if (Test-Path $key) {
                Write-Skip "$key already exists"
            } else {
                New-Item -Path $key -Force -ErrorAction Stop | Out-Null
                New-ItemProperty -Path $key -Name 'MigrationTestMarker' `
                    -Value 'FAKE — created by Setup-DirtyBox.ps1' `
                    -PropertyType String -Force | Out-Null
                Write-OK "$key created"
                $script:Created.Add("REGKEY:$key")
            }
        } catch {
            Write-Err "Registry $key : $($_.Exception.Message)"
        }
    }

    # Also plant a fake uninstall entry so Uninstall-ProgramIfPresent finds something
    $uninstallRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\AmazonSSMAgent-MIGRATIONTEST'
    if (-not (Test-Path $uninstallRoot)) {
        try {
            New-Item -Path $uninstallRoot -Force | Out-Null
            $props = @{
                DisplayName     = 'Amazon SSM Agent'
                DisplayVersion  = '3.2.0.0'
                Publisher       = 'Amazon Web Services (MIGRATION-TEST)'
                UninstallString = 'MsiExec.exe /x {AABBCCDD-1111-2222-3333-AABBCCDDEEFF}'
                MigrationTest   = 'true'
            }
            foreach ($kv in $props.GetEnumerator()) {
                New-ItemProperty -Path $uninstallRoot -Name $kv.Key -Value $kv.Value `
                    -PropertyType String -Force | Out-Null
            }
            Write-OK "Fake uninstall entry created for 'Amazon SSM Agent'"
            $script:Created.Add("REGKEY:$uninstallRoot")
        } catch {
            Write-Err "Uninstall entry: $($_.Exception.Message)"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ENVIRONMENT VARIABLES (Machine scope)
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeEnvVars) {
    Write-Step "Setting fake AWS machine-scope environment variables..."

    $fakeVars = @{
        'AWS_DEFAULT_REGION'  = 'us-east-1'
        'AWS_REGION'          = 'us-east-1'
        'AWS_PROFILE'         = 'migration-test-profile'
        'AWS_CONFIG_FILE'     = 'C:\Windows\System32\config\systemprofile\.aws\config'
    }

    foreach ($kv in $fakeVars.GetEnumerator()) {
        $existing = [System.Environment]::GetEnvironmentVariable($kv.Key, 'Machine')
        if ($null -ne $existing) {
            Write-Skip "$($kv.Key) already set — not overwriting"
        } else {
            [System.Environment]::SetEnvironmentVariable($kv.Key, $kv.Value, 'Machine')
            Write-OK "$($kv.Key) = $($kv.Value)"
            $script:Created.Add("ENVVAR:$($kv.Key)")
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# HOSTS FILE
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeHostsEntry) {
    Write-Step "Appending fake AWS hosts entries..."

    $hostsFile   = "$env:windir\System32\drivers\etc\hosts"
    $markerBegin = '# --- MIGRATION-TEST AWS entries (Setup-DirtyBox.ps1) ---'
    $markerEnd   = '# --- end MIGRATION-TEST AWS entries ---'
    $awsEntries  = @(
        '169.254.169.254  instance-data.ec2.internal  # MIGRATION-TEST',
        '169.254.169.254  instance-data              # MIGRATION-TEST'
    )

    $existing = Get-Content $hostsFile -Raw -ErrorAction SilentlyContinue
    if ($existing -match [regex]::Escape($markerBegin)) {
        Write-Skip "AWS hosts entries already present"
    } else {
        try {
            $block = @($markerBegin) + $awsEntries + @($markerEnd, '')
            Add-Content -Path $hostsFile -Value $block -Encoding ASCII -ErrorAction Stop
            Write-OK "AWS entries appended to $hostsFile"
            $script:Created.Add('HOSTS:aws-entries')
        } catch {
            Write-Err "Hosts file: $($_.Exception.Message)"
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SCHEDULED TASKS
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeScheduledTasks) {
    Write-Step "Registering fake Amazon scheduled tasks..."

    # Ensure the required task folder hierarchy exists before registering tasks.
    # Register-ScheduledTask does not auto-create nested folders on Server 2022.
    function Ensure-TaskFolder {
        param([string]$FolderPath)
        if ($FolderPath -eq '\') { return }
        $svc = New-Object -ComObject 'Schedule.Service'
        $svc.Connect()
        $parts = ($FolderPath.Trim('\') -split '\\')
        $parent = $svc.GetFolder('\')
        foreach ($part in $parts) {
            try {
                $parent = $parent.GetFolder($part)
            } catch {
                $parent = $parent.CreateFolder($part)
            }
        }
    }

    $taskAction  = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo MIGRATION-TEST'
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    # Use SYSTEM principal to avoid "No mapping between account names and security IDs"
    # errors when running as SYSTEM via az vm run-command.
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $fakeTasks = @(
        @{ Name = 'Amazon EC2Launch - Instance Initialization'; Path = '\' },
        @{ Name = 'AmazonCloudWatchAutoUpdate';                 Path = '\Amazon\AmazonCloudWatch\' },
        @{ Name = 'Amazon SSM Agent Heartbeat';                 Path = '\Amazon\' }
    )

    foreach ($t in $fakeTasks) {
        # Ensure task folder exists before registering
        try { Ensure-TaskFolder $t.Path } catch { Write-Err "Could not create task folder '$($t.Path)': $($_.Exception.Message)" }

        $existing = Get-ScheduledTask -TaskName $t.Name -TaskPath $t.Path -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Skip "Task '$($t.Path)$($t.Name)' already exists"
        } else {
            try {
                Register-ScheduledTask `
                    -TaskName    $t.Name `
                    -TaskPath    $t.Path `
                    -Action      $taskAction `
                    -Trigger     $taskTrigger `
                    -Principal   $taskPrincipal `
                    -Description 'MIGRATION-TEST — created by Setup-DirtyBox.ps1' `
                    -ErrorAction Stop | Out-Null
                Write-OK "Task '$($t.Path)$($t.Name)' registered"
                $script:Created.Add("TASK:$($t.Path)$($t.Name)")
            } catch {
                Write-Err "Task '$($t.Name)': $($_.Exception.Message)"
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# DIRECTORIES
# ─────────────────────────────────────────────────────────────────────────────
if ($IncludeDirectories) {
    Write-Step "Creating fake AWS program directories..."

    $fakeDirs = @(
        'C:\Program Files\Amazon\SSM',
        'C:\Program Files\Amazon\AmazonCloudWatchAgent',
        'C:\Program Files\Amazon\EC2ConfigService',
        "$env:SystemRoot\system32\config\systemprofile\.aws",
        "$env:SystemRoot\ServiceProfiles\NetworkService\.aws",
        "$env:SystemRoot\ServiceProfiles\LocalService\.aws"
    )

    foreach ($dir in $fakeDirs) {
        if (Test-Path $dir) {
            Write-Skip "$dir already exists"
        } else {
            try {
                New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null
                # Place a marker file so the directory is non-empty (easier to spot)
                Set-Content -Path (Join-Path $dir 'MIGRATION-TEST.txt') `
                    -Value "Created by Setup-DirtyBox.ps1 on $(Get-Date -Format 'u')" `
                    -Encoding UTF8
                Write-OK "$dir created"
                $script:Created.Add("DIR:$dir")
            } catch {
                Write-Err "$dir : $($_.Exception.Message)"
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Manifest — write what was created so Teardown can clean up exactly
# ─────────────────────────────────────────────────────────────────────────────
$manifestPath = Join-Path $PSScriptRoot 'dirtybox-manifest.json'
$script:Created | ConvertTo-Json | Set-Content -Path $manifestPath -Encoding UTF8
Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " DirtyBox setup complete." -ForegroundColor Cyan
Write-Host " $($script:Created.Count) artifact(s) created." -ForegroundColor Cyan
Write-Host " Manifest: $manifestPath" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Run: .\validation\Invoke-MigrationReadiness.ps1 -Mode Pre"
Write-Host "  2. Run: .\windows\Invoke-AWSCleanup.ps1 -DryRun -Phase TestMigration"
Write-Host "  3. Run: .\windows\Invoke-AWSCleanup.ps1 -Phase TestMigration"
Write-Host "  4. Run: .\validation\Invoke-MigrationReadiness.ps1 -Mode Post"
Write-Host "  5. Repeat steps 2-4 with -Phase Cutover"
Write-Host "  6. Run: .\tests\Fixture\Teardown-DirtyBox.ps1  (when done)"
