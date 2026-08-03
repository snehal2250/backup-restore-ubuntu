#!/bin/bash
# ---------------------------------------------------------------------------
# test_catalog.sh — catalog references (schema v5). Covers:
#
#   * resolve_effective_inventory (lib/common.sh): the template * overrides
#     merge — scalar/map overrides land, array fields APPEND to the template's
#     list (deduped), installer sub-map overrides keep the rest of the
#     template's installer, non-catalog apps pass through, the no-refs fast
#     path keeps INVENTORY_READ at the raw file, and an unknown catalog key
#     dies with a clear message.
#   * the schema's appReference form: reference + full records both validate,
#     an entry with BOTH `catalog` and `installer` matches neither oneOf arm.
#   * a sandboxed REAL backup.sh run against a catalog-referenced app — the
#     config is captured from the RESOLVED path and the manifest reports a
#     captured artifact (the end-to-end proof that references work).
#
# Sandboxing mirrors test_backup_completeness.sh: REPO_ROOT/INVENTORY_FILE/
# BACKUPS_DIR (and backup.sh's STAGE/ARTIFACTS/lock) are env-overridable under
# BRU_ALLOW_TEST_OVERRIDES=1, HOME points at the sandbox, BACKUP_DEST=''
# disables the mirror. Nothing outside the git-ignored sandbox is touched.
# ---------------------------------------------------------------------------
set -euo pipefail

# shellcheck source=tests/helpers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers.sh"

ORIG_REPO="$REPO_ROOT"
sandbox_new
SB="$SANDBOX"
# Sandbox the resolver's scratch space BEFORE sourcing common.sh: the unit
# tests below call resolve_effective_inventory repeatedly, and it writes its
# effective-inventory dirs next to the repo (snap-packaged yq cannot read
# /tmp). Pointing REPO_ROOT/INVENTORY_FILE at the sandbox here keeps every
# .inventory-resolve.* dir inside $SB (removed by sandbox_cleanup) instead of
# leaking into the real repo root. ORIG_REPO keeps the real paths for the
# schema-check and backup.sh sections below.
REPO_ROOT="$SB"
INVENTORY_FILE="$SB/inv.yml"

# --- Resolver unit tests (source common.sh in this shell) ------------------
# shellcheck source=lib/common.sh
source "$ORIG_REPO/lib/common.sh"

cat > "$SB/inv-ref.yml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: gh
    catalog: gh
    overrides:
      config_paths:
        - ~/.config/gh-extra
      required: true
  - name: tmux
    description: Terminal multiplexer
    installer: { type: apt }
    check_cmd: tmux
    config_paths: ["~/.tmux.conf"]
services: []
YAML

t_begin "catalog resolver: no-refs fast path keeps INVENTORY_READ at the raw file"
cat > "$SB/inv-plain.yml" <<'YAML'
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
INVENTORY_FILE="$SB/inv-plain.yml"
INVENTORY_READ=""
EFFECTIVE_INVENTORY="stale"
resolve_effective_inventory
assert_eq "$INVENTORY_FILE" "$INVENTORY_READ" "no-refs: INVENTORY_READ == raw"
assert_eq "" "$EFFECTIVE_INVENTORY" "no-refs: EFFECTIVE_INVENTORY reset to empty"

t_begin "catalog resolver: template * overrides merge (scalar + array append+dedupe)"
INVENTORY_FILE="$SB/inv-ref.yml"
resolve_effective_inventory
if [ -n "$EFFECTIVE_INVENTORY" ] && [ -f "$EFFECTIVE_INVENTORY" ]; then
  t_pass "effective file written"
else
  t_fail "effective file missing"
fi
assert_eq "apt_repository" "$(app_get gh '.installer.type')" "gh installer.type from template"
assert_eq "https://cli.github.com/packages" "$(app_get gh '.installer.url')" "gh installer.url from template"
assert_eq "2" "$(app_get gh '.config_paths | length')" "gh config_paths appended (template + override), deduped"
_gh_paths="$(app_get gh '.config_paths[]?')"
assert_str_contains "~/.config/gh" "$_gh_paths" "gh template path present"
assert_str_contains "~/.config/gh-extra" "$_gh_paths" "gh override path present"
assert_eq "true" "$(app_get gh '.required')" "gh override required=true landed"
assert_eq "apt" "$(app_get tmux '.installer.type')" "non-catalog app passes through"
assert_eq "~/.tmux.conf" "$(app_get tmux '.config_paths[0]')" "non-catalog app path unchanged"

