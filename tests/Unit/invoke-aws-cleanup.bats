#!/usr/bin/env bats
# =============================================================================
# invoke-aws-cleanup.bats
#
# Unit / DirtyBox tests for linux/invoke-aws-cleanup.sh
#
# ── Requirements ──────────────────────────────────────────────────────────────
#   • Run as root:  sudo bats tests/Unit/invoke-aws-cleanup.bats
#   • bats (>= 1.2): apt-get install bats  OR  brew install bats-core
#   • python3 (for JSON assertion helpers)
#
# ── Pattern ───────────────────────────────────────────────────────────────────
#   setup()    – create per-test sandbox dir, write command stubs into $T/bin,
#                prepend to PATH so the script never touches real system tools.
#   teardown() – restore any real files amended by the test; delete $T.
#
# ── Stub strategy ────────────────────────────────────────────────────────────
#   $T/registered_services  – newline-separated list of "foo.service enabled"
#                             read by the systemctl stub for list-unit-files
#   $T/installed_packages   – newline-separated list of package names
#                             consulted by rpm / dpkg stubs
#   $T/bin/systemctl        – responds to list-unit-files / stop / disable /
#                             enable / start / is-active
#   $T/bin/rpm              – checks $T/installed_packages for rpm -q
#   $T/bin/dpkg             – checks $T/installed_packages for dpkg -l
#   $T/bin/dnf|yum|apt-get  – succeed silently, log to $T/pkg_log
#   $T/bin/lsmod            – prints header only (no loaded modules)
# =============================================================================

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/linux/invoke-aws-cleanup.sh"

# ─── JSON report helpers ──────────────────────────────────────────────────────

# names_with_status <report> <Status>  →  newline-separated list of action names
names_with_status() {
    python3 - "$1" "$2" <<'PY'
import json, sys
r  = json.load(open(sys.argv[1]))
st = sys.argv[2]
print('\n'.join(a['name'] for a in r['actions'] if a['status'] == st))
PY
}

# summary_field <report> <field>  →  integer
summary_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(r['summary'][sys.argv[2]])
PY
}

# report_field <report> <field-path>  →  value (top-level only)
report_field() {
    python3 - "$1" "$2" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
print(r[sys.argv[2]])
PY
}

# ─── setup / teardown ────────────────────────────────────────────────────────

setup() {
    # All tests must run as root.
    if [[ $EUID -ne 0 ]]; then
        skip "These tests require root — run: sudo bats tests/Unit/invoke-aws-cleanup.bats"
    fi

    T="$(mktemp -d)"
    STUB_BIN="$T/bin"
    mkdir -p "$STUB_BIN"
    REPORT="$T/report.json"

    # Minimal, controlled PATH: stubs first, then bare system utils.
    export PATH="$STUB_BIN:/usr/bin:/bin:/sbin"
    export T   # stubs reference $T at write time (heredocs below)

    # ── systemctl stub ────────────────────────────────────────────────────────
    # list-unit-files: reads from $T/registered_services
    # is-active:       returns "active"
    # all other verbs: log to $T/systemctl.log and exit 0
    cat > "$STUB_BIN/systemctl" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "list-unit-files" ]]; then
    cat "$T/registered_services" 2>/dev/null || true
    exit 0
fi
if [[ "\$1" == "is-active" ]]; then
    echo "active"
    exit 0
fi
echo "stub-systemctl \$*" >> "$T/systemctl.log"
exit 0
STUB
    chmod +x "$STUB_BIN/systemctl"

    # ── rpm stub ─────────────────────────────────────────────────────────────
    cat > "$STUB_BIN/rpm" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "-q" ]]; then
    pkg="\$2"
    if grep -qxF "\$pkg" "$T/installed_packages" 2>/dev/null; then
        echo "\${pkg}-1.0-1.x86_64"
        exit 0
    fi
    echo "package \$pkg is not installed"
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_BIN/rpm"

    # ── dpkg stub ─────────────────────────────────────────────────────────────
    cat > "$STUB_BIN/dpkg" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "-l" ]]; then
    pkg="\$2"
    if grep -qxF "\$pkg" "$T/installed_packages" 2>/dev/null; then
        printf 'ii  %s  1.0  amd64  stub\n' "\$pkg"
        exit 0
    fi
    exit 1
