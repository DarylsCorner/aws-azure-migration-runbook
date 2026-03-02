#!/usr/bin/env bash
# =============================================================================
# invoke-migration-readiness.sh
#
# In-guest AWS → Azure migration readiness auditor for Linux.
# Detects AWS components and validates Azure agent health.
# Does NOT make any changes.  Safe to run at any time.
#
# Usage:
#   sudo ./validation/invoke-migration-readiness.sh [OPTIONS]
#
# Options:
#   --mode <pre|post|both>   Scan mode (default: both)
#   --report <path>          JSON report output path
#                            Default: /var/log/readiness-report-<timestamp>.json
#
# Exit codes:
#   0  — Clean (Post mode: no AWS artifacts found, Azure agent healthy)
#   1  — Findings present or Azure agent issues
#   2  — Script error
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────
MODE="both"
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
REPORT_PATH="/var/log/readiness-report-${TIMESTAMP}.json"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)   MODE="${2:-both}"; shift ;;
        --report) REPORT_PATH="${2}"; shift ;;
        *) echo "[WARN] Unknown option: $1" ;;
    esac
    shift
done

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Must be run as root (sudo)." >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Finding infrastructure
# ─────────────────────────────────────────────────────────────────────────────
declare -a F_CATEGORY=()
declare -a F_NAME=()
declare -a F_STATUS=()
declare -a F_DETAIL=()
declare -a F_RECOMMENDATION=()

add_finding() {
    local category="$1"
    local name="$2"
    local status="$3"    # Found | NotFound | Pass | Fail | Warning | Info
    local detail="${4:-}"
    local recommendation="${5:-}"

    F_CATEGORY+=("$category")
    F_NAME+=("$name")
    F_STATUS+=("$status")
    F_DETAIL+=("$detail")
    F_RECOMMENDATION+=("$recommendation")

    local icon
    case "$status" in
        Found)    icon="[FOUND  ]" ;;
        NotFound) icon="[CLEAN  ]" ;;
        Pass)     icon="[PASS   ]" ;;
        Fail)     icon="[FAIL   ]" ;;
        Warning)  icon="[WARN   ]" ;;
        Info)     icon="[INFO   ]" ;;
        *)        icon="[?      ]" ;;
    esac
    local line="$icon $category / $name"
    [[ -n "$detail" ]] && line="$line: $detail"
    echo "$line"
    [[ -n "$recommendation" ]] && echo "          -> $recommendation"
    return 0
}

# Escape a string for inclusion in a JSON double-quoted value.
json_str() {
    local s="$1"
    s="${s//\\/\\\\}"    # \ -> \\
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# ─────────────────────────────────────────────────────────────────────────────
# Detect package manager
# ─────────────────────────────────────────────────────────────────────────────
detect_pkg_mgr() {
    if   command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v apt-get &>/dev/null; then echo "apt"
    else echo "unknown"
    fi
}
PKG_MGR=$(detect_pkg_mgr)

# ─────────────────────────────────────────────────────────────────────────────
# Check helpers
# ─────────────────────────────────────────────────────────────────────────────
check_service() {
    local svc="$1"
    local friendly="${2:-$1}"
    local category="${3:-Services}"

    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service"; then
        local state
        state=$(systemctl is-enabled "$svc" 2>/dev/null || echo "unknown")
        local active
        active=$(systemctl is-active "$svc" 2>/dev/null || echo "inactive")
        add_finding "$category" "$friendly" "Found" \
            "enabled=$state active=$active" \
            "Stop and disable service '$svc', then remove package on Cutover"
    else
        add_finding "$category" "$friendly" "NotFound"
    fi
}

check_package() {
    local pkg_yum="$1"
    local pkg_apt="${2:-$1}"
    local friendly="${3:-$pkg_yum}"
    local category="${4:-Installed Packages}"

    local installed=false
    local version=""

    case "$PKG_MGR" in
        dnf|yum)
            if rpm -q "$pkg_yum" &>/dev/null; then
                installed=true
                version=$(rpm -q --queryformat '%{VERSION}' "$pkg_yum" 2>/dev/null || echo "")
            fi
            ;;
        apt)
            if dpkg -l "$pkg_apt" 2>/dev/null | grep -q '^ii'; then
                installed=true
                version=$(dpkg -l "$pkg_apt" 2>/dev/null | awk '/^ii/{print $3}' || echo "")
            fi
            ;;
    esac

    if $installed; then
        add_finding "$category" "$friendly" "Found" \
            "${pkg_yum}/${pkg_apt} v${version}" \
            "Remove package during Cutover phase"
    else
        add_finding "$category" "$friendly" "NotFound"
    fi
}

