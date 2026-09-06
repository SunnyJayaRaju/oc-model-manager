#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154
# ============================================================================
# lib/config.sh — Configuration management (YAML with schema validation)
# ============================================================================

# ---- Default Config Paths ---------------------------------------------------
DEFAULT_CONFIG_DIR="$HOME/.config/ocprobe"
DEFAULT_CONFIG_FILE="$DEFAULT_CONFIG_DIR/config.yaml"
DEFAULT_STATE_DIR="$HOME/.local/state/ocprobe"

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
        default: "ocprobe-probe"
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
        default: "OCPROBE_ALLOW_MASS_REMOVE"
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
: "${OCPROBE_OPencode_CONFIG:=}"
: "${OCPROBE_OPencode_DB:=}"
: "${OCPROBE_PROBE_TIMEOUT_NEW:=45}"
: "${OCPROBE_PROBE_TIMEOUT_WL:=30}"
: "${OCPROBE_MAX_PARALLEL:=4}"
: "${OCPROBE_PROBE_PROMPT:=Reply with exactly: OK}"
: "${OCPROBE_PROBE_TITLE_PREFIX:=ocprobe-probe}"
: "${OCPROBE_CACHE_TTL_HOURS:=24}"
: "${OCPROBE_FORCE_REFRESH:=0}"
: "${OCPROBE_QUICK:=0}"
: "${OCPROBE_WATCH_SECS:=21600}"
: "${OCPROBE_WEBHOOK_URL:=}"
: "${OCPROBE_DESKTOP_NOTIFICATIONS:=1}"
: "${OCPROBE_BATCH_MODE:=0}"
: "${OCPROBE_AGE_GUARD_HOURS:=24}"
: "${OCPROBE_FRESH_GUARD_HOURS:=1}"
: "${OCPROBE_MAX_MSG_COUNT:=4}"
: "${OCPROBE_SESSION_BACKUP_DIR:=}"
: "${OCPROBE_HISTORY_LIMIT:=5000}"
: "${OCPROBE_ALERT_LIMIT:=1000}"
: "${OCPROBE_BACKUP_KEEP_DAYS:=30}"
: "${OCPROBE_GRAVEYARD_COOLDOWN_HOURS:=24}"
: "${OCPROBE_MASS_REMOVAL_THRESHOLD_PCT:=50}"
: "${OCPROBE_ALLOW_MASS_REMOVE_ENV:=OCPROBE_ALLOW_MASS_REMOVE}"
: "${OCPROBE_LOG_LEVEL:=info}"
: "${OCPROBE_LOG_FORMAT:=text}"
: "${OCPROBE_LOG_FILE_ENABLED:=1}"

