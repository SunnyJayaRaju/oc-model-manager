#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/verify_release_script.bats
#
# Coverage for scripts/ci/verify-release.sh, the script that replaced
# test/unit/release_313.bats.
#
# The script itself makes live network calls and must never run in this suite --
# these tests drive it with MOCKED gh and curl (VERIFY_RELEASE_GH /
# VERIFY_RELEASE_CURL) against a local fixture tarball, so the suite stays
# offline, fast and deterministic. What is covered here is the script's own
# behaviour: argument handling, and that each invariant it claims to enforce
# actually fails when that invariant is broken.
#
# That last part is the point. A release verifier whose checks cannot fail is
# worse than no verifier, because it prints "ok" and a human believes it. Every
# negative case below breaks exactly one thing and requires the script to notice.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/scripts/ci/verify-release.sh"
    BIN="$BATS_TEST_TMPDIR/bin"
    FX_DIR="$BATS_TEST_TMPDIR/fx"
    mkdir -p "$BIN" "$FX_DIR"
    export FX_DIR

    # Executable stubs on PATH. The script resolves gh and curl through
    # VERIFY_RELEASE_GH / VERIFY_RELEASE_CURL, so nothing here can reach the
    # real ones even if a test forgets to pass a fixture knob.
    printf '#!/bin/bash\nexec python3 %q "$@"\n' "$ROOT/test/helpers/mock-gh.py" >"$BIN/gh"
    printf '#!/bin/bash\nexec python3 %q "$@"\n' "$ROOT/test/helpers/mock-curl.py" >"$BIN/curl"
    chmod +x "$BIN/gh" "$BIN/curl"
    export VERIFY_RELEASE_GH="$BIN/gh"
    export VERIFY_RELEASE_CURL="$BIN/curl"
    export VERIFY_RELEASE_WORK="$BATS_TEST_TMPDIR/work"
}

# Rebuild the fixture with whatever FX_* knobs the test set, then run the script.
run_verify() {
    python3 "$ROOT/test/helpers/make-release-fixture.py" "$FX_DIR" >/dev/null
    run bash "$SCRIPT" "$@"
}

# ---- argument handling: must fail before any network call -----------------

@test "no version at all is a usage error, not a silent default" {
    # SCRIPT_ROOT/VERSION exists in this repo, so the script would otherwise fall
    # back to it. Point the script at a tree with no VERSION file to prove the
    # "nothing to go on" path is loud.
    local fake_root="$BATS_TEST_TMPDIR/emptyroot"
    mkdir -p "$fake_root/scripts/ci"
    cp "$SCRIPT" "$fake_root/scripts/ci/verify-release.sh"

    run env -u VERSION VERIFY_RELEASE_GH=/nonexistent VERIFY_RELEASE_CURL=/nonexistent \
        bash "$fake_root/scripts/ci/verify-release.sh"

    assert_failure
    assert_output --partial "no VERSION given"
}

@test "an explicitly empty version argument is rejected" {
    # Passing "" must NOT fall back to the VERSION file. Silently verifying a
    # different version than the caller asked for is the one failure mode here
    # that must never happen quietly.
    run env VERIFY_RELEASE_GH=/nonexistent VERIFY_RELEASE_CURL=/nonexistent \
        bash "$SCRIPT" ""

    assert_failure
    assert_output --partial "version argument is empty"
}

@test "a version that is not MAJOR.MINOR.PATCH is rejected" {
    for v in 3.1 3.1.3.4 v3.1.3 3.1.3-rc1 abc "3.1.3; echo pwned" "../3.1.3" "3.1.3 " ; do
        run env VERIFY_RELEASE_GH=/nonexistent VERIFY_RELEASE_CURL=/nonexistent \
            bash "$SCRIPT" "$v"
        assert_failure
        # The message must name the offending value: "some version is malformed"
        # tells a caller nothing about which call was wrong.
        assert_output --partial "'$v' is not a MAJOR.MINOR.PATCH version"
    done
}

