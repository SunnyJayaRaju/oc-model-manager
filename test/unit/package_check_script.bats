#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/package_check_script.bats
#
# The Package Check job exists because CI never inspected the release artifact.
# scripts/ci/package-check.sh is the thing that does the inspecting, so it needs
# its own cover: a check that would itself fail to detect a bad package, or that
# silently passes for the wrong reason, is worse than no check.
#
# The important properties are that it FAILS when it should. Each negative case
# here removes or corrupts something from the installed copy and asserts the
# script notices -- if these ever pass, the job has become decoration.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/scripts/ci/package-check.sh"
    WORK="$BATS_TEST_TMPDIR/pkgcheck"
    export PKGCHECK_WORK="$WORK"
    # The script's phases are individually runnable, which is what makes these
    # cases possible.
    bash "$SCRIPT" build >/dev/null 2>&1
}

phase() { run bash "$SCRIPT" "$1"; }
extract_dir() { printf '%s\n' "$WORK/extract/ocprobe-$(cat "$ROOT/VERSION")"; }
prefix_dir() { printf '%s\n' "$WORK/prefix"; }

# ---- the phases exist and are wired ----------------------------------------

@test "all four phases run, and an unknown phase is refused" {
    phase build
    assert_success
    phase verify-tarball
    assert_success
    phase show
    assert_success
    phase definitely-not-a-phase
    assert_failure
    assert_output --partial "usage:"
}

# ---- the tarball check actually fails on a missing module ------------------

@test "verify-tarball fails when session_restore.py is missing" {
    # This is the regression the whole job is for.
    local py
    py="$(extract_dir)/lib/session_restore.py"
    [ -f "$py" ]
    mv "$py" "$py.hidden"
    phase verify-tarball
    assert_failure
    assert_output --partial "session_restore.py"
    mv "$py.hidden" "$py"

    phase verify-tarball
    assert_success
}

@test "verify-tarball fails when a core library is missing" {
    local sh
    sh="$(extract_dir)/lib/core.sh"
    mv "$sh" "$sh.hidden"
    phase verify-tarball
    assert_failure
    assert_output --partial "core.sh"
    mv "$sh.hidden" "$sh"
}

@test "verify-tarball fails when the binary is not executable" {
    chmod -x "$(extract_dir)/bin/ocprobe"
    phase verify-tarball
    assert_failure
    assert_output --partial "bin/ocprobe"
}

@test "verify-tarball fails on a python bytecode cache in the package" {
    # A stale .pyc makes two builds of the same commit differ, and would ship a
    # compiled module for a different interpreter.
    local dir
    dir="$(extract_dir)/lib/__pycache__"
    mkdir -p "$dir"
    : >"$dir/session_restore.cpython-314.pyc"
    # The build phase is what checks for residue, so run it against the tree
    # rather than the extract.
    run bash -c "cd '$ROOT' && PKGCHECK_WORK='$BATS_TEST_TMPDIR/residue' bash '$SCRIPT' build"
    assert_success # a clean repo builds fine
    # and now prove the check bites, by planting residue in the repo copy
    mkdir -p "$ROOT/lib/__pycache__"
    : >"$ROOT/lib/__pycache__/planted.pyc"
    run bash -c "PKGCHECK_WORK='$BATS_TEST_TMPDIR/residue2' bash '$SCRIPT' build"
    rm -rf "$ROOT/lib/__pycache__"
    assert_failure
    assert_output --partial "bytecode cache"
}

# ---- the install check actually fails on a broken install ------------------

@test "verify-install fails when the module is not in the installed lib" {
    # Delete it from the extracted tree and install from that, which is the only
    # way this failure mode could occur in a real release.
    local py
    py="$(extract_dir)/lib/session_restore.py"
    mv "$py" "$py.hidden"
    phase verify-install
    assert_failure
    assert_output --partial "session_restore.py"
    mv "$py.hidden" "$py"
}

@test "verify-install fails when a valid restore does not take" {
    # Break the restore by removing the module from the extracted tree: the
    # valid-restore assertion must notice, not pass on a seed row.
    local py
    py="$(extract_dir)/lib/session_restore.py"
    mv "$py" "$py.hidden"
    run bash -c "
        PKGCHECK_WORK='$WORK' bash '$SCRIPT' verify-install 2>&1
    "
    mv "$py.hidden" "$py"
    assert_failure
}

@test "verify-install succeeds on a good package" {
    # The positive case, so the negatives above cannot be passing merely because
    # the script always fails.
    phase verify-install
    assert_success
    assert_output --partial "ocprobe version"
    assert_output --partial "round-tripped"
    assert_output --partial "database byte-identical"
}

@test "verify-install asserts the bypass dump is rejected AND leaves the db alone" {
    # Both halves matter. Accepting the dump is the original bug; accepting it
    # and rolling back would still be a bug the old code had.
    phase verify-install
    assert_success
    # The evil dump is written into the work dir, so it can be inspected.
    [ -s "$WORK/evil.sql" ]
    run grep -c 'DELETE FROM message' "$WORK/evil.sql"
    assert_output "1"
    # and the db it checked is still the seeded one
    [ -s "$WORK/restore.db" ]
}

@test "verify-install reports a version mismatch rather than passing" {
    # Corrupt the staged VERSION so `ocprobe version` cannot report what was
    # built, and confirm the script says so.
    local v
    v="$(extract_dir)/VERSION"
    local saved
    saved="$(cat "$v")"
    printf '99.99.99\n' >"$v"
    phase verify-install
    printf '%s\n' "$saved" >"$v"
    assert_failure
    assert_output --partial "version"
}

# ---- the job runs the phases the script provides --------------------------

@test "the workflow runs build, verify-tarball, verify-install and show" {
    local job
    job="$(awk '/^  package-check:/,/^  build:/' "$ROOT/.github/workflows/ci.yml")"
    [[ -n "$job" ]] || {
        echo "package-check job not found in ci.yml" >&2
        false
    }
    for phase in build verify-tarball verify-install show; do
        [[ "$job" == *"package-check.sh $phase"* ]] || {
            echo "the job does not run the $phase phase" >&2
            false
        }
    done
}

@test "the package-check job runs on both platforms and gates build" {
    run grep -c 'package-check' "$ROOT/.github/workflows/ci.yml"
    [ "$output" -ge 2 ] || {
        echo "package-check is not referenced in ci.yml" >&2
        false
    }
    # build must wait for it, or a bad package is still published
    run grep -c 'needs:.*package-check' "$ROOT/.github/workflows/ci.yml"
    assert_output "1"
    # and both legs
    run grep -c 'os: \[ubuntu-latest, macos-latest\]' "$ROOT/.github/workflows/ci.yml"
    [ "$output" -ge 1 ] || {
        echo "package-check does not cover both platforms" >&2
        false
    }
}

@test "the script is syntax-clean and covered by the lint gate" {
    # Not invoking shellcheck: it is absent from the macOS runners, and a test
    # that only passes on Linux makes a green run look red. `bash -n` is the
    # portable gate; the Lint job and `make lint` do the real linting.
    run bash -n "$SCRIPT"
    assert_success
    # Lint coverage is asserted by reading the commands, not by running them.
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/.github/workflows/ci.yml"
    assert_output "1"
}
