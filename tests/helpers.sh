#!/bin/bash
# ---------------------------------------------------------------------------
# tests/helpers.sh — assertion + sandbox helpers for the automated test suite.
#
# Sourced by every tests/test_*.sh file. Tracks per-file pass/fail counters;
# each test file ends with `t_summary` (its exit code is the file's exit code,
# so tests/run.sh can aggregate results).
#
# Sandboxes are created under $REPO_ROOT/.test-tmp.* (git-ignored), NOT under
# /tmp: the snap-packaged yq cannot read /tmp, and helpers/scripts under test
# may legitimately point yq at a sandboxed inventory (see AGENTS.md).
# ---------------------------------------------------------------------------
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# t_begin NAME — start a named test case (printed with every assertion).
t_begin() { CURRENT_TEST="$1"; }

t_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  PASS  %s: %s\n' "$CURRENT_TEST" "$1"; }

t_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  FAIL  %s: %s\n' "$CURRENT_TEST" "$1" >&2
}

# assert_ok CMD... — command must exit 0.
assert_ok() {
  if "$@"; then
    t_pass "$*"
  else
    t_fail "expected success, got exit $?: $*"
  fi
}

# assert_fail CMD... — command must exit non-zero.
assert_fail() {
  if "$@"; then
    t_fail "expected failure: $*"
  else
    t_pass "$* (failed as expected)"
  fi
}

# assert_eq EXPECTED ACTUAL LABEL
assert_eq() {
  local expected="$1" actual="$2" label="${3:-eq}"
  if [ "$expected" = "$actual" ]; then
    t_pass "$label (='$expected')"
  else
    t_fail "$label: expected '$expected', got '$actual'"
  fi
}

# assert_file_exists FILE LABEL
assert_file_exists() {
  if [ -e "$1" ]; then
    t_pass "${2:-file exists}: $1"
  else
    t_fail "${2:-file exists}: $1"
  fi
}

# assert_not_exists FILE LABEL
assert_not_exists() {
  if [ -e "$1" ]; then
    t_fail "${2:-file absent}: $1"
  else
    t_pass "${2:-file absent}: $1"
  fi
}

# assert_contains NEEDLE FILE — file must contain the literal needle.
assert_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    t_pass "contains '$needle' in $(basename "$file")"
  else
    t_fail "expected '$needle' in $(basename "$file")"
  fi
}

# assert_not_contains NEEDLE FILE
assert_not_contains() {
  local needle="$1" file="$2"
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    t_fail "unexpected '$needle' in $(basename "$file")"
  else
    t_pass "no '$needle' in $(basename "$file")"
  fi
}

# assert_str_contains NEEDLE STRING LABEL — grep a multi-line string (e.g.
# captured command output), not a file.
assert_str_contains() {
  local needle="$1" str="$2" label="${3:-str contains}"
  if printf '%s\n' "$str" | grep -qF -- "$needle"; then
    t_pass "$label (contains '$needle')"
  else
    t_fail "$label: expected '$needle'"
  fi
}

# --- Sandbox ---------------------------------------------------------------
SANDBOX=""

# sandbox_new — create a fresh git-ignored scratch dir under the repo root and
# set the SANDBOX global (call it, then read $SANDBOX — do NOT capture the
# output of the function, the global must be set in this shell).
sandbox_new() {
  SANDBOX="$(mktemp -d "$REPO_ROOT/.test-tmp.XXXXXX")"
  chmod 700 "$SANDBOX"
  printf 'sandbox: %s\n' "$SANDBOX" >&2
}

sandbox_cleanup() {
  if [ -n "$SANDBOX" ] && [ -d "$SANDBOX" ]; then
    rm -rf "$SANDBOX"
  fi
  SANDBOX=""
}

# Always clean the sandbox, even if a test file dies early under set -e.
# sandbox_cleanup is idempotent (SANDBOX empty after the first run), so the
# explicit end-of-file cleanup stays harmless.
trap sandbox_cleanup EXIT

# --- Summary ---------------------------------------------------------------
# t_summary — print the tally; exit code is the caller's verdict (0 = all green).
t_summary() {
  echo
  if [ "$TESTS_FAILED" -gt 0 ]; then
    printf 'FAIL: %d/%d assertions failed\n' "$TESTS_FAILED" "$TESTS_RUN"
    return 1
  fi
  printf 'OK: all %d assertions passed\n' "$TESTS_RUN"
  return 0
}
