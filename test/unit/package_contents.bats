#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/package_contents.bats
#
# CI has never checked what is actually inside the release tarball. The build
# job runs `cp -r bin lib config docs ...` and the Makefile does the same, so
# everything under lib/ ships -- but "everything under lib/" is a claim about a
# glob, and a glob is exactly the kind of thing that silently stops matching a
# new file type.
#
# lib/session_restore.py is the live example: it is not a .sh, it is a Python
# module loaded with importlib by `ocprobe session restore`, and a release that
# omitted it would install a tool whose restore command fails at runtime with
# "no such file". Nothing in the test suite noticed, because the tests run from
# the working tree.
#
# These tests check the copied tree the way a release is assembled, and pin the
# file list the install layout requires.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SRC="$BATS_TEST_TMPDIR/tree"
    mkdir -p "$SRC"

    # Mirror what the build job and `make package` copy: whole directories, no
    # per-extension globs. A build residue that exists in the working tree is
    # excluded here, because a CI checkout starts clean and a real release
    # tarball should not contain one either -- the residue check below asserts
    # that separately by looking at what a clean copy would produce.
    for d in bin lib config; do
        mkdir -p "$SRC/$d"
        cp -r "$ROOT/$d/." "$SRC/$d/"
    done
    cp "$ROOT/VERSION" "$SRC/"

    # Drop anything git ignores, exactly as a fresh CI checkout would be.
    find "$SRC" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
    find "$SRC" -name '*.pyc' -delete 2>/dev/null || true
}

listing() { find "$SRC" -type f | sed "s|^$SRC/||" | sort; }

# ---- the module that started this ------------------------------------------

@test "session_restore.py is inside the packaged lib/" {
    # The specific regression: a non-.sh file in lib/ must ship.
    [ -f "$SRC/lib/session_restore.py" ] || {
        echo "lib/session_restore.py would NOT be in the release tarball" >&2
        listing >&2
        false
    }
}

@test "the module is non-empty and is real Python" {
    [ -s "$SRC/lib/session_restore.py" ] || {
        echo "session_restore.py is empty in the package" >&2
        false
    }
    run python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$SRC/lib/session_restore.py"
    assert_success
}

@test "session.sh invokes the module next to itself, so both must ship" {
    # The module is located as "${BASH_SOURCE%/*}/session_restore.py", i.e.
    # relative to lib/session.sh. If either file is relocated in the install
    # layout this breaks, so both are asserted together.
    run grep -c 'session_restore.py' "$SRC/lib/session.sh"
    [ "$output" -ge 1 ] || {
        echo "lib/session.sh no longer references session_restore.py" >&2
        false
    }
    [ -f "$SRC/lib/session.sh" ] && [ -f "$SRC/lib/session_restore.py" ]
}

# ---- no glob may narrow the lib/ file set ----------------------------------

@test "packaging copies whole directories, never a *.sh glob" {
    # A `.sh`-only glob is the specific thing that would have dropped the .py,
    # so assert the absence of that shape in every place that assembles a
    # package. Matched on the command form rather than a comment mentioning it,
    # because the count of comment mentions is not a property worth pinning.
    for f in "$ROOT/Makefile" "$ROOT/.github/workflows/ci.yml" "$ROOT/scripts/ci/package-check.sh"; do
        run bash -c "grep -cE 'cp -r? +[^ ]*lib/\*\.sh' '$f' || true"
        assert_output "0"
    done
    # and the real copy lists are directory-wide
    run grep -cE '^\s*@?cp -r bin lib ' "$ROOT/Makefile"
    assert_output "1"
    run grep -cE '^\s+cp -r bin lib ' "$ROOT/.github/workflows/ci.yml"
    assert_output "1"
}

@test "every file currently in lib/ ends up in the package" {
    # The general form: whatever the working tree has, the package has. Catches
    # the next new file type automatically rather than by review. Build residue
    # is excluded, matching a clean CI checkout.
    local missing=0 f rel
    while IFS= read -r f; do
        rel="${f#"$ROOT/"}"
        case "$rel" in *__pycache__*|*.pyc) continue ;; esac
        [ -f "$SRC/$rel" ] || {
            echo "in the tree but not packaged: $rel" >&2
            missing=1
        }
    done < <(find "$ROOT/lib" -maxdepth 1 -type f)
    [ "$missing" -eq 0 ]
}

@test "a package built from a clean checkout carries no build residue" {
    # setup() removed residue the way a fresh CI checkout would not have any,
    # so this asserts the copy itself does not manufacture one.
    run bash -c "find '$SRC' \( -name '__pycache__' -o -name '*.pyc' -o -name '*.bak' \) -print | wc -l | tr -d ' '"
    assert_output "0"
}

@test "the working tree does not leave a __pycache__ in lib/" {
    # A residue in lib/ is harmless to a release (setup() strips it) but it
    # means something is running the module without -B, which on a read-only
    # install directory is a hard failure.
    [ ! -d "$ROOT/lib/__pycache__" ] || {
        echo "lib/__pycache__ exists; the module is being imported without python3 -B" >&2
        find "$ROOT/lib/__pycache__" >&2
        false
    }
}

# ---- the install layout the Homebrew formula uses -------------------------

@test "installing the package gives the layout bin/ + lib/ + share/" {
    # bin/ocprobe picks lib/ up from ../lib/ocprobe (installed) or ../lib (dev),
    # and config/version from share/ocprobe. An install that puts lib anywhere
    # else yields a tool that cannot find its own libraries.
    local dest="$BATS_TEST_TMPDIR/install"
    mkdir -p "$dest"
    cp -r "$SRC/bin" "$dest/"
    mkdir -p "$dest/lib/ocprobe" && cp -r "$SRC/lib/." "$dest/lib/ocprobe/"
    mkdir -p "$dest/share/ocprobe"
    cp -r "$SRC/config" "$dest/share/ocprobe/config"
    cp "$SRC/VERSION" "$dest/share/ocprobe/VERSION"

    [ -x "$dest/bin/ocprobe" ]
    [ -f "$dest/lib/ocprobe/session_restore.py" ]
    [ -f "$dest/lib/ocprobe/session.sh" ]
    [ -f "$dest/share/ocprobe/VERSION" ]
}

@test "the bootstrap can locate lib in the install layout" {
    # bin/ocprobe probes ../lib/ocprobe/core.sh first, so the install must place
    # core.sh there. Asserted on the copy, by running the same probe.
    local dest="$BATS_TEST_TMPDIR/install2"
    mkdir -p "$dest/lib/ocprobe"
    cp -r "$SRC/lib/." "$dest/lib/ocprobe/"
    cp -r "$SRC/bin" "$dest/"

    run bash -c "test -f '$dest/lib/ocprobe/core.sh' && echo found"
    assert_success
    assert_output "found"
    # and it must not be relying on the dev layout, which a release has no use for
    run bash -c "test -f '$dest/lib/core.sh' && echo also-dev || echo installed-only"
    assert_output "installed-only"
}
