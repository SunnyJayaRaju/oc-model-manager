# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.0.2] - 2026-09-01

### Fixed
- doctor command crashed with `cmd_scheduler: command not found` when run from a Homebrew-installed binary, because scheduler.sh was never sourced before calling cmd_scheduler in installed mode.

## [3.0.1] - 2026-08-30

### Fixed
- Release tarball missing `docs/ocprobe.1.md`, causing `brew install` to fail with `Errno::ENOENT: No such file or directory - docs/ocprobe.1.md`

## [3.0.0] - 2026-08-30

### Added
- `ocprobe validate` command: probe all models for providers with valid credentials, classify results (WORKS/TIMEOUT/AUTH_ERROR/BILLING_ERROR/NOT_FOUND/ERROR), and manage provider blacklists in opencode.json
- Dry-run mode (default) shows proposed blacklist changes without writing
- `--apply` flag writes blacklist changes with automatic backup and verification
- `--provider <id>` and `--model <id>` flags to scope validation
- `--json` flag for machine-readable output
- `validate restore` subcommand reverts to last validate backup
- Bootstrap auto-detection for dev vs installed mode (binary works from repo and when installed via `make install` / Homebrew)

### Changed
- Exit code convention: dry-run exits 0 when no changes needed, 1 when changes pending (matches `ocprobe check`)

### Breaking
- **BREAKING**: Renamed CLI from `ocm` to `ocprobe` — naming collisions with existing OCM/OpenCode-ecosystem tools. Binary, config dir (`~/.config/ocprobe/`), state dir (`~/.local/state/ocprobe/`), env var prefix (`OCPROBE_*`), log banners, backup suffix (`.ocprobe-backup-*`), and package names updated. Migration: on first run, existing `~/.config/ocm/config.yaml` is copied to new location if no new config exists.
- **BREAKING**: Install target now copies `lib/` and `config/` to `~/.local/` for standalone installed binary operation
- **BREAKING**: Binary bootstrap detects dev vs installed mode via `VERSION` file presence

## [2.0.10] - 2026-08-29

### Security
- Model name validation updated to support `kilo/~provider/model` format
- All SQL queries use proper escaping
- Umask 077 for state directories
- Read-only DB connections for queries

## [2.0.2] - 2026-08-29

### Fixed
- Homebrew release workflow now fails gracefully when tap token/repo not configured

### Changed
- CI: Homebrew job skips entirely (green) when HOMEBREW_TAP_TOKEN not set
- Updated `softprops/action-gh-release` from v1 to v2

## [2.0.3] - 2026-08-29

### Fixed
- Homebrew job token check using step output instead of invalid job-level env context

### Changed
- CI: Fixed workflow YAML parse error caused by `env.HOMEBREW_TAP_TOKEN` in job-level `if`

## [2.0.4] - 2026-08-29

### Fixed
- Homebrew formula update job now properly skips all steps when HOMEBREW_TAP_TOKEN not set

### Changed
- CI: Homebrew job uses step-level conditional outputs for graceful skip

## [2.0.1] - 2026-08-28

### Fixed
- Config parsing hardened with stricter validation
- Session handling improved (backup/restore reliability)
- TMPDIR unbound variable in session cleanup
- flock lock acquisition/release file descriptor leak
- Hardcoded test paths in integration tests
- Bats installation reliability in CI
- Integration test dependencies (generic package versions)
- Shellcheck v0.11.0 pinned for consistent linting

### Changed
- CI: Bats installed from source (v1.14.0) for reliability
- CI: Integration test dependencies use generic versions

### Documentation
- README updated for v2.0.1

## [2.0.0] - 2026-08-27

### Added
- Unified `ocm` CLI with subcommands (audit, check, status, alerts, probe, watch, scheduler, session, config, doctor)
- YAML configuration with JSON Schema validation (`~/.config/ocm/config.yaml`)
- Structured JSON logging and Prometheus metrics (`--json` flag)
- Session management: backup, restore, list, cleanup
- Health check command (`ocm doctor`)
- launchd (macOS) and systemd (Linux) scheduler integration
- Desktop notifications for critical alerts
- Webhook support for alerting
- Mass-removal safety guard (configurable threshold)
- Graveyard cooldown for deliberately removed models
- Two-failure rule for transient probe failures
- Comprehensive test suite (bats unit + integration tests)
- CI/CD pipeline (GitHub Actions: lint, test, build, release)
- Homebrew formula support
- Man page generation
- Architecture documentation (ADRs, runbooks)

### Changed
- **BREAKING**: Replaced `oc-model-manager` and `oc-model-audit.sh` with unified `ocm` CLI
- **BREAKING**: Config moved from env vars to YAML file
- **BREAKING**: State directory changed to `~/.local/state/ocm/`
- Probe engine now uses constants for prompt/title (single source of truth)
- Session cleanup uses batched SQLite queries (2 queries vs N×2)
- History parsing uses single `jq` call (5000x faster)
- Lock acquisition improved with stale PID detection

### Fixed
- TOCTOU race condition in lock acquisition
- Division by zero in mass-removal guard when whitelist empty
- SQL injection risk in probe session detection (parameterized)
- Duplicate `prune_history` function
- Duplicate `MODE` assignment

### Security
- Model name validation updated to support `kilo/~provider/model` format
- All SQL queries use proper escaping
- Umask 077 for state directories
- Read-only DB connections for queries
