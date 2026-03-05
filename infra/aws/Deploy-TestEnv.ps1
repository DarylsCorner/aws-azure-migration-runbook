#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys the AWS migration test environment via CloudFormation.

.DESCRIPTION
    Creates stack 'mig-test-env' with one Windows Server 2022 and one Ubuntu
    22.04 LTS EC2 instance pre-loaded with AWS agents and dirty-box artifacts.
    Both instances use SSM for agent-based management (no key pair required).

.PARAMETER StackName
    CloudFormation stack name. Default: mig-test-env

.PARAMETER Region
    AWS region to deploy into. Default: us-east-1

.PARAMETER AllowCidr
    CIDR allowed inbound on RDP/SSH.
    Default: your current public IP (/32).

.PARAMETER WindowsInstanceType
    EC2 instance type for Windows VM. Default: t3.medium

.PARAMETER LinuxInstanceType
    EC2 instance type for Linux VM. Default: t3.small

.EXAMPLE
    .\Deploy-TestEnv.ps1

.EXAMPLE
    .\Deploy-TestEnv.ps1 -Region eu-west-1 -AllowCidr '1.2.3.4/32'
#>
[CmdletBinding()]
param(
    [string] $StackName           = 'mig-test-env',
    [string] $Region              = 'us-east-1',
    [string] $AllowCidr           = '',            # auto-detected if blank
    [string] $WindowsInstanceType = 't3.medium',
    [string] $LinuxInstanceType   = 't3.small'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TemplateFile = Join-Path $PSScriptRoot 'cfn-migration-test.yaml'

# ── Pre-flight ────────────────────────────────────────────────────────────────

Write-Host "`n=== Migration Test Environment — Deploy ===" -ForegroundColor Cyan

if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error 'AWS CLI not found. Install from https://aws.amazon.com/cli/'
    exit 1
}

# Verify credentials work
$null = aws sts get-caller-identity --region $Region 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "AWS credentials not configured or invalid. Run 'aws configure' or set AWS_PROFILE."
    exit 1
}
$identity = aws sts get-caller-identity --region $Region | ConvertFrom-Json
Write-Host "  AWS Account : $($identity.Account)"
Write-Host "  IAM ARN     : $($identity.Arn)"
Write-Host "  Region      : $Region"

# Auto-detect public IP if AllowCidr not specified
if ([string]::IsNullOrWhiteSpace($AllowCidr)) {
    try {
        $myIp    = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 5).Trim()
        $AllowCidr = "$myIp/32"
        Write-Host "  Allow CIDR  : $AllowCidr (auto-detected)"
    } catch {
        $AllowCidr = '0.0.0.0/0'
        Write-Warning "Could not detect public IP — defaulting AllowCidr to 0.0.0.0/0 (tighten before production use)"
    }
} else {
    Write-Host "  Allow CIDR  : $AllowCidr"
}

# Check if stack already exists
$existingStack = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>&1
$stackExists   = ($LASTEXITCODE -eq 0)

# ── Deploy / update ───────────────────────────────────────────────────────────

$cfnParams = @(
    "ParameterKey=AllowCidr,ParameterValue=$AllowCidr",
    "ParameterKey=WindowsInstanceType,ParameterValue=$WindowsInstanceType",
    "ParameterKey=LinuxInstanceType,ParameterValue=$LinuxInstanceType"
)

if ($stackExists) {
    Write-Host "`nStack '$StackName' exists — updating..." -ForegroundColor Yellow
    $cmd = 'update-stack'
} else {
    Write-Host "`nCreating stack '$StackName'..." -ForegroundColor Green
    $cmd = 'create-stack'
}

aws cloudformation $cmd `
    --stack-name      $StackName `
    --template-body   "file://$TemplateFile" `
    --parameters      $cfnParams `
    --capabilities    CAPABILITY_NAMED_IAM `
    --region          $Region | Out-Null

if ($LASTEXITCODE -ne 0) {
    # update-stack returns non-zero if there are no changes — that's fine
    if ($cmd -eq 'update-stack') {
        Write-Host "  No changes detected or update submitted." -ForegroundColor Gray
    } else {
        Write-Error "CloudFormation $cmd failed."
        exit 1
    }
}

# ── Wait ──────────────────────────────────────────────────────────────────────

$waitEvent = if ($cmd -eq 'create-stack') { 'stack-create-complete' } else { 'stack-update-complete' }
Write-Host "`nWaiting for $waitEvent (this takes ~3–5 min)..." -ForegroundColor Cyan

