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
: "${OCPROBE_CACHE_TTL_HOURS:=1}"
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
			# Values the emitter could not safely wrap in quotes (anything with a
			# newline or a double quote) arrive base64-encoded behind a b64: marker.
			# Decode before quote-stripping so a multi-line value survives intact.
			if [[ "$val" == b64:* ]]; then
				# A sentinel byte is appended and stripped because command substitution
				# strips trailing newlines, which would otherwise eat a value that ends
				# in a newline.
				val=$(python3 -c 'import base64,sys; sys.stdout.write(base64.b64decode(sys.argv[1]).decode() + chr(1))' "${val#b64:}") || val=""
				val="${val%$'\x01'}"
			# Strip surrounding quotes if present
			elif [[ "$val" =~ ^\"(.*)\"$ ]]; then
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

	# ---- Reserved keys ---------------------------------------------------------
	# Accepted for backwards compatibility, read by nothing. Warn ONCE, naming
	# the keys, when one is set to a non-default value -- silence would let an
	# operator believe, say, `scheduler.enabled: false` disables the scheduler.
	if [[ -n "${OCPROBE_RESERVED_IN_USE:-}" ]]; then
		log_warn "these config keys have no effect and are ignored: ${OCPROBE_RESERVED_IN_USE}"
		log_warn "  (they are kept in the schema so existing configs keep validating)"
	fi

	# ---- Integer config validation --------------------------------------------
	# Every value below is interpolated UNQUOTED into an interpreter that
	# assumes it is a plain positive integer:
	#   - SQL strings in lib/db.sh (OCPROBE_MAX_MSG_COUNT, OCPROBE_AGE_GUARD_HOURS,
	#     OCPROBE_FRESH_GUARD_HOURS)
	#   - a launchd plist <integer> and a systemd unit file in lib/scheduler.sh,
	#     plus $(( )) arithmetic there (OCPROBE_WATCH_SECS)
	#   - $(( )) arithmetic and `tail -n` in prune_jsonl (lib/core.sh)
	#     (OCPROBE_HISTORY_LIMIT, OCPROBE_ALERT_LIMIT)
	#   - $(( )) arithmetic in lib/models.sh (OCPROBE_CACHE_TTL_HOURS)
	#
	# CONFIG_SCHEMA already constrains each of these to `type: integer` with a
	# minimum, and that remains the primary gate. This is the second layer: it
	# costs nothing, runs on every load_config, and turns a malformed value into
	# a named error at startup instead of a cryptic SQL syntax error, an
	# unloadable plist, or an arithmetic abort deep inside a command.
	#
	# validate_positive_int() requires a value > 0, which matches every field
	# here (all schema minimums are >= 1), so no zero-allowing variant is needed
	# and the function's tested behaviour is untouched. It is passed the config
	# key alongside the variable name so the failure names the key a user
	# actually edits in config.yaml.
	local int_var int_label
	for int_var in \
		OCPROBE_MAX_MSG_COUNT \
		OCPROBE_AGE_GUARD_HOURS \
		OCPROBE_FRESH_GUARD_HOURS \
		OCPROBE_WATCH_SECS \
		OCPROBE_HISTORY_LIMIT \
		OCPROBE_ALERT_LIMIT \
		OCPROBE_CACHE_TTL_HOURS; do
		case "$int_var" in
		OCPROBE_MAX_MSG_COUNT) int_label="session.max_msg_count" ;;
		OCPROBE_AGE_GUARD_HOURS) int_label="session.age_guard_hours" ;;
		OCPROBE_FRESH_GUARD_HOURS) int_label="session.fresh_guard_hours" ;;
		OCPROBE_WATCH_SECS) int_label="scheduler.interval_seconds" ;;
		OCPROBE_HISTORY_LIMIT) int_label="retention.history_limit" ;;
		OCPROBE_ALERT_LIMIT) int_label="retention.alert_limit" ;;
		OCPROBE_CACHE_TTL_HOURS) int_label="catalog.cache_ttl_hours" ;;
		esac
		validate_positive_int "$int_label ($int_var) [in $config_file]" "${!int_var}"
		# NORMALIZE to canonical decimal. The gate above forces base 10, so "08"
		# and "007" are accepted -- but the raw string is still not safe to use:
		# these values are interpolated UNQUOTED into SQL integer literals and
		# into $(( )) arithmetic, where a leading zero is an octal trap all over
		# again. Canonical decimal is the only form that is correct in every sink.
		# "0" cannot reach here (the gate rejects it), so the strip cannot empty
		# the value, but guard anyway rather than export an empty variable.
		local canonical="${!int_var#"${!int_var%%[!0]*}"}"
		[[ -n "$canonical" ]] || canonical=0
		printf -v "$int_var" '%s' "$canonical"
	done

	# Set derived paths
	OCPROBE_AUDIT_DIR="${OCPROBE_AUDIT_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/ocprobe.XXXXXX")}"
	OCPROBE_STAMP="$(date +%Y%m%d-%H%M%S)"
	OCPROBE_RUN_DIR="${OCPROBE_RUN_DIR:-$(mktemp -d "${OCPROBE_AUDIT_DIR}/run-XXXXXX")}"
	OCPROBE_LOG_FILE="${OCPROBE_LOG_FILE:-$OCPROBE_RUN_DIR/audit.log}"
	OCPROBE_RESULTS_FILE="${OCPROBE_RESULTS_FILE:-$OCPROBE_RUN_DIR/results.tsv}"
	OCPROBE_LOCK_DIR="${OCPROBE_LOCK_DIR:-$OCPROBE_STATE_DIR/.lock}"

	# Run start (epoch ms). Session cleanup deletes ONLY sessions created at/after
	# this instant, so a long run cannot leak its own probe sessions (a fixed
	# "fresh < 1h" window leaked everything older than an hour on a 65-min run).
	OCPROBE_RUN_START_MS="${OCPROBE_RUN_START_MS:-$(python3 -c 'import time; print(int(time.time() * 1000))')}"
	export OCPROBE_RUN_START_MS

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
  cache_ttl_hours: 1

