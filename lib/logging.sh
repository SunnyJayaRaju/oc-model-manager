#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/logging.sh — Structured logging with text/JSON output
# ============================================================================

# ---- Log Levels -------------------------------------------------------------
: "${LOG_LEVEL_DEBUG:=0}"
: "${LOG_LEVEL_INFO:=1}"
: "${LOG_LEVEL_WARN:=2}"
: "${LOG_LEVEL_ERROR:=3}"
: "${LOG_LEVEL_FATAL:=4}"

: "${OCM_LOG_LEVEL_NUM:=${LOG_LEVEL_INFO}}"
: "${OCM_LOG_FORMAT:=text}" # text|json

# ---- Initialization ---------------------------------------------------------
init_logging() {
	case "${OCM_LOG_LEVEL:-info}" in
	debug) OCM_LOG_LEVEL_NUM=$LOG_LEVEL_DEBUG ;;
	info) OCM_LOG_LEVEL_NUM=$LOG_LEVEL_INFO ;;
	warn) OCM_LOG_LEVEL_NUM=$LOG_LEVEL_WARN ;;
	error) OCM_LOG_LEVEL_NUM=$LOG_LEVEL_ERROR ;;
	*) OCM_LOG_LEVEL_NUM=$LOG_LEVEL_INFO ;;
	esac

	OCM_LOG_FORMAT="${OCM_LOG_FORMAT:-text}"
	if [[ "${OCM_JSON_OUTPUT:-0}" = "1" ]]; then
		OCM_LOG_FORMAT="json"
	fi
}

# ---- Internal logging -------------------------------------------------------
_log() {
	local level_num="$1" level_name="$2" msg="$3"
	((level_num < OCM_LOG_LEVEL_NUM)) && return 0

	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
	local caller="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"

	if [[ "$OCM_LOG_FORMAT" == "json" ]]; then
		jq -cn \
			--arg ts "$timestamp" \
			--arg level "$level_name" \
			--arg msg "$msg" \
			--arg caller "$caller" \
			--arg pid "$$" \
			'{timestamp:$ts, level:$level, message:$msg, caller:$caller, pid:$pid|tonumber}'
	else
		printf '[%s] %-5s %s\n' "$(date '+%H:%M:%S')" "$level_name" "$msg" >&2
	fi
}

# ---- Public API -------------------------------------------------------------
log_debug() { _log "$LOG_LEVEL_DEBUG" "DEBUG" "$*"; }
log_info() { _log "$LOG_LEVEL_INFO" "INFO" "$*"; }
log_warn() { _log "$LOG_LEVEL_WARN" "WARN" "$*"; }
log_error() { _log "$LOG_LEVEL_ERROR" "ERROR" "$*"; }
log_fatal() { _log "$LOG_LEVEL_FATAL" "FATAL" "$*"; }

# ---- Audit log (always text, to file) --------------------------------------
audit_log() {
	local msg="$1"
	[[ -n "$OCM_LOG_FILE" ]] && printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$msg" >>"$OCM_LOG_FILE"
}
