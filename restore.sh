#!/bin/bash
# ---------------------------------------------------------------------------
# restore.sh — REBUILD the system from the inventory.
#
# Philosophy (see AGENTS.md): install everything FRESH from recommended sources
# at the latest stable version; copy back ONLY configuration from backups/.
# Never installs from backup files, never replays dpkg state, never pins versions.
#
# Usage:
#   ./restore.sh                 # prompts before modifying the system
#   ./restore.sh --yes           # skip prompts
#   ./restore.sh --dry-run       # preview everything without executing
#   ./restore.sh --upgrade-base  # ALSO apt full-upgrade the base OS (opt-in)
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DRY_RUN=0
ASSUME_YES=0
DO_UPGRADE=0   # base OS upgrade is opt-in: only declared items are touched by default

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --upgrade-base) DO_UPGRADE=1 ;;
    *) die "Unknown option: $1 (usage: $0 [--dry-run] [--yes] [--upgrade-base])" ;;
  esac
  shift
done

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq "$([ "$DRY_RUN" = "0" ] && echo 1 || echo 0)"
require_cmd sudo

# --- Preflight ------------------------------------------------------------
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || warn "This repo targets Ubuntu; detected: ${ID:-unknown} ${VERSION_ID:-}"
else
  warn "Cannot determine the OS (/etc/os-release missing)."
fi

# backups/ counts as present only if it holds a real artifact (backup-info.txt written
# by backup.sh, or at least one captured file). An EMPTY dir — e.g. after a failed
# snapshot copy on a fresh machine — must not silently suppress the warning below.
BACKUPS_PRESENT=0
if [ -f "$BACKUPS_DIR/backup-info.txt" ]; then
  BACKUPS_PRESENT=1
elif [ -d "$BACKUPS_DIR" ] && [ -n "$(find "$BACKUPS_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  BACKUPS_PRESENT=1
fi
if [ "$BACKUPS_PRESENT" = "0" ]; then
  warn "No backups/ found — packages will still be installed, but configuration cannot be restored."
fi

if [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  confirm "This will install packages and modify the system. Continue?" "n" || die "Aborted."
fi

# --- Phase 1: base system -------------------------------------------------
info "Phase 1/5: base system"
run sudo apt-get update
if [ "$DO_UPGRADE" = "1" ]; then
  info "(--upgrade-base: apt full-upgrade of the whole base OS)"
  run sudo apt-get full-upgrade -y
  run sudo apt-get autoremove -y
else
  info "(base OS full-upgrade skipped by default — opt in with --upgrade-base)"
fi

# --- Phase 2: packages ----------------------------------------------------
info "Phase 2/5: packages"

install_apt_packages() {
  local -a pkgs=() p
  while IFS= read -r p; do
    [ -n "$p" ] && pkgs+=("$p")
  done < <(yaml_list '.apt_packages[]')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    info "Installing ${#pkgs[@]} apt package(s): ${pkgs[*]}"
    run sudo apt-get install -y "${pkgs[@]}"
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
      return 0
    fi
    for entry in "${pkgs[@]}"; do
      pkg="${entry%%:*}"
      classic=""
      [ "${entry##*:}" = "classic" ] && classic="--classic"
      info "Installing snap: $entry"
      run sudo snap install $classic "$pkg"
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
      run sudo apt-get install -y flatpak
    }
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    for a in "${apps[@]}"; do
      info "Installing flatpak app: $a"
      run flatpak install -y flathub "$a"
    done
  fi
}

install_apt_packages
install_snap_packages
install_flatpak_apps

# --- Phase 3: apps (fresh install + config overwrite) ----------------------
info "Phase 3/5: apps"

restore_app_config() {
  local name="$1"
  local dir="$BACKUPS_DIR/apps/$name"
  [ "$BACKUPS_PRESENT" = "1" ] || return 0
  if [ -d "$dir/home" ]; then
    run rsync -a "$dir/home/" "$HOME/"
    ok "  $name: config restored to \$HOME"
  fi
  if [ -d "$dir/root" ]; then
    run sudo rsync -a "$dir/root/" /
    ok "  $name: config restored to /"
  fi
}

install_app() {
  local name="$1" itype icmd check pkg
  itype="$(app_get "$name" '.install_type')"
  [ -n "$itype" ] || { warn "  app '$name' has no install_type — skipping."; return 0; }
  icmd="$(app_get "$name" '.install_command')"
  check="$(app_get "$name" '.check_cmd')"
  pkg="$(app_get "$name" '.package')"
  [ -n "$pkg" ] || pkg="$name"

  # Dependencies are auto-installed with the app; they are never separate
  # inventory items (AGENTS.md principle 4).
  local -a deps=() d
  while IFS= read -r d; do
    [ -n "$d" ] && deps+=("$d")
  done < <(yq -r ".apps[] | select(.name == \"$name\") | .depends_apt[]?" "$INVENTORY_FILE")
  if [ "${#deps[@]}" -gt 0 ]; then
    info "  $name: installing dependencies: ${deps[*]}"
    run sudo apt-get install -y "${deps[@]}"
  fi

  if [ -n "$check" ] && command -v "$check" >/dev/null 2>&1; then
    ok "  $name: already installed (found '$check')"
  else
    case "$itype" in
      apt)          run sudo apt-get install -y "$pkg" ;;
      snap)         run sudo snap install "$pkg" ;;
      snap-classic) run sudo snap install --classic "$pkg" ;;
      flatpak)      run flatpak install -y flathub "$pkg" ;;
      npm-global)   run sudo npm install -g "$name"@latest ;;
      pipx)         run pipx install "$name" ;;
      cargo)        run cargo install "$name" ;;
      script|custom)
        [ -n "$icmd" ] || die "  app '$name' uses install_type '$itype' but has no install_command."
        if [ "$DRY_RUN" = "1" ]; then
          printf '[dry-run] install %s: %s\n' "$name" "$icmd"
        else
          info "  $name: running official installer..."
          bash -c "$icmd" || warn "  install command for '$name' failed (exit $?)."
        fi
        ;;
      *) warn "  app '$name': unknown install_type '$itype' — skipping." ;;
    esac
  fi

  restore_app_config "$name"
}

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
    if [ "$BACKUPS_PRESENT" = "1" ] && [ -f "$sdir/unit" ]; then
      if [ "$target" = "user" ]; then
        dest="$HOME/.config/systemd/user/$unit"
        run mkdir -p "$HOME/.config/systemd/user"
        run cp "$sdir/unit" "$dest"
        run systemctl --user daemon-reload
        [ "$enable" = "true" ] && run systemctl --user enable "$unit"
        [ "$start" = "true" ] && run systemctl --user start "$unit"
      else
        dest="/etc/systemd/system/$unit"
        run sudo cp "$sdir/unit" "$dest"
        run sudo systemctl daemon-reload
        [ "$enable" = "true" ] && run sudo systemctl enable "$unit"
        [ "$start" = "true" ] && run sudo systemctl start "$unit"
      fi
      # Restore any config files declared for this service (env file, config dir...).
      if [ -d "$sdir/home" ]; then
        run rsync -a "$sdir/home/" "$HOME/"
        ok "  $unit: config restored to \$HOME"
      fi
      if [ -d "$sdir/root" ]; then
        run sudo rsync -a "$sdir/root/" /
        ok "  $unit: config restored to /"
      fi
      ok "  service: $unit ($target)"
    else
      warn "  service '$unit': no unit file in backups/ — skipping."
    fi
  done < <(yq -r '.services[] | [.unit, (.target // "system"), (.enable // false | tostring), (.start // false | tostring)] | @tsv' "$INVENTORY_FILE")
}

