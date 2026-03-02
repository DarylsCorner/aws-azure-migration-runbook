#!/usr/bin/env bash
# =============================================================================
# setup-dirty-box-linux.sh
#
# Plants fake AWS in-guest artifacts on a Linux VM so that
# invoke-aws-cleanup.sh has real targets to act on — without needing
# to install actual AWS software.
#
# Creates the same systemd units, directory trees, environment variables,
# hosts entries, credential dirs, and cloud-init datasource references that
# a real EC2-migrated VM would have.
#
# SAFE TO RUN ON ANY LINUX TEST MACHINE.  All artifacts are labelled
# MIGRATION-TEST-DIRTYBOX.  Pair with teardown-dirty-box-linux.sh to restore.
#
# Usage:
#   sudo ./tests/Fixture/setup-dirty-box-linux.sh [--phase cutover]
#
# Options:
#   --phase test-migration   Plant only test-migration artifacts (default)
#   --phase cutover          Also plant cutover-phase-only artifacts
#   --skip-services          Do not create systemd unit files
#   --skip-env               Do not modify /etc/environment or profile.d
#   --skip-hosts             Do not modify /etc/hosts
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────
PHASE="test-migration"
SKIP_SERVICES=false
SKIP_ENV=false
SKIP_HOSTS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)          PHASE="${2:-test-migration}"; shift ;;
        --skip-services)  SKIP_SERVICES=true ;;
        --skip-env)       SKIP_ENV=true ;;
        --skip-hosts)     SKIP_HOSTS=true ;;
        *) echo "[SETUP][WARN] Unknown option: $1" ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
# Guards
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[SETUP][ERROR] Must be run as root." >&2
    exit 1
fi

MARKER="MIGRATION-TEST-DIRTYBOX"
MANIFEST="/tmp/dirtybox-manifest.txt"
> "$MANIFEST"

