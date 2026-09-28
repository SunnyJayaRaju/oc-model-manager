#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/update_tap_formula_shapes.bats
#
# scripts/update-tap-formula.sh assumed the formula has a `version "X"` line.
# A Homebrew formula does not need one: the version is normally derived from the
# url, and `brew audit --strict` actively complains about a version line that
# merely restates what the url already says ("version 3.1.3 is redundant with
# version scanned from URL"). So the tap's formula is on its way to dropping
# that line -- and when it does, this script aborted with
#
#     version substitution did not apply -- is there a version line in ...?
#
# after it had ALREADY written the url and sha256. Half-applied, and it looked
# like the formula was the problem rather than the script.
#
# So: url and sha256 are the managed fields. `version` is updated when present
# and is not added when absent; in that case the url is what carries the version
# and is asserted directly. Every other safety check is unchanged.
#
# RELEASE_BASE_URL exists for the same reason: the flow can then be rehearsed
# end to end against a local http server, with no release and no token.
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
    FORMULA="$TAP/Formula/ocprobe.rb"
    export FORMULA
    export WORK_DIR="$WORK/run"
    export REPO_SLUG="SunnyJayaRaju/oc-model-manager"
    export RELEASE_BASE_URL="http://127.0.0.1:8731"
    export PATH="$BIN:$PATH"
    mkdir -p "$WORK_DIR"

    # The served artifact, and its hash as a constant for this exact content.
    printf 'pretend this is the ocprobe tarball\n' >"$WORK/ocprobe-9.9.9.tar.gz"
    export FAKE_SHA="5c1b45e07e6d95b1de1f2f0e1c74e3f9e6d24c4a1e5a5b3d2c1e0f9a8b7c6d5e"
    # ...recomputed here so the constant above is never trusted blindly.
    local actual
    actual="$(python3 -c "import hashlib,sys;print(hashlib.sha256(open(sys.argv[1],'rb').read()).hexdigest())" "$WORK/ocprobe-9.9.9.tar.gz")"
    export FAKE_SHA="$actual"
    export FAKE_PAYLOAD="$WORK/ocprobe-9.9.9.tar.gz"
    export TAG=v9.9.9
    export FAKE_CURL_MODE=ok

    cat >"$BIN/curl" <<'FAKE'
#!/usr/bin/env bash
# Minimal `curl` stand-in: understands the flags the script actually passes.
# RELEASE_BASE_URL decides which asset is being asked for, so the override is
# exercised end to end rather than asserted about.
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
        printf '<html><body>404: Not Found</body></html>\n' >"$out"; exit 22 ;;
    sha_mismatch)
        case "$url" in
            *.sha256) printf '%s  x\n' "0000000000000000000000000000000000000000000000000000000000000000" >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac ;;
    not_a_hash)
        case "$url" in
            *.sha256) printf '404: Not Found\n' >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac ;;
    ok)
        case "$url" in
            *.sha256) printf '%s  %s\n' "$FAKE_SHA" "$(basename "$url")" >"$out" ;;
            *) cp "$FAKE_PAYLOAD" "$out" ;;
        esac ;;
    *) echo "unknown FAKE_CURL_MODE" >&2; exit 99 ;;
esac
FAKE
    chmod +x "$BIN/curl"
}

_run() { run bash "$ROOT/scripts/update-tap-formula.sh"; }

# Shape A: the formula carries an explicit version line (the tap's current shape).
_formula_with_version() {
    cat >"$FORMULA" <<'EOF'
class Ocprobe < Formula
  desc "x"
  homepage "https://example.com"
  url "https://github.com/old/v1.0.0/ocprobe-1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"
  version "1.0.0"

  def install
    (bin/"ocprobe").install "x"
  end
end
EOF
}

# Shape B: no version line, the version derived from the url (the target shape).
_formula_without_version() {
    cat >"$FORMULA" <<'EOF'
class Ocprobe < Formula
  desc "x"
  homepage "https://example.com"
  url "https://github.com/old/v1.0.0/ocprobe-1.0.0.tar.gz"
  sha256 "1111111111111111111111111111111111111111111111111111111111111111"
  license "MIT"

  def install
    (bin/"ocprobe").install "x"
  end
end
EOF
}

expected_url() {
    printf 'http://127.0.0.1:8731/v9.9.9/ocprobe-9.9.9.tar.gz'
}

# ---- shape A: version line present ----------------------------------------

@test "shape A: a version line is updated along with url and sha256" {
    _formula_with_version
    _run
    assert_success
    assert_output --partial "changed=yes"
    run grep -c 'version "9.9.9"' "$FORMULA"
    assert_output "1"
    run grep -cF "url \"$(expected_url)\"" "$FORMULA"
    assert_output "1"
    run grep -c "sha256 \"$FAKE_SHA\"" "$FORMULA"
    assert_output "1"
    # and no stale value survives anywhere
    run grep -c '1\.0\.0' "$FORMULA"
    assert_output "0"
}

# ---- shape B: no version line ---------------------------------------------

@test "shape B: a formula with no version line is updated, not rejected" {
    _formula_without_version
    _run
    assert_success
    assert_output --partial "changed=yes"
    run grep -cF "url \"$(expected_url)\"" "$FORMULA"
    assert_output "1"
    run grep -c "sha256 \"$FAKE_SHA\"" "$FORMULA"
    assert_output "1"
}

