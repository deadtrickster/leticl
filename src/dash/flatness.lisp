;;;; flatness — FLATNESS, robustly
;;;;
;;;; Split out of `dash.lisp`, which was one 1569-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------- FLATNESS, robustly ;;;
;;;
;;; **PORTED IN SUBSTANCE FROM `~/Projects/serenedash/src/serenedash/anomaly.py`**, which solved most
;;; of this and did not generalise it. Its detectors are all about something GROWING — `spike`,
;;; `shift`, `trend` — while `flat` exists once, hand-rolled inside ONE panel
;;; (`views.py`'s storage tail), as a three-way choice over a local delta. So the concept is proven
;;; and ungeneralised, which is the opening this takes: **direction-and-duration becomes a thing A
;;; SERIES ANSWERS**, and every source — a Lisp function, a command, a daemon job — gets it for
;;; nothing and no panel has to know.
;;;
;;; Three of that file's decisions travel with it, because each is a trap it already paid for:
;;;
;;;   · **MEDIAN AND MAD, NOT MEAN AND STANDARD DEVIATION.** Both are computed over a window that
;;;     CONTAINS the event being looked for, so a mean is dragged toward the excursion and a standard
;;;     deviation is inflated by it — the failure gets worse exactly as the event gets bigger. MAD
;;;     has a 50% breakdown point; `+mad-to-sigma+` is 1.4826 so a multiplier reads in familiar
;;;     units even though the data are not normal.
;;;   · **AN ABSOLUTE FLOOR PER UNIT.** A genuinely flat series has a MAD of ZERO, and every
;;;     rounding wobble is then infinitely many sigmas. Measured over there at 8 MiB of allocator
;;;     noise against a 34 GB pool; here it is the last digit of a float.
;;;   · **A MINIMUM WINDOW IN SAMPLES, NOT SECONDS.** `*dash-interval*` is settable, so a rule keyed
;;;     on wall time silently changes meaning when somebody passes `(dash-start 60)`.
;;;
;;; And the sentence worth putting above the feature: *"Each detection carries the baseline it was
;;; judged against, the value that arrived, and the window, which is what makes it arguable rather
;;; than authoritative."* An unarguable claim is the one that gets ignored.

(defparameter +mad-to-sigma+ 1.4826
  "MAD scaled so a multiplier reads in familiar units. serenedash's constant and its reason: the
data here are not normal, but `6` should still mean what a reader thinks `6` means.")

(defparameter +dash-flat-floor+ '(("B" . 1048576.0) ("bytes" . 1048576.0) ("%" . 5.0)
                                  ("percent" . 5.0) ("s" . 30.0) ("ms" . 500.0))
  "**THE FLOOR, PER UNIT, and it is the whole trick on a flat series.** A series that is genuinely
flat has a MAD of exactly ZERO, so every last-digit wobble is infinitely many sigmas and every flat
series in the fleet reports itself as maximally anomalous.

serenedash's numbers where they exist — 64 MiB for bytes, 5.0 for percent — and lowered to 1 MiB
here because a head watches counters and rates, not a 34 GB pool; a byte floor of 64 MiB would leave
every counter in this head unable to be flat at all. A unit nobody named gets the DEFAULT, and the
default is deliberately small: the floor is a guard against float noise, not a judgement about what
counts as a change.

**PER UNIT AND NOT PER SERIES.** A floor a caller can pass is a floor that gets passed `0`.")

(defparameter +dash-flat-unit-default+ 1.0)

(defparameter +dash-flat-window+ 8
  "How many samples the flatness test looks at. Eight, because the question is *has the recent tail
moved* and a longer test is slower to notice a recovery.")

(defparameter +dash-flat-min-samples+ 12
  "**The minimum window before the rule may speak, IN SAMPLES.** serenedash's `MIN_SPIKE`/`MIN_TREND`
make the same point as *\"a trend needs enough of a window that a query starting is not a trend\"*:
below this a series has no past to be measured against, and the honest answer is silence.

Samples and not seconds for the reason its sibling above gives — `*dash-interval*` is settable.")

(defun dash-floor-for (unit)
  "The absolute floor for UNIT, or the default. Case-insensitive, because a unit is a word somebody
typed rather than an enum.

**AND THAT CLAIM WAS FALSE WHEN WRITTEN (R56, §7).** The function downcased the UNIT and compared
it against a table whose keys carry their own case, so `B` — the single most likely spelling for a
byte series, and the one the suite's own `%feed` uses — never matched itself. MEASURED on the live
head: `(:BYTES 1048576.0 :B 1.0 :PCT 5.0 :S 30.0 :UNKNOWN 1.0)`. So a byte counter that had genuinely
stalled and jittered by ±100 bytes got the 1.0 default and was called MOVING, while the 1 MiB floor
that exists for exactly that series was unreachable. One spelling of case-insensitivity on both
sides of the comparison is the whole fix.`"
  (or (and unit
           (let ((u (string-downcase unit)))
             (cdr (assoc u +dash-flat-floor+ :test #'string-equal))))
      +dash-flat-unit-default+))

(defun dash-median (values)
  "The median of VALUES (a vector), by sorting a copy. NIL for none."
  (let* ((v (coerce values 'vector))
         (n (length v)))
    (when (plusp n)
      (let ((sorted (sort (copy-seq v) #'<)))
        (if (oddp n)
            (aref sorted (floor n 2))
            (/ (+ (aref sorted (1- (floor n 2))) (aref sorted (floor n 2))) 2.0))))))

(defun dash-spread (values unit)
  "Two values: the MEDIAN of VALUES and its scaled MAD with UNIT's floor applied.
serenedash's `spread`, and the floor is why it takes a unit at all."
  (let* ((n (length values))
         (med (or (dash-median values) 0.0)))
    (if (zerop n)
        (values 0.0 (dash-floor-for unit))
        (let* ((devs (make-array n :initial-element 0.0)))
          (dotimes (i n) (setf (aref devs i) (abs (- (aref values i) med))))
          (values med (max (dash-floor-for unit) (* +mad-to-sigma+ (or (dash-median devs) 0.0))))))))

(defun dash-window (name &optional (n +dash-flat-window+))
  "The last N samples of NAME, as a vector, or NIL when there are none."
  (let ((v (dash-values name)))
    (when (and v (plusp (length v)))
      (let ((at (max 0 (- (length v) n))))
        (subseq v at)))))

(defun dash-rhythm-ms (name)
  "The median gap between NAME's changes, in ms, or NIL when there are fewer than two.

**AND FEWER THAN TWO MEANS THERE IS NO RHYTHM TO SPEAK OF**, which is a correction worth recording:
the first cut of this rule divided the whole span by the number of moves, so a series that moved
ONCE over eleven samples was given a rhythm of the entire span and a bar of twice that — which no
amount of quiet could reach. MEASURED: a series that stopped at t=30s was still not flat at t=71s,
because its single move made the ratio 110 seconds. With one move there is no evidence about how
often the thing moves, so the caller abstains and the window floor governs."
  (let* ((v (dash-values name))
         (t* (dash-times name))
         (n (and v (length v))))
    (when (and n t* (>= n 2))
      (let ((gaps (loop for i in (dash-changes name) collect (aref t* i))))
        (when (>= (length gaps) 2)
          (let ((step (loop for (a b) on gaps while b collect (- b a))))
            (and step (dash-median (coerce step 'vector)))))))))

(defun dash-flatness (name &optional (now *now-ms*))
  "**HAS THIS SERIES STOPPED MAKING PROGRESS?** — a FINDING, or NIL.

**Five fields, and every one is evidence rather than decoration**, because that is what makes the
claim arguable rather than authoritative:

    :series    which one
    :held-ms   how long it has been flat — **a DURATION, not a colour**
    :baseline  the median it was judged against
    :value     the value that arrived
    :window    how many samples the judgement looked at

**`held-ms` IS THE AFFORDANCE, and it is the one this vocabulary was missing.** ABSENT, STALE and
ZERO are states; flatness is a state PLUS HOW LONG IT HAS HELD, and a reader can weigh *flat 20s*
against *flat 3h* without being told which matters — where a yellow cell cannot say that at all.

It is none of the three states that already existed. The collector is healthy (not stale), the value
is there (not absent), and it is **present and non-zero** (not idle) — and it is not changing:

  1. **enough history** — `+dash-flat-min-samples+`, in SAMPLES;
  2. **non-zero** — the operator's own words;
  3. **the recent tail is at its FLOOR** — `dash-spread` of the last `+dash-flat-window+` samples,
     whose MAD collapses to the floor when nothing has moved. **Measured, not compared to zero**, so
     a float's last digit cannot call a flat series anomalous;
  4. **and it has held longer than twice its own rhythm**, when a rhythm exists — the over-calling
     protection. *\"A fuzzer that finds something every twenty minutes has not plateaued at minute
     nineteen\"*, and a reader told otherwise learns to ignore the word."
  (let* ((v (dash-values name))
         (t* (dash-times name))
         (n (and v (length v)))
         (unit (let ((s (gethash name *dash-series*))) (and s (getf s :unit)))))
    (when (and n t* (>= n +dash-flat-min-samples+))
      (let* ((last (aref v (1- n)))
             (recent (dash-window name))
             (changed (dash-last-change-at name))
             (since (or changed (aref t* 0)))
             (held (- (or now *now-ms*) since))
             ;; **THE MOVE MUST BE OLDER THAN THE FLAT WINDOW, and this is the trap MAD cannot
             ;; catch.** MAD's 50% breakdown point is why it ignores ordinary variation, and the
             ;; same property makes a SINGLE jump invisible: seven identical samples and one
             ;; outlier give a median deviation of zero, so a series that has just jumped reads as
             ;; perfectly flat. MEASURED — `(10 10 10 10 10 10 10 99)` was called flat.
             ;;
             ;; serenedash's own `GROWTH_RISING` exists for the mirror of this (*"one jump at the
             ;; end of a flat series is a perfect trend"*), so the guard is the same shape at the
             ;; other end: the value must have been still for the WHOLE window being judged, not
             ;; merely for most of it.
             (wstart (aref t* (max 0 (- n +dash-flat-window+))))
             (aged (<= since wstart))
             (rhythm (dash-rhythm-ms name))
             (flatp (multiple-value-bind (med spread) (dash-spread recent unit)
                      (declare (ignore med))
                      ;; **AT THE FLOOR**, which is `<=` and not `=`: a spread that has collapsed is
                      ;; exactly the floor, and a tolerance here would be a second number to tune.
                      (<= spread (dash-floor-for unit)))))
        (when (and flatp
                   aged
                   (not (zerop last))
                   (or (null rhythm) (>= held (* 2 rhythm))))
          (let ((all (dash-window name (length v))))
            (multiple-value-bind (med spread) (dash-spread all unit)
              (list :series name
                    :held-ms held
                    :baseline med
                    :value last
                    :window (length all)
                    :spread spread
                    :unit (or unit "")))))))))

(defun dash-plateau-p (name &optional (now *now-ms*))
  "Is NAME flat? The predicate behind `dash-flatness`, which carries the evidence."
  (and (dash-flatness name now) t))

(defun dash-flat-said (finding)
  "FINDING as the words a row or a marker carries: `flat 3h`, or `flat 20s`.

**The duration is the whole sentence on purpose.** It is the fact a reader weighs, and a bare
`flat` would make every plateau look the same size."
  (and finding (format nil "flat ~a" (duration (max 0 (floor (getf finding :held-ms)))))))

(defun dash-plateaued (&optional (now *now-ms*))
  "Every series that has stopped moving — the list a frame surfaces without being opened.

**ATTENTION, NOT DISPLAY.** With eleven dashboards the operator does not want eleven sparklines;
they want to know which ones stopped. A frame that requires reading every panel to find the stuck
one has moved the work rather than done it.

NOW is a parameter for the reason every other clock question here takes one: a frame and a test must
be able to ask *as of this instant* rather than as of whenever `*now-ms*` was last set."
  (loop for name being the hash-keys of *dash-series*
        when (dash-plateau-p name now) collect name))

(defun dash-flatness-said (name &optional (now *now-ms*))
  "`flat 3h` for NAME when it is flat, or NIL — **and NIL means a panel says its own thing instead**,
which is serenedash's `views.py`: *\"Orphaned beats flat … That is a reclaimable number, which is
worth more than another word for 'not moving'.\"*

**A plateau is a WEAK finding**, and this is the function that admits it: a panel with something
actionable to say about a row should say that, and `flat` is what is left when it has nothing
better. Returning NIL rather than `flat` is how a panel expresses that without knowing this rule
exists."
  (dash-flat-said (dash-flatness name now)))

(defun dash-times (name)
  "NAME's sample timestamps, parallel to `dash-values`. Recorded per sample rather than kept as one
`at`, because a flatness claim is a claim about WHEN the value last moved."
  (let ((s (gethash name *dash-series*))) (and s (getf s :t))))

(defun dash-changed-p (a b unit)
  "Did the value move from A to B by more than UNIT's FLOOR?

**A CHANGE IS A MOVEMENT BIGGER THAN THE NOISE FLOOR, and without that the floor would be applied in
one place and not another.** A byte series wobbling in its last digit differs from sample to sample,
so a `/=` test calls every pair a change — and then the series' *last change* is always the newest
sample, which makes every flat series look like it moved a moment ago and no plateau is ever
reported. Same floor, same reason, applied once."
  (>= (abs (- (float a) (float b))) (dash-floor-for unit)))

(defun dash-changes (name)
  "The indices at which NAME moved by more than its floor."
  (let* ((v (dash-values name))
         (s (gethash name *dash-series*))
         (unit (and s (getf s :unit)))
         (n (and v (length v))))
    (when (and n (> n 1))
      (loop for i from 1 below n
            when (dash-changed-p (aref v (1- i)) (aref v i) unit) collect i))))

(defun dash-last-change-at (name)
  "When NAME's value last moved by more than its floor, or NIL.

**Consecutive samples, and floor-aware** — see `dash-changed-p` for why a raw `/=`. A fuzzer that
finds something every twenty minutes moves ONCE at minute twenty; every sample before it equals the
one before, and this reads that as *the last change was when it moved*, which is the fact the
duration is measured from."
  (let* ((v (dash-values name))
         (t* (dash-times name))
         (idx (dash-changes name)))
    (when (and v t* idx)
      (aref t* (car (last idx))))))

(defun dash-values (name) (let ((s (gethash name *dash-series*))) (and s (getf s :v))))
(defun dash-last (name)
  (let ((v (dash-values name))) (and v (plusp (length v)) (aref v (1- (length v))))))

(defun dash-age-ms (name &optional (now *now-ms*))
  (let ((s (gethash name *dash-series*)))
    (when (and s (plusp (getf s :at))) (max 0 (- (or now *now-ms*) (getf s :at))))))

(defun dash-stale-p (name &optional (now *now-ms*))
  (let ((age (dash-age-ms name now)))
    (and age (> age (* 1000 *dash-interval* +dash-stale-factor+)))))

(defun dash-freshness (name &optional (now *now-ms*))
  "A chip for a panel header: `(:live \"live\")`, `(:stale \"stale 42s\")`, `(:no-data \"no data\")`.
**Three facts, not two** — a series with no samples and a series that stopped are different
things, and neither is a zero."
  (let ((s (gethash name *dash-series*)))
    (cond ((or (null s) (zerop (length (getf s :v)))) (list :no-data "no data"))
          ((dash-stale-p name now)
           (let ((age (dash-age-ms name now)))
             (list :stale (format nil "stale ~a" (duration (or age 0))))))
          (t (list :live "live")))))

(defun dash-oldest-freshness (names &optional (now *now-ms*))
  "The worst freshness among NAMES — what a panel's header should say when it reads several
series, because a panel is only as live as its stalest input."
  (let ((worst (list :live "live")) (rank '(:live 0) ))
    (dolist (n names)
      (destructuring-bind (kind word) (dash-freshness n now)
        (let ((r (case kind (:no-data 2) (:stale 1) (t 0))))
          (when (> r (second rank)) (setf rank (list kind r) worst (list kind word))))))
    worst))

(defun dash-reset-series () (clrhash *dash-series*) (values))

;;; ============================================================= 3. panels ;;;
;;;
;;; A panel is DATA and its rows are plists, so the renderer applies the grid and a new panel
;;; is a `dash-register` call rather than a function in this file.
;;;
;;; A ROW is a plist:
;;;   :label  the ruler's left column
;;;   :value  right-aligned in its own column (a string)
;;;   :bar    0..1, or a list for a segmented bar, or NIL for none
;;;   :tail   the DENOMINATOR — the unit, the ratio, or the sentence that keeps the value honest
;;;   :kind   :plain (default) :dim :good :warn :crit :pending
;;;   :spark  a series name, drawn in the bar column instead of a bar

(defvar *dash-line-map* nil
  "The pane LINE each panel starts on, as a VECTOR — indexed with `aref` by `dash-panel-at-line`,
which walks it backwards to find the box a click is inside. Written by the last `dash-frame-lines`.

Read by the click through `dash-panel-at-line`, and by nothing else. **It is set by the DRAW and
not returned**, because the frame's full-body arm binds a pane function's second value to the
cursor's line — see the comment in `dash-frame-lines` for the crash that taught this.")

(defvar *dash-panels* (make-hash-table :test #'equal))
(defvar *dash-order* nil "Registration order, as names.")

(defun dash-register (name &key title rows (order 50) needs job feed)
  "Register or replace a panel. Returns NAME.

    (dash-register \"llama\" :title \"llama\" :needs '(\"llama.gen\")
      :rows (lambda (cols) (list (list :label \"gen rate\" :value … :bar …))))

**That call at a live REPL is the whole API**, and it is what makes a dashboard a thing the
operator composes rather than a thing a programmer ships. Replacing an existing NAME keeps its
place in the order, so re-registering a panel while watching it does not move it.

**`:job` binds the panel to a background job, and `:feed` says how to read it.** With `:job`
alone the panel gets the two series every job has and no parsing is needed:

  · `produced` — everything the job has written, a MONOTONIC TOTAL, which for a long-running
    import is the most useful line on the panel;
  · `dropped` — bytes that fell off the ring, which a parser counting lines cannot recover from.

`FEED` is a function of the `JobOutput` window returning `(series-name . value)` pairs — **the same
contract a sampler has**, so a job-backed feed is registered where the panel is and a REPL call
still composes a whole dashboard. That property is worth more than any elegance in the plumbing: a
feed that needed a code change in a module would make the dashboard a thing a programmer ships."
  (setf (gethash name *dash-panels*)
        (list :name name :title (or title name) :rows rows :order order :needs needs
              :job job :feed feed))
  (unless (member name *dash-order* :test #'string=) (push name *dash-order*))
  (setf *dash-order*
        (stable-sort *dash-order* #'<
                     :key (lambda (n) (or (getf (gethash n *dash-panels*) :order) 50))))
  name)

(defun dash-job-matches-p (job want)
  "Does JOB satisfy the name WANT a panel was registered with?

**THE RULE, IN ONE PLACE, because it is asked in BOTH DIRECTIONS** — `dash-panel-for-job` goes
job → panel (the pane asks *is there a dashboard for this row*) and `dash-job-for-panel` goes
panel → job (the feed asks *has my job appeared yet*). Two spellings of this match would let the
pane say one thing and the feed do another, and the failure would be a panel that never fills.

The match is a substring of the job's COMMAND, or its exact `:id`, and the reason is the one that
makes this usable at all: a job's id is known the moment the daemon reports it, but a panel is
registered **before** the job exists — the operator writes a dashboard for a llama server, and the
job that starts it is named afterwards. So the association is made on the thing both sides have: the
command line. `:job \"llama\"` catches `./llama-server -m …` however the operator spelled it.

An **exact id** is checked too, because a panel registered while watching a specific job should be
able to name it, and an id is the only unambiguous handle there is.

Case-insensitive on the command: a path and a name in a command line are the same word to a reader,
and `Llama-Server` is not a different program."
  (and want job
       (or (string-equal want (or (getf job :id) ""))
           (let ((cmd (or (getf job :command) "")))
             (and (plusp (length cmd))
                  (search (string-downcase want) (string-downcase cmd)))))))

(defun dash-panel-for-job (job)
  "The panel registered for JOB, or NIL. See `dash-job-matches-p` for the match, which is shared."
  (when (and job (or (getf job :command) (getf job :id)))
    (find-if (lambda (p) (dash-job-matches-p job (getf p :job))) (dash-panels))))

(defun dash-job-for-panel (head panel)
  "The daemon's job entry a PANEL is bound to, or NIL.

**The other direction of `dash-panel-for-job`, through the same rule** — and it is the feed's whole
matching problem: the daemon's list is the only place a job's id, state and `running` flag exist, so
this is what turns a panel's `:job \"llama\"` into the `\"j12\"` that `read_job_output` takes."
  (let ((want (getf panel :job)))
    (and want (find-if (lambda (j) (dash-job-matches-p j want)) (head-jobs head)))))

(defun dash-unregister (name)
  (remhash name *dash-panels*)
  (setf *dash-order* (remove name *dash-order* :test #'string=))
  (values))

(defun dash-panels () (remove nil (mapcar (lambda (n) (gethash n *dash-panels*)) *dash-order*)))

(defun dash-job-panels ()
  "How many panels are attached to a job. The jobs pane's hint bar uses it to say whether the key is
worth pressing — a hint that names a key which does nothing is the defect `dash-bindings` exists to
avoid, one pane over."
  (count-if (lambda (p) (getf p :job)) (dash-panels)))

(defun dash-clear-panels () (clrhash *dash-panels*) (setf *dash-order* nil) (values))

;;; =========================================================== 4. the keys ;;;
;;;
;;; serenedash's `BINDINGS` is a table of `(key name label)` and its key bar is GENERATED from
;;; it, so the bar cannot list a key that does nothing. The nav contract is the other half and
;;; it is the subtle one: **a nav returns NIL to mean "not mine"**, and the caller then leaves
;;; the view. `esc` inside an open row closes the row; `esc` with nothing open leaves the pane.

(defvar *dash-views* nil
  "`(key name label)` triples. Registered rather than coded, so a head can offer a dashboard it
did not ship with.")

(defun dash-bind (key name label)
  (setf *dash-views* (remove name *dash-views* :key #'second :test #'string=))
  (setf *dash-views* (append *dash-views* (list (list key name label))))
  name)

(defun dash-bindings ()
  "The key bar, generated from the table. **The keyboard is the documentation or it is a lie.**
A bar listing a key the handler does not have is worse than a shorter bar — serenedash shipped
one that advertised `q` and `x` to a browser that could do neither, and found it by reading."
  (format nil "~{~a~^   ~}"
          (loop for (k _n l) in *dash-views* when l collect (format nil "~a ~a" k l))))

(defun dash-nav (nav key)
  "One key applied to the dashboard: the new nav, or NIL for `not mine`.

**The contract, and it is serenedash's own:**
  · `esc` at depth 0 returns NIL — the caller's signal to LEAVE the view;
  · `esc` at depth 1 closes what is open and stays.

A nav that answered at depth 0 would make the pane inescapable; one that returned NIL at depth
1 would make an open row impossible to close. Both are asserted, because both are silent."
  (let* ((n (copy-list (or nav nil)))
         (panels (dash-panels)))
    (setf (getf n :sel) (or (getf n :sel) 0)
          (getf n :scroll) (or (getf n :scroll) 0))
    (let ((k (if (characterp key) (string key) key))
          (count (max 1 (length panels))))
      (cond
        ((and (stringp k) (string= k "q")) nil)
        ((and (stringp k) (member k '("j" "down") :test #'string=))
         (setf (getf n :sel) (min (1- count) (1+ (getf n :sel)))) n)
        ((and (stringp k) (member k '("k" "up") :test #'string=))
         (setf (getf n :sel) (max 0 (1- (getf n :sel)))) n)
        ((and (stringp k) (string= k "J"))
         (setf (getf n :sel) (min (1- count) (+ 2 (getf n :sel)))) n)
        ((and (stringp k) (string= k "K"))
         (setf (getf n :sel) (max 0 (- (getf n :sel) 2))) n)
        ((and (stringp k) (member k '("g" "home") :test #'string=))
         (setf (getf n :sel) 0) n)
        ((and (stringp k) (member k '("G" "end") :test #'string=))
         (setf (getf n :sel) (1- count)) n)
        ((and (stringp k) (member k '("\r" "\n" "enter") :test #'string=))
         (setf (getf n :open) (not (getf n :open)) (getf n :scroll) 0) n)
        ((and (stringp k) (string= k "esc"))
         (if (getf n :open) (progn (setf (getf n :open) nil (getf n :scroll) 0) n) nil))
        (t n)))))

;;; ======================================================== 5. the renderer ;;;
;;;
;;; **THE ONE PLACE THE GRID IS APPLIED.** No panel draws its own columns; a panel returns
;;; rows and this turns them into segments. That is what keeps the ruler straight down the
;;; frame — serenedash's own words: *"Building rows ad hoc is why the storage and memory bars
;;; used to start at different offsets."*

(defun dash-style-for (kind)
  (case kind
    (:dim '(:dim t))
    (:good '(:fg :green))
    (:warn '(:bold t :fg :yellow))
    (:crit '(:fg :red))
    (:pending '(:fg :yellow))
    (t nil)))

(defun dash-bar-text (bar width)
  "BAR as glyphs. A number draws filled-over-empty; a LIST draws a segment per element, which
is how a share of a whole is shown (`cached` then `computed` then `free`). **A segmented bar is
the reason the fraction alone is not enough**: `61%` cannot say whether the rest is unstarted or
unreachable."
  (let ((w (max 1 width)))
    (cond
      ((null bar) (make-string w :initial-element #\space))
      ((listp bar)
       (let* ((parts (mapcar (lambda (f) (* w (max 0.0 (min 1.0 (float f))))) bar))
              (full (make-string (min w (round (reduce #'+ parts))) :initial-element #\█))
              (used (length full)))
         (concatenate 'string full (make-string (max 0 (- w used)) :initial-element #\░))))
      (t (let* ((f (max 0.0 (min 1.0 (float bar))))
                (k (min w (round (* f w)))))
           (concatenate 'string (make-string k :initial-element #\█)
                        (make-string (- w k) :initial-element #\░)))))))

(defun dash-line (row cols &optional (sel-p nil))
  "ROW as a segment list, on the shared grid, EXACTLY COLS wide.

The label is ellipsised rather than clipped — a label cut without a mark reads as the row's
actual name, which serenedash learned from `checkpoint_thres` — and the value is
right-aligned in its own column so digits line up down the panel.

**AND THE ROW IS PADDED TO COLS, which is what keeps the right border straight.** It was not, and
the operator saw it: *\"right borders are off\"*. MEASURED at 60 columns, one panel's rows came out
**85, 78, 70, 79 and 80** wide inside a box whose own borders are 59 — because the TAIL had no
bound at all, so `peak 114.4 tok/s  falling` simply ran past the edge and the `│` that
`dash-panel-lines` appends landed wherever the text happened to stop.

So the tail gets what is left after the fixed columns and is ELLIPSISED like every other column,
and a filler segment makes up any shortfall — including the one a truncated VALUE leaves, which is
the case a fixed arithmetic would get wrong."
  (let* ((label (or (getf row :label) ""))
         (value (or (getf row :value) ""))
         (style (dash-style-for (getf row :kind)))
         (bar (getf row :bar))
         (sparkname (getf row :spark))
         ;; **THE COLUMNS ARE ALLOCATED FROM COLS, NOT FIXED.** A fixed label of 24 and value of
         ;; 11 is 49 columns before the bar and the separators — more than a narrow panel has, so
         ;; at 40 columns the row came out **53 wide in a box drawn 40**. The bar takes a third,
         ;; the label and the value take what is left in that order, and each is capped at its
         ;; designed width so a wide terminal is unchanged.
         (room (max 0 (- cols 6)))
         (bar-cols (min +dash-col-bar+ (max 0 (floor room 3))))
         (label-cols (min +dash-col-label+ (max 1 (- room bar-cols 6))))
         (value-cols (min +dash-col-value+ (max 0 (- room bar-cols label-cols 2))))
         (glyph (cond ((and sparkname (dash-values sparkname))
                       (dash-spark (dash-values sparkname) :top (getf row :top) :width bar-cols))
                      ((or bar (listp bar)) (dash-bar-text bar bar-cols))
                      (t (make-string bar-cols :initial-element #\space))))
         (lab (if (<= (length label) label-cols)
                  (format nil "~va" label-cols label)
                  (format nil "~a…" (subseq label 0 (max 1 (1- label-cols))))))
         (val (if (<= (string-width value) value-cols)
                  (format nil "~va" value-cols value)
                  (truncate-to-width value value-cols)))
         (before-tail (+ 2 label-cols value-cols 2 bar-cols 2))
         (tail (truncate-to-width (or (getf row :tail) "") (max 0 (- cols before-tail))))
         (used (+ before-tail (string-width tail)))
         (pad (make-string (max 0 (- cols used)) :initial-element #\space)))
    (list (cons (if sel-p "▸ " "  ") (and sel-p '(:bold t)))
          (cons lab '(:dim t))
          (cons val style)
          (cons "  " nil)
          (cons glyph (cond ((getf row :bar) '(:fg :cyan)) (sparkname '(:dim t)) (t nil)))
          (cons "  " nil)
          (cons tail '(:dim t))
          ;; **THE FILLER IS A SEGMENT AND NOT TRAILING SPACES ON THE TAIL**, so it survives a
          ;; caller that trims, and so the padding is visible as one thing rather than as an
          ;; accident of a format string.
          (cons pad nil))))

(defun dash-panel-lines (panel cols &key sel-p (open-p nil) now)
  "One panel as lines: a box, its header with the freshness chip, its rows, and its close.

**The freshness chip is in the HEADER and not in the rows**, because it is a fact about the
panel rather than about any row in it, and a chip repeated on every line is a column of noise
that hides the one line it belongs to."
  (let* ((title (getf panel :title))
         (needs (getf panel :needs))
         (fresh (and needs (dash-oldest-freshness needs now)))
         (chip (second fresh))
         (chip-kind (first fresh))
         (inner (max 20 (- cols 4)))
         ;; **WHICH FILE IT CAME FROM** (R56). A panel this head was told about by a file and one it
         ;; ships must not look alike — the operator asked for the dashboards directory to be
         ;; VISIBLE, and the header is where a reader is already looking to find out what the box is.
         ;; A separate key rather than text folded into `:title`, because `:title` is the file's own
         ;; data and a panel reporting a title it was never given is a small lie in the one place a
         ;; reader trusts absolutely.
         (fnote (let ((n (getf panel :file-note)))
                  (when (and n (stringp n))
                    (truncate-to-width (format nil "  ~a" n) (max 0 (- cols 24))))))
         (head (format nil "┌─~a " title))
         (chip-text (format nil " ~a ─┐" (or chip "")))
         (fill (make-string (max 1 (- cols (string-width head) (string-width chip-text)))
                            :initial-element #\─))
         (rows (ignore-errors (funcall (getf panel :rows) cols))))
    (append
     (list (list (cons (concatenate 'string head (or fnote "")
                                    ;; the filler gives back exactly what the note took, so the
                                    ;; box edge lands on the last column as it always did
                                    (subseq fill 0 (max 1 (- (length fill)
                                                             (if fnote (length fnote) 0)))))
                  '(:fg :cyan))
                 (cons chip-text (case chip-kind
                                   (:live '(:fg :green))
                                   (:stale '(:bold t :fg :yellow))
                                   (:no-data '(:dim t))
                                   (t '(:dim t))))))
     ;; A panel whose rows function failed says so rather than drawing an empty box: an empty
     ;; panel and a broken one must not look alike, for the same reason a stale series must not
     ;; look like a zero.
     (if (null rows)
         (list (list (cons "│ " '(:fg :cyan))
                     (cons (format nil "~va" (- cols 3) "(the panel returned nothing)")
                           '(:dim t))
                     (cons "│" '(:fg :cyan))))
         (mapcar (lambda (row)
                   (let ((segs (dash-line row (- cols 4) (and sel-p (getf row :sel)))))
                     (append (list (cons "│ " '(:fg :cyan))) segs (list (cons " │" '(:fg :cyan))))))
                 rows))
     (list (list (cons (concatenate 'string "└" (make-string (max 1 (- cols 2)) :initial-element #\─)
                                    "┘")
                       '(:fg :cyan)))))))

(defun dash-frame-lines (cols &key nav now)
  "The whole dashboard, as lines, and **the LINE each panel starts on**.

Two values, and the second is `todos-lines`' own arrangement: a pane that owns a cursor must be able
to say WHICH ROW A LINE BELONGS TO, or a click cannot be turned into a selection. The alternative —
recomputing the layout from the panel list at click time — is a second layout arithmetic, and this
tree has already paid for that once (`todos-stops`' docstring: *\"two enumerations is the defect\"*).

**Every panel is listed, always.** The operator: *\"dashboard with list all dashboard\"* — so this is
a LIST you walk, not a stack you scroll: `↑↓` moves the cursor, `enter` opens the one under it, and a
click lands on the panel you aimed at.

**The key bar is GENERATED from the binding table**, so it cannot advertise a key that does
nothing, and it is always the last line — which is how the reader learns the pane is interactive at
all. serenedash's own correction: a bar that listed `q` and `x` to a browser that could do neither
was found by reading, not by looking."
  (let* ((panels (dash-panels))
         (sel (or (getf nav :sel) 0))
         (open (getf nav :open))
         (lines '())
         (starts (make-array 0 :adjustable t :fill-pointer 0)))
    ;; a heading, because a list of boxes with no line above them does not say what it is
    (push (list (cons (format nil "~d dashboard~:p registered~@[ · ~d attached to a job~]"
                              (length panels) (dash-job-panels))
                      '(:bold t)))
          lines)
    (push nil lines)
    ;; **AND WHAT THE FILES SAID** (R56): how many panels came from disk, and one `!` line per file
    ;; that could not be read. It sits between the heading and the panels because it is about the
    ;; list rather than about any panel in it — and a broken file must be visible from the pane,
    ;; since `/dash-reload`'s status note is gone by the time a reader looks.
    (dolist (l (dash-file-notes)) (push l lines))
    ;; **AND THE WATCHERS AND SINKS** (R56) — a watcher is a thing that runs, so the pane is where a
    ;; reader finds out whether it is running, what it is bound to, and whether its last push landed.
    ;; A sink that is quietly failing is the case this exists for: a dashboard missing a counter
    ;; reads as a job that has not moved.
    (dolist (l (nreverse (append (dash-watcher-notes) (dash-sink-notes)))) (push l lines))
    (dolist (p panels)
      (vector-push-extend (length lines) starts)
      (let ((i (position p panels)))
        (dolist (l (dash-panel-lines p cols :sel-p (eql i sel) :now now))
          (push l lines))))
    (push (list (cons (dash-bindings) '(:dim t))) lines)
    ;; **THE STARTS ARE STASHED, NOT RETURNED, and the reason is a crash on the operator's
    ;; screen.** This function's second value was the line each panel starts on, and the frame's
    ;; full-body arm is
    ;;
    ;;     (multiple-value-setq (lines sel-line) (case (head-mode head) …))
    ;;
    ;; so that vector was bound to `sel-line` and handed to `scroll-pane-into-view`:
    ;; **`#(2 9) is not of type REAL`, and the render died while the suite was green.**
    ;;
    ;; `*hist-bounds*` is this tree's own precedent for the fix — *set by `%viewport-lines` and
    ;; read by the anchor* — and it is right here for a second reason: the click asks for the map
    ;; at a moment when the pane was drawn by THIS function, so a stash written by the draw cannot
    ;; disagree with the screen. A second function computing the layout would be a second layout,
    ;; which `todos-stops` calls *\"the defect\"*.
    (setf *dash-line-map* (copy-seq starts))
    (nreverse lines)))

(defun dash-panel-at-line (line starts)
  "Which panel a click on LINE lands on, or NIL.

**The question is `line >= start`, taking the LAST panel that satisfies it** — a panel's box is its
own line plus everything until the next one begins, so walking backwards is what makes a click land
on the box it is inside rather than on the one after it."
  (when (and starts (plusp (length starts)) line)
    (loop for i from (1- (length starts)) downto 0
          when (>= line (aref starts i)) return i)))

;;; ======================================================= 6. the collector ;;;

(defun dash-http-get (host port path &key (timeout 4))
  "A GET over a stream socket, HTTP/1.0 so the server closes the reply and the read ends.

**No HTTP library, for the house reason** — letibot writes its own HTTP and its own termios, and
what this needs is one request and one body. A general client brings redirects, chunked transfer
and TLS, and the only part of that this could not do without is TLS, which a `/metrics` on
loopback does not need. NIL on any failure: the caller records nothing rather than a zero."
  (handler-case
      (let ((sock (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
        (unwind-protect
             (progn
               (sb-bsd-sockets:socket-connect sock (sb-bsd-sockets:make-inet-address host) port)
               (let ((s (sb-bsd-sockets:socket-make-stream
                         sock :input t :output t :element-type 'character
                         :external-format :utf-8 :buffering :full)))
                 (format s "GET ~a HTTP/1.0~c~cHost: ~a:~d~c~cConnection: close~c~c~c~c"
                         path #\Return #\Linefeed host port #\Return #\Linefeed
                         #\Return #\Linefeed #\Return #\Linefeed)
                 (finish-output s)
                 (let* ((text (with-output-to-string (o)
                                (loop with deadline = (+ (get-internal-real-time)
                                                         (* timeout internal-time-units-per-second))
                                      while (< (get-internal-real-time) deadline)
                                      for line = (read-line s nil :eof)
                                      until (eq line :eof)
                                      do (write-string line o) (terpri o))))
                        (at (search (format nil "~c~c~c~c" #\Return #\Linefeed #\Return #\Linefeed)
                                    text)))
                   (when at (subseq text (+ at 4))))))
          (ignore-errors (sb-bsd-sockets:socket-close sock))))
    (error () nil)))

(defun dash-parse-metrics (text)
  "TEXT as an alist of metric-name → number, dropping the `# HELP`/`# TYPE` lines and any
label suffixes. Prometheus text format's shape, and the only part of it this needs."
  (when text
    (loop for line in (uiop:split-string text :separator '(#\Newline))
          for trimmed = (string-trim '(#\space #\tab #\Return) line)
          unless (or (zerop (length trimmed)) (char= (char trimmed 0) #\#))
            append (let* ((sp (position #\space trimmed))
                          (key (subseq trimmed 0 sp))
                          (brace (position #\{ key))
                          (bare (if brace (subseq key 0 brace) key))
                          (val (ignore-errors (read-from-string (subseq trimmed sp)))))
                     (when (and val (numberp val) (plusp (length bare)))
                       (list (cons bare val)))))))

(defun dash-proc-read (name)
  (ignore-errors (uiop:read-file-string (format nil "/proc/~a" name))))

(defun dash->bytes (kb)
  "KB as a float count of bytes. `/proc` reports kilobytes, and every size in the panels is
bytes until a formatter says otherwise — mixing the two units is how a memory row reads 190T."
  (* 1024.0 (float kb 1.0)))

(defun dash-meminfo ()
  "/proc/meminfo as an alist of keyword → kilobytes.

**Line-wise, not by searching the blob.** The first version searched for the key and took
everything up to the next space — which for `MemTotal:` is the run of spaces that follows it,
so every memory number came back NIL. A `/proc` file has one fact per line and parsing it any
other way is guessing at its whitespace."
  (let ((text (dash-proc-read "meminfo")))
    (when text
      (loop for line in (uiop:split-string text :separator '(#\Newline))
            for colon = (position #\: line)
            when colon
              append (let* ((key (subseq line 0 colon))
                            (rest (string-trim '(#\space #\tab)
                                               (subseq line (1+ colon))))
                            (num (ignore-errors
                                  (parse-integer rest :junk-allowed t))))
                       (when num
                         (list (cons (intern (string-upcase key) :keyword) num))))))))

(defun dash-sample-system ()
  "The machine's own numbers, from /proc. Returns an alist of series → value.

**Every number here has a denominator, and the panel is where it is drawn.** Load against
cores, memory against total, swap against total — a load average with no core count is a
number nobody can act on."
  (let ((mem (dash-meminfo)))
    (flet ((kb (key) (cdr (assoc key mem))))
      (let* ((total (kb :memtotal))
             (avail (kb :memavailable))
             (stot (kb :swaptotal))
             (sfree (kb :swapfree)))
        (list (cons "sys.mem_used" (and total avail (dash->bytes (- total avail))))
              (cons "sys.mem_total" (and total (dash->bytes total)))
              (cons "sys.swap_used" (and stot sfree (dash->bytes (- stot sfree))))
              (cons "sys.swap_total" (and stot (dash->bytes stot)))
              ;; the load numbers are gauges the kernel already maintains, so they are read
              ;; once here and the panel's only work is the scale.
              (cons "sys.load1" (dash-loadavg 0))
              (cons "sys.load5" (dash-loadavg 1))
              (cons "sys.load15" (dash-loadavg 2)))))))

(defun dash-loadavg (n)
  "The Nth load average (0, 1, 2), or NIL."
  (let ((row (dash-proc-read "loadavg")))
    (when row
      (let ((parts (remove "" (uiop:split-string row :separator '(#\space)) :test #'string=)))
        (when (> (length parts) n)
          (ignore-errors (read-from-string (nth n parts))))))))

;;; **THE COLLECTOR'S STATE, and it has to be declared before the functions that set it.** These
;;; five were written but did not survive one of the paren repairs above — and the failure was
;;; silent until the head was asked to start: `(setf *dash-running* t)` on a `defvar` that had
;;; been DECLARED works, so the first symptom was `*DASH-THREAD* is unbound` two lines later.
;;; A whole section can be lost to a repair, which is why the suite now asks `dash-start` to run.

(defvar *dash-samplers* nil
  "`(name . function)` pairs. A function returns an alist of series → value; **NIL for a value
means *not measured*, which is recorded as nothing rather than as a zero.**")

(defvar *dash-thread* nil "The collector thread, or NIL when it is not running.")
(defvar *dash-running* nil "T while the collector should keep sampling.")
(defvar *dash-samples-taken* 0 "How many passes have completed. A counter, so a reader can tell a
started collector from a running one without asking the thread.")
(defvar *dash-last-error* nil "`(sampler . message)` for the most recent failing sampler, or NIL.
**Kept rather than printed**: a dashboard with a dead endpoint should draw that fact, and a log
nobody is reading is not a place for it.")

(defun dash-sampler-add (name fn)
  (setf *dash-samplers* (remove name *dash-samplers* :key #'car :test #'string=))
  (setf *dash-samplers* (append *dash-samplers* (list (cons name fn))))
  name)

(defun dash-parse-pairs (text)
  "TEXT as `(series . value)` pairs, from the two shapes every tool already speaks.

An ordinary line is either `key value` (`rows 1204`, `pending 3`) or `key=value`
(`rows=1204`, prometheus-ish text, an env dump). A line that is neither, and a blank or
`#`-prefixed line, records NOTHING — because this is parsing somebody else's output and a guess
about a shape nobody promised is how a series gets a number that means something else.

A METRIC NAME is left as it comes, dots and all: `pg_fuzz.findings` stays that, and the source's own
name is prefixed on by `dash-command-add` so two sources cannot collide."
  (loop for raw in (uiop:split-string (or text "") :separator '(#\Newline))
        for line = (string-trim '(#\space #\tab #\return) raw)
        unless (or (zerop (length line)) (char= (char line 0) #\#))
          append (let* ((eq (position #\= line))
                        (sp (position-if (lambda (c) (member c '(#\space #\tab) :test #'char=)) line)))
                   (multiple-value-bind (key tail)
                       (cond ((and eq (or (null sp) (< eq sp)))
                              (values (subseq line 0 eq) (subseq line (1+ eq))))
                             (sp (values (subseq line 0 sp) (subseq line (1+ sp))))
                             (t (values nil nil)))
                     (let ((value (and key (ignore-errors
                                            (read-from-string
                                             (string-trim '(#\space #\tab) (or tail "")))))))
                       (when (and key (plusp (length key)) (numberp value))
                         (list (cons key (float value)))))))))

(defun dash-command-add (name command &key (parse #'dash-parse-pairs) (timeout 10)
                                        (prefix t))
  "**A SOURCE THAT IS A COMMAND** — because the thing being watched is often not in this process, or
in this filesystem, at all.

MEASURED, and it is why this exists: the operator's long-running work runs in a different mount
namespace (`mnt:[4026533260]` against the head's `mnt:[4026531832]`), its state is on a path that
does not exist in the head's filesystem, and `nsenter` answers `Operation not permitted`. A source
that can only call a Lisp function or `with-open-file` cannot watch that — and the same shape covers
an HTTP endpoint (`curl`), a `docker exec`, an agent task's log, and the `watch`-like case: anything
whose answer a command can print.

COMMAND is run through `/bin/sh -c`, so a pipeline, a redirect and a `docker exec` all work.

**TIMEOUT IS NOT OPTIONAL, AND `uiop:run-program`'s `:timeout` DOES NOT DO IT.** Measured: with
`:timeout 1` against a `sleep 30`, the pass took **30 seconds** — the option was accepted and
ignored, so the collector thread was wedged for the whole of it while the head kept painting and
every other series silently stopped. That is the worst-shaped failure this file has, and it was
sitting in the argument list looking like protection.

So the cap is coreutils' own `timeout`, in front of the shell: `timeout N /bin/sh -c CMD`. It kills
the child, it is the same tool an operator would reach for at a prompt, and its absence is a
numbered exit rather than a hang. A command that overran records nothing rather than a partial
parse.

A non-zero exit is NOT an error here: the output is still parsed, because `pg_fstat; exit 1` is a
program with something to say.

PREFIX puts the source's own name in front of every series it produces (`fuzz.findings`), so two
command sources cannot collide — and `:prefix nil` is for a command whose keys are already unique."
  (dash-sampler-add name
                    (lambda ()
                      (let* ((text (uiop:run-program (list "timeout" (princ-to-string timeout)
                                                          "/bin/sh" "-c" command)
                                                     :output :string :error-output :output
                                                     :ignore-error-status t))
                             (pairs (funcall parse text)))
                        (if prefix
                            (loop for (k . v) in pairs
                                  collect (cons (format nil "~a.~a" name k) v))
                            pairs)))))

(defun dash-collect-once ()
  "One pass over every sampler. Returns the number of values recorded.

**A failing sampler is recorded and does not stop the pass** — one dead endpoint must not take
the other panels' history with it, and the failure is kept where the dashboard can draw it
rather than printed into a log nobody is reading."
  (let ((n 0))
    (dolist (s *dash-samplers*)
      (handler-case
          (dolist (pair (funcall (cdr s)))
            (when (dash-note (car pair) (cdr pair)) (incf n)))
        (error (e) (setf *dash-last-error* (cons (car s) (format nil "~a" e))))))
    (incf *dash-samples-taken*)
    ;; **AND THEN THE SINKS, once per pass** — a source pointed the other way, so it runs at the same
    ;; cadence and under the same discipline. `fboundp` because `src/dashwatch.lisp` loads AFTER this
    ;; file (it is a reader of this vocabulary and belongs after it), and a forward reference that is
    ;; called from the collector thread is a call that will always find its definition — this is the
    ;; one place that ordering is visible, so it is stated rather than left to inference.
    (when (and (fboundp 'dash-sinks-run) (plusp (hash-table-count *dash-sinks*)))
      (ignore-errors (dash-sinks-run)))
    n))

(defun dash-start (&optional (interval nil))
  "Start the collector. Idempotent: calling it twice does not make two threads."
  (when interval (setf *dash-interval* interval))
  (setf *dash-running* t)
  (unless (and *dash-thread* (sb-thread:thread-alive-p *dash-thread*))
    (setf *dash-thread*
          (sb-thread:make-thread
           (lambda ()
             (loop while *dash-running*
                   do (ignore-errors (dash-collect-once))
                      ;; sleep in small steps so `dash-stop` is felt promptly rather than after
                      ;; a whole interval — a stop that takes five seconds reads as a hang.
                      (loop repeat (* 10 *dash-interval*) while *dash-running* do (sleep 0.1))))
           :name "leticl-dash-collector")))
  *dash-interval*)

(defun dash-stop ()
  (setf *dash-running* nil)
  (when (and *dash-thread* (sb-thread:thread-alive-p *dash-thread*))
    (ignore-errors (sb-thread:join-thread *dash-thread* :timeout 2)))
  (setf *dash-thread* nil)
  (values))

;;; ============================================================== 7. the feed ;;;
;;;
;;; **A JOB'S ENDING IS AN EVENT; ITS PROGRESS IS A POLL.** Verified rather than assumed, and the
;;; whole shape follows from it: `SessionEvent::JobOutput` has exactly ONE publish site — inside the
;;; daemon's `CommandKind::ReadJobOutput` arm — nothing in the daemon issues that frame on its own,
;;; and the exec host publishes nothing at capture time. `JobSettled`, by contrast, arrives
;;; unprompted from the watcher thread. So the poll covers progress and the event covers the
;;; ending, and together the polling window is EXACTLY the job's lifetime.
;;;
;;; **And the asking happens in the MAIN LOOP.** A sampler runs on `leticl-dash-collector`, and
;;; `%send` from that thread would write a frame from a thread that does not own the socket — the
;;; same class as handing a frame to Lisp from a foreign thread (the host must drive). So the feed
;;; is a tick beside `tick-notice` and `tick-op-calls`, and the reply is folded by the event arm
;;; that already folds a window for the pane.

(defvar *dash-fed* (make-hash-table :test #'equal)
  "JOB id → `(:next N :from N :state STRING :never-ran BOOL :at MS :asked BOOL)`.

**`:next` is the daemon's own incremental handle**, taken from the reply and handed back — never
recomputed here, because the page size is the daemon's (`JOB_OUTPUT_WINDOW`) and a head that
arithmetic'd `from + window` would be a second copy of a number only the daemon knows.

**`:asked` is what makes the feed STOP.** A job that is no longer running and has been asked about
once is not asked again, which is what bounds the cost by the job's life rather than by the head's.

A `defvar`, for the house reason: a live push must not throw away the offsets this head has taken.")

(defvar *dash-fed-at* 0 "When this head last asked for a window, on `internal-real-time-ms`.")

(defvar *dash-jobs-asked-at* 0
  "When this head last asked for the JOB LIST, on `internal-real-time-ms`.

Separate from the window clock because the two questions have different urgencies: a window is asked
for every interval, and the job LIST only while a panel is still unmatched — which is the state a
dashboard registered before its job started is in.")

(defun dash-feed-panels ()
  "The registered panels that name a job — the feed's work list."
  (remove-if-not (lambda (p) (getf p :job)) (dash-panels)))

(defun dash-feed-due-p (head &optional (now (internal-real-time-ms)))
  "Is it time to ask? **The same interval as the samplers**, so a job series and a system series have
ONE resolution: two cadences would draw two time axes on a panel that shows both, which is the same
defect as two sparklines on different ceilings."
  (declare (ignore head))
  (and (dash-feed-panels)
       (>= (- now *dash-fed-at*) (* 1000 *dash-interval*))))

(defun tick-dash-feeds (head)
  "Ask for the window of every registered job panel. Runs ON THE MAIN LOOP — see the section note.

**The job LIST is asked for while a panel is unmatched, and that is the second ask.** `head-jobs`
is filled by `/jobs` and by `JobSettled`, so a dashboard registered before its job started has
nothing to match against; this asks `list_jobs` until it does, which stops as soon as it does."
  (when (dash-feed-due-p head)
    (setf *dash-fed-at* (internal-real-time-ms))
    (let* ((panels (dash-feed-panels))
           (unmatched (remove-if (lambda (p) (dash-job-for-panel head p)) panels)))
      ;; one ask, and only while something is still waiting for its job to exist
      (when (and unmatched
                 (>= (- (internal-real-time-ms) *dash-jobs-asked-at*)
                     (* 1000 *dash-interval*)))
        (setf *dash-jobs-asked-at* (internal-real-time-ms))
        (%send head (make-list-jobs)))
      (dolist (p panels)
        (let ((entry (dash-job-for-panel head p)))
          (when entry
            (let* ((id (getf entry :id))
                   (fed (gethash id *dash-fed*)))
              ;; **A SETTLED JOB IS NOT ASKED ABOUT AGAIN** — the event told us, and polling a
              ;; finished job for ever is exactly the cost this design exists to avoid.
              (unless (and (getf fed :asked) (not (getf entry :running)))
                (%send head (make-read-job-output id 0))
                (setf (gethash id *dash-fed*)
                      (list :next (getf fed :next) :from (getf fed :from)
                            :state (getf fed :state) :never-ran (getf fed :never-ran)
                            :at (getf fed :at) :asked t)))))))))
  t)

