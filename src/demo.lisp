;;;; demo.lisp — paint one real frame on the real terminal: the M1 exit
;;;; criterion (PLAN.md §10). Not a test; a thing you look at.

(in-package #:leticl)

(defun demo (&key (cols 80) (rows 24))
  (unless (plusp (%isatty 1))
    (error "demo paints on the real terminal — run it on a tty, not a pipe"))
  (multiple-value-bind (in out) (make-tty-streams)
    (declare (ignore in))
    (with-tui-terminal (out)
      (let ((s (make-screen cols rows))
            (title (style-index '(:bold t :fg :cyan)))
            (dim (style-index '(:fg :bright-black))))
        (screen-put-string s 0 2 "leticl — the letibot head, in Common Lisp" title)
        (screen-put-string s 1 2 "cell buffer + diff painter, protocol 18 ready" dim)
        ;; a box, drawn the way render will draw chrome
        (screen-put s 3 2 #\+ 0)
        (dotimes (i (- cols 5)) (screen-put s 3 (+ 3 i) #\─ 0))
        (screen-put s 3 (1- cols) #\+ 0)
        (screen-put-string s 4 2 "CJK: 中文テスト  emoji: 🌍🚀  combining: é" 0)
        (screen-put-string s 6 2 "wide chars occupy two cells; the painter" dim)
        (screen-put-string s 7 2 "moves in runs and tracks style across the frame" dim)
        (paint-full s out)
        (move-to out (1- rows) 0)
        (sleep 2)))))
