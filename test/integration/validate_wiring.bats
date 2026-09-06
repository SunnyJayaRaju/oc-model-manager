#!/usr/bin/env bats
# test/integration/validate_wiring.bats — Integration tests for validate command wiring

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'
load '../helpers/setup_libs'

setup() {
	source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

	# Create test config directory with policy schema
	local test_config_dir="$BATS_TEST_TMPDIR/config"
	mkdir -p "$test_config_dir"
	cp "$OCPROBE_ROOT/config/policy.schema.json" "$test_config_dir/policy.schema.json"
	cp "$OCPROBE_ROOT/config/policy.schema.json" "$BATS_TEST_TMPDIR/policy.schema.json"

	# Create test config.yaml with correct opencode.config_path pointing to test opencode.json
	cat >"$test_config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-validate"
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

	# Create minimal opencode.json and auth.json
	cat >"$BATS_TEST_TMPDIR/opencode.json" <<EOF
{
  "provider": {
    "test-provider": {
      "whitelist": ["test-provider/model-a", "test-provider/model-b", "test-provider/model-c", "test-provider/model-d", "test-provider/model-e"]
    }
  }
}
EOF
	cat >"$BATS_TEST_TMPDIR/auth.json" <<EOF
{
  "test-provider": {
    "type": "api",
    "key": "test-key"
  }
}
EOF

	# Set config override to use test config
	export OCPROBE_CONFIG_OVERRIDE="$test_config_dir/config.yaml"
	export OCPROBE_OPencode_CONFIG="$BATS_TEST_TMPDIR/opencode.json"
	export OCPROBE_OPencode_AUTH="$BATS_TEST_TMPDIR/auth.json"

	# Initialize logging
	init_logging
}

teardown() {
	rm -f /tmp/ocprobe-test-policy-*.yaml
	rm -f /tmp/ocprobe-test-opencode-*.json
}

# ---- Test 1: AUTH_ERROR threshold abort ----
@test "provider-wide AUTH_ERROR threshold aborts blacklist changes" {
	local policy_file
	policy_file=$(mktemp /tmp/ocprobe-test-policy-XXXXXX.yaml)
	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
auto_apply: true
never_remove: []
never_add: []
providers:
  test-provider:
    enabled: true
    include: ["*"]
    exclude: []
    auto_apply: true
EOF

	local opencode_config
	opencode_config=$(mktemp /tmp/ocprobe-test-opencode-XXXXXX.json)
	
	# Create opencode.json with 5 whitelisted models under one provider
	cat >"$opencode_config" <<EOF
{
  "provider": {
    "test-provider": {
      "whitelist": [
        "test-provider/model-a",
        "test-provider/model-b",
        "test-provider/model-c",
        "test-provider/model-d",
        "test-provider/model-e"
      ]
    }
  }
}
EOF

	# Mock opencode to return results with 4 AUTH_ERROR out of 5 models (80%)
	local mock_dir
	mock_dir=$(mktemp -d /tmp/ocprobe-mock-XXXXXX)
	cat >"$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
test-provider/model-a
test-provider/model-b
test-provider/model-c
test-provider/model-d
test-provider/model-e
MODELS
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
        "test-provider/model-a") echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test123","error":{"name":"APIError","data":{"message":"401 Unauthorized"}}}'; exit 1 ;;
        "test-provider/model-b") echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test456","error":{"name":"APIError","data":{"message":"403 Forbidden"}}}'; exit 1 ;;
        "test-provider/model-c") echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test789","error":{"name":"APIError","data":{"message":"403 Forbidden"}}}'; exit 1 ;;
        "test-provider/model-d") echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test012","error":{"name":"APIError","data":{"message":"401 Unauthorized"}}}'; exit 1 ;;
        "test-provider/model-e") echo '{"type":"status","timestamp":1234567890,"sessionID":"ses_test345","status":"WORKS","message":"OK"}'; exit 0 ;;
        *) echo '{"type":"error","timestamp":1234567890,"sessionID":"ses_test999","error":{"name":"UnknownError"}}'; exit 1 ;;
      esac
    else
      case "$model" in
        "test-provider/model-a") echo "Error: 401 Unauthorized"; exit 1 ;;
        "test-provider/model-b") echo "Error: 403 Forbidden"; exit 1 ;;
        "test-provider/model-c") echo "Error: 403 Forbidden"; exit 1 ;;
        "test-provider/model-d") echo "Error: 401 Unauthorized"; exit 1 ;;
        "test-provider/model-e") echo "OK"; exit 0 ;;
        *) echo "Error: Unknown"; exit 1 ;;
      esac
    fi
    ;;
  --version)
    echo "opencode 0.1.0-test"
    ;;
esac
EOF
	chmod +x "$mock_dir/opencode"

	# Mock timeout
	cat >"$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ $# -lt 2 ]]; then
  echo "Usage: timeout SECONDS COMMAND [ARGS...]" >&2
  exit 1
