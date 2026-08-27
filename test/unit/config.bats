#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/config.bats — Configuration tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
}

teardown() {
  # Clean up any test config files
  rm -f /tmp/ocm-test-config-*.yaml
}

@test "CONFIG_SCHEMA is valid YAML" {
  run python3 -c "import yaml, sys; yaml.safe_load(sys.argv[1])" "$CONFIG_SCHEMA"
  assert_success
}

@test "create_default_config creates valid YAML" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$tmpfile"
  assert_success
  [[ -f "$tmpfile" ]]
}

@test "default config has required sections" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f)
assert c['version'] == 1
assert 'opencode' in c
assert 'probe' in c
assert 'catalog' in c
assert 'scheduler' in c
assert 'alerts' in c
assert 'session' in c
assert 'retention' in c
assert 'safety' in c
assert 'logging' in c
" "$tmpfile"
  assert_success
}

@test "validate_config accepts valid config" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run validate_config "$tmpfile"
  assert_success
  assert_output --partial "VALID"
}

@test "validate_config rejects invalid config" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  echo "invalid: yaml: [" > "$tmpfile"
  run validate_config "$tmpfile"
  assert_failure
}

@test "validate_config rejects wrong version" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  cat > "$tmpfile" <<'EOF'
version: 2
opencode: {}
probe: {}
catalog: {}
scheduler: {}
alerts: {}
session: {}
retention: {}
safety: {}
logging: {}
EOF
  run validate_config "$tmpfile"
  assert_failure
}

@test "parse_config_yaml outputs bash assignments" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocm-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run parse_config_yaml "$tmpfile"
  assert_success
  assert_output --partial "OCM_PROBE_TIMEOUT_NEW="
  assert_output --partial "OCM_MAX_PARALLEL="
  assert_output --partial "OCM_PROBE_PROMPT="
}

@test "get_env_or_config prefers env var" {
  export TEST_ENV_VAR="from_env"
  local result
  result=$(get_env_or_config "TEST_ENV_VAR" "TEST_CONFIG_VAR" "default")
  assert_equal "$result" "from_env"
}

@test "get_env_or_config falls back to config var" {
  unset TEST_ENV_VAR
  TEST_CONFIG_VAR="from_config"
  local result
  result=$(get_env_or_config "TEST_ENV_VAR" "TEST_CONFIG_VAR" "default")
  assert_equal "$result" "from_config"
}

@test "get_env_or_config falls back to default" {
  unset TEST_ENV_VAR TEST_CONFIG_VAR
  local result
  result=$(get_env_or_config "TEST_ENV_VAR" "TEST_CONFIG_VAR" "default")
  assert_equal "$result" "default"
}