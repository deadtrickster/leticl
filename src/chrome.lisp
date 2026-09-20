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
  "The model this session is ACTUALLY on, best known first.

The wiring's model arrives on `Hello` and never changes; the turn's arrives on
`TurnStarted` and is the truth while (and after) a turn runs. Reading only the
wiring is what put `qwen-3.8-27b` on the header of a session running
`deepseek/deepseek-flash` — a number on screen that was wrong, which is the
defect class this head exists against.

Once the settings rows land (§7.4) the live `model` row is the third and best
source; until then the turn is the newest thing we have.

`SettingRow` carries the flag's own name in `key` and its rendered value in
`value` (protocol.rs:214) — `row(\"model\", …)` is emitted by the daemon
(config.rs:825), and `mode` beside it."
  (or (%model-from-settings)
      (let ((turn-model (getf (session-turn s) :model)))
        (and (stringp turn-model) (plusp (length turn-model)) turn-model))
      (let ((wire (getf (session-wiring s) :model)))
        (and (stringp wire) wire))
      ""))

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

(defun top-border (head cols)
  (let* ((s (head-session head))
         (title (if (plusp (length (session-title s)))
                    (session-title s) (session-session-id s)))
         (model (%model-name s))
         (left (format nil " leticl · ~a~@[ · ~a~] " title
                       (and (plusp (length model)) model)))
         ;; the meter rides beside the token count, because that is where the
         ;; question "what is this costing me" is already being asked
         (money (spent-text))
         (right (format nil "~@[~a · ~]seq ~a · ~d heads "
                        money (session-seq s) (length (session-heads s))))
         (pad (max 0 (- cols (string-width left) (string-width right)))))
    (list (cons left '(:bold t :fg :cyan))
          (cons (make-string pad :initial-element #\─) '(:fg :bright-black))
          (cons right '(:fg :bright-black)))))

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
         (style (if (head-connected head) '(:fg :bright-black) '(:fg :red :bold t))))
    (list (cons (%truncate-width text (max 1 (or cols 1)))
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:fg :bright-black)))))

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
      ((head-secret-req head) "enter submits · esc refuses the password")
      ((%open-decision head) "a row number answers · ↑↓ then enter · or type an option")
      (t "ctrl-s sessions · ctrl-p todos · ctrl-r thinking · tab completes · /help"))
    '(:fg :bright-black))))

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
  "The title on the box's top edge: what this session is, or nothing."
  (let ((s (head-session head)))
    (if (plusp (length (session-title s)))
        (format nil " ~a " (session-title s))
        " input ")))

(defun composer-wiring (head)
  "The right end of the box's bottom edge: what this session is talking to."
  (let* ((w (session-wiring (head-session head)))
         (model (%model-name (head-session head)))
         (dialect (getf w :dialect))
         (endpoint (getf w :endpoint))
         (parts (remove nil (list model dialect endpoint))))
    (if parts
        (format nil " ~{~a~^ · ~} " parts)
        " leticl ")))

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
    (list (cons "╭" '(:fg :bright-black))
          (cons name '(:bold t))
          (cons (make-string fill :initial-element #\─) '(:fg :bright-black))
          (cons "╮" '(:fg :bright-black)))))

(defun composer-box-bottom (head cols)
  "The box's bottom edge, with the wiring at its right end."
  (let* ((wiring (composer-wiring head))
         (w (max 1 (- cols 2)))          ; the two edges are one column each
         (name (%truncate-width wiring w))
         (fill (max 0 (- w (string-width name)))))
    (list (cons "╰" '(:fg :bright-black))
          (cons (make-string fill :initial-element #\─) '(:fg :bright-black))
          (cons name '(:fg :bright-black))
          (cons "╯" '(:fg :bright-black)))))

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
          collect (list (cons "│ " '(:fg :bright-black))
                        (cons "› " '(:fg :bright-cyan :bold t))
                        (cons shown nil)
                        (cons (make-string (max 0 (- inner (string-width shown)))
                                           :initial-element #\space) nil)
                        (cons " │" '(:fg :bright-black))))))

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