check_path() {
    local path="$1"
    local friendly="${2:-$path}"
    local category="${3:-Filesystem}"

    if [[ -e "$path" ]]; then
        local size=""
        if [[ -d "$path" ]]; then
            size=$(du -sh "$path" 2>/dev/null | cut -f1 || echo "?")
            add_finding "$category" "$friendly" "Found" \
                "Path: $path  Size: $size" \
                "Remove directory"
        else
            size=$(wc -c < "$path" 2>/dev/null || echo "?")
            add_finding "$category" "$friendly" "Found" \
                "Path: $path  Size: ${size} bytes" \
                "Remove file"
        fi
    else
        add_finding "$category" "$friendly" "NotFound"
    fi
}

check_env_file_for_aws() {
    local file="$1"
    local category="${2:-Environment Variables}"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local found_vars=()
    local var
    for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
               AWS_DEFAULT_REGION AWS_REGION AWS_PROFILE \
               AWS_CONFIG_FILE AWS_SHARED_CREDENTIALS_FILE \
               AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE; do
        if grep -qE "(^|export )[[:space:]]*${var}=" "$file" 2>/dev/null; then
            found_vars+=("$var")
        fi
    done

    if [[ ${#found_vars[@]} -gt 0 ]]; then
        local list=""
        for _v in "${found_vars[@]}"; do
            list="${list:+$list, }$_v"
        done
        add_finding "$category" "AWS vars in $file" "Found" \
            "$list" \
            "Remove AWS_ variable declarations from $file"
    else
        add_finding "$category" "AWS vars in $file" "NotFound"
    fi
    return 0
}

check_hosts() {
    local pattern="$1"
    local friendly="$2"
    local category="${3:-Hosts File}"

    if grep -qE "$pattern" /etc/hosts 2>/dev/null; then
        add_finding "$category" "$friendly" "Found" \
            "Pattern '$pattern' found in /etc/hosts" \
            "Remove AWS-specific hosts entries"
    else
        add_finding "$category" "$friendly" "NotFound"
    fi
    return 0
}

check_cloud_init_datasource() {
    local category="cloud-init"

    if [[ ! -f /etc/cloud/cloud.cfg ]]; then
        add_finding "$category" "cloud.cfg" "Info" "cloud-init not installed"
        return 0
    fi

    if grep -qiE "^[[:space:]]*datasource_list:[[:space:]]*\[.*Ec2" /etc/cloud/cloud.cfg 2>/dev/null; then
        add_finding "$category" "Datasource (cloud.cfg)" "Found" \
            "Active datasource_list in /etc/cloud/cloud.cfg pins AWS Ec2 datasource" \
            "Comment out or remove the Ec2 datasource_list line; cleanup script handles this"
    else
        add_finding "$category" "Datasource (cloud.cfg)" "NotFound"
    fi

    # Azure datasource drop-in
    if [[ -f /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg ]]; then
        add_finding "$category" "Azure datasource drop-in" "Pass" \
            "90_azure_datasource.cfg present"
    else
        add_finding "$category" "Azure datasource drop-in" "Warning" \
            "90_azure_datasource.cfg not found" \
            "Run cleanup script to write Azure datasource drop-in"
    fi
    return 0
}

check_azure_agent() {
    local category="Azure Agent"

    local found_svc=""
    for svc_name in waagent walinuxagent; do
        if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc_name}\.service"; then
            found_svc="$svc_name"
            break
        fi
    done

    if [[ -z "$found_svc" ]] && ! command -v waagent &>/dev/null; then
        add_finding "$category" "waagent / WALinuxAgent" "Fail" \
            "Service not found and waagent binary not in PATH" \
            "Install azure-linux-agent / WALinuxAgent: dnf install WALinuxAgent  OR  apt-get install walinuxagent"
        return
    fi

    if [[ -n "$found_svc" ]]; then
        local active
        active=$(systemctl is-active "$found_svc" 2>/dev/null || echo "inactive")
        local enabled
        enabled=$(systemctl is-enabled "$found_svc" 2>/dev/null || echo "unknown")

        if [[ "$active" == "active" ]]; then
            add_finding "$category" "$found_svc" "Pass" \
                "active=$active enabled=$enabled"
        else
            add_finding "$category" "$found_svc" "Fail" \
                "active=$active enabled=$enabled" \
                "systemctl enable --now $found_svc"
        fi
    elif command -v waagent &>/dev/null; then
        add_finding "$category" "waagent binary" "Warning" \
            "waagent binary found but no systemd unit" \
            "Verify waagent is registered as a service"
    fi

    # Agent version
    local ver=""
    if command -v waagent &>/dev/null; then
        ver=$(waagent --version 2>/dev/null | head -1 || echo "")
    fi
    [[ -n "$ver" ]] && add_finding "$category" "Agent Version" "Info" "$ver"
    return 0
}

check_imds() {
    local category="Azure IMDS"

    local response
    if response=$(curl -sf --connect-timeout 3 \
        -H 'Metadata: true' \
        'http://169.254.169.254/metadata/instance?api-version=2021-02-01' 2>/dev/null); then
        # Check provider field
        local provider=""
        if command -v python3 &>/dev/null; then
            provider=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('compute',{}).get('provider',''))" 2>/dev/null || echo "")
        fi
        if [[ "$provider" == Microsoft* ]]; then
            local location=""
            if command -v python3 &>/dev/null; then
                location=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('compute',{}).get('location',''))" 2>/dev/null || echo "")
            fi
            add_finding "$category" "IMDS endpoint" "Pass" \
                "Azure IMDS responding. Provider: $provider, Region: $location"
        else
            add_finding "$category" "IMDS endpoint" "Warning" \
                "IMDS responded but provider='$provider' — expected 'Microsoft.Compute'"
        fi
    else
        add_finding "$category" "IMDS endpoint" "Warning" \
            "IMDS did not respond" \
            "Verify VM is running on Azure and Azure networking is configured"
    fi
}

