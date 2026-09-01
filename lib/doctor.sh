#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/doctor.sh — Health checks
# ============================================================================

cmd_doctor() {
	load_config
	local all_ok=1

	echo "=== ocprobe doctor ==="
	echo

	# 1. opencode binary
	if command -v opencode >/dev/null; then
		local oc_version
		oc_version=$(opencode --version 2>/dev/null || echo "unknown")
		log_info "opencode: OK ($oc_version)"
	else
		log_error "opencode: NOT FOUND in PATH"
		all_ok=0
	fi

	# 2. Python 3
	if command -v python3 >/dev/null; then
		local py_version
		py_version=$(python3 --version 2>&1)
		log_info "python3: OK ($py_version)"
	else
		log_error "python3: NOT FOUND"
		all_ok=0
	fi

	# 3. jq
	if command -v jq >/dev/null; then
		log_info "jq: OK"
	else
		log_error "jq: NOT FOUND"
		all_ok=0
	fi

	# 4. sqlite3
	if command -v sqlite3 >/dev/null; then
		log_info "sqlite3: OK"
	else
		log_error "sqlite3: NOT FOUND"
		all_ok=0
	fi

	# 5. Config file
	if [[ -f "$OCPROBE_CONFIG_FILE" ]]; then
		log_info "config: OK ($OCPROBE_CONFIG_FILE)"
		# Validate
		if validate_config "$OCPROBE_CONFIG_FILE" >/dev/null 2>&1; then
			log_info "config validation: OK"
		else
			log_error "config validation: FAILED"
			all_ok=0
		fi
	else
		log_warn "config: NOT FOUND (will create default at $OCPROBE_CONFIG_FILE)"
	fi

	# 6. opencode config
	if [[ -f "$OCPROBE_OPencode_CONFIG" ]]; then
		log_info "opencode config: OK ($OCPROBE_OPencode_CONFIG)"
	else
		log_error "opencode config: NOT FOUND ($OCPROBE_OPencode_CONFIG)"
		all_ok=0
	fi

	# 7. opencode DB
	if [[ -f "$OCPROBE_OPencode_DB" ]]; then
		log_info "opencode DB: OK ($OCPROBE_OPencode_DB)"
		# Check DB integrity
		if sqlite3 -readonly "$OCPROBE_OPencode_DB" "PRAGMA integrity_check;" 2>/dev/null | grep -q "ok"; then
			log_info "DB integrity: OK"
		else
			log_warn "DB integrity: CHECK FAILED"
		fi
	else
		log_error "opencode DB: NOT FOUND ($OCPROBE_OPencode_DB)"
		all_ok=0
	fi

	# 8. State directory
	if [[ -d "$OCPROBE_STATE_DIR" && -w "$OCPROBE_STATE_DIR" ]]; then
		log_info "state dir: OK ($OCPROBE_STATE_DIR)"
	else
		log_warn "state dir: NOT ACCESSIBLE ($OCPROBE_STATE_DIR)"
	fi

	# 9. Disk space
	local disk_avail
	disk_avail=$(df -h "$OCPROBE_STATE_DIR" | awk 'NR==2 {print $4}')
	log_info "disk space: $disk_avail available"

	# 10. opencode auth (try a simple models call)
	if opencode models >/dev/null 2>&1; then
		log_info "opencode auth: OK"
	else
		log_warn "opencode auth: MAY NEED REFRESH (opencode models failed)"
	fi

	# 11. Scheduler status
	echo
	echo "--- Scheduler ---"
	# OCPROBE_LIB_DIR is set by the binary bootstrap; fall back to relative path
	# when called directly (e.g., in tests) where bootstrap hasn't run.
	local lib_dir="${OCPROBE_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
	# shellcheck source=./scheduler.sh
	source "${lib_dir}/scheduler.sh"
	cmd_scheduler status

	# 12. State files
	echo
	echo "--- State ---"
	[[ -f "$OCPROBE_STATE_DIR/probe-history.jsonl" ]] && echo "probe-history: $(wc -l <"$OCPROBE_STATE_DIR/probe-history.jsonl") entries" || echo "probe-history: none"
	[[ -f "$OCPROBE_STATE_DIR/alerts.jsonl" ]] && echo "alerts: $(wc -l <"$OCPROBE_STATE_DIR/alerts.jsonl") entries" || echo "alerts: none"
	[[ -f "$OCPROBE_STATE_DIR/graveyard.jsonl" ]] && echo "graveyard: $(wc -l <"$OCPROBE_STATE_DIR/graveyard.jsonl") entries" || echo "graveyard: none"
	[[ -f "$OCPROBE_STATE_DIR/catalog-cache.json" ]] && echo "catalog-cache: $(jq '.models|length' "$OCPROBE_STATE_DIR/catalog-cache.json" 2>/dev/null || echo "corrupt") models" || echo "catalog-cache: none"

	echo
	if [[ $all_ok -eq 1 ]]; then
		log_info "All checks passed"
		exit 0
	else
		log_error "Some checks failed"
		exit 1
	fi
}
