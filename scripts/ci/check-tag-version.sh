#!/usr/bin/env bash
# Validate a release tag against the repository's VERSION file.
#
# The build job used to do this:
#
#     - name: Set version from tag
#       run: echo "VERSION=${GITHUB_REF_NAME#v}" >> "$GITHUB_ENV"
#
# i.e. it adopted whatever tag was pushed and overwrote VERSION with it. So
# tagging v9.9.9 against a tree whose VERSION says 3.1.2 produced a release
# claiming to be 9.9.9, with the source's own idea of its version silently
# discarded -- and `ocprobe version` inside the release would then disagree with
# what anyone reading the tag expects, in a way no test noticed.
#
# The rule is the obvious one: a release tag names the version it releases, and
# VERSION in the tree is that version. If they disagree, the tag is wrong (or
# VERSION was not bumped), and the correct action is to refuse.
#
# Usage: check-tag-version.sh [--quiet]
#   Reads the tag from $RELEASE_TAG, falling back to $GITHUB_REF_NAME.
#   Exits 0 if the tag is well-formed and matches VERSION, 1 otherwise, with the
#   reason on stderr.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TAG="${RELEASE_TAG:-${GITHUB_REF_NAME:-}}"
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

say() { [ "$QUIET" -eq 1 ] || printf '  %s\n' "$*"; }
die() {
	printf 'check-tag-version: %s\n' "$*" >&2
	exit 1
}

# ---- 1. the tag must exist and be well-formed -----------------------------
# Validated before use, not merely quoted: this value is interpolated into the
# artifact name and the release title.
[ -n "$TAG" ] || die "no tag provided (set RELEASE_TAG or GITHUB_REF_NAME)"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	die "tag '$TAG' does not match v<major>.<minor>.<patch>"

tag_version="${TAG#v}"

# ---- 2. and it must equal the VERSION file --------------------------------
version_file="$REPO_ROOT/VERSION"
[ -f "$version_file" ] || die "VERSION file not found at $version_file"

file_version="$(tr -d '[:space:]' <"$version_file")"
[ -n "$file_version" ] || die "VERSION is empty"

if [ "$tag_version" != "$file_version" ]; then
	printf 'check-tag-version: %s\n' \
		"tag v${tag_version} does not match VERSION ${file_version}" >&2
	printf '  The tag names the version being released and VERSION is the\n' >&2
	printf '  source of truth for it. Either bump VERSION in a commit (and let\n' >&2
	printf '  make version-check pass) or retag the commit that has the version\n' >&2
	printf '  you want. Refusing to build, because building anyway produces a\n' >&2
	printf '  release whose ocprobe version disagrees with its own tag.\n' >&2
	exit 1
fi

say "tag v${tag_version} matches VERSION ${file_version}"
printf '%s\n' "$tag_version"
