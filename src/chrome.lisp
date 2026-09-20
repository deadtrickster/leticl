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
                   (cons "resync" *resyncs*))))

(defun alarmed-p (head)
  "Is anything wrong enough to spend a row on?"
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
rate nobody took, and it is the rule the meter and the footer are both held to."
  (let* ((turn (session-turn s))
         (state (and turn (getf turn :state)))
         (usage (or (and state (getf state :usage))
                    ;; a finished turn's usage is kept past the end of the turn,
                    ;; so the header still says what the conversation costs while
                    ;; nothing is running — which is most of the time
                    (and turn (getf turn :usage))))
         (timings (and state (getf state :timings)))
         (parts nil))
    (when (and usage (numberp (getf usage :prompt-tokens))
               (plusp (getf usage :prompt-tokens)))
      (push (format nil "~a ctx" (thousands (getf usage :prompt-tokens))) parts))
    (when (and usage (numberp (getf usage :cached-tokens))
               (numberp (getf usage :prompt-tokens))
               (plusp (getf usage :prompt-tokens)))
      (push (format nil "~d% cached"
                    (round (* 100 (/ (float (getf usage :cached-tokens))
                                     (getf usage :prompt-tokens)))))
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

(defparameter *stall-ms* 20000
  "How long a silence before the head says so. Long enough that a slow model
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

(defun stall-text ()
  (let ((ms (stalled-ms)))
    (when (and ms (>= ms *stall-ms*))
      (format nil " · no frames for ~a" (duration ms)))))

;;; --------------------------------------------------------------- status ;;;

(defun status-line (head cols)
  "The status row: the note, the connection, the scroll, the queue, the stall.

The counters moved to the ALARM line and to `/status`, which is the reference's
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

The reference's `hint_bar`, and its point is that the hint is per-context: a key
that closes a card is not the key that interrupts a turn, and a hint that names
the wrong key is worse than no hint at all. It is the first thing dropped on a
narrow screen."
  (declare (ignore cols))
  (list
   (cons
    (cond
      ((head-quit-open head) "1/2 or ↑↓ then enter · esc stays")
      ((eq (head-mode head) :help) "esc closes this")
      ((eq (head-mode head) :status) " esc closes this · every counter, and what it means")
      ((eq (head-mode head) :config) "arrows move · enter changes a row marked ✎ · esc closes")
      ((eq (head-mode head) :jobs) "↑↓ then enter reads one · esc closes")
      ((eq (head-mode head) :subagents) "↑↓ then enter peeks one · esc closes")
      ((eq (head-mode head) :todos) "↑↓ moves · enter or tab unfolds · esc closes")
      ((eq (head-mode head) :peek) "esc closes")
      ((eq (head-mode head) :picker) "↑↓ then enter switches · esc closes")
      ((eq (head-mode head) :mode-picker) "↑↓ then enter · esc closes")
      ((eq (head-mode head) :models-picker) "↑↓ then enter · esc closes")
      ((head-secret-req head) "enter submits · esc refuses the password")
      ((%open-decision head) "a row number answers · ↑↓ then enter · or type an option")
      ;; the ordinary line, in letibot's own order and wording — measured off
      ;; its screen: `enter send · ctrl+c exit` FIRST, because those are the two
      ;; keys a person needs before any chord, then the chords, then completion
      ;; and help last.
      (t "enter send · ctrl+c exit · ctrl-s sessions · ctrl-p todos · ctrl-g subagents · ctrl-r thinking · ctrl-t tool output · ctrl-q jobs · tab completes /commands · /help"))
    '(:dim t))))

;;; ---------------------------------------------------------- turn status ;;;
;;;
;;; Ported from `App::turn_status`. It rides the composer box's BOTTOM edge,
;;; beside the alarm triangle — which is why the reference has no separate status
;;; row: the box's edge is the status line when the box is there, and a plain row
;;; only when the screen is too short for a box.
;;;
;;; Two refusals, both measured in the reference's own comment:
;;;
;;;  · a turn out of a SNAPSHOT has no timestamps, so `now - 0` is an epoch
;;;    difference and the line read `Responding · 496940h16m`. Unmeasured means
;;;    *started before this head attached*, never a number nobody took;
;;;  · a zero count is a zero field wearing a measurement's clothes: nothing yet
;;;    is NO field, not `· 0 tok`.

(defun turn-status (head)
  "The running turn in a few words, or NIL when no turn is running."
  (let* ((turn (session-turn (head-session head)))
         (state (and turn (getf turn :state)))
         (running (and state (string= (getf (getf turn :state) :state) "running"))))
    (when running
      (let ((since (if *turn-started-ms*
                       (format nil " · ~a" (duration (- (internal-real-time-ms)
                                                        *turn-started-ms*)))
                       " · started before this head attached"))
            (tokens (getf turn :tokens))
            (spin (string (spinner *now-ms*))))
        (concatenate
         'string
         "Responding"
         (if (and (numberp tokens) (plusp tokens))
             (format nil " · ~a tok" (thousands tokens))
             ;; the character count where the server has not spoken, or a
             ;; messages-backend turn whose seam carries no token count
             (let ((chars (length (or (getf turn :text) ""))))
               (if (plusp chars) (format nil " · ~a chars" (thousands chars)) "")))
         since
         " · "
         spin)))))

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
        (format nil " ~d subagent~p running " running running)
        "")))

(defun composer-wiring (head)
  "The right-hand label of the box's BOTTOM edge: the alarm and the turn's status.

**Not the wiring** — same mistake as the title, same fix: the reference's bottom
edge is where the alarm triangle and the running turn's own status live, and the
wiring's model is in the header where it belongs.

An alarm is `⚠` alone, because the counters behind it are `/status`'s and were
never worth a resident sentence of bright yellow. With nothing running and nothing
wrong, the edge is bare."
  (let ((parts (remove nil (list (and (alarmed-p head) "⚠")
                                 (turn-status head)))))
    ;; NOTHING is nothing: returning a space put a stray `─ ╯` on the box where
    ;; letibot draws `──╯`. Same defect as `composer-title`'s, one function over —
    ;; and only a column-precise diff shows a one-column difference.
    (if parts
        (format nil " ~{~a~^ · ~} " parts)
        "")))

(defun %composer-rows (head cols)
  "How many rows the composer buffer renders to, wrapped at the box's inner width.

Takes HEAD rather than reaching for the global: the paint has `*head*` bound and
a TEST of the paint does not, and the difference is a render that dies with `NIL
is not of type LETICL::HEAD` — measured, twice, in this file. Anything here that
can be given the head is given it."
  (max 1 (ceiling (max 1 (string-width (composer-buffer (head-composer head))))
                  (max 1 (composer-inner cols)))))

(defun composer-inner (cols)
  "The columns of editable text inside the box.

The row is `│ ` (2) + `› ` (2) + text + ` │` (2) = COLS, so the text gets COLS-6.
It was COLS-4 and every body row rendered two columns wide — measured: a 60-column
frame drew a 62-column row, which wraps in a terminal and pushes the whole frame
down a line on every keystroke."
  (max 1 (- cols 6)))

(defun composer-box-top (head cols)
  "The box's top edge: `╭─ title ────╮`."
  (let* ((title (composer-title head))
         ;; the edges are one column each, so the fill and the title share COLS-2
         (w (max 1 (- cols 2)))
         (name (%truncate-width title w))
         (fill (max 0 (- w (string-width name)))))
    (list (cons "╭" '(:dim t))
          (cons name '(:bold t))
          (cons (make-string fill :initial-element #\─) '(:dim t))
          (cons "╮" '(:dim t)))))

(defun composer-box-bottom (head cols)
  "The box's bottom edge, with the wiring at its right end."
  (let* ((wiring (composer-wiring head))
         (w (max 1 (- cols 2)))          ; the two edges are one column each
         (name (%truncate-width wiring w))
         (fill (max 0 (- w (string-width name)))))
    (list (cons "╰" '(:dim t))
          (cons (make-string fill :initial-element #\─) '(:dim t))
          (cons name '(:dim t))
          (cons "╯" '(:dim t)))))

(defun composer-box-body (head cols)
  "The body rows of the box: `│ › text… │` per wrapped row."
  (let* ((c (head-composer head))
         (inner (composer-inner cols))
         (buf (composer-buffer c))
         (lines (if (zerop (length buf))
                    (list "")
                    (uiop:split-string buf :separator '(#\newline)))))
    (loop for line in lines
          for shown = (%truncate-width line inner)
          ;; the wall and the prompt are DIM, and the wall is its own segment with
          ;; a plain space after it — read off the two screens' escapes, which is
          ;; the only place the difference shows: ours was `ESC[2m│ ESC[0;1mESC[96m›`
          ;; against letibot's `ESC[2m│ESC[0m space ESC[2m›ESC[0m`.
          collect (list (cons "│" '(:dim t))
                        (cons " " nil)
                        (cons "› " '(:dim t))
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

(defun composer-line (head cols)
  "The composer, as the rows it occupies — box plus body, or one bare line.

Returns a LIST of rows, because the box is three or more rows tall; the caller
places them from the bottom up. A single-row list is the degraded form."
  (let ((inner (max 1 (- cols 2))))
    (if (< (head-rows head) 8)
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
                (composer-box-body head cols)
                (list (composer-box-bottom head cols))))))

(defun composer-rows-needed (head cols)
  "How many rows `composer-line` will return. The render needs this BEFORE it
component the frame, because the transcript gets what is left."
  (declare (ignore cols))
  (if (< (head-rows head) 8)
      1
      (+ 2 (%composer-rows head cols))))

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

(defun attaching-p (head)
  (and *attach-started-ms* (not (head-connected head))))

(defun attach-lines (head cols)
  "The wait, or NIL when there is nothing to wait for."
  (when (attaching-p head)
    (let* ((elapsed (max 0 (- (internal-real-time-ms) *attach-started-ms*)))
           (slot (format nil "~v@a" +cat-slot+ (cat-frame elapsed))))
      (list (list (cons "" nil))                 ; the caller centres vertically
            (%centred-row slot cols)
            (list (cons "" nil))
            (%centred-row "· · · · ›" cols)        ; a pawprint trail, so a still
            (list (cons "" nil))                   ; frame still reads as going
            (%centred-row "asking the daemon for this session" cols)
            (list (cons "" nil))
            (%centred-row (duration elapsed) cols)))))
