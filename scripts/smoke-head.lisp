;;;; smoke-head.lisp — T13's verification, headless: attach, ingest the Hello,
;;;; render the viewport through the real render path, ack, then drain live
;;;; events for a few seconds, re-rendering and acking as a head would. No
;;;; terminal needed; the screen is printed escape-stripped. Read-only: no
;;;; prompt, no decision. Run: sbcl --script run.lisp smoke-head

(in-package #:leticl)

(defun %strip-ansi (string)
  (let ((out (make-string-output-stream))
        (n (length string))
        (i 0))
    (loop while (< i n)
          do (let ((ch (char string i)))
               (if (char= ch (code-char 27))
                   (progn
                     (incf i)                       ; ESC
                     (when (and (< i n) (char= (char string i) #\[))
                       (incf i))                    ; CSI introducer
                     ;; consume to the final byte, inclusive
                     (loop while (and (< i n)
                                      (not (<= 64 (char-code (char string i)) 126)))
                           do (incf i))
                     (incf i))
                   (progn (write-char ch out) (incf i)))))
    (get-output-stream-string out)))

(let* ((daemons (discover-daemons))
       (sock (getf (first daemons) :socket))
       (stream (connect-unix sock))
       (head (%make-head))
       (session (head-session head))
       (deadline (+ (get-internal-real-time)
                    (* 6 internal-time-units-per-second))) ; six SECONDS
       (events 0) (dirty 0) (acks 0))
  (setf (head-cols head) 100 (head-rows head) 30)
  (screen-resize (head-screen head) 100 30)
  (screen-resize (head-prev-screen head) 100 30)
  (unwind-protect
       (progn
         (write-frame (encode-frame (make-attach :identity "leticl-smoke")) stream)
         (loop
           (let ((now (get-internal-real-time)))
             (when (> now deadline) (return))
             ;; wait for the next frame or the deadline — never a bare listen
             ;; poll: one poll right after the attach write loses the race
             (when (wait-for-input stream
                                   (/ (- deadline now) internal-time-units-per-second))
               (multiple-value-bind (line eof) (read-frame stream)
                 (cond
                   (eof (format t "peer closed~%") (return))
                   (t (let ((frame (decode-frame line)))
                        (cond
                          ((string= (frame-name frame) "hello")
                           (ingest-hello session frame)
                           (format t "hello: session=~a dropped=~a items=~d sessions=~d~%"
                                   (session-session-id session)
                                   (session-dropped session)
                                   (length (session-items session))
                                   (length (session-sessions session))))
                          ((string= (frame-name frame) "event")
                           (incf events)
                           (when (eq (apply-event session frame) :dirty) (incf dirty)))
                          ((string= (frame-name frame) "resync")
                           (ingest-snapshot session (getf frame :snapshot))
                           (format t "resync: ~a~%" (getf frame :reason)))
                          (t nil))))))))
           ;; a head paints when dirty and acks after painting, never on receipt
           (when (plusp dirty)
             (%render head)
             (write-frame (encode-frame (make-ack (session-seq session) dirty 0)) stream)
             (incf acks)
             (setf dirty 0)))
         ;; final render, shown escape-stripped
         (%render head)
         (format t "~%events=~d acks=~d seq=~d items=~d open-decisions=~d~%"
                 events acks (session-seq session) (length (session-items session))
                 (length (session-open-decisions session)))
         (format t "~%viewport (100x30, escapes stripped):~%")
         (dolist (r (screen-rows-ansi (head-screen head)))
           (format t "|~a~%" (%strip-ansi r)))
         ;; one clean ack for everything consumed since
         (write-frame (encode-frame (make-ack (session-seq session) 0 0)) stream))
    (ignore-errors (write-frame (encode-frame (make-detach)) stream))
    (ignore-errors (close stream)))) 
