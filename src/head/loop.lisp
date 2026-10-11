;;;; loop — the loop, and the parts it is made of
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- the loop ;;;

(defun %drain (mailbox)
  (sb-concurrency:receive-pending-messages mailbox))

(defparameter *reconnect-connect-secs* 2
  "How long one reconnect attempt may sit in `connect(2)` before it is abandoned.

A unix-domain connect returns at once in every ordinary case — ENOENT, ECONNREFUSED, or a
connection — and blocks in exactly one: the daemon's listen backlog is full, which is a
daemon that has stopped accepting. Blocking there is the main thread blocking, and the
main thread is the head. `sb-ext:with-timeout`, not `sb-sys:with-deadline`: a deadline
fires only at Lisp's own blocking points and a syscall is not one; `with-timeout`
interrupts the thread, and the connect returns.

Two seconds, the same as the retry interval, so a head that is being refused this way
spends at most half its time waiting. The socket a timed-out connect leaves behind is
closed by its finalizer at the next GC — one descriptor per attempt, two seconds apart,
and said in the status line each time rather than leaked in silence.")

(defun %shutdown-fd (fd)
  "`shutdown(2)` both halves of socket FD, so a thread blocked in `read(2)` on it is
handed EOF now. Nothing but the fd is needed: the stream was made by
`socket-make-stream` and the socket object behind it was not kept."
  (ignore-errors
   (sb-alien:alien-funcall
    (sb-alien:extern-alien "shutdown" (function sb-alien:int sb-alien:int sb-alien:int))
    fd 2)))

(defun %retire-reader (head)
  "End the old connection's reader BEFORE its stream is closed, and then close it.

**Closing an fd-stream another thread is mid-`read-line` on is not safe in SBCL** — the
reader's buffer refill reads through the stream's fd slot while `close` is tearing the
stream down, and the two race. The reader is usually already dead by the time this runs
(its EOF is what asked for the reconnect), but *usually* is not the rule. So the socket is
SHUT DOWN first — `shutdown(2)` makes the blocked `read(2)` return 0, and the reader's EOF
arm posts `(:disconnected STREAM)` and returns on its own, which `%handle-frame` then
ignores as a stale reader's goodbye once `head-stream` is the new socket. The thread is
joined with a short deadline, and one that is still alive past it — blocked somewhere
that is not the read — is terminated, so no second reader can ever be reading a socket
this head has let go of. Only then is the stream closed."
  (let ((stream (head-stream head))
        (reader (head-reader head)))
    (when (typep stream 'sb-sys:fd-stream)
      (%shutdown-fd (sb-sys:fd-stream-fd stream)))
    (when (and reader (sb-thread:thread-alive-p reader)
               (not (eq reader sb-thread:*current-thread*)))
      ;; `:default` makes a timed-out join RETURN rather than signal, so the thread's own
      ;; liveness is what is asked afterwards — not the join's answer
      (ignore-errors (sb-thread:join-thread reader :default nil :timeout 0.5))
      (when (sb-thread:thread-alive-p reader)
        (ignore-errors (sb-thread:terminate-thread reader))
        (ignore-errors (sb-thread:join-thread reader :default nil :timeout 0.5))))
    (when stream
      (ignore-errors (close stream)))))

(defun %try-reconnect (head)
  "Detach is not abort; a dead socket is retried with the seq we had, which
is a resume — the gap arrives as events, or a Resync does (§13.2).

A head that is LEAVING does not reconnect. The loop's own `head-running` check
comes at the top of the next pass, which is one attach too late: a `Bye` and a
`/quit` both arrive mid-pass, and re-attaching to a daemon that just said
goodbye is how a final refusal became a two-second loop.

**The old reader is retired before the old stream is closed** (`%retire-reader`), and
**the connect is bounded** (`*reconnect-connect-secs*`) — both from the 2026-10-11
stability pass, and both about the same fact: this runs on the main thread, and
anything that blocks it blocks the head."
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
            (%retire-reader head)
            (let ((stream (sb-ext:with-timeout *reconnect-connect-secs*
                            (connect-unix (head-socket-path head)))))
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
        ;; `sb-ext:timeout` is a SERIOUS-CONDITION and not an ERROR, so it has its own arm —
        ;; left to the `error` arm it would have gone through the main thread's debugger hook
        ;; and ended the head.
        (sb-ext:timeout ()
          (say head (format nil "reconnect: the daemon did not accept within ~as — is it stopped?"
                            *reconnect-connect-secs*)))
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

