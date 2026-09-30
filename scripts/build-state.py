#!/usr/bin/env python3
"""build-state — what is BUILT, what is RUNNING, and whether they are the same bytes.

Two trees, two binaries, and the failure this exists to catch is the one that has
already happened: a binary rebuilt on disk while the process serving you still runs
the old code (Linux lets a running process keep its deleted file), so every check
that only looks at the disk says "rebuilt" and the session behaves like it was not.

  · letibot  -> target/release/harnessd, one process per daemon
  · leticl   -> bin/leticl-head,          one process per head

For each: the commit, the binary's mtime, whether any source is NEWER than the
binary (a stale build), and every running process with whether it maps THAT file.
"""
import hashlib
import os
import subprocess

TREES = [
    ("letibot   harnessd", "/home/dead/Projects/letibot/letibot",
     "target/release/harnessd", "harnessd"),
    ("leticl    head", "/home/dead/Projects/leticl",
     "bin/leticl-head", "leticl-head"),
]

for label, root, rel, procname in TREES:
    print("=" * 68)
    print(label)
    print("=" * 68)
    commit = subprocess.run(["git", "-C", root, "log", "--oneline", "-1"],
                            capture_output=True, text=True).stdout.strip()
    print("  commit :", commit)

    binary = os.path.join(root, rel)
    if not os.path.exists(binary):
        print("  !! no binary at", binary)
        continue
    st = os.stat(binary)
    import time
    print("  binary : %s  %d bytes" % (time.strftime("%m-%d %H:%M:%S", time.localtime(st.st_mtime)),
                                       st.st_size))

    # a source file newer than the binary means the build is stale
    newer = []
    for dirpath, _, names in os.walk(os.path.join(root, "crates" if "letibot" in root else "src")):
        for n in names:
            if n.endswith((".rs", ".lisp")):
                p = os.path.join(dirpath, n)
                if os.stat(p).st_mtime > st.st_mtime:
                    newer.append(os.path.relpath(p, root))
    if newer:
        print("  STALE  : %d source file(s) newer than the binary:" % len(newer))
        for p in sorted(newer)[:6]:
            print("           ", p)
    else:
        print("  build  : current (no source newer than the binary)")

    # every running process, and whether it maps THIS file
    out = subprocess.run(["ps", "-eo", "pid,cmd"], capture_output=True, text=True).stdout
    print("  running:")
    n = 0
    for line in out.splitlines():
        if procname in line and procname not in ("",) and "grep" not in line:
            pid = line.split()[0]
            try:
                exe = os.readlink("/proc/%s/exe" % pid)
            except OSError:
                continue
            if "deleted" in exe:
                state = "OLD CODE (its file was replaced while it ran)"
            else:
                try:
                    same = os.stat(exe).st_ino == st.st_ino
                except OSError:
                    same = False
                state = "current binary" if same else "DIFFERENT FILE"
            print("    %8s  %s" % (pid, state))
            n += 1
    if n == 0:
        print("    (none running)")
print()
print("A rebuilt binary does NOT update a running process: restart it to pick the fix up.")