@test "argument errors happen before gh or curl is consulted" {
    # The mocks are pointed at /nonexistent, so if the script called either one
    # before validating, the message would be "required tool not found" instead.
    run env VERIFY_RELEASE_GH=/nonexistent VERIFY_RELEASE_CURL=/nonexistent \
        bash "$SCRIPT" "not-a-version"

    assert_failure
    refute_output --partial "required tool not found"
    refute_output --partial "== a."
}

@test "a missing required tool is reported clearly" {
    run env VERIFY_RELEASE_GH=/nonexistent VERIFY_RELEASE_CURL="$VERIFY_RELEASE_CURL" \
        bash "$SCRIPT" 3.1.3

    assert_failure
    assert_output --partial "required tool not found"
}

# ---- the happy path, entirely mocked -------------------------------------

@test "a complete, correct release passes" {
    run_verify 3.1.3

    assert_success
    assert_output --partial "tag v3.1.3 exists"
    assert_output --partial "exactly one tarball asset"
    assert_output --partial "published sha256 matches the tarball exactly"
    assert_output --partial "zero AppleDouble"
    assert_output --partial "contains lib/session_restore.py"
    assert_output --partial "formula sha256 matches the published tarball exactly"
    assert_output --partial "verify-release: PASS"
}

@test "an annotated tag is peeled to the commit it releases" {
    FX_ANNOTATED=1 run_verify 3.1.3

    assert_success
    assert_output --partial "peeled to commit"
    # The peeled commit is the tag object's target, not the tag object itself.
    assert_output --partial "$(printf '0%.0s' {1..39})2"
}

# ---- D3: asset URLs must be read out of the response, not grepped ---------
#
# The script used `gh api --input - --jq ...`, which is request-body input for a
# write endpoint, not a filter over a fetched document. Real gh rejects it. The
# first real run of this job therefore read "<not found>" for both asset URLs on
# a release that had both, and checks (c) and (d) could never pass.

@test "both asset URLs are found on the release, so the tarball is actually checked" {
    run_verify 3.1.3

    assert_success
    # The URLs must be real, not the placeholder the broken code produced.
    assert_output --partial "tarball asset URL: https://example.invalid/ocprobe-3.1.3.tar.gz"
    assert_output --partial "sha256 asset URL:  https://example.invalid/ocprobe-3.1.3.tar.gz.sha256"
    # And they must actually have been followed, not merely printed.
    refute_output --partial "asset URLs unavailable"
    refute_output --partial "it was not downloaded"
    assert_output --partial "downloaded tarball"
    assert_output --partial "computed sha256"
    assert_output --partial "published sha256 matches the tarball exactly"
    # (d) only runs if (c) downloaded something, so these prove the chain.
    assert_output --partial "zero AppleDouble"
    assert_output --partial "contains lib/session_restore.py"
}

@test "an asset whose browser_download_url is empty is not silently accepted" {
    # A release entry can carry a name and no URL. Counting the name would pass
    # the "a .sha256 asset is present" check and then leave the URL empty, which
    # is how a release ends up published but unverifiable.
    FX_EMPTY_ASSET_URL=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "cannot check checksums"
    refute_output --partial "a .sha256 asset is present"
}

@test "the script never uses 'gh api --input -', which real gh refuses" {
    # A static guard, because the mock now rejects that call shape the way gh
    # does and a test would otherwise only catch a reintroduction indirectly.
    # Comment lines are excluded: the script deliberately *names* the broken form
    # in a comment explaining why it is not used, and a naive grep would match its
    # own documentation.
    run python3 - "$SCRIPT" <<'PY'
import sys

code = [
    ln
    for ln in open(sys.argv[1]).read().splitlines()
    if ln.strip() and not ln.lstrip().startswith("#")
]
body = "\n".join(code)
bad = [ln for ln in code if "--input" in ln and "api" in ln]
assert not bad, "uses a call shape real gh rejects:\n" + "\n".join(bad)
assert "gh api --input" not in body, body
PY
    assert_success
}

# ---- D2: absence vs "could not look" --------------------------------------
#
# The first real run of this job had no GH_TOKEN, so gh was unauthenticated, every
# call hit the anonymous rate limit, and each `|| true` turned an error into an
# empty string. The script then reported the tag, the release and the formula as
# all missing while all three existed. These tests pin the distinction.