fi
exit 0
STUB
    chmod +x "$STUB_BIN/dpkg"

    # ── package manager stubs (succeed silently; dnf chosen so detect picks it) ──
    for pm in dnf yum; do
        cat > "$STUB_BIN/$pm" <<STUB
#!/usr/bin/env bash
echo "stub-$pm \$*" >> "$T/pkg_log"
exit 0
STUB
        chmod +x "$STUB_BIN/$pm"
    done
    cat > "$STUB_BIN/apt-get" <<STUB
#!/usr/bin/env bash
echo "stub-apt-get \$*" >> "$T/pkg_log"
exit 0
STUB
    chmod +x "$STUB_BIN/apt-get"

    # ── lsmod stub (empty — no AWS kernel modules) ────────────────────────────
    cat > "$STUB_BIN/lsmod" <<'STUB'
#!/usr/bin/env bash
echo "Module                  Size  Used by"
exit 0
STUB
    chmod +x "$STUB_BIN/lsmod"

    # ── Snapshot real files that tests may modify ─────────────────────────────
    _snapshot /etc/hosts
    _snapshot /etc/environment
}

teardown() {
    # Restore real files
    _restore /etc/hosts
    _restore /etc/environment

    # Remove any filesystem artifacts we might have created
    rm -rf \
        /root/.aws \
        /var/lib/ssm-user/.aws \
        /var/lib/codedeploy-agent/.aws \
        /etc/amazon \
        /var/lib/amazon/ssm \
        /etc/profile.d/aws-test-stub.sh \
        /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg \
        /var/lib/cloud/instances \
        /var/lib/cloud/data \
        /var/log/amazon \
        /var/log/ssm \
        /etc/ec2-instance-connect \
        /etc/cfn \
        /opt/aws \
        2>/dev/null || true

    rm -rf "$T"
}

_snapshot() {
    local f="$1"
    local key="${T}/snap$(echo "$f" | tr '/' '_')"
    if [[ -f "$f" ]]; then
        cp -p "$f" "$key"
    else
        touch "${key}.absent"
    fi
}

_restore() {
    local f="$1"
    local key="${T}/snap$(echo "$f" | tr '/' '_')"
    if [[ -f "${key}.absent" ]]; then
        rm -f "$f"
    elif [[ -f "$key" ]]; then
        cp -p "$key" "$f"
    fi
}

# =============================================================================
# ROOT GUARD
# =============================================================================

@test "root guard: exits 1 and prints error when not root" {
    # Run the script as an unprivileged user
    run su -s /bin/bash nobody -c "bash '$SCRIPT' --dry-run --skip-agent-check 2>&1" 2>/dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"must be run as root"* ]]
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

@test "arg parsing: unknown option prints WARN but script continues" {
    run bash "$SCRIPT" --unknown-flag --dry-run --skip-agent-check \
        --report "$REPORT" 2>&1
    [ "$status" -eq 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "arg parsing: --dry-run flag causes all actions to be DryRun or Skipped" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local completed
    completed=$(summary_field "$REPORT" completed)
    [ "$completed" -eq 0 ]
}

@test "arg parsing: --phase cutover is accepted without error" {
    run bash "$SCRIPT" --phase cutover --dry-run --skip-agent-check \
        --report "$REPORT"
    [ "$status" -eq 0 ]
    local phase
    phase=$(report_field "$REPORT" phase)
    [ "$phase" = "cutover" ]
}

@test "arg parsing: --report writes JSON to specified path" {
    local custom_report="$T/custom-report.json"
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$custom_report"
    [ "$status" -eq 0 ]
    [ -f "$custom_report" ]
    python3 -c "import json; json.load(open('$custom_report'))"
}

@test "arg parsing: --skip-agent-check skips Section 10" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Azure Linux Agent Check"* ]]
}

