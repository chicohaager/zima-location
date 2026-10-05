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
#   zima-location.sh list-disks                       # ext4/btrfs/xfs-Platten + UUIDs
#   zima-location.sh status
#   zima-location.sh set <anchor> <uuid> [subdir=Media]
#   zima-location.sh rollback <anchor>
#   zima-location.sh heal <anchor>                    # von udev angestoßen: Anker neu binden, falls kaputt
#
# Muss als root laufen.
set -euo pipefail
# udev/systemd starten 'heal' mit minimalem PATH; angehängt, damit Tests ihre Fakes vorn behalten.
PATH="$PATH:/usr/sbin:/usr/bin:/sbin:/bin"

VERSION="0.3.0"
# Root-only location (NOT world-writable /DATA/AppData, which ZimaOS ships 0777 -> local privesc).
HELPER_DIR="/etc/zima-location"
HELPER="$HELPER_DIR/redirect.sh"
UNIT_DIR="/etc/systemd/system"
TAG="zima-location"
UI_UNIT="$TAG-ui.service"
# Mountpunkte der ZimaOS-Systemplatte (casaos-boot/-overlay/-data). Eine Partition, die einen
# davon trägt, ist nie ein Redirect-Ziel: der Anker landete wieder auf der Systemplatte.
SYSTEM_MPS="/ /boot /mnt/boot /mnt/overlay /DATA /var/lib/casaos_data /media"

die(){ echo "ERROR: $*" >&2; exit 1; }
log(){ echo "[$TAG] $*"; }
warn(){ echo "[$TAG] WARN: $*" >&2; }
need_root(){ [ "$(id -u)" = 0 ] || die "muss als root laufen (sudo)."; }
svc_name(){ echo "${TAG}-$(systemd-escape -p "$1").service"; }   # /DATA/Media -> zima-location-DATA-Media.service
heal_name(){ echo "${TAG}-heal-$(systemd-escape -p "$1").service"; }
rule_name(){ echo "99-${TAG}-$(systemd-escape -p "$1").rules"; }

# Root-Mountpunkt einer UUID. Nur Einträge mit FSROOT "/" zählen: ein Bind eines Unterordners
# (ein Anker, z.B. /DATA/Media = /dev/sda[/Media]) trägt dieselbe UUID und steht vorn, sobald
# der Original-Mount entfernt/neu eingehängt wurde -> ein zweiter Anker derselben Platte
# landete sonst in /DATA/Media/<subdir> (tests/ns-cases.sh N4).
# $2 = Anker, der selbst nie als Quelle gilt. findmnt -r maskiert Leerzeichen als \x20.
uuid_mp(){
  local t
  t="$(findmnt -rno TARGET,FSROOT -S UUID="$1" 2>/dev/null \
        | awk -v a="${2:-}" '$2=="/" && $1!=a {print $1; exit}' || true)"
  printf '%b' "$t"
}

# Gerät hinter einem Pfad, ohne [subpath]-Anhang ("/dev/sda[/Media]" -> "/dev/sda").
path_dev(){ findmnt -rno SOURCE "$1" 2>/dev/null | head -1 | sed 's/\[.*//' || true; }

