#!/usr/bin/env bash
# =============================================================================
# invoke-aws-cleanup.sh
#
# Removes or disables AWS-specific in-guest components from a Linux VM
# migrated to Azure via Azure Migrate.
#
# IDEMPOTENT — every action is preceded by an existence/state check.
# Safe to run during Test Migration and again at cutover.
#
# Usage:
#   sudo ./invoke-aws-cleanup.sh [OPTIONS]
#
# Options:
#   --dry-run          Log every action without making changes
#   --phase <value>    test-migration (default) | cutover
#   --report <path>    Write JSON report to <path>
#                      Default: /var/log/aws-cleanup-report-<timestamp>.json
#   --skip-agent-check Do not verify waagent after cleanup
#
# What this script does NOT touch:
#   - Application binaries (e.g. application code that calls aws-cli)
#   - User home directories under /home/* — flag for manual review
#   - ENA / NVMe driver modules — Azure Migrate handles driver swap
#   - /etc/fstab — EBS mount entries must be reviewed by application owner
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
PHASE="test-migration"
SKIP_AGENT_CHECK=false
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
REPORT_PATH="/var/log/aws-cleanup-report-${TIMESTAMP}.json"

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)            DRY_RUN=true ;;
        --phase)              PHASE="${2:-test-migration}"; shift ;;
        --report)             REPORT_PATH="${2}"; shift ;;
        --skip-agent-check)   SKIP_AGENT_CHECK=true ;;
        *) echo "[WARN ] Unknown option: $1" ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
# Guard: must run as root
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] This script must be run as root (sudo)." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Detect distro family and package manager
# ─────────────────────────────────────────────────────────────────────────────
detect_package_manager() {
    if   command -v dnf  &>/dev/null; then echo "dnf"
    elif command -v yum  &>/dev/null; then echo "yum"
    elif command -v apt-get &>/dev/null; then echo "apt"
    else echo "unknown"
    fi
}

PKG_MGR=$(detect_package_manager)

# ─────────────────────────────────────────────────────────────────────────────
# Report infrastructure
# ─────────────────────────────────────────────────────────────────────────────
declare -a ACTION_NAMES=()
declare -a ACTION_STATUSES=()
declare -a ACTION_DETAILS=()

log() {
    local level="${1:-INFO}"
    local msg="${2:-}"
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    printf "%s [%-5s] %s\n" "$ts" "$level" "$msg"
}

add_action() {
    local name="$1"
    local status="$2"   # Completed | Skipped | DryRun | Error
    local detail="${3:-}"
    ACTION_NAMES+=("$name")
    ACTION_STATUSES+=("$status")
    ACTION_DETAILS+=("$detail")
    local level="INFO"
    [[ "$status" == "Error"  ]] && level="ERROR"
    [[ "$status" == "DryRun" ]] && level="DRY  "
    log "$level" "[$status] $name${detail:+ — $detail}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: stop and disable a systemd service (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
disable_service_if_present() {
    local svc="$1"
    local friendly="${2:-$1}"

    if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service"; then
        add_action "Disable Service: $friendly" "Skipped" "Service unit not found"
        return
    fi

    if $DRY_RUN; then
        add_action "Disable Service: $friendly" "DryRun" "Would stop and disable $svc.service"
        return
    fi

    systemctl stop    "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
    add_action "Disable Service: $friendly" "Completed" "Stopped and disabled"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a package (idempotent, distro-agnostic)
# ─────────────────────────────────────────────────────────────────────────────
remove_package_if_installed() {
    local pkg_yum="$1"   # package name on yum/dnf
    local pkg_apt="${2:-$1}"  # package name on apt (defaults to same)
    local friendly="${3:-$pkg_yum}"

    local installed=false
    case "$PKG_MGR" in
        dnf|yum)
            rpm -q "$pkg_yum" &>/dev/null && installed=true ;;
        apt)
            dpkg -l "$pkg_apt" 2>/dev/null | grep -q '^ii' && installed=true ;;
    esac

    if ! $installed; then
        add_action "Remove Package: $friendly" "Skipped" "Package not installed"
        return
    fi

    if $DRY_RUN; then
        add_action "Remove Package: $friendly" "DryRun" "Would remove $pkg_yum / $pkg_apt"
        return
    fi

    case "$PKG_MGR" in
        dnf)  dnf  remove -y "$pkg_yum" &>/dev/null ;;
        yum)  yum  remove -y "$pkg_yum" &>/dev/null ;;
        apt)  DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge "$pkg_apt" &>/dev/null ;;
        *)
            add_action "Remove Package: $friendly" "Error" "Unsupported package manager: $PKG_MGR"
            return
        ;;
    esac
    add_action "Remove Package: $friendly" "Completed" "Package removed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a file or directory (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
