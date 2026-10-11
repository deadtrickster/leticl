<!-- abstract: TODO.md handover after 2026-10-11: 24 boxes closed, 4 open, the five traps this session measured, and what each remaining item is blocked on. -->

# The TODO.md queue, handed over (2026-10-11, session end)

**24 boxes closed, 4 top-level open.** Closed: T2–T8, both git-format rows, `/todo rm N`, the
mid-turn model sentence, the settle handover, the strands *diff+highlight* / *screens+frame* /
*cards+markdown+width*, the carry by the row's own words, the edge buttons, the merge queue's
first two steps, and the standing-notes pane (renderer + wire + pane). Suite **7714/7714**,
tree green, everything pushed and the image frozen.

## THE FIVE TRAPS THIS SESSION MEASURED — read these before touching a pane or a frame

1. **A wire frame needs its CALLER**: a constructor with no sender fails
   `every-frame-constructor-is-actually-sent`. Land the ask with the frames.
2. **A verb needs its ROW** in `*slash-commands*`: the registry/dispatcher drift test refuses a
   verb the moment it exists without one.
3. **A pane needs its MODE-LIST ENTRY** in `%handle-key`'s pane arm (and in the ctrl-c list): a
   pane registered in `*pane-classes*` but absent there DRAWS and receives no keys.
4. **A verb needs its OPEN**: `/standing` asked and never opened — the arm was written for trap 1
   and the open was never wired. Fixing trap 1 is not opening the pane.
5. **A test that reads a process global is fragile**: `the-diagnostic-verb-…` read
   `*unreadable-total*` unbound, so inserting a test above it turned it red. Bind what you assert
   on.

And `:timeout` on a socket stream does NOT bound a blocking `write(2)`: measured. The fix is
`O_NONBLOCK` + an EAGAIN loop, or a writer thread.

## What is open, and what each is blocked on

- **the merge queue, steps 3–5** — the person's approve/veto/rm are the **DAEMON's** acts
  (`tokencore/src/store.rs`: `approve_entry`, `veto_entry`; a test named *a veto parks the row and
  a remove forgets it*), and the reference's TUI has **no** verb for them, so a head must not invent
  frames. `MergeState` has **seven** states (`Waiting, Taken, Landed, Failed, Conflict, Stale,
  Vetoed`) — six are drawn, `vetoed` is deliberately plain pending a screen to decide its register.
- **the standing-notes row's remainder** — `Enter` opening the note in rano (`81749c9`) and the
  rest of `NoteForm`'s vocabulary. Depends on the rano integration, i.e. the `!term` project.
- **`!term` pane + VT renderer** — a project: a program owning the conversation's rectangle. The
  same rectangle contract as `ctrl-e`, which the reference implements as an `EditorPane` holding a
  **rano instance** behind the composer, toggled, reached by rano's own open-file key (`F8`).
- **the two reference batch rows** — backlogs; every clause is probed and the file says which are
  landed.

## Two things only the operator can do

1. **Restart the heads.** The leticl head wedges (a stale eval holds the paint lock; the 5-second
   deadline makes later evals SAY so, but only a restart frees it) — which is why four
   `ask_user_question` calls went unanswered.
2. `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl` — `~/bin/leticl` is a COPY and
   drifts; `~/bin/letibot` is already correct.

## Habits that paid

`edit` not heredocs for source; `count-parens.py <file>` after every edit (it caught five
unbalanced tails); clear `~/.cache/common-lisp` AND `*.fasl` before a suite run; `git commit -F
<file>` (backticks in `-m` get shell-substituted). The suite's own guards catch a docstring with a
raw `"`, `(is (signals …))`, a `format` string with its `~:[…~]` branches reversed, and a `let`
where the initialiser reads a sibling binding.