# ---- Input-Validierung (verhindert systemd-Unit-/Shell-Injection über anchor/uuid/sub) ----
validate_anchor(){
  local a="$1"
  [[ "$a" =~ ^/DATA/[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] \
    || die "ungültiger anchor: muss unter /DATA/ liegen (z.B. /DATA/Media), nur [A-Za-z0-9._/-], kein /DATA/.<versteckt>"
  case "$a" in *..*|*//*|*/) die "anchor: kein '..', kein '//', kein abschließender '/'";; esac
}
validate_inputs(){
  local a="$1" u="$2" s="$3"
  validate_anchor "$a"
  [[ "$u" =~ ^[0-9A-Fa-f-]+$ ]] || die "ungültige UUID"
  [[ "$s" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "ungültiges subdir: relativ, beginnt mit [A-Za-z0-9], nur [A-Za-z0-9._/-]"
  case "$s" in *..*|*//*) die "subdir: kein '..', kein '//'";; esac
}

# ---- Helper-Script (resolver+bind) IMMER kanonisch schreiben (kein Vertrauen in on-disk-File), root-only ----
# Inhalt identisch mit redirect.sh im Repo (tests/run.sh prüft das).
install_helper(){
  mkdir -p "$HELPER_DIR"; chown root:root "$HELPER_DIR" 2>/dev/null || true; chmod 0755 "$HELPER_DIR"
  cat > "$HELPER" <<'HELPER_EOF'
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
HELPER_EOF
  chown root:root "$HELPER" 2>/dev/null || true; chmod 0755 "$HELPER"
}

validate_uuid(){
  local uuid="$1" fstype
  local dev; dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  # Kein xargs: ZimaOS liefert keins aus (gemessen 1.7.1 + 1.8.0-beta1) -> die alte Pipe
  # 'blkid -U | xargs blkid' lief dort nie, es griff immer der lsblk-Fallback.
  fstype=""
  [ -n "$dev" ] && fstype="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
  # Fallback: bei mdadm-RAID tragen die Mitgliedsplatten dieselbe UUID wie das Array
  # (gemessen nas-test: sda/sdb linux_raid_member, md0 btrfs) -> Mitglieder überspringen.
  [ -z "$fstype" ] && fstype="$(lsblk -rno FSTYPE,UUID 2>/dev/null \
        | awk -v u="$uuid" '$2==u && $1!="linux_raid_member"{print $1; exit}' || true)"
  [ -n "$fstype" ] || die "UUID $uuid nicht gefunden (blkid/lsblk)."
  case "$fstype" in
    ext4|ext3|btrfs|xfs) : ;;
    exfat|ntfs|ntfs3|vfat|fuseblk) die "FS '$fstype' untauglich für Container-uid (chown scheitert). Native Linux-FS wählen." ;;
    # WARN nach stderr: stdout dieser Funktion IST der Rückgabewert (fstype="$(validate_uuid …)").
    *) warn "unbekanntes FS '$fstype' — fortfahren auf eigene Gefahr." ;;
  esac
  echo "$fstype"
}

# 0 = Partition trägt die ZimaOS-Systemplatte (Label casaos-* oder Gerät hinter einem SYSTEM_MPS).
is_system_dev(){
  local dev="$1" label="$2" m
  case "$label" in casaos-*) return 0;; esac
  for m in $SYSTEM_MPS; do
    [ "$(path_dev "$m")" = "$dev" ] && return 0
  done
  return 1
}

