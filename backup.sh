#!/bin/bash
# ---------------------------------------------------------------------------
# backup.sh — capture the CONFIGURATION of everything declared in
# inventory/inventory.yaml into the git-ignored backups/ folder.
#
# Each run builds a COMPLETE new generation in a staging directory, validates
# it, mirrors it, and atomically swaps it in. The last-known-good backup is
# never modified in place — a failed run leaves the previous backup intact.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

YQ_AUTO=2   # interactive tool: if yq is missing, ask the user to install it
SCHEMA_AUTO=2   # schema validator: ask before installing python3-jsonschema

[ -f "$INVENTORY_FILE" ] || die "Inventory file not found: $INVENTORY_FILE"
require_yq "$YQ_AUTO"

# --- Concurrency protection ----------------------------------------------
# The lock path is test-overridable only under the explicit test override opt-in
# (BRU_ALLOW_TEST_OVERRIDES=1, exported by tests/helpers.sh) so sandboxed runs
# never contend for the real repo lock; production always uses the repo lock.
if [ "$BRU_ALLOW_TEST_OVERRIDES" = "1" ]; then
  BACKUP_LOCK="${BACKUP_LOCK:-$REPO_ROOT/.backup.lock}"
  require_contained_dir BACKUP_LOCK "$BACKUP_LOCK" "$REPO_ROOT" || die "Unsafe BACKUP_LOCK path — aborting."
  with_lock "$BACKUP_LOCK"
else
  with_lock "$REPO_ROOT/.backup.lock"
fi

# --- Validate inventory --------------------------------------------------
validate_inventory || die "Inventory validation failed — fix inventory.yaml and re-run."

# --- Setup: staging directory --------------------------------------------
BACKUP_RUN_ID="$(date -u +%Y%m%dT%H%M%S)-$$"
BACKUP_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# STAGE/ARTIFACTS are test-overridable only under the explicit test override
# opt-in (BRU_ALLOW_TEST_OVERRIDES=1, see tests/test_backup_completeness.sh);
# production always uses the repo-local paths. Every path destructive
# operations run against is validated with require_contained_dir (safe + under
# REPO_ROOT) — a poisoned environment or a bad override must never redirect
# rm -rf / mv at an arbitrary path.
if [ "$BRU_ALLOW_TEST_OVERRIDES" = "1" ]; then
  STAGE="${STAGE:-$REPO_ROOT/backups.staging}"
  ARTIFACTS="${ARTIFACTS:-$REPO_ROOT/backups.artifacts}"
else
  STAGE="$REPO_ROOT/backups.staging"
  ARTIFACTS="$REPO_ROOT/backups.artifacts"
fi
require_contained_dir STAGE "$STAGE" "$REPO_ROOT" || die "Unsafe STAGE path — aborting."
require_contained_dir ARTIFACTS "$ARTIFACTS" "$REPO_ROOT" || die "Unsafe ARTIFACTS path — aborting."
require_contained_dir BACKUPS_DIR "$BACKUPS_DIR" "$REPO_ROOT" || die "Unsafe BACKUPS_DIR path — aborting."

# Clean up any stale staging from a previous run that crashed.
rm -rf "$STAGE" "$ARTIFACTS"
mkdir -p "$STAGE"/{apps,services,dotfiles,user-dirs,cron}
> "$ARTIFACTS"  # tracked artifact file: one line per declared item

manifest_in_progress "$BACKUP_RUN_ID"

# Helper: record an artifact status line.
record_artifact() { printf '%s/%s\n' "$1" "$2" >> "$ARTIFACTS"; }

# Helper: safe rsync returning 0 on success, 1 on failure.
# Uses -R (--relative) so nested paths keep their full relative location
# (e.g. ~/.config/opencode lands under dest/.config/opencode, not dest/opencode).
_safe_rsync() {
  local dest="$1" src="$2"; shift 2
  if [ "$DRY_RUN" = "1" ]; then
    return 0
  fi
  if rsync -aR "$@" "$src" "$dest/" 2>/dev/null; then
    return 0
  else
    return 1
  fi
}