remove_path_if_present() {
    local path="$1"
    local friendly="${2:-$path}"

    if [[ ! -e "$path" ]]; then
        add_action "Remove Path: $friendly" "Skipped" "Path not found"
        return
    fi

    if $DRY_RUN; then
        add_action "Remove Path: $friendly" "DryRun" "Would remove: $path"
        return
    fi

    rm -rf "$path"
    add_action "Remove Path: $friendly" "Completed" "Removed: $path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove lines matching a pattern from a file (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
remove_lines_matching() {
    local file="$1"
    local pattern="$2"
    local friendly="${3:-$file}"

    if [[ ! -f "$file" ]]; then
        add_action "Edit File: $friendly" "Skipped" "File not found: $file"
        return
    fi

    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        add_action "Edit File: $friendly" "Skipped" "Pattern not found in $file"
        return
    fi

    if $DRY_RUN; then
        local count
        count=$(grep -cE "$pattern" "$file" || true)
        add_action "Edit File: $friendly" "DryRun" "Would remove $count line(s) matching '$pattern' from $file"
        return
    fi

    local tmp
    tmp=$(mktemp)
    grep -vE "$pattern" "$file" > "$tmp" || true
    mv "$tmp" "$file"
    add_action "Edit File: $friendly" "Completed" "Removed lines matching '$pattern' from $file"
}

# =============================================================================
# SECTION 1 — Pre-flight
# =============================================================================
log INFO "════════════════════════════════════════════════"
log INFO " AWS → Azure In-Guest Cleanup (Linux)"
log INFO " Phase   : $PHASE"
log INFO " DryRun  : $DRY_RUN"
log INFO " Host    : $(hostname -f 2>/dev/null || hostname)"
log INFO " PkgMgr  : $PKG_MGR"
log INFO " Started : $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
log INFO "════════════════════════════════════════════════"

$DRY_RUN && log WARN "DRY-RUN MODE — no changes will be made"

# =============================================================================
# SECTION 2 — AWS Services: stop + disable
# =============================================================================
log INFO "--- Section 2: AWS Services ---"

disable_service_if_present "amazon-ssm-agent"           "AWS SSM Agent"
disable_service_if_present "ssm-agent"                  "AWS SSM Agent (alt name)"
disable_service_if_present "amazon-cloudwatch-agent"    "AWS CloudWatch Agent"
disable_service_if_present "awslogs"                    "AWS Logs Agent (legacy)"
disable_service_if_present "ec2-instance-connect"       "AWS EC2 Instance Connect"
disable_service_if_present "aws-cfn-hup"                "AWS CloudFormation cfn-hup"
disable_service_if_present "codedeploy-agent"           "AWS CodeDeploy Agent"

# =============================================================================
# SECTION 3 — AWS Packages: remove
# =============================================================================
log INFO "--- Section 3: AWS Packages ---"

remove_package_if_installed "amazon-ssm-agent"        "amazon-ssm-agent"    "AWS SSM Agent"
remove_package_if_installed "amazon-cloudwatch-agent" "amazon-cloudwatch-agent" "AWS CloudWatch Agent"
remove_package_if_installed "awslogs"                 "awslogs"             "AWS Logs Agent (legacy)"
remove_package_if_installed "aws-cfn-bootstrap"       "aws-cfn-bootstrap"   "AWS CloudFormation Bootstrap"
remove_package_if_installed "ec2-instance-connect"    "ec2-instance-connect" "AWS EC2 Instance Connect"
remove_package_if_installed "codedeploy-agent"        "codedeploy"          "AWS CodeDeploy Agent"
remove_package_if_installed "amazon-ec2-hibinit-agent" "amazon-ec2-hibinit-agent" "AWS Hibernation Agent"

# AWS CLI — intentionally skipped; app workloads may invoke 'aws' commands.
# Uncomment if confirmed safe:
# remove_package_if_installed "awscli" "awscli" "AWS CLI v1"
# remove_path_if_present "/usr/local/bin/aws"   "AWS CLI v2 binary"
# remove_path_if_present "/usr/local/aws-cli"   "AWS CLI v2 install dir"
add_action "Remove Package: AWS CLI" "Skipped" \
    "Intentionally skipped — app binaries may call 'aws'. Review manually before cutover."

# =============================================================================
# SECTION 4 — AWS Credentials and Profile Files
# =============================================================================
log INFO "--- Section 4: AWS Credentials & Profiles ---"

# Root account
remove_path_if_present "/root/.aws"  "root .aws credentials directory"

# Service-account home dirs that are known infra accounts
# /home/* directories are NOT touched — flagged for manual app-owner review
for dir in /var/lib/ssm-user/.aws /var/lib/codedeploy-agent/.aws; do
    remove_path_if_present "$dir" "$dir"
done

# Warn about remaining user home dirs with .aws credentials
if ls /home/*/.aws 2>/dev/null | grep -q '.'; then
    log WARN "Found .aws directories under /home/* — these must be reviewed by application owners"
    for d in /home/*/.aws; do
        add_action "Found User .aws: $d" "Skipped" "Manual review required — not auto-removed"
    done
fi

# /etc/aws* — configuration directories written by agents
remove_path_if_present "/etc/amazon/ssm"       "SSM Agent config directory"
remove_path_if_present "/var/lib/amazon/ssm"   "SSM Agent data directory"

# =============================================================================
# SECTION 5 — Environment Variables
# =============================================================================
log INFO "--- Section 5: Environment Variables ---"

AWS_VARS=(
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    AWS_SESSION_TOKEN
    AWS_DEFAULT_REGION
    AWS_REGION
    AWS_PROFILE
    AWS_CONFIG_FILE
    AWS_SHARED_CREDENTIALS_FILE
    AWS_ROLE_ARN
    AWS_WEB_IDENTITY_TOKEN_FILE
)

for env_file in /etc/environment /etc/profile /etc/bashrc /etc/bash.bashrc; do
    for var in "${AWS_VARS[@]}"; do
        remove_lines_matching "$env_file" "^[[:space:]]*export[[:space:]]+${var}=" \
            "Env $var in $env_file"
        remove_lines_matching "$env_file" "^[[:space:]]*${var}=" \
            "Env $var (unquoted) in $env_file"
    done
done

# /etc/profile.d/ drop-ins created by AWS agents
for f in /etc/profile.d/aws*.sh /etc/profile.d/amazon*.sh; do
    [[ -f "$f" ]] && remove_path_if_present "$f" "AWS profile.d drop-in: $f"
done

# =============================================================================
# SECTION 6 — /etc/hosts: AWS metadata endpoint overrides
# =============================================================================
log INFO "--- Section 6: Hosts File ---"

# NOTE: 169.254.169.254 is the Azure IMDS address too.
# We only remove lines that explicitly name AWS-specific hostnames.
remove_lines_matching "/etc/hosts" "169\.254\.169\.254.*ec2\.internal" \
    "AWS EC2-internal metadata hostname"
remove_lines_matching "/etc/hosts" "instance-data\.ec2\.internal" \
    "AWS instance-data alias"

# =============================================================================
# SECTION 7 — cloud-init: remove AWS datasource, add Azure datasource
# =============================================================================
log INFO "--- Section 7: cloud-init Datasource ---"

CLOUDINIT_CFG="/etc/cloud/cloud.cfg"
DATASOURCE_FILE="/etc/cloud/cloud.cfg.d/90_azure_datasource.cfg"

if [[ -f "$CLOUDINIT_CFG" ]]; then
    # Remove ExplicitlySet datasource_list that pins AWS
    if grep -qiE "Ec2|AmazonEC2|aws" "$CLOUDINIT_CFG" 2>/dev/null; then
        if $DRY_RUN; then
            add_action "cloud-init: Datasource config" "DryRun" \
                "Would remove AWS datasource references from $CLOUDINIT_CFG"
        else
            # Comment out the old datasource_list rather than delete it
            sed -i 's/^\(datasource_list:.*Ec2.*\)$/#MIGRATED: \1/' "$CLOUDINIT_CFG" 2>/dev/null || true
            add_action "cloud-init: Datasource config" "Completed" \
                "Commented out AWS datasource_list in $CLOUDINIT_CFG"
        fi
    else
        add_action "cloud-init: Datasource config" "Skipped" \
            "No AWS datasource reference found in cloud.cfg"
    fi

    # Write Azure datasource drop-in
    if [[ -f "$DATASOURCE_FILE" ]]; then
        add_action "cloud-init: Azure datasource drop-in" "Skipped" \
            "File already exists: $DATASOURCE_FILE"
    else
        if $DRY_RUN; then
            add_action "cloud-init: Azure datasource drop-in" "DryRun" \
                "Would write: $DATASOURCE_FILE"
        else
            cat > "$DATASOURCE_FILE" <<'EOF'
# Written by AWS→Azure migration cleanup script
# Instructs cloud-init to use only the Azure datasource
datasource_list: [ Azure ]
datasource:
  Azure:
    apply_network_config: true
EOF
            add_action "cloud-init: Azure datasource drop-in" "Completed" \
                "Written: $DATASOURCE_FILE"
        fi
    fi
else
    add_action "cloud-init: Datasource config" "Skipped" "cloud-init not installed"
fi

# Remove cached EC2 metadata/userdata from cloud-init
remove_path_if_present "/var/lib/cloud/instances" "cloud-init instance cache (EC2 seed data)"
remove_path_if_present "/var/lib/cloud/data" "cloud-init data cache"

# =============================================================================
# SECTION 8 — AWS-specific kernel modules (informational only; not removed)
# Removing xen or virtio modules while the VM is live can cause data loss.
# Azure Migrate installs correct drivers during replication.
# =============================================================================
log INFO "--- Section 8: Kernel Modules (informational) ---"

AWS_MODULES=("xen_blkfront" "xen_netfront" "xen-blkfront" "xen-netfront" "ena" "nvme")
for mod in "${AWS_MODULES[@]}"; do
    if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
        add_action "Kernel Module: $mod" "Skipped" \
            "Module loaded — NOT removed. Azure Migrate replaces drivers during replication."
    fi
done

# =============================================================================
# SECTION 9 — Cutover-only: deep clean of residual data
# =============================================================================
if [[ "$PHASE" == "cutover" ]]; then
    log INFO "--- Section 9: Cutover-only Deep Clean ---"

    # SSM and CloudWatch log data
    remove_path_if_present "/var/log/amazon" "AWS Amazon log directory"
    remove_path_if_present "/var/log/ssm"    "SSM Agent logs"

    # EC2 instance metadata cache
    remove_path_if_present "/run/cloud-init/results.json" "cloud-init results cache"

    # Remove stale EC2 system-level SSH keys injected by EC2 Instance Connect
    if [[ -d /etc/ec2-instance-connect ]]; then
        remove_path_if_present "/etc/ec2-instance-connect" "EC2 Instance Connect config"
    fi

    # cfn-hup residuals
    remove_path_if_present "/etc/cfn"             "CloudFormation cfn-hup config"
    remove_path_if_present "/opt/aws/bin"         "AWS bootstrap bin directory"
    remove_path_if_present "/opt/aws/python"      "AWS bootstrap Python env"

else
    log INFO "--- Section 9: Skipped (test-migration phase — deep clean deferred to cutover) ---"
    add_action "Deep Clean" "Skipped" \
        "Deferred to cutover phase to preserve rollback capability"
fi

# =============================================================================
# SECTION 10 — Azure Linux Agent (waagent)
# =============================================================================
log INFO "--- Section 10: Azure Linux Agent ---"

if $SKIP_AGENT_CHECK; then
    add_action "Azure Linux Agent Check" "Skipped" "Skipped by --skip-agent-check"
else
    if ! command -v waagent &>/dev/null && ! systemctl list-unit-files 2>/dev/null | grep -q walinuxagent; then
        add_action "Azure Linux Agent Check" "Error" \
            "waagent not found. Install azure-linux-agent / WALinuxAgent before the VM is usable on Azure."
        log WARN "Install with: dnf install WALinuxAgent  OR  apt-get install walinuxagent"
    else
        # Ensure it's enabled
        for svc_name in waagent walinuxagent; do
            if systemctl list-unit-files 2>/dev/null | grep -q "^${svc_name}\.service"; then
                if $DRY_RUN; then
                    add_action "Azure Linux Agent: $svc_name" "DryRun" \
                        "Would enable and start $svc_name"
                else
                    systemctl enable "$svc_name" 2>/dev/null || true
                    systemctl start  "$svc_name" 2>/dev/null || true
                    STATUS=$(systemctl is-active "$svc_name" 2>/dev/null || echo "unknown")
                    add_action "Azure Linux Agent: $svc_name" "Completed" \
                        "Enabled and started — status: $STATUS"
                fi
            fi
        done
    fi
fi

# =============================================================================
# SECTION 11 — Report
# =============================================================================
TOTAL=${#ACTION_NAMES[@]}
COMPLETED=0; SKIPPED=0; DRYRUN=0; ERRORS=0

for s in "${ACTION_STATUSES[@]}"; do
    case "$s" in
        Completed) ((++COMPLETED)) ;;
        Skipped)   ((++SKIPPED))  ;;
        DryRun)    ((++DRYRUN))   ;;
        Error)     ((++ERRORS))   ;;
    esac
