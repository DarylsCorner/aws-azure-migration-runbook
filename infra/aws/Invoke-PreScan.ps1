#Requires -Version 5.1
<#
.SYNOPSIS
    Scans both AWS test VMs for AWS components and produces a pre-migration
    inventory report.

.DESCRIPTION
    Runs SSM Run Commands against the Windows and Linux EC2 instances defined
    in infra/aws/test-env.json. Inventories everything the cleanup scripts
    target:

    Windows:
      - AWS services (SSM, CloudWatch, EC2Config, EC2Launch, Kinesis, CodeDeploy)
      - AWS executables on PATH and in known install dirs
      - Registry hives (Amazon/EC2ConfigService, EC2Launch, EC2Launch/v2)
      - Scheduled tasks under \Amazon\
      - .aws/credentials files under all profiles + service accounts
      - Hosts file entries matching EC2 patterns
      - AWS CloudFormation cfn-init/cfn-signal binaries
      - User profiles with .aws directories

    Linux:
      - systemd services (amazon-ssm-agent, amazon-cloudwatch-agent, codedeploy)
      - /etc/amazon/ and /var/lib/amazon/ and /opt/codedeploy-agent/
      - ~/.aws/credentials for root and home users
      - cloud-init datasource_list in /etc/cloud/cloud.cfg
      - /etc/hosts EC2 entries
      - /etc/aws-kinesis/
      - aws CLI version
      - cloud-init status

.PARAMETER EnvFile
    Path to test-env.json produced by Deploy-TestEnv.ps1.
    Default: same directory as this script.

.PARAMETER Region
    AWS region. Default: value in test-env.json, or us-east-1.

.PARAMETER OutputDir
    Where to write the JSON + text reports.
    Default: infra/aws/scan-reports/

.EXAMPLE
    .\Invoke-PreScan.ps1

.EXAMPLE
    .\Invoke-PreScan.ps1 -OutputDir C:\temp\scan
#>
[CmdletBinding()]
param(
    [string] $EnvFile   = '',
    [string] $Region    = '',
    [string] $OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -- Resolve paths --

if ([string]::IsNullOrWhiteSpace($EnvFile)) {
    $EnvFile = Join-Path $PSScriptRoot 'test-env.json'
}
if (-not (Test-Path $EnvFile)) {
    Write-Error "test-env.json not found at '$EnvFile'. Run Deploy-TestEnv.ps1 first."
    exit 1
}

$env = Get-Content $EnvFile | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($Region)) { $Region = if ($env.Region) { $env.Region } else { 'us-east-1' } }
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $PSScriptRoot 'scan-reports'
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$windowsId = $env.WindowsInstanceId
$linuxId   = $env.LinuxInstanceId
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'

Write-Host "`n=== Pre-Migration AWS Component Scan ===" -ForegroundColor Cyan
Write-Host "  Windows instance : $windowsId"
Write-Host "  Linux instance   : $linuxId"
Write-Host "  Region           : $Region"
Write-Host "  Output           : $OutputDir`n"

# -- Helper: wait for SSM instance to be online --

function Wait-SsmOnline {
    param([string]$InstanceId, [string]$Region, [int]$TimeoutSec = 300)
    $start = [datetime]::UtcNow
    Write-Host "  Waiting for SSM agent on $InstanceId..." -NoNewline
    while ($true) {
        $info = aws ssm describe-instance-information `
            --filters "Key=InstanceIds,Values=$InstanceId" `
            --region $Region | ConvertFrom-Json
        if ($info.InstanceInformationList.Count -gt 0 -and
            $info.InstanceInformationList[0].PingStatus -eq 'Online') {
            Write-Host " Online" -ForegroundColor Green
            return $true
        }
        if (([datetime]::UtcNow - $start).TotalSeconds -gt $TimeoutSec) {
            Write-Host " TIMED OUT" -ForegroundColor Red
            return $false
        }
        Write-Host "." -NoNewline
        Start-Sleep 10
    }
}

# -- Helper: run SSM command and return stdout --

