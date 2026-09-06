#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# Unit tests for validate command
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_LOG_LEVEL="error"
    export OCPROBE_LOG_FORMAT="text"

    mkdir -p "$OCPROBE_STATE_DIR"
    mkdir -p "$(dirname "$OCPROBE_CONFIG_OVERRIDE")"

    # Create minimal config
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
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
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
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF

    # Create minimal opencode.json
    cat >"$BATS_TEST_TMPDIR/opencode.json" <<EOF
{
  "provider": {
    "test-provider": {
      "blacklist": ["test-provider/old-model"],
      "whitelist": []
    }
  }
}
EOF

    # Create minimal auth.json
    cat >"$BATS_TEST_TMPDIR/auth.json" <<EOF
{
  "test-provider": {
    "type": "api",
    "key": "test-key"
  }
}
EOF

    export OCPROBE_OPencode_AUTH="$BATS_TEST_TMPDIR/auth.json"

    load_config

    # Setup mock opencode
    setup_mock_opencode
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# ---- Mock opencode command for testing ----
# Create a mock opencode executable in a test-specific PATH
setup_mock_opencode() {
    local mock_dir="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$mock_dir"
    
    cat >"$mock_dir/opencode" <<'MOCK_EOF'
#!/usr/bin/env bash
cmd="$1"
shift
case "$cmd" in
    models)
        printf 'test-provider/model-a\ntest-provider/model-b\ntest-provider/model-c\n'
        ;;
    run)
        # Parse args to find model and check for --format json
        format_json=false
        model=""
        i=1
        while [[ $i -le $# ]]; do
            arg="${!i}"
            if [[ "$arg" == "--format" ]]; then
                next=$((i+1))
                if [[ $next -le $# ]] && [[ "${!next}" == "json" ]]; then
                    format_json=true
                fi
                i=$((i+1))
            elif [[ "$arg" == "-m" ]]; then
                next=$((i+1))
                if [[ $next -le $# ]]; then
                    model="${!next}"
                fi
                i=$((i+1))
            fi
            i=$((i+1))
        done
        
        if [[ "$format_json" == "true" ]]; then
            # Output JSON with sessionID and status
            case "$model" in
                "test-provider/model-a") echo '{"type":"status","timestamp":1234567890,"sessionID":"ses_test123","status":"WORKS","message":"OK"}'; exit 0 ;;
                "test-provider/model-b")
                    echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test456","error":{"name":"APIError","data":{"message":"Gone - model reached end of life"}}}'
                    exit 1
                    ;;
                "test-provider/model-c")
                    echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test789","error":{"name":"APIError","data":{"message":"404 Not Found"}}}'
                    exit 1
                    ;;
                *) echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test999","error":{"name":"UnknownError"}}'; exit 1 ;;
            esac
        else
            # Legacy plain text output
            case "$model" in
                "test-provider/model-a") echo "OK"; exit 0 ;;
                "test-provider/model-b")
                    echo "Error: Gone - model reached end of life"
                    exit 1
                    ;;
                "test-provider/model-c")
                    echo "Error: 404 Not Found"
                    exit 1
                    ;;
                *) echo "Error: Unknown"; exit 1 ;;
            esac
        fi
        ;;
    *) exit 1 ;;
esac
MOCK_EOF
    chmod +x "$mock_dir/opencode"
    export PATH="$mock_dir:$PATH"
}

# Override get_provider_models to use mock
get_provider_models() {
    local provider_id="$1"
    opencode models "$provider_id" 2>/dev/null | sort -u
}

# ---- Tests for probe_model_classify ----

@test "probe_model_classify returns WORKS for successful model" {
    run probe_model_classify "test-provider/model-a"
    assert_success
    assert_output --partial "WORKS"
}

@test "probe_model_classify returns NOT_FOUND for EOL model" {
    run probe_model_classify "test-provider/model-b"
    assert_success
    assert_output --partial "NOT_FOUND"
}

@test "probe_model_classify returns NOT_FOUND for 404 model" {
    run probe_model_classify "test-provider/model-c"
    assert_success
    assert_output --partial "NOT_FOUND"
}

# ---- Tests for get_configured_providers ----

@test "get_configured_providers returns providers with valid credentials" {
    run get_configured_providers
    assert_success
    assert_output --partial "test-provider"
}

