#!/bin/bash
# ---------------------------------------------------------------------------
# test_static.sh — repository-wide static checks:
#   * bash -n on every production script and the test suite itself
#   * no `rsync --delete` anywhere in backup.sh/restore.sh/lib — REGRESSION
#     guard for the critical conflict-policy bug (replace used to run
#     rsync --delete against $HOME or /, which would wipe unrelated data)
#   * the real inventory validates against inventory/schema.yaml
#   * schema v3 rejects invalid conflict_policy values (and accepts valid ones)
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

# --- 1. Syntax --------------------------------------------------------------
t_begin "static: bash -n on every production script + test file"
_prod_scripts=(
  backup.sh restore.sh inventory.sh schedule_cron.sh update_all_ubuntu.sh
  lib/common.sh lib/installers.sh lib/catalog.sh
  tests/run.sh tests/helpers.sh
)
# shellcheck disable=SC2207  # intentional word-split glob
_prod_scripts+=("$REPO_ROOT"/tests/test_*.sh)
for f in "${_prod_scripts[@]}"; do
  if bash -n "$f" 2>/dev/null; then
    t_pass "bash -n $f"
  else
    t_fail "bash -n $f"
  fi
done

# --- 2. Critical-bug regression guard ---------------------------------------
t_begin "static: no actual rsync --delete command anywhere in production scripts"
# restore.sh must NEVER mirror the backup tree with --delete against a restore
# target root — only exact leaf counterparts may be removed (conflict_policy
# replace). Comments may mention the anti-pattern; only real command lines
# count. grep output is path:line:content; strip lines whose content is a
# comment (optional whitespace then #).
# LIMITATION: this is line-local — a regression hiding --delete in an array
# (e.g. extra=(--delete); run rsync -a "${extra[@]}") would evade it. The
# production code never builds such an array; if it ever does, extend the
# guard to scan array definitions too.
if grep -rEn -- 'rsync[^|]*--delete|--delete[^|]*rsync' \
    "$REPO_ROOT/backup.sh" "$REPO_ROOT/restore.sh" "$REPO_ROOT/lib/" 2>/dev/null \
  | grep -vE ':[0-9]+:[[:space:]]*#'; then
  t_fail "found an actual rsync --delete invocation in production scripts (critical-bug regression!)"
else
  t_pass "no rsync --delete invocations in backup.sh/restore.sh/lib"
fi

# --- 3. Real inventory validates --------------------------------------------
t_begin "static: inventory.yaml validates against schema.yaml"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  if python3 "$REPO_ROOT/lib/schema_check.py" \
      "$REPO_ROOT/inventory/schema.yaml" "$REPO_ROOT/inventory/inventory.yaml" >/dev/null 2>&1; then
    t_pass "schema_check.py accepted inventory.yaml"
  else
    t_fail "schema_check.py rejected inventory.yaml"
  fi
fi

# --- 4. conflict_policy schema variants --------------------------------------
t_begin "static: schema v4 accepts valid conflict_policy values, rejects invalid"
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — policy-variant checks skipped"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # Valid values must pass.
  yq -i '.apps[0].conflict_policy = "replace" | .apps[1].conflict_policy = "skip-existing" | .apps[2].conflict_policy = "prompt"' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "valid policies accepted"
  else
    t_fail "valid policies were rejected"
  fi
  # Invalid values must be rejected.
  yq -i '.apps[0].conflict_policy = "blowup"' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "invalid policy 'blowup' was accepted"
  else
    t_pass "invalid policy rejected"
  fi
  sandbox_cleanup
fi

t_begin "static: schema v4 accepts required/on_missing, rejects invalid values"
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — completeness-variant checks skipped"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # Valid values must pass.
  yq -i '.apps[0].required = true | .apps[1].on_missing = "fail" | .services[0].required = true' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "valid required/on_missing accepted"
  else
    t_fail "valid required/on_missing were rejected"
  fi
  # Invalid enum value must be rejected.
  yq -i '.apps[0].on_missing = "bogus"' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "invalid on_missing 'bogus' was accepted"
  else
    t_pass "invalid on_missing rejected"
  fi
  # Invalid type (string instead of boolean) must be rejected.
  yq -i '.apps[0].on_missing = "warn" | .apps[0].required = "maybe"' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "invalid required type (string) was accepted"
  else
    t_pass "invalid required type rejected"
  fi
  sandbox_cleanup
fi

t_begin "static: schema v3 inventories still validate during the v4 transition"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # schema_version 3 (pre-v4) must remain valid — every v4 change is optional.
  yq -i '.schema_version = 3' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "schema_version 3 accepted (v4 transition)"
  else
    t_fail "schema_version 3 was rejected (v4 should accept 3 during the transition)"
  fi
  # Unknown versions must still be rejected.
  yq -i '.schema_version = 5' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "schema_version 5 was accepted"
  else
    t_pass "schema_version 5 rejected"
  fi
  sandbox_cleanup
fi

t_summary
