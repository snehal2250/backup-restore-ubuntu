# PLAN.md — Roadmap to the end state

This is the working plan for reaching the target architecture: **restore = fresh install
of user-installed apps/packages/services + configuration overwrite**.

Legend: ✅ done · 🚧 in progress · ⬜ planned

## Phase 0 — Principles & architecture (✅)

- Redefined the project goal: rebuild, don't copy. Written down in `AGENTS.md` as
  non-negotiable principles + anti-pattern table.
- Repo restructured: `inventory/` (source of truth), `lib/` (shared helpers + catalog),
  `backups/` (git-ignored captured config).
- Single YAML inventory chosen (with `yq` as the one tool dependency).
- Dotfiles included as an optional inventory list. Only user-declared custom services.
- Legacy `backup/` folder from the old script was reviewed and removed.

## Phase 1 — Inventory (✅)

- `inventory/inventory.yaml` — schema with top-level scalars (`default_shell`), flat lists
  (`groups`, `user_dirs`), and structured lists (`apps`, `services`) including optional
  `extensions` per app (VS Code extension IDs, Azure CLI extension IDs, Ollama model names).
- `lib/catalog.sh` — seed catalog so `add-app` knows common apps out of the box.
- **Live inventory: 25 apps + 2 services declared** with group + shell state.
- `inventory.sh` — the manual tool: `list`, `validate`, `add-package`, `remove-package`,
  `add-app` (wizard with catalog prefill + config-path detection + dependency prompt),
  `add-service` (validates unit name), `remove-app`, `remove-service`, `review`, `wizard`.

## Phase 2 — Backup & Restore & Update (✅)

- `backup.sh` — **transactional**: builds in staging, validates, generates manifest with
  per-artifact status, mirrors to `BACKUP_DEST`, atomically swaps into `backups/`. Uses
  `flock` for concurrency protection. Rejects mirror-to-repo overlap.
- `restore.sh` — preflight (Ubuntu check, non-root guard, inventory validation), `apt`
  update, fresh install of apt/snap/flatpak packages, **per-app source-specific install
  checks** (`dpkg` for apt, `snap list` for snap, `flatpak info` for flatpak, `npm list -g`
  for npm-global), **`bash -o pipefail`** for all installer commands, **manifest validation**
  (requires `status: ok` before restoring config), service install + config-before-start,
  config overwrite from `backups/`, **post-install phase** (groups, default shell,
  extensions/models), accumulated exit code with nonzero on any failure. Flags:
  `--dry-run`, `--yes`, `--upgrade-base`, `--configs-only`, `--packages-only`,
  `--force-incomplete`.
- `update_all_ubuntu.sh` — apt/snap/flatpak/npm + all declared apps (with truthful
  per-item pass/fail/skip reporting), prompts before re-running custom installers.
- `schedule_cron.sh` — **systemd user timer** (daily + 15min after boot) replacing the
  old @reboot cron approach; passes explicit environment, noninteractive mode.

## Phase 3 — Hardening & validation (🚧)

- ✅ Ran `shellcheck` (v0.10.0) on all scripts; fixed findings.
- ✅ Backup manifest with `status: ok`, per-artifact tracking, inventory SHA-256.
- ✅ Restore manifest verification before config restore.
- ✅ Accurate exit codes (accumulated bitmask) — restore fails nonzero if any item fails.
- ✅ `--packages-only` services are NOT enabled/started (need config first).
- ✅ Root config ownership warning instead of silent failure.
- ✅ Transactional backup: staging → validate → mirror → atomic swap.
- ✅ Hardened publication (`publish_backup`): fail-fast first rename (never moves staging
  over an existing live dir), same-filesystem verification for atomic renames, deterministic
  rollback, keep-old-generation until final manifest verification (`status: ok`) with
  rollback on failure, cleanup trap for interrupted runs; directory fsync documented as an
  optional extra for stronger crash consistency.
- ✅ Concurrency protection via `flock`.
- ✅ Structured installers (schema v2): replaced the opaque `script`/`custom`
  `install_command` shell pipelines with typed `installer:` records — `apt`, `snap`,
  `snap_classic`, `flatpak`, `npm_global`, `pipx`, `cargo`, `apt_repository` (signed
  third-party repo: key download + optional gpg key-fingerprint verification + sources
  line), `deb` (arch gate, pinned sha256 or `unverified: true`), `tarball`
  (`{arch}`/`{version}` templates, checksum/checksum_url, safe top-level-dir swap,
  binary symlink), and `script` as the explicit last resort (downloaded to a file, never
  piped; checksum or `unverified: true`). Dispatched by the new `lib/installers.sh`;
  `inventory.sh` wizard + catalog emit the same structured records.
- ✅ Inventory validation, v2: **versioned JSON Schema** (`inventory/schema.yaml`,
  draft 2020-12, `schema_version: 2` + `profile: workstation`) enforced with a REAL
  validator (`lib/schema_check.py`, python3 + reference `jsonschema` library) replacing
  ad-hoc structural parsing; plus strict semantic checks (unique names,
  `default_shell` provenance, config-path/`exclude` nesting, cross-owner path overlap
  with the explicit exclude-allowance rule, {version} template completeness,
  supported arch/Ubuntu-release gate).
