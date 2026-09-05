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
INSERT INTO message VALUES (1, 'ses_probe1', strftime('%s','now')*1000);
INSERT INTO message VALUES (2, 'ses_probe2', (strftime('%s','now')-90000)*1000);
INSERT INTO part VALUES (1, 'ses_probe1', 1, strftime('%s','now')*1000, '{"type":"text","text":"Reply with exactly: OK"}');
INSERT INTO part VALUES (2, 'ses_probe2', 2, (strftime('%s','now')-90000)*1000, '{"type":"text","text":"Reply with exactly: OK"}');
EOF
}
