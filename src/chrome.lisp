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

(defvar *ctrlc-at* nil
  "When the last `ctrl-c` on an empty composer arrived, for the double-tap quit.

Beside `*esc-at*` and here for the same reason: the hint bar reads it. There was
no counter at all, so the FIRST ctrl-c opened the quit card — and the hint bar
had nothing to show in between, which is the press that teaches the second one.")
(defparameter *ctrlc-window-ms* 1000
  "How long a second `ctrl-c` still means the same gesture — the reference's
`QUIT_WINDOW_MS`. Shorter than the interrupt's, deliberately: leaving is the more
expensive answer of the two.")

(defvar *resyncs* 0
  "How many Resync frames this head has taken. A counter the reference keeps on
its status line and shows on /status; a non-zero value means this head lost its
place at least once, which the operator should be able to see without asking.")

;;; the fit ladder drops it, is what `/status` and a restyle both still reach it; the
;;; note and the stall are their own chrome rows now (`notice-line`, `stall-row`) and;;; --------------------------------------------------------------- model ;;;
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
                   (cons "resync" *resyncs*)
                   ;; **A frame this head could not read alarms too**, and it is the
                   ;; fourth term of the reference's `alarmed()` (app.rs:7929-7931:
                   ;; `dropped + scrubbed + resyncs + unreadable > 0`). It belongs on
                   ;; the border for the same reason `scrubbed` does: the head is still
                   ;; running and the conversation has the sentence, but a counter
                   ;; that only appears on `/status` is one the operator has to have
                   ;; already suspected.
                   (cons "unreadable" *unreadable-total*))))

(defun alarmed-p (head)
  "Is anything wrong enough to spend a row on?

`alarm-counts` now carries `scrubbed`, which is the reference's third term. The
`(not connected)` clause is ours and stays: the reference exits on a dead socket
(`driver.rs:102-108`) and this head reconnects, so \"detached\" is a state it can
be in and the reference cannot.

**A render error alarms too**, and it is the one that most needs to: the failure
is normally painted into the screen, so if the failure is IN the painting the frame
saying so is exactly what does not arrive. `⚠` on the composer's edge is the one
channel a broken renderer cannot take away, and `/status` carries the message."
  (or (alarm-counts head)
      (not (head-connected head))
      (and *last-render-error* t)))

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

