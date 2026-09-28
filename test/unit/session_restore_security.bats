#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/session_restore_security.bats — statement-level enforcement for
# `ocprobe session restore <file.sql>`.
#
# The previous gate was line-prefix based (lib/session.sh: it accepted any line
# whose first keyword was INSERT/BEGIN/COMMIT/PRAGMA). SQLite executes EVERY
# semicolon-separated statement on a line, so a line beginning with INSERT
# could carry a second statement that the filter never looked at:
#
#   INSERT INTO session VALUES('a','x',1,2); DROP TABLE session;
#
# passed the filter and destroyed the table, and
#
#   INSERT ...; ATTACH DATABASE '/tmp/x.db' AS e; CREATE TABLE e.t(x); INSERT INTO e.t VALUES(42);
#
# wrote an attacker-controlled file on the host. Line-prefix filtering cannot be
# made safe, so restore now enforces at STATEMENT level.
#
# Every case below asserts three things, not one:
#   1. the restore FAILS (non-zero)
#   2. the database is byte-identical afterwards (sha256), so nothing committed
#   3. no file was created at the watched path
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
  db_path: "$BATS_TEST_TMPDIR/oc.db"
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/sb"
retention:
  history_limit: 5000
logging:
  level: info
  format: text
  file_enabled: false
EOF
    cat >"$BATS_TEST_TMPDIR/opencode.json" <<'JSON'
{"provider":{}}
JSON
    load_config >/dev/null

    DUMP="$BATS_TEST_TMPDIR/dump.sql"
    DB="$BATS_TEST_TMPDIR/oc.db"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# The four tables a genuine `ocprobe session backup` dump writes, plus `marker`
# as a stand-in for "any other table in the DB".
_fresh_db() {
    # Idempotent: several tests need a pristine DB more than once in one test.
    sqlite3 "$DB" <<'SQL'
DROP TABLE IF EXISTS session; DROP TABLE IF EXISTS message;
DROP TABLE IF EXISTS part;    DROP TABLE IF EXISTS todo;
DROP TABLE IF EXISTS marker;  DROP TABLE IF EXISTS other;
CREATE TABLE session   (id TEXT PRIMARY KEY, title TEXT, time_created INTEGER, time_updated INTEGER);
CREATE TABLE message   (id INTEGER PRIMARY KEY, session_id TEXT, time_created INTEGER);
CREATE TABLE part      (id INTEGER PRIMARY KEY, session_id TEXT, message_id INTEGER, time_created INTEGER, data TEXT);
CREATE TABLE todo      (id INTEGER PRIMARY KEY, session_id TEXT);
CREATE TABLE marker    (x);
CREATE TABLE other     (y);
INSERT INTO session VALUES('victim','a real conversation',1,1);
INSERT INTO marker  VALUES('keepme');
SQL
}

_db_hash()    { shasum -a 256 "$DB" | awk '{print $1}'; }
_schema_of()  { sqlite3 "$DB" "SELECT COALESCE(group_concat(name),'') FROM (SELECT name FROM sqlite_master ORDER BY name);"; }
_rows_of()    { sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM session)||'/'||(SELECT COUNT(*) FROM marker)||'/'||(SELECT COUNT(*) FROM other);"; }

# _reject <label> <dump body> [path-that-must-not-be-created]
_reject() {
    local label="$1" body="$2" watch="${3:-}"
    _fresh_db
    local h_before s_before r_before
    h_before=$(_db_hash); s_before=$(_schema_of); r_before=$(_rows_of)
    [ -n "$watch" ] && rm -f "$watch"
    printf '%b' "$body" >"$DUMP"

    run cmd_session_restore "$DUMP"

    if [ "$status" -eq 0 ]; then
        printf '  BYPASS (restore reported success): %s\n' "$label" >&2
        return 1
    fi
    if [ "$(_db_hash)" != "$h_before" ]; then
        printf '  DB MUTATED: %s\n' "$label" >&2
        return 1
    fi
    [ "$(_schema_of)" = "$s_before" ] || { printf '  SCHEMA CHANGED: %s\n' "$label" >&2; return 1; }
    [ "$(_rows_of)" = "$r_before" ]   || { printf '  ROWS CHANGED: %s\n' "$label" >&2; return 1; }
    if [ -n "$watch" ] && [ -e "$watch" ]; then
        printf '  FILE CREATED at %s: %s\n' "$watch" "$label" >&2
        return 1
    fi
    return 0
}

