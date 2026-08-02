#!/bin/bash
# ---------------------------------------------------------------------------
# test_interrupted_backup.sh — REGRESSION tests for the transactional backup
# guarantees (the P0 fixes from the handoff):
#
#   1. The in_progress marker is written to the STAGING manifest only — the
#      live backups/ manifest is never modified in place, so a crash mid-run
#      leaves the last-known-good backup intact and restorable.
#   2. publish_backup (lib/common.sh) atomically swaps a VERIFIED generation
#      in, keeps the previous generation until the new one is verified, rolls
#      back when the new generation is degraded/manifest-less, and fails FAST
#      (previous backup untouched) when the live dir cannot be moved aside.
#
# publish_backup reads its globals ($STAGE, $BACKUPS_DIR, $BACKUP_MANIFEST,
# $ARTIFACTS, $REPO_ROOT) at call time, so every scenario here is fully
# sandboxed — including $REPO_ROOT, which keeps backups.old.* generations
# inside the sandbox. Each publish runs in a subshell so its EXIT trap (used
# for crash cleanup) can never take the test file down with it.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
SB="$SANDBOX"
REPO_ROOT="$SB"   # sandbox backups.old.* generations

# make_gen DIR MARKER STATUS — a synthetic backup generation. STATUS '' means
# "no manifest at all".
make_gen() {
  local dir="$1" marker="$2" status="$3"
  mkdir -p "$dir"
  printf '%s\n' "$marker" > "$dir/generation-marker.txt"
  if [ -n "$status" ]; then
    printf 'status: %s\n---\napps/demo/captured\n' "$status" > "$dir/backup-info.txt"
  fi
}

# --- 1. Interrupted run: live manifest untouched, staging carries the marker -
t_begin "interrupted: in_progress marker stays in staging, live backup untouched + restorable"
make_gen "$SB/live/backups" "OLD" "ok"
cp "$SB/live/backups/backup-info.txt" "$SB/live.before"
STAGE="$SB/stage"
mkdir -p "$STAGE"
manifest_in_progress "CRASH-1"
assert_contains "status: in_progress" "$STAGE/backup-info.txt"
assert_ok cmp -s "$SB/live.before" "$SB/live/backups/backup-info.txt"
# Simulate the crash: the run dies here, publish_backup never runs.
BACKUPS_DIR="$SB/live/backups"
BACKUP_MANIFEST="$SB/live/backups/backup-info.txt"
assert_ok manifest_verify_restorable "$BACKUP_MANIFEST"

# --- 2. publish_backup: verified new generation wins ------------------------
t_begin "publish: verified new generation replaces live, old generation dropped"
make_gen "$SB/live2/backups" "OLD2" "ok"
make_gen "$SB/stage2" "NEW2" "ok"
BACKUPS_DIR="$SB/live2/backups"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
STAGE="$SB/stage2"
ARTIFACTS="$SB/artifacts2"
if ( publish_backup ); then
  t_pass "publish_backup succeeded"
else
  t_fail "publish_backup failed"
fi
assert_str_contains "NEW2" "$(cat "$BACKUPS_DIR/generation-marker.txt")"
assert_contains "status: ok" "$BACKUP_MANIFEST"
assert_not_exists "$SB/stage2" "staging dir consumed by publish"
# No stray generations left behind.
if ls "$SB"/backups.old.* >/dev/null 2>&1; then
  t_fail "leftover backups.old.* after successful publish"
else
  t_pass "no leftover backups.old.* after successful publish"
fi
assert_ok manifest_verify_restorable "$BACKUP_MANIFEST"

# --- 3. publish_backup: degraded new generation rolls back to previous -------
t_begin "publish: degraded new generation rolls back to the verified previous one"
make_gen "$SB/live3/backups" "OLD3" "ok"
make_gen "$SB/stage3" "NEW3" "degraded"
BACKUPS_DIR="$SB/live3/backups"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
STAGE="$SB/stage3"
ARTIFACTS="$SB/artifacts3"
if ( publish_backup ); then
  t_pass "publish_backup returned 0 after rollback"
else
  t_fail "publish_backup failed unexpectedly"
fi
assert_str_contains "OLD3" "$(cat "$BACKUPS_DIR/generation-marker.txt")"
assert_contains "status: ok" "$BACKUP_MANIFEST"

# --- 4. publish_backup: manifest-less new generation rolls back --------------
t_begin "publish: manifest-less new generation rolls back to the previous one"
make_gen "$SB/live4/backups" "OLD4" "ok"
make_gen "$SB/stage4" "NEW4" ""
BACKUPS_DIR="$SB/live4/backups"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
STAGE="$SB/stage4"
ARTIFACTS="$SB/artifacts4"
if ( publish_backup ); then
  t_pass "publish_backup returned 0 after rollback"
else
  t_fail "publish_backup failed unexpectedly"
fi
assert_str_contains "OLD4" "$(cat "$BACKUPS_DIR/generation-marker.txt")"
assert_contains "status: ok" "$BACKUP_MANIFEST"

# --- 5. publish_backup: manifest-less new generation, no previous -> fail ----
t_begin "publish: manifest-less new generation with NO previous generation fails and removes the unusable dir"
make_gen "$SB/stage5" "NEW5" ""
BACKUPS_DIR="$SB/only-live"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
STAGE="$SB/stage5"
ARTIFACTS="$SB/artifacts5"
if ( publish_backup ); then
  t_fail "publish_backup should have died"
else
  t_pass "publish_backup died as expected"
fi
assert_not_exists "$SB/only-live" "unusable live dir removed"
assert_not_exists "$SB/stage5" "staging cleaned up by trap"

# --- 6. publish_backup: live dir not movable -> fail-fast, previous intact ---
t_begin "publish: cannot move live aside -> fail-fast, previous backup NOT modified"
make_gen "$SB/live6/backups" "OLD6" "ok"
make_gen "$SB/stage6" "NEW6" "ok"
chmod 555 "$SB/live6"
BACKUPS_DIR="$SB/live6/backups"
BACKUP_MANIFEST="$BACKUPS_DIR/backup-info.txt"
STAGE="$SB/stage6"
ARTIFACTS="$SB/artifacts6"
if ( publish_backup ); then
  t_fail "publish_backup should have died (live dir not movable)"
else
  t_pass "publish_backup died (fail-fast, previous backup untouched)"
fi
chmod 755 "$SB/live6"
assert_str_contains "OLD6" "$(cat "$BACKUPS_DIR/generation-marker.txt")"
assert_contains "status: ok" "$BACKUP_MANIFEST"

sandbox_cleanup
t_summary
