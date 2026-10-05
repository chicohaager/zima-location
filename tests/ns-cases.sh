#!/bin/bash
# Integration cases, executed by tests/run.sh INSIDE a throw-away user+mount namespace with a
# private root (tmpfs + bound /usr, overlay /etc). Real mount --bind, umount, mountpoint, rsync,
# mv; "disks" are tmpfs mounts named zl-disk-<uuid>. Faked only: blkid (no real block devices),
# findmnt's UUID lookup (mapped onto the tmpfs name), systemctl (no PID-1 systemd here; it runs
# the unit's real ExecStart/ExecStop). Nothing here can reach the host's /DATA or /etc.
set -uo pipefail
CLI=/zl/zima-location.sh
export ZLT_STATE=/zlstate PATH="/zl/tests/nsbin:$PATH"
mkdir -p "$ZLT_STATE" /DATA /media /etc/systemd/system
# fresh unit dir: the host's (lower) one is owned by an unmapped uid, and status must not
# see host units anyway
mount -t tmpfs zl-units /etc/systemd/system
mkdir -p /etc/udev/rules.d 2>/dev/null; mount -t tmpfs zl-rules /etc/udev/rules.d

pass=0; fail=0
ok(){   printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }
check(){ local n="$1"; shift; if "$@"; then ok "$n"; else bad "$n" "Bedingung falsch: $*"; fi; }
has(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac; }

# disk <uuid> <fstype> <mountpoint>
disk(){ echo "$2" > "$ZLT_STATE/disk-$1"; mkdir -p "$3"; mount -t tmpfs "zl-disk-$1" "$3"; }
src_of(){ findmnt -rno SOURCE "$1" 2>/dev/null | head -1; }

disk 1111 ext4 /media/sda
disk 2222 f2fs /media/sdb
disk 3333 btrfs /media/sdc

echo "set mit Migration:"
mkdir -p /DATA/Media; echo hallo > /DATA/Media/a.txt
out="$(bash "$CLI" set /DATA/Media 1111 Media 2>&1)"; rc=$?
check "N1 set endet mit Exit 0" [ "$rc" = 0 ]
check "N1 Anker ist echter Mountpoint" mountpoint -q /DATA/Media
check "N1 Bestandsdaten liegen auf der Zielplatte" [ "$(cat /media/sda/Media/a.txt 2>/dev/null)" = hallo ]
check "N1 Original als .pre-zl weggesichert (mv, keine Kopie im Anker)" [ -f /DATA/Media.pre-zl/a.txt ]
check "N1 Unit ordnet sich vor docker.service" grep -q '^Before=docker.service' /etc/systemd/system/zima-location-DATA-Media.service
echo neu > /DATA/Media/b.txt
check "N1 Schreiben über Anker landet auf der Platte" [ -f /media/sda/Media/b.txt ]

echo
echo "unbekanntes FS:"
out="$(bash "$CLI" set /DATA/Other 2222 X 2>&1)"; rc=$?
check "N2 set mit f2fs läuft durch (nur Warnung)" [ "$rc" = 0 ]
if has "$out" "UUID 2222 (f2fs) @"; then ok "N2 WARN verschmutzt den FS-Typ nicht"
else bad "N2 WARN verschmutzt den FS-Typ nicht" "$(echo "$out" | grep 'Ziel:')"; fi
bash "$CLI" rollback /DATA/Other >/dev/null 2>&1

echo
echo "zweites set auf andere Platte:"
out="$(bash "$CLI" set /DATA/Media 3333 Media 2>&1)"; rc=$?
check "N3 erneutes set endet mit Exit 0" [ "$rc" = 0 ]
check "N3 Anker zeigt jetzt auf die neue Platte" has "$(src_of /DATA/Media)" "zl-disk-3333"
[ "$rc" = 0 ] || printf '       %s\n' "$out"

echo
echo "Letter-Shift mit zwei Ankern auf derselben Platte:"
# Zweiter Anker auf Platte 3333, dann wandert die Platte (/media/sdc -> /media/sdd) und der
# Original-Mount verschwindet. Danach traegt zl-disk-3333: /DATA/Media (FSROOT /Media),
# /DATA/Downloads (FSROOT /Downloads), /media/sdd (FSROOT /). Ein restart von Downloads loest
# per ExecStop nur den eigenen Bind -- vorn steht dann der Bind von /DATA/Media. Wer die
# erste Zeile nimmt (v0.2.2: head -1), bindet /DATA/Downloads auf /DATA/Media/Downloads.
bash "$CLI" set /DATA/Downloads 3333 Downloads >/dev/null 2>&1
mkdir -p /media/sdd; mount --bind /media/sdc /media/sdd; umount /media/sdc
systemctl restart zima-location-DATA-Downloads.service >/dev/null 2>&1; rc=$?
check "N4 Helper bindet neu (Exit 0)" [ "$rc" = 0 ]
echo shift > /DATA/Downloads/c.txt
check "N4 Anker schreibt auf den neuen Pfad /media/sdd/Downloads" [ -f /media/sdd/Downloads/c.txt ]
check "N4 nicht in den Nachbaranker /DATA/Media/Downloads" [ ! -e /media/sdd/Media/Downloads ]
bash "$CLI" rollback /DATA/Downloads >/dev/null 2>&1
echo shift > /DATA/Media/c.txt

