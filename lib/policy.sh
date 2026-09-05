#!/usr/bin/env bash
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154,SC2155
# ============================================================================
# lib/policy.sh — Declarative policy engine (EXPERIMENTAL)
# ============================================================================

# ---- Default Policy Paths ----------------------------------------------------
DEFAULT_POLICY_DIR="$HOME/.config/ocprobe"
DEFAULT_POLICY_FILE="$DEFAULT_POLICY_DIR/policy.yaml"

# ---- Path Resolution ---------------------------------------------------------
# Resolve the policy file path, expanding ~ to $HOME if present.
# Mirrors the tilde-expansion idiom used in load_config().
policy_resolve_path() {
	local path="${OCPROBE_POLICY_OVERRIDE:-$DEFAULT_POLICY_FILE}"
	path="${path/#\~/$HOME}"
	echo "$path"
}

# ---- Validation --------------------------------------------------------------
# Standalone validator for the `policy validate` command.
# Loads the JSON schema from $OCPROBE_CONFIG_DIR/policy.schema.json,
# parses the YAML file, validates with jsonschema, prints VALID/INVALID.
# Returns 0 on success, 1 on validation failure.
validate_policy() {
	local policy_file="$1"
	local schema_file="$OCPROBE_CONFIG_DIR/policy.schema.json"

	# Ensure schema file exists
	[[ -f "$schema_file" ]] || {
		log_error "Schema file not found: $schema_file"
		return 1
	}

	python3 - "$policy_file" "$schema_file" <<'PY'
import sys, yaml, json, jsonschema

policy_file = sys.argv[1]
schema_file = sys.argv[2]

try:
    with open(policy_file) as f:
        cfg = yaml.safe_load(f) or {}
except yaml.YAMLError as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(2)

try:
    with open(schema_file) as f:
        schema = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"SCHEMA_ERROR: {e}", file=sys.stderr)
    sys.exit(1)

try:
    jsonschema.validate(instance=cfg, schema=schema)
    print("VALID")
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f"INVALID: {e.message}", file=sys.stderr)
    sys.exit(1)
PY
}

# ---- Fail-Closed Loader ------------------------------------------------------
# load_policy() — the fail-closed policy loader.
#
# IMPORTANT: This function implements a deliberate FAIL-CLOSED design.
# If the policy file exists but cannot be parsed/validated, we do NOT silently
# ignore it (which would be fail-open). Instead:
#   - If parse succeeds and validation passes: policy is active per its settings.
#   - If parse succeeds but validation fails AND enabled:true (or we can't tell
#     because the schema didn't set a default) → DIE. We refuse to run with a
#     broken policy that claims to be enabled.
#   - If parse fails (YAML syntax error) → DIE. We cannot know whether the
#     user intended enabled:true, so we treat this as the enabled:true case
#     for safety.
#   - If file doesn't exist → no-op (policy engine disabled).
#
# This prevents a class of bugs where a typo in the policy file silently
# disables all protection the user thought they had.
load_policy() {
	local policy_file
	policy_file=$(policy_resolve_path)

	# No policy file = no-op (disabled)
	[[ -f "$policy_file" ]] || {
		OCPROBE_POLICY_ENABLED=0
		OCPROBE_POLICY_AUTO_APPLY=0
		OCPROBE_POLICY_FILE=""
		return 0
	}

	# Run validation in a single Python heredoc to avoid multiple parses
	local result
	result=$(
		python3 - "$policy_file" "$OCPROBE_CONFIG_DIR/policy.schema.json" <<'PY'
import sys, yaml, json, jsonschema

policy_file = sys.argv[1]
schema_file = sys.argv[2]

try:
    with open(policy_file) as f:
        cfg = yaml.safe_load(f) or {}
except yaml.YAMLError as e:
    print(f"PARSE_ERROR: {e}", file=sys.stderr)
    sys.exit(2)

enabled_raw = cfg.get('enabled', False) if isinstance(cfg, dict) else False

try:
    with open(schema_file) as f:
        schema = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"SCHEMA_ERROR: {e}", file=sys.stderr)
    sys.exit(1)

try:
    jsonschema.validate(instance=cfg, schema=schema)
    print(f"OK|{1 if cfg.get('enabled', False) else 0}|{1 if cfg.get('auto_apply', False) else 0}")
    sys.exit(0)
except jsonschema.ValidationError as e:
    print(f"INVALID|{1 if enabled_raw else 0}", file=sys.stderr)
    sys.exit(1)
PY
	)
	local ec=$?

	case $ec in
	0) # OK|enabled|auto_apply
		local enabled auto_apply
		enabled=$(echo "$result" | cut -d'|' -f2)
		auto_apply=$(echo "$result" | cut -d'|' -f3)
		OCPROBE_POLICY_ENABLED=$enabled
		OCPROBE_POLICY_AUTO_APPLY=$auto_apply
		OCPROBE_POLICY_FILE="$policy_file"
		;;
	1) # INVALID|enabled_raw
		local enabled_raw
		enabled_raw=$(echo "$result" | cut -d'|' -f2)
		if [[ "$enabled_raw" -eq 1 ]]; then
			die "Policy file is invalid and enabled:true — refusing to proceed: $policy_file (run 'ocprobe policy validate' for details)"
		else
			log_warn "Policy file is invalid but enabled is not true — ignoring (no-op): $policy_file"
			OCPROBE_POLICY_ENABLED=0
			OCPROBE_POLICY_FILE="$policy_file"
		fi
		;;
	2) # PARSE_ERROR
		die "Policy file could not be parsed as YAML — refusing to proceed safely: $policy_file (run 'ocprobe policy validate' for details)"
		;;
	*) # Should not happen
		die "Unknown policy validation exit code: $ec"
		;;
	esac
}

