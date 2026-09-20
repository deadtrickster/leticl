# leticl — TODO

Derived from `PLAN.md`. Status: `[ ]` open, `[~]` in progress, `[x]` done.
Dependencies are explicit; **do not start an item before its deps are done**.
This file is mirrored into the harness todo list; update both together.

`PARITY.md` is the measurement this file's Phase 7 is derived from — what the
reference head (`crates/tui`, `crates/ui`) does that this one does not, with
file:line citations. Read it before starting a parity item.

**The reference is pinned, and it moves.** Phase 7 was measured against:

| repo | commit | date |
|---|---|---|
| `letibot` (reference) | `756441720c7b53d39eca045185ed9b4168d09cc1` | 2026-09-20 |
| `leticl` (this) | `074bbf6` | 2026-09-20 |

An earlier pass measured `letibot` @ `82ff650e` (2026-09-19); the 19 commits
between the two are §7 of `PARITY.md`, and they added **P41–P46** below.

Every `PARITY.md` citation is a line number in **that** commit (line numbers
added before the §7 pass are in `82ff650`, and §7 says which). The reference is a
live repo, so a citation is a pointer into a moving tree: **before acting on one,
`git -C ~/Projects/letibot/letibot log --oneline <pinned>..HEAD` and re-read the
function** rather than trusting the number. When a strand finishes, record the
new reference HEAD it re-checked against; when the numbers no longer match, the
right move is to re-measure `PARITY.md`, not to guess which line moved.

## Dependency graph

```
T1 ─┬─ T3 ─┬─ T4 ──────┐
    │      ├─ T5 ──────┼─ T6 ────┐
    │      ├─ T7       │         │
    │      └─ T10      │         │
T2 ─┴─ T8 ─────────────┴─ T9 ─ T11 ─ T12 ─┬─ T13 ─ T14 ─┬─ T18 ── T22
                                          │             ├─ T19
                                          └─ T15 ─┬─ T16│
                                                  └─ T17 ┴─ T20, T21
```

Reading: T6 needs T4+T5; T9 needs T8; T11 needs T9; T12 needs T6+T11; T13
needs T10+T12; T14 needs T13; T15 needs T12; T16/T17 need T15; T18 needs T14;
T20/T21 need T14/T17; T22 needs T18.

**Phase 7 (parity)** is a second graph, below its own heading, because its unit
is a **strand** — a file-disjoint work package one subagent owns — rather than a
task.

## Phase 0 — repo

- [x] **T1** git init, `.gitignore`, commit PLAN.md + TODO.md.
- [x] **T2** vendor yason + alexandria + trivial-gray-streams, pinned in
  `scripts/bootstrap.sh` (yason `0c84b29`, t-g-s `257d73e`, alexandria
  `f283e25`).

## Phase 1 — foundation (M1)

- [x] **T3** `leticl.asd` (+ `/test` system), `src/package.lisp` (one package
  `:leticl`), `run.lisp` entry (`test` / `demo`), source-registry setup for
  `vendor/`. Deps: T1.
- [x] **T4** `src/term.lisp`: termios via sb-alien (tcgetattr/tcsetattr/
  cfmakeraw, TCSADRAIN), `with-raw-mode`, winsize ioctl (`terminal-size`),
  UTF-8 fd-streams, enter/exit sequences mirrored from `term.rs:188,461`
  byte-for-byte, synchronized-output helpers. Deps: T3.
- [x] **T5** `src/width.lisp`: `char-width`/`string-width`, compact port of the
  `ui/width.rs` ranges (CJK, Hangul, fullwidth, common emoji, combining,
  variation selectors, ZWJ). Full cluster-aware port (ZWJ sequences, regional
  pairs, escape-aware walking) stays open until T19/T20 need it. Deps: T3.
- [x] **T6** `src/cells.lisp`: cell buffer (char + interned style plist),
  `style-index` + cached SGR builder, `screen-put-string` (wide-char
  continuation cells, non-fitting wide char degrades to space),
  `paint-diff` (run-based, absolute moves, style tracked across the frame,
  `?2026` wrapper), `paint-full`. Deps: T4, T5.
- [x] **T7** `src/wire.lisp`: `read-frame` (skip blanks, `:eof` on close),
  `write-frame` (flush per frame), `wire-error` carrying the offending line.
  Deps: T3.
- [x] **T8** `src/json.lisp`: yason wrappers — decode to keyword-key plists,
  encode per PLAN §7 (never elide, nil→null, keyword value→snake string,
  plist→object, list→array). Deps: T2, T3.
- [x] **T9** `src/protocol.lisp`: `+protocol-version+` 18, constructors for the
  client frames we send (attach/ack/resync/prompt/interrupt/answer/
  answer_question/list_sessions/list_todos/new_session/rename_session/switch/
  peek/settings/detach first; the rest as needed), decode passthrough,
  request-id generator, reject-code constants, golden tests. Deps: T8.
- [x] **T10** `src/socket.lisp`: `connect-unix`, `discover-daemons` (parse
  `$XDG_RUNTIME_DIR/letibot/*.json`). Deps: T3.

## Phase 2 — attach (M2)

- [x] **T11** `src/session.lisp`: attach/hello handling, snapshot ingestion
  (read `view.rs` first — do not guess the shape), event application into a
  transcript model, ack bookkeeping per PLAN §5.1, resync handling. Deps: T9.
