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

t_begin "static: schema v7 accepts valid user_dirs object form, rejects invalid"
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — user_dirs object-form checks skipped"
elif ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import jsonschema, yaml' >/dev/null 2>&1; then
  echo "  SKIP: python3 + jsonschema + yaml not available"
else
  sandbox_new
  cp "$REPO_ROOT/inventory/inventory.yaml" "$SANDBOX/inv.yaml"
  # Set schema_version 7 explicitly (the shipped inventory already is v7).
  yq -i '.schema_version = 7' "$SANDBOX/inv.yaml"
  # Valid: object form with path + exclude must be accepted.
  yq -i '.user_dirs = ["~/Documents", {"path": "~/.config/manicode/projects", "exclude": ["chats"]}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "valid user_dirs object form with exclude accepted"
  else
    t_fail "valid user_dirs object form with exclude was rejected"
  fi
  # Valid: object form without exclude must be accepted.
  yq -i '.user_dirs = ["~/Documents", {"path": "~/.config/manicode/projects"}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "valid user_dirs object form without exclude accepted"
  else
    t_fail "valid user_dirs object form without exclude was rejected"
  fi
  # Invalid: object form without path (missing required field).
  yq -i '.user_dirs = ["~/Documents", {"exclude": ["chats"]}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "user_dirs object without path was accepted"
  else
    t_pass "user_dirs object without path rejected"
  fi
  # Invalid: object form with extra unknown key.
  yq -i '.user_dirs = ["~/Documents", {"path": "~/.config/manicode/projects", "unknown": true}]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_fail "user_dirs object with unknown key was accepted"
  else
    t_pass "user_dirs object with unknown key rejected"
  fi
  # Valid: legacy plain strings still work.
  yq -i '.user_dirs = ["~/Documents", "~/.config/manicode/projects"]' "$SANDBOX/inv.yaml"
  if python3 "$REPO_ROOT/lib/schema_check.py" "$REPO_ROOT/inventory/schema.yaml" "$SANDBOX/inv.yaml" >/dev/null 2>&1; then
    t_pass "legacy plain string user_dirs still accepted"
  else
    t_fail "legacy plain string user_dirs was rejected"
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

t_begin "static: go entry pins a checksum (not the broken .sha256 sidecar)"
# Rehearsal finding (2026-08): go.dev's .sha256 sidecar URL serves an HTML
# error page, so checksum_url made the go install fail with a bogus checksum.
# The inventory must pin the tarball's sha256 directly (and stay in sync with
# the catalog template — a pinned checksum is version-specific: bump on bump).
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — go checksum guard skipped"
else
  _go_cs="$(yq -r '.apps[] | select(.name == "go") | .installer.checksum // ""' "$REPO_ROOT/inventory/inventory.yaml")"
  _go_csurl="$(yq -r '.apps[] | select(.name == "go") | .installer.checksum_url // ""' "$REPO_ROOT/inventory/inventory.yaml")"
  if [ -n "$_go_cs" ] && [ -z "$_go_csurl" ]; then
    t_pass "go entry pins installer.checksum (no checksum_url)"
  else
    t_fail "go entry must pin installer.checksum with no checksum_url (got checksum='$_go_cs' checksum_url='$_go_csurl')"
  fi
  # Parity guard: a catalog fix must not silently drift from the inventory.
  _cat_cs="$(bash -c 'source "'"$REPO_ROOT"'/lib/catalog.sh"; catalog_lookup go' | sed -n 's/^installer_checksum=//p' | tail -n1)"
  assert_eq "$_cat_cs" "$_go_cs" "go pinned checksum matches the catalog template"
fi

t_begin "static: _installer_npm_global makes the global npm tree user-readable"
# Rehearsal finding (2026-08): `sudo npm install -g` under a restrictive sudo
# umask (027) created /usr/local/lib/node_modules as 0750 root:root — the
# user-level `npm list -g` source check then failed and restore re-installed
# the app on every run. The installer must chmod the global root after install.
_npm_fn="$(sed -n '/^_installer_npm_global()/,/^}/p' "$REPO_ROOT/lib/installers.sh")"
if printf '%s\n' "$_npm_fn" | grep -q 'npm root -g' && printf '%s\n' "$_npm_fn" | grep -q 'chmod -R a+rX'; then
  t_pass "_installer_npm_global resolves + chmods the global npm root"
else
  t_fail "_installer_npm_global must chmod -R a+rX its \"npm root -g\" dir (rehearsal perms finding)"
fi

t_begin "static: _installer_tarball extracts under a sane umask"
# Rehearsal finding (2026-08): extraction under the restoring user's
# restrictive umask (007/027) masked archive modes to 0750, and the following
# `sudo chown root:root` left /usr/local/<app> unreadable by the user — same
# class of bug as the npm_global perms issue. The extract must run under 022.
_tar_fn="$(sed -n '/^_installer_tarball()/,/^}/p' "$REPO_ROOT/lib/installers.sh")"
if printf '%s\n' "$_tar_fn" | grep -q 'umask 022'; then
  t_pass "_installer_tarball extracts under umask 022"
