#!/bin/bash
set -euo pipefail

if [ -z "$HOME" ]; then
  echo "ERROR: HOME is not set"
  exit 1
fi

export PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backup"
mkdir -p "$BACKUP_DIR"/{apt,services,snap,vscode,configs,dotfiles,apps}

CODE_CMD=""
for candidate in /snap/bin/code /usr/bin/code /usr/local/bin/code; do
  if [ -x "$candidate" ]; then
    CODE_CMD="$candidate"
    break
  fi
done

echo "Saving apt package selections..."
dpkg --get-selections > "$BACKUP_DIR/apt/package-selections.txt"
dpkg-query -W -f='${Package}\n' > "$BACKUP_DIR/apt/package-list.txt"

echo "Saving apt sources..."
sudo mkdir -p "$BACKUP_DIR/apt/sources.list.d"
sudo cp -r /etc/apt/sources.list "$BACKUP_DIR/apt/sources.list"
sudo cp -r /etc/apt/sources.list.d/* "$BACKUP_DIR/apt/sources.list.d/" 2>/dev/null || true
sudo mkdir -p "$BACKUP_DIR/apt/trusted.gpg.d"
sudo cp -r /etc/apt/trusted.gpg.d/* "$BACKUP_DIR/apt/trusted.gpg.d/" 2>/dev/null || true
sudo mkdir -p "$BACKUP_DIR/apt/keyrings"
sudo cp -r /etc/apt/keyrings/* "$BACKUP_DIR/apt/keyrings/" 2>/dev/null || true

echo "Saving snap package list..."
snap list --all | awk 'NR>1 {notes=""; for (i=6; i<=NF; i++) { notes = notes $i (i<NF ? " " : "") } print $1 "\t" notes}' > "$BACKUP_DIR/snap/snap-list.txt"

if command -v flatpak >/dev/null 2>&1; then
  echo "Saving flatpak application list..."
  flatpak list --app --columns=application > "$BACKUP_DIR/snap/flatpak-list.txt"
fi

echo "Saving VS Code extensions..."
if [ -n "$CODE_CMD" ] && [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
  "$CODE_CMD" --list-extensions > "$BACKUP_DIR/vscode/extensions.txt" 2>/dev/null || true
  if [ ! -s "$BACKUP_DIR/vscode/extensions.txt" ]; then
    echo "VS Code extension backup produced no output."
  fi
else
  echo "code command not found or HOME unavailable; skipping VS Code extension backup."
fi

echo "Backing up configs..."
rsync -a "$HOME/.config/" "$BACKUP_DIR/configs/config/" 2>/dev/null || true
rsync -a "$HOME/.ssh/" "$BACKUP_DIR/configs/ssh/" 2>/dev/null || true
[ -f "$HOME/.gitconfig" ] && cp "$HOME/.gitconfig" "$BACKUP_DIR/configs/.gitconfig"
rsync -a "$HOME/.local/share/code/" "$BACKUP_DIR/configs/local-share-code/" 2>/dev/null || true
rsync -a "$HOME/.local/share/applications/" "$BACKUP_DIR/configs/local-share-applications/" 2>/dev/null || true

echo "Backing up dotfiles..."
for dotfile in .bashrc .profile .bash_aliases .bash_functions .zshrc .inputrc; do
  if [ -e "$HOME/$dotfile" ]; then
    cp -r "$HOME/$dotfile" "$BACKUP_DIR/dotfiles/"
  fi
done

echo "Backing up custom services..."
sudo mkdir -p "$BACKUP_DIR/services/systemd"
sudo cp -r /etc/systemd/system "$BACKUP_DIR/services/systemd/" 2>/dev/null || true
systemctl list-unit-files --type=service --state=enabled --no-legend | awk '{print $1}' > "$BACKUP_DIR/services/enabled-services.txt"

echo "Backing up application files..."
rsync -a "$HOME/.vscode/" "$BACKUP_DIR/apps/vscode/" 2>/dev/null || true
mkdir -p "$BACKUP_DIR/apps/package-json/home"
find "$HOME/.config" "$HOME/.vscode" 2>/dev/null -type f -name package.json | while IFS= read -r file; do
  dest="$BACKUP_DIR/apps/package-json/home${file#$HOME}"
  mkdir -p "$(dirname "$dest")"
  cp "$file" "$dest"
done

if [ -d /opt ]; then
  echo "Backing up /opt application directories..."
  sudo tar -czf "$BACKUP_DIR/apps/opt.tar.gz" -C /opt .
  mkdir -p "$BACKUP_DIR/apps/package-json/opt"
  find /opt -type f -name package.json 2>/dev/null | while IFS= read -r file; do
    dest="$BACKUP_DIR/apps/package-json${file}"
    mkdir -p "$(dirname "$dest")"
    sudo cp "$file" "$dest"
  done
fi

if [ -d /usr/local ]; then
  echo "Backing up /usr/local application directories..."
  sudo tar -czf "$BACKUP_DIR/apps/usr-local.tar.gz" -C /usr/local .
fi

echo "Backup complete."
