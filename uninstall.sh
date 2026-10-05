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

echo "Removing auto-heal udev rules ..."
# first, so no udev event re-binds an anchor while the redirects are being rolled back
rm -f /etc/udev/rules.d/99-zima-location-*.rules
udevadm control --reload 2>/dev/null || true

echo "Rolling back all zima-location redirects ..."
for u in "$UNIT_DIR"/zima-location-*.service; do
  [ -e "$u" ] || continue
  uname="$(basename "$u")"
  anchor="$(awk -F'redirect.sh ' '/ExecStart=/{print $2}' "$u" | awk '{print $1}')"
  echo "  - $uname (anchor: ${anchor:-?})"
  systemctl disable --now "$uname" 2>/dev/null || true
  if [ -n "${anchor:-}" ] && mountpoint -q "$anchor"; then
    umount "$anchor" 2>/dev/null || umount -l "$anchor" || true   # -l: disk already gone (USB reset)
  fi
  rm -f "$u"
done
systemctl daemon-reload

echo "Removing $DEST ..."
find "$DEST" -type f -delete 2>/dev/null || true
find "$DEST" -depth -type d -empty -delete 2>/dev/null || true
echo "✅ Uninstalled. Redirected data remains on its target disk(s); any *.pre-zl backups were left in place."
