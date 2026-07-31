#!/bin/bash
# ---------------------------------------------------------------------------
# backup.sh — capture the CONFIGURATION of everything declared in
# inventory/inventory.yaml into the git-ignored backups/ folder.
#
# What is captured (and nothing else):
#   * config_paths of every declared app        (mirrored under backups/apps/<name>/)
#   * unit file + config_paths of every service (backups/services/<unit>/unit + /home + /root)
#   * declared dotfiles                         (backups/dotfiles/<name>)
#   * declared user dirs (e.g. ~/Documents)     (backups/user-dirs/<name>/ — whole folders)
#
# Safe to run anytime. Output: backups/ (git-ignored) + backups/backup-info.txt
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

YQ_AUTO=2   # interactive tool: if yq is missing, ask the user to install it

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq "$YQ_AUTO"

mkdir -p "$BACKUPS_DIR"/{apps,services,dotfiles,user-dirs}

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
      rel="${src#"$HOME"/}"
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
      rel="${csrc#"$HOME"/}"
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

# --- User dirs: capture whole declared data folders (e.g. ~/Documents) -----
while IFS= read -r d; do
  [ -n "$d" ] || continue
  src="$(expand_path "$d")"
  if [ ! -d "$src" ]; then
    warn "User dir not found: $d"
    continue
  fi
  if [ "$src" = "$HOME" ]; then
    warn "  skip (\$HOME itself cannot be a user dir): $d"
    continue
  fi
  case "$src" in
    "$HOME"/*) : ;;
    *) warn "  skip (user_dirs must live under \$HOME): $d" ; continue ;;
  esac
  rel="${src#"$HOME"/}"
  ( cd "$HOME" && rsync -aR "./$rel" "$BACKUPS_DIR/user-dirs/" )
  ok "  $d -> backups/user-dirs/"
done < <(yaml_list '.user_dirs[]')

# --- Mirror to the configurable local-disk destination ----------------------
# BACKUP_DEST (env-overridable) receives a full, unfiltered copy of backups/.
# Only the newest $BACKUP_KEEP snapshots are kept there (rotation).
mirror_backup() {
  MIRROR_STATUS="disabled"
  [ -n "$BACKUP_DEST" ] || { info "BACKUP_DEST is empty — skipping local mirror."; return 0; }
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || BACKUP_KEEP=5
  if [ ! -d "$BACKUP_DEST" ]; then
    mkdir -p "$BACKUP_DEST" 2>/dev/null || { warn "Cannot create $BACKUP_DEST — skipping mirror."; MIRROR_STATUS="failed"; return 0; }
  fi
  # %N (nanoseconds) avoids two same-second runs colliding into one snapshot dir.
  local snap old
  snap="$BACKUP_DEST/backup-$(date +%Y%m%d-%H%M%S%N)"
  info "Mirroring backups/ -> $snap (no filtering)"
  # --no-o --no-g: the destination may be NTFS/FAT where chown fails (rsync exit 23).
  if ! rsync -a --no-o --no-g "$BACKUPS_DIR/" "$snap/"; then
    warn "Mirror to $snap failed — keeping backups/ only."
    MIRROR_STATUS="failed"
    return 0
  fi
  MIRROR_STATUS="ok"
  ok "Mirrored to $snap"
  # Rotation: keep the newest $BACKUP_KEEP snapshots. Names are zero-padded
  # timestamps, so -r (descending) lexicographic order IS newest-first
  # chronological order — never sort by mtime (-t), which is unreliable when
  # snapshots share a creation second. Slicing [@]:$BACKUP_KEEP then drops the
  # newest KEEP and prunes the rest (the OLDER snapshots).
  local -a old_snaps=()
  while IFS= read -r old; do
    [ -n "$old" ] && old_snaps+=("$old")
  done < <(ls -1dr "$BACKUP_DEST"/backup-* 2>/dev/null)
  # Remember the newest snapshot (old_snaps[0], the one we just created) so the
  # success-marker refresh below can reuse it instead of re-listing the dir.
  MIRROR_NEWEST="${old_snaps[0]:-}"
  if [ "${#old_snaps[@]}" -gt "$BACKUP_KEEP" ]; then
    local prune
    for prune in "${old_snaps[@]:$BACKUP_KEEP}"; do
      rm -rf "$prune"
      warn "Pruned old snapshot: $prune"
    done
  fi
}

mirror_backup

# --- Success marker ----------------------------------------------------------
# backup-info.txt is (re)written at the START of a run, so on its own it cannot
# prove the run COMPLETED. This block is appended only when the whole run
# finished (captures + mirror). Therefore:
#   * 'status: ok' present  -> the last run completed successfully
#   * 'status: ok' absent   -> the last run did NOT complete (aborted mid-way)
# The newest mirror snapshot gets the same file so the off-machine copy can be
# verified identically (cp guarded so a failed mirror never clobbers an older
# good snapshot's info).
{
  echo "status: ok"
  echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mirror: ${MIRROR_STATUS:-unknown}"
} >> "$BACKUPS_DIR/backup-info.txt"
if [ "${MIRROR_STATUS:-}" = "ok" ] && [ -n "${MIRROR_NEWEST:-}" ]; then
  cp "$BACKUPS_DIR/backup-info.txt" "$MIRROR_NEWEST/backup-info.txt"
fi

echo
ok "Backup complete."
echo "backups/ is git-ignored. Mirror status above — BACKUP_DEST=${BACKUP_DEST:-<disabled>},"
echo "keeping the last ${BACKUP_KEEP} snapshot(s)."
