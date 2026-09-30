#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/check_workflow_secrets.bats
#
# Coverage for scripts/ci/check-workflow-secrets.sh, the guard against a `run:`
# body referencing a secret-backed variable that nothing in scope provides.
#
# The three cases the guard has to get right, and the direction each can fail:
#
#   (a) the REAL historical file, as it was merged, must FAIL. Taken from git, not
#       restated here, so this cannot quietly stop testing the actual bug because
#       a hand-copied fixture was edited.
#   (b) the current file must PASS.
#   (c) a DIFFERENT secret name, missing in a different way, must FAIL and name
#       the file, job and secret. A guard hardcoded to one variable is not a
#       guard.
#
# Then the false-positive guards, which matter more than they look. A static
# analysis tool that fails on correct workflows gets deleted, and then the real
# bug ships. Each of these is a shape that LOOKS like the bug and is not:
#   - a step-level env: that provides the name
#   - a $GITHUB_ENV export in an earlier step, which genuinely does provide it
#   - a non-secret variable that is also not provided (out of scope, by design)
#   - a $VAR mentioned only in a prose comment
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/scripts/ci/check-workflow-secrets.sh"
    WF="$BATS_TEST_TMPDIR/wf"
    mkdir -p "$WF"
}

# Write one workflow into the scratch dir and run the checker over it.
# Usage: check_with <<'YAML' ... YAML      (via `check_body`/`check_file`)
check_file() {
    run bash "$SCRIPT" "$WF"
}

# The commit whose publish-release-to-tap.yml is the merged-but-broken version:
# HOMEBREW_TAP_TOKEN used as a secret on two checkout steps, read as
# ${HOMEBREW_TAP_TOKEN:-} by the first step, provided by no env: anywhere.
# Fixed in 0180eef's successor, so this SHA stays reachable in history.
UNFIXED_COMMIT="0180eefa1e1fc96c2a944d90bb6c91cebcc6f02d"

# ---- (a) the real historical file must FAIL --------------------------------

@test "the real unfixed workflow from git history is rejected" {
    if ! git -C "$ROOT" cat-file -e "$UNFIXED_COMMIT^{commit}" 2>/dev/null; then
        skip "commit $UNFIXED_COMMIT is not in this checkout"
    fi
    git -C "$ROOT" show "$UNFIXED_COMMIT:.github/workflows/publish-release-to-tap.yml" \
        >"$WF/publish-release-to-tap.yml"

    check_file

    assert_failure
    # The message has to identify the three things a human needs to fix it.
    assert_output --partial "publish-release-to-tap.yml"
    assert_output --partial "job 'publish'"
    assert_output --partial "Validate the input"
    assert_output --partial '$HOMEBREW_TAP_TOKEN'
    # And it has to say what WAS in scope, or the fix is guesswork.
    assert_output --partial "job env: "
    assert_output --partial "GH_TOKEN"
}

@test "the unfixed commit is genuinely an ancestor, so (a) keeps testing the real file" {
    # Without this, a future rebase could make `git show` fail and the test above
    # would skip silently, which is the one outcome a regression test must not
    # have.
    if ! git -C "$ROOT" cat-file -e "$UNFIXED_COMMIT^{commit}" 2>/dev/null; then
        skip "commit $UNFIXED_COMMIT is not in this checkout"
    fi
    run git -C "$ROOT" merge-base --is-ancestor "$UNFIXED_COMMIT" HEAD
    assert_success
}

# ---- (b) the current file must PASS ---------------------------------------

@test "the current workflows pass" {
    check_file

    assert_success
    assert_output --partial "no secret-backed run: variable without an env: provider"
}

@test "every workflow in the repo is covered, not just ci.yml" {
    run bash "$SCRIPT"
    assert_success
    # Three as of this change: ci, publish-release-to-tap, release-rehearsal.
    assert_output --partial "3 workflow file(s)"
}

# ---- (c) a different secret, missing differently, must FAIL ---------------

@test "a different secret name with no provider is rejected and named" {
    cat >"$WF/release.yml" <<'YAML'
name: r
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ secrets.NPM_TOKEN }}
      - name: Use it
        run: |
          if [ -z "${NPM_TOKEN:-}" ]; then exit 1; fi
          echo "$NPM_TOKEN" | wc -c
YAML
    check_file

    assert_failure
    assert_output --partial "release.yml"
    assert_output --partial "job 'deploy'"
    assert_output --partial "Use it"
    assert_output --partial '$NPM_TOKEN'
    # And it must not be satisfied by the other workflow's contents.
    refute_output --partial "HOMEBREW_TAP_TOKEN"
}

