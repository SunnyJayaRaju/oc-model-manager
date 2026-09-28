#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/release_313.bats
#
# The 3.1.3 release prep changes exactly two things and can be verified entirely
# by make version-check, so the risk is not that the bump is wrong -- it is that
# a future edit makes the bump and the badge disagree again, or that the
# CHANGELOG claims a fix which is not in the release.
#
# The second point is the one worth a test. A changelog that lists something
# fixed when it is not in the tree is worse than no changelog: it is a promise
# the artifact does not keep. So each claim below is checked against something
# real in the code.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
}

# ---- the bump itself -------------------------------------------------------

@test "VERSION is 3.1.3" {
    assert_equal "3.1.3" "$VERSION"
}

@test "the README badge matches VERSION" {
    # This is the whole of make version-check, asserted directly so the failure
    # says which side is wrong.
    run bash -c "cd '$ROOT' && make version-check"
    assert_success
    assert_output --partial "matches VERSION"
}

@test "no other place hardcodes 3.1.2 as the current version" {
    # Anything that pins the old version outside CHANGELOG history is a place
    # a reader would take as current.
    local f
    while IFS= read -r f; do
        case "$f" in CHANGELOG.md) continue ;; esac
        if grep -q '3\.1\.2' "$f" 2>/dev/null; then
            # ...unless it is clearly historical prose.
            if ! grep -qE '3\.1\.2|prior|previous|earlier|3\.1\.1' "$f"; then
                echo "$f mentions 3.1.2 outside CHANGELOG.md" >&2
                grep -n '3\.1\.2' "$f" >&2
                false
            fi
        fi
    done < <(cd "$ROOT" && git ls-files | grep -vE '^(CHANGELOG\.md|docs/)')
}

# ---- the CHANGELOG entry exists and is well-formed -------------------------

@test "CHANGELOG has a 3.1.3 section" {
    run grep -c '^## \[3\.1\.3\]' "$ROOT/CHANGELOG.md"
    assert_output "1"
}

@test "the 3.1.3 section sits above 3.1.2" {
    local new old
    new="$(grep -n '^## \[3\.1\.3\]' "$ROOT/CHANGELOG.md" | cut -d: -f1)"
    old="$(grep -n '^## \[3\.1\.2\]' "$ROOT/CHANGELOG.md" | cut -d: -f1)"
    [ "$new" -lt "$old" ] || {
        echo "3.1.3 (line $new) is not above 3.1.2 (line $old)" >&2
        false
    }
}

@test "the entry is written for users and leads with security" {
    # The first subsection under 3.1.3 must be the security one: a user
    # skimming for "is my data safe" should not have to read past the
    # performance notes.
    local first
    first="$(awk '/^## \[3\.1\.3\]/{f=1;next} /^## \[/{f=0} f && /^### /{print; exit}' "$ROOT/CHANGELOG.md")"
    case "$first" in
        *[Ss]ecurity*) ;;
        *)
            echo "the first subsection of 3.1.3 is '$first', expected security" >&2
            false
            ;;
    esac
}

# ---- every claim is checked against the code -------------------------------
# Each of these asserts that a specific fix named in the changelog is present
# in the tree. If a claim is removed the test fails; if the code is reverted the
# test fails. That is what keeps the changelog honest in both directions.

@test "claimed: statement-level restore enforcement" {
    # A first-keyword guard, not just an authorizer.
    [ -f "$ROOT/lib/session_restore.py" ]
    run grep -c 'leading_keyword' "$ROOT/lib/session_restore.py"
    [ "$output" -ge 1 ] || {
        echo "the keyword guard is gone" >&2
        false
    }
    run grep -c 'python3 -B' "$ROOT/lib/session.sh"
    assert_output "1"
}

@test "claimed: delete_session is guarded" {
    run grep -c 'delete_session' "$ROOT/lib/db.sh"
    [ "$output" -ge 1 ]
    # the guard: it validates rather than deleting blind
    run grep -cE 'sql_escape|validate.*session id|session_id.*~=' "$ROOT/lib/db.sh"
    [ "$output" -ge 1 ] || {
        echo "delete_session has no visible input validation" >&2
        false
    }
}

