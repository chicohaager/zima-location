#!/usr/bin/env python3
"""Guards of ui/server.py, against a REAL running server process (loopback, free port).
Only read-only GETs and rejected POSTs are sent -- no request here reaches the CLI."""
import http.client, os, socket, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "..", "ui", "server.py")
fails = 0


def free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def start(env_extra):
    port = free_port()
    env = dict(os.environ, ZL_BIND="127.0.0.1", **env_extra)
    p = subprocess.Popen([sys.executable, SERVER, str(port)], env=env,
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    for _ in range(50):
        try:
            socket.create_connection(("127.0.0.1", port), 0.1).close(); return p, port
        except OSError:
            time.sleep(0.1)
    p.kill(); raise SystemExit("server did not start: " + p.stderr.read().decode())


def req(port, method, path, headers=None, body=None):
    try:
        return _req(port, method, path, headers, body)
    except Exception as e:  # hang/drop is a finding, not a crash of the suite
        return f"{type(e).__name__}"


def _req(port, method, path, headers=None, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.putrequest(method, path, skip_host=True)
    h = {"Host": f"127.0.0.1:{port}"}; h.update(headers or {})
    for k, v in h.items():
        c.putheader(k, v)
    if body is not None:
        c.putheader("Content-Length", str(len(body)) if isinstance(body, bytes) else body)
    c.endheaders(body if isinstance(body, bytes) else None)
    r = c.getresponse(); r.read(); c.close(); return r.status


def check(name, got, want):
    global fails
    if got == want:
        print(f"  \033[32mPASS\033[0m {name}")
    else:
        fails += 1; print(f"  \033[31mFAIL\033[0m {name}\n     HTTP {got}, erwartet {want}")


p, port = start({})
try:
    check("S1 GET status von loopback", req(port, "GET", "/api?action=status"), 200)
    check("S2 fremder Host (DNS-Rebinding) abgelehnt",
          req(port, "GET", "/api?action=status", {"Host": f"evil.example:{port}"}), 403)
    check("S3 fremde Origin abgelehnt",
          req(port, "POST", "/api?action=rollback", {"Origin": "http://evil.example"}, b"anchor=/DATA/x"), 403)
    check("S4 Origin gleicher Host, anderer Port abgelehnt",
          req(port, "POST", "/api?action=rollback", {"Origin": f"http://127.0.0.1:{port + 1}"}, b"anchor=/DATA/x"), 403)
    check("S5 Origin localhost-Alias mit gleichem Port erlaubt (GET)",
          req(port, "GET", "/api?action=status", {"Origin": f"http://localhost:{port}"}), 200)
    check("S6 Origin 'null' abgelehnt",
          req(port, "POST", "/api?action=rollback", {"Origin": "null"}, b"anchor=/DATA/x"), 403)
    check("S7 Content-Length ueber Grenze -> 413",
          req(port, "POST", "/api?action=rollback", {}, "999999999"), 413)
    check("S8 Content-Length kaputt -> 400",
          req(port, "POST", "/api?action=rollback", {}, "abc"), 400)
finally:
    p.kill()

p, port = start({"ZL_TOKEN": "s3cret"})
try:
    check("S9 Token gesetzt, ohne Token -> 403", req(port, "GET", "/api?action=status"), 403)
    check("S10 falscher Token -> 403", req(port, "GET", "/api?action=status", {"X-ZL-Token": "nope"}), 403)
    check("S11 richtiger Token im Header -> 200", req(port, "GET", "/api?action=status", {"X-ZL-Token": "s3cret"}), 200)
    check("S12 Seite selbst ohne Token ladbar", req(port, "GET", "/"), 200)
finally:
    p.kill()

print(f"PYRESULT {12 - fails} {fails}")
