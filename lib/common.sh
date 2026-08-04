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
# shellcheck source=lib/catalog.sh
source "$LIB_DIR/catalog.sh"   # catalog_lookup + catalog_to_yaml (catalog refs, schema v5)
# Test-override guard: the automated suite (tests/) runs backup.sh against a
# fully sandboxed repo by overriding REPO_ROOT / INVENTORY_FILE /
# INVENTORY_SCHEMA / BACKUPS_DIR / STAGE / ARTIFACTS / BACKUP_LOCK. Production
# must NEVER honor those overrides — a stray REPO_ROOT/BACKUPS_DIR/... in the
# environment (another tool exporting it, a cron wrapper, a hand-rolled
# systemd unit) could redirect destructive operations (rm -rf staging, the
# publish mv) at arbitrary paths. Overrides only apply when the test harness
# explicitly opts in with BRU_ALLOW_TEST_OVERRIDES=1 (exported by
# tests/helpers.sh); otherwise the defaults below are unconditional.
BRU_ALLOW_TEST_OVERRIDES="${BRU_ALLOW_TEST_OVERRIDES:-0}"
if [ "$BRU_ALLOW_TEST_OVERRIDES" = "1" ]; then
  # The opt-in sentinel alone must never unlock arbitrary destructive paths.
  # When REPO_ROOT is EXPORTED into the environment (a production wrapper, a
  # stray export, a sandboxed backup.sh child), it must point at a TEST
  # SANDBOX (.test-tmp.* under the real repo — the only layout
  # tests/helpers.sh's sandbox_new produces). This stops a stray
  # BRU_ALLOW_TEST_OVERRIDES=1 from redirecting the staging rm -rf / publish
  # mv at /srv/data or any other path through a poisoned REPO_ROOT. backup.sh
  # additionally containment-checks STAGE, ARTIFACTS, BACKUPS_DIR and
  # BACKUP_LOCK under REPO_ROOT (require_contained_dir) before anything
  # destructive runs.
  # NOTE: helpers.sh sets REPO_ROOT as a PLAIN (non-exported) shell variable
  # in the test process, which does not appear in `env` — only an actual
  # environment override trips this guard.
  _bru_root_in_env=0
  while IFS= read -r _bru_line; do
    case "$_bru_line" in
      REPO_ROOT=*) _bru_root_in_env=1; break ;;
    esac
  done < <(env)
  if [ "$_bru_root_in_env" = "1" ]; then
    _bru_root_real="$(realpath -m -- "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
    case "$(basename "$_bru_root_real")" in
      .test-tmp.*) : ;;
      *)
        # err() is not defined yet at source time — format the message inline.
        printf '\033[1;31m[ERR ]\033[0m %s\n' "BRU_ALLOW_TEST_OVERRIDES=1 but REPO_ROOT='$REPO_ROOT' is not a test sandbox (.test-tmp.*) — refusing to honor path overrides." >&2
        exit 1 ;;
    esac
  fi
  REPO_ROOT="${REPO_ROOT:-$(cd "$LIB_DIR/.." && pwd)}"
  INVENTORY_FILE="${INVENTORY_FILE:-$REPO_ROOT/inventory/inventory.yaml}"
  INVENTORY_SCHEMA="${INVENTORY_SCHEMA:-$REPO_ROOT/inventory/schema.yaml}"   # versioned JSON Schema (draft 2020-12)
  # shellcheck disable=SC2034  # consumed by backup.sh / restore.sh after sourcing
  BACKUPS_DIR="${BACKUPS_DIR:-$REPO_ROOT/backups}"
  # /etc/cron.d source dir for declared cron.d jobs — test-overridable so
  # sandboxed backup/restore runs never touch the real system cron.d (same
  # opt-in guard as the other overrides).
  CRON_D_DIR="${CRON_D_DIR:-/etc/cron.d}"
else
  REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
  INVENTORY_FILE="$REPO_ROOT/inventory/inventory.yaml"
  INVENTORY_SCHEMA="$REPO_ROOT/inventory/schema.yaml"
  BACKUPS_DIR="$REPO_ROOT/backups"
  CRON_D_DIR="/etc/cron.d"
fi
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
# Path every getter/script reads inventory data from. Points at the REAL
# inventory.yaml unless a catalog reference has been resolved (schema v5):
# resolve_effective_inventory() sets it to the effective (resolved) file.
# inventory.sh's EDIT commands always use INVENTORY_FILE (the raw file).
INVENTORY_READ="$INVENTORY_FILE"
# Path of the effective (catalog-resolved) inventory; empty when the
# inventory has no catalog references (or resolution has not run).
EFFECTIVE_INVENTORY=""
# Directory of THIS process's last resolved inventory (owned by us, see
# resolve_effective_inventory); empty when none. Never shared across
# processes — every resolve uses a pid-scoped dir so concurrent runs cannot
# clobber each other's effective file.
BRU_EFFECTIVE_DIR=""
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

# esc: escape a string for safe inclusion inside a double-quoted YAML scalar
# (backslashes + double quotes). Shared by inventory.sh's write_app and
# catalog.sh's catalog_to_yaml.
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# require_safe_dir NAME PATH — defensive guard for the directories destructive
# operations run against (staging, artifact file, live backups). Rejects
# empty, '/', '.', '..' and any path that realpath-resolves to one of those.
# Returns 1 (after err) when unsafe; callers decide whether to die.
require_safe_dir() {
  local name="$1" val="$2"
  case "$val" in
    ""|"/"|"."|"..")
      err "Unsafe $name path: '$val' — refusing to run."; return 1 ;;
  esac
  local real
  real="$(realpath -m -- "$val" 2>/dev/null || true)"
  case "$real" in
    ""|"/"|"."|"..")
      err "Unsafe $name path resolves to '$real' — refusing to run."; return 1 ;;
  esac
  return 0
}

