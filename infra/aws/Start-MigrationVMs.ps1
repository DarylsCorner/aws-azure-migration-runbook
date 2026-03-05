<#
.SYNOPSIS
    Starts all migration VMs and refreshes public IP env files.
.DESCRIPTION
    1. Starts discovery appliance, replication appliance, and both source VMs.
    2. Waits for running state.
    3. Updates appliance-vm.env and repl-appliance-vm.env with new public IPs.
    4. Prints RDP connection info.
.EXAMPLE
    .\Start-MigrationVMs.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot

# Instance IDs
$discoveryInstanceId    = 'i-032b879f96b453f2a'
$replInstanceId         = 'i-04bbc1a09463b00e3'
$windowsSourceInstanceId = (aws ec2 describe-instances `
    --filters 'Name=private-ip-address,Values=10.10.1.17' `
    --query 'Reservations[0].Instances[0].InstanceId' --output text)
$linuxSourceInstanceId  = (aws ec2 describe-instances `
    --filters 'Name=private-ip-address,Values=10.10.1.64' `
    --query 'Reservations[0].Instances[0].InstanceId' --output text)

$allIds = @($discoveryInstanceId, $replInstanceId, $windowsSourceInstanceId, $linuxSourceInstanceId)

Write-Host "Starting VMs: $($allIds -join ', ')"
aws ec2 start-instances --instance-ids @allIds --output text | Out-Null

Write-Host "Waiting for running state..."
aws ec2 wait instance-running --instance-ids @allIds
Write-Host "All VMs running."

# Fetch new public IPs
$discoveryPublicIp = aws ec2 describe-instances --instance-ids $discoveryInstanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
$replPublicIp = aws ec2 describe-instances --instance-ids $replInstanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# Update env files
$discoveryEnv = Join-Path $scriptDir 'appliance-vm.env'
if (Test-Path $discoveryEnv) {
    (Get-Content $discoveryEnv) -replace '^PublicIp=.*', "PublicIp=$discoveryPublicIp" |
        Set-Content $discoveryEnv
    Write-Host "Updated appliance-vm.env"
}

$replEnv = Join-Path $scriptDir 'repl-appliance-vm.env'
if (Test-Path $replEnv) {
    (Get-Content $replEnv) -replace '^PublicIp=.*', "PublicIp=$replPublicIp" |
        Set-Content $replEnv
    Write-Host "Updated repl-appliance-vm.env"
}

# Print connection summary
Write-Host ""
Write-Host "=== Connection Info ===" -ForegroundColor Cyan
Write-Host "Discovery appliance RDP : $discoveryPublicIp  |  Administrator / MigApp1iance!2026"
Write-Host "Replication appliance RDP: $replPublicIp  |  Administrator / Mig1!Ika4y2Clgz64fpl4hc"
Write-Host ""
Write-Host "Source VMs (private IPs unchanged):"
Write-Host "  Windows : 10.10.1.17  |  Administrator / MigW1ndows!2026"
Write-Host "  Linux   : 10.10.1.64  |  root / MigL1nux2026"
Write-Host ""
Write-Host "=== Next Steps ===" -ForegroundColor Cyan
Write-Host "1. RDP to replication appliance: mstsc /v:$replPublicIp"
Write-Host "2. Check Configuration Manager shows 'Connected' for rsv1-mig-landing"
Write-Host "   - If Connected: go to Azure Migrate portal -> Replicate"
Write-Host "   - If not Connected: re-run .\DRInstaller.ps1 and re-enter vault key"
Write-Host "      Portal: rsv1-mig-landing -> Site Recovery Infrastructure -> Replication appliances -> Keys"
