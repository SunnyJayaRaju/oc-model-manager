# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [3.1.3] - 2026-09-28

A hardening release. Nothing here changes what `ocprobe` decides about your
models; it changes what it refuses to do, what it can no longer silently get
wrong, and what CI is now able to catch before you do.

### Security

- **`session restore` is now validated one statement at a time.** Restoring a
  session dump previously ran each statement through a SQLite authorizer and
  trusted that to be the only thing deciding what a dump may contain. Whether a
  statement produces authorizer callbacks at all is a property of your sqlite
  build, not of ocprobe, so a statement a build did not route to the authorizer
  was never offered to it. Two concrete consequences are now closed:
  - `INSERT INTO <table> DEFAULT VALUES` is a real INSERT on a table the
    allowlist permits, so it was accepted and wrote an all-NULL row over real
    data. A genuine backup never emits it, and it is now refused. A value that
    merely *reads* "DEFAULT VALUES" is still restored normally.
  - Every statement is now checked for a first keyword of `INSERT`, `REPLACE` or
    `WITH` before sqlite sees it, after stripping a BOM, Unicode whitespace and
    `--` / `/* */` comments. `REINDEX`, `ANALYZE` and `VACUUM` were already
    denied on the builds tested; this no longer depends on that being true.
  - Independently, a statement that runs without performing a single allowed
    INSERT is refused: it restored nothing.
  - A rejected dump leaves the database **byte-identical** — not merely
    unchanged in row count. This is asserted in CI against the installed
    package.

- **`delete_session` validates its target before deleting.** The title
  verification was subject to a pagination gap that could let a delete proceed
  against the wrong row; it is now done against the database rather than
  inferred from a paginated scan.

- **`validate --apply` re-acquires the lock and re-checks the config hash
  before writing.** A concurrent `ocprobe config edit` between discovery and
  apply could previously be overwritten by a blacklist built against a different
  config.

- **The `session restore` module runs under `python3 -B`.** It is imported by
  importlib, which made CPython try to write a `__pycache__` next to the module.
  In a Homebrew install that directory is read-only, so this was a hard failure
  rather than a cosmetic one.

### Fixed

- **The history lock now fails closed.** On lock timeout the write was skipped
  but the caller could not tell "skipped for contention" from "recorded". A
  sentinel now reaches the caller, and a contended record never runs its
  callback unlocked.

- **The streak cache no longer goes stale on a same-size rewrite.** It is keyed
  on a generation counter alongside byte size, bumped on every write. If the bump
  fails, that is now loud: previously both the temp write and the `mv` were
  swallowed, so an unwritable state directory produced a successful-looking
  record with a counter that never moved — reopening exactly the hole the
  counter exists to close. Now it warns, drops the in-process cache, and reports
  failure to the caller. A directory sitting where the sidecar belongs was the
  case `mv ||` structurally could not catch, because `mv` *succeeds* by moving
  the file inside it.

- **Config integers are validated and read in base 10.** A leading zero made
  bash read a value as octal, so `max_msg_count: 08` meant 0 and
  `history_limit: 0755` meant 493. Values are canonicalised to base 10 and
  range-checked before they reach SQL, arithmetic or XML contexts.

- **An empty or truncated catalog response can no longer poison the cache.** A
  floor guard drops a suspiciously small response rather than overwriting a
  good cache with nothing.

- **Three config keys were dead and said nothing.** `catalog.force_refresh`,
  `scheduler.enabled` and `scheduler.run_at_load` were declared in the schema
  and shipped in the generated config, but nothing ever read them — so
  `scheduler.enabled: false` did not disable the scheduler and
  `catalog.force_refresh: true` did not force a refresh. They are still accepted
  (removing them from the schema would make existing configs fail validation),
  now documented as having no effect, no longer written into new configs, and
  they log a single warning when set to a non-default value. Use
  `ocprobe probe --force-refresh`, which is the knob that works.

- **A Homebrew release could publish a formula that could not install.** The tag
  job fetched the published sha256 with `curl -sL`, which exits 0 on a 404 — so a
  tag that was not really released produced a formula whose sha256 was an HTML
  error page, and the job reported success. The updater now downloads the
  tarball, cross-checks its hash against the published one, and verifies its own
  edits landed. The token no longer reaches a `run:` body as an interpolated
  expression.

- **A release could be tagged with a version the source disagrees with.** The
  build job adopted whatever tag was pushed and overwrote `VERSION` with it. A
  tag must now match `^v[0-9]+\.[0-9]+\.[0-9]+$` *and* the `VERSION` file, and
  the check runs before anything is packaged.
- **The tap updater no longer assumes the formula has a `version` line.** A
  Homebrew formula normally takes its version from the url, and `brew audit`
  calls a `version` line that merely restates it redundant -- so the tap's
  formula drops it, and the updater used to write the url and the sha256 and
  *then* fail on the missing line. `url` and `sha256` are now the managed
  fields; `version` is updated when present and not added when absent. Every
  other check is unchanged: the tag pattern, `curl --fail`, the self-computed
  sha256 cross-checked against the published `.sha256`, 64-hex validation, the
  post-edit assertions and the idempotent no-op.

- **The release -> tap update can now be rehearsed without releasing anything.**
  A `workflow_dispatch` job builds the tarball the way the release job does,
  serves it and its `.sha256` from a local http server, runs the real updater
  against a copy of the formula, and prints the diff. It has no token, read-only
  permissions, and no way to push; that is asserted by tests rather than merely
  intended. Previously that path only ever ran on a real tag push, and only
  ever ran for real once.

### Performance

- **`validate` at real catalog scale is no longer quadratic.** The consecutive-
  failure streak was rebuilt by rescanning the history for every model. It is
  now folded in place, which is the difference between a run that finishes and
  one that does not at 900+ models — roughly **150x faster at 942 models**
  (measured: the 4x-model scaling ratio is ~4x, not ~16x, and is pinned by a
  test that fails above 8x).

- **The compiled bash 4.3 used by CI is cached**, so the job that tests the
  documented minimum shell no longer spends 3m20s rebuilding it on every run
  (27s to build, 0s to restore; the sha256 pin and the "is it really 4.3"
  assertion are both unchanged).

### Changed

- **macOS is a supported test target, on a real bash 4.3.** macOS ships bash 3.2
  and the codebase needs 4.3. The unit and integration legs now run on both
  platforms, and a separate leg runs the entire unit suite under a compiled
  bash 4.3.30 — the minimum the README advertises, which until now was asserted
  and never tested. Five array expansions aborted on 4.3 (expanding a
  declared-but-empty array is an error there before 4.4); they are fixed, and
  the suite is 314/314 on 3.2, 5.x and 4.3.30.

- **CI now checks the release tarball and the installed copy.** Nothing had
  ever looked inside the artifact, and the unit suite runs from the working
  tree where every file is present by definition — so a package missing
  `lib/session_restore.py` would have shipped a broken restore with CI green.
  A new job builds the tarball the way the release job does, installs it in the
  Homebrew layout, and runs version, doctor, a real restore and a
  multi-statement-bypass rejection against the installed binary.

- **The launchd bootstrap is now tested by mocking, on both platforms.**

### Notes for users

- No configuration file needs changing. The three reserved keys above keep
  validating; leaving them in place now logs a warning naming them.
- No database migration. Every change is to what ocprobe accepts and how it
  reports, not to the shape of your data.
- If you restore a session dump written by an older ocprobe, it still restores:
  the round-trip test covers the escaping both current and older sqlite builds
  produce for values containing newlines.

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