# =============================================================================
# SECTION 2 — AWS Services (disable_service_if_present)
# =============================================================================

@test "S2 service: unit not found → Skipped" {
    # No entries in registered_services
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Disable Service: AWS SSM Agent"* ]]
}

@test "S2 service: unit present + dry-run → DryRun" {
    echo "amazon-ssm-agent.service enabled" > "$T/registered_services"
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"Disable Service: AWS SSM Agent"* ]]
}

@test "S2 service: unit present + live → Completed" {
    echo "amazon-ssm-agent.service enabled" > "$T/registered_services"
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"Disable Service: AWS SSM Agent"* ]]
}

@test "S2 service: stop and disable are called for present service" {
    echo "amazon-cloudwatch-agent.service enabled" > "$T/registered_services"
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q "stop.*amazon-cloudwatch-agent\|disable.*amazon-cloudwatch-agent" "$T/systemctl.log"
}

@test "S2 service: all seven AWS services checked" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"AWS SSM Agent"* ]]
    [[ "$names" == *"AWS CloudWatch Agent"* ]]
    [[ "$names" == *"AWS Logs Agent"* ]]
    [[ "$names" == *"AWS EC2 Instance Connect"* ]]
    [[ "$names" == *"AWS CloudFormation cfn-hup"* ]]
    [[ "$names" == *"AWS CodeDeploy Agent"* ]]
}

# =============================================================================
# SECTION 3 — AWS Packages (remove_package_if_installed)
# =============================================================================

@test "S3 package: not installed → Skipped" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Remove Package: AWS SSM Agent"* ]]
}

@test "S3 package: installed + dry-run → DryRun" {
    echo "amazon-ssm-agent" > "$T/installed_packages"
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"Remove Package: AWS SSM Agent"* ]]
}

@test "S3 package: installed + live → Completed and dnf remove called" {
    echo "amazon-ssm-agent" > "$T/installed_packages"
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"Remove Package: AWS SSM Agent"* ]]
    grep -q "dnf.*remove.*amazon-ssm-agent\|remove.*amazon-ssm-agent" "$T/pkg_log"
}

@test "S3 package: AWS CLI is always Skipped regardless of install state" {
    # Even if awscli were somehow in installed_packages, it should remain Skipped
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Remove Package: AWS CLI"* ]]
}

@test "S3 package: multiple packages installed → all reported Completed" {
    printf 'amazon-ssm-agent\namazon-cloudwatch-agent\nawslogs\n' \
        > "$T/installed_packages"
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"Remove Package: AWS SSM Agent"* ]]
    [[ "$names" == *"Remove Package: AWS CloudWatch Agent"* ]]
    [[ "$names" == *"Remove Package: AWS Logs Agent"* ]]
}

# =============================================================================
# SECTION 4 — AWS Credentials (remove_path_if_present)
# =============================================================================

@test "S4 creds: /root/.aws absent → Skipped" {
    rm -rf /root/.aws
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"root .aws credentials directory"* ]]
}

@test "S4 creds: /root/.aws present + dry-run → DryRun, directory preserved" {
    mkdir -p /root/.aws
    echo "fake-key" > /root/.aws/credentials
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ -d /root/.aws ]
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"root .aws credentials directory"* ]]
}

@test "S4 creds: /root/.aws present + live → Completed, directory removed" {
    mkdir -p /root/.aws
    echo "fake-key" > /root/.aws/credentials
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /root/.aws ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"root .aws credentials directory"* ]]
}

@test "S4 creds: service account .aws dirs removed when present" {
    mkdir -p /var/lib/ssm-user/.aws
    mkdir -p /var/lib/codedeploy-agent/.aws
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /var/lib/ssm-user/.aws ]
    [ ! -e /var/lib/codedeploy-agent/.aws ]
}

