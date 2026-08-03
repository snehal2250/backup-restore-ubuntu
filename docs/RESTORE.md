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

`restore.sh` runs in six phases. Nothing happens in a phase unless the inventory declares
items for it, and the whole thing is **idempotent** — you can re-run it safely.

| Phase | What it does | Requires inventory |
| --- | --- | --- |
| 1/6 Base system | `apt-get update`; full-upgrade **only if** `--upgrade-base` (opt-in) | — |
| 2/6 Packages | installs `apt_packages`, `snap_packages` (incl. `:classic`), `flatpak_apps` | the package lists |
| 3/6 Apps | per app: installs `depends_apt`, then the app itself, then restores its config | `apps:` |
| 4/6 Services | copies unit files, restores their config, then enables/starts them | `services:` |
| 5/6 Dotfiles & user dirs | copies declared dotfiles to `$HOME`; restores whole `user_dirs` folders (e.g. `~/Documents`) | `dotfiles:` + `user_dirs:` |
| 6/6 Post-install | adds `groups` (`usermod -aG`), sets `default_shell` (`chsh`), installs app `extensions`/models | `groups:`, `default_shell`, `extensions` |

Flags:

```bash
./restore.sh                 # prompts before touching the system
./restore.sh --yes           # skip all prompts
./restore.sh --dry-run       # preview everything; only yq auto-installs if missing
./restore.sh --source <snapshot-dir>
#                            # restore config DIRECTLY from an external backup
#                            # snapshot (no copying into backups/ needed); the
#                            # repo checkout is disposable, the snapshot is authoritative
./restore.sh --upgrade-base  # OPT-IN: also apt full-upgrade the base OS + autoremove
./restore.sh --configs-only  # restore config only (skip all installs)
./restore.sh --packages-only # install fresh only (skip config restore)
./restore.sh --plan          # preview the plan: which phases/apps will run (dry-run)
./restore.sh --from-phase services
#                            # resume a failed restore: skip everything before this
#                            # phase (base|packages|apps|services|dotfiles|postinstall)
./restore.sh --only code,git # only these apps (plus any listed phases) run
./restore.sh --skip user-data
#                            # skip this phase (user-data == the dotfiles phase) and/or
#                            # these apps; --skip user-data == --skip dotfiles
./restore.sh --non-interactive
#                            # never prompt (implies --yes); for scripts/automation
```

