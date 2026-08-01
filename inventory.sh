#!/bin/bash
# ---------------------------------------------------------------------------
# inventory.sh — the MANUAL tool for declaring what to back up & restore.
#
# This is your (the user's) responsibility to run. It only edits
# inventory/inventory.yaml — it never touches the system (except for the
# optional service unit copy in add-service).
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/catalog.sh"

YQ_AUTO=2

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"

usage() {
  cat <<EOF
Usage: ./inventory.sh <command> [args]

Commands:
  list                                   Show the current inventory + installed status
  validate                               Validate inventory.yaml schema and semantics
  add-package apt|snap|flatpak <name>    Add a package to a list
  remove-package apt|snap|flatpak <name> Remove a package from a list
  add-app <name>                         Declare an app (interactive wizard)
  remove-app <name>                      Remove an app declaration
  add-service                            Declare a custom service (interactive wizard)
  remove-service <unit>                  Remove a service declaration (e.g. myservice.service)
  add-user-dir <path>                    Declare a whole user-data folder (e.g. ~/Documents)
  remove-user-dir <path>                 Remove a user-dir declaration
  review                                 Suggest apps found on this system, not yet declared
  wizard                                 Guided: scan the system and declare apps one by one
EOF
}

esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- validate ------------------------------------------------------------
cmd_validate() {
  if validate_inventory; then
    ok "Inventory is valid."
  else
    die "Inventory has issues — see warnings above."
  fi
}

# --- list ----------------------------------------------------------------
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
  done < <(yaml_list ".${key}[]")
}

