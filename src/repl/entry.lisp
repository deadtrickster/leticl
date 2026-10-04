;;;; entry — one evaluated form, as an entry
;;;;
;;;; Split out of `repl.lisp`, which was one 242-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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

