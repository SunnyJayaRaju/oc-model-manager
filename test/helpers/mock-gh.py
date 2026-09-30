#!/usr/bin/env python3
"""Mock `gh` for verify-release.sh's unit coverage. Reads $FX_DIR/fixture.json.

Real `gh api --jq EXPR` prints ONLY the jq result and never the raw JSON, so this
stub must too: a first version printed both, which made the script read a JSON
blob where it expected a bare hash. Anything unhandled exits non-zero, so a test
that drifts from the script's actual call shape fails loudly rather than passing
against a mock that answers whatever it is asked.

That rule extends to what real gh REFUSES to do. This mock used to implement
`gh api --input - --jq EXPR` as a filter over the document on stdin, which real
gh does not do at all:

    $ echo '{}' | gh api --input - --jq .x
    accepts 1 arg(s), received 0

Because the mock obliged, 19 tests passed against a script that could never run
in CI, and the real tag run (36687980784) failed with asset URLs permanently
"<not found>". A mock that invents a capability the real tool lacks is worse than
no mock: it converts an untested path into a tested-looking one. So that form is
rejected here exactly as gh rejects it, which means any future reintroduction
fails the suite instead of passing it.

Fixture fields for error handling (see make-release-fixture.py):
  api_error     an HTTP status to fail with, or null
  api_error_on  endpoint substring the failure is limited to, or null for all
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

# Real gh: `--input` is request-body input for a write endpoint and still
# requires the endpoint itself, so this call shape is rejected, not honoured.
if "--input" in rest:
    sys.stderr.write("accepts 1 arg(s), received 0\n")
    sys.exit(1)

endpoint = rest[0]

# A non-404 API failure. The whole point of the error handling under test is that
# this is NOT reported as "does not exist", so the mock must be able to produce
# it for any endpoint.
err_status = fx.get("api_error")
err_on = fx.get("api_error_on")
if err_status and (err_on is None or err_on in endpoint):
    if err_status == "404":
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
    elif err_status == "403":
        sys.stderr.write("gh: API rate limit exceeded (HTTP 403)\n")
    elif err_status == "401":
        sys.stderr.write("gh: Bad credentials (HTTP 401)\n")
    else:
        sys.stderr.write("gh: server error (HTTP %s)\n" % err_status)
    sys.exit(1)

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
