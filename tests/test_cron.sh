#!/bin/bash
# ---------------------------------------------------------------------------
# test_cron.sh — systemd TIMER pairing + CRON JOB backup/restore (schema v6):
#
#   * validate_inventory semantic checks: duplicate cron job names, more than
#     one source: user entry, and the timer-pairing hint (.timer without its
#     paired .service warns but does NOT fail validation).
#   * REAL backup.sh captures the user crontab (mocked `crontab` command) and
#     a /etc/cron.d file (CRON_D_DIR override) into backups/cron/<name> with
#     the correct artifact status: captured / empty / missing / failed.
#   * REAL restore.sh --source restores both sources with rollback capture +
#     journal (mocked crontab/sudo/systemctl/rsync/dpkg so nothing on the real
#     system is touched — every path override is guarded by
#     BRU_ALLOW_TEST_OVERRIDES=1, exported by helpers.sh).
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"

ORIG_REPO="$REPO_ROOT"

if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — cron tests skipped"
  t_summary
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available — schema/semantic tests skipped"
  NO_PYTHON=1
else
  NO_PYTHON=0
fi

sandbox_new
SB="$SANDBOX"

# --- Sandbox layout + mocked system commands -------------------------------
mkdir -p "$SB/inventory" "$SB/home" "$SB/cron.d" "$SB/bin"
cp "$ORIG_REPO/inventory/schema.yaml" "$SB/inventory/schema.yaml"

export HOME="$SB/home"
mkdir -p "$HOME/.config/good-app"
printf 'x\n' > "$HOME/.config/good-app/settings.json"

export REPO_ROOT="$SB"
export INVENTORY_FILE="$SB/inventory/inventory.yaml"
export BACKUP_DEST=""          # mirror disabled -> ok_with_warnings when all captured
export CRON_D_DIR="$SB/cron.d"

# Mock crontab: FAKE_CRONTAB_FILE holds the crontab; -l lists, anything else
# (a file path) installs. No real /var/spool/cron is ever touched.
cat > "$SB/bin/crontab" <<'MOCK'
#!/bin/bash
if [ "$1" = "-l" ]; then
  if [ -f "$FAKE_CRONTAB_FILE" ]; then cat "$FAKE_CRONTAB_FILE"; else
    echo "no crontab for $USER" >&2; exit 1; fi
else
  cp "$1" "$FAKE_CRONTAB_FILE"
fi
MOCK
# Mock sudo: run the command directly — sandbox paths only.
printf '#!/bin/bash\nexec "$@"\n' > "$SB/bin/sudo"
# Mock systemctl: cron reports active; everything else is a harmless no-op.
cat > "$SB/bin/systemctl" <<'MOCK'
#!/bin/bash
case "$1 $2" in
  "is-active cron") exit 0 ;;
