#!/usr/bin/env bash
set -uo pipefail
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
: "${OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT:=40}"
: "${OCPROBE_VALIDATE_VERBOSE:=0}"
: "${OCPROBE_VALIDATE_PROGRESS_INTERVAL:=25}"
: "${OCPROBE_VALIDATE_LARGE_RUN_THRESHOLD:=200}"

# Sentinel returned by _validate_history_locked() when the history lock could not
# be acquired within its timeout, so the history update for that model was
# SKIPPED rather than performed unsynchronised. Distinct from 0 (ok), 1 and 2
# (ordinary failures) so callers can tell the two apart. EX_TEMPFAIL semantics:
# the work was not done, retry later.
OCPROBE_HISTORY_SKIPPED=75

# ---- Modality Skip Patterns ---------------------------------------------------
# Local glob matcher — semantics intentionally match policy_glob_match()
# in lib/policy.sh (case-sensitive, * matches /, ? = one char) but this
# is a deliberately separate, non-shared copy for this track.
# This decouples validate's modality skip from the experimental policy engine
# so that modality skips remain stable even if policy engine changes.
# See feature/validate-hardening design notes: do not merge with policy.sh.
# shellcheck disable=SC2053
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
	local skip_file="${OCPROBE_CONFIG_DIR:-}/validate-skip-patterns.txt"
	local user_skip_file="$OCPROBE_STATE_DIR/validate-skip-patterns-user.txt"
	local patterns_file

	# Warn once if defaults file is missing (fail-open: skip modality matching for defaults)
	if [[ ! -f "$skip_file" ]]; then
		if [[ -z "${OCPROBE_VALIDATE_SKIP_WARNED:-}" ]]; then
			log_warn "Modality skip defaults not found at $skip_file — SKIPPED_MODALITY will not trigger for default patterns this run (user extension file, if any, still applies)"
			declare -g OCPROBE_VALIDATE_SKIP_WARNED=1
		fi
	fi

	# Build combined patterns file (defaults + user extensions)
	patterns_file=$(mktemp)
	[[ -f "$skip_file" ]] && cat "$skip_file" >"$patterns_file"
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

# load_validate_history() — populates VALIDATE_FAIL_COUNT from validate-history.jsonl
# For each model, reconstructs consecutive non-WORKS streak from end of its history:
# - WORKS → streak = 0 (resets)
# - EOL / NOT_FOUND → streak = 2 (confirmed immediately)
# - Other non-WORKS → streak += 1 (capped at 2)
# Uses safe_key pattern (model with / replaced by _) same as lib/models.sh
load_validate_history() {
	local -n fail_count=$1

	# Same fold, same map as the per-model streak lookup, so the two views can
	# never disagree. _validate_streak_sync rebuilds only if the file changed.
	_validate_streak_sync

	local k
	# shellcheck disable=SC2034  # fail_count is a nameref; shellcheck cannot see the caller's array
	for k in "${!_VALIDATE_HISTREAK[@]}"; do
		fail_count["$k"]="${_VALIDATE_HISTREAK[$k]}"
	done
}

# ---- History streak cache -----------------------------------------------------
# A model's streak depends ONLY on that model's own lines, in file order. The old
# _validate_history_streak exploited that by re-reading the whole file and keeping
# only the matching lines -- but it did that once PER MODEL, and it spawned TWO awk
# processes per line to pull out $1 and $2. That is O(models x history) with a
# process spawn per field, which is where "~2.4 hours for one validate run" at the
# real catalog size (~941 models) came from.
#
# Instead: fold the file ONCE into a per-model streak map, then every lookup is a
# single hash read. Semantics are unchanged. _validate_streak_apply is the same
# case statement the per-model scanner used, applied in the same file order, and
# an append only ever extends ONE model's own sequence -- so advancing just that
# model's entry is identical to rescanning the file. The map is dropped and
# rebuilt only when the file stops matching what we folded (see
# _validate_streak_sync and record_validate_history).
declare -gA _VALIDATE_HISTREAK=()
declare -g _VALIDATE_HISTREAK_BYTES=-1

# _validate_streak_apply <safe_key> <status> — one fold step, in place.
# WORKS resets to 0, EOL/NOT_FOUND confirm at 2, anything else counts up capped at 2.
_validate_streak_apply() {
	local key="$1" status="$2"
	case "$status" in
	WORKS) _VALIDATE_HISTREAK["$key"]=0 ;;
	EOL | NOT_FOUND) _VALIDATE_HISTREAK["$key"]=2 ;;
	*)
		local cur="${_VALIDATE_HISTREAK[$key]:-0}"
		_VALIDATE_HISTREAK["$key"]=$((cur < 2 ? cur + 1 : 2))
		;;
	esac
}

# _validate_history_size — byte size of the history file, or -1 if absent.
# Byte size is the cheap invalidation token: it changes on any append and on any
# prune_jsonl rewrite, and costs one wc.
_validate_history_size() {
	local f="$OCPROBE_STATE_DIR/validate-history.jsonl"
	[[ -f "$f" ]] || {
		printf '%s\n' -1
		return 0
	}
	wc -c <"$f" | tr -d '[:space:]'
}

# _validate_streak_rebuild — fold the entire file once. O(lines), no forks.
_validate_streak_rebuild() {
	_VALIDATE_HISTREAK=()
	local f="$OCPROBE_STATE_DIR/validate-history.jsonl"
	_VALIDATE_HISTREAK_BYTES=-1
	[[ -f "$f" ]] || return 0
	_VALIDATE_HISTREAK_BYTES=$(_validate_history_size)
	# `read` with the default IFS splits on runs of spaces/tabs exactly as awk's
	# $1/$2 did, but without a fork. The third field absorbs the rest of the line
	# so `status` is field 2 alone, matching awk rather than read's 2-var form.
	local model status _rest
	while read -r model status _rest; do
		[[ -n "$model" && -n "$status" ]] || continue
		_validate_streak_apply "${model//\//_}" "$status"
	done <"$f"
	return 0
}

# _validate_streak_sync — rebuild only if the file differs from what we folded.
# Covers another process appending, and our own append that got pruned away.
_validate_streak_sync() {
	local size
	size=$(_validate_history_size)
	[[ "$size" == "$_VALIDATE_HISTREAK_BYTES" ]] && return 0
	_validate_streak_rebuild
}

