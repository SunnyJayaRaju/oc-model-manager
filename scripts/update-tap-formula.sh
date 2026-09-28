#!/usr/bin/env bash
# Update the tap formula for a released tag.
#
# Runs on the runner, not in the tap repo's shell, and deliberately does NOT
# commit or push: keeping git -- and therefore HOMEBREW_TAP_TOKEN -- entirely
# out of here means the token is never an argument, a variable this script can
# print, or part of a command line. The workflow commits when this reports
# changed=yes.
#
# The point of this script is that the old inline version trusted whatever came
# back over the network:
#
#     SHA256=$(curl -sL "$URL.sha256" | cut -d' ' -f1)
#     sed -i "s/sha256 \".*\"/sha256 \"${SHA256}\"/" Formula/ocprobe.rb
#
# `curl -sL` without --fail exits 0 on a 404, so an HTML error page became the
# formula's sha256 and the tag job published a formula that could not install.
# Everything below is the opposite: fail loudly, verify the download against
# the published checksum, and then check that the edits actually landed.
#
# Two formula shapes are supported, because a Homebrew formula does not need a
# `version` line: the version is normally derived from the url, and `brew audit
# --strict` calls a version line that merely restates the url redundant. So:
#
#   url and sha256  are always managed, because they must always be there
#   version         is updated when present, and NOT added when absent
#
# When there is no version line the url carries the version, so that is what the
# post-edit assertion checks instead. Previously the script wrote the url and
# the sha256 and then failed on the missing version line -- half applied, and it
# read as though the formula were at fault.
#
# RELEASE_BASE_URL overrides where the release artifacts are fetched from, so
# the whole flow can be rehearsed against a local http server with no release
# and no token. It changes only the base; the path shape is always
# <base>/<tag>/ocprobe-<version>.tar.gz.
set -euo pipefail

TAG="${TAG:-}"
REPO_SLUG="${REPO_SLUG:-}"
FORMULA="${FORMULA:-Formula/ocprobe.rb}"
WORK_DIR="${WORK_DIR:-}"
RELEASE_BASE_URL="${RELEASE_BASE_URL:-https://github.com/${REPO_SLUG}/releases/download}"
# One trailing slash, however many the caller supplied: "${BASE%/}" is applied
# once below, but an empty override must not silently become "/".
[[ -n "$RELEASE_BASE_URL" ]] || RELEASE_BASE_URL="https://github.com"

# A 404 body, an HTML error page or an empty string is the failure this script
# exists to catch, so every message is explicit and every exit is non-zero.
die() {
	printf 'update-tap-formula: %s\n' "$*" >&2
	exit 1
}

# ---- 1. constrain the inputs ------------------------------------------------
# Both the tag and the slug are interpolated into a URL and then into sed
# replacements, so both are matched against a strict pattern before use rather
# than merely quoted.
[[ -n "$TAG" ]] || die "TAG is required (expected v<major>.<minor>.<patch>)"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	die "TAG '$TAG' does not match v<major>.<minor>.<patch>"
[[ -n "$REPO_SLUG" ]] || die "REPO_SLUG is required (expected owner/name)"
[[ "$REPO_SLUG" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] ||
	die "REPO_SLUG '$REPO_SLUG' is not owner/name"

VERSION="${TAG#v}"
[[ -f "$FORMULA" ]] || die "formula not found: $FORMULA"

# %{...} on the next line: `${BASE%/}` strips exactly one trailing slash, which
# is the only case that matters, and %/{1,2} is not portable in a pattern.
BASE="${RELEASE_BASE_URL%/}"
URL="${BASE}/${TAG}/ocprobe-${VERSION}.tar.gz"

if [[ -z "$WORK_DIR" ]]; then
	WORK_DIR="$(mktemp -d)"
	# shellcheck disable=SC2064  # expand WORK_DIR now, not at trap time
	trap "rm -rf '$WORK_DIR'" EXIT
fi
mkdir -p "$WORK_DIR"
TARBALL="${WORK_DIR}/ocprobe-${VERSION}.tar.gz"

# ---- 2. portability shims ---------------------------------------------------
# macOS has no sha256sum; coreutils provides `gsha256sum`, not a bare
# `sha256sum`. Same shape as the existing `timeout` fallback in lib/core.sh.
sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		die "neither sha256sum nor shasum is available"
	fi
}

fetch() { # $1 = url, $2 = destination path
	# --fail is the whole point: without it curl exits 0 on a 404 and writes the
	# error page to the destination.
	curl --fail --location --silent --show-error --output "$2" "$1" ||
		die "download failed: $1"
}

