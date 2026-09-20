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

## In flight

- [~] **cards + markdown + width** — `cards.lisp`, `markdown.lisp`, `width.lisp`,
  `cells.lisp`. Priority one is **escape sanitising**: tool output currently
  reaches the terminal unfiltered, and the reference closed that in `f36d927`
  ("a tool's output cannot reconfigure the operator's terminal").
- [~] **screens + frame** — `panes.lisp`, `chrome.lisp`, `render.lisp`. The
  picker opening off your own session; the peek pane's dead cursor; the
  permission card drawing one line of the oracle's five; no fit ladder.
- [~] **diff + highlight** — `diff.lisp`, `sidediff.lisp`, `highlight.lisp`.
  Dead intra-line emphasis; SAPs passed unpinned across the FFI; every visible
  fence re-parsed through the shim on every frame.

## Open, in the order they would stop the operator

- [ ] **T1 · the payload window** (`keys.md` G13, `wire.md` W2/W13,
  `panes.md` G4/G10). A 418 KB tool result is a logical string that wraps to
  thousands of display lines; `ctrl-t` never reached the end of one, and Enter on
  a jobs row posts `/job ID` into the conversation instead of reading it. The
  reference answered with a protocol frame (`FetchRow` / `RowFetched`,
  `ReadJobOutput` / `JobOutput`) and a paged overlay. **Wire and pane together —
  the one item that needs two strands.** Size L.
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
- [ ] **T5 · the ordering of the ladders** — with the session picker open and an
  ask arriving, ↑↓ move the picker; the reference puts the decision ladder above
  the picker (app.rs:3474 before 3508). Size S.
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
