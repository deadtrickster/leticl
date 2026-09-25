;;;; module-deps.lisp — the dependency graph of leticl's src/, by READING the forms.
;;;;
;;;; The Python version of this that preceded it walked the text with regexes, and
;;;; it was wrong three times in three different ways — every one of them silent:
;;;;
;;;;   1. **tokens instead of call positions.** `(let ((run …)))` in the hidden-run
;;;;      walk is a local variable, and it was reported as a call to `head.lisp`'s
;;;;      `run` from three files that never touch it.
;;;;   2. **a case bug in the filter.** `out` kept the written case while the local
;;;;      set was uppercased, so `out - local` removed NOTHING — the filter looked
;;;;      like it worked while every collision went on being reported as an edge.
;;;;   3. **`)\s*(` read as a binding pair.** In `(f (g x) (h y))` the second call
;;;;      follows a `)` and a space, so every function called after another form
;;;;      was classified as a local — which then DELETED real edges, including
;;;;      `keys.lisp → socket.lisp`'s `wait-for-input`.
;;;;
;;;; Heuristics are the wrong instrument for Lisp. This reads the forms with the
;;;; system's own reader and walks the tree, so a call position is a call position
;;;; and a binding list is a binding list.
;;;;
;;;; **Two limits, stated rather than discovered later.**
;;;;
;;;;   · Symbols are read into packages that exist only to be read, so everything
;;;;     compares by NAME. That is exactly enough for a file-level graph, and it
;;;;     cannot produce the error classes above — but `foo:bar` and `baz:bar` are
;;;;     one name here, which no leticl file can exploit (one package).
;;;;   · A form the reader refuses ends its FILE with a note rather than taking the
;;;;     survey down; a survey that dies on one form reports nothing about the
;;;;     other twenty-six.
;;;;
;;;; Usage:  sbcl --script scripts/module-deps.lisp [FILE]
;;;;           no FILE → the table;   FILE → what that file needs, by name.

;;; ------------------------------------------------------------- the setup ;;;

(defvar *root*
  (merge-pathnames #p"../src/" (or *load-truename* *default-pathname-defaults*))
  "src/ beside this script, wherever the script was found.")

;;; **MAKING `alexandria:assoc-value` READ AT ALL.** Two approaches failed first,
;;; and both are worth recording because each looks like it should work:
;;;
;;;   · **stub packages.** A package must know its symbols, so `alexandria:assoc-value`
;;;     is still a read error with ALEXANDRIA present-but-empty. Measured: the survey
;;;     then died on `uio:getenv`, and then on `sb-posix:getpid`, one file at a time.
;;;   · **a readtable where `:` is a constituent.** `(set-syntax-from-char #\: #\- rt)`
;;;     does not disarm a MACRO character, and the name still parsed as a package
;;;     marker. Measured against a one-line probe before believing it.
;;;
;;; So: a pre-pass finds every `pkg:sym` in the file's TEXT and interns those names
;;; into stub packages. The graph itself still comes from the READER — this only
;;; makes the read succeed, and it touches nothing else about the file.
;;; The prefixes leticl actually uses. A name whose package is not here and does
;;; not already exist is NOT interned: the read then fails and is reported, which
;;; is the honest outcome — a prefix nobody expected is a fact worth knowing, not
;;; something to paper over with a package conjured from a URL scheme.
(defparameter +pkg-prefixes+
  '("alexandria" "anaphora" "yason" "trivial-gray-streams" "sb-alien"
    "sb-concurrency" "sb-posix" "sb-sys" "sb-bsd-sockets" "sb-ext"
    "sb-unix" "sb-impl" "fiveam" "uiop" "asdf" "leticl" "leticl/tests"
    "common-lisp" "cl"))

(defun identifier-char-p (c)
  (or (alphanumericp c) (find c "-!?*+<>/=%.&_~^")))

