# Backup-Restore-Ubuntu

Rebuild your Ubuntu desktop to its last-known-good state — **without restoring binaries or
packages from a backup**. This repo installs the apps you use from their recommended
sources (latest stable versions) and then copies your *configuration* over them.

## The idea

A traditional backup copies files. This repo instead:

1. Knows **what you use** — from a single, hand-maintained file: `inventory/inventory.yaml`.
2. `backup.sh` saves **only the configuration** of those apps (config folders, systemd
   unit files, dotfiles).
3. `restore.sh` **installs everything fresh** — `apt`, `snap`, `flatpak`, official
   installers — and then overwrites them with your saved configuration.

> Example: you use **OpenCode**. The inventory says so. `backup.sh` saves
> `~/.config/opencode`. On a fresh system, `restore.sh` runs the app's typed `script`
> installer — downloads `https://opencode.ai/install` and executes it (latest version,
> official source) — then restores your `~/.config/opencode` on top.

This is how you'd set up a new machine by hand — automated, and only for the things
**you** installed on top of stock Ubuntu. No version pinning, no dependency guessing, no
copying of the OS itself.

## Quick start

> **Prerequisites:** the scripts read the inventory with `yq`, and validate it against
> a **versioned JSON Schema** (`inventory/schema.yaml`) with a real validator
> (`lib/schema_check.py`, python3 + the `jsonschema` library + PyYAML).
> - `inventory.sh` and `backup.sh` will offer to install `yq` and the validator
>   (`sudo snap install yq` / `sudo apt-get install -y python3-jsonschema python3-yaml`);
> - `restore.sh` auto-installs both on a fresh system — including under `--dry-run`
>   (a preview still needs to read and validate the inventory and the backup source
>   with read-only checks; nothing is installed or modified).

```bash
# 1. Declare what you use (your manual responsibility — this file is the source of truth)
./inventory.sh                      # show current inventory
./inventory.sh wizard               # guided: scan the system, declare apps one by one
./inventory.sh add-app opencode     # opencode etc. are known in the built-in catalog
./inventory.sh add-package apt git
./inventory.sh add-service          # wizard for a custom service you installed
./inventory.sh add-user-dir ~/Documents   # declare a whole user-data folder (e.g. Documents)
./inventory.sh review               # suggest apps found on this system that you haven't declared

# 2. Back up the configuration of everything declared
./backup.sh                         # writes to backups/ AND mirrors it to BACKUP_DEST
#   (default BACKUP_DEST=/media/vikram-athare/Storage/backup-restore-ubuntu,
#    full unfiltered copy, last 5 snapshots kept — override with env vars)

# 3. On a fresh Ubuntu: restore (fresh install + your config)
#    Full step-by-step runbook: docs/RESTORE.md
#    VirtualBox rehearsal (test the restore path in a VM): docs/REHEARSAL-VIRTUALBOX.md
./restore.sh                        # prompts; --yes to skip, --dry-run to preview
#   --configs-only = restore config only (skip all installs)
#   --packages-only = install fresh only (skip config restore)
#   --source <snapshot-dir> = restore config DIRECTLY from an external backup
#     snapshot (e.g. a backup-* mirror snapshot on the Storage disk) — no manual
#     copying into backups/ needed. Preflight verifies the source manifest and
#     checks architecture / Ubuntu release / inventory compatibility.
#   --plan = preview which phases/apps will run (dry-run)
#   --from-phase services = resume: skip everything before this phase
#   --only code,git = only these apps (and any listed phases) run
#   --skip user-data = skip a phase (user-data == dotfiles) and/or apps
#   --non-interactive = never prompt (implies --yes)
```

Then, optionally, as a separate exercise (only after the plain restore + verification):

```bash
./restore.sh --upgrade-base         # OPT-IN: also apt full-upgrade of the base OS
```

Keep everything current day-to-day:

```bash
./update_all_ubuntu.sh
```

## Commands

