<#
.SYNOPSIS
    Provisions Azure Automation Account for Layer 3 runbook testing.
    In-guest scripts are embedded as base64 in the runbook — no storage required by default.

.DESCRIPTION
    Always creates:
      - Azure Automation Account (aa-migration-test) with system-assigned MI
      - Assigns Virtual Machine Contributor to MI on the resource group
      - Embeds in-guest scripts as base64 and publishes Start-MigrationCleanup.ps1 (PS 7.2)

    With -WithStorage also creates:
      - Storage Account (stmigtest<suffix>) with 'migration-scripts' container
      - Uploads Invoke-AWSCleanup.ps1 and invoke-aws-cleanup.sh to the container
      - Assigns Storage Blob Data Reader to MI on the storage account
      Use this path for Hybrid Runbook Worker + private-storage scenarios only.

    Safe to re-run — skips resources that already exist.

.PARAMETER ResourceGroup
    Resource group to deploy into (default: rg-migration-test).

.PARAMETER Location
    Azure region (default: eastus).

.PARAMETER SubscriptionId
    Target subscription (defaults to current az context).

.PARAMETER WithStorage
    When specified, provisions a storage account, uploads scripts, and assigns
    Storage Blob Data Reader to the managed identity.  Use for Hybrid Runbook Worker
    or private-storage scenarios.  Off by default — the runbook embeds scripts as
    base64 and requires no storage at runtime.

.EXAMPLE
    # Standard (no storage — embedded scripts)
    .\tests\Setup-AutomationInfra.ps1

.EXAMPLE
    # With storage for HRW / private-storage scenarios
    .\tests\Setup-AutomationInfra.ps1 -WithStorage
