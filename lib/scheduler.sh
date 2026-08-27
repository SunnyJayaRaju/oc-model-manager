#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/scheduler.sh — Launchd/systemd scheduler management
# ============================================================================

# ---- Launchd (macOS) --------------------------------------------------------
launchd_plist_path() {
  echo "$HOME/Library/LaunchAgents/com.ocm.watch.plist"
}

launchd_install() {
  local plist
  plist=$(launchd_plist_path)
  mkdir -p "$(dirname "$plist")"

  local bash_path oc_path homebrew_path
  bash_path=$(command -v bash)
  oc_path=$(command -v opencode)
  homebrew_path=""

  [[ "$(dirname "$oc_path")" != "/usr/bin" ]] && homebrew_path="$(dirname "$oc_path"):"
  [[ -d /opt/homebrew/bin ]] && homebrew_path="${homebrew_path}/opt/homebrew/bin:"
  homebrew_path="${homebrew_path}/usr/local/bin:"

  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.ocm.watch</string>
  <key>ProgramArguments</key><array>
    <string>${bash_path}</string><string>${OCM_ROOT}/bin/ocm</string><string>check</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>${homebrew_path}/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>StartInterval</key><integer>${OCM_WATCH_SECS}</integer>
  <key>RunAtLoad</key><false/>
  <key>StandardOutPath</key><string>${OCM_STATE_DIR}/scheduler.log</string>
  <key>StandardErrorPath</key><string>${OCM_STATE_DIR}/scheduler.log</string>
</dict></plist>
EOF

  launchctl unload "$plist" 2>/dev/null || true
  launchctl load "$plist" && log_info "installed: check+alert every $((OCM_WATCH_SECS/3600))h — logs: ${OCM_STATE_DIR}/scheduler.log"
  log_info "note: alerts appear via 'ocm alerts' (+desktop ping on CRITICAL). Apply remains manual."
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
    launchctl list | grep -q com.ocm.watch && echo "INSTALLED (running)" || echo "INSTALLED (not running)"
  else
    echo "NOT INSTALLED"
  fi
}

# ---- Systemd (Linux) --------------------------------------------------------
systemd_unit_path() {
  echo "$HOME/.config/systemd/user/ocm-watch.service"
}

systemd_timer_path() {
  echo "$HOME/.config/systemd/user/ocm-watch.timer"
}

systemd_install() {
  local unit_path timer_path
  unit_path=$(systemd_unit_path)
  timer_path=$(systemd_timer_path)

  mkdir -p "$(dirname "$unit_path")"

  cat > "$unit_path" <<EOF
[Unit]
Description=ocm model catalog watcher
After=network.target

[Service]
Type=oneshot
ExecStart=${OCM_ROOT}/bin/ocm check
Environment=HOME=${HOME}
Environment=PATH=/usr/local/bin:/usr/bin:/bin
StandardOutput=append:${OCM_STATE_DIR}/scheduler.log
StandardError=append:${OCM_STATE_DIR}/scheduler.log
EOF

  cat > "$timer_path" <<EOF
[Unit]
Description=Run ocm check every ${OCM_WATCH_SECS} seconds

[Timer]
OnBootSec=5min
OnUnitActiveSec=${OCM_WATCH_SECS}
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now ocm-watch.timer
  log_info "installed systemd timer: check every $((OCM_WATCH_SECS/60)) min"
}

systemd_uninstall() {
  systemctl --user disable --now ocm-watch.timer 2>/dev/null || true
  rm -f "$(systemd_unit_path)" "$(systemd_timer_path)"
  systemctl --user daemon-reload
  log_info "systemd scheduler removed."
}

systemd_status() {
  if [[ -f "$(systemd_unit_path)" ]]; then
    systemctl --user is-enabled ocm-watch.timer >/dev/null 2>&1 && echo "INSTALLED (enabled)" || echo "INSTALLED (disabled)"
  else
    echo "NOT INSTALLED"
  fi
}

# ---- Cross-platform ---------------------------------------------------------
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "launchd" ;;
    Linux)  echo "systemd" ;;
    *)      echo "unknown" ;;
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
        *) log_error "Unsupported platform for scheduler"; return 1 ;;
      esac
      ;;
    uninstall)
      case "$(detect_platform)" in
        launchd) launchd_uninstall ;;
        systemd) systemd_uninstall ;;
        *) log_error "Unsupported platform for scheduler"; return 1 ;;
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
      echo "Usage: ocm scheduler [install|uninstall|status]"
      return 1
      ;;
  esac
}