#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/integration/full_cycle.bats — End-to-end integration tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  mock_opencode
  mock_sqlite3
}

teardown() {
  rm -rf "$OCM_STATE_DIR"
}

# Mock opencode for integration tests
mock_opencode() {
  local mock_dir
  mock_dir=$(mktemp -d /tmp/ocm-mock-XXXXXX)
  cat > "$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
openai/gpt-4
openai/gpt-3.5-turbo
anthropic/claude-3
google/gemini-pro
MODELS
    ;;
  run)
    # Simulate probe: gpt-4 works, gpt-3.5 fails, claude paywalled, gemini works
    if [[ "$*" == *"gpt-4"* ]]; then
      sleep 0.1
      echo "OK"
      exit 0
    elif [[ "$*" == *"gpt-3.5"* ]]; then
      echo "Error: model not found"
      exit 1
    elif [[ "$*" == *"claude"* ]]; then
      echo "No payment method"
      exit 1
    elif [[ "$*" == *"gemini"* ]]; then
      sleep 0.1
      echo "OK"
      exit 0
    else
      echo "OK"
      exit 0
    fi
    ;;
  session)
    case "$2" in
      list)
        echo "ses_abc123  ocmm-probe-test  2024-01-01"
        echo "ses_def456  Real Session  2024-01-01"
        ;;
      delete)
        exit 0
        ;;
    esac
    ;;
  --version)
    echo "opencode 0.1.0-test"
    ;;
esac
EOF
  chmod +x "$mock_dir/opencode"
  export PATH="$mock_dir:$PATH"
}

# Mock sqlite3 for test DB
mock_sqlite3() {
  local mock_dir
  mock_dir=$(mktemp -d /tmp/ocm-mock-sqlite-XXXXXX)
  cat > "$mock_dir/sqlite3" <<'EOF'
#!/usr/bin/env bash
# Simple mock for sqlite3 - just handle our specific queries
if [[ "$*" == *"PRAGMA integrity_check"* ]]; then
  echo "ok"
elif [[ "$*" == *"FROM session WHERE id="* ]]; then
  # Session queries - return empty for safety
  exit 0
elif [[ "$*" == *"FROM message WHERE session_id="* ]]; then
  exit 0
elif [[ "$*" == *"FROM part WHERE message_id="* ]]; then
  exit 0
else
  # Default: use real sqlite3 if available, otherwise exit 0
  command sqlite3 "$@" 2>/dev/null || exit 0
fi
EOF
  chmod +x "$mock_dir/sqlite3"
  export PATH="$mock_dir:$PATH"
}

@test "cmd_check runs without errors (dry-run)" {
  mock_opencode
  mock_sqlite3
  source "$OCM_ROOT/lib/core.sh"
  source "$OCM_ROOT/lib/config.sh"
  source "$OCM_ROOT/lib/logging.sh"
  source "$OCM_ROOT/lib/locking.sh"
  source "$OCM_ROOT/lib/db.sh"
  source "$OCM_ROOT/lib/models.sh"

  load_config
  run cmd_check --quick
  assert_success
}

@test "cmd_status shows whitelist and history" {
  mock_opencode
  mock_sqlite3
  source "$OCM_ROOT/lib/core.sh"
  source "$OCM_ROOT/lib/config.sh"
  source "$OCM_ROOT/lib/logging.sh"
  source "$OCM_ROOT/lib/locking.sh"
  source "$OCM_ROOT/lib/db.sh"
  source "$OCM_ROOT/lib/models.sh"

  load_config
  run cmd_status
  assert_success
  assert_output --partial "whitelist"
}

@test "cmd_alerts shows empty when no alerts" {
  source "$OCM_ROOT/lib/core.sh"
  source "$OCM_ROOT/lib/config.sh"
  source "$OCM_ROOT/lib/logging.sh"
  source "$OCM_ROOT/lib/locking.sh"
  source "$OCM_ROOT/lib/db.sh"

  load_config
  run cmd_alerts
  assert_success
  assert_output --partial "no alerts"
}

@test "cmd_session_list works" {
  mock_sqlite3
  source "$OCM_ROOT/lib/core.sh"
  source "$OCM_ROOT/lib/config.sh"
  source "$OCM_ROOT/lib/logging.sh"
  source "$OCM_ROOT/lib/locking.sh"
  source "$OCM_ROOT/lib/db.sh"
  source "$OCM_ROOT/lib/session.sh"

  load_config
  run cmd_session_list
  assert_success
}

@test "cmd_doctor runs health checks" {
  mock_opencode
  mock_sqlite3
  source "$OCM_ROOT/lib/core.sh"
  source "$OCM_ROOT/lib/config.sh"
  source "$OCM_ROOT/lib/logging.sh"
  source "$OCM_ROOT/lib/locking.sh"
  source "$OCM_ROOT/lib/db.sh"
  source "$OCM_ROOT/lib/doctor.sh"

  # Create test database (sets OCM_OPencode_DB)
  create_test_db

  # Create test config pointing to test paths
  local test_config="$BATS_TEST_TMPDIR/test-doctor-config.yaml"
  local test_db_path="$OCM_OPencode_DB"
  local test_config_path="$OCM_STATE_DIR/opencode.json"
  cat > "$test_config" <<EOF
version: 1
opencode:
  config_path: "$test_config_path"
  db_path: "$test_db_path"
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
  backup_dir: "~/.local/share/opencode/session-backups"
retention:
  history_limit: 100
  alert_limit: 100
safety:
  mass_removal_threshold_pct: 50
logging:
  level: debug
  format: text
EOF
  # Create dummy opencode config
  echo '{"provider":{}}' > "$OCM_STATE_DIR/opencode.json"
  OCM_CONFIG_OVERRIDE="$test_config"
  # Don't call load_config here - let cmd_doctor do it
  run cmd_doctor
  assert_success
  assert_output --partial "opencode: OK"
}