function Invoke-SsmCommand {
    param(
        [string]   $InstanceId,
        [string]   $Region,
        [string]   $DocumentName,   # AWS-RunPowerShellScript or AWS-RunShellScript
        [string[]] $Commands,
        [int]      $TimeoutSec = 120
    )

    # Split multiline scripts into individual lines so SSM executes them
    # correctly (ConvertTo-Json of a single multiline string produces literal
    # \r\n escape sequences which SSM does not expand on the remote host).
    $lines = $Commands | ForEach-Object { $_ -split "`r?`n" }
    $lines = $lines | Where-Object { $null -ne $_ }   # drop nulls
    $cmdJson = $lines | ConvertTo-Json -Compress

    # Write the parameters to a temp file to avoid shell quoting / length issues
    $paramFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($paramFile, "{`"commands`":$cmdJson}", [System.Text.UTF8Encoding]::new($false))

    $sendResult = aws ssm send-command `
        --instance-ids  $InstanceId `
        --document-name $DocumentName `
        --parameters    "file://$paramFile" `
        --region        $Region `
        --output json | ConvertFrom-Json

    Remove-Item $paramFile -Force -ErrorAction SilentlyContinue

    $commandId = $sendResult.Command.CommandId

    # Poll for completion
    $start = [datetime]::UtcNow
    while ($true) {
        Start-Sleep 5
        $inv = aws ssm get-command-invocation `
            --command-id  $commandId `
            --instance-id $InstanceId `
            --region      $Region | ConvertFrom-Json

        if ($inv.Status -in @('Success','Failed','Cancelled','TimedOut')) {
            return @{
                Status   = $inv.Status
                Stdout   = $inv.StandardOutputContent
                Stderr   = $inv.StandardErrorContent
                ExitCode = $inv.ResponseCode
            }
        }
        if (([datetime]::UtcNow - $start).TotalSeconds -gt $TimeoutSec) {
            return @{ Status = 'Timeout'; Stdout = ''; Stderr = 'SSM polling timed out'; ExitCode = -1 }
        }
    }
}

# -- Wait for both agents --

$winOnline = Wait-SsmOnline -InstanceId $windowsId -Region $Region -TimeoutSec 600
$lnxOnline = Wait-SsmOnline -InstanceId $linuxId   -Region $Region -TimeoutSec 600

if (-not $winOnline -or -not $lnxOnline) {
    Write-Warning "One or both instances did not come online in time. Proceeding with available instances."
}

# -- Windows scan script --

$windowsScan = @'
$out = [System.Collections.ArrayList]::new()
function Add-Section { param($title) $out.Add("`n### $title ###") | Out-Null }
function Add-Line    { param($line)  $out.Add($line)              | Out-Null }

# -- Services --
Add-Section "SERVICES (AWS)"
$awsSvcNames = @('AmazonSSMAgent','AmazonCloudWatchAgent','EC2Config','EC2Launch',
                 'Amazon EC2Launch','KinesisAgent','AWSCodeDeployAgent')
foreach ($name in $awsSvcNames) {
    $s = Get-Service -Name $name -ErrorAction SilentlyContinue
    if ($s) { Add-Line "  FOUND    $($s.Name) - Status=$($s.Status) StartType=$($s.StartType)" }
    else     { Add-Line "  missing  $name" }
}

# Any other Amazon/AWS services not in the expected list
$others = Get-Service | Where-Object { $_.Name -match '(?i)amazon|ssmagent|ec2|awscode' -and $_.Name -notin $awsSvcNames }
foreach ($s in $others) { Add-Line "  EXTRA    $($s.Name) - $($s.DisplayName)" }

# -- AWS executables --
Add-Section "EXECUTABLES"
$exePaths = @(
    'C:\Program Files\Amazon\SSM\amazon-ssm-agent.exe',
    'C:\Program Files\Amazon\AmazonCloudWatchAgent\amazon-cloudwatch-agent.exe',
    'C:\Program Files\Amazon\EC2Launch\EC2Launch.exe',
    'C:\Program Files\Amazon\EC2ConfigService\EC2Config.exe',
    'C:\ProgramData\Amazon\EC2Launch\bin\EC2Launch.exe',
    'C:\Program Files\Amazon\AWSCLIV2\aws.exe',
    'C:\Program Files\Amazon\AWSSAM\samcli.exe',
    'C:\cfn\bin\cfn-init.exe',
    'C:\Program Files\Amazon\cfn-bootstrap\cfn-init.exe'
)
foreach ($p in $exePaths) {
    if (Test-Path $p) { Add-Line "  FOUND    $p" } else { Add-Line "  missing  $p" }
}
# aws.exe on PATH?
$awsCli = Get-Command aws -ErrorAction SilentlyContinue
Add-Line "  aws CLI on PATH: $(if ($awsCli) { $awsCli.Source } else { 'NOT FOUND' })"

# -- Registry hives --
Add-Section "REGISTRY"
$regPaths = @(
    'HKLM:\SOFTWARE\Amazon\EC2ConfigService',
    'HKLM:\SOFTWARE\Amazon\EC2Launch',
    'HKLM:\SOFTWARE\Amazon\EC2Launch\v2',
    'HKLM:\SOFTWARE\Amazon\AmazonSSMAgent',
    'HKLM:\SOFTWARE\Amazon\AmazonCloudWatch',
    'HKLM:\SOFTWARE\Amazon',
    'HKLM:\SYSTEM\CurrentControlSet\Services\AmazonSSMAgent',
    'HKLM:\SYSTEM\CurrentControlSet\Services\AmazonCloudWatchAgent'
)
foreach ($p in $regPaths) {
    if (Test-Path $p) {
        $keys = (Get-ItemProperty $p -ErrorAction SilentlyContinue).PSObject.Properties |
                Where-Object { $_.Name -notmatch '^PS' } |
                ForEach-Object { "$($_.Name)=$($_.Value)" }
        Add-Line "  FOUND    $p  [$($keys -join ', ')]"
    } else {
        Add-Line "  missing  $p"
    }
}

# -- Scheduled tasks --
Add-Section "SCHEDULED TASKS (Amazon)"
$tasks = Get-ScheduledTask -ErrorAction SilentlyContinue |
         Where-Object { $_.TaskPath -match '\\Amazon\\' -or $_.TaskName -match '(?i)amazon|ec2|ssm|cloudwatch' }
if ($tasks) {
    foreach ($t in $tasks) { Add-Line "  FOUND    $($t.TaskPath)$($t.TaskName) - State=$($t.State)" }
} else { Add-Line "  none found" }

# -- .aws credentials --
Add-Section "AWS CREDENTIALS FILES"
$searchRoots = @('C:\Users', 'C:\Windows\System32\config\systemprofile',
                 'C:\Windows\ServiceProfiles\NetworkService',
                 'C:\Windows\ServiceProfiles\LocalService')
foreach ($root in $searchRoots) {
    if (Test-Path $root) {
        Get-ChildItem -Path $root -Filter 'credentials' -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -match '\.aws' } |
        ForEach-Object { Add-Line "  FOUND    $($_.FullName)" }
    }
}

# -- Hosts file entries --
Add-Section "HOSTS FILE (EC2 entries)"
$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
Get-Content $hostsFile -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '169\.254\.169\.254|ec2\.internal|instance-data' } |
    ForEach-Object { Add-Line "  $($_.Trim())" }

# -- Program directories --
Add-Section "PROGRAM DIRECTORIES"
$dirs = @(
    'C:\Program Files\Amazon',
    'C:\ProgramData\Amazon',
    'C:\cfn',
    'C:\ec2',
    'C:\Program Files\Amazon\AWSCLIV2'
)
foreach ($d in $dirs) {
    if (Test-Path $d) {
        $children = (Get-ChildItem $d -ErrorAction SilentlyContinue | Select-Object -First 10 | ForEach-Object { $_.Name }) -join ', '
        Add-Line "  FOUND    $d  [$children]"
    } else { Add-Line "  missing  $d" }
}

# -- Environment variables --
Add-Section "ENVIRONMENT VARIABLES (AWS)"
[System.Environment]::GetEnvironmentVariables('Machine').GetEnumerator() |
    Where-Object { $_.Key -match '(?i)^AWS_|^EC2_|^AMAZON_' } |
    ForEach-Object { Add-Line "  $($_.Key) = $($_.Value)" }

$out -join "`n"
'@

# -- Linux scan script --

$linuxScan = @'
#!/bin/bash
echo ""
echo "### SERVICES (AWS) ###"
for svc in amazon-ssm-agent amazon-cloudwatch-agent codedeploy-agent aws-kinesis-agent; do
    if systemctl is-active "$svc" &>/dev/null; then
        state=$(systemctl is-active "$svc")
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo unknown)
        echo "  FOUND    $svc - active=$state enabled=$enabled"
    elif systemctl list-units --all "$svc.service" 2>/dev/null | grep -q "$svc"; then
        state=$(systemctl is-active "$svc" 2>/dev/null || echo inactive)
        enabled=$(systemctl is-enabled "$svc" 2>/dev/null || echo disabled)
        echo "  FOUND    $svc - active=$state enabled=$enabled"
    else
        echo "  missing  $svc"
    fi
