;;;; stop — a stop that is an OUTCOME: stopping the daemon, and what it answers
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ----------------------------------------- a stop that is an OUTCOME ;;;
;;;
;;; **A REQUEST IS NOT AN OUTCOME.** The operator chose *leave and stop the
;;; daemon* — twice — and the daemon stayed. The head that asked was already
;;; gone, so nothing could tell them, and nothing ever asked again.
;;;
;;; MEASURED, because the first fix here was a guess and was wrong. The old code
;;; sent `Stop` and set `head-running` nil in the same breath, so the socket was
;;; closed while the daemon was still answering. A scratch daemon, the release
;;; build, the head's own sequence byte for byte:
;;;
;;;     wrote stop, wrote detach, closed the socket — no pause
;;;     daemon alive: T          socket still on disk: T
;;;     snapshot warnings: ('daemon_stopping')   <- THE STOP WAS RECEIVED
;;;     head connection ended: wire io: Broken pipe (os error 32)
;;;
;;; and the same `Stop`, sent by a client that stays for the answer:
;;;
;;;     <- {"frame":"accepted","note":"stopping"}
;;;     <- {"frame":"bye","reason":"daemon shutting down"}
;;;     daemon gone after 232 ms; socket present: F; exit code 0
;;;
;;; So the frame is not lost: it arrives, and the daemon publishes its
;;; `daemon_stopping` warning for it. What is lost is the following write — the
;;; daemon acks into a socket with no reader, takes `EPIPE`, and
;;; `registry.close()` sits BEHIND that write
;;; (`sessionlog/src/server.rs:776-778`), so the stop the daemon *heard* is never
;;; acted on. A one-millisecond pause before the close is enough to save it:
;;; close 0 ms after the stop → STUCK; 1 ms → gone in 221 ms. A race, and the
;;; head always lost it.
;;;
;;; **So the head stays and watches — it does not wait on its own frame.** The
;;; loop keeps draining, keeps painting, keeps SAYING what it is waiting for, and
;;; the wait has a deadline. Past the deadline the head leaves anyway and says on
;;; stderr that it did, naming the pid and the way to stop it from outside. *The
;;; head does not exit until the daemon has actually gone, or until it can say
;;; that it has not.*
;;;
;;; **The fact waited on is the daemon's ABSENCE, not its acknowledgement.** Its
;;; `Accepted` and its `Bye` say it heard, which is a different and weaker
;;; statement, and the row says which one is true.

