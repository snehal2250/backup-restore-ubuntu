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
- Legacy `backup/` folder from the old script was reviewed and deleted (its contents were
  superseded by `backups/` + the `BACKUP_DEST` mirror; SSH keys were verified identical to
  `~/.ssh` before deletion).

## Phase 1 — Inventory (✅)

- `inventory/inventory.yaml` — schema with commented examples (apt/snap/flatpak lists,
  `apps:` with install_type/install_command/check_cmd/depends_apt/config_paths, `services:`
  with unit/target/enable/start).
- `lib/catalog.sh` — seed catalog so `add-app` knows common apps out of the box
  (opencode, VS Code, Docker, Chrome). Extend as the user adopts more apps.
- `inventory.sh` — the manual tool: `list`, `add-package`, `remove-package`, `add-app`
  (wizard with catalog prefill + config-path detection), `add-service` (with optional
  `config_paths` for the service), `remove-app`, `remove-service`, `review` (suggests
  undeclared apps found on the system), and `wizard` (guided scan-and-declare flow).

## Phase 2 — Backup & Restore & Update (✅)

- `backup.sh` — captures only declared configs (per app), service unit files + service
  `config_paths`, and dotfiles into `backups/`; writes `backups/backup-info.txt`.
- `restore.sh` — preflight (Ubuntu check), `apt` update, fresh install of apt/snap/flatpak
  packages, per-app install (with deps + idempotency via `check_cmd`), service install +
  enable/start + service config restore, config overwrite from `backups/`. Base OS
  full-upgrade is OPT-IN via `--upgrade-base` (default touches only declared items). Flags:
  `--dry-run`, `--yes`. Auto-installs `yq` on a fresh system; `inventory.sh`/`backup.sh`
  ask before installing it.
- `update_all_ubuntu.sh` — apt/snap/flatpak/npm + declared npm/pipx/cargo apps.
- `schedule_cron.sh` + `.gitignore` updated for the new `backups/` layout.

## Phase 3 — Hardening & validation (⬜ next)

- ✅ Ran `shellcheck` (v0.10.0) on all scripts; fixed findings (SC1087 braces,
  SC2318 `local` split, SC2295 quoted `$HOME` patterns) and silenced intentional
  patterns (SC2034/SC2119/SC2120 cross-file globals, SC2016 yq expression vars,
  SC1091 sourced libs).
- Validate the full flow in a disposable VM: fresh Ubuntu → `restore.sh` → verify apps,
  configs, services; run it twice to prove idempotency.
- Test `--dry-run` output is accurate end-to-end.
- ✅ Decided & documented: `backups/` is carried off-machine via the configurable
  `BACKUP_DEST` mirror (default `/media/vikram-athare/Storage/backup-restore-ubuntu`),
  keeping the last `BACKUP_KEEP` snapshots (`BACKUP_DEST=` disables). See "Commit
  strategy" below.

## Commit strategy

Land changes in small, reviewable commits. This re-architecture lands as two commits:

1. **Commit 1 — architecture.** The full toolchain (`inventory.sh`, `backup.sh`,
   `restore.sh`, `update_all_ubuntu.sh`, `lib/`, `AGENTS.md`, `README.md`, `docs/`,
   `.gitignore`) with `inventory/inventory.yaml` containing only commented examples.
2. **Commit 2 — real inventory.** Landed once the user has declared their real
   apps/packages/services via `./inventory.sh wizard` / `add-app` / `add-package` /
   `add-service`. Contains the populated `inventory/inventory.yaml` plus the
   `package:` schema support (and related fixes) the real inventory required.

Never commit `backups/` (git-ignored). `backup.sh` automatically mirrors it to the
configured `BACKUP_DEST` (default `/media/vikram-athare/Storage/backup-restore-ubuntu`)
keeping the last `BACKUP_KEEP` snapshots; set `BACKUP_DEST=` to disable the mirror.

## Phase 4 — Future enhancements (⬜ backlog)

- Grow the seed catalog (`lib/catalog.sh`) as the user adopts apps.
- Optional git-crypt or age-based encryption for committing `backups/`.
- Optional `restore.sh --configs-only` / `--packages-only` sub-phases.
- Optional integrity check (`restore.sh --verify`) comparing declared inventory vs system.
