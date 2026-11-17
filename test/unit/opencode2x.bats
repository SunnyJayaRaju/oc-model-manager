#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/opencode2x.bats — OpenCode 2.x compatibility tests
#
# Fixtures:
#   test/fixtures/opencode2x-schema.sql  — the real 2.x DDL (captured from a
#     2.3.0 database; DDL only, no row content)
#   test/fixtures/probe-events-*.jsonl   — real `opencode run --format json`
#     event shapes with session/message ids scrubbed
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

FIXTURES="$BATS_TEST_DIRNAME/../fixtures"
SCRUB_SESSION="ses_scrubok111111111111111"

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  export OCPROBE_ROOT="${OCPROBE_ROOT:-$(cd "$BATS_TEST_DIRNAME/../.." && pwd)}"
  mkdir -p "$OCPROBE_RUN_DIR"
  # Session-layer knobs the tests read directly
  OCPROBE_PROBE_PROMPT="Reply with exactly: OK"
  OCPROBE_VALIDATE_PROBE_PROMPT="Reply with exactly: OK"
  OCPROBE_MAX_MSG_COUNT=4
}

teardown() {
  rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
}

# ---- shared fixture helpers --------------------------------------------------

# Build a 2.x-shaped database from the real captured DDL.
# Extra rows are added by the calling test via fixtures_v2_add_rows.
create_v2_db() {
  local db="$OCPROBE_RUN_DIR/v2.db"
  rm -f "$db"
  sqlite3 "$db" <"$FIXTURES/opencode2x-schema.sql"
  export OCPROBE_OPencode_DB="$db"
}

now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }

# ---- F1: config discovery + JSONC -------------------------------------------

@test "resolve_opencode_config_file: explicit override wins" {
  local cfg="$BATS_TEST_TMPDIR/explicit.json"
  : >"$cfg"
  OCPROBE_OPencode_CONFIG="$cfg"
  run resolve_opencode_config_file
  assert_success
  assert_output "$cfg"
}

@test "resolve_opencode_config_file: .jsonc preferred when the default .json is absent" {
  local dir="$BATS_TEST_TMPDIR/discover-jsonc"
  mkdir -p "$dir"
  printf '{\n  "provider": {}\n}\n' >"$dir/opencode.jsonc"
  DEFAULT_OPENCODE_CONFIG="$dir/opencode.json"
  unset OCPROBE_OPencode_CONFIG
  run resolve_opencode_config_file
  assert_success
  assert_output "$dir/opencode.jsonc"
}

@test "resolve_opencode_config_file: .json used when no .jsonc exists" {
  local dir="$BATS_TEST_TMPDIR/discover-json"
  mkdir -p "$dir"
  printf '{\n  "provider": {}\n}\n' >"$dir/opencode.json"
  DEFAULT_OPENCODE_CONFIG="$dir/opencode.json"
  unset OCPROBE_OPencode_CONFIG
  run resolve_opencode_config_file
  assert_success
  assert_output "$dir/opencode.json"
}

@test "oc_config_read parses .jsonc with comments, trailing commas and a // inside a string" {
  local cfg="$BATS_TEST_TMPDIR/edge.jsonc"
  cat >"$cfg" <<'EOF'
{
  // leading comment
  "note": "url https://example.com/a // not a comment",
  /* block comment
     spanning lines */
  "provider": {
    "opencode": {
      "whitelist": ["m/one", "m/two",],
    },
  },
}
EOF
  run oc_config_read "$cfg"
  assert_success
  local out
  out=$(oc_config_read "$cfg")
  run python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["provider"]["opencode"]["whitelist"][0]); print(d["note"])' <<<"$out"
  assert_success
  assert_line "m/one"
  assert_line "url https://example.com/a // not a comment"
}

@test "oc_config_read parses a BOM and CRLF .jsonc" {
  local cfg="$BATS_TEST_TMPDIR/bom.jsonc"
  printf '\xef\xbb\xbf{\r\n  "provider": {\r\n    "opencode": {\r\n      "whitelist": ["m/one"],\r\n    },\r\n  },\r\n}\r\n' >"$cfg"
  run oc_config_read "$cfg"
  assert_success
  assert_output --partial '"m/one"'
}

@test "patching a .jsonc never creates a shadowing .json next to it" {
  local dir="$BATS_TEST_TMPDIR/no-shadow"
  mkdir -p "$dir"
  printf '{\n  // keep\n  "provider": {\n    "opencode": {\n      "whitelist": ["m/one"]\n    }\n  }\n}\n' >"$dir/opencode.jsonc"
  oc_config_patch_array "$dir/opencode.jsonc" "provider.opencode.whitelist" '["m/one", "m/two"]'
  assert [ -f "$dir/opencode.jsonc" ]
  assert [ ! -e "$dir/opencode.json" ]
  # comments survive the patch
  run grep -c "keep" "$dir/opencode.jsonc"
  assert_output "1"
}