# _validate_history_streak(model) — consecutive non-WORKS streak for ONE model.
# Echoes the streak; see _validate_history_streak_into for the form the
# classification loop uses.
_validate_history_streak() {
	_validate_history_streak_into "$1"
	printf '%s\n' "$_VALIDATE_LAST_STREAK"
}

# _VALIDATE_LAST_STREAK carries a streak back to the caller without a command
# substitution. `$( )` runs in a subshell, so any cache work done inside one is
# thrown away when it exits — which is exactly what would undo the single-pass
# fold above and put us back to one file scan per model. Assigning a global
# keeps the work in the caller's shell.
declare -g _VALIDATE_LAST_STREAK=0

# _validate_history_streak_into <model> — as above, but assigns
# _VALIDATE_LAST_STREAK instead of echoing. An empty model can never match a
# history line (lines with an empty model field are skipped when folding), and
# "" is not a legal associative-array subscript, so answer 0 directly — the same
# result the old per-model scanner gave, without a "bad array subscript" error.
_validate_history_streak_into() {
	local safe_key="${1//\//_}"
	if [[ -z "$safe_key" ]]; then
		_VALIDATE_LAST_STREAK=0
		return 0
	fi
	_validate_streak_sync
	_VALIDATE_LAST_STREAK="${_VALIDATE_HISTREAK[$safe_key]:-0}"
}

# _validate_history_locked(fn, args...) — run fn with the history-scoped lock
# held, guaranteeing the release on every path (success, failure, or early
# return inside fn). The lock covers ONLY this short read-decide-write; it is
# never held across a network probe, so probing concurrency is unchanged, and it
# is a separate lock from acquire_lock() so it cannot serialize the rest of a run.
#
# FAILS CLOSED on lock timeout. The callback is NOT run unlocked: doing so would
# re-open the exact read-decide-write race this lock exists to prevent, precisely
# when contention makes it most likely. Instead the history update for this model
# is skipped and OCPROBE_HISTORY_SKIPPED is returned so callers can tell "skipped
# for lock contention" apart from "callback ran and failed". No data is lost — the
# streak simply does not advance or reset this cycle, and the model is
# re-evaluated on the next validate run.
#
# Note the retry already lives in _acquire_scoped_lock (50 x 0.1s, ~5s), so the
# callback is only skipped after a real 5s stall, not on a momentary collision.
_validate_history_locked() {
	local lock_dir="$OCPROBE_STATE_DIR/.validate-history.lock"

	if ! _acquire_scoped_lock "$lock_dir"; then
		log_warn "validate: history update SKIPPED this run due to lock contention ($lock_dir); no streak change was recorded and the model will be re-evaluated on the next validate run"
		return "$OCPROBE_HISTORY_SKIPPED"
	fi

	local rc=0
	"$@" || rc=$?
	_release_scoped_lock "$lock_dir"
	return $rc
}

# _validate_report_skipped(model, proposal_file, tentative_file)
# Fallback used ONLY when the history lock timed out and the persistent write was
# skipped (OCPROBE_HISTORY_SKIPPED). The run must still report what the probe it
# just performed found, so this classifies from an unlocked read and emits the
# same TENTATIVE/CONFIRMED line the locked path would have — but writes nothing
# to the history file. A read cannot corrupt the file, so doing it unlocked is
# safe. Echoes the streak the caller should keep in memory.
_validate_report_skipped() {
	local model="$1" proposal_file="$2" tentative_file="$3"

	_validate_history_streak_into "$model"

	if [[ "$_VALIDATE_LAST_STREAK" -eq 0 ]]; then
		echo "$model" >>"$tentative_file"
		_VALIDATE_LAST_STREAK=1
	else
		echo "$model" >>"$proposal_file"
		_VALIDATE_LAST_STREAK=2
	fi
}

# _validate_record_failure(model, status, proposal_file, tentative_file)
# Atomic read-decide-write for one model's non-terminal failure: the streak is
# re-read from the file *while the history lock is held*, so two concurrent
# validate runs cannot both decide from the same stale count (which would let
# both confirm on one real failure, or both stay tentative so a dead model is
# never confirmed). Echoes the streak after the write.
_validate_record_failure() {
	local model="$1" status="$2" proposal_file="$3" tentative_file="$4"

	_validate_history_streak_into "$model"

	if [[ "$_VALIDATE_LAST_STREAK" -eq 0 ]]; then
		record_validate_history "$model" "$status"
		echo "$model" >>"$tentative_file"
		_VALIDATE_LAST_STREAK=1
	else
		record_validate_history "$model" "$status"
		echo "$model" >>"$proposal_file"
		_VALIDATE_LAST_STREAK=2
	fi
}

# _validate_record_success(model) — atomic: if this model has a live failure
# streak, clear it with a WORKS record. Streak re-read under the lock so a
# concurrent run's record cannot be lost. Echoes the streak after the reset.
_validate_record_success() {
	local model="$1"

	_validate_history_streak_into "$model"

	if [[ "$_VALIDATE_LAST_STREAK" -gt 0 ]]; then
		record_validate_history "$model" "WORKS"
		_VALIDATE_LAST_STREAK=0
	fi
}

# record_validate_history(model, status) — append one line, then prune_jsonl
# Reuses the generic prune_jsonl utility from lib/db.sh (pure utility, not audit-specific)
# NOTE: the append+prune pair is not atomic on its own (prune_jsonl rewrites the
# file via tail+mv), so callers that race on a shared history file must hold the
# history-scoped lock — see _validate_history_locked.
record_validate_history() {
	local model="$1" status="$2"
	local history_file="$OCPROBE_STATE_DIR/validate-history.jsonl"
	mkdir -p "$(dirname "$history_file")"
	# Portable millisecond timestamp: python for cross-platform support
	local timestamp
	timestamp=$(python3 -c 'import time; print(int(time.time() * 1000))')

	# Bring the folded map in line with the file BEFORE appending. The
	# incremental step below is only valid on top of a map that already matches
	# the file; without this, anything that changed the file behind our back
	# (another process, a prune, a rewritten file) would leave us folding onto a
	# stale value. In the steady state this is a single wc and no rebuild,
	# because the previous record already recorded the size it left behind.
	_validate_streak_sync

	# Size before the append, so a prune_jsonl rewrite below can be told apart
	# from a plain append.
	local before
	before=$(_validate_history_size)
	[[ "$before" == "-1" ]] && before=0

	local line
	line=$(printf '%s\t%s\t%d' "$model" "$status" "$timestamp")
	printf '%s\n' "$line" >>"$history_file"
	prune_jsonl "$history_file" "$OCPROBE_HISTORY_LIMIT"

	# Keep the folded map in step with the file we just wrote, so the NEXT
	# model's lookup is O(1) rather than a rescan — that is what makes a run
	# linear in models instead of quadratic. If the size is not exactly
	# before+len(line)+1 then prune_jsonl rewrote the file and dropped lines we
	# had already folded in, so the map can no longer be trusted: drop it and let
	# the next read rebuild from the file.
	local after
	after=$(_validate_history_size)
	if [[ "$after" == "$((before + ${#line} + 1))" ]]; then
		_validate_streak_apply "${model//\//_}" "$status"
		_VALIDATE_HISTREAK_BYTES="$after"
	else
		_VALIDATE_HISTREAK=()
		_VALIDATE_HISTREAK_BYTES=-1
	fi
}

