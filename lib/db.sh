#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/db.sh — SQLite database operations
# ============================================================================

# ---- Session Queries --------------------------------------------------------

# True when the managed database has the OpenCode 2.x session schema
# (session_v2 + session_message + session_part). Session code branches on
# this: on a 2.x database the live rows are in session_v2, on a 1.x database
# in session. A missing or unreadable database answers "no" (legacy), so a
# caller that only reads keeps working; the file checks still guard writes.
oc_db_is_v2() {
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    sqlite3 -readonly "$OCPROBE_OPencode_DB" \
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_v2' LIMIT 1;" \
        2>/dev/null | grep -q 1
}

# ---- Bound-parameter SQL runner (OpenCode 2.x paths) ------------------------
# Every 2.x session query runs through this instead of string-interpolated
# `sqlite3 -readonly` SQL: values reach SQL as bound parameters (argv via jq
# as JSON on stdin) and the database is opened read-only by lib/db_query.py,
# so a session id can never change the shape of a query, whatever it contains.
# The legacy 1.x path keeps sql_escape; both carry the same adversarial tests.
#
# Usage: _oc_db_query <sql> [param ...]
# Prints rows, columns tab-separated (NULL prints empty). Returns non-zero
# when the database is missing, no python3 exists, or the query fails.
# Note: bash cannot pass an embedded NUL byte through an argument list, so a
# parameter holding one arrives truncated - a lookup with such a value simply
# matches no row (no stored id can contain one; delete_session's format gate
# rejects it first anyway).
_oc_db_query() {
    local sql="$1"
    shift
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    local py
    py=$(oc_python) || return 1
    local params
    params=$(jq -cn --args '$ARGS.positional' -- "$@") || return 1
    printf '%s\n' "$params" | "$py" -B "${BASH_SOURCE%/*}/db_query.py" "$OCPROBE_OPencode_DB" "$sql"
}

# Get session age in milliseconds
session_age_ms() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1

    local age_ms
    if oc_db_is_v2; then
        # Bound parameters on every 2.x path; the table is the fixed 2.x name.
        age_ms=$(_oc_db_query \
            "SELECT (strftime('%s','now')*1000) - time_created FROM session_v2 WHERE id = ? LIMIT 1;" \
            "$sid") || return 1
    else
        local sid_escaped
        sid_escaped=$(sql_escape "$sid") || return 1
        age_ms=$(sqlite3 -readonly "$OCPROBE_OPencode_DB" \
            "SELECT (strftime('%s','now')*1000) - time_created FROM session WHERE id='${sid_escaped}' LIMIT 1;" \
            2>/dev/null) || return 1
    fi

    [[ -n "$age_ms" ]] || return 1
    echo "$age_ms"
}

# True when <sid> also has a row in the LEGACY session table. On a 2.x
# database a CLI delete removes only the v2 row (verified on 2.3.0), so a
# session backed by a legacy row can only be hidden, never removed — the
# guarded delete must refuse those ids. On 1.x the legacy table IS the live
# one and this gate must not apply. A missing legacy table answers "no".
session_has_legacy_row() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    local hit
    hit=$(_oc_db_query "SELECT 1 FROM session WHERE id = ? LIMIT 1;" "$sid") || return 1
    [[ -n "$hit" ]]
}

# True when <sid> sits in a session tree: it has a parent, or another session
# names it as parent. Tree members are deleted whole through OpenCode, never
# one row at a time. Only meaningful on a 2.x database (the legacy table has
# the same parent_id column, but the CLI delete there removes the real row).
session_in_tree() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    local hit
    hit=$(_oc_db_query \
        "SELECT 1 FROM session_v2 WHERE parent_id = ? OR (id = ? AND parent_id IS NOT NULL) LIMIT 1;" \
        "$sid" "$sid") || return 1
    [[ -n "$hit" ]]
}

