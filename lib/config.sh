#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/config.sh — Configuration management (YAML with schema validation)
# ============================================================================

# ---- Default Config Paths ---------------------------------------------------
DEFAULT_CONFIG_DIR="$HOME/.config/ocm"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/config.yaml"
DEFAULT_STATE_DIR="$HOME/.local/state/ocm"

# ---- Config Schema (embedded for validation) -------------------------------
read -r -d '' CONFIG_SCHEMA <<'SCHEMA' || true
# yaml-language-server: $schema=https://json-schema.org/draft/2020-12/schema
type: object
additionalProperties: false
properties:
  version:
    type: integer
    const: 1
  opencode:
    type: object
    properties:
      config_path:
        type: string
        default: "~/.config/opencode/opencode.json"
      db_path:
        type: string
        default: "~/.local/share/opencode/opencode.db"
    required: []
  probe:
    type: object
    properties:
      timeout_new:
        type: integer
        minimum: 5
        maximum: 300
        default: 45
      timeout_whitelist:
        type: integer
        minimum: 5
        maximum: 300
        default: 30
      max_parallel:
        type: integer
        minimum: 1
        maximum: 16
        default: 4
      prompt:
        type: string
        default: "Reply with exactly: OK"
      title_prefix:
        type: string
        default: "ocmm-probe"
    required: []
  catalog:
    type: object
    properties:
      cache_ttl_hours:
        type: integer
        minimum: 1
        maximum: 168
        default: 24
      force_refresh:
        type: boolean
        default: false
    required: []
  scheduler:
    type: object
    properties:
      enabled:
        type: boolean
        default: false
      interval_seconds:
        type: integer
        minimum: 60
        maximum: 604800
        default: 21600
      run_at_load:
        type: boolean
        default: false
    required: []
  alerts:
    type: object
    properties:
      webhook_url:
        type: string
        format: uri
        default: ""
      desktop_notifications:
        type: boolean
        default: true
      batch_mode:
        type: boolean
        default: false
    required: []
  session:
    type: object
    properties:
      age_guard_hours:
        type: integer
        minimum: 1
        maximum: 168
        default: 24
      fresh_guard_hours:
        type: integer
        minimum: 1
        maximum: 24
        default: 1
      max_msg_count:
        type: integer
        minimum: 2
        maximum: 20
        default: 4
      backup_dir:
        type: string
        default: "~/.local/share/opencode/session-backups"
    required: []
  retention:
    type: object
    properties:
      history_limit:
        type: integer
        minimum: 100
        maximum: 100000
        default: 5000
      alert_limit:
        type: integer
        minimum: 100
        maximum: 100000
        default: 1000
      backup_keep_days:
        type: integer
        minimum: 1
        maximum: 365
        default: 30
      graveyard_cooldown_hours:
        type: integer
        minimum: 1
        maximum: 8760
        default: 24
    required: []
  safety:
    type: object
    properties:
      mass_removal_threshold_pct:
        type: integer
        minimum: 10
        maximum: 90
        default: 50
      allow_mass_remove_env:
        type: string
        default: "OCM_ALLOW_MASS_REMOVE"
    required: []
  logging:
    type: object
    properties:
      level:
        type: string
        enum: [debug, info, warn, error]
        default: info
      format:
        type: string
        enum: [text, json]
        default: text
      file_enabled:
        type: boolean
        default: true
    required: []
SCHEMA

# ---- Config Variables (populated by load_config) ---------------------------
# Use conditional assignment to allow re-sourcing
: "${OCM_OPencode_CONFIG:=}"
: "${OCM_OPencode_DB:=}"
: "${OCM_PROBE_TIMEOUT_NEW:=45}"
: "${OCM_PROBE_TIMEOUT_WL:=30}"
: "${OCM_MAX_PARALLEL:=4}"
: "${OCM_PROBE_PROMPT:=Reply with exactly: OK}"
: "${OCM_PROBE_TITLE_PREFIX:=ocmm-probe}"
: "${OCM_CACHE_TTL_HOURS:=24}"
: "${OCM_FORCE_REFRESH:=0}"
: "${OCM_QUICK:=0}"
: "${OCM_WATCH_SECS:=21600}"
: "${OCM_WEBHOOK_URL:=}"
: "${OCM_DESKTOP_NOTIFICATIONS:=1}"
: "${OCM_BATCH_MODE:=0}"
: "${OCM_AGE_GUARD_HOURS:=24}"
: "${OCM_FRESH_GUARD_HOURS:=1}"
: "${OCM_MAX_MSG_COUNT:=4}"
: "${OCM_SESSION_BACKUP_DIR:=}"
: "${OCM_HISTORY_LIMIT:=5000}"
: "${OCM_ALERT_LIMIT:=1000}"
: "${OCM_BACKUP_KEEP_DAYS:=30}"
: "${OCM_GRAVEYARD_COOLDOWN_HOURS:=24}"
: "${OCM_MASS_REMOVAL_THRESHOLD_PCT:=50}"
: "${OCM_ALLOW_MASS_REMOVE_ENV:=OCM_ALLOW_MASS_REMOVE}"
: "${OCM_LOG_LEVEL:=info}"
: "${OCM_LOG_FORMAT:=text}"
: "${OCM_LOG_FILE_ENABLED:=1}"

