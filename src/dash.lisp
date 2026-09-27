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

(defvar *dash-series* (make-hash-table :test #'equal)
  "series name → a struct. A `defvar`, for the house reason: a live push must not throw away
the running head's collected history.")

(defvar *dash-interval* 5 "Seconds between samples.")

(defun dash-series-new (name &optional (unit ""))
  (setf (gethash name *dash-series*)
        (list :name name :unit unit :v (make-array +dash-hist+ :adjustable t :fill-pointer 0)
              :at 0)))

(defun dash-note (name value &key (unit "") (now *now-ms*))
  "Record one sample of NAME. Returns VALUE, or NIL when nothing was recorded.

**A NIL VALUE IS NOT RECORDED, and that is the point.** The sampler has already decided the
number does not exist; a zero substituted here would be THIS FUNCTION inventing a fact about
the world. A series that stops being fed goes STALE — which `dash-freshness` says out loud —
rather than dropping to the floor and looking idle."
  (when (and value (numberp value))
    (let ((s (or (gethash name *dash-series*) (dash-series-new name unit))))
      (setf (getf s :unit) unit (getf s :at) (or now *now-ms*))
      (let ((v (getf s :v)))
        (when (>= (length v) +dash-hist+)
          ;; Drop the oldest eighth rather than shifting on every tick: a full array shift at
          ;; every sample is the one operation in this file that would show up in a profile.
          (let ((keep (- +dash-hist+ (floor +dash-hist+ 8))))
            (replace v (subseq v (floor +dash-hist+ 8)))
            (setf (fill-pointer v) keep)))
        (vector-push-extend (float value) v)))
    value))

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

(defvar *dash-panels* (make-hash-table :test #'equal))
(defvar *dash-order* nil "Registration order, as names.")

(defun dash-register (name &key title rows (order 50) needs)
  "Register or replace a panel. Returns NAME.

    (dash-register \"llama\" :title \"llama\" :needs '(\"llama.gen\")
      :rows (lambda (cols) (list (list :label \"gen rate\" :value … :bar …))))

**That call at a live REPL is the whole API**, and it is what makes a dashboard a thing the
operator composes rather than a thing a programmer ships. Replacing an existing NAME keeps its
place in the order, so re-registering a panel while watching it does not move it."
  (setf (gethash name *dash-panels*)
        (list :name name :title (or title name) :rows rows :order order :needs needs))
  (unless (member name *dash-order* :test #'string=) (push name *dash-order*))
  (setf *dash-order*
        (stable-sort *dash-order* #'<
                     :key (lambda (n) (or (getf (gethash n *dash-panels*) :order) 50))))
  name)

(defun dash-unregister (name)
  (remhash name *dash-panels*)
  (setf *dash-order* (remove name *dash-order* :test #'string=))
  (values))

(defun dash-panels () (remove nil (mapcar (lambda (n) (gethash n *dash-panels*)) *dash-order*)))

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
  "ROW as a segment list, on the shared grid.

The label is ellipsised rather than clipped — a label cut without a mark reads as the row's
actual name, which serenedash learned from `checkpoint_thres` — and the value is
right-aligned in its own column so digits line up down the panel."
  (let* ((label (or (getf row :label) ""))
         (value (or (getf row :value) ""))
         (style (dash-style-for (getf row :kind)))
         (bar (getf row :bar))
         (sparkname (getf row :spark))
         (bar-cols (min +dash-col-bar+ (max 8 (- cols +dash-col-label+ +dash-col-value+ 6))))
         (glyph (cond ((and sparkname (dash-values sparkname))
                       (dash-spark (dash-values sparkname) :top (getf row :top) :width bar-cols))
                      ((or bar (listp bar)) (dash-bar-text bar bar-cols))
                      (t (make-string bar-cols :initial-element #\space))))
         (lab (if (<= (length label) +dash-col-label+)
                  (format nil "~va" +dash-col-label+ label)
                  (format nil "~a…" (subseq label 0 (1- +dash-col-label+)))))
         (val (if (<= (string-width value) +dash-col-value+)
                  (format nil "~va" +dash-col-value+ value)
                  (truncate-to-width value +dash-col-value+))))
    (list (cons (if sel-p "▸ " "  ") (and sel-p '(:bold t)))
          (cons lab '(:dim t))
          (cons val style)
          (cons "  " nil)
          (cons glyph (cond ((getf row :bar) '(:fg :cyan)) (sparkname '(:dim t)) (t nil)))
          (cons "  " nil)
          (cons (or (getf row :tail) "") '(:dim t)))))

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
         (head (format nil "┌─~a " title))
         (chip-text (format nil " ~a ─┐" (or chip "")))
         (fill (make-string (max 1 (- cols (string-width head) (string-width chip-text) 1))
                            :initial-element #\─))
         (rows (ignore-errors (funcall (getf panel :rows) cols))))
    (append
     (list (list (cons (concatenate 'string head fill) '(:fg :cyan))
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
  "The whole dashboard, as lines. NAV is the plist `dash-nav` maintains.

**The key bar is GENERATED from the binding table**, so it cannot advertise a key that does
nothing, and it is always the last line — which is how the reader learns the pane is
interactive at all. serenedash's own correction: a bar that listed `q` and `x` to a browser
that could do neither was found by reading, not by looking."
  (let ((panels (dash-panels))
        (sel (or (getf nav :sel) 0))
        (open (getf nav :open)))
    (append
     (loop for p in panels
           for i from 0
           append (dash-panel-lines p cols :sel-p (= i sel) :open-p (and (= i sel) open) :now now))
     (list (list (cons (dash-bindings) '(:dim t)))))))

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

;;; ====================================================== 8. the llama panel ;;;
;;;
;;; **THE DASHBOARD THE OPERATOR ASKED FOR**, and the shape is the argument: the collector feeds
;;; series, the panels read them, and every number is drawn beside its denominator. Nothing here
;;; is compiled into the head's core — `dash-llama-dashboard` is a function you call, and every
;;; piece of it can be replaced at a live REPL.

(defparameter +dash-llama-host+ "127.0.0.1")
(defparameter +dash-llama-port+ 8080)

(defun dash-llama-dashboard (&key (start t))
  "**THE ONE CALL A HEAD MAKES**: register the panels, register the samplers, and start
collecting. Returns the interval.

Two samplers and not one, because they fail independently — llama-server can be down while the
machine is fine, and a single sampler would take the system panel's history with it every time
the server restarts. That is the same reason `dash-collect-once` records a failing sampler instead
of propagating."
  (dash-llama-panels)
  (dash-sampler-add "llama" #'dash-sample-llama)
  (dash-sampler-add "system" #'dash-sample-system)
  (when start (dash-start))
  *dash-interval*)

(defparameter +dash-cores+ 32
  "Cores, for the load row's denominator.

**A constant rather than a probe, and that is the design.** A load average with no scale is a
number nobody can act on — 20.09 is alarming on 4 cores and idle on 64 — so the denominator has
to be sayable, and a `defparameter` lets a panel be TESTED without asking the machine. The
default is this box's; a head on another machine sets it once."
  )

(defun dash-sample-llama ()
  "llama-server's own `/metrics`, plus `/slots` for what is in flight.

The metric names are the server's and the derivations are stated, because two of them are
COUNTERS and a counter drawn as a gauge is a line that only ever climbs:
  · `predicted_tokens_seconds` and `prompt_tokens_seconds` are already rates, so they are read
    directly — note they are per-slot averages, not `Δtokens/Δt`;
  · the spec-decode accept RATE is `accepted / drafts` from the cumulative counters, which is
    the number that says whether the draft model is earning its keep."
  (let* ((text (dash-http-get +dash-llama-host+ +dash-llama-port+ "/metrics"))
         (m (dash-parse-metrics text)))
    (flet ((g (name) (cdr (assoc name m :test #'string=))))
      ;; **THE DENOMINATOR IS DRAFT TOKENS, NOT DRAFT STEPS**, and reading the wrong one gives a
      ;; rate ABOVE 100%: measured on the live server, `num_drafts_total` is 1.98M *"verification
      ;; steps"* while `num_draft_tokens_total` is 3.95M tokens generated, and 3.53M were
      ;; accepted. Against steps that is 178%; against tokens it is 89%, which is the number the
      ;; panel is actually about. One draft yields several tokens, so the two counters are not
      ;; the same kind of thing and the names do not say so.
      (let ((drafts (g "llamacpp:spec_decode_num_draft_tokens_total"))
            (accepted (g "llamacpp:spec_decode_num_accepted_tokens_total"))
            (prompt (g "llamacpp:prompt_tokens_total"))
            (cached (g "llamacpp:prompt_tokens_cached_total"))
            (pred (g "llamacpp:tokens_predicted_total")))
        (list (cons "llama.gen_rate" (g "llamacpp:predicted_tokens_seconds"))
              (cons "llama.prompt_rate" (g "llamacpp:prompt_tokens_seconds"))
              (cons "llama.processing" (g "llamacpp:requests_processing"))
              (cons "llama.deferred" (g "llamacpp:requests_deferred"))
              (cons "llama.slots_busy" (g "llamacpp:n_busy_slots_per_decode"))
              (cons "llama.decode_total" (g "llamacpp:n_decode_total"))
              (cons "llama.ctx_max" (g "llamacpp:n_tokens_max"))
              (cons "llama.accept_ratio"
                    (and drafts accepted (plusp drafts) (min 1.0 (/ accepted drafts))))
              (cons "llama.cache_ratio" (and prompt cached (plusp prompt) (/ cached prompt)))
              (cons "llama.predicted_total" pred)
              ;; **A COUNTER IS NOT A GAUGE.** `/slots` reports what is in flight NOW — the
              ;; prompt a request is working through — which is the only live progress there
              ;; is; the totals above only ever climb and cannot answer "is it moving".
              (cons "llama.slot_prompt_pts"
                    (let ((slots (ignore-errors
                                  (json-decode (or (dash-http-get +dash-llama-host+
                                                                 +dash-llama-port+ "/slots")
                                                   "[]")))))
                      (when (listp slots)
                        (let ((busy (remove-if-not (lambda (s) (getf s :is-processing)) slots)))
                          (when busy
                            (let ((s (first busy)))
                              (getf s :n-prompt-tokens-processed))))))))))))

(defun dash-llama-panels ()
  "Register the llama + system dashboard. Call it, or call it at a REPL to change one panel.

Each panel's `:needs` names the series its freshness chip should reflect — **a panel is only as
live as its stalest input**, which is why the chip is computed from the set rather than from
whichever series happened to be sampled last."
  (dash-register "llama" :title "llama-server" :order 10
                 :needs '("llama.gen_rate" "llama.processing")
                 :rows
                 (lambda (cols)
                   (declare (ignore cols))
                   (let* ((gen (dash-last "llama.gen_rate"))
                          (pp (dash-last "llama.prompt_rate"))
                          (peak (let ((v (dash-values "llama.gen_rate")))
                                  (and v (plusp (length v)) (reduce #'max v))))
                          (dec (dash-values "llama.gen_rate"))
                          (proc (dash-last "llama.processing"))
                          (defer (dash-last "llama.deferred"))
                          (acc (dash-last "llama.accept_ratio"))
                          (cache (dash-last "llama.cache_ratio")))
                     (list
                      (list :label "generation"
                            :value (or (dash-rate gen) "—")
                            :bar (and gen peak (plusp peak) (/ gen peak))
                            :tail (format nil "peak ~a  ~a"
                                          (or (dash-rate peak) "?")
                                          (or (dash-direction dec 20) "no trend")))
                      (list :label "prompt"
                            :value (or (dash-rate pp) "—")
                            :kind :dim
                            :tail "tokens/s, per slot")
                      (list :label "requests"
                            :value (if proc (format nil "~d" (round proc)) "—")
                            :kind (if (and proc (plusp proc)) :pending :dim)
                            :tail (format nil "processing~@[ · ~d deferred~]" (and defer (plusp defer) (round defer))))
                      (list :label "spec accept"
                            :value (or (dash-pct acc 0) "—")
                            :bar acc
                            :kind (cond ((null acc) :dim) ((> acc 0.8) :good) ((< acc 0.4) :warn) (t :plain))
                            :tail "accepted of drafted")
                      (list :label "prefix cache"
                            :value (or (dash-pct cache 0) "—")
                            :bar cache
                            :kind :good
                            :tail "prompt tokens reused")))))
  (dash-register "system" :title "this machine" :order 20
                 :needs '("sys.load1" "sys.mem_used")
                 :rows
                 (lambda (cols)
                   (declare (ignore cols))
                   (let* ((l1 (dash-last "sys.load1"))
                          (used (dash-last "sys.mem_used"))
                          (total (dash-last "sys.mem_total"))
                          (swap (dash-last "sys.swap_used"))
                          (stot (dash-last "sys.swap_total"))
                          (mem-frac (and used total (plusp total) (/ used total)))
                          (swap-frac (and swap stot (plusp stot) (/ swap stot))))
                     (list
                      ;; **LOAD IS A NUMBER WITH NO SCALE UNTIL IT HAS ONE.** A bare 20.09 is
                      ;; alarming on four cores and idle on sixty-four, and the reader cannot
                      ;; tell which — so the denominator is in the tail, always.
                      (list :label "load 1m"
                            :value (if l1 (format nil "~,1f" l1) "—")
                            :bar (and l1 (plusp +dash-cores+) (/ l1 +dash-cores+))
                            :kind (cond ((null l1) :dim)
                                        ((> l1 (* 1.2 +dash-cores+)) :crit)
                                        ((> l1 +dash-cores+) :warn)
                                        (t :good))
                            ;; **THE SEPARATOR IS PART OF THE WORD, not of the format.** A
                            ;; row that ends `of 32 cores · ` carries punctuation for a
                            ;; sentence that is not there — and it is there for the first three
                            ;; samples of every session, which is when the pane is first read.
                            :tail (let ((dir (dash-direction (dash-values "sys.load1") 20)))
                                    (if dir
                                        (format nil "of ~d cores · ~a" +dash-cores+ dir)
                                        (format nil "of ~d cores" +dash-cores+))))
                      (list :label "memory"
                            :value (or (dash-bytes used) "—")
                            :bar mem-frac
                            :kind (cond ((null mem-frac) :dim)
                                        ((> mem-frac 0.9) :crit)
                                        ((> mem-frac 0.75) :warn)
                                        (t :plain))
                            :tail (format nil "of ~a · ~a"
                                          (or (dash-bytes total) "?")
                                          (or (dash-pct mem-frac 0) "")))
                      ;; **SWAP IS THE ONE NUMBER HERE THAT IS ALMOST ALWAYS BAD**, so its
                      ;; threshold is a fraction of a gigabyte rather than a percentage:
                      ;; anything swapped at all on a model box is memory pressure, and waiting
                      ;; for 100% to say so is waiting until the machine is already thrashing.
                      (list :label "swap"
                            :value (or (dash-bytes swap) "—")
                            :bar swap-frac
                            :kind (cond ((null swap) :dim)
                                        ((> swap (* 512 1024 1024)) :crit)
                                        ((plusp swap) :warn)
                                        (t :good))
                            :tail (format nil "of ~a" (or (dash-bytes stot) "?")))))))
  (dash-bind "g" "main" "dash")
  (dash-bind "j/k" "move" "move")
  (dash-bind "esc" "leave" "leave")
  (values))

