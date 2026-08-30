# Common Operations Runbook

This runbook covers common operational tasks for oc-model-manager.

## Daily Operations

### Run Full Audit
```bash
ocprobe audit
```
- Performs full catalog diff, probes new and whitelisted models
- Prompts for confirmation before applying changes
- Creates timestamped backup of config before applying

### Quick Check (Dry Run)
```bash
ocprobe check --quick
```
- Fast check: only probes new models, skips whitelist
- Exits with code 1 if changes pending, 0 if clean
- Suitable for cron jobs

### Check Status
```bash
ocprobe status
```
- Shows whitelisted models
- Shows last probe result per model
- Shows recent alerts

### View Alerts
```bash
ocprobe alerts
```
Shows all recorded alerts with timestamps.

```bash
ocprobe alerts --clear
```
Clears alert history.

## Continuous Monitoring

### Watch Mode (Foreground)
```bash
ocprobe watch
```
Runs `check` every 6 hours, logs results, never auto-applies.

```bash
ocprobe watch --quick
```
Quick watch mode (only new models).

### Background Scheduler (macOS)
```bash
ocprobe scheduler install
```
Installs launchd agent running `check` every 6 hours.

```bash
ocprobe scheduler uninstall
```
Removes the launchd agent.

```bash
ocprobe scheduler status
```
Shows scheduler status.

### Background Scheduler (Linux)
```bash
ocprobe scheduler install
```
Installs systemd user timer.

## Session Management

### List Sessions
```bash
ocprobe session list
```

### Backup Session
```bash
ocprobe session backup ses_abc123
```
Creates SQL dump of session in `~/.local/share/opencode/session-backups/`.

### Restore Session
```bash
ocprobe session restore /path/to/backup.sql
```

### Cleanup Probe Sessions
```bash
ocprobe session cleanup
```
Removes probe sessions created by ocprobe (safety: only fresh sessions with probe title).

## Configuration

### View Config
```bash
ocprobe config show
```

### Edit Config
```bash
ocprobe config edit
```

### Validate Config
```bash
ocprobe config validate
```

### View Schema
```bash
ocprobe config schema
```

### Show Config Path
```bash
ocprobe config path
```

## Health Checks

### Full Health Check
```bash
ocprobe doctor
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
1. Check backups: `ls ~/.config/opencode/opencode.json.ocprobe-backup-*`
2. Restore latest: `cp ~/.config/opencode/opencode.json.ocprobe-backup-YYYYMMDD-HHMMSS ~/.config/opencode/opencode.json`
3. Run `ocprobe doctor` to verify

### Mass Removal Guard Triggered
If you see: `MASS-REMOVAL GUARD: X/Y whitelisted models flagged dead`
1. Run `ocprobe check` to see details
2. Verify opencode is working: `ocprobe doctor`
3. If false positive, override: `OCPROBE_ALLOW_MASS_REMOVE=1 ocprobe audit`
4. Investigate root cause (network, auth, opencode version)

### Probe Timeouts
If probes consistently timeout:
1. Increase timeouts in config: `ocprobe config edit`
2. Check network connectivity to model providers
3. Check opencode auth: `opencode auth status`

### Scheduler Not Running
```bash
ocprobe scheduler status
ocprobe scheduler install
# Check logs:
cat ~/.local/state/ocprobe/scheduler.log
```

## Escalation

For issues not covered here:
1. Run `ocprobe doctor` and collect output
2. Check logs: `~/.local/state/ocprobe/audit-*.log`
3. Check opencode logs: `opencode --version`
4. File issue at: https://github.com/SunnyJayaRaju/oc-model-manager/issues