(defun %session-brief (s)
  "This session's OWN row from the daemon's list, or NIL when it is not there.

The list arrives on the `Hello` and on every `sessions` frame, and this head already
keeps it and reads it for `:stored-items` (the picker's `N rows`). The two fields it
did not read are the ones that answer *how big is this conversation* without a turn.

**A subagent session finds no row here, and the reference has the same gap**: both
heads filter `parent_session_id` rows out of the list they keep (a subagent is not a
session a picker lists), so a head switched INTO one has nothing to read. Recorded
rather than half-fixed — the fix is a second, unfiltered list, and it is not needed for
the screen R8 is about."
  (find (session-session-id s) (session-sessions s)
        :key (lambda (b) (getf b :session-id)) :test #'string=))

(defun %usage-backfilled (s)
  "The context the SESSION's own row remembers, as a usage plist, or NIL.

**R8: the context size is a property of the SESSION, not of this head's uptime.**
A daemon that restarted has no turn state in the snapshot — `TurnFinished` is
ephemeral and a view rebuilt from the transcript has no turn — so after a reattach, a
resume, or opening a session from disk, the turn's usage is empty and this head's
whole `ctx` segment disappeared. On the operator's screen the symptom was intermittent
in exactly the way the cause predicts: it showed while a turn had run in THIS head's
lifetime and showed nothing after a reattach — most of the time, and precisely when
somebody asks how big the conversation is (*\"leticl doesnt show context size for
whatever reason\"*).

The daemon writes both columns on EVERY round finish (`persist_context`,
harness.rs:4930-4941, from `TurnMetrics`), so the row is the durable half of the same
measurement. The reference reads it in its `Sessions` arm (app.rs:2116-2140) and only
when it has no usage of its own.

**Two disciplines, and they are the reason this is not a one-liner.**

  · **The size is known and the cache FRACTION may not be.** A row carries
    `context_cached` only if a turn finished after that column existed, so the same
    refusal the header already makes applies here: `:cached-tokens` is ABSENT from the
    plist rather than zero, and `%usage-numbers`' own `(third ctx)` guard is what keeps
    `0% cached` off the screen. A zero would read as *nothing was cached*, which is a
    measurement, where the truth is that nobody measured.
  · **A backfilled row carries NO COST.** `:cost-micros-usd` is absent, never 0 —
    nothing recorded a per-turn cost on the row, and a zero there would report a
    metered session as free. That is §13.2b in its most expensive form: a number that is
    absent is not a number that is zero."
  (let* ((brief (%session-brief s))
         (tokens (and brief (getf brief :context-tokens)))
         ;; the same guard the turn path uses: a count of zero is not a measurement of a
         ;; prompt, it is a row nobody wrote
         (cached (and brief (getf brief :context-cached))))
    (when (and (numberp tokens) (plusp tokens))
      (append (list :prompt-tokens tokens)
              (when (numberp cached) (list :cached-tokens cached))))))

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
                    (and turn (getf turn :usage))
                    ;; **AND WHEN THERE IS NO TURN AT ALL** — a reattach, a resume, a
                    ;; session opened from disk — the SESSION's own row. This is the
                    ;; fallback that was missing: without it the whole `ctx` segment
                    ;; vanished on exactly the screens where nobody can answer the
                    ;; question any other way.
                    (%usage-backfilled s)))
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
in the chrome above the box, where the card is (app.rs:5069-5075).

**One thing outranks the note: a wait for a daemon this head asked to stop.** That
row is drawn from the pending request rather than from a note, so nothing can
expire it, and it is the only row that matters while it is up — the head is on its
way out and the operator is owed the reason it has not gone. See `head.lisp`, \"a
stop that is an OUTCOME\"."
  (let ((waiting (stop-wait-row head cols))
        (note (head-status-note head)))
    (cond
      (waiting waiting)
      ((and note (plusp (length note)))
       (list (list (cons (truncate-to-width (format nil "· ~a" note) cols)
                         '(:fg :magenta))))))))

(defun stop-wait-row (head cols)
  "The row the head waits under while a daemon it asked to stop has not gone.
NIL when nothing is pending.

**Its own row rather than a status note**, because a note expires on
`+notice-ttl-ms+` and this fact must not: the whole defect was a request whose
outcome nobody ever learned, and a sentence that disappears while the wait runs is
that defect with a sentence attached. Yellow, the stall line's role — this is a
thing that is taking longer than it should, not a failure."
  (declare (ignorable head))
  (let ((text (stop-wait-text)))
    (when text
      (list (list (cons (truncate-to-width text cols) '(:fg :yellow)))))))

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
          (list (list (cons (truncate-to-width
                             (format nil "  ~{~a~^  ·  ~}" parts) cols)
                            '(:dim t)))))))))

(defun stall-row (head cols)
  (let ((text (stall-text head)))
    (when text
      (list (list (cons (truncate-to-width text cols) '(:fg :yellow)))))))

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
    (list (cons (truncate-to-width text (max 1 (or cols 1)))
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:dim t)))))

;;; --------------------------------------------------------------- hint bar ;;;

(defun %armed-p (at window-ms)
  "Is a two-tap gesture still within its window? NIL when it was never started."
  (and at (< (- (get-internal-real-time) at)
             (* window-ms (/ internal-time-units-per-second 1000.0)))))

(defun hint-bar (head cols)
  "The line under the composer that says what the keys do HERE.

The reference's `hint_bar`: ONE constant string per context — a key that closes
a card is not the key that interrupts a turn, and a hint that names the wrong key
is worse than no hint at all."
  (declare (ignore cols))
  ;; **ONE CONSTANT STRING, no prefix.** It used to open with the keys that
  ;; change — `enter send` idle, `esc interrupt` while a turn runs — and those
  ;; are three different lengths in front of the same tail, so the line moved
  ;; sideways whenever a turn started or the first character was typed. The
  ;; reference deleted exactly that and says so at app.rs:5001-5004; this head
  ;; had copied the prefix from an older commit of it, and the 1:1 rig caught
  ;; the row on every frame of all ten fixtures.
  (let* ((armed (cond
                  ;; the ARMED warnings stay: `Editor::hint` still returns these
                  ;; two and nothing else (editor.rs:820-834), because a gesture
                  ;; half-made is the one thing the bottom row must say.
                  ((head-quit-open head) nil)
                  ((%armed-p *esc-at* *esc-double-ms*)
                   (cons "esc again to interrupt" '(:bold t :fg :yellow)))
                  ((%armed-p *ctrlc-at* *ctrlc-window-ms*)
                   (cons "ctrl+c again to exit" '(:bold t :fg :yellow)))
                  (t nil)))
         (tail (cond
                 ((head-quit-open head) "1/2 or ↑↓ then enter · esc stays")
                 ((member (head-mode head) '(:help :status)) "esc closes this")
                 ;; a listing arrived, it is not a screen you opened from a list of
                 ;; keys: `esc closes` alone would not say that the arrows do anything
                 ((eq (head-mode head) :slash) "↑↓ and the wheel scroll · esc closes")
                 ((eq (head-mode head) :picker) "type a number to switch · /new [title] · esc closes")
                 (*pick-open* "a row number switches · ↑↓ then enter · or type a name · esc closes")
                 ((eq (head-mode head) :todos) "↑↓ moves · enter or tab unfolds · pgup/pgdn and the wheel scroll · esc closes")
                 ((eq (head-mode head) :config) "arrows move · enter changes a row marked ✎ · esc closes")
                 ((eq (head-mode head) :subagents) "subagents this session spawned · esc closes")
                 ((eq (head-mode head) :jobs) "background jobs this session started · ↑↓ then enter reads one · esc closes")
                 ((eq (head-mode head) :peek) "arrows scroll · enter re-reads · esc back")
                 ;; the overlay's row names ESC BACK TO JOBS, not "closes": the
                 ;; jobs list never closed under it, and a bottom row that says
                 ;; `esc closes` on a pane that goes back one level teaches the
                 ;; wrong thing about the key (app.rs:5424)
                 ((eq (head-mode head) :job-out)
                  "↑↓ scroll · → next page · ← back · enter re-reads · esc back to jobs")
                 ((head-secret-req head) "enter submits · esc refuses the password")
                 ((%open-decision head) "a row number answers · ↑↓ then enter · or type an option · /help")
                 ;; **`ctrl-n` IS SECOND, AND THE PLACEMENT IS A MEASUREMENT** (R22).
                 ;; This bar is 136 characters — the same 136 as letibot's, item for
                 ;; item — and at the usual 80 columns everything past column 80 is off
                 ;; the screen. Appending `ctrl-n notes` at the END puts it at 137 and
                 ;; invisible; second, right after `ctrl-s sessions`, it starts at 18.
                 ;; `ctrl-s` keeps first place because opening the session list is what
                 ;; an operator reaches for with no notes in front of them; `ctrl-n` is
                 ;; a reflex, and a reflex nobody can see is a key nobody presses.
                 (t "ctrl-s sessions · ctrl-n notes · ctrl-p todos · ctrl-g subagents · ctrl-r thinking · ctrl-t tool output · ctrl-q jobs · tab completes /commands · /help"))))
    (if armed
        (list armed (cons (format nil " · ~a" tail) '(:dim t)))
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
                        (format nil "─ ~a " (truncate-to-width left (max 1 (- inner 4))))
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
                    (truncate-to-width right (max 0 (- room 1)))
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
          for shown = (truncate-to-width line inner)
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
;;; status line for the rest of the session. Dropping it is what makes the next one
;;; noticeable.
;;;
;;; **The clock lives on the HEAD, beside the note it ages, and it counts TIME.**
;;; Both halves were learned the hard way, and they are the same lesson this file
;;; keeps meeting: state that belongs to a head does not live in a global, and a
;;; timer does not count a unit that stops when the thing being timed is not the
;;; thing counting.
;;;
;;; MEASURED IN THE FIELD, on the live head, because the note was stuck on screen:
;;;
;;;     :note "permission answered"  :ttl 0  :dirty NIL     <- and identical 2 s later
;;;
;;; A note with no clock, on a head whose loop was running and painting that whole
;;; time (the operator watched thinking text stream underneath it). The note and its
;;; clock had COME APART, permanently: `tick-notice` was guarded on `(plusp ttl)`, so
;;; with the global at 0 the note could never be aged — and the global is left at 0
;;; by every one of the seventeen places that set the note DIRECTLY rather than
;;; through `say`. `"permission answered"` is the daemon's own `Accepted` note, and
;;; that arm is one of them.
;;;
;;; So three things changed together and each would be wrong alone:
;;;
;;;   · the deadline is a **millisecond** the head holds, not a frame count in a
;;;     global — it cannot come apart from the note because it is a slot of the same
;;;     struct, and `notice-remaining-ms` reports it beside the note it belongs to;
;;;   · it expires **in time**, so it is the same duration on a busy screen and a
;;;     quiet one. A TTL counted in frames is a timer that stops when the frames
;;;     stop, which is exactly when a notice is left standing longest;
;;;   · `say` is the only writer, and it STARTS the clock. `clear-note` is the only
;;;     clearer, and it stops it. A note nobody started a clock on was reachable at
;;;     seventeen call sites, and the guard that made it permanent was written as a
;;;     feature — "an alarm persists" — which is true of the alarm line and false of
;;;     this slot.

(defparameter +notice-ttl-ms+ 1600
  "How long a status notice stays on the screen before it stops being news.

**The number that was already in effect, measured rather than chosen.** The old
constant was 60 FRAMES, and measured on the live head from `say` to the note going,
polled from the shell so the eval socket's paint lock could not starve the loop it
was watching:

      0.518s ttl 41    ·    1.061s ttl 20    ·    1.599s gone

— about 38 loop passes a second on an idle screen, and **1.6 s of wall time**. So
this changes the UNIT and not the behaviour: the same sentence stays for the same
second and a half, on a busy screen as on a quiet one.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defun notice-remaining-ms (head)
  "Milliseconds left on HEAD's status note, or NIL when nothing is counting.

**The one function that answers \"is the note near its end\"** — and it answers it
from the note's own head, so the two cannot disagree. The defect this replaces was
read as `head-status-note` non-NIL with `*notice-ttl*` 0: a note with no clock, on a
head that could never clear it."
  (let ((until (head-notice-until head)))
    (when (plusp until)
      (max 0 (- until (internal-real-time-ms))))))

(defun tick-notice (head)
  "Clear the status note once its deadline has passed. T when it cleared one.

**A comparison against the clock, not a decrement.** The old body took one frame off
a counter per loop pass and cleared the note at 1, which made the notice's lifetime a
function of the frame rate — and made a note whose counter had already reached 0
immortal, because the body was guarded on `(plusp ttl)`.

A note the OPERATOR must act on is not on this clock — an alarm and a stall both
persist until they are fixed, because those are about the state of the world rather
than about something that just happened. That is what the guard is FOR; it just has
to be the note's own state that says so, and \"no deadline\" says it without also
saying \"never again\"."
  (let ((until (head-notice-until head)))
    (when (and (head-status-note head)
               (plusp until)
               (>= (internal-real-time-ms) until))
      (clear-note head)
      t)))

(defun say (head text)
  "Set a status note and START its clock. The one way to notice something.

**Every writer goes through here**, and that is the fix: the clock is armed by the
same `setf` that sets the note, so there is no way to set one without the other. The
seventeen direct `(setf (head-status-note head) …)` sites this replaced are the
reason `\"permission answered\"` was immortal."
  (setf (head-status-note head) text
        (head-notice-until head) (+ (internal-real-time-ms) +notice-ttl-ms+)
        (head-dirty head) t))

(defun clear-note (head)
  "Take the status note down and stop its clock. The one way to clear one."
  (setf (head-status-note head) nil
        (head-notice-until head) 0
        (head-dirty head) t))

;;; ------------------------------------------- the frame and the clock ;;;
;;;
;;; **A number the frame computes from the clock is computed and never drawn again.**
;;; The frame is rebuilt when `head-dirty` is set, and only a FRAME or a KEY sets it —
;;; so `*now-ms*`, which the loop sets on every pass, is read by a builder that is not
;;; asked to run. Measured on a scratch head with a 45-second-old running call, from
;;; the shell with no eval in between (an eval POKES `head-dirty` to prove the loop
;;; can paint — `scripts/tui-eval:220` — so a probe that watches freshness keeps the
;;; frame fresh; see HACKING.md, "a measurement that refreshes what it measures"):
;;;
;;;     value  75637 ms -> 78680 ms          (it moves: read from this head's clock)
;;;     glass  Running · 1m19s · 1m19s · 1m19s   (frozen: nothing asked for a frame)
;;;
;;; — the frame is a SNAPSHOT of the clock, kept until an event replaces it. That is
;;; R13's defect one layer above where it was reported: the number was never the
;;; problem, the ASKING was.
;;;
;;; **The fix is not "repaint always".** A head that paints at the loop's rate burns a
;;; core and a terminal to say nothing has changed. It is: ask for a frame while the
;;; frame has a part that is a function of time, and at a rate a person can read.

(defparameter +live-frame-ms+ 100
  "How often a frame with a part that is a function of TIME is rebuilt.

**Tenths of a second, and that is the operator's number rather than a choice of
ours**: a live duration answers *is this moving, and roughly how long has it been —
a live coarse timer would be nice, say 1/10th of a second*, and a figure that churns
every frame is noise that also makes the row impossible to read.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defvar *last-paint-ms* 0
  "When this head last produced a frame, on the monotonic clock.

**The fact the loop needs and the frame cannot carry**: the loop is what DECIDES to
paint, so the loop is what has to know how long it has been since it last did. A
`defvar` rather than a head slot because a struct change is a RESTART in this SBCL,
and nothing about this fact justifies one. Stamped by `%render-and-paint` on every
path, including the failure one — a paint that fell back to the failure frame is
still a frame, and a stamp that did not move would ask for another one immediately,
which is a head spinning on a broken renderer.")

(defun %live-decision (head)
  "The open ask whose DEADLINE the frame is counting down, or NIL.

§1.6's card carries a clock — `expires in 5 min`, `47s left` — and a clock on a card
is a reason to repaint for the same reason a spinner is. It is the one part of this
frame whose *granularity* is not a tenth of a second: see `live-frame-interval-ms`."
  (let ((d (first (session-open-decisions (head-session head)))))
    (and d (numberp (getf d :deadline)) t)))

(defun live-frame-p (head)
  "Is something on HEAD's frame a function of the CLOCK?

Each part named here is drawn from `*now-ms*` or from `internal-real-time-ms` while
the frame is built, so a frame built a second from now would differ with NO event in
between: the composer's spinner and its `· {since}` (`turn-status`), a running call's
elapsed (`%call-elapsed-ms`), the stall row becoming due (`stall-text`), the
carry/filling line's bar and its patience, and an open ask's deadline (§1.6).

**A notice and a pending stop-wait are deliberately NOT here.** They arm their own
deadline and mark the head dirty when a tenth of it passes (`tick-notice`,
`tick-stop-request`), so they already ask for the frames they need; naming them again
would be a second spelling of one rule, and the second spelling is the one that
rots."
  (let ((turn (session-turn (head-session head))))
    (or (and turn (string= (turn-state-name turn) "running"))
        (some (lambda (c) (string= (getf (getf c :state) :state) "running"))
              (getf turn :calls))
        (filling-active-p)
        (and *carry-last-done* *carry-moved-at*)
        (and (%live-decision head) t))))

(defun live-frame-tenths-p (head)
  "Is any live part of the frame drawn in TENTHS — the rate `+live-frame-ms+` is for?

The spinner, a running call's elapsed and the carry bar all move continuously, so
they want the fastest rate a person can read. **A deadline does not**, and neither
does the stall row: those change once a second at most, so a decision card waiting on
its own clock asks for ONE frame a second rather than ten — the difference between a
countdown and a head burning a core to redraw the same number."
  (let ((turn (session-turn (head-session head))))
    (or (and turn (string= (turn-state-name turn) "running"))
        (some (lambda (c) (string= (getf (getf c :state) :state) "running"))
              (getf turn :calls))
        (filling-active-p)
        (and *carry-last-done* *carry-moved-at*))))

(defparameter +live-frame-coarse-ms+ 1000
  "How often a frame whose only live part is a COUNTDOWN is rebuilt.

One second, because that is the finest thing a countdown can say: the ladder in
`deadline-said` is whole minutes far out and whole seconds near, and a repaint at ten
times that rate would draw the same characters nine times. Measured: a live frame at
`+live-frame-ms+` costs 0.07 % of a core; a head idling on the one-second rate is
inside the noise.")

(defun live-frame-interval-ms (head)
  "How long a frame with a clock in it may stand: 100 ms, or 1000 for a countdown only."
  (if (live-frame-tenths-p head) +live-frame-ms+ +live-frame-coarse-ms+))

(defun live-frame-due-p (head)
  "Has the CLOCK asked for a frame — as opposed to an event — and is one due?

False on a head with nothing live in it, which is the state that keeps an idle head
at `sleep 0.03` and off the operator's CPU."
  (and (live-frame-p head)
       (>= (- (internal-real-time-ms) *last-paint-ms*)
           (live-frame-interval-ms head))))

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

(defparameter +attach-wait-ms+ 30000
  "How long this head waits for a `Hello` before it gives up and says why.

**The reference's `ATTACH_WAIT` (`bin/letibot-tui.rs:167`), and the deadline is the
point rather than the number.** A daemon that accepted the connection and sent no
Hello is not an absent daemon — it is a HUNG one, and the difference matters to
whoever has to deal with it: absent means start one, hung means find out why. So the
head stops waiting, exits, and its farewell names `letibot --status` (what is on the
socket) and `letibot --stop` (how to end it from outside), which are the two commands
a person needs and neither of which the screen can offer.

Ours waited for ever, with a two-second line that said `ctrl-c twice, or wait` and
nothing about the daemon being hung. Measured on a scratch daemon that accepts and
never answers: the head sat on the cat indefinitely.

**Ctrl-C still works during the wait** — the input thread drains keys and the loop
runs `%handle-key` the whole time, which is what the hint bar under the frame has
promised since before there was a frame.")

(defun attach-overdue-p ()
  "Has the attach been unanswered past `+attach-wait-ms+`?"
  (and *attach-started-ms*
       (>= (- (internal-real-time-ms) *attach-started-ms*) +attach-wait-ms+)))

(defun attach-gave-up-said ()
  "The farewell for a daemon that took the connection and said nothing."
  (format nil "the daemon did not answer within ~ds. It accepted the connection and ~
               sent no `Hello`, which is a hung daemon rather than an absent one — ~
               `letibot --status` says what is on the socket, and `letibot --stop` ~
               stops it."
          (floor +attach-wait-ms+ 1000)))

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

;;; -------------------------------------------------------- the carry line ;;;
;;;
;;; **One line for a bulk announcement whose bodies are still coming**, and it exists
;;; because `/reseat` and `/compact` announce every carried row before a single body
;;; follows. Drawn one per row that is a screen of placeholders — the operator's word
;;; was *"insane amount of grainess"*, and their instruction was to reuse what already
;;; exists: *\"we have this cat animation for progress and we have prefill progress bar
;;; for local models\"*.
;;;
;;; So: `cat-frame` (the walking cat the pre-attach wait draws) and `progress-bar`
;;; (the three-valued bar the local prefill draws), fed with ROWS instead of tokens.
;;;
;;; **IT SAYS WHAT IT KNOWS AND NOT WHY.** The head can see that a bulk announcement
;;; left rows without bodies; it cannot see whether the operation behind it was a
;;; reseat, a `/compact`, a resume or a plain attach. So the sentence is cause-free —
;;; `N rows announced, waiting for the daemon to send them` — and the named version
;;; (`carrying the conversation onto the new prompt`) belongs to a daemon that reports
;;; the operation it is running, which is what `SessionEvent::ImportProgress` landed
;;; for at protocol 23. A head that names a cause it has not observed is the same
;;; defect as a counter derived from a proxy: the sentence claims something the
;;; evidence does not know.

(defparameter +body-patience-ms+ 5000
  "How long a row may sit announced-without-a-body before the head says it never came.

**MEASURED, and the measurement is why it is not the reference's 3000.** On a live
session (this head, pid 2889943, 59 consecutive announce→body pairs): the longest gap
was **31 ms**, the 90th percentile **1 ms**, the median **0**, and none exceeded
1000 ms. A body normally follows its announcement inside the same 30 ms tick.

So 3000 would work — and the reference's 3000 still produced a FALSE alarm
(*\"9,570 row(s) announced and never filled in\"*, three seconds into a healthy import),
because its sentence fired on a *rendering* of the gap rather than on the gap. Two
things follow, and they are the whole of this constant:

  · **the patience has to cover a gap that is genuinely slow.** This head adds no case
    of its own, and 5000 ms is 160× the slowest ordinary body measured.
  · **the case that CAN honestly take minutes is excluded by the TRIGGER, not waited
    for.** A prompt queued behind a running turn is a live `transcript_appended` whose
    content arrives when the prompt is sent — R2, *\"a queued prompt first reaches model,
    thinking starts, and after some time the prompt goes out of queue and appears\"* —
    and that can be minutes. It never enters this count: the count is a **bulk
    announcement's** rows (`note-carry`), and a queued prompt arrives one event at a
    time. Waiting five minutes to report a hole would make the diagnostic useless;
    knowing which rows are waiting on a queue is what makes a five-second patience
    honest.")


(defparameter +carry-min-rows+ 64
  "How big a bulk announcement has to be before it is drawn as a carry BAR.

**MEASURED.** Over the daemon's own store (242 turns across its sessions): rows per turn
— median **12**, p90 **317**, maximum **3635**; and the two carries this session has
actually seen were **2702** and **4473** rows. So 64 sits above an ordinary turn's tail
and below any real carry, with the median turn five times under it.

**And it gates the BAR, not the DIAGNOSTIC.** A small batch — a resync of a three-row
session, a snapshot with a couple of holes in it — draws no bar, because a bar with a cat
on it for three rows is noise dressed as information. But if those rows never arrive,
`carry-line` still says so: that sentence is the only thing on the screen that ever
reports a row the daemon announced and never sent, and the operator learned about a real
daemon-side hole from exactly it. Suppressing it for being small would throw away the
diagnostic to protect the decoration.")

(defvar *carry-last-done* nil
  "How many carried rows had arrived at the last frame that asked, or NIL.

The only state the line needs, and it is about the SEQUENCE of frames rather than about
the session — which is why it is here and not in `session.lisp`: the clock it is
compared against is this file's (`*now-ms*`). Bound by `with-replay-globals`, because a
replay must answer the same bytes twice.")

(defvar *carry-moved-at* nil
  "When `*carry-last-done*` last changed, on `*now-ms*`'s clock. NIL before any carry.")

(defun %carry-counts-text (done total &optional (unit "rows"))
  "`1400 of 2.7k rows`, with the numerator right-aligned in the width of its own
denominator — which is the widest it can ever be.

**Every field that can change width sits left of everything that cannot.** Two things
vary as a carry runs: this numerator, which grows from `0` to `2.7k`, and the cat,
whose frames are eight and nine columns. Anything drawn to the RIGHT of either moves
when it changes, and the operator watched exactly that: *\"move cat to the right most
position or thngs jump around\"*. So the numerator pads to the denominator's width,
the cat occupies a fixed SLOT, and the bar's own width is fixed by the columns rather
than by the fraction — leaving the bar's edge as the only thing on the row that is
meant to move."
  (let* ((d (thousands total))
         (d-w (length d)))
    ;; `~v@a` and not `~va`: `~A` pads on the RIGHT and this number is padded on the
    ;; LEFT. The first version of this line read `0    of 2702 rows` — the alignment
    ;; was there and on the wrong side, which is the same defect wearing the opposite
    ;; coat.
    (format nil "~v@a of ~a ~a" d-w (thousands done) d unit)))

(defun %carry-row-width (row)
  "The columns ROW occupies. `%segs-width` lives in markdown.lisp, later in the load
order; this is the same sum and one of the two has to exist twice."
  (loop for seg in row sum (string-width (car seg))))

(defun %carry-row (done total cat cols &optional (unit "rows"))
  "The bar, the count and the cat — as wide as COLS, or as near as the count alone
can be.

**It degrades by DELETION from the bar back**, which is `prefill-line`'s own rule, and
the order is what matters: the bar is the most expensive field and the least
load-bearing, the count is the FACT, and the cat is decoration. A carry on a
30-column terminal still has to say how far along it is — a row that overflowed and
lost its tail to the painter would say `1400 of` and nothing else, silently.

The bar's width is fixed by COLS and the fixed fields rather than by the fraction, so
its edge is the only thing on the row that moves."
  (let* ((counts (%carry-counts-text done total unit))
         (bar-cols (max 8 (min 40 (- cols (+ +cat-slot+ (length counts) 8)))))
         (full (list (cons "  " nil)
                     (cons (progress-bar (list :total total :cache done :processed done)
                                         bar-cols)
                           nil)
                     (cons " " nil)
                     (cons counts '(:dim t))
                     (cons "  " nil)
                     (cons cat '(:dim t))))
         (no-bar (list (cons "  " nil)
                       (cons counts '(:dim t))
                       (cons "  " nil)
                       (cons cat '(:dim t)))))
    (cond
      ((<= (%carry-row-width full) cols) full)
      ((<= (%carry-row-width no-bar) cols) no-bar)
      (t (list (cons "  " nil)
               (cons (truncate-to-width counts (max 1 (- cols 2)))
                     '(:dim t)))))))

(defun filling-progress-line (what unit done total cols &optional (now *now-ms*))
  "**THE one renderer for a counted operation**, whoever counted it.

A blank, the bar with `done of total {unit}` and the cat, and the operation's own word
under it. Every caller goes through here — the daemon's `filling` event and the head's
own bulk-announcement inference — so the two cannot drift apart, and the operator's
instruction (*\"we have this cat animation for progress and we have prefill progress bar
for local models. reuse that instead of spanning me with grayness\"*) is served by one
piece of code rather than two that look alike today.

    ▐███████████████████▊░░░░░░░░░░░░░░░░░░▌ 1400 of 2702 rows  (=^.^=)~
      carrying the conversation onto the new prompt

`WHAT` is the daemon's own word for the operation and is drawn VERBATIM — a head that
composes a sentence about an operation it inferred is the defect this whole line keeps
being an example of. When there is no `what` (the head's own inference) the sentence is
cause-free: `N rows announced, waiting for the daemon to send them`.

`UNIT` is the noun the count is in — `parts` for an import, `rows` for a carry. The
daemon chooses it because the daemon is the layer counting.

The bar is two-valued: landed cells are `█` and the rest `░`, and `▓` — the prefill's
`processed`, the band that means *being computed now and costing you* — never appears,
because neither a carry nor a read spends anything. The reference paints that band with
its `cache` role for exactly this reason (*\"that one is yellow\"*, on the first version),
and here it is carried in the GLYPH, so it survives a terminal with no colour at all."
  (let ((cat (format nil "~va" +cat-slot+ (cat-frame (or now 0)))))
    (list nil
          (%carry-row done total cat cols (or unit "rows"))
          (list (cons (truncate-to-width
                       (if (and what (plusp (length what)))
                           (format nil "  ~a" what)
                           ;; TRUNCATED WITH DISCLOSURE rather than left for the painter:
                           ;; a painter that silently drops what passes the right edge is
                           ;; the §6 gap, and a sentence cut with an `…` is at least a
                           ;; sentence the reader knows was cut.
                           (format nil "  ~d ~a announced, waiting for the daemon to send them"
                                   (- total done) (or unit "row")))
                       cols)
                      '(:dim t))))))

(defun carry-line (head cols)
  "The line for a bulk announcement the DAEMON has not reported, or NIL.

**When the daemon reports the operation, this yields to it** — a `filling` event is the
count and the name from the layer that owns them, and drawing an inferred line beside it
would be two bars for one operation. Everything below is the inference, and it is the
inference that has to be careful about what it claims.

Four things it is careful about, each measured on this session:

  · **the trigger is the announcement SHAPE, not a row without a body.** Letibot's
    `bodies_pending > 0` is true for the R2 window of every ordinary message, so its line
    comes up over and over for a carry that is not happening (*\"it literally appears over
    and over — carrying the conversation onto the new prompt\"*). Here the trigger is a
    snapshot that announced rows with no bodies (`note-carry`), which is what a bulk carry
    looks like on the wire. A prompt queued behind a running turn is a live
    `transcript_appended` and never enters this count.
  · **the sentence names no cause.** A reseat, a `/compact`, a resume and an attach all
    arrive as a snapshot of bodiless rows and the head cannot tell them apart, so it says
    what it knows. The named form is `filling`'s, and the daemon is the only layer that
    has it.
  · **a small batch draws no BAR** (`+carry-min-rows+`) — but it is still DIAGNOSED if it
    never lands, because that sentence is the only place a row the daemon announced and
    never sent is ever reported.
  · **past the patience it stops claiming to be progress** (`+body-patience-ms+`), and
    says what happened instead.

It disappears by itself the moment the last body lands. The stalled form is TWO rows and
not three, and that is the whole of the claim: the blank, and one quiet sentence. **The
live sentence must not be under it** — that sentence says rows are still coming, and a
head that says both is worse than the bar it replaced."
  (multiple-value-bind (total done) (%carry-counts (head-session head))
    (let ((outstanding (- total done)))
      (cond
        ;; **the daemon is counting this one**: its line, its numbers, its name.
        ;;
        ;; **DRAWN HERE, and it is a fix rather than a phrasing.** This branch used to
        ;; answer NIL, on the intent stated in this function's own docstring — *"when the
        ;; daemon reports the operation, this yields to it"* — with the yielding
        ;; implemented and the thing it yields TO not. `filling-progress-line` had exactly
        ;; ONE call site (the carry branch below) and was therefore unreachable for the
        ;; case it was written for. Measured on the glass during a real opencode import
        ;; (9,570 parts, the filling active at every sample from t=0 to t=8 s, 320 → 2,816
        ;; of 9,570): **the screen carried no count, no bar and no operation name**, while
        ;; the head asked the loop for a frame ten times a second (`live-frame-tenths-p`
        ;; includes `filling-active-p`) for a line it never drew. So the two halves of the
        ;; old sentence were both true and joined by nothing.
        ((filling-active-p)
         (filling-progress-line (getf *filling* :what) (getf *filling* :unit)
                                (getf *filling* :done) (getf *filling* :total)
                                cols (and (plusp *now-ms*) *now-ms*)))
        ((or (minusp outstanding) (zerop outstanding))
         ;; every row the announcement promised has arrived — or there is no carry at
         ;; all. Either way the line is done, and it forgets the carry it measured.
         (when *carry-outstanding* (reset-carry))
         (setf *carry-last-done* nil *carry-moved-at* nil)
         nil)
        (t
         ;; the clock, and the movement it measures: an unknown clock (a test, a replay)
         ;; can never be stalled, because a stall is a claim about time
         (let ((now (and (plusp *now-ms*) *now-ms*)))
           (when (and now (not (eql done *carry-last-done*)))
             (setf *carry-moved-at* now))
           (setf *carry-last-done* done)
           (cond
             ;; **PAST THE PATIENCE IT IS NOT PROGRESS ANY MORE**, whatever the size.
             ;; This is the only thing on the screen that will ever report a row the
             ;; daemon announced and never sent — a bodiless row draws NOTHING in the
             ;; transcript — and it is therefore NOT gated on the batch being big, nor on
             ;; an operation being named. The operator learned about a real daemon-side
             ;; hole from exactly here.
             ((and now *carry-moved-at*
                   (>= (- now *carry-moved-at*) +body-patience-ms+))
              (list nil
                    (list (cons (truncate-to-width
                                 (format nil "  ~d row~:p announced and never filled in — the ~
                                              daemon said they exist and did not send them"
                                         outstanding)
                                 cols)
                                '(:dim t)))))
             ;; **the threshold gates the BAR, not the sentence.** Three rows are not
             ;; worth a bar with a cat on it; they are still worth telling the truth
             ;; about if they never land, so the arm above comes FIRST and this one
             ;; leaves the movement clock ALONE. Clearing it here — the first version of
             ;; this did — means a small batch can never reach the patience arm at all,
             ;; because the clock it is measured against is reset on every frame: found
             ;; by the live probe, where a two-row batch that never landed drew nothing
             ;; rather than the sentence that is the whole reason the sentence exists.
             ((< total +carry-min-rows+) nil)
             (t (filling-progress-line nil "rows" done total cols now)))))))))

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
