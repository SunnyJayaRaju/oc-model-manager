#!/usr/bin/env bash
# shellcheck shell=bash
# ============================================================================
# lib/opencodecfg.sh — Reading and editing OpenCode's own config file
# ============================================================================
#
# OpenCode's config may be opencode.json (plain) or opencode.jsonc (comments,
# trailing commas, BOM). Everything here is safe for both:
#
#   - oc_config_read <file>       pure JSON on stdout (comments stripped)
#   - oc_config_patch_array       byte-span edit: touches ONLY the target array
#   - oc_generation               "2" on OpenCode 2.x, "1" otherwise
#
# The .jsonc writer never re-serialises the file: an owner's hand-written
# comments are data. When the array to edit does not exist yet in a .jsonc,
# the patch REFUSES and the caller prints the exact lines to add by hand —
# synthesising keys inside a commented file is where bytes get eaten.

# ---- jsonc.py ---------------------------------------------------------------
# Sits next to this file in a checkout (lib/) and in an install (lib/ocprobe/).
oc_jsonc_py() {
    printf '%s\n' "${BASH_SOURCE[0]%/*}/jsonc.py"
}

# Read a config file as pure JSON. Works for .json and .jsonc alike.
oc_config_read() {
    local file="$1"
    python3 "$(oc_jsonc_py)" load "$file"
}

# Replace the array at <dotted.key> in <file>, leaving every other byte
# identical. rc 3 = refused (key missing / not an array / unparseable).
oc_config_patch_array() {
    local file="$1" key="$2" array_json="$3"
    python3 "$(oc_jsonc_py)" patch "$file" "$key" "$array_json"
}

# Locate (read-only) the array at <dotted.key>: rc 0 = editable, rc 3 = refused.
oc_config_locate_array() {
    local file="$1" key="$2"
    python3 "$(oc_jsonc_py)" locate "$file" "$key"
}

# True when <file> is the comment-carrying flavour.
oc_config_is_jsonc() {
    [[ "${1##*.}" == "jsonc" ]]
}

# ---- Generation detection ----------------------------------------------------
# 2.x is detected from `opencode --version` (major >= 2). Session-layer code
# additionally checks for the session_v2 table via oc_db_is_v2 in db.sh, so a
# mismatched CLI is never trusted on its own.
oc_generation() {
    local v major
    v=$(opencode --version 2>/dev/null || true)
    # The major is the FIRST number in the output ("opencode 1.7.11" must give
    # 1, not 7 — a greedy match would grab the last "N." component instead).
    major=$(printf '%s' "$v" | sed -nE 's/^[^0-9]*([0-9]+).*/\1/p')
    [[ "$major" =~ ^[0-9]+$ ]] || major=1
    ((major >= 2)) && {
        echo 2
        return 0
    }
    echo 1
}

# ---- Whitelist/blacklist writers ---------------------------------------------
#
# oc_config_set_provider_array <config-file> <provider-id> <key> <new-array-json>
#
# Plain .json: whole-file rewrite is fine (ocm owns the formatting).
# .jsonc: patch the exact span; refuse when the array does not exist yet.
#   Refusal prints the exact lines the operator must add by hand.
# Returns:
#   0 = written
#   3 = refused for .jsonc (message printed); caller must not claim success
oc_config_set_provider_array() {
    local file="$1" pid="$2" key="$3" array_json="$4"
    local dotted="provider.${pid}.${key}"

    if ! oc_config_is_jsonc "$file"; then
        python3 - "$file" "$pid" "$key" "$array_json" <<'PY'
import json, os, sys
config_path = os.path.expanduser(sys.argv[1])
pid, key, array_json = sys.argv[2], sys.argv[3], sys.argv[4]
with open(config_path) as f:
    cfg = json.load(f)
prov = cfg.setdefault("provider", {}).setdefault(pid, {})
prov[key] = json.loads(array_json)
tmp = config_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, config_path)
PY
        return $?
    fi

    # .jsonc: every target must be locatable BEFORE anything is written, so a
    # refusal never leaves a half-applied config behind.
    if ! oc_config_locate_array "$file" "$dotted" 2>/dev/null; then
        log_error "refusing to edit $file: \"$dotted\" does not exist yet, and ocm never creates keys inside a commented config"
        log_error "add by hand inside the \"$pid\" provider object, then re-run:"
        log_error "    \"$key\": $array_json"
        return 3
    fi
    oc_config_patch_array "$file" "$dotted" "$array_json"
}
