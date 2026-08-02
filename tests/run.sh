#!/bin/bash
# ---------------------------------------------------------------------------
# tests/run.sh — run the whole automated test suite.
#
#   ./tests/run.sh            # run everything, aggregate the results
#   bash tests/test_x.sh      # run one file standalone
#
# Each tests/test_*.sh file is self-contained (sources helpers.sh, runs its
# assertions, ends with t_summary). run.sh only orchestrates: run each file,
# count the failures, exit non-zero if any file failed.
# ---------------------------------------------------------------------------
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

TOTAL_FAIL=0
FILE_COUNT=0

for t in "$TEST_DIR"/test_*.sh; do
  [ -f "$t" ] || continue
  FILE_COUNT=$((FILE_COUNT + 1))
  echo "=== $(basename "$t") ==="
  if bash "$t"; then
    echo ">>> $(basename "$t"): ok"
  else
    echo ">>> $(basename "$t"): FAILED" >&2
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  echo
done

echo "=================================================="
if [ "$FILE_COUNT" -eq 0 ]; then
  echo "No test files found in tests/ (expected tests/test_*.sh)"
  exit 1
fi
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "SUITE FAILED: $TOTAL_FAIL/$FILE_COUNT test files failed"
  exit 1
fi
echo "SUITE OK: $FILE_COUNT/$FILE_COUNT test files passed"