Every phase boundary is recorded in the restore journal
(`~/.local/state/backup-restore-ubuntu/rollback-<timestamp>/restore-journal.log`) as
`phase-start`/`phase-done` lines, so an interrupted run leaves a durable record of where
it got to. `--only`/`--skip` accept **phase names AND app names** — phase names gate
whole phases, app names filter the apps phase (so `--only code,git` restores just those
apps while every phase still runs). Unknown names are rejected with an error.

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
tail -5 backups/backup-info.txt      # must show a restorable status ('ok' or 'ok_with_warnings')
#   Also confirm the newest mirror snapshot carries the same marker:
newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
tail -5 "$newest/backup-info.txt"
```

> The manifest reports one of four statuses: `ok` (all captured + mirror ran),
> `ok_with_warnings` (complete backup; mirror not `ok` — disabled or failed —
> restorable), `degraded` (some
> non-required item missing/incomplete — restore needs `--force-incomplete`), or
> `failed` (a REQUIRED item — `required: true` / `on_missing: fail` — is missing;
> restore refuses by default). For `degraded`/`failed`, re-run `./backup.sh` and fix
> what it reports (or restore with `--force-incomplete`). If the file is **missing
> entirely**, no completed, verified run exists — re-run `./backup.sh` before restoring
> from a snapshot.
>
> **Local vs. snapshot marker:** the local `backups/backup-info.txt` reflects the last
> **completed, verified** run. `backup.sh` never truncates it mid-run — the `in_progress`
> marker is written to the staging manifest instead — and it is replaced atomically only
> when a run finishes successfully. A run that aborts during capture leaves the previous
> restorable marker intact; a missing local file means no completed run exists (or the
> run died inside the atomic swap). The newest mirror snapshot only receives the marker on
> a successful run — so check the **local** file for the truth about the most recent run,
> and only then verify the snapshot you are about to restore from carries a matching
> marker.
>
> **Snapshot authority:** the newest mirror snapshot is **not** automatically the last
> successful backup — publication rolls back a degraded/failed generation to the previous
> one, so a snapshot can be *newer* than the local live backup while the local one stays
> the restorable truth, and a snapshot itself can carry `degraded`/`failed`. Judge every
> snapshot **on its own `backup-info.txt`**, never by its timestamp (see § 3).

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

> **Easier alternative: `--source` (no copy needed).** Instead of copying a snapshot
> into `backups/`, point restore directly at the snapshot on the external drive — the
> repo checkout stays disposable and the backup medium is authoritative:
>
> ```bash
> newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
> ./restore.sh --source "$newest" --dry-run    # preview first
> ./restore.sh --source "$newest" --yes        # then restore for real
> ```
>
> `--source` resolves the path with `realpath`, requires a **verified** `backup-info.txt`
> (restorable status `ok`/`ok_with_warnings` + artifact list; `degraded`/`failed` need
> `--force-incomplete`), and checks
> architecture / Ubuntu release / inventory-SHA compatibility before any system change.
> It warns if the source is writable (a read-only medium is safer), and prints the exact
> source snapshot before touching anything. Nothing is copied or mounted implicitly.
>
> Because an explicit `--source` is authoritative, a bad source is **fatal** (restore
> stops with an error) — unlike a bad local `backups/`, which warns and continues with
> packages only. The same strict preflight applies even with `--packages-only`
> (config restore is skipped, but the source must still be a valid, verified snapshot).

### 2.4 Check prerequisites
- `sudo` — already required above.
- `yq` — `restore.sh` **auto-installs it** on a fresh system (via `snap` or a download),
  for both a real run **and** `--dry-run` (a preview still needs to parse the inventory),
  so you normally don't need to do anything. If the auto-install fails (no `snap`, no
  `curl`), install it manually: `sudo snap install yq`.
- **Schema validator** — `restore.sh` validates the inventory against the versioned
  JSON Schema (`inventory/schema.yaml`) with `lib/schema_check.py` (python3 + the
  `jsonschema` library). On a fresh system it **auto-installs**
  `python3-jsonschema python3-yaml` via apt (same policy as `yq`: needed even for
  `--dry-run`). Install manually if needed:
  `sudo apt-get install -y python3-jsonschema python3-yaml`.
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
  exact install step that will run;
- typed-installer dry-run steps — e.g. `[dry-run] curl -fsSL -o /etc/apt/keyrings/...`
  (repo key), `[dry-run] sudo apt-get install -y <pkg>` (from an `apt_repository`),
  `[dry-run] curl -fsSL -o /tmp/... .deb` + `[dry-run] sudo apt-get install -y /tmp/...deb`
  (a `deb`), or `[dry-run] bash /tmp/<app>.install.sh` (a `script`).

Also verify `Phase 4/6: services` lists your custom services and that their unit files
exist in `backups/services/<unit>/unit` (a missing unit file is warned as
"no unit file in backups/ — skipping").

Before anything else, expect a `Backup content verified (SHA256SUMS)` line: `restore.sh`
checksum-verifies the payload and rejects hostile files (device/FIFO/socket, symlinks
escaping the snapshot) before touching the system. A snapshot without `SHA256SUMS`
(created before integrity checking) prints a warning and is accepted.

---

## 4. Run the restore

```bash
./restore.sh            # review the prompt, then answer y
# or non-interactively (choose ONE — pasting both runs the full base-OS upgrade):
./restore.sh --yes
```

**Run it from a TTY, and tee the output to a log.** A long restore (10–30+ min) can be
interrupted by a locked GUI screen, leaving apt/dpkg half-configured. On a desktop,
switch to a TTY with `Ctrl+Alt+F3`, log in, and run:

```bash
cd ~/backup-restore-ubuntu
./restore.sh --yes 2>&1 | tee ~/restore.log
```

> **Never power-cycle mid-restore.** A hard power-off during an apt transaction breaks
> the package state (D-Bus/polkit/GDM fail on next boot). If a run fails, re-run it —
> restore is idempotent and picks up where it left off. The tee'd log shows exactly where
> it stopped.

`--upgrade-base` is a **separate, deliberate exercise** (opt-in, slower, touches the whole
OS). Run it only after the plain restore succeeds, you've rebooted and verified, and the
network is stable:

```bash
./restore.sh --yes --upgrade-base
```

### What happens, phase by phase (what to watch)

**Phase 1/6 — base system.** `apt-get update` runs (needed before any apt installs).
Without `--upgrade-base` nothing else happens here by design.

**Phase 2/6 — packages.** apt packages install in one batch. Snap packages install one by
one (classic entries get `--classic`). If `flatpak_apps` is non-empty and flatpak is
missing, it is installed and Flathub is added automatically.

**Phase 3/6 — apps.** For each app: dependencies (`depends_apt`) install first, then the
app via its typed `installer:` record (`apt`/`snap`/`snap_classic`/`flatpak`/
`npm_global`/`pipx`/`cargo`/`apt_repository`/`deb`/`tarball`/`script` — implemented in
`lib/installers.sh`). After install, the app's `config_paths` are rsynced back from
`backups/apps/<name>/` — both `$HOME` parts and `/` (root) parts if present. With
`--only <apps>` only the listed apps run here; `--skip <apps>` skips the listed ones.

**Phase 4/6 — services.** Each declared service's unit file is copied to
`/etc/systemd/system/` (system) or `~/.config/systemd/user/` (user), `daemon-reload` runs,
then its `config_paths` (env file, config dir, ...) are restored, and **then**
`enable`/`start` per the declaration — so the service boots with its real configuration
on first start.

**Phase 5/6 — dotfiles & user dirs.** Each declared dotfile is copied from
`backups/dotfiles/` to `$HOME`. Whole user-data folders declared in `user_dirs`
(e.g. `~/Documents`) are restored wholesale from `backups/user-dirs/` back to `$HOME`.
Declare them with `./inventory.sh add-user-dir ~/Documents`; `backup.sh` captures them
in full (they are user data, not app config).

**Phase 6/6 — post-install.** Declared `groups` are added via `usermod -aG`, the
`default_shell` is set via `chsh` (if declared and provided by a declared app), and each
declared app's `extensions` (VS Code extensions, Azure CLI extensions, Ollama models) are
installed through the app's native mechanism.

**Config restore honours conflict policies, with a rollback bundle + journal.** Each
app/service may declare `conflict_policy` (default `merge`): `merge` = additive overlay,
never deletes (a config file that no longer exists in the backup is not removed —
deliberate: restore must never delete data); `replace` = preserve existing into the
rollback bundle, remove **only the exact leaf files** the backup would restore, then
merge-restore (never `rsync --delete` against `$HOME` or `/` — that would wipe unrelated
data); `skip-existing` = restore only missing files; `prompt` = ask per config path
(non-interactive runs skip).
Before any overwrite, restore captures what exists into a timestamped rollback bundle at
`~/.local/state/backup-restore-ubuntu/rollback-<timestamp>/` (OUTSIDE the backup source)
and appends one line per operation to its `restore-journal.log`
(created/replaced/skipped/failed). The bundle path is printed at the end of the run —
copy files back from it to undo, `rm -rf` it once satisfied. `--dry-run` creates nothing.

Two failure behaviors, by design:

- A **`script`/`deb`/`tarball` installer** that errors (download failure, checksum
  mismatch, the remote script exits nonzero) prints a warning and restore **continues**
  with the remaining apps.
- Any other failure (e.g. an `apt`/`snap` install error) **aborts the run** (`set -e`).
  Fix the cause, then re-run `./restore.sh --yes` — restore is idempotent and picks up
  where it left off.

> ⚠️ A green `[ OK ] <app>: config restored` line means the *captured config* was copied
> back — it does **not** mean the app's install step succeeded (a failed installer still
> restores config before restore continues). Watch the warning lines above each app, not
> just the green ones.

---

## 5. After the restore

```bash
# 1. Review the output for warnings you should act on
#    (failed script installers, missing unit files, skipped configs...)
# 1b. The run printed a rollback bundle path — keep it until you have verified the
#     machine, then review its restore-journal.log and rm -rf the bundle when satisfied.

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
- **Azure CLI extensions** (`az` `cliextensions`) — installed extension packages are
  excluded as binaries; re-add what you use with `az extension add -n <name>` after
  restore. Credentials and profile ARE restored.

  Current extension list captured on 2026-07-31 (re-verify with `az extension list`;
  `az extension add` installs the latest — the version below is informational only):

    ```bash
    az extension add -n azure-devops   # v1.0.6 in use at capture time
    ```
