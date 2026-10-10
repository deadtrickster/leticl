;;;; operator-todos — the operator's todos
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------- the operator's todos ;;;
;;;
;;; **They were head-local, and a restart ate them.** The operator: *"todo items i add do not
;;; survive the head restart."* Correct, and by construction rather than by accident:
;;; `*operator-todos*` is a `defvar` the head fills and nothing writes down — fine for state that
;;; describes RIGHT NOW, wrong for state the operator authored. A todo list is the second kind: they
;;; typed it, it is still true after a restart, and losing it silently is the worst answer because
;;; the pane comes back looking exactly like one they never added anything to.
;;;
;;; **A FILE OF ITS OWN, not a key in `head.toml`**: that file is parsed as TOML-ish key/value pairs
;;; and every value passes through its quoting rules, while a todo carries arbitrary prose —
;;; newlines from alt+enter, quotes, backslashes. `prin1` round-trips all of that, so one printed
;;; item per line in a file of its own is a writer that cannot corrupt the preferences and a reader
;;; that cannot be confused by them.
;;;
;;; **One file per USER, not per head**, like the retired notes: two heads on one project are
;;; looking at one list, and a per-head file would silently show each of them a different one.

(defparameter +operator-todos-cap+ 500
  "How many of the operator's items are kept. Oldest dropped from the front, like the notes set.

A cap because this is the one file here a person writes and never prunes, and an unbounded one would
grow for the life of the project.")

(defvar *operator-todos-path-override* nil
  "A TEST's own legacy todo file. Bound, never set: the default is `operator-todos-path`.

**Because this path is the OPERATOR's**, and a test that reaches the real one does damage rather than
failing: `load-operator-todos` imports whatever is there into the test's database, so a suite that did
not isolate this would read `~/.config/leticl/todos.sexp` and write its rows under a temp store — which
is how this defvar came to exist. MEASURED: a test of the new-project template imported the operator's
own two rows and then asserted about the wrong list. `*store-path-override*` is here for the same reason
and says so in its own docstring; this is the same seam for the file beside it.")

(defun operator-todos-path ()
  "The operator's todo file: beside the preferences, in the head's own config directory."
  (or *operator-todos-path-override*
      (let ((prefs (default-prefs-path)))
        (and prefs (merge-pathnames "todos.sexp" (uiop:pathname-directory-pathname prefs))))))

(defun operator-todos->text (items)
  "ITEMS as one `prin1` form per item — the whole file's contents, ready to write.

`prin1` and not a field separator: a title may contain a newline, a quote or a backslash, and every
hand-rolled encoding of that is a parser waiting to disagree with its writer.

**ONE FORM PER ITEM, and NOT one LINE per item** — the distinction is a bug I shipped and then
measured. `prin1` writes a newline inside a string as a REAL newline (it is `\n` in the source of a
test, and a real character in the data), so an item whose title spans lines occupied two lines of the
file, and a reader that split on newlines lost it. The reader reads FORMS (`text->operator-todos`);
the writer's `terpri` is only there to make the file readable to a person."
  (with-output-to-string (out)
    (dolist (item items)
      ;; **`*print-readably*` NIL, and that is not a detail.**
      ;;
      ;; Measured on the first real write: with it T, SBCL prints a STRING as its own array type —
      ;; `(:ID #A((2) BASE-CHAR . \"t1\") …)` — which is readable and horrible, and ties the file's
      ;; bytes to one implementation's idea of how a string prints. Nil gives the quoted form every
      ;; Lisp reads back identically, which is what a file another head (or a person with an editor)
      ;; may open has to contain.
      (let ((*print-pretty* nil) (*print-circle* nil) (*print-length* nil)
            (*print-level* nil) (*print-readably* nil)
            (*print-escape* t))
        (prin1 item out)
        (terpri out)))))

(defun text->operator-todos (text)
  "The items in TEXT that can be READ, in order. A line that cannot, is skipped.

**Skip rather than refuse**, the opposite of the notes file's rule and for a reason: a todo is one row
of a list, so a line this build cannot read costs that row. Refusing the whole file — right for a
retired set, where a partial read would re-state warnings the operator dismissed — would cost every
row because one was corrupt."
  (let ((items nil)
        (*read-eval* nil)
        (*package* (find-package :keyword)))
    ;; **FORMS, not lines** — see the writer's docstring: a title with a newline in it is one form
    ;; over two lines, and a line splitter loses exactly the items a person is most likely to have
    ;; typed. `read` treats the newline as whitespace INSIDE the string, which is what it is.
    (with-input-from-string (in text)
      (loop
        (let ((item (handler-case (read in nil :eof)
                      ;; a form this build cannot read: skip the rest of its line and go on. A
                      ;; todo is one row of a list, so a corrupt form costs that row and not the
                      ;; file — the opposite of the notes rule, and for this reason.
                      (error () (read-line in nil nil) :unreadable))))
          (when (eq item :eof) (return))
          (when (and (consp item) (stringp (getf item :id))
                     (stringp (getf item :content)))
            (push item items)))))
    ;; **THE COUNT IS TAKEN BEFORE THE REVERSAL, and getting that wrong lost every item but one.**
    ;;
    ;; `(last (nreverse items) (min (length items) +operator-todos-cap+))` reads as correct and is
    ;; not: arguments are evaluated LEFT TO RIGHT, so `nreverse` runs first, and it is DESTRUCTIVE —
    ;; it walks the conses setting each `cdr`, which leaves `items` (still pointing at the ORIGINAL
    ;; head cons, now the tail) as a one-element list. `(length items)` therefore answers **1**, and
    ;; `(last reversed 1)` keeps exactly the last element.
    ;;
    ;; MEASURED on the live head: a file with three items read back as one — always the LAST, which
    ;; is what pointed at the tail of the list rather than at the read loop. The same expression with
    ;; a literal count returns all three, which is why it survived the first reading:
    ;;
    ;;     (let ((items (list 1 2 3))) (last (nreverse items) (min (length items) +operator-todos-cap+)))
    ;;     => (1)
    ;;
    ;; `items` is NEWEST FIRST (the pushes), so the items to keep are at the END and the reversal
    ;; goes last. One binding, and the order of the two operations is the whole fix.
    (let ((kept (min (length items) +operator-todos-cap+)))
      (nreverse (last items kept)))))

(defun read-operator-todos (&optional (path (operator-todos-path)))
  "`(values ITEMS READABLE-P)` from PATH — the same three cases `read-retired-keys` names.

**Unreadable is not empty**, and it decides whether the head may WRITE: a file that cannot be read
must not be saved over, or a permissions error costs the operator the list it could not see."
  (cond
    ((null path) (values nil t))
    ((not (probe-file path)) (values nil t))
    (t (handler-case (values (text->operator-todos (uiop:read-file-string path)) t)
         (error () (values nil nil))))))

