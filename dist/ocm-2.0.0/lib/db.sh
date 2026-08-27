#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/db.sh — SQLite database operations
# ============================================================================

# ---- Session Queries --------------------------------------------------------

# Check if a session is a probe session (exact prompt match, small, fresh)
is_probe_session() {
	local sid="$1"
	local sid_escaped prompt_escaped
	sid_escaped=$(sql_escape "$sid") || return 1
	prompt_escaped=$(sql_escape "$OCM_PROBE_PROMPT") || return 1

	[[ -f "$OCM_OPencode_DB" ]] || return 1

	sqlite3 -readonly "$OCM_OPencode_DB" \
		"SELECT 1 FROM message m \
     WHERE m.session_id='${sid_escaped}' \
       AND m.id=(SELECT m2.id FROM message m2 WHERE m2.session_id='${sid_escaped}' ORDER BY m2.time_created, m2.id LIMIT 1) \
       AND (SELECT COUNT(*) FROM message WHERE session_id='${sid_escaped}') <= ${OCM_MAX_MSG_COUNT} \
       AND m.time_created > (strftime('%s','now')-${OCM_AGE_GUARD_HOURS}*3600)*1000 \
       AND EXISTS (SELECT 1 FROM part p WHERE p.message_id=m.id \
                   AND json_extract(p.data,'\$.type')='text' \
                   AND trim(json_extract(p.data,'\$.text'), '\"')='${prompt_escaped}') \
     LIMIT 1;" \
		2>/dev/null | grep -q 1
}

# Get session age in milliseconds
session_age_ms() {
	local sid="$1"
	local sid_escaped
	sid_escaped=$(sql_escape "$sid") || return 1

	[[ -f "$OCM_OPencode_DB" ]] || return 1

	local age_ms
	age_ms=$(sqlite3 -readonly "$OCM_OPencode_DB" \
		"SELECT (strftime('%s','now')*1000) - time_created FROM session WHERE id='${sid_escaped}' LIMIT 1;" \
		2>/dev/null) || return 1

	[[ -n "$age_ms" ]] || return 1
	echo "$age_ms"
}

# Check if session has messages
session_has_messages() {
	local sid="$1"
	local sid_escaped
	sid_escaped=$(sql_escape "$sid") || return 1

	[[ -f "$OCM_OPencode_DB" ]] || return 1

	sqlite3 -readonly "$OCM_OPencode_DB" \
		"SELECT 1 FROM message WHERE session_id='${sid_escaped}' LIMIT 1;" \
		2>/dev/null | grep -q 1
}

