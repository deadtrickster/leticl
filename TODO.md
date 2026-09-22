# leticl — TODO, for the switch

Derived from `PARITY.md` and the four measurements under `docs/parity/`. The
previous list — twelve strands, `S0`–`S11`, `P1`–`P46` — is archived whole at
`docs/archive/2026-09-20/TODO.md` along with the measurement it came from. It is
not carried forward, because it was written against a different question.

**The question now is the switch.** The operator wants leticl as their primary
head. So an item earns a place here by answering *"when would this stop me, and
how would I know it had been fixed"* — not by being a feature the reference has.

Status: `[ ]` open · `[~]` in flight · `[x]` done, with the commit.

## The reference is pinned, and it moves

| repo | commit | date |
|---|---|---|
| `letibot` (reference) | `8af671e3467ce0a139ba25d99a18378ba39c910b` | 2026-09-20 |
| `leticl` (this) | the commit each row names | |

Every citation in `docs/parity/` is a line in **that** commit. Before acting on
one, `git -C ~/Projects/letibot/letibot log --oneline 8af671e..HEAD` and re-read
the function: a citation is a pointer into a moving tree, not a specification.
When the numbers stop matching, **re-measure the document** rather than guessing
which line moved.

## The two gates, and what "done" means

1. **Gate 1 — the suite.** `sbcl --script run.lisp test` at 100%. Every closed
   item carries a test that **fails without the change**.
2. **Gate 2 — the live head.** `scripts/tui-eval --tree` pushes the tree to the
   running head and `--where` says `PUSHED`; then the behaviour is exercised on
   that head, and for anything visible `scripts/compare-heads` agrees with
   letibot.

A commit is not the gate. *"S6 panes done"* was once recorded against code in
which three panes had never rendered at all, and an attach indicator passed its
test while never drawing, because the test proved the renderer and not the
predicate.

---

## Landed

