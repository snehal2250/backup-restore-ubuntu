#!/bin/bash
# ---------------------------------------------------------------------------
# schedule_cron.sh — install a systemd user timer that runs backup.sh daily.
#
# This replaces the old @reboot cron approach with a proper systemd user timer
# that runs backup.sh periodically (daily, with a random delay) and retries
# on failure. The timer tracks last-run state natively.
#
# Run this as the normal user (NOT root). The timer runs in the user's own
# systemd session and inherits the user's environment + DBus session.
# ---------------------------------------------------------------------------
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_non_root

SERVICE_NAME="backup-restore-ubuntu"
USER_SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

mkdir -p "$USER_SYSTEMD_DIR"

# --- Service unit ---
cat > "$USER_SYSTEMD_DIR/${SERVICE_NAME}.service" <<SVC
[Unit]
Description=Backup restore-ubuntu configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "$REPO_ROOT/backup.sh"
# Pass the backup destination explicitly (cron-like environments don't source rc files).
Environment=BACKUP_DEST=${BACKUP_DEST:-}
Environment=BACKUP_KEEP=${BACKUP_KEEP:-5}
Environment=HOME=$HOME
Environment=USER=$USER
Environment=YQ_AUTO=1
Environment=SCHEMA_AUTO=1
StandardOutput=append:$REPO_ROOT/backups/timer-backup.log
StandardError=append:$REPO_ROOT/backups/timer-backup.log

[Install]
WantedBy=default.target
SVC

# --- Timer unit ---
cat > "$USER_SYSTEMD_DIR/${SERVICE_NAME}.timer" <<TMR
[Unit]
Description=Daily backup-restore-ubuntu backup
After=network-online.target

[Timer]
# Run daily, starting 15 minutes after boot, with a 10-minute random delay.
OnBootSec=15min
OnUnitActiveSec=24h
RandomizedDelaySec=10min
Persistent=yes

[Install]
WantedBy=timers.target
TMR

# Remove any old cron entry.
if crontab -l 2>/dev/null | grep -q -F "backup-restore-ubuntu"; then
  crontab -l 2>/dev/null | grep -v -F "backup-restore-ubuntu" | grep -v -F "$REPO_ROOT/backup.sh" | crontab - || true
  echo "Removed old @reboot cron entry."
fi

# Enable and start the timer.
systemctl --user daemon-reload
systemctl --user enable "${SERVICE_NAME}.timer"
systemctl --user start "${SERVICE_NAME}.timer"

ok "Systemd timer installed and started: ${SERVICE_NAME}.timer"
echo
echo "Status:"
echo "  systemctl --user status ${SERVICE_NAME}.timer"
echo "  systemctl --user status ${SERVICE_NAME}.service"
echo
echo "Logs:"
echo "  journalctl --user -u ${SERVICE_NAME}.service"
echo "  tail -f $REPO_ROOT/backups/timer-backup.log"
echo
echo "The timer runs backup.sh daily and 15 minutes after each boot."
echo "Use BACKUP_DEST env var before running this script to set a custom mirror:"
echo "  BACKUP_DEST=/media/\$USER/Storage/backup-restore-ubuntu ./schedule_cron.sh"
