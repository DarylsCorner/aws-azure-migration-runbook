<#
.SYNOPSIS
    Provisions the Azure Migrate project and landing-zone infrastructure for
    migrating the AWS test VMs to Azure.

.DESCRIPTION
    Creates:
      rg-mig-project   -- resource group housing the Azure Migrate hub project
      rg-mig-landing   -- landing-zone resource group where migrated VMs will live
      vnet-mig-landing -- VNet (10.20.0.0/16) in the landing zone
      snet-mig-vms     -- subnet (10.20.1.0/24) for migrated VMs
      nsg-mig-vms      -- NSG attached to the subnet (RDP/SSH restricted to caller IP)
      migproject       -- Azure Migrate hub project

    Run once.  Safe to re-run -- existing resources are skipped.

.PARAMETER Location
    Azure region for all resources.  Default: eastus.

.PARAMETER CallerCidr
    CIDR to allow for RDP (3389) and SSH (22) on the landing-zone NSG.
    Defaults to the current public IP of this machine.

.EXAMPLE
    .\Setup-MigrateProject.ps1
    .\Setup-MigrateProject.ps1 -Location eastus2 -CallerCidr 203.0.113.5/32
#>
param(
    [string] $Location   = 'eastus',
    [string] $CallerCidr = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Resolve caller CIDR ───────────────────────────────────────────────────────

if ([string]::IsNullOrWhiteSpace($CallerCidr)) {
    $ip = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
    $CallerCidr = "$ip/32"
    Write-Host "  Detected public IP: $CallerCidr"
}

# ── Names ─────────────────────────────────────────────────────────────────────

$rgProject  = 'rg-mig-project'
$rgLanding  = 'rg-mig-landing'
$vnetName   = 'vnet-mig-landing'
$subnetName = 'snet-mig-vms'
$nsgName    = 'nsg-mig-vms'
$projectName = 'migproject'

# ── Helper ────────────────────────────────────────────────────────────────────

function Ensure-ResourceGroup {
    param($Name, $Location)
    $exists = az group exists --name $Name | ConvertFrom-Json
    if ($exists) { Write-Host "  [exists] $Name" }
    else {
        Write-Host "  [create] $Name..."
        az group create --name $Name --location $Location --output none
    }
}

# ── Resource groups ───────────────────────────────────────────────────────────

Write-Host "`n=== Resource Groups ===" -ForegroundColor Cyan
Ensure-ResourceGroup $rgProject $Location
Ensure-ResourceGroup $rgLanding $Location

# ── NSG ───────────────────────────────────────────────────────────────────────

Write-Host "`n=== NSG ===" -ForegroundColor Cyan
$nsgExists = az network nsg show --resource-group $rgLanding --name $nsgName `
    --query name -o tsv 2>$null
if ($nsgExists) {
    Write-Host "  [exists] $nsgName"
} else {
    Write-Host "  [create] $nsgName..."
    az network nsg create --resource-group $rgLanding --name $nsgName `
        --location $Location --output none

    # RDP - restricted to caller only
    az network nsg rule create --resource-group $rgLanding --nsg-name $nsgName `
        --name Allow-RDP --priority 1000 --protocol Tcp --direction Inbound `
        --source-address-prefixes $CallerCidr --destination-port-ranges 3389 `
        --access Allow --output none
    Write-Host "    Added: Allow-RDP from $CallerCidr"

    # SSH - restricted to caller only
    az network nsg rule create --resource-group $rgLanding --nsg-name $nsgName `
        --name Allow-SSH --priority 1010 --protocol Tcp --direction Inbound `
        --source-address-prefixes $CallerCidr --destination-port-ranges 22 `
        --access Allow --output none
    Write-Host "    Added: Allow-SSH from $CallerCidr"

    # Deny all other inbound (belt-and-suspenders; Azure default deny already applies)
    az network nsg rule create --resource-group $rgLanding --nsg-name $nsgName `
        --name Deny-AllInbound --priority 4000 --protocol '*' --direction Inbound `
        --source-address-prefixes '*' --destination-port-ranges '*' `
        --access Deny --output none
    Write-Host "    Added: Deny-AllInbound"
}

# ── VNet + subnet ─────────────────────────────────────────────────────────────

Write-Host "`n=== VNet ===" -ForegroundColor Cyan
$vnetExists = az network vnet show --resource-group $rgLanding --name $vnetName `
    --query name -o tsv 2>$null
if ($vnetExists) {
    Write-Host "  [exists] $vnetName"
} else {
    Write-Host "  [create] $vnetName (10.20.0.0/16)..."
    az network vnet create --resource-group $rgLanding --name $vnetName `
        --location $Location --address-prefixes '10.20.0.0/16' `
        --subnet-name $subnetName --subnet-prefixes '10.20.1.0/24' `
        --output none

    # Associate NSG with subnet
    az network vnet subnet update --resource-group $rgLanding --vnet-name $vnetName `
        --name $subnetName --network-security-group $nsgName --output none
    Write-Host "  [create] $subnetName (10.20.1.0/24) + NSG attached"
}

# ── Azure Migrate project ─────────────────────────────────────────────────────

Write-Host "`n=== Azure Migrate Project ===" -ForegroundColor Cyan
$projExists = az resource show --resource-group $rgProject `
    --resource-type 'Microsoft.Migrate/migrateProjects' --name $projectName `
    --query name -o tsv 2>$null
if ($projExists) {
    Write-Host "  [exists] $projectName"
} else {
    Write-Host "  [create] $projectName..."
    $sub = (az account show --query id -o tsv).Trim()
    $projUri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rgProject" +
               "/providers/Microsoft.Migrate/migrateProjects/${projectName}?api-version=2020-05-01"
    # migrateProjects is not available in eastus -- use centralus as the fixed region
    $projLocation = if ($Location -eq 'eastus') { 'centralus' } else { $Location }
    $body = @{
        location   = $projLocation
        properties = @{}
    } | ConvertTo-Json -Compress
    $tmp = [System.IO.Path]::GetTempFileName() + '.json'
    [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
    az rest --method PUT --uri $projUri --body "@$tmp" --output none
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    Write-Host "  [created] $projectName in $rgProject"
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n=== Done ===" -ForegroundColor Green
$sub = (az account show --query id -o tsv).Trim()
Write-Host @"

  Azure Migrate project : $projectName  ($rgProject, centralus)
  Landing zone VNet     : $vnetName / $subnetName  ($rgLanding)
  NSG                   : $nsgName (RDP+SSH from $CallerCidr)

Next steps:
  1. In the Azure portal, open the $projectName migrate project
     and add the 'Server Migration' tool
  2. Download + deploy the replication appliance OVA (or Physical/AWS installer)
     onto a Windows Server in the same network that can reach the EC2 VMs
  3. Install the Mobility service agent on both EC2 VMs via SSM
  4. Register VMs with the appliance and start replication
  5. Test migration -> run cleanup runbook -> validate -> cutover
"@
