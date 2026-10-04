;;;; bar — the bar
;;;;
;;;; Split out of `progress.lisp`, which was one 409-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; --------------------------------------------------------------- bar ;;;

(defparameter +eighths+ #("" "▏" "▎" "▍" "▌" "▋" "▊" "▉" "█")
  "Eighth-of-a-cell fill, empty to full; index is the number of eighths.

From the reference, and worth having: a 20-column bar over a 40,000-token
prompt advances one cell per 2,000 tokens, so at whole-cell resolution a bar
that is genuinely moving looks frozen for seconds at a time — the exact
impression a progress display exists to prevent.")

(defun progress-bar (p cols)
  "A three-segment bar `cols` columns wide.

    ▐████████▓▓▓▓▍░░░░░▌
     ^cached  ^computed ^remaining

The cached run is drawn differently from the computed run on purpose. A
two-colour bar answers \"how far along\"; this also answers \"how much of this did
the prefix cache save me\", which is the question the whole prompt pipeline is
optimising for. The three runs are three different GLYPHS as well as three
colours, so the information survives a terminal with none."
  (let* ((cols (max 4 (or cols 0)))
         (inner (max 0 (- cols 2)))
         (total (or (getf p :total) 0)))
    (if (or (zerop total) (zerop inner))
        (format nil "▐~a▌" (make-string inner :initial-element #\░))
        (let* ((frac (lambda (n) (/ (float (min (or n 0) total)) total)))
               (done-e (min (round (* (funcall frac (getf p :processed)) inner 8))
                            (* inner 8)))
               ;; the cache boundary in whole cells, never past the moving edge
               (cached (min (floor (* (funcall frac (getf p :cache)) inner))
                            (floor done-e 8)))
               (full (- (floor done-e 8) cached))
               (rem (mod done-e 8))
               (partial (if (plusp rem) 1 0))
               (rest (- inner cached full partial)))
          (concatenate 'string
                       "▐"
                       (make-string cached :initial-element #\█)
                       (make-string (max 0 full) :initial-element #\▓)
                       (if (= partial 1) (aref +eighths+ rem) "")
                       (make-string (max 0 rest) :initial-element #\░)
                       "▌")))))

