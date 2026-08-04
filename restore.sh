#!/bin/bash
# ---------------------------------------------------------------------------
# restore.sh — REBUILD the system from the inventory.
#
# Philosophy (see AGENTS.md): install everything FRESH from recommended sources
# at the latest stable version; copy back ONLY configuration from backups/
# (or an external snapshot given with --source). Never installs from backup
# files, never replays dpkg state, never pins versions.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$LIB_DIR/installers.sh"

DRY_RUN=0
ASSUME_YES=0
DO_UPGRADE=0
CONFIGS_ONLY=0
PACKAGES_ONLY=0
FORCE_INCOMPLETE=0
RESTORE_SOURCE=""
BACKUP_LABEL="backups/"   # user-facing name of the config source (set to the snapshot under --source)
PLAN=0                    # --plan: dry-run preview + phase plan summary
PHASES_FROM=""           # --from-phase NAME: skip every phase before NAME
# Raw --only/--skip tokens; classified into phase vs app names after yq is
# available (see the "Resolve --only/--skip selections" block below).
declare -a RAW_ONLY=() RAW_SKIP=()

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)      DRY_RUN=1 ;;
    --yes|-y)       ASSUME_YES=1 ;;
    --plan)         PLAN=1; DRY_RUN=1 ;;
    --non-interactive) ASSUME_YES=1 ;;  # never prompt (implies --yes)
    --from-phase)
      shift
      PHASES_FROM="${1:-}"
      _c="$(phase_canonical "$PHASES_FROM")"
      [ -n "$_c" ] || die "--from-phase requires a phase name: ${PHASE_ORDER[*]} (alias: user-data)."
      PHASES_FROM="$_c"
      ;;
    --only)
      shift
      [ -n "${1:-}" ] || die "--only requires a comma-separated list of phases and/or apps."
      IFS=',' read -ra _tokens <<< "$1"
      RAW_ONLY+=("${_tokens[@]}")
      ;;
    --skip)
      shift
      [ -n "${1:-}" ] || die "--skip requires a comma-separated list of phases and/or apps."
      IFS=',' read -ra _tokens <<< "$1"
      RAW_SKIP+=("${_tokens[@]}")
      ;;
    --upgrade-base) DO_UPGRADE=1 ;;
    --configs-only) CONFIGS_ONLY=1 ;;
    --packages-only) PACKAGES_ONLY=1 ;;
    --force-incomplete) FORCE_INCOMPLETE=1 ;;
    --source)       shift; RESTORE_SOURCE="${1:-}"; [ -n "$RESTORE_SOURCE" ] || die "--source requires a snapshot directory argument." ;;
    *) die "Unknown option: $1 (usage: $0 [--source <snapshot-dir>] [--plan] [--from-phase <phase>] [--only|--skip <phases,apps>] [--dry-run] [--yes|--non-interactive] [--upgrade-base] [--configs-only|--packages-only] [--force-incomplete])" ;;
  esac
  shift
done

[ "$CONFIGS_ONLY" = "1" ] && [ "$PACKAGES_ONLY" = "1" ] && die "--configs-only and --packages-only are mutually exclusive."

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq 1
SCHEMA_AUTO=1   # schema validator: auto-install python3-jsonschema on a fresh system

# Note: require_schema_validator (called via validate_inventory below) may also
# auto-install python3-jsonschema python3-yaml on a fresh system — the same
# policy as yq: validation must run even under --dry-run.

# --- Preflight: OS and user ----------------------------------------------
require_ubuntu
require_non_root
require_cmd sudo

# Validate inventory before touching anything.
validate_inventory || die "Inventory validation failed — fix inventory.yaml and re-run."

# --- Resolve --only/--skip selections -------------------------------------
# Phase names gate whole phases (phase_enabled); app names filter the apps
# phase (app_selected). Unknown names die — a typo must never silently restore
# the wrong set. Classification lives in lib/common.sh (apply_selection) so
# the typo guard is unit-tested.
PHASES_ONLY=(); APPS_ONLY=(); PHASES_SKIP=(); APPS_SKIP=()
_app_names="$(yaml_list '.apps[] | .name')"
apply_selection only "$_app_names" "${RAW_ONLY[@]}"
apply_selection skip "$_app_names" "${RAW_SKIP[@]}"
# Warn when app filters are set but the apps phase itself is disabled by
# phase gating (e.g. --skip apps --only code,git would silently process no
# apps).
if [ "${#APPS_ONLY[@]}" -gt 0 ] || [ "${#APPS_SKIP[@]}" -gt 0 ]; then
  if ! phase_enabled apps; then
    warn "--only/--skip app names given, but the apps phase is disabled by phase gating — no apps will be processed."
  fi
fi
# Warn when the resumability flags contradict the legacy modes (e.g.
# --packages-only --only dotfiles would silently skip the only phase the user
# asked for).
check_phase_conflicts

