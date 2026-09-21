# Acceptance criteria — what a head can be RUN against

**Every requirement this document has ever stated, with the test that decides it.**

Written 2026-09-22, after a night in which seventeen requirements and a dozen section
fixes were implemented across two repositories, each with its acceptance criterion
written in the words of whichever head landed it, scattered through commit messages.
This is that material pulled together and made runnable.

**Companion to `docs/parity/{keys,wire,rendering,panes}.md`**, which measure *what
differs*. This measures *what must be true*, and it is the document phase 2 is driven
from: the requirements doc is the spec, and this is the suite.

---

## The shape of a criterion

Every entry below is written in the R3 shape, because R3 is the one the document keeps
returning to and it is the shape that survives being handed to somebody else:

> **send one line the head cannot parse, then a line it can** — and assert that the
> complaint arrived, that the following frame was still handled, and that the counter
> moved.

Three parts, always, and none of them is optional:

1. **SETUP** — the state the head is put in. Named, because half the defects in this
   document are only reachable in a state nobody thought to build.
2. **STIMULUS** — the exact bytes on the wire or the exact key. An idle head is not a
   test: *"a countdown that ticks for five minutes is furniture"* was decided by
   running one.
3. **ASSERTION** — what must be true, stated so that it is FALSE without the fix. This
   is the part that gets skipped and it is the only part that matters: **a test that
   cannot fail guards nothing** (§3.2).

## The instrument, and its two traps

    scripts/tui-eval --pid PID FORM      read or change one thing in a live head
    scripts/tui-eval --pid PID --screen  what the head last drew, ANSI stripped
    tmux capture-pane -p -e -t PANE      what the TERMINAL shows
    scripts/tui-eval --list              the live heads

**Both traps are measured, and both produced a wrong answer before they were
understood** (`HACKING.md`):

- **A measurement that takes time starves what it measures.** An eval holds the paint
  lock for its whole duration, so a `sleep` inside one freezes the loop it is timing:
  a 60-second probe made the loop look like one pass a minute. Put the sleep in the
  SHELL, between short evals. (The real rate is ~43 passes/s.)
- **A measurement can REFRESH what it measures.** `tui-eval` proves the head can paint
  by poking `head-dirty`, so a probe that watches the screen keeps it fresh. A frozen
  elapsed time read as *moving* through the socket and was frozen on the glass.

So: **to see what the operator sees, look at the screen** — `capture-pane`, or
`--screen` on a head you are not also probing — and keep the socket for reading and
changing state.

## The three statuses, and why they are the point

| status | means |
|---|---|
| **RUNS** | there is a test in `tests/tests.lisp` that fails without the fix, and I have run it |
| **RUNS + LIVE** | as above, and I have also demonstrated it on a real head — outside the suite, with the instrument above |
| **ARGUED** | the criterion is written and nothing runs it. **A sentence, not a test** — and that is the honest label, because a criterion nobody can run is what this document exists to stop shipping |

An entry marked ARGUED is not a criticism of the requirement. Several are simply A's
half, and one or two are requirements whose *criterion* nobody has settled yet.

---

# A. The gate — answering what was asked

## §1.1 A typed answer must reach the option the operator named

- **SETUP** an open permission with options `allow_once, allow_session, allow_always`.
- **STIMULUS** type `allow` and press enter; then type `allow_once`; then type a word
  naming nothing.
- **ASSERTION** the ambiguous word sends **nothing** and names the candidates; the
  exact id answers; the naming nothing sends nothing and keeps the ask open.
- **Evidence** `an-ambiguous-prefix-is-refused-and-names-the-candidates`,
  `a-prefix-names-an-option-when-it-is-unambiguous`, `a-typed-word-that-names-no-option-sends-nothing`, `deny-and-tell-takes-the-words-that-were-refused`.
- **Status RUNS.** `c1e02cd` + `an-ambiguous-prefix…`.
- **Drift** none on the criterion. The reference resolves an ambiguous prefix by list
  position (first match); leticl refuses. **Deliberate, and it means the two heads
  answer `allow` differently** — leticl declines, letibot picks. That is a phase-2
  question about the criterion, not about either implementation.

## §1.2 The ladder cursor must start where the operator put it

- **SETUP** an open decision.
- **STIMULUS** a second ask arrives; then a third.
- **ASSERTION** every fresh ask puts the cursor on row 0, and nothing resets it out
  from under a keystroke.
- **Evidence** `a-new-decision-starts-with-the-first-row-marked`,
  `a-redelivered-ask-is-the-same-question-not-a-fresh-one`.
- **Status RUNS.** `36b75e2` — a reconnect replays from the read mark, so an ask the
  head had already drawn arrived again and zeroed the selector.

## §1.3 The ladder must be reachable while a pane is open

