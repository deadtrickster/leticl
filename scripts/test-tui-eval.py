#!/usr/bin/env python3
"""Exercise scripts/tui-eval against a throwaway fake head on a unix socket.

Covers the three things that have actually broken here:
  - discovery: a head found by --list, and by --pid across runtime dirs
  - the one-line rule: a FORM with a newline in it cannot travel the wire
  - --file: the form is ONE balanced line, it names the file, and it skips
    the forms that cannot be re-evaluated into a live image (unless --all)
"""
import errno
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import threading
import time

runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/{}".format(os.getuid())
if not os.path.isdir(runtime_dir):
    runtime_dir = os.path.join(tempfile.gettempdir(), "leticl-{}".format(os.getuid()))
os.makedirs(runtime_dir, exist_ok=True)

# a REAL pid: --list keeps only sockets whose process is alive, so a made-up
# pid would be filtered out (a stale socket is not a head you can talk to).
MYPID = os.getpid()
path = os.path.join(runtime_dir, "tui-{}.sock".format(MYPID))
try:
    os.unlink(path)
except FileNotFoundError:
    pass

received = []

# The fake head answers the three forms the render gate sends, so the gate's
# own logic is tested here without a real head. `healthy` flips to simulate a
# head that has lost its stream (the bug the gate exists for).
state = {"healthy": True}


