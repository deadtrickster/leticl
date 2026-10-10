# PERF — how a leticl head spends a core, and what it spent it on

The operator's report: **in-turn CPU at 80 % of a core**. This is the diagnosis, the
code review that came out of it, and what was done about it (*Fixes*, below).

**Line numbers in the review are the PRE-FIX ones** — the fixes added lines above nearly
everything they point at. The names did not move.

Everything here is measured on this checkout with SBCL 2.6.0, at the operator's own
frame size (214 x 60), with a live turn synthesised through `%make-head` +
`ingest-snapshot` + `note-call-started` in a **throwaway process** — never against a
running head, for the reason `scripts/perf-lisp.lisp` records at its head: a
benchmark that iterates against the operator's own eval channel wedges it.

## Verdict

It is not the loop, and it is not the terminal. It is the **frame rebuild**, and
in-turn every frame is a full rebuild of the transcript. The chain, four links, each
one measured:

1. **In-turn the frame is rebuilt many times a second.** `%hist-key` puts a clock in
   the cache key — `%hist-live-tick` (`src/render/history-cache.lisp:102`) answers
   `(floor (internal-real-time-ms) +live-frame-ms+)` while a call runs — and every
   committed row or body fill bumps `*hist-generation*` (`src/session/state.lisp:493,443`).
   `%hist-key`'s own docstring says it: *"while a call runs the tick changes ten times
   a second, so EVERY frame is a miss."* So in-turn, frames are cold frames.
2. **A cold frame re-rendered the whole window.** `%item-lines-render` was called
   44-296 times per frame and **never hit** — see finding A.
3. **What it re-rendered was expensive and scales with payload size**, because an
   `item-lines` call on a `tool_result` splits, sanitises and filters the whole
   payload (`%tool-payload-rows`, `src/cards/payload.lisp:66`) and there was no memo under
   it.
4. **Ten frames a second is enough.** Measured per-frame cost, 2038 items, 214x60,
   live turn:

   | payload per tool row | warm frame | cold frame (the in-turn case) | % of a core @ 10 fps |
   |---|---|---|---|
   | 2 lines | 2.4 ms | 3.5 ms | 3 % |
   | 20 lines | 2.6 ms | 4.9-9.5 ms | 5-10 % |
   | 100 lines (~30 KB) | 2.6 ms | 22-46 ms | **22-46 %** |
   | 300 lines (~90 KB) | 3.2 ms | **168 ms** | **168 %** |

   A turn whose screenful holds a source-file read or a `cargo test` tail sits in the
   45 ms row; add a second frame source (each folded row re-scans — finding C) and
   80 % of a core is the expected number, not a surprise. It also explains the
   *feeling*: at 45 ms a frame the head can no longer keep the 100 ms live cadence,
   the 2 ms input sleep stops happening, and scrolling goes sluggish again.

## Code review — the five things wrong

**A. The per-item memo from `feedc9b` never produced a hit. Blocking.**
`item-lines` (`src/cards/note-card.lisp:149`) kept **one** frame per stamp, and the stamp
carries `prefs` (`%item-lines-stamp`, `src/cards/note-card.lisp:107`). Inside a single walk
`item-lines` is called twice per item with **two different `prefs`**:

- `src/render/history-cache.lisp:391` — `(item-lines item cols (head-prefs head))`
- `src/render/history-cache.lisp:396` -> `%row-invisible-p` -> `src/cards/tool-result-card.lisp:351` —
  `(item-lines item cols nil)`

Each alternation discarded the table (`(unless frame ...)` built a fresh hash table),
so no call ever hit again. Measured: **44-48 `%item-lines-render` calls per cold
frame, growing by 2 each frame** — the walk re-rendering rows it had already rendered
on the frame before. With the `nil` normalised to the head's prefs in a bench:
**1 call**, and the frame went 5.3 -> 3.0 ms.

**B. `%hist-key` invalidated the whole cache on a clock. High.**
The docstring already prescribes the cure — *"the fix is not a coarser key — it is the
SPLIT ... a SETTLED PREFIX plus a rebuilt TIP"*. Until that lands, every tenth of a
second of a running call costs a full walk and re-render of the window. This is the
frame-rate multiplier for everything else.