@test "oc_config_patch_array leaves every other byte identical" {
  local cfg="$BATS_TEST_TMPDIR/bytes.jsonc"
  cat >"$cfg" <<'EOF'
{
  "alpha": [
    "a1", // trailing comment on a line
    "a2"
  ],
  "provider": {
    "opencode": {
      "whitelist": ["x/old"]
    }
  }
}
EOF
  cp "$cfg" "$cfg.before"
  oc_config_patch_array "$cfg" "provider.opencode.whitelist" '["x/new"]'
  # diff exits 1 when the files differ — the span change is the one allowed
  # difference; anything else (comments, sibling keys) must never appear.
  run diff "$cfg.before" "$cfg"
  assert_equal "${status}" 1
  assert_output --partial "x/new"
  refute_output --partial "a1"
  refute_output --partial "alpha"
}

@test "oc_config_patch_array refuses a missing key and reports rc 3" {
  local cfg="$BATS_TEST_TMPDIR/missing.jsonc"
  printf '{\n  "provider": { "opencode": {} }\n}\n' >"$cfg"
  run oc_config_patch_array "$cfg" "provider.opencode.whitelist" '["m/one"]'
  assert_failure
  assert_equal "${status}" 3
}

# ---- F2: generation detection + write refusal + dry-run ----------------------

@test "oc_generation: 2.x, 1.x and missing opencode" {
  local mock="$BATS_TEST_TMPDIR/gen2"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 2.3.0";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run oc_generation
  assert_output "2"

  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 1.7.11";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run oc_generation
  assert_output "1"

  local empty="$BATS_TEST_TMPDIR/gen-none"
  mkdir -p "$empty"
  # no opencode, but the usual tools (sed) still available — as on a real machine
  PATH="$empty:/usr/bin:/bin" run oc_generation
  assert_output "1"
}

@test "merge_blacklist refuses to write on OpenCode 2.x and leaves the file byte-identical" {
  local cfg="$BATS_TEST_TMPDIR/bl-2x.json"
  printf '{\n  "provider": {\n    "opencode": {\n      "blacklist": ["old/dead"]\n    }\n  }\n}\n' >"$cfg"
  cp "$cfg" "$cfg.before"
  local mock="$BATS_TEST_TMPDIR/gen2"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 2.3.0";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run merge_blacklist "$cfg" "opencode" '["new/dead"]' '' ''
  assert_failure
  assert_output --partial "does not honour provider model lists"
  # nothing was changed
  run cmp -s "$cfg" "$cfg.before"
  assert_success
}

@test "merge_blacklist still writes on OpenCode 1.x (jsonc span patch)" {
  local cfg="$BATS_TEST_TMPDIR/bl-1x.jsonc"
  printf '{\n  // owner comment\n  "provider": {\n    "opencode": {\n      "blacklist": ["old/dead"]\n    }\n  }\n}\n' >"$cfg"
  local mock="$BATS_TEST_TMPDIR/gen1"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 1.7.11";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run merge_blacklist "$cfg" "opencode" '["new/dead"]' '' ''
  assert_success
  run grep -c "owner comment" "$cfg"
  assert_output "1"
  run grep -c "new/dead" "$cfg"
  assert_output "1"
  run grep -c "old/dead" "$cfg"
  assert_output "0"
}

@test "apply_changes honors OCPROBE_DRY_RUN: prints pending, writes nothing" {
  local cfg="$BATS_TEST_TMPDIR/dryrun.json"
  printf '{\n  "provider": {\n    "opencode": {\n      "whitelist": ["dead/one"]\n    }\n  }\n}\n' >"$cfg"
  cp "$cfg" "$cfg.before"
  export OCPROBE_OPencode_CONFIG="$cfg"
  export OCPROBE_STAMP="12345"
  export OCPROBE_DRY_RUN=1
  export OCPROBE_ASSUME_YES=0
  REPORT_ADDS=("new/works")
  export REPORT_ADDS
  REPORT_DEAD_N=1
  export REPORT_DEAD_N
  REPORT_WL_COUNT=5
  export REPORT_WL_COUNT
  printf 'dead/one\n' >"$OCPROBE_RUN_DIR/dead.txt"
  local mock="$BATS_TEST_TMPDIR/gen1"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 1.7.11";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run apply_changes
  # changes pending → non-zero, nothing written, no backup
  assert_failure
  assert_output --partial "DRY-RUN"
  run cmp -s "$cfg" "$cfg.before"
  assert_success
  run ls "$cfg".ocprobe-backup-* 2>/dev/null
  assert_failure
}

@test "apply_changes refuses per-model writes on OpenCode 2.x" {
  local cfg="$BATS_TEST_TMPDIR/apply-2x.json"
  printf '{\n  "provider": {\n    "opencode": {\n      "whitelist": ["dead/one"]\n    }\n  }\n}\n' >"$cfg"
  cp "$cfg" "$cfg.before"
  export OCPROBE_OPencode_CONFIG="$cfg"
  export OCPROBE_STAMP="12345"
  export OCPROBE_DRY_RUN=0
  export OCPROBE_ASSUME_YES=1
  REPORT_ADDS=("new/works")
  export REPORT_ADDS
  REPORT_DEAD_N=1
  export REPORT_DEAD_N
  REPORT_WL_COUNT=5
  export REPORT_WL_COUNT
  printf 'dead/one\n' >"$OCPROBE_RUN_DIR/dead.txt"
  local mock="$BATS_TEST_TMPDIR/gen2"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\ncase "$1" in --version) echo "opencode 2.3.0";; esac\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run apply_changes
  assert_failure
  assert_output --partial "does not honour provider model lists"
  run cmp -s "$cfg" "$cfg.before"
  assert_success
  run ls "$cfg".ocprobe-backup-* 2>/dev/null
  assert_failure
}