# --- Apps: capture declared config paths ---------------------------------
while IFS= read -r name; do
  [ -n "$name" ] || continue
  dest="$STAGE/apps/$name"
  mkdir -p "$dest/home" "$dest/root"
  info "Backing up config for app: $name"
  _app_ok=1
  _app_paths=0   # any config_path declared (non-empty) seen
  # Backup-completeness policy (schema v4): `required: true` or
  # `on_missing: fail` turns a missing/incomplete artifact into 'failed'
  # (overall status failed, restore refuses by default).
  _app_strict="no"
  [ "$(app_get "$name" '.required // false')" = "true" ] && _app_strict="yes"
  [ "$(app_get "$name" '.on_missing // "warn"')" = "fail" ] && _app_strict="yes"

  excl=()
  while IFS= read -r e; do
    [ -n "$e" ] && excl+=(--exclude="$e")
  done < <(app_get "$name" '.exclude[]?')
  if [ "${#excl[@]}" -gt 0 ]; then
    info "  (excluded from backup: ${excl[*]#--exclude=})"
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    _app_paths=1
    src="$(expand_path "$p")"
    if [ ! -e "$src" ]; then
      warn "  skip (path not found): $p"
      _app_ok=0
      continue
    fi
    if [[ "$src" == "$HOME"* ]]; then
      rel="${src#"$HOME"/}"
      if ( cd "$HOME" && _safe_rsync "$dest/home" "./$rel" "${excl[@]}" ); then
        ok "  $p -> backups/apps/$name/"
      else
        warn "  $p -> rsync failed (partial read?); fix permissions and re-run"
        _app_ok=0
      fi
    elif [ ! -r "$src" ]; then
      warn "  $p -> not readable by current user; fix permissions (chmod/chown) or declare a readable path in the inventory"
      _app_ok=0
    elif ( cd / && _safe_rsync "$dest/root" "./${src#/}" "${excl[@]}" ); then
      ok "  $p -> backups/apps/$name/"
    else
      warn "  $p -> rsync failed (partial read?); fix permissions and re-run"
      _app_ok=0
    fi
  done < <(app_get "$name" '.config_paths[]?')

  if [ "$_app_paths" = "0" ]; then
    # No config_paths declared at all — nothing to back up by design.
    record_artifact "apps/$name" "empty"
  elif [ "$_app_ok" = "1" ]; then
    record_artifact "apps/$name" "captured"
  elif [ "$_app_strict" = "yes" ]; then
    # required: true / on_missing: fail — a missing or partial config is a
    # failure (overall status failed, restore refuses by default).
    record_artifact "apps/$name" "failed"
  else
    record_artifact "apps/$name" "incomplete"
  fi
done < <(yaml_list '.apps[] | .name')