@test "a 404 is reported as absence, which is a legitimate failure" {
    FX_TAG_MISSING=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "does not exist in SunnyJayaRaju/oc-model-manager (HTTP 404)"
    # Absence is reported, not an error: the script must still get to a verdict.
    assert_output --partial "verify-release: FAIL"
}

@test "a rate-limit error on the tag lookup is NOT reported as a missing tag" {
    # This is the exact failure of tag run 36687980784. The subject is present;
    # the check could not read it, so the script must say so and stop.
    FX_API_ERROR=403 run_verify 3.1.3

    assert_failure
    refute_output --partial "does not exist"
    assert_output --partial "FAILED TO CHECK whether tag v3.1.3 exists"
    assert_output --partial "this is an API error, not an absent object"
    # The reason has to be visible, or the operator has nothing to act on.
    assert_output --partial "rate limit"
}

@test "a credentials error on the release lookup is NOT reported as a missing release" {
    # Scoped to the release endpoint, so the tag lookup still succeeds and the
    # failure is proven at the release step specifically. An unscoped error would
    # stop the script at step (a) and never test what this claims to test.
    FX_API_ERROR=401 FX_API_ERROR_ON="/releases/tags/" run_verify 3.1.3

    assert_failure
    # The tag checks must have run, proving the scoping worked.
    assert_output --partial "tag v3.1.3 exists"
    refute_output --partial "Release v3.1.3 does not exist"
    assert_output --partial "FAILED TO CHECK whether Release v3.1.3 exists"
    assert_output --partial "Bad credentials"
    assert_output --partial "missing GH_TOKEN"
}

@test "a 500 on the release lookup is NOT reported as a missing release" {
    FX_API_ERROR=500 run_verify 3.1.3

    assert_failure
    refute_output --partial "does not exist"
    assert_output --partial "FAILED TO CHECK"
    assert_output --partial "HTTP 500"
}

@test "an error on the VERSION read is not reported as a wrong VERSION" {
    # The tag is fine, the release is fine, and one content read fails. Reporting
    # "reads <empty>, expected 3.1.3" here would blame the release for a
    # transport problem.
    FX_API_ERROR=403 FX_API_ERROR_ON="/contents/VERSION" run_verify 3.1.3

    assert_failure
    refute_output --partial "expected 3.1.3"
    assert_output --partial "FAILED TO CHECK"
}

@test "an API error stops the run instead of cascading into bogus later checks" {
    # With the old `|| true`, one failure produced a tail of confident-sounding
    # follow-on failures ("cannot check checksums", "was not downloaded") that all
    # implied the release was at fault. The first error is the only thing said.
    FX_API_ERROR=403 run_verify 3.1.3

    assert_failure
    refute_output --partial "cannot check checksums"
    # "check(s) failed" is the verdict line, and is what must never be printed.
    # Asserting on "verify-release: FAIL" instead would be self-defeating: that
    # is a substring of the FAILED TO CHECK line, so the refute would have passed
    # for the wrong reason.
    refute_output --partial "check(s) failed"
}

# ---- each invariant must be able to fail ----------------------------------

@test "a missing tag fails" {
    FX_TAG_MISSING=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "does not exist"
    assert_output --partial "verify-release: FAIL"
}

@test "a tag whose commit has a different VERSION fails" {
    # The tag would ship a tarball built from a commit that claims another
    # version -- the exact mismatch a human is least likely to notice.
    FX_TAG_VERSION=3.1.2 run_verify 3.1.3

    assert_failure
    assert_output --partial "reads '3.1.2', expected 3.1.3"
}

@test "a missing Release fails" {
    FX_RELEASE_MISSING=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "does not exist"
}

@test "two tarball assets fails -- exactly one is required" {
    FX_TARBALL_COUNT=2 run_verify 3.1.3

    assert_failure
    assert_output --partial "expected exactly 1 tarball asset"
}

@test "a missing .sha256 asset fails" {
    FX_NO_SHA_ASSET=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "no ocprobe-3.1.3.tar.gz.sha256 asset"
}