- **SETUP** the session picker open, a permission arriving over it.
- **STIMULUS** ↓; then enter.
- **ASSERTION** ↓ moves the LADDER, not the picker; enter answers the ask.
- **Evidence** `an-open-ask-outranks-every-list-on-the-screen`.
- **Status RUNS.** `6b87351`.

## §1.4 One open decision per `req_id`, oldest first

- **SETUP** an ask drawn.
- **STIMULUS** the same `req_id` delivered again (a reconnect replays).
- **ASSERTION** `(length open-decisions)` stays 1, and answering still answers that
  question.
- **Evidence** `a-redelivered-ask-is-the-same-question-not-a-fresh-one`.
- **Status RUNS.** `36b75e2`.
- **Drift** none. Both heads dedupe on `req_id`; only the list ORDER differs
  (reference appends, this head pushes) and that is unobservable while one ask is
  open.

## §1.5 The card must say why it is asking

- **SETUP** a permission with a `because` field and one without.
- **STIMULUS** draw the card.
- **ASSERTION** the reason is drawn with the evidence, and **an absent reason is
  distinct from an absent oracle** — *"not asked"* and *"said nothing"* must not look
  alike.
- **Evidence** `a-decision-says-what-it-was-grounded-in`.
- **Status RUNS.**
- **Drift** this head says `no oracle was consulted` where the reference draws nothing;
  **deliberate** (an absence is evidence under `/mode supervised`). Phase 2 must decide
  whether the criterion says a card MUST say it.

## §1.6 The card must say what happens if nobody answers

- **SETUP** an open decision with `deadline` and `on_timeout`; then one with
  `deadline: null`.
- **STIMULUS** draw; wait; let the deadline pass; draw again.
- **ASSERTION** four states, and each is a different sentence —
  `expires in 5 min` · `47s left` · `past its deadline by 12s; the daemon has not said
  what became of it` · **nothing at all when there is no deadline** — plus
  what silence does, in the daemon's own words (`nothing runs` / `it RUNS anyway`).
- **Evidence** `a-deadline-is-drawn-coarse-until-it-is-worth-counting`,
  `a-deadline-is-read-on-this-heads-clock-not-the-daemons`,
  `a-card-with-no-deadline-says-nothing-about-time`, `the-card-says-what-silence-will-do`,
  `a-countdown-is-a-reason-to-repaint-but-not-a-tenth-one`.
- **Status RUNS + LIVE.** `550bc94`; measured on a scratch head at 300 s → `expires in
  5 min`, at 65 s → `1m04s left`, 12 s past → the past-tense sentence.
- **Drift** **B's criterion is the spec and A has not implemented it** (the document
  says so). The three rulings worth reading before A does: the ladder (coarse → seconds
  → past), that a past-deadline card must NOT count into negative seconds, and that an
  ask with no deadline says NOTHING about time (§13.2b answered in the other direction).

## §1.7 A `question` must be answerable

- **SETUP** an open `question` with two choices; then one with NO choices.
- **STIMULUS** type a choice's own text; type a word; type a sentence.
- **ASSERTION** a typed-out row answers that row **with no note**; a prefix answers with
  the rest as the note; an ambiguous prefix is refused; anything else goes as `free`.
- **Evidence** `a-question-answer-can-carry-a-typed-reply`.
- **Status RUNS.** `550bc94`.
- **Drift** **A cannot answer a question at all** (no `AnswerQuestion` action). Both
  were latent — `RequestKind::Question` is never constructed daemon-side — which is
  why neither head noticed.

# B. Content loss

## §2.1 Wide characters must not be written off the screen

- **SETUP** a paragraph of CJK; a paragraph mixing widths; a word wider than the row.
- **STIMULUS** render at a fixed width.
- **ASSERTION** every cluster reaches the screen; each row is within the column budget;
  a wide cluster is never split.
- **Evidence** `a-wide-character-line-wraps-at-the-column-budget`, `a-cjk-run-fills-the-row-it-started-on`, `an-over-wide-word-breaks-one-chunk-per-row`, `a-wide-cluster-is-not-broken-in-half`.
- **Status RUNS + LIVE.** `25039a5`; measured before/after on the live head: **156 of
  300 clusters reached the screen** before, 300 of 300 after.

## §2.2 A newline in content must break the line

- **SETUP** a text containing `\n`.
- **STIMULUS** render.
- **ASSERTION** the newline is a hard break, not a character the painter discards.
- **Evidence** `a-newline-in-the-text-is-a-hard-break-and-is-not-painted`.
- **Status RUNS.** `25039a5`.

## §2.3 A long tool payload must be reachable to its end

- **SETUP** a 60-line tool result, folded.
- **STIMULUS** ctrl-t; ↓; ↓; esc.
- **ASSERTION** the fold raises the budget **and gives an offset**; the seam names the
  key and where the reader is; esc closes the window and gives the arrows back.
