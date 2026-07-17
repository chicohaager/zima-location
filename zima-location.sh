#!/bin/bash
# zima-location.sh v2 (UUID-hardened) — globaler Storage-Redirect für ZimaOS-Apps
#
# Biegt einen App-Anker (z.B. /DATA/Media) reboot-fest + LETTER-SHIFT-SICHER auf ein
# Unterverzeichnis einer per UUID identifizierten Platte um. Kernidee: KEIN Buchstaben-
# pfad in der Unit — ein oneshot-Service löst die UUID zur Boot-Zeit via `findmnt` auf
# und bindet dann. Selbstheilend, wenn der Automounter der Platte einen anderen
# Buchstaben gibt (§2.4-Zeitbombe entschärft). Kämpft NICHT gegen den Automounter.
#
# Usage:
#   zima-location.sh list-disks                       # ext4/btrfs-Platten + UUIDs
#   zima-location.sh status
#   zima-location.sh set <anchor> <uuid> [subdir=Media]
#   zima-location.sh rollback <anchor>
#
# Muss als root laufen.
set -euo pipefail

VERSION="0.2.1"
# Root-only location (NOT world-writable /DATA/AppData, which ZimaOS ships 0777 -> local privesc).
HELPER_DIR="/etc/zima-location"
HELPER="$HELPER_DIR/redirect.sh"
UNIT_DIR="/etc/systemd/system"
TAG="zima-location"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$TAG] $*"; }
need_root(){ [ "$(id -u)" = 0 ] || die "muss als root laufen (sudo)."; }
svc_name(){ echo "${TAG}-$(systemd-escape -p "$1").service"; }   # /DATA/Media -> zima-location-DATA-Media.service

