#!/usr/bin/env python3
"""Statement-level enforcement for `ocprobe session restore <file.sql>`.

Run as:  session_restore.py <database> <dump.sql>

A dump is applied one statement at a time inside a single transaction. Two
independent layers decide what is allowed:

  1. A first-keyword guard, applied to every complete statement before it is
     ever handed to sqlite. Unless the statement's first keyword is INSERT,
     REPLACE or WITH it is refused. This does not depend on the authorizer
     being consulted, which matters because whether a given statement produces
     SQLITE_* callbacks at all is a property of the sqlite build, not of this
     code.
  2. A SQLite authorizer, allowing only what a real `ocprobe session backup`
     dump needs. Everything else is refused.

Any refusal, parse error or exception rolls the whole file back, so a rejected
dump leaves the database byte-identical.

This lives in its own module rather than inline in lib/session.sh for one
reason: the set of SQL function names and callbacks SQLite reports is
BUILD-DEPENDENT, and a missing name only shows up on a platform you are not
developing on. That is not hypothetical -- the ubuntu CI runner reports a
SQLITE_FUNCTION callback for the conflict target of `INSERT OR REPLACE`
("replace"), which sqlite 3.54 on macOS does not report at all, so an allowlist
of just {"unistr"} passed every local test and the macOS CI leg while breaking
restore for every Linux user. Keeping the policy here lets the bats suites
assert it on every platform, without depending on what the local sqlite happens
to report.
"""

import re
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

# The only first keywords a dump statement may have. A genuine dump is
# `INSERT INTO t VALUES(...)` rewritten to `INSERT OR REPLACE INTO t VALUES(...)`
# by cmd_session_backup, so INSERT and REPLACE are both required. WITH is
# allowed because it is a legitimate way to write an INSERT, and the authorizer
# still has the final say on everything the statement actually does.
ALLOWED_KEYWORDS = frozenset(("INSERT", "REPLACE", "WITH"))

# Authorizer action codes from sqlite3.h. Spelled out rather than reflected:
# several constants share a value (SQLITE_INSERT and SQLITE_TOOBIG are both 18),
# so building this map with getattr() silently picks the wrong name.
OP_INSERT = 18
OP_TRANSACTION = 22
OP_FUNCTION = 31

# A keyword is a run of ASCII letters. Anything else terminates the scan, so
# "INSERT/**/INTO" cannot be misread as a single identifier.
_KEYWORD_RE = re.compile(r"[A-Za-z]+")

# Characters that may sit between the start of a statement and its first real
# token. Python's str.strip() already removes ASCII whitespace; this adds the
# Unicode spaces a text editor or a re-encoding can introduce, so that
# "\u00a0REINDEX" is not mistaken for an unrecognised statement and, worse, for
# an acceptable one.
_UNICODE_SPACES = "".join(
    chr(cp)
    for cp in (
        0x00A0,  # NO-BREAK SPACE
        0x1680,  # OGHAM SPACE MARK
        0x2000,
        0x2001,
        0x2002,
        0x2003,
        0x2004,
        0x2005,
        0x2006,
        0x2007,
        0x2008,
        0x2009,
        0x200A,
        0x200B,
        0x200C,
        0x200D,
        0x200E,
        0x200F,
        0x2028,  # LINE SEPARATOR
        0x2029,  # PARAGRAPH SEPARATOR
        0x202A,
        0x202B,
        0x202C,
        0x202D,
        0x202E,  # bidi embedding controls
        0x202F,  # NARROW NO-BREAK SPACE
        0x205F,  # MEDIUM MATHEMATICAL SPACE
        0x2060,  # WORD JOINER
        0x3000,  # IDEOGRAPHIC SPACE
        0xFEFF,  # ZERO WIDTH NO-BREAK SPACE / BOM
    )
)


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


