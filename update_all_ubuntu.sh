#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_all_ubuntu.sh — keep the base system and all inventory-declared apps
# up to date. Version-agnostic by design: everything goes to the latest stable.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/installers.sh"

UPD_OK=0
UPD_SKIPPED=0
UPD_FAILED=0

_info_skip() { info "  skipped — not installed"; UPD_SKIPPED=$((UPD_SKIPPED + 1)); }
_ok_update()  { ok   "  $1";                 UPD_OK=$((UPD_OK + 1)); }
_warn_fail()  { warn "  $1";                 UPD_FAILED=$((UPD_FAILED + 1)); }

info "1/5 — APT"
sudo apt-get update
sudo apt-get full-upgrade -y && _ok_update "apt upgraded" || _warn_fail "apt upgrade failed"
sudo apt-get autoremove -y || true

info "2/5 — Snap"
if command -v snap >/dev/null 2>&1; then
  sudo snap refresh && _ok_update "snap refreshed" || _warn_fail "snap refresh failed"
else
  _info_skip
fi

info "3/5 — Flatpak"
if command -v flatpak >/dev/null 2>&1; then
  flatpak update -y && _ok_update "flatpak updated" || _warn_fail "flatpak update failed"
else
  _info_skip
fi

info "4/5 — npm + npm global apps"
if command -v npm >/dev/null 2>&1; then
  sudo npm install -g npm@latest && _ok_update "npm upgraded" || _warn_fail "npm upgrade failed"
else
  _info_skip
fi

info "5/5 — Inventory apps (npm_global/pipx/cargo/script/deb/tarball)"
if [ -f "$INVENTORY_FILE" ] && command -v yq >/dev/null 2>&1; then
  # Expand `catalog:` references (schema v5) so the update loop sees the
  # RESOLVED installer records. $INVENTORY_READ points at the effective file.
  resolve_effective_inventory
  while IFS=$'\t' read -r name itype pkg; do
    [ -n "$name" ] || continue
    case "$itype" in
      npm_global)
        if command -v npm >/dev/null 2>&1; then
          sudo npm update -g "${pkg:-$name}" && _ok_update "$name (npm)" || _warn_fail "$name (npm)"
        else
          _info_skip
        fi ;;
      pipx)
        if command -v pipx >/dev/null 2>&1; then
          pipx upgrade "${pkg:-$name}" && _ok_update "$name (pipx)" || _warn_fail "$name (pipx)"
        else
          _info_skip
        fi ;;
      cargo)
        if command -v cargo >/dev/null 2>&1; then
          cargo install "${pkg:-$name}" && _ok_update "$name (cargo)" || _warn_fail "$name (cargo)"
        else
          _info_skip
        fi ;;
      script|deb|tarball)
        # No prompt: this is an unattended updater (every other step is -y),
        # and re-running the typed installer IS the update for these types.
        # Gate on the app being installed so an update never installs a
        # declared-but-not-yet-installed app.
        if is_app_installed "$name"; then
          if installer_run "$name"; then _ok_update "$name ($itype)"; else _warn_fail "$name ($itype)"; fi
        else
          _info_skip
        fi ;;
      apt|apt_repository|snap|snap_classic|flatpak)
        _ok_update "$name ($itype — covered by base update)" ;;
      *)
        _info_skip ;;
    esac
  done < <(yq -r '.apps[] | [.name, .installer.type, (.installer.package // "")] | @tsv' "$INVENTORY_READ" || true)
else
  warn "  Inventory not found or yq missing; skipping declared app updates."
  UPD_SKIPPED=$((UPD_SKIPPED + 1))
fi

echo
echo "Summary: ${UPD_OK} updated / ${UPD_SKIPPED} skipped / ${UPD_FAILED} failed"
if [ "$UPD_FAILED" -gt 0 ]; then
  warn "Some updates failed — review the output above."
  exit 1
else
  ok "All updates finished."
fi
