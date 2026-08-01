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
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
# Local-disk mirror destination for backup.sh (env-overridable; empty string disables).
BACKUP_DEST="${BACKUP_DEST-/media/vikram-athare/Storage/backup-restore-ubuntu}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"

DRY_RUN=0   # set to 1 by scripts that support --dry-run (restore.sh)

# --- Architecture ---------------------------------------------------------
ARCH="$(uname -m)"
# Normalise common arch strings to the values dpkg/Go/Docker use.
case "$ARCH" in
  x86_64|amd64) ARCH_NORM="amd64" ;;
  aarch64|arm64) ARCH_NORM="arm64" ;;
  *)             ARCH_NORM="$ARCH" ;;
esac

# --- Logging & exit codes -------------------------------------------------
# Exit codes for restore accumulation (restore.sh uses these).
EXIT_OK=0
EXIT_CONFIGS_MISSING=1
EXIT_INSTALL_FAILED=2
EXIT_PREREQ_FAILED=4

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
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- yq bootstrap ---------------------------------------------------------
YQ_AUTO=0

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
      sudo snap install yq
    elif command -v curl >/dev/null 2>&1; then
      local yq_url
      case "$ARCH_NORM" in
        amd64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
        arm64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
        *)     die "Unsupported architecture '$ARCH_NORM' for yq bootstrap. Install yq manually." ;;
      esac
      local tmp_yq
      tmp_yq="$(mktemp)"
      curl -fsSL -o "$tmp_yq" "$yq_url" || { rm -f "$tmp_yq"; die "yq download failed. Install it manually: sudo snap install yq"; }
      sudo install -m 0755 -o root -g root "$tmp_yq" /usr/local/bin/yq
      rm -f "$tmp_yq"
    else
      die "yq is required. Install it manually (e.g. 'sudo snap install yq') and re-run."
    fi
    command -v yq >/dev/null 2>&1 || die "yq still not available after the install attempt."
  else
    die "The 'yq' tool is required to read $INVENTORY_FILE. Install it with: sudo snap install yq"
  fi
}

# --- YAML access (requires yq) -------------------------------------------
yaml_get() {
  require_yq "$YQ_AUTO"
  yq -r "$1 // \"\"" "$INVENTORY_FILE"
}

yaml_list() {
  require_yq "$YQ_AUTO"
  yq -r "$1" "$INVENTORY_FILE"
}

# app_get NAME QUERY -> scalar attribute of one app (empty if absent)
# Uses environment variable to avoid YAML injection.
app_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | $2 // \"\"" "$INVENTORY_FILE"
}

# --- Safe path helpers ---------------------------------------------------
# normalize_path: resolve '~' and '..' then canonicalise.
# Returns the canonical path; exits non-zero if it escapes $HOME or /.
normalize_path() {
  local p="$1" allow_root="${2:-0}"
  if [ "$p" = "~" ]; then
    p="$HOME"
  else
    p="${p/#\~\//$HOME/}"
  fi
  # Reject '..' components — no traversal allowed.
  case "$p" in
    *..*) err "Path contains '..' traversal — rejected: $1"; return 1 ;;
  esac
  # Reject control characters.
  if printf '%s' "$p" | grep -q $'[\x00-\x1f\x7f]'; then
    err "Path contains control characters — rejected: $1"; return 1
  fi
  printf '%s\n' "$p"
}

# expand_path: turn ~/.config/foo into /home/user/.config/foo  (no canonicalisation)
expand_path() {
  local p="$1"
  if [ "$p" = "~" ]; then
    p="$HOME"
  else
    p="${p/#\~\//$HOME/}"
  fi
  printf '%s\n' "$p"
}

