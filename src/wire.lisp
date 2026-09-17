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

(defun write-frame (line stream)
  "One line + newline, flushed now: a head that renders in real time cannot
wait for a buffer to fill (wire.rs:88)."
  (write-string line stream)
  (write-char #\newline stream)
  (force-output stream))
