;;;; alarm — the alarm line, and the stall it reports
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ----------------------------------------------------------- alarm line ;;;
;;;
;;; The counters that are not zero, in the attention role, and nothing else. The
;;; full list lives on the `/status` screen with a line under each saying what it
;;; means — reachable, which is the obligation, and not resident, which was never
;;; part of it.

(defparameter +read-edits-marker+ "reading + the edits — every change it made, and nothing else"
  "What the `:read-edits` rung calls itself.

**It must not say \"the conversation only\"**: this rung shows the head's changes on purpose, and a
marker that names the rung below it is the one sentence on the row that would be false.")

(defparameter +reading-marker+ "reading — the conversation only"
  "What the `:reading` rung calls itself on the screen, ONE string in ONE place.

**The name is letibot's to choose** (R37: *A names the rung because `Verbosity` is already
its ladder*), and it is filed with that ask. It is a constant rather than inline text so a
rename is one line here and one word there — nothing else in the head spells it.")

(defun alarm-line (head cols)
  "The alarm row, or NIL when there is nothing to say.

NIL rather than an empty line: a row that is always present is a row that costs
the transcript a line to say nothing.

**And it is the row that names the `:reading` rung while it is on** (R37: *the head says
which state it is in, because a reader who cannot tell will scroll to find out*). Three
things about that placement, and each is why it is here rather than on a row of its own:

  · **This row is already in the frame's budget.** It is drawn only when it has something
    to say, so the mode costs nothing on every other rung — which matters because the rung
    is opt-in and the layout must not change for the readers who never turn it on.
  · **It must not EXPIRE.** A note does (`+notice-ttl-ms+`), and a mode that stopped saying
    its own name four seconds after the keypress is a mode a reader can be inside without
    knowing — the same affordance failure R36 describes for scroll.
  · **It is joined to an alarm rather than replacing it.** Both facts fit on one row, and a
    rung that hid a real alarm while it was on would be the rung deciding what the operator
    should not see, which is the thing R37 forbids it to do with warnings.

The mode alone is DIM: it is a state, not a fault, and R19's whole rule is that red and
yellow are spent on something going wrong."
  (let ((counts (alarm-counts head))
        (reading (and (reading-p) (if (read-edits-p) +read-edits-marker+ +reading-marker+))))
    (cond
      ((not (head-connected head))
       (list (cons (format nil " ⚠ detached — retrying~@[ · ~a~]" reading)
                   '(:fg :red :bold t))))
      (counts
       (list (cons (format nil " ⚠ ~{~a ~a~^ · ~}~@[ · ~a~]"
                           (loop for (k . v) in counts append (list k v))
                           reading)
                   '(:fg :yellow))))
      (reading
       (list (cons (format nil " ~a" reading) '(:dim t))))
      (t nil))))

;;; ----------------------------------------------------------------- stall ;;;
;;;
;;; The head says when the DAEMON has gone quiet. `now_ms` and `last-event-at`
;;; are received-at, not the event's own `ts`: taking it from the event's clock
;;; would measure the daemon's opinion of how long it had been quiet, which is
;;; exactly the number that is missing when it has stopped talking.
;;;
;;; **`*stall-ms*` lives in `session.lisp`** — moved there the day the filling bar needed the
;;; same number. Two things ask the identical question (*has the daemon stopped talking to
;;; me?*) and one of them is folded in `session.lisp`, which loads before this file; a second
;;; spelling of the window here is how the stall sentence and the bar would come to disagree
;;; about what silence means. One number, one place, both callers.

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
            ;; BUSY, not the state name: the name reads "finished" for the whole of a tool call,
            ;; which is exactly when a long silence happens — so this line was silent for the one
            ;; case it exists for (the same defect `turn-busy-p` records, in its fifth place).
            (when (and turn (turn-busy-p turn))
              (format nil "~a — nothing received for ~a. The turn is still working; esc esc interrupts it."
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

(defun %completions-text (head)
  "The live `/command` matches as ONE STRING, or NIL — the completion row's content.

Split from `completions-line` so the two callers that want it differently can have it: the frame
draws it INSIDE the composer's box (`composer-ghost-row`), and `completions-line` is the standalone
row the tests and a non-boxed frame read. The text itself is spelled once, which is the rule the
counts' spelling follows for the same reason: two spellings of one thing come to disagree."
  (let ((text (composer-buffer (head-composer head))))
    (when (and (plusp (length text))
               (char= (char text 0) #\/)
               (not (find-if (lambda (c) (member c '(#\space #\tab #\newline))) text)))
      (let* ((needle (subseq text 1))
             ;; **the union of both owners**, so the row that is drawn under the composer
             ;; offers exactly what Tab will accept — a row listing fewer verbs than the key
             ;; takes is the same defect as one listing verbs nothing acts on.
             (parts (loop for (name . hint) in (%slash-completions head)
                          when (alexandria:starts-with-subseq needle name)
                            collect (format nil "/~a ~a" name hint))))
        (when parts
          (format nil "~{~a~^  ·  ~}" parts))))))

(defun composer-ghost-row (text cols)
  "TEXT — the live `/command` matches — as a row INSIDE the composer's box.

**This is where the ghost lives, and the operator moved it here:** *\"when i start typing a slash
command this grey help ghost appears above the area and the conversation is jumping again. I want
the ghost inside the input area.\"* The row used to be a CHROME row above the box, and a chrome row
costs the transcript one of its own — the viewport is bottom-anchored, so the whole conversation
shifted up a line every time the ghost appeared and back down when it went. The ghost is drawn in
the box's footprint instead, on the row the box's top edge vacates (see `%render`), so the frame's
total height and the transcript's rows are the same whether it is up or not.

The row is a body row of the box — `│` + a space + the continuation indent + the text + the pad +
`│` — built exactly like `%composer-body-rows` builds one, and DIM, which is the register the ghost
has always been in and the reason it reads as a ghost rather than as a message."
  (let* ((inner (composer-inner cols))
         (shown (truncate-to-width (or text "") inner)))
    (list (cons "│" '(:dim t))
          (cons " " nil)
          (cons "  " nil)
          (cons shown '(:dim t))
          (cons (make-string (max 0 (1+ (- inner (string-width shown))))
                             :initial-element #\space)
                nil)
          (cons "│" '(:dim t)))))

(defun completions-line (head cols)
  "The live `/command` matches as ONE dim row — the standalone form.

Tab has completed since the beginning (`src/editor.lisp:118`) and **nothing was
ever drawn**: `grep -rn completion src/*.lisp` found `%complete` and no renderer,
so the only way to learn what a prefix matched was to press Tab and watch the
buffer change under you. A bare `/` lists every verb; a prefix nothing matches
draws NOTHING rather than an empty row, because a row that appears and
disappears is noise, and Tab still says what went wrong when it is asked.

**The frame does not call this any more.** The row the frame draws is
`composer-ghost-row`'s, inside the box; this is the same text as a row of its own,
kept because it is a named contract surface (HACKING.md) and because
`the-completions-row-lists-what-tab-would-take` asks the CONTENT question here,
where the content is spelled once."
  (let ((text (%completions-text head)))
    (when text
      (list (list (cons (truncate-to-width (format nil "  ~a" text) cols)
                        '(:dim t)))))))

(defun stall-row (head cols)
  (let ((text (stall-text head)))
    (when text
      (list (list (cons (truncate-to-width text cols) '(:fg :yellow)))))))