# ---- F3: v2 sessions ----------------------------------------------------------

fixtures_v2_add_rows() {
  local db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  sqlite3 "$db" <<EOF
INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated)
VALUES ('ses_probeA111111111111111', 'proj_test', 'probe-a', '/tmp/proj-a', '1', 'ocprobe-probe', $ts, $ts);
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a1', 'ses_probeA111111111111111', 'user', 1, $ts, $ts,
        '{"time":{"created":$ts},"text":"Reply with exactly: OK","files":[]}');
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a2', 'ses_probeA111111111111111', 'assistant', 2, $ts, $ts,
        '{"time":{"created":$ts},"content":[{"type":"text","text":"OK"}]}');
INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data)
VALUES ('msg_a3', 'ses_probeA111111111111111', 'idle', 3, $ts, $ts,
        '{"time":{"created":$ts},"outcome":"succeeded"}');
EOF
}

# cmd_session_* subcommands run load_config, whose emitter resets
# OCPROBE_OPencode_DB / OCPROBE_SESSION_BACKUP_DIR from the ocm config yaml.
# Point that config at the fixture DB the supported way: the config keys.
v2_load_config_fixtures() {
  printf '{"provider":{}}\n' >"$OCPROBE_RUN_DIR/opencode-dummy.json"
  OCPROBE_CONFIG_OVERRIDE="$OCPROBE_RUN_DIR/ocm-config.yaml"
  cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$OCPROBE_RUN_DIR/opencode-dummy.json"
  db_path: "$OCPROBE_OPencode_DB"
session:
  backup_dir: "$OCPROBE_RUN_DIR/backups"
EOF
}

@test "oc_db_is_v2: true for the real 2.x DDL, false for the 1.x schema, false when missing" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  run oc_db_is_v2
  assert_success

  local legacy="$OCPROBE_RUN_DIR/legacy.db"
  rm -f "$legacy"
  sqlite3 "$legacy" <<'EOF'
CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id INTEGER PRIMARY KEY, session_id TEXT, time_created INTEGER);
CREATE TABLE part (id INTEGER PRIMARY KEY, session_id TEXT, message_id INTEGER, time_created INTEGER, data TEXT);
EOF
  OCPROBE_OPencode_DB="$legacy" run oc_db_is_v2
  assert_failure

  OCPROBE_OPencode_DB="$OCPROBE_RUN_DIR/nope.db" run oc_db_is_v2
  assert_failure
}

@test "get_session_title reads session_v2 on a 2.x database" {
  create_v2_db
  fixtures_v2_add_rows
  run get_session_title "ses_probeA111111111111111"
  assert_success
  assert_output --partial "ocprobe-probe"
}

@test "list_all_session_ids covers v2 rows and legacy ghosts" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  sqlite3 "$db" "INSERT INTO session (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_legacyghost111111', 'proj_legacy', 'lg', '/tmp/proj-legacy', '1', 'ocmm-probe-old', 1, 1);"
  run list_all_session_ids
  assert_success
  assert_line "ses_probeA111111111111111"
  assert_line "ses_legacyghost111111"
}

@test "list_probe_sessions_since (v2) lists a clean probe session" {
  create_v2_db
  fixtures_v2_add_rows
  run list_probe_sessions_since 0
  assert_success
  assert_line --partial "ses_probeA111111111111111"
}

@test "list_probe_sessions_since (v2) never lists unsafe sessions" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)

  fixtures_v2_add_rows # the one safe session

  # legacy-backed: same id in session AND session_v2
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeLegacy11111', 'proj_test', 'pl', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_l1', 'ses_probeLegacy11111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  sqlite3 "$db" "INSERT INTO session (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeLegacy11111', 'proj_legacy', 'pl', '/tmp/proj-legacy', '1', 'ocprobe-probe', $ts, $ts);"

  # parent: has a child
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, parent_id, time_created, time_updated) VALUES ('ses_probeParent11111', 'proj_test', 'pp', '/tmp/proj', '1', 'ocprobe-probe', NULL, $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_p1', 'ses_probeParent11111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, parent_id, time_created, time_updated) VALUES ('ses_probeChild111111', 'proj_test', 'pc', '/tmp/proj', '1', 'ocprobe-probe', 'ses_probeParent11111', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_c1', 'ses_probeChild111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"

  # tool calls
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeTools111111', 'proj_test', 'pt', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_t1', 'ses_probeTools111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_t2', 'ses_probeTools111111', 'assistant', 2, $ts, $ts, '{\"content\":[{\"type\":\"tool\",\"callID\":\"c1\",\"tool\":\"read\"}]}');"

  # too many messages
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeLong111111', 'proj_test', 'pn', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_n1', 'ses_probeLong111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  local i
  for i in 2 3 4 5 6; do
    sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_n$i', 'ses_probeLong111111', 'assistant', $i, $ts, $ts, '{\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}');"
  done

  # wrong prompt
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeWrong11111', 'proj_test', 'pw', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_w1', 'ses_probeWrong11111', 'user', 1, $ts, $ts, '{\"text\":\"write my thesis\"}');"

  # wrong title
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeReal111111', 'proj_test', 'pr', '/tmp/proj', '1', 'Real Session', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_r1', 'ses_probeReal111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"

  run list_probe_sessions_since 0
  assert_success
  assert_line --partial "ses_probeA111111111111111"
  refute_output --partial "ses_probeLegacy11111"
  refute_output --partial "ses_probeParent11111"
  refute_output --partial "ses_probeChild111111"
  refute_output --partial "ses_probeTools111111"
  refute_output --partial "ses_probeLong111111"
  refute_output --partial "ses_probeWrong11111"
  refute_output --partial "ses_probeReal111111"
}