# ---- Load Configuration -----------------------------------------------------
load_config() {
  local config_file="${OCM_CONFIG_OVERRIDE:-$DEFAULT_CONFIG_FILE}"
  config_file="${config_file/#\~/$HOME}"

  OCM_CONFIG_FILE="$config_file"
  OCM_STATE_DIR="${OCM_STATE_DIR:-$DEFAULT_STATE_DIR}"
  OCM_STATE_DIR="${OCM_STATE_DIR/#\~/$HOME}"

  # Create directories
  mkdir -p "$(dirname "$config_file")" "$OCM_STATE_DIR"
  chmod 700 "$OCM_STATE_DIR" 2>/dev/null || true

  # If config doesn't exist, create default
  if [[ ! -f "$config_file" ]]; then
    create_default_config "$config_file"
  fi

  # Validate with Python (jsonschema)
  if ! validate_config "$config_file"; then
    die "Configuration validation failed: $config_file"
  fi

  # Parse YAML with Python (more reliable than bash)
  local config_vars
  config_vars=$(parse_config_yaml "$config_file")
  # Write to temp file and source to avoid eval injection
  local vars_file
  vars_file=$(mktemp)
  printf '%s\n' "$config_vars" > "$vars_file"
  # shellcheck disable=SC1090
  source "$vars_file"
  rm -f "$vars_file"

  # Set derived paths
  OCM_AUDIT_DIR="${OCM_AUDIT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/ocm.XXXXXX")}"
  OCM_STAMP="$(date +%Y%m%d-%H%M%S)"
  OCM_RUN_DIR="$(mktemp -d "${OCM_AUDIT_DIR}/run-XXXXXX")"
  OCM_LOG_FILE="$OCM_RUN_DIR/audit.log"
  OCM_RESULTS_FILE="$OCM_RUN_DIR/results.tsv"
  OCM_LOCK_DIR="$OCM_STATE_DIR/.lock"

  # Export for subprocesses
  export OCM_CONFIG_FILE OCM_STATE_DIR OCM_AUDIT_DIR OCM_RUN_DIR OCM_LOG_FILE
}

create_default_config() {
  local file="$1"
  cat > "$file" <<'EOF'
# ocm — OpenCode Model Manager Configuration
# See: ocm config schema
version: 1

opencode:
  config_path: "~/.config/opencode/opencode.json"
  db_path: "~/.local/share/opencode/opencode.db"

probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocmm-probe"

catalog:
  cache_ttl_hours: 24
  force_refresh: false

scheduler:
  enabled: false
  interval_seconds: 21600
  run_at_load: false

alerts:
  webhook_url: ""
  desktop_notifications: true
  batch_mode: false

session:
  age_guard_hours: 24
  fresh_guard_hours: 1
  max_msg_count: 4
  backup_dir: "~/.local/share/opencode/session-backups"

retention:
  history_limit: 5000
  alert_limit: 1000
  backup_keep_days: 30
  graveyard_cooldown_hours: 24

safety:
  mass_removal_threshold_pct: 50
  allow_mass_remove_env: "OCM_ALLOW_MASS_REMOVE"

logging:
  level: info
  format: text
  file_enabled: true
EOF
  log_info "Created default config: $file"
}

