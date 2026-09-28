#!/usr/bin/env python3
"""Statement-level enforcement for `ocprobe session restore <file.sql>`.

Run as:  session_restore.py <database> <dump.sql>

A dump is applied one statement at a time inside a single transaction, with a
SQLite authorizer allowing only what a real `ocprobe session backup` dump needs.
Everything else is refused, and any refusal, parse error or exception rolls the
whole file back, so a rejected dump leaves the database byte-identical.

This lives in its own module rather than inline in lib/session.sh for one
reason: the set of SQL function names SQLite reports is BUILD-DEPENDENT, and a
missing name only shows up on a platform you are not developing on. That is not
hypothetical -- the ubuntu CI runner reports a SQLITE_FUNCTION callback for the
conflict target of `INSERT OR REPLACE` ("replace"), which sqlite 3.54 on macOS
does not report at all, so an allowlist of just {"unistr"} passed every local
test and the macOS CI leg while breaking restore for every Linux user. Keeping
the policy here lets test/unit/session_restore_security.bats assert the
allowlist itself, on every platform, without depending on what the local
sqlite happens to report.
"""

import sqlite3
import sys

# The exact tables `cmd_session_backup` writes. Confirmed by generating a real
# dump: `.mode insert` over session, message, part and todo, one INSERT OR
# REPLACE per row.
ALLOWED_TABLES = frozenset(("session", "message", "part", "todo"))

# SQL function names a genuine dump can legitimately contain. All are pure
# string/encoding helpers; none can read a file, write a file, or touch the
# database beyond the row being inserted.
#   unistr  - sqlite >= 3.42 escapes a newline inside a value as
#             unistr('...\u000a...'), so most current dumps use it.
#   replace - some sqlite builds report the conflict target of
#             INSERT OR REPLACE as a SQLITE_FUNCTION callback rather than
#             folding it into SQLITE_INSERT. Without this, a legitimate
#             backup cannot be restored at all on those builds.
#   char    - older builds may emit char(10) for a newline instead of unistr.
# Kept as a named set with the reasoning inline, because getting it wrong breaks
# restore in a way that is invisible until someone runs it on that platform.
ALLOWED_FUNCS = frozenset(("unistr", "replace", "char"))

# Authorizer action codes from sqlite3.h. Spelled out rather than reflected:
# several constants share a value (SQLITE_INSERT and SQLITE_TOOBIG are both 18),
# so building this map with getattr() silently picks the wrong name.
OP_INSERT = 18
OP_TRANSACTION = 22
OP_FUNCTION = 31


def authorize(action, arg1, arg2, db_name, trigger_name):
    """Return SQLITE_OK for a permitted action, SQLITE_DENY otherwise.

    Denying by default is the point: ATTACH/DETACH, DROP/DELETE/UPDATE/ALTER,
    any CREATE (which surfaces as an INSERT into sqlite_master, so the table
    allowlist rejects it), every PRAGMA, every other function, and all reads
    (SQLITE_READ / SQLITE_SELECT, so INSERT..SELECT cannot copy out of
    sqlite_master or another table) are all refused.
    """
    if action == OP_INSERT:
        return sqlite3.SQLITE_OK if arg1 in ALLOWED_TABLES else sqlite3.SQLITE_DENY
    if action == OP_TRANSACTION:
        return sqlite3.SQLITE_OK
    if action == OP_FUNCTION:
        # arg2 carries the function name. Python has passed both the bare str
        # and a (name, narg) tuple across versions, so accept either shape.
        name = arg2[0] if isinstance(arg2, (tuple, list)) else arg2
        return sqlite3.SQLITE_OK if name in ALLOWED_FUNCS else sqlite3.SQLITE_DENY
    return sqlite3.SQLITE_DENY


def _function_name(arg2):
    """Normalize the two shapes arg2 arrives in, for tests and for authorize()."""
    return arg2[0] if isinstance(arg2, (tuple, list)) else arg2


def restore(db_path, dump_path):
    """Apply dump_path to db_path. Returns 0 on success, 1 on any refusal."""
    con = sqlite3.connect(db_path, isolation_level=None)
    try:
        # Set the busy timeout before the authorizer goes on; afterwards a
        # PRAGMA would be refused like any other statement.
        con.execute("PRAGMA busy_timeout=10000")
        con.set_authorizer(authorize)
        try:
            con.execute("BEGIN IMMEDIATE")
            pending = ""
            with open(dump_path, encoding="utf-8") as handle:
                for line in handle:
                    pending += line
                    # Accumulate rather than treating a line as a statement: a
                    # value containing a newline spans lines, and how a dump
                    # encodes one is sqlite-build dependent.
                    if not sqlite3.complete_statement(pending):
                        continue
                    statement = pending.strip()
                    pending = ""
                    if statement:
                        # execute(), never executescript(): the latter commits
                        # implicitly and would defeat the rollback.
                        con.execute(statement)
            if pending.strip():
                # Trailing text that never closed is not a statement we can
                # vouch for.
                raise ValueError(
                    "trailing text is not a complete statement: %r" % pending[:120]
                )
            con.execute("COMMIT")
        except Exception as exc:  # noqa: BLE001 - any failure must roll back
            try:
                con.execute("ROLLBACK")
            except Exception:
                pass
            sys.stderr.write("restore failed: %s: %s\n" % (type(exc).__name__, exc))
            return 1
    finally:
        con.set_authorizer(None)
        con.close()
    return 0


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: session_restore.py <database> <dump.sql>\n")
        return 2
    return restore(argv[1], argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
