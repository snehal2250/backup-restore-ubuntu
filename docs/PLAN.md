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
  `~/.ssh` before deletion). A 36 KB root-owned remnant still needs the user's final
  `sudo rm -rf backup` to finish the cleanup.

## Phase 1 — Inventory (✅)

- `inventory/inventory.yaml` — schema with commented examples (apt/snap/flatpak lists,
  `apps:` with install_type/install_command/check_cmd/depends_apt/config_paths, `services:`
  with unit/target/enable/start, `user_dirs:` for whole user-data folders).
- `lib/catalog.sh` — seed catalog so `add-app` knows common apps out of the box
  (opencode, VS Code, Docker, Chrome, gh, gcloud, go, uv, tmux, terraform, ollama,
  az, azurite, slack, onlyoffice, storage-explorer, ...). Extend as the user adopts
  more apps.
- **Live inventory: 23 apps + 1 service declared** (`inventory/inventory.yaml`).
  Includes 4 install-method corrections that match how the user actually installed
  the tool: gcloud→`snap-classic` (classic snap), gh→official GitHub apt repo,
  go→official go.dev tarball,  uv→official astral installer (instead of pipx, which isn't installed on this system
  and would have failed on a fresh restore).
- `inventory.sh` — the manual tool: `list`, `add-package`, `remove-package`, `add-app`
  (wizard with catalog prefill + config-path detection), `add-service` (with optional
  `config_paths` for the service), `remove-app`, `remove-service`, `review` (suggests
  undeclared apps found on the system), and `wizard` (guided scan-and-declare flow).

## Phase 2 — Backup & Restore & Update (✅)

- `backup.sh` — captures only declared configs (per app), service unit files + service
  `config_paths`, dotfiles, and declared `user_dirs` (whole folders) into `backups/`;
  writes `backups/backup-info.txt`.
- `restore.sh` — preflight (Ubuntu check), `apt` update, fresh install of apt/snap/flatpak
  packages, per-app install (with deps + idempotency via `check_cmd`), service install +
  enable/start + service config restore, config overwrite from `backups/`, and wholesale
  restore of declared `user_dirs`. Base OS full-upgrade is OPT-IN via `--upgrade-base`
  (default touches only declared items). Flags: `--dry-run`, `--yes`. Auto-installs `yq`
  on a fresh system; `inventory.sh`/`backup.sh` ask before installing it.
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

Land changes in small, reviewable commits. The re-architecture **started** with two
commits:

1. **Commit 1 — architecture.** The full toolchain (`inventory.sh`, `backup.sh`,
   `restore.sh`, `update_all_ubuntu.sh`, `lib/`, `AGENTS.md`, `README.md`, `docs/`,
   `.gitignore`) with `inventory/inventory.yaml` containing only commented examples.
2. **Commit 2 — real inventory.** The populated `inventory/inventory.yaml` plus the
   `package:` schema support (and related fixes) the real inventory required.

Since then the branch has grown in small follow-up commits: the `BACKUP_DEST` mirror
feature, legacy-cleanup + cron dedup, more app declarations (cloudflared, google-chrome,
fish, sqlitebrowser, stacer, sublime-text, freebuff), a shellcheck hardening pass, the
`docs/RESTORE.md` runbook, and the inventory expansion to 23 apps (9 new apps + 4 install-
method fixes, `98b7425`).

Never commit `backups/` (git-ignored). `backup.sh` automatically mirrors it to the
configured `BACKUP_DEST` (default `/media/vikram-athare/Storage/backup-restore-ubuntu`)
keeping the last `BACKUP_KEEP` snapshots; set `BACKUP_DEST=` to disable the mirror.

## Phase 4 — Future enhancements (⬜ backlog)

- Grow the seed catalog (`lib/catalog.sh`) as the user adopts apps.
- Optional git-crypt or age-based encryption for committing `backups/`.
- Optional `restore.sh --configs-only` / `--packages-only` sub-phases.
- Optional integrity check (`restore.sh --verify`) comparing declared inventory vs system.
