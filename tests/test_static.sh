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

t_begin "static: schema v3-v7 inventories all validate (v7 transition), unknown rejected"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # schema_version 3-6 must remain valid — every v7 change is optional
  # (user_dirs objects with exclude are opt-in).
  for _v in 3 4 5 6 7; do
    yq -i ".schema_version = $_v" "$SANDBOX/inv.yaml"
    if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
      t_pass "schema_version $_v accepted (v7 transition)"
    else
      t_fail "schema_version $_v was rejected (should stay valid during the transition)"
    fi
  done
  # Unknown versions must still be rejected.
  yq -i '.schema_version = 8' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "schema_version 8 was accepted"
  else
    t_pass "schema_version 8 rejected"
  fi
  sandbox_cleanup
fi

t_begin "static: schema v6 accepts valid cron_jobs, rejects invalid entries"
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — cron_jobs schema checks skipped"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # Valid: one user crontab + one cron.d file (file defaults are legal too).
  yq -i '.cron_jobs = [{"name": "user-crontab", "source": "user"}, {"name": "custom-daily", "source": "cron.d", "file": "custom-daily"}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "valid cron_jobs accepted"
  else
    t_fail "valid cron_jobs were rejected"
  fi
  # Invalid: cron.d without file.
  yq -i '.cron_jobs = [{"name": "x", "source": "cron.d"}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "cron.d without file was accepted"
  else
    t_pass "cron.d without file rejected"
  fi
  # Invalid: dotted file name (Debian cron ignores dotted /etc/cron.d names).
  yq -i '.cron_jobs = [{"name": "x", "source": "cron.d", "file": "bad.name"}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "dotted cron.d file name was accepted"
  else
    t_pass "dotted cron.d file name rejected"
  fi
  # Invalid: file on a source: user entry.
  yq -i '.cron_jobs = [{"name": "x", "source": "user", "file": "nope"}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "file on a source:user entry was accepted"
  else
    t_pass "file on a source:user entry rejected"
  fi
  sandbox_cleanup
fi

t_begin "static: declared support matrix is Ubuntu + amd64 only"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
assert_eq "amd64" "$SUPPORTED_ARCHS" "arch matrix is amd64-only"
# The runtime gate (check_system_support) is HOST-dependent: on a
# non-Ubuntu/non-amd64 machine it would (correctly) fail and break the whole
# suite for contributors who can't run on the target platform. The constant
# above already locks the matrix — exercise the runtime gate only when this
# host can actually pass it.
if [ "$ARCH_NORM" = "amd64" ] && grep -q '^ID=ubuntu$' /etc/os-release 2>/dev/null; then
  assert_ok check_system_support   # must pass on this host (Ubuntu, amd64)
else
  echo "  SKIP  $CURRENT_TEST: host is not Ubuntu/amd64 (arch=$ARCH_NORM) — runtime gate not exercised here"
fi

t_summary
