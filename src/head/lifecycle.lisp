;;;; lifecycle — starting, attaching, detaching, leaving
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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
    ;; **THE DASHBOARDS THIS HEAD SHIPS, registered at startup and COLLECTING LATER.** Without
    ;; this a fresh head had the vocabulary and no panels — measured: *"I restarted, no
    ;; dashboards"* — because the only thing that ever registered one was a hand-typed eval.
    ;; The collector stays off until the pane is opened; see `dash-register-defaults`.
    (dash-register-defaults)
    ;; **AND THEN THE FILES, WHICH SHADOW THE BUILT-INS BY NAME** (R56). A file always wins: the
    ;; panels above are DEFAULT STATE like the folds and the diff shape, and the operator's own
    ;; dashboard for their import must be able to replace one. The workspace is not known yet at
    ;; this point — the daemon says it in the session wiring — so this loads the user directory
    ;; now and `/dashboards` loads the project's when the head can name it
    ;; (`dash-file-load-needed-p`).
    (dash-load-file-panels head)
    ;; **AND THE WATCHERS AND THEIR SINKS, from the same two directories' `watchers/`.** Registered
    ;; here and STARTED later, deliberately: reading a file is a few plists, while running a command
    ;; on a timer is work nobody asked for until a job is claimed or somebody opens the pane. The
    ;; lifecycle is `tick-dash-watchers`, on the main loop.
    (dash-watcher-load head)
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
    ;; the head's CURRENT stream, not the one this function opened: a reconnect replaced it, and
    ;; closing the original a second time left the live socket open at exit
    (ignore-errors (close (head-stream head)))
    ;; **THE FAREWELL, after the terminal is back.** A `Bye` says why the daemon
    ;; ended the conversation — a version skew names both numbers — and saying it
    ;; into the transcript puts it on the ALTERNATE SCREEN, which is thrown away
    ;; one line later: the operator is returned to their shell with a head that
    ;; exited and no reason anywhere. The reference prints it after `Terminal`
    ;; is dropped for exactly this (`App::farewell`, app.rs:1555).
    (awhen (head-farewell head)
      (format *error-output* "~&leticl: ~a~%" it)
      (force-output *error-output*))
    ;; **THE ID IT WAS SERVING, ALONE ON STDOUT** (letibot `feed8b5`, and it is the operator's
    ;; own ask: *'I guess on exit you have to print main session id to stdout too'*, after a
    ;; restart landed them in a reviewer's session instead of the conversation). The launcher
    ;; `exec`s this head, so THIS stdout IS the launcher's — the daemon's is detached into a log
    ;; nobody reads — and `--session ID` reopens whatever this names.
    ;;
    ;; The session the head was IN at exit, not the daemon's root: the operator may have
    ;; switched with ctrl-s, and a child reopens as readily as a root. Alone on stdout, with
    ;; everything else an exit says left on stderr where a pipeline ignores it; a head that
    ;; never seated a session prints nothing, because an empty line is worse than silence.
    (let ((id (session-session-id (head-session head))))
      (when (and id (plusp (length id)))
        (format *standard-output* "~a~%" id)
        (force-output *standard-output*)))))


