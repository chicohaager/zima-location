#!/usr/bin/env python3
"""zima-location web UI backend — Python 3 stdlib only, runs as root.

Serves index.html and a small JSON API that wraps the zima-location CLI.
  GET  /                      -> index.html
  GET  /api?action=disks      -> {"disks":[...]}
  GET  /api?action=status     -> {"redirects":[...]}
  POST /api?action=set        (anchor,uuid,sub) -> {"ok":bool,"log":str}
  POST /api?action=rollback   (anchor)          -> {"ok":bool,"log":str}
"""
import json, os, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = "/DATA/AppData/zima-location/zima-location.sh"
USABLE_FS = {"ext4", "ext3", "btrfs", "xfs"}
# ZimaOS internal partitions to hide from the picker (system/boot/overlay, not user data).
SYSTEM_MPS = {"/", "/boot", "/mnt/overlay", "/var/lib/casaos_data"}


def is_system_partition(label, fstype, mp):
    return (label.startswith("casaos-") or fstype == "squashfs"
            or mp in SYSTEM_MPS)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def list_disks():
    disks = []
    out = run(["blkid"]).stdout
    for line in out.splitlines():
        dev = line.split(":", 1)[0]
        if not ("/dev/sd" in dev or "/dev/nvme" in dev):
            continue
        def field(k):
            import re
            m = re.search(k + r'="([^"]*)"', line)
            return m.group(1) if m else ""
        uuid = field("UUID")
        if not uuid:
            continue
        fstype = field("TYPE")
        mp = run(["findmnt", "-rno", "TARGET", "-S", f"UUID={uuid}"]).stdout.splitlines()
        mp = mp[0] if mp else ""
        if is_system_partition(field("LABEL"), fstype, mp):
            continue  # hide ZimaOS system/overlay/boot partitions
        size = avail = ""
        if mp:
            df = run(["df", "-hP", mp]).stdout.splitlines()
            if len(df) > 1:
                cols = df[1].split()
                if len(cols) >= 4:
                    size, avail = cols[1], cols[3]
        disks.append({"dev": dev, "uuid": uuid, "label": field("LABEL"),
                      "fstype": fstype, "size": size, "avail": avail,
                      "mp": mp, "usable": fstype in USABLE_FS})
    return {"disks": disks}


def status():
    reds = []
    d = "/etc/systemd/system"
    for f in sorted(os.listdir(d)):
        if not (f.startswith("zima-location-") and f.endswith(".service")):
            continue
        if f == "zima-location-ui.service":
            continue
        anchor = ""
        for l in open(os.path.join(d, f)):
            if l.startswith("ExecStart=") and "redirect.sh " in l:
                anchor = l.split("redirect.sh ", 1)[1].split()[0]
        active = run(["systemctl", "is-active", f]).stdout.strip()
        enabled = run(["systemctl", "is-enabled", f]).stdout.strip()
        src = run(["findmnt", "-rno", "SOURCE", anchor]).stdout.splitlines() if anchor else []
        reds.append({"unit": f, "anchor": anchor, "source": src[0] if src else "",
                     "active": active, "enabled": enabled})
    return {"redirects": reds}


def cli(action, p):
    if action == "set":
        anchor, uuid, sub = p.get("anchor", ""), p.get("uuid", ""), p.get("sub", "Media") or "Media"
        if not anchor or not uuid:
            return {"ok": False, "log": "anchor + uuid required"}
        r = run(["bash", CLI, "set", anchor, uuid, sub])
    elif action == "rollback":
        anchor = p.get("anchor", "")
        if not anchor:
            return {"ok": False, "log": "anchor required"}
        r = run(["bash", CLI, "rollback", anchor])
    else:
        return {"error": "unknown action"}
    return {"ok": r.returncode == 0, "log": (r.stdout + r.stderr).strip()}


class H(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/" or u.path == "/index.html":
            try:
                b = open(os.path.join(HERE, "index.html"), "rb").read()
            except OSError:
                return self._json({"error": "index.html missing"}, 500)
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(b)))
            self.end_headers()
            self.wfile.write(b)
            return
        if u.path == "/api":
            a = parse_qs(u.query).get("action", [""])[0]
            if a == "disks":
                return self._json(list_disks())
            if a == "status":
                return self._json(status())
            return self._json({"error": "unknown action"}, 400)
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/api":
            return self._json({"error": "not found"}, 404)
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n).decode() if n else ""
        p = {k: v[0] for k, v in parse_qs(body).items()}
        a = parse_qs(u.query).get("action", [p.get("action", "")])[0]
        self._json(cli(a, p))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9797
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