| item | what it was | commit |
|---|---|---|
| **W-breakages** | `/mode NAME` closed the connection (a `bool` encoded as `null`); the walking cat never drew; twenty-one notice sites had nowhere to print | `4e32354` |
| **terminal** | a crash left the terminal raw, alternate-screen, cursorless — `unwind-protect` never runs when a saved image does not unwind | `aa049f0` |
| **prefs** | an unreadable `head.toml` refused to start the head | `4051d13` |
| **wire** (20 of 25) | reconnect and resume had never worked; `ToolStarted` stuck on `proposed`; `ToolProgress`'s note lost; tokens assigned not `max`; no `turn_id` filter; session-scoped state carried across a switch; protocol pinned to 21 | `723098a` |
| **input** (22 of 24) | no printable character reached the composer under any pane; the decision ladder needed an empty prompt; `ctrl-c` wrong four ways *(including: every keystroke into a password ask was a type error)*; paste markers collided; word and vertical motion | `b305374` |
| **the replayed ask** | a reconnect replays from the read mark, so an ask the head had already drawn arrived again: `session.lisp` pushed a twin per delivery (`open` at 2, then 3) and `head.lisp` zeroed `head-decision-sel` on it, undoing the operator's keystroke — which is what *"selector didnt work"* … *"works on restarted"* was | `36b75e2` |
| **T5, the ladders' order** | the decision ladder was the tail of the key chain, so a permission arriving over an open session list left ↑↓ moving the PICKER; the reference asks the ask first (app.rs:3609) and keeps only the deliberate overlays ahead of it (:3384, :3417, :3481) | `6b87351` |
| **R3, unreadable frames** | a frame this head could not read was consumed and counted NOWHERE — the reader turned a bad line into a status note that expired, and an unknown frame or event tag fell through in silence, which makes *"this daemon is sending me something I do not understand"* look exactly like a quiet daemon. Now said in the conversation, counted on `/status` and the border, and survived | `f70920d` |
| **R5, a protocol skew** | the `Hello` version check EXITED the head and said so on a note that expires. It now names the DIRECTION (a newer daemon is a reading problem R3 answers; an older one is a writing problem this head cannot survive from its side), files the sentence in the conversation, and stays attached; `/status` has a `protocol` row that reads `not told yet` before the handshake | `3025082` |
| **R8, the context size** | the header's `ctx` came from the TURN only, so it vanished after a restart, a reattach or a resume — `TurnFinished` is ephemeral. It now falls back to the session's own row (`context_tokens`/`context_cached`), which the daemon writes at every round finish; the cache fraction is refused unless the row measured it, and a backfilled row never lights the money meter | `R8` |
| **§2.5, the carry and filling line** | one renderer for a counted operation, whoever counted it. The daemon states it when it can (`filling {what, unit, done, total}`); the head infers only from a BULK announcement, says no cause, counts arrived-of-total rather than `peak - pending`, and both thresholds are measured (`64` rows above an ordinary turn's tail, `5 s` against a 31 ms measured body) | `R-filling` |
| **§2.5, the carry line** | a fork announced every carried row before a body followed, and drew one placeholder per row — *"insane amount of grainess"*. One line now, in the cat and the bar the head already had: `1400 of 2702 rows`, landed cells `█` and never `▓`, the count derived from the rows themselves rather than from a tally or from how many still lack a body, and the line stops claiming to be progress after three seconds of no movement | `R-carry` |
| **T1, the payload window** | a long tool result had an UNREACHABLE TAIL: the fold raised the budget and gave no row an offset, so `… +N lines · ctrl-t` named a chord that revealed nothing past forty lines. `ctrl-t` now opens a window on the newest pageable row, ↑/↓ page it, `esc` closes it, and the three seams say which key does what and where the reader is | `f655e7a` |
| **W1, double-width text** | `%split-words` split on spaces alone, so a CJK paragraph was one chunk; it was then cut by CHARACTER INDEX against a COLUMN budget, so each piece was `2×cols` columns and the painter dropped the overflow in silence — **156 of 300 clusters reached the screen**. Now wraps at the column budget over clusters, and a newline in a wrapped text is a hard break instead of a character the painter discards | `W1` |
| **§3.2's third candidate** | **FOUND.** `%sgr` is bounds-checked — an out-of-range style costs one cell's colour, not the frame — and **any paint that failed forces the next one to be FULL**, because `head-prev-screen` is the head's only record of the terminal and a diff against a wrong record is a permanent hole. Measured: with the paint injected to die after `ESC[2J`, the head believed it had drawn 30 rows the terminal had none of, and no ordinary paint could repair it; `screen-resize` allocates a fresh cell vector, which is why a byobu window switch was the only cure. **The sync pair is RULED OUT** — tmux-256color advertises no `Sync` and the pair is balanced in every frame of a `pipe-pane` capture — and so are copy mode and a mode reset | `§3.2` |
| **T1(1), `FetchRow`** | `items_dropped` was stored and read by NOTHING, so a head on a long session drew a window as if it were the whole conversation. Now a seam above the oldest row (`… N rows above · scroll to this line to load the next`), a fetch asked for on demand when the reader reaches the top, the row prepended, and `… the daemon does not hold them any more` when it answers `null`. **Measured: the frame cannot currently answer anything** — the snapshot is `view.items.clone()` and `row_body_at` reads the same list, so the other half is letibot's R19.2(b), a store read for a trimmed ordinal | `T1(1)` |
| **§3.1, terminal safety** | **PROVEN, not patched.** Every source the section names (prose, reasoning, the user's message, the system row, a fence body, a diff excerpt off disk) carrying every real byte (SGR, `?1002`/`?1006`/`?1049`/`?2004`/`?2026`, an OSC, C1, DEL) — no ESC-prefixed sequence reaches stdout, on a frame carrying 103 of the head's own. The guarantee is ONE invariant: the frame is a cell grid, `screen-put-string` skips zero-column clusters, and a control character measures zero, so it has no cell to be written into. The sources are unsanitised and safe; `%without-control` is belt-and-braces. **letibot's painter writes ANSI-bearing strings verbatim, so its exposure is real — the property to build toward is that a control character must not be STORABLE in a cell** | `§3.1` |
| **a `seq` gap** | MISSING IN BOTH: a jump forward in the event stream is filed as a row and counted (`jumped from 40 to 52 — 11 events never arrived`), while a step of one and a step backwards are the redelivery §13.2b promises and are not reported. `dropped` only says what the daemon admits to at a `Hello`/`Resync` | `§10` |
| **§6, the last of the B-side list** | `ctrl-x` on a settled row (the pref did nothing on a transcript — one `raw-call-lines` for both halves now); the attach deadline (30 s, naming `letibot --status`/`--stop`, because a daemon that took the connection and said nothing is HUNG, not absent — this head waited for ever); a row labelled `on disk` is RESUMED, not switched to; `/switch` resolves a row number or a title like the picker does; `/rename`'s two guards; `ctrl-b`/`ctrl-f`/`ctrl-_` | `§6` |
| **§2.6, fence languages** | the info string resolved by its **first word** (comma, then whitespace, case-insensitively) against `rano::syntax::Lang::from_token`'s own token table, so every fence carrying an attribute colours and 27 more tokens resolve — only where this build HAS the grammar (`xml`/`svg` reach the HTML grammar; a language with no grammar is not in the table). **RULED: `console` is not a language** — plain, in both heads, because a transcript's bytes are mostly output and colouring them as bash invents structure that hides them | `§2.6` |
| **§3.3, `truncate-target` + §1.7's question answer** | the cap is **120 columns** (the reference's 120 BYTES under-filled by 2 on ASCII and by a factor of two on wide text; this head's 120 CHARACTERS let 61 CJK through at 122 columns). **RULED: both heads count columns.** And the strip class is C0 + DEL + **C1** — `0x9B` was kept here and stripped there, so the two measured the same target differently | `§3.3` |
| **§1.6, the gate card's deadline** | MISSING IN BOTH heads: both carried `deadline` and `on_timeout` and drew neither, while both drew a countdown on the secret card. Now a ladder (`expires in 5 min` → `1m59s left` → `47s left`), the consequence of silence in the daemon's own words, a state for a card whose clock has already run out, and nothing at all when there is no deadline. Found while measuring it: the secret card's countdown subtracted a Unix instant from a monotonic counter (R13's two-clocks trap, second place) | `§1.6` |
| **R13, a live elapsed time** | the running call's number was already read from this head's own clock and MOVES (`75637 -> 78680 ms`); the FRAME was frozen (`Running · 1m19s` four seconds on the glass), because only an event set `head-dirty`. The loop now has a second reason to paint — the clock, at `+live-frame-ms+` 100, while anything on the frame is a function of time — and the running number is rounded down to a tenth while the settled one is not | `R13` |
| **R15, the edit row's label** | the operator's `Edited […] …/src/commands.lisp`: a batch edit writes its `edits` array before its `path`, so the elision took the best position on the row to point at the diff drawn underneath it. A nested value is now a PLACEHOLDER and not a part of a label — dropped when the arguments name a subject, kept where they name nothing (`todo_write`, a `pkill` modifier). The elision rule itself stays | `0446585` |
| **the notice's clock** | a magenta `permission answered` stuck above the composer, measured as a note with NO clock beside it (`:note "permission answered" :ttl 0`, identical 2 s later, while the loop painted). The deadline is now a millisecond on the head — `+notice-ttl-ms+` 1600, the wall time the 60 frames already were — armed only by `say` and stopped only by `clear-note`, so a frame-counted timer cannot stop when the frames do and a global cannot be shadowed away from the note it ages | `57d20dc` |
| **a request is not an outcome** | the operator chose *leave and stop the daemon* and it stayed — measured against a real daemon: the stop ARRIVES (its `daemon_stopping` warning is in the next snapshot) and the daemon then takes `EPIPE` writing the ack, with `registry.close()` behind that write; one millisecond of pause is the whole race (0 ms → stuck, 1 ms → gone in 221 ms). The head now waits for the daemon's ABSENCE with a saying, deadline-bounded row, and names the pid and `letibot --stop` when it does not go | `df5b66a` |
| **R10, a warning is a disclosure** | the mirror of letibot's wall: a `Warning` went into `session-warnings` and was read by nothing, so `auto_compact`, `compacted`, `context_wall`, `transcript_store`, `decision_corpus` and `mode_set` had never once reached this head. Now drawn as a row where it arrived, folded to three lines plus a `… +N lines · /notes` seam, retired by `/notes`/`/dismiss` into a set keyed `(code detail ts)` **outside the transcript** — so a resync and a reattach replant the wall retired instead of replanting it — and counted on `/status` as `notes  N of M retired`. The four specialised homes (`turn_failed`, `job_output_refused`, `slash`/`slash_refused`, `secret_late`) are kept | `R10` |

## In flight

- [~] **cards + markdown + width** — `cards.lisp`, `markdown.lisp`, `width.lisp`,
  `cells.lisp`. Priority one is **escape sanitising**: tool output currently
  reaches the terminal unfiltered, and the reference closed that in `f36d927`
  ("a tool's output cannot reconfigure the operator's terminal"). **The width half is
  closed**: W1 landed the wrapping rules, and the structural commit after it merged
  the two breakpoint scanners into one (`%break-ranges`, used by `wrap-segments` AND
  `wrap-ranges`) and deleted the third truncator, which was per-character and silent.
  **What is left is the same shape one level up and is NOT closed**: a row composed
  wider than the frame is cut by the PAINTER — `screen-put-string` drops every cell
  past the right edge without a word — so the hint bar ends `ctrl-q ` where the
  reference ends it `ctrl…`. It is why the bottom row differs in every fixture of the
  1:1 rig, and it is `rendering.md` §6 gap 23.
- [~] **screens + frame** — `panes.lisp`, `chrome.lisp`, `render.lisp`. The
  picker opening off your own session; the peek pane's dead cursor; the
  permission card drawing one line of the oracle's five; no fit ladder. **The
  carry line landed** (`filling-progress-line`, §2.5) — one renderer, the daemon's
  count when it states one and the head's own inference otherwise — and **R6 depends
  on it**: the opencode import must have the UI up and a COUNTED progress line live
  *before* anything is read, because read-then-draw turns a background job into a
  startup dependency. **The leticl half is done; the daemon half is NOT.** See
  `docs/parity/rendering.md` §1.10 — the event is ruled to be
  `SessionEvent::Filling {what, unit, done, total}`, replacing `ImportProgress`
  inside protocol 23 rather than a second version decision, and letibot's tree has
  another agent in it: I did not edit it. leticl folds BOTH names, with the old one
  translated through a named compatibility arm that is to be deleted when the
  rename lands.
- [~] **diff + highlight** — `diff.lisp`, `sidediff.lisp`, `highlight.lisp`.
  Dead intra-line emphasis; SAPs passed unpinned across the FFI; every visible
  fence re-parsed through the shim on every frame.

## §11 of the requirements doc — the five that are MINE

**Filed 2026-09-22 on the operator's instruction, before working them, so they survive a
compaction.** `~/Projects/head-parity-2026-09-21.md` §11 tracks eight items with an owner
and a default each; **the default is this head's recommendation** unless the operator says
otherwise (stated rather than assumed). Five are mine. They are here in the order the
operator set, and the rulings are quoted because the *reason* is the part that would be
lost.

- [ ] **§11.1 · §3.3 — write the criterion PER LAYER.** *Default: rule per layer; change
  NEITHER head.* A daemon's cap is a **byte** cap and is allowed to be one (`TARGET_MAX_BYTES`,
  120 bytes, `sessionlog/src/event.rs:288`); a head's cap must be a **column** cap (120
  columns, `*target-max-cols*`). Both picked 120; only the unit differs, and only off ASCII
  (120 bytes = 40 CJK = 80 columns). The reason a daemon may not be asked to move: **it has
  no terminal to count columns with** — the target is cut before any head exists. Criterion
  edit only; no code in either head. Same edit retires §3.3's entry-level `Drift`, which
  still says *"A should move"*.
