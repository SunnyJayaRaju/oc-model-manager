#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/worker_self_delete.bats — the probe worker deletes its own session
# through the guarded delete path after EVERY probe outcome, so a parent that
# is killed mid-run can no longer leave the probe session behind.
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

FIXTURES="$BATS_TEST_DIRNAME/../fixtures"
PROBE_SID="ses_probeA111111111111111"
STUB_DIR=""
DELOG=""

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  export OCPROBE_LIB_DIR="$OCPROBE_ROOT/lib"

  # 2.x-shaped database with one delete-able probe session (probe title,
  # exact probe prompt as first user message, no tools, no tree, no legacy row)
  create_v2_db
  fixtures_v2_add_rows

  # Stub opencode: logs every invocation; `run` replays captured 2.x event
  # streams rewritten onto the fixture session id; `session delete` succeeds.
  STUB_DIR="$OCPROBE_RUN_DIR/stub-bin"
  DELOG="$OCPROBE_RUN_DIR/delete.log"
  INVOKE_LOG="$OCPROBE_RUN_DIR/invocations.log"
  mkdir -p "$STUB_DIR"
  cat >"$STUB_DIR/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$INVOKE_LOG"
case "\$1" in
  run)
    ev="$OCPROBE_RUN_DIR/stub-events.jsonl"
    [[ -s "\$ev" ]] || { echo "OK"; exit 0; }
    sed "s/ses_scrub[a-z0-9]*/$PROBE_SID/g" "\$ev"
    exit "\${STUB_RUN_RC:-0}"
    ;;
  session)
    if [[ "\$2" == "delete" ]]; then printf '%s\n' "\$3" >>"$DELOG"; fi
    exit 0
    ;;
  models) echo "provider/test-model"; exit 0 ;;
  --version) echo "opencode 2.3.2"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$STUB_DIR/opencode"
  export PATH="$STUB_DIR:$PATH"
  : >"$DELOG"
  : >"$INVOKE_LOG"
  rm -f "$OCPROBE_RUN_DIR/stub-events.jsonl"
}

teardown() {
  rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
}

create_v2_db() {
  local db="$OCPROBE_RUN_DIR/v2.db"
  rm -f "$db"
  sqlite3 "$db" <"$FIXTURES/opencode2x-schema.sql"
  export OCPROBE_OPencode_DB="$db"
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

fixtures_v2_add_rows() {
  local db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  sqlite3 "$db" <<EOF
INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated)
VALUES ('$PROBE_SID', 'proj_test', 'probe-a', '/tmp/proj-a', '1', 'ocprobe-probe', $ts, $ts);
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a1', '$PROBE_SID', 'user', 1, $ts, $ts,
        '{"time":{"created":$ts},"text":"Reply with exactly: OK","files":[]}');
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a2', '$PROBE_SID', 'assistant', 2, $ts, $ts,
        '{"time":{"created":$ts},"content":[{"type":"text","text":"OK"}]}');
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a3', '$PROBE_SID', 'idle', 3, $ts, $ts,
        '{"time":{"created":$ts},"outcome":"succeeded"}');
EOF
}

# Point the session code at the fixture the way the cleanup tests do
config_fixture() {
  printf '{"provider":{}}\n' >"$OCPROBE_RUN_DIR/opencode-dummy.json"
  cat >"$OCPROBE_RUN_DIR/ocm-config.yaml" <<EOF
version: 1
opencode:
  config_path: "$OCPROBE_RUN_DIR/opencode-dummy.json"
  db_path: "$OCPROBE_OPencode_DB"
EOF
  export OCPROBE_CONFIG_OVERRIDE="$OCPROBE_RUN_DIR/ocm-config.yaml"
}

run_worker() {
  local worker_file="$OCPROBE_RUN_DIR/worker.sh"
  write_worker "$worker_file"
  run "$worker_file" "provider/test-model" "TEST" "30" "Reply with exactly: OK"
}

@test "worker deletes its own session after a WORKS probe" {
  cat "$FIXTURES/probe-events-ok.jsonl" >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  run_worker
  assert_success
  assert_output --partial $'WORKS'
  grep -qx "$PROBE_SID" "$DELOG"
}

@test "worker deletes its own session after a TIMEOUT probe" {
  cat "$FIXTURES/probe-events-ok.jsonl" >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  STUB_RUN_RC=124 run_worker
  assert_success
  assert_output --partial $'TIMEOUT'
  grep -qx "$PROBE_SID" "$DELOG"
}

@test "worker deletes its own session after a provider-failure probe" {
  cat "$FIXTURES/probe-events-noauth.jsonl" >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  STUB_RUN_RC=1 run_worker
  assert_success
  # the captured stream's no-route error classifies as NOTFOUND; the outcome
  # under test is that a failed probe still deletes its session
  assert_output --partial $'NOTFOUND'
  grep -qx "$PROBE_SID" "$DELOG"
}

@test "worker deletes its own session after an AUTH_ERROR probe" {
  printf '{"type":"error","sessionID":"%s","error":{"type":"auth","message":"authentication failed: invalid_api_key"}}\n' "$PROBE_SID" \
    >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  STUB_RUN_RC=1 run_worker
  assert_success
  assert_output --partial $'AUTH_ERROR'
  grep -qx "$PROBE_SID" "$DELOG"
}

@test "worker deletes its own session after a NOTFOUND probe" {
  cat "$FIXTURES/probe-events-notfound.jsonl" >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  STUB_RUN_RC=1 run_worker
  assert_success
  assert_output --partial $'NOTFOUND'
  grep -qx "$PROBE_SID" "$DELOG"
}

@test "worker does not delete a session that contains tool calls (guard holds)" {
  cat "$FIXTURES/probe-events-ok.jsonl" >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  local ts
  ts=$(now_ms)
  sqlite3 "$OCPROBE_OPencode_DB" <<EOF
INSERT INTO session_part (message_id, session_id, ordinal, type, time_created, time_updated, data)
VALUES ('msg_a2', '$PROBE_SID', 1, 'tool', $ts, $ts, '{"tool":"bash"}');
EOF
  run_worker
  assert_success
  assert_output --partial $'WORKS'
  [[ ! -s "$DELOG" ]]
}

@test "worker skips cleanup when no session id was captured" {
  printf '' >"$OCPROBE_RUN_DIR/stub-events.jsonl"
  run_worker
  assert_success
  [[ ! -s "$DELOG" ]]
}

@test "doctor and status never create a session (no probe run invocations)" {
  config_fixture
  run cmd_doctor
  run cmd_status
  ! grep -q '^run ' "$INVOKE_LOG"
}
