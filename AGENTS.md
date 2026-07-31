# AGENTS.md — Context for AI agents working on this repo

**Read this file first, before any other file.** If a task or a change conflicts with
anything written here, stop and ask the user. This file is the single source of truth for
the project's *why* and *how*.

---

## 1. Mission

This repo restores the user's Ubuntu desktop back to its last-known-good state
**without restoring binaries, packages, or application data from the backup**.

Instead:

- A single user-maintained file, `inventory/inventory.yaml`, declares which
  **applications, packages, services, dotfiles, and user-data folders** the user wants.
- `backup.sh` captures **only the configuration** for those declared items
  (config directories, systemd unit files, dotfiles) plus any whole **user-data
  folders** the user declared (`user_dirs`, e.g. `~/Documents`) into a git-ignored
  `backups/` folder, then mirrors the whole folder (no filtering) to a configurable
  local disk destination.
- `restore.sh` performs a **fresh install** of those items from their recommended sources
  (Ubuntu repositories, Snap Store, Flathub, official installers) at the **latest stable
  versions**, then **overwrites** them with the backed-up configuration.

Example (the canonical one): the user uses OpenCode.
- The inventory declares the `opencode` app.
- `backup.sh` copies `~/.config/opencode` into `backups/apps/opencode/`.
- `restore.sh` runs the official installer `curl -fsSL https://opencode.ai/install | bash`
  (fresh binary, latest version), then restores `~/.config/opencode` on top.

The repo is deliberately **not** a traditional image/byte-level backup. It rebuilds a
system the same way a person would set up a new machine: install what you use, then copy
your settings over it.

## 2. Non-negotiable principles

1. **Fresh install, never copy.** `restore.sh` must install packages/applications from
   their recommended sources at the latest stable version. It must never install from
   backup files, never untar `/opt` or `/usr/local` archives, never replay `dpkg
   --get-selections` state.
2. **Configuration is the only thing copied.** The backup captures configuration for
   inventory items and nothing else: no binaries, no whole-`~/.config` dumps, no dpkg
   databases, no home-directory bulk copying. The one deliberate exception: whole
   user-data folders a user explicitly declares under `user_dirs` (e.g. `~/Documents`)
   are captured in full — those are user data, not app configuration.
3. **The inventory is the single source of truth.** `inventory/inventory.yaml` is the only
   list of what to back up and install. Scripts must never hardcode user apps, package
   names, or services. The seed catalog in `lib/catalog.sh` may *suggest* install methods,
   but it must never bypass the inventory.
4. **Only what the user installed on top of stock Ubuntu.** No kernel/base-system state,
   no default packages, no system-wide dumps. Dependencies of an app (e.g. `nodejs`/`npm`
   for a node-based app) are declared **per app** in the inventory as `depends_apt`, and are
   **never** separate inventory items the user has to think about.
5. **Version-agnostic.** Never record, pin, or restore application/package versions.
   Latest stable wins, always. No `@1.2.3` anywhere in the data.
6. **Idempotent and safe.** Scripts must be safe to run multiple times. `restore.sh`
   prompts before modifying the system (`--yes` to skip) and supports `--dry-run`.
7. **Everything is declarative.** Data lives in `inventory/inventory.yaml`; code lives in
   scripts under this repo. Never mix the two.

## 3. What we deliberately do NOT do (anti-patterns)

| Do not | Because |
| --- | --- |
| `dpkg --set-selections` / `dselect-upgrade` | Restores exact versions/state — violates principle 1 & 5 |
| tar of `/opt`, `/usr/local`, `/etc` | Copies binaries/system state — violates principle 1 & 2 |
| `rsync -a ~/.config/` wholesale | Copies junk + unknown apps — violates principle 2 & 3 |
| Restoring apt sources/keyrings | Fresh Ubuntu ships correct sources — violates principle 1 |
| Recording installed versions/snapshots | Version-agnostic (principle 5) |
| Hardcoding app/package names in scripts | Violates principle 3 |

## 4. Repo map