# --- Optional external backup source (--source) ---------------------------
# With --source, restore reads configuration DIRECTLY from the given backup
# snapshot (e.g. a backup-* mirror snapshot on an external drive) instead of
# the repo-local backups/. The repo checkout is disposable and the backup
# medium is authoritative — nothing is copied or mounted implicitly.
if [ -n "$RESTORE_SOURCE" ]; then
  RESTORE_SOURCE="$(realpath -m -- "$RESTORE_SOURCE" 2>/dev/null || printf '%s' "$RESTORE_SOURCE")"
  if [ ! -d "$RESTORE_SOURCE" ]; then
    die "Backup source not found: $RESTORE_SOURCE (--source expects a snapshot directory containing backup-info.txt, e.g. /media/$USER/Storage/backup-restore-ubuntu/backup-20260802-120000)"
  fi
  if [ ! -f "$RESTORE_SOURCE/backup-info.txt" ]; then
    _newest_snap="$(ls -1dr "$RESTORE_SOURCE"/backup-* 2>/dev/null | head -n1 || true)"
    if [ -n "$_newest_snap" ]; then
      die "No backup-info.txt in $RESTORE_SOURCE — that looks like a mirror root holding snapshots. Pass a single snapshot, e.g.: $_newest_snap"
    fi
    die "No backup-info.txt in $RESTORE_SOURCE — not a backup snapshot (run ./backup.sh first, or point --source at a mirror snapshot)."
  fi
  BACKUPS_DIR="$RESTORE_SOURCE"
  BACKUP_MANIFEST="$RESTORE_SOURCE/backup-info.txt"
  BACKUP_LABEL="$RESTORE_SOURCE"
  BACKUPS_PRESENT=1
  BACKUPS_VERIFIED=0
  if manifest_verify_restorable "$BACKUP_MANIFEST"; then
    BACKUPS_VERIFIED=1
  elif [ "$FORCE_INCOMPLETE" = "1" ]; then
    warn "Backup manifest is incomplete but --force-incomplete was specified — proceeding anyway."
    BACKUPS_VERIFIED=1
  else
    die "Cannot restore from $RESTORE_SOURCE: backup manifest is not verified (missing or no restorable status: 'ok'/'ok_with_warnings'). Use --force-incomplete to override."
  fi

  # Preflight compatibility checks (best-effort; older manifests may lack lines).
  _src_arch="$(grep -m1 '^arch: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_arch" ] && [ "$_src_arch" != "$ARCH_NORM" ]; then
    die "Backup was created on architecture '$_src_arch' but this machine is '$ARCH_NORM' — refusing to restore incompatible configuration."
  fi
  _src_os="$(grep -m1 '^ubuntu_version: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_os" ]; then
    _cur_os=""
    [ -r /etc/os-release ] && { . /etc/os-release; _cur_os="${VERSION_ID:-}"; }
    if [ -n "$_cur_os" ] && [ "$_src_os" != "$_cur_os" ]; then
      warn "Backup was created on Ubuntu $_src_os but this machine is $_cur_os — packages reinstall at latest versions, but some app configs may not match. Proceeding."
    fi
  fi
  _src_sha="$(grep -m1 '^inventory_sha256: ' "$BACKUP_MANIFEST" | cut -d' ' -f2- || true)"
  if [ -n "$_src_sha" ]; then
    _cur_sha="$(sha256sum "$INVENTORY_FILE" | cut -d' ' -f1)"
    if [ "$_src_sha" != "$_cur_sha" ]; then
      warn "This repo's inventory.yaml differs from the one used to create this backup — items added since restore fresh, items removed are skipped."
    fi
  else
    warn "Backup manifest has no inventory_sha256 — cannot verify inventory compatibility."
  fi
  if [ -w "$RESTORE_SOURCE" ]; then
    warn "Backup source is writable. For safety, prefer restoring from a read-only medium (mounted drive, read-only snapshot)."
  fi
  info "Restoring from backup source: $RESTORE_SOURCE"
fi

# --- Determine backup status (repo-local backups/, unless --source) -------
if [ -z "$RESTORE_SOURCE" ]; then
  BACKUPS_PRESENT=0
  BACKUPS_VERIFIED=0
  if [ -f "$BACKUP_MANIFEST" ]; then
    BACKUPS_PRESENT=1
    if manifest_verify_restorable "$BACKUP_MANIFEST"; then
      BACKUPS_VERIFIED=1
    elif [ "$FORCE_INCOMPLETE" = "1" ]; then
      warn "Backup manifest is incomplete but --force-incomplete was specified — proceeding anyway."
      BACKUPS_VERIFIED=1
    fi
  elif [ -d "$BACKUPS_DIR" ] && [ -n "$(find "$BACKUPS_DIR" -mindepth 1 -print -quit 2>/dev/null)" ]; then
    warn "backups/ contains data but no valid manifest (backup-info.txt with a restorable status: ok/ok_with_warnings)."
    if [ "$FORCE_INCOMPLETE" = "1" ]; then
      BACKUPS_PRESENT=1
      BACKUPS_VERIFIED=1
    fi
  fi

  if [ "$BACKUPS_PRESENT" = "0" ]; then
    if [ "$CONFIGS_ONLY" = "1" ]; then
      warn "No backups/ found — --configs-only has nothing to restore."
    else
      warn "No backups/ found — packages will still be installed, but configuration cannot be restored."
    fi
  fi

  if [ "$BACKUPS_PRESENT" = "1" ] && [ "$BACKUPS_VERIFIED" = "0" ]; then
    if [ "$CONFIGS_ONLY" = "1" ]; then
      die "Cannot restore config: backup manifest is not valid (missing or no restorable status: 'ok'/'ok_with_warnings'). Use --force-incomplete to override."
    elif [ "$PACKAGES_ONLY" != "1" ]; then
      warn "Backup manifest is not valid — configuration will NOT be restored. Use --force-incomplete to override."
    fi
  fi
fi

# --- Content integrity (SHA256SUMS) --------------------------------------
# Read-only verification of the restore source (repo backups/ or --source
# snapshot): hostile special files, escaping symlinks, and checksum matches.
# Skipped under --packages-only (no config is restored, so content is unused).
# Legacy snapshots without SHA256SUMS are accepted with a warning. A failed
# check means the payload is corrupt or tampered — refuse unless overridden.
if [ "$BACKUPS_VERIFIED" = "1" ] && [ "$PACKAGES_ONLY" != "1" ]; then
  if [ -f "$BACKUPS_DIR/SHA256SUMS" ]; then
    if backup_verify_integrity "$BACKUPS_DIR"; then
      ok "Backup content verified (SHA256SUMS)"
    elif [ "$FORCE_INCOMPLETE" = "1" ]; then
      warn "Backup content integrity check FAILED but --force-incomplete was specified — proceeding anyway."
    else
      die "Backup content integrity check FAILED (corrupt or tampered snapshot). Use --force-incomplete to override."
    fi
  else
    warn "No SHA256SUMS in backup — skipping content integrity check (snapshot created before integrity checking)."
  fi
fi

# --- Confirm -------------------------------------------------------------
if [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ] && [ "$CONFIGS_ONLY" = "0" ] && [ "$PACKAGES_ONLY" = "0" ]; then
  confirm "This will install packages and modify the system. Continue?" "n" || die "Aborted."
