#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies that source VMs can reach the Azure Migrate discovery and
    replication appliances on all ports required by ASR Mobility Service.

.DESCRIPTION
    Runs TCP port probes from each source EC2 instance (via SSM Run Command)
    to both appliance VMs.  Produces a PASS/FAIL table and exits non-zero if
    any probe fails — suitable as a CI gate or pre-replication check.

    Required connectivity matrix:
    ┌────────────────────┬────────────────────────┬──────────────────────────┐
    │ Source             │ Destination            │ Ports                    │
    ├────────────────────┼────────────────────────┼──────────────────────────┤
    │ Windows VM         │ Discovery appliance    │ 443                      │
    │ Windows VM         │ Replication appliance  │ 443, 9443, 44368         │
    │ Linux VM           │ Discovery appliance    │ 443                      │
    │ Linux VM           │ Replication appliance  │ 443, 9443, 44368         │
    └────────────────────┴────────────────────────┴──────────────────────────┘

    Port 44368 — Appliance Configuration Manager endpoint used by
    UnifiedAgentConfigurator.exe /CSType CSPrime to register the Mobility
    Service agent.  If this port is blocked the configurator reports the
    misleading error "Invalid source config file provided".

.PARAMETER EnvFile
    Path to test-env.json produced by Deploy-TestEnv.ps1.
    Default: same directory as this script.

.PARAMETER DiscoveryApplianceInstanceId
    EC2 instance ID of the discovery appliance.  Used to look up its private
    IP when -DiscoveryApplianceIp is not provided.
    Default: read from appliance-vm.env in the same directory.

.PARAMETER ReplicationApplianceInstanceId
    EC2 instance ID of the replication appliance.  Used to look up its
    private IP when -ReplicationApplianceIp is not provided.
    Default: read from repl-appliance-vm.env in the same directory.

.PARAMETER DiscoveryApplianceIp
    Private IP of the discovery appliance.  Overrides the auto-lookup.

.PARAMETER ReplicationApplianceIp
    Private IP of the replication appliance.  Overrides the auto-lookup.

.PARAMETER Region
    AWS region.  Default: value in test-env.json, or us-east-1.

.PARAMETER TimeoutSec
    Per-probe TCP connection timeout in seconds.  Default: 5.

.EXAMPLE
    # Fully automatic — reads all IPs from env files
    .\Invoke-ConnectivityCheck.ps1

.EXAMPLE
    # Specify IPs explicitly (e.g. if env files are absent)
    .\Invoke-ConnectivityCheck.ps1 `
        -DiscoveryApplianceIp    10.10.1.50 `
        -ReplicationApplianceIp  10.10.1.178

.EXAMPLE
    # Use as a CI gate — exit code 1 if any probe fails
    .\Invoke-ConnectivityCheck.ps1; if ($LASTEXITCODE -ne 0) { throw 'Connectivity check failed' }
#>
[CmdletBinding()]
param(
    [string] $EnvFile                         = '',
    [string] $DiscoveryApplianceInstanceId    = '',
    [string] $ReplicationApplianceInstanceId  = '',
    [string] $DiscoveryApplianceIp            = '',
    [string] $ReplicationApplianceIp          = '',
    [string] $Region                          = '',
    [int]    $TimeoutSec                      = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─────────────────────────────────────────────────────────────────────────────
# Helper functions (mockable for unit tests)
# ─────────────────────────────────────────────────────────────────────────────

function Read-ApplianceEnvFile {
    <#.SYNOPSIS Parses a KEY=VALUE .env file into a hashtable.#>
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path $Path)) { return $map }
    Get-Content $Path | ForEach-Object {
        if ($_ -match '^([^=]+)=(.*)$') { $map[$Matches[1].Trim()] = $Matches[2].Trim() }
    }
    return $map
}

