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

(defparameter +hack-lock-timeout+ 5
  "Seconds an eval will wait for the paint lock before giving up and saying so.

Five, because a legitimate eval holds it for milliseconds — `--tree` re-evaluates fifty
forms in well under one — so anything near this number is a wedge and not a slow push. See
`%with-paint-lock` for the measurement that put a deadline here at all.")

(defmacro %with-paint-lock ((mutex) &body body)
  "Run BODY holding MUTEX, or signal a clear error after `+hack-lock-timeout+`.

**A macro rather than `with-mutex`, because `with-mutex` cannot time out** and a lock held
by a thread that is itself blocked is held for the life of the process. Preferring
`sb-thread:grab-mutex` with `:timeout` keeps the safety property that put the lock here (no
redefinition lands mid-frame) while removing the one it did not have (a single bad eval
taking the whole channel with it).

The fallback is deliberate and not tidiness: `grab-mutex`'s keyword set differs across SBCL
versions, and a head that cannot time out should still be able to eval — the wedge is the
lesser evil next to a live-modification surface that refuses to work at all.

**THE WEDGE THIS DEADLINE WAS ADDED FOR, MEASURED on the live head 2026-09-24.** One `%send`
issued from inside a probe — which held this lock and was therefore waiting on the head's own
loop to write — did exactly that. The channel was dead for an hour: the socket LISTENED but
never ACCEPTED again (backlog full, `connect` returning EAGAIN), and every push in that hour was
silently discarded while the head went on painting the screen, so the pushes looked applied.
A deadline turns that permanent wedge into ONE bad eval that says so. It does not free the lock
— nothing can, the thread is stuck — but the SURFACE survives: the next eval is told the channel
is blocked rather than joining it."
  (let ((m (gensym "MUTEX")) (got (gensym "GOT")))
    `(let ((,m ,mutex)
           (,got nil))
       ;; **`:timeout` and NOT `:wait-p`** — the latter is not a keyword on this SBCL and an
       ;; unknown keyword is a WARNING, which this tree's build treats as fatal (measured:
       ;; the whole compile aborted). VERIFIED on this box, across two threads: a second
       ;; `grab-mutex` on a held lock with `:timeout` answers NIL rather than blocking,
       ;; which is the property the deadline rests on.
       ;;
       ;; The `handler-case` is for a Lisp that has neither keyword: taking the lock the old
       ;; way is the lesser evil next to a live-modification surface that refuses to work.
       (setf ,got
             (handler-case (sb-thread:grab-mutex ,m :timeout +hack-lock-timeout+)
               (error () (sb-thread:grab-mutex ,m) t)))
       (unless ,got
         (error "the eval channel is BLOCKED on the paint lock (waited ~as): an earlier ~
                 eval is wedged holding it, very likely blocked on something that needs the ~
                 head's own loop. This form did NOT run. Nothing pushed since the wedge has ~
                 run either. Restart the head — it resumes from the store."
                +hack-lock-timeout+))
       (unwind-protect (progn ,@body)
         (sb-thread:release-mutex ,m)))))

(defun hack-eval-form (head form)
  "FORM evaluated in this head's own image: `(values VALUE CONDITION MS)`.

**ONE PATH, TWO SURFACES.** The eval socket (`hack-handle`) and the `/lisp` pane (`repl.lisp`) both
ask THIS, so a form that works at one works at the other — and the two cannot come to disagree about
what `*standard-output*` is, which conditions are muted, or whether an eval counts as a PUSH.

**THE PAINT LOCK IS THE CALLER'S, and that asymmetry is the whole reason this is a function.** The
socket takes it for the eval's duration, because its thread is not the paint thread and a `defun`
landing mid-frame is an error in the MAIN thread — which with `--disable-debugger` is a dead head.
The pane IS the paint thread, so it must not take it: taking `paint-lock` inside an eval deadlocks,
which is what this file says at length two functions down. The lock lives with the caller; this is
the part that must be identical.

Output and warnings are swallowed for BOTH callers. The reply is what a reader reads, and a leak to
`*standard-output*` corrupts the TUI it is standing on.

**A PUSH INVALIDATES WHAT CODE DERIVED, FROM EITHER DOOR.** The generation bump is here rather than
at the socket because `/lisp` can `defun` exactly as `tui-eval --file` can, and a cache that holds
values the previous code produced does not know which door the redefinition came through — that is
`*code-generation*`'s own paragraph, and it is why this is not the socket's private step. The bump is
`boundp`-guarded for the reason recorded there: this file loads before `head.lisp`.

**THE ERROR ARM DIRTIES THE HEAD TOO.** A condition is an entry in the pane and a fact on the
screen; the socket's own reader gets it in the reply, but the head is the surface that draws it, and
an eval that raised is the one an operator most needs to see."
  (let ((start (get-internal-real-time)))
    (flet ((ms () (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)))
      (handler-case
          (let ((value (let ((*standard-output* (make-string-output-stream))
                             (*error-output* (make-string-output-stream)))
                         (handler-bind ((style-warning #'hack-mute)
                                        (warning #'hack-mute))
                           (eval form)))))
            (setf *code-generation*
                  (1+ (if (boundp '*code-generation*) *code-generation* 0)))
            (setf (head-dirty head) t)
            (values value nil (ms)))
        (error (e) (setf (head-dirty head) t) (values nil e (ms)))))))

(defun hack-handle (head line)
  "One request, one JSON reply. `eval <form>` — the rest of the line is one
s-expression, read and evaluated in :leticl with *head* bound. Compiler notes
and print side-effects are swallowed: the reply goes to the socket, and a leak
to *standard-output* would corrupt the TUI and desync it from the screen."
  (handler-case
      (progn
        (unless (uiop:string-prefix-p "eval " line)
          (error "only `eval <form>` is spoken here"))
        (let ((form (read-from-string (subseq line 5))))
          ;; the lock is TAKEN HERE and not in `hack-eval-form` — see its docstring: the pane, which
          ;; shares the eval, is the paint thread and cannot take it
          (multiple-value-bind (value condition ms)
              (%with-paint-lock ((paint-lock)) (hack-eval-form head form))
            (if condition
                (format nil "{\"ok\":false,\"error\":~a}"
                        (json-encode-to-string (prin1-to-string condition)))
                (format nil "{\"ok\":true,\"value\":~a,\"ms\":~a}"
                        (json-encode-to-string (prin1-to-string value))
                        ms)))))
    (error (e)
      (format nil "{\"ok\":false,\"error\":~a}"
              (json-encode-to-string (prin1-to-string e))))))

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
