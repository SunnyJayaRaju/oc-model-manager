#!/usr/bin/env bash
# ============================================================================
# scripts/ci/verify-release.sh
#
# Assert that a published release is genuinely complete and installable, against
# LIVE GitHub state. Everything here is a network call; nothing here runs in the
# unit suite.
#
# This exists because the one-shot checklist it replaces (test/unit/
# release_313.bats) could not survive being merged. Two of its tests asserted
# "no v3.1.3 tag exists" and "the release-prep branch is not merged" -- both
# permanently false the moment the release ships, so on main they turned the
# unit suite red on every run. A pre-release checklist is the wrong shape for an
# ongoing invariant: the right shape is a check that runs AFTER the release, and
# asserts the release actually produced what it claims.
#
# It is deliberately NOT a bats test and NOT wired into `make test-unit` /
# `make test` / any per-PR job. Those need to be fast, hermetic and offline;
# this needs to reach github.com, and it can only pass once a release exists.
# It runs from the "Verify Release" CI job, which is gated on a tag push and
# needs `homebrew`, so it runs after the tap has actually been updated.
#
# Usage: scripts/ci/verify-release.sh [VERSION]
#   VERSION defaults to $VERSION, then to the repository's VERSION file.
#
# Requires: gh, curl, python3, network. Exit non-zero with a clear message on
# any failure.
# ============================================================================
set -euo pipefail

REPO_SLUG="${REPO_SLUG:-SunnyJayaRaju/oc-model-manager}"
TAP_REPO_SLUG="${TAP_REPO_SLUG:-SunnyJayaRaju/homebrew-ocprobe}"
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Overridable so the bats coverage can drive this with fixtures instead of the
# network. VERIFY_RELEASE_GH and VERIFY_RELEASE_CURL are command paths.
GH="${VERIFY_RELEASE_GH:-gh}"
CURL="${VERIFY_RELEASE_CURL:-curl}"

failures=0

note() { printf '  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok   %s\n' "$*"; }
bad() {
	printf '  FAIL %s\n' "$*" >&2
	failures=$((failures + 1))
}

# --- argument handling -----------------------------------------------------
# Every failure below happens before any network call, so a caller that gets the
# argument wrong never touches github.com.
usage() {
	cat <<-EOF
		usage: $(basename "$0") [VERSION]

		VERSION may be given as an argument, or via \$VERSION, or is read from
		the repository's VERSION file. It must look like 1.2.3 -- a release tag is
		v<VERSION> and every asset is named for it, so a malformed version cannot
		produce a meaningful check.
	EOF
}

die_usage() {
	printf 'verify-release: %s\n' "$1" >&2
	usage >&2
	exit 2
}

VERSION="${1:-${VERSION:-}}"
# An argument that was PASSED is used verbatim -- including an empty one, which
# is then rejected. Falling back to the VERSION file when the caller passed ""
# would turn a caller's mistake into a check of a different version, which is
# the one failure mode here that must not happen silently.
if [ "$#" -ge 1 ]; then
	[ -n "$VERSION" ] || die_usage "the version argument is empty"
else
	[ -n "$VERSION" ] || {
		[ -f "$SCRIPT_ROOT/VERSION" ] ||
			die_usage "no VERSION given, \$VERSION is unset, and $SCRIPT_ROOT/VERSION does not exist"
		VERSION="$(tr -d '[:space:]' <"$SCRIPT_ROOT/VERSION")"
	}
fi

# Shape first: 1.2.3, and only that. Everything downstream builds URLs from it.
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
	die_usage "'$VERSION' is not a MAJOR.MINOR.PATCH version"
fi

TAG="v$VERSION"
note "verifying release $TAG of $REPO_SLUG (version $VERSION)"