@test "shape B: no version line is added" {
    _formula_without_version
    _run
    assert_success
    # Adding one would be wrong twice over: it was not there, and brew audit
    # calls a version line that restates the url redundant.
    run grep -cE '^[[:space:]]*version[[:space:]]+"' "$FORMULA"
    assert_output "0"
}

@test "shape B: the url carries the version, and that is what is asserted" {
    # The substitute for the version assertion: the url must name both the tag
    # and the tarball, because that is where the version now lives.
    _formula_without_version
    _run
    assert_success
    local url
    url="$(grep -oE 'url "[^"]+"' "$FORMULA")"
    [[ "$url" == *"/v9.9.9/"* ]] || {
        echo "url does not name the tag: $url" >&2
        false
    }
    [[ "$url" == *"ocprobe-9.9.9.tar.gz"* ]] || {
        echo "url does not name the tarball: $url" >&2
        false
    }
}

@test "shape B: the rest of the formula is untouched" {
    _formula_without_version
    _run
    assert_success
    run grep -c 'class Ocprobe < Formula' "$FORMULA"
    assert_output "1"
    run grep -c 'def install' "$FORMULA"
    assert_output "1"
    run grep -c 'license "MIT"' "$FORMULA"
    assert_output "1"
}

# ---- the override ----------------------------------------------------------

@test "RELEASE_BASE_URL is honoured, and the default is the real releases URL" {
    _formula_with_version
    _run
    assert_success
    run grep -cF "url \"http://127.0.0.1:8731/v9.9.9/ocprobe-9.9.9.tar.gz\"" "$FORMULA"
    assert_output "1"

    # Unset it: the default must be the real GitHub releases URL, or the whole
    # point of the flag is that the default works.
    unset RELEASE_BASE_URL
    _formula_with_version
    _run
    assert_success
    run grep -cF "url \"https://github.com/SunnyJayaRaju/oc-model-manager/releases/download/v9.9.9/ocprobe-9.9.9.tar.gz\"" "$FORMULA"
    assert_output "1"
}

@test "a trailing slash on RELEASE_BASE_URL does not double up" {
    _formula_with_version
    export RELEASE_BASE_URL="http://127.0.0.1:8731/"
    _run
    assert_success
    run grep -cF "url \"http://127.0.0.1:8731/v9.9.9/ocprobe-9.9.9.tar.gz\"" "$FORMULA"
    assert_output "1"
    refute_output --partial "8731//"
}

# ---- every safety check, on both shapes -----------------------------------

@test "a 404 is refused and the formula is left alone (shape B)" {
    _formula_without_version
    cp "$FORMULA" "$WORK/before.rb"
    export FAKE_CURL_MODE=http404
    _run
    assert_failure
    assert_output --partial "download failed"
    run diff -q "$WORK/before.rb" "$FORMULA"
    assert_success
}

@test "a 404 is refused and the formula is left alone (shape A)" {
    _formula_with_version
    cp "$FORMULA" "$WORK/before.rb"
    export FAKE_CURL_MODE=http404
    _run
    assert_failure
    run diff -q "$WORK/before.rb" "$FORMULA"
    assert_success
}

@test "a checksum mismatch is refused and nothing is written" {
    _formula_without_version
    cp "$FORMULA" "$WORK/before.rb"
    export FAKE_CURL_MODE=sha_mismatch
    _run
    assert_failure
    assert_output --partial "checksum mismatch"
    run diff -q "$WORK/before.rb" "$FORMULA"
    assert_success
}

@test "a non-hash published checksum is refused" {
    _formula_without_version
    export FAKE_CURL_MODE=not_a_hash
    _run
    assert_failure
    assert_output --partial "not 64 hex chars"
}

@test "a bad tag is refused before any network access, on both shapes" {
    for shape in with_version without_version; do
        for bad in "1.0.0" "v9.9" "v9.9.9-rc1" "" "v9.9.9; touch $WORK/pwned"; do
            _formula_$shape
            TAG="$bad" _run
            assert_failure
        done
    done
    [ ! -e "$WORK/pwned" ]
}

@test "a malformed REPO_SLUG is refused" {
    _formula_with_version
    REPO_SLUG='../../etc' _run
    assert_failure
    assert_output --partial "REPO_SLUG"
}

@test "a missing formula is reported" {
    FORMULA="$TAP/Formula/nope.rb" _run
    assert_failure
    assert_output --partial "formula not found"
}

# ---- idempotence -----------------------------------------------------------

@test "a second run over the same tag is a no-op, on both shapes" {
    for shape in with_version without_version; do
        _formula_$shape
        _run
        assert_success
        assert_output --partial "changed=yes"
        _run
        assert_success
        assert_output --partial "changed=no"
        assert_output --partial "nothing to do"
    done
}

@test "no .bak file is left next to the formula" {
    for shape in with_version without_version; do
        _formula_$shape
        _run
        assert_success
        [ ! -e "${FORMULA}.bak" ]
    done
}

@test "the script never runs git and never sees a token" {
    run grep -cE '^[[:space:]]*(git|push)[[:space:]]' "$ROOT/scripts/update-tap-formula.sh"
    assert_output "0"
    local code
    code="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/update-tap-formula.sh")"
    run bash -c "printf '%s' \"\$1\" | grep -ciE 'HOMEBREW_TAP_TOKEN|GITHUB_TOKEN'" _ "$code"
    assert_output "0"
}
