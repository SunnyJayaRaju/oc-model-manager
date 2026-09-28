#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/session_restore_keyword_guard.bats
#
# The authorizer in lib/session_restore.py was the only thing deciding what a
# dump could contain. That is one layer, and its coverage is a property of the
# sqlite build rather than of this code: a statement a given build does not
# route through SQLITE_* callbacks is never offered to the authorizer at all.
#
# Two independent holes, both found against the base code:
#
#  1. "INSERT INTO session DEFAULT VALUES" is a real INSERT on an allowed table,
#     so the authorizer permits it, and it silently writes an all-NULL row. A
#     genuine dump (sqlite3 .mode insert over session/message/part/todo) never
#     emits DEFAULT VALUES, so accepting it can only corrupt the target.
#
#  2. Anything the authorizer is not asked about is accepted by default. On
#     sqlite 3.53.4 REINDEX/ANALYZE/VACUUM do happen to fire callbacks and are
#     denied, but that is the build's choice, not this code's guarantee.
#
# So the module now checks the first keyword of every complete statement before
# running it, and independently requires each statement to have actually
# performed an allowed INSERT. The authorizer stays as the second layer.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    DB="$BATS_TEST_TMPDIR/probe.db"
    DUMP="$BATS_TEST_TMPDIR/dump.sql"
    OUT="$BATS_TEST_TMPDIR/out.txt"
    # -B so the probe itself never writes a __pycache__ into the repo.
    SR="python3 -B $ROOT/lib/session_restore.py"

    sqlite3 "$DB" <<'SQL'
CREATE TABLE session(id TEXT PRIMARY KEY, title TEXT, data TEXT);
CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, data TEXT);
CREATE TABLE part(id TEXT PRIMARY KEY, message_id TEXT, data TEXT);
CREATE TABLE todo(id TEXT PRIMARY KEY, session_id TEXT, content TEXT);
CREATE INDEX idx_data ON session(data);
CREATE INDEX idx_msg ON message(session_id);
INSERT INTO session VALUES('s1','original','keep me');
SQL
}

snapshot() { sqlite3 "$DB" "SELECT id || '|' || COALESCE(title,'<null>') FROM session ORDER BY id;"; }
count_sessions() { sqlite3 "$DB" "SELECT count(*) FROM session;"; }

# Writes $1 as the dump and runs the module. Sets RC, and leaves the combined
# output in $OUT. Deliberately not bats' `run`: the assertions below need both
# the status and the output in the same shell, and `run` only survives inside a
# command substitution here, where $output is not visible to the caller.
# Builds a dump the way cmd_session_backup does: seed rows containing a real
# newline and a semicolon, dump with `sqlite3 .mode insert`, then rewrite
# INSERT INTO to INSERT OR REPLACE. Generated rather than hand-written because
# the escaping of a newline is sqlite-build dependent.
_make_real_dump() {
    # The session/message/part tables are created in setup() and session already
    # has a row, so the dump is driven off INSERT OR REPLACE rather than
    # INSERT: this helper may run more than once in a test file, and a unique
    # violation on the second call would be a fixture problem, not a finding.
    sqlite3 "$DB" <<'SQL'
INSERT OR REPLACE INTO session VALUES('s1','t;1','multi' || char(10) || 'line');
INSERT OR REPLACE INTO message VALUES('m1','s1','has ; semicolon');
INSERT OR REPLACE INTO part VALUES('p1','m1','p' || char(10) || '1');
SQL
    {
        echo ".mode insert session"
        echo "SELECT * FROM session WHERE id='s1';"
        echo ".mode insert message"
        echo "SELECT * FROM message WHERE id='m1';"
        echo ".mode insert part"
        echo "SELECT * FROM part WHERE id='p1';"
    } | sqlite3 -readonly "$DB" >"$BATS_TEST_TMPDIR/real.sql"
    # INSERT OR REPLACE, as cmd_session_backup does, so a re-restore is idempotent.
    if sed --version >/dev/null 2>&1; then
        sed -i 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$BATS_TEST_TMPDIR/real.sql"
    else
        sed -i '' 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$BATS_TEST_TMPDIR/real.sql"
    fi
    grep -q 'INSERT OR REPLACE INTO session' "$BATS_TEST_TMPDIR/real.sql" || {
        echo "the generated fixture is not shaped like a backup dump:" >&2
        cat "$BATS_TEST_TMPDIR/real.sql" >&2
        false
    }
}

