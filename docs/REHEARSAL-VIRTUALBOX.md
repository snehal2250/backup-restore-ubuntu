# REHEARSAL-VIRTUALBOX.md — Rehearse the restore in a VirtualBox VM

This document is the **step-by-step, tested procedure** for replaying the full restore
path (docs/RESTORE.md § 2–§ 6) inside a disposable **VirtualBox** VM. It exists because
the generic runbook is hypervisor-agnostic, but the *mechanics* of getting a fresh system
up with VirtualBox are specific and were worked out once, on this machine.

> **When to use this:** you want to prove `restore.sh` works on a genuinely fresh system
> before you ever need a real restore. Do it once, calmly. Cost: ~1–2 hours + a few GB.
>
> **Why VirtualBox (not GNOME Boxes):** GNOME Boxes' built-in folder sharing is
> SPICE-WebDAV, which presents shared folders as a copy-like file-manager connection
> rather than a real live mount. VirtualBox's `vboxsf` shared folders are **real live
> mounts** inside the guest (`/media/sf_*`), always in sync with the host — no copying.
>
> **Why Oracle's VirtualBox 7.1.x (not the Ubuntu package):** Ubuntu's `virtualbox`
> 7.0.16 package fails to build its kernel module (`virtualbox-dkms`) on this machine's
> Ubuntu 24.04 HWE kernel 7.0 — the kernel exports KVM symbols under symbol namespaces
> (`kvm`, `kvm-amd`, `kvm-intel`) that VirtualBox 7.0.16 does not import, so `modpost`
> fails the build. Symptoms: no `/dev/vboxdrv`, no `vboxusers` group, apt left with
> half-configured (`iU`/`iF`) packages. Oracle's **7.1.x** includes the fix.

---

## 0. Preflight on the host (the real machine)

```bash
# 1. Hardware virtualization enabled in BIOS?
grep -c svm /proc/cpuinfo          # AMD: want a number > 0  (Intel: grep -c vmx)
```
If `0`: reboot → **Del** → Advanced (F2) → Tweaker/M.I.T. → Advanced CPU Settings →
**SVM Mode** → Enabled → F10. (AMD boards call it SVM, not VT-x.)

```bash
# 2. Ubuntu ISO present (same major release as your machine is ideal)
ls -lh ~/Downloads/*.iso
```

---

## 1. Install VirtualBox 7.1.x from Oracle's repo

```bash
# Oracle GPG key
wget -qO- https://www.virtualbox.org/download/oracle_vbox_2016.asc | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/oracle-virtualbox-2016.gpg

# Oracle repo for Ubuntu 24.04 (noble)
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/oracle-virtualbox-2016.gpg] \
https://download.virtualbox.org/virtualbox/debian noble contrib" | \
  sudo tee /etc/apt/sources.list.d/virtualbox.list

# Install 7.1.x (has the kernel 7.0 / KVM-namespace fix)
sudo apt-get update
sudo apt-get install -y virtualbox-7.1
```

Verify the kernel module + group:

```bash
ls -l /dev/vboxdrv                  # want: crw-rw---- 1 root vboxusers ...
getent group vboxusers              # want: vboxusers:x:...  (now exists)
sudo usermod -aG vboxusers $USER    # add yourself — then FULL reboot (a logout may not refresh GUI sessions)
```

> If `/dev/vboxdrv` is missing after install: `sudo dkms install virtualbox/7.1.x`
> (or `sudo dpkg --configure -a` to finish the package). If the build still fails, read
> the log: `tail -30 /var/lib/dkms/virtualbox/*/build/make.log`.

---

## 2. Create the VM (all commands — no GUI clicks needed)

```bash
# Create the empty VM
VBoxManage createvm --name "ubuntu-rehearsal" --ostype Ubuntu_64 --register
VBoxManage modifyvm "ubuntu-rehearsal" --memory 8192 --cpus 4 --vram 128 --ioapic on

# SATA controller + a brand-new EMPTY 40 GB disk
VBoxManage storagectl "ubuntu-rehearsal" --name "SATA" --add sata --controller IntelAhci
VBoxManage createmedium disk \
  --filename "$HOME/VirtualBox VMs/ubuntu-rehearsal/ubuntu-rehearsal.vdi" \
  --size 40960 --format VDI

# Attach the empty disk (port 0) AND the Ubuntu ISO as a DVD (port 1)
VBoxManage storageattach "ubuntu-rehearsal" --storagectl "SATA" --port 0 --device 0 \
  --type hdd --medium "$HOME/VirtualBox VMs/ubuntu-rehearsal/ubuntu-rehearsal.vdi"
VBoxManage storageattach "ubuntu-rehearsal" --storagectl "SATA" --port 1 --device 0 \
  --type dvddrive --medium "/home/vikram-athare/Downloads/ubuntu-26.04-desktop-amd64.iso"

# Power on — it boots the ISO's installer
VBoxManage startvm "ubuntu-rehearsal"
```

