#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/core.sh — Shared utilities and constants
# ============================================================================

# ---- Minimum bash version guard --------------------------------------------
# core.sh is the first library sourced by every entry point (bin/ocprobe and the
# bats helper both source it first), so this is the single choke point where an
# old interpreter can be rejected with an actionable message. Without it, a
# bash 3.2 interpreter fails much later with an opaque parse error such as
# "conditional binary operator expected" (from `[[ -v ]]`) or
# "local: -n: invalid option" (from namerefs), which tells a user nothing.
#
# Floor is 4.3, not 4.2: `local -n` namerefs are used in lib/db.sh (4x) and
# lib/validate.sh and landed in bash 4.3. A 4.2 floor would wave through an
# interpreter that then dies on the first nameref — exactly the cryptic failure
# this guard exists to prevent. No 4.3+/5.x-only constructs are used elsewhere,
# so 4.3 is sufficient.
#
# This uses only syntax available in bash 3.2 so it can report the problem
# rather than tripping over it. BASH_VERSINFO is [major, minor, patch].
if [[ -z "${BASH_VERSINFO[0]:-}" ]] || [[ "${BASH_VERSINFO[0]}" -lt 4 ]] ||
	{ [[ "${BASH_VERSINFO[0]}" -eq 4 ]] && [[ "${BASH_VERSINFO[1]:-0}" -lt 3 ]]; }; then
	echo "ocprobe requires bash 4.3 or newer; you are running bash ${BASH_VERSION:-unknown}." >&2
	echo "" >&2
	echo "macOS ships bash 3.2 as /bin/bash, which is what you are likely using." >&2
	echo "Install a modern bash and ensure it takes precedence on PATH:" >&2
	echo "" >&2
	echo "    brew install bash" >&2
	echo "" >&2
	echo "then verify with 'bash --version' — Homebrew's bash lives in" >&2
	echo "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/bin, which must come before /bin." >&2
	exit 78 # EX_CONFIG
fi

# ---- Constants --------------------------------------------------------------
# Use conditional assignment to allow re-sourcing
: "${OCPROBE_PROBE_PROMPT:=Reply with exactly: OK}"
: "${OCPROBE_PROBE_TITLE_PREFIX:=ocprobe-probe}"
# Legacy probe title prefix for backward compatibility with sessions created
# before the ocm→ocprobe rename. Can be removed in a future cleanup once
# no old probe sessions remain.
: "${OCPROBE_PROBE_TITLE_PREFIX_LEGACY:=ocmm-probe}"
: "${OCPROBE_AGE_GUARD_MS:=86400000}"  # 24h in ms
: "${OCPROBE_FRESH_GUARD_MS:=3600000}" # 1h in ms
: "${OCPROBE_MAX_MSG_COUNT:=4}"
: "${OCPROBE_HISTORY_LIMIT:=5000}"
: "${OCPROBE_ALERT_LIMIT:=1000}"
: "${OCPROBE_CACHE_TTL_HOURS:=1}"
: "${OCPROBE_BACKUP_KEEP_DAYS:=30}"
: "${OCPROBE_GRAVEYARD_COOLDOWN_HOURS:=24}"
: "${OCPROBE_DEFAULT_WATCH_SECS:=21600}" # 6h
: "${OCPROBE_MAX_PARALLEL:=4}"
: "${OCPROBE_PROBE_TIMEOUT_NEW:=45}"
: "${OCPROBE_PROBE_TIMEOUT_WL:=30}"

# ---- Paths (resolved at runtime) -------------------------------------------
: "${OCPROBE_CONFIG_FILE:=}"
: "${OCPROBE_STATE_DIR:=}"
: "${OCPROBE_AUDIT_DIR:=}"
: "${OCPROBE_DB_FILE:=$HOME/.local/share/opencode/opencode.db}"

# ---- Runtime State ---------------------------------------------------------
: "${OCPROBE_STAMP:=}"
: "${OCPROBE_RUN_DIR:=}"
: "${OCPROBE_LOG_FILE:=}"
: "${OCPROBE_RESULTS_FILE:=}"
: "${OCPROBE_LOCK_DIR:=}"