# =============================================================================
# Run all checks
# =============================================================================
echo ""
echo "================================================"
echo " AWS -> Azure Migration Readiness Check (Linux)"
echo " Mode    : $MODE"
echo " Host    : $(hostname -f 2>/dev/null || hostname)"
echo " PkgMgr  : $PKG_MGR"
echo " Time    : $(date -u +"%Y-%m-%d %H:%M:%SZ")"
echo "================================================"
echo ""

# ── Services ─────────────────────────────────────────────────────────────────
echo "--- Services ---"
check_service "amazon-ssm-agent"         "AWS SSM Agent"
check_service "ssm-agent"                "AWS SSM Agent (alt)"
check_service "amazon-cloudwatch-agent"  "AWS CloudWatch Agent"
check_service "awslogs"                  "AWS Logs Agent (legacy)"
check_service "ec2-instance-connect"     "AWS EC2 Instance Connect"
check_service "aws-cfn-hup"              "AWS CloudFormation cfn-hup"
check_service "codedeploy-agent"         "AWS CodeDeploy Agent"

# ── Installed Packages ────────────────────────────────────────────────────────
echo "--- Installed Packages ---"
check_package "amazon-ssm-agent"         "amazon-ssm-agent"         "AWS SSM Agent"
check_package "amazon-cloudwatch-agent"  "amazon-cloudwatch-agent"  "AWS CloudWatch Agent"
check_package "awslogs"                  "awslogs"                  "AWS Logs Agent (legacy)"
check_package "aws-cfn-bootstrap"        "aws-cfn-bootstrap"        "AWS CloudFormation Bootstrap"
check_package "ec2-instance-connect"     "ec2-instance-connect"     "AWS EC2 Instance Connect"
check_package "codedeploy-agent"         "codedeploy"               "AWS CodeDeploy Agent"
check_package "amazon-ec2-hibinit-agent" "amazon-ec2-hibinit-agent" "AWS Hibernation Agent"

# ── Environment Files ─────────────────────────────────────────────────────────
echo "--- Environment Variables ---"
check_env_file_for_aws "/etc/environment"
check_env_file_for_aws "/etc/profile"
check_env_file_for_aws "/etc/bashrc"
check_env_file_for_aws "/etc/bash.bashrc"