def fake_head():
    """Accept several connections; record every request line."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(path)
    s.listen(8)
    try:
        while True:
            conn, _ = s.accept()
            line = b""
            # mimic the head's read-line: stop at the FIRST newline, and keep
            # whatever followed for the next round (a client may send more than
            # one line in one chunk)
            while b"\n" not in line:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                line += chunk
            first, sep, rest = line.partition(b"\n")
            line = first.decode("utf-8")
            received.append(line)
            if not line.startswith("eval "):
                reply = {"ok": False, "error": "only eval is spoken here"}
            else:
                body = line[5:]
                if "head-dirty" in body and "setf" in body:
                    reply = {"ok": True, "value": "T", "ms": 1}     # poke
                elif body == "(head-dirty *head*)":
                    reply = {"ok": True, "value": "NIL", "ms": 1}   # cleared
                elif "stdout=" in body:
                    out = "ok" if state["healthy"] else "NIL"
                    reply = {"ok": True,
                             "value": '"stdout={} rows=30/30 cols=100/100 rows-n=30"'.format(out),
                             "ms": 1}
                elif "head-last-rows" in body:
                    reply = {"ok": True, "value": '"row one\\nrow two\\n"', "ms": 1}
                else:
                    reply = {"ok": True, "value": "42", "ms": 1}
            try:
                conn.sendall((json.dumps(reply) + "\n").encode("utf-8"))
            except OSError:
                pass
            conn.close()
    except OSError:
        pass
    finally:
        s.close()
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


threading.Thread(target=fake_head, daemon=True).start()
time.sleep(0.3)

cli = [sys.executable, "scripts/tui-eval"]


def run(*args):
    r = subprocess.run(cli + list(args), capture_output=True, text=True, timeout=15)
    return r


def balanced(form):
    """Parens outside string literals balance, and no newline survived."""
    if "\n" in form:
        return False
    stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', form)
    depth = 0
    for ch in stripped:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


r = run("--list")
print("--list ->", repr(r.stdout.strip()))
assert str(MYPID) in r.stdout, "expected the live pid in --list"

r = run("--pid", str(MYPID), "(head-cols *head*)")
print("eval   ->", r.stdout.strip().replace("\n", " "))
assert '"ok": true' in r.stdout, "expected ok:true"
assert "42" in r.stdout, "expected the value 42"
assert r.returncode == 0, "a healthy eval must exit 0"
assert "stdout=ok" in r.stderr, "the gate should report the head is healthy: " + r.stderr

# the gate must REFUSE to call a broken head a success
state["healthy"] = False
r = run("--pid", str(MYPID), "(head-cols *head*)")
print("broken ->", "rc", r.returncode, "|", r.stderr.strip().splitlines()[0])
assert r.returncode == 3, "the gate must exit 3 on a head that cannot paint"
assert "*stdout* is NIL" in r.stderr, "the gate must name the broken thing"
state["healthy"] = True
r = run("--pid", str(MYPID), "(head-cols *head*)")
assert r.returncode == 0, "the gate must go green again once the head recovers"

# --screen captures what the head drew, and --no-verify skips the gate
r = run("--pid", str(MYPID), "--screen")
assert r.returncode == 0, "--screen should exit 0"
assert "row one" in r.stdout and "row two" in r.stdout, "--screen must print the rows"
r = run("--pid", str(MYPID), "--no-verify", "(head-cols *head*)")
assert r.returncode == 0, "--no-verify must skip the gate"
assert "stdout=" not in r.stderr, "--no-verify must not run the gate"

# --file: one balanced line naming the file, skipping the not-live forms.
# Find the PUSH among the requests, not simply the last: the render gate runs
# after it and sends its own forms (which is the point of the gate).
target = os.path.abspath("src/head.lisp")


def last_push(path):
    hits = [l for l in received if path in l]
    return hits[-1] if hits else ""


r = run("--pid", str(MYPID), "--file", target)
assert '"ok": true' in r.stdout, "--file should reach the head: " + r.stderr
assert r.returncode == 0, "a --file push that leaves the head healthy must exit 0"
form = last_push(target)
print("--file ->", form[:100], "...")
assert form.startswith("eval "), "the request must be an eval"
body = form[5:]
assert target in body, "the form must name the file"
assert balanced(body), "the --file form must be ONE balanced line"
assert "DEFSTRUCT" in body, "defstruct must be in the default skip list"
assert "DEFCLASS" in body and "EVAL-WHEN" in body, "the skip list must be whole"

# --all: the skip list is empty, and the form is still one balanced line
r = run("--pid", str(MYPID), "--file", target, "--all")
assert '"ok": true' in r.stdout, "--file --all should reach the head: " + r.stderr
body = last_push(target)[5:]
assert "(skip '())" in body, "--all must send an empty skip list: " + body[:120]
assert balanced(body), "--all form must be one balanced line"

# --file with a missing path is refused before any socket work
r = run("--pid", str(MYPID), "--file", "/definitely/not/here.lisp")
assert r.returncode == 2 and "no such file" in r.stderr, "a missing file is exit 2"

# --tree reads leticl.asd for the file list, in the asd's order, and the asd
# writes components WITHOUT the extension. Getting that wrong pushes 23
# nonexistent paths, so assert the mapping rather than the count.
ns = {"__name__": "tui_eval_test"}
exec(open("scripts/tui-eval").read(), ns)
asd = ns["asd_files"](os.getcwd())
names = [os.path.basename(p) for p in asd]
print("--tree files ->", " ".join(names))
assert names[0] == "package.lisp", "the asd order starts at package, got " + names[0]
assert all(n.endswith(".lisp") for n in names), "every component needs .lisp: " + str(names)
assert all(os.path.isfile(p) for p in asd), "every path must exist: " + str(
    [p for p in asd if not os.path.isfile(p)])
# the order must match the asd's serial order, not a directory listing
assert names.index("head.lisp") < names.index("render.lisp"), \
    "head before render (render composes what head calls)"
assert names.index("render.lisp") < names.index("editor.lisp"), \
    "render before editor, per the asd"

# --where: the generated form is one line and never NAMES the contrib package,
# because that name is read before anything runs and a head without the contrib
# would fail with a reader error rather than the message this prints.
wf = ns["where_form"]("item-lines")
assert "\n" not in wf, "--where form must be one line"
assert "sb-introspect:" not in wf, "must not name the package at read time"
assert "find-symbol" in wf and "funcall" in wf, "use find-symbol + funcall"

# an unquoted multi-line FORM cannot travel the wire: the head reads ONE line.
# Documented in HACKING.md; asserted here so the rule is not quietly lost.
# --no-verify so exactly one request is sent and the assertion is unambiguous.
before = len(received)
run("--pid", str(MYPID), "--no-verify", "(list 1\n2)")
print("multiline ->", repr(received[-1]) if len(received) > before else "NOTHING RECEIVED")
assert len(received) == before + 1, "a multi-line form still costs one request"
assert received[-1] == "eval (list 1", "the wire carries only the first line, as documented"

# **The two ways a head can stop listening, and the ONE message they must not share.**
#
# `unreachable` is a verdict about the repair, so a wrong one costs more than a vague one:
# "cannot reach" says start a head, "WEDGED" says THIS head is alive and has stopped
# accepting, and the difference was worth an hour on the live head (2026-09-24) where
# every push hung and every one of them was silently discarded.
class FakeErr(Exception):
    def __init__(self, errno):
        self.errno = errno


eagain = ns["unreachable"]("/tmp/x.sock", FakeErr(errno.EAGAIN))
assert "WEDGED" in eagain, eagain
assert "not ACCEPTING" in eagain, eagain
assert "NOTHING PUSHED SINCE THE WEDGE" in eagain, "the form did not run — say so"

refused = ns["unreachable"]("/tmp/x.sock", FakeErr(errno.ECONNREFUSED))
assert "cannot reach" in refused and "WEDGED" not in refused, (
    "a head that is GONE and a head that is stuck need opposite repairs: " + refused
)

# and the deadline really does cover the connect, which is where the first cut of this
# hung for ever: a listener whose backlog is full blocks `connect` with no error at all.
assert ns["EVAL_TIMEOUT_S"] > 0, "there is a deadline"
src_eval = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tui-eval")).read()
i_timeout = src_eval.index("s.settimeout(")
i_connect = src_eval.index("s.connect(")
assert i_timeout < i_connect, (
    "settimeout must come BEFORE connect: a full backlog blocks connect, and a "
    "deadline set afterwards never applies"
)

print("PASS")