# ---- Validate Classification ---------------------------------------------------
# generate_validate_classification() — two-consecutive-failure state machine
# For each model in results_file (including WORKS and SKIPPED_MODALITY):
#   - WORKS → reset count to 0, record history if count was > 0
#   - SKIPPED_MODALITY → no-op for gate
#   - EOL / NOT_FOUND → CONFIRMED immediately
#   - Other non-WORKS → check VALIDATE_FAIL_COUNT:
#       0 (first time) → TENTATIVE, record failure, do NOT add to blacklist
#       >=1 (second consecutive) → CONFIRMED, add to blacklist
# Output: proposal file (CONFIRMED only), tentative_file (TENTATIVE only)
# VALIDATE_FAIL_COUNT is assigned but never read inside this function: it is a
# global associative array published for the caller to consume.
# shellcheck disable=SC2034
generate_validate_classification() {
	local provider_id="$1"
	local results_file="$2"
	local proposal_file="$3"
	local tentative_file="$4"

	: >"$proposal_file"
	: >"$tentative_file"

	[[ -s "$results_file" ]] || return 0

	# Load history for this run
	# shellcheck disable=SC2034  # VALIDATE_FAIL_COUNT is a global associative array used by caller
	declare -gA VALIDATE_FAIL_COUNT=()
	load_validate_history VALIDATE_FAIL_COUNT

	local model status
	while IFS=$'\t' read -r model status _lat; do
		[[ -n "$model" ]] || continue
		local safe_key="${model//\//_}"

		case "$status" in
		WORKS)
			# Reset failure count on success. Atomic read-decide-write: re-reads the
			# streak under the history lock so a concurrent run's record is not lost.
			# On a skipped write the streak simply is not reset; keep the real current
			# value rather than the sentinel so nothing downstream sees "75".
			local works_rc=0
			_validate_history_locked _validate_record_success "$model" || works_rc=$?
			VALIDATE_FAIL_COUNT["$safe_key"]="$_VALIDATE_LAST_STREAK"
			if [[ $works_rc -eq "$OCPROBE_HISTORY_SKIPPED" ]]; then
				_validate_history_streak_into "$model"
				VALIDATE_FAIL_COUNT["$safe_key"]="$_VALIDATE_LAST_STREAK"
			fi
			;;
		EOL | NOT_FOUND)
			# Terminal failures — confirm immediately regardless of history
			echo "$model" >>"$proposal_file"
			VALIDATE_FAIL_COUNT["$safe_key"]=2 # mark as confirmed
			# The rc must be consumed, not left bare: these libs run under `set -e`
			# (locking.sh sets -euo pipefail and validate.sh does not clear it), so an
			# unconsumed OCPROBE_HISTORY_SKIPPED would abort the whole run here. This
			# run's user-visible report is already emitted above, so a skipped write
			# only means the persistent streak does not advance (re-evaluated next run).
			local eol_rc=0
			_validate_history_locked record_validate_history "$model" "$status" || eol_rc=$?
			;;
		SKIPPED_MODALITY)
			# Already filtered out by generate_blacklist_proposal, but handle gracefully
			;;
		BILLING_ERROR)
			# The ACCOUNT cannot afford this model's default output size — the model
			# itself is fine and works as soon as credits exist. Blacklisting it would
			# permanently hide working models from a free / credit-limited key, which
			# is the opposite of what the user asked for. Report, never blacklist, and
			# do not let it count toward the two-strike gate.
			VALIDATE_FAIL_COUNT["$safe_key"]=0
			# rc consumed for the same `set -e` reason as the EOL/NOT_FOUND branch:
			# a bare non-zero return would abort the run. The report below is
			# unconditional and does not depend on the history write.
			local bill_rc=0
			_validate_history_locked record_validate_history "$model" "$status" || bill_rc=$?
			printf '%s\tBILLING_ERROR\n' "$model" >>"${tentative_file}.billing"
			;;
		*)
			# Other failures: TIMEOUT, AUTH_ERROR, ERROR, UNCLEAR
			# Atomic read-decide-write under the history lock — this is the two-strike
			# gate decision, and it must not be taken twice from the same stale count.
			# If the lock timed out, the persistent write is skipped but this run still
			# reports its classification from the probe that just happened.
			local fail_rc=0
			_validate_history_locked _validate_record_failure "$model" "$status" "$proposal_file" "$tentative_file" || fail_rc=$?
			VALIDATE_FAIL_COUNT["$safe_key"]="$_VALIDATE_LAST_STREAK"
			if [[ $fail_rc -eq "$OCPROBE_HISTORY_SKIPPED" ]]; then
				_validate_report_skipped "$model" "$proposal_file" "$tentative_file"
				VALIDATE_FAIL_COUNT["$safe_key"]="$_VALIDATE_LAST_STREAK"
			fi
			;;
		esac
	done <"$results_file"
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
# shellcheck disable=SC2329
# ---- Validate-Local Worker (AUTH_ERROR detection) ---------------------------------
# Captures FULL raw response text from opencode run --format json
# and performs auth-pattern detection locally within validate.sh.
# Does NOT modify lib/models.sh's write_worker() to avoid ripple effects.
# shellcheck disable=SC2329
write_validate_worker() {
	local worker_file="$1"
	cat >"$worker_file" <<'WORKER'
#!/usr/bin/env bash
set -u
m="$1"; src="$2"; secs="$3"; prompt="$4"
# Validate model name
[[ "$m" =~ ^[a-zA-Z0-9_./:~:-]+$ ]] || { echo "INVALID_MODEL: $m" >&2; exit 1; }
# Validate timeout
[[ "$secs" =~ ^[0-9]+$ ]] && [[ "$secs" -gt 0 ]] || { echo "INVALID_TIMEOUT" >&2; exit 1; }
t0=$(python3 -c 'import time; print(int(time.time() * 1000))')
# Portable timeout with --format json for sessionID capture
if command -v timeout >/dev/null 2>&1; then
  res=$(timeout "$secs" opencode run --pure --title ocprobe-validate --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
else
  res=$(perl -e 'alarm $ARGV[0]; exec @ARGV[1..$#ARGV] or exit 127' "$secs" opencode run --pure --title ocprobe-validate --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
fi
t1=$(python3 -c 'import time; print(int(time.time() * 1000))')

# Parse JSON events from opencode --format json output
# Each line is a JSON event; look for status event or error event
st=UNCLEAR
err_msg=""
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # Try to extract status from status events
  if printf '%s' "$line" | grep -q '"type":"status"'; then
    st=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","UNCLEAR"))' 2>/dev/null)
    [[ -n "$st" ]] && break
  # Try to extract error type from error events
  elif printf '%s' "$line" | grep -q '"type":"error"'; then
    err_type=$(printf '%s' "$line" | python3 -c 'import sys,json; d=json.load(sys.stdin); err=d.get("error",{}); print(err.get("data",{}).get("message",""))' 2>/dev/null)
    err_msg="$err_type"
    # Credit/quota limits are an ACCOUNT condition, not model death. opencode sends
    # the model's default max output tokens (e.g. 16384, hardcoded from model
    # metadata — no config knob lowers it), so on a free or credit-limited key every
    # paid model returns 402 "requires more credits ... can only afford 102" even
    # though the model works. Must map to BILLING_ERROR, never to ERROR/NOT_FOUND,
    # or a free-tier key would blacklist every paid model it cannot afford.
    if printf '%s' "$err_type" | grep -Eqi 'no payment method|requires more credits|insufficient credits|not enough credit|not enough balance|can only afford|payment required|billing|quota (exceeded|insufficient)|402'; then st=PAYWALLED; break
    elif printf '%s' "$err_type" | grep -qi 'end of life\|^Gone'; then st=EOL; break
    elif printf '%s' "$err_type" | grep -q '404'; then st=NOTFOUND; break
    elif printf '%s' "$err_type" | grep -qi 'Error'; then st=BROKEN; break
    else st=ERROR; break
    fi
  fi
done <<<"$res"

# If no status from JSON events, fall back to string matching on full output
if [[ "$st" == "UNCLEAR" ]]; then
  if   printf '%s' "$res" | grep -Eqi 'no payment method|requires more credits|insufficient credits|not enough credit|not enough balance|can only afford|payment required|billing|quota (exceeded|insufficient)|402'; then st=PAYWALLED
  elif printf '%s' "$res" | grep -qi 'end of life\|^Gone'; then st=EOL
  elif printf '%s' "$res" | grep -q '404';                 then st=NOTFOUND
  elif printf '%s' "$res" | grep -qi 'Error:';              then st=BROKEN
  elif printf '%s' "$res" | grep -qE '(^|[^a-zA-Z])OK([[:punct:][:space:]]|$)'; then st=WORKS
  elif [[ $rc -eq 127 ]];                                   then st=ERROR
  elif [[ $rc -ne 0 ]];                                     then st=TIMEOUT
  else st=UNCLEAR; fi
fi

# Map to the validate status vocabulary here, inside the worker, so the worker is
# fully self-contained. Previously auth detection happened in the parent via a
# SHARED temp file (.validate_raw_response) — that made concurrent probing unsafe.
case "$st" in
  WORKS) v=WORKS ;;
  PAYWALLED) v=BILLING_ERROR ;;
  EOL|NOTFOUND) v=NOT_FOUND ;;
  BROKEN|ERROR) v=ERROR ;;
  TIMEOUT) v=TIMEOUT ;;
  *) v=UNCLEAR ;;