(defparameter +stop-wait-ms+ 5000
  "How long this head waits for a daemon it asked to stop.

Measured, not guessed: a daemon that takes the stop answers `Accepted`, sends
`bye`, exits and removes its socket **232 ms** later (scratch daemon, release
build — `tools/stop-lab/proof.py`). Five seconds is twenty times the measured
shutdown and still short enough that a daemon which will not go does not hold the
operator's terminal: the case this exists for is a daemon that never goes at all,
and no value of this number waits *that* out.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defvar *stop-request* nil
  "`(:asked-at MS :deadline MS :socket PATH :pid N :heard TEXT :shown TENTHS)`
while this head has asked the daemon to stop and is waiting to see it go, else NIL.

Every key is PRESENT from the start, and that is load-bearing: `tick-stop-request`
writes `:heard` and `:shown` through `(setf (getf …))`, which mutates the cons in
the list when the key is there and silently rebinds a local when it is not — the
trap `%call-put` documents. Keys with nothing in them yet are NIL, not absent.

A `defvar`, so a push can introduce this state on a running head: the wait is
exactly the kind of thing that gets fixed live.")

(defun %daemon-pid-for (socket-path)
  "The pid the launcher wrote beside SOCKET-PATH, or NIL.

`~/bin/letibot` leaves a `<socket>.json` in the run dir carrying the daemon's pid
— the record `discover-daemons` reads — and it is the only place a head can learn
a pid from. A daemon started by hand has no record: then the pid is unknown and
`daemon-gone-p` falls back to the socket rather than inventing one."
  (when (and socket-path (probe-file socket-path))
    (let ((json (make-pathname :type "json" :defaults (pathname socket-path))))
      (when (probe-file json)
        (getf (ignore-errors (json-decode (uiop:read-file-string json))) :pid)))))

;;; **THE OPERATOR'S FIVE SECONDS, AND WHY `%pid-state` EXISTS.** Their words, 2026-10-04:
;;; *"i still wait full 5 seconds when ask for daemon stop"*. The launcher starts the daemon and
;;; then stays alive running the head, so the daemon it started is never reaped — its socket is
;;; gone, its process runs nothing, and `/proc/<pid>` is STILL THERE in state `Z`. This function's
;;; caller read the entry's EXISTENCE as "not gone", so the tick never saw its first ending and
;;; waited out the whole `+stop-wait-ms+`: five seconds, twenty times the 232 ms shutdown the
;;; daemon's own measurement records. A zombie is gone; what is left is a corpse nobody collected.
;;;
;;; **The parsing detail is the one that punishes splitting on whitespace**: `/proc/<pid>/stat`'s
;;; SECOND field is the executable's name in parentheses and it may contain spaces AND parentheses,
;;; so the fields are read from AFTER THE LAST `)` rather than split — a process named `a b)` would
;;; otherwise shift every field by one and this would return the wrong letter, silently, in a
;;; liveness test.
(defun %pid-state (pid)
  "PID's single-letter state from the proc entry's stat line, or NIL when it has no entry.

NIL is the REAPED case as well as the never-existed one: the entry can vanish between the read
and the parse, and the caller's answer for both is the same, so they are the same here."
  (let ((line (ignore-errors (uiop:read-file-string (format nil "/proc/~d/stat" pid)))))
    (when line
      (let ((close (position #\) line :from-end t)))
        (when close
          (let* ((rest (string-left-trim '(#\space) (subseq line (1+ close))))
                 (space (position #\space rest)))
            (subseq rest 0 (or space (length rest)))))))))

(defun daemon-gone-p (socket-path pid)
  "Has the daemon actually gone?

**The pid first, because that is the fact the operator asked for** — and because a
socket FILE outlives a daemon that was killed: a `-9` leaves the path on disk, so
answering \"not gone\" for a process that is not there is the same lie the other way
round. With no pid (a daemon nobody wrote a record for) the socket is all there is,
and \"nothing is listening there\" is the honest reading of it."
  (cond ((and (integerp pid) (plusp pid))
         (let ((state (%pid-state pid)))
           (or (null state) (string= "Z" state))))
        (t (not (and socket-path (probe-file socket-path))))))

(defun begin-stop-request (head)
  "Ask the daemon to stop, and REMEMBER that an answer is owed. Returns the request.

**This is where the old code set `head-running` nil, and that is the whole bug**:
the frame went out and the process left in the same breath, so whether the daemon
ever saw it was a race against this head's own shutdown. Now the ask is recorded
and `tick-stop-request`, in the loop, decides when the request has become an
outcome. `write-frame` is `force-output`, so the stop itself is on the socket
before this returns — queued-and-dropped is not the failure mode here."
  (%send head (make-stop (session-expected-seq (head-session head)) "leticl"))
  (setf *stop-request*
        (list :asked-at (internal-real-time-ms)
              :deadline (+ (internal-real-time-ms) +stop-wait-ms+)
              :socket (head-socket-path head)
              :pid (%daemon-pid-for (head-socket-path head))
              :heard nil
              :shown nil)
        (head-dirty head) t)
  *stop-request*)

(defun heard-stop (head text)
  "Record what the daemon ANSWERED a pending stop with. Returns the request.

Called from the `accepted` and `bye` arms, whose normal job is to end things:
during a pending stop they are the acknowledgement, not the outcome, and the tick
is what ends the wait. The first answer wins — a `Bye` after an `Accepted` is the
same fact twice, and the row reads better naming the one that came first."
  (when (and *stop-request* (null (getf *stop-request* :heard)))
    (setf (getf *stop-request* :heard) (or text "acknowledged")
          (head-dirty head) t))
  *stop-request*)

(defun stop-wait-text ()
  "The sentence the head is waiting under, or NIL when nothing is pending.

Two states, because they are two different facts: an ask nobody has answered, and
an ask the daemon has answered. Neither is \"gone\", which is why the wait
continues after the second one."
  (when *stop-request*
    (let* ((req *stop-request*)
           (waited (- (internal-real-time-ms) (getf req :asked-at)))
           (heard (getf req :heard)))
      (format nil "the daemon was asked to stop~@[ and answered \"~a\"~] · waiting for it to go — ~a of ~a"
              heard (duration waited) (duration +stop-wait-ms+)))))

(defun %daemon-said (req)
  "How the two farewells NAME the daemon: the pid and the socket, whichever are known.

**Both, when both are known**, because the failure this exists for is a daemon
nobody could identify: the pid is what `ps` and `letibot --stop` take, and the
socket is what a head started by hand has instead of a pid."
  (let ((pid (getf req :pid)) (socket (getf req :socket)))
    (cond ((and pid socket) (format nil "pid ~d, socket ~a" pid socket))
          (pid (format nil "pid ~d" pid))
          (socket (format nil "socket ~a" socket))
          (t "no pid and no socket record"))))

(defun %stop-gone-said (req waited)
  "The farewell when the daemon DID go: the outcome the operator asked for."
  (format nil "the daemon has stopped (~a), ~a after it was asked."
          (%daemon-said req) (duration waited)))

(defun %stop-timeout-said (req)
  "The farewell when it did NOT: the requirement's third clause, said on stderr
where it survives the alternate screen — how long, which daemon, and the verb that
stops it from outside."
  (format nil "the daemon was asked to stop ~a ago and has NOT stopped (~a). `letibot --stop` stops it from outside; this head is leaving it running."
          (duration (- (internal-real-time-ms) (getf req :asked-at)))
          (%daemon-said req)))

(defun tick-stop-request (head)
  "One pass of the wait for a daemon this head asked to stop. T when it is over.

Three endings and no others: it is gone (the ask succeeded), the deadline passed
(it is not going, and the head leaves anyway **saying so**), or nothing is pending
and this does nothing.

The row is refreshed on the tenth of a second that CHANGED — so the seconds move
and the head is visibly alive rather than frozen, and not on every pass, which
would paint forty-three frames a second to say the same thing."
  (when *stop-request*
    (let* ((req *stop-request*)
           (now (internal-real-time-ms))
           (waited (- now (getf req :asked-at)))
           (tenths (floor waited 100)))
      (cond
        ((daemon-gone-p (getf req :socket) (getf req :pid))
         (setf (head-farewell head) (%stop-gone-said req waited)
               (head-running head) nil)
         t)
        ((>= now (getf req :deadline))
         (setf (head-farewell head) (%stop-timeout-said req)
               (head-running head) nil)
         t)
        (t (unless (eql tenths (getf req :shown))
             ;; `:shown` is PRESENT, so this writes the cons the list already
             ;; holds rather than rebinding anything (see `*stop-request*`)
             (setf (getf req :shown) tenths
                   (head-dirty head) t))
           nil)))))

