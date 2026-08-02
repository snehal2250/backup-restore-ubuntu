#!/bin/bash
# ---------------------------------------------------------------------------
# test_integrity.sh — unit tests for the SHA256SUMS content-integrity helpers
# (backup_generate_checksums / backup_verify_integrity in lib/common.sh).
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
TREE="$SANDBOX/tree"
mkdir -p "$TREE/apps/demo/home/.config/demo" "$TREE/dotfiles" "$TREE/user-dirs/Documents"
printf 'conf\n' > "$TREE/apps/demo/home/.config/demo/settings.json"
printf 'bashrc\n' > "$TREE/dotfiles/.bashrc"
printf 'doc\n' > "$TREE/user-dirs/Documents/readme.txt"
# Mutable / non-payload files that must NEVER be checksummed:
printf 'logline\n' > "$TREE/cron-backup.log"
printf 'status: ok\n' > "$TREE/backup-info.txt"

t_begin "generate: creates a non-empty SHA256SUMS"
assert_ok backup_generate_checksums "$TREE"
assert_file_exists "$TREE/SHA256SUMS" "SHA256SUMS created"

t_begin "generate: excludes manifest, *.log and itself"
assert_not_contains 'backup-info.txt' "$TREE/SHA256SUMS"
assert_not_contains 'cron-backup.log' "$TREE/SHA256SUMS"
assert_not_contains 'SHA256SUMS' "$TREE/SHA256SUMS"

t_begin "generate: covers the payload files"
assert_contains '.config/demo/settings.json' "$TREE/SHA256SUMS"
assert_contains 'dotfiles/.bashrc' "$TREE/SHA256SUMS"
assert_contains 'user-dirs/Documents/readme.txt' "$TREE/SHA256SUMS"

t_begin "generate: deterministic (stable output across runs)"
backup_generate_checksums "$TREE"
cp "$TREE/SHA256SUMS" "$SANDBOX/SHA256SUMS.first"
backup_generate_checksums "$TREE"
assert_ok cmp -s "$SANDBOX/SHA256SUMS.first" "$TREE/SHA256SUMS"

t_begin "verify: clean tree passes"
assert_ok backup_verify_integrity "$TREE"

t_begin "verify: tampered file rejected"
printf 'tampered\n' >> "$TREE/apps/demo/home/.config/demo/settings.json"
assert_fail backup_verify_integrity "$TREE"
printf 'conf\n' > "$TREE/apps/demo/home/.config/demo/settings.json"
backup_generate_checksums "$TREE"   # re-sync after repair

t_begin "verify: missing file rejected"
rm "$TREE/dotfiles/.bashrc"
assert_fail backup_verify_integrity "$TREE"
printf 'bashrc\n' > "$TREE/dotfiles/.bashrc"
backup_generate_checksums "$TREE"   # re-sync after repair

t_begin "verify: symlink escaping the snapshot rejected"
ln -s /etc/passwd "$TREE/apps/demo/evil"
assert_fail backup_verify_integrity "$TREE"
rm "$TREE/apps/demo/evil"

t_begin "verify: benign in-tree symlink accepted"
ln -s ../.config/demo/settings.json "$TREE/apps/demo/link.json"
assert_ok backup_verify_integrity "$TREE"
rm "$TREE/apps/demo/link.json"

t_begin "verify: FIFO (hostile special file) rejected"
mkfifo "$TREE/apps/demo/pipe"
assert_fail backup_verify_integrity "$TREE"
rm "$TREE/apps/demo/pipe"

t_begin "verify: extra unlisted file warns but passes"
printf 'added-later\n' > "$TREE/apps/demo/extra.txt"
assert_ok backup_verify_integrity "$TREE"
rm "$TREE/apps/demo/extra.txt"

t_begin "verify: missing SHA256SUMS rejected"
rm "$TREE/SHA256SUMS"
assert_fail backup_verify_integrity "$TREE"

t_begin "verify: non-directory argument rejected"
assert_fail backup_verify_integrity "$TREE/dotfiles/.bashrc"

sandbox_cleanup
t_summary