- ✅ Backup completeness semantics (schema v4): per-item `required:` / `on_missing:`
  (`warn`|`fail`) on apps/services; manifest granularity `ok` / `ok_with_warnings` /
  `degraded` / `failed` with exact warning/failure counts; restore accepts
  `ok_with_warnings`, refuses `failed`, `degraded` needs `--force-incomplete`;
  `publish_backup` treats `ok_with_warnings` as verified.
- ✅ Path safety: reject `..`, control chars, containment checks.
- ✅ Architecture detection for yq bootstrap (amd64 + arm64).
- ✅ Non-Ubuntu systems: `require_ubuntu` hard-fails (was a warning).
- ✅ Root execution: `require_non_root` hard-fails (was silent misbehavior).
- ✅ Source-specific install checks (`is_app_installed_by_source`).
- ✅ Post-install phase: groups, default shell, app extensions/models.
- 🚧 Validate the full flow in a disposable VM: fresh Ubuntu → `restore.sh` → verify.
  Rehearsal (2026-08-01/02, VirtualBox) reached app 16/24 (docker) before an interrupted
  apt transaction; dry-run verified accurate end-to-end. Remaining: complete a full clean
  run, reboot + verify, idempotency pass (§ 6.7–6.8 of docs/REHEARSAL-VIRTUALBOX.md).
  Rehearsal lessons baked into the docs: persistent guest DNS (static `/etc/resolv.conf`,
  bypassing the NAT DNS proxy which breaks with host MagicDNS) + run restore from a TTY
  with the screen lock disabled (a locked GUI mid-restore corrupts the package state).
- ✅ Test `--dry-run` output is accurate end-to-end (verified by the rehearsal dry-run,
  which matched the real install commands until the run was interrupted).
- ✅ `restore.sh --source <snapshot>` — external backup snapshot as a **first-class
  restore input** (P0 from the improvement analysis): `realpath` resolution, requires a
  verified manifest + artifact list (`status: ok`; `--force-incomplete` to override),
  architecture / Ubuntu-release / inventory-SHA compatibility checks, writable-source
  warning, and prints the exact source before any system change. No implicit copy or
  mount — the repo checkout is disposable, the backup medium is authoritative.
- ✅ Backup content integrity (P1): `backup.sh` writes a deterministic `SHA256SUMS` over
  the staged payload (excluding the manifest and mutable logs); `restore.sh` verifies it
  before any config restore — checksum matches, hostile special files (device/FIFO/
  socket), escaping symlinks, and missing/extra-file reporting. Legacy snapshots without
  `SHA256SUMS` warn and proceed; a failed check refuses the restore unless
  `--force-incomplete`.
- ✅ Restore conflict policies + rollback bundle + journal (P1, schema v3): per-owner
  `conflict_policy` (`merge` default / `replace` / `skip-existing` / `prompt`) on apps
  and services; every config restore first captures what it overwrites into a
  timestamped rollback bundle under `~/.local/state/backup-restore-ubuntu/rollback-<ts>/`
  (outside the backup source) and journals created/replaced/skipped/failed. `--dry-run`
  creates nothing; user-dirs stay merge-only (never delete user data).
- ✅ Restore resumability (P1, handoff item 5): `--plan` preview (phase-by-phase table +
  dry-run detail), `--from-phase <phase>` (skip everything before a phase),
  `--only`/`--skip` (phase names gate whole phases; app names filter the apps phase;
  `user-data` is an alias for the dotfiles phase), and `--non-interactive` (never prompt).
  The rollback bundle + journal are created up front on real runs and every enabled phase
  writes `phase-start`/`phase-done` markers — the durable phase journal. Phase gating
  lives in `lib/common.sh` (pure functions, unit-tested in `tests/test_phases.sh`);
  unknown phase/app names in `--only`/`--skip` die (typo guard).
- ✅ Automated test suite (P2 testing): `tests/run.sh` — plain-bash unit tests for the
  integrity, rollback/journal/conflict-policy, manifest and path helpers;
  interrupted-backup regression (staging-only `in_progress` marker + `publish_backup`
  success/rollback/fail-fast in a fully sandboxed repo); static checks (`bash -n` on
  every script, real-inventory schema validation + `conflict_policy` variants, and a
  guard asserting no `rsync --delete` invocation in backup.sh/restore.sh/lib — the
  critical-bug regression). The suite's first runs caught two real bugs, both fixed:
  a NUL-truncated control-char check in `normalize_path` and `conflict_policy_get`
  returning empty (instead of `merge`) for unknown owners.
- ⬜ Run `shellcheck` on all updated scripts.

## Commit strategy

Land changes in small, reviewable commits. Never commit `backups/` (git-ignored).

## Phase 4 — Future enhancements (⬜ backlog)

- Grow the seed catalog (`lib/catalog.sh`) as the user adopts apps.
- Optional git-crypt or age-based encryption for committing `backups/`.
- Optional integrity check (`restore.sh --verify`) comparing declared inventory vs system.
- VM-based automated integration tests with mock installers.
- Encrypted backup storage support.
