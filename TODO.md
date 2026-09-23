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
| **R19, history as news** | a fresh attach planted the snapshot's warnings as ROWS, so a restart opened with twelve red lines the operator had never been shown — *"i dont want to see that on restart."* Three faults: an attach now plants nothing (they stay in the record, listed by `/notes` and counted by `/status`), a routine code draws faint with `·` instead of the failure role (letibot's own severity table, guarded by a test that reads it), and a dismissal survives a restart. **The first version of the restart test wrote into the operator's real config**, which is why the prefs path and the notes path are both now the test's own | `771f5ab` |
| **R20, the option ladder** | a permission card's options were the TAIL of one list that the fit loop shrank from the end, so a long diff ate the hint and then the options bottom-up — measured at every size from 8 rows to 30 with a 40-line diff: **not one option, not the hint, not the deadline on the screen.** The card now returns CONTENT and LADDER separately, `%render` pins the ladder and never trims it, and the content above it shrinks and scrolls (PgUp/PgDn/Home/End/the wheel) | `4e61ff4` |
| **R24, a compaction is a tool call** | the most information-dense event in a long session arrived as the one shape with no affordances. It is now a `tool_result` row whose headline carries the stats (`941,290 → 9,449 tokens`) and whose payload is letibot's own sentence, so `ctrl-t` folds and pages it — and `context_wall` stays a NOTE, ruled on its own: it is terminal in the cases where nothing follows | `972a88c` |
| **the notes file is ONE FILE FOR EVERY HEAD** | letibot's `e7b6caf` measured that a dismissal is one file for every head, so a wholesale save from either erases the other's. This head now writes letibot's own key (`w|{code}|{ts}|{fnv1a16}`), unions on save, re-reads on listing, replaces on restore, writes through a rename, and **never writes a file it could not read**. Its own `head.toml` keeps the four choices and nothing else. **The suite had been writing the operator's real file**; repaired, and the artefact it had left there was removed | `2581b25` |
| **R22, `ctrl-n`** | one chord retires every note this head holds, and the empty press says `nothing to retire` — letibot's one amendment, on the rule that a hint bar cannot be conditional so a chord named unconditionally must answer. It runs the VERB rather than reimplementing it, and it is placed second in the hint bar because both heads' bars are the same 136 characters and anything past 80 is off the screen | `bbf6c33` |
| **eleven docstrings stopped mid-sentence** | an unescaped quote inside a docstring ENDS it, so the rest of the paragraph is read as code and the compiler reports the wreckage as one undefined variable per word — in a defun that still compiles and still runs. Repaired across seven files, and now **checked**: a test reads every source file the way the compiler does and fails on a body form that is not a form. Falsified by putting one quote back | `5b1c4cc` |
| **R25, the head's half** | the subject of a tool headline was cut to a **constant 120 COLUMNS** at the moment the head derived it, so a 227-column pane drew a 156-column headline and ~70 columns of viewport belonged to nobody. The constant is a **KEEP bound** now (2048 columns) and the elision is the **viewport's**, at draw time — which is also why a resize re-elides by construction. Measured: 156 → 224 columns at 227, unchanged at 80 and 140 where the pane was already binding; a 400-column CJK subject keeps 99 characters / 198 columns. `ctrl-x`'s raw block had the same defect one control away. **letibot's half (`4f313e4`) turned out to be 90% of the story and its conclusion about this head was wrong** | `R25` |
| **R6's head half** | **the daemon's progress line was never drawn.** `filling-progress-line` had exactly ONE call site, in the branch `carry-line` reaches only when a filling is NOT active — so *"when the daemon reports the operation, this yields to it"* was a yield with nothing on the other side, and the case the function exists for was the one it did not draw. Found by running R6 end to end (a real 9,570-part opencode import) rather than reading it: the screen was up with rows landing and **no bar, no count and no name** for eight seconds. Fixed; the line is on the glass | `edb58c4` |
| **R24 part two, decision 1 — a row says WHO asked** | letibot `dd81999` put `origin: Option<CallOrigin>` on `TranscriptItem::ToolResult`; this head read `:origin` only on a SYSTEM row, so an operator-run call drew as the model's. The headline now names the actor (`▸ Fetched <url> · by human:dead · ok`), VERBATIM from `who`, in the tail so R25's arithmetic protects it. **The negative case is asserted as a literal — a row with no origin draws the same segments in the same order as before the field existed** — and an origin this build cannot read still names somebody rather than falling back to looking like the model's. Measured through `--replay` at 60/80/120 cols. 4917 → 4921 checks | `d28bf22`
| **R16, the merged row** | **the queue could not see the shape it was waiting for.** Measured live on the operator's head 2026-09-23: **28 `queued ·` echoes two hours after their rows landed**, while letibot's pane on the same daemon held zero. The daemon merges consecutive queued prompts into ONE item joined by newlines, so the row is not equal to any echo and **the equality rule retired 0 of 28** (R16's front-piece branch: also 0). `%piece-of` — a text has landed when the row IS it or holds it as a run **bounded by newlines** — retires **28 of 28**; bounded and not merely contained, or `second thing` retires on `second thing-guess`. Two leaks came out with it: the unconfirmed set was emptied by removing the ROW's text (never a queued text), so an unconfirmed echo whose row landed in a merged item was retired from the queue and **left in the set for ever**; and the live arm read only the first text part while the snapshot path reads every part. Falsified three ways. Live: 28 → 0. 5145 → 5156 | `09a8967` |
| **R24 part two's three rulings** | **RUNS + LIVE** | proved against a REAL protocol-25 daemon (today's `release/harnessd`) on its own workspace, socket, store and head. **The operator's own daemon speaks 23** (measured: it refuses 24 and 25, `bye: … this daemon speaks 23`), which is why the proof is on a scratch 25 daemon. (1) *run only on the log event* — the order was measured on the wire (`accepted` seq 6, then `operator_call_allowed` seq 7); the chord's call ran the tool only after the event; and the daemon's OWN `accepted` line delivered to a live head left **the runner unfired and the call still pending**. (2) *the door comes from the SettingRow* — the live daemon publishes `head-run.tools = web_search,web_fetch` and the card drew exactly those. (3) *a refused name is a sentence* — `bash` refused through the door with the daemon's own words (*"`bash` is not a call this door runs for the operator… Nothing ran."*) **and a runner bound for `bash` never fired**, which is what shows the allowlist is enforced there and not here. The row: `▸ Fetched (headrun-1) · by leticl · ok · 1 line`, `:origin (:operator (:who "leticl"))`. **The proof found a real defect and killed its own head**: `outcome` was a bare word where `ToolOutcome` is an internally-tagged enum — fixed `5b3a6fc`, with the vocabulary measured off the daemon's refusal (`ok, abstained, failed, denied, timeout, not_run, backgrounded`; `failed` requires a `reason`) | `bc85ffc` + `5b3a6fc` |
| **R11's locator** | **RUNS + LIVE for one of three states** | the wire is real: `fetch_diagnostic` answers on a 25 daemon, keyed by the adjudication's own id, both kinds, and the head's `/diagnostic` drew it on the glass for the REAL adjudication `op-headrun-1` my own operator call wrote — *"brief — what the gate was shown · 0 bytes / nobody kept this…"*, the same for the reply. **The RECORDED branch is not provable on this box tonight, and the measurement says why**: the corpus holding recorded exchanges (386 `shown`, 239 `oracle_reply`) is behind the operator's daemon, which speaks **23**; the 25-speaking daemons are scratch, and one started `--role runner --bash --oracle 127.0.0.1:8080 --supervise` (oracle up, 200) recorded a real gated call with **`consulted: 1` but `shown`, `oracle_reply`, `oracle_model` all NULL** — nothing kept to fetch. Needs: a 25-speaking daemon where a consulted oracle actually WRITES the pair (or the operator's daemon restarted on tonight's build, which already holds 239). *Recorded and empty* is 0 rows in that corpus and was unreachable too | `0c5aca6` |
| **the queue's own clipping** | **FILED, not built.** The screen showed 20 echoes and the head held 28: `queued-lines` draws every entry and the VIEWPORT clips the top of them, so a reader counts 20 and has no way to learn there are 8 more — the under-report *hid eight of the defect* from the person reporting it. A window that does not say it is a window is read as the whole conversation; the same rule wants a count here, and it wants it on a row that is visible, which is a render-layer change and not a one-line one | — |
| **R12, the head's half** | the card said *the guard said something* and nothing more: `consulted: true`, `would: "ask"`, `cites: []` is what **FIVE** distinct facts arrived as — three non-answers plus a real `NotAuthorised` — so three `decision_requested` frames drew three byte-identical cards. The daemon now sends `unsure` (letibot `bc852c7`, protocol 25) and the head AUTHORS the classification from the token, with the daemon's `basis` following as the detail beneath it; an unrecognised token prints RAW, so a fifth kind is visible rather than folded into one of the four. The half `unsure` does not cover is `consulted` (a fourth state: *nobody spoke*), and an ABSENT `:consulted` is not `false`. `%advice-line` is now the ONE renderer for the card and the settled row, which had already drifted. Falsified four ways. 4921 → 4944 checks | `e56fdd7` |
| **R24 part two, the head's half** | a CHORD (`alt+r`) and a composer, because every control byte with a mnemonic is taken and a tool's JSON wants the composer's wrapping, history, paste and undo; the daemon's `head-run.tools` row is READ rather than held (the suite asks a row naming different tools), and no door at all says so rather than guessing a list. **Asking is not permission**: `Accepted` is *queued*, the run happens only on `operator_call_allowed`, and it matches its `call_id` — so another head's permission, published to the same session, runs nothing. A refusal is not retried, a silence is said in one of two sentences (never answered / queued and not admitted) and said once, and the result goes out BEFORE the sentence. The runner is an EMPTY hook and the head refuses before asking, because an ask is an ADMISSION and an admission is a corpus row saying the operator decided to run something this head then could not. 4944 → 5083 checks | `bc85ffc` |
| **R11, the head's half** | `/diagnostic [ID]` — the oracle's brief and its reply, as the gate saw and heard them, by the adjudication's own id (the same id `/gate` takes). The read is two fields with **both absences on the wire** (no `expected_seq`, no `client_request_id`: the answer is keyed by the adjudication). `body: None` — *nobody kept this* — and `body: Some("")` — *recorded, and empty* — are two screens, and *not answered yet* is a third; `total` is drawn rather than derived. An answer for a different id is not taken and is SAID; with no read open it is `:filtered`, which is not a frame this head cannot read. It reuses the `/slash` listing pane. Falsified five ways. 5083 → 5145 checks | `0c5aca6` |

