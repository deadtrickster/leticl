;;;; panels — panels from a spec: series, and loading a file's panels
;;;;
;;;; Split out of `dashfiles.lisp`, which was one 651-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun dash-panel-spec-rows (head spec name cols)
  (declare (ignore cols))
  (let* ((panel (gethash name *dash-panels*))
         (rows (getf spec :rows)))
    (if rows
        (mapcar (lambda (row) (dash-spec-row head panel row nil)) rows)
        ;; no rows is an EMPTY panel drawn as one, not a panel that looks broken
        (list (list :label "" :value "" :kind :dim
                    :tail "this file declares no rows")))))

(defun dash-series-declare (name unit)
  "Declare NAME's UNIT **without touching its samples.**

**NOT `dash-series-new`, which is a CREATE and would WIPE the history.** MEASURED on the live head:
reloading a panel file reset every series it named to an empty vector, so `/dash-reload` — the verb
the operator presses after editing a file — threw away the very history the panel exists to draw,
and the freshness chip went to `no data` on a head that had been collecting for an hour. A
declaration is a claim about the series' UNITS; the samples are the series.

The plist is rebuilt rather than mutated, for `*dash-series*`' own reason: a painter may be holding
the old one, and it should either see the whole change or none of it."
  (let ((old (gethash name *dash-series*)))
    (if (and old (listp old))
        (setf (gethash name *dash-series*)
              (list :name name :unit unit
                    :v (getf old :v) :t (getf old :t) :at (or (getf old :at) 0)))
        (dash-series-new name unit))
    name))

(defun dash-panel-from-spec (head spec path scope)
  "Register the panel SPEC describes. Returns its NAME."
  (let* ((name (or (getf spec :name) (%dash-file-stem path)))
         ;; **THE ORIGIN IS A KEY OF ITS OWN, and `dash-panel-lines` draws it** (R56). Not folded into
         ;; `:title`: that is the file's own data, and a panel reporting a title it was never given
         ;; is a small lie in the one place a reader trusts absolutely. Computed HERE rather than read
         ;; back out of `*dash-file-scope*`, which this function writes at the end — on the FIRST load
         ;; it would still be empty and the note would appear only after a reload.
         (note (truncate-to-width
                (format nil "~a~@[ · ~a~]"
                        (file-namestring path)
                        (and (eq scope :workspace) "workspace"))
                24))
         (title (or (getf spec :title) name))
         (order (or (%dash-spec-integer spec :order) 50))
         (watch (let ((w (getf spec :watch)))
                  (cond ((stringp w) w) ((and (listp w) w) (first w)) (t nil))))
         (needs (getf spec :needs)))
    (unless (stringp name)
      (error "\"name\" is ~s — it must be a string" name))
    ;; THE UNITS, declared BEFORE the first sample, which is the whole reason `series` is not
    ;; optional. Measured: in a running head every series has unit `""` today, because no caller
    ;; of `dash-note` ever passes one — so `dash-floor-for` returns the 1.0 default for everything
    ;; and the per-unit floor table is dead. See `docs/r56-dashboards-from-files.md` §7.
    (dolist (s (getf spec :series))
      (let ((sname (getf s :name))
            (unit (or (getf s :unit) "")))
        (when (stringp sname) (dash-series-declare sname unit))))
    (when (and needs (not (listp needs)))
      (setf needs (list needs)))
    (dash-register name
                   :title title
                   :order order
                   :needs (or needs (dash-series-names-in-spec spec))
                   :job watch
                   :rows (lambda (cols) (dash-panel-spec-rows head spec name cols)))
    ;; the origin, for the pane — a second table rather than a `dash-register` argument, because
    ;; `dash-register` is the API a REPL uses and a REPL panel has no file behind it.
    (setf (gethash name *dash-file-scope*)
          (list :file (namestring path) :scope scope :note note))
    ;; and the panel carries the note for the DRAW, because `dash-panel-lines` is given the panel and
    ;; not its origin. A plist key rather than a `dash-register` argument: a REPL panel has no file
    ;; behind it, and inventing an argument for one would make the file case the API's shape.
    (let ((p (gethash name *dash-panels*)))
      (setf (getf p :file-note) note)
      (setf (getf p :file) (namestring path))
      (setf (gethash name *dash-panels*) p))
    name))

