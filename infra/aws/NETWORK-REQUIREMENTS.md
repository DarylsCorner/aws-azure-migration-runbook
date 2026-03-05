# Network & Credential Requirements for ASR Replication Appliance

These rules must be in place **before** adding source server IPs in the
Appliance Configuration Manager (`DRInstaller.ps1` → Configure credentials →
Add server IPs).

---

## 1. Replication Appliance → Source VMs (inbound on source VM SGs)

The replication appliance VM (`mig-repl-appliance-vm`, private IP `10.10.1.178`)
needs to reach each source VM on the following ports.

### Windows source VM (`10.10.1.17`, SG `sg-002b55db90da692b7`)

| Protocol | Port(s) | Purpose |
|----------|---------|---------|
| TCP | 135 | RPC endpoint mapper (WMI/remote management) |
| TCP | 445 | SMB (mobility service push) |
| TCP | 5985 | WinRM HTTP |
| TCP | 5986 | WinRM HTTPS |
| TCP | 9443 | ASR mobility service data channel |

```powershell
$cidr = "10.10.1.178/32"   # replication appliance private IP
$sg   = "sg-002b55db90da692b7"
foreach ($port in @(135, 445, 5985, 5986, 9443)) {
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port $port --cidr $cidr
}
```

### Linux source VM (`10.10.1.64`, SG `sg-002b55db90da692b7`)

| Protocol | Port(s) | Purpose |
|----------|---------|----------|
| TCP | 22 | SSH (mobility service push) |
| TCP | 9443 | ASR mobility service data channel |

```powershell
$cidr = "10.10.1.178/32"
$sg   = "sg-002b55db90da692b7"
foreach ($port in @(22, 9443)) {
    aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port $port --cidr $cidr
}
```

---

## 2. Source VM Credential Setup

### Windows (`10.10.1.17`)
- **Username:** `Administrator`
- **Password:** `MigW1ndows!2026`
- No extra configuration needed — WinRM is enabled by default on the test VM.

### Linux (`10.10.1.64`)
Root login must be enabled because the Configuration Manager hardcodes `root`
for Linux. Run via SSM (instance `i-0b5fb8a9552e16559`):

```bash
echo root:<PASSWORD> | sudo chpasswd
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

```powershell
# Via AWS SSM from local machine
aws ssm send-command --instance-id i-0b5fb8a9552e16559 `
  --document-name AWS-RunShellScript `
  --parameters 'commands=["echo root:<PASSWORD> | sudo chpasswd","sudo sed -i \"s/^#\\?PermitRootLogin.*/PermitRootLogin yes/\" /etc/ssh/sshd_config","sudo sed -i \"s/^#\\?PasswordAuthentication.*/PasswordAuthentication yes/\" /etc/ssh/sshd_config","sudo systemctl restart sshd","echo DONE"]'
```

- **Username:** `root`
- **Password:** *(the password set above — avoid `!` in SSM commands due to shell escaping)*

> **Note:** Avoid special characters like `!` in the password when setting it
> via SSM RunShellScript, as the shell will interpret them. Use a password
> without `!` or escape it properly.

---

## 3. Source VMs → Replication Appliance Inbound (SG `sg-01b33115f80213aa1`)

Source VMs must reach the appliance on ports **443**, **9443**, and **44368**.
All three are required — missing any one will break HTTPS communication,
replication, or agent registration.

| Protocol | Port  | Purpose |
|----------|-------|---------|
| TCP | 443   | HTTPS — Mobility agent → appliance control channel |
| TCP | 9443  | Replication data channel (source VM → appliance) |
| TCP | 44368 | Appliance Configuration Manager — Mobility agent registration. Without this, `UnifiedAgentConfigurator.exe` reports "Invalid source config file provided" even when config.json is valid. |

```powershell
$applianceSg = "sg-01b33115f80213aa1"  # appliance SG
aws ec2 authorize-security-group-ingress --group-id $applianceSg --protocol tcp --port 443   --cidr 10.10.1.0/24
aws ec2 authorize-security-group-ingress --group-id $applianceSg --protocol tcp --port 9443  --cidr 10.10.1.0/24
aws ec2 authorize-security-group-ingress --group-id $applianceSg --protocol tcp --port 44368 --cidr 10.10.1.0/24
```

---

## 3a. Discovery Appliance → Source VMs (inbound on source VM SGs)

The Azure Migrate discovery appliance (`10.10.1.192`) **polls source VMs** to
gather server inventory before replication is enabled.  The appliance initiates
the connection; source VMs must allow inbound on:

| Protocol | Port | Target VM | Purpose |
|----------|------|-----------|----------|
| TCP | 22   | Linux VM  | SSH — discovery appliance inventories Linux servers over SSH |
| TCP | 5985 | Windows VM | WinRM HTTP — discovery appliance inventories Windows servers over WinRM |

Both VMs share SG `sg-002b55db90da692b7`:

```powershell
$sg      = "sg-002b55db90da692b7"  # source VM SG (both Windows and Linux)
$discIp  = "10.10.1.192/32"        # discovery appliance private IP
# Port 22  — discovery appliance → Linux VM SSH
aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 22   --cidr $discIp
# Port 5985 — discovery appliance → Windows VM WinRM
aws ec2 authorize-security-group-ingress --group-id $sg --protocol tcp --port 5985 --cidr $discIp
```

> **Connectivity check:** The `Invoke-ConnectivityCheck.ps1` script validates
> this direction by running `Test-NetConnection` **from** the discovery
> appliance (via SSM) **to** each source VM on these ports.

---

## 4. Replication Appliance Outbound (SG `sg-01b33115f80213aa1`)

The appliance itself needs outbound HTTPS to Azure. Verify the SG allows:

| Protocol | Port | Destination | Purpose |
|----------|------|-------------|---------|
| TCP | 443 | `0.0.0.0/0` | Azure REST APIs, vault registration |
| TCP | 9443 | `0.0.0.0/0` | ASR replication data to Azure |

These are typically covered by a default "allow all outbound" egress rule.

---

## 5. Configuration Manager Entry Order

1. Connectivity type: **Connect directly (no proxy)**
2. Register with RSV: paste vault key from `rsv1-mig-landing` → Site Recovery
3. vCenter: **Skip**
4. Credentials:
   - Windows: `Administrator` / `MigW1ndows!2026`
   - Linux: `root` / `<root password set via SSM>`
5. Server IPs: `10.10.1.17`, `10.10.1.64`
