# leticl ↔ letibot: feature parity assessment

What the Rust TUI head (`crates/tui`, `crates/ui`) does that the Lisp head
(`src/`) does not, measured rather than recalled. This is an input to planning:
`PLAN.md` says what leticl is for, `TODO.md` says what is tracked, and this says
what is actually missing.

**Measured against `letibot` @ `756441720c7b53d39eca045185ed9b4168d09cc1`
(2026-09-20), from `leticl` @ `074bbf6`.**

**Screen comparison rounds** (`scripts/compare-heads`, both heads on the same
session, 210×63, escapes included) are pinned separately, because they measure
the screen rather than the surface:

| round | letibot | leticl | result |
|---|---|---|---|
| 3 | `e9ee3c4` (2026-09-20) | `1be0293` | 60 of 63 rows byte-identical; the rest self-measured numbers |
| 4 | `2deceb8` (2026-09-20) | `5a52ae2` | every pane row-identical but for each head's own numbers — see §8 |

An earlier pass measured `82ff650e` (2026-09-19); §7 is what the 19 commits
between the two changed, and the gaps it added are `P41`–`P46` in `TODO.md`.
Everything cited in §1–§6 that predates that pass still holds unless §7 says
otherwise.

Every line number below is a line in **that** reference commit. The reference is
a live repo, so:

```sh
git -C ~/Projects/letibot/letibot log --oneline 82ff650..HEAD   # has it moved?
```

If the tree has moved, **re-read the function before trusting the number** — a
citation is a pointer, not a specification. Re-measure this document rather than
patching numbers; the counts in §1 and the line counts in §3.9 are the parts that
go stale silently.

## Method, and what the numbers mean

Two reference surfaces, both the reference head's own:

- **`help_lines()`** — `crates/tui/src/app.rs:6543`. The head's own list of what
  it answers to. This is the operator-facing truth: if it is not here, it is not
  a feature anybody knows they have.
- **`struct App`** — `crates/tui/src/app.rs:499-874`. Its fields *are* its
  features; a pane has a flag, a cache has a map, a mode has a cursor.
- Plus `SLASH_COMMANDS` (`app.rs:936`), `enum Action` (`app.rs:88`),
  `enum Key` (`app.rs:160`), and `ClientFrame`/`ServerFrame`
  (`crates/sessionlog/src/protocol.rs`).

leticl's side: `*slash-commands*` (`src/render.lisp:269`), `%handle-key` and the
key ladder (`src/head.lisp:328-473`), `src/keys.lisp`, and every `%send` site in
`src/head.lisp` (the frames it can actually emit).

**Line counts are for shape, not effort.** Rust is verbose and Lisp is dense; the
reference is ~23,000 Rust lines (`tui` 16,993 + `ui` 6,117) and leticl is 3,708
Lisp lines. The useful ratio is *not* 6:1 — a conditional in Lisp costs a line
what a conditional in Rust costs four. Read them as "this is how much surface
exists", which is the question being asked.

Sizes below: **S** ≈ an afternoon, **M** ≈ a focused day, **L** ≈ several days or
a design question, **XL** ≈ a subsystem.

---

## 1. The short version

**leticl is a *working* head and letibot is a *furnished* one.**

The `M1–M4` spine is real and exercised: attach, hello/snapshot, the event fold,
resync and reconnect, the cell buffer and diff painter, transcript rendering,
markdown, chrome, composer, decision and question cards, the session picker,
todos/subagents/jobs/peek/help/status/config screens, prompt/interrupt/compact/
reseat, the eval socket with the render gate, and now a frozen launcher.

What is missing is not the protocol and not the renderer — it is the
**operator's side of the desk**: the editor that makes a prompt writable, the
panes that make state visible, the cards that keep a tool call's evidence after
the call is over, the persisted preferences, and the commands that reach the
environment (`/models`, `/gate`, `/flowy`, …).

Two numbers make it concrete. Of the reference's **28 key bindings**, leticl
answers **14**. Of its **24 slash commands**, leticl answers **16**, and all
**eight** it does not — `/verbosity`, `/models`, `/default-model`, `/job`,
`/resync`, `/gate`, `/supervise`, `/flowy` — are absent features rather than
missing bindings.

And the first finding is not a missing feature at all: **the head never sends an
`Ack`** (§2.1).

**§7 is newer than the rest**: 19 commits landed on the reference after the first
pass, adding six things this head does not have (P41–P46) — pane scrolling, a
rewritten todos pane, a money meter, the settings-on-attach bug, `deny_and_tell`'s
note, and the refusal-dedup. Read it alongside §1–§3.

---

## 2. Correctness found while comparing

These are not parity items. They are things that are wrong or dead, found by
looking for what the reference sends and leticl does not.

### 2.1 The head never acks — the read mark never advances

`make-ack` is defined (`src/protocol.lisp:80`) and `ack-frame` exists
(`src/session.lisp:304`), and **neither is called from `src/head.lisp`** — 0
occurrences. `grep -rn 'make-ack|ack-frame'` over the tree finds only
`tests/tests.lisp` and `scripts/smoke-head.lisp` (a dev script that does ack).

