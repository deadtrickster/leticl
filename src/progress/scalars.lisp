;;;; progress.lisp — the numbers a turn produces, said in a way a person reads.
;;;;
;;;; Ported from crates/ui/src/progress.rs. The point of the module is that a
;;;; prefill and a decode are the same wait to the person doing the waiting, so
;;;; they are said in the same words: `thousands` for a count, `duration` for a
;;;; time, and one bar that carries the cache split.
;;;;
;;;; Three deliberate refusals, all from the reference and all worth keeping:
;;;;
;;;;  · `thousands` is NOT a digit separator. A status line has no room for one,
;;;;    and `40.1k` reads faster than `40,132` when the digits past the first
;;;;    three are noise.
;;;;  · The rate is measured over COMPUTED tokens, never over `processed`:
;;;;    dividing the cache hit by the wall clock is not a speed, it is an
;;;;    artefact in the hundreds of thousands.
;;;;  · A number nobody measured is absent, not zero. No rate before there is
;;;;    enough elapsed time to divide by — `0.0 tok/s` would be a claim.
;;;;
;;;; `prompt_progress` arrives as a plist on the turn (`:total :cache
;;;; :processed :time-ms`), so these take it as one: wire-shaped state stays a
;;;; plist (PLAN.md D4).

(in-package #:leticl)

;;; ------------------------------------------------------------ scalars ;;;

(defun thousands (n)
  "`1234567` becomes `1.23M`, `12345` becomes `12.3k`. Not a separator."
  (let ((n (or n 0)))
    (cond ((<= n 9999) (format nil "~d" n))
          ((<= n 999999) (format nil "~,1fk" (/ n 1000.0)))
          (t (format nil "~,2fM" (/ n 1000000.0))))))

(defun duration (ms)
  "A duration a person reads at a glance: `840ms`, `2.5s`, `3m07s`, `1h05m`."
  (let ((ms (or ms 0)))
    (cond ((< ms 1000) (format nil "~dms" ms))
          ((< ms 60000) (format nil "~,1fs" (/ ms 1000.0)))
          ((< ms 3600000)
           (multiple-value-bind (m s) (floor (floor ms 1000) 60)
             (format nil "~dm~2,'0ds" m s)))
          (t (multiple-value-bind (h m) (floor (floor (floor ms 1000) 60) 60)
               (format nil "~dh~2,'0dm" h m))))))