@test "a published sha256 that does not match the tarball fails" {
    FX_PUBLISHED_SHA=0000000000000000000000000000000000000000000000000000000000000000 \
        run_verify 3.1.3

    assert_failure
    assert_output --partial "published sha256 0000"
    assert_output --partial "!= computed"
}

@test "an AppleDouble member in the tarball fails" {
    # This is the bug PR #20 fixed. The check reads the archive with python's
    # tarfile, not `tar -tzf`, because bsdtar hides AppleDouble members when
    # listing -- a tar-based check would pass this fixture.
    FX_APPLEDOUBLE=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "AppleDouble member"
    assert_output --partial "._VERSION"
}

@test "a tarball without lib/session_restore.py fails" {
    # The release that motivated package-check.sh: 'ocprobe session restore'
    # dies with "no such file" for every user, and nothing else notices.
    FX_NO_RESTORE=1 run_verify 3.1.3

    assert_failure
    assert_output --partial "does not contain ocprobe-3.1.3/lib/session_restore.py"
}

@test "a formula whose sha256 does not match the published tarball fails" {
    FX_FORMULA_SHA=1111111111111111111111111111111111111111111111111111111111111111 \
        run_verify 3.1.3

    assert_failure
    assert_output --partial "formula sha256 1111"
    assert_output --partial "!= published tarball"
}

@test "a formula whose url points at a different tag fails" {
    FX_FORMULA_URL="https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v3.1.2/ocprobe-3.1.2.tar.gz" \
        run_verify 3.1.3

    assert_failure
    assert_output --partial "does not reference v3.1.3/ocprobe-3.1.3.tar.gz"
}

# ---- the script must stay OUT of the hermetic suite -----------------------

@test "the live-API script is not in test/unit and is not run by make test" {
    # If this ever regresses, every PR starts depending on github.com and a
    # release check that can only pass after a release would block every push.
    [ ! -e "$ROOT/test/unit/verify-release.sh" ] || false
    run grep -nE "verify-release" "$ROOT/Makefile"
    assert_failure
    [ -z "$output" ] || {
        echo "Makefile references verify-release: $output" >&2
        false
    }
}

@test "every CI job that calls the live script is gated to an explicit release" {
    # The per-PR jobs must not call it. This was a `grep -B 12` for
    # "refs/tags/v", which passed only because the gate happened to sit within
    # twelve lines above the call; growing a comment moved it out of range and
    # the check failed for a reason that had nothing to do with what it claims to
    # test. Read the jobs structurally instead, and accept the two gates that are
    # legitimate: a tag push, or an explicit workflow_dispatch naming a tag.
    run python3 - "$ROOT/.github/workflows" <<'PY'
import pathlib, sys, yaml

wfs = sorted(pathlib.Path(sys.argv[1]).glob("*.yml"))
found, bad = [], []
for wf in wfs:
    d = yaml.safe_load(wf.read_text()) or {}
    on = d[True] if True in d else d.get("on")
    triggers = set(on) if isinstance(on, dict) else {on}
    # A dispatch-only workflow carries its gate in `on:`, not in the job's `if:`.
    dispatch_only = triggers == {"workflow_dispatch"}
    for jname, job in (d.get("jobs") or {}).items():
        steps = job.get("steps") or []
        if not any("verify-release.sh" in (s.get("run") or "") for s in steps):
            continue
        found.append("%s:%s" % (wf.name, jname))
        cond = str(job.get("if") or "")
        if "refs/tags/v" in cond or dispatch_only:
            continue
        bad.append(
            "%s:%s gated on %r, triggers %r" % (wf.name, jname, cond, sorted(triggers))
        )
assert found, "no CI job calls verify-release.sh at all"
assert not bad, "ungated live-script invocation:\n" + "\n".join(bad)
print("\n".join(found))
PY
    assert_success
    # Both the tag-gated job and the manual catch-up must be present, so neither
    # can be quietly deleted.
    assert_output --partial "ci.yml:verify-release"
    assert_output --partial "publish-release-to-tap.yml:publish"
}
