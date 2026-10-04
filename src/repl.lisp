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

;;; ------------------------------------------------------------- the entry ;;;

(defun %lisp-entry-lines (entry cols)
  "One ENTRY as the rows the pane draws, at COLS.

    › (session-seq (head-session *head*))
      => 471 · 0.3 ms

The form is drawn as the operator's OWN words — their prompt registers, `› ` and plain text, the same
arrangement the composer uses — because that is what it is: a line they typed. The value is the
answer and carries its own duration, which is the socket's `ms` on the same clock, so a form that
feels slow can be told from one that looks slow.

**AN ERROR IS THE FAILURE REGISTER AND NOTHING ELSE.** A condition printed in the same style as a
value is a REPL that lies about what happened, which is the one defect this pane exists to avoid: the
whole point of typing at a live image is that you find out it did not work."
  (let* ((w (max 8 (- (pane-width cols) 4)))
         (form-rows (lisp-value-lines (or (getf entry :form) "") w))
         (error (getf entry :error))
         (body (and (not error) (lisp-value-lines (or (getf entry :value) "") w)))
         (why (and error (lisp-value-lines error w)))
         (ms (or (getf entry :ms) 0)))
    (append
     ;; the form, in the prompt's own register — `› ` and plain text, the arrangement the composer
     ;; uses, because that is what a form here is: a line the operator typed
     (loop for r in form-rows
           for i from 0
           collect (list (cons (if (zerop i) "› " "  ") +role-faint+) (cons r nil)))
     ;; the value, and its duration on the row that carries the arrow
     (loop for r in body
           for i from 0
           collect (if (zerop i)
                       (list (cons "  => " +role-faint+) (cons r nil)
                             (cons (format nil " · ~d ms" ms) +role-faint+))
                       (list (cons "     " nil) (cons r nil))))
     ;; or the failure, marker and all — one register, so an error cannot read as a value
     (loop for r in why
           for i from 0
           collect (list (cons (if (zerop i) "  !! " "     ") +role-failure+)
                         (cons r +role-failure+))))))

;;; ------------------------------------------------------------- the eval ;;;

(defun lisp-eval-entry (head line)
  "LINE read and evaluated in this head's image, pushed to the scrollback, and returned.

NIL when LINE is blank: enter on an empty prompt is not an evaluation, and an entry for it would be a
row saying nothing happened (the rule `%submit-line` keeps for a blank Enter).

**THE READ IS THE SOCKET'S READ.** `*package*` is `:leticl`, exactly as `hack-serve` binds it for its
connection, so a form that resolves at `tui-eval` resolves here and a symbol the head does not have is
the same error in both places. The first form on the line wins and anything after it is ignored, which
is what the socket does with `eval <form>` — one path, and this is it.

**A READ ERROR IS AN ENTRY, unlike at the socket** — where it is a reply, because the caller is a
program that wants to know its own form was malformed. Here the caller is a person looking at a pane,
and a form that did not read is the most common thing that will happen to them: it belongs in the
scrollback with the rest of the conversation, not in a message that scrolls away."
  (let ((text (string-trim '(#\space #\tab #\newline #\return) line)))
    (when (plusp (length text))
      (let* ((form (handler-case
                       (let ((*package* (find-package :leticl)))
                         (read-from-string text nil :eof))
                     (error (e) (cons :unreadable e))))
             (entry
               (if (and (consp form) (eq (car form) :unreadable))
                   (list :form text :error (format nil "the form did not read: ~a" (cdr form)) :ms 0)
                   (multiple-value-bind (value condition ms)
                       ;; **NO PAINT LOCK** — this runs on the paint thread; see the file header
                       (hack-eval-form head form)
                     (if condition
                         (list :form text :error (prin1-to-string condition) :ms ms)
                         (list :form text :value (%lisp-print value) :ms ms))))))
        (push entry *lisp-entries*)
        (when (> (length *lisp-entries*) +lisp-entries-max+)
          (setf *lisp-entries* (subseq *lisp-entries* 0 +lisp-entries-max+))
          (incf *lisp-dropped*))
        ;; **THE VIEW FOLLOWS THE TAIL, and only the EVAL moves it.** Scrolling up stays where the
        ;; reader put it — the pane is a document and the keys are theirs — but an answer they just
        ;; asked for is the one thing that must be visible. `*pane-lines*` is the last frame's count,
        ;; so the entry's own rows are added to it rather than a redraw being asked for.
        (incf *pane-lines* (length (%lisp-entry-lines entry (- (head-cols head) +gutter+ +right-margin+))))
        (setf *pane-scroll* (pane-scroll-max))
        entry))))

;;; -------------------------------------------------------------- the pane ;;;

(defun lisp-pane-lines (head cols)
  "The `/lisp` pane: the header, the scrollback oldest-first, and the tally.

Second value is NIL on purpose: **this pane has no cursor.** ↑↓ are the composer's own history — the
forms evaluated here are pushed to it exactly as sent prompts are — so a cursor would be a second
meaning for one key, and the pane would have to choose which the operator meant. `pane-row-count`
answers 0 for it for the same reason.

The prompt itself is not drawn here: it is the composer, at the bottom of the frame, where every other
typed line in this head lives — and the hint bar says what Enter does with it."
  (let* ((entries (reverse *lisp-entries*))
         (n (length entries))
         (ms (reduce #'+ entries :key (lambda (e) (or (getf e :ms) 0)) :initial-value 0))
         (failed (count-if (lambda (e) (getf e :error)) entries)))
    (values
     (append
      (list (list (cons "live lisp" '(:bold t))) nil
           ;; **THE PACKAGE IS NAMED AS THE TREE SPELLS IT** — `:leticl`, lower case, because this is
           ;; prose for a person and every other sentence in this tree writes it that way. The
           ;; DERIVATION stays (it is the package the eval really reads in, which is `hack-serve`'s
           ;; binding and not a literal this pane could drift from).
           (list (cons (format nil "  this head's own image, `:~a`, `*head*` bound — enter evaluates what is in the prompt"
                               (string-downcase (package-name (find-package :leticl))))
                       +role-faint+))
           nil)
     (when (plusp *lisp-dropped*)
       (list (list (cons (format nil "  … ~d earlier form~:p no longer held (the last ~d are)"
                                 *lisp-dropped* +lisp-entries-max+)
                         +role-faint+))))
     (when (zerop n)
       (list (list (cons "  nothing evaluated yet — try `(session-seq (head-session *head*))`"
                         +role-faint+))))
     (loop for entry in entries
           append (append (%lisp-entry-lines entry cols) (list nil)))
     (when (plusp n)
       (list nil
             (list (cons (format nil "  ~d form~:p evaluated~a · ~,1f s in all"
                                 n
                                 (if (plusp failed)
                                     (format nil ", ~d failed" failed)
                                     "")
                                 (/ ms 1000.0))
                         +role-faint+))))
      ;; the second value is NIL: this pane has no cursor (see the docstring). Returning no values
      ;; here would be a pane that draws NOTHING — `multiple-value-setq` takes the first.
      )
     nil)))
