;;;; lifecycle — starting, attaching, detaching, leaving
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

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

(defun run (&key socket-path session-id new-title resume-id theme-template)
  "Attach to a daemon and run until /quit or ctrl+d. NEW-TITLE asks the daemon for
a fresh session under that name right after the attach — `letibot --new TITLE`
through `scripts/leticl-head`, the same two frames `/new` sends from the composer.

**RESUME-ID is a different act from SESSION-ID and the difference is measured.** A session the
daemon HOLDS is named on the ATTACH; one on disk is not the daemon's yet, so an attach naming it is
refused. `--resume ID` therefore attaches as it would with no id and holds the ask in
`*pending-resume*`, which the first Hello consumes — through `%switch-to`, the same path the picker
uses, so the two doors cannot disagree about which frame brings a session in (T4 in `TODO.md`)."
  ;; **THEME-TEMPLATE PRINTS AND LEAVES** (letibot `d7288a8`, whose `--theme-template` does the same):
  ;; it is a question about THIS BUILD rather than about a session — *which roles may I set, and what do
  ;; they look like now* — so it answers on stdout and returns before a daemon is looked for. A flag that
  ;; needed a running daemon to list a table would be a flag nobody can use to write their first theme.
  (when theme-template
    (write-string (theme-template) *standard-output*)
    (force-output)
    (return-from run nil))
  (setf *pending-resume* (and resume-id (plusp (length resume-id)) resume-id))
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
    ;; **AND THE THEME, WHICH IS WHAT THOSE PREFS SAY EVERY ROLE IS DRAWN WITH** (letibot `d7288a8`).
    ;; The prefs are in, so this is the first moment `*role-looks*` can be told — and it is told ONCE per
    ;; head rather than per frame, because a theme is a FILE: a file read in a paint path is a file read
    ;; sixty times a second, and the render is the one place this head cannot afford that.
    ;;
    ;; **A NOTE HERE IS SAID LIKE ANY OTHER STARTUP NOTE.** A theme line that names a role nobody draws,
    ;; or a look the parser cannot read, is exactly the kind of thing the reader is owed a sentence about
    ;; — and `theme-looks` names them rather than dropping them.
    (multiple-value-bind (looks theme-notes)
        (theme-looks (prefs-theme (head-prefs head)) (prefs-colors (head-prefs head)))
      (setf *role-looks* looks)
      (dolist (note theme-notes)
        (say head (format nil "~a~@[ · ~a~]" note (head-status-note head)))))
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
        ;; **THE DETACH HAS A DEADLINE OF ITS OWN, AND THE TERMINAL DOES NOT WAIT ON IT.**
        ;; Before 2026-10-11 this was an unbounded `write(2)`: a daemon that had stopped
        ;; reading made `/quit` hang on its own goodbye, on the alternate screen, in raw mode,
        ;; with the only way out a `kill -9` from another window. One second, not the loop's
        ;; five: a head that is LEAVING owes the operator their terminal more than it owes a
        ;; dead daemon a courtesy — the daemon notices the closed socket anyway, which is the
        ;; same detach by another route. `with-tui-terminal`'s own `unwind-protect` runs
        ;; `leave-tui` after this cleanup whatever it did, and the `ignore-errors` is what
        ;; makes "whatever it did" include a `write-timeout`.
        (ignore-errors
         (let ((*write-timeout-secs* 1))
           (%send head (make-detach))))
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


