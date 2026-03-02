#!/usr/bin/env bash
# =============================================================================
# invoke-dirty-box-integration-linux.sh
#
# Layer 2 integration test — DirtyBox end-to-end pipeline for Linux.
#
# Runs the full cleanup pipeline against real artifacts planted on this machine:
#
#   setup-dirty-box  →  Pre-assertions  →  Cleanup (DryRun)  →  Cleanup (Live)
#                    →  Post-assertions  →  teardown-dirty-box
#
# NO MOCKS.  Every state check reads real Linux state (systemd, /etc/environment,
# /etc/hosts, filesystem paths).
#
# Usage:
#   sudo ./tests/Integration/invoke-dirty-box-integration-linux.sh [OPTIONS]
#
# Options:
#   --phase <value>    test-migration (default) | cutover
#   --skip-setup       Skip setup-dirty-box (artifacts already planted)
#   --skip-teardown    Leave artifacts in place after the test
#   --report-dir <dir> Where to write JSON reports (default: same dir as script)
# =============================================================================

set -uo pipefail
IFS=$'\n\t'

# ─────────────────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────────────────
PHASE="test-migration"
SKIP_SETUP=false
SKIP_TEARDOWN=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_DIR="$SCRIPT_DIR/reports"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --phase)         PHASE="${2:-test-migration}"; shift ;;
        --skip-setup)    SKIP_SETUP=true ;;
        --skip-teardown) SKIP_TEARDOWN=true ;;
        --report-dir)    REPORT_DIR="${2}"; shift ;;
        *) echo "[WARN] Unknown option: $1" ;;
    esac
    shift
done

# ─────────────────────────────────────────────────────────────────────────────
# Guards
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Must be run as root." >&2
    exit 1
fi

mkdir -p "$REPORT_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Paths
# ─────────────────────────────────────────────────────────────────────────────
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$SCRIPT_DIR/../Fixture/setup-dirty-box-linux.sh"
TEARDOWN_SCRIPT="$SCRIPT_DIR/../Fixture/teardown-dirty-box-linux.sh"
CLEANUP_SCRIPT="$ROOT_DIR/linux/invoke-aws-cleanup.sh"

# ─────────────────────────────────────────────────────────────────────────────
# Test tracking
# ─────────────────────────────────────────────────────────────────────────────
PASSED=0
FAILED=0
ASSERTIONS_JSON=""   # comma-separated JSON objects

TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
START_TIME=$(date +%s)

escape_json() {
    # Minimal JSON string escaping: backslash → \\, double-quote → \"
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

append_assertion() {
    local result="$1"
    local label="$2"
    local escaped
    escaped=$(escape_json "$label")
    local entry="{\"result\":\"$result\",\"assertion\":\"$escaped\"}"
    if [[ -n "$ASSERTIONS_JSON" ]]; then
        ASSERTIONS_JSON="${ASSERTIONS_JSON},$entry"
    else
        ASSERTIONS_JSON="$entry"
    fi
}

pass() {
    local label="$1"
    echo "  [PASS] $label"
    ((++PASSED))
    append_assertion "PASS" "$label"
}

fail() {
    local label="$1"
    echo "  [FAIL] $label"
    ((++FAILED))
    append_assertion "FAIL" "$label"
}

info() { echo "  [INFO] $1"; }

banner() {
    local text="$1"
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  $text"
    echo "══════════════════════════════════════════════════════════"
}

# ─────────────────────────────────────────────────────────────────────────────
# Assertion helpers
# ─────────────────────────────────────────────────────────────────────────────
assert_service_unit_exists() {
    local svc="$1" label="$2"
    # Check systemctl unit database AND on-disk file — daemon-reload may lag in
    # run-command contexts, but the file on disk is always authoritative.
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service" \
       || [[ -f "/etc/systemd/system/${svc}.service" ]] \
       || [[ -f "/usr/lib/systemd/system/${svc}.service" ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_service_unit_absent() {
    local svc="$1" label="$2"
    if systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service"; then
        fail "$label"
    else
        pass "$label"
    fi
}

assert_service_disabled() {
    local svc="$1" label="$2"
    # If the unit file is gone from disk and the unit db, it's been fully removed — acceptable.
    if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${svc}\.service" \
       && [[ ! -f "/etc/systemd/system/${svc}.service" ]] \
       && [[ ! -f "/usr/lib/systemd/system/${svc}.service" ]]; then
        pass "$label (unit removed)"
        return
    fi
    # Unit still exists — check its enable state.  Use  || true  to avoid the
    # 'set -e exits on disabled' trap; capture only the first line.
    local state
    state=$(systemctl is-enabled "$svc" 2>/dev/null) || true
    state=$(printf '%s' "$state" | head -1)
    case "$state" in
        disabled|static|masked)
            pass "$label (state: $state)" ;;
        *)
            fail "$label (state: ${state:-unknown})" ;;
    esac
}

