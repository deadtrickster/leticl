;;;; notes.lisp — the /notes listing: the warnings the session has filed
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------------- the notes ;;;
;;;
;;; R10's reader: what this head has warned about, and how to retire one. The listing
;;; is a slash listing — content that arrived, read from the top — so it is
;;; `*slash-out*` and `:slash`, not a pane of its own.

(defun warning-listing-lines (session)
  "The `/notes` listing: every warning this head holds, in the order the conversation
has them, numbered for `/notes dismiss N`.

**The whole text, not the fold.** A listing that hid the tail of the very thing it
exists to make findable would be the defect it is the answer to; the reference
renders it with the transcript's own unfolded renderer for the same reason
(app.rs:5860-5864). Lines come back UNWRAPPED — the slash pane wraps at its own
width, and wrapping here as well would wrap twice."
  (let* ((ws (warning-order session))
         (held (length ws))
         (retired (count-if (lambda (w) (session-retired-p session w)) ws))
         (out (if (zerop held)
                  (list "this head holds no warnings. A warning is the daemon's own \
sentence about this session — a compaction, a context wall, an interrupted turn — and \
the session log holds it whether or not this head is showing it.")
                  (list (format nil "~d warning~a, ~d retired — the log holds the durable \
fact and this head shows it once"
                                held (if (= held 1) "" "s") retired)))))
    (loop for w in ws
          for i from 1
          do (push (format nil "~3d  ~a" i
                           (if (session-retired-p session w) "[retired]" ""))
                   out)
             (push (format nil "~a ~a" (warning-glyph w) (warning-note-text w)) out))
    (when (plusp held)
      (push "" out)
      (push "/notes dismiss [N|all] retires one, or every one · /notes restore brings them all back"
            out))
    (nreverse out)))

(defun open-notes-listing (session)
  "Open the `/notes` listing in the slash pane. T when there is a listing.

Fills `*slash-out*` and does NOT touch the mode: the mode is head state, and the one
thing the head has to do with what arrived here is the same thing it does with a
listing the daemon sent — follow the state after the fold (`head.lisp:495-497`)."
  (setf *slash-out* (cons "/notes" (warning-listing-lines session)))
  (reset-pane-scroll)
  t)

(defun notes-listing-open-p ()
  "Is the listing on the screen the NOTES one? Used to decide whether a retirement
should redraw it: a daemon slash reply that happens to be up is not this head's to
replace."
  (and (consp *slash-out*) (equal (car *slash-out*) "/notes")))

