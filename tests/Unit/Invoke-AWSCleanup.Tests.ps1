#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Pester 5 behavioural tests for windows/Invoke-AWSCleanup.ps1

.DESCRIPTION
    Architecture:
      - A file-level BeforeAll strips #Requires -RunAsAdministrator from a temp
        copy of the script so it can be dot-sourced without an elevated session.
        (Every admin-touching cmdlet is mocked, so elevation is unnecessary.)
      - Each Context block's BeforeAll:
          1. Calls Set-SafeMocks  (mocks all system cmdlets to safe no-ops)
          2. Adds scenario-specific mock overrides
          3. Resets $script:Actions
          4. Dot-sources the temp script DIRECTLY — this is key: dot-sourcing
             in a BeforeAll runs in that block's scope so helper functions and
             $DryRun are visible to the It blocks that follow.
      - It blocks assert on $script:Actions (filtered by Name) and Should -Invoke.

    Run:
        Invoke-Pester .\tests\Unit\Invoke-AWSCleanup.Tests.ps1 -Output Detailed
        .\tests\Run-Tests.ps1 -Output Detailed
#>
Set-StrictMode -Version Latest

# ─────────────────────────────────────────────────────────────────────────────
# File-level setup / teardown
# ─────────────────────────────────────────────────────────────────────────────
BeforeAll {
    $originalScript = Resolve-Path "$PSScriptRoot\..\..\windows\Invoke-AWSCleanup.ps1"

    # Create an admin-check-free copy for dot-sourcing in non-elevated test sessions.
    # The #Requires check is irrelevant here because every admin cmdlet is mocked.
    $raw     = [System.IO.File]::ReadAllText($originalScript)
    $stripped = $raw -replace '(?m)^#Requires\s+-RunAsAdministrator\s*(\r?\n)?', ''
    $script:TestScript = [System.IO.Path]::Combine(
        [System.IO.Path]::GetTempPath(),
        "Invoke-AWSCleanup-pester-$([System.Guid]::NewGuid()).ps1"
    )
    [System.IO.File]::WriteAllText($script:TestScript, $stripped, [System.Text.Encoding]::UTF8)

    # ── Set-SafeMocks ─────────────────────────────────────────────────────────
    # Mock EVERY system-touching cmdlet to a safe no-op / "nothing exists".
    # Individual Context blocks override specific mocks for their scenario.
    function Set-SafeMocks {
        Mock Get-Service              { return $null }
        Mock Stop-Service             { }
        Mock Start-Service            { }
        Mock Set-Service              { }
        Mock Get-ItemProperty         { return $null }
        Mock Start-Process            { }
        Mock Test-Path                { return $false }
        Mock Get-Content              { return @() }
        Mock Set-Content              { }
        Mock Remove-Item              { }
        Mock New-Item                 { }
        Mock Get-ScheduledTask        { return $null }
        Mock Unregister-ScheduledTask { }
        Mock Get-ChildItem            { return @() }
        Mock Measure-Object           { return [PSCustomObject]@{ Sum = 0 } }
    }

    # ── DotSource helper ─────────────────────────────────────────────────────
    # Runs the test-safe script copy in the CALLER's scope (dot-source semantics
    # propagate when this scriptblock is dot-sourced from a BeforeAll).
    # Usage in each Context BeforeAll:
    #     . $script:Run [-DryRun] [-Phase Cutover] [-SkipAzureAgentCheck]
    $script:Run = {
        param(
            [switch]$DryRun,
            [ValidateSet('TestMigration','Cutover')]
            [string]$Phase = 'TestMigration',
            [switch]$SkipAzureAgentCheck
        )
        $script:Actions = [System.Collections.Generic.List[hashtable]]::new()
        $rpt = [System.IO.Path]::Combine($TestDrive, "rpt-$([System.Guid]::NewGuid()).json")
        if ($DryRun) {
            . $script:TestScript -DryRun -Phase $Phase `
                -SkipAzureAgentCheck:$SkipAzureAgentCheck -ReportPath $rpt
        } else {
            . $script:TestScript -Phase $Phase `
                -SkipAzureAgentCheck:$SkipAzureAgentCheck -ReportPath $rpt
        }
    }

    # ── Convenience: get a specific action from the last script run ───────────
    function Get-Action {
        param([string]$Like)
        $script:Actions | Where-Object { $_.Name -like $Like } | Select-Object -First 1
    }
}