# Batch query: get old sessions (> age guard)
batch_get_old_sessions() {
	local -n session_array=$1
	local age_hours="${2:-$OCM_AGE_GUARD_HOURS}"

	[[ -f "$OCM_OPencode_DB" ]] || return 0
	[[ ${#session_array[@]} -eq 0 ]] && return 0

	local in_clause
	local -a escaped_sessions=()
	for sid in "${session_array[@]}"; do
		local escaped
		escaped=$(sql_escape "$sid") || continue
		escaped_sessions+=("$escaped")
	done
	[[ ${#escaped_sessions[@]} -eq 0 ]] && return 0
	in_clause=$(printf "'%s'," "${escaped_sessions[@]}" | sed 's/,$//')

	while IFS= read -r sid; do
		[[ -n "$sid" ]] && echo "$sid"
	done < <(sqlite3 -readonly "$OCM_OPencode_DB" \
		"SELECT id FROM session WHERE id IN ($in_clause) AND time_created <= (strftime('%s','now')-${age_hours}*3600)*1000;" \
		2>/dev/null)
}

# Batch query: get fresh probe sessions (< fresh guard, has messages)
batch_get_fresh_probe_sessions() {
	local -n session_array=$1
	local fresh_hours="${2:-$OCM_FRESH_GUARD_HOURS}"

	[[ -f "$OCM_OPencode_DB" ]] || return 0
	[[ ${#session_array[@]} -eq 0 ]] && return 0

	local in_clause
	local -a escaped_sessions=()
	for sid in "${session_array[@]}"; do
		local escaped
		escaped=$(sql_escape "$sid") || continue
		escaped_sessions+=("$escaped")
	done
	[[ ${#escaped_sessions[@]} -eq 0 ]] && return 0
	in_clause=$(printf "'%s'," "${escaped_sessions[@]}" | sed 's/,$//')

	while IFS= read -r sid; do
		[[ -n "$sid" ]] && echo "$sid"
	done < <(sqlite3 -readonly "$OCM_OPencode_DB" \
		"SELECT id FROM session WHERE id IN ($in_clause) AND time_created > (strftime('%s','now')-${fresh_hours}*3600)*1000 AND EXISTS (SELECT 1 FROM message WHERE session_id=id) LIMIT 1;" \
		2>/dev/null)
}

# Delete session
delete_session() {
	local sid="$1"
	opencode session delete "$sid" >/dev/null 2>&1
}

# List all sessions with titles
list_sessions_with_titles() {
	opencode session list 2>/dev/null | awk '/^ses_/{id=$1; $1=""; sub(/^ +/,""); print id"\t"$0}' || true
}

# Probe History Queries ------------------------------------------------------

# Load probe history into associative arrays
load_probe_history() {
	local -n last_status=$1
	local -n fail_count=$2

	[[ -f "$OCM_STATE_DIR/probe-history.jsonl" ]] || return 0

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
	done <"$OCM_STATE_DIR/probe-history.jsonl"
}

# Record probe result to history
record_probe_history() {
	local model="$1" status="$2" latency_ms="$3"
	local ts
	ts=$(ms)
	jq -cn --argjson ts "$ts" --arg m "$model" --arg s "$status" --argjson l "$latency_ms" \
		'{ts:$ts,model:$m,status:$s,latency_ms:$l}' >>"$OCM_STATE_DIR/probe-history.jsonl"
	prune_jsonl "$OCM_STATE_DIR/probe-history.jsonl" "$OCM_HISTORY_LIMIT"
}

# Alert Queries ---------------------------------------------------------------

record_alert() {
	local severity="$1" type="$2" model="$3" message="$4"
	local ts
	ts=$(ms)
	jq -cn --arg ts "$ts" --arg sev "$severity" --arg type "$type" --arg m "$model" --arg msg "$message" \
		'{ts:$ts|tonumber, severity:$sev, type:$type, model:$m, message:$msg}' \
		>>"$OCM_STATE_DIR/alerts.jsonl"
	audit_log "ALERT[$severity] $type $model: $message"

	# Desktop notification for critical (non-batch)
	if [[ "$severity" == "CRITICAL" && "$OCM_BATCH_MODE" -ne 1 && "$OCM_DESKTOP_NOTIFICATIONS" -eq 1 ]]; then
		osascript -e 'on run {t, m}' -e 'display notification m with title t' -e 'end run' \
			"ocm" "$model: $message" >/dev/null 2>&1 || true
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
	if [[ -n "$OCM_WEBHOOK_URL" ]]; then
		if validate_webhook_url "$OCM_WEBHOOK_URL"; then
			curl -sS --max-time 10 -H 'Content-Type: application/json' \
				-d "$(jq -cn --arg sev "$severity" --arg type "$type" --arg m "$model" --arg msg "$message" \
					'{text:("["+$sev+"] "+$type+" "+$m+": "+$msg)}')" \
				"$OCM_WEBHOOK_URL" >/dev/null 2>&1 || true
		else
			log_warn "Invalid webhook URL configured, skipping webhook notification"
		fi
	fi

	prune_jsonl "$OCM_STATE_DIR/alerts.jsonl" "$OCM_ALERT_LIMIT"
}

# Graveyard Queries -----------------------------------------------------------

record_graveyard() {
	local model="$1"
	local ts
	ts=$(ms)
	printf '%s\t%s\n' "$ts" "$model" >>"$OCM_STATE_DIR/graveyard.jsonl"
	prune_jsonl "$OCM_STATE_DIR/graveyard.jsonl" 2000
}

get_active_graveyard() {
	local cutoff_ms
	cutoff_ms=$(python3 -c "import time;print(int((time.time()-${OCM_GRAVEYARD_COOLDOWN_HOURS}*3600)*1000))")

	[[ -f "$OCM_STATE_DIR/graveyard.jsonl" ]] || return 0

	awk -F'\t' -v c="$cutoff_ms" '
    NF >= 2 && $1 >= c { print $2 }
  ' "$OCM_STATE_DIR/graveyard.jsonl" 2>/dev/null | sort -u
}
