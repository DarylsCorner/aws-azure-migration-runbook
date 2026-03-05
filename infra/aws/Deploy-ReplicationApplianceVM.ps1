<#
.SYNOPSIS
    Launches a second Windows Server 2022 EC2 instance to host the Azure Site
    Recovery (ASR) replication appliance (Configuration Server / DRA).

.DESCRIPTION
    This is a SEPARATE VM from the Azure Migrate discovery appliance.
    Microsoft does not support installing both components on the same host.

    Resources created / reused:
      sg-mig-appliance   -- reuses existing SG (RDP from caller, outbound all)
      mig-repl-appliance-vm  -- t3.xlarge WS2022, 127 GB OS disk

    UserData:
      - Sets Administrator password
      - Downloads ASR replication appliance PowerShell zip to C:\AzureMigrate
      - Extracts it so DRInstaller.ps1 is ready to run

    After RDP:
      1. Open PowerShell as Administrator
      2. cd C:\AzureMigrate
      3. .\DRInstaller.ps1
      4. In the Appliance Configuration Manager UI:
           - Paste the replication appliance key from rsv1-mig-landing
             (portal: rsv1-mig-landing -> Site Recovery ->
              Prepare Infrastructure -> copy key)
           - Sign in with your Azure account (device code)
           - Select vault: rsv1-mig-landing
           - Add source credentials:
               Windows: Administrator / MigW1ndows!2026
               Linux:   ec2-user   / MigL1nux!2026
           - Add source IPs: 10.10.1.17 (Windows)  10.10.1.64 (Linux)

.PARAMETER CallerCidr
    CIDR allowed for RDP.  Defaults to auto-detected public IP.

.PARAMETER InstanceType
    EC2 instance type.  Default: t3.xlarge (4 vCPU, 16 GB).
#>
param(
    [string] $CallerCidr   = '',
    [string] $InstanceType = 't3.xlarge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants from mig-test-env stack ─────────────────────────────────────────
$VpcId    = 'vpc-04387196e38cf73be'
$SubnetId = 'subnet-058c9fa5b6e8a7e9c'
$AmiId    = 'ami-0f7a0c94dce9ab456'   # Windows Server 2022 Full Base 2026-02-11
$Region   = 'us-east-1'

# ASR replication appliance PowerShell zip (modernized appliance path)
$DrZipUrl = 'https://aka.ms/V2ARcmApplianceCreationPowershellZip'

# ── Caller IP ─────────────────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($CallerCidr)) {
    $ip = (Invoke-RestMethod 'https://checkip.amazonaws.com').Trim()
    $CallerCidr = "$ip/32"
    Write-Host "  Detected public IP: $CallerCidr"
}

# ── Random admin password ─────────────────────────────────────────────────────
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$buf = [byte[]]::new(24)
$rng.GetBytes($buf)
$AdminPass = ('Mig1!' + [Convert]::ToBase64String($buf).Replace('=','').Replace('+','x').Replace('/','y').Substring(0,18))
Write-Host "  Generated admin password (save this): $AdminPass"

# ── Reuse or create security group ───────────────────────────────────────────
Write-Host "`n=== Security Group ===" -ForegroundColor Cyan
$AppSgId = aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$VpcId" "Name=group-name,Values=sg-mig-appliance" `
    --query 'SecurityGroups[0].GroupId' --output text 2>$null

if ($AppSgId -and $AppSgId -ne 'None') {
    Write-Host "  [reuse] $AppSgId (sg-mig-appliance)"

    # Ensure caller's IP has RDP access (may differ from original deployment)
    $rdpExists = aws ec2 describe-security-groups --group-ids $AppSgId `
        --query "SecurityGroups[0].IpPermissions[?FromPort==``3389``].IpRanges[?CidrIp=='$CallerCidr'].CidrIp" `
        --output text 2>$null
    if (-not $rdpExists) {
        aws ec2 authorize-security-group-ingress `
            --group-id $AppSgId `
            --protocol tcp --port 3389 `
            --cidr $CallerCidr --output none 2>$null
        Write-Host "  Added RDP rule for $CallerCidr"
    }

    # Ensure all required ASR ports are open from source VM subnet (idempotent — ignore duplicate error)
    # 443   — HTTPS Mobility agent → appliance
    # 9443  — replication data channel
    # 44368 — Appliance Configuration Manager (agent registration)
    foreach ($p in @(443, 9443, 44368)) {
        aws ec2 authorize-security-group-ingress `
            --group-id $AppSgId `
            --protocol tcp --port $p `
            --cidr '10.10.1.0/24' --output none 2>$null
    }
    Write-Host "  Ensured ports 443 (HTTPS), 9443 (replication data), 44368 (agent registration) open from 10.10.1.0/24"
} else {
    Write-Host "  [create] sg-mig-appliance..."
    $AppSgId = aws ec2 create-security-group `
        --group-name 'sg-mig-appliance' `
        --description 'Azure Migrate appliance VMs' `
        --vpc-id $VpcId `
        --query 'GroupId' --output text
    Write-Host "  Created: $AppSgId"
    aws ec2 authorize-security-group-ingress `
        --group-id $AppSgId `
        --protocol tcp --port 3389 `
        --cidr $CallerCidr --output none
    Write-Host "  Added RDP from $CallerCidr"

    # Port 443   — HTTPS communication, Mobility agent → appliance.
    # Port 9443  — replication data channel (source VM → appliance).
    # Port 44368 — Appliance Configuration Manager endpoint.
    # Source VMs must reach all three ports on the appliance.
    # Without 44368 the configurator reports "Invalid source config file".
    foreach ($p in @(443, 9443, 44368)) {
        aws ec2 authorize-security-group-ingress `
            --group-id $AppSgId `
            --protocol tcp --port $p `
            --cidr '10.10.1.0/24' --output none
    }
    Write-Host "  Added ports 443 (HTTPS), 9443 (replication data), 44368 (agent registration) from 10.10.1.0/24"
}

