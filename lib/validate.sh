#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016
# OCPROBE_OPencode_CONFIG, OCPROBE_STATE_DIR, OCPROBE_RUN_DIR, OCPROBE_RESULTS_FILE, OCPROBE_LOCK_DIR, OCPROBE_STAMP,
# OCPROBE_AUDIT_DIR, OCPROBE_LOG_FILE, OCPROBE_PROBE_TIMEOUT_NEW, OCPROBE_PROBE_TIMEOUT_WL, OCPROBE_MAX_PARALLEL,
# OCPROBE_PROBE_PROMPT, OCPROBE_PROBE_TITLE_PREFIX, OCPROBE_CACHE_TTL_HOURS, OCPROBE_FORCE_REFRESH, OCPROBE_QUICK,
# OCPROBE_WATCH_SECS, OCPROBE_WEBHOOK_URL, OCPROBE_DESKTOP_NOTIFICATIONS, OCPROBE_BATCH_MODE, OCPROBE_AGE_GUARD_HOURS,
# OCPROBE_FRESH_GUARD_HOURS, OCPROBE_MAX_MSG_COUNT, OCPROBE_SESSION_BACKUP_DIR, OCPROBE_HISTORY_LIMIT,
# OCPROBE_ALERT_LIMIT, OCPROBE_BACKUP_KEEP_DAYS, OCPROBE_GRAVEYARD_COOLDOWN_HOURS,
# OCPROBE_MASS_REMOVAL_THRESHOLD_PCT, OCPROBE_ALLOW_MASS_REMOVE_ENV, OCPROBE_LOG_LEVEL, OCPROBE_LOG_FORMAT,
# OCPROBE_LOG_FILE_ENABLED are set by load_config in config.sh
# ============================================================================
# lib/validate.sh — Validate models and manage provider blacklists
# ============================================================================

# ---- Constants ---------------------------------------------------------------
: "${OCPROBE_VALIDATE_PROBE_TIMEOUT:=30}"
: "${OCPROBE_VALIDATE_PROBE_PROMPT:=Reply with exactly: OK}"
: "${OCPROBE_VALIDATE_TITLE_PREFIX:=ocprobe-validate}"
: "${OCPROBE_VALIDATE_MAX_PARALLEL:=4}"

# ---- Modality Skip Patterns ---------------------------------------------------
# Local glob matcher — semantics intentionally match policy_glob_match()
# in lib/policy.sh (case-sensitive, * matches /, ? = one char) but this
# is a deliberately separate, non-shared copy for this track. See
# feature/validate-hardening design notes: do not merge with policy.sh.
# shellcheck disable=SC2053,SC2329
validate_glob_match() {
	local pattern="$1" value="$2"
	[[ "$value" == $pattern ]]
}

