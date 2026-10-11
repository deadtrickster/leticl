<!-- abstract: TODO.md handover after 2026-10-11: 24 boxes closed, 4 open, the merge queue's read half complete, the six traps measured, and what each remaining item is blocked on. -->

# The TODO.md queue, handed over (2026-10-11, later)

**24 boxes closed, 4 top-level open.** Suite **7759/7759**, tree green, everything pushed, image
frozen. Closed includes T2–T8, both git-format rows, `/todo rm N`, the mid-turn model sentence, the
settle handover, the three strands (*diff+highlight*, *screens+frame*, *cards+markdown+width*), the
carry by the row's own words, the edge buttons, the job label, the standing-notes pane, and the
merge queue's whole READ half.

## THE MERGE QUEUE'S READ HALF IS CLOSED — what is in

`make-list-merge-queue`, the `/queue` verb (asks AND opens), a `head-merge-queue` slot, the reply
fold (replaces — a queue is a snapshot), `merge_entry_added` (appends by id, REPLACING so a replay
cannot double) and `merge_entry_moved` (state + evidence, keeping the evidence it has), the pane,
`merge-queue-lines` (state, branch, PRIORITY, what it waits for, evidence), the gate steps in the
gate's own order (four outcome words, and an empty checklist NEVER drawn — it reads as *all steps
passed*), `merge-standings-line` + its wiring on the composer edge (review/merging/parked, drawn
only while something stands), `merge-review-line` + its drawing (a verdict, an unanswered ask and a
DEATH kept apart), and `:merge-detail` — Enter on a row shows the entry in full, Esc returns.

**What remains on that box: the daemon's own acts.** `approve_entry`/`veto_entry` live in
`tokencore/src/store.rs`; the reference's TUI has NO verb for them, so a head must not invent
frames. `MergeState` has SEVEN states; six are drawn, `vetoed` stays plain deliberately.

## THE SIX TRAPS MEASURED HERE — read before touching a pane, a frame or a verb

1. **A wire frame needs its CALLER** — `every-frame-constructor-is-actually-sent` refuses one
   without. Land the ask with the frames.
2. **A verb needs its ROW** in `*slash-commands*` — the registry/dispatcher drift test refuses it.
3. **A pane needs its MODE-LIST ENTRY** in `%handle-key`'s pane arm (and the ctrl-c list): a pane
   in `*pane-classes*` but absent there DRAWS and receives no keys at all.
4. **A verb needs its OPEN** — fixing trap 1 is not opening the pane.
5. **A test that reads a process global is fragile** — bind what you assert on.
6. **A key event is `(:type :enter)`**, not `(:type :key :key :enter)`; a renderer's `let` needs
   `let*` when an initialiser reads a sibling; `(count s :test #'search)` is a type error.

And `:timeout` on a socket stream does NOT bound a blocking `write(2)` — measured. The fix is
`O_NONBLOCK` + an EAGAIN loop, or a writer thread.

## What is open, and what each is blocked on

- **the merge queue's acts** — the daemon's store (see above).
- **`!term` + VT renderer, `ctrl-e`, the notes row's `Enter`, the queue's rano-side arrangement** —
  ALL the RANO integration: the reference's own queue pane IS a rano widget
  (`ui/panes/queue.rs:2`), and `ctrl-e` is an `EditorPane` holding a rano instance behind the
  composer. One project answers four items.
- **the socket-write refactor** — `O_NONBLOCK` + an EAGAIN write loop, or a writer thread.
- **the two reference batch rows** — every clause probed; most are landed or the other half's.

## Two things only the operator can do

1. **Restart the heads.** The leticl head wedges (a stale eval holds the paint lock; the 5-second
   deadline makes later evals SAY so, but only a restart frees it) — which is why four
   `ask_user_question` calls went unanswered.
2. `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl` — `~/bin/leticl` is a COPY and
   drifts; `~/bin/letibot` is already correct.

## Habits that paid

`edit` not heredocs for source (five unbalanced tails caught by `count-parens.py`, which is
mandatory after every edit); clear `~/.cache/common-lisp` AND `*.fasl` before a suite run; `git
commit -F <file>` (backticks in `-m` get shell-substituted); and verify a ledger's claims against
the tree — four of this file's boxes described work that had already landed.

## LATER THE SAME SESSION: the `!term` pane is real now (suite 7809/7809)

The `!term` box went from *"a project"* to a working pane. What is IN, each with its test:

  · the four client frames (`term_open`/`term_input`/`term_resize`/`term_close`) and the three
    server ones folded (`term_attached`/`term_output`/`term_ended`), the `head-term` slot, and the
    `/term` verb — which opens the pane rather than sending a second `TermOpen` the daemon refuses;
  · **the keys a shell needs**: Enter as `#\return`, Tab and Backspace as DEL `#x7f`, all sent as
    `TermInput`;
  · **line discipline**: `\r` OVERWRITES (it does not clear), so a progress bar is one line;
  · **escapes are DROPPED AND COUNTED**, `ESC [ K` is honoured (erase to end of line), `ESC [ 2 J`
    clears the screen, and every sequence the head cannot honour is counted and said.

What is MISSING is the VT renderer's hard half — cursor addressing, scroll regions, the alternate
screen — which needs a DECISION before code: `ESC [ H` (home) is ambiguous in a line model (a redraw
of the whole screen, or a position within one), so honouring it would be guessing. The pane says this
out loud rather than drawing a confident wrong screen, which is the rule the whole box now holds.

## THREE ORDERING LESSONS FROM ONE PANE (plus the traps above)

1. a pane needs its entry in `%handle-key`'s pane-arm MODE LIST;
2. an arm must sit ABOVE its siblings in `%pane-key` (a pane's own Enter arm is earlier than the
   character arms, so a terminal's Enter was eaten by an act the pane does not have);
3. a key a pane needs must be taken before the paths that assume a composer is the reader — the
   completer claims `:tab`, so the terminal's arm goes at the TOP of `%handle-key`'s cond.

**AND THE TRAP THAT COST MOST**: there are TWO `dispatch.lisp` files — verb arms in
`src/commands/dispatch.lisp` (where `%command` is), mode lists in `src/editor/dispatch.lisp` (where
`%handle-key` is). Three attempts put the arm in the wrong one and read the failure as an anchor
problem.

**AND AN ESCAPING RECIPE**: to put a control character in a Lisp string from a script, hand `format`
a `~c` and a literal `#\escape` as an ARGUMENT — a backslash in a Lisp string escapes the next
character literally, so `"\r"` is the letter `r`. Five attempts died on that.

**AND A SHAPE THAT WORKS**: four FLAT `cond` arms, each saying one thing, rather than one arm with a
`cond` inside it — the nested form failed twice on a stray paren; the flat form landed first try.
