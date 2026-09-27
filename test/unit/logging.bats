#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/logging.bats — Logging / structured output tests
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../../lib/core.sh"
  source "$BATS_TEST_DIRNAME/../../lib/logging.sh"
  export OCPROBE_LOG_LEVEL=info
  export OCPROBE_LOG_FORMAT=text
  init_logging
}

# M4: %N is a GNU date extension. BSD date (macOS) emitted the format
# characters literally, producing "2026-09-27T12:20:29.3NZ" in every JSON log
# line — not a valid ISO 8601 timestamp. Nothing asserted this, so the bug went
# unnoticed. These tests pin the format on BOTH platforms.
@test "iso8601 helper emits a valid ISO 8601 UTC timestamp" {
  run _ocprobe_iso8601_now
  assert_success
  # YYYY-MM-DDTHH:MM:SS.mmmZ  (3-digit millisecond field, trailing Z)
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] \
    || {
      echo "not ISO 8601 with real milliseconds: '$output'" >&2
      false
    }
}

@test "iso8601 helper does not leak the literal %N format characters" {
  # The exact macOS regression: BSD date rendered "%3N" as "3N".
  run _ocprobe_iso8601_now
  assert_success
  [[ "$output" != *"3N"* ]] || {
    echo "timestamp contains a literal '3N' (GNU-only format leaked): '$output'" >&2
    false
  }
  refute_output --partial "N Z"
}

@test "iso8601 millisecond field varies or is well-formed, never empty" {
  # Guards against a fallback that emits ".Z" or "..Z".
  run _ocprobe_iso8601_now
  assert_success
  local ms="${output##*.}"
  ms="${ms%Z}"
  [[ "$ms" =~ ^[0-9]{3}$ ]] || {
    echo "millisecond field is not 3 digits: '$ms' (full: '$output')" >&2
    false
  }
}

@test "json log line has a valid ISO 8601 timestamp field" {
  export OCPROBE_LOG_FORMAT=json
  run log_info "hello"
  assert_success

  # Must be valid JSON with a parseable timestamp.
  run jq -r '.timestamp' <<<"$output"
  assert_success
  local ts="$output"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z$ ]] \
    || {
      echo "json .timestamp is not ISO 8601 with milliseconds: '$ts'" >&2
      false
    }
  refute_output --partial "3N"
}

@test "json log line preserves level, message and caller fields" {
  export OCPROBE_LOG_FORMAT=json
  run log_warn "careful"
  assert_success
  # `run` overwrites $output, so keep the raw JSON before extracting fields.
  local json="$output"

  assert_equal "$(jq -r '.level' <<<"$json")" "WARN"
  assert_equal "$(jq -r '.message' <<<"$json")" "careful"
  # caller is "<file>:<line>". Invoked through bats' `run` wrapper the frame is
  # bats' own harness, so assert the shape rather than a specific filename.
  local caller
  caller="$(jq -r '.caller' <<<"$json")"
  [[ "$caller" =~ ^[A-Za-z0-9_.-]+\.bash:[0-9]+$ ]] \
    || {
      echo "caller is not '<file>:<line>': '$caller'" >&2
      false
    }
}

@test "text log format still emits a plain bracketed line" {
  export OCPROBE_LOG_FORMAT=text
  run log_info "plain text"
  assert_success
  # note the two spaces: the level is padded with %-5s
  [[ "$output" =~ ^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\][[:space:]]INFO[[:space:]]{2}plain[[:space:]]text$ ]] \
    || {
      echo "unexpected text log format: '$output'" >&2
      false
    }
}