- Any app with no `config_paths` declared in the inventory is reinstalled fresh but starts
  with defaults — check `./inventory.sh list` for entries missing `config_paths`.

These are deliberate trade-offs (principle: config-only backup, no binaries/models), not
mistakes — the inventory comments note each one.

---

## 6. Rehearse on a disposable VM (do this once, before you ever need a real restore)

A rehearsal runs the full restore path (sections 2–5 above) on a **throwaway VM** so you
can prove the mechanics work on a genuinely fresh system — without risking your real
machine. You cannot test restore on your working machine: everything is already
installed, so `restore.sh` would just skip each app. The rehearsal is the only way to
exercise the real path (fresh install → config overwrite → services up).

Cost: ~1–2 hours + a few GB of disk. Plan for it once.

> **📌 Tested rehearsal path: VirtualBox.** The full, click-by-click procedure (install
> Oracle's VirtualBox 7.1.x, create the VM, install Ubuntu, wire real `vboxsf` shared
> folders, replay the restore) is documented separately in
> **`docs/REHEARSAL-VIRTUALBOX.md`**. The sections below are the generic, hypervisor-
> agnostic steps; use the VirtualBox doc for the exact commands and GUI details.
> VirtualBox was chosen over GNOME Boxes because its shared folders (`/media/sf_*`) are
> **real live mounts** — GNOME Boxes' built-in sharing is SPICE-WebDAV, which behaves
> like copy-based file-manager access rather than a live folder.

