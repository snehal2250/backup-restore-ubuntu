# RESTORE.md — Step-by-step system restore

This document is the runbook for rebuilding an Ubuntu desktop from this repo. It is the
*user-facing* companion to `restore.sh`. Read `AGENTS.md` for the philosophy; read this
file when you are actually restoring a machine.

> **What restore does (in one sentence):** install everything you declared in
> `inventory/inventory.yaml` **fresh** from recommended sources at the latest stable
> versions, then overwrite them with your saved configuration from `backups/`.
>
> It never copies binaries or packages from the backup, never replays dpkg state, and
> never pins versions.

---

## 0. Understand the flow first

`restore.sh` runs in five phases. Nothing happens in a phase unless the inventory declares
items for it, and the whole thing is **idempotent** — you can re-run it safely.

| Phase | What it does | Requires inventory |
| --- | --- | --- |
| 1/5 Base system | `apt-get update`; full-upgrade **only if** `--upgrade-base` (opt-in) | — |
| 2/5 Packages | installs `apt_packages`, `snap_packages` (incl. `:classic`), `flatpak_apps` | the package lists |
| 3/5 Apps | per app: installs `depends_apt`, then the app itself, then restores its config | `apps:` |
| 4/5 Services | copies unit files, enables/starts them, restores their config | `services:` |
| 5/5 Dotfiles & user dirs | copies declared dotfiles to `$HOME`; restores whole `user_dirs` folders (e.g. `~/Documents`) | `dotfiles:` + `user_dirs:` |

Flags:

```bash
./restore.sh                 # prompts before touching the system
./restore.sh --yes           # skip all prompts
./restore.sh --dry-run       # preview everything, execute nothing
./restore.sh --upgrade-base  # OPT-IN: also apt full-upgrade the base OS + autoremove
```

---

## 1. Before you restore (on your working machine)

Make sure the snapshot you are about to use is current:

```bash
# 1. Inventory reflects everything you use (your manual responsibility)
./inventory.sh list

# 2. Capture the latest configuration
./backup.sh                  # writes backups/ AND mirrors it to BACKUP_DEST

# 3. Confirm the last backup SUCCEEDED before you go (see "How do I know the
#    last backup succeeded?" in README.md):
tail -5 backups/backup-info.txt      # must contain a 'status: ok' line
#   Also confirm the newest mirror snapshot carries the same marker:
newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
tail -5 "$newest/backup-info.txt"
```

> If `backup-info.txt` has **no** `status: ok` line, the last run did not complete —
> re-run `./backup.sh` and fix whatever it reports before restoring from a snapshot.
>
> **Local vs. snapshot marker:** the local `backups/backup-info.txt` reflects the **last
> run** (a new run truncates it immediately; only a completed run re-appends `status: ok`).
> The newest mirror snapshot only receives the marker on a successful run — so check the
> **local** file for the truth about the most recent run, and only then verify the snapshot
> you are about to restore from carries a matching marker.

The mirror lives at `BACKUP_DEST` (default `/media/vikram-athare/Storage/backup-restore-ubuntu`)
as timestamped snapshots, keeping the newest `BACKUP_KEEP` (default 5). The newest
snapshot is the full, unfiltered copy of `backups/`.

---

## 2. Set up the fresh machine

### 2.1 Install Ubuntu
Install a stock Ubuntu (same major release is ideal) and complete first-boot setup.
The target user **must have sudo rights** (the default first user does).

### 2.2 Get the repo onto the machine
The repo carries the scripts + the inventory. Get it onto the new machine **from a
source that contains the repo itself** — the Storage disk only holds `backup-*` config
snapshots (the mirror of `backups/`), not the repo:

```bash
# Option A: git clone (if you keep this repo on a remote)
git clone <your-remote> ~/backup-restore-ubuntu
cd ~/backup-restore-ubuntu

# Option B: copy the repo folder from the old machine (USB stick, network share...)
cp -r <path-to-repo-on-old-machine> ~/backup-restore-ubuntu
cd ~/backup-restore-ubuntu
```

### 2.3 Bring your configuration onto the machine
The configuration that `restore.sh` puts back lives in **`backups/`** inside the repo.
That folder is git-ignored, so a fresh `git clone` won't have it — restore it from the
newest mirror snapshot on the Storage disk:

```bash
# Copy ONLY the newest snapshot's contents into backups/
# (the backup-* glob is NOT sorted newest-first — pick it explicitly.
#  Sort by NAME (-r) like the rotation code does: names are zero-padded
#  timestamps, so name order == chronological order, unlike mtime.)
mkdir -p backups
newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
cp -a "$newest/." backups/

# or pick a specific snapshot explicitly:
#   ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-*
#   cp -a "/media/vikram-athare/Storage/backup-restore-ubuntu/backup-YYYYMMDD-HHMMSS.../." backups/
```

> If you skip this step, restore still installs everything — but **no configuration can be
> restored** (restore prints a warning and skips config copying).

### 2.4 Check prerequisites
- `sudo` — already required above.
- `yq` — a real `restore.sh` run **auto-installs it** on a fresh system (via `snap` or a
  download), so you normally don't need to do anything. Note: `--dry-run` does **not**
  auto-install — if `yq` is missing it prints install instructions instead (that is
  intentional: previews never modify the system).
- Network access to the repos the inventory uses (apt, Snap Store, Flathub, official
  installers).

---

## 3. Preview (recommended first run)

Never skip the preview on a machine you care about:

```bash
cd ~/backup-restore-ubuntu
./restore.sh --dry-run
```

