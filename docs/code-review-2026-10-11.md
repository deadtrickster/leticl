# Code review, 2026-10-11 — eight read-only reviewers

Eight subagents reviewed this tree with no particular focus (bad practices, stale comments and
comments that contradict their code, dead code, refactorings, performance), each on one surface,
read-only. This file is their findings, triaged; the ones already fixed say so and name the
commit. Order inside each section is severity, not importance to the reader.

**How to read a finding.** A finding is a *hypothesis with evidence*: the reviewer quotes code and
says what it checked. Treat anything marked high as verified by the reviewer and worth checking
again before acting; anything I have already acted on is inline.

---

## Fixed already (this review's first pass)

| Where | What |
|---|---|
| `src/editor/pane-keys.lisp`, `src/panes/subagents.lisp` | **`%subagent-switch` indexed the event fold while the pane draws stops** — with events `[A done, B running]` the pane draws B at `sel 0` and Enter/`o` switched into A; on a list-derived pane they did nothing. Found independently by the panes reviewer and the editor reviewer. Deleted; Enter, `o` and `p` all go through `subagent-stop-at`. `ctrl-o` corrected to the reference's unconditional `promote()`. `b3e45f1` |
| `tests/tests.lisp` OSC-8 scan | The balance check compared **four** characters against a **five**-character needle, so it counted 0 and 0 on every screen. `6330e54` |
| `tests/tests.lisp` pin test | `(is (not (search "message" "")))` — searches the empty literal, a constant. Fixed to search the drawn lines. `6330e54` |
| `tests/tests.lisp` wheel test | Three process globals `setf`-ed with no binding, leaking into every later test. Bound. `6330e54` |
| `tests/tests.lisp` fold round-trip | The "into the child and back" was two slot assignments with nothing running between them. Now presses Esc through `%handle-key`, which is a real path since the way-up arm landed. `6330e54` |

---

## Panes (`src/panes/`, `src/pane-protocol.lisp`)

- **`%subagent-switch`** — fixed, above.
- **high — `config.lisp:70-87`: `marker_seam` cannot be flipped.** The row is drawn with the edit mark and dispatched as `:head`, but `%flip-head-setting` has no arm for the key: Enter writes head.toml, changes nothing, and reports the value unchanged. `%set-marker-seam` is documented as its only writer and nothing calls it.
- **medium — `config.lisp:222-237`: a variable number of lines per row against a click map that assumes one.** The pane pushes a section heading and a blank between groups, and a `from …` line under the selected row, while `click-row->sel` uses `per-row 1` and a constant header — a click lands on another row. `todos-lines` already returns its stop lines; `config-lines` should too.
- **medium — `session-picker.lisp:141-142` vs `submit.lisp:212-213`: a typed number switches to the wrong session.** The pane numbers only parent rows (children are `↳`-marked), and `%resolve-session` reads the number as an index into the interleaved list. `[P1, C1, P2]` draws `2` on `P2` and `2` resolves to `C1`.
- **medium — `peek.lisp:208-213`: `*peek-prompt-only*` is set and never cleared**, so a prompt-only view outlives the press; the docstring promises Enter and `/peek` clear it.
- **medium — `status.lisp:123`: a literal `\n` inside a Lisp string** — the row reads `a countern above these values points again`. (The same defect class as the heredoc quote trap; nothing pins the sentence.)
- **medium — `pane-protocol.lisp:249-250`: the twelve pane classes are written twice** (`*pane-classes*` and the `dolist` that installs the methods) — a pane in one list and not the other draws NOTHING, silently.
- **medium — `pane-protocol.lisp:263-265`: `pane-cursor-rows` for `:todos` answers the repo's rows**, not the cursor's stops — contradicting the protocol's own contract. Unreachable today (both callers special-case `:todos`), so a trap rather than a live bug.
- **low** — `repo-todo-lines`, `repo-todo-stops`, `slash-out-row-count` have no call site; `%todo-md-toggle-line` refuses a line whose *prose* mentions `[~]`; the todos pane ignores its width entirely (`(declare (ignore cols))`); per-frame quadratic work in `session-picker.lisp:141` (`subseq` per row) and `repo-todo.lisp:745` (`(length out)` and `(nth at stops)` per row).

