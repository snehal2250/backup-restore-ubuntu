# Backup Restore Ubuntu — Improvement Analysis

> **How to read this document (2026-08-02):** the analysis *body* below describes the
> repo **at analysis time** (commit `5d12f028`). Every finding now carries a **status
> badge** and the summary table at the top of "Prioritized findings" reflects the
> **current** repo (HEAD `9002629` + uncommitted `--source` work). Where the body's
> "Retrieved facts" / "Executive assessment" disagree with a ✅ completed badge, the
> badge is authoritative — the facts describe the pre-fix code as it was when this
> analysis was written.

## Repository state

- Repository: `backup-restore-ubuntu`
- Branch: `main`
- Commit at analysis time: `5d12f028c56af9b2df3301933021ce2492e58103` (current HEAD: `9002629`)
- Working tree: **dirty** (uncommitted `--source` feature + this status update, 2026-08-02)
- Untracked items observed: `backups.artifacts`, `backups.staging/`
- **Status labels last updated: 2026-08-02** — every finding below carries its own status badge, and the summary table at the top of the findings lists them all.
- Investigation scope: backup transactionality, inventory design, package reinstall strategy, configuration and service restoration, safety, portability, validation, testing, and documentation.
- Backup payloads and potentially sensitive configuration contents were intentionally not inspected.

## Executive assessment

The repository is aligned with the right recovery model: rebuild a fresh Ubuntu installation from a declared inventory, reinstall software from known sources, and restore only configuration and selected user data. The existing code already includes useful foundations such as an inventory-first design, path validation, source-aware installation checks, locking, staging, manifests, exclusions, service declarations, and snapshot rotation.

The highest-priority issue is that the current backup flow can overwrite the previous live manifest with `status: in_progress` before the staged backup has been successfully published. That contradicts the documented last-known-good guarantee and can cause a restore to reject an otherwise valid previous backup after an interrupted run.

## Prioritized findings

**Status summary (updated 2026-08-02)** — legend: ✅ completed · 🚧 in-progress (partial) · ⬜ pending · ⛔ not-required (overengineering)

| Item | Status |
| --- | --- |
| P0 — Preserve the previous known-good manifest | ✅ completed |
| P0 — Make publication genuinely atomic and fail closed | ✅ completed |
| P0 — External backup selection as a first-class restore input (`--source`) | ✅ completed |
| P1 — Replace arbitrary install commands with structured installers | ✅ completed |
| P1 — Add a strict inventory schema and semantic validation | ✅ completed |
| P1 — Separate configuration, state, data, cache, and secrets | 🚧 in-progress |
| P1 — Define restore conflict policies | 🚧 in-progress |
| P1 — Introduce explicit restore phases and resumability | 🚧 in-progress |
| P1 — Improve backup completeness semantics | 🚧 in-progress |
| P1 — Add integrity verification for backup contents | ✅ completed |
| P2 — Improve portability across Ubuntu releases and architectures | 🚧 in-progress |
| P2 — Avoid backing up application authentication blindly | ⬜ pending |
| P2 — Reduce catalog/inventory drift | ⬜ pending |
| P2 — Testing strategy | 🚧 in-progress |
| Suggested target layout | ⛔ not-required |

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

### P1 — Define restore conflict policies — 🚧 in-progress

**Status:** 🚧 in-progress — the "merge" policy is effectively implemented as the global **additive overlay** (restore never deletes target files; README documents it). Not implemented: per-path `merge`/`replace`/`skip-existing`/`prompt` declarations, the timestamped rollback bundle, and the restore journal. (The proposed `three-way` merge is a future option — not-required.)

A fresh installation can still create default files before restoration. Each path should declare one of:

- `merge`: copy saved files without deleting new files
- `replace`: replace the destination after preserving it
- `skip-existing`: restore only missing files
- `prompt`: interactive decision
- `three-way`: future option for text configuration

Before modifying a destination, create a timestamped local rollback bundle. Generate a restore journal listing every path created, replaced, skipped, or failed.

Avoid broad `rsync --delete` behavior for home-directory content unless a path explicitly opts in.

### P1 — Introduce explicit restore phases and resumability — 🚧 in-progress

**Status:** 🚧 in-progress — explicit phases 1–6 with idempotent re-runs, accumulated nonzero exit codes, and continue-on-installer-failure are in place. Not implemented: `--plan`, `--from-phase`, `--only`, `--skip`, `--non-interactive`, and a durable phase journal.

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

Several declared configuration directories commonly contain authentication state or tokens, such as GitHub CLI, Google Cloud, Azure, Docker, browser profiles, and Cloudflare-related configuration (`inventory/inventory.yaml:75-281`).

Use per-app include lists rather than copying entire configuration roots wherever possible. For authentication:

- prefer re-login after restore
- export only non-secret settings
- place required secrets in a separate encrypted backup
- show a post-restore authentication checklist

### P2 — Reduce catalog/inventory drift — ⬜ pending

**Status:** ⬜ pending — the inventory still repeats full values; the `catalog: <name>` + `overrides:` resolution model and a drift-report command are not implemented.

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

### P2 — Testing strategy — 🚧 in-progress

**Status:** 🚧 in-progress — `shellcheck` and inventory schema validation run as static checks (a shellcheck pass is recorded in docs/PLAN.md). Not implemented: no automated unit/integration/VM test suite (no `tests/` dir), and the interrupted-backup regression test exists only as a manual/live check, not an automated one.

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
2. ⬜ pending — Add regression tests for interrupted backup and previous-generation preservation (folded into the P2 Testing item).
3. ✅ done — Add explicit `--source` snapshot selection and preflight verification (2026-08-02).
4. ✅ done — Add checksums and hostile-file/symlink validation (P1 integrity).
5. 🚧 partial — Add restore journal, conflict policies, and resumable phases (global merge overlay exists; per-path policies, journal, and phase flags missing).
6. ✅ done — Introduce schema versioning and strict inventory validation.
7. ✅ done — Replace opaque custom commands incrementally with typed installers.
8. ⬜ pending — Add secret classification and encrypted-secret guidance.
9. 🚧 in-progress — Add VM-based end-to-end restore rehearsal (VirtualBox rehearsal reached app 16/24; full clean run still outstanding — docs/PLAN.md).
10. ⬜ pending — Refactor catalog/inventory duplication after behavior is covered by tests.

## Generated Repository Evidence

- **Repository:** `backup-restore-ubuntu`
- **Branch and commit:** `main` at `5d12f028c56af9b2df3301933021ce2492e58103`
- **Status:** dirty; untracked `backups.artifacts` and `backups.staging/`
- **Investigation scope:** architecture, transactional backup safety, package sources, inventory, config/data handling, services, integrity, restore UX, portability, tests, and documentation
- **Evidence documents read:** `README.md`, `AGENTS.md`, `docs/PLAN.md`
- **Important source files inspected:** `backup.sh`, `restore.sh`, `lib/common.sh`, `lib/catalog.sh`, `inventory/inventory.yaml`
- **Key finding:** the in-progress manifest is written to the live backup before staged publication, which can invalidate the previous known-good backup after interruption
- **Gaps:** no commands or tests were executed; backup payloads were not inspected; the repository-evidence generator rejected its request, so this analysis used targeted reads
- **Recommended next step (2026-08-02):** the P0 transaction and `--source` items are deployed. Next highest-value open items: **P1 integrity verification (SHA256SUMS)** and **P1 restore conflict policies / completeness semantics** — then the automated test suite (P2 testing) to lock the P0 fixes in as regression tests.