**C. `newest-payload-row-p` recomputed a session-wide scan once per drawn row. High.**
`src/cards/decisions.lisp:227` calls it per folded tool row; it calls
`newest-payload-item-id` (`src/cards.lisp:1323`), which walks backwards from the
newest item asking `%row-openable-rows` -> `%tool-payload-rows` of every candidate.
The answer is the same for every row in a frame. Measured: 43-60
`newest-payload-item-id` calls per cold frame, 86-120 payload splits per frame; and
when **no** row in the session is pageable (`+payload-pageable-lines+` is 2) the scan
is unbounded — 2038-4000 `%row-openable-rows` calls for a *single* scan, about
**47 ms per frame, 94 % of the frame in an `sb-sprof` flat profile**
(`%TOOL-PAYLOAD-ROWS` -> `%FIND-POSITION-IF` -> `SPLIT-STRING` / `FIND` /
`%C1-CONTROL-P`).

**D. `%tool-payload-rows` was recomputed for every reason, including "is this
pageable". Medium.** `src/cards/payload.lisp:66` splits, sanitises (`%without-control`, a
character at a time) and `remove-if`s the whole payload on every call — for the row's
own drawing *and* for the pageability question. A 90 KB payload was re-split two or
three times per frame per row. It is a pure function of the payload.

**E. Stale measurements in the docstrings that justify policy. Medium — house rule.**
`src/render/wrapping.lisp:11-15` states `%render` "measures under 0.1 ms a frame"; measured
here **2.2-2.7 ms** warm at 214x60 (20-30x). `*idle-poll-ms*` (`src/head/op-call.lisp:273`)
claims a pass costs "under 0.001 ms"; measured on an idle live head (pid 2536078):
5158 passes in 10 s at 30 ms of CPU = **about 6 us a pass**, 516 passes/s, about
**0.3 % of a core** (so the 2 ms wait is still defensible — the number backing it is
not). This tree's method is *measure, then write the number down*; these two are
load-bearing and both were wrong.

**F. Minor.** `newest-hidden-run-id` (`src/cards/tool-result-card.lisp:355`, called at
`src/render.lisp:589` **before** the cache test) walks the session backwards every
frame whenever no rung is hiding anything — cheap per item here (about 0 ms at 2038),
but it is an O(session) call on the hit path. `%reading-joined-items`
(`src/cards/hidden-run.lisp:573`) is O(n) per call (1.0 ms at 2038, 2.0 ms at 4000) on the same
pre-cache path: harmless while `*reading-join-prose*` is off, a per-frame O(n) the
moment it is on.

## Optimisation opportunities, ranked by payoff

1. **Fix the memo's context** (A) — it is the difference between "re-render the
   window" and "re-render what changed", and it sits under every other cost.
2. **Hoist `newest-payload-item-id` to once per frame** (C) — measured up to
   47 ms/frame -> about 0.1 ms.
3. **Memoise `%tool-payload-rows`** (D) and keep the payload's line count rather than
   recomputing it to answer "is there more to page".
4. **Split the history cache** (B) — settled prefix plus live tip; removes the walk
   itself from the clock-driven frame.
5. **Re-measure and correct the constants** (E) — and only then revisit the loop's
   2 ms wait, which is 0.3 % of a core and not the problem.

## Fixes — what was changed, and what it measures

**1. The item memo holds a frame per render CONTEXT, not one slot** (`src/cards/`).
`*item-lines-frames*` is a bounded list (`+item-lines-contexts+` 4) searched by the same stamp, so
the walk's prefs and `%row-invisible-p`'s NIL no longer evict each other.
MEASURED, 2038 items, 214x60, live turn, cold frame: **44-296 `%item-lines-render` calls a frame,
growing every frame, became 2**; the frame 5.3 ms -> 2.6 ms. On the operator's OWN head (471 items,
`:read-edits`), A/B inside the live image: **13.7 ms a cold frame with the memo cleared, 6.5 ms with
it holding**.

**2. The signature names what the renderer reads** (`%item-lines-sig`). The suite caught this one:
with the memo finally holding, `retired-warning` failed — *"and gone from the screen"* — because
`%item-lines-render` reads `(getf item :retired)` and the signature was `(tick . body)`. The item is
mutated IN PLACE, so the signature holds the item's own FIELDS (`:retired`, `:ts`) and the body by
reference. `*bound-prompts*`, which `bound-prompt-for` reads by item id, joined the stamp for the
same reason.

**3. `newest-payload-item-id` is answered once per frame** (`src/cards/`). `*newest-payload*`
keys on `(items vector, *hist-generation*)` — the vector alone is not enough, because a row becomes
pageable when its BODY arrives and `fill-item` bumps the generation without replacing the vector.
MEASURED: 43-60 asks per cold frame became 1, and where no row is pageable the scan used to walk the
whole transcript (2038 `%row-openable-rows` calls per ask, 47 ms a frame, 94% of it in an `sb-sprof`
flat profile).

