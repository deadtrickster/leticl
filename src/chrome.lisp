;;;; chrome.lisp — the frame furniture: the top border, the status line, the
;;;; boxed composer, the hint bar, and the alarm.
;;;;
;;;; This is the strip the operator looks at while typing. It draws no
;;;; transcript and reads only `head` state, so it can be restyled without
;;;; touching a single row renderer.
;;;;
;;;; Ported from the reference's `screen()` chrome (`app.rs:4011-4102`, `4284`,
;;;; `4318`): the composer is a BOX with a title, whose bottom edge carries the
;;;; wiring; below it an ALARM line that exists only when something is wrong; and
;;;; below that a HINT bar. On a short screen the box degrades to a bare `›` line
;;;; rather than eating a row it does not have.

(in-package #:leticl)

(defvar *esc-at* nil
  "When the last bare ESC arrived, for the double-tap interrupt.

About the KEY STREAM, not the session, so not a head slot. Defined here, before
`editor.lisp`, because the hint bar reads it: a special referenced before its
defvar is a full compile-time WARNING.")
(defparameter *esc-double-ms* 5000
  "How long a second `esc` still counts as the same gesture. The reference's
number: a double tap is one intent, and five seconds is the width of a hesitation
rather than a second thought.")

(defvar *resyncs* 0
  "How many Resync frames this head has taken. A counter the reference keeps on
its status line and shows on /status; a non-zero value means this head lost its
place at least once, which the operator should be able to see without asking.")

(defvar *notice-ttl* 0
  "Frames left on the status note. See `tick-notice`.")

;;; --------------------------------------------------------------- model ;;;
(defun %model-from-settings ()
  "The live `model` setting, when the head has asked for the rows (§7.4).

Reads the GLOBAL head, so it must only be called from a context where `*head*`
is bound — which the paint is, and which a test of the render is not. Callers
that may be outside the head pass nil for the rows; see `%model-name`."
  (let ((settings (and *head* (head-settings *head*))))
    (and settings
         (let ((row (find "model" settings
                          :key (lambda (r) (getf r :key)) :test #'string=)))
           (and row (let ((v (getf row :value)))
                      (and (stringp v) (plusp (length v)) v)))))))

(defun %model-name (s)
  "The model this session is ACTUALLY on: whichever the head was told MORE
RECENTLY, by seq — the reference's rule since letibot `03cb812`.

`ServerFrame::Settings` has exactly one send site and it is the ANSWER to a
request, so an attached head reads the `model` row once, at attach, and is never
told again: a provider switch updated the daemon, the turns and the config pane —
which asks again when opened — and left every attached head drawing what it read
at attach. `TurnStarted` is the exception: it arrives unprompted and names the
model answering that turn. So the two are ranked by the only clock a head has,
and the wiring's model from `Hello` is the fallback when neither has spoken.

Measured on the operator's screen: the `/config` row said `deepseek/deepseek-flash`
while the header said `qwen-3.8-27b`."
  (let* ((row (%model-from-settings))
         (turn-model (let ((m (getf (session-turn s) :model)))
                       (and (stringp m) (plusp (length m)) m)))
         (turn-newer (> *model-from-turn-at* *model-from-settings-at*)))
    (cond ((and row (not turn-newer)) row)
          ((and row (null turn-model)) row)
          (row turn-model)
          (turn-model turn-model)
          (t (let ((wire (getf (session-wiring s) :model)))
               (if (stringp wire) wire ""))))))

;;; -------------------------------------------------------------- counters ;;;
;;;
;;; The head's own instrumentation. Every counter here was added because
;;; something was measured going wrong, and each one lives on the status line
;;; only when it is NOT ZERO — a number that is zero costs a row of attention
;;; for ever in exchange for being noticed once. The alarm line below carries
;;; the rest.

(defun alarm-counts (head)
  "The counters that are not zero, as an alist of (LABEL . VALUE).

A defvar each rather than a head slot, because a struct layout change is a
restart; there is one head per process, so a global costs nothing and pushes."
  (remove-if (lambda (pair) (zerop (cdr pair)))
             (list (cons "dropped" (or (session-dropped (head-session head)) 0))
                   ;; **`scrubbed` counts too.** The reference's `alarmed()` is
                   ;; `dropped + scrubbed + resyncs > 0` (app.rs:7619-7620) and
                   ;; this list carried the first and the third: a head that had
                   ;; had secrets stripped out of its rows and nothing else wrong
                   ;; showed no ⚠ at all, so the one counter whose whole point is
                   ;; that the operator learns about it was the one kept quiet.
                   (cons "scrubbed" *scrubbed-total*)
                   (cons "resync" *resyncs*))))

(defun alarmed-p (head)
  "Is anything wrong enough to spend a row on?

`alarm-counts` now carries `scrubbed`, which is the reference's third term. The
`(not connected)` clause is ours and stays: the reference exits on a dead socket
(`driver.rs:102-108`) and this head reconnects, so \"detached\" is a state it can
be in and the reference cannot."
  (or (alarm-counts head)
      (not (head-connected head))))

;;; ---------------------------------------------------------------- money ;;;
;;;
;;; `Usage.cost_micros_usd` is `Option<u64>` on the wire and this head used to
;;; ignore it entirely. Three rules, each a version of a rule this repo already
;;; holds elsewhere:
;;;
;;;  · an absent cost adds NOTHING and lights nothing — free and unpriced are both
;;;    "no number", and `$0.0000` on every local header is noise;
;;;  · a flag separates "free, so nothing to show" from "metered and nothing has
;;;    finished yet";
;;;  · the total belongs to the CONVERSATION, not the head, so a session switch
;;;    clears it — carrying one session's bill onto another's header is wrong in
;;;    the direction that costs money.

(defvar *spent-micros* 0
  "Micro-USD this head has WATCHED finish this conversation. A head that attached
late shows only what it saw, which is the honest answer rather than a total that
is quietly too low. A defvar, not a head slot: a struct layout change is a
restart.")
(defvar *spent-seen* nil
  "T when any turn this head saw carried a cost at all.")

(defun note-turn-cost (usage)
  "Fold one turn's `usage` into the money meter. T when it changed anything."
  (let ((micros (and usage (getf usage :cost-micros-usd))))
    (when (numberp micros)
      (setf (ldb (byte 64 0) *spent-micros*) (+ *spent-micros* micros)
            *spent-seen* t)
      t)))

(defun reset-spent ()
  "A new conversation has its own bill."
  (setf *spent-micros* 0
        *spent-seen* nil))

(defun spent-text ()
  "`$0.0421`, or NIL when no turn this head saw carried a cost."
  (when *spent-seen*
    (format nil "$~,4f" (/ *spent-micros* 1000000.0))))

;;; ---------------------------------------------------------------- border ;;;

(defun %workspace (s)
  "The session root with `$HOME` written as `~`.

Twelve columns of an eighty-column header spent on `/home/dead` is twelve
columns not spent on the session's name."
  (let ((ws (getf (session-wiring s) :workspace))
        (home (uiop:getenv "HOME")))
    (cond ((null ws) nil)
          ((and home (>= (length ws) (length home))
                (string= (subseq ws 0 (length home)) home))
           (concatenate 'string "~" (subseq ws (length home))))
          (t ws))))

(defun %session-position (s)
  "`1/71` — which of the daemon's sessions this is, of how many. The reference's
rule, from `header_line`: shown for one session too, because \"1/1\" is a fact —
this daemon holds one session and you are in it — where two absences are not.
Subagents are children of a session, not sessions a picker lists, so they are not
counted; the picker filters them the same way."
  (let* ((all (picker-sessions s))
         (at (position (session-session-id s) all
                       :key (lambda (b) (getf b :session-id)) :test #'equal)))
    (format nil "~d/~d" (if at (1+ at) 0) (max 1 (length all)))))

(defun %ellipsise-left (path room)
  "PATH shortened from its LEFT to ROOM columns: the end of a path is the part
that identifies it, and `~/Projects/…` names nothing."
  (if (<= (string-width path) room)
      path
      (let ((keep (max 1 (- room 1))))
        (concatenate 'string "…" (subseq path (max 0 (- (length path) keep)))))))

(defun %usage-numbers (s)
  "The four telemetry numbers the header shows, each present only when measured:
context size, cache fraction, decode rate, elapsed — plus output tokens.

A number nobody measured is ABSENT, not zero: `0% cached` is the same defect as a
rate nobody took, and it is the rule the meter and the footer are both held to.

**The LIVE PREFILL WINS while a turn runs.** `header_line` (app.rs:6274-6281)
reads `turn.progress.total/cache` first and falls back to the kept usage only
when there is no prefill in flight, because *how big is this prompt* is a
question about the prompt being sent — not about the last one that finished.
Ours read `state.usage` or `turn.usage` and had no `progress` path at all, so
through the whole of a long turn the header showed the PREVIOUS turn's context
while the bar on the composer's edge was expanding a different one. Measured
against `src/session.lisp:218-223`, which already folds `PromptProgress` onto the
turn as `(:total :cache :processed :time-ms)` and had no reader."
  (let* ((turn (session-turn s))
         (state (and turn (getf turn :state)))
         (usage (or (and state (getf state :usage))
                    ;; a finished turn's usage is kept past the end of the turn,
                    ;; so the header still says what the conversation costs while
                    ;; nothing is running — which is most of the time
                    (and turn (getf turn :usage))))
         (pp (getf turn :progress))
         ;; `(TOTAL CACHED CACHE-MEASURED)`, the reference's own triple: a live
         ;; prefill always measured its own cache, a kept usage did so only if it
         ;; carried the number.
         (live (and pp (numberp (getf pp :total)) (plusp (getf pp :total))
                    (list (getf pp :total) (or (getf pp :cache) 0) t)))
         (kept (and usage (numberp (getf usage :prompt-tokens))
                    (plusp (getf usage :prompt-tokens))
                    (list (getf usage :prompt-tokens)
                          (or (getf usage :cached-tokens) 0)
                          (numberp (getf usage :cached-tokens)))))
         (ctx (or live kept))
         (timings (and state (getf state :timings)))
         (parts nil))
    (when ctx
      (push (format nil "~a ctx" (thousands (first ctx))) parts))
    (when (and ctx (third ctx))
      (push (format nil "~d% cached"
                    (round (* 100 (/ (float (second ctx)) (first ctx)))))
            parts))
    (when (and timings (numberp (getf timings :predicted-ms))
               (plusp (getf timings :predicted-ms))
               (numberp (getf usage :predicted-tokens))
               (plusp (getf usage :predicted-tokens)))
      (push (format nil "~d tok/s"
                    (round (/ (* (float (getf usage :predicted-tokens)) 1000.0)
                              (getf timings :predicted-ms))))
            parts))
    (when (and timings (numberp (getf timings :wall-ms)) (plusp (getf timings :wall-ms)))
      (push (duration (getf timings :wall-ms)) parts))
    (when (and usage (numberp (getf usage :predicted-tokens))
               (plusp (getf usage :predicted-tokens)))
      (push (format nil "~a out" (thousands (getf usage :predicted-tokens))) parts))
    (nreverse parts)))

(defun top-border (head cols)
  "The header: what this session IS on the left, what it is COSTING on the right.

    ▌ the cache question  ~/Projects/letibot   2/4 · glm-5.3-flash · 41.2k ctx · 92% cached · 45 tok/s · 12.3s · 1.2k out

The shape is letibot's `header_line`, and so are the three registers, read off its
raw escapes rather than its plain text: the bar is `Role::UserAccent` (blue), the
title `Strong`, the workspace `Faint`, and the whole tail `Faint`. Ours painted the
left half bold from the bar to the path, which is one register where the reference
has three — and it is the row the eye crosses on every return to the field.

**It degrades by deletion, one field at a time**, from the tail's END: the path is
shortened from its left before anything is dropped — a path is recognisable from
its end, and a token count is not recoverable from anywhere else on the screen."
  (let* ((s (head-session head))
         (name (if (plusp (length (session-title s)))
                   (session-title s) (session-session-id s)))
         (model (%model-name s))
         (right (remove nil
                        (append (list (%session-position s))
                                (list (and (plusp (length model)) model))
                                (list (spent-text))
                                (%usage-numbers s))))
         (name-cols (+ 2 (string-width name))))
    ;; drop from the end until it leaves room for the name
    (loop while (and (> (length right) 1)
                     (> (+ name-cols (string-width (format nil "~{~a~^ · ~}" right)) 2) cols))
          do (setf right (butlast right)))
    (let* ((tail (format nil "~{~a~^ · ~}" right))
           (tail-cols (if (plusp (length tail)) (+ 2 (string-width tail)) 0))
           (left (list (cons "▌ " '(:fg :blue))
                       (cons name '(:bold t))))
           (left-cols name-cols)
           (ws (%workspace s)))
      ;; the workspace fills whatever is left, shortened from its LEFT
      (when ws
        (let ((room (- cols left-cols tail-cols 2)))
          (when (>= room 8)
            (let ((shown (%ellipsise-left ws room)))
              (setf left (append left (list (cons (format nil "  ~a" shown) '(:dim t)))))
              (incf left-cols (+ 2 (string-width shown)))))))
      (let ((pad (max 0 (- cols left-cols (string-width tail)))))
        (append left
                (list (cons (make-string pad :initial-element #\space) nil)
                      (cons tail '(:dim t))))))))

;;; ----------------------------------------------------------- alarm line ;;;
;;;
;;; The counters that are not zero, in the attention role, and nothing else. The
;;; full list lives on the `/status` screen with a line under each saying what it
;;; means — reachable, which is the obligation, and not resident, which was never
;;; part of it.

(defun alarm-line (head cols)
  "The alarm row, or NIL when there is nothing to say.

NIL rather than an empty line: a row that is always present is a row that costs
the transcript a line to say nothing."
  (let ((counts (alarm-counts head)))
    (cond
      ((not (head-connected head))
       (list (cons " ⚠ detached — retrying" '(:fg :red :bold t))))
      (counts
       (list (cons (format nil " ⚠ ~{~a ~a~^ · ~}"
                           (loop for (k . v) in counts append (list k v)))
                   '(:fg :yellow))))
      (t nil))))

;;; ----------------------------------------------------------------- stall ;;;
;;;
;;; The head says when the DAEMON has gone quiet. `now_ms` and `last-event-at`
;;; are received-at, not the event's own `ts`: taking it from the event's clock
;;; would measure the daemon's opinion of how long it had been quiet, which is
;;; exactly the number that is missing when it has stopped talking.

(defparameter *stall-ms* 15000
  "How long a silence before the head says so — the reference's own number
(`stuck_line`, app.rs:7594: `if quiet > 15_000`). Ours was 20 000, which is five
seconds of a dead turn nobody is told about; long enough that a slow model
thinking is not a stall, short enough that a dead socket is not a mystery.")

(defvar *now-ms* 0 "Wall clock, fed by the loop. 0 means nobody told us.")
(defvar *last-event-ms* nil "When the last frame arrived, or NIL before any.")

(defun note-frame-arrived ()
  (setf *last-event-ms* *now-ms*))

(defun stalled-ms ()
  "Milliseconds since the last frame, or NIL when there is nothing to say.

NIL when nobody has told this head what time it is (a test, a replay), because a
stall is a claim about the clock and a head without one must not guess.

The guard is written as two explicit checks rather than an `or` inside an `and`:
the first version was `(and *last-event-ms* (or (zerop *now-ms*) nil) …)`, and
`(or nil nil)` is NIL — so a head WITH a clock returned NIL forever and the stall
line never fired. A test caught it, which is the reason the test is a test."
  (when (and *last-event-ms* (plusp *now-ms*) (>= *now-ms* *last-event-ms*))
    (- *now-ms* *last-event-ms*)))

(defun stall-text (&optional head)
  "The stall sentence, or NIL — the reference's `stuck_line`.

Only while a TURN IS RUNNING, and it names the model, how long the silence has
been, and the key that ends it: a head between turns is quiet because nothing is
happening, and calling that a stall is an alarm about ordinary rest. Without the
head (a test of the clock alone) the old shorter form stands."
  (let ((ms (stalled-ms)))
    (when (and ms (>= ms *stall-ms*))
      (if (null head)
          (format nil " · no frames for ~a" (duration ms))
          (let ((turn (session-turn (head-session head))))
            (when (and turn (string= (turn-state-name turn) "running"))
              (format nil "~a — nothing received for ~a. The turn is still marked running; esc esc interrupts it."
                      (%model-name (head-session head)) (duration ms))))))))

(defun notice-line (head cols)
  "The head's own note, above the composer — `· resync: …`, `· bye: …`, `· mode →
allow-all`, every `say`.

**It had nowhere to go.** `status-line` carried it and `%render` drew that row
only on a screen too short for the composer's box (`(and … (not boxed))`, and
`boxed` is any screen of eight rows or more), so on every real terminal the note,
the stall and 21 other write sites of `head-status-note` went into silence —
including `detached — reconnecting…`. The reference puts the notice and the stall
in the chrome above the box, where the card is (app.rs:5069-5075)."
  (let ((note (head-status-note head)))
    (when (and note (plusp (length note)))
      (list (list (cons (%truncate-width (format nil "· ~a" note) cols)
                        '(:fg :magenta)))))))

(defun completions-line (head cols)
  "The live `/command` matches, one dim row above the composer — the reference's
`completions_line` (app.rs:4342-4358).

Tab has completed since the beginning (`src/editor.lisp:118`) and **nothing was
ever drawn**: `grep -rn completion src/*.lisp` found `%complete` and no renderer,
so the only way to learn what a prefix matched was to press Tab and watch the
buffer change under you. A bare `/` lists every verb; a prefix nothing matches
draws NOTHING rather than an empty row, because a row that appears and
disappears is noise, and Tab still says what went wrong when it is asked.

A list of 0 or 1 lines, like `notice-line` and `stall-row`, because the fit
ladder counts rows and this is **the first row it gives up** (app.rs:5111): it
is a typing aid, not a message."
  (let ((text (composer-buffer (head-composer head))))
    (when (and (plusp (length text))
               (char= (char text 0) #\/)
               (not (find-if (lambda (c) (member c '(#\space #\tab #\newline))) text)))
      (let* ((needle (subseq text 1))
             (parts (loop for (name . hint) in *slash-commands*
                          when (alexandria:starts-with-subseq needle name)
                            collect (format nil "/~a ~a" name hint))))
        (when parts
          (list (list (cons (%truncate-width
                             (format nil "  ~{~a~^  ·  ~}" parts) cols)
                            '(:dim t)))))))))

(defun stall-row (head cols)
  (let ((text (stall-text head)))
    (when text
      (list (list (cons (%truncate-width text cols) '(:fg :yellow)))))))

;;; --------------------------------------------------------------- status ;;;

(defun status-line (head cols)
  "The status row: the note, the connection, the scroll, the queue, the stall.

**Not on the frame\'s path any more.** `%render` used to draw this only when
there was no composer box — i.e. never on a real terminal — and now draws the
note and the stall as their own chrome rows (`notice-line`, `stall-row`) and the
unboxed fallback as `alarm-line`, which is what the reference pushes there
(app.rs:5199-5201). Kept because it is a named contract surface (HACKING.md) and
because `/status` and a restyle both still reach it; redefining it no longer
changes the frame, and `notice-line` is the function that does.

The counters moved to the ALARM line and to `/status`, which is the reference\'s
own change and the right one: `seq 907 · rendered 900 · filtered 1 · dropped 0` on
every frame next to the thing you are typing into is a row of attention spent for
ever on a number that is zero."
  (let* ((note (or (head-status-note head) ""))
         (scroll (if (plusp (head-scroll head))
                     (format nil " · ↑~a" (head-scroll head)) ""))
         (queued (if (head-queued head)
                     (format nil " · ~d queued" (length (head-queued head))) ""))
         (stall (or (stall-text) ""))
         (text (format nil " ~a~a~a~a" note scroll queued stall))
         (style (if (head-connected head) '(:dim t) '(:fg :red :bold t))))
    (list (cons (%truncate-width text (max 1 (or cols 1)))
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:dim t)))))

;;; --------------------------------------------------------------- hint bar ;;;

(defun hint-bar (head cols)
  "The line under the composer that says what the keys do HERE.

The reference's `hint_bar`, row for row: the composer's own hint first (`enter
send · ctrl+c exit`, or the interrupt/clear pair while a turn runs, or `esc again
to interrupt` while esc is armed), then ` · ` and the context's tail — a key that
closes a card is not the key that interrupts a turn, and a hint that names the
wrong key is worse than no hint at all. The quit card stands alone: its second
ctrl-c closes it, so the prefix's `ctrl+c exit` would be a lie there. Measured
against letibot's row 63 with the mode picker up: ours had dropped the prefix."
  (declare (ignore cols))
  (let* ((running (and (session-turn (head-session head))
                       (string= (turn-state-name (session-turn (head-session head))) "running")))
         (prefix (cond ((head-quit-open head) nil)
                       ((and *esc-at*
                             (< (- (get-internal-real-time) *esc-at*)
                                (* *esc-double-ms* (/ internal-time-units-per-second 1000.0))))
                        (cons "esc again to interrupt" '(:bold t :fg :yellow)))
                       (running (cons "esc interrupt · ctrl+c clear" '(:dim t)))
                       ((zerop (length (composer-buffer (head-composer head))))
                        (cons "enter send · ctrl+c exit" '(:dim t)))
                       (t (cons "enter send · alt+enter newline · ctrl+c clear" '(:dim t)))))
         (tail (cond
                 ((head-quit-open head) "1/2 or ↑↓ then enter · esc stays")
                 ((member (head-mode head) '(:help :status)) "esc closes this")
                 ((eq (head-mode head) :picker) "type a number to switch · /new [title] · esc closes")
                 (*pick-open* "a row number switches · ↑↓ then enter · or type a name · esc closes")
                 ((eq (head-mode head) :todos) "↑↓ moves · enter or tab unfolds · pgup/pgdn and the wheel scroll · esc closes")
                 ((eq (head-mode head) :config) "arrows move · enter changes a row marked ✎ · esc closes")
                 ((eq (head-mode head) :subagents) "subagents this session spawned · esc closes")
                 ((eq (head-mode head) :jobs) "background jobs this session started · ↑↓ then enter reads one · esc closes")
                 ((eq (head-mode head) :peek) "arrows scroll · enter re-reads · esc back")
                 ((head-secret-req head) "enter submits · esc refuses the password")
                 ((%open-decision head) "a row number answers · ↑↓ then enter · or type an option · /help")
                 (t "ctrl-s sessions · ctrl-p todos · ctrl-g subagents · ctrl-r thinking · ctrl-t tool output · ctrl-q jobs · tab completes /commands · /help"))))
    (if prefix
        (list prefix (cons (format nil " · ~a" tail) '(:dim t)))
        (list (cons tail '(:dim t))))))

(defun turn-status (head &optional (cols 40))
  "The running turn in a few words, or NIL when no turn is running — the
reference's `turn_status` (app.rs:7501-7566).

**Two orderings and a missing phase, all measured off `app.rs:7560-7566`.**

  · the SPINNER COMES FIRST — `{spin} Responding{since}{count}` — and ours had
    it last, after a ` · `, which puts the one moving glyph on the edge where a
    narrow border truncates it away first;
  · `since` comes before the count, not after;
  · and there was **no prefill arm at all**. While `turn.progress` says the
    prompt is still expanding, the reference replaces the whole status with
    `{spin} {prefill_line(pf, w-6)}` — the bar, the rate and the estimate. Ours
    had `prefill-line` (`src/progress.lisp:172`) written, tested and called from
    nowhere, so the one number this harness exists to move never reached the
    composer's edge. COLS is the border's width, which is why it is a parameter:
    the line is sized to the edge it is being pinned to."
  (let* ((turn (session-turn (head-session head)))
         (state (and turn (getf turn :state)))
         (running (and state (string= (getf (getf turn :state) :state) "running"))))
    (when running
      (let* ((pp (getf turn :progress))
             (spin (string (spinner *now-ms*))))
        (if (and pp (numberp (getf pp :total)) (plusp (getf pp :total))
                 (< (or (getf pp :processed) 0) (getf pp :total)))
            ;; prefilling: the bar says everything the words would have
            (format nil "~a ~a" spin (prefill-line pp (max 1 (- cols 6))))
            (let ((since (if *turn-started-ms*
                             (format nil " · ~a" (duration (- (internal-real-time-ms)
                                                              *turn-started-ms*)))
                             " · started before this head attached"))
                  (tokens (getf turn :tokens)))
              (concatenate
               'string
               spin
               " Responding"
               since
               (if (and (numberp tokens) (plusp tokens))
                   (format nil " · ~a tok" (thousands tokens))
                   ;; the character count where the server has not spoken, or a
                   ;; messages-backend turn whose seam carries no token count
                   (let ((chars (length (or (getf turn :text) ""))))
                     (if (plusp chars)
                         (format nil " · ~a chars" (thousands chars))
                         ""))))))))))

;;; --------------------------------------------------------- the composer ;;;
;;;
;;; A box with a title, whose bottom edge carries the WIRING (model · dialect ·
;;; endpoint) — the reference's shape, and the most visible structural
;;; difference this head had: a bare `›` line against a framed one.
;;;
;;; Degrades on a short screen: drawing a box costs two rows (its top and bottom
;;; edges) and this returns the bare line instead when the frame has not got
;;; them, so the composer never eats the last row of the transcript.

(defun composer-title (head)
  "The right-hand label of the box's TOP edge: how many subagents are running.

**Not the session title** — I put one there first, guessing from a code comment
instead of reading the code, and the operator's screen showed a bare `╭───╮` where
mine said `╭ hello, what we are doing here ───╮`. The reference's top edge carries
`N subagents running` when any are, and nothing otherwise.

Counted from the SUBAGENT events whose latest state for that subagent is
`running` — `subagent-rows`, the same fold the subagents pane draws, so the edge
and the pane cannot disagree. It used to fold here by the envelope's `session_id`,
which is the PARENT's (event.rs:841), so two children of one session counted as
one."
  (let ((running (count "running" (subagent-rows head)
                        :key (lambda (r) (or (getf r :state) "")) :test #'string=)))
    ;; NOTHING is nothing: returning a single space put a stray `╭ ───` on the box
    ;; where letibot draws `╭───`. Measured column-by-column against the two
    ;; screens, which is the only way a one-column difference shows up.
    (if (plusp running)
        (format nil "~d subagent~p running" running running)
        "")))

(defun composer-wiring (head &optional (cols 40))
  "The right-hand label of the box's BOTTOM edge: the alarm and the turn's status.

**Not the wiring** — same mistake as the title, same fix: the reference's bottom
edge is where the alarm triangle and the running turn's own status live, and the
wiring's model is in the header where it belongs.

COLS is the edge's width, passed through to `turn-status` so the prefill bar is
sized to the border it is inlaid into (`app.rs:5183`, `turn_status(w)`).

An alarm is `⚠` alone, because the counters behind it are `/status`'s and were
never worth a resident sentence of bright yellow. With nothing running and nothing
wrong, the edge is bare."
  (let ((parts (remove nil (list (and (alarmed-p head) "⚠")
                                 (turn-status head cols)))))
    ;; NOTHING is nothing: returning a space put a stray `─ ╯` on the box where
    ;; letibot draws `──╯`. Same defect as `composer-title`'s, one function over —
    ;; and only a column-precise diff shows a one-column difference.
    (if parts
        ;; no padding of its own: `box-edge` frames the legend (` … ─`), and a
        ;; legend that pads itself as well puts two spaces where the reference
        ;; has one on both sides of it
        (format nil "~{~a~^ · ~}" parts)
        "")))

(defun composer-ranges (head cols)
  "The composer buffer's wrapped rows, as index ranges at the box's inner width."
  (wrap-ranges (composer-buffer (head-composer head)) (composer-inner cols)))

(defun %composer-rows (head cols)
  "How many rows the composer buffer renders to, wrapped at the box's inner width.

The WRAP, not a ceiling of the whole buffer's width: the two disagreed on any
buffer with a newline in it, and the row count decides where the box's top edge
goes — so the box was one row short of its own body and the transcript moved
under it.

Takes HEAD rather than reaching for the global: the paint has `*head*` bound and
a TEST of the paint does not, and the difference is a render that dies with `NIL
is not of type LETICL::HEAD` — measured, twice, in this file. Anything here that
can be given the head is given it."
  (if (head-secret-req head)
      ;; a password is one row of dots however long it is, and the text is never
      ;; measured — see `composer-box-body`
      1
      (max 1 (length (composer-ranges head cols)))))

(defun composer-inner (cols)
  "The columns of editable text inside the box.

The row is `│ ` (2) + `› ` (2) + text + ` │` (2) = COLS, so the text gets COLS-6.
It was COLS-4 and every body row rendered two columns wide — measured: a 60-column
frame drew a 62-column row, which wraps in a terminal and pushes the whole frame
down a line on every keystroke."
  (max 1 (- cols 6)))

(defun box-edge (cols open close left right &optional (right-style '(:dim t)))
  "One edge of the composer's box, as segments — the reference's `box_edge`
(app.rs:5384-5411), which both of ours had only half of.

    ╭──────────────────────────── 2 subagents running ─╮
    ╰─────────────────────── ⚠ · ⠹ Responding · 4.2s ─╯

Three things ours got wrong and this fixes, each read off the reference's own
raw row rather than its plain text:

  · the legend is pinned **RIGHT**, not left. `composer-box-top` put the
    subagent count immediately after the `╭`, where the eye is not looking and
    where it collides with the header's left half one row above;
  · it is **framed** — ` {legend} ─` — so the legend sits in a notch in the
    border rather than being border that happens to be words;
  · and it is gated: no legend at all below `inner >= 10`, and the right legend
    is dropped rather than squeezed when its room falls under 4 columns. A
    legend squeezed to two characters is a legend nobody can read occupying
    room the border needs.

Invisible today on both edges because both legends are usually empty, which is
exactly why it went two rounds of `compare-heads` unnoticed: the difference only
exists while a subagent runs or a turn is answering.

The reference reopens `Role::Faint` after each legend because its palette closes
a span with a plain reset (`a reset is not a restore`). Cells carry their own
style here, so the reopen is structural: the border's segments are dim and the
legend's is its own."
  (let* ((w (max 4 cols))
         (inner (- w 2))
         (left-text (if (and (plusp (length left)) (>= inner 10))
                        (format nil "─ ~a " (%truncate-width left (max 1 (- inner 4))))
                        ""))
         (left-cols (string-width left-text))
         (room (max 0 (- inner left-cols 2)))
         ;; the reference computes the legend's room as `inner - left - 2` and
         ;; then spends three columns on the framing (` `, the legend, ` ─`), so
         ;; a legend that uses all of its room makes the edge one column wider
         ;; than the box. An edge one column over WRAPS, and a border that wraps
         ;; scrolls the whole frame by a row every time it is drawn, so the gate
         ;; is the reference's and the truncation is one tighter.
         (shown (if (and (plusp (length right)) (>= inner 10) (>= room 4))
                    (%truncate-width right (max 0 (- room 1)))
                    ""))
         (right-cols (if (plusp (length shown)) (+ 3 (string-width shown)) 0))
         (fill (max 0 (- inner left-cols right-cols))))
    (append (list (cons (string open) '(:dim t)))
            (when (plusp (length left-text)) (list (cons left-text '(:dim t))))
            (list (cons (make-string fill :initial-element #\─) '(:dim t)))
            (when (plusp (length shown))
              (list (cons " " '(:dim t))
                    (cons shown right-style)
                    (cons " ─" '(:dim t))))
            (list (cons (string close) '(:dim t))))))

(defun composer-box-top (head cols)
  "The box's top edge, with `N subagents running` pinned right.

`Role::Pending` — yellow (`style.rs:174`) — not `Strong`: the count is a thing
that is happening, which is the register the spinner on the bottom edge is
already in, and ours painted it bold, which is the header's register."
  (box-edge cols #\╭ #\╮ "" (composer-title head) '(:fg :yellow)))

(defun composer-box-bottom (head cols)
  "The box's bottom edge, with the alarm and the turn's status pinned right."
  (box-edge cols #\╰ #\╯ "" (composer-wiring head cols) '(:dim t)))

(defun %composer-body-rows (lines start inner)
  "LINES as box rows, the prompt on the FIRST row of the buffer only."
  (let ((lines (or lines (list ""))))
    (loop for line in lines
          for i from start
          for shown = (%truncate-width line inner)
          ;; the wall and the prompt are DIM, and the wall is its own segment with
          ;; a plain space after it — read off the two screens' escapes, which is
          ;; the only place the difference shows: ours was `ESC[2m│ ESC[0;1mESC[96m›`
          ;; against letibot's `ESC[2m│ESC[0m space ESC[2m›ESC[0m`.
          collect (list (cons "│" '(:dim t))
                        (cons " " nil)
                        (if (zerop i)
                            (cons "› " '(:dim t))
                            (cons "  " nil))
                        (cons shown nil)
                        ;; `inner - shown + 1`: the closing wall used to carry its
                        ;; own leading space (`" │"`), and splitting it into the
                        ;; pad is what makes the escape boundaries match letibot's
                        ;; without changing the row's width
                        (cons (make-string (max 0 (1+ (- inner (string-width shown))))
                                           :initial-element #\space) nil)
                        ;; the closing wall is its OWN dim segment with the space
                        ;; in the pad, not `" │"` together — one space inside the
                        ;; escape is the last column of difference between the two
                        ;; screens' box rows
                        (cons "│" '(:dim t))))))

(defun composer-window (head cols &optional max-rows)
  "Which wrapped rows of the composer the box draws, as `(values START SHOW N
CROW)` — the reference's `composer_rows` window (app.rs:5355-5358).

MAX-ROWS is what the fit ladder left the composer. A composer taller than the
rows it was given **scrolls to the caret, never to the top**: the person is
typing somewhere, and a window pinned at row 0 puts that somewhere off screen."
  (if (head-secret-req head)
      (values 0 1 1 0)
      (let* ((ranges (composer-ranges head cols))
             (n (max 1 (length ranges)))
             (show (max 1 (min (or max-rows n) n)))
             (crow (nth-value 0 (locate-in-ranges
                                 (composer-buffer (head-composer head))
                                 (composer-cursor (head-composer head))
                                 ranges)))
             (start (min (max 0 (- crow (1- show))) (- n show))))
        (values start show n crow))))

(defun composer-box-body (head cols &optional max-rows)
  "The body rows of the box: `│ › text… │`, the buffer WRAPPED.

It used to split on newlines and TRUNCATE each one, so a typed line longer than
the box was cut at the edge with no way to see the rest of it — and the caret,
which is a position in the text, had nowhere on the screen to be. The prompt is
on the first row only and continuation rows are indented by its width, as the
reference's editor does."
  (let* ((c (head-composer head))
         (inner (composer-inner cols))
         (buf (composer-buffer c))
         (all (if (head-secret-req head)
                  ;; **A DOT PER CHARACTER, and the text never even measured** —
                  ;; the reference's own comment at `app.rs:5343-5347`. Ours kept
                  ;; painting the ordinary buffer under the password card, so
                  ;; whatever had been typed before sudo asked sat on the screen
                  ;; while a password was being entered over the top of it.
                  (list (make-string (length (head-secret-buf head))
                                     :initial-element #\•))
                  (loop for (a . b) in (composer-ranges head cols)
                        collect (string-right-trim '(#\space) (subseq buf a b))))))
    (multiple-value-bind (start show) (composer-window head cols max-rows)
      (%composer-body-rows (subseq all (min start (length all))
                                   (min (+ start show) (length all)))
                           start inner))))

(defun composer-line (head cols &key (boxed (>= (head-rows head) 8)) max-rows)
  "The composer, as the rows it occupies — box plus body, or one bare line.

Returns a LIST of rows, because the box is three or more rows tall; the caller
places them from the bottom up. A single-row list is the degraded form.

BOXED and MAX-ROWS are the **fit ladder's** answers (`%fit-ladder`, render.lisp):
the ladder gives up the composer's rows one at a time and then the box itself,
in that order, and this used to decide both for itself from `head-rows`. The
defaults keep a caller that has not run the ladder working."
  (let ((inner (max 1 (- cols 2))))
    (declare (ignorable inner))
    (if (not boxed)
        ;; too short for a box: the bare line, with the prompt and the tail of
        ;; the buffer keeping the cursor end visible
        (let* ((buf (composer-buffer (head-composer head)))
               (prefix "› ")
               (visible (if (> (+ 2 (string-width buf)) cols)
                            (subseq buf (max 0 (- (length buf) (- cols 2))))
                            buf)))
          (list (list (cons prefix '(:fg :bright-cyan :bold t))
                      (cons visible nil))))
        (append (list (composer-box-top head cols))
                (composer-box-body head cols max-rows)
                (list (composer-box-bottom head cols))))))

(defun composer-caret (head cols &key (boxed (>= (head-rows head) 8)) max-rows)
  "Where the terminal's own caret goes, as (ROW . COL) inside the composer's own
rows — the reference's `composer_rows` third value.

**The composer's whole affordance is that caret.** This head asked for a steady
block at startup (`ESC[2 q`), hid the cursor (`ESC[?25l`) and then never said
where it went, so the prompt had no cursor at all — the operator: *\"the creepy
thing about leticl - prompt input doesnt have caret or cursor\"*. The box draws a
`›` and that is a decoration; the caret is the thing that says where the next
character lands."
  (let ((c (head-composer head)))
    (if (not boxed)
        ;; the bare line: the prompt is two columns and the tail is what is shown
        (let* ((buf (composer-buffer c))
               (cut (max 0 (- (length buf) (- cols 2)))))
          (cons 0 (+ 2 (string-width buf :start (min cut (composer-cursor c))
                                        :end (composer-cursor c)))))
        ;; a password puts the caret after the last DOT, and the buffer it is a
        ;; caret into is never measured (app.rs:5343-5347)
        (if (head-secret-req head)
            (cons 1 (+ 4 (length (head-secret-buf head))))
            (multiple-value-bind (start) (composer-window head cols max-rows)
              (multiple-value-bind (row col)
                  (locate-in-ranges (composer-buffer c) (composer-cursor c)
                                    (composer-ranges head cols))
                ;; +1 for the box's wall, +1 for the space after it, +2 for `› `;
                ;; the body's first row is one below the top edge, and START is
                ;; how many rows the window has scrolled past
                (cons (1+ (- row start)) (+ 4 col))))))))

(defun composer-rows-needed (head cols &key (boxed (>= (head-rows head) 8)) max-rows)
  "How many rows `composer-line` will return. The render needs this BEFORE it
composes the frame, because the transcript gets what is left."
  (if (not boxed)
      1
      (+ 2 (nth-value 1 (composer-window head cols max-rows)))))

;;; --------------------------------------------------------------- notice ;;;
;;;
;;; A notice that never expires becomes furniture: the old head pinned one to the
;;; status line for the rest of the session. The reference gives it a TTL in
;;; FRAMES (60), and dropping it is what makes the next one noticeable.

(defparameter *notice-ttl-frames* 60
  "How many frames a status notice survives before it stops being news.")

(defun tick-notice (head)
  "Age the status note one frame; clear it when its time is up.

A note the OPERATOR must act on is not on the TTL — an alarm and a stall both
persist until they are fixed, because those are about the state of the world
rather than about something that just happened."
  (let ((ttl *notice-ttl*))
    (when (and (head-status-note head) (plusp ttl))
      (if (= ttl 1)
          (setf (head-status-note head) nil
                *notice-ttl* 0
                (head-dirty head) t)
          (setf *notice-ttl* (1- ttl))))))

(defun say (head text)
  "Set a status note and START its clock. The one way to notice something."
  (setf (head-status-note head) text
        *notice-ttl* *notice-ttl-frames*
        (head-dirty head) t))

;;; ------------------------------------------------------- the attach wait ;;;
;;;
;;; The `Hello` carries the WHOLE SNAPSHOT, so on a session of thousands of rows
;;; there is a real wait before the first frame — and this head drew an empty
;;; screen with a status line, which is indistinguishable from a head attached to
;;; the wrong socket.
;;;
;;; The reference's shape, and its four properties are each a bug it had:
;;;
;;;  · **centred horizontally on the indicator's OWN row**, so "centred" is a
;;;    statement about the cat and not about whatever else shares the line (the
;;;    first version put ` attach` beside it);
;;;  · **walking in place** — the frames differ in width, so the SLOT is what is
;;;    centred and the cat sits at its left edge. Centring each frame on its own
;;;    made it jitter sideways, which reads as a drawing bug rather than a walk;
;;;  · **moved by the CLOCK**, not a frame counter, so the screen stays a pure
;;;    function of time;
;;;  · **vertically in the conversation**, not pinned under the header.
;;;
;;; A cat rather than a spinner glyph because this is the one wait where a spinner
;;; is the honest answer: the work is client-side and the head genuinely cannot say
;;; more, having been told nothing.

(defparameter +cat-frames+
  #("(=^.^=)" "(=^.-.=)" "(=^o^=)" "(=^-.-=)" "(=^.^=)~" "(=^.-.=)~" "(=^o^=)~" "(=^-.-=)~")
  "A cat walking right, one leg changing per frame.")

(defparameter +cat-slot+ (loop for f across +cat-frames+ maximize (length f))
  "The width of the SLOT the cat walks in: the widest frame. Centring each frame
on its own width made a 7-wide and an 8-wide cat jitter instead of walk.")

(defun cat-frame (elapsed-ms)
  (aref +cat-frames+ (mod (floor (or elapsed-ms 0) 120) (length +cat-frames+))))

(defun %centred-row (text cols)
  "TEXT centred in COLS columns."
  (let* ((w (string-width text))
         (pad (max 0 (floor (- cols w) 2))))
    (list (cons (make-string pad :initial-element #\space) nil)
          (cons text nil))))

(defvar *attach-started-ms* nil
  "When this head sent its ATTACH, or NIL once a Hello has arrived. A defvar: the
clock the cat walks to.")

(defparameter +attach-impatient-ms+ 2000
  "How long a wait goes before the screen says the daemon has not answered — the
reference's `ATTACH_IMPATIENT`.")

(defun attaching-p (head)
  "Has this head asked for a session and not been answered?

**The clock IS the flag.** This also required `(not (head-connected head))`, and
`run` sets `connected` to T the moment the socket opens — deliberately, because
`%send` refuses to write while disconnected and the ATTACH is the first frame —
so `attaching-p` was false from before the first paint and the walking cat NEVER
DREW. The blank screen it exists to replace is what the operator got on every
attach to a big session. `*attach-started-ms*` is set when the ATTACH goes out and
cleared by the `hello` arm, which is exactly the reference's `attaching` flag
(app.rs:1559, 1653)."
  (declare (ignore head))
  (and *attach-started-ms* t))

(defun attach-lines (head cols)
  "The wait, or NIL when there is nothing to wait for."
  (when (attaching-p head)
    (let* ((elapsed (max 0 (- (internal-real-time-ms) *attach-started-ms*)))
           ;; LEFT-justified in a fixed slot (`{cat:<CAT_SLOT$}`): the frames are
           ;; different widths, and right-justifying moves the cat's own centre
           ;; as it walks — the jitter the fixed slot exists to prevent.
           (slot (format nil "~va" +cat-slot+ (cat-frame elapsed))))
      (append
       (list (list (cons "" nil))                ; the caller centres vertically
            (%centred-row slot cols)
            (list (cons "" nil))
            (%centred-row "· · · · ›" cols)        ; a pawprint trail, so a still
            (list (cons "" nil))                   ; frame still reads as going
            (%centred-row "asking the daemon for this session" cols)
            (list (cons "" nil))
             (%centred-row (duration elapsed) cols))
       ;; past the impatient mark the frame says how to get OUT, so a wait on a
       ;; daemon that will never answer is not a screen you have to guess at
       (when (>= elapsed +attach-impatient-ms+)
         (list (list (cons "" nil))
               (%centred-row "the daemon has not answered. ctrl-c twice, or wait" cols)))))))
