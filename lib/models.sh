#!/usr/bin/env bash
set -euo pipefail
# shellcheck shell=bash
# shellcheck disable=SC2154,SC2016
# ============================================================================
# lib/models.sh — Model catalog management (diff, probe, apply)
# ============================================================================

# ---- Worker Script Generation -----------------------------------------------
write_worker() {
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
  res=$(timeout "$secs" opencode run --pure --title ocprobe-probe --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
else
  res=$(perl -e 'alarm $ARGV[0]; exec @ARGV[1..$#ARGV] or exit 127' "$secs" opencode run --pure --title ocprobe-probe --format json </dev/null -m "$m" "$prompt" 2>&1); rc=$?
fi
t1=$(python3 -c 'import time; print(int(time.time() * 1000))')

# Extract sessionID from JSON output (first line with sessionID)
session_id=$(printf '%s' "$res" | grep -o '"sessionID":"[^"]*"' | head -1 | sed 's/"sessionID":"\([^"]*\)"/\1/')
printf 'SESSION_ID:%s\n' "$session_id" >&2

# More robust status detection with structured output handling
# Parse JSON events from opencode --format json output
# Each line is a JSON event; look for status event or error event
st=UNCLEAR
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # Try to extract status from status events
  if printf '%s' "$line" | grep -q '"type":"status"'; then
    st=$(printf '%s' "$line" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status","UNCLEAR"))' 2>/dev/null)
    [[ -n "$st" ]] && break
  # Try to extract error type from error events
  elif printf '%s' "$line" | grep -q '"type":"error"'; then
    err_type=$(printf '%s' "$line" | python3 -c 'import sys,json; d=json.load(sys.stdin); err=d.get("error",{}); print(err.get("data",{}).get("message",""))' 2>/dev/null)
    if printf '%s' "$err_type" | grep -qi 'No payment method'; then st=PAYWALLED; break
    elif printf '%s' "$err_type" | grep -qi 'end of life\|Gone'; then st=EOL; break
    elif printf '%s' "$err_type" | grep -q '404'; then st=NOTFOUND; break
    elif printf '%s' "$err_type" | grep -qi 'Error'; then st=BROKEN; break
    else st=ERROR; break
    fi
  fi
done <<<"$res"

# If no status from JSON events, fall back to string matching on full output
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
printf '%s\t%s\t%s\t%s\n' "$src" "$m" "$st" "$((t1-t0))"
WORKER
	chmod +x "$worker_file"
}

# ---- Catalog Operations -----------------------------------------------------

# Get whitelisted models from opencode config
list_whitelist() {
	# shellcheck disable=SC2154
	python3 - "$OCPROBE_OPencode_CONFIG" <<'PY'
import json,sys,os
try:
    cfg=json.load(open(os.path.expanduser(sys.argv[1])))
except (json.JSONDecodeError, OSError) as e:
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
	local cache_age=$(($(now_s) - $(stat -f %m "$cache_file" 2>/dev/null || echo 0)))

	if [[ $OCPROBE_FORCE_REFRESH -eq 1 || ! -s "$cache_file" || $cache_age -ge $((OCPROBE_CACHE_TTL_HOURS * 3600)) ]]; then
		log_info "[1/7] Fetching full catalog..."
		if ! timeout "${OCPROBE_PROBE_TIMEOUT_NEW:-45}" opencode models 2>/dev/null | sort >"$OCPROBE_RUN_DIR/catalog.raw"; then
			log_error "opencode models command timed out or failed"
			return 1
		fi
		python3 - "$OCPROBE_RUN_DIR/catalog.raw" "$cache_file" <<'PY'
import json,sys,time
models=[l.strip() for l in open(sys.argv[1]) if l.strip()]
tmp=sys.argv[2]+".tmp"
json.dump({"fetched_at":int(time.time()),"models":models},open(tmp,"w"))
import os; os.replace(tmp,sys.argv[2])
PY
	else
		log_info "[1/7] Using cached catalog (age: $((cache_age / 3600))h $(((cache_age % 3600) / 60))m)"
	fi

	local full_count
	full_count=$(jq '.models|length' "$cache_file")
	jq -r '.models[]' "$cache_file" >"$OCPROBE_RUN_DIR/catalog.txt"
	log_info "      Full catalog: $full_count models"

	# Validate format
	if ! grep -qE '^[a-zA-Z0-9_./:~:-]+/[a-zA-Z0-9_./:~:-]+$' "$OCPROBE_RUN_DIR/catalog.txt"; then
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

	local new_n gone_n cooling_n
	new_n=$(wc -l <"$OCPROBE_RUN_DIR/new.txt" | tr -d ' ')
	gone_n=$(wc -l <"$OCPROBE_RUN_DIR/gone.txt" | tr -d ' ')
	cooling_n=$(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ')

	log_info "[3/7] NEW: $new_n | GONE-from-catalog: $gone_n | known-dead cooling: $cooling_n"

	# Alert on catalog shrink
	if [[ $gone_n -gt 0 ]]; then
		while read -r m; do [[ -n "$m" ]] && record_alert "WARNING" "CATALOG_SHRINK" "$m" "removed from upstream catalog"; done <"$OCPROBE_RUN_DIR/gone.txt"
	fi

	# Snapshot sessions before probing
	mapfile -t SES_BEFORE < <(opencode session list 2>/dev/null | awk '/^ses_/{print $1}')
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
			_ "$worker" "$model" "$label" "$secs" "$OCPROBE_PROBE_PROMPT" "$exit_file" >>"$OCPROBE_RESULTS_FILE"

		local ec
		ec=$(cat "$exit_file" 2>/dev/null || echo "1")
		rm -f "$worker" "$exit_file"

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

	log_info "[4/7] Probing $count $label models (timeout ${secs}s, parallel $OCPROBE_MAX_PARALLEL)..."

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
			osascript -e 'on run {t, m}' -e 'display notification m with title t' -e 'end run' \
				"ocprobe" "$((crit_n + warn_n)) model(s) failing: $crit_n confirmed dead, $warn_n degraded — run: ocprobe alerts" >/dev/null 2>&1 || true
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

	# Get new sessions since baseline
	local titles_file="$OCPROBE_RUN_DIR/titles.tsv"
	list_sessions_with_titles >"$titles_file"

	local new_sessions=()
	while IFS=$'\t' read -r sid title; do
		[[ -n "$sid" ]] || continue
		[[ " ${SES_BEFORE[*]+${SES_BEFORE[*]}} " != *" $sid "* ]] || continue
		new_sessions+=("$sid")
	done <"$titles_file"

	# Batch queries
	local old_sessions=() fresh_probe_sessions=()
	mapfile -t old_sessions < <(batch_get_old_sessions new_sessions)
	mapfile -t fresh_probe_sessions < <(batch_get_fresh_probe_sessions new_sessions)

	# Convert to lookup sets
	declare -A is_old_session is_fresh_probe_session
	for s in "${old_sessions[@]}"; do is_old_session["$s"]=1; done
	for s in "${fresh_probe_sessions[@]}"; do is_fresh_probe_session["$s"]=1; done

	local deleted=0
	while IFS=$'\t' read -r sid title; do
		[[ -n "$sid" ]] || continue
		[[ " ${SES_BEFORE[*]+${SES_BEFORE[*]}} " != *" $sid "* ]] || continue

		# Age guard
		if [[ ${is_old_session["$sid"]:-0} -eq 1 ]]; then
			log_debug "  age-guard: $sid is >${OCPROBE_AGE_GUARD_HOURS}h old — never touching it"
			continue
		fi

		log_debug "new session detected: $sid title='$title'"

		# Probe session check - match both new and legacy prefixes
		if { [[ "$title" == ${OCPROBE_PROBE_TITLE_PREFIX}* || "$title" == ${OCPROBE_PROBE_TITLE_PREFIX_LEGACY}* || "$title" == "New session - "* ]] && [[ ${is_fresh_probe_session["$sid"]:-0} -eq 1 ]]; } || is_probe_session "$sid"; then
			delete_session "$sid" && {
				deleted=$((deleted + 1))
				log_debug "  deleted test session $sid"
			}
		else
			log_debug "  PRESERVED non-test session $sid ('$title')"
			log_warn "left new session $sid untouched (title='$title')"
		fi
	done <"$titles_file"

	log_info "[5/7] Sessions: ${#SES_BEFORE[@]} preserved, $deleted test session(s) deleted"
}

# ---- Report Generation ------------------------------------------------------
generate_report() {
	local -a ADDS=() DEAD=() DEFER=()

	# New working models to add
	while IFS=$'\t' read -r _ model _; do [[ -n "$model" ]] && ADDS+=("$model"); done < <(awk -F'\t' '$1=="NEW"&&$3=="WORKS"{print $2}' "$OCPROBE_RESULTS_FILE")

	# Deferred/confirmed dead models
	while IFS=$'\t' read -r _src model st _lat; do
		[[ -n "$model" ]] || continue
		if is_confirmed_dead "$model" "$st"; then
			DEAD+=("$model [$st]")
		else
			DEFER+=("$model [$st]")
		fi
	done < <(awk -F'\t' '$1=="WHITELIST"&&$3!="WORKS"' "$OCPROBE_RESULTS_FILE")

	# Write dead list for apply
	printf '%s\n' "${DEAD[@]}" | awk -F' [[]' 'NF{print $1}' >"$OCPROBE_RUN_DIR/dead.txt"

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
		(($(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ') > 0)) && echo "-- known-dead, cooling down (${OCPROBE_GRAVEYARD_COOLDOWN_HOURS}h): $(wc -l <"$OCPROBE_RUN_DIR/cooling.txt" | tr -d ' ') skipped"
		echo "========================================"
	} >&2

	# Store for apply
	export REPORT_ADDS=("${ADDS[@]}")
	export REPORT_DEAD=("${DEAD[@]}")
	export REPORT_DEFER=("${DEFER[@]}")
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

	if [[ $OCPROBE_ASSUME_YES -eq 0 ]]; then
		printf 'Apply changes to %s? [y/N] ' "$OCPROBE_OPencode_CONFIG" >&2
		read -r ans || ans=""
		[[ "${ans:-n}" =~ ^[Yy]$ ]] || {
			log_info "Aborted."
			return 1
		}
	fi

	# Backup - use new suffix
	cp "$OCPROBE_OPencode_CONFIG" "$OCPROBE_OPencode_CONFIG.ocprobe-backup-$OCPROBE_STAMP"
	log_info "[7/7] Applying (backup: $(basename "$OCPROBE_OPencode_CONFIG").ocprobe-backup-$OCPROBE_STAMP)"

	# Apply with Python
	python3 - "$OCPROBE_OPencode_CONFIG" "$OCPROBE_RESULTS_FILE" "$OCPROBE_RUN_DIR/dead.txt" "$OCPROBE_RUN_DIR/removed.txt" <<'PY'
import json,sys,os
cfg_p,res_p,dead_p,out_p=sys.argv[1],sys.argv[2],sys.argv[3],sys.argv[4]
cfg=json.load(open(cfg_p)); prov=cfg.setdefault("provider",{})
adds=[];rems=[]
for line in open(res_p):
    p=line.rstrip("\n").split("\t")
    if len(p)<3: continue
    if p[0]=="NEW" and p[2]=="WORKS": adds.append(p[1])
for line in open(dead_p):
    mid=line.strip()
    if mid: rems.append(mid)
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

	fetch_catalog
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

	fetch_catalog
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
