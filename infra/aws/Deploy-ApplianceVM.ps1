<#
.SYNOPSIS
    Launches a Windows Server 2022 EC2 instance in the mig-test-env VPC,
    downloads the Azure Migrate physical appliance installer, and outputs
    RDP details so you can finish configuration in the appliance web UI.

.DESCRIPTION
    Resources created:
      sg-mig-appliance      -- new SG: RDP from caller IP, all outbound
      mig-appliance-vm      -- t3.xlarge (4 vCPU / 16 GB) Windows Server 2022

    Existing SGs updated (inbound rules added):
      mig-test-env-WindowsSg  -- WMI (5985,5986,135) + SMB (445) from appliance SG
      mig-test-env-LinuxSg    -- SSH (22) from appliance SG

    The instance userdata:
      - Sets a random Administrator password
      - Downloads the Azure Migrate appliance zip (~500 MB) to C:\AzureMigrate
      - Writes the project key to C:\Users\Administrator\Desktop\project-key.txt

    After RDP connect:
      cd C:\AzureMigrate
      .\AzureMigrateInstaller.ps1
      Then open https://mig-appliance:44368 and paste the key.

.PARAMETER ProjectKey
    The Azure Migrate project key generated in the portal.

.PARAMETER CallerCidr
    CIDR allowed for RDP.  Defaults to auto-detected public IP.

.PARAMETER InstanceType
    EC2 instance type.  Default: t3.xlarge (4 vCPU, 16 GB).
    Use t3.2xlarge (8 vCPU, 32 GB) to meet the official spec exactly.
