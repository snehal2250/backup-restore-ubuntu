# Backup Restore Ubuntu — Improvement Analysis

> **How to read this document (2026-08-02):** the analysis *body* below describes the
> repo **at analysis time** (commit `5d12f028`). Every finding carries a **status
> badge**, the **progress table** at the top of "Prioritized findings" tracks what is
> done vs. remaining, and the open items carry **"Resume here"** notes with the exact
> next step and where in the code to pick it up. The progress table reflects the
> **current** repo (HEAD `3659fd8` + uncommitted test suite and resumable-phase work).
> Where the body's "Retrieved facts" / "Executive assessment" disagree with a ✅
> completed badge, the badge is authoritative — the facts describe the pre-fix code as
> it was when this analysis was written.

## Repository state

- Repository: `backup-restore-ubuntu`
- Branch: `main`
- Commit at analysis time: `5d12f028c56af9b2df3301933021ce2492e58103` (current HEAD: `3659fd8`)
- Working tree: **dirty** — uncommitted as of 2026-08-02: the automated test suite (`tests/`, 7 files), the resumable-phase flags + durable phase journal (`restore.sh`, `lib/common.sh`), and doc updates (README, RESTORE.md, AGENTS.md, PLAN.md, this file)
- Untracked items observed at analysis time: `backups.artifacts`, `backups.staging/` (git-ignored runtime artifacts of backup.sh; cleaned on the next run)
- **Progress tracking last updated: 2026-08-02** — see the progress table + progress log at the top of "Prioritized findings" and the per-item "Resume here" notes below.
- Investigation scope: backup transactionality, inventory design, package reinstall strategy, configuration and service restoration, safety, portability, validation, testing, and documentation.
- Backup payloads and potentially sensitive configuration contents were intentionally not inspected.

## Executive assessment

The repository is aligned with the right recovery model: rebuild a fresh Ubuntu installation from a declared inventory, reinstall software from known sources, and restore only configuration and selected user data. The existing code already includes useful foundations such as an inventory-first design, path validation, source-aware installation checks, locking, staging, manifests, exclusions, service declarations, and snapshot rotation.

The highest-priority issue is that the current backup flow can overwrite the previous live manifest with `status: in_progress` before the staged backup has been successfully published. That contradicts the documented last-known-good guarantee and can cause a restore to reject an otherwise valid previous backup after an interrupted run.

## Prioritized findings

**Progress tracking (updated 2026-08-02)** — legend: ✅ completed · 🚧 in-progress (partial) · ⬜ pending · 🔓 unblocked (waiting on a dependency that has since landed) · ⛔ not-required (overengineering). "Resume" = the concrete next step for picking the item up again.