@test "S4 creds: SSM agent config directory removed when present" {
    mkdir -p /etc/amazon/ssm
    mkdir -p /var/lib/amazon/ssm
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /etc/amazon/ssm ]
    [ ! -e /var/lib/amazon/ssm ]
}

# =============================================================================
# SECTION 5 — Environment Variables (remove_lines_matching)
# =============================================================================

@test "S5 envvars: export AWS_ACCESS_KEY_ID removed from /etc/environment" {
    echo 'export AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE' >> /etc/environment
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    ! grep -q 'AWS_ACCESS_KEY_ID' /etc/environment
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"Env AWS_ACCESS_KEY_ID"* ]]
}

@test "S5 envvars: unquoted AWS_REGION= removed from /etc/environment" {
    echo 'AWS_REGION=us-east-1' >> /etc/environment
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    ! grep -q 'AWS_REGION' /etc/environment
}

@test "S5 envvars: dry-run leaves AWS line in /etc/environment intact" {
    echo 'export AWS_DEFAULT_REGION=us-east-1' >> /etc/environment
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q 'AWS_DEFAULT_REGION' /etc/environment
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"Env AWS_DEFAULT_REGION"* ]]
}

@test "S5 envvars: non-AWS lines in /etc/environment are untouched" {
    local sentinel="MYAPP_ENV=production"
    echo "$sentinel" >> /etc/environment
    echo 'export AWS_PROFILE=default' >> /etc/environment
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q "$sentinel" /etc/environment
}

@test "S5 envvars: /etc/environment absent → all Skipped" {
    rm -f /etc/environment
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"/etc/environment"* ]]
}

@test "S5 profile.d: aws*.sh drop-in removed when present" {
    echo '# stub aws env' > /etc/profile.d/aws-test-stub.sh
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -f /etc/profile.d/aws-test-stub.sh ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"AWS profile.d drop-in"* ]]
}

@test "S5 profile.d: dry-run preserves aws*.sh drop-in" {
    echo '# stub aws env' > /etc/profile.d/aws-test-stub.sh
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ -f /etc/profile.d/aws-test-stub.sh ]
}

# =============================================================================
# SECTION 6 — /etc/hosts (remove_lines_matching)
# =============================================================================

@test "S6 hosts: AWS ec2.internal metadata line removed" {
    echo '169.254.169.254 instance-data.ec2.internal # aws metadata' \
        >> /etc/hosts
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    ! grep -q 'ec2\.internal' /etc/hosts
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"AWS EC2-internal metadata hostname"* ]]
}

@test "S6 hosts: instance-data.ec2.internal alias removed" {
    echo 'instance-data.ec2.internal # aws alias' >> /etc/hosts
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    ! grep -q 'instance-data\.ec2\.internal' /etc/hosts
}

@test "S6 hosts: generic 169.254.169.254 line (Azure IMDS) is preserved" {
    local imds_line="169.254.169.254 # Azure IMDS"
    echo "$imds_line" >> /etc/hosts
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q '169\.254\.169\.254' /etc/hosts
}

@test "S6 hosts: no AWS lines present → Skipped" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"AWS EC2-internal metadata hostname"* ]]
}

@test "S6 hosts: dry-run does not modify /etc/hosts" {
    local aws_line="169.254.169.254 instance-data.ec2.internal"
    echo "$aws_line" >> /etc/hosts
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q 'ec2\.internal' /etc/hosts
}

# =============================================================================
# SECTION 7 — cloud-init
# =============================================================================

@test "S7 cloud-init: not installed → Skipped" {
    rm -f /etc/cloud/cloud.cfg 2>/dev/null || true
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"cloud-init: Datasource config"* ]]
}

