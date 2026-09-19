#!/usr/bin/env python3
"""The render gate, against a REAL head: does it catch a head that stops painting?

This one needs a live daemon (bin/leticl-head attaches to $LETIBOT_SOCKET or,
here, the daemon discovered for this workspace). It starts a THROWAWAY head on
its own pty, so it never touches a head you are using, and it proves the two
things that matter:

  1. a healthy eval exits 0 and the gate reports the head is painting full
     frames (`stdout=ok rows=N/N`);
  2. an eval that clobbers the head's stream — the exact live-push accident
     that tore the operator's screen — is CAUGHT: exit 3, naming *stdout*;
  3. recovery puts the gate back to green.

scripts/test-tui-eval.py tests the same gate logic against a fake head, with no
daemon needed; this file is the end-to-end proof against a real one.
"""
import os, pty, signal, socket, struct, subprocess, sys, time, fcntl, select, termios

root = "/home/dead/Projects/leticl"
env = {k: v for k, v in os.environ.items() if k != "LETIBOT_SOCKET"}
os.chdir(root)
pid, fd = pty.fork()
if pid == 0:
    # no --session: attach to whatever this workspace's daemon serves, so the
    # test does not name one operator's session.
    os.execve(root + "/bin/leticl-head", [root + "/bin/leticl-head"], env)
    os._exit(1)
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
except OSError:
    pass

def drain():
    while True:
        r, _, _ = select.select([fd], [], [], 0.1)
        if not r:
            return
        try:
            if not os.read(fd, 65536):
                return
        except OSError:
            return

sock = None
for d in (os.environ.get("XDG_RUNTIME_DIR") or "", "/run/user/{}".format(os.getuid()),
          "/tmp/leticl-{}".format(os.getuid())):
    if not d:
        continue
    cand = os.path.join(d, "tui-{}.sock".format(pid))
    t0 = time.time()
    while time.time() - t0 < 30:
        drain()
        if os.path.exists(cand):
            sock = cand
            break
        time.sleep(0.2)
    if sock:
        break
print("scratch head pid", pid, "ready:", bool(sock))
assert sock, "the scratch head never opened its hack socket"


def run(*args, timeout=60):
    r = subprocess.run([root + "/scripts/tui-eval", "--pid", str(pid)] + list(args),
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


print("\n=== 1. a healthy eval: gate passes, exit 0 ===")
rc, out, err = run("(head-cols *head*)")
print("rc:", rc, "| gate:", [l for l in err.splitlines() if l.startswith("gate:")])
assert rc == 0, "a healthy eval must exit 0"

print("\n=== 2. --screen: the real capture reaches stdout ===")
rc, out, err = run("--screen")
assert rc == 0, "--screen should exit 0"
assert "leticl" in out and "seq" in out, "--screen should show the drawn frame"
assert out.count("\n") > 10, "--screen should show many rows"
print("rc:", rc, "| captured lines:", out.count("\n"))

print("\n=== 3. the bug this gate exists for: clobber *stdout* ===")
rc, out, err = run("--no-verify", "(setf *stdout* nil)")
print("clobber rc:", rc, "(no-verify, so 0)")
rc, out, err = run("(head-cols *head*)")
print("rc:", rc)
print("stderr:", err.replace("\n", "\n         "))
assert rc == 3, "the gate must FAIL on a clobbered *stdout*, got rc={}".format(rc)
assert "stdout" in err, "the gate must name *stdout* as the problem"
print("\n*** the gate caught it ***")

print("\n=== 4. recover, and confirm the gate goes green again ===")
rc, out, err = run("--no-verify",
                   "(progn (setf *stdout* (sb-sys:make-fd-stream 1 :output t "
                   ":element-type 'character :external-format :utf-8 :buffering :none)) "
                   "(setf (head-full-repaint *head*) t) :ok)")
rc, out, err = run("(head-cols *head*)")
print("rc:", rc, "| gate:", [l for l in err.splitlines() if l.startswith("gate:")])
assert rc == 0, "after recovery the gate must pass again"

try:
    os.kill(pid, signal.SIGTERM)
except OSError:
    pass
print("\nPASS")
