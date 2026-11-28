# ocprobe — OpenCode Model Probe

<p align="center">
  <img src=".github/assets/banner.svg" alt="ocprobe — OpenCode Model Probe" width="800"/>
</p>

<p align="center">
  <a href="https://github.com/SunnyJayaRaju/oc-model-manager/actions"><img alt="CI: passing" src="https://github.com/SunnyJayaRaju/oc-model-manager/actions/workflows/ci.yml/badge.svg?branch=main&style=flat-square" /></a>
  <a href="VERSION"><img alt="Version: 3.2.2" src="https://img.shields.io/badge/version-3.2.2-blue.svg?style=flat-square" /></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green.svg?style=flat-square" /></a>
  <a href="https://github.com/SunnyJayaRaju/homebrew-ocprobe"><img alt="Homebrew: SunnyJayaRaju/ocprobe" src="https://img.shields.io/badge/homebrew-SunnyJayaRaju%2Focprobe-orange.svg?style=flat-square" /></a>
</p>

## 📌 At A Glance

ocprobe automates the full model catalog lifecycle: diff, probe, safety-gated apply and continuous monitoring.

Start with [Quick Start](#-quick-start).

## ❓ Why ocprobe?

Managing model catalogs in OpenCode is manual, error prone and unsafe. You diff catalogs by hand, probe models one by one
and risk wiping your whitelist with a bad apply. **ocprobe automates the full lifecycle**: catalog diffing → live probing →
safety-gated apply → continuous monitoring — all with built-in guards so you never lose a working model or apply a broken one.

<details>
<summary><b>Click to Open the Diagram</b></summary>

```mermaid
%%{init: {'flowchart': {'nodeSpacing': 40, 'rankSpacing': 50, 'padding': 16}}}%%
flowchart LR
  A["🔍 diff catalog"] --> B["🧪 probe models"] --> C["✅ confirm"] --> D["🛡️ safety apply"] --> E["📈 monitor"]
```

</details>

## 🗂️ Table of Contents

- [At A Glance](#-at-a-glance)
- [Why ocprobe?](#-why-ocprobe)
- [Installation](#-installation)
- [Upgrade and Uninstall](#-upgrade-and-uninstall)
- [OpenCode Version Support](#-opencode-version-support)
- [Quick Start](#-quick-start)
- [Commands](#-commands)
- [Global Options](#-global-options)
- [Configuration](#-configuration)
- [Features](#-features)
- [Validate Command](#-validate-command)
- [Policy (Experimental)](#-policy-experimental)
- [Safety Guarantees](#-safety-guarantees)
- [Security](#-security)
- [Troubleshooting and FAQ](#-troubleshooting-and-faq)
- [Architecture](#-architecture)
- [Development](#-development)
- [License](#-license)
- [Contributing](#-contributing)

## 💾 Installation

### Homebrew (macOS / Linux)

> **Note:** Legacy shims `oc-model-audit.sh`, `oc-model-manager`, and `oc-session-backup` are deprecated. Use `ocprobe` subcommands directly (`ocprobe audit`, `ocprobe check`, `ocprobe session`, etc.). They will be removed in a future major release.

```bash
brew tap SunnyJayaRaju/ocprobe
brew install ocprobe
```

> **Note:** The previous tap `SunnyJayaRaju/ocm` is deprecated. If you previously installed via `brew tap SunnyJayaRaju/ocm && brew install ocm`, please run `brew untap SunnyJayaRaju/ocm` and use the new tap above.

### From Source

```bash
git clone https://github.com/SunnyJayaRaju/oc-model-manager.git
cd oc-model-manager
make install
```

### Manual (Pre-built Release)

```bash
# Latest release: https://github.com/SunnyJayaRaju/oc-model-manager/releases/latest
VERSION=$(curl -s https://api.github.com/repos/SunnyJayaRaju/oc-model-manager/releases/latest | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4 | sed 's/^v//')
curl -sSL "https://github.com/SunnyJayaRaju/oc-model-manager/releases/latest/download/ocprobe-${VERSION}.tar.gz" | tar -xz
mkdir -p ~/.local/bin ~/.local/lib/ocprobe ~/.local/share/ocprobe
cp "ocprobe-${VERSION}/bin/ocprobe" ~/.local/bin/
cp -r "ocprobe-${VERSION}/lib/"* ~/.local/lib/ocprobe/
cp -r "ocprobe-${VERSION}/config" ~/.local/share/ocprobe/
cp "ocprobe-${VERSION}/VERSION" ~/.local/share/ocprobe/
# Ensure ~/.local/bin is in PATH (add to ~/.bashrc, ~/.zshrc, or ~/.profile if not already)
```

## 🔄 Upgrade and Uninstall

### Homebrew

```bash
brew update
brew upgrade ocprobe
```

Verify after upgrading:

```bash
brew test ocprobe
ocprobe version
```

Uninstall:

```bash
brew uninstall ocprobe
brew untap SunnyJayaRaju/ocprobe
```

### From Source

```bash
cd oc-model-manager
git pull
make install      # re-install from the updated checkout
make uninstall    # remove an installed copy
```

The tap formula is regenerated automatically when a release ships, so `brew upgrade` only sees a new version after `brew update` has refreshed the tap.

## 🔎 OpenCode Version Support

ocprobe works with OpenCode 1.x and 2.x. The generation is detected at runtime
from `opencode --version` (session work additionally checks for the
`session_v2` tables in the OpenCode database), and behavior is adjusted
automatically. What differs, verified against OpenCode 2.3.2 (2.3.x):

<details>
<summary><b>Click to Open the Diagram</b></summary>

**Version-by-version matrix**

| Behaviour                    | OpenCode 1.x                                                                                                                                   | OpenCode 2.x                                                                                                                                                                                                                                                                   |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Catalog (fetch + cache)      | Upstream catalog fetched once and cached in the state dir; refreshed after `catalog.cache_ttl_hours` or with `--force-refresh`                 | Same — the catalog is read from the same upstream and cache on both generations                                                                                                                                                                                                |
| OpenCode config read         | `opencode.json`                                                                                                                                | `opencode.jsonc` is preferred when it exists, else `opencode.json`. Both flavours are read the same way; comments, trailing commas and a BOM are supported                                                                                                                     |
| Editing the OpenCode config  | Plain JSON is rewritten as a whole; a `.jsonc` is patched in place so every byte outside the edited array, including comments, stays identical | Same. A key that does not exist yet inside a commented `.jsonc` is never synthesised: ocprobe refuses and prints the exact lines to add by hand                                                                                                                                |
| `apply` / `validate --apply` | Writes `provider.<id>.blacklist` as before                                                                                                     | **Refuses with an explicit message**: OpenCode 2.x does not honour per-provider model lists in the model catalog, so per-model hiding cannot work and nothing is written. `validate` and `monitor` keep working read-only, and `apply --dry-run` still reports pending changes |
| Probing                      | `opencode run --format json`                                                                                                                   | Same command (`--pure`, which older releases used, no longer exists in 2.x). The event stream differs (`step_start` / `text` / `step_finish`, plus one-line `error` objects); both shapes are parsed                                                                           |
| Session storage              | legacy `session` / `message` / `part` tables                                                                                                   | `session_v2` / `session_message` / `session_part` tables; legacy tables are never written to                                                                                                                                                                                   |
| `session cleanup`            | dry-run by default                                                                                                                             | Same, and it lists probe sessions from the v2 tables; `--apply` deletes through `opencode session delete`, one per call, and exits non-zero if any delete fails                                                                                                                |
| `session backup`             | SQL dump (`.sql`)                                                                                                                              | JSON document via `opencode session export`, which requires `OCPROBE_OPENCODE_SERVER` to be set to the server that owns the database                                                                                                                                           |
| `session restore`            | SQL dump restore (per-statement hardened SQLite path)                                                                                          | Refuses `.sql` dumps and restores the JSON backup through `opencode session import` with `OCPROBE_OPENCODE_SERVER` set                                                                                                                                                         |
| `scheduler`                  | launchd (macOS) / systemd (Linux) units for the 6-hour watch interval, installed and removed with `scheduler install` / `scheduler uninstall`  | Same; the units are generation-independent because they only run `ocprobe watch` (read-only: check + alerts, never auto-applies)                                                                                                                                               |

### Session Backup and Restore

The exact matrix, per generation:

| Generation   | `session backup` produces                                                                                                                                              | `session restore` accepts                                                                                                                                                                                                                                                                                                                                                                                          | What is refused, and why                                                                                                                                                                                                                                                                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| OpenCode 1.x | a `.sql` dump of the four session tables (`session`, `message`, `part`, and the task-list table), written as `INSERT OR REPLACE` so a restore is idempotent            | that `.sql` file. A copy of the whole database is taken first; the dump runs as one transaction, and SQLite's statement authorizer allows only plain `INSERT`s into those four tables (plus the `unistr()` string helper) — `ATTACH`, `DROP`, `DELETE`, `UPDATE`, `ALTER`, any `CREATE`, any `PRAGMA`, every other function and every read (`INSERT … SELECT`) are refused, and a rejected restore commits nothing | `.sql` files that contain any other statement type: the file can only ever add rows back into the four session tables                                                                                                                                                                                                                                                         |
| OpenCode 2.x | a JSON document produced by `opencode session export` — requires `OCPROBE_OPENCODE_SERVER` to name the server that owns this database; without it, nothing is exported | the JSON backup from `session backup`, imported through `opencode session import --server $OCPROBE_OPENCODE_SERVER`. This machine's database file is never written directly                                                                                                                                                                                                                                        | a `.sql` dump (the 2.x UI reads only the `session_v2` tables, so rows inserted into the legacy tables would be invisible — restoring one would look successful and change nothing), and a run with `OCPROBE_OPENCODE_SERVER` unset (an import through the wrong background service would write the session into a different database than the one the operator is looking at) |

</details>

## ⚡ Quick Start

```bash
# One-time setup
$ ocprobe config show          # View current configuration
$ ocprobe doctor               # Verify installation (config, DB, auth, disk)

# Daily workflow
$ ocprobe audit                # Full cycle: diff → probe → confirm → apply
$ ocprobe check                # Dry-run only (exit 1 if changes pending)
$ ocprobe check --quick        # Skip the whitelist probe
$ ocprobe status               # Show whitelisted models + recent probe results

# Validate (provider/model blacklist management)
$ ocprobe validate                # Dry-run: show proposed blacklist changes (exit 1 if pending)
$ ocprobe validate --apply        # Apply: write blacklist, create backup, verify effect

# Policy (experimental, disabled by default)
$ ocprobe policy show             # Show current policy (or note if missing)

# Continuous monitoring
$ ocprobe watch                # Check + alert on interval (never auto-applies)
$ ocprobe scheduler install    # Install as background service (launchd/systemd)

# Ad-hoc
$ ocprobe probe openai/gpt-4   # Test a single model now
$ ocprobe alerts               # View alert history
$ ocprobe session backup ses_abc  # Backup session (JSON on OpenCode 2.x, SQL dump on 1.x)
```

Verified locally:

```bash
ocprobe version
```

```text
ocprobe 3.2.2
```

## 📜 Commands

| Command                                                                    | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `audit`                                                                    | Full cycle: diff → probe → confirm → apply (default)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `check`                                                                    | Dry-run only; exit 1 if changes pending                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                 |
| `status`                                                                   | Show whitelisted models + recent probe results                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `alerts [--clear]`                                                         | Show/clear recorded alerts                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `probe <model>`                                                            | Test one model now                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                      |
| `watch`                                                                    | Run check+alert on interval (never auto-applies)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| `validate [--provider <id>] [--model <id>] [--apply] [--verbose] [--json]` | Probe all models for configured providers, blacklist failures                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `policy [show\|validate\|path\|init\|dry-run]`                             | Experimental, off by default; audit/check only (never validate)                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `validate restore`                                                         | Revert opencode.json from last validate backup                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `scheduler [install\|uninstall\|status]`                                   | Manage background scheduler                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| `session [list\|backup\|restore\|cleanup]`                                 | Session management. On OpenCode 2.x cleanup is a dry run by default (`--apply` to delete); backup/restore use `opencode session export`/`import` with `OCPROBE_OPENCODE_SERVER`                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| `session restore <file>`                                                   | On OpenCode 1.x: restore a `.sql` backup dump. A pre-restore copy of the database is taken first, and the dump is enforced **per statement** inside SQLite: only plain `INSERT`s into the four session tables are permitted (plus the `unistr()` string helper); `ATTACH`, `DROP`, `DELETE`, `UPDATE`, `ALTER`, any `CREATE`, any `PRAGMA`, any other function, and every read (`INSERT … SELECT`) are refused, and the whole file is one transaction. On OpenCode 2.x: `.sql` dumps are refused (the 2.x UI never reads rows inserted into the legacy tables) and the JSON backup from `session backup` is restored through `opencode session import` against the server in `OCPROBE_OPENCODE_SERVER`. |
| `config [show\|validate\|edit\|schema\|path]`                              | Configuration management                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| `doctor`                                                                   | Health check: config, DB, auth, disk                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| `version`                                                                  | Show version                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            |
| `help`                                                                     | Show help                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |

## 🎯 Global Options

| Option            | Description                              |
| ----------------- | ---------------------------------------- |
| `--quick`         | Skip whitelist probe (audit/check only)  |
| `--force-refresh` | Force catalog refresh (ignore cache)     |
| `--yes, -y`       | Assume yes to prompts                    |
| `--json`          | Output JSON (machine-readable)           |
| `--dry-run`       | Show what would be done without doing it |
| `--config <path>` | Override config file                     |
| `--policy <path>` | Override policy file path                |
| `--verbose, -v`   | Verbose logging                          |
| `--help, -h`      | Show help                                |

## 🔧 Configuration

Config file: `~/.config/ocprobe/config.yaml`

OpenCode's own config file is discovered as follows: an explicit `opencode.config_path` is used as given; otherwise `opencode.jsonc` is used when it exists next to the default path, else `opencode.json`. See [OpenCode version support](#-opencode-version-support).

```yaml
version: 1
opencode:
  config_path: "~/.config/opencode/opencode.json"
  db_path: "~/.local/share/opencode/opencode.db"

probe:
  timeout_new: 45 # seconds for new models
  timeout_whitelist: 30 # seconds for whitelisted models
  max_parallel: 4 # concurrent probes
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"

catalog:
  cache_ttl_hours: 24
  force_refresh: false

scheduler:
  enabled: false
  interval_seconds: 21600 # 6 hours
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
```

See `ocprobe config schema` for full schema.

### Reserved Keys

Three keys are still accepted by the schema so that existing config files keep
validating, but **nothing in ocprobe reads them**:

| Key                     | Default | Status              |
| ----------------------- | ------- | ------------------- |
| `catalog.force_refresh` | `false` | reserved, no effect |
| `scheduler.enabled`     | `false` | reserved, no effect |
| `scheduler.run_at_load` | `false` | reserved, no effect |

They are no longer written by `ocprobe config init`, and setting one to a
non-default value logs a single warning on startup. To force a catalog refresh,
use the `ocprobe probe --force-refresh` flag (or the `OCPROBE_FORCE_REFRESH`
environment variable), which is the knob that actually works.

## ✨ Features

- **Catalog Management** — Diff upstream catalog against whitelist, discover new models, detect removed models
- **Live Probing** — Test models with configurable timeouts, parallel execution, and intelligent status detection (WORKS, EOL, PAYWALLED, BROKEN, TIMEOUT, NOTFOUND)
- **Safety First** — Session cleanup only removes _this run's_ probe sessions (verified via exact prompt match in DB); mass-removal guard prevents catastrophic whitelist wipes
- **Alerting** — Desktop notifications, webhook support, alert history with severity levels
- **Scheduler** — launchd (macOS) / systemd (Linux) integration for continuous monitoring
- **Session Management** — Backup and restore probe sessions (SQL dumps on OpenCode 1.x, `opencode session export`/`import` on 2.x), guarded cleanup that only ever touches ocprobe's own probe sessions
- **Health Checks** — `doctor` command validates entire stack (config, DB, auth, disk)
- **Observability** — Structured JSON logging (`--json`), structured output for observability
- **Configuration** — YAML config with JSON Schema validation (`ocprobe config validate`)
- **Validate / Blacklist Management** — Two-failure gate, modality skip list, AUTH_ERROR provider-wide abort, three-bucket verify (WRITTEN/HIDDEN/STILL_VISIBLE)
- **Experimental Policy Engine** — Declarative rules for audit/check; off by default

## ✅ Validate Command

`ocprobe validate` probes every model offered by each provider that has valid API credentials in `~/.local/share/opencode/auth.json`. Models that respond successfully (`WORKS`) stay visible in OpenCode's model picker; models that fail (timeout, auth error, not found, or other error) are added to the provider's `blacklist` in the OpenCode config. On OpenCode 2.x, `validate --apply` refuses to write that list, because 2.x does not honour per-provider model lists in the catalog — see [OpenCode version support](#-opencode-version-support).

In one line: **what it does** — probes all models of every credentialed provider and classifies each; **how to run it** — `ocprobe validate` (dry-run by default, see [Usage](#usage) below); **what it changes** — with `--apply` on OpenCode 1.x only, the provider `blacklist` keys in the OpenCode config, with a timestamped backup first; **how to undo** — `ocprobe validate restore` reverts the config from the last validate backup (on OpenCode 2.x nothing is written, so there is nothing to undo).

**Billing errors are never blacklisted.** If a probe fails with `BILLING_ERROR`, the _account_ cannot currently afford that model's default output size — the model itself is fine and works as soon as credits exist. Blacklisting it would permanently hide a working model on a free or credit-limited key, so it is reported for review but never added to the blacklist, and it does not count toward the two-failure gate.

### Two-Failure Gate

Non-terminal failures (TIMEOUT, AUTH_ERROR, ERROR, UNCLEAR) require **two consecutive failures** before a model is added to the blacklist:

- First failure → `TENTATIVE` (not blacklisted, surfaced for review)
- Second consecutive failure → `CONFIRMED` (added to blacklist)
- `WORKS` at any point resets the failure counter
- `EOL` / `NOT_FOUND` → `CONFIRMED` immediately (terminal)
- `BILLING_ERROR` → never blacklisted, and does not advance the counter (see above)

### Modality Skip List

Models matching patterns in the default patterns file (installed at `share/ocprobe/validate-skip-patterns.txt` under the install prefix, resolved via `OCPROBE_CONFIG_DIR`) or the optional user override at `~/.local/state/ocprobe/validate-skip-patterns-user.txt` are **never probed** and receive `SKIPPED_MODALITY` status. Default patterns cover embeddings, reranking, image/audio/video generation, moderation, etc.

### AUTH_ERROR Provider-Wide Abort

If a provider's `AUTH_ERROR` rate exceeds `OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT` (default 40%), the provider is **skipped entirely** — no models are probed, no blacklist changes are made. This prevents blacklisting models due to credential/quota issues.

### Usage

```bash
# Dry-run: show what would be blacklisted (exit 0 if no changes, 1 if changes pending)
ocprobe validate

# Apply changes (OpenCode 1.x): write blacklist, create backup, verify effect
ocprobe validate --apply

# Scope to a single provider
ocprobe validate --provider openrouter

# Scope to a single model
ocprobe validate --provider nvidia --model nvidia/meta/llama-4-maverick-17b-128e-instruct

# Verbose per-model logging
ocprobe validate --verbose

# Machine-readable output with schema_version
ocprobe validate --json

# Restore from last validate backup
ocprobe validate restore
```

### Behavior

- **Default is dry-run** — prints a per-provider diff of proposed blacklist additions/removals
- **Uses blacklist (additive)** — only hides confirmed failures; does not whitelist-only (which would hide unprobed models)
- **Fresh every run** — no cached/stale blacklisting; every run re-probes all models
- **Creates backup on `--apply`** — timestamped backup in `~/.local/state/ocprobe/validate-backups/`
- **Verifies effect** — re-queries `opencode models` after apply; warns if OpenCode bug #32528 prevents blacklist from taking effect (OpenCode 1.x; `--apply` refuses on 2.x)
- **Exit codes** — 0 = success (all hidden or no changes); 2 = partial (some STILL_VISIBLE); 1 = error or dry-run with pending changes
- **Verbose mode** (`--verbose`) shows per-model status during probing
- **Progress logging** every 25 models (configurable via `OCPROBE_VALIDATE_PROGRESS_INTERVAL`)
- **Large-run warning** when catalog exceeds 200 models (configurable via `OCPROBE_VALIDATE_LARGE_RUN_THRESHOLD`)
- **JSON output** (`--json`) includes `schema_version` for forward compatibility

### Classification

Each model is classified as:

| Status             | Meaning                                              |
| ------------------ | ---------------------------------------------------- |
| `WORKS`            | Model responded with expected output                 |
| `TIMEOUT`          | Probe exceeded timeout                               |
| `AUTH_ERROR`       | Invalid/missing API key                              |
| `BILLING_ERROR`    | Payment required, quota exceeded                     |
| `NOT_FOUND`        | Model EOL, 404, or gone                              |
| `ERROR`            | Other error (rate limit, server error, etc.)         |
| `SKIPPED_MODALITY` | Model matched a modality skip pattern (never probed) |

## 🧪 Policy (Experimental)

`ocprobe policy` provides a declarative rule engine for the audit/check pipeline.
**Disabled by default** — a missing file or `enabled: false` is a true no-op.

In one line: **what it does** — filters audit/check candidates with declarative rules; **how to run it** — create a scaffold with `ocprobe policy init`, set `enabled: true`, then `ocprobe policy validate` and `ocprobe policy dry-run`; **what it changes** — nothing by itself: it only narrows or widens what audit/check would add or remove, and effective `auto_apply` skips the confirmation prompt without bypassing any guard; **how to undo** — set `enabled: false` or delete the policy file, which restores unfiltered audit/check behavior.

### Schema Fields

| Field          | Type             | Default      | Description                                            |
| -------------- | ---------------- | ------------ | ------------------------------------------------------ |
| `version`      | integer          | **required** | Must be `1`                                            |
| `enabled`      | boolean          | `false`      | Master switch for the policy engine                    |
| `auto_apply`   | boolean          | `false`      | Apply policy decisions without confirmation            |
| `never_remove` | array of strings | `[]`         | Models (provider/model) to never remove from whitelist |
| `never_add`    | array of strings | `[]`         | Models (provider/model) to never add to whitelist      |
| `providers`    | object           | `{}`         | Per-provider rules (see below)                         |

**Per-provider rules** (`providers.<provider>`):

- `enabled` (boolean, default: `true`) — enable/disable policy for this provider
- `include` (array of globs, default: `["*"]`) — models to consider
- `exclude` (array of globs, default: `[]`) — models to skip
- `auto_apply` (boolean, optional) — override global `auto_apply` for this provider

### Glob Semantics

- Matching is against the FULL "provider/model" string, not path-segment-aware.
- `*` matches any sequence of characters, **including `/`** (so `anthropic/*`
  matches `anthropic/claude-3` and would also match `anthropic/x/y` — there
  is no slash-boundary special-casing).
- `?` matches exactly one character.
- `[...]` character classes work (native bash glob).
- Matching is case-sensitive.
- Empty or missing patterns file = no match, never an error.

### Policy Commands

| Command                   | Description                                                  |
| ------------------------- | ------------------------------------------------------------ |
| `ocprobe policy show`     | Display current policy file (or note if missing)             |
| `ocprobe policy validate` | Validate policy file against schema                          |
| `ocprobe policy path`     | Print resolved policy file path                              |
| `ocprobe policy init`     | Create a scaffold policy file (disabled) at default location |
| `ocprobe policy dry-run`  | Show candidates & exclusions without probing or applying     |

### Current Status

**Wired into audit/check** — new-model candidates are filtered by `never_add` and provider `include`/`exclude` rules before probing; whitelisted models matching `never_remove` are protected from removal regardless of probe failures. The effective `auto_apply` (per-provider override or global) skips the confirmation prompt but **never bypasses** the mass-removal guard, backups, or graveyard recording.

**Per-provider `auto_apply` is enforced** — effective auto_apply for a provider/model is determined by:

- If `providers.<provider>.auto_apply` is explicitly set in the policy file → use it
- Otherwise → use global `auto_apply`

At confirmation time, the prompt is skipped only if policy is enabled AND every involved provider (from pending ADDS/DEAD) has effective `auto_apply = true`, OR global `auto_apply` covers all. If any provider has effective `auto_apply = false`, the prompt is kept (unless `--yes` / `OCPROBE_ASSUME_YES=1`).

## 🔒 Safety Guarantees

1. **Session Isolation** — Only sessions created during _this run_ with the exact probe prompt (`Reply with exactly: OK`) in the first message are deleted. Real conversations are never touched.

2. **Mass Removal Guard** — If >50% of whitelist would be removed in one run, `ocprobe` refuses to apply (override with `OCPROBE_ALLOW_MASS_REMOVE=1`).

3. **Config Backups** — Every apply creates a timestamped backup (`opencode.json.ocprobe-backup-YYYYMMDD-HHMMSS`).

4. **Graveyard Cooldown** — Deliberately removed models won't be re-probed as "new" for 24h.

5. **Two-Failure Rule** — Transient failures (BROKEN, TIMEOUT, PAYWALLED) require 2 consecutive failed probes before removal.

## 🔐 Security

Report vulnerabilities privately — see [SECURITY.md](SECURITY.md) for the supported versions, contact channel and what to include. Please do not open a public issue for a security report.

ocprobe's security posture, in brief:

- **Config edits are backed up first** — every apply writes a timestamped backup of the OpenCode config before touching it.
- **Restores are sandboxed** — on OpenCode 1.x a `.sql` restore runs as one transaction behind SQLite's statement authorizer (only plain `INSERT`s into the four session tables); on OpenCode 2.x restores go through `opencode session import` against the configured server, and the local database file is never written directly.
- **Session queries bind their parameters** — session ids are never interpolated into SQL.
- **Session cleanup is name-closed** — it only ever deletes sessions that this run created and that carry the exact probe prompt.

## 🧰 Troubleshooting and FAQ

<details>
<summary><b>Click to Open the Diagram</b></summary>

**Common questions and exact messages**

### `validate --apply` Refuses on OpenCode 2.x

The message is: `this OpenCode version does not honour provider model lists; nothing was changed (per-model hiding is not supported on OpenCode 2.x)`. This is expected: OpenCode 2.x ignores per-provider model lists in the catalog, so writing one would have no effect. `validate` keeps working read-only and `validate --dry-run` still reports pending changes. Use OpenCode 1.x for blacklist-based hiding, or manage model visibility through OpenCode 2.x's own UI.

### `ocprobe doctor` Says Python Is Missing PyYAML/jsonschema

The exact message is: `python: <interpreter> is missing PyYAML/jsonschema (needed to read ocm's own config)`. This applies to source/manual installs only — the Homebrew formula builds its own Python virtualenv, so `brew install` needs nothing. Fix for a source install: run `make setup` in a checkout, or `<interpreter> -m pip install PyYAML jsonschema`. `ocprobe doctor` prints the exact interpreter it resolved.

### Backup or Restore Says the Server URL Is Required

The exact message is: `backing up on OpenCode 2.x requires the server that owns this database: set OCPROBE_OPENCODE_SERVER=<url> (e.g. http://127.0.0.1:4096) and re-run` (restore prints the same with `restoring` instead of `backing up`). On OpenCode 2.x, sessions are moved through `opencode session export`/`import`, and both need the background server's URL so the backup lands in the database the server actually owns. Set `OCPROBE_OPENCODE_SERVER` and re-run.

### What Does `UNCLEAR` Mean?

A probe finished but the reply could not be classified as a definite status (the model answered, but not with the expected confirmation). `UNCLEAR` is a non-terminal failure: it counts toward the [two-failure gate](#two-failure-gate), so a single `UNCLEAR` never blacklists or removes a model on its own.

### Where Do Config, State, Cache and Logs Live?

| What                                                                      | Where                                                                                                                        |
| ------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| ocprobe config                                                            | `~/.config/ocprobe/config.yaml` (override with `OCPROBE_CONFIG`)                                                             |
| State (probe history, alerts, graveyard, catalog cache, validate backups) | `~/.local/state/ocprobe` (override with `OCPROBE_STATE_DIR`)                                                                 |
| Per-run audit logs                                                        | a fresh per-run directory under `$TMPDIR`, named `ocprobe.` plus random characters (`logging.file_enabled` controls writing) |
| OpenCode database                                                         | `~/.local/share/opencode/opencode.db`                                                                                        |
| OpenCode config                                                           | `~/.config/opencode/opencode.jsonc` or `.json`                                                                               |

### `ocprobe doctor` Warns About Multiple ocprobe in PATH

The warning `Multiple ocprobe in PATH (shadowing risk)` means more than one PATH entry resolves to an `ocprobe` binary — typically the Homebrew Cellar path and its `/opt/homebrew/bin` symlink, which point at the same install and are harmless. If the two paths are genuinely different installs, remove or reorder them so the intended one wins, then re-run `ocprobe doctor`.

</details>

## 📐 Architecture

```text
ocprobe (entry point)
├── lib/
│   ├── core.sh        # Shared utilities, validation
│   ├── config.sh      # YAML config + JSON Schema validation
│   ├── logging.sh     # Structured logging (text/JSON)
│   ├── locking.sh     # Process locking (mkdir atomicity)
│   ├── db.sh          # SQLite operations
│   ├── models.sh      # Catalog diff, probe engine, apply
│   ├── session.sh     # Session backup/restore/cleanup
│   ├── scheduler.sh   # launchd/systemd management
│   ├── doctor.sh      # Health checks
│   ├── validate.sh    # Provider/model validation & blacklist management
│   ├── policy.sh      # Experimental policy engine (audit/check only)
│   └── shim_helpers.sh # Shared shim utilities
├── config/
│   ├── schema.json            # JSON Schema for config validation
│   ├── policy.schema.json     # JSON Schema for policy validation
│   └── validate-skip-patterns.txt # Modality skip defaults
├── test/
│   ├── unit/          # bats unit tests
│   └── integration/   # End-to-end tests
└── packaging/         # Homebrew pointer only (live formula: homebrew-ocprobe)
```

## 💻 Development

```bash
# Run tests
make test

# Lint
make lint

# Build package
make build

# Install locally
make install

# Check version consistency
make version-check

# Drift detection (version, tags, installed binary, PATH)
make drift-check
```

## 📄 License

MIT License — see [LICENSE](LICENSE) for details.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run `make lint test`
5. Submit a PR

**Documentation rule:** Any PR that adds a feature, changes a command's behavior, or changes a flag **MUST** update `README.md` and `CHANGELOG.md` in the same PR.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.
