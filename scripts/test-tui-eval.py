#!/usr/bin/env python3
"""Exercise scripts/tui-eval against a throwaway fake head on a unix socket."""
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or os.path.join(
    tempfile.gettempdir(), "leticl-{}".format(os.getuid()))
os.makedirs(runtime_dir, exist_ok=True)
path = os.path.join(runtime_dir, "tui-99999.sock")
try:
    os.unlink(path)
except FileNotFoundError:
    pass


def fake_head():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(1)
    try:
        conn, _ = s.accept()  # exactly one: the eval
        line = b""
        while not line.endswith(b"\n"):
            chunk = conn.recv(4096)
            if not chunk:
                break
            line += chunk
        line = line.decode("utf-8").strip()
        if line.startswith("eval "):
            reply = {"ok": True, "value": "42", "ms": 1}
        else:
            reply = {"ok": False, "error": "only eval is spoken here"}
        conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
        conn.close()
    finally:
        s.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


t = threading.Thread(target=fake_head, daemon=True)
t.start()
time.sleep(0.3)

cli = [sys.executable, "scripts/tui-eval"]

r = subprocess.run(cli + ["--list"], capture_output=True, text=True, timeout=10)
print("--list ->", repr(r.stdout.strip()))
assert "99999" in r.stdout, "expected 99999 in --list"

r = subprocess.run(cli + ["--pid", "99999", "(head-cols *head*)"],
                   capture_output=True, text=True, timeout=10)
print("eval   ->", r.stdout.strip().replace("\n", " "))
assert '"ok": true' in r.stdout, "expected ok:true"
assert "42" in r.stdout, "expected the value 42"

print("PASS")