```
AGENTS.md                 <- this file (agents MUST read it)
README.md                 <- user-facing quick start
docs/PLAN.md              <- roadmap to the end state
docs/RESTORE.md           <- user-facing step-by-step restore runbook
inventory/
  inventory.yaml          <- THE source of truth (user-maintained, git-tracked)
lib/
  common.sh               <- shared helpers (logging, yq bootstrap, YAML getters, status checks)
  catalog.sh              <- seed catalog of common apps (opencode, code, docker, chrome,
                              gh, gcloud, go, uv, tmux, terraform, ollama, az, azurite,
                              slack, onlyoffice, storage-explorer, cloudflared, ...)
inventory.sh              <- MANUAL tool: list / add-* / remove-* / review / wizard
backup.sh                 <- captures configs + service units + dotfiles -> backups/
restore.sh                <- fresh install + config overwrite (--dry-run/--yes/--upgrade-base)
update_all_ubuntu.sh      <- updates apt/snap/flatpak/npm + inventory apps
schedule_cron.sh          <- @reboot scheduled backup
backups/                  <- output of backup.sh (GIT-IGNORED; contains personal config)
                             (apps/<name>/, services/<unit>/, dotfiles/, user-dirs/<name>/)
                           mirrored to BACKUP_DEST (default /media/vikram-athare/Storage/backup-restore-ubuntu)
                           (legacy backup/ folder from the old script was reviewed and
                           deleted; a 36 KB root-owned remnant still needs the user's
                           final 'sudo rm -rf backup')
```

## 5. Inventory model (`inventory/inventory.yaml`)

The file is plain YAML with four flat lists (plus `user_dirs`) and two structured lists.
See the file itself for the commented template. The live inventory currently declares **23 apps + 1 service**
(four of them — gcloud, gh, go, uv — use install methods corrected to match how the user
actually installed each tool).

```yaml
apt_packages:            # installed via: sudo apt-get install -y <item>
  - git
snap_packages:           # suffix ':classic' = classic confinement (e.g. code:classic)
  - code:classic
flatpak_apps:            # installed via: flatpak install -y flathub <item>
  - org.gimp.GIMP
dotfiles:                # copied from/to $HOME (e.g. .bashrc, .gitconfig)
  - .bashrc
user_dirs:               # WHOLE user-data folders captured/restored in full (e.g. Documents)
  - ~/Documents          # user data, not app config — backed up whole, restored wholesale

apps:                    # one entry per MAIN app. Dependencies are per-app, never separate.
  - name: opencode
    description: AI coding agent
    install_type: script            # apt|snap|snap-classic|flatpak|npm-global|pipx|cargo|script|custom
    install_command: curl -fsSL https://opencode.ai/install | bash   # required for script/custom
    check_cmd: opencode             # optional: binary to test "already installed"
    depends_apt:                    # optional: auto-installed before the app (NOT inventory items)
      - curl
    config_paths:                   # optional: backed up + restored (overwritten) for this app
      - ~/.config/opencode
  - name: gcloud                    # package: only for apt/snap/snap-classic/flatpak, when
    install_type: snap-classic      # the package name differs from the app name (here the
    package: google-cloud-cli       # snap is google-cloud-cli; also e.g. onlyoffice ->
    check_cmd: gcloud               # onlyoffice-desktopeditors). The wizard prompts for it
    config_paths:                   # after you pick the install method.
      - ~/.config/gcloud

services:                # only CUSTOM services the user installed. Nothing default.
  - unit: myservice.service
    target: system                  # system (/etc/systemd/system) or user (~/.config/systemd/user)
    enable: true
    start: true
    config_paths:                   # optional: config files the service needs (env file, config dir)
      - ~/.config/myservice
```

Rules for agents editing the inventory:

- Only add items the user explicitly asked for, or that `inventory.sh` produced. Never
  invent apps/packages/services from guesswork.
- `install_type` values: `apt`, `snap`, `snap-classic`, `flatpak`, `npm-global`, `pipx`,
  `cargo`, `script` (official installer), `custom` (arbitrary command). For `script`/
  `custom`, `install_command` is required.
- Optional `package` overrides the package name for `apt`/`snap`/`snap-classic`/`flatpak`
  installs when it differs from the app name (e.g. app `gcloud` installs snap
  `google-cloud-cli`, app `onlyoffice` installs snap `onlyoffice-desktopeditors`). The
  wizard prompts for it after the install method is chosen.
- `config_paths` and `user_dirs` use `~` (tilde) form, not absolute `/home/...` paths,
  for portability.
- `user_dirs` entries are whole data folders (e.g. `~/Documents`); they are captured and
  restored wholesale under `backups/user-dirs/` — this is the deliberate data-backup
  exception to principle 2.