AfterAll {
    if ($script:TestScript -and (Test-Path -LiteralPath $script:TestScript)) {
        [System.IO.File]::Delete($script:TestScript)
    }
}

# =============================================================================
# GROUP 1 – DryRun mode (whole-script invariants)
# =============================================================================
Describe "DryRun mode — whole-script invariants" {

    Context "All components present, DryRun=true, Phase=Cutover" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service     { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Test-Path       { return $true }
            Mock Get-Content     { '169.254.169.254 instance-data.ec2.internal' }
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    DisplayName     = 'Amazon SSM Agent'
                    DisplayVersion  = '3.2.0'
                    UninstallString = 'MsiExec.exe /x {AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}'
                }
            }
            Mock Get-ScheduledTask {
                [PSCustomObject]@{ TaskName = 'Amazon EC2Launch - Instance Initialization'; TaskPath = '\'; State = 'Ready' }
            }
            . $script:Run -DryRun -Phase Cutover -SkipAzureAgentCheck
        }

        It "produces at least one action" {
            $script:Actions.Count | Should -BeGreaterThan 0
        }

        It "zero Completed actions" {
            @($script:Actions | Where-Object Status -eq 'Completed').Count | Should -Be 0
        }

        It "zero Error actions" {
            @($script:Actions | Where-Object Status -eq 'Error').Count | Should -Be 0
        }

        It "every action is DryRun or Skipped" {
            $bad = $script:Actions | Where-Object { $_.Status -notin 'DryRun', 'Skipped' }
            $bad | Should -BeNullOrEmpty
        }

        It "Stop-Service never called" {
            Should -Invoke Stop-Service -Times 0 -Exactly
        }

        It "Remove-Item never called" {
            Should -Invoke Remove-Item -Times 0 -Exactly
        }

        It "Start-Process (msiexec) never called" {
            Should -Invoke Start-Process -Times 0 -Exactly
        }

        It "Unregister-ScheduledTask never called" {
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        }
    }
}

# =============================================================================
# GROUP 2 – Service disabling (Section 2)
# =============================================================================
Describe "Section 2 — Service disabling" {

    Context "All services absent (Get-Service returns null)" {
        BeforeAll {
            Set-SafeMocks
            # Default Get-Service mock already returns $null
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "SSM Agent action is Skipped" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Status | Should -Be 'Skipped'
        }

        It "CloudWatch Agent action is Skipped" {
            (Get-Action -Like 'Disable Service: AWS CloudWatch Agent').Status | Should -Be 'Skipped'
        }

        It "Stop-Service never called" {
            Should -Invoke Stop-Service -Times 0 -Exactly
        }
    }

    Context "Services running + DryRun=true" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
            . $script:Run -DryRun -Phase TestMigration -SkipAzureAgentCheck
        }

        It "SSM Agent action is DryRun" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Status | Should -Be 'DryRun'
        }

        It "CloudWatch Agent action is DryRun" {
            (Get-Action -Like 'Disable Service: AWS CloudWatch Agent').Status | Should -Be 'DryRun'
        }

        It "Stop-Service never called in DryRun mode" {
            Should -Invoke Stop-Service -Times 0 -Exactly
        }
    }

    Context "Service running + live run — happy path" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Stop-Service { }
            Mock Set-Service  { }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "SSM Agent action is Completed" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Status | Should -Be 'Completed'
        }

        It "Stop-Service called at least once (once per running service)" {
            # All 8 services are mocked as running → Stop-Service called 8 times
            Should -Invoke Stop-Service -Times 1 -Scope Context
        }

        It "Set-Service called at least once" {
            Should -Invoke Set-Service -Times 1 -Scope Context
        }
    }

    Context "Service already Stopped — Stop-Service not re-called" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service { [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
            Mock Stop-Service { }
            Mock Set-Service  { }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "SSM Agent action is still Completed" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Status | Should -Be 'Completed'
        }

        It "Stop-Service is NOT called for already-stopped services" {
            Should -Invoke Stop-Service -Times 0 -Exactly
        }
    }

    Context "Stop-Service throws → Error status" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service { [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' } }
            Mock Stop-Service { throw 'Access is denied' }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "SSM Agent action is Error" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Status | Should -Be 'Error'
        }

        It "Error detail contains exception message" {
            (Get-Action -Like 'Disable Service: AWS SSM Agent').Detail | Should -Match 'Access is denied'
        }
    }
}

