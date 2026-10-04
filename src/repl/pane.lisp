;;;; pane — the /lisp pane: the scrollback, and the pane itself
;;;;
;;;; Split out of `repl.lisp`, which was one 242-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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
