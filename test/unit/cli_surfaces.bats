#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/cli_surfaces.bats — coverage for CLI surfaces with zero tests
#
# M6. Every launchd and timeout call in here is MOCKED. An earlier batch's
# verification ran a real launchd_install on the developer's machine, which
# installed a live launchd agent and then broke test/unit/bootstrap.bats
# because those tests assert doctor reports "NOT INSTALLED" and depend on real
# host launchd state. Nothing in this file touches the host: launchctl is a
# stub on PATH, the plist path is redirected into BATS_TEST_TMPDIR, and the
# perl-fallback tests run under a synthetic PATH built from symlinks.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_RUN_DIR="$BATS_TEST_TMPDIR/run"
    mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"
    write_test_config
    load_config >/dev/null
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# log_info carries the observable result of restore/cleanup, so the level has
# to be info, not error.
write_test_config() {
    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "$BATS_TEST_TMPDIR/session-backups"
logging:
  level: info
  format: text
  file_enabled: false
EOF
    cat >"$BATS_TEST_TMPDIR/opencode.json" <<'JSON'
{"provider":{}}
JSON
}

# Build a PATH containing symlinks to $@ (and nothing else), so that a given
# binary is genuinely absent from it.
make_pseudo_path() { # $1 = dest dir, rest = tools to expose
    local dest="$1" tool p
    shift
    mkdir -p "$dest"
    for tool in "$@"; do
        p=$(command -v "$tool" 2>/dev/null) || continue
        ln -sf "$p" "$dest/$tool"
    done
}

# ---- run_with_timeout (lib/core.sh) ----------------------------------------
# The macOS fallback: when coreutils' `timeout` is absent, the perl alarm is the
# only reason the tool works at all. It was entirely unexercised.
#
# These two run in a synthetic PATH rather than via `run`, because the perl
# alarm raises SIGALRM in the whole process group: the shell under test dies
# with it, so there is no rc to read from inside. Instead the script announces
# that it reached the perl branch, then dies if the interruption worked.

PERL_PATH_TOOLS="perl sleep bash date mkdir cat sed awk ls rm grep tr"

@test "run_with_timeout kills a command that exceeds the timeout" {
    local t0=$SECONDS
    run run_with_timeout 1 sleep 5
    assert_failure
    [[ $((SECONDS - t0)) -lt 5 ]] || {
        echo "run_with_timeout did not actually interrupt sleep 5" >&2
        false
    }
}

@test "run_with_timeout leaves a command that finishes within the timeout alone" {
    run run_with_timeout 10 sleep 0.1
    assert_success
    assert_output ""
}

@test "run_with_timeout propagates the command's own exit status" {
    run run_with_timeout 10 bash -c 'exit 42'
    assert_failure
    assert_equal 42 "$status"
}

@test "run_with_timeout uses the perl alarm when coreutils timeout is absent" {
    make_pseudo_path "$BATS_TEST_TMPDIR/nobin" $PERL_PATH_TOOLS

    # Announce each milestone so the assertions can tell how far it got.
    local t0=$SECONDS
    run env -i PATH="$BATS_TEST_TMPDIR/nobin" HOME="$HOME" bash -c '
        command -v timeout >/dev/null 2>&1 && { echo TIMEOUT_PRESENT; exit 99; }
        echo PERL_BRANCH_REACHED
        cd ~/GitHub/oc-model-manager
        source lib/core.sh
        run_with_timeout 1 sleep 5
        echo NOT_KILLED
    '

    refute_output --partial "TIMEOUT_PRESENT"  # the premise actually held
    assert_output --partial "PERL_BRANCH_REACHED"
    refute_output --partial "NOT_KILLED"      # the sleep was interrupted
    assert_failure
    [[ $((SECONDS - t0)) -lt 5 ]] || {
        echo "perl alarm did not interrupt sleep 5" >&2
        false
    }
}

@test "run_with_timeout perl fallback succeeds for a quick command" {
    make_pseudo_path "$BATS_TEST_TMPDIR/nobin2" $PERL_PATH_TOOLS

    run env -i PATH="$BATS_TEST_TMPDIR/nobin2" HOME="$HOME" bash -c '
        command -v timeout >/dev/null 2>&1 && { echo TIMEOUT_PRESENT; exit 99; }
        cd ~/GitHub/oc-model-manager
        source lib/core.sh
        run_with_timeout 10 sleep 0.1
        echo "QUICK_RC=$?"
    '
    refute_output --partial "TIMEOUT_PRESENT"
    assert_output --partial "QUICK_RC=0"
    assert_success
}

# ---- launchd_install / launchd_uninstall (lib/scheduler.sh) ----------------

