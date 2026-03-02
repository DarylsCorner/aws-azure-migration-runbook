#Requires -Modules Pester
#Requires -Version 7.0
<#
.SYNOPSIS
    Pester 5 unit tests for validation/Invoke-MigrationReadiness.ps1

.DESCRIPTION
    The readiness script is a read-only auditor — it detects AWS artifacts
    and validates Azure VM Agent health, then produces a JSON report.

    All system calls are mocked so the tests run on any Windows machine
    without needing AWS software or Azure connectivity.

    Key design notes:
    - Get-MachineEnvVar is a thin wrapper added to the production script so
      [System.Environment]::GetEnvironmentVariable (a .NET static method)
      can be intercepted by Pester.
    - All mocked Get-ItemProperty returns include both DisplayName/DisplayVersion
      (for Check-InstalledProgram) and GuestAgentVersion (for Check-AzureAgent)
      to prevent StrictMode PropertyNotFoundException across all test contexts.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    # Dot-source the script from a temp copy (keeps $script: scope shared)
    $script:TestScript = [System.IO.Path]::ChangeExtension(
        [System.IO.Path]::GetTempFileName(), '.ps1')
    Copy-Item (Join-Path $PSScriptRoot '..\..\validation\Invoke-MigrationReadiness.ps1') `
              $script:TestScript -Force

    $script:DefaultReport = Join-Path $env:TEMP 'pester-readiness-test.json'

    # ─────────────────────────────────────────────────────────────────────────
    # Stub for Get-MachineEnvVar so Pester can Mock it by name even before the
    # production script is dot-sourced. The mock registered in Set-SafeMocks
    # overwrites this stub at runtime.
    # ─────────────────────────────────────────────────────────────────────────
    function Get-MachineEnvVar { param([string]$Name) $null }

    # ─────────────────────────────────────────────────────────────────────────
    # Set-SafeMocks — baseline "fully clean machine" profile:
    #   no AWS services, no installed programs, empty hosts file,
    #   no registry keys, no env vars, IMDS unreachable, no Azure agent.
    # Override specific mocks per-Context to set up test scenarios.
    # ─────────────────────────────────────────────────────────────────────────
    function Set-SafeMocks {
        # Services — nothing found by default
        Mock Get-Service              { $null }

        # Registry — all ItemProperty lookups return null (nothing installed)
        Mock Get-ItemProperty         { $null }

        # Paths — nothing exists (no registry keys, no directories)
        Mock Test-Path                { $false }

        # Hosts file — empty
        Mock Get-Content              { @() }

        # Directory listing — empty (for size calculations in Check-DirectoryExists)
        Mock Get-ChildItem            { @() }

        # Scheduled tasks — none registered
        Mock Get-ScheduledTask        { $null }

        # IMDS — not reachable (not on Azure yet / network blocked)
        Mock Invoke-RestMethod        { throw 'Connection refused: IMDS not reachable' }

        # Machine-scope env vars — none set
        Mock Get-MachineEnvVar        { $null }

        # Output / file-write side effects — silent no-ops
        Mock Set-Content              { }
        Mock New-Item                 { [PSCustomObject]@{ FullName = 'mocked' } }
        Mock Write-Host               { }
        Mock Write-Warning            { }
    }

    # ─────────────────────────────────────────────────────────────────────────
    # $script:Run — resets findings list and dot-sources the script
    # ─────────────────────────────────────────────────────────────────────────
    $script:Run = {
        param(
            [string]$Mode       = 'Both',
            [string]$ReportPath = $script:DefaultReport
        )
        $script:Findings = $null
        . $script:TestScript -Mode $Mode -ReportPath $ReportPath
    }

    # Helper: retrieve findings matching a name substring and optional category
    function Get-Finding {
        param([string]$Name, [string]$Category = '')
        $script:Findings | Where-Object {
            ($_.Name -like "*$Name*") -and
            ($Category -eq '' -or $_.Category -eq $Category)
        }
    }

    # A PSCustomObject with every property the production script's mocks ever
    # access — prevents StrictMode PropertyNotFoundException when the same
    # Get-ItemProperty mock is called by both Check-InstalledProgram and
    # Check-AzureAgent in the same test run.
    function New-MockInstalledEntry {
        param(
            [string]$DisplayName     = 'Amazon SSM Agent',
            [string]$DisplayVersion  = '3.3.1611.0'
        )
        [PSCustomObject]@{
            DisplayName       = $DisplayName
            DisplayVersion    = $DisplayVersion
            UninstallString   = 'MsiExec.exe /x {AAAABBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF}'
            GuestAgentVersion = $null   # accessed by Check-AzureAgent on the same mock
        }
    }
}

AfterAll {
    Remove-Item $script:TestScript -Force -ErrorAction SilentlyContinue
}

# =============================================================================
# GROUP 1 – Report structure (sanity: runs without error, emits valid report)
# =============================================================================
Describe "Report structure" {

    Context "Mode=Both, clean machine (all safe mocks)" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Both
        }

        It "returns a hashtable" {
            $script:Report | Should -BeOfType [hashtable]
        }

        It "SchemaVersion is '1.0'" {
            $script:Report.SchemaVersion | Should -Be '1.0'
        }

        It "Mode is 'Both'" {
            $script:Report.Mode | Should -Be 'Both'
        }

        It "Findings list is not empty" {
            $script:Report.Findings | Should -Not -BeNullOrEmpty
        }

        It "Summary is a hashtable" {
            $script:Report.Summary | Should -BeOfType [hashtable]
        }

        It "Timestamp is a non-empty string" {
            $script:Report.Timestamp | Should -Not -BeNullOrEmpty
        }

        It "ComputerName is a non-empty string" {
            $script:Report.ComputerName | Should -Not -BeNullOrEmpty
        }
    }
}

# =============================================================================
# GROUP 2 – Mode=Pre: discovery only — no PostAssertions
# =============================================================================
Describe "Mode=Pre — discovery only" {

    Context "Pre mode with default safe mocks" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Pre
        }

        It "PostAssertions is null" {
            $script:Report.PostAssertions | Should -BeNullOrEmpty
        }

        It "Findings list is populated (checks ran)" {
            $script:Report.Findings.Count | Should -BeGreaterThan 0
        }

        It "IMDS check is performed in Pre mode" {
            Should -Invoke Invoke-RestMethod -Scope Context
        }

        It "Get-Service is called (service checks run)" {
            Should -Invoke Get-Service -Scope Context
        }
    }
}

# =============================================================================
# GROUP 3 – Mode=Post with clean machine: CleanState = true
# =============================================================================
Describe "Mode=Post — clean machine assertions" {

    Context "Post mode: no AWS artifacts, Azure agent healthy" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                } else { $null }
            }
            Mock Get-ItemProperty {
                param($Path)
                if ($Path -like '*GuestAgent*') {
                    [PSCustomObject]@{
                        DisplayName       = $null
                        DisplayVersion    = $null
                        UninstallString   = $null
                        GuestAgentVersion = '2.7.41491.1075'
                    }
                } else { $null }
            }
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    compute = [PSCustomObject]@{ provider = 'Microsoft'; location = 'eastus' }
                }
            }
            $script:Report = . $script:Run -Mode Post
        }

        It "PostAssertions is not null" {
            $script:Report.PostAssertions | Should -Not -BeNullOrEmpty
        }

        It "CleanState is true" {
            $script:Report.PostAssertions.CleanState | Should -Be $true
        }

        It "AwsComponentsFound is zero" {
            $script:Report.PostAssertions.AwsComponentsFound | Should -Be 0
        }

        It "AzureAgentFailed is zero" {
            $script:Report.PostAssertions.AzureAgentFailed | Should -Be 0
        }
    }
}

# =============================================================================
# GROUP 4 – Service detection
# =============================================================================
Describe "Service detection" {

    Context "AWS SSM Agent service is running" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'AmazonSSMAgent') {
                    [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                } else { $null }
            }
            $script:Report = . $script:Run -Mode Pre
        }

        It "creates a Found finding for AWS SSM Agent" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Services'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Found'
        }

        It "finding detail includes Status and StartType" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Services'
            $f.Detail | Should -Match 'Status=Running'
            $f.Detail | Should -Match 'StartType=Automatic'
        }

        It "finding includes a Recommendation" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Services'
            $f.Recommendation | Should -Not -BeNullOrEmpty
        }

        It "Summary.Found is at least 1" {
            $script:Report.Summary.Found | Should -BeGreaterOrEqual 1
        }
    }

    Context "AWS SSM Agent service not installed" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Pre
        }

        It "creates a NotFound finding for AWS SSM Agent" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Services'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'NotFound'
        }
    }
}

# =============================================================================
# GROUP 5 – Installed program detection
# =============================================================================
Describe "Installed program detection" {

    Context "Amazon SSM Agent appears in the uninstall registry hive" {
        BeforeAll {
            Set-SafeMocks
            # Return a matching entry for any registry path except the Azure GuestAgent key
            Mock Get-ItemProperty {
                param($Path)
                if ($Path -like '*GuestAgent*') { return $null }
                New-MockInstalledEntry -DisplayName 'Amazon SSM Agent' -DisplayVersion '3.3.1611.0'
            }
            $script:Report = . $script:Run -Mode Pre
        }

        It "creates a Found finding under Installed Software" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Installed Software'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Found'
        }

        It "finding detail includes the display name" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Installed Software'
            $f.Detail | Should -Match 'Amazon SSM Agent'
        }

        It "finding detail includes the version number" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Installed Software'
            $f.Detail | Should -Match '3\.3\.'
        }

        It "finding includes a Recommendation" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Installed Software'
            $f.Recommendation | Should -Not -BeNullOrEmpty
        }
    }

    Context "No AWS software installed (default safe mocks)" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Pre
        }

        It "AWS SSM Agent Installed Software finding is NotFound" {
            $f = Get-Finding -Name 'AWS SSM Agent' -Category 'Installed Software'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'NotFound'
        }
    }
}

# =============================================================================
# GROUP 6 – Azure Agent health
# =============================================================================
Describe "Azure Agent health checks" {

    Context "WindowsAzureGuestAgent is Running and version is in registry" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                } else { $null }
            }
            Mock Get-ItemProperty {
                param($Path)
                if ($Path -like '*GuestAgent*') {
                    [PSCustomObject]@{
                        DisplayName       = $null
                        DisplayVersion    = $null
                        UninstallString   = $null
                        GuestAgentVersion = '2.7.41491.1075'
                    }
                } else { $null }
            }
            $script:Report = . $script:Run -Mode Both
        }

        It "Azure Agent finding is Pass" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Pass'
        }

        It "Agent Version finding is Info" {
            $f = Get-Finding -Name 'Agent Version' -Category 'Azure Agent'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Info'
        }

        It "Agent Version detail contains the version string" {
            $f = Get-Finding -Name 'Agent Version' -Category 'Azure Agent'
            $f.Detail | Should -Match '2\.7\.'
        }
    }

    Context "WindowsAzureGuestAgent service not found" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Both
        }

        It "Azure Agent finding is Fail" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Fail'
        }

        It "Recommendation mentions how to install the agent" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f.Recommendation | Should -Match 'Install'
        }

        It "Detail says 'not found'" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f.Detail | Should -Match 'not found'
        }
    }

    Context "WindowsAzureGuestAgent service exists but is Stopped" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'WindowsAzureGuestAgent') {
                    [PSCustomObject]@{ Status = 'Stopped'; StartType = 'Disabled' }
                } else { $null }
            }
            $script:Report = . $script:Run -Mode Both
        }

        It "Azure Agent finding is Fail" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f.Status | Should -Be 'Fail'
        }

        It "finding detail mentions Stopped" {
            $f = Get-Finding -Name 'WindowsAzureGuestAgent' -Category 'Azure Agent'
            $f.Detail | Should -Match 'Stopped'
        }
    }
}

# =============================================================================
# GROUP 7 – Azure IMDS check
# =============================================================================
Describe "Azure IMDS check" {

    Context "IMDS returns Azure (Microsoft) provider response" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    compute = [PSCustomObject]@{ provider = 'Microsoft'; location = 'westus2' }
                }
            }
            $script:Report = . $script:Run -Mode Pre
        }

        It "IMDS finding is Pass" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Pass'
        }

        It "IMDS detail includes 'Microsoft'" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f.Detail | Should -Match 'Microsoft'
        }

        It "IMDS detail includes the region" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f.Detail | Should -Match 'westus2'
        }
    }

    Context "IMDS does not respond (Invoke-RestMethod throws)" {
        BeforeAll {
            Set-SafeMocks   # default mock already throws
            $script:Report = . $script:Run -Mode Pre
        }

        It "IMDS finding is Warning" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f | Should -Not -BeNullOrEmpty
            $f.Status | Should -Be 'Warning'
        }

        It "IMDS detail mentions the error" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f.Detail | Should -Not -BeNullOrEmpty
        }
    }

    Context "IMDS responds but provider is not Microsoft" {
        BeforeAll {
            Set-SafeMocks
            Mock Invoke-RestMethod {
                [PSCustomObject]@{
                    compute = [PSCustomObject]@{ provider = 'Amazon'; location = 'us-east-1' }
                }
            }
            $script:Report = . $script:Run -Mode Pre
        }

        It "IMDS finding is Warning (unexpected provider)" {
            $f = Get-Finding -Name 'IMDS endpoint' -Category 'Azure IMDS'
            $f.Status | Should -Be 'Warning'
        }
    }
}

# =============================================================================
# GROUP 8 – Mode=Post: dirty machine (AWS present, Azure unhealthy)
# =============================================================================
Describe "Mode=Post — dirty machine" {

    Context "AWS service still running and Azure agent is missing" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'AmazonSSMAgent') {
                    [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                } else { $null }
            }
            $script:Report = . $script:Run -Mode Post
        }

        It "PostAssertions is not null" {
            $script:Report.PostAssertions | Should -Not -BeNullOrEmpty
        }

        It "CleanState is false" {
            $script:Report.PostAssertions.CleanState | Should -Be $false
        }

        It "AwsComponentsFound is greater than zero" {
            $script:Report.PostAssertions.AwsComponentsFound | Should -BeGreaterThan 0
        }

        It "AzureAgentFailed is greater than zero" {
            $script:Report.PostAssertions.AzureAgentFailed | Should -BeGreaterThan 0
        }
    }

    Context "AWS installed software found, Azure agent missing" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-ItemProperty {
                param($Path)
                if ($Path -like '*GuestAgent*') { return $null }
                New-MockInstalledEntry -DisplayName 'Amazon SSM Agent' -DisplayVersion '3.2.0'
            }
            $script:Report = . $script:Run -Mode Post
        }

        It "CleanState is false" {
            $script:Report.PostAssertions.CleanState | Should -Be $false
        }

        It "AwsComponentsFound reflects the installed software finding" {
            $script:Report.PostAssertions.AwsComponentsFound | Should -BeGreaterThan 0
        }
    }
}

# =============================================================================
# GROUP 9 – Summary counts match the actual findings
# =============================================================================
Describe "Summary counts accuracy" {

    Context "Mixed state: one running AWS service, Azure agent missing" {
        BeforeAll {
            Set-SafeMocks
            Mock Get-Service {
                param($Name)
                if ($Name -eq 'AmazonSSMAgent') {
                    [PSCustomObject]@{ Status = 'Running'; StartType = 'Automatic' }
                } else { $null }
            }
            $script:Report = . $script:Run -Mode Both
        }

        It "Summary.Found matches count of Found findings" {
            $expected = @($script:Findings | Where-Object { $_.Status -eq 'Found' }).Count
            $script:Report.Summary.Found | Should -Be $expected
        }

        It "Summary.NotFound matches count of NotFound findings" {
            $expected = @($script:Findings | Where-Object { $_.Status -eq 'NotFound' }).Count
            $script:Report.Summary.NotFound | Should -Be $expected
        }

        It "Summary.Fail matches count of Fail findings" {
            $expected = @($script:Findings | Where-Object { $_.Status -eq 'Fail' }).Count
            $script:Report.Summary.Fail | Should -Be $expected
        }

        It "Summary.Warning matches count of Warning findings" {
            $expected = @($script:Findings | Where-Object { $_.Status -eq 'Warning' }).Count
            $script:Report.Summary.Warning | Should -Be $expected
        }

        It "all Summary counts sum to total Findings count" {
            $total = $script:Report.Summary.Found   + $script:Report.Summary.NotFound +
                     $script:Report.Summary.Pass    + $script:Report.Summary.Fail     +
                     $script:Report.Summary.Warning + $script:Report.Summary.Info
            $total | Should -Be $script:Findings.Count
        }
    }
}

# =============================================================================
# GROUP 10 – Report file creation
# =============================================================================
Describe "Report file creation" {

    Context "Normal run — Set-Content is called with the correct path" {
        BeforeAll {
            Set-SafeMocks
            $script:Report = . $script:Run -Mode Pre -ReportPath 'C:\Temp\pester-test-report.json'
        }

        It "Set-Content is called with the specified ReportPath" {
            Should -Invoke Set-Content -ParameterFilter {
                $Path -eq 'C:\Temp\pester-test-report.json'
            } -Scope Context
        }
    }

    Context "Report directory does not exist — New-Item is called" {
        BeforeAll {
            Set-SafeMocks
            # Test-Path mocked $false for everything including the report dir
            $script:Report = . $script:Run -Mode Pre -ReportPath 'C:\NoSuchDir\sub\report.json'
        }

        It "New-Item is called to create the missing directory" {
            Should -Invoke New-Item -Scope Context
        }
    }

    Context "Report content is valid JSON" {
        BeforeAll {
            Set-SafeMocks
            $script:CapturedContent = $null
            Mock Set-Content {
                param($Path, $Value, $Encoding)
                $script:CapturedContent = $Value
            }
            . $script:Run -Mode Both -ReportPath 'C:\Temp\pester-json-test.json'
        }

        It "content passed to Set-Content can be parsed as JSON" {
            { $script:CapturedContent | ConvertFrom-Json } | Should -Not -Throw
        }

        It "parsed JSON contains Findings array" {
            $json = $script:CapturedContent | ConvertFrom-Json
            $json.Findings | Should -Not -BeNullOrEmpty
        }

        It "parsed JSON contains Summary object" {
            $json = $script:CapturedContent | ConvertFrom-Json
            $json.Summary | Should -Not -BeNullOrEmpty
        }
    }
}