@test 'a missing provider is caught when the secret is only in a with: block' {
    # The real bug's exact shape: the secret appears ONLY as an actions/checkout
    # `with: token:`, which is not an env: provider, and the run: body reads the
    # bare name.
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ secrets.DEPLOY_KEY }}
      - run: echo "$DEPLOY_KEY" > /dev/null
YAML
    check_file

    assert_failure
    assert_output --partial '$DEPLOY_KEY'
}

# ---- false-positive guards: shapes that look like the bug and are not ------

@test "a step-level env: provides the name" {
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: guarded
        env:
          ARTIFACT_TOKEN: ${{ secrets.ARTIFACT_TOKEN }}
        run: echo "$ARTIFACT_TOKEN"
YAML
    check_file

    assert_success
}

@test "a job-level env: provides the name" {
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    env:
      ARTIFACT_TOKEN: ${{ secrets.ARTIFACT_TOKEN }}
    steps:
      - run: echo "$ARTIFACT_TOKEN"
YAML
    check_file

    assert_success
}

@test 'a GITHUB_ENV export in an earlier step provides the name' {
    # ci.yml does exactly this with TAG. Without this rule the guard would fail
    # the repo's own workflow, and a guard that fails on correct code is a guard
    # that gets deleted.
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: set it
        env:
          RAW: ${{ secrets.RAW_VALUE }}
        run: echo "VALUE=$RAW" >> "$GITHUB_ENV"
      - name: use it
        run: echo "$VALUE"
YAML
    check_file

    assert_success
}

@test "a non-secret variable with no provider is not flagged" {
    # Out of scope by design. The guard is about secret-backed names; widening it
    # to every unset variable would mean implementing shell scope analysis, and
    # would produce noise on every workflow.
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$COMPLETELY_UNRELATED" "$NOPE"
YAML
    check_file

    assert_success
}

@test 'a secret only mentioned in a comment is not flagged' {
    # The prose in these workflows names the variables it is talking about. A
    # checker that read comments would flag its own documentation.
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          token: ${{ secrets.WRONG }}
      - name: guarded
        run: |
          # This used to read $WRONG directly, which is why it is now in env:.
          echo hello
YAML
    check_file

    assert_success
}

@test 'the built-in inputs.* and github.* contexts are not secrets' {
    cat >"$WF/x.yml" <<'YAML'
name: x
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$SOMETHING_ELSE"
YAML
    check_file

    assert_success
}

# ---- the tool's own behaviour ---------------------------------------------

@test "a missing directory is a failure, not a pass" {
    # So a mistyped path cannot hide the repo.
    run bash "$SCRIPT" "$BATS_TEST_TMPDIR/nope"
    assert_failure
    assert_output --partial "not a directory"
}

@test "an empty directory passes rather than erroring" {
    run bash "$SCRIPT" "$WF"
    assert_success
    assert_output --partial "0 workflow file(s)"
}

@test "invalid YAML is reported, not silently skipped" {
    printf 'name: x\non: push\njobs:\n  j:\n   - [unclosed\n' >"$WF/bad.yml"
    check_file

    assert_failure
    assert_output --partial "not valid YAML"
}

@test 'the checker is lint-clean and is covered by the lint gate' {
    # shellcheck is NOT installed on the macOS test runners, so it must not be
    # invoked from here: the Lint job (which installs it) and `make lint` are the
    # lint gates. This test DID invoke it, and failed the macOS leg of PR #25
    # with "shellcheck: command not found". A test that can only pass on one
    # platform is worse than no test, because it makes a real run look red.
    #
    # That mistake was already recorded in this repo at
    # test/unit/check_tag_version.bats, with the same explanation. It was not
    # read before the test was written.
    #
    # `bash -n` is the portable syntax gate, so that is what runs here.
    run bash -n "$SCRIPT"
    assert_success

    # The lint COVERAGE is still asserted, by reading the command rather than
    # executing it. `scripts/*.sh` is a glob, so this file is included; the point
    # is to prove the glob is still there, since a literal path list would let
    # this file drift out of linting unnoticed.
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"

    # And the file must actually be matched by that glob, not merely covered by
    # a pattern that has since stopped matching. Compared as a repo-relative
    # path: the glob yields `scripts/ci/...` while $SCRIPT is absolute, so an
    # absolute comparison silently never matches.
    run bash -c "cd '$ROOT' && for f in scripts/*/*.sh; do echo \"\$f\"; done"
    assert_output --partial "scripts/ci/check-workflow-secrets.sh"
}

@test "the Lint job runs this checker" {
    run grep -c 'check-workflow-secrets.sh' "$ROOT/.github/workflows/ci.yml"
    assert_success
    assert_output --partial "1"
}
