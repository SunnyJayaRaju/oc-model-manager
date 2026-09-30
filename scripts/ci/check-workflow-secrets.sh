#!/usr/bin/env bash
# ============================================================================
# scripts/ci/check-workflow-secrets.sh
#
# Rejects a `run:` body that references a secret-backed environment variable
# which nothing in scope actually provides.
#
# Why this exists
# ---------------
# publish-release-to-tap.yml, as merged, had this at job level:
#
#     env:
#       TAG: ${{ inputs.tag }}
#       REPO_SLUG: ${{ github.repository }}
#       TAP_REPO: ${{ github.repository_owner }}/homebrew-ocprobe
#       GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
#
# and this in its first step:
#
#     if [ -z "${HOMEBREW_TAP_TOKEN:-}" ]; then
#       echo "::error::HOMEBREW_TAP_TOKEN is not set; cannot push the tap"
#
# HOMEBREW_TAP_TOKEN was used as a secret in the same job -- on the two
# actions/checkout steps -- and was never added to any `env:`. So the shell saw
# an empty string, the guard fired, and the workflow refused to run (run
# 36711062560). That is the good ending. The bad ending is the same code
# without the guard: an empty variable written to $GITHUB_ENV, or a checkout
# token that resolves to nothing, reported as success.
#
# That is the third time this class has cost a round, and each time the symptom
# appeared somewhere other than the cause:
#
#   1. GITHUBUB_REPOSITORY      -- a typo, empty expansion, caught downstream
#                                  by a `die` in another step
#   2. scripts/update-tap-formula.sh missing from the workspace -- "No such file
#                                  or directory" on stderr, hidden by `| tee`
#   3. HOMEBREW_TAP_TOKEN       -- empty expansion, caught by a guard
#
# The common shape: the YAML is valid, so nothing complains at parse time, and
# the failure surfaces later, in a different step, often on a code path ordinary
# CI never runs.
#
# The rule
# --------
# For each job: find every name N used as `secrets.N` anywhere in the job. For
# each step, find every shell variable reference in the `run:` body. If a
# reference is to a name in that first set, and the name is not provided by
# that step's `env:`, nor the job's `env:`, nor exported to $GITHUB_ENV by some
# step in the job, that is an error.
#
# GITHUB_ENV exports count as providing a name, because
# `echo "TAG=${TAG}" >> "$GITHUB_ENV"` in one step genuinely makes $TAG visible
# to the next. Without that, this check would fail the repo's own ci.yml, and a
# guard that fails on correct code is a guard that gets deleted.
#
# Why this is bash + python3, while check-workflow-env.sh is pure sed
# --------------------------------------------------------------------
# That one is a pure-text check on variable NAMES and can stay textual. This one
# has to know whether an `env:` belongs to the job or to a step, and whether a
# given `secrets.N` is in the same job as a given `run:` body. That is document
# structure, and flattening it with grep is how you end up with a check that
# passes for the wrong reason. python3 parses the YAML; bash keeps the file's
# interface, exit convention and message style.
#
# Usage: scripts/ci/check-workflow-secrets.sh [DIR]  (default .github/workflows)
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DIR="${1:-$ROOT/.github/workflows}"

if [[ ! -d "$DIR" ]]; then
	echo "check-workflow-secrets: not a directory: $DIR" >&2
	exit 1
fi

python3 - "$DIR" <<'PYTHON'
import pathlib
import re
import sys

import yaml

wf_dir = pathlib.Path(sys.argv[1])
files = sorted(
    [p for p in wf_dir.iterdir() if p.suffix in (".yml", ".yaml") and p.is_file()]
)

