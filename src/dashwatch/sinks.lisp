;;;; sinks — the sinks: a command the collector runs with the reading on stdin
;;;;
;;;; Split out of `dashwatch.lisp`, which was one 1016-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun dash-sink-add-from-spec (spec watcher)
  "Register the sink SPEC declares in WATCHER's file. Signals on anything that must be refused.

**The refusals are the design.** A sink that names a seat whose environment this head cannot find is
REFUSED BY NAME rather than run — the operator's rule, verbatim: *\"If a watcher names a seat it
cannot read a token for, that is a refusal, not a fallback.\"* And `seat` is a NAME and never a
token, so nothing in a watcher file is a credential.

**It returns `(values NAME ERRORS)`**, because a `retain` that cannot be read is a REPORT rather than
a refusal: the sink still publishes, and the pane says which key was ignored. One function with two
outcomes, because the alternative — signaling on the retain and refusing the sink — would take a
working publisher down over a housekeeping hint."
  (let ((errors '())
        (name (or (getf spec :name) (format nil "~a-sink" (getf watcher :name))))
        (kind (or (getf spec :kind) "command"))
         (series (or (getf spec :series)
                     ;; the watcher's own declared series, which is the reason sinks live in a
                     ;; watcher file: its subject is what that watcher produces
                     (remove nil (mapcar (lambda (s) (getf s :name)) (getf watcher :series)))))
         (retain (or (getf spec :retain) 200))
         (timeout (or (getf spec :timeout) 15)))
    (unless (and series (listp series))
      (error "~a: a sink names no series" name))
    ;; every series name is qualified with the watcher's name, the same rule the sampler uses
    (setf series (mapcar (lambda (s) (if (search "." s) s (format nil "~a.~a" (getf watcher :name) s)))
                         series))
    (cond
      ((string-equal kind "flowy")
       (let* ((seat (or (getf spec :seat)
                        (error "~a: a flowy sink must name its \"seat\"" name)))
              (seat-file (dash-flowy-seat-file seat))
              (addr (dash-flowy-addr spec)))
         (unless (and seat-file (probe-file seat-file))
           (error "~a names seat ~a and there is no ~a — a refusal, not a fallback"
                  (file-namestring (getf watcher :file)) seat
                  (or (and seat-file (namestring seat-file)) "seat file")))
         (unless addr
           (error "~a: a flowy sink needs an \"addr\", or FLOWY_ADDR in this head's environment" name))
         (multiple-value-bind (retains rerrs) (dash-sink-retains spec watcher series)
           (dolist (e rerrs) (push e errors))
           (dash-sink-add name :kind "flowy" :series series :retain retain :retains retains
                          :timeout timeout
                          :file (getf watcher :file)
                          :command (dash-flowy-command seat seat-file addr timeout)
                          :body-fn (lambda (series-name value)
                                     (let ((r (cdr (assoc series-name retains :test #'string=))))
                                       (dash-flowy-body series-name value
                                                        :points (getf r :points)
                                                        :seconds (getf r :seconds))))))))
      (t
       (let ((command (getf spec :command))
             (body (getf spec :body)))
         (unless command
           (error "~a: a sink must name a \"command\" (or be kind flowy)" name))
         (dash-sink-add name :kind "command" :series series
                        :command command :body (or body "{\"series\":\"{series}\",\"value\":{value}}")
                        :file (getf watcher :file) :retain retain :timeout timeout))))
    (values name (nreverse errors))))

(defmacro %dash-with-payload ((payload path-var) &body body)
  "Bind PATH-VAR to a temp file holding PAYLOAD, run BODY, delete the file.

**WHY A FILE AND NOT `:input`, MEASURED:** `uiop:run-program`'s `:input` does NOT accept a string —
handed a bare string it fails with a complaint that begins *The file* — because a string designator is
read as a PATHNAME. That is the second option in this file's family that looked like an API and was a
trap (the first is `:timeout`, in `dash-command-add`: accepted, ignored, 30 seconds). A pathname for
`:input` works, which is what this does.

The sink's contract is unchanged — **the reading arrives on the command's STDIN**, which a file
descriptor satisfies exactly as a pipe would, and the command needs to know nothing about where it
came from."
  (let ((s (gensym)) (p (gensym)))
    `(let ((,p (merge-pathnames (format nil "leticl-sink-~d-~d" (get-universal-time) (random 1000000))
                                (uiop:temporary-directory))))
       (unwind-protect
            (progn
              (with-open-file (,s ,p :direction :output :if-exists :supersede
                                    :if-does-not-exist :create)
                (write-string ,payload ,s))
              (let ((,path-var ,p)) ,@body))
         (ignore-errors (delete-file ,p))))))

(defun dash-sinks-reset ()
  "Forget every sink and its counters. The suite's door — a live reload does NOT do this, because a
reload must not throw away a running sink's history."
  (clrhash *dash-sinks*)
  (clrhash *dash-sink-errors*)
  (clrhash *dash-sink-stat*)
  (values))

(defun %dash-fill-reading (template series value)
  "TEMPLATE with `{series}` and `{value}` replaced — **the sink's own two slots, and only two**, for
the same reason `%dash-fill-slots` is a closed list: a body template that can compute is a language."
  (let ((out (copy-seq template)))
    (setf out (substitute-substring out "{series}" series))
    (substitute-substring out "{value}" (format nil "~a" value))))

(defun substitute-substring (text from to)
  "TEXT with every FROM replaced by TO. A local helper rather than a dependency: this is the whole of
what `cl-ppcre` would be here, on a string that is a series name or a number."
  (let ((pos 0) (out (make-string-output-stream)))
    (loop
      (let ((hit (search from text :start2 pos)))
        (cond ((null hit) (write-string (subseq text pos) out) (return))
              (t (write-string (subseq text pos hit) out)
                 (write-string to out)
                 (setf pos (+ hit (length from)))))))
    (get-output-stream-string out)))

(defun dash-sink-run (sink)
  "Run SINK once per series it publishes. Returns `(values POSTED FAILED)`.

**A NIL READING IS NOT PUSHED**, which is `dash-note`'s own rule pointed outward: a series nobody
measured has no value, and pushing a zero would be this head inventing a fact on the NODE — where it
outlives the process and cannot be retracted, since newest-wins never sees a deletion. A series that
goes quiet simply stops updating, which is exactly how a stopped box reads and is the truth.

**And a failing sink does not take the pass down** — `dash-collect-once`'s rule for samplers, one
level out. The failure is recorded, the pane shows it, and the other series still go."
  (let ((posted 0) (failed 0)
        (command (getf sink :command))
        (body (getf sink :body))
        (body-fn (getf sink :body-fn))
        (timeout (getf sink :timeout)))
    (dolist (series (getf sink :series))
      (let ((value (dash-last series)))
        (when (and value (numberp value))
          (let ((payload (if body-fn
                             (funcall body-fn series value)
                             (%dash-fill-reading body series value))))
            (handler-case
                (%dash-with-payload (payload payload-file)
                  (let* ((text (uiop:run-program (list "timeout" (princ-to-string timeout)
                                                       "/bin/sh" "-c" command)
                                                 :input payload-file
                                                 :output :string :error-output :output
                                                 :ignore-error-status t))
                         (code (string-trim '(#\space #\newline) (or text ""))))
                    ;; the sink's own exit status is not the answer — the HTTP code its command
                    ;; printed is, because a curl that could not connect still exits 0 with `000`
                    (if (member code '("200" "201") :test #'string=)
                        (progn
                          (incf posted)
                          ;; **A SUCCESS CLEARS THE LAST FAILURE**, or the pane reports a stale error
                          ;; over a sink that has been working since — which is the same defect as a
                          ;; stale series drawn as a live one. MEASURED: after a 400 was fixed, the
                          ;; stat read `:posted 2 :failed 0` while the error line still said 400.
                          (remhash (getf sink :name) *dash-sink-errors*))
                        (progn
                          (incf failed)
                          (setf (gethash (getf sink :name) *dash-sink-errors*)
                                (format nil "~a for ~a — the command answered ~a"
                                        (getf sink :name) series
                                        (if (plusp (length code)) code "nothing")))))))
              (error (e)
                (incf failed)
                (setf (gethash (getf sink :name) *dash-sink-errors*) (format nil "~a" e))))))))
    (setf (gethash (getf sink :name) *dash-sink-stat*)
          (list :posted posted :failed failed :at (internal-real-time-ms)))
    (values posted failed)))

(defun dash-sinks-run ()
  "Every sink, one pass. Returns `(values POSTED FAILED)`."
  (let ((p 0) (f 0))
    (maphash (lambda (name sink)
               (declare (ignore name))
               (multiple-value-bind (a b) (dash-sink-run sink) (incf p a) (incf f b)))
             *dash-sinks*)
    (values p f)))

(defun dash-sink-names () (sort (loop for k being the hash-keys of *dash-sinks* collect k) #'string<))

;;; --------------------------------------------------------- 5. the lifecycle ;;;

