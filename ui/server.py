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
import hmac, json, os, re, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = "/etc/zima-location/zima-location.sh"
USABLE_FS = {"ext4", "ext3", "btrfs", "xfs"}
# Mountpoints of the ZimaOS system disk (casaos-boot/-overlay/-data); same list as the CLI.
SYSTEM_MPS = ("/", "/boot", "/mnt/boot", "/mnt/overlay", "/DATA", "/var/lib/casaos_data", "/media")
DISK_PREFIXES = ("/dev/sd", "/dev/nvme", "/dev/md", "/dev/mmcblk")
MAX_BODY = 64 * 1024
# one set/rollback at a time: two concurrent migrations onto the same anchor would race
CLI_LOCK = threading.Lock()

BIND = os.environ.get("ZL_BIND", "127.0.0.1")
TOKEN = os.environ.get("ZL_TOKEN", "")
LOOPBACK = {"127.0.0.1", "localhost", "::1", "[::1]"}


def run(cmd, timeout=120):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def path_dev(path):
    """Device behind a path without the [subpath] suffix ("/dev/sda[/Media]" -> "/dev/sda")."""
    out = run(["findmnt", "-rno", "SOURCE", path]).stdout.splitlines()
    return out[0].split("[", 1)[0] if out else ""


def system_devs():
    return {d for d in (path_dev(m) for m in SYSTEM_MPS) if d}


def uuid_mp(uuid, exclude=""):
    """Root mountpoint of a UUID. FSROOT must be "/": a bind of a subdir (our own anchor)
    carries the same UUID and must never count as the disk's mountpoint."""
    for l in run(["findmnt", "-rno", "TARGET,FSROOT", "-S", f"UUID={uuid}"]).stdout.splitlines():
        parts = l.split(" ")
        if len(parts) == 2 and parts[1] == "/" and parts[0] != exclude:
            # findmnt -r escapes blanks etc. as \xNN
            return re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), parts[0])
    return ""


def field(line, k):
    m = re.search(k + r'="([^"]*)"', line)
    return m.group(1) if m else ""


def list_disks():
    disks, sysdevs = [], system_devs()
    for line in run(["blkid"]).stdout.splitlines():
        dev = line.split(":", 1)[0]
        if not dev.startswith(DISK_PREFIXES):
            continue
        uuid = field(line, " UUID")
        if not uuid:
            continue
        fstype = field(line, "TYPE")
        if field(line, " LABEL").startswith("casaos-") or fstype in ("squashfs", "linux_raid_member") \
                or dev in sysdevs:
            continue
        mp = uuid_mp(uuid)
        size = avail = ""
        if mp:
            df = run(["df", "-hP", mp]).stdout.splitlines()
            if len(df) > 1 and len(df[1].split()) >= 4:
                cols = df[1].split()
                size, avail = cols[1], cols[3]
        disks.append({"dev": dev, "uuid": uuid, "label": field(line, " LABEL"),
                      "fstype": fstype, "size": size, "avail": avail,
                      "mp": mp, "usable": fstype in USABLE_FS})
    return {"disks": disks}


def status():
    reds, d = [], "/etc/systemd/system"
    for f in sorted(os.listdir(d)):
        if not (f.startswith("zima-location-") and f.endswith(".service")):
            continue
        if f == "zima-location-ui.service" or f.startswith("zima-location-heal-"):
            continue
        anchor = uuid = ""
        with open(os.path.join(d, f)) as fh:
            for l in fh:
                if l.startswith("ExecStart=") and "redirect.sh " in l:
                    args = l.split("redirect.sh ", 1)[1].split()
                    anchor, uuid = args[0], (args[1] if len(args) > 1 else "")
        active = run(["systemctl", "is-active", f]).stdout.strip()
        enabled = run(["systemctl", "is-enabled", f]).stdout.strip()
        mounted = bool(anchor) and run(["mountpoint", "-q", anchor]).returncode == 0
        src = run(["findmnt", "-rno", "SOURCE", anchor]).stdout.splitlines() if mounted else []
        reds.append({"unit": f, "anchor": anchor, "source": src[0] if src else "",
                     "active": active, "enabled": enabled,
                     "health": health(anchor, uuid, f) if mounted else "not mounted"})
    return {"redirects": reds}