@test "get_configured_providers excludes providers without credentials" {
    # Add provider without key
    cat >"$OCPROBE_OPencode_AUTH" <<EOF
{
  "test-provider": {"type": "api", "key": "test-key"},
  "no-key-provider": {"type": "api", "key": ""},
  "no-type-provider": {"key": "test-key"}
}
EOF
    run get_configured_providers
    assert_success
    assert_output --partial "test-provider"
    refute_output --partial "no-key-provider"
    refute_output --partial "no-type-provider"
}

# ---- Tests for get_current_blacklist ----

@test "get_current_blacklist returns current blacklist" {
    run get_current_blacklist "test-provider"
    assert_success
    assert_output --partial "test-provider/old-model"
}

# ---- Tests for generate_blacklist_proposal ----

@test "generate_blacklist_proposal includes non-WORKS models with two-failure gate" {
    local results_file="$BATS_TEST_TMPDIR/results.tsv"
    cat >"$results_file" <<EOF
test-provider/model-a	WORKS	100
test-provider/model-b	NOT_FOUND	200
test-provider/model-c	ERROR	300
EOF

    local proposal_file="$BATS_TEST_TMPDIR/proposal.txt"
    local tentative_file="$BATS_TEST_TMPDIR/tentative.txt"
    generate_validate_classification "test-provider" "$results_file" "$proposal_file" "$tentative_file"

    # NOT_FOUND (terminal) should be CONFIRMED immediately
    run cat "$proposal_file"
    assert_success
    assert_output --partial "test-provider/model-b"
    refute_output --partial "test-provider/model-a"
    refute_output --partial "test-provider/model-c"

    # ERROR (non-terminal) should be TENTATIVE on first failure
    run cat "$BATS_TEST_TMPDIR/tentative.txt"
    assert_success
    assert_output --partial "test-provider/model-c"
    refute_output --partial "test-provider/model-b"
    refute_output --partial "test-provider/model-a"
}

# ---- Tests for apply_blacklist ----

@test "apply_blacklist writes blacklist to opencode.json" {
    local blacklist_file="$BATS_TEST_TMPDIR/blacklist.txt"
    local models_file="$BATS_TEST_TMPDIR/models.txt"
    cat >"$blacklist_file" <<EOF
test-provider/model-a
test-provider/model-b
EOF
cat >"$models_file" <<EOF
test-provider/model-a
test-provider/model-b
test-provider/model-c
EOF

    apply_blacklist "test-provider" "$blacklist_file" "$models_file"

    # Verify the config was updated
    run cat "$BATS_TEST_TMPDIR/opencode.json"
    assert_success
    assert_output --partial "test-provider/model-a"
    assert_output --partial "test-provider/model-b"
}

# ---- Tests for backup_opencode_config ----

@test "backup_opencode_config creates backup file" {
    run backup_opencode_config
    assert_success
    local backup_file="$output"
    [[ -f "$backup_file" ]] || { echo "Backup file not found: $backup_file" >&2; return 1; }
    [[ -s "$backup_file" ]] || { echo "Backup file empty: $backup_file" >&2; return 1; }
}

@test "backup_opencode_config preserves original content" {
    run backup_opencode_config
    assert_success
    local backup_file="$output"

    run diff "$BATS_TEST_TMPDIR/opencode.json" "$backup_file"
    assert_success
}

# ---- Tests for restore_from_backup ----

@test "restore_from_backup restores config from backup" {
    # First create a backup
    local backup_file
    backup_file=$(backup_opencode_config)

    # Modify the config
    cat >"$BATS_TEST_TMPDIR/opencode.json" <<EOF
{
  "provider": {
    "test-provider": {
      "blacklist": ["test-provider/new-model"],
      "whitelist": []
    }
  }
}
EOF

    # Restore
    run restore_from_backup
    assert_success

    # Verify original content restored
    run cat "$BATS_TEST_TMPDIR/opencode.json"
    assert_success
    assert_output --partial "test-provider/old-model"
    refute_output --partial "test-provider/new-model"
}

# ---- Tests for dry-run mode ----

@test "cmd_validate dry-run does not modify opencode.json" {
    # Capture original config
    local original
    original=$(cat "$BATS_TEST_TMPDIR/opencode.json")

    # Run validate in dry-run mode (no --apply) - exits 1 when changes pending
    run cmd_validate --provider test-provider
    assert_failure

    # Verify config unchanged
    local current
    current=$(cat "$BATS_TEST_TMPDIR/opencode.json")
    assert_equal "$original" "$current"
}

