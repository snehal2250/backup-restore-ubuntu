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
> `~/.config/opencode`. On a fresh system, `restore.sh` runs
> `curl -fsSL https://opencode.ai/install | bash` (latest version, official repo), then
> restores your `~/.config/opencode` on top.

This is how you'd set up a new machine by hand — automated, and only for the things
**you** installed on top of stock Ubuntu. No version pinning, no dependency guessing, no
copying of the OS itself.

## Quick start

> **Prerequisite:** the scripts read the inventory with `yq`. `inventory.sh` and
> `backup.sh` will offer to install it for you (`sudo snap install yq`); `restore.sh`
> auto-installs it on a fresh system.

```bash
# 1. Declare what you use (your manual responsibility — this file is the source of truth)
./inventory.sh                      # show current inventory
./inventory.sh wizard               # guided: scan the system, declare apps one by one
./inventory.sh add-app opencode     # opencode etc. are known in the built-in catalog
./inventory.sh add-package apt git
./inventory.sh add-service          # wizard for a custom service you installed
./inventory.sh review               # suggest apps found on this system that you haven't declared

# 2. Back up the configuration of everything declared
./backup.sh                         # writes to backups/ AND mirrors it to BACKUP_DEST
#   (default BACKUP_DEST=/media/vikram-athare/Storage/backup-restore-ubuntu,
#    full unfiltered copy, last 5 snapshots kept — override with env vars)

# 3. On a fresh Ubuntu: restore (fresh install + your config)
./restore.sh                        # prompts; --yes to skip, --dry-run to preview
./restore.sh --upgrade-base         # OPT-IN: also apt full-upgrade of the base OS

# Keep everything current day-to-day
./update_all_ubuntu.sh
```

## Commands

| Command | What it does | Safe to run |
| --- | --- | --- |
| `./inventory.sh list` | Show declared apps/packages/services + installed status | ✅ |
| `./inventory.sh add-app <name>` | Interactive wizard to declare an app | ✅ |
| `./inventory.sh add-package apt\|snap\|flatpak <name>` | Add a package to a list | ✅ |
| `./inventory.sh add-service` | Interactive wizard to declare a custom service | ✅ |
| `./inventory.sh remove-app/-package/-service` | Remove a declaration | ✅ |
| `./inventory.sh review` | Suggest undeclared apps found on the system | ✅ |
| `./inventory.sh wizard` | Guided flow: scan the system, declare apps one by one | ✅ |
| `./backup.sh` | Capture configs + service units + dotfiles → `backups/`, mirror to `BACKUP_DEST` (keep last `BACKUP_KEEP`) | ✅ |
| `./restore.sh` | Fresh install + config restore (base OS upgrade is opt-in: `--upgrade-base`) | ⚠️ modifies system |
| `./update_all_ubuntu.sh` | Update apt/snap/flatpak/npm + declared apps | ⚠️ modifies system |
| `./schedule_cron.sh` | Install a @reboot scheduled backup | ⚠️ edits crontab |

## Layout

```
inventory/inventory.yaml   the single source of truth (user-maintained)
lib/common.sh              shared helpers for all scripts
lib/catalog.sh             built-in knowledge of common apps (opencode, code, docker, ...)
inventory.sh               the manual inventory tool
backup.sh                  capture configuration -> backups/
restore.sh                 fresh install + config overwrite
update_all_ubuntu.sh       update everything
schedule_cron.sh           scheduled backup after reboot
backups/                   captured configuration (git-ignored)
                           mirrored to BACKUP_DEST (default /media/vikram-athare/Storage/backup-restore-ubuntu)
```

## FAQ

**Does restore copy packages from the backup?** No. Packages are installed fresh from
Ubuntu repos / Snap Store / Flathub / official installers at their latest stable versions.
Only configuration is copied.

**What about dependencies?** Each app can declare its own dependencies (`depends_apt`) and
they are installed automatically with the app. You never see them as separate inventory
items — you only think about the main apps you use.

**Which services are managed?** Only the custom services **you** declare in the inventory
(unit files in `/etc/systemd/system` or `~/.config/systemd/user`). Default system services
are never touched.

**My custom service needs a config file or env file.** Declare it in the service's
`config_paths` when you run `add-service` (or put it under the relevant app's
`config_paths`). `backup.sh` captures it; `restore.sh` puts it back after installing the
service.

**Is `backups/` committed?** No — it's git-ignored (config can contain secrets).
`backup.sh` automatically mirrors the whole folder (no filtering) to the local disk at
`BACKUP_DEST` (default `/media/vikram-athare/Storage/backup-restore-ubuntu`), keeping
only the newest `BACKUP_KEEP` (default 5) snapshots. Set `BACKUP_DEST`/`BACKUP_KEEP`
as env vars to override (e.g. `BACKUP_DEST=  ./backup.sh` disables the mirror).

**Can I change versions?** The repo never pins versions. If you need an exact old version
of something, this repo isn't the tool for it — that's a deliberate design choice.

## For AI agents

Read `AGENTS.md` first — it contains the mission, the non-negotiable principles, the
inventory schema, and the coding conventions that every change must follow.
