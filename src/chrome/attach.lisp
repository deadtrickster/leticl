;;;; attach — the attach wait: what the head shows while it is finding its daemon
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------- the attach wait ;;;
;;;
;;; The `Hello` carries the WHOLE SNAPSHOT, so on a session of thousands of rows
;;; there is a real wait before the first frame — and this head drew an empty
;;; screen with a status line, which is indistinguishable from a head attached to
;;; the wrong socket.
;;;
;;; The reference's shape, and its four properties are each a bug it had:
;;;
;;;  · **centred horizontally on the indicator's OWN row**, so "centred" is a
;;;    statement about the cat and not about whatever else shares the line (the
;;;    first version put ` attach` beside it);
;;;  · **walking in place** — the frames differ in width, so the SLOT is what is
;;;    centred and the cat sits at its left edge. Centring each frame on its own
;;;    made it jitter sideways, which reads as a drawing bug rather than a walk;
;;;  · **moved by the CLOCK**, not a frame counter, so the screen stays a pure
;;;    function of time;
;;;  · **vertically in the conversation**, not pinned under the header.
;;;
;;; A cat rather than a spinner glyph because this is the one wait where a spinner
;;; is the honest answer: the work is client-side and the head genuinely cannot say
;;; more, having been told nothing.

(defparameter +cat-frames+
  #("(=^.^=)" "(=^.-.=)" "(=^o^=)" "(=^-.-=)" "(=^.^=)~" "(=^.-.=)~" "(=^o^=)~" "(=^-.-=)~")
  "A cat walking right, one leg changing per frame.")

(defparameter +cat-slot+ (loop for f across +cat-frames+ maximize (length f))
  "The width of the SLOT the cat walks in: the widest frame. Centring each frame
on its own width made a 7-wide and an 8-wide cat jitter instead of walk.")

(defun cat-frame (elapsed-ms)
  (aref +cat-frames+ (mod (floor (or elapsed-ms 0) 120) (length +cat-frames+))))

(defun %centred-row (text cols)
  "TEXT centred in COLS columns."
  (let* ((w (string-width text))
         (pad (max 0 (floor (- cols w) 2))))
    (list (cons (make-string pad :initial-element #\space) nil)
          (cons text nil))))

(defvar *attach-started-ms* nil
  "When this head sent its ATTACH, or NIL once a Hello has arrived. A defvar: the
clock the cat walks to.")

(defparameter +attach-impatient-ms+ 2000
  "How long a wait goes before the screen says the daemon has not answered — the
reference's `ATTACH_IMPATIENT`.")

(defparameter +attach-wait-ms+ 30000
  "How long this head waits for a `Hello` before it gives up and says why.

**The reference's `ATTACH_WAIT` (`bin/letibot-tui.rs:167`), and the deadline is the
point rather than the number.** A daemon that accepted the connection and sent no
Hello is not an absent daemon — it is a HUNG one, and the difference matters to
whoever has to deal with it: absent means start one, hung means find out why. So the
head stops waiting, exits, and its farewell names `letibot --status` (what is on the
socket) and `letibot --stop` (how to end it from outside), which are the two commands
a person needs and neither of which the screen can offer.

Ours waited for ever, with a two-second line that said `ctrl-c twice, or wait` and
nothing about the daemon being hung. Measured on a scratch daemon that accepts and
never answers: the head sat on the cat indefinitely.

**Ctrl-C still works during the wait** — the input thread drains keys and the loop
runs `%handle-key` the whole time, which is what the hint bar under the frame has
promised since before there was a frame.")

(defun attach-overdue-p ()
  "Has the attach been unanswered past `+attach-wait-ms+`?"
  (and *attach-started-ms*
       (>= (- (internal-real-time-ms) *attach-started-ms*) +attach-wait-ms+)))

(defun attach-gave-up-said ()
  "The farewell for a daemon that took the connection and said nothing."
  (format nil "the daemon did not answer within ~ds. It accepted the connection and ~
               sent no `Hello`, which is a hung daemon rather than an absent one — ~
               `letibot --status` says what is on the socket, and `letibot --stop` ~
               stops it."
          (floor +attach-wait-ms+ 1000)))

(defun attaching-p (head)
  "Has this head asked for a session and not been answered?

**The clock IS the flag.** This also required `(not (head-connected head))`, and
`run` sets `connected` to T the moment the socket opens — deliberately, because
`%send` refuses to write while disconnected and the ATTACH is the first frame —
so `attaching-p` was false from before the first paint and the walking cat NEVER
DREW. The blank screen it exists to replace is what the operator got on every
attach to a big session. `*attach-started-ms*` is set when the ATTACH goes out and
cleared by the `hello` arm, which is exactly the reference's `attaching` flag
(app.rs:1559, 1653)."
  (declare (ignore head))
  (and *attach-started-ms* t))

