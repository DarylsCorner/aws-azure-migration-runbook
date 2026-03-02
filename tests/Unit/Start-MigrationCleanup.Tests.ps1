#Requires -Modules Pester
#Requires -Version 7.0
<#
.SYNOPSIS
    Pester 5 unit tests for runbook/Start-MigrationCleanup.ps1

.DESCRIPTION
    The runbook authenticates via Managed Identity, validates a VM exists,
    checks a snapshot gate on the OS disk, downloads the in-guest cleanup
    script from Blob Storage, runs it via Run Command, then retrieves and
    parses the JSON report.

    All Az module cmdlets are stubbed in BeforeAll (so tests run on machines
    without the Az module) and then mocked per-Context for scenario control.

    The runbook calls `exit 1` on any fatal error. Since dot-sourcing a script
    that calls `exit` would terminate the test process, the temp copy replaces
    every `exit 1` with `throw 'EXIT:1'`. Tests that expect a fatal abort use
    `| Should -Throw` and optionally check the message.

.NOTES
    Mandatory stub functions for Az cmdlets MUST be declared in the file-level
    BeforeAll BEFORE any Mock call targets them. Pester cannot mock a command
    that does not yet exist.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    # ─────────────────────────────────────────────────────────────────────────
    # Create temp copy — replace `exit 1` with throw so dot-sourcing is safe
    # ─────────────────────────────────────────────────────────────────────────
    $script:TestScript = [System.IO.Path]::ChangeExtension(
        [System.IO.Path]::GetTempFileName(), '.ps1')

    $src = Get-Content (Join-Path $PSScriptRoot '..\..\runbook\Start-MigrationCleanup.ps1') -Raw
    $src = $src -replace '\bexit 1\b', 'throw ''EXIT:1'''
    $src | Set-Content $script:TestScript -Encoding UTF8

    # ─────────────────────────────────────────────────────────────────────────
    # Az cmdlet stubs — exist in this scope so Pester can mock them.
    # [CmdletBinding()] is required so -ErrorAction Stop is accepted.
    # Parameter names must match what the runbook actually passes.
    # ─────────────────────────────────────────────────────────────────────────
    function Connect-AzAccount        { [CmdletBinding()] param([switch]$Identity) }
    function Set-AzContext            { [CmdletBinding()] param($SubscriptionId) }
    function Get-AzVM                 { [CmdletBinding()] param($ResourceGroupName, $Name) }
    function Get-AzDisk               { [CmdletBinding()] param($ResourceGroupName, $DiskName) }
    function New-AzStorageContext     { [CmdletBinding()] param($StorageAccountName, [switch]$UseConnectedAccount) }
    function Get-AzStorageBlobContent { [CmdletBinding()] param($Container, $Blob, $Destination, $Context, [switch]$Force) }
    function Invoke-AzVMRunCommand    { [CmdletBinding()] param($ResourceGroupName, $VMName, $CommandId, $ScriptString) }

    # ─────────────────────────────────────────────────────────────────────────
    # Helper: build a fake Invoke-AzVMRunCommand result
    # ─────────────────────────────────────────────────────────────────────────
    function New-RunCommandResult {
        param(
            [string]$StdOut = '',
            [string]$StdErr = ''
        )
        [PSCustomObject]@{
            Value = @(
                [PSCustomObject]@{ Code = 'ComponentStatus/StdOut/succeeded'; Message = $StdOut }
                [PSCustomObject]@{ Code = 'ComponentStatus/StdErr/succeeded'; Message = $StdErr }
            )
        }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Helper: build a fake Windows VM object
    # ─────────────────────────────────────────────────────────────────────────
    function New-MockWindowsVM {
        param([string]$DiskName = 'vm-osdisk')
        [PSCustomObject]@{
            Location       = 'eastus'
            StorageProfile = [PSCustomObject]@{
                OsDisk = [PSCustomObject]@{
                    OsType = 'Windows'
                    Name   = $DiskName
                }
            }
        }
    }

    function New-MockLinuxVM {
        [PSCustomObject]@{
            Location       = 'eastus'
            StorageProfile = [PSCustomObject]@{
                OsDisk = [PSCustomObject]@{
                    OsType = 'Linux'
                    Name   = 'linux-osdisk'
                }
            }
        }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Valid cleanup report JSON (Windows format)
    # ─────────────────────────────────────────────────────────────────────────
    $script:SampleReportJson = @{
        ComputerName = 'TEST-VM'
        Phase        = 'TestMigration'
        DryRun       = $false
        Summary      = @{ Total = 20; Completed = 15; Skipped = 5; Errors = 0; DryRun = 0 }
        Actions      = @()
    } | ConvertTo-Json -Depth 4

    # ─────────────────────────────────────────────────────────────────────────
    # Set-SafeMocks — happy-path baseline:
    #   auth succeeds, Windows VM found, snapshot tag present, script downloads,
    #   Run Command succeeds, report JSON returned
    # ─────────────────────────────────────────────────────────────────────────
    function Set-SafeMocks {
        Mock Connect-AzAccount        { }
        Mock Set-AzContext            { }
        Mock Get-AzVM                 { New-MockWindowsVM }
        Mock Get-AzDisk               {
            [PSCustomObject]@{ Tags = @{ MigrationSnapshot = 'true' } }
        }
        Mock New-AzStorageContext     {
            [PSCustomObject]@{ StorageAccountName = 'teststorage' }
        }
        Mock Get-AzStorageBlobContent { }
        Mock Get-Content              { '# fake cleanup script content' }
        Mock Invoke-AzVMRunCommand    {
            if ($ScriptString -match 'PSVersionTable') {
                New-RunCommandResult -StdOut '5.1' -StdErr ''
            } else {
                New-RunCommandResult -StdOut $script:SampleReportJson -StdErr ''
            }
        }
        Mock Test-Path                { $false }
        Mock New-Item                 { [PSCustomObject]@{ FullName = 'mocked' } }
        Mock Set-Content              { }
        Mock Write-Output             { }
        Mock Write-Warning            { }
        Mock Write-Error              { }   # no-op — script's throw 'EXIT:1' propagates cleanly
    }

    # ─────────────────────────────────────────────────────────────────────────
    # Default runbook parameter set (all mandatory fields satisfied)
    # ─────────────────────────────────────────────────────────────────────────
    $script:DefaultParams = @{
        SubscriptionId                 = 'aaaabbbb-cccc-dddd-eeee-ffffffffffff'
        ResourceGroupName              = 'rg-migration-test'
        VMName                         = 'test-vm-01'
        Phase                          = 'TestMigration'
        DryRun                         = $false
        CleanupScriptStorageAccountName = 'mystorageaccount'
        CleanupScriptContainer         = 'migration-scripts'
        RequireSnapshotTag             = $false   # bypass by default; opt-in per test
        ReportOutputDir                = "$env:TEMP\pester-runbook-test"
    }

    # ─────────────────────────────────────────────────────────────────────────
    # $script:Run — dot-sources the temp script with the given params
    # ─────────────────────────────────────────────────────────────────────────
    $script:Run = {
        param([hashtable]$Overrides = @{})
        $p = $script:DefaultParams.Clone()
        foreach ($k in $Overrides.Keys) { $p[$k] = $Overrides[$k] }
        . $script:TestScript @p
    }
}

AfterAll {
    Remove-Item $script:TestScript -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# GROUP 1 – Authentication
# =============================================================================
Describe "Authentication" {

    Context "Happy path — Managed Identity auth succeeds" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run
        }

        It "calls Connect-AzAccount with -Identity" {
            Should -Invoke Connect-AzAccount -ParameterFilter {
                $Identity -eq $true
            } -Scope Context
        }

        It "calls Set-AzContext with the subscription ID" {
            Should -Invoke Set-AzContext -ParameterFilter {
                $SubscriptionId -eq 'aaaabbbb-cccc-dddd-eeee-ffffffffffff'
            } -Scope Context
        }
    }

    Context "Auth failure — Connect-AzAccount throws" {
        BeforeAll {
            Set-SafeMocks
            Mock Connect-AzAccount { throw 'MSI endpoint not reachable' }
        }

        It "aborts with EXIT:1" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }

        It "emits Write-Error before aborting" {
            { . $script:Run } | Should -Throw
            Should -Invoke Write-Error -Scope Context
        }
    }
}

