#!/usr/bin/env python3
"""Mock `gh` for verify-release.sh's unit coverage. Reads $FX_DIR/fixture.json.

Real `gh api --jq EXPR` prints ONLY the jq result and never the raw JSON, so this
stub must too: a first version printed both, which made the script read a JSON
blob where it expected a bare hash. Anything unhandled exits non-zero, so a test
that drifts from the script's actual call shape fails loudly rather than passing
against a mock that answers whatever it is asked.
"""

import json
import os
import sys

args = sys.argv[1:]
fx = json.load(open(os.path.join(os.environ["FX_DIR"], "fixture.json")))
rest = [a for a in args if a != "api"]
has_jq = "--jq" in rest
expr = (rest[rest.index("--jq") + 1] if has_jq else "") or ""


def emit(*lines):
    for line in lines:
        sys.stdout.write(str(line) + "\n")


if not rest:
    sys.exit(1)

# gh api --input - --jq <expr>   (the JSON document arrives on stdin)
if "--input" in rest:
    doc = json.load(sys.stdin)
    if "html_url" in expr:
        emit(doc.get("html_url", ""))
    elif "assets[]" in expr:
        # select(.name=="<name>") -- take the quoted literal after the `==`.
        want = expr.split('"')[1] if '"' in expr else ""
        for a in doc.get("assets", []):
            if a["name"] == want:
                emit(a["browser_download_url"])
    else:
        emit(json.dumps(doc))
    sys.exit(0)

endpoint = rest[0]

if "/git/refs/tags/" in endpoint:
    if fx["tag_ref"] is None:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    t = fx["tag_ref"]["object"]
    if has_jq and "object.type" in expr:
        emit("%s %s" % (t["type"], t["sha"]))
    else:
        emit(json.dumps(fx["tag_ref"]))
    sys.exit(0)

if "/git/tags/" in endpoint:
    if has_jq:
        emit(fx["tag_object_sha"])
    else:
        emit(json.dumps({"object": {"sha": fx["tag_object_sha"]}}))
    sys.exit(0)

if "/contents/VERSION" in endpoint:
    if has_jq:
        emit(fx["tag_version_b64"])
    else:
        emit(json.dumps({"content": fx["tag_version_b64"]}))
    sys.exit(0)

if "/releases/tags/" in endpoint:
    if fx["release"] is None:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    emit(json.dumps(fx["release"]))
    sys.exit(0)

sys.stderr.write("mock gh: unhandled endpoint %s\n" % endpoint)
sys.exit(1)