esac

# Auth detection.
# Scan ONLY the error message, never the whole event stream: opencode emits JSON
# containing timestamps and ids, so a bare `401|403` substring match hits random
# digits (e.g. "timestamp":1790364416**401**) and mislabels healthy models as
# AUTH_ERROR — which then trips the provider-wide abort and hides real results.
# Bare status codes are matched only in an explicit status context.
if [[ "$v" != "AUTH_ERROR" ]]; then
  if printf '%s' "$err_msg" | grep -Eqi 'invalid_api_key|invalid api key|unauthorized|forbidden|authentication failed|auth failed|api key.*(invalid|missing|expired)|(status|"code"|http)[^0-9a-z]{0,4}(401|403)\b'; then
    v=AUTH_ERROR
  elif [[ -z "$err_msg" ]] && printf '%s' "$res" | grep -Eqi 'invalid_api_key|invalid api key|authentication failed|auth failed'; then
    v=AUTH_ERROR
  fi
fi

printf '%s\t%s\t%s\t%s\n' "$src" "$m" "$v" "$((t1-t0))"
WORKER
	chmod +x "$worker_file"
}

# Probe a single model using the validate worker.
# The worker is self-contained: it classifies, maps to the validate vocabulary and
# performs auth detection internally, so no shared temp file is involved and this
# function is safe to call from concurrent workers.
# shellcheck disable=SC2329
probe_model_classify() {
	local model="$1"
	local timeout_secs="${2:-$OCPROBE_VALIDATE_PROBE_TIMEOUT}"
	local prompt="${3:-$OCPROBE_VALIDATE_PROBE_PROMPT}"
	local worker_file="${4:-}"

	if [[ -z "$worker_file" ]]; then
		worker_file=$(mktemp "${OCPROBE_RUN_DIR}/validate_worker.XXXXXX")
		write_validate_worker "$worker_file"
		local own_worker=1
	fi

	local start_ms end_ms
	start_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')

	local output ec
	output=$("$worker_file" "$model" "VALIDATE" "$timeout_secs" "$prompt" 2>/dev/null)
	ec=$?

	end_ms=$(python3 -c 'import time; print(int(time.time() * 1000))')
	local latency=$((end_ms - start_ms))

	if [[ -n "${own_worker:-}" ]]; then rm -f "$worker_file"; fi

	local status
	if [[ $ec -eq 0 && -n "$output" ]]; then
		# Worker already emits a validate-vocabulary status in field 3
		status=$(printf '%s' "$output" | awk -F'\t' '{print $3}')
		[[ -n "$status" ]] || status="UNCLEAR"
	elif [[ $ec -eq 124 || $ec -eq 137 || $ec -eq 142 ]]; then
		status="TIMEOUT"
	else
		status="ERROR"
	fi

	printf '%s\t%s\t%d\n' "$model" "$status" "$latency"
}

