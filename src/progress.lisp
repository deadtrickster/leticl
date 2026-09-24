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

;;; ------------------------------------------------------- the daemon's clock ;;;
;;;
;;; **A DEADLINE FROM THE DAEMON IS A WALL-CLOCK INSTANT AND THIS HEAD'S CLOCK IS
;;; NOT.** `DecisionRequested.deadline` and `SecretRequested.deadline` are *"Unix
;;; millis"* (event.rs:573, :746) and `internal-real-time-ms` is SBCL's
;;; `get-internal-real-time` — a counter since this process started. Subtracting one
;;; from the other is a duration measured across two clocks, silently wrong by an
;;; enormous constant, which is R13's trap in a second place and the one the SECRET
;;; card had been living with: its countdown read the difference between a Unix
;;; instant and a monotonic counter.
;;;
;;; The two clocks differ by a CONSTANT, so it is measured once and reused, and a
;;; wire deadline is converted to this head's clock **when the frame arrives** —
;;; R13's own answer (*anchor on arrival*), which is the only place the two readings
;;; can be subtracted while they describe the same moment. What remains is a
;;; duration in one clock, and every countdown from then on is two readings of
;;; `internal-real-time-ms`.
;;;
;;; The residual error is the delivery latency of one frame plus any real
;;; disagreement between this box's wall clock and the daemon's — which is the honest
;;; best available: the daemon said *when*, and `when` is a wall-clock fact.

