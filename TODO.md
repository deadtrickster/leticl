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

- [~] **cards + markdown + width** — `cards/*.lisp`, `markdown.lisp`, `width.lisp`,
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
  - [ ] **the count labels on the composer's edge are BUTTONS** (`9ac7dad`) —
    a click on `1 subagent running` opens the subagents pane, `1 job running`
    the jobs pane. This head already converts clicks for panes and rows; this
    is the edge's own hit test.
  - [ ] **a settling diff card is handed over on the row's body, not its
    announcement** (`98a8f11`, the settle-flicker merge: a call is in one half
    or the other, never neither, so a settling card's frames are identical).
  - [ ] **a click on an edit opens its change in a popup** (`88b003d`): the
    whole file, no editor chrome; and **the popup's scroll repaints its rows,
    not the whole screen** (`6fb34d4`).
  - [ ] **a redirected job's window is the file, even when a preamble reached
    the capture** (`d234194`) — the jobs pane's tail.
  - [ ] **`ctrl-e`: a real editor pane** (`a8f5e83`, `e38b82e`, `8e91a4b`,
    `88b003d`) — ctrl-e puts the editor away and brings it back with its files
    kept; on an empty prompt it opens on any file; and the pane wears the
    head's frame rather than nano's. This is the `!term` project's sibling and
    the same rectangle contract applies.
  - [ ] **standing notes: the agent writes the notes it already reads**
    (`1c9f3a4`, `35670ee`, `1be706b`) — a tool, so the wire is the tool table;
    the head's notes pane is the surface, and every read must say the notes are
    historical. Delivery moved to session open and every base rebuild, and
    nowhere else.
  - [ ] **a refused request compacts: the wall classified** (`03f0277`,
    `08faf55`, `8590f2c`, `7eceda7`) — a provider's context-length refusal IS
    the wall; the guard stands down the pre-emptive door only and survives the
    restart; both automatic doors take the pre-turn check.
  - [ ] **a model change during a retrying turn takes** (`12ade5e`) — daemon,
    but the head's `/model` surface should say the turn continues.

- [ ] **the reference's second 116-commit batch (2026-10-09, protocols 38–42)** — the wire
  core is ported (`c2a5605`'s successor: 42's todo author and `cancelled`, 40's
  `TranscriptForked` drop, the exit id on stdout, `prefix_stale`); what remains is head-side:

  - [ ] **the standing-notes pane** (`ccee82a`, protocol 39): `ClientFrame::ListNotes` →
    `ServerFrame::StandingNotes` carrying `NoteEntry` — one row per note, and the form the
    budget gave each. Two frames, so this is the one item here that adds wire. The reference's
    pane draws it and Enter opens the note in rano (`81749c9`).
  - [ ] **the carry by the row's own words** (`53ac610`, `7b18b1d`): on a live re-seat a fork
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
  - [ ] **the head's smaller mirrors**: a printed path is a link (`5b3843f`), a change detected
    after a command draws its diff (`e09d77c`), a job named in every sentence about it
    (`29f2422`, `5d3bfac`), `allow-all`'s answer surviving a restart (`9f09f04`), the stop
    that interrupts the turns it holds (`195a813`), and the term pane born at its size
    (`401e61f`).


## Filed for their own sessions — the `!term` pane, and the merge queue

Both were measured against the reference's current tree before filing, so the next
session starts from facts and not from a summary's memory. Neither is parity debt:
the wire half of each is additive (protocol 31+ frames; leticl is 36) and nothing a
head runs today breaks without them.

- [ ] **the `!term` pane + a VT renderer** — a program that owns the conversation's
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

- [ ] **the merge queue pane** — the queue is DAEMON-LEVEL, not the session's: the
  snapshot carries none of it by design, and a head that wants the queue asks with
  `ListMergeQueue` and is answered by `MergeQueue` (the whole queue as of now);
  from then on `MergeEntryAdded {entry}` and `MergeEntryMoved {id, state, evidence}`
  carry every change — a head that attaches late and does not ask draws nothing,
  which is the same bootstrap rule `/todos` already keeps. `MergeEntry`: id,
  branch, priority, `needs`, state, evidence — and **the evidence is the reason for
  the state in the queue's own words** (the unmet dependencies while Waiting, the
  gate's failure while Failed, the conflict while Conflict, the dead job while
  Stale, the landed tip while Landed): a move without its reason is a row the pane
  draws and the operator cannot read. States: Waiting / Taken / Landed / Failed /
  Conflict / Stale. The reference's pane is `ui/panes/queue.rs` (129 lines — the
  SMALL pane of the two projects). The warning codes `merge_queued` and
  `merge_not_queued` are already ported with remedies; this pane is where their
  rows point. Leticl needs: `make-list-merge-queue`, the `merge_queue` frame arm,
  the two event arms in `apply-event`, a `:queue` pane (grouped by state, the
  evidence under the row), and the pane's own cursor/stops plumbing — the pattern
  every existing pane already keeps.

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