- [x] **T12** `src/head.lisp`: reader thread + mailbox, input thread + mailbox,
  main loop (drain, fold, paint-on-dirty), resize poll, ack-after-paint.
  Deps: T6, T11.
- [x] **T13** live smoke: attach to a real daemon, render the snapshot as plain
  lines, acks accepted, resync survives. Verified against the running daemons
  under `/run/user/1000/letibot/`. Deps: T10, T12.

## Phase 3 — real TUI (M3)

- [x] **T14** `src/render.lisp`: transcript items → styled cells, chrome
  (status line, wiring disclosure), fit loop with the ported drop order.
  Deps: T13.
- [x] **T15** `src/keys.lisp` + composer: escape decoding (port term.rs tables,
  bracketed paste, mouse SGR), line editing, prompt/interrupt send. Deps: T12.
- [x] **T16** decision/question cards: `DecisionRequested`/question rendering,
  `Answer`/`AnswerQuestion` frames, one-list-at-a-time rule, card steps aside
  while a decision is up. Deps: T15.
- [x] **T17** session picker: `Sessions`/`ListSessions`, `Switch`,
  `NewSession`/`ResumeSession`/`RenameSession`, click facts recorded by the
  frame. Deps: T15.

## Phase 4 — the point (M4)

- [x] **T18** `src/hack.lisp` + `scripts/tui-eval`: per-instance eval socket
  (PLAN §8), repaint-on-eval, `--list`/`--pid`, `HACKING.md` naming the
  contract surface. Demo: a model restyles the live TUI. Deps: T14.

## Phase 5 — the ports (M5)

The Rust→Lisp ports. Distinct from Phase 7, which closes the *feature* gap;
these are the engines both heads need.

- [x] **T19** markdown rendering (port `tui/markdown.rs`). Deps: T14.
- [ ] **T20** diff/sidediff/highlight (port `ui/diff.rs`, `ui/sidediff.rs`,
  `ui/highlight.rs`). Deps: T14. **Deferred**: ~2400-line port (Myers O(ND)
  edit script, intra-line word diff, side-by-side, syntax highlight). The core
  TUI already dumps the daemon-bounded before/after lines
  (`awhen-edit-lines`); the gap is hunk context, word-level highlight,
  split view, syntax colour. Plan (D2 relaxed 2026-09-19): port `diff.rs` +
  `sidediff.rs` + the hand-written `highlight.rs` lexer to Lisp; diff-panel
  colouring via rano's `syntax` module behind a small Rust cdylib shim
  (3-function C ABI, u8 role grid, caller-provided buffer) called with
  sb-alien — the head's only native dependency, degrading to uncoloured when
  the `.so` is absent.
- [x] **T21** prefs/settings/peek/subagent rows/todos screens. Deps: T17.

## Phase 6 — hardening (M6)

- [x] **T22** resync/reconnect drills, `Screen` frame answers (last painted
  frame retained), long-session memory behavior, saved-core note. Deps: T18.
  Reconnect (`%try-reconnect`) and `Screen` answers are in; long-session memory
  is unverified headless (needs a long live session).

## Phase 7 — parity

Closing the gap `PARITY.md` measures. The unit of work here is a **strand**: a
file-disjoint package that one subagent owns end to end. The DAG is the gates
between strands, not a sequence — strands with no edge between them run at the
same time.

### The two gates every strand must pass

**Gate 1 — source.** `sbcl --script run.lisp test` is **172/172 green** at the
start of this phase; it must not go below that, and each strand adds checks for
what it builds. A strand that cannot test something headless says so in its
commit rather than skipping silently.

**Gate 2 — the live head, and it is not optional.** The running head is the
verification surface. For every feature:

```sh
tui-eval --list                       # find the head's pid
tui-eval --pid <PID> --tree           # make the head match disk (every file)
tui-eval --pid <PID> --where <SYM>    # prove it: PUSHED, not "from the IMAGE"
tui-eval --pid <PID> --screen         # read what it actually drew
```

`--tree` is how a strand's work gets in, and **not `--file <one file>`**: the
gate proves the head can *paint*, not that *your* file is loaded, and since S0
rendering lives in six files. Pushing the wrong one exits 0 with a green gate and
the old code on screen. `--tree` pushes every file `leticl.asd` lists, in that
order, and stops at the first failure. `--where` then answers "is it in" from the
head's own record — `PUSHED` versus `from the IMAGE` — which is the one thing a
green gate cannot tell you.

A feature that is **not visible on the running head is not done**, however green
the tests are — that is the premise of this rewrite (`PLAN.md` §1), and these two
commands exist to make the claim checkable instead of hopeful.

### The rules that keep the live head usable

1. **The head is ONE shared resource; pushes serialize.** Two subagents pushing
   at the same time race, and the second overwrites the first's functions. Only
   the orchestrator pushes; a subagent prepares and hands over. Before any push,
   `tui-eval --pid <PID> --screen` to see the state you are about to change, and
   `--where <SYM>` to see what is currently loaded.
2. **Nothing that holds running state may be `defparameter`** — `defvar`, or a
   live push re-initialises it mid-session. `HACKING.md` §"Live state models
   defvar" has the table; this is the injury that killed a head, not a style
   preference.
