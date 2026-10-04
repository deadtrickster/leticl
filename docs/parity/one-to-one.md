# 1:1, made checkable — the replay instrument and the first run

**The operator's words:** *"i want our rendering to map letibot-tui 1-1."*

Until today that claim could only be checked by looking at two LIVE heads: two
processes, two scroll offsets, two fold states, two clocks, two moments. That is
not a controlled test, and one comparison in the last round was invalid for
exactly that reason. This file records the instrument that replaces it, and the
first measurement it took.

**Reference**: `~/Projects/letibot/letibot` @ `8af671e` (read-only), **where this was
measured; the pin is now `149edf9` (2026-10-04)**. `crates/tui/src/bin/letibot-tui.rs`,
`fn replay` (line 236) and `--no-tty` — **and that line is one of the citations the pin's
move broke**: the file is 11 lines now, with the TUI in `crates/tui/src/render.rs` and
`app.rs`, so this one needs re-pointing rather than renumbering (see TODO.md's pin
section).
**Subject**: this tree. **Taken**: 2026-09-20.

---

## The command

```sh
scripts/compare-1-1                       # every fixture
scripts/compare-1-1 markdown tool-long    # two of them
scripts/compare-1-1 --diff split          # both heads at the other fold
```

Exit 0 when every fixture is identical, 1 when any row differs, 2 when a head
could not be run. It needs `python3` and the two binaries and nothing else.

Under it:

```sh
letibot-tui --replay tests/fixtures/F.jsonl --no-tty     # the reference, 100x40
bin/leticl-head --replay tests/fixtures/F.jsonl --no-tty  # ours, --cols/--rows
```

Both fold a recorded event log with **no daemon, no socket and no model**, print
the screen at a fixed size, and exit. Rebuild the image with `sbcl --script
freeze.lisp`; without it `compare-1-1` falls back to `sbcl --script
scripts/leticl-replay.lisp`, which is the same entry point about ten seconds
slower.

`scripts/make-fixture --all` rebuilds the fixtures from
`~/.local/share/letibot/sessions.db` (copied first — it is the operator's, and a
`-wal` beside it means a daemon may be writing).

### Three things the instrument holds fixed, each because it did not at first

1. **The clock.** Folding a `turn_started` read a wall clock, so the composer's
   edge answered `· 0ms` on one run and `· 1ms` on the next.
   `--no-tty` now binds `*fixed-clock-ms*` to 0 for the whole fold and the whole
   frame (`src/progress.lisp`). The reference has the same property for free: its
   `now_ms` is never set under `--no-tty` and its `started_ms` comes off the
   envelope's `ts`, so its duration is `0.saturating_sub(ts)` every time.
2. **The prefs.** The two heads read *different* files —
   `$XDG_CONFIG_HOME/leticl/head.toml` and `…/letibot/head.toml`, deliberately —
   and on this box they disagreed: `diff = "split"` against `diff = "unified"`.
   The first run reported a two-panel diff card against a unified one as a
   rendering difference. `compare-1-1` now writes both files itself, identical,
   and points both heads at them; the values are printed in the header of every
   run.
3. **"Detached".** `alarmed-p` is `(or (alarm-counts head) (not (head-connected
   head)))`, so a socketless replay put a `⚠` on the bottom border of all nine
   fixtures — nine findings that were one fact about the instrument. The replay
   head is now `connected` with a NIL stream, which `%send` already refuses to
   write to.

### What is compared

**The rendered cell grid, not the byte stream.** leticl paints through a cell
buffer and emits one SGR per style *change*; letibot composes strings and closes
each span with a reset. On the same screen that is `\x1b[0;2m…` against
`\x1b[2m…\x1b[0m`, and a byte diff would call all forty rows different while the
terminal shows the same thing. So each row is decoded into (character, style)
cells — bold, dim, italic, underline, reverse, fg, bg — and the cells are what
must match. Trailing cells that are a space in the default style are dropped from
both sides.

Three numbers are printed per fixture:

- **cells** — rows identical position-for-position. This is the claim, and the
  exit code follows it.
- **struct** — rows matched after `difflib` alignment. One extra row at the top
  is then an insert rather than forty substitutions.
- **bytes** — rows identical escape-for-escape after the right margin is
  trimmed. Not the rendering claim; it is repaint volume, and it never fails the
  run.

---

## The fixtures

`tests/fixtures/*.jsonl`, one `letibot_sessionlog::event::Envelope` per line.
All but `hello` and `permission` are rows out of the operator's own store.
`head -n K` on any of them renders the state the session was in at event K, with
no timing to race.

