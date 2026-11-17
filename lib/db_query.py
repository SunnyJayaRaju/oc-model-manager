#!/usr/bin/env python3
"""Read-only SQL runner for the OpenCode 2.x session queries.

Replaces the string-interpolated `sqlite3 -readonly` calls on the 2.x paths:
the database is opened through a read-only URI and every value a query needs
arrives as a bound parameter (a JSON array on stdin). Whatever a session id
contains, it cannot change the shape of a query.

Stdlib only (sqlite3, json): no PyYAML or jsonschema is needed here, so any
python3 works, resolved by oc_python() in lib/core.sh like the other stdlib
helpers (lib/jsonc.py, lib/session_restore.py).
"""

import json
import sqlite3
import sys
from pathlib import Path


def _fail(message):
    print("db_query.py: " + message, file=sys.stderr)
    raise SystemExit(2)


def main(argv):
    if len(argv) != 3:
        _fail(
            "usage: db_query.py <database> <sql>  (bound parameters arrive as a JSON array on stdin)"
        )
    db_path, sql = Path(argv[1]), argv[2]

    try:
        params = json.load(sys.stdin)
    except ValueError as exc:
        _fail("parameters are not valid JSON: %s" % exc)
    if not isinstance(params, list):
        _fail("parameters must be a JSON array")

    # jq hands parameters through as strings. A numeric parameter must bind as
    # an INTEGER, or SQLite's type ordering (INTEGER < TEXT) silently flips
    # comparisons like "message_count <= 4": against the text '4' the integer
    # 6 compares true and an over-ceiling session slips through a safety gate.
    # Real ids never consist of digits alone (they start with ses_), so this
    # conversion cannot misplace a value.
    params = [
        int(p)
        if isinstance(p, str) and p.lstrip("-").isdigit() and not p.lstrip("-") == ""
        else p
        for p in params
    ]

    if not db_path.is_file():
        _fail("database file not found")
    # Read-only URI: no query on this path can write the database, and a path
    # containing '?' or '#' survives as_uri()'s percent-encoding.
    uri = db_path.resolve().as_uri() + "?mode=ro"
    try:
        conn = sqlite3.connect(uri, uri=True)
    except sqlite3.Error as exc:
        _fail("cannot open the database read-only: %s" % exc)
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.Error as exc:
        _fail("query failed: %s" % exc)
    finally:
        conn.close()

    for row in rows:
        print("\t".join("" if value is None else str(value) for value in row))


if __name__ == "__main__":
    main(sys.argv)
