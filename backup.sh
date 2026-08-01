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

# Capture run metadata at start; written to backup-info.txt only on COMPLETION.
# No file exists during a run — a missing or status-absent file means the last
# run did not complete (or no run has ever succeeded).
BACKUP_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BACKUP_HOST="$(hostname)"
BACKUP_USER="$USER"
BACKUP_REPO="$REPO_ROOT"
GIT_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"

# --- Apps: capture declared config paths ---------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  dest="$BACKUPS_DIR/apps/$name"
  # Fresh capture every run: wipe stale files from previous runs. rsync
  # --exclude only SKIPS transferring files — it never deletes them from an
  # existing destination, so without this, removed config_paths and newly
  # excluded caches would linger in backups/ forever (the very bloat this
  # feature exists to avoid). NOTE: backups/ now reflects the CURRENT state
  # only — a config_path that is transiently missing at backup time loses its
  # prior copy here; the mirror snapshots in BACKUP_DEST preserve history.
  # shellcheck disable=SC2115  # dest is always set (BACKUPS_DIR/apps/<name>)
  rm -rf "${dest:?}/home" "${dest:?}/root"
  mkdir -p "$dest/home" "$dest/root"
  info "Backing up config for app: $name"
  # Per-app rsync excludes (the 'exclude' field in inventory.yaml) keep caches,
  # model stores and re-downloadable binaries OUT of backups/ — the config-only
  # principle. Exclude patterns are plain rsync patterns (match by basename at
  # any depth); they apply to every config_path of this app.
  excl=()
  while IFS= read -r e; do
    [ -n "$e" ] && excl+=(--exclude="$e")
  done < <(yq -r ".apps[] | select(.name == \"$name\") | .exclude[]?" "$INVENTORY_FILE")
  if [ "${#excl[@]}" -gt 0 ]; then
    info "  (excluded from backup: ${excl[*]#--exclude=})"
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    src="$(expand_path "$p")"
    if [ ! -e "$src" ]; then
      warn "  skip (path not found): $p"
      continue
    fi
    if [[ "$src" == "$HOME"* ]]; then
      rel="${src#"$HOME"/}"
      if ( cd "$HOME" && rsync -aR "${excl[@]}" "./$rel" "$dest/home/" ); then
        ok "  $p -> backups/apps/$name/"
      else
        warn "  $p -> rsync failed (partial read?); fix permissions and re-run"
      fi
    elif [ ! -r "$src" ]; then
      # Non-$HOME (root-side) config may be root-owned and unreadable by the
      # current user. Detect that up front and warn instead of failing silently
      # or aborting the whole run (backup.sh is normally run WITHOUT sudo — and
      # running it WITH sudo would flip \$HOME to /root and break this script).
      warn "  $p -> not readable by current user; fix permissions (chmod/chown) or declare a readable path in the inventory"
    elif ( cd / && rsync -aR "${excl[@]}" "./${src#/}" "$dest/root/" ); then
      ok "  $p -> backups/apps/$name/"
    else
      warn "  $p -> rsync failed (partial read?); fix permissions and re-run"
    fi
  done < <(yq -r ".apps[] | select(.name == \"$name\") | .config_paths[]?" "$INVENTORY_FILE")
done < <(yaml_list '.apps[] | .name')

# --- Services: capture declared unit files + config paths ------------------
while IFS=$'\t' read -r unit target; do
  [ -n "$unit" ] || continue
  sdest="$BACKUPS_DIR/services/$unit"
  mkdir -p "$sdest"
  # Fresh capture: wipe stale config copies from previous runs (see app loop).
  # shellcheck disable=SC2115  # sdest is always set (BACKUPS_DIR/services/<unit>)
  rm -rf "${sdest:?}/home" "${sdest:?}/root"
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
      if ( cd "$HOME" && rsync -aR "./$rel" "$sdest/home/" ); then
        ok "  $unit: $p -> backups/services/$unit/"
      else
        warn "  $unit: $p -> rsync failed (partial read?); fix permissions and re-run"
      fi
    elif [ ! -r "$csrc" ]; then
      # Root-side service config may be root-owned; warn instead of silent failure.
      # (Do NOT suggest running backup.sh with sudo — that would flip \$HOME to /root.)
      warn "  $unit: $p -> not readable by current user; fix permissions (chmod/chown) or declare a readable path in the inventory"
    elif ( cd / && rsync -aR "./${csrc#/}" "$sdest/root/" ); then
      ok "  $unit: $p -> backups/services/$unit/"
    else
      warn "  $unit: $p -> rsync failed (partial read?); fix permissions and re-run"
    fi
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
# backup-info.txt is written ONLY on a COMPLETED run (meta­data + status in a
# single atomic write). Therefore:
#   * File present with 'status: ok'  -> the last run completed successfully
#   * File absent or lacks that line  -> the last run did NOT complete (or no
#     run has ever succeeded here; the most recent mirror snapshot still holds
#     the previous successful run's marker)
# The newest mirror snapshot gets a copy so the off-machine copy can be
# verified identically (cp guarded so a failed mirror never clobbers an older
# good snapshot's info).
{
  echo "host: $BACKUP_HOST"
  echo "user: $BACKUP_USER"
  echo "started: $BACKUP_STARTED"
  echo "repo: $BACKUP_REPO"
  [ -n "$GIT_COMMIT" ] && echo "git_commit: $GIT_COMMIT"
  echo "status: ok"
  echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "mirror: ${MIRROR_STATUS:-unknown}"
} > "$BACKUPS_DIR/backup-info.txt"
if [ "${MIRROR_STATUS:-}" = "ok" ] && [ -n "${MIRROR_NEWEST:-}" ]; then
  cp "$BACKUPS_DIR/backup-info.txt" "$MIRROR_NEWEST/backup-info.txt"
fi

echo
ok "Backup complete."
echo "backups/ is git-ignored. Mirror status above — BACKUP_DEST=${BACKUP_DEST:-<disabled>},"
echo "keeping the last ${BACKUP_KEEP} snapshot(s)."
