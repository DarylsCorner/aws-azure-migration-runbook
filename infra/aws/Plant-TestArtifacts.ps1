#Requires -Version 5.1
<#
.SYNOPSIS
    Plants only the AWS artifacts that are missing on the test VMs, based on
    the latest pre-scan report produced by Invoke-PreScan.ps1.

.DESCRIPTION
    Reads the most recent scan-reports/pre-scan-*.json, determines which items
    needed by the cleanup scripts are absent on each VM, then sends targeted
    SSM Run Commands to plant only those items.

    After planting, optionally re-runs Invoke-PreScan.ps1 so you can confirm
    everything the cleanup scripts target is now present.

.PARAMETER Region
    AWS region. Default: value in test-env.json, or us-east-1.

.PARAMETER ScanReportPath
    Explicit path to a pre-scan JSON file.  If omitted, the most recent file
    in infra/aws/scan-reports/ is used.

.PARAMETER NoVerify
    Skip the post-plant re-scan.

.EXAMPLE
    .\Plant-TestArtifacts.ps1

.EXAMPLE
    .\Plant-TestArtifacts.ps1 -NoVerify
#>
[CmdletBinding()]
param(
    [string] $Region         = '',
    [string] $ScanReportPath = '',
    [switch] $NoVerify,
    [switch] $SkipWindows
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Load env + scan report ────────────────────────────────────────────────────

$EnvFile = Join-Path $PSScriptRoot 'test-env.json'
if (-not (Test-Path $EnvFile)) {
    Write-Error "test-env.json not found. Run Deploy-TestEnv.ps1 first."
    exit 1
}
$envData = Get-Content $EnvFile | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Region)) {
    $Region = if ($envData.Region) { $envData.Region } else { 'us-east-1' }
}

$report = $null
if (-not [string]::IsNullOrWhiteSpace($ScanReportPath)) {
    $report = Get-Content $ScanReportPath -ErrorAction SilentlyContinue | ConvertFrom-Json
} else {
    # Try to find the latest JSON report (legacy format).  If only .txt reports
    # exist (new format), that's fine -- we just plant everything unconditionally.
    $reportDir = Join-Path $PSScriptRoot 'scan-reports'
    $latest    = Get-ChildItem $reportDir -Filter 'pre-scan-*.json' -ErrorAction SilentlyContinue |
                     Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) {
        $ScanReportPath = $latest.FullName
        $report = Get-Content $ScanReportPath | ConvertFrom-Json
        Write-Host "  Using scan report: $ScanReportPath"
    } else {
        $txtReport = Get-ChildItem $reportDir -Filter 'prescan-*-Windows.txt' -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($txtReport) {
            Write-Host "  Scan report found (txt): $($txtReport.FullName)"
            Write-Host "  (Planting all artifacts unconditionally -- txt reports are not parsed)" -ForegroundColor DarkGray
        } else {
            Write-Warning "No scan reports found in $reportDir -- planting all artifacts unconditionally."
        }
    }
}

Write-Host "`n=== Plant-TestArtifacts ===" -ForegroundColor Cyan
Write-Host "  Region      : $Region"
$winId  = $envData.WindowsInstanceId
$lnxId  = $envData.LinuxInstanceId

# ── SSM helper ────────────────────────────────────────────────────────────────

