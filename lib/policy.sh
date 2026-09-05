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

# ---- Policy File Writers -----------------------------------------------------

# policy_write_never_remove_file() — materializes the flat never_remove
# list (global, top-level only per schema — NOT provider-scoped) into
# $OCPROBE_RUN_DIR/policy-never_remove.txt for consumption by
# policy_match_any(). Writes an EMPTY file when policy is disabled or
# missing, so callers never need a conditional branch.
policy_write_never_remove_file() {
	local out="$OCPROBE_RUN_DIR/policy-never_remove.txt"
	: >"$out"
	[[ "${OCPROBE_POLICY_ENABLED:-0}" -eq 1 && -n "${OCPROBE_POLICY_FILE:-}" ]] || return 0
	python3 - "$OCPROBE_POLICY_FILE" "$out" <<'PY'
import sys, yaml
policy_file, out_file = sys.argv[1], sys.argv[2]
with open(policy_file) as f:
    cfg = yaml.safe_load(f) or {}
patterns = cfg.get('never_remove') or []
with open(out_file, 'w') as f:
    f.write('\n'.join(patterns) + ('\n' if patterns else ''))
PY
}

# apply_policy_new_filter() — filters new_file IN PLACE, moving excluded
# entries to excluded_file. Handles never_add, per-provider enabled/exclude/include
# in ONE python pass over the whole policy file. Uses Python's fnmatch.fnmatchcase,
# which matches bash's [[ == $glob ]] semantics (case-sensitive, * matches / too,
# ? single char) — so behavior stays consistent with the bash-side matcher.
apply_policy_new_filter() {
	local new_file="$1" excluded_file="$2"
	: >"$excluded_file"
	[[ "${OCPROBE_POLICY_ENABLED:-0}" -eq 1 && -n "${OCPROBE_POLICY_FILE:-}" ]] || return 0
	[[ -s "$new_file" ]] || return 0

	local kept_file="${new_file}.kept"
	python3 - "$OCPROBE_POLICY_FILE" "$new_file" "$kept_file" "$excluded_file" <<'PY'
import sys, yaml, fnmatch

policy_file, new_file, kept_file, excluded_file = sys.argv[1:5]
with open(policy_file) as f:
    cfg = yaml.safe_load(f) or {}

never_add = cfg.get('never_add') or []
providers = cfg.get('providers') or {}

def excluded(model_id):
    for pat in never_add:
        if fnmatch.fnmatchcase(model_id, pat):
            return True
    pid = model_id.split('/', 1)[0]
    prov = providers.get(pid)
    if prov is None:
        return False
    if prov.get('enabled', True) is False:
        return True
    for pat in (prov.get('exclude') or []):
        if fnmatch.fnmatchcase(model_id, pat):
            return True
    include = prov.get('include') or ['*']
    if include != ['*'] and not any(fnmatch.fnmatchcase(model_id, pat) for pat in include):
        return True
    return False

kept, exc = [], []
with open(new_file) as f:
    for line in f:
        mid = line.strip()
        if not mid:
            continue
        (exc if excluded(mid) else kept).append(mid)

with open(kept_file, 'w') as f:
    f.write('\n'.join(kept) + ('\n' if kept else ''))
with open(excluded_file, 'w') as f:
    f.write('\n'.join(exc) + ('\n' if exc else ''))
PY
	mv "$kept_file" "$new_file"
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
	dry-run)
		load_config
		load_policy
		policy_write_never_remove_file
		acquire_lock
		trap 'release_lock; cleanup_run_dir' EXIT INT TERM
		fetch_catalog
		compute_diff
		local new_n excluded_n
		new_n=$(wc -l <"$OCPROBE_RUN_DIR/new.txt" 2>/dev/null | tr -d ' ')
		excluded_n=$(wc -l <"$OCPROBE_RUN_DIR/excluded.txt" 2>/dev/null | tr -d ' ')
		{
			echo
			echo "========= POLICY DRY-RUN (no probing, no apply) ========="
			echo "-- candidates that WOULD be probed (${new_n:-0}) — WORKS/failure not yet known:"
			[[ -s "$OCPROBE_RUN_DIR/new.txt" ]] && sed 's/^/    ? /' "$OCPROBE_RUN_DIR/new.txt" || echo "    none"
			echo "-- excluded by policy, never probed (${excluded_n:-0}):"
			[[ -s "$OCPROBE_RUN_DIR/excluded.txt" ]] && sed 's/^/    x /' "$OCPROBE_RUN_DIR/excluded.txt" || echo "    none"
			echo "==========================================================="
		} >&2
		;;
	*)
		log_error "Unknown policy command: $subcmd"
		echo "Usage: ocprobe policy [show|validate|path|init|dry-run]"
		return 1
		;;
	esac
}
