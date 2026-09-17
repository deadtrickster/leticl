;;;; smoke-list.lisp — the seed of T13: discover the daemons on this box,
;;;; ATTACH (the daemon refuses anything else as a first frame — server.rs:205),
;;;; read the Hello with its session list, detach. Read-only: no prompt, no
;;;; decision, nothing the model could see as a turn. Run: sbcl --script run.lisp smoke

(in-package #:leticl)

(let ((daemons (discover-daemons)))
  (format t "~d daemon(s) found~%" (length daemons))
  (dolist (d daemons)
    (format t "  ~a model=~a workspace=~a~%"
            (getf d :socket) (getf d :model) (getf d :workspace)))
  (if (null daemons)
      (format t "nothing to ask — no daemon publishing under ~a~%" (daemon-dir))
      (let* ((sock (getf (first daemons) :socket))
             (stream (connect-unix sock)))
        (unwind-protect
             (progn
               ;; empty session id = "whatever this daemon calls current"
               ;; (registry.rs:600)
               (write-frame (encode-frame (make-attach :identity "leticl-smoke")) stream)
               (multiple-value-bind (line eof) (read-frame stream)
                 (cond (eof (format t "peer closed before replying~%"))
                       (t (let ((hello (decode-frame line)))
                            (if (string= (frame-name hello) "hello")
                                (progn
                                  (format t "hello: session=~a head=~a dropped=~a wiring model=~a~%"
                                          (getf hello :session-id) (getf hello :head-id)
                                          (getf hello :dropped)
                                          (getf (getf hello :wiring) :model))
                                  (format t "  ~d session(s):~%" (length (getf hello :sessions)))
                                  (dolist (s (getf hello :sessions))
                                    (format t "    ~a ~s~%" (getf s :session-id) (getf s :title))))
                                (format t "refused: ~a~%" (getf hello :reason))))))))
          ;; the daemon may have closed after a Bye; a detach into a closed
          ;; socket is a broken pipe, not our problem
          (ignore-errors (write-frame (encode-frame (make-detach)) stream))
          (ignore-errors (close stream)))))) 
