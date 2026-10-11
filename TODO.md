# leticl — TODO, for the switch

- [x] **the git format's row on `/config`** — DONE, and measured rather than assumed (2026-10-11).
  `"git_format"` is in `*head-setting-rows*` AND `"git format"` in the parallel labels list,
  `%head-setting-value` reports the template in force, `%flip-head-setting` has the three stops,
  both bridges carry it, and `%git-format` reads the live plist. The test that holds it is
  `the-config-pane-lists-the-git-format-and-cycles-it`; the LIVE head draws the row with its
  value —

      ("diff view" "split") … ("marker seam" "hidden")
      ("git format" "default (%b%d%a%s%m%~%+%!%?)")

  — so the finding below is history rather than instructions.~~
  The operator: *"i dont see the config in /config"*. It was invisible for a reason worth keeping:
  **`*head-setting-rows*` is a list of KEYS and the labels beside it are a PARALLEL list** in the
  `loop` that builds the pane (`panes.lisp`, `config-rows`) — so a key added without a label does
  not draw a row at all; the loop simply runs out of labels and drops what is left. Adding the key
  is not enough, and nothing says so.

  **What is needed** (all written once, reverted to keep HEAD green):
  · `"git_format"` in `*head-setting-rows*` AND `"git format"` in the labels list;
  · `%head-setting-value`: the template IN FORCE (`(or (getf (head-prefs head) :git-format)
    (format nil "default (~a)" +git-format-default+))`);
  · `%flip-head-setting`: three stops — nil → `"%b %!%+"` → `"%b"` → nil;
  · the bridges: `prefs-into-head` seeds `head-prefs :git-format` from the file and
    `head-into-prefs` reads it back, so `/config` and `head.toml` cannot drift;
  · `%git-format` reads the LIVE plist (`*head*`'s `head-prefs`), not `*prefs*`;
  · and **the pane's own fixture needs four lines**: the new row's exact column padding, the
    cursor line, and two more `nth` positions in
    `the-config-pane-renders-every-row-with-its-source-under-the-cursor`.


- [x] **the git field's COLOURS and its CONFIGURABLE FORMAT** — DONE (2026-10-11, verified against
  this list item by item). `+git-format-default+` is `"%b%d%a%s%m%~%+%!%?"`; `+git-slots+` maps the
  glyphs (`%%` literal); `+git-styles+` is one ROLE per segment, word for word with the decisions
  above (branch green clean / yellow dirty, `+` green, `!` yellow, `?` dim, `~` red and bold, the
  action bold magenta, `*` magenta, `⇣`/`⇡` cyan); `%git-pieces` returns `(text . style)` pieces with
  each literal attached to the piece it PRECEDES; the state is cached as FACTS and never as a
  rendered string; the format is applied on the reader thread; and the preference is `git_format` in
  this head's own file, with its load arm (including the quoted-string handling) and its save arm in
  `src/prefs/notes.lisp` and its default in `*prefs-defaults*`. Held by
  `the-git-format-is-configurable-and-the-colours-are-roles`.

  **The paragraph below is kept as the record of the design, which is the expensive part.**
  The operator asked for both, 2026-10-04, right after the field gained gitstatus's segments:
  *"how about we do the colours too and the configurable format too"*.

  **The decisions, which are the expensive part**:

  · the cache holds the **STATE** (`:branch :detached :behind :ahead :stash :action :conflict
    :staged :unstaged :untracked`), never a rendered string — a cache of text is a cache of
    somebody's old format choice;
  · a **format** turns the state into PIECES, one `(text . style)` per placeholder, literals
    attached to the piece they PRECEDE so fitting drops whole pieces and never half of one;
  · placeholders **are the glyphs**: `%b %d %a %s %m %~ %+ %! %?`, `%%` literal; default
    `"%b%d%a%s%m%~%+%!%?"`, which is the concatenation that ships;
  · **colours are roles, one per segment**: branch green when clean and yellow when not (the one
    fact read at a glance), `+` green, `!` yellow, `?` dim, `~` red and bold, the action bold
    magenta, `*` magenta, `⇣`/`⇡` cyan;
  · **the format is applied ON THE READER THREAD, never in a paint** — a mistyped template or a
    preference function this build lacks is then a bad line rather than a header that fails to
    draw;
  · the preference is `git_format` in this head's own file: add it to `*prefs-defaults*` and the
    load/save arms in `src/prefs/notes.lisp` (`*prefs-keys*` was a fourth list to keep in step
    and nothing read it — deleted 2026-10-11, so the arms are the only place), an accessor pair,
    one load arm and one save arm — the load arm needs the
    quoted-string handling `todo_template` has.

  **Where it stopped**: the core was written into `src/chrome.lisp` and then reverted, because
  the migration left three callers speaking the old shape and the git tests at 3/15 — so this
  starts from the decisions rather than the wreckage. HEAD is green (`41d8935`, 7043 checks).


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
| `letibot` (reference) | `149edf91b9740ac7775a0a875abfcd562c8fd3e6` | 2026-10-04 |
| `letibot` (the pin this replaced) | `8af671e3467ce0a139ba25d99a18378ba39c910b` | 2026-09-20 |
| `leticl` (this) | the commit each row names | |

**THE PIN MOVED 2026-10-04, AND THE PAIRING IS WHAT SAYS IT IS SAFE.** 322 commits
between the two, and `PROTOCOL_VERSION` went **21 → 27** — so the reference is now
the daemon this head actually speaks to, which the ship pin already was
(`LETIBOT_REF: v0.2.2` in the release workflow is the same 27; the ordering rule
lives there: letibot tags, that pin follows, this repository tags third).

Every citation in `docs/parity/` is a line in **that** commit. Before acting on
one, `git -C ~/Projects/letibot/letibot log --oneline <the commit the citation
names>..HEAD` and re-read the function: a citation is a pointer into a moving
tree, not a specification. When the numbers stop matching, **re-measure the
document** rather than guessing which line moved.

**AND WHAT MOVING IT COST IS MEASURED, not discovered one citation at a time.**
`scripts/repin-check OLD NEW [DOC…]` answers the only question a repin has to
answer — *is that line still the line* — over every `something.rs:NNN` in a
document, and prints this:

    document                  cites  exact  moved  gone  lost  ambig
    keys.md                     130      5    125     0     0      0
    wire.md                     201      3    192     1     0      5
    rendering.md                329     36    248     0     0     45
    panes.md                    177      5    149    19     2      2
    one-to-one.md                 4      0      4     0     0      0
    TOTAL                       854     49    731    20     2     52

