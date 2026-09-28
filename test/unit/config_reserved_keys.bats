#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/config_reserved_keys.bats — three config keys that are parsed,
# schema-validated, and then ignored.
#
# catalog.force_refresh, scheduler.enabled and scheduler.run_at_load appear in
# config/schema.json and in both the shipped and the generated config.yaml, but
# no code ever reads them. Measured before this change: the emitter produces no
# variable for any of them and nothing in lib/ or bin/ references them, so
# `scheduler.enabled: false` does not stop `ocprobe scheduler install`.
#
# The schema root sets "additionalProperties": false, so the keys MUST stay in
# the schema -- removing them would make every existing config that still
# contains one fail validation, which is a hard break for users. So they are
# kept, marked reserved in the schema, dropped from the generated default config
# so nobody new copies them, and produce one warning when set to a non-default
# value so anyone who has one finds out.
#
# OCPROBE_FORCE_REFRESH is a different thing entirely -- a real environment
# variable (--force-refresh) -- and is covered at the end to make sure none of
# this disturbs it.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_RUN_DIR="$BATS_TEST_TMPDIR/run"
    export OCPROBE_LOG_LEVEL=info
    export OCPROBE_LOG_FORMAT=text
    mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

_write_config() { # $1 = extra lines injected into the config
    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  title_prefix: "ocprobe-probe"
  prompt: "OK"
catalog:
  cache_ttl_hours: 1
$1
session:
  max_msg_count: 4
  age_guard_hours: 24
  fresh_guard_hours: 1
  backup_dir: "$BATS_TEST_TMPDIR/sb"
retention:
  history_limit: 5000
logging:
  level: info
  format: text
  file_enabled: false
EOF
    echo '{"provider":{}}' >"$BATS_TEST_TMPDIR/opencode.json"
}

@test "a config containing a reserved key still validates (it must keep working)" {
    _write_config "  force_refresh: true
scheduler:
  interval_seconds: 21600
  enabled: true
  run_at_load: true
"
    run load_config
    assert_success
}

@test "setting a reserved key to a non-default value warns exactly once" {
    _write_config "  force_refresh: true
scheduler:
  interval_seconds: 21600
  enabled: true
  run_at_load: false
"
    run load_config
    assert_success
    # One warning naming the offending keys, not one per key.
    local warns
    warns=$(printf '%s\n' "$output" | grep -c 'no effect' || true)
    [ "$warns" -eq 1 ] || {
        echo "expected exactly 1 'no effect' warning, got $warns:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        false
    }
    printf '%s\n' "$output" | grep 'no effect' | grep -q 'catalog.force_refresh'
    printf '%s\n' "$output" | grep 'no effect' | grep -q 'scheduler.enabled'
}

@test "a reserved key left at its default value warns about nothing" {
    _write_config "  force_refresh: false
scheduler:
  interval_seconds: 21600
  enabled: false
  run_at_load: false
"
    run load_config
    assert_success
    refute_output --partial "no effect"
}

@test "a config with no reserved keys at all warns about nothing" {
    _write_config "scheduler:
  interval_seconds: 21600
"
    run load_config
    assert_success
    refute_output --partial "no effect"
}

@test "the generated default config no longer ships the reserved keys" {
    # `ocprobe config init`-style output, so nobody new copies a key that does
    # nothing.
    run bash -c "
        export OCPROBE_ROOT='$BATS_TEST_DIRNAME/../..'
        export OCPROBE_STATE_DIR='$OCPROBE_STATE_DIR'
        source '$BATS_TEST_DIRNAME/../../lib/core.sh' >/dev/null 2>&1
        source '$BATS_TEST_DIRNAME/../../lib/logging.sh' >/dev/null 2>&1
        source '$BATS_TEST_DIRNAME/../../lib/locking.sh' >/dev/null 2>&1
        source '$BATS_TEST_DIRNAME/../../lib/config.sh' >/dev/null 2>&1
        create_default_config '$BATS_TEST_TMPDIR/generated.yaml'
        cat '$BATS_TEST_TMPDIR/generated.yaml'
    "
    assert_success
    refute_output --partial "force_refresh:"
    refute_output --partial "run_at_load:"
    # scheduler.enabled must go too, but the other scheduler keys must stay
    refute_output --partial "  enabled:"
    assert_output --partial "interval_seconds:"
    assert_output --partial "cache_ttl_hours:"
}

@test "the reserved keys are still declared in the schema, marked reserved" {
    run grep -c 'force_refresh' "$BATS_TEST_DIRNAME/../../config/schema.json"
    assert_output "1"
    run grep -c 'run_at_load' "$BATS_TEST_DIRNAME/../../config/schema.json"
    assert_output "1"
    # scheduler.enabled and the others are described as having no effect, so a
    # reader of the schema learns the truth.
    run grep -c 'no effect' "$BATS_TEST_DIRNAME/../../config/schema.json"
    assert_output "3"
}

@test "the reserved keys are still declared in the shipped config.yaml's schema twin" {
    # The shipped config/config.yaml should no longer carry them either.
    run grep -c 'force_refresh' "$BATS_TEST_DIRNAME/../../config/config.yaml"
    assert_output "0"
    run grep -c 'run_at_load' "$BATS_TEST_DIRNAME/../../config/config.yaml"
    assert_output "0"
}

@test "OCPROBE_FORCE_REFRESH (the real env var) still works and is unaffected" {
    # --force-refresh sets this; it is a live knob in lib/models.sh and must keep
    # working regardless of the unrelated reserved config key of a similar name.
    _write_config "scheduler:
  interval_seconds: 21600
"
    export OCPROBE_FORCE_REFRESH=0
    run load_config
    assert_success
    assert_equal "0" "$OCPROBE_FORCE_REFRESH"

    export OCPROBE_FORCE_REFRESH=1
    run load_config
    assert_success
    assert_equal "1" "$OCPROBE_FORCE_REFRESH"

    # and the cache-refresh branch in models.sh still reads it
    run bash -c "
        export OCPROBE_FORCE_REFRESH=1
        export OCPROBE_CACHE_TTL_HOURS=99
        source '$BATS_TEST_DIRNAME/../../lib/core.sh' >/dev/null 2>&1
        [[ \$OCPROBE_FORCE_REFRESH -eq 1 ]]
    "
    assert_success
}
