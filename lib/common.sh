#!/bin/bash
# ---------------------------------------------------------------------------
# common.sh — shared helpers for all scripts in this repo.
#
# Source from a script at the repo root with:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
#
# Convention: never duplicate these helpers in individual scripts. If you add
# a helper here, update AGENTS.md and find-and-update all callers.
# ---------------------------------------------------------------------------
set -euo pipefail

# --- Paths ---------------------------------------------------------------
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
INVENTORY_FILE="$REPO_ROOT/inventory/inventory.yaml"
INVENTORY_SCHEMA="$REPO_ROOT/inventory/schema.yaml"   # versioned JSON Schema (draft 2020-12)
# shellcheck disable=SC2034  # consumed by backup.sh / restore.sh after sourcing
BACKUPS_DIR="$REPO_ROOT/backups"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
# Local-disk mirror destination for backup.sh (env-overridable; empty string disables).
BACKUP_DEST="${BACKUP_DEST-/media/vikram-athare/Storage/backup-restore-ubuntu}"
BACKUP_KEEP="${BACKUP_KEEP:-5}"

DRY_RUN=0   # set to 1 by scripts that support --dry-run (restore.sh)

# --- Architecture ---------------------------------------------------------
ARCH="$(uname -m)"
# Normalise common arch strings to the values dpkg/Go/Docker use.
case "$ARCH" in
  x86_64|amd64) ARCH_NORM="amd64" ;;
  aarch64|arm64) ARCH_NORM="arm64" ;;
  *)             ARCH_NORM="$ARCH" ;;
esac

# --- Logging & exit codes -------------------------------------------------
# Exit codes for restore accumulation (restore.sh uses these).
EXIT_OK=0
EXIT_CONFIGS_MISSING=1
EXIT_INSTALL_FAILED=2
EXIT_PREREQ_FAILED=4

info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# confirm "question" [default y|n] -> exit code 0 (yes) or 1 (no)
confirm() {
  local question="${1:-Continue?}" default="${2:-n}" answer=""
  while :; do
    if [ "$default" = "y" ]; then
      printf '%s [Y/n] ' "$question"
    else
      printf '%s [y/N] ' "$question"
    fi
    read -r answer
    [ -z "$answer" ] && answer="$default"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO)   return 1 ;;
      *) warn "Please answer y or n." ;;
    esac
  done
}

# --- Dry-run aware runner ------------------------------------------------
run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

# --- yq bootstrap ---------------------------------------------------------
YQ_AUTO=0

# Schema-validation bootstrap mode, mirrors YQ_AUTO:
#   0 = die if the validator is missing, 1 = auto-install, 2 = ask first.
SCHEMA_AUTO=0

require_yq() {
  local mode="${1:-$YQ_AUTO}"
  if command -v yq >/dev/null 2>&1; then return 0; fi
  if [ "$mode" = "1" ] || [ "$mode" = "2" ]; then
    if [ "$mode" = "2" ]; then
      confirm "yq is required to read $INVENTORY_FILE. Install it now?" "n" || die "yq is required. Install it with: sudo snap install yq"
    else
      info "yq not found — installing it so the scripts can read inventory.yaml."
    fi
    if command -v snap >/dev/null 2>&1; then
      sudo snap install yq
    elif command -v curl >/dev/null 2>&1; then
      local yq_url
      case "$ARCH_NORM" in
        amd64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64" ;;
        arm64) yq_url="https://github.com/mikefarah/yq/releases/latest/download/yq_linux_arm64" ;;
        *)     die "Unsupported architecture '$ARCH_NORM' for yq bootstrap. Install yq manually." ;;
      esac
      local tmp_yq
      tmp_yq="$(mktemp)"
      curl -fsSL -o "$tmp_yq" "$yq_url" || { rm -f "$tmp_yq"; die "yq download failed. Install it manually: sudo snap install yq"; }
      sudo install -m 0755 -o root -g root "$tmp_yq" /usr/local/bin/yq
      rm -f "$tmp_yq"
    else
      die "yq is required. Install it manually (e.g. 'sudo snap install yq') and re-run."
    fi
    command -v yq >/dev/null 2>&1 || die "yq still not available after the install attempt."
  else
    die "The 'yq' tool is required to read $INVENTORY_FILE. Install it with: sudo snap install yq"
  fi
}

# --- YAML access (requires yq) -------------------------------------------
yaml_get() {
  require_yq "$YQ_AUTO"
  yq -r "$1 // \"\"" "$INVENTORY_FILE"
}

yaml_list() {
  require_yq "$YQ_AUTO"
  yq -r "$1" "$INVENTORY_FILE"
}

