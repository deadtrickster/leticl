;;;; helpers.lisp — the four-line helpers a pane row is assembled from
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ------------------------------------------------------------- helpers ;;;
;;;
;;; Every pane below was measured against the reference's screen at 210x63
;;; (`scripts/compare-heads`, the `pane-*-lb.ans` captures), and these are the
;;; things every one of them needed: a plain-text WRAP, the `~` a path is written
;;; with, the short id, and the right-aligned row. The body's WIDTH, `pane-width`,
;;; is in render.lisp beside the gutter constants it reads.

(defun wrap-text (text cols)
  "TEXT to plain lines of at most COLS columns — `wrap` in the reference's
width.rs, over `wrap-segments` so the two wrappers here cannot break differently.

Each line is one string with its trailing space trimmed, because a painter that
erases to end of row would otherwise paint one column past the text."
  (mapcar (lambda (line) (apply #'concatenate 'string (mapcar #'car line)))
          (wrap-segments (list (cons text nil)) cols)))

(defun tilde-path (path)
  "PATH with `$HOME` written as `~` — the reference's `tilde`. NIL stays NIL."
  (let ((home (uiop:getenv "HOME")))
    (cond ((null path) nil)
          ((and home (plusp (length home))
                (>= (length path) (length home))
                (string= (subseq path 0 (length home)) home))
           (concatenate 'string "~" (subseq path (length home))))
          (t path))))

(defun short-id (id)
  "The last eight characters behind an ellipsis, or the whole of a short id —
`short_id` in the reference's registry.rs, which is what an unnamed session is
listed as."
  (let ((n (length id)))
    (if (<= n 10) id (format nil "…~a" (subseq id (- n 8))))))

(defun bytes-human (n)
  "`512 B`, `1.5 KB`, `2.0 MB` — the reference's `bytes_human` (render.rs:899)."
  (let ((k 1024))
    (cond ((< n k) (format nil "~d B" n))
          ((< n (* k k)) (format nil "~,1f KB" (/ n (float k 1d0))))
          ((< n (* k k k)) (format nil "~,1f MB" (/ n (float (* k k) 1d0))))
          (t (format nil "~,1f GB" (/ n (float (* k k k) 1d0)))))))

(defun split-row (left right cols)
  "LEFT at the left edge and RIGHT at the right, as one segment line — the
reference's `split_row`. When the two do not fit with two columns between them the
right half is dropped and the left is kept whole, which is the reference's choice
too: the facts are the part a narrow screen can do without."
  (let ((lw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) left)))
        (rw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) right))))
    (if (<= (+ lw rw 2) cols)
        (append left
                (list (cons (make-string (- cols lw rw) :initial-element #\space) nil))
                right)
        left)))

