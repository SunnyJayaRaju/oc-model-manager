% OCPROBE(1) General Commands Manual
% Sunny Jayaraj
% September 2026

# NAME

ocprobe — OpenCode Model Probe

# SYNOPSIS

**ocprobe** [*global-options*] <command> [*command-options*]

# DESCRIPTION

**ocprobe** manages the OpenCode model catalog lifecycle: discovering new models, probing model health, alerting on failures, and safely applying whitelist changes.

# GLOBAL OPTIONS

**--quick**
: Skip whitelisted model probing (audit/check only).

**--force-refresh**
: Force catalog refresh, ignoring cache.

**--yes**, **-y**
: Assume yes to confirmation prompts.

**--json**
: Output JSON for machine-readable results.

**--config** <path>
: Override configuration file path.

**--verbose**, **-v**
: Enable verbose (debug) logging.

**--help**, **-h**
: Show help and exit.

# COMMANDS

## audit

Full cycle: diff catalog → probe new/whitelisted models → confirm changes → apply to config.

    ocprobe audit [--quick] [--force-refresh] [--yes]

Exits 0 on success, 1 if user aborts or error.

## check

Dry-run only. Performs diff and probe but never writes config. Exits 1 if changes pending, 0 if clean.

    ocprobe check [--quick] [--force-refresh]

## status

Show current whitelist, recent probe results, and recent alerts.

    ocprobe status

## alerts

Show recorded alerts.

    ocprobe alerts [--clear]

**--clear**
: Clear alert history.

## probe

Test a single model immediately.

    ocprobe probe <provider/model>

Example: `ocprobe probe openai/gpt-4`

## watch

Run `check` on interval (default 6 hours), alert on changes. Never auto-applies.

    ocprobe watch [--quick]

Press Ctrl-C to stop gracefully.

## scheduler

Manage background scheduler (launchd on macOS, systemd on Linux).

    ocprobe scheduler install|uninstall|status

**install**
: Install and enable periodic check+alert.

**uninstall**
: Remove scheduler.

**status**
: Show scheduler status.

## session

Manage OpenCode sessions.

    ocprobe session list
    ocprobe session backup <session_id>
    ocprobe session restore <file.sql>
    ocprobe session cleanup

**list**
: List sessions with message counts and timestamps.

**backup**
: Dump session to replayable SQL file.

**restore**
: Restore session from SQL dump.

**cleanup**
: Remove probe sessions (ocprobe-probe*).

## config

Manage configuration.

    ocprobe config show|validate|edit|schema|path

**show**
: Display current config.

**validate**
: Validate config against schema.

**edit**
: Open config in $EDITOR.

**schema**
: Output JSON Schema.

**path**
: Show config file path.

## policy

Declarative rule engine for the audit/check pipeline. **Experimental, disabled by default** — a missing file or `enabled: false` is a true no-op. Policy never applies to the validate command.

    ocprobe policy [show|validate|path|init|dry-run]

**show**
: Display current policy file (or note if missing).

**validate**
: Validate policy file against JSON schema.

**path**
: Print resolved policy file path.

**init**
: Create a scaffold policy file (disabled) at default location.

**dry-run**
: Show candidates & exclusions without probing or applying.

## validate

Probe all models for providers with valid credentials and manage provider blacklists.

    ocprobe validate [--provider <id>] [--model <id>] [--apply] [--verbose] [--json]
    ocprobe validate restore

**--provider** <id>
: Only validate models for this provider.

**--model** <id>
: Only validate this specific model (requires --provider).

**--apply**
: Apply blacklist changes to opencode.json (default: dry-run).

**--verbose**
: Show per-model detail during probing.

**--json**
: Output JSON (machine-readable), includes schema_version.

**restore**
: Restore opencode.json from last validate backup.

### Two-Failure Gate

Non-terminal failures (TIMEOUT, AUTH_ERROR, BILLING_ERROR, ERROR, UNCLEAR) require **two consecutive failures** before a model is added to the blacklist:

- First failure → TENTATIVE (not blacklisted, surfaced for review)
- Second consecutive failure → CONFIRMED (added to blacklist)
- WORKS at any point resets the failure counter
- EOL / NOT_FOUND → CONFIRMED immediately (terminal)