validate_config() {
  local file="$1"
  python3 - <<'PYEOF' "$file" "$CONFIG_SCHEMA"
import sys, yaml, json, jsonschema
from pathlib import Path

config_file = Path(sys.argv[1]).expanduser()
schema = yaml.safe_load(sys.argv[2])

with open(config_file) as f:
    config = yaml.safe_load(f)

try:
    jsonschema.validate(config, schema)
    print("VALID")
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f"INVALID: {e.message}", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

parse_config_yaml() {
  local file="$1"
  python3 - <<'PYEOF' "$file"
import sys, yaml, os
from pathlib import Path

config_file = Path(sys.argv[1]).expanduser()
with open(config_file) as f:
    config = yaml.safe_load(f) or {}

def get(path, default=None):
    keys = path.split('.')
    val = config
    for k in keys:
        if isinstance(val, dict):
            val = val.get(k)
        else:
            return default
        if val is None:
            return default
    return val

# Print as bash assignments
print(f'OCM_OPencode_CONFIG="{os.path.expanduser(str(get("opencode.config_path", "~/.config/opencode/opencode.json")))}"')
print(f'OCM_OPencode_DB="{os.path.expanduser(str(get("opencode.db_path", "~/.local/share/opencode/opencode.db")))}"')
print(f'OCM_PROBE_TIMEOUT_NEW={get("probe.timeout_new", 45)}')
print(f'OCM_PROBE_TIMEOUT_WL={get("probe.timeout_whitelist", 30)}')
print(f'OCM_MAX_PARALLEL={get("probe.max_parallel", 4)}')
print(f'OCM_PROBE_PROMPT="{get("probe.prompt", "Reply with exactly: OK")}"')
print(f'OCM_PROBE_TITLE_PREFIX="{get("probe.title_prefix", "ocmm-probe")}"')
print(f'OCM_CACHE_TTL_HOURS={get("catalog.cache_ttl_hours", 24)}')
print(f'OCM_WATCH_SECS={get("scheduler.interval_seconds", 21600)}')
print(f'OCM_WEBHOOK_URL="{get("alerts.webhook_url", "")}"')
print(f'OCM_DESKTOP_NOTIFICATIONS={1 if get("alerts.desktop_notifications", True) else 0}')
print(f'OCM_BATCH_MODE={1 if get("alerts.batch_mode", False) else 0}')
print(f'OCM_AGE_GUARD_HOURS={get("session.age_guard_hours", 24)}')
print(f'OCM_FRESH_GUARD_HOURS={get("session.fresh_guard_hours", 1)}')
print(f'OCM_MAX_MSG_COUNT={get("session.max_msg_count", 4)}')
print(f'OCM_SESSION_BACKUP_DIR="{os.path.expanduser(str(get("session.backup_dir", "~/.local/share/opencode/session-backups")))}"')
print(f'OCM_HISTORY_LIMIT={get("retention.history_limit", 5000)}')
print(f'OCM_ALERT_LIMIT={get("retention.alert_limit", 1000)}')
print(f'OCM_BACKUP_KEEP_DAYS={get("retention.backup_keep_days", 30)}')
print(f'OCM_GRAVEYARD_COOLDOWN_HOURS={get("retention.graveyard_cooldown_hours", 24)}')
print(f'OCM_MASS_REMOVAL_THRESHOLD_PCT={get("safety.mass_removal_threshold_pct", 50)}')
print(f'OCM_ALLOW_MASS_REMOVE_ENV="{get("safety.allow_mass_remove_env", "OCM_ALLOW_MASS_REMOVE")}"')
print(f'OCM_LOG_LEVEL="{get("logging.level", "info")}"')
print(f'OCM_LOG_FORMAT="{get("logging.format", "text")}"')
print(f'OCM_LOG_FILE_ENABLED={1 if get("logging.file_enabled", True) else 0}')
PYEOF
}

# ---- Config Commands --------------------------------------------------------
cmd_config() {
  local subcmd="${1:-show}"
  shift || true

  case "$subcmd" in
    show)
      [[ -f "$OCM_CONFIG_FILE" ]] && cat "$OCM_CONFIG_FILE" || echo "No config file found"
      ;;
    validate)
      validate_config "$OCM_CONFIG_FILE" && echo "Config is valid"
      ;;
    edit)
      local editor="${EDITOR:-${VISUAL:-vim}}"
      if ! command -v "${editor%% *}" >/dev/null 2>&1; then
        log_error "No editor found. Set EDITOR or VISUAL environment variable, or install vim/nano"
        return 1
      fi
      $editor "$OCM_CONFIG_FILE"
      ;;
    schema)
      echo "$CONFIG_SCHEMA"
      ;;
    path)
      echo "$OCM_CONFIG_FILE"
      ;;
    *)
      log_error "Unknown config command: $subcmd"
      return 1
      ;;
  esac
}

# ---- Environment Variable Override Helpers ---------------------------------
get_env_or_config() {
  local env_var="$1" config_var="$2" default="$3"
  local val="${!env_var:-${!config_var:-$default}}"
  echo "$val"
}