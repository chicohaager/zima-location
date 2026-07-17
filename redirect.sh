#!/bin/bash
# zima-location redirect helper — resolves UUID -> live mountpoint at boot, then bind-mounts.
# Installed to /DATA/AppData/zima-location/redirect.sh and invoked by the per-anchor systemd unit.
# Letter-shift-safe: never hardcodes /dev/sdX or /media/sdX — always resolves via the disk UUID.
set -euo pipefail
ANCHOR="${1:?anchor}"; UUID="${2:?uuid}"; SUB="${3:-Media}"
log(){ echo "[zima-location] $*"; }

# Resolve UUID -> current mountpoint (whatever letter the automounter assigned this boot).
# Retry up to 60s in case the disk is mounted late.
MP=""
for _ in $(seq 1 60); do
  MP="$(findmnt -rno TARGET -S UUID="$UUID" 2>/dev/null | head -1 || true)"
  [ -n "$MP" ] && break
  sleep 1
done
[ -n "$MP" ] || { log "FATAL: UUID $UUID not mounted after 60s — anchor $ANCHOR left empty"; exit 1; }

SRC="$MP/$SUB"
mkdir -p "$SRC"; chmod 0777 "$SRC" 2>/dev/null || true
mkdir -p "$ANCHOR"
# Fresh re-bind (handles a changed letter/source); idempotent on re-run.
if mountpoint -q "$ANCHOR"; then umount "$ANCHOR" 2>/dev/null || true; fi
mount --bind "$SRC" "$ANCHOR"
log "bound: $ANCHOR -> $SRC (UUID $UUID @ $MP)"