# $NAME and ${NAME}, and ${NAME:-default} / ${NAME:?...}. A leading letter or
# underscore is required, so positional parameters ($1) and $? are not names.
VAR = re.compile(r"\$(?:\{)?([A-Za-z_][A-Za-z0-9_]*)")
# NAME=... >> "$GITHUB_ENV"   and   NAME=... >> $GITHUB_ENV
EXPORT = re.compile(r"([A-Za-z_][A-Za-z0-9_]*)=[^>]*>>\s*\"?\$\{?GITHUB_ENV\b")
SECRET = re.compile(r"secrets\.([A-Za-z_][A-Za-z0-9_]*)")
# A `#` at the start of a line or after whitespace begins a shell comment. Not a
# general shell lexer, and deliberately not one: what matters is not to read a
# $VAR out of a prose comment and report it as a missing value.
SHELL_COMMENT = re.compile(r"(?:^|\s)#.*$", re.MULTILINE)


def walk(node, path=()):
    """Yield (path, key, value) for every mapping entry, at every depth."""
    if isinstance(node, dict):
        for k, v in node.items():
            yield path, k, v
            yield from walk(v, path + (k,))
    elif isinstance(node, list):
        for item in node:
            yield from walk(item, path)


def secret_names_in(job):
    """Every secrets.N used anywhere in this job."""
    out = set()
    for _, _, v in walk(job):
        if isinstance(v, str):
            out.update(SECRET.findall(v))
    return out


def env_keys(node):
    """Keys of an `env:` mapping, if this node is one."""
    if isinstance(node, dict) and "env" in node and isinstance(node["env"], dict):
        return set(node["env"])
    return set()


def env_of_job(job):
    return env_keys(job)


def exports_to_github_env(job):
    """Names some step in this job appends to $GITHUB_ENV.

    Those are visible to every later step, so they count as provided.
    """
    out = set()
    for step in job.get("steps") or []:
        body = step.get("run")
        if isinstance(body, str):
            out.update(EXPORT.findall(body))
    return out


problems = []

for path in files:
    try:
        doc = yaml.safe_load(path.read_text()) or {}
    except yaml.YAMLError as exc:
        problems.append("%s: not valid YAML: %s" % (path.name, exc))
        continue
    jobs = doc.get("jobs") or {}
    # `on:` parses as the boolean True in YAML 1.1, so it must be looked up both
    # ways when reporting which workflows were covered.
    triggers = doc.get(True, doc.get("on"))
    for jname, job in jobs.items():
        if not isinstance(job, dict):
            continue
        secrets = secret_names_in(job)
        if not secrets:
            continue
        job_env = env_of_job(job)
        job_exports = exports_to_github_env(job)
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            body = step.get("run")
            if not isinstance(body, str):
                continue
            step_env = env_keys(step)
            code = SHELL_COMMENT.sub(" ", body)
            # set -u turns an unset variable into an error, which is the good
            # case; only the ones this check is about are secret-backed names,
            # and an unprovided one is a bug either way.
            for name in sorted(set(VAR.findall(code)) & secrets):
                if name in step_env or name in job_env or name in job_exports:
                    continue
                problems.append(
                    "%s: job %r, step %r: run: body references $%s but no env: "
                    "provides it (job env: %s; step env: %s; exported to "
                    "$GITHUB_ENV: %s)"
                    % (
                        path.name,
                        jname,
                        step.get("name", "<unnamed>"),
                        name,
                        sorted(job_env) or "none",
                        sorted(step_env) or "none",
                        sorted(job_exports) or "none",
                    )
                )

if problems:
    for p in problems:
        print(p, file=sys.stderr)
    print("", file=sys.stderr)
    print(
        "check-workflow-secrets: %d secret-backed variable(s) referenced by a\n"
        "run: body with nothing in scope providing them (above)." % len(problems),
        file=sys.stderr,
    )
    print(
        "\nA missing env: entry does not fail the workflow. The shell expands the\n"
        "name to the empty string, so the failure appears later and somewhere else --\n"
        "usually as a guard in a consumer script, on a code path ordinary CI never\n"
        "exercises. Pass the secret through the job or step env: block. Do NOT\n"
        "splice it into the run: body: a secret inside a shell script is executable.",
        file=sys.stderr,
    )
    sys.exit(1)

print(
    "check-workflow-secrets: %d workflow file(s), no secret-backed run: variable "
    "without an env: provider" % len(files)
)
PYTHON