## The ARGUED list — six of nine closed 2026-09-23

It began as a list of *questions* and is now a list of *work*. Each entry below has a ruling
and a measurement under it, which is what the operator asked for — **including "satisfied by
construction, here is the grep" where that is the truth.**

| item | ruled | the measurement |
|---|---|---|
| **R12** — an oracle out of budget | **CLOSED — the wire arrived and the head's half is landed** | three cards on one screen with letibot's own three `basis` sentences, through `tui-eval`: **every field the head controls was identical** (`would: "ask"`, `consulted: true`, `cites: []`), so the card echoed the daemon's prose and authored nothing — and `would: "ask"` is also what a REAL `NotAuthorised` answer sets, so **five distinct facts reached the glass as one line**. letibot `bc852c7` shipped `unsure: Option<String>` at protocol 25; the head classifies from the token and lands the half `unsure` does not cover | `e56fdd7` |
| **R14** — the read-before-overwrite refusal | **RUNS, satisfied by construction** | the greps ARE the measurement: no copy of either arm in `src/`, `tests/` or any `.md`; the head writes only its own two preference files and a peek spill, never a workspace path. letibot's half is done the way the entry asked — unread arm removed, changed-since-read arm ruled separately and KEPT, schema text updated to promise what is enforced |
| **R6** — an opencode import | **RUNS + LIVE, and the run found a bug of mine** | a real 9,570-part import on a scratch daemon: the screen up at t=0 and rows landing as they were read (409 → 2,141 items) — and **no progress line**, because its renderer had no reachable caller. Fixed (`edb58c4`); after: `▐█▊░…▌ 448 of 9570 parts (=^o^=)` / `importing an opencode conversation` |
| **T1(1)'s `Some` path** | **RUNS + LIVE, both paths** | letibot's `a17be5c` added the store tier and said the end-to-end proof *"is on the next restart"*; this was that restart. A static trimmed window (exactly 2,000 items, `items-dropped 4646`) and three fetches at **+1 item / −1 dropped each**, the row prepended as `leticl-row-<ordinal>`, with real store text as its body |
| **§3.2's natural trigger** | **NOT OWED** | its mechanism is structurally impossible now (`*styles*`/`*style-sgrs*` are `defvar`, pinned by `live-state-tables-are-defvar`, which names `("cells" "*style-sgrs*")` as *the one that bit*), a desync is both repairable (`rebuild-style-sgrs`) and bounded (`%sgr` falls back to index 0), and the criterion is about a failed paint's CONSEQUENCE, which is tested. **A trigger made unreachable does not owe a reproduction** |
| **R17's repair** | **CLOSED — the criterion no longer asks** | ruled §11.4: SAID and COUNTED, *"repairs"* dropped. Detection RUNS: `a-gap-in-the-event-stream-is-said-counted-and-filed` files the row and `/status` counts it; who presses the key is the head's choice, with the reason in the criterion |
| **R11** — the brief and the raw reply | **CLOSED — the locator landed on both sides** | `shown` now holds the brief (the survey found *147 cards, zero briefs*) and `oracle_reply` holds the reply verbatim, but the wire carried neither. What was asked for was *a locator keyed `(kind . id)`, not a payload*; letibot `bc852c7` shipped `FetchDiagnostic`/`Diagnostic` at protocol 25 and the head reads both halves on demand, drawing *not recorded* and *recorded and empty* as the two different facts they are | `0c5aca6` |
| **§11.6's `never_ran`** | **still A's, not patchable here** | derived from the exit code alone (`host.rs:900`), so a command that ran `exit 125` is listed as one that never did. Measured end to end on the operator's own scratch daemon; only the daemon holds the evidence |
| **§11.7** — R18's card | **CLOSED — landed `aea5dcd`** | letibot `11f07e7`; the sentence is asserted VERBATIM and the two guards falsified (widening to any access → 2; guessing `exec` when the field is absent → the `:ABSENT` assertion plus R20's fit cascade). `access` is MEASURED on the wire (`tool_started` carries `access: "read"` at 25) | `aea5dcd` |
| **R24 part two's three rulings** | **RUNS, NOT LIVE** | each one is falsified and named below; what is missing is the real daemon, and that is one landing: a scratch `harnessd` on its own socket, `/run` against it, and a forced `operator_call_allowed`. The three: (1) *run only on `OperatorCallAllowed`, match its `call_id`* — running on `Accepted` fails `an-accepted-call-is-queued-and-not-permission` (3 assertions) and a look-up that ignores the id fails `only-the-admission-runs-it-and-it-matches-the-call-id` (7); (2) *the door's names come from the `SettingRow`* — a list held in the head fails `the-door-is-the-daemons-list-and-not-a-copy-in-this-head` (6); (3) *neither answer arrives → run nothing, say so, do not re-send under a new id* — a re-ask fails `a-refused-call-is-not-retried` (2) and one sentence for both silences fails `a-queued-call-that-is-never-admitted-says-the-other-sentence` (3) | `bc85ffc` |
| **R12's card** | **RUNS, NOT LIVE** | the DEFECT was measured on three real frames through `tui-eval`; the FIX has not been seen live, because it needs a daemon that actually emits an `unsure` token — a guard that cannot decide, comes back unreadable, or runs out of room. Falsified four ways here | `e56fdd7` |
| **R11's locator** | **RUNS, NOT LIVE** | the corpus half was measured live (`147 cards, zero briefs`); the read itself has not been exercised against a real adjudication id. Falsified five ways here | `0c5aca6` |