### 6.1 Pre-rehearsal hardware checklist (run once, on the real machine)

The rehearsal creates a real VM, so the machine that runs it needs a working hypervisor
with hardware acceleration. Do this **once** on the working machine (not inside a
prep/CI environment — the VM needs your actual hardware):

**1. Install a hypervisor.** VirtualBox is the tested path for this rehearsal. Use
**Oracle's VirtualBox 7.1.x** — the Ubuntu package (7.0.16) cannot build its kernel
module on this machine's 24.04 HWE kernel 7.0 (KVM symbol namespaces break
`virtualbox-dkms`; see § 1 of docs/REHEARSAL-VIRTUALBOX.md for the exact install and
verification):

```bash
# Oracle repo + VirtualBox 7.1.x (has the kernel fix) — full steps: docs/REHEARSAL-VIRTUALBOX.md
wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] \
https://download.virtualbox.org/virtualbox/debian noble contrib" | \
  sudo tee /etc/apt/sources.list.d/virtualbox.list
sudo apt-get update && sudo apt-get install -y virtualbox-7.1
# then verify: ls -l /dev/vboxdrv  +  getent group vboxusers  +  usermod -aG vboxusers $USER
# alternatives (any hypervisor works — the repo is hypervisor-agnostic):
#   sudo apt-get install -y gnome-boxes      # built-in WebDAV sharing is copy-like; ok in a pinch
#   sudo apt-get install -y qemu-kvm libvirt-daemon-system virt-manager
```

