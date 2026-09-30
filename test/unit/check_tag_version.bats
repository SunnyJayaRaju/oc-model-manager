#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/check_tag_version.bats
#
# The build job used to adopt whatever tag was pushed and overwrite VERSION
# with it:
#
#     - name: Set version from tag
#       run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
#
# So tagging v9.9.9 against a tree whose VERSION says 3.1.2 produced a release
# that claimed to be 9.9.9, with the source's own version silently discarded --
# and no test noticed, because the tests never read the build job.
#
# scripts/ci/check-tag-version.sh now refuses. The negative cases here are the
# point: a check that only ever passes is indistinguishable from no check.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$ROOT/scripts/ci/check-tag-version.sh"
    CURRENT="$(tr -d '[:space:]' <"$ROOT/VERSION")"
}

# Runs the script against the real VERSION file, with a given tag.
# RELEASE_TAG and GITHUB_REF_NAME are both cleared unless the test sets one:
# the script falls back to GITHUB_REF_NAME, and Actions sets that to "16/merge"
# for a pull-request build. An empty RELEASE_TAG therefore did not mean "no
# tag" -- it meant "use the branch ref", which is a different (and correct) code
# path being tested under the wrong name.
with_tag() { run env -u GITHUB_REF_NAME RELEASE_TAG="$1" REPO_ROOT="$ROOT" bash "$SCRIPT" --quiet; }
with_tag_and_root() { # $1 = tag, $2 = a tree with a different VERSION
    run env RELEASE_TAG="$1" REPO_ROOT="$2" bash "$SCRIPT" --quiet
}

# ---- the happy path --------------------------------------------------------

@test "a tag matching VERSION passes and prints the version" {
    with_tag "v$CURRENT"
    assert_success
    assert_output "$CURRENT"
}

@test "a tag without the leading v is rejected" {
    with_tag "$CURRENT"
    assert_failure
    assert_output --partial "does not match"
}

@test "a tag with a pre-release suffix is rejected" {
    # v3.1.3-rc1 is a real thing people tag. It is not a version VERSION can
    # hold, so it must not silently build a release.
    with_tag "v${CURRENT}-rc1"
    assert_failure
    assert_output --partial "does not match"
}

@test "a tag with extra path components is rejected" {
    for bad in "release/v3.1.3" "v3" "v3.1" "v3.1.3.4" "v3.1.3 " "V3.1.3" "v-3.1.3" "v3.1.x" "v03.1.3 "; do
        with_tag "$bad"
        assert_failure || {
            echo "expected rejection for tag '$bad'" >&2
            false
        }
    done
}

@test "a tag carrying shell metacharacters is rejected, not executed" {
    local canary="$BATS_TEST_TMPDIR/pwned"
    with_tag "v1.2.3; touch $canary"
    assert_failure
    [ ! -e "$canary" ]
}

@test "an empty tag is rejected with a clear message" {
    with_tag ""
    assert_failure
    assert_output --partial "no tag provided"
}

@test "a tag is read from GITHUB_REF_NAME when RELEASE_TAG is unset" {
    # This is how the build job actually calls it.
    run env -u RELEASE_TAG GITHUB_REF_NAME="v$CURRENT" REPO_ROOT="$ROOT" \
        bash "$SCRIPT" --quiet
    assert_success
    assert_output "$CURRENT"
}

@test "a pull-request ref is rejected, not treated as a tag" {
    # Actions sets GITHUB_REF_NAME to "16/merge" on a pull-request build. The
    # fallback must not quietly accept that as a version -- it happens to be
    # caught by the pattern, but the point is that it is caught as a MALFORMED
    # TAG rather than being passed through into an artifact name.
    run env -u RELEASE_TAG GITHUB_REF_NAME="16/merge" REPO_ROOT="$ROOT" \
        bash "$SCRIPT" --quiet
    assert_failure
    assert_output --partial "does not match"
}

# ---- the mismatch case, which is the whole point ---------------------------

@test "a tag that disagrees with VERSION is refused" {
    # A version that is certainly not the current one.
    local other="99.99.99"
    with_tag "v$other"
    assert_failure
    assert_output --partial "does not match VERSION"
    assert_output --partial "$other"
    assert_output --partial "$CURRENT"
}

@test "the refusal explains what to do about it" {
    with_tag "v99.99.99"
    assert_failure
    assert_output --partial "make version-check"
}

@test "a matching tag in a tree with a different VERSION is refused" {
    # Proves the check reads the VERSION file rather than trusting the tag
    # alone: a temp tree whose VERSION says something else must fail even for a
    # well-formed tag.
    local tree="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$tree"
    printf '1.2.3\n' >"$tree/VERSION"
    with_tag_and_root "v$CURRENT" "$tree"
    assert_failure
    assert_output --partial "does not match VERSION"
    with_tag_and_root "v1.2.3" "$tree"
    assert_success
}

