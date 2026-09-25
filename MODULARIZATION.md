# MODULARIZATION — which parts of leticl can become libraries, measured

**Surveyed 2026-09-25.** The question: which modules can be isolated into
`libs/<name>/` with their own `AGENTS.md` and `DESIGN.md`.

**A survey, not a plan of record.** Nothing here has been started. The order is
*what the arrows already say*, not taste. PLAN.md §6 is the architecture; this is
what the code's own references say about where its seams really are.

---

## 0. How this was measured, and how to falsify it

    scripts/module-deps.lisp    the graph — READ the forms with SBCL's reader
    scripts/module-deps.lisp F  what file F needs, by name and count

**Four earlier versions of this tool were wrong, and every one of them was wrong
silently.** They are worth recording, because the failure mode is the point: a
dependency graph that is quietly wrong is worse than no graph, and each of these
produced a *plausible table*.

1. **Tokens instead of call positions.** `(let ((run …)))` in the hidden-run walk
   is a local variable; it was reported as a call to `run` in `head.lisp` from
   three files that never touch it.
2. **A case bug in the filter.** The reference set kept the written case and the
   local set was uppercased, so the subtraction removed nothing — the filter
   looked like it worked while every collision went on being an edge.
3. **`)` + `(` read as a binding pair.** In `(f (g x) (h y))` the second call
   follows a `)` and a space, so every function called after another form was
   classified as a local — which then *deleted real edges*, including
   `keys.lisp → socket.lisp`.
4. **Heuristics are the wrong instrument for Lisp.** Hence the current tool: it
   reads each file with `read` and walks the tree, so a call position is a call
   position and a binding list is a binding list.

**Getting *that* to run took five fixes of its own**, each measured rather than
guessed, and they are in the file's comments so the next person does not repeat
them: stub packages do not make `alexandria:foo` readable (a package must know
its symbols); `set-syntax-from-char` does not disarm a macro character; interning
a symbol is not making it *external*; a symbol read into `:keyword` is not `eq` to
its `CL-USER` twin, so the first working read produced a table of 27 zeros; and a
`defun`'s **lambda list** is not a call list — walking it made the first parameter
of every function in the tree look like a reference.

**What this still cannot see**, and it is why the claims that matter were also
checked by grep:

- **Macro-expanded coupling.** An edge through a macro that expands into another
  file's function is invisible.
- **Run-time coupling through the eval socket.** `hack.lisp` pushes arbitrary
  forms into a live image, so *any* file can reach *any* symbol at run time. That
  is the point of the head and no static graph can show it.
- **Coupling through shared globals.** Two files that both `setf` the same
  variable are coupled; the graph sees the reference, not the assignment.

---

## 1. The measured graph

`src/`, 27 files. **referenced_by** is how many files use something this file
owns — the number that says how hard this is to move. **needs** is how many
files it uses.

| file | lines | referenced by | needs |
|---|---:|---:|---:|
| `width.lisp` | 466 | **11** | **0** |
| `head.lisp` | 1821 | 10 | 16 |
| `chrome.lisp` | 2072 | 9 | 9 |
| `render.lisp` | 1721 | 9 | 9 |
| `cards.lisp` | 3873 | 8 | 11 |
| `session.lisp` | 2624 | 8 | 9 |
| `json.lisp` | 125 | 7 | **0** |
| `panes.lisp` | 2750 | 7 | **12** |
| `progress.lisp` | 409 | 7 | 1 |
| `commands.lisp` | 1395 | 6 | 10 |
| `editor.lisp` | 2315 | 6 | 11 |
| `protocol.lisp` | 740 | 6 | 1 |
| `cells.lisp` | 524 | 4 | 2 |
| `prefs.lisp` | 933 | 4 | 4 |
| `socket.lisp` | 123 | 4 | 1 |
| `term.lisp` | 177 | 4 | **0** |
| `diff.lisp` | 511 | 2 | 2 |
| `highlight.lisp` | 360 | 2 | **0** |
| `store.lisp` | 327 | 2 | **0** |
| `hack.lisp` | 259 | 1 | 4 |
| `keys.lisp` | 198 | 1 | 1 |
| `markdown.lisp` | 1132 | 1 | 3 |
| `sidediff.lisp` | 376 | 1 | 4 |
| `wire.lisp` | 33 | 1 | **0** |
| `demo.lisp` | 26 | 0 | 2 |
| `package.lisp` | 244 | 0 | **0** |
| `replay.lisp` | 316 | 0 | 9 |