# =============================================================================
# GROUP 2 – VM lookup and OS detection
# =============================================================================
Describe "VM lookup and OS detection" {

    Context "Windows VM found" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzVM { New-MockWindowsVM }
            . $script:Run
        }

        It "calls Get-AzVM with the correct ResourceGroup and VMName" {
            Should -Invoke Get-AzVM -ParameterFilter {
                $ResourceGroupName -eq 'rg-migration-test' -and $Name -eq 'test-vm-01'
            } -Scope Context
        }

        It "uses RunPowerShellScript command ID (Windows path)" {
            Should -Invoke Invoke-AzVMRunCommand -ParameterFilter {
                $CommandId -eq 'RunPowerShellScript'
            } -Scope Context
        }

        It "downloads Invoke-AWSCleanup.ps1 from blob storage" {
            Should -Invoke Get-AzStorageBlobContent -ParameterFilter {
                $Blob -eq 'Invoke-AWSCleanup.ps1'
            } -Scope Context
        }
    }

    Context "Linux VM found" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzVM { New-MockLinuxVM }
            . $script:Run
        }

        It "uses RunShellScript command ID (Linux path)" {
            Should -Invoke Invoke-AzVMRunCommand -ParameterFilter {
                $CommandId -eq 'RunShellScript'
            } -Scope Context
        }

        It "downloads invoke-aws-cleanup.sh from blob storage" {
            Should -Invoke Get-AzStorageBlobContent -ParameterFilter {
                $Blob -eq 'invoke-aws-cleanup.sh'
            } -Scope Context
        }
    }

    Context "VM not found — Get-AzVM throws" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzVM { throw "VM 'test-vm-01' not found" }
        }

        It "aborts with EXIT:1" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }

        It "emits Write-Error before aborting" {
            { . $script:Run } | Should -Throw
            Should -Invoke Write-Error -Scope Context
        }
    }
}

