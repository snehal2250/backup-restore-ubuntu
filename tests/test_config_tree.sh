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

sandbox_cleanup
t_summary