done

echo ""
echo "### AWS CLI ###"
if command -v aws &>/dev/null; then
    echo "  FOUND    $(aws --version 2>&1)"
else
    echo "  missing  aws"
fi

echo ""
echo "### EXECUTABLES ###"
for bin in /usr/bin/aws /usr/local/bin/aws /usr/local/aws-cli/v2/current/bin/aws \
           /usr/bin/amazon-ssm-agent /usr/sbin/amazon-ssm-agent \
           /usr/bin/amazon-cloudwatch-agent /opt/aws/bin/cfn-init; do
    if [[ -f "$bin" ]]; then echo "  FOUND    $bin"
    else echo "  missing  $bin"; fi
done

echo ""
echo "### DIRECTORIES ###"
for dir in /etc/amazon /etc/amazon/ssm /etc/amazon/cloudwatch \
           /var/lib/amazon /var/lib/amazon/ssm /var/log/amazon/ssm \
           /opt/codedeploy-agent /etc/codedeploy-agent \
           /opt/aws /etc/aws-kinesis; do
    if [[ -d "$dir" ]]; then
        contents=$(ls -1 "$dir" 2>/dev/null | head -5 | tr '\n' ' ')
        echo "  FOUND    $dir  [$contents]"
    else
        echo "  missing  $dir"
    fi
