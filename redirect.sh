#!/bin/bash
# zima-location redirect helper — resolves UUID -> live mountpoint at boot, then bind-mounts.
# Written by zima-location.sh to /etc/zima-location/redirect.sh (root-only) and invoked by the
# per-anchor systemd unit. This repo copy is reference only; `set` always rewrites the live one.
# Letter-shift-safe: never hardcodes /dev/sdX or /media/sdX — always resolves via the disk UUID.
set -euo pipefail
ANCHOR="${1:?anchor}"; UUID="${2:?uuid}"; SUB="${3:-Media}"
log(){ echo "[zima-location] $*"; }

# Resolve UUID -> current root mountpoint (whatever letter the automounter assigned this boot).
# Only FSROOT "/" entries count: a bind of a subdir (another anchor on the same disk) carries
# the same UUID and may be listed first once the original mount moved.
# Retry up to 60s in case the disk is mounted late.
MP=""
for _ in $(seq 1 60); do
  MP="$(findmnt -rno TARGET,FSROOT -S UUID="$UUID" 2>/dev/null \
        | awk -v a="$ANCHOR" '$2=="/" && $1!=a {print $1; exit}' || true)"
  MP="$(printf '%b' "$MP")"
  [ -n "$MP" ] && break
  sleep 1
done
[ -n "$MP" ] || { log "FATAL: UUID $UUID not mounted after 60s — anchor $ANCHOR left unbound"; exit 1; }

SRC="$MP/$SUB"
# chmod only on creation: never loosen an existing target dir's permissions on every boot.
if [ ! -d "$SRC" ]; then mkdir -p "$SRC"; chmod 0777 "$SRC"; fi
mkdir -p "$ANCHOR"
# Fresh re-bind (handles a changed letter/source); idempotent on re-run. A bind whose disk
# vanished (USB reset) cannot be unmounted normally -> detach it lazily.
if mountpoint -q "$ANCHOR"; then umount "$ANCHOR" 2>/dev/null || umount -l "$ANCHOR"; fi
mount --bind "$SRC" "$ANCHOR"
log "bound: $ANCHOR -> $SRC (UUID $UUID @ $MP)"
