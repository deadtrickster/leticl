;;;; notice — the notice row
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; --------------------------------------------------------------- notice ;;;
;;;
;;; A notice that never expires becomes furniture: the old head pinned one to the
;;; status line for the rest of the session. Dropping it is what makes the next one
;;; noticeable.
;;;
;;; **The clock lives on the HEAD, beside the note it ages, and it counts TIME.**
;;; Both halves were learned the hard way, and they are the same lesson this file
;;; keeps meeting: state that belongs to a head does not live in a global, and a
;;; timer does not count a unit that stops when the thing being timed is not the
;;; thing counting.
;;;
;;; MEASURED IN THE FIELD, on the live head, because the note was stuck on screen:
;;;
;;;     :note "permission answered"  :ttl 0  :dirty NIL     <- and identical 2 s later
;;;
;;; A note with no clock, on a head whose loop was running and painting that whole
;;; time (the operator watched thinking text stream underneath it). The note and its
;;; clock had COME APART, permanently: `tick-notice` was guarded on `(plusp ttl)`, so
;;; with the global at 0 the note could never be aged — and the global is left at 0
;;; by every one of the seventeen places that set the note DIRECTLY rather than
;;; through `say`. `"permission answered"` is the daemon's own `Accepted` note, and
;;; that arm is one of them.
;;;
;;; So three things changed together and each would be wrong alone:
;;;
;;;   · the deadline is a **millisecond** the head holds, not a frame count in a
;;;     global — it cannot come apart from the note because it is a slot of the same
;;;     struct, and `notice-remaining-ms` reports it beside the note it belongs to;
;;;   · it expires **in time**, so it is the same duration on a busy screen and a
;;;     quiet one. A TTL counted in frames is a timer that stops when the frames
;;;     stop, which is exactly when a notice is left standing longest;
;;;   · `say` is the only writer, and it STARTS the clock. `clear-note` is the only
;;;     clearer, and it stops it. A note nobody started a clock on was reachable at
;;;     seventeen call sites, and the guard that made it permanent was written as a
;;;     feature — "an alarm persists" — which is true of the alarm line and false of
;;;     this slot.

(defparameter +notice-ttl-ms+ 1600
  "How long a status notice stays on the screen before it stops being news.

**The number that was already in effect, measured rather than chosen.** The old
constant was 60 FRAMES, and measured on the live head from `say` to the note going,
polled from the shell so the eval socket's paint lock could not starve the loop it
was watching:

      0.518s ttl 41    ·    1.061s ttl 20    ·    1.599s gone

— about 38 loop passes a second on an idle screen, and **1.6 s of wall time**. So
this changes the UNIT and not the behaviour: the same sentence stays for the same
second and a half, on a busy screen as on a quiet one.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defun notice-remaining-ms (head)
  "Milliseconds left on HEAD's status note, or NIL when nothing is counting.

**The one function that answers \"is the note near its end\"** — and it answers it
from the note's own head, so the two cannot disagree. The defect this replaces was
read as `head-status-note` non-NIL with `*notice-ttl*` 0: a note with no clock, on a
head that could never clear it."
  (let ((until (head-notice-until head)))
    (when (plusp until)
      (max 0 (- until (internal-real-time-ms))))))

(defun tick-notice (head)
  "Clear the status note once its deadline has passed. T when it cleared one.

**A comparison against the clock, not a decrement.** The old body took one frame off
a counter per loop pass and cleared the note at 1, which made the notice's lifetime a
function of the frame rate — and made a note whose counter had already reached 0
immortal, because the body was guarded on `(plusp ttl)`.

A note the OPERATOR must act on is not on this clock — an alarm and a stall both
persist until they are fixed, because those are about the state of the world rather
than about something that just happened. That is what the guard is FOR; it just has
to be the note's own state that says so, and \"no deadline\" says it without also
saying \"never again\"."
  (let ((until (head-notice-until head)))
    (when (and (head-status-note head)
               (plusp until)
               (>= (internal-real-time-ms) until))
      (clear-note head)
      t)))

(defun say (head text)
  "Set a status note and START its clock. The one way to notice something.

**Every writer goes through here**, and that is the fix: the clock is armed by the
same `setf` that sets the note, so there is no way to set one without the other. The
seventeen direct `(setf (head-status-note head) …)` sites this replaced are the
reason `\"permission answered\"` was immortal."
  (setf (head-status-note head) text
        (head-notice-until head) (+ (internal-real-time-ms) +notice-ttl-ms+)
        (head-dirty head) t))

(defun clear-note (head)
  "Take the status note down and stop its clock. The one way to clear one."
  (setf (head-status-note head) nil
        (head-notice-until head) 0
        (head-dirty head) t))