**2. Enable hardware virtualization in the BIOS.** The setting is named **SVM Mode** on
AMD boards (this machine: Gigabyte B550M K) or **Intel VT-x** on Intel. It is off by
default on many boards, and no hypervisor gets hardware acceleration until it is on:

- Reboot and tap **Del** to enter the BIOS; switch to Advanced mode with **F2**;
  **Tweaker/M.I.T. → Advanced CPU Settings → SVM Mode → Enabled**; save with **F10**.
- If acceleration still does not work after that, also disable **Secure Boot** and/or
  load the module manually: VirtualBox → `sudo modprobe vboxdrv`;
  KVM/Boxes → `sudo modprobe kvm_amd` (Intel: `kvm_intel`).

**3. Verify acceleration is live** (after rebooting back into Ubuntu):

```bash
# VirtualBox (tested path) — uses its OWN kernel module:
lsmod | grep vboxdrv                    # expect: vboxdrv ...
ls -l /dev/vboxdrv                      # expect: crw-rw---- 1 root vboxusers ...
getent group vboxusers                  # expect: vboxusers:x:...  (exists after install)
sudo usermod -aG vboxusers "$USER"      # add yourself, then log out/in once
# KVM/Boxes instead — uses /dev/kvm, NOT vboxdrv:
#   ls -l /dev/kvm                      # expect: crw-rw---- 1 root kvm ...
#   virsh -c qemu:///session list       # expect: no error (virsh ships in libvirt-clients)
#   sudo usermod -aG kvm "$USER"        # if no ACL and access is denied
```

> **Why this matters:** without hardware acceleration (SVM/AMD-V), the hypervisor falls
> back to slow software emulation — the rehearsal still works but can take 20–40× longer.
> Get acceleration working before you start.

### 6.2 Make a fresh backup on your working machine first

```bash
./backup.sh
tail -5 backups/backup-info.txt        # must show a restorable status ('ok' or 'ok_with_warnings')
```
Use this newest snapshot as the rehearsal's config source.

### 6.3 Create the disposable VM

- Any local hypervisor: **VirtualBox (tested path — see 6.1 and
  docs/REHEARSAL-VIRTUALBOX.md)**, virt-manager/KVM, or GNOME Boxes. Free.
- Install a **stock Ubuntu, same major release** as your working machine, complete the
  first-boot setup. The first user must have sudo (the default user does).

### 6.4 Get the repo + config onto the VM

The Storage disk holds only `backup-*` snapshots (the mirror of `backups/`), **not** the
repo — bring the repo via git clone or a copy of the folder (same as section 2.2), then
restore the config from the newest snapshot (same as section 2.3).

In the VirtualBox rehearsal, the snapshot share appears at **`/media/sf_snapshots`**
(live `vboxsf` mount — see docs/REHEARSAL-VIRTUALBOX.md § 4–5 for wiring it up):

```bash
mkdir -p backups
newest=$(ls -1dr /media/sf_snapshots/backup-* | head -1)
cp -a "$newest/." backups/
```

Or skip the copy entirely and point restore at the snapshot directly:

```bash
newest=$(ls -1dr /media/sf_snapshots/backup-* | head -1)
./restore.sh --source "$newest" --dry-run     # preflight verifies the source manifest
./restore.sh --source "$newest" --yes
```

### 6.5 Preview

```bash
./restore.sh --dry-run
```

Read every app: expect `already installed (found '...')` only for things a stock Ubuntu
ships; everything else should print the exact typed-installer steps that will run
(`apt`/`snap`/`npm` installs, repo-key downloads + `apt_repository` setup, `.deb`/
tarball/script downloads with their checksum checks). Also confirm Phase 4 lists your
custom services and their unit files exist in `backups/services/<unit>/unit`.

### 6.6 Run the restore for real

