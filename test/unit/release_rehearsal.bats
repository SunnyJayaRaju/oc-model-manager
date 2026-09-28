#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/release_rehearsal.bats
#
# The release -> tap update only ever ran on a tag push, and only ever ran for
# real once. Everything upstream of publishing was untested, so a mistake in the
# updater surfaced as a broken published formula.
#
# scripts/ci/rehearsal.sh and .github/workflows/release-rehearsal.yml fix that.
# The property that matters most is negative: the rehearsal must be incapable of
# publishing anything. That is what most of these tests are about, because a
# rehearsal that could push is worse than no rehearsal.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/scripts/ci/rehearsal.sh"
    WORKFLOW="$ROOT/.github/workflows/release-rehearsal.yml"
    TAP="$BATS_TEST_TMPDIR/tap"
    mkdir -p "$TAP/Formula"
    REPO_ROOT="$ROOT"
    export REPO_ROOT
}

# ---- the rehearsal works ---------------------------------------------------

@test "the rehearsal succeeds against a formula with a version line" {
    cat >"$TAP/Formula/with_ver.rb" <<'EOF'
class Ocprobe < Formula
  url "https://github.com/o/r/releases/download/v3.0.0/ocprobe-3.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  version "3.0.0"
end
EOF
    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/with_ver.rb"
    assert_success
    assert_output --partial "rehearsal OK"
    assert_output --partial "the existing version line was updated"
    assert_output --partial "the checked-out formula was not modified"
}

@test "the rehearsal succeeds against a formula with no version line" {
    cat >"$TAP/Formula/no_ver.rb" <<'EOF'
class Ocprobe < Formula
  url "https://github.com/o/r/releases/download/v3.0.0/ocprobe-3.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
end
EOF
    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/no_ver.rb"
    assert_success
    assert_output --partial "rehearsal OK"
    assert_output --partial "no version line, so the url carries the version"
}

@test "the rehearsal prints the formula diff" {
    cat >"$TAP/Formula/f.rb" <<'EOF'
class Ocprobe < Formula
  url "https://github.com/o/r/releases/download/v3.0.0/ocprobe-3.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
end
EOF
    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/f.rb"
    assert_success
    assert_output --partial "resulting formula diff"
    # a real unified diff, with the old and new url both visible
    # indented by the script's own sed, so match the content not the column
    assert_output --partial -- "-  url \"https://github.com"
    assert_output --partial -- "+  url \"http://127.0.0.1"
    assert_output --partial -- "+  sha256"
}

@test "the rehearsal builds the tarball and a .sha256 asset" {
    cat >"$TAP/Formula/f.rb" <<'EOF'
class Ocprobe < Formula
  url "https://github.com/o/r/releases/download/v3.0.0/ocprobe-3.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
end
EOF
    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/f.rb"
    assert_success
    # the hash it reports is 64 hex chars, and the tarball it names exists
    local sha
    sha="$(printf '%s' "$output" | grep -oE 'sha256 [0-9a-f]{64}' | head -1 | awk '{print $2}')"
    [ "${#sha}" -eq 64 ] || {
        echo "no 64-hex sha in the output" >&2
        false
    }
    [ -d "$REPO_ROOT/.rehearsal/dist" ] || {
        echo "the rehearsal left no dist/ directory" >&2
        false
    }
}

# ---- the negative properties, which are the point -------------------------

@test "the rehearsal cannot push: the script has no git command at all" {
    # Comments AND quoted strings are excluded. The script's prose says it cannot
    # push, and it prints "nothing was pushed" at the end; counting those would
    # be testing the wording rather than the property. What must be absent is a
    # COMMAND that invokes git, or anything named push.
    run bash -c "
        sed -e 's/^[[:space:]]*#.*//' -e 's/\"[^\"]*\"//g' '$SCRIPT' \
          | grep -cE '(^|[^[:alnum:]_/])git[[:space:]]|push' || true
    "
    assert_output "0"
}