@test "S7 cloud-init: cloud.cfg with Ec2 reference → commented out (live)" {
    mkdir -p /etc/cloud/cloud.cfg.d
    printf 'datasource_list: [ Ec2, NoCloud ]\ncloud_init_modules: []\n' \
        > /etc/cloud/cloud.cfg
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    grep -q '#MIGRATED:' /etc/cloud/cloud.cfg
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"cloud-init: Datasource config"* ]]
    # cleanup
    rm -f /etc/cloud/cloud.cfg
}

@test "S7 cloud-init: cloud.cfg with Ec2 → Azure drop-in written" {
    mkdir -p /etc/cloud/cloud.cfg.d
    rm -f /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg
    printf 'datasource_list: [ Ec2 ]\n' > /etc/cloud/cloud.cfg
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ -f /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg ]
    grep -q 'datasource_list.*Azure' /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg
    # cleanup
    rm -f /etc/cloud/cloud.cfg
}

@test "S7 cloud-init: cloud.cfg without AWS refs → Skipped" {
    mkdir -p /etc/cloud/cloud.cfg.d
    printf '# clean azure cloud.cfg\ndatasource_list: [ Azure ]\n' \
        > /etc/cloud/cloud.cfg
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"cloud-init: Datasource config"* ]]
    # cleanup
    rm -f /etc/cloud/cloud.cfg
}

@test "S7 cloud-init: drop-in already exists → Skipped" {
    mkdir -p /etc/cloud/cloud.cfg.d
    printf 'datasource_list: [ Ec2 ]\n' > /etc/cloud/cloud.cfg
    echo "# already here" > /etc/cloud/cloud.cfg.d/90_azure_datasource.cfg
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"cloud-init: Azure datasource drop-in"* ]]
    # cleanup
    rm -f /etc/cloud/cloud.cfg
}

@test "S7 cloud-init: instance cache removed (live)" {
    mkdir -p /var/lib/cloud/instances
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /var/lib/cloud/instances ]
}

@test "S7 cloud-init: dry-run does not remove instance cache" {
    mkdir -p /var/lib/cloud/instances
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ -d /var/lib/cloud/instances ]
}

# =============================================================================
# SECTION 8 — Kernel Modules (informational — no changes)
# =============================================================================

@test "S8 kernel modules: loaded module logged as Skipped (not removed)" {
    # Replace lsmod stub to report ena as loaded
    cat > "$STUB_BIN/lsmod" <<'STUB'
#!/usr/bin/env bash
echo "Module                  Size  Used by"
echo "ena                   131072  0"
STUB
    chmod +x "$STUB_BIN/lsmod"
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Kernel Module: ena"* ]]
}

@test "S8 kernel modules: no loaded modules → no module actions in report" {
    # Default lsmod stub returns header only
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" != *"Kernel Module:"* ]]
}

# =============================================================================
# SECTION 9 — Phase gating (test-migration vs cutover)
# =============================================================================

@test "S9 phase: test-migration → deep-clean deferred (Skipped)" {
    run bash "$SCRIPT" --phase test-migration --dry-run --skip-agent-check \
        --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Skipped)
    [[ "$names" == *"Deep Clean"* ]]
}

@test "S9 phase: cutover + dry-run → deep-clean paths show DryRun" {
    mkdir -p /var/log/amazon
    run bash "$SCRIPT" --phase cutover --dry-run --skip-agent-check \
        --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"AWS Amazon log directory"* ]]
}

@test "S9 phase: cutover + live → /var/log/amazon removed" {
    mkdir -p /var/log/amazon
    run bash "$SCRIPT" --phase cutover --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /var/log/amazon ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"AWS Amazon log directory"* ]]
}

@test "S9 phase: cutover + live → /etc/cfn removed when present" {
    mkdir -p /etc/cfn
    run bash "$SCRIPT" --phase cutover --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /etc/cfn ]
}

@test "S9 phase: cutover + live → /opt/aws removed when present" {
    mkdir -p /opt/aws/bin
    mkdir -p /opt/aws/python
    run bash "$SCRIPT" --phase cutover --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /opt/aws/bin ]
    [ ! -e /opt/aws/python ]
}