assert_env_var_in_file() {
    local var="$1" file="$2" label="$3"
    if grep -qE "(^|export )[[:space:]]*${var}=" "$file" 2>/dev/null; then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_env_var_absent_in_file() {
    local var="$1" file="$2" label="$3"
    if grep -qE "(^|export )[[:space:]]*${var}=" "$file" 2>/dev/null; then
        fail "$label (still present in $file)"
    else
        pass "$label"
    fi
}

assert_hosts_pattern_present() {
    local pattern="$1" label="$2"
    if grep -qE "$pattern" /etc/hosts 2>/dev/null; then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_hosts_pattern_absent() {
    local pattern="$1" label="$2"
    if grep -qE "$pattern" /etc/hosts 2>/dev/null; then
        fail "$label (pattern still found in /etc/hosts)"
    else
        pass "$label"
    fi
}

assert_path_exists() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}

assert_path_absent() {
    local path="$1" label="$2"
    if [[ -e "$path" ]]; then
        fail "$label (path still exists)"
    else
        pass "$label"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight: verify script dependencies exist
# ─────────────────────────────────────────────────────────────────────────────
banner "Pre-flight: verifying scripts exist"
for script_path in "$SETUP_SCRIPT" "$TEARDOWN_SCRIPT" "$CLEANUP_SCRIPT"; do
    if [[ -f "$script_path" ]]; then
        info "Found: $script_path"
    else
        echo "[ERROR] Missing required script: $script_path" >&2
        exit 1
    fi
done

chmod +x "$SETUP_SCRIPT" "$TEARDOWN_SCRIPT" "$CLEANUP_SCRIPT"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 0 — SETUP
# ═══════════════════════════════════════════════════════════════════════════
if ! $SKIP_SETUP; then
    banner "Phase 0: setup-dirty-box-linux"
    bash "$SETUP_SCRIPT" --phase "$PHASE"
    SETUP_EXIT=$?
    if [[ $SETUP_EXIT -ne 0 ]]; then
        echo "[ERROR] setup-dirty-box-linux failed (exit $SETUP_EXIT)" >&2
        exit 1
    fi
    # Force systemd to register the new unit files written by setup.
    # daemon-reload may not propagate automatically in run-command contexts.
    systemctl daemon-reload 2>/dev/null || true
else
    info "Skipping setup (--skip-setup specified)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1 — PRE-CLEANUP ASSERTIONS (DirtyBox state verification)
# ═══════════════════════════════════════════════════════════════════════════
banner "Phase 1: Verify DirtyBox artifacts are present"

echo "  Services:"
assert_service_unit_exists "amazon-ssm-agent"        "amazon-ssm-agent unit file exists"
assert_service_unit_exists "amazon-cloudwatch-agent"  "amazon-cloudwatch-agent unit file exists"
assert_service_unit_exists "codedeploy-agent"         "codedeploy-agent unit file exists"
assert_service_unit_exists "awslogs"                  "awslogs unit file exists"

echo "  Environment variables:"
assert_env_var_in_file "AWS_DEFAULT_REGION" "/etc/environment" "AWS_DEFAULT_REGION in /etc/environment"
assert_env_var_in_file "AWS_REGION"         "/etc/environment" "AWS_REGION in /etc/environment"
assert_env_var_in_file "AWS_PROFILE"        "/etc/environment" "AWS_PROFILE in /etc/environment"

echo "  profile.d drop-in:"
assert_path_exists "/etc/profile.d/aws_migration_test.sh" "/etc/profile.d/aws_migration_test.sh exists"

echo "  Hosts file:"
assert_hosts_pattern_present "instance-data\.ec2\.internal" "Hosts file contains EC2 internal entry"

echo "  Credentials directories:"
assert_path_exists "/root/.aws"                     "/root/.aws exists"
assert_path_exists "/var/lib/ssm-user/.aws"         "/var/lib/ssm-user/.aws exists"
assert_path_exists "/var/lib/codedeploy-agent/.aws" "/var/lib/codedeploy-agent/.aws exists"

echo "  Agent config directories:"
assert_path_exists "/etc/amazon/ssm"   "/etc/amazon/ssm exists"
assert_path_exists "/var/lib/amazon/ssm" "/var/lib/amazon/ssm exists"

echo "  Cutover-phase paths:"
assert_path_exists "/var/log/amazon"   "/var/log/amazon exists"
assert_path_exists "/var/log/ssm"      "/var/log/ssm exists"
assert_path_exists "/etc/cfn"          "/etc/cfn exists"
assert_path_exists "/opt/aws/bin"      "/opt/aws/bin exists"

PRE_PASSED=$PASSED
PRE_FAILED=$FAILED
info "Pre-state: $PRE_PASSED checks passed, $PRE_FAILED failed"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2 — DRY-RUN CLEANUP
# ═══════════════════════════════════════════════════════════════════════════
banner "Phase 2: invoke-aws-cleanup.sh --dry-run --phase $PHASE"

DRY_REPORT="$REPORT_DIR/cleanup-dryrun-${TIMESTAMP}.json"
bash "$CLEANUP_SCRIPT" --dry-run --phase "$PHASE" \
    --report "$DRY_REPORT" --skip-agent-check
DRY_EXIT=$?

info "DryRun exit code: $DRY_EXIT"
info "DryRun report: $DRY_REPORT"

# Parse summary from report (requires python3 which is guaranteed to be present)
if [[ -f "$DRY_REPORT" ]]; then
    DRY_TOTAL=$(python3 -c "import json,sys; d=json.load(open('$DRY_REPORT')); print(d['summary']['total'])" 2>/dev/null || echo "?")
    DRY_DRYRUN=$(python3 -c "import json,sys; d=json.load(open('$DRY_REPORT')); print(d['summary']['dryRun'])" 2>/dev/null || echo "?")
    DRY_COMPLETED=$(python3 -c "import json,sys; d=json.load(open('$DRY_REPORT')); print(d['summary']['completed'])" 2>/dev/null || echo "?")
    DRY_ERRORS=$(python3 -c "import json,sys; d=json.load(open('$DRY_REPORT')); print(d['summary']['errors'])" 2>/dev/null || echo "?")
    info "  Total=$DRY_TOTAL  DryRun=$DRY_DRYRUN  Completed=$DRY_COMPLETED  Errors=$DRY_ERRORS"

    if [[ "$DRY_DRYRUN" != "?" ]] && [[ "$DRY_DRYRUN" -gt 0 ]]; then
        pass "DryRun mode recorded $DRY_DRYRUN DryRun-status action(s)"
    else
        fail "DryRun mode produced no DryRun-status actions"
    fi

    if [[ "$DRY_COMPLETED" == "0" ]]; then
        pass "DryRun mode made no real changes (zero Completed actions)"
    else
        fail "DryRun mode made real changes ($DRY_COMPLETED Completed actions)"
    fi
else
    fail "DryRun report not written to $DRY_REPORT"
fi

# Verify state is unchanged after DryRun
echo "  State unchanged after DryRun:"
assert_service_unit_exists "amazon-ssm-agent"  "amazon-ssm-agent unit still exists after DryRun"
assert_env_var_in_file "AWS_DEFAULT_REGION" "/etc/environment" "AWS_DEFAULT_REGION still in /etc/environment after DryRun"
assert_hosts_pattern_present "instance-data\.ec2\.internal" "Hosts EC2 entry still present after DryRun"
assert_path_exists "/root/.aws" "/root/.aws still exists after DryRun"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3 — LIVE CLEANUP
# ═══════════════════════════════════════════════════════════════════════════
banner "Phase 3: invoke-aws-cleanup.sh --phase $PHASE (live)"

LIVE_REPORT="$REPORT_DIR/cleanup-live-${TIMESTAMP}.json"
bash "$CLEANUP_SCRIPT" --phase "$PHASE" \
    --report "$LIVE_REPORT" --skip-agent-check
LIVE_EXIT=$?

info "Live cleanup exit code: $LIVE_EXIT"
info "Live cleanup report: $LIVE_REPORT"

if [[ -f "$LIVE_REPORT" ]]; then
    LIVE_TOTAL=$(python3 -c "import json; d=json.load(open('$LIVE_REPORT')); print(d['summary']['total'])" 2>/dev/null || echo "?")
    LIVE_COMPLETED=$(python3 -c "import json; d=json.load(open('$LIVE_REPORT')); print(d['summary']['completed'])" 2>/dev/null || echo "?")
    LIVE_SKIPPED=$(python3 -c "import json; d=json.load(open('$LIVE_REPORT')); print(d['summary']['skipped'])" 2>/dev/null || echo "?")
    LIVE_ERRORS=$(python3 -c "import json; d=json.load(open('$LIVE_REPORT')); print(d['summary']['errors'])" 2>/dev/null || echo "?")
    info "  Total=$LIVE_TOTAL  Completed=$LIVE_COMPLETED  Skipped=$LIVE_SKIPPED  Errors=$LIVE_ERRORS"

    if [[ "$LIVE_COMPLETED" != "?" ]] && [[ "$LIVE_COMPLETED" -gt 0 ]]; then
        pass "Live cleanup completed $LIVE_COMPLETED action(s)"
    else
        fail "Live cleanup completed zero actions — nothing was cleaned up"
    fi

    if [[ "$LIVE_ERRORS" == "0" ]]; then
        pass "Live cleanup had no errors"
    else
        fail "Live cleanup had $LIVE_ERRORS error(s)"
        # Print error details
        python3 - <<PYEOF 2>/dev/null || true
import json
d = json.load(open('$LIVE_REPORT'))
for a in d.get('actions', []):
    if a.get('status') == 'Error':
        print(f"  ERROR: {a['name']} - {a['detail']}")
PYEOF
    fi
else
    fail "Live cleanup report not written to $LIVE_REPORT"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4 — POST-CLEANUP ASSERTIONS
# ═══════════════════════════════════════════════════════════════════════════
banner "Phase 4: Verify cleanup removed artifacts"

echo "  Services:"
assert_service_disabled "amazon-ssm-agent"       "amazon-ssm-agent service disabled or removed"
assert_service_disabled "amazon-cloudwatch-agent" "amazon-cloudwatch-agent service disabled or removed"
assert_service_disabled "codedeploy-agent"         "codedeploy-agent service disabled or removed"

echo "  Environment variables:"
assert_env_var_absent_in_file "AWS_DEFAULT_REGION" "/etc/environment" "AWS_DEFAULT_REGION removed from /etc/environment"
assert_env_var_absent_in_file "AWS_REGION"         "/etc/environment" "AWS_REGION removed from /etc/environment"
assert_env_var_absent_in_file "AWS_PROFILE"        "/etc/environment" "AWS_PROFILE removed from /etc/environment"

echo "  profile.d drop-in:"
assert_path_absent "/etc/profile.d/aws_migration_test.sh" "AWS profile.d drop-in removed"

echo "  Hosts file:"
assert_hosts_pattern_absent "instance-data\.ec2\.internal" "Hosts EC2 entry removed"

echo "  Credentials directories:"
assert_path_absent "/root/.aws"                     "/root/.aws removed"
assert_path_absent "/var/lib/ssm-user/.aws"         "/var/lib/ssm-user/.aws removed"
assert_path_absent "/var/lib/codedeploy-agent/.aws" "/var/lib/codedeploy-agent/.aws removed"

echo "  Agent config directories:"
assert_path_absent "/etc/amazon/ssm"    "/etc/amazon/ssm removed"
assert_path_absent "/var/lib/amazon/ssm" "/var/lib/amazon/ssm removed"

# Cutover-only: deep clean paths (Section 9 of cleanup)
if [[ "$PHASE" == "cutover" ]]; then
    echo "  Cutover-phase deep clean:"
    assert_path_absent "/var/log/amazon"   "/var/log/amazon removed (cutover)"
    assert_path_absent "/var/log/ssm"      "/var/log/ssm removed (cutover)"
    assert_path_absent "/etc/cfn"          "/etc/cfn removed (cutover)"
    assert_path_absent "/opt/aws/bin"      "/opt/aws/bin removed (cutover)"
    assert_path_absent "/etc/ec2-instance-connect" "/etc/ec2-instance-connect removed (cutover)"
else
    info "Cutover deep-clean paths not checked for test-migration phase"
    # For test-migration, Section 9 is skipped, so the paths should still exist
    assert_path_exists "/var/log/amazon" "/var/log/amazon preserved (test-migration — not yet cleaned)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5 — TEARDOWN
# ═══════════════════════════════════════════════════════════════════════════
if ! $SKIP_TEARDOWN; then
    banner "Phase 5: teardown-dirty-box-linux"
    bash "$TEARDOWN_SCRIPT" --force
else
    info "Skipping teardown (--skip-teardown specified)"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
TOTAL=$((PASSED + FAILED))

if [[ $FAILED -eq 0 ]]; then
    COLOR="\033[32m"  # green
else
    COLOR="\033[31m"  # red
fi
NC="\033[0m"

echo ""
printf "${COLOR}══════════════════════════════════════════════════════════${NC}\n"
printf "${COLOR}  Integration Test Results — Linux (Phase: %s)${NC}\n" "$PHASE"
printf "${COLOR}  Total    : %d${NC}\n" "$TOTAL"
printf "\033[32m  Passed   : %d${NC}\n" "$PASSED"
if [[ $FAILED -gt 0 ]]; then
    printf "\033[31m  Failed   : %d${NC}\n" "$FAILED"
else
    printf "${COLOR}  Failed   : 0${NC}\n"
fi
printf "${COLOR}  Duration : %ds${NC}\n" "$DURATION"
printf "${COLOR}══════════════════════════════════════════════════════════${NC}\n"

# Write JSON summary
SUMMARY_PATH="$REPORT_DIR/integration-summary-${TIMESTAMP}.json"
cat > "$SUMMARY_PATH" <<EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "phase": "$PHASE",
  "total": $TOTAL,
  "passed": $PASSED,
  "failed": $FAILED,
  "durationSec": $DURATION,
  "assertions": [${ASSERTIONS_JSON}]
}
EOF

echo ""
echo "  Summary report: $SUMMARY_PATH"

[[ $FAILED -gt 0 ]] && exit $FAILED
exit 0