# ---- Tests for --apply mode ----

@test "cmd_validate --apply creates backup before writing" {
    run cmd_validate --provider test-provider --apply
    assert_success

    # Check backup directory exists and has backup
    local state_dir="${OCPROBE_STATE_DIR:-$HOME/.local/state/ocm}"
    local backup_dir="$state_dir/validate-backups"
    [[ -d "$backup_dir" ]] || { echo "Backup dir not found: $backup_dir" >&2; return 1; }

    local backup_count
    backup_count=$(ls -1 "$backup_dir"/opencode.json.backup-* 2>/dev/null | wc -l | tr -d ' ')
    assert_equal "$backup_count" 1
}

@test "cmd_validate --apply writes blacklist to opencode.json" {
    run cmd_validate --provider test-provider --apply
    assert_success

    run cat "$BATS_TEST_TMPDIR/opencode.json"
    assert_success
    assert_output --partial "test-provider/model-b"
    assert_output --partial "test-provider/model-c"
}

# ---- Tests for cmd_validate_restore ----

@test "cmd_validate --apply aborts if config changed between discovery and apply" {
    # This test requires a single --apply run where config changes mid-run.
    # We simulate this by using a custom mock that modifies the config
    # during the probe phase (phase 2), between discovery (phase 1) and apply (phase 4).
    
    # Override the mock to modify config when opencode run is called
    local mock_dir="$BATS_TEST_TMPDIR/mock-staleness"
    mkdir -p "$mock_dir"
    cat >"$mock_dir/opencode" <<'MOCK_EOF'
#!/usr/bin/env bash
cmd="$1"
shift
case "$cmd" in
    models)
        printf 'test-provider/model-a\ntest-provider/model-b\ntest-provider/model-c\n'
        ;;
    run)
        # On first run call, modify the config file to simulate external change
        if [[ ! -f "/tmp/ocprobe-staleness-test-modified" ]]; then
            touch "/tmp/ocprobe-staleness-test-modified"
            cat >"$BATS_TEST_TMPDIR/opencode.json" <<'EOF'
{
  "provider": {
    "test-provider": {
      "blacklist": ["test-provider/old-model", "test-provider/external-change"],
      "whitelist": []
    }
  }
}
EOF
        fi
        # Normal response for model-a
        if [[ "$*" == *"model-a"* ]]; then
            echo '{"type":"status","timestamp":1234567890,"sessionID":"ses_test123","status":"WORKS","message":"OK"}'
            exit 0
        elif [[ "$*" == *"model-b"* ]]; then
            echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test456","error":{"name":"APIError","data":{"message":"Gone - model reached end of life"}}}'
            exit 1
        elif [[ "$*" == *"model-c"* ]]; then
            echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test789","error":{"name":"APIError","data":{"message":"404 Not Found"}}}'
            exit 1
        else
            echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test999","error":{"name":"UnknownError"}}'
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
MOCK_EOF
    chmod +x "$mock_dir/opencode"
    export PATH="$mock_dir:$PATH"
    rm -f "/tmp/ocprobe-staleness-test-modified"

    # Run with --apply (single invocation: discovery -> probe -> apply)
    run cmd_validate --provider test-provider --apply
    assert_failure
    assert_output --partial "Config changed since discovery"
}

@test "cmd_validate_restore reverts config to backup" {
    # First run with --apply to create backup and modify config
    run cmd_validate --provider test-provider --apply
    assert_success

    # Verify config was modified
    run cat "$BATS_TEST_TMPDIR/opencode.json"
    assert_output --partial "test-provider/model-b"

    # Run restore
    run cmd_validate_restore
    assert_success

    # Verify config reverted
    run cat "$BATS_TEST_TMPDIR/opencode.json"
    assert_success
    assert_output --partial "test-provider/old-model"
    refute_output --partial "test-provider/model-b"
}

# ---- Shellcheck validation ----

@test "validate.sh passes shellcheck" {
    if command -v shellcheck >/dev/null 2>&1; then
        run shellcheck "$OCPROBE_ROOT/lib/validate.sh"
        assert_success
    else
        skip "shellcheck not installed"
    fi
}

@test "validate.sh passes bash -n" {
    run bash -n "$OCPROBE_ROOT/lib/validate.sh"
    assert_success
}

@test "ocm binary passes bash -n" {
    run bash -n "$OCPROBE_ROOT/bin/ocprobe"
    assert_success
}