**Two asks go to letibot in the same batch as R24's four**: R12's `unsure` token on the wire,
and R11's locator. Both are one field or one frame, and both are already measured from this
side.

## For letibot's batch — a documentation defect and the R27 wire ask

### 1. The R24 wire was published in a shape a careful reader could implement wrongly

`## R24 part two — THE WIRE` gives frame 2 as a Rust struct with the outcome described in
prose:

```rust
ClientFrame::OperatorResult {
    call_id: String,
    outcome: letibot_transcript::ToolOutcome,   // Ok / Failed / Timeout / … — already on the wire
    payload: String,
}
```

**A Rust type name and a prose list of variants is not a wire shape.** `ToolOutcome` in Rust
is a typed enum; in JSON it is an INTERNALLY TAGGED OBJECT (`{"outcome":"ok"}`), and nothing
in the comment says so. I built the bare word, and the daemon's read loop — not one frame,
the LOOP — answered `bye`, which is the end of the session for a head that treats `bye` as
final. The comment is also wrong on its own terms: it names `Timeout` where the variant is
`timeout`, and `timed_out` is not a variant at all.

**What the document should say**, for every frame it publishes — and this is the general form,
not this one frame:

1. **the JSON, not the Rust** — `outcome: {"outcome": "ok"}`, with the tag spelled out;
2. **the variants listed exactly, in snake_case, on their own line** — `ok`, `abstained`,
   `failed`, `denied`, `timeout`, `not_run`, `backgrounded` (measured off the daemon's own
   refusal, which is the only authority);
