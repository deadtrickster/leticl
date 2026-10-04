;;;; prefill — prefill: how far the prompt has got
;;;;
;;;; Split out of `progress.lisp`, which was one 409-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ----------------------------------------------------------- prefill ;;;

;; A "Prefill" is the plist the daemon sends; these are the four questions the
;; display asks of it. Values are clamped to TOTAL because a cache can be
;; reported larger than the prompt it cached (a stale row, a resumed session),
;; and a bar drawn past its own end is a lie about progress.

(defun prefill-fraction (p)
  "How much of the prompt is resident, 0.0 to 1.0."
  (let ((total (or (getf p :total) 0)))
    (if (zerop total)
        0.0
        (/ (float (min (or (getf p :processed) 0) total)) total))))

(defun prefill-cached-fraction (p)
  "How much of the prompt cost nothing — the headline number for this project:
`f_keep` observed live rather than reconstructed after the turn."
  (let ((total (or (getf p :total) 0)))
    (if (zerop total)
        0.0
        (/ (float (min (or (getf p :cache) 0) total)) total))))

(defun prefill-computed (p)
  "Tokens actually computed this turn."
  (max 0 (- (or (getf p :processed) 0) (or (getf p :cache) 0))))

(defun prefill-rate (p)
  "Prefill throughput in tokens/second, or NIL before there is enough to divide.

Measured over `prefill-computed`, not over `processed`: the cache hit divided by
the wall clock produces a number in the hundreds of thousands and it is not a
speed, it is an artefact. And a rate needs more than a moment of elapsed time —
under 50ms the divisor is noise."
  (let ((ms (or (getf p :time-ms) 0))
        (computed (prefill-computed p)))
    (when (and (>= ms 50) (plusp computed))
      (/ (* (float computed) 1000.0) ms))))

(defun prefill-eta-ms (p)
  "Estimated milliseconds to the end of the prefill, or NIL with no rate yet.

Assumes the remaining tokens all have to be computed, which they do —
everything past `processed` is by definition not in the cache."
  (let ((rate (prefill-rate p)))
    (when rate
      (let ((left (max 0 (- (or (getf p :total) 0) (or (getf p :processed) 0)))))
        (if (zerop left)
            0
            (round (/ (* (float left) 1000.0) rate)))))))