# =============================================================================
# GROUP 3 – Snapshot gate
# =============================================================================
Describe "Snapshot gate" {

    Context "RequireSnapshotTag=true, tag is present" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzDisk {
                [PSCustomObject]@{ Tags = @{ MigrationSnapshot = 'true' } }
            }
            . $script:Run -Overrides @{ RequireSnapshotTag = $true }
        }

        It "calls Get-AzDisk" {
            Should -Invoke Get-AzDisk -Scope Context
        }

        It "proceeds to Run Command (gate passed)" {
            Should -Invoke Invoke-AzVMRunCommand -Scope Context
        }
    }

    Context "RequireSnapshotTag=true, tag is missing" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzDisk {
                [PSCustomObject]@{ Tags = @{ } }
            }
        }

        It "aborts with EXIT:1" {
            { . $script:Run -Overrides @{ RequireSnapshotTag = $true } } |
                Should -Throw 'EXIT:1'
        }

        It "does NOT invoke Run Command" {
            { . $script:Run -Overrides @{ RequireSnapshotTag = $true } } |
                Should -Throw
            Should -Invoke Invoke-AzVMRunCommand -Times 0 -Exactly -Scope Context
        }
    }

    Context "RequireSnapshotTag=true, Get-AzDisk throws" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzDisk { throw 'Disk not found' }
        }

        It "aborts with EXIT:1" {
            { . $script:Run -Overrides @{ RequireSnapshotTag = $true } } |
                Should -Throw 'EXIT:1'
        }
    }

    Context "RequireSnapshotTag=false — gate bypassed" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run -Overrides @{ RequireSnapshotTag = $false }
        }

        It "never calls Get-AzDisk (skipped entirely)" {
            Should -Invoke Get-AzDisk -Times 0 -Exactly -Scope Context
        }

        It "still proceeds to Run Command" {
            Should -Invoke Invoke-AzVMRunCommand -Scope Context
        }

        It "emits a warning about bypassing the gate" {
            Should -Invoke Write-Warning -Scope Context
        }
    }
}

# =============================================================================
# GROUP 4 – Script download from Blob Storage
# =============================================================================
Describe "Script download from Blob Storage" {

    Context "Happy path — blob download succeeds" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run
        }

        It "creates a storage context for the specified account" {
            Should -Invoke New-AzStorageContext -ParameterFilter {
                $StorageAccountName -eq 'mystorageaccount'
            } -Scope Context
        }

        It "calls Get-AzStorageBlobContent targeting the correct container" {
            Should -Invoke Get-AzStorageBlobContent -ParameterFilter {
                $Container -eq 'migration-scripts'
            } -Scope Context
        }
    }

    Context "Blob download fails — Get-AzStorageBlobContent throws" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzStorageBlobContent { throw 'Blob not found' }
        }

        It "aborts with EXIT:1" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }

        It "does NOT run the cleanup script (only the PS version check call fires)" {
            { . $script:Run } | Should -Throw
            # ParameterFilter excludes the PS-version-check call (ScriptString contains 'PSVersionTable');
            # this asserts that no cleanup or report Run Command was ever invoked.
            Should -Invoke Invoke-AzVMRunCommand -Times 0 -Exactly -Scope Context -ParameterFilter {
                $ScriptString -notmatch 'PSVersionTable'
            }
        }
    }
}

