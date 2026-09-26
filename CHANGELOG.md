# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.2] - 2026-09-26

### Fixed (found by a full-catalog `validate` run against 942 models)

- **Credit-limited keys blacklisted every paid model.** opencode sends the model's
  default max output tokens (e.g. `16384`, hardcoded from model metadata — verified
  that no `options.max_tokens` / `maxTokens` / `max_completion_tokens` / per-model
  `options` shape lowers it), so on a free or credit-limited key every paid model
  returns `402 "requires more credits ... can only afford 102"` even though the
  model works. That surfaced as a generic `ERROR` and counted toward the two-strike
  gate. Credit/quota messages now map to `BILLING_ERROR`, which is reported
  ("Blocked by account credits") but **never blacklisted** — the model works as soon
  as credits exist. This is the free-tier case the tool exists for.
- **Blacklist entries were not sticky:** the merge was
  `(previous - probed) ∪ confirmed`, so probing a blacklisted model for any reason
  (billing error, or merely being in scope of a scoped run) un-blacklisted it. Now
  `(previous - worked) ∪ confirmed` — an entry is dropped only when the model probes
  `WORKS`. The dry-run preview uses the same rule, so it no longer disagrees with
  what `--apply` writes.
- **No timeout-rate safety valve.** Every probe is a full `opencode run` agent
  contending for CPU and the SQLite DB, so parallelism inflates latency (measured
  ~2x at `-P 8`: 8.9s -> 16.3s, 13.1s -> 20.2s). A full-catalog run at `-P 8`
  produced **941/979 TIMEOUT** while single probes answered in <2s, marking 917
  models "tentative" — one more run would have confirmed them and retired the whole
  catalog. A provider whose timeout rate meets `OCPROBE_VALIDATE_TIMEOUT_THRESHOLD_PCT`
  (default 60) is now skipped with actionable guidance, mirroring the AUTH_ERROR abort.
- **Session leak:** `validate` left one session per probed model in the user's
  history — 842 leaked from a single 942-model run. Three compounding causes:
  (1) `validate` never called `cleanup_probe_sessions`; (2) cleanup enumerated
  candidates via `opencode session list`, which paginates at 100 rows, so it could
  only see/delete the first 100; (3) freshness was a fixed `< 1h` window, shorter
  than the 65-minute run itself. Cleanup now enumerates from the DB (complete),
  bounded by a recorded run-start timestamp, with age and message-count guards
  applied in SQL.
- **Probe sessions never matched by title:** workers title sessions
  `ocprobe-validate`, but cleanup only matched `ocprobe-probe*` / `ocmm-probe*`.
  All three prefixes are now matched from one place.
- **Session baseline unreliable:** built from the paginated CLI listing, silently
  omitting pre-existing sessions on busy histories. Now read from the DB.
- **False `AUTH_ERROR` on healthy models:** auth detection grepped bare `401|403`
  against the whole `opencode --format json` stream, which contains timestamps —
  `"timestamp":1790364416**401**` matched, marking working models as auth failures
  and tripping the provider-wide abort. Detection now runs on the parsed error
  message; bare status codes match only in an explicit status context.
- **Misleading dry-run diff:** `show_blacklist_diff` used `sort -u f1 f2 | uniq -c`
  and treated `count==1` as "present in one file only", but `sort -u` de-duplicates
  across both files, so when current == effective every model printed as "would be
  removed". Now uses `comm` set arithmetic — the same computation the counters use.
- **Command flags rejected:** `validate --provider/--model/--apply` and
  `alerts --clear` aborted with "Unknown global flag". Unknown flags after a
  subcommand are now passed through to that subcommand.
- **Install/upgrade layout:** `cp -r lib DIR` nests as `DIR/lib` when `DIR` exists,
  breaking every upgrade after the first. Installs copy contents instead.
- **Bootstrap misdetection:** a stray `VERSION` file (e.g. `~/.local/VERSION`)
  selected dev-mode paths for an installed copy, killing the CLI on a missing
  `lib/core.sh`. Layout is now detected by probing for the library that exists.
