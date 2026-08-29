# ocm — OpenCode Model Manager

[![CI](https://github.com/SunnyJayaRaju/oc-model-manager/workflows/CI/CD%20Pipeline/badge.svg)](https://github.com/SunnyJayaRaju/oc-model-manager/actions)
[![Version](https://img.shields.io/badge/version-2.0.2-blue.svg)](VERSION)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

Enterprise-grade model catalog manager for [OpenCode](https://opencode.ai). Handles the full lifecycle: catalog diffing, live probing, alerting, safe application, and continuous monitoring.

## Features

- **Catalog Management**: Diff upstream catalog against whitelist, discover new models, detect removed models
- **Live Probing**: Test models with configurable timeouts, parallel execution, and intelligent status detection (WORKS, EOL, PAYWALLED, BROKEN, TIMEOUT, NOTFOUND)
- **Safety First**: Session cleanup only removes *this run's* probe sessions (verified via exact prompt match in DB), mass-removal guard prevents catastrophic whitelist wipes
- **Alerting**: Desktop notifications, webhook support, alert history with severity levels
- **Scheduler**: launchd (macOS) / systemd (Linux) integration for continuous monitoring
- **Session Management**: Backup/restore sessions to replayable SQL dumps
- **Health Checks**: `doctor` command validates entire stack
- **Observability**: Structured JSON logging, Prometheus metrics
- **Configuration**: YAML config with JSON Schema validation

## Installation

### Homebrew (macOS/Linux)
```bash
brew tap user/ocm
brew install ocm
```

### From Source
```bash
git clone https://github.com/SunnyJayaRaju/oc-model-manager.git
cd oc-model-manager
make install
```

### Manual
```bash
curl -sSL https://github.com/SunnyJayaRaju/oc-model-manager/releases/latest/download/ocm-2.0.1.tar.gz | tar -xz
sudo cp ocm-2.0.1/bin/ocm /usr/local/bin/
```

## Quick Start

```bash
# One-time setup
ocm config show          # View configuration
ocm doctor               # Verify installation

# Daily workflow
ocm audit                # Full audit: diff → probe → confirm → apply
ocm check                # Dry-run only (exit 1 if changes pending)
ocm status               # Show whitelist + recent probe results

# Continuous monitoring
ocm watch                # Check every 6h, never auto-applies
ocm scheduler install    # Install as background service

# Ad-hoc
ocm probe openai/gpt-4   # Test single model
ocm alerts               # View alert history
ocm session backup ses_abc  # Backup session
```

## Commands

| Command | Description |
|---------|-------------|
| `audit` | Full cycle: diff → probe → confirm → apply (default) |
| `check` | Dry-run only; exit 1 if changes pending |
| `status` | Show whitelisted models + recent probe results |
| `alerts [--clear]` | Show/clear recorded alerts |
| `probe <model>` | Test one model now |
| `watch` | Run check+alert on interval (never auto-applies) |
| `scheduler [install|uninstall|status]` | Manage background scheduler |
| `session [list|backup|restore|cleanup]` | Session management |
| `config [show|validate|edit|schema|path]` | Configuration management |
| `doctor` | Health check: config, DB, auth, disk |
| `version` | Show version |

## Global Options

| Option | Description |
|--------|-------------|
| `--quick` | Skip whitelist probe (audit/check only) |
| `--force-refresh` | Force catalog refresh (ignore cache) |
| `--yes, -y` | Assume yes to prompts |
| `--json` | Output JSON (machine-readable) |
| `--config <path>` | Override config file |
| `--verbose, -v` | Verbose logging |

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

## Safety Guarantees

1. **Session Isolation**: Only sessions created during *this run* with the exact probe prompt (`Reply with exactly: OK`) in the first message are deleted. Real conversations are never touched.

2. **Mass Removal Guard**: If >50% of whitelist would be removed in one run, `ocm` refuses to apply (override with `OCM_ALLOW_MASS_REMOVE=1`).

3. **Config Backups**: Every apply creates a timestamped backup (`opencode.json.ocm-backup-YYYYMMDD-HHMMSS`).

4. **Graveyard Cooldown**: Deliberately removed models won't be re-probed as "new" for 24h.

5. **Two-Failure Rule**: Transient failures (BROKEN, TIMEOUT, PAYWALLED) require 2 consecutive failed probes before removal.

## Architecture

```
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
```

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes with tests
4. Run `make lint test`
5. Submit a PR

See [CONTRIBUTING.md](CONTRIBUTING.md) for details.