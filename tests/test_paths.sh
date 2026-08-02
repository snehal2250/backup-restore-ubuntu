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

sandbox_cleanup
t_summary