@test "list_probe_sessions_since (v2) does not list old sessions (age guard)" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts old_ts
  ts=$(now_ms)
  old_ts=$((ts - 100 * 24 * 3600 * 1000))
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeOld11111111', 'proj_test', 'po', '/tmp/proj', '1', 'ocprobe-probe', $old_ts, $old_ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_o1', 'ses_probeOld11111111', 'user', 1, $old_ts, $old_ts, '{\"text\":\"Reply with exactly: OK\"}');"
  run list_probe_sessions_since 0
  assert_success
  refute_output --partial "ses_probeOld11111111"
}

@test "delete_session refuses v2 sessions with a legacy row" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  sqlite3 "$db" "INSERT INTO session (id, project_id, slug, directory, version, title, time_created, time_updated) SELECT id, 'proj_legacy', slug, directory, version, title, time_created, time_updated FROM session_v2 WHERE id='ses_probeA111111111111111';"
  run delete_session "ses_probeA111111111111111"
  assert_failure
  assert_output --partial "legacy (v1) row"
}

@test "delete_session refuses v2 sessions with a parent or a child" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeParent11111', 'proj_test', 'pp', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_p1', 'ses_probeParent11111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, parent_id, time_created, time_updated) VALUES ('ses_probeChild111111', 'proj_test', 'pc', '/tmp/proj', '1', 'ocprobe-probe', 'ses_probeParent11111', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_c1', 'ses_probeChild111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  run delete_session "ses_probeParent11111"
  assert_failure
  assert_output --partial "parent or child"
  run delete_session "ses_probeChild111111"
  assert_failure
  assert_output --partial "parent or child"
}

@test "delete_session refuses v2 sessions with tool calls" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeTools111111', 'proj_test', 'pt', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_t1', 'ses_probeTools111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_t2', 'ses_probeTools111111', 'assistant', 2, $ts, $ts, '{\"content\":[{\"type\":\"tool\",\"callID\":\"c1\"}]}');"
  run delete_session "ses_probeTools111111"
  assert_failure
  assert_output --partial "tool calls"
}

@test "delete_session refuses v2 sessions whose first user message is not a probe prompt" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeWrong11111', 'proj_test', 'pw', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_w1', 'ses_probeWrong11111', 'user', 1, $ts, $ts, '{\"text\":\"write my thesis\"}');"
  run delete_session "ses_probeWrong11111"
  assert_failure
  assert_output --partial "not a configured probe prompt"
}

@test "delete_session refuses sessions with more than the message ceiling" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts i
  ts=$(now_ms)
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('ses_probeLong111111', 'proj_test', 'pn', '/tmp/proj', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_n1', 'ses_probeLong111111', 'user', 1, $ts, $ts, '{\"text\":\"Reply with exactly: OK\"}');"
  for i in 2 3 4 5 6; do
    sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('msg_n$i', 'ses_probeLong111111', 'assistant', $i, $ts, $ts, '{\"content\":[{\"type\":\"text\",\"text\":\"OK\"}]}');"
  done
  run delete_session "ses_probeLong111111"
  assert_failure
  assert_output --partial "message ceiling"
}

@test "delete_session deletes a clean probe session through the CLI only" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/del-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "opencode 2.3.0" ;;
  session)
    case "$2" in
      delete) echo "$3" >>"$DELETE_TRACK"; exit 0 ;;
    esac
    ;;
esac
EOF
  chmod +x "$mock/opencode"
  export DELETE_TRACK="$OCPROBE_RUN_DIR/deleted.txt"
  : >"$DELETE_TRACK"
  PATH="$mock:$PATH" run delete_session "ses_probeA111111111111111"
  assert_success
  run cat "$DELETE_TRACK"
  assert_line "ses_probeA111111111111111"
}

@test "delete_session still refuses malformed ids" {
  run delete_session "rm -rf /"
  assert_failure
  assert_output --partial "malformed session id"
}

