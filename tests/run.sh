#!/bin/bash
# zima-location regression tests.
#
# Runs the REAL entry points (zima-location.sh <cmd>) against fake blkid/findmnt/ip
# on PATH, so the tests exercise the same code path a user hits -- not functions
# cut out of the script.
#
# Focus: the `set -euo pipefail` failure class reported by Gelbuilding (v0.2.1).
# A command substitution whose pipeline exits non-zero (grep with no match, findmnt
# on an unmounted UUID, `ip route get` with no default route) aborts the whole
# script. Every case below aborted before the fix.
#
#   Usage: tests/run.sh          (no root, no real disks required)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
export PATH="$HERE/fakebin:$PATH"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok(){   printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad(){  printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; fail=$((fail+1)); }

# assert_contains <name> <haystack> <needle>
assert_contains(){
  case "$2" in *"$3"*) ok "$1";; *) bad "$1" "erwartet '$3' in der Ausgabe, nicht gefunden";; esac
}

echo "=== zima-location regression tests ==="
echo

# --- Fixture: 4 disks. p2 and sda1 have NO LABEL. Only p1 is mounted. ---------
export ZLT_BLKID='/dev/nvme0n1p1: LABEL="ZimaData" UUID="1111-aaaa" TYPE="ext4"
/dev/nvme0n1p2: UUID="2222-bbbb" TYPE="btrfs"
/dev/sda1: UUID="3333-cccc" TYPE="btrfs"
/dev/sdb1: LABEL="Last" UUID="4444-dddd" TYPE="xfs"'
export ZLT_MOUNTED='1111-aaaa=/mnt/data'

echo "list-disks:"
out="$(bash "$ROOT/zima-location.sh" list-disks 2>&1)"; rc=$?

# T1: the reported bug -- a disk without LABEL must not end the listing.
assert_contains "T1 Platte ohne LABEL bricht die Liste nicht ab" "$out" "2222-bbbb"
# T2: same class, second instance -- an unmounted disk must not end the listing.
assert_contains "T2 nicht gemountete Platte bricht die Liste nicht ab" "$out" "nicht gemountet"
# T3: the LAST disk must still appear -- proves the loop ran to completion.
assert_contains "T3 Liste laeuft bis zur letzten Platte durch" "$out" "4444-dddd"
# T4: exit code clean.
if [ "$rc" = 0 ]; then ok "T4 list-disks endet mit Exit 0"; else bad "T4 list-disks endet mit Exit 0" "Exit war $rc"; fi

echo
echo "set (UUID nicht gemountet):"
# T5: must FAIL LOUDLY. Before the fix set -e killed the script silently and the
# friendly die() message below the findmnt call was never reached.
export ZLT_LSBLK='ext4 9999-zzzz'
export ZLT_MOUNTED=''          # nichts gemountet -> findmnt exit 1, cmd_set muss hier sterben
out="$(bash "$ROOT/zima-location.sh" set "$TMP/anchor" 1111-aaaa Media 2>&1)"; rc=$?
assert_contains "T5 zeigt die freundliche Fehlermeldung statt still zu sterben" "$out" "nicht gemountet"
if [ "$rc" != 0 ]; then ok "T6 set endet mit Non-Zero"; else bad "T6 set endet mit Non-Zero" "Exit war $rc"; fi

echo
echo "install-ui.sh (Host ohne Default-Route):"
# install-ui.sh cannot be run end-to-end here (it writes a systemd unit and needs
# root), so T7 asserts against the REAL file: the `ip route get` assignment must
# carry a `|| true` guard. A behavioural copy of the line would stay green even if
# the real file regressed -- which is exactly the trap this suite exists to avoid.
ip_line="$(grep -n 'IP=.*ip -4 route get' "$ROOT/ui/install-ui.sh" || true)"
if [ -z "$ip_line" ]; then
  bad "T7 install-ui.sh: IP-Zuweisung ist pipefail-sicher" "IP-Zuweisung nicht gefunden - Test veraltet?"
elif [ "${ip_line#*|| true}" != "$ip_line" ]; then
  ok "T7 install-ui.sh: IP-Zuweisung ist pipefail-sicher"
else
  bad "T7 install-ui.sh: IP-Zuweisung ist pipefail-sicher" "kein '|| true': $ip_line"
fi

# T8: demonstrates WHY -- `ip route get` exits 2 with no default route, so the
# unguarded form aborts the installer before it prints its summary.
out="$(ZLT_IP_RC=2 bash -c '
  set -euo pipefail
  IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk "{print \$7; exit}" || true)"
  echo "http://${IP:-<host-ip>}:8099/"' 2>&1)"
assert_contains "T8 offline -> Platzhalter statt Abbruch" "$out" "<host-ip>"

echo
echo "Doku-Konsistenz:"
# T9: v0.2.1 moved the CLI to root-only /etc/zima-location. No doc may still send
# users to the world-writable /DATA/AppData path (that was the privesc S2 fixed).
if grep -rn "/DATA/AppData/zima-location" "$ROOT"/*.md >/dev/null 2>&1; then
  bad "T9 keine veralteten /DATA/AppData-Pfade in der Doku" "$(grep -rn '/DATA/AppData/zima-location' "$ROOT"/*.md)"
else
  ok "T9 keine veralteten /DATA/AppData-Pfade in der Doku"
fi

echo
echo "Syntax:"
for f in zima-location.sh install.sh uninstall.sh redirect.sh ui/install-ui.sh; do
  if bash -n "$ROOT/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f" "Syntaxfehler"; fi
done

echo
echo "shellcheck:"
# NOTE: shellcheck does NOT catch the pipefail-abort class above -- verified against
# the pre-fix code with `-o all`: it only reported SC2250 (brace style) on those very
# lines. The behavioural tests above are the only detector for that class; shellcheck
# runs here as an independent baseline for everything else.
if command -v shellcheck >/dev/null 2>&1; then
  if sc_out="$(shellcheck -S warning "$ROOT"/*.sh "$ROOT"/ui/install-ui.sh 2>&1)"; then
    ok "shellcheck sauber (severity >= warning)"
  else
    bad "shellcheck sauber (severity >= warning)" "$sc_out"
  fi
else
  printf '  \033[33mSKIP\033[0m shellcheck nicht installiert (statisches Binary: siehe README)\n'
fi

echo
echo "================================"
printf 'PASS: %d   FAIL: %d\n' "$pass" "$fail"
[ "$fail" = 0 ] || exit 1
