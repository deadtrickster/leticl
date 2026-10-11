<!-- abstract: Where TODO.md's queue stands after 2026-10-11: 21 boxes closed, 5 open, the merge queue two of five steps in, and each remaining item's first step and traps. -->

# The TODO.md queue, handed over (2026-10-11, updated)

**Closed 21 boxes this session**, each verified against the SOURCE rather than the prose: T2–T8
(T1's own text says what stays open is a daemon-side half and a design limit), both git-format
rows, `/todo rm N`, the mid-turn model sentence, the settle handover, the three
found-while-working divergences recorded at their sites, and the strands *diff+highlight*,
*screens+frame*, *cards+markdown+width*.

**FIVE of them described work that had already landed** — so PROBE EVERY BOX against the tree
(`def-test` in `tests/tests.lisp`, `grep` over `src/`) before believing it. The inverse bit too:
one row looked identical to the already-done ones and was genuine work.

## The merge queue (the box that is moving) — steps 1 and 2 are IN

Landed: `make-list-merge-queue`, a `head-merge-queue` slot, `/queue` (which ASKS through
`%toggle-pane` and opens the pane), the reply fold (replaces, never merges — a queue is a
snapshot), the two events (`merge_entry_added` replacing by id so a replay cannot double the
queue; `merge_entry_moved` setting state and keeping the evidence it has when the event carries
none), `merge-queue-lines` (the renderer) and `merge-queue-pane` (class, `:queue` keyword, lines,
cursor rows, hint). Tests: `the-merge-queue-is-asked-for-and-its-answer-is-kept`,
`the-merge-queue-draws-its-states-and-why-each-one-is-that-state`.

**Traps measured, so they need not be re-learnt**:
1. A wire frame cannot land without its CALLER — the suite's
   `every-frame-constructor-is-actually-sent` refuses a frame defined and never sent.
2. A verb cannot land without its ROW in `*slash-commands*` — the registry/dispatcher drift test.
3. A pane registered in `*pane-classes*` but absent from `%handle-key`'s **pane arm mode list**
   DRAWS and receives no keys at all.
4. `the-diagnostic-verb-…` read `*unreadable-total*` without binding it; the third instance of
   *a test that reads the world instead of its own state*. It binds it now.

**Remaining steps**: the person's hand (approve / veto / rm — three new client frames AND the card
that carries them, which is why it is not a one-turn piece); the standings with the gate's steps in
the gate's own order; the review queue as two views of one list with `/queue reset|clean|restart`.

## The rest

- **`!term` pane + VT renderer** — a project; the brief is in TODO.md.
- **the two reference batches** — backlogs of features, each naming its commit; every clause is now
  probed, so the file says which are landed and which are real.
- **the socket write that can block the head** — MEASURED: `:timeout` on the socket stream does
  NOT bound a blocking `write(2)` on a Unix socket. The fix is `O_NONBLOCK` + an EAGAIN loop, or a
  writer thread.

## Two things only the operator can do

1. **Restart the heads.** The leticl head wedges (a stale eval holds the paint lock; the 5-second
   deadline makes later evals SAY so, but only a restart frees it), which is why two
   `ask_user_question` calls went unanswered.
2. `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl` — `~/bin/leticl` is a COPY and
   drifts; `~/bin/letibot` is already correct (all five TUI exec sites go through `$HEAD`).

## Habits

`edit` not heredocs for source; `count-parens.py <file>` after every edit (it caught five
unbalanced tails this session); clear `~/.cache/common-lisp` AND `*.fasl` before a suite run;
`git commit -F <file>` (backticks in `-m` get shell-substituted); and the suite's own guards catch
a docstring with a raw `"` (three times), `(is (signals …))`, and a `format` string whose `~:[…~]`
branches are the wrong way round.