# ---- Load Configuration -----------------------------------------------------
load_config() {
	local config_file="${OCPROBE_CONFIG_OVERRIDE:-$DEFAULT_CONFIG_FILE}"
	config_file="${config_file/#\~/$HOME}"

	OCPROBE_CONFIG_FILE="$config_file"
	OCPROBE_STATE_DIR="${OCPROBE_STATE_DIR:-$DEFAULT_STATE_DIR}"
	OCPROBE_STATE_DIR="${OCPROBE_STATE_DIR/#\~/$HOME}"

	# Create directories
	mkdir -p "$(dirname "$config_file")" "$OCPROBE_STATE_DIR"
	chmod 700 "$OCPROBE_STATE_DIR" 2>/dev/null || true

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
	# Parse line by line safely (no eval/source)
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		# Only accept simple VAR=value assignments (allow lowercase in variable names)
		if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
			local var="${BASH_REMATCH[1]}"
			local val="${BASH_REMATCH[2]}"
			# Strip surrounding quotes if present
			if [[ "$val" =~ ^\"(.*)\"$ ]]; then
				val="${BASH_REMATCH[1]}"
			elif [[ "$val" =~ ^\'(.*)\'$ ]]; then
				val="${BASH_REMATCH[1]}"
			fi
			# Use declare -g to safely set global variable (no eval)
			declare -g "$var=$val"
		else
			log_warn "Ignoring unexpected config output line: $line"
		fi
	done <<<"$config_vars"

	# Set derived paths
	OCPROBE_AUDIT_DIR="${OCPROBE_AUDIT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/ocprobe.XXXXXX")}"
	OCPROBE_STAMP="$(date +%Y%m%d-%H%M%S)"
	OCPROBE_RUN_DIR="${OCPROBE_RUN_DIR:-$(mktemp -d "${OCPROBE_AUDIT_DIR}/run-XXXXXX")}"
	OCPROBE_LOG_FILE="${OCPROBE_LOG_FILE:-$OCPROBE_RUN_DIR/audit.log}"
	OCPROBE_RESULTS_FILE="${OCPROBE_RESULTS_FILE:-$OCPROBE_RUN_DIR/results.tsv}"
	OCPROBE_LOCK_DIR="${OCPROBE_LOCK_DIR:-$OCPROBE_STATE_DIR/.lock}"

	# Derive OCPROBE_CONFIG_DIR from OCPROBE_OPencode_CONFIG (directory containing opencode.json)
	OCPROBE_CONFIG_DIR="$(dirname "$OCPROBE_OPencode_CONFIG")"

	# Export for subprocesses
	export OCPROBE_CONFIG_FILE OCPROBE_STATE_DIR OCPROBE_AUDIT_DIR OCPROBE_RUN_DIR OCPROBE_LOG_FILE
}

create_default_config() {
	local file="$1"
	cat >"$file" <<'EOF'
# ocprobe — OpenCode Model Probe Configuration
# See: ocprobe config schema
version: 1

opencode:
  config_path: "~/.config/opencode/opencode.json"
  db_path: "~/.local/share/opencode/opencode.db"

probe:
  timeout_new: 45
  timeout_whitelist: 30
  max_parallel: 4
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"

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
  allow_mass_remove_env: "OCPROBE_ALLOW_MASS_REMOVE"

logging:
  level: info
  format: text
  file_enabled: true
EOF
	log_info "Created default config: $file"
}

validate_config() {
	local file="$1"
	python3 - "$file" "$CONFIG_SCHEMA" <<'PYEOF'
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
	python3 - "$file" <<'PYEOF'
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
print(f'OCPROBE_OPencode_CONFIG="{os.path.expanduser(str(get("opencode.config_path", "~/.config/opencode/opencode.json")))}"')
print(f'OCPROBE_OPencode_DB="{os.path.expanduser(str(get("opencode.db_path", "~/.local/share/opencode/opencode.db")))}"')
print(f'OCPROBE_PROBE_TIMEOUT_NEW={get("probe.timeout_new", 45)}')
print(f'OCPROBE_PROBE_TIMEOUT_WL={get("probe.timeout_whitelist", 30)}')
print(f'OCPROBE_MAX_PARALLEL={get("probe.max_parallel", 4)}')
print(f'OCPROBE_PROBE_PROMPT="{get("probe.prompt", "Reply with exactly: OK")}"')
print(f'OCPROBE_PROBE_TITLE_PREFIX="{get("probe.title_prefix", "ocprobe-probe")}"')
print(f'OCPROBE_CACHE_TTL_HOURS={get("catalog.cache_ttl_hours", 24)}')
print(f'OCPROBE_WATCH_SECS={get("scheduler.interval_seconds", 21600)}')
print(f'OCPROBE_WEBHOOK_URL="{get("alerts.webhook_url", "")}"')
print(f'OCPROBE_DESKTOP_NOTIFICATIONS={1 if get("alerts.desktop_notifications", True) else 0}')
print(f'OCPROBE_BATCH_MODE={1 if get("alerts.batch_mode", False) else 0}')
print(f'OCPROBE_AGE_GUARD_HOURS={get("session.age_guard_hours", 24)}')
print(f'OCPROBE_FRESH_GUARD_HOURS={get("session.fresh_guard_hours", 1)}')
print(f'OCPROBE_MAX_MSG_COUNT={get("session.max_msg_count", 4)}')
print(f'OCPROBE_SESSION_BACKUP_DIR="{os.path.expanduser(str(get("session.backup_dir", "~/.local/share/opencode/session-backups")))}"')
print(f'OCPROBE_HISTORY_LIMIT={get("retention.history_limit", 5000)}')
print(f'OCPROBE_ALERT_LIMIT={get("retention.alert_limit", 1000)}')
print(f'OCPROBE_BACKUP_KEEP_DAYS={get("retention.backup_keep_days", 30)}')
print(f'OCPROBE_GRAVEYARD_COOLDOWN_HOURS={get("retention.graveyard_cooldown_hours", 24)}')
print(f'OCPROBE_MASS_REMOVAL_THRESHOLD_PCT={get("safety.mass_removal_threshold_pct", 50)}')
print(f'OCPROBE_ALLOW_MASS_REMOVE_ENV="{get("safety.allow_mass_remove_env", "OCPROBE_ALLOW_MASS_REMOVE")}"')
print(f'OCPROBE_LOG_LEVEL="{get("logging.level", "info")}"')
print(f'OCPROBE_LOG_FORMAT="{get("logging.format", "text")}"')
print(f'OCPROBE_LOG_FILE_ENABLED={1 if get("logging.file_enabled", True) else 0}')
PYEOF
}

# ---- Config Commands --------------------------------------------------------
cmd_config() {
	local subcmd="${1:-show}"
	shift || true

	case "$subcmd" in
	show)
		[[ -f "$OCPROBE_CONFIG_FILE" ]] && cat "$OCPROBE_CONFIG_FILE" || echo "No config file found"
		;;
	validate)
		validate_config "$OCPROBE_CONFIG_FILE" && echo "Config is valid"
		;;
	edit)
		local editor="${EDITOR:-${VISUAL:-vim}}"
		if ! command -v "${editor%% *}" >/dev/null 2>&1; then
			log_error "No editor found. Set EDITOR or VISUAL environment variable, or install vim/nano"
			return 1
		fi
		$editor "$OCPROBE_CONFIG_FILE"
		;;
	schema)
		echo "$CONFIG_SCHEMA"
		;;
	path)
		echo "$OCPROBE_CONFIG_FILE"
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
