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
  rm -f /tmp/ocprobe-test-config-*.yaml
}

@test "CONFIG_SCHEMA is valid YAML" {
  run python3 -c "import yaml, sys; yaml.safe_load(sys.argv[1])" "$CONFIG_SCHEMA"
  assert_success
}

@test "create_default_config creates valid YAML" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run python3 -c "import yaml, sys; yaml.safe_load(open(sys.argv[1]))" "$tmpfile"
  assert_success
  [[ -f "$tmpfile" ]]
}

@test "default config has required sections" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
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
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run validate_config "$tmpfile"
  assert_success
  assert_output --partial "VALID"
}

@test "validate_config rejects invalid config" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  echo "invalid: yaml: [" > "$tmpfile"
  run validate_config "$tmpfile"
  assert_failure
}

@test "validate_config rejects wrong version" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
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
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  run parse_config_yaml "$tmpfile"
  assert_success
  assert_output --partial "OCPROBE_PROBE_TIMEOUT_NEW="
  assert_output --partial "OCPROBE_MAX_PARALLEL="
  assert_output --partial "OCPROBE_PROBE_PROMPT="
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
@test "cmd_config show prints the config file when it exists (regression: empty OCPROBE_CONFIG_FILE)" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  printf 'version: 1\n' > "$tmpfile"
  OCPROBE_CONFIG_OVERRIDE="$tmpfile"
  OCPROBE_CONFIG_FILE=""
  run cmd_config show
  assert_success
  assert_output --partial "version: 1"
}

@test "cmd_config show reports a missing config file without creating one" {
  OCPROBE_CONFIG_OVERRIDE="$HOME/.config/ocprobe/does-not-exist-$RANDOM.yaml"
  OCPROBE_CONFIG_FILE=""
  run cmd_config show
  assert_success
  assert_output "No config file found"
  [[ ! -f "$OCPROBE_CONFIG_OVERRIDE" ]]
}

@test "cmd_config path prints a non-empty resolved path" {
  OCPROBE_CONFIG_OVERRIDE=""
  OCPROBE_CONFIG_FILE=""
  run cmd_config path
  assert_success
  [[ -n "$output" ]]
  assert_output --partial "config.yaml"
}

@test "cmd_config validate says a valid config is valid" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  create_default_config "$tmpfile"
  OCPROBE_CONFIG_OVERRIDE="$tmpfile"
  OCPROBE_CONFIG_FILE=""
  run cmd_config validate
  assert_success
  assert_output --partial "Config is valid"
}

@test "config path resolves through the CLI without load_config (regression)" {
  local tmpfile
  tmpfile=$(mktemp /tmp/ocprobe-test-config-XXXXXX.yaml)
  printf 'version: 1\n' > "$tmpfile"
  run env -u OCPROBE_CONFIG_FILE "$OCPROBE_ROOT/bin/ocprobe" --config "$tmpfile" config path
  assert_success
  assert_output "$tmpfile"
}