cmd_list_disks(){
  echo "=== ext4/btrfs/xfs-Datenplatten (für 'set <anchor> <uuid>') ==="
  local shown=0 line dev uuid label mp
  # '|| true': ohne Treffer liefert grep 1 -> pipefail bräche cmd_list_disks hier ab.
  while read -r line; do
    [ -n "$line" ] || continue
    dev="${line%%:*}"
    # '|| true' zwingend: ohne LABEL/UUID-Treffer liefert grep 1 -> set -o pipefail
    # würde die Zuweisung fehlschlagen lassen und die Liste mittendrin abbrechen.
    uuid="$(echo "$line" | grep -oE ' UUID="[^"]+"' | head -1 | cut -d'"' -f2 || true)"
    label="$(echo "$line" | grep -oE ' LABEL="[^"]+"' | head -1 | cut -d'"' -f2 || true)"
    [ -n "$uuid" ] || continue
    is_system_dev "$dev" "$label" && continue
    mp="$(uuid_mp "$uuid")"
    printf "  %-14s UUID=%s  LABEL=%-10s  @ %s\n" "$dev" "$uuid" "${label:-–}" "${mp:-nicht gemountet}"
    shown=$((shown+1))
  done < <(blkid 2>/dev/null | grep -iE 'TYPE="(ext4|ext3|btrfs|xfs)"' | grep -E "^/dev/(sd|nvme|md|mmcblk)" || true)
  [ "$shown" -gt 0 ] || echo "  (keine geeignete Datenplatte gefunden — exFAT/NTFS und die Systemplatte sind ausgeblendet)"
}

# Zustand eines aktiven Ankers: OK | Zielplatte fehlt | veralteter Bind | nicht lesbar.
anchor_health(){
  local anchor="$1" uuid="$2" cur bound
  cur="$(blkid -U "$uuid" 2>/dev/null || true)"
  bound="$(path_dev "$anchor")"
  [ -n "$cur" ] || { echo "FEHLER: Zielplatte UUID $uuid fehlt (abgezogen/USB-Reset?) — Anker zeigt ins Leere"; return; }
  if [ -n "$bound" ] && [ "$bound" != "$cur" ]; then
    echo "FEHLER: veralteter Bind ($bound), Platte jetzt $cur — 'systemctl restart $(svc_name "$anchor")'"; return
  fi
  if ! timeout 5 ls -A "$anchor" >/dev/null 2>&1; then
    echo "FEHLER: Anker nicht lesbar (I/O-Fehler?) — dmesg prüfen"; return
  fi
  echo "OK"
}

cmd_status(){
  echo "=== ZimaLocation Status ==="
  local found=0 u uname exec active enabled anchor uuid
  for u in "$UNIT_DIR/$TAG"-*.service; do
    [ -e "$u" ] || continue
    uname="$(basename "$u")"
    [ "$uname" = "$UI_UNIT" ] && continue
    case "$uname" in "$TAG"-heal-*) continue;; esac
    found=1
    exec="$(awk -F'redirect.sh ' '/^ExecStart=/{print $2}' "$u")"
    active="$(systemctl is-active "$uname" 2>/dev/null || true)"
    enabled="$(systemctl is-enabled "$uname" 2>/dev/null || true)"
    anchor="$(echo "$exec" | awk '{print $1}')"
    uuid="$(echo "$exec" | awk '{print $2}')"
    printf "  %-30s [active:%s enabled:%s]\n" "$uname" "$active" "$enabled"
    printf "     args: %s\n" "$exec"
    if [ -n "$anchor" ] && mountpoint -q "$anchor"; then
      printf "     %s -> %s (mountpoint: JA)\n" "$anchor" "$(findmnt -rno SOURCE "$anchor" | head -1 || true)"
      printf "     Zustand: %s\n" "$(anchor_health "$anchor" "$uuid")"
    else
      printf "     %s (mountpoint: NEIN)\n" "$anchor"
    fi
    if [ -n "$anchor" ] && [ -e "/etc/udev/rules.d/$(rule_name "$anchor")" ]; then
      printf "     Auto-Heal: an (/etc/udev/rules.d/%s)\n" "$(rule_name "$anchor")"
    else
      printf "     Auto-Heal: aus — 'set' erneut ausführen, um es einzurichten\n"
    fi
  done
  [ "$found" = 0 ] && echo "  (kein ZimaLocation-Redirect installiert)"
  return 0
}

# Nicht-belegter Backup-Name neben dem Anker (zweiter Lauf überschreibt nie ein altes Backup).
backup_name(){
  local b="${1}.pre-zl"
  [ -e "$b" ] && b="${1}.pre-zl.$(date +%Y%m%d-%H%M%S)"
  echo "$b"
}

cmd_set(){
  local anchor="${1:-}" uuid="${2:-}" sub="${3:-Media}"
  if [ -z "$anchor" ] || [ -z "$uuid" ]; then die "usage: set <anchor> <uuid> [subdir=Media]"; fi
  validate_inputs "$anchor" "$uuid" "$sub"
  local fstype; fstype="$(validate_uuid "$uuid")"
  local dev label
  dev="$(blkid -U "$uuid" 2>/dev/null || true)"
  label="$(blkid -o value -s LABEL "$dev" 2>/dev/null || true)"
  [ -n "$dev" ] && is_system_dev "$dev" "$label" && die "UUID $uuid ist die ZimaOS-Systemplatte ($dev) — Datenplatte wählen."
  local mp; mp="$(uuid_mp "$uuid" "$anchor")"
  [ -n "$mp" ] || die "UUID $uuid derzeit nicht gemountet — Platte einstecken/mounten."
  local src="$mp/$sub"
  case "$src/" in "$anchor"/*) die "Ziel $src liegt im Anker $anchor (Schleife).";; esac
  case "$anchor/" in "$src"/*) die "Anker $anchor liegt im Ziel $src (Schleife).";; esac
  log "Ziel: UUID $uuid ($fstype) @ $mp, subdir '$sub' -> Anker $anchor"

  install_helper
  if [ ! -d "$src" ]; then mkdir -p "$src"; chmod 0777 "$src"; fi
  mkdir -p "$anchor"

  local uname; uname="$(svc_name "$anchor")"
  local unit="$UNIT_DIR/$uname"
  # Ab hier nimmt jeder Abbruch (die, set -e) das 'set' zurück — auch ein Fehler beim Schreiben
  # der Unit, nachdem der Anker schon weggesichert ist. Gab es schon einen Redirect für diesen
  # Anker, wird dessen Unit wiederhergestellt statt gelöscht. Globale Variablen, weil der
  # EXIT-Trap außerhalb dieser Funktion läuft.
  UNDO_ANCHOR="$anchor"; UNDO_UNIT="$uname"; UNDO_BACKUP=""
  UNDO_PREV="$(cat "$unit" 2>/dev/null || true)"
  trap 'undo_set' EXIT

  # Migration: Anker enthält Daten & ist kein Mountpoint -> nach src spiegeln, Original wegbenennen.
  # mv statt cp: ein Backup per Kopie verdoppelte die Daten auf der (vollen) Systemplatte.
  if [ -n "$(ls -A "$anchor" 2>/dev/null)" ] && ! mountpoint -q "$anchor"; then
    UNDO_BACKUP="$(backup_name "$anchor")"
    log "Anker enthält Daten -> rsync nach $src (Original bleibt als $UNDO_BACKUP)"
    rsync -aHAX --info=stats1 "$anchor"/ "$src"/
    mv -T "$anchor" "$UNDO_BACKUP"
    mkdir -p "$anchor"
  fi

  log "Schreibe Service $unit"
  # Before=docker.service: Container starten erst, wenn der Anker gebunden ist — sonst schreiben
  # Apps beim Boot in den leeren Ordner auf der Systemplatte, den der Bind danach verdeckt.
  # Direkt gegen docker.service, nicht gegen ein Target (gemessen ZimaOS 1.7.1: docker.service
  # hängt After=zimaos-local-storage-first.service, kein Zyklus mit uns).
  cat > "$unit" <<EOF
[Unit]
Description=ZimaLocation UUID redirect ($TAG): $anchor -> UUID $uuid /$sub
Documentation=https://github.com/chicohaager/zima-location
After=local-fs.target
Wants=local-fs.target
Before=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$HELPER $anchor $uuid $sub
ExecStop=/bin/sh -c 'mountpoint -q $anchor && umount $anchor || true'

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$uname"
  # restart statt 'enable --now': bei einem erneuten 'set' (andere Platte) ist die Unit schon
  # active (RemainAfterExit) und '--now' täte nichts -> der alte Bind bliebe stehen.
  systemctl restart "$uname" || die "  Service-Start fehlgeschlagen (journalctl -u $uname)."

  log "Verifikation:"
  mountpoint -q "$anchor" || die "  $anchor kein Mountpoint (journalctl -u $uname)."
  log "  OK: $anchor ist Mountpoint -> $(findmnt -rno SOURCE "$anchor" | head -1 || true)"
  local probe=".zl-probe-$$"
  echo "zima-location-uuid-ok" > "$anchor/$probe"
  if [ "$(cat "$src/$probe" 2>/dev/null)" != "zima-location-uuid-ok" ]; then
    rm -f "$anchor/$probe"
    die "  Write-Through-Test fehlgeschlagen."
  fi
  rm -f "$anchor/$probe"
  install_heal "$anchor" "$uuid"
  trap - EXIT
  log "  OK: Write über Anker landet real auf UUID-Ziel (read-through bestätigt)."
  log "  OK: Auto-Heal eingerichtet (/etc/udev/rules.d/$(rule_name "$anchor"))."
  log "FERTIG. Redirect aktiv, reboot-fest (enabled) + letter-shift-sicher (UUID-Resolution zur Boot-Zeit)."
  log "Laufende Apps, die $anchor nutzen, einmal neu starten (docker restart <app>)."
}

# ---- Auto-Heal ----
# Taucht die Platte zur Laufzeit wieder auf (USB umgesteckt, Reset), bindet nichts den Anker
# neu — die Boot-Unit lief schon (gemessen nas-main, 05.10.2026: Anker blieb leer, bis 'set' lief).
# Die udev-Regel stößt deshalb eine Heal-Unit an. Nicht direkt aus der Regel mounten:
# systemd-udevd läuft mit PrivateMounts=yes (gemessen ZimaOS 1.7.1), der Mount käme beim Host
# nie an. RAID-Mitglieder tragen die UUID des Arrays (linux_raid_member) -> ausgeschlossen;
# md-Arrays melden sich per 'change' statt 'add'. Pfade fest ausgeschrieben, damit kein leerer
# Wert ein Löschen auf '/' umlenken kann.
install_heal(){
  local anchor="$1" uuid="$2" hname rname tmp
  hname="$(heal_name "$anchor")"; rname="$(rule_name "$anchor")"
  cat > "/etc/systemd/system/$hname" <<EOF
[Unit]
Description=ZimaLocation auto-heal ($TAG): $anchor
Documentation=https://github.com/chicohaager/zima-location

[Service]
Type=oneshot
ExecStart=$HELPER_DIR/zima-location.sh heal $anchor
EOF
  mkdir -p /etc/udev/rules.d
  # über Temp-Datei + mv: ein Abbruch lässt nie eine halbe Regel zurück
  tmp="$(mktemp "/etc/udev/rules.d/.${TAG}-XXXXXX")"
  cat > "$tmp" <<EOF
# zima-location auto-heal for $anchor (UUID $uuid) — written by 'zima-location.sh set'
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="$uuid", ENV{ID_FS_TYPE}!="linux_raid_member", RUN+="/usr/bin/systemctl --no-block start $hname"
EOF
  chmod 0644 "$tmp"; mv -f "$tmp" "/etc/udev/rules.d/$rname"
  systemctl daemon-reload
  udevadm control --reload 2>/dev/null || warn "udevadm control --reload fehlgeschlagen — Regel greift nach dem nächsten Boot."
}

remove_heal(){
  local anchor="$1"
  rm -f "/etc/udev/rules.d/$(rule_name "$anchor")" "/etc/systemd/system/$(heal_name "$anchor")"
  udevadm control --reload 2>/dev/null || true
}

# Von udev (über die Heal-Unit) angestoßen. Nur handeln, wenn der Anker wirklich kaputt ist —
# sonst baute jedes 'change'-Event einen gesunden Bind neu auf.
cmd_heal(){
  local anchor="${1:-}"; [ -n "$anchor" ] || die "usage: heal <anchor>"
  validate_anchor "$anchor"
  local uname; uname="$(svc_name "$anchor")"
  [ -e "$UNIT_DIR/$uname" ] || { log "heal $anchor: kein Redirect (mehr) — nichts zu tun."; return 0; }
  # Beim Boot erzeugt das Coldplug 'add'-Events; dort bindet die Boot-Unit selbst.
  case "$(systemctl is-system-running 2>/dev/null || true)" in
    initializing|starting) log "heal $anchor: System bootet noch — Boot-Unit ist zuständig."; return 0;;
  esac
  if [ "$(systemctl is-active "$uname" 2>/dev/null || true)" = activating ]; then
    log "heal $anchor: Unit startet bereits."; return 0
  fi
  local uuid h="nicht gebunden"
  uuid="$(awk -F'redirect.sh ' '/^ExecStart=/{print $2}' "$UNIT_DIR/$uname" | awk '{print $2}')"
  if mountpoint -q "$anchor"; then h="$(anchor_health "$anchor" "$uuid")"; fi
  if [ "$h" = OK ]; then log "heal $anchor: gesund — nichts zu tun."; return 0; fi
  log "heal $anchor: $h -> binde neu ($uname)."
  systemctl --no-block restart "$uname"
}

# EXIT-Trap eines abgebrochenen 'set': Unit weg, Bind lösen, weggesichertes Original zurück.
# Die rsync-Kopie auf dem Ziel bleibt liegen (nichts wird gelöscht).
UNDO_ANCHOR=""; UNDO_UNIT=""; UNDO_BACKUP=""; UNDO_PREV=""
undo_set(){
  local rc=$? anchor="$UNDO_ANCHOR" uname="$UNDO_UNIT" backup="$UNDO_BACKUP"
  trap - EXIT
  set +e   # jeder Rücknahme-Schritt soll laufen, auch wenn ein früherer scheitert
  [ -n "$anchor" ] || exit "$rc"
  echo "[$TAG] set abgebrochen — nehme Änderungen zurück ..." >&2
  systemctl disable --now "$uname" 2>/dev/null || true
  if mountpoint -q "$anchor"; then umount "$anchor" 2>/dev/null || umount -l "$anchor" 2>/dev/null || true; fi
  rm -f "$UNIT_DIR/$uname"
  if [ -n "$UNDO_PREV" ]; then
    printf '%s\n' "$UNDO_PREV" > "$UNIT_DIR/$uname"
    systemctl daemon-reload
    if systemctl restart "$uname"; then echo "[$TAG]   vorheriger Redirect wiederhergestellt." >&2
    else echo "[$TAG]   vorheriger Redirect: Unit zurückgeschrieben, Start scheiterte (journalctl -u $uname)." >&2; fi
  else
    systemctl daemon-reload || true
  fi
  if [ -n "$backup" ] && [ -d "$backup" ] && [ -z "$(ls -A "$anchor" 2>/dev/null)" ]; then
    rmdir "$anchor" && mv -T "$backup" "$anchor" && echo "[$TAG]   Original $anchor wiederhergestellt." >&2
  fi
  echo "[$TAG]   zurückgerollt (Kopie auf dem Ziel bleibt liegen)." >&2
  exit "$rc"
}

cmd_rollback(){
  local anchor="${1:-}"; [ -n "$anchor" ] || die "usage: rollback <anchor>"
  validate_anchor "$anchor"
  local uname; uname="$(svc_name "$anchor")"
  [ -e "$UNIT_DIR/$uname" ] || die "kein zima-location-Redirect für $anchor ($UNIT_DIR/$uname fehlt) — 'status' zeigt die aktiven."
  log "Rollback $anchor (Service $uname)"
  # Regel zuerst weg: ein udev-Event mitten im Rollback darf den Anker nicht wieder binden.
  remove_heal "$anchor"
  systemctl disable --now "$uname" 2>/dev/null || true
  if mountpoint -q "$anchor"; then umount "$anchor" 2>/dev/null || umount -l "$anchor" 2>/dev/null || true; fi
  rm -f "$UNIT_DIR/$uname"
  systemctl daemon-reload
  mountpoint -q "$anchor" && die "  $anchor noch Mountpoint — manuell prüfen."
  log "  OK: Redirect entfernt. Daten auf Ziel-Disk bleiben; ggf. ${anchor}.pre-zl* zurückspielen."
}

usage(){ cat <<EOF
zima-location v$VERSION — reboot-safe, letter-shift-proof storage redirect for ZimaOS apps

Usage:
  zima-location list-disks                       list ext4/btrfs/xfs data disks + UUIDs
  zima-location status                           show active redirects and their health
  zima-location set <anchor> <uuid> [subdir]     redirect <anchor> (under /DATA/) to <uuid>/<subdir> (default subdir: Media)
  zima-location rollback <anchor>                remove a redirect (data on target disk kept)
  zima-location heal <anchor>                    re-bind a broken anchor (run by udev when the disk reappears)
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
  heal)       need_root; cmd_heal "${2:-}" ;;
  version|-v|--version) echo "zima-location v$VERSION" ;;
  help|-h|--help|"") usage ;;
  *) usage; exit 1 ;;
esac