@test "the rehearsal cannot push: no workflow step invokes a git push" {
    # The naive substring test is useless here because the workflow's own comment
    # once used the words, so this reads the run: bodies specifically.
    local body
    body="$(python3 - "$WORKFLOW" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
# strip comments, then keep only run: bodies
lines = [l for l in text.splitlines() if not l.lstrip().startswith("#")]
out = []
for m in re.finditer(r"run: (.*)", "\n".join(lines)):
    out.append(m.group(1))
print("\n".join(out))
PY
)"
    run bash -c "printf '%s' \"\$1\" | grep -ciE 'git .*push' || true" _ "$body"
    assert_output "0"
}

@test "the workflow is workflow_dispatch only" {
    # Not on push, not on a tag, not on a schedule: a rehearsal that could be
    # triggered by a real release could itself do something on that release.
    run python3 - "$WORKFLOW" <<'PY'
import sys

import yaml

d = yaml.safe_load(open(sys.argv[1]))
on = d.get(True, d.get("on"))
if isinstance(on, list):
    on = on
else:
    on = list(on)
bad = [k for k in on if k != "workflow_dispatch"]
print("TRIGGERS=%s" % ",".join(on))
print("EXTRA=%s" % ",".join(bad))
PY
    assert_line "TRIGGERS=workflow_dispatch"
    assert_line "EXTRA="
}

@test "the workflow has read-only permissions" {
    run python3 - "$WORKFLOW" <<'PY'
import sys

import yaml

d = yaml.safe_load(open(sys.argv[1]))
print("PERMS=%s" % d.get("permissions"))
PY
    assert_line "PERMS={'contents': 'read'}"
}

@test "no step in the workflow is given a token" {
    run python3 - "$WORKFLOW" <<'PY'
import sys

import yaml

d = yaml.safe_load(open(sys.argv[1]))
found = []
for job in d["jobs"].values():
    for st in job["steps"]:
        if "token" in (st.get("with") or {}):
            found.append(st.get("name") or st.get("uses"))
print("TOKENS=%d" % len(found))
PY
    assert_line "TOKENS=0"
}

@test "the rehearsal never writes to the checked-out formula" {
    # A rehearsal that edits the real file would be a rehearsal that changes
    # state, which is the thing being rehearsed.
    cat >"$TAP/Formula/f.rb" <<'EOF'
class Ocprobe < Formula
  url "https://github.com/o/r/releases/download/v3.0.0/ocprobe-3.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
end
EOF
    local before
    before="$(cat "$TAP/Formula/f.rb")"
    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/f.rb"
    assert_success
    assert_equal "$before" "$(cat "$TAP/Formula/f.rb")"
}

@test "the rehearsal refuses a missing tap or formula" {
    run bash "$SCRIPT" --tap-dir "$BATS_TEST_TMPDIR/nope"
    assert_failure
    assert_output --partial "tap not checked out"

    run bash "$SCRIPT" --tap-dir "$TAP" --formula "$TAP/Formula/nope.rb"
    assert_failure
    assert_output --partial "formula not found"
}

@test "the rehearsal scratch dir is gitignored" {
    # Otherwise a local rehearsal leaves build output in `git status`.
    run grep -c '^\.rehearsal/' "$ROOT/.gitignore"
    assert_output "1"
}

# ---- gates ----------------------------------------------------------------

@test "the script and workflow are syntax-clean and covered by the lint gate" {
    # NOT invoking shellcheck here. It is absent from the macOS runners -- it is
    # installed by the Lint job, which is the only place it is needed -- so a
    # test that runs it can only ever pass on Linux. That was already fixed once
    # in this suite (the 3.1.3 prep branch) and reintroduced here; the rule is
    # that lint lives in the Lint job and `make lint`, and a test asserts the
    # COVERAGE by reading those commands instead of executing them.
    run bash -n "$SCRIPT"
    assert_success
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/.github/workflows/ci.yml"
    assert_output "1"
    run python3 - "$WORKFLOW" <<'PY'
import sys

import yaml

yaml.safe_load(open(sys.argv[1]))
PY
    assert_success
    # and scripts/ci/*.sh is already covered by the lint job
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"
}