- [ ] **§11.2 · R10 — the criterion stays at *survives a resync and a reattach*.** *Default:
  A's persistence to `head.toml` is a superset it may keep; restart-survival becomes its
  OWN row if it is ever wanted, never a widening of this one.* The criterion's sentence is
  the one both heads pass. **Say in that row that it is the only item on this list that
  writes to the operator's config directory** — the reason it must not be widened by
  accident. Criterion edit only.
- [ ] **§11.4 · R17 — drop the word "repairs" and keep both behaviours.** *Default: what
  must not differ is that a gap is SAID and COUNTED — and the two heads already agree on
  exactly that.* A queues `Action::Resync` itself (`app.rs:2484-2512`); this head files the
  row, counts it, and names `/resync`. **The criterion must say that who presses the key is
  the HEAD's choice, and why** (a resync REPLACES the transcript, so an automatic one moves
  the ground under a reader who did not ask), or the next reader re-opens it. Criterion edit
  only.
- [ ] **§11.5 · §2.6/C14 — point the GUARD at `rano`**, and this is the one with code in
  it. Leave this head's copy (`*fence-tokens*`, `src/markdown.lisp:252`); the defect is that
  `every-token-rano-knows-is-a-token-this-head-knows` (`tests/tests.lisp:1108`) carries a
  **third** hand-written copy of the token list in its own body, so **the guard cannot fire
  for a token nobody wrote down — the drift it exists to catch is exactly the one it cannot
  see**, which is §2.6's own shape one layer up. `rano` is an absolute path dependency in
  three `Cargo.toml`s, so the tree is reachable. **The test must keep failing when it should**
  — falsify by adding a token to `rano` and watching the check fire.