**The shape in one sentence.** Six files need **nothing** from the rest of the
tree (`width`, `json`, `term`, `store`, `wire`, `highlight`, `package`), and the
interesting ones are those with a high in-degree *and* a near-zero out-degree —
used widely, depending on little. `width.lisp` is the pure case: 11 files lean on
it and it leans on none.

**And `head.lisp` is not the module people assume.** Its in-degree is 10, not
"everything", because a `head` is passed around as a *value* and most files touch
one or two accessors. It is still the application — it owns the struct, the
threads, the mailboxes, the paint loop and the resize poll — but "everything
depends on head" was a guess, and the measurement says ten files do.

---

## 2. Four inversions, and they block more than they cost

An inversion is a low-level file depending on a high-level one. In one image with
one package they are invisible; separate a lib and each becomes a cycle.

### 2.1 `wrap-segments` — a TEXT helper living in the FRAME engine

    defined   src/render.lisp
    called by src/cards.lisp (11 mentions), src/panes.lisp (7), src/render.lisp itself (7),
              src/markdown.lisp (4), src/width.lisp, src/diff.lisp, src/sidediff.lisp

`render.lisp` is the frame engine — it composes cards, chrome and panes into a
screen. `width.lisp` is the layer everything *measures* with. A wrapper in the
composer, used by the measurer, is backwards. **This one inversion is what makes
the text cluster look coupled to the renderer**, and moving two functions fixes
it: `wrap-segments` → `width.lisp`, and `%line-blank-p` → `width.lisp` (it asks
whether a line renders to nothing).

### 2.2 The call-facts recorder is in `cards.lisp`, and the MODEL calls it

    defined   src/cards.lisp
    called by src/session.lisp : %adopt-call-facts, note-call-started,
              note-call-finished, note-call-target, note-call-decision,
              note-answered-call, note-assistant-targets, note-snapshot-answered,
              note-snapshot-targets, %payload-lines

`session.lisp` folds what the daemon sends into state; `cards.lisp` draws a tool
call. That the model calls the *renderer* to record a call's start and finish is
why `session.lisp` looks inseparable from the UI. The `note-*` family belongs
with the state it records.

### 2.3 An fd-polling primitive lives in the protocol's socket module

    defined src/socket.lisp : wait-for-input
    called by src/keys.lisp

`wait-for-input` asks whether a stream can deliver input
(`sb-sys:wait-until-fd-usable`). It is an **I/O primitive** inside the module
whose job is discovering a daemon's socket. One function, one-line move — and it
is the whole of `keys.lisp`'s one outbound edge. *(This is the edge heuristic
version 3 deleted; it is the reason that version was discarded rather than
patched.)*

### 2.4 `%send` — `panes.lisp` reaching up into `head.lisp`

    src/panes.lisp → head.lisp : %send

A screen composing a frame and *writing to the daemon* is a rendering module that
sends. Same class as 2.2, one symbol instead of ten.

### Not an inversion, and it should stay one file's problem

    src/prefs.lisp → session, cards, commands, chrome, diff, head (4 files, 4 needs)

`prefs.lisp` (933 lines) touches four modules because *applying a setting* means
calling the module that owns the thing being set. **It is not an inversion, it is
what a settings layer is.** Inverting it would spread the prefs vocabulary across
six files to make one file's graph prettier. Expect it to stay the most
cross-cutting non-head file in the tree.

---

## 3. The extractable libraries, in dependency order

Line counts are the files that would move. "Needs" is the measured leak **after**
the inversions above are fixed.