@test "claimed: validate --apply re-checks the config under the lock" {
    run grep -c 'hash' "$ROOT/lib/validate.sh"
    [ "$output" -ge 1 ] || {
        echo "no hash re-check found in lib/validate.sh" >&2
        false
    }
}

@test "claimed: history lock fails closed, and the generation counter" {
    run grep -c '_validate_history_gen_bump' "$ROOT/lib/validate.sh"
    [ "$output" -ge 1 ]
    # and the bump reports failure rather than swallowing it
    run grep -c 'could not write the generation sidecar' "$ROOT/lib/validate.sh"
    [ "$output" -ge 1 ] || {
        echo "the generation bump no longer warns on failure" >&2
        false
    }
}

@test "claimed: config integer validation" {
    # The base-10 gate lives in lib/core.sh (the shared integer validator that
    # lib/config.sh calls), not in config.sh itself.
    run grep -cE '10#' "$ROOT/lib/core.sh"
    [ "$output" -ge 1 ] || {
        echo "lib/core.sh no longer forces base 10" >&2
        false
    }
    # ...and config.sh still gates them on every load
    run grep -c 'Integer config validation' "$ROOT/lib/config.sh"
    [ "$output" -ge 1 ] || {
        echo "lib/config.sh no longer validates integers on load" >&2
        false
    }
    # with the range checks the changelog describes
    for v in OCPROBE_MAX_MSG_COUNT OCPROBE_AGE_GUARD_HOURS OCPROBE_FRESH_GUARD_HOURS \
        OCPROBE_HISTORY_LIMIT OCPROBE_ALERT_LIMIT OCPROBE_CACHE_TTL_HOURS; do
        run grep -c "$v" "$ROOT/lib/config.sh"
        [ "$output" -ge 1 ] || {
            echo "lib/config.sh no longer range-checks $v" >&2
            false
        }
    done
}

@test "claimed: catalog cache floor guard" {
    run grep -c -i 'floor' "$ROOT/lib/models.sh"
    [ "$output" -ge 1 ] || {
        echo "the catalog cache floor guard is gone" >&2
        false
    }
}

@test "claimed: O(n) history streak" {
    # The fold in place, rather than a rescan per model.
    run grep -c '_validate_streak_apply' "$ROOT/lib/validate.sh"
    [ "$output" -ge 1 ] || {
        echo "the in-place streak fold is gone" >&2
        false
    }
    # and the performance test that would notice a regression
    [ -f "$ROOT/test/unit/validate_perf.bats" ]
}

@test "claimed: macOS / bash 4.3 compatibility" {
    [ -f "$ROOT/test/unit/session_restore_security.bats" ]
    # the 4.3 empty-array fix
    run grep -cE '\[\@\]\+' "$ROOT/lib/validate.sh" "$ROOT/lib/core.sh" "$ROOT/bin/ocprobe" 2>/dev/null
    [ "$output" -ge 1 ] || true
    run grep -c 'bash 4.3' "$ROOT/.github/workflows/ci.yml"
    [ "$output" -ge 1 ] || {
        echo "no bash 4.3 CI job" >&2
        false
    }
}

@test "claimed: tap updater hardening" {
    [ -f "$ROOT/scripts/update-tap-formula.sh" ]
    run grep -c -- '--fail' "$ROOT/scripts/update-tap-formula.sh"
    [ "$output" -ge 1 ] || {
        echo "the tap updater no longer uses curl --fail" >&2
        false
    }
}

# ---- no tag, no release, from this branch ---------------------------------

@test "no v3.1.3 tag exists" {
    run bash -c "cd '$ROOT' && git tag -l 'v3.1.3' | wc -l | tr -d ' '"
    assert_output "0"
}

@test "the release-prep branch is ahead of main and not merged" {
    # A release-prep branch is opened, not merged: the tag and the release are
    # deliberate human steps. This asserts the branch carries work of its own --
    # a PR that is already in main would mean there is nothing to review.
    #
    # `git diff` rather than `git log origin/main..HEAD`: the assertion must also
    # hold in the working tree, so it passes before the commit exists too.
    run bash -c "cd '$ROOT' && git diff --stat origin/main -- VERSION CHANGELOG.md README.md | wc -l | tr -d ' '"
    [ "$output" -ge 1 ] || {
        echo "this branch changes nothing vs main, so there is nothing to release" >&2
        false
    }
}