# Validate a path is contained under the expected root (realpath-aware).
# Usage: validate_path_contained "~/Documents" "$HOME"
validate_path_contained() {
  local raw="$1" root="${2:-$HOME}"
  local resolved
  resolved="$(normalize_path "$raw")" || return 1
  local realp
  realp="$(realpath -m -- "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  case "$realp" in
    "$root"|"$root"/*) return 0 ;;
    *) err "Path '$raw' resolves to '$realp' which is outside '$root' — rejected."; return 1 ;;
  esac
}

# --- Inventory validation ------------------------------------------------
validate_inventory() {
  require_yq 0
  local errors=0

  # Validate apps.
  while IFS=$'\t' read -r name itype icmd check pkg; do
    [ -n "$name" ] || continue
    # Safe identifier: alphanumeric, dash, underscore, dot. No slashes, no spaces.
    if ! [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
      warn "  app '$name': name contains invalid characters (a-z, 0-9, ., _, - only)"
      errors=$((errors + 1))
      continue
    fi
    if [ -z "$itype" ]; then
      warn "  app '$name': missing install_type"
      errors=$((errors + 1))
      continue
    fi
    case "$itype" in
      apt|snap|snap-classic|flatpak|npm-global|pipx|cargo) ;;
      script|custom)
        if [ -z "$icmd" ]; then
          warn "  app '$name': install_type '$itype' requires install_command"
          errors=$((errors + 1))
        fi
        ;;
      *) warn "  app '$name': unknown install_type '$itype'"
         errors=$((errors + 1)) ;;
    esac
    # package override only meaningful for apt/snap/snap-classic/flatpak
    if [ -n "$pkg" ]; then
      case "$itype" in
        apt|snap|snap-classic|flatpak) ;;
        *) warn "  app '$name': 'package' field only applies to apt/snap/snap-classic/flatpak installs"
           errors=$((errors + 1)) ;;
      esac
    fi
    if { [ "$itype" = "script" ] || [ "$itype" = "custom" ]; } && [ -z "$check" ]; then
      warn "  app '$name': script/custom installer has no check_cmd — re-runs will re-execute the installer"
    fi
    # Validate config_paths.
    while IFS= read -r cp; do
      [ -n "$cp" ] || continue
      if ! validate_path_contained "$cp" "$HOME" 2>/dev/null && ! validate_path_contained "$cp" "/" 2>/dev/null; then
        warn "  app '$name': invalid config_path '$cp'"
        errors=$((errors + 1))
      fi
    done < <(app_get "$name" '.config_paths[]?')
  done < <(yq -r '.apps[] | [.name, .install_type, (.install_command // ""), (.check_cmd // ""), (.package // "")] | @tsv' "$INVENTORY_FILE")

  # Check for duplicate app names.
  local dupes
  dupes="$(yaml_list '.apps[] | .name' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    warn "  duplicate app names: $dupes"
    errors=$((errors + 1))
  fi

  # Validate services.
  while IFS=$'\t' read -r unit target; do
    [ -n "$unit" ] || continue
    if ! [[ "$unit" =~ ^[a-zA-Z0-9@._:-]+\.(service|timer|socket|path)$ ]]; then
      warn "  service '$unit': invalid systemd unit name (must end in .service/.timer/.socket/.path, no slashes/control chars)"
      errors=$((errors + 1))
      continue
    fi
    case "$target" in
      user|system) ;;
      *) warn "  service '$unit': target must be 'user' or 'system', got '$target'"
         errors=$((errors + 1)) ;;
    esac
  done < <(yq -r '.services[] | [.unit, (.target // "system")] | @tsv' "$INVENTORY_FILE")

  # Validate user_dirs.
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$d" = "~" ]; then
      warn "  user_dirs: '\$HOME' itself cannot be a user dir"
      errors=$((errors + 1))
      continue
    fi
    if ! validate_path_contained "$d" "$HOME" 2>/dev/null; then
      warn "  user_dirs: path '$d' is not under \$HOME"
      errors=$((errors + 1))
    fi
  done < <(yaml_list '.user_dirs[]')

  # Validate dotfiles.
  while IFS= read -r df; do
    [ -n "$df" ] || continue
    if [[ "$df" =~ ^/ ]] || [[ "$df" =~ \.\. ]]; then
      warn "  dotfiles: '$df' must be a relative path under \$HOME"
      errors=$((errors + 1))
    fi
  done < <(yaml_list '.dotfiles[]')

  if [ "$errors" -gt 0 ]; then
    warn "Inventory validation found $errors issue(s). Please fix inventory.yaml before continuing."
    return 1
  fi
  ok "Inventory validation: OK"
  return 0
}

# --- OS checks -----------------------------------------------------------
require_ubuntu() {
  local os_id=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi
  if [ "$os_id" != "ubuntu" ]; then
    die "This repo targets Ubuntu only (detected: ${os_id:-unknown}). Restore on a non-Ubuntu system is not supported."
  fi
}

require_non_root() {
  if [ "$(id -u)" = "0" ]; then
    die "Do not run this script as root. Run as the target user — sudo is used internally for individual system operations."
  fi
}

# --- Concurrency protection (flock) --------------------------------------
# Usage: with_lock LOCKFILE command...
# Acquires an exclusive, non-blocking lock; dies if another instance is running.
LOCK_FD=9
with_lock() {
  local lockfile="$1"; shift
  mkdir -p "$(dirname "$lockfile")"
  exec 9>"$lockfile"
  if ! flock -n 9; then
    die "Another instance is already running (lock: $lockfile). Wait for it to finish."
  fi
}

release_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

# --- Backup manifest -----------------------------------------------------
# Write an in-progress marker (atomically replaces any old marker).
manifest_in_progress() {
  local run_id="$1"
  {
    echo "run_id: $run_id"
    echo "status: in_progress"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$BACKUP_MANIFEST"
}

# Write the final manifest with artifact tracking.
manifest_final() {
  local run_id="$1" mir_stat="$2" artifact_file="$3"
  local inventory_sha git_commit os_ver overall="ok"
  inventory_sha="$(sha256sum "$INVENTORY_FILE" 2>/dev/null | cut -d' ' -f1 || echo "unknown")"
  git_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  os_ver=""
  [ -r /etc/os-release ] && { . /etc/os-release; os_ver="${VERSION_ID:-}"; } 2>/dev/null || true

  # Derive the overall status from the artifact list. Any missing/incomplete
  # artifact degrades the backup (an app with no config paths is 'empty', not a
  # failure). Restore requires 'status: ok' before restoring configuration.
  if [ -s "$artifact_file" ] && grep -Eq '/(missing|incomplete|missing-unit)$' "$artifact_file"; then
    overall="degraded"
  fi

  {
    echo "run_id: $run_id"
    echo "status: $overall"
    echo "host: $(hostname)"
    echo "user: $USER"
    echo "arch: $ARCH_NORM"
    [ -n "$os_ver" ] && echo "ubuntu_version: $os_ver"
    echo "repo: $REPO_ROOT"
    [ -n "$git_commit" ] && echo "git_commit: $git_commit"
    echo "inventory_sha256: $inventory_sha"
    echo "started: ${BACKUP_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mirror: $mir_stat"
    echo "---"
    if [ -s "$artifact_file" ]; then
      cat "$artifact_file"
    fi
  }
}

# Count artifact lines with a given status.
manifest_count_status() {
  local status="$1" file="$2"
  [ -f "$file" ] || { echo "0"; return 0; }
  # grep -c prints the count (including '0') and exits 1 on no match;
  # guard the exit code only, never print a second '0'.
  grep -c "^.*/$status$" "$file" 2>/dev/null || true
}

