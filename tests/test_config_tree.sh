#!/bin/bash
# ---------------------------------------------------------------------------
# test_config_tree.sh — functional regression test for restore_sync_tree
# (lib/common.sh): a config-tree sync must NEVER propagate the staged source
# tree's directory owner/group/mode onto the destination root or pre-existing
# destination directories.
#
# Rehearsal finding (2026-08-05): restore ran `sudo rsync -a "$src/" /` for
# root-owned config trees. The staged backup (copied `cp -a` from a vboxsf
# share, which presents dmode=0770,gid=vboxsf) carried 0770 dirs owned by the
# staging user — rsync -a wrote those attributes onto / and /etc, locking out
# every unprivileged daemon (dbus/resolved/avahi/polkit/NetworkManager failed
# at boot). restore_sync_tree syncs with --no-owner --no-group and re-asserts
# the pre-existing modes of every destination dir the source tree touches.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

if ! command -v rsync >/dev/null 2>&1; then
  echo "SKIP: rsync not installed"
  exit 0
fi

# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
DRY_RUN=0

# Mimic the rehearsal: a STAGED source tree carrying foreign metadata (all
# dirs 0770, as a vboxsf share presents them) and a pre-existing destination
# root with sane 0755 mode + an unrelated 0700 dir that must survive.
SRC="$SANDBOX/staged-root"
DEST="$SANDBOX/dest-root"
mkdir -p "$SRC/etc/app" "$DEST" "$DEST/keep"
printf 'config\n' > "$SRC/etc/app/config.yml"
printf 'sensitive\n' > "$SRC/etc/app/key.pem"
chmod 600 "$SRC/etc/app/key.pem"
printf 'untouched\n' > "$DEST/keep/other.txt"
chmod 770 "$SRC" "$SRC/etc" "$SRC/etc/app"   # share-style polluted source
chmod 755 "$DEST"                            # pre-existing dest root: sane
chmod 700 "$DEST/keep"                       # unrelated dir: must be kept

t_begin "restore_sync_tree: dest root + unrelated dir modes survive the sync"
restore_sync_tree "$SRC" "$DEST" "" ""
assert_eq "755" "$(stat -c '%a' "$DEST")" "dest root mode preserved"
assert_eq "700" "$(stat -c '%a' "$DEST/keep")" "unrelated dest dir mode preserved"

t_begin "restore_sync_tree: file content restored, file modes preserved"
assert_file_exists "$DEST/etc/app/config.yml" "config restored"
assert_eq "config" "$(cat "$DEST/etc/app/config.yml")" "content matches"
assert_eq "600" "$(stat -c '%a' "$DEST/etc/app/key.pem")" "0600 file mode preserved"

t_begin "restore_sync_tree: created dirs keep the source mode (new config dir)"
# etc/app did not exist before the sync -> it is a NEW config dir and keeps
# the source's mode (sane 0755 for a real backup; the catastrophe class was
# / and /etc themselves, which pre-existed and are now protected).
assert_eq "770" "$(stat -c '%a' "$DEST/etc/app")" "created dir keeps source mode"

t_begin "restore_sync_tree: dry-run changes nothing"
DRY_RUN=1
DEST2="$SANDBOX/dest2"
mkdir -p "$DEST2"
chmod 755 "$DEST2"
restore_sync_tree "$SRC" "$DEST2" "" ""
assert_not_exists "$DEST2/etc/app/config.yml" "no files created under dry-run"
assert_eq "755" "$(stat -c '%a' "$DEST2")" "dest root untouched under dry-run"
DRY_RUN=0

