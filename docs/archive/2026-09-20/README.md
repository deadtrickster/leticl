# The first parity effort, as it stood on 2026-09-20

Archived whole, because it is the evidence and not the conclusion. The work that
replaced it is `PARITY.md` and `TODO.md` at the repo root, re-measured from
scratch against letibot `8af671e` for the switch to leticl as the primary head.

What is here:

| file | what it was |
|---|---|
| `PARITY.md` | the first gap assessment, measured against letibot `7564417` (2026-09-20) with §7 added for `82ff650..7564417` and §8–§9 for the screen-comparison rounds 3–5 |
| `TODO.md` | the strand plan (S0–S11, P1–P46) derived from it, and its Phase 7 gates |
| `RANO.md` | how letibot integrates rano, the improvements that review found, and the design of leticl's shim |
| `captures/` | round 3: both heads' transcripts, `tmux capture-pane -e`, 210×63, same session, same instant |
| `captures-panes/` | round 4: every full-body pane on both heads (todos in three states, sessions, subagents, jobs, help, status, config) |
| `captures-pickers/` | round 5: the mode picker on both heads, before and after the card rewrite |

**Why it is kept rather than folded in.** These files say what the reference DID
at a pinned commit, with a file and line for each claim. A work list says what we
meant to do about it, and a closed item says nothing about what it closed on.
Folding the finished rows into the new document would delete the evidence and
leave the conclusions, which is the shape of claim this repo exists against — so
the old measurement stays readable at its own commit, and the new one starts from
the reference rather than from it.

The captures are the part that cannot be reconstructed: they are two heads at one
instant on one session, and that session moves.
