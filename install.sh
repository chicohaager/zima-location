#!/bin/bash
# zima-location installer for ZimaOS.
# Usage (from a checkout):   sudo ./install.sh
#        or one-liner:       curl -fsSL https://raw.githubusercontent.com/chicohaager/zima-location/main/install.sh | sudo bash
set -euo pipefail

REPO_RAW="${ZL_REPO_RAW:-https://raw.githubusercontent.com/chicohaager/zima-location/main}"
DEST="/etc/zima-location"   # root-only (not world-writable /DATA/AppData)

[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./install.sh"; exit 1; }
[ -d /DATA ] || { echo "ERROR: /DATA not found — this installer targets ZimaOS / CasaOS."; exit 1; }
command -v findmnt >/dev/null || { echo "ERROR: findmnt (util-linux) is required."; exit 1; }
command -v systemctl >/dev/null || { echo "ERROR: systemd is required."; exit 1; }

echo "Installing zima-location to $DEST ..."
mkdir -p "$DEST"; chown root:root "$DEST"; chmod 0755 "$DEST"

if [ -f "$(dirname "$0")/zima-location.sh" ]; then cp "$(dirname "$0")/zima-location.sh" "$DEST/zima-location.sh"
else curl -fsSL "$REPO_RAW/zima-location.sh" -o "$DEST/zima-location.sh"; fi
chown root:root "$DEST/zima-location.sh"; chmod 0755 "$DEST/zima-location.sh"

cat <<EOF

✅ Installed (root-owned, $DEST).

Run it (root required):
  sudo $DEST/zima-location.sh list-disks
  sudo $DEST/zima-location.sh set /DATA/Media <UUID> Media
  sudo $DEST/zima-location.sh status
  sudo $DEST/zima-location.sh rollback /DATA/Media

Pick a NATIVE Linux fs disk (ext4/btrfs/xfs). exFAT/NTFS are rejected. See README.
Optional web UI: sudo ui/install-ui.sh   (localhost-only by default).
EOF
