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

### 6.1 Pre-rehearsal hardware checklist (run once, on the real machine)

The rehearsal creates a real VM, so the machine that runs it needs a working hypervisor
with hardware acceleration. Do this **once** on the working machine (not inside a
prep/CI environment — the VM needs your actual hardware):

**1. Install a hypervisor.** VirtualBox is the recommended option for this rehearsal:

```bash
sudo apt-get update
sudo apt-get install -y virtualbox virtualbox-ext-pack virtualbox-dkms
# alternatives (any hypervisor works — the repo is hypervisor-agnostic):
#   sudo apt-get install -y gnome-boxes
#   sudo apt-get install -y qemu-kvm libvirt-daemon-system virt-manager
```

> `virtualbox-dkms` rebuilds the `vboxdrv` module automatically on kernel updates —
> without it, VirtualBox can stop working after a kernel upgrade.

**2. Enable hardware virtualization in the BIOS.** The setting is named **SVM Mode** on
AMD boards (this machine: Gigabyte B550M K) or **Intel VT-x** on Intel. It is off by
default on many boards, and no hypervisor gets hardware acceleration until it is on:

- Reboot and tap **Del** to enter the BIOS; switch to Advanced mode with **F2**;
  **Tweaker/M.I.T. → Advanced CPU Settings → SVM Mode → Enabled**; save with **F10**.
- If acceleration still does not work after that, also disable **Secure Boot** and/or
  load the module manually: VirtualBox → `sudo modprobe vboxdrv`; KVM →
  `sudo modprobe kvm_amd` (Intel: `kvm_intel`).

**3. Verify acceleration is live** (after rebooting back into Ubuntu):

```bash
# VirtualBox (recommended) — uses its OWN kernel module, NOT /dev/kvm:
lsmod | grep vboxdrv                     # expect: vboxdrv ...
sudo usermod -aG vboxusers "$USER"       # then log out/in once for it to apply
# KVM/Boxes instead — expect /dev/kvm to exist:
#   ls -l /dev/kvm                       # expect: crw-rw---- 1 root kvm ...
#   sudo systemctl enable --now libvirtd
#   sudo usermod -aG libvirt "$USER"
```

> **Why this matters:** without hardware acceleration (SVM/AMD-V), the hypervisor falls
> back to slow software emulation — the rehearsal still works but can take 20–40× longer.
> Get acceleration working before you start.

### 6.2 Make a fresh backup on your working machine first

```bash
./backup.sh
tail -5 backups/backup-info.txt        # must show a 'status: ok' line
```
Use this newest snapshot as the rehearsal's config source.

### 6.3 Create the disposable VM

- Any local hypervisor: GNOME Boxes, VirtualBox, or virt-manager/KVM. Free.
- Install a **stock Ubuntu, same major release** as your working machine, complete the
  first-boot setup. The first user must have sudo (the default user does).

### 6.4 Get the repo + config onto the VM

The Storage disk holds only `backup-*` snapshots (the mirror of `backups/`), **not** the
repo — bring the repo via git clone or a copy of the folder (same as section 2.2), then
restore the config from the newest snapshot (same as section 2.3):

```bash
mkdir -p backups
newest=$(ls -1dr /media/vikram-athare/Storage/backup-restore-ubuntu/backup-* | head -1)
cp -a "$newest/." backups/
```

### 6.5 Preview

```bash
./restore.sh --dry-run
```

Read every app: expect `already installed (found '...')` only for things a stock Ubuntu
ships; everything else should print the exact `apt`/`snap`/`npm`/installer command that
will run. Also confirm Phase 4 lists your custom services and their unit files exist in
`backups/services/<unit>/unit`.

### 6.6 Run the restore for real

```bash
./restore.sh --yes
# optionally, to also test a full base OS upgrade:
./restore.sh --yes --upgrade-base
```

`yq` auto-installs on the fresh system, so no manual step is needed.

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

### 6.9 What to do with failures

- A **custom/script installer** that fails prints a warning and restore **continues** —
  note which app, fix its `install_command` in the inventory, re-run.
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
| `No backups/ found — configuration cannot be restored` | You skipped step 2.3. Copy the newest snapshot into `backups/` and re-run. |
| `no unit file in backups/ — skipping` | The service's unit file wasn't captured. Run `./backup.sh` on your working machine, re-copy `backups/`, re-run. |
| `install command for '<app>' failed` | The official installer errored (network, missing dep). Fix the cause, re-run; restore continues with other items. |
| App installed but config looks missing | Its `config_paths` weren't declared in the inventory (or weren't captured). Declare them with `./inventory.sh` + `./backup.sh`, then re-run restore. |
| Not an Ubuntu system | restore warns and continues; this repo targets Ubuntu only. |

---

## 8. Safety notes

- `restore.sh` is **effectful** — it modifies the system. `--dry-run` previews it;
  `--yes` skips the confirmation. Default restore touches **only** declared items.
- `--upgrade-base` is the exception: it full-upgrades the entire base OS. Only use it when
  you intend that.
- `backups/` contains personal configuration and possible secrets — never commit it, and
  keep the mirror disk safe.
- If you restore onto a machine that already has some apps, restore detects them via
  `check_cmd` and **skips reinstalling** (still restores their config).
