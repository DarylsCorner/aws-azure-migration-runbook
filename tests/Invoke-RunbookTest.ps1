<#
.SYNOPSIS
    Starts a Start-MigrationCleanup Automation job and streams its output.

.DESCRIPTION
    Creates an Azure Automation job via ARM REST API (az automation CLI extension
    is beta and does not support job create reliably). Polls until completion
    and prints all output/warning/error streams.

.PARAMETER SubscriptionId
    Target subscription (defaults to current az context).

.PARAMETER ResourceGroup
    Resource group containing the Automation Account and VM (default: rg-migration-test).

.PARAMETER AutomationAccount
    Automation Account name (default: aa-migration-test).

.PARAMETER StorageAccount
    Optional. Storage Account name. Leave empty (default) to use the scripts
    embedded in the runbook at publish time. Provide a value only for Hybrid
    Runbook Worker deployments where scripts are stored in private Blob Storage.

.PARAMETER VMName
    Name of the VM to clean up (default: mig-test-vm).

.PARAMETER Phase
    TestMigration (default) or Cutover.

.PARAMETER DryRun
    Pass to the runbook as DryRun=$true - no changes are made.

.PARAMETER RequireSnapshotTag
    Whether the runbook checks for the MigrationSnapshot disk tag (default: $false for testing).

.EXAMPLE
    # DryRun with embedded scripts (no storage account required)
    .\tests\Invoke-RunbookTest.ps1 -Phase TestMigration -DryRun

.EXAMPLE
    # DryRun using live storage download (Hybrid Runbook Worker)
    .\tests\Invoke-RunbookTest.ps1 -StorageAccount '<your-storage-account>' -DryRun
#>
[CmdletBinding()]
param(
    [string]$SubscriptionId     = '',
    [string]$ResourceGroup      = 'rg-migration-test',
    [string]$AutomationAccount  = 'aa-migration-test',

    [string]$StorageAccount = '',

    [string]$VMName             = 'mig-test-vm',

    [ValidateSet('TestMigration','Cutover')]
    [string]$Phase              = 'TestMigration',

    [switch]$DryRun,
    [bool]$RequireSnapshotTag   = $false
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step { param([string]$Msg) Write-Host "`n-- $Msg" -ForegroundColor Cyan }

function Invoke-ArmRest {
    param([string]$Method, [string]$Uri, [object]$Body, [string[]]$Headers = @('Content-Type=application/json'))
    if ($Body) {
        $tmp = [System.IO.Path]::GetTempFileName() + '.json'
        if ($Body -is [string]) {
            [System.IO.File]::WriteAllText($tmp, $Body, [System.Text.Encoding]::UTF8)
        } else {
            [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 10 -Compress), [System.Text.Encoding]::UTF8)
        }
        try   { az rest --method $Method --uri $Uri --body "@$tmp" --headers $Headers 2>&1 }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    } else {
        az rest --method $Method --uri $Uri --headers $Headers 2>&1
    }
}

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv).Trim()
}

Write-Host "Automation Account : $AutomationAccount"
Write-Host "VM                 : $VMName ($ResourceGroup)"
Write-Host "Phase              : $Phase  |  DryRun: $($DryRun.IsPresent)"

$apiVer  = '2023-11-01'
$aaBase  = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AutomationAccount"

# ---------------------------------------------------------------------------
# Start job via ARM PUT
# ---------------------------------------------------------------------------
Write-Step "Starting Automation job..."

$jobId  = [System.Guid]::NewGuid().ToString()
$jobUri = "$aaBase/jobs/${jobId}?api-version=$apiVer"