def health(anchor, uuid, unit):
    """Same verdicts as `zima-location.sh status`: the bind survives its disk vanishing
    (USB reset) and then answers every read with EIO."""
    cur = run(["blkid", "-U", uuid]).stdout.strip() if uuid else ""
    if not cur:
        return f"target disk UUID {uuid} missing (unplugged / USB reset?)"
    bound = path_dev(anchor)
    if bound and bound != cur:
        return f"stale bind ({bound}), disk is now {cur} - systemctl restart {unit}"
    try:
        if run(["ls", "-A", anchor], timeout=5).returncode != 0:
            return "anchor not readable (I/O error?) - check dmesg"
    except subprocess.TimeoutExpired:
        return "anchor not readable (timeout) - check dmesg"
    return "OK"


def cli(action, p):
    if action == "set":
        anchor, uuid, sub = p.get("anchor", ""), p.get("uuid", ""), p.get("sub", "Media") or "Media"
        if not anchor or not uuid:
            return {"ok": False, "log": "anchor + uuid required"}
        # no timeout: 'set' rsyncs existing data, which can take hours. Killing it midway
        # would leave a half-migrated anchor.
        r = run(["bash", CLI, "set", anchor, uuid, sub], timeout=None)
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
        # optional shared secret (constant-time compare)
        if TOKEN:
            tok = params.get("token", "") or self.headers.get("X-ZL-Token", "")
            if not hmac.compare_digest(tok.encode(), TOKEN.encode()):
                return "forbidden (bad token)"
        hosthdr = self.headers.get("Host", "")
        u = urlparse("//" + hosthdr)
        host, port = (u.hostname or ""), u.port
        # DNS-rebinding guard: on the default loopback bind, only loopback Host is allowed
        if BIND in LOOPBACK and host not in {"127.0.0.1", "localhost", "::1"}:
            return "forbidden (host)"
        # cross-site guard: if an Origin is present it must be this very origin (host AND
        # port) - another service on the same box (other port) must not drive a root API.
        origin = self.headers.get("Origin", "")
        if origin:
            o = urlparse(origin)
            same = (o.hostname or "") == host and o.port == port
            loop = {o.hostname, host} <= {"127.0.0.1", "localhost", "::1"} and o.port == port
            if not (same or loop):
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
            try:
                if a == "disks":
                    return self._json(list_disks())
                if a == "status":
                    return self._json(status())
            except Exception as e:
                return self._json({"error": f"server error: {e}"}, 500)
            return self._json({"error": "unknown action"}, 400)
        self._json({"error": "not found"}, 404)

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/api":
            return self._json({"error": "not found"}, 404)
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            return self._json({"error": "bad Content-Length"}, 400)
        if n < 0 or n > MAX_BODY:
            return self._json({"error": "body too large"}, 413)
        body = self.rfile.read(n).decode(errors="replace") if n else ""
        p = {k: v[0] for k, v in parse_qs(body).items()}
        p.update({k: v[0] for k, v in parse_qs(u.query).items()})
        err = self._guard(p)
        if err:
            return self._json({"error": err}, 403)
        if not CLI_LOCK.acquire(blocking=False):
            return self._json({"ok": False, "log": "another set/rollback is still running"}, 409)
        try:
            res = cli(p.get("action", ""), p)
        except Exception as e:  # loud: a crashed handler would just drop the connection
            return self._json({"ok": False, "log": f"server error: {e}"}, 500)
        finally:
            CLI_LOCK.release()
        # CLI refused (bad input, no such redirect, failed set) -> 422; unknown action -> 400
        self._json(res, 200 if res.get("ok") else (400 if "error" in res else 422))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9797
    ThreadingHTTPServer((BIND, port), H).serve_forever()