# ---- Input-Validierung (verhindert systemd-Unit-/Shell-Injection über anchor/uuid/sub) ----
validate_inputs(){
  local a="$1" u="$2" s="$3"
  [[ "$a" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "ungültiger anchor: absoluter Pfad, nur [A-Za-z0-9._/-]"
  case "$a" in *..*) die "anchor darf kein '..' enthalten";; esac
  [[ "$u" =~ ^[0-9A-Fa-f-]+$ ]]     || die "ungültige UUID"
  [[ "$s" =~ ^[A-Za-z0-9._/-]+$ ]]  || die "ungültiges subdir: nur [A-Za-z0-9._/-]"
  case "$s" in /*|*..*) die "subdir muss relativ sein, kein '..'";; esac
}

# ---- Helper-Script (resolver+bind) IMMER kanonisch schreiben (kein Vertrauen in on-disk-File), root-only ----
install_helper(){
  mkdir -p "$HELPER_DIR"; chown root:root "$HELPER_DIR" 2>/dev/null || true; chmod 0755 "$HELPER_DIR"
  cat > "$HELPER" <<'HELPER_EOF'
#!/bin/bash
# zima-location redirect helper — resolves UUID->live mountpoint at boot, then bind-mounts.
set -euo pipefail
ANCHOR="${1:?anchor}"; UUID="${2:?uuid}"; SUB="${3:-Media}"
log(){ echo "[zima-location] $*"; }
MP=""
for _ in $(seq 1 60); do
  MP="$(findmnt -rno TARGET -S UUID="$UUID" 2>/dev/null | head -1 || true)"
  [ -n "$MP" ] && break
  sleep 1
done
[ -n "$MP" ] || { log "FATAL: UUID $UUID nach 60s nicht gemountet — Anker $ANCHOR bleibt leer"; exit 1; }
SRC="$MP/$SUB"
mkdir -p "$SRC"; chmod 0777 "$SRC" 2>/dev/null || true
mkdir -p "$ANCHOR"
# frisch neu binden (fängt Letter-/Source-Wechsel ab); idempotent bei Re-Run
if mountpoint -q "$ANCHOR"; then umount "$ANCHOR" 2>/dev/null || true; fi
mount --bind "$SRC" "$ANCHOR"
log "gebunden: $ANCHOR -> $SRC (UUID $UUID @ $MP)"
HELPER_EOF
  chown root:root "$HELPER" 2>/dev/null || true; chmod 0755 "$HELPER"
}

validate_uuid(){
  local uuid="$1" fstype
  fstype="$(blkid -U "$uuid" 2>/dev/null | xargs -r blkid -o value -s TYPE 2>/dev/null || true)"
  [ -z "$fstype" ] && fstype="$(lsblk -rno FSTYPE,UUID | awk -v u="$uuid" '$2==u{print $1}' | head -1)"
  [ -n "$fstype" ] || die "UUID $uuid nicht gefunden (blkid/lsblk)."
  case "$fstype" in
    ext4|ext3|btrfs|xfs) : ;;
    exfat|ntfs|vfat|fuseblk) die "FS '$fstype' untauglich für Container-uid (chown scheitert). Native Linux-FS wählen." ;;
    *) log "WARN: unbekanntes FS '$fstype' — fortfahren auf eigene Gefahr." ;;
  esac
  echo "$fstype"
}

cmd_list_disks(){
  echo "=== ext4/btrfs-Platten (für 'set <anchor> <uuid>') ==="
  blkid 2>/dev/null | grep -iE 'TYPE="(ext4|ext3|btrfs|xfs)"' | grep -E "/dev/sd|/dev/nvme" | \
  while read -r line; do
    local dev uuid label mp
    dev="${line%%:*}"
    uuid="$(echo "$line" | grep -oE 'UUID="[^"]+"' | head -1 | cut -d'"' -f2)"
    label="$(echo "$line" | grep -oE 'LABEL="[^"]+"' | head -1 | cut -d'"' -f2)"
    mp="$(findmnt -rno TARGET -S UUID="$uuid" 2>/dev/null | head -1)"
    printf "  %-12s UUID=%s  LABEL=%-10s  @ %s\n" "$dev" "$uuid" "${label:-–}" "${mp:-nicht gemountet}"
  done
}

cmd_status(){
  echo "=== ZimaLocation Status ==="
  local found=0
  for u in "$UNIT_DIR"/${TAG}-*.service; do
    [ -e "$u" ] || continue
    found=1
    local uname; uname="$(basename "$u")"
    local exec; exec="$(awk -F'redirect.sh ' '/ExecStart=/{print $2}' "$u")"
    local active; active="$(systemctl is-active "$uname" 2>/dev/null || true)"
    local enabled; enabled="$(systemctl is-enabled "$uname" 2>/dev/null || true)"
    local anchor="${exec%% *}"
    printf "  %-22s [active:%s enabled:%s]\n" "$uname" "$active" "$enabled"
    printf "     args: %s\n" "$exec"
    if [ -n "$anchor" ] && mountpoint -q "$anchor"; then
      printf "     %s -> %s (mountpoint: JA)\n" "$anchor" "$(findmnt -rno SOURCE "$anchor" | head -1)"
    else
      printf "     %s (mountpoint: NEIN)\n" "$anchor"
    fi
  done
  [ "$found" = 0 ] && echo "  (kein ZimaLocation-Redirect installiert)"
}

cmd_set(){
  local anchor="${1:-}" uuid="${2:-}" sub="${3:-Media}"
  [ -n "$anchor" ] && [ -n "$uuid" ] || die "usage: set <anchor> <uuid> [subdir=Media]"
  validate_inputs "$anchor" "$uuid" "$sub"
  local fstype; fstype="$(validate_uuid "$uuid")"
  local mp; mp="$(findmnt -rno TARGET -S UUID="$uuid" 2>/dev/null | head -1)"
  [ -n "$mp" ] || die "UUID $uuid derzeit nicht gemountet — Platte einstecken/mounten."
  log "Ziel: UUID $uuid ($fstype) @ $mp, subdir '$sub' -> Anker $anchor"

  install_helper
  local src="$mp/$sub"
  mkdir -p "$src"; chmod 0777 "$src" 2>/dev/null || true
  mkdir -p "$anchor"

  # Migration: Anker enthält Daten & ist kein Mountpoint -> nach src spiegeln + Backup
  if [ -n "$(ls -A "$anchor" 2>/dev/null)" ] && ! mountpoint -q "$anchor"; then
    log "Anker enthält Daten -> rsync nach $src (Backup: ${anchor}.pre-zl)"
    rsync -aHAX --info=stats1 "$anchor"/ "$src"/
    cp -a "$anchor" "${anchor}.pre-zl" 2>/dev/null || true
  fi

  local uname; uname="$(svc_name "$anchor")"
  local unit="$UNIT_DIR/$uname"
  log "Schreibe Service $unit"
  cat > "$unit" <<EOF
[Unit]
Description=ZimaLocation UUID redirect ($TAG): $anchor -> UUID $uuid /$sub
Documentation=zima-location v2 (UUID-hardened, letter-shift-safe)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER $anchor $uuid $sub
ExecStop=/bin/sh -c 'mountpoint -q $anchor && umount $anchor || true'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$uname"

  log "Verifikation:"
  mountpoint -q "$anchor" || die "  $anchor kein Mountpoint (journalctl -u $uname)."
  log "  OK: $anchor ist Mountpoint -> $(findmnt -rno SOURCE "$anchor" | head -1)"
  local probe=".zl-probe-$$"
  echo "zima-location-uuid-ok" > "$anchor/$probe"
  [ "$(cat "$src/$probe" 2>/dev/null)" = "zima-location-uuid-ok" ] || die "  Write-Through-Test fehlgeschlagen."
  rm -f "$anchor/$probe"
  log "  OK: Write über Anker landet real auf UUID-Ziel (read-through bestätigt)."
  log "FERTIG. Redirect aktiv, reboot-fest (enabled) + letter-shift-sicher (UUID-Resolution zur Boot-Zeit)."
}

cmd_rollback(){
  local anchor="${1:-}"; [ -n "$anchor" ] || die "usage: rollback <anchor>"
  local uname; uname="$(svc_name "$anchor")"
  log "Rollback $anchor (Service $uname)"
  systemctl disable --now "$uname" 2>/dev/null || true
  umount "$anchor" 2>/dev/null || true
  [ -e "$UNIT_DIR/$uname" ] && rm -f "$UNIT_DIR/$uname"
  systemctl daemon-reload
  mountpoint -q "$anchor" && die "  $anchor noch Mountpoint — manuell prüfen." || true
  log "  OK: Redirect entfernt. Daten auf Ziel-Disk bleiben; ggf. ${anchor}.pre-zl zurückspielen."
}

usage(){ cat <<EOF
zima-location v$VERSION — reboot-safe, letter-shift-proof storage redirect for ZimaOS apps

Usage:
  zima-location list-disks                       list ext4/btrfs disks + UUIDs
  zima-location status                           show active redirects
  zima-location set <anchor> <uuid> [subdir]     redirect <anchor> to <uuid>/<subdir> (default subdir: Media)
  zima-location rollback <anchor>                remove a redirect (data on target disk kept)
  zima-location version

Examples:
  sudo zima-location list-disks
  sudo zima-location set /DATA/Media 5a29c250-... Media
  sudo zima-location rollback /DATA/Media
EOF
}

case "${1:-}" in
  list-disks) need_root; cmd_list_disks ;;
  status)     need_root; cmd_status ;;
  set)        need_root; cmd_set "${2:-}" "${3:-}" "${4:-}" ;;
  rollback)   need_root; cmd_rollback "${2:-}" ;;
  version|-v|--version) echo "zima-location v$VERSION" ;;
  help|-h|--help|"") usage ;;
  *) usage; exit 1 ;;
esac
