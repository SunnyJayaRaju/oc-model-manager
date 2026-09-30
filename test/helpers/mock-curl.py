#!/usr/bin/env python3
"""Mock `curl` for verify-release.sh's unit coverage.

Serves the local fixture tarball and .sha256 for the release asset URLs, and the
formula text for the raw.githubusercontent.com URL. Any other URL is a 404, so a
test that accidentally reaches the real network fails loudly instead of quietly
depending on the internet.
"""

import json
import os
import sys

args = sys.argv[1:]
fx = json.load(open(os.path.join(os.environ["FX_DIR"], "fixture.json")))

url = args[-1]
outfile = None
if "-o" in args:
    outfile = args[args.index("-o") + 1]

payload = None
if url.endswith(".tar.gz"):
    payload = open(fx["tarball_path"], "rb").read()
elif url.endswith(".tar.gz.sha256"):
    payload = ("%s  ocprobe.tar.gz\n" % fx["published_sha"]).encode()
elif "raw.githubusercontent.com" in url:
    payload = fx["formula"].encode()
else:
    sys.stderr.write("mock curl: refusing unexpected URL %s\n" % url)
    sys.exit(22)

if outfile:
    with open(outfile, "wb") as fh:
        fh.write(payload)
else:
    sys.stdout.buffer.write(payload)
