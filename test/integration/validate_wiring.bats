#!/usr/bin/env bats
# test/integration/validate_wiring.bats — Integration tests for validate command wiring

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'
load '../helpers/setup_libs'

# ---- Test: apply_blacklist merges by model id ----
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

	run cat "$OCPROBE_OPencode_CONFIG"
	assert_output --partial "test-provider/old-model"
	assert_output --partial "test-provider/model-a"
	assert_output --partial "test-provider/model-b"
	refute_output --partial "test-provider/model-c"
}

# ---- Test: cmd_validate --apply honestly reports STILL_VISIBLE via exit code 2 ----
@test "cmd_validate --apply returns exit 2 and reports still_visible when picker shows blacklisted model" {
	local mock_dir
	mock_dir=$(mktemp -d "$BATS_TEST_TMPDIR/mock-XXXXXX")
	cat >"$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    echo "test-provider/model-a"
    echo "test-provider/model-b"
    ;;
  run)
    model=""
    i=1
    while [[ $i -le $# ]]; do
      arg="${!i}"
      if [[ "$arg" == "-m" ]]; then
        next=$((i+1))
        [[ $next -le $# ]] && model="${!next}"
      fi
      i=$((i+1))
    done
    case "$model" in
      "test-provider/model-a") echo '{"type":"status","status":"WORKS"}'; exit 0 ;;
      "test-provider/model-b") echo '{"type":"error","error":{"data":{"message":"404 Not Found"}}}'; exit 1 ;;
      *) echo "Error: Unknown"; exit 1 ;;
    esac
    ;;
  --version) echo "opencode 0.1.0-test" ;;
esac
EOF
	chmod +x "$mock_dir/opencode"
	cat >"$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
	chmod +x "$mock_dir/timeout"
	export PATH="$mock_dir:$PATH"

	cat >"$BATS_TEST_TMPDIR/opencode.json" <<EOF
{
  "provider": {
    "test-provider": {
      "whitelist": ["test-provider/model-a", "test-provider/model-b"]
    }
  }
}
EOF
	cat >"$BATS_TEST_TMPDIR/auth.json" <<EOF
{
  "test-provider": { "type": "api", "key": "test-key" }
}
EOF

	# Create test config YAML
	cat >"$BATS_TEST_TMPDIR/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
EOF

	export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
	export OCPROBE_OPencode_CONFIG="$BATS_TEST_TMPDIR/opencode.json"
	export OCPROBE_OPencode_AUTH="$BATS_TEST_TMPDIR/auth.json"

	run cmd_validate --provider test-provider --apply
	assert_equal 2 "$status"
	assert_output --partial "still_visible=1"
	assert_output --partial "written=1"
}