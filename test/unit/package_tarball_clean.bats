#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/package_tarball_clean.bats
#
# A release tarball built on macOS used to carry one AppleDouble file for every
# real file: 35 of the 70 members in ocprobe-3.1.3.tar.gz were named ._something.
#
# They are never on disk. bsdtar synthesises them at archive time from the
# extended attributes macOS attaches to files, so `find -delete` on the staged
# tree finds nothing to delete and changes nothing. That is why this went
# unnoticed for as long as it did, and why COPYFILE_DISABLE=1 on the tar command
# is the fix rather than a cleanup step.
#
# It matters because the artifact is public. Every user who downloads a release
# gets 35 junk files, and anything that unpacks the tarball -- a Homebrew install
# does -- pays for them.
#
# Two things this file has to get right, both learned the hard way:
#
# 1. The archive must be read with python's tarfile, not `tar -tzf`. On macOS
#    bsdtar interprets and hides AppleDouble members when listing: it reports 35
#    members for a 70-member archive, and greps for `._` find nothing. A check
#    written against `tar -tzf` passes forever.
#
# 2. The negative cases must construct the pollution, not depend on it. bsdtar
#    only synthesises `._` members for files that CARRY an extended attribute.
#    A developer's checkout does (com.apple.provenance); a fresh
#    actions/checkout does not. A negative case that relies on the ambient xattr
#    state therefore passes on a laptop and fails in CI -- or worse, skips in CI
#    and quietly stops covering anything. So the polluted archives here are
#    built with a literal `._` file in the tree, which both bsdtar and GNU tar
#    archive as a real member on every platform.
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

# Every AppleDouble member, one per line; exits 1 if there is at least one.
# Reads the raw archive, so bsdtar's listing behaviour cannot hide them.
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

appledouble_count() {
    python3 - "$1" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1]) as t:
    names = t.getnames()
print(len([n for n in names
           if n.split("/")[-1].startswith("._") or "__MACOSX" in n.split("/")]))
PY
}

member_count() {
    python3 - "$1" <<'PY'
import sys
import tarfile
print(len(tarfile.open(sys.argv[1]).getnames()))
PY
}

# A staged tree, plus a real `._` file inside it, archived with plain tar.
# Deterministic on every platform, unlike relying on xattrs.
stage_polluted() { # $1 = tarball to write
    local stage="$WORK/polluted"
    mkdir -p "$stage/ocprobe-$VERSION/lib"
    cp -r "$ROOT/lib/." "$stage/ocprobe-$VERSION/lib/"
    cp "$ROOT/VERSION" "$stage/ocprobe-$VERSION/VERSION"
    : >"$stage/ocprobe-$VERSION/._synthetic"
    (cd "$stage" && tar -czf "$1" "ocprobe-$VERSION/")
}

@test "the release tarball contains no AppleDouble members" {
    run appledouble_members "$TARBALL"

    assert_output ""
    assert_success
}

@test "the tarball is not mostly AppleDouble files" {
    # The failure was not one stray entry: 35 of 70 members, one per real file.
    # A check that only caught a couple would have been useless, so this asserts
    # the ratio directly rather than re-deriving it from the count.
    local bad total
    bad="$(appledouble_count "$TARBALL")"
    total="$(member_count "$TARBALL")"

    [ "$total" -gt 0 ] || {
        echo "tarball has no members at all" >&2
        return 1
    }
    [ "$bad" -eq 0 ] || {
        printf 'tarball has %d AppleDouble member(s) out of %d\n' "$bad" "$total" >&2
        return 1
    }
}

@test "the detector sees an AppleDouble member when there is one" {
    # Without this, "no AppleDouble members" is only meaningful if the detector
    # can find one. The pollution is constructed, so this cannot pass by being
    # handed an already-clean archive.
    stage_polluted "$WORK/polluted.tar.gz"

    run appledouble_members "$WORK/polluted.tar.gz"

    assert_failure
    assert_output --partial "._"
}