# True when <sid> contains tool calls. Probe sessions are pure text: one
# user prompt, one assistant answer. A tool call means a working session.
# Checked in the message JSON (where 2.3.0 stores content items of type
# "tool"; verified against real sessions) and in session_part (the schema
# keeps a typed part table even though 2.3.0 leaves it empty).
session_has_tool_calls() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    local hit
    hit=$(_oc_db_query \
        "SELECT 1 FROM session_message WHERE session_id = ? AND json_valid(data) AND EXISTS (SELECT 1 FROM json_each(data, '\$.content') WHERE json_extract(value, '\$.type') = 'tool') LIMIT 1;" \
        "$sid") && [[ -n "$hit" ]] && return 0
    hit=$(_oc_db_query "SELECT 1 FROM session_part WHERE session_id = ? AND type = 'tool' LIMIT 1;" "$sid") || return 1
    [[ -n "$hit" ]]
}

# Text of the first user message of <sid> (empty when there is none or it
# does not parse). The exact probe-prompt match in delete_session compares
# this against the configured probe prompts.
session_first_user_text() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    _oc_db_query \
        "SELECT COALESCE(json_extract(data, '\$.text'), '') FROM session_message WHERE session_id = ? AND type = 'user' AND json_valid(data) ORDER BY seq LIMIT 1;" \
        "$sid"
}

# Number of messages belonging to <sid> in the live table.
session_message_count() {
    local sid="$1"
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 1
    if oc_db_is_v2; then
        _oc_db_query \
            "SELECT (SELECT COUNT(*) FROM session_v2 WHERE id = ?) + (SELECT COUNT(*) FROM session_message WHERE session_id = ?);" \
            "$sid" "$sid"
    else
        local sid_esc
        sid_esc=$(sql_escape "$sid") || return 1
        sqlite3 -readonly "$OCPROBE_OPencode_DB" \
            "SELECT (SELECT COUNT(*) FROM session WHERE id='${sid_esc}') + (SELECT COUNT(*) FROM message WHERE session_id='${sid_esc}');" 2>/dev/null
    fi
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

    # R37: an id that is absent from this database is ALREADY CLEAN — there is
    # nothing to delete, and no CLI call is made, so returning success cannot
    # remove anything. The old refusal logged a false ERROR for every probe
    # whose session never persisted (measured 2026-11-18: a real
    # `ocprobe probe opencode/deepseek-v4.1-flash-free` run ended with
    # "refusing to delete ses_e121b7d0effe… — not present", while the session
    # count stayed at 40 before and after and no such row ever existed).
    if [[ -z "$row" ]]; then
        log_info "delete_session: $sid is not in this database — already clean, nothing to delete"
        return 0
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

    # (c) Generation gates. On a 2.x database a CLI delete removes only the
    # v2 row, so any of the conditions below makes a delete unsafe and the
    # session is left alone: a legacy row would survive as a ghost, a tree
    # member must be deleted whole, tool calls or a long conversation mean it
    # is a working session, and the first user message must be exactly a
    # probe prompt. On 1.x none of these apply (there is no session_v2).
    if oc_db_is_v2; then
        if session_has_legacy_row "$sid"; then
            log_error "delete_session: refusing to delete $sid — a legacy (v1) row also exists and a CLI delete would leave it behind"
            return 1
        fi
        if session_in_tree "$sid"; then
            log_error "delete_session: refusing to delete $sid — it has a parent or child session; delete the tree through OpenCode instead"
            return 1
        fi
        local first_text
        first_text=$(session_first_user_text "$sid")
        # R37: this tool's own validate probe is identified by the EXACT title
        # plus the EXACT configure prompt. On this harness the model can emit a
        # tool call or a few reasoning messages before answering "OK"; the
        # generic gates then refused and leaked one session per model (R35: 3
        # leaked; measured 2026-11-18: a 5-message validate session with 2 tool
        # calls sat undeleted for 3 hours). Own-probe identity is narrower than
        # the "ocprobe-probe" prefix, so the generic gates stay as they are.
        local validate_probe=0
        if [[ "$title" == "$validate_title_prefix" ]] &&
            [[ "$first_text" == "$OCPROBE_VALIDATE_PROBE_PROMPT" ]]; then
            validate_probe=1
        fi
        if ((validate_probe == 0)) && session_has_tool_calls "$sid"; then
            log_error "delete_session: refusing to delete $sid — it contains tool calls, so it is a working session, not a probe"
            return 1
        fi
        case "$first_text" in
            "$OCPROBE_PROBE_PROMPT" | "$OCPROBE_VALIDATE_PROBE_PROMPT") ;;
            *)
                log_error "delete_session: refusing to delete $sid — its first user message is not a configured probe prompt"
                return 1
                ;;
        esac
        # A validate probe runs in the live harness, so its message ceiling is
        # the runaway bound, not the generic 4-message probe bound. 100 is a
        # safety cap, not a measurement.
        local msg_count max_msgs
        msg_count=$(session_message_count "$sid")
        max_msgs="${OCPROBE_MAX_MSG_COUNT:-4}"
        ((validate_probe == 1)) && max_msgs=100
        if [[ "$msg_count" =~ ^[0-9]+$ ]] && ((msg_count > max_msgs)); then
            log_error "delete_session: refusing to delete $sid — $msg_count messages exceeds the probe message ceiling ($max_msgs)"
            return 1
        fi
    fi

    # (d) Delete through the CLI. The CLI's exit code and stderr are captured:
    # on failure the caller sees a short sanitised reason (the CLI's message
    # can name other sessions or filesystem paths — every id but this one,
    # whose shape gate (a) already validated, is masked, paths are masked,
    # and the line is capped) and the non-zero exit propagates.
    local rc=0 err
    err=$(opencode session delete "$sid" 2>&1) || rc=$?
    if ((rc != 0)); then
        local reason
        reason=$(printf '%s\n' "$err" | head -n 1 | sed -E \
            -e "s/${sid}/__SELF__/g" \
            -e 's/ses_[A-Za-z0-9_-]+/<id>/g' \
            -e "s/__SELF__/${sid}/g" \
            -e 's/(^|[[:space:]])\/[A-Za-z0-9_./@:+~-]+/\1<path>/g' | cut -c1-160)
        log_error "delete_session: opencode session delete failed for $sid (exit $rc): ${reason:-no message}"
        return 1
    fi
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
    if oc_db_is_v2; then
        _oc_db_query "SELECT id || char(9) || COALESCE(title, '') FROM session_v2 WHERE id = ? LIMIT 1;" "$sid"
    else
        local sid_esc
        sid_esc=$(sql_escape "$sid") || return 1
        sqlite3 -readonly "$OCPROBE_OPencode_DB" \
            "SELECT id || char(9) || COALESCE(title, '') FROM session WHERE id='${sid_esc}' LIMIT 1;" \
            2>/dev/null
    fi
}

