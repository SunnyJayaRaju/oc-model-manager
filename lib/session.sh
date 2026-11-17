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
	if oc_db_is_v2; then
		# OpenCode 2.x reads only session_v2 rows; message counts come from
		# session_message. Legacy rows on a 2.x database are invisible to the
		# UI, so listing them would only confuse.
		sqlite3 -readonly "$OCPROBE_OPencode_DB" \
			"SELECT s.id, s.title, (SELECT COUNT(*) FROM session_message m WHERE m.session_id=s.id) AS msgs, datetime(s.time_updated/1000,'unixepoch','localtime') FROM session_v2 s ORDER BY s.time_updated DESC;"
	else
		sqlite3 -readonly "$OCPROBE_OPencode_DB" \
			"SELECT s.id, s.title, (SELECT COUNT(*) FROM message m WHERE m.session_id=s.id) AS msgs, datetime(s.time_updated/1000,'unixepoch','localtime') FROM session s ORDER BY s.time_updated DESC;"
	fi
}

# ---- In-place sed variant ----------------------------------------------------
# `sed -i` takes a MANDATORY suffix argument on BSD/macOS (`sed -i ''`) and an
# OPTIONAL, attached one on GNU (`sed -i`, or `sed -i.bak`). So the BSD form
# `sed -i '' 'script' file` is parsed by GNU as: script='', then FILES
# 'script' and 'file' — the real substitution never runs, and the command only
# "works" because the bogus filename makes it exit non-zero and fall through to
# the GNU form. That is fragile: correctness depends on the first invocation
# FAILING, and if it ever returned 0 the edit would be silently skipped, leaving
# a non-idempotent restore.
# Detect the variant once and always invoke the correct form.
if sed --version >/dev/null 2>&1; then
	OCPROBE_SED_INPLACE=(sed -i) # GNU
else
	OCPROBE_SED_INPLACE=(sed -i '') # BSD / macOS
fi

