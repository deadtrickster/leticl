;;;; frame — the frame and the clock: when a snapshot is taken, and when it is stale
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- the frame and the clock ;;;
;;;
;;; **A number the frame computes from the clock is computed and never drawn again.**
;;; The frame is rebuilt when `head-dirty` is set, and only a FRAME or a KEY sets it —
;;; so `*now-ms*`, which the loop sets on every pass, is read by a builder that is not
;;; asked to run. Measured on a scratch head with a 45-second-old running call, from
;;; the shell with no eval in between (an eval POKES `head-dirty` to prove the loop
;;; can paint — `scripts/tui-eval:220` — so a probe that watches freshness keeps the
;;; frame fresh; see HACKING.md, "a measurement that refreshes what it measures"):
;;;
;;;     value  75637 ms -> 78680 ms          (it moves: read from this head's clock)
;;;     glass  Running · 1m19s · 1m19s · 1m19s   (frozen: nothing asked for a frame)
;;;
;;; — the frame is a SNAPSHOT of the clock, kept until an event replaces it. That is
;;; R13's defect one layer above where it was reported: the number was never the
;;; problem, the ASKING was.
;;;
;;; **The fix is not "repaint always".** A head that paints at the loop's rate burns a
;;; core and a terminal to say nothing has changed. It is: ask for a frame while the
;;; frame has a part that is a function of time, and at a rate a person can read.

(defparameter +live-frame-ms+ 100
  "How often a frame with a part that is a function of TIME is rebuilt.

**Tenths of a second, and that is the operator's number rather than a choice of
ours**: a live duration answers *is this moving, and roughly how long has it been —
a live coarse timer would be nice, say 1/10th of a second*, and a figure that churns
every frame is noise that also makes the row impossible to read.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defvar *last-paint-ms* 0
  "When this head last produced a frame, on the monotonic clock.

**The fact the loop needs and the frame cannot carry**: the loop is what DECIDES to
paint, so the loop is what has to know how long it has been since it last did. A
`defvar` rather than a head slot because a struct change is a RESTART in this SBCL,
and nothing about this fact justifies one. Stamped by `%render-and-paint` on every
path, including the failure one — a paint that fell back to the failure frame is
still a frame, and a stamp that did not move would ask for another one immediately,
which is a head spinning on a broken renderer.")

(defun %live-decision (head)
  "The open ask whose DEADLINE the frame is counting down, or NIL.

§1.6's card carries a clock — `expires in 5 min`, `47s left` — and a clock on a card
is a reason to repaint for the same reason a spinner is. It is the one part of this
frame whose *granularity* is not a tenth of a second: see `live-frame-interval-ms`."
  (let ((d (first (session-open-decisions (head-session head)))))
    (and d (numberp (getf d :deadline)) t)))

(defun live-frame-p (head)
  "Is something on HEAD's frame a function of the CLOCK?

Each part named here is drawn from `*now-ms*` or from `internal-real-time-ms` while
the frame is built, so a frame built a second from now would differ with NO event in
between: the composer's spinner and its `· {since}` (`turn-status`), a running call's
elapsed (`%call-elapsed-ms`), the stall row becoming due (`stall-text`), the
carry/filling line's bar and its patience, and an open ask's deadline (§1.6).

**A notice and a pending stop-wait are deliberately NOT here.** They arm their own
deadline and mark the head dirty when a tenth of it passes (`tick-notice`,
`tick-stop-request`), so they already ask for the frames they need; naming them again
would be a second spelling of one rule, and the second spelling is the one that
rots.

**AND THE TURN'S HALF IS `turn-busy-p`, which is the FOURTH place today this was wrong.** It used to
read *generating* or *a call is running*, spelled out — right while the model produces and right
while a command executes, and **FALSE in the gap between them**: the round's generation ends, the
model has not been sent the results, and for that whole window the frame was not clock-driven at
all. MEASURED on the operator's screen — *\"when a tool call starts the responding timer freezes for
a sec\"* — and of course it does: the `Responding · 2m23s` number is a function of the clock, so a
frame that is not rebuilt on the clock cannot advance it, and everything else live in the frame
freezes with it.

`turn-busy-p` asks the question the two clauses were reaching for — *is the turn still working* —
and it is true across the whole turn because it counts a call that has not finished as work."
  (let ((turn (session-turn (head-session head))))
    (or (and turn (turn-busy-p turn))
        (filling-active-p)
        ;; **THE FOLD IS LIVE BY DEFINITION** -- `written` moves continuously, so a frame drawn
        ;; once and never rebuilt is a screenshot of a bar. Named separately from `turn-busy-p`
        ;; because a COMPACTION DURING A TURN is exactly the case the operator sharpened: *"even
        ;; more so for this overruns when we compact in turns"* -- and the turn's own busy state
        ;; would otherwise be the only thing asking for frames while the fold is what is running.
        (compaction-active-p)
        (and *carry-last-done* *carry-moved-at*)
        ;; **A DASHBOARD IS LIVE BY DEFINITION, and this is why the numbers moved only when a key
        ;; was pressed.** The panels draw from series the collector samples on a clock — the very
        ;; same shape as a running call's elapsed, one layer down — so a frame with a dashboard in
        ;; it IS a function of the clock and must be rebuilt on it.
        ;;
        ;; MEASURED, on the operator's screen: *"it doesnt update until i type"*, and the
        ;; mechanism was that pressing a key marked the head dirty and a clock-driven frame was
        ;; never due — so the dashboard was a screenshot until something else asked for a paint.
        (eq (head-mode head) :dash)
        (and (%live-decision head) t))))

(defun live-frame-tenths-p (head)
  "Is any live part of the frame drawn in TENTHS — the rate `+live-frame-ms+` is for?

The spinner, a running call's elapsed and the carry bar all move continuously, so
they want the fastest rate a person can read. **A deadline does not**, and neither
does the stall row: those change once a second at most, so a decision card waiting on
its own clock asks for ONE frame a second rather than ten — the difference between a
countdown and a head burning a core to redraw the same number.

**The turn's half is `turn-busy-p`, for the reason `live-frame-p` gives at length** — with the added
sting that THIS one decides the RATE, so the frozen second the operator reported was not only a stale
number but a frame that had dropped to the idle rate in the middle of a turn."
  (let ((turn (session-turn (head-session head))))
    (or (and turn (turn-busy-p turn))
        (filling-active-p)
        ;; and in TENTHS, because the spinner and the count are read at a glance
        (compaction-active-p)
        (and *carry-last-done* *carry-moved-at*))))

(defparameter +live-frame-coarse-ms+ 1000
  "How often a frame whose only live part is a COUNTDOWN is rebuilt.

One second, because that is the finest thing a countdown can say: the ladder in
`deadline-said` is whole minutes far out and whole seconds near, and a repaint at ten
times that rate would draw the same characters nine times. Measured: a live frame at
`+live-frame-ms+` costs 0.07 % of a core; a head idling on the one-second rate is
inside the noise.")

(defun live-frame-interval-ms (head)
  "How long a frame with a clock in it may stand: 100 ms, or 1000 for a countdown only."
  (if (live-frame-tenths-p head) +live-frame-ms+ +live-frame-coarse-ms+))

(defun live-frame-due-p (head)
  "Has the CLOCK asked for a frame — as opposed to an event — and is one due?

False on a head with nothing live in it, which is the state that keeps an idle head
at `sleep 0.03` and off the operator's CPU."
  (and (live-frame-p head)
       (>= (- (internal-real-time-ms) *last-paint-ms*)
           (live-frame-interval-ms head))))