cmd_list() {
  require_yq "$YQ_AUTO"
  echo "Inventory: $INVENTORY_FILE"
  echo

  local app_count
  app_count="$(yaml_list '.apps[] | .name' | { grep -c . 2>/dev/null || true; })"
  app_count="${app_count:-0}"
  echo "=== Apps ($app_count) ==="
  # Single yq pass to extract all app metadata — avoids repeated yq invocations
  # which have significant startup overhead (especially with snap yq).
  while IFS=$'\t' read -r name itype check pkg cfg_cnt dep_cnt; do
    [ -n "$name" ] || continue
    # Convert sentinel empty-string markers back.
    [ "$pkg" = "___EMPTY___" ] && pkg=""
    local tags="  ${itype:-?}"
    [ -n "$pkg" ] && tags="$tags  pkg=$pkg"
    [ "${cfg_cnt:-0}" -gt 0 ] && tags="$tags  configs=$cfg_cnt"
    [ "${dep_cnt:-0}" -gt 0 ] && tags="$tags  deps=$dep_cnt"
    [ "${cfg_cnt:-0}" -eq 0 ] && [ "$itype" != "snap" ] && tags="$tags  (no config)"
    if is_app_installed "$name"; then
      printf '    [x] %-20s %s\n' "$name" "$tags"
    else
      printf '    [ ] %-20s %s\n' "$name" "$tags"
    fi
  done < <(yq -r '
    .apps[] | [
      .name,
      (.install_type // "___EMPTY___"),
      (.check_cmd // "___EMPTY___"),
      (.package // "___EMPTY___"),
      ((.config_paths // []) | length),
      ((.depends_apt   // []) | length)
    ] | @tsv
  ' "$INVENTORY_FILE")
  echo

  echo "=== Packages ==="
  print_plain_list apt_packages "APT:"
  print_plain_list snap_packages "SNAP:"
  print_plain_list flatpak_apps "FLATPAK:"
  echo

  echo "=== Dotfiles ==="
  print_plain_list dotfiles "(in \$HOME):"
  echo

  echo "=== User dirs ==="
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ -d "$(expand_path "$d")" ]; then
      echo "    [x] $d"
    else
      echo "    [ ] $d"
    fi
  done < <(yaml_list '.user_dirs[]')
  echo

  echo "=== Services ==="
  while IFS=$'\t' read -r unit target enable start; do
    [ -n "$unit" ] || continue
    [ "$target" = "user" ] || target="system"
    local tags="$target"
    [ "$enable" = "true" ] && tags="$tags  enabled"
    [ "$start" = "true" ] && tags="$tags  start"
    if [ "$target" = "user" ]; then
      if systemctl --user is-enabled "$unit" >/dev/null 2>&1; then echo "    [x] $unit ($tags)"; else echo "    [ ] $unit ($tags)"; fi
    else
      if systemctl is-enabled "$unit" >/dev/null 2>&1; then echo "    [x] $unit ($tags)"; else echo "    [ ] $unit ($tags)"; fi
    fi
  done < <(yq -r '.services[] | [.unit, (.target // "system"), (.enable // false | tostring), (.start // false | tostring)] | @tsv' "$INVENTORY_FILE")
}

# --- add-package / remove-package -----------------------------------------
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
  if yaml_list ".${key}[]" | grep -Fqx "$name"; then
    warn "'$name' is already in the $key list."
    return 0
  fi
  P="$name" yq -i ".$key += [strenv(P)]" "$INVENTORY_FILE"
  ok "Added $type package '$name'."
}

cmd_remove_package() {
  local type="${1:-}" name="${2:-}" key
  key="$(_package_key "$type")"
  [ -n "$key" ] || die "Package type must be apt, snap or flatpak."
  [ -n "$name" ] || die "Usage: ./inventory.sh remove-package $type <name>"
  if ! yaml_list ".${key}[]" | grep -Fqx "$name"; then
    warn "'$name' is not in the $key list."
    return 0
  fi
  P="$name" yq -i ".$key |= map(select(. != strenv(P)))" "$INVENTORY_FILE"
  ok "Removed $type package '$name'."
}

# --- add-app (wizard) / remove-app ----------------------------------------
write_app() {
  local name="$1" desc="$2" itype="$3" icmd="$4" check="$5" deps="$6" paths="$7" pkg="${8:-}" excl="${9:-}"
  local tmp
  tmp="$(mktemp)"
  {
    printf -- '- name: "%s"\n' "$(esc "$name")"
    [ -n "$desc" ] && printf '  description: "%s"\n' "$(esc "$desc")"
    printf '  install_type: "%s"\n' "$(esc "$itype")"
    [ -n "$icmd" ] && printf '  install_command: "%s"\n' "$(esc "$icmd")"
    [ -n "$check" ] && printf '  check_cmd: "%s"\n' "$(esc "$check")"
    [ -n "$pkg" ] && printf '  package: "%s"\n' "$(esc "$pkg")"
    if [ -n "$deps" ]; then
      echo "  depends_apt:"
      for d in $deps; do printf '    - "%s"\n' "$(esc "$d")"; done
    fi
    if [ -n "$paths" ]; then
      echo "  config_paths:"
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        printf '    - "%s"\n' "$(esc "$d")"
      done <<< "$paths"
    fi
    if [ -n "$excl" ]; then
      echo "  exclude:"
      local -a e_arr=()
      read -ra e_arr <<< "$excl"
      for e in "${e_arr[@]}"; do
        printf '    - "%s"\n' "$(esc "$e")"
      done
    fi
  } > "$tmp"
  yq -i '.apps += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

write_service() {
  local unit="$1" target="$2" enable="$3" start="$4" paths="$5"
  local tmp
  tmp="$(mktemp)"
  {
    printf -- '- unit: "%s"\n' "$(esc "$unit")"
    printf '  target: %s\n' "$target"
    printf '  enable: %s\n' "$enable"
    printf '  start: %s\n' "$start"
    if [ -n "$paths" ]; then
      echo "  config_paths:"
      while IFS= read -r d; do
        [ -n "$d" ] || continue
        printf '    - "%s"\n' "$(esc "$d")"
      done <<< "$paths"
    fi
  } > "$tmp"
  yq -i '.services += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

cmd_add_app() {
  local name="${1:-}" desc="" itype="" icmd="" check="" deps="" paths="" pkg="" excl=""
  if [ -z "$name" ]; then
    printf 'App name (e.g. opencode): '
    read -r name
  fi
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
  [ -n "$name" ] || die "Invalid app name."
  if yaml_list '.apps[] | .name' | grep -Fqx "$name"; then
    die "App '$name' is already in the inventory."
  fi

  local template
  template="$(catalog_lookup "$name")"
  if [ -n "$template" ]; then
    while IFS='=' read -r k v; do
      [ -n "$k" ] || continue
      if [ -n "${!k:-}" ]; then
        printf -v "$k" '%s\n%s' "${!k}" "$v"
      else
        printf -v "$k" '%s' "$v"
      fi
    done <<<"$template"
    echo "Found '$name' in the built-in catalog:"
    [ -n "${description:-}" ] && echo "  ${description}"
    echo "  install_type:   ${install_type:-?}"
    [ -n "${install_command:-}" ] && echo "  install_command: ${install_command}"
    [ -n "${config_paths:-}" ] && echo "  config_paths:    ${config_paths//$'\n'/ }"
    if confirm "Use these defaults?" "y"; then
      write_app "$name" "${description:-}" "$install_type" "${install_command:-}" \
        "${check_cmd:-}" "${depends_apt:-}" "${config_paths:-}" "${package:-}" "${exclude:-}"
      ok "Added app '$name'."
      return 0
    fi
    desc=""; itype=""; icmd=""; check=""; deps=""; paths=""; pkg=""; excl=""
    unset description install_type install_command check_cmd depends_apt config_paths package exclude
    echo
    echo "Running the manual wizard instead."
  fi

  # Install method.
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
  case "$itype" in
    apt|snap|snap-classic|flatpak)
      if [ -z "$pkg" ]; then
        printf 'Package name if it differs from the app name (blank = "%s"): ' "$name"
        read -r pkg
      fi
      ;;
  esac
  if [ -z "$check" ]; then
    printf 'Binary to check for "already installed" (recommended): '
    read -r check
  fi

  # Dependencies — ask the user if they know them (catalog was already offered above).
  if [ -z "$deps" ]; then
    printf 'APT dependencies (space-separated, e.g. "nodejs npm" — optional): '
    read -r deps
  fi

  # Detect existing config locations.
  local candidates=() c i selected n ans
  for c in "$HOME/.config/$name" "$HOME/.$name" "$HOME/.local/share/$name"; do
    [ -e "$c" ] && candidates+=("$c")
  done
  # Also check common snap paths.
  if [ -d "$HOME/snap/$name/common" ]; then
    candidates+=("$HOME/snap/$name/common")
  fi
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
        paths+="${c/#$HOME\//~\/}"$'\n'
      done
      paths="${paths%$'\n'}"
    fi
  fi

  # Offer to add additional config paths.
  if [ -z "$paths" ]; then
    printf 'Config paths (space-separated, ~-form, optional): '
    read -r ans
    if [ -n "$ans" ]; then
      for c in $ans; do
        paths+="${c/#$HOME\//~\/}"$'\n'
      done
      paths="${paths%$'\n'}"
    fi
  fi
  if [ -n "$paths" ]; then
    echo "  Config paths declared:"
    while IFS= read -r p; do printf '    ~%s\n' "${p#~}"; done <<< "$paths"
  else
    warn "  No config paths declared — this app's settings will NOT be backed up or restored."
  fi

  write_app "$name" "$desc" "$itype" "$icmd" "$check" "$deps" "$paths" "$pkg" "$excl"
  ok "Added app '$name'."
}

cmd_remove_app() {
  local name="${1:-}"
  [ -n "$name" ] || die "Usage: ./inventory.sh remove-app <name>"
  if ! yaml_list '.apps[] | .name' | grep -Fqx "$name"; then
    warn "App '$name' is not in the inventory."
    return 0
  fi
  N="$name" yq -i '.apps |= map(select(.name != strenv(N)))' "$INVENTORY_FILE"
  ok "Removed app '$name'."
}

# --- add-service (wizard) / remove-service --------------------------------
cmd_add_service() {
  local unit="" target="system" src="" sel=""
  printf 'Unit file name (e.g. myservice.service): '
  read -r unit
  [ -n "$unit" ] || die "Unit name required."

  # Validate basic systemd unit name.
  if ! [[ "$unit" =~ ^[a-zA-Z0-9@._:-]+\.(service|timer|socket|path)$ ]]; then
    die "Invalid systemd unit name: '$unit'. Must end in .service/.timer/.socket/.path and contain no slashes or control characters."
  fi

  if yaml_list '.services[] | .unit' | grep -Fqx "$unit"; then
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

  local paths="" p norm=""
  printf 'Config paths this service needs (space-separated, optional): '
  read -r paths
  if [ -n "$paths" ]; then
    for p in $paths; do
      norm+="${p/#$HOME\//~\/}"$'\n'
    done
    paths="${norm%$'\n'}"
  fi

  write_service "$unit" "$target" "$enable" "$start" "$paths"
  ok "Added service '$unit'."
}

cmd_remove_service() {
  local unit="${1:-}"
  [ -n "$unit" ] || die "Usage: ./inventory.sh remove-service <unit>"
  if ! yaml_list '.services[] | .unit' | grep -Fqx "$unit"; then
    warn "Service '$unit' is not in the inventory."
    return 0
  fi
  U="$unit" yq -i '.services |= map(select(.unit != strenv(U)))' "$INVENTORY_FILE"
  ok "Removed service '$unit'."
}

# --- add-user-dir / remove-user-dir --------------------------------------
_norm_dir() {
  local p="$1"
  p="${p%/}"
  case "$p" in
    "$HOME"/*)
      # shellcheck disable=SC2088
      p="~/${p#"$HOME"/}"
      ;;
    "$HOME") p="~" ;;
    ~/*)     : ;;
    *)
      warn "Path must start with ~ or \$HOME (got: '$p')." >&2
      return 1
      ;;
  esac
  printf '%s\n' "$p"
}

cmd_add_user_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] || die "Usage: ./inventory.sh add-user-dir <path> (e.g. ~/Documents)"
  dir="$(_norm_dir "$dir")" || die "Invalid path."
  if yaml_list '.user_dirs[]' | grep -Fqx "$dir"; then
    warn "'$dir' is already in the user_dirs list."
    return 0
  fi
  [ -d "$(expand_path "$dir")" ] || warn "'$dir' does not exist yet — declared anyway (it will be captured once it exists)."
  P="$dir" yq -i ".user_dirs += [strenv(P)]" "$INVENTORY_FILE"
  ok "Added user dir '$dir'."
}

cmd_remove_user_dir() {
  local dir="${1:-}"
  [ -n "$dir" ] || die "Usage: ./inventory.sh remove-user-dir <path>"
  dir="$(_norm_dir "$dir")" || die "Invalid path."
  if ! yaml_list '.user_dirs[]' | grep -Fqx "$dir"; then
    warn "'$dir' is not in the user_dirs list."
    return 0
  fi
  P="$dir" yq -i ".user_dirs |= map(select(. != strenv(P)))" "$INVENTORY_FILE"
  ok "Removed user dir '$dir'."
}

# --- review / wizard -----------------------------------------------------
scan_candidates() {
  local noise="dconf gtk-3.0 gtk-4.0 pulse ibus gnome-session user-dirs.dirs enchant glib-2.0 xdg goa-1.0 evolution tracker3 nautilus gedit mimeapps.list autostart"
  local d base
  local declared_configs
  declared_configs="$(yq -r '.apps[].config_paths[]?' "$INVENTORY_FILE" | sed -n 's#.*/##p')"

  for d in "$HOME"/.config/*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    echo "$noise" | grep -Fwq "$base" && continue
    yaml_list '.apps[] | .name' | grep -Fqx "$base" && continue
    printf '%s\n' "$declared_configs" | grep -Fqx "$base" && continue
    printf '%s\n' "$base"
  done

  local sys_dirs="local cache share ssh gnupg snap npm cargo vscode vscode-server java dbus mozilla thunderbird . .."
  for d in "$HOME"/.*/; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    echo "$sys_dirs" | grep -Fwq "$base" && continue
    echo "$noise" | grep -Fwq "$base" && continue
    [[ "$base" != "." && "$base" != ".." ]] || continue
    yaml_list '.apps[] | .name' | grep -Fqx "$base" && continue
    printf '%s\n' "$declared_configs" | grep -Fqx "$base" && continue
    printf '%s\n' "$base"
  done
}

cmd_review() {
  require_yq "$YQ_AUTO"
  echo "Apps found on this system that are NOT declared in the inventory:"
  echo
  local found=0
  while IFS= read -r base; do
    [ -n "$base" ] || continue
    found=1
    if command -v "$base" >/dev/null 2>&1; then
      printf '  [%s] %s  (binary: %s)\n' "config" "$base" "$(command -v "$base")"
    else
      printf '  [%s] %s\n' "config" "$base"
    fi
  done < <(scan_candidates)
  if [ "$found" = "0" ]; then
    echo "  (none — all detected config dirs appear declared)"
  fi
  echo
  echo "Declare any of these with: ./inventory.sh add-app <name>"
}

cmd_wizard() {
  require_yq "$YQ_AUTO"
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

# --- dispatch -------------------------------------------------------------
cmd="${1:-list}"
case "$cmd" in
  list)            shift; cmd_list "$@" ;;
  validate)        shift; cmd_validate "$@" ;;
  add-package)     shift; cmd_add_package "$@" ;;
  remove-package)  shift; cmd_remove_package "$@" ;;
  add-app)         shift; cmd_add_app "$@" ;;
  remove-app)      shift; cmd_remove_app "$@" ;;
  add-service)     shift; cmd_add_service "$@" ;;
  remove-service)  shift; cmd_remove_service "$@" ;;
  add-user-dir)    shift; cmd_add_user_dir "$@" ;;
  remove-user-dir) shift; cmd_remove_user_dir "$@" ;;
  review)          shift; cmd_review "$@" ;;
  wizard)          shift; cmd_wizard "$@" ;;
  -h|--help|help)  usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