# Stream events while waiting
$lastSeen = @{}
$done     = $false
$start    = [datetime]::UtcNow

while (-not $done) {
    Start-Sleep 10

    # Check stack status
    $stack  = aws cloudformation describe-stacks --stack-name $StackName --region $Region | ConvertFrom-Json
    $status = $stack.Stacks[0].StackStatus

    # Stream new resource events
    $events = aws cloudformation describe-stack-events --stack-name $StackName --region $Region |
              ConvertFrom-Json | Select-Object -ExpandProperty StackEvents |
              Where-Object { -not $lastSeen.ContainsKey($_.EventId) } |
              Sort-Object Timestamp
    foreach ($evt in $events) {
        $lastSeen[$evt.EventId] = $true
        $color = if ($evt.ResourceStatus -match 'FAILED') { 'Red' }
                 elseif ($evt.ResourceStatus -match 'COMPLETE') { 'Green' }
                 else { 'Gray' }
        Write-Host ("  {0,-30} {1,-35} {2}" -f $evt.ResourceType, $evt.LogicalResourceId, $evt.ResourceStatus) -ForegroundColor $color
    }

    if ($status -in @('CREATE_COMPLETE','UPDATE_COMPLETE')) {
        $done = $true
    } elseif ($status -match 'FAILED|ROLLBACK') {
        Write-Error "Stack reached status: $status"
        exit 1
    } elseif (([datetime]::UtcNow - $start).TotalMinutes -gt 20) {
        Write-Error "Timed out waiting for stack operation after 20 minutes."
        exit 1
    }
}

# ── Fetch outputs ─────────────────────────────────────────────────────────────

Write-Host "`n=== Stack outputs ===" -ForegroundColor Cyan
$outputs = aws cloudformation describe-stacks --stack-name $StackName --region $Region |
           ConvertFrom-Json | Select-Object -ExpandProperty Stacks |
           Select-Object -First 1 |
           Select-Object -ExpandProperty Outputs

$outputMap = @{}
foreach ($o in $outputs) {
    $outputMap[$o.OutputKey] = $o.OutputValue
    Write-Host ("  {0,-30} {1}" -f $o.OutputKey, $o.OutputValue)
}

# ── Write env file for subsequent scripts ─────────────────────────────────────

$envFile = Join-Path $PSScriptRoot 'test-env.json'
@{
    StackName          = $StackName
    Region             = $Region
    WindowsInstanceId  = $outputMap['WindowsInstanceId']
    LinuxInstanceId    = $outputMap['LinuxInstanceId']
    WindowsPublicIp    = $outputMap['WindowsPublicIp']
    LinuxPublicIp      = $outputMap['LinuxPublicIp']
    WindowsPrivateIp   = $outputMap['WindowsPrivateIp']
    LinuxPrivateIp     = $outputMap['LinuxPrivateIp']
    DeployedAt         = (Get-Date -Format 'o')
} | ConvertTo-Json | Set-Content $envFile
Write-Host "`n  Environment details saved to: $envFile"

# ── Next steps ────────────────────────────────────────────────────────────────

Write-Host @"

=== Next steps ===
  1. Wait ~2 min for UserData (agent installs) to finish.
     Check with: aws ssm describe-instance-information --region $Region

  2. Verify appliance connectivity (port reachability gate):
     .\Invoke-ConnectivityCheck.ps1

  3. Set up Azure Migrate project if not already done:
     https://portal.azure.com → Azure Migrate → Servers, databases and web apps

  4. Install Azure Site Recovery Mobility service on each VM via SSM:
     .\Install-AzureMigrateAgent.ps1   (will be generated next)

  5. Enable replication in Azure Migrate, wait for initial sync, then migrate.

  6. After cutover, run the cleanup runbook:
     .\tests\Invoke-RunbookTest.ps1

"@ -ForegroundColor Green