function Get-AppliancePrivateIp {
    <#.SYNOPSIS Resolves an EC2 instance's private IP via the AWS CLI.#>
    param([string]$InstanceId, [string]$Region)
    $ip = aws ec2 describe-instances `
        --instance-ids $InstanceId `
        --query 'Reservations[0].Instances[0].PrivateIpAddress' `
        --region $Region --output text 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ip) -or $ip -eq 'None') {
        return $null
    }
    return $ip.Trim()
}

function Invoke-SsmProbeCommand {
    <#.SYNOPSIS Sends an SSM Run Command and polls for completion.#>
    param(
        [string]   $InstanceId,
        [string]   $Region,
        [string]   $DocumentName,
        [string[]] $Commands,
        [int]      $TimeoutSec = 90
    )
    $lines    = $Commands | ForEach-Object { $_ -split "`r?`n" } | Where-Object { $null -ne $_ }
    $cmdJson  = $lines | ConvertTo-Json -Compress
    $paramFile = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($paramFile, "{`"commands`":$cmdJson}",
        [System.Text.UTF8Encoding]::new($false))

    $sendResult = aws ssm send-command `
        --instance-ids  $InstanceId `
        --document-name $DocumentName `
        --parameters    "file://$paramFile" `
        --region        $Region `
        --output json | ConvertFrom-Json
    Remove-Item $paramFile -Force -ErrorAction SilentlyContinue

    $commandId = $sendResult.Command.CommandId
    $start     = [datetime]::UtcNow
    while ($true) {
        Start-Sleep 5
        $inv = aws ssm get-command-invocation `
            --command-id  $commandId `
            --instance-id $InstanceId `
            --region      $Region | ConvertFrom-Json
        if ($inv.Status -in @('Success','Failed','Cancelled','TimedOut')) {
            return @{
                Status   = $inv.Status
                Stdout   = $inv.StandardOutputContent
                Stderr   = $inv.StandardErrorContent
                ExitCode = $inv.ResponseCode
            }
        }
        if (([datetime]::UtcNow - $start).TotalSeconds -gt $TimeoutSec) {
            return @{ Status = 'Timeout'; Stdout = ''; Stderr = 'SSM polling timed out'; ExitCode = -1 }
        }
    }
}

function Build-ProbeMatrix {
    <#
    .SYNOPSIS Returns the list of port-probe descriptors for both appliances.
    .OUTPUTS  Array of hashtables: @{ Label; InstanceId; OS; SourceIp; TargetIp; Port }
    #>
    param(
        [PSCustomObject] $TestEnv,
        [string]         $DiscoveryIp,
        [string]         $ReplicationIp
    )
    $probes    = [System.Collections.ArrayList]::new()
    $discPorts = @(443)
    $replPorts = @(443, 9443, 44368)

    foreach ($os in @('Windows', 'Linux')) {
        $iid      = if ($os -eq 'Windows') { $TestEnv.WindowsInstanceId } else { $TestEnv.LinuxInstanceId }
        $sourceIp = if ($os -eq 'Windows') { $TestEnv.WindowsPrivateIp  } else { $TestEnv.LinuxPrivateIp  }
        if (-not $iid) { continue }

        if ($DiscoveryIp) {
            foreach ($port in $discPorts) {
                $null = $probes.Add(@{
                    Label     = "$os → Discovery:$port"
                    InstanceId = $iid; OS = $os; SourceIp = $sourceIp
                    TargetIp  = $DiscoveryIp; Port = $port
                })
            }
        }
        if ($ReplicationIp) {
            foreach ($port in $replPorts) {
                $null = $probes.Add(@{
                    Label     = "$os → Replication:$port"
                    InstanceId = $iid; OS = $os; SourceIp = $sourceIp
                    TargetIp  = $ReplicationIp; Port = $port
                })
            }
        }
    }
    return @($probes)
}

