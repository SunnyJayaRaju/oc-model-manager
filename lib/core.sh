#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/core.sh — Shared utilities and constants
# ============================================================================

# ---- Constants --------------------------------------------------------------
# Use conditional assignment to allow re-sourcing
: "${OCM_PROBE_PROMPT:=Reply with exactly: OK}"
: "${OCM_PROBE_TITLE_PREFIX:=ocmm-probe}"
: "${OCM_AGE_GUARD_MS:=86400000}"  # 24h in ms
: "${OCM_FRESH_GUARD_MS:=3600000}" # 1h in ms
: "${OCM_MAX_MSG_COUNT:=4}"
: "${OCM_HISTORY_LIMIT:=5000}"
: "${OCM_ALERT_LIMIT:=1000}"
: "${OCM_CACHE_TTL_HOURS:=24}"
: "${OCM_BACKUP_KEEP_DAYS:=30}"
: "${OCM_GRAVEYARD_COOLDOWN_HOURS:=24}"
: "${OCM_DEFAULT_WATCH_SECS:=21600}" # 6h
: "${OCM_MAX_PARALLEL:=4}"
: "${OCM_PROBE_TIMEOUT_NEW:=45}"
: "${OCM_PROBE_TIMEOUT_WL:=30}"

# ---- Paths (resolved at runtime) -------------------------------------------
: "${OCM_CONFIG_FILE:=}"
: "${OCM_STATE_DIR:=}"
: "${OCM_AUDIT_DIR:=}"
: "${OCM_DB_FILE:=$HOME/.local/share/opencode/opencode.db}"

# ---- Runtime State ---------------------------------------------------------
: "${OCM_STAMP:=}"
: "${OCM_RUN_DIR:=}"
: "${OCM_LOG_FILE:=}"
: "${OCM_RESULTS_FILE:=}"
: "${OCM_LOCK_DIR:=}"

# ---- Validation -------------------------------------------------------------
validate_positive_int() {
	local var_name="$1" var_value="$2"
	[[ "$var_value" =~ ^[0-9]+$ ]] && [[ "$var_value" -gt 0 ]] || die "$var_name must be a positive integer (got: $var_value)"
}

validate_model_name() {
	local model="$1"
	# Allow provider/model, provider/model:variant, and kilo/~provider/model
	[[ "$model" =~ ^[a-zA-Z0-9_./:~:-]+$ ]] || return 1
	# Must have at least one slash
	[[ "$model" == */* ]] || return 1
	return 0
}

# ---- Portable timestamp (ms) ------------------------------------------------
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
now_s() { date +%s; }

# ---- SQL escaping -----------------------------------------------------------
# Validates and escapes a string for safe use in SQLite SQL queries.
# Returns 0 on success, 1 on validation failure.
sql_escape() {
	local input="$1"
	local max_len="${2:-256}"

	# Reject empty input
	[[ -n "$input" ]] || return 1

	# Reject input that's too long
	[[ ${#input} -le $max_len ]] || return 1

	# Reject input containing null bytes (0x00), newlines (0x0a), or carriage returns (0x0d)
	# Using od to avoid bash pattern matching issues with special characters
	local hex_dump
	hex_dump=$(printf '%s' "$input" | od -An -tx1)
	echo "$hex_dump" | grep -q "00" && return 1 # null byte
	echo "$hex_dump" | grep -q "0a" && return 1 # newline (LF)
	echo "$hex_dump" | grep -q "0d" && return 1 # carriage return (CR)

	# Escape single quotes by doubling them (SQLite standard)
	printf '%s' "$input" | sed "s/'/''/g"
	return 0
}

# Validates a session ID format (alphanumeric, underscore, hyphen only)
validate_session_id() {
	local sid="$1"
	[[ -n "$sid" ]] && [[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# ---- Error handling ---------------------------------------------------------
die() {
	log_fatal "$*"
	cleanup_run_dir
	release_lock
	exit 1
}

# ---- File operations --------------------------------------------------------
atomic_write() {
	local target="$1"
	local tmp="${target}.tmp.$$"
	cat >"$tmp"
	mv "$tmp" "$target"
}

# ---- Cleanup ----------------------------------------------------------------
cleanup_run_dir() {
	[[ -d "$OCM_RUN_DIR" && "$OCM_RUN_DIR" == "$TMPDIR"/*/ocm-* ]] && rm -rf "$OCM_RUN_DIR"
}

# ---- Pruning JSONL files ----------------------------------------------------
prune_jsonl() {
	local file="$1" max_lines="${2:-5000}"
	[[ -f "$file" ]] || return 0
	local lines
	lines=$(wc -l <"$file" | tr -d ' ')
	if ((lines > max_lines)); then
		local tmp_file="${file}.tmp.$$"
		tail -n "$max_lines" "$file" >"$tmp_file" && mv "$tmp_file" "$file"
	fi
}

# ---- Array utilities --------------------------------------------------------
array_contains() {
	local needle="$1"
	shift
	for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
	return 1
}

array_dedup() {
	local var_name="$1"
	# Use a simple approach: read array via indirect reference
	local -a result=()
	local -a seen=()
	local idx=0
	while :; do
		local elem_var="${var_name}[$idx]"
		# Check if array element exists before accessing
		if [[ -v $elem_var ]]; then
			local val="${!elem_var}"
			if ! array_contains "$val" "${seen[@]}"; then
				seen+=("$val")
				result+=("$val")
			fi
		else
			break
		fi
		idx=$((idx + 1))
	done
	# Write back to original array
	eval "${var_name}=()"
	for item in "${result[@]}"; do
		eval "${var_name}+=(\"\$item\")"
	done
}
