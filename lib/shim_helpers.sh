#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# lib/shim_helpers.sh — Shared helpers for backward compatibility shims
# ============================================================================

# Map old command names to new ocprobe subcommands
# Usage: map_old_command "old_command"
map_old_command() {
  local old_cmd="$1"
  # Emit ONE WORD PER LINE, matching map_old_flags and handle_special_cases.
  # This previously echoed e.g. "scheduler install" as a single string, so
  # run_shim passed one argv element containing a space to ocprobe, whose `case`
  # statement compares separate words and so reported
  # "Unknown command: scheduler install".
  case "$old_cmd" in
    install-scheduler) printf '%s\n' scheduler install ;;
    uninstall-scheduler) printf '%s\n' scheduler uninstall ;;
    *) printf '%s\n' "$old_cmd" ;;
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
  
  # With no subcommand there is no $1 to map. This script runs under `set -u`,
  # so referencing it was a fatal "$1: unbound variable" instead of usage.
  if [[ $# -eq 0 ]]; then
    printf 'usage: %s <command> [flags]\n' "$_old_program" >&2
    printf 'This shim is deprecated; use ocprobe directly.\n' >&2
    printf "Try 'ocprobe help' for the current command list.\n" >&2
    return 0
  fi

  # Map command. Split on newlines so a multi-word mapping becomes separate
  # argv entries that ocprobe's `case` statement can actually match.
  local -a cmd_words=()
  mapfile -t cmd_words < <(map_old_command "$1")
  shift
  
  # Map flags
  local mapped_args=()
  while [[ $# -gt 0 ]]; do
    mapped_args+=("$(map_old_flags "$1")")
    shift
  done
  
  # Combine command and flags
  local -a final_args=("${cmd_words[@]}" "${mapped_args[@]}")
  
  # Handle special cases
  local special_args
  special_args=$(handle_special_cases "${final_args[@]}")
  mapfile -t final_args <<< "$special_args"
  
  # Execute ocprobe with mapped arguments
  exec ocprobe "${final_args[@]}"
}