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

(defun daemon-dir ()
  "Where daemons publish: $XDG_RUNTIME_DIR/letibot/, falling back to
/run/user/<uid>/letibot/ — this box's agent contexts run without
XDG_RUNTIME_DIR (measured, PLAN.md §4)."
  (let ((x (uiop:getenv "XDG_RUNTIME_DIR")))
    (if x
        (merge-pathnames "letibot/" (pathname (concatenate 'string x "/")))
        (merge-pathnames "letibot/"
                         (pathname (format nil "/run/user/~d/" (sb-posix:getuid)))))))

(defun discover-daemons ()
  "Every daemon this user runs, as decoded plists of their .json files, the
one named by $LETIBOT_SOCKET first when set — that is the daemon of the folder
the calling context belongs to. Read-only; a file that does not parse is
skipped, not fatal — a half-written json from a daemon that is starting up
must not take a head down."
  (let* ((plists (loop for f in (ignore-errors
                                 (directory (merge-pathnames "*.json" (daemon-dir))))
                       for plist = (ignore-errors (json-decode (uiop:read-file-string f)))
                       when plist collect plist))
         (mine (uiop:getenv "LETIBOT_SOCKET")))
    (if mine
        (let ((hit (find mine plists :key (lambda (p) (getf p :socket)) :test #'string=)))
          (if hit (cons hit (remove hit plists)) plists))
        plists)))