So the doc comments that say "acks after painting" describe something no code
does. `ClientFrame::Ack` is what `hub.ack()` consumes on the daemon side
(`server.rs:256`), which is what drives scrollback trimming and the `dropped`
count other heads see. A head that never acks is a head the hub cannot account
for.

The Rust head acks every batch (`client.rs:114`) and its own `rendered`/
`filtered` counters exist to be reported there. **This is the most important
item in this document** — more than any missing pane — because it is a
correctness obligation `PLAN.md` §5.1 states explicitly ("Ack is sent **after**
painting, never on receipt") and `src/head.lisp`'s own header comment claims.

**S**, and it wants a test that fails without it: attach, receive events, assert
an `Ack` with a monotone `seq` left the socket.

### 2.2 Four frames are defined and never sent

| frame | defined | sent from | consequence |
|---|---|---|---|
| `ack` | `protocol.lisp:80` | nowhere | §2.1 |
| `resync` | `protocol.lisp:85` | nowhere | no `/resync` command; the head cannot ask for a fresh snapshot, so §M6's resync drills only exercise the daemon-initiated path |
| `peek` | `protocol.lisp:162` | nowhere | **the `:peek` screen is unreachable** — see §2.3 |
| `resume_session` | `protocol.lisp:146` | nowhere | a session in the store but not in the daemon cannot be brought back from the picker |
| `list_todos` | `protocol.lisp:137` | nowhere | the todos pane has no bootstrap read; it shows only what `todos_updated` events have carried since attach |

### 2.3 The peek screen cannot be reached

`head-mode :peek` is set in exactly one place — the `"peeked"` frame handler
(`head.lisp:186`), which can only fire if a `Peek` was requested. Nothing
requests one (`%send` has no `make-peek`), and there is no `/peek` in
`*slash-commands*`. `peek-lines` (`render.lisp:422`) is reachable code with no
caller. Either wire it (one command) or delete the screen; right now it is a
mode the renderer supports, the help does not mention, and no key reaches.

### 2.4 The diff engine is ported and never called

`src/diff.lisp` is 488 lines of real work — Myers (`%myers`), backtracking,
`hunks` with context, word-level spans (`word-spans`), line numbers, emphasis
(`render-diff`). **`render-diff` has no caller.** The only edit rendering in the
head is `awhen-edit-lines` (`render.lisp:193`), a 15-line function that prints
every removed line then every added line, unnumbered, unemphasised, and only for
a *live* call.

So `TODO.md`'s **T20 is half done in the worst way**: the hard half is written
and disconnected, and the screen shows the naive version. The operator's own
words in `app.rs:849` (*"nothing really shown"*, and *"past edits lose their diff
panels"*) describe exactly this state.

### 2.5 `highlight.lisp` is ported and never called

`highlight-lines` (`highlight.lisp:126`), `lang-for`, `class-grid`,
`role-style` — 158 lines plus a native shim contract (`RANO.md`). `grep` over
`src/` finds it only in the `package.lisp` export list. So **code blocks in
markdown are never coloured**, and the `.so`'s availability never matters
because nothing asks. Same shape as §2.4.

### 2.6 Stale documents

- `PLAN.md` says protocol **18** in four places (§2, §5, §6, D1); the code is
  **20** (`protocol.lisp:14`). The frames v19/v20 added (`withdraw_prompts`,
  `stop`, `promote`) are implemented or partly so, and the plan does not know.
- `PLAN.md` §8 gives the eval socket path as `$XDG_RUNTIME_DIR/leticl/tui-<pid>`
  — the code uses `$XDG_RUNTIME_DIR/tui-<pid>.sock` (`hack.lisp:13`).
  `HACKING.md` had the same error and it is fixed there; `PLAN.md` still has it.

---

## 3. The gap, by area

### 3.1 Transcript and cards — the biggest visible gap

| feature | letibot | leticl | size |
|---|---|---|---|
| **diff on an edit call** | `card::render`, two-panel `diff_split` | naive before/after block, live calls only (§2.4) | **L** |
| **diff after the call settles** | `call_edits` map by item id (`app.rs:856`), seeded from the snapshot | nothing — the block disappears with the live card | **M** |
| call duration on a settled row | `call_ms` by item id (`app.rs:842`) | nothing | **S** |
| oracle brief + reply on a settled row | `call_decisions` by item id (`app.rs:869`) | live decision card only; gone once the row lands | **M** |
| tool call's **target** on the row | `call_targets`, replaced per round (`app.rs:830`) | `:target` on the live call only | **S** |
| raw `<function=…>` markup behind a chord | `raw_calls` (`app.rs:686`), `ctrl-x` | absent | **S** |
| thinking header + reasoning decoration | `thinking_header`, `reasoning_decor` (`app.rs:6324`) | indented italic, one style | **S** |
| turn footer (state/usage/timings) | `turn_footer` (`app.rs:6433`) | absent | **S** |
| user block with a timestamp | `user_block`, `clock_time` (`app.rs:6880`) | `› text` | **S** |
| queued prompts rendered in the body | `queued_lines` (`app.rs:6961`), tail of body | count in the status line only | **S** |
| warnings/notes **interleaved where they happened** | `notes: Vec<(usize, Note)>` (`app.rs:647`) | collected, never rendered in the transcript | **M** |
| settled decisions rendered | `decision_lines` (`app.rs:7262`) | `settled-decisions` collected, not drawn | **S** |
| tool outcome word / "why" | `outcome_word`, `outcome_why` (`app.rs:6837`) | `outcome-name` only | **S** |
| activity indent / gutter / `step_in` | `activity_indent`, `strip_gutter`, `step_in` | absent | **S** |
| fold state per card | `Fold`, `card_cfg` (`app.rs:6390`) | fold is a global pref | **S** |

The three **L/M** rows here are one project, not three: they all need the same
thing — **a value keyed by `item_id` that survives the live card being taken over
by the transcript row**. That is the design `app.rs` arrived at after getting it
wrong (see the `call_targets` comment, `app.rs:806-829`: the call id is
round-positional, so it can never be the key).

### 3.2 Input and the editor — the second biggest

The reference's composer is `letibot_ui::editor::Editor`, 1,090 lines
(`crates/ui/src/editor.rs`); leticl's is `src/keys.lisp`'s composer, ~70 lines.

| feature | letibot | leticl | size |
|---|---|---|---|
| **multi-line prompt** (`alt+enter`) | yes | **no** — `alt` is decoded (`keys.lisp:138`) and nothing handles it | **M** |
| kill ring + **yank** (`ctrl-y`) | yes | kills exist (`ctrl-k/u/w`), no yank | **S** |
| **undo** (`ctrl-z`), batched per word, kills as steps | yes | absent | **M** |
| prompt history | yes | yes (`composer-history-step`) | — |
| **paste ledger** — ≥5 lines collapse to a marker, sent whole | yes | absent; pastes are inserted raw | **S** |
| **`esc esc` to interrupt** (twice in 5s) | yes | `esc` is a no-op in normal mode (`head.lisp:473`) | **S** |
| **mouse click** — pick a picker row under the pointer | yes (`picker_rows_drawn` guards it, `app.rs:546`) | decoded (`keys.lisp:103`), never acted on | **M** |
| mouse wheel scroll | yes | yes | — |
| click arithmetic per screen (mode card rows, header rows) | yes (`mode_first_row`, `screen_rows`) | n/a | **S/M** |
| `esc` returns to following the stream (scroll→0) | yes | absent; once scrolled you stay scrolled | **S** |

### 3.3 Keys — mostly bindings for features that do not exist yet

The reference's precedence ladder is: the decision ladder, gated on an empty
composer; then panes; then the composer. **leticl already has that ladder**
(`head.lisp:394-416`) — the divergence is in what the rungs *reach*.

| key | letibot | leticl | note |
|---|---|---|---|
| `ctrl-r` | fold thinking | — | `/think` exists; binding missing |
| `ctrl-t` | fold tools | — | `/tools` exists; binding missing |
| `ctrl-x` | raw calls | — | **feature absent** |
| `ctrl-s` | session list | — | `/sessions` exists; binding missing |
| `ctrl-p` | todos pane | — | `/todos` exists; binding missing |
| `ctrl-g` | subagents pane | — | `/subagents` exists; binding missing |
| `ctrl-q` | jobs pane | — | `/jobs` exists; binding missing |
| `ctrl-o` | **promote** the running command to the background | — | **feature absent** (§3.5) |
| `ctrl-l` | repaint | yes | — |
| `ctrl-a/e/w/u/k` | editor | yes | — |
| `ctrl-y` | yank | — | §3.2 |
| `ctrl-z` | undo | — | §3.2 |
| `alt+enter` | newline | — | §3.2 |
| `pgup/pgdn`, wheel | scroll | yes | — |
| `tab` | complete `/command` | yes | — |
| `↑↓` | cursor, then prompt history | yes | — |
| `ctrl-c` | clear; twice on empty quits | **opens the quit card / interrupts** | *deliberate* — see §4 |
| `esc esc` | interrupt | — | §3.2 |

### 3.4 Slash commands

leticl answers 14 of the reference's 24. Missing:

| command | what it is | leticl | size |
|---|---|---|---|
| `/verbosity` | terse/normal/loud — which events reach the screen | absent; no verbosity concept | **M** |
| `/models` | list models with auth; switch this conversation; `local` | absent | **M** |
| `/default-model` | what a *new* session starts on | absent | **S** |
| `/resync` | throw state away, take a fresh snapshot | absent **and the frame is never sent** (§2.2) | **S** |
| `/job` | read a background job's output: list, `ID`, `--offset N` | absent; the jobs pane counts bytes and cannot show them | **M** |
| `/gate` | the gate's decisions, and rule on them afterwards: `recent`, `todo`, `corpus`, `ok|grant|revoke ID` | absent | **L** |
| `/supervise` | the guard model answers every gated call before you do — `on`, `off`, `status` | absent | **M** |
| `/flowy` | the seat on the fabric: `status`, `login`, `logout` | absent | **M** |
| `/status` | both have it | yes | — |
| `/reshape`-class extras (`/peek`, `/resume`) | the reference reaches these through panes | absent (see §2.2, §2.3) | **S** |

leticl also has `/subagents` and `/todos` as *commands* where the reference uses
`ctrl-g`/`ctrl-p`. Harmless; noted in §4.

### 3.5 Panes and screens

| screen | letibot | leticl | size |
|---|---|---|---|
| help | `help_lines` (64 rows) | `help-lines` | — |
| status | `stats` | `status-screen-lines` | — |
| config | **editable in place**, `ConfigEdit`/`HeadSetting` per row, writes `head.toml` | read-only, and its own copy says *"the daemon owns this list"* (`render.lisp:321`) | **L** |
| session picker | arrows **and** click **and** typing a number/name | arrows only | **M** |
| **mode picker** | `mode_picker`, a real list from `SettingRow::choices` | prints a name to copy (`/mode` needs the name typed) | **M** |
| **models picker** | `models_picker`, same machinery | absent | **M** |
| **quit card** | `quit_card`, two answers (leave / leave+stop) | `head-quit-open` — **already has this** | — |
| todos pane | session plan **+ repo `TODO.md`** (`repo_todos_map`, `app.rs:6503`) | session plan; repo section map absent | **S** |
| subagents pane | `subagents_pane`, Enter → **subagent output view** | tree only, no output view | **M** |
| jobs pane | `jobs_pane`, Enter → job output | counts only | **M** |
| **subagent output view** | `sub_out`, spilling to a file when long (`spill_sub_out`, `app.rs:6278`) | absent | **M** |
| **promote the running command** | `ctrl-o` → `Action::Promote` (`app.rs:2451`); the daemon honours it inside `bash`'s wait loop | absent — a long command cannot be backgrounded from the head | **M** |
| secret card | yes | yes | — |
| peek | yes | unreachable (§2.3) | **S** |
| **notice with a TTL** | `notice` + `notice_ttl` (`app.rs:687`), expires so it is not furniture | `head-status-note` persists forever | **S** |
| **stall detection** | `now_ms` + `last_event_at` → a head that stops hearing from the daemon says so | absent | **S** |

### 3.6 Chrome — the bottom third looks different

The reference's composer is **a box**, and this is the most visible structural
difference on screen. `screen()` builds it as: a `╭─╮` top edge carrying a title,
body rows, a `╰─╯` bottom edge whose right side carries the wiring
(`model · dialect · endpoint`) joined with `·`, an **alarm line**, a **hint bar**
below, and an **unboxed fallback** on a short screen where the border does not
fit (`app.rs:4011-4102`, `4284`, `4318`). There is also a left **gutter** down
the whole body (`Self::gutter(term_w)`, `app.rs:3951`).

leticl draws `› `, a plain line, and no gutter (`render.lisp:472`), and its status
line is a bordered row rather than a box edge.

| element | letibot | leticl | size |
|---|---|---|---|
| boxed composer (`╭╮╰╯`) with a title | yes | no — bare `› ` | **M** |
| the box edge carrying model/dialect/endpoint | yes | the top border carries title/model; not the same shape | **S** |
| **alarm line** (only non-zero counters) | yes (`alarmed()`) | status note only | **S** |
| **hint bar** | `hint_bar`, `app.rs:4318` | absent | **S** |
| **unboxed short-screen fallback** | yes | n/a — nothing to fall back from | **S** |
| left gutter on the body | yes | no | **M** |
| completions shown on their own line | `completions_line` (`app.rs:3322`) | crammed into the status note | **S** |

### 3.7 Render architecture — every frame re-renders the viewport

The reference keeps `hist_lines`, a `hist_marks` vector and
`invalidate_history_from(k)` (`app.rs:595-612`, `3750`, `3772`), because a
token-per-delta stream must not re-lex the session. Its own comment records what
happened when that rule was broken above the lexer: *"135 full rebuilds of an
89-row session, measured on one replay"*.

leticl has no cache and no invalidation mark. `%viewport-lines`
(`head.lisp:462`) walks items backwards calling `item-lines` on each until it has
`want` lines, **on every paint** — so a streaming turn re-runs markdown, table
layout and wrapping for the visible tail on every delta. It is bounded (it stops
at `want`), which is why it is not a bug today, but a frame's cost grows with how
much work those visible items cost, and there is no mark to say "only rows from
here are stale".

**L** to do properly, **M** to bound it, and worth a measurement before either —
this is `PLAN.md`'s own §13.3 concern and the one place leticl's architecture
differs from the reference rather than merely lagging it.

### 3.8 Preferences that outlive the process

`letibot_ui::prefs` (`crates/tui/src/prefs.rs`) reads and writes
`~/.config/letibot/head.toml`: diff shape, folds, raw calls. Written whenever the
config pane changes a row; unknown keys and comments survive a write.

leticl holds `head-prefs` in the struct (`head.lisp:43`) and nothing persists it.
**The folds and the diff shape die with the process**, which is the exact defect
`prefs.rs`'s header quotes the operator about. **M**, and it is a dependency of
the config pane above.

### 3.9 Rendering engines — ported, partial, or missing

| engine | letibot | leticl | size |
|---|---|---|---|
| diff (Myers, hunks, word emphasis) | `ui/diff.rs` 839 | `src/diff.lisp` 488 — **written, unwired** (§2.4) | **S** to wire |
| **sidediff** (two-panel before/after) | `ui/sidediff.rs` 878 | absent | **L** |
| highlight (tree-sitter via shim) | `ui/highlight.rs` 699 | `src/highlight.lisp` 158 — **written, unwired** (§2.5) | **S** to wire |
| **progress** (token rate, `thousands`, the rate/ETA vocabulary) | `ui/progress.rs` 442 | absent | **M** |
| width (cluster-aware: ZWJ, emoji, combining) | `ui/width.rs` 777 | `src/width.lisp` 106 — approximate | **M** |
| card (the call card vocabulary) | `ui/card.rs` 813 | spread through `render.lisp` | **M** |
| style | `ui/style.rs` 526 | `src/cells.lisp` styles | — |
| editor | `ui/editor.rs` 1090 | §3.2 | **L** |

---

## 4. Divergences that should stay

Not everything different is a gap. These are deliberate and should be recorded
as such rather than flattened:

- **`ctrl-c` means different things.** The reference clears the line, then quits
  on a second press against an empty prompt. leticl interrupts a running turn,
  otherwise opens the quit card, and a second press leaves. leticl's is the v20
  protocol's own shape (`make-stop` travels the wire rather than killing a pid)
  and was built to an operator request. **Keep it** — but the help text must say
  so, because someone with the reference in their fingers will be surprised.
- **`/subagents`, `/todos` as commands** where the reference uses chords. leticl
  has no chord for them *yet*; once §3.3 lands, keep both — typing is how a
  script and a model drive a head.
- **The render gate and `--screen`** (`HACKING.md`) have no reference equivalent.
  They exist because leticl can be patched live and the reference cannot. This is
  leticl ahead, not behind, and should not be "aligned".
- **The eval socket itself** is the whole point (PLAN §1) and has no counterpart.

---

## 5. Suggested build order

Ordered by *dependency*, then by how much of the operator's day each unlocks.
The first three are not new features — they are existing code and existing
obligations.

1. **Ack** (§2.1). Correctness, and `PLAN.md` already says so. With a test.
2. **Wire what is already written**: `render-diff` onto edit cards (§2.4),
   `highlight-lines` into markdown code blocks (§2.5), `/resync` and the peek
   command (§2.2). Days, not weeks, and it turns ~650 lines of dead port into
   the operator's twice-requested diff.
3. **The item-id maps** — `call_ms`, `call_edits`, `call_decisions`, plus the
   snapshot seeding (`app.rs:842-869`). This is what keeps evidence on screen
   after a call settles, and it is the foundation of §3.1's three big rows.
4. **The editor** (§3.2): multi-line, kill ring + yank, undo, paste ledger.
   Everything typed goes through it, so it is worth doing before more panes.
5. **Prefs** (`head.toml`) → **the config pane becomes editable** (§3.8, §3.5).
   Prefs first: the pane writes what the file holds.
6. **The panes**: settings on attach (P44 — *first*, the pickers read the rows it
   fetches), then the mode picker, models picker, subagent output view, job
   output, promote (§3.5), mouse click (§3.2), **pane scrolling (P41)**, and the
   **todos rewrite (P42)** — §7.2 is the largest single item added by the second
   pass, and it is two functions in a file this strand already owns.
7. **The commands**: `/verbosity`, `/models`, `/default-model`, `/job`, then the
   environment-facing ones (`/gate`, `/supervise`, `/flowy`) — those are **L**
   each because they are features, not bindings: they need their own protocol
   surface and their own screens.
8. **The chrome** (§3.6): the boxed composer, the gutter, the hint bar, the alarm
   line; then turn footer, stall detection, notice TTL, notes interleaved in the
   transcript, queued lines in the body (§3.1, §3.5), and **the money meter
   (P43)**. The composer box is the most visible single change in this document.
9. **Bindings** (§3.3) — cheap, but *after* the features they reach, or they
   bind to nothing.
10. **Engines**: sidediff (two-panel), progress vocabulary, cluster-aware width
    (§3.9).
11. **Render architecture** (§3.7) — measure first. Only worth the machinery if
    a long session with a streaming turn is actually slow; the reference built it
    because it measured 135 rebuilds of an 89-row session.

An honest read of the shape: **1–5 are weeks; 6–11 are a season**, and item 7's
last three are each a project. Item 2 is the best ratio in the list — most of
the work is already in the tree.

---

## 6. What I could not check

- Whether every reference feature is *reachable* — I read `help_lines` as the
  operator-facing truth and did not drive the Rust head.
- The `letibot_ui` modules' internal behaviour (I counted and read headers, not
  bodies); "878 lines of sidediff" is a size, not a spec.
- `crates/ui/DESIGN.md` in depth.

I *did* check markdown proactively, and the hedge I first wrote there was wrong:
`src/markdown.lisp` already does headings, fenced code, blockquotes, GFM pipe
tables with column padding, ordered and unordered lists, and inline bold/italic/
code (`markdown.lisp:56-128`). The real gaps are narrower — no nested-list
indent, no links or strikethrough, no per-column table alignment (`:---:`), and
code fences are not syntax-highlighted, which is §2.5 (the engine exists, unwired)
rather than a markdown deficiency.

---

## 7. What the 19 commits since `82ff650` changed

`82ff650..7564417` is 19 commits and **+1224 lines to `app.rs`**. Six of them
add something this head does not have, and one of those is a bug rather than a
gap. The rest are daemon-side (`Region::Scratch`, the oracle reading a script,
the request id leaving the brief) or a plan for a future workstream
(`docs/streaming-markdown-plan.md` — a tree-sitter streaming engine for rano,
which will matter to §3.9 and to markdown when it lands, but adds no head
feature today).

**The `help_lines` diff was one changed row** (`ctrl-p`'s text) and no new slash
commands — so §3.3's chord table and §3.4's command table stand unamended. These
are not new commands; they are new *behaviour inside existing ones*.

### 7.1 Panes could not scroll — now every one does (P41)

Every pane drew `rows.truncate(room)` and the scroll keys were *swallowed* while
one was open. Right that the view underneath must not move; it left the pane
itself unable to move at all, and `leticl`'s own TODO.md renders 98 rows, so on a
40-row terminal more than half was unreachable — and the ↑↓ cursor could walk
into rows never drawn.

One `pane_scroll` for all of them (only one pane is open at a time), with the
cursor scrolling itself into view. Two bugs found by its own test, both worth
knowing because the shape recurs:

- **The polarity is the opposite of the transcript's.** `self.scroll` counts rows
  back from the **bottom** (up increases it); `pane_scroll` counts rows hidden
  above the **top** (down does). Copying the first makes PageDown a no-op that
  looks exactly like the swallowing it replaced.
- **`repo_sel` and `pane_scroll` count different things** — the repo's rows and
  the pane's, which start with a title and the model's live list.

**leticl**: panes are `:help :status :config :jobs :subagents :peek :todos` and
none of them own a scroll offset; `head-scroll` moves the *transcript* only. Any
pane taller than the body is clipped with no way to reach the rest, and
`repo-todo-lines` walks the whole file. **P41.**

### 7.2 The todos pane was rewritten: items, org roll-up, state paint, unfold (P42)

Three commits, and they are one feature. Measured from the operator's own words
in them: *"our todo pane doesnt render them - only section titles and sub todos
count"*, then *"colors?"*, then *"if a todo has some associated text? should i be
able to expand it somehow?"*.

| what | before | now |
|---|---|---|
| **items** | one line per `## ` heading, items never drawn | heading + its items nested under it |
| **roll-up** | `Phase 0 — repo — 0 open, 2 done` | org's rule and org's cookie: `[x] Phase 0 — repo  [2/2]` |
| **state** | not painted | done green, doing yellow, **open left alone** |
| **detail** | **dropped** — the lines under a checkbox were thrown away, so an item read as a sentence cut in half | kept; enter (or tab) unfolds, moving off folds |
| **freshness** | read once at open | `stat` per draw on `(mtime, len)` |

Org's rule, and the whole of it: *every child done makes the parent done; any
child started makes it started; otherwise open.* A heading with **no** checkboxes
under it gets neither box nor cookie — an empty section is one nobody has filled
in, and in a real TODO.md that is every prose heading, which must not be claimed
as finished work. `###` owns its own items, being a subsection in both org's
outline and markdown's.

Four traps the commits name, each a defect this head could reproduce:

- the cursor landed on headings, because a heading carries a mark too (its
  roll-up), so the mark cannot be what tells a row from a heading — the row is a
  struct with an explicit `item` now;
- the indent must be carried **separately from the text**, because the indent
  belongs *before* the mark and the mark is what gets painted — baked together it
  renders `[x]     Phase 0` with the colour in front of the whitespace;
- `colour()` appends a RESET unconditionally, so painting an open box with an
  empty code emits a bare `ESC[0m` after every one — on the most common row in
  the pane. Asserting the *escapes* rather than the glyphs is the only way that
  is visible;
- a blank line closes an item, or the prose between a heading and its list
  attaches to whatever came before and two items a blank apart merge.

**Freshness**: one `stat` per draw rather than an inotify thread — a watcher
means a descriptor, a thread, and an event routed into a head whose design is one
loop over one channel, and the pane is drawn only while it is open. `(mtime, len)`
rather than mtime alone, because second-granularity mtime misses two writes in one
second.

**leticl**: `todos-lines` (`panes.lisp`) draws the model's live list with marks
and then the repo file as **flat `:bright-black` lines** via `repo-todo-lines` —
no nesting, no roll-up, no paint, no detail, no re-read. This is a rewrite of
two functions, both already in S6's file. **P42**, and it is the largest single
item in this section.

### 7.3 The money meter (P43)

`Usage.cost_micros_usd` — `Option<u64>`, `#[serde(default)]` so an older daemon's
frame still reads. The head sums what it has watched finish and puts the total
**beside the token count in the header**, which is where the question "what is
this costing me" is already being asked:

```
$0.0421   128k ctx · 51% cached · 32 tok/s
```

Three rules the commit is explicit about, and each is a version of a rule this
repo already holds elsewhere:

- `None` adds nothing **and lights nothing** — *"free and unpriced are both 'no
  number', and `$0.0000` on every local header would be noise"*;
- `spent_seen` distinguishes *free, so nothing to show* from *metered and nothing
  has finished yet* — the same "a number nobody took" rule as the cache
  percentage;
- **the total belongs to the conversation, not the head** — a session switch
  clears it, because carrying one session's bill onto another's header is wrong
  in the direction that costs money. A head that attached late says so by having
  only what it watched.

The daemon had computed `micros_usd` and read it in exactly one place: the
one-shot `--prompt` printer in `harnessd.rs`. It never went on the wire, so a
session driven from a head never saw it.

**leticl**: reads `:usage` as a plist and ignores the field entirely
(`session.lisp` keeps the whole usage plist; `status-screen-lines` prints it
raw), and the header (`top-border`, `chrome.lisp`) carries title, model and seq
only. **P43.**

### 7.4 Settings are asked for on attach (P44) — a bug, and it is on the screen

`ServerFrame::Settings` is only ever sent in reply to `ClientFrame::Settings`;
nothing pushes it. So a head that had not opened `/mode` or `/config` **had no
settings at all**, and its header fell back to the model `Hello` named — which is
exactly the operator's report: *"restarted the letibot - still qwen"*. The daemon
knew; nothing had asked.

Now the head asks **on attach, and again after a switch**.

**leticl has this bug, measured on the operator's own head while writing this**
(`pid 3567952`, 2026-09-20):

```
(head-settings *head*)                       -> NIL      ; never asked
(getf (session-wiring …) :model)             -> "qwen-3.8-27b"        ; Hello, stale
(getf (session-turn   …) :model)             -> "deepseek/deepseek-flash"  ; the truth
--screen, row 0 -> " leticl · s-… · qwen-3.8-27b ─── … seq 7313 · 2 heads "
```

**The header names a model the session is not using.** `top-border`
(`chrome.lisp`) reads `(getf (session-wiring s) :model)` — the Hello-time value,
set once at attach — so a session whose model changed mid-life shows the old one
for ever. The running turn's own `:model` is correct and is thrown away.

So this is not "a feature we lack"; it is **a number on the operator's screen
that is wrong**, which is the defect class this repo exists against. `(make-settings)`
is sent from exactly one place — the `/config` command (`commands.lisp:73`).

**Where the fix goes**: the *send* is `head.lisp` (`run`, and `%try-reconnect`),
so it is S1's file; the *display* is `chrome.lisp`, S8's. It is therefore listed
under **S1** (the wire the head owes) with the display half recorded here, and
**S6's P22/P23 pickers are what consume the rows** — which is why the DAG wants
it done before them either way.

### 7.5 `deny_and_tell` can be told something (P45)

The option read *"Deny, and tell the model why"* and **the why had nowhere to
go** at any layer: no field on the head's `Action::Answer`, none on
`ClientFrame::Answer`, none on `Reply::Permission`, and nothing branched on the
id — the whole of what the model was told was `<who> chose deny_and_tell at the
head`.

Typing it was *actively refused*: `match_option` ended with
`if id.kind != OptionKind::AllowAlways { return None; }`, so `deny_and_tell use
the scratch dir` matched nothing, the line stayed in the composer, and **nothing
was answered** — the ask sat open while the operator looked at their own
sentence.

Now the words ride after the option id the way a glob does after `allow_always`,
travel as their own `note` field, and become the decision's basis:

```
deny_and_tell use the scratch dir, not /tmp
-> deadtrickster chose `deny_and_tell` at the head: "use the scratch dir, not /tmp"
```

Quoted and attributed, because *"a sentence the model reads as the harness's own
reasoning is one it will argue with, and one it reads as the operator's is an
instruction."* A `deny_and_tell` with nothing typed is a denial with no reason
and says exactly that plus how to give one. No `PROTOCOL_VERSION` bump — an
added, defaulted field on an existing frame.

**leticl**: `make-answer` takes `(req-id option-id &optional pattern)` and the
card prints the options with no mention of where words would go
(`cards.lisp`, `decision-card-lines`). **P45.**

### 7.6 A refusal says its reason once (P46)

From *"how many times is 'nothing ran' needed?"* — once; it was three, and the
card was 21 lines for one refused command. A refusal's payload is already a
complete explanation, and two other places said the same paragraph again: the
envelope (`outcome_word` inlines the reason for `Failed`/`NotRun`) and the card
(when `ctrl-t` was open it printed the entire `why` directly above the payload
that is the same text).

Both now check whether the text is already below them and say it only when it is
not — because where the payload does *not* explain itself, that line is the only
place the reason is said. Two bounds so the check cannot misfire: **short reasons
are left alone** (cheap to repeat, and a short string can appear below by
coincidence), and the card matches on the reason's **first line**, because `why`
is a paragraph while the payload arrives already split into lines — a
whole-paragraph containment could never have matched, *"the kind of check that
passes review and never fires"*.

**leticl**: `%outcome-style` and the `:tool_result` arm print the outcome word and
a payload preview with no such check (`cards.lisp`). **P46**, and it depends on
P8–P10 having somewhere to put the reason.

---

### P40: what to do with this document — **keep it, as the measurement**

Recommendation, and the argument in five lines: **this file should stay, because
it is the only place that says what the reference DOES rather than what we plan
to do, and the two drift at different rates.** `TODO.md` is a work list — items
are opened, worked and closed, and a closed item says nothing about what it
closed on. This file is a measurement with provenance: a pinned commit, a file
and line for each gap, and the counts that go stale silently (§1's 28 bindings,
§3.9's line counts). Folding the finished rows into `TODO.md` would delete the
evidence and leave the conclusions, which is exactly the shape of claim this repo
exists against. So: keep it, and re-measure it against a new pinned commit when
the reference moves in a way that matters — not edit it line by line, which is
how a measurement becomes a memory. `TODO.md` §7 already carries the sync
procedure for the same reason.

---

## 8. What the screens said (compare rounds 3 and 4, 2026-09-20)

Measured with `scripts/compare-heads`: both heads on `s-1789639478142928813`,
210×63, the same instant, `tmux capture-pane -e`, rows compared **with their
escapes**. This is a different instrument from §1–§7, which read the reference's
*surface* (its bindings, commands, struct fields); this reads its *output*, and
it found things the surface could not — every one of them a function that
existed, was called, and drew the wrong thing.

### Round 3 — the transcript (letibot `e9ee3c4`, fixed in leticl `1be0293`)

Start: 42 of the 45 shared rows differed. End: 60 of 63 rows byte-identical in
both fold states; the three left carry numbers each head measured for itself.

| what the row showed | cause | fix |
|---|---|---|
| paragraphs cut at column 210, no continuation | `markdown-lines` called with no width; `%place-lines` clips | the block model wraps every paragraph to its width |
| `What I measured` bold, letibot `## What I measured` faint hashes + bold blue | heading dropped its marker and level | hashes faint, text by level (cyan/blue/bold) |
| `**1.6–2.7 s**` literal in a table cell | cells were strings, not runs | cells are inline runs, columns measured painted, water-filled, wrapping |
| `` `activity-indent` `` literal backticks inside bold | inline spans did not nest | grammar with `nest` (code inside bold is cyan, not bold) |
| `▸ Ran … · ok · 9 lines  … +8 lines · ctrl-t` on one row | seam appended to header, first line dropped | header / first line / seam, three rows |
| `· 1 line` beside an inlined one-line result | count printed for a fold with nothing to fold | inline form carries no count |
| `<<'MSG' the step` where letibot has `<<'MSG'\nthe step` | `~s` then control-char flattening | Rust-Debug quoting |
| all-bold header; no `1/71`; three columns short | one register; `%turn-index` counted decisions | blue bar / bold title / dim path / dim tail; position from the session list |
| prose on row 59, box on 60 | no gap after committed rows | one blank row, always |
| one extra blank row at the bottom of every open card | `split-string` keeps the trailing "" that `str::lines` drops | `%payload-lines` |
| `▸ ` dim on the reasoning fold; `3 lines` for three paragraphs | mark dimmed; source lines counted | plain mark; screen lines |

Not a rendering difference, and left alone: the `⚠` on our box edge is
`Hello.dropped` > 0, which the reference also alarms on — letibot had attached
before the log wrapped, so its count was 0.

### Round 4 — the panes (letibot `2deceb8`)

Every full-body pane opened on both heads, captured, compared. Three of ours
did not render at all:

| pane | letibot | leticl |
|---|---|---|
| jobs | `background jobs`, the two dim sentences | `TYPE-ERROR The value ("" :DIM T) is not of type STRING` — the header's second element was `(list LINE)`, a line whose segment is a line; **never rendered** |
| subagents | `subagents`, the two dim sentences | the same error, the same cause |
| config | `▸ ✎ diff view  split` / `from …/head.toml`, `✎` on the editable rows, then the read-only session rows | `UNBOUND-VARIABLE The variable ANAPHORA:IT is unbound` — **never rendered** |
| todos | cursor `▸` on the **repo's items**, ↑↓ moves it, enter/tab unfolds; session plan indented 6; ` ···` one space | cursor on the *session plan*, no `▸`, ↑↓ clamped to that list — *"todos pane not browsable"*; indent 4; two spaces before `···`; title carries a hint suffix; closing sentence differs |
| help | 41 rows | 50 rows |
| status | 26 rows | 18 rows |

The wheel, found in the same session: a burst of SGR wheel events leaked
`[<65;120;30M` into the composer (`%poll-char` consulted the deadline before the
buffer; the input thread had been stopped past the 60 ms window), and a decoded
wheel did nothing anyway (`:wheel-up` arms keyed on `:type`, which is `:mouse`).
Fixed in `3ec5791`, with the reference's `── scrolled back` banner.

**Result** (leticl `5a52ae2`, re-captured on both heads at 227×61): help 57/57
body rows identical; jobs 57/57; subagents 57/57; sessions 55/57 (the two carry
live row counts); todos row-identical in all three states once the stale row cache
was cleared; status and config differ only in each head's own numbers (`h3` vs
`h18`, `filtered`, `dropped`) and its own prefs file. The picker's right edge had
been four columns short: `pane-width` took the gutter off cols that were already
net of it.

**The lesson this round adds to §1's:** *"S6 panes done"* was recorded against
code that had never drawn a frame. A pane is done when it has been opened on the
head and captured, and `compare-heads` is how that is measured.
