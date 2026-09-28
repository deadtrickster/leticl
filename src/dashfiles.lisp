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

(defparameter +dash-row-formats+
  '("number" "bytes" "rate" "percent" "duration" "ago" "fixed")
  "**A CLOSED set of NAMES, never a format string.** A `format` string in a data file is Lisp's
`format` with extra steps, and it is how a data format becomes a programming language — which is
this design's own stated failure condition. Each name maps to a function or a two-line form the head
already has.")

(defparameter +dash-row-kinds+ '("plain" "dim" "good" "warn" "crit" "pending")
  "The renderer's `:kind` vocabulary, named here so an unknown word falls back to `plain` instead of
becoming a keyword the painter has never seen.")

(defun dash-ms-text (ms)
  "A duration in MS as words a reader can act on, or NIL."
  (when (and ms (numberp ms))
    (let ((s (/ ms 1000.0)))
      (cond ((< s 90) (format nil "~ds" (round s)))
            ((< s 5400) (format nil "~dm" (round s 60)))
            (t (format nil "~,1fh" (/ s 3600)))))))

(defun dash-ago-text (ms)
  (let ((text (dash-ms-text ms))) (and text (format nil "~a ago" text))))

(defun %dash-format-value (v spec series)
  "V as text, by SPEC's `format`. NIL for a value nobody measured — **never a zero**, which is
`dash-rate`'s own rule: `0 tok/s` is a claim about the world and an absent sample is not.

SERIES is the resolved series name, used for the unit a `rate` row prints."
  (when (and v (numberp v))
    (let* ((fmt (or (getf spec :format) "number"))
           (unit (let ((s (and series (gethash series *dash-series*))))
                   (or (and s (getf s :unit)) ""))))
      (cond
        ((string-equal fmt "bytes") (dash-bytes v))
        ((string-equal fmt "percent") (dash-pct v (or (%dash-spec-integer spec :digits) 1)))
        ((string-equal fmt "rate")
         (if (plusp (length unit))
             (format nil "~,1f ~a" (float v) unit)
             (dash-rate v)))
        ((string-equal fmt "duration") (dash-ms-text v))
        ((string-equal fmt "ago") (dash-ago-text v))
        ((string-equal fmt "fixed")
         (format nil "~,vf" (or (%dash-spec-integer spec :digits) 1) (float v)))
        (t (format nil "~:d" (round v)))))))

(defun %dash-series-stat (series which)
  "SERIES' `:peak` `:min` `:mean` or `:last`, or NIL."
  (let ((v (and series (dash-values series))))
    (when (and v (plusp (length v)))
      (cond ((eq which :peak) (reduce #'max v))
            ((eq which :min) (reduce #'min v))
            ((eq which :mean) (/ (reduce #'+ v) (float (length v))))
            (t (aref v (1- (length v))))))))

(defun %dash-slot-value (name spec series value-text value)
  "The value of one `{NAME}`, or NIL when NAME is not one this format knows.

**A closed list of names, and nothing else** — no conditionals, no expressions, no arithmetic. The
whole point of the format being data is that it cannot become a language, and this is the one place
it plausibly could.

**THE TWO PREFIXED FORMS ARE LOOKUPS, AND THAT IS THE WHOLE BOUNDARY** (measured, not chosen for
taste): the SHIPPED system panel's memory row reads `of 251.6G · 34%`, which is its own value's
denominator and its own ratio. A file with no way to name another series could never say what a
built-in already says, so a file could never replace one — which is the whole feature.

`{series:NAME}` renders NAME's last sample with the ROW's own `format`; `{pct:NAME}` renders NAME's
last sample as a percentage, for a series that already IS a fraction. And `{pct}` — no prefix, no
argument — is **this row's own bar fraction**, which is the ratio the built-in draws: `value / of`.
`{pct:NAME}` would have been the wrong tool for that row, and the test written for it MEASURED why:
it renders the DENOMINATOR as a percentage of itself, not used-of-total.

Two prefixes, both a name lookup, no third one: a third would be the signal that the design failed
and the answer is `dash-register` at a REPL, not a bigger grammar."
  (let ((colon (position #\: name)))
    (if colon
        (let ((kind (subseq name 0 colon))
              (arg (subseq name (1+ colon))))
          (cond ((string-equal kind "series")
                 (or (%dash-format-value (and (plusp (length arg)) (dash-last arg)) spec arg) ""))
                ((string-equal kind "pct")
                 (let ((v (and (plusp (length arg)) (dash-last arg))))
                   (or (and v (dash-pct v 0)) "")))
                (t nil)))
        (cond ((string-equal name "unit")
               (let ((s (and series (gethash series *dash-series*))))
                 (or (and s (getf s :unit)) "")))
              ((string-equal name "value") (or value-text ""))
              ((string-equal name "pct")
               (let ((frac (and value (numberp value)
                                (%dash-bar-fraction (getf (getf spec :bar) :of) value))))
                 (or (and frac (dash-pct frac 0)) "")))
              ((string-equal name "peak")
               (or (%dash-format-value (%dash-series-stat series :peak) spec series) ""))
              ((string-equal name "min")
               (or (%dash-format-value (%dash-series-stat series :min) spec series) ""))
              ((string-equal name "mean")
               (or (%dash-format-value (%dash-series-stat series :mean) spec series) ""))
              ((string-equal name "direction")
               ;; **A VALUES VECTOR, not a name** — `dash-direction`'s first argument is the trace
               ;; itself, and the built-ins call it as `(dash-direction (dash-values "sys.load1")
               ;; 20)`. Passing the name MEASURED as a hard error, not a wrong answer: `#\s is not
               ;; of type REAL`, because the name string went into the min/max arithmetic.
               (or (and series (dash-direction (dash-values series) 20)) ""))
              ((string-equal name "age")
               (or (and series (dash-ago-text (dash-age-ms series))) ""))
              ((string-equal name "change")
               (let* ((v (and series (dash-values series)))
                      (delta (and v (plusp (length v))
                                  (- (aref v (1- (length v))) (aref v 0)))))
                 (or (%dash-format-value delta spec series) "")))
              (t nil)))))

(defun %dash-fill-slots (text spec series value-text &optional value)
  "TEXT with `{slots}` replaced. **The one place the format could grow into a language, and it does
not** — the names are `%dash-slot-value`'s closed list.

It exists because the shipped llama panel's tail is `peak 114.4 tok/s  falling`, and `dash-line`
documents its `:tail` as *\"the DENOMINATOR — the unit, the ratio, or the sentence that keeps the
value honest\"*. A literal cannot say that sentence.

**An unknown `{slot}` is left standing in the text**, so a typo is visible on the panel rather than
silently becoming nothing — the same reason a stale series must not be drawn as a zero."
  (when text
    (let ((out (make-string-output-stream))
          (n (length text))
          (i 0))
      (loop while (< i n) do
        (let ((open (position #\{ text :start i)))
          (cond
            ((null open)
             (write-string (subseq text i) out)
             (setf i n))
            (t
             (write-string (subseq text i open) out)
             (let ((close (position #\} text :start (1+ open))))
               (cond
                 ((null close)
                  (write-string (subseq text open) out)
                  (setf i n))
                 (t
                  (let* ((name (subseq text (1+ open) close))
                         (v (%dash-slot-value name spec series value-text value)))
                    (write-string (if v v (subseq text open (1+ close))) out)
                    (setf i (1+ close))))))))))
      (get-output-stream-string out))))

(defun %dash-bar-fraction (of value)
  "VALUE as a 0..1 fraction of OF — a NUMBER, or the last sample of a series named by a STRING.

The `of` a series case is what makes a progress bar mean something for a counter nobody has a
target for: *of the 32 GiB dump*, where the denominator is itself a measurement."
  (when (and value (numberp value))
    (cond ((stringp of)
           (let ((d (dash-last of)))
             (and d (plusp d) (/ value (float d)))))
          ((and (numberp of) (plusp of)) (/ value (float of)))
          (t nil))))

(defun %dash-spec-bar (spec series value)
  "SPEC's `bar` as the renderer's `:bar`: a fraction, a LIST of fractions for a segmented bar, or
NIL. **The `of` form carries the denominator into the drawing**, because a fraction alone cannot say
whether the top of the bar is a target somebody chose or a peak this head happened to see."
  (declare (ignore series))
  (let ((bar (getf spec :bar)))
    (cond
      ((null bar) nil)
      ((eq bar t) value)
      ((listp bar)
       (let ((segs (getf bar :segments)))
         (cond
           (segs (remove nil (mapcar (lambda (seg) (%dash-bar-fraction (getf seg :of) value))
                                     segs)))
           (t (%dash-bar-fraction (getf bar :of) value)))))
      (t nil))))

(defun %dash-spec-kind (spec)
  (let ((k (getf spec :kind)))
    (if (and (stringp k) (member k +dash-row-kinds+ :test #'string-equal))
        (intern (string-upcase k) :keyword)
        :plain)))

(defun %dash-spec-spark (spec series)
  "SPEC's `spark`: `true` means the row's own series, a string names another."
  (let ((s (getf spec :spark)))
    (cond ((eq s t) series)
          ((stringp s) s)
          (t nil))))

;;; ------------------------------------------------- 4. the three job-backed rows ;;;

(defun %dash-job-id (head panel)
  (let ((entry (dash-job-for-panel head panel))) (getf entry :id)))

(defun %dash-job-row (head panel which spec cols)
  "One of the three rows every job-backed panel can draw with NO watcher file at all: `state`,
`produced`, `dropped`.

**`state` and `produced` are `dash-job-rows`' own rows**, taken from it rather than respelled — that
function is where R56's five states live, and a second spelling would let the pane and the file
disagree about whether a job that never ran is quiet. The spec's own `label`, `kind` and `tail`
override what it returns; `dropped` has no row of its own there (it is that row's tail), so it is
built from its series."
  (let* ((base (ignore-errors (dash-job-rows head panel cols)))
         (row (cond ((string-equal which "state") (first base))
                    ((string-equal which "produced") (second base))
                    (t nil)))
         (id (%dash-job-id head panel)))
    (cond
      (row
       (list :label (or (getf spec :label) (getf row :label))
             :value (getf row :value)
             :kind (if (getf spec :kind) (%dash-spec-kind spec) (getf row :kind))
             :tail (or (and (getf spec :tail)
                            (%dash-fill-slots (getf spec :tail) spec nil (getf row :value)))
                       (getf row :tail))))
      ((string-equal which "dropped")
       (let ((d (and id (dash-last (format nil "job.~a.dropped" id)))))
         (list :label (or (getf spec :label) "dropped")
               :value (or (%dash-format-value d spec nil) "—")
               :kind (or (and (getf spec :kind) (%dash-spec-kind spec))
                         (if (and d (plusp d)) :warn :dim))
               :tail (or (getf spec :tail) "output lost off the ring"))))
      (t
       (list :label (or (getf spec :label) which)
             :value "—"
             :kind :dim
             :tail (format nil "no job yet for ~a" (or (getf panel :job) "")))))))

;;; -------------------------------------------------------------- 5. a whole row ;;;

(defun dash-spec-row (head panel spec cols)
  "One row of a file-defined panel, as the renderer's plist.

The order of the keys is the order of the decisions: what the row is ABOUT (a `job` or a `series`),
what it says (value and format), and then the things about the value that keep it honest (bar, tail,
spark, flatness)."
  (let* ((which (getf spec :job)))
    (cond
      ((and which (stringp which)) (%dash-job-row head panel which spec cols))
      (t
       (let* ((series (getf spec :series))
              (value (and series (dash-last series)))
              (value-text (or (%dash-format-value value spec series) "—"))
              (tail-literal (getf spec :tail))
              (tail-text (if tail-literal
                             (%dash-fill-slots tail-literal spec series value-text value)
                             nil))
              ;; FLATNESS IS THE DOOR THE PLATEAU WORK NEEDED: without it `dash-flatness-said`
              ;; is reachable only from Lisp, which is this whole row's complaint one level down.
              ;; **The row's own tail wins when it has one**, which is R56's own rule —
              ;; `dash-flatness-said` returns NIL rather than `flat` so that *something actionable
              ;; beats flat*, and a literal tail IS the something actionable.
              (finding (let ((mode (getf spec :flatness)))
                         (and (stringp mode) series (dash-flatness-said series))))
              (kind (let ((k (getf spec :kind)))
                      (cond (k (%dash-spec-kind spec))
                            ((and finding (stringp (getf spec :flatness))
                                  (string-equal (getf spec :flatness) "warn")) :warn)
                            ((and finding (stringp (getf spec :flatness))
                                  (string-equal (getf spec :flatness) "crit")) :crit)
                            (t :plain)))))
         (list :label (or (getf spec :label) series "")
               :value value-text
               :kind kind
               :bar (%dash-spec-bar spec series value)
               :spark (%dash-spec-spark spec series)
               :tail (or tail-text (and finding finding) "")))))))

;;; --------------------------------------------------------- 6. a whole panel ;;;

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