- **Unguarded `timeout`:** `fetch_catalog` called GNU `timeout` directly, absent on
  stock macOS (exit 127 → "catalog failed"). Added `run_with_timeout` in `core.sh`.
- **Stale catalog:** `cache_ttl_hours` 24 → 1. A 24h TTL on a catalog that changes
  hourly is why a newly available model (`openrouter/.../inkling:free`) went unseen
  for a day.

### Added / changed

- `validate` probes models in **parallel** (`OCPROBE_VALIDATE_MAX_PARALLEL`,
  default 4); it was sequential, making a 900+ model catalog infeasible. The worker
  is now self-contained (classify + vocabulary mapping + auth detection), which also
  removes a shared temp-file hazard that made concurrent probing unsafe.
- Modality skip patterns extended (`veo`, `lyria`, `imagen`, `flux`, `*-omni-*`,
  `*-live-*`, `*-realtime-*`, `*transcribe*`, `*translation*`, `*-audio-*`).
  Non-text models cannot answer a text probe and produced false verdicts.
- `validate` honours `--json` / `--verbose` in the global position as well as after
  the subcommand.
- Dry-run reports effective (merged) blacklist counts, so scoped runs no longer look
  like they would wipe unrelated entries.

### Added (policy/CI work, previously unreleased)
- Per-provider `auto_apply` enforcement in policy engine (audit/check only)
- Drift detection: `make drift-check` target and `ocprobe doctor` version/PATH reporting
- `lib/policy.sh`: `policy_effective_auto_apply()` and `policy_all_pending_auto_applyable()` helpers
- CI: default permissions `contents: read`; shellcheck covers legacy shims

### Changed

- Per-provider `auto_apply` now enforced in audit/check (previously schema-only)
- `README.md`: removed "NOT YET ENFORCED" notice; documented effective auto_apply rule
- `lib/doctor.sh`: added version/PATH drift reporting

### Verified

- Full catalog: 942 models probed across 5 credentialed providers; 0 probe sessions
  left behind; the user's 70 real sessions untouched.
- 134 unit + integration tests pass; shellcheck clean at warning level.
- `openrouter/thinkingmachines/inkling:free` verified as WORKS with the user's key and
  left visible; `openrouter/openai/gpt-4o` verified as BILLING_ERROR and left blacklisted.

## [3.1.1] - 2026-09-12

### Fixed

- Default modality skip patterns tightened: removed over-broad matchers (_function-calling_, _plugin_, _tool-use_) that incorrectly skipped chat models with tool-use capabilities
- **Validate two-failure gate**: load_validate_history now correctly restores consecutive failure counts from validate-history.jsonl (previously a no-op); WORKS now properly resets failure count in generate_validate_classification (previously filtered out); auth detection no longer treats rate limits / quota as AUTH_ERROR
- **lib/policy.sh**: load_policy now has explicit case for SCHEMA_ERROR (exit 3) with clear die message about missing/unreadable policy.schema.json

### Changed

- README / man page structure and command surface parity: policy subcommands documented, validate --verbose added, modality skip path wording corrected (defaults from install config dir, user override at ~/.local/state/ocprobe/validate-skip-patterns-user.txt)
- **lib/models.sh**: probe_batch log line now says "sequential" (honest about execution model); fetch_catalog uses portable stat (GNU stat -c %Y / BSD stat -f %m)
- **lib/policy.sh**: missing/unreadable policy.schema.json now causes hard failure (die) instead of soft-ignoring as invalid-disabled; added explicit case 3 for SCHEMA_ERROR
- **README.md**: Architecture tree now lists policy.sh under lib/; config/ expanded with policy.schema.json and validate-skip-patterns.txt; packaging/ corrected to Homebrew pointer only; legacy shim deprecation notes added
- **CHANGELOG.md**: [Unreleased] documents gate regression tests, policy SCHEMA_ERROR die message, Architecture listing; [3.1.0] AUTH_ERROR bullet corrected (quota exceeded removed)
- **.gitignore**: added secrets/credentials patterns (.env*, _.pem, *.key, id_rsa*, credentials_, auth.json, **/secrets.*, .ocprobe/, *.sqlite, *.db)
- **SECURITY.md**: reporting section now prefers GitHub Security Advisories + maintainer profile for sensitive reports; public issues for non-sensitive only
- **CI workflow**: removed non-existent 'develop' branch from push/PR triggers
- Legacy shims `oc-model-audit.sh`, `oc-model-manager`, `oc-session-backup` deprecated with stderr warnings; prefer `ocprobe` subcommands

