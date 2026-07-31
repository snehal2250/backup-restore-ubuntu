#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
LOGFILE="$SCRIPT_DIR/backups/cron-backup.log"
USER_HOME="${HOME:-}"

if [ -z "$USER_HOME" ]; then
  echo "HOME is not set. Run this as the user who owns the backup repo."
  exit 1
fi

CRON_MARK="# backup-restore-ubuntu cron entry"
CRON_CMD="@reboot sleep 900 && HOME=\"$USER_HOME\" PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /bin/bash \"$BACKUP_SCRIPT\" >> \"$LOGFILE\" 2>&1"

mkdir -p "$SCRIPT_DIR/backups"
TMPFILE="$SCRIPT_DIR/schedule_cron.tmp"
trap 'rm -f "$TMPFILE"' EXIT

# Remove any previous entry: the marker line AND the @reboot command line (which
# contains the backup script path). Filtering only the marker would leave the old
# command behind and re-running would stack duplicate @reboot jobs.
crontab -l 2>/dev/null | grep -v -F "$CRON_MARK" | grep -v -F "$BACKUP_SCRIPT" > "$TMPFILE" || true
{
  cat "$TMPFILE"
  echo "$CRON_MARK"
  echo "$CRON_CMD"
} | crontab -

echo "Cron job installed."
echo "@reboot job will run 15 minutes after reboot and append logs to $LOGFILE."
echo "Note: the scheduled run only captures configuration (see backup.sh)."
echo "Each run also mirrors backups/ to \$BACKUP_DEST (default: /media/vikram-athare/Storage/backup-restore-ubuntu),"
echo "keeping the last \$BACKUP_KEEP (default 5) snapshots."
echo "Installed entry:"
echo "$CRON_CMD"
echo "Verify with: crontab -l | grep backup-restore-ubuntu"
