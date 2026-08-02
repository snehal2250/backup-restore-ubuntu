# AGENTS.md — Context for AI agents working on this repo

**Read this file first, before any other file.** If a task or a change conflicts with
anything written here, stop and ask the user. This file is the single source of truth for
the project's *why* and *how*.

---

## 1. Mission

This repo restores the user's Ubuntu desktop back to its last-known-good state
**without restoring binaries, packages, or application data from the backup**.

Instead:

- A single user-maintained file, `inventory/inventory.yaml`, declares which
  **applications, packages, services, dotfiles, user-data folders, groups, default shell,
  and extensions** the user wants.
- `backup.sh` captures **only the configuration** for those declared items
  (config directories, systemd unit files, dotfiles) plus any whole **user-data
  folders** the user declared (`user_dirs`, e.g. `~/Documents`) into a git-ignored
  `backups/` folder using **transactional staging** (build in staging, validate, atomically
  swap in — the last-known-good backup is never modified in place). A failure leaves the
  previous backup intact.
- `restore.sh` performs a **fresh install** of those items from their recommended sources
  (Ubuntu repositories, Snap Store, Flathub, official installers) at the **latest stable
  versions**, then **overwrites** them with the backed-up configuration. It validates the
  backup manifest (requires `status: ok`) before restoring config, uses `bash -o pipefail`
  for installer commands, checks installation by source (dpkg/snap/flatpak, not just
  `command -v`), tracks all failures, and exits with a nonzero accumulated code if any
  required item failed. Under `--packages-only`, services are installed but NOT
  enabled/started (they need config restored first).

Example (the canonical one): the user uses OpenCode.
- The inventory declares the `opencode` app with a typed `script` installer.
- `backup.sh` copies `~/.config/opencode` into `backups/apps/opencode/`.
- `restore.sh` downloads `https://opencode.ai/install` to a temp file and executes it
  (fresh binary, latest version), then restores `~/.config/opencode` on top.

The repo is deliberately **not** a traditional image/byte-level backup. It rebuilds a
system the same way a person would set up a new machine: install what you use, then copy
your settings over it.

## 2. Non-negotiable principles

1. **Fresh install, never copy.** `restore.sh` must install packages/applications from
   their recommended sources at the latest stable version. It must never install from
   backup files, never untar `/opt` or `/usr/local` archives, never replay `dpkg
   --get-selections` state.
2. **Configuration is the only thing copied.** The backup captures configuration for
   inventory items and nothing else: no binaries, no whole-`~/.config` dumps, no dpkg
   databases, no home-directory bulk copying. The one deliberate exception: whole
   user-data folders a user explicitly declares under `user_dirs` (e.g. `~/Documents`)
   are captured in full — those are user data, not app configuration.
3. **The inventory is the single source of truth.** `inventory/inventory.yaml` is the only
   list of what to back up and install. Scripts must never hardcode user apps, package
   names, or services. The seed catalog in `lib/catalog.sh` may *suggest* install methods,
   but it must never bypass the inventory.
4. **Only what the user installed on top of stock Ubuntu.** No kernel/base-system state,
   no default packages, no system-wide dumps. Dependencies of an app (e.g. `nodejs`/`npm`
   for a node-based app) are declared **per app** in the inventory as `depends_apt`, and are
   **never** separate inventory items the user has to think about.
5. **Version-agnostic.** Never record, pin, or restore application/package versions.
   Latest stable wins, always. No `@1.2.3` anywhere in the data.
6. **Idempotent and safe.** Scripts must be safe to run multiple times. `restore.sh`
   prompts before modifying the system (`--yes` to skip), supports `--dry-run`, and now
   exits nonzero when required items fail (accumulated exit code via bitmask). `--dry-run`
   previews the restore but may auto-install `yq` if missing — the only thing a preview
   executes, because it must still read the inventory. Restore refuses to run as root and
   dies on non-Ubuntu systems.
