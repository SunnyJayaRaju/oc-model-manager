# ocprobe — OpenCode Model Probe

<p align="center">
  <img src=".github/assets/banner.svg" alt="ocprobe — OpenCode Model Probe" width="800"/>
</p>

[![CI](https://github.com/SunnyJayaRaju/oc-model-manager/actions/workflows/ci.yml/badge.svg?branch=main&style=flat-square)](https://github.com/SunnyJayaRaju/oc-model-manager/actions)
[![Version](https://img.shields.io/badge/version-3.0.3-blue.svg?style=flat-square)](VERSION)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)
[![Homebrew](https://img.shields.io/badge/homebrew-SunnyJayaRaju%2Focprobe-orange.svg?style=flat-square)](https://github.com/SunnyJayaRaju/homebrew-ocprobe)

---

## Why ocprobe?

Managing model catalogs in OpenCode is manual, error-prone, and unsafe. You diff catalogs by hand, probe models one by one, and risk wiping your whitelist with a bad apply. **ocprobe automates the full lifecycle**: catalog diffing → live probing → safety-gated apply → continuous monitoring — all with built-in guards so you never lose a working model or apply a broken one.

---

## At a Glance

```bash
# One-time setup
$ ocprobe doctor
[19:12:26] INFO  opencode: OK (1.18.25)
[19:12:26] INFO  python3: OK (Python 3.14.7)
[19:12:26] INFO  jq: OK
[19:12:26] INFO  sqlite3: OK
[19:12:26] INFO  config: OK (~/.config/ocprobe/config.yaml)
[19:12:26] INFO  config validation: OK
[19:12:26] INFO  opencode config: OK (~/.config/opencode/opencode.jsonc)
[19:12:26] INFO  DB: OK (~/.local/share/opencode/opencode.db)
[19:12:26] INFO  disk: OK (42G free)

# Daily workflow
$ ocprobe audit
[19:15:19] INFO  === ocprobe audit ===
[19:15:19] INFO  [1/7] Using cached catalog (age: 17h)
[19:15:19] INFO  [2/7] Whitelist: 12 models
[19:15:19] INFO  [3/7] NEW: 3 | GONE: 0
[19:15:19] INFO  [4/7] Probing 3 models (timeout 45s, parallel 4)...
[19:15:21] INFO  ✓ kilo/~anthropic/claude-3  WORKS (1.2s)
[19:15:21] INFO  ✓ openai/gpt-4o            WORKS (0.8s)
[19:15:21] INFO  ⚠ openrouter/unknown-model  NOTFOUND
[19:15:21] INFO  Apply changes? [y/N] y
[19:15:21] INFO  Whitelist updated: +2, -1

# Quick dry-run
$ ocprobe check --quick
[19:15:19] INFO  === ocprobe check ===
[19:15:19] INFO  [1/7] Using cached catalog (age: 17h)
[19:15:19] INFO  [2/7] Whitelist: 12 models
[19:15:19] INFO  [3/7] NEW: 1 | GONE: 0
[19:15:20] INFO  Exit code: 1 (changes pending)

# Continuous monitoring
$ ocprobe watch              # Runs check + alerts every 6h, never auto-applies
$ ocprobe scheduler install  # Install as launchd (macOS) or systemd (Linux) service
```

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Commands](#commands)
- [Global Options](#global-options)
- [Configuration](#configuration)
- [Safety Guarantees](#safety-guarantees)
- [Architecture](#architecture)
- [Development](#development)
- [License](#license)
- [Contributing](#contributing)

---

## Installation

### Homebrew (macOS / Linux)
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

---

## Quick Start

```bash
# One-time setup
ocprobe config show          # View current configuration
ocprobe doctor               # Verify installation (config, DB, auth, disk)

# Daily workflow
ocprobe audit                # Full cycle: diff → probe → confirm → apply
ocprobe check                # Dry-run only (exit 1 if changes pending)
ocprobe status               # Show whitelisted models + recent probe results

# Continuous monitoring
ocprobe watch                # Check + alert on interval (never auto-applies)
ocprobe scheduler install    # Install as background service (launchd/systemd)

# Ad-hoc
ocprobe probe openai/gpt-4   # Test a single model now
ocprobe alerts               # View alert history
ocprobe session backup ses_abc  # Backup session to SQL dump
```

---

## Commands

| Command | Description |
|---------|-------------|
| `audit` | Full cycle: diff → probe → confirm → apply (default) |
| `check` | Dry-run only; exit 1 if changes pending |
| `status` | Show whitelisted models + recent probe results |
| `alerts [--clear]` | Show/clear recorded alerts |
| `probe <model>` | Test one model now |
| `watch` | Run check+alert on interval (never auto-applies) |
| `validate [--provider <id>] [--model <id>] [--apply] [--json]` | Probe all models for configured providers, blacklist failures |
| `validate restore` | Revert opencode.json from last validate backup |
| `scheduler [install\|uninstall\|status]` | Manage background scheduler |
| `session [list\|backup\|restore\|cleanup]` | Session management |
| `config [show\|validate\|edit\|schema\|path]` | Configuration management |
| `doctor` | Health check: config, DB, auth, disk |
| `version` | Show version |
| `help` | Show help |

---

## Global Options

| Option | Description |
|--------|-------------|
| `--quick` | Skip whitelist probe (audit/check only) |
| `--force-refresh` | Force catalog refresh (ignore cache) |
| `--yes, -y` | Assume yes to prompts |
| `--json` | Output JSON (machine-readable) |
| `--dry-run` | Show what would be done without doing it |
| `--config <path>` | Override config file |
| `--verbose, -v` | Verbose logging |
| `--help, -h` | Show help |

---

## Configuration

Config file: `~/.config/ocprobe/config.yaml`

```yaml
version: 1
opencode:
  config_path: "~/.config/opencode/opencode.json"
  db_path: "~/.local/share/opencode/opencode.db"

probe:
  timeout_new: 45          # seconds for new models
  timeout_whitelist: 30    # seconds for whitelisted models
  max_parallel: 4          # concurrent probes
  prompt: "Reply with exactly: OK"
  title_prefix: "ocprobe-probe"

catalog:
  cache_ttl_hours: 24
  force_refresh: false

scheduler:
  enabled: false
  interval_seconds: 21600  # 6 hours
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

---

## Features

- **Catalog Management** — Diff upstream catalog against whitelist, discover new models, detect removed models
- **Live Probing** — Test models with configurable timeouts, parallel execution, and intelligent status detection (WORKS, EOL, PAYWALLED, BROKEN, TIMEOUT, NOTFOUND)
- **Safety First** — Session cleanup only removes *this run's* probe sessions (verified via exact prompt match in DB); mass-removal guard prevents catastrophic whitelist wipes
- **Alerting** — Desktop notifications, webhook support, alert history with severity levels
- **Scheduler** — launchd (macOS) / systemd (Linux) integration for continuous monitoring
- **Session Management** — Backup/restore sessions to replayable SQL dumps
- **Health Checks** — `doctor` command validates entire stack (config, DB, auth, disk)
- **Observability** — Structured JSON logging (`--json`), structured output for observability
- **Configuration** — YAML config with JSON Schema validation (`ocprobe config validate`)

---

## Validate Command

`ocprobe validate` probes every model offered by each provider that has valid API credentials in `~/.local/share/opencode/auth.json`. Models that respond successfully (`WORKS`) stay visible in OpenCode's model picker; models that fail (timeout, auth error, billing error, not found, or other error) are added to the provider's `blacklist` in `opencode.json`.

### Usage

```bash
# Dry-run: show what would be blacklisted (exit 0 if no changes, 1 if changes pending)
ocprobe validate

# Apply changes: write blacklist to opencode.json, create backup, verify effect
ocprobe validate --apply

# Scope to a single provider
ocprobe validate --provider openrouter

# Scope to a single model
ocprobe validate --provider nvidia --model nvidia/meta/llama-4-maverick-17b-128e-instruct

# Machine-readable output
ocprobe validate --json

# Restore from last validate backup
ocprobe validate restore
```

### Behavior

- **Default is dry-run** — prints a per-provider diff of proposed blacklist additions/removals
- **Uses blacklist (additive)** — only hides confirmed failures; does not whitelist-only (which would hide unprobed models)
- **Fresh every run** — no cached/stale blacklisting; every run re-probes all models
- **Creates backup on `--apply`** — timestamped backup in `~/.local/state/ocprobe/validate-backups/`
- **Verifies effect** — re-queries `opencode models` after apply; warns if OpenCode bug #32528 prevents blacklist from taking effect
- **Exit codes** — 0 = no changes needed; 1 = changes pending (dry-run) or error

### Classification

Each model is classified as:
| Status | Meaning |
|--------|---------|
| `WORKS` | Model responded with expected output |
| `TIMEOUT` | Probe exceeded timeout |
| `AUTH_ERROR` | Invalid/missing API key |
| `BILLING_ERROR` | Payment required, quota exceeded |
| `NOT_FOUND` | Model EOL, 404, or gone |
| `ERROR` | Other error (rate limit, server error, etc.) |

---

## Policy (experimental)

`ocprobe policy` provides a declarative rule engine for the audit/check pipeline.
**Disabled by default** — a missing file or `enabled: false` is a true no-op.

### Schema fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `version` | integer | **required** | Must be `1` |
| `enabled` | boolean | `false` | Master switch for the policy engine |
| `auto_apply` | boolean | `false` | Apply policy decisions without confirmation |
| `never_remove` | array of strings | `[]` | Models (provider/model) to never remove from whitelist |
| `never_add` | array of strings | `[]` | Models (provider/model) to never add to whitelist |
| `providers` | object | `{}` | Per-provider rules (see below) |

**Per-provider rules** (`providers.<provider>`):
- `enabled` (boolean, default: `true`) — enable/disable policy for this provider
- `include` (array of globs, default: `["*"]`) — models to consider
- `exclude` (array of globs, default: `[]`) — models to skip
- `auto_apply` (boolean, optional) — override global `auto_apply` for this provider

### Glob semantics

- Matching is against the FULL "provider/model" string, not path-segment-aware.
- `*` matches any sequence of characters, **including `/`** (so `anthropic/*`
  matches `anthropic/claude-3` and would also match `anthropic/x/y` — there
  is no slash-boundary special-casing).
- `?` matches exactly one character.
- `[...]` character classes work (native bash glob).
- Matching is case-sensitive.
- Empty or missing patterns file = no match, never an error.

### Commands

| Command | Description |
|---------|-------------|
| `ocprobe policy show` | Display current policy file (or note if missing) |
| `ocprobe policy validate` | Validate policy file against schema |
| `ocprobe policy path` | Print resolved policy file path |
| `ocprobe policy init` | Create a scaffold policy file (disabled) at default location |

### Current status

**Not yet wired into audit/check** — this release only adds the schema,
loader, and `ocprobe policy` inspection commands. Enforcement lands
in a future release.

---

## Safety Guarantees

1. **Session Isolation** — Only sessions created during *this run* with the exact probe prompt (`Reply with exactly: OK`) in the first message are deleted. Real conversations are never touched.

2. **Mass Removal Guard** — If >50% of whitelist would be removed in one run, `ocprobe` refuses to apply (override with `OCPROBE_ALLOW_MASS_REMOVE=1`).

3. **Config Backups** — Every apply creates a timestamped backup (`opencode.json.ocprobe-backup-YYYYMMDD-HHMMSS`).

4. **Graveyard Cooldown** — Deliberately removed models won't be re-probed as "new" for 24h.

5. **Two-Failure Rule** — Transient failures (BROKEN, TIMEOUT, PAYWALLED) require 2 consecutive failed probes before removal.

---

## Architecture

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
│   └── shim_helpers.sh # Shared shim utilities
├── config/
│   └── schema.json    # JSON Schema for config validation
├── test/
│   ├── unit/          # bats unit tests
│   └── integration/   # End-to-end tests
└── packaging/         # Homebrew, deb, rpm
```

---

## Development

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
```

---

## License

MIT License — see [LICENSE](LICENSE) for details.

---

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run `make lint test`
5. Submit a PR

**Documentation rule:** Any PR that adds a feature, changes a command's behavior, or changes a flag **MUST** update `README.md` and `CHANGELOG.md` in the same PR.

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.