# is_modality_skip(model_id) — returns 0 if model matches any skip pattern
# Checks curated defaults at $OCPROBE_CONFIG_DIR/validate-skip-patterns.txt
# and optional user file at $OCPROBE_STATE_DIR/validate-skip-patterns-user.txt
# shellcheck disable=SC2329
is_modality_skip() {
	local model_id="$1"
	local skip_file="$OCPROBE_CONFIG_DIR/validate-skip-patterns.txt"
	local user_skip_file="$OCPROBE_STATE_DIR/validate-skip-patterns-user.txt"
	local patterns_file

	# Build combined patterns file (defaults + user extensions)
	patterns_file=$(mktemp)
	cat "$skip_file" >"$patterns_file"
	[[ -f "$user_skip_file" ]] && cat "$user_skip_file" >>"$patterns_file"

	# Read patterns into array first to avoid SC2094
	local -a patterns=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		[[ "$line" =~ ^# ]] && continue
		patterns+=("$line")
	done <"$patterns_file"
	rm -f "$patterns_file"

	local pattern
	for pattern in "${patterns[@]}"; do
		validate_glob_match "$pattern" "$model_id" && return 0
	done
	return 1
}

# ---- Modality Skip Patterns ---------------------------------------------------
# Local glob matcher — semantics intentionally match policy_glob_match()
# in lib/policy.sh (case-sensitive, * matches /, ? = one char) but this
# is a deliberately separate, non-shared copy for this track. See
# feature/validate-hardening design notes: do not merge with policy.sh.
# shellcheck disable=SC2053
validate_glob_match() {
	local pattern="$1" value="$2"
	[[ "$value" == $pattern ]]
}

# is_modality_skip(model_id) — returns 0 if model matches any skip pattern
# Checks curated defaults at $OCPROBE_CONFIG_DIR/validate-skip-patterns.txt
# and optional user file at $OCPROBE_STATE_DIR/validate-skip-patterns-user.txt
is_modality_skip() {
	local model_id="$1"
	local skip_file="$OCPROBE_CONFIG_DIR/validate-skip-patterns.txt"
	local user_skip_file="$OCPROBE_STATE_DIR/validate-skip-patterns-user.txt"
	local patterns_file

	# Build combined patterns file (defaults + user extensions)
	patterns_file=$(mktemp)
	cat "$skip_file" >"$patterns_file"
	[[ -f "$user_skip_file" ]] && cat "$user_skip_file" >>"$patterns_file"

	# Read patterns into array first to avoid SC2094
	local -a patterns=()
	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		[[ "$line" =~ ^# ]] && continue
		patterns+=("$line")
	done <"$patterns_file"
	rm -f "$patterns_file"

	local pattern
	for pattern in "${patterns[@]}"; do
		validate_glob_match "$pattern" "$model_id" && return 0
	done
	return 1
}

# Path to skip patterns files (exported for external reference, only when dirs are set)
[[ -n "${OCPROBE_CONFIG_DIR:-}" ]] && export OCPROBE_VALIDATE_SKIP_PATTERNS_FILE="${OCPROBE_CONFIG_DIR}/validate-skip-patterns.txt"
[[ -n "${OCPROBE_STATE_DIR:-}" ]] && export OCPROBE_VALIDATE_USER_SKIP_PATTERNS_FILE="${OCPROBE_STATE_DIR}/validate-skip-patterns-user.txt"

# Path to opencode auth file (credentials)
OCPROBE_OPencode_AUTH="${OCPROBE_OPencode_AUTH:-$HOME/.local/share/opencode/auth.json}"

# ---- Validate History (validate-history.jsonl) ---------------------------------
# SEPARATE from probe-history.jsonl (audit/check's file). Never read or write
# probe-history.jsonl from validate.sh.

# load_validate_history() — populates VALIDATE_FAIL_COUNT
# Uses safe_key pattern (model with / replaced by _) same as lib/models.sh
load_validate_history() {
	local -n fail_count=$1

	[[ -f "$OCPROBE_STATE_DIR/validate-history.jsonl" ]] || return 0

	local line
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		local model status
		model=$(printf '%s' "$line" | awk '{print $1}')
		status=$(printf '%s' "$line" | awk '{print $2}')
		[[ -n "$model" && -n "$status" ]] || continue
		local safe_key="${model//\//_}"
		VALIDATE_FAIL_COUNT["$safe_key"]="${fail_count[$safe_key]:-0}"
	done <"$OCPROBE_STATE_DIR/validate-history.jsonl"
}

# record_validate_history(model, status) — append one line, then prune_jsonl
# Reuses the generic prune_jsonl utility from lib/db.sh (pure utility, not audit-specific)
record_validate_history() {
	local model="$1" status="$2"
	local history_file="$OCPROBE_STATE_DIR/validate-history.jsonl"
	mkdir -p "$(dirname "$history_file")"
	# Portable millisecond timestamp: python for cross-platform support
	local timestamp
	timestamp=$(python3 -c 'import time; print(int(time.time() * 1000))')
	printf '%s\t%s\t%d\n' "$model" "$status" "$timestamp" >>"$history_file"
	prune_jsonl "$history_file" "$OCPROBE_HISTORY_LIMIT"
}

# ---- Validate Classification ---------------------------------------------------
# generate_validate_classification() — two-consecutive-failure state machine
# For each non-WORKS, non-SKIPPED_MODALITY model in results_file:
#   - EOL or NOT_FOUND (validate's mapping) → CONFIRMED immediately
#   - Other non-WORKS → check VALIDATE_FAIL_COUNT:
#       0 (first time) → TENTATIVE, record failure, do NOT add to blacklist
#       >=1 (second consecutive) → CONFIRMED, add to blacklist
#   - WORKS → if VALIDATE_FAIL_COUNT > 0, record WORKS to reset count
# Output: proposal file (CONFIRMED only), tentative_file (TENTATIVE only)
generate_validate_classification() {
	local provider_id="$1"
	local results_file="$2"
	local proposal_file="$3"
	local tentative_file="$4"

	: >"$proposal_file"
	: >"$tentative_file"

	[[ -s "$results_file" ]] || return 0

	# Load history for this run
	declare -gA VALIDATE_FAIL_COUNT=()
	load_validate_history VALIDATE_FAIL_COUNT

	local model status
	while IFS=$'\t' read -r model status _lat; do
		[[ -n "$model" ]] || continue
		local safe_key="${model//\//_}"

		case "$status" in
		WORKS)
			# Reset failure count on success
			if [[ "${VALIDATE_FAIL_COUNT[$safe_key]:-0}" -gt 0 ]]; then
				VALIDATE_FAIL_COUNT["$safe_key"]=0
				record_validate_history "$model" "WORKS"
			fi
			;;
		EOL | NOT_FOUND)
			# Terminal failures — confirm immediately regardless of history
			echo "$model" >>"$proposal_file"
			VALIDATE_FAIL_COUNT["$safe_key"]=2 # mark as confirmed
			record_validate_history "$model" "$status"
			;;
		SKIPPED_MODALITY)
			# Already filtered out by generate_blacklist_proposal, but handle gracefully
			;;
		*)
			# Other failures: TIMEOUT, AUTH_ERROR, BILLING_ERROR, ERROR, UNCLEAR
			local fail_count="${VALIDATE_FAIL_COUNT[$safe_key]:-0}"
			if [[ $fail_count -eq 0 ]]; then
				# First failure → TENTATIVE
				VALIDATE_FAIL_COUNT["$safe_key"]=1
				record_validate_history "$model" "$status"
				echo "$model" >>"$tentative_file"
			else
				# Second consecutive failure → CONFIRMED
				echo "$model" >>"$proposal_file"
				VALIDATE_FAIL_COUNT["$safe_key"]=2
				record_validate_history "$model" "$status"
			fi
			;;
		esac
	done < <(awk -F'\t' '$2 != "WORKS" && $2 != "SKIPPED_MODALITY" {print $1 "\t" $2}' "$results_file")
}