$jobBody = @{
    properties = @{
        runbook    = @{ name = 'Start-MigrationCleanup' }
        parameters = @{
            SubscriptionId                  = $SubscriptionId
            ResourceGroupName               = $ResourceGroup
            VMName                          = $VMName
            Phase                           = $Phase
            DryRun                          = if ($DryRun) { 'true' } else { 'false' }
            CleanupScriptStorageAccountName = $StorageAccount
            CleanupScriptContainer          = 'migration-scripts'
            RequireSnapshotTag              = if ($RequireSnapshotTag) { 'true' } else { 'false' }
        }
        runOn = ''
    }
}

$createResult = Invoke-ArmRest PUT $jobUri $jobBody
$createJson   = ($createResult -join '') -replace '^[^{]*',''   # drop any leading non-JSON lines
try   { $createObj = $createJson | ConvertFrom-Json } catch { $createObj = $null }

if ($createObj -and $createObj.PSObject.Properties['error']) {
    Write-Error "Job creation failed: $(($createObj.error | ConvertTo-Json -Compress))"
    exit 1
}

$jobName = if ($createObj -and $createObj.PSObject.Properties['name']) { $createObj.name } else { $jobId }
Write-Host "  Job ID : $jobName"

# ---------------------------------------------------------------------------
# Poll until terminal state
# ---------------------------------------------------------------------------
Write-Step "Polling job status (typically 3-8 minutes)..."

$terminalStates = @('Completed', 'Failed', 'Stopped', 'Suspended')
$spinChars  = @('|', '/', '-', '\')
$spinIdx    = 0
$startTime  = Get-Date
$maxWait    = [TimeSpan]::FromMinutes(30)
$statusObj  = $null

while ($true) {
    $statusJson = az rest --method GET --uri $jobUri --output json 2>$null
    $statusObj  = $statusJson | ConvertFrom-Json
    $status     = $statusObj.properties.status
    $elapsed    = ((Get-Date) - $startTime).ToString('mm\:ss')

    Write-Host -NoNewline "`r  [$($spinChars[$spinIdx % 4])] $($status.PadRight(14)) elapsed: $elapsed   "
    $spinIdx++

    if ($status -in $terminalStates) { Write-Host ""; break }

    if ((Get-Date) - $startTime -gt $maxWait) {
        Write-Host ""
        Write-Warning "Timed out after 30 minutes. Job still: $status"
        exit 1
    }

    Start-Sleep -Seconds 10
}

# ---------------------------------------------------------------------------
# Stream job output
# ---------------------------------------------------------------------------
Write-Step "Job output:"
Write-Host ""

$streamsUri = "$aaBase/jobs/$jobName/streams?api-version=$apiVer"
$streams    = (az rest --method GET --uri $streamsUri --output json 2>$null | ConvertFrom-Json).value

foreach ($s in $streams) {
    $color = switch ($s.properties.streamType) {
        'Output'  { 'White'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
        default   { 'Gray'   }
    }
    $streamId  = $s.properties.jobStreamId
    $detailUri = "$aaBase/jobs/$jobName/streams/$streamId`?api-version=$apiVer"
    $detail    = az rest --method GET --uri $detailUri --output json 2>$null | ConvertFrom-Json
    $text      = $detail.properties.streamText
    if ($text -and $text.Trim()) { Write-Host $text -ForegroundColor $color }
}

# ---------------------------------------------------------------------------
# Final result
# ---------------------------------------------------------------------------
Write-Host ""
$exMsg = if ($statusObj.properties.PSObject.Properties['exception']) { $statusObj.properties.exception } else { $null }
if ($exMsg) { Write-Host "  Exception: $exMsg" -ForegroundColor Red }

$color = if ($status -eq 'Completed') { 'Green' } else { 'Red' }
$sep   = '=' * 55
Write-Host $sep -ForegroundColor $color
Write-Host "  Job    : $jobName"                              -ForegroundColor $color
Write-Host "  Status : $status"                               -ForegroundColor $color
Write-Host "  Phase  : $Phase  |  DryRun: $($DryRun.IsPresent)" -ForegroundColor $color
Write-Host $sep -ForegroundColor $color

if ($status -ne 'Completed') { exit 1 }
