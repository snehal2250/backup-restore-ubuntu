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
sudo usermod -aG vboxusers $USER    # add yourself — then LOG OUT & back in
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
sudo apt install -y build-essential dkms linux-headers-$(uname -r)
```

Then in the VirtualBox menu: **Devices → Insert Guest Additions CD image**, and run:

```bash
sudo mount /dev/cdrom /mnt 2>/dev/null || sudo mount /dev/sr0 /mnt
sudo /mnt/VBoxLinuxAdditions.run
sudo usermod -aG vboxsf $USER     # grants access to shared folders
# LOG OUT & back in, then:
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

---

## 6. Preview, then run the restore (runbook § 6.5–6.6)

```bash
cd ~/backup-restore-ubuntu
./restore.sh --dry-run       # preview — execute nothing
```

Read every app: expect `already installed (found '...')` only for stock-Ubuntu items;
everything else prints the exact `apt`/`snap`/installer command that will run. Confirm
**Phase 4/5 services** lists `cloudflared` and its unit file exists in
`backups/services/cloudflared.service/unit`.

> `--dry-run` does **not** auto-install `yq` (by design). If it complains, run
> `sudo snap install yq` then re-run the dry-run. A real run auto-installs yq itself.

Then the real thing:

```bash
./restore.sh --yes
# optional, to also test a full base-OS upgrade:
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
| `/media/sf_*` not visible in guest | Guest Additions not installed (step 4b), or you're not in `vboxsf` — `sudo usermod -aG vboxsf $USER` then log out/in |
| Shared folder appears but empty | Share was added while the VM ran; `VBoxManage sharedfolder remove` + re-`add` after a VM restart |
| `yq is required...` on dry-run | Expected — `--dry-run` never modifies the system. `sudo snap install yq` and re-run, or just run the real `./restore.sh --yes` |
| VM boots to a black screen after install | The ISO wasn't ejected — re-attach `emptydrive` (step 3) and reboot |