ok()     { echo "  [+] $1"; }
skip()   { echo "  [~] SKIP: $1"; }
warn()   { echo "  [!] WARN: $1"; }
record() { echo "$1" >> "$MANIFEST"; }
step()   { echo ""; echo "[SETUP] ── $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1 — Systemd service units
# The cleanup script uses  systemctl list-unit-files  to detect these.
# Creating real (but harmless) unit files is the cleanest way to fake presence.
# ─────────────────────────────────────────────────────────────────────────────
if ! $SKIP_SERVICES; then
    step "Creating fake AWS systemd service units..."

    SERVICES=(
        amazon-ssm-agent
        amazon-cloudwatch-agent
        awslogs
        aws-cfn-hup
        codedeploy-agent
    )

    for svc in "${SERVICES[@]}"; do
        unit_file="/etc/systemd/system/${svc}.service"
        if [[ -f "$unit_file" ]]; then
            skip "$unit_file already exists"
            continue
        fi
        cat > "$unit_file" <<EOF
[Unit]
Description=Fake ${svc} (${MARKER})
ConditionPathExists=/dev/null

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
        ok "Created $unit_file"
        record "SYSTEMD_UNIT:$unit_file"
    done

    # Reload unit file database so systemctl list-unit-files picks them up
    systemctl daemon-reload 2>/dev/null || true

    # Enable the primary service so it shows as "enabled"
    if systemctl list-unit-files 2>/dev/null | grep -q "^amazon-ssm-agent\.service"; then
        if ! systemctl is-enabled amazon-ssm-agent &>/dev/null; then
            systemctl enable amazon-ssm-agent 2>/dev/null || true
            ok "Enabled amazon-ssm-agent"
        else
            skip "amazon-ssm-agent already enabled"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2 — AWS environment variables in /etc/environment
# The cleanup script removes  export VAR=  and  VAR=  lines from this file.
# ─────────────────────────────────────────────────────────────────────────────
if ! $SKIP_ENV; then
    step "Adding AWS environment variables to /etc/environment..."

    ENV_FILE="/etc/environment"
    BEGIN_TAG="# --- ${MARKER} begin ---"
    END_TAG="# --- ${MARKER} end ---"

    if grep -qF "$MARKER" "$ENV_FILE" 2>/dev/null; then
        skip "AWS env block already present in $ENV_FILE"
    else
        # /etc/environment uses KEY=VALUE (no export) — both forms are planted
        # so the cleanup script's two grep passes each find a target.
        cat >> "$ENV_FILE" <<EOF

${BEGIN_TAG}
AWS_DEFAULT_REGION=us-east-1
AWS_REGION=us-east-1
AWS_PROFILE=migration-test-profile
AWS_CONFIG_FILE=/root/.aws/config
${END_TAG}
EOF
        ok "Added AWS env block to $ENV_FILE"
        record "ENV_BLOCK:$ENV_FILE"
    fi

    # ─── profile.d drop-in (uses export keyword) ───────────────────────────
    step "Creating /etc/profile.d AWS drop-in..."
    PROFILED="/etc/profile.d/aws_migration_test.sh"
    if [[ -f "$PROFILED" ]]; then
        skip "$PROFILED already exists"
    else
        cat > "$PROFILED" <<EOF
# ${MARKER} — created by setup-dirty-box-linux.sh
export AWS_DEFAULT_REGION=us-east-1
export AWS_REGION=us-east-1
EOF
        ok "Created $PROFILED"
        record "FILE:$PROFILED"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3 — /etc/hosts EC2 metadata entries
# The cleanup script removes lines matching 169\.254\.169\.254.*ec2\.internal
# ─────────────────────────────────────────────────────────────────────────────
if ! $SKIP_HOSTS; then
    step "Adding AWS hosts entries to /etc/hosts..."

    HOSTS_FILE="/etc/hosts"
    if grep -qF "instance-data.ec2.internal" "$HOSTS_FILE" 2>/dev/null; then
        skip "AWS hosts entries already present"
    else
        cp "$HOSTS_FILE" "${HOSTS_FILE}.dirtybox.bak"
        cat >> "$HOSTS_FILE" <<EOF

# --- ${MARKER} begin ---
169.254.169.254  instance-data.ec2.internal  # ${MARKER}
# --- ${MARKER} end ---
EOF
        ok "Added EC2 metadata hosts entries"
        record "HOSTS_BLOCK:/etc/hosts"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 4 — AWS credentials directories
# /root/.aws and service-account .aws dirs; the cleanup script removes these.
# ─────────────────────────────────────────────────────────────────────────────
step "Creating AWS credentials directories..."

CRED_DIRS=(
    /root/.aws
    /var/lib/ssm-user/.aws
    /var/lib/codedeploy-agent/.aws
)

for d in "${CRED_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        skip "$d already exists"
    else
        mkdir -p "$d"
        cat > "$d/credentials" <<EOF
[default]
# ${MARKER} — fake credentials written by setup-dirty-box-linux.sh
aws_access_key_id     = AKIAIOSFODNN7FAKETEST
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYFAKETEST
EOF
        ok "Created $d"
        record "DIR:$d"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 5 — AWS agent config/data directories
# /etc/amazon/ssm and /var/lib/amazon/ssm
# ─────────────────────────────────────────────────────────────────────────────
step "Creating AWS agent config/data directories..."

AGENT_DIRS=(
    /etc/amazon/ssm
    /var/lib/amazon/ssm
)

for d in "${AGENT_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        skip "$d already exists"
    else
        mkdir -p "$d"
        echo "# ${MARKER}" > "$d/.dirtybox"
        ok "Created $d"
        record "DIR:$d"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 6 — cloud-init: Add AWS datasource reference
# The cleanup script looks for Ec2|AmazonEC2|aws in /etc/cloud/cloud.cfg
# ─────────────────────────────────────────────────────────────────────────────
step "Adding AWS datasource reference to cloud-init config..."

CLOUD_CFG="/etc/cloud/cloud.cfg"

if [[ -f "$CLOUD_CFG" ]]; then
    if grep -qF "$MARKER" "$CLOUD_CFG" 2>/dev/null; then
        skip "AWS datasource marker already present in $CLOUD_CFG"
    else
        # Backup before modification
        cp "$CLOUD_CFG" "${CLOUD_CFG}.dirtybox.bak"
        cat >> "$CLOUD_CFG" <<EOF

# --- ${MARKER} begin (setup-dirty-box-linux.sh) ---
datasource_list: [ Ec2, Azure ]
# --- ${MARKER} end ---
EOF
        ok "Added datasource_list to $CLOUD_CFG"
        record "CLOUD_CFG_MODIFIED:$CLOUD_CFG"
    fi
else
    skip "cloud-init not installed — skipping cloud.cfg modification"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 7 — cloud-init instance cache directories
# Remove Path: cloud-init instance cache targets these
# ─────────────────────────────────────────────────────────────────────────────
step "Creating cloud-init instance cache..."

FAKE_INSTANCE_DIR="/var/lib/cloud/instances/i-0123456789abcdef0"
if [[ -d "$FAKE_INSTANCE_DIR" ]]; then
    skip "$FAKE_INSTANCE_DIR already exists"
else
    mkdir -p "$FAKE_INSTANCE_DIR"
    echo "# ${MARKER}" > "${FAKE_INSTANCE_DIR}/.dirtybox"
    ok "Created $FAKE_INSTANCE_DIR"
    record "DIR:$FAKE_INSTANCE_DIR"
fi

CLOUD_DATA="/var/lib/cloud/data"
if [[ -d "$CLOUD_DATA" ]]; then
    skip "$CLOUD_DATA already exists"
else
    mkdir -p "$CLOUD_DATA"
    echo "# ${MARKER}" > "${CLOUD_DATA}/.dirtybox"
    ok "Created $CLOUD_DATA"
    record "DIR:$CLOUD_DATA"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 8 — Cutover-phase artifacts (Section 9 of cleanup script)
# Always planted regardless of phase so Cutover integration tests work.
# ─────────────────────────────────────────────────────────────────────────────
step "Creating cutover-phase AWS paths..."

CUTOVER_DIRS=(
    /var/log/amazon/ssm
    /var/log/ssm
    /etc/cfn/hooks.d
    /opt/aws/bin
    /opt/aws/python
    /etc/ec2-instance-connect
)

for d in "${CUTOVER_DIRS[@]}"; do
    if [[ -d "$d" ]]; then
        skip "$d already exists"
    else
        mkdir -p "$d"
        echo "# ${MARKER}" > "$d/.dirtybox"
        ok "Created $d"
        record "DIR:$d"
    fi
done

# /run/cloud-init/results.json (removed by cutover Section 9)
RUN_CI="/run/cloud-init"
if [[ -f "$RUN_CI/results.json" ]]; then
    skip "$RUN_CI/results.json already exists"
else
    mkdir -p "$RUN_CI"
    echo '{"v1":{"errors":[],"datasource":"DataSourceEc2Local","init":{"errors":[]}}}' \
        > "$RUN_CI/results.json"
    ok "Created $RUN_CI/results.json"
    record "FILE:$RUN_CI/results.json"
fi

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
COUNT=$(wc -l < "$MANIFEST")
echo ""
echo "[SETUP] ════════════════════════════════════════"
echo "[SETUP] DirtyBox Linux setup complete."
echo "[SETUP] Phase    : $PHASE"
echo "[SETUP] Manifest : $MANIFEST"
echo "[SETUP] Artifacts: $COUNT group(s) recorded"
echo "[SETUP] ════════════════════════════════════════"
