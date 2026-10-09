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
  (prompt-req nil)
  (peeked nil)
  (settings nil)
  (jobs nil)
  (subagents nil)
  (prefs (list :show-reasoning nil :show-tools nil :diff "split" :links t))
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
  "Main thread only — the writer is single-threaded by construction.

**A READ-ONLY SEATING SENDS NOTHING, and this is where that is true for every path**
(the operator's ruling, letibot `f6e66f0`): the composer, a decision card's answer, a
secret, a pane's bytes, and the head's own seating asks all come through here, and a
frame a 22 daemon has never heard of fails its deserialiser and ends the session. The
REASON is said at the sites a person acts — `%submit-line` and the chord — and silently
here, because a pane refetching on a timer is not a person to argue with."
  (when (skew-locked-p)
    (return-from %send nil))
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

(defun attach-anyway (head)
  "`ctrl-^` — *attach anyway, I know what this is.*

**Nothing is re-sent.** The override does not reach back for whatever was refused while
locked: a refused line was HELD in the composer, not queued, and re-sending a person's
words after they have moved on is an act nobody asked for. What it does send are the
reads the seating itself owes — the settings ask the Hello would have made — which the
lock skipped on arrival: those are the head's own obligations, not the operator's, and
lifting the lock is the moment they come due. Silent when nothing is locked, by the
rule a chord is only named where it acts."
  (when (skew-locked-p)
    (let ((older (cdr *daemon-seat*)))
      (setf *skew-override-seat* *daemon-seat*)
      (%send head (make-settings))
      (say head (format nil "attached anyway — this head now sends to a daemon speaking protocol ~d against its own ~d. The first frame the two do not share still ends the connection, with a `Bye` naming both builds; restarting the daemon is the fix."
                        older +protocol-version+))
      (setf (head-dirty head) t)
      t)))

(defun %reader-loop (head)
  "Socket → frames mailbox. EOF is detach, never abort (§13.2).

**Every frame carries the line it arrived as**, under `:wire-line`. Not a copy: it
is the string `read-frame` just returned, which the frame now keeps alive until it
is folded and which is therefore free — one cons. It is here because a frame this
head cannot read is only evidence if the operator can see the bytes, and the two
places that meet one (an unknown frame tag, an unknown event tag) are downstream of
the decode that would otherwise have dropped the line on the floor."
  ;; **The stream is taken ONCE, and the goodbye names it.** A reconnect replaces `head-stream`
  ;; while this loop is still running on the old one; reading through the slot would have the old
  ;; reader read the NEW socket, and an untagged `(:disconnected)` from it would be taken as the
  ;; new connection's. `%handle-frame` ignores a marker whose stream is not the current one.
  (loop with stream = (head-stream head)
        do
    (handler-case
        (multiple-value-bind (line eof) (read-frame stream)
          (cond (eof
                 (sb-concurrency:send-message (head-frames head) (list :disconnected stream))
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
        (sb-concurrency:send-message (head-frames head) (list :disconnected stream))
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

(defvar *daemon-seat* nil
  "The process at the other end of the socket, as of the last `Hello` — `(pid . protocol)`.

**A PAIR rather than the pid alone, because the kernel reuses pids** (the reference's own
ruling, `DaemonSeat`): a daemon restarted and handed the same number is a different daemon
with the same identity, and the protocol version is the other half of the answer — a replaced
daemon is usually a rebuilt one, and a rebuild that moved the wire is the case a head most
needs to be told about. What this deliberately is NOT is a daemon instance id: that would be a
boot stamp the daemon mints and a `PROTOCOL_VERSION` bump, and `SO_PEERCRED` is already on the
socket. The residue — a replacement with the same pid AND the same protocol — is named here
rather than papered over.

NIL until the first `Hello` (nothing to compare), and reset by `with-replay-globals`, because a
replay has no socket and no peer.")

(defvar *seat-said-pending* nil
  "The replaced-daemon sentence the `Hello` being folded produced, held until the snapshot is
in — the same reason as `*skew-said-pending*`, beside which it sits.")

(defvar *seat-last-said* nil
  "The last replaced-daemon sentence this head filed, so the same change does not file twice
(a flip back and forth between two daemons files each move, which is right; the SAME move
filing twice is not).")

(defvar *filtered-total* 0
  "Events this head consumed and did not draw, over its life — what `/verbosity`
reports beside the level, so \"terse\" is a number and not a mood.")

(defvar *rendered-total* 0
  "Events this head consumed and DID draw, over its life — the other half of the
ack's accounting, which `/status` shows as `seq · N rendered` the way the
reference does. Counted by this head, not by the daemon.")

(defparameter +input-external-format+ '(:utf-8 :replacement #\?)
  "How fd 0 is decoded. **The `:replacement` IS THE FIX, not a nicety.**

MEASURED: a byte that is not valid UTF-8 on stdin makes SBCL's UTF-8 decoder signal
`STREAM-DECODING-ERROR: :UTF-8 stream` — the operator's *\"complaining about wrong character code
while i was typing\"*. Reproduced with a one-byte file:

    lone continuation 0x80   -> STREAM-DECODING-ERROR: :UTF-8 stream
    0xff                     -> the same
    latin1 e9 (e-acute)      -> the same
    esc [ 0x80               -> the same   (a mouse sequence with one bad byte)
    valid utf-8              -> read fine

`read-char` with a bare `:utf-8` therefore signals on the FIRST undecodable byte, and a terminal can
send one at any moment: a mis-encoded key, a paste from a Latin-1 file, a byte lost in a resize race.

**The head must not care.** It renders cells and it is not the terminal's editor: one byte it cannot
decode is one wrong glyph, and refusing the WHOLE stream for it means the reader's keyboard stops.
`:replacement` makes the decoder produce `#\?` for that byte and carry on, which is the same trade this
tree makes everywhere else — an unknown thing is DRAWN as something honest rather than taken as a
reason to stop. And it is why this is a parameter rather than a literal: the encoding is a choice about
this head's input, and a head on a terminal that is genuinely not UTF-8 wants a different answer.

**It is also not a substitute for `%input-loop`'s guard.** A guard says *something went wrong and here
it is*; this says *this is not wrong*. Both are wanted: the format handles the byte, and the guard
handles everything the format cannot — a closed fd, a mailbox failure — because the reader thread is
the one thing whose death is silent.")

(defun %input-loop (head)
  "Terminal → keys mailbox.

**NOTHING HERE MAY END THE THREAD, AND IT HAD NO GUARD AT ALL.** The operator: *\"it was complaining
about wrong character code while i was typing\"* — and that message is `STREAM-DECODING-ERROR`, MEASURED,
raised by this loop's own `read-char` on a byte that is not valid UTF-8. See `+input-external-format+`
for the fix at the source; this guard is the second half, for everything the DECODER cannot be asked to
tolerate.

An error here does not reach `run-loop`'s guards: it kills THIS thread, and the mailbox is then never
written again while the head keeps painting and answering evals. Typing stops and the only symptom is
that the screen stops changing — the worst shape a failure can take, because nothing says anything.

So an unreadable byte is SAID and the loop goes on. The status note is the right register for it: the
reader is at the keyboard, that is exactly where they are looking, and the note expires on its own
rather than needing to be cleared. `handler-case` around the WHOLE body, not just `read-key`: sending
to the mailbox is the other half that must not end the only reader there is.

The `:eof` return is OUTSIDE the guard on purpose — a closed stdin is a fact about the terminal, not
an error, and a guard that swallowed it would leave a thread spinning on a dead fd."
  (let ((in (sb-sys:make-fd-stream 0 :input t :element-type 'character
                                   :external-format +input-external-format+)))
    (loop
      (let ((key nil) (eof nil))
        (handler-case
            (progn
              (setf key (read-key in))
              (sb-concurrency:send-message (head-keys head) key))
          (error (e)
            ;; said, not swallowed: a reader whose keys are being dropped must be told, and the
            ;; expiry means the message does not have to be cleaned up
            (ignore-errors (say head (format nil "input: ~a" e)))
            ;; a byte this decoder cannot read is CONSUMED rather than re-read, or the loop spins on
            ;; it: reading one char off the stream advances past whatever arrived
            (ignore-errors (read-char in nil nil))))
        (when (or (and key (eq (getf key :type) :eof)) (eq key :eof))
          (return))))))

