#!/bin/bash
# Installs the zima-location web UI as a host systemd service (python3 stdlib server).
# Requires python3 (the CLI itself does not). Usage: sudo ./install-ui.sh [port]
#
# Binds 127.0.0.1 by default. To expose on the LAN (at your own risk), set ZL_BIND=0.0.0.0
# and ideally ZL_TOKEN=<secret> before running. Reach a localhost-only UI via an SSH tunnel:
#   ssh -L 9797:localhost:9797 <host>
set -euo pipefail
PORT="${1:-9797}"
DEST="/etc/zima-location"   # root-only
UI="$DEST/ui"
UNIT="/etc/systemd/system/zima-location-ui.service"
PY="$(command -v python3 || echo /usr/bin/python3)"
ZL_BIND="${ZL_BIND:-127.0.0.1}"
ZL_TOKEN="${ZL_TOKEN:-}"

[ "$(id -u)" = 0 ] || { echo "Please run as root: sudo ./install-ui.sh"; exit 1; }
[ -f "$DEST/zima-location.sh" ] || { echo "ERROR: install the CLI first (../install.sh)."; exit 1; }
[ -x "$PY" ] || { echo "ERROR: python3 is required for the UI (CLI works without it)."; exit 1; }

echo "Deploying UI to $UI (bind $ZL_BIND) ..."
mkdir -p "$UI"; chown root:root "$DEST" "$UI"; chmod 0755 "$DEST" "$UI"
cp "$(dirname "$0")/index.html" "$UI/index.html"
cp "$(dirname "$0")/server.py"  "$UI/server.py"
chown root:root "$UI/index.html" "$UI/server.py"; chmod 0755 "$UI/server.py"; chmod 0644 "$UI/index.html"

{
  echo "[Unit]"
  echo "Description=zima-location web UI (python3)"
  echo "After=network.target"
  echo ""
  echo "[Service]"
  echo "Environment=ZL_BIND=$ZL_BIND"
  [ -n "$ZL_TOKEN" ] && echo "Environment=ZL_TOKEN=$ZL_TOKEN"
  echo "ExecStart=$PY $UI/server.py $PORT"
  echo "Restart=on-failure"
  echo ""
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > "$UNIT"

systemctl daemon-reload
systemctl enable --now zima-location-ui.service

if [ "$ZL_BIND" = "127.0.0.1" ]; then
  cat <<EOF

✅ UI running on 127.0.0.1:$PORT (localhost only).
   Reach it via an SSH tunnel:  ssh -L $PORT:localhost:$PORT <this-host>  then open http://localhost:$PORT/
   Stop it:  sudo systemctl disable --now zima-location-ui.service
EOF
else
  # '|| true': 'ip route get' liefert 2 ohne Default-Route (Host offline) -> pipefail
  # wuerde den Installer hier abbrechen, obwohl unten '${IP:-<host-ip>}' den Leerfall kann.
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || true)"
  cat <<EOF

✅ UI running on $ZL_BIND:$PORT  ->  http://${IP:-<host-ip>}:$PORT/
⚠️  Exposed beyond localhost. This backend runs as ROOT. Open the ZimaOS firewall port
    deliberately, keep it on a trusted LAN, and set ZL_TOKEN for a shared secret.
    Stop it:  sudo systemctl disable --now zima-location-ui.service
EOF
fi