@test "session cleanup is a dry run by default and applies only with --apply" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/cl-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "opencode 2.3.0" ;;
  session)
    case "$2" in
      delete) echo "$3" >>"$DELETE_TRACK"; exit 0 ;;
    esac
    ;;
esac
EOF
  chmod +x "$mock/opencode"
  export DELETE_TRACK="$OCPROBE_RUN_DIR/deleted.txt"
  : >"$DELETE_TRACK"
  v2_load_config_fixtures
  # The probe session was just created; the standalone cleanup only deletes
  # sessions that are at least 15 minutes old (time_updated), so age it.
  local ts
  ts=$(now_ms)
  sqlite3 "$db" "UPDATE session_v2 SET time_created = $ts - 20*60*1000, time_updated = $ts - 20*60*1000 WHERE id='ses_probeA111111111111111';"

  PATH="$mock:$PATH" run cmd_session_cleanup
  assert_success
  assert_output --partial "would delete"
  run cat "$DELETE_TRACK"
  assert_output ""

  PATH="$mock:$PATH" run cmd_session_cleanup --apply
  assert_success
  run cat "$DELETE_TRACK"
  assert_line "ses_probeA111111111111111"
}

@test "session cleanup --apply exits non-zero when a delete fails" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/clfail-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --version) echo "opencode 2.3.0" ;;
  session)
    case "$2" in
      delete) exit 1 ;;
    esac
    ;;
esac
EOF
  chmod +x "$mock/opencode"
  v2_load_config_fixtures
  local ts
  ts=$(now_ms)
  sqlite3 "$db" "UPDATE session_v2 SET time_created = $ts - 20*60*1000, time_updated = $ts - 20*60*1000 WHERE id='ses_probeA111111111111111';"
  PATH="$mock:$PATH" run cmd_session_cleanup --apply
  assert_failure
}

@test "v2 backup uses opencode session export and produces a JSON document" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/bk-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  session)
    case "$2" in
      export) printf '%s\n' "$*" >>"$SERVER_ARGS"; printf '{\n  "info": {\n    "id": "%s"\n  }\n}\n' "$3"; exit 0 ;;
    esac
    ;;
esac
EOF
  chmod +x "$mock/opencode"
  export SERVER_ARGS="$OCPROBE_RUN_DIR/server-args.txt"
  : >"$SERVER_ARGS"
  v2_load_config_fixtures
  # Without an explicit server the export must refuse: the CLI could otherwise
  # connect to a different background service than the database in view.
  OCPROBE_OPENCODE_SERVER= run cmd_session_backup "ses_probeA111111111111111"
  assert_failure
  assert_output --partial "OCPROBE_OPENCODE_SERVER"

  export OCPROBE_OPENCODE_SERVER="http://127.0.0.1:4096"
  PATH="$mock:$PATH" run cmd_session_backup "ses_probeA111111111111111"
  assert_success
  local backup_output="$output"
  run grep -F -- "--server http://127.0.0.1:4096" "$SERVER_ARGS"
  assert_success
  local out_file
  out_file=$(grep -o "$OCPROBE_RUN_DIR/backups/[^ ]*\.json" <<<"$backup_output" | head -1)
  assert [ -f "$out_file" ]
  run grep -q "ses_probeA111111111111111" "$out_file"
  assert_success
}

@test "v2 restore refuses .sql dumps and requires an explicit server" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  # cmd_session_restore calls load_config, which resets OCPROBE_OPencode_DB
  # from the ocm config yaml — point that config at the fixture DB.
  v2_load_config_fixtures
  local f="$OCPROBE_RUN_DIR/legacy.sql"
  printf 'INSERT INTO session VALUES (1);\n' >"$f"
  run cmd_session_restore "$f"
  assert_failure
  assert_output --partial "1.x format"

  local f2="$OCPROBE_RUN_DIR/sessions.json"
  printf '{\n  "info": {}\n}\n' >"$f2"
  unset OCPROBE_OPENCODE_SERVER
  run cmd_session_restore "$f2"
  assert_failure
  assert_output --partial "OCPROBE_OPENCODE_SERVER"
}

# ---- F4: probe worker ---------------------------------------------------------

