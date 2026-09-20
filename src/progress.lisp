;;;; progress.lisp — the numbers a turn produces, said in a way a person reads.
;;;;
;;;; Ported from crates/ui/src/progress.rs. The point of the module is that a
;;;; prefill and a decode are the same wait to the person doing the waiting, so
;;;; they are said in the same words: `thousands` for a count, `duration` for a
;;;; time, and one bar that carries the cache split.
;;;;
;;;; Three deliberate refusals, all from the reference and all worth keeping:
;;;;
;;;;  · `thousands` is NOT a digit separator. A status line has no room for one,
;;;;    and `40.1k` reads faster than `40,132` when the digits past the first
;;;;    three are noise.
;;;;  · The rate is measured over COMPUTED tokens, never over `processed`:
;;;;    dividing the cache hit by the wall clock is not a speed, it is an
;;;;    artefact in the hundreds of thousands.
;;;;  · A number nobody measured is absent, not zero. No rate before there is
;;;;    enough elapsed time to divide by — `0.0 tok/s` would be a claim.
;;;;
;;;; `prompt_progress` arrives as a plist on the turn (`:total :cache
;;;; :processed :time-ms`), so these take it as one: wire-shaped state stays a
;;;; plist (PLAN.md D4).

(in-package #:leticl)

;;; ------------------------------------------------------------ scalars ;;;

(defun thousands (n)
  "`1234567` becomes `1.23M`, `12345` becomes `12.3k`. Not a separator."
  (let ((n (or n 0)))
    (cond ((<= n 9999) (format nil "~d" n))
          ((<= n 999999) (format nil "~,1fk" (/ n 1000.0)))
          (t (format nil "~,2fM" (/ n 1000000.0))))))

(defun duration (ms)
  "A duration a person reads at a glance: `840ms`, `2.5s`, `3m07s`, `1h05m`."
  (let ((ms (or ms 0)))
    (cond ((< ms 1000) (format nil "~dms" ms))
          ((< ms 60000) (format nil "~,1fs" (/ ms 1000.0)))
          ((< ms 3600000)
           (multiple-value-bind (m s) (floor (floor ms 1000) 60)
             (format nil "~dm~2,'0ds" m s)))
          (t (multiple-value-bind (h m) (floor (floor (floor ms 1000) 60) 60)
               (format nil "~dh~2,'0dm" h m))))))

(defun spinner (elapsed-ms)
  "A frame chosen from ELAPSED TIME, not from a frame counter.

Neither is evidence the turn is progressing — a counter proves the render loop
is alive and a clock proves the clock is alive — so the caller is expected to
stop calling this when the turn stops, rather than to read the frame as proof
of anything."
  (let ((frames "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"))
    (char frames (mod (floor (or elapsed-ms 0) 80) (length frames)))))

(defvar *fixed-clock-ms* nil
  "When non-NIL, what `internal-real-time-ms` answers, for everything.

There for `--replay --no-tty`, whose whole contract is *same file in, same bytes
out*. Two places read this clock while FOLDING a recorded log — the turn's start
time (`session.lisp`, on `turn_started`) and a call's start and end
(`note-call-started`) — and both end up on the screen as a duration, so a replay
on the real clock answers `· 0ms` on one run and `· 1ms` on the next and every
comparison against the reference is one row noisier than it should be. Measured:
that is the only nondeterminism a fold has; the rest of a frame is a function of
the file.

NIL everywhere else, so a running head, a paced tty replay and the tests that
measure real elapsed time are untouched. Bound, never assigned: a clock frozen by
a `setf` that an error skipped past would be a head whose spinner never turns.")

(defun internal-real-time-ms ()
  "The monotonic clock in milliseconds, or `*fixed-clock-ms*` when one is bound.

`get-universal-time` is one-second resolution, which is fine for a filesystem
timestamp and wrong for anything a person watches — a five-second window measured
in whole seconds is a four-to-five-second window. This is the clock the ESC
decoder and the stall line both need."
  (or *fixed-clock-ms*
      (round (* 1000 (/ (get-internal-real-time) internal-time-units-per-second)))))

;;; ----------------------------------------------------------- prefill ;;;

;; A "Prefill" is the plist the daemon sends; these are the four questions the
;; display asks of it. Values are clamped to TOTAL because a cache can be
;; reported larger than the prompt it cached (a stale row, a resumed session),
;; and a bar drawn past its own end is a lie about progress.

(defun prefill-fraction (p)
  "How much of the prompt is resident, 0.0 to 1.0."
  (let ((total (or (getf p :total) 0)))
    (if (zerop total)
        0.0
        (/ (float (min (or (getf p :processed) 0) total)) total))))

(defun prefill-cached-fraction (p)
  "How much of the prompt cost nothing — the headline number for this project:
`f_keep` observed live rather than reconstructed after the turn."
  (let ((total (or (getf p :total) 0)))
    (if (zerop total)
        0.0
        (/ (float (min (or (getf p :cache) 0) total)) total))))

(defun prefill-computed (p)
  "Tokens actually computed this turn."
  (max 0 (- (or (getf p :processed) 0) (or (getf p :cache) 0))))

(defun prefill-rate (p)
  "Prefill throughput in tokens/second, or NIL before there is enough to divide.

Measured over `prefill-computed`, not over `processed`: the cache hit divided by
the wall clock produces a number in the hundreds of thousands and it is not a
speed, it is an artefact. And a rate needs more than a moment of elapsed time —
under 50ms the divisor is noise."
  (let ((ms (or (getf p :time-ms) 0))
        (computed (prefill-computed p)))
    (when (and (>= ms 50) (plusp computed))
      (/ (* (float computed) 1000.0) ms))))

(defun prefill-eta-ms (p)
  "Estimated milliseconds to the end of the prefill, or NIL with no rate yet.

Assumes the remaining tokens all have to be computed, which they do —
everything past `processed` is by definition not in the cache."
  (let ((rate (prefill-rate p)))
    (when rate
      (let ((left (max 0 (- (or (getf p :total) 0) (or (getf p :processed) 0)))))
        (if (zerop left)
            0
            (round (/ (* (float left) 1000.0) rate)))))))

;;; --------------------------------------------------------------- bar ;;;

(defparameter +eighths+ #("" "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█")
  "Eighth-of-a-cell fill, empty to full; index is the number of eighths.

From the reference, and worth having: a 20-column bar over a 40,000-token
prompt advances one cell per 2,000 tokens, so at whole-cell resolution a bar
that is genuinely moving looks frozen for seconds at a time — the exact
impression a progress display exists to prevent.")

(defun progress-bar (p cols)
  "A three-segment bar `cols` columns wide.

    ▐████████▓▓▓▓▍░░░░░▌
     ^cached  ^computed ^remaining

The cached run is drawn differently from the computed run on purpose. A
two-colour bar answers \"how far along\"; this also answers \"how much of this did
the prefix cache save me\", which is the question the whole prompt pipeline is
optimising for. The three runs are three different GLYPHS as well as three
colours, so the information survives a terminal with none."
  (let* ((cols (max 4 (or cols 0)))
         (inner (max 0 (- cols 2)))
         (total (or (getf p :total) 0)))
    (if (or (zerop total) (zerop inner))
        (format nil "▐~a▌" (make-string inner :initial-element #\░))
        (let* ((frac (lambda (n) (/ (float (min (or n 0) total)) total)))
               (done-e (min (round (* (funcall frac (getf p :processed)) inner 8))
                            (* inner 8)))
               ;; the cache boundary in whole cells, never past the moving edge
               (cached (min (floor (* (funcall frac (getf p :cache)) inner))
                            (floor done-e 8)))
               (full (- (floor done-e 8) cached))
               (rem (mod done-e 8))
               (partial (if (plusp rem) 1 0))
               (rest (- inner cached full partial)))
          (concatenate 'string
                       "▐"
                       (make-string cached :initial-element #\█)
                       (make-string (max 0 full) :initial-element #\▓)
                       (if (= partial 1) (aref +eighths+ rem) "")
                       (make-string (max 0 rest) :initial-element #\░)
                       "▌")))))

;;; -------------------------------------------------------------- lines ;;;

(defun %truncate-width (s cols)
  "S to at most COLS display columns. Counts cells, not characters."
  (if (<= (string-width s) cols)
      s
      (let ((out (make-string-output-stream))
            (w 0))
        (loop for ch across s
              for cw = (char-width ch)
              while (<= (+ w cw) cols)
              do (write-char ch out) (incf w cw))
        (get-output-stream-string out))))

(defun prefill-line (p cols)
  "The whole prefill line: `prefill 61% ▐████▓▓░░░▌ · 2.4k tok/s · ~12s left`.

The raw counts (`25.1k/41.2k tok · 92% cached`) are deliberately NOT here: the
header carries `ctx` and `cached%` live for the whole turn, and the same number
in two places is read once and doubted once. What the header cannot show — how
fast the expansion runs and how long is left — is what this keeps.

Degrades by dropping the LEAST useful field first as the terminal narrows: the
estimate, then the rate, then the bar — leaving `prefill 61%`, which is still
true. It never wraps: a status line that wraps scrolls the transcript by a row
every frame, and that reads as flicker."
  (let* ((cols (max 1 (or cols 1)))
         (pct (round (* (prefill-fraction p) 100)))
         (head (format nil "prefill ~d%" pct))
         (rate (awhen (prefill-rate p)
                 (format nil "~a tok/s" (thousands (round it)))))
         (eta (when (and (prefill-eta-ms p)
                         (< (or (getf p :processed) 0) (or (getf p :total) 0)))
                (format nil "~~~a left" (duration (prefill-eta-ms p)))))
         (barw (min 20 (floor cols 3)))
         (bar (progress-bar p barw)))
    (flet ((join (parts)
             (let ((s (format nil "~{~a~^ · ~}" (remove nil parts))))
               (string-right-trim " ·" (substitute #\space #\Nul s)))))
      (loop for candidate in (list (join (list head bar rate eta))
                                   (join (list head bar rate))
                                   (join (list head bar))
                                   head)
            when (<= (string-width candidate) cols)
              return candidate
            finally (return (%truncate-width head cols))))))

(defun decode-line (predicted elapsed-ms cols)
  "The decode phase: how fast tokens are coming out.

Kept beside the prefill because the two phases are one wait to the person doing
the waiting, and a head that shows a bar and then nothing has just told them the
work stopped."
  (let* ((rate (if (and elapsed-ms (plusp elapsed-ms))
                   (/ (* (float (or predicted 0)) 1000.0) elapsed-ms)
                   0.0))
         (s (format nil "generating ~a tok · ~,1f tok/s · ~a"
                    (thousands predicted) rate (duration elapsed-ms))))
    (%truncate-width s (max 1 (or cols 1)))))