# =============================================================================
# GROUP 5 – Run Command invocation
# =============================================================================
Describe "Run Command invocation" {

    Context "Happy path — Run Command succeeds" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run
        }

        It "calls Invoke-AzVMRunCommand three times (PS version check + run + report retrieval)" {
            Should -Invoke Invoke-AzVMRunCommand -Times 3 -Exactly -Scope Context
        }

        It "all Run Command calls target the correct VM" {
            Should -Invoke Invoke-AzVMRunCommand -ParameterFilter {
                $VMName -eq 'test-vm-01' -and $ResourceGroupName -eq 'rg-migration-test'
            } -Scope Context
        }
    }

    Context "Run Command execution fails" {
        BeforeAll {
            Set-SafeMocks
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check passes
                } elseif ($script:CallCount -eq 2) {
                    throw 'Run Command timed out'   # cleanup script fails
                }
                New-RunCommandResult -StdOut '' -StdErr ''
            }
        }

        It "aborts with EXIT:1 when the cleanup Run Command throws" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }
    }

    Context "VM has StdErr output but Run Command does not throw" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-AzVMRunCommand {
                if ($ScriptString -match 'PSVersionTable') {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''
                } else {
                    New-RunCommandResult -StdOut $script:SampleReportJson -StdErr 'non-fatal warning from VM'
                }
            }
            . $script:Run
        }

        It "emits Write-Warning for the StdErr content" {
            Should -Invoke Write-Warning -Scope Context
        }

        It "still completes (does not abort)" {
            Should -Invoke Invoke-AzVMRunCommand -Times 3 -Exactly -Scope Context
        }
    }
}

# =============================================================================
# GROUP 6 – Report parsing
# =============================================================================
Describe "Report parsing" {

    Context "Valid JSON report returned from VM" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run
        }

        It "calls Set-Content to save local report copy" {
            Should -Invoke Set-Content -Scope Context
        }

        It "creates the report output directory if it does not exist" {
            Should -Invoke New-Item -Scope Context
        }
    }

    Context "No report content returned (empty StdOut on third call)" {
        BeforeAll {
            Set-SafeMocks
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check
                } elseif ($script:CallCount -eq 3) {
                    New-RunCommandResult -StdOut '' -StdErr ''       # report retrieval returns empty
                } else {
                    New-RunCommandResult -StdOut 'cleanup output' -StdErr ''
                }
            }
            . $script:Run
        }

        It "emits Write-Warning about missing report" {
            Should -Invoke Write-Warning -Scope Context
        }

        It "does NOT call Set-Content (no report to save)" {
            Should -Invoke Set-Content -Times 0 -Exactly -Scope Context
        }
    }

    Context "Third Run Command returns malformed JSON" {
        BeforeAll {
            Set-SafeMocks
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''              # PS version check
                } elseif ($script:CallCount -eq 3) {
                    New-RunCommandResult -StdOut 'this is not json {{{' -StdErr ''   # malformed report
                } else {
                    New-RunCommandResult -StdOut 'cleanup output' -StdErr ''
                }
            }
            . $script:Run
        }

        It "emits Write-Warning about parse failure" {
            Should -Invoke Write-Warning -Scope Context
        }
    }

    Context "Report contains Error-status actions" {
        BeforeAll {
            Set-SafeMocks
            $errorReport = @{
                ComputerName = 'TEST-VM'
                Phase        = 'Cutover'
                DryRun       = $false
                Summary      = @{ Total = 5; Completed = 3; Skipped = 1; Errors = 1; DryRun = 0 }
                Actions      = @(
                    @{ Name = 'Uninstall: AWS SSM Agent'; Status = 'Error'; Detail = 'Access denied' }
                )
            } | ConvertTo-Json -Depth 4

            Mock Invoke-AzVMRunCommand {
                if ($ScriptString -match 'PSVersionTable') {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''
                } else {
                    New-RunCommandResult -StdOut $errorReport -StdErr ''
                }
            }
            . $script:Run
        }

        It "emits Write-Warning for each errored action" {
            Should -Invoke Write-Warning -Scope Context
        }
    }
}

