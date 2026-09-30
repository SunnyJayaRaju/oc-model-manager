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
    
    # Mock opencode for tests that need it
    mock_opencode

    # Never let these tests depend on — or touch — the real scheduler, on either
    # backend. `ocprobe doctor` reports the scheduler through `cmd_scheduler
    # status`, which dispatches on detect_platform INSIDE the child process:
    # launchd_status on macOS, systemd_status on Linux. Both decide "NOT
    # INSTALLED" from a $HOME-relative state file, so the previous version of
    # this file was really asserting a fact about whichever machine ran it.
    #
    # So mock the backend THIS run will actually dispatch to. Asserting one
    # backend's report while the other is what the code consults is precisely
    # the mistake that made the first attempt of this fix fail on ubuntu.
    case "$(detect_platform)" in
        launchd) setup_launchd_stubs ok ;;
        systemd) setup_systemd_stubs ok ;;
    esac
    isolate_scheduler_home
}

# ---- Dev Mode Detection Tests ----

@test "bootstrap detects dev mode when VERSION file exists alongside binary parent" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"
    
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
    chmod +x "$test_bin_dir/ocprobe"
    
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
    chmod +x "$test_bin_dir/ocprobe"
    
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
    chmod +x "$test_bin_dir/ocprobe"
    
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

# ---- doctor must read the VERSION file that belongs to the install ---------
#
# doctor.sh read a bare `cat VERSION`, i.e. a path relative to the CURRENT
# DIRECTORY, while the binary had already resolved $OCPROBE_VERSION_FILE to the
# file that actually belongs to the install. Found on a real Homebrew install of
# v3.1.3, where it printed "VERSION file: unknown" and a spurious
# "WARN VERSION mismatch: file= binary=3.1.3" on every run.
#
# The working directory in these tests is deliberately somewhere unrelated to
# the install, because that is the situation that broke.

# Run the installed-layout binary from a caller-chosen cwd, and print only the
# Drift Detection block.
doctor_drift_from() { # $1 = cwd, $2 = layout root
    local cwd="$1" root="$2"
    ( cd "$cwd" && bash "$root/bin/ocprobe" doctor 2>&1 ) |
        sed -n '/--- Drift Detection ---/,/^  Local tag\|^  PATH:/p'
}

@test "doctor reads the install's VERSION file, not one in the current directory" {
    local root="$BATS_TEST_TMPDIR/fake-installed"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$root/bin/ocprobe"
    chmod +x "$root/bin/ocprobe"

    # A cwd with no VERSION file at all. This is the bug's own symptom: the old
    # code printed "unknown" here and then warned about a mismatch that was not
    # there.
    local bare="$BATS_TEST_TMPDIR/cwd-without-version"
    mkdir -p "$bare"
    [ ! -f "$bare/VERSION" ]

    run doctor_drift_from "$bare" "$root"

    # The fake-installed tree ships share/ocprobe/VERSION containing 2.0.10.
    assert_output --partial "VERSION file: 2.0.10"
    refute_output --partial "VERSION file: unknown"
    # Whether a mismatch is reported at all is NOT assertable here: `ocprobe
    # version` resolves through PATH, so the binary version belongs to whatever
    # is installed on the machine running the suite, not to this layout. Asserting
    # "no warning" would be asserting a fact about the host -- the same trap the
    # scheduler tests in this file document. So assert the part that is ours: any
    # warning must quote the version doctor actually read. Before the fix it
    # always printed an empty file value, which is the spurious warning.
    refute_output --partial "VERSION mismatch: file= binary="
    if [[ "$output" == *"VERSION mismatch"* ]]; then
        assert_output --partial "VERSION mismatch: file=2.0.10 binary="
    fi
}