- A custom service's runtime files (env file, config dir, helper script) belong in that
  service's `config_paths` (or the relevant app's `config_paths`). They are never
  auto-inferred from the unit file alone.
- Do not add dependencies as separate entries (principle 4).

## 6. Standard workflows

**Declare an app** (the user's manual responsibility; the tool does the work):
```bash
./inventory.sh add-app opencode     # wizard; catalog prefills opencode
./inventory.sh add-package apt git
./inventory.sh add-service          # wizard (unit file, target, enable/start, config paths)
./inventory.sh add-user-dir ~/Documents   # declare a whole user-data folder
./inventory.sh list                 # see everything + installed status
./inventory.sh review               # suggests apps found on the system, not yet declared
./inventory.sh wizard               # guided: scan the system, declare apps one by one
```

**Backup** (captures config for everything declared, plus any `user_dirs`):
```bash
./backup.sh
```
Output goes to `backups/` (git-ignored), then the whole folder is mirrored **without
filtering** to `BACKUP_DEST` (env-overridable; default
`/media/vikram-athare/Storage/backup-restore-ubuntu`), keeping only the newest
`BACKUP_KEEP` (default 5) timestamped snapshots. On a successful run `backup.sh` appends
a **success marker** (`status: ok` + `finished:` + `mirror:`) to `backups/backup-info.txt`
— its absence means the run did NOT complete. The newest mirror snapshot carries the same
file. See the README's "How do I know the last backup succeeded?" for the exact check
commands. `BACKUP_DEST=` disables the mirror. Never commit `backups/` (see docs/PLAN.md).

**Restore** (on a fresh Ubuntu install):
```bash
./restore.sh                 # prompts; adds --yes to skip prompts, --dry-run to preview
./restore.sh --upgrade-base  # OPT-IN: also apt full-upgrade of the base OS
```
By default restore only touches the items declared in the inventory (principle 4); it
never upgrades the whole base OS unless `--upgrade-base` is passed.

**Keep everything current**:
```bash
./update_all_ubuntu.sh
```

## 7. Conventions for AI agents

- **Shell code**: bash, `set -euo pipefail` at the top of every script, `shellcheck`
  clean. Scripts run on Ubuntu's default bash (4.x) — no bash 5-only features.
- **Reuse `lib/common.sh`**: logging (`info/ok/warn/err/die`), `confirm`, `require_cmd`,
  `require_yq`, `yaml_get`, `yaml_list`, `expand_path`, `run` (dry-run aware), status
  checkers (`is_apt_installed`, `is_snap_installed`, `is_flatpak_installed`). Never
  duplicate these in new scripts.
- **YAML is read with `yq`** (https://github.com/mikefarah/yq). `require_yq` follows
  `YQ_AUTO`: fail with install instructions (default), install silently (restore on a fresh
  system), or ask the user first (inventory.sh/backup.sh). Write YAML with `yq -i` and
  `strenv(VAR)`/`load()`/`env()` — never by string-concatenating user input into
  expressions. Note: the installed yq v4.53.3 does **not** support `--arg`; use
  `strenv()` (or `env()`) with an inline `VAR=value` prefix instead.
- **Never run `restore.sh` or `update_all_ubuntu.sh` on the user's machine without
  explicit permission.** `inventory.sh` only edits the inventory; `backup.sh` only writes
  to the git-ignored `backups/`. Both are safe. `restore.sh` modifies the system.
- **When adding features**: keep `inventory.yaml` backward compatible; update `AGENTS.md`
  (this file), `README.md`, and `docs/PLAN.md` if the schema, principles, or workflow
  change. If you change an exported helper in `lib/common.sh`, update all callers.
- **Validate before finishing**: `bash -n <script>` on every script, `shellcheck
  <script>` if installed. Prefer running `./inventory.sh list` and `./backup.sh` (safe)
  over `restore.sh` (effectful).

## 8. Glossary

- **Inventory** — the declarations in `inventory/inventory.yaml` (what the user uses).
- **Backup** — captured configuration in `backups/` (git-ignored, machine-specific).
- **Restore** — fresh install from recommended sources + config overwrite from `backups/`.
- **Catalog** — built-in knowledge in `lib/catalog.sh` used by `inventory.sh add-app`.
- **Custom service** — a systemd unit the user installed themselves; only these are ever
  declared in the inventory.