#>
param(
    [string] $ProjectKey   = 'mig-appliance;PROD;0ad83fc1-ed30-4a49-a63c-b9d628e13479;6f9c9b05-871f-4edd-8183-893998be6ec3;rg-mig-project;migproject;b2da6a14-1c7b-46ed-8e7e-110ddbe3b4a1;baefb36f-07b0-4416-9ee0-d31feec1c1c0;https://discoverysrv.wus2.prod.migration.windowsazure.com/;westus2;false',
    [string] $CallerCidr   = '',
    [string] $InstanceType = 't3.xlarge'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants from mig-test-env stack ────────────────────────────────────────
$VpcId     = 'vpc-04387196e38cf73be'
$SubnetId  = 'subnet-058c9fa5b6e8a7e9c'
$AmiId     = 'ami-0f7a0c94dce9ab456'   # Windows Server 2022 Full Base 2026-02-11
$WinSgId   = 'sg-002b55db90da692b7'    # existing Windows test VM SG
$LinSgId   = 'sg-018c93c6ed949927a'    # existing Linux test VM SG
$Region    = 'us-east-1'

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

# ── Security group ────────────────────────────────────────────────────────────
Write-Host "`n=== Appliance Security Group ===" -ForegroundColor Cyan
$existingSg = aws ec2 describe-security-groups `
    --filters "Name=vpc-id,Values=$VpcId" "Name=group-name,Values=sg-mig-appliance" `
    --query 'SecurityGroups[0].GroupId' --output text 2>$null

if ($existingSg -and $existingSg -ne 'None') {
    Write-Host "  [exists] $existingSg"
    $AppSgId = $existingSg
} else {
    Write-Host "  [create] sg-mig-appliance..."
    $AppSgId = aws ec2 create-security-group `
        --group-name 'sg-mig-appliance' `
        --description 'Azure Migrate appliance VM' `
        --vpc-id $VpcId `
        --query 'GroupId' --output text
    Write-Host "  Created: $AppSgId"

    # RDP inbound from caller
    aws ec2 authorize-security-group-ingress `
        --group-id $AppSgId `
        --protocol tcp --port 3389 `
        --cidr $CallerCidr --output none
    Write-Host "  Added: Allow RDP from $CallerCidr"

    # HTTPS outbound to Azure (all outbound already default-allowed on AWS)
    # Default egress rule covers it -- no change needed
}

# ── Update Windows SG: allow appliance to discover over WMI/SMB ───────────────
Write-Host "`n=== Updating existing SGs for discovery ===" -ForegroundColor Cyan
foreach ($rule in @(
    @{ Sg = $WinSgId; Port = 5985;  Desc = 'WinRM HTTP' },
    @{ Sg = $WinSgId; Port = 5986;  Desc = 'WinRM HTTPS' },
    @{ Sg = $WinSgId; Port = 135;   Desc = 'RPC endpoint mapper' },
    @{ Sg = $WinSgId; Port = 445;   Desc = 'SMB' },
    @{ Sg = $LinSgId; Port = 22;    Desc = 'SSH' }
)) {
    $already = aws ec2 describe-security-groups --group-ids $rule.Sg `
        --query "SecurityGroups[0].IpPermissions[?FromPort==``$($rule.Port)``].SourceSecurityGroupId" `
        --output text 2>$null
    if ($already -match $AppSgId) {
        Write-Host "  [exists] $($rule.Desc) from appliance SG on $($rule.Sg)"
    } else {
        aws ec2 authorize-security-group-ingress `
            --group-id $rule.Sg `
            --protocol tcp --port $rule.Port `
            --source-group $AppSgId --output none 2>$null
        Write-Host "  [added]  $($rule.Desc) from appliance SG -> $($rule.Sg)"
    }
}

# ── UserData ──────────────────────────────────────────────────────────────────
$userDataPs = @"
<powershell>
net user Administrator "$AdminPass"
New-Item -ItemType Directory -Force -Path C:\AzureMigrate | Out-Null
Set-Location C:\AzureMigrate
Write-EventLog -LogName Application -Source 'AzureMigrateSetup' -EventId 1 -Message 'Downloading appliance zip...' -ErrorAction SilentlyContinue
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri 'https://go.microsoft.com/fwlink/?linkid=2140334' -OutFile 'AzureMigrateInstaller.zip' -UseBasicParsing
    Expand-Archive -Path 'AzureMigrateInstaller.zip' -DestinationPath 'C:\AzureMigrate' -Force
} catch {
    "Download failed: `$_" | Out-File C:\AzureMigrate\download-error.txt
}
"$ProjectKey" | Out-File C:\Users\Administrator\Desktop\project-key.txt -Encoding ascii
"Run: cd C:\AzureMigrate then .\AzureMigrateInstaller.ps1" | Out-File C:\Users\Administrator\Desktop\README.txt -Encoding ascii
</powershell>
"@

$userDataB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($userDataPs))

# ── Launch instance ────────────────────────────────────────────────────────────
Write-Host "`n=== Launching appliance VM ===" -ForegroundColor Cyan

$existingId = aws ec2 describe-instances `
    --filters "Name=tag:Name,Values=mig-appliance-vm" "Name=instance-state-name,Values=running,pending,stopped" `
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
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=mig-appliance-vm},{Key=Stack,Value=mig-test-env}]" `
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp3"}}]' `
        --output json 2>&1 | ConvertFrom-Json
    $InstanceId = $launchResult.Instances[0].InstanceId
    Write-Host "  Launched: $InstanceId"
}

# ── Wait for running ───────────────────────────────────────────────────────────
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

# ── Summary ────────────────────────────────────────────────────────────────────
Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host @"

  Instance ID : $InstanceId
  Public IP   : $publicIp
  Username    : Administrator
  Password    : $AdminPass

  ** Wait ~5 minutes for userdata to finish downloading the appliance zip **

  Then RDP to $publicIp and:
    1. Open PowerShell as Administrator
    2. cd C:\AzureMigrate
    3. .\AzureMigrateInstaller.ps1
    4. Open https://mig-appliance:44368 in the browser
    5. Paste key from Desktop\project-key.txt
    6. Add credentials for the EC2 VMs:
         Windows: Administrator / <EC2 password>
         Linux:   ec2-user / <SSH key or password>
    7. Add server IPs: 10.10.1.17 (Windows)  10.10.1.64 (Linux)
    8. Start discovery

"@
