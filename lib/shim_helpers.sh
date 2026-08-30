#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# lib/shim_helpers.sh — Shared helpers for backward compatibility shims
# ============================================================================

# Map old command names to new ocprobe subcommands
# Usage: map_old_command "old_command"
map_old_command() {
  local old_cmd="$1"
  case "$old_cmd" in
    install-scheduler) echo "scheduler install" ;;
    uninstall-scheduler) echo "scheduler uninstall" ;;
    *) echo "$old_cmd" ;;
  esac
}

# Map old flags to new ocprobe global flags
# Usage: map_old_flags "$@"
map_old_flags() {
  local args=()
  for arg in "$@"; do
    case "$arg" in
      --quick) args+=("--quick") ;;
      --force-refresh) args+=("--force-refresh") ;;
      --yes|-y) args+=("--yes") ;;
      --help|-h) args+=("help") ;;
      *) args+=("$arg") ;;
    esac
  done
  printf '%s\n' "${args[@]}"
}

# Handle special command combinations
# Usage: handle_special_cases mapped_args
handle_special_cases() {
  local args=("$@")
  if [[ "${args[0]:-}" == "alerts" && "${args[1]:-}" == "--clear" ]]; then
    printf '%s\n' "alerts" "--clear"
    return 0
  fi
  printf '%s\n' "${args[@]}"
}

# Main shim entry point
# Usage: run_shim old_program_name "$@"
run_shim() {
  local _old_program="$1"
  shift
  
  # Map command
  local cmd
  cmd=$(map_old_command "$1")
  shift
  
  # Map flags
  local mapped_args=()
  while [[ $# -gt 0 ]]; do
    mapped_args+=("$(map_old_flags "$1")")
    shift
  done
  
  # Combine command and flags
  local final_args=("$cmd" "${mapped_args[@]}")
  
  # Handle special cases
  local special_args
  special_args=$(handle_special_cases "${final_args[@]}")
  mapfile -t final_args <<< "$special_args"
  
  # Execute ocprobe with mapped arguments
  exec ocprobe "${final_args[@]}"
}