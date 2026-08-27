#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/locking.sh — Process locking with atomic operations
# ============================================================================

# Check if flock is available
_has_flock() {
  command -v flock >/dev/null 2>&1
}

# ---- Acquire Lock -----------------------------------------------------------
# Uses atomic file-based locking with flock if available, falls back to mkdir.
# Waits up to 20 seconds (100 * 0.2s).
acquire_lock() {
  local lock_dir="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
  local lock_file="${lock_dir}/lock"
  local waited=0

  # Try flock-based locking first (more robust)
  if _has_flock; then
    # Create lock directory if it doesn't exist
    mkdir -p "$lock_dir" 2>/dev/null || true
    
    # Use flock on a lock file. The fd must be remembered (not re-opened)
    # so release_lock can unlock the SAME open file description — flock
    # locks are per-fd, so unlocking a freshly-opened fd to the same path
    # is a no-op and leaves the original lock held.
    exec {_OCM_LOCK_FD}>"$lock_file"
    local waited_flock=0
    while ! flock -n "$_OCM_LOCK_FD"; do
      (( waited_flock++ >= 100 )) && {
        exec {_OCM_LOCK_FD}>&-
        unset _OCM_LOCK_FD
        die "Another ocm run holds the lock ($lock_dir)"
      }
      sleep 0.2
    done
    echo $$ > "$lock_file"
    echo $$ > "${lock_dir}/pid"
    log_debug "Acquired lock (flock): $lock_dir (PID: $$)"
    return 0
  fi

  # Fallback: mkdir-based locking with improved stale lock handling
  local lock_dir_base="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
  local waited=0

  while ! mkdir "$lock_dir_base" 2>/dev/null; do
    local pid_file="$lock_dir_base/pid"
    if [[ -f "$pid_file" ]]; then
      local pid
      pid=$(cat "$pid_file" 2>/dev/null || echo "")
      if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
        # Stale lock from dead process - attempt atomic removal
        # Use a unique temp name and atomic rename to avoid TOCTOU
        local temp_removed="${lock_dir_base}.removed.$$"
        if mv "$lock_dir_base" "$temp_removed" 2>/dev/null; then
          rm -rf "$temp_removed"
          continue
        fi
        # If mv failed, another process got there first - retry
        continue
      fi
    fi
    (( waited++ >= 100 )) && die "Another ocm run holds the lock ($lock_dir_base)"
    sleep 0.2
  done

  echo $$ > "$lock_dir_base/pid"
  log_debug "Acquired lock (mkdir): $lock_dir_base (PID: $$)"
}

# ---- Release Lock -----------------------------------------------------------
release_lock() {
  local lock_dir="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
  
  # Try flock-based release first
  if _has_flock; then
    local lock_file="${lock_dir}/lock"
    if [[ -f "$lock_file" ]]; then
      # Read ownership BEFORE opening the fd — opening with '>' below
      # truncates the file, so the PID must be captured first or the
      # ownership check always sees an empty/stale value.
      local locked_pid
      locked_pid=$(cat "${lock_dir}/pid" 2>/dev/null || echo "")
      if [[ -n "${_OCM_LOCK_FD:-}" ]]; then
        flock -u "$_OCM_LOCK_FD" 2>/dev/null || true
        exec {_OCM_LOCK_FD}>&-
        unset _OCM_LOCK_FD
      fi
      # Only remove if we own the lock
      if [[ "$locked_pid" == "$$" ]]; then
        rm -f "$lock_file" "${lock_dir}/pid" 2>/dev/null
        rmdir "$lock_dir" 2>/dev/null || true
        log_debug "Released lock (flock): $lock_dir"
      fi
    fi
    return 0
  fi

  # Fallback: mkdir-based release
  local lock_dir_base="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
  if [[ -d "$lock_dir_base" ]]; then
    local locked_pid
    locked_pid=$(cat "$lock_dir_base/pid" 2>/dev/null || echo "")
    if [[ "$locked_pid" == "$$" ]]; then
      rm -rf "$lock_dir_base"
      log_debug "Released lock (mkdir): $lock_dir_base"
    fi
  fi
}

# ---- Lock Status ------------------------------------------------------------
lock_status() {
  local lock_dir="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
  
  if _has_flock; then
    local lock_file="${lock_dir}/lock"
    if [[ -f "$lock_file" ]]; then
      local pid
      pid=$(cat "$lock_file" 2>/dev/null || echo "unknown")
      if kill -0 "$pid" 2>/dev/null; then
        echo "HELD by PID $pid"
      else
        echo "STALE (PID $pid dead)"
      fi
    else
      echo "FREE"
    fi
  else
    local lock_dir_base="${OCM_LOCK_DIR:-$OCM_STATE_DIR/.lock}"
    if [[ -d "$lock_dir_base" ]]; then
      local pid
      pid=$(cat "$lock_dir_base/pid" 2>/dev/null || echo "unknown")
      if kill -0 "$pid" 2>/dev/null; then
        echo "HELD by PID $pid"
      else
        echo "STALE (PID $pid dead)"
      fi
    else
      echo "FREE"
    fi
  fi
}