# require_contained_dir NAME PATH ROOT — require_safe_dir plus a containment
# check: PATH's realpath must be ROOT itself or live under it. Used for every
# directory destructive operations run against (staging, artifact file, live
# backups, lock file) so a poisoned environment or a bad test override can
# never redirect rm -rf / mv outside the repo (or the test sandbox).
# Production paths always derive from REPO_ROOT, so this is a no-op guard
# there.
require_contained_dir() {
  local name="$1" val="$2" root="$3"
  require_safe_dir "$name" "$val" || return 1
  require_safe_dir "$name" "$root" || return 1
  local rv rr re rrf
  rv="$(realpath -m -- "$val" 2>/dev/null || printf '%s' "$val")"
  rr="$(realpath -m -- "$root" 2>/dev/null || printf '%s' "$root")"
  case "$rv" in
    "$rr"|"$rr"/*) : ;;
    *)
      err "Unsafe $name path: '$val' escapes root '$root' — refusing to run."
      return 1 ;;
  esac
  # Symlink hardening: realpath -m is purely lexical, so a symlink INSIDE the
  # root pointing outside (e.g. $SB/backups -> /etc) would pass the check
  # above. When the paths already exist, resolve symlinks fully and re-check.
  # Non-existent paths are fine — there is nothing to follow yet.
  if [ -e "$val" ] && [ -e "$root" ]; then
    re="$(realpath -e -- "$val" 2>/dev/null || true)"
    rrf="$(realpath -e -- "$root" 2>/dev/null || true)"
    if [ -n "$re" ] && [ -n "$rrf" ]; then
      case "$re" in
        "$rrf"|"$rrf"/*) return 0 ;;
      esac
      err "Unsafe $name path: '$val' resolves (through symlinks) to '$re' outside '$root' — refusing to run."
      return 1
    fi
  fi
  return 0
}

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
# Getter reads use "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}" — the effective
# (catalog-resolved) file when resolve_effective_inventory ran, otherwise the
# CURRENT $INVENTORY_FILE (evaluated at call time, so a caller that swaps
# INVENTORY_FILE after sourcing common.sh still reads the right file — the
# test suite does exactly that). Scripts' direct yq calls use $INVENTORY_READ,
# which resolve_effective_inventory keeps in sync.
yaml_get() {
  require_yq "$YQ_AUTO"
  yq -r "$1 // \"\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

yaml_list() {
  require_yq "$YQ_AUTO"
  yq -r "$1" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

# app_get NAME QUERY -> scalar attribute of one app (empty if absent)
# Uses environment variable to avoid YAML injection.
app_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | $2 // \"\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

# cron_job_get NAME QUERY -> scalar attribute of one cron job (empty if absent)
# Uses environment variable to avoid YAML injection. QUERY is always a fixed
# expression like '.source' or '.on_missing'. Null-safe: cron_jobs is OPTIONAL
# in the schema (v3-v5 inventories may omit it), so reads use `.cron_jobs[]?`.
cron_job_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".cron_jobs[]? | select(.name == strenv(N)) | $2 // \"\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

# installer_get NAME QUERY -> scalar attribute under .installer (empty if absent)
# QUERY is always a fixed expression like '.type' or '.package'.
installer_get() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | .installer$2 // \"\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

# installer_list NAME QUERY -> lines under .installer (callers pass '.packages[]?'
# or '.components[]?' — the '?' suppresses the iterate-over-null error).
installer_list() {
  require_yq "$YQ_AUTO"
  N="$1" yq -r ".apps[] | select(.name == strenv(N)) | .installer$2" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}"
}

# installer_has NAME QUERY -> 0 if the .installer field is present (even if
# null/empty list), 1 if absent. Used to distinguish 'components absent'
# (defaults to main) from 'components: []' (no components).
installer_has() {
  require_yq "$YQ_AUTO"
  local name="$1" q="$2"
  N="$name" yq -e ".apps[] | select(.name == strenv(N)) | .installer$q != null" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}" >/dev/null 2>&1
}

# user_dir_paths: list user_dirs entries as PLAIN PATHS, handling both the
# legacy string form (schema v3-v6) and the new object form with path+exclude
# (schema v7). For each item:
#   - string -> print the string as-is
#   - object with .path -> print .path
# Returns one path per line (empty lines suppressed).
user_dir_paths() {
  require_yq "$YQ_AUTO"
  yq -r '.user_dirs[] | (if type == "object" then .path else . end)' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}" 2>/dev/null | grep -v '^\s*$' || true
}

# user_dir_exclude PATH -> prints the exclude patterns for one user_dir entry
# (one per line, empty if none). PATH is the expanded path (e.g.
# ~/.config/manicode/projects). Only object-form entries with an exclude list
# produce output; legacy string-form entries produce nothing.
user_dir_exclude() {
  require_yq "$YQ_AUTO"
  local ud_path="$1"
  # Match the entry in user_dirs that has this path (either as a plain string
  # or as .path in an object). Then print its .exclude[] items.
  N="$ud_path" yq -r '.user_dirs[] | select((type == "object" and .path == strenv(N)) or (type == "string" and . == strenv(N))) | (if type == "object" and has("exclude") then .exclude[] else "" end)' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}" 2>/dev/null | grep -v '^\s*$' || true
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
  # Reject control characters. LC_ALL=C + [[:cntrl:]] over a here-string
  # catches every control byte except an embedded newline (grep treats \n as
  # a line terminator), so reject those explicitly too. Never pipe into
  # grep -q here: under set -o pipefail a match would SIGPIPE the writer and
  # turn a hit into a 141 'failure'. The previous $'[\x00-\x1f\x7f]' pattern
  # embedded a literal NUL byte, which truncated the pattern and silently let
  # control characters through.
  if [[ "$p" == *$'\n'* ]] || LC_ALL=C grep -q '[[:cntrl:]]' <<< "$p" 2>/dev/null; then
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

# Declared support matrix (2026-08-03): Ubuntu on AMD64 ONLY.
#   * Architecture is hard-locked to amd64 — arm64 is deliberately NOT
#     supported (no arm64 machine; headline apps like Chrome are amd64-only;
#     arm64 support would be untested scaffolding). Change SUPPORTED_ARCHS if
#     that ever changes.
#   * The Ubuntu RELEASE is deliberately NOT locked: any Ubuntu release runs
#     (version-agnostic, matching the repo's no-version-pinning principle).
#     Cross-release restores are still flagged: the manifest records
#     `ubuntu_version:` and restore.sh --source warns on a mismatch.
SUPPORTED_ARCHS="amd64"

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

# validate_schema_structure [FILE]: run the real schema validator on FILE
# (defaults to $INVENTORY_FILE — the raw inventory; callers validating the
# resolved inventory pass the effective path explicitly).
# Returns 0 on success, 1 on any structural violation (output is printed).
validate_schema_structure() {
  require_schema_validator
  local inv="${1:-$INVENTORY_FILE}"
  [ -f "$INVENTORY_SCHEMA" ] || die "Inventory schema not found: $INVENTORY_SCHEMA"
  [ -f "$inv" ] || die "Inventory file not found: $inv"
  local py rc=0 out
  py="$(_schema_python)" || return 1
  out="$( "$py" "$LIB_DIR/schema_check.py" "$INVENTORY_SCHEMA" "$inv" 2>&1 )" || rc=1
  printf '%s\n' "$out"
  return "$rc"
}

# check_system_support: strict platform gate (Ubuntu OS family + amd64). The
# Ubuntu RELEASE is intentionally NOT gated (see the SUPPORTED_ARCHS comment) —
# only the OS family and the architecture are. Cross-release restores are
# flagged separately via the manifest `ubuntu_version:` record + --source.
# Note: uses here-strings, never `cmd | grep -q` — under `set -o pipefail` a
# grep that exits on its first match SIGPIPEs a slow upstream writer (e.g. the
# snap yq) and turns a match into a 141 "failure".
check_system_support() {
  local errs=0 os_id="" supported
  supported="$(printf '%s\n' $SUPPORTED_ARCHS)"
  if ! grep -Fqx "$ARCH_NORM" <<< "$supported"; then
    warn "  unsupported architecture: '$ARCH_NORM' (this repo supports AMD64 only — see SUPPORTED_ARCHS in lib/common.sh)"
    errs=$((errs + 1))
  fi
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi
  if [ "$os_id" != "ubuntu" ]; then
    warn "  unsupported OS: '${os_id:-unknown}' (this repo targets Ubuntu)"
    errs=$((errs + 1))
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

# check_timer_pairing — for every declared service unit ending in .timer, warn
# when the paired stem.service is neither declared in the inventory nor present
# on disk: after a FRESH restore the timer would be installed but could never
# fire (its service unit would not have been backed up). Warn-only by design —
# the timer unit itself is still restorable, and the pairing may legitimately
# target a system-provided unit. The restore path repeats this message when it
# enables a timer whose pair is undeclared.
check_timer_pairing() {
  local unit stem paired found units
  # Here-string, never `yq | grep -q` — under pipefail an early-exit grep
  # SIGPIPEs a slow yq and turns a match into a 141 'failure' (see the
  # default_shell check for the same convention).
  units="$(yq -r '.services[] | .unit' "$INVENTORY_READ")"
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [[ "$unit" == *.timer ]] || continue
    stem="${unit%.timer}"
    paired="$stem.service"
    found=0
    if grep -Fqx "$paired" <<< "$units"; then
      found=1
    elif [ -f "$HOME/.config/systemd/user/$paired" ] || [ -f "/etc/systemd/system/$paired" ]; then
      found=1
    fi
    if [ "$found" = "0" ]; then
      warn "  timer '$unit': paired unit '$paired' is neither declared nor on disk — after a fresh restore this timer would not fire. Declare '$paired' in services: (or remove the timer)."
    fi
  done < <(yaml_list '.services[] | .unit')
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
  done < <(yq -r '.apps[] | . as $a | .config_paths[]? | $a.name + "\t" + .' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")
  while IFS=$'\t' read -r name e; do
    [ -n "$name" ] && [ -n "$e" ] && app_excludes["$name"]+=" $e"
  done < <(yq -r '.apps[] | . as $a | .exclude[]? | $a.name + "\t" + .' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")
  while IFS=$'\t' read -r unit p; do
    [ -n "$p" ] || continue
    types+=(service); owners+=("$unit"); paths+=("$(_norm_overlap_path "$p")"); labels+=("service '$unit'")
  done < <(yq -r '.services[] | . as $s | .config_paths[]? | $s.unit + "\t" + .' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    types+=(user_dir); owners+=(""); paths+=("$(_norm_overlap_path "$d")"); labels+=("user_dir")
  done < <(user_dir_paths)

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

# --- Catalog-reference resolution (schema v5) ----------------------------
# resolve_effective_inventory: expand `catalog:` references in the RAW
# inventory ($INVENTORY_FILE) into a fully-resolved document and point every
# getter at it. Semantics (validated against the repo's yq):
#   * The effective record = catalog template * overrides (yq `*` merge: maps
#     deep-merge, scalars right-win, arrays replace wholesale — exactly right
#     for overrides like `installer: {url: new}` which keep the rest of the
#     template's installer).
#   * ARRAY fields that the overrides set (config_paths, exclude, extensions,
#     depends_apt, installer.packages, installer.components) are APPENDED to
#     the template's list and deduped instead of replacing it — the common
#     "add a path to the catalog's defaults" case, and the drift-reduction
#     goal: a catalog fix reaches every referencing entry automatically.
#     NOTE: the `| unique` below is the MIKE-FARAH-yq form, which dedupes
#     while preserving FIRST-SEEN order (it does NOT sort like jq's unique) —
#     so the merged array really is "template order + new override items in
#     override order". This behavior is locked by tests/test_catalog.sh.
#   * Non-catalog app entries pass through unchanged.
# Dies on an unknown catalog key. No-op fast path when nothing references the
# catalog. Sets:
#   INVENTORY_READ       -> the effective file (or $INVENTORY_FILE)
#   EFFECTIVE_INVENTORY  -> the effective file path (empty when no refs)
# The effective file lives under $REPO_ROOT (.inventory-resolve.<pid>.*,
# git-ignored) because the snap-packaged yq cannot read /tmp. Lifecycle:
#   * Each call uses its OWN fresh pid-scoped dir. A second call in the same
#     process removes the previous dir (tracked in BRU_EFFECTIVE_DIR) — so a
#     caller must not keep relying on an old INVENTORY_READ path after
#     re-resolving.
#   * Dirs owned by OTHER live processes are NEVER removed (their pid is in
#     the dir name and checked via kill -0), so concurrent backup.sh /
#     restore.sh / inventory.sh list / update_all_ubuntu.sh runs cannot
#     clobber each other's effective inventory. A run's effective dir lives
#     for its process lifetime (the getters read it after resolve returns) and
#     is swept — as a dead-pid dir — by the next resolution; legacy
#     non-pid-scoped dirs are swept at the same time. Steady state is at most
#     one leftover git-ignored dir between runs.
_resolve_cleanup_stale() {
  local d pid
  for d in "$REPO_ROOT"/.inventory-resolve.*; do
    [ -d "$d" ] || continue
    pid="${d##*.inventory-resolve.}"
    pid="${pid%%.*}"
    case "$pid" in
      "$$") : ;;   # our own dir — removed by the caller via BRU_EFFECTIVE_DIR
      *[!0-9]*|"") rm -rf "$d" 2>/dev/null || true ;;  # legacy/unparseable -> stale garbage
      *) if ! kill -0 "$pid" 2>/dev/null; then rm -rf "$d" 2>/dev/null || true; fi ;;
    esac
  done
}

resolve_effective_inventory() {
  require_yq 0
  local n_refs
  n_refs="$(yq -r '[.apps[] | select(has("catalog"))] | length' "$INVENTORY_FILE" 2>/dev/null || echo 0)"
  if [ "${n_refs:-0}" = "0" ] || [ -z "${n_refs:-}" ]; then
    # Fast path — no refs: drop our previous dir (if any) and reset. Also
    # sweep stale dirs from crashed runs; the pid-scoped layout makes this
    # safe against live concurrent resolvers.
    if [ -n "$BRU_EFFECTIVE_DIR" ]; then
      rm -rf "$BRU_EFFECTIVE_DIR" 2>/dev/null || true
      BRU_EFFECTIVE_DIR=""
    fi
    _resolve_cleanup_stale
    INVENTORY_READ="$INVENTORY_FILE"
    EFFECTIVE_INVENTORY=""
    return 0
  fi

  # Clean stale dirs from crashed runs (dead pids only) and our own previous
  # dir from an earlier resolve in this process. NEVER a blanket wipe: a live
  # concurrent process may be reading its own effective file right now.
  _resolve_cleanup_stale
  if [ -n "$BRU_EFFECTIVE_DIR" ]; then
    rm -rf "$BRU_EFFECTIVE_DIR" 2>/dev/null || true
  fi
  local edir tmpl ovr merged frag eff
  edir="$(mktemp -d "$REPO_ROOT/.inventory-resolve.$$.XXXXXX")"
  BRU_EFFECTIVE_DIR="$edir"
  tmpl="$edir/tmpl.yml"; ovr="$edir/ovr.yml"; merged="$edir/merged.yml"
  frag="$edir/frag.yml"; eff="$edir/effective.yml"

  # The effective document starts as the raw inventory with apps: [] — every
  # top-level scalar/list is preserved; the apps array is rebuilt below.
  yq -n 'load("'"$INVENTORY_FILE"'") | .apps = []' > "$eff"

  local name ck has_cat
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    has_cat="$(N="$name" yq -r '.apps[] | select(.name == strenv(N)) | has("catalog")' "$INVENTORY_FILE")"
    if [ "$has_cat" != "true" ]; then
      # Pass-through: re-emit the raw entry unchanged.
      N="$name" yq -n 'load("'"$INVENTORY_FILE"'") | .apps[] | select(.name == strenv(N))' > "$frag"
    else
      ck="$(N="$name" yq -r '.apps[] | select(.name == strenv(N)) | .catalog' "$INVENTORY_FILE")"
      [ -n "$ck" ] || die "App '$name' has an empty catalog key."
      catalog_to_yaml "$ck" > "$tmpl" || die "App '$name' references unknown catalog key '$ck' (lib/catalog.sh)."
      N="$name" yq -n 'load("'"$INVENTORY_FILE"'") | .apps[] | select(.name == strenv(N)) | .overrides // {}' > "$ovr"
      yq -n 'load("'"$tmpl"'") * load("'"$ovr"'")' > "$merged"

  # Array fields the overrides set: append template's + override's, dedupe
  # (wholesale replacement would clobber the catalog's paths — the exact
  # drift this feature exists to prevent). Note this makes `config_paths: []`
  # in an override a no-op (the template's paths are kept) — a reference
  # cannot CLEAR a template path; use a full record for that. The paths below
  # are fixed literals, never derived from inventory data. The whole
  # expression is built as a shell variable with escaped double quotes
  # (single quotes would terminate the shell argument), then passed to yq -n.
      local expr="load(\"$merged\")"
      local spec key path set
      # Path values carry no leading dot: the expression prefixes .$path.
      for spec in \
        "config_paths:config_paths" "exclude:exclude" "extensions:extensions" \
        "depends_apt:depends_apt" "packages:installer.packages" \
        "components:installer.components"; do
        key="${spec%%:*}"; path="${spec#*:}"
        if [ "$key" = "packages" ] || [ "$key" = "components" ]; then
          set="$(yq -r '.installer | has("'"$key"'")' "$ovr")"
        else
          set="$(yq -r 'has("'"$key"'")' "$ovr")"
        fi
        [ "$set" = "true" ] || continue
        # The | unique must be parenthesized INSIDE the assignment — a trailing
        # '| unique' would pipe the whole document through unique and fail.
        expr="$expr | .$path = (((load(\"$tmpl\").$path // []) + (load(\"$ovr\").$path // [])) | unique)"
      done
      N="$name" yq -n "$expr | .name = strenv(N)" > "$frag"
    fi
    yq -i '.apps += load("'"$frag"'")' "$eff"
  done < <(yq -r '.apps[] | .name' "$INVENTORY_FILE")

  INVENTORY_READ="$eff"
  EFFECTIVE_INVENTORY="$eff"
  info "Resolved $n_refs catalog reference(s) — reading effective inventory from $eff"
  return 0
}

validate_inventory() {
  require_yq 0
  local errors=0

  # 0) RESOLVE catalog references (schema v5) — builds the effective inventory
  #    (catalog templates merged with each entry's overrides) and points
  #    INVENTORY_READ at it, so every getter and semantic check below sees the
  #    resolved data. Dies on an unknown catalog key.
  resolve_effective_inventory

  # 1) STRUCTURAL — versioned JSON Schema via a real validator, on the RAW
  #    inventory (catalog references are legal schema v5).
  if ! validate_schema_structure "$INVENTORY_FILE"; then
    err "  Inventory failed schema validation (inventory/schema.yaml) — fix inventory.yaml first."
    errors=$((errors + 1))
  fi

  # 1b) STRUCTURAL — the EFFECTIVE (resolved) inventory, when catalog refs
  #     exist: the merged records must also satisfy the full installer schema
  #     (e.g. an override that adds url to an apt installer is rejected here).
  if [ -n "$EFFECTIVE_INVENTORY" ] && ! validate_schema_structure "$EFFECTIVE_INVENTORY"; then
    err "  Resolved (catalog-expanded) inventory failed schema validation — check the overrides for the referenced apps."
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

  # 4b) Unique cron job names. Null-safe (.cron_jobs[]?) — cron_jobs is
  #     OPTIONAL (v3-v5 inventories may omit it).
  dupes="$(yaml_list '.cron_jobs[]? | .name' | sort | uniq -d)"
  if [ -n "$dupes" ]; then
    warn "  duplicate cron job names: $dupes"
    errors=$((errors + 1))
  fi

  # 4c) At most ONE source: user cron job — the running user has a single
  #     crontab; more than one entry would capture the same crontab N times.
  local n_user_cron
  n_user_cron="$(yq -r '[.cron_jobs[]? | select(.source == "user")] | length' "$INVENTORY_READ")"
  if [ "${n_user_cron:-0}" -gt 1 ]; then
    warn "  cron_jobs: more than one entry with source: user — the running user has a single crontab; keep at most one."
    errors=$((errors + 1))
  fi

  # 4d) Timer pairing hint (warn-only, never fails validation).
  check_timer_pairing

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
    apt_pkgs="$(yq -r '[.apps[] | select(.installer.type == "apt") | .installer.package // ""] + [.apps[] | select(.installer.type == "apt_repository") | .installer.packages[]?] | .[] | select(. != "")' "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")"
    if ! grep -Fqx "$shell_bin" <<< "$app_names" \
       && ! grep -Fqx "$shell_bin" <<< "$pkg_names" \
       && ! grep -Fqx "$shell_bin" <<< "$apt_pkgs"; then
      warn "  default_shell '$shell_path': no declared app, apt package, apt app package override, or apt_repository package provides '$shell_bin'"
      errors=$((errors + 1))
    fi
  fi

  # 6) user_dirs semantics: under $HOME, never $HOME itself (form + traversal
  #    are already enforced by the schema). Validate each entry's path.
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
  done < <(user_dir_paths)

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

  # Backup-completeness status, derived from the artifact list + mirror state:
  #   * any 'failed' artifact (a REQUIRED item missing)    -> failed
  #   * any missing/incomplete/missing-unit (non-required) -> degraded
  #   * otherwise, mirror not 'ok' (disabled/failed)       -> ok_with_warnings
  #   * otherwise                                          -> ok
  # Restore allows 'ok' and 'ok_with_warnings'; 'degraded' and 'failed' need
  # --force-incomplete. An app with no config paths is 'empty' — informational,
  # not a failure. Exact warning/failure counts are recorded in the manifest.
  local n_failed n_missing n_incomplete n_missing_unit n_captured n_empty
  n_failed="$(manifest_count_status failed "$artifact_file")"
  n_missing="$(manifest_count_status missing "$artifact_file")"
  n_incomplete="$(manifest_count_status incomplete "$artifact_file")"
  n_missing_unit="$(manifest_count_status missing-unit "$artifact_file")"
  n_captured="$(manifest_count_status captured "$artifact_file")"
  n_empty="$(manifest_count_status empty "$artifact_file")"
  if [ "$n_failed" -gt 0 ]; then
    overall="failed"
  elif [ "$(( n_missing + n_incomplete + n_missing_unit ))" -gt 0 ]; then
    overall="degraded"
  elif [ "$mir_stat" != "ok" ]; then
    overall="ok_with_warnings"
  fi
  local n_warnings=$(( n_missing + n_incomplete + n_missing_unit ))
  [ "$mir_stat" != "ok" ] && n_warnings=$(( n_warnings + 1 ))

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
    echo "artifact_counts: captured=$n_captured empty=$n_empty missing=$n_missing incomplete=$n_incomplete missing-unit=$n_missing_unit failed=$n_failed"
    echo "warnings: $n_warnings"
    echo "failures: $n_failed"
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

# Verify a manifest for restore readiness (backup-completeness semantics).
# Returns 0 for 'ok' and 'ok_with_warnings' (restorable).
# Returns 1 for 'failed' (a REQUIRED item is missing), 'degraded' (missing
# non-required items), 'in_progress' (interrupted) or any invalid status —
# restore.sh lets --force-incomplete override the two refusal cases.
manifest_verify_restorable() {
  local mf="$1"
  [ -f "$mf" ] || { err "No backup manifest found at $mf."; return 1; }

  local st=""
  st="$(grep -m1 '^status: ' "$mf" 2>/dev/null | cut -d' ' -f2- || true)"
  case "$st" in
    ok)
      : ;;
    ok_with_warnings)
      warn "Backup manifest reports 'ok_with_warnings' — the backup is complete but the run had warnings (e.g. the mirror was disabled or failed). Restoring anyway." ;;
    failed)
      err "Backup manifest reports 'failed' — a REQUIRED item is missing from this backup. Refusing to restore (use --force-incomplete only if you understand why)."
      return 1 ;;
    degraded)
      err "Backup manifest reports 'degraded' — some items are missing or incomplete. Refusing to restore without --force-incomplete."
      return 1 ;;
    in_progress)
      err "The last backup run was interrupted (still 'in_progress'). Do not restore from this snapshot."
      return 1 ;;
    *)
      err "Backup manifest does not report a valid status — the backup is incomplete or failed."
      return 1 ;;
  esac

  # Check that at least some artifacts were captured.
  if ! grep -q '^---$' "$mf"; then
    err "Backup manifest has no artifact list — cannot verify completeness."
    return 1
  fi

  ok "Backup manifest verified: status=$st"
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
#     manifest verification (restorable: 'status: ok' or 'ok_with_warnings');
#     only then is it dropped.
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
  # Outcome for backup.sh's final summary: 'published' (new generation live),
  # 'rolled_back' (new generation non-restorable, previous kept live) or
  # 'kept_unverified' (non-restorable and no previous generation to fall back
  # to). Read AFTER publish_backup returns.
  PUBLISH_RESULT=""
  _cleanup_publish() {
    local rc="$1"
    # Clear traps first: a signal handler that exits would otherwise re-fire
    # the EXIT trap and run this cleanup twice.
    trap - EXIT INT TERM
    # Not yet published + a previous generation exists => the new generation
    # was never verified (live absent, or present but not restorable because
    # a signal landed between the swap and verification). Restore the
    # last-known-good so it stays live.
    if [ "$_PUBLISHED" != "1" ] && [ -d "$_old_gen" ]; then
      if [ ! -d "$BACKUPS_DIR" ] || ! grep -Eq '^status: (ok|ok_with_warnings)$' "$BACKUP_MANIFEST" 2>/dev/null; then
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
  # new one is restorable ('status: ok' or 'ok_with_warnings' — the latter is
  # a complete backup with only warnings, e.g. the mirror did not run or
  # failed; restore accepts both). The outcome is recorded in PUBLISH_RESULT
  # so backup.sh's final summary reflects what ACTUALLY happened (a rollback
  # must never be reported as a fresh success). Cases:
  #   * manifest present + restorable      -> published (keep new, drop old)
  #   * manifest present + degraded/failed -> rolled_back if an old generation
  #     exists; otherwise kept_unverified (the only snapshot; restore.sh can
  #     use it with --force-incomplete), with a loud warning.
  #   * manifest absent (or unreadable)    -> rolled_back if an old generation
  #     exists; otherwise remove the broken live dir and fail hard.
  if grep -Eq '^status: (ok|ok_with_warnings)$' "$BACKUP_MANIFEST" 2>/dev/null; then
    _PUBLISHED=1
    PUBLISH_RESULT="published"
  elif [ -r "$BACKUP_MANIFEST" ]; then
    warn "The new generation's manifest does not report a restorable status ('ok'/'ok_with_warnings') — restore would need --force-incomplete."
    if [ -d "$_old_gen" ]; then
      rm -rf "$BACKUPS_DIR" || die "Could not remove the unverified generation at $BACKUPS_DIR — previous backup preserved at $_old_gen."
      if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
        warn "Rolled back to the previous (verified) backup generation."
        PUBLISH_RESULT="rolled_back"
      else
        die "Could not roll back — the previous generation is preserved at $_old_gen."
      fi
    else
      warn "No previous generation to roll back to — keeping the new generation as-is (review backup-info.txt)."
      _PUBLISHED=1
      PUBLISH_RESULT="kept_unverified"
    fi
  else
    if [ -d "$_old_gen" ]; then
      rm -rf "$BACKUPS_DIR" || die "Could not remove the unverified generation at $BACKUPS_DIR — previous backup preserved at $_old_gen."
      if mv "$_old_gen" "$BACKUPS_DIR" 2>/dev/null; then
        warn "The new generation has no manifest — rolled back to the previous (verified) backup generation."
        PUBLISH_RESULT="rolled_back"
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

# --- Restore conflict policies -------------------------------------------
# Per-owner conflict policy (apps[]/services[]), default "merge" (additive
# overlay, never deletes — the historical restore behavior).
# conflict_policy_get KIND NAME -> the owner's policy ("merge" if absent).
# KIND is 'app' (NAME = app name) or 'service' (NAME = unit file).
conflict_policy_get() {
  require_yq "$YQ_AUTO"
  local kind="$1" owner="$2" val=""
  case "$kind" in
    app)     val="$(N="$owner" yq -r ".apps[] | select(.name == strenv(N)) | .conflict_policy // \"merge\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")" ;;
    service) val="$(U="$owner" yq -r ".services[] | select(.unit == strenv(U)) | .conflict_policy // \"merge\"" "${EFFECTIVE_INVENTORY:-$INVENTORY_FILE}")" ;;
  esac
  # Unknown owners (an app/service the inventory no longer declares, or a
  # non-app/non-service kind) default to the historical safe behavior.
  [ -n "$val" ] || val="merge"
  printf '%s\n' "$val"
}

# --- Rollback bundle + restore journal ------------------------------------
# Every config restore captures what it is about to overwrite into a
# timestamped ROLLBACK_DIR under the user's XDG state dir (OUTSIDE the backup
# source — the repo checkout and the backup medium stay pristine), and appends
# one line per operation to $ROLLBACK_DIR/restore-journal.log
# (actions: created | replaced | skipped | failed). The bundle is created
# lazily on first capture, never under --dry-run, never when nothing is
# restored. Dry-run prints the operations instead of executing them.
ROLLBACK_DIR=""

# --- Restore phase framework (resumability) ------------------------------
# restore.sh runs in six canonical phases, each gated by phase_enabled. The
# resumability flags map onto them: --from-phase (start later), --only/--skip
# (accept phase names AND app names — app names filter the apps phase via
# app_selected, matching the handoff's `--only code,docker` example).
# 'user-data' is accepted as an alias for the 'dotfiles' phase (that phase
# covers dotfiles AND user dirs). Pure functions — unit-tested in
# tests/test_phases.sh.
PHASE_ORDER=(base packages apps services dotfiles postinstall)

# Resumability flag state (set by restore.sh; defaults keep the helpers pure
# so tests can source common.sh and call them directly).
PHASES_FROM=""
PHASES_ONLY=()
PHASES_SKIP=()
APPS_ONLY=()
APPS_SKIP=()
PLAN=0

# phase_canonical NAME -> canonical phase name (resolves the 'user-data'
# alias); empty if NAME is not a phase name.
phase_canonical() {
  case "$1" in
    base|packages|apps|services|dotfiles|postinstall) printf '%s\n' "$1" ;;
    user-data) printf 'dotfiles\n' ;;
  esac
}

# check_phase_conflicts — warn when the resumability flags (--only/--from-phase)
# contradict the legacy modes (--configs-only/--packages-only) and would
# silently skip phases the user explicitly asked for. Pure-ish (reads the same
# globals as phase_enabled) — unit-tested in tests/test_phases.sh.
check_phase_conflicts() {
  local p n=0 skipped="" from="${PHASES_FROM:-}" seeing=0 any=0 p2 all_suppressed=0
  if [ "${#PHASES_ONLY[@]}" -gt 0 ]; then
    for p in "${PHASES_ONLY[@]}"; do
      if ! phase_enabled "$p"; then
        n=$((n + 1))
        [ -n "$skipped" ] && skipped="$skipped, "
        skipped="$skipped$p"
      fi
    done
    if [ "$n" -gt 0 ] && [ "$n" = "${#PHASES_ONLY[@]}" ]; then
      warn "--only phase(s) ($skipped) are all suppressed by phase gating (--configs-only/--packages-only/--from-phase/--skip) — nothing will run in this phase set."
      all_suppressed=1
    elif [ "$n" -gt 0 ]; then
      warn "--only phase(s) suppressed by phase gating: $skipped."
    fi
  fi
  # The --from-phase resume point itself does NOT need to run — it only marks
  # where to start. What matters is whether ANY canonical phase at or after it
  # can still run (e.g. --from-phase services --only dotfiles is fine: dotfiles
  # comes after services and runs). Warn only when the whole at-or-after set is
  # suppressed and the run would do nothing — and skip it when the --only
  # warning above already said nothing will run (avoids a redundant second
  # warning for the same outcome).
  if [ -n "$from" ] && [ "$all_suppressed" = "0" ]; then
    for p2 in "${PHASE_ORDER[@]}"; do
      [ "$p2" = "$from" ] && seeing=1
      if [ "$seeing" = "1" ] && phase_enabled "$p2"; then
        any=1
        break
      fi
    done
    if [ "$any" = "0" ]; then
      warn "--from-phase $from: no phase at or after it is enabled (suppressed by phase gating) — the run may do nothing."
    fi
  fi
}

# phase_enabled NAME -> 0 if the phase should run, 1 if it must be skipped.
# Combines the legacy modes (--configs-only / --packages-only) with the
# resumability flags (--from-phase / --only / --skip). App names given to
# --only/--skip never gate whole phases — they filter the apps phase via
# app_selected.
phase_enabled() {
  local name="$1"
  case "$name" in
    base|packages) [ "${CONFIGS_ONLY:-0}" = "1" ] && return 1 ;;
    dotfiles)      [ "${PACKAGES_ONLY:-0}" = "1" ] && return 1 ;;
    postinstall)   { [ "${CONFIGS_ONLY:-0}" = "1" ] || [ "${PACKAGES_ONLY:-0}" = "1" ]; } && return 1 ;;
  esac
  # --from-phase NAME: skip every phase before NAME.
  if [ -n "${PHASES_FROM:-}" ]; then
    local before=1 n
    for n in "${PHASE_ORDER[@]}"; do
      [ "$n" = "$PHASES_FROM" ] && before=0
      [ "$n" = "$name" ] && break
    done
    [ "$before" = "1" ] && return 1
  fi
  # --only: phases not listed are skipped. (The arrays are always declared
  # empty in common.sh, so plain "${#arr[@]}"/"${arr[@]}" are safe under
  # set -u — note "${#arr[@]:-0}" is NOT valid bash.)
  if [ "${#PHASES_ONLY[@]}" -gt 0 ]; then
    local o found=0
    for o in "${PHASES_ONLY[@]}"; do
      [ "$o" = "$name" ] && { found=1; break; }
    done
    [ "$found" = "0" ] && return 1
  fi
  # --skip: listed phases are skipped.
  local s
  for s in "${PHASES_SKIP[@]}"; do
    [ "$s" = "$name" ] && return 1
  done
  return 0
}

# apply_selection KIND APP_NAMES TOKENS... — classify --only/--skip tokens
# into the PHASES_*/APPS_* arrays (phase names gate phases, app names filter
# the apps phase). APP_NAMES is the newline-separated list of declared app
# names. Unknown tokens die (typo guard). Pure-ish — unit-tested in
# tests/test_phases.sh.
apply_selection() {
  local kind="$1" app_names="$2"
  local t c
  shift 2
  for t in "$@"; do
    [ -n "$t" ] || continue
    c="$(phase_canonical "$t")"
    if [ -n "$c" ]; then
      if [ "$kind" = "only" ]; then PHASES_ONLY+=("$c"); else PHASES_SKIP+=("$c"); fi
    elif grep -Fxq "$t" <<< "$app_names"; then
      if [ "$kind" = "only" ]; then APPS_ONLY+=("$t"); else APPS_SKIP+=("$t"); fi
    else
      die "--$kind: '$t' is neither a phase (${PHASE_ORDER[*]}, alias user-data) nor a declared app."
    fi
  done
}

# app_selected NAME -> 0 if the app should run in the apps phase. App names
# from --only (only these) / --skip (all but these) filter the apps phase.
app_selected() {
  local name="$1" a
  if [ "${#APPS_ONLY[@]}" -gt 0 ]; then
    for a in "${APPS_ONLY[@]}"; do
      [ "$a" = "$name" ] && return 0
    done
    return 1
  fi
  for a in "${APPS_SKIP[@]}"; do
    [ "$a" = "$name" ] && return 1
  done
  return 0
}

# rollback_init: create the bundle dir + journal header (dry-run aware).
# restore.sh calls it eagerly at restore start (non-dry-run) so every phase
# records phase-start/phase-done markers — the durable phase journal.
rollback_init() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] rollback bundle + journal would be created at %s\n' "$HOME/.local/state/backup-restore-ubuntu/rollback-<timestamp>"
    return 0
  fi
  [ -n "$ROLLBACK_DIR" ] && return 0
  ROLLBACK_DIR="$HOME/.local/state/backup-restore-ubuntu/rollback-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$ROLLBACK_DIR"
  {
    echo "# restore journal — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# source: ${BACKUP_MANIFEST:-unknown}"
    echo "# rollback bundle: $ROLLBACK_DIR"
    echo "# actions: created | replaced | skipped | failed"
  } > "$ROLLBACK_DIR/restore-journal.log"
  info "Rollback bundle + journal: $ROLLBACK_DIR"
}

