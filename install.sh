#!/bin/bash
# zima-location installer for ZimaOS.
# Usage (from a checkout):   sudo ./install.sh
#        or one-liner:       curl -fsSL https://raw.githubusercontent.com/chicohaager/zima-location/main/install.sh | sudo bash
set -euo pipefail

REPO_RAW="${ZL_REPO_RAW:-https://raw.githubusercontent.com/chicohaager/zima-location/main}"
DEST="/DATA/AppData/zima-location"

[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./install.sh"; exit 1; }
[ -d /DATA ] || { echo "ERROR: /DATA not found — this installer targets ZimaOS / CasaOS."; exit 1; }
command -v findmnt >/dev/null || { echo "ERROR: findmnt (util-linux) is required."; exit 1; }
command -v systemctl >/dev/null || { echo "ERROR: systemd is required."; exit 1; }

echo "Installing zima-location to $DEST ..."
mkdir -p "$DEST"

fetch(){ # fetch <file> — copy from local checkout if present, else download from repo
  local f="$1"
  if [ -f "$(dirname "$0")/$f" ]; then cp "$(dirname "$0")/$f" "$DEST/$f"
  else curl -fsSL "$REPO_RAW/$f" -o "$DEST/$f"; fi
}

fetch zima-location.sh
fetch redirect.sh
chmod 0755 "$DEST/zima-location.sh" "$DEST/redirect.sh"

cat <<EOF

✅ Installed.

Run it (root required):
  sudo $DEST/zima-location.sh list-disks
  sudo $DEST/zima-location.sh set /DATA/Media <UUID> Media
  sudo $DEST/zima-location.sh status
  sudo $DEST/zima-location.sh rollback /DATA/Media

Tip: pick a NATIVE Linux fs disk (ext4/btrfs). exFAT/NTFS are rejected
(container uid cannot chown them). See README for details.
EOF
