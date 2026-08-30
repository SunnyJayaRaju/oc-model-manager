# Configuration Schema

This document describes the JSON Schema for the oc-model-manager configuration file.

## Schema Location

The schema is defined in `config/schema.json` and embedded in `lib/config.sh` as `CONFIG_SCHEMA`.

## Schema Structure

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

## Field Descriptions

### opencode
- `config_path`: Path to opencode's config file
- `db_path`: Path to opencode's SQLite database

### probe
- `timeout_new`: Timeout in seconds for probing new models
- `timeout_whitelist`: Timeout in seconds for probing whitelisted models
- `max_parallel`: Maximum concurrent probes
- `prompt`: The exact prompt sent to models during probing
- `title_prefix`: Prefix used for probe session titles

### catalog
- `cache_ttl_hours`: How long to cache the full model catalog
- `force_refresh`: Force catalog refresh on every run

### scheduler
- `enabled`: Enable automatic scheduling
- `interval_seconds`: Check interval in seconds (default: 6 hours)
- `run_at_load`: Run check immediately on scheduler start

### alerts
- `webhook_url`: Webhook URL for alert notifications
- `desktop_notifications`: Enable desktop notifications for critical alerts
- `batch_mode`: Suppress desktop notifications during batch operations

### session
- `age_guard_hours`: Sessions older than this are never deleted
- `fresh_guard_hours`: Sessions newer than this are considered fresh
- `max_msg_count`: Maximum messages in a probe session
- `backup_dir`: Directory for session backups

### retention
- `history_limit`: Maximum probe history entries
- `alert_limit`: Maximum alert entries
- `backup_keep_days`: Days to keep config backups
- `graveyard_cooldown_hours`: Hours before re-probing removed models

### safety
- `mass_removal_threshold_pct`: Percentage threshold for mass removal guard
- `allow_mass_remove_env`: Environment variable to override mass removal guard

### logging
- `level`: Log level (debug, info, warn, error)
- `format`: Log format (text, json)
- `file_enabled`: Enable file logging

## Validation

Run `ocprobe config validate` to validate your configuration file against this schema.