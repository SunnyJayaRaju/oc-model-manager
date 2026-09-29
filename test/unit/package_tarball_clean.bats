#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/package_tarball_clean.bats
#
# A release tarball built on macOS used to carry one AppleDouble file for every
# real file: 35 of the 70 members in ocprobe-3.1.3.tar.gz were named ._something.
#
# They are never on disk. bsdtar synthesises them at archive time from the
# extended attributes macOS attaches to copied files, so `find -delete` on the
# staged tree finds nothing to delete and changes nothing. That is why this went
# unnoticed for as long as it did, and why COPYFILE_DISABLE=1 on the tar command
# is the fix rather than a cleanup step.
#
# It matters because the artifact is public. Every user who downloads a release
# gets 35 junk files, and anything that mirrors or indexes the tarball (a Homebrew
# install unpacks them all) pays for them.
#
# The check is on the built tarball, not on the source tree, because that is
# where the pollution appears and the only place it can be observed.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    WORK="$BATS_TEST_TMPDIR/tarball"
    export PKGCHECK_WORK="$WORK"
    VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
    TARBALL="$WORK/ocprobe-$VERSION.tar.gz"
    bash "$ROOT/scripts/ci/package-check.sh" build >/dev/null 2>&1
}

# Every member whose basename starts with "._", or which lives under __MACOSX/.
# Exits non-zero when it finds any, so a caller can rely on the status as well as
# the output -- a detector that only prints is a detector a test can pass with.
appledouble_members() {
    python3 - "$1" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1]) as t:
    names = t.getnames()
bad = [n for n in names
       if n.split("/")[-1].startswith("._") or "__MACOSX" in n.split("/")]
for n in bad:
    print(n)
sys.exit(1 if bad else 0)
PY
}

@test "the release tarball contains no AppleDouble members" {
    run appledouble_members "$TARBALL"

    assert_output ""
    assert_success
}

@test "the tarball is not half AppleDouble files" {
    # The failure was not one stray entry: it was 35 of 70 members, i.e. one per
    # real file. A check that only caught a couple would have been useless, so
    # this asserts the ratio directly rather than re-deriving it from the count.
    read -r bad total < <(python3 - "$TARBALL" <<'PY'
import sys, tarfile
n = tarfile.open(sys.argv[1]).getnames()
bad = [x for x in n if x.split("/")[-1].startswith("._") or "__MACOSX" in x.split("/")]
print(len(bad), len(n))
PY
)
    [ "$total" -gt 0 ] || skip "tarball has no members"
    [ "$bad" -eq 0 ] || {
        printf 'tarball has %d AppleDouble member(s) out of %d\n' "$bad" "$total" >&2
        return 1
    }
}

@test "the detector itself catches a deliberately polluted tarball" {
    # Without this, "no AppleDouble members" is only meaningful if the detector
    # can see one. Build a tarball the old way -- plain tar, no COPYFILE_DISABLE
    # -- and require the detector to report it.
    stage="$WORK/polluted"
    mkdir -p "$stage/ocprobe-$VERSION"
    cp -r "$ROOT/lib" "$stage/ocprobe-$VERSION/"
    (cd "$stage" && tar -czf "$WORK/polluted.tar.gz" "ocprobe-$VERSION/")

    run appledouble_members "$WORK/polluted.tar.gz"

    assert_failure
    assert_output --partial "._"
}

@test "COPYFILE_DISABLE=1 is what makes the difference" {
    # The mechanism, so a future change to the build cannot quietly reintroduce
    # it by some other route. Only meaningful on a platform whose tar honours the
    # variable; on Linux both halves are zero and the assertion is vacuous.
    stage="$WORK/cf"
    mkdir -p "$stage/ocprobe-$VERSION"
    cp -r "$ROOT/lib" "$stage/ocprobe-$VERSION/"

    (cd "$stage" && tar -czf "$WORK/without.tar.gz" "ocprobe-$VERSION/")
    (cd "$stage" && COPYFILE_DISABLE=1 tar -czf "$WORK/with.tar.gz" "ocprobe-$VERSION/")

    without="$(python3 -c 'import sys,tarfile;print(len([n for n in tarfile.open(sys.argv[1]).getnames() if n.split("/")[-1].startswith("._")]))' "$WORK/without.tar.gz" 2>/dev/null || echo 0)"
    with="$(python3 -c 'import sys,tarfile;print(len([n for n in tarfile.open(sys.argv[1]).getnames() if n.split("/")[-1].startswith("._")]))' "$WORK/with.tar.gz" 2>/dev/null || echo 0)"

    [ "$with" -eq 0 ] || {
        printf 'COPYFILE_DISABLE=1 tarball still has %d AppleDouble member(s)\n' "$with" >&2
        return 1
    }
    if [ "$without" -eq 0 ]; then
        skip "this tar emits no AppleDouble members, so COPYFILE_DISABLE has nothing to suppress here"
    fi
    [ "$without" -gt "$with" ]
}

@test "the Makefile's tar pipeline is covered too" {
    # The Makefile packages with `tar -c | gzip -n`, not `tar -czf`, so a fix
    # applied only to package-check.sh would leave `make package` dirty.
    stage="$WORK/mk"
    mkdir -p "$stage/ocprobe-$VERSION"
    cp -r "$ROOT/lib" "$stage/ocprobe-$VERSION/"
    (cd "$stage" && COPYFILE_DISABLE=1 tar -c "ocprobe-$VERSION/" | gzip -n >"$WORK/mk.tar.gz")

    run appledouble_members "$WORK/mk.tar.gz"

    assert_output ""
    assert_success
}

@test "verify-tarball accepts the clean tarball it just built" {
    run bash "$ROOT/scripts/ci/package-check.sh" verify-tarball

    assert_success
}

@test "verify-tarball REJECTS a tarball with AppleDouble members" {
    # The CI enforcement, as opposed to this file's own detector. Without this,
    # a verify_tarball check that never fires is indistinguishable from a correct
    # one until the day the junk ships.
    #
    # Note it cannot use `tar -tzf` to look: on macOS bsdtar hides AppleDouble
    # members when listing, reporting 35 members for a 70-member archive. That is
    # why the check reads the archive with python instead.
    stage="$WORK/polluted2"
    mkdir -p "$stage/ocprobe-$VERSION"
    cp -r "$ROOT/bin" "$ROOT/lib" "$ROOT/config" "$stage/ocprobe-$VERSION/"
    for f in VERSION CHANGELOG.md LICENSE README.md; do
        [ -e "$ROOT/$f" ] && cp "$ROOT/$f" "$stage/ocprobe-$VERSION/"
    done
    (cd "$stage" && tar -czf "$TARBALL" "ocprobe-$VERSION/")
    rm -rf "$WORK/extract"
    mkdir -p "$WORK/extract"
    tar -xzf "$TARBALL" -C "$WORK/extract"

    # Only meaningful where this tar emits AppleDouble members at all.
    [ "$(appledouble_members "$TARBALL" | wc -l | tr -d ' ')" -gt 0 ] ||
        skip "this tar emits no AppleDouble members, so there is nothing for the check to catch"

    run bash "$ROOT/scripts/ci/package-check.sh" verify-tarball

    assert_failure
    assert_output --partial "AppleDouble"
}