# app_get NAME QUERY -> scalar attribute of one app (empty if absent)
# Uses environment variable to avoid YAML injection.
app_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | $2 // \"\"" "$INVENTORY_FILE"
}

# installer_get NAME QUERY -> scalar attribute under .installer (empty if absent)
# QUERY is always a fixed expression like '.type' or '.package'.
installer_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | .installer$2 // \"\"" "$INVENTORY_FILE"
}

# installer_list NAME QUERY -> lines under .installer (callers pass '.packages[]?'
# or '.components[]?' — the '?' suppresses the iterate-over-null error).
installer_list() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | .installer$2" "$INVENTORY_FILE"
}

# installer_has NAME QUERY -> 0 if the .installer field is present (even if
# null/empty list), 1 if absent. Used to distinguish 'components absent'
# (defaults to main) from 'components: []' (no components).
installer_has() {
  require_yq "$YQ_AUTO"
  local name="$1" q="$2"
  N="$name" yq -e ".apps[] | select(.name == strenv(N)) | .installer$q != null" "$INVENTORY_FILE" >/dev/null 2>&1
}

# --- Safe path helpers ---------------------------------------------------
# normalize_path: resolve '~' and '..' then canonicalise.
# Returns the canonical path; exits non-zero if it escapes $HOME or /.
normalize_path() {
  local p="$1" allow_root="${2:-0}"
  if [ "$p" = "~" ]; then
    p="$HOME"
  else
    p="${p/#\~\//$HOME/}"
  fi
  # Reject '..' components — no traversal allowed.
  case "$p" in
    *..*) err "Path contains '..' traversal — rejected: $1"; return 1 ;;
  esac
  # Reject control characters.
  if printf '%s' "$p" | grep -q $'[\x00-\x1f\x7f]'; then
    err "Path contains control characters — rejected: $1"; return 1
  fi
  printf '%s\n' "$p"
}

# expand_path: turn ~/.config/foo into /home/user/.config/foo  (no canonicalisation)
expand_path() {
  local p="$1"
  if [ "$p" = "~" ]; then
    p="$HOME"
  else
    p="${p/#\~\//$HOME/}"
  fi
  printf '%s\n' "$p"
}