# _no_damage <label> <dump body> [path-that-must-not-be-created]
# For constructs that are legitimate-but-suspicious: a trailing comment after a
# valid INSERT cannot execute anything, so restore may legitimately succeed.
# What must hold is that nothing harmful happened.
_no_damage() {
    local label="$1" body="$2" watch="${3:-}"
    _fresh_db
    local s_before others_before
    s_before=$(_schema_of)
    others_before=$(sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM marker)||'/'||(SELECT COUNT(*) FROM other);")
    [ -n "$watch" ] && rm -f "$watch"
    printf '%b' "$body" >"$DUMP"

    run cmd_session_restore "$DUMP"

    # The INSERT is legitimate, so the session row count is expected to change.
    # What must hold: the schema survives, the tables that are NOT in the dump
    # allowlist are untouched, the pre-existing row survives, and no new file
    # appears anywhere.
    [ "$(_schema_of)" = "$s_before" ] || { printf '  SCHEMA DAMAGED: %s\n' "$label" >&2; return 1; }
    [ "$(sqlite3 "$DB" "SELECT (SELECT COUNT(*) FROM marker)||'/'||(SELECT COUNT(*) FROM other);")" = "$others_before" ] || {
        printf '  NON-ALLOWLIST TABLE TOUCHED: %s\n' "$label" >&2; return 1; }
    [ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM session WHERE id='victim';")" = "1" ] || {
        printf '  PRE-EXISTING ROW LOST: %s\n' "$label" >&2; return 1; }
    if [ -n "$watch" ] && [ -e "$watch" ]; then
        printf '  FILE CREATED: %s\n' "$label" >&2; return 1
    fi
    return 0
}

# ---- The six cases from the audit ------------------------------------------

@test "restore: INSERT followed by DROP TABLE session is rejected" {
    _reject "INSERT; DROP TABLE session" \
        'INSERT OR REPLACE INTO session VALUES("a","x",1,2); DROP TABLE session;\n'
}

@test "restore: INSERT followed by DELETE FROM session is rejected" {
    _reject "INSERT; DELETE FROM session" \
        'INSERT OR REPLACE INTO session VALUES("a","x",1,2); DELETE FROM session;\n'
}

@test "restore: INSERT followed by ALTER TABLE RENAME is rejected" {
    _reject "INSERT; ALTER TABLE RENAME" \
        'INSERT OR REPLACE INTO session VALUES("a","x",1,2); ALTER TABLE session RENAME TO pwned;\n'
}

@test "restore: INSERT followed by INSERT into an unrelated table is rejected" {
    _reject "INSERT; INSERT marker" \
        'INSERT OR REPLACE INTO session VALUES("a","x",1,2); INSERT INTO marker VALUES("hacked");\n'
}

@test "restore: INSERT followed by DROP of an unrelated table is rejected" {
    _reject "INSERT; DROP marker" \
        'INSERT OR REPLACE INTO session VALUES("a","x",1,2); DROP TABLE marker;\n'
}

@test "restore: INSERT followed by ATTACH + CREATE + INSERT creates no file" {
    _reject "INSERT; ATTACH writes a file" \
        "INSERT OR REPLACE INTO session VALUES(\"a\",\"x\",1,2); ATTACH DATABASE \"$BATS_TEST_TMPDIR/exfil.db\" AS e; CREATE TABLE e.t(x); INSERT INTO e.t VALUES(42);\n" \
        "$BATS_TEST_TMPDIR/exfil.db"
}

# ---- VACUUM INTO ----------------------------------------------------------

@test "restore: VACUUM INTO is rejected" {
    _reject "VACUUM INTO" \
        "VACUUM INTO '$BATS_TEST_TMPDIR/vac.db';\n" \
        "$BATS_TEST_TMPDIR/vac.db"
}