elif [ "$CONFIGS_ONLY" = "1" ] && [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  confirm "This will restore configuration from $BACKUP_LABEL (no packages will be installed). Continue?" "n" || die "Aborted."
elif [ "$PACKAGES_ONLY" = "1" ] && [ "$DRY_RUN" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  confirm "This will install packages only (no configuration will be restored). Continue?" "n" || die "Aborted."
fi

# --- Durable phase journal -------------------------------------------------
# Create the rollback bundle + journal up front (non-dry-run) so every phase
# records phase-start/phase-done markers even when nothing is captured yet
# (e.g. --packages-only). Dry-run/--plan create nothing. phase-done is
# recorded even when the phase had failures — per-item failures are journaled
# and accumulated in the exit code separately.
if [ "$DRY_RUN" != "1" ]; then
  rollback_init
fi

# --- Restore plan (--plan) -------------------------------------------------
if [ "$PLAN" = "1" ]; then
  echo
  echo "Restore plan (--plan):"
  for _p in "${PHASE_ORDER[@]}"; do
    if phase_enabled "$_p"; then
      printf '  [x] %-12s will run\n' "$_p"
    else
      printf '  [ ] %-12s skipped\n' "$_p"
    fi
  done
  # Cron jobs are restored inside the services phase — show them so the plan
  # does not silently hide scheduled jobs. (No `local` here — this block is
  # top-level; plain variables, unset after.)
  _cron_plan="$(yq -r '.cron_jobs[]? | [.name, .source] | @tsv' "$INVENTORY_READ" 2>/dev/null || true)"
  if [ -n "$_cron_plan" ]; then
    echo "  cron jobs (restored in the services phase):"
    while IFS=$'\t' read -r _cn _cs; do
      [ -n "$_cn" ] || continue
      if phase_enabled services; then
        printf '    [x] %-20s source=%s\n' "$_cn" "$_cs"
      else
        printf '    [ ] %-20s source=%s (services phase skipped)\n' "$_cn" "$_cs"
      fi
    done <<< "$_cron_plan"
  fi
  unset _cron_plan _cn _cs
  if [ "${#APPS_ONLY[@]}" -gt 0 ]; then
    printf '  apps: %s only\n' "${APPS_ONLY[*]}"
  elif [ "${#APPS_SKIP[@]}" -gt 0 ]; then
    printf '  apps: all except %s\n' "${APPS_SKIP[*]}"
  fi
  # Resolved app records (catalog references expanded) — the EFFECTIVE values
  # that would actually run. $INVENTORY_READ is the effective inventory (set by
  # validate_inventory); the catalog key is read from the raw file (references
  # are stripped by the resolver). No `local` here — this block is top-level.
  printf '  resolved apps (effective values):\n'
  declare -A _plan_cat=()
  while IFS=$'\t' read -r _n _c; do
    [ -n "$_n" ] && _plan_cat["$_n"]="$_c"
  done < <(yq -r '.apps[] | select(has("catalog")) | [.name, .catalog] | @tsv' "$INVENTORY_FILE")
  while IFS=$'\t' read -r _n _itype _pkg; do
    [ -n "$_n" ] || continue
    if app_selected "$_n"; then
      printf '    [x] %-20s installer=%-16s %s%s\n' "$_n" "$_itype" "${_pkg:+pkg=$_pkg }" "${_plan_cat[$_n]:+(catalog: ${_plan_cat[$_n]})}"
    else
      printf '    [ ] %-20s (skipped by --only/--skip)\n' "$_n"
    fi
  done < <(yq -r '.apps[] | [.name, (.installer.type // "?"), (.installer.package // "")] | @tsv' "$INVENTORY_READ")
  unset _plan_cat
  echo "  (every step below is a preview — nothing is modified)"
  echo
fi

# --- Check required tools -------------------------------------------------
# rsync is needed for config restore; ensure it's available.
if [ "$PACKAGES_ONLY" != "1" ] && [ "$BACKUPS_PRESENT" = "1" ]; then
  if ! command -v rsync >/dev/null 2>&1; then
    info "rsync not found — installing it (needed for config restore)."
    run sudo apt-get update
    run sudo apt-get install -y rsync
  fi
fi

# --- Accumulated exit code ------------------------------------------------
ACUMULATED_EXIT=0

mark_failure() {
  local code="${1:-$EXIT_INSTALL_FAILED}"
  ACUMULATED_EXIT=$(( ACUMULATED_EXIT | code ))
}

# --- Phase 1: base system -------------------------------------------------
if phase_enabled base; then
  journal_log "phase-start" "base"
  info "Phase 1/6: base system"
  run sudo apt-get update || mark_failure "$EXIT_PREREQ_FAILED"
  if [ "$DO_UPGRADE" = "1" ]; then
    info "(--upgrade-base: apt full-upgrade of the whole base OS)"
    run sudo apt-get full-upgrade -y || mark_failure "$EXIT_PREREQ_FAILED"
    run sudo apt-get autoremove -y || true
  else
    info "(base OS full-upgrade skipped by default — opt in with --upgrade-base)"
  fi
  journal_log "phase-done" "base"
else
  info "Phase 1/6: base system (skipped)"
fi

# --- Phase 2: packages ----------------------------------------------------
if phase_enabled packages; then
  journal_log "phase-start" "packages"
  info "Phase 2/6: packages"

install_apt_packages() {
  local -a pkgs=() p
  while IFS= read -r p; do
    [ -n "$p" ] && pkgs+=("$p")
  done < <(yaml_list '.apt_packages[]')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    info "Installing ${#pkgs[@]} apt package(s): ${pkgs[*]}"
    run sudo apt-get install -y "${pkgs[@]}" || mark_failure
  fi
}

install_snap_packages() {
  local -a pkgs=() p entry pkg classic
  while IFS= read -r p; do
    [ -n "$p" ] && pkgs+=("$p")
  done < <(yaml_list '.snap_packages[]')
  if [ "${#pkgs[@]}" -gt 0 ]; then
    if ! command -v snap >/dev/null 2>&1; then
      warn "snap is not available on this system; skipping snap packages."
      mark_failure
      return 0
    fi
    for entry in "${pkgs[@]}"; do
      pkg="${entry%%:*}"
      classic=""
      [ "${entry##*:}" = "classic" ] && classic="--classic"
      info "Installing snap: $entry"
      # _run_snap_install (lib/installers.sh) warns when a large snap takes a
      # long time so a slow download is not mistaken for a hang.
      # shellcheck disable=SC2086  # $classic is empty or '--classic'
      _run_snap_install "$pkg" $classic || mark_failure
    done
  fi
}

install_flatpak_apps() {
  local -a apps=() a
  while IFS= read -r a; do
    [ -n "$a" ] && apps+=("$a")
  done < <(yaml_list '.flatpak_apps[]')
  if [ "${#apps[@]}" -gt 0 ]; then
    command -v flatpak >/dev/null 2>&1 || {
      info "flatpak not found — installing it."
      run sudo apt-get install -y flatpak || mark_failure
    }
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
    for a in "${apps[@]}"; do
      info "Installing flatpak app: $a"
      run flatpak install -y flathub "$a" || mark_failure
    done
  fi
}

install_apt_packages
install_snap_packages
install_flatpak_apps
  journal_log "phase-done" "packages"
else
  info "Phase 2/6: packages (skipped)"
fi

# --- Phase 3: apps --------------------------------------------------------
# (the helper functions below stay at top level — restore_config_tree is also
# used by the services phase)

# restore_config_tree OWNER POLICY SRC DEST RBREL [SUDO...]
# Apply one backed-up config tree to DEST honouring the owner's conflict
# policy: merge (default, additive overlay), replace (preserve existing into
# the rollback bundle, then remove ONLY the exact leaf counterparts the
# backup would restore and merge-restore — never rsync --delete against the
# dest root, which would wipe unrelated data), skip-existing (only missing
# files), prompt (ask per path; non-interactive runs skip). Every run first
# captures what already exists into the rollback bundle and journals
# created/replaced/skipped. SUDO... is a prefix for root-owned targets.
restore_config_tree() {
  local owner="$1" policy="$2" src="$3" dest="$4" rb="$5"; shift 5
  local -a sudo_prefix=("$@")
  [ -d "$src" ] || return 0

  # Rollback capture first: returns 1 if existing files would be overwritten.
  local had_existing=0
  if rollback_capture "$src" "$dest" "$rb" "${sudo_prefix[@]}"; then
    had_existing=0
  else
    had_existing=1
  fi

  case "$policy" in
    prompt)
      if [ "$had_existing" = "1" ]; then
        if [ "$ASSUME_YES" = "1" ] || [ "$DRY_RUN" = "1" ]; then
          warn "  $owner: conflict_policy=prompt and target files exist — skipping (non-interactive)."
          journal_log "skipped" "$rb"
          return 0
        fi
        if confirm "  $owner: existing files under '$dest' — overwrite with the backup? (conflict_policy=prompt)" "n"; then
          :
        else
          info "  $owner: skipped (prompt declined)"
          journal_log "skipped" "$rb"
          return 0
        fi
      fi
      ;;
  esac

  local -a extra=()
  case "$policy" in
    skip-existing) extra+=(--ignore-existing) ;;
  esac

  # replace: remove ONLY the exact leaf counterparts the backup would restore
  # (never siblings or parents — rsync --delete against $HOME or / would wipe
  # unrelated data). The overwritten files were already preserved in the
  # rollback bundle above.
  if [ "$policy" = "replace" ]; then
    local rel
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      [ -e "$dest/$rel" ] || continue
      if [ "${#sudo_prefix[@]}" -gt 0 ]; then
        run "${sudo_prefix[@]}" rm -rf "$dest/$rel"
      else
        run rm -rf "$dest/$rel"
      fi
    done < <(cd "$src" && find . \( -type f -o -type l \) | sed 's|^\./||')
  fi

  if [ "$policy" = "skip-existing" ] && [ "$had_existing" = "1" ]; then
    journal_log "skipped" "$rb"
  elif [ "$had_existing" = "1" ]; then
    journal_log "replaced" "$rb"
  else
    journal_log "created" "$rb"
  fi

  if [ "${#sudo_prefix[@]}" -gt 0 ]; then
    run "${sudo_prefix[@]}" rsync -a "${extra[@]}" "$src/" "$dest/"
  else
    run rsync -a "${extra[@]}" "$src/" "$dest/"
  fi
  ok "  $owner: config restored to $dest (conflict_policy=$policy)"
}

