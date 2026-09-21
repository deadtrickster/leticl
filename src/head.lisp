;;;; head.lisp — the running head: the struct, the threads, the paint-on-dirty
;;;; loop, frame handling, reconnect, lifecycle.
;;;;
;;;; The rest of the head is a runtime call away, in files that are disjoint so
;;;; more than one of them can be worked on at once: key ownership and the
;;;; composer in `editor.lisp`, the slash commands in `commands.lisp`, and how
;;;; state becomes cells in `render.lisp` (the frame engine), `cards.lisp`
;;;; (rows and cards), `chrome.lisp` (border/status/composer) and `panes.lisp`
;;;; (the full-body screens).
;;;;
;;;; The loop paints only when dirty, and acks after painting, never on receipt
;;;; (cursor.rs). Nothing here that holds RUNNING state may be a defparameter —
;;;; a live push would re-initialise it mid-session (HACKING.md, "Live state
;;;; must be defvar").

(in-package #:leticl)

;; the reader interns sb-concurrency symbols in the defstruct below, so the
;; module must be present at compile time, not just at load
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-concurrency))

;; defvar, not defparameter: these hold the RUNNING head's live state, and
;; `tui-eval --file src/head.lisp` re-evaluates this file in a live image at
;; load time. defparameter assigns unconditionally, so a live push would set
;; *stdout* to nil in a head that was mid-session — measured: every paint
;; afterwards wrote nowhere and tore the operator's screen. defvar assigns only
;; when unbound, which is the meaning these need.
(defvar *head* nil
  "The running head — the root a hack-socket eval reaches.")

