# leticl ↔ letibot: the second measurement, for the switch

**Reference: letibot `8af671e` (2026-09-20) — where this was measured. THE PIN IS
NOW `149edf9` (2026-10-04).** Subject: leticl at the commit each row names.

**AND THE CITED LINES ARE THE OLD PIN'S.** 322 letibot commits and `PROTOCOL_VERSION`
21 → 27 have passed between the two; of the 854 `file.rs:NNN` citations in this set,
**49 are still exact** against the new pin, 731 have moved, 20 point past the end of a
file and 2 at a path that is gone — and those 22 are ONE structural move, not 22 edits:
`bin/letibot-tui.rs` is 759 lines at the old pin and 11 at the new, because the Rust
TUI became a workspace crate. `scripts/repin-check OLD NEW` measures this over any
document; the per-file numbers are in TODO.md's pin section. The first measurement is
archived whole at
`docs/archive/2026-09-20/`, its screen captures included; this one starts from
the reference rather than from it.

The question is not "how far along is the port". A port is judged by what it
has; a **daily driver is judged by what it lacks at the moment you reach for
it**. So every finding here carries the same four things: the reference's
behaviour with a file and line, ours with a file and line, what it costs in an
hour of real use, and **the assertion that proves it closed**.

## The four surfaces

Disjoint by construction, so four readers measured at once and nothing was
assumed by two of them.

| surface | document | what it measures | findings |
|---|---|---|---|
| input | [`docs/parity/keys.md`](docs/parity/keys.md) | every key, every slash command, the editor | 25 |
| wire | [`docs/parity/wire.md`](docs/parity/wire.md) | every frame constructed, sent, handled; every event folded | 25 |
| rendering | [`docs/parity/rendering.md`](docs/parity/rendering.md) | cards, markdown, diffs, the frame, styles, width | 60+ |
| screens | [`docs/parity/panes.md`](docs/parity/panes.md) | panes, cards, prefs, lifecycle, the launcher | 21 |

Counts, as measured: **keys 35 of 38** · **slash commands 36 of 39** ·
**client frames 26 of 29 constructed** · **server frames 11 of 13 handled** ·
**events 24 of 29 folded** · **snapshot fields 10 of 10 ingested**.

## What the two instruments are

1. **Read both sides.** A citation is a pointer, not a specification: every line
   number is a line at `8af671e` — the pin has moved since; see the head of this
   file — and the reference is a live repo.
2. **Look at the screen.** `scripts/compare-heads` captures both heads with
   `tmux capture-pane -e` — escapes included, because a bold title over a dim
   path and an all-bold header are the same plain text, and a plain diff read
   past that difference for two rounds.

A gap is **closed** when both agree: a test fails without the change, and the
two screens are identical where they should be. Two rules the rendering pass
added, paid for by a bad comparison: both heads must be at the **same scroll and
fold state**, and `-e` compares *cell attributes* rather than emitted bytes
(tmux coalesces runs), so byte-level claims belong in a unit test against
`screen-rows-ansi`, never in a capture.

---

## What this measurement found that the first one could not

The first pass measured *surface* — bindings, commands, struct fields — and
concluded the spine was real and the furniture was missing. It was right about
the furniture and wrong about the spine, because a surface cannot show a
function that is called and does the wrong thing. This pass ran the code.

**Four things were broken in a way no feature list would show:**

- **Reconnect and resume had never worked.** A `Hello` without a snapshot — the
  resume-from-the-ring path (`hub.rs:628-652`) — wrote `""` over the session id
  and `NIL` into a `fixnum` slot. The `TYPE-ERROR` was swallowed by `run-loop`,
  leaving the head half-attached: id wiped, settings never asked for, the attach
  clock never cleared, the cat walking for ever.
