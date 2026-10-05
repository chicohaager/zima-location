#!/bin/bash
# Installs the zima-location web UI as a host systemd service (python3 stdlib server).
# Requires python3 (the CLI itself does not). Usage: sudo /etc/zima-location/ui/install-ui.sh [port]
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
if ! [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "ERROR: port must be 1-65535"; exit 1
fi
[ -f "$DEST/zima-location.sh" ] || { echo "ERROR: install the CLI first (../install.sh)."; exit 1; }
[ -x "$PY" ] || { echo "ERROR: python3 is required for the UI (CLI works without it)."; exit 1; }

echo "Deploying UI to $UI (bind $ZL_BIND) ..."
mkdir -p "$UI"; chown root:root "$DEST" "$UI"; chmod 0755 "$DEST" "$UI"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Run from /etc/zima-location/ui (install.sh put the files there) -> source == dest, nothing to copy.
if [ "$HERE" != "$UI" ]; then
  cp "$HERE/index.html" "$UI/index.html"
  cp "$HERE/server.py"  "$UI/server.py"
fi
chown root:root "$UI/index.html" "$UI/server.py"; chmod 0755 "$UI/server.py"; chmod 0644 "$UI/index.html"

# Token in a root-only 0600 file: the unit file is world-readable (0644) and an inline
# Environment= shows up in 'systemctl show' for every local user.
ENVF="$DEST/ui.env"
( umask 077; { echo "ZL_BIND=$ZL_BIND"; [ -z "$ZL_TOKEN" ] || echo "ZL_TOKEN=$ZL_TOKEN"; } > "$ENVF" )
chown root:root "$ENVF"; chmod 0600 "$ENVF"

{
  echo "[Unit]"
  echo "Description=zima-location web UI (python3)"
  echo "After=network.target"
  echo ""
  echo "[Service]"
  echo "EnvironmentFile=$ENVF"
  echo "ExecStart=$PY $UI/server.py $PORT"
  echo "Restart=on-failure"
  echo ""
  echo "[Install]"
  echo "WantedBy=multi-user.target"
} > "$UNIT"

systemctl daemon-reload
systemctl enable zima-location-ui.service
# restart, not 'enable --now': a re-run with a new bind/token must reach the running server.
systemctl restart zima-location-ui.service

case "$ZL_BIND" in 127.0.0.1|localhost|::1) LOCAL_ONLY=1;; *) LOCAL_ONLY=0;; esac
if [ "$LOCAL_ONLY" = 1 ]; then
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
