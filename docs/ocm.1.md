% OCM(1) General Commands Manual
% Sunny Jayaraj
% August 2026

# NAME

ocm — OpenCode Model Manager

# SYNOPSIS

**ocm** [*global-options*] <command> [*command-options*]

# DESCRIPTION

**ocm** manages the OpenCode model catalog lifecycle: discovering new models, probing model health, alerting on failures, and safely applying whitelist changes.

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

    ocm audit [--quick] [--force-refresh] [--yes]

Exits 0 on success, 1 if user aborts or error.

## check

Dry-run only. Performs diff and probe but never writes config. Exits 1 if changes pending, 0 if clean.

    ocm check [--quick] [--force-refresh]

## status

Show current whitelist, recent probe results, and recent alerts.

    ocm status

## alerts

Show recorded alerts.

    ocm alerts [--clear]

**--clear**
: Clear alert history.

## probe

Test a single model immediately.

    ocm probe <provider/model>

Example: `ocm probe openai/gpt-4`

## watch

Run `check` on interval (default 6 hours), alert on changes. Never auto-applies.

    ocm watch [--quick]

Press Ctrl-C to stop gracefully.

## scheduler

Manage background scheduler (launchd on macOS, systemd on Linux).

    ocm scheduler install|uninstall|status

**install**
: Install and enable periodic check+alert.

**uninstall**
: Remove scheduler.

**status**
: Show scheduler status.

## session

Manage OpenCode sessions.

    ocm session list
    ocm session backup <session_id>
    ocm session restore <file.sql>
    ocm session cleanup

**list**
: List sessions with message counts and timestamps.

**backup**
: Dump session to replayable SQL file.

**restore**
: Restore session from SQL dump.

**cleanup**
: Remove probe sessions (ocmm-probe*).

## config

Manage configuration.

    ocm config show|validate|edit|schema|path

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

## doctor

Run health checks: opencode binary, Python, jq, sqlite3, config files, DB integrity, auth, disk space, scheduler.

    ocm doctor

Exits 0 if all critical checks pass, 1 otherwise.

## version

Show version.

    ocm version

# CONFIGURATION

Configuration file: `~/.config/ocm/config.yaml`

See `ocm config schema` for full schema. Key sections:

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

**OCM_CONFIG**
: Override config file path.

**OCM_STATE_DIR**
: Override state directory (default `~/.local/state/ocm`).

**OCM_LOG_LEVEL**
: Log level: debug, info, warn, error (default: info).

**OCM_LOG_FORMAT**
: Log format: text, json (default: text).

**OCM_ALLOW_MASS_REMOVE**
: Override mass-removal guard (set to 1).

# FILES

`~/.config/ocm/config.yaml`
: User configuration.

`~/.local/state/ocm/`
: State directory (history, alerts, graveyard, cache).

`~/.local/state/ocm/probe-history.jsonl`
: Probe history (JSON Lines).

`~/.local/state/ocm/alerts.jsonl`
: Alert history (JSON Lines).

`~/.local/state/ocm/graveyard.jsonl`
: Deliberately removed models with timestamps.

`~/.local/state/ocm/catalog-cache.json`
: Cached full catalog.

`~/.config/opencode/opencode.json.ocm-backup-*`
: Config backups before apply.

# EXAMPLES

Full audit with confirmation:
    ocm audit

Fast dry-run:
    ocm check --quick

Continuous monitoring:
    ocm scheduler install
    ocm watch

Test single model:
    ocm probe anthropic/claude-3

Backup session:
    ocm session backup ses_abc123

Health check:
    ocm doctor

# EXIT STATUS

0
: Success.

1
: Error, user abort, or changes pending (check command).

2
: Configuration or validation error.

# SEE ALSO

opencode(1), sqlite3(1), launchd.plist(5), systemd.timer(5)

# BUGS

Report bugs at: https://github.com/SunnyJayaRaju/oc-model-manager/issues