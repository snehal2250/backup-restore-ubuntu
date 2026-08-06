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
  supported-arch gate — amd64 only; the Ubuntu release is deliberately not locked).
- ✅ Backup completeness semantics (schema v4): per-item `required:` / `on_missing:`
  (`warn`|`fail`) on apps/services; manifest granularity `ok` / `ok_with_warnings` /
  `degraded` / `failed` with exact warning/failure counts; restore accepts
  `ok_with_warnings`, refuses `failed`, `degraded` needs `--force-incomplete`;
  `publish_backup` treats `ok_with_warnings` as verified.
- ✅ Catalog references (schema v5): apps may be declared as `catalog: <key>` + optional
  `overrides:` (resolved at run time by `resolve_effective_inventory` — maps/scalars
  override the template, arrays append+dedupe; the resolved record is schema-validated);
  `inventory.sh add-app` emits references, `list` shows resolved values + `catalog=` tag,
  `review --drift` reports declared-vs-template drift, `restore.sh --plan` prints the
  effective values; schema accepts `schema_version: 3|4|5`; 41-assertion `tests/test_catalog.sh`.
- ✅ Path safety: reject `..`, control chars, containment checks.
- ✅ Architecture detection for yq bootstrap (amd64 + arm64; historical — the repo's declared matrix is now amd64-only).
- ✅ Non-Ubuntu systems: `require_ubuntu` hard-fails (was a warning).
- ✅ Root execution: `require_non_root` hard-fails (was silent misbehavior).
- ✅ Source-specific install checks (`is_app_installed_by_source`).
- ✅ Post-install phase: groups, default shell, app extensions/models.
- ✅ Validate the full flow in a disposable VM: fresh Ubuntu → `restore.sh` → verify.
  Rehearsal rounds (VirtualBox, 2026-08-01/02 + 2026-08-05) reached a full clean run of
  **all 25 declared apps** (§ 6.7–6.8 of docs/REHEARSAL-VIRTUALBOX.md) — completed on
  2026-08-05: fresh restore of every app, **cloudflared starts with healthy DNS**
  (enabled + active, 0 failed units), a **clean reboot with all services green**
  (`systemctl --failed` empty; `/` and `/etc` verified `root:root 755` after reboot —
  the config-tree perms-fix validation), configs + user dirs restored (opencode config,
  `~/Documents`, `~/.config/manicode/projects` with `chats` excluded), and an
  **idempotency re-run** reporting everything "already installed (verified via
  <source>)" with exit 0 (the az first-run failure — a transient unattended-upgrades
  dpkg lock — was fixed by the re-run; the azure-cli repo has no `resolute` suite and
  correctly fell back to `noble`). The round found and fixed **three real bugs**: the
  schema-v7 `user_dirs` object form silently disabled user-dir capture (mikefarah yq
  lexer error in `user_dir_paths`/`user_dir_exclude`, swallowed by
  `2>/dev/null || true`) — fixed with `(.path // .)`; **config restore propagating
  staging dir metadata onto `/` and `/etc`** (`sudo rsync -a` + a 0770 vboxsf-staged
  tree made every unprivileged daemon die at boot) — fixed with the
  `restore_sync_tree` helper (`--no-owner` `--no-group` + pre-existing dest-dir mode
  re-assertion; `bcc4d3c`, `1679139`); and **backup.sh pre-creating an empty `root/`
  dir for every app** — restore unconditionally rsync'd it onto `/` (an empty
  `rsync -a root/ /` still applies the source top-dir's 0770 mode to the dest root,
  which killed the whole restore at app 2/25 and re-corrupted `/`) — fixed with
  per-path-only scope dirs in backup.sh + empty-tree skips in restore_config_tree and
  restore_sync_tree + the sudo'd rsync-and-re-assert running inside ONE `bash -c`
  (a later separate sudo could no longer be forked once `/` was mode-locked).
  Known **environmental limitations** (not repo bugs): VirtualBox **NAT DNS flakiness**
  (breaks with host MagicDNS; the persistent nmcli upstream fix survives reboot — it
  caused run-1's git/gh failures) and **snap CLIs under headless guestcontrol** (`/ not
  root-owned`, ollama "transient scope" — snap apps need a real GUI session). Rehearsal
  lessons baked into the docs: persistent guest DNS + run restore from a TTY with the
  screen lock disabled (a locked GUI mid-restore corrupts the package state).
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

## Phase 4 — Systemd timers & cron jobs (schema v6) (✅)

- **Timers are first-class `services:` entries** (they always were — the unit-name
  pattern accepts `.timer`; this phase formalized it): `validate_inventory` warns when a
  declared `.timer`'s paired `.service` is neither declared nor on disk (a fresh restore
  would install a timer that can never fire), and `restore.sh` repeats the message when it
  enables a timer whose pair is undeclared. The inventory dogfoods the user's real timers:
  `trading-bot-*.timer` + their paired `trading-bot-*.service` units (timers enabled/started,
  services enable/start false — the timer pulls them in).
- **New top-level `cron_jobs:` list (schema v6, OPTIONAL — absent means none, keeping
  v3-v5 inventories valid; scripts read it null-safely)**: declares WHICH
  cron scheduling the repo manages; the CONTENT lives in the backup (like unit files). Two
  sources: `user` (the running user's crontab — `crontab -l` at backup, whole-crontab
  replace with rollback capture at restore; at most ONE user entry) and `cron.d` (one file
  under `/etc/cron.d`, restored with sudo + 0644 perms; names with dots are FORBIDDEN —
  Debian cron ignores them). Per-entry `on_missing: warn|fail` completeness policy; artifact
  statuses `captured`/`empty`/`missing`/`failed` flow through the same transactional staging
  + manifest pipeline (principles 3, 8, 9).
- `backup.sh` captures cron sources into `backups/cron/<name>` (`crontab -l`, or a copy of
  `/etc/cron.d/<file>`); `restore.sh` restores them in the services phase — the cron package
  is ensured (installed when missing, never under `--configs-only`), the sources are
  restored with rollback capture + journal, and only THEN is the daemon activated
  (config-before-start, mirroring services; never activated under
  `--packages-only`/`--configs-only`, with truthful messages). The `--plan` output lists
  cron jobs. `inventory.sh review` skips package-owned `/etc/cron.d` files via `dpkg -S`
  (they are recreated by reinstalling their package, so they never need backing up).
- `inventory.sh`: `add-cron` / `remove-cron` commands, a `=== Cron jobs ===` list section,
  and review hints (undeclared user crontab + non-stock `/etc/cron.d` files).
- Semantics: unique cron names, at most one `source: user`, cron.d file pattern enforced by
  the schema; `/etc/cron.d` source dir is `CRON_D_DIR` (test-overridable only under the
  `BRU_ALLOW_TEST_OVERRIDES=1` opt-in, like the other path overrides).
- Tests: `tests/test_cron.sh` (33 assertions — schema v6 variants, semantic checks,
  sandboxed backup capture of crontab + cron.d with captured/empty/missing/failed statuses,
  sandboxed `restore.sh --source` with mocked crontab/sudo/systemctl/rsync/dpkg + rollback
  journal assertions, and the failed-snapshot refusal); `test_static.sh` extended for the
  v6 transition (3-6 valid, 7 rejected) and cron_jobs schema variants.

## Commit strategy

Land changes in small, reviewable commits. Never commit `backups/` (git-ignored).
The v6 rollout landed as: schema+inventory dogfood → common.sh semantic checks → backup.sh
cron capture → restore.sh cron restore + timer messaging → inventory.sh add/remove/list →
tests + docs → validation.

## Phase 5 — Future enhancements (⬜ backlog)

- Grow the seed catalog (`lib/catalog.sh`) as the user adopts apps.
- Optional git-crypt or age-based encryption for committing `backups/`.
- Optional integrity check (`restore.sh --verify`) comparing declared inventory vs system.
- VM-based automated integration tests with mock installers.
- Encrypted backup storage support.
- Cron merge policy (per-entry conflict_policy for crontabs) — currently whole-crontab
  replace with rollback capture (the safe default).
