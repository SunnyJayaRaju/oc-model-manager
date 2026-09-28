#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/validate_history_cache.bats — soundness of the validate-history
# streak cache.
#
# The cache (lib/validate.sh, _VALIDATE_HISTREAK) used to be invalidated on the
# history file's BYTE SIZE alone. Byte size is not injective: another validate
# run that appends one line and then prunes an equal number of bytes leaves the
# size identical with different content, so the cache was trusted while stale.
#
# Reproduced exactly (this is the scenario, not a paraphrase):
#
#   B primes the map:  file = "m<TAB>ERROR<TAB>1"   (10 bytes)  -> streak 1
#   A appends a record:  file grows to 20 bytes       (gen bumped)
#   A prunes:          file = "m<TAB>WORKS<TAB>1"    (10 bytes)  -> truth 0
#   B reads:           size still 10 == cached 10, so B returned the stale 1
#
# A streak of 1 where the truth is 0 means CONFIRMED instead of TENTATIVE, i.e.
# a model gets written to the blacklist that should not have been.
#
# Fix: a generation counter sidecar ($OCPROBE_STATE_DIR/.validate-history.gen)
# that every writer bumps. record_validate_history is the ONLY writer of
# validate-history.jsonl and every one of its call sites runs under
# _validate_history_locked, so bumping it there covers every mutation.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_RUN_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/sb"
retention:
  history_limit: 5000
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo '{"provider":{}}' >"$BATS_TEST_TMPDIR/opencode.json"
    load_config >/dev/null

    HISTORY="$OCPROBE_STATE_DIR/validate-history.jsonl"
    GEN="$OCPROBE_STATE_DIR/.validate-history.gen"
    # Start from a known-empty cache so each test is independent.
    _VALIDATE_HISTREAK=()
    _VALIDATE_HISTREAK_BYTES=-1
    _VALIDATE_HISTREAK_GEN=""
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

_size()  { wc -c <"$HISTORY" | tr -d '[:space:]'; }
_truth() { # recompute from the file, bypassing the cache entirely
    local keep=("$@")
    _VALIDATE_HISTREAK=()
    _VALIDATE_HISTREAK_BYTES=-1
    _validate_history_streak_into m
    printf '%s' "$_VALIDATE_LAST_STREAK"
}

@test "stale cache: another run's append+prune that nets zero bytes must not be trusted" {
    # B primes on a file whose only record is one failure. The line is a
    # realistic 22 bytes ("m<TAB>ERROR<TAB><13-digit ms><NL>"), the same width a
    # real writer emits, so the append and the prune below cancel exactly.
    printf 'm\tERROR\t1759000000000\n' >"$HISTORY"
    _validate_history_streak_into m
    assert_equal 1 "$_VALIDATE_LAST_STREAK"
    local cached_size; cached_size=$(_size)

    # --- process A, entirely out of band: B never writes anything, so B's cached
    # size stays at whatever it was. A appends one record, then prunes the oldest
    # line, leaving the file at exactly the same byte size with new content.
    printf 'm\tERROR\t1759000000000\nm\tWORKS\t1759000000000\n' >"$HISTORY"
    tail -n 1 "$HISTORY" >"$HISTORY.pruned" && mv "$HISTORY.pruned" "$HISTORY"
    # A bumps the sidecar, as every writer must (record_validate_history is the
    # only writer of this file and all of its call sites hold the scoped lock).
    printf '%s' "$(( $(cat "$GEN" 2>/dev/null || echo 0) + 1 ))" >"$GEN"
    assert_equal "$cached_size" "$(_size)"   # the trap: size is unchanged

    # The file's only m record is now WORKS, so the true streak is 0.
    assert_equal 0 "$(_truth)"

    # B reads again, exactly as the classification loop does.
    _validate_history_streak_into m
    assert_equal 0 "$_VALIDATE_LAST_STREAK"
}

