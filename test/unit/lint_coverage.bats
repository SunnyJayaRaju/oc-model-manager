#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/lint_coverage.bats
#
# The lint gate must actually LOOK at every shell script in the repo.
#
# Why this exists
# ---------------
# `make lint` and the Lint job both ran
#
#     shellcheck --severity=warning bin/ocprobe lib/*.sh scripts/*.sh
#
# A shell glob does not cross a directory boundary, so `scripts/*.sh` matched
# exactly ONE file -- scripts/update-tap-formula.sh -- and none of the seven
# under scripts/ci/:
#
#     check-tag-version.sh  check-workflow-env.sh  check-workflow-secrets.sh
#     install-bash43.sh     package-check.sh       rehearsal.sh
#     verify-release.sh
#
# So the gate reported "clean" about scripts it had never read. verify-release.sh
# was rewritten in PR #23, that PR reported "shellcheck --severity=warning
# clean", and the claim was never tested -- the same glob was used to produce it.
#
# A coverage gap in a lint gate is worse than a missing check, because it is
# indistinguishable from a passing one.
#
# shellcheck is NOT invoked here: it is not installed on the macOS test runners
# (see the identical note in test/unit/check_tag_version.bats). This reads the
# globs instead, which is the part that was actually wrong.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
}

# Every tracked shell script, as a repo-root-relative path. `git ls-files`
# already reports exactly that form, which is the form the lint globs expand to,
# so no trimming happens here -- an earlier version stripped the first component
# and reported seven files as uncovered that were covered.
all_scripts() {
    git -C "$ROOT" ls-files '*.sh' bin/ocprobe | sort -u
}

# The path-like tokens a lint command passes to shellcheck, as written. Taken
# from the command rather than hardcoded here, so this test measures the gate
# that exists rather than one restated beside it.
lint_patterns() { # $1 = file to read the command out of
    grep -hE 'shellcheck --severity' "$1" |
        tr '\n\t' '  ' |
        sed -E 's/^[[:space:]]*@//' |
        tr ' ' '\n' |
        grep -E '^(bin|lib|scripts|test)/' |
        sort -u
}

# Expand the lint globs in the repo root and report what they match.
linted_by() { # $1 = file to read the command out of
    (
        cd "$ROOT"
        for pat in $(lint_patterns "$1"); do
            for f in $pat; do
                printf '%s\n' "$f"
            done
        done
    ) | sort -u
}

@test 'every tracked shell script is matched by the Makefile lint globs' {
    if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        skip 'not a git checkout'
    fi
    run bash -c "true"
    local missing
    missing="$(comm -23 <(all_scripts) <(linted_by "$ROOT/Makefile"))"
    [ -z "$missing" ] || {
        printf 'not covered by the Makefile lint globs:\n%s\n' "$missing" >&2
        false
    }
}

@test 'every tracked shell script is matched by the Lint job globs' {
    if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        skip 'not a git checkout'
    fi
    local missing
    missing="$(comm -23 <(all_scripts) <(linted_by "$ROOT/.github/workflows/ci.yml"))"
    [ -z "$missing" ] || {
        printf 'not covered by the Lint job globs:\n%s\n' "$missing" >&2
        false
    }
}

@test 'the seven scripts/ci/ files are individually reachable by a lint glob' {
    # The specific hole, asserted by name rather than inferred. If someone
    # removes scripts/*/*.sh, the first test catches it, but it will not say
    # which file went dark until someone reads the diff.
    if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
        skip 'not a git checkout'
    fi
    local covered f
    covered="$(linted_by "$ROOT/Makefile")"
    for f in scripts/ci/*.sh; do
        run grep -qxF "$f" <<<"$covered"
        [ "$status" -eq 0 ] || {
            echo "$f is not covered by make lint" >&2
            false
        }
    done
}

@test 'scripts/*.sh alone does NOT reach scripts/ci/, which is why it is not the only glob' {
    # Documents the mechanism, so the extra glob is not removed as redundant by
    # a reader who does not know what a shell glob does.
    run bash -c "cd '$ROOT' && for f in scripts/*.sh; do echo \"\$f\"; done"
    refute_output --partial "scripts/ci/"
    assert_success
}

# bash -n the same file list the Makefile lints. A function, not an inline
# `bash -c`, because a nested shell does not inherit bats' functions and
# word-splitting a newline-separated list through another layer of quoting is
# how the whole list once arrived as a single argument.
lint_syntax_ok() {
    local f
    while read -r f; do
        bash -n "$f" || return 1
    done < <(linted_by "$ROOT/Makefile")
    return 0
}

@test 'the syntax half of the lint gate runs here, and matches what CI runs' {
    # `make lint` itself is NOT executed from this file, and the reason is worth
    # stating because it has now been got wrong twice in one PR: it calls
    # shellcheck, which is not installed on the macOS test runners, so
    # `make -C . lint` fails there with
    #     /bin/sh: shellcheck: command not found
    #     make: *** [lint] Error 127
    # and turns a real run red for a reason that has nothing to do with what is
    # being tested. The Lint job installs shellcheck and runs it; that plus a
    # developer's own `make lint` are the gates. The coverage assertions above
    # are the part that was actually wrong, and they read the commands rather
    # than executing them.
    #
    # What runs here is the portable half -- the bash -n syntax sweep -- over the
    # same file list, so the nested scripts are at least syntax-checked
    # everywhere.
    run lint_syntax_ok
    assert_success
}

@test 'the Makefile and the Lint job lint the same files' {
    # They drifted once: three bin/ scripts were in the CI list and not in
    # `make lint`, so a developer running the local gate saw less than CI did.
    run diff <(linted_by "$ROOT/Makefile") <(linted_by "$ROOT/.github/workflows/ci.yml")
    assert_success
    [ -z "$output" ] || {
        printf 'the two lint lists differ:\n%s\n' "$output" >&2
        false
    }
}

@test 'the portable half of the gate is what runs here, and it is green' {
    # Re-asserted as its own test because it is the check that would have caught
    # a broken nested script, and because it must be visibly green: "the thing
    # that runs" and "the thing that is asserted" being the same command is the
    # point.
    run lint_syntax_ok
    assert_success
}

# There is deliberately no test here that greps test/unit for "shellcheck" or
# "make lint".
#
# A version of one was written and removed. It could not tell an execution from
# a mention: it flagged the `# shellcheck shell=bash` directive every bats file
# carries, the comments explaining why shellcheck is not invoked, a test named
# "validate.sh passes shellcheck", and its own @test line. Making it pass meant
# filtering until it stopped catching anything real, and a check that no longer
# discriminates is worse than no check -- it reads as coverage.
#
# What actually protects this is the Unit Tests (macos-latest) CI leg, which runs
# on a runner with no shellcheck. It failed this PR twice, at
# "shellcheck: command not found" and "make: *** [lint] Error 127", before any
# guard existed. That is the enforcement, and it is not something to be
# reimplemented in a regex.

@test 'the checker script under test is itself covered by the lint globs' {
    # Closed loop: this PR adds a script to scripts/ci/ and the gate must reach
    # it without anyone editing the globs by hand.
    run bash -c "cd '$ROOT' && for f in scripts/*/*.sh; do echo \"\$f\"; done"
    assert_output --partial "scripts/ci/check-workflow-secrets.sh"
    run bash -c "cd '$ROOT' && for f in scripts/*/*.sh; do echo \"\$f\"; done"
    assert_output --partial "scripts/ci/verify-release.sh"
}