restore_app_config() {
  local name="$1"
  local dir="$BACKUPS_DIR/apps/$name"
  [ "$BACKUPS_VERIFIED" = "1" ] || return 0
  local policy
  policy="$(conflict_policy_get app "$name")"
  if [ -d "$dir/home" ]; then
    restore_config_tree "$name" "$policy" "$dir/home" "$HOME" "apps/$name/home"
  fi
  if [ -d "$dir/root" ]; then
    restore_config_tree "$name" "$policy" "$dir/root" "/" "apps/$name/root" sudo
  fi
}

# Bootstrap backends derived from inventory, before any app install.
bootstrap_backends() {
  local need_flatpak=0 need_npm=0 need_pipx=0 need_cargo=0
  local itype
  while IFS= read -r itype; do
    [ -n "$itype" ] || continue
    case "$itype" in
      flatpak) need_flatpak=1 ;;
      npm_global) need_npm=1 ;;
      pipx) need_pipx=1 ;;
      cargo) need_cargo=1 ;;
    esac
  done < <(yq -r '.apps[].installer.type | select(. != null)' "$INVENTORY_READ")

  if [ "$need_flatpak" = "1" ] && ! command -v flatpak >/dev/null 2>&1; then
    info "flatpak needed by declared apps — installing it."
    run sudo apt-get install -y flatpak || mark_failure
  fi
  local flatpak_count
  flatpak_count="$(yq -r '.flatpak_apps | length // 0' "$INVENTORY_READ" 2>/dev/null || echo 0)"
  if [ "$need_flatpak" = "1" ] || [ "${flatpak_count:-0}" -gt 0 ]; then
    run flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo 2>/dev/null || true
  fi
  if [ "$need_npm" = "1" ] && ! command -v npm >/dev/null 2>&1; then
    info "npm needed by declared apps but not installed — individual npm-global installs will fail unless nodejs+npm are declared as deps."
  fi
  if [ "$need_pipx" = "1" ] && ! command -v pipx >/dev/null 2>&1; then
    info "pipx needed by declared apps — installing it."
    run sudo apt-get install -y pipx || mark_failure
  fi
  if [ "$need_cargo" = "1" ] && ! command -v cargo >/dev/null 2>&1; then
    info "cargo needed by declared apps — installing it."
    run sudo apt-get install -y cargo || mark_failure
  fi
}

