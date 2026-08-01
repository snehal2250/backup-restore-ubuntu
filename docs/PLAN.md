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
- **Live inventory: 24 apps + 1 service declared** with group + shell state.
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
- ✅ Concurrency protection via `flock`.
- ✅ Inventory schema validation (`inventory.sh validate`).
- ✅ Path safety: reject `..`, control chars, containment checks.
- ✅ Architecture detection for yq bootstrap (amd64 + arm64).
- ✅ Non-Ubuntu systems: `require_ubuntu` hard-fails (was a warning).
- ✅ Root execution: `require_non_root` hard-fails (was silent misbehavior).
- ✅ Source-specific install checks (`is_app_installed_by_source`).
- ✅ Post-install phase: groups, default shell, app extensions/models.
- ⬜ Validate the full flow in a disposable VM: fresh Ubuntu → `restore.sh` → verify.
- ⬜ Test `--dry-run` output is accurate end-to-end.
- ⬜ Run `shellcheck` on all updated scripts.

## Commit strategy

Land changes in small, reviewable commits. Never commit `backups/` (git-ignored).

## Phase 4 — Future enhancements (⬜ backlog)

- Grow the seed catalog (`lib/catalog.sh`) as the user adopts apps.
- Optional git-crypt or age-based encryption for committing `backups/`.
- Optional integrity check (`restore.sh --verify`) comparing declared inventory vs system.
- VM-based automated integration tests with mock installers.
- Encrypted backup storage support.