WORK="${VERIFY_RELEASE_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
cleanup() {
	[ -n "${VERIFY_RELEASE_KEEP_WORK:-}" ] || rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

# --- preflight: the tools this needs ---------------------------------------
for tool in "$GH" "$CURL" python3; do
	command -v "$tool" >/dev/null 2>&1 || die_usage "required tool not found: $tool"
done

# --- a. the tag exists, and its commit's VERSION is this version ------------
step "a. tag $TAG exists and its target commit's VERSION reads $VERSION"

tag_json="$("$GH" api "repos/$REPO_SLUG/git/refs/tags/$TAG" 2>/dev/null || true)"
if [ -z "$tag_json" ]; then
	bad "tag $TAG does not exist in $REPO_SLUG"
else
	ok "tag $TAG exists"
	# An annotated tag's ref points at a tag object, whose `object.sha` is the tag
	# object, not the commit. Peel it with type=commit so the VERSION read is
	# against the commit the tag actually releases.
	peeled="$("$GH" api "repos/$REPO_SLUG/git/refs/tags/$TAG" --jq '.object.type + " " + .object.sha' 2>/dev/null || true)"
	type="${peeled%% *}"
	sha="${peeled##* }"
	note "  tag object type: $type  sha: $sha"
	if [ "$type" = "tag" ]; then
		sha="$("$GH" api "repos/$REPO_SLUG/git/tags/$sha" --jq '.object.sha' 2>/dev/null || true)"
		note "  peeled to commit: $sha"
	fi
	[ -n "$sha" ] && ok "tag resolves to commit $sha" || bad "could not resolve $TAG to a commit"

	if [ -n "$sha" ]; then
		tag_version="$("$GH" api "repos/$REPO_SLUG/contents/VERSION?ref=$sha" --jq .content 2>/dev/null |
			base64 -d 2>/dev/null | tr -d '[:space:]' || true)"
		if [ "$tag_version" = "$VERSION" ]; then
			ok "VERSION at $sha reads $tag_version"
		else
			bad "VERSION at $sha reads '${tag_version:-<empty>}', expected $VERSION"
		fi
	fi
fi

# --- b. the Release exists, with exactly the expected assets ----------------
step "b. GitHub Release $TAG exists with the expected assets"

rel_json="$("$GH" api "repos/$REPO_SLUG/releases/tags/$TAG" 2>/dev/null || true)"
TARBALL_URL=""
SHA_URL=""
if [ -z "$rel_json" ]; then
	bad "GitHub Release $TAG does not exist"
else
	ok "Release $TAG exists"
	rel_url="$(printf '%s' "$rel_json" | "$GH" api --input - --jq .html_url 2>/dev/null ||
		grep -o '"html_url": *"[^"]*"' <<<"$rel_json" | head -1 | cut -d'"' -f4 || true)"
	note "  release URL: ${rel_url:-<unknown>}"

	# Count tarball assets by exact name. Exactly one is required: two would mean
	# the build produced something twice, and a `brew` formula pointing at a
	# name that resolves ambiguously is not a release anyone can reason about.
	tarball_count="$(printf '%s' "$rel_json" | grep -o '"name": *"ocprobe-[0-9.]*\.tar\.gz"' | sort -u | wc -l | tr -d ' ')"
	all_tarballs="$(printf '%s' "$rel_json" | grep -o '"name": *"ocprobe-[0-9.]*\.tar\.gz"' | wc -l | tr -d ' ')"
	if [ "$tarball_count" -eq 1 ] && [ "$all_tarballs" -eq 1 ]; then
		ok "exactly one tarball asset: ocprobe-$VERSION.tar.gz"
	else
		bad "expected exactly 1 tarball asset ocprobe-$VERSION.tar.gz, found $all_tarballs total / $tarball_count distinct"
	fi

	if printf '%s' "$rel_json" | grep -q '"name": *"ocprobe-[0-9.]*\.tar\.gz\.sha256"'; then
		ok "a .sha256 asset is present"
	else
		bad "no ocprobe-$VERSION.tar.gz.sha256 asset"
	fi

	# Asset URLs. Use the API's own browser_download_url values rather than
	# reconstructing release/download URLs.
	TARBALL_URL="$(printf '%s' "$rel_json" |
		"$GH" api --input - --jq '.assets[] | select(.name=="ocprobe-'"$VERSION"'.tar.gz") | .browser_download_url' 2>/dev/null | head -1 || true)"
	SHA_URL="$(printf '%s' "$rel_json" |
		"$GH" api --input - --jq '.assets[] | select(.name=="ocprobe-'"$VERSION"'.tar.gz.sha256") | .browser_download_url' 2>/dev/null | head -1 || true)"
	note "  tarball asset URL: ${TARBALL_URL:-<not found>}"
	note "  sha256 asset URL:  ${SHA_URL:-<not found>}"