# --- Services: capture declared unit files + config paths ------------------
while IFS=$'\t' read -r unit target; do
  [ -n "$unit" ] || continue
  sdest="$STAGE/services/$unit"
  mkdir -p "$sdest/home" "$sdest/root"
  _svc_ok=1
  _svc_has_unit=0
  # Backup-completeness policy (schema v4), same semantics as apps. Reads
  # INVENTORY_READ (the effective inventory — set by validate_inventory).
  _svc_strict="no"
  [ "$(unit="$unit" yq -r ".services[] | select(.unit == strenv(unit)) | .required // false" "$INVENTORY_READ")" = "true" ] && _svc_strict="yes"
  [ "$(unit="$unit" yq -r ".services[] | select(.unit == strenv(unit)) | .on_missing // \"warn\"" "$INVENTORY_READ")" = "fail" ] && _svc_strict="yes"

  if [ "$target" = "user" ]; then
    src="$HOME/.config/systemd/user/$unit"
  else
    src="/etc/systemd/system/$unit"
  fi
  if [ -f "$src" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      cp "$src" "$sdest/unit"
    fi
    ok "Service unit backed up: $unit"
    _svc_has_unit=1
  else
    warn "Service unit not found at $src — will not be restorable."
    _svc_ok=0
  fi

  while IFS= read -r p; do
    [ -n "$p" ] || continue
    csrc="$(expand_path "$p")"
    if [ ! -e "$csrc" ]; then
      warn "  $unit: skip (path not found): $p"
      _svc_ok=0
      continue
    fi
    mkdir -p "$sdest/home" "$sdest/root"
    if [[ "$csrc" == "$HOME"* ]]; then
      rel="${csrc#"$HOME"/}"
      if ( cd "$HOME" && _safe_rsync "$sdest/home" "./$rel" ); then
        ok "  $unit: $p -> backups/services/$unit/"
      else
        warn "  $unit: $p -> rsync failed (partial read?); fix permissions and re-run"
        _svc_ok=0
      fi
    elif [ ! -r "$csrc" ]; then
      warn "  $unit: $p -> not readable by current user; fix permissions (chmod/chown) or declare a readable path in the inventory"
      _svc_ok=0
    elif ( cd / && _safe_rsync "$sdest/root" "./${csrc#/}" ); then
      ok "  $unit: $p -> backups/services/$unit/"
    else
      warn "  $unit: $p -> rsync failed (partial read?); fix permissions and re-run"
      _svc_ok=0
    fi
  done < <(unit="$unit" yq -r ".services[] | select(.unit == strenv(unit)) | .config_paths[]?" "$INVENTORY_READ")

  if [ "$_svc_ok" = "1" ] && [ "$_svc_has_unit" = "1" ]; then
    record_artifact "services/$unit" "captured"
  elif [ "$_svc_strict" = "yes" ]; then
    record_artifact "services/$unit" "failed"
  elif [ "$_svc_has_unit" = "0" ]; then
    record_artifact "services/$unit" "missing-unit"
  else
    record_artifact "services/$unit" "incomplete"
  fi
done < <(yq -r '.services[] | [.unit, (.target // "system")] | @tsv' "$INVENTORY_READ")

# --- Cron jobs: capture declared crontab / /etc/cron.d files ---------------
# Schema v6: `cron_jobs:` declares WHICH cron sources the repo manages
# (source: user = the running user's crontab via crontab -l; source: cron.d =
# the file $CRON_D_DIR/<file>). The CONTENT is captured here, exactly like
# unit files — the inventory never hardcodes crontab lines.
while IFS=$'\t' read -r name source file; do
  [ -n "$name" ] || continue
  [ -n "$file" ] || file="$name"
  cdest="$STAGE/cron/$name"
  _cron_ok=1
  _cron_has_content=0
  # Backup-completeness policy (schema v6), same semantics as apps/services:
  # `on_missing: fail` turns a missing cron source into a 'failed' artifact.
  _cron_strict="no"
  [ "$(cron_job_get "$name" '.on_missing // "warn"')" = "fail" ] && _cron_strict="yes"

  case "$source" in
    user)
      if [ "$DRY_RUN" != "1" ] && crontab -l > "$cdest" 2>/dev/null; then
        if [ -s "$cdest" ]; then
          _cron_has_content=1
          ok "  $name: user crontab captured -> backups/cron/$name"
        else
          ok "  $name: user crontab is EMPTY (nothing scheduled) — recorded as empty"
        fi
      else
        warn "  $name: no crontab for $USER — will not be restorable."
        _cron_ok=0
      fi
      ;;
    cron.d)
      src="$CRON_D_DIR/$file"
      if [ -f "$src" ] && [ -r "$src" ]; then
        if [ "$DRY_RUN" != "1" ]; then
          cp "$src" "$cdest"
        fi
        _cron_has_content=1
        ok "  $name: $src -> backups/cron/$name"
      else
        warn "  $name: cron file not found at $src — will not be restorable."
        _cron_ok=0
      fi
      ;;
  esac

  if [ "$_cron_ok" = "1" ] && [ "$_cron_has_content" = "1" ]; then
    record_artifact "cron/$name" "captured"
  elif [ "$_cron_ok" = "1" ]; then
    record_artifact "cron/$name" "empty"
  elif [ "$_cron_strict" = "yes" ]; then
    record_artifact "cron/$name" "failed"
  else
    record_artifact "cron/$name" "missing"
  fi
done < <(yq -r '.cron_jobs[]? | [.name, .source, (.file // "")] | @tsv' "$INVENTORY_READ")

# --- Dotfiles --------------------------------------------------------------
while IFS= read -r df; do
  [ -n "$df" ] || continue
  if [ -f "$HOME/$df" ]; then
    if [ "$DRY_RUN" != "1" ]; then
      mkdir -p "$STAGE/dotfiles/$(dirname "$df")" 2>/dev/null || true
      cp "$HOME/$df" "$STAGE/dotfiles/$df"
    fi
    record_artifact "dotfiles/$df" "captured"
    ok "Dotfile backed up: $df"
  else
    record_artifact "dotfiles/$df" "missing"
    warn "Dotfile missing: $df"
  fi
done < <(yaml_list '.dotfiles[]')

# --- User dirs: capture whole declared data folders -----------------------
while IFS= read -r d; do
  [ -n "$d" ] || continue
  src="$(expand_path "$d")"
  if [ ! -d "$src" ]; then
    warn "User dir not found: $d"
    rel="${d/#\~\//}"
    record_artifact "user-dirs/$rel" "missing"
    continue
  fi
  if [ "$src" = "$HOME" ]; then
    warn "  skip (\$HOME itself cannot be a user dir): $d"
    continue
  fi
  rel="${src#"$HOME"/}"
  # Build exclude array from the entry's object-form exclude list (schema v7).
  excl=()
  while IFS= read -r e; do
    [ -n "$e" ] && excl+=(--exclude="$e")
  done < <(user_dir_exclude "$d")
  if [ "${#excl[@]}" -gt 0 ]; then
    info "  (excluded from user-dir backup: ${excl[*]#--exclude=})"
  fi
  ( cd "$HOME" && _safe_rsync "$STAGE/user-dirs" "./$rel" "${excl[@]}" )
  record_artifact "user-dirs/$rel" "captured"
  ok "  $d -> backups/user-dirs/"
done < <(user_dir_paths)

# --- Determine overall status ---------------------------------------------
_missing_count="$(manifest_count_status "missing" "$ARTIFACTS")"
_incomplete_count="$(manifest_count_status "incomplete" "$ARTIFACTS")"
_missing_unit_count="$(manifest_count_status "missing-unit" "$ARTIFACTS")"
_failed_count="$(manifest_count_status "failed" "$ARTIFACTS")"

if [ "$_missing_count" -gt 0 ] || [ "$_incomplete_count" -gt 0 ] || [ "$_missing_unit_count" -gt 0 ] || [ "$_failed_count" -gt 0 ]; then
  warn "  $_missing_count declared path(s) missing, $_incomplete_count incomplete, $_missing_unit_count service unit(s) missing, $_failed_count failed (required items)."
fi

# --- Content integrity: deterministic checksums over the staged payload ---
# SHA256SUMS covers every staged regular file except the manifest, mutable
# logs, and the checksum file itself. It ships in backups/ and every mirror
# snapshot; restore.sh verifies it before touching the system.
backup_generate_checksums "$STAGE"
ok "SHA256SUMS generated for the staged payload"

# --- Mirror to BACKUP_DEST ------------------------------------------------
MIRROR_STATUS="disabled"

mirror_backup() {
  [ -n "$BACKUP_DEST" ] || { info "BACKUP_DEST is empty — skipping local mirror."; return 0; }
  [[ "$BACKUP_KEEP" =~ ^[0-9]+$ ]] || BACKUP_KEEP=5

  # Reject BACKUP_DEST that overlaps with the repo or user home.
  _bd_canonical="$(realpath -m "$BACKUP_DEST" 2>/dev/null || printf '%s' "$BACKUP_DEST")"
  _repo_canonical="$(realpath -m "$REPO_ROOT" 2>/dev/null || printf '%s' "$REPO_ROOT")"
  if [ "$_bd_canonical" = "$_repo_canonical" ] || [[ "$_bd_canonical" == "$_repo_canonical"/* ]] || [[ "$_repo_canonical" == "$_bd_canonical"/* ]]; then
    warn "BACKUP_DEST ($BACKUP_DEST) overlaps with the repo — refusing to mirror. Set a different destination."
    MIRROR_STATUS="failed"
    return 0
  fi

  if ! mkdir -p "$BACKUP_DEST" 2>/dev/null; then
    warn "Cannot create $BACKUP_DEST — skipping mirror."
    MIRROR_STATUS="failed"
    return 0
  fi

  if [ ! -w "$BACKUP_DEST" ]; then
    warn "$BACKUP_DEST is not writable — skipping mirror. Is the disk mounted?"
    MIRROR_STATUS="failed"
    return 0
  fi

  local snap
  snap="$BACKUP_DEST/backup-$(date +%Y%m%d-%H%M%S%N)"

  # First mirror into the snapshot directory.
  info "Mirroring backups/ -> $snap (no filtering)"
  if ! rsync -a --no-o --no-g "$STAGE/" "$snap/"; then
    warn "Mirror to $snap failed — keeping local backups/ only."
    rm -rf "$snap" 2>/dev/null || true
    MIRROR_STATUS="failed"
    return 0
  fi

  # Write the final manifest + marker into the snapshot.
  manifest_final "$BACKUP_RUN_ID" "ok" "$ARTIFACTS" > "$snap/backup-info.txt"

  ok "Mirrored to $snap"
  MIRROR_STATUS="ok"

  # Rotation: keep the newest $BACKUP_KEEP snapshots.
  local -a old_snaps=()
  while IFS= read -r old; do
    [ -n "$old" ] && old_snaps+=("$old")
  done < <(ls -1dr "$BACKUP_DEST"/backup-* 2>/dev/null)
  if [ "${#old_snaps[@]}" -gt "$BACKUP_KEEP" ]; then
    local prune
    for prune in "${old_snaps[@]:$BACKUP_KEEP}"; do
      rm -rf "$prune"
      warn "Pruned old snapshot: $prune"
    done
  fi
}

mirror_backup

# --- Atomic publication: swap staging -> live ----------------------------
# Write the final manifest into the staged generation, then publish it:
# fail-fast first rename, same-filesystem check, deterministic rollback,
# cleanup trap, and the previous generation is kept until the new one passes
# manifest verification (see publish_backup in lib/common.sh).
manifest_final "$BACKUP_RUN_ID" "$MIRROR_STATUS" "$ARTIFACTS" > "$STAGE/backup-info.txt"
publish_backup

release_lock

echo
# The summary reflects what publication ACTUALLY did (PUBLISH_RESULT from
# publish_backup), not what the now-live manifest says — after a rollback the
# live manifest is the PREVIOUS generation's, so grepping it would report a
# false success for this run.
case "${PUBLISH_RESULT:-}" in
  published)
    ok "Backup complete and published."
    ;;
  rolled_back)
    warn "The new backup generation was not restorable — the previous verified backup was kept live. Review backup-info.txt for what failed."
    ;;
  kept_unverified)
    warn "Backup finished, but the new generation is not restorable and no previous backup existed to fall back to — restore would need --force-incomplete. Review backup-info.txt."
    ;;
  *)
    warn "Backup finished with issues — see backup-info.txt."
    ;;
esac
_lines_total="$(wc -l < "$BACKUP_MANIFEST" 2>/dev/null || echo 0)"
echo "  Artifacts captured — see backup-info.txt for details."
echo "  Mirror: ${MIRROR_STATUS} — BACKUP_DEST=${BACKUP_DEST:-<disabled>}, keeping ${BACKUP_KEEP} snapshot(s)."
if [ "$_missing_count" -gt 0 ] || [ "$_incomplete_count" -gt 0 ] || [ "$_missing_unit_count" -gt 0 ] || [ "$_failed_count" -gt 0 ]; then
  echo "  NOTE: $_missing_count path(s) missing, $_incomplete_count incomplete, $_missing_unit_count service unit(s) missing, $_failed_count failed — review backup-info.txt."
fi
