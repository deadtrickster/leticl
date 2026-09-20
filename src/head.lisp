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
  (mode :normal :type symbol)            ; :normal :picker :help :status :config :jobs :subagents :peek :todos
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
  (queued nil :type list)                ; prompts sent, user row not yet seen
  (connected nil :type boolean)
  (frames (sb-concurrency:make-mailbox :name "leticl frames"))
  (keys (sb-concurrency:make-mailbox :name "leticl keys"))
  (reader nil) (input nil) (hack-listener nil) (hack-thread nil)
  (hack-path nil)
  (running t :type boolean)
  (last-reconnect 0 :type fixnum)
  (socket-path nil)
  (quit-open nil :type boolean)
  (quit-sel 0 :type fixnum))

;;; ---------------------------------------------------------------- io ;;;
(defun %send (head frame)
  "Main thread only — the writer is single-threaded by construction."
  (when (and (head-stream head) (head-connected head))
    (handler-case
        (write-frame (encode-frame frame) (head-stream head))
      (error (e)
        (setf (head-connected head) nil
              (head-status-note head) (format nil "send failed: ~a" e))))))

(defun %reader-loop (head)
  "Socket → frames mailbox. EOF is detach, never abort (§13.2)."
  (loop
    (handler-case
        (multiple-value-bind (line eof) (read-frame (head-stream head))
          (cond (eof
                 (sb-concurrency:send-message (head-frames head) '(:disconnected))
                 (return))
                (t
                 (handler-case
                     (sb-concurrency:send-message (head-frames head)
                                                  (decode-frame line))
                   (wire-error (e)
                     (sb-concurrency:send-message
                      (head-frames head)
                      (list :frame "warning" :code "malformed-frame"
                            :detail (format nil "~a" e))))))))
      (error (e)
        (sb-concurrency:send-message (head-frames head) '(:disconnected))
        (sb-concurrency:send-message
         (head-frames head)
         (list :frame "warning" :code "read-error" :detail (format nil "~a" e)))
        (return)))))

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
     (setf (head-connected head) nil
           (head-status-note head) "detached — reconnecting…"
           (head-dirty head) t)
     :control)
    ((and (consp frame) (string= (frame-name frame) "warning")
          (getf frame :code) (member (getf frame :code)
                                     '("malformed-frame" "read-error")
                                     :test #'string=))
     ;; our own transport warnings, not session events
     (setf (head-status-note head)
           (format nil "~a: ~a" (getf frame :code) (getf frame :detail))
           (head-dirty head) t)
     :control)
    ((string= (frame-name frame) "hello")
     ;; A Switch lands as a Hello on the new session, and the money meter is the
     ;; CONVERSATION's — carrying one session's bill onto another's header is
     ;; wrong in the direction that costs money. Cleared, not guessed.
     (reset-spent)
     ;; the wait is over: the cat stands down
     (setf *attach-started-ms* nil)
     (ingest-hello (head-session head) frame)
     (setf (head-connected head) t
           (head-status-note head) nil
           (head-full-repaint head) t
           (head-dirty head) t)
     ;; A `Switch` lands as a Hello on the new session, so asking here covers
     ;; attach AND switch with one send (§7.4). Without it the header keeps the
     ;; old session's model, and the rows a picker would read are another
     ;; session's.
     (%send head (make-settings))
     :control)
    ((string= (frame-name frame) "event")
     (let* ((env frame)
            (name (event-name env)))
       ;; the two events a head answers rather than renders
       (case name
         ((:screen-requested)
          (%send head (make-screen-answer (getf env :req-id)
                                          (or (head-last-rows head)
                                              (list "")))))
         ((:secret-requested)
          (setf (head-secret-req head) env
                (head-secret-buf head) ""
                (head-dirty head) t))
         (t))
       ;; a queued prompt's row has landed: stop announcing it (app.rs:3018)
       (when (and (eq name :transcript-appended)
                  (string= (getf env :kind) "user")
                  (head-queued head))
         (pop (head-queued head))
         (setf (head-dirty head) t))
       ;; apply-event is the classifier: :dirty means something visible moved.
       (if (eq (apply-event (head-session head) env) :dirty)
           (progn (setf (head-dirty head) t) :rendered)
           :filtered)))
    ((string= (frame-name frame) "resync")
     ;; a resync means this head lost its place; the count is on /status and in
     ;; the alarm, because "it happened at all" is the operator's business
     (incf *resyncs*)
     (ingest-snapshot (head-session head) (getf frame :snapshot))
     (setf (head-full-repaint head) t
           (head-dirty head) t
           (head-status-note head) (format nil "resync: ~a" (getf frame :reason)))
     :control)
    ((string= (frame-name frame) "accepted")
     ;; Telling the person who just pressed enter that their prompt was
     ;; accepted is not information — and the note sits on the status line for
     ;; the rest of the session. Anything other than the routine acceptance
     ;; still gets said (app.rs:1315, NOTE_PROMPT_QUEUED).
     (let ((note (getf frame :note)))
       (unless (and note (string= note +note-prompt-queued+))
         (setf (head-status-note head) note
               (head-dirty head) t)))
     :control)
    ((string= (frame-name frame) "rejected")
     (setf (head-status-note head)
           (format nil "rejected: ~a (expected seq ~a, daemon at ~a)"
                   (getf frame :reason) (getf frame :expected-seq)
                   (getf frame :actual-seq))
           (head-dirty head) t)
     :control)
    ((string= (frame-name frame) "sessions")
     (setf (session-sessions (head-session head)) (getf frame :sessions)
           (head-picker-sel head) 0
           (head-dirty head) t)
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
     (setf (head-connected head) nil
           (head-status-note head) (format nil "bye: ~a" (getf frame :reason))
           (head-dirty head) t)
     :control)
    (t :control)))

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
is a resume — the gap arrives as events, or a Resync does (§13.2)."
  (let ((now (get-universal-time)))
    (when (> now (+ (head-last-reconnect head) 2))
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
          (setf (head-status-note head) (format nil "reconnect: ~a" e)))))))

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
                 (error (e) (ignore-errors (setf (head-status-note head)
                                                 (format nil "key error: ~a" e))))))
             (handler-case (%poll-resize head)
               (error (e) (ignore-errors (setf (head-status-note head)
                                               (format nil "resize error: ~a" e)))))
             (unless (head-connected head)
               (%try-reconnect head))
             ;; 2. draw (guarded in %render-and-paint: a render error paints
             ;; itself and the loop carries on, so the operator can see what
             ;; broke and re-push instead of losing the head)
             (if (head-dirty head)
                 (%render-and-paint head)
                 (sleep 0.03))
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

(defun run (&key socket-path session-id)
  "Attach to a daemon and run until /quit or ctrl+d."
  (%open-stdout)
  (unless (plusp (%isatty 1))
    (error "the head paints on the real terminal — run it on a tty, not a pipe"))
  (let* ((path (or socket-path
                   (getf (first (discover-daemons)) :socket)
                   (let ((mine (uiop:getenv "LETIBOT_SOCKET")))
                     (error (if mine
                                (format nil "no daemon for this folder: nothing listens at ~a.~%leticl is a head only — start the daemon here first (leticode or letibot in this directory), or point LETIBOT_SOCKET at another folder's daemon to attach to it on purpose."
                                        mine)
                                "no daemon found — start one or pass :socket-path")))))
         (head (%make-head))
         (stream (connect-unix path)))
    ;; The head's own choices, read before the first frame: the folds and the
    ;; diff shape should be what the operator left them, not the defaults, and
    ;; reading here means the very first paint is already right (S5).
    (dolist (note (load-prefs-into head))
      (setf (head-status-note head)
            (format nil "~a~@[ · ~a~]" note (head-status-note head))))
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
    (ignore-errors (close stream))))