fi

# --- c. the published sha256 is the tarball's real sha256 ------------------
step "c. the .sha256 asset matches the tarball's real sha256"

COMPUTED_SHA=""
if [ -z "$TARBALL_URL" ] || [ -z "$SHA_URL" ]; then
	bad "cannot check checksums: asset URLs unavailable (see step b)"
else
	"$CURL" -fsSL --retry 3 -o "$WORK/ocprobe-$VERSION.tar.gz" "$TARBALL_URL" ||
		bad "could not download the tarball from $TARBALL_URL"
	if [ -s "$WORK/ocprobe-$VERSION.tar.gz" ]; then
		ok "downloaded tarball ($(wc -c <"$WORK/ocprobe-$VERSION.tar.gz" | tr -d ' ') bytes)"
		COMPUTED_SHA="$(shasum -a 256 "$WORK/ocprobe-$VERSION.tar.gz" | cut -d' ' -f1)"
		ok "computed sha256: $COMPUTED_SHA"
	else
		bad "downloaded tarball is empty or missing"
	fi

	"$CURL" -fsSL --retry 3 -o "$WORK/ocprobe-$VERSION.tar.gz.sha256" "$SHA_URL" ||
		bad "could not download the .sha256 asset from $SHA_URL"
	if [ -s "$WORK/ocprobe-$VERSION.tar.gz.sha256" ]; then
		# The asset is "<hash>  <name>". Compare the hash only, and say so if the
		# shape is wrong rather than silently comparing nothing.
		published="$(awk 'NR==1 {print $1}' "$WORK/ocprobe-$VERSION.tar.gz.sha256")"
		if ! printf '%s' "$published" | grep -Eq '^[0-9a-f]{64}$'; then
			bad "the .sha256 asset does not begin with a 64-hex hash: '$(head -1 "$WORK/ocprobe-$VERSION.tar.gz.sha256")'"
		elif [ "$published" = "$COMPUTED_SHA" ]; then
			ok "published sha256 matches the tarball exactly"
		else
			bad "published sha256 $published != computed $COMPUTED_SHA"
		fi
	else
		bad "the downloaded .sha256 asset is empty or missing"
	fi
fi

# --- d. tarball contents ---------------------------------------------------
step "d. tarball has no AppleDouble members and ships lib/session_restore.py"

# Read with python's tarfile, not `tar -tzf`. On macOS, bsdtar interprets and
# HIDES AppleDouble members when listing -- it reports 35 members for a
# 70-member archive -- so a `tar -tzf | grep ._` check finds nothing and passes
# forever. That is a check that cannot fail, which is worse than no check.
if [ -z "${COMPUTED_SHA:-}" ]; then
	bad "cannot inspect the tarball: it was not downloaded (see step c)"
else
	member_report="$(
		python3 - "$WORK/ocprobe-$VERSION.tar.gz" "$VERSION" <<'PY' || true
import sys
import tarfile

path, version = sys.argv[1], sys.argv[2]
with tarfile.open(path) as t:
    names = t.getnames()
root = "ocprobe-%s/" % version
ad = [n for n in names
      if n.split("/")[-1].startswith("._") or "__MACOSX" in n.split("/")]
