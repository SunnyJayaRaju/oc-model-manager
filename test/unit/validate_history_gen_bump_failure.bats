#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/validate_history_gen_bump_failure.bats
#
# The streak cache is keyed on (generation counter, byte size) of
# validate-history.jsonl. The generation counter is what catches a rewrite that
# leaves the size unchanged. So if the counter silently fails to advance while
# the file does change, the stale-cache hole that the counter was added to close
# reopens -- and the failure is invisible, because the caller has no way to tell
# a successful bump from a skipped one.
#
# _validate_history_gen_bump swallowed both failure modes:
#
#     if printf '%s\n' "$new" >"$tmp" 2>/dev/null; then
#         mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null
#     fi
#
# A failed temp write skips the mv and says nothing; a failed mv says nothing
# either. In both cases record_validate_history carried on, recorded the new
# size, and exited 0.
#
# The fix: on bump failure warn, invalidate the in-process cache, and return
# non-zero so record_validate_history reports failure the way its existing
# SKIPPED path does. Losing a history line is survivable; a silently wrong
# cache is not.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_RUN_DIR="$BATS_TEST_TMPDIR/run"
    export OCPROBE_LOG_LEVEL=info
    export OCPROBE_LOG_FORMAT=text
    mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
    source "$ROOT/lib/core.sh"
    source "$ROOT/lib/logging.sh"
    source "$ROOT/lib/locking.sh"
    source "$ROOT/lib/db.sh"
    source "$ROOT/lib/validate.sh"
}

gen_file() { printf '%s\n' "$OCPROBE_STATE_DIR/.validate-history.gen"; }
hist_file() { printf '%s\n' "$OCPROBE_STATE_DIR/validate-history.jsonl"; }

@test "the happy path bumps the counter and record_validate_history succeeds" {
    record_validate_history "m1" "BROKEN"
    assert_equal "0" "$?"
    assert_equal "1" "$(cat "$(gen_file)")"
    assert_equal "1" "$(wc -l < "$(hist_file)" | tr -d ' ')"

    record_validate_history "m2" "BROKEN"
    assert_equal "2" "$(cat "$(gen_file)")"
    assert_equal "2" "$(wc -l < "$(hist_file)" | tr -d ' ')"
}

# ---- the failure mode -------------------------------------------------------

@test "a bump that cannot write the sidecar is loud and reports failure" {
    # A directory where the sidecar belongs: every write under it fails, and the
    # mv cannot replace a directory with a file either.
    mkdir -p "$(gen_file)"

    run record_validate_history "m1" "BROKEN"
    assert_failure
    assert_output --partial "generation"
}

@test "the history line is still written when only the bump fails" {
    # The append happens before the bump, so the data is on disk. What must not
    # happen is a silent success: the caller has to be able to tell.
    mkdir -p "$(gen_file)"
    run record_validate_history "m1" "BROKEN"
    assert_failure
    assert_equal "1" "$(wc -l < "$(hist_file)" | tr -d ' ')"
}

@test "a failed bump invalidates the in-process streak cache" {
    # Prime the cache with a good record, then replace the sidecar with a
    # directory so the bump cannot succeed.
    record_validate_history "m1" "BROKEN"
    _validate_streak_sync
    [ -n "$_VALIDATE_HISTREAK_GEN" ] || {
        echo "expected the cache to have adopted a generation" >&2
        false
    }
    assert_equal "1" "${_VALIDATE_HISTREAK[m1]}"

    rm -f "$(gen_file)"
    mkdir -p "$(gen_file)"
    record_validate_history "m1" "BROKEN" || true

    # The folded map must not still be trusted: it was advanced against a
    # generation that never actually changed on disk.
    assert_equal "-1" "$_VALIDATE_HISTREAK_BYTES"
    assert_equal "0" "${#_VALIDATE_HISTREAK[@]}"
}

@test "a failed bump leaves the cached generation pointing at the old value" {
    # So the next read sees a mismatch and rebuilds from the file.
    record_validate_history "m1" "BROKEN"
    _validate_streak_sync
    local before_gen="$_VALIDATE_HISTREAK_GEN"
    rm -f "$(gen_file)"
    mkdir -p "$(gen_file)"
    record_validate_history "m1" "BROKEN" || true
    [ "$_VALIDATE_HISTREAK_GEN" != "$before_gen" ] || {
        echo "cached generation was left at $before_gen after a failed bump" >&2
        false
    }
}

