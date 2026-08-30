#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/locking.bats — Locking tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
}

teardown() {
  release_lock
  rm -rf "$OCPROBE_STATE_DIR"
}

@test "acquire_lock creates lock directory" {
  acquire_lock
  assert [ -d "$OCPROBE_STATE_DIR/.lock" ]
  assert [ -f "$OCPROBE_STATE_DIR/.lock/pid" ]
  assert_equal "$(cat "$OCPROBE_STATE_DIR/.lock/pid")" "$$"
}

@test "release_lock removes lock directory" {
  acquire_lock
  release_lock
  assert [ ! -d "$OCPROBE_STATE_DIR/.lock" ]
}

@test "lock_status returns HELD when locked" {
  acquire_lock
  run lock_status
  assert_success
  assert_output --partial "HELD"
}

@test "lock_status returns FREE when unlocked" {
  run lock_status
  assert_success
  assert_output --partial "FREE"
}

@test "concurrent acquire_lock blocks second process" {
  acquire_lock
  # Try to acquire in background - should fail/timeout
  run timeout 1 bash -c "source '$OCPROBE_ROOT/lib/core.sh'; source '$OCPROBE_ROOT/lib/locking.sh'; acquire_lock"
  assert_failure
}

@test "stale lock (dead PID) is removed" {
  acquire_lock
  # Simulate dead PID
  echo $(( $$ + 1000 )) > "$OCPROBE_STATE_DIR/.lock/pid"
  # Should be able to acquire after stale detection
  release_lock
  acquire_lock
  assert_equal "$(cat "$OCPROBE_STATE_DIR/.lock/pid")" "$$"
}