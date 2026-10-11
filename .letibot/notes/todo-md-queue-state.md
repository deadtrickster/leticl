<!-- abstract: Where TODO.md's queue stands after 2026-10-11: 21 boxes closed, 5 open, and what each remaining one needs first. -->

# The TODO.md queue, handed over (2026-10-11)

**Closed 21 boxes this session**, each verified against the SOURCE rather than the prose: T2–T8
(T1's own text says what stays open is a daemon-side half and a design limit), both git-format
rows, `/todo rm N`, the mid-turn model sentence, the settle handover, the three
found-while-working divergences recorded at their sites, and the strands *diff+highlight*,
*screens+frame*, *cards+markdown+width*.

**FOUR of them described work that had already landed.** So: probe every box against the tree
before believing it — `def-test` in `tests/tests.lisp`, `grep` over `src/`. The inverse bit too:
one row looked identical to the already-done ones and was genuine work.

## What is open, and its first step

- **the merge queue pane** — decomposed into five sized steps in the file itself; start with the
  two wire frames (`ListMergeQueue` → `MergeQueue`, plus `MergeEntryAdded`/`MergeEntryMoved`) and
  their folds, which is S and leaves nothing on screen.
- **`!term` pane + VT renderer** — a project; the brief is in TODO.md and the rectangle contract
  is the merge queue's sibling.
- **the two reference batches** (48- and 116-commit mirrors) — backlogs of features, each naming
  its commit; several sub-items are already landed and marked.
- **the socket write that can block the head** — MEASURED: `:timeout` on the socket stream does
  NOT bound a blocking `write(2)` on a Unix socket (a peer that never reads still blocked a
  minute later). The fix is `O_NONBLOCK` + an EAGAIN write loop, or a writer thread.

## Two things only the operator can do

1. **Restart the heads.** The leticl head wedges (a stale eval holds the paint lock; the 5-second
   deadline makes later evals SAY so rather than hang, but only a restart frees it), which is why
   two `ask_user_question` calls went unanswered.
2. `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl` — `~/bin/leticl` is a COPY and
   drifts; `~/bin/letibot` is already correct (all five TUI exec sites go through `$HEAD`).

## Habits that paid off here

`edit` not heredocs for source; `python3 scripts/count-parens.py <file>` after every edit (it
caught four unbalanced tails this session); clear `~/.cache/common-lisp` AND `*.fasl` before a
suite run; `git commit -F <file>` (backticks in `-m` get shell-substituted — bit me twice); and
the suite's own invariant tests catch a docstring with a raw `"` (three times) and
`(is (signals …))`, which reads as a form and lets the error escape.
