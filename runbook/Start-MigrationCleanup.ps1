<#
.SYNOPSIS
    Azure Automation Runbook — orchestrates AWS in-guest cleanup on a single VM
    migrated via Azure Migrate.

.DESCRIPTION
    Runs as an Azure Automation PowerShell runbook with a system-assigned Managed
    Identity. Performs pre-flight checks (VM exists, OS detected, snapshot gate),
    then fires the appropriate in-guest cleanup script via Run Command.

    The in-guest scripts (windows/Invoke-AWSCleanup.ps1 or linux/invoke-aws-cleanup.sh)
    are embedded as base64 content by Setup-AutomationInfra.ps1 at publish time — no
    storage account is required at runtime. Pass -CleanupScriptStorageAccountName to
    download fresh copies from Blob Storage instead (useful for Hybrid Runbook Worker
    deployments with a private storage account; requires Storage Blob Data Reader on
    the Managed Identity).

.PARAMETER SubscriptionId
    Azure subscription containing the target VM.

.PARAMETER ResourceGroupName
    Resource group containing the target VM.

.PARAMETER VMName
    Name of the Azure VM to clean up.

.PARAMETER Phase
    TestMigration (default) or Cutover.
    TestMigration: service-disable, credential/env cleanup only.
    Cutover:       full cleanup including MSI/package removal.

.PARAMETER DryRun
    Pass -DryRun to the in-guest script; no changes are made but all actions
    are logged and returned.

.PARAMETER CleanupScriptStorageAccountName
    Optional. Name of the Azure Storage Account hosting the in-guest scripts.
    Leave empty (default) to use the scripts embedded at publish time.
    Provide a value to download fresh copies at job runtime instead (Hybrid Runbook
    Worker / private-storage scenario).

.PARAMETER CleanupScriptContainer
    Blob container name (default: 'migration-scripts').

.PARAMETER RequireSnapshotTag
    If true (default), abort unless the VM's OS disk has a tag
    'MigrationSnapshot' = 'true'. Set to $false to bypass in non-prod tests.

.PARAMETER ReportOutputDir
    Local Automation worker path to write JSON reports. Reports are also
    written to the Runbook output stream.

.NOTES
    Required Az modules: Az.Accounts, Az.Compute
                        Az.Storage (only when -CleanupScriptStorageAccountName is used)
    Authentication: System-assigned Managed Identity on the Automation Account
    Run Command extension must be enabled on the VM.
#>
param(
    [Parameter(Mandatory)]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [string]$VMName,

    [ValidateSet('TestMigration', 'Cutover')]
    [string]$Phase = 'TestMigration',

    [bool]$DryRun = $false,

    [string]$CleanupScriptStorageAccountName = '',

    [string]$CleanupScriptContainer = 'migration-scripts',

    [bool]$RequireSnapshotTag = $true,

    [string]$ReportOutputDir = "$env:TEMP\migration-reports"
)

$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Embedded in-guest script content
# Setup-AutomationInfra.ps1 replaces these placeholders with real base64 at
# publish time. Do not edit these lines manually.
# ─────────────────────────────────────────────────────────────────────────────
$embeddedWindowsScriptB64 = '__WINDOWS_SCRIPT_B64__'
$embeddedLinuxScriptB64   = '__LINUX_SCRIPT_B64__'

