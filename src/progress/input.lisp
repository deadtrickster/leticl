;;;; input — input helpers
;;;;
;;;; Split out of `progress.lisp`, which was one 409-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------ input helpers ;;;

(defun spinner (elapsed-ms)
  "A frame chosen from ELAPSED TIME, not from a frame counter.

Neither is evidence the turn is progressing — a counter proves the render loop
is alive and a clock proves the clock is alive — so the caller is expected to
stop calling this when the turn stops, rather than to read the frame as proof
of anything."
  (let ((frames "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"))
    (char frames (mod (floor (or elapsed-ms 0) 80) (length frames)))))

(defvar *fixed-clock-ms* nil
  "When non-NIL, what `internal-real-time-ms` answers, for everything.

There for `--replay --no-tty`, whose whole contract is *same file in, same bytes
out*. Two places read this clock while FOLDING a recorded log — the turn's start
time (`session.lisp`, on `turn_started`) and a call's start and end
(`note-call-started`) — and both end up on the screen as a duration, so a replay
on the real clock answers `· 0ms` on one run and `· 1ms` on the next and every
comparison against the reference is one row noisier than it should be. Measured:
that is the only nondeterminism a fold has; the rest of a frame is a function of
the file.

NIL everywhere else, so a running head, a paced tty replay and the tests that
measure real elapsed time are untouched. Bound, never assigned: a clock frozen by
a `setf` that an error skipped past would be a head whose spinner never turns.")

(defun internal-real-time-ms ()
  "The monotonic clock in milliseconds, or `*fixed-clock-ms*` when one is bound.

`get-universal-time` is one-second resolution, which is fine for a filesystem
timestamp and wrong for anything a person watches — a five-second window measured
in whole seconds is a four-to-five-second window. This is the clock the ESC
decoder and the stall line both need."
  (or *fixed-clock-ms*
      (round (* 1000 (/ (get-internal-real-time) internal-time-units-per-second)))))