esac
exit 0
MOCK
# Mock rsync (restore preflight + config-tree restore; not exercised deeply).
printf '#!/bin/bash\nexit 0\n' > "$SB/bin/rsync"
# Mock dpkg/dpkg-query: claim every package is installed (cron included).
cat > "$SB/bin/dpkg" <<'MOCK'
#!/bin/bash
if [ "$1" = "-s" ]; then echo "Status: install ok installed"; fi
exit 0
MOCK
# The real dpkg-query -f='${Status}' output starts with a leading space —
# is_apt_installed greps for ' install ok installed' exactly.
printf '#!/bin/bash\necho " install ok installed"\n' > "$SB/bin/dpkg-query"
chmod +x "$SB/bin"/*
export PATH="$SB/bin:$PATH"
export FAKE_CRONTAB_FILE="$SB/fake-crontab"

MF="$SB/backups/backup-info.txt"

run_backup() { # label
  if bash "$ORIG_REPO/backup.sh" > "$SB/backup.log" 2>&1; then
    t_pass "backup.sh ran ($1)"
  else
    t_fail "backup.sh failed ($1) — see $SB/backup.log"
  fi
}

reset_backup_state() { rm -rf "$SB/backups"; }

write_inventory() {
  cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 6
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: good-app
    installer: { type: apt }
    config_paths: ["~/.config/good-app"]
services: []
cron_jobs:
  - name: user-crontab
    source: user
  - name: custom-daily
    source: cron.d
    file: custom-daily
YAML
}

# --- Semantic validation ----------------------------------------------------
if [ "$NO_PYTHON" = "0" ]; then
  t_begin "semantic: duplicate cron job names fail validation"
  write_inventory
  yq -i '.cron_jobs += [{"name": "user-crontab", "source": "cron.d", "file": "dup"}]' "$INVENTORY_FILE"
  if ( validate_inventory ) >/dev/null 2>&1; then
    t_fail "duplicate cron job name was accepted"
  else
    t_pass "duplicate cron job name rejected"
  fi

  t_begin "semantic: more than one source:user cron job fails validation"
  write_inventory
  yq -i '.cron_jobs += [{"name": "second-crontab", "source": "user"}]' "$INVENTORY_FILE"
  if ( validate_inventory ) >/dev/null 2>&1; then
    t_fail "two source:user entries were accepted"
  else
    t_pass "two source:user entries rejected"
  fi

  t_begin "semantic: .timer without its paired .service warns but still validates"
  write_inventory
  yq -i '.services = [{"unit": "foo.timer", "target": "user"}]' "$INVENTORY_FILE"
  _tout="$(validate_inventory 2>&1)" || {
    t_fail "timer pairing should warn, not fail validation"
    printf '%s\n' "$_tout"
  }
  if printf '%s\n' "$_tout" | grep -q "paired unit 'foo.service'"; then
    t_pass "timer-pairing warning mentions the missing paired unit"
  else
    t_fail "timer-pairing warning missing — got: $_tout"
  fi

  t_begin "semantic: .timer with its paired .service declared warns nothing"
  write_inventory
  yq -i '.services = [{"unit": "foo.timer", "target": "user"}, {"unit": "foo.service", "target": "user"}]' "$INVENTORY_FILE"
  _tout="$(validate_inventory 2>&1)" || {
    t_fail "valid timer+service pair failed validation"
    printf '%s\n' "$_tout"
  }
  if printf '%s\n' "$_tout" | grep -q "paired unit"; then
    t_fail "pairing warning emitted for a complete pair: $_tout"
  else
    t_pass "complete timer+service pair validates clean"
  fi

  # --- inventory.sh add-cron/remove-cron on a LEGACY v5 inventory -----------
  # cron_jobs is OPTIONAL (schema v6) — a v5 inventory without the key must
  # stay valid, and the wizard must create the key on first use.
  t_begin "cron: add-cron/remove-cron work on a legacy v5 inventory without cron_jobs"
  cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps: []
services: []
YAML
  # Legacy inventory (no cron_jobs key) must validate as-is.
  if python3 "$ORIG_REPO/lib/schema_check.py" "$SB/inventory/schema.yaml" "$INVENTORY_FILE" >/dev/null 2>&1; then
    t_pass "legacy v5 inventory without cron_jobs validates"
  else
    t_fail "legacy v5 inventory without cron_jobs was rejected"
  fi
  # add-cron wizard (source 2 = cron.d, then identifier + file name).
  if printf '2\nmy-daily\nmy-daily\n' | bash "$ORIG_REPO/inventory.sh" add-cron > "$SB/addcron.log" 2>&1; then
    t_pass "add-cron wizard ran on the legacy inventory"
  else
    t_fail "add-cron failed on the legacy inventory — see $SB/addcron.log"
  fi
  assert_contains "my-daily" "$INVENTORY_FILE"
  # The result must still validate (v5 + cron_jobs is legal in v6 schema).
  if bash "$ORIG_REPO/inventory.sh" validate >/dev/null 2>&1; then
    t_pass "inventory validates after add-cron on legacy v5"
  else
    t_fail "inventory failed validation after add-cron"
  fi
  # remove-cron must remove it again.
  if bash "$ORIG_REPO/inventory.sh" remove-cron my-daily >/dev/null 2>&1; then
    t_pass "remove-cron ran"
  else
    t_fail "remove-cron failed"
  fi
  assert_not_contains "my-daily" "$INVENTORY_FILE"
fi

# --- backup.sh: capture user crontab + cron.d file --------------------------
reset_backup_state
write_inventory
printf '0 3 * * * echo backup-hi\n' > "$FAKE_CRONTAB_FILE"
printf '0 4 * * * root echo custom-daily\n' > "$CRON_D_DIR/custom-daily"

t_begin "cron: backup captures user crontab + cron.d file as captured"
run_backup "cron captured"
assert_contains "cron/user-crontab/captured" "$MF"
assert_contains "cron/custom-daily/captured" "$MF"
assert_contains "status: ok_with_warnings" "$MF"   # mirror disabled, nothing missing
assert_file_exists "$SB/backups/cron/user-crontab" "crontab artifact"
assert_file_exists "$SB/backups/cron/custom-daily" "cron.d artifact"
assert_contains "backup-hi" "$SB/backups/cron/user-crontab"

# --- backup.sh: empty crontab -> empty artifact -----------------------------
reset_backup_state
: > "$FAKE_CRONTAB_FILE"
t_begin "cron: empty user crontab -> empty artifact (informational, not a failure)"
run_backup "empty crontab"
assert_contains "cron/user-crontab/empty" "$MF"
assert_contains "cron/custom-daily/captured" "$MF"
assert_contains "status: ok_with_warnings" "$MF"
assert_not_contains "cron/user-crontab/missing" "$MF"

# --- backup.sh: no crontab -> missing -> degraded ---------------------------
reset_backup_state
rm -f "$FAKE_CRONTAB_FILE"
t_begin "cron: no crontab -> missing artifact -> degraded status"
run_backup "missing crontab"
assert_contains "cron/user-crontab/missing" "$MF"
assert_contains "status: degraded" "$MF"

# --- backup.sh: on_missing: fail -> failed artifact -> failed status --------
reset_backup_state
yq -i '.cron_jobs[0].on_missing = "fail"' "$INVENTORY_FILE"
t_begin "cron: on_missing fail + no crontab -> failed artifact -> failed status"
run_backup "strict cron missing"
assert_contains "cron/user-crontab/failed" "$MF"
assert_contains "status: failed" "$MF"
assert_contains "failures: 1" "$MF"

# --- restore.sh --source: restore crontab + cron.d with rollback+journal ----
reset_backup_state
yq -i 'del(.cron_jobs[0].on_missing)' "$INVENTORY_FILE"
printf '0 3 * * * echo backup-hi\n# second line\n' > "$FAKE_CRONTAB_FILE"
printf '0 4 * * * root echo custom-daily\n' > "$CRON_D_DIR/custom-daily"
run_backup "pre-restore backup"
# Disturb the destinations so restore actually overwrites something.
printf 'OLD crontab line\n' > "$FAKE_CRONTAB_FILE"
printf '0 5 * * * root echo OLD\n' > "$CRON_D_DIR/custom-daily"

t_begin "cron: restore.sh --source restores crontab + cron.d with rollback/journal"
if [ "$NO_PYTHON" = "1" ]; then
  echo "  SKIP: python3 + jsonschema not available — restore run skipped"
else
  if bash "$ORIG_REPO/restore.sh" --source "$SB/backups" --yes --configs-only > "$SB/restore.log" 2>&1; then
    t_pass "restore.sh ran (exit 0)"
  else
    t_fail "restore.sh failed — see $SB/restore.log"
  fi
  assert_contains "backup-hi" "$FAKE_CRONTAB_FILE"      # crontab replaced from backup
  assert_contains "custom-daily" "$CRON_D_DIR/custom-daily"  # cron.d replaced from backup
  assert_not_contains "OLD" "$FAKE_CRONTAB_FILE"
  _journal="$(ls "$HOME"/.local/state/backup-restore-ubuntu/rollback-*/restore-journal.log 2>/dev/null | head -1 || true)"
  if [ -n "$_journal" ]; then
    assert_contains "cron/user-crontab" "$_journal"
    assert_contains "cron/custom-daily" "$_journal"
  else
    t_fail "no rollback journal was written"
  fi
fi

# --- restore.sh --source refuses a failed cron snapshot ----------------------
t_begin "cron: restore refuses a failed snapshot (on_missing fail, missing crontab)"
reset_backup_state
yq -i '.cron_jobs[0].on_missing = "fail"' "$INVENTORY_FILE"
rm -f "$FAKE_CRONTAB_FILE"
run_backup "strict missing for refusal test"
assert_contains "status: failed" "$MF"
if bash "$ORIG_REPO/restore.sh" --source "$SB/backups" --dry-run --yes > "$SB/restore2.log" 2>&1; then
  t_fail "restore.sh should have refused the failed snapshot"
else
  t_pass "restore.sh refused the failed snapshot (exit nonzero)"
fi

sandbox_cleanup
t_summary