t_begin "restore_sync_tree: EMPTY source tree never touches the dest root mode"
# The exact round-8 rehearsal failure: every legacy app artifact holds an
# empty root/ dir staged with 0770 (vboxsf dmode). `rsync -a` of that tree
# onto / rewrote / to 0770 — sudo died, the re-assert could not run, and the
# whole boot locked out unprivileged daemons. An empty tree must be a
# complete no-op (no rsync, no chmod, no copy).
EMPTY_SRC="$SANDBOX/empty-root"
DEST3="$SANDBOX/dest3"
mkdir -p "$EMPTY_SRC" "$DEST3"
chmod 770 "$EMPTY_SRC"
chmod 755 "$DEST3"
restore_sync_tree "$EMPTY_SRC" "$DEST3" "" ""
assert_eq "755" "$(stat -c '%a' "$DEST3")" "dest root mode untouched by an empty tree"
assert_eq "0" "$(find "$DEST3" -mindepth 1 | wc -l)" "empty tree copies nothing"

# The empty-tree skip must also hold for the ROOT-owned path (dest=/ on a
# real run): an empty legacy root/ tree must not rewrite the dest root mode.
# `env` mocks sudo — it execs the command in-place, exercising the exact
# single bash -c code path without needing a root shell in the sandbox.
t_begin "restore_sync_tree: EMPTY tree is a no-op on the sudo'd root path"
DEST5="$SANDBOX/dest5"
mkdir -p "$DEST5"
chmod 755 "$DEST5"
restore_sync_tree "$EMPTY_SRC" "$DEST5" "" "env"
assert_eq "755" "$(stat -c '%a' "$DEST5")" "dest root mode untouched (sudo path, empty tree)"

# The ROOT-owned path (dest would be / on a real run) with a NON-empty
# polluted source: rsync + re-asserts run inside one bash -c (env mock), and
# the dest root mode must be re-asserted even though the source top dir is
# 0770. This is the round-7 failure class: sudo rsync of a 0770 tree onto /
# set / to 0770; the re-assert chmod must still run.
t_begin "restore_sync_tree: sudo path re-asserts the dest root mode in one context"
SRC3="$SANDBOX/staged-root3"
DEST6="$SANDBOX/dest6"
mkdir -p "$SRC3/etc/app" "$DEST6"
printf 'x\n' > "$SRC3/etc/app/config.yml"
chmod 770 "$SRC3" "$SRC3/etc" "$SRC3/etc/app"   # share-style polluted source
chmod 755 "$DEST6"                              # pre-existing dest root: sane
restore_sync_tree "$SRC3" "$DEST6" "" "env"
assert_eq "755" "$(stat -c '%a' "$DEST6")" "dest root mode re-asserted (sudo path)"
assert_file_exists "$DEST6/etc/app/config.yml" "config restored via sudo path"

t_begin "restore_sync_tree: a FAILED sync returns nonzero (truthful exit codes)"
# Round-8 review finding: the sudo path swallowed rsync failures with `|| warn`
# and returned 0, so restore_config_tree printed "[ OK ] config restored" and
# restore exited 0 for a config that was never applied (violates principle 9 —
# a failed config restore must surface in the accumulated exit code). Both
# branches must return nonzero so the caller can mark_failure. An UNREADABLE
# source file makes `find` succeed (the empty-tree check passes) while the
# rsync itself fails (code 23) — the realistic failure the skip cannot catch.
SRC4="$SANDBOX/fail-src"
DEST7="$SANDBOX/fail-dest"
mkdir -p "$SRC4/etc" "$DEST7"
printf 'secret\n' > "$SRC4/etc/app.conf"
chmod 000 "$SRC4/etc/app.conf"   # unreadable file: rsync fails, find succeeds
chmod 755 "$DEST7"
if restore_sync_tree "$SRC4" "$DEST7" "" "env"; then
  t_fail "restore_sync_tree must return nonzero when the rsync fails (sudo path)"
else
  t_pass "restore_sync_tree returns nonzero on rsync failure (sudo path)"
fi
if restore_sync_tree "$SRC4" "$DEST7" "" ""; then
  t_fail "restore_sync_tree must return nonzero when the rsync fails (plain path)"
else
  t_pass "restore_sync_tree returns nonzero on rsync failure (plain path)"
fi

sandbox_cleanup
t_summary