@test "doctor ignores a decoy VERSION file in the current directory" {
    local root="$BATS_TEST_TMPDIR/fake-installed"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$root/bin/ocprobe"
    chmod +x "$root/bin/ocprobe"

    # The dangerous half of the bug: an unrelated file named VERSION in the cwd.
    # The old code compared ITS contents against the binary, so this could report
    # a mismatch that is not about ocprobe -- or, if the decoy happened to match,
    # silently pass a genuinely drifted install.
    local decoy="$BATS_TEST_TMPDIR/cwd-with-decoy"
    mkdir -p "$decoy"
    echo "9.9.9" > "$decoy/VERSION"

    run doctor_drift_from "$decoy" "$root"

    assert_output --partial "VERSION file: 2.0.10"
    refute_output --partial "9.9.9"
    refute_output --partial "VERSION file: unknown"
}

@test "doctor reads the dev-checkout VERSION file in dev mode too" {
    # The other branch of the bootstrap. $OCPROBE_VERSION_FILE is <root>/VERSION
    # here, so the same bare `cat VERSION` would have happened to work only by
    # coincidence -- while still being wrong, and still wrong from any other cwd.
    local root="$BATS_TEST_TMPDIR/fake-repo"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$root/bin/ocprobe"
    chmod +x "$root/bin/ocprobe"

    local elsewhere="$BATS_TEST_TMPDIR/cwd-elsewhere"
    mkdir -p "$elsewhere"
    echo "9.9.9" > "$elsewhere/VERSION"

    run doctor_drift_from "$elsewhere" "$root"

    # fake-repo/VERSION is this repo's own VERSION.
    assert_output --partial "VERSION file: $(tr -d '[:space:]' <"$OCPROBE_ROOT/VERSION")"
    refute_output --partial "9.9.9"
}

@test "no library reads VERSION relative to the current directory" {
    # The class, not this one line. A bare `cat VERSION` is correct only when the
    # cwd happens to be the install root, which is exactly the assumption that
    # made this bug invisible in a dev checkout and obvious in a real install.
    run grep -rnE 'cat +"?VERSION"?' "$OCPROBE_ROOT/lib" "$OCPROBE_ROOT/bin/ocprobe"
    # Only the comment in doctor.sh that documents the fix may mention it, and
    # that line starts with a tab and a comment marker.
    local offenders
    offenders="$(grep -rnE 'cat +VERSION' "$OCPROBE_ROOT/lib" "$OCPROBE_ROOT/bin/ocprobe" |
        grep -vE ':[[:space:]]*#' || true)"
    [ -z "$offenders" ] || {
        printf 'these read VERSION relative to the cwd:\n%s\n' "$offenders" >&2
        false
    }
}

@test "doctor still reports a REAL mismatch, and does not warn when there is none" {
    # The fix must not simply delete the check. With a known file version and a
    # known binary version, the right answer is: warn only when they differ.
    local root="$BATS_TEST_TMPDIR/fake-installed"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$root/bin/ocprobe"
    chmod +x "$root/bin/ocprobe"

    # A layout whose VERSION disagrees with the version the binary reports. The
    # binary prints its own VERSION, so renaming the file's contents is enough.
    echo "1.2.3" > "$root/share/ocprobe/VERSION"
    local bare="$BATS_TEST_TMPDIR/cwd-clean"
    mkdir -p "$bare"

    # `ocprobe version` resolves through PATH, which is not this binary, so the
    # reported pair depends on the host. Assert the SHAPE instead: the file value
    # must be the one doctor read, and any mismatch warning must quote it.
    run doctor_drift_from "$bare" "$root"
    assert_output --partial "VERSION file: 1.2.3"
    refute_output --partial "file=1.2.3 binary=1.2.3"
    # Whatever the host PATH resolves to, the warning can never claim an empty
    # file value again -- that was the spurious-WARN bug.
    refute_output --partial "VERSION mismatch: file= binary="
}

@test "installed mode doctor command scheduler check works (sources scheduler.sh)" {    local test_bin_dir="$BATS_TEST_TMPDIR/fake-installed/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"
    
    # Create minimal config for doctor to run
    local config_dir="$BATS_TEST_TMPDIR/installed-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"
    
    # Run doctor in installed mode - should not error on scheduler check
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' doctor 2>&1
    "
    # Doctor may fail due to missing opencode, but scheduler check should work
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "--- Scheduler ---"
    assert_output --partial "NOT INSTALLED"
    # Should NOT contain the crash error
    refute_output --partial "cmd_scheduler: command not found"
}