# journal_log ACTION PATH — append one journal line (dry-run aware).
journal_log() {
  local action="$1" path="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf '[dry-run] journal: %s %s\n' "$action" "$path"
    return 0
  fi
  [ -n "$ROLLBACK_DIR" ] || return 0
  printf '%s %s %s\n' "$(date -u +%H:%M:%S)" "$action" "$path" >> "$ROLLBACK_DIR/restore-journal.log"
}

# rollback_capture SRC DEST RBREL [sudo...]
# Capture what restore is about to overwrite into $ROLLBACK_DIR/RBREL.
#   * SRC is a FILE (unit files, dotfiles): capture DEST itself if it exists.
#   * SRC is a DIR (config trees): for every file/symlink under SRC, capture
#     DEST/<rel> if it exists (rsync -R from DEST, so structure is preserved).
# Optional trailing args are a sudo prefix for root-owned destinations.
# Returns 1 if anything existing was captured (i.e. files would be
# overwritten), 0 otherwise. Dry-run aware.
rollback_capture() {
  local src="$1" dest="$2" rb="$3"; shift 3
  local -a sudo_prefix=("$@")

  # Single-file capture.
  if [ -f "$src" ]; then
    [ -e "$dest" ] || return 0
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] rollback: cp -a %s -> %s\n' "$dest" "$HOME/.local/state/backup-restore-ubuntu/rollback-<timestamp>/$rb"
      return 1
    fi
    rollback_init
    mkdir -p "$ROLLBACK_DIR/$(dirname "$rb")"
    if [ "${#sudo_prefix[@]}" -gt 0 ]; then
      "${sudo_prefix[@]}" cp -a "$dest" "$ROLLBACK_DIR/$rb" 2>/dev/null || warn "  rollback: could not capture $dest"
    else
      cp -a "$dest" "$ROLLBACK_DIR/$rb" 2>/dev/null || warn "  rollback: could not capture $dest"
    fi
    return 1
  fi

  # Tree capture.
  [ -d "$src" ] || return 0
  local found=0 rel
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    [ -e "$dest/$rel" ] || continue
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] rollback: %s ./%s -> %s\n' "${sudo_prefix[*]:-}" "$rel" "$HOME/.local/state/backup-restore-ubuntu/rollback-<timestamp>/$rb"
      found=1
      continue
    fi
    rollback_init
    # rsync -aR does not create the nested destination dirs itself — ensure
    # the bundle path exists before capturing.
    mkdir -p "$ROLLBACK_DIR/$rb"
    if [ "${#sudo_prefix[@]}" -gt 0 ]; then
      ( cd "$dest" && "${sudo_prefix[@]}" rsync -aR "./$rel" "$ROLLBACK_DIR/$rb/" ) 2>/dev/null || warn "  rollback: could not capture $dest/$rel"
    else
      ( cd "$dest" && rsync -aR "./$rel" "$ROLLBACK_DIR/$rb/" ) 2>/dev/null || warn "  rollback: could not capture $dest/$rel"
    fi
    found=1
  done < <(cd "$src" && find . \( -type f -o -type l \) | sed 's|^\./||')
  [ "$found" = "1" ] && return 1
  return 0
}