t_begin "catalog resolver: installer sub-map override keeps the rest of the template installer"
cat > "$SB/inv-ovr.yml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: gh
    catalog: gh
    overrides:
      installer:
        url: https://example.invalid/packages
services: []
YAML
INVENTORY_FILE="$SB/inv-ovr.yml"
resolve_effective_inventory
assert_eq "apt_repository" "$(app_get gh '.installer.type')" "installer sub-map override keeps type"
assert_eq "https://example.invalid/packages" "$(app_get gh '.installer.url')" "installer sub-map override replaces url"
assert_eq "gh" "$(app_get gh '.installer.packages[0]')" "installer array preserved when not overridden"

t_begin "catalog resolver: unknown catalog key dies with a clear message"
cat > "$SB/inv-bad.yml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: bogus
    catalog: no-such-key
services: []
YAML
INVENTORY_FILE="$SB/inv-bad.yml"
set +e
out="$(resolve_effective_inventory 2>&1)"
rc=$?
set -e
if [ "$rc" = "0" ]; then
  t_fail "expected a die on the unknown catalog key"
else
  t_pass "unknown catalog key dies (exit $rc)"
fi
assert_str_contains "unknown catalog key" "$out" "die message names the key"

t_begin "catalog resolver: stale effective dirs from dead processes are swept, own dir kept"
# A dir whose owner pid is dead (or unparseable/legacy) must be removed by
# the next resolution; the current process's own dir must be created and
# tracked (pid-scoped) so concurrent runs can never delete each other's file.
INVENTORY_FILE="$SB/inv-ref.yml"
mkdir -p "$SB/.inventory-resolve.999999999.stale"   # dead pid -> swept
mkdir -p "$SB/.inventory-resolve.legacy"            # legacy (no pid) -> swept
resolve_effective_inventory
if [ -e "$SB/.inventory-resolve.999999999.stale" ] || [ -e "$SB/.inventory-resolve.legacy" ]; then
  t_fail "stale/legacy effective dirs were not swept"
else
  t_pass "stale (dead pid) and legacy effective dirs swept"
fi
if [ -n "${BRU_EFFECTIVE_DIR:-}" ] && [ -d "$BRU_EFFECTIVE_DIR" ] && [ -f "$BRU_EFFECTIVE_DIR/effective.yml" ]; then
  t_pass "own effective dir created and tracked"
else
  t_fail "own effective dir missing after resolve"
fi
case "$(basename "$BRU_EFFECTIVE_DIR")" in
  ".inventory-resolve.$$."*) t_pass "own dir is pid-scoped" ;;
  *) t_fail "own dir not pid-scoped: $(basename "$BRU_EFFECTIVE_DIR")" ;;
esac

t_begin "catalog resolver: array append dedupes preserving template order"
# yq's `unique` (mikefarah) preserves FIRST-SEEN order — it does NOT sort
# like jq's. Template git has [~/.gitconfig, ~/.config/git]; the override
# adds a duplicate and a new path. A sorted dedupe would put ~/.config/git
# first; the order-preserving one keeps template order and appends.
cat > "$SB/inv-order.yml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: git
    catalog: git
    overrides:
      config_paths:
        - ~/.config/git
        - ~/.zzz
services: []
YAML
INVENTORY_FILE="$SB/inv-order.yml"
resolve_effective_inventory
assert_eq "3" "$(app_get git '.config_paths | length')" "template 2 + override 2 -> 3 unique paths"
assert_eq "~/.gitconfig" "$(app_get git '.config_paths[0]')" "template order preserved (first)"
assert_eq "~/.config/git" "$(app_get git '.config_paths[1]')" "template order preserved (second)"
assert_eq "~/.zzz" "$(app_get git '.config_paths[2]')" "override addition appended after template items"

# --- Schema v5: reference form valid, catalog+installer mix invalid ---------
t_begin "schema v5: reference and full records validate; catalog+installer mix fails oneOf"
if python3 "$ORIG_REPO/lib/schema_check.py" "$ORIG_REPO/inventory/schema.yaml" "$SB/inv-ref.yml" >/dev/null 2>&1; then
  t_pass "catalog-reference inventory validates"
else
  t_fail "catalog-reference inventory should validate"
fi
cat > "$SB/inv-mix.yml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: gh
    catalog: gh
    installer: { type: apt }