# =============================================================================
# GROUP 3 – Registry cleanup (Section 6)
# =============================================================================
Describe "Section 6 — Registry cleanup" {

    Context "Registry keys absent" {
        BeforeAll {
            Set-SafeMocks
            # Default Test-Path mock returns $false
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2ConfigService registry action is Skipped" {
            (Get-Action -Like 'Remove Registry: EC2ConfigService registry hive').Status | Should -Be 'Skipped'
        }

        It "SSM registry action is Skipped" {
            (Get-Action -Like 'Remove Registry: SSM Agent registry hive').Status | Should -Be 'Skipped'
        }

        It "Remove-Item never called" {
            Should -Invoke Remove-Item -Times 0 -Exactly
        }
    }

    Context "Registry keys present + DryRun=true" {
        BeforeAll {
            Set-SafeMocks
            Mock Test-Path { return $true }
            . $script:Run -DryRun -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2ConfigService registry action is DryRun" {
            (Get-Action -Like 'Remove Registry: EC2ConfigService registry hive').Status | Should -Be 'DryRun'
        }

        It "Remove-Item never called in DryRun" {
            Should -Invoke Remove-Item -Times 0 -Exactly
        }
    }

    Context "Registry keys present + live run" {
        BeforeAll {
            Set-SafeMocks
            Mock Test-Path   { return $true }
            Mock Remove-Item { }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2ConfigService registry action is Completed" {
            (Get-Action -Like 'Remove Registry: EC2ConfigService registry hive').Status | Should -Be 'Completed'
        }

        It "Remove-Item called at least once for registry cleanup" {
            Should -Invoke Remove-Item -Times 1 -Scope Context
        }
    }

    Context "Remove-Item throws on registry key → Error" {
        BeforeAll {
            Set-SafeMocks
            Mock Test-Path   { return $true }
            Mock Remove-Item { throw 'Registry key is locked' }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2ConfigService registry action is Error" {
            (Get-Action -Like 'Remove Registry: EC2ConfigService registry hive').Status | Should -Be 'Error'
        }
    }
}

# =============================================================================
# GROUP 4 – Hosts file cleanup (Section 4)
# =============================================================================
Describe "Section 4 — Hosts file cleanup" {

    Context "AWS pattern not in hosts file" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Content { return @('127.0.0.1 localhost', '::1 localhost') }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "Hosts file action is Skipped" {
            (Get-Action -Like 'Hosts File: AWS EC2 internal metadata hostname').Status | Should -Be 'Skipped'
        }

        It "Set-Content never called" {
            Should -Invoke Set-Content -Times 0 -Exactly
        }
    }

    Context "AWS pattern present + DryRun=true" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Content { '169.254.169.254 instance-data.ec2.internal' }
            . $script:Run -DryRun -Phase TestMigration -SkipAzureAgentCheck
        }

        It "Hosts file action is DryRun" {
            (Get-Action -Like 'Hosts File: AWS EC2 internal metadata hostname').Status | Should -Be 'DryRun'
        }

        It "Set-Content never called in DryRun" {
            Should -Invoke Set-Content -Times 0 -Exactly
        }
    }

    Context "AWS pattern present + live run" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Content { '127.0.0.1 localhost' + "`n" + '169.254.169.254 instance-data.ec2.internal' }
            Mock Set-Content { }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "Hosts file action is Completed" {
            (Get-Action -Like 'Hosts File: AWS EC2 internal metadata hostname').Status | Should -Be 'Completed'
        }

        It "Set-Content called to rewrite the hosts file" {
            Should -Invoke Set-Content -Times 1 -Scope Context
        }
    }
}

