;;;; dash.lisp — the dashboard vocabulary: a value, a series, a panel, and the keys.
;;;;
;;;; Ported in PHILOSOPHY from `~/Projects/serenedash` (its `fmt.py` and `views.py`), not in
;;;; code. That tree is a Python dashboard for a database server; the point here is that a
;;;; dashboard is a THING A HEAD CAN COMPOSE AT RUNTIME, which is what leticl is for (R60).
;;;;
;;;; **What serenedash got right, and what each rule buys** — every one of these is a bug it
;;;; had first, so they are the reason to port the shape rather than invent one:
;;;;
;;;;   · **ONE COLUMN GRID FOR EVERY PANEL.** Every row goes through `dash-line`, so the glyph
;;;;     column is a single ruler down the frame and the value after it lands on the same
;;;;     screen column in every panel. Built ad hoc, two panels' bars start at different
;;;;     offsets and the frame reads as noise.
;;;;   · **A SPARKLINE IS DRAWN AGAINST A SHARED CEILING** when one is given, so two traces on
;;;;     one panel can be read against each other. Self-scaling made a 260 MB pool that never
;;;;     moves render as a full-height line beside a 34 GB one — each series stretched to its
;;;;     own min and max, which says something about that series' variance and nothing about
;;;;     its size.
;;;;   · **A FLAT SERIES AT ZERO DRAWS NOTHING.** Self-scaling renders a flat series as a
;;;;     mid-height bar on every sample, so thirteen empty pools became thirteen identical
;;;;     stripes: ink that reads as activity and means the opposite.
;;;;   · **A VALUE IS NEVER DRAWN WITHOUT ITS DENOMINATOR.** `34.0G` alone is not a fact;
;;;;     `34.0G` with `of 100.0G, 34%` is. That is what the tail column is for.
;;;;   · **STALE IS NOT ZERO, AND ABSENT IS NOT ZERO.** A frozen collector must not look like a
;;;;     quiet system, and a series nobody has sampled must not draw a line at the floor.
;;;;   · **COLOUR ENCODES CONSEQUENCE**, never decoration: good / warn / critical, and a quiet
;;;;     register for a number that is merely there.
;;;;   · **THE KEY BAR IS GENERATED FROM THE BINDING TABLE**, so it cannot advertise a key that
;;;;     does nothing.
;;;;
;;;; **What is deliberately different here.** serenedash's panels each build their own lines.
;;;; These return ROWS — `(:label :value :bar :tail :kind)` — and the renderer applies the
;;;; grid. That is the difference between a dashboard you WRITE and one you COMPOSE: a panel
;;;; is data, so a new one is a `dash-register` call at a live REPL rather than a function in
;;;; a module, and the grid cannot drift between panels because no panel draws it.