7. **Everything is declarative.** Data lives in `inventory/inventory.yaml`; code lives in
   scripts under this repo. Never mix the two.
8. **Backups are transactional.** Each `backup.sh` run builds a complete new generation in
   a staging directory, validates it, writes a manifest, mirrors it, and atomically swaps
   it in. The last-known-good backup is **never** modified in place. A failure to complete
   simply leaves the staging directory (cleaned up on next run) and the previous backup
   intact. `flock` prevents concurrent runs. Publication (`publish_backup` in
   `lib/common.sh`) is fail-fast: the live dir is renamed aside **first** and any failure
   stops the run — it never moves staging over an existing live dir. The two renames are
   atomic only on one filesystem, which is verified before anything moves. The previous
   generation is retained until the new one passes final manifest verification
   (`status: ok`); a failing generation rolls back to the last-known-good one. A cleanup
   trap removes leftovers from interrupted runs.
9. **Truthful reporting.** `restore.sh` tracks every failure via an accumulated exit code
   bitmask. If any required app install, config restore, or service fails, the script exits
   nonzero. The backup manifest records per-artifact status (`captured`/`missing`/
   `incomplete`/`empty`) so the user knows exactly what was captured.
10. **Source-specific installation checks.** `restore.sh` checks whether an app is
    installed by its declared source (`dpkg-query` for apt, `snap list` for snap,
    `flatpak info` for flatpak, `npm list -g` for npm-global), not just by `command -v`
    which can match unrelated binaries.

## 3. What we deliberately do NOT do (anti-patterns)

| Do not | Because |
| --- | --- |
| `dpkg --set-selections` / `dselect-upgrade` | Restores exact versions/state — violates principle 1 & 5 |
| tar of `/opt`, `/usr/local`, `/etc` | Copies binaries/system state — violates principle 1 & 2 |
| `rsync -a ~/.config/` wholesale | Copies junk + unknown apps — violates principle 2 & 3 |
| Restoring apt sources/keyrings | Fresh Ubuntu ships correct sources — violates principle 1 |
| Recording installed versions/snapshots | Version-agnostic (principle 5) |
| Hardcoding app/package names in scripts | Violates principle 3 |
| Running restore as root | Silently restores config into /root — violates principle 2 |
| Overwriting backup in place | Previous good backup is destroyed before new one is proven |
| `command -v` to check installed | May match wrong source or leftover binary |
| Running services under `--packages-only` | Config hasn't been restored yet |

## 4. Repo map

```
AGENTS.md                 <- this file (agents MUST read it)
README.md                 <- user-facing quick start
docs/PLAN.md              <- roadmap to the end state
docs/RESTORE.md           <- user-facing step-by-step restore runbook
docs/REHEARSAL-VIRTUALBOX.md <- tested VirtualBox rehearsal procedure (Oracle 7.1.x,
                              VM creation, vboxsf shared folders, restore replay)
inventory/
  inventory.yaml          <- THE source of truth (user-maintained, git-tracked)
  schema.yaml             <- VERSIONED JSON Schema (draft 2020-12) — the structural
                             contract for inventory.yaml (schema_version must match)
lib/
  common.sh               <- shared helpers (logging, yq bootstrap, YAML getters, status
                             checkers, path safety, manifest helpers, inventory validation,
                             concurrency protection, architecture detection)
  installers.sh           <- TYPED installer functions for the structured `installer:`
                             records (apt, snap, snap_classic, flatpak, npm_global, pipx,
                             cargo, apt_repository, deb, tarball, script) — no free-form
                             shell anywhere
  schema_check.py         <- REAL structural validator: python3 + jsonschema + PyYAML,
                             checks inventory.yaml against inventory/schema.yaml
  catalog.sh              <- seed catalog of common apps (opencode, code, docker, chrome,
                             gh, gcloud, go, uv, tmux, terraform, ollama, az, azurite,
                             slack, onlyoffice, storage-explorer, cloudflared, ...)
inventory.sh              <- MANUAL tool: list / add-* / remove-* / review / wizard / validate
backup.sh                 <- captures configs + service units + dotfiles -> backups/
                             (transactional: staging -> validate -> mirror -> atomic swap)
restore.sh                <- fresh install + config overwrite (--dry-run/--yes/--upgrade-base/
                             --configs-only/--packages-only/--force-incomplete/--source <snapshot>)
update_all_ubuntu.sh      <- updates apt/snap/flatpak/npm + inventory apps
schedule_cron.sh          <- installs a systemd user timer (daily + after boot)
backups/                  <- output of backup.sh (GIT-IGNORED; contains personal config)                             (apps/<name>/, services/<unit>/, dotfiles/, user-dirs/<name>/,
                              SHA256SUMS content checksums)
                             mirrored to BACKUP_DEST (default /media/vikram-athare/Storage/backup-restore-ubuntu)
                           (the legacy single backup/ folder from the old script was
                           removed from git tracking; if its on-disk root-owned remnant
                           still exists, delete it with 'sudo rm -rf backup')
```

