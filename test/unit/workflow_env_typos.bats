#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/workflow_env_typos.bats
#
# A mistyped built-in env var is the quietest CI bug there is.
# `${GITHUBUB_REPOSITORY}` is not a typo the shell complains about: under
# `set -u` it is an unbound-variable error, but the step that used it ran without
# `set -u`, so the expansion was simply the empty string. That empty string was
# then written to $GITHUB_ENV as REPO_SLUG, and the release job that consumes it
# has its own guard -- so the symptom was not a crash in the step that was wrong,
# it was a hard failure in a *later* step, on a tag push, in a job that has
# never run because no tag has ever been created.
#
# Nothing in ordinary CI can catch that. This test can, and it must FAIL when a
# bad token is present -- a scanner that passes on a broken workflow is worse
# than no scanner, because it is trusted.
#
# Only the first test looks at the real .github/workflows. Every other case
# builds its own two-line workflow, so each one fails for exactly one reason: a
# copy of the real tree would let the repo's own current state decide the result
# of a test that is supposed to be about an injected line.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    CHECK="$ROOT/scripts/ci/check-workflow-env.sh"
    WORK="$BATS_TEST_TMPDIR/wf"
    mkdir -p "$WORK"
    # A minimal, known-good workflow to add lines to.
    cat >"$WORK/ci.yml" <<'EOF'
name: scratch
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo "$GITHUB_REPOSITORY"
EOF
}

# Scan a scratch tree containing only the synthetic workflow.
run_check() {
    bash "$CHECK" "$WORK"
}

@test "the real .github/workflows passes" {
    # The only test that reads the repository's own workflows. It is the one
    # that catches a typo introduced anywhere in .github/.
    run bash "$CHECK" "$ROOT/.github/workflows"

    assert_success
}

@test "the synthetic baseline passes on its own" {
    # Guards the other tests: if this fails, they are all failing for the wrong
    # reason and their "caught it" results would be meaningless.
    run run_check

    assert_success
}

@test "a duplicated-prefix typo like GITHUBUB_REPOSITORY is caught" {
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: echo "x=${GITHUBUB_REPOSITORY}"
EOF

    run run_check

    assert_failure
    assert_output --partial "GITHUBUB_REPOSITORY"
}

@test "a misspelled RUNNER_ var is caught" {
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: echo "x=$RUNNER_TEMPP"
EOF

    run run_check

    assert_failure
    assert_output --partial "RUNNER_TEMPP"
}

@test "a plausible-but-nonexistent GITHUB_ var is caught" {
    # The failure mode this guards: inventing a name that reads correctly.
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: echo "x=$GITHUB_REPOSITORY_OWNER_NAME"
EOF

    run run_check

    assert_failure
    assert_output --partial "GITHUB_REPOSITORY_OWNER_NAME"
}

@test "every real built-in default is accepted" {
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: |
          echo "$GITHUB_ACTION $GITHUB_ACTIONS $GITHUB_ACTOR $GITHUB_API_URL"
          echo "$GITHUB_ENV $GITHUB_OUTPUT $GITHUB_PATH $GITHUB_STEP_SUMMARY"
          echo "$GITHUB_HEAD_REF $GITHUB_JOB $GITHUB_REF $GITHUB_REF_NAME"
          echo "$GITHUB_REF_TYPE $GITHUB_REPOSITORY $GITHUB_REPOSITORY_OWNER"
          echo "$GITHUB_RUN_ID $GITHUB_RUN_NUMBER $GITHUB_SERVER_URL $GITHUB_SHA"
          echo "$GITHUB_WORKFLOW $GITHUB_WORKSPACE $GITHUB_EVENT_NAME"
          echo "$RUNNER_ARCH $RUNNER_OS $RUNNER_TEMP $RUNNER_TOOL_CACHE"
EOF

    run run_check

    assert_success
}

@test "secrets.GITHUB_TOKEN is not flagged -- it is a context, not an env var" {
    # GITHUB_TOKEN is not a default env var, and flagging it would make the
    # guard unusable: every workflow that uses secrets.GITHUB_TOKEN would fail.
    # This is the case that decides whether the check is practical.
    cat >>"$WORK/ci.yml" <<'EOF'
      - env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: echo "$GITHUB_TOKEN" | wc -c
EOF

    run run_check

    assert_success
}

@test "a secret whose name itself looks like a typo is not flagged" {
    # Same reason as above: a dotted reference is a context lookup, and a
    # workflow may legitimately read a secret called anything at all.
    cat >>"$WORK/ci.yml" <<'EOF'
      - env:
          T: ${{ secrets.GITHUBUB_REPOSITORY }}
        run: echo "$T"
EOF

    run run_check

    assert_success
}

@test "github.token and other contexts are not flagged" {
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: echo "${{ github.token }} ${{ github.repository }}"
EOF

    run run_check

    assert_success
}

@test "a typo in any workflow file is caught, with the filename reported" {
    cat >"$WORK/release-rehearsal.yml" <<'EOF'
name: rehearsal
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: echo "x=$RUNNER_TEMP2"
EOF

    run run_check

    assert_failure
    assert_output --partial "release-rehearsal.yml"
    assert_output --partial "RUNNER_TEMP2"
}

@test "a bad token on the same line as a good one is still caught" {
    # Guards against a check that stops scanning a line once it has seen a
    # legitimate reference -- the common shape is
    #   echo "$GITHUB_REF ${GITHUBUB_REPOSITORY}"
    cat >>"$WORK/ci.yml" <<'EOF'
      - run: echo "$GITHUB_REF ${GITHUBUB_REPOSITORY}"
EOF

    run run_check

    assert_failure
    assert_output --partial "GITHUBUB_REPOSITORY"
}

@test "a GITHUB_* used as an env: key is not flagged" {
    # A step-local env: value named GITHUB_TOKEN is a custom variable, not a
    # reference to a default one, and is a normal thing for a workflow to do.
    cat >>"$WORK/ci.yml" <<'EOF'
      - env:
          RUNNER_TRACE: "1"
        run: echo "$RUNNER_TRACE"
EOF

    run run_check

    assert_success
}

@test "a misspelling inside a comment is not an error" {
    # The comment that records the GITHUBUB_ bug has to be able to name it, and
    # a typo in prose cannot break a run -- only a typo in a run: body can.
    cat >>"$WORK/ci.yml" <<'EOF'
      # this used to be ${GITHUBUB_REPOSITORY}, which does not exist
      - run: echo "x=$GITHUBUB_REPOSITORY"
EOF

    run run_check

    assert_failure
    # The executable line is 9; the comment above it is 8. Only 9 is reported.
    assert_output --partial "ci.yml:9: GITHUBUB_REPOSITORY"
    refute_output --partial "ci.yml:8"
}

@test "no workflow files means nothing to check" {
    mkdir -p "$WORK/empty"

    run bash "$CHECK" "$WORK/empty"

    assert_success
}

@test "a missing directory is an error, not a silent pass" {
    # Otherwise a mistyped path turns the guard into decoration.
    run bash "$CHECK" "$WORK/does-not-exist"

    assert_failure
}
