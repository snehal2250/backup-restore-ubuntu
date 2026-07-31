#!/bin/bash
# ---------------------------------------------------------------------------
# backup.sh — capture the CONFIGURATION of everything declared in
# inventory/inventory.yaml into the git-ignored backups/ folder.
#
# What is captured (and nothing else):
#   * config_paths of every declared app        (mirrored under backups/apps/<name>/)
#   * unit file + config_paths of every service (backups/services/<unit>/unit + /home + /root)
#   * declared dotfiles                         (backups/dotfiles/<name>)
#
# Safe to run anytime. Output: backups/ (git-ignored) + backups/backup-info.txt
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

YQ_AUTO=2   # interactive tool: if yq is missing, ask the user to install it

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq

mkdir -p "$BACKUPS_DIR"/{apps,services,dotfiles}

{
  echo "host: $(hostname)"
  echo "user: $USER"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repo: $REPO_ROOT"
  git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null | sed 's/^/git_commit: /' || true
} > "$BACKUPS_DIR/backup-info.txt"
ok "Backup info written to backups/backup-info.txt"

# --- Apps: capture declared config paths ---------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  dest="$BACKUPS_DIR/apps/$name"
  mkdir -p "$dest/home" "$dest/root"
  info "Backing up config for app: $name"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    src="$(expand_path "$p")"
    if [ ! -e "$src" ]; then
      warn "  skip (path not found): $p"
      continue
    fi
    if [[ "$src" == "$HOME"* ]]; then
      rel="${src#$HOME/}"
      ( cd "$HOME" && rsync -aR "./$rel" "$dest/home/" )
    else
      ( cd / && rsync -aR "./${src#/}" "$dest/root/" )
    fi
    ok "  $p -> backups/apps/$name/"
  done < <(yq -r ".apps[] | select(.name == \"$name\") | .config_paths[]?" "$INVENTORY_FILE")
done < <(yaml_list '.apps[] | .name')

# --- Services: capture declared unit files + config paths ------------------
while IFS=$'\t' read -r unit target; do
  [ -n "$unit" ] || continue
  sdest="$BACKUPS_DIR/services/$unit"
  # Remove a stale unit-file-from-old-layout at this path so mkdir can proceed.
  [ -f "$sdest" ] && rm -f "$sdest"
  mkdir -p "$sdest"
  if [ "$target" = "user" ]; then
    src="$HOME/.config/systemd/user/$unit"
  else
    src="/etc/systemd/system/$unit"
  fi
  if [ -f "$src" ]; then
    cp "$src" "$sdest/unit"
    ok "Service unit backed up: $unit"
  else
    warn "Service unit not found at $src — will not be restorable."
  fi
  # Config files the service needs (env file, config dir, helper script, ...).
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    csrc="$(expand_path "$p")"
    if [ ! -e "$csrc" ]; then
      warn "  $unit: skip (path not found): $p"
      continue
    fi
    mkdir -p "$sdest/home" "$sdest/root"
    if [[ "$csrc" == "$HOME"* ]]; then
      rel="${csrc#$HOME/}"
      ( cd "$HOME" && rsync -aR "./$rel" "$sdest/home/" )
    else
      ( cd / && rsync -aR "./${csrc#/}" "$sdest/root/" )
    fi
    ok "  $unit: $p -> backups/services/$unit/"
  done < <(yq -r ".services[] | select(.unit == \"$unit\") | .config_paths[]?" "$INVENTORY_FILE")
done < <(yq -r '.services[] | [.unit, (.target // "system")] | @tsv' "$INVENTORY_FILE")

# --- Dotfiles --------------------------------------------------------------
while IFS= read -r df; do
  [ -n "$df" ] || continue
  if [ -f "$HOME/$df" ]; then
    cp "$HOME/$df" "$BACKUPS_DIR/dotfiles/$df"
    ok "Dotfile backed up: $df"
  else
    warn "Dotfile missing: $df"
  fi
done < <(yaml_list '.dotfiles[]')

echo
ok "Backup complete."
echo "backups/ is git-ignored — copy it to safe storage (USB / another machine) to make"
echo "restore.sh able to bring back your configuration on a fresh system."