install_app() {
  local name="$1" itype check
  itype="$(app_get "$name" '.installer.type')"
  [ -n "$itype" ] || { warn "  app '$name' has no installer.type — skipping."; mark_failure; return 1; }
  check="$(app_get "$name" '.check_cmd')"

  if [ "$CONFIGS_ONLY" = "1" ]; then
    if [ "$BACKUPS_VERIFIED" = "1" ]; then
      restore_app_config "$name"
    fi
    return 0
  fi

  local -a deps=() d
  while IFS= read -r d; do
    [ -n "$d" ] && deps+=("$d")
  done < <(app_get "$name" '.depends_apt[]?')
  if [ "${#deps[@]}" -gt 0 ]; then
    info "  $name: installing dependencies: ${deps[*]}"
    run sudo apt-get install -y "${deps[@]}" || { warn "  $name: dependency install failed"; mark_failure; }
  fi

  if [ "$itype" = "script" ] && [ -z "$check" ]; then
    warn "  $name: script installer with NO check_cmd — re-runs will re-run the installer (add check_cmd in the inventory)."
  fi

  # Source-specific check: don't skip just on command -v.
  if is_app_installed_by_source "$name"; then
    ok "  $name: already installed (verified via $itype)"
  else
    # Typed installer (lib/installers.sh) — prints its own dry-run steps.
    if installer_run "$name"; then
      if [ "$DRY_RUN" = "1" ]; then
        printf '[dry-run] %s: would be installed (steps above)\n' "$name"
      elif [ -n "$check" ] && ! command -v "$check" >/dev/null 2>&1; then
        warn "  $name: installer succeeded but '$check' not found — may need a new shell or PATH update."
      else
        ok "  $name: installed."
      fi
    else
      mark_failure
    fi
  fi

  if [ "$PACKAGES_ONLY" != "1" ]; then
    restore_app_config "$name"
  fi
}

if phase_enabled apps; then
  journal_log "phase-start" "apps"
  info "Phase 3/6: apps"
  # Bootstrap backends before starting app installs.
  if [ "$CONFIGS_ONLY" != "1" ]; then
    bootstrap_backends
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if app_selected "$name"; then
      info "App: $name"
      install_app "$name"
    else
      info "App: $name (skipped — not in --only / in --skip)"
    fi
  done < <(yaml_list '.apps[] | .name')
  journal_log "phase-done" "apps"
else
  info "Phase 3/6: apps (skipped)"
fi

