;;;; chrome.lisp — the frame furniture: the top border, the status line, and
;;;; the composer's line.
;;;;
;;;; This is the strip the operator looks at while typing. It draws no
;;;; transcript and reads only `head` state, so it can be restyled without
;;;; touching a single row renderer.

(in-package #:leticl)

;;; --------------------------------------------------------------- chrome ;;;
(defun top-border (head cols)
  (let* ((s (head-session head))
         (title (if (plusp (length (session-title s)))
                    (session-title s) (session-session-id s)))
         (model (getf (session-wiring s) :model))
         (left (format nil " leticl · ~a · ~a " title model))
         (right (format nil "seq ~a · ~d heads "
                        (session-seq s) (length (session-heads s))))
         (pad (max 0 (- cols (string-width left) (string-width right)))))
    (list (cons left '(:bold t :fg :cyan))
          (cons (make-string pad :initial-element #\─) '(:fg :bright-black))
          (cons right '(:fg :bright-black)))))

(defun status-line (head cols)
  (let* ((conn (if (head-connected head) "" " · DISCONNECTED — retrying"))
         (scroll (if (plusp (head-scroll head))
                     (format nil " · ↑~a" (head-scroll head)) ""))
         (queued (if (head-queued head)
                     (format nil " · ~d queued" (length (head-queued head))) ""))
         (text (format nil " ~a~a~a~a"
                       (or (head-status-note head) "") conn scroll queued))
         (style (if (head-connected head) '(:fg :bright-black) '(:fg :red :bold t))))
    (list (cons (if (> (string-width text) cols)
                    (subseq text 0 cols) text)
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:fg :bright-black)))))

(defun composer-line (head cols)
  (let* ((c (head-composer head))
         (buf (composer-buffer c))
         (prefix "› ")
         (visible (if (> (+ (string-width prefix) (string-width buf)) cols)
                      ;; keep the cursor end visible: show the tail
                      (subseq buf (max 0 (- (length buf)
                                            (- cols (length prefix)))))
                      buf)))
    (list (cons prefix '(:fg :bright-cyan :bold t))
          (cons visible nil))))