- [x] **a pane's Enter belongs to the pane — landed, and the `empty` gate is gone.** `8aa347e`.
  (from letibot — `ee33732`; **no `T`-number, yours to number**, but it goes first
  because it is a keystroke loss the operator has already hit once on the other head).

  **Measured on your side, not inferred**: `src/editor.lisp:1382` is

      ((:enter) (when empty (%pane-enter head)) empty)

  with `empty` the composer's buffer at zero (`:1251`). So on every screen that HAS an
  Enter act — `:config`, `:subagents`, `:peek`, `:jobs`, `:job-out`, `:dash` — and on
  the screens with no act at all, **one character in the composer turns the pane's own
  advertised key into `submit`**: `%pane-enter` is never called, the key falls through
  the ladder, and the half-written line is sent to the session. The pane does nothing
  and nothing on the screen says why. That is the operator's report from the jobs pane
  on the reference head, 2026-10-03 — *"i went to jobs pane and hit enter"*, and what
  reached the model was a stray `\` — and their ruling is the whole of the fix:
  *"the pane own keyboard in a way, so enter is a pane thing."*

  **The rule, and it is narrower than *the composer is dead***: **Enter in a pane is the
  pane's, unconditionally.** The words are **held, never eaten** — a pane that consumes
  the half-written line to keep the key trades one silent loss for another, so
  `%pane-enter` must leave the buffer exactly as it was, whatever the pane's act is.

  **Three things must NOT be swept into it**, and each is in the reference for a reason:

  · **the cursor keys keep the gate.** `:left`/`:right` on `:job-out` (`:1352`) is
    already right and must stay as it is: a cursor key is the composer's first, and a
    half-typed line keeps its motion (letibot `app.rs:5963`).
  · **the screens where a typed line IS the answer keep it**: `:todos` (with its `:tab`
    unfold at `:1368`) and `:picker` — a row number, a prefix, a name is what the reader
    is typing and `submit` routes it. The reference gates exactly those, with the same
    condition (`app.rs:6493`, which is also where Tab and Enter are one arm and not the
    pane's). This file's line 8 states the rule as *Enter and the digits*; **the digits
    half stands** (`app.rs:6283`) — **this amends the Enter half only, and line 8 is
    amended in the same commit**, because it is the rule as stated and it is the
    sentence being overturned.
  · **and one arm must close Enter for the screens whose block never runs over an empty
    list** — the jobs list and the subagent tree over no rows, plus `help`, `stats` and
    the slash listing, which have no Enter act at all. Without it, Enter in an EMPTY
    jobs pane is still a submit: the same defect with one row fewer on the screen
    (letibot `app.rs:6697`).

  **What "done" is**: on the live head, with a character in the composer — Enter on a
  jobs row opens that job's output, on a subagent row reads it, on `:config` changes the
  row, on `:peek` re-reads it, on `:dash` opens the panel under the cursor — **and the
  character is still in the composer afterwards**; Enter on an empty jobs pane submits
  nothing; and Enter in `:todos` with a line typed is still the line's. The suite half is
  the PAIR of assertions, because either alone passes on the broken code: that the pane's
  act happened, and that the words survived. The reference's test is
  `a_panes_enter_is_the_panes_even_with_words_in_the_composer` (`app.rs:39303`), and it
  was verified fail-first by restoring the guard on the jobs arm — which is how the
  reference found that **no test had ever asserted the old behaviour**, and that a
  keystroke aimed at a pane came to be sent to a model for a day.

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
- [x] **T2 · the launcher** — MEASURED 2026-10-11, and BOTH CLAUSES ARE ALREADY MET; the row was
  written from the intention rather than from the files:

  · **`~/bin/letibot`'s exec sites all go through `$HEAD`** — `HEAD="${LETIBOT_HEAD:-$BIN/letibot-tui}"`
    (line 95) and FIVE `exec "$HEAD" --socket "$SOCKET" --identity ...` sites (1605, 1902, 1960,
    1964, 1967), so `LETIBOT_HEAD` reaches every one of them. The row's *four remaining* sites
    were fixed before it was written.
  · **`~/bin/leticl` IS `scripts/leticl`** — `cmp` says byte-identical, and `scripts/leticl` is
    the complete launcher: it seats leticode (`LETIBOT_ROLE`, `LETIBOT_MODE=automode-edits`, the
    shell and `web_fetch` on), exports `LETIBOT_HEAD="$LETICL_HOME/scripts/leticl-head"` and
    `exec letibot`. So `leticl` in a folder with no daemon STARTS one — the refusal the row
    describes cannot happen with this pair in place.

  **What is still worth doing, and it is the operator's file rather than mine**: `~/bin/leticl` is
  a COPY. A change to `scripts/leticl` in this repo does not reach it until somebody copies it
  again — which is exactly the drift the script's own header records (*"a second copy of
  letibot's launcher that had already drifted from it"*). A symlink would end it:
  `ln -sf /home/dead/Projects/leticl/scripts/leticl ~/bin/leticl`.
- [x] **T3 · `--replay FILE.jsonl`** (`panes.md` G18) — DONE (2026-10-11): the replay itself
  was already in place (`--replay FILE [--no-tty] [--cols N] [--rows N]`, `src/replay.lisp`, a
  fixture per scenario and a walk over all of them), and **`-n K` — the half that makes a screen
  ADDRESSABLE — is now landed too**: fold only the first K envelopes, so the frame is the state the
  head was in at event K, exactly `head -n K` on the file.

  MEASURED through the frozen image on a committed fixture: `-n 2` and the whole file render
  DIFFERENT screens (7 rows differ on a 90x12 frame — at event 2 the head has just attached and
  said nothing, at the end it has the tool call and its counts), so the limit is a parameter that
  is really read rather than one the CLI accepts and drops. `a-replay-can-be-stopped-at-event-k`
  holds the three envelope cases apart (inside the file, past its end, and no limit) plus that pair
  of screens.

  What it buys is the item's own sentence: a screen test can now address a MOMENT, and a screen
  that changed can be bisected by event number rather than by guesswork about which row drew it.
- [x] **T4 · `--resume ID`** (`panes.md` G9). `scripts/leticl-head` rewrites it
  to `--session`, which cannot work for a session the daemon does not hold
  (app.rs:1602-1610). Size M. **Landed 2026-10-11**: the image has a `--resume`
  arm of its own, the launcher passes the flag THROUGH instead of rewriting it, and
  the ask is held in `*pending-resume*` until the first Hello delivers the daemon's
  list — consumed through `%switch-to`, the same path the picker uses, so the CLI
  and the picker cannot disagree about which frame brings a session in (a live row
  switches, a stored one resumes, and the session you are already on sends nothing).
- [x] **T5 · the ordering of the ladders** — with the session picker open and an
  ask arriving, ↑↓ moved the picker; the reference puts the decision ladder above
  the picker (re-measured on the pin below: the ladder is app.rs:3609 and the
  session picker :3643 — the `3474`/`3508` this row used to carry were a lineref
  that moved). Landed in `6b87351`, with the overlays that keep the arrows under an
  ask — `:peek`, `:job-out`, `:config` — written down on both sides of it. Size S.
- [x] **T6 · `Todos` and `Jobs` replies ignore their `session_id`**, so a reply
  for a session this head has left is applied to the one it is on. One `equal`
  each in `%handle-frame`. Size S. **Landed 2026-10-11** in `%frame-for-another-session-p`
  (one predicate, both arms), with `a-reply-for-a-session-this-head-left-is-not-applied`
  holding the three cases apart: another session's reply is not taken, its own is, and
  EMPTY on either side means *cannot tell* rather than *not mine* — a head that refused
  then would draw an empty pane on every attach, which is the same defect inverted.
- [x] **T7 · the render instrumentation, not the cache** — THE COUNTER AND ITS BOUND ARE IN
  (2026-10-11, the *first* half this item asks for). `*item-lines-renders*` counts the work where
  the work happens (`%item-lines-render`, not `item-lines` — a memo HIT is a `gethash` and the
  number that was 44-296 is the renders), `*item-lines-renders-this-frame*`/`-last-frame*` are read
  at the frame boundary by `%render-and-paint`, and
  `a-steady-frame-does-not-re-render-the-transcript` holds the bound: a COLD frame over 120 rows
  renders them, a STEADY frame renders at most TWO, and a frame after a row arrived renders the row
  and not the transcript.

  **The instrument earned its place immediately**: the first version published the count at the
  START of the next paint, so a test asking *what did the frame I just drew cost* got the one before
  it — measured, and the same mistake would have made the bound read as a defect in the memo.

  **The rest of the item stays open on purpose**: `rendering.md` argues against porting
  `hist_lines`, and that argument has not changed. The reference renders
  zero rows on a steady frame; we rebuild the window every frame (0.46 ms at
  210×63). `rendering.md` argues against porting `hist_lines` — its invalidation
  key would have to include five defvars any eval can change, and a screen cache
  is a second source of truth in a head whose contract is that redefining a
  renderer changes the next frame. Port the counter and a test that bounds
  `item-lines` calls per frame first. Size M.
- [x] **T8 · the rest of `docs/parity/`** — every finding not claimed above, each
  already carrying its citation, its size and its assertion. Work them by size
  within a strand's files, never across. **DONE 2026-10-11, and it was not the work the
  row expected**: working these strands found that the findings were almost all CLOSED
  already, so what was left was the recording — twenty-two of them in `rendering.md`,
  twelve in `panes.md`, twenty-two in `keys.md`, each now paired with the TEST that keeps
  it shut (struck through in the first two, a table in `keys.md`), plus `one-to-one.md`
  which had marked its own state and `wire.md` whose per-section tables carry verdicts.

  **Three claims of mine were caught doing exactly that** on the way: a test name cited
  for a fix that had a different test (`degrade-rather-than-refuse`), a payload-window
  test I invented, and a first pass at the reconciliation in which *the whole point of
  the exercise* — that a reader must be able to CHECK — was what was broken. Every line
  of the tables was verified against `def-test` in the suite rather than written from
  memory, which is the only reason they are worth reading.

  **STARTED 2026-10-11, and the first finding is about the METHOD rather than about the code**:
  the two strands' headline lists had gone stale in the same direction — `rendering.md`'s
  *Where they are not* (ten items) and `panes.md`'s *What would stop the operator switching
  today* (twelve) were EVERY ONE of them closed, so a reader was being sent to verify
  twenty-two things that were already true. A doc that over-claims work is a doc nobody can
  use, and the fix is the convention the docs already keep: struck through, each naming the
  TEST or the site that holds it. Both are reconciled now, and one claim of mine was caught
  doing it — a test name cited for a fix that had a different test.

  **What is left**: the per-section tables under each list (the `G`-numbered findings in
  `panes.md`/`keys.md`, the §-numbered ones in `rendering.md`/`wire.md`), worked by size
  within a strand as this row says.

## Found while working, and not fixed

- [ ] **THE EVAL SOCKET CAN WEDGE THE HEAD PERMANENTLY, and it happened on 2026-10-11 at 02:04.**
  The operator's head answered every `tui-eval` with the pusher's own verdict —
  *"a previous eval that took the paint lock and then blocked on the session socket leaves every
  later one waiting in `with-mutex` for ever. NOTHING YOU PUSHED SINCE THEN HAS LANDED … the head
  must be restarted"*. MEASURED: `(:pid 259603)` alive, `(+ 1 2)` timing out, while the other head
  on the box answered in 0 ms.

  **The trigger is not established** and that is why this is filed rather than fixed: the last
  thing done to that head was two `--tree` pushes in quick succession (the first printed nothing,
  the second timed out), so the shape is *a tree push that takes the paint lock and then blocks
  writing to the session socket* — the same class `hack.lisp`'s own wedge note records, from the
  other direction (`%send` called off the main thread). What IS established: the head cannot
  recover, nothing on its screen says why, and the only cure is a restart — which costs nothing
  now that `bin/leticl-head` is current and a head resumes from the store, but it costs the
  session's screen if the operator has not been told.

  **Worth doing**: make the pusher hold the paint lock for the LOAD only and never across a
  `%send`; give `with-mutex` a deadline with a sentence (*"the head is busy in an eval"*) rather
  than a silent wait; and have the pusher say which pid wedged rather than that the tree did not
  land.

  **TWO OF THE THREE ARE ALREADY IN, MEASURED 2026-10-11.** The paint lock HAS a deadline
  (`+hack-lock-timeout+`, five seconds, `%with-paint-lock`) — it predates this wedge, added after
  the same shape on 2026-09-24, and it is why the pusher could say *the channel is blocked* instead
  of hanging: the eval surface survives even though the process cannot. And the pusher does name
  the pid (`--list`/`--pid`, used here to find 259603 wedged while the box's other head answered in
  0 ms). What is NOT in is the lock being held across a `%send`.

  **AND `:timeout` ON THE SOCKET STREAM DOES NOT FIX THE BLOCKING WRITE — MEASURED, so nobody
  spends the hour again.** The remedy that looks obvious is `sb-bsd-sockets:socket-make-stream
  ... :timeout N` on the daemon socket, and it does not do it: a probe with a peer that never reads
  wrote 20 000 × 200-byte strings through a stream made with `:timeout 1` and was still blocked a
  MINUTE later (the probe had to be killed). So the deadline is not available as a stream keyword on
  this SBCL for a blocking `write(2)` on a Unix socket, and the real fix has to be one of: put the fd
  in non-blocking mode and drive the write from a loop that handles `EAGAIN` (`O_NONBLOCK` +
  `sb-unix:unix-write`, which is a change to the stream layer and wants its own test), or give the
  head a WRITER THREAD with a queue so the main loop never blocks on the fd at all. The second is
  what the reference does.

Each of these is a DIVERGENCE FROM THE REFERENCE that is currently invisible on the
screen, so none of them is worth a commit of its own. They are written down here
because an invisible divergence is exactly what this repo has been bitten by (the
`endp-open` that promised a cursor reset and was `(declare (ignore …))`).

**All three of the items below are now RECORDED AT THEIR SITES in the code** (2026-10-11), which
is what each of them asks for — a note and not a change. `asked-ts`'s note is at the fold that
stores it (`seq-gap.lisp`), the decision list's is at the slot (`session/state.lisp`), and the
quit card's is at the arm that takes the key (`editor/dispatch.lisp`), including what to change
FIRST if it is ever made to fall through.

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
