;;;; todos.lisp — the todo vocabulary: the marks, their roll-up, and the TODO.md reader
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

(defparameter +todo-marks+
  '(("x" . :done) ("X" . :done) (" " . :open) ("~" . :doing) ("-" . :open))
  "The marks this file's own legend defines and `todo_write` uses, so both halves
of the pane read alike. `-` counts as open: it is a bullet nobody has picked up.")

(defun %todo-mark-of (line)
  "LINE as a checkbox, or NIL.

A checkbox is `- [x] …`, `- [ ] …` or a bare `[x] …` — markdown's list bullet is
optional, because a TODO.md written by hand does not always carry one."
  (let ((trimmed (string-left-trim " " line)))
    (when (>= (length trimmed) 3)
      (let ((body (cond ((and (>= (length trimmed) 6)
                              (or (uiop:string-prefix-p "- [" trimmed)
                                  (uiop:string-prefix-p "* [" trimmed)))
                         ;; strip the bullet AND its space: `- [x] one` → `[x] one`
                         ;; at offset 2. At 3 the body starts `] one` and nothing
                         ;; matches, which is how the first version read every
                         ;; checkbox as prose.
                         (subseq trimmed 2))
                        ((char= (char trimmed 0) #\[) trimmed)
                        (t nil))))
        (when (and body (>= (length body) 3) (char= (char body 0) #\[)
                   (char= (char body 2) #\]))
          (let ((mark (cdr (assoc (string (char body 1)) +todo-marks+ :test #'string=))))
            (when mark
              (values mark (string-left-trim " " (subseq body 4))))))))))

(defun strip-todo-markup (text)
  "`**T1** git init` -> `T1 git init`. Backticks go too; nothing else is
interpreted, because this is a reader and not a renderer."
  (let ((out text))
    (dolist (marker '("**" "`"))
      (loop for i = (search marker out)
            while i
            do (setf out (concatenate 'string (subseq out 0 i) (subseq out (+ i (length marker)))))))
    out))

(defun %todo-rollup (marks)
  "Org's rule for a parent, and the whole of it: every child done makes the parent
done; any child started makes it started; otherwise open."
  (cond ((every (lambda (m) (eq m :done)) marks) :done)
        ((some (lambda (m) (not (eq m :open))) marks) :doing)
        (t :open)))

(defun read-todo-md (body)
  "BODY (a TODO.md) to a list of `todo-row` plists.

Each row: `:indent` (columns before the mark), `:mark` (`:open`/`:doing`/`:done`
or NIL for a heading with no checkboxes under it), `:text`, `:body` (the detail
lines under an item) and `:item` (T for a checkbox row, NIL for a heading).

The indent is carried rather than baked into the text, because it belongs BEFORE
the mark and the mark is the part that gets painted — pre-indented it renders as
`[x]     Phase 0` with the colour in front of the whitespace instead of on the
box. And `:item` exists because a heading carries a mark TOO (its roll-up), so
the mark cannot be what tells a row from a heading."
  (let ((out nil)
        (section nil)
        (items nil)                     ; newest first: mark, head, body
        (collecting nil)
        ;; **THE SOURCE LINE EVERY ITEM WAS PARSED FROM** (R44 editable), so a caller can rewrite
        ;; exactly one line of the file instead of regenerating it.
        ;;
        ;; This is not a convenience. `%todo-row-lines` re-renders a row from its PARSED fields, so
        ;; writing the rows back would reformat the whole file and discard everything this parser
        ;; does not model — prose between items, the `Deps:` indent, wrapping, trailing space. On a
        ;; SHARED, COMMITTED file that is a diff nobody asked for and a conflict for whoever else is
        ;; editing it. The line number is what makes the edit surgical instead.
        (line-no 0))
    (labels ((flush ()
               (when section
                 (if (null items)
                     ;; no box and no cookie: an empty section is one nobody has
                     ;; filled in, and org does not mark it done either. Indent
                     ;; 6, not 4: with no mark to paint, the reference's row is
                     ;; `{pad}{cursor}{text}` at `indent - 2`, and measured
                     ;; against its screen `Dependency graph` sits six in, where
                     ;; a heading WITH a box has its `[x]` at four.
                     (push (list :indent 6 :mark nil :text section :body nil
                                 :item nil)
                           out)
                     (let ((marks (mapcar #'first items)))
                       (push (list :indent 4
                                   :mark (%todo-rollup marks)
                                   :text (format nil "~a  [~a/~a]"
                                                 section
                                                 (count :done marks)
                                                 (length items))
                                   :body nil :item nil)
                             out)
                       ;; oldest first under the heading
                       (dolist (it (reverse items))
                         (push (list :indent 8 :mark (first it) :text (second it)
                                     :body (third it) :item t :line (fourth it))
                               out))))))
             (end-item () (setf collecting nil)))
      (dolist (line (uiop:split-string body :separator '(#\newline)))
        (incf line-no)
        (cond
          ;; `##` and deeper. `###` is a subsection and owns its own items, which
          ;; is what org's outline says too.
          ((or (uiop:string-prefix-p "## " line)
               (uiop:string-prefix-p "### " line))
           (flush)
           (let ((n (if (uiop:string-prefix-p "### " line) 4 3)))
             (setf section (string-trim " " (subseq line n))
                   items nil
                   collecting nil)))
          (t
           (multiple-value-bind (mark text) (%todo-mark-of line)
             (cond
               (mark
                ;; the LINE is the fifth element, carried so an edit can address the file
                (push (list mark (strip-todo-markup text) nil line-no) items)
                (setf collecting t))
               ((zerop (length (string-trim " " line)))
                ;; a blank line CLOSES an item: two items a blank apart would
                ;; otherwise merge, and the prose between a heading and its list
                ;; would land on whatever came before
                (end-item))
               ((and collecting
                     (or (char= (char line 0) #\space)
                         (char= (char line 0) #\tab))
                     items)
                ;; an indented line under an item is that item's DETAIL — where a
                ;; TODO.md puts the commit it pins and the `Deps:` line.
                ;;
                ;; APPENDED, not pushed: the detail reads top-to-bottom as the
                ;; file does, and pushing put the `Deps:` line above the commit it
                ;; was pinned to. `(third (first items))` is the CURRENT item;
                ;; `items` itself is newest-first.
                (let ((det (strip-todo-markup (string-trim " " line))))
                  (setf (third (first items))
                        (append (third (first items)) (list det)))))
               (t (end-item)))))))
      (flush)
      (nreverse out))))

