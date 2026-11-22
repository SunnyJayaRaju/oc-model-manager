#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016
# ============================================================================
# lib/models.sh — Model catalog management (diff, probe, apply)
# ============================================================================

# Source policy engine (only if OCPROBE_LIB_DIR is set, i.e., not during test setup)
# shellcheck disable=SC1091
[[ -n "${OCPROBE_LIB_DIR:-}" ]] && source "${OCPROBE_LIB_DIR}/policy.sh"

# ---- Worker Script Generation -----------------------------------------------
write_worker() {
	local worker_file="$1"
	{
		cat <<'WORKER'
#!/usr/bin/env bash
set -u
m="$1"; src="$2"; secs="$3"; prompt="$4"
# Validate model name
[[ "$m" =~ ^[a-zA-Z0-9_./:~@:-]+$ ]] || { echo "INVALID_MODEL: $m" >&2; exit 1; }
# Validate timeout
[[ "$secs" =~ ^[0-9]+$ ]] && [[ "$secs" -gt 0 ]] || { echo "INVALID_TIMEOUT" >&2; exit 1; }
t0=$(python3 -c 'import time; print(int(time.time() * 1000))')
# The old isolation flag was removed in OpenCode 2.x (2.3.0 rejects it and
# prints usage without ever calling the model), so the plain run format is
# used on every generation. --format json exists on both.
if command -v timeout >/dev/null 2>&1; then
  res=$(timeout "$secs" opencode run --title ocprobe-probe --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
else
  res=$(perl -e 'alarm $ARGV[0]; exec @ARGV[1..$#ARGV] or exit 127' "$secs" opencode run --title ocprobe-probe --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
fi
t1=$(python3 -c 'import time; print(int(time.time() * 1000))')

# Session id for the guarded per-probe cleanup (printed on stderr; every
# observed 2.x event carries one).
session_id=$(printf '%s' "$res" | grep -o '"sessionID":"[^"]*"' | head -1 | sed 's/"sessionID":"\([^"]*\)"/\1/')
printf 'SESSION_ID:%s\n' "$session_id" >&2

# Classify from the event stream in one python pass.
# Observed shapes (opencode 2.3.0, --format json, captured fixtures):
#   success: {"type":"step_start"...}, {"type":"text","part":{"type":"text","text":"OK"}}, {"type":"step_finish"...}; exit 0
#   failure: one line {"type":"error","sessionID":"...","error":{"type":"provider.no-route","message":"Model unavailable: <id>"}}; exit 1
# 2.x emits no "status" events; 1.x may still emit them and the string
# fallback below keeps working either way.
cls=$(printf '%s' "$res" | python3 -c '
import json, sys
rc = int(sys.argv[1])
text = ""
err_type = ""
err_msg = ""
status_ev = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if not isinstance(ev, dict):
        continue
    t = ev.get("type")
    if t == "error":
        err = ev.get("error") or {}
        if isinstance(err, dict):
            err_type = str(err.get("type") or "")
            err_msg = str(err.get("message") or "")
        else:
            err_msg = str(err)
    elif t == "text":
        part = ev.get("part") or {}
        if isinstance(part, dict):
            text = str(part.get("text") or "")
    elif t == "status":
        status_ev = str(ev.get("status") or "")

msg = (err_type + " " + err_msg).lower()
status = ""
if rc == 0 and text.strip():
    status = "WORKS"
elif status_ev:
    status = status_ev
elif err_type or err_msg:
    if (err_type == "provider.no-route"
            or "Model unavailable:" in err_msg
            or "404" in msg
            or "not found" in msg):
        status = "NOTFOUND"
    elif ("no payment method" in msg
            or "requires more credits" in msg
            or "insufficient credits" in msg
            or "not enough credit" in msg
            or "not enough balance" in msg
            or "can only afford" in msg
            or "payment required" in msg
            or "billing" in msg
            or "quota exceeded" in msg
            or "quota insufficient" in msg
            or "402" in msg):
        status = "PAYWALLED"
    elif ("end of life" in msg
            or err_msg.startswith("Gone")):
        status = "EOL"
    elif ("invalid_api_key" in msg
            or "unauthorized" in msg
            or "forbidden" in msg
            or "authentication failed" in msg
            or "auth failed" in msg):
        status = "AUTH_ERROR"
    else:
        status = "ERROR"
elif rc != 0:
    if rc in (124, 137, 142):
        status = "TIMEOUT"
    else:
        status = "ERROR"
print(status)
' "$rc") || cls=""
st="$cls"
[[ -n "$st" ]] || st=UNCLEAR

# Fallback string matching for shapes the event parser could not read
# (non-JSON output, older versions). Same rules as before this rewrite.
if [[ "$st" == "UNCLEAR" ]]; then
  if   printf '%s' "$res" | grep -qi 'No payment method'; then st=PAYWALLED
  elif printf '%s' "$res" | grep -qi 'end of life\|^Gone'; then st=EOL
  elif printf '%s' "$res" | grep -q '404';                 then st=NOTFOUND
  elif printf '%s' "$res" | grep -qi 'Error:';              then st=BROKEN
  elif printf '%s' "$res" | grep -qE '(^|[^a-zA-Z])OK([[:punct:][:space:]]|$)'; then st=WORKS
  elif [[ $rc -eq 127 ]];                                   then st=ERROR
  elif [[ $rc -ne 0 ]];                                     then st=TIMEOUT
  else st=UNCLEAR; fi
fi
WORKER
		# Guarded self-delete inputs: resolved from the caller's already-loaded
		# config and emitted as literals, so the worker's delete gates see
		# exactly the values the parent used to create the session.
		printf 'OCPROBE_LIB_DIR=%q\n' "${OCPROBE_LIB_DIR:-}"
		printf 'OCPROBE_OPencode_DB=%q\n' "${OCPROBE_OPencode_DB:-}"
		printf 'OCPROBE_PROBE_PROMPT=%q\n' "${OCPROBE_PROBE_PROMPT:-Reply with exactly: OK}"
		printf 'OCPROBE_VALIDATE_PROBE_PROMPT=%q\n' "${OCPROBE_VALIDATE_PROBE_PROMPT:-Reply with exactly: OK}"
		printf 'OCPROBE_PROBE_TITLE_PREFIX=%q\n' "${OCPROBE_PROBE_TITLE_PREFIX:-ocprobe-probe}"
		printf 'OCPROBE_PROBE_TITLE_PREFIX_LEGACY=%q\n' "${OCPROBE_PROBE_TITLE_PREFIX_LEGACY:-ocmm-probe}"
		printf 'OCPROBE_VALIDATE_TITLE_PREFIX=%q\n' "${OCPROBE_VALIDATE_TITLE_PREFIX:-ocprobe-validate}"
		printf 'OCPROBE_MAX_MSG_COUNT=%q\n' "${OCPROBE_MAX_MSG_COUNT:-4}"
		cat <<'WORKER'

# Self-delete after EVERY outcome (WORKS, TIMEOUT, AUTH_ERROR, ERROR, ...):
# this process created the session and captured its id from the event stream,
# so cleanup happens even when the parent is killed mid-run and never reaches
# its own delete. The delete goes through the same guarded delete_session the
# session cleanup commands use (id shape, probe title, exact probe prompt, no
# tool calls, no tree, no legacy row); no age-gate waiver is needed because
# the deleted id is the just-created session itself.
# ponytail: a SIGKILL to this worker can still leak the session - the daily
# clean-tests sweep and the audit/check cleanup pass are the backstop for it.
if [[ -n "$session_id" && -n "${OCPROBE_LIB_DIR:-}" && -f "$OCPROBE_LIB_DIR/db.sh" ]]; then
    # core.sh exits the shell when bash is older than 4.3; the result line
    # must survive even then, so only source the libraries on a modern bash.
    if [[ "${BASH_VERSINFO[0]:-0}" -gt 4 || "${BASH_VERSINFO[0]:-0}" -eq 4 && "${BASH_VERSINFO[1]:-0}" -ge 3 ]]; then
        source "$OCPROBE_LIB_DIR/core.sh" || true
        source "$OCPROBE_LIB_DIR/logging.sh" || true
        source "$OCPROBE_LIB_DIR/db.sh" || true
        if declare -F delete_session >/dev/null; then
            delete_session "$session_id" >&2 || true
        fi
    fi
fi
printf '%s\t%s\t%s\t%s\n' "$src" "$m" "$st" "$((t1-t0))"
WORKER
	} >"$worker_file"
	chmod +x "$worker_file"
}

# ---- Catalog Operations -----------------------------------------------------

# Get whitelisted models from opencode config
# The config may be opencode.json or opencode.jsonc; oc_config_read returns
# pure JSON for either (see lib/opencodecfg.sh).
list_whitelist() {
	local jpy
	jpy="$(oc_jsonc_py)"
	# shellcheck disable=SC2154
	python3 -B - "$OCPROBE_OPencode_CONFIG" "${jpy%/*}" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[2])
import jsonc
try:
    cfg = jsonc.parse_jsonc(jsonc.load_text(os.path.expanduser(sys.argv[1])))[0]
except (jsonc.JsoncError, OSError) as e:
    print(f"Error loading config: {e}", file=sys.stderr)
    sys.exit(1)
for pid,p in sorted((cfg.get("provider") or {}).items()):
    for m in sorted(p.get("whitelist") or []):
        print(f"{pid}/{m}")
PY
}

# Fetch full catalog (with caching)
fetch_catalog() {
	local cache_file="$OCPROBE_STATE_DIR/catalog-cache.json"
	local cache_age=$(($(now_s) - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))

	if [[ $OCPROBE_FORCE_REFRESH -eq 1 || ! -s "$cache_file" || $cache_age -ge $((OCPROBE_CACHE_TTL_HOURS * 3600)) ]]; then
		log_info "[1/7] Fetching full catalog..."
		if ! run_with_timeout "${OCPROBE_PROBE_TIMEOUT_NEW:-45}" opencode models 2>/dev/null | sort >"$OCPROBE_RUN_DIR/catalog.raw"; then
			log_error "opencode models command timed out or failed"
			return 1
		fi

		# ---- Catalog floor guard ----------------------------------------------
		# `opencode models` can exit 0 and return nothing (transient upstream
		# blip, partial response, auth/rate-limit edge). Writing that straight to
		# the cache replaces a good catalog with {"models":[]}, and the format
		# check below only warns — so every previously-whitelisted model then
		# lands in gone.txt and fires a CATALOG_SHRINK alert, for up to the whole
		# cache TTL. Nothing is actually deleted (the gone list is alert-only;
		# removal needs a probe-confirmed DEAD), so the damage is alert noise plus
		# a poisoned cache, not data loss — but it is still worth refusing.
		#
		# Two rejection rules:
		#   1. zero models — never a legitimate catalog.
		#   2. fewer than 10% of the previous cache — a sudden collapse to a tiny
		#      fraction of a previously-populated catalog is far more likely a
		#      partial response than a real mass removal. 10% is deliberately
		#      conservative and asymmetric: a false positive costs one cycle of
		#      staleness (the next successful fetch, or --force-refresh, shows the
		#      true catalog), while a false negative costs the poisoning plus one
		#      alert per whitelisted model for the full TTL. For a prior catalog
		#      of <= 10 models the 10% floor is <= 1, so only rule 1 can bite.
		local new_count prior_count reject_reason=""
		new_count=$(grep -c '[^[:space:]]' "$OCPROBE_RUN_DIR/catalog.raw" 2>/dev/null) || new_count=0
		[[ "$new_count" =~ ^[0-9]+$ ]] || new_count=0
		prior_count=0
		if [[ -s "$cache_file" ]]; then
			prior_count=$(jq -r '(.models // []) | length' "$cache_file" 2>/dev/null) || prior_count=0
			[[ "$prior_count" =~ ^[0-9]+$ ]] || prior_count=0
		fi

		if [[ $new_count -eq 0 ]]; then
			reject_reason="it contained no models at all"
		elif [[ $prior_count -gt 0 ]] && [[ $((new_count * 10)) -lt $prior_count ]]; then
			reject_reason="it had $new_count models, under 10% of the $prior_count in the existing cache"
		fi

		if [[ -n "$reject_reason" ]]; then
			if [[ $prior_count -gt 0 ]]; then
				# Keep the previous cache and fall through: catalog.txt is rebuilt
				# from it below, so compute_diff sees no "gone" models and the
				# CATALOG_SHRINK path cannot fire from this rejected fetch.
				log_warn "Rejected suspiciously small catalog: $reject_reason. Treating it as a transient/partial response and keeping the existing cache ($prior_count models) for this run."
			else
				# No usable baseline: an empty first fetch has nothing to fall back
				# on. Writing {"models":[]} would just create a meaningless
				# baseline, and continuing would mark every whitelisted model as
				# gone. Abort instead and let the caller retry.
				log_warn "Catalog fetch returned an empty catalog and there is no previous cache to fall back on. Not writing an empty cache; aborting this run. Re-run 'ocprobe audit' (or use --force-refresh) to retry."
				return 1
			fi
		else
			python3 - "$OCPROBE_RUN_DIR/catalog.raw" "$cache_file" <<'PY'
import json,sys,time
models=[l.strip() for l in open(sys.argv[1]) if l.strip()]
tmp=sys.argv[2]+".tmp"
json.dump({"fetched_at":int(time.time()),"models":models},open(tmp,"w"))
import os; os.replace(tmp,sys.argv[2])
PY
		fi
	else
		log_info "[1/7] Using cached catalog (age: $((cache_age / 3600))h $(((cache_age % 3600) / 60))m)"
	fi

	local full_count
	full_count=$(jq '.models|length' "$cache_file")
	jq -r '.models[]' "$cache_file" >"$OCPROBE_RUN_DIR/catalog.txt"
	log_info "      Full catalog: $full_count models"

	# Validate format
	if ! grep -qE '^[a-zA-Z0-9_./:~@:-]+/[a-zA-Z0-9_./:~@:-]+$' "$OCPROBE_RUN_DIR/catalog.txt"; then
		log_warn "Catalog format unexpected, proceeding anyway"
	fi
}

# ---- Diff Operations --------------------------------------------------------
compute_diff() {
	# Current whitelist
	list_whitelist | sort -u >"$OCPROBE_RUN_DIR/wl.txt"
	local wl_count
	wl_count=$(wc -l <"$OCPROBE_RUN_DIR/wl.txt" | tr -d ' ')
	log_info "[2/7] Whitelist: $wl_count models"

	# Diff
	sort -u "$OCPROBE_RUN_DIR/catalog.txt" -o "$OCPROBE_RUN_DIR/catalog.txt"
	comm -13 "$OCPROBE_RUN_DIR/wl.txt" "$OCPROBE_RUN_DIR/catalog.txt" >"$OCPROBE_RUN_DIR/new.txt"  # in catalog, not whitelisted
	comm -23 "$OCPROBE_RUN_DIR/wl.txt" "$OCPROBE_RUN_DIR/catalog.txt" >"$OCPROBE_RUN_DIR/gone.txt" # whitelisted, vanished upstream

	# Graveyard filtering (models we deliberately removed)
	: >"$OCPROBE_RUN_DIR/cooling.txt"
	if [[ -s "$OCPROBE_STATE_DIR/graveyard.jsonl" ]]; then
		get_active_graveyard >"$OCPROBE_RUN_DIR/graveyard_active.txt" || : >"$OCPROBE_RUN_DIR/graveyard_active.txt"
		grep -Fxf "$OCPROBE_RUN_DIR/graveyard_active.txt" "$OCPROBE_RUN_DIR/new.txt" >>"$OCPROBE_RUN_DIR/cooling.txt" 2>/dev/null || : >"$OCPROBE_RUN_DIR/cooling.txt"
		grep -Fvf "$OCPROBE_RUN_DIR/cooling.txt" "$OCPROBE_RUN_DIR/new.txt" >"$OCPROBE_RUN_DIR/new.fresh" 2>/dev/null || : >"$OCPROBE_RUN_DIR/new.fresh"
		mv "$OCPROBE_RUN_DIR/new.fresh" "$OCPROBE_RUN_DIR/new.txt"
	fi

	sort -u "$OCPROBE_RUN_DIR/new.txt" -o "$OCPROBE_RUN_DIR/new.txt"
	sort -u "$OCPROBE_RUN_DIR/cooling.txt" -o "$OCPROBE_RUN_DIR/cooling.txt"

	# Policy: filter new models by never_add / provider include/exclude
	apply_policy_new_filter "$OCPROBE_RUN_DIR/new.txt" "$OCPROBE_RUN_DIR/excluded.txt"

	local new_n gone_n cooling_n excluded_n
	new_n=$(wc -l <"$OCPROBE_RUN_DIR/new.txt" | tr -d ' ')
	gone_n=$(wc -l <"$OCPROBE_RUN_DIR/gone.txt" | tr -d ' ')
	cooling_n=$(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ')
	excluded_n=$(wc -l <"$OCPROBE_RUN_DIR/excluded.txt" 2>/dev/null | tr -d ' ')

	log_info "[3/7] NEW: $new_n | GONE-from-catalog: $gone_n | known-dead cooling: $cooling_n | excluded-by-policy: ${excluded_n:-0}"

	# Alert on catalog shrink
	if [[ $gone_n -gt 0 ]]; then
		while read -r m; do [[ -n "$m" ]] && record_alert "WARNING" "CATALOG_SHRINK" "$m" "removed from upstream catalog"; done <"$OCPROBE_RUN_DIR/gone.txt"
	fi

	# Snapshot sessions before probing
	# Baseline from the DB, not `opencode session list` (paginated at 100 rows,
	# so it silently omitted pre-existing sessions on busy histories).
	SES_BEFORE=()
	mapfile -t SES_BEFORE < <(list_all_session_ids)
	log_debug "Baseline sessions: ${#SES_BEFORE[@]}"
}

# ---- Probe Engine -----------------------------------------------------------
# Probe a single model with retry/backoff logic
probe_model() {
	local model="$1" label="$2" secs="$3" max_retries="${4:-2}" base_delay="${5:-2}"
	local attempt=0

	while :; do
		local worker="$OCPROBE_RUN_DIR/.worker-retry"
		write_worker "$worker"
		local exit_file="$OCPROBE_RUN_DIR/.exit-retry"
		: >"$exit_file"

		# shellcheck disable=SC2016
		bash -c '"$1" "$2" "$3" "$4" "$5"; echo $? >> "$6"' \
			_ "$worker" "$model" "$label" "$secs" "$OCPROBE_PROBE_PROMPT" "$exit_file" 2>"$OCPROBE_RUN_DIR/.worker-stderr" >>"$OCPROBE_RESULTS_FILE"
		local probe_sid
		probe_sid=$(sed -n 's/^SESSION_ID://p' "$OCPROBE_RUN_DIR/.worker-stderr" | head -1)
		rm -f "$OCPROBE_RUN_DIR/.worker-stderr"

		local ec
		ec=$(cat "$exit_file" 2>/dev/null || echo "1")
		rm -f "$worker" "$exit_file"

		# The probe leaves a titled session behind; delete it through the guarded
		# path immediately so probes do not pile up. A failure here is not fatal:
		# the next cleanup pass will find it by title, prompt and id format.
		if [[ -n "$probe_sid" ]]; then
			delete_session "$probe_sid" ||
				log_debug "probe session $probe_sid not deletable yet (kept for the next cleanup pass)"
		fi

		if [[ "$ec" -eq 0 ]]; then
			return 0
		fi

		attempt=$((attempt + 1))
		if [[ $attempt -ge $max_retries ]]; then
			log_warn "Model $model failed after $max_retries attempts (last exit code: $ec)"
			return 1
		fi

		local delay=$((base_delay * (2 ** (attempt - 1))))
		log_warn "Model $model probe failed (attempt $attempt/$max_retries), retrying in ${delay}s..."
		sleep "$delay"
	done
}

probe_batch() {
	local file="$1" label="$2" secs="$3"
	local count
	count=$(wc -l <"$file" | tr -d ' ')
	[[ $count -eq 0 ]] && return 0

	log_info "[4/7] Probing $count $label models (timeout ${secs}s, sequential)..."

	# Use retry logic for each model
	local failed=0
	while IFS= read -r model; do
		[[ -n "$model" ]] || continue
		if ! probe_model "$model" "$label" "$secs"; then
			failed=$((failed + 1))
		fi
	done <"$file"

	if [[ $failed -gt 0 ]]; then
		log_warn "$failed model(s) failed after retries"
	fi
}

run_probes() {
	: >"$OCPROBE_RESULTS_FILE"
	probe_batch "$OCPROBE_RUN_DIR/new.txt" "NEW" "$OCPROBE_PROBE_TIMEOUT_NEW"
	if [[ $OCPROBE_QUICK -eq 0 ]]; then
		probe_batch "$OCPROBE_RUN_DIR/wl.txt" "WHITELIST" "$OCPROBE_PROBE_TIMEOUT_WL"
	fi
	[[ -f "$OCPROBE_RESULTS_FILE" ]] || : >"$OCPROBE_RESULTS_FILE"

	# Record history
	while IFS=$'\t' read -r _src model status lat; do
		[[ -n "${model:-}" ]] || continue
		record_probe_history "$model" "$status" "$lat"
	done <"$OCPROBE_RESULTS_FILE"
}

# ---- Alert Processing -------------------------------------------------------
process_alerts() {
	local crit_n=0 warn_n=0

	if grep -q '^WHITELIST' "$OCPROBE_RESULTS_FILE" 2>/dev/null; then
		export OCPROBE_BATCH_MODE=1
		while IFS=$'\t' read -r _ model status _; do
			[[ "$status" == "WORKS" ]] && continue
			local safe_key="${model//\//_}"
			local prev="${MODEL_LAST_STATUS[$safe_key]:-}"
			if [[ -n "$prev" && "$prev" != "WORKS" ]]; then
				record_alert "CRITICAL" "MODEL_EOL_CONFIRMED" "$model" "failed again (prev=$prev now=$status)"
				((crit_n++))
			else
				record_alert "WARNING" "MODEL_DEGRADED" "$model" "probe failed ($status)"
				((warn_n++))
			fi
		done < <(awk -F'\t' '$1=="WHITELIST" && $3!="WORKS"' "$OCPROBE_RESULTS_FILE")
		unset OCPROBE_BATCH_MODE

		if ((crit_n + warn_n > 0)) && [[ "$OCPROBE_DESKTOP_NOTIFICATIONS" -eq 1 ]]; then
			audit_log "NOTIFICATION best-effort: $((crit_n + warn_n)) model(s) failing: $crit_n confirmed dead, $warn_n degraded — run: ocprobe alerts"
			if command -v terminal-notifier >/dev/null 2>&1; then
				terminal-notifier -title ocprobe -message "$((crit_n + warn_n)) model(s) failing" >/dev/null 2>&1 || true
			fi
		fi
	fi

	# Alert on new working models
	while IFS=$'\t' read -r _ model _; do
		record_alert "INFO" "NEW_MODEL_DISCOVERED" "$model" "new model works — candidate for whitelist"
	done < <(awk -F'\t' '$1=="NEW" && $3=="WORKS"' "$OCPROBE_RESULTS_FILE")
}

# ---- Session Cleanup --------------------------------------------------------
cleanup_probe_sessions() {
	log_info "[5/7] Cleaning probe sessions..."

	# Historical note: session safety here is NOT the older is_probe_session()
	# exact-prompt-match check, which was removed as dead code. That older
	# approach compared the first message's text against the probe prompt
	# verbatim; it was the original safety net for the 2026-08-25 session-loss
	# incident, and it has since been superseded by the design used here:
	# a title-prefix match (probe / legacy-probe / validate) in SQL, bounded
	# by this run's start time, plus the age and message-count guards. Any
	# future change to session deletion must keep all three properties -- the
	# exact-prompt property is no longer provided by any code path.
	# Candidate sessions come from the DB (complete), bounded by this run's start
	# time — NOT from `opencode session list`, which paginates at 100 rows and hid
	# 842 of 942 probe sessions on a full-catalog run. Age and message-count guards
	# are already applied in SQL by list_probe_sessions_since.
	local since_ms="${OCPROBE_RUN_START_MS:-0}"
	[[ "$since_ms" =~ ^[0-9]+$ ]] || since_ms=0

	local candidates_file="$OCPROBE_RUN_DIR/probe_candidates.tsv"
	list_probe_sessions_since "$since_ms" >"$candidates_file"

	local candidate_count
	candidate_count=$(wc -l <"$candidates_file" | tr -d ' ')
	if [[ $candidate_count -eq 0 ]]; then
		log_info "[5/7] Sessions: no probe sessions created by this run — nothing to clean"
		return 0
	fi
	log_debug "  $candidate_count probe session(s) created by this run are cleanup candidates"

	local deleted=0 preserved=0
	local sid title
	while IFS=$'\t' read -r sid title; do
		[[ -n "$sid" ]] || continue
		title="${title#"${title%%[![:space:]]*}"}" # trim leading space from CLI-style titles

		# If it existed before this run started, it is not ours.
		if [[ ${#SES_BEFORE[@]} -gt 0 ]]; then
			case " ${SES_BEFORE[*]} " in
			*" $sid "*)
				log_debug "  pre-existing session $sid — never touching it"
				preserved=$((preserved + 1))
				continue
				;;
			esac
		fi

		if delete_session "$sid"; then
			deleted=$((deleted + 1))
			log_debug "  deleted probe session $sid"
		else
			preserved=$((preserved + 1))
		fi
	done <"$candidates_file"

	log_info "[5/7] Sessions: $deleted probe session(s) deleted, $preserved preserved, ${#SES_BEFORE[@]} pre-existing untouched"
}

# ---- Report Generation ------------------------------------------------------
generate_report() {
	local -a ADDS=() DEAD=() DEFER=()

	# New working models to add
	while IFS=$'\t' read -r _ model _; do [[ -n "$model" ]] && ADDS+=("$model"); done < <(awk -F'\t' '$1=="NEW"&&$3=="WORKS"{print $2}' "$OCPROBE_RESULTS_FILE")

	# Deferred/confirmed dead models
	local -a PROTECTED=()
	while IFS=$'\t' read -r _src model st _lat; do
		[[ -n "$model" ]] || continue
		if is_confirmed_dead "$model" "$st"; then
			if [[ "${OCPROBE_POLICY_ENABLED:-0}" -eq 1 ]] && policy_match_any "$model" "$OCPROBE_RUN_DIR/policy-never_remove.txt"; then
				PROTECTED+=("$model [$st]")
			else
				DEAD+=("$model [$st]")
			fi
		else
			DEFER+=("$model [$st]")
		fi
	done < <(awk -F'\t' '$1=="WHITELIST"&&$3!="WORKS"' "$OCPROBE_RESULTS_FILE")

	# Write dead list for apply
	# ${a[@]+"${a[@]}"} not "${a[@]}": empty arrays are unbound under set -u on bash 4.3.
	printf '%s\n' ${DEAD[@]+"${DEAD[@]}"} | awk -F' [[]' 'NF{print $1}' >"$OCPROBE_RUN_DIR/dead.txt"

	local dead_n=${#DEAD[@]}
	local ok_count
	ok_count=$(awk -F'\t' '$1=="WHITELIST"&&$3=="WORKS"' "$OCPROBE_RESULTS_FILE" | wc -l | tr -d ' ')
	local wl_count
	wl_count=$(wc -l <"$OCPROBE_RUN_DIR/wl.txt" | tr -d ' ')

	# Output report
	{
		echo
		echo "================ REPORT ================"
		echo "-- ADD to whitelist:"
		[[ ${#ADDS[@]} -gt 0 ]] && printf '    + %s\n' "${ADDS[@]}" || echo "    none"
		echo "-- REMOVE (confirmed dead):"
		[[ ${#DEAD[@]} -gt 0 ]] && printf '    - %s\n' "${DEAD[@]}" || echo "    none"
		echo "-- protected by policy (kept despite failures):"
		[[ ${#PROTECTED[@]} -gt 0 ]] && printf '    * %s\n' "${PROTECTED[@]}" || echo "    none"
		echo "-- degraded (kept; removes after next failed probe):"
		[[ ${#DEFER[@]} -gt 0 ]] && printf '    ~ %s\n' "${DEFER[@]}" || echo "    none"
		if [[ $OCPROBE_QUICK -eq 1 ]] && ! grep -q '^WHITELIST' "$OCPROBE_RESULTS_FILE" 2>/dev/null; then
			echo "-- healthy: whitelist not probed this run (--quick)"
		else
			echo "-- healthy: $ok_count/$wl_count"
		fi
		[[ -s "$OCPROBE_RUN_DIR/gone.txt" ]] && {
			echo "-- gone upstream:"
			sed 's/^/    ! /' "$OCPROBE_RUN_DIR/gone.txt"
		}
		[[ -s "$OCPROBE_RUN_DIR/excluded.txt" ]] && {
			echo "-- excluded by policy (never_add / provider filters):"
			sed 's/^/    x /' "$OCPROBE_RUN_DIR/excluded.txt"
		}
		(($(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ') > 0)) && echo "-- known-dead, cooling down (${OCPROBE_GRAVEYARD_COOLDOWN_HOURS}h): $(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ') skipped"
		echo "========================================"
	} >&2

	# Store for apply
	export REPORT_ADDS=("${ADDS[@]}")
	export REPORT_DEAD=(${DEAD[@]+"${DEAD[@]}"})
	export REPORT_DEFER=("${DEFER[@]}")
	export REPORT_PROTECTED=("${PROTECTED[@]}")
	export REPORT_DEAD_N=$dead_n
	export REPORT_OK_COUNT=$ok_count
	export REPORT_WL_COUNT=$wl_count
}

# ---- Confirmed Dead Logic ---------------------------------------------------
is_confirmed_dead() {
	local model="$1" status="$2"
	case "$status" in EOL | NOTFOUND) return 0 ;; esac
	local safe_key="${model//\//_}"
	local cnt="${MODEL_FAIL_COUNT[$safe_key]:-0}"
	[[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
	((cnt >= 2)) || return 1
	local prev="${MODEL_LAST_STATUS[$safe_key]:-}"
	[[ -n "$prev" && "$prev" != "WORKS" ]]
}

# ---- Apply Changes ----------------------------------------------------------
# Shared parsing of what this run wants to write: reads the probe results and
# the dead list, prints two files (adds.txt, rems.txt) of provider/model ids.
collect_pending_changes() {
	local res_p="$1" dead_p="$2" adds_p="$3" rems_p="$4"
	: >"$adds_p"
	: >"$rems_p"
	awk -F'\t' '$1=="NEW"&&$3=="WORKS"{print $2}' "$res_p" >"$adds_p"
	while IFS= read -r mid; do
		[[ -n "$mid" ]] && printf '%s\n' "$mid" >>"$rems_p"
	done <"$dead_p"
}

apply_changes_plain() {
	local adds_p="$OCPROBE_RUN_DIR/apply-adds.txt" rems_p="$OCPROBE_RUN_DIR/apply-rems.txt"
	collect_pending_changes "$OCPROBE_RESULTS_FILE" "$OCPROBE_RUN_DIR/dead.txt" "$adds_p" "$rems_p"
	python3 - "$OCPROBE_OPencode_CONFIG" "$adds_p" "$rems_p" "$OCPROBE_RUN_DIR/removed.txt" <<'PY'
import json,os,sys
cfg_p,adds_p,rems_p,out_p=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
cfg=json.load(open(cfg_p)); prov=cfg.setdefault("provider",{})
adds=[l.strip() for l in open(adds_p) if l.strip()]
rems=[l.strip() for l in open(rems_p) if l.strip()]
for mid in adds:
    pid,m=mid.split("/",1)
    wl=prov.setdefault(pid,{}).setdefault("whitelist",[])
    if m not in wl: wl.append(m)
for mid in rems:
    pid,m=mid.split("/",1)
    wl=prov.get(pid,{}).get("whitelist",[])
    if m in wl:
        wl.remove(m)
        with open(out_p,"a") as f: f.write(mid+"\n")
for pid in prov:
    if "whitelist" in prov[pid]:
        prov[pid]["whitelist"]=sorted(set(prov[pid]["whitelist"]))
tmp=cfg_p+".tmp"; json.dump(cfg,open(tmp,"w"),indent=2)
os.replace(tmp,cfg_p)
PY
}

# .jsonc variant of apply_changes: every whitelist that changes is replaced in
# place, everything else — comments included — is left byte-identical.
# Providers whose whitelist array does not exist yet refuse the whole write:
# creating keys inside a commented file needs a human, and the refusal prints
# the exact lines to add.
apply_changes_jsonc() {
	local cfg_p="$OCPROBE_OPencode_CONFIG"
	local adds_p="$OCPROBE_RUN_DIR/apply-adds.txt" rems_p="$OCPROBE_RUN_DIR/apply-rems.txt"
	collect_pending_changes "$OCPROBE_RESULTS_FILE" "$OCPROBE_RUN_DIR/dead.txt" "$adds_p" "$rems_p"
	local jpy
	jpy="$(oc_jsonc_py)"
	python3 -B - "$cfg_p" "$adds_p" "$rems_p" "$OCPROBE_RUN_DIR/removed.txt" "${jpy%/*}" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[5])
import jsonc
cfg_p, adds_p, rems_p, out_p = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
adds = [l.strip() for l in open(adds_p) if l.strip()]
rems = [l.strip() for l in open(rems_p) if l.strip()]
text = jsonc.load_text(cfg_p)
cfg, masked = jsonc.parse_jsonc(text)
providers = cfg.get("provider") or {}
touched = {}
for mid in adds + rems:
    touched.setdefault(mid.split("/", 1)[0], True)
new_values, spans = {}, {}
for pid in sorted(touched):
    dotted = "provider.%s.whitelist" % pid
    current = list((providers.get(pid) or {}).get("whitelist") or [])
    merged = set(current)
    for mid in adds:
        if mid.split("/", 1)[0] == pid:
            merged.add(mid.split("/", 1)[1])
    for mid in rems:
        if mid.split("/", 1)[0] == pid:
            m = mid.split("/", 1)[1]
            if m in merged:
                merged.discard(m)
                with open(out_p, "a") as f:
                    f.write(mid + "\n")
    new_values[pid] = sorted(merged)
# Locate every span BEFORE writing anything, so one missing whitelist refuses
# the whole run instead of leaving a half-applied config behind.
try:
    for pid in sorted(touched):
        spans[pid] = jsonc.find_array_span(masked, "provider.%s.whitelist" % pid)
except jsonc.JsoncError as e:
    sys.stderr.write(
        "refusing to edit %s: %s\nadd by hand inside the provider object, e.g.:\n"
        '    "whitelist": ["%s"]\n'
        % (cfg_p, e, next(iter(touched)))
    )
    sys.exit(3)
changed = {pid: v for pid, v in new_values.items()
           if v != list((providers.get(pid) or {}).get("whitelist") or [])}
for pid in sorted(changed, key=lambda p: -spans[p][0]):
    start, end = spans[pid]
    text = text[:start] + json.dumps(new_values[pid]) + text[end:]
final, _ = jsonc.parse_jsonc(text)
tmp = cfg_p + ".tmp"
with open(tmp, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
    f.write(text)
os.replace(tmp, cfg_p)
print("patched %d whitelist(s) in %s" % (len(changed), cfg_p))
PY
}

apply_changes() {
	local dead_n=$REPORT_DEAD_N
	local wl_count=$REPORT_WL_COUNT
	local pending=$((${#REPORT_ADDS[@]} + dead_n))

	# Mass removal guard
	if [[ $dead_n -gt 0 && $wl_count -gt 0 ]] && ((dead_n * 100 >= wl_count * OCPROBE_MASS_REMOVAL_THRESHOLD_PCT)) && [[ "${!OCPROBE_ALLOW_MASS_REMOVE_ENV:-0}" != "1" ]]; then
		log_warn "MASS-REMOVAL GUARD: $dead_n/$wl_count whitelisted models flagged dead (>${OCPROBE_MASS_REMOVAL_THRESHOLD_PCT}%)."
		log_warn "This pattern usually = probe infrastructure failure, not model death."
		die "Refusing to apply. Verify environment/probes first; override with ${OCPROBE_ALLOW_MASS_REMOVE_ENV}=1 only if certain."
	fi

	if [[ $pending -eq 0 ]]; then
		log_info "[6/7] Nothing to apply"
		return 0
	fi

	# Dry-run: report what would change and write nothing.
	if [[ $OCPROBE_DRY_RUN -eq 1 ]]; then
		log_info "DRY-RUN: nothing was written. Pending changes:"
		[[ ${#REPORT_ADDS[@]} -gt 0 ]] && printf '  would add to whitelist: %s\n' "${REPORT_ADDS[@]}"
		[[ -s "$OCPROBE_RUN_DIR/dead.txt" ]] && sed 's/^/  would remove from whitelist: /' "$OCPROBE_RUN_DIR/dead.txt"
		if [[ "$(oc_generation)" != "1" ]]; then
			log_warn "DRY-RUN note: OpenCode 2.x does not honour these keys; a real apply would refuse. Nothing was changed."
		fi
		return 1
	fi

	# OpenCode 2.x builds its model catalog without reading per-model provider
	# keys (verified on 2.3.0: no whitelist/blacklist/disabled/policies key
	# changes the server's model list). Writing one would report success while
	# changing nothing, so refuse instead of writing an inert key.
	if [[ "$(oc_generation)" != "1" ]]; then
		log_error "this OpenCode version does not honour provider model lists; nothing was changed (per-model hiding is not supported on OpenCode 2.x)"
		return 1
	fi

	# Determine if we can skip confirmation based on auto_apply
	local skip_confirm=0

	# --yes flag overrides everything
	if [[ $OCPROBE_ASSUME_YES -eq 1 ]]; then
		skip_confirm=1
	fi

	# Check policy-based auto_apply (per-provider)
	if [[ $skip_confirm -eq 0 ]]; then
		# Build a temporary file with all pending models (adds + removals)
		local pending_models_file="$OCPROBE_RUN_DIR/pending_models.txt"
		: >"$pending_models_file"
		[[ -n "${REPORT_ADDS[*]:-}" ]] && printf '%s
' "${REPORT_ADDS[@]}" >>"$pending_models_file"
		[[ -s "$OCPROBE_RUN_DIR/dead.txt" ]] && cat "$OCPROBE_RUN_DIR/dead.txt" >>"$pending_models_file"

		# Check if all pending models have effective auto_apply = true
		if policy_all_pending_auto_applyable "$pending_models_file"; then
			skip_confirm=1
			# Log which providers auto_apply
			local -a providers=()
			while IFS= read -r model; do
				[[ -n "$model" ]] || continue
				providers+=("${model%%/*}")
			done <"$pending_models_file"
			# Deduplicate providers
			local -A seen=()
			local -a unique_providers=()
			for p in "${providers[@]}"; do
				[[ -n "${seen[$p]:-}" ]] && continue
				seen["$p"]=1
				unique_providers+=("$p")
			done
			log_info "policy auto_apply: skipping confirmation prompt (providers: ${unique_providers[*]})"
		fi
	fi

	if [[ $skip_confirm -eq 0 ]]; then
		printf 'Apply changes to %s? [y/N] ' "$OCPROBE_OPencode_CONFIG" >&2
		read -r reply || reply=""
		[[ "${reply:-n}" =~ ^[Yy]$ ]] || {
			log_info "Aborted."
			return 1
		}
	fi

	# Backup - use new suffix
	cp "$OCPROBE_OPencode_CONFIG" "$OCPROBE_OPencode_CONFIG.ocprobe-backup-$OCPROBE_STAMP"
	log_info "[7/7] Applying (backup: $(basename "$OCPROBE_OPencode_CONFIG").ocprobe-backup-$OCPROBE_STAMP)"

	# Apply with Python.
	# Plain .json is rewritten whole (ocm owns the formatting). A .jsonc is
	# patched span-by-span: re-serialising it would destroy hand-written
	# comments, so every target array is located first and only the spans of
	# whitelists that actually change are replaced. If any whitelist does not
	# exist yet, the whole write is refused — a half-applied config is worse
	# than none.
	if oc_config_is_jsonc "$OCPROBE_OPencode_CONFIG"; then
		apply_changes_jsonc || return 1
	else
		apply_changes_plain
	fi

	# Record removals in graveyard
	local ts_ms
	ts_ms=$(ms)
	while IFS= read -r mid; do [[ -n "$mid" ]] && printf '%s\t%s\n' "$ts_ms" "$mid" >>"$OCPROBE_STATE_DIR/graveyard.jsonl"; done <"$OCPROBE_RUN_DIR/removed.txt"
	prune_jsonl "$OCPROBE_STATE_DIR/graveyard.jsonl" 2000

	# Cleanup old backups - match both old and new backup suffixes
	find "$(dirname "$OCPROBE_OPencode_CONFIG")" -name '*.ocm-backup-*' -mtime +"$OCPROBE_BACKUP_KEEP_DAYS" -delete 2>/dev/null || true
	find "$(dirname "$OCPROBE_OPencode_CONFIG")" -name '*.ocprobe-backup-*' -mtime +"$OCPROBE_BACKUP_KEEP_DAYS" -delete 2>/dev/null || true

	prune_jsonl "$OCPROBE_STATE_DIR/probe-history.jsonl" "$OCPROBE_HISTORY_LIMIT"
	prune_jsonl "$OCPROBE_STATE_DIR/alerts.jsonl" "$OCPROBE_ALERT_LIMIT"

	log_info "DONE. Log: $OCPROBE_LOG_FILE"
}

# ---- Command Implementations ------------------------------------------------

cmd_audit() {
	load_config
	acquire_lock
	trap 'release_lock; cleanup_run_dir' EXIT INT TERM

	log_info "=== ocprobe audit $(date) ==="
	audit_log "=== run start mode=audit quick=$OCPROBE_QUICK ==="

	load_policy
	policy_write_never_remove_file

	# fetch_catalog returns non-zero when the catalog is unusable (fetch failed,
	# or an empty first fetch with no cache to fall back on). Abort before
	# compute_diff, which would otherwise diff against a missing/empty catalog
	# and mark every whitelisted model as gone.
	fetch_catalog || return 1
	compute_diff

	# Load probe history for alert processing
	declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
	load_probe_history MODEL_LAST_STATUS MODEL_FAIL_COUNT

	run_probes
	process_alerts
	cleanup_probe_sessions
	generate_report
	apply_changes
}

cmd_check() {
	load_config
	acquire_lock
	trap 'release_lock; cleanup_run_dir' EXIT INT TERM

	log_info "=== ocprobe check $(date) ==="
	audit_log "=== run start mode=check quick=$OCPROBE_QUICK ==="

	load_policy
	policy_write_never_remove_file

	# See the note in cmd_audit: a non-zero return means there is no usable
	# catalog, so stop before compute_diff can raise CATALOG_SHRINK for every
	# whitelisted model.
	fetch_catalog || return 1
	compute_diff

	declare -gA MODEL_LAST_STATUS MODEL_FAIL_COUNT
	load_probe_history MODEL_LAST_STATUS MODEL_FAIL_COUNT

	run_probes
	process_alerts
	cleanup_probe_sessions
	generate_report

	local pending=$((${#REPORT_ADDS[@]} + REPORT_DEAD_N))
	log_info "[6/7] Check-only: no changes written"
	[[ $pending -gt 0 ]] && exit 1 || exit 0
}

cmd_status() {
	load_config
	echo
	echo "=== whitelist ($(list_whitelist | wc -l | tr -d ' ') models) ==="
	list_whitelist | sed 's/^/  /'
	echo
	echo "=== last probe result per model ==="
	if [[ -s "$OCPROBE_STATE_DIR/probe-history.jsonl" ]]; then
		jq -r '[.model,.status,(.latency_ms|tostring)+"ms",(.ts/1000|todate)] | @tsv' "$OCPROBE_STATE_DIR/probe-history.jsonl" |
			awk '{a[i++]=$0} END{for(j=i-1;j>=0;j--)print a[j]}' | awk -F'\t' '!seen[$1]++' | head -40 | sed 's/^/  /'
	else echo "  (no history yet)"; fi
	echo
	echo "=== alerts (last 10) ==="
	[[ -s "$OCPROBE_STATE_DIR/alerts.jsonl" ]] && tail -10 "$OCPROBE_STATE_DIR/alerts.jsonl" | jq -r '"  \(.severity)\t\(.type)\t\(.model)\t\(.message)"' || echo "  (none)"
}

cmd_alerts() {
	load_config
	local clear=0
	[[ "${1:-}" == "--clear" ]] && clear=1

	if [[ $clear -eq 1 ]]; then
		: >"$OCPROBE_STATE_DIR/alerts.jsonl"
		echo "alerts cleared."
	else
		[[ -s "$OCPROBE_STATE_DIR/alerts.jsonl" ]] && jq -r '"\(.ts/1000|todate)\t\(.severity)\t\(.type)\t\(.model): \(.message)"' <"$OCPROBE_STATE_DIR/alerts.jsonl" || echo "(no alerts)"
	fi
}

cmd_probe() {
	local model="${1:-}"
	[[ -n "$model" ]] || {
		log_error "usage: ocprobe probe <provider/model>"
		exit 1
	}

	load_config
	acquire_lock
	trap 'release_lock; cleanup_run_dir' EXIT INT TERM

	validate_model_name "$model" || die "Invalid model name: $model"

	local worker="$OCPROBE_RUN_DIR/.worker"
	write_worker "$worker"

	# Run worker, capture stdout and stderr separately
	local out err session_id
	out=$("$worker" "$model" "MANUAL" "$OCPROBE_PROBE_TIMEOUT_NEW" "$OCPROBE_PROBE_PROMPT" 2>"$OCPROBE_RUN_DIR/.worker.err")
	err=$(cat "$OCPROBE_RUN_DIR/.worker.err" 2>/dev/null || true)
	rm -f "$OCPROBE_RUN_DIR/.worker.err"

	# Extract session ID from the worker's JSON output marker
	session_id=$(printf '%s' "$err" | grep '^SESSION_ID:' | head -1 | sed 's/^SESSION_ID://')
	if [[ -z "$session_id" ]]; then
		log_warn "could not capture session ID for this probe, skipping automatic cleanup — session will be caught by the next audit/check cleanup pass instead"
	else
		log_debug "captured probe session ID: $session_id"
		# Delete the session directly using captured ID
		if delete_session "$session_id"; then
			log_debug "cleaned probe session $session_id"
		else
			log_debug "session $session_id already gone or not deletable"
		fi
	fi

	printf '%s\n' "$out"
	record_probe_history "$model" "$(awk -F'\t' '{print $3}' <<<"$out")" "$(awk -F'\t' '{print $4}' <<<"$out")"
	rm -f "$worker"
}

cmd_watch() {
	load_config
	log_info "Watch mode: check+alert every $((OCPROBE_WATCH_SECS / 60)) min — never auto-applies (run 'audit' manually)"

	local watch_args=(check)
	((OCPROBE_QUICK)) && watch_args+=(--quick)

	local stop=0
	trap 'stop=1' INT TERM

	while ((! stop)); do
		# Call cmd_check directly instead of recursive self-invocation
		if cmd_check "${watch_args[@]}"; then
			audit_log "watch: no changes"
		else
			audit_log "watch: changes pending — see 'alerts' / run 'audit' to apply"
		fi

		# Sleep in small increments for signal handling
		local slept=0
		while ((slept < OCPROBE_WATCH_SECS && ! stop)); do
			sleep 10
			slept=$((slept + 10))
		done
	done
	log_info "Watch stopped gracefully"
}
