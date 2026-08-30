#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/bootstrap.bats — Binary bootstrap (dev vs installed mode) tests
# ============================================================================

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"
    
    # Set up fake installed layout
    mkdir -p "$BATS_TEST_TMPDIR/fake-installed/bin"
    mkdir -p "$BATS_TEST_TMPDIR/fake-installed/lib/ocprobe"
    mkdir -p "$BATS_TEST_TMPDIR/fake-installed/share/ocprobe"
    echo "2.0.10" > "$BATS_TEST_TMPDIR/fake-installed/share/ocprobe/VERSION"
    cp -r "$OCPROBE_ROOT/lib/"* "$BATS_TEST_TMPDIR/fake-installed/lib/ocprobe/"
    
    # Set up fake repo layout
    mkdir -p "$BATS_TEST_TMPDIR/fake-repo/bin"
    mkdir -p "$BATS_TEST_TMPDIR/fake-repo/lib"
    cp -r "$OCPROBE_ROOT/lib/"* "$BATS_TEST_TMPDIR/fake-repo/lib/"
    cp "$OCPROBE_ROOT/VERSION" "$BATS_TEST_TMPDIR/fake-repo/VERSION"
}

# ---- Dev Mode Detection Tests ----

@test "bootstrap detects dev mode when VERSION file exists alongside binary parent" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    
    run bash -c "
        source '$test_bin_dir/ocprobe'
        echo \"ROOT=\$OCPROBE_ROOT\"
        echo \"LIB_DIR=\$OCPROBE_LIB_DIR\"
        echo \"VERSION_FILE=\$OCPROBE_VERSION_FILE\"
    "
    assert_success
    assert_output --partial "ROOT=$BATS_TEST_TMPDIR/fake-repo"
    assert_output --partial "LIB_DIR=$BATS_TEST_TMPDIR/fake-repo/lib"
    assert_output --partial "VERSION_FILE=$BATS_TEST_TMPDIR/fake-repo/VERSION"
}

@test "bootstrap detects installed mode when VERSION file is NOT alongside binary parent" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-installed/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    
    run bash -c "
        source '$test_bin_dir/ocprobe'
        echo \"ROOT=\$OCPROBE_ROOT\"
        echo \"LIB_DIR=\$OCPROBE_LIB_DIR\"
        echo \"VERSION_FILE=\$OCPROBE_VERSION_FILE\"
    "
    assert_success
    assert_output --partial "ROOT=$BATS_TEST_TMPDIR/fake-installed"
    assert_output --partial "lib/ocprobe"
    assert_output --partial "share/ocprobe/VERSION"
}

@test "installed mode binary can source libs from ~/.local/lib/ocprobe/" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-installed/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    
    run bash -c "
        source '$test_bin_dir/ocprobe' 2>&1
        type log_info >/dev/null && echo 'libs sourced OK'
    "
    assert_success
    assert_output --partial "libs sourced OK"
}

@test "dev mode binary can source libs from repo lib/" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    
    run bash -c "
        source '$test_bin_dir/ocprobe' 2>&1
        type log_info >/dev/null && echo 'libs sourced OK'
    "
    assert_success
    assert_output --partial "libs sourced OK"
}

@test "bootstrap sets OCPROBE_LIB_DIR correctly for both modes" {
    # Dev mode
    local dev_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$dev_bin_dir/ocprobe"
    
    run bash -c "
        source '$dev_bin_dir/ocprobe'
        echo \"LIB_DIR=\$OCPROBE_LIB_DIR\"
    "
    assert_success
    assert_output --partial "fake-repo/lib"
    
    # Installed mode
    local inst_bin_dir="$BATS_TEST_TMPDIR/fake-installed/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$inst_bin_dir/ocprobe"
    
    run bash -c "
        source '$inst_bin_dir/ocprobe'
        echo \"LIB_DIR=\$OCPROBE_LIB_DIR\"
    "
    assert_success
    assert_output --partial "lib/ocprobe"
}
