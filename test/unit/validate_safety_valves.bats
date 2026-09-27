#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/validate_safety_valves.bats — mass-blacklist safety valves
#
# M5: OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT and
# OCPROBE_VALIDATE_TIMEOUT_THRESHOLD_PCT exist because a real run produced
# 941/979 TIMEOUT (96%) at -P 8 while single probes answered in <2s. Without the
# valves that run would have retired the entire catalog. They had zero test
# coverage, so a valve that always tripped — or never tripped — would have gone
# unnoticed. These tests pin both directions plus the historical ratio.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_LOG_LEVEL="warn"
    export OCPROBE_LOG_FORMAT="text"

    mkdir -p "$OCPROBE_STATE_DIR"
    mkdir -p "$(dirname "$OCPROBE_CONFIG_OVERRIDE")"

    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocmm-probe"
catalog:
  cache_ttl_hours: 24
scheduler:
  enabled: false
  interval_seconds: 21600
alerts:
  webhook_url: ""
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
logging:
  level: warn
  format: text
  file_enabled: false
EOF

    cat >"$BATS_TEST_TMPDIR/opencode.json" <<'JSON'
{
  "provider": {
    "test-provider": {
      "blacklist": [],
      "whitelist": []
    }
  }
}
JSON

    cat >"$BATS_TEST_TMPDIR/auth.json" <<'JSON'
{
  "test-provider": {
    "type": "api",
    "key": "test-key"
  }
}
JSON
    export OCPROBE_OPencode_AUTH="$BATS_TEST_TMPDIR/auth.json"

    load_config
    setup_valve_mock_opencode
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# ---- mocks -----------------------------------------------------------------

setup_valve_mock_opencode() {
    local mock_dir="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    cat >"$mock_dir/opencode" <<'MOCK_EOF'
#!/usr/bin/env bash
case "$1" in
    models) cat "$MOCK_MODELS_FILE" ;;
    run)    echo "OK"; exit 0 ;;
    session) exit 0 ;;
esac
exit 0
MOCK_EOF
    chmod +x "$mock_dir/opencode"
    export PATH="$mock_dir:$PATH"
}

# ---- fixture builders ------------------------------------------------------

# Emit $3 models named m<start>.. into a results TSV with a single status.
# $1=status $2=count $3=start_index  -> path on stdout
gen_results() {
    local st="$1" n="$2" start="$3"
    local out="$BATS_TEST_TMPDIR/results.tsv"
    local i
    : >"$out"
    for ((i = start; i < start + n; i++)); do
        printf 'test-provider/m%s\t%s\t100\n' "$i" "$st" >>"$out"
    done
    printf '%s' "$out"
}

# Model list matching gen_results, published for the mock `opencode models`.
publish_models() { # $1=count $2=start_index
    local n="$1" start="$2" i
    export MOCK_MODELS_FILE="$BATS_TEST_TMPDIR/models.txt"
    : >"$MOCK_MODELS_FILE"
    for ((i = start; i < start + n; i++)); do
        printf 'test-provider/m%s\n' "$i" >>"$MOCK_MODELS_FILE"
    done
}

# Replace the probe phase with one that copies our TSV into place. The path is
# interpolated at definition time so no large string is ever passed to eval.
stub_probe_results() { # $1=results file
    eval "probe_models_batch() { cat '$1' > \"\$3\"; }"
}

# Seed one prior failure per model in the given range so this run's failure is
# the SECOND consecutive one and therefore CONFIRMED. Without this the
# two-failure gate would leave everything TENTATIVE and the valve would have
# nothing to prevent.
seed_prior_failures() { # $1=status $2=count $3=start_index
    local st="$1" n="$2" start="$3" i
    local history="$OCPROBE_STATE_DIR/validate-history.jsonl"
    : >"$history"
    for ((i = start; i < start + n; i++)); do
        printf 'test-provider/m%s\t%s\t1000\n' "$i" "$st" >>"$history"
    done
}