- [ ] **§11.8 · move `acceptance.md` into the requirements document.** *Default: into
  `~/Projects/head-parity-2026-09-21.md`.* It describes **both** heads and sits in one tree;
  leaving it where it is was the default nobody chose. **The concurrency risk is real and is
  the one edit tonight that already lost work** (the §2.6 stash) — so move it when the other
  writer is not in the file, and leave a pointer at the old path.
- [ ] **§11.6 · `NotScoped`, HALF MINE AND SECOND IN LINE.** *Owner: letibot rules the
  wording (it owns `JobState::word`); both heads render the same string.* **Wait for the
  string rather than guessing it** — if the two differ it is a new drift rather than a fix.
  When it arrives: the line says *it never ran* rather than *it wrote nothing at all* under a
  header that already says `not run (could not join its scope)` (`panes.lisp`'s empty-log
  branch, letibot `app.rs:8407-8416`).

**Not mine, tracked here so the list is whole:** §11.3 R13 (A moves the notice TTL to wall
time), §11.6's wording (A), §11.7 R18's card (A).

## Open, in the order they would stop the operator

- [~] **T1 · the payload window** (`keys.md` G13/G20, `wire.md` W2,
  `panes.md` G4/G10). **Two of its three parts are closed and the third is a BOUND
  rather than a defect** — so what keeps this row open is a daemon-side half and a
  design limit, not work here.
  `f655e7a` gave the fold a real window: the OFFSET exists —
  `ctrl-t` opens a window on the newest pageable row, ↑/↓ page it by ten lines,
  `esc` closes it, and three seams say which key does what and where the reader is
  (`↑ N more lines above · ↑ scrolls up`, `… +N lines · ↓ pages down · esc closes`,
  `… end of output · esc closes`). What is NOT there, part by part:
  (1) **CLOSED here**: a row above the head's window is now disclosed and fetched —
  the seam `… N rows above`, the ask on demand when the reader reaches the top, the
  row prepended, and `… the daemon does not hold them any more` when it answers
  `null`. But the daemon cannot answer one (`view.items` is both what the snapshot
  clones and what `row_body_at` reads — one view, one bound), so the other half is
  letibot's R19.2: a store read for a trimmed ordinal. `ViewBounds` still trims at
  2000 rows / 8 MB; (2) one window at a time, on the newest row, because the
  transcript has no pointer to aim one with;
  (3) **CLOSED, and this line said otherwise for most of a day — MEASURED
  2026-09-22**: Enter on a jobs row opens the job's output in a pane. It landed in
  `b7a2620` (2026-09-21 00:00) with six tests, and this clause was written at
  `f91f3ae` (22:20) from `panes.md`/`keys.md`/`wire.md`, which were measured at
  `7c2c6fc` — twenty-three minutes BEFORE the fix. Live, on a real daemon and a real
  finished job: `job output — j74`, `exited 0 — bytes 0..899 of 899`, the bytes
  themselves, the jobs list still behind it. One window at a time is (2); (1) is its
  own item.
