# Common Operations Runbook

This runbook covers common operational tasks for oc-model-manager.

## Daily Operations

### Run Full Audit
```bash
ocm audit
```
- Performs full catalog diff, probes new and whitelisted models
- Prompts for confirmation before applying changes
- Creates timestamped backup of config before applying

### Quick Check (Dry Run)
```bash
ocm check --quick
```
- Fast check: only probes new models, skips whitelist
- Exits with code 1 if changes pending, 0 if clean
- Suitable for cron jobs

### Check Status
```bash
ocm status
```
- Shows whitelisted models
- Shows last probe result per model
- Shows recent alerts

### View Alerts
```bash
ocm alerts
```
Shows all recorded alerts with timestamps.

```bash
ocm alerts --clear
```
Clears alert history.

## Continuous Monitoring

### Watch Mode (Foreground)
```bash
ocm watch
```
Runs `check` every 6 hours, logs results, never auto-applies.

```bash
ocm watch --quick
```
Quick watch mode (only new models).

### Background Scheduler (macOS)
```bash
ocm scheduler install
```
Installs launchd agent running `check` every 6 hours.

```bash
ocm scheduler uninstall
```
Removes the launchd agent.

```bash
ocm scheduler status
```
Shows scheduler status.

### Background Scheduler (Linux)
```bash
ocm scheduler install
```
Installs systemd user timer.

## Session Management

### List Sessions
```bash
ocm session list
```

### Backup Session
```bash
ocm session backup ses_abc123
```
Creates SQL dump of session in `~/.local/share/opencode/session-backups/`.

### Restore Session
```bash
ocm session restore /path/to/backup.sql
```

### Cleanup Probe Sessions
```bash
ocm session cleanup
```
Removes probe sessions created by ocm (safety: only fresh sessions with probe title).

## Configuration

### View Config
```bash
ocm config show
```

### Edit Config
```bash
ocm config edit
```

### Validate Config
```bash
ocm config validate
```

### View Schema
```bash
ocm config schema
```

### Show Config Path
```bash
ocm config path
```

## Health Checks

### Full Health Check
```bash
ocm doctor
```
Checks:
- opencode binary availability
- Python, jq, sqlite3 availability
- Config file existence and validity
- opencode config and DB existence
- DB integrity
- State directory accessibility
- Disk space
- opencode authentication
- Scheduler status
- State file sizes

## Emergency Procedures

### Config Corruption Recovery
1. Check backups: `ls ~/.config/opencode/opencode.json.ocm-backup-*`
2. Restore latest: `cp ~/.config/opencode/opencode.json.ocm-backup-YYYYMMDD-HHMMSS ~/.config/opencode/opencode.json`
3. Run `ocm doctor` to verify

### Mass Removal Guard Triggered
If you see: `MASS-REMOVAL GUARD: X/Y whitelisted models flagged dead`
1. Run `ocm check` to see details
2. Verify opencode is working: `ocm doctor`
3. If false positive, override: `OCM_ALLOW_MASS_REMOVE=1 ocm audit`
4. Investigate root cause (network, auth, opencode version)

### Probe Timeouts
If probes consistently timeout:
1. Increase timeouts in config: `ocm config edit`
2. Check network connectivity to model providers
3. Check opencode auth: `opencode auth status`

### Scheduler Not Running
```bash
ocm scheduler status
ocm scheduler install
# Check logs:
cat ~/.local/state/ocm/scheduler.log
```

## Escalation

For issues not covered here:
1. Run `ocm doctor` and collect output
2. Check logs: `~/.local/state/ocm/audit-*.log`
3. Check opencode logs: `opencode --version`
4. File issue at: https://github.com/SunnyJayaRaju/oc-model-manager/issues