# Profile.d drop-ins
shopt -s nullglob
for f in /etc/profile.d/aws*.sh /etc/profile.d/amazon*.sh; do
    if [[ -f "$f" ]]; then
        add_finding "Environment Variables" "profile.d drop-in: $f" "Found" \
            "$f" \
            "Remove AWS profile.d drop-in"
    fi
done
shopt -u nullglob

# ── Credential Directories ────────────────────────────────────────────────────
echo "--- Credentials & Credential Directories ---"
check_path "/root/.aws"                    "root .aws credentials"       "Credentials"
check_path "/var/lib/ssm-user/.aws"        "ssm-user .aws credentials"   "Credentials"
check_path "/var/lib/codedeploy-agent/.aws" "codedeploy .aws credentials" "Credentials"

# Warn about user home dirs (not auto-removed by cleanup script)
for d in /home/*/.aws; do
    [[ -d "$d" ]] || continue
    add_finding "Credentials" "User .aws: $d" "Warning" \
        "$d" \
        "Manual review required — cleanup script does not auto-remove user home .aws dirs"
done

# ── AWS Agent Config Directories ─────────────────────────────────────────────
echo "--- AWS Agent Directories ---"
check_path "/etc/amazon/ssm"      "SSM Agent config dir"  "Filesystem"
check_path "/var/lib/amazon/ssm"  "SSM Agent data dir"    "Filesystem"

# ── Hosts File ────────────────────────────────────────────────────────────────
echo "--- Hosts File ---"
check_hosts "169\.254\.169\.254.*ec2\.internal" "AWS EC2-internal metadata hostname"
check_hosts "instance-data\.ec2\.internal"      "AWS instance-data alias"

# ── cloud-init ────────────────────────────────────────────────────────────────
echo "--- cloud-init ---"
check_cloud_init_datasource

# cloud-init instance cache
check_path "/var/lib/cloud/instances" "cloud-init instance cache" "cloud-init"
check_path "/var/lib/cloud/data"      "cloud-init data cache"     "cloud-init"

# ── Cutover-phase paths (informational in Pre mode) ───────────────────────────
echo "--- Cutover-phase paths ---"
check_path "/var/log/amazon"          "AWS Amazon log directory"  "Filesystem"
check_path "/var/log/ssm"             "SSM Agent logs"            "Filesystem"
check_path "/etc/cfn"                 "cfn-hup config"            "Filesystem"
check_path "/opt/aws/bin"             "AWS bootstrap bin dir"     "Filesystem"
check_path "/etc/ec2-instance-connect" "EC2 Instance Connect config" "Filesystem"

# ── Azure Agent & IMDS ────────────────────────────────────────────────────────
echo "--- Azure Agent & IMDS ---"
check_azure_agent
check_imds

# =============================================================================
# Post-mode assertions
# =============================================================================
POST_AWS_COUNT=0
POST_AZURE_FAIL=0
POST_CLEAN=false

if [[ "$MODE" == "post" || "$MODE" == "both" ]]; then
    echo ""
    echo "--- Post-Cleanup Assertions ---"

    for i in "${!F_STATUS[@]}"; do
        local_cat="${F_CATEGORY[$i]}"
        local_status="${F_STATUS[$i]}"
        if [[ "$local_status" == "Found" ]] && \
           [[ "$local_cat" != "Azure Agent" ]] && \
           [[ "$local_cat" != "Azure IMDS" ]] && \
           [[ "$local_cat" != "cloud-init" || "${F_NAME[$i]}" == *datasource* || "${F_NAME[$i]}" == *Datasource* ]]; then
            (( POST_AWS_COUNT++ )) || true
        fi
        if [[ "$local_status" == "Fail" ]]; then
            (( POST_AZURE_FAIL++ )) || true
        fi
    done

    if [[ $POST_AWS_COUNT -eq 0 ]]; then
        echo "[PASS   ] No AWS components detected."
    else
        echo "[FAIL   ] $POST_AWS_COUNT AWS component(s) still present:"
        for i in "${!F_STATUS[@]}"; do
            if [[ "${F_STATUS[$i]}" == "Found" ]]; then
                echo "          - ${F_CATEGORY[$i]} / ${F_NAME[$i]}: ${F_DETAIL[$i]}"
            fi
        done
    fi

    if [[ $POST_AZURE_FAIL -eq 0 ]]; then
        echo "[PASS   ] All Azure agent checks passed."
    else
        for i in "${!F_STATUS[@]}"; do
            if [[ "${F_STATUS[$i]}" == "Fail" ]]; then
                echo "[FAIL   ] ${F_CATEGORY[$i]} / ${F_NAME[$i]}: ${F_DETAIL[$i]}"
                [[ -n "${F_RECOMMENDATION[$i]}" ]] && echo "          -> ${F_RECOMMENDATION[$i]}"
            fi
        done
    fi

    [[ $POST_AWS_COUNT -eq 0 && $POST_AZURE_FAIL -eq 0 ]] && POST_CLEAN=true || true
fi

# =============================================================================
# Summary counts
# =============================================================================
COUNT_FOUND=0; COUNT_NOTFOUND=0; COUNT_PASS=0
COUNT_FAIL=0;  COUNT_WARN=0;     COUNT_INFO=0

for s in "${F_STATUS[@]}"; do
    case "$s" in
        Found)    (( COUNT_FOUND++    )) || true ;;
        NotFound) (( COUNT_NOTFOUND++ )) || true ;;
        Pass)     (( COUNT_PASS++     )) || true ;;
        Fail)     (( COUNT_FAIL++     )) || true ;;
        Warning)  (( COUNT_WARN++     )) || true ;;
        Info)     (( COUNT_INFO++     )) || true ;;
    esac
done

echo ""
echo "============ Summary ============"
echo "  Found AWS components : $COUNT_FOUND"
echo "  Clean (not found)    : $COUNT_NOTFOUND"
echo "  Azure checks passed  : $COUNT_PASS"
echo "  Azure checks failed  : $COUNT_FAIL"
echo "  Warnings             : $COUNT_WARN"
echo "================================="

# =============================================================================
# Write JSON report
# =============================================================================
TOTAL_FINDINGS=${#F_NAME[@]}

{
    echo "{"
    echo "  \"schemaVersion\": \"1.0\","
    echo "  \"timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
    echo "  \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\","
    echo "  \"mode\": \"$MODE\","
    echo "  \"findings\": ["
    for i in "${!F_NAME[@]}"; do
        local_cat=$(json_str "${F_CATEGORY[$i]}")
        local_name=$(json_str "${F_NAME[$i]}")
        local_status="${F_STATUS[$i]}"
        local_detail=$(json_str "${F_DETAIL[$i]}")
        local_rec=$(json_str "${F_RECOMMENDATION[$i]}")
        _comma=","
        [[ $i -eq $((TOTAL_FINDINGS - 1)) ]] && _comma=""
        echo "    { \"category\": \"$local_cat\", \"name\": \"$local_name\", \"status\": \"$local_status\", \"detail\": \"$local_detail\", \"recommendation\": \"$local_rec\" }$_comma"
    done
    echo "  ],"
    echo "  \"summary\": {"
    echo "    \"found\":    $COUNT_FOUND,"
    echo "    \"notFound\": $COUNT_NOTFOUND,"
    echo "    \"pass\":     $COUNT_PASS,"
    echo "    \"fail\":     $COUNT_FAIL,"
    echo "    \"warning\":  $COUNT_WARN,"
    echo "    \"info\":     $COUNT_INFO"
    echo "  },"
    if [[ "$MODE" == "post" || "$MODE" == "both" ]]; then
        echo "  \"postAssertions\": {"
        echo "    \"awsComponentsFound\": $POST_AWS_COUNT,"
        echo "    \"azureAgentFailed\":   $POST_AZURE_FAIL,"
        echo "    \"cleanState\":         $( $POST_CLEAN && echo true || echo false )"
        echo "  }"
    else
        echo "  \"postAssertions\": null"
    fi
    echo "}"
} > "$REPORT_PATH" 2>/dev/null \
    && echo "Report: $REPORT_PATH" \
    || echo "[WARN] Could not write report to $REPORT_PATH"

# Exit with failure if Post mode and not clean
if [[ "$MODE" == "post" ]] && ! $POST_CLEAN; then
    exit 1
fi
exit 0