(defun dash-series-names-in-spec (spec)
  "Every series a spec's rows name — the default `needs`, so the freshness chip is about this panel's
own numbers rather than about nothing."
  (remove-duplicates
   (remove nil
           (append (mapcar (lambda (r) (getf r :series)) (getf spec :rows))
                   (mapcar (lambda (s) (getf s :name)) (getf spec :series))))
   :test #'string=))

;;; ------------------------------------------------------------ 7. the whole load ;;;

(defun dash-load-file-panels (&optional head dirs)
  "Read every dashboard file and register the panels. Returns `(values COUNT ERRORS)`.

DIRS defaults to `dash-file-dirs` and is a PARAMETER rather than a special variable because the
suite has to exercise this without reading the operator's own `~/.config/letibot/dashboards/` — the
same discipline `*write-prefs*` records for `head.toml`: *a test that changes the answer to the
question it is asking* is worse here than anywhere, because the value is on disk and outlives the
process.

**THE RULE, and it is the answer to *what does a head do with a file it cannot understand*: no file
in these directories can stop the head from starting, and no file can stop another file from
working.** Every failure below is a line in `/dashboards` and nothing more:

  · bad JSON, or a top level that is not an object → skipped, with the parser's own message;
  · a `format` this head does not read → skipped, and the message says exactly which number it is.
    NEVER rewritten, never deleted, never guessed at;
  · an unknown KEY inside a known format → ignored, not an error. The difference is deliberate: a
    version bump is the author saying *this is not the old format*, while an extra key is additive,
    and a head that renders what it can is more useful than one that refuses a file it mostly
    understands;
  · a command or path that does not exist, a `watch` no job matches, a row naming a series nobody
    produces → **not load errors at all**. They are runtime facts: the sampler records nothing,
    `dash-collect-once` keeps the failure on the panel, the `waiting` state is one of R56's five,
    and a missing series draws `—`.

Idempotent and re-runnable: `dash-register` replaces by name, so loading twice is one set of panels,
and a file REMOVED from disk leaves its panel behind until the head restarts — which is the honest
behaviour while `dash-register` is also a live API, since the head cannot tell a REPL panel from one
whose file was deleted."
  (setf *dash-file-workspace*
        (and head (ignore-errors (getf (session-wiring (head-session head)) :workspace))))
  (let ((specs (make-hash-table :test #'equal))
        (errors '())
        (n 0))
    ;; LOWEST PRECEDENCE FIRST, so a later (workspace) file overwrites a user one by name.
    (dolist (dir (or dirs (dash-file-dirs head)))
      (dolist (entry (%dash-json-objects dir))
        (let ((path (car entry)) (scope (cdr entry)))
          (handler-case
              (multiple-value-bind (spec msg) (dash-read-spec-file path)
                (if msg
                    (push (cons path msg) errors)
                    (progn
                      (dash-spec-format-check spec path)
                      ;; **AND THE ROW VOCABULARY, at the same moment and for the same reason** — an
                      ;; unknown `kind` or `format` is a typo the author cannot see, because they are
                      ;; not at a REPL, so the boundary where they are absent is the one that speaks.
                      (dash-spec-vocabulary-check spec path)
                      (let* ((name (or (getf spec :name) (%dash-file-stem path)))
                             (enabled (if (member :enabled spec)
                                          (getf spec :enabled)
                                          t)))
                        (if enabled
                            (setf (gethash name specs) (list :spec spec :path path :scope scope))
                            ;; `enabled: false` is the only way a workspace file can suppress a
                            ;; user-level panel it shadows without deleting the operator's file.
                            (setf (gethash name specs) (list :off t :path path)))))))
            (error (e) (push (cons path (format nil "~a" e)) errors))))))
    (maphash
     (lambda (name entry)
       (if (getf entry :off)
           (dash-unregister name)
           (handler-case
               (progn (dash-panel-from-spec head (getf entry :spec) (getf entry :path)
                                            (getf entry :scope))
                      (incf n))
             (error (e) (push (cons (getf entry :path) (format nil "~a" e)) errors)))))
     specs)
    (setf *dash-file-errors* (nreverse errors))
    (values n *dash-file-errors*)))

(defun dash-file-load-needed-p (&optional (head nil))
  "Has the workspace changed since the panels were loaded? A head attaches, learns its workspace, and
must load the project's dashboards then — but the load at startup happened before that, because
`run` registers the built-ins before it knows where it is."
  (let ((now (and head (ignore-errors (getf (session-wiring (head-session head)) :workspace)))))
    (not (equal now *dash-file-workspace*))))

(defun dash-file-notes ()
  "The pane's lines about the files: how many loaded, and one `!` line per broken one."
  (let ((errors *dash-file-errors*)
        (scopes (loop for n being the hash-keys of *dash-file-scope* collect n)))
    (append
     (list (list (cons (format nil "~d panel~:p from a file~@[ · ~d broken file~:p~]"
                               (length scopes) (and errors (length errors)))
                       (if errors '(:fg :yellow) '(:dim t)))))
     (loop for (path . msg) in errors
           collect (list (cons "  ! " '(:bold t :fg :yellow))
                         (cons (format nil "~a " (file-namestring path)) '(:bold t))
                         (cons msg '(:dim t)))))))