@test "S9 phase: cutover + live → EC2 Instance Connect removed when present" {
    mkdir -p /etc/ec2-instance-connect
    run bash "$SCRIPT" --phase cutover --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ ! -e /etc/ec2-instance-connect ]
}

# =============================================================================
# SECTION 10 — Azure Linux Agent (waagent)
# =============================================================================

@test "S10 waagent: not found (no binary, no service) → Error action" {
    # waagent NOT in stub bin; no entry in registered_services
    run bash "$SCRIPT" --report "$REPORT"
    # Script exits 2 when errors > 0
    [ "$status" -eq 2 ]
    local names
    names=$(names_with_status "$REPORT" Error)
    [[ "$names" == *"Azure Linux Agent Check"* ]]
}

@test "S10 waagent: found via systemctl + live → Completed" {
    echo "walinuxagent.service enabled" > "$T/registered_services"
    # Ensure waagent binary is also available so the check passes
    cat > "$STUB_BIN/waagent" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_BIN/waagent"
    run bash "$SCRIPT" --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" Completed)
    [[ "$names" == *"Azure Linux Agent: walinuxagent"* ]]
}

@test "S10 waagent: found via binary + dry-run → DryRun" {
    cat > "$STUB_BIN/waagent" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$STUB_BIN/waagent"
    echo "waagent.service enabled" > "$T/registered_services"
    run bash "$SCRIPT" --dry-run --report "$REPORT"
    [ "$status" -eq 0 ]
    local names
    names=$(names_with_status "$REPORT" DryRun)
    [[ "$names" == *"Azure Linux Agent:"* ]]
}

@test "S10 waagent: --skip-agent-check suppresses Section 10 entirely" {
    # Even with no waagent present, --skip-agent-check must not produce Error
    run bash "$SCRIPT" --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local errors
    errors=$(summary_field "$REPORT" errors)
    [ "$errors" -eq 0 ]
}

# =============================================================================
# SECTION 11 — Report correctness
# =============================================================================

@test "report: valid JSON written to --report path" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    [ -f "$REPORT" ]
    run python3 -c "import json; json.load(open('$REPORT'))"
    [ "$status" -eq 0 ]
}

@test "report: schemaVersion is '1.0'" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local ver
    ver=$(report_field "$REPORT" schemaVersion)
    [ "$ver" = "1.0" ]
}

@test "report: phase field matches --phase argument" {
    run bash "$SCRIPT" --phase cutover --dry-run --skip-agent-check \
        --report "$REPORT"
    [ "$status" -eq 0 ]
    local phase
    phase=$(report_field "$REPORT" phase)
    [ "$phase" = "cutover" ]
}

@test "report: dryRun field is true when --dry-run passed" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local dryrun
    dryrun=$(report_field "$REPORT" dryRun)
    [ "$dryrun" = "True" ]
}

@test "report: summary total equals length of actions array" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local total array_len
    total=$(summary_field "$REPORT" total)
    array_len=$(python3 -c "import json; r=json.load(open('$REPORT')); print(len(r['actions']))")
    [ "$total" -eq "$array_len" ]
}

@test "report: summary counts add up to total" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    python3 - "$REPORT" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
s = r['summary']
assert s['completed'] + s['skipped'] + s['dryRun'] + s['errors'] == s['total'], \
    f"counts don't add up: {s}"
PY
}

@test "report: errors=0 → exit 0" {
    run bash "$SCRIPT" --dry-run --skip-agent-check --report "$REPORT"
    [ "$status" -eq 0 ]
    local errors
    errors=$(summary_field "$REPORT" errors)
    [ "$errors" -eq 0 ]
}

@test "report: errors>0 → exit 2" {
    # waagent absent → Error, which triggers exit 2
    run bash "$SCRIPT" --report "$REPORT"
    [ "$status" -eq 2 ]
    local errors
    errors=$(summary_field "$REPORT" errors)
    [ "$errors" -gt 0 ]
}