@test "the next read after a failed bump rebuilds the correct streak" {
    # The real point: a failure must not corrupt the answer, only force the
    # slow path.
    record_validate_history "m1" "BROKEN"
    rm -f "$(gen_file)"
    mkdir -p "$(gen_file)"
    record_validate_history "m1" "BROKEN" || true
    # Put the sidecar back so the rebuild can read a generation.
    rmdir "$(gen_file)"

    # Two consecutive failures for m1, as recorded above.
    _validate_streak_sync
    assert_equal "2" "${_VALIDATE_HISTREAK[m1]}"
}

@test "an unwritable state directory is also loud" {
    # Different failure, same contract: chmod the directory so the temp write
    # cannot be created. Skipped when running as root, where the mode is
    # advisory.
    if [ "$(id -u)" = "0" ]; then
        skip "running as root: directory permissions are not enforced"
    fi
    record_validate_history "m1" "BROKEN"
    local saved_gen
    saved_gen="$(cat "$(gen_file)")"
    chmod 500 "$OCPROBE_STATE_DIR"

    run record_validate_history "m2" "BROKEN"
    chmod 700 "$OCPROBE_STATE_DIR"
    assert_failure
    assert_output --partial "generation"
    # Untouched, so the next run still knows where it left off.
    assert_equal "$saved_gen" "$(cat "$(gen_file)")"
}

@test "a failure is reported once per record, not once per warning" {
    mkdir -p "$(gen_file)"
    run record_validate_history "m1" "BROKEN"
    assert_failure
    local warns
    warns=$(printf '%s\n' "$output" | grep -ci 'generation' || true)
    [ "$warns" -le 2 ] || {
        echo "expected at most 2 mentions of 'generation', got $warns:" >&2
        printf '%s\n' "$output" | sed 's/^/    /' >&2
        false
    }
}

# ---- what must NOT change ---------------------------------------------------

@test "the in-process increment still works, so the fast path is not slowed" {
    # record_validate_history used to advance the folded map in place; that is
    # what makes a 900-model run linear rather than quadratic, so it has to
    # survive the fix.
    for i in 1 2 3 4 5 6 7 8; do record_validate_history "model$i" "BROKEN"; done
    _validate_streak_sync
    assert_equal "8" "${#_VALIDATE_HISTREAK[@]}"
    for i in 1 2 3 4 5 6 7 8; do
        assert_equal "1" "${_VALIDATE_HISTREAK[model$i]}"
    done
    # and the cached generation adopted the newest value, with the byte size
    # tracking the file (224 = 8 lines of "modelN\tBROKEN\t<13-digit ms>")
    assert_equal "8" "$_VALIDATE_HISTREAK_GEN"
    assert_equal "8" "$(wc -l < "$(hist_file)" | tr -d ' ')"
    assert_equal "$(wc -c < "$(hist_file)" | tr -d ' ')" "$_VALIDATE_HISTREAK_BYTES"
}

@test "the H3 fail-closed lock behaviour is untouched" {
    # Same shape as the existing H3 tests in test/unit/validate.bats: make the
    # scoped lock look contended, then assert the callback does not run. D2 must
    # not have softened fail-closed, and this is the assertion that would notice.
    local ran_file="$BATS_TEST_TMPDIR/ran"
    _acquire_scoped_lock() { return 1; }
    _touch_marker() { : >"$ran_file"; }

    _validate_history_locked _touch_marker >/dev/null 2>&1 || true

    [ ! -f "$ran_file" ] || {
        echo "callback ran unlocked despite lock contention" >&2
        false
    }
}

@test "the H3 skip sentinel still reaches the caller" {
    _acquire_scoped_lock() { return 1; }
    run _validate_history_locked true
    assert_failure
    assert_equal "$OCPROBE_HISTORY_SKIPPED" "$status"
}

@test "a bump failure is distinct from a lock skip, and both are non-zero" {
    # Two different reasons to fail must not be conflated: a lock skip means
    # "contention, retry later", a bump failure means "the cache is now
    # untrustworthy". Both are non-zero, so a caller can treat them alike, but
    # the messages must say which happened.
    _acquire_scoped_lock() { return 1; }
    run _validate_history_locked true
    assert_failure
    refute_output --partial "generation"

    mkdir -p "$(gen_file)"
    run record_validate_history "m1" "BROKEN"
    assert_failure
    assert_output --partial "generation"
}