echo
echo "status / Gesundheit:"
out="$(bash "$CLI" status 2>&1)"
check "N5 status meldet OK" has "$out" "Zustand: OK"
mv "$ZLT_STATE/disk-3333" "$ZLT_STATE/gone-3333"
out="$(bash "$CLI" status 2>&1)"
check "N5 status meldet fehlende Zielplatte" has "$out" "Zielplatte UUID 3333 fehlt"
mv "$ZLT_STATE/gone-3333" "$ZLT_STATE/disk-3333"

echo
echo "rollback:"
out="$(bash "$CLI" rollback /DATA/Media 2>&1)"; rc=$?
check "N6 rollback Exit 0" [ "$rc" = 0 ]
check "N6 Anker kein Mountpoint mehr" bash -c '! mountpoint -q /DATA/Media'
check "N6 Unit entfernt" [ ! -e /etc/systemd/system/zima-location-DATA-Media.service ]
check "N6 Daten bleiben auf der Platte" [ -f /media/sdd/Media/c.txt ]
out="$(bash "$CLI" rollback /DATA/Nix 2>&1)"; rc=$?
check "N7 rollback ohne Redirect scheitert laut" [ "$rc" != 0 ]
check "N7 ... mit Meldung" has "$out" "kein zima-location-Redirect"

echo
echo "fehlgeschlagenes set wird zurückgenommen:"
rm -rf /DATA/Media; mkdir -p /DATA/Media; echo orig > /DATA/Media/o.txt
before="$(ls /DATA)"
touch "$ZLT_STATE/fail-restart"
out="$(bash "$CLI" set /DATA/Media 1111 Media 2>&1)"; rc=$?
rm -f "$ZLT_STATE/fail-restart"
check "N8 set scheitert (Exit != 0)" [ "$rc" != 0 ]
check "N8 Unit wieder entfernt" [ ! -e /etc/systemd/system/zima-location-DATA-Media.service ]
check "N8 Original zurück im Anker" [ "$(cat /DATA/Media/o.txt 2>/dev/null)" = orig ]
check "N8 kein Backup-Rest neben dem Anker" [ "$(ls /DATA)" = "$before" ]

echo "Unit nicht schreibbar (Abbruch NACH dem Wegsichern des Ankers):"
mkdir /etc/systemd/system/zima-location-DATA-Media.service   # 'cat > unit' -> "Is a directory"
out="$(bash "$CLI" set /DATA/Media 1111 Media 2>&1)"; rc=$?
rmdir /etc/systemd/system/zima-location-DATA-Media.service
check "N13 set scheitert (Exit != 0)" [ "$rc" != 0 ]
[ "$rc" != 0 ] || printf '       %s\n' "$out"
check "N13 Original zurück im Anker" [ "$(cat /DATA/Media/o.txt 2>/dev/null)" = orig ]
check "N13 kein Backup-Rest neben dem Anker" [ "$(ls /DATA)" = "$before" ]

echo
echo
echo "zweite Migration überschreibt kein altes Backup:"
rm -rf /DATA/Media.pre-zl*; mkdir -p /DATA/Media.pre-zl; echo alt > /DATA/Media.pre-zl/alt.txt
out="$(bash "$CLI" set /DATA/Media 1111 Media 2>&1)"; rc=$?
check "N9 set Exit 0" [ "$rc" = 0 ]
check "N9 altes Backup unverändert" [ "$(ls /DATA/Media.pre-zl)" = alt.txt ]
check "N9 neues Backup mit Zeitstempel" bash -c 'ls -d /DATA/Media.pre-zl.2* >/dev/null 2>&1'
bash "$CLI" rollback /DATA/Media >/dev/null 2>&1

echo
echo "gescheitertes zweites set lässt den alten Redirect stehen:"
bash "$CLI" set /DATA/Media 1111 Media >/dev/null 2>&1
touch "$ZLT_STATE/fail-once"
out="$(bash "$CLI" set /DATA/Media 3333 Media 2>&1)"; rc=$?
check "N14 zweites set scheitert (Exit != 0)" [ "$rc" != 0 ]
check "N14 Unit noch da" [ -e /etc/systemd/system/zima-location-DATA-Media.service ]
check "N14 Unit zeigt wieder auf die alte Platte" grep -q ' 1111 Media$' /etc/systemd/system/zima-location-DATA-Media.service
check "N14 Anker wieder auf der alten Platte gebunden" has "$(src_of /DATA/Media)" "zl-disk-1111"
bash "$CLI" rollback /DATA/Media >/dev/null 2>&1

echo
echo "RAID ohne xargs (Lage .184, ZimaOS 1.8.0-beta1):"
disk 7777 btrfs /media/Home-Storage; touch "$ZLT_STATE/raid-7777"
out="$(bash "$CLI" set /DATA/Raid 7777 zl 2>&1)"; rc=$?
check "N15 set auf RAID Exit 0" [ "$rc" = 0 ]
if has "$out" "UUID 7777 (btrfs) @"; then ok "N15 Typ des Arrays (btrfs), nicht des Mitglieds"
else bad "N15 Typ des Arrays (btrfs), nicht des Mitglieds" "$(echo "$out" | grep -E 'Ziel:|WARN')"; fi
bash "$CLI" rollback /DATA/Raid >/dev/null 2>&1

