;;;; hack.lisp — the live-modification surface, the reason this rewrite exists
;;;; (PLAN.md §8). Each head listens on its own unix socket; a line `eval <form>`
;;;; evaluates in this image and the change is on the next frame, because the
;;;; eval marks the head dirty and the loop repaints when dirty.
;;;;
;;;; Trust: this is arbitrary code execution in the head, by design — the same
;;;; trust a person at a REPL has and the same trust the daemon's exec tool
;;;; already grants. Per-user socket, mode 0600, documented loudly in
;;;; HACKING.md rather than hidden.

(in-package #:leticl)

(defun hack-socket-path (&optional (pid (sb-posix:getpid)))
  (merge-pathnames (format nil "tui-~d.sock" pid)
                   (pathname (concatenate 'string (runtime-dir) "/"))))

(defun hack-start (head)
  "Listen and accept. A head that cannot take its hack socket still runs —
the TUI works without it; only the live-modification is lost."
  (handler-case
      (let* ((path (hack-socket-path))
             (listener (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
        (ensure-directories-exist path)
        (ignore-errors (delete-file path))
        (sb-bsd-sockets:socket-bind listener (namestring path))
        (sb-bsd-sockets:socket-listen listener 8)
        (sb-posix:chmod (namestring path) #o600)
        (setf (head-hack-listener head) listener
              (head-hack-path head) path
              (head-hack-thread head)
              (sb-thread:make-thread
               (lambda () (hack-accept-loop head))
               :name "leticl hack listener"))
        path)
    (error (e)
      (setf (head-status-note head) (format nil "hack socket unavailable: ~a" e))
      nil)))

(defun hack-accept-loop (head)
  (loop
    (handler-case
        (let ((conn (sb-bsd-sockets:socket-accept (head-hack-listener head))))
          (sb-thread:make-thread (lambda () (hack-serve head conn))
                                 :name "leticl hack conn"))
      (error () (return)))))             ; listener closed: the head is gone

(defun hack-serve (head conn)
  (unwind-protect
       (let ((stream (sb-bsd-sockets:socket-make-stream
                      conn :input t :output t :element-type 'character
                      :external-format :utf-8 :buffering :line)))
         (let ((*package* (find-package :leticl))
               (*head* head))
           (loop
             (let ((line (read-line stream nil nil)))
               (unless line (return))
               (write-line (hack-handle head line) stream)
               (force-output stream)))))
    (ignore-errors (close conn))))

(defun hack-mute (condition)
  "Swallow a compiler note. The eval's reply travels the socket; *standard-output*
 is the TUI, so a note printed there paints over the render and desyncs the
 terminal from the cell buffer — and /cells, which sends the cell buffer, then
 cannot show what the operator actually sees (measured: an eval with a typo put
 SBCL's compile report on the operator's screen)."
  (declare (ignore condition))
  nil)

(defun hack-handle (head line)
  "One request, one JSON reply. `eval <form>` — the rest of the line is one
s-expression, read and evaluated in :leticl with *head* bound. Compiler notes
and print side-effects are swallowed: the reply goes to the socket, and a leak
to *standard-output* would corrupt the TUI and desync it from the screen."
  (let ((start (get-internal-real-time)))
    (flet ((ms () (round (* 1000 (- (get-internal-real-time) start))
                         internal-time-units-per-second)))
      (handler-case
          (progn
            (unless (uiop:string-prefix-p "eval " line)
              (error "only `eval <form>` is spoken here"))
            (let* ((form (read-from-string (subseq line 5)))
                   (value (let ((*standard-output* (make-string-output-stream))
                                (*error-output* (make-string-output-stream)))
                            (handler-bind ((style-warning #'hack-mute)
                                           (warning #'hack-mute))
                              (eval form)))))
              ;; visible immediately is a property of the loop: the eval marks
              ;; the head dirty, the loop repaints on its next tick
              (setf (head-dirty head) t)
              (format nil "{\"ok\":true,\"value\":~a,\"ms\":~a}"
                      (json-encode-to-string (prin1-to-string value))
                      (ms))))
        (error (e)
          (format nil "{\"ok\":false,\"error\":~a}"
                  (json-encode-to-string (prin1-to-string e))))))))

(defun hack-stop (head)
  (when (head-hack-listener head)
    (ignore-errors (sb-bsd-sockets:socket-close (head-hack-listener head))))
  (when (head-hack-path head)
    (ignore-errors (delete-file (head-hack-path head)))))

(defun hack-socket-path* ()
  "The path of the running head's hack socket, for tui-eval's --list."
  (when (and *head* (head-hack-path *head*))
    (namestring (head-hack-path *head*))))

(defun list-live-heads ()
  "Every leticl head this user runs, by its hack socket."
  (loop for f in (directory (merge-pathnames "tui-*.sock"
                                             (pathname (concatenate 'string (runtime-dir) "/"))))
        collect (namestring f)))
