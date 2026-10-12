# AGENTS.md

## Merge gate

The merge queue runs these in a branch's worktree, after rebasing it onto `main` and before landing
it; the first that fails parks the branch. Read from `main`'s copy of this file, so a branch cannot
change its own gate.

Two things the commands below carry that are not obvious, both measured on 2026-10-11:

- **The fasl cache is cleared first.** A stale one makes the counts LIE rather than fail — a run
  against a stale cache reported `7,844 checks` where the truth was `8,359`, and it does so
  silently. The delete is cheap and the difference is a green run that tested something else.
- **The suite needs room.** SBCL is killed outright by a 64 MiB cap, and the run peaks around
  350 MiB. A gate runner that caps a command at that default will see this suite fail for a reason
  that has nothing to do with the branch.

```sh
rm -rf ~/.cache/common-lisp
find . -name '*.fasl' -delete
sbcl --noinform --disable-debugger --script run.lisp test
```