| Command | What it does | Safe to run |
| --- | --- | --- |
| `./inventory.sh list` | Show declared apps/packages/services + installed status | ✅ |
| `./inventory.sh add-app <name>` | Interactive wizard to declare an app | ✅ |
| `./inventory.sh add-package apt\|snap\|flatpak <name>` | Add a package to a list | ✅ |
| `./inventory.sh add-service` | Interactive wizard to declare a custom service | ✅ |
| `./inventory.sh add-user-dir <path>` | Declare a whole user-data folder (e.g. `~/Documents`) | ✅ |
| `./inventory.sh remove-app/-package/-service/-user-dir` | Remove a declaration | ✅ |
| `./inventory.sh review` | Suggest undeclared apps found on the system | ✅ |
| `./inventory.sh wizard` | Guided flow: scan the system, declare apps one by one | ✅ |
| `./backup.sh` | Capture configs + service units + dotfiles + `user_dirs` → `backups/`, mirror to `BACKUP_DEST` (keep last `BACKUP_KEEP`); writes `status: ok` marker in `backup-info.txt` on success | ✅ |
| `./restore.sh` | Fresh install + config restore (config from `backups/` or `--source <snapshot>`; base OS upgrade is opt-in: `--upgrade-base`; resumable/targeted via `--plan`, `--from-phase`, `--only`, `--skip`) | ⚠️ modifies system |
| `./update_all_ubuntu.sh` | Update apt/snap/flatpak/npm + declared apps | ⚠️ modifies system |
| `./schedule_cron.sh` | Install a @reboot scheduled backup | ⚠️ edits crontab |

## Layout

```
inventory/inventory.yaml   the single source of truth (user-maintained)
inventory/schema.yaml      versioned JSON Schema (draft 2020-12) the inventory is validated against
lib/common.sh              shared helpers for all scripts
lib/installers.sh          typed installer functions for the structured installer: records
lib/schema_check.py        real structural validator (python3 + jsonschema + PyYAML)
lib/catalog.sh             built-in knowledge of common apps (opencode, code, docker, ...)
inventory.sh               the manual inventory tool (list / add-* / remove-* / validate / review / wizard)
backup.sh                  capture configuration -> backups/
restore.sh                 fresh install + config overwrite
update_all_ubuntu.sh       update everything
schedule_cron.sh           scheduled backup after reboot
backups/                   captured configuration (git-ignored)
                           mirrored to BACKUP_DEST (default /media/vikram-athare/Storage/backup-restore-ubuntu)
```

## Automated tests

The repo has a small automated test suite — plain bash, no extra dependencies:

```bash
./tests/run.sh
```

It covers the integrity (SHA256SUMS), rollback/journal/conflict-policy, manifest,
and path helpers; the transactional backup guarantees (interrupted-backup
regression: staging-only `in_progress` marker, `publish_backup` success/rollback/
fail-fast); and static guards (syntax, schema validation, no `rsync --delete` in
production scripts). Sandboxes are git-ignored (`.test-tmp.*`).

## FAQ

**Does restore copy packages from the backup?** No. Packages are installed fresh from
Ubuntu repos / Snap Store / Flathub / official installers at their latest stable versions.
Only configuration is copied.

**What about dependencies?** Each app can declare its own dependencies (`depends_apt`) and
they are installed automatically with the app. You never see them as separate inventory
items — you only think about the main apps you use.