@test "restore: VACUUM INTO inside a transaction is rejected" {
    _reject "BEGIN; VACUUM INTO; COMMIT" \
        "BEGIN;\nVACUUM INTO '$BATS_TEST_TMPDIR/vac2.db';\nCOMMIT;\n" \
        "$BATS_TEST_TMPDIR/vac2.db"
}

# ---- PRAGMA ---------------------------------------------------------------

@test "restore: PRAGMA writable_schema is rejected" {
    _reject "PRAGMA writable_schema" 'PRAGMA writable_schema=1;\n'
}

@test "restore: other PRAGMAs are rejected" {
    _reject "PRAGMA journal_mode" 'PRAGMA journal_mode=OFF;\n'
    _reject "PRAGMA foreign_keys" 'PRAGMA foreign_keys=OFF;\n'
    _reject "PRAGMA key"           'PRAGMA rekey="x";\n'
}

# ---- Functions ------------------------------------------------------------

@test "restore: SELECT load_extension() is rejected" {
    _reject "load_extension" "SELECT load_extension('/tmp/nope.so');\n"
}

@test "restore: an arbitrary SQL function is rejected" {
    _reject "randomblob() is fine to deny" \
        "INSERT OR REPLACE INTO session VALUES('a', hex(randomblob(4)), 1, 2);\n"
}

# ---- INSERT ... SELECT (reading other tables / schema) --------------------

@test "restore: INSERT..SELECT from sqlite_master is rejected" {
    _reject "INSERT..SELECT sqlite_master" \
        "INSERT INTO session SELECT name,NULL,0,0 FROM sqlite_master;\n"
}

@test "restore: INSERT..SELECT from another table is rejected" {
    _reject "INSERT..SELECT other" \
        "INSERT INTO session SELECT y,NULL,0,0 FROM other;\n"
}

@test "restore: WITH .. INSERT is rejected" {
    _reject "WITH..INSERT" \
        "WITH c(x) AS (SELECT 1) INSERT INTO session SELECT x,NULL,0,0 FROM c;\n"
}

# ---- REPLACE / other tables ----------------------------------------------

@test "restore: REPLACE INTO a table outside the allowlist is rejected" {
    _reject "REPLACE INTO other" "REPLACE INTO other VALUES('hacked');\n"
    _reject "REPLACE INTO marker" "REPLACE INTO marker VALUES('hacked');\n"
}

# ---- DDL ------------------------------------------------------------------

@test "restore: CREATE TABLE / VIEW / TRIGGER / INDEX are rejected" {
    _reject "CREATE TABLE"  "CREATE TABLE zzz(a);\n"
    _reject "CREATE VIEW"   "CREATE VIEW v AS SELECT 1;\n"
    _reject "CREATE TRIGGER" "CREATE TRIGGER tr AFTER INSERT ON session BEGIN SELECT 1; END;\n"
    _reject "CREATE INDEX"  "CREATE INDEX ix ON session(title);\n"
}

# ---- ATTACH / DETACH ------------------------------------------------------

@test "restore: ATTACH and DETACH are rejected" {
    _reject "ATTACH" "ATTACH DATABASE '$BATS_TEST_TMPDIR/att.db' AS e;\n" "$BATS_TEST_TMPDIR/att.db"
    _reject "DETACH" "DETACH DATABASE main;\n"
}

# ---- DROP / DELETE / UPDATE / ALTER as standalone statements --------------

@test "restore: standalone DROP / DELETE / UPDATE / ALTER are rejected" {
    _reject "DROP TABLE"  "DROP TABLE session;\n"
    _reject "DELETE"      "DELETE FROM session;\n"
    _reject "UPDATE"      "UPDATE session SET title='x';\n"
    _reject "ALTER TABLE" "ALTER TABLE session ADD COLUMN zzz TEXT;\n"
}

# ---- Tables outside the allowlist ----------------------------------------

@test "restore: INSERT into a table not in the allowlist is rejected" {
    _reject "INSERT other" "INSERT INTO other VALUES('hacked');\n"
    _reject "INSERT marker" "INSERT INTO marker VALUES('hacked');\n"
}

# ---- Case / whitespace / comment tricks ----------------------------------

