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
  add-cron                               Declare a cron scheduling source (wizard: user crontab / /etc/cron.d file)
  remove-cron <name>                     Remove a cron job declaration
  add-user-dir <path>                    Declare a whole user-data folder (e.g. ~/Documents)
  remove-user-dir <path>                 Remove a user-dir declaration
  review [--drift]                       Suggest apps found on this system, not yet declared;
                                         with --drift: report catalog drift (declared entries vs templates)
  wizard                                 Guided: scan the system and declare apps one by one
EOF
}

# esc() is defined in lib/common.sh (shared with catalog.sh).

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
  # Resolve catalog references so the listing shows the EFFECTIVE (merged)
  # records — installer types, packages and config counts that would actually
  # run. The raw file is still read for the catalog-key tag below.
  resolve_effective_inventory
  echo "Inventory: $INVENTORY_FILE"
  echo

  local app_count
  app_count="$(yaml_list '.apps[] | .name' | { grep -c . 2>/dev/null || true; })"
  app_count="${app_count:-0}"
  echo "=== Apps ($app_count) ==="
  # Catalog keys come from the RAW file (the resolver strips them from the
  # effective document); everything else reads the effective inventory.
  local -A _cat_of=()
  local _cn _ck
  while IFS=$'\t' read -r _cn _ck; do
    [ -n "$_cn" ] && _cat_of["$_cn"]="$_ck"
  done < <(yq -r '.apps[] | select(has("catalog")) | [.name, .catalog] | @tsv' "$INVENTORY_FILE")
  # Single yq pass to extract all app metadata — avoids repeated yq invocations
  # which have significant startup overhead (especially with snap yq).
  while IFS=$'\t' read -r name itype check pkg cfg_cnt dep_cnt; do
    [ -n "$name" ] || continue
    # Convert sentinel empty-string markers back.
    [ "$pkg" = "___EMPTY___" ] && pkg=""
    local tags="  ${itype:-?}"
    [ -n "$pkg" ] && tags="$tags  pkg=$pkg"
    [ -n "${_cat_of[$name]:-}" ] && tags="$tags  catalog=${_cat_of[$name]}"
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
  ' "$INVENTORY_READ")
  unset _cat_of
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
    local excl_tags=""
    local -a ud_excl=()
    while IFS= read -r e; do
      [ -n "$e" ] && ud_excl+=("$e")
    done < <(user_dir_exclude "$d")
    [ "${#ud_excl[@]}" -gt 0 ] && excl_tags="  exclude: ${ud_excl[*]}"
    if [ -d "$(expand_path "$d")" ]; then
      echo "    [x] $d$excl_tags"
    else
      echo "    [ ] $d$excl_tags"
    fi
  done < <(user_dir_paths)
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
  done < <(yq -r '.services[] | [.unit, (.target // "system"), (.enable // false | tostring), (.start // false | tostring)] | @tsv' "$INVENTORY_READ")

  echo "=== Cron jobs ==="
  while IFS=$'\t' read -r cname csource cfile; do
    [ -n "$cname" ] || continue
    [ -n "$cfile" ] || cfile="$cname"
    local ctags="$csource"
    case "$csource" in
      user)
        if command -v crontab >/dev/null 2>&1 && crontab -l >/dev/null 2>&1; then
          echo "    [x] $cname ($ctags)"
        else
          echo "    [ ] $cname ($ctags — no crontab)"
        fi
        ;;
      cron.d)
        ctags="$ctags  file=$cfile"
        if [ -f "$CRON_D_DIR/$cfile" ]; then
          echo "    [x] $cname ($ctags)"
        else
          echo "    [ ] $cname ($ctags)"
        fi
        ;;
    esac
  done < <(yq -r '.cron_jobs[]? | [.name, .source, (.file // "")] | @tsv' "$INVENTORY_READ")
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
      for k in package url suite codename_fallback key_url key_fingerprint arch checksum checksum_url binary dest version version_url version_query; do
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
  unset installer_type installer_package installer_url installer_suite installer_codename_fallback installer_components installer_key_url installer_key_fingerprint installer_packages installer_arch installer_checksum installer_checksum_url installer_unverified installer_binary installer_dest installer_version installer_version_url installer_version_query 2>/dev/null || true

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
      # Emit a CATALOG REFERENCE (schema v5) instead of an expanded copy: the
      # effective record is the template merged with `overrides:` at run time,
      # so a catalog fix reaches this entry automatically. The template key is
      # the name the wizard looked up (catalog_lookup matches it).
      local tmp
      tmp="$(mktemp "$REPO_ROOT/.app-ref.XXXXXX")"
      printf -- '- name: "%s"\n  catalog: "%s"\n' "$(esc "$name")" "$(esc "$name")" > "$tmp"
      yq -i '.apps += load("'"$tmp"'")' "$INVENTORY_FILE"
      rm -f "$tmp"
      ok "Added app '$name' (catalog reference — resolved from lib/catalog.sh at run time; tweak with overrides:)."
      return 0
    fi
    desc=""; check=""; deps=""; paths=""; excl=""
    unset description check_cmd depends_apt config_paths exclude extensions
    unset installer_type installer_package installer_url installer_suite installer_codename_fallback installer_components installer_key_url installer_key_fingerprint installer_packages installer_arch installer_checksum installer_checksum_url installer_unverified installer_binary installer_dest installer_version installer_version_url installer_version_query 2>/dev/null || true
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
      [ -n "${installer_arch:-}" ] || { printf 'Architecture gate (blank = any, or amd64; arm64 artifacts are skipped on this amd64-only repo): '; read -r installer_arch; }
      printf 'sha256 checksum (blank = unverified): '; read -r installer_checksum
      [ -n "$installer_checksum" ] || installer_unverified="true"
      ;;
    tarball)
      [ -n "${installer_url:-}" ] || { printf 'Tarball URL (https://..., {arch}/{version} allowed): '; read -r installer_url; }
      if [[ "${installer_url:-}" == *"{version}"* ]] && [ -z "${installer_version_url:-}" ]; then
        printf 'Version URL to resolve {version} (https://...): '; read -r installer_version_url
      fi
      [ -n "${installer_arch:-}" ] || { printf 'Architecture gate (blank = any, or amd64; arm64 artifacts are skipped on this amd64-only repo): '; read -r installer_arch; }
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

