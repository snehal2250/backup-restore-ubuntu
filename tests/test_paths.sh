#!/bin/bash
# ---------------------------------------------------------------------------
# test_paths.sh — unit tests for the safe path helpers in lib/common.sh:
# expand_path (tilde expansion only) and normalize_path + validate_path_contained
# (canonicalisation with traversal/control-char rejection).
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

sandbox_new
export HOME="$SANDBOX/home"

t_begin "expand_path: tilde forms"
assert_eq "$HOME"          "$(expand_path "~")" "bare tilde"
assert_eq "$HOME/.config"  "$(expand_path "~/.config")" "tilde + subpath"
assert_eq "/etc/hosts"     "$(expand_path "/etc/hosts")" "absolute passthrough"

t_begin "normalize_path: tilde forms"
assert_eq "$HOME"         "$(normalize_path "~")" "bare tilde"
assert_eq "$HOME/.config" "$(normalize_path "~/.config")" "tilde + subpath"

t_begin "normalize_path: rejects traversal"
assert_fail normalize_path "../etc"
assert_fail normalize_path "~/../etc"
assert_fail normalize_path "~/a/../../b"

t_begin "normalize_path: rejects control characters"
# printf '\x01' (single backslash) emits a real 0x01 control byte.
assert_fail normalize_path "$(printf '~/bad\x01name')"

t_begin "validate_path_contained: under the root accepted, outside rejected"
mkdir -p "$HOME/Documents"
assert_ok validate_path_contained "~/Documents" "$HOME"
assert_ok validate_path_contained "~/.config/app" "$HOME"
assert_fail validate_path_contained "/etc" "$HOME"
assert_fail validate_path_contained "../etc" "$HOME"

t_begin "require_safe_dir: rejects empty, /, ., .. and resolves-to-/ paths"
assert_fail require_safe_dir STAGE ""
assert_fail require_safe_dir STAGE "/"
assert_fail require_safe_dir STAGE "."
assert_fail require_safe_dir STAGE ".."
assert_fail require_safe_dir STAGE "/tmp/.."      # realpath -m -> /
assert_ok require_safe_dir STAGE "$SANDBOX/backups"
assert_ok require_safe_dir STAGE "/tmp/backup-restore-ubuntu-staging"

t_begin "require_contained_dir: contained under the root accepted, escaping rejected"
assert_ok require_contained_dir STAGE "$SANDBOX/backups" "$SANDBOX"
assert_ok require_contained_dir STAGE "$SANDBOX" "$SANDBOX"            # equal to root
assert_ok require_contained_dir STAGE "$SANDBOX/sub/deep/path" "$SANDBOX"
assert_fail require_contained_dir STAGE "$SANDBOX/../escape" "$SANDBOX"
assert_fail require_contained_dir STAGE "/etc" "$SANDBOX"
assert_fail require_contained_dir STAGE "/" "$SANDBOX"
assert_fail require_contained_dir STAGE "" "$SANDBOX"
assert_fail require_contained_dir STAGE "/tmp/.." "$SANDBOX"            # resolves to /
assert_fail require_contained_dir STAGE "$SANDBOX/backups" "/"          # root itself unsafe

t_begin "require_contained_dir: a symlink escaping the root is rejected"
ln -sfn "$REPO_ROOT/tests" "$SANDBOX/link-out"   # exists + points outside the sandbox
assert_fail require_contained_dir STAGE "$SANDBOX/link-out" "$SANDBOX"
assert_ok require_contained_dir STAGE "$SANDBOX/link-out" "$REPO_ROOT"   # fine under the real repo root
rm -f "$SANDBOX/link-out"

sandbox_cleanup
t_summary
