#!/usr/bin/env bats
# shellcheck shell=bash
# ============================================================================
# test/unit/validate_perf.bats — guards the history-streak scan against going
# quadratic again.
#
# _validate_history_streak used to re-read the whole validate-history.jsonl once
# PER MODEL, spawning two awk processes per history line to pull out $1/$2. That
# is O(models x history) and it dominated a validate run: ~2.4 hours at the real
# catalog size (~941 models), which made the tool's core command impractical.
# It now folds the file once into a per-model map and each lookup is a hash read.
#
# This asserts the SCALING, not an absolute time, because absolute times depend
# on the runner. Measured on the author's machine, 4x the models (50 -> 200):
#   old, quadratic : 39.16s -> 613.25s  = 15.7x   (~16x, the quadratic signature)
#   new, linear    :  5.13s ->  26.92s  =  5.2x   (linear would be ~4x)
# A threshold of 8x sits clear of both: linear passes, quadratic fails loudly.
# ============================================================================

bats_require_minimum_version 1.5.0

load '../helpers/bats-support/load'
load '../helpers/bats-assert/load'

setup() {
    source "$BATS_TEST_DIRNAME/../helpers/setup_libs.bash"

    export OCPROBE_CONFIG_OVERRIDE="$BATS_TEST_TMPDIR/config.yaml"
    export OCPROBE_STATE_DIR="$BATS_TEST_TMPDIR/state"
    export OCPROBE_RUN_DIR="$BATS_TEST_TMPDIR/run"
    export OCPROBE_LOG_LEVEL="error"
    export OCPROBE_LOG_FORMAT="text"
    mkdir -p "$OCPROBE_STATE_DIR" "$OCPROBE_RUN_DIR"

    cat >"$OCPROBE_CONFIG_OVERRIDE" <<EOF
version: 1
opencode:
  config_path: "$BATS_TEST_TMPDIR/opencode.json"
  db_path: "$BATS_TEST_TMPDIR/opencode.db"
retention:
  history_limit: 5000
logging:
  level: error
  format: text
  file_enabled: false
EOF
    cat >"$BATS_TEST_TMPDIR/opencode.json" <<'JSON'
{"provider":{}}
JSON
    load_config >/dev/null

    TIMER="$BATS_TEST_DIRNAME/../helpers/timer.py"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR"
}

# _classify_n_models <n> — seed one prior failure per model (so the history file
# scales with n, as it does in production) and re-classify all of them as
# failures. Every model therefore takes the non-terminal-failure path, which is
# the one that reads the streak once per model.
_classify_n_models() {
    local n="$1" i
    local history="$OCPROBE_STATE_DIR/validate-history.jsonl"
    : >"$history"
    for i in $(seq 1 "$n"); do
        printf 'test-provider/m%s\tTIMEOUT\t1000\n' "$i" >>"$history"
    done

    local results="$BATS_TEST_TMPDIR/results.tsv"
    local proposal="$BATS_TEST_TMPDIR/proposal.txt"
    local tentative="$BATS_TEST_TMPDIR/tentative.txt"
    : >"$results"; : >"$proposal"; : >"$tentative"
    for i in $(seq 1 "$n"); do
        printf 'test-provider/m%s\tTIMEOUT\t2000\n' "$i" >>"$results"
    done

    generate_validate_classification "test-provider" "$results" "$proposal" "$tentative" >/dev/null 2>&1
    # every model is on its second strike, so all must be CONFIRMED
    grep -c . "$proposal"
}

# _time_classify <n> <repeats> — seconds for the best of <repeats> runs. The
# minimum is the most noise-resistant estimator on a shared CI runner: a slow
# sample from contention can only ever make a run look worse, never better.
_time_classify() {
    local n="$1" repeats="$2" r best="" t0 t1 secs
    for r in $(seq 1 "$repeats"); do
        t0=$(python3 "$TIMER" now)
        _classify_n_models "$n" >/dev/null
        t1=$(python3 "$TIMER" now)
        secs=$(python3 "$TIMER" diff "$t0" "$t1")
        if [[ -z "$best" ]] || awk -v a="$secs" -v b="$best" 'BEGIN{exit !(a<b)}'; then
            best="$secs"
        fi
    done
    printf '%s' "$best"
}

@test "history-streak classification scales roughly linearly, not quadratically" {
    local small large ratio
    # 4x the models. Linear predicts ~4x time; quadratic predicts ~16x.
    small=$(_time_classify 50 2)
    large=$(_time_classify 200 1)

    echo "  N=50: ${small}s   N=200: ${large}s" >&2
    ratio=$(awk -v a="$large" -v b="$small" 'BEGIN{printf "%.2f", a/b}')
    echo "  ratio for 4x models: ${ratio}x (linear ~4x, quadratic ~16x)" >&2

    # Sanity: the work really happened, so a crash cannot masquerade as speed.
    [[ $(_classify_n_models 200) == "200" ]] || {
        echo "classification did not confirm all 200 models" >&2
        false
    }

    awk -v r="$ratio" 'BEGIN{exit !(r < 8)}' || {
        echo "history-streak scaling regressed to quadratic: ${ratio}x for 4x the models" >&2
        false
    }
}

@test "history-streak scaling is linear across a 4x range of history depth" {
    # Same guard at a different point on the curve, so a regression that only
    # bites at depth (a full file re-read per model) is also caught.
    local small large ratio
    small=$(_time_classify 100 1)
    large=$(_time_classify 400 1)

    echo "  N=100: ${small}s   N=400: ${large}s" >&2
    ratio=$(awk -v a="$large" -v b="$small" 'BEGIN{printf "%.2f", a/b}')
    echo "  ratio for 4x models: ${ratio}x (linear ~4x, quadratic ~16x)" >&2

    [[ $(_classify_n_models 400) == "400" ]] || {
        echo "classification did not confirm all 400 models" >&2
        false
    }

    awk -v r="$ratio" 'BEGIN{exit !(r < 8)}' || {
        echo "history-streak scaling regressed to quadratic: ${ratio}x for 4x the models" >&2
        false
    }
}