done

echo ""
echo "### AWS CREDENTIALS FILES ###"
for home in /root /home/*; do
    cred="$home/.aws/credentials"
    if [[ -f "$cred" ]]; then
        echo "  FOUND    $cred"
        head -4 "$cred" 2>/dev/null | sed 's/aws_secret_access_key.*/aws_secret_access_key = [REDACTED]/'
    else
        echo "  missing  $cred"
    fi
done

echo ""
echo "### CLOUD-INIT ###"
if [[ -f /etc/cloud/cloud.cfg ]]; then
    echo "  cloud.cfg exists"
    grep -E 'datasource_list|datasource' /etc/cloud/cloud.cfg 2>/dev/null || echo "  no datasource_list found"
    echo "  cloud-init status: $(cloud-init status 2>/dev/null || echo n/a)"
else
    echo "  missing  /etc/cloud/cloud.cfg"
fi

echo ""
echo "### HOSTS FILE (EC2 entries) ###"
grep -E '169\.254\.169\.254|ec2\.internal|instance-data' /etc/hosts 2>/dev/null || echo "  none found"

echo ""
echo "### ENVIRONMENT VARIABLES (AWS) ###"
env | grep -E '^AWS_|^EC2_|^AMAZON_' 2>/dev/null || echo "  none"

