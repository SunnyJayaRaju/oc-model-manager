#!/usr/bin/env bash
# ============================================================================
# scripts/ci/check-workflow-checkout-paths.sh
#
# Fail when one job contains two or more `actions/checkout` steps and any of
# them has no `path:`.
#
# Why this exists
# ---------------
# actions/checkout checks out into the job workspace by default and DELETES
# the working directory's contents before it runs -- including directories a
# previous checkout put there. Two checkouts without explicit `path:` values
# in one job therefore leave only the second repo on disk, silently. On the
# v3.2.0 tag push, the "Update Homebrew Formula" job checked the release repo
# into `source/` and THEN checked out the tap with no `path:`; the tap
# checkout's clean deleted `source/`, `source/scripts/update-tap-formula.sh`
# was gone, and the step died with exit 127 (run 44060706401). The updater's
# own `| tee` without pipefail once turned the same missing-file failure into
# a GREEN step (see test/unit/workflow_step_exit_status.bats); pipefail is
# pinned there, and this check pins the filesystem side.
#
# publish-release-to-tap.yml runs the same job in the safe order (tap first,
# updater into `source/` last) -- but ordering alone is the bug, not the cure:
# swap the steps and the other checkout is destroyed instead. Distinct
# `path:` values are the only shape that is correct in every order, so the
# rule is mechanical: every checkout in a multi-checkout job names its path.
#
# The check is static and heuristic on purpose, like check-workflow-env.sh:
# it matches lines by indentation instead of parsing YAML. Every action this
# repo uses puts `uses:` and its `with:` block on consecutive lines, so a
# checkout is considered to have a `path:` when a `path:` line appears between
# its `uses:` line and the next step marker (`- ` at step level), `name:`,
# `run:` or the next `uses:` line. Full-line comments are skipped and trailing
# comments are cut first, so documented bad shapes stay documented without
# changing the verdict.
#
# Usage: scripts/ci/check-workflow-checkout-paths.sh [DIR]
#        (default: .github/workflows)
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:-$ROOT/.github/workflows}"

if [[ ! -d "$DIR" ]]; then
    echo "check-workflow-checkout-paths: not a directory: $DIR" >&2
    exit 1
fi

shopt -s nullglob
files=("$DIR"/*.yml "$DIR"/*.yaml)
shopt -u nullglob

if ((${#files[@]} == 0)); then
    echo "check-workflow-checkout-paths: no workflow files in $DIR, nothing to check"
    exit 0
fi

report_job() {
    # $1 file, $2 job, $3 missing, $4 total
    if (($3 > 0 && $4 >= 2)); then
        printf '%s: job %s: %d of %d actions/checkout steps lack "path:"\n' "$1" "$2" "$3" "$4" >&2
        return 1
    fi
    return 0
}

fail=0
for f in "${files[@]}"; do
    name="$(basename "$f")"
    job="(top)"
    total=0
    missing=0
    in_window=0
    window_has_path=0
    window_line=0
    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        # Cut a trailing comment and left-trim. Nothing this check matches
        # (`uses:`, `path:`, `name:`, `run:`, `- `) contains a `#`, so a plain
        # cut is safe; a full-line comment becomes an empty line and no-ops.
        trimmed="${line%%#*}"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        [[ -z "$trimmed" ]] && continue

        # Job boundary: a key at exactly two spaces, e.g. `  lint:`. Matching
        # the raw line's two-space indent is what keeps nested keys (steps,
        # `with:` entries) from looking like job names. Reset per-job counters.
        if [[ "$line" =~ ^\ {2}[A-Za-z0-9_-]+:([[:space:]]*$) ]]; then
            if ((in_window)) && ((! window_has_path)); then
                missing=$((missing + 1))
                printf '%s:%d: actions/checkout without "path:" (job %s)\n' "$name" "$window_line" "$job" >&2
            fi
            if ! report_job "$name" "$job" "$missing" "$total"; then
                fail=1
            fi
            job="${line%%:*}"
            job="${job#  }"
            total=0
            missing=0
            in_window=0
            continue
        fi

        # A step marker ("- " at step level) ends any open with: window.
        if [[ "${trimmed:0:2}" == "- " ]] && ((in_window)) && ((! window_has_path)); then
            missing=$((missing + 1))
            printf '%s:%d: actions/checkout without "path:" (job %s)\n' "$name" "$window_line" "$job" >&2
        fi
        if [[ "${trimmed:0:2}" == "- " ]]; then
            in_window=0
        fi

        # A checkout opens a with:-window that the next marker closes. `continue`
        # so the opening line is never mistaken for the window's closer.
        case "$trimmed" in
            -?uses:*actions/checkout@* | uses:*actions/checkout@*)
                total=$((total + 1))
                in_window=1
                window_has_path=0
                window_line=$line_no
                continue
                ;;
        esac

        if ((in_window)); then
            case "$trimmed" in
                -?path:* | path:*) window_has_path=1 ;;
                uses:* | run:* | name:*)
                    if ((! window_has_path)); then
                        missing=$((missing + 1))
                        printf '%s:%d: actions/checkout without "path:" (job %s)\n' "$name" "$window_line" "$job" >&2
                    fi
                    in_window=0
                    ;;
            esac
        fi
    done <"$f"

    # EOF closes the last window and reports the last job block.
    if ((in_window)) && ((! window_has_path)); then
        missing=$((missing + 1))
        printf '%s:%d: actions/checkout without "path:" (job %s)\n' "$name" "$window_line" "$job" >&2
    fi
    if ! report_job "$name" "$job" "$missing" "$total"; then
        fail=1
    fi
done

if ((fail)); then
    echo "check-workflow-checkout-paths: FAILED -- a checkout without path: deletes whatever a" >&2
    echo "  previous checkout in the same job put in the workspace" >&2
    exit 1
fi
echo "check-workflow-checkout-paths: OK"