# Validate a path is contained under the expected root (realpath-aware).
# Usage: validate_path_contained "~/Documents" "$HOME"
validate_path_contained() {
  local raw="$1" root="${2:-$HOME}"
  local resolved
  resolved="$(normalize_path "$raw")" || return 1
  local realp
  realp="$(realpath -m -- "$resolved" 2>/dev/null || printf '%s' "$resolved")"
  case "$realp" in
    "$root"|"$root"/*) return 0 ;;
    *) err "Path '$raw' resolves to '$realp' which is outside '$root' — rejected."; return 1 ;;
  esac
}

# --- Inventory validation ------------------------------------------------
# Two layers:
#   1. STRUCTURAL — a versioned JSON Schema (inventory/schema.yaml, draft
#      2020-12) enforced with a real validator (lib/schema_check.py on python3 +
#      the reference `jsonschema` library). No ad-hoc parsing for structure.
#   2. SEMANTIC — rules a schema cannot express (unique names, path overlap,
#      default_shell provenance, interactive installers, platform support...).

# Supported platforms for the strict semantic platform check. Extend these
# constants when a platform becomes supported (keep them in sync with the
# yq bootstrap in require_yq, which knows amd64/arm64).
SUPPORTED_ARCHS="amd64 arm64"
SUPPORTED_UBUNTU_RELEASES="22.04 24.04"

# _schema_python: print the python3 interpreter that has the jsonschema + yaml
# modules (the real validator), or fail. Tries PATH python3 first, then
# /usr/bin/python3 (PATH can be minimal under systemd user timers).
_schema_python() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
    command -v python3
    return 0
  fi
  if [ -x /usr/bin/python3 ] && /usr/bin/python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
    printf '%s\n' '/usr/bin/python3'
    return 0
  fi
  return 1
}

# require_schema_validator [mode]: ensure a real schema validator exists.
# Mode: 0 = die, 1 = auto-install (apt), 2 = confirm first. Defaults to SCHEMA_AUTO.
require_schema_validator() {
  local mode="${1:-$SCHEMA_AUTO}"
  if _schema_python >/dev/null; then
    return 0
  fi
  if [ "$mode" = "0" ]; then
    die "Inventory schema validation needs python3 with the 'jsonschema' and 'yaml' modules. Install with: sudo apt-get install -y python3-jsonschema python3-yaml"
  fi
  if [ "$mode" = "2" ]; then
    confirm "Inventory schema validation needs python3 + jsonschema + yaml. Install python3-jsonschema python3-yaml now?" "n" || die "Aborted — install the validator and re-run."
  else
    info "python3 jsonschema/yaml not found — installing python3-jsonschema python3-yaml."
  fi
  require_cmd sudo
  require_cmd apt-get
  sudo apt-get update
  sudo apt-get install -y python3-jsonschema python3-yaml
  _schema_python >/dev/null || die "Schema validator still unavailable after the install. Run: sudo apt-get install -y python3-jsonschema python3-yaml"
}

# validate_schema_structure: run the real schema validator on the inventory.
# Returns 0 on success, 1 on any structural violation (output is printed).
validate_schema_structure() {
  require_schema_validator
  [ -f "$INVENTORY_SCHEMA" ] || die "Inventory schema not found: $INVENTORY_SCHEMA"
  local py rc=0 out
  py="$(_schema_python)" || return 1
  out="$( "$py" "$LIB_DIR/schema_check.py" "$INVENTORY_SCHEMA" "$INVENTORY_FILE" 2>&1 )" || rc=1
  printf '%s\n' "$out"
  return "$rc"
}

# check_system_support: strict platform gate (arch + Ubuntu release).
# Note: uses here-strings, never `cmd | grep -q` — under `set -o pipefail` a
# grep that exits on its first match SIGPIPEs a slow upstream writer (e.g. the
# snap yq) and turns a match into a 141 "failure".
check_system_support() {
  local errs=0 os_id="" os_ver="" supported
  supported="$(printf '%s\n' $SUPPORTED_ARCHS)"
  if ! grep -Fqx "$ARCH_NORM" <<< "$supported"; then
    warn "  unsupported architecture: '$ARCH_NORM' (supported: $(printf '%s' "$SUPPORTED_ARCHS" | tr ' ' '/'))"
    errs=$((errs + 1))
  fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    os_ver="${VERSION_ID:-}"
  fi
  if [ "$os_id" != "ubuntu" ]; then
    warn "  unsupported OS: '${os_id:-unknown}' (this repo targets Ubuntu)"
    errs=$((errs + 1))
  else
    supported="$(printf '%s\n' $SUPPORTED_UBUNTU_RELEASES)"
    if ! grep -Fqx "$os_ver" <<< "$supported"; then
      warn "  unsupported Ubuntu release: '${os_ver:-unknown}' (supported: $(printf '%s' "$SUPPORTED_UBUNTU_RELEASES" | tr ' ' '/'))"
      errs=$((errs + 1))
    fi
  fi
  return "$(( errs > 0 ? 1 : 0 ))"
}

# check_installer_templates: deb/tarball URLs (and checksum_url sidecars) may
# contain {version}, which must be resolvable from 'version' or 'version_url'.
# The old opaque install_command is gone (schema v2) — the structured
# installer types no longer carry free-form shell, so there is nothing left to
# heuristically scan for interactivity: remote scripts are an explicit
# last-resort type ('script') and their content is downloaded and executed as
# a file, never piped inline.
check_installer_templates() {
  local errs=0 name itype url csurl
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    itype="$(installer_get "$name" '.type')"
    url="$(installer_get "$name" '.url')"
    case "$itype" in
      deb|tarball)
        if [[ "$url" == *"{version}"* ]] && [ -z "$(installer_get "$name" '.version')" ] && [ -z "$(installer_get "$name" '.version_url')" ]; then
          warn "  app '$name': installer url uses {version} but neither 'version' nor 'version_url' is declared"
          errs=$((errs + 1))
        fi
        ;;
      script)
        if [[ "$url" == *"{version}"* ]]; then
          warn "  app '$name': script installer urls cannot use {version}"
          errs=$((errs + 1))
        fi
        ;;
    esac
    csurl="$(installer_get "$name" '.checksum_url')"
    if [ -n "$csurl" ] && [[ "$csurl" == *"{version}"* ]] && [ -z "$(installer_get "$name" '.version')" ] && [ -z "$(installer_get "$name" '.version_url')" ]; then
      warn "  app '$name': checksum_url uses {version} but neither 'version' nor 'version_url' is declared"
      errs=$((errs + 1))
    fi
  done < <(yaml_list '.apps[] | .name')
  return "$(( errs > 0 ? 1 : 0 ))"
}

# check_config_under_excluded: an app's own config_path must not sit under one
# of its own exclude patterns — rsync would strip it and it could never be
# backed up (silently producing an empty/partial artifact).
check_config_under_excluded() {
  local errs=0 name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    local -a excl=()
    local e
    while IFS= read -r e; do
      [ -n "$e" ] && excl+=("$e")
    done < <(app_get "$name" '.exclude[]?')
    [ "${#excl[@]}" -gt 0 ] || continue
    local p
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      local expanded rel
      expanded="$(expand_path "$p")"
      if [[ "$expanded" == "$HOME/"* ]]; then
        rel="${expanded#"$HOME"/}"
      else
        rel="${expanded#/}"
      fi
      local c
      local -a comp=()
      IFS='/' read -ra comp <<< "$rel"
      for c in "${comp[@]}"; do
        local ex
        for ex in "${excl[@]}"; do
          # shellcheck disable=SC2254  # exclude patterns may be globs
          if [[ "$c" == $ex ]]; then
            warn "  app '$name': config_path '$p' contains excluded component '$ex' — it will never be backed up; remove the config_path or the exclude"
            errs=$((errs + 1))
            c=""
            break
          fi
        done
        [ -n "$c" ] || break
      done
    done < <(app_get "$name" '.config_paths[]?')
  done < <(yaml_list '.apps[] | .name')
  return "$(( errs > 0 ? 1 : 0 ))"
}

# check_config_overlaps: cross-owner path ownership (apps, services, user_dirs).
#   - the exact same expanded path declared twice                    -> error
#   - one declared path nested under another owner's path            -> error,
#     UNLESS the outer owner is an app whose exclude list covers the nested
#     component (the deliberate "split ownership" case, e.g. freebuff's
#     ~/.config/manicode + user_dir ~/.config/manicode/projects with
#     exclude: projects).
check_config_overlaps() {
  local errs=0
  declare -a types=() owners=() paths=() labels=()
  declare -A app_excludes=()
  local name unit d e p
  # Fields are joined with a literal tab (config paths/excludes can never
  # contain control chars — the schema forbids them — so tab is a safe
  # separator; never use @tsv, which quotes double-quote fields).
  # _norm_overlap_path: expand + strip a trailing slash so ~/foo and ~/foo/
  # compare equal (a lone "/" stays "/").
  _norm_overlap_path() {
    local x
    x="$(expand_path "$1")"
    x="${x%/}"
    [ -n "$x" ] || x="/"
    printf '%s\n' "$x"
  }
  while IFS=$'\t' read -r name p; do
    [ -n "$p" ] || continue
    types+=(app); owners+=("$name"); paths+=("$(_norm_overlap_path "$p")"); labels+=("app '$name'")
  done < <(yq -r '.apps[] | . as $a | .config_paths[]? | $a.name + "\t" + .' "$INVENTORY_FILE")
  while IFS=$'\t' read -r name e; do
    [ -n "$name" ] && [ -n "$e" ] && app_excludes["$name"]+=" $e"
  done < <(yq -r '.apps[] | . as $a | .exclude[]? | $a.name + "\t" + .' "$INVENTORY_FILE")
  while IFS=$'\t' read -r unit p; do
    [ -n "$p" ] || continue
    types+=(service); owners+=("$unit"); paths+=("$(_norm_overlap_path "$p")"); labels+=("service '$unit'")
  done < <(yq -r '.services[] | . as $s | .config_paths[]? | $s.unit + "\t" + .' "$INVENTORY_FILE")
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    types+=(user_dir); owners+=(""); paths+=("$(_norm_overlap_path "$d")"); labels+=("user_dir")
  done < <(yaml_list '.user_dirs[]')

  local i j n="${#paths[@]}"
  for (( i = 0; i < n; i++ )); do
    for (( j = i + 1; j < n; j++ )); do
      local pi="${paths[$i]}" pj="${paths[$j]}"
      if [ "$pi" = "$pj" ]; then
        warn "  duplicate configuration ownership: ${labels[$i]} and ${labels[$j]} both declare '$pi'"
        errs=$((errs + 1))
        continue
      fi
      local outer_i inner_i
      if [[ "$pj" == "$pi"/* ]]; then
        outer_i=$i; inner_i=$j
      elif [[ "$pi" == "$pj"/* ]]; then
        outer_i=$j; inner_i=$i
      else
        continue
      fi
      local outer_p="${paths[$outer_i]}" inner_p="${paths[$inner_i]}"
      local rel first
      rel="${inner_p#"$outer_p"/}"
      first="${rel%%/*}"
      local allowed=0 pat
      if [ "${types[$outer_i]}" = "app" ]; then
        local oname="${owners[$outer_i]}"
        # shellcheck disable=SC2086  # word-split the space-joined exclude list
        for pat in ${app_excludes["$oname"]:-}; do
          # shellcheck disable=SC2254  # exclude patterns may be globs
          [[ "$first" == $pat ]] && { allowed=1; break; }
        done
      fi
      if [ "$allowed" = "0" ]; then
        warn "  overlapping declarations: ${labels[$inner_i]} ('$inner_p') is nested under ${labels[$outer_i]} ('$outer_p'); declare it under one owner only, or add the nested component to the outer app's exclude list to allow the split"
        errs=$((errs + 1))
      fi
    done
  done
  return "$(( errs > 0 ? 1 : 0 ))"
}

validate_inventory() {
  require_yq 0
  local errors=0

  # 1) STRUCTURAL — versioned JSON Schema via a real validator.
  if ! validate_schema_structure; then
    err "  Inventory failed schema validation (inventory/schema.yaml) — fix inventory.yaml first."
    errors=$((errors + 1))
  fi

  # 2) Platform support (strict: unsupported arch/release blocks).
  if ! check_system_support; then
    errors=$((errors + 1))
  fi

  # 3) Unique app names.
  local dupes
  dupes="$(yaml_list '.apps[] | .name' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    warn "  duplicate app names: $dupes"
    errors=$((errors + 1))
  fi

  # 4) Unique service unit names.
  dupes="$(yaml_list '.services[] | .unit' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    warn "  duplicate service unit names: $dupes"
    errors=$((errors + 1))
  fi

  # 5) default_shell must be provided by a declared package — either a declared
  #    app name, a declared apt package, the package name an apt-installed app
  #    overrides with (e.g. app 'myfish' installer type apt package 'fish'), or a
  #    package from an apt_repository app's installer.packages.
  #    (here-strings, not pipes: pipefail + early-exit grep SIGPIPEs slow yq)
  local shell_path shell_bin app_names pkg_names apt_pkgs
  shell_path="$(yaml_get '.default_shell')"
  if [ -n "$shell_path" ]; then
    shell_bin="$(basename "$shell_path")"
    app_names="$(yaml_list '.apps[] | .name')"
    pkg_names="$(yaml_list '.apt_packages[]')"
    apt_pkgs="$(yq -r '[.apps[] | select(.installer.type == "apt") | .installer.package // ""] + [.apps[] | select(.installer.type == "apt_repository") | .installer.packages[]?] | .[] | select(. != "")' "$INVENTORY_FILE")"
    if ! grep -Fqx "$shell_bin" <<< "$app_names" \
       && ! grep -Fqx "$shell_bin" <<< "$pkg_names" \
       && ! grep -Fqx "$shell_bin" <<< "$apt_pkgs"; then
      warn "  default_shell '$shell_path': no declared app, apt package, apt app package override, or apt_repository package provides '$shell_bin'"
      errors=$((errors + 1))
    fi
  fi

  # 6) user_dirs semantics: under $HOME, never $HOME itself (form + traversal
  #    are already enforced by the schema).
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$d" = "~" ]; then
      warn "  user_dirs: '\$HOME' itself cannot be a user dir"
      errors=$((errors + 1))
      continue
    fi
    if ! validate_path_contained "$d" "$HOME" 2>/dev/null; then
      warn "  user_dirs: path '$d' is not under \$HOME"
      errors=$((errors + 1))
    fi
  done < <(yaml_list '.user_dirs[]')

  # 7) deb/tarball URLs must resolve their {version} placeholders.
  if ! check_installer_templates; then
    errors=$((errors + 1))
  fi

  # 8) No config path nested under the same app's own excluded path.
  if ! check_config_under_excluded; then
    errors=$((errors + 1))
  fi

  # 9) No overlapping / duplicate path ownership across owners.
  if ! check_config_overlaps; then
    errors=$((errors + 1))
  fi

  if [ "$errors" -gt 0 ]; then
    warn "Inventory validation found $errors issue(s). Please fix inventory.yaml before continuing."
    return 1
  fi
  ok "Inventory validation: OK"
  return 0
}

# --- OS checks -----------------------------------------------------------
require_ubuntu() {
  local os_id=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi
  if [ "$os_id" != "ubuntu" ]; then
    die "This repo targets Ubuntu only (detected: ${os_id:-unknown}). Restore on a non-Ubuntu system is not supported."
  fi
}

require_non_root() {
  if [ "$(id -u)" = "0" ]; then
    die "Do not run this script as root. Run as the target user — sudo is used internally for individual system operations."
  fi
}

# --- Concurrency protection (flock) --------------------------------------
# Usage: with_lock LOCKFILE command...
# Acquires an exclusive, non-blocking lock; dies if another instance is running.
LOCK_FD=9
with_lock() {
  local lockfile="$1"; shift
  mkdir -p "$(dirname "$lockfile")"
  exec 9>"$lockfile"
  if ! flock -n 9; then
    die "Another instance is already running (lock: $lockfile). Wait for it to finish."
  fi
}

release_lock() {
  flock -u 9 2>/dev/null || true
  exec 9>&- 2>/dev/null || true
}

# --- Backup manifest -----------------------------------------------------
# Write an in-progress marker. This ALWAYS goes into the STAGING manifest
# ($STAGE/backup-info.txt), never into the live backups/backup-info.txt:
# the live manifest is only ever replaced atomically by publish_backup with
# a generation that passed final verification. Writing the marker into live
# would (a) modify the last-known-good backup in place and (b) make any
# rollback to the previous generation un-restorable (restore refuses
# 'in_progress' manifests).
# Falls back to $BACKUP_MANIFEST only if STAGE is not set (callers that have
# no staging concept, e.g. restore.sh — never call this in that case).
manifest_in_progress() {
  local run_id="$1" target=""
  if [ -n "${STAGE:-}" ]; then
    target="$STAGE/backup-info.txt"
  else
    target="$BACKUP_MANIFEST"
  fi
  {
    echo "run_id: $run_id"
    echo "status: in_progress"
    echo "started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$target"
}

# Write the final manifest with artifact tracking.
manifest_final() {
  local run_id="$1" mir_stat="$2" artifact_file="$3"
  local inventory_sha git_commit os_ver overall="ok"
  inventory_sha="$(sha256sum "$INVENTORY_FILE" 2>/dev/null | cut -d' ' -f1 || echo "unknown")"
  git_commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
  os_ver=""
  [ -r /etc/os-release ] && { . /etc/os-release; os_ver="${VERSION_ID:-}"; } 2>/dev/null || true

  # Derive the overall status from the artifact list. Any missing/incomplete
  # artifact degrades the backup (an app with no config paths is 'empty', not a
  # failure). Restore requires 'status: ok' before restoring configuration.
  if [ -s "$artifact_file" ] && grep -Eq '/(missing|incomplete|missing-unit)$' "$artifact_file"; then
    overall="degraded"
  fi

  {
    echo "run_id: $run_id"
    echo "status: $overall"
    echo "host: $(hostname)"
    echo "user: $USER"
    echo "arch: $ARCH_NORM"
    [ -n "$os_ver" ] && echo "ubuntu_version: $os_ver"
    echo "repo: $REPO_ROOT"
    [ -n "$git_commit" ] && echo "git_commit: $git_commit"
    echo "inventory_sha256: $inventory_sha"
    echo "started: ${BACKUP_STARTED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
    echo "finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "mirror: $mir_stat"
    echo "---"
    if [ -s "$artifact_file" ]; then
      cat "$artifact_file"
    fi
  }
}

# Count artifact lines with a given status.
manifest_count_status() {
  local status="$1" file="$2"
  [ -f "$file" ] || { echo "0"; return 0; }
  # grep -c prints the count (including '0') and exits 1 on no match;
  # guard the exit code only, never print a second '0'.
  grep -c "^.*/$status$" "$file" 2>/dev/null || true
}