# Path to opencode auth file (credentials)
OCPROBE_OPencode_AUTH="${OCPROBE_OPencode_AUTH:-$HOME/.local/share/opencode/auth.json}"

# ---- Path Validation ---------------------------------------------------------
validate_opencode_config() {
	local config_file
	# shellcheck disable=SC2154  # OCPROBE_OPencode_CONFIG set by load_config in config.sh
	config_file="${OCPROBE_OPencode_CONFIG}"
	[[ -f "$config_file" ]] || die "opencode.json not found at $config_file"
	[[ -r "$config_file" ]] || die "opencode.json not readable at $config_file"
	[[ -w "$config_file" ]] || die "opencode.json not writable at $config_file"
}

validate_auth_file() {
	[[ -f "$OCPROBE_OPencode_AUTH" ]] || die "auth.json not found at $OCPROBE_OPencode_AUTH"
	[[ -r "$OCPROBE_OPencode_AUTH" ]] || die "auth.json not readable at $OCPROBE_OPencode_AUTH"
}

# ---- Auth/Config Parsing -----------------------------------------------------
# Get providers with valid credentials from auth.json
get_configured_providers() {
	python3 - "$OCPROBE_OPencode_AUTH" <<'PY'
import json, sys, os
try:
    with open(os.path.expanduser(sys.argv[1])) as f:
        auth = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"Error loading auth: {e}", file=sys.stderr)
    sys.exit(1)

for provider_id, creds in sorted(auth.items()):
    if isinstance(creds, dict) and creds.get("type") == "api" and creds.get("key"):
        print(provider_id)
PY
}

# Get full model list for a provider from opencode models command
get_provider_models() {
	local provider_id="$1"
	opencode models "$provider_id" 2>/dev/null | sort -u
}

# Get current blacklist for a provider from opencode.json
get_current_blacklist() {
	local provider_id="$1"
	python3 - "$OCPROBE_OPencode_CONFIG" "$provider_id" <<'PY'
import json, sys, os
try:
    with open(os.path.expanduser(sys.argv[1])) as f:
        cfg = json.load(f)
except (json.JSONDecodeError, OSError) as e:
    print(f"Error loading config: {e}", file=sys.stderr)
    sys.exit(1)

provider = sys.argv[2]
bl = cfg.get("provider", {}).get(provider, {}).get("blacklist", [])
for m in sorted(bl):
    print(m)
PY
}