(defvar *unix-offset-ms* nil
  "`(- unix-ms monotonic-ms)` — the constant between this box's wall clock and
SBCL's internal counter, measured on first use and then reused.

A `defvar` and not a head slot: it is a property of the PROCESS, not of a head, and
a struct change is a restart. Bound to 0 by `with-replay-globals` (see there).")

(defun unix-now-ms ()
  "The wall clock in Unix milliseconds, from the process's own readings.

Sub-millisecond accurate and monotonic in practice: `get-universal-time` is a
one-second counter, so it is used ONCE to establish the offset and every later
reading is the internal counter plus that constant."
  (let ((offset (or *unix-offset-ms*
                    (setf *unix-offset-ms*
                          (- (* 1000 (- (get-universal-time) 2208988800))
                             (internal-real-time-ms))))))
    (+ (internal-real-time-ms) offset)))

(defun wire-deadline->monotonic (deadline)
  "DEADLINE as the daemon sent it (Unix milliseconds), on THIS head's clock.

**Called where the frame is folded, never where it is drawn.** A card that converted
at render time would be subtracting a Unix instant from a monotonic one on every
frame — which is what the secret card did — and a card that converts at arrival
holds a duration that is already in one clock.

NIL in, NIL out: §11.5's *\"wait forever\"* is `deadline: null`, and an ask that
cannot expire is not an ask whose deadline is zero. **A zero or negative value counts
as no deadline too**, because epoch 0 is not an instant any daemon means and a card
counting down from 1970 would be a rendering fault rather than a fact — this is the
guard the secret card already had (`(plusp deadline)`), kept rather than moved."
  (when (and (numberp deadline) (plusp deadline))
    (+ (internal-real-time-ms) (- deadline (unix-now-ms)))))

(defun wire-stamp->started-ms (began)
  "BEGAN, as the daemon sent it (Unix ms), as a value `*turn-started-ms*` can hold — or NIL.

**The whole turn's start, not the round's.** `TurnStarted` fires once per ROUND (the engine's
`run_turn_steered` is called inside the daemon's round loop), so a head that simply took
`internal-real-time-ms` at the event restarted its clock every round: the operator watched the
composer read `2.1s` a minute into a turn and reported it — *\"it should be still responding even
while you do tools calls and such, and not reset, currently it resets.\"*

So the emitter stamps the turn's real start and this converts it once, at the fold, into the
monotonic base the duration is subtracted from — the same one-conversion rule
`wire-deadline->monotonic` keeps, and for the same reason: two clocks in one subtraction is a
number that is wrong by their offset.

**NIL for a value nobody measured**, which is §11.5's *wait forever* read the other way: a
non-positive stamp is not an instant any daemon means, so the head keeps its own NIL and the row
says *started before this head attached* rather than inventing a start."
  (when (and (numberp began) (plusp began))
    (+ (internal-real-time-ms) (- began (unix-now-ms)))))

(defun deadline-remaining-ms (deadline)
  "Milliseconds left before DEADLINE, or NIL when there is none. NEGATIVE once past.

Negative rather than clamped, because *\"past its deadline\"* and *\"no time left\"* are
different facts and the caller has a different sentence for each.

A non-positive DEADLINE is NIL here for the same reason `wire-deadline->monotonic`
converts one to NIL: epoch 0 is not an instant anybody meant."
  (when (and (numberp deadline) (plusp deadline))
    (- deadline (internal-real-time-ms))))

(defparameter +deadline-coarse-ms+ 120000
  "Above this much time left, the countdown is in WHOLE MINUTES.

The operator's question, answered: *\"a countdown that ticks for five minutes is
furniture and one that ticks for ten seconds is a pressure the operator did not ask
for\"*. Both are avoided by a ladder rather than by a number — coarse while it is not
urgent (and a minute-granular figure also gives the loop a reason to repaint once a
minute instead of ten times a second), exact once it is. Two minutes is where a
decision stops being something to think about later and starts being something to
answer now, and it is the number the coarse arm is measured against: at the daemon's
own `ANSWER_BUDGET` (300 s, `harnessd/src/answers.rs:66`) the card reads `5 min` for
its first three minutes and counts in seconds for the last two.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defun %countdown-duration (ms)
  "MS as a countdown reads it: whole seconds under a minute, `duration` above.

`47s`, not `47.0s` — the spelling the secret card used and the one the reference's own
countdown prints — while a long one keeps `3m07s`. One function, so the *time left*
clause and the *past its deadline* clause cannot disagree about how a duration is
written; two spellings of one rule is the defect that always follows."
  (if (< ms 60000) (format nil "~ds" (floor ms 1000)) (duration ms)))

(defun %coarse-duration (ms)
  "MS rounded UP to whole minutes: `5 min`, `2 min`, `1 min`.

**Up, not nearest.** The sentence is *expires in …*, and a rounded-down figure claims
less time than there is — an operator who decides on the strength of it would be
deciding about a deadline that is not the one the daemon set. Ties go up for the same
reason, and the value never decreases as the clock runs."
  (format nil "~d min" (max 1 (ceiling (max 0 ms) 60000))))

(defun deadline-said (deadline)
  "The time clause for a card with DEADLINE, or NIL when there is no deadline.

Three states, and the third is the one the operator hit on 2026-09-21 — two cards
went by with `not_run by gate:timeout` and *nothing on the card had said that was
coming*:

  · **time left, and plenty** — `expires in 5 min`. No ticking: the value is the
    fact, and the fact does not change this second;
  · **time left, and not plenty** — `1m58s left`, then `47s left` under a minute. The
    last two minutes are counted in seconds because that is where the number is acted
    on, and the last of them in WHOLE seconds (`47s`, not `47.0s`), which is the
    spelling the secret card already used and the one the reference's own countdown
    prints;
  · **past it** — `past its deadline by 12s; the daemon has not said what became of it`.
    A card still on the screen after its own deadline is a card whose answer has
    already been settled daemon-side, and the head has not been told which way. Saying
    so is the difference between a clock the operator can see and one that ran out
    quietly; what it must NOT do is keep counting into negative seconds, which is a
    number that means nothing and reads as a rendering fault.

**NIL, not a sentence, when there is no deadline.** §11.5's `deadline: null` is
*\"wait forever\"* — a policy, not missing information — so an ask that cannot expire
says nothing about time, and *\"I was not told\"* cannot be manufactured by a card that
never had a clock to show. This is the §13.2b question (present-and-zero) answered in
the other direction, and deliberately: `unreadable 0` is a counter that must be shown
because a head that does not count is a different head, while a countdown on an ask
with no deadline is a number nobody took."
  (let ((left (deadline-remaining-ms deadline)))
    ;; NIL from `deadline-remaining-ms` is *no deadline* — an absent one, or a
    ;; non-positive one nobody meant — and it is the same silence either way
    (when left
      (cond
        ((minusp left)
         ;; a SEMICOLON and not an em-dash: the card joins its clauses with ` · `, so
         ;; a second dash level here would read as two different kinds of break
         (format nil "past its deadline by ~a; the daemon has not said what became of it"
                 (%countdown-duration (- left))))
        ((>= left +deadline-coarse-ms+)
         (format nil "expires in ~a" (%coarse-duration left)))
        (t (format nil "~a left" (%countdown-duration left)))))))

(defparameter +on-timeout-said+
  '(("deny" . "if nobody answers, nothing runs")
    ("allow" . "if nobody answers, it RUNS anyway")
    ("ask" . "if nobody answers, the guard model decides"))
  "What SILENCE does, in the daemon's own three words (`SessionEvent`'s `OnTimeout`,
`deny | allow | ask`, event.rs:250-257).

**Said on every card that has a deadline, because it is the fact that does not
change.** The countdown tells an operator when to hurry; this tells them what happens
if they do not, and the two are not the same question — `deny` costs one refused call,
`allow` runs it UNATTENDED, and an operator who walked away believing the default was
`deny` when it was `allow` has been told nothing by a clock. Upper case on that one
word: it is the only outcome here that does something the person did not ask for.

A code this head does not know renders no clause, rather than guessing at one —
a wrong consequence is worse than an absent one, and the daemon's vocabulary is the
only place this can be learned.")

(defun on-timeout-said (on-timeout)
  "What silence does, from the wire's own word: `\"deny\"`, `\"allow\"`, `\"ask\"`, or
NIL for a word this head does not know (see the table)."
  (cdr (assoc (string-downcase (or on-timeout "")) +on-timeout-said+ :test #'string=)))

;;; ------------------------------------------------------------ input helpers ;;;

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
            finally (return (truncate-to-width head cols))))))

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
    (truncate-to-width s (max 1 (or cols 1)))))
