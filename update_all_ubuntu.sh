#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# update_all_ubuntu.sh — keep the base system and all inventory-declared apps
# up to date. Version-agnostic by design: everything goes to the latest stable.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

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

info "4/5 — npm + npm-global apps"
if command -v npm >/dev/null 2>&1; then
  sudo npm install -g npm@latest && _ok_update "npm upgraded" || _warn_fail "npm upgrade failed"
else
  _info_skip
fi

info "5/5 — Inventory apps (npm-global/pipx/cargo/custom/script)"
if [ -f "$INVENTORY_FILE" ] && command -v yq >/dev/null 2>&1; then
  while IFS=$'\t' read -r name itype icmd pkg; do
    [ -n "$name" ] || continue
    case "$itype" in
      npm-global)
        if command -v npm >/dev/null 2>&1; then
          sudo npm update -g "$name" && _ok_update "$name (npm)" || _warn_fail "$name (npm)"
        else
          _info_skip
        fi ;;
      pipx)
        if command -v pipx >/dev/null 2>&1; then
          pipx upgrade "$name" && _ok_update "$name (pipx)" || _warn_fail "$name (pipx)"
        else
          _info_skip
        fi ;;
      cargo)
        if command -v cargo >/dev/null 2>&1; then
          cargo install "$name" && _ok_update "$name (cargo)" || _warn_fail "$name (cargo)"
        else
          _info_skip
        fi ;;
      script|custom)
        if [ -n "$icmd" ] && confirm "  $name: re-run official installer to update?" "n"; then
          bash -o pipefail -c "$icmd" && _ok_update "$name (installer)" || _warn_fail "$name (installer)"
        else
          _info_skip
        fi ;;
      apt|snap|snap-classic|flatpak)
        _ok_update "$name ($itype — covered by base update)" ;;
      *)
        _info_skip ;;
    esac
  done < <(yq -r '.apps[] | [.name, .install_type, (.install_command // ""), (.package // "")] | @tsv' "$INVENTORY_FILE" || true)
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