else
  t_fail "_installer_tarball must extract under umask 022 (rehearsal perms finding)"
fi

t_begin "static: user_dir_paths/user_dir_exclude handle string + object forms"
# Rehearsal finding (2026-08-05): user_dir_paths used `if type == "object"`
# — a LEXER ERROR in mikefarah yq (type/tag cannot follow `if`), silently
# swallowed by `2>/dev/null || true`. user_dir_paths then returned EMPTY, so
# backup.sh never captured user dirs (the manifest had zero user-dirs
# artifacts), restore_user_dirs skipped them, and the overlap checks missed
# them. The helpers must resolve BOTH the legacy string form and the schema
# v7 object form (with exclude).
if ! command -v yq >/dev/null 2>&1; then
  echo "  SKIP: yq not installed — user_dir helper checks skipped"
else
  sandbox_new
  SBUD="$SANDBOX"
  mkdir -p "$SBUD/inventory"
  cp "$REPO_ROOT/inventory/schema.yaml" "$SBUD/inventory/schema.yaml"
  cat > "$SBUD/inventory/inventory.yaml" <<'YAML'
schema_version: 7
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs:
  - ~/Documents
  - path: ~/.config/manicode/projects
    exclude:
      - "chats"
apps: []
services: []
cron_jobs: []
YAML
  # shellcheck source=lib/common.sh
  source "$REPO_ROOT/lib/common.sh"
  INVENTORY_FILE="$SBUD/inventory/inventory.yaml"
  INVENTORY_READ="$INVENTORY_FILE"
  _ud_paths="$(user_dir_paths)"
  assert_eq "~/Documents ~/.config/manicode/projects" "$(printf '%s\n' "$_ud_paths" | tr '\n' ' ' | sed 's/ $//')" "user_dir_paths lists string + object entries in order"
  assert_eq "chats" "$(user_dir_exclude '~/.config/manicode/projects')" "user_dir_exclude returns the object form's exclude"
  _ud_excl_doc="$(user_dir_exclude '~/Documents')"
  assert_eq "" "$_ud_excl_doc" "user_dir_exclude returns nothing for a plain string entry"
  sandbox_cleanup
fi

t_begin "static: config-tree sync never propagates source dir metadata (restore_sync_tree)"
# Rehearsal finding (2026-08-05): `sudo rsync -a "$src/" /` propagated a
# share-staged tree's dmode=0770 + vboxsf group onto / and /etc, locking out
# every unprivileged daemon at boot. restore_config_tree must route its sync
# through restore_sync_tree, which runs rsync with --no-owner --no-group and
# re-asserts pre-existing destination dir modes.
_sync_fn="$(sed -n '/^restore_sync_tree()/,/^}/p' "$REPO_ROOT/lib/common.sh")"
if printf '%s\n' "$_sync_fn" | grep -q -- '--no-owner --no-group' && printf '%s\n' "$_sync_fn" | grep -q 'prot_dirs'; then
  t_pass "restore_sync_tree uses --no-owner --no-group + dir-mode protection"
else
  t_fail "restore_sync_tree must sync with --no-owner --no-group and re-assert dir modes (rehearsal perms finding)"
fi
_cfg_fn="$(sed -n '/^restore_config_tree()/,/^}/p' "$REPO_ROOT/restore.sh")"
if printf '%s\n' "$_cfg_fn" | grep -q 'restore_sync_tree'; then
  t_pass "restore_config_tree routes its rsync through restore_sync_tree"
else
  t_fail "restore_config_tree must call restore_sync_tree (a direct rsync -a would clobber dest dir attrs)"
fi

t_begin "static: empty source trees are skipped (never rewrite the dest root mode)"
# Round-8 rehearsal finding (2026-08-05): backup.sh created an EMPTY root/ dir
# for every app; restore unconditionally rsync'd it onto / with sudo, and
# rsync -a applies the source top-dir's mode to the dest root — a 0770
# vboxsf-staged tree rewrote / to 0770 and killed the boot (the restore died
# at app 2/25). Both restore_config_tree and restore_sync_tree must skip
# empty trees entirely.
_sync_fn2="$(sed -n '/^restore_sync_tree()/,/^}/p' "$REPO_ROOT/lib/common.sh")"
if printf '%s\n' "$_sync_fn2" | grep -q -- '-mindepth 1 -print -quit'; then
  t_pass "restore_sync_tree skips empty source trees"
else
  t_fail "restore_sync_tree must skip empty source trees (an empty root/ artifact must never touch the dest root mode)"
fi
_cfg_fn2="$(sed -n '/^restore_config_tree()/,/^}/p' "$REPO_ROOT/restore.sh")"
if printf '%s\n' "$_cfg_fn2" | grep -q -- '-mindepth 1 -print -quit'; then
  t_pass "restore_config_tree skips empty source trees"
else
  t_fail "restore_config_tree must skip empty source trees (legacy artifacts hold empty home//root/ dirs)"
fi

