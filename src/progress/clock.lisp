;;;; clock — the daemon's clock
;;;;
;;;; Split out of `progress.lisp`, which was one 409-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------- the daemon's clock ;;;
;;;
;;; **A DEADLINE FROM THE DAEMON IS A WALL-CLOCK INSTANT AND THIS HEAD'S CLOCK IS
;;; NOT.** `DecisionRequested.deadline` and `SecretRequested.deadline` are *"Unix
;;; millis"* (event.rs:573, :746) and `internal-real-time-ms` is SBCL's
;;; `get-internal-real-time` — a counter since this process started. Subtracting one
;;; from the other is a duration measured across two clocks, silently wrong by an
;;; enormous constant, which is R13's trap in a second place and the one the SECRET
;;; card had been living with: its countdown read the difference between a Unix
;;; instant and a monotonic counter.
;;;
;;; The two clocks differ by a CONSTANT, so it is measured once and reused, and a
;;; wire deadline is converted to this head's clock **when the frame arrives** —
;;; R13's own answer (*anchor on arrival*), which is the only place the two readings
;;; can be subtracted while they describe the same moment. What remains is a
;;; duration in one clock, and every countdown from then on is two readings of
;;; `internal-real-time-ms`.
;;;
;;; The residual error is the delivery latency of one frame plus any real
;;; disagreement between this box's wall clock and the daemon's — which is the honest
;;; best available: the daemon said *when*, and `when` is a wall-clock fact.