### 3.1 `libs/leticl-units` — width + progress — 875 lines — needs NOTHING

    files   src/width.lisp (466)  src/progress.lisp (409)
    needs   nothing outside the pair
    inside  progress → width (string-width ×1, truncate-to-width ×2)
    extern  none

The cleanest extraction in the tree. No globals from the head, no clock —
`progress.lisp`'s own header makes that a rule (*"No clock is read inside this
module. Elapsed time is a parameter"*) — and the inputs are numbers and strings.
**11 files lean on `width` alone**, so this is also the first lib that forces the
package decision in §5.2.

**One decision:** one lib or two. They split cleanly (`progress` reaches `width`
by three calls), but both are *"a measurement, said in the way a person reads
it"*, and two 450-line libs is more ceremony than the split earns. **Recommend
one**, with the two files as its two modules.

**`AGENTS.md` would say:** what `string-width` guarantees (clusters, not chars —
a ZWJ emoji is one cell of two; escapes are zero); that `%width-between` is the
hot leaf and must stay allocation-free; that a caller needing columns must never
use `length`; and that nothing here may read the clock.

**`DESIGN.md` would say:** why the width table is hand-written ranges rather than
CFFI `wcwidth` (startup, and `wcwidth` is per-codepoint where the unit is a
cluster); why the bar is three-valued; the sub-cell-eighths argument (*"a
20-column bar over a 40,000-token prompt advances one cell per 2,000 tokens"*);
and progress.lisp's three refusals (no digit separator, rate over computed
tokens, an unmeasured number is absent rather than zero).

### 3.2 `libs/leticl-wire` — json + wire + protocol + socket — 1,021 lines — needs NOTHING

    files   src/json.lisp (125)  src/wire.lisp (33)
            src/protocol.lisp (740)  src/socket.lisp (123)
    needs   nothing outside the cluster
    inside  protocol → json (%key-from-wire, json-decode, json-encode-to-string)
            socket → json (json-decode)
    extern  yason (json), sb-posix + sb-bsd-sockets (socket)

**Measured twice, by two methods, and hand-checked:** nothing in this cluster
calls `head`, `width`, `render` or `session`. It is the daemon protocol — frame
constructors, the version constant, NDJSON framing, socket discovery — and it is
the **highest-value candidate in this survey, because it is the part of leticl
that is not a TUI at all.** A second CL consumer (a test harness, a CLI, a
headless client, the fixture builder) could speak protocol 26 without linking a
renderer. `json.lisp` is 7 in / 0 out on its own.

**Include the `wait-for-input` move from §2.3 here** — this lib already owns the
socket, and then `keys` reaches for a socket *primitive* rather than a socket
module.

**`AGENTS.md` would say:** the plist-with-keyword-keys convention (`"session_id"`
→ `:session-id`) and that it lives in `json.lisp` **and nowhere else**; that
`+protocol-version+` is pinned by a test and a change to it is a change to both
heads; that a frame constructor is total (validation belongs to the caller); and
that a new frame needs a version bump while a new defaulted field does not.

**`DESIGN.md` would say:** why frames stay plists at the boundary (PLAN.md §7's
v1 decision); what `wire-error` carries and why (the offending line — a framing
failure that loses the bytes cannot be debugged); the discovery rule
(`$XDG_RUNTIME_DIR/letibot/*.json`); and the version-skew policy.

### 3.3 `libs/leticl-cells` — term + cells — 701 lines — needs `units`

    files   src/term.lisp (177)  src/cells.lisp (524)
    needs   libs/leticl-units : %simple, char-width, plain-columns-p
    inside  cells → term (sync-begin, sync-end)
    extern  sb-alien (termios, ioctl)

The cell buffer (char + interned style), the SGR builder, the diff and full
painters, plus raw mode, the alt screen and the winsize ioctl.

**This is the layer most worth *not* moving casually: `term.lisp` is on the
restart list.** It is where an alien type and a terminal mode are defined, and a
re-evaluated `define-alien-type` is a layout change — the header records it, and
`store.lisp` has the same property. A lib that cannot be live-pushed without a
restart is a lib whose `AGENTS.md` must say so on line one.