3. **which variants require which extra fields** — `failed` REQUIRES `reason` (refused by
   name without it: *missing field `reason`*), and no other variant takes one;
4. **what happens when a head gets the shape wrong** — it fails the READ LOOP, the daemon
   answers `bye`, and a head that treats `bye` as final ENDS. A frame-shape error is not a
   retry; it is the end of the session, and a reader who knew that would check the shape;
5. **a pointer to the existing precedent** — a `ToolResult` row already carries this same
   object, so "the `ToolOutcome` a `ToolResult` carries" is a shape a reader can go and look
   at instead of inferring.

This is filed as a documentation defect and not a code one: nothing in the daemon is wrong.
But the document exists so a head can build without reading the tree, and this wire was
ambiguous enough that I wrote the wrong shape and was right to think I could.

### 2. R27 — the compaction artefact, drawn from STRUCTURE

The ask, in one paragraph: **put the compaction artefact's structure beside its prose, on the
warning frame that already carries the sentence**, as an optional, defaulted object
`warning.compaction` — so a head draws the sections as sections and the tail as a tail and
stops parsing `compaction-facts` out of a format string. The named fields are `kind` (the
daemon's own word, as it is today); `tokens_before` / `tokens_after` / `transcript` /
`resident` / `window` / `headroom` / `carried` as numbers and ids rather than digits inside a
sentence; `cut_off` as a bool, because a templated summary is exactly where "this was
truncated" stops being readable out of any one section's prose; `template` as a tag like the
`brief_sha` the corpus already keeps, so a change of template is visible; **`sections` as an
ordered list of `{name, body}` in the DAEMON's own order and names** — not five names this
head holds, for the same reason `head-run.tools` and `SettingRow.choices` are the daemon's —
where **an empty body is a section that is present and says nothing (`(none)`) and a name
ABSENT from the list is a section nobody stated (`(not stated)`)**, which are the two
different facts the operator's ruling turns on; **`tail` as `{turns: [{role, text}], carried:
bool, because: "local_model"|"nothing_fits"|"no_turns"}`**, carried BESIDE the summary and
never folded into it, with an unknown `because` printed RAW, and with an EMPTY tail still
present as an object so the local artefact is the remote one with an empty tail rather than a
different shape; and `detail` kept, the daemon's own sentence, unchanged, as the record every
unreadable path in this head falls back to. Whether it travels inline on the `Warning` (my
preference: one event or two can drift about WHICH compaction they describe, which is this
document's oldest defect) or as an R11-style locator is letibot's call — **but if it is a
locator, it must be reachable from the SNAPSHOT too**, or a head that attaches after a
compaction draws a row it can never fill.

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

## §11 of the requirements doc — the six that were MINE, all closed

**Filed 2026-09-22 on the operator's instruction and worked the same night.**
`~/Projects/head-parity-2026-09-21.md` §11 tracks eight items with an owner and a default
each; **the default is this head's recommendation** unless the operator says otherwise. Six
came to this head (five at once, and §11.6 — which is A's words and B's rendering) and all
six are closed. The rulings are kept here with their reasons, because the reason is the part
that would be lost.

**AND THE CRITERIA THEMSELVES HAVE MOVED (§11.8): they are §12 of
`~/Projects/head-parity-2026-09-21.md` now**, not `docs/parity/acceptance.md` — that path is
a pointer stub. Anything below that says *"the criterion says …"* means §12.

**One finding came out of this work that is NOT closed, and it is letibot's**: see the end of
§11.6 below — `never_ran` is derived from the exit code alone, and 125 is a legitimate
command exit code, so a command that ran is listed as one that never did.

## R19 — a fresh attach does not open with old news — DONE

**Ruled by the operator on restarting a head and being met by twelve red lines.** Three
faults, all three closed here, all three with a live measurement on the operator's own
session (`s-1789639478142928813`, which carries exactly the warnings they saw):

- **history arrives as news** — an ATTACH plants nothing: the snapshot's warnings are in
  the record (`/notes` lists them, `/status` counts them) and **not rows**. `0` warning
  rows on a fresh head where the old code drew `6`, and `/resync` still replants them
  (all retired) exactly as R10 requires. `*snapshotted-sessions*` decides, and the frame
  that carried the snapshot decides it — a `Hello` is an attach, a `Resync` is not.
- **routine is painted as failure** — `+routine-warnings+`, twelve codes, drawn faint with
  `·`; everything else stays red with `!`, **including `daemon_stopping`**. Reported to the
  operator as asked, with the twelve named and the unclassified default stated.
- **a dismissal survives a restart** — and it lives in the file EVERY head shares,
  `~/.config/letibot/head.toml`, under **letibot's own key**
  `w|{code}|{ts}|{fnv1a16(detail)}` and its own discipline: a save UNIONS with what is
  already there, a listing and an act RE-READ it, a save goes through a temp file and one
  rename, and a file that cannot be READ is never written. A restore REPLACES, which is the
  half letibot's merge is missing. cap 512, oldest dropped. **This head's own `head.toml`
  keeps the four choices and nothing else** — a set with two homes is a set that disagrees
  with itself, and the home that would go stale is the one no other head reads. Live:
  dismiss all, restart, `/status` reads `7 of 7 retired`, no rows.

  Two things about that are worth keeping in front of a reader. **The suite had been
  writing the operator's real file**, and it is fixed by a path of the run's own in
  `run-all` and a path of its OWN per test in the `notes-of-its-own` fixture — because one
  file for the whole run is still shared between tests and `/notes` re-reads it, which is
  how two assertions came to fail on an earlier test's leftovers. And **the old identity
  was `code|ts|escaped-detail`**: one file two heads compare by string equality means two
  formats is a file both write and neither can read, so the escaping went and a hash took
  its place.

**This supersedes §11.2's "restart is a different requirement and nobody has asked for
it"** — correct when written, overtaken by the operator asking by hitting it. §11.2's row
and R10's criterion are both updated in the document.

**And it cost the operator a line in their own `head.toml`**, which is worth recording:
my first version of the restart test bound `*write-prefs*` T while the save path still
resolved to the default, so a dismissal from a temp directory was written into
`~/.config/leticl/head.toml`. Repaired by hand, fixed structurally (the test sets
`*prefs*` with its own path before it writes), and verified by md5 across a full suite run.
Found on the way: `save-prefs` ignored the path the preferences were loaded from.

- [x] **§11.1 · §3.3 — the criterion is PER LAYER, and neither head moved.** `f6e2658`. A
  daemon's cap is a **byte** cap and is allowed to be one (`TARGET_MAX_BYTES`, 120 bytes,
  `sessionlog/src/event.rs:288`); a head's cap must be a **column** cap (120 columns,
  `*target-max-cols*`); the two are NOT required to be equal. A daemon has no terminal to
  count columns with, and the target is cut before any head exists — that is why it may not
  be asked to move. Both alternatives ruled out by name in the criterion.
- [x] **§11.2 · R10 — the criterion stands at *survives a resync and a reattach*.**
  `f6e2658`. The reference persists to `head.toml` (key `hash(code|ts|detail)`, cap 512) and
  that is a **superset it may keep**; restart-survival becomes its **own row** if ever wanted,
  never a widening of this one — because **this is the only item that writes to the
  operator's config directory**, and the entry says so.
- [x] **§11.4 · R17 — *repairs* is dropped; both behaviours stand.** `f6e2658`. A queues the
  resync itself; this head files the row and names `/resync`. The criterion now says **who
  presses the key is the head's choice, with the reason** (a resync REPLACES the transcript,
  so an automatic one moves the ground under a reader who did not ask, and it admits a
  loop) so the next reader does not re-open it as a defect.
- [x] **§11.5 · §2.6/C14 — the GUARD reads `rano`.** `e037273`. This was the one with code.
  The test `every-token-rano-knows-is-a-token-this-head-knows` carried a **third**
  hand-written copy of the token list, so it could not fire for a token nobody wrote down —
  §2.6's own shape one layer up. It now EXTRACTS the tokens from
  `~/Projects/rano/rano/src/syntax.rs`, asserts a plausible count so an extractor that stops
  matching fails loudly instead of looping over nothing, and **was falsified by adding
  `falsify-me` to rano and watching it fail** (rano restored byte-identical afterwards).
- [x] **§11.6 · `NotScoped` — RULED AND LANDED.** The string is letibot's, from
  `e1cd2b0` (2026-09-22 07:38): **`it never ran, so there is nothing it could have
  written.`**, rendered verbatim — one wording for both heads, asserted literally in this
  head's suite because a different wording here is a new drift rather than a fix. Two more
  places said the same thing on both heads and both are fixed here: the jobs **row** read
  `not run (could not join its scope) · 0 B out · ran 0.0s`, and a job that never ran has no
  duration, so the clause goes (the byte count stays — it is a real measurement); and the
  **refusal** path, which is the daemon's sentence rendered verbatim and so agrees by
  construction — measured on the glass rather than assumed. The fact rides the wire
  (`never_ran`, defaulted, no version bump, on `JobOutput` and on `JobEntry`), so a daemon
  older than it draws exactly what it drew before.
  **And it turned up something that is NOT closed, on letibot's side:** `never_ran` is
  derived from the exit code alone (`host.rs:900`), and 125 is a legitimate command exit
  code — measured on a scratch daemon, `bash -c "exit 125"` is listed and rendered as a job
  that never ran, with the wrapper's own stderr marker (63 bytes, captured) as the evidence
  the classification ignores. Raised for a ruling in §11; the head renders what it is told.
- [x] **§11.8 · `acceptance.md` moved into the requirements document.** §12 of
  `~/Projects/head-parity-2026-09-21.md`; the old path is a pointer stub, because a dozen
  citations point at it and a citation that resolves to *"it moved"* costs one line while a
  404 costs the trail. **Written the careful way**: the destination's `md5` taken before and
  re-checked at the moment of the write, nothing written if it had moved — the file has
  another writer tonight and this night already lost one edit that way.

**Not mine, tracked so the list is whole:** §11.3 R13 (A moves the notice TTL to wall time),
§11.7 R18's card (A's wording).

## R22 — `ctrl-n` retires every note — DONE

**Ruled by the operator, answered by letibot on both sides, landed here in `bbf6c33`.** One
chord, `ctrl-n`, retires ALL of the notes this head holds — and **the empty press says
`nothing to retire`**, which is the one amendment and where the first draft's silence was
given up. The argument is this head's own rule: a chord may only be named where it acts,
and `ctrl-t` earns that by having its seam name it only on the one row it can open — **a
hint bar cannot be conditional**, so a chord named unconditionally has to answer
unconditionally, or a press that produced silence is a press the operator repeats to find
out whether it was received.

**The chord runs the verb.** It is `%command head "notes dismiss all"` and not a second
implementation, so the sentence the operator reads and the file that gets written are the
verb's, whichever door they came through.

**And the hint bar's placement is a measurement both heads got the same**: the bar is 136
characters on each side, so at 80 columns everything past 80 is off the screen — appended,
`ctrl-n notes` starts at 137 and is invisible; second, right after `ctrl-s sessions`, it
starts at 18. `/help` teaches it too, which takes the help from 38 rows to 39 on both
sides rather than on one.

Its reach is the identity's rather than a hope — a note's key carries the log's `ts`, so a
warning that happens again arrives with a new one and is a note nobody has retired, which
means `ctrl-n` cannot mute a KIND of thing — and the byte is free on both sides (`0x0e`
reaches no arm in either decoder, and `Key::CtrlN` does not exist).

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