## [3.1.0] - 2026-09-10

### Added

- Experimental policy engine scaffold:
  - Schema: `config/policy.schema.json` (version, enabled, auto_apply, never_remove, never_add, providers)
  - Loader: `lib/policy.sh` with fail-closed validation (parse error or invalid+enabled → die; invalid+disabled → warn and ignore; missing → no-op)
  - Glob matcher: `policy_glob_match` / `policy_match_any` (bash glob semantics, `*` matches `/`, case-sensitive)
  - CLI: `ocprobe policy` with `show|validate|path|init|dry-run` subcommands
  - Unit tests for glob matcher in `test/unit/policy.bats`
  - Integration tests in `test/integration/policy_wiring.bats`
- **Validate hardening (feature/validate-hardening):**
  - **Modality skip list**: `config/validate-skip-patterns.txt` + user file at `~/.local/state/ocprobe/validate-skip-patterns-user.txt`; matched models get `SKIPPED_MODALITY` status, never probed
  - **Two-failure gate**: `validate-history.jsonl` tracks consecutive failures; non-terminal failures require 2 consecutive failures before blacklisting; `WORKS` resets counter; `EOL`/`NOT_FOUND` confirm immediately
  - **AUTH_ERROR detection**: validate-local worker captures raw response, detects auth patterns (401, 403, Unauthorized, invalid_api_key, authentication failed) → `AUTH_ERROR` status; quota exceeded / rate limit handled as BILLING_ERROR (post-3.1.0 tightening now in Unreleased)
  - **Provider-wide AUTH_ERROR abort**: `OCPROBE_VALIDATE_AUTH_ERROR_THRESHOLD_PCT` (default 40%); if exceeded, provider skipped entirely
  - **Apply merge logic**: `apply_blacklist` merges by model-id: `new_blacklist = (previous - probed_this_run) ∪ confirmed_dead_this_run`; never wipes untouched entries
  - **Three-bucket verification**: `verify_blacklist_effect` returns WRITTEN/HIDDEN/STILL_VISIBLE; exit codes 0=all hidden, 2=some still visible, 1=hard error
  - **Dry-run exit codes**: 0=all hidden/nothing to do, 2=some still visible, 1=hard error
  - **UX improvements**: `--verbose` flag, progress logging (every 25 models/60s), large-run warning (>200 models), `--json` includes `schema_version`
  - **Per-provider `auto_apply`** accepted by schema but not yet enforced (global only for now)
  - **Integration tests** in `test/integration/validate_wiring.bats` for apply-merge-by-model-id and cmd_validate --apply exit-code-2 (STILL_VISIBLE)

### Changed

- Disabled by default; policy engine now active in audit/check when `enabled: true`
- `cmd_validate` dry-run exit codes: 0=all hidden/nothing to do, 2=some still visible, 1=hard error
- `apply_blacklist` merges by model-id: preserves entries for models not probed this run
- `verify_blacklist_effect` reports three buckets (written/hidden/still-visible) via globals

### Fixed

- Modality skip pattern defaults now correctly resolve via `OCPROBE_CONFIG_DIR` (previously derived from `opencode.json`'s location, which meant default skip patterns silently never loaded on real Homebrew/installed-mode setups); missing defaults file now warns once instead of failing silently
- `record_validate_history` uses portable millisecond timestamp (python)

## [3.0.3] - 2026-09-03

### Fixed

- Global flag parsing: flags now work correctly regardless of position (`ocprobe audit --quick` and `ocprobe --quick audit` both work)
- Fixed `OCPROBE_CONFIG_OVERRIDE` being silently reset even when set via environment variable
- Fixed non-portable awk regex that broke dead-model list extraction on Ubuntu/mawk (CI-only failure, invisible on macOS)
- Man page packaging now correctly installs the generated troff file, not raw Markdown

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