run_restore() {
    printf '%s' "$1" >"$DUMP"
    # Capture the status explicitly rather than relying on `$?` after a command
    # that bats may treat as a test failure. `|| RC=$?` catches the non-zero
    # case (which most of these tests want); the fallthrough catches success.
    # The module's output is re-exported as $output so assert_output works too:
    # bats' `run` cannot be used here because these tests need the status and
    # the output in the same shell, and `run` only survives in a substitution.
    RC=0
    bash -c "$SR '$DB' '$DUMP'" >"$OUT" 2>&1 || RC=$?
    output="$(cat "$OUT")"
    lines=()
    while IFS= read -r _line; do lines+=("$_line"); done <"$OUT"
    return 0
}

# ---- the reproducible base failure -----------------------------------------

@test "INSERT ... DEFAULT VALUES is rejected and the database is unchanged" {
    before="$(snapshot)"
    run_restore "INSERT INTO session DEFAULT VALUES;"
    [ "$RC" -ne 0 ]
    assert_equal "$before" "$(snapshot)"
    assert_equal "1" "$(count_sessions)"
}

@test "REPLACE ... DEFAULT VALUES is rejected too" {
    before="$(snapshot)"
    run_restore "REPLACE INTO session DEFAULT VALUES;"
    [ "$RC" -ne 0 ]
    assert_equal "$before" "$(snapshot)"
}

@test "a DEFAULT VALUES smuggled after a valid INSERT rolls the whole file back" {
    before="$(snapshot)"
    run_restore "INSERT OR REPLACE INTO session VALUES('s2','t2','x');
INSERT INTO session DEFAULT VALUES;"
    [ "$RC" -ne 0 ]
    assert_equal "$before" "$(snapshot)"
}

# ---- the first-keyword guard, exercised directly ---------------------------

@test "the keyword guard accepts the shapes a real dump uses" {
    _kw_accepts "INSERT OR REPLACE INTO session VALUES('a','b','c');"
    _kw_accepts "INSERT INTO session VALUES('a','b','c');"
    _kw_accepts "REPLACE INTO session VALUES('a','b','c');"
    # case and leading whitespace must not matter
    _kw_accepts "  insert or replace into session VALUES('a','b','c');"
    _kw_accepts $'\tINSERT INTO session VALUES(1,2,3);'
    # a WITH that ends in an INSERT is allowed through to the authorizer
    _kw_accepts "WITH t(a) AS (VALUES('k')) INSERT INTO session SELECT a,'1';"
}

@test "the keyword guard rejects every non-INSERT first keyword" {
    for s in "REINDEX;" "ANALYZE;" "VACUUM;" "PRAGMA writable_schema=ON;" \
        "DELETE FROM session;" "UPDATE session SET title='x';" "DROP TABLE session;" \
        "ALTER TABLE session ADD COLUMN z TEXT;" "ATTACH DATABASE '/tmp/e.db' AS e;" \
        "CREATE TRIGGER t AFTER INSERT ON session BEGIN SELECT 1; END;" \
        "SELECT load_extension('x');" "EXPLAIN SELECT 1;" "COMMIT;" "ROLLBACK;"; do
        _kw_rejects "$s"
    done
}

@test "the keyword guard sees through comments, BOM and unicode spaces" {
    # All of these must be judged as REINDEX, not as something harmless.
    _kw_rejects "-- REINDEX"
    _kw_rejects "--harmless comment
REINDEX;"
    _kw_rejects "/* REINDEX */ VACUUM;"
    _kw_rejects $'\xef\xbb\xbfREINDEX;'
    _kw_rejects $'\xc2\xa0REINDEX;'
    _kw_rejects $'\xe3\x80\x80REINDEX;'
    _kw_rejects $'\xe2\x80\x83REINDEX;'
    # ...and a commented-out INSERT really is still an INSERT
    _kw_accepts "-- a comment
INSERT OR REPLACE INTO session VALUES('a','b','c');"
    _kw_accepts $'\xef\xbb\xbf/* lead */ INSERT INTO session VALUES(1,2,3);'
}

