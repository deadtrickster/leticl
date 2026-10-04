;;;; dashfiles.lisp — dashboards as FILES (R56).
;;;;
;;;; THE REQUIREMENT, in the operator's own words: *"if ill ask an agent in a different project to
;;;; create me a nice dashboard for the long running import… that is the goal of having common lisp
;;;; here."* An agent in another project cannot edit this head's source, so a dashboard that exists
;;;; only as a `dash-register` call inside `src/dash.lisp` can only ever be written by the one person
;;;; who did not need the feature — and the operator said so plainly: *"everything is half done."*
;;;;
;;;; So a panel is DATA ON DISK. `dash-register` stays exactly what it was — the live-REPL escape
;;;; hatch, which is what makes a dashboard composable at a running head — and additionally becomes
;;;; the one function this file calls, so a file and a REPL call produce the same panel.
;;;;
;;;; **DATA AND NOT LISP**, which is the decision that cannot be changed later without breaking every
;;;; file anybody wrote: letibot could never read a Lisp dashboard, and an agent in another project
;;;; would have to know Common Lisp to draw a progress bar. JSON, because this head already depends
;;;; on `yason` (`leticl.asd`) and already parses JSON in `src/json.lisp`, letibot reads JSON with
;;;; serde, `~/.config/letibot/` already holds `permission.json`, and this head's TOML reader is the
;;;; *"flat key = value subset"* (`src/prefs.lisp:9`) with no nesting — a dashboard's rows are a
;;;; nested list, so TOML would mean writing a nested-table parser first. See
;;;; `docs/r56-dashboards-from-files.md` §6.
;;;;
;;;; Two directories, lowest precedence first:
;;;;
;;;;   ${XDG_CONFIG_HOME:-~/.config}/letibot/dashboards/*.json     the operator's own
;;;;   <workspace>/.letibot/dashboards/*.json                      the project's own
;;;;
;;;; **A union by `name`, and on a collision the workspace file wins** — not "the workspace
;;;; directory replaces the user one", because a project adds one dashboard without having to
;;;; restate the rest. The operator ruled this shape over the alternative (`modes.tsv`'s single
;;;; user-level file keyed by project root) because it is the only one where an agent in another
;;;; project writes inside ITS OWN CHECKOUT and never reaches into `~/.config`.

(in-package #:leticl)

(defparameter +dash-file-format+ 1
  "The format version this head reads. A file that says a different number is REPORTED, never
guessed at and never rewritten — see `dash-load-file-panels`.")

(defparameter *dash-file-errors* nil
  "`((PATH . MESSAGE) …)` from the last load, newest load first.

**A broken file is a fact on the pane, not a refusal to start.** An operator who edits a dashboard
directory by hand will have a broken file in it eventually, and *\"the head refused to start\"* is
the wrong answer to that — see `dash-load-file-panels` for the whole rule.")

(defvar *dash-file-scope* (make-hash-table :test #'equal)
  "panel name → `(:file PATH :scope :user|:workspace)`. What the pane shows so a reader can tell
where a panel came from. A second table rather than a key inside the panel plist, because
`dash-register` is the API a REPL uses and it does not take an origin.")

(defvar *dash-file-workspace* nil
  "Which workspace the panels were loaded for. A pane opened in a new workspace reloads; see
`dash-file-load-needed-p`.")

;;; ------------------------------------------------------------ 1. where they are ;;;

(defun dash-workspace-config-dir (workspace)
  "`<workspace>/.letibot/`, or NIL when there is no workspace to name.

A directory of the project's own, so an agent working in that project writes inside its own
checkout — the whole point of the operator's ruling. Nothing else in this tree reads `.letibot/`:
this is a NEW convention, and the briefing's premise that a precedence story already existed was
wrong (`~/.config/letibot/head.toml` is one flat file with no per-project sections; measured)."
  (when (and workspace (stringp workspace) (plusp (length workspace)))
    (ignore-errors
      (merge-pathnames ".letibot/"
                       (uiop:ensure-directory-pathname (uiop:parse-native-namestring workspace))))))

(defun dash-file-dirs (&optional (head nil))
  "The dashboard directories, LOWEST PRECEDENCE FIRST, as `((DIR . SCOPE) …)`.

The user directory is `daemon-config-dir`'s — the same `~/.config/letibot/` the daemon's own files
live in, computed by one function so this cannot drift from the pane that lists them."
  (let* ((user (ignore-errors (daemon-config-dir)))
         (ws (let ((w (and head (ignore-errors
                                   (getf (session-wiring (head-session head)) :workspace)))))
               (dash-workspace-config-dir w))))
    (remove nil
            (list (and user (cons (merge-pathnames "dashboards/" user) :user))
                  (and ws (cons (merge-pathnames "dashboards/" ws) :workspace))))))

(defun %dash-file-stem (path)
  "PATH's filename without its extension — the default panel `name`."
  (let* ((name (file-namestring path))
         (dot (position #\. name :from-end t)))
    (if dot (subseq name 0 dot) name)))

(defun %dash-json-objects (dir)
  "`(PATH . SCOPE)` for every `.json` in DIR, sorted by filename so a collision inside ONE directory
resolves deterministically rather than by directory order. NIL when the directory is not there — a
head with neither directory must start normally and show its built-ins."
  (when (and dir (uiop:directory-pathname-p
                  (ignore-errors (probe-file (car dir)))))
    (let ((files (ignore-errors (uiop:directory-files (car dir) "*.json"))))
      (sort (mapcar (lambda (f) (cons (namestring f) (cdr dir))) files)
            #'string< :key #'car))))

;;; ----------------------------------------------------------------- 2. reading ;;;

(defun %dash-spec-integer (spec key)
  "SPEC's integer at KEY, or NIL when absent. Signals when present and not an integer, because a
`\"order\": \"first\"` must be a named refusal rather than a panel quietly drawing at the default."
  (let ((v (getf spec key)))
    (when (not (null v))
      (unless (integerp v)
        (error "~a is ~s — it must be a whole number" key v))
      v)))

(defun dash-read-spec-file (path)
  "PATH as `(values PLIST NIL)`, or `(values NIL MESSAGE)`.

`json-decode` rather than a second `yason:parse` call: one spelling of *this wire's JSON
conventions*, which is what `src/json.lisp` exists to be."
  (handler-case
      (let ((obj (json-decode (uiop:read-file-string path))))
        (if (and (listp obj) (keywordp (car obj)))
            (values obj nil)
            (values nil "the file's top level is not a JSON object")))
    (error (e) (values nil (format nil "~a" e)))))

(defun dash-spec-vocabulary-check (spec path)
  "Signal when SPEC names a row `kind` or `format` this head does not have. NIL when every word is
known — **and that NIL is deliberate: an unreadable word is not the same as an absent one.**

**THE REFUSAL IS AT LOAD, NOT AT DRAW, and that is the whole point.** These two words were validated
nowhere: `%dash-spec-kind` fell back to `:plain` and `%dash-format-value` to `~:d`, so a typo rendered
as a plausible row for ever and the author — who is not at a REPL — never saw a nil to notice. A file
is the boundary where the person who wrote the word is absent, so it is the boundary that has to
speak.

**AND IT NAMES THE FILE, THE WORD, AND THE ROW**, because a message that says *invalid kind* leaves
the reader grepping. The row's label is the handle they wrote themselves.

This is the same shape as `dash-spec-format-check` beside it — one pass over the spec at load, one
named refusal — rather than a check inside the renderer, for the reason `dash-load-file-panels`
gives: no file in these directories can stop the head from starting, and no file can stop another file
from working. A refusal here is a line in the pane.

**PATH IS NOT USED IN ANY MESSAGE HERE, and that is the caller's arrangement rather than an oversight:**
`dash-load-file-panels` catches the signal and pairs it with the path it was reading, so the pane shows
`machine.json: <this sentence>`. The parameter stays because it is what says which file is being
checked — and `dash-spec-format-check` beside it has the same shape."
  ;; **THE DECLARATION COMES AFTER THE DOCSTRING**, which is CLHS's order
  ;; (`[[declaration* | docstring]]` reads as docstring first, then declarations). Written the other
  ;; way round the docstring stops being the docstring — MEASURED: the suite's own docstring check
  ;; reported it as *"1 body form that is not a form"*, because a string after a `declare` is a plain
  ;; string form in a body, which is the exact thing that check exists to find.
  (declare (ignore path))
  (dolist (row (getf spec :rows))
    (when (listp row)
      (let ((kind (getf row :kind))
            (fmt (getf row :format))
            (label (or (getf row :label) (getf row :series) "a row")))
        (when (and kind (stringp kind) (not (member kind +dash-row-kinds+ :test #'string-equal)))
          (error "\"kind\": \"~a\" on row \"~a\" is not a kind this head draws — the words are ~{~a~^, ~}"
                 kind label +dash-row-kinds+))
        (when (and fmt (stringp fmt) (not (member fmt +dash-row-formats+ :test #'string-equal)))
          (error "\"format\": \"~a\" on row \"~a\" is not a format this head renders — the words are ~{~a~^, ~}. **A word it does not know cannot be rendered HONESTLY**, and the cost is a misread of magnitude with no symptom: a byte counter would print 19953650499584 where the author meant 185.8G."
                 fmt label +dash-row-formats+)))))
  nil)

(defun dash-spec-format-check (spec path)
  "Signal unless SPEC declares the format this head reads. NIL is version 1 — a file that does not
say is the first version, which is the only reading that is not a guess."
  (let ((f (getf spec :format)))
    (cond ((null f) +dash-file-format+)
          ((not (integerp f))
           (error "\"format\" is ~s — it must be a whole number" f))
          ((/= f +dash-file-format+)
           (error "written for format ~a; this head reads ~a" f +dash-file-format+))
          (t f))))

;;; ------------------------------------------------------------------ 3. the row ;;;
