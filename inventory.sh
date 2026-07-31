#!/bin/bash
# ---------------------------------------------------------------------------
# inventory.sh — the MANUAL tool for declaring what to back up & restore.
#
# This is your (the user's) responsibility to run. It only edits
# inventory/inventory.yaml — it never touches the system.
#
#   ./inventory.sh                          # same as: list
#   ./inventory.sh list                     # show everything declared + status
#   ./inventory.sh add-package apt|snap|flatpak <name>
#   ./inventory.sh remove-package apt|snap|flatpak <name>
#   ./inventory.sh add-app <name>           # interactive wizard (catalog-aware)
#   ./inventory.sh remove-app <name>
#   ./inventory.sh add-service              # interactive wizard
#   ./inventory.sh remove-service <unit>
#   ./inventory.sh review                   # suggest undeclared apps found on this system
#   ./inventory.sh wizard                   # guided: scan the system, declare apps one by one
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$LIB_DIR/catalog.sh"

YQ_AUTO=2   # interactive tool: if yq is missing, ask the user to install it

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"

usage() {
  cat <<EOF
Usage: ./inventory.sh <command> [args]

Commands:
  list                                   Show the current inventory + installed status
  add-package apt|snap|flatpak <name>    Add a package to a list
  remove-package apt|snap|flatpak <name> Remove a package from a list
  add-app <name>                         Declare an app (interactive wizard)
  remove-app <name>                      Remove an app declaration
  add-service                            Declare a custom service (interactive wizard)
  remove-service <unit>                  Remove a service declaration (e.g. myservice.service)
  review                                 Suggest apps found on this system, not yet declared
  wizard                                 Guided: scan the system and declare apps one by one
EOF
}

# Minimal YAML double-quote escaping for values written into inventory.yaml.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# ---------------------------------------------------------------------------
# list
# ---------------------------------------------------------------------------
print_plain_list() {
  local key="$1" label="$2" item base
  echo "  $label"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    base="${item%%:*}"
    case "$key" in
      apt_packages)
        if is_apt_installed "$base"; then echo "    [x] $item"; else echo "    [ ] $item"; fi
        ;;
      snap_packages)
        if [ "${item##*:}" = "classic" ]; then
          if is_snap_installed "$base"; then echo "    [x] $item (classic)"; else echo "    [ ] $item (classic)"; fi
        else
          if is_snap_installed "$base"; then echo "    [x] $item"; else echo "    [ ] $item"; fi
        fi
        ;;
      flatpak_apps)
        if is_flatpak_installed "$base"; then echo "    [x] $item"; else echo "    [ ] $item"; fi
        ;;
      dotfiles)
        if [ -e "$HOME/$base" ]; then echo "    [x] $item"; else echo "    [ ] $item"; fi
        ;;
    esac
  done < <(yaml_list ".$key[]")
}

cmd_list() {
  require_yq
  echo "Inventory: $INVENTORY_FILE"
  echo
  echo "=== Packages ==="
  print_plain_list apt_packages "APT:"
  print_plain_list snap_packages "SNAP:"
  print_plain_list flatpak_apps "FLATPAK:"
  echo
  echo "=== Dotfiles ==="
  print_plain_list dotfiles "(in \$HOME):"
  echo
  echo "=== Apps ==="
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    itype="$(app_get "$name" '.install_type')"
    if is_app_installed "$name"; then
      printf '    [x] %-16s %s\n' "$name" "${itype:-?}"
    else
      printf '    [ ] %-16s %s\n' "$name" "${itype:-?}"
    fi
  done < <(yaml_list '.apps[] | .name')
  echo
  echo "=== Services ==="
  while IFS=$'\t' read -r unit target; do
    [ -n "$unit" ] || continue
    if [ "$target" = "user" ]; then
      if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then echo "    [x] $unit (user)"; else echo "    [ ] $unit (user)"; fi
    else
      if systemctl is-enabled "$unit" >/dev/null 2>&1; then echo "    [x] $unit (system)"; else echo "    [ ] $unit (system)"; fi
    fi
  done < <(yq -r '.services[] | [.unit, (.target // "system")] | @tsv' "$INVENTORY_FILE")
}