@test "an unterminated block comment cannot hide a statement" {
    # "/*" with no "*/" means the comment runs on, so there is no first keyword
    # to find and the statement must not be accepted.
    _kw_rejects "/* unterminated REINDEX"
    _kw_rejects "/*/ REINDEX"
}

@test "a comment cannot smuggle a second statement past the guard" {
    # The guard reads the FIRST keyword, so this string passes the guard. What
    # must stop it is the statement splitter: sqlite3.complete_statement()
    # closes the INSERT at its ';', so "/* x */ REINDEX;" arrives next and is
    # then refused on its own. Proved end to end, because asserting it at the
    # guard level would be asserting the wrong thing.
    before="$(snapshot)"
    run_restore "INSERT OR REPLACE INTO session VALUES('s2','t2','x');
/* x */ REINDEX;"
    [ "$RC" -ne 0 ]
    # the good INSERT was rolled back with everything else
    assert_equal "$before" "$(snapshot)"
    assert_output --partial "REINDEX"
}

@test "a value that merely reads DEFAULT VALUES is not mistaken for the clause" {
    # The message body is data. Refusing this would make a real dump fail.
    run_restore "INSERT OR REPLACE INTO message VALUES('m1','s1','DEFAULT VALUES');
INSERT OR REPLACE INTO message VALUES('m2','s1','set DEFAULT VALUES here');"
    assert_equal "0" "$RC"
    assert_equal "DEFAULT VALUES" "$(sqlite3 "$DB" "SELECT data FROM message WHERE id='m1';")"
}

@test "a comment-prefixed REINDEX is rejected end to end, database unchanged" {
    before="$(snapshot)"
    run_restore "-- leading comment
REINDEX;"
    [ "$RC" -ne 0 ]
    assert_equal "$before" "$(snapshot)"
}

@test "a BOM-prefixed REINDEX is rejected end to end, database unchanged" {
    before="$(snapshot)"
    run_restore $'\xef\xbb\xbfREINDEX;'
    [ "$RC" -ne 0 ]
    assert_equal "$before" "$(snapshot)"
}

@test "a BOM-prefixed valid dump is still restored" {
    run_restore $'\xef\xbb\xbfINSERT OR REPLACE INTO session VALUES(\'s1\',\'bom-ok\',\'z\');'
    assert_equal "0" "$RC"
    assert_equal "s1|bom-ok" "$(sqlite3 "$DB" "SELECT id || '|' || title FROM session WHERE id='s1';")"
}

@test "REINDEX / ANALYZE / VACUUM are rejected end to end, database unchanged" {
    for s in "REINDEX;" "ANALYZE;" "VACUUM;" "REINDEX idx_data;" "ANALYZE session;"; do
        before="$(snapshot)"
        run_restore "$s"
        [ "$RC" -ne 0 ] || {
            echo "expected rejection for: $s" >&2
            false
        }
        assert_equal "$before" "$(snapshot)"
    done
}

# ---- legit dumps must keep working -----------------------------------------

@test "a real-shaped dump round-trips, semicolons in values included" {
    # Generated by `sqlite3 .mode insert` rather than hand-written, because how
    # a newline is escaped in a dump is BUILD-DEPENDENT: this macOS sqlite writes
    # unistr('...\u000a...') and the ubuntu runner's writes a literal newline, and
    # unistr() does not even exist on a build older than 3.42. A hand-written
    # unistr() dump therefore fails on one leg for a reason that has nothing to
    # do with the keyword guard. Generating it tests whichever shape this build
    # actually produces -- which is the real requirement.
    _make_real_dump
    run_restore "$(cat "$BATS_TEST_TMPDIR/real.sql")"
    assert_equal "0" "$RC"
    assert_equal "s1|t;1" "$(sqlite3 "$DB" "SELECT id || '|' || title FROM session WHERE id='s1';")"
    assert_equal "has ; semicolon" "$(sqlite3 "$DB" "SELECT data FROM message WHERE id='m1';")"
}

