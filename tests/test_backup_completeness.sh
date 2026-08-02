#!/bin/bash
# ---------------------------------------------------------------------------
# test_backup_completeness.sh — INTEGRATION test for the P1 backup-completeness
# semantics, running the REAL backup.sh against a fully sandboxed repo:
#
#   * apps with `required: true` or `on_missing: fail` whose declared paths are
#     missing produce a `failed` artifact and an overall `status: failed`
#     manifest (restore refuses it by default);
#   * the same apps WITHOUT the strict policy produce `incomplete` artifacts and
#     an overall `status: degraded` manifest;
#   * a fully captured backup with the mirror disabled produces
#     `status: ok_with_warnings` (complete backup, warning only) — restorable;
#   * restore.sh --source refuses a `failed` snapshot.
#
# Sandboxing: REPO_ROOT/INVENTORY_FILE/INVENTORY_SCHEMA/BACKUPS_DIR (and
# backup.sh's STAGE/ARTIFACTS/lock) are env-overridable, HOME points at the
# sandbox, and BACKUP_DEST='' disables the mirror — nothing outside the
# git-ignored sandbox is touched.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

ORIG_REPO="$REPO_ROOT"
sandbox_new
SB="$SANDBOX"

# The schema must live where the overridden INVENTORY_SCHEMA default points.
mkdir -p "$SB/inventory"
cp "$ORIG_REPO/inventory/schema.yaml" "$SB/inventory/schema.yaml"

export HOME="$SB/home"
mkdir -p "$HOME/.config/good-app"
printf 'x\n' > "$HOME/.config/good-app/settings.json"

export REPO_ROOT="$SB"
export INVENTORY_FILE="$SB/inventory/inventory.yaml"
export BACKUP_DEST=""        # mirror disabled -> ok_with_warnings when all captured

MF="$SB/backups/backup-info.txt"

run_backup() { # label
  if bash "$ORIG_REPO/backup.sh" > "$SB/backup.log" 2>&1; then
    t_pass "backup.sh ran ($1)"
  else
    t_fail "backup.sh failed ($1) — see $SB/backup.log"
  fi
}

# Each scenario runs against a FRESH publication context: publish_backup's
# transactional guarantee (#8) keeps the previous generation live whenever the
# new one is not restorable (ok/ok_with_warnings), so a degraded/failed run
# rolls back to the prior generation. That interaction is covered by
# test_interrupted_backup.sh; here we isolate per-run status derivation by
# dropping the previous generation before each scenario.
reset_backup_state() { rm -rf "$SB/backups"; }

# --- Run 1: required + on_missing:fail apps with MISSING paths ----------------
t_begin "completeness: strict items missing -> failed artifacts + failed status"
cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 4
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: good-app
    installer: { type: apt }
    config_paths: ["~/.config/good-app"]
  - name: opt-app
    installer: { type: apt }
    config_paths: ["~/.config/opt-app"]
  - name: req-app
    installer: { type: apt }
    required: true
    config_paths: ["~/.config/req-app"]
  - name: fail-app
    installer: { type: apt }
    on_missing: fail
    config_paths: ["~/.config/fail-app"]
services: []
YAML
run_backup "strict missing"
assert_contains "status: failed" "$MF"
assert_contains "apps/good-app/captured" "$MF"
assert_contains "apps/opt-app/incomplete" "$MF"
assert_contains "apps/req-app/failed" "$MF"
assert_contains "apps/fail-app/failed" "$MF"
assert_contains "failures: 2" "$MF"
assert_contains "failed=2" "$MF"

t_begin "completeness: restore.sh --source refuses the failed snapshot"
if bash "$ORIG_REPO/restore.sh" --source "$SB/backups" --dry-run --yes > "$SB/restore.log" 2>&1; then
  t_fail "restore.sh should have refused the failed snapshot"
else
  t_pass "restore.sh refused the failed snapshot (exit nonzero)"
fi

# --- Run 1b: required SERVICE with missing unit -> failed -------------------
reset_backup_state
t_begin "completeness: required service with missing unit -> failed artifact + failed status"
cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 4
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: good-app
    installer: { type: apt }
    config_paths: ["~/.config/good-app"]
services:
  - unit: mysvc.service
    target: user
    required: true
    config_paths: []
YAML
run_backup "strict service missing unit"
assert_contains "status: failed" "$MF"
assert_contains "services/mysvc.service/failed" "$MF"
assert_contains "apps/good-app/captured" "$MF"