@test "record_validate_history creates and bumps the generation sidecar" {
    rm -f "$GEN"
    printf 'm\tERROR\t1759000000000\n' >"$HISTORY"

    # A read must NOT create it: a missing sidecar simply reads as unknown.
    _validate_history_streak_into m
    [ ! -f "$GEN" ] || {
        echo "a read created the sidecar; it is a writer-side artefact" >&2
        false
    }

    # The first write creates it.
    record_validate_history m TIMEOUT
    [ -f "$GEN" ] || {
        echo "no generation sidecar at $GEN after a write" >&2
        false
    }
    local g0; g0=$(cat "$GEN")
    [[ "$g0" =~ ^[0-9]+$ ]] || {
        echo "generation is not a bare integer: [$g0]" >&2
        false
    }

    record_validate_history m TIMEOUT
    local g1; g1=$(cat "$GEN")
    [ "$g1" -gt "$g0" ] || {
        echo "record_validate_history did not bump the generation ($g0 -> $g1)" >&2
        false
    }

    record_validate_history m TIMEOUT
    local g2; g2=$(cat "$GEN")
    [ "$g2" -gt "$g1" ] || {
        echo "second write did not bump the generation ($g1 -> $g2)" >&2
        false
    }
}

@test "a sidecar without a trailing newline is still honoured" {
    # `read` hits EOF without a newline and returns non-zero, but has already
    # assigned the value. If that status were swallowed the generation would be
    # treated as unknown and the cache would fall back to size-only -- silently
    # reinstating the exact bug this counter prevents.
    printf 'm\tERROR\t1759000000000\n' >"$HISTORY"
    _validate_history_streak_into m
    assert_equal 1 "$_VALIDATE_LAST_STREAK"

    # Written with no trailing newline at all.
    printf '%s' "1" >"$GEN"
    printf 'm\tWORKS\t1759000000000\n' >"$HISTORY"
    assert_equal 0 "$(_truth)"

    _validate_history_streak_into m
    assert_equal 0 "$_VALIDATE_LAST_STREAK"
}

@test "a missing sidecar forces exactly one rebuild, not a permanently empty cache" {
    printf 'm\tERROR\t1\nm\tERROR\t2\n' >"$HISTORY"
    rm -f "$GEN"

    # First read: sidecar absent, so the map must be built from the file.
    _validate_history_streak_into m
    assert_equal 2 "$_VALIDATE_LAST_STREAK"

    # And the freshly built map must be cached (a second read agrees).
    _validate_history_streak_into m
    assert_equal 2 "$_VALIDATE_LAST_STREAK"
}

@test "the cache is still correct for the ordinary append path" {
    printf '' >"$HISTORY"
    _validate_history_streak_into m
    assert_equal 0 "$_VALIDATE_LAST_STREAK"

    record_validate_history m TIMEOUT
    _validate_history_streak_into m
    assert_equal 1 "$_VALIDATE_LAST_STREAK"

    record_validate_history m TIMEOUT
    _validate_history_streak_into m
    assert_equal 2 "$_VALIDATE_LAST_STREAK"

    # WORKS resets
    record_validate_history m WORKS
    _validate_history_streak_into m
    assert_equal 0 "$_VALIDATE_LAST_STREAK"

    # EOL / NOT_FOUND confirm at 2 immediately
    record_validate_history m EOL
    _validate_history_streak_into m
    assert_equal 2 "$_VALIDATE_LAST_STREAK"
    record_validate_history m WORKS
    record_validate_history m NOT_FOUND
    _validate_history_streak_into m
    assert_equal 2 "$_VALIDATE_LAST_STREAK"
}

@test "a concurrent writer's change is picked up on the next read" {
    # A different process rewrites the file behind this process's back, with NO
    # size change and (on the unpatched code) no way to notice.
    printf 'm\tERROR\t1759000000000\n' >"$HISTORY"
    _validate_history_streak_into m
    assert_equal 1 "$_VALIDATE_LAST_STREAK"

    # Another process: same byte size, new content, sidecar bumped by it.
    printf 'm\tWORKS\t1759000000000\n' >"$HISTORY"
    printf '%s' $(( $(cat "$GEN" 2>/dev/null || echo 0) + 1 )) >"$GEN"
    _validate_history_streak_into m
    assert_equal 0 "$_VALIDATE_LAST_STREAK"
}
