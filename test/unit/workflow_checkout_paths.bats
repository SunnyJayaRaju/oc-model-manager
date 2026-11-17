#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/workflow_checkout_paths.bats
#
# Tests for scripts/ci/check-workflow-checkout-paths.sh, the static guard on
# multi-checkout jobs.
#
# Why this file exists: on the v3.2.0 tag push, the "Update Homebrew Formula"
# job checked the release repo into `source/` and then checked out the tap
# with no `path:`. actions/checkout deletes the working directory's contents
# before it runs, so the tap checkout silently erased `source/`, and the step
# died with exit 127 on `source/scripts/update-tap-formula.sh` (run
# 44060706401). The guard fails any job with two or more actions/checkout
# steps where any of them has no `path:`.
#
# The old workflow is pinned as a fixture (test/fixtures/
# ci-v3.2.0-checkout-order.yml, extracted from tag v3.2.0) rather than
# reproduced from memory: if the bug ever returns in a shape the heuristic
# misses, the fixture is the record of what it must catch. Three assertions
# matter, and all three are here:
#   - the v3.2.0 workflow FAILS the guard (the bug is caught, not asserted)
#   - the current workflows PASS it
#   - the catch-up workflow publish-release-to-tap.yml PASSes it, so the two
#     release paths stay under the same rule
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GUARD="$ROOT/scripts/ci/check-workflow-checkout-paths.sh"
    WORK="$BATS_TEST_TMPDIR/workflows"
    mkdir -p "$WORK"
}

@test "guard FAILS the v3.2.0 ci.yml (tap checkout after source checkout, no path)" {
    cp "$ROOT/test/fixtures/ci-v3.2.0-checkout-order.yml" "$WORK/ci.yml"
    run bash "$GUARD" "$WORK"
    assert_failure
    assert_output --partial 'job homebrew: 1 of 2 actions/checkout steps lack "path:"'
}

@test "guard PASSES the current ci.yml (every multi-checkout checkout has a path)" {
    run bash "$GUARD" "$ROOT/.github/workflows"
    assert_success
    assert_output --partial "check-workflow-checkout-paths: OK"
}

@test "guard ignores single-checkout jobs but still reports them" {
    # The lint job has one checkout with no path -- harmless by the rule, but
    # the report names it so the exemption is visible, not silent, and the
    # verdict stays OK because the rule only bites multi-checkout jobs.
    mkdir -p "$WORK/one"
    cat >"$WORK/one/single.yml" <<'YAML'
name: single
on: push
jobs:
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0
YAML
    run bash "$GUARD" "$WORK/one"
    assert_success
    assert_output --partial 'actions/checkout without "path:" (job lint)'
    assert_output --partial "check-workflow-checkout-paths: OK"
}