| Item | Status | Progress (what is done) | Remaining → resume here |
| --- | --- | --- | --- |
| P0 — Preserve the previous known-good manifest | ✅ | `manifest_in_progress` writes only to the staging manifest; the live `backups/backup-info.txt` is replaced only atomically by a verified `publish_backup`; restore refuses `in_progress` | — |
| P0 — Make publication atomic and fail closed | ✅ | same-filesystem check, fail-fast first rename, deterministic rollback, previous generation kept until final `status: ok` verification, cleanup trap | — (directory `fsync` documented-but-optional, README FAQ) |
| P0 — External backup selection (`--source`) | ✅ | full preflight: `realpath` resolution, verified manifest + artifact list, arch (fail) / Ubuntu (warn) / inventory-SHA (warn), writable-source warning, nothing copied/mounted implicitly | — |
| P1 — Structured installers | ✅ | schema v2 typed `installer:` records (11 types) dispatched by `lib/installers.sh`; no free-form `install_command` anywhere | — |
| P1 — Strict inventory schema + semantic validation | ✅ | `inventory/schema.yaml` v3 + real validator (`lib/schema_check.py`) + semantic checks (unique names, path overlap, `{version}` templates, platform gate) | — |
| P1 — Separate config/state/data/cache/secrets | 🚧 | `config_paths` vs `user_dirs` split + per-app `exclude:` lists cover config / user-data / cache in practice | **Per-path `class:` model + pre-backup secret scanner.** Resume: `inventory/schema.yaml` (class enum), `backup.sh` capture loop, `lib/common.sh` validation, tests |
| P1 — Restore conflict policies | ✅ | schema v3 `conflict_policy` (merge/replace/skip-existing/prompt), rollback bundle + restore journal, dry-run creates nothing | — (three-way merge: not-required) |
| P1 — Explicit phases + resumability | ✅ | `--plan` / `--from-phase` / `--only` / `--skip` / `--non-interactive`; durable phase journal (`phase-start`/`phase-done`); gating unit-tested | — |
| P1 — Backup completeness semantics | 🚧 | per-artifact `captured/missing/incomplete/empty`, overall `ok/degraded`, `status: ok` gate + `--force-incomplete` | **Per-item `required:` / `on_missing:` + `ok_with_warnings`/`failed` granularity.** Resume: `record_artifact` (backup.sh), `manifest_final`/`manifest_verify_restorable` (lib/common.sh), restore gating, schema v4, tests |
| P1 — Content integrity (SHA256SUMS) | ✅ | deterministic checksums on backup; restore verifies checksums, rejects hostile files + escaping symlinks, warns on extras; legacy snapshots warn | — (manifest/checksum signing: not-required) |
| P2 — Portability | 🚧 | `SUPPORTED_ARCHS`/`SUPPORTED_UBUNTU_RELEASES` gate, `ARCH_NORM`, manifest arch/os records checked by `--source` preflight | **Per-entry compat constraints + config-format migration hooks.** Resume: `inventory/schema.yaml` (per-app arch/release gates), `lib/catalog.sh` (Chrome AMD64 gate), `lib/installers.sh`, tests |
| P2 — Avoid backing up auth blindly | ⬜ | `exclude:` lists keep some token dirs out; docs post-restore checklist (RESTORE.md §5) | **`include:` lists + `secret` class + encrypted-secret workflow.** Resume: schema (shared with the classification item), `backup.sh`, docs |
| P2 — Reduce catalog/inventory drift | 🔓 | — (nothing shipped; the blocker — an automated test suite — landed 2026-08-02) | **`catalog:` + `overrides:` resolution + drift-report.** Resume: `lib/catalog.sh`, `inventory.sh`, resolve effective entries in `--plan`, tests |
| P2 — Testing strategy | ✅ | `tests/` plain-bash harness, 7 files, **202 assertions**: unit (integrity/rollback/journal/manifest/paths/phases) + interrupted-backup regression + static guards (bash -n, schema, no `rsync --delete`) | — (shellcheck + full-system VM tests tracked under the VM rehearsal item) |
| Suggested target layout | ⛔ | not-required (flat root scripts + `lib/` works at current scale) | — |

**Progress log (2026-08-02)** — shipped this session:

1. P0 — manifest staging isolation + atomic publication rollback (in `3b10951` "harden transactional publication").
2. P1 — schema v2 structured installers + versioned validation (`9002629`).
3. P0 — `--source` external-snapshot restore + P1 SHA256SUMS integrity (`d0aec8c`).
4. P1 — conflict policies + rollback bundle + restore journal, schema v3 (`3659fd8`).
5. P2 — automated test suite (`tests/`, 7 files / 202 assertions) — **uncommitted**.
6. P1 — resumable-phase flags + durable phase journal — **uncommitted**.

### P0 — Preserve the previous known-good manifest — ✅ completed

**Status:** ✅ completed — `manifest_in_progress` now writes **only** to the staging manifest (`backups.staging/backup-info.txt`); the live `backups/backup-info.txt` is replaced only atomically by `publish_backup` with a verified generation; interrupted runs leave the previous `status: ok` intact; restore refuses `in_progress` manifests. (Live-verified 2026-08-02: the leftover `in_progress` live manifest from an old interrupted run is truthfully rejected by `restore.sh`.)

**Retrieved facts**

- `backup.sh` states that a failed backup should leave the previous backup intact (`backup.sh:2-8`).
- It creates `backups.staging`, then calls `manifest_in_progress` before backup capture begins (`backup.sh:25-36`).
- `manifest_in_progress` writes directly to `$BACKUP_MANIFEST` (`lib/common.sh:321-330`).
- The final staged tree is not swapped into `backups/` until the end (`backup.sh:276-296`).