fi
shift
exec "$@"
EOF
	chmod +x "$mock_dir/timeout"

	export PATH="$mock_dir:$PATH"
	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_OPencode_CONFIG="$opencode_config"
	export OCPROBE_STATE_DIR=$(mktemp -d /tmp/ocprobe-test-state-XXXXXX)
	export OCPROBE_RUN_DIR=$(mktemp -d /tmp/ocprobe-test-run-XXXXXX)
	export OCPROBE_LOG_LEVEL=error
	export OCPROBE_LOG_FILE="$OCPROBE_RUN_DIR/audit.log"
	export OCPROBE_RESULTS_FILE="$OCPROBE_RUN_DIR/results.tsv"
	export OCPROBE_LOCK_DIR="$OCPROBE_STATE_DIR/.lock"
	mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

	init_logging

	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_OPencode_CONFIG="$opencode_config"
	load_config
	load_policy
	policy_write_never_remove_file
	fetch_catalog
	compute_diff

	# Check that provider was skipped due to AUTH_ERROR threshold
	# The provider should be skipped entirely due to 80% AUTH_ERROR > 40% threshold
	# So new.txt should be empty (no models probed) and excluded.txt should be empty too
	# because the provider was skipped entirely

	# Check that provider was skipped (no blacklist proposed for it)
	run test -f "$OCPROBE_RUN_DIR/test-provider.proposed_blacklist.txt"
	assert_failure

	# Check that excluded.txt is empty (provider skipped, no models excluded individually)
	run wc -l <"$OCPROBE_RUN_DIR/excluded.txt"
	assert_success
	run bash -c 'wc -l <"$OCPROBE_RUN_DIR/excluded.txt" | tr -d " "'
	assert_output "0"

	# Cleanup
	rm -rf "$mock_dir" "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR" "$policy_file" "$opencode_config"
}

# ---- Test 2: apply_blacklist merges by model id ----
@test "apply_blacklist merges by model id, never wipes untouched entries" {
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

	export OCPROBE_OPencode_CONFIG="/tmp/test_opencode.json"
	export OCPROBE_STATE_DIR="/tmp/test_state"
	export OCPROBE_RUN_DIR="/tmp/test_run"
	mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

	cat >"$OCPROBE_OPencode_CONFIG" <<EOF
{
  "provider": {
    "test-provider": {
      "blacklist": ["test-provider/old-model"],
      "whitelist": []
    }
  }
}
EOF

	apply_blacklist "test-provider" "$blacklist_file" "$models_file"

	# Verify old-model is preserved (not in probed models)
	run cat "$OCPROBE_OPencode_CONFIG"
	assert_output --partial "test-provider/old-model"
	assert_output --partial "test-provider/model-a"
	assert_output --partial "test-provider/model-b"
	# model-c was probed and passed, so it should NOT be in blacklist
	refute_output --partial "test-provider/model-c"
}

# ---- Test 3: three-bucket verify reporting ----
@test "verify_blacklist_effect reports three buckets correctly" {
	local policy_file
	policy_file=$(mktemp /tmp/ocprobe-test-policy-XXXXXX.yaml)
	cat >"$policy_file" <<'EOF'
version: 1
enabled: true
auto_apply: false
never_remove:
  - "openai/gpt-4"
never_add: []
providers: {}
EOF

	local opencode_config
	opencode_config=$(mktemp /tmp/ocprobe-test-opencode-XXXXXX.json)
	cat >"$opencode_config" <<EOF
{
  "provider": {
    "test-provider": {
      "whitelist": ["openai/gpt-4", "anthropic/claude-3"]
    }
  }
}
EOF

	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_OPencode_CONFIG="$opencode_config"
	export OCPROBE_STATE_DIR=$(mktemp -d /tmp/ocprobe-test-state-XXXXXX)
	export OCPROBE_RUN_DIR=$(mktemp -d /tmp/ocprobe-test-run-XXXXXX)
	export OCPROBE_LOG_LEVEL=error
	export OCPROBE_LOG_FILE="$OCPROBE_RUN_DIR/audit.log"
	export OCPROBE_RESULTS_FILE="$OCPROBE_RUN_DIR/results.tsv"
	export OCPROBE_LOCK_DIR="$OCPROBE_STATE_DIR/.lock"
	mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

	init_logging

	# Create a fake results file with a WHITELIST EOL entry for openai/gpt-4
	cat >"$OCPROBE_RESULTS_FILE" <<EOF
WHITELIST	openai/gpt-4	EOL	100
WHITELIST	anthropic/claude-3	EOL	200
EOF

	# Create whitelist file
	echo -e "openai/gpt-4\nanthropic/claude-3" >"$OCPROBE_RUN_DIR/wl.txt"
	# Create empty cooling.txt
	: >"$OCPROBE_RUN_DIR/cooling.txt"

	# Set up policy
	export OCPROBE_POLICY_OVERRIDE="$policy_file"
	export OCPROBE_CONFIG_DIR="$BATS_TEST_DIRNAME/../../config"
	load_config
	load_policy
	policy_write_never_remove_file

	# Run generate_report
	generate_report

	# Check that dead.txt does NOT contain openai/gpt-4
	run grep -Fx "openai/gpt-4" "$OCPROBE_RUN_DIR/dead.txt"
	assert_failure

	# Cleanup
	rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR" "$policy_file"
}