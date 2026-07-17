#!/bin/bash
# zima-location uninstaller — rolls back all redirects, then removes files.
# Data on target disks is NOT touched. Usage: sudo ./uninstall.sh
set -euo pipefail
DEST="/DATA/AppData/zima-location"
UNIT_DIR="/etc/systemd/system"
[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./uninstall.sh"; exit 1; }

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
rm -f "$DEST/zima-location.sh" "$DEST/redirect.sh"
rmdir "$DEST" 2>/dev/null || true
echo "✅ Uninstalled. Redirected data remains on its target disk(s); any *.pre-zl backups were left in place."