# A run of $2 models: the first $1 fail with $3, the rest probe WORKS.
build_run() { # $1=failing count $2=total count $3=failing status
    local fail_n="$1" total_n="$2" st="$3"
    local results
    results=$(gen_results "$st" "$fail_n" 1)
    local i
    for ((i = fail_n + 1; i <= total_n; i++)); do
        printf 'test-provider/m%s\tWORKS\t100\n' "$i" >>"$results"
    done
    publish_models "$total_n" 1
    stub_probe_results "$results"
    seed_prior_failures "$st" "$fail_n" 1
}

blacklist_len() {
    jq -r '.provider["test-provider"].blacklist | length' "$BATS_TEST_TMPDIR/opencode.json"
}

# ---- AUTH_ERROR valve -------------------------------------------------------

@test "AUTH_ERROR valve trips: rate at/above threshold blocks the blacklist write" {
    # 5 AUTH_ERROR of 8 probed = 62%, default threshold 40
    build_run 5 8 AUTH_ERROR

    run cmd_validate --provider test-provider --apply

    assert_output --partial "AUTH_ERROR"
    assert_output --partial "Skipping blacklist changes"

    # Nothing may be retired: the valve's `continue` keeps the provider out of
    # provider_results, so overall_changes stays 0 and opencode.json is untouched.
    run blacklist_len
    assert_success
    assert_output "0"
}

@test "AUTH_ERROR valve does NOT trip below threshold: classification proceeds" {
    # 3 AUTH_ERROR of 10 probed = 30%, below the 40 threshold
    build_run 3 10 AUTH_ERROR

    run cmd_validate --provider test-provider --apply
    refute_output --partial "Skipping blacklist changes"

    # The three confirmed failures MUST be blacklisted, proving the valve did
    # not swallow a legitimate classification.
    run blacklist_len
    assert_success
    assert_output "3"
}

# ---- TIMEOUT valve ----------------------------------------------------------

@test "TIMEOUT valve trips: rate at/above threshold blocks the blacklist write" {
    # 7 TIMEOUT of 10 probed = 70%, default threshold 60
    build_run 7 10 TIMEOUT

    run cmd_validate --provider test-provider --apply
    assert_output --partial "TIMEOUT"
    assert_output --partial "Skipping blacklist changes"

    run blacklist_len
    assert_success
    assert_output "0"
}

@test "TIMEOUT valve does NOT trip below threshold: classification proceeds" {
    # 5 TIMEOUT of 10 probed = 50%, below the 60 threshold
    build_run 5 10 TIMEOUT

    run cmd_validate --provider test-provider --apply
    refute_output --partial "Skipping blacklist changes"

    run blacklist_len
    assert_success
    assert_output "5"
}

# ---- the actual historical incident ----------------------------------------

@test "TIMEOUT valve survives the historical 941/979 (96%) incident ratio" {
    # The incident was 941 of 979 models TIMEOUT (96%) at -P 8. What the valve
    # keys on is the RATIO (timeout_pct >= threshold), not the absolute count, so
    # this reproduces 19/20 = 95%.
    #
    # The absolute count is deliberately small. Each model re-derives its streak
    # by re-reading the whole history file (_validate_history_streak), which is
    # O(models x history_lines) and spawns two awk per line, so a 941-model
    # fixture takes hours. That scaling is a real defect, tracked separately
    # from these valve tests; it is not what this test is asserting.
    local total=20 failing=19 i
    local results
    results=$(gen_results TIMEOUT "$failing" 1)
    for ((i = failing + 1; i <= total; i++)); do
        printf 'test-provider/m%s\tWORKS\t100\n' "$i" >>"$results"
    done
    publish_models "$total" 1
    stub_probe_results "$results"
    seed_prior_failures TIMEOUT "$failing" 1

    run cmd_validate --provider test-provider --apply
    assert_output --partial "TIMEOUT"
    assert_output --partial "Skipping blacklist changes"

    # The whole point: the catalog survives intact.
    run blacklist_len
    assert_success
    assert_output "0"
}