| fixture | shape | source | envelopes |
|---|---|---|---|
| `hello` | the smallest possible turn: one prompt, one answer | hand-written | 8 |
| `prose` | a plain-prose answer, no markup, no calls | `s-1789390808604422623#t0` 0–2 | 17 |
| `markdown` | headings, a list, a GFM table, a fenced `sh` block, inline code, bold | `s-1789639478142928813#t9` 72–73 | 15 |
| `reasoning` | a long reasoning block in front of a markdown answer | `s-1789933554744912553#t0` 8–9 | 15 |
| `tool-short` | one `bash` call, six lines of payload | `s-1789639478142928813#t9` 69–71 | 20 |
| `tool-long` | one `read` call, 193 lines of payload | `s-1789639478142928813#t11` 1042–1044 | 20 |
| `edit-diff` | a file edit carrying both sides of a one-line replacement | `s-1789639478142928813#t11` 1040–1041 | 10 |
| `multi-round` | one turn, three rounds of calls | `s-1789933554744912553#t0` 0–9 | 48 |
| `user-cells` | a user message with a `/cells` screen dump in it, and a call still running | `s-1789462738453908838#t18` 899–901 | 19 |
| `permission` | a decision left OPEN — the card owns the keyboard | `adjudication`, newest asked `bash` row | 5 |

**The ordering is the point.** letibot's `docs/tui-testing.md`: the engine
invokes every call in a round *before* appending any of that round's result
rows, so a `ToolFinished` always precedes its own row's `TranscriptAppended`. A
fixture built the other way exercises a path the daemon never produces, and this
head reads that ordering to carry a call's duration onto its settled card. The
check is a test (`every-fixture-puts-a-tool-finished-before-its-own-row`) over
the committed files, not over the builder.

Three fields are **derived** rather than stored, and they are derived the same
way for both heads: a call's `target`, the digests, and a turn's
`usage`/`timings`. Everything else is the store's own: `created_at`, `tok_offset`,
`tok_len`, `h_k`, and the permission's sentences.

---

## The first run — 2026-09-20, 100x40, prefs `diff=unified thinking=folded tools=folded`

| fixture | cells | struct | bytes |
|---|---|---|---|
| `hello` | **35/40** | 37/40 | 32/40 |
| `prose` | **28/40** | 37/40 | 25/40 |
| `markdown` | **35/40** | 35/40 | 7/40 |
| `reasoning` | **34/40** | 34/40 | 7/40 |
| `tool-short` | **31/40** | 35/40 | 28/40 |
| `tool-long` | **31/40** | 36/40 | 28/40 |
| `edit-diff` | **28/40** | 33/40 | 25/40 |
| `multi-round` | **34/40** | 34/40 | 7/40 |
| `user-cells` | **29/40** | 33/40 | 26/40 |
| `permission` | **34/40** | 36/40 | 20/40 |

**0 of 10 identical.** 315 of 400 rows identical position-for-position, 350 of
400 after alignment.

**What is identical today, and it is most of the screen.** The composer box, its
top and bottom edges, the frame gutter, the body window, the blank rows, the
permission card in full (rows 5–38 of `permission` match cell for cell, ladder,
advice and all), the
user block's reverse-video padding and right-aligned stamp *field*, the folded
`▸ Thought` row's shape, the unified diff's line numbers, signs and
`48;5;52`/`48;5;22` backgrounds, the markdown body, the table rows, the fence
frame, and the turn status's `⠋ Responding · 0ms · 39 chars`.

---

## The worklist, ranked by how often the shape occurs in a real session

Nothing below was fixed. `src/cards.lisp`, `src/markdown.lisp`, `src/width.lisp`
and `src/cells.lisp` belong to another strand right now, and so do
`src/chrome.lisp` and `src/render.lisp`.

### 1. The hint bar opens with keys that change — every frame, all 10 fixtures

```
 lb:   ^[[2mctrl-s sessions · ctrl-p todos · ctrl-g subagents · ctrl-r thinking · ctrl-t tool output · ctrl…^[[0m
 lc:   ^[[0;2menter send · ctrl+c exit · ctrl-s sessions · ctrl-p todos · ctrl-g subagents · ctrl-r thinking · c^[[0m
```

and, with a decision open:

```
 lb:   ^[[2ma row number answers · ↑↓ then enter · or type an option · /help^[[0m
 lc:   ^[[0;2mesc interrupt · ctrl+c clear · a row number answers · ↑↓ then enter · or type an option · /help^[[0m
```