(defvar *stdout* nil
  "The head's own stream on fd 1, bound in run. Declared here, before anything
paints to it, and defvar for the same reason as *head*.")

(defvar *replaying* nil
  "T while `--replay` is folding a recorded log instead of reading a socket.

One thing in the loop asks about the socket rather than about the head: an
unconnected head is a DETACHED head, and the loop re-attaches it every two
seconds. A replay is unconnected on purpose and for ever, so without this the
reconnect timer fires under every paced frame and the status line fills with a
socket nobody asked for. Declared here because `run-loop` is here; everything
else a replay needs is in `src/replay.lisp`, which loads last so it can name the
globals a frame reads.")

(defstruct (head (:constructor %make-head))
  (session (make-session))
  (stream nil)
  (cols 80 :type fixnum)
  (rows 24 :type fixnum)
  (screen (make-screen 80 24))
  (prev-screen (make-screen 80 24))
  (dirty t :type boolean)
  (full-repaint t :type boolean)
  (last-rows nil)                        ; strings with ANSI — Screen answers, /cells
  (last-cols 0 :type fixnum)
  (last-rows-n 0 :type fixnum)
  (scroll 0 :type fixnum)
  (composer (make-composer))
  (mode :normal :type symbol)            ; :normal :picker :help :status :config :jobs :subagents :peek :job-out :todos :slash
  (picker-sel 0 :type fixnum)
  (decision-sel 0 :type fixnum)
  (secret-req nil)
  (secret-buf "" :type string)
  (peeked nil)
  (settings nil)
  (jobs nil)
  (subagents nil)
  (prefs (list :show-reasoning nil :show-tools nil :diff "split"))
  (status-note nil)
  ;; **THE CLOCK BELONGS TO THE NOTE IT AGES.** A wall-clock millisecond after
  ;; which `status-note` stops being news; 0 means no clock is running. It was a
  ;; global special counting FRAMES, and it came apart from the note in the field:
  ;; see `tick-notice`.
  (notice-until 0 :type integer)
  (queued nil :type list)                ; prompts sent, user row not yet seen
  (connected nil :type boolean)
  (frames (sb-concurrency:make-mailbox :name "leticl frames"))
  (keys (sb-concurrency:make-mailbox :name "leticl keys"))
  (reader nil) (input nil) (hack-listener nil) (hack-thread nil)
  (hack-path nil)
  (running t :type boolean)
  ;; `screen_requested` ids waiting for a frame. The answer is the rows this
  ;; head DRAWS, and they do not exist until the frame is built, so the id is
  ;; queued here and the loop answers after the paint (app.rs:2723-2732).
  (screen-reqs nil :type list)
  ;; a `new_session` this head asked for: the `Sessions` reply that carries
  ;; `created` is then ours to act on rather than merely announce (app.rs:1739)
  (want-new nil :type boolean)
  (last-reconnect 0 :type fixnum)
  (socket-path nil)
  ;; why the daemon ended it, printed after the terminal is restored. NOT a
  ;; defvar: it is the one piece of state `run` must read after the loop has
  ;; gone, and it belongs to the head that was told.
  (farewell nil)
  (quit-open nil :type boolean)
  (quit-sel 0 :type fixnum))

;;; ---------------------------------------------------------------- io ;;;
(defun %send (head frame)
  "Main thread only — the writer is single-threaded by construction."
  ;; ONE PLACE remembers that this head asked for a session. The daemon answers
  ;; a `NewSession` with a `Sessions` frame carrying `created`, and whether that
  ;; id is somewhere to GO or merely something to announce depends on who asked
  ;; — which only the sender knows. Noted here so `/new` from the composer and
  ;; `--new TITLE` from the launcher cannot disagree about it.
  (when (and (%frame-plist-p frame) (string= (frame-name frame) "new_session"))
    (setf (head-want-new head) t))
  (when (and (head-stream head) (head-connected head))
    (handler-case
        (write-frame (encode-frame frame) (head-stream head))
      (error (e)
        (setf (head-connected head) nil)
        (say head (format nil "send failed: ~a" e))))))

(defun %reader-loop (head)
  "Socket → frames mailbox. EOF is detach, never abort (§13.2).

**Every frame carries the line it arrived as**, under `:wire-line`. Not a copy: it
is the string `read-frame` just returned, which the frame now keeps alive until it
is folded and which is therefore free — one cons. It is here because a frame this
head cannot read is only evidence if the operator can see the bytes, and the two
places that meet one (an unknown frame tag, an unknown event tag) are downstream of
the decode that would otherwise have dropped the line on the floor."
  (loop
    (handler-case
        (multiple-value-bind (line eof) (read-frame (head-stream head))
          (cond (eof
                 (sb-concurrency:send-message (head-frames head) '(:disconnected))
                 (return))
                (t
                 (handler-case
                     (sb-concurrency:send-message
                      (head-frames head)
                      (list* :wire-line line (decode-frame line)))
                   ;; **A line this head cannot read is a FRAME, not a socket.** The
                   ;; reader used to turn this into a `warning` with code
                   ;; `malformed-frame`, which the head drew as a status note: one
                   ;; line above the composer, gone on the next frame's TTL, and
                   ;; counted nowhere. It is handed on as the same head-internal
                   ;; marker the two unknown-tag sites use, so all three describe
                   ;; themselves once, in the conversation, and in one counter.
                   (wire-error (e)
                     (sb-concurrency:send-message
                      (head-frames head)
                      (list :unreadable t
                            :detail (format nil "~a" (wire-error-detail e))
                            :line (wire-error-line e))))))))
      (error (e)
        (sb-concurrency:send-message (head-frames head) '(:disconnected))
        (sb-concurrency:send-message
         (head-frames head)
         (list :frame "warning" :code "read-error" :detail (format nil "~a" e)))
        (return)))))

(defvar *skew-said-pending* nil
  "The skew sentence the `Hello` being folded produced, held until the snapshot is
in. `ingest-snapshot` replaces the session's items wholesale, so a row filed before
it is not \"anchored at the frame that revealed this\", it is thrown away.")

(defvar *skew-last-said* nil
  "The last skew sentence this head filed, so a `Switch`'s second `Hello` on the same
connection does not file a second identical row.")

(defvar *filtered-total* 0
  "Events this head consumed and did not draw, over its life — what `/verbosity`
reports beside the level, so \"terse\" is a number and not a mood.")

(defvar *rendered-total* 0
  "Events this head consumed and DID draw, over its life — the other half of the
ack's accounting, which `/status` shows as `seq · N rendered` the way the
reference does. Counted by this head, not by the daemon.")

(defun %input-loop (head)
  "Terminal → keys mailbox."
  (let ((in (sb-sys:make-fd-stream 0 :input t :element-type 'character
                                   :external-format :utf-8 :buffering :none)))
    (loop
      (let ((key (read-key in)))
        (sb-concurrency:send-message (head-keys head) key)
        (when (eq (getf key :type) :eof) (return))))))

;;; ------------------------------------------------------------ frames ;;;

(defun %frame-plist-p (x)
  "T when X is a decoded frame: a plist with a `:frame` key.

THE guard, in one place. `:disconnected` is a one-element list the reader pushes
to signal a dead socket, and any code that assumes `consp` means `plist` will call
`getf` on it and die in the main thread — which is a head that will not start."
  (and (consp x) (keywordp (car x)) (evenp (length x)) (getf x :frame)))

(defun %retire-pending (head text)
  "Stand down the echo of the queued prompt whose row has landed, by TEXT.

The transcript takes the words over by BEING them, so the exact match is the
rule and one row retires one entry — two prompts that say the same thing stay
queued separately until each of their rows lands. One refinement, the
reference's (`app.rs:4685-4703`): behind a running turn the operator's
consecutive messages are merged by the engine into ONE, so a landing row may be
the front PIECE of a coalesced echo; a row that is such a prefix strips itself
off and the rest stays queued until its own row lands.

The list is newest-first (`commands.lisp` pushes), and the match walks it
OLDEST-first, because the row that lands first is the prompt that was sent
first."
  (let* ((oldest (reverse (head-queued head)))
         (at (position text oldest :test #'equal))
         (prefix (concatenate 'string text (string #\newline)))
         (part (and (null at)
                    (position-if (lambda (p) (uiop:string-prefix-p prefix p)) oldest))))
    (cond
      (at (setf (head-queued head)
                (reverse (append (subseq oldest 0 at) (subseq oldest (1+ at))))
                (head-dirty head) t))
      (part
       (let ((rest (subseq (nth part oldest) (length prefix))))
         (setf (head-queued head)
               (reverse (append (subseq oldest 0 part)
                                (when (plusp (length rest)) (list rest))
                                (subseq oldest (1+ part))))
               (head-dirty head) t))))))

;;;
;;; `%handle-frame` returns a DISPOSITION, which is what the ack counts
;;; (driver.rs:31 classifies each frame the same three ways):
;;;
;;;   :rendered  something visible changed
;;;   :filtered  consumed, nothing to draw (a head at terse renders little and
;;;              must still advance, or it rereads its own output forever)
;;;   :control   not session content: hello, ack-of-our-own, settings, bye
;;;
;;; The ack itself is sent by the loop, after painting, from the last seq READ
;;; — never from this function, which does not know whether the frame went out.
(defun %handle-frame (head frame)
  (cond
    ((and (consp frame) (eq (car frame) :disconnected))
     (setf (head-connected head) nil)
     (say head "detached — reconnecting…")
     ;; **A DAEMON OLDER THAN `read_job_output` DROPS THE SOCKET, and this is the
     ;; only place that can say so.**
     ;;
     ;; `ClientFrame` is an internally-tagged serde enum, so an unknown `frame`
     ;; value does not fail one frame — it fails the DESERIALIZER, which ends the
     ;; daemon's read loop and closes the connection. This head has already been
     ;; bitten by that exact class: `consented: null` on `/mode NAME` broke the
     ;; read loop the same way, and the whole symptom was a head that went quiet
     ;; (tests: `a-boolean-field-goes-out-as-a-boolean`).
     ;;
     ;; There is deliberately NO version negotiation invented here — the server
     ;; side landed without a `PROTOCOL_VERSION` bump, so the version cannot tell
     ;; us and a handshake this head made up would be a second, private protocol.
     ;; What is chosen instead is HONESTY: the reconnect path below already brings
     ;; the head back, and the one thing it could not do was say why it went. A
     ;; read that was in flight when the socket died is named — by frame, and with
     ;; the verb that still works on an old daemon — in the overlay that asked and
     ;; on the status line, so the operator is never left with a pane at `reading…`
     ;; and a head that looks merely slow.
     (when (and *job-out* (getf *job-out* :loading))
       (setf (getf *job-out* :loading) nil
             (getf *job-out* :error)
             (format nil "the daemon closed the connection on `read_job_output`.~2%~
                          That frame is newer than this daemon: an unknown frame ~
                          fails serde's whole read loop rather than one message, ~
                          so the socket goes with it. Reconnecting — until the ~
                          daemon is updated, `/job ~a` in the composer still ~
                          reads this job, into the conversation."
                     (getf *job-out* :job)))
       (say head
            "read_job_output: the daemon closed the connection — it is older than this frame; reconnecting"))
     :control)
    ((and (consp frame) (eq (car frame) :unreadable))
     ;; **A FRAME THIS HEAD CANNOT READ: said, counted, survived.** The marker is
     ;; head-internal — the reader loop makes one for a line that will not decode —
     ;; and the two unknown-tag arms below reach the same function directly. It is
     ;; NOT a status note and NOT `:filtered`: nothing was parsed, so there is no seq
     ;; to ack, and `filtered` is "events I chose not to show", which the daemon reads
     ;; back. See `note-unreadable`.
     (note-unreadable (head-session head)
                      (or (getf frame :detail) "no detail")
                      (getf frame :line))
     (setf (head-dirty head) t)
     :control)
    ((and (consp frame) (string= (frame-name frame) "warning")
          (getf frame :code) (member (getf frame :code)
                                     '("read-error")
                                     :test #'string=))
     ;; our own transport warnings, not session events. **`malformed-frame` is no
     ;; longer one of them**: a line that would not decode is a frame this head could
     ;; not read, and it goes through `note-unreadable` with the rest.
     (say head (format nil "~a: ~a" (getf frame :code) (getf frame :detail)))
     :control)
    ((string= (frame-name frame) "hello")
     ;; **THE VERSION, BEFORE ANYTHING ELSE — AND THE HEAD STAYS.**
     ;;
     ;; A daemon that speaks a different protocol refuses with a `Bye` and no `Hello`
     ;; (server.rs:332-342), so a skew normally arrives the other way round — but this
     ;; check is the head's OWN, and it is not redundant, because **the two halves are
     ;; built and run separately**: a check is a thing a protocol GAINS at some
     ;; version, so a daemon older than the check has none, and a check is a candidate
     ;; for being relaxed — which is the direction `R3` itself argues for.
     ;;
     ;; **It used to EXIT**, with the sentence on a status note: `head-running` nil on
     ;; a version the daemon had merely disagreed about, which took the session with it
     ;; and said so in a place that expires. That is the failure framing the fix, on
     ;; the same argument `note-unreadable` is built on — a head that quits at the
     ;; handshake never gets to use the survival the rest of the protocol is for, and
     ;; the operator loses the conversation over a number.
     ;;
     ;; The sentence NAMES THE DIRECTION and the two directions are different
     ;; problems: a NEWER daemon is a reading problem (`R3`: the frames the two share
     ;; read fine, the first one they do not is reported and skipped), and an OLDER
     ;; daemon is a WRITING problem this head cannot survive from its side, because a
     ;; `ClientFrame` it has never heard of fails ITS deserialiser and its read loop
     ;; answers by closing the socket — silent until fatal, which is the case the
     ;; operator is entitled to know about before they spend an hour in it.
     ;; `protocol-skew-said` is the one place that sentence is built, beside the
     ;; number it is about, so every head says it the same way.
     (let* ((theirs (getf frame :protocol-version))
            (said (protocol-skew-said theirs +protocol-version+)))
       (setf *daemon-protocol* (and (integerp theirs) theirs))
       ;; held until the snapshot is folded in: `ingest-snapshot` replaces the
       ;; session's items wholesale, so a row filed before it is not "anchored at
       ;; the frame that revealed this", it is thrown away. Found by the test that
       ;; asserts the sentence exists, which is the only reason this is not a
       ;; silence nobody would have noticed.
       (setf *skew-said-pending* said))
     ;; A Switch lands as a Hello on the new session, and the money meter is the
     ;; CONVERSATION's — carrying one session's bill onto another's header is
     ;; wrong in the direction that costs money. Cleared, not guessed.
     (reset-spent)
     ;; the wait is over: the cat stands down
     (setf *attach-started-ms* nil)
     ;; THE HEAD'S OWN session-scoped state goes with the session, the way
     ;; `ingest-snapshot` drops the session's (app.rs:1902-1934). These four are
     ;; not in any snapshot and nothing cleared them, so a `/switch` carried the
     ;; old session's job rows, its peeked scrollback and the echo of prompts
     ;; queued in a conversation that is no longer on the screen.
     (let ((moved (and (plusp (length (session-session-id (head-session head))))
                       (not (equal (session-session-id (head-session head))
                                   (getf frame :session-id))))))
       (when moved
         (setf (head-jobs head) nil
               (head-peeked head) nil
               (head-queued head) nil
               (head-picker-sel head) 0)
         ;; and the overlays, for the reason the job ROWS are cleared: a window
         ;; belongs to the session that produced it, so a `j12` carried across a
         ;; switch is a question about a job that was never here — and a slash
         ;; listing carried across one is another session's `/tools` on this
         ;; screen, which is worse, because it looks like an answer to something
         ;; nobody asked here.
         (shut-overlays)
         (when (member (head-mode head) '(:job-out :slash))
           (setf (head-mode head) :normal))))
     (ingest-hello (head-session head) frame)
     (progn
       (setf (head-connected head) t
             (head-full-repaint head) t
             (head-dirty head) t)
       (clear-note head))
     ;; A `Switch` lands as a Hello on the new session, so asking here covers
     ;; attach AND switch with one send (§7.4). Without it the header keeps the
     ;; old session's model, and the rows a picker would read are another
     ;; session's.
     (%send head (make-settings))
     ;; **Now it can be said.** A row in the conversation, not a status note: the
     ;; fact is about the connection and outlives the next keystroke, and a note
     ;; that expires would make a version skew disappear silently — the same
     ;; argument `note-unreadable` is built on. Said ONCE per distinct sentence,
     ;; because a `Switch` lands as a second `Hello` on the same connection and
     ;; three Hellos must not be three identical rows (the reference dedupes its
     ;; notes on `(code, detail, ts)` for exactly this).
     (when (and *skew-said-pending*
                (not (equal *skew-said-pending* *skew-last-said*)))
       (note-protocol-skew (head-session head) *skew-said-pending*)
       (setf *skew-last-said* *skew-said-pending*
             (head-dirty head) t))
     (setf *skew-said-pending* nil)
     :control)
    ((string= (frame-name frame) "event")
     (let* ((env frame)
            (name (event-name env)))
       ;; the two events a head answers rather than renders
       (case name
         ((:screen-requested)
          ;; QUEUED, NOT ANSWERED HERE. The answer is the rows this head draws,
          ;; and they do not exist until the frame is built: answering from
          ;; `head-last-rows` during the drain sends the PREVIOUS frame, which
          ;; is a lie about the one frame in the system whose whole point is
          ;; what the operator is looking at right now. At 30 ms a tick that is
          ;; usually harmless and at a resize or a pane change it is wrong. The
          ;; loop answers after the paint, with what it put on the terminal
          ;; (driver.rs:93-99, app.rs:2723-2732).
          (push (getf env :req-id) (head-screen-reqs head))
          (setf (head-dirty head) t))
         ((:secret-requested)
          ;; the deadline is converted ON ARRIVAL, like the gate's: the wire's
          ;; `deadline` is a Unix instant and this head's clock is not one
          (setf (head-secret-req head)
                (list* :deadline (wire-deadline->monotonic (getf env :deadline)) env)
                (head-secret-buf head) ""
                (head-dirty head) t))
         ((:secret-settled)
          ;; SOMEBODY ELSE ANSWERED. Without this the masked field stayed up
          ;; over a `sudo` that was already through, and the daemon's own
          ;; `secret_late` warning — which would have explained it — is a
          ;; `Warning`, which this head does not draw either (app.rs:2750-2765).
          ;; Only OUR ask is dismissed: a settlement for another req_id is
          ;; another question, and closing this one on it would drop the
          ;; operator's keystrokes on the floor.
          (when (and (head-secret-req head)
                     (equal (getf (head-secret-req head) :req-id)
                            (getf env :req-id)))
            (progn
              (setf (head-secret-req head) nil
                    (head-secret-buf head) "")
              (say head (if (getf env :given)
                            (format nil "password given by ~a" (getf env :by))
                            (format nil "no password given (~a)" (getf env :by)))))))
         ((:decision-requested)
          ;; **A FRESH QUESTION STARTS AT THE TOP OF ITS LADDER.**
          ;;
          ;; The reference's own reason (app.rs:2597-2600): *"the highlight must
          ;; never be somewhere the operator did not put it when Enter is one key
          ;; away"*. This head never reset it — `endp-open` in `session.lisp` was
          ;; called here and did NOTHING (`(declare (ignore open-decisions))`), and
          ;; the slot was zeroed only AFTER an answer went out
          ;; (`editor.lisp`'s two `%answer-decision` paths). So an ask inherited
          ;; the cursor of the last one, and with the no-match arm answering the
          ;; marked row, a typed line that named nothing was answered at a row the
          ;; operator had selected for a decision already dealt with.
          ;;
          ;; It lives HERE and not in `session.lisp` because the cursor is HEAD
          ;; state: the session cannot reach a head slot, which is why the hook
          ;; there could never have done it.
          ;;
          ;; **AND ONLY A FRESH ONE STARTS THERE.** The reset is guarded on the
          ;; `req_id`, because a reconnect replays from the read mark and delivers
          ;; an ask this head has already drawn — the same question a second time.
          ;; Zeroing on that undid the operator's keystroke: measured on the live
          ;; head, `down` left the cursor at 1 and a redelivery of the same
          ;; `req_id` put it back to 0, which is exactly what "the selector does
          ;; not work" looked like. A redelivery is the SAME question, not a fresh
          ;; one, and the reference only resets unconditionally because its reset
          ;; sits INSIDE the arm that has already dropped the old entry
          ;; (app.rs:2596-2601: `retain`, then `sel = 0`, then `push`) — and its
          ;; own comment names the thing that justifies the zero: a *FRESH*
          ;; question. This head's hook runs BEFORE `apply-event` drops the twin,
          ;; so the twin is still here to be asked about.
          (unless (member (getf env :req-id)
                          (session-open-decisions (head-session head))
                          :key (lambda (d) (getf d :req-id)) :test #'string=)
            (setf (head-decision-sel head) 0
                  (head-dirty head) t)))
         ((:job-settled)
          ;; FOLDED INTO THE ROW THE DAEMON GAVE US, never invented. The jobs
          ;; pane draws `head-jobs`, which is only ever the `Jobs` reply, so an
          ;; open pane showed `running` for a job that had exited until `/jobs`
          ;; was run again — the exact lie event.rs:857-864 says this event
          ;; exists to prevent. A settlement for a job this head has not been
          ;; told about is not a row to make up: it arrives with the next
          ;; `ListJobs` (app.rs:2176-2195).
          (let ((row (find (getf env :job) (head-jobs head)
                           :key (lambda (j) (getf j :id)) :test #'equal)))
            (when row
              (setf (getf row :state) (getf env :state)
                    (getf row :running) nil
                    (getf row :produced) (getf env :produced)
                    (getf row :elapsed-ms) (getf env :elapsed-ms)
                    (head-dirty head) t))))
         (t))
       ;; a queued prompt's row has landed: stop announcing it. The ROW's TEXT
       ;; is the match (app.rs:4744-4751), because the transcript takes the
       ;; words over by being them — `pop` retired the NEWEST entry for a row
       ;; that is almost certainly the OLDEST prompt, so with two queued
       ;; prompts of different lengths the wrong one came off first.
       (when (eq name :transcript-content)
         (let ((body (getf env :item)))
           (when (and (consp body) (equal (getf body :type) "user"))
             (let ((text (loop for p in (getf body :parts)
                               when (getf p :text) return (getf p :text))))
               (when text (%retire-pending head text))))))
       ;; apply-event is the classifier: :dirty means something visible moved.
       (let ((disposition (apply-event (head-session head) env)))
         ;; **A REPLY THAT ARRIVED IS SHOWN, AND THAT IS THE ONE THING THE SESSION
         ;; CANNOT DO.** `note-slash-reply` — called from the `:warning` arm inside
         ;; `apply-event` — fills `*slash-out*`; the MODE is head state, so the head
         ;; follows the state HERE, after the fold that produced it. (It was first
         ;; written above the fold, where `*slash-out*` was always still empty: a
         ;; check with nothing to check, which the live probe caught and no test
         ;; could, because both halves are correct on their own.)
         ;;
         ;; The operator typed the verb, so the answer is what they asked for and it
         ;; takes the screen — the reference draws `slash_out` ahead of every other
         ;; pane for the same reason. A pane that was up is not lost (`/help` is one
         ;; key away again), and the alternative is worse: a reply CONSUMED as a
         ;; listing and then drawn nowhere at all.
         (when (and *slash-out* (not (eq (head-mode head) :slash)))
           (setf (head-mode head) :slash
                 (head-dirty head) t))
         (if (eq disposition :dirty)
             (progn (setf (head-dirty head) t) :rendered)
             :filtered))))
    ((string= (frame-name frame) "resync")
     ;; a resync means this head lost its place; the count is on /status and in
     ;; the alarm, because "it happened at all" is the operator's business
     (incf *resyncs*)
     ;; BOTH COUNTS TRAVEL ON THIS FRAME and both were dropped on this path, so
     ;; `/status`'s `dropped` and `scrubbed` under-reported after a resync —
     ;; which is precisely when they are worth reading. The reference adds both
     ;; (app.rs:1843-1845). `ingest-snapshot` takes the max of its own, so this
     ;; is counted first and cannot be overwritten by a smaller snapshot.
     (incf (session-dropped (head-session head)) (or (getf frame :dropped) 0))
     (incf *scrubbed-total* (%scrub-total (getf frame :scrubbed)))
     (ingest-snapshot (head-session head) (getf frame :snapshot))
     (progn
       (setf (head-full-repaint head) t
             (head-dirty head) t)
       (say head (format nil "resync: ~a" (getf frame :reason))))
     :control)
    ((string= (frame-name frame) "accepted")
     ;; Telling the person who just pressed enter that their prompt was
     ;; accepted is not information — and the note sits on the status line for
     ;; the rest of the session. Anything other than the routine acceptance
     ;; still gets said (app.rs:1315, NOTE_PROMPT_QUEUED).
     (let ((note (getf frame :note)))
       (unless (and note (string= note +note-prompt-queued+))
         (say head note))
       ;; **AND IF THIS IS THE ACK TO A STOP, IT IS NOT THE OUTCOME** — it is the
       ;; daemon saying it heard. Recorded and said; `tick-stop-request` decides
       ;; when the wait is over (`head.lisp`, "a stop that is an OUTCOME").
       (heard-stop head note))
     :control)
    ((string= (frame-name frame) "rejected")
     (say head (format nil "rejected: ~a (expected seq ~a, daemon at ~a)"
                     (getf frame :reason) (getf frame :expected-seq)
                     (getf frame :actual-seq)))
     :control)
    ((string= (frame-name frame) "sessions")
     (setf (session-sessions (head-session head))
           ;; subagents are not sessions a picker lists, on this frame as on the
           ;; Hello (app.rs:1732-1735)
           (remove-if (lambda (b) (getf b :parent-session-id)) (getf frame :sessions))
           (head-picker-sel head) 0
           (head-dirty head) t)
     ;; `current` is the daemon's word for where this connection IS. It was
     ;; dropped, along with `created`.
     (let ((current (getf frame :current))
           (created (getf frame :created)))
       (when (and (stringp current) (plusp (length current)))
         (setf (session-session-id (head-session head)) current))
       (cond
         ;; A SESSION WAS MADE BECAUSE THIS HEAD ASKED. Going there is what was
         ;; meant: `/new` that leaves you where you were is a command whose
         ;; effect is invisible, and that is what `/new` and `--new TITLE` did —
         ;; they created a session and left the operator in the old one
         ;; (app.rs:1736-1744).
         ((and created (head-want-new head))
          (setf (head-want-new head) nil)
          (%send head (make-switch created 0)))
         ;; somebody else's: said, not followed
         (created (say head (format nil "session ~a created" created)))
         ;; **Not** an open picker. This frame answers three different questions
         ;; — a list, a rename, and a switch to the session you are in — and only
         ;; the first wants one; the command that asks for a list opens it itself.
         (t nil)))
     :control)
    ((string= (frame-name frame) "jobs")
     (setf (head-jobs head) (getf frame :jobs)
           (head-dirty head) t)
     :control)
    ((string= (frame-name frame) "todos")
     (setf (session-todos (head-session head)) (getf frame :todos)
           (head-dirty head) t)
     :control)
    ((string= (frame-name frame) "settings")
     ;; STORE the rows and stop there. Opening the pane is the COMMAND's act,
     ;; not the reply's: the head asks for settings on attach now (they are only
     ;; ever sent in reply to a request, §7.4), and a reply that opened the pane
     ;; would pop `/config` at every attach.
     (setf (head-settings head) (getf frame :rows)
           ;; when the rows were last heard, so the header can rank them against
           ;; the turn's own word for the model (`%model-name`)
           *model-from-settings-at* (session-seq (head-session head))
           (head-dirty head) t)
     :control)
    ((string= (frame-name frame) "peeked")
     (setf (head-peeked head) (getf frame :events)
           *peeked-session* (getf frame :session-id)
           *peeked-dropped* (or (getf frame :dropped) 0)
           (head-mode head) :peek
           (head-dirty head) t)
     (reset-pane-scroll)
     :control)
    ((string= (frame-name frame) "bye")
     ;; **A BYE IS FINAL — UNLESS THIS HEAD ASKED FOR IT.** The daemon writes one
     ;; and returns; the reference's pump stops on it and the head leaves
     ;; (client.rs:548, app.rs:1886-1889). This head only dropped `connected`, so
     ;; `%try-reconnect` re-attached two seconds later, forever — a refusal the
     ;; daemon meant as the end of the conversation became a loop, and a version
     ;; skew became unreadable AND unescapable: `bye: protocol version 21, this
     ;; daemon speaks 22` flashing under a head that never attaches and never
     ;; exits.
     ;;
     ;; **When a stop is pending, this Bye is the ANSWER to it**, and the outcome
     ;; is still the daemon's absence: leaving here would be the same defect one
     ;; frame later — the operator told nothing while a process that was *asked*
     ;; to go does whatever it does next. So it is recorded and the wait goes on.
     (if *stop-request*
         (progn
           (heard-stop head (format nil "bye — ~a" (getf frame :reason)))
           (progn
             (setf (head-connected head) nil)
             (say head (format nil "bye: ~a" (getf frame :reason)))
             :control))
         (progn
           (progn
             (setf (head-connected head) nil
                   (head-running head) nil
                   (head-farewell head) (format nil "the daemon said goodbye: ~a"
                                                (getf frame :reason)))
             (say head (format nil "bye: ~a" (getf frame :reason)))
             :control))))
    ;; **A FRAME TAG THIS HEAD DOES NOT KNOW IS A FRAME IT CANNOT READ**, and it used
    ;; to be neither said nor counted — the arm answered `:control` and the line went
    ;; past. This is the other half of what a daemon one version ahead looks like from
    ;; a STRUCTURAL reader: serde fails the whole line on an unknown tag, so the
    ;; reference only ever meets this case in its decoder, while this head is handed
    ;; the plist and has to notice for itself.
    ;;
    ;; Silent is the worse of the two failures: a head that steps over a frame from a
    ;; newer daemon in silence makes "this daemon is sending me something I do not
    ;; understand" look exactly like a quiet daemon.
    (t
     ;; **Not a plist at all is also unreadable, and it is reported rather than
     ;; swallowed.** This file has been bitten by exactly that shape before: the
     ;; reader pushes `(:disconnected)` — a one-element list — and a `frame-name`
     ;; call on it is a TYPE-ERROR in the main thread, which under
     ;; `--disable-debugger` is a head that refuses to start (see `%frame-plist-p`).
     ;; The old `(t :control)` hid any other such marker in silence; now the one
     ;; thing that must never happen to an unreadable frame happens to it too.
     (let ((framep (%frame-plist-p frame)))
       (note-unreadable (head-session head)
                        (if framep
                            (format nil "unknown frame ~s" (or (frame-name frame) "?"))
                            (format nil "not a frame at all: ~s" frame))
                        (and framep (getf frame :wire-line))))
     (setf (head-dirty head) t)
     :control)))

(defun %poll-resize (head)
  (multiple-value-bind (cols rows) (terminal-size 1)
    (when (or (/= cols (head-cols head)) (/= rows (head-rows head)))
      (setf (head-cols head) cols (head-rows head) rows)
      (screen-resize (head-screen head) cols rows)
      (screen-resize (head-prev-screen head) cols rows)
      (setf (head-full-repaint head) t
            (head-dirty head) t))))

;;; ------------------------------------------------------------- the loop ;;;

(defun %drain (mailbox)
  (sb-concurrency:receive-pending-messages mailbox))

(defun %try-reconnect (head)
  "Detach is not abort; a dead socket is retried with the seq we had, which
is a resume — the gap arrives as events, or a Resync does (§13.2).

A head that is LEAVING does not reconnect. The loop's own `head-running` check
comes at the top of the next pass, which is one attach too late: a `Bye` and a
`/quit` both arrive mid-pass, and re-attaching to a daemon that just said
goodbye is how a final refusal became a two-second loop."
  (let ((now (get-universal-time)))
    ;; **A HEAD WAITING FOR A STOP DOES NOT MEAN TO RECONNECT.** The daemon it
    ;; asked to stop is closing this socket on purpose: re-attaching to it would
    ;; be asking a dying daemon for a session, and the reconnect would then race
    ;; the very wait this is here to make an outcome of.
    (when (and (head-running head) (null *stop-request*)
               (> now (+ (head-last-reconnect head) 2)))
      (setf (head-last-reconnect head) now)
      (handler-case
          (progn
            (ignore-errors (close (head-stream head)))
            (let ((stream (connect-unix (head-socket-path head))))
              ;; connected before the send: %send refuses to write while
              ;; disconnected, and this attach is the first frame on the fresh
              ;; socket — gated on the old flag it would be dropped and the
              ;; daemon would wait on an ATTACH that never comes (measured:
              ;; one render, then silence).
              (setf (head-stream head) stream
                    (head-connected head) t)
              (%send head (make-attach
                           :session-id (session-session-id (head-session head))
                           :since-seq (session-seq (head-session head))
                           :identity "leticl"))
              ;; The settings are NOT re-asked here: this ATTACH draws a
              ;; `hello`, and the hello handler asks. Asking in both places put
              ;; the frame on the wire twice per reconnect.
              ;; restart the reader: the old one died on the disconnect that
              ;; triggered this, and without a reader the fresh socket is
              ;; written to but never read — the head sits "connected" and
              ;; silent forever (measured: reader thread dead, stuck
              ;; "detached — reconnecting…" with no frames arriving).
              (setf (head-reader head)
                    (sb-thread:make-thread (lambda () (%reader-loop head))
                                           :name "leticl reader"))))
        (error (e)
          (say head (format nil "reconnect: ~a" e)))))))

;;; ------------------------------------------------- the loop and its parts ;;;
;;;
;;; The order of three operations is the whole of it (driver.rs:1):
;;;
;;;   1. drain every frame that has arrived, classifying each
;;;   2. draw
;;;   3. ack the last seq READ, with (rendered, filtered)
;;;
;;; Step 3 comes after step 2, always — §13.2b, *"a crash then costs a
;;; duplicate, never a silence"* — and the seq acked is the last one **read** in
;;; step 1, never the last one drawn. That distinction is the reason a head may
;;; filter freely: it acknowledges what it consumed, so nothing is reread and
;;; nothing is lost, and a head that renders almost nothing still advances.

;;; ----------------------------------------- a stop that is an OUTCOME ;;;
;;;
;;; **A REQUEST IS NOT AN OUTCOME.** The operator chose *leave and stop the
;;; daemon* — twice — and the daemon stayed. The head that asked was already
;;; gone, so nothing could tell them, and nothing ever asked again.
;;;
;;; MEASURED, because the first fix here was a guess and was wrong. The old code
;;; sent `Stop` and set `head-running` nil in the same breath, so the socket was
;;; closed while the daemon was still answering. A scratch daemon, the release
;;; build, the head's own sequence byte for byte:
;;;
;;;     wrote stop, wrote detach, closed the socket — no pause
;;;     daemon alive: T          socket still on disk: T
;;;     snapshot warnings: ('daemon_stopping')   <- THE STOP WAS RECEIVED
;;;     head connection ended: wire io: Broken pipe (os error 32)
;;;
;;; and the same `Stop`, sent by a client that stays for the answer:
;;;
;;;     <- {"frame":"accepted","note":"stopping"}
;;;     <- {"frame":"bye","reason":"daemon shutting down"}
;;;     daemon gone after 232 ms; socket present: F; exit code 0
;;;
;;; So the frame is not lost: it arrives, and the daemon publishes its
;;; `daemon_stopping` warning for it. What is lost is the following write — the
;;; daemon acks into a socket with no reader, takes `EPIPE`, and
;;; `registry.close()` sits BEHIND that write
;;; (`sessionlog/src/server.rs:776-778`), so the stop the daemon *heard* is never
;;; acted on. A one-millisecond pause before the close is enough to save it:
;;; close 0 ms after the stop → STUCK; 1 ms → gone in 221 ms. A race, and the
;;; head always lost it.
;;;
;;; **So the head stays and watches — it does not wait on its own frame.** The
;;; loop keeps draining, keeps painting, keeps SAYING what it is waiting for, and
;;; the wait has a deadline. Past the deadline the head leaves anyway and says on
;;; stderr that it did, naming the pid and the way to stop it from outside. *The
;;; head does not exit until the daemon has actually gone, or until it can say
;;; that it has not.*
;;;
;;; **The fact waited on is the daemon's ABSENCE, not its acknowledgement.** Its
;;; `Accepted` and its `Bye` say it heard, which is a different and weaker
;;; statement, and the row says which one is true.

(defparameter +stop-wait-ms+ 5000
  "How long this head waits for a daemon it asked to stop.

Measured, not guessed: a daemon that takes the stop answers `Accepted`, sends
`bye`, exits and removes its socket **232 ms** later (scratch daemon, release
build — `tools/stop-lab/proof.py`). Five seconds is twenty times the measured
shutdown and still short enough that a daemon which will not go does not hold the
operator's terminal: the case this exists for is a daemon that never goes at all,
and no value of this number waits *that* out.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defvar *stop-request* nil
  "`(:asked-at MS :deadline MS :socket PATH :pid N :heard TEXT :shown TENTHS)`
while this head has asked the daemon to stop and is waiting to see it go, else NIL.

Every key is PRESENT from the start, and that is load-bearing: `tick-stop-request`
writes `:heard` and `:shown` through `(setf (getf …))`, which mutates the cons in
the list when the key is there and silently rebinds a local when it is not — the
trap `%call-put` documents. Keys with nothing in them yet are NIL, not absent.

A `defvar`, so a push can introduce this state on a running head: the wait is
exactly the kind of thing that gets fixed live.")

(defun %daemon-pid-for (socket-path)
  "The pid the launcher wrote beside SOCKET-PATH, or NIL.

`~/bin/letibot` leaves a `<socket>.json` in the run dir carrying the daemon's pid
— the record `discover-daemons` reads — and it is the only place a head can learn
a pid from. A daemon started by hand has no record: then the pid is unknown and
`daemon-gone-p` falls back to the socket rather than inventing one."
  (when (and socket-path (probe-file socket-path))
    (let ((json (make-pathname :type "json" :defaults (pathname socket-path))))
      (when (probe-file json)
        (getf (ignore-errors (json-decode (uiop:read-file-string json))) :pid)))))

(defun daemon-gone-p (socket-path pid)
  "Has the daemon actually gone?

**The pid first, because that is the fact the operator asked for** — and because a
socket FILE outlives a daemon that was killed: a `-9` leaves the path on disk, so
answering \"not gone\" for a process that is not there is the same lie the other way
round. With no pid (a daemon nobody wrote a record for) the socket is all there is,
and \"nothing is listening there\" is the honest reading of it."
  (cond ((and (integerp pid) (plusp pid))
         (not (probe-file (format nil "/proc/~d" pid))))
        (t (not (and socket-path (probe-file socket-path))))))

(defun begin-stop-request (head)
  "Ask the daemon to stop, and REMEMBER that an answer is owed. Returns the request.

**This is where the old code set `head-running` nil, and that is the whole bug**:
the frame went out and the process left in the same breath, so whether the daemon
ever saw it was a race against this head's own shutdown. Now the ask is recorded
and `tick-stop-request`, in the loop, decides when the request has become an
outcome. `write-frame` is `force-output`, so the stop itself is on the socket
before this returns — queued-and-dropped is not the failure mode here."
  (%send head (make-stop (session-expected-seq (head-session head)) "leticl"))
  (setf *stop-request*
        (list :asked-at (internal-real-time-ms)
              :deadline (+ (internal-real-time-ms) +stop-wait-ms+)
              :socket (head-socket-path head)
              :pid (%daemon-pid-for (head-socket-path head))
              :heard nil
              :shown nil)
        (head-dirty head) t)
  *stop-request*)

(defun heard-stop (head text)
  "Record what the daemon ANSWERED a pending stop with. Returns the request.

Called from the `accepted` and `bye` arms, whose normal job is to end things:
during a pending stop they are the acknowledgement, not the outcome, and the tick
is what ends the wait. The first answer wins — a `Bye` after an `Accepted` is the
same fact twice, and the row reads better naming the one that came first."
  (when (and *stop-request* (null (getf *stop-request* :heard)))
    (setf (getf *stop-request* :heard) (or text "acknowledged")
          (head-dirty head) t))
  *stop-request*)

(defun stop-wait-text ()
  "The sentence the head is waiting under, or NIL when nothing is pending.

Two states, because they are two different facts: an ask nobody has answered, and
an ask the daemon has answered. Neither is \"gone\", which is why the wait
continues after the second one."
  (when *stop-request*
    (let* ((req *stop-request*)
           (waited (- (internal-real-time-ms) (getf req :asked-at)))
           (heard (getf req :heard)))
      (format nil "the daemon was asked to stop~@[ and answered \"~a\"~] · waiting for it to go — ~a of ~a"
              heard (duration waited) (duration +stop-wait-ms+)))))

(defun %daemon-said (req)
  "How the two farewells NAME the daemon: the pid and the socket, whichever are known.

**Both, when both are known**, because the failure this exists for is a daemon
nobody could identify: the pid is what `ps` and `letibot --stop` take, and the
socket is what a head started by hand has instead of a pid."
  (let ((pid (getf req :pid)) (socket (getf req :socket)))
    (cond ((and pid socket) (format nil "pid ~d, socket ~a" pid socket))
          (pid (format nil "pid ~d" pid))
          (socket (format nil "socket ~a" socket))
          (t "no pid and no socket record"))))

(defun %stop-gone-said (req waited)
  "The farewell when the daemon DID go: the outcome the operator asked for."
  (format nil "the daemon has stopped (~a), ~a after it was asked."
          (%daemon-said req) (duration waited)))

(defun %stop-timeout-said (req)
  "The farewell when it did NOT: the requirement's third clause, said on stderr
where it survives the alternate screen — how long, which daemon, and the verb that
stops it from outside."
  (format nil "the daemon was asked to stop ~a ago and has NOT stopped (~a). `letibot --stop` stops it from outside; this head is leaving it running."
          (duration (- (internal-real-time-ms) (getf req :asked-at)))
          (%daemon-said req)))

(defun tick-stop-request (head)
  "One pass of the wait for a daemon this head asked to stop. T when it is over.

Three endings and no others: it is gone (the ask succeeded), the deadline passed
(it is not going, and the head leaves anyway **saying so**), or nothing is pending
and this does nothing.

The row is refreshed on the tenth of a second that CHANGED — so the seconds move
and the head is visibly alive rather than frozen, and not on every pass, which
would paint forty-three frames a second to say the same thing."
  (when *stop-request*
    (let* ((req *stop-request*)
           (now (internal-real-time-ms))
           (waited (- now (getf req :asked-at)))
           (tenths (floor waited 100)))
      (cond
        ((daemon-gone-p (getf req :socket) (getf req :pid))
         (setf (head-farewell head) (%stop-gone-said req waited)
               (head-running head) nil)
         t)
        ((>= now (getf req :deadline))
         (setf (head-farewell head) (%stop-timeout-said req)
               (head-running head) nil)
         t)
        (t (unless (eql tenths (getf req :shown))
             ;; `:shown` is PRESENT, so this writes the cons the list already
             ;; holds rather than rebinding anything (see `*stop-request*`)
             (setf (getf req :shown) tenths
                   (head-dirty head) t))
           nil)))))

(defun %answer-screen-requests (head)
  "Answer every queued `screen_requested` with the rows this head just PAINTED.

*\"A tool asked what the operator is looking at; this is the only place in the
system that knows, because it is the place that put the bytes on the terminal\"*
(driver.rs:93-99). Called after the paint, never during the drain: the arm that
answered from `head-last-rows` while the frames were still arriving sent the
PREVIOUS frame — one tick stale at rest, and simply the wrong screen across a
resize or a pane change, which is the one thing this frame exists to report.
Oldest request first."
  (when (head-screen-reqs head)
    ;; **THE ROWS AND THE SIZE COME FROM THE SAME PAINT.** The size is a required
    ;; argument of `make-screen-answer` and not derived from a row's length, because
    ;; that derivation reported the character count of row zero with its escape bytes
    ;; in it. `head-last-cols`/`head-last-rows-n` are set beside `head-last-rows` by
    ;; `%render-and-paint`, so all three describe one frame; before any paint there is
    ;; no frame to describe, and the head's own size is the honest answer.
    (let* ((painted (head-last-rows head))
           (cols (if painted (head-last-cols head) (head-cols head)))
           (rows-n (if painted (head-last-rows-n head) (head-rows head)))
           (rows (or painted (list (make-string (max 1 cols) :initial-element #\space)))))
      (dolist (req (nreverse (head-screen-reqs head)))
        (%send head (make-screen-answer req cols rows-n rows)))
      (setf (head-screen-reqs head) nil))))

(defun run-loop (head)
  (loop while (head-running head)
        do (let ((rendered 0)
                 (filtered 0)
                 (last-seq 0))            ; the read mark, from step 1 only
             ;; the clock, and the arrival of anything at all: the stall line is
             ;; about the DAEMON going quiet, so it is measured from the last
             ;; frame to land, on OUR clock and not on the event's own `ts`
             (setf *now-ms* (internal-real-time-ms))
             (tick-notice head)
             ;; **the wait for a daemon this head asked to stop** — before the
             ;; drain, so the row it marks dirty is painted in THIS pass, and so
             ;; the pass that ends the loop is the one that says why
             (tick-stop-request head)
             ;; 1. drain. An error while FOLDING a frame must not kill the loop
             ;; either: a frame this head cannot handle is one bad frame, not a
             ;; reason to lose the session. The failure is remembered so the
             ;; gate can say so, and the loop reads the next one.
             (dolist (frame (%drain (head-frames head)))
               (note-frame-arrived)
               ;; `(%frame-p frame)`, not `(consp frame)`: the reader pushes
               ;; `(:disconnected)` — a ONE-element list — and `frame-name` calls
               ;; `(getf frame :frame)` on it, which is a malformed plist and a
               ;; TYPE-ERROR in the main thread. With --disable-debugger that is
               ;; not a wrong frame, it is a head that refuses to start: measured,
               ;; `leticl` exited at launch for 45 minutes of this session.
               ;; A frame is a plist whose car is `:frame`; nothing else is one.
               (when (%frame-plist-p frame)
                 (when (and (string= (frame-name frame) "event")
                            (getf frame :seq))
                   (setf last-seq (getf frame :seq))))
               (handler-case
                   (case (%handle-frame head frame)
                     (:rendered (incf rendered) (incf *rendered-total*))
                     (:filtered (incf filtered) (incf *filtered-total*))
                     (t nil))
                 (error (e)
                   (setf *last-render-error* e
                         (head-dirty head) t))))
             (dolist (key (%drain (head-keys head)))
               (handler-case (%handle-key head key)
                 (error (e) (ignore-errors (say head (format nil "key error: ~a" e))))))
             (handler-case (%poll-resize head)
               (error (e) (ignore-errors (say head (format nil "resize error: ~a" e)))))
             ;; `*replaying*`: a replay has no socket to come back to, and
             ;; "not connected" there is the normal state rather than a loss
             (unless (or *replaying* (head-connected head))
               (%try-reconnect head))
             ;; 2. draw (guarded in %render-and-paint: a render error paints
             ;; itself and the loop carries on, so the operator can see what
             ;; broke and re-push instead of losing the head)
             ;;
             ;; **TWO reasons to paint, and only one of them is an event.** An
             ;; event sets `head-dirty`; the CLOCK asks for a frame while anything
             ;; on it is a function of time, because a number computed from
             ;; `*now-ms*` and never asked for is a number drawn once (R13 — see
             ;; `live-frame-p`). An idle head has neither, so it still sleeps.
             (if (or (head-dirty head) (live-frame-due-p head))
                 (%render-and-paint head)
                 (sleep 0.03))
             ;; 2b. answer every screen request with the frame just painted
             (%answer-screen-requests head)
             ;; 3. ack, and only when a frame was actually read this pass: an
             ;; idle tick has no seq to report and must not invent one
             (when (plusp last-seq)
               (%send head (make-ack last-seq rendered filtered))))))

;;; ------------------------------------------------------------- lifecycle ;;;
(defun %open-stdout ()
  "The head's stream on fd 1. Called at startup and RE-called whenever the
stream has gone missing, so a clobbered *stdout* heals on the next paint instead
of taking the head down — writing a frame to NIL is a type error in the MAIN
thread, and in --disable-debugger mode that quits the process (measured: a live
push ran `(defparameter *stdout* nil)` and the operator's head exited)."
  (or *stdout*
      (setf *stdout* (sb-sys:make-fd-stream 1 :output t :element-type 'character
                                            :external-format :utf-8 :buffering :none))))

(defun run (&key socket-path session-id new-title)
  "Attach to a daemon and run until /quit or ctrl+d. NEW-TITLE asks the daemon for
a fresh session under that name right after the attach — `letibot --new TITLE`
through `scripts/leticl-head`, the same two frames `/new` sends from the composer."
  (%open-stdout)
  (unless (plusp (%isatty 1))
    (error "the head paints on the real terminal — run it on a tty, not a pipe"))
  (let* ((path (or socket-path
                   (getf (first (discover-daemons)) :socket)
                   (error 'no-daemon :socket (let ((m (uiop:getenv "LETIBOT_SOCKET")))
                                                (and m (plusp (length m)) m)))))
         (head (%make-head))
         (stream (connect-unix path)))
    ;; The head's own choices, read before the first frame: the folds and the
    ;; diff shape should be what the operator left them, not the defaults, and
    ;; reading here means the very first paint is already right (S5).
    (dolist (note (load-prefs-into head))
      (say head (format nil "~a~@[ · ~a~]" note (head-status-note head))))
    (setf *head* head
          (head-stream head) stream
          (head-socket-path head) path
          ;; the socket is open, so we are connected: %send refuses to write
          ;; while disconnected, and the ATTACH below is the first frame on
          ;; this socket — gated on the initial nil it would be dropped and
          ;; the daemon would wait on an ATTACH that never comes (measured:
          ;; one render, then silence).
          (head-connected head) t
          (head-cols head) (nth-value 0 (terminal-size 1))
          (head-rows head) (nth-value 1 (terminal-size 1)))
    (screen-resize (head-screen head) (head-cols head) (head-rows head))
    (screen-resize (head-prev-screen head) (head-cols head) (head-rows head))
    ;; ATTACH is the first frame on every connection (server.rs:205); an empty
    ;; session id means "the daemon's current session" (registry.rs:600).
    ;;
    ;; The SETTINGS request is NOT sent here: the `hello` handler sends it, and
    ;; asking in both places put the frame on the wire twice per attach — seen
    ;; by witnessing the head's writes against a fake daemon. The hello hook is
    ;; the right home because a `Switch` also lands as a hello, so one send
    ;; covers attach, switch and reconnect.
    ;; the clock the attach indicator walks to; cleared when a Hello lands
    (setf *attach-started-ms* (internal-real-time-ms))
    (%send head (make-attach :session-id (or session-id "")
                             :identity "leticl"))
    ;; `--new TITLE`: the attach lands on the daemon's current session, and this
    ;; asks for a fresh one under the name — the frame `/new` sends, so the
    ;; launcher's `--new` and the composer's `/new` cannot disagree
    (when (and new-title (plusp (length new-title)))
      (%send head (make-new-session new-title "")))
    (hack-start head)
    (setf (head-reader head)
          (sb-thread:make-thread (lambda () (%reader-loop head)) :name "leticl reader")
          (head-input head)
          (sb-thread:make-thread (lambda () (%input-loop head)) :name "leticl input"))
    (with-tui-terminal (*stdout*)
      (unwind-protect
           (run-loop head)
        (ignore-errors (%send head (make-detach)))
        (hack-stop head)))
    (ignore-errors (close stream))
    ;; **THE FAREWELL, after the terminal is back.** A `Bye` says why the daemon
    ;; ended the conversation — a version skew names both numbers — and saying it
    ;; into the transcript puts it on the ALTERNATE SCREEN, which is thrown away
    ;; one line later: the operator is returned to their shell with a head that
    ;; exited and no reason anywhere. The reference prints it after `Terminal`
    ;; is dropped for exactly this (`App::farewell`, app.rs:1555).
    (awhen (head-farewell head)
      (format *error-output* "~&leticl: ~a~%" it)
      (force-output *error-output*))))