- [ ] **T2 · the launcher** — `~/bin/letibot` needs `exec "$HEAD"` at its four
  remaining TUI exec sites and `~/bin/leticl` replaced by `scripts/leticl`;
  blocked on the operator, since the edit is in their own `~/bin`. Until then
  `leticl` in a folder with no daemon refuses instead of starting one. Size S.
- [ ] **T3 · `--replay FILE.jsonl`** (`panes.md` G18). The reference's head
  replays a session log with no daemon, no socket and no model, which is what
  makes its screen tests deterministic — `head -n K` and the head renders the
  state it was in at event K. We compare against a live session instead, which is
  why both heads have to be nudged into the same state by hand, and why one
  comparison in this round was not a controlled test. Size L, and it pays for
  itself in every later round.
- [ ] **T4 · `--resume ID`** (`panes.md` G9). `scripts/leticl-head` rewrites it
  to `--session`, which cannot work for a session the daemon does not hold
  (app.rs:1602-1610). Size M.
- [x] **T5 · the ordering of the ladders** — with the session picker open and an
  ask arriving, ↑↓ moved the picker; the reference puts the decision ladder above
  the picker (re-measured on the pin below: the ladder is app.rs:3609 and the
  session picker :3643 — the `3474`/`3508` this row used to carry were a lineref
  that moved). Landed in `6b87351`, with the overlays that keep the arrows under an
  ask — `:peek`, `:job-out`, `:config` — written down on both sides of it. Size S.
