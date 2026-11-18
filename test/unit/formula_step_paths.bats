#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/formula_step_paths.bats — the formula step's updater path must
# resolve from the step's working-directory.
#
# ci.yml's "Update formula" step and the catch-up workflow's "Update the
# formula" step run with working-directory: tap and called
#
#     bash source/scripts/update-tap-formula.sh
#
# which resolves to tap/source/... -- a path that cannot exist, because the
# two checkouts are siblings (source/ and tap/ under the workspace root). The
# v3.2.1 tag run died with exit 127 exactly that way. The earlier fix added
# the checkout `path:`s, and a string-match test saw "source/scripts/..." in
# the body and passed: the invocation never resolved, and no test executed it.
#
# This test executes each such step body in a simulated actions workspace,
# with a stub updater, so path resolution is the only variable.
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
  ROOT="$BATS_TEST_DIRNAME/../.."
}

@test "every formula-update step resolves its updater from its working-directory" {
  run python3 - "$ROOT" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

import yaml

root = pathlib.Path(sys.argv[1])
failures = []
seen = 0

for wf in sorted((root / ".github" / "workflows").glob("*.yml")):
    d = yaml.safe_load(wf.read_text()) or {}
    for jname, job in (d.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            body = step.get("run") or ""
            # Invocation lines only: comments in other steps mention the
            # script by name and must not be simulated.
            invokes = any(
                (not line.lstrip().startswith("#"))
                and "bash" in line
                and "update-tap-formula.sh" in line
                for line in body.splitlines()
            )
            if not invokes:
                continue
            seen += 1
            wd = step.get("working-directory") or "."
            with tempfile.TemporaryDirectory() as tmp:
                ws = pathlib.Path(tmp) / "ws"
                (ws / "tap").mkdir(parents=True)
                scripts = ws / "source" / "scripts"
                scripts.mkdir(parents=True)
                (scripts / "update-tap-formula.sh").write_text(
                    "#!/bin/bash\necho changed=no\n"
                )
                (ws / "temp").mkdir()
                env = dict(os.environ)
                env["RUNNER_TEMP"] = str(ws / "temp")
                env["GITHUB_OUTPUT"] = str(ws / "output")
                stepscript = ws / "step.sh"
                stepscript.write_text(body)
                r = subprocess.run(
                    ["bash", "-e", str(stepscript)],
                    cwd=str(ws / wd),
                    env=env,
                    capture_output=True,
                    text=True,
                )
                if r.returncode != 0:
                    failures.append(
                        "%s %s/%r (working-directory %r): exit %d: %s"
                        % (
                            wf.name,
                            jname,
                            step.get("name", "?"),
                            wd,
                            r.returncode,
                            (r.stderr or "").strip().splitlines()[-1:],
                        )
                    )

if seen == 0:
    sys.exit("no formula-update step found in any workflow; the test lost its target")
if failures:
    sys.exit("unresolvable updater path:\n" + "\n".join(failures))
print("all %d formula step(s) resolve" % seen)
PY
  assert_success
}