Before running, confirm the VM's network + DNS are healthy (restore depends on `apt`,
`snap`, and `curl`): `ping -c 1 8.8.8.8`, `getent hosts api.snapcraft.io`, and
`getent hosts in.archive.ubuntu.com`. If DNS fails, use the **persistent** fix
(static `/etc/resolv.conf` pointing at `8.8.8.8`, disabling `systemd-resolved` if it
crashes) — a transient `nameserver` gets overwritten on reconnect/reboot and fails the
restore mid-run again (see docs/REHEARSAL-VIRTUALBOX.md § 6).

```bash
./restore.sh --yes
```

`yq` auto-installs on the fresh system, so no manual step is needed.

`--upgrade-base` (whole-OS apt upgrade) is a **separate, second-pass exercise** — run it
only after the plain restore succeeds, you've rebooted and verified, and networking is
stable:

```bash
./restore.sh --yes --upgrade-base
```

### 6.7 Reboot and verify

```bash
sudo reboot
# then, after logging back in:
code --version && gh --version && opencode --version
fish --version && terraform version && az version
systemctl status cloudflared.service        # your custom services
ls ~/.config/opencode                       # app config came back
ls ~/Documents                              # user dir came back
ls ~/.config/manicode/projects              # Freebuff per-project chat history came back
```

Also re-do the **section 5** manual steps here and confirm they work: Slack/OnlyOffice re-login,
`ollama pull <model>`, and `az extension add -n <name>` for any Azure CLI extensions — the
rehearsal is the right time to discover those need a working network/account, not later.

### 6.8 Idempotency check (the important one)

Run the restore a second time:

```bash
./restore.sh --yes
```

Everything should report `already installed` or skip; nothing should break, duplicate,
or error. This proves re-runs are safe (principle 6).

> Tools whose installer edits `~/.bashrc` to add its own `PATH` (e.g. `opencode`) only
> show up on `command -v` in a **fresh shell** — open a new terminal (or
> `source ~/.bashrc`) before judging a re-run, or it may re-run the installer.

### 6.9 What to do with failures

- A **`script`/`deb`/`tarball` installer** that fails prints a warning and restore
  **continues** — note which app, fix its `installer:` record in the inventory, re-run.
- A **hard failure** (apt/snap install error) aborts — fix the cause, re-run (idempotent).
- **Missing config?** Check the app declares `config_paths` in the inventory and that
  `backup.sh` captured it (the app appears under `backups/apps/<name>/`).

### 6.10 Done — delete the VM

The VM is disposable: shut it down and delete it. The point was to prove the mechanics
work. Keep this checklist in mind for the real restore — the real one just uses a newer
snapshot.

> **Why bother:** the restore path has never run on a fresh system — installers,
> idempotency, and config round-trips (including nested `user_dirs` like
> `~/.config/manicode/projects`) are only proven by a rehearsal. Fix any gaps in this
> repo while you are calm, not during a real emergency.

---