(in-package #:leticl)

;;; =========================================================== constants ;;;

(defparameter +dash-hist+ 160
  "Samples retained per series. serenedash's number, and its reason: deep enough to fill the
tail of a wide terminal, so it is a RETENTION limit rather than a width. At five seconds that
is a bit over thirteen minutes.")

(defparameter +dash-spark+ "▁▂▃▄▅▆▇█" "The eight block glyphs, thinnest to full.")

(defparameter +dash-col-label+ 24
  "The label column. serenedash's 22 plus the two its longest setting name needed; here the
longest label in the llama panel is `prompt tokens cached`, at 20, and the ruler must not
render a label the reader cannot identify.")

(defparameter +dash-col-value+ 11)
(defparameter +dash-col-bar+ 18)

(defparameter +dash-stale-factor+ 3
  "A series is stale after this many intervals without a sample. Three, not one: a single
missed tick is a slow read, and a dashboard that cries stale on jitter trains its reader to
ignore the word.")

;;; ============================================================= 1. values ;;;

(defun dash-bytes (n)
  "N bytes as a person reads it: `34.0G`, `512K`, `0B`. Binary, and it says so.

**NIL IN, NIL OUT** — and that is a rule rather than a convenience. The first version coerced a
missing value to zero, so a panel with no samples read `0B` instead of `—`: an absent
measurement rendering as a confident zero, which is the one thing this whole layer exists to
prevent. A caller that wants a placeholder writes `(or (dash-bytes x) the dash)`."
  ;; **THE NIL GUARD HAS TO BE THE WHOLE BODY, not a coercion.** `(and n (float n))` looked like
  ;; one and was not: `n` stayed NIL and the loop below reached `(abs nil)` and signalled
  ;; `NIL is not of type NUMBER` — so the function raised on exactly the input its docstring
  ;; promises to pass through, and it raised at DRAW time on a panel whose series was empty.
  (when n
    (let ((n (float n)))
      (loop for u across #("B" "K" "M" "G" "T" "P")
            do (when (or (< (abs n) 1024) (string= u "P"))
                 (return (if (string= u "B")
                             (format nil "~d~a" (round n) u)
                             (format nil "~,1f~a" n u))))
               (setf n (/ n 1024))))))

(defun dash-bytes-at (base per sec)
  "BASE bytes plus a growth RATE, which is what makes a storage panel actionable: the number
alone cannot tell filling from full."
  (cond ((and per (plusp (abs per)))
         (format nil "~a ~a~a/~a" (dash-bytes base) (if (plusp per) "+" "-")
                 (dash-bytes (abs per)) (if sec (duration (* 1000 sec)) "s")))
        (t (dash-bytes base))))

(defun dash-rate (n &optional (unit "tok/s"))
  "A rate, or NIL when nobody measured one. **NOT ZERO** — `0 tok/s` is a claim, and the same
distinction serenedash draws between a publisher that is quiet and one that is dead."
  (when (and n (numberp n) (plusp n)) (format nil "~,1f ~a" (float n) unit)))

(defun dash-pct (frac &optional (digits 1))
  "FRAC as a percentage string, or NIL when there is no fraction to state.

**`~,vf` takes the digit count FROM THE ARGUMENT LIST, in parameter order** — so the count comes
first and the value second. Written the other way round it read the VALUE as the digit count and
died with `177.4 is not of type INTEGER`, which is at least the loud kind of wrong: a percentage
is the one place a silent version of this would have printed a plausible wrong number."
  (when (and frac (numberp frac))
    ;; **`~,0F` STILL PRINTS THE POINT** — `~w,dF` emits it whenever a digit count is GIVEN,
    ;; so zero digits came out `86.%`. Zero goes through an integer form instead; anything else
    ;; would be visible only to somebody who read the number.
    (if (zerop digits)
        (format nil "~d%" (round (* 100.0 (float frac))))
        (format nil "~,vf%" digits (* 100.0 (float frac))))))

(defun dash-counter (n) (thousands (round (or n 0))))

(defun dash-spark-band (frac)
  "Which of the eight block glyphs a fraction occupies.

**`floor(* frac 8)` LOOKS RIGHT AND IS OFF BY ONE.** The glyphs are not eight equal steps of a
scale from nothing: `▁` is an eighth TALL and `█` is the whole of it, so index I is `(I+1)/8`
high. `floor` therefore maps a half to index 4 — `▅`, five eighths — and every reading of a
half-full bar comes out a notch too high. `ceiling` puts the half where a reader looks for it:
`▄`, which IS the half-height block.

The clamp is for the ends: a fraction of zero has no glyph under it (`ceiling 0` is 0, and
`1-` would be -1) and is drawn as `▁`, and anything past 1 is `█`."
  (min 7 (max 0 (1- (ceiling (* (float frac) 8))))))

(defun dash-spark (series &key top (width +dash-hist+))
  "SERIES as block glyphs, oldest first, at most WIDTH samples. A STRING, unstyled — the
caller decides the register, and the glyph carries the shape either way.

**Every sample is drawn against the same ceiling when `top` is given**, which is the whole
reason the argument exists: a trace on its own min/max says something about its variance and
nothing about its size, so two traces on one panel cannot be compared. With no `top` the
series scales to itself — right for a lone trace, wrong for a panel of several.

**A FLAT SERIES AT ZERO IS NOTHING, not a mid-height stripe.** Fifteen idle pools each drawing
a row of mid-block ink is a picture of activity that means its absence."
  (let* ((all (or series #()))
         (v (coerce (remove nil (subseq all (max 0 (- (length all) width)))) 'vector)))
    (cond
      ((< (length v) 2) "")
      (top
       (if (every (lambda (x) (<= (float x) 0.0)) v)
           ""
           (with-output-to-string (o)
             (loop for x across v
                   for frac = (min 1.0 (max 0.0 (/ (float x) (float top))))
                   do (princ (aref +dash-spark+ (dash-spark-band frac)) o)))))
      (t
       (let ((lo (reduce #'min v)) (hi (reduce #'max v)))
         (if (< (- hi lo) 1d-9)
             (make-string (length v) :initial-element (aref +dash-spark+ 3))
             (with-output-to-string (o)
               (loop for x across v
                     do (princ (aref +dash-spark+
                                     (dash-spark-band (/ (- x lo) (- hi lo))))
                               o)))))))))

(defun dash-direction (series &optional (window 20) (floor-frac 0.02))
  "One word for a trace's own caption: `climbing`, `falling`, `flat`.

**The caption is the fix, not the line.** A sparkline alone is a shape; a reader cannot tell a
flat one from a noisy one at a glance, and serenedash's rule is that the direction word is what
makes the line mean something.

**The threshold is above the noise floor**, and that is the correction it had to make: a 0.1%
move reported as `climbing` is noise wearing a label, which is worse than saying nothing."
  (let* ((v (remove nil (series-tail series window)))
         (n (length v)))
    (cond ((< n 3) nil)
          (t (let* ((lo (reduce #'min v)) (hi (reduce #'max v))
                    (scale (max (abs hi) (abs lo) 1d-9))
                    (delta (- (float (car (last v))) (float (first v)))))
               (cond ((< (abs delta) (* floor-frac scale)) "flat")
                     ((plusp delta) "climbing")
                     (t "falling")))))))

(defun series-tail (series n)
  (let ((v (or series #())))
    (coerce (subseq v (max 0 (- (length v) n))) 'list)))

;;; ============================================================= 2. series ;;;

(defvar *dash-series* (make-hash-table :test #'equal :synchronized t)
  "series name → a PLIST, whose `:v` is an immutable snapshot vector.

Two properties, and both are load-bearing:

  · **`:synchronized t`**, because this table has TWO THREADS. The collector writes it
    (`leticl-dash-collector`); the painter reads it, from a panel's own `:rows` lambda, on the
    thread drawing the frame. An SBCL hash table is not safe for that by default, and this was
    MEASURED as one: `(sb-ext:hash-table-synchronized-p *dash-series*)` answered NIL while the
    collector had 1984 samples in it.
  · **and a snapshot rather than a buffer that grows in place.** A synchronized table makes
    `gethash` and `setf gethash` atomic with respect to each other, and says NOTHING about the
    vector stored in it — so `vector-push-extend` and `fill-pointer` would still have been
    mutating a vector the painter was walking with `subseq` and `aref`. `dash-note` therefore
    publishes a NEW vector each time, which a reader either sees whole or does not see at all. At
    eighteen series of a hundred and sixty samples that is a few thousand copies per sample,
    every five seconds, which is nothing beside the HTTP request that produced the number.

A `defvar`, for the house reason: a live push must not throw away the running head's history.")

(defvar *dash-interval* 5 "Seconds between samples.")

(defun dash-series-new (name &optional (unit ""))
  (setf (gethash name *dash-series*)
        (list :name name :unit unit :v #() :at 0)))

(defun dash-note (name value &key (unit "") (now *now-ms*))
  "Record one sample of NAME. Returns VALUE, or NIL when nothing was recorded.

**A NIL VALUE IS NOT RECORDED, and that is the point.** The sampler has already decided the
number does not exist; a zero substituted here would be THIS FUNCTION inventing a fact about
the world. A series that stops being fed goes STALE — which `dash-freshness` says out loud —
rather than dropping to the floor and looking idle.

**AND IT PUBLISHES A NEW VECTOR RATHER THAN APPENDING TO THE OLD ONE.** The old one may be in a
painter's hands right now — see `*dash-series*` for why that is not a hypothetical. The retention
rule is unchanged: past `+dash-hist+` the oldest eighth is dropped, which keeps this O(1)-ish
amortized rather than shifting the whole series on every tick.

**AND A SAMPLE NEVER ERASES THE UNIT THE SERIES WAS DECLARED WITH** (R56, §7). This is the defect
that made the whole per-unit floor table dead: a caller with no unit passed the empty string, the
new plist was
rebuilt with the empty string, and the fresh list REPLACED the one `dash-series-new` had just
declared — so
`dash-floor-for` read the 1.0 default for every series in a running head, including the byte
counters, and a genuinely stalled counter jittering by ±100 bytes was called *moving*. MEASURED in
the live head before the fix: `(getf (gethash sys.mem_used *dash-series*) :unit)` was the EMPTY
string while that series had just been declared `B`. The unit is a claim about the SERIES, so it
outlives any sample that does not restate it."
  (when (and value (numberp value))
    (let* ((old (gethash name *dash-series*))
           (v (and old (getf old :v)))
           (n (length v)))
      (when (or (null v) (not (vectorp v))) (setf v #() n 0))
      (let* ((keep (if (>= n +dash-hist+)
                       (- +dash-hist+ (floor +dash-hist+ 8))
                       n))
             (when-now (or now *now-ms*))
             ;; the tail we keep, then the new sample — a fresh SIMPLE-VECTOR, so nothing a
             ;; reader already holds is touched
             (next (make-array (1+ keep) :initial-element 0.0))
             (times (make-array (1+ keep) :initial-element 0))
             (old-t (and old (getf old :t))))
        (when (plusp keep) (replace next v :start2 (- n keep) :end2 n))
        (when (and (plusp keep) old-t (vectorp old-t))
          (replace times old-t :start2 (max 0 (- n keep)) :end2 (min n (length old-t))))
        (setf (aref next keep) (float value)
              (aref times keep) when-now)
        (setf (gethash name *dash-series*)
              (list :name name :unit (if (and unit (plusp (length unit)))
                                         unit
                                         (or (and old (getf old :unit)) ""))
                    :v next :t times :at when-now))))
    value))