# =============================================================================
# GROUP 7 – DryRun and Phase flag propagation
# =============================================================================
Describe "DryRun and Phase flag propagation" {

    Context "DryRun=true is passed to the VM script" {
        BeforeAll {
            Set-SafeMocks
            $script:CapturedScript = $null
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check
                } else {
                    if ($script:CallCount -eq 2) { $script:CapturedScript = $ScriptString }
                    New-RunCommandResult -StdOut $script:SampleReportJson
                }
            }
            . $script:Run -Overrides @{ DryRun = $true }
        }

        It "the ScriptString passed to Run Command contains `$true for DryRun" {
            $script:CapturedScript | Should -Match '\$true'
        }

        It "the ScriptString does not contain `$false for DryRun" {
            # Match the DryRun assignment specifically (not any random $false)
            $script:CapturedScript | Should -Not -Match 'DryRun\s*=\s*\$false'
        }
    }

    Context "DryRun=false is the default" {
        BeforeAll {
            Set-SafeMocks
            $script:CapturedScript = $null
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check
                } else {
                    if ($script:CallCount -eq 2) { $script:CapturedScript = $ScriptString }
                    New-RunCommandResult -StdOut $script:SampleReportJson
                }
            }
            . $script:Run -Overrides @{ DryRun = $false }
        }

        It "the ScriptString contains `$false for DryRun" {
            $script:CapturedScript | Should -Match 'DryRun\s*=\s*\$false'
        }
    }

    Context "Phase=Cutover is propagated" {
        BeforeAll {
            Set-SafeMocks
            $script:CapturedScript = $null
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check
                } else {
                    if ($script:CallCount -eq 2) { $script:CapturedScript = $ScriptString }
                    New-RunCommandResult -StdOut $script:SampleReportJson
                }
            }
            . $script:Run -Overrides @{ Phase = 'Cutover' }
        }

        It "the ScriptString contains 'Cutover'" {
            $script:CapturedScript | Should -Match 'Cutover'
        }
    }

    Context "Phase=TestMigration is propagated" {
        BeforeAll {
            Set-SafeMocks
            $script:CapturedScript = $null
            $script:CallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:CallCount++
                if ($script:CallCount -eq 1) {
                    New-RunCommandResult -StdOut '5.1' -StdErr ''   # PS version check
                } else {
                    if ($script:CallCount -eq 2) { $script:CapturedScript = $ScriptString }
                    New-RunCommandResult -StdOut $script:SampleReportJson
                }
            }
            . $script:Run -Overrides @{ Phase = 'TestMigration' }
        }

        It "the ScriptString contains 'TestMigration'" {
            $script:CapturedScript | Should -Match 'TestMigration'
        }
    }
}

# =============================================================================
# GROUP 8 – Report directory and file management
# =============================================================================
Describe "Report directory and file management" {

    Context "ReportOutputDir does not exist — directory is created" {
        BeforeAll {
            Set-SafeMocks
            Mock Test-Path { $false }
            . $script:Run
        }

        It "calls New-Item to create the report directory" {
            Should -Invoke New-Item -Scope Context
        }
    }

    Context "ReportOutputDir already exists — New-Item not called" {
        BeforeAll {
            Set-SafeMocks
            Mock Test-Path { $true }
            . $script:Run
        }

        It "does NOT call New-Item (directory already exists)" {
            Should -Invoke New-Item -Times 0 -Exactly -Scope Context
        }
    }

    Context "Set-Content receives report JSON at the expected path" {
        BeforeAll {
            Set-SafeMocks
            $script:SavedPath = $null
            Mock Test-Path { $true }
            Mock Set-Content {
                param($Path, $Value, $Encoding)
                $script:SavedPath = $Path
            }
            . $script:Run -Overrides @{ ReportOutputDir = 'C:\Temp\reports' }
        }

        It "saved path is under the specified ReportOutputDir" {
            $script:SavedPath | Should -Match '^C:\\Temp\\reports'
        }

        It "saved filename contains the VMName" {
            $script:SavedPath | Should -Match 'test-vm-01'
        }
    }
}