function Send-SsmCommand {
    param(
        [string] $InstanceId,
        [string] $DocumentName,
        [string] $Script,
        [string] $Label
    )
    Write-Host "`n  Planting on $Label ($InstanceId)..." -ForegroundColor Yellow
    $tmpFile = [System.IO.Path]::GetTempFileName() + '.json'
    # Split into per-line array (ConvertTo-Json on a multiline string produces \r\n literals
    # that SSM passes as a single mangled line).  Use BOM-free UTF-8 so AWS CLI Python parses it.
    $scriptLines = @($Script -split "`r?`n")
    $params = @{ commands = $scriptLines }
    $json   = $params | ConvertTo-Json -Depth 5 -Compress
    [System.IO.File]::WriteAllText($tmpFile, $json, [System.Text.UTF8Encoding]::new($false))

    $cmd = aws ssm send-command `
        --instance-ids $InstanceId `
        --document-name $DocumentName `
        --parameters "file://$tmpFile" `
        --region $Region `
        --output json 2>&1 | ConvertFrom-Json
    Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue

    if ($LASTEXITCODE -ne 0) { Write-Warning "send-command failed for $Label"; return }

    $cmdId = $cmd.Command.CommandId
    Write-Host "    Command ID: $cmdId  polling..." -ForegroundColor Gray -NoNewline
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 10
        # Use --query to avoid deserializing potentially large JSON blobs
        $status = aws ssm get-command-invocation `
                      --command-id $cmdId --instance-id $InstanceId `
                      --region $Region --query 'Status' --output text 2>$null
        if ($status -in @('Success','Failed','TimedOut','Cancelled')) {
            $color = if ($status -eq 'Success') { 'Green' } else { 'Red' }
            Write-Host " $status" -ForegroundColor $color
            if ($status -ne 'Success') {
                $errOut = aws ssm get-command-invocation `
                              --command-id $cmdId --instance-id $InstanceId `
                              --region $Region --query 'StandardErrorContent' --output text 2>$null
                if ($errOut) { Write-Warning $errOut }
            }
            $stdOut = aws ssm get-command-invocation `
                          --command-id $cmdId --instance-id $InstanceId `
                          --region $Region --query 'StandardOutputContent' --output text 2>$null
            if ($stdOut) { Write-Host $stdOut }
            return
        }
        Write-Host '.' -NoNewline
    }
    Write-Warning "Timed out waiting for command result."
}

# ── Build Windows plant script ────────────────────────────────────────────────

function Build-WindowsPlantScript {
    param($ScanData)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('$planted = @()')

    # ── Registry hives ──────────────────────────────────────────────────────

    $regTargets = @(
        @{ Key = 'HKLM:\SOFTWARE\Amazon\EC2ConfigService'; Props = @{ Version = '4.9.4222' } },
        @{ Key = 'HKLM:\SOFTWARE\Amazon\EC2Launch';        Props = @{ Version = '1.3.2003610' } },
        @{ Key = 'HKLM:\SOFTWARE\Amazon\EC2Launch\v2';     Props = @{} }
    )
    foreach ($reg in $regTargets) {
        $present = $false
        if ($ScanData -and $ScanData.RegistryKeys) {
            $val = $ScanData.RegistryKeys.PSObject.Properties |
                   Where-Object { $_.Name -eq $reg.Key } |
                   Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
            $present = ($val -eq 'True')
        }
        if (-not $present) {
            $lines.Add("New-Item -Path '$($reg.Key)' -Force | Out-Null")
            foreach ($p in $reg.Props.GetEnumerator()) {
                $lines.Add("Set-ItemProperty -Path '$($reg.Key)' -Name '$($p.Key)' -Value '$($p.Value)' -Type String")
            }
            $lines.Add("`$planted += 'Registry: $($reg.Key)'")
        }
    }

    # ── Hosts file ───────────────────────────────────────────────────────────

    $hostsEntries = @(
        "169.254.169.254  ec2.internal  # AWS EC2 internal metadata hostname",
        "169.254.169.254  instance-data.ec2.internal  # AWS EC2 metadata"
    )
    $existingHosts = if ($ScanData -and $ScanData.HostsAwsEntries) { $ScanData.HostsAwsEntries } else { @() }
    foreach ($entry in $hostsEntries) {
        $needle = ($entry -split '\s+')[1]
        if ($existingHosts -notmatch [regex]::Escape($needle)) {
            $lines.Add("`$hostsFile = `"`$env:SystemRoot\System32\drivers\etc\hosts`"")
            $lines.Add("if ((Get-Content `$hostsFile -Raw) -notmatch '$needle') { Add-Content `$hostsFile `"`n$entry`" }")
            $lines.Add("`$planted += 'Hosts: $needle'")
        }
    }

    # ── AWS credential files ──────────────────────────────────────────────────

    $credTargets = @(
        'C:\Windows\System32\config\systemprofile\.aws',
        'C:\Windows\ServiceProfiles\NetworkService\.aws',
        'C:\Windows\ServiceProfiles\LocalService\.aws',
        'C:\Users\Administrator\.aws'
    )
    $credContent = @'
