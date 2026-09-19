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
  (prefs (list :show-reasoning t :show-tools t))
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

(defun %input-loop (head)
  "Terminal → keys mailbox."
  (let ((in (sb-sys:make-fd-stream 0 :input t :element-type 'character
                                   :external-format :utf-8 :buffering :none)))
    (loop
      (let ((key (read-key in)))
        (sb-concurrency:send-message (head-keys head) key)
        (when (eq (getf key :type) :eof) (return))))))

;;; ------------------------------------------------------------ frames ;;;
(defun %handle-frame (head frame)
  (cond
    ((and (consp frame) (eq (car frame) :disconnected))
     (setf (head-connected head) nil
           (head-status-note head) "detached — reconnecting…"
           (head-dirty head) t))
    ((and (consp frame) (string= (frame-name frame) "warning")
          (getf frame :code) (member (getf frame :code)
                                     '("malformed-frame" "read-error")
                                     :test #'string=))
     ;; our own transport warnings, not session events
     (setf (head-status-note head)
           (format nil "~a: ~a" (getf frame :code) (getf frame :detail))
           (head-dirty head) t))
    ((string= (frame-name frame) "hello")
     (ingest-hello (head-session head) frame)
     (setf (head-connected head) t
           (head-status-note head) nil
           (head-full-repaint head) t
           (head-dirty head) t))
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
       (when (eq (apply-event (head-session head) env) :dirty)
         (setf (head-dirty head) t))
       ;; a queued prompt's row has landed: stop announcing it (app.rs:3018)
       (when (and (eq name :transcript-appended)
                  (string= (getf env :kind) "user")
                  (head-queued head))
         (pop (head-queued head))
         (setf (head-dirty head) t))))
    ((string= (frame-name frame) "resync")
     (ingest-snapshot (head-session head) (getf frame :snapshot))
     (setf (head-full-repaint head) t
           (head-dirty head) t
           (head-status-note head) (format nil "resync: ~a" (getf frame :reason))))
    ((string= (frame-name frame) "accepted")
     ;; Telling the person who just pressed enter that their prompt was
     ;; accepted is not information — and the note sits on the status line for
     ;; the rest of the session. Anything other than the routine acceptance
     ;; still gets said (app.rs:1315, NOTE_PROMPT_QUEUED).
     (let ((note (getf frame :note)))
       (unless (and note (string= note +note-prompt-queued+))
         (setf (head-status-note head) note
               (head-dirty head) t))))
    ((string= (frame-name frame) "rejected")
     (setf (head-status-note head)
           (format nil "rejected: ~a (expected seq ~a, daemon at ~a)"
                   (getf frame :reason) (getf frame :expected-seq)
                   (getf frame :actual-seq))
           (head-dirty head) t))
    ((string= (frame-name frame) "sessions")
     (setf (session-sessions (head-session head)) (getf frame :sessions)
           (head-picker-sel head) 0
           (head-dirty head) t))
    ((string= (frame-name frame) "todos")
     (setf (session-todos (head-session head)) (getf frame :todos)
           (head-dirty head) t))
    ((string= (frame-name frame) "settings")
     (setf (head-settings head) (getf frame :rows)
           (head-mode head) :config
           (head-dirty head) t))
    ((string= (frame-name frame) "peeked")
     (setf (head-peeked head) (getf frame :events)
           (head-mode head) :peek
           (head-dirty head) t))
    ((string= (frame-name frame) "bye")
     (setf (head-connected head) nil
           (head-status-note head) (format nil "bye: ~a" (getf frame :reason))
           (head-dirty head) t))
    (t nil)))

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

(defun run-loop (head)
  (loop while (head-running head)
        do (dolist (frame (%drain (head-frames head)))
             (%handle-frame head frame))
           (dolist (key (%drain (head-keys head)))
             (%handle-key head key))
           (%poll-resize head)
           (unless (head-connected head)
             (%try-reconnect head))
           (if (head-dirty head)
               (%render-and-paint head)
               (sleep 0.03))))

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
                   (error "no daemon found — start one or pass :socket-path")))
         (head (%make-head))
         (stream (connect-unix path)))
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
    ;; session id means "the daemon's current session" (registry.rs:600)
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