## 5. Inventory model (`inventory/inventory.yaml`)

The file is plain YAML with top-level scalars (`schema_version`, `profile`,
`default_shell`), flat lists (`groups`, `user_dirs`), and structured lists (`apps`,
`services`). `schema_version` and `profile` are REQUIRED, and ALL top-level lists
(`apt_packages`, `snap_packages`, `flatpak_apps`, `dotfiles`, `groups`, `user_dirs`,
`apps`, `services`) are required too (empty allowed) — the scripts read them with plain
`yq` expressions, so a schema-valid inventory must declare every one. All are validated
against `inventory/schema.yaml` (bump both together when the contract changes).

```yaml
schema_version: 1            # REQUIRED — must match inventory/schema.yaml
profile: workstation         # REQUIRED — machine profile (validated)
default_shell: /usr/bin/fish   # optional: login shell set via chsh after restore
groups:                        # optional: Unix groups the user needs
  - docker
apt_packages:                  # installed via: sudo apt-get install -y <item>
  - git
snap_packages:                 # suffix ':classic' = classic confinement
  - code:classic
flatpak_apps:                  # installed via: flatpak install -y flathub <item>
  - org.gimp.GIMP
dotfiles:                      # copied from/to $HOME (e.g. .bashrc, .gitconfig)
  - .bashrc
user_dirs:                     # WHOLE user-data folders captured/restored in full
  - ~/Documents

apps:                          # one entry per MAIN app
  - name: opencode
    description: AI coding agent
    installer:                 # typed record — HOW to install (see rules below)
      type: script             # apt|snap|snap_classic|flatpak|npm_global|pipx|cargo|
                               #   apt_repository|deb|tarball|script
      url: https://opencode.ai/install
      unverified: true         # explicit acknowledgement (no pinned checksum)
    check_cmd: opencode        # binary to verify installation
    depends_apt:               # auto-installed before the app
      - curl
    config_paths:              # backed up + restored (overwritten) for this app
      - ~/.config/opencode
    exclude:                   # rsync patterns to keep caches/binaries out
      - CachedData
    extensions:                # optional: IDs to re-install after restore
      - some-extension         # VS Code -> code --install-extension
                               # Azure CLI -> az extension add
                               # Ollama -> ollama pull
    conflict_policy: merge     # optional: how restore applies config when the target
                               # already has files (merge|replace|skip-existing|prompt)

services:                      # only CUSTOM services the user installed
  - unit: myservice.service
    target: system             # system (/etc/systemd/system) or user (~/.config/systemd/user)
    enable: true
    start: true
    config_paths:              # config files the service needs
      - ~/.config/myservice
```

Rules for agents editing the inventory:

- Only add items the user explicitly asked for, or that `inventory.sh` produced. Never
  invent apps/packages/services from guesswork.
- `installer.type` values: `apt`, `snap`, `snap_classic`, `flatpak`, `npm_global`, `pipx`,
  `cargo`, `apt_repository` (signed third-party apt repo), `deb`, `tarball`, `script`
  (remote script — explicit LAST RESORT, never a preferred choice). Each type maps to
  ONE narrowly-scoped function in `lib/installers.sh`; there is NO free-form
  `install_command` anywhere. Downloads/scripts require a pinned `checksum`,
  `checksum_url`, or an explicit `unverified: true` acknowledgement.
- Optional `installer.package` overrides the source package name for package-based
  types (`apt`/`snap`/`snap_classic`/`flatpak`/`npm_global`/`pipx`/`cargo`) when it
  differs from the app name. It must ONLY be used with those types. Download types use
  `installer.url` (+ `suite`/`key_url`/`key_fingerprint`/`packages` for `apt_repository`,
  `{arch}`/`{version}` templates, arch gates — see `inventory/schema.yaml`).
- `config_paths` and `user_dirs` use `~` (tilde) form for portability.
- `validate_inventory` runs before all destructive operations. It has TWO layers:
  1. **Structural** — `inventory/schema.yaml` (versioned JSON Schema, draft 2020-12)
     enforced by a REAL validator (`lib/schema_check.py`: python3 + the reference
     `jsonschema` library + PyYAML). This replaces all ad-hoc structural parsing: allowed
     keys per install type, package/source identifier patterns, path forms (~/ or
     absolute, no `..`, no control chars), systemd unit names, group names,
     `schema_version`/`profile` identity.
  2. **Semantic** — checks a schema cannot express: unique app/service names,
     `default_shell` provided by a declared app, apt package, or apt app `package`
     override, user_dirs under `$HOME`,
     interactive install commands (known TUI binaries — `read`/`select`/`dialog`/`fzf`/
     `ssh`/etc. — and `apt`/`flatpak` without `-y`; heuristic, not exhaustive),
     config paths nested under the same app's own `exclude` patterns, and overlapping
     or duplicated path ownership across apps/services/user_dirs (a nested path is only
     allowed when the outer app's `exclude` covers the nested component — the freebuff
     `~/.config/manicode` + `user_dirs: ~/.config/manicode/projects` split is the
     canonical allowed case). It also hard-blocks unsupported architectures/Ubuntu
     releases (`SUPPORTED_ARCHS`, `SUPPORTED_UBUNTU_RELEASES` in `lib/common.sh`).
- `schema_version`/`profile` are top-level REQUIRED keys validated by the schema;
  never bump them without updating `inventory/schema.yaml` (`$id` + version) and docs.
- `extensions` lists extension/model IDs (without versions). During the post-install phase
  of restore, each is installed via the app's native mechanism.
- `default_shell` is a top-level key (not per-app). The declared shell package must itself
  be a declared app.
