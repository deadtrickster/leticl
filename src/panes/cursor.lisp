;;;; cursor.lisp — where a pane's cursor opens — the door the protocol calls
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ---------------------------------------- where a pane's cursor opens ;;;

(defun picker-initial-sel (head)
  "The row the session picker opens on: **the session this head is in**.

The reference seeds `picker_sel` from the current session when Ctrl+S opens the
list (app.rs:3080-3087), so Enter on an untouched list is a no-op — the same
courtesy `open-pick` pays the mode picker two hundred lines above. `%open-pane`
(`src/commands/verbs.lisp:182-195`) sets the shared cursor to 0 for every pane, so
Ctrl+S then Enter switched the operator to session #1, which is very rarely the
one they were in.

0 when the current session is not in the list, which is a daemon that has not
answered `sessions` yet — and row 0 is then the only row there is to be on."
  (or (position (session-session-id (head-session head))
                (picker-sessions (head-session head))
                :key (lambda (b) (getf b :session-id)) :test #'equal)
      0))

(defun pane-initial-sel (head mode)
  "Where pane MODE's cursor belongs the moment it opens.

One function so `%open-pane` has a single line to call rather than a `case` of
its own, and so the seeding lives beside the pane that defines what a row is.
Every pane but the session picker opens at the top, which is the honest place
when one cursor is shared: a position left by the last pane means nothing to the
next (`src/commands/verbs.lisp:185-190`)."
  (pane-opens-at (pane-for mode) head))