`exact` is the strong claim: the same text is at that line in both revisions.
`moved` is what this doctrine expects, and the answer to it is *re-read the
function*. **The twenty `gone` and the two `lost` are ONE structural move and not
twenty-two edits**: `crates/tui/src/bin/letibot-tui.rs` was 759 lines at the old pin
and is 11 at the new one, because the Rust TUI became a workspace crate
(`app.rs`, `head.rs`, `render.rs`, `term.rs`, …) — every `bin/letibot-tui.rs:NNN`
citation has to be re-POINTED rather than renumbered. `ambig` is a basename that
matches more than one path in the reference (`syntax.rs`): the tool refuses to
guess which one a document meant, which is the whole reason it is run before the
documents are touched.

**AND THE SOURCES CITE IT TOO** — the same measurement over `src/*.lisp`, which is
where this tree's method actually keeps its citations:

    src/*.lisp                  338     20    299     5     1     13

So the pin's move is **1192 citations and not 854**: 69 exact against the new
commit, 1030 moved, and six that cannot be followed at all — five into
`bin/letibot-tui.rs` (`chrome.lisp`'s `ATTACH_WAIT` and `replay.lisp`'s four) and one
into `rano/src/syntax.rs` (`markdown.lisp`). **None of them was rewritten to hide
this.** A docstring that cites `app.rs:9712` is a record of what was READ at a
commit; the honest answer is the pin that says which tree, and the next pass's
queue — not an edit that would make a stale line look measured.

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
| **the `/cells` fold is unrecoverable** | **FILED with the measurement, not built** (the operator's R27 second ruling, clause 3, is the test). **A `/cells` message is drawn as two rows** — the operator's words and `· 63 rows of this screen (210x63) went with this message` — and **no key on this head reveals the 63 rows**: measured on a live head, `item-lines` draws 2 rows, the unfolded content is absent from the screen, `payload-view-seed` answers NIL (it considers `tool_result` rows only), and the RECORD still holds all 63. That is the ruling's test failed exactly: *"they arent reread, but they are the part of the decision chain"* — the operator sent a screen as EVIDENCE, the reader is shown that a screen went and not what it said, so every conclusion drawn from it is unsupported from the screen. The bytes are in the record (so the model has them and a listing could print them), which is *recoverable by a tool call* and not *present in the chain* — the same distinction the ruling draws. **The fix is to reuse the payload window** (`ctrl-t` already pages, already has a seam and esc) by letting it seed on a user row whose text carries a `cells` block, and by having the user row draw the block instead of the fold line when the view is on it. Not built: the operator said *nothing new to start*, and this is filed with its number so it is one small landing whenever it is wanted | — |
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

## R29 rule one — DONE, live, and the audit's second clause

**Landed `44830ac` and PUSHED to the operator's head** (pid 2328208, protocol 23): 109 forms,
none failed, render gate green, and the two `slash_refused` rows on their screen now end
`  → nothing to fix — that verb does not exist. /help lists the ones that do; ctrl-n clears
this note`. Their eleven notes are still theirs to clear, with `ctrl-n` now in the image.

**The audit's second clause** — *does the act work in the process they are in* — measured on
that head with a throwaway head per verb, so their session saw nothing:

| named act | what THIS head does |
|---|---|
| `/help` `/status` `/notes` `/dismiss` `/subagents` `/verbosity` `/promote` `/peek` `/switch` `/rename` `/resume` `/cells` `/quit` | runs HERE — a pane, a sentence, or an in-place change |
| `/mode` `/models` `/sessions` `/new` `/resync` `/compact` `/reseat` `/tools` `/todos` `/interrupt` `/gate` `/job` `/flowy` | goes to the daemon as a slash line — the daemon's own verb, and its answer is the record |
| `ctrl-n` `ctrl-r` `ctrl-t` `ctrl-p` `ctrl-q` `ctrl-s` `ctrl-x` | claimed by `%global-chord` on a fresh head |

**Every act the table names resolves**, and none of them is a remedy that cannot run. The two
that name *something the reader must do outside the glass* — `frame_capture_disabled` (set the
env var, restart the daemon) and `protocol_skew` (restart one of the halves) — say so in those
words rather than pointing at a key.

**And the probe found a trap worth writing down: `*slash-commands*` is the COMPLETION
registry, not the dispatcher.** The first version of the audit checked named verbs against it
and reported `/gate`, `/flowy`, `/job` and `/verbosity` as *remedies that cannot run* — all
four work. `%command` has arms the registry does not list (`verbosity`, `jobs`) and forwards
anything else to the daemon, where `/gate`, `/flowy` and `/job ID` live. **An audit of *what a
head can do* has to ask the dispatcher and the wire, not the list it completes from.**

## R38 — a setting with more than two values is CHOSEN, not cycled

**Landed `dfad931`, the verbosity half.** `/verbosity` opened a four-rung cycle: with R37's rung the
reader pressed up to three times and watched the screen change twice to reach the one they wanted,
and discovered the current value *by changing it*. It is now the picker this head already has
(`:verbosity` beside `:mode` and `:model`), each value saying what it MEANS and the card saying that
it applies to the transcript already drawn; `esc` closes it and says nothing was changed.

**`set-verbosity` is the one writer and invalidates the render history** — the rung is read at draw
time and `%hist-key` is (generation, width, items identity), none of which a rung moves, so without
the bump the cache serves the previous rung's lines back.

**The diff half is FILED and not built**, per R38's own instruction (*name the values first, then
build the card*). The ask to letibot names this head's two words (`split`, `unified`), asks whether
there is a third (`auto` is accepted as an input spelling here and maps to `split`), and asks the
one question that is not vocabulary at all: **does letibot's diff carry a sign column?** leticl's
does — `+`/`-`/space is the carrier and the colour is on top, so a monochrome terminal reads it —
and if the other head is coloured without a sign then no setting makes the two diffs one artifact.

---

## The elision audit — the R27 second ruling's test, on this head's surface

**The operator's test, 2026-09-23:** *"they arent reread, but they are the part of the
decision chain."* So for every place this head shows a region as elided, cleared, not carried
or replaced, the question is **not** *is the absence disclosed* but **can the reader still
support the decision that region was evidence for.** Surveyed across `src/`, with what each
site draws and what gets you back:

| site | what it is | the way back | verdict |
|---|---|---|---|
| folded tool payload (`… +N lines · ctrl-t opens it`) | window | `ctrl-t` pages it; the seam names the key **on the row the chord acts on**, `/t unfolds it` on every other row (R40) | **PASS** |
| R20 card content (`… N rows out of view · PgDn`) | window | PgUp/PgDn/Home/End/wheel, pinned ladder unharmed | **PASS** |
| the `rows above` seam (T1(1)) | window | scroll to the top asks the daemon for the row | **PASS** |
| job output, windowed mid-log (`512 earlier bytes gone off the front`) | ERASURE by the daemon's ring | nobody holds them; the window's state and count are all there is | **PASS by necessity** — the erasure is the daemon's, and the row says which |
| peek pane (`full: <path>`) | window + spill | the file exists on disk and is named | **PASS** |
| spill head (`N of M went to the model … read_spill hash=…`) | locator | `read_spill` with the hash | **PASS** |
| shortened subject (`…`) | elision | `ctrl-x` draws the raw call and its arguments | **PASS** |
| **folded `/cells` block** | **REPLACEMENT** | **none — measured** | **FAIL** |
| queue echo clipping (20 drawn of 28 held) | window, undisclosed | none yet | **FAIL** (filed above) |

**Two fail, and both are filed rather than built.** The `/cells` one is the ruling's own
shape: replaced, not windowed — the reader is shown that a screen went with the message and
not what it said — and it is the only one of the nine where the head HOLDS the bytes and
still cannot show them. Everything else on this list either pages, names a key, names a file,
names a tool, or is an erasure nobody can undo; the `/cells` fold is a replacement this head
chose.

**And the ruling's second clause is now a build constraint for R27's renderer, written down
before it is built:** a carried tail and a summarised head are **different KINDS of presence**
and must not read as one continuous region — a summary is the daemon's reading and a tail is
the conversation itself, and a reader who cannot tell which words are whose cannot support
anything downstream of either. Same principle, one layer up, as a section marked `(none)`
against a section absent: *nothing is blocked* and *nobody said* are different facts, and a
renderer that folds them together has thrown away the distinction the wire was widened to
carry.

## In flight

- [x] **cards + markdown + width** — `cards/*.lisp`, `markdown.lisp`, `width.lisp`,
  `cells.lisp`. Priority one is **escape sanitising**: tool output currently
  reaches the terminal unfiltered, and the reference closed that in `f36d927`
  ("a tool's output cannot reconfigure the operator's terminal"). **The width half is
  closed**: W1 landed the wrapping rules, and the structural commit after it merged
  the two breakpoint scanners into one (`%break-ranges`, used by `wrap-segments` AND
  `wrap-ranges`) and deleted the third truncator, which was per-character and silent.
  **AND THE LAST CLAUSE IS CLOSED TOO** (2026-10-11): a row composed wider than the frame was
  cut by the PAINTER — `screen-put-string` drops every cell past the right edge without a word —
  so the hint bar ended `ctrl-q ` where the reference ends it `ctrl…`. The bar now composes to the
  width it is drawn in (`%truncate-segs`, the composer the transcript's own rows use), so the
  elision is the head's usual `…` and the reader can tell a key that is missing from one that never
  existed. `rendering.md` §6 gap 23, and the reason the bottom row differed in every fixture of the
  1:1 rig.

  Its test had to be corrected rather than merely kept green: `ctrl-n-is-in-the-hint-bar-…`
  asserted `(= 1 (length (hint-bar h 80)))` — true only WHILE the tail was being dropped in
  silence — and it now asserts the property it was always about: same string, cut at the TAIL,
  with the mark allowed to be a segment of its own (which is how `%truncate-segs` keeps the style
  of whatever was being cut) and the prefix nothing has re-ordered.
- [x] **screens + frame** — `panes.lisp`, `chrome.lisp`, `render.lisp`. **EVERY CLAUSE ON THIS
  HEAD'S SIDE IS CLOSED, verified 2026-10-11**, each by the test that holds it:

  · the picker opening off your own session — `the-picker-opens-on-the-session-you-are-in`;
  · the peek pane's dead cursor — `the-peek-panes-arrows-and-enter-do-what-it-says` and
    `the-peek-pane-shows-the-tail-and-names-its-spill-file`;
  · the permission card drawing one line of the oracle's five —
    `the-permission-card-draws-the-oracles-verdict`;
  · no fit ladder — `the-chrome-is-given-up-in-the-references-order` (and the gutter:
    `the-gutter-is-the-first-thing-a-narrow-screen-gives-up`);
  · the carry line — landed (`filling-progress-line`), and **the daemon half is NOT OURS**: the
    event is ruled to be `SessionEvent::Filling { what, unit, done, total }`, replacing
    `ImportProgress` inside protocol 23, and that is letibot's tree. This head folds BOTH names,
    with the old one through a named compatibility arm to delete when the rename lands — which is
    the correct end to hold, and the reason this box can close here.

  *(Original text kept below for the record.)* The
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
- [x] **diff + highlight** — `diff.lisp`, `sidediff.lisp`, `highlight.lisp`. **ALL THREE CLAUSES
  SETTLED, verified 2026-10-11**:

  · **Dead intra-line emphasis** — the wiring is repaired (`%pair-rows` binds its addition run's
    start before consuming it) AND both call sites pass `:intra-line nil` with the reference's own
    reason, because repairing the wiring made this head emit emphasis the reference deliberately
    suppresses (`edit-card.lisp`).
  · **SAPs passed unpinned across the FFI** — `sb-sys:with-pinned-objects` around the hand-over,
    held by `the-alien-call-pins-the-vectors-it-hands-over`, whose docstring records what the
    unpinned version bought: not a crash but the shim writing role indices into whatever object
    the collector had moved there.
  · **Every visible fence re-parsed through the shim on every frame** — this is the one left
    DELIBERATELY undone, and the argument is in `rendering.md`: a markdown cache would need an
    invalidation key covering five defvars any eval can change, in a head whose contract is that
    redefining a renderer changes the next frame. `TODO.md`'s T7 keeps that argument and its first
    half (the render counter and its bound) has landed.

## Queued from the reference's own batches — surveyed, not yet built

Two batches of the reference (2026-10-09) were read in full, and everything this head
must mirror is written down here: the wire and the policy are ported, and each of the
rest names the commit it comes from.

- [ ] **the reference's head-side mirrors from its 48-commit batch (2026-10-09)** —
  the wire and the policy are ported (`06e0da9`, `c2a5605`: protocol 37's todo
  author, the read-only seating of an older daemon, the list-derived child's
  `stored_end`); what remains is head-side UI, each measured against this tree:

  - [x] **scrolled back, the turn's prompt stays pinned on the top row**
    (`26b9e08`) — **LANDED `1cb72ac`**, held by
    `scrolled-back-the-question-stays-pinned-on-top`. The turn is found from the row at the TOP of the window,
    walking back to the nearest row the operator wrote — the pin is the
    question the VISIBLE answer answers, not the session's newest — drawn as
    their row is drawn and cut to one line, covering the top row the way the
    holding banner covers the bottom. Not drawn while the prompt itself is on
    screen; a prompt above the rows a tail frame rendered has no span and is
    pinned too.
  - [x] **a wheel notch renders before it steps, and a run of notches outpaces
    a living stream** (`a950c6e`) — **LANDED `15e17a5`**, held by
    `a-run-of-wheel-notches-outpaces-a-living-stream` (and the page-unit numbers beside it:
    `the-wheel-notch-and-the-page-keystep-are-different-numbers`).
  - [x] **the count labels on the composer's edge are BUTTONS** (`9ac7dad`) — **LANDED 2026-10-11**,
    held by `a-click-on-the-edges-count-labels-opens-the-pane`: a click on `N subagents running`
    opens the subagents pane and on `N jobs running` the jobs pane, a click elsewhere on the edge
    opens nothing (the border is not a button), and with nothing running there are NO targets
    because a target is what the reader can see. **The hit test reads the PAINTED frame**
    (`%composer-edge-buttons` searches the last drawn top edge for the two labels), which is the
    shape this row's own text prescribed and the reason it cannot disagree with the drawing — the
    box's row and the legend's columns are functions of the chrome the frame laid out.
    *(The original finding kept below.)*
    a click on `1 subagent running` opens the subagents pane, `1 job running`
    the jobs pane. This head already converts clicks for panes and rows; this
    is the edge's own hit test.

    **WHAT IT NEEDS, measured 2026-10-11 so the next session starts from facts rather than
    from the reference's wording**: the legend is `composer-legend` (`src/chrome/composer.lisp`),
    rendered into the box's TOP edge by `composer-box-top` as ` {legend} ─` right-aligned inside
    the box's inner width; `%click` (`src/editor/click-actions.lisp`) receives the screen ROW and
    does not know where the box is, because the frame composes the chrome from the bottom up. So
    the two missing pieces are a helper that answers the box's top row (the tests already find it
    the robust way — search the LAST PAINTED rows for `╭`, as `%ghost-box-top` does — and using
    the painted frame means the hit test cannot disagree with the drawing) and a span per label
    computed from the same pieces the legend composes (`~d subagent~:p running` and `~d job~:p
    running`, joined by ` · `), so a click maps to `(:subagents)` or `(:jobs)` and `%open-pane`
    does the rest. `%click`'s existing arms show the shape: a `cond` clause BEFORE the pane arm,
    answering `t` when it took the click.
  - [x] **a settling diff card is handed over on the row's body, not its
    announcement** (`98a8f11`, the settle-flicker merge: a call is in one half
    or the other, never neither, so a settling card's frames are identical) —
    **HELD BY TWO TESTS, verified 2026-10-11**: `the-markers-number-hands-over-from-live-work-to-
    the-row-without-a-dip` (a finished call whose row has not landed is still counted, so the
    number cannot dip — the operator's own *"2 (in yellow) → 1 (in yellow) → 2 (in white)"*) and
    `a-call-the-transcript-has-answered-is-not-drawn-executing` (once the row lands the call stops
    being drawn as executing). The card and the count share `%hidden-run-live-work`, which is why
    one rule covers both halves of the handover.
  - [ ] **a click on an edit opens its change in a popup** (`88b003d`): the
    whole file, no editor chrome; and **the popup's scroll repaints its rows,
    not the whole screen** (`6fb34d4`).
  - [ ] **a redirected job's window is the file, even when a preamble reached
    the capture** (`d234194`) — the jobs pane's tail. **NOT LANDED — probed 2026-10-11**: no
    code in `src/panes/job-out.lisp` or the frames path mentions a preamble or a redirect, and no
    test covers it, so this is genuine work and not another already-done row. The shape it needs:
    when a job's command redirects its own output to a file, the daemon's capture holds only the
    preamble it saw before the redirect, and the pane should show the FILE's contents (the job's
    real output) rather than that preamble — which means the head has to know the path, and the
    place to learn it is the `JobEntry`/`Jobs` reply the pane already draws from.
  - [ ] **`ctrl-e`: a real editor pane** (`a8f5e83`, `e38b82e`, `8e91a4b`,
    `88b003d`) — ctrl-e puts the editor away and brings it back with its files
    kept; on an empty prompt it opens on any file; and the pane wears the
    head's frame rather than nano's. This is the `!term` project's sibling and
    the same rectangle contract applies.

    **MEASURED 2026-10-11, AND IT SETTLES WHERE THIS BELONGS.** The reference's `open_editor`
    (`crates/tui/src/app/editor.rs:323`) is an `EditorPane` holding **a rano instance** — it
    TOGGLES (`p.hidden = !p.hidden`, so *put away* is not *destroyed*: the file, the cursor and the
    keyboard come back as they were), it is drawn BEHIND the composer, and the door into it is
    *`F8` is rano's `open-file`, in its global map, and a key is the one door into rano's commands
    its API keeps public*. So this is not a head-side pane at all: **it is the `!term` project's
    sibling**, needing the same rectangle contract — a program that owns the conversation's
    rectangle — and the same client frames. A head that built "a pane drawing a file" would be
    building the wrong thing, which is why the item is left where the ledger already put it: beside
    `!term`, not in the 48-batch's list of small mirrors.
  - [ ] **standing notes: the agent writes the notes it already reads**
    (`1c9f3a4`, `35670ee`, `1be706b`) — a tool, so the wire is the tool table;
    the head's notes pane is the surface, and every read must say the notes are
    historical. Delivery moved to session open and every base rebuild, and
    nowhere else.
  - [ ] **a refused request compacts: the wall classified** (`03f0277`,
    `08faf55`, `8590f2c`, `7eceda7`) — a provider's context-length refusal IS
    the wall; the guard stands down the pre-emptive door only and survives the
    restart; both automatic doors take the pre-turn check.
  - [x] **a model change during a retrying turn takes** (`12ade5e`) — **THE HEAD'S HALF IS IN**
    (2026-10-11, `a-model-change-mid-turn-says-the-turn-continues`): `/model NAME` while a turn is
    running now says *the model changes at the next round — this turn continues on <the one it
    started with>*, instead of `sent: "models …"`, which left the one question a reader has
    (*did that interrupt anything?*) unanswered. Asked of `turn-busy-p` and not the state name,
    because the name reads `finished` for the whole of a tool call and a command issued then is
    just as mid-turn — which the test's third case asserts with a call in flight.
    **The daemon half is not this head's** (the retrying turn's own behaviour).

- [ ] **the reference's second 116-commit batch (2026-10-09, protocols 38–42)** — the wire
  core is ported (`c2a5605`'s successor: 42's todo author and `cancelled`, 40's
  `TranscriptForked` drop, the exit id on stdout, `prefix_stale`); what remains is head-side:

  - [ ] **the standing-notes pane** (`ccee82a`, protocol 39): `ClientFrame::ListNotes` →
    `ServerFrame::StandingNotes` carrying `NoteEntry` — one row per note, and the form the
    budget gave each. Two frames, so this is the one item here that adds wire. The reference's
    pane draws it and Enter opens the note in rano (`81749c9`).

    **THE RENDERER IS LANDED (2026-10-11)** — `standing-notes-lines`, held by
    **AND THE WIRE WITH IT** — `make-list-notes`, the `standing_notes` fold (which REPLACES: the
    reply is a snapshot of the harness's mailbox), the `/standing` verb that asks, and the pane
    registered (class, `:standing` keyword, three methods, and BOTH mode lists in `%handle-key` —
    the trap the queue's pane taught, handled before this one's first run).
    **AND THE FAULT WAS IN THE VERB, FOUND BY THE TEST**: `/standing` left the screen on the
    conversation because **the arm's body only ASKED** — it was written to satisfy the
    constructor-needs-a-caller invariant and the OPEN was never wired. With the arm fixed
    (`%toggle-pane … :standing`, the ask as the pane's open, which is the reference's shape), the
    pane opens at the keypress, draws the renderer's rows and closes on `q` — held by
    `the-standing-pane-opens-at-the-keypress-and-draws-the-mailbox`, which is its OWN test because
    the first attempt bolted these assertions onto the wire test where the fixture's `let*` had
    already closed. **A test is not a place to save a line.**

    **THE ITEM IS THEREFORE COMPLETE**: the two frames, the fold, the verb, the pane and the
    renderer, each with its own test — and five measured corrections behind it (a frame needs its
    caller, a verb its registry row, a pane its mode-list entry, a test that reads a global is
    fragile, and a verb needs its OPEN). **What remains in this row**: `Enter` opening the note in
    rano (`81749c9`) and `NoteForm`'s own vocabulary beyond the two words this head saw.
    `the-standing-notes-draw-their-form-and-where-their-abstract-came-from`: one row per note, the
    path whole, the FORM drawn (`[verbatim]`/`[indexed]` in the registers Success/Pending), the
    abstract, and **whether that abstract is the author's own or the harness's derivation** — the
    field's own reason, since *a reader who cannot tell them apart is taking a guess for a
    statement*. A file with no prose says *nothing but headings* rather than drawing a blank line.
    **What remains is the same as the queue's next step**: the two frames (`list_notes` →
    `standing_notes`) with their fold, the pane's registration, and the ask on open.

    **MEASURED 2026-10-11, SO THE SHAPE IS KNOWN RATHER THAN GUESSED**: the ask rides the
    **PANE OPEN**, not a verb — `app/standing.rs:133` is `self.standing_pane.then_some(Action::ListNotes)`
    and `ui/panes/standing.rs:70` queues it on open. The protocol's own docstring says why: *"a list
    is a question, not an act — a pane that opens must answer while it is open, and a verb that
    rides the command queue answers after the turn"*, and it is *read-only and unserialised like
    `ListJobs`*. And the answer is **the harness's mailbox, not a fresh read of the directory**:
    the form each file has is decided with the session's own token counter, which the server thread
    does not hold. So this is `ListJobs`' shape one mailbox over — the seam the jobs pane already
    keeps at `%toggle-pane` — and NOT a `/notes`-style verb, which is what a guess would have
    produced.
  - [x] **the carry by the row's own words** (`53ac610`, `7b18b1d`) — **LANDED 2026-10-11**, held by
    `a-fork-carries-the-readers-place-by-the-rows-own-words`: a fork captures the anchored row's
    WORDS before removing the parent's rows and re-finds a row that carries them under its new id,
    keeping the offset into it, so a reader scrolled back does not lose their place when the
    transcript is forked. A row nobody carried still loses the anchor (and `%anchor-lose` says so,
    as before), and a reader at the bottom is not given a place they never had. *(Original below.)*
    (from `53ac610`, `7b18b1d`): on a live re-seat a fork
    takes the reader's CARRY — the row's own words and the line — and the view is re-anchored
    by them under the new id, or the sentence says it cannot. The fork port drops the anchor
    and lets `%anchor-lose` say so; this is the better half.
  - [~] **the todo verbs and the pane's own reading** — **`/todo rm N` LANDED 2026-10-11**
    (`a-row-is-struck-off-by-rm-and-brought-back-by-resume`): the verb strikes a row off by
    number, the row keeps its words, `/todo resume N` brings it back, the refusals name the row
    or the word, and a bare `/todo rm` is a usage note naming the verb. The status is
    `cancelled` — the daemon's own word — because a DELETE would be this head forgetting
    something the other half still holds. **Still open here**: a row read whole with enter
    (`fe9febe`), a row's title capped at the pane's own row with the rest as detail (`aa27a89`),
    one row marked by quoting it (`09b1c0f`), a row waiting on a CHILD (`f8d98b6`), and the
    plan as a DAG with `needs` edges (`c211118`, `f8d98b6`) — `TodoNeed::{Row, Child}` rides
    the row and this pane draws none of it.
  - [ ] **the merge queue** (`e9eb358`, `424c212`, `8178c4e`, `5b925b6`, `1cff68e`,
    `0b05003`): the pane, the person's approve/veto/rm, `/queue reset|clean|restart`, the
    gate's steps drawn in order, the standings beside the triangle, and the review queue as
    TWO VIEWS OF ONE LIST (protocol 38's removal rides it). The big filed project; the queue
    is daemon-level and asks with `ListMergeQueue`.
  - [ ] **the lateral send and the question row** — a message to a session the worker owns is
    a row and a turn (`af218a2`, `3d36cea`), and an answered question leaves the operator's
    answer as their own row, byte-identical and citable (`7179fc6`, `0cf9cce`).
    **MEASURED 2026-10-11: the question half is the DAEMON's, not this head's.** `7179fc6` is
    `harnessd/src/answers.rs` + `harness.rs` (+ its own 500-line test) — the row is appended by
    the daemon and this head draws it with the speaker rule it already has (`speaker: operator`
    draws as the person's own row, `agent` as the session's labelled one), which the earlier port
    landed. **AND THE LATERAL SEND IS THE DAEMON'S TOO — MEASURED THE SAME WAY**: `af218a2` is
    `harnessd/src/sessions.rs` + `harness.rs` (+ a 1126-line `session_channel.rs` test), so a
    message delivered into a worker-owned session is *delivered by the daemon*; this head's part is
    drawing the row and the turn that arrive, which is the rendering it already does for every other
    row. **SO THE WHOLE CLAUSE IS THE OTHER HALF'S**, with this head's obligation being only that it
    draws what arrives — and that is worth saying plainly, because the ledger's prose read as two
    head-side features.
  - [~] **the head's smaller mirrors**: **a printed path IS a link — probed and LANDED
    2026-10-11** (`src/links.lisp`, held by `a-link-url-is-never-built-from-content`,
    `an-image-path-becomes-a-link-and-the-url-is-head-authored` and
    `a-link-is-refused-when-the-path-is-not-honest` — the last being the security half: a URL is
    never built out of content). **AND A CHANGE DETECTED AFTER A COMMAND DRAWS ITS DIFF — also
    LANDED**: `a-bash-command-that-edits-a-file-draws-its-diff` is the operator's own report from
    their rano session (*"why im not show normal diff card"*, then *"i want diff card for python
    edits you all love so much"*) turned into a test: the daemon sends a `FileEdit` when a command
    changed exactly one file, and this head used to throw it away because it chose what to draw
    from the TOOL'S NAME (`bash` is neither `:edit` nor `:write`), so a `python3 - <<'PY'` heredoc
    that rewrote a source file got a note and no diff.
    **AND A JOB NAMED IN EVERY SENTENCE ABOUT IT IS LANDED 2026-10-11** (`job-label`, held by
    `a-job-is-called-by-its-name-and-falls-back-to-its-command`): the name the caller gave the job
    when there is one, and the COMMAND when there is not — never the id, because `j57` is a counter
    and *a person watching the pane cannot tell which running job is the release build and which is
    the fold's tests*. Measured against `protocol.rs:1268`, whose own words are that the name is
    *the agent's own stated intent* and *never a parse of the command line*, because a slug derived
    from the command would be the machine inventing an intent.
    (`29f2422`, `5d3bfac`), **`allow-all`'s answer surviving a restart (`9f09f04`) IS THE DAEMON'S** — `harnessd/src/modes.rs`
    + `harness.rs` + `sessions.rs`, the answer living in the session's store rather than in a head's
    memory. **And `195a813` (a stop interrupts the turns it holds) is MOSTLY the daemon's** —
    `sessionlog/src/{registry,server}.rs` — **with a genuine 20-line head half** (`app/session.rs`):
    this head must let a `Stop` end the turn it holds rather than leaving a running turn's clock and
    spinner over a daemon that has gone. **AND `195a813` IS MEASURED IN DETAIL NOW, and the head's part is already this head's
    behaviour**: the commit is `Registry::close` interrupting the turns it holds (*CommandKind::
    Interrupt under DAEMON_SUBMITTER, submitted to every hub whose status().running is true*) plus
    the launcher's `--stop` sending `--interrupt-all`, and the head's own twenty lines are about not
    drawing a running turn over a daemon that is going. **This head leaves on `Bye`**, which is the
    same obligation discharged a different way — and its own `a-bye-is-the-end-of-the-conversation`
    holds it. So nothing here is owed. The term pane (`401e61f`) remains the `!term` project.
    that interrupts the turns it holds (`195a813`), and the term pane born at its size
    (`401e61f`).


## Filed for their own sessions — the `!term` pane, and the merge queue

Both were measured against the reference's current tree before filing, so the next
session starts from facts and not from a summary's memory. Neither is parity debt:
the wire half of each is additive (protocol 31+ frames; leticl is 36) and nothing a
head runs today breaks without them.

- [~] **the `!term` pane + a VT renderer** — **THE WIRE, THE PANE AND THE KEY PATH ARE LANDED
  (2026-10-11)**, held by `a-terminal-opens-takes-keys-for-the-program-and-ends-when-asked`: the four
  client frames (each with its caller), the `head-term` slot, the three server folds, the pane, and
  the `/term` verb — which opens the pane rather than sending a second `TermOpen` the daemon refuses.
  **AND THE KEYS A SHELL NEEDS**: Enter arrives as `#\return` (CR, not LF), Backspace as DEL `#x7f`
  rather than BS `#x08`, and the arm has to be FIRST in `%pane-key`'s `cond` because the pane's own
  Enter arm is earlier than the character arms — the same ordering rule as `q`. **Two things are
  deliberately NOT done and are recorded here rather than in a commit message**: `TAB` cannot reach a
  program today (`:tab` is taken by the completer before a pane's cond sees it — a change to the
  completer's routing, its own increment), and Backspace's byte mapping is written in the code with
  its reason but UNASSERTED, because the fixture that tried compared a byte a failure message cannot
  render, and an assertion that cannot say what went wrong is worse than none.
  `q` closes the pane AND ends the terminal; every other key goes to the PROGRAM. **AND THE PANE SAYS
  WHAT IS MISSING**: the bytes are drawn as text because that is what arrived, and the VT EMULATOR is
  the remaining half — the one thing a head must not fake, because a faked screen makes the missing
  half invisible. *The two failed attempts that preceded this are recorded below; they are why it
  landed in one piece.* — **AND ITS WIRE IS MEASURED 2026-10-11**
  (`sessionlog/src/protocol.rs:344-460`): four client frames — `TermOpen`, `TermInput`,
  `TermResize` (the head's rectangle) and `TermClose` — and three server ones: `TermAttached`,
  `TermOutput`, `TermEnded`. **The rules the docstring states and the head must keep**: *ONE pane per
  session at a time* (a second `TermOpen` while one is live is refused), `TermInput`/`TermOutput` are
  the pair that carry the bytes, and the two frames that are neither a line nor an answer are the
  rectangle and the ending. So the project's first increment is the four constructors WITH the pane
  that opens one (the caller rule), and the VT renderer is the second — the wire is not the hard
  part.

  **AND AN ATTEMPT AT THE FIRST INCREMENT MEASURED WHERE IT ACTUALLY STARTS — 2026-10-11**: the four
  client frames were written (with the pane that opens one, so the caller rule was satisfied), and
  the suite refused the result in exactly the place that matters: **`every-frame-constructor-is-
  actually-sent` refuses `TermInput` and `TermResize`, because their caller IS THE INPUT PATH and
  there isn't one.** That is the invariant doing its job rather than being an obstacle: a terminal
  pane that cannot accept a keystroke for the program is not a terminal pane, so the honest first
  increment is the pane's KEY PATH (a key in `:term` becomes `TermInput`, and a resize becomes
  `TermResize`) — and only then the frames it feeds. Reverted so the tree is green; what was learned
  is that **the VT renderer is not the first step, the input path is**, and that the frames' own
  shapes are four lines each once it exists. — a program that owns the conversation's
  rectangle. **The wire half is the small half**: client `TermOpen` / `TermInput` /
  `TermResize {cols rows}` / `TermClose`; server `TermAttached {command}` /
  `TermStatus {command}` / `TermOutput {bytes}` / `TermEnded {reason}` (protocol 31;
  `TermAttached` is a new server frame, which is why 31 was a bump). **The renderer
  is the project.** The reference's pane is `letibot-vt`'s `Screen` — a rectangle of
  cells, a cursor, a pen, an alternate buffer — plus `letibot_ui::ansi::pane_rows`,
  and the contract that matters is THE RECTANGLE: `pane_rows` answers EXACTLY
  `room` rows, so the composer, header and status never move by a line when the
  pane opens and never lose one when it closes. For this head the renderer is
  either a Lisp cell-grid VT emulator (cells, cursor, pen, alternate buffer, SGR,
  CUP/ED/EL, scroll regions) or an FFI to `letibot-vt` — the highlight shim
  (`native/libleticl_hl.so`) is the existing pattern for the second, and the same
  trade it made (a native dependency against a live-patchable image) is the first
  decision to argue. **The way out is `ctrl-\` (0x1c), intercepted on the raw byte
  stream BEFORE anything is forwarded** — the program never receives it and cannot
  trap it; Esc is wrong on purpose (it is `cancel` in vi/mc/nano/less and the first
  byte of every meta sequence). Detach ends NOTHING: the program keeps running on
  the daemon's pty and nothing is sent at all. This head's input layer reads decoded
  characters, not raw bytes — where 0x1c arrives and whether the interception can
  live in the driver is the first thing to measure.

- [ ] **the merge queue pane** — **STEPS, BY SIZE, taken from this box's own list** (added
  2026-10-11 so the next session takes them in the file's own order — smallest verifiable thing
  first, never across, and each step leaving the head working):

  · **S — the two frames — `ListMergeQueue` AND ITS ASK ARE LANDED** (2026-10-11, held by
    `the-merge-queue-is-asked-for-and-its-answer-is-kept`): `make-list-merge-queue`, a
    `head-merge-queue` slot, the `/queue` verb that sends the ask, and the fold — which REPLACES
    rather than merges, because a queue is a snapshot and folding it would let a landed entry
    survive a reset. The `/queue` row is in `*slash-commands*` too, which the registry/dispatcher
    drift test insisted on the moment the verb existed.

    **WHAT IS STILL MISSING FROM THIS STEP**: `MergeEntryAdded`/`MergeEntryMoved` — the two EVENTS
    that keep the queue live after the reply — and their folds. The reply alone is a snapshot; the
    events are what make it a queue a reader can watch.

    **STEP ONE IS COMPLETE — LANDED 2026-10-11** (the frames, the ask, the reply, AND the two
    events with their folds), held by `the-merge-queue-is-asked-for-and-its-answer-is-kept`. The
    paragraph below is the record of how it got there, including the hour that was not the folds'
    fault. The two arms were added to the
    head's event `case` (an add that appends by id, replacing rather than doubling so a reconnect's
    replay cannot double the queue; a move that sets state and evidence, keeping the evidence it
    has when the event carries none) and the suite went red in
    `the-diagnostic-verb-asks-for-both-halves-and-opens-the-pane`, on its last assertion —
    `*unreadable-total*` was no longer 0. Chasing it found the real defect one file over:
    **that test's last assertion reads a PROCESS global it never binds**, so it passed only while no
    earlier test had bumped the counter — inserting a test above it was enough to turn it red, and
    the diagnostic test sent no merge-queue frame at all. It binds `*unreadable-total*` now (as five
    sibling tests already did), the suite is green, and **the folds were innocent**.

    The folds landed once the test was fixed: append-by-id with replace (a reconnect's replay must
    not double the queue), a move that sets state and keeps the evidence it has when the event
    carries none, and no row invented for an entry the head was never told about.

    **AND IT CANNOT LAND ALONE — MEASURED 2026-10-11, one hour wasted so nobody repeats it.** The
    suite has an invariant, `every-frame-constructor-is-actually-sent`: *a frame the head defines
    and never sends is a feature that does not exist*. A wire half with no caller therefore fails
    the suite by construction — so **step one must be the pane's ASK together with its constructor**
    (a `/queue` verb or the pane's own open, which is how `/todos` and the jobs pane do it), and the
    constructor alone is not a landable increment. Written down because the tempting order — wire
    first, screen after — is exactly the order this tree forbids.
  · **S — the pane, drawing state and EVIDENCE — THE RENDERER IS LANDED** (2026-10-11, `merge-queue-lines`, held by `the-merge-queue-draws-its-states-and-why-each-one-is-that-state`): two lines per entry, `[state] branch` over the evidence, cursor reversed, the panes' own registers (landed Success, failed/conflict Failure, waiting Pending) and an unknown state drawn PLAIN rather than guessed; an entry with no evidence SAYS *no reason given*. **STEP TWO IS NOW COMPLETE TOO (2026-10-11)**: the pane class, the `:queue` keyword in `*pane-classes*`, `pane-lines`/`pane-cursor-rows`/`pane-hint`, `/queue` asking AND opening it (`%toggle-pane`), and — the piece the test caught — `:queue` in **the pane arm's mode list**, because `%handle-key` enumerates the modes it serves and a registered pane absent from that list DRAWS and receives no keys at all. Held by the same test, which asserts the pane opens at the keypress, the ask goes with it, the pane draws the renderer's rows and nothing of its own, and `q` closes it. **WHAT REMAINS** — the pane class, `pane-lines` calling this, the mode keyword, `pane-cursor-rows`, `pane-escape-target`, the hint row and `%open-pane`: the drawing is done, which is why the risky half was split from it.** One row per entry, the evidence as the reason —
    *the evidence is the reason for the state in the queue's own words*. The five states are
    already a vocabulary this head renders elsewhere; this is one more pane in `src/panes/`.
  · **M — the person's hand: approve, veto, rm.** **CORRECTED 2026-10-11 by measuring the
    reference: these are NOT client frames.** There is no `MergeApprove`/`MergeVeto`/`MergeRemove`
    in letibot's crates — the only client frame about the queue is `ListMergeQueue`, which this head
    already sends. So the acts must ride the SLASH path (a `/queue approve <id>` line the daemon
    answers, the way `/job` and `/gate` work), and the next session should confirm that in
    `crates/tui/src/keys/` before writing anything: inventing three frames for acts the daemon
    reaches another way is exactly the mistake this ledger keeps catching.
  · **M — the standings and the gate's steps, in order. MEASURED 2026-10-11, AND IT IS A RENDERER
    ADDITION RATHER THAN NEW WIRE**: the wire's own `MergeEntry` already carries
    `gate_steps: Vec<MergeGateStep>` (`sessionlog/src/event.rs:461`, `serde(default)`, so no
    version bump — *an older head ignores an unknown key and draws exactly the row it drew
    before*). Each step is `{ command, outcome, output, started_ms, elapsed_ms }`
    (`tokencore/src/store.rs:1230`), where `command` is *the command as `main`'s `AGENTS.md`
    spells it — the string a person would paste into a shell to reproduce the row*, `output` is
    *the tail of what the step wrote, with the bytes dropped from the front counted* (empty on a
    step that never ran), and `outcome` is a **closed four-word set** (green / red / never reached
    / no gate).

    **AND THE RENDERING IS LANDED (2026-10-11)**: each step is drawn with its outcome and its
    COMMAND, in the order `main` declared them, with green in Success's register and red /
    never-reached in Failure's — held by the same test as the queue's rows. Three facts are kept
    apart and the test holds all three: a `no_gate` step is its own sentence, an entry whose steps
    have not arrived says *the gate has not run on this entry*, and an empty list is NEVER drawn as
    a checklist (it would read as *all steps passed*). **What remains in this step**: the
    STANDINGS beside the triangle, which is a drawing question about the pane's edge rather than
    about the rows.

    **AND THE RULE THAT MATTERS IS THE REFERENCE'S OWN**: the `no_gate` case is a VARIANT rather
    than an empty list because *"the gate declared nothing to run"* and *"the gate has not run
    yet"* are different facts, and **an empty checklist reads as a third one — *all steps passed* —
    which is the lie the operator's own rule forbids.** So the renderer draws the four words and
    never an empty list, and that is the whole of what this step needs on this side. The steps drawn in the order the gate
    runs them (which is the gate's own sequence, not the head's), and the standings beside the
    **AND THE STEP IS LANDED — 2026-10-11**: the standings LINE (`merge-standings-line`: review/merging/parked, *nothing at all while nothing stands, all three with zeroes when something does, the four stopped states parked TOGETHER*) **and its WIRING**: the composer's bottom legend carries it while the queue stands and says nothing when it does not (`composer-wiring`), which is the reference's own rule that a marker always on is furniture — held by `the-queues-standings-are-drawn-only-while-something-stands`. **What remains in this box**: the daemon's own acts (approve/veto/rm — measured: they live in the reference's STORE, not on its wire) and the review queue as two views of one list. (the line below is the earlier, now-superseded statement)
    (`merge-standings-line`: three counts — review/merging/parked — with the reference's own rule,
    *nothing at all while nothing stands, all three with zeroes when something does, the four
    stopped states parked TOGETHER*), **but it is not yet DRAWN**: `composer-wiring` composes the
    alarm and the turn status on the bottom edge and knows nothing about it, so the wiring — and
    what it displaces when a completion is open — is what remains. A line nobody calls is the shape
    this session kept finding; said here rather than rediscovered.
    triangle the head already draws.
  · **M — the review queue as TWO VIEWS OF ONE LIST. THE SECOND VIEW'S SHAPE IS NOW MEASURED, so
    it is a small feature rather than a design question**: `Enter` on a queue row opens the entry's
    reviews and gate steps as an OVERLAY over the list, and the pattern to copy is this head's own
    `pane-enter` for the jobs pane (`pane-keys.lisp:145`): take `(nth (head-picker-sel head) …)`,
    open the overlay, set `head-mode`, and leave the list behind it so Esc returns to the chosen
    row. **AND NO FRAME GOES OUT** — unlike the jobs pane, whose overlay needs a `ReadJobOutput`,
    the reviews and gate steps are already on the entry (`MergeEntry.reviews`, `gate_steps`), so the
    view draws what the head holds. That is the whole of what remains here, and it is a
    `pane-enter` method plus an overlay: the two lists a pane must join (the pane arm's modes and
    **AND IT IS LANDED (2026-10-11)** — held by
    `enter-on-a-queue-row-opens-the-entry-in-full-and-esc-returns`: `pane-enter` on the queue sets
    `*merge-detail*` and the `:merge-detail` mode, and the view draws the entry's facts, its ask,
    its reviews (three facts kept apart) and its gate steps in the gate's own order; `pane-esc-target`
    is `:queue` so Esc lands on the row the reader chose, and **no frame goes out** — asserted by
    counting the wire before and after. An empty queue opens nothing. **So the queue's whole READ
    half is closed**; what remains on this box is the daemon's own acts.
    the overlay's own mode) are the traps already written down twice. AND THE REFERENCE'S QUEUE PANE IS A RANO
    WIDGET** — its own header says the pane comes from *`rano::agent::queue` from the queue and the
    reviews this head holds* (`ui/panes/queue.rs:2`), so the reference draws this list through
    rano, the same integration this tree deferred for `ctrl-e` and `!term`. **This head draws it
    itself instead** (the rows, the gate steps, the standings, the reviews), which is why the whole
    read half landed here without rano — and why the *two views* question is this head's to answer
    rather than a widget's to inherit. MEASURED 2026-10-11: the reviews are ON THE
    WIRE, one list per entry** — `MergeEntry.reviews: Vec<MergeReview>` (`protocol.rs:2400-2405`),
    additive with its own note: *an older peer reads past it and draws the queue without the
    reviews*. So *two views of one list* is a PANE question rather than a wire one: the same queue
    drawn whole, and one entry's reviews drawn as their own view — and the head already has the
    pattern (the job-output overlay is a second view of a row the list holds). **AND `MergeReview`'S FIELDS ARE READ, so nothing is left to
    guess** (`event.rs:516`): `entry_id`, `session_id` (*the session that reviewed it — the one a
    person attaches to when they want to read the argument rather than the verdict*), `branch`,
    `base_sha`, `asked_ms`, `answered_ms` (`None` while outstanding), `decision` (`accept`,
    `reject` or `needs_human`, or `None` for one that has not answered — `serde(default)`),
    `failure` (*the last attempt's failure, verbatim, or empty* — **and the daemon's own note says
    it must NOT be read as a decision: a reviewer whose turn failed reached no judgement, so
    `decision` is `None` and without this field the pane drew *asked and has not answered* over an
    attempt that had already died**), and `reasons` (*the reviewer's reasons, in its own words*).
    **AND THE REVIEWS ARE LANDED AND DRAWN (2026-10-11)**: `merge-review-line` keeps the three facts
    apart — a verdict with the reviewer's own reasons, nothing at all for *asked and has not
    answered*, and *review failed* in the failure's own words — and `merge-queue-lines` draws them
    under each entry, so the function is CALLED rather than dead (the shape this session kept
    finding). Held by `a-reviews-three-facts-are-not-one-rendering` and the queue renderer's own
    test. So the view has three facts to keep apart — a verdict, no verdict yet, and a review that DIED —
    which is the same three-way distinction the notes and the gate steps each turned on. And
    `/queue reset | clean | restart` — the verbs, each with the sentence that says what it did.
    **AND A SECOND MEASUREMENT, 2026-10-11**: the reference's TUI has NO `/queue` verb either —
    `queue` appears in no chord or key file, and its ONE reference is `driver.rs:737`, the
    `ListMergeQueue` ask. So the head-side surface for this queue, in the reference, is *the list
    and nothing else*: the approve/veto/rm acts belong to the DAEMON's own surface (its CLI or its
    other clients), and a head that invented them would be building an interface the other half
    does not answer. **The honest next step is therefore not code**: find where the acts live in
    the reference (the daemon's CLI, most likely) and only then decide what this head owes
    **AND THE THIRD MEASUREMENT FINDS THEM — 2026-10-11.** They are the STORE's, not a head's:
    `tokencore/src/store.rs` has `approve_entry(…)` and `veto_entry(entry_id, evidence, now_ms)`,
    with a test named *a veto parks the row and a remove forgets it* — so a REMOVE is a real
    deletion there, and a VETO parks the row with its evidence, which is the opposite of each
    other and both are the queue owner's acts. **And `MergeState` HAS SEVEN STATES, NOT FIVE**:
    `Waiting, Taken, Landed, Failed, Conflict, Stale, Vetoed`. This head's renderer maps five of
    them (`landed`, `failed`, `conflict`, `waiting`/`stale`) and draws anything else PLAIN — so
    `taken` and `vetoed` currently arrive in the pane with no colour at all. That is honest rather
    than wrong, and it is the next concrete thing to fix here: give those two their registers from
    the daemon's own semantics (a `taken` row is *in flight*, a `vetoed` one is *a person said
    no*) — **not** from a guess, and not before the events that carry them are watched on a live
    queue.