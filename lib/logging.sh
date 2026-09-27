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

: "${OCPROBE_LOG_LEVEL_NUM:=${LOG_LEVEL_INFO}}"
: "${OCPROBE_LOG_FORMAT:=text}" # text|json

# ---- Initialization ---------------------------------------------------------
init_logging() {
	case "${OCPROBE_LOG_LEVEL:-info}" in
	debug) OCPROBE_LOG_LEVEL_NUM=$LOG_LEVEL_DEBUG ;;
	info) OCPROBE_LOG_LEVEL_NUM=$LOG_LEVEL_INFO ;;
	warn) OCPROBE_LOG_LEVEL_NUM=$LOG_LEVEL_WARN ;;
	error) OCPROBE_LOG_LEVEL_NUM=$LOG_LEVEL_ERROR ;;
	*) OCPROBE_LOG_LEVEL_NUM=$LOG_LEVEL_INFO ;;
	esac

	OCPROBE_LOG_FORMAT="${OCPROBE_LOG_FORMAT:-text}"
	if [[ "${OCPROBE_JSON_OUTPUT:-0}" = "1" ]]; then
		OCPROBE_LOG_FORMAT="json"
	fi
}

# ---- ISO 8601 timestamp -----------------------------------------------------
# %N is a GNU date extension. BSD date (macOS) does not implement it and emits
# the format characters literally, so this used to produce timestamps like
# "2026-09-27T12:20:29.3NZ" — not valid ISO 8601, in every --json log line.
# Detect the variant once and always use a form that is known to work, rather
# than emitting a broken value and hoping no one parses it.
#
# The python3 fallback is acceptable because python3 is already a hard
# dependency (lib/config.sh, lib/db.sh, lib/validate.sh and lib/doctor.sh all
# shell out to it), and the JSON path already spawns jq per line, so this adds
# no new dependency and no meaningful overhead. Seconds and milliseconds are
# derived from a single millisecond value so they cannot straddle a second
# boundary and disagree.
if [[ "$(date -u +%3N 2>/dev/null)" =~ ^[0-9]{3}$ ]]; then
	_ocprobe_iso8601_now() { date -u +"%Y-%m-%dT%H:%M:%S.%3NZ"; }
else
	_ocprobe_iso8601_now() {
		python3 -c 'import time; ms=int(time.time()*1000); print("%s.%03dZ" % (time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(ms//1000)), ms%1000))'
	}
fi

# ---- Internal logging -------------------------------------------------------
_log() {
	local level_num="$1" level_name="$2" msg="$3"
	((level_num < OCPROBE_LOG_LEVEL_NUM)) && return 0

	local timestamp
	timestamp=$(_ocprobe_iso8601_now)
	local caller="${BASH_SOURCE[2]##*/}:${BASH_LINENO[1]}"

	if [[ "$OCPROBE_LOG_FORMAT" == "json" ]]; then
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
	[[ -n "$OCPROBE_LOG_FILE" ]] && printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$msg" >>"$OCPROBE_LOG_FILE"
}
