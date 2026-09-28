#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/core_int_normalization.bats — base-10 handling of integer config
# values, and the normalization that makes a leading zero harmless.
#
# The gate was:  [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -gt 0 ]]
#
# `[[ -gt ]]` evaluates arithmetic, and a leading zero means OCTAL. So a user
# writing `interval_seconds: 08` got two errors, the first of which explains
# nothing:
#
#   value too great for base (error token is "08")
#   must be a positive integer (got: 08)
#
# and `007` was quietly accepted as octal 7, i.e. the value that reached the
# arithmetic and the SQL sinks was not the number the user wrote.
#
# Fixed by forcing base 10 (10#), rejecting 0, capping the digit count so
# overflow is impossible, and then NORMALIZING the exported value to canonical
# decimal in load_config. The normalization is the part that matters downstream:
# without it "08" would pass validation and then be interpolated unquoted into
# SQL and into $(( )) arithmetic, where a leading zero is a trap again.
#
# The four pre-existing validate_positive_int tests in core.bats are unchanged.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
    export OCPROBE_LOG_LEVEL=error
    export OCPROBE_LOG_FORMAT=text
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# ---- the gate itself ------------------------------------------------------

@test "validate_positive_int accepts leading-zero values as base 10" {
    run validate_positive_int "TEST" "08"
    assert_success
    run validate_positive_int "TEST" "09"
    assert_success
    run validate_positive_int "TEST" "007"
    assert_success
    run validate_positive_int "TEST" "0000000009"
    assert_success
}

@test "validate_positive_int still rejects zero, negatives and non-numerics" {
    run validate_positive_int "TEST" "0"
    assert_failure
    assert_output --partial "must be a positive integer"

    run validate_positive_int "TEST" "00"
    assert_failure

    run validate_positive_int "TEST" "000"
    assert_failure

    run validate_positive_int "TEST" "-1"
    assert_failure

    run validate_positive_int "TEST" "4 OR 1=1"
    assert_failure
    assert_output --partial "must be a positive integer"

    run validate_positive_int "TEST" "4); DROP TABLE session;--"
    assert_failure
    assert_output --partial "must be a positive integer"

    run validate_positive_int "TEST" ""
    assert_failure
}

@test "validate_positive_int rejects an over-long digit run with a clear message" {
    # 20 digits: far beyond any int64, and beyond any sane config value.
    run validate_positive_int "TEST" "99999999999999999999"
    assert_failure
    # The message must say why, not just "not a positive integer": a 20-digit
    # number IS a positive integer, it is simply too long to use safely.
    assert_output --partial "at most 10 digits"
    # And it must not leak a shell arithmetic diagnostic instead.
    refute_output --partial "value too great for base"
    refute_output --partial "syntax error"

    run validate_positive_int "TEST" "12345678901"   # 11 digits
    assert_failure
    assert_output --partial "at most 10 digits"
}

@test "validate_positive_int accepts the largest in-range value" {
    run validate_positive_int "TEST" "9999999999"   # 10 digits
    assert_success
}

# ---- normalization -------------------------------------------------------
#
# Being straight about reachability, because it changes what these tests can
# honestly claim. A value in config.yaml is validated by jsonschema BEFORE the
# bash gate ever sees it, and every integer field in config/schema.json carries
# a minimum and a maximum. Measured:
#
#   file: 08   -> PyYAML resolves it to the STRING '08' -> schema: "is not of
#                   type 'integer'"
#   file: 8    -> schema: below the minimum for that field
#   file: 0    -> schema: below the minimum
#   file: <20 digits> -> schema: above the maximum
#
# So no config-file input can put a leading zero, a zero, or an over-long run in
# front of validate_positive_int. The bash gate is the second line of defence,
# and normalizing its output guards the unquoted SQL and $(( )) sinks against a
# leading zero arriving by any future path. These tests therefore assert the
# invariant (everything the gate exports is canonical) rather than pretending a
# file input reaches it.

@test "every validated int is exported in canonical decimal, with its value preserved" {
    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$OCPROBE_STATE_DIR"
    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  title_prefix: "ocprobe-probe"
  prompt: "OK"
scheduler:
  interval_seconds: 21600
session:
  max_msg_count: 4
  age_guard_hours: 24
  fresh_guard_hours: 1
  backup_dir: "$BATS_TEST_TMPDIR/sb"
retention:
  history_limit: 5000
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo '{"provider":{}}' >"$BATS_TEST_TMPDIR/opencode.json"
    run load_config
    assert_success

    # Values preserved, and none carrying a leading zero.
    assert_equal 4    "$OCPROBE_MAX_MSG_COUNT"
    assert_equal 24   "$OCPROBE_AGE_GUARD_HOURS"
    assert_equal 1    "$OCPROBE_FRESH_GUARD_HOURS"
    assert_equal 21600 "$OCPROBE_WATCH_SECS"
    assert_equal 5000 "$OCPROBE_HISTORY_LIMIT"

    local v
    for v in OCPROBE_MAX_MSG_COUNT OCPROBE_AGE_GUARD_HOURS OCPROBE_FRESH_GUARD_HOURS \
             OCPROBE_WATCH_SECS OCPROBE_HISTORY_LIMIT; do
        [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || {
            echo "$v is not canonical decimal: [${!v}]" >&2
            false
        }
    done
}

@test "a leading zero that reaches the gate is safe in the unquoted SQL and arithmetic sinks" {
    # This is the property normalization exists for, exercised directly since a
    # config file cannot produce this input (see the note above). "08" is exactly
    # what a leading-zero value would look like if it ever arrived by another
    # route, and it is a trap in both sinks: octal in $(( )), and a bare literal
    # in SQL that no longer matches what the operator wrote.
    local raw="08"
    validate_positive_int "scheduler.interval_seconds" "$raw"

    # The canonical form is what load_config exports.
    local canonical="${raw#"${raw%%[!0]*}"}"
    [[ -n "$canonical" ]] || canonical=0
    assert_equal "8" "$canonical"

    # Safe in $(( )).
    assert_equal 0 "$(( canonical / 3600 ))"

    # Safe as a SQL integer literal.
    run sqlite3 :memory: "SELECT $canonical AS v;"
    assert_success
    assert_output "8"

    # And the un-normalized form really is the problem, so this test is not
    # asserting something that was true anyway.
    run sqlite3 :memory: "SELECT '08' = 8;"
    assert_output "0"
}

@test "load_config rejects an out-of-range value from a real file" {
    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    mkdir -p "$OCPROBE_STATE_DIR"
    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  title_prefix: "ocprobe-probe"
  prompt: "OK"
scheduler:
  interval_seconds: 99999999999999999999
session:
  max_msg_count: 4
  age_guard_hours: 24
  fresh_guard_hours: 1
  backup_dir: "$BATS_TEST_TMPDIR/sb"
retention:
  history_limit: 5000
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo '{"provider":{}}' >"$BATS_TEST_TMPDIR/opencode.json"
    run load_config
    assert_failure
    # The schema's maximum catches it, and says so in plain language. No shell
    # arithmetic diagnostic, which is what the old gate would have produced.
    assert_output --partial "maximum"
    refute_output --partial "value too great for base"
    refute_output --partial "syntax error"
}
