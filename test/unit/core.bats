#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/core.bats — Core utility tests
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  source "$BATS_TEST_DIRNAME/../../lib/logging.sh"
  source "$BATS_TEST_DIRNAME/../../lib/locking.sh"
  # Mock die to avoid calling log_fatal/cleanup_run_dir/release_lock
  die() {
    echo "$*" >&2
    return 1
  }
}

teardown() {
  # Clean up any test config files
  rm -f /tmp/ocprobe-test-config-*.yaml
}

@test "validate_positive_int accepts valid integers" {
  validate_positive_int "TEST" "1"
  validate_positive_int "TEST" "42"
  validate_positive_int "TEST" "999999"
}

@test "validate_positive_int rejects zero" {
  run validate_positive_int "TEST" "0"
  assert_failure
  assert_output --partial "must be a positive integer"
}

@test "validate_positive_int rejects negative" {
  run validate_positive_int "TEST" "-1"
  assert_failure
}

@test "validate_positive_int rejects non-numeric" {
  run validate_positive_int "TEST" "abc"
  assert_failure
}

@test "validate_model_name accepts provider/model" {
  validate_model_name "openai/gpt-4"
  validate_model_name "anthropic/claude-3"
  validate_model_name "google/gemini-pro"
}

@test "validate_model_name accepts provider/model:variant" {
  validate_model_name "openai/gpt-4:latest"
  validate_model_name "anthropic/claude-3:sonnet"
}

@test "validate_model_name accepts kilo/~provider/model" {
  validate_model_name "kilo/~openai/gpt-4"
  validate_model_name "kilo/~anthropic/claude-3"
}

@test "validate_model_name rejects no slash" {
  run validate_model_name "gpt-4"
  assert_failure
}

@test "validate_model_name rejects invalid chars" {
  run validate_model_name "openai/gpt@4"
  assert_failure
}

@test "sql_escape doubles single quotes" {
  run sql_escape "it's a test"
  assert_success
  assert_equal "$output" "it''s a test"
}

@test "sql_escape handles multiple quotes" {
  run sql_escape "don't stop believin'"
  assert_success
  assert_equal "$output" "don''t stop believin''"
}

@test "sql_escape rejects empty input" {
  run sql_escape ""
  assert_failure
}

@test "sql_escape rejects null bytes" {
  skip "bash cannot pass null bytes in variables; tested via command substitution which strips them"
  local input
  input=$(printf 'test\0input')
  run sql_escape "$input"
  assert_failure
}

@test "sql_escape rejects newlines" {
  run bash -c "source '$BATS_TEST_DIRNAME/../../lib/core.sh'; sql_escape \$'test\ninput'"
  assert_failure
}

@test "sql_escape rejects carriage returns" {
  run bash -c "source '$BATS_TEST_DIRNAME/../../lib/core.sh'; sql_escape \$'test\rinput'"
  assert_failure
}

@test "sql_escape rejects overly long input" {
  local long_input
  long_input=$(printf 'a%.0s' {1..300})
  run sql_escape "$long_input"
  assert_failure
}

@test "ms returns milliseconds timestamp" {
  local result
  result=$(ms)
  assert test "$result" -gt 0
  assert test "$result" -gt 1700000000000  # After 2023
}

@test "atomic_write writes file atomically" {
  local tmpfile
  tmpfile=$(mktemp)
  echo "test content" | atomic_write "$tmpfile"
  assert_equal "$(cat "$tmpfile")" "test content"
  rm -f "$tmpfile"
}

@test "array_contains finds element" {
  local arr=("a" "b" "c")
  run array_contains "b" "${arr[@]}"
  assert_success
}

@test "array_contains returns false for missing" {
  local arr=("a" "b" "c")
  run array_contains "d" "${arr[@]}"
  assert_failure
}

@test "array_dedup removes duplicates" {
  local arr=("a" "b" "a" "c" "b")
  echo "Before: ${#arr[@]} ${arr[@]}" >&2
  array_dedup arr
  echo "After: ${#arr[@]} ${arr[@]}" >&2
  assert_equal "${#arr[@]}" 3
  assert_equal "${arr[0]}" "a"
  assert_equal "${arr[1]}" "b"
  assert_equal "${arr[2]}" "c"
}