### Modality Skip List

Models matching patterns in `~/.config/ocprobe/validate-skip-patterns.txt` (or user file at `~/.local/state/ocprobe/validate-skip-patterns-user.txt`) are **never probed** and receive SKIPPED_MODALITY status. Default patterns cover embeddings, reranking, image/audio/video generation, moderation, etc.

### AUTH_ERROR Provider-Wide Abort

If a provider's AUTH_ERROR rate exceeds OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT (default 40%), the provider is **skipped entirely** — no models are probed, no blacklist changes are made. This prevents blacklisting models due to credential/quota issues.

### Merge-by-ID Blacklist Apply

Blacklist changes merge by model id; they never wipe unprobed/untouched entries.

### Three-Bucket Verify

On --apply, after writing the blacklist, ocprobe re-queries the OpenCode picker and reports per-provider:
- WRITTEN: models successfully added to blacklist
- HIDDEN: blacklisted models no longer visible in picker
- STILL_VISIBLE: blacklisted models still visible (likely upstream OpenCode issue #32528)

### Exit Codes

- 0 = success (all hidden or no changes)
- 1 = error, or dry-run with pending changes
- 2 = partial (some STILL_VISIBLE)

## doctor

Run health checks: opencode binary, Python, jq, sqlite3, config files, DB integrity, auth, disk space, scheduler.

    ocprobe doctor

Exits 0 if all critical checks pass, 1 otherwise.

## version

Show version.

    ocprobe version

# CONFIGURATION

Configuration file: `~/.config/ocprobe/config.yaml`

See `ocprobe config schema` for full schema. Key sections:

- **opencode**: Paths to opencode config and DB
- **probe**: Timeouts, parallelism, prompt
- **catalog**: Cache TTL
- **scheduler**: Interval, enable/disable
- **alerts**: Webhook, desktop notifications
- **session**: Age guards, backup directory
- **retention**: History/alert limits, backup retention
- **safety**: Mass-removal threshold
- **logging**: Level, format, file output

# ENVIRONMENT VARIABLES

**OCPROBE_CONFIG**
: Override config file path.

**OCPROBE_STATE_DIR**
: Override state directory (default `~/.local/state/ocprobe`).

**OCPROBE_LOG_LEVEL**
: Log level: debug, info, warn, error (default: info).

**OCPROBE_LOG_FORMAT**
: Log format: text, json (default: text).

**OCPROBE_ALLOW_MASS_REMOVE**
: Override mass-removal guard (set to 1).

# FILES

`~/.config/ocprobe/config.yaml`
: User configuration.

`~/.local/state/ocprobe/`
: State directory (history, alerts, graveyard, cache).

`~/.local/state/ocprobe/probe-history.jsonl`
: Probe history (JSON Lines).

`~/.local/state/ocprobe/alerts.jsonl`
: Alert history (JSON Lines).

`~/.local/state/ocprobe/graveyard.jsonl`
: Deliberately removed models with timestamps.

`~/.local/state/ocprobe/catalog-cache.json`
: Cached full catalog.

`~/.config/opencode/opencode.json.ocprobe-backup-*`
: Config backups before apply.

# EXAMPLES

Full audit with confirmation:
    ocprobe audit

Fast dry-run:
    ocprobe check --quick

Continuous monitoring:
    ocprobe scheduler install
    ocprobe watch

Test single model:
    ocprobe probe anthropic/claude-3

Backup session:
    ocprobe session backup ses_abc123

Health check:
    ocprobe doctor

Validate dry-run (show proposed blacklist changes):
    ocprobe validate

Validate apply (write blacklist, create backup, verify effect):
    ocprobe validate --apply

Policy dry-run (show candidates & exclusions, experimental):
    ocprobe policy dry-run

# EXIT STATUS

0
: Success.

1
: Error, user abort, or changes pending (check command, validate dry-run).

2
: Configuration or validation error, or validate partial (STILL_VISIBLE).

# SEE ALSO

opencode(1), sqlite3(1), launchd.plist(5), systemd.timer(5)

# BUGS

Report bugs at: https://github.com/SunnyJayaRaju/oc-model-manager/issues