# ── UserData: download + extract DRInstaller zip ──────────────────────────────
$userDataPs = @"
<powershell>
net user Administrator "$AdminPass"
# Ensure RDP is enabled (EC2 WS2022 sometimes has it off by default)
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
New-Item -ItemType Directory -Force -Path C:\AzureMigrate | Out-Null
Set-Location C:\AzureMigrate
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri '$DrZipUrl' -OutFile 'DRAppliance.zip' -UseBasicParsing
    Expand-Archive -Path 'DRAppliance.zip' -DestinationPath 'C:\AzureMigrate' -Force
    "DRInstaller.ps1 ready in C:\AzureMigrate" | Out-File C:\Users\Administrator\Desktop\README.txt -Encoding ascii
} catch {
    "Download failed: `$_" | Out-File C:\AzureMigrate\download-error.txt
}
</powershell>
"@

$userDataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userDataPs))

# ── Launch instance ───────────────────────────────────────────────────────────
Write-Host "`n=== Launching replication appliance VM ===" -ForegroundColor Cyan

$existingId = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mig-repl-appliance-vm" "Name=instance-state-name,Values=running,pending,stopped" `
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>$null

if ($existingId -and $existingId -ne 'None') {
    Write-Host "  [exists] $existingId -- skipping launch"
    $InstanceId = $existingId
} else {
    Write-Host "  [launch] $InstanceType / $AmiId..."
    $launchResult = aws ec2 run-instances `
        --image-id $AmiId `
        --instance-type $InstanceType `
        --subnet-id $SubnetId `
        --security-group-ids $AppSgId `
        --user-data $userDataB64 `
        --associate-public-ip-address `
        --iam-instance-profile 'Name=mig-test-instance-profile' `
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=mig-repl-appliance-vm},{Key=Stack,Value=mig-test-env}]" `
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":127,"VolumeType":"gp3"}}]' `
        --output json 2>&1 | ConvertFrom-Json
    $InstanceId = $launchResult.Instances[0].InstanceId
    Write-Host "  Launched: $InstanceId"
}

# ── Wait for running ──────────────────────────────────────────────────────────
Write-Host "  Waiting for running state..." -NoNewline
do {
    Start-Sleep 10
    $state = aws ec2 describe-instances --instance-ids $InstanceId `
        --query 'Reservations[0].Instances[0].State.Name' --output text
    Write-Host -NoNewline "."
} while ($state -ne 'running')
Write-Host " running"

$publicIp = aws ec2 describe-instances --instance-ids $InstanceId `
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text

# ── Save env file (gitignored) ────────────────────────────────────────────────
$envFile = Join-Path $PSScriptRoot 'repl-appliance-vm.env'
@"
InstanceId=$InstanceId
PublicIp=$publicIp
AdminPass=$AdminPass
"@ | Set-Content $envFile -Encoding ascii
Write-Host "  Saved to $envFile"

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host @"

  Instance ID : $InstanceId
  Public IP   : $publicIp
  Username    : Administrator
  Password    : $AdminPass

  ** Wait ~5 minutes for UserData to finish downloading the ASR zip **

  Then RDP to $publicIp and run as Administrator:
    cd C:\AzureMigrate
    .\DRInstaller.ps1

  In the Appliance Configuration Manager that opens:
    1. Get replication key from portal:
         rsv1-mig-landing -> Site Recovery -> Prepare Infrastructure -> copy key
    2. Paste key -> Login (device code)
    3. Select vault: rsv1-mig-landing
    4. Add source credentials:
         Windows: Administrator / MigW1ndows!2026
         Linux:   ec2-user / MigL1nux!2026
    5. Add source IPs: 10.10.1.17  10.10.1.64
    6. Continue -> ~30 min install

"@
