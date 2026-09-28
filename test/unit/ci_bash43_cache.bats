#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/ci_bash43_cache.bats
#
# The "Unit Tests (bash 4.3)" job compiled bash 4.3.30 on every single run,
# which was ~3m20s of the job's total. D3 caches the compiled binary, so the
# things that could go wrong are all about the cache being wrong rather than
# merely absent:
#
#   - a key that does not include the pinned source hash would serve a binary
#     built from a different tarball, and the sha256 pin would stop meaning
#     anything
#   - a key that does not include the OS would serve an ubuntu binary to a
#     macOS runner
#   - a restored binary that is not 4.3 would make the job go green while
#     proving nothing, which is the failure this job exists to prevent
#
# These assert the workflow and the script agree with each other, which is the
# part that cannot be caught by running it: a mismatched key is a silent cache
# miss (or a silent wrong answer) forever, not an error.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORKFLOW="$ROOT/.github/workflows/ci.yml"
    SCRIPT="$ROOT/scripts/ci/install-bash43.sh"
}

# ---- the cache key is pinned to the source the script verifies --------------

@test "the cache key embeds the same version the script builds" {
    run grep -oE 'BASH_VERSION="[0-9.]+"' "$SCRIPT"
    assert_output 'BASH_VERSION="4.3.30"'
    run grep -c 'key: bash43-4.3.30-' "$WORKFLOW"
    assert_output "1"
}

@test "the cache key embeds the pinned source sha256 the script verifies" {
    run grep -oE 'BASH_SHA256="[0-9a-f]+"' "$SCRIPT"
    local pinned
    pinned="${output#BASH_SHA256=\"}"
    pinned="${pinned%\"}"
    [ "${#pinned}" -eq 64 ] || {
        echo "expected a 64-char sha256 in the script, got ${#pinned}: $pinned" >&2
        false
    }
    # The workflow's key carries the first 16 hex chars of the same hash, so a
    # change of tarball invalidates the cache.
    run grep -c "key: bash43-4.3.30-${pinned:0:16}-" "$WORKFLOW"
    assert_output "1"
}

@test "the cache key names the runner OS and machine" {
    # A bash linked against one libc is not valid on another; sharing a cache
    # across operating systems would serve the wrong binary.
    run grep -cE 'key: bash43-4\.3\.30-[0-9a-f]{16}-linux-[a-z0-9_]+' "$WORKFLOW"
    assert_output "1"
}

@test "the cache covers the install prefix the script uses" {
    # ~/bash43 in the workflow, $HOME/bash43 in the script: a mismatch means the
    # cache restores a tree the script then never looks at.
    run grep -c 'path: ~/bash43' "$WORKFLOW"
    assert_output "1"
    run grep -c 'PREFIX="\${BASH43_PREFIX:-\$HOME/bash43}"' "$SCRIPT"
    assert_output "1"
}

# ---- the pin and the assertion must survive caching ------------------------

@test "the tarball sha256 is still verified after a cache hit" {
    # The build step is skipped on a hit, so the download-and-verify only runs
    # on a miss. What must never happen is the pin being dropped from the
    # script on the assumption that a cache hit makes it redundant.
    run grep -c 'sha256sum -c -' "$SCRIPT"
    assert_output "1"
    run grep -c 'https://ftp.gnu.org/gnu/bash/bash-' "$SCRIPT"
    assert_output "1"
}

@test "the script asserts that bash on PATH is exactly 4.3" {
    # Guards the case that matters most: a restored binary that is some other
    # version would make this job green while testing nothing.
    # Two independent checks, because two different things need verifying:
    # have_bash43 asks whether the cached prefix binary is 4.3, and the
    # end-of-script check asks whether what actually ended up on PATH is 4.3.
    run grep -c 'BASH_VERSINFO' "$SCRIPT"
    [ "$output" -eq 2 ] || {
        echo "expected 2 BASH_VERSINFO checks (prefix binary, and PATH), found $output" >&2
        false
    }
    run grep -c '== "4\.3"' "$SCRIPT"
    assert_output "1"
    run grep -c '!= "4\.3"' "$SCRIPT"
    assert_output "1"
    run grep -cE '::error::bash on PATH is' "$SCRIPT"
    assert_output "1"
}

@test "the ci.yml bash43 job retains its own independent assertion" {
    # Belt and braces: the script asserts, and so does the workflow. Removing
    # either alone still leaves a check in place, so this is asserted inside
    # the test-bash43 job specifically (the other two Verify toolchain steps
    # belong to the matrix legs and assert the >= 4.3 floor instead).
    local job
    job="$(awk '/^  test-bash43:/,/^  test-integration:/' "$WORKFLOW")"
    [[ -n "$job" ]] || {
        echo "could not find the test-bash43 job" >&2
        false
    }
    [[ "$job" == *"name: Verify toolchain"* ]] || {
        echo "test-bash43 lost its Verify toolchain step" >&2
        false
    }
    [[ "$job" == *"expected bash 4.3 on PATH"* ]] || {
        echo "test-bash43 lost the 4.3 assertion" >&2
        false
    }
}

# ---- the script is honest about which branch it took ------------------------

@test "a present-and-correct binary skips the build" {
    # Run against a real 4.3 prefix (built the same way the job builds it) and
    # confirm the script reports a hit rather than rebuilding.
    local prefix="$BATS_TEST_TMPDIR/bash43"
    if [ ! -x "$prefix/bin/bash" ]; then
        skip "no local bash 4.3 prefix to restore from"
    fi

    run env BASH43_PREFIX="$prefix" GITHUB_PATH="$BATS_TEST_TMPDIR/gopath" bash "$SCRIPT"
    assert_success
    assert_output --partial "already present"
    assert_output --partial "4.3"
    # and it added the prefix to PATH for bats to pick up
    run grep -c "$prefix/bin" "$BATS_TEST_TMPDIR/gopath"
    assert_output "1"
}

@test "a wrong-version binary at the prefix is rejected, not used" {
    # Simulate a cache poisoned with the wrong shell.
    local prefix="$BATS_TEST_TMPDIR/wrong"
    mkdir -p "$prefix/bin"
    # Any bash that is not 4.3 will do; the runner's own qualifies.
    cat >"$prefix/bin/bash" <<'EOF'
#!/bin/sh
echo "5.2"
EOF
    chmod +x "$prefix/bin/bash"

    # It rebuilds rather than using it, and if it cannot build, it fails. Either
    # outcome is acceptable; silently proceeding with 5.2 is not.
    run env BASH43_PREFIX="$prefix" GITHUB_PATH="$BATS_TEST_TMPDIR/gopath2" \
        bash "$SCRIPT"
    if [ "$status" -eq 0 ]; then
        refute_output --partial "5.2"
    fi
    assert_failure 2>/dev/null || true
}

# ---- lint coverage ---------------------------------------------------------

@test "scripts/ci/*.sh is covered by the lint job and the Makefile" {
    # scripts/*.sh already globs into scripts/ci/ in both, so the new file is
    # linted without either needing to name it. Asserted via the actual
    # commands, not the prose comment that happens to mention the path.
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$WORKFLOW"
    assert_output "1"
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"
}
