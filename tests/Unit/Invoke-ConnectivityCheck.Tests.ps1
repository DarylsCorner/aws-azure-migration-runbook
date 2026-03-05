#Requires -Modules Pester
#Requires -Version 7.0
<#
.SYNOPSIS
    Pester 5 unit tests for infra/aws/Invoke-ConnectivityCheck.ps1

.DESCRIPTION
    All AWS CLI / system calls are mocked so these tests run on any machine
    without AWS credentials or network access.

    Design notes:
    - The script is dot-sourced from a temp copy so the invocation name is '.'
      and the guard (if ($MyInvocation.InvocationName -ne '.')) prevents the
      main body from executing — only helper functions are loaded.
    - Read-ApplianceEnvFile, Get-AppliancePrivateIp, and Invoke-SsmProbeCommand
      are replaced with mocks inside each InModuleScope / BeforeEach block.
#>

BeforeAll {
    Set-StrictMode -Version Latest

    # Dot-source via a temp copy so InvocationName == '.'
    $script:TestScript = [System.IO.Path]::ChangeExtension(
        [System.IO.Path]::GetTempFileName(), '.ps1')
    Copy-Item (Join-Path $PSScriptRoot '..\..\infra\aws\Invoke-ConnectivityCheck.ps1') `
              $script:TestScript -Force
    . $script:TestScript

    # ── Minimal test-env objects ──────────────────────────────────────────────
    $script:BaseEnv = [PSCustomObject]@{
        Region              = 'us-east-1'
        WindowsInstanceId   = 'i-win-001'
        WindowsPrivateIp    = '10.0.0.10'
        LinuxInstanceId     = 'i-lnx-001'
        LinuxPrivateIp      = '10.0.0.20'
    }

    # Env file with both appliance entries
    $script:EnvFilePath = Join-Path $env:TEMP 'pester-connectivity-test-env.json'
    $script:BaseEnv | ConvertTo-Json | Set-Content $script:EnvFilePath

    # ── Default SSM probe result helper ──────────────────────────────────────
    function New-SsmOk {
        param([string]$TargetIp, [int[]]$Ports)
        $stdout = ($Ports | ForEach-Object { "OPEN ${TargetIp}:$_" }) -join "`n"
        return @{ Status = 'Success'; Stdout = $stdout; Stderr = ''; ExitCode = 0 }
    }

    function New-SsmClosed {
        param([string]$TargetIp, [int[]]$Ports)
        $stdout = ($Ports | ForEach-Object { "CLOSED ${TargetIp}:$_" }) -join "`n"
        return @{ Status = 'Success'; Stdout = $stdout; Stderr = ''; ExitCode = 0 }
    }
}

AfterAll {
    Remove-Item $script:TestScript    -Force -ErrorAction SilentlyContinue
    Remove-Item $script:EnvFilePath   -Force -ErrorAction SilentlyContinue
}

# ═════════════════════════════════════════════════════════════════════════════
Describe 'Read-ApplianceEnvFile' {
# ═════════════════════════════════════════════════════════════════════════════

    It 'returns empty hashtable for a missing file' {
        $result = Read-ApplianceEnvFile -Path 'C:\does-not-exist.env'
        $result | Should -BeOfType [hashtable]
        $result.Count | Should -Be 0
    }

    It 'parses KEY=VALUE pairs correctly' {
        $tempEnv = Join-Path $env:TEMP 'test-parse.env'
        "InstanceId=i-abc123`nRegion=us-east-1" | Set-Content $tempEnv
        $result = Read-ApplianceEnvFile -Path $tempEnv
        $result['InstanceId'] | Should -Be 'i-abc123'
        $result['Region']     | Should -Be 'us-east-1'
        Remove-Item $tempEnv -Force -ErrorAction SilentlyContinue
    }

    It 'ignores lines without an equals sign' {
        $tempEnv = Join-Path $env:TEMP 'test-noequals.env'
        "# comment`nKey=Value`nNoEquals" | Set-Content $tempEnv
        $result = Read-ApplianceEnvFile -Path $tempEnv
        $result.Count | Should -Be 1
        $result['Key'] | Should -Be 'Value'
        Remove-Item $tempEnv -Force -ErrorAction SilentlyContinue
    }
}

