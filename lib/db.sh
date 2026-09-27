#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/db.sh — SQLite database operations
# ============================================================================

# ---- Session Queries --------------------------------------------------------

# Get session age in milliseconds
session_age_ms() {
	local sid="$1"
	local sid_escaped
	sid_escaped=$(sql_escape "$sid") || return 1

	[[ -f "$OCPROBE_OPencode_DB" ]] || return 1

	local age_ms
	age_ms=$(sqlite3 -readonly "$OCPROBE_OPencode_DB" \
		"SELECT (strftime('%s','now')*1000) - time_created FROM session WHERE id='${sid_escaped}' LIMIT 1;" \
		2>/dev/null) || return 1

	[[ -n "$age_ms" ]] || return 1
	echo "$age_ms"
}

# Delete session
# Single choke point for session deletion, so the safety guards live HERE rather
# than at each call site: a future caller cannot delete an unvalidated id.
delete_session() {
	local sid="$1"

	# (a) Format gate. opencode session ids are "ses_" followed by [A-Za-z0-9_-]
	# (the same shape get_session_title matches with /^ses_/). Anything
	# else cannot be a real id, so refuse before invoking the CLI.
	if [[ ! "$sid" =~ ^ses_[A-Za-z0-9_-]+$ ]]; then
		log_error "delete_session: refusing malformed session id: '$sid'"
		return 1
	fi

	# (b) Title gate. Only ever delete a session that is recognisably a probe
	# session. A session that is absent, or whose title is not a known probe
	# prefix, is REFUSED — fail closed, so an id mis-parsed out of model output
	# cannot delete a real conversation.
	#
	# The lookup is a single-row DB read, not `opencode session list`: that CLI
	# listing paginates at 100 rows, so probing that way left a blind spot — a
	# genuine probe session beyond the newest 100 was reported "not present" and
	# refused, which leaked sessions that cmd_session_cleanup had already found
	# via the DB. Reading the row directly is complete by construction and so is
	# strictly MORE protective, not less: the same three prefixes are still
	# required and an unknown id is still refused.
	local validate_title_prefix="${OCPROBE_VALIDATE_TITLE_PREFIX:-ocprobe-validate}"
	local row title
	row=$(get_session_title "$sid")

	if [[ -z "$row" ]]; then
		log_error "delete_session: refusing to delete $sid — not present in the session database, cannot confirm it is a probe session"
		return 1
	fi
	# get_session_title emits "<id><TAB><title>"; strip the id.
	title="${row#*$'\t'}"

	case "$title" in
	"${OCPROBE_PROBE_TITLE_PREFIX}"* | "${OCPROBE_PROBE_TITLE_PREFIX_LEGACY}"* | "$validate_title_prefix"*)
		;;
	*)
		log_error "delete_session: refusing to delete $sid — title '$title' is not a probe session"
		return 1
		;;
	esac

	opencode session delete "$sid" >/dev/null 2>&1
}

# List all sessions with titles
# get_session_title(sid) — print "<id><TAB><title>" for one session, or nothing
# if it does not exist. Single-row primary-key lookup, so it is not subject to
# the 100-row pagination of `opencode session list`. Mirrors the column
# selection used by list_probe_sessions_since (id || char(9) || COALESCE(...)),
# which also lets an absent row be told apart from a row whose title is empty.
get_session_title() {
	local sid="$1"
	[[ -f "$OCPROBE_OPencode_DB" ]] || return 1
	local sid_esc
	sid_esc=$(sql_escape "$sid") || return 1
	sqlite3 -readonly "$OCPROBE_OPencode_DB" \
		"SELECT id || char(9) || COALESCE(title, '') FROM session WHERE id='${sid_esc}' LIMIT 1;" \
		2>/dev/null
}

# All session ids currently in the DB (complete, unpaginated).
# `opencode session list` caps at 100 rows, so it must not be used to build a
# safety baseline: on a busy history it silently omits pre-existing sessions.
list_all_session_ids() {
	[[ -f "$OCPROBE_OPencode_DB" ]] || return 0
	sqlite3 -readonly "$OCPROBE_OPencode_DB" "SELECT id FROM session;" 2>/dev/null || true
}

# Enumerate probe sessions created at/after <epoch_ms> that are safe to delete.
#
# `opencode session list` paginates (100 rows by default), so on a large run the
# CLI view hides most of the sessions the run just created — cleanup then deleted
# only what it could see and leaked the rest (observed: 842 leaked probe sessions
# from a 942-model validate). Query the DB instead, bounded by the run start time.
#
# The age guard and the "probe sessions are tiny" guard are applied in SQL so no
# giant IN (...) clause is needed (942 ids would be slow and near SQLite limits).
#
# Prints: <id>\t<title>
list_probe_sessions_since() {
	local since_ms="$1"
	[[ -f "$OCPROBE_OPencode_DB" ]] || return 0
	[[ "$since_ms" =~ ^[0-9]+$ ]] || return 0

	local p1 p2 p3 age_hours max_msgs
	p1=$(sql_escape "${OCPROBE_PROBE_TITLE_PREFIX:-ocprobe-probe}")
	p2=$(sql_escape "${OCPROBE_PROBE_TITLE_PREFIX_LEGACY:-ocmm-probe}")
	# The validate worker titles its sessions "ocprobe-validate", which matched
	# neither prefix above — so validate runs deleted almost nothing and leaked a
	# session per probed model (842 observed). Keep all three in sync here.
	p3=$(sql_escape "${OCPROBE_VALIDATE_TITLE_PREFIX:-ocprobe-validate}")
	age_hours="${OCPROBE_AGE_GUARD_HOURS:-24}"
	max_msgs="${OCPROBE_MAX_MSG_COUNT:-4}"
	[[ "$age_hours" =~ ^[0-9]+$ ]] || age_hours=24
	[[ "$max_msgs" =~ ^[0-9]+$ ]] || max_msgs=4

	sqlite3 -readonly "$OCPROBE_OPencode_DB" <<PY
SELECT s.id || char(9) || COALESCE(s.title, '')
FROM session s
WHERE s.time_created >= ${since_ms}
  AND s.time_created >  (strftime('%s','now') - ${age_hours}*3600) * 1000
  AND (s.title LIKE '${p1}%' OR s.title LIKE '${p2}%' OR s.title LIKE '${p3}%')
  AND (SELECT COUNT(*) FROM message m WHERE m.session_id = s.id) <= ${max_msgs}
ORDER BY s.time_created;
PY
}

