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

(defparameter +header-tail-slots+
  '((:position . 6) (:spent . 9) (:ctx . 11) (:cached . 11)
    (:rate . 10) (:elapsed . 5) (:out . 10))
  "How many columns each of the header's tail fields RESERVES, whether or not it has a value.

**A place found on the first render, so growth has nowhere to go but inside its own slot.** The
operator's axiom — *\"nothing must jump\"* — and their report of how it was being broken: *\"the top
right status part — where sessions counter and model lives. the problem here is the rate it seems.
So when a model responds that status thing changes length … again — rate comes and goes.\"*

Measured at 206 columns before this existed: the `1/87 · model` pair sat at column 176 on a head
that had measured nothing, at 140 mid-turn, at 123 with no rate, at 112 with one, at 111 once the
meter crossed ten dollars and at 114 once the context crossed a megabyte. **Sixty-four columns of
sliding**, on the two leftmost fields, for facts changing inside a single turn.

The tail is right-aligned, so every field to the LEFT of one that grows or appears moves by its whole
width. Fixed slots are the whole fix: the tail's total width is now a constant of the frame, so its
left edge cannot move and neither can anything in it.

**Widths are the formatter's own maxima**, in the display order, and the numbers are RIGHT-aligned
inside them so a value grows toward its slot's left edge rather than into its neighbour's. The
`:model` field is deliberately absent from this table — see `%header-tail`.

A `defparameter` and not a `defconstant`: the file pusher skips constants.")

(defun %header-slot (key)
  "KEY's reserved columns, or 0 for a field that keeps its natural width."
  (or (cdr (assoc key +header-tail-slots+)) 0))

