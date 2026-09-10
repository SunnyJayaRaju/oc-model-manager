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

## Validate (Blacklist Management)

### Dry-Run (Show Proposed Changes)
```bash
ocprobe validate
```
- Probes all models for configured providers
- Shows per-provider diff of proposed blacklist additions/removals
- Exit codes: 0 = no changes, 1 = changes pending, 2 = error
- Does NOT modify opencode.json

### Apply (Write Blacklist, Verify Effect)
```bash
ocprobe validate --apply
```
- Same probing as dry-run
- Creates timestamped backup of opencode.json
- Writes blacklist to opencode.json (merge-by-model-id, preserves unprobed entries)
- Verifies effect by re-querying opencode models picker
- Exit codes: 0 = all hidden, 2 = some STILL_VISIBLE (likely upstream OpenCode issue #32528), 1 = error

### Scope to Single Provider/Model
```bash
ocprobe validate --provider openrouter
ocprobe validate --provider nvidia --model nvidia/meta/llama-4-maverick-17b-128e-instruct
```

### Verbose / JSON Output
```bash
ocprobe validate --verbose
ocprobe validate --json
```

### Restore from Backup
```bash
ocprobe validate restore
```
- Reverts opencode.json to last validate backup
- Verifies restored config matches backup

### Exit Codes Summary
| Code | Meaning |
|------|---------|
| 0 | Success: all hidden or no changes |
| 1 | Error, or dry-run with pending changes |
| 2 | Partial: some STILL_VISIBLE (blacklist written but picker shows model) |

### Modality Skip List
Models matching patterns in `share/ocprobe/validate-skip-patterns.txt` (installed) or `~/.local/state/ocprobe/validate-skip-patterns-user.txt` (user override) are never probed, receive `SKIPPED_MODALITY` status.

### AUTH_ERROR Provider-Wide Abort
If a provider's AUTH_ERROR rate exceeds 40% (configurable via `OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT`), the provider is skipped entirely — no models probed, no blacklist changes.

## Policy (Experimental, Disabled by Default)

### Show Current Policy
```bash
ocprobe policy show
```

### Validate Policy File
```bash
ocprobe policy validate
```

### Print Policy Path
```bash
ocprobe policy path
```

### Initialize Scaffold
```bash
ocprobe policy init
```

### Dry-Run (Show Candidates & Exclusions)
```bash
ocprobe policy dry-run
```
Shows candidates & exclusions without probing or applying. Policy never applies to validate command.

---

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