**Impact**

An interrupted backup can change the live `backups/backup-info.txt` to `status: in_progress` while the old backup data remains present. `manifest_verify_restorable` then rejects it (`lib/common.sh:382-405`). The previous data may still be valid, but its trusted manifest has been destroyed.

**Recommended change**

Write the in-progress manifest only inside the staging directory:

```bash
manifest_in_progress "$BACKUP_RUN_ID" > "$STAGE/backup-info.txt"
```

Refactor `manifest_in_progress` so it writes to stdout or accepts an explicit output path. Never write into `$BACKUPS_DIR` until the final atomic publication.

Also add an EXIT trap that removes only this run's staging directory and artifact file, without touching the published backup.

### P0 — Make publication genuinely atomic and fail closed — ✅ completed

**Status:** ✅ completed — `publish_backup` in `lib/common.sh`: same-filesystem verification before any rename, fail-fast first rename (never moves staging over an existing live dir), deterministic rollback, previous generation retained until the new one passes final `status: ok` verification, cleanup trap for interrupted runs. Directory `fsync` kept as documented-but-optional (README FAQ) — deliberately not on by default.

**Retrieved facts**

- The publication flow first renames `backups/` to a temporary old directory, then renames staging into place (`backup.sh:280-293`).
- The first `mv` is followed by `|| true` (`backup.sh:282`).

**Risk**

If the first rename fails, the script continues and may attempt to move staging over an existing destination. Recovery behavior then depends on filesystem and `mv` semantics. Atomicity also only holds when staging and destination are on the same filesystem.

**Recommended change**

- Fail immediately if the old live directory cannot be renamed.
- Create staging beside the live directory, as already done, and explicitly verify both paths are on the same filesystem.
- Use a cleanup trap and a deterministic rollback path.
- After publication, `fsync` is optional but worth documenting for users who need stronger crash consistency.
- Keep the old generation until the new generation has passed a final manifest verification, then remove it.

### P0 — Treat external backup selection as a first-class restore input — ✅ completed

**Status:** ✅ completed (2026-08-02) — `restore.sh --source <snapshot-dir>` implements the full preflight: `realpath` resolution, verified manifest + artifact list required (missing/`in_progress`/no-artifact-list sources are rejected), architecture (fail) / Ubuntu release (warn) / inventory-SHA (warn) compatibility checks, writable-source warning, prints the exact source before any system change, and copies/mounts nothing implicitly. Docs updated (README, RESTORE.md, REHEARSAL-VIRTUALBOX.md, PLAN.md, AGENTS.md). Live-tested against real mirror snapshots (happy path, mirror-root hint, `in_progress` rejection, missing source, arch mismatch).

The stated workflow restores from an externally attached drive, but the architecture should make the selected snapshot explicit rather than relying on repository-local `backups/`.

Add a restore interface such as:

```bash
./restore.sh --source /media/$USER/BackupDrive/backup-20260802-120000
```

The restore preflight should:

1. Resolve the source with `realpath`.
2. Require a final manifest and artifact list.
3. Verify inventory hash compatibility.
4. Verify architecture and Ubuntu-version compatibility.
5. Confirm that the source is not writable during restore, where practical.
6. Copy or mount nothing implicitly.
7. Print the exact source snapshot before any system changes.

This separation makes the Git checkout disposable and the backup medium authoritative.

### P1 — Replace arbitrary install commands with structured installers — ✅ completed

**Status:** ✅ completed — schema v2 typed `installer:` records (`apt`, `snap`, `snap_classic`, `flatpak`, `npm_global`, `pipx`, `cargo`, `apt_repository`, `deb`, `tarball`, `script`-as-last-resort) dispatched by `lib/installers.sh`; no free-form `install_command` anywhere; `inventory.sh` wizard + catalog emit the same structured records.

**Retrieved facts**

