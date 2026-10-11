<!-- abstract: TODO.md handover after 2026-10-11: 25 boxes closed, 3 open, the !term pane landed (frames, keys, line discipline, escape counting) and the VT renderer identified as a PORT from rano's local term/. -->

# The TODO.md queue, handed over (2026-10-11, end of session)

**25 boxes closed, 3 open, 1 in flight. Suite 7809/7809; tree green; everything pushed; image frozen.**

Closed includes T2–T8, both git-format rows, `/todo rm N`, the mid-turn model sentence, the settle
handover, the three strands (*diff+highlight*, *screens+frame*, *cards+markdown+width*), the carry by
the row's own words, the edge buttons, the job label, the standing-notes pane, the merge queue's whole
READ half, and the `!term` pane.

## THE THREE THAT REMAIN — and none of them is an invention

1. **The VT emulator (the `!term` box's other half)** — **IT IS A PORT**: `rano` is a LOCAL project
   (`/home/dead/Projects/rano`) and ships its own terminal, **`rano/src/term/` — 3021 lines across six
   modules** (`decode`, `event`, `features`, `graphics`, `links`, `terminal`). The reference head drives
   it, and this tree ports the reference everywhere else. What is already in the pane — the character
   walk, the column model, the escape counting — is the frame it plugs into. `ESC [ H` stays COUNTED
   until the port brings ROWS, which is what answers the ambiguity that looked like a design decision.
2. **The rano integration** — which answers FOUR items at once: `ctrl-e` (an `EditorPane` holding a
   rano instance behind the composer, toggled, reached by rano's `open-file` key), the standing-notes
   row's `Enter`, and the queue's own arrangement (the reference's queue pane IS a rano widget).
3. **The daemon's queue acts** — `approve_entry`/`veto_entry` live in `tokencore/src/store.rs`; the
   reference's TUI has NO verb for them, so a head must not invent frames.

Plus the socket-write refactor: `O_NONBLOCK` + an EAGAIN loop, or a writer thread (`:timeout` on a
socket stream does NOT bound a blocking `write(2)` — measured).

## THE `!term` PANE, AS IT NOW STANDS

Landed: the four client frames (`term_open`/`term_input`/`term_resize`/`term_close`) and three server
folds (`term_attached`/`term_output`/`term_ended`), the `head-term` slot, the `/term` verb (which opens
the pane rather than sending a second `TermOpen` the daemon refuses), **the keys a shell needs** (Enter
as `#\return`, Tab and Backspace as DEL `#x7f`), **line discipline** (`\r` OVERWRITES, it does not
clear), **escapes dropped and counted**, `ESC [ K` honoured, and `ESC [ 2 J` clearing the screen with
the CSI parameter now read. What is missing is the emulator's hard half — and the pane SAYS so rather
than drawing a confident wrong screen.

## TRAPS MEASURED (read before touching a pane, a frame or a verb)

1. **A wire frame needs its CALLER** — `every-frame-constructor-is-actually-sent` refuses one without.
2. **A verb needs its ROW** in `*slash-commands*` (the registry/dispatcher drift test).
3. **A pane needs its MODE-LIST ENTRY** in `%handle-key`'s pane arm.
4. **An arm must sit ABOVE its siblings** in `%pane-key` — a pane's own Enter arm is earlier than the
   character arms, and a terminal's Enter was eaten by an act the pane does not have.
5. **A key a pane needs must be taken before the paths that assume a composer is the reader** — the
   completer claims `:tab`, so the terminal's arm goes at the TOP of `%handle-key`'s cond.
6. **A test that reads a process global is fragile** — bind what you assert on.
7. **THERE ARE TWO `dispatch.lisp` FILES**: verb arms in `src/commands/dispatch.lisp` (where `%command`
   is), mode lists in `src/editor/dispatch.lisp` (where `%handle-key` is). Three attempts put an arm in
   the wrong one and read the failure as an anchor problem.
8. **ESCAPING RECIPE**: to put a control character in a Lisp string from a script, hand `format` a `~c`
   and a literal `#\escape` as an ARGUMENT — a backslash in a Lisp string escapes the next character
   literally, so `"\r"` is the letter `r`. Five attempts died on that.
9. **FOUR FLAT `cond` ARMS beat one arm with a `cond` inside it** — the nested form failed twice on a
   stray paren; the flat form landed first try.
10. **A signature change wearing a feature's clothes**: returning a cons broke callers written an hour
    earlier; `(values …)` did not. And a docstring with a raw `"` cuts itself short — the tree's own
    `NO-DOCSTRING-IS-CUT-SHORT-BY-AN-UNESCAPED-QUOTE` catches it (four times today).

## Two things only the operator can do

1. **Restart the heads.** The leticl head wedges (a stale eval holds the paint lock; the 5-second
   deadline makes later evals SAY so, but only a restart frees it) — which is why four
   `ask_user_question` calls went unanswered.
2. `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl` — `~/bin/leticl` is a COPY and
   drifts; `~/bin/letibot` is already correct.

## Habits that paid

`edit` not heredocs for source; `count-parens.py <file>` after every edit; **assert every string
replacement in a script** (an unasserted one is a coin flip, and the suite is what catches it); clear
`~/.cache/common-lisp` AND `*.fasl` before a suite run; `git commit -F <file>`; and VERIFY A LEDGER'S
CLAIMS AGAINST THE TREE — five of this file's boxes described work that had already landed.
