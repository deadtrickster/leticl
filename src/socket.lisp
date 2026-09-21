;;;; socket.lisp — unix socket connect and daemon discovery.
;;;; Daemons publish <hash>.json (workspace, socket, pid, role, model, …) and
;;;; a matching <hash>.sock under $XDG_RUNTIME_DIR/letibot/ — measured on this
;;;; box, PLAN.md §4. One daemon per folder.

(in-package #:leticl)

(defun connect-unix (path)
  "A UTF-8 character stream on a unix socket. Unbuffered output: frames are
written whole and flushed per frame (wire.rs:88)."
  (let ((sock (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (sb-bsd-sockets:socket-connect sock (namestring path))
    (sb-bsd-sockets:socket-make-stream sock
                                       :input t :output t
                                       :element-type 'character
                                       :external-format :utf-8
                                       :buffering :none)))

(defun wait-for-input (stream timeout-secs)
  "T when STREAM can deliver input without blocking, waiting up to
TIMEOUT-SECS (nil waits forever). listen answers only about bytes already
inside the stream's buffer; the fd decides — a loop that polls listen alone
gets one poll microseconds after its attach write, before the daemon has
read anything, and concludes the peer is silent (smoke-head, measured).
A stream without an fd (a test string stream) falls back to listen alone —
its whole input is already in the buffer."
  (or (listen stream)
      (when (typep stream 'sb-sys:fd-stream)
        (sb-sys:wait-until-fd-usable (sb-sys:fd-stream-fd stream)
                                     :input timeout-secs))))

(defun runtime-dir ()
  "Where leticl's own sockets live: $XDG_RUNTIME_DIR, falling back to
/tmp/leticl-<uid> for contexts without it (PLAN.md §8)."
  (or (uiop:getenv "XDG_RUNTIME_DIR")
      (format nil "/tmp/leticl-~d" (sb-posix:getuid))))

(define-condition no-daemon (error)
  ((socket :initarg :socket :reader no-daemon-socket))
  (:report (lambda (c stream)
             (if (no-daemon-socket c)
                 (format stream "no daemon for this folder: nothing listens at ~a.~%leticl is a head only — start the daemon here first (leticode or letibot in this directory), or point LETIBOT_SOCKET at another folder's daemon to attach to it on purpose."
                         (no-daemon-socket c))
                 (format stream "no daemon found — start one, or pass --session to a daemon's session"))))
  (:documentation "Nothing to attach to. Its own condition so the image's toplevel can
print the sentence and exit rather than a backtrace: a refusal is a message for
the operator, and a debugger dump is the shape of a crash."))

(defun daemon-dir ()
  "Where daemons publish: $XDG_RUNTIME_DIR/letibot/, falling back to
/run/user/<uid>/letibot/ — this box's agent contexts run without
XDG_RUNTIME_DIR (measured, PLAN.md §4)."
  (let ((x (uiop:getenv "XDG_RUNTIME_DIR")))
    (if x
        (merge-pathnames "letibot/" (pathname (concatenate 'string x "/")))
        (merge-pathnames "letibot/"
                         (pathname (format nil "/run/user/~d/" (sb-posix:getuid)))))))

(defun %in-workspace (ws cwd)
  "T when CWD is WS or inside it (a path-boundary match, so /a/b does not
claim /a/bc). (subseq + string= rather than string-prefixp: the latter does
not resolve to CL in the frozen image and dies as LETICL::STRING-PREFIXP.)"
  (and ws
       (<= (length ws) (length cwd))
       (string= (subseq cwd 0 (length ws)) ws)
       (or (= (length ws) (length cwd))
           (char= (char cwd (length ws)) #\/))))

(defun %socket-exists-p (path)
  "Is there a unix socket at PATH? `probe-file` answers for any file; the head
wants the FILE KIND, because a leftover regular file with the same name is not a
daemon and connecting to it fails with a different error entirely."
  (handler-case
      (= sb-posix:s-ifsock
         (logand (sb-posix:stat-mode (sb-posix:stat path)) sb-posix:s-ifmt))
    (error () nil)))

(defun discover-daemons ()
  "Every daemon this user runs, as decoded plists of their .json files, the
one named by $LETIBOT_SOCKET first when set — that is the daemon of the folder
the calling context belongs to. Without $LETIBOT_SOCKET (a head run directly,
not via ~/bin/leticl) the daemon whose workspace contains the current
directory comes first, so the head finds its own daemon, not the first one in
the run dir. Read-only; a file that does not parse is skipped, not fatal — a
half-written json from a daemon that is starting up must not take a head down."
  (let* ((plists (loop for f in (ignore-errors
                                 (directory (merge-pathnames "*.json" (daemon-dir))))
                       for plist = (ignore-errors (json-decode (uiop:read-file-string f)))
                       when plist collect plist))
         (mine (uiop:getenv "LETIBOT_SOCKET")))
    (cond
      ;; **A named socket that is not there is NO daemon, not "any daemon".**
      ;; This returned the whole list when `$LETIBOT_SOCKET` matched nothing, so
      ;; `leticl` run in a folder with no daemon attached to whichever daemon the
      ;; run dir listed first and drew ITS current session — the operator opened
      ;; leticl in an unrelated directory and was put in the latest leticl
      ;; conversation. The launcher names the folder's socket precisely so the
      ;; head can refuse when it is not there.
      (mine
       ;; **THE SOCKET IS THE DAEMON; the record is only what a launcher wrote
       ;; beside it.** This matched `$LETIBOT_SOCKET` against the `.json` files
       ;; `~/bin/letibot` leaves in the run dir, so a daemon started any other
       ;; way — by hand, by a test, by a harness with its own launcher — was
       ;; refused with *"nothing listens at X"* while something was listening at
       ;; X. Measured: a scratch `harnessd` on its own socket, live, and the head
       ;; would not attach. The record is still preferred when it exists, because
       ;; it carries the workspace and the seat; its absence is not a refusal.
       (let ((hit (find mine plists :key (lambda (p) (getf p :socket)) :test #'string=)))
         (cond (hit (cons hit (remove hit plists)))
               ((%socket-exists-p mine) (list (list :socket mine)))
               (t nil))))
      (t
       (let* ((cwd (namestring (uiop:getcwd)))
              ;; the MOST SPECIFIC workspace wins: /home/dead matches a head in
              ;; /home/dead/Projects/leticl too (that path is inside it), and
              ;; picking the shorter one attaches to the wrong daemon — measured,
              ;; an empty screen and a fresh session in the parent folder.
              (hit (first (sort (remove-if-not
                                 (lambda (p) (%in-workspace (getf p :workspace) cwd))
                                 plists)
                                #'>
                                :key (lambda (p) (length (getf p :workspace)))))))
         (if hit (cons hit (remove hit plists)) plists))))))