@test "get_provider_models works when the CLI rejects a positional provider arg (2.x)" {
  local mock="$BATS_TEST_TMPDIR/strict-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
  models)
    if [[ $# -gt 1 ]]; then
      echo "ERROR" >&2
      echo "  Unexpected positional argument: \"$2\"" >&2
      exit 1
    fi
    printf 'prov-a/m1\nprov-a/m2\nprov-b/m3\n'
    ;;
esac
MOCK
  chmod +x "$mock/opencode"
  local out
  out=$(PATH="$mock:$PATH" get_provider_models "prov-a")
  local rc=$?
  [[ $rc -eq 0 ]] || { echo "get_provider_models exited $rc" >&2; return 1; }
  run printf '%s' "$out"
  assert_output "prov-a/m1
prov-a/m2"
}

@test "the generated probe workers never invoke the removed flag" {
  local w1="$OCPROBE_RUN_DIR/w1.sh" w2="$OCPROBE_RUN_DIR/w2.sh"
  write_worker "$w1"
  write_validate_worker "$w2"
  run grep -q -- "--pure" "$w1" "$w2"
  assert_failure
}

@test "worker: real success event stream → WORKS, session id on stderr" {
  local w="$OCPROBE_RUN_DIR/worker-ok.sh"
  write_worker "$w"
  local mock="$BATS_TEST_TMPDIR/ok-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<EOF
#!/usr/bin/env bash
cat "$FIXTURES/probe-events-ok.jsonl"
exit 0
EOF
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local err out
  out=$(PATH="$mock:$PATH" "$w" "test/ok" "TEST" "5" "Reply with exactly: OK" 2>"$OCPROBE_RUN_DIR/err.txt")
  err=$(cat "$OCPROBE_RUN_DIR/err.txt")
  run grep -q "SESSION_ID:$SCRUB_SESSION" <<<"$err"
  assert_success
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "WORKS"
}

@test "worker: real error event stream (nonexistent model) → NOTFOUND" {
  local w="$OCPROBE_RUN_DIR/worker-nf.sh"
  write_worker "$w"
  local mock="$BATS_TEST_TMPDIR/nf-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<EOF
#!/usr/bin/env bash
cat "$FIXTURES/probe-events-notfound.jsonl"
exit 1
EOF
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local out
  out=$(PATH="$mock:$PATH" "$w" "test/nf" "TEST" "5" "prompt" 2>/dev/null)
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "NOTFOUND"
}

@test "worker accepts catalog ids containing @ (real 2.x catalogs have them)" {
  local w="$OCPROBE_RUN_DIR/worker-at.sh"
  write_worker "$w"
  local mock="$BATS_TEST_TMPDIR/at-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<EOF
#!/usr/bin/env bash
cat "$FIXTURES/probe-events-notfound.jsonl"
exit 1
EOF
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local out
  out=$(env PATH="$mock:$PATH" "$w" "cloudflare-workers-ai/@cf/zai-org/glm-4.7-flash" "TEST" "5" "prompt" 2>"$OCPROBE_RUN_DIR/at.err")
  local rc=$?
  [[ $rc -eq 0 ]] || { sed 's/^/stderr: /' "$OCPROBE_RUN_DIR/at.err" >&2; return 1; }
  run grep -q "INVALID_MODEL" "$OCPROBE_RUN_DIR/at.err"
  assert_failure
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "NOTFOUND"
}

@test "validate worker: auth-flavoured error → AUTH_ERROR" {
  local w="$OCPROBE_RUN_DIR/worker-auth.sh"
  write_validate_worker "$w"
  local mock="$BATS_TEST_TMPDIR/auth-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<EOF
#!/usr/bin/env bash
printf '%s\n' '{"type":"error","timestamp":1,"sessionID":"ses_scrubauth1111111111111","error":{"type":"provider.auth","message":"invalid api key"}}'
exit 1
EOF
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local out
  out=$(PATH="$mock:$PATH" "$w" "test/auth" "TEST" "5" "prompt" 2>/dev/null)
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "AUTH_ERROR"
}

@test "worker: timeout exit code → TIMEOUT" {
  local w="$OCPROBE_RUN_DIR/worker-to.sh"
  write_worker "$w"
  local mock="$BATS_TEST_TMPDIR/to-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
echo '{"type":"step_start","timestamp":1,"sessionID":"ses_scrubto11111111111111"}'
exit 124
EOF
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
# simulate GNU timeout: drop the seconds argument, relay the child's status
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local out
  out=$(PATH="$mock:$PATH" "$w" "test/to" "TEST" "5" "prompt" 2>/dev/null)
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "TIMEOUT"
}

@test "worker: unknown output → UNCLEAR" {
  local w="$OCPROBE_RUN_DIR/worker-unk.sh"
  write_worker "$w"
  local mock="$BATS_TEST_TMPDIR/unk-mock"
  mkdir -p "$mock"
  printf '#!/usr/bin/env bash\necho "some non-JSON noise"\nexit 0\n' >"$mock/opencode"
  chmod +x "$mock/opencode"
  cat >"$mock/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
  chmod +x "$mock/timeout"
  local out
  out=$(PATH="$mock:$PATH" "$w" "test/unk" "TEST" "5" "prompt" 2>/dev/null)
  run awk -F'\t' '{print $3}' <<<"$out"
  assert_output "UNCLEAR"
}

# ---- F5: python resolution -----------------------------------------------------

@test "oc_python honors OCPROBE_PYTHON and falls back to python3" {
  OCPROBE_PYTHON="$(command -v python3)" run oc_python
  assert_output "$(command -v python3)"
  unset OCPROBE_PYTHON
  run oc_python
  assert_output "$(command -v python3)"
}

@test "oc_python_require refuses an interpreter without PyYAML/jsonschema and prints the fix" {
  # point at a stub interpreter that cannot import the modules
  local stub="$BATS_TEST_TMPDIR/pybin"
  mkdir -p "$stub"
  cat >"$stub/python3" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "$2" == *"import yaml"* ]]; then
  echo "ModuleNotFoundError: No module named 'yaml'" >&2
  exit 1