@test "restore: case and whitespace tricks are rejected" {
    _reject "lowercase insert + drop"  'insert into session values("a","x",1,2); drop table session;\n'
    _reject "MiXeD case"                'InSeRt InTo session VaLuEs("a","x",1,2); DrOp TaBlE session;\n'
    _reject "leading tabs"              '\t\tINSERT INTO session VALUES("a","x",1,2); DROP TABLE session;\n'
    _reject "leading spaces"            '    INSERT INTO session VALUES("a","x",1,2); DROP TABLE session;\n'
    _reject "unicode whitespace (NBSP)" "$(printf '\xc2\xa0INSERT INTO session VALUES("a","x",1,2); DROP TABLE session;\n')"
    _reject "unicode whitespace (ideographic)" "$(printf '\xe3\x80\x80INSERT INTO session VALUES("a","x",1,2); DROP TABLE session;\n')"
}

@test "restore: a comment after a valid INSERT cannot smuggle a statement" {
    # These two are NOT required to be rejected: a trailing comment is inert, so
    # a plain valid INSERT plus a comment is a legitimate dump. The assertion that
    # matters is that nothing was damaged.
    _no_damage "trailing -- comment"  'INSERT INTO session VALUES("a","x",1,2); -- DROP TABLE session;\n'
    _no_damage "inline block comment" 'INSERT INTO session VALUES("a","x",1,2); /* DROP TABLE session; */\n'
}

@test "restore: a comment cannot hide a real statement" {
    _reject "block comment then stmt"     '/* lead */ DROP TABLE session;\n'
    _reject "unterminated block comment"  'INSERT INTO session VALUES("a","x",1,2);\n/* unterminated\n'
    _reject "comment then attach"         "-- lead\nATTACH DATABASE '$BATS_TEST_TMPDIR/x.db' AS e;\n" "$BATS_TEST_TMPDIR/x.db"
}

@test "restore: a statement hidden after a newline inside a string is handled" {
    # A newline inside a string literal must not split one INSERT into two
    # statements, and must not let a following DROP through either.
    _reject "newline inside string literal" \
        "INSERT OR REPLACE INTO part VALUES(1,'s',1,1,'line1\nline2');\nDROP TABLE session;\n"
}

# ---- The authorizer policy itself -------------------------------------------
# Asserted directly, and on every platform, because what SQLite REPORTS to an
# authorizer is build-dependent. An allowlist of just {"unistr"} passed every
# local test and the macOS CI leg, because sqlite 3.54 never reports the
# conflict target of INSERT OR REPLACE as a function -- and then the ubuntu
# runner, whose sqlite does report it, refused every legitimate restore with
# "not authorized to use function: replace". Testing the policy directly means
# the macOS leg catches that from now on.

@test "the authorizer allowlist covers every function a real dump can need" {
    run python3 - "$BATS_TEST_DIRNAME/../../lib/session_restore.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sr", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

# Everything `sqlite3 .mode insert` can legitimately emit. unistr is how a
# newer build escapes a newline, char is how an older one might, and replace is
# the conflict target some builds report for INSERT OR REPLACE. A literal
# newline needs no function at all.
required = {"unistr", "char", "replace"}
missing = required - m.ALLOWED_FUNCS
if missing:
    print("MISSING from ALLOWED_FUNCS: %s" % sorted(missing))
    sys.exit(1)

# And nothing dangerous may be in it.
forbidden = {"load_extension", "readfile", "writefile", "edit", "eval",
             "getcsv", "fts3_tokenizer", "printf", "random", "hex"}
leaked = forbidden & m.ALLOWED_FUNCS
if leaked:
    print("FORBIDDEN in ALLOWED_FUNCS: %s" % sorted(leaked))
    sys.exit(1)

# The allowlist must stay small: every extra name is more surface.
if len(m.ALLOWED_FUNCS) > 4:
    print("ALLOWED_FUNCS has grown to %d entries: %s"
          % (len(m.ALLOWED_FUNCS), sorted(m.ALLOWED_FUNCS)))
    sys.exit(1)
PY
    assert_success
    refute_output --partial "MISSING"
    refute_output --partial "FORBIDDEN"
    refute_output --partial "grown"
}