- `groups` is a top-level list. Each group name is added to the user via `usermod -aG`.
- A custom service's runtime files belong in that service's `config_paths` (or the relevant
  app's `config_paths`). They are never auto-inferred from the unit file alone.
- Do not add dependencies as separate entries (principle 4).
- `conflict_policy` (optional, apps and services; default `merge`) controls how restore
  applies that owner's config when the target already has files: `merge` = additive
  overlay, never deletes; `replace` = preserve existing into the rollback bundle, then
  mirror the backup exactly (`rsync --delete`); `skip-existing` = restore only missing
  files; `prompt` = ask per config path (non-interactive runs skip). Every config restore
  first captures what it is about to overwrite into a timestamped rollback bundle under
  `~/.local/state/backup-restore-ubuntu/rollback-<ts>/` with a `restore-journal.log`
  (created/replaced/skipped/failed); `--dry-run` creates nothing. The bundle lives
  OUTSIDE the backup source so the repo checkout and backup medium stay pristine.

## 6. Standard workflows

**Declare an app** (the user's manual responsibility; the tool does the work):
```bash
./inventory.sh add-app opencode     # wizard; catalog prefills opencode
./inventory.sh add-package apt git
./inventory.sh add-service          # wizard (validates unit name, config paths)
./inventory.sh add-user-dir ~/Documents
./inventory.sh list                 # see everything + installed status
./inventory.sh validate             # validate schema + semantics (safe, read-only)
./inventory.sh review               # suggests apps found on the system, not yet declared
./inventory.sh wizard               # guided: scan the system, declare apps one by one
```

**Backup** (captures config for everything declared, plus any `user_dirs`):
```bash
./backup.sh
```
Output goes to `backups/` (git-ignored) via transactional staging, then mirrored to
`BACKUP_DEST`. The backup manifest (`backup-info.txt`) records per-artifact status and
overall outcome. A `status: ok` line means ALL declared artifacts were captured. Each
run also writes `SHA256SUMS` (deterministic checksums over the payload, excluding the
manifest and mutable logs); `restore.sh` verifies it before restoring config. The
`in_progress` marker is written into the STAGING manifest (`backups.staging/backup-info.txt`)
when a run starts — never into the live `backups/` manifest, which is only ever replaced
atomically by a generation that passed final verification. A missing live manifest, or
one that does not report `status: ok`, means the last completed run did not succeed.

**Restore** (on a fresh Ubuntu install):
```bash
./restore.sh                        # prompts; --yes to skip, --dry-run to preview
./restore.sh --source /media/$USER/Storage/backup-restore-ubuntu/backup-20260802-120000
#                                   # restore config DIRECTLY from an external backup
#                                   # snapshot (no copying into backups/ needed).
#                                   # Preflight: realpath resolve, require a verified
#                                   # manifest (status: ok), verify arch / Ubuntu
#                                   # release / inventory-SHA compatibility, warn on
#                                   # writable sources, print the source before any
#                                   # system change. Nothing is copied or mounted.
./restore.sh --upgrade-base         # OPT-IN: also apt full-upgrade of the base OS
./restore.sh --configs-only         # restore config only (skip all installs)
./restore.sh --packages-only        # install fresh only (skip config + services)
./restore.sh --force-incomplete     # restore even from an incomplete backup
```
Restore validates the backup manifest (requires `status: ok`) and the SHA256SUMS content
check before restoring config. Config is applied per the owner's `conflict_policy`
(default `merge`), and every overwrite is first captured into a timestamped rollback
bundle + restore journal (printed at the end of the run). Under `--packages-only`,
services are installed but NOT enabled/started. Restore exits
nonzero if any required item failed.

**Post-restore** — groups, default shell, app extensions/models are applied:
```bash
# groups (e.g. docker) — user added via usermod -aG
# default_shell — set via chsh
# VS Code extensions — installed via code --install-extension
# Azure CLI extensions — installed via az extension add
# Ollama models — pulled via ollama pull
```

**Keep everything current**:
```bash
./update_all_ubuntu.sh
```

**Scheduled backup** (systemd user timer):
```bash
./schedule_cron.sh   # installs a daily systemd user timer + runs 15min after boot
```

## 7. Conventions for AI agents

- **Shell code**: bash, `set -euo pipefail` at the top of every script, `shellcheck`
  clean. Scripts run on Ubuntu's default bash (4.x) — no bash 5-only features.
- **Reuse `lib/common.sh`**: logging (`info/ok/warn/err/die`), `confirm`, `require_cmd`,
  `require_yq`, `require_non_root`, `require_ubuntu`, `yaml_get`, `yaml_list`,
  `app_get`, `installer_get`/`installer_list`/`installer_has`, `expand_path`,
  `normalize_path`, `validate_path_contained`, `require_schema_validator`,
  `validate_schema_structure`, `validate_inventory`, `manifest_in_progress`,
  `manifest_final`, `manifest_verify_restorable`, `conflict_policy_get`,
  `rollback_init`/`rollback_capture`/`journal_log` (per-owner conflict policies,
  rollback bundle + restore journal),
  `backup_generate_checksums`/`backup_verify_integrity` (SHA256SUMS content integrity:
  generated over the staged payload by `backup.sh`, verified by `restore.sh` before any
  config restore — hostile special files, escaping symlinks, missing/corrupt files,
  extra-file warnings), `publish_backup` (transactional swap:
  same-filesystem check, fail-fast renames, rollback to the previous generation, cleanup
  trap), `run` (dry-run aware), status checkers (`is_apt_installed`, `is_snap_installed`,
  `is_flatpak_installed`, `is_app_installed_by_source`, `is_app_installed`),
  `with_lock`/`release_lock` (flock). App installs go through the TYPED installer
  functions in `lib/installers.sh` (`installer_run NAME`) — never inline shell.
- **YAML is read with `yq`** (https://github.com/mikefarah/yq). `require_yq` follows
  `YQ_AUTO`. `app_get`/`installer_get` use `strenv(N)` for the app name (safe) and `$2`
  directly for the yq query (always a fixed expression like `.installer.type`). Write
  YAML with `yq -i` and `strenv(VAR)`/`load()` — never by string-concatenating user
  input into expressions. NOTE: the snap-packaged yq cannot read /tmp, so `load()`
  temp files must be created under `$REPO_ROOT`, not with bare `mktemp`.
- **Structural checks are NEVER ad-hoc bash parsing** — they go through the versioned
  schema (`inventory/schema.yaml`) and the real validator (`require_schema_validator` /
  `validate_schema_structure`, python3 + jsonschema). `SCHEMA_AUTO` mirrors `YQ_AUTO`
  (0=die, 1=auto-install python3-jsonschema python3-yaml, 2=confirm); scripts set it the
  same way they set `YQ_AUTO`. Free-text values (install_command, config paths) must
  never be emitted through yq `@tsv` (it quotes double-quote fields) — use plain `-r`
  streams or tab-joined concatenation (control chars are schema-forbidden).
- **Never run `restore.sh` or `update_all_ubuntu.sh` on the user's machine without
  explicit permission.** `inventory.sh` only edits the inventory; `backup.sh` only writes
  to git-ignored `backups/`. Both are safe. `restore.sh` modifies the system.
- **When adding features**: keep `inventory.yaml` backward compatible; update `AGENTS.md`
  (this file), `README.md`, and `docs/PLAN.md` if the schema, principles, or workflow
  change. If you change an exported helper in `lib/common.sh`, update all callers.
- **Validate before finishing**: `bash -n <script>` on every script, `shellcheck
  <script>` if installed. Also run `./inventory.sh validate` to check the inventory.

## 8. Glossary

- **Inventory** — the declarations in `inventory/inventory.yaml` (what the user uses).
- **Backup** — captured configuration in `backups/` (git-ignored, machine-specific).
- **Restore** — fresh install from recommended sources + config overwrite from `backups/`.
- **Installer** — the typed `installer:` record on each app; `lib/installers.sh`
  dispatches it. Replaces the old opaque `install_command` shell pipelines.
- **Catalog** — built-in knowledge in `lib/catalog.sh` used by `inventory.sh add-app`.
- **Custom service** — a systemd unit the user installed themselves; only these are ever
  declared in the inventory.
- **Manifest** — `backup-info.txt` written by `backup.sh` on completion with artifact
  status, inventory SHA-256, and overall `status: ok` (or `degraded`). The `in_progress`
  marker lives only in the staging manifest during a run.
- **Transactional backup** — build in staging, validate, mirror, atomically swap to live.
  The current `backups/` is never the target of an in-progress rebuild.
