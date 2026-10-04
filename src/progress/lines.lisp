;;;; lines — the lines a turn produces
;;;;
;;;; Split out of `progress.lisp`, which was one 409-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; -------------------------------------------------------------- lines ;;;

(defun prefill-line (p cols)
  "The whole prefill line: `prefill 61% ▐████▓▓░░░▌ · 2.4k tok/s · ~12s left`.

The raw counts (`25.1k/41.2k tok · 92% cached`) are deliberately NOT here: the
header carries `ctx` and `cached%` live for the whole turn, and the same number
in two places is read once and doubted once. What the header cannot show — how
fast the expansion runs and how long is left — is what this keeps.

Degrades by dropping the LEAST useful field first as the terminal narrows: the
estimate, then the rate, then the bar — leaving `prefill 61%`, which is still
true. It never wraps: a status line that wraps scrolls the transcript by a row
every frame, and that reads as flicker."
  (let* ((cols (max 1 (or cols 1)))
         (pct (round (* (prefill-fraction p) 100)))
         (head (format nil "prefill ~d%" pct))
         (rate (awhen (prefill-rate p)
                 (format nil "~a tok/s" (thousands (round it)))))
         (eta (when (and (prefill-eta-ms p)
                         (< (or (getf p :processed) 0) (or (getf p :total) 0)))
                (format nil "~~~a left" (duration (prefill-eta-ms p)))))
         (barw (min 20 (floor cols 3)))
         (bar (progress-bar p barw)))
    (flet ((join (parts)
             (let ((s (format nil "~{~a~^ · ~}" (remove nil parts))))
               (string-right-trim " ·" (substitute #\space #\Nul s)))))
      (loop for candidate in (list (join (list head bar rate eta))
                                   (join (list head bar rate))
                                   (join (list head bar))
                                   head)
            when (<= (string-width candidate) cols)
              return candidate
            finally (return (truncate-to-width head cols))))))

(defun decode-line (predicted elapsed-ms cols)
  "The decode phase: how fast tokens are coming out.

Kept beside the prefill because the two phases are one wait to the person doing
the waiting, and a head that shows a bar and then nothing has just told them the
work stopped."
  (let* ((rate (if (and elapsed-ms (plusp elapsed-ms))
                   (/ (* (float (or predicted 0)) 1000.0) elapsed-ms)
                   0.0))
         (s (format nil "generating ~a tok · ~,1f tok/s · ~a"
                    (thousands predicted) rate (duration elapsed-ms))))
    (truncate-to-width s (max 1 (or cols 1)))))