done

# Build JSON report
{
    echo "{"
    echo "  \"schemaVersion\": \"1.0\","
    echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    echo "  \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\","
    echo "  \"phase\": \"$PHASE\","
    echo "  \"dryRun\": $DRY_RUN,"
    echo "  \"actions\": ["
    for i in "${!ACTION_NAMES[@]}"; do
        local_name="${ACTION_NAMES[$i]//\\/\\\\}"
        local_name="${local_name//\"/\\\"}"
        local_status="${ACTION_STATUSES[$i]}"
        local_detail="${ACTION_DETAILS[$i]//\\/\\\\}"
        local_detail="${local_detail//\"/\\\"}"
        comma=","
        [[ $i -eq $((TOTAL - 1)) ]] && comma=""
        echo "    { \"name\": \"$local_name\", \"status\": \"$local_status\", \"detail\": \"$local_detail\" }$comma"
    done
    echo "  ],"
    echo "  \"summary\": {"
    echo "    \"total\": $TOTAL,"
    echo "    \"completed\": $COMPLETED,"
    echo "    \"skipped\": $SKIPPED,"
    echo "    \"dryRun\": $DRYRUN,"
    echo "    \"errors\": $ERRORS"
    echo "  }"
    echo "}"
} > "$REPORT_PATH" 2>/dev/null && log INFO "Report written to: $REPORT_PATH" \
    || log WARN "Could not write report to $REPORT_PATH"

log INFO "════════════ Summary ════════════"
log INFO "  Total   : $TOTAL"
log INFO "  Done    : $COMPLETED"
log INFO "  Skipped : $SKIPPED"
log INFO "  DryRun  : $DRYRUN"
log INFO "  Errors  : $ERRORS"
log INFO "═════════════════════════════════"

[[ $ERRORS -gt 0 ]] && exit 2
exit 0