scheduler:
  interval_seconds: 21600

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

import base64

def s(var, value):
    # Emit a string config value. load_config parses this output line by line as
    # VAR="value", so a value containing a newline used to split one assignment
    # across several lines: the continuation lines failed the ^VAR=value$ match
    # and were dropped with a warning, leaving the value truncated AND carrying a
    # stray leading quote. A double quote breaks the same convention. Both are
    # therefore base64-encoded behind a b64: marker that load_config decodes.
    t = str(value)
    if "\n" in t or '"' in t:
        # base64 output is shell-safe by construction (A-Za-z0-9+/=), so it is
        # emitted unquoted; quoting it would leave the b64: marker behind a
        # leading '"' and the decode branch would never match.
        print(f'{var}=b64:{base64.b64encode(t.encode()).decode()}')
    else:
        print(f'{var}="{t}"')

# Print as bash assignments
s("OCPROBE_OPencode_CONFIG", os.path.expanduser(str(get("opencode.config_path", "~/.config/opencode/opencode.json"))))
s("OCPROBE_OPencode_DB", os.path.expanduser(str(get("opencode.db_path", "~/.local/share/opencode/opencode.db"))))
print(f'OCPROBE_PROBE_TIMEOUT_NEW={get("probe.timeout_new", 45)}')
print(f'OCPROBE_PROBE_TIMEOUT_WL={get("probe.timeout_whitelist", 30)}')
print(f'OCPROBE_MAX_PARALLEL={get("probe.max_parallel", 4)}')
s("OCPROBE_PROBE_PROMPT", get("probe.prompt", "Reply with exactly: OK"))
s("OCPROBE_PROBE_TITLE_PREFIX", get("probe.title_prefix", "ocprobe-probe"))
print(f'OCPROBE_CACHE_TTL_HOURS={get("catalog.cache_ttl_hours", 1)}')
print(f'OCPROBE_WATCH_SECS={get("scheduler.interval_seconds", 21600)}')
s("OCPROBE_WEBHOOK_URL", get("alerts.webhook_url", ""))
print(f'OCPROBE_DESKTOP_NOTIFICATIONS={1 if get("alerts.desktop_notifications", True) else 0}')
print(f'OCPROBE_BATCH_MODE={1 if get("alerts.batch_mode", False) else 0}')
print(f'OCPROBE_AGE_GUARD_HOURS={get("session.age_guard_hours", 24)}')
print(f'OCPROBE_FRESH_GUARD_HOURS={get("session.fresh_guard_hours", 1)}')
print(f'OCPROBE_MAX_MSG_COUNT={get("session.max_msg_count", 4)}')
s("OCPROBE_SESSION_BACKUP_DIR", os.path.expanduser(str(get("session.backup_dir", "~/.local/share/opencode/session-backups"))))
print(f'OCPROBE_HISTORY_LIMIT={get("retention.history_limit", 5000)}')
print(f'OCPROBE_ALERT_LIMIT={get("retention.alert_limit", 1000)}')
print(f'OCPROBE_BACKUP_KEEP_DAYS={get("retention.backup_keep_days", 30)}')
print(f'OCPROBE_GRAVEYARD_COOLDOWN_HOURS={get("retention.graveyard_cooldown_hours", 24)}')
print(f'OCPROBE_MASS_REMOVAL_THRESHOLD_PCT={get("safety.mass_removal_threshold_pct", 50)}')
s("OCPROBE_ALLOW_MASS_REMOVE_ENV", get("safety.allow_mass_remove_env", "OCPROBE_ALLOW_MASS_REMOVE"))
s("OCPROBE_LOG_LEVEL", get("logging.level", "info"))
s("OCPROBE_LOG_FORMAT", get("logging.format", "text"))
print(f'OCPROBE_LOG_FILE_ENABLED={1 if get("logging.file_enabled", True) else 0}')

# Reserved keys. These three are declared in config/schema.json and are still
# accepted, so an existing config containing one keeps validating, but nothing in
# lib/ or bin/ ever reads them. Report the ones set to a non-default value so
# load_config can say so once, instead of leaving an operator to believe
# `scheduler.enabled: false` is doing something. Only the emitter writes this
# variable, and only from these three fixed paths, so it cannot be injected.
reserved = [
    name for name, path in (
        ("catalog.force_refresh", ("catalog", "force_refresh")),
        ("scheduler.enabled", ("scheduler", "enabled")),
        ("scheduler.run_at_load", ("scheduler", "run_at_load")),
    ) if get(".".join(path), False)
]
print('OCPROBE_RESERVED_IN_USE="%s"' % ",".join(reserved))
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