# Probe models for one provider.
# Parallel: a 900+ model catalog is infeasible sequentially (hours). The worker is
# written once and reused; each worker is fully independent, so xargs -P is safe.
# Results are appended as single TSV lines (atomic for short lines in append mode).
probe_models_batch() {
	local provider_id="$1"
	local models_file="$2"
	local results_file="$3"

	local count
	count=$(wc -l <"$models_file" | tr -d ' ')
	[[ $count -eq 0 ]] && return 0

	local parallel="${OCPROBE_VALIDATE_MAX_PARALLEL:-4}"
	[[ "$parallel" =~ ^[0-9]+$ && "$parallel" -gt 0 ]] || parallel=4

	log_info "Probing $count models for provider $provider_id (parallel $parallel)..."

	# Modality exclusions (image/video/embedding models can't answer a text probe)
	local candidates="$OCPROBE_RUN_DIR/.validate_candidates.$provider_id"
	local skipped_count=0
	: >"$candidates"
	local model
	while IFS= read -r model; do
		[[ -n "$model" ]] || continue
		if is_modality_skip "$model"; then
			printf '%s\tSKIPPED_MODALITY\t0\n' "$model" >>"$results_file"
			skipped_count=$((skipped_count + 1))
			continue
		fi
		printf '%s\n' "$model" >>"$candidates"
	done <"$models_file"
	[[ $skipped_count -gt 0 ]] && log_info "Skipped $skipped_count modality-excluded models for provider $provider_id"

	local cand_count
	cand_count=$(wc -l <"$candidates" | tr -d ' ')
	[[ $cand_count -eq 0 ]] && return 0

	local worker_file="$OCPROBE_RUN_DIR/.validate_worker-$provider_id"
	write_validate_worker "$worker_file"

	local start_time
	start_time=$(date +%s)

	# Each worker writes one TSV line; -P runs up to $parallel at a time.
	# shellcheck disable=SC2016
	xargs -P "$parallel" -I{} bash -c '
		worker="$1"; m="$2"; secs="$3"; prompt="$4"; out="$5"; verbose="$6"
		line=$("$worker" "$m" "VALIDATE" "$secs" "$prompt" 2>/dev/null)
		if [[ -n "$line" ]]; then
			status=$(printf "%s" "$line" | awk -F"\t" "{print \$3}")
			printf "%s\t%s\t0\n" "$m" "$status" >>"$out"
		else
			status="ERROR"
			printf "%s\t%s\t0\n" "$m" "$status" >>"$out"
		fi
		if [[ "$verbose" == "1" ]]; then printf "  → %s → %s\n" "$m" "$status" >&2; fi
	' _ "$worker_file" {} "$OCPROBE_VALIDATE_PROBE_TIMEOUT" "$OCPROBE_VALIDATE_PROBE_PROMPT" "$results_file" "${OCPROBE_VALIDATE_VERBOSE:-${verbose_mode:-0}}" <"$candidates"

	local elapsed=$(($(date +%s) - start_time))
	log_info "  Probed $cand_count models for $provider_id in ${elapsed}s"

	rm -f "$worker_file" "$candidates"
}

# ---- Blacklist Management ----------------------------------------------------
# Generate proposed blacklist from probe results (uses two-failure gate)
generate_blacklist_proposal() {
	local provider_id="$1"
	local results_file="$2"
	local proposal_file="$3"

	local tentative_file="${proposal_file}.tentative"
	generate_validate_classification "$provider_id" "$results_file" "$proposal_file" "$tentative_file"
	# Tentative file is kept for dry-run reporting; caller is responsible for cleanup
}

# Show diff between current and proposed blacklist
show_blacklist_diff() {
	local provider_id="$1"
	local current_file="$2"
	local effective_file="$3"

	# NOTE: the previous implementation used `sort -u f1 f2 | sort | uniq -c` and
	# treated count==1 as "present in one file only". That is wrong: `sort -u`
	# de-duplicates ACROSS both files, so when current == effective every model
	# appears once and all of them were reported as "would be removed". Use comm
	# set arithmetic, which is what the change counters already used — hence the
	# contradiction between "N changes" and a full removal list.
	local removed added
	removed=$(comm -23 <(sort -u "$current_file") <(sort -u "$effective_file"))
	added=$(comm -13 <(sort -u "$current_file") <(sort -u "$effective_file"))

	if [[ -z "$removed" && -z "$added" ]]; then
		log_info "Provider $provider_id: No changes to blacklist"
		return 0
	fi

	echo "Provider: $provider_id"
	if [[ -n "$removed" ]]; then
		while IFS= read -r model; do
			[[ -n "$model" ]] && echo "- $model (would be removed from blacklist)"
		done <<<"$removed"
	fi
	if [[ -n "$added" ]]; then
		while IFS= read -r model; do
			[[ -n "$model" ]] && echo "+ $model (would be added to blacklist)"
		done <<<"$added"
	fi
	echo
}