## 7. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `yq is required...` at the top | restore failed to auto-install yq (no snap + no curl?). Install it: `sudo snap install yq`, then re-run. |
| `Inventory schema validation needs python3 with the 'jsonschema' and 'yaml' modules` | restore could not auto-install the schema validator. Install it manually: `sudo apt-get install -y python3-jsonschema python3-yaml`, then re-run. |
| `Inventory failed schema validation` / `schema check FAILED` | `inventory.yaml` violates `inventory/schema.yaml` (wrong `schema_version`/`profile`, invalid package/unit/group/path, disallowed key for the install type...). Run `./inventory.sh validate` on your working machine, fix, re-run `backup.sh`, and bring a fresh snapshot. |
| `unsupported architecture` / `unsupported OS` | This repo hard-blocks platforms outside its declared matrix: Ubuntu on **AMD64 only** (`SUPPORTED_ARCHS` in `lib/common.sh`). The Ubuntu release is deliberately NOT locked — any Ubuntu release runs, and cross-release restores are flagged by the `--source` warning. |
| `No backups/ found — configuration cannot be restored` | You skipped step 2.3. Copy the newest snapshot into `backups/`, or just pass `--source "$newest"` (§ 2.3 alternative) and re-run. |
| `Backup content integrity check FAILED` | The snapshot's `SHA256SUMS` doesn't match its files — corruption, a partial copy, or tampering. Re-run `./backup.sh` and bring a fresh snapshot; use `--force-incomplete` only if you accept the risk. |
| `Backup manifest reports 'failed'` | A REQUIRED item (`required: true` / `on_missing: fail`) was missing at backup time. Fix the declared paths on your working machine and re-run `./backup.sh`; use `--force-incomplete` only if you accept the gap. |
| "Where did my pre-restore config go?" | Every overwrite is captured first into the rollback bundle `~/.local/state/backup-restore-ubuntu/rollback-<timestamp>/` (path printed at the end of the restore run; journal in `restore-journal.log`). Copy files back to undo, `rm -rf` the bundle once satisfied. |
| `Backup source not found: ...` | `--source` pointed at a nonexistent path, or at a mirror *root* (a folder of `backup-*` snapshots) instead of a single snapshot. Pass a snapshot directory that contains `backup-info.txt` (the error prints the newest snapshot to use). |
| `Backup was created on architecture '...' but this machine is '...'` | The `--source` snapshot was made on a different CPU architecture — restore refuses incompatible config by design. Make a backup on this machine's architecture and re-run. |
| `no unit file in backups/ — skipping` | The service's unit file wasn't captured. Run `./backup.sh` on your working machine, re-copy `backups/`, re-run. |
| `install script for '<app>' failed` / installer step errored | The typed installer failed (network, missing dep, checksum mismatch, key-fingerprint mismatch). Fix the cause, re-run; restore continues with other items. |
| `Temporary failure resolving ...` / DNS errors mid-restore | Network/DNS dropped. Make the DNS fix **persistent** — a transient `nameserver` gets overwritten on reconnect/reboot and the restore fails again mid-run: set `nameserver 8.8.8.8` in a static `/etc/resolv.conf` (or via the connection: `nmcli connection modify ... ipv4.dns "8.8.8.8 1.1.1.1" ipv4.ignore-auto-dns yes`); if `systemd-resolved` itself crashes, disable it and use the static file. Then re-run restore (idempotent). Don't power-cycle while apt is mid-transaction. |
| **"Authentication error" at the login screen before typing anything** | Interrupted package transaction — a restore died mid-apt and PAM/GDM is half-configured. Recovery: `Ctrl+Alt+F3` TTY → `sudo dpkg --configure -a` → `sudo apt-get install -f -y` → reboot. Prevent it by running restore from a TTY with the screen lock disabled (§ 4). |
| VM boots but D-Bus/polkit/GDM fail (no login) | Interrupted package transaction (network drop mid-restore + power-cycle). TTY recovery: `Ctrl+Alt+F3` → `sudo dpkg --configure -a` → `sudo apt-get install -f -y` (if this still fails on DNS/network, fix networking first, then re-run) → reboot. Never power-cycle mid-upgrade. |
| App installed but config looks missing | Its `config_paths` weren't declared in the inventory (or weren't captured). Declare them with `./inventory.sh` + `./backup.sh`, then re-run restore. |
| Not an Ubuntu system | restore warns and continues; this repo targets Ubuntu only. |

---

## 8. Safety notes

- `restore.sh` is **effectful** — it modifies the system. `--dry-run` previews it
  (`--dry-run` still auto-installs `yq` if missing, since the preview must read the
  inventory; nothing else is executed); `--yes` skips the confirmation. Default
  restore touches **only** declared items.
- `--upgrade-base` is the exception: it full-upgrades the entire base OS. Only use it when
  you intend that.
- `backups/` contains personal configuration and possible secrets — never commit it, and
  keep the mirror disk safe.
- If you restore onto a machine that already has some apps, restore detects them via
  `check_cmd` and **skips reinstalling** (still restores their config).