# ---------------------------------------------------------------------------
# add-package / remove-package
# ---------------------------------------------------------------------------
_package_key() {
  case "$1" in
    apt) echo apt_packages ;;
    snap) echo snap_packages ;;
    flatpak) echo flatpak_apps ;;
    *) echo "" ;;
  esac
}

cmd_add_package() {
  local type="${1:-}" name="${2:-}" key
  key="$(_package_key "$type")"
  [ -n "$key" ] || die "Package type must be apt, snap or flatpak."
  if [ -z "$name" ]; then
    printf '%s package name: ' "$type"
    read -r name
  fi
  [ -n "$name" ] || die "Package name required."
  if [ "$type" = "snap" ] && [ -z "${2:-}" ]; then
    if confirm "Does '$name' need classic confinement?" "n"; then
      name="$name:classic"
    fi
  fi
  if yaml_list ".$key[]" | grep -qx "$name"; then
    warn "'$name' is already in the $key list."
    return 0
  fi
  yq -i --arg p "$name" ".$key += [\$p]" "$INVENTORY_FILE"
  ok "Added $type package '$name'."
}

cmd_remove_package() {
  local type="${1:-}" name="${2:-}" key
  key="$(_package_key "$type")"
  [ -n "$key" ] || die "Package type must be apt, snap or flatpak."
  [ -n "$name" ] || die "Usage: ./inventory.sh remove-package $type <name>"
  if ! yaml_list ".$key[]" | grep -qx "$name"; then
    warn "'$name' is not in the $key list."
    return 0
  fi
  yq -i --arg p "$name" ".$key |= map(select(. != \$p))" "$INVENTORY_FILE"
  ok "Removed $type package '$name'."
}