# Verify a manifest for restore readiness.
# Returns 0 if the backup is complete and can be restored.
# Returns 1 if the backup is incomplete/degraded and should not be restored
# without explicit override.
manifest_verify_restorable() {
  local mf="$1"
  [ -f "$mf" ] || { err "No backup manifest found at $mf."; return 1; }

  if ! grep -q '^status: ok$' "$mf"; then
    err "Backup manifest does not report 'status: ok' — the backup is incomplete or failed."
    if grep -q '^status: in_progress$' "$mf"; then
      err "  The last backup run was interrupted (still 'in_progress'). Do not restore from this snapshot."
    fi
    return 1
  fi

  # Check that at least some artifacts were captured.
  if ! grep -q '^---$' "$mf"; then
    err "Backup manifest has no artifact list — cannot verify completeness."
    return 1
  fi

  ok "Backup manifest verified: status=ok"
  return 0
}

# --- Backup publication (transactional swap) -----------------------------
# publish_backup: atomically publish the staged generation as the live
# backups/. Guarantees:
#   * STAGE and backups/ must be on the SAME filesystem — rename(2) across
#     devices is not atomic and can fail; verified before anything is moved.
#   * The live dir is renamed aside FIRST, and the script fails immediately
#     if that rename fails — it never moves staging over an existing live dir.
#   * The previous generation is kept until the new one passes a final
#     manifest verification ('status: ok'); only then is it dropped.
#   * If the new generation fails verification and a previous generation
#     exists, we roll back to it (restore refuses non-ok manifests, so a
#     degraded live backup would be unusable).
#   * A cleanup trap removes leftovers from interrupted runs, and once the new
#     generation is verified, any backups.old.* generations.
#   * Crash consistency: after the swap the directory could be fsync'ed for
#     stronger guarantees (optional — not done by default; see README FAQ).
# Uses globals: STAGE, BACKUPS_DIR, BACKUP_MANIFEST, ARTIFACTS, REPO_ROOT.
publish_backup() {
  _PUBLISHED=0
  _old_gen=""
  _cleanup_publish() {
    local rc="$1"
    # Clear traps first: a signal handler that exits would otherwise re-fire
    # the EXIT trap and run this cleanup twice.
    trap - EXIT INT TERM
    # Not yet published + a previous generation exists => the new generation
    # was never verified (live absent, or present but not 'status: ok' because
    # a signal landed between the swap and verification). Restore the
    # last-known-good so it stays live.
    if [ "$_PUBLISHED" != "1" ] && [ -d "$_old_gen" ]; then
      if [ ! -d "$BACKUPS_DIR" ] || ! grep -q '^status: ok$' "$BACKUP_MANIFEST" 2>/dev/null; then
        rm -rf "$BACKUPS_DIR" 2>/dev/null || true
        if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
          warn "Backup run interrupted before the new generation was verified — restored the previous backup generation."
        fi
      fi
    fi
    rm -f "$ARTIFACTS" 2>/dev/null || true
    # STAGE only still exists when the run died before publishing.
    rm -rf "$STAGE" 2>/dev/null || true
    # Only drop previous generations once the new one was verified good.
    if [ "$_PUBLISHED" = "1" ]; then
      rm -rf "$REPO_ROOT"/backups.old.* 2>/dev/null || true
    fi
    exit "$rc"
  }
  trap '_cleanup_publish $?' EXIT INT TERM

  # Nothing to publish?
  [ -d "$STAGE" ] || die "Nothing to publish: staging directory not found at $STAGE."

  # Same-filesystem check — both renames must stay within one device. Compare
  # STAGE against the live dir's own device (it may be a mountpoint on another
  # filesystem even though it lives under the repo root) and against the repo
  # root as a fallback.
  local stage_dev root_dev live_dev
  stage_dev="$(stat -c %d "$STAGE" 2>/dev/null || true)"
  root_dev="$(stat -c %d "$REPO_ROOT" 2>/dev/null || true)"
  live_dev=""
  [ -d "$BACKUPS_DIR" ] && live_dev="$(stat -c %d "$BACKUPS_DIR" 2>/dev/null || true)"
  if [ -n "$stage_dev" ] && [ -n "$live_dev" ] && [ "$stage_dev" != "$live_dev" ]; then
    die "backups.staging and backups/ are on different filesystems (the live dir is its own mountpoint) — the swap would not be atomic. Keep the repo on a single filesystem."
  fi
  if [ -n "$stage_dev" ] && [ -n "$root_dev" ] && [ "$stage_dev" != "$root_dev" ]; then
    die "backups.staging and backups/ are on different filesystems — the swap would not be atomic. Keep the repo on a single filesystem."
  fi

  # Swap: live -> backups.old.<pid> (previous generation), staging -> live.
  if [ -d "$BACKUPS_DIR" ]; then
    # Stray generations from a crashed run are superseded by the live dir.
    rm -rf "$REPO_ROOT"/backups.old.* 2>/dev/null || true
    _old_gen="$REPO_ROOT/backups.old.$$"
    if ! mv "$BACKUPS_DIR" "$_old_gen" 2>/dev/null; then
      die "Could not move the existing backups/ aside (permissions or I/O error) — the previous backup was NOT modified."
    fi
  fi
  if ! mv "$STAGE" "$BACKUPS_DIR" 2>/dev/null; then
    if [ -d "$_old_gen" ]; then
      if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
        die "Failed to publish the new backup — the previous backup has been restored."
      fi
      die "CRITICAL: publishing the new backup failed AND rolling back failed. Manual recovery: the previous backup is at $_old_gen."
    fi
    die "Failed to publish the new backup (no previous generation existed)."
  fi

  # Final verification: keep (or restore) the previous generation unless the
  # new one reports 'status: ok'. Three cases:
  #   * manifest present + 'status: ok'   -> keep the new generation, drop old
  #   * manifest present + degraded       -> restore the old generation if one
  #     exists; otherwise keep the new one as-is (it is the only snapshot, and
  #     restore.sh can use it with --force-incomplete), with a loud warning.
  #   * manifest absent (or unreadable)   -> the new generation is unusable by
  #     restore.sh (hard refusal, no override). Restore the old generation if
  #     one exists; otherwise remove the broken live dir and fail hard.
  if grep -q '^status: ok$' "$BACKUP_MANIFEST" 2>/dev/null; then
    _PUBLISHED=1
  elif [ -r "$BACKUP_MANIFEST" ]; then
    warn "The new generation's manifest does not report 'status: ok' — restore would need --force-incomplete."
    if [ -d "$_old_gen" ]; then
      rm -rf "$BACKUPS_DIR" || die "Could not remove the unverified generation at $BACKUPS_DIR — previous backup preserved at $_old_gen."
      if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
        warn "Rolled back to the previous (verified) backup generation."
      else
        die "Could not roll back — the previous generation is preserved at $_old_gen."
      fi
    else
      warn "No previous generation to roll back to — keeping the new generation as-is (review backup-info.txt)."
      _PUBLISHED=1
    fi
  else
    if [ -d "$_old_gen" ]; then
      rm -rf "$BACKUPS_DIR" || die "Could not remove the unverified generation at $BACKUPS_DIR — previous backup preserved at $_old_gen."
      if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
        warn "The new generation has no manifest — rolled back to the previous (verified) backup generation."
      else
        die "Could not roll back — the previous generation is preserved at $_old_gen."
      fi
    else
      rm -rf "$BACKUPS_DIR" || die "Could not remove the unusable new generation at $BACKUPS_DIR — no previous backup existed, so there is nothing to fall back to."
      die "The new generation has no manifest and no previous backup exists — refusing to keep an unusable backups/ directory."
    fi
  fi
  rm -f "$ARTIFACTS"
  # Publication is complete — drop the previous generation now that the new one
  # is verified, and clear the trap so it does not re-fire at script exit.
  if [ "$_PUBLISHED" = "1" ]; then
    rm -rf "$REPO_ROOT"/backups.old.* 2>/dev/null || true
  fi
  trap - EXIT INT TERM
  return 0
}