def leading_keyword(statement):
    """Return the first SQL keyword of `statement`, upper-cased.

    Strips, in order: a UTF-8 BOM, leading whitespace (ASCII and the Unicode
    spaces listed above), `--` line comments, and balanced `/* */` block
    comments -- repeatedly, because they can be interleaved (`-- a /* b */ c
    REINDEX`).

    Returns "" when the statement contains no keyword at all, which the caller
    must treat as a refusal: there is nothing here that has been shown to be an
    INSERT, so it cannot be allowed. An unterminated `/*` also yields "", since
    the rest of the statement is comment and there is no keyword after it.
    """
    text = statement.lstrip("\ufeff").lstrip()

    while True:
        # Any of the "invisible" characters, anywhere they may have been left.
        text = text.lstrip().lstrip(_UNICODE_SPACES).lstrip()
        if not text:
            return ""
        if text.startswith("--"):
            newline = text.find("\n")
            if newline == -1:
                return ""
            text = text[newline + 1 :]
            continue
        if text.startswith("/*"):
            end = text.find("*/", 2)
            if end == -1:
                # Unterminated: everything after this is comment.
                return ""
            text = text[end + 2 :]
            continue
        break

    match = _KEYWORD_RE.match(text)
    return match.group(0).upper() if match else ""


def statement_is_permitted(statement):
    """True when the statement's first keyword is INSERT, REPLACE or WITH."""
    return leading_keyword(statement) in ALLOWED_KEYWORDS


def is_comment_only(statement):
    """True when `statement` contains no SQL at all -- only comments/whitespace.

    A dump may legitimately carry a header comment. Such a statement must be
    skipped rather than refused, but it must also not be treated as an INSERT,
    so it is reported separately from "has no keyword" (which includes an
    unterminated `/*`, and IS a refusal).
    """
    text = statement.lstrip("\ufeff").lstrip()
    while True:
        text = text.lstrip().lstrip(_UNICODE_SPACES).lstrip()
        if not text:
            return True
        if text.startswith("--"):
            newline = text.find("\n")
            if newline == -1:
                return True
            text = text[newline + 1 :]
            continue
        if text.startswith("/*"):
            end = text.find("*/", 2)
            if end == -1:
                return False  # unterminated: refused, not skipped
            text = text[end + 2 :]
            continue
        return False


def _outside_string_literals(statement):
    """Return `statement` with the contents of quoted literals blanked out.

    Every character inside '...', "..." or `...` becomes a space, keeping the
    quotes themselves so positions still line up. A keyword search over the
    result cannot be fooled by text that is only data -- a message titled
    "DEFAULT VALUES" is a value, not a clause.
    """
    out = list(statement)
    i = 0
    n = len(statement)
    while i < n:
        if statement[i] in ("'", '"', "`"):
            quote = statement[i]
            i += 1
            while i < n:
                if statement[i] == quote:
                    # A doubled quote is an escaped quote, not the end.
                    if i + 1 < n and statement[i + 1] == quote:
                        out[i] = out[i + 1] = " "
                        i += 2
                        continue
                    break
                if statement[i] == "\n":
                    # An unterminated literal cannot be blanked reliably; give
                    # up and let sqlite reject the statement on its own terms.
                    return statement
                out[i] = " "
                i += 1
        i += 1
    return "".join(out)


# `DEFAULT VALUES` is a real INSERT on an allowed table, so both the keyword
# guard and the authorizer wave it through -- and it silently writes a row of
# NULLs over whatever the real value was. A genuine dump never emits it
# (`sqlite3 .mode insert` always writes an explicit VALUES list), so refusing it
# costs nothing. Matched against the statement with string literals blanked, so
# a value that merely reads "DEFAULT VALUES" is not mistaken for the clause.
_DEFAULT_VALUES_RE = re.compile(r"\bDEFAULT\s+VALUES\b", re.IGNORECASE)


def uses_default_values(statement):
    """True when the statement uses the DEFAULT VALUES insert form."""
    return bool(_DEFAULT_VALUES_RE.search(_outside_string_literals(statement)))


