#!/bin/bash
# ---------------------------------------------------------------------------
# common.sh — shared helpers for all scripts in this repo.
#
# Source from a script at the repo root with:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Convention: never duplicate these helpers in individual scripts. If you add
# a helper here, update AGENTS.md and find-and-update all callers.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths ---------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
INVENTORY_FILE="$REPO_ROOT/inventory/inventory.yaml"
# shellcheck disable=SC2034  # consumed by backup.sh / restore.sh after sourcing
BACKUPS_DIR="$REPO_ROOT/backups"
# Local-disk mirror destination for backup.sh (env-overridable; empty string disables).
# NOTE: use "-" (not ":-"): an empty BACKUP_DEST must stay empty so backup.sh
# skips the mirror, per the documented "BACKUP_DEST= disables" semantics.
BACKUP_DEST="${BACKUP_DEST-/media/vikram-athare/Storage/backup-restore-ubuntu}"
# Keep at most this many timestamped snapshots in BACKUP_DEST.
BACKUP_KEEP="${BACKUP_KEEP:-5}"

DRY_RUN=0   # set to 1 by scripts that support --dry-run (restore.sh)

# --- Logging -------------------------------------------------------------
info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# confirm "question" [default y|n] -> exit code 0 (yes) or 1 (no)
confirm() {
  local question="${1:-Continue?}" default="${2:-n}" answer=""
  while :; do
    if [ "$default" = "y" ]; then
      printf '%s [Y/n] ' "$question"
    else
      printf '%s [y/N] ' "$question"
    fi
    read -r answer
    [ -z "$answer" ] && answer="$default"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# --- Dry-run aware runner ------------------------------------------------
# Wrap effectful commands in run(); with DRY_RUN=1 it only prints them.
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- yq bootstrap ---------------------------------------------------------
# YQ_AUTO controls what happens when yq is missing:
#   0 (default): fail with install instructions
#   1         : install silently (restore.sh on a fresh system)
#   2         : ask the user, then install (interactive tools: inventory.sh, backup.sh)
YQ_AUTO=0

# require_yq [mode] — mode overrides YQ_AUTO for this one call.
require_yq() {
  local mode="${1:-$YQ_AUTO}"
  if command -v yq >/dev/null 2>&1; then return 0; fi
  if [ "$mode" = "1" ] || [ "$mode" = "2" ]; then
    if [ "$mode" = "2" ]; then
      confirm "yq is required to read $INVENTORY_FILE. Install it now?" "n" || die "yq is required. Install it with: sudo snap install yq"
    else
      info "yq not found — installing it so the scripts can read inventory.yaml."
    fi
    if command -v snap >/dev/null 2>&1; then
      run sudo snap install yq
    elif command -v curl >/dev/null 2>&1; then
      run sudo install -m 0755 -o root -g root \
        <(curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64") \
        /usr/local/bin/yq
    else
      die "yq is required. Install it manually (e.g. 'sudo snap install yq') and re-run."
    fi
    command -v yq >/dev/null 2>&1 || die "yq still not available after the install attempt."
  else
    die "The 'yq' tool is required to read $INVENTORY_FILE. Install it with: sudo snap install yq"
  fi
}

# --- YAML access (requires yq) -------------------------------------------
# yaml_get QUERY  -> prints a scalar (empty string if absent)
yaml_get() {
  require_yq "$YQ_AUTO"
  yq -r "$1 // \"\"" "$INVENTORY_FILE"
}

# yaml_list QUERY -> prints each element of a list, one per line
# NOTE: no trailing '| .[]' — yq iterates a non-empty scalar's CHARACTERS with .[]
# (jq semantics), which would mangle every app/package name.
# NOTE: no '// []' fallback either — on an empty/null list yq v4 prints a literal
# '[]' line, which callers would treat as a real list item.
yaml_list() {
  require_yq "$YQ_AUTO"
  yq -r "$1" "$INVENTORY_FILE"
}

# app_get NAME QUERY -> scalar attribute of one app (empty if absent)
app_get() {
  require_yq "$YQ_AUTO"
  yq -r ".apps[] | select(.name == \"$1\") | $2 // \"\"" "$INVENTORY_FILE"
}

# --- Misc helpers ---------------------------------------------------------
# expand_path: turn ~/.config/foo into /home/user/.config/foo
expand_path() {
  local p="$1"
  if [ "$p" = "~" ]; then
    p="$HOME"
  else
    p="${p/#\~\//$HOME/}"
  fi
  printf '%s\n' "$p"
}

# --- Installed-status checkers -------------------------------------------
is_apt_installed() {
  dpkg -s "$1" >/dev/null 2>&1 || return 1
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q ' install ok installed'
}

is_snap_installed() {
  command -v snap >/dev/null 2>&1 || return 1
  snap list "$1" >/dev/null 2>&1
}

is_flatpak_installed() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak info "$1" >/dev/null 2>&1
}

# is_app_installed NAME -> true if the app appears to be installed
is_app_installed() {
  local name="$1" itype check pkg
  itype="$(app_get "$name" '.install_type')"
  check="$(app_get "$name" '.check_cmd')"
  pkg="$(app_get "$name" '.package')"
  [ -n "$pkg" ] || pkg="$name"
  if [ -n "$check" ]; then
    command -v "$check" >/dev/null 2>&1 && return 0 || return 1
  fi
  case "$itype" in
    apt)          is_apt_installed "$pkg" ;;
    snap|snap-classic) is_snap_installed "$pkg" ;;
    flatpak)      is_flatpak_installed "$pkg" ;;
    npm-global)   command -v "$name" >/dev/null 2>&1 ;;
    *)            return 1 ;;
  esac
}
