#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/update_tap_formula.bats
#
# scripts/update-tap-formula.sh rewrites the published sha256 in a Homebrew
# formula. The inline shell it replaces in .github/workflows/ci.yml fetched that
# hash with `curl -sL "$URL.sha256" | cut -d' ' -f1`, which exits 0 on a 404, so
# a tag that was not really published produced a formula whose sha256 was an
# HTML error page. These tests drive the script with a fake `curl` on PATH, so
# the failure modes are reproducible without a network or a real tag.
#
# The script does not commit or push, so none of this touches git or a token.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/work"
    TAP="$BATS_TEST_TMPDIR/tap"
    BIN="$BATS_TEST_TMPDIR/bin"
    mkdir -p "$WORK" "$TAP/Formula" "$BIN"

    # The fake tarball the fake curl will serve. Its sha256 is a hard-coded
    # constant for this exact byte content, so the "published" checksum and the
    # one the script computes from the download come from one source and the
    # test needs no hashing tool of its own.
    printf 'pretend this is the ocprobe tarball for 1.4.2\n' >"$WORK/ocprobe-1.4.2.tar.gz"
    FAKE_SHA="eb15322f8b7c9befb1c67a69415eddedd095a8ed92ab8dfa1f4f6790678be33f"

    export FAKE_PAYLOAD="$WORK/ocprobe-1.4.2.tar.gz"
    export FAKE_SHA
    export PATH="$BIN:$PATH"
    export WORK_DIR="$WORK/script"
    export FORMULA="$TAP/Formula/ocprobe.rb"
    export REPO_SLUG="SunnyJayaRaju/oc-model-manager"
    export TAG="v1.4.2"
    export FAKE_CURL_MODE=ok
    mkdir -p "$WORK_DIR"

    _write_formula

    cat >"$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# Minimal `curl` stand-in: understands the flags the script actually passes.
# FAKE_CURL_MODE selects the behaviour under test.
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--output) out="$2"; shift 2 ;;
        --fail|--location|--silent|--show-error|-fsS|--*) shift ;;
        *) url="$1"; shift ;;
    esac
done
case "${FAKE_CURL_MODE:-ok}" in
    http404)
        # What a real 404 gives you. `--fail` turns this into a non-zero exit;
        # without it the old inline job happily used this as the hash.
        printf '<html><body>404: Not Found</body></html>\n' >"$out"
        exit 22
        ;;
    empty)
        : >"$out"
        exit 0
        ;;
    ok)
        case "$url" in
            *.sha256) printf '%s  %s\n' "$FAKE_SHA" "$(basename "$url")" >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac
        ;;
    sha_mismatch)
        case "$url" in
            *.sha256) printf '%s  %s\n' "0000000000000000000000000000000000000000000000000000000000000000" "x" >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac
        ;;
    not_a_hash)
        case "$url" in
            *.sha256) printf '404: Not Found\n' >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac
        ;;
    *) echo "unknown FAKE_CURL_MODE" >&2; exit 99 ;;
esac
FAKE
    chmod +x "$BIN/curl"
}

_write_formula() {
    cat >"$FORMULA" <<'EOF'
class Ocprobe < Formula
  desc "ocprobe"
  homepage "https://github.com/SunnyJayaRaju/oc-model-manager"
  url "https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v1.4.1/ocprobe-1.4.1.tar.gz"
  version "1.4.1"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"

  def install
    bin.install "ocprobe"
  end
end
EOF
}

_run() { # runs the script, capturing output
    run bash "$ROOT/scripts/update-tap-formula.sh"
}

# ---- the success path -------------------------------------------------------

@test "a good tag updates version, url and sha256 exactly" {
    _run
    assert_success
    assert_output --partial "changed=yes"
    assert_output --partial "updated to v1.4.2"
    run grep -q "version \"1.4.2\"" "$FORMULA"
    assert_success
    run grep -qF "sha256 \"$FAKE_SHA\"" "$FORMULA"
    assert_success
    # the rest of the formula is untouched
    run grep -q 'def install' "$FORMULA"
    assert_success
    run grep -q 'bin.install "ocprobe"' "$FORMULA"
    assert_success
}

