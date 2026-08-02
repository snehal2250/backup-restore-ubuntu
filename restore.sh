#!/bin/bash
# ---------------------------------------------------------------------------
# restore.sh — REBUILD the system from the inventory.
#
# Philosophy (see AGENTS.md): install everything FRESH from recommended sources
# at the latest stable version; copy back ONLY configuration from backups/
# (or an external snapshot given with --source). Never installs from backup
# files, never replays dpkg state, never pins versions.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/installers.sh"

DRY_RUN=0
ASSUME_YES=0
DO_UPGRADE=0
CONFIGS_ONLY=0
PACKAGES_ONLY=0
FORCE_INCOMPLETE=0
RESTORE_SOURCE=""
BACKUP_LABEL="backups/"   # user-facing name of the config source (set to the snapshot under --source)

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --upgrade-base) DO_UPGRADE=1 ;;
    --configs-only) CONFIGS_ONLY=1 ;;
    --packages-only) PACKAGES_ONLY=1 ;;
    --force-incomplete) FORCE_INCOMPLETE=1 ;;
    --source)       shift; RESTORE_SOURCE="${1:-}"; [ -n "$RESTORE_SOURCE" ] || die "--source requires a snapshot directory argument." ;;
    *) die "Unknown option: $1 (usage: $0 [--source <snapshot-dir>] [--dry-run] [--yes] [--upgrade-base] [--configs-only|--packages-only] [--force-incomplete])" ;;
  esac
  shift
done

[ "$CONFIGS_ONLY" = "1" ] && [ "$PACKAGES_ONLY" = "1" ] && die "--configs-only and --packages-only are mutually exclusive."

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq 1
SCHEMA_AUTO=1   # schema validator: auto-install python3-jsonschema on a fresh system

# Note: require_schema_validator (called via validate_inventory below) may also
# auto-install python3-jsonschema python3-yaml on a fresh system — the same
# policy as yq: validation must run even under --dry-run.

# --- Preflight: OS and user ----------------------------------------------
require_ubuntu
require_non_root
require_cmd sudo

# Validate inventory before touching anything.
validate_inventory || die "Inventory validation failed — fix inventory.yaml and re-run."

# --- Optional external backup source (--source) ---------------------------
# With --source, restore reads configuration DIRECTLY from the given backup
# snapshot (e.g. a backup-* mirror snapshot on an external drive) instead of
# the repo-local backups/. The repo checkout is disposable and the backup
# medium is authoritative — nothing is copied or mounted implicitly.
if [ -n "$RESTORE_SOURCE" ]; then
  RESTORE_SOURCE="$(realpath -m -- "$RESTORE_SOURCE" 2>/dev/null || printf '%s' "$RESTORE_SOURCE")"
  if [ ! -d "$RESTORE_SOURCE" ]; then
    die "Backup source not found: $RESTORE_SOURCE (--source expects a snapshot directory containing backup-info.txt, e.g. /media/$USER/Storage/backup-restore-ubuntu/backup-20260802-120000)"
  fi
  if [ ! -f "$RESTORE_SOURCE/backup-info.txt" ]; then
    _newest_snap="$(ls -1dr "$RESTORE_SOURCE"/backup-* 2>/dev/null | head -n1 || true)"
    if [ -n "$_newest_snap" ]; then
      die "No backup-info.txt in $RESTORE_SOURCE — that looks like a mirror root holding snapshots. Pass a single snapshot, e.g.: $_newest_snap"
    fi
    die "No backup-info.txt in $RESTORE_SOURCE — not a backup snapshot (run ./backup.sh first, or point --source at a mirror snapshot)."
  fi
  BACKUPS_DIR="$RESTORE_SOURCE"
  BACKUP_MANIFEST="$RESTORE_SOURCE/backup-info.txt"
  BACKUP_LABEL="$RESTORE_SOURCE"
  BACKUPS_PRESENT=1
  BACKUPS_VERIFIED=0
  if manifest_verify_restorable "$BACKUP_MANIFEST"; then
    BACKUPS_VERIFIED=1
  elif [ "$FORCE_INCOMPLETE" = "1" ]; then
    warn "Backup manifest is incomplete but --force-incomplete was specified — proceeding anyway."
    BACKUPS_VERIFIED=1
  else
    die "Cannot restore from $RESTORE_SOURCE: backup manifest is not verified (missing or no 'status: ok'). Use --force-incomplete to override."
  fi

  # Preflight compatibility checks (best-effort; older manifests may lack lines).
  _src_arch="$(grep -m1 '^arch: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_arch" ] && [ "$_src_arch" != "$ARCH_NORM" ]; then
    die "Backup was created on architecture '$_src_arch' but this machine is '$ARCH_NORM' — refusing to restore incompatible configuration."
  fi
  _src_os="$(grep -m1 '^ubuntu_version: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_os" ]; then
    _cur_os=""
    [ -r /etc/os-release ] && { . /etc/os-release; _cur_os="${VERSION_ID:-}"; }
    if [ -n "$_cur_os" ] && [ "$_src_os" != "$_cur_os" ]; then
      warn "Backup was created on Ubuntu $_src_os but this machine is $_cur_os — packages reinstall at latest versions, but some app configs may not match. Proceeding."
    fi
  fi
  _src_sha="$(grep -m1 '^inventory_sha256: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_sha" ]; then
    _cur_sha="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
    if [ "$_src_sha" != "$_cur_sha" ]; then
      warn "This repo's inventory.yaml differs from the one used to create this backup — items added since restore fresh, items removed are skipped."
    fi
  else
    warn "Backup manifest has no inventory_sha256 — cannot verify inventory compatibility."
  fi
  if [ -w "$RESTORE_SOURCE" ]; then
    warn "Backup source is writable. For safety, prefer restoring from a read-only medium (mounted drive, read-only snapshot)."
  fi
  info "Restoring from backup source: $RESTORE_SOURCE"