# ─────────────────────────────────────────────────────────────────────────────
# Logging (compatible with Automation output streams)
# ─────────────────────────────────────────────────────────────────────────────
function Write-RunbookLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Output "$ts [$Level] $Message"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run Command output helpers (defined early so the WMF check can reuse them)
# RunPowerShellScript (Windows) returns separate StdOut/StdErr Value items.
# RunShellScript      (Linux)  returns a single ProvisioningState item whose
# Message embeds [stdout]...[stderr] markers.
# ─────────────────────────────────────────────────────────────────────────────
function Get-RunCmdStdOut {
    param($Result, [string]$OsType)
    if ($OsType -eq 'Windows') {
        return $Result.Value | Where-Object { $_.Code -like '*StdOut*' } | Select-Object -ExpandProperty Message
    }
    $raw = ($Result.Value | Select-Object -ExpandProperty Message) -join "`n"
    if ($raw -match '(?s)\[stdout\](.*?)\[stderr\]') { return $matches[1].Trim() }
    return ''
}
function Get-RunCmdStdErr {
    param($Result, [string]$OsType)
    if ($OsType -eq 'Windows') {
        return $Result.Value | Where-Object { $_.Code -like '*StdErr*' } | Select-Object -ExpandProperty Message
    }
    $raw = ($Result.Value | Select-Object -ExpandProperty Message) -join "`n"
    if ($raw -match '(?s)\[stderr\](.*)$') { return $matches[1].Trim() }
    return ''
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: authenticate via Managed Identity
# ─────────────────────────────────────────────────────────────────────────────
Write-RunbookLog "Connecting to Azure using Managed Identity..."
try {
    Connect-AzAccount -Identity -ErrorAction Stop | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-RunbookLog "Connected. Subscription: $SubscriptionId"
} catch {
    Write-Error "Failed to authenticate: $($_.Exception.Message)"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: verify VM exists and retrieve OS profile
# ─────────────────────────────────────────────────────────────────────────────
Write-RunbookLog "Retrieving VM: $VMName in $ResourceGroupName..."
try {
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -ErrorAction Stop
} catch {
    Write-Error "VM '$VMName' not found in resource group '$ResourceGroupName': $($_.Exception.Message)"
    exit 1
}

$osType = if ($vm.StorageProfile.OsDisk.OsType -eq 'Windows') { 'Windows' } else { 'Linux' }
Write-RunbookLog "VM found. OS type: $osType  |  Location: $($vm.Location)"

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: snapshot gate
# Verify a restore point exists before allowing Cutover-phase cleanup.
# ─────────────────────────────────────────────────────────────────────────────
if ($RequireSnapshotTag) {
    Write-RunbookLog "Checking snapshot gate..."
    $diskName = $vm.StorageProfile.OsDisk.Name
    try {
        $disk = Get-AzDisk -ResourceGroupName $ResourceGroupName -DiskName $diskName -ErrorAction Stop
        $snapshotTagValue = $disk.Tags['MigrationSnapshot']
        if ($snapshotTagValue -ne 'true') {
            Write-Error @"
SNAPSHOT GATE FAILED: OS disk '$diskName' does not have tag 'MigrationSnapshot=true'.
Take a snapshot or restore point of the VM before running cleanup,
then add the tag to the disk: az disk update --name $diskName --resource-group $ResourceGroupName --set tags.MigrationSnapshot=true
To bypass this check (non-production only), set -RequireSnapshotTag `$false.
"@
            exit 1
        }
        Write-RunbookLog "Snapshot gate passed — tag 'MigrationSnapshot=true' confirmed on disk '$diskName'"
    } catch {
        Write-Error "Could not check disk '$diskName': $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-Warning "Snapshot gate bypassed (-RequireSnapshotTag `$false). Ensure a manual restore point exists."
}

# ─────────────────────────────────────────────────────────────────────────────
# Windows pre-flight: PowerShell version gate
#
# Invoke-AWSCleanup.ps1 declares #Requires -Version 5.1 and will refuse to
# run on older runtimes.  Windows Server 2016+ ships with PS 5.1 already.
# If this check fails the VM was not upgraded before migration as recommended
# by the Azure Migrate assessment — resolve the OS version before retrying.
# ─────────────────────────────────────────────────────────────────────────────
if ($osType -eq 'Windows') {
    Write-RunbookLog "Checking PowerShell version on '$VMName'..."
    try {
        $versionResult = Invoke-AzVMRunCommand `
            -ResourceGroupName $ResourceGroupName `
            -VMName            $VMName `
            -CommandId         'RunPowerShellScript' `
            -ScriptString      '"$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"' `
            -ErrorAction       Stop
        $psVersionStr = (Get-RunCmdStdOut $versionResult 'Windows').Trim().Trim('"')
        Write-RunbookLog "Detected PowerShell version: $psVersionStr"
    } catch {
        Write-Warning "Could not detect PowerShell version on VM (will proceed): $($_.Exception.Message)"
        $psVersionStr = $null
    }

    if ($psVersionStr -and ($psVersionStr -as [version]) -lt [version]'5.1') {
        Write-Error @"
POWERSHELL VERSION TOO LOW
  VM      : $VMName
  Found   : PowerShell $psVersionStr
  Required: PowerShell 5.1 (ships with Windows Server 2016 and later)

This VM should have received an in-place OS upgrade to Windows Server 2016+
before reaching this step. Check the Azure Migrate assessment recommendations
for this VM and complete the OS upgrade, then re-run this runbook.
"@
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Retrieve cleanup script — embedded content (default) or Blob Storage download
# ─────────────────────────────────────────────────────────────────────────────
$scriptBlobName = if ($osType -eq 'Windows') { 'Invoke-AWSCleanup.ps1' } else { 'invoke-aws-cleanup.sh' }

if ($CleanupScriptStorageAccountName) {
    Write-RunbookLog "Fetching cleanup script from storage account '$CleanupScriptStorageAccountName'..."
    try {
        $ctx = New-AzStorageContext -StorageAccountName $CleanupScriptStorageAccountName `
            -UseConnectedAccount -ErrorAction Stop

        $localScriptPath = Join-Path $env:TEMP $scriptBlobName
        Get-AzStorageBlobContent `
            -Container $CleanupScriptContainer `
            -Blob       $scriptBlobName `
            -Destination $localScriptPath `
            -Context     $ctx `
            -Force       -ErrorAction Stop | Out-Null

        Write-RunbookLog "Script downloaded to: $localScriptPath"
        $scriptContent = Get-Content -Path $localScriptPath -Raw -ErrorAction Stop
    } catch {
        Write-Error "Failed to retrieve cleanup script '$scriptBlobName' from storage: $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-RunbookLog "Using embedded script content (injected at publish time)..."
    $b64 = if ($osType -eq 'Windows') { $embeddedWindowsScriptB64 } else { $embeddedLinuxScriptB64 }
    try {
        $scriptContent = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    } catch {
        Write-Error "Failed to decode embedded script content: $($_.Exception.Message)"
        exit 1
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Build Run Command parameters
# ─────────────────────────────────────────────────────────────────────────────
$reportTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$inGuestReportPath = if ($osType -eq 'Windows') {
    "C:\Windows\Temp\aws-cleanup-report-${reportTimestamp}.json"
} else {
    "/tmp/aws-cleanup-report-${reportTimestamp}.json"
}

if ($osType -eq 'Windows') {
    $commandId = 'RunPowerShellScript'

    # Append parameter invocation to the script content
    $dryRunFlag    = if ($DryRun) { '$true' } else { '$false' }
    $invokeWrapper = @"

`$params = @{
    DryRun     = $dryRunFlag
    Phase      = '$Phase'
    ReportPath = '$inGuestReportPath'
}
`$report = . { $scriptContent } @params
"@
    $runScript = $invokeWrapper

} else {
    $commandId = 'RunShellScript'

    # Bash: write script to temp, chmod, invoke
    $phaseFlag  = $Phase.ToLower().Replace('testmigration', 'test-migration')
    $dryRunFlag = if ($DryRun) { '--dry-run ' } else { '' }
    $runScript  = @"
#!/usr/bin/env bash
cat <<'CLEANUP_SCRIPT' > /tmp/invoke-aws-cleanup.sh
$scriptContent
CLEANUP_SCRIPT
chmod +x /tmp/invoke-aws-cleanup.sh
sudo /tmp/invoke-aws-cleanup.sh ${dryRunFlag}--phase $phaseFlag --report '$inGuestReportPath'
"@
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke Run Command
# ─────────────────────────────────────────────────────────────────────────────
Write-RunbookLog "Invoking Run Command on VM '$VMName' (OS: $osType, Phase: $Phase, DryRun: $DryRun)..."

try {
    $runResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName            $VMName `
        -CommandId         $commandId `
        -ScriptString      $runScript `
        -ErrorAction       Stop

    $runOutput  = Get-RunCmdStdOut $runResult $osType
    $runErrors  = Get-RunCmdStdErr $runResult $osType

    Write-RunbookLog "Run Command completed."

    if ($runOutput) {
        Write-RunbookLog "=== VM Output ==="
        Write-Output $runOutput
    }

    if ($runErrors -and $runErrors.Trim()) {
        Write-Warning "=== VM StdErr ==="
        Write-Warning $runErrors
    }

} catch {
    Write-Error "Run Command failed: $($_.Exception.Message)"
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Retrieve and parse the JSON report written inside the VM
# ─────────────────────────────────────────────────────────────────────────────
Write-RunbookLog "Retrieving JSON report from VM..."

# Parse on the VM and return only summary + error actions — avoids the 4 KB
# Run Command stdout cap that truncates large action arrays.
$reportReadScript = if ($osType -eq 'Windows') {
    "try { `$r = Get-Content -Path '$inGuestReportPath' -Raw -EA Stop | ConvertFrom-Json; [ordered]@{ ComputerName=`$r.ComputerName; Phase=`$r.Phase; DryRun=`$r.DryRun; Timestamp=`$r.Timestamp; Summary=`$r.Summary; ErrorActions=@(`$r.Actions | Where-Object { `$_.Status -eq 'Error' }) } | ConvertTo-Json -Depth 3 -Compress } catch { '{}' }"
} else {
    # Use python3 to extract summary + error actions in-VM — avoids the 4 KB
    # Run Command stdout cap that would truncate the full action array.
    "python3 -c `"import json; d=json.load(open('$inGuestReportPath')); ea=[a for a in d.get('actions',[]) if a.get('status')=='Error']; print(json.dumps({'hostname':d.get('hostname',''),'phase':d.get('phase',''),'dryRun':d.get('dryRun',False),'summary':d.get('summary',{}),'actions':ea}))`" 2>/dev/null || echo '{}'"
}

try {
    $reportResult = Invoke-AzVMRunCommand `
        -ResourceGroupName $ResourceGroupName `
        -VMName            $VMName `
        -CommandId         $commandId `
        -ScriptString      $reportReadScript `
        -ErrorAction       Stop

    $reportJson = Get-RunCmdStdOut $reportResult $osType

    if ($reportJson -and $reportJson.Trim()) {
        try {
            $report = $reportJson | ConvertFrom-Json

            Write-RunbookLog "════════════ Cleanup Report ════════════"
            Write-RunbookLog "  VM        : $($report.ComputerName ?? $report.hostname)"
            Write-RunbookLog "  Phase     : $($report.Phase ?? $report.phase)"
            Write-RunbookLog "  DryRun    : $($report.DryRun ?? $report.dryRun)"
            Write-RunbookLog "  Total     : $($report.Summary.Total ?? $report.summary.total)"
            Write-RunbookLog "  Completed : $($report.Summary.Completed ?? $report.summary.completed)"
            Write-RunbookLog "  Skipped   : $($report.Summary.Skipped ?? $report.summary.skipped)"
            Write-RunbookLog "  Errors    : $($report.Summary.Errors ?? $report.summary.errors)"
            Write-RunbookLog "══════════════════════════════════════"

            # Flag errors for review
            $errorActions = $report.Actions ?? $report.actions |
                Where-Object { $_.Status -eq 'Error' -or $_.status -eq 'Error' }
            if ($errorActions) {
                foreach ($ea in $errorActions) {
                    Write-Warning "ACTION ERROR: $($ea.Name ?? $ea.name) — $($ea.Detail ?? $ea.detail)"
                }
            }

            # Save a local copy to Automation worker
            if (-not (Test-Path $ReportOutputDir)) {
                New-Item -ItemType Directory -Path $ReportOutputDir -Force | Out-Null
            }
            $localReportFile = Join-Path $ReportOutputDir "aws-cleanup-${VMName}-${reportTimestamp}.json"
            $reportJson | Set-Content -Path $localReportFile -Encoding UTF8
            Write-RunbookLog "Report saved locally: $localReportFile"

        } catch {
            Write-Warning "Could not parse JSON report from VM: $($_.Exception.Message)"
            Write-Output "Raw report output:"
            Write-Output $reportJson
        }
    } else {
        Write-Warning "No report file found at '$inGuestReportPath' on the VM."
    }
} catch {
    Write-Warning "Could not retrieve report from VM: $($_.Exception.Message)"
}

Write-RunbookLog "Runbook complete. VM: $VMName | Phase: $Phase | DryRun: $DryRun"
