#!/usr/bin/env python3
"""zima-location web UI backend — Python 3 stdlib only, runs as root.

Serves index.html and a small JSON API that wraps the zima-location CLI.
  GET  /                      -> index.html
  GET  /api?action=disks      -> {"disks":[...]}
  GET  /api?action=status     -> {"redirects":[...]}
  POST /api?action=set        (anchor,uuid,sub) -> {"ok":bool,"log":str}
  POST /api?action=rollback   (anchor)          -> {"ok":bool,"log":str}

Security:
  - Binds 127.0.0.1 by default (set ZL_BIND=0.0.0.0 to expose on the LAN, at your risk).
  - /api requests are guarded against DNS-rebinding / cross-site POST: the Host header
    must be a loopback name (when bound to localhost) and any Origin must be same-host.
  - Optional shared secret: set ZL_TOKEN=... and pass it as ?token= or X-ZL-Token header.
"""
import json, os, re, subprocess, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = "/etc/zima-location/zima-location.sh"
USABLE_FS = {"ext4", "ext3", "btrfs", "xfs"}
SYSTEM_MPS = {"/", "/boot", "/mnt/overlay", "/var/lib/casaos_data"}

BIND = os.environ.get("ZL_BIND", "127.0.0.1")
TOKEN = os.environ.get("ZL_TOKEN", "")
LOOPBACK = {"127.0.0.1", "localhost", "::1", "[::1]"}


def is_system_partition(label, fstype, mp):
    return label.startswith("casaos-") or fstype == "squashfs" or mp in SYSTEM_MPS


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=120)


def field(line, k):
    m = re.search(k + r'="([^"]*)"', line)
    return m.group(1) if m else ""


def list_disks():
    disks = []
    for line in run(["blkid"]).stdout.splitlines():
        dev = line.split(":", 1)[0]
        if not ("/dev/sd" in dev or "/dev/nvme" in dev):
            continue
        uuid = field(line, "UUID")
        if not uuid:
            continue
        fstype = field(line, "TYPE")
        mp = run(["findmnt", "-rno", "TARGET", "-S", f"UUID={uuid}"]).stdout.splitlines()
        mp = mp[0] if mp else ""
        if is_system_partition(field(line, "LABEL"), fstype, mp):
            continue
        size = avail = ""
        if mp:
            df = run(["df", "-hP", mp]).stdout.splitlines()
            if len(df) > 1 and len(df[1].split()) >= 4:
                cols = df[1].split()
                size, avail = cols[1], cols[3]
        disks.append({"dev": dev, "uuid": uuid, "label": field(line, "LABEL"),
                      "fstype": fstype, "size": size, "avail": avail,
                      "mp": mp, "usable": fstype in USABLE_FS})
    return {"disks": disks}


def status():
    reds, d = [], "/etc/systemd/system"
    for f in sorted(os.listdir(d)):
        if not (f.startswith("zima-location-") and f.endswith(".service")):
            continue
        if f == "zima-location-ui.service":
            continue
        anchor = ""
        with open(os.path.join(d, f)) as fh:
            for l in fh:
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

    def _guard(self, params):
        """Return an error string if the /api request must be rejected, else None."""
        # optional shared secret
        if TOKEN:
            tok = params.get("token", "") or self.headers.get("X-ZL-Token", "")
            if tok != TOKEN:
                return "forbidden (bad token)"
        host = (self.headers.get("Host", "").rsplit(":", 1)[0]).strip("[]")
        # DNS-rebinding guard: on the default loopback bind, only loopback Host is allowed
        if BIND in LOOPBACK and host not in {"127.0.0.1", "localhost", "::1"}:
            return "forbidden (host)"
        # cross-site guard: if an Origin is present it must match the Host
        origin = self.headers.get("Origin", "")
        if origin:
            ohost = urlparse(origin).hostname or ""
            if ohost != host and ohost not in {"127.0.0.1", "localhost"}:
                return "forbidden (origin)"
        return None

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
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
            params = {k: v[0] for k, v in parse_qs(u.query).items()}
            err = self._guard(params)
            if err:
                return self._json({"error": err}, 403)
            a = params.get("action", "")
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
        p.update({k: v[0] for k, v in parse_qs(u.query).items()})
        err = self._guard(p)
        if err:
            return self._json({"error": err}, 403)
        self._json(cli(p.get("action", ""), p))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9797
    ThreadingHTTPServer((BIND, port), H).serve_forever()