# All session ids currently in the DB (complete, unpaginated).
# `opencode session list` caps at 100 rows, so it must not be used to build a
# safety baseline: on a busy history it silently omits pre-existing sessions.
list_all_session_ids() {
    [[ -f "$OCPROBE_OPencode_DB" ]] || return 0
    if oc_db_is_v2; then
        # Both tables: the safety baseline must cover v2 rows AND any legacy
        # ghosts still sitting in the old table.
        {
            sqlite3 -readonly "$OCPROBE_OPencode_DB" "SELECT id FROM session_v2;" 2>/dev/null || true
            sqlite3 -readonly "$OCPROBE_OPencode_DB" "SELECT id FROM session;" 2>/dev/null || true
        } | sort -u
    else
        sqlite3 -readonly "$OCPROBE_OPencode_DB" "SELECT id FROM session;" 2>/dev/null || true
    fi
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
    p1="${OCPROBE_PROBE_TITLE_PREFIX:-ocprobe-probe}"
    p2="${OCPROBE_PROBE_TITLE_PREFIX_LEGACY:-ocmm-probe}"
    # The validate worker titles its sessions "ocprobe-validate", which matched
    # neither prefix above — so validate runs deleted almost nothing and leaked a
    # session per probed model (842 observed). Keep all three in sync here.
    p3="${OCPROBE_VALIDATE_TITLE_PREFIX:-ocprobe-validate}"
    age_hours="${OCPROBE_AGE_GUARD_HOURS:-24}"
    max_msgs="${OCPROBE_MAX_MSG_COUNT:-4}"
    [[ "$age_hours" =~ ^[0-9]+$ ]] || age_hours=24
    [[ "$max_msgs" =~ ^[0-9]+$ ]] || max_msgs=4

    if oc_db_is_v2; then
        # OpenCode 2.x: live probe sessions are rows in session_v2; message
        # counts come from session_message. Every exclusion that makes a
        # delete unsafe (legacy row, session tree, tool calls, prompt
        # mismatch) is applied here so the candidate list only ever contains
        # rows delete_session would accept — delete_session still re-checks
        # all of them independently. Every value in the query (title
        # prefixes, probe prompts, the since bound, the age and message
        # ceilings) is a bound parameter; none of it is interpolated.
        local p4 p5
        p4="${OCPROBE_PROBE_PROMPT:-Reply with exactly: OK}"
        p5="${OCPROBE_VALIDATE_PROBE_PROMPT:-Reply with exactly: OK}"
        _oc_db_query "
SELECT s.id || char(9) || COALESCE(s.title, '')
FROM session_v2 s
WHERE s.time_created >= ?
  AND s.time_created >  (strftime('%s','now') - ? * 3600) * 1000
  AND (s.title LIKE ? || '%' OR s.title LIKE ? || '%' OR s.title LIKE ? || '%')
  AND (SELECT COALESCE(json_extract(m.data, '\$.text'), '') FROM session_message m
	   WHERE m.session_id = s.id AND m.type = 'user' AND json_valid(m.data)
	   ORDER BY m.seq LIMIT 1) IN (?, ?)
  AND s.parent_id IS NULL
  AND NOT EXISTS (SELECT 1 FROM session_v2 c WHERE c.parent_id = s.id)
  AND NOT EXISTS (SELECT 1 FROM session l WHERE l.id = s.id)
  -- R37: two candidate shapes. Generic probe: no tool calls, tiny. Our own
  -- validate probe (exact title + exact prompt): a live-harness model can
  -- emit tool calls and a few reasoning messages, and those sessions used to
  -- be filtered out here AND refused by delete_session, leaking forever.
  -- 100 is a runaway bound, not a measurement.
  AND (
        ( (SELECT COUNT(*) FROM session_message m WHERE m.session_id = s.id) <= ?
          AND NOT EXISTS (SELECT 1 FROM session_message m
                          WHERE m.session_id = s.id AND m.type = 'assistant' AND json_valid(m.data)
                            AND EXISTS (SELECT 1 FROM json_each(m.data, '\$.content')
                                        WHERE json_extract(value, '\$.type') = 'tool'))
          AND NOT EXISTS (SELECT 1 FROM session_part sp WHERE sp.session_id = s.id AND sp.type = 'tool') )
        OR
        ( s.title = ?
          AND (SELECT COALESCE(json_extract(m.data, '\$.text'), '') FROM session_message m
                 WHERE m.session_id = s.id AND m.type = 'user' AND json_valid(m.data)
                 ORDER BY m.seq LIMIT 1) = ?
          AND (SELECT COUNT(*) FROM session_message m WHERE m.session_id = s.id) <= 100 )
      )
ORDER BY s.time_created;" \
            "$since_ms" "$age_hours" "$p1" "$p2" "$p3" "$p4" "$p5" "$max_msgs" "$p3" "$p5"
        return 0
    fi

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

    # The old desktop notification called osascript, which sent Apple Events and
    # made macOS ask to control System Events/Finder. The alert log is the record.
    if [[ "$severity" == "CRITICAL" && "$OCPROBE_BATCH_MODE" -ne 1 && "$OCPROBE_DESKTOP_NOTIFICATIONS" -eq 1 ]]; then
        audit_log "NOTIFICATION suppressed (no Apple Events): $model: $message"
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