The inventory supports `script` and `custom` entries containing full shell commands (`inventory/inventory.yaml:39-44`). Current entries include remote install scripts and complex shell pipelines, including Opencode, uv, Azure CLI, Tailscale, Docker, GitHub CLI, and Cloudflared (`inventory/inventory.yaml:49-281`). The built-in catalog duplicates many of these commands (`lib/catalog.sh:13-244`).

**Risk**

- Remote `curl | bash` execution is not reproducible or auditable.
- Shell quoting inside YAML is fragile.
- Commands are duplicated between the catalog and inventory.
- It is difficult to validate idempotency, supported Ubuntu releases, architecture, signing keys, and expected package source.
- A changed upstream script can alter restore behavior without a repository change.

**Recommended design**

Use typed installer records instead of opaque shell:

```yaml
- name: docker
  installer:
    type: apt_repository
    repository_url: https://download.docker.com/linux/ubuntu
    suite: ubuntu_codename
    component: stable
    key_url: https://download.docker.com/linux/ubuntu/gpg
    key_fingerprint: "..."
    packages:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-buildx-plugin
      - docker-compose-plugin
```

Provide narrowly scoped installer functions for:

- Ubuntu apt
- signed third-party apt repository
- snap / classic snap
- Flatpak
- pipx
- npm global
- cargo
- verified `.deb`
- verified tarball
- remote script only as an explicit last-resort type

For remote scripts or downloaded artifacts, support a pinned checksum, signing-key fingerprint, or explicit `unverified: true` acknowledgement.

Move canonical app metadata to one place. The inventory should reference catalog entries and override only user-specific settings.

### P1 — Add a strict inventory schema and semantic validation — ✅ completed

**Status:** ✅ completed — versioned JSON Schema (`inventory/schema.yaml`, draft 2020-12) enforced by a real validator (`lib/schema_check.py`, python3 + reference `jsonschema`) plus semantic checks (unique names, `default_shell` provenance, config-path/`exclude` nesting, cross-owner path overlap, `{version}` templates, supported arch/Ubuntu-release gate) in `validate_inventory`.

The inventory is already the single source of truth (`inventory/inventory.yaml:1-23`), but it should be validated against a versioned schema.

Add:

```yaml
schema_version: 1
profile: workstation
```

Validate:

- unique app and service names
- allowed keys per installer type
- package names and source identifiers
- absolute service paths and `~/` user paths
- no path traversal
- no overlapping user-data/config declarations unless explicitly allowed
- no config path nested under an excluded path
- valid systemd unit names
- valid group names
- `default_shell` provided by a declared package
- duplicate configuration ownership
- unsupported architecture or Ubuntu release
- commands that require interactive input

Use a real YAML/schema validator rather than ad hoc parsing for structural checks.

### P1 — Separate configuration, state, data, cache, and secrets — 🚧 in-progress

**Status:** 🚧 in-progress — the `config_paths` vs `user_dirs` split plus per-app `exclude:` lists already cover config / user-data / cache / binary in practice. Not implemented: the explicit per-path `class:` model (config/state/user_data/cache/binary/secret) and the pre-backup scanner warning about credentials/keys/sockets.

**Resume here (concrete next step):** (1) add an optional `class` enum (`config|state|user_data|cache|binary|secret`, default `config`) to `config_paths` in `inventory/schema.yaml`; (2) honor `cache`/`binary`/`secret` in the `backup.sh` capture loop (skip them); (3) add a pre-backup scanner to `backup.sh` that warns on likely credential files (names/patterns: `token`, `key`, `.aws`, `.ssh`, browser profile dirs, `.docker/config.json`) without printing contents; (4) unit tests in `tests/`.

The current model distinguishes application configuration and user directories, which is a good start. It needs an explicit data classification model:

```yaml
paths:
  - path: ~/.config/example
    class: config
    restore: merge
  - path: ~/.local/share/example
    class: state
    restore: replace
  - path: ~/Documents
    class: user_data
    restore: merge
  - path: ~/.config/example/token.json
    class: secret
    backup: false
```

Recommended classes:

- `config`: restore after package installation
- `state`: optional, application-specific
- `user_data`: preserve user-created files
- `cache`: never back up
- `binary`: never back up
- `secret`: excluded by default or stored through a separate encrypted workflow