# --- add-cron / remove-cron -----------------------------------------------
# write_cron NAME SOURCE [FILE] — append a cron_jobs entry (schema v6). The
# CONTENT lives in the backup; the inventory only declares WHICH cron source.
write_cron() {
  local name="$1" source="$2" file="${3:-}"
  # Temp file must live next to the repo (NOT /tmp): the snap-packaged yq
  # cannot read /tmp, and load() would fail with 'no such file or directory'.
  local tmp
  tmp="$(mktemp "$REPO_ROOT/.cron-entry.XXXXXX")"
  {
    printf -- '- name: "%s"\n' "$(esc "$name")"
    printf '  source: %s\n' "$source"
    [ -n "$file" ] && printf '  file: "%s"\n' "$(esc "$file")"
  } > "$tmp"
  yq -i '.cron_jobs += load("'"$tmp"'")' "$INVENTORY_FILE"
  rm -f "$tmp"
}

cmd_add_cron() {
  echo "Declare a cron scheduling source (schema v6). The CONTENT lives in the backup —"
  echo "the inventory only declares WHICH sources to manage (never hardcode job lines)."
  echo
  echo "Source:"
  echo "  1) user    — the current user's crontab (crontab -l). At most ONE user entry."
  echo "  2) cron.d  — one file under /etc/cron.d (restored with sudo)."
  printf 'Select [1-2]: '
  local sel="" source="" name="" file=""
  read -r sel
  if [ "$sel" = "2" ]; then
    source="cron.d"
  else
    source="user"
  fi
  printf 'Identifier (e.g. user-crontab, my-daily): '
  read -r name
  name="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-')"
  [ -n "$name" ] || die "Invalid identifier."
  if yaml_list '.cron_jobs[]? | .name' | grep -Fqx "$name"; then
    die "Cron job '$name' is already in the inventory."
  fi
  if [ "$source" = "cron.d" ]; then
    printf 'File name under /etc/cron.d (blank = %s; NO dots — Debian cron ignores dotted names): ' "$name"
    read -r file
    [ -n "$file" ] || file="$name"
    if ! [[ "$file" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      die "Invalid cron.d file name: '$file'. Must be [a-zA-Z0-9_-]+ (no dots, no slashes)."
    fi
    [ -f "$CRON_D_DIR/$file" ] || warn "$CRON_D_DIR/$file does not exist yet — declared anyway (it will be captured once it exists)."
  else
    if yaml_list '.cron_jobs[]? | .source' | grep -Fqx "user"; then
      die "A source: user cron job already exists — the running user has a single crontab (remove it first)."
    fi
    command -v crontab >/dev/null 2>&1 && crontab -l >/dev/null 2>&1 \
      || warn "No crontab for $USER yet — declared anyway (it will be captured once one exists)."
  fi
  write_cron "$name" "$source" "$file"
  ok "Added cron job '$name' (source=$source${file:+ file=$file})."
}

cmd_remove_cron() {
  local name="${1:-}"
  [ -n "$name" ] || die "Usage: ./inventory.sh remove-cron <name>"
  if ! yaml_list '.cron_jobs[]? | .name' | grep -Fqx "$name"; then
    warn "Cron job '$name' is not in the inventory."
    return 0
  fi
  N="$name" yq -i '.cron_jobs |= map(select(.name != strenv(N)))' "$INVENTORY_FILE"
  ok "Removed cron job '$name'."
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
  if user_dir_paths | grep -Fqx "$dir"; then
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
  if ! user_dir_paths | grep -Fqx "$dir"; then
    warn "'$dir' is not in the user_dirs list."
    return 0
  fi
  # Remove both string-form and object-form entries matching this path.
  P="$dir" yq -i ".user_dirs |= map(select((type == \"string\" and . != strenv(P)) or (type == \"object\" and .path != strenv(P))))" "$INVENTORY_FILE"
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

cmd_review_drift() {
  require_yq "$YQ_AUTO"
  if ! _schema_python >/dev/null 2>&1; then
    warn "review --drift needs python3 + python3-yaml (already required by schema validation). Run './inventory.sh validate' to install them."
    return 1
  fi
  echo "Catalog drift report — declared apps vs lib/catalog.sh templates:"
  echo
  local found=0 name ck ovr_keys tfile dfile
  # 1) Apps declared as catalog references: show their overrides (the
  #    intentional deltas). These inherit catalog fixes automatically.
  while IFS=$'\t' read -r name ck; do
    [ -n "$name" ] || continue
    found=1
    ovr_keys="$(N="$name" yq -r '.apps[] | select(.name == strenv(N)) | (.overrides // {}) | keys | join(", ")' "$INVENTORY_FILE")"
    printf '  [ref ] %-20s catalog=%-12s overrides: %s\n' "$name" "$ck" "${ovr_keys:-(none)}"
  done < <(yq -r '.apps[] | select(has("catalog")) | [.name, .catalog] | @tsv' "$INVENTORY_FILE")

  # 2) FULL records whose name is a known catalog template: they do NOT inherit
  #    catalog fixes — classify the divergence so INTENTIONAL local extensions
  #    (extra fields like conflict_policy, extra array items) are not shouted
  #    at as stale drift, and only suggest converting to a reference when the
  #    diff is actually expressible in `overrides:` (a reference can append
  #    array items and override scalars, but it can NEVER remove a template
  #    array item).
  local _refs out
  _refs="$(yq -r '.apps[] | select(has("catalog")) | .name' "$INVENTORY_FILE")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -Fqx "$name" <<< "$_refs"; then continue; fi
    if ! catalog_lookup "$name" >/dev/null 2>&1; then continue; fi
    tfile="$(mktemp "$REPO_ROOT/.drift-tmpl.XXXXXX")"
    dfile="$(mktemp "$REPO_ROOT/.drift-decl.XXXXXX")"
    catalog_to_yaml "$name" > "$tfile" 2>/dev/null || { rm -f "$tfile" "$dfile"; continue; }
    N="$name" yq -n 'load("'"$INVENTORY_FILE"'") | .apps[] | select(.name == strenv(N)) | del(.name)' > "$dfile"
    out="$(python3 - "$tfile" "$dfile" "$name" <<'PYEOF'
import sys, yaml
tmpl = yaml.safe_load(open(sys.argv[1])) or {}
decl = yaml.safe_load(open(sys.argv[2])) or {}
name = sys.argv[3]

# Array fields a reference can only APPEND to (never shrink).
APPEND = {"config_paths", "exclude", "extensions", "depends_apt"}
APPEND_INST = {"packages", "components"}

stale, missing, extra = [], [], []

def array_diff(field, tarr, dval):
    """Classify one APPEND field: tarr = template items, dval = declared value
    (None when the key is absent). A declared value that is a STRICT SUPERSET of
    the template's items is an addition; a subset/absent-with-items is missing
    (not representable as a reference). Equal or both-empty stays clean — note
    `not dval` would misflag an equal empty array (e.g. components: [] from a
    template's `_none_`), so presence is checked with `is None`."""
    if dval is None:
        if tarr:
            missing.append(field)
        return
    if any(x not in dval for x in tarr):
        missing.append(field)
        return
    if set(dval) > set(tarr):
        extra.append(f"{field} (+{len(set(dval) - set(tarr))})")

ti = tmpl.get("installer") or {}
di = decl.get("installer") or {}
for k, v in ti.items():
    if k in APPEND_INST:
        array_diff("installer." + k, v, di.get(k))
    elif di.get(k) != v:
        stale.append("installer." + k)
for k in di:
    if k not in ti:
        extra.append("installer." + k)

for k, v in tmpl.items():
    if k == "installer":
        continue
    if k in APPEND:
        array_diff(k, v, decl.get(k))
    elif decl.get(k) != v:
        stale.append(k)
for k in decl:
    if k != "installer" and k not in tmpl:
        extra.append(k)

if not (stale or missing or extra):
    sys.exit(0)
lines = [f"  [man ] {name:<20} diverges from its catalog template"]
if stale:
    lines.append(f"         stale:  {', '.join(stale)}")
if missing:
    lines.append(f"         removed template items: {', '.join(missing)}")
if extra:
    lines.append(f"         additions: {', '.join(sorted(extra))}")
if not missing:
    lines.append(f"         -> expressible as a reference: ./inventory.sh remove-app {name} && ./inventory.sh add-app {name} (re-apply the stale values and additions via overrides:)")
else:
    lines.append("         -> keep the full record — a catalog reference cannot remove template items")
print("\n".join(lines))
PYEOF
)"
    if [ -n "$out" ]; then
      found=1
      printf '%s\n' "$out"
    fi
    rm -f "$tfile" "$dfile"
  done < <(yq -r '.apps[] | .name' "$INVENTORY_FILE")

  if [ "$found" = "0" ]; then
    echo "  (no drift — every declared app matches its catalog template, or has no template)"
  fi
  echo
  echo "References resolve to the template at run time; full records that match are fine too."
}

cmd_review() {
  require_yq "$YQ_AUTO"
  if [ "${1:-}" = "--drift" ]; then
    shift
    cmd_review_drift "$@"
    return 0
  fi
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
  echo "Cron jobs found on this system that are NOT declared:"
  local found_cron=0 cdfile cbase
  # Here-strings, never `yq | grep -q` (pipefail + early-exit grep SIGPIPEs a
  # slow yq — same convention as lib/common.sh).
  local declared_cron_sources declared_cron_files
  declared_cron_sources="$(yq -r '.cron_jobs[]? | .source' "$INVENTORY_FILE")"
  declared_cron_files="$(yq -r '.cron_jobs[]? | select(.source == "cron.d") | .file // .name' "$INVENTORY_FILE")"
  if command -v crontab >/dev/null 2>&1 && crontab -l >/dev/null 2>&1; then
    if ! grep -Fqx "user" <<< "$declared_cron_sources"; then
      found_cron=1
      printf '  [cron] user crontab exists (crontab -l) — declare with: ./inventory.sh add-cron\n'
    fi
  fi
  # System-managed / package-owned files are never suggested (principle 4: only
  # what the user added on top of stock Ubuntu). Two filters: a hardcoded stock
  # list for the common Ubuntu set, AND a dpkg ownership check — a file owned by
  # any dpkg package (e.g. sysstat, docker) is recreated by reinstalling that
  # package, so it never needs backing up. Only hand-created files (owned by no
  # package) are worth suggesting.
  local stock_cron_d="anacron e2scrub_all sysstat 0hourly apt-compat dpkg man-db popularity-contest update-notifier-common apport fstrim"
  for cdfile in "$CRON_D_DIR"/*; do
    [ -f "$cdfile" ] || continue
    cbase="$(basename "$cdfile")"
    echo "$stock_cron_d" | grep -Fwq "$cbase" && continue
    command -v dpkg >/dev/null 2>&1 && dpkg -S "$cdfile" >/dev/null 2>&1 && continue
    grep -Fqx "$cbase" <<< "$declared_cron_files" && continue
    found_cron=1
    printf '  [cron] %s/%s — declare with: ./inventory.sh add-cron (source cron.d)\n' "$CRON_D_DIR" "$cbase"
  done
  if [ "$found_cron" = "0" ]; then
    echo "  (none — all detected cron sources appear declared)"
  fi
  echo
  echo "Declare any of these with: ./inventory.sh add-app <name> / add-cron"
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
  add-cron)        shift; cmd_add_cron "$@" ;;
  remove-cron)     shift; cmd_remove_cron "$@" ;;
  add-user-dir)    shift; cmd_add_user_dir "$@" ;;
  remove-user-dir) shift; cmd_remove_user_dir "$@" ;;
  review)          shift; cmd_review "$@" ;;
  wizard)          shift; cmd_wizard "$@" ;;
  -h|--help|help)  usage ;;
  *)               usage; die "Unknown command: $cmd" ;;
esac
