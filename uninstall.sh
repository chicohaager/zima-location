#!/bin/bash
# zima-location uninstaller — rolls back all redirects, stops the UI, removes files.
# Data on target disks is NOT touched. Usage: sudo ./uninstall.sh
set -euo pipefail
DEST="/etc/zima-location"
UNIT_DIR="/etc/systemd/system"
[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./uninstall.sh"; exit 1; }

echo "Stopping web UI (if present) ..."
systemctl disable --now zima-location-ui.service 2>/dev/null || true
rm -f "$UNIT_DIR/zima-location-ui.service"

echo "Rolling back all zima-location redirects ..."
for u in "$UNIT_DIR"/zima-location-*.service; do
  [ -e "$u" ] || continue
  uname="$(basename "$u")"
  anchor="$(awk -F'redirect.sh ' '/ExecStart=/{print $2}' "$u" | awk '{print $1}')"
  echo "  - $uname (anchor: ${anchor:-?})"
  systemctl disable --now "$uname" 2>/dev/null || true
  [ -n "${anchor:-}" ] && { mountpoint -q "$anchor" && umount "$anchor" || true; }
  rm -f "$u"
done
systemctl daemon-reload

echo "Removing $DEST ..."
find "$DEST" -type f -delete 2>/dev/null || true
find "$DEST" -depth -type d -empty -delete 2>/dev/null || true
echo "✅ Uninstalled. Redirected data remains on its target disk(s); any *.pre-zl backups were left in place."
