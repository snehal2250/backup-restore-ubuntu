#!/bin/bash
# ---------------------------------------------------------------------------
# installers.sh — typed, narrowly-scoped installer functions for the
# structured `installer:` records in inventory.yaml (schema v2).
#
# Replaces the old opaque `install_command` shell pipelines with parameterized,
# auditable install steps. Every installer type has exactly ONE function, and
# restore.sh / update_all_ubuntu.sh dispatch through `installer_run NAME`.
#
# Installer types (see inventory/schema.yaml $defs.installer):
#   apt / snap / snap_classic / flatpak / npm_global / pipx / cargo
#       — package-based: install the declared source package.
#   apt_repository      — signed third-party apt repository (url + suite +
#                         components + key_url [+ key_fingerprint] + packages).
#   deb                 — verified .deb download (url [+ arch gate] [+ sha256
#                         checksum or unverified: true]).
#   tarball             — verified tarball (url [+ {version}] [+ checksum /
#                         checksum_url / unverified] + binary symlink).
#   script              — REMOTE SCRIPT, explicit last resort: the script is
#                         downloaded to a file and executed; never piped inline.
#                         Requires a pinned checksum or `unverified: true`.
#
# Source AFTER lib/common.sh (needs: run, info/ok/warn/err, require_yq,
# installer_get/installer_list/installer_has, ARCH_NORM, DRY_RUN).
# ---------------------------------------------------------------------------
set -euo pipefail

# installer_pkg NAME — the source package name (defaults to the app name).
installer_pkg() {
  local name="$1" pkg
  pkg="$(installer_get "$name" '.package')"
  [ -n "$pkg" ] || pkg="$name"
  printf '%s\n' "$pkg"
}

# ubuntu_codename — the running Ubuntu release codename (e.g. noble).
ubuntu_codename() {
  local cn=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    cn="${VERSION_CODENAME:-}"
  fi
  [ -n "$cn" ] || { err "  cannot determine the Ubuntu codename from /etc/os-release"; return 1; }
  printf '%s\n' "$cn"
}

# resolve_version NAME — literal 'version', or resolved from 'version_url'
# (first non-empty line of the fetched document, or the result of the optional
# 'version_query' yq expression applied to it).
resolve_version() {
  local name="$1" v vurl vq
  vurl="$(installer_get "$name" '.version_url')"
  if [ -n "$vurl" ]; then
    local doc
    doc="$(mktemp)"
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] resolve version from %s\n' "$vurl"
      v="__VERSION__"
    else
      curl -fsSL -o "$doc" "$vurl" || { rm -f "$doc"; err "  $name: could not fetch version URL $vurl"; return 1; }
      vq="$(installer_get "$name" '.version_query')"
      if [ -n "$vq" ]; then
        # Feed the document via stdin, not as a path argument: the snap-packaged
        # yq cannot open /tmp files ("no such file or directory"). The `|| true`
        # guards a head-exits-first SIGPIPE under pipefail (see common.sh note).
        v="$(yq -r "$vq" < "$doc" | grep -v '^[[:space:]]*$' | head -n1 || true)"
      else
        v="$(grep -v '^[[:space:]]*$' "$doc" | head -n1 || true)"
      fi
      rm -f "$doc"
    fi
  else
    v="$(installer_get "$name" '.version')"
  fi
  [ -n "$v" ] || { err "  $name: cannot resolve {version} — set 'version' or 'version_url'"; return 1; }
  printf '%s\n' "$v"
}

# resolve_url NAME URL — substitute {arch} and {version} placeholders.
resolve_url() {
  local name="$1" url="$2" ver
  if [[ "$url" == *"{version}"* ]]; then
    ver="$(resolve_version "$name")" || return 1
    url="${url//\{version\}/$ver}"
  fi
  url="${url//\{arch\}/$ARCH_NORM}"
  printf '%s\n' "$url"
}

# _download DEST URL — curl to a file, dry-run aware (prints + leaves a
# placeholder so downstream steps can proceed).
_download() {
  local dest="$1" url="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] curl -fsSL -o %s %s\n' "$dest" "$url"
    : > "$dest"
    return 0
  fi
  curl -fsSL -o "$dest" "$url"
}