#>
[CmdletBinding()]
param(
    [string]$ResourceGroup  = 'rg-migration-test',
    [string]$Location       = 'eastus',
    [string]$SubscriptionId = '',
    [switch]$WithStorage
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Split-Path $PSScriptRoot -Parent

function Write-Step { param([string]$Msg) Write-Host "`n── $Msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$Msg) Write-Host "  [+] $Msg" -ForegroundColor Green }
function Write-Skip { param([string]$Msg) Write-Host "  [~] $Msg" -ForegroundColor Yellow }

# az rest on Windows strips inner double-quotes when --body is passed as a string.
# Write JSON to a temp file and use @filepath to avoid the issue.
function Invoke-ArmRest {
    param([string]$Method, [string]$Uri, [object]$Body, [string[]]$Headers = @('Content-Type=application/json'))
    if ($Body) {
        $tmp = [System.IO.Path]::GetTempFileName() + '.json'
        if ($Body -is [string]) {
            [System.IO.File]::WriteAllText($tmp, $Body, [System.Text.Encoding]::UTF8)
        } else {
            [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 10 -Compress), [System.Text.Encoding]::UTF8)
        }
        try {
            az rest --method $Method --uri $Uri --body "@$tmp" --headers $Headers 2>&1
        } finally {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    } else {
        az rest --method $Method --uri $Uri --headers $Headers 2>&1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve subscription
# ─────────────────────────────────────────────────────────────────────────────
if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv).Trim()
}
Write-Host "Subscription : $SubscriptionId"
Write-Host "Resource Group: $ResourceGroup"
Write-Host "Location     : $Location"
Write-Host "With Storage  : $WithStorage"

# Variables for storage — populated only when -WithStorage is used
$saName    = ''
$saId      = ''
$container = 'migration-scripts'

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1 — Automation Account
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 1 — Automation Account"

$aaName    = 'aa-migration-test'
$aaApiVer  = '2021-06-22'
$aaUri     = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/${aaName}?api-version=$aaApiVer"

$aaState = az rest --method GET --uri $aaUri --query 'properties.state' -o tsv 2>$null
if ($aaState) {
    Write-Skip "$aaName already exists (state: $aaState)"
    # Ensure managed identity is enabled (may have been created without it)
    $existingMI = az rest --method GET --uri $aaUri --query 'identity.principalId' -o tsv 2>$null
    if (-not $existingMI) {
        Write-Host "  Enabling system-assigned managed identity on existing account..." -ForegroundColor Yellow
        Invoke-ArmRest PATCH $aaUri @{ identity = @{ type = 'SystemAssigned' } } | Out-Null
        Start-Sleep -Seconds 15
        Write-OK "Managed identity enabled"
    }
} else {
    Invoke-ArmRest PUT $aaUri @{ location = $Location; identity = @{ type = 'SystemAssigned' }; properties = @{ sku = @{ name = 'Basic' } } } | Out-Null
    Write-OK "Created $aaName — waiting for ARM propagation..."

    $deadline = (Get-Date).AddSeconds(120)
    do {
        Start-Sleep -Seconds 10
        $aaState = az rest --method GET --uri $aaUri --query 'properties.state' -o tsv 2>$null
    } while (-not $aaState -and (Get-Date) -lt $deadline)
    if (-not $aaState) { throw "Automation Account '$aaName' not visible after 120s — check Azure portal" }
    Write-OK "ARM propagation confirmed (state: $aaState)"
}

# Get the managed identity principal ID
$miPrincipalId = (az rest --method GET --uri $aaUri --query 'identity.principalId' -o tsv).Trim()
Write-OK "Managed Identity principal: $miPrincipalId"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2 — Storage Account  [skipped unless -WithStorage]
# ─────────────────────────────────────────────────────────────────────────────
if ($WithStorage) {
    Write-Step "Step 2 — Storage Account"

    # Use a deterministic name based on subscription suffix to stay idempotent
    $subSuffix  = $SubscriptionId.Replace('-','').Substring(0,8)
    $saName     = "stmigtest$subSuffix"
    $saExisting = az storage account show --resource-group $ResourceGroup --name $saName --query name -o tsv 2>$null
    if ($saExisting) {
        Write-Skip "$saName already exists"
    } else {
        az storage account create `
            --resource-group         $ResourceGroup `
            --name                   $saName `
            --location               $Location `
            --sku                    Standard_LRS `
            --allow-blob-public-access false `
            --min-tls-version        TLS1_2 | Out-Null
        Write-OK "Created $saName"
    }

    $saId = (az storage account show `
        --resource-group $ResourceGroup `
        --name           $saName `
        --query          id `
        -o tsv).Trim()

    Write-OK "Storage account ID: $saId"

    # Ensure the operator running this script has Storage Blob Data Contributor so
    # that --auth-mode login works for container and blob operations.
    $operatorId = (az ad signed-in-user show --query id -o tsv 2>$null).Trim()
    if (-not $operatorId) {
        # Fallback for service principals
        $operatorId = (az account show --query user.name -o tsv).Trim()
    }
    $blobContribOperator = az role assignment list `
        --assignee $operatorId `
        --role     'Storage Blob Data Contributor' `
        --scope    $saId `
        --query    '[0].id' -o tsv 2>$null
    if ($blobContribOperator) {
        Write-Skip "Operator already has Storage Blob Data Contributor on $saName"
    } else {
        az role assignment create `
            --assignee $operatorId `
            --role     'Storage Blob Data Contributor' `
            --scope    $saId | Out-Null
        Write-OK "Assigned Storage Blob Data Contributor to operator on $saName"
        # RBAC propagation — new assignments can take ~30s to take effect
        Write-Host "  Waiting 30s for RBAC propagation..." -ForegroundColor Yellow
        Start-Sleep -Seconds 30
    }

    # ─────────────────────────────────────────────────────────────────────────
    # STEP 3 — Blob container + upload scripts
    # ─────────────────────────────────────────────────────────────────────────
    Write-Step "Step 3 — Blob container + script upload"

    $containerExists = az storage container exists `
        --account-name $saName `
        --auth-mode    login `
        --name         $container `
        --query        exists -o tsv 2>$null

    if ($containerExists -eq 'true') {
        Write-Skip "Container '$container' already exists"
    } else {
        az storage container create `
            --account-name $saName `
            --auth-mode    login `
            --name         $container | Out-Null
        Write-OK "Created container '$container'"
    }

    # Upload Windows cleanup script
    $windowsScript = Join-Path $root 'windows\Invoke-AWSCleanup.ps1'
    az storage blob upload `
        --account-name   $saName `
        --auth-mode      login `
        --container-name $container `
        --name           'Invoke-AWSCleanup.ps1' `
        --file           $windowsScript `
        --overwrite | Out-Null
    Write-OK "Uploaded Invoke-AWSCleanup.ps1"

    # Upload Linux cleanup script
    $linuxScript = Join-Path $root 'linux\invoke-aws-cleanup.sh'
    if (Test-Path $linuxScript) {
        az storage blob upload `
            --account-name   $saName `
            --auth-mode      login `
            --container-name $container `
            --name           'invoke-aws-cleanup.sh' `
            --file           $linuxScript `
            --overwrite | Out-Null
        Write-OK "Uploaded invoke-aws-cleanup.sh"
    }
} else {
    Write-Host "`n  [~] Skipping storage account (use -WithStorage for HRW/private-storage scenarios)" -ForegroundColor DarkGray
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4 — RBAC assignments
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 4 — RBAC assignments"

$rgScope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup"

# Storage Blob Data Reader for managed identity — only needed when storage is provisioned
if ($WithStorage -and $saId) {
    $blobReaderExists = az role assignment list `
        --assignee   $miPrincipalId `
        --role       'Storage Blob Data Reader' `
        --scope      $saId `
        --query      '[0].id' -o tsv 2>$null

    if ($blobReaderExists) {
        Write-Skip "Storage Blob Data Reader already assigned"
    } else {
        az role assignment create `
            --assignee   $miPrincipalId `
            --role       'Storage Blob Data Reader' `
            --scope      $saId | Out-Null
        Write-OK "Assigned Storage Blob Data Reader on storage account"
    }
}

# Virtual Machine Contributor — always required (runbook invokes az vm run-command)
$vmContribExists = az role assignment list `
    --assignee   $miPrincipalId `
    --role       'Virtual Machine Contributor' `
    --scope      $rgScope `
    --query      '[0].id' -o tsv 2>$null

if ($vmContribExists) {
    Write-Skip "Virtual Machine Contributor already assigned"
} else {
    az role assignment create `
        --assignee   $miPrincipalId `
        --role       'Virtual Machine Contributor' `
        --scope      $rgScope | Out-Null
    Write-OK "Assigned Virtual Machine Contributor on resource group"
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5 — Import + publish runbook (PS 7.2 runtime — Az modules built-in)
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 5 — Runbook import"

$runbookName = 'Start-MigrationCleanup'
$runbookFile = Join-Path $root 'runbook\Start-MigrationCleanup.ps1'
$rbApiVer    = '2023-11-01'
$rbBaseUri   = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$aaName/runbooks/$runbookName"

# Create or update the runbook metadata
$rbResult = Invoke-ArmRest PUT "${rbBaseUri}?api-version=$rbApiVer" @{
    location   = $Location
    properties = @{ runbookType = 'PowerShell72'; description = 'AWS to Azure in-guest cleanup orchestration' }
}
$rbJson = ($rbResult -join '') -replace '^[^{]*',''
try { $rbObj = $rbJson | ConvertFrom-Json } catch { $rbObj = $null }
if ($rbObj -and $rbObj.PSObject.Properties['error']) { throw "Runbook create/update failed: $(($rbObj.error | ConvertTo-Json -Compress))" }
Write-OK "Runbook '$runbookName' created/updated"

# Upload draft content via the /draft/content endpoint
$scriptContent = Get-Content $runbookFile -Raw -Encoding UTF8

# Embed the in-guest scripts as base64 — the runbook placeholders replaced here so
# no storage account is needed at runtime (cloud sandbox or Hybrid Runbook Worker).
$winScriptPath = Join-Path $root 'windows\Invoke-AWSCleanup.ps1'
$linScriptPath = Join-Path $root 'linux\invoke-aws-cleanup.sh'
if (-not (Test-Path $winScriptPath)) { throw "Windows cleanup script not found: $winScriptPath" }
if (-not (Test-Path $linScriptPath)) { throw "Linux cleanup script not found: $linScriptPath" }
$winB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $winScriptPath -Raw -Encoding UTF8)))
$linB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-Content $linScriptPath -Raw -Encoding UTF8)))
$scriptContent = $scriptContent -replace '__WINDOWS_SCRIPT_B64__', $winB64
$scriptContent = $scriptContent -replace '__LINUX_SCRIPT_B64__', $linB64
Write-OK "In-guest scripts embedded as base64 into runbook draft"

