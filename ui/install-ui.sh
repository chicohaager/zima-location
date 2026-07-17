#!/bin/bash
# Installs the zima-location web UI as a host systemd service (python3 stdlib server).
# Requires python3 on the host (the CLI itself does not). Usage: sudo ./install-ui.sh [port]
set -euo pipefail
PORT="${1:-9797}"
DEST="/DATA/AppData/zima-location"
UI="$DEST/ui"
UNIT="/etc/systemd/system/zima-location-ui.service"
PY="$(command -v python3 || echo /usr/bin/python3)"

[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./install-ui.sh"; exit 1; }
[ -f "$DEST/zima-location.sh" ] || { echo "ERROR: install the CLI first (../install.sh)."; exit 1; }
[ -x "$PY" ] || { echo "ERROR: python3 is required for the UI (CLI works without it)."; exit 1; }

echo "Deploying UI to $UI ..."
mkdir -p "$UI"
cp "$(dirname "$0")/index.html" "$UI/index.html"
cp "$(dirname "$0")/server.py"  "$UI/server.py"
chmod 0755 "$UI/server.py"

cat > "$UNIT" <<EOF
[Unit]
Description=zima-location web UI (python3)
After=network.target

[Service]
ExecStart=$PY $UI/server.py $PORT
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now zima-location-ui.service

IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
cat <<EOF

✅ UI running on port $PORT.
   http://${IP:-<host-ip>}:$PORT/

⚠️  Security: this backend runs as ROOT and is UNAUTHENTICATED. Anyone who can
    reach the port can redirect storage. Expose only on a trusted LAN (open the
    ZimaOS firewall port deliberately), or keep it localhost-only.
    Stop it with:  sudo systemctl disable --now zima-location-ui.service
EOF
