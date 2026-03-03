#Requires -Version 5.1
<#
.SYNOPSIS
    Tears down the AWS migration test environment CloudFormation stack.

.PARAMETER StackName
    CloudFormation stack name. Default: mig-test-env

.PARAMETER Region
    AWS region. Default: us-east-1

.PARAMETER Force
    Skip confirmation prompt.

.EXAMPLE
    .\Teardown-TestEnv.ps1

.EXAMPLE
    .\Teardown-TestEnv.ps1 -Force
#>
[CmdletBinding()]
param(
    [string] $StackName = 'mig-test-env',
    [string] $Region    = 'us-east-1',
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n=== Migration Test Environment — Teardown ===" -ForegroundColor Yellow

# ── Confirm ───────────────────────────────────────────────────────────────────

if (-not $Force) {
    $confirm = Read-Host "Delete stack '$StackName' in region '$Region'? All EC2 instances and VPC resources will be destroyed. (yes/no)"
    if ($confirm -notmatch '^yes$') {
        Write-Host "Aborted." -ForegroundColor Gray
        exit 0
    }
}

# ── Check stack exists ────────────────────────────────────────────────────────

$null = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Stack '$StackName' not found — nothing to delete." -ForegroundColor Gray
    exit 0
}

# ── Delete ────────────────────────────────────────────────────────────────────

Write-Host "Deleting stack '$StackName'..." -ForegroundColor Red
aws cloudformation delete-stack --stack-name $StackName --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Error "delete-stack failed."
    exit 1
}

# ── Wait ──────────────────────────────────────────────────────────────────────

Write-Host "Waiting for stack-delete-complete..." -ForegroundColor Cyan
$lastSeen = @{}
$done     = $false
$start    = [datetime]::UtcNow

while (-not $done) {
    Start-Sleep 10

    # Once stack is gone describe-stacks returns an error — that means success
    $null = aws cloudformation describe-stacks --stack-name $StackName --region $Region 2>&1
    if ($LASTEXITCODE -ne 0) {
        $done = $true
        break
    }

    $stack  = aws cloudformation describe-stacks --stack-name $StackName --region $Region | ConvertFrom-Json
    $status = $stack.Stacks[0].StackStatus

    $events = aws cloudformation describe-stack-events --stack-name $StackName --region $Region |
              ConvertFrom-Json | Select-Object -ExpandProperty StackEvents |
              Where-Object { -not $lastSeen.ContainsKey($_.EventId) } |
              Sort-Object Timestamp
    foreach ($evt in $events) {
        $lastSeen[$evt.EventId] = $true
        $color = if ($evt.ResourceStatus -match 'FAILED') { 'Red' }
                 elseif ($evt.ResourceStatus -match 'DELETED') { 'Green' }
                 else { 'Gray' }
        Write-Host ("  {0,-30} {1,-35} {2}" -f $evt.ResourceType, $evt.LogicalResourceId, $evt.ResourceStatus) -ForegroundColor $color
    }

    if ($status -match 'DELETE_FAILED') {
        Write-Error "Stack deletion failed. Check the CloudFormation console for retained resources."
        exit 1
    }

    if (([datetime]::UtcNow - $start).TotalMinutes -gt 20) {
        Write-Error "Timed out waiting for stack deletion after 20 minutes."
        exit 1
    }
}

Write-Host "`nStack '$StackName' deleted successfully." -ForegroundColor Green

# Remove local env file if present
$envFile = Join-Path $PSScriptRoot 'test-env.json'
if (Test-Path $envFile) {
    Remove-Item $envFile -Force
    Write-Host "Removed $envFile"
}