# ---- Probe Classification ----------------------------------------------------
# Probe a single model using the existing worker and classify the result
probe_model_classify() {
	local model="$1"
	local timeout_secs="${2:-$OCPROBE_VALIDATE_PROBE_TIMEOUT}"
	local prompt="${3:-$OCPROBE_VALIDATE_PROBE_PROMPT}"

	local worker_file
	worker_file=$(mktemp "${OCPROBE_RUN_DIR}/worker.XXXXXX")
	write_worker "$worker_file"

	local start_ms end_ms
	start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')

	# Run worker and capture stdout only (stderr has SESSION_ID marker)
	local output
	output=$("$worker_file" "$model" "VALIDATE" "$timeout_secs" "$prompt" 2>/dev/null)
	local ec=$?

	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')

	local latency=$((end_ms - start_ms))

	rm -f "$worker_file"

	# Parse worker output (TSV: src\tmodel\tstatus\tlatency)
	local status
	if [[ $ec -eq 0 && -n "$output" ]]; then
		# Worker succeeded, parse its classification
		status=$(printf '%s' "$output" | awk -F'\t' '{print $3}')
		# Map worker statuses to validate statuses
		case "$status" in
		WORKS) status="WORKS" ;;
		PAYWALLED) status="BILLING_ERROR" ;;
		EOL) status="NOT_FOUND" ;;
		NOTFOUND) status="NOT_FOUND" ;;
		BROKEN) status="ERROR" ;;
		ERROR) status="ERROR" ;;
		TIMEOUT) status="TIMEOUT" ;;
		*) status="UNCLEAR" ;;
		esac
	elif [[ $ec -eq 124 ]] || [[ $ec -eq 137 ]] || [[ $ec -eq 142 ]]; then
		status="TIMEOUT"
	else
		# Worker failed to run or produced no output
		status="ERROR"
	fi

	printf '%s\t%s\t%d\n' "$model" "$status" "$latency"
}

# Probe models sequentially (reliable, simpler)
probe_models_batch() {
	local provider_id="$1"
	local models_file="$2"
	local results_file="$3"

	local count
	count=$(wc -l <"$models_file" | tr -d ' ')
	[[ $count -eq 0 ]] && return 0

	log_info "Probing $count models for provider $provider_id..."

	local skipped_count=0
	while IFS= read -r model; do
		[[ -n "$model" ]] || continue
		if is_modality_skip "$model"; then
			# Modality-skip: write SKIPPED_MODALITY status without probing
			echo -e "${model}\tSKIPPED_MODALITY\t0" >>"$results_file"
			skipped_count=$((skipped_count + 1))
			continue
		fi
		result=$(probe_model_classify "$model")
		echo "$result" >>"$results_file"
	done <"$models_file"

	[[ $skipped_count -gt 0 ]] && log_info "Skipped $skipped_count modality-excluded models for provider $provider_id"
}

# ---- Blacklist Management ----------------------------------------------------
# Generate proposed blacklist from probe results (uses two-failure gate)
generate_blacklist_proposal() {
	local provider_id="$1"
	local results_file="$2"
	local proposal_file="$3"

	local tentative_file="${proposal_file}.tentative"
	generate_validate_classification "$provider_id" "$results_file" "$proposal_file" "$tentative_file"
	# Clean up tentative file (used for reporting only)
	rm -f "$tentative_file"
}

# Show diff between current and proposed blacklist
show_blacklist_diff() {
	local provider_id="$1"
	local current_file="$2"
	local proposed_file="$3"

	local current_proposed
	current_proposed=$(mktemp "${OCPROBE_RUN_DIR}/cp.XXXXXX")
	sort -u "$current_file" "$proposed_file" | sort | uniq -c | while read -r count model; do
		if [[ $count -eq 1 ]]; then
			# Only in one of the files
			if grep -qxF "$model" "$current_file"; then
				echo "- $model (would be removed from blacklist)"
			else
				echo "+ $model (would be added to blacklist)"
			fi
		fi
	done >"$current_proposed"

	if [[ -s "$current_proposed" ]]; then
		echo "Provider: $provider_id"
		cat "$current_proposed"
		echo
	else
		log_info "Provider $provider_id: No changes to blacklist"
	fi

	rm -f "$current_proposed"
}