@test "a missing VERSION file is refused" {
    local tree="$BATS_TEST_TMPDIR/nover"
    mkdir -p "$tree"
    with_tag_and_root "v1.2.3" "$tree"
    assert_failure
    assert_output --partial "VERSION file not found"
}

@test "an empty VERSION file is refused" {
    local tree="$BATS_TEST_TMPDIR/emptyver"
    mkdir -p "$tree"
    : >"$tree/VERSION"
    with_tag_and_root "v1.2.3" "$tree"
    assert_failure
    assert_output --partial "VERSION is empty"
}

@test "a VERSION file with a trailing newline still matches" {
    # `tr -d [:space:]` handles the normal case; assert the real file has one.
    run bash -c "tail -c 1 '$ROOT/VERSION' | od -An -c | tr -d ' \\n'"
    assert_output '\n'
    with_tag "v$CURRENT"
    assert_success
}

# ---- the build job is wired to it -----------------------------------------

@test "the build job runs the check and no longer overwrites VERSION" {
    local build_job
    build_job="$(awk '/^  build:/,/^  release:/' "$ROOT/.github/workflows/ci.yml")"
    [[ -n "$build_job" ]] || {
        echo "build job not found in ci.yml" >&2
        false
    }
    # The old line adopted the tag blindly. Comments are stripped first, because
    # the replacement step quotes that old line in a comment explaining what it
    # replaced -- a grep over the raw body would match its own explanation.
    local code
    code="$(printf '%s\n' "$build_job" | grep -vE '^[[:space:]]*(#|$)')"
    if printf '%s\n' "$code" | grep -q 'VERSION=${GITHUB_REF_NAME#v}'; then
        echo "the build job still overwrites VERSION from the tag:" >&2
        printf '%s\n' "$code" | grep -n 'GITHUB_REF_NAME#v' >&2
        false
    fi
    # and the only place VERSION reaches GITHUB_ENV is from the check's output
    printf '%s\n' "$code" | grep -q 'check-tag-version.sh'
    # and the check runs before anything is packaged
    [[ "$build_job" == *"check-tag-version.sh"* ]] || {
        echo "the build job does not run check-tag-version.sh" >&2
        false
    }
    # with the tag passed through the environment, never interpolated into the
    # run: body
    [[ "$build_job" == *"RELEASE_TAG:"* ]] || {
        echo "the tag is not passed via env" >&2
        false
    }
}

@test "the check runs before the package is created" {
    # Order matters: validating after the tarball is built would mean building
    # an artifact from a bad tag before refusing.
    local build_job
    build_job="$(awk '/^  build:/,/^  release:/' "$ROOT/.github/workflows/ci.yml")"
    local check_line pkg_line
    check_line="$(printf '%s\n' "$build_job" | grep -n 'check-tag-version.sh' | head -1 | cut -d: -f1)"
    pkg_line="$(printf '%s\n' "$build_job" | grep -n 'Create release package' | head -1 | cut -d: -f1)"
    [ -n "$check_line" ] && [ -n "$pkg_line" ] || {
        echo "could not locate both steps in the build job" >&2
        false
    }
    [ "$check_line" -lt "$pkg_line" ] || {
        echo "the tag check runs at line $check_line, after packaging at $pkg_line" >&2
        false
    }
}

