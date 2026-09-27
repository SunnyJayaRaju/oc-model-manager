#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/scheduler.sh — Launchd/systemd scheduler management
# ============================================================================

# ---- Launchd (macOS) --------------------------------------------------------
launchd_plist_path() {
	echo "$HOME/Library/LaunchAgents/com.ocprobe.watch.plist"
}

launchd_install() {
	local plist
	plist=$(launchd_plist_path)
	mkdir -p "$(dirname "$plist")"

	local bash_path oc_path homebrew_path
	bash_path=$(command -v bash)
	# A launchd plist with an empty ProgramArguments entry can load but can never
	# run, and the failure only surfaces later in the scheduler log. Refuse to
	# write one at all rather than produce a silently broken schedule.
	if [[ -z "$bash_path" ]]; then
		log_error "could not locate bash on PATH — refusing to write a launchd plist with an empty ProgramArguments entry"
		return 1
	fi
	oc_path=$(command -v opencode)
	homebrew_path=""

	[[ "$(dirname "$oc_path")" != "/usr/bin" ]] && homebrew_path="$(dirname "$oc_path"):"
	[[ -d /opt/homebrew/bin ]] && homebrew_path="${homebrew_path}/opt/homebrew/bin:"
	homebrew_path="${homebrew_path}/usr/local/bin:"

	cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ocprobe.watch</string>
  <key>ProgramArguments</key><array>
    <string>${bash_path}</string><string>${OCPROBE_ROOT}/bin/ocprobe</string><string>check</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>${homebrew_path}/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>StartInterval</key><integer>${OCPROBE_WATCH_SECS}</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${OCPROBE_STATE_DIR}/scheduler.log</string>
  <key>StandardErrorPath</key><string>${OCPROBE_STATE_DIR}/scheduler.log</string>
</dict></plist>
EOF

	launchctl unload "$plist" 2>/dev/null || true

	# Check the exit status explicitly. `cmd && log_info ...` printed nothing at
	# all on failure, and the note below then implied the schedule was live.
	local load_out load_rc=0
	load_out=$(launchctl load "$plist" 2>&1) || load_rc=$?
	if [[ $load_rc -ne 0 ]]; then
		log_error "launchctl load failed (exit $load_rc) for $plist — the watch schedule is NOT installed"
		[[ -n "$load_out" ]] && log_error "  launchctl said: $load_out"
		return 1
	fi

	log_info "installed: check+alert every $((OCPROBE_WATCH_SECS / 3600))h — logs: ${OCPROBE_STATE_DIR}/scheduler.log"
	log_info "note: alerts appear via 'ocprobe alerts' (+desktop ping on CRITICAL). Apply remains manual."
	return 0
}

launchd_uninstall() {
	local plist
	plist=$(launchd_plist_path)
	launchctl unload "$plist" 2>/dev/null || true
	rm -f "$plist" && log_info "scheduler removed."
}

launchd_status() {
	local plist
	plist=$(launchd_plist_path)
	if [[ -f "$plist" ]]; then
		launchctl list | grep -q com.ocprobe.watch && echo "INSTALLED (running)" || echo "INSTALLED (not running)"
	else
		echo "NOT INSTALLED"
	fi
}

# ---- Systemd (Linux) --------------------------------------------------------
systemd_unit_path() {
	echo "$HOME/.config/systemd/user/ocprobe-watch.service"
}

systemd_timer_path() {
	echo "$HOME/.config/systemd/user/ocprobe-watch.timer"
}

systemd_install() {
	local unit_path timer_path
	unit_path=$(systemd_unit_path)
	timer_path=$(systemd_timer_path)

	mkdir -p "$(dirname "$unit_path")"

	cat >"$unit_path" <<EOF
[Unit]
Description=ocprobe model catalog watcher
After=network.target

[Service]
Type=oneshot
ExecStart=${OCPROBE_ROOT}/bin/ocprobe check
Environment=HOME=${HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
StandardOutput=append:${OCPROBE_STATE_DIR}/scheduler.log
StandardError=append:${OCPROBE_STATE_DIR}/scheduler.log
EOF

	cat >"$timer_path" <<EOF
[Unit]
Description=Run ocprobe check every ${OCPROBE_WATCH_SECS} seconds

[Timer]
OnBootSec=5min
OnUnitActiveSec=${OCPROBE_WATCH_SECS}
Persistent=true

[Install]
WantedBy=timers.target
EOF

	systemctl --user daemon-reload
	systemctl --user enable --now ocprobe-watch.timer
	log_info "installed systemd timer: check every $((OCPROBE_WATCH_SECS / 60)) min"
}

systemd_uninstall() {
	systemctl --user disable --now ocprobe-watch.timer 2>/dev/null || true
	rm -f "$(systemd_unit_path)" "$(systemd_timer_path)"
	systemctl --user daemon-reload
	log_info "systemd scheduler removed."
}

systemd_status() {
	if [[ -f "$(systemd_unit_path)" ]]; then
		systemctl --user is-enabled ocprobe-watch.timer >/dev/null 2>&1 && echo "INSTALLED (enabled)" || echo "INSTALLED (disabled)"
	else
		echo "NOT INSTALLED"
	fi
}

# ---- Cross-platform ---------------------------------------------------------
detect_platform() {
	case "$(uname -s)" in
	Darwin) echo "launchd" ;;
	Linux) echo "systemd" ;;
	*) echo "unknown" ;;
	esac
}

cmd_scheduler() {
	local subcmd="${1:-status}"
	shift || true

	load_config

	case "$subcmd" in
	install)
		case "$(detect_platform)" in
		launchd) launchd_install ;;
		systemd) systemd_install ;;
		*)
			log_error "Unsupported platform for scheduler"
			return 1
			;;
		esac
		;;
	uninstall)
		case "$(detect_platform)" in
		launchd) launchd_uninstall ;;
		systemd) systemd_uninstall ;;
		*)
			log_error "Unsupported platform for scheduler"
			return 1
			;;
		esac
		;;
	status)
		case "$(detect_platform)" in
		launchd) launchd_status ;;
		systemd) systemd_status ;;
		*) echo "UNKNOWN PLATFORM" ;;
		esac
		;;
	*)
		log_error "Unknown scheduler command: $subcmd"
		echo "Usage: ocprobe scheduler [install|uninstall|status]"
		return 1
		;;
	esac
}
