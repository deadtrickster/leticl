<!-- abstract: The reserved status row: the reference's own words and the exact sites in this head, measured and reverted because six ladder assertions move with it. -->

# The reserved status row — measured, reverted, and how to finish it

**The finding, in the reference's own commit message (`516c5a4`, 2026-10-14):**

> The operator, 2026-10-14: *"it showed me \\"resync...\\" in violet and \\"reading job output\\" very
> nice! but they were on their bottom lines and conversation was jumping back and forth. can we show
> such things say on the bottom prompt input border? [...] Or! where Responding... line lives - it is
> preallocated and fixed"*.
>
> ... The notice was a row of its own above the composer, **counted by the fit ladder as `notice`, so
> each one took a line from the transcript when it appeared and handed it back NOTICE_MS later.** With
> a one-second poll that is a jump every second.

**This head has exactly that shape**, so the fix is the reference's:

`src/chrome/composer.lisp` — the row above the box is ALREADY reserved and always drawn
(`turn-report-row`, called at ~:493, whose own comment already states the axiom *"a row that came and
went with the turn would move the transcript on every exchange"*). The transient should ride it:

    (or (let ((transient (and (alarmed-p head) (notice-line head cols))))
          (and transient transient))          ; both return a LIST OF ROWS; shapes match
        (turn-report-row head cols))

`src/render/history-cache.lisp` — three places still count them as ladder rows:
  · `%fit-ladder` (~:1207): `(if stall-p 1 0)` and `(if notice-p 1 0)` in the `n`, and the two drop
    arms in its `cond` (`(notice-p (setf notice-p nil))`, `(stall-p (setf stall-p nil))`);
  · `chrome-top` (~:1516): `(- cursor (if notice-p 1 0) (if stall-p 1 0) card-rows)`;
  · the draws (~:1615): `(when stall-p (row (first stall)))`, `(when notice-p (row (first notice)))`.

**Why it was reverted rather than finished**: six assertions in the fit-ladder test
(`grep -n 'then the notice' tests/tests.lisp` — around :18036-18065, plus one at :12605) assert the
DROP ORDER across widths: at 6 rows *the notice is still there*, at 5 *then the notice* goes and *the
stall outlives it*, at 4 the stall. With the transients no longer rows, none of that is true — they
are always there while the box is, and what is given up first is a different question. **Those
assertions are the work, not an obstacle**: they were written from `app.rs:5206-5208`, and that quote
is the PRE-`516c5a4` order, so the test's own authority has moved.

**And the lesson this cost me**: the row I was handed said *"one condition in `%usage-numbers`"*-style
precision — but for this one, believing the filed description (and the test's quoted reference line)
without reading the reference's commit is what would have produced a wrong change. The commit message
named the exact defect, the operator who reported it, and the day.