(defun %header-tail (fields)
  "FIELDS — a list of `(KEY . TEXT-OR-NIL)`, in display order — as the header's right-hand tail,
**in slots that do not move** (R43).

NIL is a field nothing measured, and it **holds its place**: the slot is emitted as spaces. That is
the rule the marker's room is, one surface over — a number nobody measured is ABSENT and not zero,
and an absent number takes up no less room than a present one, because the room moving is the defect
and the number is not.

The separator belongs to the slot — ` · ` before a field that has something to say, three columns of
nothing before one that does not — so an absent field in the MIDDLE leaves a gap and no dot, and a
present field beside it still gets its own. That is a blank cell in a table, not a punctuation mark
about nothing.

**TRAILING absent fields are not emitted.** They are to the RIGHT of everything else, so dropping
them moves nothing — and the pad still charges their columns (`%header-tail-cols`), so the fields
that ARE drawn sit exactly where the reservation puts them either way. The row therefore ends with a
value, as every other row in this head does, and the segment it ends with is the tail's own.

**`:model` is the one field with no slot**, and it is a boundary rather than an oversight: every
other field is a MEASUREMENT, which changes inside a turn, where the model name is a fact about the
session that changes only when somebody switches provider. Reserving the width of the longest model
name anyone might use would cost every short one a gap for a jump that only a deliberate act causes."
  (let* ((last-present (position-if #'cdr (reverse fields)))
         (shown (if last-present (- (length fields) last-present) 0))
         (out (make-string-output-stream))
         (first t))
    (dolist (f (subseq fields 0 shown) (get-output-stream-string out))
      (let* ((key (car f))
             (text (cdr f))
             (slot (%header-slot key))
             (present (and text (plusp (length text)))))
        (unless first
          (write-string (if present " · " "   ") out))
        (when present
          (let* ((text (if (and (plusp slot) (> (string-width text) slot))
                           (truncate-to-width text slot)
                           text))
                 (w (if (plusp slot) slot (string-width text)))
                 (pad (max 0 (- w (string-width text)))))
            (when (plusp pad) (write-string (make-string pad :initial-element #\space) out))
            (write-string text out)))
        (when (and (not present) (plusp slot))
          (write-string (make-string slot :initial-element #\space) out))
        (setf first nil)))))

(defun %header-tail-cols (fields)
  "How many columns the tail RESERVES for FIELDS — every field present, at its slot's width.

The number the pad and the workspace's room are both computed from, so the tail's left edge is a
function of the frame and not of what happens to have been measured when the frame is drawn.

**Not `%header-tail`'s own width**, because that one drops trailing absent fields and this one must
charge for them: the fields that ARE drawn have to land where the reservation puts them, and those
columns have to come from somewhere. This is the `NIL`-holds-its-place rule stated as arithmetic
rather than as rendering."
  (loop for f in fields
        for i from 0
        sum (+ (if (zerop i) 0 3)
               (let* ((slot (%header-slot (car f)))
                      (text (cdr f)))
                 (if (plusp slot) slot (string-width (or text "")))))))

(defun %header-tail-natural (fields)
  "FIELDS with NO slots — each value at its own width, absent fields omitted.

The reference's own tail, and the form the header falls back to on a frame too narrow to afford the
reservation. Used for the drop decision in that mode, so the ladder is measuring the row it is
going to draw."
  (format nil "~{~a~^ · ~}"
          (loop for f in fields when (cdr f) collect (cdr f))))

;;; -------------------------------------------------------------- counters ;;;
;;;
;;; The head's own instrumentation. Every counter here was added because
;;; something was measured going wrong, and each one lives on the status line
;;; only when it is NOT ZERO — a number that is zero costs a row of attention
;;; for ever in exchange for being noticed once. The alarm line below carries
;;; the rest.

(defvar *frozen* nil
  "Is the VIEW held — the reader's selection safe — until `ctrl-p` releases it?

**`ctrl-p` and not `ctrl-f`:** the operator's first pick was `ctrl-f` and it is taken — the
composer's emacs motions bind it, and `the-emacs-motions-the-reference-decodes-are-bound` caught it
the moment this was `#\f`. `ctrl-p` is free because the todos pane gave it up when that moved to
`ctrl-t`, and *pause* is the better mnemonic for a chord that stops the screen moving.

**The operator's own diagnosis, and it is exact:** *\"leticl resets selection if screen wasnt scrolled
    too. so both should not do it if anything selected. whether it means stopping render and showing me
'new content' marker - likely.\"* MEASURED on both heads with `tmux pipe-pane`: leticl erased NOTHING
(0 x `ESC[2J`, 0 x `ESC[K` in a twenty-two minute turn) and still lost the selection — **any write into
a selected cell clears it**, so erasing is not the trigger and there is no gentler way to paint.

**And the head CANNOT detect the selection.** With mouse reporting on, holding Shift tells the
TERMINAL to do its own selection and not to forward the events — which is why Shift is the gesture —
so the head never sees the press, the drag or the release, and there is no query. *Do not repaint
while something is selected* is therefore not implementable as written: there is nothing to test. The
reader is the only party who knows a selection exists, so the reader is who holds the view.

**What the freeze owes the screen is NOTHING.** One written cell is one lost selection, so while this
is true the head writes nothing at all — not a spinner, not a clock, not a counter that ticks — which
is why `paint-wanted-p` is the one place that reads it and why the clock's frames are silenced with
the events'. A frozen head that still animated is a frozen head that does not work.

The one exception is the frame the freeze itself owes (`*frozen-frame*`): the row saying the view is
held cannot appear without a write, and it is drawn ONCE, at the moment of freezing.")

(defvar *frozen-items* 0
  "How many rows the session held when the view was frozen — the other half of what the release says.

**Not a live count.** A number that moves is an animation, and an animation is writes; the count of
what arrived is computed ONCE, when the reader takes the view back, and is said then.  A `defvar` and
not a head slot, for the reason every counter here is one: a struct change is a restart.")

(defvar *frozen-frame* nil
  "Does a held view owe exactly one frame — the one that draws the marker saying so?

**A one-shot, and it exists because *write nothing* and *say that the view is held* cannot both be
true without it.** The marker cannot be drawn without a write, and it cannot be drawn while nothing
writes, so the freeze owes ONE frame and `%render-and-paint` is what spends it. `paint-wanted-p`
reads this FIRST, before the freeze silences everything else.")

(defun frozen-lines (head cols)
  "The row that says the view is HELD — identical in every frame, which is the whole point.

It is drawn ONCE (the freeze's owed frame) and then never again, because nothing after it writes: the
row is the same row in every frame the reader would have got, so there is nothing to redraw. It names
the chord that releases the view, for R29's reason — a state with no way out of it is a state the
reader is in whether they meant to be or not.

**No count.** The number of rows that arrived is what the RELEASE says, and only then: a live count
here would be an animation, and an animation is writes. `cols` truncates, so a narrow frame cuts the
sentence rather than wrapping it into the transcript's last row."
  (declare (ignore head))
  (when *frozen*
    (list (list (cons (truncate-to-width "⏸ the view is held — ctrl-p follows again" cols)
                      '(:dim t)))
          ;; and its own air, like every other tail part
          nil)))

(defun %toggle-freeze (head)
  "The ONE writer of `*frozen*`, and the only place the release's sentence is composed.

Freezing takes the row count with it and owes one frame (see `*frozen-frame*`). Releasing says what
happened while the view was held — *N rows arrived* — because the reader who looked away for a minute
wants to know how far the conversation moved, and that is a number that can be computed at the one
moment it is allowed to be said."
  (if *frozen*
      (let ((arrived (max 0 (- (length (session-items (head-session head))) *frozen-items*))))
        (setf *frozen* nil)
        (say head (format nil "the view follows again — ~d row~:p arrived while it was held" arrived))
        (setf (head-dirty head) t))
      (setf *frozen* t
            *frozen-items* (length (session-items (head-session head)))
            *frozen-frame* t))
  t)

(defvar *lf-note-said* nil
  "Has the head already explained that LF is `ctrl-j` now — said ONCE, and for a reason.

**The bytes cannot be told apart, so the SITUATION is what gets read.** `keys.lisp` no longer
collapses LF onto Enter (the operator freed it for the jobs pane), which means a terminal path that
delivers a bare LF for Return now opens the jobs pane where the reader meant to submit. There is no
way to distinguish that from a reader pressing Ctrl-J on purpose — they are the same byte — but there
IS a way to notice the moment it matters: LF arriving while the composer HOLDS TEXT is a submit that
did not happen far more often than it is somebody checking jobs mid-sentence. So the head says so,
once, in its own voice. A mystery turned into a message, the same move `no-daemon` and the
host-library refusal make: the reading that could be wrong is at least on the screen where the
reader can correct it. A `defvar` because it is running state, and ONE flag for the life of the
process because a note that repeats is a note nobody reads (R29).")

(defvar *alarms-acked* nil
  "`(LABEL . VALUE)` for every counter the reader has ACKNOWLEDGED at that value.

**The alarm is a POINTER, and a pointer that cannot be dismissed is one you learn to ignore.**
`⚠` on the composer's edge means *the head is alive and something was wrong — look at `/status`*;
its job is finished the moment the reader has looked, and until now nothing could say so. The
counters are cumulative and start at zero when the process does, so a head that took two resyncs
(an upgrade, a reattach) carried the triangle for the rest of its life while saying nothing new.
The operator: *\"how to hide that resync counter arrow?\"*

**Opening `/status` is the acknowledgement** — no key, no verb, no second thing to learn. That is
the whole interface: you looked. It is the `/notes` retire pattern with one difference and it is
the important one: **retiring silences a warning forever, and this silences a counter only UP TO
THE VALUE THAT WAS SEEN.** A resync after this one is a new fact and the triangle comes back —
which is what makes acknowledging safe rather than a way to switch the alarm off.

**The record is the unacknowledged state**, so it is a `defvar` like the counters it quiets, and
bound by `with-replay-globals` for the usual reason: a replay must answer the same bytes twice.")

(defun alarm-acked-p (label value)
  "Has LABEL been acknowledged at or beyond VALUE?"
  (let ((at (cdr (assoc label *alarms-acked* :test #'string=))))
    (and at (<= value at))))

(defun acknowledge-alarms (head)
  "Acknowledge every alarm counter at the value it holds now. T when anything changed.

Called when `/status` opens — see `*alarms-acked*` for the argument. **The whole set is taken at
once**, deliberately: a reader who has looked at the screen has seen every number on it, and
acknowledging only the one they scrolled to would be a decision the screen does not ask them to
make."
  (let ((changed nil))
    (dolist (pair (alarm-counts head))
      (unless (alarm-acked-p (car pair) (cdr pair))
        (let ((cell (assoc (car pair) *alarms-acked* :test #'string=)))
          (if cell
              (setf (cdr cell) (cdr pair))
              (push (cons (car pair) (cdr pair)) *alarms-acked*))
          (setf changed t))))
    (when changed (setf (head-dirty head) t))
    changed))

(defun alarm-counts (head)
  "The counters that are not zero **and not acknowledged**, as an alist of (LABEL . VALUE).

A defvar each rather than a head slot, because a struct layout change is a
restart; there is one head per process, so a global costs nothing and pushes.

**The acknowledgement filter is HERE and not at the two callers**, so the row and the triangle
cannot disagree about what has been read — the same rule the counts' own spelling keeps. What it
filters on is `*alarms-acked*`: a counter at or below the value the reader last saw on `/status`
is one they have read, and a counter ABOVE it is news again. **`/status` reads the raw globals and
not this**, which is what keeps the numbers on the screen after the triangle goes: off the edge
and still in the log, exactly as a retired note is."
  (remove-if (lambda (pair) (or (zerop (cdr pair))
                                (alarm-acked-p (car pair) (cdr pair))))
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
                   ;; **`routine` counts the WEATHER the head was told and did not draw** — the
                   ;; operator's ruling that `model_slow_first_byte` belongs on the `⚠` rather than
                   ;; in the conversation. A counter rather than a sentence for the reason the other
                   ;; four are: the edge can afford a word and `/notes` holds the sentence.
                   (cons "routine" *weather-notes*)
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