restore_services

# --- Phase 5: dotfiles + user dirs -------------------------------------------
info "Phase 5/5: dotfiles & user dirs"

restore_dotfiles() {
  local df
  while IFS= read -r df; do
    [ -n "$df" ] || continue
    if [ "$BACKUPS_PRESENT" = "1" ] && [ -f "$BACKUPS_DIR/dotfiles/$df" ]; then
      run cp "$BACKUPS_DIR/dotfiles/$df" "$HOME/$df"
      ok "  dotfile: $df"
    else
      warn "  dotfile '$df': no backup — skipping."
    fi
  done < <(yaml_list '.dotfiles[]')
}

restore_dotfiles

# Whole user-data folders declared as user_dirs (e.g. ~/Documents).
restore_user_dirs() {
  local d rel src
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$BACKUPS_PRESENT" != "1" ]; then
      warn "  user dir '$d': no backups — skipping."
      continue
    fi
    src="$(expand_path "$d")"
    if [ "$src" = "$HOME" ]; then
      warn "  user dir '$d': \$HOME itself cannot be restored this way — skipping."
      continue
    fi
    case "$src" in
      "$HOME"/*) : ;;
      *) warn "  user dir '$d': not under \$HOME — skipping." ; continue ;;
    esac
    rel="${src#"$HOME"/}"
    if [ -d "$BACKUPS_DIR/user-dirs/$rel" ]; then
      run mkdir -p "$HOME/$rel"
      run rsync -a "$BACKUPS_DIR/user-dirs/$rel/" "$HOME/$rel/"
      ok "  user dir: $d restored"
    else
      warn "  user dir '$d': no backup in backups/user-dirs — skipping."
    fi
  done < <(yaml_list '.user_dirs[]')
}

restore_user_dirs

# --- Wrap-up ---------------------------------------------------------------
echo
ok "Restore complete."
if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run — nothing was executed)"
  exit 0
fi
echo
echo "Next steps:"
echo "  1. Review the output above for warnings."
echo "  2. Reboot so services and configuration take full effect."
echo "  3. Keep everything current with ./update_all_ubuntu.sh"
