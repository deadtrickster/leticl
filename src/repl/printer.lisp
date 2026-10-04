;;;; repl.lisp — the `/lisp` pane: the eval socket's own surface, on the glass.
;;;;
;;;; HACKING.md's contract is that a leticl head is a LIVE IMAGE — you can redefine its
;;;; renderer, restyle it and inspect its state while it is attached to a running turn —
;;;; and until now the only door to that was a socket (`scripts/tui-eval`) or an agent
;;;; holding one. This is the same door in the head: type a form, press enter, read what
;;;; came back, with the transcript still behind it.
;;;;
;;;; **ONE EVAL, TWO SURFACES.** The eval itself is `hack-eval-form` (`src/hack.lisp`), so
;;;; a form that works at the socket works here, and the two cannot come to disagree about
;;;; what `*standard-output*` is, which conditions are muted, or whether a form counts as a
;;;; PUSH. What is here is the pane: the frame's budget on the printed value, the
;;;; scrollback, and the disclosure of what it did not keep.
;;;;
;;;; **THE PAINT LOCK IS NOT TAKEN, and that is the one place the two surfaces differ.**
;;;; The socket takes it (`%with-paint-lock`) because its thread is not the paint thread;
;;;; this code RUNS on the paint thread, and taking `paint-lock` inside an eval deadlocks —
;;;; measured, and recorded in `%with-paint-lock`'s own docstring. See `hack-eval-form`.
;;;;
;;;; **THE SENTENCE THIS FILE MOST NEEDS A READER TO KNOW** is HACKING.md's: an eval that
;;;; blocks (a `sleep`, a long walk, a big allocation) freezes the LOOP, because the loop is
;;;; what is running it. The pane is not a prompt beside the head; it is the head.

(in-package #:leticl)

(defvar *lisp-entries* nil
  "What this head has evaluated in the pane, NEWEST FIRST: plists
`(:form S :value S :error S :ms N)`, with the value and the error already PRINTED.

Newest first because that is what `push` costs, and the display reverses it — the same
arrangement `jobs-lines` keeps, and for the same reason.

A `defvar`, so a live push does not drop a running head's scrollback: the shape every piece of live
state in this tree keeps. Bound by `with-replay-globals`, because a replay must answer the same bytes
twice and a scrollback is state.")

(defparameter +lisp-entries-max+ 200
  "How many entries the pane holds before the oldest goes.

**Dropping is not deleting, and the count is what says so** (R17). An entry that falls off the front
is counted in `*lisp-dropped*` and the pane draws the count, so a scrollback that was cut says it was
cut rather than looking like the whole session — the rule the job-output window already keeps with
its `N earlier bytes went off the front`.")

(defvar *lisp-dropped* 0
  "How many entries have gone off the front of the scrollback. See `+lisp-entries-max+`.")

(defparameter +lisp-print-length+ 64
  "How many ELEMENTS of a sequence the pane's printer shows before the language's own `...`.

**THE FRAME'S BUDGET, NOT TIDINESS.** A REPL in a terminal has a screen's room, and the head's own
values are huge: `(session-items (head-session *head*))` is two thousand rows and printing it whole
takes the scrollback, the frame and the operator's patience with it. `*print-length*` and
`*print-level*` cut with `...`, which is a DISCLOSURE rather than a truncation — the reader can see
that something was left out and how much of the shape was shown.

The socket is deliberately NOT bounded this way: `tui-eval` is asked for one value by somebody who
chose the form, and a `--where`-style answer that arrived cut would be a worse tool. The pane is the
surface a person types into, and it draws what it can hold.")

(defparameter +lisp-print-level+ 8
  "How deep the pane's printer goes before `#`. See `+lisp-print-length+`.")

(defparameter +lisp-value-max-lines+ 12
  "How many ROWS one entry's value may take before the rest is disclosed as a count.

A count and not an ellipsis: twelve rows of a printed list end at an arbitrary place, and a reader
who is told `+38 lines` knows both that there is more and how much. The full value is still in the
scrollback's own entry — this is the DRAWING's bound, not the entry's.")

;;; ------------------------------------------------------------- the printer ;;;

(defun %lisp-print (value)
  "VALUE as the text an entry carries. See `+lisp-print-length+` for the bounds and why the pane has
them when the socket does not.

`*print-circle*` is here for a reason that is not size: the head's own structures are GRAPHS — a head
holds its session, the session's items hold bodies, and a form is free to make a cycle — and an
unshared printer on a circular value does not return. `*print-readably*` is off so that a value the
printer cannot read back (a structure, a hash table, a function) prints as the `#<...>` it is rather
than raising inside the pane that was trying to show it."
  (let ((*print-length* +lisp-print-length+)
        (*print-level* +lisp-print-level+)
        (*print-circle* t)
        (*print-readably* nil)
        (*print-pretty* nil))
    (prin1-to-string value)))

(defun lisp-value-lines (text cols)
  "TEXT, one row per line at most COLS columns, at most `+lisp-value-max-lines+` of them.

The cut is DISCLOSED and it is a count: `… +38 lines`. A printed list cut at an ellipsis would leave
the reader unsure whether the form ended there, and this is the one place the pane can say exactly
what it did not draw."
  (let* ((max-cols (max 8 (- (pane-width cols) 3)))
         ;; **THE SAME SPLIT A TOOL PAYLOAD GETS**, and for the same reason: a final newline ENDS the
         ;; last line and does not start an empty one. `uiop:split-string` answers a trailing `""`
         ;; for both, so a value that ends in a newline would count one line more than it draws — and
         ;; the disclosure's own NUMBER is the thing that would have been wrong.
         (rows (mappend (lambda (l) (or (wrap-text l max-cols) (list "")))
                        (%payload-lines text)))
         (rows (or rows (list "")))
         (n (length rows))
         (shown (min n +lisp-value-max-lines+)))
    (append (subseq rows 0 shown)
            (when (> n shown)
              (list (format nil "… +~d line~:p" (- n shown)))))))