**`AGENTS.md` would say:** which functions are safe to redefine in a live image
and which are not (anything touching an alien type or the terminal mode is a
restart); that terminal restore must run on every exit path including a signal;
that `put-segments` is the one writer of the cell buffer.

**`DESIGN.md` would say:** the double buffer and the diff painter, and the
`ESC[?2026` synchronised-output window whose two halves are unprotected in
between (`cells.lisp`'s header already says so); why styles are interned rather
than stored per cell; the measured diff-versus-full-paint cost.

### 3.4 `libs/leticl-store` — store.lisp — 327 lines — needs NOTHING

    files   src/store.lisp (327)
    needs   nothing
    extern  sb-alien (libsqlite3)

The only file that touches the C library. Operator ruling, quoted in its own
header: *"regarding local todo storage - use sqlite as always, not files."*

**Honest assessment: the least valuable extraction here and the easiest.** Nothing
else would use it, so its value is not reuse — it is that it makes the sb-alien
boundary explicit and puts the *restart required* fact in one place with its own
document. It is also the **smallest change with the largest proof**: if the
`libs/` machinery works for a 327-line zero-dependency lib, it works for the rest.

**`AGENTS.md` would say:** that re-evaluating this file in a live image needs a
**fresh process** (a redefined `define-alien-type` faults the image — measured
three times, which is why the file carries a restart note); that
`store-available-p` asks rather than assumes; and that nothing may run before the
sqlite library is loaded.

**`DESIGN.md` would say:** the schema, and why the operator's rows have their own
table rather than sharing the daemon's; the `%sq-*` accessor convention over a
raw alien struct; why a store failure is a return value rather than a condition.

### 3.5 `libs/leticl-text` — highlight + diff + sidediff + markdown — 2,379 lines — needs `units`, AFTER §2.1

    files   src/highlight.lisp (360)  src/diff.lisp (511)
            src/sidediff.lisp (376)   src/markdown.lisp (1132)
    needs   libs/leticl-units : %truncate-cells, string-width, truncate-to-width
            and, TODAY, src/render.lisp : wrap-segments
              (diff.lisp ×1, markdown.lisp ×2, sidediff.lisp ×1)  ← §2.1, move it first
    inside  markdown → highlight (highlight-lines, lang-for ×2)
            sidediff → diff (…), sidediff → highlight (…)
    extern  yason (highlight), sb-alien (highlight)

The text engines. **After the `wrap-segments` move this cluster is clean**, and it
is the biggest — nearly a tenth of `src/`. Note `highlight.lisp` is **0 needs**:
it is a leaf today.

**`AGENTS.md` would say:** that these are **pure functions from strings to
segments** — no clock, no head globals, no socket; that `item-lines` (the head's
dispatcher) must never be called from here, or the lib depends on the transcript
model; and that the highlight table is data, so a new language needs no code
change.

**`DESIGN.md` would say:** why the diff is LCS-over-lines with a word-level
refinement rather than one granularity; why `sidediff` re-diffs its own excerpts
instead of reusing the unified hunks; the implemented markdown subset and what is
deliberately plain text.

---

## 4. What must NOT be extracted, and why

**`head.lisp`** (10 files reference it) — the struct, the threads, the paint
loop, the resize poll. Because the live image is the development environment, a
model hacking a running head reaches *through* it: it is the application, and
there is no lib behind it.

**`render`, `cards`, `chrome`, `panes`** — 10,416 lines with 8–12 mutual edges
each, and the part of the tree most specific to this head: the segment model, the
viewport and anchor arithmetic, the air rule, the fit loop. Extracting them means
inventing a general TUI framework from exactly one implementation, which is how a
framework acquires twenty knobs nobody uses. Their shared vocabulary
(`wrap-segments`, `%line-blank-p`) moves down to `units`; the rest stays.
**`editor.lisp` is the most locked-in file in the tree**: 24 distinct symbols of
`panes.lisp`'s (32 mentions) and **191 mentions of `head.lisp`'s** — sixty of them
`head-dirty`, twenty `head-composer`. That is the composer and the key handler
reaching directly into pane and head state, it is the one internal tangle worth
naming, and it blocks nothing in this survey.

**`replay.lisp`** (0 referenced-by, 9 needs) — it **rebinds every global a frame
reads**, and the `let` over them only works if each symbol is already special in
the pushing image. It is not a module with a boundary; it is a statement about
the image, and its own comment already says why it loads last.

**`prefs.lisp`** — §2's closing note. **`hack.lisp`** — the eval socket, whose
job is to defeat modularity; a lib for that is a contradiction.

**`session.lisp` (2,624 lines, 8 in) is the large file I can see becoming a lib
*after* §2.2** — the protocol-to-model layer, the natural companion to
`leticl-wire`. **Not recommended now:** its ten inbound symbols from `cards.lisp`
are the thing to fix first, and its shape afterwards is not something I can
predict from here.

---

## 5. The costs nobody's file list mentions

1. **`scripts/tui-eval --tree` reads `leticl.asd`** and pushes every src file in
   that file's component order, stopping at the first failure. Split the tree into
   four systems and this must learn to walk them in dependency order — or the
   live-push story degrades, which is the feature the project exists for
   (PLAN.md §1, §8). **This is the largest mechanical cost, and it is paid once.**
2. **One package (`:leticl`, nickname `:lt`) exporting 610 symbols, on purpose**
   — PLAN.md §6: *"a model hacking a live instance reaches everything without
   package imports."* Each lib must decide: its own package that `leticl` `:use`s
   (keeps `lt:` working, adds a real build boundary), or `:use`-ing `:leticl` from
   the lib (a boundary in name only). **Recommend the first**, keeping `:leticl`'s
   re-exports so no caller changes.
3. **Tests.** 597 of them in one 20,218-line `tests/tests.lisp`. A lib with its
   own `AGENTS.md` should run its own tests without the head — otherwise the
   boundary is documentation rather than a fact.

---

## 6. Order of work

Smallest proof first, in dependency order:

1. **`libs/leticl-store`** (327, needs nothing) — proves the `libs/` machinery,
   the `AGENTS.md`/`DESIGN.md` convention, ASDF wiring, per-lib tests and the
   `tui-eval --tree` walk, on the file with no dependents.
2. **`libs/leticl-units`** (875, needs nothing) — the first *valuable* one, and
   the first to need the package decision, since 11 files use it.
3. **`libs/leticl-wire`** (1,021, needs nothing) — highest value; include the
   `wait-for-input` move.
4. **`libs/leticl-cells`** (701) — the first lib with a lib dependency.
5. **§2.1's `wrap-segments` move** (two functions, `render` → `width`), then
   **`libs/leticl-text`** (2,379).
6. **§2.2's call-facts move** (ten symbols, `cards` → `session`) — not required
   by any extraction above; it is the precondition if `session.lisp` is ever to be
   a lib, and the inversion most likely to bite meanwhile.

After 1–5: **5,303 of 25,850 lines** — a fifth of `src/` — live in libraries with
their own documents, and every remaining file depends on them downward.

---

## 7. What I am not confident about

- **The graph is static** (§0). It cannot see macro-expanded coupling or the
  run-time reach of `hack.lisp`, and it cannot see two files coupled through a
  shared global. Each step above is deliberately small enough to back out.
- **`highlight.lisp` uses `sb-alien` and `yason`**, which I noted and did not
  chase — something alien inside a highlighter is unexpected enough to check
  before moving that file.
- **The one-lib-or-two call in §3.1** is taste, argued in the open.
- **I did not measure build times.** The split adds systems to compile and should
  be a one-time cost; that is a claim I did not test.
- **`session.lisp`'s shape after §2.2** I can only guess, and a guess is not
  something to plan from.
- **And the tool that produced all of this was wrong four times before it was
  right.** Every number above was also checked by hand where it decides something
  (`width`, `json`, `store`, `term`, `progress → width`, `keys → socket`,
  `markdown → render`). Treat a row nobody has checked that way as a hypothesis,
  not a fact — including the ones I did not.
