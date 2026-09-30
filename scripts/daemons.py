#!/usr/bin/env python3
"""daemons — every harnessd, with its workspace, its socket, and whether it is closing.

The question this answers: "there is a daemon for this workspace, so why will a head not attach?"
A daemon that has been told to stop keeps its socket and its pid while it drains, so `ps` says it is
alive and a head connects and is immediately told goodbye. Nothing in a plain process list shows that.
"""
import os
import subprocess

print("%-9s %-9s %-11s %-46s %s" % ("pid", "ppid", "state", "socket", "workspace"))
out = subprocess.run(["ps", "-eo", "pid,ppid,stat,cmd"], capture_output=True, text=True).stdout
rows = []
for line in out.splitlines():
    if "harnessd" not in line or "grep" in line or "python3" in line:
        continue
    parts = line.split()
    pid, ppid, stat = parts[0], parts[1], parts[2]
    sock = next((w for w in parts if w.endswith(".sock")), "-")
    ws = "-"
    for i, w in enumerate(parts):
        if w == "--workspace" and i + 1 < len(parts):
            ws = parts[i + 1]
    # is the socket still there, and does the process hold it?
    alive_sock = os.path.exists(sock) if sock != "-" else False
    rows.append((pid, ppid, stat, sock, ws, alive_sock))

for pid, ppid, stat, sock, ws, alive_sock in rows:
    print("%-9s %-9s %-11s %-46s %s" % (pid, ppid, stat, sock if alive_sock else sock + " (GONE)", ws))

print()
print("state `Ssl` with a socket that GONE-headed heads are being told goodbye by = closing.")