# Apply blacklist to opencode.json
apply_blacklist() {
	local provider_id="$1"
	local blacklist_file="$2"

	# Read blacklist into array
	local -a blacklist=()
	while IFS= read -r model; do
		[[ -n "$model" ]] && blacklist+=("$model")
	done <"$blacklist_file"

	python3 - "$OCPROBE_OPencode_CONFIG" "$provider_id" "$(printf '%s\n' "${blacklist[@]}")" <<'PY'
import json, sys, os

config_path = os.path.expanduser(sys.argv[1])
provider_id = sys.argv[2]
blacklist = sys.argv[3].splitlines() if sys.argv[3] else []

with open(config_path) as f:
    cfg = json.load(f)

providers = cfg.setdefault("provider", {})
provider = providers.setdefault(provider_id, {})
provider["blacklist"] = sorted(set(blacklist))

# Write atomically
tmp = config_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, config_path)

print("Applied blacklist for provider:", provider_id, "with", len(blacklist), "models")
PY
}

# Verify that the blacklist actually took effect by checking model visibility
verify_blacklist_effect() {
	local provider_id="$1"
	local expected_blacklist_file="$2"

	# Get currently visible models for this provider (models not blacklisted)
	local visible_models
	visible_models=$(opencode models "$provider_id" 2>/dev/null | sort -u)

	# Read expected blacklist
	local -a expected_blacklist=()
	while IFS= read -r model; do
		[[ -n "$model" ]] && expected_blacklist+=("$model")
	done <"$expected_blacklist_file"

	# Check if any blacklisted models are still visible
	local failed=0
	for model in "${expected_blacklist[@]}"; do
		if printf '%s\n' "$visible_models" | grep -qxF "$model"; then
			log_warn "Blacklist may not have taken effect: $model still visible in picker"
			failed=1
		fi
	done

	return $failed
}

# ---- Backup/Restore ----------------------------------------------------------
# Create backup of current opencode.json
backup_opencode_config() {
	local state_dir="${OCPROBE_STATE_DIR:-$HOME/.local/state/ocprobe}"
	mkdir -p "$state_dir/validate-backups"
	local backup_file
	backup_file="$state_dir/validate-backups/opencode.json.backup-$(date +%Y%m%d-%H%M%S)"
	cp "$OCPROBE_OPencode_CONFIG" "$backup_file"
	echo "$backup_file"
}

# Get latest backup file
get_latest_backup() {
	local state_dir="${OCPROBE_STATE_DIR:-$HOME/.local/state/ocprobe}"
	# Portable: use ls -t (sort by modification time, newest first)
	# shellcheck disable=SC2012  # backup filenames are controlled pattern, ls -t is safe here
	ls -1t "$state_dir/validate-backups"/opencode.json.backup-* 2>/dev/null | head -1
}

# Restore from latest backup
restore_from_backup() {
	local backup_file
	backup_file=$(get_latest_backup)
	[[ -n "$backup_file" ]] || die "No backup found to restore from"

	cp "$backup_file" "$OCPROBE_OPencode_CONFIG"
	log_info "Restored from backup: $backup_file"
	echo "$backup_file"
}

# ---- Main Command Logic ------------------------------------------------------
cmd_validate() {
	local apply_mode=0
	local restore_mode=0
	local target_provider=""
	local target_model=""
	local json_output=0

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--apply) apply_mode=1 ;;
		--provider)
			target_provider="$2"
			shift
			;;
		--provider=*) target_provider="${1#*=}" ;;
		--model)
			target_model="$2"
			shift
			;;
		--model=*) target_model="${1#*=}" ;;
		--json) json_output=1 ;;
		restore) restore_mode=1 ;;
		-h | --help)
			cat <<'EOF'
ocprobe validate — Probe all models for configured providers and blacklist failures

USAGE:
  ocprobe validate [--provider <id>] [--model <id>] [--apply]
  ocprobe validate restore

OPTIONS:
  --provider <id>   Only validate models for this provider
  --model <id>      Only validate this specific model (requires --provider)
  --apply           Apply blacklist changes to opencode.json (default: dry-run)
  --json            Output JSON (machine-readable)
  restore           Restore opencode.json from last validate backup

BEHAVIOR:
  1. Finds providers with valid API keys in auth.json
  2. For each provider, fetches ALL available models via `opencode models`
  3. Probes each model with a minimal test prompt
  4. Classifies: WORKS / TIMEOUT / AUTH_ERROR / BILLING_ERROR / NOT_FOUND / ERROR
  5. Proposed blacklist = all non-WORKS models
  6. Default (dry-run): Shows diff of what would change
  7. --apply: Backs up opencode.json, writes blacklist, verifies effect
  8. restore: Reverts to last validate backup, verifies restore

