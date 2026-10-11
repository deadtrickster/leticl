;;;; wire.lisp — newline-delimited JSON over any stream, ported from
;;;; crates/sessionlog/src/wire.rs. The framing knows nothing about the
;;;; transport: a unix socket today, anything with a stream tomorrow.
;;;; Blank lines are skipped; EOF is detach, not an error; a malformed frame
;;;; carries the offending line, because "bad frame" without the frame is a
;;;; shrug where a complaint should be.

(in-package #:leticl)

(define-condition wire-error (error)
  ((line :initarg :line :reader wire-error-line)
   (detail :initarg :detail :reader wire-error-detail))
  (:report (lambda (c s)
             (let ((line (wire-error-line c)))
               (format s "malformed frame (~a): ~a"
                       (wire-error-detail c)
                       (subseq line 0 (min 200 (length line))))))))

(defun read-frame (stream)
  "One NDJSON line, blank lines skipped. Second value :eof when the peer
closed — for a head that is detach, never an error (wire.rs:30)."
  (loop
    (let ((line (read-line stream nil nil)))
      (cond ((null line) (return (values nil :eof)))
            ((zerop (length (string-trim '(#\space #\tab #\return) line)))) ; skip
            (t (return (values (string-right-trim '(#\return) line) nil)))))))

(defparameter *write-timeout-secs* 5
  "How long a frame write waits for the socket to take bytes before it is given up.

**THE HEAD'S WHOLE MAIN THREAD IS ON THE OTHER SIDE OF THIS NUMBER.** Every ack, every
screen answer, every `tick-peek` read and the detach at `/quit` are written from the
loop, and `write(2)` on a stream socket blocks once the kernel's send buffer is full —
about 200 KB on this box. A daemon that stopped reading (wedged, paused under a debugger,
stopped with SIGSTOP) fills that buffer and then the head stops: no paint, no keys, and
`/quit` hangs on its own detach, with nothing on the screen saying why. The reconnect
path cannot help, because the loop that would run it is the thing that is blocked.

Five seconds, the same number the eval channel already waits for its lock
(`+hack-lock-timeout+`): a daemon that has taken nothing for five seconds is not slow, it
is gone, and the honest reading is a disconnect — which is what `%send` makes of the
condition this signals. Bound at the detach to one second (see `run`), because a head that
is leaving owes the operator their terminal more than it owes a dead daemon a goodbye.

A `defparameter` so a test and a live head can set it; `NIL` waits for ever, which is
what the code did before 2026-10-11 and what nothing should ask for again.")

(define-condition write-timeout (error)
  ((seconds :initarg :seconds :reader write-timeout-seconds))
  (:report (lambda (c s)
             (format s "the socket took no bytes for ~as — the daemon has stopped reading"
                     (write-timeout-seconds c)))))

(defun write-frame (line stream &key (timeout *write-timeout-secs*))
  "One line + newline, flushed now: a head that renders in real time cannot
wait for a buffer to fill (wire.rs:88).

**And the write is BOUNDED, not just flushed.** Before the bytes go out the fd is asked
whether it can take any, for at most TIMEOUT seconds (`sb-sys:wait-until-fd-usable`,
without `serve-event` — this is a plain poll). A fd that cannot signals `write-timeout`,
which is an `error` so `%send`'s existing guard turns it into a disconnect and a status
note. The frame is NOT written: a write into a full buffer is the block this exists to
prevent, and a daemon that has stopped reading will not read a frame it was handed late.

What this bounds is the common case — a peer that takes NOTHING. A frame larger than the
free space in a buffer that is nearly full can still block for its remainder; the kernel
reports writable at a low-water mark and not at the frame's size. That case needs a writer
thread, and it is written down here rather than hidden behind the word \"bounded\".

A stream that is not an fd-stream — a string stream in a test, the replay's sink — is
written at once: there is no fd to ask, and nothing on the other end to stall."
  (when (and timeout (typep stream 'sb-sys:fd-stream))
    (unless (sb-sys:wait-until-fd-usable (sb-sys:fd-stream-fd stream) :output timeout nil)
      (error 'write-timeout :seconds timeout)))
  (write-string line stream)
  (write-char #\newline stream)
  (force-output stream))