- **`/mode NAME` closed the connection.** `consented: bool` carries
  `#[serde(default)]`, which accepts a *missing* key and not a present `null` —
  and our encoder writes `NIL` as `null`, so the daemon's read loop broke with an
  `Err` and dropped the socket. Every mode but `allow-all` took that path.
- **The head had nowhere to speak.** Twenty-one write sites of
  `head-status-note` — `resync:`, `bye:`, `detached — reconnecting…`, every
  `say` — rode a row `%render` drew only on a screen too short for the composer's
  box. On every real terminal the head was silent.
- **The walking cat never drew.** `attaching-p` required `(not connected)`, and
  `run` marks connected the moment the socket opens, on purpose. An earlier fix
  in this session made the clause *reachable* and its test set the flag by hand —
  so it passed while the screen stayed blank. **A test that proves the renderer
  and not the predicate is not a test of the feature.**

And a class of quieter ones: folds that write nowhere. `ToolStarted` left a call
reading `proposed` for its whole run; `ToolProgress`'s note was written to a
local plist and lost; `TokensGenerated` assigned where it should take the max;
nothing checked `turn_id`, so a delta for another turn appended to this one.

**The lesson, recorded because it cost this repo twice:** *"S6 panes done"* was
once written against code in which three panes had never rendered at all. A gap
is not closed by a commit. It is closed by a test that fails without it and a
screen that shows it.

---

## Status

Work is landing in five strands on disjoint files. This table is the ledger; each
document carries the detail.

| strand | files | state |
|---|---|---|
| orchestrator | `term.lisp`, `prefs.lisp`, `freeze.lisp`, `scripts/` | the four breakages above, the terminal restore, the prefs guard — **landed** |
| wire | `protocol.lisp`, `session.lisp`, `head.lisp`, `wire.lisp`, `json.lisp` | 20 of 25 — **landed** (`723098a`) |
| input | `keys.lisp`, `editor.lisp`, `commands.lisp` | in flight |
| cards + markdown + width | `cards.lisp`, `markdown.lisp`, `width.lisp`, `cells.lisp` | in flight |
| screens + frame | `panes.lisp`, `chrome.lisp`, `render.lisp` | in flight |
| diff + highlight | `diff.lisp`, `sidediff.lisp`, `highlight.lisp` | in flight |

Deliberately **not** attempted yet, and why:

- **`FetchRow` / the payload window** (`ReadJobOutput`, `JobOutput`, the paged
  row view). The reference added a protocol frame and an overlay for it — a
  418 KB tool result is a logical string that wraps to thousands of display lines
  and `ctrl-t` never reached the end. It needs the wire and a pane together.
- **`--replay FILE.jsonl`.** The reference's head replays a session log with no
  daemon, which is what makes its own screen tests deterministic. We compare
  against a live session instead, which is why the two heads must be nudged into
  the same state by hand.
- **A rendered-row cache** (`hist_lines`). The reference renders zero rows on a
  steady frame; we rebuild the window every frame, measured at 0.46 ms at
  210×63. The recommendation in `rendering.md` is **not to port it yet**: the
  invalidation key would have to include five defvars any eval can change, and a
  screen cache is a second source of truth in a head whose whole contract is that
  redefining a renderer changes the next frame. Port the instrumentation first.

## Divergences that should stay

Argued in full in the four documents; in one line each:

- **Live state lives in `defvar`s, not struct slots.** A layout change is a
  restart, and a restart is the one thing a live-patchable head must not need.
- **The backwards viewport walk** (`%viewport-lines`) instead of a cache — the
  same lever the reference reached for in `fill_backward`, and the reason our
  attach to a 2000-item session is 0.29 s.
- **Nine local slash verbs** (`/subagents`, `/todos`, `/peek`, `/resume`,
  `/promote`, `/models`) the reference reaches only by chord.
- **An unknown verb is forwarded to the daemon**, not refused: the head does not
  need to learn every daemon verb to be useful with it.
- **The eval socket**, which the reference has no equivalent of at all.