setup_launchd_stubs() { # $1 = "ok" | "fail"
    local bin="$BATS_TEST_TMPDIR/lb"
    mkdir -p "$bin"
    cat >"$bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$BATS_TEST_TMPDIR/launchctl.calls"
if [[ "\$1" == "load" && "$1" == "fail" ]]; then
    echo "Load failed: 5: Input/output error" >&2
    exit 5
fi
exit 0
EOF
    chmod +x "$bin/launchctl"
    export PATH="$bin:$PATH"
    : >"$BATS_TEST_TMPDIR/launchctl.calls"
    # redirect the plist away from ~/Library/LaunchAgents
    eval "launchd_plist_path() { echo '$BATS_TEST_TMPDIR/com.ocprobe.watch.plist'; }"
}

@test "launchd_install writes a plist and reports success when launchctl load succeeds" {
    setup_launchd_stubs ok
    export OCPROBE_ROOT="$BATS_TEST_TMPDIR/root"
    export OCPROBE_WATCH_SECS=21600

    run launchd_install
    assert_success

    run cat "$BATS_TEST_TMPDIR/com.ocprobe.watch.plist"
    assert_success
    assert_output --partial "<key>Label</key><string>com.ocprobe.watch</string>"
    assert_output --partial "<key>StartInterval</key><integer>21600</integer>"
    # the resolved bash path, not an empty string
    run grep -c '<string></string>' "$BATS_TEST_TMPDIR/com.ocprobe.watch.plist"
    assert_output "0"
}

@test "launchd_install fails loudly and returns non-zero when launchctl load fails" {
    setup_launchd_stubs fail
    export OCPROBE_ROOT="$BATS_TEST_TMPDIR/root"
    export OCPROBE_WATCH_SECS=21600

    run launchd_install
    assert_failure
    # M8: the failure must be reported, and the exit code surfaced.
    assert_output --partial "launchctl load failed"
    # ...and no success-implying message may be printed.
    refute_output --partial "installed: check+alert"
    refute_output --partial "alerts appear via"
}

@test "launchd_install refuses to write a plist when bash is not on PATH" {
    setup_launchd_stubs ok
    export OCPROBE_ROOT="$BATS_TEST_TMPDIR/root"
    export OCPROBE_WATCH_SECS=21600

    # launchd_install runs `dirname` before it looks for bash, so expose
    # dirname and mkdir but pointedly NOT bash.
    make_pseudo_path "$BATS_TEST_TMPDIR/nobash" dirname mkdir
    cp "$BATS_TEST_TMPDIR/lb/launchctl" "$BATS_TEST_TMPDIR/nobash/launchctl"
    eval "launchd_plist_path() { echo '$BATS_TEST_TMPDIR/nobash.plist'; }"

    local orig_path="$PATH"
    export PATH="$BATS_TEST_TMPDIR/nobash"
    run launchd_install
    export PATH="$orig_path"

    assert_failure
    assert_output --partial "could not locate bash on PATH"
    # nothing must have been written
    [ ! -f "$BATS_TEST_TMPDIR/nobash.plist" ] || {
        echo "a plist was written despite the missing bash" >&2
        false
    }
}

@test "launchd_uninstall unloads and removes the plist" {
    setup_launchd_stubs ok
    printf '<plist/>' >"$BATS_TEST_TMPDIR/com.ocprobe.watch.plist"

    run launchd_uninstall
    assert_success
    assert_output --partial "scheduler removed"
    [ ! -f "$BATS_TEST_TMPDIR/com.ocprobe.watch.plist" ] || {
        echo "plist was not removed" >&2
        false
    }
    # it really did ask launchctl
    run grep -c "unload" "$BATS_TEST_TMPDIR/launchctl.calls"
    refute_output "0"
}

@test "launchd_uninstall is safe when no plist exists" {
    setup_launchd_stubs ok
    rm -f "$BATS_TEST_TMPDIR/com.ocprobe.watch.plist"
    run launchd_uninstall   # rm -f on a missing file still succeeds
    assert_success
    refute_output --partial "No such file"
}

# ---- audit_log (lib/logging.sh) -------------------------------------------

@test "audit_log appends a timestamped line to the log file" {
    export OCPROBE_LOG_FILE="$BATS_TEST_TMPDIR/audit.log"
    : >"$OCPROBE_LOG_FILE"

    run audit_log "run start mode=audit quick=0"
    assert_success

    run cat "$OCPROBE_LOG_FILE"
    assert_success
    # format: [HH:MM:SS] message
    [[ "$output" =~ ^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\][[:space:]]run[[:space:]]start[[:space:]]mode=audit[[:space:]]quick=0$ ]] || {
        echo "unexpected audit_log format: '$output'" >&2
        false
    }
}