The reference deleted exactly this, and says why (`app.rs:5000`, `Editor::hint`):

> **The bar is one constant string.** It used to open with the keys that change —
> `enter send` idle, `esc interrupt` while a turn runs — and those are three
> different lengths in front of the same tail, so the line moved sideways
> whenever a turn started or the first character was typed.

Ours still has the shape the reference moved away from. It is the last row of
every frame in every state, so it is the most-seen difference in the tree.
`src/chrome.lisp`.

### 2. A user row's timestamp is an hour wrong under summer time — every prompt

```
 lb:   ^[[34m▌^[[0m ^[[7msay hello                                                                             15:00:08^[[0m
 lc:   ^[[0;34m▌^[[0m ^[[0;7msay hello                                                                             14:00:08^[[0m
```

`src/cards.lisp:1261`:

```lisp
(multiple-value-bind (s m h) (decode-universal-time (floor ts 1000))
```

`ts` is **Unix** milliseconds and `decode-universal-time` takes a **universal**
time (epoch 1900). The two epochs are 2 208 988 800 s apart — *exactly* 25 567
days — so the H:M:S survives and only the date is wrong, by seventy years, which
is why nothing caught it. But the local-time offset is then taken for that wrong
date: `2026-09-14` is CEST (+2) and `1956-09-14` is CET (+1), because Germany had
no summer time in 1956. So the stamp is right in winter and an hour early in
summer. The reference uses `localtime_r` on the real seconds (`app.rs:9053`).
The fix is `(+ (floor ts 1000) 2208988800)`, and the docstring above it — which
already records one timezone bug found this way — should record this one.

### 3. A tool card's duration — every call, in both directions

```
 lb:     ^[[2m▸^[[0m^[[2m Ran ^[[0m"echo …"^[[2m · ok^[[0m^[[2m · 2.7s^[[0m^[[2m · 6 lines^[[0m
 lc:     ^[[0;2m▸ Ran ^[[0m"echo …"^[[0;2m · ok · 6 lines^[[0m
```

