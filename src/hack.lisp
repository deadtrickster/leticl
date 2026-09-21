;;;; hack.lisp — the live-modification surface, the reason this rewrite exists
;;;; (PLAN.md §8). Each head listens on its own unix socket; a line `eval <form>`
;;;; evaluates in this image and the change is on the next frame, because the
;;;; eval marks the head dirty and the loop repaints when dirty.
;;;;
;;;; Trust: this is arbitrary code execution in the head, by design — the same
;;;; trust a person at a REPL has and the same trust the daemon's exec tool
;;;; already grants. Per-user socket, mode 0600, documented loudly in
;;;; HACKING.md rather than hidden.

(in-package #:leticl)

(defun hack-socket-path (&optional (pid (sb-posix:getpid)))
  (merge-pathnames (format nil "tui-~d.sock" pid)
                   (pathname (concatenate 'string (runtime-dir) "/"))))

(defun hack-start (head)
  "Listen and accept. A head that cannot take its hack socket still runs —
the TUI works without it; only the live-modification is lost."
  (handler-case
      (let* ((path (hack-socket-path))
             (listener (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (ensure-directories-exist path)
        (ignore-errors (delete-file path))
        (sb-bsd-sockets:socket-bind listener (namestring path))
        (sb-bsd-sockets:socket-listen listener 8)
        (sb-posix:chmod (namestring path) #o600)
        (setf (head-hack-listener head) listener
              (head-hack-path head) path
              (head-hack-thread head)
              (sb-thread:make-thread
               (lambda () (hack-accept-loop head))
               :name "leticl hack listener"))
        path)
    (error (e)
      (say head (format nil "hack socket unavailable: ~a" e))
      nil)))

(defvar *hack-accept-errors* 0
  "Accept calls that failed and were retried, over this head's life.

**A COUNT, not a silence**, and it is on `/status` beside `unreadable` for the reason
that row exists: a head that has stopped being evaluatable and has not said so is
indistinguishable from a head nobody has asked. A `defvar` rather than a slot (a
struct change is a restart) and NOT reset by a snapshot — it counts this process's
lifetime.")

(defun hack-accept-loop (head)
  "Accept eval connections until the LISTENER IS GONE, and for no other reason.

This read `(error () (return))`: ANY accept error ended the loop for the rest of the
head's life, and the socket file stayed on disk because `hack-stop` owns the
`delete-file` — a path with nothing listening behind it, which readers cannot tell
from a busy head. That is the same defect the session daemon already paid for and
wrote down (`sessionlog/src/server.rs`: *\"a failed accept is almost never a reason to
stop accepting\"*, and the lesson was that the errno could not even be named
afterwards).

**What ends this loop is the listener being cleared, which is `hack-stop` and nothing
else.** Everything else is retried and COUNTED. The error is not printed: this thread
runs under the TUI, and a line on `*error-output*` would paint over the frame and
desync it from the cell buffer — the hazard `hack-mute` documents from the other
direction."
  (loop
    (when (null (head-hack-listener head)) (return))
    (handler-case
        (let ((conn (sb-bsd-sockets:socket-accept (head-hack-listener head))))
          (sb-thread:make-thread (lambda () (hack-serve head conn))
                                 :name "leticl hack conn"))
      (error ()
        (unless (null (head-hack-listener head))
          (incf *hack-accept-errors*)
          ;; a persistent failure would otherwise spin a core
          (sleep 0.05))))))

(defun hack-serve (head conn)
  "One eval connection, until the client goes or the listener does.

**A CLIENT THAT HAS GONE IS A CLIENT, NOT A HEAD FAILURE.** The `write-line` and
`force-output` here were unguarded, and the whole body ran in a thread made by
`hack-accept-loop` — so a client that vanished between its request and its reply
signalled `BROKEN-PIPE` out of a NON-MAIN thread, and in an image saved with
`--disable-debugger` an unhandled error in any thread QUITS THE PROCESS.

MEASURED, and it is not hypothetical (`tools/evaldrop.py` in the notes below): open
the socket, send `eval (progn (sleep 1) :answered)`, close without reading, and the
head is dead before the sleep is over —

    round 1: head alive after the client vanished mid-reply: False
    VERDICT: THE HEAD IS DEAD
    ... (HACK-SERVE) ... (SB-IMPL::%WRITE-LINE with the reply for the ok case ...)
    unhandled condition in --disable-debugger mode, quitting

That is a `tui-eval` interrupted at the wrong moment — Ctrl-C in the middle of a push,
a terminal that closed, a command that was killed — taking the operator's SESSION with
it, and the eval socket is the surface the whole live-modification contract rests on.

`unwind-protect` was already here and it is not the fix: it closes the connection on
the way out and then RE-RAISES, which is why the process died rather than the
connection. The guard has to be a `handler-case`."
  (unwind-protect
       (handler-case
           (let ((stream (sb-bsd-sockets:socket-make-stream
                          conn :input t :output t :element-type 'character
                          :external-format :utf-8 :buffering :line)))
             (let ((*package* (find-package :leticl))
                   (*head* head))
               (loop
                 (let ((line (read-line stream nil nil)))
                   (unless line (return))
                   ;; **THE REPLY IS THE ONLY THING THAT CAN MEET A GONE CLIENT.** The
                   ;; read above returns NIL for a clean close; this is the other
                   ;; half, and it ends THIS connection rather than the head.
                   (handler-case
                       (progn (write-line (hack-handle head line) stream)
                              (force-output stream))
                     (error () (return)))))))
         ;; anything the eval itself could not survive: this connection is over, the
         ;; head is not. Not printed — see `hack-accept-loop` on why a line on the
         ;; error stream under a TUI is worse than a silence.
         (error () nil))
    (ignore-errors (close conn))))

(defun hack-mute (condition)
  "Swallow a compiler note. The eval's reply travels the socket; *standard-output*
 is the TUI, so a note printed there paints over the render and desyncs the
 terminal from the cell buffer — and /cells, which sends the cell buffer, then
 cannot show what the operator actually sees (measured: an eval with a typo put
 SBCL's compile report on the operator's screen)."
  (declare (ignore condition))
  nil)

(defun hack-handle (head line)
  "One request, one JSON reply. `eval <form>` — the rest of the line is one
s-expression, read and evaluated in :leticl with *head* bound. Compiler notes
and print side-effects are swallowed: the reply goes to the socket, and a leak
to *standard-output* would corrupt the TUI and desync it from the screen."
  (let ((start (get-internal-real-time)))
    (flet ((ms () (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)))
      (handler-case
          (progn
            (unless (uiop:string-prefix-p "eval " line)
              (error "only `eval <form>` is spoken here"))
            (let* ((form (read-from-string (subseq line 5)))
                   (value (let ((*standard-output* (make-string-output-stream))
                                (*error-output* (make-string-output-stream)))
                            (handler-bind ((style-warning #'hack-mute)
                                           (warning #'hack-mute))
                              ;; **Hold the paint lock for the whole eval.** The
                              ;; push is what makes this surface usable, and
                              ;; without serialisation it races the frame: a
                              ;; `defun` can land while `%render-and-paint` is
                              ;; halfway through, so an in-flight call reaches a
                              ;; function whose definition just changed — an
                              ;; error in the MAIN thread, which quits the head.
                              ;; Measured twice, at a different file each time.
                              ;;
                              ;; An eval must NOT paint: taking this lock again
                              ;; inside one deadlocks. Nothing here does.
                              (sb-thread:with-mutex ((paint-lock))
                                (eval form))))))
              ;; visible immediately is a property of the loop: the eval marks
              ;; the head dirty, the loop repaints on its next tick
              (setf (head-dirty head) t)
              (format nil "{\"ok\":true,\"value\":~a,\"ms\":~a}"
                      (json-encode-to-string (prin1-to-string value))
                      (ms))))
        (error (e)
          (format nil "{\"ok\":false,\"error\":~a}"
                  (json-encode-to-string (prin1-to-string e))))))))

(defun hack-stop (head)
  ;; **the slot is CLEARED, and that is what the accept loop watches for.** The loop
  ;; cannot ask a closed socket whether it is closed, so the flag is the slot itself:
  ;; nil it first, then close, so an accept blocked on the old listener returns to a
  ;; loop that has already decided to stop.
  (let ((listener (head-hack-listener head)))
    (setf (head-hack-listener head) nil)
    (when listener
      (ignore-errors (sb-bsd-sockets:socket-close listener))))
  (when (head-hack-path head)
    (ignore-errors (delete-file (head-hack-path head)))))

(defun hack-socket-path* ()
  "The path of the running head's hack socket, for tui-eval's --list."
  (when (and *head* (head-hack-path *head*))
    (namestring (head-hack-path *head*))))

(defun list-live-heads ()
  "Every leticl head this user runs, by its hack socket."
  (loop for f in (directory (merge-pathnames "tui-*.sock"
                                             (pathname (concatenate 'string (runtime-dir) "/"))))
        collect (namestring f)))