fi

# --- Determine backup status (repo-local backups/, unless --source) -------
if [ -z "$RESTORE_SOURCE" ]; then
  BACKUPS_PRESENT=0
  BACKUPS_VERIFIED=0
  if [ -f "$BACKUP_MANIFEST" ]; then
    BACKUPS_PRESENT=1
    if manifest_verify_restorable "$BACKUP_MANIFEST"; then
      BACKUPS_VERIFIED=1
    elif [ "$FORCE_INCOMPLETE" = "1" ]; then
      warn "Backup manifest is incomplete but --force-incomplete was specified — proceeding anyway."
      BACKUPS_VERIFIED=1
    fi
  elif [ -d "$BACKUPS_DIR" ] && [ -n "$(find "$BACKUPS_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    warn "backups/ contains data but no valid manifest (backup-info.txt with status: ok)."
    if [ "$FORCE_INCOMPLETE" = "1" ]; then
      BACKUPS_PRESENT=1
      BACKUPS_VERIFIED=1
    fi
  fi

  if [ "$BACKUPS_PRESENT" = "0" ]; then
    if [ "$CONFIGS_ONLY" = "1" ]; then
      warn "No backups/ found — --configs-only has nothing to restore."
    else
      warn "No backups/ found — packages will still be installed, but configuration cannot be restored."
    fi
  fi

  if [ "$BACKUPS_PRESENT" = "1" ] && [ "$BACKUPS_VERIFIED" = "0" ]; then
    if [ "$CONFIGS_ONLY" = "1" ]; then
      die "Cannot restore config: backup manifest is not valid (missing or no 'status: ok'). Use --force-incomplete to override."
    elif [ "$PACKAGES_ONLY" != "1" ]; then
      warn "Backup manifest is not valid — configuration will NOT be restored. Use --force-incomplete to override."
    fi
  fi
fi

# --- Content integrity (SHA256SUMS) --------------------------------------
# Read-only verification of the restore source (repo backups/ or --source
# snapshot): hostile special files, escaping symlinks, and checksum matches.
# Skipped under --packages-only (no config is restored, so content is unused).
# Legacy snapshots without SHA256SUMS are accepted with a warning. A failed
# check means the payload is corrupt or tampered — refuse unless overridden.
if [ "$BACKUPS_VERIFIED" = "1" ] && [ "$PACKAGES_ONLY" != "1" ]; then
  if [ -f "$BACKUPS_DIR/SHA256SUMS" ]; then
    if backup_verify_integrity "$BACKUPS_DIR"; then
      ok "Backup content verified (SHA256SUMS)"
    elif [ "$FORCE_INCOMPLETE" = "1" ]; then
      warn "Backup content integrity check FAILED but --force-incomplete was specified — proceeding anyway."
    else
      die "Backup content integrity check FAILED (corrupt or tampered snapshot). Use --force-incomplete to override."
    fi
  else
    warn "No SHA256SUMS in backup — skipping content integrity check (snapshot created before integrity checking)."
  fi
fi

# --- Confirm -------------------------------------------------------------
if [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ] && [ "$CONFIGS_ONLY" = "0" ] && [ "$PACKAGES_ONLY" = "0" ]; then
  confirm "This will install packages and modify the system. Continue?" "n" || die "Aborted."
elif [ "$CONFIGS_ONLY" = "1" ] && [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  confirm "This will restore configuration from $BACKUP_LABEL (no packages will be installed). Continue?" "n" || die "Aborted."
elif [ "$PACKAGES_ONLY" = "1" ] && [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  confirm "This will install packages only (no configuration will be restored). Continue?" "n" || die "Aborted."
fi

# --- Check required tools -------------------------------------------------
# rsync is needed for config restore; ensure it's available.
if [ "$PACKAGES_ONLY" != "1" ] && [ "$BACKUPS_PRESENT" = "1" ]; then
  if ! command -v rsync >/dev/null 2>&1; then
    info "rsync not found — installing it (needed for config restore)."
    run sudo apt-get update
    run sudo apt-get install -y rsync
  fi
fi

# --- Accumulated exit code ------------------------------------------------
ACUMULATED_EXIT=0

mark_failure() {
  local code="${1:-$EXIT_INSTALL_FAILED}"
  ACUMULATED_EXIT=$(( ACUMULATED_EXIT | code ))
}

# --- Phase 1: base system -------------------------------------------------
if [ "$CONFIGS_ONLY" = "1" ]; then
  info "Phase 1/5: base system (skipped — --configs-only)"
else
  info "Phase 1/5: base system"
  run sudo apt-get update || mark_failure "$EXIT_PREREQ_FAILED"
  if [ "$DO_UPGRADE" = "1" ]; then
    info "(--upgrade-base: apt full-upgrade of the whole base OS)"
    run sudo apt-get full-upgrade -y || mark_failure "$EXIT_PREREQ_FAILED"
    run sudo apt-get autoremove -y || true
  else
    info "(base OS full-upgrade skipped by default — opt in with --upgrade-base)"
  fi
fi

# --- Phase 2: packages ----------------------------------------------------
if [ "$CONFIGS_ONLY" = "1" ]; then
  info "Phase 2/5: packages (skipped — --configs-only)"
else
  info "Phase 2/5: packages"

install_apt_packages() {
  local -a pkgs=() p
  while IFS= read -r p; do
    [ -n "$p" ] && pkgs+=("$p")
  done < <(yaml_list '.apt_packages[]')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    info "Installing ${#pkgs[@]} apt package(s): ${pkgs[*]}"
    run sudo apt-get install -y "${pkgs[@]}" || mark_failure
  fi
}

install_snap_packages() {
  local -a pkgs=() p entry pkg classic
  while IFS= read -r p; do
    [ -n "$p" ] && pkgs+=("$p")
  done < <(yaml_list '.snap_packages[]')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    if ! command -v snap >/dev/null 2>&1; then
      warn "snap is not available on this system; skipping snap packages."
      mark_failure
      return 0
    fi
    for entry in "${pkgs[@]}"; do
      pkg="${entry%%:*}"
      classic=""
      [ "${entry##*:}" = "classic" ] && classic="--classic"
      info "Installing snap: $entry"
      run sudo snap install $classic "$pkg" || mark_failure
    done
  fi
}

install_flatpak_apps() {
  local -a apps=() a
  while IFS= read -r a; do
    [ -n "$a" ] && apps+=("$a")
  done < <(yaml_list '.flatpak_apps[]')
  if [ "${#apps[@]}" -gt 0 ]; then
    command -v flatpak >/dev/null 2>&1 || {
      info "flatpak not found — installing it."
      run sudo apt-get install -y flatpak || mark_failure
    }
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    for a in "${apps[@]}"; do
      info "Installing flatpak app: $a"
      run flatpak install -y flathub "$a" || mark_failure
    done
  fi
}

install_apt_packages
install_snap_packages
install_flatpak_apps
fi

# --- Phase 3: apps --------------------------------------------------------
info "Phase 3/5: apps"

restore_app_config() {
  local name="$1"
  local dir="$BACKUPS_DIR/apps/$name"
  [ "$BACKUPS_VERIFIED" = "1" ] || return 0
  if [ -d "$dir/home" ]; then
    run rsync -a "$dir/home/" "$HOME/"
    ok "  $name: config restored to \$HOME"
  fi
  if [ -d "$dir/root" ]; then
    run sudo rsync -a "$dir/root/" /
    ok "  $name: config restored to /"
  fi
}

# Bootstrap backends derived from inventory, before any app install.
bootstrap_backends() {
  local need_flatpak=0 need_npm=0 need_pipx=0 need_cargo=0
  local itype
  while IFS= read -r itype; do
    [ -n "$itype" ] || continue
    case "$itype" in
      flatpak) need_flatpak=1 ;;
      npm_global) need_npm=1 ;;
      pipx) need_pipx=1 ;;
      cargo) need_cargo=1 ;;
    esac
  done < <(yq -r '.apps[].installer.type | select(. != null)' "$INVENTORY_FILE")

  if [ "$need_flatpak" = "1" ] && ! command -v flatpak >/dev/null 2>&1; then
    info "flatpak needed by declared apps — installing it."
    run sudo apt-get install -y flatpak || mark_failure
  fi
  local flatpak_count
  flatpak_count="$(yq -r '.flatpak_apps | length // 0' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  if [ "$need_flatpak" = "1" ] || [ "${flatpak_count:-0}" -gt 0 ]; then
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
  fi
  if [ "$need_npm" = "1" ] && ! command -v npm >/dev/null 2>&1; then
    info "npm needed by declared apps but not installed — individual npm-global installs will fail unless nodejs+npm are declared as deps."
  fi
  if [ "$need_pipx" = "1" ] && ! command -v pipx >/dev/null 2>&1; then
    info "pipx needed by declared apps — installing it."
    run sudo apt-get install -y pipx || mark_failure
  fi
  if [ "$need_cargo" = "1" ] && ! command -v cargo >/dev/null 2>&1; then
    info "cargo needed by declared apps — installing it."
    run sudo apt-get install -y cargo || mark_failure
  fi
}