# Probe History Queries ------------------------------------------------------

# Load probe history into associative arrays
load_probe_history() {
	local -n last_status=$1
	local -n fail_count=$2

	[[ -f "$OCPROBE_STATE_DIR/probe-history.jsonl" ]] || return 0

	local line_num=0
	while IFS= read -r line; do
		line_num=$((line_num + 1))
		[[ -n "$line" ]] || continue

		local model status
		model=$(printf '%s' "$line" | jq -r '.model // empty' 2>/dev/null)
		status=$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null)

		[[ -n "$model" && -n "$status" ]] || {
			log_warn "Skipping malformed line $line_num in probe-history.jsonl"
			continue
		}

		local safe_key="${model//\//_}"
		# shellcheck disable=SC2034,SC2034
		last_status["$safe_key"]="$status"
		if [[ "$status" != "WORKS" ]]; then
			fail_count["$safe_key"]=$((${fail_count["$safe_key"]:-0} + 1))
		else
			fail_count["$safe_key"]=0
		fi
	done <"$OCPROBE_STATE_DIR/probe-history.jsonl"
}

# Record probe result to history
record_probe_history() {
	local model="$1" status="$2" latency_ms="$3"
	local ts
	ts=$(ms)
	jq -cn --argjson ts "$ts" --arg m "$model" --arg s "$status" --argjson l "$latency_ms" \
		'{ts:$ts,model:$m,status:$s,latency_ms:$l}' >>"$OCPROBE_STATE_DIR/probe-history.jsonl"
	prune_jsonl "$OCPROBE_STATE_DIR/probe-history.jsonl" "$OCPROBE_HISTORY_LIMIT"
}

# Alert Queries ---------------------------------------------------------------

record_alert() {
	local severity="$1" type="$2" model="$3" message="$4"
	local ts
	ts=$(ms)
	jq -cn --arg ts "$ts" --arg sev "$severity" --arg type "$type" --arg m "$model" --arg msg "$message" \
		'{ts:$ts|tonumber, severity:$sev, type:$type, model:$m, message:$msg}' \
		>>"$OCPROBE_STATE_DIR/alerts.jsonl"
	audit_log "ALERT[$severity] $type $model: $message"

	# Desktop notification for critical (non-batch)
	if [[ "$severity" == "CRITICAL" && "$OCPROBE_BATCH_MODE" -ne 1 && "$OCPROBE_DESKTOP_NOTIFICATIONS" -eq 1 ]]; then
		osascript -e 'on run {t, m}' -e 'display notification m with title t' -e 'end run' \
			"ocprobe" "$model: $message" >/dev/null 2>&1 || true
	fi

	# Webhook URL validation
	validate_webhook_url() {
		local url="$1"
		[[ -n "$url" ]] || return 1
		# Basic URL validation - must start with http:// or https:// and contain a valid hostname
		[[ "$url" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?(/.*)?$ ]] || return 1
		return 0
	}

	# Webhook
	if [[ -n "$OCPROBE_WEBHOOK_URL" ]]; then
		if validate_webhook_url "$OCPROBE_WEBHOOK_URL"; then
			curl -sS --max-time 10 -H 'Content-Type: application/json' \
				-d "$(jq -cn --arg sev "$severity" --arg type "$type" --arg m "$model" --arg msg "$message" \
					'{text:("["+$sev+"] "+$type+" "+$m+": "+$msg)}')" \
				"$OCPROBE_WEBHOOK_URL" >/dev/null 2>&1 || true
		else
			log_warn "Invalid webhook URL configured, skipping webhook notification"
		fi
	fi

	prune_jsonl "$OCPROBE_STATE_DIR/alerts.jsonl" "$OCPROBE_ALERT_LIMIT"
}

# Graveyard Queries -----------------------------------------------------------

get_active_graveyard() {
	local cutoff_ms
	cutoff_ms=$(python3 -c "import time;print(int((time.time()-${OCPROBE_GRAVEYARD_COOLDOWN_HOURS}*3600)*1000))")

	[[ -f "$OCPROBE_STATE_DIR/graveyard.jsonl" ]] || return 0

	awk -F'\t' -v c="$cutoff_ms" '
    NF >= 2 && $1 >= c { print $2 }
  ' "$OCPROBE_STATE_DIR/graveyard.jsonl" 2>/dev/null | sort -u
}