# --- Installed-status checkers (source-specific) -------------------------
is_apt_installed() {
  dpkg -s "$1" >/dev/null 2>&1 || return 1
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q ' install ok installed'
}

is_snap_installed() {
  command -v snap >/dev/null 2>&1 || return 1
  snap list "$1" >/dev/null 2>&1
}

is_flatpak_installed() {
  command -v flatpak >/dev/null 2>&1 || return 1
  flatpak info "$1" >/dev/null 2>&1
}

# is_app_installed_by_source NAME -> true if the app is installed via its declared source.
# This is stricter than mere 'command -v' — it verifies the expected package manager.
is_app_installed_by_source() {
  local name="$1" itype check pkg
  itype="$(installer_get "$name" '.type')"
  check="$(app_get "$name" '.check_cmd')"
  pkg="$(installer_get "$name" '.package')"
  [ -n "$pkg" ] || pkg="$name"

  case "$itype" in
    apt)           is_apt_installed "$pkg" && return 0 || return 1 ;;
    snap|snap_classic) is_snap_installed "$pkg" && return 0 || return 1 ;;
    flatpak)       is_flatpak_installed "$pkg" && return 0 || return 1 ;;
    npm_global)
      command -v npm >/dev/null 2>&1 && npm list -g --depth=0 "$pkg" >/dev/null 2>&1 && return 0 || return 1 ;;
    pipx)
      command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -q "^$pkg " && return 0 || return 1 ;;
    cargo)
      command -v "$check" >/dev/null 2>&1 && return 0 || return 1 ;;
    apt_repository)
      # Source-specific: every declared repo package must be installed via dpkg
      # (not just the check binary present — it could come from another source).
      local -a rpkgs=()
      local rp rp_all=1
      while IFS= read -r rp; do [ -n "$rp" ] && rpkgs+=("$rp"); done < <(installer_list "$name" '.packages[]?')
      if [ "${#rpkgs[@]}" -gt 0 ]; then
        for rp in "${rpkgs[@]}"; do
          is_apt_installed "$rp" || { rp_all=0; break; }
        done
        [ "$rp_all" = "1" ] && return 0
        return 1
      fi
      [ -n "$check" ] && command -v "$check" >/dev/null 2>&1 && return 0 || return 1 ;;
    deb|tarball|script)
      [ -n "$check" ] && command -v "$check" >/dev/null 2>&1 && return 0 || return 1 ;;
    *) return 1 ;;
  esac
}

# is_app_installed NAME -> true if the app appears installed via its declared
# source (used by ./inventory.sh list). Delegates to the source-specific
# checker so the list agrees with what restore would do for every installer
# type (apt_repository apps are only "installed" when their repo packages are).
is_app_installed() {
  is_app_installed_by_source "$1"
}