services: []
YAML
if python3 "$ORIG_REPO/lib/schema_check.py" "$ORIG_REPO/inventory/schema.yaml" "$SB/inv-mix.yml" >/dev/null 2>&1; then
  t_fail "catalog + installer in one entry should fail oneOf"
else
  t_pass "catalog + installer mix rejected"
fi

# --- Sandboxed REAL backup.sh against a catalog-referenced app --------------
mkdir -p "$SB/inventory"
cp "$ORIG_REPO/inventory/schema.yaml" "$SB/inventory/schema.yaml"

export HOME="$SB/home"
mkdir -p "$HOME/.config/gh"
printf 'x\n' > "$HOME/.config/gh/settings.json"

export REPO_ROOT="$SB"
export INVENTORY_FILE="$SB/inventory/inventory.yaml"
export BACKUP_DEST=""          # mirror disabled -> ok_with_warnings when all captured
unset INVENTORY_READ EFFECTIVE_INVENTORY

cat > "$INVENTORY_FILE" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: gh
    catalog: gh
services: []
YAML

MF="$SB/backups/backup-info.txt"

t_begin "catalog: real backup.sh captures a catalog-referenced app's RESOLVED config"
if bash "$ORIG_REPO/backup.sh" > "$SB/backup.log" 2>&1; then
  t_pass "backup.sh ran with a catalog-referenced app"
else
  t_fail "backup.sh failed — see $SB/backup.log"
fi
assert_contains "status: ok_with_warnings" "$MF"
assert_contains "apps/gh/captured" "$MF"
assert_not_contains "apps/gh/empty" "$MF"
assert_file_exists "$SB/backups/apps/gh/home/.config/gh/settings.json" "catalog-ref app config captured from resolved path"
assert_contains "inventory_sha256" "$MF"

t_begin "catalog: inventory.sh list shows the resolved record + catalog tag"
if ( export HOME="$SB/home"; bash "$ORIG_REPO/inventory.sh" list ) > "$SB/list.log" 2>&1; then
  t_pass "inventory.sh list ran against the catalog-ref inventory"
else
  t_fail "inventory.sh list failed — see $SB/list.log"
fi
assert_contains "catalog=gh" "$SB/list.log"
assert_contains "apt_repository" "$SB/list.log"

t_begin "catalog: review --drift separates intentional additions from stale drift"
cat > "$SB/drift-inv.yaml" <<'YAML'
schema_version: 5
profile: workstation
apt_packages: []
snap_packages: []
flatpak_apps: []
dotfiles: []
groups: []
user_dirs: []
apps:
  - name: fish
    description: "Friendly interactive shell (official apt)"
    installer: { type: apt }
    check_cmd: fish
    config_paths: ["~/.config/fish"]
    conflict_policy: replace
  - name: code
    description: "Visual Studio Code"
    installer: { type: snap_classic, package: code }
    check_cmd: code
    config_paths: ["~/.config/code-custom"]
    exclude: ["CachedData"]
  - name: sublime-text
    description: "Sublime Text editor (official apt repo)"
    installer:
      type: apt_repository
      url: "https://download.sublimetext.com/"
      suite: "apt/stable/"
      components: []
      key_url: "https://download.sublimetext.com/sublimehq-pub.gpg"
      packages: ["sublime-text"]
    check_cmd: "sublime_text"
    depends_apt: ["curl"]
    config_paths: ["~/.config/sublime-text"]
    exclude: ["Log"]
services: []
YAML
# REPO_ROOT=$SB is already exported by the backup.sh section above (its
# basename is .test-tmp.*, which the override guard accepts), so the drift
# command's .drift-*. scratch files stay inside the sandbox too.
if ( export INVENTORY_FILE="$SB/drift-inv.yaml"; bash "$ORIG_REPO/inventory.sh" review --drift ) > "$SB/drift.log" 2>&1; then
  t_pass "review --drift ran"
else
  t_fail "review --drift failed — see $SB/drift.log"
fi
assert_contains "additions: conflict_policy" "$SB/drift.log"  # intentional extra, NOT stale
assert_not_contains "stale:" "$SB/drift.log"
assert_contains "expressible as a reference" "$SB/drift.log"   # fish diff is representable
assert_contains "removed template items" "$SB/drift.log"       # code lost template paths/excludes
assert_contains "keep the full record" "$SB/drift.log"         # code diff is NOT representable
assert_not_contains "sublime-text" "$SB/drift.log"             # equal empty array (components: []) is NOT drift

sandbox_cleanup
t_summary