## Editor and commands (`src/editor/`, `src/commands/`, `src/repl/`, `src/hack.lisp`)

- **high — `dispatch.lisp:51`: Enter answers the prompt request even when the card is AWAY.** The esc arm is gated `(not *prompt-away*)`; the Enter arm is not — so the line goes to the running command instead of being held. The reference gates both.
- **high — `hack.lisp:121,223,245`: the eval socket's guards catch `error` only.** `CONTROL-STACK-EXHAUSTED` is a `SERIOUS-CONDITION` and not an `ERROR` — verified on this box — so a form that exhausts the stack takes the head down in the accept thread.
- **medium — `replay.lisp:168`: `*key-draft*` is not reset by `with-replay-globals`** though the ladder reads it and the render draws it; `*todo-draft*` is bound for exactly this reason (*"a leaked draft made every later pane test's Esc go to a card nobody could see"*).
- **medium — `dispatch.lisp:74`: `:dash` is missing from the ctrl-c close list** — ctrl-c on the dashboard offers to quit the head.
- **medium — `click-actions.lisp:18-21`: `%pick-card-top` recomputes the card's top** from the full card and the hint bar, omitting the notice row, the stall row, the alarm row and the fit ladder's trim — a click on a mode/model/verbosity card selects a neighbour.
- **medium — `submit.lisp:92`: `!send` is a raw five-character prefix**, so `!sender foo` reaches the command as `er foo` and a bare `!send` runs a shell command called `send`. The reference's `send_line` requires whitespace or end.
- **medium — `overlay-keys.lisp:65-72`: an open ask claims the page keys and the wheel** whenever the composer is empty, even when the card has nothing to scroll.
- **medium — `help.lisp:19`: `/help` has no `! COMMAND` and no `!send LINE` row**, though this head implements both and the prompt card tells the operator to type `!send LINE`.
- **medium — `dispatch.lisp:407-412`: `ctrl-d` leaves the head at once**, where the reference routes it through the quit card.
- **low** — `:q-press` is an arm for a key no decoder produces; the draft arm reports an answer `%answer-decision` refused to send; an unreadable directory is reported as a prefix that matches nothing; `%slash-completions` is rebuilt per frame; `/lisp` re-wraps its whole scrollback per frame.

## Cards (`src/cards/`)

- **high — `roles.lisp:205,226,229`: `%sgr-to-style` is broken three ways** — `(push :bold style)` pushes a bare keyword (so `(apply #'append …)` either returns a keyword or signals: `(append :bold '(:dim t))` → *":BOLD is not of type LIST"*), and the `39` arm compares `:fg` against the list `(:fg)` so `ESC[39m` never resets a colour. An operator-run row with any SGR bold/dim takes the frame down; `%paint-line` has no test.
- **medium — `decisions.lisp:172-176`: the docstring says the oracle block "cannot fire today"; it fires** — `seq-gap.lisp:504` copies `:advice` onto the settled decision.
- **medium — `user-card.lisp:228`: a stale claim and the duplicate it justifies** — `%user-parts-text` is now byte-for-byte `item-display-text`'s `:user` arm.
- **medium — `assistant-card.lisp:8-40` vs `turn.lisp:120-152`: `raw-call-lines` is defined twice, identically**, and the later load wins; the earlier copy's docstring says it is "here and not beside either of them".
- **medium — `notice-card.lisp:167-225`: `%job-notice-facts` is dead (~59 lines)** and `user-card.lisp:150` cites it as the authority for what the row draws.
- **medium — `static-cards.lisp:37-49,74-88`: the split left both trailing comment blocks one method out of place.**
- **low** — `awhen-edit-lines` and `%payload-line-count` have no call site; five `card-lines` methods bind an unused `item` (SBCL style warnings on every build); `item-lines.lisp:103` is half a sentence; nine citations point at files the split removed; the notice prefixes are spelled twice; `%tool-result-lines` is one 278-line function with six concerns.