install_app() {
  local name="$1" itype check
  itype="$(app_get "$name" '.installer.type')"
  [ -n "$itype" ] || { warn "  app '$name' has no installer.type — skipping."; mark_failure; return 1; }
  check="$(app_get "$name" '.check_cmd')"

  if [ "$CONFIGS_ONLY" = "1" ]; then
    if [ "$BACKUPS_VERIFIED" = "1" ]; then
      restore_app_config "$name"
    fi
    return 0
  fi

  local -a deps=() d
  while IFS= read -r d; do
    [ -n "$d" ] && deps+=("$d")
  done < <(app_get "$name" '.depends_apt[]?')
  if [ "${#deps[@]}" -gt 0 ]; then
    info "  $name: installing dependencies: ${deps[*]}"
    run sudo apt-get install -y "${deps[@]}" || { warn "  $name: dependency install failed"; mark_failure; }
  fi

  if [ "$itype" = "script" ] && [ -z "$check" ]; then
    warn "  $name: script installer with NO check_cmd — re-runs will re-run the installer (add check_cmd in the inventory)."
  fi

  # Source-specific check: don't skip just on command -v.
  if is_app_installed_by_source "$name"; then
    ok "  $name: already installed (verified via $itype)"
  else
    # Typed installer (lib/installers.sh) — prints its own dry-run steps.
    if installer_run "$name"; then
      if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] %s: would be installed (steps above)\n' "$name"
      elif [ -n "$check" ] && ! command -v "$check" >/dev/null 2>&1; then
        warn "  $name: installer succeeded but '$check' not found — may need a new shell or PATH update."
      else
        ok "  $name: installed."
      fi
    else
      mark_failure
    fi
  fi

  if [ "$PACKAGES_ONLY" != "1" ]; then
    restore_app_config "$name"
  fi
}

