;;;; rows — a spec row: how its slots, formats and bars are filled
;;;;
;;;; Split out of `dashfiles.lisp`, which was one 651-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)


(defparameter +dash-row-formats+
  '("number" "bytes" "rate" "percent" "duration" "ago" "fixed")
  "**A CLOSED set of NAMES, never a format string.** A `format` string in a data file is Lisp's
`format` with extra steps, and it is how a data format becomes a programming language — which is
this design's own stated failure condition. Each name maps to a function or a two-line form the head
already has.

**CLOSED AT THE FILE BOUNDARY, and the criterion is the one R57 settled** — *closed iff an unknown
value forces the renderer to GUESS; open iff the renderer can render the unknown itself honestly.*
An unknown `format` cannot render honestly at all: it fell through to `~:d`, so a byte counter an
author wrote as `bytes` and meant as `185.8G` came out `19953650499584`. **A silent misread of
magnitude with no symptom**, which is worse than a mis-coloured row, and invisible to the author
because they are not at a REPL to see the nil.

The LISP API is a different boundary and stays OPEN: `dash-register` takes any `:kind` keyword and
`dash-style-for` answers NIL for one it does not know, which is where runtime invention lives and an
unstyled row misleads nobody.")

(defparameter +dash-row-kinds+ '("plain" "dim" "good" "warn" "crit" "pending")
  "The renderer's `:kind` vocabulary, **closed at the FILE boundary** for the reason
`+dash-row-formats+` gives. It used to fall back to `:plain` silently, so a typo on an alarm row —
`\"critcal\"` — rendered as an ordinary row: precisely the cost R57 §3.3 names for a guessed tone,
*\"a guessed colour mis-states consequence, silently, and the reader has no way to know.\"*")

(defun %dash-list-has-duplicates-p (list)
  "T when LIST holds the same word twice. **A registry is not a bag with a lookup rule.**

letibot found the cost of not checking: its classifier held `git symbolic-ref` in BOTH the read arm
and the write arm, the match takes the FIRST, and a command that rewrites `.git/HEAD` was therefore
judged a read and admitted at every tier. Its own conclusion is the rule here — *\"a set that can
hold a name twice is not a registry; it is a bag with a lookup rule, and which of the two entries
wins is decided by source order.\"* And the compiler had already said so as `unreachable pattern`:
*\"a warning is not a decision.\"*

The lists below are short and hand-written, which is exactly the case where a duplicate is a typo
nobody notices — so the check is a TEST that fails the suite rather than a note, because in Lisp a
warn is a line nobody reads."
  (not (equal list (remove-duplicates list :test #'string-equal))))

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