NOTES:
  - Uses blacklist (additive) not whitelist (would hide unprobed models)
  - Every run re-probes fresh; no cached/stale blacklisting
  - Verifies actual picker visibility after apply (OpenCode bug #32528)
EOF
			return 0
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
		shift
	done

	load_config
	validate_opencode_config
	validate_auth_file

	if [[ $restore_mode -eq 1 ]]; then
		cmd_validate_restore
		return $?
	fi

	# Phase 1: Acquire lock, discover providers & models, release lock
	acquire_lock
	local -a providers=()
	if [[ -n "$target_provider" ]]; then
		if python3 - "$OCPROBE_OPencode_AUTH" "$target_provider" -c '
import json,sys,os
with open(os.path.expanduser(sys.argv[1])) as f: auth=json.load(f)
pid=sys.argv[2]
if pid in auth and auth[pid].get("type")=="api" and auth[pid].get("key"):
    sys.exit(0)
else:
    sys.exit(1)
'; then
			providers=("$target_provider")
		else
			release_lock
			die "Provider '$target_provider' not found or has no valid credentials"
		fi
	else
		mapfile -t providers < <(get_configured_providers)
	fi

	# Capture config hash for staleness detection (TOCTOU guard)
	local config_hash
	config_hash=$(sha256sum "$OCPROBE_OPencode_CONFIG" | awk '{print $1}')

	release_lock

	[[ ${#providers[@]} -gt 0 ]] || die "No providers with valid credentials found"

	log_info "=== ocprobe validate $(date) ==="
	audit_log "=== validate run start apply=$apply_mode provider=${target_provider:-all} ==="
	log_info "Validating providers: ${providers[*]}"

	# Phase 2: Probe all models (NO lock held - avoids FD leakage to command substitutions)
	local all_results_file="$OCPROBE_RUN_DIR/all_results.tsv"
	: >"$all_results_file"

	for provider_id in "${providers[@]}"; do
		log_info "Processing provider: $provider_id"

		local models_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.models.txt"
		if [[ -n "$target_model" ]]; then
			echo "$target_model" >"$models_file"
		else
			get_provider_models "$provider_id" >"$models_file"
		fi

		local model_count
		model_count=$(wc -l <"$models_file" | tr -d ' ')
		log_info "Provider $provider_id: $model_count models to probe"

		local results_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.results.tsv"
		: >"$results_file"
		probe_models_batch "$provider_id" "$models_file" "$results_file"

		cat "$results_file" >>"$all_results_file"
	done

	# Phase 3: Generate proposals & diffs (still no lock needed)
	local -a provider_results=()
	local overall_changes=0

	for provider_id in "${providers[@]}"; do
		local results_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.results.tsv"
		local current_blacklist_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.current_blacklist.txt"
		get_current_blacklist "$provider_id" >"$current_blacklist_file"

		local proposed_blacklist_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.proposed_blacklist.txt"
		generate_blacklist_proposal "$provider_id" "$results_file" "$proposed_blacklist_file"

		# Count skipped modality and tentative models for reporting
		local skipped_count=0 tentative_count=0
		skipped_count=$(awk -F'\t' '$2 == "SKIPPED_MODALITY" {count++} END {print count+0}' "$results_file")
		local tentative_file="${proposed_blacklist_file}.tentative"
		[[ -f "$tentative_file" ]] && tentative_count=$(wc -l <"$tentative_file" | tr -d ' ')

		if [[ $json_output -eq 1 ]]; then
			python3 - "$provider_id" "$results_file" "$current_blacklist_file" "$proposed_blacklist_file" "$skipped_count" "$tentative_count" <<'PY'
import json, sys, os

provider_id = sys.argv[1]
results_file = sys.argv[2]
current_file = sys.argv[3]
proposed_file = sys.argv[4]
skipped_count = int(sys.argv[5])
tentative_count = int(sys.argv[6])

results = []
with open(results_file) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3:
            results.append({"model": parts[0], "status": parts[1], "latency_ms": int(parts[2])})

with open(current_file) as f:
    current = [l.strip() for l in f if l.strip()]

with open(proposed_file) as f:
    proposed = [l.strip() for l in f if l.strip()]

current_set = set(current)
proposed_set = set(proposed)

additions = sorted(proposed_set - current_set)
removals = sorted(current_set - proposed_set)

print(json.dumps({
    "provider": provider_id,
    "total_probed": len(results),
    "works": len([r for r in results if r["status"] == "WORKS"]),
    "failures": len([r for r in results if r["status"] != "WORKS"]),
    "skipped_modality": skipped_count,
    "tentative": tentative_count,
    "status_breakdown": {
        s: len([r for r in results if r["status"] == s])
        for s in ["WORKS", "TIMEOUT", "AUTH_ERROR", "BILLING_ERROR", "NOT_FOUND", "ERROR", "UNCLEAR", "SKIPPED_MODALITY"]
    },
    "current_blacklist_count": len(current),
    "proposed_blacklist_count": len(proposed),
    "additions": additions,
    "removals": removals
}, indent=2))
PY
		else
			show_blacklist_diff "$provider_id" "$current_blacklist_file" "$proposed_blacklist_file"
			[[ $skipped_count -gt 0 ]] && echo "    Skipped (modality): $skipped_count"
			[[ $tentative_count -gt 0 ]] && echo "    Tentative (watching): $tentative_count"
		fi

		local additions_count removals_count
		additions_count=$(comm -13 <(sort "$current_blacklist_file") <(sort "$proposed_blacklist_file") | wc -l | tr -d ' ')
		removals_count=$(comm -23 <(sort "$current_blacklist_file") <(sort "$proposed_blacklist_file") | wc -l | tr -d ' ')

		if [[ $additions_count -gt 0 ]] || [[ $removals_count -gt 0 ]]; then
			overall_changes=1
			provider_results+=("$provider_id:$proposed_blacklist_file:$additions_count:$removals_count")
		else
			log_info "Provider $provider_id: No changes needed"
		fi
	done

	# Phase 4: Apply changes (re-acquire lock only for write phase)
	if [[ $apply_mode -eq 1 && $overall_changes -eq 1 ]]; then
		acquire_lock
		trap 'release_lock; cleanup_run_dir' EXIT INT TERM

		# Staleness guard: verify opencode.json hasn't changed since Phase 1
		local current_hash
		current_hash=$(sha256sum "$OCPROBE_OPencode_CONFIG" | awk '{print $1}')
		if [[ "$current_hash" != "$config_hash" ]]; then
			release_lock
			die "Config changed since discovery (hash mismatch). Re-run validate to get fresh results."
		fi

		for entry in "${provider_results[@]}"; do
			IFS=':' read -r provider_id proposed_blacklist_file additions_count removals_count <<<"$entry"
			log_info "Applying blacklist for $provider_id..."
			local backup_file
			backup_file=$(backup_opencode_config)
			log_info "Backup created: $backup_file"

			apply_blacklist "$provider_id" "$proposed_blacklist_file"

			log_info "Verifying blacklist effect..."
			if verify_blacklist_effect "$provider_id" "$proposed_blacklist_file"; then
				log_info "SUCCESS: Blacklist applied and verified for $provider_id"
			else
				log_warn "WARNING: Blacklist written but verification failed (OpenCode bug #32528?)"
				log_warn "The config was written but models may still appear in picker"
				log_warn "Run 'opencode models $provider_id' to check actual visibility"
			fi
		done

		log_info "Validate complete. Changes applied."
	elif [[ $apply_mode -eq 0 && $overall_changes -eq 1 ]]; then
		log_info "Validate complete (dry-run). Changes pending. Run with --apply to write."
		return 1
	else
		log_info "Validate complete. No changes needed."
		return 0
	fi
}

cmd_validate_restore() {
	log_info "=== ocprobe validate restore $(date) ==="
	audit_log "=== validate restore run start ==="

	load_config
	validate_opencode_config

	acquire_lock
	trap 'release_lock; cleanup_run_dir' EXIT INT TERM

	local backup_file
	backup_file=$(restore_from_backup)

	# Verify restore
	if [[ -f "$backup_file" ]]; then
		# Compare restored config with backup
		if diff -q "$OCPROBE_OPencode_CONFIG" "$backup_file" >/dev/null; then
			log_info "SUCCESS: Config restored and verified from $backup_file"
		else
			log_warn "WARNING: Restore wrote file but content differs from backup"
			exit 1
		fi
	else
		die "Backup file missing after restore: $backup_file"
	fi
}