# Bootstrap backends before starting app installs.
if [ "$CONFIGS_ONLY" != "1" ]; then
  bootstrap_backends
fi

while IFS= read -r name; do
  [ -n "$name" ] || continue
  info "App: $name"
  install_app "$name"
done < <(yaml_list '.apps[] | .name')

# --- Phase 4: services -----------------------------------------------------
info "Phase 4/5: services"

restore_services() {
  local unit target enable start sdir dest
  while IFS=$'\t' read -r unit target enable start; do
    [ -n "$unit" ] || continue
    [ "$target" = "user" ] || target="system"
    [ "$enable" = "true" ] || enable="false"
    [ "$start" = "true" ] || start="false"
    sdir="$BACKUPS_DIR/services/$unit"
    if [ "$BACKUPS_VERIFIED" = "1" ] && [ -f "$sdir/unit" ]; then
      if [ "$CONFIGS_ONLY" = "0" ]; then
        if [ "$target" = "user" ]; then
          dest="$HOME/.config/systemd/user/$unit"
          run mkdir -p "$HOME/.config/systemd/user"
          run cp "$sdir/unit" "$dest"
          run systemctl --user daemon-reload 2>/dev/null || warn "  $unit: could not reload user systemd (no user session?)."
        else
          dest="/etc/systemd/system/$unit"
          run sudo cp "$sdir/unit" "$dest"
          run sudo systemctl daemon-reload
        fi
        ok "  $unit: unit installed ($target)"
      fi
      if [ "$PACKAGES_ONLY" != "1" ]; then
        if [ -d "$sdir/home" ]; then
          run rsync -a "$sdir/home/" "$HOME/"
          ok "  $unit: config restored to \$HOME"
        fi
        if [ -d "$sdir/root" ]; then
          run sudo rsync -a "$sdir/root/" /
          ok "  $unit: config restored to /"
        fi
      fi
      # Under --packages-only, do NOT enable/start services — they need
      # their configuration to have been restored first.
      if [ "$PACKAGES_ONLY" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
          printf '[dry-run] %s: NOT enabling/starting (--packages-only skips config — re-run without --packages-only to activate).\n' "$unit"
        else
          warn "  $unit: NOT enabled/started (--packages-only skips config — re-run without --packages-only to activate)."
        fi
      elif [ "$CONFIGS_ONLY" = "0" ]; then
        if [ "$target" = "user" ]; then
          [ "$enable" = "true" ] && run systemctl --user enable "$unit" 2>/dev/null || warn "  $unit: could not enable (no user session?)."
          [ "$start" = "true" ] && run systemctl --user start "$unit" 2>/dev/null || warn "  $unit: could not start (no user session?)."
        else
          [ "$enable" = "true" ] && run sudo systemctl enable "$unit"
          [ "$start" = "true" ] && run sudo systemctl start "$unit"
        fi
      fi
      ok "  service: $unit ($target)"
    else
      warn "  service '$unit': no unit file in $BACKUP_LABEL — skipping."
      if [ "$BACKUPS_VERIFIED" = "1" ]; then
        mark_failure
      fi
    fi
  done < <(yq -r '.services[] | [.unit, (.target // "system"), (.enable // false | tostring), (.start // false | tostring)] | @tsv' "$INVENTORY_FILE")
}

restore_services

# --- Phase 5: dotfiles + user dirs -------------------------------------------
if [ "$PACKAGES_ONLY" = "1" ]; then
  info "Phase 5/5: dotfiles & user dirs (skipped — --packages-only)"
else
info "Phase 5/5: dotfiles & user dirs"

restore_dotfiles() {
  local df
  while IFS= read -r df; do
    [ -n "$df" ] || continue
    if [ "$BACKUPS_VERIFIED" = "1" ] && [ -f "$BACKUPS_DIR/dotfiles/$df" ]; then
      local dest_parent
      dest_parent="$(dirname "$HOME/$df")"
      run mkdir -p "$dest_parent"
      run cp "$BACKUPS_DIR/dotfiles/$df" "$HOME/$df"
      ok "  dotfile: $df"
    else
      warn "  dotfile '$df': no backup — skipping."
    fi
  done < <(yaml_list '.dotfiles[]')
}

restore_dotfiles

restore_user_dirs() {
  local d rel src
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$BACKUPS_VERIFIED" != "1" ]; then
      warn "  user dir '$d': no verified backups — skipping."
      continue
    fi
    src="$(expand_path "$d")"
    if [ "$src" = "$HOME" ]; then
      warn "  user dir '$d': \$HOME itself cannot be restored this way — skipping."
      continue
    fi
    if ! validate_path_contained "$d" "$HOME" 2>/dev/null; then
      warn "  user dir '$d': not under \$HOME — skipping."
      continue
    fi
    rel="${src#"$HOME"/}"
    if [ -d "$BACKUPS_DIR/user-dirs/$rel" ]; then
      run mkdir -p "$HOME/$rel"
      run rsync -a "$BACKUPS_DIR/user-dirs/$rel/" "$HOME/$rel/"
      ok "  user dir: $d restored"
    else
      warn "  user dir '$d': no backup in $BACKUP_LABEL/user-dirs — skipping."
    fi
  done < <(yaml_list '.user_dirs[]')
}

restore_user_dirs
fi

# --- Phase 6: post-install (groups, shell, extensions, models) ------------
if [ "$CONFIGS_ONLY" = "1" ]; then
  info "Phase 6/6: post-install (skipped — --configs-only)"
elif [ "$PACKAGES_ONLY" = "1" ]; then
  info "Phase 6/6: post-install (skipped — --packages-only)"
else
info "Phase 6/6: post-install (groups, shell, extensions)"

# --- Groups ---
while IFS= read -r g; do
  [ -n "$g" ] || continue
  if getent group "$g" >/dev/null 2>&1; then
    if groups "$USER" 2>/dev/null | grep -qw "$g"; then
      ok "  group: $g already member"
    else
      run sudo usermod -aG "$g" "$USER"
      ok "  group: $g — user '$USER' added (log out and back in to take effect)"
    fi
  else
    warn "  group '$g' does not exist — skipping."
  fi
done < <(yaml_list '.groups[]?')

# --- Default shell ---
_shell_target="$(yaml_get '.default_shell')"
if [ -n "$_shell_target" ]; then
  if [ -x "$_shell_target" ]; then
    if grep -q "^$USER:.*:$_shell_target\$" /etc/passwd 2>/dev/null; then
      ok "  default shell: already $_shell_target"
    else
      run sudo chsh -s "$_shell_target" "$USER"
      ok "  default shell: set to $_shell_target (takes effect on next login)"
    fi
  else
    warn "  default shell '$_shell_target' is not executable — skipping chsh."
  fi
fi

# --- App extensions (VS Code, Azure CLI, Ollama models) ---
while IFS= read -r name; do
  [ -n "$name" ] || continue
  exts=()
  while IFS= read -r e; do
    [ -n "$e" ] && exts+=("$e")
  done < <(app_get "$name" '.extensions[]?')
  [ "${#exts[@]}" -gt 0 ] || continue

  check="$(app_get "$name" '.check_cmd')"
  [ -n "$check" ] && command -v "$check" >/dev/null 2>&1 || { warn "  $name: app not installed — cannot install extensions."; continue; }

  for e in "${exts[@]}"; do
    case "$name" in
      code|vscode)
        run code --install-extension "$e" && ok "  $name: extension '$e' installed" || warn "  $name: failed to install extension '$e'"
        ;;
      az)
        run az extension add -n "$e" 2>/dev/null && ok "  $name: extension '$e' added" || warn "  $name: failed to add extension '$e'"
        ;;
      ollama)
        run ollama pull "$e" && ok "  $name: model '$e' pulled" || warn "  $name: failed to pull model '$e'"
        ;;
      *)
        warn "  $name: extensions not supported for this app type"
        ;;
    esac
  done
