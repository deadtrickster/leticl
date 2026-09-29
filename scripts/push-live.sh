#!/bin/sh
# push-live.sh PID — push every source file's top-level forms into a live head.
#
# HACKING.md documents this as a typed loop, but the shell adjudicator refuses
# `$f` in an interactive line (PLAN.md §3), so it lives here the way
# `freeze-safe` does.
#
# **Order matters.** `package.lisp` skips to a no-op (the package already
# exists), and the rest are pushed in glob order, which is the order the image
# was built in. A file whose forms are not live — a struct, a macro, the
# toplevel — will say so rather than silently doing nothing; the caller reads
# the output rather than the exit status, because tui-eval prints a condition
# and still exits 0 in some cases.
set -eu

PID="$1"
cd /home/dead/Projects/leticl

ok=0
bad=0
for f in src/*.lisp; do
  if out=$(./scripts/tui-eval --pid "$PID" --file "$f" 2>&1); then
    case "$out" in
      *ERROR*|*error\ during*|*unbound*|*undefined*)
        echo "PUSHED WITH A CONDITION: $f"
        printf '%s\n' "$out" | head -6
        bad=$((bad + 1)) ;;
      *)
        ok=$((ok + 1)) ;;
    esac
  else
    echo "FAILED: $f"
    printf '%s\n' "$out" | head -6
    bad=$((bad + 1))
  fi
done

echo "pushed $ok files clean, $bad with something to read"
[ "$bad" -eq 0 ]
