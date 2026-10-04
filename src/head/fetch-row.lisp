;;;; fetch-row — asking for a row above the window
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- asking for a row above the window ;;;
;;;
;;; The REQUEST half of `FetchRow`, here rather than in `session.lisp` for the reason
;;; the split exists: the session owns the STATE (what it holds, and the seam that says
;;; so) and the head owns the SOCKET. A session function that sends would be a session
;;; function that needs a head, and this file is the one that has both.

(defun fetch-row-above (head)
  "Ask the daemon for the row above this head's oldest. T when a request went out.

**On demand, and never eagerly** — which is the question the requirement asks. Eagerly
filling the gap would fetch exactly what `ViewBounds` just refused to put in the
snapshot: thousands of rows, over a socket that already costs the daemon a clone per
attaching head, for an operator who is looking at the NEWEST end of the conversation.
The trigger is the reader reaching the top of what they have, which is the only moment
those rows are wanted.

Three refusals, and each is a fact rather than a guard: nothing above (`rows-above`), a
request already in flight (a transcript has one top), and the daemon having already
refused these rows (`*rows-above-unserved*`) — the last is what keeps a head from
asking once per scroll for ever.

Nothing is said on the status line: the seam itself changes from `scroll to this line
to load the next` to `asking the daemon for row N`, which is where the reader is
already looking and is the same place the answer will land."
  (let* ((session (head-session head))
         (row (rows-above session)))
    (when (and row (null *row-fetch*) (not *rows-above-unserved*))
      (setf *row-fetch* (list :row row :at 0))
      (%send head (make-fetch-row (session-session-id session) row))
      (setf (head-dirty head) t)
      t)))

(defun %wheel-batch (keys)
  "KEYS split into `(values OTHER-KEYS KIND NOTCHES)`: the keys to dispatch in order, and the wheel
gesture the batch amounts to as ONE direction and a count.

**THE OPERATOR ASKED FOR THIS IN ONE WORD — *\"batching\"* — and the reason is not only throughput.**
A pass reads whatever arrived, and a trackpad sends far more events than a screen can show: applying
each one paints a frame that is immediately superseded. Coalescing makes the cost of a pass ONE move
and ONE paint however fast the finger moves, so the loop's period stops being a function of the input
device.

**AND IT IS EXTRACTED FROM THE LOOP SO IT CAN BE TESTED.** Inline, the only way to exercise it was to
run the loop and watch a screen; as a function of a key list it is a pure question with a pure answer,
and the two interesting answers are the ones an inline version gets wrong — a mixed batch, and a
gesture that turns around.

**OPPOSITE DIRECTIONS CANCEL, which is what makes a turn-around end where the finger ended.** An
up-then-down gesture is not two moves that happen to follow each other; it is one net movement, and if
the batch were applied as \"the last direction wins\" a flick-scroll that returned to its start would
jump by the whole flick instead of staying put. One notch of the new direction cancels one of the old,
and the batch flips sides only when the old side is used up.

**THE NON-WHEEL KEYS ARE RETURNED IN ORDER AND DISPATCHED FIRST**, so a printable key or an `esc` that
changes what a notch MEANS (a pane opened, a mode left) is applied before the gesture — the gesture
lands on the view it was made on."
  (let ((others '())
        (kind nil)
        (notches 0))
    (dolist (key keys)
      (let ((t* (%key-type key)))
        (if (member t* '(:wheel-up :wheel-down))
            (let ((n (or (getf key :notches) 1)))
              (cond
                ((or (null kind) (eq kind t*)) (setf kind t*) (incf notches n))
                (t (decf notches n)
                   (when (minusp notches)
                     (setf kind t* notches (- notches))))))
            (push key others))))
    (values (nreverse others) kind notches)))