Add a pre-backup scanner that warns about likely credentials, private keys, browser profiles, cloud tokens, and socket files. Do not print secret contents.

### P1 — Define restore conflict policies — ✅ completed

**Status:** ✅ completed (2026-08-02) — per-owner `conflict_policy` (apps and services, schema v3): `merge` (default, the historical additive overlay) / `replace` (preserve into the rollback bundle, then exact mirror with `--delete`) / `skip-existing` (`--ignore-existing`) / `prompt` (per path, non-interactive skips). Every config restore captures what it overwrites into a timestamped rollback bundle under `~/.local/state/backup-restore-ubuntu/rollback-<ts>/` (outside the backup source) and appends one line per operation to its `restore-journal.log` (created/replaced/skipped/failed). Dry-runs create nothing; user-dirs stay merge-only (never delete user data). (The proposed `three-way` merge remains a future option — not-required.)

A fresh installation can still create default files before restoration. Each path should declare one of:

- `merge`: copy saved files without deleting new files
- `replace`: replace the destination after preserving it
- `skip-existing`: restore only missing files
- `prompt`: interactive decision
- `three-way`: future option for text configuration

Before modifying a destination, create a timestamped local rollback bundle. Generate a restore journal listing every path created, replaced, skipped, or failed.

Avoid broad `rsync --delete` behavior for home-directory content unless a path explicitly opts in.

### P1 — Introduce explicit restore phases and resumability — ✅ completed (2026-08-02)

