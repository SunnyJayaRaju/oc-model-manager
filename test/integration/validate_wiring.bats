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

	# Pin generation 1: apply_blacklist writes model lists on 1.x and refuses on 2.x.
	local mock_dir
	mock_dir=$(mktemp -d "$BATS_TEST_TMPDIR/mock-XXXXXX")
	printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 1.7.11";; esac\n' >"$mock_dir/opencode"
	chmod +x "$mock_dir/opencode"
	export PATH="$mock_dir:$PATH"

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
# R37: probe_model_classify must delete its OWN probe session even when the
# model FAILS and the session contains tool calls. Before the fix, the guard
# refused both (tool-call gate + 4-message ceiling), so every failed probe
# leaked a session. Stub CLI only: no model call, no network.
@test "R37 validate: a FAILED probe that emitted tool calls is still deleted" {
  local db="$BATS_TEST_TMPDIR/v2.db"
  rm -f "$db"
  sqlite3 "$db" <"$OCPROBE_ROOT/test/fixtures/opencode2x-schema.sql"
  export OCPROBE_OPencode_DB="$db"
  export DELETE_TRACK="$BATS_TEST_TMPDIR/deleted.txt"
  : >"$DELETE_TRACK"
  export STUB_DB="$db"

  local mock_dir
  mock_dir=$(mktemp -d "$BATS_TEST_TMPDIR/r37-mock-XXXXXX")
  cat >"$mock_dir/opencode" <<'STUB'
#!/usr/bin/env bash
ts=$(python3 -c 'import time; print(int(time.time()*1000))')
case "$1" in
  run)
    sid=ses_failedProbe1111111
    sqlite3 "$STUB_DB" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('$sid','proj_test','fp','/tmp/proj','1','ocprobe-validate',$ts,$ts);
      INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('m1','$sid','user',1,$ts,$ts,'{\"text\":\"Reply with exactly: OK\"}');
      INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('m2','$sid','assistant',2,$ts,$ts,'{\"content\":[{\"type\":\"tool\",\"callID\":\"c1\"}]}');
      INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('m3','$sid','assistant',3,$ts,$ts,'{\"content\":[{\"type\":\"text\",\"text\":\"partial\"}]}');"
    printf '{"type":"error","error":{"type":"provider","message":"boom"}}\n'
    printf '{"sessionID":"%s"}\n' "$sid"
    exit 1
    ;;
  session)
    case "$2" in
      delete)
        echo "$3" >>"$DELETE_TRACK"
        sqlite3 "$STUB_DB" "DELETE FROM session_message WHERE session_id='$3'; DELETE FROM session_v2 WHERE id='$3';"
        exit 0 ;;
    esac
    ;;
  --version) echo "opencode 2.3.0" ;;
esac
STUB
  chmod +x "$mock_dir/opencode"
  cat >"$mock_dir/timeout" <<'T'
#!/usr/bin/env bash
shift
exec "$@"
T
  chmod +x "$mock_dir/timeout"

  PATH="$mock_dir:$PATH" run probe_model_classify "test-provider/failing-model" 10 "Reply with exactly: OK"
  assert_success
  assert_output --partial "ERROR"
  run cat "$DELETE_TRACK"
  assert_line "ses_failedProbe1111111"
  run sqlite3 "$db" "SELECT count(*) FROM session_v2 WHERE id='ses_failedProbe1111111';"
  assert_output "0"
}