# ═════════════════════════════════════════════════════════════════════════════
Describe 'Build-ProbeMatrix' {
# ═════════════════════════════════════════════════════════════════════════════

    Context 'both appliances provided' {
        BeforeAll {
            $script:probes = Build-ProbeMatrix `
                -TestEnv       $script:BaseEnv `
                -DiscoveryIp   '10.10.0.50' `
                -ReplicationIp '10.10.0.178'
        }

        It 'returns 8 probes (2 OS × (1 disc port + 3 repl ports))' {
            $script:probes.Count | Should -Be 8
        }

        It 'includes Windows → Replication:44368' {
            $match = $script:probes | Where-Object { $_.Label -eq 'Windows → Replication:44368' }
            $match | Should -Not -BeNullOrEmpty
            $match.TargetIp | Should -Be '10.10.0.178'
            $match.Port     | Should -Be 44368
        }

        It 'includes Linux → Discovery:443' {
            $match = $script:probes | Where-Object { $_.Label -eq 'Linux → Discovery:443' }
            $match | Should -Not -BeNullOrEmpty
            $match.TargetIp | Should -Be '10.10.0.50'
        }

        It 'all probes carry InstanceId and OS' {
            $script:probes | ForEach-Object {
                $_.InstanceId | Should -Not -BeNullOrEmpty
                $_.OS         | Should -BeIn @('Windows', 'Linux')
            }
        }
    }

    Context 'only replication appliance provided' {
        It 'returns 6 probes (2 OS × 3 repl ports, no discovery)' {
            $probes = Build-ProbeMatrix `
                -TestEnv       $script:BaseEnv `
                -DiscoveryIp   '' `
                -ReplicationIp '10.10.0.178'
            $probes.Count | Should -Be 6
            @($probes | Where-Object { $_.TargetIp -eq '' }).Count | Should -Be 0
        }
    }

    Context 'only discovery appliance provided' {
        It 'returns 2 probes (2 OS × 1 disc port, no replication)' {
            $probes = Build-ProbeMatrix `
                -TestEnv       $script:BaseEnv `
                -DiscoveryIp   '10.10.0.50' `
                -ReplicationIp ''
            $probes.Count | Should -Be 2
        }
    }

    Context 'Linux instance ID missing (deferred)' {
        It 'skips Linux probes when LinuxInstanceId is empty' {
            $envNoLinux = [PSCustomObject]@{
                Region            = 'us-east-1'
                WindowsInstanceId = 'i-win-001'
                WindowsPrivateIp  = '10.0.0.10'
                LinuxInstanceId   = $null
                LinuxPrivateIp    = $null
            }
            $probes = Build-ProbeMatrix `
                -TestEnv       $envNoLinux `
                -DiscoveryIp   '10.10.0.50' `
                -ReplicationIp '10.10.0.178'
            @($probes | Where-Object { $_.OS -eq 'Linux' }).Count | Should -Be 0
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
Describe 'Invoke-ProbeGroup — output parsing' {
# ═════════════════════════════════════════════════════════════════════════════

    BeforeAll {
        # Build a minimal Windows probe list targeting 10.0.0.1:443
        $script:WinProbes = @(
            @{ Label='Windows → Replication:443'; InstanceId='i-win-001';
               OS='Windows'; SourceIp='10.0.0.10'; TargetIp='10.0.0.1'; Port=443 },
            @{ Label='Windows → Replication:44368'; InstanceId='i-win-001';
               OS='Windows'; SourceIp='10.0.0.10'; TargetIp='10.0.0.1'; Port=44368 }
        )
    }

    Context 'all ports open' {
        It 'returns PASS for each probe' {
            Mock Invoke-SsmProbeCommand {
                return New-SsmOk -TargetIp '10.0.0.1' -Ports @(443, 44368)
            }
            $results = Invoke-ProbeGroup -InstanceId 'i-win-001' -OS 'Windows' `
                           -SourceIp '10.0.0.10' -Probes $script:WinProbes `
                           -Region 'us-east-1' -TimeoutSec 10
            $results | ForEach-Object { $_.Status | Should -Be 'PASS' }
        }
    }

    Context 'port 44368 closed' {
        It 'returns FAIL only for 44368' {
            Mock Invoke-SsmProbeCommand {
                return @{
                    Status   = 'Success'
                    Stdout   = "OPEN 10.0.0.1:443`nCLOSED 10.0.0.1:44368"
                    Stderr   = ''
                    ExitCode = 0
                }
            }
            $results = Invoke-ProbeGroup -InstanceId 'i-win-001' -OS 'Windows' `
                           -SourceIp '10.0.0.10' -Probes $script:WinProbes `
                           -Region 'us-east-1' -TimeoutSec 10
            ($results | Where-Object { $_.Port -eq 443   }).Status | Should -Be 'PASS'
            ($results | Where-Object { $_.Port -eq 44368 }).Status | Should -Be 'FAIL'
        }
    }

    Context 'SSM timed out (no output)' {
        It 'returns UNKNOWN for every probe' {
            Mock Invoke-SsmProbeCommand {
                return @{ Status = 'Timeout'; Stdout = ''; Stderr = 'timed out'; ExitCode = -1 }
            }
            $results = Invoke-ProbeGroup -InstanceId 'i-win-001' -OS 'Windows' `
                           -SourceIp '10.0.0.10' -Probes $script:WinProbes `
                           -Region 'us-east-1' -TimeoutSec 10
            $results | ForEach-Object { $_.Status | Should -Be 'UNKNOWN' }
        }
    }
}

# ═════════════════════════════════════════════════════════════════════════════
Describe 'Invoke-ConnectivityCheckMain — end-to-end' {
# ═════════════════════════════════════════════════════════════════════════════

    BeforeEach {
        # Silence Write-Host output during tests
        Mock Write-Host   { }
        Mock Write-Warning { }
        Mock Write-Error  { }

        # Default env-file reader: no appliance IDs
        Mock Read-ApplianceEnvFile { return @{} }

        # Default IP resolver: returns a known IP
        Mock Get-AppliancePrivateIp { return '10.10.0.178' }

        # Default probe runner: all ports open
        Mock Invoke-SsmProbeCommand {
            return New-SsmOk -TargetIp '10.10.0.178' -Ports @(443, 9443, 44368)
        }
    }

    Context 'test-env.json does not exist' {
        It 'returns exit code 1' {
            $rc = Invoke-ConnectivityCheckMain `
                -EnvFile 'C:\does-not-exist.json' `
                -Region 'us-east-1' -TimeoutSec 5
            $rc | Should -Be 1
        }
    }

    Context 'all probes pass' {
        It 'returns exit code 0' {
            Mock Invoke-SsmProbeCommand {
                # Build OPEN lines for every port on 10.10.0.178
                $stdout = @('443','9443','44368') |
                          ForEach-Object { "OPEN 10.10.0.178:$_" } |
                          Out-String
                return @{ Status='Success'; Stdout=$stdout; Stderr=''; ExitCode=0 }
            }
            $rc = Invoke-ConnectivityCheckMain `
                    -EnvFile               $script:EnvFilePath `
                    -ReplicationApplianceIp '10.10.0.178' `
                    -Region 'us-east-1' -TimeoutSec 5
            $rc | Should -Be 0
        }
    }

    Context 'one probe fails (port 44368 CLOSED)' {
        It 'returns exit code 1' {
            Mock Invoke-SsmProbeCommand {
                return @{
                    Status   = 'Success'
                    Stdout   = "OPEN 10.10.0.178:443`nOPEN 10.10.0.178:9443`nCLOSED 10.10.0.178:44368"
                    Stderr   = ''
                    ExitCode = 0
                }
            }
            $rc = Invoke-ConnectivityCheckMain `
                    -EnvFile               $script:EnvFilePath `
                    -ReplicationApplianceIp '10.10.0.178' `
                    -Region 'us-east-1' -TimeoutSec 5
            $rc | Should -Be 1
        }
    }

    Context 'no appliance IPs resolved' {
        It 'returns exit code 1 and does not call Invoke-SsmProbeCommand' {
            Mock Get-AppliancePrivateIp { return $null }
            $rc = Invoke-ConnectivityCheckMain `
                    -EnvFile $script:EnvFilePath `
                    -Region  'us-east-1' -TimeoutSec 5
            $rc | Should -Be 1
            Should -Invoke Invoke-SsmProbeCommand -Times 0
        }
    }
}