done < <(yaml_list '.apps[] | .name')
fi

# --- Wrap-up ---------------------------------------------------------------
echo
if [ "$ACUMULATED_EXIT" -ne 0 ]; then
  warn "Restore completed with issues (exit code: $ACUMULATED_EXIT)."
  echo
  echo "  Review the output above for warnings and failed items."
  _fail_reasons=""
  [ "$(( ACUMULATED_EXIT & EXIT_INSTALL_FAILED ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - One or more package/app installs failed (check above)."
  [ "$(( ACUMULATED_EXIT & EXIT_CONFIGS_MISSING ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - Some configuration or artifacts were missing."
  [ "$(( ACUMULATED_EXIT & EXIT_PREREQ_FAILED ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - A prerequisite setup step failed."
  [ -n "$_fail_reasons" ] && echo "$_fail_reasons"
else
  ok "Restore complete."
fi
if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run — no system changes made; read-only checks (inventory, backup source) still ran)"
fi
if [ "$PACKAGES_ONLY" = "1" ] && [ "$BACKUPS_VERIFIED" = "1" ]; then
  echo
  echo "NOTE: --packages-only was used. Services were installed but NOT enabled/started."
  echo "Re-run without --packages-only to restore config and activate services."
fi
echo
echo "Next steps:"
echo "  1. Review the output above for warnings and failed items."
echo "  2. Reboot so services and configuration take full effect."
echo "  3. Keep everything current with ./update_all_ubuntu.sh"
echo "  4. Verify key apps and services work before relying on this machine."

exit "$ACUMULATED_EXIT"