**4. A payload is split once** (`%tool-payload-rows` + `*payload-rows*`). An `eq` hash of payload
string -> rows, bounded at 512. Splitting, sanitising and filtering is pure, and the frame asked two
or three times per row.

**5. The three stale numbers** were re-measured and corrected in place: `render.lisp`'s optimisation
header (0.07 ms -> **2.1-2.6 ms** at 214x60, and it is a function of what is on the screen), and
`*idle-poll-ms*`'s docstring in `head.lisp` (a pass is **~6 us**, not "under 0.001 ms": 5158 passes
in 10 s at 30 ms of CPU on an idle live head = 516 passes/s = **0.3% of a core**, measured on pid
2536078 — the number that justifies the 2 ms wait is right, the two beside it were not).

### The frame after the fix

MEASURED with `sb-sprof` and a live turn, 2038 items, 214x60 — the same harness that measured the
breakdown above:

| payload per tool row | cold frame BEFORE | cold frame AFTER |
|---|---|---|
| 2 lines | 3.5 ms | 2.3-2.5 ms |
| 20 lines | 4.9-9.5 ms | 2.2-2.9 ms |
| 100 lines (~30 KB) | 22-46 ms | 2.2-2.4 ms |
| 300 lines (~90 KB) | **168 ms** | 2.6-2.7 ms |

and it no longer grows with the session either: **2.2-2.9 ms cold and 2.1-2.5 ms warm at 200, 800,
2038 and 4000 items** — so the in-turn cost at ten frames a second is about **2.5% of a core**,
against 45-168% before. `%history-until` is now **0.93 ms on a hit and 0.90 ms on a miss** (it was
0.2 against 11-13): the clock in `%hist-key` still invalidates, and the walk it forces is answered
from the memo, so the miss IS the hit. The pathological shape — a session where no row is pageable,
where one frame made 43 full-transcript scans — went from **46.8 ms a cold frame to 0.2 ms**.

Pushed live to the operator's own head (`tui-eval --file src/cards/`, 179 forms, gate green,
155 ms) and verified there: `:item-memo T :payload-memo T :contexts 4`.

**The suite is green on all of it: 7104 checks, 7104 pass, 0 fail** (`sbcl --script run.lisp test`),
including four new tests that assert the arithmetic rather than the picture — a memo that stops
holding does not fail, it gets slower, so the count of `%item-lines-render` calls IS the assertion.
The same run is what found fix 2: with the memo finally holding, `retired-warning` failed (*"and gone
from the screen"*), which is how a missing input in a signature announces itself.

### What is LEFT, and why it is not a blind fix

**`*hist-depth*` is a session-lifetime high-water mark**, and `%viewport-lines` asks the walk for
`(max need *hist-depth*)` on every miss (`src/render.lisp:1253`). MEASURED ON THE OPERATOR'S OWN HEAD
(471 items, `:read-edits`): a cold `%history-until` at `need` 50 costs **0.2 ms**, a cold
`%viewport-lines` costs **6.0 ms**, and the walk that separates them is **748 items / 1599 lines** —
because one deep walk, once, raised the mark for the rest of the session. In-turn every frame is a
miss, so that is ~6.5% of a core on their session and grows with the mark.

The obvious change — ask for `need` while the reader is at the BOTTOM and keep the mark for a
scrolled reader, who is the one `*scroll-max*` can clamp — is not blindly safe: the mark exists to
stop exactly the scroll-jump and *"row replaced by a compaction"* classes this tree has fought, and
`*hist-bounds*` shrinking under a parked anchor is how the note would come back with nothing to say.
The cure the docstrings already name is the SPLIT (a settled prefix plus a rebuilt tip); until that
lands, this is the largest remaining per-frame cost and it is a design change, not a constant.

## Method, and what was NOT reproduced

Probes live in `/tmp/letibot-scratch-2197601/bench*.lisp` (outside the tree): a head
built in-process, a live turn, and `sb-sprof` where the shape of the cost mattered
more than the milliseconds.

The head attached to the session this was written in was **pid 2197574** (216 items,
`turn-busy-p` T): warm frame 0.84 ms, cold 2.95 ms, 87 frames in 8 s, **2 % of a
core** over 6 s. So the 80 % is not that session at that size — it is the same
mechanism at 2000+ items with fat tool results on screen, which is what the tables
above measure. Live probing was used for short single questions only
(`*loop-passes*`, `*frames-painted*`, one `%render` timing, `/proc` deltas); every
number that needed iterations came from a throwaway process.