(defun prepare-reader (path)
  "Intern every `pkg:sym` PATH mentions, so `read` does not refuse the file.

Scans for `:` and takes the identifier on each side. A `:` with nothing before it
(the keyword arguments that are everywhere in this tree) is skipped, and so is a
`#:` — an uninterned name needs no package."
  (let ((text (with-open-file (s path :direction :input :external-format :utf-8)
                (let ((out (make-string-output-stream)))
                  (loop for line = (read-line s nil :eof)
                        until (eq line :eof)
                        do (write-string line out) (terpri out))
                  (get-output-stream-string out)))))
    (loop for i from 0 below (length text)
          when (char= (char text i) #\:)
            do (let ((a i) (b (1+ i)))
                 ;; the package name to the left
                 (loop while (and (> a 0) (identifier-char-p (char text (1- a))))
                       do (decf a))
                 ;; and the symbol name to the right, past any second colon
                 (loop while (and (< b (length text)) (char= (char text b) #\:)) do (incf b))
                 (let ((stop b))
                   (loop while (and (< stop (length text))
                                    (identifier-char-p (char text stop)))
                         do (incf stop))
                   (let ((pkg (subseq text a i)) (sym (subseq text b stop)))
                     (when (and (plusp (length pkg)) (plusp (length sym))
                                (> a 0)
                                (not (char= (char text (1- a)) #\#))
                                (member (string-downcase pkg) +pkg-prefixes+
                                        :test #'string=))
                       (let ((p (or (find-package (string-upcase pkg))
                                    (make-package (string-upcase pkg) :use nil))))
                         ;; **EXPORTED, not merely interned.** `pkg:sym` requires
                         ;; the symbol to be EXTERNAL, and `intern` makes it internal
                         ;; — measured: the survey then failed on every file with
                         ;; `The symbol "ASSOC-VALUE" is not external in the
                         ;; ALEXANDRIA package`.
                         (handler-case (export (intern (string-upcase sym) p) p)
                           (error () nil))))))))
    text))

(defun src-files ()
  (sort (mapcar #'file-namestring
                (remove-if-not (lambda (p) (equal (pathname-type p) "lisp"))
                               (directory (merge-pathnames #p"*.lisp" *root*))))
        #'string<))

(defun read-forms (path)
  (let ((forms '())
        (*read-eval* nil)
        (*package* (find-package :keyword)))
    (prepare-reader path)
    (with-open-file (s path :direction :input :external-format :utf-8)
      (handler-case
          (loop for form = (read s nil :eof)
                until (eq form :eof)
                do (push form forms))
        (error (e) (format *error-output* "~&;; ~a: ~a~%" (file-namestring path) e))))
    (nreverse forms)))

;;; ---------------------------------------------------- what a form DEFINES ;;;

;;; **EVERY COMPARISON IS BY NAME, and this is the trap.** A file read with
;;; `*package*` bound to KEYWORD yields `:DEFUN`, `:LET`, `:QUOTE` — nothing is
;;; `COMMON-LISP-USER::DEFUN`, so an `assoc`/`member` against a normally-interned
;;; list matches NOTHING and the graph comes out empty in every column. Measured:
;;; the first run of this file printed 27 rows of zeros. `kw` puts a symbol in the
;;; same package the reader used, and everything below compares through it.
(defun kw (x)
  (if (symbolp x) (intern (symbol-name x) :keyword) x))

(defparameter +define-kinds+
  '(defun defmacro defgeneric defmethod defstruct defclass
    defparameter defvar defconstant deftype define-symbol-macro))

(defun name-of (x)
  "The defined name in a definition's second position, for the shapes that occur."
  (cond ((symbolp x) x)
        ;; `(defun (setf foo) …)` defines FOO: the operator is not the name.
        ((and (consp x) (eq (kw (car x)) :setf) (consp (cdr x))) (second x))
        ((consp x) (first x))
        (t nil)))

(defun defines (form)
  "Two values: the names this form defines, and whether it is a STRUCT or CLASS
(whose accessors then belong to the same file)."
  (if (and (consp form) (member (kw (car form)) (mapcar #'kw +define-kinds+) :test #'eq))
      (let ((n (name-of (second form))))
        (values (if n (list n) nil)
                (member (kw (car form)) '(:defstruct :defclass) :test #'eq)))
      (values nil nil)))

;;; ------------------------------------------------------- what a form USES ;;;

(defparameter +binding-positions+
  '((:let . 1) (:let* . 1) (:flet . 1) (:labels . 1) (:symbol-macrolet . 1)
    ;; **1, NOT 2, for both of these.** `(multiple-value-bind (vars) values …)`
    ;; and `(destructuring-bind (params) expr …)` put the binding list FIRST; a
    ;; position of 2 made `binding-list-pairs` treat the VALUE as the binding list
    ;; and it died on `:COLOR is not of type LIST`. Measured, on cells.lisp.
    (:macrolet . 1) (:multiple-value-bind . 1) (:destructuring-bind . 1)
    (:dolist . 1) (:dotimes . 1) (:do . 1) (:do* . 1)
    (:with-open-file . 1) (:with-slots . 1) (:with-accessors . 1) (:lambda . 1)
    ;; **A LAMBDA LIST IS A BINDING LIST.** Without these, `(defun render-table
    ;; (head align rows w) …)` was walked as a CALL whose first element is `head`
    ;; — the first PARAMETER of every function in the tree became a reference to
    ;; the symbol of that name, and `head` is the struct head.lisp owns. Measured:
    ;; markdown.lisp was reported as depending on head.lisp. A `defmethod`'s
    ;; lambda list sits after its qualifiers, so it is deliberately NOT listed —
    ;; there are none in src/, and a wrong position would be worse than none.
    (:defun . 2) (:defmacro . 2) (:defgeneric . 2) (:deftype . 2))
  "Head → which argument holds the BINDING LIST (1-based, counting the head as 0).

A binding list's names are not calls; its INIT forms are walked, because
`(let ((x (foo))) …)` does call FOO.")

(defun binding-list-pairs (form)
  "(names . value-forms) from a binding list: `((a 1) b (c 2))`."
  (let ((names '()) (vals '()))
    (dolist (b form)
      (cond ((consp b) (push (name-of b) names) (push (cdr b) vals))
            ((symbolp b) (push b names))))
    (values names vals)))

(defun refs (form)
  "Every symbol this form CALLS: function position, `#'`, or `(function …)`."
  (let ((out '()))
    (labels
        ((walk (f)
           (when (consp f)
             (let ((head (car f)))
               (cond
                 ((eq (kw head) :quote) nil)
                 ((eq (kw head) :function)
                  (let ((g (second f))) (when (symbolp g) (push g out))))
                 (t
                  (when (symbolp head) (push head out))
                  (let ((pos (and (symbolp head)
                                  (cdr (assoc (kw head) +binding-positions+ :test #'eq)))))
                    (if pos (walk-binding-args f pos head) (walk-args f))))))))
         ;; **THE SPINE, not `dolist`.** A LOOP clause like `(loop for (k . v) in
         ;; pairs …)` holds a DOTTED list, and `(dolist (a (cdr f)) …)` on one dies
         ;; with `:V is not of type LIST` — measured, on `cards.lisp`. Walk the
         ;; spine and ignore a non-nil tail.
         (walk-args (f)
           (loop for tail = (cdr f) then (cdr tail)
                 while (consp tail)
                 do (walk (car tail))))
         (walk-binding-args (f pos head-of-form)
           (loop for tail = (cdr f) then (cdr tail)
                 for i from 1
                 while (consp tail)
                 do (let ((a (car tail)))
                      (if (= i pos)
                          (multiple-value-bind (names vals) (binding-list-pairs a)
                            (declare (ignore names))
                            ;; **A LOCAL FUNCTION IS NOT A CALL.** For `flet`,
                            ;; `labels` and `macrolet` the val forms are the local
                            ;; function's own lambda list and body, so walking them
                            ;; would report every parameter name as a call — and a
                            ;; parameter that happens to share a global's name is a
                            ;; false edge of exactly the kind this file exists to
                            ;; avoid. Their BODIES are walked by the caller anyway,
                            ;; because they are still inside the form.
                            (unless (member (kw head-of-form) '(:flet :labels :macrolet)
                                            :test #'eq)
                              (dolist (v vals) (dolist (one v) (walk one)))))
                          (walk a))))))
      (walk form)
      (nreverse out))))

;;; -------------------------------------------------------- the two passes ;;;

(defun survey ()
  "→ owns (name → file), structs (struct name → file), refs (file → symbols), files."
  (let ((owns (make-hash-table :test 'equal))
        (structs (make-hash-table :test 'equal))
        (refs (make-hash-table :test 'equal))
        (files (src-files)))
    (dolist (f files)
      (dolist (form (read-forms (merge-pathnames f *root*)))
        (multiple-value-bind (names struct-p) (defines form)
          (dolist (n names)
            (setf (gethash (string-upcase (symbol-name n)) owns) f)
            ;; **UPPERCASE, because `owner-of` compares against an uppercased
            ;; name.** Stored lowercased, the accessor rule never fired — the key
            ;; was `head` and the name was `HEAD-COLS`, and `string=` is
            ;; case-sensitive. Measured: head.lisp's in-degree read 7 when the
            ;; truth (every `head-…` accessor in the tree) is much higher.
            (when struct-p
              (setf (gethash (string-upcase (symbol-name n)) structs) f))))
        (setf (gethash f refs) (append (gethash f refs) (refs form)))))
    (values owns structs refs files)))

(defun owner-of (name owns structs)
  "The file that owns NAME: by definition, or by being STRUCT-<slot>."
  (let ((up (string-upcase (symbol-name name))))
    (or (gethash up owns)
        (loop for s being the hash-keys of structs using (hash-value file)
              when (and (> (length up) (1+ (length s)))
                        (string= s (subseq up 0 (length s)))
                        (char= (char up (length s)) #\-))
                return file))))

(defun line-count (f)
  (with-open-file (s (merge-pathnames f *root*))
    (loop for l = (read-line s nil :eof) until (eq l :eof) count l)))

(defun main ()
  (multiple-value-bind (owns structs refs files) (survey)
    (let ((needs (make-hash-table :test 'equal))
          (needed (make-hash-table :test 'equal)))
      (dolist (f files)
        (let ((seen '()))
          (dolist (r (gethash f refs))
            (let ((d (owner-of r owns structs)))
              (when (and d (not (equal d f)))
                (push (cons d (symbol-name r)) (gethash f needs))
                (unless (member d seen :test #'equal)
                  (push d seen)))))
          (dolist (d seen) (incf (gethash d needed 0)))))
      ;; **`*posix-argv*` IS THE WHOLE COMMAND LINE** under `--script`: its first
      ;; element is the implementation's path, not the file argument. Measured —
      ;; asking for `progress.lisp` printed the whole table, because the first
      ;; element was `/usr/bin/sbcl` and it was not a file name. The argument is
      ;; whichever element names a source file.
      (let ((arg (find-if (lambda (a) (member a files :test #'equal))
                          sb-ext:*posix-argv*)))
        (if (and arg (member arg files :test #'equal))
            ;; one file: what it needs, by name
            (let ((by (make-hash-table :test 'equal)))
              (loop for (d . s) in (gethash arg needs)
                    do (push s (gethash d by)))
              ;; one name once, with its count: a report that prints
              ;; `TRUNCATE-TO-WIDTH, TRUNCATE-TO-WIDTH, …` reads as a bug in the
              ;; tool rather than as a fact about the file.
              (loop for d being the hash-keys of by using (hash-value ss)
                    do (let ((counts (make-hash-table :test 'equal)))
                         (dolist (x ss) (incf (gethash x counts 0)))
                         (format t "~&~20a ~3d: ~{~a~^, ~}~%"
                                 d (length ss)
                                 (sort (loop for k being the hash-keys of counts
                                             using (hash-value v)
                                             collect (if (> v 1)
                                                         (format nil "~a×~d" k v)
                                                         k))
                                       #'string<)))))
            (progn
              (format t "~&~22a~7a~15a~7a~%" "file" "lines" "referenced_by" "needs")
              (dolist (f (sort (copy-list files)
                               (lambda (a b) (> (gethash a needed 0) (gethash b needed 0)))))
                (format t "~22a~7d~15d~7d~%"
                        f (line-count f)
                        (gethash f needed 0)
                        (length (remove-duplicates
                                 (mapcar #'car (gethash f needs)) :test #'equal))))))))))

(main)