@test "audit_log appends rather than truncating" {
    export OCPROBE_LOG_FILE="$BATS_TEST_TMPDIR/audit.log"
    : >"$OCPROBE_LOG_FILE"
    audit_log "first"
    audit_log "second"
    audit_log "third"
    # BSD wc pads its output, so strip the whitespace
    run bash -c 'wc -l <"$1" | tr -d "[:space:]"' _ "$OCPROBE_LOG_FILE"
    assert_output "3"
}

@test "audit_log is a no-op when no log file is configured" {
    unset OCPROBE_LOG_FILE
    run audit_log "should not fail"
    assert_success
    assert_output ""
}

# ---- cmd_session_restore (lib/session.sh, C1) -----------------------------

# 4 columns for session / 3 for message, matching create_test_db in setup_libs.bash
make_session_db() {
    local db="$BATS_TEST_TMPDIR/opencode.db"
    sqlite3 "$db" "CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, time_created INTEGER, time_updated INTEGER);
                    CREATE TABLE message (id INTEGER PRIMARY KEY, session_id TEXT, time_created INTEGER);" 2>/dev/null
    printf '%s' "$db"
}

@test "cmd_session_restore rejects a call with no file argument" {
    run cmd_session_restore
    assert_failure
    assert_output --partial "usage: ocprobe session restore"
}

@test "cmd_session_restore rejects a missing file" {
    run cmd_session_restore "$BATS_TEST_TMPDIR/nope.sql"
    assert_failure
    assert_output --partial "no such file"
}

@test "cmd_session_restore refuses SQL containing disallowed statements" {
    local db sql
    db=$(make_session_db)
    sql="$BATS_TEST_TMPDIR/evil.sql"
    printf 'INSERT INTO session VALUES ("s1","t",1,1);\nDROP TABLE session;\n' >"$sql"

    run cmd_session_restore "$sql"
    assert_failure
    assert_output --partial "disallowed statement"
    # the table must still be there
    run sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='session';"
    assert_output "session"
}

@test "cmd_session_restore rejects a sqlite dot-command" {
    local db sql
    db=$(make_session_db)
    sql="$BATS_TEST_TMPDIR/dot.sql"
    printf 'INSERT INTO session VALUES ("s1","t",1,1);\n.shell rm -rf ~\n' >"$sql"

    run cmd_session_restore "$sql"
    assert_failure
    assert_output --partial "disallowed statement"
}

@test "cmd_session_restore aborts cleanly when the pre-restore backup fails" {
    local db sql
    db=$(make_session_db)
    sql="$BATS_TEST_TMPDIR/ok.sql"
    printf 'INSERT INTO session VALUES ("s1","kept",1,1);\n' >"$sql"

    # The config file's session.backup_dir wins over the environment here, so
    # point it at a regular file: mkdir -p then cannot succeed.
    printf 'not a directory' >"$BATS_TEST_TMPDIR/blocked"
    sed -i.bak "s|backup_dir: .*|backup_dir: \"$BATS_TEST_TMPDIR/blocked/nested\"|" "$OCPROBE_CONFIG_OVERRIDE"

    run cmd_session_restore "$sql"
    assert_failure
    assert_output --partial "cannot create backup directory"
    # and the row must NOT have been restored
    run sqlite3 "$db" "SELECT COUNT(*) FROM session;"
    assert_output "0"
}

@test "cmd_session_restore applies a valid dump idempotently and reports success" {
    local db sql
    db=$(make_session_db)
    sql="$BATS_TEST_TMPDIR/good.sql"
    # INSERT OR REPLACE is what `ocprobe session backup` actually emits (it
    # rewrites the dump for exactly this reason), so a round-trip restore is
    # idempotent. Plain INSERT would be a dump no real backup produces.
    printf 'INSERT OR REPLACE INTO session VALUES ("s1","hello",1000,1000);\nINSERT OR REPLACE INTO session VALUES ("s2","world",2000,2000);\n' >"$sql"

    run cmd_session_restore "$sql"
    assert_success
    assert_output --partial "restored from"

    run sqlite3 "$db" "SELECT COUNT(*) FROM session;"
    assert_output "2"

    # restoring the same dump again must not duplicate or error
    run cmd_session_restore "$sql"
    assert_success
    run sqlite3 "$db" "SELECT COUNT(*) FROM session;"
    assert_output "2"
}

