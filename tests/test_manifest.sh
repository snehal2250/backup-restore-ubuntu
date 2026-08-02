#!/bin/bash
# ---------------------------------------------------------------------------
# test_manifest.sh — unit tests for the backup-manifest helpers in
# lib/common.sh: manifest_in_progress (staging-only marker), manifest_final
# (overall status derivation), manifest_count_status, manifest_verify_restorable.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
STAGE="$SANDBOX/stage"
LIVE="$SANDBOX/backups"
ARTIFACTS="$SANDBOX/backups.artifacts"
BACKUPS_DIR="$LIVE"
BACKUP_MANIFEST="$LIVE/backup-info.txt"
mkdir -p "$STAGE" "$LIVE"

# A last-known-good live manifest (as a completed backup.sh run would leave).
printf 'run_id: PREV-1\nstatus: ok\nfinished: 2026-08-02T00:00:00Z\n' > "$LIVE/backup-info.txt"
cp "$LIVE/backup-info.txt" "$SANDBOX/live.before"

t_begin "manifest_in_progress: marker goes to STAGING, live manifest untouched"
manifest_in_progress "TEST-1"
assert_contains "status: in_progress" "$STAGE/backup-info.txt"
assert_contains "run_id: TEST-1" "$STAGE/backup-info.txt"
assert_ok cmp -s "$SANDBOX/live.before" "$LIVE/backup-info.txt"

t_begin "manifest_in_progress: without STAGE falls back to the live manifest (documented)"
unset STAGE
manifest_in_progress "TEST-2"
assert_contains "status: in_progress" "$LIVE/backup-info.txt"
STAGE="$SANDBOX/stage"
printf 'run_id: PREV-1\nstatus: ok\nfinished: 2026-08-02T00:00:00Z\n' > "$LIVE/backup-info.txt"

t_begin "manifest_count_status: counts per status"
printf 'apps/a/captured\ndotfiles/.bashrc/captured\napps/b/missing\nuser-dirs/x/missing\napps/c/incomplete\n' > "$ARTIFACTS"
assert_eq "2" "$(manifest_count_status captured "$ARTIFACTS")" "captured count"
assert_eq "2" "$(manifest_count_status missing "$ARTIFACTS")" "missing count"
assert_eq "1" "$(manifest_count_status incomplete "$ARTIFACTS")" "incomplete count"
assert_eq "0" "$(manifest_count_status empty "$ARTIFACTS")" "empty count"

t_begin "manifest_final: all captured -> status ok"
printf 'apps/a/captured\ndotfiles/.bashrc/captured\n' > "$ARTIFACTS"
_final_out="$(manifest_final RUN-1 ok "$ARTIFACTS")"
assert_str_contains "status: ok" "$_final_out"
assert_str_contains "mirror: ok" "$_final_out"

t_begin "manifest_final: any missing/incomplete -> status degraded"
printf 'apps/a/captured\napps/b/missing\n' > "$ARTIFACTS"
_final_out="$(manifest_final RUN-2 ok "$ARTIFACTS")"
assert_str_contains "status: degraded" "$_final_out"
assert_str_contains "apps/b/missing" "$_final_out"

t_begin "manifest_verify_restorable: ok manifest accepted"
printf 'status: ok\n---\napps/a/captured\n' > "$LIVE/backup-info.txt"
assert_ok manifest_verify_restorable "$LIVE/backup-info.txt"

t_begin "manifest_verify_restorable: in_progress refused"
printf 'status: in_progress\n' > "$LIVE/backup-info.txt"
assert_fail manifest_verify_restorable "$LIVE/backup-info.txt"

t_begin "manifest_verify_restorable: degraded refused"
printf 'status: degraded\n---\napps/a/missing\n' > "$LIVE/backup-info.txt"
assert_fail manifest_verify_restorable "$LIVE/backup-info.txt"

t_begin "manifest_verify_restorable: ok but no artifact list refused"
printf 'status: ok\n' > "$LIVE/backup-info.txt"
assert_fail manifest_verify_restorable "$LIVE/backup-info.txt"

t_begin "manifest_verify_restorable: missing manifest refused"
assert_fail manifest_verify_restorable "$LIVE/nonexistent-info.txt"

sandbox_cleanup
t_summary