# ---- Backup Session ---------------------------------------------------------
# On OpenCode 2.x the backup is OpenCode's own export (a JSON document its
# import understands), never a SQL INSERT dump: the 2.x UI reads only
# session_v2 rows, so SQL inserts into the legacy tables would be invisible
# to it. On 1.x the SQL dump path stays exactly as it was.
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

	if oc_db_is_v2; then
		local srv="${OCPROBE_OPENCODE_SERVER:-}"
		if [[ -z "$srv" ]]; then
			# `opencode session export` without --server may connect to a
			# different background service than the database the operator is
			# looking at, so the export could silently hold the wrong rows.
			# Require the server explicitly, exactly like restore.
			log_error "backing up on OpenCode 2.x requires the server that owns this database: set OCPROBE_OPENCODE_SERVER=<url> (e.g. http://127.0.0.1:4096) and re-run"
			return 1
		fi
		local out
		out="$backup_dir/${sid}-$(date +%Y%m%d-%H%M%S).json"
		if ! opencode session export "$sid" --server "$srv" >"$out"; then
			log_error "export failed for $sid (is OCPROBE_OPENCODE_SERVER serving this database?)"
			rm -f "$out"
			return 1
		fi
		if ! grep -q "\"$sid\"" "$out"; then
			log_error "export for $sid does not contain the session (wrong server or missing session)"
			rm -f "$out"
			return 1
		fi
		log_info "backed up $sid -> $out (OpenCode export, $(wc -c <"$out" | tr -d ' ') bytes)"
		echo "$out"
		return 0
	fi

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
	"${OCPROBE_SED_INPLACE[@]}" 's/^INSERT INTO /INSERT OR REPLACE INTO /' "$out"

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

	# OpenCode 2.x: restore runs through OpenCode's own import, which writes
	# through a server — this machine's database file is never touched
	# directly. The server must be given explicitly (OCPROBE_OPENCODE_SERVER),
	# because importing through the wrong server would write the session into
	# a different database than the one the operator is looking at. A legacy
	# .sql dump is refused: the 2.x UI never reads rows inserted into the
	# legacy tables.
	if oc_db_is_v2; then
		case "$file" in
			*.sql)
				log_error "refusing to restore $file on OpenCode 2.x: .sql dumps are the 1.x format; the 2.x UI never reads rows inserted into the legacy tables"
				return 1
				;;
		esac
		local srv="${OCPROBE_OPENCODE_SERVER:-}"
		if [[ -z "$srv" ]]; then
			log_error "restoring on OpenCode 2.x requires the server that owns this database: set OCPROBE_OPENCODE_SERVER=<url> (e.g. http://127.0.0.1:4096) and re-run"
			return 1
		fi
		if ! opencode session import "$file" --server "$srv"; then
			log_error "import failed — this machine's database file was not touched"
			return 1
		fi
		log_info "restored from $file (imported through $srv)"
		return 0
	fi

	# Back up the live database BEFORE writing to it. backup_opencode_config()
	# backs up opencode.json (and cmd_session does not source validate.sh), so use
	# SQLite's online backup for the session DB itself. .backup exits non-zero on
	# failure, so an unbacked database aborts the restore. This must stay ahead of
	# the enforcement block below: if the backup cannot be taken, nothing may be
	# written at all.
	local backup_dir="${OCPROBE_SESSION_BACKUP_DIR:-$HOME/.local/share/opencode/session-backups}"
	backup_dir="${backup_dir/#\~/$HOME}"
	mkdir -p "$backup_dir" || {
		log_error "cannot create backup directory: $backup_dir"
		return 1
	}
	local db_backup
	db_backup="$backup_dir/opencode.db.pre-restore-$(date +%Y%m%d-%H%M%S)"
	if ! sqlite3 "$OCPROBE_OPencode_DB" ".backup '$db_backup'"; then
		log_error "could not back up database to $db_backup — refusing to restore"
		return 1
	fi
	log_info "database backed up to $db_backup"

	# Statement-level enforcement. The policy lives in lib/session_restore.py
	# rather than inline here, because the set of SQL function names SQLite
	# reports is build-dependent and a missing one only shows up on a platform you
	# are not developing on: the ubuntu runner reports a SQLITE_FUNCTION callback
	# for the conflict target of INSERT OR REPLACE ("replace"), which sqlite 3.54
	# on macOS does not report at all. An allowlist of just {"unistr"} therefore
	# passed every local test and the macOS CI leg while breaking restore for
	# every Linux user. See that module for the allowlist and its reasoning.
	#
	# It allows only:
	#   - SQLITE_INSERT on the four tables `cmd_session_backup` actually emits
	#   - SQLITE_TRANSACTION, so the module owns BEGIN IMMEDIATE / COMMIT
	#   - SQLITE_FUNCTION for the few pure string helpers a genuine dump contains
	# and denies everything else: ATTACH/DETACH, DROP/DELETE/UPDATE/ALTER, any
	# CREATE (which surfaces as an INSERT into sqlite_master, so the table
	# allowlist rejects it), every PRAGMA, every other function, and all reads
	# (SQLITE_READ / SQLITE_SELECT, so INSERT..SELECT cannot copy out of
	# sqlite_master or any other table).
	#
	# Statements are split with sqlite3.complete_statement() so a value spanning
	# lines still restores -- and which shape a dump uses for a newline is
	# sqlite-build dependent -- and each runs through execute() rather than
	# executescript(), which would commit implicitly and defeat the rollback.
	# The whole file is one transaction: any denial, parse error or exception rolls
	# it all back, so a rejected restore leaves the database byte-identical.
	#
	# This must stay AFTER the pre-restore backup above: if the backup cannot be
	# taken, nothing may be written at all.
	local restore_rc=0
	# -B: never write a __pycache__ next to the module. The installed lib
	# directory is read-only for a Homebrew install, and CPython's attempt to
	# cache there would either fail the restore or litter the install tree.
	python3 -B "${BASH_SOURCE%/*}/session_restore.py" "$OCPROBE_OPencode_DB" "$file" || restore_rc=$?

	if ((restore_rc != 0)); then
		log_error "restore refused: $file was rejected (see the error above) — nothing committed; backup kept at $db_backup"
		log_error "  only INSERT statements into: session, message, part, todo are permitted"
		return 1
	fi
	log_info "restored from $file"
}