@test "cmd_session_restore creates a backup before writing" {
    local db sql
    db=$(make_session_db)
    sql="$BATS_TEST_TMPDIR/good2.sql"
    printf 'INSERT OR REPLACE INTO session VALUES ("s9","x",1,1);\n' >"$sql"

    run cmd_session_restore "$sql"
    assert_success
    # session.backup_dir from the config is what the code uses
    run ls -1 "$BATS_TEST_TMPDIR/session-backups"
    assert_success
    assert_output --partial "opencode.db.pre-restore-"
}

# ---- cmd_session_cleanup (lib/session.sh, M2 + FIX 4) --------------------

# Record which session ids reach `opencode session delete`, without invoking it.
setup_session_delete_recorder() { # $1 = output file
    local rec="$1"
    local bin="$BATS_TEST_TMPDIR/rec"
    mkdir -p "$bin"
    cat >"$bin/opencode" <<EOF
#!/usr/bin/env bash
case "\$1" in
  session)
    case "\$2" in
      delete) echo "\$3" >> "$rec"; exit 0 ;;
      list)   exit 0 ;;
    esac ;;
esac
exit 0
EOF
    chmod +x "$bin/opencode"
    export PATH="$bin:$PATH"
}

@test "cmd_session_cleanup uses the DB-backed listing across all three title prefixes" {
    local db now_ms i t
    db=$(make_session_db)
    now_ms=$(( $(date +%s) * 1000 ))

    # 30 fresh sessions spread over all three prefixes. The old CLI-based
    # listing paginated at 100 rows, so this is also the regression guard for
    # "cleanup can only see what the CLI shows".
    for i in $(seq 1 30); do
        case $((i % 3)) in
        0) t="ocprobe-probe-s$i" ;;
        1) t="ocmm-probe-s$i" ;;
        2) t="ocprobe-validate-s$i" ;;
        esac
        sqlite3 "$db" "INSERT INTO session VALUES ('ses_s$i','$t',$now_ms,$now_ms);
                        INSERT INTO message VALUES ($i,'ses_s$i',$now_ms);" 2>/dev/null
    done

    : >"$BATS_TEST_TMPDIR/deleted.txt"
    setup_session_delete_recorder "$BATS_TEST_TMPDIR/deleted.txt"

    run cmd_session_cleanup
    assert_success
    assert_output --partial "cleaned 30 probe session(s)"

    # every one of the three prefixes must have reached the delete call
    run bash -c 'wc -l <"$1" | tr -d "[:space:]"' _ "$BATS_TEST_TMPDIR/deleted.txt"
    assert_output "30"
    run grep -c 'ses_s' "$BATS_TEST_TMPDIR/deleted.txt"
    assert_output "30"
}

@test "cmd_session_cleanup leaves a real conversation alone" {
    local db now_ms
    db=$(make_session_db)
    now_ms=$(( $(date +%s) * 1000 ))
    sqlite3 "$db" "INSERT INTO session VALUES ('ses_probe1','ocprobe-probe-x',$now_ms,$now_ms);
                    INSERT INTO message VALUES (1,'ses_probe1',$now_ms);
                    INSERT INTO session VALUES ('ses_real','My real conversation',$now_ms,$now_ms);
                    INSERT INTO message VALUES (2,'ses_real',$now_ms);" 2>/dev/null

    : >"$BATS_TEST_TMPDIR/deleted.txt"
    setup_session_delete_recorder "$BATS_TEST_TMPDIR/deleted.txt"

    run cmd_session_cleanup
    assert_success
    run cat "$BATS_TEST_TMPDIR/deleted.txt"
    assert_output --partial "ses_probe1"
    refute_output --partial "ses_real"
}

@test "cmd_session_cleanup respects the fresh-guard-hours interval" {
    local db now_ms old_ms
    db=$(make_session_db)
    now_ms=$(( $(date +%s) * 1000 ))
    # 3 hours old with a 1h fresh guard -> must NOT be cleaned
    old_ms=$(( now_ms - 3 * 3600 * 1000 ))
    sqlite3 "$db" "INSERT INTO session VALUES ('ses_old','ocprobe-probe-old',$old_ms,$old_ms);
                    INSERT INTO message VALUES (1,'ses_old',$old_ms);" 2>/dev/null
    export OCPROBE_FRESH_GUARD_HOURS=1

    : >"$BATS_TEST_TMPDIR/deleted.txt"
    setup_session_delete_recorder "$BATS_TEST_TMPDIR/deleted.txt"

    run cmd_session_cleanup
    assert_success
    assert_output --partial "cleaned 0 probe session(s)"
    run cat "$BATS_TEST_TMPDIR/deleted.txt"
    refute_output --partial "ses_old"
}
