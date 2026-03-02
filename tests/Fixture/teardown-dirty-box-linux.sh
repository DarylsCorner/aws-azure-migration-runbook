#!/usr/bin/env bash
# =============================================================================
# teardown-dirty-box-linux.sh
#
# Removes all fake AWS artifacts created by setup-dirty-box-linux.sh.
# Uses the marker tag to identify and remove exactly what was planted.
#
# Usage:
#   sudo ./tests/Fixture/teardown-dirty-box-linux.sh [--force]
#
# Options:
#   --force   Remove all known DirtyBox artifact patterns even without
#             manifest markers (full scan-and-wipe mode).
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

if [[ $EUID -ne 0 ]]; then
    echo "[TEARDOWN][ERROR] Must be run as root." >&2
    exit 1
fi

FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true ;;
        *) echo "[TEARDOWN][WARN] Unknown option: $1" ;;
    esac
    shift
done

MARKER="MIGRATION-TEST-DIRTYBOX"
REMOVED=0

ok()   { echo "  [-] $1"; ((++REMOVED)); }
skip() { echo "  [~] SKIP: $1"; }
warn() { echo "  [!] WARN: $1"; }
step() { echo ""; echo "[TEARDOWN] ── $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Helper: remove a path only if it contains our marker (or --force)
# ─────────────────────────────────────────────────────────────────────────────
safe_remove() {
    local path="$1"
    local label="${2:-$1}"

    if [[ ! -e "$path" ]]; then
        skip "$label — not found"
        return
    fi

    # Verify ownership via marker file or --force flag
    local has_marker=false
    if [[ -d "$path" ]]; then
        [[ -f "$path/.dirtybox" ]] && has_marker=true
    elif [[ -f "$path" ]]; then
        grep -qF "$MARKER" "$path" 2>/dev/null && has_marker=true
    fi

    if ! $has_marker && ! $FORCE; then
        skip "$label — no DirtyBox marker found (use --force to remove anyway)"
        return
    fi

    rm -rf "$path"
    ok "Removed: $label"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — Systemd service units
# ─────────────────────────────────────────────────────────────────────────────
step "Removing fake AWS systemd service units..."

SERVICES=(
    amazon-ssm-agent
    amazon-cloudwatch-agent
    awslogs
    aws-cfn-hup
    codedeploy-agent
)

for svc in "${SERVICES[@]}"; do
    unit_file="/etc/systemd/system/${svc}.service"
    if [[ ! -f "$unit_file" ]]; then
        skip "$unit_file — not found"
        continue
    fi

    # Only remove if it was created by DirtyBox (contains our marker) or --force
    if grep -qF "$MARKER" "$unit_file" 2>/dev/null || $FORCE; then
        # Disable and stop first (suppress errors — oneshot services may not be active)
        systemctl disable "$svc" 2>/dev/null || true
        systemctl stop    "$svc" 2>/dev/null || true
        rm -f "$unit_file"
        ok "Removed $unit_file"
        ((++REMOVED))
    else
        skip "$unit_file — not a DirtyBox unit (no marker). Use --force to remove."
    fi
done

systemctl daemon-reload 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — /etc/environment AWS block
# ─────────────────────────────────────────────────────────────────────────────
step "Removing AWS env block from /etc/environment..."

ENV_FILE="/etc/environment"
if [[ -f "$ENV_FILE" ]] && grep -qF "$MARKER" "$ENV_FILE" 2>/dev/null; then
    # Remove lines between (and including) the MARKER begin/end tags
    sed -i "/# --- ${MARKER} begin ---/,/# --- ${MARKER} end ---/d" "$ENV_FILE" 2>/dev/null || true
    # Remove any stray blank lines at end of file
    sed -i '/^[[:space:]]*$/{ /./!d }' "$ENV_FILE" 2>/dev/null || true
    ok "Removed AWS env block from $ENV_FILE"
    ((++REMOVED))
else
    skip "/etc/environment — no DirtyBox block found"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — profile.d drop-in
# ─────────────────────────────────────────────────────────────────────────────
step "Removing /etc/profile.d AWS drop-in..."
safe_remove "/etc/profile.d/aws_migration_test.sh" "/etc/profile.d/aws_migration_test.sh"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — /etc/hosts EC2 entries
# ─────────────────────────────────────────────────────────────────────────────
step "Removing AWS hosts entries from /etc/hosts..."

HOSTS_FILE="/etc/hosts"
if [[ -f "$HOSTS_FILE" ]] && grep -qF "$MARKER" "$HOSTS_FILE" 2>/dev/null; then
    # Restore from backup if available, otherwise strip the marker block
    if [[ -f "${HOSTS_FILE}.dirtybox.bak" ]]; then
        cp "${HOSTS_FILE}.dirtybox.bak" "$HOSTS_FILE"
        rm -f "${HOSTS_FILE}.dirtybox.bak"
        ok "Restored /etc/hosts from backup"
        ((++REMOVED))
    else
        sed -i "/# --- ${MARKER} begin ---/,/# --- ${MARKER} end ---/d" "$HOSTS_FILE" 2>/dev/null || true
        ok "Removed AWS hosts block from /etc/hosts"
        ((++REMOVED))
    fi
else
    skip "/etc/hosts — no DirtyBox block found"
    # Clean up stale backup if any
    [[ -f "${HOSTS_FILE}.dirtybox.bak" ]] && rm -f "${HOSTS_FILE}.dirtybox.bak"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — AWS credentials directories
# ─────────────────────────────────────────────────────────────────────────────
step "Removing AWS credentials directories..."

# Note: /root/.aws has a credentials file with MARKER text, not a .dirtybox file
for d in /root/.aws /var/lib/ssm-user/.aws /var/lib/codedeploy-agent/.aws; do
    if [[ ! -d "$d" ]]; then
        skip "$d — not found"
        continue
    fi
    # Check if it's ours via the credentials file marker
    if ( grep -qF "$MARKER" "$d/credentials" 2>/dev/null ) || $FORCE; then
        rm -rf "$d"
        ok "Removed $d"
        ((++REMOVED))
    else
        skip "$d — no DirtyBox marker in credentials (use --force to remove)"
    fi
done

# Parent dirs for service accounts (empty them only; don't remove parent)

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — AWS agent config/data directories
# ─────────────────────────────────────────────────────────────────────────────
step "Removing AWS agent config/data directories..."
safe_remove "/etc/amazon/ssm"     "/etc/amazon/ssm"
safe_remove "/var/lib/amazon/ssm" "/var/lib/amazon/ssm"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — cloud-init datasource reference
# ─────────────────────────────────────────────────────────────────────────────
step "Restoring cloud-init config..."

CLOUD_CFG="/etc/cloud/cloud.cfg"
if [[ -f "${CLOUD_CFG}.dirtybox.bak" ]]; then
    cp "${CLOUD_CFG}.dirtybox.bak" "$CLOUD_CFG"
    rm -f "${CLOUD_CFG}.dirtybox.bak"
    ok "Restored $CLOUD_CFG from backup"
    ((++REMOVED))
elif [[ -f "$CLOUD_CFG" ]] && grep -qF "$MARKER" "$CLOUD_CFG" 2>/dev/null; then
    sed -i "/# --- ${MARKER} begin/,/# --- ${MARKER} end ---/d" "$CLOUD_CFG" 2>/dev/null || true
    ok "Removed DirtyBox block from $CLOUD_CFG"
    ((++REMOVED))
else
    skip "$CLOUD_CFG — no DirtyBox block found"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — cloud-init instance cache
# ─────────────────────────────────────────────────────────────────────────────
step "Removing cloud-init instance cache..."
safe_remove "/var/lib/cloud/instances/i-0123456789abcdef0" "cloud-init fake instance dir"
safe_remove "/var/lib/cloud/data" "cloud-init data dir"

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 9 — Cutover-phase paths
# ─────────────────────────────────────────────────────────────────────────────
step "Removing cutover-phase AWS paths..."

safe_remove "/var/log/amazon"           "/var/log/amazon"
safe_remove "/var/log/ssm"             "/var/log/ssm"
safe_remove "/etc/cfn"                 "/etc/cfn"
safe_remove "/opt/aws"                 "/opt/aws"
safe_remove "/etc/ec2-instance-connect" "/etc/ec2-instance-connect"

# /run/cloud-init/results.json — only remove if it's our fake one
if [[ -f "/run/cloud-init/results.json" ]]; then
    if grep -qF "DataSourceEc2Local" "/run/cloud-init/results.json" 2>/dev/null || $FORCE; then
        rm -f "/run/cloud-init/results.json"
        ok "Removed /run/cloud-init/results.json"
        ((++REMOVED))
    else
        skip "/run/cloud-init/results.json — not a DirtyBox file (contains real data)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Clean up manifest
# ─────────────────────────────────────────────────────────────────────────────
[[ -f "/tmp/dirtybox-manifest.txt" ]] && rm -f "/tmp/dirtybox-manifest.txt"

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "[TEARDOWN] ════════════════════════════════════════"
echo "[TEARDOWN] DirtyBox Linux teardown complete."
echo "[TEARDOWN] Removed: $REMOVED item(s)"
echo "[TEARDOWN] ════════════════════════════════════════"
