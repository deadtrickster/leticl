#!/usr/bin/env python3
"""Count parens in a Lisp file, line by line.

Usage: count-parens.py FILE [FIRST_LINE [LAST_LINE]]

Ignores parens inside string literals, ; line comments, #| |# block
comments, and #\\( / #\\) / #\\X character literals. Prints the running
depth at the end of each line in the range, the range's net change, and
the whole file's final depth. Exits 1 if depth ever goes negative or the
file ends unbalanced.
"""
import sys


def scan(text):
    """Return (final_depth, {line: depth_at_end_of_line}, [problems])."""
    depth = 0
    line = 1
    in_string = False
    block = 0
    problems = []
    report = {}
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if in_string:
            if c == "\\":
                i += 2  # skip the escaped char (Lisp uses backslash)
                continue
            if c == '"':
                in_string = False
            if c == "\n":
                # a string may span lines; keep the line labels honest
                report[line] = depth
                line += 1
            i += 1
            continue
        if block:
            if c == "#" and nxt == "|":
                block += 1
                i += 2
                continue
            if c == "|" and nxt == "#":
                block -= 1
                i += 2
                continue
            i += 1
            continue
        if c == '"':
            in_string = True
            i += 1
            continue
        if c == ";":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "#":
            if nxt == "|":
                block = 1
                i += 2
                continue
            if nxt in "()":
                i += 2
                continue
            if nxt == "\\":
                i += 3
                continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                problems.append(f"line {line}: depth went negative")
        if c == "\n":
            report[line] = depth
            line += 1
        i += 1
    if not text.endswith("\n"):
        report[line] = depth
    return depth, report, problems


def main():
    if len(sys.argv) < 2:
        print(__doc__.strip())
        return 2
    path = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 1
    last = int(sys.argv[3]) if len(sys.argv) > 3 else None
    with open(path) as f:
        text = f.read()
    final, report, problems = scan(text)
    hi = last if last is not None else max(report)
    base = report.get(first - 1, 0)
    for ln in range(first, hi + 1):
        if ln in report:
            print(f"{ln:5d}  depth={report[ln]:3d}")
    end = report.get(hi, final)
    print(f"range {first}-{hi}: start depth {base}, end depth {end}, net {end - base:+d}")
    print(f"file final depth: {final}")
    for p in problems:
        print(p)
    return 0 if final == 0 and not problems else 1


if __name__ == "__main__":
    sys.exit(main())