## Drawing (`src/chrome/`, `src/render/`, `src/cells/`, `src/diff.lisp`, `src/sidediff.lisp`, …)

- **high — `history-cache.lisp:167`: the history cache KEY wraps the whole reasoning text on every frame** to compute a line count the key does not need to recompute (~0.23 ms per call for a 20 KB reasoning text, per frame while the turn thinks).
- **high — `composer.lisp:121,356,385,471,474`: the composer buffer is fully wrapped five times per frame**, each call consing a fresh range list.
- **medium — three quadratic index walks on every memo miss**: `diff.lisp:89-93` (Myers copies the whole `v` per D), `sidediff.lisp:92-99` (`nth` in a loop, plus `length` per iteration), `diff.lisp:194-203` (`nth` over the changed list).
- **medium — `history-cache.lisp:952`: `*hist-depth*` is never reset** (a process-lifetime high-water mark), so a deep scroll in one session makes every later session walk to that depth; `peek.lisp` `setf`s the global instead of binding it.
- **medium — `composer.lisp:65`: the composer's top edge re-folds the whole subagent event list every frame**, quadratically (a `reverse` plus a `find` per envelope).
- **medium — `history-cache.lisp:64-67`: the cache-key comment claims inputs the key does not have** (the item count and the three prefs; the generation carries them).
- **medium — `composer.lisp:418-420` and `border.lisp:44-45`: character truncation against a cell budget**, so a wide-character buffer or path overflows the row it was sized for.
- **low** — `render-diff` appends per row; `carry.lisp:105-107` duplicates a width sum on a false load-order claim; `hint.lisp:62 vs :100` give two different lengths for the same bar; `%fit-ladder`'s `comp-p` is dead; a comment fragment from a split is glued to a section header; a docstring with literal `\n`; diff and sidediff spell four constants and two sentences twice; the tab stop `4` is a literal in six call sites; `pad-to` is dead; **~80 Rust citations and ~38 in-tree citations can no longer be followed** (the reference deleted `width.rs`, `diff.rs`, `markdown.rs` on 2026-10-08 — the code is now in the `rano` dependency — and the in-tree ones name pre-split files).

## The test suite (`tests/`)

- **high — `tests.lisp:23208`: the OSC-8 balance check is vacuous** — fixed (`6330e54`).
- **high — `tests.lisp:24349`: four assertions sit inside `(when (probe-file (dash-flowy-seat-file "claude-lab2x1")))`**, a file in the operator's `~/.config` — on any other box the branch never runs and the test is green having checked nothing.
- **high — `replay.lisp:145`: `(is (>= results 0))` on the test's own counter** — a tautology; a fixture with no tool rows passes silently.
- **high — `tests.lisp:3649`: two `(is (integerp (click-header-lines h)))`** — the function ends in `(or sel-line 0)`, so both are always true.
- **high — `tests.lisp:3141`: the assertion is satisfied by the line above it** — the first disjunct is the slot the test just set; `paint-wanted-p` is never called.
- **medium** — `:12710` docstring states the opposite rule to its assertion; `:22940` a stray `1` becomes FiveAM's format argument (truthiness only); `:14577` an invariant loop with no count assertion; `:15420` the style is passed in and asserted back; `:26834` degrades to `(search "" …)`; `:861`, `:1444` cannot fail; `:22717` a guard named "every preference write" skips `src/prefs/`; `:3499` claims ctrl-p is unbound while `:3473` asserts it is bound; **leaked globals** at `:11684` (`*answered-calls*`, `*item-facts*`) and `:20613` (`*pick-open*`); **~25 scratch directories left per run** (`%dash-temp-dir` has no cleanup; `/tmp/leticl-todos-test` and friends are fixed paths cleaned only as files); `:10086` writes into a hardcoded foreign session's scratchpad; `:3033` an exact-integer assertion on a wall clock.
- **low** — dead helpers (`%note-rows` duplicates `%warning-rows`; `%segments-of` duplicates `segs-of`; `%blank-line-p` and friends unused); stale citations (`tests.lisp:1772`, "eleven files" for 19, `scripts/tui-eval:220`); a comment claiming a check with no assertion after it.
- **No test names** (grep over the token stream; every one is reached from a tested file, so this is *not covered by name*, not *unexercised*): `src/prefs/format.lisp`, `src/prefs/path.lisp`, `src/editor/click-actions.lisp`, `src/editor/overlay-keys.lisp`, `src/cards/{tool-result-card,write-card,static-cards}.lisp`, `src/chrome/status.lisp`, `src/repl/entry.lisp`. The ones the reviewer would treat as genuinely unexercised: the hand-rolled prefs parser, the prefs path resolver, and the two mouse modules.