# --- Run 2: same apps WITHOUT strict policy -> degraded ----------------------
reset_backup_state
t_begin "completeness: non-strict items missing -> incomplete artifacts + degraded status"
cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 4
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: good-app
    installer: { type: apt }
    config_paths: ["~/.config/good-app"]
  - name: opt-app
    installer: { type: apt }
    config_paths: ["~/.config/opt-app"]
  - name: req-app
    installer: { type: apt }
    config_paths: ["~/.config/req-app"]
  - name: fail-app
    installer: { type: apt }
    config_paths: ["~/.config/fail-app"]
services: []
YAML
run_backup "non-strict missing"
assert_contains "status: degraded" "$MF"
assert_contains "apps/req-app/incomplete" "$MF"
assert_contains "apps/fail-app/incomplete" "$MF"
assert_not_contains "apps/req-app/failed" "$MF"

# --- Run 3: everything present, mirror disabled -> ok_with_warnings ----------
reset_backup_state
t_begin "completeness: all captured + mirror disabled -> ok_with_warnings (restorable)"
mkdir -p "$HOME/.config/opt-app" "$HOME/.config/req-app" "$HOME/.config/fail-app"
printf 'x\n' > "$HOME/.config/opt-app/settings.json"
printf 'x\n' > "$HOME/.config/req-app/settings.json"
printf 'x\n' > "$HOME/.config/fail-app/settings.json"
run_backup "all captured"
assert_contains "status: ok_with_warnings" "$MF"
assert_contains "apps/good-app/captured" "$MF"
assert_contains "apps/req-app/captured" "$MF"
assert_contains "warnings: 1" "$MF"
assert_contains "failures: 0" "$MF"
assert_contains "mirror: disabled" "$MF"

# --- Run 4: a failed generation rolls back; the summary stays truthful -------
t_begin "completeness: failed generation with a previous good one rolls back and the summary is truthful"
# Run 3 left a PUBLISHED ok_with_warnings generation in $SB/backups. Add a
# REQUIRED app whose path is missing -> the new generation is 'failed' ->
# publish_backup restores the previous (restorable) generation. The CLI
# summary must say the previous backup was kept live, NOT a fresh success
# (regression: the old code re-read $BACKUP_MANIFEST after the rollback and
# saw the OLD 'ok' manifest, reporting 'Backup complete' for a failed run).
cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 4
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: good-app
    installer: { type: apt }
    config_paths: ["~/.config/good-app"]
  - name: opt-app
    installer: { type: apt }
    config_paths: ["~/.config/opt-app"]
  - name: req-app
    installer: { type: apt }
    config_paths: ["~/.config/req-app"]
  - name: fail-app
    installer: { type: apt }
    config_paths: ["~/.config/fail-app"]
  - name: new-req
    installer: { type: apt }
    required: true
    config_paths: ["~/.config/new-req"]
services: []
YAML
run_backup "failed run with previous good generation"
# The live manifest must be the PREVIOUS (restorable) generation.
assert_contains "status: ok_with_warnings" "$MF"
assert_not_contains "apps/new-req" "$MF"
# The CLI summary must not claim a fresh success after the rollback.
assert_not_contains "Backup complete and published" "$SB/backup.log"
assert_contains "previous verified backup was kept live" "$SB/backup.log"

# --- Sandboxing: hostile path overrides die before any destructive op --------
t_begin "sandboxing: BACKUPS_DIR outside the sandbox is refused before anything is touched"
if ( export BACKUPS_DIR=/bru-hostile-escape; bash "$ORIG_REPO/backup.sh" > "$SB/escape.log" 2>&1 ); then
  t_fail "backup.sh accepted an escaping BACKUPS_DIR"
else
  t_pass "backup.sh refused an escaping BACKUPS_DIR (exit nonzero)"
fi
assert_contains "Unsafe BACKUPS_DIR path" "$SB/escape.log"

t_begin "sandboxing: a non-sandbox REPO_ROOT override is refused at source time"
if ( export REPO_ROOT=/tmp/not-a-test-sandbox; bash "$ORIG_REPO/backup.sh" > "$SB/root.log" 2>&1 ); then
  t_fail "backup.sh accepted a non-sandbox REPO_ROOT override"
else
  t_pass "backup.sh refused a non-sandbox REPO_ROOT override (exit nonzero)"
fi
assert_contains "not a test sandbox" "$SB/root.log"

# --- manifest_verify_restorable honors the new statuses ----------------------
t_begin "completeness: manifest_verify_restorable accepts ok_with_warnings, rejects failed"
# shellcheck source=lib/common.sh
source "$ORIG_REPO/lib/common.sh"
assert_ok manifest_verify_restorable "$MF"
printf 'status: failed\nfailures: 1\n---\napps/req/failed\n' > "$SB/backups/backup-info.txt"
assert_fail manifest_verify_restorable "$SB/backups/backup-info.txt"

sandbox_cleanup
t_summary