function Invoke-ProbeGroup {
    <#
    .SYNOPSIS
        Sends a single batched SSM command for all probes from one instance.
        Returns an array of result objects with Status PASS/FAIL/UNKNOWN.
    #>
    param(
        [string] $InstanceId,
        [string] $OS,
        [string] $SourceIp,
        [array]  $Probes,
        [string] $Region,
        [int]    $TimeoutSec
    )
    if ($OS -eq 'Windows') {
        $lines = @()
        foreach ($p in $Probes) {
            $lines += "`$r = Test-NetConnection -ComputerName '$($p.TargetIp)' -Port $($p.Port) -InformationLevel Quiet -WarningAction SilentlyContinue"
            $lines += "if (`$r) { Write-Output 'OPEN $($p.TargetIp):$($p.Port)' } else { Write-Output 'CLOSED $($p.TargetIp):$($p.Port)' }"
        }
        $doc = 'AWS-RunPowerShellScript'
    } else {
        $lines = @('#!/bin/bash')
        foreach ($p in $Probes) {
            $lines += "timeout $TimeoutSec bash -c '</dev/tcp/$($p.TargetIp)/$($p.Port)' 2>/dev/null && echo 'OPEN $($p.TargetIp):$($p.Port)' || echo 'CLOSED $($p.TargetIp):$($p.Port)'"
        }
        $doc = 'AWS-RunShellScript'
    }

    $ssmResult = Invoke-SsmProbeCommand -InstanceId $InstanceId -Region $Region `
                     -DocumentName $doc -Commands $lines -TimeoutSec $TimeoutSec

    $out = [System.Collections.ArrayList]::new()
    foreach ($p in $Probes) {
        $token  = "$($p.TargetIp):$($p.Port)"
        $status = if ($ssmResult.Stdout -match "OPEN $([regex]::Escape($token))") { 'PASS' }
                  elseif ($ssmResult.Stdout -match "CLOSED $([regex]::Escape($token))") { 'FAIL' }
                  else { 'UNKNOWN' }
        $null = $out.Add([PSCustomObject]@{
            Label  = $p.Label
            Source = "$OS ($SourceIp)"
            Target = $token
            Port   = $p.Port
            Status = $status
        })
    }
    return @($out)
}

# ─────────────────────────────────────────────────────────────────────────────
# Main entry point
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-ConnectivityCheckMain {
    param(
        [string] $EnvFile,
        [string] $DiscoveryApplianceInstanceId,
        [string] $ReplicationApplianceInstanceId,
        [string] $DiscoveryApplianceIp,
        [string] $ReplicationApplianceIp,
        [string] $Region,
        [int]    $TimeoutSec
    )

    # -- Resolve test-env.json ------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($EnvFile)) {
        $EnvFile = Join-Path $PSScriptRoot 'test-env.json'
    }
    if (-not (Test-Path $EnvFile)) {
        Write-Error "test-env.json not found at '$EnvFile'. Run Deploy-TestEnv.ps1 first."
        return 1
    }
    $testEnv = Get-Content $EnvFile -Raw | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($Region)) {
        $Region = if ($testEnv.Region) { $testEnv.Region } else { 'us-east-1' }
    }

    # -- Resolve appliance instance IDs from .env files ----------------------
    if ([string]::IsNullOrWhiteSpace($DiscoveryApplianceInstanceId)) {
        $appEnv = Read-ApplianceEnvFile (Join-Path $PSScriptRoot 'appliance-vm.env')
        $DiscoveryApplianceInstanceId = $appEnv['InstanceId']
    }
    if ([string]::IsNullOrWhiteSpace($ReplicationApplianceInstanceId)) {
        $replEnv = Read-ApplianceEnvFile (Join-Path $PSScriptRoot 'repl-appliance-vm.env')
        $ReplicationApplianceInstanceId = $replEnv['InstanceId']
    }

    # -- Resolve private IPs --------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($DiscoveryApplianceIp) -and
        -not [string]::IsNullOrWhiteSpace($DiscoveryApplianceInstanceId)) {
        $DiscoveryApplianceIp = Get-AppliancePrivateIp -InstanceId $DiscoveryApplianceInstanceId -Region $Region
        if (-not $DiscoveryApplianceIp) {
            Write-Warning "Could not resolve private IP for discovery appliance ($DiscoveryApplianceInstanceId) — skipping."
        }
    }
    if ([string]::IsNullOrWhiteSpace($ReplicationApplianceIp) -and
        -not [string]::IsNullOrWhiteSpace($ReplicationApplianceInstanceId)) {
        $ReplicationApplianceIp = Get-AppliancePrivateIp -InstanceId $ReplicationApplianceInstanceId -Region $Region
        if (-not $ReplicationApplianceIp) {
            Write-Warning "Could not resolve private IP for replication appliance ($ReplicationApplianceInstanceId) — skipping."
        }
    }

    if (-not $DiscoveryApplianceIp -and -not $ReplicationApplianceIp) {
        Write-Error "No appliance IPs resolved. Provide -DiscoveryApplianceIp and/or -ReplicationApplianceIp."
        return 1
    }

    # -- Print header ---------------------------------------------------------
    Write-Host "`n=== ASR Appliance Connectivity Check ===" -ForegroundColor Cyan
    if ($DiscoveryApplianceIp)   { Write-Host "  Discovery appliance   : $DiscoveryApplianceIp" }
    if ($ReplicationApplianceIp) { Write-Host "  Replication appliance : $ReplicationApplianceIp" }
    Write-Host "  Windows source VM     : $($testEnv.WindowsInstanceId) ($($testEnv.WindowsPrivateIp))"
    Write-Host "  Linux source VM       : $($testEnv.LinuxInstanceId) ($($testEnv.LinuxPrivateIp))"
    Write-Host ""

    # -- Build and run probes -------------------------------------------------
    $probes = Build-ProbeMatrix -TestEnv $testEnv `
                  -DiscoveryIp $DiscoveryApplianceIp `
                  -ReplicationIp $ReplicationApplianceIp

    $groups = @{}
    foreach ($p in $probes) {
        $key = "$($p.InstanceId)|$($p.OS)"
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = @{ InstanceId=$p.InstanceId; OS=$p.OS; SourceIp=$p.SourceIp; Probes=@() }
        }
        $groups[$key].Probes += $p
    }

    $allResults = [System.Collections.ArrayList]::new()
    foreach ($key in $groups.Keys) {
        $grp = $groups[$key]
        Write-Host "  Probing from $($grp.OS) ($($grp.InstanceId))..." -NoNewline
        $groupResults = Invoke-ProbeGroup `
            -InstanceId $grp.InstanceId -OS $grp.OS -SourceIp $grp.SourceIp `
            -Probes $grp.Probes -Region $Region -TimeoutSec $TimeoutSec
        Write-Host " done"
        foreach ($r in $groupResults) { $null = $allResults.Add($r) }
    }

    # -- Print result table ---------------------------------------------------
    Write-Host ""
    Write-Host ("  {0,-42} {1,-22} {2}" -f 'Probe', 'Destination', 'Result')
    Write-Host ("  {0,-42} {1,-22} {2}" -f ('─' * 42), ('─' * 22), ('─' * 8))
    $anyFailed = $false
    foreach ($r in $allResults) {
        $color = switch ($r.Status) { 'PASS' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        if ($r.Status -ne 'PASS') { $anyFailed = $true }
        Write-Host ("  {0,-42} {1,-22} {2}" -f $r.Label, $r.Target, $r.Status) -ForegroundColor $color
    }
    Write-Host ""

    if ($anyFailed) {
        Write-Host "CONNECTIVITY CHECK FAILED" -ForegroundColor Red
        Write-Host @"

  One or more required ports are blocked.  Common causes:
    - Missing inbound rule on source VM security group  (see NETWORK-REQUIREMENTS.md §1)
    - Missing inbound rule on appliance security group  (see NETWORK-REQUIREMENTS.md §3)
    - Windows firewall on source VM                     (disable all profiles via SSM)

  Run NETWORK-REQUIREMENTS.md §1 and §3 snippets to add the missing rules,
  then re-run:  .\Invoke-ConnectivityCheck.ps1
"@ -ForegroundColor Yellow
        return 1
    }

    Write-Host "CONNECTIVITY CHECK PASSED — all required ports are reachable." -ForegroundColor Green
    return 0
}

# ── Execute when run directly (not dot-sourced for unit tests) ────────────────
if ($MyInvocation.InvocationName -ne '.') {
    $exitCode = Invoke-ConnectivityCheckMain `
        -EnvFile                        $EnvFile `
        -DiscoveryApplianceInstanceId   $DiscoveryApplianceInstanceId `
        -ReplicationApplianceInstanceId $ReplicationApplianceInstanceId `
        -DiscoveryApplianceIp           $DiscoveryApplianceIp `
        -ReplicationApplianceIp         $ReplicationApplianceIp `
        -Region                         $Region `
        -TimeoutSec                     $TimeoutSec
    exit $exitCode
}