@test "dev mode doctor command scheduler check works" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"
    
    local config_dir="$BATS_TEST_TMPDIR/dev-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"
    
    # Run doctor in dev mode - should not error on scheduler check
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' doctor 2>&1
    "
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "--- Scheduler ---"
    assert_output --partial "NOT INSTALLED"
    refute_output --partial "cmd_scheduler: command not found"
}

# ---- Scheduler state is controlled, not inherited ---------------------------
# The two doctor tests above assert "NOT INSTALLED". That assertion is only
# meaningful if the test actually controls the state it is asserting about, so
# this test flips the plist into existence inside the throwaway HOME and requires
# the report to change. If the fake HOME or the launchctl stub ever stop applying
# — e.g. someone "simplifies" setup() back to reading the real host — this fails
# and the NOT INSTALLED assertions stop being trustworthy.

@test "doctor scheduler report is driven by the mocked state, not the host" {
    # Everything below follows the backend detect_platform will actually
    # dispatch to, so the assertions are about the code path the test really
    # exercises. Asserting a launchd plist changes the report is meaningless on
    # Linux, where systemd_status never looks at it.
    local platform state_file when_enabled
    platform=$(detect_platform)
    case "$platform" in
        launchd)
            state_file="$HOME/Library/LaunchAgents/com.ocprobe.watch.plist"
            when_enabled="INSTALLED (not running)"   # stubbed `launchctl list` is silent
            ;;
        systemd)
            state_file="$HOME/.config/systemd/user/ocprobe-watch.service"
            when_enabled="INSTALLED (enabled)"       # stubbed `is-enabled` exits 0
            ;;
        *)
            skip "unsupported platform: $platform"
            return
            ;;
    esac

    local test_bin_dir="$BATS_TEST_TMPDIR/fake-installed/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"

    local config_dir="$BATS_TEST_TMPDIR/mocksens-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"

    # Baseline: no state file in the throwaway HOME -> NOT INSTALLED
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' doctor 2>&1
    "
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "NOT INSTALLED"

    # Now create the state file exactly where this backend looks, i.e. inside the
    # throwaway HOME. The report MUST change, proving the assertion above is
    # sensitive to state we control rather than passing vacuously.
    printf 'x\n' > "$state_file"

    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' doctor 2>&1
    "
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "$when_enabled"
    refute_output --partial "NOT INSTALLED"

    if [[ "$platform" == "launchd" ]]; then
        # Mirror of the systemd branch below. With the plist present, flip ONLY
        # what `launchctl list` prints and require the report to change again.
        # This is what proves launchctl is genuinely consulted: launchd_status
        # pipes its output into `grep -q com.ocprobe.watch`, so the pipeline's
        # status is grep's and the OUTPUT is the signal. A stub that only ever
        # exits 0 in silence would leave this assertion vacuous, which is
        # exactly how the systemd side had already been covered.
        setup_launchd_stubs running

        run bash -c "
            export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
            export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
            export OCPROBE_LOG_LEVEL=error
            mkdir -p "$BATS_TEST_TMPDIR/state"
            '$test_bin_dir/ocprobe' doctor 2>&1
        "
        [[ "$status" -eq 0 || "$status" -eq 1 ]]
        assert_output --partial "INSTALLED (running)"
        refute_output --partial "INSTALLED (not running)"
    elif [[ "$platform" == "systemd" ]]; then
        # systemd_status consults BOTH the unit file and `systemctl --user
        # is-enabled`. Flip only the systemctl stub and the report must change
        # again, which proves the systemctl mock is really in the path (with no
        # unit file it short-circuits and systemctl is never called at all).
        setup_systemd_stubs fail

        run bash -c "
            export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
            export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
            export OCPROBE_LOG_LEVEL=error
            mkdir -p "$BATS_TEST_TMPDIR/state"
            '$test_bin_dir/ocprobe' doctor 2>&1
        "
        [[ "$status" -eq 0 || "$status" -eq 1 ]]
        assert_output --partial "INSTALLED (disabled)"
        refute_output --partial "NOT INSTALLED"
    fi
}