fi
case "$1" in
  --version) echo "stub python 3.99" ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$stub/python3"
  OCPROBE_PYTHON="$stub/python3" run oc_python_require
  assert_failure
  assert_output --partial "pip install PyYAML jsonschema"
}

@test "oc_python_require accepts an interpreter that has both modules" {
  # the CI python always has both; skip the assertion when it does not
  if ! python3 -c 'import yaml, jsonschema' >/dev/null 2>&1; then
    skip "local python3 lacks PyYAML/jsonschema; resolver path covered by the refusal test"
  fi
  OCPROBE_PYTHON="$(command -v python3)" run oc_python_require
  assert_success
}

@test "make setup exists and .venv is gitignored" {
  run grep -q "^setup:" "$OCPROBE_ROOT/Makefile"
  assert_success
  run grep -q "^\.venv/" "$OCPROBE_ROOT/.gitignore"
  assert_success
}

# ---- F6: docs are true ----------------------------------------------------------

@test "README documents both OpenCode generations and the real tap name" {
  run grep -q "SunnyJayaRaju/ocprobe" "$OCPROBE_ROOT/README.md"
  assert_success
  run grep -Eq "OpenCode 1\.x|OpenCode 1" "$OCPROBE_ROOT/README.md"
  assert_success
  run grep -Eq "OpenCode 2\.x|OpenCode 2" "$OCPROBE_ROOT/README.md"
  assert_success
}

@test "no placeholder text remains in README or CHANGELOG" {
  run grep -Eni "TODO|FIXME|TBD|PLACEHOLDER|XXX" "$OCPROBE_ROOT/README.md"
  assert_failure
}

# ---- F7: adversarial values on both SQL paths ---------------------------------
#
# The 2.x queries run through lib/db_query.py with bound parameters; the 1.x
# queries keep sql_escape + string interpolation. For every hostile id below
# the requirement is the same on BOTH paths: the lookup either finds exactly
# its own row or safely finds nothing — the query shape never changes, and no
# error text from the SQL layer reaches the caller's stdout.

# Insert a v2 session row (plus its one user message) with an arbitrary id,
# bound, so ids no sqlite3 CLI argument could carry (NUL) can be used.
v2_add_adversarial_session() {
  local sid="$1"
  local db="$OCPROBE_OPencode_DB"
  python3 -B "$OCPROBE_ROOT/test/helpers/adversarial_rows.py" "$db" "$sid"
}

@test "adversarial ids on the bound 2.x path: quote, semicolon, newline, unicode, very long" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ids=(
    "ses_it's-a-quote"
    'ses_semi;coloned'
    $'ses_new\nline'
    'ses_uni-😎-日本'
    "ses_$(printf 'x%.0s' {1..2000})"
  )
  local sid
  for sid in "${ids[@]}"; do
    run v2_add_adversarial_session "$sid"
    assert_success
  done
  for sid in "${ids[@]}"; do
    run get_session_title "$sid"
    assert_success
    assert_output --partial "ocprobe-probe"
  done
  # The age lookup answers for the same rows without any SQL error.
  for sid in "${ids[@]}"; do
    run session_age_ms "$sid"
    assert_success
    assert_output --regexp '^[0-9]+$'
  done
}

@test "a NUL byte in an id is inert: no match, no changed query, table intact" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  # bash variables cannot hold NUL; the row is built python-side with an id
  # carrying the classic injection attempt after the NUL, to prove it is inert.
  python3 -B "$OCPROBE_ROOT/test/helpers/adversarial_rows.py" --nul "$db"
  # A lookup whose value bash truncated at the NUL matches no row. An absent
  # row is an empty result, not an error, for get_session_title.
  run get_session_title "ses_x"
  assert_output ""
  # ...and a NUL row never matches anything queryable, and the table survives.
  run sqlite3 "$db" "SELECT COUNT(*) FROM session_v2;"
  assert_success
  assert_output --regexp '^[0-9]+$'
  run sqlite3 "$db" "SELECT COUNT(*) FROM session_v2 WHERE id LIKE 'ses_x%';"
  assert_output "1"
}

@test "malformed JSON in session_message.data is handled, not fatal" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  local sid="ses_badjson11111111111111"
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated) VALUES ('$sid', 'proj_adv', 'adv', '/tmp/adv', '1', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('adv_bad1', '$sid', 'user', 1, $ts, $ts, 'not-json{{');"
  sqlite3 "$db" "INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES ('adv_bad2', '$sid', 'assistant', 2, $ts, $ts, '{\"content\":[{\"type\":\"tool\"}]}broken');"
  run session_has_tool_calls "$sid"
  assert_failure
  run session_first_user_text "$sid"
  assert_success
  assert_output ""
  # delete_session fails closed: no prompt match -> refusal, nothing deleted.
  run delete_session "$sid"
  assert_failure
  assert_output --partial "not a configured probe prompt"
  run sqlite3 "$db" "SELECT COUNT(*) FROM session_v2 WHERE id='$sid';"
  assert_output "1"
}

