#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/workflow_step_exit_status.bats
#
# Tests for the behaviour of a GitHub Actions `run:` step, which is a plain bash
# script. There is no way to unit-test the runner itself, so what is tested here
# is the shell semantics the steps depend on, plus a static check that the
# workflow still uses them.
#
# Why this file exists: the "Update Homebrew Formula" job once ran
#
#     bash scripts/update-tap-formula.sh | tee "$RUNNER_TEMP/formula.log"
#
# in a workspace that contained only the tap repo, so the script did not exist.
# bash reported tee's exit status, tee succeeded, the step went GREEN, the log
# was empty, changed=false, and the commit step was skipped. The tap was left on
# the previous release and the workflow reported success. A release pipeline that
# cannot distinguish "the work happened" from "the work did not happen" is worse
# than one that fails, because the green is trusted.
#
# Two halves are pinned here, and both matter:
#   - the broken shape really does exit 0 (so the bug is demonstrated, not
#     asserted from memory)
#   - the fixed shape really does exit non-zero
# A test that only checked the fixed shape would pass just as well against a
# world where the bug had never existed.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/work"
    mkdir -p "$WORK"
}

# Reproduce a `run:` step's shell: `bash -e {0}` writing to a file.
as_step() { # $1 = path to a step script; runs it the way the runner would
    bash -e "$1" 2>&1
}

# ---- the bug, demonstrated -------------------------------------------------

@test "without pipefail, a missing script piped to tee exits ZERO" {
    # The shape that shipped. If this ever starts failing, the demonstration is
    # no longer demonstrating, and the paired test below needs re-checking.
    cat >"$WORK/step.sh" <<'EOS'
bash definitely-not-here.sh | tee "$LOG"
EOS
    LOG="$WORK/out.log" run as_step "$WORK/step.sh"

    assert_success
    # The failure is visible in the text but invisible in the status.
    assert_output --partial "No such file or directory"
}

@test "without pipefail, a script that exits 1 is masked as success" {
    printf '#!/bin/bash\necho "update-tap-formula: checksum mismatch" >&2\nexit 1\n' \
        >"$WORK/updater.sh"
    cat >"$WORK/step.sh" <<'EOS'
bash updater.sh | tee "$LOG"
EOS
    cd "$WORK" && LOG="$WORK/out.log" run as_step "$WORK/step.sh"

    assert_success
    assert_output --partial "checksum mismatch"
}

# ---- the fix, proven -------------------------------------------------------

@test "with pipefail, a missing script exits non-zero" {
    cat >"$WORK/step.sh" <<'EOS'
set -o pipefail
bash definitely-not-here.sh | tee "$LOG"
EOS
    LOG="$WORK/out.log" run as_step "$WORK/step.sh"

    assert_failure
    assert_output --partial "No such file or directory"
}

@test "with pipefail, a script that exits 1 fails the step" {
    printf '#!/bin/bash\necho "update-tap-formula: checksum mismatch" >&2\nexit 1\n' \
        >"$WORK/updater.sh"
    cat >"$WORK/step.sh" <<'EOS'
set -o pipefail
bash updater.sh | tee "$LOG"
EOS
    cd "$WORK" && LOG="$WORK/out.log" run as_step "$WORK/step.sh"

    assert_failure
    assert_output --partial "checksum mismatch"
}

@test "with pipefail, a successful script still succeeds and still logs" {
    # The fix must not break the working case: exit 0, and the log the next line
    # greps for must be written.
    printf '#!/bin/bash\necho "changed=yes"\n' >"$WORK/updater.sh"
    cat >"$WORK/step.sh" <<'EOS'
set -o pipefail
bash updater.sh | tee "$LOG"
grep -q '^changed=yes$' "$LOG" && echo "changed=true" >> "$OUT"
EOS
    cd "$WORK" && LOG="$WORK/out.log" OUT="$WORK/github_output" \
        run as_step "$WORK/step.sh"

    assert_success
    run cat "$WORK/github_output"
    assert_output --partial "changed=true"
}

# ---- the workflow must keep using the fixed shape --------------------------

@test "the homebrew job checks out this repo, not only the tap" {
    run python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys, yaml

d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["homebrew"]["steps"]
checkouts = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
paths = [str((s.get("with") or {}).get("path", "")) for s in checkouts]
repos = [str((s.get("with") or {}).get("repository", "")) for s in checkouts]
assert any(p == "source" for p in paths), "no source-repo checkout: %r" % (paths,)
assert any("homebrew-ocprobe" in r for r in repos), "tap checkout gone: %r" % (repos,)
PY
    assert_success
}

@test "the formula step sets pipefail and runs the updater from source/" {
    run python3 - "$ROOT/.github/workflows/ci.yml" <<'PY'
import sys, yaml

d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["homebrew"]["steps"]
body = next(s["run"] for s in steps if s.get("id") == "formula")
assert "set -o pipefail" in body, "no pipefail:\n%s" % body
assert "source/scripts/update-tap-formula.sh" in body, body
assert "bash scripts/update-tap-formula.sh |" not in body, body
PY
    assert_success
}

@test "no run: step in any workflow pipes a command to tee without pipefail" {
    # The whole bug class, not just the one step. Applied to every workflow so a
    # second copy cannot be added later.
    run python3 - "$ROOT/.github/workflows" <<'PY'
import pathlib, sys, yaml

bad = []
for wf in sorted(pathlib.Path(sys.argv[1]).glob("*.yml")):
    d = yaml.safe_load(wf.read_text()) or {}
    for jname, job in (d.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            body = step.get("run")
            if not body or "tee" not in body:
                continue
            if "set -o pipefail" not in body and "set -euo pipefail" not in body:
                bad.append("%s:%s:%s" % (wf.name, jname, step.get("name")))
assert not bad, "unmasked pipefail:\n" + "\n".join(bad)
PY
    assert_success
}

@test "every job that calls gh passes a token and declares permissions" {
    # A gh call with no token is an anonymous call, and the anonymous rate limit
    # is what turned a passing release into three false absences.
    run python3 - "$ROOT/.github/workflows" <<'PY'
import pathlib, sys, yaml

bad = []
for wf in sorted(pathlib.Path(sys.argv[1]).glob("*.yml")):
    d = yaml.safe_load(wf.read_text()) or {}
    for jname, job in (d.get("jobs") or {}).items():
        for step in job.get("steps") or []:
            body = step.get("run") or ""
            if "verify-release.sh" not in body:
                continue
            env = step.get("env") or {}
            if "GH_TOKEN" not in env and "GITHUB_TOKEN" not in env:
                bad.append("%s:%s: no token in env" % (wf.name, jname))
            perms = job.get("permissions")
            if not isinstance(perms, dict):
                bad.append("%s:%s: no permissions block" % (wf.name, jname))
            else:
                for k, v in perms.items():
                    if k == "contents" and v not in ("read",):
                        bad.append("%s:%s: contents=%r" % (wf.name, jname, v))
                    if k != "contents":
                        bad.append("%s:%s: unexpected scope %s" % (wf.name, jname, k))
assert not bad, "\n".join(bad)
PY
    assert_success
}
