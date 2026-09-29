#!/usr/bin/env bash
# ============================================================================
# scripts/ci/check-workflow-env.sh
#
# Rejects GITHUB_*/RUNNER_* names in .github/workflows that are not real GitHub
# Actions default environment variables.
#
# Why this exists: `echo "REPO_SLUG=${GITHUBUB_REPOSITORY}"` sat in the homebrew
# job for a while. Nothing complained. The step had no `set -u`, so the
# expansion was the empty string; that was written to $GITHUB_ENV as an empty
# REPO_SLUG; and the consumer, scripts/update-tap-formula.sh, has its own
# `die "REPO_SLUG is required"`. So the failure surfaced as a hard stop in a
# *different* step, in a job gated on a tag push, on a tag that has never been
# created. Every green run said nothing, because a run that never pushes a tag
# never reaches the line.
#
# A shellcheck-style workflow lint cannot see this: it checks shell files, and
# it has no list of GitHub's built-in variable names. So the names are listed
# here, and anything unlisted is treated as a mistake.
#
# Three things are deliberately NOT mistakes:
#   - `secrets.GITHUB_TOKEN` and any other `secrets.*` / `github.*` reference.
#     Those are context lookups, not environment variables, and every workflow
#     that uses secrets.GITHUB_TOKEN would otherwise be reported.
#   - A name the workflow itself defines as a YAML key, e.g.
#         - env:
#             GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
#           run: echo "$GITHUB_TOKEN" | wc -c
#     That is a step-local variable, not a reference to a default, and it is a
#     completely normal thing for a workflow to do -- flagging it would make the
#     guard fail on correct workflows, which is how guards get deleted.
#   - Nothing at all: a directory with no workflows is a pass, but a directory
#     that does not exist is a failure, so a mistyped path cannot hide a repo.
#
# Implementation note: this uses sed + grep, deliberately, and not awk. On the
# machine this was written on, /usr/bin/awk's gsub()/sub() silently fail to
# modify a local variable (they work on $0 and on fields) -- it returns the
# right match count and leaves the variable untouched. A check built on that
# would have reported every token on every line, or none, depending on which
# half of the bug you hit. sed and grep behave normally.
#
# Usage: scripts/ci/check-workflow-env.sh [DIR]   (default: .github/workflows)
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:-$ROOT/.github/workflows}"

if [[ ! -d "$DIR" ]]; then
	echo "check-workflow-env: not a directory: $DIR" >&2
	exit 1
fi

# GitHub Actions default environment variables, plus the runner ones.
# https://docs.github.com/en/actions/learn-github-actions/variables#default-environment-variables
readonly KNOWN_GITHUB="GITHUB_ACTION GITHUB_ACTION_PATH GITHUB_ACTION_REPOSITORY \
GITHUB_ACTIONS GITHUB_ACTOR GITHUB_ACTOR_ID GITHUB_API_URL GITHUB_BASE_REF \
GITHUB_ENV GITHUB_EVENT_NAME GITHUB_EVENT_PATH GITHUB_GRAPHQL_URL GITHUB_HEAD_REF \
GITHUB_JOB GITHUB_OUTPUT GITHUB_PATH GITHUB_REF GITHUB_REF_NAME GITHUB_REF_PROTECTED \
GITHUB_REF_TYPE GITHUB_REPOSITORY GITHUB_REPOSITORY_ID GITHUB_REPOSITORY_OWNER \
GITHUB_REPOSITORY_OWNER_ID GITHUB_RETENTION_DAYS GITHUB_RUN_ATTEMPT GITHUB_RUN_ID \
GITHUB_RUN_NUMBER GITHUB_SERVER_URL GITHUB_SHA GITHUB_STEP_SUMMARY \
GITHUB_TRIGGERING_ACTOR GITHUB_WORKFLOW GITHUB_WORKFLOW_REF GITHUB_WORKFLOW_SHA \
GITHUB_WORKSPACE"
readonly KNOWN_RUNNER="RUNNER_ARCH RUNNER_DEBUG RUNNER_NAME RUNNER_OS RUNNER_TEMP \
RUNNER_TOOL_CACHE RUNNER_TRACKING_ID"

mapfile -t FILES < <(find "$DIR" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)

if ((${#FILES[@]} == 0)); then
	echo "check-workflow-env: no workflow files in $DIR, nothing to check"
	exit 0
fi

is_known() {
	local tok="$1" list
	if [[ "$tok" == GITHUB_* ]]; then
		list="$KNOWN_GITHUB"
	else
		list="$KNOWN_RUNNER"
	fi
	[[ " $list " == *" $tok "* ]]
}

fail=0
for f in "${FILES[@]}"; do
	name="$(basename "$f")"
	# Names this workflow defines itself, e.g. an `env:` key. Collected first,
	# because whether a bare reference is legitimate depends on whether some
	# other line in the same file defines it. Comments are stripped here too, so
	# that a commented-out key does not make a real reference look defined.
	local_keys="$(
		sed -E 's/(^|[[:space:]])#.*$/\1/' "$f" |
			grep -Eo '^[[:space:]]*(GITHUB|RUNNER)[A-Z0-9_]*[[:space:]]*:' |
			grep -Eo '(GITHUB|RUNNER)[A-Z0-9_]*' | sort -u | tr '\n' ' '
	)" || true
	read -r -a LOCAL <<<"$local_keys"

	# Blank the two exempt constructs, then pull out every remaining
	# GITHUB_*/RUNNER_* token with its line number. Blanking (rather than
	# skipping the line) is what keeps a legitimate use of a token from hiding
	# a bad one on the same line.
	#
	# YAML comments are stripped first. A misspelling in a comment is
	# documentation, not behaviour, and the comment recording the GITHUBUB_ bug
	# has to be able to name it.
	bad="$(
		sed -E \
			-e 's/(secrets|github)\.[A-Za-z0-9_]+/ /g' \
			-e 's/(^|[[:space:]])#.*$/\1/' \
			"$f" |
			grep -nEo '(GITHUB|RUNNER)[A-Z0-9_]*' |
			while IFS=: read -r lineno tok; do
				is_known "$tok" && continue
				seen_locally=0
				for k in ${LOCAL[@]+"${LOCAL[@]}"}; do
					[[ "$k" == "$tok" ]] && seen_locally=1 && break
				done
				((seen_locally)) && continue
				printf '%s:%s: %s is not a GitHub Actions built-in environment variable\n' \
					"$name" "$lineno" "$tok"
			done
	)" || true

	if [[ -n "$bad" ]]; then
		printf '%s\n' "$bad" >&2
		fail=1
	fi
done

if ((fail)); then
	cat >&2 <<-'EOF'

		check-workflow-env: a GITHUB_*/RUNNER_* name above is not a real built-in.

		A misspelled built-in expands to the empty string rather than failing, so
		the symptom appears later and somewhere else -- typically as a guard in a
		consumer script, on a code path (a tag push, a scheduled job) that ordinary
		CI never exercises. Add the real name to KNOWN_* in
		scripts/ci/check-workflow-env.sh only if it is genuinely a GitHub default.
	EOF
	exit 1
fi

printf 'check-workflow-env: %d workflow file(s), no unknown GITHUB_*/RUNNER_* names\n' "${#FILES[@]}"