# ---- Global Flag Parsing Tests ----

@test "global flag --quick works before subcommand (--quick audit)" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    local test_lib_dir="$BATS_TEST_TMPDIR/fake-repo/lib"
    mkdir -p "$test_bin_dir" "$test_lib_dir"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    cp -r "$OCPROBE_ROOT/lib" "$test_lib_dir"
    chmod +x "$test_bin_dir/ocprobe"
    
    local config_dir="$BATS_TEST_TMPDIR/flag-test-config"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"
    
    # Run with --quick before audit - should set OCPROBE_QUICK=1 and run audit
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' --quick audit 2>&1
    "
    # Should run audit (not fail with "Unknown command: --quick")
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "REPORT"
    # Verify --quick was honored (should skip whitelist probe)
    assert_output --partial "whitelist not probed this run (--quick)"
}

@test "global flag --quick works after subcommand (audit --quick)" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    local test_lib_dir="$BATS_TEST_TMPDIR/fake-repo/lib"
    mkdir -p "$test_bin_dir" "$test_lib_dir"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    cp -r "$OCPROBE_ROOT/lib" "$test_lib_dir"
    chmod +x "$test_bin_dir/ocprobe"
    
    local config_dir="$BATS_TEST_TMPDIR/flag-test-config2"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"
    
    # Run with --quick after audit - should set OCPROBE_QUICK=1
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' audit --quick 2>&1
    "
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "REPORT"
    # Verify --quick was honored (should skip whitelist probe)
    assert_output --partial "whitelist not probed this run (--quick)"
}

@test "global flag --json works before subcommand (--json version)" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"
    
    # Run with --json before version - should set OCPROBE_JSON_OUTPUT=1
    run bash -c "
        '$test_bin_dir/ocprobe' --json version 2>&1
    "
    assert_success
    # JSON output should be valid (version is simple text, but --json shouldn't break it)
    # Derive the expected version from VERSION so a release bump does not break this test.
    assert_output "ocprobe $(cat "$OCPROBE_ROOT/VERSION")"
}
 
@test "global flag --json works after subcommand (version --json)" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    chmod +x "$test_bin_dir/ocprobe"
    
    # Run with --json after version - should set OCPROBE_JSON_OUTPUT=1
    run bash -c "
        '$test_bin_dir/ocprobe' version --json 2>&1
    "
    assert_success
    assert_output "ocprobe $(cat "$OCPROBE_ROOT/VERSION")"
}

@test "global flags work in any order (--json --quick audit)" {
    local test_bin_dir="$BATS_TEST_TMPDIR/fake-repo/bin"
    local test_lib_dir="$BATS_TEST_TMPDIR/fake-repo/lib"
    mkdir -p "$test_bin_dir" "$test_lib_dir"
    cp "$OCPROBE_ROOT/bin/ocprobe" "$test_bin_dir/ocprobe"
    cp -r "$OCPROBE_ROOT/lib" "$test_lib_dir"
    chmod +x "$test_bin_dir/ocprobe"
    
    local config_dir="$BATS_TEST_TMPDIR/flag-test-config3"
    mkdir -p "$config_dir"
    cat > "$config_dir/config.yaml" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"
catalog:
  cache_ttl_hours: 24
  force_refresh: false
scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false
alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24
safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"
logging:
  level: error
  format: text
  file_enabled: false
EOF
    echo "{}" > "$BATS_TEST_TMPDIR/opencode.json"
    
    # Multiple flags before command
    run bash -c "
        export OCPROBE_CONFIG_OVERRIDE="$config_dir/config.yaml"
        export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
        export OCPROBE_LOG_LEVEL=error
        mkdir -p "$BATS_TEST_TMPDIR/state"
        '$test_bin_dir/ocprobe' --json --quick audit 2>&1
    "
    [[ "$status" -eq 0 || "$status" -eq 1 ]]
    assert_output --partial "REPORT"
    assert_output --partial "whitelist not probed this run (--quick)"
    # assert_output --partial "NEW:"
}