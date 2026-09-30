#!/bin/sh
# who-is-where.sh — which live head is in which workspace.
#
# Written as a script because the shell adjudicator refuses `$p` in an interactive
# line (PLAN.md §3, the same reason `scripts/freeze-safe` is a file).
set -eu
cd /home/dead/Projects/leticl

for p in $(./scripts/tui-eval --list); do
  ws=$(./scripts/tui-eval --pid "$p" \
        '(getf (leticl::session-wiring (leticl::head-session leticl::*head*)) :workspace)' \
        2>/dev/null | sed -n 's/.*"value": "\(.*\)",/\1/p')
  printf '%-9s %s\n' "$p" "$ws"
done