[default]
# FAKE-CREDENTIAL - planted by Plant-TestArtifacts.ps1 for migration runbook testing
aws_access_key_id     = AKIAIOSFODNN7FAKETEST
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKETEST
region = us-east-1
'@
    foreach ($dir in $credTargets) {
        $credFile = "$dir\credentials"
        $present  = $false
        if ($ScanData -and $ScanData.CredentialFiles) {
            $val = $ScanData.CredentialFiles.PSObject.Properties |
                   Where-Object { $_.Name -eq $credFile } |
                   Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
            $present = ($val -eq 'True')
        }
        if (-not $present) {
            $lines.Add("New-Item -ItemType Directory -Path '$dir' -Force | Out-Null")
            $lines.Add("@'`n$credContent`n'@ | Set-Content '$credFile'")
            $lines.Add("`$planted += 'Credential: $credFile'")
        }
    }

    # ── Scheduled tasks ───────────────────────────────────────────────────────

    $existingTasks = if ($ScanData -and $ScanData.ScheduledTasks) {
        $ScanData.ScheduledTasks.PSObject.Properties.Name
    } else { @() }

    $taskTargets = @(
        @{ Path = '\';                       Name = 'Amazon EC2Launch - Instance Initialization';   Exe = 'C:\Windows\System32\cmd.exe' }
        @{ Path = '\';                       Name = 'Amazon EC2Launch - TemporaryDesktopBackground'; Exe = 'C:\Windows\System32\cmd.exe' }
        @{ Path = '\Amazon\AmazonCloudWatch\'; Name = 'AmazonCloudWatchAutoUpdate';                 Exe = 'C:\Windows\System32\cmd.exe' }
        @{ Path = '\Amazon\';               Name = 'Amazon SSM Agent Heartbeat';                    Exe = 'C:\Windows\System32\cmd.exe' }
        @{ Path = '\Amazon\';               Name = 'AWSCodeDeployAgent';                            Exe = 'C:\Windows\System32\cmd.exe' }
    )
    foreach ($t in $taskTargets) {
        $fullName = "$($t.Path)$($t.Name)"
        if ($existingTasks -notcontains $fullName) {
            $lines.Add(@"
try {
    `$a = New-ScheduledTaskAction -Execute '$($t.Exe)'
    `$tr = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName '$($t.Name)' -TaskPath '$($t.Path)' ``
        -Action `$a -Trigger `$tr -RunLevel Highest -Force -ErrorAction Stop | Out-Null
    `$planted += 'ScheduledTask: $fullName'
} catch { Write-Warning "Could not create task $fullName`: `$_" }
"@)
        }
    }

    # ── App workload: IIS + non-AWS app config ────────────────────────────────
    # IIS installs in ~30s on WS2022 (pre-staged).  The key under HKLM:\SOFTWARE\MyApp
    # is intentionally non-AWS so we can assert it SURVIVES the cleanup run.

    $lines.Add('if ((Get-WindowsFeature -Name Web-Server).InstallState -ne "Installed") {')
    $lines.Add('    Install-WindowsFeature -Name Web-Server | Out-Null')
    $lines.Add('    $planted += "Workload: IIS installed"')
    $lines.Add('}')
    $lines.Add('if (-not (Test-Path "HKLM:\SOFTWARE\MyApp\Config")) {')
    $lines.Add('    New-Item -Path "HKLM:\SOFTWARE\MyApp\Config" -Force | Out-Null')
    $lines.Add('    Set-ItemProperty -Path "HKLM:\SOFTWARE\MyApp\Config" -Name AppName     -Value MigTestApp                -Type String')
    $lines.Add('    Set-ItemProperty -Path "HKLM:\SOFTWARE\MyApp\Config" -Name AppVersion  -Value 1.0.0                     -Type String')
    $lines.Add('    Set-ItemProperty -Path "HKLM:\SOFTWARE\MyApp\Config" -Name AppEndpoint -Value http://myapp.internal/api  -Type String')
    $lines.Add('    $planted += "Workload: AppConfig registry key"')
    $lines.Add('}')
    $lines.Add('$healthzDir = "C:\inetpub\wwwroot\healthz"')
    $lines.Add('if (-not (Test-Path $healthzDir)) {')
    $lines.Add('    New-Item -ItemType Directory -Path $healthzDir -Force | Out-Null')
    $lines.Add('    Set-Content "$healthzDir\index.html" "{""status"":""ok"",""app"":""MigTestApp"",""check"":""pre-cleanup""}"')
    $lines.Add('    $planted += "Workload: healthz page"')
    $lines.Add('}')
    $lines.Add('Set-Service  W3SVC -StartupType Automatic -ErrorAction SilentlyContinue')
    $lines.Add('Start-Service W3SVC                       -ErrorAction SilentlyContinue')

    # ── Summary ───────────────────────────────────────────────────────────────

    $lines.Add('if ($planted.Count -eq 0) { Write-Host "WINDOWS: nothing to plant -- all artifacts already present." }')
    $lines.Add('else { $planted | ForEach-Object { Write-Host "  PLANTED: $_" } }')

    return $lines -join "`n"
}

# ── Build Linux plant script ──────────────────────────────────────────────────

function Build-LinuxPlantScript {
    param($ScanData)

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add('#!/bin/bash')
    $parts.Add('planted=()')

    # ── AWS credential files ──────────────────────────────────────────────────

    $credDirs = @('/root/.aws', '/home/ec2-user/.aws', '/home/ssm-user/.aws')
    foreach ($dir in $credDirs) {
        $credFile = "$dir/credentials"
        $present  = $false
        if ($ScanData -and $ScanData.CredentialFiles) {
            $val = $ScanData.CredentialFiles.PSObject.Properties |
                   Where-Object { $_.Name -eq $credFile } |
                   Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
            $present = ($val -eq $true -or $val -eq 'True')
        }
        if (-not $present) {
            $parentDir = ($dir -replace '/[^/]+$', '')
            $parts.Add("if [[ -d '$parentDir' ]]; then")
            $parts.Add("  mkdir -p '$dir'")
            $parts.Add("  cat > '$credFile' <<'CREDS'")
            $parts.Add("[default]")
            $parts.Add("# FAKE-CREDENTIAL - planted by Plant-TestArtifacts.ps1 for migration runbook testing")
            $parts.Add("aws_access_key_id     = AKIAIOSFODNN7FAKETEST")
            $parts.Add("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKETEST")
            $parts.Add("CREDS")
            $parts.Add("  planted+=('Credential: $credFile')")
            $parts.Add("fi")
        }
    }

    # ── cloud.cfg datasource_list ─────────────────────────────────────────────

    $dsPresent = $ScanData -and $ScanData.CloudInitDatasource -and
                 $ScanData.CloudInitDatasource -ne 'NOT_FOUND'
    if (-not $dsPresent) {
        $parts.Add("if [[ -f /etc/cloud/cloud.cfg ]] && ! grep -qE '^[[:space:]]*datasource_list:' /etc/cloud/cloud.cfg; then")
        $parts.Add("  echo '' >> /etc/cloud/cloud.cfg")
        $parts.Add("  echo 'datasource_list: [ Ec2, None ]' >> /etc/cloud/cloud.cfg")
        $parts.Add("  planted+=('cloud.cfg: datasource_list')")
        $parts.Add("fi")
    }

    # ── /etc/hosts EC2 entries ────────────────────────────────────────────────

    $existingHosts = if ($ScanData -and $ScanData.HostsAwsEntries) { $ScanData.HostsAwsEntries } else { @() }
    if ($existingHosts -notmatch 'instance-data\.ec2\.internal') {
        $parts.Add("grep -q 'instance-data.ec2.internal' /etc/hosts || {")
        $parts.Add("  echo '169.254.169.254  instance-data.ec2.internal  # AWS EC2 metadata' >> /etc/hosts")
        $parts.Add("  planted+=('Hosts: instance-data.ec2.internal')")
        $parts.Add("}")
    }

    # ── Agent directories ────────────────────────────────────────────────────

    $dirTargets = @(
        '/etc/amazon/ssm',
        '/var/lib/amazon/ssm',
        '/var/log/amazon/ssm',
        '/etc/amazon/cloudwatch',
        '/etc/codedeploy-agent/conf',
        '/opt/codedeploy-agent/deployment-root',
        '/etc/aws-kinesis'
    )
    foreach ($d in $dirTargets) {
        $present = $false
        if ($ScanData -and $ScanData.Directories) {
            $val = $ScanData.Directories.PSObject.Properties |
                   Where-Object { $_.Name -eq $d } |
                   Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue
            $present = ($val -eq $true -or $val -eq 'True')
        }
        if (-not $present) {
            $parts.Add("mkdir -p '$d' && planted+=('Dir: $d')")
        }
    }

    # ── App workload: nginx + non-AWS app config ──────────────────────────────
    # /etc/myapp/config.env is intentionally non-AWS so we can assert it
    # SURVIVES the cleanup run while AWS credentials/dirs are removed.

    $parts.Add('if ! command -v nginx >/dev/null 2>&1; then')
    $parts.Add('  dnf install -y nginx >/dev/null 2>&1 || yum install -y nginx >/dev/null 2>&1')
    $parts.Add('  planted+=("Workload: nginx installed")')
    $parts.Add('fi')
    $parts.Add('if [[ ! -f /etc/myapp/config.env ]]; then')
    $parts.Add('  mkdir -p /etc/myapp')
    $parts.Add('  printf "APP_NAME=MigTestApp\nAPP_VERSION=1.0.0\nAPP_ENDPOINT=http://myapp.internal/api\n" > /etc/myapp/config.env')
    $parts.Add('  planted+=("Workload: /etc/myapp/config.env")')
    $parts.Add('fi')
    $parts.Add('mkdir -p /usr/share/nginx/html/healthz')
    $parts.Add('[[ -f /usr/share/nginx/html/healthz/index.html ]] || {')
    $parts.Add('  echo "{\"status\":\"ok\",\"app\":\"MigTestApp\",\"check\":\"pre-cleanup\"}" > /usr/share/nginx/html/healthz/index.html')
    $parts.Add('  planted+=("Workload: healthz page")')
    $parts.Add('}')
    $parts.Add('systemctl enable nginx >/dev/null 2>&1')
    $parts.Add('systemctl start  nginx >/dev/null 2>&1')

    # ── Summary ───────────────────────────────────────────────────────────────

    $parts.Add('if [[ ${#planted[@]} -eq 0 ]]; then')
    $parts.Add('  echo "LINUX: nothing to plant -- all artifacts already present."')
    $parts.Add('else')
    $parts.Add('  for item in "${planted[@]}"; do echo "  PLANTED: $item"; done')
    $parts.Add('fi')

    return $parts -join "`n"
}

# ── Execute ───────────────────────────────────────────────────────────────────

Write-Host "`nBuilding Windows plant script from scan data..." -ForegroundColor Gray
$winScanData = if ($report) { $report.Windows } else { $null }
$winScript = Build-WindowsPlantScript -ScanData $winScanData

Write-Host "Building Linux plant script from scan data..." -ForegroundColor Gray
$lnxScanData = if ($report) { $report.Linux } else { $null }
$lnxScript = Build-LinuxPlantScript -ScanData $lnxScanData

# Show what will be planted
Write-Host "`n--- Windows script preview ---" -ForegroundColor DarkGray
$winScript -split "`n" | Where-Object { $_ -match 'planted \+=' } |
    ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }

Write-Host "`n--- Linux script preview ---" -ForegroundColor DarkGray
$lnxScript -split "`n" | Where-Object { $_ -match "planted\+=" } |
    ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }

$confirm = Read-Host "`nSend plant commands to both VMs? (yes/no)"
if ($confirm -notmatch '^yes$') { Write-Host "Aborted."; exit 0 }

if (-not $SkipWindows) {
    Send-SsmCommand -InstanceId $winId -DocumentName 'AWS-RunPowerShellScript' `
                    -Script $winScript -Label 'Windows'
} else {
    Write-Host "  Skipping Windows (--SkipWindows specified)." -ForegroundColor DarkGray
}
Send-SsmCommand -InstanceId $lnxId -DocumentName 'AWS-RunShellScript' `
                -Script $lnxScript -Label 'Linux'

Write-Host "`n=== Planting complete ===" -ForegroundColor Green

# ── Verify ────────────────────────────────────────────────────────────────────

if (-not $NoVerify) {
    Write-Host "`nRunning post-plant verification scan..." -ForegroundColor Cyan
    $preScan = Join-Path $PSScriptRoot 'Invoke-PreScan.ps1'
    if (Test-Path $preScan) {
        & $preScan -Region $Region
    } else {
        Write-Host "  (Invoke-PreScan.ps1 not found -- skipping verification)"
    }
}