# verify_checksum FILE EXPECTED_SHA256 — dry-run aware.
verify_checksum() {
  local file="$1" expected="$2" actual
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] verify sha256 of %s == %s\n' "$file" "$expected"
    return 0
  fi
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "${actual,,}" != "${expected,,}" ]; then
    err "  checksum mismatch for $file: expected ${expected,,}, got ${actual,,}"
    return 1
  fi
  ok "  checksum verified: ${actual,,}"
}

# verify_artifact NAME FILE — enforce checksum -> checksum_url -> unverified.
verify_artifact() {
  local name="$1" file="$2" cs csurl
  cs="$(installer_get "$name" '.checksum')"
  if [ -n "$cs" ]; then
    verify_checksum "$file" "$cs" || return 1
    return 0
  fi
  csurl="$(installer_get "$name" '.checksum_url')"
  if [ -n "$csurl" ]; then
    local resolved
    resolved="$(resolve_url "$name" "$csurl")" || return 1
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] fetch checksum sidecar %s\n' "$resolved"
      return 0
    fi
    local sidecar
    sidecar="$(mktemp)"
    curl -fsSL -o "$sidecar" "$resolved" || { rm -f "$sidecar"; err "  $name: could not fetch checksum sidecar $resolved"; return 1; }
    cs="$(awk '{print $1; exit}' "$sidecar")"
    rm -f "$sidecar"
    [ -n "$cs" ] || { err "  $name: could not parse a checksum from $resolved"; return 1; }
    verify_checksum "$file" "$cs" || return 1
    return 0
  fi
  if [ "$(installer_get "$name" '.unverified')" = "true" ]; then
    warn "  $name: no pinned checksum — unverified artifact (explicitly acknowledged in the inventory)"
    return 0
  fi
  err "  $name: download has no checksum and is not marked unverified: true — refusing to install"
  return 1
}

# verify_key_fingerprint KEYFILE EXPECTED — verify an apt repository signing
# key before it is trusted (gnupg installed on demand). Dry-run aware.
verify_key_fingerprint() {
  local keyfile="$1" expected="$2" actual a e
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] verify gpg key fingerprint of %s == %s\n' "$keyfile" "$expected"
    return 0
  fi
  if ! command -v gpg >/dev/null 2>&1; then
    info "  gpg not found — installing gnupg to verify the repository key fingerprint."
    sudo apt-get install -y gnupg || return 1
  fi
  actual="$(gpg --show-keys --with-colons --with-fingerprint "$keyfile" 2>/dev/null | awk -F: '/^fpr:/{print $10; exit}')"
  [ -n "$actual" ] || { err "  could not read a fingerprint from $keyfile"; return 1; }
  e="$(printf '%s' "$expected" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  a="$(printf '%s' "$actual" | tr -d ' ' | tr '[:lower:]' '[:upper:]')"
  if [ "$a" != "$e" ]; then
    err "  repository key fingerprint mismatch: expected $e, got $a"
    return 1
  fi
  ok "  repository key fingerprint verified ($a)"
}

# --- Installer functions (one per type) -----------------------------------

_installer_apt() {
  local name="$1"
  run sudo apt-get install -y "$(installer_pkg "$name")"
}

_installer_snap() {
  local name="$1"
  command -v snap >/dev/null 2>&1 || { warn "  $name: snap is not available on this system."; return 1; }
  run sudo snap install "$(installer_pkg "$name")"
}

_installer_snap_classic() {
  local name="$1"
  command -v snap >/dev/null 2>&1 || { warn "  $name: snap is not available on this system."; return 1; }
  run sudo snap install --classic "$(installer_pkg "$name")"
}

_installer_flatpak() {
  local name="$1"
  run flatpak install -y flathub "$(installer_pkg "$name")"
}

_installer_npm_global() {
  local name="$1"
  run sudo npm install -g "$(installer_pkg "$name")"@latest
}

_installer_pipx() {
  local name="$1"
  run pipx install "$(installer_pkg "$name")"
}

_installer_cargo() {
  local name="$1"
  run cargo install "$(installer_pkg "$name")"
}