3. **A whole file is re-evaluated at load time**, so a push is not a patch. Keep
   new top-level bindings `defvar`; keep the file loadable on its own.
4. **Recover, do not restart, after a bad push.** `tui-eval --screen` says what
   it draws; re-push with the mistake fixed. A restart is for a **`defstruct`
   change** (a changed struct layout is a hard error in this SBCL — *"redefine the
   STRUCTURE-OBJECT class … incompatibly"*), a toplevel change, or a dead paint
   loop. **`defclass` is not on this list**: a class redefinition propagates an
   added slot to existing instances, which is why the head's own state wants to be
   classes rather than structs.
5. **New files need `leticl.asd`** (`:serial t`, add to `:components`) *and* a
   push — the `.asd` edit is one line and is a shared file: it is the
   orchestrator's, like `TODO.md` and `PARITY.md`.

### Read the reference, do not guess from the citations

`PARITY.md` gives file:line for every gap, and a line number is **a pointer, not
a specification**. Before building anything, **fetch the actual source**:

- The reference is local: `~/Projects/letibot/letibot/crates/…`. Read the whole
  function, its tests, and the comments — the comments in `app.rs` are often the
  best available spec, because they record what went wrong when the obvious
  design was tried (`app.rs:806` on why the call id cannot key a map;
  `app.rs:2428` on why the jobs chord is `ctrl-q` and not `ctrl-j`).
- **`web_search` / `web_fetch` are available and should be used** for anything
  the tree cannot answer: the Common Lisp spec or a library's documentation
  (alexandria, `sb-concurrency`, `sb-ext`), a terminal escape-sequence
  convention, a markdown/GFM rule, an algorithm's published description. Guessing
  at a library's semantics is the same defect class as guessing at the wire.
- Colour escapes, key tables and the protocol have their own truths in the tree
  (`crates/ui/src/style.rs`, `crates/tui/src/term.rs`, `protocol.rs`) — read
  them rather than inventing a parallel convention.

### Write Common Lisp, not Rust in parentheses

The reference is Rust and this is not. **Its structure is the wrong thing to
copy**; its behaviour is the right thing to copy. A strand that transliterates a
Rust module into Lisp has done the work twice and got the worse half both times.

Concretely, reach for:

- **`defgeneric`/`defmethod` with `eql` specialisation** where the reference has
  an enum and a `match`. The `(case (intern (string-upcase …) :keyword) …)` over
  item types (`render.lisp:125`, `session.lisp:313`) should become

  ```lisp
  (defgeneric item-lines-for (kind item cols head)
    (:documentation "One transcript row's lines. KIND is the wire type as a keyword."))

  (defmethod item-lines-for ((kind (eql :tool-result)) item cols head) …)
  ```

  called as `(item-lines-for (%kind-keyword item) item cols head)`. Same
  extensibility — a model defines a method for a row type this head has never
  seen, from the eval socket, with no edit to a dispatcher — but **`item` is
  still the wire plist**. See the boundary rule below: this is the one place the
  class instinct would be actively wrong.
- **`loop`** with real clauses (`for … in`, `collect`, `when`, `until`,
  `maximize`) instead of index arithmetic. The `dotimes`/`aref`/`incf` walks in
  `render.lisp` are hand-written loops that `loop` states in a line.
- **`format`** instead of `concatenate` and `make-string`. `~{…~^…~}`,
  `~v@a`, `~<`, `~:>`, `~[~;~]`, `~*` do layout and pluralisation without
  helper functions.
- **`defstruct`/`defclass` with a printed name, and `with-` macros** for paired
  enter/exit (`with-tui-terminal`, `with-raw-mode` are the existing examples —
  every new resource pair gets one).
- **`&key`/`&optional`/`&rest` and multiple values** rather than tuples and out
  parameters.
- **`alexandria`** (`if-let`, `when-let`, `with-gensyms`, `lastcar`, `mappend`,
  `assoc-value`, `define-constant`) and **`anaphora`** (`awhen`, `aif`, `alet`)
  are already dependencies and are used in places; use them in the new code.
- **`defmacro`** where a pattern repeats — but only where it removes repetition
  rather than hiding it. One good macro beats ten clever ones.
- **`handler-case` / `restart-case`** where Rust would return `Result`. The head
  has a `restart`-shaped opportunity in the render path: a bad row should be able
  to degrade to a placeholder rather than take the frame.

**The boundary rule: wire-shaped state stays a plist.** `PLAN.md` D4 and §7, the
`session.lisp` header and `HACKING.md`'s contract all say the same thing — what
the daemon sent stays a keyword plist, so a model at the eval socket inspects
*exactly* the raw frame. Migrating `session-items`, frames or decoded events to
classes would trade that inspectability for dispatch, which is the wrong trade in
a head whose whole premise is being inspectable while it runs.

So the rule, stated plainly:

| is the data | shape | why |
|---|---|---|
| a wire frame, snapshot, event, or transcript item | **plist** (unchanged) | D4; a model must see what the daemon sent |
| the head's own state (`head`, `session`, a card cache, a pickset) | struct, or **class when a strand may need to grow it** | not on the wire; classes reshape live, structs do not |

"Extensible from the eval socket" is satisfied by an `eql`-specialised method on
the kind keyword — it does not require the *data* to be an instance.

**Reshape as you go.** When a strand touches a piece of Rust-shaped Lisp, leave
it idiomatic — but only the part the strand touches. A drive-by refactor of a
file another strand is holding is how two agents collide. The `S0` strands below
are where wholesale reshaping belongs, and `S0`'s `Done when` includes "the live
head still gates green", so idiomatic is never allowed to cost behaviour.

**One caution, and it runs the OTHER way from the usual advice.** `defstruct` and
`defclass` behave oppositely on a live redefinition, measured in this SBCL:

- **`defstruct` refuses.** Adding a slot to a struct whose instances exist signals
  *"attempt to redefine the STRUCTURE-OBJECT class … incompatibly with the current
  definition"*. This is why `tui-eval --file` skips `defstruct`, and it means a
  new slot on a struct is a **restart**, not a push.
- **`defclass` redefines and propagates.** An added slot is present on existing
  instances immediately (with its `:initform`); standard redefinition semantics
  apply. A *removed* slot raises `missing-slot` when reached, so remove nothing a
  live object may still hold.

So the idiomatic-Lisp advice above and the live-update rule agree: **classes can
be reshaped while the head runs, structs cannot.** That is why the head's own
state — the `head` struct, a card cache, a pickset — should be a class when a
strand may need to grow it. It is *not* an argument for the item vocabulary: that
is wire-shaped and stays a plist (see the boundary rule above).

### How a strand is run

Each strand is one subagent, briefed with:

1. **its `P` items from this file**, and the `PARITY.md` section that measured
   them — not a restatement of the gap, the measurement;
2. **the reference files to read** (pinned commit, path, symbol), with the
   instruction to re-read the function rather than trust the line number;
3. **the live-update protocol** above, quoted — S0's check, `defvar`, the gate —
   because a subagent that has not read this file will restart the head;
4. **the CL standard**: "behaviour from Rust, structure from Lisp", with the
   concrete list, and the standing permission to use `web_search`/`web_fetch`
   rather than guess at a library;
5. **its file boundary**: the files it owns, and the files it must not touch
   (`TODO.md`, `PARITY.md`, `leticl.asd`, and every other strand's files). A
   subagent that needs a shared file edited **asks**, and the orchestrator makes
   that one-line change;
6. **the handover**: it returns the changed files, the `Gate 1` result, the
   `Gate 2` plan (which files to push and what `--screen` should show), and any
   deviation it had to make. It does **not** push the shared head — the
   orchestrator serializes pushes.

The orchestrator's job per strand: approve the brief, serialize the push, run
Gate 2 on the live head, confirm `--screen` shows the feature, then mark the `P`
items done here and in the harness todo list.

### The DAG

**S0 is done**, so the graph below is live and the frontier is really six.

```
S1  wire        ─────────────────────────────────────┐
S2  engines     ─┬─ S3  cards ───────────────────────┼─ S9 ── S10
S4  editor      ─┘                                   │
S5  prefs  ──────── S6  panes  ──── S7  commands ────┘
S8  chrome      ─────────────────────────────────────┘
S11 docs        (independent, no deps, no dependents)
                                       all strands: Gate 1 + Gate 2
```

Reading: **S3 needs S2** (it renders with S2's engine). **S6 needs S5** (the
config pane writes what prefs holds). **S7 needs S6** (the pickers are the
commands' menus). **S9 needs S3+S6+S8** — S1 is done (it binds chords to features that
must already exist). **S10 needs S3+S8** (measuring a render path worth caching).

**The parallel frontier, in one line**: `S2, S4, S5, S8, S11` — five strands
with no deps between them and, since S0, no shared file either. **S1 is done**, so
S9 no longer waits on it (`S9` needs `S3+S6+S8` now).

**File ownership is what makes that true**, so it is a rule and not a hope: a
strand edits the files S0 assigned it and no others. Crossing a boundary is how
two agents overwrite each other's work — the shared files (`TODO.md`,
`PARITY.md`, `leticl.asd`, `package.lisp`) are the orchestrator's, and a strand
that needs one changed asks for it.

### S0 — decomposition ✅ **done** (2026-09-19)

**Why.** `head.lisp` (687 lines) and `render.lisp` (552) were the files *every*
strand must touch: ack and the key ladder lived in `head.lisp`, every card and
screen in `render.lisp`. Two strands editing one file cannot run at the same
time, so **as the tree stood the "parallel" strands below all serialized on
those two files** — the DAG would have been a lie.

**What was done.** A pure carve: **no behaviour change and no data-shape change**.
Function forms moved between files byte-exactly (verified: 77 forms in, 77 out,
identical), nothing was rewritten, no dispatch redesigned, and no wire-shaped
value changed representation.

This was **not** a class migration. That is a separate, larger question — "should
the head's own state be classes?" — and it belongs to whichever strand next needs
to grow a piece of that state.

**Where things are now** — the strand briefs depend on this table:

| file | now owns | strand |
|---|---|---|
| `src/head.lisp` (687→292) | the `head` struct, threads, the loop, frame handling, reconnect, lifecycle | S1 |
| `src/render.lisp` (552→178) | the frame **engine**: segment/wrap machinery, `%viewport-lines`, `%render`, `%place-lines`, `%render-and-paint` | S10 |
| `src/cards.lisp` (new, 221) | `item-lines`, `call-lines`, `turn-lines`, `awhen-edit-lines`, `%fold-cells`, `%outcome-style`, and the decision/quit/secret cards | S3 |
| `src/chrome.lisp` (new, 44) | `top-border`, `status-line`, `composer-line` | S8 |
| `src/panes.lisp` (new, 190) | the nine full-body screens (picker, help, status, config, jobs, subagents, repo-todos, todos, peek) | S6, S7 |
| `src/editor.lisp` (new, 273) | the composer (from `keys.lisp`) + the key ladder (`%handle-key`, `%normal-key`, `%submit-line`, `%complete`, `%open-decision`, `%answer-decision`) | S4 |
| `src/commands.lisp` (new, 103) | `*slash-commands*` (from `render.lisp`), `%command`, `%prompt`, `%cells`, `%interrupt`, and the `*cells-*` delimiters | S7 |
| `src/keys.lisp` (219→137) | the terminal **decoder** only (term.rs's tables) | — |
| `src/prefs.lisp` (new, header only) | nothing yet — S5 fills it | S5 |

`leticl.asd` orders them so accessors resolve at compile time: `head` comes after
everything it does not need and before everything that reaches through it; `render`
comes after the files it composes.

**Acceptance, as measured** (not asserted):

- **Gate 1**: `sbcl --script run.lisp test` — **172/172**, unchanged.
- **Gate 2**: every carved file pushed to the running head
  (`pid 3567952`), `gate: stdout=ok rows=63/63 cols=210/210` after each, **0
  failures**.
- **Byte-identical**: a battery of 27 pure render calls against fixed inputs
  (wrap, markdown, every `item-lines` kind, `call-lines`, `turn-lines`,
  `help-lines`, the panes, the chrome, the composer, the command registry) —
  **26 identical, 0 real diffs**. The one difference is `status-screen-lines`,
  which reads the *live* session (seq/items/usage moved between captures) and is
  expected to; `--screen` itself cannot be byte-compared because the transcript
  grows during the test.
- **Warnings went 5 → 3** (the survivors are vendored `yason`'s and a
  pre-existing `type` shadow), because the new order resolves `*slash-commands*`
  and `*stdout*` at compile time.

**Follow-ups S0 surfaced, for whichever strand touches them:**

- `%normal-key` binds a variable named `type`, shadowing `cl:type` (the remaining
  `TYPE` warning). A one-word rename; left alone here because S0 moves code and
  does not edit it.
- `eval-when`/`require` stay skipped by `--file`, so `sb-concurrency` must be in
  the image already — true for `bin/leticl-head`, and noted for a fresh image.

---

### S1 — honest wire ✅ **done** (2026-09-20, commits `164475a`, `42fead7`)

What was wrong rather than missing: `PARITY.md` §2.

- [x] **P1** **the head acks.** `run-loop` drains, classifies each frame
  (`:rendered` / `:filtered` / `:control`, the disposition `driver.rs:31` uses),
  **paints**, and then acks the last seq **read** with the counts. The seq is the
  last one read and never the last one drawn — that is what lets a head filter
  freely: it acknowledges what it consumed. `%handle-frame` returns the
  disposition; `apply-event`'s `:dirty` is the classifier for events.
  **Witnessed on the wire** (`{"frame":"ack","seq":2,"rendered":2,"filtered":0}`)
  by acting as the daemon — the head's writes are otherwise unobservable: we
  cannot ptrace it and the daemon does not log frames.
- [x] **P44** **settings on attach.** `ServerFrame::Settings` is only ever sent in
  reply to a request, so a head that never asked had none and the header fell
  back to the `Hello` model for ever. Sent from the **hello handler**, which
  covers attach, switch and reconnect with one send — a `Switch` lands as a
  hello. The reply no longer opens the pane (or `/config` would pop up at every
  attach), so `/config` asks *and* opens.
- [ ] **P2** the **dead frames**: `/resync` (never sent, so §M6's drills only test
  the daemon-initiated path), the **peek** command and its unreachable `:peek`
  screen, the `list_todos` bootstrap read, and `resume_session` from the picker.
  Files: `head.lisp`, `protocol.lisp`. **Not done** — carried to the next pass.

**Two more bugs of the same shape were found by measuring while doing P44**, both
now fixed: `config-lines` read `:name` where `SettingRow` carries `key`
(protocol.rs:214), so the config pane printed `NIL` as every setting's label;
and `%model-name` read the *global* `*head*` instead of the session handed to it,
which the new test caught.

**And the reason a push kept killing the head.** A render error runs on the MAIN
thread, where `--disable-debugger` means *quit*, so one bad row cost the session.
Three doors closed: `%render-and-paint` is guarded (a failure paints itself, and
a good frame clears the flag, so a fix needs no restart); a **paint lock** that a
push holds for the whole eval and a frame holds for the whole frame, so a
definition cannot land under an in-flight call; and `--tree` pushes the
lock-defining files **first** (`render`, then `hack`), because a mechanism cannot
protect a head that does not have it yet. Verified on a purpose-built old image —
lock `UNBOUND` → push → `BOUND`, `render=ok`, survived.

**Live**: the header on the operator's head now reads `deepseek/deepseek-flash`
(the truth) instead of `qwen-3.8-27b`; `head-settings` holds 38 rows; the paint
lock is bound; `gate: render=ok`. Tests 176 → 178.

### S2 — engines ✅ **P3, P4, P6 done** (2026-09-20)

`render-diff` is on edit cards, `highlight-lines` is in code fences, and
`src/progress.lisp` is ported. **P5 (sidediff) and P7 (cluster-aware width) are
not done.** See the commit for what each carries; tests 207 → 254.

Ported and disconnected — `PARITY.md` §2.4, §2.5, §3.9.

- [ ] **P3** `render-diff` **onto edit cards**: Myers hunks, context, line
  numbers, word emphasis. 488 lines already written and called from nowhere; the
  screen shows a naive before/after block instead. This is the diff the operator
  asked for twice.
- [ ] **P4** `highlight-lines` **into markdown code fences** (158 lines plus the
  rano shim, called from nowhere, so fences are never coloured). Degrade to
  uncoloured with no `.so`.
- [ ] **P5** `sidediff.lisp` — two-panel before/after, on when the pane is wide
  enough (`diff_split`).
- [ ] **P6** `progress.lisp` — the rate/`thousands`/duration vocabulary.
- [ ] **P7** cluster-aware `width.lisp` (ZWJ, combining, regional pairs).

**Live**: push, then `--screen` on a session with an edit in it and read the diff
out of the capture.

### S3 — cards ✅ **P8–P13, P45, P46 done** (2026-09-20)

The item-id maps: a settled row keeps its duration, its diff and the decision
that gated it, keyed by ITEM id. **P13 (the rest of the card vocabulary), P45
(`deny_and_tell`'s note) and P46 (a refusal says its reason once) are not done.**
Tests 374 → 391.


The biggest visible gap — `PARITY.md` §3.1. Three of its rows are **one** project:
a value keyed by **`item_id`** that survives the live card being taken over by the
transcript row. The call id cannot be the key (it is round-positional — see the
`call_targets` comment, `app.rs:806`).

- [ ] **P8** `call-ms` (duration on a settled row) and `call-edits` (the diff
  after the call settles), both seeded from the snapshot so a restart does not
  lose the change.
- [ ] **P9** `call-decisions` — the oracle's brief and reply on a settled row.
- [ ] **P10** `call-targets` — the call's display target, replaced wholesale per
  round, never keyed on the id alone.
- [ ] **P11** settled decision rows rendered in the transcript.
- [ ] **P12** warnings/notes **interleaved where they happened** (anchored to the
  row count), not pinned to the bottom.
- [ ] **P13** the rest of the card vocabulary: raw-calls fold (`ctrl-x`),
  thinking header/reasoning decoration, turn footer (state/usage/timings), user
  timestamp, queued prompts rendered in the body.
- [ ] **P45** `deny_and_tell` **can be told something** (`PARITY.md` §7.5). The
  words ride after the option id the way a glob does after `allow_always`, travel
  as their own `note`, and become the decision's basis — quoted and attributed,
  because a sentence the model reads as the *harness's* reasoning is one it
  argues with and one it reads as the *operator's* is an instruction. A
  `deny_and_tell` with nothing typed says exactly that plus how to give one.
  Today `make-answer` takes `(req-id option-id &optional pattern)` and the card
  never says where words would go. Needs a `note` on the Answer frame (added,
  defaulted — no protocol bump) and the card to name the affordance.
- [ ] **P46** **a refusal says its reason once** (§7.6). Three places said the
  same paragraph; two of them now check whether the text is already below them.
  Two bounds, both of which matter: **short reasons are left alone** (cheap to
  repeat, and a short string can match below by coincidence), and the card
  compares on the reason's **first line**, because `why` is a paragraph while the
  payload arrives pre-split — a whole-paragraph containment *"passes review and
  never fires"*. Depends on P8–P10 having a place to put the reason.

### S4 — editor ✅ **done** (2026-09-20)

Multi-line (`alt+enter`), a kill ring with `ctrl-y`, `ctrl-z` undo batched by
word, a paste ledger (five lines or more collapses to a marker and still sends
whole), and `esc esc`. Tests 301 → 325.


`PARITY.md` §3.2; the reference's editor is 1,090 lines, this one ~70.

- [ ] **P14** multi-line prompt (`alt+enter` — alt is decoded and unhandled).
- [ ] **P15** kill ring + **yank** (`ctrl-y`); kills exist, yank does not.
- [ ] **P16** **undo** (`ctrl-z`), word-batched, kills as their own steps.
- [ ] **P17** **paste ledger** — ≥5 lines collapse to a marker, sent whole.
- [ ] **P18** `esc esc` interrupts; a bare `esc` returns to following the stream.

### S5 — prefs ✅ **done** (2026-09-20)

`~/.config/leticl/head.toml`, read at startup and written when a fold changes;
unknown lines and comments survive a save. **A PLIST, not a struct**, because
`defstruct` is skipped by `--file` and a struct could never reach a running head.
Tests 273 → 301.


`PARITY.md` §3.8. Folds and diff shape die with the process today.

- [ ] **P19** `prefs.lisp` — `~/.config/leticl/head.toml`, the flat
  `key = "value"` subset, unknown keys and comments survive a write.
- [ ] **P20** folds + diff shape + raw-calls persisted, read at start.

**Live**: `/think`, quit the head, restart, `/think` is still off.

### S6 — panes ✅ **P41, P42, P21, P22, P23, P27 done** (2026-09-20)

Panes scroll (one offset, counting from the TOP — the opposite polarity to the
transcript's), the todos pane draws its items with org's roll-up and cookie and
unfolds them, and `/mode` and `/models` open pickers built from the daemon's own
`SettingRow.choices`. **P21 (config editable in place), P24 (subagent output),
P25 (job output), P26 (promote) and P27 (mouse click) are not done.**
Tests 391 → 456.


`PARITY.md` §3.5.

- [ ] **P21** the **config pane becomes editable in place** and writes prefs
  (today it is read-only and says the daemon owns the list).
- [ ] **P22** **mode picker** — a real list from `SettingRow::choices`, not a name
  to copy.
- [ ] **P23** **models picker** — same machinery.
- [ ] **P24** **subagent output view** (Enter on a row), spilling to a file when
  long.
- [ ] **P25** **job output** (`/job`, `--offset N`) — the pane counts bytes and
  cannot show them.
- [ ] **P26** **promote** the running command to the background (`ctrl-o`).
- [ ] **P27** **mouse click** picks the picker row under the pointer, guarded by
  the rows the frame actually drew.

> **P44's rows are a prerequisite here.** The mode and models pickers (P22, P23)
> read the settings rows, and today the head has none until `/config` is opened.
> P44 lives in **S1** because its send site is `head.lisp`; S6 must not start the
> pickers until it has landed.

- [ ] **P41** **panes scroll** (`PARITY.md` §7.1). Every pane drew
  `rows.truncate(room)` and the scroll keys were *swallowed* while one was open —
  right that the view underneath must not move, and it left the pane itself unable
  to move. `leticl`'s own TODO.md is 98 rows, so on a 40-row terminal most of it
  is unreachable and the ↑↓ cursor can walk into rows never drawn. One scroll
  offset for all panes (only one is open at a time), with the cursor scrolling
  itself into view. **Two traps, both from the reference's own test:** the
  polarity is the *opposite* of the transcript's (`head-scroll` counts back from
  the **bottom**, a pane's offset counts hidden above the **top** — copying the
  first makes PageDown a no-op that looks exactly like the bug it replaced), and
  a pane's row indices and the repo's are **different lists** (the pane's starts
  with a title and the model's live section).
- [ ] **P42** **the todos pane, rewritten** (`PARITY.md` §7.2) — the largest item
  in this strand, and every part of it is measured from the operator's own words
  in the reference's commits. Ours draws the model's live list with marks, then
  the repo file as **flat dim lines**: no nesting, no roll-up, no paint, no
  detail, no re-read. The rewrite is of `todos-lines` and `repo-todo-lines`, both
  already in `panes.lisp`:
  - **items are drawn**, nested under their heading — the reference's pane drew
    one line per `## ` heading and never showed the queue at all;
  - **org's roll-up and org's cookie**: *every child done makes the parent done;
    any child started makes it started; otherwise open* → `[x] Phase 0 — repo
    [2/2]`. A heading with **no** checkboxes under it gets neither box nor cookie
    (an empty section is one nobody has filled in, and in a real TODO.md that is
    every prose heading — claiming it as finished work is a lie about the repo);
    `###` owns its own items;
  - **painted by state** — done green, doing yellow, **open left plain**, because
    open is the majority and colouring the majority spends the signal the other
    two carry;
  - **detail kept, enter/tab unfolds** — the lines under a checkbox were being
    *thrown away*, so a pinned-dependency item read as a sentence cut in half. A
    folded item that has more says `···`; one that does not, does not;
  - **re-read when the file changes** — `stat` per draw on `(mtime, len)`, not a
    watcher (a descriptor, a thread and an event routed into a head whose design
    is one loop over one channel, for a pane drawn only while open) and not mtime
    alone (second granularity misses two writes in one second). This file is
    edited exactly while somebody is looking at it.
  - **Four traps** the reference hit, all of which we would hit too: the cursor
    cannot key off *having a mark*, because a heading carries its roll-up as a
    mark (the row needs an explicit `item`); the **indent must be separate from
    the text**, because the indent belongs before the mark and the mark is what
    gets painted (baked together it renders `[x]     Phase 0`); a **blank line
    closes an item**, or prose attaches to the previous item and two items a blank
    apart merge; and painting a box whose colour code is *empty* must not emit a
    bare `ESC[0m` — on the most common row in the pane — so assert the **escapes**
    in the test, not the glyphs, which is the only way that one is visible.

### S7 — commands (needs S6)

`PARITY.md` §3.4. The first four are bindings onto what S6 built; the last three
are features with their own protocol surface and screens — **L each**, not
binding work.

- [ ] **P28** `/verbosity` (terse/normal/loud) and the filter counts behind it.
- [ ] **P29** `/models` + `/default-model`.
- [ ] **P30** `/gate` — the decisions, and ruling on them afterwards.
- [ ] **P31** `/supervise` — the guard model answers before the operator does.
- [ ] **P32** `/flowy` — the seat on the fabric.

### S8 — chrome ✅ **done** (2026-09-20)

The boxed composer, the alarm line, the hint bar, notice TTL, stall detection,
and the money meter. Tests 325 → 374.


`PARITY.md` §3.6. The most visible structural difference: the reference's
composer is a box with a title, the wiring on its bottom edge, an alarm line and
a hint bar, and the body carries a gutter. This one draws `› `.

- [ ] **P33** boxed composer (`╭╮╰╯`), title, wiring on the bottom edge, and the
  unboxed fallback when the screen is too short.
- [ ] **P34** the body gutter.
- [ ] **P35** hint bar + the alarm line (only the counters that are not zero).
- [ ] **P36** notice with a **TTL**, and **stall detection** (the head says when
  the daemon has gone quiet).
- [ ] **P43** **the money meter** (`PARITY.md` §7.3). `Usage.cost_micros_usd` is
  `Option<u64>` on the wire (`#[serde(default)]`, so an older daemon's frame still
  reads) and we ignore it. The reference sums what it has watched finish and puts
  the total **beside the token count in the header**, where "what is this costing
  me" is already being asked:
  ``` 
  $0.0421   128k ctx · 51% cached · 32 tok/s
  ```
  Three rules, each a version of one this repo already holds: `None` adds nothing
  **and lights nothing** (*"free and unpriced are both 'no number', and `$0.0000`
  on every local header would be noise"*); a `spent_seen` flag distinguishes *free,
  so nothing to show* from *metered, nothing finished yet* — the same "a number
  nobody took" rule as the cache percentage; and **the total belongs to the
  conversation, not the head**, so a session switch clears it, because carrying one
  session's bill onto another's header is wrong in the direction that costs money.
  A head that attached late shows only what it watched, and that is the honest
  answer rather than a total that is quietly too low.

### S9 — bindings ✅ **done** (2026-09-20, with P26 promote)

`PARITY.md` §3.3. Cheap, but strictly **after** the features: a chord bound to
nothing is worse than no chord.

- [ ] **P37** `ctrl-r` `ctrl-t` `ctrl-x` `ctrl-s` `ctrl-p` `ctrl-g` `ctrl-q`
  `ctrl-o` `ctrl-y` `ctrl-z`, `esc esc`, `alt+enter`, `esc`→follow, and the
  completions line. Files: `head.lisp` only — which is why this is a **separate
  strand**: it can only run once every other strand's `head.lisp` edits are in.

### S10 — render architecture ✅ **measured, and NOT built** (2026-09-20)

Measured on the operator's own head — a **2273-item** session at 227x61, which is
the case the question is about:

| what | 50 calls | per call |
|---|---|---|
| a full `%render` | 45 ms | **0.9 ms** |
| `%viewport-lines` alone | 15 ms | **0.3 ms** |

**So the cache is not built, and that is the answer rather than a deferral.** The
loop paints at most once per 30 ms tick and only when dirty, so 0.9 ms is ~3% of
the budget; a streaming turn at 30 deltas/s would spend ~2.7% of a core. The
reference needed its incremental-history machinery because it measured *135 full
rebuilds of an 89-row session*; this head walks the transcript backwards and
**stops as soon as it has the lines the viewport needs**, so its cost is bounded
by the SCREEN and not by the session — which is why a 2273-item session costs the
same as a 20-item one.

The measurement is written down because it is the reason for the decision: if a
future change makes a *visible* item expensive (a huge markdown block, a diff with
thousands of rows), the bound moves from the screen to that item, and the number
to beat is above.

### S11 — docs ✅ **done** (2026-09-20)

- [x] **P39** `PLAN.md` said protocol **18** in four places and gave the eval
  socket path as `$XDG_RUNTIME_DIR/leticl/tui-<pid>` — the code is **20** and
  `$XDG_RUNTIME_DIR/tui-<pid>.sock`. Both fixed to the code, with the v19/v20
  frames named (`withdraw_prompts`, `stop`) and D1 saying the version is read off
  the wire and bumped when the daemon bumps it, never negotiated here.

  **Recounting found two more errors nobody had noticed**, which is the point:
  the client-frame list said 24 and there are **26**, and the session-event list
  said 27 and there are **28** — it was missing `tokens_generated` entirely. Both
  lists are now counted from the enums with a note saying a count in a document
  is a claim about code that moves.

- [x] **P40** `PARITY.md` **stays**, as the measurement rather than a work list.
  The recommendation and its argument are at the end of that file: a closed item
  in `TODO.md` says nothing about what it closed on, while `PARITY.md` carries a
  pinned commit and a file:line per gap — folding the done rows in would delete
  the evidence and leave the conclusions, which is the shape of claim this repo
  exists against. Re-measure it against a new commit when the reference moves;
  do not edit it line by line, which is how a measurement becomes a memory.

---

### What is deliberately NOT here

`PARITY.md` §4. Do not "fix" these into line with the reference:

- **`ctrl-c`'s meaning** — interrupt a turn, else the quit card, and `make-stop`
  travels the wire rather than killing a pid. Built to an operator request on the
  v20 shape; the help text must say so, which is P37's business, not a change.
- **`/subagents` and `/todos` as commands** — typing is how a script and a model
  drive a head. Add the chords (P37); keep the commands.
- **The render gate, `--screen`, and the eval socket** — leticl is *ahead* here.
  The reference cannot be patched while it runs.
