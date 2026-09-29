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

# A copy of the clean tarball with one AppleDouble member added, built with
# python's tarfile. NOT built with tar, on purpose:
#
#   plain `tar -czf`                  drops a literal ._ file and substitutes the
#                                     ones it synthesises from xattrs -- so on a
#                                     fresh checkout, which has no xattrs, it
#                                     yields a completely CLEAN archive.
#   `COPYFILE_DISABLE=1 tar -czf`     keeps the literal ._ file, synthesises none
#
# So no tar invocation produces a polluted archive deterministically on every
# platform. tarfile does, because it does not interpret the name. That is the
# right thing to test anyway: the guard's job is to reject an archive that
# contains such a member, not to reproduce bsdtar's synthesis rules.
#
# The clean tarball is the starting point so the result is otherwise complete --
# a polluted archive that verify_tarball rejects for a MISSING file would pass
# the test for entirely the wrong reason.
add_appledouble_member() { # $1 = clean tarball, $2 = output tarball
    # Built via a temporary name: src and dst are often the same path, and
    # opening the output would truncate the input mid-read.
    python3 - "$1" "$2" "$VERSION" <<'PY'
import io
import os
import sys
import tarfile

src, dst, version = sys.argv[1], sys.argv[2], sys.argv[3]
name = "%s/._synthetic" % version
tmp = dst + ".tmp"
with tarfile.open(src) as tin, tarfile.open(tmp, "w:gz") as tout:
    for m in tin.getmembers():
        f = tin.extractfile(m) if m.isreg() else None
        tout.addfile(m, f)
    info = tarfile.TarInfo(name)
    info.size = 0
    tout.addfile(info, io.BytesIO(b""))
os.replace(tmp, dst)
PY
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
    # can find one.
    add_appledouble_member "$TARBALL" "$WORK/polluted.tar.gz"

    run appledouble_members "$WORK/polluted.tar.gz"

    assert_failure
    assert_output --partial "._synthetic"
}

@test "verify-tarball accepts the clean tarball it just built" {
    run bash "$ROOT/scripts/ci/package-check.sh" verify-tarball

    assert_success
}

@test "verify-tarball REJECTS a tarball with AppleDouble members" {
    # The CI enforcement, as opposed to this file's own detector. A
    # verify_tarball check that never fires is indistinguishable from a correct
    # one until the day the junk ships. Built with tarfile, so it runs identically
    # everywhere instead of depending on the host's xattrs.
    add_appledouble_member "$TARBALL" "$TARBALL"
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

@test "COPYFILE_DISABLE=1 does not strip a file the tree really contains" {
    # The flag suppresses bsdtar's *synthesis*; it does not remove files that are
    # genuinely in the tree. A literal ._ file survives it, which is correct --
    # and it is also the only portable way to get a polluted archive out of a
    # tar invocation, since plain tar drops the literal file instead.
    local stage="$WORK/mk2"
    mkdir -p "$stage/ocprobe-$VERSION/lib"
    cp -r "$ROOT/lib/." "$stage/ocprobe-$VERSION/lib/"
    : >"$stage/ocprobe-$VERSION/._synthetic"
    (cd "$stage" && COPYFILE_DISABLE=1 tar -c "ocprobe-$VERSION/" | gzip -n >"$WORK/mk2.tar.gz")

    run appledouble_count "$WORK/mk2.tar.gz"

    assert_output "1"
}