$draftResult = Invoke-ArmRest PUT "${rbBaseUri}/draft/content?api-version=$rbApiVer" -Body $scriptContent -Headers @('Content-Type=text/powershell')
# 200 draft/content returns empty body — check for error prefix
if (($draftResult -join '') -match '"error"') { throw "Draft upload failed: $(($draftResult -join ''))" }
Write-OK "Runbook draft content uploaded"

# Publish the runbook
$pubResult = Invoke-ArmRest POST "${rbBaseUri}/publish?api-version=$rbApiVer"
if (($pubResult -join '') -match '"error"') { throw "Runbook publish failed: $(($pubResult -join ''))" }
Write-OK "Runbook published"

# ─────────────────────────────────────────────────────────────────────────────
# STEP 6 — Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Step "Step 6 — Infrastructure ready"
Write-Host ""
Write-Host "  Automation Account : $aaName" -ForegroundColor White
Write-Host "  Runbook            : $runbookName (PowerShell 7.2)" -ForegroundColor White
Write-Host "  Script embedding   : base64 (no storage required at runtime)" -ForegroundColor White
if ($WithStorage -and $saName) {
    Write-Host "  Storage Account    : $saName" -ForegroundColor White
    Write-Host "  Container          : $container" -ForegroundColor White
} else {
    Write-Host "  Storage Account    : not provisioned (use -WithStorage if needed)" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "  Run a DryRun test job with:" -ForegroundColor White
Write-Host @"
  .\tests\Invoke-RunbookTest.ps1 ``
      -SubscriptionId '$SubscriptionId' ``
      -AutomationAccount '$aaName' ``
      -VMName 'mig-test-vm' ``
      -Phase TestMigration ``
      -DryRun
"@ -ForegroundColor DarkGray