# Apply blacklist to opencode.json (merge by model-id, not wholesale replace)
# Reads probed_models_file to know which models were in scope this run.
# new_blacklist = (previous - worked_this_run) ∪ confirmed_dead_this_run
# Entries are sticky: dropped only when the model now probes WORKS. Preserves
# entries for models not probed this run.
apply_blacklist() {
	local provider_id="$1"
	local confirmed_file="$2"
	local probed_models_file="$3"
	local working_file="${4:-}"

	# Read previous blacklist
	local -a prev_blacklist=()
	[[ -f "$OCPROBE_OPencode_CONFIG" ]] &&
		mapfile -t prev_blacklist < <(
			python3 - "$OCPROBE_OPencode_CONFIG" "$provider_id" <<'PY'
import json, sys, os
config_path = os.path.expanduser(sys.argv[1])
provider_id = sys.argv[2]
with open(config_path) as f:
    cfg = json.load(f)
bl = cfg.get("provider", {}).get(provider_id, {}).get("blacklist", [])
for m in bl:
    print(m)
PY
		)

	# Read probed models this run
	local -a probed=()
	[[ -f "$probed_models_file" ]] && mapfile -t probed <"$probed_models_file"

	# Read confirmed dead (new blacklist proposal)
	local -a confirmed=()
	[[ -f "$confirmed_file" ]] && mapfile -t confirmed <"$confirmed_file"

	# Read models that probed WORKS this run (blacklist entries drop only for these)
	local -a working=()
	[[ -n "$working_file" && -f "$working_file" ]] && mapfile -t working <"$working_file"

	# Merge: (previous - working) ∪ confirmed
	python3 - "$OCPROBE_OPencode_CONFIG" "$provider_id" \
		"$(printf '%s\n' "${probed[@]:+${probed[@]}}")" \
		"$(printf '%s\n' "${confirmed[@]:+${confirmed[@]}}")" \
		"$(printf '%s\n' "${prev_blacklist[@]:+${prev_blacklist[@]}}")" \
		"$(printf '%s\n' "${working[@]:+${working[@]}}")" <<'PY'
import json, sys, os

config_path = os.path.expanduser(sys.argv[1])
provider_id = sys.argv[2]
probed = set(sys.argv[3].splitlines()) if sys.argv[3] else set()
confirmed = set(sys.argv[4].splitlines()) if sys.argv[4] else set()
previous = set(sys.argv[5].splitlines()) if sys.argv[5] else set()
working = set(sys.argv[6].splitlines()) if len(sys.argv) > 6 and sys.argv[6] else set()

with open(config_path) as f:
    cfg = json.load(f)

providers = cfg.setdefault("provider", {})
provider = providers.setdefault(provider_id, {})

# Blacklist entries are STICKY: a previously blacklisted model is dropped only when
# it now probes WORKS. Any other outcome (billing/credit limit, timeout, auth error,
# unclear) leaves it blacklisted — un-blacklisting on a non-answer would resurface
# models we have no evidence work, and would flip entries off on every scoped run.
# Entries not probed this run are always preserved.
new_blacklist = (previous - working) | confirmed
provider["blacklist"] = sorted(new_blacklist)

# Write atomically
tmp = config_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, config_path)

print("Applied blacklist for provider:", provider_id, "with", len(new_blacklist), "models")
PY
}

# Verify that the blacklist actually took effect by checking model visibility
# Returns three counts via global vars: VERIFY_WRITTEN, VERIFY_HIDDEN, VERIFY_STILL_VISIBLE
# Exit code stored in VERIFY_EXIT_CODE (0=all hidden, 2=some still visible, 1=hard error)
# Always returns 0 to avoid bash 5.3 bug with non-zero returns from sourced functions
verify_blacklist_effect() {
	local provider_id="$1"
	local expected_blacklist_file="$2"

	local visible_models
	visible_models=$(opencode models "$provider_id" 2>/dev/null | sort -u)

	local -a expected_blacklist=()
	while IFS= read -r model; do
		[[ -n "$model" ]] && expected_blacklist+=("$model")
	done <"$expected_blacklist_file"

	VERIFY_WRITTEN=0
	VERIFY_HIDDEN=0
	VERIFY_STILL_VISIBLE=0

	for model in "${expected_blacklist[@]}"; do
		VERIFY_WRITTEN=$((VERIFY_WRITTEN + 1))
		if printf '%s\n' "$visible_models" | grep -qxF "$model"; then
			VERIFY_STILL_VISIBLE=$((VERIFY_STILL_VISIBLE + 1))
		else
			VERIFY_HIDDEN=$((VERIFY_HIDDEN + 1))
		fi
	done

	if [[ $VERIFY_STILL_VISIBLE -eq 0 ]]; then
		declare -g VERIFY_EXIT_CODE=0
	else
		declare -g VERIFY_EXIT_CODE=2
	fi
	return 0
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
	# Seed from the global flags so both `ocprobe --json validate` and
	# `ocprobe validate --json` work. The global parser consumes these before the
	# subcommand, so without seeding they were silently ignored.
	local json_output="${OCPROBE_JSON_OUTPUT:-0}"
	local verbose_mode="${OCPROBE_VERBOSE:-0}"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--apply) apply_mode=1 ;;
		--verbose) verbose_mode=1 ;;
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
  ocprobe validate [--provider <id>] [--model <id>] [--apply] [--verbose] [--json]
  ocprobe validate restore

OPTIONS:
  --provider <id>   Only validate models for this provider
  --model <id>      Only validate this specific model (requires --provider)
  --apply           Apply blacklist changes to opencode.json (default: dry-run)
  --verbose         Show per-model detail during probing
  --json            Output JSON (machine-readable)
  restore           Restore opencode.json from last validate backup

