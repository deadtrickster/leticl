<!-- abstract: Measured 2026-10-11: the operator's leticl head held ONE transcript row while the daemon had 184 — a snapshot that is a partial bulk fill, which the head never repairs. A /resync restored it. The reference tracks this as `Bulk`; leticl does not. -->

# "my messages vanish from the transcript" — measured 2026-10-11

Operator's report, on the live leticl head (pid 2155346, session
`s-1791151788256943467`): **their own messages appear and then VANISH from the
transcript** (not scroll off). The head had been restarted ~5 min earlier, right
around a harness auto-compaction.

## What I measured (all on the live head, `scripts/tui-eval --pid 2155346`)

    (length (session-items (head-session *head*)))          => 6
    kinds: tool_result, note, note, note, note, system
    user items                                              => 0
    item ids: leticl-compaction-1, leticl-note-2..5, s-1791151788256943467#t8.0
    session-items-dropped                                   => 0
    session-expected-seq                                    => 59904 (advancing; later 72384)
    *resyncs*                                               => 0

So the head held **exactly ONE daemon row** (`#t8.0`) plus its own local
compaction card and four warning rows. The daemon's store, for the same session:

    sqlite3 ~/.local/share/letibot/sessions.db \
      "select kind,count(*) from transcript_item where transcript_id='s-1791151788256943467#t8' group by kind"
    tool_result 62 | assistant 59 | reasoning 57 | user 8 | system 1     (184 rows)

**The daemon was healthy; the head's transcript was nearly empty.** And the head
was NOT stalled: `session-seq` advanced 59904 -> 72384 while the item count sat
at 6 — events flowed, transcript rows did not land.

## The fix that worked (a workaround, not the cure)

    (leticl::%send *head* (make-resync))    ;; what the `/resync` verb sends

    after 1s:  :n 230  :resyncs 1  :dropped 1152
    user items => 8   (all of them; the operator's messages were on the screen again)

So the daemon's snapshot is FINE (a bounded window: 230 rows held, 1152 dropped);
the head's state was the problem.

## The shape of the defect

The attach snapshot was **partial** — 1 row, `items-dropped 0` — which is what a
snapshot looks like while the daemon is still FILLING a view after a
resume/compaction (`SessionEvent::Filling` exists for exactly this), or
immediately after a `transcript_forked` when the new transcript holds only its
summary row. **leticl has no notion of a snapshot that is not yet complete**, so
it takes the one row as the whole conversation and never repairs it:

- `ingest-snapshot` (src/session/state.lisp:334) REPLACES `session-items` with the
  snapshot's items and believes `items-dropped` at face value.
- the `:transcript-forked` arm (src/session/seq-gap.lisp:318) REMOVES the parent's
  rows and waits for the child's rows to arrive as appends — which, for an
  already-attached head, they did not.
- nothing asks again. `*resync-asked*` is only set for a counted SEQ GAP, and no
  gap was counted (`session-dropped` stayed 0).

**The reference has this notion and leticl does not.** letibot's TUI tracks a
`Bulk` (`crates/tui/src/app/mod.rs` ~1476-1485): *"a bulk announcement the daemon
has not filled yet ... recorded only when a snapshot is ingested"*, and its own
comment says a snapshot's rows are a bulk announcement — a fork, a reseat, a
resume, an import — while a live append is not, so *"the shape of the evidence
separates the two with no threshold."* The reference also carries an anchor
ACROSS the boundary (`Carry`, ~1407-1419) and repairs it after the rows land.

## The candidate fix (NOT yet landed — needs a decision)

The smallest self-healing change: when a `:transcript-forked` lands, OR when a
snapshot arrives whose rows look like a bulk announcement, ask for a snapshot the
way `/resync` does — the head cannot distinguish a fork from a fill, and either
way a fresh snapshot is the truthful answer. It cannot be done inside
`apply-event` (that fold deliberately sends nothing — see src/head/frames.lisp:810),
so it belongs in `%handle-frame`'s event arm beside the job-count logic.

**Do not trust the fork arm's own comment** ("every carried row is published
under the new transcript's ids") without measuring it: in this session they were
not published, or not to this head.