@test "a multi-line value spanning physical lines still round-trips" {
    # The other shape: whatever escaping this build emits, and the literal
    # multi-line form the ubuntu runner produces.
    _make_real_dump
    run_restore "$(cat "$BATS_TEST_TMPDIR/real.sql")"
    assert_equal "0" "$RC"
    # the stored value must still contain a real newline after the round trip
    local stored
    stored="$(sqlite3 "$DB" "SELECT data FROM part WHERE id='p1';")"
    case "$stored" in
        *$'\n'*) ;;
        *)
            echo "the embedded newline did not survive the round trip: $(printf '%q' "$stored")" >&2
            false
            ;;
    esac
}

@test "every function a real dump uses is on the allowlist" {
    # The general form of the above: whatever this build's .mode insert emits,
    # the allowlist must already cover it. A build that invents a new helper
    # would otherwise ship a dump its own restore refuses.
    _make_real_dump
    local used missing
    used="$(grep -oE '\b[A-Za-z_][A-Za-z0-9_]*\(' "$BATS_TEST_TMPDIR/real.sql" |
        tr -d '(' | sort -u | grep -vE '^(INSERT|VALUES|REPLACE|INTO)$' || true)"
    [ -n "$used" ] || {
        echo "the generated dump uses no SQL functions at all, so this proves nothing" >&2
        false
    }
    missing="$(python3 -B "$ROOT/lib/session_restore.py" --allowlist-check "$BATS_TEST_TMPDIR/real.sql")" || {
        echo "a function in the dump is not on the allowlist: $missing" >&2
        false
    }
    assert_equal "" "$missing"
}

@test "an empty dump and a whitespace-only dump are no-ops, not failures" {
    run_restore ""
    assert_equal "0" "$RC"
    run_restore "   
-- just a comment
"
    assert_equal "0" "$RC"
    assert_equal "1" "$(count_sessions)"
}

# ---- every statement must have performed an allowed INSERT -----------------

@test "a statement that runs but performs no INSERT is rejected" {
    # The module's own usage error is still a usage error.
    run python3 -B "$ROOT/lib/session_restore.py"
    assert_failure
    assert_output --partial "usage:"

    # BEGIN/COMMIT are issued by the module itself, not taken from the dump, so
    # a dump that is only transaction control is refused rather than being a
    # silent no-op.
    run_restore "COMMIT;"
    [ "$RC" -ne 0 ]
}

@test "a statement that only fires a TRANSACTION callback is rejected" {
    run_restore "BEGIN;"
    [ "$RC" -ne 0 ]
    assert_equal "1" "$(count_sessions)"
}

# ---- no bytecode written into the install tree -----------------------------

@test "running the module leaves no __pycache__ behind" {
    find "$ROOT/lib" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    run_restore "INSERT OR REPLACE INTO session VALUES('s1','x','y');"
    [ ! -d "$ROOT/lib/__pycache__" ] || {
        echo "module left a __pycache__ in lib/:" >&2
        find "$ROOT/lib/__pycache__" >&2
        false
    }
}

@test "lib/session.sh invokes the module with -B" {
    # A restore must never try to write into the installed lib directory, which
    # for a Homebrew install is not writable and would fail the restore.
    run grep -c 'python3 -B' "$ROOT/lib/session.sh"
    assert_output "1"
}

# ---- helpers ----------------------------------------------------------------

_kw_accepts() { # the statement's first keyword is INSERT/REPLACE/WITH
    if ! python3 -B "$ROOT/test/helpers/keyword_probe.py" accept "$1"; then
        echo "expected guard to ACCEPT: $1" >&2
        return 1
    fi
}

_kw_rejects() { # the statement's first keyword is anything else
    if python3 -B "$ROOT/test/helpers/keyword_probe.py" accept "$1"; then
        echo "expected guard to REJECT: $1" >&2
        return 1
    fi
}