@test "the script is shellcheck-clean and linted" {
    # shellcheck is NOT installed on the macOS test runners, so it must not be
    # invoked from here: the Lint job (which installs it) and `make lint` are
    # the lint gates. This test did invoke it, and failed the macOS leg with
    # "shellcheck: command not found" -- a test that can only pass on one
    # platform is worse than no test, because it makes a real run look red.
    # `bash -n` is the portable syntax gate, so that is what runs here.
    run bash -n "$SCRIPT"
    assert_success
    # The lint COVERAGE is still asserted, by reading the commands rather than
    # executing them.
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/Makefile"
    assert_output "1"
    run grep -c 'shellcheck --severity=warning.*scripts/\*\.sh' "$ROOT/.github/workflows/ci.yml"
    assert_output "1"
}

  # ---- the stdout contract ---------------------------------------------------
  # This is the whole reason the script was changed. The build job does
  #     VERSION="$(bash scripts/ci/check-tag-version.sh)"
  #     echo "VERSION=$VERSION" >> "$GITHUB_ENV"
  # and the script used to print its confirmation AND the version, both to
  # stdout. $() captured two lines, GITHUB_ENV got a multi-line value, and the
  # runner refused it:
  #     ##[error]Unable to process file command 'env' successfully.
  #     ##[error]Invalid format '3.1.3'
  # That killed the v3.1.3 tag run (36679268678) at Build -> "Check the tag
  # against VERSION", with no release produced.
  #
  # So the contract is now: on success, stdout is EXACTLY the version and
  # nothing else. The tests below capture stdout with stderr discarded, which
  # is the only way to state that precisely -- bats' `run` merges the two.
  
  @test "STDOUT CONTRACT: stdout is exactly the version and nothing else" {
      # stderr is discarded, so any confirmation text written to stdout fails.
      local out rc=0
      out="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" \
          bash "$SCRIPT" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || {
          echo "expected success, got rc=$rc" >&2
          false
      }
      # Byte-exact: one line, no leading whitespace, no confirmation text.
      [ "$out" = "$CURRENT" ] || {
          printf 'stdout was NOT the bare version.\n  expected exactly: [%s]\n  got:             [%s]\n' \
              "$CURRENT" "$out" >&2
          false
      }
  }
  
  @test "STDOUT CONTRACT: stdout is a single line, with nothing after it" {
      # Guards the exact shape that broke the runner: a multi-line value.
      local out
      out="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" \
          bash "$SCRIPT" 2>/dev/null)"
      local lines
      lines="$(printf '%s' "$out" | grep -c '' || true)"
      [ "$lines" -eq 1 ] || {
          printf 'stdout should be one line, got %d:\n%s\n' "$lines" "$out" >&2
          false
      }
  }
  
  @test "STDOUT CONTRACT: stdout survives being written to GITHUB_ENV" {
      # The end-to-end version of the contract, using the real file format. A
      # multi-line value is exactly what the runner rejected, so reproduce that
      # rather than reasoning about it.
      local envfile="$BATS_TEST_TMPDIR/github_env"
      : >"$envfile"
      local version rc=0
      version="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" \
          bash "$SCRIPT" 2>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ]
      printf 'VERSION=%s\n' "$version" >>"$envfile"
      # A well-formed GITHUB_ENV entry is NAME=VALUE on one line.
      [ "$(wc -l <"$envfile" | tr -d ' ')" -eq 1 ] || {
          echo "GITHUB_ENV would have received a multi-line value:" >&2
          cat "$envfile" >&2
          false
      }
      grep -qx "VERSION=$CURRENT" "$envfile" || {
          echo "GITHUB_ENV entry is not 'VERSION=$CURRENT':" >&2
          cat "$envfile" >&2
          false
      }
  }
  
  @test "the confirmation still reaches a human, on stderr" {
      # Redirecting stdout to stderr must not have silenced the check: a build
      # log that says nothing about what it validated is worse than a bad one.
      local out rc=0
      out="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" \
          bash "$SCRIPT" 2>&1 1>/dev/null)" || rc=$?
      [ "$rc" -eq 0 ] || {
          echo "expected success, got rc=$rc" >&2
          false
      }
      grep -q "matches VERSION" <<<"$out" || {
          echo "the confirmation is no longer printed anywhere:" >&2
          printf '%s\n' "$out" >&2
          false
      }
  }
  
  @test "--quiet is accepted and changes nothing" {
      # Four call sites in this file still pass it. It is now redundant, not
      # removed, so a caller that still passes it keeps working; this asserts
      # it is genuinely a no-op rather than something that silences output.
      local without with_flag
      without="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" bash "$SCRIPT" 2>/dev/null)"
      with_flag="$(env -u GITHUB_REF_NAME RELEASE_TAG="v$CURRENT" REPO_ROOT="$ROOT" bash "$SCRIPT" --quiet 2>/dev/null)"
      [ "$without" = "$with_flag" ] || {
          printf -- '--quiet changed stdout:\n  without: [%s]\n  with:    [%s]\n' \
              "$without" "$with_flag" >&2
          false
      }
      [ "$with_flag" = "$CURRENT" ]
  }
  
  @test "a refusal still writes nothing to stdout" {
      # On failure stdout must be empty too, so a caller that ignores the exit
      # status gets an empty VERSION rather than a diagnostic sentence.
      local out rc=0
      out="$(env -u GITHUB_REF_NAME RELEASE_TAG="v99.99.99" REPO_ROOT="$ROOT" \
          bash "$SCRIPT" 2>/dev/null)" || rc=$?
      [ "$rc" -ne 0 ] || {
          echo "a mismatched tag should have been refused" >&2
          false
      }
      [ -z "$out" ] || {
          printf 'a refusal wrote to stdout: [%s]\n' "$out" >&2
          false
      }
  }
  
  # ---- a dry run of the real command, both ways -----------------------------
  # The demonstration the task asks for, executed rather than asserted about.
  
  @test "dry run: the real tag passes" {
      with_tag "v$CURRENT"
      assert_success
      echo "    RELEASE_TAG=v$CURRENT -> rc=0, version=$output"
  }

@test "dry run: a mismatched tag fails" {
    with_tag "v99.99.99"
    assert_failure
    echo "    RELEASE_TAG=v99.99.99 -> rc=$status (VERSION is $CURRENT)"
}