The two heads take this number from different places. The reference stamps a
call with the **envelope's `ts`** (`app.rs:2364`, `c.started_ms = ts`); ours
measures it on the **head's own clock** (`note-call-started`, `src/cards.lisp`).
Under a frozen replay clock ours is 0 and the field disappears; live, both show a
number and they are different numbers — ours is "how long this head watched",
the reference's is "how long it took". The same split is behind `▸ Thought for
0ms` (reference) against `▸ Thought` (ours). Reading the `ts` is also what makes
a replayed card honest, which is the case the reference's `Phase::Replayed`
exists for.

### 4. Inline code is split from the punctuation after it when wrapping — every markdown answer

```
 lb:   ^[[2m· ^[[0m^[[36mwidepfn5^[[0m scored worse than ^[[36mwidepfn2^[[0m (Brier 0.24 vs 0.16, AUC 0.58 vs 0.90 with
 lc:   ^[[0;2m· ^[[0;36mwidepfn5^[[0m scored worse than …0.90 with ^[[0;36m--drop-constant^[[0m
 lb:     ^[[36m--drop-constant^[[0m). The 3x2 rescoring grid has blank widepfn2/widepfn4 rows — the scorer broke
 lc:     ). The 3x2 rescoring grid has blank widepfn2/widepfn4 rows — the scorer broke on older
```

The source is `` `--drop-constant`). ``. The reference treats the code span and
the `).` after it as one wrap token and moves the whole thing down; ours breaks
between them and starts the next line with a bare `)`. Every line below it is
then offset, which is why `reasoning` and `multi-round` lose four rows each to
one wrap decision. `src/markdown.lisp` / `src/width.lisp`.

**FIXED by the one-rule merge**, and not by touching this file: the wrapper used to
split each SEGMENT into words, so the inline-code span `--drop-constant` and the
plain `).` after it were two tokens however they sat in the text. Now the rule sees
one text and one token, exactly as the reference does, and the rows match its
(`--drop-constant). The 3x2 rescoring grid …`). The fixture dumps move on four rows
of `markdown` and four of `prose`, and on nothing else in the eleven — which is the
measurement that this is the same defect the reference's own comment describes.

### 5. A folded payload's legend loses the word `pages` — every folded tool card

```
 lb:     ^[[2m  … +192 lines · ctrl-t pages^[[0m
 lc:     ^[[0;2m  … +192 lines · ctrl-t^[[0m
```

Same on `tool-short` (`… +5 lines`). `ctrl-t` alone reads as a toggle; the
reference's word says the key *pages* through a payload too big for one screen.
`src/cards.lisp`.

### 6. A call that has not finished is reported as finished — every running turn

```
 lb:     ^[[33m◐^[[0m ^[[1mRunning^[[0m cd /home/dead/Projects/letibot/letibot && sqlite3 …
 lc:     ^[[0;2m  → Ran^[[0m "cd /home/dead/Projects/letibot/letibot && sqlite3 …
```

and, for a call that is only *proposed* (waiting on a permission):

```
 lb:     ^[[2m○^[[0m ^[[1mRunning^[[0m rustup target list --installed 2>/dev/null; echo "--- rustc ---"; rustc --version
 lc:     ^[[0;2m○^[[0m ^[[0;1mRan^[[0m rustup target list --installed 2>/dev/null; echo "--- rustc ---"; rustc --version
```

Three differences in one row: the **verb** (`Running` against `Ran` — ours says
a call finished when it has not), the **glyph** for a started call (`◐` yellow
against `→` dim; the *proposed* glyph `○` already matches), and the **weight**
(the reference paints the verb bold and the target plain; ours paints the whole
prefix dim). `src/cards.lisp`.

### 7. The live reasoning quote is not drawn at all — every turn that thinks

```
 lb:     ^[[2m┃^[[0m^[[2;3m Let me go.^[[0m
 lc:     (nothing)
```

While a turn runs the reference shows the tail of the reasoning as a one-line
quote under the folded `▸ Thought` row. Ours shows the fold and nothing else, so
a long silent think looks the same as a stalled one.

### 8. The edit card's path moves off the title onto a row of its own

```
 lb:     ^[[2m▸^[[0m^[[2m Edited ^[[0mPARITY.md "| `ctrl-q` | jobs pane | …"^[[2m · ok^[[0m^[[2m · 3.8s^[[0m^[[2m · 10 lines^[[0m
 lc:     ^[[0;2m▸ Edited ^[[0m"| `ctrl-q` | jobs pane | …"^[[0;2m · ok · 10 lines^[[0m
 lc:       ^[[0;1;36m  PARITY.md^[[0m
```

The reference puts the file being edited where the eye lands — immediately after
the verb — and uses the remaining width for the argument. Ours leads with the
argument and spends a whole row on the path in bold cyan. One row per edit card,
and an edit card is the most common card in a working session.

### 9. The elided-diff-row count is off by one

```
 lb:     ^[[2m  … +2 diff rows · ctrl-t^[[0m
 lc:     ^[[0;2m  … +3 diff rows · ctrl-t^[[0m
```

Same excerpt, same eight rows drawn above it, different remainder. One of the
two is counting a row the other does not.

### 10. Syntax highlighting uses the bright palette

```
 lb:   ^[[2m│ ^[[0m^[[34mcd^[[0m /home/dead/Projects/leticl
 lc:   ^[[0;2m│ ^[[0;96mcd^[[0m /home/dead/Projects/leticl
 lb:   ^[[2m│ ^[[0m^[[33mLETIBOT_SOCKET^[[0m=… ^[[34msbcl^[[0m ^[[33m--script^[[0m run.lisp head
 lc:   ^[[0;2m│ ^[[0;93mLETIBOT_SOCKET^[[0m=… ^[[0;96msbcl^[[0m ^[[0;93m--script^[[0m run.lisp head
```

Ours maps the shim's roles to 96/93 (bright cyan, bright yellow) where the
reference uses 34/33 (blue, yellow). Every fenced block in every answer.
`src/highlight.lisp` roles → `src/cells.lisp` palette.

### 11. A fence's language label is not normalised

```
 lb:   ^[[2m┌─ bash^[[0m
 lc:   ^[[0;2m┌─ sh^[[0m
```

The source says ` ```sh `. The reference resolves the alias to the language it
highlights with and labels the box with that; ours prints what was written.

### 12. A `/cells` screen dump is rendered instead of folded

```
 lb:   ^[[34m▌^[[0m ^[[7mawful                                                                                 10:38:13^[[0m
 lb:   ^[[34m▌^[[0m ^[[7m· 63 rows of this screen (210x63) went with this message                                      ^[[0m
 lc:   ^[[0;34m▌^[[0m ^[[0;7mawful⟦screen 210x63 — my terminal exactly as this head drew it, ANSI escape codes     09:38:13^[[0m
 lc:   ^[[0;34m▌^[[0m ^[[0;7mincluded, so what you are reading IS the rendering and not a description of it⟧ …             ^[[0m
```

The reference's `fold_cells` replaces the whole `⟦screen …⟧` block with one line
saying how much went with the message; ours wraps the marker text into the user
block. On this operator's sessions a `/cells` paste is common, and when the
screen is 63 rows the difference is the difference between a two-row message and
a message that fills the frame.

### 13. A folded reasoning row's line count differs

`· 1 line` against `· 2 lines`, `· 398 lines` against `· 401 lines`. The two
heads count the lines of the same text differently — most likely a trailing
newline and the blank lines between paragraphs.

### 14. A card title truncates the argument at a different width

```
 lb:     ▸ Ran "echo \"=== 42ce ===\"; cat /run/user/1000/letibot/42ce9f1aae08.j…
 lc:     ▸ Ran "echo \"=== 42ce ===\"; cat /run/user/1000/letibot/42ce9f1aae08.json; ec…
```

Ours keeps ~14 more columns. The reference reserves the width its trailing
fields (`· ok · 2.7s · 6 lines`) will need; ours reserves the width of the
shorter set it draws.

### 15. One dim space in the diff gutter

`^[[2m        ^[[0m ` (8 dim, 1 default) against `^[[0;2m         ` (9 dim). Same
text, different style on the ninth column of a continued diff row.

---

## Not a rendering difference — two notes on the instrument

**The header row.** Under `--replay` the reference draws **no** header, ever: it
gates it on `h >= 6 && !self.session_id.is_empty()` (`app.rs:5231`) and a replay
has no `Hello` to learn a session id from. Ours takes only the height half, on
purpose — `src/render.lisp:437` says so, and gives the reason: `click-row->sel`
(`src/editor.lisp:213`) converts a click with `(- row 1)`, so the pane's origin
is written down in a second file and moving one of the two would put every click
in a pane one row out.

Live, both heads have a session id and both draw a header, so **this difference
does not exist on the operator's screen**. Under replay it costs a row at the
top and shifts the whole body down one, which is the whole gap between the
`cells` and `struct` columns above. It was left alone rather than routed around:
the clause belongs with the click arithmetic, and whoever owns `render.lisp` and
`editor.lisp` together should take the other half of the gate — after which this
instrument gets about 50 rows sharper.

**The escape form.** `bytes` is 7/40 on a full body and 32/40 on a nearly empty
one, and none of it is visible. Two structural reasons: ours opens every row with
`ESC[0m` and pads to the right margin where the reference stops at its last
glyph, and ours spells an attribute as `ESC[0;2m` (reset then set) where the
reference spells it `ESC[2m`. On a full repaint that is roughly 4 extra bytes per
style run plus the margin, which is a repaint-volume question and not a 1:1 one.
Recorded here so it is not re-found as a rendering fault.

---

## One thing was fixed, because it was a crash and not a difference

`scripts/compare-1-1` could not run `edit-diff` at all: the head exited.

```
leticl: The value "PARITY.md" is not of type SIMPLE-STRING when binding STRING
0: (SB-ALIEN::STRING-TO-C-STRING "PARITY.md" :UTF-8)
1: (LETICL::%HL-DETECT "PARITY.md")
2: (LETICL:EDIT-SPLIT-LINES (:PATH "PARITY.md" …) 92)
```

`lang-for` handed a yason-decoded path straight to an alien `c-string`, which
binds its argument as a `simple-string`; a string out of the JSON parser is the
adjustable buffer the parser filled. Every path a head renders an edit card for
arrives that way, and it is a MAIN-thread error, so with `--disable-debugger` it
is not a wrong card — it is a head that exits. `src/highlight.lisp` now coerces.

Nothing in this tree had ever fed a real `ToolEditExcerpt` to the card before
there were fixtures. That is the argument for the fixtures.

---

## The net under it

`tests/replay.lisp`, 100 checks inside `sbcl --script run.lisp test` (1446 →
1546, 100%):

- a replay answers exactly the frame it was asked for, at two sizes;
- **the same file gives the same rows twice in one image** — the whole `--no-tty`
  contract, and the reason `with-replay-globals` resets every global a frame
  reads rather than trusting a fresh process;
- a blank line is skipped and a malformed line dropped, the way the reference
  drops it, so neither head is quietly fed a different file;
- `hello` renders the screen it has always rendered — the visible text of the
  body, not the escapes, because the styles are what the other strand is moving;
- every committed fixture puts a `tool_finished` before its own row;
- every committed fixture folds and paints with no render error left behind.
