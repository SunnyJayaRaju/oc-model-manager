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

@test "only the tag-gated CI job calls the live script" {
    # The per-PR jobs must not. Count the jobs in ci.yml that invoke it.
    local invocations
    invocations="$(grep -c 'verify-release.sh' "$ROOT/.github/workflows/ci.yml" || true)"
    [ "$invocations" -ge 1 ] || {
        echo "no CI job calls verify-release.sh" >&2
        false
    }
    run grep -B 12 'verify-release.sh' "$ROOT/.github/workflows/ci.yml"
    # The invoking job must be gated on a tag push.
    assert_output --partial "refs/tags/v"
}