- [ ] **T6 · `Todos` and `Jobs` replies ignore their `session_id`**, so a reply
  for a session this head has left is applied to the one it is on. One `equal`
  each in `%handle-frame`. Size S.
- [ ] **T7 · the render instrumentation, not the cache.** The reference renders
  zero rows on a steady frame; we rebuild the window every frame (0.46 ms at
  210×63). `rendering.md` argues against porting `hist_lines` — its invalidation
  key would have to include five defvars any eval can change, and a screen cache
  is a second source of truth in a head whose contract is that redefining a
  renderer changes the next frame. Port the counter and a test that bounds
  `item-lines` calls per frame first. Size M.
- [ ] **T8 · the rest of `docs/parity/`** — every finding not claimed above, each
  already carrying its citation, its size and its assertion. Work them by size
  within a strand's files, never across.

## Found while working, and not fixed

Each of these is a DIVERGENCE FROM THE REFERENCE that is currently invisible on the
screen, so none of them is worth a commit of its own. They are written down here
because an invisible divergence is exactly what this repo has been bitten by (the
`endp-open` that promised a cursor reset and was `(declare (ignore …))`).

- **`asked-ts` is the wire's `ts`, and the reference makes it 0.** `session.lisp`
  stores `:asked-ts (getf env :ts)` where the reference stores `asked_ts: 0` and says
  why (app.rs:2617: *"the snapshot path at `apply` carries the real `asked_ts`"*).
  **Read by neither codebase** — the reference's field is written in three places
  and read in none — so it is a value waiting for a feature, and if that feature is
  the *"waiting 40s"* edge it must come from the head's clock, not the wire.
- **The open-decision list runs the other way round.** Ours is NEWEST first (Lisp
  `push`), the reference's is OLDEST (`Vec::push` appends, app.rs:2601), and both
  take `first`. Unobservable while the daemon serializes on the tool call and only
  one ask is ever open, which is why it is a note and not a change; it is recorded
  at the slot itself (`session.lisp`).
- **The quit card swallows every key here, including the head's own chords.**
  Ours is `((head-quit-open head) (%quit-card-key …))`, so the clause is taken for
  every key and the body's NIL is discarded — `ctrl-t` under the quit card does
  nothing. In the reference the global chord match is at app.rs:3152, BEFORE the
  card at :3698, and the card's `_ => {}` falls through — so its `ctrl-t` still
  toggles the fold. Fail-closed is the safer reading and the operator has not hit
  it; the one thing that must not happen is a future reader believing the two
  heads agree about it.

## The DAG

```
T2 ──────────────────────────────► (the operator's own ~/bin)
T3 ──► every later comparison round
T1 ──► needs: wire (landed) + a pane overlay (screens strand)
T4 ──► needs: T1's frame work, or its own
T5, T6, T7, T8 ── independent
```

The three strands in flight are file-disjoint and can land in any order; each is
merged, tested, pushed to the live heads and re-captured before the next.

## The rules that cost this repo the most

- **A feature that is not on the screen is not done.** Three panes were recorded
  done while never having rendered; the attach indicator passed a test while
  never drawing. Gate 2 exists for this.
- **Live state is a `defvar`.** A struct slot is a layout change, which is a
  restart, which is the one thing a live-patchable head must not need.
- **Push serially.** Only the orchestrator runs `--tree` against the operator's
  head; a strand works in a worktree and reports.
- **The reference's own bug reports are the best specification available** — they
  say what the operator saw and why the obvious fix was wrong. Read the commit
  message before the code.