(defvar *unix-offset-ms* nil
  "`(- unix-ms monotonic-ms)` — the constant between this box's wall clock and
SBCL's internal counter, measured on first use and then reused.

A `defvar` and not a head slot: it is a property of the PROCESS, not of a head, and
a struct change is a restart. Bound to 0 by `with-replay-globals` (see there).")

(defun unix-now-ms ()
  "The wall clock in Unix milliseconds, from the process's own readings.

Sub-millisecond accurate and monotonic in practice: `get-universal-time` is a
one-second counter, so it is used ONCE to establish the offset and every later
reading is the internal counter plus that constant."
  (let ((offset (or *unix-offset-ms*
                    (setf *unix-offset-ms*
                          (- (* 1000 (- (get-universal-time) 2208988800))
                             (internal-real-time-ms))))))
    (+ (internal-real-time-ms) offset)))

(defun wire-deadline->monotonic (deadline)
  "DEADLINE as the daemon sent it (Unix milliseconds), on THIS head's clock.

**Called where the frame is folded, never where it is drawn.** A card that converted
at render time would be subtracting a Unix instant from a monotonic one on every
frame — which is what the secret card did — and a card that converts at arrival
holds a duration that is already in one clock.

NIL in, NIL out: §11.5's *\"wait forever\"* is `deadline: null`, and an ask that
cannot expire is not an ask whose deadline is zero. **A zero or negative value counts
as no deadline too**, because epoch 0 is not an instant any daemon means and a card
counting down from 1970 would be a rendering fault rather than a fact — this is the
guard the secret card already had (`(plusp deadline)`), kept rather than moved."
  (when (and (numberp deadline) (plusp deadline))
    (+ (internal-real-time-ms) (- deadline (unix-now-ms)))))

(defun wire-stamp->started-ms (began)
  "BEGAN, as the daemon sent it (Unix ms), as a value `*turn-started-ms*` can hold — or NIL.

**The whole turn's start, not the round's.** `TurnStarted` fires once per ROUND (the engine's
`run_turn_steered` is called inside the daemon's round loop), so a head that simply took
`internal-real-time-ms` at the event restarted its clock every round: the operator watched the
composer read `2.1s` a minute into a turn and reported it — *\"it should be still responding even
while you do tools calls and such, and not reset, currently it resets.\"*

So the emitter stamps the turn's real start and this converts it once, at the fold, into the
monotonic base the duration is subtracted from — the same one-conversion rule
`wire-deadline->monotonic` keeps, and for the same reason: two clocks in one subtraction is a
number that is wrong by their offset.

**NIL for a value nobody measured**, which is §11.5's *wait forever* read the other way: a
non-positive stamp is not an instant any daemon means, so the head keeps its own NIL and the row
says *started before this head attached* rather than inventing a start."
  (when (and (numberp began) (plusp began))
    (+ (internal-real-time-ms) (- began (unix-now-ms)))))

(defun deadline-remaining-ms (deadline)
  "Milliseconds left before DEADLINE, or NIL when there is none. NEGATIVE once past.

Negative rather than clamped, because *\"past its deadline\"* and *\"no time left\"* are
different facts and the caller has a different sentence for each.

A non-positive DEADLINE is NIL here for the same reason `wire-deadline->monotonic`
converts one to NIL: epoch 0 is not an instant anybody meant."
  (when (and (numberp deadline) (plusp deadline))
    (- deadline (internal-real-time-ms))))

(defparameter +deadline-coarse-ms+ 120000
  "Above this much time left, the countdown is in WHOLE MINUTES.

The operator's question, answered: *\"a countdown that ticks for five minutes is
furniture and one that ticks for ten seconds is a pressure the operator did not ask
for\"*. Both are avoided by a ladder rather than by a number — coarse while it is not
urgent (and a minute-granular figure also gives the loop a reason to repaint once a
minute instead of ten times a second), exact once it is. Two minutes is where a
decision stops being something to think about later and starts being something to
answer now, and it is the number the coarse arm is measured against: at the daemon's
own `ANSWER_BUDGET` (300 s, `harnessd/src/answers.rs:66`) the card reads `5 min` for
its first three minutes and counts in seconds for the last two.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defun %countdown-duration (ms)
  "MS as a countdown reads it: whole seconds under a minute, `duration` above.

`47s`, not `47.0s` — the spelling the secret card used and the one the reference's own
countdown prints — while a long one keeps `3m07s`. One function, so the *time left*
clause and the *past its deadline* clause cannot disagree about how a duration is
written; two spellings of one rule is the defect that always follows."
  (if (< ms 60000) (format nil "~ds" (floor ms 1000)) (duration ms)))

(defun %coarse-duration (ms)
  "MS rounded UP to whole minutes: `5 min`, `2 min`, `1 min`.

**Up, not nearest.** The sentence is *expires in …*, and a rounded-down figure claims
less time than there is — an operator who decides on the strength of it would be
deciding about a deadline that is not the one the daemon set. Ties go up for the same
reason, and the value never decreases as the clock runs."
  (format nil "~d min" (max 1 (ceiling (max 0 ms) 60000))))

(defun deadline-said (deadline)
  "The time clause for a card with DEADLINE, or NIL when there is no deadline.

Three states, and the third is the one the operator hit on 2026-09-21 — two cards
went by with `not_run by gate:timeout` and *nothing on the card had said that was
coming*:

  · **time left, and plenty** — `expires in 5 min`. No ticking: the value is the
    fact, and the fact does not change this second;
  · **time left, and not plenty** — `1m58s left`, then `47s left` under a minute. The
    last two minutes are counted in seconds because that is where the number is acted
    on, and the last of them in WHOLE seconds (`47s`, not `47.0s`), which is the
    spelling the secret card already used and the one the reference's own countdown
    prints;
  · **past it** — `past its deadline by 12s; the daemon has not said what became of it`.
    A card still on the screen after its own deadline is a card whose answer has
    already been settled daemon-side, and the head has not been told which way. Saying
    so is the difference between a clock the operator can see and one that ran out
    quietly; what it must NOT do is keep counting into negative seconds, which is a
    number that means nothing and reads as a rendering fault.

**NIL, not a sentence, when there is no deadline.** §11.5's `deadline: null` is
*\"wait forever\"* — a policy, not missing information — so an ask that cannot expire
says nothing about time, and *\"I was not told\"* cannot be manufactured by a card that
never had a clock to show. This is the §13.2b question (present-and-zero) answered in
the other direction, and deliberately: `unreadable 0` is a counter that must be shown
because a head that does not count is a different head, while a countdown on an ask
with no deadline is a number nobody took."
  (let ((left (deadline-remaining-ms deadline)))
    ;; NIL from `deadline-remaining-ms` is *no deadline* — an absent one, or a
    ;; non-positive one nobody meant — and it is the same silence either way
    (when left
      (cond
        ((minusp left)
         ;; a SEMICOLON and not an em-dash: the card joins its clauses with ` · `, so
         ;; a second dash level here would read as two different kinds of break
         (format nil "past its deadline by ~a; the daemon has not said what became of it"
                 (%countdown-duration (- left))))
        ((>= left +deadline-coarse-ms+)
         (format nil "expires in ~a" (%coarse-duration left)))
        (t (format nil "~a left" (%countdown-duration left)))))))

(defparameter +on-timeout-said+
  '(("deny" . "if nobody answers, nothing runs")
    ("allow" . "if nobody answers, it RUNS anyway")
    ("ask" . "if nobody answers, the guard model decides"))
  "What SILENCE does, in the daemon's own three words (`SessionEvent`'s `OnTimeout`,
`deny | allow | ask`, event.rs:250-257).

**Said on every card that has a deadline, because it is the fact that does not
change.** The countdown tells an operator when to hurry; this tells them what happens
if they do not, and the two are not the same question — `deny` costs one refused call,
`allow` runs it UNATTENDED, and an operator who walked away believing the default was
`deny` when it was `allow` has been told nothing by a clock. Upper case on that one
word: it is the only outcome here that does something the person did not ask for.

A code this head does not know renders no clause, rather than guessing at one —
a wrong consequence is worse than an absent one, and the daemon's vocabulary is the
only place this can be learned.")

(defun on-timeout-said (on-timeout)
  "What silence does, from the wire's own word: `\"deny\"`, `\"allow\"`, `\"ask\"`, or
NIL for a word this head does not know (see the table)."
  (cdr (assoc (string-downcase (or on-timeout "")) +on-timeout-said+ :test #'string=)))