# Verify a manifest for restore readiness.
# Returns 0 if the backup is complete and can be restored.
# Returns 1 if the backup is incomplete/degraded and should not be restored
# without explicit override.
manifest_verify_restorable() {
  local mf="$1"
  [ -f "$mf" ] || { err "No backup manifest found at $mf."; return 1; }

  if ! grep -q '^status: ok$' "$mf"; then
    err "Backup manifest does not report 'status: ok' — the backup is incomplete or failed."
    if grep -q '^status: in_progress$' "$mf"; then
      err "  The last backup run was interrupted (still 'in_progress'). Do not restore from this snapshot."
    fi
    return 1
  fi

  # Check that at least some artifacts were captured.
  if ! grep -q '^---$' "$mf"; then
    err "Backup manifest has no artifact list — cannot verify completeness."
    return 1
  fi

  ok "Backup manifest verified: status=ok"
  return 0
}

# --- Installed-status checkers (source-specific) -------------------------
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

# is_app_installed_by_source NAME -> true if the app is installed via its declared source.
# This is stricter than mere 'command -v' — it verifies the expected package manager.
is_app_installed_by_source() {
  local name="$1" itype check pkg
  itype="$(app_get "$name" '.install_type')"
  check="$(app_get "$name" '.check_cmd')"
  pkg="$(app_get "$name" '.package')"
  [ -n "$pkg" ] || pkg="$name"

  case "$itype" in
    apt)           is_apt_installed "$pkg" && return 0 || return 1 ;;
    snap|snap-classic) is_snap_installed "$pkg" && return 0 || return 1 ;;
    flatpak)       is_flatpak_installed "$pkg" && return 0 || return 1 ;;
    npm-global)
      command -v npm >/dev/null 2>&1 && npm list -g --depth=0 "$pkg" >/dev/null 2>&1 && return 0 || return 1 ;;
    pipx)
      command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -q "^$pkg " && return 0 || return 1 ;;
    cargo)
      command -v "$check" >/dev/null 2>&1 && return 0 || return 1 ;;
    script|custom)
      [ -n "$check" ] && command -v "$check" >/dev/null 2>&1 && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

# is_app_installed NAME -> true if the app appears to be installed (legacy fallback).
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