BEHAVIOR:
  1. Finds providers with valid API keys in auth.json
  2. For each provider, fetches ALL available models via \`opencode models\`
  3. Probes each model with a minimal test prompt
  4. Classifies: WORKS / TIMEOUT / AUTH_ERROR / BILLING_ERROR / NOT_FOUND / ERROR
  5. Proposed blacklist = all non-WORKS models (two-failure gate for non-terminal)
  6. Default (dry-run): Shows diff of what would change
  7. --apply: Backs up opencode.json, writes blacklist, verifies effect
  8. restore: Reverts to last validate backup, verifies restore

NOTES:
  - Uses blacklist (additive) not whitelist (would hide unprobed models)
  - Every run re-probes fresh; no cached/stale blacklisting
  - Creates backup on \`--apply\`; verifies actual picker visibility after apply
  - Exit codes: 0 = success; 2 = partial (some STILL_VISIBLE); 1 = error

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

	# Soft warning for large catalog runs
	local total_models=0
	for provider_id in "${providers[@]}"; do
		local models_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.models.txt"
		if [[ -n "$target_model" ]]; then
			echo "$target_model" >"$models_file"
		else
			get_provider_models "$provider_id" >"$models_file"
		fi
		local model_count
		model_count=$(wc -l <"$models_file" | tr -d ' ')
		total_models=$((total_models + model_count))
	done
	if [[ $total_models -gt ${OCPROBE_VALIDATE_LARGE_RUN_THRESHOLD:-200} ]]; then
		log_warn "Running full-catalog validate across ${#providers[@]} providers / $total_models models. Consider --provider for a smaller, safer run. Continuing in dry-run..."
		if [[ $apply_mode -eq 1 ]]; then
			log_warn "...with --apply..."
		fi
	fi

	# Phase 2: Probe all models (NO lock held - avoids FD leakage to command substitutions)
	local all_results_file="$OCPROBE_RUN_DIR/all_results.tsv"
	: >"$all_results_file"

	# Snapshot sessions BEFORE probing so cleanup_probe_sessions can delete exactly
	# the sessions this run creates — and nothing that existed beforehand.
	SES_BEFORE=()
	# Baseline from the DB, not `opencode session list` (paginated at 100 rows,
	# so it silently omitted pre-existing sessions on busy histories).
	SES_BEFORE=()
	mapfile -t SES_BEFORE < <(list_all_session_ids)
	log_debug "Baseline sessions: ${#SES_BEFORE[@]}"

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

	# Remove ONLY the sessions this run created. Without this, every validate run
	# leaves one session per probed model in the user's history (observed: 33
	# leaked sessions from a single 38-model run). Reuses the audit-path cleanup,
	# which only ever deletes sessions created after the baseline snapshot.
	if [[ ${#SES_BEFORE[@]} -gt 0 ]] || declare -p SES_BEFORE >/dev/null 2>&1; then
		cleanup_probe_sessions
	fi

	# Phase 3: Generate proposals & diffs (still no lock needed)
	local -a provider_results=()
	local overall_changes=0

	for provider_id in "${providers[@]}"; do
		local results_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.results.tsv"
		local current_blacklist_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.current_blacklist.txt"
		get_current_blacklist "$provider_id" >"$current_blacklist_file"

		local proposed_blacklist_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.proposed_blacklist.txt"
		generate_blacklist_proposal "$provider_id" "$results_file" "$proposed_blacklist_file"

		# Effective blacklist = what --apply would actually write.
		# apply_blacklist merges: new = (previous - probed_this_run) ∪ confirmed_dead.
		# Diffing the raw proposal against the previous blacklist reported every
		# out-of-scope entry as "would be removed", which is wrong and alarming when
		# a run is scoped (--provider/--model). Diff against the merged result.
		local effective_blacklist_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.effective_blacklist.txt"
		# Drop previously-blacklisted entries ONLY for models that now probe WORKS
		# (sticky blacklist), then union in this run's confirmed-dead set.
		awk -F'\t' 'NR==FNR {if ($2 == "WORKS") seen[$1]=1; next} ($1 in seen) {next} {print $1}' \
			"$results_file" "$current_blacklist_file" >"$effective_blacklist_file"
		cat "$proposed_blacklist_file" >>"$effective_blacklist_file"
		sort -u "$effective_blacklist_file" -o "$effective_blacklist_file"

		if [[ "${OCPROBE_VALIDATE_VERBOSE:-${verbose_mode:-0}}" == "1" ]]; then
			log_info "  counts: probed=$(wc -l <"$results_file" | tr -d ' ') current=$(wc -l <"$current_blacklist_file" | tr -d ' ') proposed=$(wc -l <"$proposed_blacklist_file" | tr -d ' ') effective=$(wc -l <"$effective_blacklist_file" | tr -d ' ')"
		fi

		# AUTH_ERROR provider-wide abort threshold
		local auth_error_count=0 total_probed=0
		auth_error_count=$(awk -F'\t' '$2 == "AUTH_ERROR" {count++} END {print count+0}' "$results_file")
		total_probed=$(awk -F'\t' '$2 != "SKIPPED_MODALITY" {count++} END {print count+0}' "$results_file")
		if [[ $total_probed -gt 0 ]]; then
			local auth_error_pct=$((auth_error_count * 100 / total_probed))
			if [[ $auth_error_pct -ge ${OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT:-40} ]]; then
				log_warn "Provider $provider_id: ${auth_error_pct}% AUTH_ERROR (threshold ${OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT:-40}%) — looks like a credentials/quota problem, not model breakage. Skipping blacklist changes for this provider. Check your API key/quota and re-run."
				if [[ $json_output -eq 1 ]]; then
					echo "{\"provider\":\"$provider_id\",\"auth_error_abort\":true,\"auth_error_pct\":$auth_error_pct,\"threshold_pct\":${OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT:-40}}"
				fi
				continue
			fi
		fi

		# TIMEOUT provider-wide abort threshold.
		# A timeout is evidence about OUR machine, not about the model: every probe
		# is a full `opencode run` agent contending for CPU and the SQLite DB, so
		# raising parallelism inflates latency (measured: ~2x at -P 8) and pushes
		# healthy models past the timeout. Observed: 941/979 TIMEOUT on a -P 8 run
		# where single probes answered in <2s. Blacklisting on that basis would
		# retire a whole catalog, so treat a high timeout rate as infrastructure
		# failure and skip the provider.
		local timeout_count=0
		timeout_count=$(awk -F'\t' '$2 == "TIMEOUT" {count++} END {print count+0}' "$results_file")
		if [[ $total_probed -gt 0 ]]; then
			local timeout_pct=$((timeout_count * 100 / total_probed))
			if [[ $timeout_pct -ge ${OCPROBE_VALIDATE_TIMEOUT_THRESHOLD_PCT:-60} ]]; then
				log_warn "Provider $provider_id: ${timeout_pct}% TIMEOUT (threshold ${OCPROBE_VALIDATE_TIMEOUT_THRESHOLD_PCT:-60}%) — this measures our probe throughput, not model health. Skipping blacklist changes. Re-run with OCPROBE_VALIDATE_MAX_PARALLEL=2-4 and a higher OCPROBE_VALIDATE_PROBE_TIMEOUT."
				if [[ $json_output -eq 1 ]]; then
					echo "{\"provider\":\"$provider_id\",\"timeout_abort\":true,\"timeout_pct\":$timeout_pct,\"threshold_pct\":${OCPROBE_VALIDATE_TIMEOUT_THRESHOLD_PCT:-60}}"
				fi
				continue
			fi
		fi

		# Count skipped modality and tentative models for reporting
		local skipped_count=0 tentative_count=0 billing_count=0
		skipped_count=$(awk -F'\t' '$2 == "SKIPPED_MODALITY" {count++} END {print count+0}' "$results_file")
		local tentative_file="${proposed_blacklist_file}.tentative"
		[[ -f "$tentative_file" ]] && tentative_count=$(wc -l <"$tentative_file" | tr -d ' ')
		# Models blocked purely by account credits — visible in the report, but
		# deliberately NOT blacklisted (see BILLING_ERROR case in the classifier).
		# The classifier writes "<tentative_file>.billing", hence the derived path.
		local billing_file="${tentative_file}.billing"
		[[ -f "$billing_file" ]] && billing_count=$(wc -l <"$billing_file" | tr -d ' ')
		# Clean up tentative file after reading count
		rm -f "$tentative_file" "$billing_file"

		if [[ $json_output -eq 1 ]]; then
			python3 - "$provider_id" "$results_file" "$current_blacklist_file" "$effective_blacklist_file" "$skipped_count" "$tentative_count" <<'PY'
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
    "schema_version": 1,
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
    "effective_blacklist_count": len(proposed),
    "additions": additions,
    "removals": removals
}, indent=2))
PY
		else
			show_blacklist_diff "$provider_id" "$current_blacklist_file" "$effective_blacklist_file"
			[[ $skipped_count -gt 0 ]] && echo "    Skipped (modality): $skipped_count"
			[[ $tentative_count -gt 0 ]] && echo "    Tentative (watching): $tentative_count"
			[[ $billing_count -gt 0 ]] && echo "    Blocked by account credits (not blacklisted, works once you have credits): $billing_count"
		fi

		local additions_count removals_count
		additions_count=$(comm -13 <(sort "$current_blacklist_file") <(sort "$effective_blacklist_file") | wc -l | tr -d ' ')
		removals_count=$(comm -23 <(sort "$current_blacklist_file") <(sort "$effective_blacklist_file") | wc -l | tr -d ' ')

		if [[ $additions_count -gt 0 ]] || [[ $removals_count -gt 0 ]]; then
			overall_changes=1
			provider_results+=("$provider_id:$proposed_blacklist_file:$additions_count:$removals_count")
		else
			log_info "Provider $provider_id: No changes needed"
		fi
	done

	# Real counts, accumulated from verify_blacklist_effect during the apply
	# loop below (apply_mode==1 only). In dry-run these stay 0 — verify
	# never runs without --apply, so "still_visible" is not a dry-run concept.
	local total_written=0 total_hidden=0 total_still_visible=0

	if [[ $apply_mode -eq 1 && $overall_changes -eq 1 ]]; then
		# Re-acquire the lock for the apply. The lock was released after Phase 1
		# discovery (intentionally — probing runs unlocked), so without this the
		# whole apply ran with no mutual exclusion and the staleness check below
		# was decorative: it could only detect a change made *before* it ran.
		# Re-checking the hash AFTER acquiring makes the check meaningful — the
		# config cannot change between the check and the write.
		acquire_lock
		trap 'release_lock; cleanup_run_dir' EXIT INT TERM

		# Staleness guard: verify opencode.json hasn't changed since Phase 1.
		# Runs *after* re-acquiring the lock, so the check and the write below are
		# atomic with respect to any other ocprobe run.
		local current_hash
		current_hash=$(sha256sum "$OCPROBE_OPencode_CONFIG" | awk '{print $1}')
		if [[ "$current_hash" != "$config_hash" ]]; then
			release_lock
			log_error "Config changed since discovery (hash mismatch): $OCPROBE_OPencode_CONFIG was modified during the unlocked probing window."
			log_error "Refusing to apply — a stale apply would overwrite those changes. Re-run 'ocprobe validate' to get fresh results."
			return 1
		fi

		for entry in "${provider_results[@]}"; do
			IFS=':' read -r provider_id proposed_blacklist_file additions_count removals_count <<<"$entry"
			log_info "Applying blacklist for $provider_id..."
			local backup_file
			backup_file=$(backup_opencode_config)
			log_info "Backup created: $backup_file"

			# 4th arg: models that probed WORKS this run. Blacklist entries are sticky
			# and are dropped only for these, never merely because they were probed.
			local working_file="$OCPROBE_RUN_DIR/${provider_id//\//_}.working.txt"
			awk -F'\t' '$2 == "WORKS" {print $1}' "$results_file" >"$working_file"
			apply_blacklist "$provider_id" "$proposed_blacklist_file" "$models_file" "$working_file"

			log_info "Verifying blacklist effect..."
			verify_blacklist_effect "$provider_id" "$proposed_blacklist_file"
			local verify_exit=$VERIFY_EXIT_CODE
			total_written=$((total_written + VERIFY_WRITTEN))
			total_hidden=$((total_hidden + VERIFY_HIDDEN))
			total_still_visible=$((total_still_visible + VERIFY_STILL_VISIBLE))
			case $verify_exit in
			0)
				log_info "SUCCESS: Blacklist applied and verified for $provider_id (written: $VERIFY_WRITTEN, hidden: $VERIFY_HIDDEN)"
				;;
			2)
				log_warn "PARTIAL: Blacklist written for $provider_id (written: $VERIFY_WRITTEN, hidden: $VERIFY_HIDDEN, still_visible: $VERIFY_STILL_VISIBLE) — likely upstream OpenCode issue #32528, not a blacklist logic error"
				;;
			*)
				log_error "FAILED: Blacklist verification failed for $provider_id"
				return 1
				;;
			esac
		done

		log_info "Validate complete. Changes applied."
		if [[ $total_still_visible -gt 0 ]]; then
			log_warn "SUMMARY: written=$total_written hidden=$total_hidden still_visible=$total_still_visible (likely upstream OpenCode issue #32528)"
			return 2
		else
			log_info "SUMMARY: written=$total_written hidden=$total_hidden still_visible=0"
			return 0
		fi
	fi

	# Dry-run mode or no changes: return appropriate exit code
	if [[ $apply_mode -eq 0 ]]; then
		if [[ $overall_changes -eq 1 ]]; then
			log_info "DRY-RUN SUMMARY: written=$total_written hidden=$total_hidden still_visible=0 (changes pending, use --apply to write)"
			return 1
		else
			log_info "No changes needed."
			return 0
		fi
	fi

	log_info "Validate complete. No changes needed."
	return 0
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