# ---- Glob Matcher ------------------------------------------------------------
# GLOB SEMANTICS (documented for future editors — do not change without tests):
# - Matching is against the FULL "provider/model" string, not path-segment-aware.
# - `*` matches any sequence of characters, INCLUDING `/` (so "anthropic/*"
#   matches "anthropic/claude-3" and would also match "anthropic/x/y" — there
#   is no slash-boundary special-casing).
# - `?` matches exactly one character.
# - `[...]` character classes work (native bash glob).
# - Matching is case-sensitive.
# - Empty or missing patterns file = no match, never an error.

policy_glob_match() {
	local pattern="$1" value="$2"
	# shellcheck disable=SC2053 # pattern deliberately unquoted for glob expansion
	[[ "$value" == $pattern ]]
}

policy_match_any() {
	local value="$1" patterns_file="$2"
	[[ -f "$patterns_file" ]] || return 1
	local p
	while IFS= read -r p; do
		[[ -n "$p" ]] || continue
		policy_glob_match "$p" "$value" && return 0
	done <"$patterns_file"
	return 1
}

# ---- Default Policy Scaffold -------------------------------------------------
create_default_policy() {
	local file="$1"
	mkdir -p "$(dirname "$file")"
	cat >"$file" <<'EOF'
# ocprobe policy — declarative rules for the audit/check pipeline (EXPERIMENTAL)
# This file is inert until you set enabled: true.
# See: ocprobe policy show / ocprobe policy validate
version: 1
enabled: false
auto_apply: false
never_remove: []
never_add: []
providers: {}
EOF
}

# ---- Command Dispatcher ------------------------------------------------------
cmd_policy() {
	local subcmd="${1:-show}"
	shift || true

	local policy_file
	policy_file=$(policy_resolve_path)

	case "$subcmd" in
	show)
		if [[ -f "$policy_file" ]]; then
			cat "$policy_file"
		else
			echo "No policy file found at $policy_file (policy engine disabled)."
		fi
		;;
	validate)
		if [[ ! -f "$policy_file" ]]; then
			echo "No policy file found at $policy_file — nothing to validate"
			return 0
		fi
		if validate_policy "$policy_file"; then
			echo "Policy is valid: $policy_file"
		else
			return 1
		fi
		;;
	path)
		echo "$policy_file"
		;;
	init)
		if [[ -f "$policy_file" ]]; then
			die "Policy file already exists: $policy_file (refusing to overwrite)"
		fi
		create_default_policy "$policy_file"
		echo "Created policy scaffold (disabled) at: $policy_file"
		;;
	*)
		log_error "Unknown policy command: $subcmd"
		echo "Usage: ocprobe policy [show|validate|path|init]"
		return 1
		;;
	esac
}