# --- Phase 4: services -----------------------------------------------------
restore_services() {
  local unit target enable start sdir dest policy _paired
  while IFS=$'\t' read -r unit target enable start; do
    [ -n "$unit" ] || continue
    [ "$target" = "user" ] || target="system"
    [ "$enable" = "true" ] || enable="false"
    [ "$start" = "true" ] || start="false"
    sdir="$BACKUPS_DIR/services/$unit"
    if [ "$BACKUPS_VERIFIED" = "1" ] && [ -f "$sdir/unit" ]; then
      if [ "$CONFIGS_ONLY" = "0" ]; then
        if [ "$target" = "user" ]; then
          dest="$HOME/.config/systemd/user/$unit"
          run mkdir -p "$HOME/.config/systemd/user"
          if rollback_capture "$sdir/unit" "$dest" "services/$unit/unit"; then
            journal_log "created" "services/$unit/unit"
          else
            journal_log "replaced" "services/$unit/unit"
          fi
          run cp "$sdir/unit" "$dest"
          run systemctl --user daemon-reload 2>/dev/null || warn "  $unit: could not reload user systemd (no user session?)."
        else
          dest="/etc/systemd/system/$unit"
          if rollback_capture "$sdir/unit" "$dest" "services/$unit/unit" sudo; then
            journal_log "created" "services/$unit/unit"
          else
            journal_log "replaced" "services/$unit/unit"
          fi
          run sudo cp "$sdir/unit" "$dest"
          run sudo systemctl daemon-reload
        fi
        ok "  $unit: unit installed ($target)"
      fi
      if [ "$PACKAGES_ONLY" != "1" ]; then
        policy="$(conflict_policy_get service "$unit")"
        if [ -d "$sdir/home" ]; then
          restore_config_tree "$unit" "$policy" "$sdir/home" "$HOME" "services/$unit/home"
        fi
        if [ -d "$sdir/root" ]; then
          restore_config_tree "$unit" "$policy" "$sdir/root" "/" "services/$unit/root" sudo
        fi
      fi
      # Under --packages-only, do NOT enable/start services — they need
      # their configuration to have been restored first.
      if [ "$PACKAGES_ONLY" = "1" ]; then
        if [ "$DRY_RUN" = "1" ]; then
          printf '[dry-run] %s: NOT enabling/starting (--packages-only skips config — re-run without --packages-only to activate).\n' "$unit"
        else
          warn "  $unit: NOT enabled/started (--packages-only skips config — re-run without --packages-only to activate)."
        fi
      elif [ "$CONFIGS_ONLY" = "0" ]; then
        # Start is guarded (service_can_start): a unit whose ExecStart binary
        # is missing — e.g. its app install failed earlier in this run — is
        # enabled but NOT started, otherwise systemd sits in a restart loop.
        # Timers also pass their paired .service so a timer whose payload
        # cannot start is not started either (it would restart-loop the
        # payload every time it fires). Warn-only, deliberately no
        # mark_failure: the failed app install already set EXIT_INSTALL_FAILED.
        # (Under --only/--skip an intentionally filtered-out app leaves its
        # service enabled but not started with exit 0 — start it manually
        # after installing the app.)
        _paired=""
        if [[ "$unit" == *.timer ]] && [ -f "$BACKUPS_DIR/services/${unit%.timer}.service/unit" ]; then
          _paired="$BACKUPS_DIR/services/${unit%.timer}.service/unit"
        fi
        if [ "$target" = "user" ]; then
          if [ "$enable" = "true" ]; then
            run systemctl --user enable "$unit" 2>/dev/null || warn "  $unit: could not enable (no user session?)."
          fi
          if [ "$start" = "true" ]; then
            if service_can_start "$unit" "$sdir/unit" "$_paired"; then
              run systemctl --user start "$unit" 2>/dev/null || {
                warn "  $unit: could not start (no user session?) — stopping it and clearing the failed state."
                # stop cancels a scheduled auto-restart; reset-failed then
                # clears the failure record (reset-failed alone is a no-op
                # while the unit is in auto-restart state).
                run systemctl --user stop "$unit" 2>/dev/null || true
                run systemctl --user reset-failed "$unit" 2>/dev/null || true
              }
            fi
          fi
        else
          if [ "$enable" = "true" ]; then
            run sudo systemctl enable "$unit"
          fi
          if [ "$start" = "true" ]; then
            if service_can_start "$unit" "$sdir/unit" "$_paired"; then
              run sudo systemctl start "$unit" || {
                warn "  $unit: failed to start — stopping it and clearing the failed state so systemd does not keep retrying in a restart loop."
                # stop FIRST: it cancels a scheduled auto-restart (reset-failed
                # alone is a no-op while the unit is in auto-restart state),
                # then reset-failed clears the failure record. Rehearsal
                # finding: a Restart=always unit with an unlimited StartLimit
                # would otherwise keep climbing (cloudflared hit 118).
                run sudo systemctl stop "$unit" 2>/dev/null || true
                run sudo systemctl reset-failed "$unit" 2>/dev/null || true
              }
            fi
          fi
        fi
      fi
      # Timer units: remind that the paired .service must exist for the timer
      # to fire on a fresh system (mirrors the validate_inventory pairing hint).
      # Here-string, never `yq | grep -q` (pipefail + early-exit grep SIGPIPEs
      # a slow yq — see common.sh for the same convention).
      if [[ "$unit" == *.timer ]] && ! grep -Fqx "${unit%.timer}.service" <<< "$(yq -r '.services[] | .unit' "$INVENTORY_READ")"; then
        warn "  $unit is a timer whose paired unit '${unit%.timer}.service' is not declared in the inventory — on a fresh system the timer will not fire unless that unit exists."
      fi
      ok "  service: $unit ($target)"
    else
      warn "  service '$unit': no unit file in $BACKUP_LABEL — skipping."
      if [ "$BACKUPS_VERIFIED" = "1" ]; then
        mark_failure
      fi
    fi
  done < <(yq -r '.services[] | [.unit, (.target // "system"), (.enable // false | tostring), (.start // false | tostring)] | @tsv' "$INVENTORY_READ")
}

# ensure_cron_daemon — the cron PACKAGE must exist for declared cron jobs
# (source: user needs the crontab binary; source: cron.d needs the daemon,
# activated AFTER config restore). The package is installed when missing
# (skipped under --configs-only, which never installs packages). DAEMON
# ACTIVATION is a separate step (activate_cron_daemon) run AFTER the config is
# restored — config-before-start, mirroring how services restore config before
# enable/start. Mode gating:
#   * --packages-only — config has not been restored, so cron restore is
#     skipped entirely (return 1);
#   * --configs-only  — the crontab/cron.d files are CONFIG and are still
#     restored (return 0), but the daemon is never activated by this script.
# Returns 0 when cron restore can proceed, 1 when it must be skipped.
ensure_cron_daemon() {
  local have_cron=0
  if is_apt_installed cron; then
    have_cron=1
  fi
  if [ "$have_cron" = "0" ] && [ "$CONFIGS_ONLY" != "1" ]; then
    info "cron package not installed — installing it (needed by declared cron jobs)."
    run sudo apt-get install -y cron || { mark_failure "$EXIT_PREREQ_FAILED"; return 1; }
    have_cron=1
  fi
  if [ "$have_cron" = "0" ]; then
    warn "  cron is not installed (and --configs-only skips package installs) — skipping cron job restore."
    return 1
  fi
  if [ "$PACKAGES_ONLY" = "1" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] cron daemon: NOT enabled/started (--packages-only skips config — re-run without --packages-only to activate).\n'
    else
      warn "  cron daemon: NOT enabled/started (--packages-only skips config — re-run without --packages-only to activate)."
    fi
    return 1
  fi
  return 0
}

# activate_cron_daemon — enable/start the cron daemon AFTER its config has been
# restored (config-before-start, mirroring services). Under --configs-only the
# daemon is never activated by this script: if it is already running it is left
# untouched (truthful reporting), otherwise a message explains that a full
# restore activates it.
activate_cron_daemon() {
  if [ "$CONFIGS_ONLY" = "1" ]; then
    if systemctl is-active cron >/dev/null 2>&1; then
      ok "  cron daemon: active (left untouched by --configs-only)"
    elif [ "$DRY_RUN" = "1" ]; then
      printf '[dry-run] cron daemon: NOT enabled/started (--configs-only restores config only — a full restore activates it).\n'
    else
      warn "  cron daemon: NOT enabled/started (--configs-only restores config only — a full restore activates it)."
    fi
    return 0
  fi
  if systemctl is-active cron >/dev/null 2>&1; then
    ok "  cron daemon: active"
  else
    run sudo systemctl enable cron 2>/dev/null || true
    run sudo systemctl start cron 2>/dev/null || warn "  could not start the cron daemon."
  fi
  return 0
}