# _installer_apt_repository: add a signed third-party apt repository and
# install packages from it. Steps: keyring dir -> download+verify key ->
# sources.list.d entry -> apt update -> install.
_installer_apt_repository() {
  local name="$1"
  local url suite key_url fp arch
  url="$(installer_get "$name" '.url')"
  suite="$(installer_get "$name" '.suite')"
  key_url="$(installer_get "$name" '.key_url')"
  fp="$(installer_get "$name" '.key_fingerprint')"
  arch="$(installer_get "$name" '.arch')"
  if [ -z "$url" ] || [ -z "$suite" ] || [ -z "$key_url" ]; then
    err "  $name: apt_repository installer requires url, suite and key_url"
    return 1
  fi

  local -a packages=() comps=() p c
  while IFS= read -r p; do [ -n "$p" ] && packages+=("$p"); done < <(installer_list "$name" '.packages[]?')
  if installer_has "$name" '.components'; then
    while IFS= read -r c; do [ -n "$c" ] && comps+=("$c"); done < <(installer_list "$name" '.components[]?')
  else
    comps=("main")
  fi
  [ "${#packages[@]}" -gt 0 ] || { err "  $name: apt_repository installer requires at least one package"; return 1; }

  if [ "$suite" = "codename" ]; then
    suite="$(ubuntu_codename)" || return 1
  fi

  local slug keyfile deb_opts line
  slug="$(printf '%s' "$name" | tr -cd 'a-z0-9._-')"
  keyfile="/etc/apt/keyrings/${slug}.asc"
  deb_opts="signed-by=$keyfile"
  [ -n "$arch" ] && deb_opts="arch=$arch ${deb_opts}"

  run sudo install -m 0755 -d /etc/apt/keyrings || return 1
  run sudo curl -fsSL -o "$keyfile" "$key_url" || return 1
  run sudo chmod a+r "$keyfile" || return 1

  if [ -n "$fp" ]; then
    verify_key_fingerprint "$keyfile" "$fp" || return 1
  fi

  line="deb [${deb_opts}] ${url} ${suite}"
  for c in "${comps[@]}"; do
    line="${line} ${c}"
  done
  printf '%s\n' "$line" | run sudo tee "/etc/apt/sources.list.d/${slug}.list" >/dev/null || return 1

  run sudo apt-get update || return 1
  run sudo apt-get install -y "${packages[@]}" || return 1
  return 0
}

# _installer_deb: download a .deb (optionally arch-gated and checksum-verified)
# and install it with apt (resolves dependencies).
_installer_deb() {
  local name="$1"
  local url arch resolved tmp
  url="$(installer_get "$name" '.url')"
  arch="$(installer_get "$name" '.arch')"
  if [ -n "$arch" ] && [ "$arch" != "$ARCH_NORM" ]; then
    warn "  $name: this .deb is for arch '$arch' but the system is '$ARCH_NORM' — skipping (no compatible build for this machine)."
    return 1
  fi
  resolved="$(resolve_url "$name" "$url")" || return 1
  tmp="/tmp/$(printf '%s' "$name" | tr -cd 'a-z0-9._-').deb"
  _download "$tmp" "$resolved" || return 1
  verify_artifact "$name" "$tmp" || return 1
  run sudo apt-get install -y "$tmp" || return 1
  return 0
}

