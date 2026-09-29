#!/usr/bin/env bash
# Rehearse the release -> tap formula update, end to end, with no release.
#
# Build the tarball exactly as the build job does, serve it and its .sha256 from
# a local http server, point the real updater at that server, and check the
# resulting formula. Nothing here can push: there is no token, no credentials on
# the tap checkout, and no git push anywhere in this script.
#
# Usage: rehearsal.sh [--formula <path>] [--tag <tag>] [--tap-dir <dir>]
#
# Defaults assume the tap has already been checked out next to this repo, which
# is what the workflow does.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="$(tr -d '[:space:]' <"$REPO_ROOT/VERSION")"

TAG="v${VERSION}"
TAP_DIR="${TAP_DIR:-$REPO_ROOT/../homebrew-ocprobe}"
FORMULA=""
PORT=0

while [ $# -gt 0 ]; do
	case "$1" in
	--tap-dir)
		TAP_DIR="$2"
		shift 2
		;;
	--tag)
		TAG="$2"
		shift 2
		;;
	--formula)
		FORMULA="$2"
		shift 2
		;;
	-h | --help)
		sed -n '2,14p' "$0"
		exit 0
		;;
	*)
		printf 'rehearsal: unknown argument %s\n' "$1" >&2
		exit 2
		;;
	esac
done

[ -n "$FORMULA" ] || FORMULA="${TAP_DIR}/Formula/ocprobe.rb"

say() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() {
	printf 'rehearsal: %s\n' "$*" >&2
	exit 1
}

# ---- 1. inputs -------------------------------------------------------------
[ -d "$TAP_DIR" ] || die "tap not checked out at $TAP_DIR"
[ -f "$FORMULA" ] || die "formula not found: $FORMULA"

say "tag            $TAG"
say "VERSION        $VERSION"
say "tap            $TAP_DIR"
say "formula        $FORMULA"
note "the live formula is copied to a temp file; the checked-out one is never written to"

# ---- 2. build the tarball exactly as the build job does --------------------
BUILD="$REPO_ROOT/.rehearsal"
rm -rf "$BUILD" 2>/dev/null || true
mkdir -p "$BUILD/dist/ocprobe-$VERSION"
cp -r "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/config" "$BUILD/dist/ocprobe-$VERSION/"
for f in VERSION CHANGELOG.md LICENSE README.md CONTRIBUTING.md; do
	[ -e "$REPO_ROOT/$f" ] && cp "$REPO_ROOT/$f" "$BUILD/dist/ocprobe-$VERSION/"
done
[ -d "$REPO_ROOT/docs" ] && cp -r "$REPO_ROOT/docs" "$BUILD/dist/ocprobe-$VERSION/"
# COPYFILE_DISABLE=1: on macOS, bsdtar synthesises an AppleDouble ._* file per
# archived file that carries an extended attribute. Meaningless to GNU tar.
(cd "$BUILD/dist" && COPYFILE_DISABLE=1 tar -czf "ocprobe-$VERSION.tar.gz" "ocprobe-$VERSION/")

# The .sha256 asset in the same "<hash>  <name>" shape GitHub's release upload
# produces, because that is what the updater parses.
(cd "$BUILD/dist" && sha256sum "ocprobe-$VERSION.tar.gz" >"ocprobe-$VERSION.tar.gz.sha256")

SHA_EXPECTED="$(awk 'NR == 1 { print $1 }' "$BUILD/dist/ocprobe-$VERSION.tar.gz.sha256")"
say "built the tarball"
note "ocprobe-$VERSION.tar.gz  $(wc -c <"$BUILD/dist/ocprobe-$VERSION.tar.gz" | tr -d ' ') bytes"
note "sha256 $SHA_EXPECTED"

# ---- 3. serve it -----------------------------------------------------------
# A plain http server, so the updater is exercised over a real network socket
# with a real 404 for anything it asks for that is not there.
SERVE_DIR="$BUILD/serve"
mkdir -p "$SERVE_DIR/$TAG"
cp "$BUILD/dist/ocprobe-$VERSION.tar.gz" "$SERVE_DIR/$TAG/"
cp "$BUILD/dist/ocprobe-$VERSION.tar.gz.sha256" "$SERVE_DIR/$TAG/"

PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
(cd "$SERVE_DIR" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) \
	>"$BUILD/server.log" 2>&1 &
SERVER_PID=$!
cleanup() {
	kill "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

BASE_URL="http://127.0.0.1:$PORT"
say "serving $SERVE_DIR on $BASE_URL"
# Wait for it to answer, rather than sleeping and hoping.
for _ in 1 2 3 4 5 6 7 8 9 10; do
	if curl --fail --silent --output /dev/null "$BASE_URL/$TAG/ocprobe-$VERSION.tar.gz"; then
		break
	fi
	sleep 0.3
done
curl --fail --silent --output /dev/null "$BASE_URL/$TAG/ocprobe-$VERSION.tar.gz" ||
	die "the local server never came up (see $BUILD/server.log)"

# ---- 4. run the real updater against a COPY of the formula -----------------
WORK="$BUILD/copy"
mkdir -p "$WORK"
cp "$FORMULA" "$WORK/formula.rb"
cp "$WORK/formula.rb" "$WORK/formula.before"

say "running scripts/update-tap-formula.sh against the copy"
RELEASE_BASE_URL="$BASE_URL" \
	TAG="$TAG" \
	REPO_SLUG="SunnyJayaRaju/oc-model-manager" \
	FORMULA="$WORK/formula.rb" \
	WORK_DIR="$BUILD/updater" \
	bash "$REPO_ROOT/scripts/update-tap-formula.sh" | sed 's/^/    /'
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || die "the updater exited $rc"

# ---- 5. the diff -----------------------------------------------------------
say "resulting formula diff"
if diff -u "$WORK/formula.before" "$WORK/formula.rb" | sed 's/^/    /'; then
	:
else
	:
fi

# ---- 6. assert the result, independently of the updater's own checks -------
say "asserting the result"
EXPECTED_URL="${BASE_URL}/${TAG}/ocprobe-${VERSION}.tar.gz"
EXPECTED_SHA="$SHA_EXPECTED"
fail=0

assert_line() { # $1 = expected line, $2 = description
	if grep -qF "$1" "$WORK/formula.rb"; then
		note "ok   $2"
	else
		note "FAIL $2 -- expected to find: $1"
		fail=1
	fi
}

assert_line "url \"$EXPECTED_URL\"" "url points at $TAG"
assert_line "sha256 \"$EXPECTED_SHA\"" "sha256 is the hash of the tarball we built"

# The version must be recorded somewhere. If the formula has a version line it
# must say $VERSION; if not, the url above is carrying it and no version line
# may have appeared.
if grep -qE '^[[:space:]]*version[[:space:]]+"' "$WORK/formula.rb"; then
	assert_line "version \"$VERSION\"" "the existing version line was updated"
else
	note "ok   no version line, so the url carries the version"
	if grep -qE '^[[:space:]]*version[[:space:]]+"' "$WORK/formula.rb"; then
		note "FAIL a version line was added to a formula that had none"
		fail=1
	fi
fi

# And the checked-out formula must be untouched: the rehearsal is a rehearsal.
if cmp -s "$FORMULA" "$WORK/formula.before"; then
	note "ok   the checked-out formula was not modified"
else
	note "FAIL the checked-out formula was modified"
	fail=1
fi

# The old release must not survive anywhere in the copy.
if grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+/ocprobe-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$WORK/formula.rb"; then
	stale="$(grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+/ocprobe-[0-9]+\.[0-9]+\.[0-9]+\.tar\.gz' "$WORK/formula.rb" | head -1)"
	if [ "$stale" != "${TAG}/ocprobe-${VERSION}.tar.gz" ]; then
		note "FAIL a stale release url is still present: $stale"
		fail=1
	else
		note "ok   no stale release url"
	fi
else
	note "ok   no stale release url"
fi

[ "$fail" -eq 0 ] || die "the rehearsal produced a formula that does not match what was expected"

say "rehearsal OK -- $TAG, $EXPECTED_URL"
say "  url    $EXPECTED_URL"
say "  sha256 $EXPECTED_SHA"
say "  nothing was pushed; the checked-out formula and the tap are untouched"