# ---- Validation -------------------------------------------------------------
# Max digits for a config integer. Well beyond any legitimate value here (the
# largest shipped default is a timeout of 21600) and comfortably inside int64,
# so no value that passes this gate can overflow an arithmetic expansion or a
# SQL integer literal. It also makes the overflow case a clean rejection with a
# message that says why, instead of whatever the shell's arithmetic evaluator
# decides to print.
OCPROBE_MAX_INT_DIGITS=10

validate_positive_int() {
	local var_name="$1" var_value="$2"
	# 10# forces base 10. Without it a leading zero means OCTAL, which produced
	# two errors for one problem -- first "value too great for base (error token
	# is \"08\")" from the shell, then "must be a positive integer" -- and meant
	# that `007` was silently accepted as octal 7, so the number reaching the
	# unquoted SQL and $(( )) sinks was not the number the user wrote.
	# Each rejection both calls die and returns 1 explicitly. In production die
	# exits, so the `return 1` is unreachable -- but the contract of this function
	# is "return non-zero on rejection", not "exit", and test/unit/core.bats mocks
	# die to `echo; return 1` precisely so it can assert on the status. Relying on
	# die's exit would make this function report success under that mock.
	if [[ ! "$var_value" =~ ^[0-9]+$ ]]; then
		die "$var_name must be a positive integer (got: $var_value)"
		return 1
	fi
	if ((${#var_value} > OCPROBE_MAX_INT_DIGITS)); then
		die "$var_name must be at most $OCPROBE_MAX_INT_DIGITS digits (got: $var_value)"
		return 1
	fi
	# Strip leading zeros before comparing, so "00" and "000" are correctly seen
	# as the zero they are rather than as octal 0.
	local canonical="${var_value#"${var_value%%[!0]*}"}"
	[[ -n "$canonical" ]] || canonical=0
	if ((10#$canonical < 1)); then
		die "$var_name must be a positive integer (got: $var_value)"
		return 1
	fi
	return 0
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

# ---- Portable timeout -------------------------------------------------------
# GNU `timeout` is NOT present on stock macOS. Callers previously invoked
# `timeout` unguarded, so on a Mac without coreutils the command failed with
# 127 and the result was misread as a probe failure. Use this everywhere.
# run_with_timeout <seconds> <cmd> [args...]
# Returns the command's exit code; 124 when the timeout fired.
run_with_timeout() {
	local secs="$1"
	shift
	if command -v timeout >/dev/null 2>&1; then
		timeout "$secs" "$@"
	else
		perl -e 'alarm $ARGV[0]; exec @ARGV[1..$#ARGV] or exit 127' "$secs" "$@"
	fi
}

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
	[[ -d "$OCPROBE_RUN_DIR" && "$OCPROBE_RUN_DIR" == "${TMPDIR:-/tmp}"/*/ocprobe-* ]] && rm -rf "$OCPROBE_RUN_DIR"
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
		# Check if array element exists before accessing.
		# `${!elem_var+x}` is the portable equivalent of `[[ -v $elem_var ]]`:
		# true when the variable named by $elem_var is set. `[[ -v ]]` requires
		# bash 4.2 and is a parse error on older interpreters.
		if [[ -n "${!elem_var+x}" ]]; then
			local val="${!elem_var}"
			# ${a[@]+"${a[@]}"} not "${a[@]}": $seen is empty on the first
			# element, which is unbound under set -u on bash 4.3.
			if ! array_contains "$val" ${seen[@]+"${seen[@]}"}; then
				seen+=("$val")
				result+=("$val")
			fi
		else
			break
		fi
		idx=$((idx + 1))
	done
	# Write back to original array without eval
	# Build newline-separated string from result
	local output
	printf -v output '%s\n' "${result[@]}"
	# Remove trailing newline
	output="${output%$'\n'}"
	# Convert back to array using mapfile
	mapfile -t "$var_name" <<<"$output"
}
