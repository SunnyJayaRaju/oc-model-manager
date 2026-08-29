# ocm — OpenCode Model Manager

```text
╔═══════════════════════════════════════════════════════════════════╗
║                         ocm                                       ║
║              OpenCode Model Manager                               ║
║         Enterprise-grade catalog lifecycle                        ║
╚═══════════════════════════════════════════════════════════════════╝
```

[![CI](https://github.com/SunnyJayaRaju/oc-model-manager/workflows/CI/CD%20Pipeline/badge.svg?branch=main&style=flat-square)](https://github.com/SunnyJayaRaju/oc-model-manager/actions)
[![Version](https://img.shields.io/badge/version-2.0.8-blue.svg?style=flat-square)](VERSION)
[![License](https://img.shields.io/badge/license-MIT-green.svg?style=flat-square)](LICENSE)
[![Homebrew](https://img.shields.io/badge/homebrew-SunnyJayaRaju%2Focm-orange.svg?style=flat-square)](https://github.com/SunnyJayaRaju/homebrew-ocm)

---

## Why ocm?

Managing model catalogs in OpenCode is manual, error-prone, and unsafe. You diff catalogs by hand, probe models one by one, and risk wiping your whitelist with a bad apply. **ocm automates the full lifecycle**: catalog diffing → live probing → safety-gated apply → continuous monitoring — all with built-in guards so you never lose a working model or apply a broken one.

---

## At a Glance

```bash
# One-time setup
$ ocm doctor
[19:12:26] INFO  opencode: OK (1.18.25)
[19:12:26] INFO  python3: OK (Python 3.14.7)
[19:12:26] INFO  jq: OK
[19:12:26] INFO  sqlite3: OK
[19:12:26] INFO  config: OK (~/.config/ocm/config.yaml)
[19:12:26] INFO  config validation: OK
[19:12:26] INFO  opencode config: OK (~/.config/opencode/opencode.jsonc)
[19:12:26] INFO  DB: OK (~/.local/share/opencode/opencode.db)
[19:12:26] INFO  disk: OK (42G free)

# Daily workflow
$ ocm audit
[19:15:19] INFO  === ocm audit ===
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
$ ocm check --quick
[19:15:19] INFO  === ocm check ===
[19:15:19] INFO  [1/7] Using cached catalog (age: 17h)
[19:15:19] INFO  [2/7] Whitelist: 12 models
[19:15:19] INFO  [3/7] NEW: 1 | GONE: 0
[19:15:20] INFO  Exit code: 1 (changes pending)

# Continuous monitoring
$ ocm watch              # Runs check + alerts every 6h, never auto-applies
$ ocm scheduler install  # Install as launchd (macOS) or systemd (Linux) service
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
brew tap SunnyJayaRaju/ocm
brew install ocm
```

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
curl -sSL "https://github.com/SunnyJayaRaju/oc-model-manager/releases/latest/download/ocm-${VERSION}.tar.gz" | tar -xz
sudo cp "ocm-${VERSION}/bin/ocm" /usr/local/bin/
```

---

## Quick Start

```bash
# One-time setup
ocm config show          # View current configuration
ocm doctor               # Verify installation (config, DB, auth, disk)

# Daily workflow
ocm audit                # Full cycle: diff → probe → confirm → apply
ocm check                # Dry-run only (exit 1 if changes pending)
ocm status               # Show whitelisted models + recent probe results

# Continuous monitoring
ocm watch                # Check + alert on interval (never auto-applies)
ocm scheduler install    # Install as background service (launchd/systemd)

# Ad-hoc
ocm probe openai/gpt-4   # Test a single model now
ocm alerts               # View alert history
ocm session backup ses_abc  # Backup session to SQL dump
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
| `--config <path>` | Override config file |
| `--verbose, -v` | Verbose logging |
| `--help, -h` | Show help |

---

## Configuration

Config file: `~/.config/ocm/config.yaml`

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
  title_prefix: "ocmm-probe"

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
  allow_mass_remove_env: "OCM_ALLOW_MASS_REMOVE"

logging:
  level: info
  format: text
  file_enabled: true
```

See `ocm config schema` for full schema.

---

## Features

- **Catalog Management** — Diff upstream catalog against whitelist, discover new models, detect removed models
- **Live Probing** — Test models with configurable timeouts, parallel execution, and intelligent status detection (WORKS, EOL, PAYWALLED, BROKEN, TIMEOUT, NOTFOUND)
- **Safety First** — Session cleanup only removes *this run's* probe sessions (verified via exact prompt match in DB); mass-removal guard prevents catastrophic whitelist wipes
- **Alerting** — Desktop notifications, webhook support, alert history with severity levels
- **Scheduler** — launchd (macOS) / systemd (Linux) integration for continuous monitoring
- **Session Management** — Backup/restore sessions to replayable SQL dumps
- **Health Checks** — `doctor` command validates entire stack (config, DB, auth, disk)
- **Observability** — Structured JSON logging (`--json`), Prometheus metrics
- **Configuration** — YAML config with JSON Schema validation (`ocm config validate`)

---

## Safety Guarantees

1. **Session Isolation** — Only sessions created during *this run* with the exact probe prompt (`Reply with exactly: OK`) in the first message are deleted. Real conversations are never touched.

2. **Mass Removal Guard** — If >50% of whitelist would be removed in one run, `ocm` refuses to apply (override with `OCM_ALLOW_MASS_REMOVE=1`).

3. **Config Backups** — Every apply creates a timestamped backup (`opencode.json.ocm-backup-YYYYMMDD-HHMMSS`).

4. **Graveyard Cooldown** — Deliberately removed models won't be re-probed as "new" for 24h.

5. **Two-Failure Rule** — Transient failures (BROKEN, TIMEOUT, PAYWALLED) require 2 consecutive failed probes before removal.

---

## Architecture

```text
ocm (entry point)
├── lib/
│   ├── core.sh        # Shared utilities, validation
│   ├── config.sh      # YAML config + JSON Schema validation
│   ├── logging.sh     # Structured logging (text/JSON)
│   ├── locking.sh     # Process locking (mkdir atomicity)
│   ├── db.sh          # SQLite operations
│   ├── models.sh      # Catalog diff, probe engine, apply
│   ├── session.sh     # Session backup/restore/cleanup
│   ├── scheduler.sh   # launchd/systemd management
│   └── doctor.sh      # Health checks
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