# =============================================================================
# GROUP 5 – Scheduled task removal (Section 5)
# =============================================================================
Describe "Section 5 — Scheduled task removal" {

    Context "Tasks not found" {
        BeforeAll {
            Set-SafeMocks
            # Default Get-ScheduledTask mock returns $null
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2Launch task action is Skipped" {
            (Get-Action -Like 'Remove Task: Amazon EC2Launch - Instance Initialization').Status |
                Should -Be 'Skipped'
        }

        It "Unregister-ScheduledTask never called" {
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        }
    }

    Context "Tasks present + DryRun=true" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ScheduledTask {
                [PSCustomObject]@{
                    TaskName = 'Amazon EC2Launch - Instance Initialization'
                    TaskPath = '\'
                    State    = 'Ready'
                }
            }
            . $script:Run -DryRun -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2Launch task action is DryRun" {
            (Get-Action -Like 'Remove Task: Amazon EC2Launch - Instance Initialization').Status |
                Should -Be 'DryRun'
        }

        It "Unregister-ScheduledTask never called in DryRun" {
            Should -Invoke Unregister-ScheduledTask -Times 0 -Exactly
        }
    }

    Context "Task present + live run" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ScheduledTask {
                [PSCustomObject]@{
                    TaskName = 'Amazon EC2Launch - Instance Initialization'
                    TaskPath = '\'
                    State    = 'Ready'
                }
            }
            Mock Unregister-ScheduledTask { }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "EC2Launch task action is Completed" {
            (Get-Action -Like 'Remove Task: Amazon EC2Launch - Instance Initialization').Status |
                Should -Be 'Completed'
        }

        It "Unregister-ScheduledTask called at least once" {
            Should -Invoke Unregister-ScheduledTask -Times 1 -Scope Context
        }
    }
}

# =============================================================================
# GROUP 6 – Phase gating: Section 7 MSI uninstalls (Cutover-only)
# =============================================================================
Describe "Section 7 — Phase gating for MSI uninstalls" {

    Context "Phase=TestMigration — uninstalls are deferred" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    DisplayName     = 'Amazon SSM Agent'
                    DisplayVersion  = '3.2.0'
                    UninstallString = 'MsiExec.exe /x {AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}'
                }
            }
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "MSI Uninstalls action exists and is Skipped" {
            $a = Get-Action -Like 'MSI Uninstalls'
            $a | Should -Not -BeNullOrEmpty
            $a.Status | Should -Be 'Skipped'
        }

        It "Detail mentions 'Cutover'" {
            (Get-Action -Like 'MSI Uninstalls').Detail | Should -Match 'Cutover'
        }

        It "Start-Process (msiexec) not called in TestMigration" {
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

    Context "Phase=Cutover — uninstalls execute" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    DisplayName     = 'Amazon SSM Agent'
                    DisplayVersion  = '3.2.0'
                    UninstallString = 'MsiExec.exe /x {AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}'
                }
            }
            Mock Start-Process { }
            . $script:Run -Phase Cutover -SkipAzureAgentCheck
        }

        It "no deferred MSI Uninstalls action exists" {
            Get-Action -Like 'MSI Uninstalls' | Should -BeNullOrEmpty
        }

        It "SSM Agent uninstall action is Completed" {
            (Get-Action -Like 'Uninstall: AWS SSM Agent').Status | Should -Be 'Completed'
        }

        It "Start-Process called for msiexec" {
            Should -Invoke Start-Process -Times 1 -Scope Context
        }
    }

    Context "Phase=Cutover + DryRun=true — uninstalls logged but not run" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ItemProperty {
                [PSCustomObject]@{
                    DisplayName     = 'Amazon SSM Agent'
                    DisplayVersion  = '3.2.0'
                    UninstallString = 'MsiExec.exe /x {AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}'
                }
            }
            . $script:Run -DryRun -Phase Cutover -SkipAzureAgentCheck
        }

        It "SSM Agent uninstall action is DryRun" {
            (Get-Action -Like 'Uninstall: AWS SSM Agent').Status | Should -Be 'DryRun'
        }

        It "Start-Process NOT called in DryRun even for Cutover" {
            Should -Invoke Start-Process -Times 0 -Exactly
        }
    }

    Context "AWS CLI intentionally skipped regardless of phase" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run -Phase Cutover -SkipAzureAgentCheck
        }

        It "AWS CLI uninstall action is Skipped with intentional note" {
            $a = Get-Action -Like 'Uninstall: AWS CLI'
            $a | Should -Not -BeNullOrEmpty
            $a.Status | Should -Be 'Skipped'
        }
    }
}

