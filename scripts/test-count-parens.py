#!/usr/bin/env python3
"""Exercise scripts/count-parens — the tool that answers "where does the depth land?"

**This exists because the tool LIED, in the way that costs the most.** `count-parens.py`
skipped `#(` as a two-character token while still counting the `)` that closes the vector,
so every `#(...)` in a file pulled the reported depth down by one — and its per-line
verdict after the first one was wrong. In `tests/tests.lisp` a single `#()` was enough to
make it report a negative depth on a file the COMPILER reads without complaint. I had just
named that script in a source comment as the way to find a stray `)` (it is: it is what
found the `handler-case` clause that had escaped its own clause), so a false alarm from it
sends the next hand hunting for a paren that is not there.

Balance is the whole contract, so it is checked against the reader's own rules rather than
against a fixture I chose: a comment, a string, a block comment, a character literal, a
vector literal, and a genuinely unbalanced file.

Run: python3 scripts/test-count-parens.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.path.join(HERE, "count-parens.py")

failures = []


def run(text, *args):
    with tempfile.NamedTemporaryFile("w", suffix=".lisp", delete=False) as f:
        f.write(text)
        path = f.name
    try:
        p = subprocess.run([sys.executable, TOOL, path, *args], capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr
    finally:
        os.unlink(path)


def final_depth(out):
    for line in out.splitlines():
        if line.startswith("file final depth:"):
            return int(line.split(":")[1])
    return None


def check(name, text, want_depth, want_negative=False, want_status=0):
    status, out = run(text)
    depth = final_depth(out)
    if depth != want_depth:
        failures.append(f"{name}: final depth {depth}, wanted {want_depth}\n{out}")
    if ("depth went negative" in out) != want_negative:
        failures.append(f"{name}: negative report {want_negative}, got it={('depth went negative' in out)}\n{out}")
    if (status != 0) != (want_status != 0):
        failures.append(f"{name}: exit {status}, wanted {want_status}")


# 1. **THE BUG.** A vector literal's `)` closes the `#(`. `(or new #())` is the shape that
#    caught it, and it is in this tree (`tests/tests.lisp:696`) — one `#()` and the tool's
#    every later line was wrong by one.
check("a vector literal balances", "(defun f (new) (or new #()))\n", 0)
check("a non-empty vector balances", "(defun f () #(1 2 3))\n", 0)
check("a vector inside a string does not count", '(defvar s "#()")\n', 0)

# 2. The things the tool must IGNORE, each of which is a paren the reader ignores.
check("parens in a line comment", "(defun f () 1) ; )))\n", 0)
check("parens in a string", '(defvar s ")))")\n', 0)
check("a string with an escaped quote", '(defvar s "a \\" ) b")\n', 0)
check("parens in a block comment", "(defun f () 1) #| ))) |#\n", 0)
check("a character literal paren", "(defvar c #\\))\n", 0)
check("a #\\( is not an open", "(defvar c #\\( )\n", 0)

# 3. And it must still FAIL on a file that is genuinely unbalanced, both ways — a tool that
#    says yes to everything is as useless as one that says no.
check("an unclosed form", "(defun f ()\n", 1, want_status=1)
check("a stray close", "(defun f ()))\n", -1, want_negative=True, want_status=1)

if failures:
    print("FAIL")
    for f in failures:
        print(" -", f)
    sys.exit(1)
print("PASS")