# ---- Cleanup Probe Sessions (standalone) -----------------------------------
# Dry-run by default: prints what would be deleted and changes nothing.
# `--apply` performs the deletes; any delete failure makes the command exit
# non-zero. Sessions younger than 15 minutes are never listed: they may be
# mid-probe in a concurrent run.
cmd_session_cleanup() {
	local apply_mode=0
	case "${1:-}" in
		--apply | -y) apply_mode=1 ;;
		"") ;;
		*)
			log_error "usage: ocprobe session cleanup [--apply]"
			return 1
			;;
	esac

	load_config
	acquire_lock
	trap 'release_lock' EXIT INT TERM

	if ((apply_mode)); then
		log_info "Cleaning probe sessions (probe + validate)..."
	else
		log_info "DRY-RUN: probe sessions that would be deleted (pass --apply to delete them):"
	fi

	local deleted=0 failed=0 sid table
	if oc_db_is_v2; then table=session_v2; else table=session; fi
	# Reuse the DB-backed listing rather than `opencode session list`, which
	# paginates at 100 rows — on a large run the CLI view hides most of the
	# sessions the run just created, so cleanup deleted only what it could see
	# and leaked the rest. This is the same helper the main cleanup path in
	# lib/models.sh uses.
	#
	# Pass 0 for since_ms so the listing is bounded by the age guard in SQL and
	# by the freshness check below, rather than by one run's start time: this
	# subcommand can be invoked at any point, including well after a run.
	# list_probe_sessions_since also matches all three title prefixes in SQL
	# (ocprobe-probe*, ocmm-probe*, ocprobe-validate*) — the validate prefix was
	# previously missing here, so validate sessions were never cleaned. No
	# title re-check is needed in this loop: delete_session below independently
	# re-validates the id format and the title before removing anything.
	# The title is not needed here: list_probe_sessions_since already filtered
	# on all three prefixes in SQL, and delete_session re-validates the title
	# before removing anything. Read it into _ so the tab-delimited line parses.
	while IFS=$'\t' read -r sid _; do
		[[ -n "$sid" ]] || continue
		local sid_esc
		sid_esc=$(sql_escape "$sid") || continue
		# Only delete fresh probe sessions, using the configured fresh guard
		# rather than a hardcoded hour, and never sessions younger than 15
		# minutes (by time_updated): they may be mid-probe in a concurrent run.
		if sqlite3 -readonly "$OCPROBE_OPencode_DB" \
			"SELECT 1 FROM ${table} WHERE id='${sid_esc}' AND time_created > (strftime('%s','now')-${OCPROBE_FRESH_GUARD_HOURS}*3600)*1000 AND time_updated <= (strftime('%s','now')-15*60)*1000 LIMIT 1;" 2>/dev/null | grep -q 1; then
			if ((apply_mode)); then
				if delete_session "$sid"; then
					deleted=$((deleted + 1))
					log_info "deleted probe session $sid"
				else
					failed=$((failed + 1))
					log_error "could not delete probe session $sid"
				fi
			else
				deleted=$((deleted + 1))
				log_info "  would delete: $sid"
			fi
		fi
	done < <(list_probe_sessions_since 0)

	if ((apply_mode)); then
		log_info "cleaned $deleted probe session(s)"
		((failed == 0)) || return 1
	else
		log_info "dry-run complete: $deleted probe session(s) would be deleted; nothing was changed"
	fi
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