**Status:** ✅ completed (2026-08-02) — `--plan` (phase-by-phase preview + dry-run detail), `--from-phase <phase>`, `--only`/`--skip <phases,apps>`, and `--non-interactive` are implemented in restore.sh. Phase names gate whole phases; app names filter the apps phase (so the handoff's `--only code,docker` example works), and `user-data` is accepted as an alias for the dotfiles phase. Unknown names in `--only`/`--skip` die (typo guard). The rollback bundle + journal are now created **up front** on real (non-dry-run) runs, and every enabled phase writes `phase-start`/`phase-done` markers to `restore-journal.log` — the durable phase journal. Gating lives in `lib/common.sh` (`phase_enabled`/`app_selected`/`phase_canonical`) and is unit-tested in `tests/test_phases.sh` (76 assertions).

Note: the flags map onto the EXISTING six phases (base/packages/apps/services/dotfiles/postinstall) rather than the aspirational 11-phase model sketched below — the finer split (preflight, package repositories, verification, …) would fragment the journal and add no behavioral value for a personal tool; the six-phase model is documented in docs/RESTORE.md.

Use a phase model with durable state:

1. preflight
2. base dependencies
3. package repositories
4. packages
5. user groups and shell
6. configuration
7. custom services
8. application extensions/plugins
9. service enable/start
10. verification
11. final report

Write a restore journal outside the backup source. Each phase should be restartable and idempotent. Support:

```bash
./restore.sh --plan
./restore.sh --from-phase packages
./restore.sh --only code,docker
./restore.sh --skip user-data
./restore.sh --non-interactive
```

Package installation failures should not silently disappear. Continue where safe, but return non-zero when required items fail.

### P1 — Improve backup completeness semantics — 🚧 in-progress

**Status:** 🚧 in-progress — per-artifact `captured`/`missing`/`incomplete`/`empty`, overall `ok`/`degraded`, and restore's `status: ok` requirement (with `--force-incomplete` override) are in place. Not implemented: per-item `required: true` / `on_missing:` policy and the finer `ok_with_warnings` / `failed` status granularity.

**Resume here:** (1) schema v4: optional per-app `required: true` and `on_missing: fail|warn`; (2) `record_artifact` in `backup.sh` distinguishes `missing` (required) from `missing-optional`; (3) `manifest_final` in `lib/common.sh` derives `ok_with_warnings`/`failed` from the artifact counts; (4) `manifest_verify_restorable` accepts `ok_with_warnings`, requires `--force-incomplete` for `degraded`, rejects `failed`; (5) extend `tests/test_manifest.sh`.

**Retrieved facts**

- Missing and incomplete artifacts degrade the manifest (`lib/common.sh:343-349`).
- Restore requires exactly `status: ok` (`lib/common.sh:382-405`).
- Missing configured paths are recorded during backup (`backup.sh:62-103`, `backup.sh:113-173`).

This is safe but overly coarse. A missing optional configuration path and a missing custom service unit have different severity.

Add per-item policy:

```yaml
required: true
on_missing: fail
```

Possible statuses:

- `ok`
- `ok_with_warnings`
- `degraded`
- `failed`

Restore should allow `ok_with_warnings`, reject `failed`, and require explicit override for `degraded`. The manifest should record exact warning and failure counts.

### P1 — Add integrity verification for backup contents — ✅ completed

**Status:** ✅ completed (2026-08-02) — `backup.sh` writes a deterministic `SHA256SUMS` over the staged payload (excluding the manifest and mutable logs); `restore.sh` verifies it before any config restore: checksum matches (missing/corrupt files fail), hostile special files (device/FIFO/socket) rejected, escaping symlinks rejected, extra files warned. Legacy snapshots without `SHA256SUMS` warn and proceed; a failed check refuses the restore unless `--force-incomplete`. The manifest still records only `inventory_sha256` (inventory identity, not content integrity). (Optional manifest/checksum signing is not-required for a personal tool.)

The manifest currently records provenance and artifact statuses (`lib/common.sh:333-377`) but not content integrity.

Generate a deterministic checksum file for all backed-up regular files, excluding the checksum and mutable logs:

```text
SHA256SUMS
```

At restore time:

- verify every listed file
- reject unexpected symlinks escaping the snapshot
- reject device files, FIFOs, and sockets
- validate file ownership metadata policy
- report missing and extra files
- optionally sign the manifest/checksum file with a user-controlled key

### P2 — Improve portability across Ubuntu releases and architectures — 🚧 in-progress

**Status:** 🚧 in-progress — `SUPPORTED_ARCHS` / `SUPPORTED_UBUNTU_RELEASES` gate, arch normalisation (`ARCH_NORM`), and manifest `arch:`/`ubuntu_version:` records (now also checked by the `--source` preflight) are in place. Not implemented: per-entry compatibility constraints and config-format migration hooks.

**Resume here:** (1) per-entry `installer.arch:`/`installer.releases:` gates in `inventory/schema.yaml` + `lib/installers.sh` (deb/tarball URLs already template `{arch}`); (2) gate the AMD64-only Google Chrome catalog entry (`lib/catalog.sh`); (3) migration hooks for config formats that changed across releases (typed per-app actions, not free-form scripts); (4) tests in `tests/`.

Record and validate:

- Ubuntu release and codename
- architecture
- desktop/session type
- source and target username
- source home directory
- package source compatibility
- systemd availability
- snap and Flatpak availability

Avoid assuming that paths or package names remain identical across releases. Add per-entry compatibility constraints and migration hooks for configuration formats.

The current Google Chrome installer is explicitly AMD64-specific in the catalog (`lib/catalog.sh:120-128`), so it needs architecture gating or an alternative package path.

### P2 — Avoid backing up application authentication blindly — ⬜ pending

**Status:** ⬜ pending — per-app `include:` lists, secret classification, and an encrypted-secret workflow are not implemented. Docs carry a manual post-restore checklist (RESTORE.md § 5) and `exclude:` lists keep some token dirs out — that covers the symptom, not the policy.

**Resume here (do together with the P1 classification item — same schema surface):** (1) optional `include:` globs per `config_paths` (back up only what is listed); (2) `class: secret`; (3) a `--no-secrets` backup mode or an encrypted-secret workflow; (4) extend the post-restore auth checklist (RESTORE.md §5).

Several declared configuration directories commonly contain authentication state or tokens, such as GitHub CLI, Google Cloud, Azure, Docker, browser profiles, and Cloudflare-related configuration (`inventory/inventory.yaml:75-281`).

Use per-app include lists rather than copying entire configuration roots wherever possible. For authentication:

- prefer re-login after restore
- export only non-secret settings
- place required secrets in a separate encrypted backup
- show a post-restore authentication checklist

### P2 — Reduce catalog/inventory drift — ⬜ pending

**Status:** 🔓 unblocked — the dependency noted in the body ("after behavior is covered by tests") landed 2026-08-02: the automated test suite (`tests/`, 7 files / 202 assertions) is the safety net for this refactor. The `catalog: <name>` + `overrides:` resolution model and a drift-report command are still not implemented.

**Resume here:** (1) schema: `catalog: <name>` + `overrides:` on apps (reference a catalog template instead of repeating values); (2) resolve effective entries in `inventory.sh list` and print resolved values in `restore.sh --plan`; (3) a drift-report command (`inventory.sh review --drift`) diffing inventory vs catalog defaults; (4) tests in `tests/`.

The catalog contains templates while the inventory repeats full generated values. That makes future catalog fixes ineffective for existing entries.

Store:

```yaml
- name: docker
  catalog: docker
  overrides:
    config_paths:
      - ~/.docker
```

Resolve the effective inventory at runtime and print it during `--plan`. Add a command to show drift between inventory entries and current catalog defaults.

### P2 — Testing strategy — ✅ completed (2026-08-02)

**Status:** ✅ completed — `tests/` is a plain-bash assertion harness (deliberately not Bats/ShellSpec: no extra dependency, mirrors the repo's bash-only style). `./tests/run.sh` runs everything and exits non-zero on any failure. Coverage:

- **Static checks** (`tests/test_static.sh`) — `bash -n` on every production + test script, real-inventory schema validation, schema v3 `conflict_policy` variant acceptance/rejection, and a regression guard asserting no `rsync --delete` invocation exists in backup.sh/restore.sh/lib (the critical conflict-policy data-loss bug).
- **Unit tests** — integrity helpers (checksum generation/verification, tamper, escaping symlink, FIFO, extra-file warn), rollback bundle + restore journal + `conflict_policy_get`, manifest helpers (staging-only `in_progress` marker, final status derivation, restorable verification), path safety (traversal + control-char rejection).
- **Interrupted-backup regression** (`tests/test_interrupted_backup.sh`) — `in_progress` marker isolation (live manifest never modified in place) plus `publish_backup` success / degraded-rollback / manifest-less-rollback / fail-fast (previous backup untouched) in a fully sandboxed repo.

The suite's first runs caught two real bugs, both fixed: a NUL-truncated control-character check in `normalize_path` (the `$'[\x00-\x1f\x7f]'` grep pattern embedded a literal NUL and silently let control chars through), and `conflict_policy_get` returning empty instead of `merge` for unknown owners.

Still out of scope here: `shellcheck` (tracked separately in docs/PLAN.md) and the full-system VM tests, which live under the VM rehearsal item (P2, item 9 below).

The roadmap notes that disposable-environment rehearsal remains important. Build an automated test pyramid:

#### Static tests

- `shellcheck`
- `shfmt --diff`
- YAML schema validation
- forbidden-pattern checks for unsafe path operations
- catalog/inventory consistency

#### Unit tests

Use Bats or ShellSpec for:

- path expansion and rejection
- manifest state transitions
- artifact status counting
- installer dispatch
- source-aware installed checks
- snapshot selection
- conflict policies
- cleanup traps

#### Integration tests

Run in Ubuntu containers where systemd is not required:

- inventory parsing
- backup staging
- interrupted backup preserving previous generation
- checksum verification
- dry-run/plan output
- package command construction with mocked package managers

#### Full system tests

Use a disposable Ubuntu VM:

1. provision fixture apps/config/services
2. create backup on a second virtual disk
3. destroy and reinstall the VM
4. restore from the attached disk
5. verify packages came from declared sources
6. verify configurations and services
7. run restore a second time to prove idempotency
8. inject failures and verify truthful non-zero status and rollback artifacts

The first regression test should reproduce the live-manifest corruption issue.

## Suggested target layout — ⛔ not-required

**Status:** ⛔ not-required (overengineering at current scale) — the flat root scripts + `lib/` layout is documented and working; splitting into `bin/` + `lib/manifest.sh` / `lib/paths.sh` / `lib/journal.sh` / `lib/installers/*.sh` would add churn without behavioral value. Revisit only if the scripts outgrow this structure.

```text
backup-restore-ubuntu/
├── bin/
│   ├── backup
│   ├── restore
│   └── inventory
├── lib/
│   ├── manifest.sh
│   ├── paths.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── journal.sh
│   └── installers/
│       ├── apt.sh
│       ├── apt_repository.sh
│       ├── snap.sh
│       ├── flatpak.sh
│       ├── pipx.sh
│       ├── npm.sh
│       └── verified_download.sh
├── inventory/
│   ├── inventory.yaml
│   └── schema.json
├── catalog/
│   └── apps.yaml
├── tests/
│   ├── unit/
│   ├── integration/
│   └── fixtures/
└── docs/
    ├── RESTORE.md
    ├── SECURITY.md
    ├── MANIFEST.md
    └── REHEARSAL-VIRTUALBOX.md
```

## Recommended implementation order

1. ✅ done — Fix manifest staging and publication rollback (`manifest_in_progress` → staging only; `publish_backup` with rollback).
2. ✅ done — Add regression tests for interrupted backup and previous-generation preservation (2026-08-02: `tests/test_interrupted_backup.sh` + the full `tests/` suite — see the P2 Testing item).
3. ✅ done — Add explicit `--source` snapshot selection and preflight verification (2026-08-02).
4. ✅ done — Add checksums and hostile-file/symlink validation (P1 integrity).
5. ✅ done — Add restore journal, conflict policies, and resumable phases (conflict policies + rollback bundle + journal 2026-08-02; resumable-phase flags `--plan`/`--from-phase`/`--only`/`--skip`/`--non-interactive` + durable phase journal 2026-08-02).
6. ✅ done — Introduce schema versioning and strict inventory validation.
7. ✅ done — Replace opaque custom commands incrementally with typed installers.
8. ⬜ pending (next-up with the classification item) — Add secret classification and encrypted-secret guidance. **Resume:** see the P2 "Avoid backing up auth blindly" item — `include:` lists + `class: secret` + encrypted workflow.
9. 🚧 in-progress — Add VM-based end-to-end restore rehearsal (VirtualBox rehearsal reached app 16/24; full clean run still outstanding — docs/PLAN.md). **Resume:** complete a full clean rehearsal run per docs/REHEARSAL-VIRTUALBOX.md §6.7–6.8 (static guest `/etc/resolv.conf` + unlocked screen — lessons already baked in), then an idempotency re-run.
10. 🔓 unblocked (tests landed 2026-08-02) — Refactor catalog/inventory duplication. **Resume:** see the P2 "Reduce catalog/inventory drift" item — `catalog:` + `overrides:` + drift-report, with the test suite as the safety net.

## Generated Repository Evidence

- **Repository:** `backup-restore-ubuntu`
- **Branch and commit:** `main` at `5d12f028c56af9b2df3301933021ce2492e58103`
- **Status:** dirty; untracked `backups.artifacts` and `backups.staging/`
- **Investigation scope:** architecture, transactional backup safety, package sources, inventory, config/data handling, services, integrity, restore UX, portability, tests, and documentation
- **Evidence documents read:** `README.md`, `AGENTS.md`, `docs/PLAN.md`
- **Important source files inspected:** `backup.sh`, `restore.sh`, `lib/common.sh`, `lib/catalog.sh`, `inventory/inventory.yaml`
- **Key finding:** the in-progress manifest is written to the live backup before staged publication, which can invalidate the previous known-good backup after interruption
- **Gaps:** no commands or tests were executed; backup payloads were not inspected; the repository-evidence generator rejected its request, so this analysis used targeted reads
- **Recommended next step (updated 2026-08-02):** all P0 items, P1 integrity / conflict-policies / phases / installers / schema, and the P2 test suite are shipped. Next open items, in order: **P1 backup completeness semantics** (finer `ok_with_warnings`/`failed` + per-item `required:`), then **P1 config/state/secrets classification** (which also unlocks P2 auth-blind backup), then **P2 catalog/inventory drift** (unblocked by tests). The **VM rehearsal** (item 9) continues independently — a full clean run is the remaining outstanding item.