> **What this does (and doesn't):** these commands only build the virtual hardware.
> Ubuntu Desktop is installed by the ISO's **installer** inside the guest (see step 3).
> If you ever use the GUI wizard instead of these CLI commands and the guest-OS list only
> shows "32-bit", hardware virtualization is off in the BIOS — go back to step 0.

---

## 3. Install Ubuntu inside the VM

In the VM window:

1. **Try or Install Ubuntu** → **Install Ubuntu**
2. **Erase disk and install Ubuntu** (touches only the virtual 40 GB disk)
3. First user: **`vikram-athare`** with sudo (same username as the host, so `~/` paths
   line up with the runbook)
4. Finish → **Restart Now**

Then eject the ISO so future boots come from the disk:

```bash
VBoxManage storageattach "ubuntu-rehearsal" --storagectl "SATA" --port 1 --device 0 \
  --type dvddrive --medium emptydrive
```

> ⚠️ **Version note:** if your ISO is a newer major release than the host (e.g. 26.04 VM
> on a 24.04 host), the mechanics are identical but base packages/apt versions will be
> newer than a real restore would see. Best fidelity = same major release as the host.

---

## 4. Real shared folders (vboxsf — the whole point of using VirtualBox)

### 4a. Host side — declare the shares

```bash
VBoxManage sharedfolder add "ubuntu-rehearsal" --name "repo" \
  --hostpath "/home/vikram-athare/backup-restore-ubuntu" --automount
VBoxManage sharedfolder add "ubuntu-rehearsal" --name "snapshots" \
  --hostpath "/media/vikram-athare/Storage/backup-restore-ubuntu" --automount
```

(`--automount` makes them appear at `/media/sf_<name>` in the guest.)

### 4b. Guest side — Guest Additions (enables vboxsf)

```bash
# inside the VM:
sudo apt update
sudo apt install -y build-essential dkms perl tar bzip2 linux-headers-$(uname -r)
```

> `perl`, `tar`, and `bzip2` are the build prerequisites the installer demands —
> installing them up front avoids two known failures (see § 9).

Then in the VirtualBox menu: **Devices → Insert Guest Additions CD image**, and run:

```bash
sudo mount /dev/cdrom /mnt 2>/dev/null || sudo mount /dev/sr0 /mnt
sudo /mnt/VBoxLinuxAdditions.run
sudo usermod -aG vboxsf $USER     # grants access to shared folders
# FULL reboot — logout is NOT enough: /media/sf_* is root:vboxsf mode 770,
# so only group members can open it, and the GUI file manager keeps the
# pre-reboot session (and its denials) otherwise.
ls /media/sf_snapshots            # the Storage mirror — live-mounted, in sync
ls /media/sf_repo                 # the repo — live-mounted
```

That's it — real folders, no copying, no WebDAV. Guest Additions also give you a
properly sized display and clipboard sharing.

---

## 5. Get the repo + config onto the VM (runbook § 6.4)

The repo can come straight from GitHub (the VM has network), or from the share; the
**config snapshot** must come from the share:

```bash
# Repo — option A: clone from your remote
cd ~
git clone <your-remote> backup-restore-ubuntu
# Repo — option B: copy from the live share
cp -r /media/sf_repo ~/backup-restore-ubuntu

# Config — the newest snapshot's contents into backups/ (git-ignored folder):
cd ~/backup-restore-ubuntu
mkdir -p backups
newest=$(ls -1dr /media/sf_snapshots/backup-* | head -1)
cp -a "$newest/." backups/

# Confirm the marker BEFORE running restore:
tail -5 backups/backup-info.txt     # must show a 'status: ok' line
```

> `backups/` is git-ignored, so a fresh clone won't have it — copying the newest snapshot
> in is required or restore installs everything but skips config restoration.
>
> ⚠️ **Take the rollback snapshot AFTER this step.** The tested workflow is: § 5 copy
> (repo + config) → § 6 DNS fix + network gate → snapshot → restore. A snapshot taken
> before the repo/config copy rolls back to a VM that still needs § 5 redone (the clone
> made before § 5 in the first rehearsal lacked `~/backup-restore-ubuntu` entirely).

---

## 6. Preview, then run the restore (runbook § 6.5–6.6)

```bash
cd ~/backup-restore-ubuntu
./restore.sh --dry-run       # preview — only yq auto-installs if missing
```

Read every app: expect `already installed (found '...')` only for stock-Ubuntu items;
everything else prints the exact `apt`/`snap`/installer command that will run. Confirm
**Phase 4/5 services** lists `cloudflared` and its unit file exists in
`backups/services/cloudflared.service/unit`.

> `--dry-run` **auto-installs `yq`** just like a real run (a preview still needs to parse
> the inventory), so no manual step is needed. If the auto-install fails (no `snap`, no
> `curl`), install it yourself: `sudo snap install yq` and re-run the dry-run.

**Before the real run — confirm network + DNS in the guest** (restore depends on `apt`,
`snap`, and `curl` reaching their repos; a dead resolver fails every install):

```bash
ping -c 1 -W 2 8.8.8.8              # network reachable?
getent hosts api.snapcraft.io        # DNS resolves?
getent hosts in.archive.ubuntu.com
```

If DNS fails, the reliable fix is to **bypass the VirtualBox NAT DNS proxy entirely and
make it persistent** — the rehearsal proved the NAT DNS proxy breaks on hosts whose own
DNS goes through Tailscale/MagicDNS or other non-standard resolvers, and a transient
`resolvectl`/`resolv.conf` fix gets overwritten on reconnect or reboot, failing the
restore mid-run:

```bash
# 1. Make the override permanent (survives reboots/reconnects):
sudo nmcli connection modify "Wired connection 1" ipv4.dns "8.8.8.8 1.1.1.1" ipv4.ignore-auto-dns yes
sudo nmcli connection up "Wired connection 1"

# 2. If systemd-resolved is still flaky/crashes mid-restore, remove the stub entirely:
sudo systemctl disable --now systemd-resolved
sudo rm -f /etc/resolv.conf
echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee /etc/resolv.conf

# 3. Verify with the REAL gate — apt must fully succeed:
getent hosts archive.ubuntu.com
sudo apt-get update        # must complete without "Temporary failure resolving"
```

Host-side fallback for flaky NAT DNS: power off the VM,
`VBoxManage modifyvm "ubuntu-rehearsal" --natdnshostresolver1 on`, then power back on.
> ⚠️ Tested 2026-08-02: this did **not** fix DNS on a host whose resolver goes through
> Tailscale MagicDNS — the guest-side persistent fix above is the reliable one; try this
> only if the guest-side fix is somehow unavailable.

**Before the real run — harden the session (a locked GUI screen mid-restore corrupts the
package state; this was the #1 rehearsal failure):**

```bash
# 1. Snapshot the clean VM first — one-command rollback if anything goes wrong:
VBoxManage snapshot "ubuntu-rehearsal" take "pre-restore-network-ok" \
  --description "clean, network verified, before restore"

# 2. Disable the screen lock so a 20–30 min restore can't be interrupted:
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.desktop.screensaver lock-enabled false

# 3. Run the restore from a TTY (Ctrl+Alt+F3) — the GUI session is out of the picture —
#    and tee the full output to a log so failures are diagnosable:
cd ~/backup-restore-ubuntu
./restore.sh --yes 2>&1 | tee ~/restore.log
```

> **Never power-cycle mid-restore.** A hard power-off during an apt transaction leaves
> dpkg half-configured (D-Bus/polkit/GDM fail on the next boot). If it breaks anyway:
> restore the snapshot (`VBoxManage snapshot "ubuntu-rehearsal" restore
> "pre-restore-network-ok"`), re-apply the DNS fix, re-run — the restore is idempotent.

`--upgrade-base` is a **separate, second-pass exercise** — only after the plain restore
succeeds, you've rebooted and verified, and networking is stable:

```bash
./restore.sh --yes --upgrade-base
```

---

## 7. Reboot, verify, prove idempotency (runbook § 6.7–6.8)

```bash
sudo reboot
# after logging back in:
code --version && gh --version && opencode --version
fish --version && terraform version && az version
systemctl status cloudflared.service        # your custom services
ls ~/.config/opencode                       # app config came back
ls ~/Documents                              # user dir came back
ls ~/.config/manicode/projects              # Freebuff per-project chat history came back
```

Also re-do the **section 5 manual steps** here: Slack/OnlyOffice re-login,
`ollama pull <model>`, `az extension add -n azure-devops`.

**Idempotency check — run restore a second time:**

```bash
./restore.sh --yes
```

Everything should report `already installed` or skip; nothing should error or duplicate.

> **New shell before judging idempotency:** tools whose installer edits `~/.bashrc` to add
> its own `PATH` (e.g. `opencode`) only show up on `command -v` in a **fresh shell**. If a
> re-run reinstalls such a tool, open a new terminal (or `source ~/.bashrc`) first — the
> re-run was only triggered because the old shell couldn't see the freshly added binary.

---

## 8. Clean up the VM when done

```bash
VBoxManage controlvm "ubuntu-rehearsal" poweroff     # if still running
VBoxManage unregistervm "ubuntu-rehearsal" --delete  # delete VM + its VDI
```

The point was to prove the mechanics. The real restore (docs/RESTORE.md) is the same
path, just on real hardware with a newer snapshot.

---

## 9. Troubleshooting (VirtualBox-specific)

| Symptom | Cause / fix |
| --- | --- |
| Guest OS list only shows "32-bit" | Hardware virtualization off in BIOS — enable SVM/VT-x (step 0) |
| `/dev/vboxdrv` missing after install | `sudo dpkg --configure -a`; if still missing, `sudo dkms install virtualbox/7.1.x`; check `/var/lib/dkms/virtualbox/*/build/make.log` |
| `/media/sf_*` not visible in guest | Guest Additions not installed (step 4b), or you're not in `vboxsf` — `sudo usermod -aG vboxsf $USER` then **full reboot** |
| Shared folder mounted but **permission denied** when opening | First disambiguate: `mount \| grep vboxsf` — if nothing prints, it isn't actually mounted (re-add the share after a VM restart). If it IS mounted, `/media/sf_*` is `root:vboxsf` mode `770` — only group members can read it. `sudo usermod -aG vboxsf $USER`, then **full reboot** (logout alone is not enough; Nautilus also caches the denial — close and reopen Files). Instant test without rebooting: `newgrp vboxsf` |
| Guest Additions asks to install `bzip2`/`tar` | Expected — the installer needs them to unpack its kernel-module sources. `sudo apt install -y tar bzip2` and re-run `/mnt/VBoxLinuxAdditions.run` |
| Guest Additions: `make: not found` / "system is not currently set up to build kernel modules" | Build toolchain missing — `sudo apt install -y build-essential perl linux-headers-$(uname -r)`, then re-run `/mnt/VBoxLinuxAdditions.run`. The later "cannot reload kernel modules: one or more module(s) is still in use" line is **normal** — reboot to load the new modules |
| Shared folder appears but empty | Share was added while the VM ran; `VBoxManage sharedfolder remove` + re-`add` after a VM restart |
| `yq is required...` on dry-run | The auto-install failed (no `snap` and no `curl` on the VM). Install it: `sudo snap install yq`, then re-run the dry-run |
| Restore fails with `Temporary failure resolving ...` / DNS errors | Guest DNS is down. This recurs if the fix is transient — make it persistent (see § 6): `nmcli connection modify ... ipv4.dns "8.8.8.8 1.1.1.1" ipv4.ignore-auto-dns yes`; if systemd-resolved crashes mid-run, `sudo systemctl disable --now systemd-resolved` + static `/etc/resolv.conf`. Then re-run restore (idempotent) |
| **"Authentication error" on the login screen before typing anything** | Interrupted package transaction — a restore died mid-apt and PAM/GDM is half-configured. Recovery: `Ctrl+Alt+F3` TTY → `sudo dpkg --configure -a` → `sudo apt-get install -f -y` → `sudo reboot`. Prevent it: disable the screen lock and run restore from a TTY (see § 6) |
| **Bridged networking gives the VM no IP** | USB WiFi adapters often don't support VirtualBox bridged pass-through. Stay on NAT and fix DNS at the guest level (§ 6) instead |
| VM boots but **D-Bus / polkit / GDM fail** (no login screen) | Same interrupted package transaction as the authentication-error row above — same TTY recovery (`Ctrl+Alt+F3` → `sudo dpkg --configure -a` → `sudo apt-get install -f -y` → `sudo reboot`; fix DNS/network first if those still fail). **Never power-cycle mid-upgrade** — wait for the prompt to return. A broken rehearsal VM does **not** mean the repo or snapshot is damaged |
| VM boots to a black screen after install | The ISO wasn't ejected — re-attach `emptydrive` (step 3) and reboot |