# restore_cron_jobs — restore every declared cron source from the backup.
#   * source: user   — the WHOLE user crontab is replaced after capturing the
#     current one into the rollback bundle (crontabs cannot be merged safely;
#     the previous content is always recoverable from the bundle + journal).
#   * source: cron.d — the file is copied to $CRON_D_DIR/<file> with sudo after
#     rollback capture, with 0644 perms (Debian cron ignores group/other-
#     writable files in /etc/cron.d).
# Runs inside the services phase; skipped under --packages-only (config). A
# verified backup whose artifact file is missing marks a failure (exit code),
# mirroring the services path — truthful exit codes (principle 9).
restore_cron_jobs() {
  local name source file src dest
  while IFS=$'\t' read -r name source file; do
    [ -n "$name" ] || continue
    [ -n "$file" ] || file="$name"
    src="$BACKUPS_DIR/cron/$name"
    if [ "$BACKUPS_VERIFIED" != "1" ]; then
      warn "  cron job '$name': no verified backups — skipping."
      continue
    fi
    if [ ! -f "$src" ]; then
      warn "  cron job '$name': backup artifact missing from $BACKUP_LABEL/cron — skipping."
      mark_failure "$EXIT_CONFIGS_MISSING"
      continue
    fi
    case "$source" in
      user)
        dest="/var/spool/cron/crontabs/$USER"
        if rollback_capture "$src" "$dest" "cron/$name" sudo; then
          journal_log "created" "cron/$name"
        else
          journal_log "replaced" "cron/$name"
        fi
        run crontab "$src"
        ok "  cron: user crontab restored ($name)"
        ;;
      cron.d)
        dest="$CRON_D_DIR/$file"
        if rollback_capture "$src" "$dest" "cron/$name" sudo; then
          journal_log "created" "cron/$name"
        else
          journal_log "replaced" "cron/$name"
        fi
        run sudo cp "$src" "$dest"
        run sudo chmod 0644 "$dest"
        ok "  cron: $dest restored ($name)"
        ;;
    esac
  done < <(yq -r '.cron_jobs[]? | [.name, .source, (.file // "")] | @tsv' "$INVENTORY_READ")
}

if phase_enabled services; then
  journal_log "phase-start" "services"
  info "Phase 4/6: services (incl. timers & cron jobs)"
  restore_services
  if [ "$(yq -r '(.cron_jobs // []) | length' "$INVENTORY_READ" 2>/dev/null || echo 0)" -gt 0 ]; then
    if ensure_cron_daemon; then
      restore_cron_jobs
      # Config-before-start: activate the daemon only after its config is in place.
      activate_cron_daemon
    fi
  fi
  journal_log "phase-done" "services"
else
  info "Phase 4/6: services (incl. timers & cron jobs) (skipped)"
fi

# --- Phase 5: dotfiles + user dirs -------------------------------------------
if phase_enabled dotfiles; then
  journal_log "phase-start" "dotfiles"
  info "Phase 5/6: dotfiles & user dirs"

restore_dotfiles() {
  local df
  while IFS= read -r df; do
    [ -n "$df" ] || continue
    if [ "$BACKUPS_VERIFIED" = "1" ] && [ -f "$BACKUPS_DIR/dotfiles/$df" ]; then
      local dest_parent
      dest_parent="$(dirname "$HOME/$df")"
      run mkdir -p "$dest_parent"
      if rollback_capture "$BACKUPS_DIR/dotfiles/$df" "$HOME/$df" "dotfiles/$df"; then
        journal_log "created" "dotfiles/$df"
      else
        journal_log "replaced" "dotfiles/$df"
      fi
      run cp "$BACKUPS_DIR/dotfiles/$df" "$HOME/$df"
      ok "  dotfile: $df"
    else
      warn "  dotfile '$df': no backup — skipping."
    fi
  done < <(yaml_list '.dotfiles[]')
}

restore_dotfiles

restore_user_dirs() {
  local d rel src
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    if [ "$BACKUPS_VERIFIED" != "1" ]; then
      warn "  user dir '$d': no verified backups — skipping."
      continue
    fi
    src="$(expand_path "$d")"
    if [ "$src" = "$HOME" ]; then
      warn "  user dir '$d': \$HOME itself cannot be restored this way — skipping."
      continue
    fi
    if ! validate_path_contained "$d" "$HOME" 2>/dev/null; then
      warn "  user dir '$d': not under \$HOME — skipping."
      continue
    fi
    rel="${src#"$HOME"/}"
    if [ -d "$BACKUPS_DIR/user-dirs/$rel" ]; then
      # Build exclude array from the entry's object-form exclude list (schema v7).
      local -a excl=()
      local e
      while IFS= read -r e; do
        [ -n "$e" ] && excl+=(--exclude="$e")
      done < <(user_dir_exclude "$d")
      run mkdir -p "$HOME/$rel"
      if rollback_capture "$BACKUPS_DIR/user-dirs/$rel" "$HOME/$rel" "user-dirs/$rel"; then
        journal_log "created" "user-dirs/$rel"
      else
        journal_log "replaced" "user-dirs/$rel"
      fi
      run rsync -a "${excl[@]}" "$BACKUPS_DIR/user-dirs/$rel/" "$HOME/$rel/"
      ok "  user dir: $d restored"
    else
      warn "  user dir '$d': no backup in $BACKUP_LABEL/user-dirs — skipping."
    fi
  done < <(user_dir_paths)
}

  restore_user_dirs
  journal_log "phase-done" "dotfiles"
else
  info "Phase 5/6: dotfiles & user dirs (skipped)"
fi

# --- Phase 6: post-install (groups, shell, extensions, models) ------------
if phase_enabled postinstall; then
  journal_log "phase-start" "postinstall"
  info "Phase 6/6: post-install (groups, shell, extensions)"

# --- Groups ---
# Track groups actually added in THIS run so the wrap-up checklist only
# suggests a re-login for memberships that genuinely need one — a group that
# did not exist, or one the user was already in, is never listed.
_NEW_GROUPS=()
while IFS= read -r g; do
  [ -n "$g" ] || continue
  if getent group "$g" >/dev/null 2>&1; then
    if groups "$USER" 2>/dev/null | grep -qw "$g"; then
      ok "  group: $g already member"
    else
      run sudo usermod -aG "$g" "$USER"
      [ "$DRY_RUN" != "1" ] && _NEW_GROUPS+=("$g")
      ok "  group: $g — user '$USER' added (log out and back in to take effect)"
    fi
  else
    warn "  group '$g' does not exist — skipping."
  fi