@test "the authorizer denies everything outside the documented allowlists" {
    # Drive authorize() directly with every action code and argument shape, so
    # this asserts policy rather than whatever the local sqlite reports.
    run python3 - "$BATS_TEST_DIRNAME/../../lib/session_restore.py" <<'PY'
import importlib.util, sqlite3, sys
spec = importlib.util.spec_from_file_location("sr", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
OK, DENY = sqlite3.SQLITE_OK, sqlite3.SQLITE_DENY
fails = []

def want(label, got, expected):
    if got != expected:
        fails.append("%s: got %s want %s" % (label, got, expected))

# INSERT: only the four backup tables.
for tbl in ("session", "message", "part", "todo"):
    want("INSERT " + tbl, m.authorize(18, tbl, None, "main", None), OK)
for tbl in ("sqlite_master", "other", "marker", "temp.session", "PRAGMA_table"):
    want("INSERT " + tbl, m.authorize(18, tbl, None, "main", None), DENY)

# TRANSACTION: allowed, so the module owns BEGIN/COMMIT.
want("TRANSACTION", m.authorize(22, "BEGIN", None, "main", None), OK)

# FUNCTIONS: allowed for the documented set, denied otherwise, in BOTH arg2
# shapes python has used across versions.
for name in sorted(m.ALLOWED_FUNCS):
    want("FUNC str " + name, m.authorize(31, None, name, "main", None), OK)
    want("FUNC tuple " + name, m.authorize(31, None, (name, 1), "main", None), OK)
for name in ("load_extension", "randomblob", "upper", "sqlite_version", "json"):
    want("FUNC str " + name, m.authorize(31, None, name, "main", None), DENY)
    want("FUNC tuple " + name, m.authorize(31, None, (name, 1), "main", None), DENY)

# Everything else denied outright.
for code, label in ((1, "CREATE_INDEX"), (2, "CREATE_TABLE"), (7, "CREATE_TRIGGER"),
                    (8, "CREATE_VIEW"), (9, "DELETE"), (10, "DROP_INDEX"),
                    (11, "DROP_TABLE"), (16, "DROP_TRIGGER"), (19, "PRAGMA"),
                    (20, "READ"), (21, "SELECT"), (23, "UPDATE"), (24, "ATTACH"),
                    (25, "DETACH"), (26, "ALTER_TABLE"), (29, "CREATE_VTABLE"),
                    (30, "DROP_VTABLE"), (32, "SAVEPOINT"), (33, "RECURSIVE")):
    want(label, m.authorize(code, "session", "col", "main", None), DENY)

if fails:
    print("\n".join(fails))
    sys.exit(1)
PY
    assert_success
}

# ---- Behaviour that must be preserved ------------------------------------

@test "restore: usage error with no argument" {
    _fresh_db
    run cmd_session_restore
    assert_failure
    assert_output --partial "usage: ocprobe session restore"
}

@test "restore: missing file error" {
    _fresh_db
    run cmd_session_restore "$BATS_TEST_TMPDIR/nope.sql"
    assert_failure
    assert_output --partial "no such file"
}

@test "restore: a legitimate dump restores byte-exactly, values and all" {
    _fresh_db
    local title data
    title="title with
a NEWLINE; a semicolon; a quote '' and -- dashes and /* block */ and emoji 🎉"
    data="part data
newline; semicolon; ''quote''; -- dash; emoji 🚀 and \t a tab"
    sqlite3 "$DB" <<SQL
INSERT INTO session VALUES('ses_r','$title',10,20);
INSERT INTO message VALUES(1,'ses_r',11);
INSERT INTO part VALUES(1,'ses_r',1,12,'$data');
INSERT INTO todo VALUES(1,'ses_r');
SQL

    # Produce the dump exactly the way `ocprobe session backup` does.
    local dump="$BATS_TEST_TMPDIR/real.sql"
    {
        echo ".mode insert session";   echo "SELECT * FROM session WHERE id='ses_r';"
        echo ".mode insert message";   echo "SELECT * FROM message WHERE session_id='ses_r' ORDER BY time_created;"
        echo ".mode insert part";      echo "SELECT * FROM part WHERE session_id='ses_r' ORDER BY time_created;"
        echo ".mode insert todo";      echo "SELECT * FROM todo WHERE session_id='ses_r';"
    } | sqlite3 -readonly "$DB" >"$dump"
    "${OCPROBE_SED_INPLACE[@]}" 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$dump"
    grep -q "INSERT OR REPLACE INTO session" "$dump" || {
        echo "fixture is not shaped like a real backup dump" >&2; false; }
    # The dump must really exercise the hard cases, or this test proves nothing.
    # NOTE: how a newline inside a value is escaped is sqlite-build specific --
    # sqlite 3.54 (macOS) writes unistr('...\\u000a...'), while the ubuntu
    # runner's build writes the newline literally. Both are valid dumps and the
    # restore handles both, so this asserts the portable properties: one
    # INSERT per allowlisted table, and the hostile characters still present.
    local t
    for t in session message part todo; do
        local n; n=$(grep -c "INSERT OR REPLACE INTO $t " "$dump")
        [ "$n" -ge 1 ] || {
            echo "dump has no INSERT OR REPLACE INTO $t -- not a backup-shaped dump" >&2
            false
        }
    done
    grep -q "semicolon" "$dump" || { echo "dump lost the semicolon" >&2; false; }
    grep -q -- "--" "$dump"   || { echo "dump lost the -- dashes" >&2; false; }

    # Compare against what SQLite actually STORED. The fixture's '' inside a
    # SQL literal collapses to a single quote, so hand-writing the expectation
    # would be asserting the wrong thing; round-trip fidelity is the real claim.
    local stored_title stored_data
    stored_title=$(sqlite3 "$DB" "SELECT title FROM session WHERE id='ses_r';")
    stored_data=$(sqlite3 "$DB" "SELECT data FROM part WHERE id=1;")
    [[ "$stored_title" == *$'\n'* ]] || { echo "stored title has no newline" >&2; false; }
    [[ "$stored_title" == *";"* ]]     || { echo "stored title has no semicolon" >&2; false; }

    # Wipe, then restore.
    sqlite3 "$DB" "DELETE FROM session; DELETE FROM message; DELETE FROM part; DELETE FROM todo;"
    assert_equal "0/1/0" "$(_rows_of)"   # marker keeps its seeded row

    run cmd_session_restore "$dump"
    assert_success
    assert_output --partial "restored from"

    # Byte-exact round trip, including the newline-bearing values.
    local got_title got_data
    got_title=$(sqlite3 "$DB" "SELECT title FROM session WHERE id='ses_r';")
    got_data=$(sqlite3 "$DB" "SELECT data FROM part WHERE id=1;")
    assert_equal "$stored_title" "$got_title"
    assert_equal "$stored_data"  "$got_data"
    assert_equal "1/1/0" "$(_rows_of)"   # ses_r restored, marker untouched, other empty
}

@test "restore: a dump with a LITERAL newline in a value round-trips" {
    # `sqlite3 .mode insert` escapes a newline differently depending on the
    # sqlite build: some emit unistr('...\\u000a...') on one line, others write
    # the newline literally so the string literal spans lines. The ubuntu CI
    # runner uses the latter. Both must restore byte-exactly, and the second
    # shape only works if the statement splitter accumulates lines instead of
    # treating each line as a statement.
    _fresh_db
    local title data
    title="first line
second line; with a semicolon and a ''quote''"
    data="payload
across lines; ''quoted''"
    sqlite3 "$DB" <<SQL
INSERT INTO session VALUES('ses_n','$title',10,20);
INSERT INTO message VALUES(1,'ses_n',11);
INSERT INTO part VALUES(1,'ses_n',1,12,'$data');
INSERT INTO todo VALUES(1,'ses_n');
SQL
    local stored_title stored_data
    stored_title=$(sqlite3 "$DB" "SELECT title FROM session WHERE id='ses_n';")
    stored_data=$(sqlite3 "$DB" "SELECT data FROM part WHERE id=1;")
    [[ "$stored_title" == *$'\n'* ]] || {
        echo "stored title has no newline; fixture is wrong" >&2; false; }

    # Build the dump with sqlite's own quote() so the SQL is valid by
    # construction on any build, then turn the escaped newline inside the string
    # literal into a REAL newline. That is the shape the ubuntu runner emits.
    local dump="$BATS_TEST_TMPDIR/literal.sql"
    local sid st sd
    sid=$(sqlite3 :memory: "SELECT quote('ses_n');")
    st=$(sqlite3 :memory: "SELECT quote('$(printf '%s' "$stored_title" | sed "s/'/''/g")');")
    sd=$(sqlite3 :memory: "SELECT quote('$(printf '%s' "$stored_data" | sed "s/'/''/g")');")
    {
        printf 'INSERT OR REPLACE INTO session VALUES(%s,%s,10,20);\n' "$sid" "$st"
        printf 'INSERT OR REPLACE INTO message VALUES(1,%s,11);\n' "$sid"
        printf 'INSERT OR REPLACE INTO part VALUES(1,%s,1,12,%s);\n' "$sid" "$sd"
        printf 'INSERT OR REPLACE INTO todo VALUES(1,%s);\n' "$sid"
    } >"$dump"

    # Convert the backslash-n escape INSIDE the string literals into real
    # newlines, so the first statement physically spans two lines.
    python3 - "$dump" <<'PYEOF'
import sys
p = sys.argv[1]
lines = open(p).read().split("\n")
out = []
for line in lines:
    if not line:
        continue
    # Only inside a quoted literal: these dumps have no other backslashes.
    if "'" in line and "\\n" in line:
        line = line.replace("\\n", "\n")
    out.append(line)
open(p, "w").write("\n".join(out) + "\n")
PYEOF

    # The statement must genuinely span lines, or this proves nothing.
    [ "$(wc -l <"$dump" | tr -d ' ')" -gt 4 ] || {
        echo "fixture did not produce a multi-line statement ($(wc -l <"$dump" | tr -d ' ') lines)" >&2
        false
    }

    sqlite3 "$DB" "DELETE FROM session; DELETE FROM message; DELETE FROM part; DELETE FROM todo;"
    run cmd_session_restore "$dump"
    assert_success
    assert_output --partial "restored from"
    assert_equal "$stored_title" "$(sqlite3 "$DB" "SELECT title FROM session WHERE id='ses_n';")"
    assert_equal "$stored_data"  "$(sqlite3 "$DB" "SELECT data FROM part WHERE id=1;")"
}

@test "restore: pre-restore backup is created and a backup failure aborts cleanly" {
    _fresh_db
    printf 'INSERT OR REPLACE INTO session VALUES("a","x",1,2);\n' >"$DUMP"
    run cmd_session_restore "$DUMP"
    assert_success
    run ls -1 "$BATS_TEST_TMPDIR/sb"
    assert_success
    assert_output --partial "opencode.db.pre-restore-"

    # Now make the backup directory impossible to create.
    _fresh_db
    printf 'INSERT OR REPLACE INTO session VALUES("b","y",1,2);\n' >"$DUMP"
    printf 'not a directory' >"$BATS_TEST_TMPDIR/blocked"
    sed -i.bak "s|backup_dir: .*|backup_dir: \"$BATS_TEST_TMPDIR/blocked/nested\"|" "$OCPROBE_CONFIG_OVERRIDE"
    local before; before=$(_db_hash)
    run cmd_session_restore "$DUMP"
    assert_failure
    assert_output --partial "cannot create backup directory"
    assert_equal "$before" "$(_db_hash)"
}

@test "restore: success logs 'restored from', failure does not" {
    _fresh_db
    printf 'INSERT OR REPLACE INTO session VALUES("a","x",1,2);\n' >"$DUMP"
    run cmd_session_restore "$DUMP"
    assert_output --partial "restored from"

    _fresh_db
    printf 'DROP TABLE session;\n' >"$DUMP"
    run cmd_session_restore "$DUMP"
    refute_output --partial "restored from"
}

@test "restore: a plain INSERT ... VALUES is still accepted (busy timeout still applied)" {
    _fresh_db
    printf 'INSERT OR REPLACE INTO session VALUES("a","x",1,2);\nINSERT OR REPLACE INTO message VALUES(1,"a",1);\n' >"$DUMP"
    run cmd_session_restore "$DUMP"
    assert_success
    assert_equal "2/1/0" "$(_rows_of)"
}