t_begin "static: sudo'd rsync + mode re-assertion run in ONE root shell"
# The round-8 failure chain: the rsync rewrites the dest root's mode DURING
# the copy (0770 /), so a later separate `sudo chmod 755 /` can no longer be
# forked by the user (traversal denied) and the re-assert never runs. The
# sudo'd path must run rsync AND the chmods inside one bash -c.
if printf '%s\n' "$_sync_fn2" | grep -q 'bash -c' && printf '%s\n' "$_sync_fn2" | grep -q 'sudo_a'; then
  t_pass "restore_sync_tree runs the sudo'd rsync + re-asserts in one bash -c"
else
  t_fail "restore_sync_tree must run the sudo'd rsync + mode re-assertion inside one root shell"
fi

t_begin "static: backup.sh creates home//root/ scope dirs per-path only"
# backup.sh must NOT pre-create an empty root/ dir for every app: restore
# maps root/ onto / with sudo, so even an empty tree would rsync onto / and
# rewrite its mode (round-8 rehearsal finding).
if grep -q 'mkdir -p "$dest/home" "$dest/root"' "$REPO_ROOT/backup.sh"; then
  t_fail "backup.sh must not create empty home//root/ dirs unconditionally (empty root/ -> restore rsyncs it onto /)"
else
  t_pass "backup.sh no longer pre-creates empty scope dirs"
fi
if grep -q 'mkdir -p "$sdest/home" "$sdest/root"' "$REPO_ROOT/backup.sh"; then
  t_fail "backup.sh services loop must not pre-create empty scope dirs either"
else
  t_pass "backup.sh services loop creates scope dirs per-path only"
fi

t_begin "static: a failed config sync marks EXIT_CONFIGS_MISSING (truthful exit codes)"
# Round-8 review finding: restore_sync_tree used to swallow rsync failures
# with `|| warn` and return 0, so restore_config_tree printed "[ OK ] config
# restored" and restore exited 0 for a config that was never applied
# (violates principle 9). The caller must mark_failure and skip the OK line.
_cfg_fn3="$(sed -n '/^restore_config_tree()/,/^}/p' "$REPO_ROOT/restore.sh")"
if printf '%s\n' "$_cfg_fn3" | grep -q 'mark_failure "$EXIT_CONFIGS_MISSING"'; then
  t_pass "restore_config_tree marks EXIT_CONFIGS_MISSING on a failed sync"
else
  t_fail "restore_config_tree must mark_failure EXIT_CONFIGS_MISSING when restore_sync_tree returns nonzero"
fi

t_begin "static: timer log lives OUTSIDE the transactional backups/ dir"
# Rehearsal finding (2026-08-06): the systemd timer service appended its log
# to $REPO_ROOT/backups/timer-backup.log, but publish_backup atomically swaps
# the WHOLE backups/ dir on every run (live -> backups.old.<pid> -> deleted
# after verification), sweeping the log away — the timer's own output vanished
# after every successful backup. The log must live outside backups/ (the
# established ~/.local/state/backup-restore-ubuntu state dir).
_sc_fn="$(sed -n '/^SERVICE_NAME=/,$p' "$REPO_ROOT/schedule_cron.sh")"
if printf '%s\n' "$_sc_fn" | grep -q 'TIMER_LOG=".*local/state/backup-restore-ubuntu/timer-backup.log"' \
   && ! printf '%s\n' "$_sc_fn" | grep -q 'backups/timer-backup.log'; then
  t_pass "schedule_cron.sh logs to ~/.local/state (outside the swapped backups/ dir)"
else
  t_fail "schedule_cron.sh must log to a path OUTSIDE backups/ (publish_backup swaps the whole dir and sweeps the log)"
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

t_begin "static: update_all_ubuntu.sh re-runs script/deb/tarball installers without prompting"
# Reported bug (2026-08): step 5/5 asked "re-run the script installer to update? [y/N]"
# but confirm()'s `read` consumed the `while ... done < <(yq ...)` stream instead of
# the terminal — it ate the NEXT inventory line as the answer ([WARN] Please answer
# y or n.), then hit EOF and died under set -e. The updater must not prompt at all:
# re-running the typed installer IS the update for these types.
if grep -q 'confirm' "$REPO_ROOT/update_all_ubuntu.sh"; then
  t_fail "update_all_ubuntu.sh must not prompt (script/deb/tarball installers are re-run directly — a prompt inside the yq loop eats the stream)"
else
  t_pass "update_all_ubuntu.sh is fully non-interactive"
fi

t_begin "static: confirm() reads the controlling terminal when stdin is redirected"
# Same root cause, fixed in the shared helper: prompts inside redirected loops
# (update_all's yq stream, inventory.sh wizard's scan_candidates stream) must read
# /dev/tty — plain `read` would consume the loop's data — and fall back to the
# default when no terminal exists (never hang, never die under set -e).
_confirm_fn="$(sed -n '/^confirm()/,/^}/p' "$REPO_ROOT/lib/common.sh")"
if printf '%s\n' "$_confirm_fn" | grep -q '/dev/tty' && printf '%s\n' "$_confirm_fn" | grep -q -- '-t 0'; then
  t_pass "confirm() reads /dev/tty when stdin is not a tty"
else
  t_fail "confirm() must read from /dev/tty when stdin is redirected (prompts otherwise eat the caller's loop stream)"
fi

t_summary
