#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_all_ubuntu.sh — keep the base system and all inventory-declared apps
# up to date. Version-agnostic by design: everything goes to the latest stable.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

info "1/4 — APT"
sudo apt-get update
sudo apt-get full-upgrade -y
sudo apt-get autoremove -y

info "2/4 — Snap"
if command -v snap >/dev/null 2>&1; then
  sudo snap refresh || true
else
  echo "  snap not installed; skipping."
fi

info "3/4 — Flatpak"
if command -v flatpak >/dev/null 2>&1; then
  flatpak update -y || true
else
  echo "  flatpak not installed; skipping."
fi

info "4/4 — Inventory apps (npm/pipx/cargo) + npm"
if command -v npm >/dev/null 2>&1; then
  sudo npm install -g npm@latest || true
else
  echo "  npm not installed; skipping npm."
fi

if [ -f "$INVENTORY_FILE" ] && command -v yq >/dev/null 2>&1; then
  while IFS=$'\t' read -r name itype; do
    [ -n "$name" ] || continue
    case "$itype" in
      npm-global) sudo npm update -g "$name" || true ;;
      pipx)       pipx upgrade "$name" || true ;;
      cargo)      cargo install "$name" || true ;;
    esac
  done < <(yq -r '.apps[] | [.name, .install_type] | @tsv' "$INVENTORY_FILE" || true)
fi

ok "All updates finished."