# ---- 3. verify the artifact before trusting its published checksum ----------
fetch "$URL" "$TARBALL"
fetch "${URL}.sha256" "${WORK_DIR}/published.sha256"

COMPUTED="$(sha256_of "$TARBALL")"
# The published file is "<hash>  <name>" or a bare hash, sometimes upper-case.
PUBLISHED="$(awk 'NR == 1 { print $1 }' "${WORK_DIR}/published.sha256" | tr 'A-F' 'a-f')"

[[ "$COMPUTED" =~ ^[0-9a-f]{64}$ ]] || die "computed checksum is not 64 hex chars: '$COMPUTED'"
[[ "$PUBLISHED" =~ ^[0-9a-f]{64}$ ]] ||
	die "published checksum is not 64 hex chars: '$PUBLISHED' (a 404 body or error page, probably)"
[[ "$COMPUTED" == "$PUBLISHED" ]] ||
	die "checksum mismatch: published $PUBLISHED, downloaded $COMPUTED"

# ---- 4. edit, then prove the edit landed ------------------------------------
cp "$FORMULA" "${WORK_DIR}/formula.before"

# Does the formula carry an explicit version line? Decided BEFORE the edit,
# because the post-edit assertion has to match whichever shape it is looking at.
HAS_VERSION_LINE=0
if grep -qE '^[[:space:]]*version[[:space:]]+"' "$FORMULA"; then
	HAS_VERSION_LINE=1
fi

# -i.bak rather than bare -i so this is GNU and BSD sed alike. Each pattern is
# anchored to the start of a line and the leading whitespace is captured and
# re-emitted, so indentation survives.
#
# The version expression is only passed to sed when the line exists: a sed
# expression that matches nothing is silent, so including it unconditionally
# would look like it had worked either way.
SED_ARGS=(
	-e "s|^([[:space:]]*)url[[:space:]]+\".*\"|\\1url \"${URL}\"|"
	-e "s|^([[:space:]]*)sha256[[:space:]]+\".*\"|\\1sha256 \"${COMPUTED}\"|"
)
if [[ "$HAS_VERSION_LINE" -eq 1 ]]; then
	SED_ARGS=(
		-e "s|^([[:space:]]*)version[[:space:]]+\".*\"|\\1version \"${VERSION}\"|"
		"${SED_ARGS[@]}"
	)
fi
sed -E -i.bak "${SED_ARGS[@]}" "$FORMULA"
rm -f "${FORMULA}.bak"

# A silent no-op sed would otherwise produce a formula that still points at the
# previous release, which is worse than a failure because it looks successful.
#
# The version check is conditional on the shape, and the no-version shape is
# checked through the url instead: the version has to be recorded somewhere, and
# with no version line the url is where it lives.
if [[ "$HAS_VERSION_LINE" -eq 1 ]]; then
	grep -q "^[[:space:]]*version[[:space:]]*\"${VERSION}\"" "$FORMULA" ||
		die "version substitution did not apply -- is there a version line in $FORMULA?"
else
	# ...and confirm none was introduced: a version line that restates the url is
	# something `brew audit --strict` reports as redundant, so adding one would
	# trade a working formula for a failing audit.
	if grep -qE '^[[:space:]]*version[[:space:]]+"' "$FORMULA"; then
		die "a version line appeared in a formula that had none: $FORMULA"
	fi
	# The url must name both the tag and the tarball, because that is now the
	# only place the version appears.
	grep -qF "/${TAG}/ocprobe-${VERSION}.tar.gz" "$FORMULA" ||
		die "url does not name ${TAG}/ocprobe-${VERSION}.tar.gz -- with no version line, the url carries the version: $FORMULA"
fi
grep -qF "url \"${URL}\"" "$FORMULA" ||
	die "url substitution did not apply -- is there a url line in $FORMULA?"
grep -q "^[[:space:]]*sha256[[:space:]]*\"${COMPUTED}\"" "$FORMULA" ||
	die "sha256 substitution did not apply -- is there a sha256 line in $FORMULA?"

# ---- 5. report --------------------------------------------------------------
if cmp -s "${WORK_DIR}/formula.before" "$FORMULA"; then
	# Re-running for a tag the formula already points at is a no-op, not a
	# failure: the old `git commit` would have exited 1 on an empty commit.
	printf 'changed=no\n'
	printf 'update-tap-formula: %s already points at %s, nothing to do\n' "$FORMULA" "$TAG"
else
	printf 'changed=yes\n'
	printf 'update-tap-formula: %s updated to %s\n' "$FORMULA" "$TAG"
fi
