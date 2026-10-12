;;;; feedback.lisp — the operator's mark on a turn (letibot R81, protocol 45)
;;;;
;;;; *"alt-g marks the current turn good, alt-b bad, and a second press within five seconds opens the
;;;; note"* — the operator's own decision, and the whole of the feature is that sentence. Two things
;;;; about it are shape rather than decoration, and both are the reference's:
;;;;
;;;;   · **`alt-b` IS READLINE's WORD-LEFT AND STAYS IT** wherever there is a line to move over — the
;;;;     same rule this head already applied to `ctrl-]` against `ctrl-e`. So it marks only on an EMPTY
;;;;     composer with nothing in front of the conversation, and the movement it has always meant is
;;;;     untouched everywhere else;
;;;;   · **the five seconds are the gesture, not a keystroke.** One press is a mark; the second, while
;;;;     the mark is still the one just made, is *say why* — so the note is never a dialog away from the
;;;;     judgement it is about.

(in-package #:leticl)

(defvar *last-mark* nil
  "The mark last sent, as `(:polarity P :at MS)`, or NIL — what the second press reads.

**A DEFVAR AND NOT A SLOT**, for the reason every counter in this head is one: a struct change is a
restart, and a head that cannot be patched while it runs is a head the operator has to leave a turn to
fix. It is the *last* mark rather than a stack, because the gesture is about the one just made.")

(defparameter +mark-window-ms+ 5000
  "How long a mark stays *the one just made* — the reference's own five seconds.

That window is the whole of what makes a second press mean *say why* rather than *mark it again*, so it
is a constant with a name rather than a number at the comparison.")

(defun %mark-verb (polarity)
  "The composer spelling of POLARITY — the door the second press opens."
  (cond ((string= polarity "good") "/fb+")
        ((string= polarity "bad") "/fb-")
        (t "/fb")))

(defun %mark-row (head)
  "The row a mark names: the one the VIEW is ANCHORED TO when the reader is scrolled back, else NIL.

**A head has no row cursor, and that is why this is an anchor.** The reference says the same thing in
its own words — *scrolled back, it names the row the view is anchored to … the head has no row cursor,
so there is no `f` on a selected row; the anchored row is the nearest thing*. So `NIL` here means
*now*, and there is no third answer to invent: a reader at the bottom is marking the turn they are
watching."
  (and (plusp (head-scroll head)) *scroll-anchor* (car *scroll-anchor*)))

(defun marks-a-turn-p (head)
  "Can this daemon be told? `Feedback` is what protocol 45 ADDED, and an older daemon refuses the whole
`ClientFrame` rather than that one field — the both-ways rule `%term-pane-field` keeps for 44.

**A head that cannot send SAYS SO** rather than marking silently: a key that appears to do nothing is
the defect this head has been fixed for more than once, and a mark nobody receives is worse than that —
it is a judgement the operator believes was recorded."
  (and (integerp *daemon-protocol*) (>= *daemon-protocol* 45)))

(defun send-mark (head polarity &optional note)
  "Send ONE mark — `good`, `bad` or `note` — with the head's clock and the anchored row. NIL and a
sentence when the daemon is older than the frame."
  (cond
    ((not (marks-a-turn-p head))
     (say head (format nil "this daemon speaks ~a, and a mark is protocol 45's frame — not sent"
                       (or *daemon-protocol* "an unknown protocol")))
     nil)
    (t
     (%send head (make-feedback polarity :note (or note "") :item-id (%mark-row head)))
     (setf *last-mark* (list :polarity polarity :at (internal-real-time-ms)))
     (say head (format nil "marked ~a~@[ — ~a~]~@[ · on the row you are reading~]"
                       polarity
                       (and (plusp (length (or note ""))) note)
                       (%mark-row head)))
     polarity)))

(defun mark-key (head polarity)
  "The `alt-g`/`alt-b` gesture: mark, or — a SECOND press inside `+mark-window-ms+` — open the composer
to say why. T always: the key is the head's either way."
  (let ((last *last-mark*)
        (now (internal-real-time-ms)))
    (if (and last
             (equal (getf last :polarity) polarity)
             (< (- now (getf last :at)) +mark-window-ms+))
        ;; **THE NOTE IS THE COMPOSER'S OWN LINE**, not a dialog: the second press fills the buffer with
        ;; the verb the operator could have typed, so the two doors cannot drift, and Enter sends it as
        ;; an ordinary line. It does NOT send the mark again — the mark is already made.
        (progn
          (setf (composer-buffer (head-composer head)) (format nil "~a " (%mark-verb polarity))
                (head-mode head) :normal
                *last-mark* nil
                (head-dirty head) t)
          (say head "say why — enter sends it as the note"))
        (send-mark head polarity))
    t))
