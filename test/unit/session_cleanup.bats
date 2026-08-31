#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/session_cleanup.bats — Session cleanup tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  create_test_db
  # Mock opencode to simulate JSON output with sessionID
  mock_opencode_json
  
  # Reset tracking file
  : > "/tmp/ocprobe-test-delete-track"
}

teardown() {
  rm -rf "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
  rm -f "/tmp/ocprobe-test-delete-track"
}

# Mock opencode that outputs JSON with sessionID
mock_opencode_json() {
  local mock_dir
  mock_dir=$(mktemp -d /tmp/ocprobe-mock-XXXXXX)
  cat > "$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
openai/gpt-4
openai/gpt-3.5-turbo
anthropic/claude-3
google/gemini-pro
kilo/~openai/gpt-4
MODELS
    ;;
  run)
    # Check if --format json is in args
    if [[ "$*" == *"--format json"* ]]; then
      # Output JSON with sessionID - include OK for string matching fallback
      echo '{"type":"status","timestamp":1234567890,"sessionID":"ses_test123","status":"WORKS","message":"OK"}'
      exit 0
    else
      # Legacy output for backward compat
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
    fi
    ;;
  session)
    case "$2" in
      list)
        echo "ses_abc123  ocmm-probe-test  2024-01-01"
        echo "ses_def456  Real Session  2024-01-01"
        ;;
      delete)
        # Track the deleted session ID
        echo "$3" >> "/tmp/ocprobe-test-delete-track"
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

  # Also mock timeout command
  cat > "$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
# Simple timeout mock that just runs the command directly (no actual timeout)
# Usage: timeout SECONDS COMMAND [ARGS...]
if [[ $# -lt 2 ]]; then
  echo "Usage: timeout SECONDS COMMAND [ARGS...]" >&2
  exit 1
fi
shift
exec "$@"
EOF
  chmod +x "$mock_dir/timeout"
  chmod +x "$mock_dir/opencode"
  export PATH="$mock_dir:$PATH"
}

# Mock opencode that outputs JSON WITHOUT sessionID (malformed)
mock_opencode_json_no_sessionid() {
  local mock_dir
  mock_dir=$(mktemp -d /tmp/ocprobe-mock-XXXXXX)
  cat > "$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
openai/gpt-4
MODELS
    ;;
  run)
    # Output JSON WITHOUT sessionID but with OK for string matching
    echo '{"type":"status","timestamp":1234567890,"status":"WORKS","message":"OK"}'
    exit 0
    ;;
  session)
    case "$2" in
      list)
        echo "ses_abc123  ocmm-probe-test  2024-01-01"
        ;;
      delete)
        # Track the deleted session ID
        echo "$3" >> "/tmp/ocprobe-test-delete-track"
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
  cat > "$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ $# -lt 2 ]]; then
  echo "Usage: timeout SECONDS COMMAND [ARGS...]" >&2
  exit 1
fi
shift
exec "$@"
EOF
  chmod +x "$mock_dir/timeout"
  chmod +x "$mock_dir/opencode"
  export PATH="$mock_dir:$PATH"
}

# Mock opencode that outputs MALFORMED JSON
mock_opencode_json_malformed() {
  local mock_dir
  mock_dir=$(mktemp -d /tmp/ocprobe-mock-XXXXXX)
  cat > "$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
openai/gpt-4
MODELS
    ;;
  run)
    # Output MALFORMED JSON (no sessionID, no OK)
    echo 'not json at all'
    exit 0
    ;;
  session)
    case "$2" in
      list)
        echo "ses_abc123  ocmm-probe-test  2024-01-01"
        ;;
      delete)
        # Track the deleted session ID
        echo "$3" >> "/tmp/ocprobe-test-delete-track"
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
  cat > "$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
if [[ $# -lt 2 ]]; then
  echo "Usage: timeout SECONDS COMMAND [ARGS...]" >&2
  exit 1
fi
shift
exec "$@"
EOF
  chmod +x "$mock_dir/timeout"
  chmod +x "$mock_dir/opencode"
  export PATH="$mock_dir:$PATH"
}

@test "extracts session id from worker JSON output" {
  # Write a worker script and run it, capture stderr
  local worker="$OCPROBE_RUN_DIR/.worker-test"
  write_worker "$worker"
  
  # Run worker and capture stderr
  local err
  err=$("$worker" "openai/gpt-4" "TEST" 5 "test prompt" 2>&1 >/dev/null)
  
  # Extract session_id from stderr
  local session_id
  session_id=$(printf '%s' "$err" | grep '^SESSION_ID:' | head -1 | sed 's/^SESSION_ID://')
  
  assert_equal "$session_id" "ses_test123"
  rm -f "$worker"
}

@test "cmd_probe logs warning and skips deletion when sessionID missing from JSON" {
  # Use mock without sessionID
  mock_opencode_json_no_sessionid
  
  # Reset tracking file
  : > "/tmp/ocprobe-test-delete-track"
  
  # Run cmd_probe and capture stderr
  run cmd_probe "openai/gpt-4" 2>&1
  
  # Verify warning was logged (in stderr)
  assert_output --partial "could not capture session ID for this probe, skipping automatic cleanup"
  
  # Verify delete_session was NOT called
  local delete_count
  delete_count=$(wc -l < "/tmp/ocprobe-test-delete-track" | tr -d ' ')
  assert_equal "$delete_count" "0"
}

@test "cmd_probe logs warning and skips deletion when sessionID malformed" {
  # Use mock with malformed JSON
  mock_opencode_json_malformed
  
  # Reset tracking file
  : > "/tmp/ocprobe-test-delete-track"
  
  # Run cmd_probe and capture stderr
  run cmd_probe "openai/gpt-4" 2>&1
  
  # Verify warning was logged (in stderr)
  assert_output --partial "could not capture session ID for this probe, skipping automatic cleanup"
  
  # Verify delete_session was NOT called
  local delete_count
  delete_count=$(wc -l < "/tmp/ocprobe-test-delete-track" | tr -d ' ')
  assert_equal "$delete_count" "0"
}

@test "cmd_probe deletes session when valid sessionID captured" {
  # Use mock with valid sessionID
  mock_opencode_json
  
  # Reset tracking file
  : > "/tmp/ocprobe-test-delete-track"
  
  # Debug: check what worker outputs
  local worker="$OCPROBE_RUN_DIR/.worker-test"
  write_worker "$worker"
  local err
  err=$("$worker" "openai/gpt-4" "TEST" 5 "test prompt" 2>&1 >/dev/null)
  echo "DEBUG: worker stderr='$err'" >&2
  local session_id
  session_id=$(printf '%s' "$err" | grep '^SESSION_ID:' | head -1 | sed 's/^SESSION_ID://')
  echo "DEBUG: extracted session_id='$session_id'" >&2
  rm -f "$worker"
  
  # Run cmd_probe and capture output
  run cmd_probe "openai/gpt-4" 2>&1
  
  echo "DEBUG: cmd_probe output='$output'" >&2
  echo "DEBUG: tracking file content='$(cat "/tmp/ocprobe-test-delete-track" 2>/dev/null || echo "none")'" >&2
  
  # Verify delete_session was called with correct session ID
  local delete_count
  delete_count=$(wc -l < "/tmp/ocprobe-test-delete-track" | tr -d ' ')
  assert_equal "$delete_count" "1"
  
  local deleted_sid
  deleted_sid=$(cat "/tmp/ocprobe-test-delete-track")
  assert_equal "$deleted_sid" "ses_test123"
}