@test "re-running for a tag the formula already has is a no-op, not a failure" {
    _run
    assert_success
    _run
    assert_success
    assert_output --partial "changed=no"
    assert_output --partial "nothing to do"
}

@test "indentation and the unrelated lines survive" {
    _run
    assert_success
    run bash -c "grep -c '^  version \"1.4.2\"$' '$FORMULA'"
    assert_output "1"
}

# ---- the bug this replaces --------------------------------------------------

@test "a 404 body cannot become the formula's sha256" {
    export FAKE_CURL_MODE=http404
    _run
    assert_failure
    assert_output --partial "download failed"
    # nothing was rewritten
    run grep -q 'sha256 "1111111111111111111111111111111111111111111111111111111111111111"' "$FORMULA"
    assert_success
    refute_output --partial "<html>"
}

@test "an empty body is rejected rather than written into the formula" {
    export FAKE_CURL_MODE=empty
    _run
    assert_failure
    run grep -q 'sha256 "1111111111111111111111111111111111111111111111111111111111111111"' "$FORMULA"
    assert_success
}

@test "a published checksum that does not match the tarball aborts" {
    export FAKE_CURL_MODE=sha_mismatch
    _run
    assert_failure
    assert_output --partial "checksum mismatch"
    # the mismatching hash was never written; the old value is still there
    run grep -q 'sha256 "1111111111111111111111111111111111111111111111111111111111111111"' "$FORMULA"
    assert_success
    run grep -q '0000000000000000000000000000000000000000000000000000000000000000' "$FORMULA"
    assert_failure
}

@test "a non-hash published checksum aborts instead of being embedded" {
    export FAKE_CURL_MODE=not_a_hash
    _run
    assert_failure
    assert_output --partial "not 64 hex chars"
    refute_output --partial "404: Not Found\""
}

# ---- input validation -------------------------------------------------------

@test "a malformed tag is rejected before any network access" {
    for bad in "1.4.2" "v1.4" "v1.4.2-rc1" "v1.4.2 && curl evil" "vX.Y.Z" ""; do
        TAG="$bad"
        export TAG
        _run
        [ "$status" -ne 0 ] || {
            echo "expected failure for TAG='$bad'" >&2
            false
        }
        assert_output --partial "TAG" # named the problem, did not touch the net
    done
}

@test "a tag carrying shell metacharacters is rejected, not executed" {
    TAG='v1.4.2; touch /tmp/pwned_update_tap_formula'
    export TAG
    _run
    assert_failure
    assert_output --partial "does not match"
    [ ! -e /tmp/pwned_update_tap_formula ]
}

@test "a malformed REPO_SLUG is rejected" {
    REPO_SLUG='../../etc/passwd'
    export REPO_SLUG
    _run
    assert_failure
    assert_output --partial "REPO_SLUG"
}

@test "a missing formula is reported rather than silently skipped" {
    FORMULA="$TAP/Formula/nope.rb"
    export FORMULA
    _run
    assert_failure
    assert_output --partial "formula not found"
}

@test "the script never writes a .bak file next to the formula" {
    _run
    assert_success
    [ ! -e "${FORMULA}.bak" ]
}

@test "the script has no git command and no credential handling" {
    # The token stays in the workflow's checkout step, so the script has no
    # reason to know about git at all. Comments are stripped first: the prose
    # explains *why* there is no git here, and that must not read as a match.
    local code
    code="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/update-tap-formula.sh")"
    run bash -c "printf '%s' \"\$1\" | grep -cE '(^|[^[:alnum:]_])(git|curl)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*[a-z-]*(commit|push)|HOMEBREW_TAP_TOKEN|GITHUB_TOKEN'" _ "$code"
    assert_output "0"
    # and it never echoes a token, because it never receives one
    run bash -c "printf '%s' \"\$1\" | grep -cE 'echo.*(TOKEN|SECRET|PASSWORD)'" _ "$code"
    assert_output "0"
}