# --- Backup content integrity (SHA256SUMS) --------------------------------
# backup_generate_checksums DIR — write a deterministic SHA256SUMS over every
# regular file under DIR except the checksum file itself, the manifest
# (backup-info.txt) and mutable logs (*.log). Run from the staged tree so the
# file ships in backups/ and every mirror snapshot. Deterministic: sorted
# input -> stable sha256sum output.
backup_generate_checksums() {
  local dir="$1"
  [ -d "$dir" ] || { err "backup_generate_checksums: not a directory: $dir"; return 1; }
  require_cmd sha256sum
  if ! ( cd "$dir" \
        && find . -type f ! -name 'SHA256SUMS' ! -name 'backup-info.txt' ! -name '*.log' -print0 \
           | sort -z \
           | xargs -0 -r sha256sum > SHA256SUMS ); then
    err "Failed to generate SHA256SUMS in $dir"
    return 1
  fi
  [ -s "$dir/SHA256SUMS" ] || { rm -f "$dir/SHA256SUMS"; err "No regular files to checksum in $dir"; return 1; }
  return 0
}

# backup_verify_integrity DIR — read-only verification of a backup tree before
# restore. Returns 0 only when:
#   * no hostile special files (block/char devices, FIFOs, sockets)
#   * no symlinks escaping the snapshot root
#   * every SHA256SUMS entry matches (missing/corrupt files fail)
# Warns (does not fail) on files present but not listed in SHA256SUMS
# (e.g. a mutable log appended by the scheduler after the backup ran).
backup_verify_integrity() {
  local dir="$1"
  [ -d "$dir" ] || { err "backup_verify_integrity: not a directory: $dir"; return 1; }
  [ -f "$dir/SHA256SUMS" ] || { err "backup_verify_integrity: no SHA256SUMS in $dir"; return 1; }
  require_cmd sha256sum
  local bad=0

  # 1) Hostile special files (device nodes, FIFOs, sockets).
  local special
  special="$(find "$dir" \( -type b -o -type c -o -type p -o -type s \) -print 2>/dev/null | head -n20 || true)"
  if [ -n "$special" ]; then
    err "Backup contains special files (device/FIFO/socket) — refusing:"
    printf '%s\n' "$special" | sed "s|^$dir/|  |" | head -n20 >&2
    bad=1
  fi

  # 2) Symlinks escaping the snapshot root (realpath-aware, broken links safe).
  local link realt
  while IFS= read -r link; do
    [ -n "$link" ] || continue
    realt="$(realpath -m -- "$link" 2>/dev/null || printf '%s' "$link")"
    case "$realt" in
      "$dir"|"$dir"/*) : ;;
      *) err "Backup symlink escapes the snapshot: $link -> $realt"; bad=1 ;;
    esac
  done < <(find "$dir" -type l -print 2>/dev/null)

  # 3) Checksum verification — catches missing and corrupt files.
  local out rc=0
  out="$( cd "$dir" && sha256sum -c SHA256SUMS 2>&1 )" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | grep -iE 'failed|no such file|warning' | head -n20 | sed 's/^/  /' >&2 || true
    err "Backup content checksum verification FAILED ($dir/SHA256SUMS)"
    bad=1
  fi

  # 4) Extra files: on disk but not listed in SHA256SUMS (warn only).
  local tmpf tmps extra
  tmpf="$(mktemp)"; tmps="$(mktemp)"
  ( cd "$dir" && find . -type f ! -name 'SHA256SUMS' ! -name 'backup-info.txt' ! -name '*.log' -printf '%P\n' | sort ) > "$tmpf" 2>/dev/null || true
  ( cd "$dir" && sed -n 's|^[0-9a-f]\{64\}  \./||p' SHA256SUMS | sort ) > "$tmps" 2>/dev/null || true
  extra="$(comm -23 "$tmpf" "$tmps" | head -n20 || true)"
  if [ -n "$extra" ]; then
    warn "Files present in the backup but not in SHA256SUMS (post-backup additions?):"
    printf '%s\n' "$extra" | sed 's/^/  /'
  fi
  rm -f "$tmpf" "$tmps"

  return "$(( bad > 0 ? 1 : 0 ))"
}
