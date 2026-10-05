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

# Checkout only when this script is a real file. Under 'curl … | bash' BASH_SOURCE is empty and
# $0 is "bash" -> dirname "." would pick up whatever zima-location.sh sits in the caller's cwd.
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ -f "$SRC_DIR/zima-location.sh" ] || SRC_DIR=""
fi

# fetch <repo-path> <dest-file> <mode>
fetch(){
  if [ -n "$SRC_DIR" ]; then cp "$SRC_DIR/$1" "$2"
  else curl -fsSL "$REPO_RAW/$1" -o "$2"; fi
  chown root:root "$2"; chmod "$3" "$2"
}

echo "Installing zima-location to $DEST (source: ${SRC_DIR:-$REPO_RAW}) ..."
mkdir -p "$DEST/ui"; chown root:root "$DEST" "$DEST/ui"; chmod 0755 "$DEST" "$DEST/ui"
fetch zima-location.sh "$DEST/zima-location.sh" 0755
# UI files are only copied here; the UI service starts only via install-ui.sh.
fetch ui/install-ui.sh "$DEST/ui/install-ui.sh" 0755
fetch ui/server.py     "$DEST/ui/server.py"     0755
fetch ui/index.html    "$DEST/ui/index.html"    0644

cat <<EOF

✅ Installed (root-owned, $DEST).

Run it (root required):
  sudo $DEST/zima-location.sh list-disks
  sudo $DEST/zima-location.sh set /DATA/Media <UUID> Media
  sudo $DEST/zima-location.sh status
  sudo $DEST/zima-location.sh rollback /DATA/Media

Pick a NATIVE Linux fs disk (ext4/btrfs/xfs). exFAT/NTFS are rejected. See README.
Optional web UI (needs python3, localhost-only by default):
  sudo $DEST/ui/install-ui.sh 9797
EOF
