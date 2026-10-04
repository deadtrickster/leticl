# The second parity measurement — for the switch

**Reference: letibot `8af671e` (2026-09-20) — where these files were measured. THE
PIN IS NOW `149edf9` (2026-10-04).** Every claim in these files cites a
file and a line in *that* commit on one side and a file and a line in leticl on
the other — and **of the 854 `file.rs:NNN` citations across all four, 49 are still
exact against the new pin**, 731 have moved, 20 point past the end of a file and 2 at a
path that is gone (all from one structural move: `bin/letibot-tui.rs` went from 759
lines to 11). Read the FUNCTION, not the line; the per-file table and what the move was
are in TODO.md's pin section, and `scripts/repin-check OLD NEW` measures it for any
document. The first measurement is archived whole at
`docs/archive/2026-09-20/`, evidence included; this one starts from the reference
rather than from it.

**Why it exists.** The operator wants to make leticl their primary head. That is a
different question from "how far along is the port": a port is judged by what it
has, and a daily driver is judged by what it *lacks* at the moment you reach for
it. So the question each file answers is not "what is missing" but "what would
stop the operator, and when would they notice".

## The four surfaces

| file | what it measures |
|---|---|
| `keys.md` | the operator's input: every key, every slash command, the editor |
| `wire.md` | the protocol: every frame constructed, sent, handled; every event folded |
| `rendering.md` | what a turn looks like: cards, markdown, diffs, the frame, styles, width |
| `panes.md` | the screens and the head's own state: panes, cards, prefs, lifecycle, the launcher |

Disjoint by construction, so four readers could work at once and nothing was
measured twice or assumed by two of them.

## The method, and its two instruments

1. **Read both sides.** A citation is a pointer, not a specification: the
   reference is a live repo and every line number here is a line at `8af671e`.
2. **Look at the screen.** `scripts/compare-heads` captures both heads with
   `tmux capture-pane -e` — escapes included, because a bold title over a dim
   path and an all-bold header are the same plain text, and a plain diff read
   past that difference for two rounds.

A gap is *closed* when both instruments agree: a test asserts the behaviour, and
the two screens are identical where they should be.

## What a finding must carry

- the reference's behaviour and its citation
- leticl's behaviour and its citation
- a verdict: SAME / DIFFERS (how) / MISSING / DEAD-CODE / EXTRA
- for a gap: why it matters in daily use, the file to change, a size, and **the
  assertion that would prove it closed**

The last one is the point. The first effort recorded strands as done against code
that had never drawn a frame — three panes in it had never rendered at all. A gap
is not closed by a commit; it is closed by a test that fails without it and a
screen that shows it.