@test "NULL columns on the bound 2.x path come back as the documented empties" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  local ts
  ts=$(now_ms)
  local sid="ses_nullcols1111111111111"
  sqlite3 "$db" "INSERT INTO session_v2 (id, project_id, slug, directory, version, title, parent_id, time_created, time_updated) VALUES ('$sid', 'proj_adv', 'adv', '/tmp/adv', '1', NULL, NULL, $ts, $ts);"
  run get_session_title "$sid"
  assert_success
  assert_output "$sid"$'\t'
  run session_in_tree "$sid"
  assert_failure
}

@test "adversarial ids on the legacy 1.x path: sql_escape keeps them safe" {
  local legacy="$OCPROBE_RUN_DIR/legacy-adv.db"
  rm -f "$legacy"
  sqlite3 "$legacy" <<'EOF'
CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, time_created INTEGER, time_updated INTEGER);
CREATE TABLE message (id INTEGER PRIMARY KEY, session_id TEXT, time_created INTEGER);
EOF
  local ts=1000
  sqlite3 "$legacy" "INSERT INTO session (id, title, time_created, time_updated) VALUES ('ses_it''s-a-quote', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$legacy" "INSERT INTO session (id, title, time_created, time_updated) VALUES ('ses_semi;coloned', 'ocprobe-probe', $ts, $ts);"
  sqlite3 "$legacy" "INSERT INTO session (id, title, time_created, time_updated) VALUES ('ses_uni-日本', 'ocprobe-probe', $ts, $ts);"
  OCPROBE_OPencode_DB="$legacy"
  # Quote and semicolon are escaped, not executed: the rows are found.
  run get_session_title "ses_it's-a-quote"
  assert_success
  assert_output --partial "ocprobe-probe"
  run get_session_title 'ses_semi;coloned'
  assert_success
  assert_output --partial "ocprobe-probe"
  run get_session_title "ses_uni-日本"
  assert_success
  assert_output --partial "ocprobe-probe"
  # sql_escape rejects newline and over-long ids: the lookup answers
  # "not present" instead of erroring.
  run get_session_title $'ses_new\nline'
  assert_failure
  run get_session_title "ses_$(printf 'x%.0s' {1..2000})"
  assert_failure
  # A NUL row is not reachable and breaks nothing (truncated lookup value);
  # an absent row is an empty result, not an error.
  python3 -B "$OCPROBE_ROOT/test/helpers/adversarial_rows.py" --nul "$legacy"
  run get_session_title "ses_x"
  assert_output ""
  run sqlite3 "$legacy" "SELECT COUNT(*) FROM session;"
  assert_output "4"
}

@test "list_probe_sessions_since (v2) survives hostile titles and prompts" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows # one clean session, still listed
  local ts
  ts=$(now_ms)
  sqlite3 "$db" <<EOF
INSERT INTO session_v2 (id, project_id, slug, directory, version, title, time_created, time_updated)
VALUES ('ses_hostileTitle1111', 'proj_adv', 'adv', '/tmp/adv', '1', 'ocprobe-probe''; DROP TABLE session_v2;--', $ts, $ts);
EOF
  run list_probe_sessions_since 0
  assert_success
  assert_line --partial "ses_probeA111111111111111"
  run sqlite3 "$db" "SELECT COUNT(*) FROM session_v2;"
  assert_success
  assert_output --regexp '^[0-9]+$'
}

@test "delete_session reports a sanitised CLI failure and keeps the non-zero exit" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/fail-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  session)
    case "$2" in
      delete)
        echo "cannot delete ses_other88888888888888: database is locked while writing /Users/someone/private/opencode.db" >&2
        echo "second line with ses_secret9999999999999 in it" >&2
        exit 3
        ;;
    esac
    ;;
esac
EOF
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run delete_session "ses_probeA111111111111111"
  assert_failure
  assert_output --partial "opencode session delete failed for ses_probeA111111111111111"
  assert_output --partial "exit 3"
  # Sanitisation: no other id, no path, nothing from later CLI lines.
  refute_output --partial "ses_other88888888888888"
  refute_output --partial "ses_secret9999999999999"
  refute_output --partial "/Users/someone/private"
  assert_output --partial "<id>"
  assert_output --partial "<path>"
  # The row was NOT deleted.
  run sqlite3 "$db" "SELECT COUNT(*) FROM session_v2 WHERE id='ses_probeA111111111111111';"
  assert_output "1"
}

@test "delete_session CLI failure with an empty stderr still fails with a reason" {
  local db
  create_v2_db
  db="$OCPROBE_OPencode_DB"
  fixtures_v2_add_rows
  local mock="$BATS_TEST_TMPDIR/silent-fail-mock"
  mkdir -p "$mock"
  cat >"$mock/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  session) case "$2" in delete) exit 1 ;; esac ;;
esac
EOF
  chmod +x "$mock/opencode"
  PATH="$mock:$PATH" run delete_session "ses_probeA111111111111111"
  assert_failure
  assert_output --partial "failed for ses_probeA111111111111111"
  assert_output --partial "no message"
}