done < <(yaml_list '.groups[]?')

# --- Default shell ---
_shell_target="$(yaml_get '.default_shell')"
if [ -n "$_shell_target" ]; then
  if [ -x "$_shell_target" ]; then
    if grep -q "^$USER:.*:$_shell_target\$" /etc/passwd 2>/dev/null; then
      ok "  default shell: already $_shell_target"
    else
      run sudo chsh -s "$_shell_target" "$USER"
      ok "  default shell: set to $_shell_target (takes effect on next login)"
    fi
  else
    warn "  default shell '$_shell_target' is not executable — skipping chsh."
  fi
fi

# --- App extensions (VS Code, Azure CLI, Ollama models) ---
while IFS= read -r name; do
  [ -n "$name" ] || continue
  exts=()
  while IFS= read -r e; do
    [ -n "$e" ] && exts+=("$e")
  done < <(app_get "$name" '.extensions[]?')
  [ "${#exts[@]}" -gt 0 ] || continue

  check="$(app_get "$name" '.check_cmd')"
  [ -n "$check" ] && command -v "$check" >/dev/null 2>&1 || { warn "  $name: app not installed — cannot install extensions."; continue; }

  for e in "${exts[@]}"; do
    case "$name" in
      code|vscode)
        run code --install-extension "$e" && ok "  $name: extension '$e' installed" || warn "  $name: failed to install extension '$e'"
        ;;
      az)
        run az extension add -n "$e" 2>/dev/null && ok "  $name: extension '$e' added" || warn "  $name: failed to add extension '$e'"
        ;;
      ollama)
        run ollama pull "$e" && ok "  $name: model '$e' pulled" || warn "  $name: failed to pull model '$e'"
        ;;
      *)
        warn "  $name: extensions not supported for this app type"
        ;;
    esac
  done  done < <(yaml_list '.apps[] | .name')
  journal_log "phase-done" "postinstall"
else
  info "Phase 6/6: post-install (skipped)"
fi

# --- Wrap-up ---------------------------------------------------------------
echo
if [ "$ACUMULATED_EXIT" -ne 0 ]; then
  warn "Restore completed with issues (exit code: $ACUMULATED_EXIT)."
  echo
  echo "  Review the output above for warnings and failed items."
  _fail_reasons=""
  [ "$(( ACUMULATED_EXIT & EXIT_INSTALL_FAILED ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - One or more package/app installs failed (check above)."
  [ "$(( ACUMULATED_EXIT & EXIT_CONFIGS_MISSING ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - Some configuration or artifacts were missing."
  [ "$(( ACUMULATED_EXIT & EXIT_PREREQ_FAILED ))" -ne 0 ] && _fail_reasons="$_fail_reasons  - A prerequisite setup step failed."
  [ -n "$_fail_reasons" ] && echo "$_fail_reasons"
else
  ok "Restore complete."
fi
if [ "$DRY_RUN" = "1" ]; then
  echo "(dry run — no system changes made; read-only checks (inventory, backup source) still ran)"
fi
if [ "$PACKAGES_ONLY" = "1" ] && [ "$BACKUPS_VERIFIED" = "1" ]; then
  echo
  echo "NOTE: --packages-only was used. Services were installed but NOT enabled/started."
  echo "Re-run without --packages-only to restore config and activate services."
fi
if [ -n "$ROLLBACK_DIR" ] && [ "$DRY_RUN" != "1" ]; then
  echo
  echo "Rollback bundle + restore journal:"
  echo "  $ROLLBACK_DIR"
  echo "  - journal: $ROLLBACK_DIR/restore-journal.log (created/replaced/skipped/failed)"
  echo "  - undo:    copy captured files from the bundle back to their destinations"
  echo "  - cleanup: rm -rf \"$ROLLBACK_DIR\" once you are satisfied"
fi
echo
echo "Next steps:"
echo "  1. Review the output above for warnings and failed items."
echo "  2. Reboot so services and configuration take full effect."
echo "  3. Keep everything current with ./update_all_ubuntu.sh"
echo "  4. Verify key apps and services work before relying on this machine."

# Inventory-derived post-restore checklist (real runs only, and only when the
# postinstall phase actually ran): actionable manual steps no script can do for
# you — a NEW login session for the groups added this run / the new shell, and
# a re-login for apps whose extensions/models were just installed. Groups are
# taken from $_NEW_GROUPS (only memberships actually created this run), so
# nonexistent or pre-existing groups are never listed. Gated on phase_enabled
# postinstall so --packages-only/--configs-only/--skip postinstall never print
# advice for steps that were skipped.
if [ "$DRY_RUN" != "1" ] && phase_enabled postinstall; then
  _c_shell="$(yaml_get '.default_shell')"
  _c_exts="$(yq -r '.apps[] | select((.extensions // []) | length > 0) | .name' "$INVENTORY_READ" 2>/dev/null || true)"
  if [ "${#_NEW_GROUPS[@]}" -gt 0 ] || [ -n "$_c_shell" ] || [ -n "$_c_exts" ]; then
    echo
    echo "  Post-restore checklist (from your inventory):"
    if [ "${#_NEW_GROUPS[@]}" -gt 0 ]; then
      printf '    - Log out and back in so group memberships take effect: %s\n' "${_NEW_GROUPS[*]}"
    fi
    [ -n "$_c_shell" ] && echo "    - Default shell '$_c_shell' takes effect at your next login."
    if [ -n "$_c_exts" ]; then
      printf '    - Re-login (or restart) so installed extensions/models are picked up: '
      # shellcheck disable=SC2086  # intentional word-split of the newline-separated names
      printf '%s ' $_c_exts
      printf '\n'
    fi
  fi
  unset _c_shell _c_exts _NEW_GROUPS
fi

exit "$ACUMULATED_EXIT"