- **Evidence** `a-long-payload-is-unreachable-until-a-window-is-opened`,
  `a-window-opens-on-the-newest-payload-that-has-one`,
  `a-payload-at-the-budget-shows-all-but-one-line`, `a-payload-window-does-not-take-the-asks-keys`, `a-fetched-row-goes-at-the-top-and-the-count-follows`.
- **Status RUNS.** `f655e7a`.

## T1(1) A row above the head's window is disclosed and fetchable

- **SETUP** a head holding a window (`items_dropped > 0`).
- **STIMULUS** scroll to the top; let the daemon answer.
- **ASSERTION** the seam says how many rows are above; reaching the top **asks**;
  the daemon's `body` is prepended and `items_dropped` comes down; `body: null` marks
  the rows unreachable and prepends nothing; an answer nobody asked for is ignored.
- **Evidence** `a-row-is-asked-for-by-its-ordinal-and-not-by-an-index`,
  `reaching-the-top-asks-for-the-row-above`, `scrolling-past-the-top-fires-the-ask`,
  `a-fetched-row-goes-at-the-top-and-the-count-follows`,
  `a-row-the-daemon-does-not-hold-is-not-an-empty-row`,
  `the-seam-above-the-window-says-what-is-above-it`.
- **Status RUNS + LIVE (the refusal path).** `94a04f9`. Live: the seam offered →
  the scroll asked → the daemon answered `null` → the seam said so, with nothing
  prepended. **Not demonstrated live: the `Some` path** — the daemon cannot currently
  answer one (`view.items` is both what the snapshot clones and what `row_body_at`
  reads; one view, one bound). The other half is **A's**, its own R19.2(b).

## §2.4 A slash reply longer than the screen must be readable

- **SETUP** a `warning` with code `slash` and a >3-line body.
- **STIMULUS** the frame arrives.
- **ASSERTION** the pane opens with the echo and the body; a ≤3-line reply stays a
  row; the listing is not ALSO pushed as a note; esc and the arrows are the listing's
  and nothing else's.
- **Evidence** `a-long-slash-reply-opens-a-scrollable-pane`,
  `a-slash-listing-keeps-its-text-on-the-screen`,
  `a-slash-listing-owns-esc-and-the-arrows-and-nothing-else`,
  `a-slash-reply-is-not-said-twice`.
- **Status RUNS + LIVE.** `b09fbd8`.

## §2.5 A fork in flight must show progress

- **SETUP** a bulk announcement whose bodies have not arrived.
- **STIMULUS** the `filling` event; then the bodies.
- **ASSERTION** one line, not a screen of placeholders; the count is
  arrived-of-total; the words are the daemon's (`what`/`unit`); the line stops claiming
  progress after patience; an ORDINARY turn draws no carry.
- **Evidence** `a-carry-is-one-line-and-not-a-screen-of-placeholders`,
  `a-filling-tick-is-read-from-the-real-wire-fields`, `a-small-batch-draws-no-bar-but-is-still-diagnosed`, `an-ordinary-turn-is-not-a-carry`.
