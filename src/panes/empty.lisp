;;;; empty.lisp — the empty-session banner
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; --------------------------------------------- the empty-session banner ;;;

(defun empty-session-lines (cols)
  "What the transcript says when there is nothing in it — the reference's opening
banner (`app.rs:6112-6131`), which leticl did not have at all.

The distinction it turns on is the one the walking cat above already makes:
**attached and quiet** is not **not answered yet**. The cat covers the second,
and this covers the first, so an empty screen is never left to mean both. The
reference guards it with `&& !self.attaching` for exactly that reason and
`%viewport-lines` guards it the same way.

One word differs from the reference on purpose: it names itself `letibot` and
this head is `leticl`, and a banner whose whole job is to say which head you are
looking at must not lie about that. Every other sentence is verbatim."
  (let ((w (max 20 cols)))
    (append
     (list (list (cons "leticl" '(:bold t)))
           nil)
     (mapcar (lambda (l) (list (cons l '(:dim t))))
             (wrap-text "attached, and this session has said nothing yet. Type a question and press enter." w))
     (mapcar (lambda (l) (list (cons l '(:dim t))))
             (wrap-text "The turn runs in the daemon: closing this window does not stop it, and reattaching picks it up." w))
     (list nil
           (list (cons "/help lists the keys." '(:dim t)))))))

