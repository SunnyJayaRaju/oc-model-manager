#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2155
# ============================================================================
# lib/session.sh — Session management (list, backup, restore, cleanup)
# ============================================================================

# ---- List Sessions ----------------------------------------------------------
cmd_session_list() {
	load_config
	sqlite3 -readonly "$OCPROBE_OPencode_DB" \
		"SELECT s.id, s.title, (SELECT COUNT(*) FROM message m WHERE m.session_id=s.id) AS msgs, datetime(s.time_updated/1000,'unixepoch','localtime') FROM session s ORDER BY s.time_updated DESC;"
}

# ---- Backup Session ---------------------------------------------------------
cmd_session_backup() {
	local sid="${1:-}"
	[[ -n "$sid" ]] || {
		log_error "usage: ocprobe session backup <session_id>"
		return 1
	}

	load_config
	[[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || {
		log_error "bad session id: $sid"
		return 1
	}

	local backup_dir="${OCPROBE_SESSION_BACKUP_DIR:-$HOME/.local/share/opencode/session-backups}"
	backup_dir="${backup_dir/#\~/$HOME}"
	mkdir -p "$backup_dir"

	local out
	out="$backup_dir/${sid}-$(date +%Y%m%d-%H%M%S).sql"
	local sql_sid
	sql_sid=$(sql_escape "$sid") || {
		log_error "invalid session id for SQL: $sid"
		return 1
	}

	sqlite3 -readonly "$OCPROBE_OPencode_DB" >"$out" <<EOF
.mode insert session
SELECT * FROM session WHERE id='$sql_sid';
.mode insert message
SELECT * FROM message WHERE session_id='$sql_sid' ORDER BY time_created;
.mode insert part
SELECT * FROM part WHERE session_id='$sql_sid' ORDER BY time_created;
.mode insert todo
SELECT * FROM todo WHERE session_id='$sql_sid';
EOF

	# Use INSERT OR REPLACE for idempotent restore
	sed -i '' 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$out" 2>/dev/null || sed -i 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$out"

	local msgs parts
	msgs=$(grep -c "INSERT OR REPLACE INTO message" "$out" || true)
	parts=$(grep -c "INSERT OR REPLACE INTO part" "$out" || true)

	log_info "backed up $sid -> $out ($msgs msgs, $parts parts)"
	echo "$out"
}

# ---- Restore Session --------------------------------------------------------
cmd_session_restore() {
	local file="${1:-}"
	[[ -n "$file" ]] || {
		log_error "usage: ocprobe session restore <file.sql>"
		return 1
	}
	[[ -f "$file" ]] || {
		log_error "no such file: $file"
		return 1
	}

	load_config
	{
		echo "PRAGMA busy_timeout=10000;"
		echo "BEGIN IMMEDIATE;"
		cat "$file"
		echo "COMMIT;"
	} | sqlite3 "$OCPROBE_OPencode_DB"

	log_info "restored from $file"
}

# ---- Cleanup Probe Sessions (standalone) -----------------------------------
cmd_session_cleanup() {
	load_config
	acquire_lock
	trap 'release_lock' EXIT INT TERM

	log_info "Cleaning probe sessions (ocprobe-probe)..."

	local deleted=0
	while IFS=$'\t' read -r sid title; do
		[[ -n "$sid" && ("$title" == ${OCPROBE_PROBE_TITLE_PREFIX}* || "$title" == ${OCPROBE_PROBE_TITLE_PREFIX_LEGACY}*) ]] || continue
		local sid_esc
		sid_esc=$(sql_escape "$sid") || continue
		# Only delete fresh (<1h) probe sessions
		if sqlite3 -readonly "$OCPROBE_OPencode_DB" \
			"SELECT 1 FROM session WHERE id='${sid_esc}' AND time_created > (strftime('%s','now')-3600)*1000 LIMIT 1;" 2>/dev/null | grep -q 1; then
			delete_session "$sid" && {
				deleted=$((deleted + 1))
				log_info "deleted probe session $sid"
			}
		fi
	done < <(list_sessions_with_titles)

	log_info "cleaned $deleted probe session(s)"
}

# ---- Command Dispatcher -----------------------------------------------------
cmd_session() {
	local subcmd="${1:-list}"
	shift || true

	case "$subcmd" in
	list) cmd_session_list "$@" ;;
	backup) cmd_session_backup "$@" ;;
	restore) cmd_session_restore "$@" ;;
	cleanup) cmd_session_cleanup "$@" ;;
	*)
		log_error "Unknown session command: $subcmd"
		echo "Usage: ocprobe session [list|backup|restore|cleanup]"
		return 1
		;;
	esac
}