**Why is my backup so large?** Some apps keep caches, model stores, or bundled binaries
inside their config folder (e.g. VS Code's `CachedExtensionVSIXs`/`CachedData`,
Chrome's `optimization_guide_model_store` and its runtime `Singleton*` files,
Freebuff's bundled `freebuff/` binary). These are re-downloadable (or transient), so by
default they are **excluded** from the backup via each app's `exclude:` list in the
inventory — only real configuration is captured. Excluded items are not restored either;
they regenerate on first launch.

**Does backup keep old copies of removed/excluded config?** No. `backup.sh` wipes each
app's captured folder before re-capturing, so `backups/` reflects the **current** state
only (a config file that no longer exists on disk is dropped from the live `backups/`).
History lives in the timestamped mirror snapshots in `BACKUP_DEST`, which are immutable
once created.

**What if some paths were missing during backup?** The run still **completes** and the
file is written, but the manifest reports `status: degraded` instead of `status: ok`
(per-artifact lines show which were `missing`/`incomplete`). `restore.sh` refuses degraded
snapshots unless you pass `--force-incomplete`. `degraded` is NOT the same as an
interrupted run — interrupted runs never publish a live manifest at all.

**Is the backup content verified?** Every `backup.sh` run writes a `SHA256SUMS` file
alongside the captured config (covering every payload file except the manifest and
mutable logs). `restore.sh` verifies it before restoring anything: all checksums must
match, no device/FIFO/socket files, no symlinks escaping the snapshot, and files present
but unlisted are reported as a warning. A snapshot created before integrity checking
(no `SHA256SUMS`) is accepted with a warning; a **failed** verification refuses the
restore unless you pass `--force-incomplete`.

**How atomic is the `backups/` swap?** Publication is a two-step rename that is atomic
only when `backups.staging/` and `backups/` share a filesystem — `backup.sh` verifies
that (same device, including the live dir itself if it is a mountpoint) before moving
anything. The live folder is renamed aside **first** and the run fails immediately if
that fails: it never moves staging over an existing live folder. The previous generation
is kept until the new one passes a final manifest check (`status: ok`); if the new
generation is degraded, `backup.sh` rolls back to the previous one (restore refuses
non-ok manifests, so a degraded live backup would be unusable). A cleanup trap removes
leftovers from crashed runs and restores the previous generation if a signal interrupts
the run before verification completes. If you need stronger crash consistency, fsync'ing
the directory after the swap is an optional extra — it is not done by default.

**Does restore delete config files I removed?** By default no — the app/service's
`conflict_policy` (default `merge`) controls this: `merge` is an **additive overlay**
that never deletes target files; `replace` mirrors the backup exactly (existing target
files are first preserved in the rollback bundle, then `rsync --delete` runs);
`skip-existing` restores only missing files; `prompt` asks per config path (non-interactive
runs skip). To get a pristine config regardless, delete the app's config dir before
re-running restore.

**Can I undo a restore?** Yes. Every config restore first captures what it is about to
overwrite into a timestamped rollback bundle at
`~/.local/state/backup-restore-ubuntu/rollback-<timestamp>/`, and appends one line per
operation to `restore-journal.log` there (created / replaced / skipped / failed). To undo,
copy files back from the bundle to their destinations; remove the bundle once you are
satisfied (`rm -rf`). Dry-runs create nothing.

**Do services start before or after their config is restored?** After. `restore.sh`
restores each service's `config_paths` before `enable`/`start`, so a service boots with
its real configuration on first start.

**How do I back up my Documents (or any folder)?** Declare it as a `user_dirs` entry
(`./inventory.sh add-user-dir ~/Documents`). Unlike app config, these are whole
user-data folders — `backup.sh` captures them in full under `backups/user-dirs/` and
`restore.sh` puts them back wholesale.

**Which services are managed?** Only the custom services **you** declare in the inventory
(unit files in `/etc/systemd/system` or `~/.config/systemd/user`). Default system services
are never touched.

**My custom service needs a config file or env file.** Declare it in the service's
`config_paths` when you run `add-service` (or put it under the relevant app's
`config_paths`). `backup.sh` captures it; `restore.sh` puts it back after installing the
service.

**How do I know the last backup succeeded?** `backup.sh` writes `backups/backup-info.txt`
with run metadata and a success marker **only when the whole run completes** (a single
atomic write — no mid-run truncation window). A missing or status-absent file means the
last run did not complete. The marker includes `status: ok`, a `finished:` timestamp, and
a `mirror:` line (`ok` / `failed` / `disabled`):

```bash
# local truth (file exists with 'status: ok' = last run completed):
tail -5 backups/backup-info.txt      # expect a 'status: ok' line
# quick yes/no:
grep -q '^status: ok' backups/backup-info.txt && echo 'BACKUP OK' || echo 'BACKUP INCOMPLETE'

# off-machine truth (the newest mirror snapshot carries the same file):
newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
tail -5 "$newest/backup-info.txt"
```

**Reading the marker combination:**

| `backup-info.txt` | Meaning | What to do |
| --- | --- | --- |
| `status: ok` + `mirror: ok` | Run completed **and** off-machine copy is in place | nothing |
| `status: ok` + `mirror: failed` | Config captured, but the off-machine copy **failed** | fix `BACKUP_DEST` (disk mounted? writable?) and re-run `./backup.sh` |
| `status: ok` + `mirror: disabled` | Run completed; no off-machine copy (`BACKUP_DEST` unset) | nothing — expected if mirror is intentionally off |
| `status: degraded` | Run **completed** but some declared paths were missing/incomplete; the file exists | review `backup-info.txt` for which artifacts degraded; fix the cause (permissions? removed config?) and re-run — restore needs `--force-incomplete` otherwise |
| no `backup-info.txt` / no `status` line | **No completed, verified run exists** (a completed run always writes the file atomically) | check the run output/log for the error and re-run |

> **Local vs. snapshot marker:** `backups/backup-info.txt` reflects the last **completed,
> verified** publication. `backup.sh` never touches it mid-run — the `in_progress` marker
> is written to the staging manifest (`backups.staging/backup-info.txt`) instead — and it
> is replaced atomically only when a run finishes successfully. So a run that aborts
> during capture leaves the previous `status: ok` marker (and backup) in place; a missing
> local file means no completed run exists (or the run died exactly inside the atomic
> swap). The newest mirror snapshot only receives the marker on a successful run — check
> the **local** file for the latest run's truth, then verify the snapshot you restore
> from carries a matching marker.

**Is `backups/` committed?** No — it's git-ignored (config can contain secrets).
`backup.sh` automatically mirrors the whole folder (no filtering) to the local disk at
`BACKUP_DEST` (default `/media/vikram-athare/Storage/backup-restore-ubuntu`), keeping
only the newest `BACKUP_KEEP` (default 5) snapshots. Set `BACKUP_DEST`/`BACKUP_KEEP`
as env vars to override (e.g. `BACKUP_DEST=  ./backup.sh` disables the mirror).

**Can I change versions?** The repo never pins versions. If you need an exact old version
of something, this repo isn't the tool for it — that's a deliberate design choice.

## What is NOT covered (restore these manually)

Some things deliberately live **outside** the inventory, because they are your own
projects with no "recommended source" to reinstall from — or because backing them up
wholesale would violate the config-only principle. After a restore, do these by hand:

| Project | Why it's not in the inventory | Manual restore steps |
| --- | --- | --- |
| `chatgpt-local-api` (`~/chatgpt-local-api`, uvicorn on `:8000`) | Your own code; 1.5 GB with `.venv` + `data/` — too large and too personal to capture as config | re-clone the repo, recreate the venv (`.venv`), copy `.env` secrets, re-copy the user unit file to `~/.config/systemd/user/chatgpt-local-api.service`, then `systemctl --user enable --now chatgpt-local-api.service` |
| `my-trading-bot` (`~/my-trading-bot`, docker compose + `.env.compose`) | Your own code + secrets; not installable from any package source | re-clone the repo, recreate `.env.compose`, pull images (`docker compose pull`), then re-import the `trading-bot-*.service` + `trading-bot-*.timer` units (`systemctl --user enable --now trading-bot-telegram.timer` etc.) |
| Tailscale node identity (`/var/lib/tailscale/tailscaled.state`) | Root-owned; `backup.sh` runs without sudo and cannot capture it | after restore, re-run `tailscale up` (the app itself is installed fresh from the official installer) |

If you ever want a project captured automatically, the clean way is to declare its
service units + env/compose files via `./inventory.sh add-service` (with `config_paths`)
and re-clone the code yourself — or declare a whole folder as a `user_dirs` entry if size
isn't a concern.

## For AI agents

Read `AGENTS.md` first — it contains the mission, the non-negotiable principles, the
inventory schema, and the coding conventions that every change must follow.
