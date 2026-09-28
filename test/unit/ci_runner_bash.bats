#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/ci_runner_bash.bats
#
# The Package Check job installs the built tree into the layout Homebrew uses and
# then RUNS the installed binary. On macOS that binary is bash, and macOS ships
# bash 3.2 as /bin/bash. The unit job sidesteps this by installing Homebrew's
# bash and putting it first on PATH; the package-check job did not, so on
# macOS `ocprobe version` refused to start:
#
#     ocprobe requires bash 4.3 or newer; you are running bash 3.2.57
#
# A red CI run is the test working, but it is the wrong kind of test: this is a
# property of the runner, not of the package, and the job is supposed to be
# about the package.
#
# So the check is explicit: the job must install a modern bash on macOS and put
# it first on PATH before exercising the installed binary. This asserts that
# wiring, which is what would otherwise only be discovered by a red run.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORKFLOW="$ROOT/.github/workflows/ci.yml"
    JOB="$(awk '/^  package-check:/,/^  build:/' "$WORKFLOW")"
}

@test "the package-check job exists" {
    [ -n "$JOB" ] || {
        echo "package-check job not found in ci.yml" >&2
        false
    }
}

@test "macOS leg installs a modern bash" {
    # Without this the installed binary is bash 3.2 and refuses to start. The
    # unit job already does the same thing; this is the package-check leg.
    [[ "$JOB" == *"brew install"* ]] || {
        echo "the macOS leg does not run brew install at all" >&2
        false
    }
    [[ "$JOB" == *"jq sqlite3 coreutils bash"* ]] || {
        echo "the macOS leg does not install bash; found:" >&2
        printf '%s\n' "$JOB" | grep -n 'brew install' >&2
        false
    }
}

@test "the Homebrew bin directory is prepended to PATH" {
    # Ordering matters and is easy to break: GITHUB_PATH entries are prepended
    # and the LAST one written ends up FIRST. The venv must win for python3
    # (it has yaml/jsonschema) while Homebrew must still win for bash.
    [[ "$JOB" == *'echo "$(brew --prefix)/bin" >> "$GITHUB_PATH"'* ]] || {
        echo "Homebrew's bin is not prepended on the macOS leg" >&2
        false
    }
    # ...and the venv is written after it, which is what puts the venv first.
    local brew_line venv_line
    brew_line="$(printf '%s\n' "$JOB" | grep -n 'brew --prefix' | head -1 | cut -d: -f1)"
    venv_line="$(printf '%s\n' "$JOB" | grep -n 'venv/bin" >>' | head -1 | cut -d: -f1)"
    [ -n "$brew_line" ] && [ -n "$venv_line" ] || {
        echo "could not locate both PATH writes" >&2
        false
    }
    [ "$venv_line" -gt "$brew_line" ] || {
        echo "the venv is written before Homebrew, which would put Homebrew first on PATH and make python3 lack yaml" >&2
        false
    }
}

@test "the job asserts the bash it exercises is new enough" {
    # Belt and braces: if the ordering above is ever broken, say so clearly
    # rather than failing with the binary's own message mid-assertion.
    [[ "$JOB" == *"bash --version"* ]] || {
        echo "the package-check job never reports which bash it is using" >&2
        false
    }
}

@test "package-check.sh itself does not hardcode a bash" {
    # The script invokes `ocprobe`, not bash directly, so it should not be
    # choosing an interpreter -- that decision belongs to the workflow.
    run grep -cE '^\s*#!.*bash' "$ROOT/scripts/ci/package-check.sh"
    assert_output "1" # a shebang is fine
    run grep -cE 'BASH_VERSINFO|brew install' "$ROOT/scripts/ci/package-check.sh"
    assert_output "0"
}

@test "the other test jobs keep their own modern-bash wiring" {
    # The unit and integration legs were already correct: they install Homebrew
    # bash on macOS and verify >= 4.3. Asserted so this fix is not undone by a
    # later tidy-up that only looks at the new job.
    #
    # The job body is sliced with python rather than awk: these jobs contain
    # `strategy:` blocks with `os: [ubuntu-latest, macos-latest]`, and an awk
    # end-pattern of /^  [a-z-]+:$/ stops at a line that is not a job header,
    # yielding a body of a dozen characters and a false failure.
    local body
    for job in test-unit test-integration test-bash43; do
        body="$(python3 - "$WORKFLOW" "$job" <<'PY'
import re
import sys

text = open(sys.argv[1]).read()
name = sys.argv[2]
m = re.search(r"^  %s:\n(.*?)(?=^  [a-zA-Z0-9_-]+:\n|\Z)" % re.escape(name),
              text, re.S | re.M)
sys.stdout.write(m.group(1) if m else "")
PY
)"
        [ -n "$body" ] || {
            echo "job $job not found in the workflow" >&2
            false
        }
        if [[ "$job" == "test-bash43" ]]; then
            [[ "$body" == *"bash 4.3"* ]] || {
                echo "$job lost its 4.3 assertion" >&2
                false
            }
        else
            # installs a modern bash on macOS ...
            [[ "$body" == *"bash sqlite3"* || "$body" == *"coreutils bash"* ]] || {
                echo "$job no longer installs a modern bash on macOS" >&2
                false
            }
            # ... and verifies it, rather than discovering it mid-suite
            [[ "$body" == *"BASH_VERSINFO"* ]] || {
                echo "$job no longer verifies the bash version" >&2
                false
            }
        fi
    done
}