echo
echo "Auto-Heal (udev):"
R=/etc/udev/rules.d/99-zima-location-DATA-Heal.rules
H=/etc/systemd/system/zima-location-heal-DATA-Heal.service
bash "$CLI" set /DATA/Heal 1111 Heal >/dev/null 2>&1
check "N16 set schreibt die udev-Regel" [ -f "$R" ]
check "N16 Regel trifft genau diese UUID" grep -q 'ENV{ID_FS_UUID}=="1111"' "$R"
check "N16 Regel schließt RAID-Mitglieder aus" grep -q 'ENV{ID_FS_TYPE}!="linux_raid_member"' "$R"
check "N16 Regel stößt nur die Heal-Unit an (kein Mount aus udevd)" grep -q 'RUN+="/usr/bin/systemctl --no-block start zima-location-heal-DATA-Heal.service"' "$R"
check "N16 Heal-Unit ruft 'heal /DATA/Heal'" grep -q '^ExecStart=/etc/zima-location/zima-location.sh heal /DATA/Heal$' "$H"
check "N16 udev-Regeln neu geladen" grep -q 'udevadm control --reload' "$ZLT_STATE/calls"
out="$(bash "$CLI" status 2>&1)"
check "N16 status zeigt Auto-Heal an" has "$out" "Auto-Heal: an"
case "$out" in *zima-location-heal-*) bad "N16 Heal-Unit nicht als Redirect gelistet" "$out";; *) ok "N16 Heal-Unit nicht als Redirect gelistet";; esac

: > "$ZLT_STATE/calls"
out="$(bash "$CLI" heal /DATA/Heal 2>&1)"
check "N17 heal auf gesundem Anker tut nichts" has "$out" "gesund"
check "N17 ... kein restart" bash -c '! grep -q "restart" "$ZLT_STATE/calls"'

# Lage .143 nach dem Umstecken: Anker nicht (mehr) gebunden, Platte wieder da.
umount /DATA/Heal
touch "$ZLT_STATE/booting"; : > "$ZLT_STATE/calls"
out="$(bash "$CLI" heal /DATA/Heal 2>&1)"
check "N18 heal während des Boots wartet auf die Boot-Unit" bash -c '! grep -q "restart" "$ZLT_STATE/calls"'
rm -f "$ZLT_STATE/booting"
out="$(bash "$CLI" heal /DATA/Heal 2>&1)"; rc=$?
check "N19 heal auf ungebundenem Anker Exit 0" [ "$rc" = 0 ]
check "N19 ... bindet neu" mountpoint -q /DATA/Heal
check "N19 ... auf die richtige Platte" has "$(src_of /DATA/Heal)" "zl-disk-1111[/Heal]"

# Zielplatte weg (USB abgezogen): heal benennt den Grund im Journal, statt still zu bleiben.
mv "$ZLT_STATE/disk-1111" "$ZLT_STATE/gone-1111"
out="$(bash "$CLI" heal /DATA/Heal 2>&1)"
check "N20 heal meldet fehlende Zielplatte" has "$out" "Zielplatte UUID 1111 fehlt"
mv "$ZLT_STATE/gone-1111" "$ZLT_STATE/disk-1111"

out="$(bash "$CLI" heal /DATA/Nix 2>&1)"; rc=$?
check "N21 heal ohne Redirect: Exit 0, nichts zu tun" [ "$rc" = 0 ]
out="$(bash "$CLI" heal /etc 2>&1)"; rc=$?
check "N21 heal mit ungültigem Anker abgelehnt" [ "$rc" != 0 ]

bash "$CLI" rollback /DATA/Heal >/dev/null 2>&1
check "N22 rollback entfernt die Regel" [ ! -e "$R" ]
check "N22 rollback entfernt die Heal-Unit" [ ! -e "$H" ]

echo
echo "Schutzgeländer:"
disk 5555 ext4 /mnt/overlay
out="$(bash "$CLI" set /DATA/X 5555 Media 2>&1)"; rc=$?
check "N10 Systemplatte (/mnt/overlay) wird abgelehnt" has "$out" "ZimaOS-Systemplatte"
for a in /etc/foo /DATA /DATA/.media /DATA/Media/ /DATA/../etc; do
  out="$(bash "$CLI" set "$a" 1111 Media 2>&1)"; rc=$?
  check "N11 anchor '$a' abgelehnt" [ "$rc" != 0 ]
done
for s in . ./x ../x /abs; do
  out="$(bash "$CLI" set /DATA/Media 1111 "$s" 2>&1)"; rc=$?
  check "N12 subdir '$s' abgelehnt" [ "$rc" != 0 ]
done
check "N12 ... ohne Unit zu schreiben" [ ! -e /etc/systemd/system/zima-location-DATA-Media.service ]

echo "NSRESULT $pass $fail"