echo ""
echo "### PACKAGE MANAGER (installed AWS packages) ###"
if command -v rpm &>/dev/null; then
    rpm -qa 2>/dev/null | grep -iE 'amazon|ec2|ssm|cloudwatch|codedeploy|kinesis' || echo "  none via rpm"
elif command -v dpkg &>/dev/null; then
    dpkg -l 2>/dev/null | grep -iE 'amazon|ec2|ssm|cloudwatch|codedeploy' | awk '{print "  "$2" "$3}' || echo "  none via dpkg"
fi
'@

# -- Run scans --

$results = @{}

if ($winOnline) {
    Write-Host "Running Windows scan..." -ForegroundColor Cyan
    $winResult = Invoke-SsmCommand -InstanceId $windowsId -Region $Region `
                     -DocumentName 'AWS-RunPowerShellScript' `
                     -Commands @($windowsScan) -TimeoutSec 180
    $results['Windows'] = $winResult
    Write-Host "  Status: $($winResult.Status)"
}

if ($lnxOnline) {
    Write-Host "Running Linux scan..." -ForegroundColor Cyan
    $lnxResult = Invoke-SsmCommand -InstanceId $linuxId -Region $Region `
                     -DocumentName 'AWS-RunShellScript' `
                     -Commands @($linuxScan) -TimeoutSec 180
    $results['Linux'] = $lnxResult
    Write-Host "  Status: $($lnxResult.Status)"
}

# -- Write reports --

$reportBase = Join-Path $OutputDir "prescan-$timestamp"

foreach ($os in $results.Keys) {
    $r = $results[$os]

    # Text report
    $txtFile = "$reportBase-$os.txt"
    @"
=== $os Pre-Migration AWS Component Scan ===
Timestamp : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') UTC
Instance  : $(if ($os -eq 'Windows') { $windowsId } else { $linuxId })
Region    : $Region
SSM Status: $($r.Status)

$($r.Stdout)

--- STDERR ---
$($r.Stderr)
"@ | Set-Content $txtFile
    Write-Host "`nReport written: $txtFile" -ForegroundColor Green
}

# -- Print to console --

foreach ($os in $results.Keys) {
    Write-Host "`n$('--' * 70)" -ForegroundColor DarkGray
    Write-Host "  $os" -ForegroundColor Yellow
    Write-Host "$('--' * 70)" -ForegroundColor DarkGray
    $results[$os].Stdout -split "`n" | ForEach-Object {
        $color = if ($_ -match '^\s*FOUND') { 'Green' }
                 elseif ($_ -match '^\s*EXTRA') { 'Yellow' }
                 elseif ($_ -match '^\s*missing') { 'DarkGray' }
                 elseif ($_ -match '^###') { 'Cyan' }
                 else { 'White' }
        Write-Host $_ -ForegroundColor $color
    }
}

# -- Gap analysis --

Write-Host "`n$('==' * 70)" -ForegroundColor Cyan
Write-Host "  GAP ANALYSIS" -ForegroundColor Cyan
Write-Host "$('==' * 70)" -ForegroundColor Cyan
Write-Host @"

Compare the FOUND/missing lines above against what the cleanup scripts target:
  Windows : windows\Invoke-AWSCleanup.ps1
  Linux   : linux\invoke-aws-cleanup.sh

Look for:
  EXTRA  - component present on baseline AMI that cleanup script doesn't handle
  missing - component not planted by UserData (may need to add to CFN template)

If you see EXTRA components you want to clean up, open a brief investigation
before adding them to the cleanup scripts.

Reports saved to: $OutputDir
"@ -ForegroundColor White
# ── Connectivity check gate ───────────────────────────────────────────────────

$checkScript = Join-Path $PSScriptRoot 'Invoke-ConnectivityCheck.ps1'
if (Test-Path $checkScript) {
    Write-Host "`n=== Running Connectivity Check (port reachability gate) ===" -ForegroundColor Cyan
    & $checkScript -Region $Region
} else {
    Write-Warning "Invoke-ConnectivityCheck.ps1 not found — skipping connectivity gate."
}