# ---------------------------------------------------------------------------
# add-app (wizard) / remove-app
# ---------------------------------------------------------------------------
write_app() {
  local name="$1" desc="$2" itype="$3" icmd="$4" check="$5" deps="$6" paths="$7"
  local tmp="/tmp/inv-app-${name}.yaml" d
  {
    printf -- '- name: "%s"\n' "$(esc "$name")"
    [ -n "$desc" ] && printf '  description: "%s"\n' "$(esc "$desc")"
    printf '  install_type: "%s"\n' "$(esc "$itype")"
    [ -n "$icmd" ] && printf '  install_command: "%s"\n' "$(esc "$icmd")"
    [ -n "$check" ] && printf '  check_cmd: "%s"\n' "$(esc "$check")"
    if [ -n "$deps" ]; then
      echo "  depends_apt:"
      for d in $deps; do printf '    - "%s"\n' "$(esc "$d")"; done
    fi
    if [ -n "$paths" ]; then
      echo "  config_paths:"
      for d in $paths; do printf '    - "%s"\n' "$(esc "$d")"; done
    fi
  } > "$tmp"
  yq -i '.apps += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

write_service() {
  local unit="$1" target="$2" enable="$3" start="$4" paths="$5"
  local tmp="/tmp/inv-service.yaml" d
  {
    printf -- '- unit: "%s"\n' "$(esc "$unit")"
    printf '  target: %s\n' "$target"
    printf '  enable: %s\n' "$enable"
    printf '  start: %s\n' "$start"
    if [ -n "$paths" ]; then
      echo "  config_paths:"
      for d in $paths; do printf '    - "%s"\n' "$(esc "$d")"; done
    fi
  } > "$tmp"
  yq -i '.services += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

cmd_add_app() {
  local name="${1:-}" desc="" itype="" icmd="" check="" deps="" paths=""
  if [ -z "$name" ]; then
    printf 'App name (e.g. opencode): '
    read -r name
  fi
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
  [ -n "$name" ] || die "Invalid app name."
  if yaml_list '.apps[] | .name' | grep -qx "$name"; then
    die "App '$name' is already in the inventory."
  fi

  local template
  template="$(catalog_lookup "$name")"
  if [ -n "$template" ]; then
    while IFS='=' read -r k v; do
      [ -n "$k" ] && printf -v "$k" '%s' "$v"
    done <<<"$template"
    echo "Found '$name' in the built-in catalog:"
    [ -n "${description:-}" ] && echo "  ${description}"
    echo "  install_type:   ${install_type:-?}"
    [ -n "${install_command:-}" ] && echo "  install_command: ${install_command}"
    [ -n "${config_paths:-}" ] && echo "  config_paths:    ${config_paths}"
    if confirm "Use these defaults?" "y"; then
      write_app "$name" "${description:-}" "$install_type" "${install_command:-}" \
        "${check_cmd:-}" "${depends_apt:-}" "${config_paths:-}"
      ok "Added app '$name'."
      return 0
    fi
    # User declined the catalog defaults -> run the full manual wizard instead.
    desc=""; itype=""; icmd=""; check=""; deps=""; paths=""
    unset description install_type install_command check_cmd depends_apt config_paths
    echo
    echo "Running the manual wizard instead."
  fi

  if [ -z "$itype" ]; then
    echo "Install method for '$name':"
    local i=1 t
    for t in apt snap snap-classic flatpak npm-global pipx cargo script custom; do
      echo "  $i) $t"
      i=$((i + 1))
    done
    printf 'Select [1-9]: '
    read -r sel
    itype="$(printf '%s\n' 'apt snap snap-classic flatpak npm-global pipx cargo script custom' | awk -v n="$sel" '{print $n}')"
    [ -n "$itype" ] || die "Invalid selection."
  fi

  if [ "$itype" = "script" ] || [ "$itype" = "custom" ]; then
    if [ -z "$icmd" ]; then
      printf 'Install command: '
      read -r icmd
      [ -n "$icmd" ] || die "An install command is required for $itype."
    fi
  fi
  if [ -z "$check" ]; then
    printf 'Binary to check for "already installed" (optional): '
    read -r check
  fi
  # Dependencies are NOT asked here on purpose (AGENTS.md principle 4): the
  # user only thinks about the main app. depends_apt is set from the catalog
  # or edited directly in inventory.yaml if ever needed.

  # Detect existing config locations for this app.
  local candidates=() c i=1 selected n
  for c in "$HOME/.config/$name" "$HOME/.$name" "$HOME/.local/share/$name"; do
    [ -e "$c" ] && candidates+=("$c")
  done
  if [ "${#candidates[@]}" -gt 0 ] && [ -z "$paths" ]; then
    echo "Existing config locations detected for '$name':"
    i=1
    for c in "${candidates[@]}"; do
      echo "  $i) $c"
      i=$((i + 1))
    done
    printf 'Select (space-separated numbers, or blank for none): '
    read -r -a selected
    paths=""
    if [ "${#selected[@]}" -gt 0 ]; then
      for n in "${selected[@]}"; do
        c="${candidates[$((n - 1))]}"
        [ -n "$c" ] || continue
        paths="$paths ${c/#$HOME\//~\/}"
      done
      paths="${paths# }"
    fi
  fi

  write_app "$name" "$desc" "$itype" "$icmd" "$check" "$deps" "$paths"
  ok "Added app '$name'."
}

cmd_remove_app() {
  local name="${1:-}"
  [ -n "$name" ] || die "Usage: ./inventory.sh remove-app <name>"
  if ! yaml_list '.apps[] | .name' | grep -qx "$name"; then
    warn "App '$name' is not in the inventory."
    return 0
  fi
  yq -i --arg n "$name" '.apps |= map(select(.name != $n))' "$INVENTORY_FILE"
  ok "Removed app '$name'."
}

# ---------------------------------------------------------------------------
# add-service (wizard) / remove-service
# ---------------------------------------------------------------------------
cmd_add_service() {
  local unit="" target="system" src="" sel=""
  printf 'Unit file name (e.g. myservice.service): '
  read -r unit
  [ -n "$unit" ] || die "Unit name required."
  if yaml_list '.services[] | .unit' | grep -qx "$unit"; then
    die "Service '$unit' is already in the inventory."
  fi
  echo "Where does this service live?"
  echo "  1) system  (/etc/systemd/system)"
  echo "  2) user    (~/.config/systemd/user)"
  printf 'Select [1-2]: '
  read -r sel
  [ "$sel" = "2" ] && target="user"

  if [ "$target" = "user" ]; then
    src="$HOME/.config/systemd/user/$unit"
  else
    src="/etc/systemd/system/$unit"
  fi
  if [ -f "$src" ]; then
    if confirm "Copy the unit file from $src into backups/ now?" "y"; then
      mkdir -p "$BACKUPS_DIR/services/$unit"
      cp "$src" "$BACKUPS_DIR/services/$unit/unit"
      ok "Copied $unit -> backups/services/$unit/unit"
    fi
  else
    warn "Unit file not found at $src. It will only be restorable after backup.sh captures it."
  fi

  local enable="false" start="false"
  confirm "Enable on boot?" "y" && enable="true"
  confirm "Start after restore?" "y" && start="true"

  # Optional config files this service needs (env file, config dir, helper script...).
  local paths="" p norm=""
  printf 'Config paths this service needs (space-separated, optional): '
  read -r paths
  if [ -n "$paths" ]; then
    for p in $paths; do
      norm="$norm ${p/#$HOME\//~\/}"
    done
    paths="${norm# }"
  fi

  write_service "$unit" "$target" "$enable" "$start" "$paths"
  ok "Added service '$unit'."
}

cmd_remove_service() {
  local unit="${1:-}"
  [ -n "$unit" ] || die "Usage: ./inventory.sh remove-service <unit>"
  if ! yaml_list '.services[] | .unit' | grep -qx "$unit"; then
    warn "Service '$unit' is not in the inventory."
    return 0
  fi
  yq -i --arg u "$unit" '.services |= map(select(.unit != $u))' "$INVENTORY_FILE"
  ok "Removed service '$unit'."
}

# ---------------------------------------------------------------------------
# review / wizard — find undeclared apps on this system
# ---------------------------------------------------------------------------
# Candidates = top-level ~/.config dirs that are not OS noise and not declared.
scan_candidates() {
  local noise="dconf gtk-3.0 gtk-4.0 pulse ibus gnome-session user-dirs.dirs enchant glib-2.0 xdg goa-1.0 evolution tracker3 nautilus gedit mimeapps.list autostart"
  local d base
  for d in "$HOME"/.config/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    echo "$noise" | grep -qw "$base" && continue
    yaml_list '.apps[] | .name' | grep -qx "$base" && continue
    printf '%s\n' "$base"
  done
}

cmd_review() {
  require_yq
  echo "Apps found on this system that are NOT declared in the inventory:"
  echo
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if command -v "$base" >/dev/null 2>&1; then
      printf '  [%s] %s  (binary: %s)\n' "config" "$base" "$(command -v "$base")"
    else
      printf '  [%s] %s\n' "config" "$base"
    fi
  done < <(scan_candidates)
  echo
  echo "Declare any of these with: ./inventory.sh add-app <name>"
}

cmd_wizard() {
  require_yq
  echo "Wizard — declare apps found on this system, one at a time:"
  echo
  local base declared=0
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    if confirm "Declare '$base'?" "n"; then
      cmd_add_app "$base"
      declared=$((declared + 1))
    fi
  done < <(scan_candidates)
  if [ "$declared" -eq 0 ]; then
    echo "Nothing new declared."
  fi
  echo
  echo "Run ./inventory.sh list to review the result."
}

# ---------------------------------------------------------------------------
cmd="${1:-list}"
case "$cmd" in
  list)            shift; cmd_list "$@" ;;
  add-package)     shift; cmd_add_package "$@" ;;
  remove-package)  shift; cmd_remove_package "$@" ;;
  add-app)         shift; cmd_add_app "$@" ;;
  remove-app)      shift; cmd_remove_app "$@" ;;
  add-service)     shift; cmd_add_service "$@" ;;
  remove-service)  shift; cmd_remove_service "$@" ;;
  review)          shift; cmd_review "$@" ;;
  wizard)          shift; cmd_wizard "$@" ;;
  -h|--help|help)  usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
