#!/bin/bash
set -euo pipefail

if [ -z "$HOME" ]; then
  echo "ERROR: HOME is not set"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$SCRIPT_DIR/backup"
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Backup directory $BACKUP_DIR not found."
  exit 1
fi

echo "Restoring apt sources..."
if [ -f "$BACKUP_DIR/apt/sources.list" ]; then
  sudo cp "$BACKUP_DIR/apt/sources.list" /etc/apt/sources.list
  sudo rm -rf /etc/apt/sources.list.d
  sudo mkdir -p /etc/apt/sources.list.d
  sudo cp -r "$BACKUP_DIR/apt/sources.list.d/"* /etc/apt/sources.list.d/ 2>/dev/null || true
  sudo rm -rf /etc/apt/trusted.gpg.d
  sudo mkdir -p /etc/apt/trusted.gpg.d
  sudo cp -r "$BACKUP_DIR/apt/trusted.gpg.d/"* /etc/apt/trusted.gpg.d/ 2>/dev/null || true
  sudo rm -rf /etc/apt/keyrings
  sudo mkdir -p /etc/apt/keyrings
  sudo cp -r "$BACKUP_DIR/apt/keyrings/"* /etc/apt/keyrings/ 2>/dev/null || true
fi

echo "Updating apt metadata..."
sudo apt-get update

if [ -f "$BACKUP_DIR/apt/package-selections.txt" ]; then
  echo "Restoring apt package selections..."
  sudo dpkg --set-selections < "$BACKUP_DIR/apt/package-selections.txt"
  sudo apt-get -y dselect-upgrade
fi

if [ -f "$BACKUP_DIR/snap/snap-list.txt" ] && command -v snap >/dev/null 2>&1; then
  echo "Restoring snap packages..."
  while IFS=$'\t' read -r pkg notes; do
    [ -z "$pkg" ] && continue
    if [[ "$pkg" == "Name" ]]; then
      continue
    fi
    if snap list "$pkg" >/dev/null 2>&1; then
      echo "Snap $pkg already installed"
      continue
    fi
    if [[ "$notes" == *classic* ]]; then
      sudo snap install --classic "$pkg" || true
    else
      sudo snap install "$pkg" || true
    fi
  done < "$BACKUP_DIR/snap/snap-list.txt"
fi

if [ -f "$BACKUP_DIR/snap/flatpak-list.txt" ] && command -v flatpak >/dev/null 2>&1; then
  echo "Restoring flatpak applications..."
  while read -r app; do
    [ -z "$app" ] && continue
    flatpak install -y "$app" || true
  done < "$BACKUP_DIR/snap/flatpak-list.txt"
fi

if [ -f "$BACKUP_DIR/vscode/extensions.txt" ] && command -v code >/dev/null 2>&1; then
  echo "Restoring VS Code extensions..."
  while read -r ext; do
    [ -z "$ext" ] && continue
    code --install-extension "$ext" || true
  done < "$BACKUP_DIR/vscode/extensions.txt"
fi

echo "Restoring configs..."
rsync -a "$BACKUP_DIR/configs/config/" "$HOME/.config/" 2>/dev/null || true
rsync -a "$BACKUP_DIR/configs/ssh/" "$HOME/.ssh/" 2>/dev/null || true
[ -f "$BACKUP_DIR/configs/.gitconfig" ] && cp "$BACKUP_DIR/configs/.gitconfig" "$HOME/"
rsync -a "$BACKUP_DIR/configs/local-share-code/" "$HOME/.local/share/code/" 2>/dev/null || true
rsync -a "$BACKUP_DIR/configs/local-share-applications/" "$HOME/.local/share/applications/" 2>/dev/null || true

echo "Restoring dotfiles..."
for dotfile in .bashrc .profile .bash_aliases .bash_functions .zshrc .inputrc; do
  if [ -f "$BACKUP_DIR/dotfiles/$dotfile" ] || [ -d "$BACKUP_DIR/dotfiles/$dotfile" ]; then
    cp -r "$BACKUP_DIR/dotfiles/$dotfile" "$HOME/"
  fi
done

if [ -d "$BACKUP_DIR/services/systemd/system" ]; then
  echo "Restoring custom services..."
  sudo cp -r "$BACKUP_DIR/services/systemd/system/"* /etc/systemd/system/ 2>/dev/null || true
  sudo systemctl daemon-reload
  if [ -f "$BACKUP_DIR/services/enabled-services.txt" ]; then
    while read -r service; do
      [ -z "$service" ] && continue
      sudo systemctl enable --now "$service" || true
    done < "$BACKUP_DIR/services/enabled-services.txt"
  fi
fi

if [ -f "$BACKUP_DIR/apps/opt.tar.gz" ]; then
  echo "Restoring /opt application directories..."
  sudo mkdir -p /opt
  sudo tar -xzf "$BACKUP_DIR/apps/opt.tar.gz" -C /opt
fi

if [ -f "$BACKUP_DIR/apps/usr-local.tar.gz" ]; then
  echo "Restoring /usr/local application directories..."
  sudo tar -xzf "$BACKUP_DIR/apps/usr-local.tar.gz" -C /usr/local
fi

if [ -d "$BACKUP_DIR/apps/package-json" ]; then
  echo "Restoring saved package.json files..."
  find "$BACKUP_DIR/apps/package-json" -type f | while read -r file; do
    rel_path="${file#$BACKUP_DIR/apps/package-json/}"
    if [[ "$rel_path" == home/* ]]; then
      dest="$HOME/${rel_path#home/}"
    else
      dest="/$rel_path"
    fi
    mkdir -p "$(dirname "$dest")"
    sudo cp "$file" "$dest"
  done
fi

echo "Restore complete. Review output and reboot when ready."
