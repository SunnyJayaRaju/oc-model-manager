#!/usr/bin/env python3
"""Portable sub-second timer for the perf regression test.

`date +%s%N` is not portable (BSD date has no %N) and EPOCHREALTIME needs
bash 5, but this project already hard-depends on python3 (record_validate_history
uses it for its timestamp), so this is the cheapest portable clock available.

    timer.py now              -> print time.time()
    timer.py diff <a> <b>     -> print (b - a) to 3 decimals
"""

import sys
import time

if sys.argv[1] == "now":
    print(repr(time.time()))
elif sys.argv[1] == "diff":
    print(f"{float(sys.argv[3]) - float(sys.argv[2]):.3f}")
else:
    sys.exit(f"usage: {sys.argv[0]} now|diff")