# _installer_tarball: download a tarball, verify it, extract the top-level
# directory into dest (idempotent), and optionally symlink a binary into
# /usr/local/bin. Hostile-archive guard: the top-level name must be sane.
_installer_tarball() {
  local name="$1"
  local url dest binary resolved tmp
  url="$(installer_get "$name" '.url')"
  dest="$(installer_get "$name" '.dest')"
  binary="$(installer_get "$name" '.binary')"
  [ -n "$dest" ] || dest="/usr/local"
  case "$dest" in
    /usr/local|/usr/local/*|/opt|/opt/*) : ;;
    *) err "  $name: tarball dest '$dest' must be under /usr/local or /opt"; return 1 ;;
  esac

  resolved="$(resolve_url "$name" "$url")" || return 1
  tmp="/tmp/$(printf '%s' "$name" | tr -cd 'a-z0-9._-').tar.gz"
  _download "$tmp" "$resolved" || return 1
  verify_artifact "$name" "$tmp" || return 1

  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] extract %s into staging, swap the top-level dir into %s\n' "$tmp" "$dest"
    [ -n "$binary" ] && printf '[dry-run] sudo ln -sf %s/%s /usr/local/bin/%s\n' "$dest" "$binary" "$(basename "$binary")"
    return 0
  fi

  # Hostile-archive guard BEFORE extraction: reject absolute paths, '..'
  # traversal, and device/FIFO members. (Symlinks are allowed — they stay
  # inside the staged tree and the installed dir is root-owned below.) The
  # `|| true`s guard head-exits-first SIGPIPE under pipefail (see common.sh).
  local badmember special
  badmember="$(tar -tzf "$tmp" 2>/dev/null | grep -E '(^/|(^|/)\.\.(/|$))' | head -n1 || true)"
  if [ -n "$badmember" ]; then
    err "  $name: tarball contains unsafe member '$badmember' — refusing to install"
    return 1
  fi
  special="$(tar -tvzf "$tmp" 2>/dev/null | grep -E '^[bcp]' | head -n1 || true)"
  if [ -n "$special" ]; then
    err "  $name: tarball contains a special file ('$special') — refusing to install"
    return 1
  fi

  local stage toplevel dirname binpath link
  stage="$(mktemp -d)"
  if ! tar -xzf "$tmp" -C "$stage" 2>/dev/null; then
    err "  $name: could not extract $tmp"
    rm -rf "$stage"
    return 1
  fi
  # `|| true` guards the find|head pipeline: with >1 top-level dir, head exits
  # after the first line and pipefail would turn find's SIGPIPE into a 141 that
  # aborts the whole restore under set -e (see the note in lib/common.sh).
  toplevel="$(find "$stage" -mindepth 1 -maxdepth 1 -type d | head -n1 || true)"
  if [ -z "$toplevel" ]; then
    err "  $name: tarball contains no top-level directory"
    rm -rf "$stage"
    return 1
  fi
  dirname="$(basename "$toplevel")"
  case "$dirname" in
    .|..|*/*)
      err "  $name: unsafe top-level directory '$dirname' in tarball — refusing to install"
      rm -rf "$stage"
      return 1
      ;;
  esac
  sudo rm -rf "$dest/$dirname" || { rm -rf "$stage"; return 1; }
  sudo mv "$toplevel" "$dest/" || { rm -rf "$stage"; return 1; }
  rm -rf "$stage"
  # Match the old `sudo tar -C /usr/local` behavior: the installed tree is
  # root-owned, not owned by the restoring user.
  sudo chown -R root:root "$dest/$dirname" || return 1
  if [ -n "$binary" ]; then
    binpath="$dest/$binary"
    link="/usr/local/bin/$(basename "$binary")"
    sudo ln -sf "$binpath" "$link" || return 1
  fi
  return 0
}

# _installer_script: EXPLICIT LAST RESORT. The remote script is downloaded to a
# file (never piped inline), optionally checksum-verified, then executed with
# bash. Requires a pinned checksum or `unverified: true` (schema-enforced).
_installer_script() {
  local name="$1" url tmp
  url="$(installer_get "$name" '.url')"
  tmp="/tmp/$(printf '%s' "$name" | tr -cd 'a-z0-9._-').install.sh"
  _download "$tmp" "$url" || return 1
  verify_artifact "$name" "$tmp" || return 1
  info "  $name: running remote install script from $url"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] bash %s\n' "$tmp"
    return 0
  fi
  bash -o pipefail "$tmp" || { err "  $name: install script failed (exit $?)"; return 1; }
  return 0
}

# installer_run NAME — dispatch to the typed installer for the app's
# `installer:` record. Returns 0 on success, non-zero on failure. The caller
# (restore.sh / update_all_ubuntu.sh) is responsible for the
# already-installed check and post-install verification.
installer_run() {
  local name="$1" itype
  itype="$(installer_get "$name" '.type')"
  case "$itype" in
    apt)            _installer_apt "$name" ;;
    snap)           _installer_snap "$name" ;;
    snap_classic)   _installer_snap_classic "$name" ;;
    flatpak)        _installer_flatpak "$name" ;;
    npm_global)     _installer_npm_global "$name" ;;
    pipx)           _installer_pipx "$name" ;;
    cargo)          _installer_cargo "$name" ;;
    apt_repository) _installer_apt_repository "$name" ;;
    deb)            _installer_deb "$name" ;;
    tarball)        _installer_tarball "$name" ;;
    script)         _installer_script "$name" ;;
    *) err "  $name: unknown installer type '$itype'"; return 1 ;;
  esac
}
