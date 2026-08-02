#!/bin/bash
# ---------------------------------------------------------------------------
# test_rollback.sh — unit tests for the rollback bundle + restore journal
# helpers (rollback_init / rollback_capture / journal_log) and the per-owner
# conflict_policy_get lookup, all in lib/common.sh.
#
# HOME is pointed at a sandbox so rollback_init never touches the real
# ~/.local/state. conflict_policy_get reads $INVENTORY_FILE at call time, so a
# sandboxed inventory works — and the sandbox lives under the repo root
# because the snap-packaged yq cannot read /tmp (see AGENTS.md).
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if ! command -v yq >/dev/null 2>&1 || ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: yq (conflict_policy_get) and/or rsync (tree capture) not installed"
  exit 0
fi

# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
# Point HOME at the sandbox BEFORE any rollback helper runs.
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.config"
STATE="$HOME/.local/state/backup-restore-ubuntu"

# --- conflict_policy_get ---------------------------------------------------
INVENTORY_FILE="$SANDBOX/inventory.yaml"
cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 3
profile: workstation
apps:
  - name: appA
    installer:
      type: apt
    conflict_policy: replace
  - name: appB
    installer:
      type: apt
    conflict_policy: skip-existing
  - name: appC
    installer:
      type: apt
    conflict_policy: prompt
  - name: appD
    installer:
      type: apt
services:
  - unit: srv.service
    target: system
    conflict_policy: replace
YAML

t_begin "conflict_policy_get: declared policies per app"
assert_eq "replace"       "$(conflict_policy_get app appA)" "appA policy"
assert_eq "skip-existing" "$(conflict_policy_get app appB)" "appB policy"
assert_eq "prompt"        "$(conflict_policy_get app appC)" "appC policy"

t_begin "conflict_policy_get: absent key defaults to merge"
assert_eq "merge" "$(conflict_policy_get app appD)" "appD default"

t_begin "conflict_policy_get: service policies"
assert_eq "replace" "$(conflict_policy_get service srv.service)" "service policy"
assert_eq "merge"   "$(conflict_policy_get service nosuch.service)" "unknown service default"

# --- rollback_init + journal_log -------------------------------------------
t_begin "rollback_init: creates bundle + journal header"
DRY_RUN=0
ROLLBACK_DIR=""
assert_ok rollback_init
assert_file_exists "$ROLLBACK_DIR/restore-journal.log" "journal file"
assert_contains "# restore journal" "$ROLLBACK_DIR/restore-journal.log"
assert_contains "actions: created | replaced | skipped | failed" "$ROLLBACK_DIR/restore-journal.log"

t_begin "journal_log: appends one line per action"
journal_log replaced services/x/unit
journal_log created dotfiles/.bashrc
journal_log skipped apps/tmux/home
assert_contains "replaced services/x/unit" "$ROLLBACK_DIR/restore-journal.log"
assert_contains "created dotfiles/.bashrc" "$ROLLBACK_DIR/restore-journal.log"
assert_contains "skipped apps/tmux/home" "$ROLLBACK_DIR/restore-journal.log"

t_begin "journal_log: dry-run prints but writes nothing"
rm -rf "$STATE"
DRY_RUN=1
ROLLBACK_DIR=""
journal_log replaced dummy >/dev/null 2>&1
assert_not_exists "$STATE" "no state dir created under dry-run"
DRY_RUN=0

# --- rollback_capture: single-file case ------------------------------------
SRC="$SANDBOX/src-file"
DEST="$SANDBOX/dest-file"
printf 'unit\n' > "$SRC"
printf 'old\n' > "$DEST"

t_begin "rollback_capture: file exists at dest -> captured, returns 1"
ROLLBACK_DIR=""
if rollback_capture "$SRC" "$DEST" "services/x/unit"; then
  t_fail "file capture with existing dest should return 1"
else
  t_pass "file capture returns 1 (existing found)"
fi
assert_file_exists "$ROLLBACK_DIR/services/x/unit" "existing file captured into bundle"
assert_eq "old" "$(cat "$ROLLBACK_DIR/services/x/unit")" "captured content preserved"

t_begin "rollback_capture: file absent at dest -> nothing captured, returns 0"
ROLLBACK_DIR=""
if rollback_capture "$SRC" "$SANDBOX/not-there" "services/x/unit"; then
  t_pass "file capture with absent dest returns 0"
else
  t_fail "file capture with absent dest should return 0"
fi

# --- rollback_capture: tree case --------------------------------------------
TSRC="$SANDBOX/src-tree"
TDEST="$SANDBOX/dest-tree"
mkdir -p "$TSRC/.config/demo" "$TDEST/.config/demo" "$TDEST/other"
printf 'backup\n' > "$TSRC/.config/demo/settings.json"
printf 'existing\n' > "$TDEST/.config/demo/settings.json"
printf 'untouched\n' > "$TDEST/other/keep.txt"

t_begin "rollback_capture: tree captures only existing counterparts"
ROLLBACK_DIR=""
if rollback_capture "$TSRC" "$TDEST" "apps/demo/home"; then
  t_fail "tree capture with existing counterparts should return 1"
else
  t_pass "tree capture returns 1 (existing found)"
fi
assert_file_exists "$ROLLBACK_DIR/apps/demo/home/.config/demo/settings.json" "existing counterpart captured"
assert_not_exists "$ROLLBACK_DIR/apps/demo/home/other/keep.txt" "non-overlapping file NOT captured"

t_begin "rollback_capture: tree with nothing existing returns 0"
ROLLBACK_DIR=""
rm -rf "$TDEST"
mkdir -p "$TDEST"
if rollback_capture "$TSRC" "$TDEST" "apps/demo/home"; then
  t_pass "tree capture with empty dest returns 0"
else
  t_fail "tree capture with empty dest should return 0"
fi

t_begin "rollback_capture: dry-run returns 1 (existing) but creates nothing"
rm -rf "$STATE"
DRY_RUN=1
ROLLBACK_DIR=""
mkdir -p "$TDEST/.config/demo"
printf 'existing\n' > "$TDEST/.config/demo/settings.json"
if rollback_capture "$TSRC" "$TDEST" "apps/demo/home"; then
  t_fail "dry-run tree capture with existing should return 1"
else
  t_pass "dry-run tree capture returns 1"
fi
assert_not_exists "$STATE" "no state dir created under dry-run"
DRY_RUN=0

sandbox_cleanup
t_summary
