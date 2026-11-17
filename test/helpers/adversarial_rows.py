#!/usr/bin/env python3
"""Test fixture: session rows with ids no sqlite3 CLI argument could carry.

Usage:
    adversarial_rows.py <database> <session_id>
        insert one session (v2 shape when session_v2 exists, legacy otherwise)
        plus its single user probe message, all values bound.

    adversarial_rows.py --nul <database>
        insert one session whose id contains an embedded NUL byte followed by
        a SQL-injection attempt; only a python-side insert can build that id.
"""

import sqlite3
import sys
import time
import uuid


def is_v2(conn):
    row = conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_v2' LIMIT 1"
    ).fetchone()
    return row is not None


def insert(conn, sid):
    ts = int(time.time() * 1000) if is_v2(conn) else 1000
    msg_id = "adv-" + uuid.uuid4().hex
    if is_v2(conn):
        conn.execute(
            "INSERT INTO session_v2 (id, project_id, slug, directory, version, title,"
            " time_created, time_updated)"
            " VALUES (?, 'proj_adv', 'adv', '/tmp/adv', '1', 'ocprobe-probe', ?, ?)",
            (sid, ts, ts),
        )
        conn.execute(
            "INSERT INTO session_message (id, session_id, type, seq, time_created,"
            " time_updated, data) VALUES (?, ?, 'user', 1, ?, ?, ?)",
            (
                msg_id,
                sid,
                ts,
                ts,
                '{"time":{"created":%d},"text":"Reply with exactly: OK","files":[]}'
                % ts,
            ),
        )
    else:
        conn.execute(
            "INSERT INTO session (id, title, time_created, time_updated)"
            " VALUES (?, 'ocprobe-probe', ?, ?)",
            (sid, ts, ts),
        )
    conn.commit()


def main(argv):
    nul_mode = len(argv) == 3 and argv[1] == "--nul"
    if not nul_mode and len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    db = argv[2] if nul_mode else argv[1]
    sid = None
    if nul_mode:
        sid = "ses_x\x00'; DROP TABLE session_v2;--"
    else:
        sid = argv[2]
    conn = sqlite3.connect(db)
    try:
        insert(conn, sid)
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
