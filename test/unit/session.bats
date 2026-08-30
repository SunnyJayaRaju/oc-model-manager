#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/session.bats — Session management tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  # Use real sqlite3 directly, no mock needed for session tests
  create_test_db
}

teardown() {
  rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
}

@test "is_probe_session returns true for valid probe session" {
  run is_probe_session "ses_probe1"
  assert_success
}

@test "is_probe_session returns false for old session" {
  run is_probe_session "ses_probe2"
  assert_failure
}

@test "is_probe_session returns false for real session" {
  run is_probe_session "ses_real"
  assert_failure
}

@test "batch_get_old_sessions finds old sessions" {
  local -a sessions=("ses_probe1" "ses_probe2" "ses_real")
  local result
  result=$(batch_get_old_sessions sessions 1)
  printf "DEBUG: result='%s'\n" "$result" >&2
  printf "DEBUG: result hex=%s\n" "$(printf "%s" "$result" | xxd)" >&2
  
  # Use case instead of grep to avoid any grep issues
  case "$result" in
    *ses_probe2*) local ec=0 ;;
    *) local ec=1 ;;
  esac
  run test $ec -eq 0
  assert_success
  
  case "$result" in
    *ses_probe1*) local ec=0 ;;
    *) local ec=1 ;;
  esac
  run test $ec -eq 1
  assert_success
  
  case "$result" in
    *ses_real*) local ec=0 ;;
    *) local ec=1 ;;
  esac
  run test $ec -eq 1
  assert_success
}

@test "batch_get_fresh_probe_sessions finds fresh sessions with messages" {
  local -a sessions=("ses_probe1" "ses_probe2" "ses_real")
  local result
  result=$(batch_get_fresh_probe_sessions sessions 1)
  case "$result" in
    *ses_probe1*) local ec=0 ;;
    *) local ec=1 ;;
  esac
  run test $ec -eq 0
  assert_success
  case "$result" in
    *ses_probe2*) local ec=0 ;;
    *) local ec=1 ;;
  esac
  run test $ec -eq 1
  assert_success
}

@test "session_age_ms returns age in milliseconds" {
  local age
  age=$(session_age_ms "ses_probe2")
  case "$age" in
    ''|*[!0-9]*) local ec=1 ;;
    *) local ec=0 ;;
  esac
  run test $ec -eq 0
  assert_success
  run test "$age" -gt 7000000
  assert_success
}

@test "cmd_session_backup creates SQL file" {
  create_test_db
  local backup_dir="$OCPROBE_STATE_DIR/backups"
  OCPROBE_SESSION_BACKUP_DIR="$backup_dir"
  # Create test config pointing to test database
  local test_config="$BATS_TEST_TMPDIR/test-session-backup-config.yaml"
  cat > "$test_config" <<EOF
version: 1
opencode:
  config_path: "$OCPROBE_STATE_DIR/opencode.json"
  db_path: "$OCPROBE_OPencode_DB"
probe:
  timeout_new: 5
  timeout_whitelist: 5
  max_parallel: 2
catalog:
  cache_ttl_hours: 1
scheduler:
  enabled: false
alerts:
  webhook_url: ""
  desktop_notifications: false
session:
  backup_dir: "$backup_dir"
retention:
  history_limit: 100
  alert_limit: 100
safety:
  mass_removal_threshold_pct: 50
logging:
  level: debug
  format: text
EOF
  echo '{"provider":{}}' > "$OCPROBE_STATE_DIR/opencode.json"
  OCPROBE_CONFIG_OVERRIDE="$test_config"
  run cmd_session_backup "ses_probe1"
  assert_success
  assert_output --partial "backed up"
  assert [ -f "$backup_dir/ses_probe1-"*".sql" ]
}

@test "backup file contains INSERT OR REPLACE" {
  create_test_db
  local backup_dir="$OCPROBE_STATE_DIR/backups"
  OCPROBE_SESSION_BACKUP_DIR="$backup_dir"
  local test_config="$BATS_TEST_TMPDIR/test-session-backup-config.yaml"
  cat > "$test_config" <<EOF
version: 1
opencode:
  config_path: "$OCPROBE_STATE_DIR/opencode.json"
  db_path: "$OCPROBE_OPencode_DB"
probe:
  timeout_new: 5
  timeout_whitelist: 5
  max_parallel: 2
catalog:
  cache_ttl_hours: 1
scheduler:
  enabled: false
alerts:
  webhook_url: ""
  desktop_notifications: false
session:
  backup_dir: "$backup_dir"
retention:
  history_limit: 100
  alert_limit: 100
safety:
  mass_removal_threshold_pct: 50
logging:
  level: debug
  format: text
EOF
  echo '{"provider":{}}' > "$OCPROBE_STATE_DIR/opencode.json"
  OCPROBE_CONFIG_OVERRIDE="$test_config"
  cmd_session_backup "ses_probe1" >/dev/null
  local backup_file
  backup_file=$(ls "$backup_dir"/ses_probe1-*.sql | head -1)
  run grep "INSERT OR REPLACE INTO" "$backup_file"
  assert_success
}