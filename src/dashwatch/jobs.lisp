;;;; jobs — a watcher as a background job: starting, noting, waiting
;;;;
;;;; Split out of `dashwatch.lisp`, which was one 1016-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun dash-watcher-note-job (window)
  "A job's OUTPUT window, read by every `job_output` watcher that claims it. Returns how many series
were written.

**The other half of the source vocabulary.** A `command` source polls; a `job_output` source is an
EVENT — `SessionEvent::JobOutput` arrives on the `ReadJobOutput` arm — so it cannot be a sampler and
must be fed from the event that already carries the window. If the import prints its own numbers,
this is the whole watcher and no process runs at all."
  (let* ((job (getf window :job))
         ;; **THE WATCH IS MATCHED AGAINST THE COMMAND WHEN THE HEAD KNOWS IT**, and against the id
         ;; otherwise — because an EVENT carries no command line. The `JobOutput` window has the job's
         ;; id and its offsets and nothing else, so a watcher that names a command substring would
         ;; never claim anything if this matched the id alone. `*head*` is where the daemon's job
         ;; list lives (`head-jobs`), and it is the same global the rest of this tree uses; a head
         ;; that has not been told about this job yet falls back to the id, which is the honest
         ;; answer rather than no answer.
         (subject (list :id job
                        :command (or (let ((entry (find job (and (boundp '*head*) (head-jobs *head*))
                                                              :key (lambda (j) (getf j :id))
                                                              :test #'equal)))
                                       (and entry (getf entry :command)))
                                     job)))
         ;; **`:lines` AND NOT `:text`** — the field the `JobOutput` arm actually carries (see
         ;; `dash-note-job`'s callers and `src/session.lisp`'s `:job-output` arm, which keeps *job,
         ;; from, to, produced, dropped, state, never-ran, LINES, next*). Reading a key the window
         ;; does not have would have made this source silently produce nothing, which is the one
         ;; failure shape this whole file's docstrings keep coming back to.
         (text (getf window :lines))
         (n 0))
    (when (and job text (plusp (length text)))
      (maphash
       (lambda (name w)
         (declare (ignore name))
         (let ((source (getf w :source)))
           (when (and source (getf source :job-output)
                      (some (lambda (want) (dash-job-matches-p subject want))
                            (getf w :watch)))
             (dolist (pair (dash-parse-pairs text))
               (when (dash-note (format nil "~a.~a" (getf w :name) (car pair)) (cdr pair))
                 (incf n))))))
       *dash-watchers*))
    n))

(defun dash-watcher-job (head watcher)
  "The job in HEAD that WATCHER claims, or NIL. **`dash-job-matches-p` and no second rule** — the
operator's own requirement, that a watcher belongs to a job, is only two-sided if both sides ask the
same question; a second spelling here would let the pane's row and the watcher disagree about which
job is which."
  (when (getf watcher :watch)
    (find-if (lambda (job)
               (some (lambda (want) (dash-job-matches-p job want)) (getf watcher :watch)))
             (head-jobs head))))

(defun dash-watcher-start (watcher &optional reason)
  "Start WATCHER's sampler. Returns `(values STARTED-P STATE-INDEX NOTE)`.

`reason` is the job it was claimed by, for the pane's sentence. **The sampler is registered under the
watcher's name**, so `dash-watcher-running-p` and the stop are both one lookup."
  (let ((name (getf watcher :name)))
    (if (dash-watcher-running-p watcher)
        (values nil 2 nil)
        (multiple-value-bind (fn why) (dash-watcher-source-fn watcher)
          (cond
            (why (setf (getf watcher :state) 4) (values nil 4 why))
            ((null fn)
             ;; no sampler and no complaint: a `job_output` watcher, which is fed by the event
             (setf (getf watcher :state) 2) (values nil 2 nil))
            (t (dash-sampler-add name fn)
               (setf (getf watcher :state) 2)
               (when reason (setf (getf watcher :job) reason))
               (values t 2 nil)))))))

(defun dash-watchers-active-p ()
  "Is a JOB-BOUND watcher in flight? The collector's own run condition, over and above the pane.

**The operator's case is an import that runs for hours**; a dashboard whose history starts when
somebody happens to look answers none of the questions it exists for. Writing the file IS asking for
the collection, so this is not work nobody requested — which is the objection
`dash-register-defaults` raises against sampling for a pane nobody opened, and it does not apply to a
watcher that names a job."
  (loop for k being the hash-keys of *dash-watchers*
        for w = (gethash k *dash-watchers*)
        thereis (and (getf w :watch) (= (getf w :state) 2))))

(defun tick-dash-watchers (&optional head)
  "The lifecycle, on the MAIN LOOP — found, claimed, started, stopped. Returns the number of changes.

Runs beside `tick-dash-feeds` and for its reason: `%send` from the collector thread would write a
frame from a thread that does not own the socket (see that function's section note). The job LIST is
asked for only while something is waiting for a job to exist, which is the same rule and the same
clock as the feed's."
  (when head
    (let ((changes 0)
          (waiting nil))
      (maphash
       (lambda (name w)
         (declare (ignore name))
         (let ((job (dash-watcher-job head w)))
           (cond
             ;; CLAIMED and RUNNING
             ((and job (getf job :running))
              (unless (dash-watcher-running-p w)
                (multiple-value-bind (started state note) (dash-watcher-start w (getf job :id))
                  (declare (ignore state))
                  (when started (incf changes))
                  (when note (setf (getf w :note) note)))))
             ;; SETTLED — stopped, its history kept in the panel
             ((and job (not (getf job :running)) (dash-watcher-running-p w))
              (dash-watcher-stop w)
              (incf changes))
             ;; NO JOB YET — and this is the state that has to ASK, because a watcher bound to a job
             ;; that has not started has nothing to match against
             ((and (getf w :watch) (null job))
              (setf waiting t))
             ;; **AN ALWAYS-ON WATCHER RUNS WHEN THE COLLECTOR DOES** — a watcher with no `watch` is
             ;; the shipped `system`/`llama` shape, and it must not start the collector itself: that
             ;; would be sampling for a pane nobody opened, which is the objection
             ;; `dash-register-defaults` raises. So it follows the collector rather than leading it.
             ((null (getf w :watch))
              (when (and *dash-running* (not (dash-watcher-running-p w)))
                (multiple-value-bind (started state note) (dash-watcher-start w)
                  (declare (ignore state))
                  (when started (incf changes))
                  (when note (setf (getf w :note) note))))))))
       *dash-watchers*)
      ;; ONE ask while something is still waiting, on the feed's own clock
      (when (and waiting (>= (- (internal-real-time-ms) *dash-jobs-asked-at*)
                             (* 1000 *dash-interval*)))
        (setf *dash-jobs-asked-at* (internal-real-time-ms))
        (%send head (make-list-jobs)))
      ;; **AND THE COLLECTOR RUNS BECAUSE A WATCHER IS ACTIVE**, which is the one behaviour change
      ;; this lifecycle makes to a running head
      (when (and (dash-watchers-active-p) (not *dash-running*))
        (dash-start)
        (incf changes))
      changes)))

;;; ------------------------------------------------------- 6. what the pane says ;;;

(defun dash-watcher-notes ()
  "The pane's lines about the watchers: one per watcher, with its state and what it is bound to."
  (let ((rows '()))
    (maphash
     (lambda (name w)
       (declare (ignore name))
       (let* ((state (aref +dash-watcher-states+ (or (getf w :state) 0)))
              (scope (if (eq (getf w :scope) :workspace) "workspace" "user"))
              (watch (getf w :watch))
              (source (let ((s (getf w :source)))
                        (cond ((null s) "no source")
                              ((getf s :command) "runs a command")
                              ((getf s :file) "reads a file")
                              ((getf s :job-output) "reads the job's output")
                              (t "unknown source")))))
         (push (list (cons (format nil "  ~a  " name) '(:bold t))
                     (cons (format nil "~a  " state)
                           (case (getf w :state)
                             (2 '(:fg :green))
                             (3 '(:dim t))
                             (4 '(:fg :yellow))
                             (t '(:dim t))))
                     (cons (format nil "~a · ~a~@[ · job ~a~]~@[ · ~a~]"
                                   source scope (first watch) (getf w :note))
                           '(:dim t)))
               rows)))
     *dash-watchers*)
    (nreverse rows)))

(defun dash-sink-notes ()
  "One line per sink: what it publishes and whether the last pass landed. **A sink that is silently
failing is the failure this exists for** — a dashboard quietly missing a counter reads as a job that
has not moved."
  (let ((rows '()))
    (maphash
     (lambda (name sink)
       (declare (ignore name))
       (let* ((stat (gethash (getf sink :name) *dash-sink-stat*))
              (err (gethash (getf sink :name) *dash-sink-errors*))
              (text (cond (err (format nil "! ~a" err))
                          (stat (format nil "pushed ~d~@[ · ~d failed~]"
                                        (getf stat :posted)
                                        (let ((f (getf stat :failed))) (and (plusp f) f))))
                          (t "not run yet"))))
         (push (list (cons (format nil "  → ~a  " (getf sink :name)) '(:bold t))
                     (cons (format nil "~d series  " (length (getf sink :series))) '(:dim t))
                     (cons text (if err '(:fg :yellow) '(:dim t)))
                     ;; **AND WHAT RETENTION THIS SINK ASKS FOR** — because the whole point of a
                     ;; per-series `retain` is that the OPERATOR set it, and a setting nobody can see
                     ;; on the pane is a setting nobody can check. The dead `:retain-refused` branch
                     ;; this replaces had the right instinct pointed at a field nothing writes any more.
                     (cons (let ((all (getf sink :retains)))
                             (if all
                                 (format nil "  · ~d/~d with declared retention"
                                         (count-if #'cdr all) (length all))
                                 ""))
                           '(:dim t)))
               rows)))
     *dash-sinks*)
    (nreverse rows)))

(defun dash-watchers-reset ()
  "Forget every watcher and sink, and stop their samplers. The suite's door; a live reload does NOT
do this, because a reload must not throw away a running watcher's history."
  (maphash (lambda (k w) (declare (ignore k)) (dash-watcher-stop w)) *dash-watchers*)
  (clrhash *dash-watchers*)
  (clrhash *dash-sinks*)
  (clrhash *dash-sink-errors*)
  (clrhash *dash-sink-stat*)
  (values))
