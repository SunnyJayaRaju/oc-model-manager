#!/usr/bin/env python3
"""Probe the first-keyword guard in lib/session_restore.py.

Prints nothing. Exits 0 if the guard ACCEPTS the given statement, 1 if it
rejects. Used by test/unit/session_restore_keyword_guard.bats so the guard can
be asserted statement by statement without running a whole restore.

Usage: keyword_probe.py accept <statement>
       keyword_probe.py count <statement>   # prints the INSERT count observed
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
MODULE = os.path.join(HERE, "..", "..", "lib", "session_restore.py")

spec = importlib.util.spec_from_file_location("session_restore", MODULE)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: keyword_probe.py accept|count <statement>\n")
        return 2
    action, statement = argv[1], argv[2]
    if action == "accept":
        return 0 if mod.statement_is_permitted(statement) else 1
    if action == "count":
        print(mod.count_allowed_inserts(statement))
        return 0
    sys.stderr.write("unknown action %r\n" % action)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
