# leticl ↔ letibot: feature parity assessment

What the Rust TUI head (`crates/tui`, `crates/ui`) does that the Lisp head
(`src/`) does not, measured rather than recalled. This is an input to planning:
`PLAN.md` says what leticl is for, `TODO.md` says what is tracked, and this says
what is actually missing.

**Measured against `letibot` @ `82ff650e6c43502069ccabba9b8c0ed4afd40b19`
(2026-09-19), from `leticl` @ `a12ee717640d99d745f44281c4b41403cbff7a6f`.**

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
6. **The panes**: mode picker, models picker, subagent output view, job output,
   promote (§3.5), mouse click (§3.2).
7. **The commands**: `/verbosity`, `/models`, `/default-model`, `/job`, then the
   environment-facing ones (`/gate`, `/supervise`, `/flowy`) — those are **L**
   each because they are features, not bindings: they need their own protocol
   surface and their own screens.
8. **The chrome** (§3.6): the boxed composer, the gutter, the hint bar, the alarm
   line; then turn footer, stall detection, notice TTL, notes interleaved in the
   transcript, queued lines in the body (§3.1, §3.5). The composer box is the
   most visible single change in this document.
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