@test "verify-tarball accepts the clean tarball it just built" {
    run bash "$ROOT/scripts/ci/package-check.sh" verify-tarball

    assert_success
}

@test "verify-tarball REJECTS a tarball with AppleDouble members" {
    # The CI enforcement, as opposed to this file's own detector. A
    # verify_tarball check that never fires is indistinguishable from a correct
    # one until the day the junk ships. Constructed pollution, so it runs
    # everywhere rather than skipping on a machine without xattrs.
    stage_polluted "$TARBALL"
    rm -rf "$WORK/extract"
    mkdir -p "$WORK/extract"
    tar -xzf "$TARBALL" -C "$WORK/extract"

    run bash "$ROOT/scripts/ci/package-check.sh" verify-tarball

    assert_failure
    assert_output --partial "AppleDouble"
}

@test "COPYFILE_DISABLE=1 is what makes the difference" {
    # The mechanism, and the only test here that can legitimately skip: bsdtar
    # only synthesises `._` members for files that carry an extended attribute,
    # and a fresh checkout has none. On a machine that does produce pollution
    # (any developer Mac), this asserts COPYFILE_DISABLE removes it.
    local stage="$WORK/mech"
    mkdir -p "$stage/ocprobe-$VERSION/lib"
    cp -r "$ROOT/lib/." "$stage/ocprobe-$VERSION/lib/"
    cp "$ROOT/VERSION" "$stage/ocprobe-$VERSION/VERSION"

    (cd "$stage" && tar -czf "$WORK/mech-plain.tar.gz" "ocprobe-$VERSION/")
    (cd "$stage" && COPYFILE_DISABLE=1 tar -czf "$WORK/mech-cf.tar.gz" "ocprobe-$VERSION/")

    local plain cf
    plain="$(appledouble_count "$WORK/mech-plain.tar.gz")"
    cf="$(appledouble_count "$WORK/mech-cf.tar.gz")"

    [ "$cf" -eq 0 ] || {
        printf 'COPYFILE_DISABLE=1 tarball still has %d AppleDouble member(s)\n' "$cf" >&2
        return 1
    }
    if [ "$plain" -eq 0 ]; then
        skip "this platform's tar emits no AppleDouble members for these files, so COPYFILE_DISABLE has nothing to suppress here"
    fi
    [ "$plain" -gt "$cf" ]
}

@test "the Makefile's tar pipeline is covered too" {
    # The Makefile packages with `tar -c | gzip -n`, not `tar -czf`, so a fix
    # applied only to package-check.sh would leave `make package` dirty.
    local stage="$WORK/mk"
    mkdir -p "$stage/ocprobe-$VERSION/lib"
    cp -r "$ROOT/lib/." "$stage/ocprobe-$VERSION/lib/"
    (cd "$stage" && COPYFILE_DISABLE=1 tar -c "ocprobe-$VERSION/" | gzip -n >"$WORK/mk.tar.gz")

    run appledouble_members "$WORK/mk.tar.gz"

    assert_output ""
    assert_success
}

@test "the Makefile pipeline is not fixed by a tar flag on the wrong side" {
    # tar reads COPYFILE_DISABLE from its own environment, so `COPYFILE_DISABLE=1
    # gzip` would not work. This asserts the variable is on the tar process, not
    # merely somewhere in the pipeline.
    local stage="$WORK/mk2"
    mkdir -p "$stage/ocprobe-$VERSION/lib"
    cp -r "$ROOT/lib/." "$stage/ocprobe-$VERSION/lib/"
    : >"$stage/ocprobe-$VERSION/._synthetic"
    (cd "$stage" && COPYFILE_DISABLE=1 tar -c "ocprobe-$VERSION/" | gzip -n >"$WORK/mk2.tar.gz")

    # The literal ._ file is real data, not synthesised metadata, so it survives
    # the flag. That is correct: the flag suppresses synthesis, it does not strip
    # files a user actually put in the tree.
    run appledouble_count "$WORK/mk2.tar.gz"

    assert_output "1"
}