class _InsertCounter:
    """Authorizer wrapper that also records whether an allowed INSERT happened.

    A statement that reaches sqlite and completes without causing a single
    allowed-table INSERT has done nothing this module is willing to vouch for --
    whatever it was, it was not a row being restored. Rejecting those closes the
    case where a build routes a statement past the authorizer entirely: the
    keyword guard rejects the obvious shapes, and this rejects anything that
    runs but performs no INSERT.
    """

    def __init__(self):
        self.inserts = 0

    def __call__(self, action, arg1, arg2, db_name, trigger_name):
        if action == OP_INSERT and arg1 in ALLOWED_TABLES:
            self.inserts += 1
        return authorize(action, arg1, arg2, db_name, trigger_name)


def count_allowed_inserts(statement):
    """Run `statement` against a throwaway in-memory database and report how
    many allowed-table INSERTs it performed.

    Exposed for the bats suite. Returns -1 if the statement could not be run at
    all, which the tests read as "no INSERT happened".
    """
    counter = _InsertCounter()
    con = sqlite3.connect(":memory:", isolation_level=None)
    try:
        con.set_authorizer(counter)
        try:
            con.execute(statement)
        except Exception:
            return -1
    finally:
        con.set_authorizer(None)
        con.close()
    return counter.inserts


def restore(db_path, dump_path):
    """Apply dump_path to db_path. Returns 0 on success, 1 on any refusal."""
    con = sqlite3.connect(db_path, isolation_level=None)
    try:
        # Set the busy timeout before the authorizer goes on; afterwards a
        # PRAGMA would be refused like any other statement.
        con.execute("PRAGMA busy_timeout=10000")
        counter = _InsertCounter()
        con.set_authorizer(counter)
        try:
            con.execute("BEGIN IMMEDIATE")
            pending = ""
            with open(dump_path, encoding="utf-8-sig") as handle:
                # utf-8-sig, not utf-8: a dump saved by an editor that adds a
                # BOM would otherwise have its first statement begin with U+FEFF.
                # The keyword guard also strips a BOM, so either alone is enough;
                # both together mean neither a saved file nor an exotic prefix
                # can hide a statement.
                for line in handle:
                    pending += line
                    # Accumulate rather than treating a line as a statement: a
                    # value containing a newline spans lines, and how a dump
                    # encodes one is sqlite-build dependent.
                    if not sqlite3.complete_statement(pending):
                        continue
                    statement = pending.strip()
                    pending = ""
                    if not statement or is_comment_only(statement):
                        # A dump may carry a header comment; there is nothing to
                        # apply and nothing to refuse.
                        continue
                    # Layer 1: the first keyword, before sqlite sees anything.
                    keyword = leading_keyword(statement)
                    if keyword not in ALLOWED_KEYWORDS:
                        raise PermissionError(
                            "statement starts with %s, only INSERT/REPLACE/WITH "
                            "may appear in a dump: %r"
                            % (keyword or "<nothing>", statement[:120])
                        )
                    if uses_default_values(statement):
                        # An allowed INSERT, so the authorizer allows it, but it
                        # writes NULLs over real values and a dump never needs it.
                        raise PermissionError(
                            "DEFAULT VALUES may not appear in a dump: %r"
                            % statement[:120]
                        )
                    # Layer 2: the authorizer, and the requirement that the
                    # statement actually did the thing a dump does.
                    before = counter.inserts
                    # execute(), never executescript(): the latter commits
                    # implicitly and would defeat the rollback.
                    con.execute(statement)
                    if counter.inserts == before:
                        raise PermissionError(
                            "statement performed no INSERT into an allowed table "
                            "and so restored nothing: %r" % statement[:120]
                        )
            if pending.strip() and not is_comment_only(pending):
                # Trailing text that never closed is not a statement we can
                # vouch for. A trailing comment is the other case: it is not
                # SQL, so there is nothing to apply, but it is not suspicious
                # either -- a dump ending in a comment is just a dump with a
                # footer.
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