# =============================================================================
# GROUP 7 – Azure VM Agent check (Section 8)
# =============================================================================
Describe "Section 8 — Azure VM Agent check" {

    Context "SkipAzureAgentCheck=$true" {
        BeforeAll {
            Set-SafeMocks
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "Azure VM Agent Check is Skipped" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'Skipped'
        }
    }

    Context "WindowsAzureGuestAgent not found" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                # Only null for the Azure agent; all others are also null (default)
                return $null
            }
            . $script:Run -Phase TestMigration
        }

        It "Azure VM Agent Check is Error" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'Error'
        }
    }

    Context "WindowsAzureGuestAgent is Running" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                }
                return $null
            }
            . $script:Run -Phase TestMigration
        }

        It "Azure VM Agent Check is Skipped (already running)" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'Skipped'
        }
    }

    Context "WindowsAzureGuestAgent Stopped — live run starts it" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    return [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' }
                }
                return $null
            }
            Mock Start-Service { }
            Mock Set-Service   { }
            . $script:Run -Phase TestMigration
        }

        It "Azure VM Agent Check is Completed after start" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'Completed'
        }

        It "Start-Service called for WindowsAzureGuestAgent" {
            Should -Invoke Start-Service -Times 1 -Exactly -Scope Context -ParameterFilter {
                $Name -eq 'WindowsAzureGuestAgent'
            }
        }
    }

    Context "WindowsAzureGuestAgent Stopped + DryRun — agent not started" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    return [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' }
                }
                return $null
            }
            Mock Start-Service { }
            . $script:Run -DryRun -Phase TestMigration
        }

        It "Azure VM Agent Check is DryRun" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'DryRun'
        }

        It "Start-Service NOT called in DryRun" {
            Should -Invoke Start-Service -Times 0 -Exactly
        }
    }

    Context "Start-Service throws → Error" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    return [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Manual' }
                }
                return $null
            }
            Mock Start-Service { throw 'Cannot start: service is disabled' }
            . $script:Run -Phase TestMigration
        }

        It "Azure VM Agent Check is Error when Start-Service fails" {
            (Get-Action 'Azure VM Agent Check').Status | Should -Be 'Error'
        }
    }
}

# =============================================================================
# GROUP 8 – Summary counts (report accuracy)
# =============================================================================
Describe "Report — summary counts" {

    Context "All-absent baseline (all Skipped)" {
        BeforeAll {
            Set-SafeMocks
            # All mocks return null/false/empty: everything should skip
            . $script:Run -Phase TestMigration -SkipAzureAgentCheck
        }

        It "Completed count is zero" {
            @($script:Actions | Where-Object Status -eq 'Completed').Count | Should -Be 0
        }

        It "Error count is zero" {
            @($script:Actions | Where-Object Status -eq 'Error').Count | Should -Be 0
        }

        It "Total equals Skipped count" {
            $total   = $script:Actions.Count
            $skipped = @($script:Actions | Where-Object Status -eq 'Skipped').Count
            $total | Should -Be $skipped
        }
    }

    Context "Mix of Skipped and DryRun (services present, DryRun=true)" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name, $ErrorAction)
                if ($Name -in 'AmazonSSMAgent', 'AmazonCloudWatchAgent') {
                    return [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                }
                return $null
            }
            . $script:Run -DryRun -Phase TestMigration -SkipAzureAgentCheck
        }

        It "DryRun count is at least 2 (SSM + CloudWatch)" {
            @($script:Actions | Where-Object Status -eq 'DryRun').Count | Should -BeGreaterOrEqual 2
        }

        It "Completed count is zero in DryRun mode" {
            @($script:Actions | Where-Object Status -eq 'Completed').Count | Should -Be 0
        }

        It "Error count is zero when mocks succeed" {
            @($script:Actions | Where-Object Status -eq 'Error').Count | Should -Be 0
        }

        It "total = Skipped + DryRun" {
            $skipped = @($script:Actions | Where-Object Status -eq 'Skipped').Count
            $dryRun  = @($script:Actions | Where-Object Status -eq 'DryRun').Count
            ($skipped + $dryRun) | Should -Be $script:Actions.Count
        }
    }
}