- **Status RUNS.** `ceebf76`. **Constants measured:** `+carry-min-rows+ 64` (above an
  ordinary turn's tail: rows-per-turn median 12, p90 317 here; 17/130 there),
  `+body-patience-ms+ 5000` (against a measured 31 ms worst body).

## §2.6 Fenced code must colour for the languages the other head colours

- **SETUP** fences named `rust,ignore`, `python title="x"`, `tsx`, `makefile`,
  `console`, `text`.
- **STIMULUS** render.
- **ASSERTION** the FIRST WORD names the grammar, case-insensitively, ignoring
  attributes; a token whose grammar this build lacks renders plain; the header names
  the grammar that RAN.
- **Evidence** `a-fence-resolves-by-its-first-word`,
  `every-token-rano-knows-is-a-token-this-head-knows`,
  `a-token-this-build-cannot-draw-stays-plain`, `console-is-not-a-language-and-stays-plain`.
- **Status RUNS + LIVE.** `a6fa7f5`; rendered on the head: `rust,ignore` → 5 distinct
  roles, `makefile` → 2, `console` → 0.
- **Drift RULED**: **`console` is NOT a language** — plain in both heads. A console
  transcript's bytes are mostly OUTPUT, and colouring them as bash invents structure
  that hides the output the fence is being read for.
- **Drift OPEN**: the token table exists in three places (A's `Lang::from_token`, B's
  `*fence-tokens*`, this doc's list). C14 asks for it to be ONE shared artefact;
  nothing generates it. B's copy has a test that fails if A's table grows.

## §2.7 Nested and ordered lists

- **SETUP** a nested list; a loose ordered list; an ordered list starting at 5.
- **STIMULUS** render.
- **ASSERTION** nesting indents by `(min 8 (* 2 (floor indent 2)))`; an ordered list
  counts up from its own start; four spaces is CODE and a four-space indented `- sub`
  is a list.
- **Evidence** `an-ordered-list-counts-up-from-its-own-start`,
  `indented-code-is-code-and-not-mangled-prose`.
- **Status RUNS.** Present before this document; measured tonight as already correct.
- **Drift** the doc records `1. 1. 1.` in A (each item its own block) against
  `1. 2. 3.` here. **A's gap**, and the ruling is `1. 2. 3.`.

# C. Terminal safety

## §3.1 Content the head did not author must not reconfigure the terminal

- **SETUP** model prose, reasoning, the user's own message, a system row, a fence body
  and a diff excerpt off disk — each carrying `ESC[31m`, `?1002`, `?1006`, `?1049`,
  `?2004`, `?2026`, an OSC title, `[2J`, `[8m`, `0x9B`, `0x9C`, DEL.
- **STIMULUS** the real pipeline, out through `--replay --no-tty` (which writes
  `screen-rows-ansi` — the same bytes `/cells` sends and ScreenRequested answers with).
- **ASSERTION** **no ESC-prefixed sequence reaches stdout**, and the frame is not
  vacuous (it carries the head's OWN escapes, so the count means something).
- **Evidence** `every-source-a-model-can-reach-goes-through-the-same-painter`,
  `the-cell-grid-cannot-store-a-zero-width-cluster`,
  `a-tool-payload-cannot-reconfigure-the-operators-terminal`.
- **Status RUNS + LIVE.** `65b63ef`: `ESC[?1049h alt screen` → `alt screen`, `ESC[?1002h
  mouse on` → `mouse on`, `ESC]0;pwned` → nothing, on a frame carrying 103 of the
  head's own escapes.
- **Drift — and this one changes what each head is asked for.** A **string** painter
  (`paint_full` writes ANSI verbatim) can emit a content escape; B's **cell-grid**
  painter cannot, because a control character measures zero columns and has no cell to
  be written into. So the criterion is *"a control character must not be STORABLE in a
  cell"*, not *"sanitise seven call sites"* — A has a real exposure, B has a proof, and
  the document should say which it is asking each for.

## §3.2 A paint that fails must leave the terminal usable

- **SETUP** a paint driven to fail partway (the real failure is a cell holding
  something that is not a cell; the recorded incident was an out-of-range style index).
- **STIMULUS** paint; then paint again with the trigger cleared.
- **ASSERTION** the synchronized-output pair is CLOSED exactly once; the head's record
  of the terminal is not updated by a paint that did not complete; **the next paint is
  FULL**; an out-of-range style costs one cell's colour and not the frame.
- **Evidence** `synchronized-output-is-closed-when-the-paint-signals`,
  `a-paint-that-failed-forces-the-next-one-to-be-full`,
  `an-out-of-range-style-costs-a-colour-and-not-the-frame`,
  `an-out-of-range-style-costs-a-colour-and-not-the-frame`.
- **Status RUNS + LIVE.** `462942e`. The hunt: a paint injected to die after `ESC[2J`
  left the head believing it had drawn 30 rows the terminal did not have —
  `head believes 30 rows, the terminal shows 0: DIVERGE on 30 row(s)` — and **no
  ordinary paint could repair it**, which is why only a byobu window switch did (a
  resize allocates a fresh cell vector).
- **Drift** the two named rules are new and A must answer both: **a failed paint must
  not leave a record**, and **a test that cannot fail guards nothing**.
- **Not established**: a NATURAL out-of-range style. `rebuild-style-sgrs` keeps the
  tables parallel (4/4 measured), so it takes a push that shortens the vocabulary.

## §3.3 `truncate-target` must agree

- **SETUP** a target of 121 ASCII characters; 61 CJK (122 columns); 61 emoji; one
  carrying `0x9B`.
- **STIMULUS** truncate.
- **ASSERTION** the cap is **120 COLUMNS**, the ellipsis counts, and **C1 is stripped**
  with C0 and DEL.
- **Evidence** `a-display-target-is-cut-to-a-column-budget-not-a-byte-count`.
- **Status RUNS + LIVE.** `a6fa7f5`: measured `121 a → 120 cols`, `61 CJK → 119 cols`,
  `60 CJK (exactly 120) → untouched`.
- **Drift RULED**: **both heads count columns.** A counts BYTES (117 + mark on ASCII,
  but 39 + mark for 61 CJK), B counted CHARACTERS (which let 122 columns through).
  **A should move** — its two-column shortfall on ASCII is the smaller half of the same
  bug.

# D. Protocol

## §4.1 A frame that cannot be parsed must be survivable

- **SETUP** a live head.
- **STIMULUS** one line that is not JSON; then an unknown frame tag; then an unknown
  event tag; then a good frame.
- **ASSERTION** each is **said** (a row in the conversation, with the offending line),
  **counted** (`/status`'s `unreadable` and the border's alarm), and **survived** — the
  following frame is folded normally and the read mark does not move backwards.
- **Evidence** `a-frame-this-head-cannot-read-is-said-counted-and-survived`,
  `an-unknown-frame-tag-is-unreadable-too`,
  `an-undecodable-line-is-the-same-fact-as-an-unknown-tag`,
  `an-event-this-head-knows-and-does-not-fold-is-not-unreadable`.
- **Status RUNS + LIVE.** `f70920d`. Live probe: `warnings before 9 · after 10 ·
  unreadable 1`, and the row's text names the line.
- **Drift** none.

## §4.2 The daemon going away

- **SETUP** a connected head.
- **STIMULUS** the socket closes; then a `Bye`; then a `Bye` NAMING a protocol version.
- **ASSERTION** a close is detach and the head reconnects; a `Bye` is FINAL and the
  head exits with the reason on **stderr** (surviving the alternate screen); a refused
  head does not then claim the session is quiet.
- **Evidence** `a-bye-is-the-end-of-the-conversation`,
  `a-refused-head-does-not-claim-the-session-is-quiet`,
  `a-live-socket-is-a-daemon-even-with-no-record-beside-it`.
- **Status RUNS.** `5800a53`, `9b20fd7`.

## §4.3 Version checking on `Hello`

- **SETUP** a daemon whose `protocol_version` differs, in each direction.
- **STIMULUS** the `Hello`.
- **ASSERTION** the skew is **named with its DIRECTION** (a newer daemon is a reading
  problem; an older one is a writing problem this head cannot survive from its side),
  the sentence reaches the conversation, and the head stays attached.
- **Evidence** `a-protocol-skew-says-its-direction-and-the-head-stays`.
- **Status RUNS + LIVE.** `3025082`. Live: a 23 head against a 22 daemon → the daemon
  refuses at ATTACH with `protocol version 23, this daemon speaks 22`.
- **Drift** both heads must compare at the HANDSHAKE (this head exits; the reference
  stays, which this head copies).

## §4.4 `Screen.cols` must be the terminal's width

- **SETUP** a head at 80 columns whose rows are 109 characters (an escape-rich row).
- **STIMULUS** a `screen_requested`.
- **ASSERTION** `cols` is the terminal's COLUMN count, not the character count of a
  row; `rows_n` matches; the rows are the ones just painted.
- **Evidence** `screen-answer-golden`.
- **Status RUNS + LIVE.** `919a022`; live JSON: `{"frame":"screen","req_id":"q1",…
  "cols":80}` on a row that is 109 characters.

## §4.5 A latent wire hazard: a nil key is never a null

- **SETUP** every `make-*` constructor in `protocol.lisp`.
- **STIMULUS** encode each frame.
- **ASSERTION** no frame carries a `null` anywhere, and each still decodes; the two
  hand-fixed sites (`consented`, `summarise`) say `false` rather than nothing.
- **Evidence** `no-client-frame-this-head-can-build-carries-a-null`,
  `a-boolean-field-goes-out-as-a-boolean`.
- **Status RUNS.** `919a022`.
- **Drift** the criterion is *the invariant*, and the reference has the same hazard
  (`consented: null` broke its read loop identically).

# E. Requirements added after the first measurement

## R1 The unified diff carries one line-number column

- **SETUP** a changed file.
- **STIMULUS** render the diff, unified.
- **ASSERTION** ONE number column, right-aligned; the excerpt is numbered from where it
  sits in the FILE, not from 1.
- **Evidence** `the-unified-gutter-is-one-column`, `diff-excerpt-is-numbered-from-where-it-starts`.
- **Status RUNS.** `a42d9e3`.

## R2 A queued prompt must appear before the answer to it

- **SETUP** a turn running.
- **STIMULUS** type a prompt and enter.
- **ASSERTION** an echo row appears immediately, marked `queued`; it retires when the
  prompt's own row lands, **matched by text**; two queued prompts of different lengths
  retire in the right order.
- **Evidence** `a-queued-prompt-is-visible-before-its-row-lands`,
  `a-landed-row-retires-the-prompt-it-echoes`,
  `a-queued-prompt-takes-the-shape-of-the-row-it-becomes`.
- **Status RUNS.**
- **Drift** A's R2 and B's must keep the TEXT match — the reference's comment records
  that any other match took the wrong prompt off first.
- **Related, and NOT implemented here — R16**: an echo retires across a COMPACTION.
  **ARGUED for B**: R16 says *"measure it rather than assuming, by queueing a prompt
  and forcing a compaction under it"* and **B is not known to pass it.** That is a
  phase-2 test to write, not a claim to make.

## R3 A frame the head cannot parse is said, counted, survived

See §4.1 — same criterion, and this is the shape every other entry uses.

## R4 An ambiguous option prefix is refused, with the candidates named

See §1.1.

## R5 A head checks the protocol version it is told, at the handshake

See §4.3.

## R6 An opencode conversation can be imported

- **SETUP** an opencode session on disk.
- **STIMULUS** `--session oc-<id>`.
- **ASSERTION** the conversation is read into this head's rows, and **the screen is up
  while it happens**.
- **Status ARGUED — A's, and untouched here.** B has no importer.

## R7 A backgrounded job's completion arrives as an event

- **SETUP** a job promoted to the background.
- **STIMULUS** it exits.
- **ASSERTION** `JobSettled` UPDATE THE ROW THE PANE DRAWS — the pane does not freeze
  at `running` until `/jobs` is re-run. Nothing blocks waiting.
- **Evidence** `a-settled-job-updates-the-row-the-pane-draws`.
- **Status RUNS.** `e013465`.
- **Drift** none on the criterion.

## R8 The context size survives a reattach

- **SETUP** a head that attached after a turn (a `--resume`, a reattach, a switched
  session).
- **STIMULUS** draw the header.
- **ASSERTION** `ctx` comes from the SESSION's own row when no turn has run; **a
  backfilled row never claims a cache fraction it did not measure** (never `0% cached`);
  a LIVE turn still wins over the session's row.
- **Evidence** `a-live-turn-still-wins-over-the-sessions-own-row`,
  `a-row-this-head-did-not-watch-shows-no-duration`.
- **Status RUNS + LIVE.** `f91f3ae`; the live table: no row/no turn → nothing;
  row+cache → `633.5k ctx · 93% cached`; row size-only → `633.5k ctx`; live turn →
  `41.2k ctx · 90% cached`.
- **Drift** A reads the same two fields; the criterion is the same.

## R9 A progress line is a counted operation

See §2.5, plus: **the sentence never names a cause it cannot see** — the trigger is a
BULK announcement, not *"any row lacks a body"*, and the number is arrived-of-total,
not `peak - pending`. **Constants measured**, above.

## R10 A note the operator has read can be dismissed

- **SETUP** a daemon `Warning` arriving on a live head.
- **STIMULUS** the frame; then `/notes`; then `/notes dismiss N`; then a resync and a
  reattach; then `/notes restore`.
- **ASSERTION** the warning is **drawn as a row where it arrived**; a long one folds to
  three lines and a `… +N lines · /notes` seam; retiring it takes the row off the screen
  and **leaves it in the record**; a resync and a reattach **replant it retired**;
  `/status` reads `N of M retired`.
- **Evidence** `a-warning-the-daemon-sends-is-drawn-where-it-arrived`,
  `a-long-warning-folds-to-three-lines-and-names-the-verb`,
  `a-retired-warning-leaves-the-screen-and-stays-counted`,
  `a-retired-warning-stays-retired-across-a-resync-and-a-reattach`,
  `a-snapshot-warning-list-keeps-the-conversations-order`,
  `the-turn-failed-warning-is-not-a-second-copy-of-the-footer`,
  `the-notes-verb-lists-retires-and-restores`.
- **Status RUNS + LIVE.** `55ad98b`/`486ed6e`; the measurement that opened the item was
  `warnings 9 → 10, note NIL, on-screen NIL, alarmed-p → only the three counters it
  already had`.
- **Drift** the retirement KEY: reference `w|{code}|{ts}|{fnv1a(detail)}` persisted in
  `head.toml` with a cap; this head `{code}|{ts}|{detail}` in memory. **The criterion
  says the retirement survives a resync and a reattach, not a RESTART** — the reference
  does more, and that is a criterion decision for phase 2.

## R11 What was asked of the oracle, and what it answered, must be readable

- **Criterion, as far as it is settled** — and **it is not settled** — the brief and the
  raw reply are reachable from the decision's own row.
- **Status ARGUED.** I surveyed it and stated a position: the reply's *summary* is
  already on screen (the `advice` is copied onto the settled decision and drawn as
  `oracle (by, latency) would X: basis`); what lacks a home is the BRIEF and the reply's
  raw text, reached by a **locator** keyed `(kind . id)` rather than a second chord.
  **Nothing runs it, and it needs a protocol change (A's `ModelAdvice.consulted`).**

## R12 An oracle that ran out of budget is not an oracle that could not be read

- **Status ARGUED — A's, untouched here.** The criterion needs a third outcome
  (`max_tokens` truncation) distinguished from *could not be read*.

## R13 A running tool call shows a live elapsed time

- **SETUP** a running call, and a frame with something on it that is a function of time.
- **STIMULUS** watch the screen with NO key and NO eval.
- **ASSERTION** the number moves, in tenths; the settled duration is the measured one
  and is NOT rounded; the frame is rebuilt by the clock while something live is on it;
  an idle head still asks for nothing.
- **Evidence** `a-running-call-counts-on-this-heads-clock-not-the-daemons`,
  `a-live-duration-is-coarse-on-purpose`,
  `a-frame-with-a-clock-in-it-is-rebuilt-by-the-clock`.
- **Status RUNS + LIVE.** `201d8ee`. Live, on the glass with no eval in between:
  `Running · 50.8s · 52.7s · 54.8s · 56.8s · 58.7s`; cost measured over 30 s — idle
  **1 tick**, live frame **3 ticks** (0.10 % of a core).
- **Drift — this one is a UNIFICATION the document now carries.** The frozen elapsed,
  a spinner that does not spin, and the reference's `notice_ttl` counted in FRAMES are
  **one defect**: a head that repaints on events rather than on time.

## R14 The read-before-overwrite refusal is abandoned

- **Status ARGUED — A's, untouched here.** B has no such refusal to remove
  (`grep` finds none), so for B the criterion is satisfied by construction; the
  changed-since-read arm is A's to rule on separately.

## R15 An edit card's label is the file, with no elided-array placeholder

- **SETUP** `{"edits":[…],"path":"…/commands.lisp"}`; `{"path":"a.rs","edits":[…]}`; a
  windowed `read`; `{"todos":[…]}`; `{"signal":"term","pids":[…]}`.
- **STIMULUS** derive the label.
- **ASSERTION** a batch edit's row **names the file and nothing before it**; a tool with
  **no scalar argument worth showing still says something** — `[…]` is the placeholder
  KEPT where there is no subject, and DROPPED where there is one.
- **Evidence** `a-batch-edit-names-the-file-and-not-the-edits-array`.
- **Status RUNS.** `0446585`. The tools that keep the placeholder are named in the test:
  `todo_write` (no scalar at all) and a `pkill`/`kill` whose only scalar is a modifier.

## R16 A queued prompt's echo retires when the prompt lands, including across a compaction

- **Criterion** — the echo is retired because the prompt is demonstrably in the ledger,
  or marked as something other than `queued`.
- **Status ARGUED.** R16 is A's finding and the doc's own instruction is *"measure it
  rather than assuming, by queueing a prompt and forcing a compaction under it."*
  **For B that measurement has not been made and the criterion is not claimed.**

## R17 A head can tell when its view has diverged from the ledger — `seq` continuity

- **SETUP** a live head.
- **STIMULUS** a batch that jumps (40 → 52); then a contiguous frame; then a
  redelivery that steps BACKWARDS.
- **ASSERTION** the jump is **filed as a row** (`jumped from 40 to 52 — 11 events never
  arrived`), **counted**, and the following frame is folded normally; a step of one is
  NOT reported; a step backwards is NOT reported (that is the redelivery §13.2b
  promises); a mark of zero is not a gap.
- **Evidence** `a-gap-in-the-event-stream-is-said-counted-and-filed`.
- **Status RUNS.** `65b63ef`.
- **Drift** both heads were missing this; the criterion as written (*"says so and
  repairs it"*) asks for a RESYNC on detection, which this head does not do
  automatically — it files the row and tells the operator `/resync`. **That difference
  is worth ruling before phase 2.**

# F. The head's own state, and the two defects found while hunting

## A request is not an outcome — the quit-card stop

- **SETUP** a head attached to a real daemon.
- **STIMULUS** choose *leave and stop the daemon*; then do NOT close the socket early;
  then a daemon that refuses to die.
- **ASSERTION** the head does not exit on the ASK (it waits for the daemon's ABSENCE);
  while waiting it says so in a row that does not expire; the deadline ends the wait and
  the farewell names the pid and `letibot --stop`; a `Bye` during the wait is the answer
  and not the end.
- **Evidence** `leaving-and-stopping-the-daemon-asks-and-waits-for-the-outcome`,
  `the-wait-for-a-stopped-daemon-is-said-on-the-screen`,
  `a-stop-is-over-when-the-daemon-is-gone`,
  `a-daemon-that-will-not-go-is-named-on-the-way-out`,
  `a-bye-during-a-stop-answers-it-without-ending-it`,
  `a-head-waiting-for-a-stop-does-not-reconnect`.
- **Status RUNS + LIVE.** `df5b66a`. The measurement is the item: the head's own exit
  sequence loses a RACE — `close 0 ms after stop → STUCK`, `1 ms → gone in 221 ms` —
  because the daemon's `Accepted` write takes `EPIPE` and `registry.close()` sits behind
  it. **One millisecond.** That is a daemon-side fragility worth handing over.

## The notice's clock belongs to the head, and counts TIME

- **SETUP** a head whose loop is painting.
- **STIMULUS** `say`; wait; read `head-status-note` and the deadline.
- **ASSERTION** the note expires in ~1.6 s of WALL TIME; a note with no deadline is not
  cleared immediately; the deadline is a slot of the head, so no `let` of a global can
  separate them.
- **Evidence** `a-notice-expires-and-an-alarm-does-not`,
  `a-note-and-its-clock-cannot-come-apart`.
- **Status RUNS + LIVE.** `57d20dc`. Live: `:note "permission answered" :ttl 0 :dirty
  NIL` and identical 2 s later — **a note with NO clock**, left immortal by 17 direct
  writers and a tick guarded on `(plusp ttl)`.
- **Drift** the reference's `notice_ttl` is still counted in FRAMES and decremented in
  its chrome builder, so on a quiet screen it can outlive its fact. **The criterion is
  a duration, and A's shape does not meet it.**

## A gone client is not a head failure — the eval socket

- **SETUP** a live head, its eval socket open.
- **STIMULUS** send `eval (progn (sleep 1) :answered)` and close WITHOUT reading.
- **ASSERTION** the head survives; the accept loop retries a failed accept and counts
  it; `/status` says whether the head is still accepting.
- **Evidence** `a-client-that-vanishes-mid-reply-does-not-take-the-head-down`,
  `a-failed-accept-is-retried-and-counted-rather-than-ending-the-loop`,
  `the-status-screen-says-whether-the-head-can-still-be-evaluated`.
- **Status RUNS + LIVE.** `bbbca21`. Live: `round 1: head alive after the client
  vanished mid-reply: False · VERDICT: THE HEAD IS DEAD`, from `HACK-SERVE` →
  `%WRITE-LINE` → broken pipe.
- **Not established**: the TRIGGER for the accept-loop half. Eight connect-and-vanish
  clients raised no accept error. **And measured while looking**: `socket-accept` on a
  listener closed UNDERNEATH it neither errors nor returns — it blocks for ever.

---

# Where the two heads have drifted on what a criterion MEANS

These are the phase-2 bugs waiting to happen: both heads agree on the sentence and
differ on what passing it looks like.

| criterion | the drift | who is right |
|---|---|---|
| §1.1 ambiguous prefix | reference takes the first match; this head refuses | **unruled** — it changes whether typing `allow` answers or declines |
| §1.5 an absent reason | reference draws nothing; this head says `no oracle was consulted` | this head, under `/supervise` (an absence IS evidence) |
| §1.6 the gate card | reference draws neither deadline nor consequence; this head is the spec | this head (`550bc94`) |
| §3.1 what is asked | A must sanitise (its painter can emit); B must prove (its painter cannot) | the criterion differs per head — saying so is the fix |
| §3.3 the cap | reference counts BYTES; this head counts COLUMNS | this head; **A should move** |
| R10 retired-set key | reference persists a hash to `head.toml`; this head holds it in memory | unruled — the criterion says *survives a resync and a reattach*, not *a restart* |
| R13 and the notice | reference's `notice_ttl` counts FRAMES; this head counts time | this head — **one defect, two symptoms** |
| R17 on detection | the criterion says *"says so and repairs it"*; this head files a row and names `/resync` | unruled — automatic resync vs. telling the operator |
| §2.6 the token table | three copies; C14 wants one shared artefact | neither yet — nothing generates it |
| R7's blocking | reference blocks nothing; `Peek`/`FetchRow` share *"a read, not a move"* | both, but B is the one that had to rebuild it |

# What is ARGUED and not run — the honest list

Everything above marked **ARGUED**, in one place, because this is the list that matters
for phase 2:

1. **R11** — the brief and the raw reply (a protocol change; a locator keyed
   `(kind . id)` proposed, nothing built).
2. **R12** — an oracle out of budget (A's).
3. **R14** — the read-before-overwrite refusal (A's; B has nothing to remove).
4. **R16** — the queued echo across a compaction (**B is not known to pass it**; the
   test is one compaction away and has not been written).
5. **R6** — the opencode import (A's).
6. **T1(1)'s `Some` path** — the daemon cannot currently answer a `FetchRow`; the head
   half is built and the daemon half is A's R19.2(b).
7. **§3.2's natural trigger** — the out-of-range style is defended against and was
   never reproduced naturally.
8. **R17's repair** — detection is run and counted; automatic resync is not.

---

## Where this document should live

It is written in `leticl/docs/parity/` because that is where the four surface
measurements live and where "the assertion that would prove it closed" already has a
home. **The right long-term home is the requirements document itself**, as the section
phase 2 is driven from — it is the spec and this is its suite, and a suite that lives in
one head's tree is a suite the other head reads second-hand. I have not moved it there:
two agents are in flight in that file tonight, and a merge into it is the operator's
call rather than mine.