---

## The wire and the session core (`src/protocol/`, `src/session/`, `json.lisp`, `socket.lisp`, `term.lisp`)

- **high — `the-wire.lisp` `Caps.can_decide` could be elided** — FIXED (`bd71bcc`).
- **high — `operator-line-refusal` diverged from the shared rule on a trailing newline** — FIXED (`bd71bcc`).
- **high — `session/compaction.lisp:203`: the only writer of `*compaction-sections*` is never called.** `%fold-settings` has zero callers; the `settings` arm sets `head-settings` and stops. So the daemon's section list and the `(not stated)` mark are unreachable, while the docstring promises *"a reader that renders the second as the first has reported silence as a clean bill of health."* The suite hides it by binding the variable by hand. Fix: call it on the settings row and test through a real frame.
- **high — `protocol/versions.lisp:113-120`: the version record still argues for announcing 25** and cites an ATTACH refusal the daemon no longer performs (*"A differing protocol version is ACCEPTED, and said — never refused on the number alone"*, `f6e66f0`), while the constant is 42.
- **high — `the-operator-call-door.lisp:166`: `+outcomes-taking-a-reason+` is `("failed")`** on an inference the daemon's enum contradicts: `Abstained{reason}`, `Denied{req_id}`, `NotRun{why}`, `Backgrounded{…}` all carry payload. Building one of those outcomes without its fields is a frame the daemon's read loop answers with `Bye`. Unreachable today only because no tool runners are seated.
- **medium — `the-wire.lisp:11-12`: the header's elision claim** is right about the mechanism and wrong about the reason (*"serde defaults them daemon-side"* — `Caps.queue`/`can_decide` do not default).
- **medium — `json.lisp:4-9`: the file header contradicts the encoder it documents** ("never elides… nil becomes null"; the body omits every nil key and has a vector arm so `#()` writes `[]`).
- **medium — `warnings.lisp:173`: `+failure-warnings+` has drifted.** Five codes with remedies are in neither list (`merge_not_queued`, `operator_run_unreadable`, `operator_shell_failed`, `prompt`, `prompt_late`), so `every-note-code-offers-a-remedy` walks past them.
- **medium — `events.lisp:29` names `+reading-never-hides+`, which does not exist** (the list is the denylist `+reading-hides+`).
- **medium — `the-wire.lisp:79-83`: `items` is no longer a required field** (the daemon added `#[serde(default)]` after this head's own failure).
- **medium — `versions.lisp:3-4`: "the constructors below are the only place that knows what a frame looks like" is false** — `slash`, `mode`, `secret`, `compact_session`, `reseat_session` and `promote` are hand-built at five sites, one of which omits `consented`.
- **low** — six `+reject-*+`/`+note-compact-queued+` constants are read by nothing; `item-display-text` is dead while another file's comment claims it feeds search; `reset-filling` has no caller (so a resumed restore bar can survive a `/switch`); `appendf-text` copies the whole reply per delta and is unguarded where its neighbours are guarded; `outcome-name`'s fallback reports a string outcome as `"ok"`; four copies of the same settings-row lookup; ~30 `app.rs:NNNN` citations now point at a file the reference deleted.

