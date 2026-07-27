# Backup-Restore-Ubuntu

This repository contains a simple backup and restore workflow for Ubuntu system state, configuration, and application metadata. It is designed for an operator who wants to capture system packages, custom services, user configs, VS Code extensions, and important app files, then restore them on a fresh Ubuntu install.

## What is included

- `backup.sh` - gathers package lists, apt sources, snaps, user config, custom services, app metadata, and package.json files into a repo-local `backup/` folder.
- `restore.sh` - restores apt sources, apt package selections, snaps, VS Code extensions, configs, dotfiles, custom services, and archived `/opt` and `/usr/local` application directories.
- `schedule_cron.sh` - installs a cron entry that runs `backup.sh` 15 minutes after reboot and saves its output to `backup/cron-backup.log`.

## Operator view

### Primary tasks

- Run a manual backup:
  ```bash
  cd /home/vikram-athare/backup-restore-ubuntu
  bash backup.sh
  ```

- Run a manual restore:
  ```bash
  cd /home/vikram-athare/backup-restore-ubuntu
  bash restore.sh
  ```

- Install the cron-based scheduler:
  ```bash
  cd /home/vikram-athare/backup-restore-ubuntu
  bash schedule_cron.sh
  ```

### Verification

- Verify that backups are being created in `backup/`.
- Check the cron log after a test run:
  ```bash
  cat /home/vikram-athare/backup-restore-ubuntu/backup/cron-backup.log
  ```

- Confirm the cron entry exists:
  ```bash
  crontab -l | grep backup-restore-ubuntu
  ```

### Notes for operators

- This repo is intended to preserve system and user environment state, not personal documents or code repos.
- `backup.sh` writes into a local repository folder: `backup/`.
- The cron job uses `@reboot` plus `sleep 900`, so it starts the backup 15 minutes after system boot.
- The restore flow performs package and config restoration, but some manual review may still be required for service-specific settings.

## Maintenance

- Keep the repo under version control, but do not commit the `backup/` folder if it contains sensitive files.
- If you modify the scripts, validate the restore process on a fresh system before relying on it for production recovery.

## Important

- `schedule_cron.sh` updates the current user’s crontab.
- The scripts assume the repo is located at `/home/vikram-athare/backup-restore-ubuntu` and use paths relative to the repo root.