print("  members: %d" % len(names))
print("ADCOUNT=%d" % len(ad))
for n in ad[:20]:
    print("AD %s" % n)
want = "%slib/session_restore.py" % root
print("HAS_RESTORE=%s" % ("yes" if want in names else "no"))
PY
	)"
	member_count="$(sed -n 's/^  members: //p' <<<"$member_report" | head -1)"
	ad_count="$(sed -n 's/^ADCOUNT=//p' <<<"$member_report" | head -1)"
	has_restore="$(sed -n 's/^HAS_RESTORE=//p' <<<"$member_report" | head -1)"
	sed -n 's/^AD /  AppleDouble member: /p' <<<"$member_report"

	note "  tarball members: ${member_count:-?}"
	if [ "${ad_count:-1}" = "0" ]; then
		ok "zero AppleDouble ._* members"
	else
		bad "tarball carries ${ad_count} AppleDouble member(s)"
	fi
	if [ "$has_restore" = "yes" ]; then
		ok "contains lib/session_restore.py"
	else
		# The member path is computed in bash, not in the python block above:
		# a variable set inside a heredoc is not a shell variable, and
		# interpolating one there expands to the empty string.
		bad "does not contain ocprobe-$VERSION/lib/session_restore.py -- 'ocprobe session restore' would fail for every user"
	fi
fi

# --- e. the live tap points at this release, with this checksum -----------
step "e. the live tap formula points at $TAG with the computed sha256"

formula_url="https://raw.githubusercontent.com/$TAP_REPO_SLUG/main/Formula/ocprobe.rb"
formula="$("$CURL" -fsSL --retry 3 "$formula_url" 2>/dev/null || true)"
if [ -z "$formula" ]; then
	bad "could not fetch $formula_url"
elif [ -z "$COMPUTED_SHA" ]; then
	bad "cannot check the formula: the tarball checksum was never computed (see step c)"
else
	note "  formula: $formula_url"
	formula_url_line="$(grep -E '^[[:space:]]*url[[:space:]]' <<<"$formula" || true)"
	formula_sha_line="$(grep -E '^[[:space:]]*sha256[[:space:]]' <<<"$formula" || true)"
	note "  url:    ${formula_url_line:-<no url line>}"
	note "  sha256: ${formula_sha_line:-<no sha256 line>}"

	# The url must name this exact tag and tarball. Quoting the dot in the
	# version keeps it from matching any character.
	if grep -Eq "releases/download/$TAG/ocprobe-$VERSION\.tar\.gz" <<<"$formula"; then
		ok "formula url references $TAG/ocprobe-$VERSION.tar.gz"
	else
		bad "formula url does not reference $TAG/ocprobe-$VERSION.tar.gz"
	fi

	# `-n` is required, not stylistic: without it sed prints EVERY line and the
	# `p` flag merely adds the substituted one, so `head -1` returned the formula's
	# first line ("class Ocprobe < Formula") as if it were the hash. That made
	# this check compare the wrong string and fail for the wrong reason.
	formula_sha="$(sed -nE 's/^[[:space:]]*sha256[[:space:]]+["'"'"']?([0-9a-f]{64})["'"'"']?.*/\1/p' <<<"$formula" | head -1)"
	if [ -z "$formula_sha" ]; then
		bad "could not read a 64-hex sha256 out of the formula"
	elif [ "$formula_sha" = "$COMPUTED_SHA" ]; then
		ok "formula sha256 matches the published tarball exactly"
	else
		bad "formula sha256 $formula_sha != published tarball $COMPUTED_SHA"
	fi
fi

# --- verdict ---------------------------------------------------------------
printf '\n'
if [ "$failures" -eq 0 ]; then
	note "verify-release: PASS ($TAG is published, complete, and matches the live tap)"
	exit 0
fi
printf 'verify-release: FAIL (%d check(s) failed for %s)\n' "$failures" "$TAG" >&2
exit 1