Read the output carefully. For every app you should see one of:
- `already installed (found '...')` — the check binary exists; no install will happen;
- `[dry-run] sudo apt-get install -y ...` / `[dry-run] sudo snap install ...` / etc. — the
  exact install command that will run;
- `[dry-run] install <app>: <install_command>` — the official installer that will run.

Also verify `Phase 4/5: services` lists your custom services and that their unit files
exist in `backups/services/<unit>/unit` (a missing unit file is warned as
"no unit file in backups/ — skipping").

---

## 4. Run the restore

```bash
./restore.sh            # review the prompt, then answer y
# or non-interactively:
./restore.sh --yes
# or if you also want the base OS fully upgraded (opt-in, slower, touches the whole OS):
./restore.sh --yes --upgrade-base
```

### What happens, phase by phase (what to watch)

**Phase 1/5 — base system.** `apt-get update` runs (needed before any apt installs).
Without `--upgrade-base` nothing else happens here by design.

**Phase 2/5 — packages.** apt packages install in one batch. Snap packages install one by
one (classic entries get `--classic`). If `flatpak_apps` is non-empty and flatpak is
missing, it is installed and Flathub is added automatically.

**Phase 3/5 — apps.** For each app: dependencies (`depends_apt`) install first, then the
app via its method (`apt`/`snap`/`snap-classic`/`flatpak`/`npm-global`/`pipx`/`cargo`/
`script`/`custom`). After install, the app's `config_paths` are rsynced back from
`backups/apps/<name>/` — both `$HOME` parts and `/` (root) parts if present.

**Phase 4/5 — services.** Each declared service's unit file is copied to
`/etc/systemd/system/` (system) or `~/.config/systemd/user/` (user), `daemon-reload` runs,
then `enable`/`start` per the declaration, then its `config_paths` are restored.

**Phase 5/5 — dotfiles & user dirs.** Each declared dotfile is copied from
`backups/dotfiles/` to `$HOME`. Whole user-data folders declared in `user_dirs`
(e.g. `~/Documents`) are restored wholesale from `backups/user-dirs/` back to `$HOME`.
Declare them with `./inventory.sh add-user-dir ~/Documents`; `backup.sh` captures them
in full (they are user data, not app config).

Two failure behaviors, by design:

- A **custom/script installer** that errors (`bash -c "$install_command"`) prints a warning
  and restore **continues** with the remaining apps.
- Any other failure (e.g. an `apt`/`snap` install error) **aborts the run** (`set -e`).
  Fix the cause, then re-run `./restore.sh --yes` — restore is idempotent and picks up
  where it left off.

---

## 5. After the restore

```bash
# 1. Review the output for warnings you should act on
#    (failed custom installers, missing unit files, skipped configs...)

# 2. Verify a few apps launched/CLI commands work:
code --version          # vs code
gh --version
opencode --version
fish --version
systemctl status cloudflared.service   # your custom services

# 3. Reboot so services and configuration take full effect
sudo reboot

# 4. Keep everything current going forward
./update_all_ubuntu.sh
```

**Apps whose state is NOT restored (by design) need a one-time manual step:**

- **Slack, OnlyOffice, Storage Explorer** — snap GUI apps: re-login after first launch
  (their login/state lives in snap revision dirs, which are not backed up).
- **Ollama** — models are intentionally not backed up (many GB, reproducible): re-pull with
  `ollama pull <model>` after restore.
- **Apps with `exclude:` lists** (VS Code, Google Chrome, Freebuff, Docker, Azure CLI,
  MongoDB Compass, ...) — excluded caches, model stores, bundled binaries, and installed
  extensions are not captured, so they are not restored either; they regenerate (or
  re-download) on first launch. Only real configuration comes back.
- **Azure CLI extensions** (`az` `cliextensions`, e.g. `azure-devops`) — installed
  extension packages are excluded as binaries; re-add what you use with
  `az extension add -n <name>` after restore. Credentials and profile ARE restored.
- Any app with no `config_paths` declared in the inventory is reinstalled fresh but starts
  with defaults — check `./inventory.sh list` for entries missing `config_paths`.

These are deliberate trade-offs (principle: config-only backup, no binaries/models), not
mistakes — the inventory comments note each one.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `yq is required...` at the top | restore failed to auto-install yq (no snap + no curl?). Install it: `sudo snap install yq`, then re-run. |
| `No backups/ found — configuration cannot be restored` | You skipped step 2.3. Copy the newest snapshot into `backups/` and re-run. |
| `no unit file in backups/ — skipping` | The service's unit file wasn't captured. Run `./backup.sh` on your working machine, re-copy `backups/`, re-run. |
| `install command for '<app>' failed` | The official installer errored (network, missing dep). Fix the cause, re-run; restore continues with other items. |
| App installed but config looks missing | Its `config_paths` weren't declared in the inventory (or weren't captured). Declare them with `./inventory.sh` + `./backup.sh`, then re-run restore. |
| Not an Ubuntu system | restore warns and continues; this repo targets Ubuntu only. |

---

## 7. Safety notes

- `restore.sh` is **effectful** — it modifies the system. `--dry-run` previews it;
  `--yes` skips the confirmation. Default restore touches **only** declared items.
- `--upgrade-base` is the exception: it full-upgrades the entire base OS. Only use it when
  you intend that.
- `backups/` contains personal configuration and possible secrets — never commit it, and
  keep the mirror disk safe.
- If you restore onto a machine that already has some apps, restore detects them via
  `check_cmd` and **skips reinstalling** (still restores their config).