# =============================================================================
# GROUP 9 – PowerShell version gate  (Windows pre-flight)
# =============================================================================
Describe "PowerShell version gate" {

    # ── PS 4.0: gate fires ─────────────────────────────────────────────────
    Context "PS 4.0 detected — gate fires, abort before cleanup" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-AzVMRunCommand {
                New-RunCommandResult -StdOut '4.0' -StdErr ''
            }
        }

        It "aborts with EXIT:1" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }

        It "emits Write-Error containing 'POWERSHELL VERSION TOO LOW'" {
            { . $script:Run } | Should -Throw
            Should -Invoke Write-Error -ParameterFilter {
                $Message -match 'POWERSHELL VERSION TOO LOW'
            } -Scope Context
        }

        It "cleanup Run Command is never invoked — only the version-check call fires" {
            { . $script:Run } | Should -Throw
            # Only the PS-version-check call (ScriptString contains 'PSVersionTable') should have run.
            # No cleanup or report Run Commands should have been issued.
            Should -Invoke Invoke-AzVMRunCommand -Times 0 -Exactly -Scope Context -ParameterFilter {
                $ScriptString -notmatch 'PSVersionTable'
            }
        }
    }

    # ── PS 5.0: below the 5.1 boundary, gate fires ────────────────────────
    Context "PS 5.0 detected — below 5.1 threshold, gate fires" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-AzVMRunCommand {
                New-RunCommandResult -StdOut '5.0' -StdErr ''
            }
        }

        It "aborts with EXIT:1 for PS 5.0" {
            { . $script:Run } | Should -Throw 'EXIT:1'
        }
    }

    # ── PS 5.1: exactly at threshold, gate passes ─────────────────────────
    Context "PS 5.1 detected — gate passes, cleanup proceeds" {
        BeforeAll {
            Set-SafeMocks
            # Set-SafeMocks already returns '5.1' for PSVersionTable calls
            . $script:Run
        }

        It "does not abort — completes all three Run Command calls" {
            Should -Invoke Invoke-AzVMRunCommand -Times 3 -Exactly -Scope Context
        }

        It "does not emit Write-Error" {
            Should -Invoke Write-Error -Times 0 -Exactly -Scope Context
        }
    }

    # ── PS 7.x: well above threshold, gate passes ─────────────────────────
    Context "PS 7.4 detected — gate passes" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-AzVMRunCommand {
                if ($ScriptString -match 'PSVersionTable') {
                    New-RunCommandResult -StdOut '7.4' -StdErr ''
                } else {
                    New-RunCommandResult -StdOut $script:SampleReportJson -StdErr ''
                }
            }
            . $script:Run
        }

        It "proceeds normally — no abort" {
            Should -Invoke Invoke-AzVMRunCommand -Times 3 -Exactly -Scope Context
        }
    }

    # ── Version check throws (network/timeout): warning, cleanup proceeds ──
    Context "PS version check throws — warning emitted, cleanup proceeds" {
        BeforeAll {
            Set-SafeMocks
            $script:PSGateCallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:PSGateCallCount++
                if ($script:PSGateCallCount -eq 1) {
                    throw 'Run Command timed out on version check'
                }
                New-RunCommandResult -StdOut $script:SampleReportJson -StdErr ''
            }
            . $script:Run
        }

        It "emits Write-Warning about undetected PS version" {
            Should -Invoke Write-Warning -Scope Context
        }

        It "proceeds to run cleanup (calls Invoke-AzVMRunCommand again after the catch)" {
            Should -Invoke Invoke-AzVMRunCommand -Times 3 -Exactly -Scope Context
        }

        It "does NOT abort — no EXIT:1" {
            Should -Invoke Write-Error -Times 0 -Exactly -Scope Context
        }
    }

    # ── Linux VM: PS version gate is skipped entirely ─────────────────────
    Context "Linux VM — PS version gate skipped entirely" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-AzVM { New-MockLinuxVM }
            $script:FirstScriptString = $null
            $script:LinuxCallCount = 0
            Mock Invoke-AzVMRunCommand {
                $script:LinuxCallCount++
                if ($script:LinuxCallCount -eq 1) { $script:FirstScriptString = $ScriptString }
                New-RunCommandResult -StdOut $script:SampleReportJson -StdErr ''
            }
            . $script:Run
        }

        It "first Run Command does NOT query PSVersionTable" {
            $script:FirstScriptString | Should -Not -Match 'PSVersionTable'
        }

        It "calls Invoke-AzVMRunCommand exactly twice — no version check call" {
            Should -Invoke Invoke-AzVMRunCommand -Times 2 -Exactly -Scope Context
        }
    }
}
