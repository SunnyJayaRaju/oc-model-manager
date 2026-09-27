#!/usr/bin/env bash
# Test helper to source all libraries in correct order

export OCPROBE_ROOT="${OCPROBE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Source in dependency order
source "$OCPROBE_ROOT/lib/core.sh"
source "$OCPROBE_ROOT/lib/logging.sh"
source "$OCPROBE_ROOT/lib/locking.sh"
source "$OCPROBE_ROOT/lib/db.sh"
source "$OCPROBE_ROOT/lib/config.sh"
source "$OCPROBE_ROOT/lib/policy.sh"
source "$OCPROBE_ROOT/lib/models.sh"
source "$OCPROBE_ROOT/lib/session.sh"
source "$OCPROBE_ROOT/lib/scheduler.sh"
source "$OCPROBE_ROOT/lib/doctor.sh"
source "$OCPROBE_ROOT/lib/validate.sh"

# Initialize logging for tests
init_logging

# Create test state directory
export OCPROBE_STATE_DIR="${OCPROBE_STATE_DIR:-$(mktemp -d /tmp/ocprobe-test-XXXXXX)}"
export OCPROBE_RUN_DIR="${OCPROBE_RUN_DIR:-$(mktemp -d /tmp/ocprobe-run-XXXXXX)}"
export OCPROBE_LOG_FILE="$OCPROBE_RUN_DIR/audit.log"
export OCPROBE_RESULTS_FILE="$OCPROBE_RUN_DIR/results.tsv"
export OCPROBE_LOCK_DIR="$OCPROBE_STATE_DIR/.lock"

mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

# Mock opencode for testing
mock_opencode() {
	local mock_dir
	mock_dir=$(mktemp -d /tmp/ocprobe-mock-XXXXXX)
	cat >"$mock_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  models)
    cat <<'MODELS'
openai/gpt-4
openai/gpt-3.5-turbo
anthropic/claude-3
google/gemini-pro
kilo/~openai/gpt-4
MODELS
    ;;
  run)
    if [[ "$*" == *"gpt-4"* ]]; then
      sleep 0.1
      echo "OK"
      exit 0
    elif [[ "$*" == *"gpt-3.5"* ]]; then
      echo "Error: model not found"
      exit 1
    elif [[ "$*" == *"claude"* ]]; then
      echo "No payment method"
      exit 1
    elif [[ "$*" == *"gemini"* ]]; then
      sleep 0.1
      echo "OK"
      exit 0
    else
      echo "OK"
      exit 0
    fi
    ;;
  session)
    case "$2" in
      list)
        echo "ses_abc123  ocmm-probe-test  2024-01-01"
        echo "ses_def456  Real Session  2024-01-01"
        ;;
      delete)
        exit 0
        ;;
    esac
    ;;
  --version)
    echo "opencode 0.1.0-test"
    ;;
esac
EOF
	chmod +x "$mock_dir/opencode"

	# Also mock timeout command
	cat >"$mock_dir/timeout" <<'EOF'
