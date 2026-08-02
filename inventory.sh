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
SCHEMA_AUTO=2   # ask before installing the schema validator (python3-jsonschema)

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
    local sv prof
    sv="$(yaml_get '.schema_version')"
    prof="$(yaml_get '.profile')"
    ok "Inventory is valid (schema_version=${sv:-?}, profile=${prof:-?})."
  else
    die "Inventory has issues — see messages above."
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
    if [ "${cfg_cnt:-0}" -eq 0 ] && [ "$itype" != "snap" ] && [ "$itype" != "snap_classic" ]; then
      tags="$tags  (no config)"
    fi
    if is_app_installed "$name"; then
      printf '    [x] %-20s %s\n' "$name" "$tags"
    else
      printf '    [ ] %-20s %s\n' "$name" "$tags"
    fi
  done < <(yq -r '
    .apps[] | [
      .name,
      (.installer.type // "___EMPTY___"),
      (.check_cmd // "___EMPTY___"),
      (.installer.package // "___EMPTY___"),
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
# write_app NAME DESC CHECK DEPS PATHS EXCL [EXTENSIONS]
# Emits an app entry with the structured `installer:` block. The installer
# fields are read from the installer_* variables set by the catalog parse or
# the wizard prompts (installer_type + installer_url/suite/packages/...).
write_app() {
  local name="$1" desc="$2" check="$3" deps="$4" paths="$5" excl="$6" exts="${7:-}"
  # Temp file must live next to the repo (NOT /tmp): the snap-packaged yq
  # cannot read /tmp, and load() would fail with 'no such file or directory'.
  local tmp
  tmp="$(mktemp "$REPO_ROOT/.app-entry.XXXXXX")"
  {
    printf -- '- name: "%s"\n' "$(esc "$name")"
    [ -n "$desc" ] && printf '  description: "%s"\n' "$(esc "$desc")"
    if [ -n "${installer_type:-}" ]; then
      echo "  installer:"
      printf '    type: "%s"\n' "$(esc "$installer_type")"
      local k v varname l
      for k in package url suite key_url key_fingerprint arch checksum checksum_url binary dest version version_url version_query; do
        varname="installer_$k"
        v="${!varname:-}"
        [ -n "$v" ] && printf '    %s: "%s"\n' "$k" "$(esc "$v")"
      done
      varname="installer_unverified"
      v="${!varname:-}"
      [ -n "$v" ] && printf '    unverified: %s\n' "$v"
      for k in components packages; do
        varname="installer_$k"
        v="${!varname:-}"
        if [ "$v" = "_none_" ]; then
          echo "    $k: []"
        elif [ -n "$v" ]; then
          echo "    $k:"
          local -a arr=()
          read -ra arr <<< "$v"
          for l in "${arr[@]}"; do printf '      - "%s"\n' "$(esc "$l")"; done
        fi
      done
    else
      rm -f "$tmp"
      die "write_app: no installer_type set — cannot write a valid app entry"
    fi
    [ -n "$check" ] && printf '  check_cmd: "%s"\n' "$(esc "$check")"
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
    if [ -n "$exts" ]; then
      echo "  extensions:"
      local -a x_arr=()
      read -ra x_arr <<< "$exts"
      for x in "${x_arr[@]}"; do
        printf '    - "%s"\n' "$(esc "$x")"
      done
    fi
  } > "$tmp"
  yq -i '.apps += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

write_service() {
  local unit="$1" target="$2" enable="$3" start="$4" paths="$5"
  # Temp file must live next to the repo (NOT /tmp): the snap-packaged yq
  # cannot read /tmp, and load() would fail with 'no such file or directory'.
  local tmp
  tmp="$(mktemp "$REPO_ROOT/.service-entry.XXXXXX")"
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
  local name="${1:-}" desc="" itype="" check="" deps="" paths="" excl=""
  if [ -z "$name" ]; then
    printf 'App name (e.g. opencode): '
    read -r name
  fi
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
  [ -n "$name" ] || die "Invalid app name."
  if yaml_list '.apps[] | .name' | grep -Fqx "$name"; then
    die "App '$name' is already in the inventory."
  fi

  # Clear any installer_* state from a previous catalog lookup.
  unset installer_type installer_package installer_url installer_suite installer_components installer_key_url installer_key_fingerprint installer_packages installer_arch installer_checksum installer_checksum_url installer_unverified installer_binary installer_dest installer_version installer_version_url installer_version_query 2>/dev/null || true

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
    echo "  installer:      type=${installer_type:-?}"
    [ -n "${installer_url:-}" ] && echo "  installer url:   ${installer_url}"
    [ -n "${installer_package:-}" ] && echo "  installer pkg:   ${installer_package}"
    [ -n "${config_paths:-}" ] && echo "  config_paths:    ${config_paths//$'\n'/ }"
    if confirm "Use these defaults?" "y"; then
      write_app "$name" "${description:-}" "${check_cmd:-}" "${depends_apt:-}" \
        "${config_paths:-}" "${exclude:-}" "${extensions:-}"
      ok "Added app '$name'."
      return 0
    fi
    desc=""; check=""; deps=""; paths=""; excl=""
    unset description check_cmd depends_apt config_paths exclude extensions
    unset installer_type installer_package installer_url installer_suite installer_components installer_key_url installer_key_fingerprint installer_packages installer_arch installer_checksum installer_checksum_url installer_unverified installer_binary installer_dest installer_version installer_version_url installer_version_query 2>/dev/null || true
    echo
    echo "Running the manual wizard instead."
  fi

  # Install method (typed installer record).
  if [ -z "$itype" ]; then
    echo "Install method for '$name' (the structured installer record):"
    echo "  package-based: apt | snap | snap_classic | flatpak | npm_global | pipx | cargo"
    echo "  download:      apt_repository | deb | tarball | script (explicit last resort)"
    local i=1 t
    for t in apt snap snap_classic flatpak npm_global pipx cargo apt_repository deb tarball script; do
      echo "  $i) $t"
      i=$((i + 1))
    done
    printf 'Select [1-11]: '
    read -r sel
    itype="$(printf '%s\n' 'apt snap snap_classic flatpak npm_global pipx cargo apt_repository deb tarball script' | awk -v n="$sel" '{print $n}')"
    [ -n "$itype" ] || die "Invalid selection."
  fi
  installer_type="$itype"

  # Type-specific installer fields.
  case "$itype" in
    apt|snap|snap_classic|flatpak|npm_global|pipx|cargo)
      if [ -z "${installer_package:-}" ]; then
        printf 'Package name if it differs from the app name (blank = "%s"): ' "$name"
        read -r installer_package
      fi
      ;;
    apt_repository)
      [ -n "${installer_url:-}" ] || { printf 'Repository base URL (https://...): '; read -r installer_url; }
      [ -n "${installer_suite:-}" ] || { printf 'Suite (literal, or "codename" for the running Ubuntu): '; read -r installer_suite; }
      [ -n "${installer_components:-}" ] || { printf 'Components (space-separated; blank = main, "none" = none): '; read -r installer_components; }
      [ -n "${installer_key_url:-}" ] || { printf 'Signing key URL (https://...): '; read -r installer_key_url; }
      [ -n "${installer_packages:-}" ] || { printf 'Packages to install from the repo (space-separated): '; read -r installer_packages; }
      [ "${installer_components:-}" = "none" ] && installer_components="_none_"
      [ -n "${installer_components:-}" ] || installer_components="main"
      ;;
    deb)
      [ -n "${installer_url:-}" ] || { printf '.deb URL (https://..., {arch} allowed): '; read -r installer_url; }
      if [[ "${installer_url:-}" == *"{version}"* ]] && [ -z "${installer_version_url:-}" ]; then
        printf 'Version URL to resolve {version} (https://...): '; read -r installer_version_url
      fi
      [ -n "${installer_arch:-}" ] || { printf 'Architecture gate (blank = any, or amd64/arm64): '; read -r installer_arch; }
      printf 'sha256 checksum (blank = unverified): '; read -r installer_checksum
      [ -n "$installer_checksum" ] || installer_unverified="true"
      ;;
    tarball)
      [ -n "${installer_url:-}" ] || { printf 'Tarball URL (https://..., {arch}/{version} allowed): '; read -r installer_url; }
      if [[ "${installer_url:-}" == *"{version}"* ]] && [ -z "${installer_version_url:-}" ]; then
        printf 'Version URL to resolve {version} (https://...): '; read -r installer_version_url
      fi
      [ -n "${installer_arch:-}" ] || { printf 'Architecture gate (blank = any, or amd64/arm64): '; read -r installer_arch; }
      [ -n "${installer_binary:-}" ] || { printf 'Binary path inside the tarball to symlink into /usr/local/bin (optional): '; read -r installer_binary; }
      [ -n "${installer_dest:-}" ] || { printf 'Extract destination (blank = /usr/local): '; read -r installer_dest; }
      printf 'sha256 checksum (blank = unverified): '; read -r installer_checksum
      if [ -z "$installer_checksum" ]; then
        printf 'sha256 checksum URL/sidecar (https://..., optional): '; read -r installer_checksum_url
        [ -n "$installer_checksum_url" ] || installer_unverified="true"
      fi
      ;;
    script)
      [ -n "${installer_url:-}" ] || { printf 'Install script URL (https://...): '; read -r installer_url; }
      printf 'sha256 checksum of the script (blank = unverified): '; read -r installer_checksum
      [ -n "$installer_checksum" ] || installer_unverified="true"
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

  write_app "$name" "$desc" "$check" "$deps" "$paths" "$excl"
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
