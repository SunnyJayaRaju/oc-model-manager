#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/models.bats — Model catalog tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
  mock_opencode
}

teardown() {
  rm -rf "$OCM_STATE_DIR" "$OCM_RUN_DIR"
}

# Mock opencode for testing
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
kilo/~openai/gpt-4
MODELS
    ;;
  run)
    # Simulate probe response
    if [[ "$*" == *"gpt-4"* ]]; then
      echo "OK"
      exit 0
    elif [[ "$*" == *"gpt-3.5"* ]]; then
      echo "Error: model not found"
      exit 1
    elif [[ "$*" == *"claude"* ]]; then
      echo "No payment method"
      exit 1
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
esac
EOF
  chmod +x "$mock_dir/opencode"
  export PATH="$mock_dir:$PATH"
}

@test "list_whitelist extracts models from config" {
  local tmpconfig
  tmpconfig=$(mktemp "${BATS_TEST_TMPDIR}/ocm-test-config-XXXXXX.json")
  cat > "$tmpconfig" <<'EOF'
{
  "provider": {
    "openai": { "whitelist": ["gpt-4", "gpt-3.5-turbo"] },
    "anthropic": { "whitelist": ["claude-3"] }
  }
}
EOF
  OCM_OPencode_CONFIG="$tmpconfig"
  run list_whitelist
  assert_success
  assert_output --partial "openai/gpt-3.5-turbo"
  assert_output --partial "openai/gpt-4"
  assert_output --partial "anthropic/claude-3"
}

@test "write_worker creates executable script" {
  local worker_file="$OCM_RUN_DIR/worker.sh"
  write_worker "$worker_file"
  assert [ -x "$worker_file" ]
  assert [ -f "$worker_file" ]
}

@test "worker validates model name" {
  local worker_file="$OCM_RUN_DIR/worker.sh"
  write_worker "$worker_file"
  run "$worker_file" "invalid@model" "TEST" "10" "prompt"
  assert_failure
  assert_output --partial "INVALID_MODEL"
}

@test "worker validates timeout" {
  local worker_file="$OCM_RUN_DIR/worker.sh"
  write_worker "$worker_file"
  run "$worker_file" "openai/gpt-4" "TEST" "abc" "prompt"
  assert_failure
  assert_output --partial "INVALID_TIMEOUT"
}

@test "compute_diff finds new and gone models" {
  mock_opencode
  export OCM_OPencode_CONFIG=$(mktemp "${BATS_TEST_TMPDIR}/ocm-test-config-XXXXXX.json")
  cat > "$OCM_OPencode_CONFIG" <<'EOF'
{
  "provider": {
    "openai": { "whitelist": ["gpt-4"] }
  }
}
EOF
  fetch_catalog
  compute_diff
  assert [ -f "$OCM_RUN_DIR/new.txt" ]
  assert [ -f "$OCM_RUN_DIR/gone.txt" ]
  # gpt-3.5-turbo, claude-3, gemini-pro, kilo/~openai/gpt-4 should be NEW
  run grep -c "openai/gpt-3.5-turbo" "$OCM_RUN_DIR/new.txt"
  assert_success
  assert_output "1"
}

@test "graveyard filtering excludes recently removed models" {
  mock_opencode
  export OCM_OPencode_CONFIG=$(mktemp "${BATS_TEST_TMPDIR}/ocm-test-config-XXXXXX.json")
  cat > "$OCM_OPencode_CONFIG" <<'EOF'
{"provider": {"openai": {"whitelist": ["gpt-4"]}}}
EOF
  # Add to graveyard
  mkdir -p "$OCM_STATE_DIR"
  echo "$(ms)	openai/gpt-3.5-turbo" >> "$OCM_STATE_DIR/graveyard.jsonl"
  fetch_catalog
  compute_diff
  # gpt-3.5-turbo should be in cooling.txt, not new.txt
  run grep "openai/gpt-3.5-turbo" "$OCM_RUN_DIR/cooling.txt"
  assert_success
  run grep "openai/gpt-3.5-turbo" "$OCM_RUN_DIR/new.txt"
  assert_failure
}

@test "is_confirmed_dead returns true for EOL" {
  declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
  run is_confirmed_dead "openai/gpt-4" "EOL"
  assert_success
}

@test "is_confirmed_dead returns true for NOTFOUND" {
  declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
  run is_confirmed_dead "openai/gpt-4" "NOTFOUND"
  assert_success
}

@test "is_confirmed_dead returns false for single BROKEN" {
  declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
  MODEL_FAIL_COUNT["openai_gpt-4"]=1
  MODEL_LAST_STATUS["openai_gpt-4"]="WORKS"
  run is_confirmed_dead "openai/gpt-4" "BROKEN"
  assert_failure
}

@test "is_confirmed_dead returns true for 2 consecutive failures" {
  declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
  MODEL_FAIL_COUNT["openai_gpt-4"]=2
  MODEL_LAST_STATUS["openai_gpt-4"]="BROKEN"
  run is_confirmed_dead "openai/gpt-4" "TIMEOUT"
  assert_success
}