#!/usr/bin/env bash
# Simple timeout mock that just runs the command directly (no actual timeout)
# Usage: timeout SECONDS COMMAND [ARGS...]
if [[ $# -lt 2 ]]; then
  echo "Usage: timeout SECONDS COMMAND [ARGS...]" >&2
  exit 1
fi
shift
exec "$@"
EOF
	chmod +x "$mock_dir/opencode"
	chmod +x "$mock_dir/timeout"
	export PATH="$mock_dir:$PATH"
}

# Mock sqlite3 for test DB
mock_sqlite3() {
	local mock_dir
	mock_dir=$(mktemp -d /tmp/ocprobe-mock-sqlite-XXXXXX)
	cat >"$mock_dir/sqlite3" <<'EOF'
#!/usr/bin/env bash
# Debug: log all arguments
echo "DEBUG SQLITE3 ARGS: $#" >&2
for arg in "$@"; do
  echo "DEBUG SQLITE3 ARG: $arg" >&2
done
echo "DEBUG SQLITE3 FULL: $0 $*" >&2

# Find real sqlite3 path
REAL_SQLITE3="/usr/bin/sqlite3"
[[ -x "$REAL_SQLITE3" ]] || REAL_SQLITE3="/opt/homebrew/bin/sqlite3"
[[ -x "$REAL_SQLITE3" ]] || REAL_SQLITE3="/usr/local/bin/sqlite3"

# If SQL is passed via stdin (like create_test_db), pass to real sqlite3 completely
# stdin mode: sqlite3 -readonly <db> <<EOF ... EOF (2 args)
# query mode: sqlite3 -readonly <db> "query" (3+ args)
if [[ $# -eq 2 ]]; then
  # stdin mode - pass to real sqlite3
  echo "DEBUG: Passing stdin SQL to real sqlite3 (argc=2)" >&2
  exec "$REAL_SQLITE3" "$@"
fi

# If SQL is passed as argument (interactive query mode)
# sqlite3 -readonly <db> <query> -> args: -readonly, <db>, <query>
if [[ $# -ge 3 ]]; then
  query="$3"
  echo "DEBUG SQLITE3 QUERY: $query" >&2
  
  if [[ "$query" == *"PRAGMA integrity_check"* ]]; then
    echo "ok"
    exit 0
  elif [[ "$query" == *"FROM session WHERE id="* ]]; then
    # session_age_ms query - return age for ses_probe2 (25 hours = 90000000 ms)
    if [[ "$query" == *"strftime('%s','now')*1000) - time_created"* && "$query" == *"ses_probe2"* ]]; then
      echo "90000000"
      exit 0
    fi
    exit 0
  # is_probe_session query - check session ID to return correct result
  elif [[ "$query" == *"FROM message m"* && "$query" == *"WHERE m.session_id="* ]]; then
    # is_probe_session query - extract session ID and return correct result
    # ses_probe1 has probe prompt and is fresh -> return 1
    # ses_probe2 is old (>24h) -> return nothing
    # ses_real has no probe prompt -> return nothing
    if [[ "$query" == *"ses_probe1"* ]]; then
      echo "1"
      exit 0
    else
      exit 0
    fi
  # Fresh probe sessions query - MUST come before general "FROM message WHERE session_id=" pattern
  elif [[ "$query" == *"time_created > (strftime('%s','now')-"* && "$query" == *"EXISTS (SELECT 1 FROM message WHERE session_id=id)"* ]]; then
    # Fresh probe sessions query - return ses_probe1 (fresh with messages)
    echo "ses_probe1"
    exit 0
  elif [[ "$query" == *"FROM message WHERE session_id="* ]]; then
    exit 0
  elif [[ "$query" == *"FROM part WHERE message_id="* ]]; then
    exit 0
  fi
fi

# Default: use real sqlite3
exec "$REAL_SQLITE3" "$@"
EOF
	chmod +x "$mock_dir/sqlite3"
	export PATH="$mock_dir:$PATH"
}

# Create test database for session tests
create_test_db() {
	local db_file="${1:-$OCPROBE_STATE_DIR/test.db}"
	export OCPROBE_OPencode_DB="$db_file"
	# Use real sqlite3 for database creation (bypass mock)
	local real_sqlite3="/usr/bin/sqlite3"
	[[ -x "$real_sqlite3" ]] || real_sqlite3="/opt/homebrew/bin/sqlite3"
	[[ -x "$real_sqlite3" ]] || real_sqlite3="/usr/local/bin/sqlite3"
	"$real_sqlite3" "$db_file" <<'EOF'
DROP TABLE IF EXISTS todo;
DROP TABLE IF EXISTS part;
DROP TABLE IF EXISTS message;
DROP TABLE IF EXISTS session;
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  title TEXT,
  time_created INTEGER,
  time_updated INTEGER
);
CREATE TABLE message (
  id INTEGER PRIMARY KEY,
  session_id TEXT,
  time_created INTEGER
);
CREATE TABLE part (
  id INTEGER PRIMARY KEY,
  session_id TEXT,
  message_id INTEGER,
  time_created INTEGER,
  data TEXT
);
CREATE TABLE todo (
  id INTEGER PRIMARY KEY,
  session_id TEXT
);
INSERT INTO session VALUES ('ses_probe1', 'ocmm-probe-test', strftime('%s','now')*1000, strftime('%s','now')*1000);
INSERT INTO session VALUES ('ses_probe2', 'ocmm-probe-old', (strftime('%s','now')-90000)*1000, (strftime('%s','now')-90000)*1000);
INSERT INTO session VALUES ('ses_real', 'Real Session', strftime('%s','now')*1000, strftime('%s','now')*1000);
-- The mocked `opencode run` reports sessionID "ses_test123", and the mocked
-- `opencode session list` lists it. The database must agree with both, because
-- delete_session verifies the title by reading this table directly (it used to
-- read the paginated CLI listing instead, so the CLI mock alone was enough).
INSERT INTO session VALUES ('ses_test123', 'ocprobe-probe', strftime('%s','now')*1000, strftime('%s','now')*1000);
INSERT INTO message VALUES (4, 'ses_test123', strftime('%s','now')*1000);
INSERT INTO part VALUES (4, 'ses_test123', 4, strftime('%s','now')*1000, '{"type":"text","text":"Reply with exactly: OK"}');
INSERT INTO message VALUES (1, 'ses_probe1', strftime('%s','now')*1000);
INSERT INTO message VALUES (2, 'ses_probe2', (strftime('%s','now')-90000)*1000);
INSERT INTO part VALUES (1, 'ses_probe1', 1, strftime('%s','now')*1000, '{"type":"text","text":"Reply with exactly: OK"}');
INSERT INTO part VALUES (2, 'ses_probe2', 2, (strftime('%s','now')-90000)*1000, '{"type":"text","text":"Reply with exactly: OK"}');
EOF
}

# ---- launchd / scheduler mocking ---------------------------------------------
# These live here rather than in a single test file because two suites need
# them, and neither may ever touch the developer's real launchd agent: a real
# `ocprobe scheduler install` on a workstation makes any assertion of
# "NOT INSTALLED" fail spuriously. (That happened once already during this
# project's own testing.)

# setup_launchd_stubs [ok|fail] — put a fake `launchctl` first on PATH and
# redirect launchd_plist_path() away from the real ~/Library/LaunchAgents, so
# launchd_install / launchd_uninstall / launchd_status run entirely against a
# controlled fake. Calls are recorded in $BATS_TEST_TMPDIR/launchctl.calls.
#   $1 "ok"      -> `launchctl load` succeeds; `launchctl list` prints nothing
#      "fail"    -> `launchctl load` exits 5
#      "running" -> `launchctl list` prints the agent, i.e. launchd_status
#                   should report INSTALLED (running) rather than not running
setup_launchd_stubs() { # $1 = "ok" | "fail" | "running"
  local bin="$BATS_TEST_TMPDIR/lb"
  mkdir -p "$bin"
  cat >"$bin/launchctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$BATS_TEST_TMPDIR/launchctl.calls"
case "\$1" in
  list)
    # launchd_status decides running vs not-running by GREPPING this output:
    #   launchctl list | grep -q com.ocprobe.watch
    # so the pipeline's status is grep's, and it is launchctl's STDOUT that
    # matters, not its exit code. "running" mode therefore has to actually
    # print the label; exiting 0 in silence always reads as "not running".
    # (systemd_status is the mirror image: it throws the output away and reads
    # the exit code, which is why its stub switches on is-enabled's status.)
    if [[ "$1" == "running" ]]; then
        printf 'PID\tStatus\tLabel\n'
        printf '123\t0\t0\tcom.ocprobe.watch\n'
    fi
    exit 0
    ;;
  load)
    if [[ "$1" == "fail" ]]; then
      echo "Load failed: 5: Input/output error" >&2
      exit 5
    fi
    exit 0
    ;;
esac
exit 0
EOF
  chmod +x "$bin/launchctl"
  export PATH="$bin:$PATH"
  : >"$BATS_TEST_TMPDIR/launchctl.calls"
  # redirect the plist away from ~/Library/LaunchAgents (current shell only)
  eval "launchd_plist_path() { echo '$BATS_TEST_TMPDIR/com.ocprobe.watch.plist'; }"
}

# setup_systemd_stubs [ok|fail] — the systemd counterpart of
# setup_launchd_stubs: a fake `systemctl` first on PATH, plus
# systemd_unit_path()/systemd_timer_path() redirected away from the real
# ~/.config/systemd/user. Calls are recorded in
# $BATS_TEST_TMPDIR/systemctl.calls.
#
# systemd_status() is shaped differently from launchd_status in a way that
# matters: it tests for the unit FILE first and only then asks
# `systemctl --user is-enabled`. With no unit file it short-circuits to
# "NOT INSTALLED" and never calls systemctl at all. So both dependencies have
# to be mocked, or the systemctl stub is never exercised.
#   $1 "ok"   -> `is-enabled` succeeds -> "INSTALLED (enabled)"
#      "fail" -> `is-enabled` exits 1  -> "INSTALLED (disabled)"
setup_systemd_stubs() { # $1 = "ok" | "fail"
  local bin="$BATS_TEST_TMPDIR/sb"
  mkdir -p "$bin"
  cat >"$bin/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$@" >>"$BATS_TEST_TMPDIR/systemctl.calls"
if [[ "\$1" == "--user" && "\$2" == "is-enabled" && "$1" == "fail" ]]; then
    exit 1
fi
exit 0
EOF
  chmod +x "$bin/systemctl"
  export PATH="$bin:$PATH"
  : >"$BATS_TEST_TMPDIR/systemctl.calls"
  # redirect the units away from the real ~/.config/systemd/user
  eval "systemd_unit_path() { echo '$BATS_TEST_TMPDIR/ocprobe-watch.service'; }"
  eval "systemd_timer_path() { echo '$BATS_TEST_TMPDIR/ocprobe-watch.timer'; }"
}

# isolate_scheduler_home — export a throwaway HOME so BOTH scheduler backends
# resolve their state files inside the test's own temp dir:
#   launchd_status -> $HOME/Library/LaunchAgents/com.ocprobe.watch.plist
#   systemd_status -> $HOME/.config/systemd/user/ocprobe-watch.service
# Both paths are $HOME-relative, so one fake HOME covers both platforms.
#
# This is needed whenever the code under test runs in a separate process:
# bootstrap.bats drives `ocprobe doctor` through `bash -c`, and the stubs above
# only redefine shell FUNCTIONS, which cannot cross that boundary. PATH and
# HOME are both inherited by the child, so both reach it — without a fake HOME
# the child resolves the REAL state file and the test depends on the host.
isolate_scheduler_home() {
  local h="$BATS_TEST_TMPDIR/fake-home"
  mkdir -p "$h/Library/LaunchAgents" "$h/.config/systemd/user"
  export HOME="$h"
}
