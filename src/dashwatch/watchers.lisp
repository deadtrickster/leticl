;;;; dashwatch.lisp — WATCHERS and SINKS (R56): a file that produces series, and where they go.
;;;;
;;;; `src/dashfiles.lisp` made a PANEL a file. This file makes the other two halves files:
;;;;
;;;;   · a WATCHER produces series — a command, a file, or a job's own output, on an interval,
;;;;     bound to a job as a LIFECYCLE (found, claimed, started, stopped);
;;;;   · a SINK publishes them — a command the collector runs with the reading on STDIN. The first
;;;;     one is flowy, and it is the reason this head needs no HTTP client at all: the only sockets
;;;;     in this tree are `sb-bsd-sockets:local-socket` (src/hack.lisp), there is no TLS, and
;;;;     head.lisp already records why. A command that runs curl is a command, and this head
;;;;     already has commands.
;;;;
;;;; **A SINK IS A SOURCE POINTED THE OTHER WAY**, which is why both live in one file: the timeout
;;;; discipline is the same (`uiop:run-program`'s `:timeout` was MEASURED doing nothing — see
;;;; `dash-command-add`), the failure discipline is the same (a failing sampler or sink is RECORDED
;;;; and does not take the pass down), and the visibility is the same (the pane).
;;;;
;;;; Directories, the same two and the same precedence as dashboards — a union by `name`, the
;;;; workspace file winning:
;;;;
;;;;   ${XDG_CONFIG_HOME:-~/.config}/letibot/watchers/*.json
;;;;   <workspace>/.letibot/watchers/*.json
;;;;
;;;; and `sinks` are declared INSIDE a watcher file, because a sink's natural subject is what that
;;;; watcher produces.

(in-package #:leticl)

(defvar *dash-workspace-commands* nil
  "May a WORKSPACE watcher's `command` source run? **NIL, and it is the interim answer to a parked
question rather than a design.**

The operator parked the trust question — *\"too many unknown unknown to make realiable decision. we
need to ship the whole package incl flowy integration first\"* — and made one judgement so the build
was not blocked: ship the MECHANISM with a workspace watcher's `command` source OFF, refusing in one
line that names the file. `docs/r56-dashboards-from-files.md` §2a carries the three shapes and the
question, so it is recoverable rather than forgotten.

So this is a DEFAULT TO FLIP and not a decision: a USER-level watcher may run anything (that
directory is the operator's own hand, the same standing as `head.toml`), and a workspace watcher may
READ freely — `file`, `job_output` — and may not RUN until somebody answers the question above.")

(defvar *dash-watchers* (make-hash-table :test #'equal)
  "watcher name → a plist, alive for the process.

  :name      the watcher's name — the prefix on every series it produces
  :file      where it came from, for the pane and for refusals
  :scope     :user or :workspace
  :spec      the decoded file, verbatim
  :watch     the job selector, or NIL for an always-on watcher
  :source    the plist under `source`, or NIL
  :series    the declared series, for the units and the sink's default selector
  :interval  seconds, or NIL for the collector's own
  :states    the SOURCE's own numbers, indexed 0..; see `+dash-watcher-states+`")

(defparameter +dash-watcher-states+ #("found" "claimed" "running" "stopped" "refused")
  "A watcher's lifecycle, and it is the JOBS vocabulary read the other way — the operator's second
complaint was *\"they still dont belong to jobs\"*, and a lifecycle is what belonging means:

  · `found`   — on disk, read, nothing started. A watcher with no `watch` is always-on and moves
                straight to `running` when the collector runs;
  · `claimed` — a job the daemon reports matches its `watch` (`dash-job-matches-p`, the ONE rule for
                that match, asked in both directions);
  · `running` — its sampler is registered;
  · `stopped` — the job settled. **The sampler is stopped, not unregistered, and what it collected
                does not evaporate** — the series live in `*dash-series*` and the panel keeps drawing
                them with a staleness chip;
  · `refused` — it cannot run at all, and the pane carries the reason: a workspace `command` source
                while `*dash-workspace-commands*` is NIL is the case that exists today.")

(defvar *dash-sinks* (make-hash-table :test #'equal :synchronized t)
  "sink name → a plist:

  :name    what the pane calls it
  :file    the watcher file that declared it
  :kind    \"flowy\" (the built-in) or \"command\" (the general form)
  :series  the series it publishes
  :command the shell command, run with the body on stdin
  :body    the body template, with `{series}` and `{value}`")

(defvar *dash-sink-errors* (make-hash-table :test #'equal :synchronized t)
  "sink name → the last failure, as a string. **A `defvar` and not a `defparameter`**, for the house
reason: a live push must not throw away what a running head is holding.")

(defvar *dash-sink-stat* (make-hash-table :test #'equal :synchronized t)
  "sink name → `(:posted N :failed N :at MS)`. The count is what makes a sink that is *quietly*
failing visible, which is the failure this whole file's discipline exists to prevent.")

;;; ------------------------------------------------------- 1. where they are ;;;

(defun dash-watchers-dirs (&optional (head nil))
  "The watcher directories, LOWEST PRECEDENCE FIRST, as `((DIR . SCOPE) …)`.

`dash-file-dirs`' own shape, one directory over, and deliberately the same code path — two spellings
of *where a file lives* is how the two halves would drift."
  (let* ((user (ignore-errors (daemon-config-dir)))
         (ws (let ((w (and head (ignore-errors
                                   (getf (session-wiring (head-session head)) :workspace)))))
               (dash-workspace-config-dir w))))
    (remove nil
            (list (and user (cons (merge-pathnames "watchers/" user) :user))
                  (and ws (cons (merge-pathnames "watchers/" ws) :workspace))))))

(defun %dash-watcher-candidates (dir)
  "`(PATH . SCOPE)` for every `.json` in DIR, sorted by filename. NIL when the directory is absent —
a head with neither directory starts normally, which is `%dash-json-objects`' rule and every
directory rule in this feature."
  (when (and dir (uiop:directory-pathname-p (ignore-errors (probe-file (car dir)))))
    (sort (mapcar (lambda (f) (cons (namestring f) (cdr dir)))
                  (ignore-errors (uiop:directory-files (car dir) "*.json")))
          #'string< :key #'car)))

;;; ---------------------------------------------------------- 2. the source ;;;

(defun %dash-sh-quote (text)
  "TEXT as ONE shell word, safe in `/bin/sh -c`.

**Not decoration.** A sink's `addr` comes out of a FILE, and `FLOWY_ADDR=$addr` with the value
`; rm -rf /` is a command injection wearing a config key. Single quotes stop every expansion and
every metacharacter; the only character that needs care inside them is the single quote itself,
which becomes `'\\''` — close, escape, reopen."
  (if (null text)
      "''"
      (with-output-to-string (s)
        (write-char #\' s)
        (loop for ch across text
              do (if (char= ch #\')
                     (write-string "'\\''" s)
                     (write-char ch s)))
        (write-char #\' s))))

(defun dash-command-source-fn (command &key (parse #'dash-parse-pairs) (timeout 10) (prefix t))
  "The sampler function a `command` source runs: COMMAND through `/bin/sh -c`, its output parsed.

**The cap is coreutils' `timeout`, and it is not optional** — `uiop:run-program`'s own `:timeout` was
MEASURED accepting `1` against a `sleep 30` and taking 30 seconds, so the collector thread was wedged
for the whole of it while the head kept painting and every other series silently stopped. Same
finding as `dash-command-add`'s, and the same fix, which is why this is a function rather than a
second copy of that reasoning."
  (lambda ()
    (let* ((text (uiop:run-program (list "timeout" (princ-to-string timeout)
                                         "/bin/sh" "-c" command)
                                   :output :string :error-output :output
                                   :ignore-error-status t))
           (pairs (funcall parse text)))
      (if prefix
          (loop for (k . v) in pairs collect (cons k v))
          pairs))))

(defun dash-file-source-fn (path &key (parse #'dash-parse-pairs) (timeout 10))
  "The sampler function a `file` source runs: `timeout N cat -- PATH`, **as ARGV and never through a
shell.**

This is the one place the distinction is load-bearing rather than tidy: `dash-command-add` runs
through `/bin/sh -c`, so a path passed to a shell would make a PATH a mini-program — a file named
`x; curl … | sh` is a command, not a filename. Run as argv there is nothing to quote and nothing to
inject, and a path is only a path.

The timeout stays, because a hung NFS mount must not wedge the collector thread."
  (lambda ()
    (let* ((text (uiop:run-program (list "timeout" (princ-to-string timeout)
                                         "cat" "--" (namestring path))
                                   :output :string :error-output :output
                                   :ignore-error-status t))
           (pairs (funcall parse text)))
      (loop for (k . v) in pairs collect (cons k v)))))

(defun %dash-throttle (fn interval)
  "FN, skipped when it ran less than INTERVAL seconds ago.

**Per-watcher intervals, and the reason it is a wrapper rather than a scheduler**: the collector's
tick is global (`*dash-interval*`), and a second scheduler would be a second clock to keep in step —
which is the defect `dash-feed-due-p`'s docstring names (*two cadences would draw two time axes*).
A watcher that wants to be slower than the collector simply declines the ticks that are not its own."
  (let ((last 0))
    (lambda ()
      (let ((now (internal-real-time-ms)))
        (when (>= (- now last) (* 1000 interval))
          (setf last now)
          (funcall fn))))))

(defun dash-watcher-source-fn (watcher)
  "The sampler function WATCHER's `source` runs, or `(values NIL REASON)` when it must not run.

**THE GATE LIVES HERE, in one place, because a second place would be a second answer.** A workspace
watcher's `command` source is refused while `*dash-workspace-commands*` is NIL — the parked question,
`docs/r56-dashboards-from-files.md` §2a — and the refusal NAMES THE FILE, because a reader looking at
one line in a pane is trying to find out which file to edit."
  (let* ((source (getf watcher :source))
         (scope (getf watcher :scope))
         (file (getf watcher :file))
         (name (getf watcher :name))
         (parse (getf source :parse))
         (timeout (or (getf source :timeout) 10))
         (prefix (if (member :prefix source) (getf source :prefix) t))
         (parse-fn (cond ((null parse) #'dash-parse-pairs)
                         ((string-equal parse "pairs") #'dash-parse-pairs)
                         ((string-equal parse "json") #'dash-parse-json-object)
                         (t #'dash-parse-pairs)))
         (fn nil))
    ;; **`RETURN-FROM` AND NOT A BARE `(values …)` — this function had a bug that made the gate a
    ;; no-op.** A `cond` clause's value is DISCARDED; `(values nil "refused")` inside one returns
    ;; nothing to the caller, and execution falls through to the `(values fn nil)` at the end. So a
    ;; workspace `command` source was "refused" with a message thrown away and then STARTED anyway.
    ;; MEASURED by the probe that found it: `started=NIL state=2 note=NIL` for a watcher whose
    ;; `*scope*` was `:WORKSPACE` and whose source was a command — the exact case the operator's
    ;; interim judgement exists to stop.
    (when (and source (not (listp source)))
      (return-from dash-watcher-source-fn (values nil "\"source\" is not a JSON object")))
    (when source
      (let ((kinds (count-if #'identity (list (getf source :command)
                                              (getf source :file)
                                              (getf source :job-output)))))
        (when (/= 1 kinds)
          (return-from dash-watcher-source-fn
            (values nil "\"source\" must name exactly ONE of command, file, job_output")))))
    (let ((kind (cond ((getf source :command) :command)
                      ((getf source :file) :file)
                      ((getf source :job-output) :job-output)
                      (t nil))))
      (case kind
        (:command
         (if (and (eq scope :workspace) (not *dash-workspace-commands*))
             (return-from dash-watcher-source-fn
               (values nil (format nil "~a runs a command and is a WORKSPACE watcher — refused (~a is NIL)"
                                   (file-namestring file) '*dash-workspace-commands*)))
             (setf fn (dash-command-source-fn (getf source :command)
                                              :parse parse-fn :timeout timeout))))
        (:file
         ;; READING is never gated: a workspace watcher may always read, and this is argv, so it is
         ;; a read rather than a run. See `dash-file-source-fn`.
         (setf fn (dash-file-source-fn (getf source :file) :parse parse-fn :timeout timeout)))
        (:job-output
         ;; not a sampler at all — the job's own window is the input, and it arrives as an EVENT.
         ;; `dash-watcher-note-job` is the reader; see §4 of the design.
         nil)
        (t (return-from dash-watcher-source-fn
             (values nil "names no source kind this head knows (command, file, job_output)")))))
    (when (and fn (getf watcher :interval))
      (setf fn (%dash-throttle fn (getf watcher :interval))))
    (when fn
      ;; and the PREFIX, which the watcher's own name supplies — so two watchers cannot collide and
      ;; a dashboard can name `import.rows` without knowing which file produced it
      (let ((inner fn))
        (setf fn (lambda ()
                   (loop for (k . v) in (funcall inner)
                         collect (cons (if prefix (format nil "~a.~a" name k) k) v))))))
    (values fn nil)))

(defun dash-parse-json-object (text)
  "TEXT as `(key . value)` pairs when it is a JSON object of numbers, else NIL.

The second shape a source can print. **Only scalar numbers**, because this is parsing somebody
else's output and a nested object is not a series — the same refusal `dash-parse-pairs` makes about
a line nobody promised a shape for."
  (let ((obj (ignore-errors (json-decode (string-trim '(#\space #\newline #\tab) (or text ""))))))
    (when (and obj (listp obj) (keywordp (car obj)))
      (loop for (k v) on obj by #'cddr
            when (numberp v)
              collect (cons (string-downcase (symbol-name k)) (float v))))))

;;; ---------------------------------------------------- 3. reading the files ;;;

(defun dash-watcher-running-p (watcher)
  "Is WATCHER's sampler registered right now?"
  (member (getf watcher :name) (mapcar #'car *dash-samplers*) :test #'string=))

(defun dash-watcher-stop (watcher)
  "Stop WATCHER's sampler. **Stopped, not unregistered, and what it collected does not evaporate** —
the series are in `*dash-series*`, which no part of this touches. The panel keeps drawing them, and
the freshness chip is what says they have stopped arriving."
  (setf *dash-samplers*
        (remove (getf watcher :name) *dash-samplers* :key #'car :test #'string=))
  (setf (getf watcher :state) 3)
  (values))

(defun dash-watcher-from-spec (spec path scope)
  "WATCHER as a plist, from SPEC. Returns `(values WATCHER ERROR)` — one of the two is NIL.

Registration is SPLIT from running, exactly as `dash-register-defaults` splits it for panels:
reading a file is a few plists and no I/O, and starting a collector is work nobody asked for until
something is claimed or looked at."
  (let* ((name (or (getf spec :name) (%dash-file-stem path)))
         (watch (let ((w (getf spec :watch)))
                  (cond ((stringp w) (list w))
                        ((and (listp w) w) w)
                        (t nil))))
         (source (getf spec :source))
         (interval (getf spec :interval))
         (series (getf spec :series)))
    (cond
      ((not (stringp name))
       (values nil (format nil "\"name\" is ~s — it must be a string" name)))
      ((and interval (not (and (numberp interval) (plusp interval))))
       (values nil (format nil "\"interval\" is ~s — it must be a positive number of seconds" interval)))
      ((and source (not (listp source)))
       (values nil "\"source\" is not a JSON object"))
      ((and source (listp source)
            (/= 1 (count-if #'identity (list (getf source :command)
                                             (getf source :file)
                                             (getf source :job-output)))))
       ;; **EXACTLY ONE KIND**, the same rule as `:span` in the link layer and for the same reason: a
       ;; source with two kinds has no defined precedence, and the answer a head invents here is
       ;; invisible until somebody is watching a number that is not the one they configured.
       ;;
       ;; **AND `source` ITSELF IS GUARDED, which is the bug this line had:** a watcher with NO source
       ;; is legal and useful — it is registered so the pane can show a row saying the file did not do
       ;; what its author meant — but `(listp nil)` is `T`, so an unguarded `count-if` over a NIL
       ;; source counts ZERO kinds and refuses the file with a complaint that begins `must name
       ;; exactly ONE`. MEASURED: it made `c-no-source.json` an error instead of a registered watcher.
       (values nil "\"source\" must name exactly ONE of command, file, job_output"))
      (t
       ;; the units, BEFORE the first sample, which is what makes the floor table live — see
       ;; `dash-series-declare` and §7 of the design
       (dolist (s series)
         (let ((sname (getf s :name))
               (unit (or (getf s :unit) "")))
           (when (stringp sname)
             (dash-series-declare (if (search "." sname) sname (format nil "~a.~a" name sname))
                                  unit))))
       (values (list :name name :file path :scope scope :spec spec :watch watch
                     :source source :series series :interval interval :state 0 :job nil)
               nil)))))

(defun dash-watcher-load (&optional (head nil) dirs)
  "Read every watcher file and register the watchers and their sinks. Returns
`(values COUNT ERRORS)`.

**The same rule as the dashboards directory, which is the answer to *what does a head do with a file
it cannot understand*: no file can stop the head from starting, and no file can stop another file
from working.** A malformed one is a line in the pane and nothing more. A watcher whose source cannot
run — the workspace `command` case above is the one that exists today — is REGISTERED and `refused`,
so the pane can say which file to edit rather than the file being invisible.

DIRS defaults to `dash-watchers-dirs` and is a parameter for the suite's reason: a test must not read
the operator's own directory."
  (let ((specs (make-hash-table :test #'equal))
        (errors '())
        (n 0))
    ;; lowest precedence first, so a workspace file overwrites a user one by name
    (dolist (dir (or dirs (dash-watchers-dirs head)))
      (dolist (candidate (%dash-watcher-candidates dir))
        (multiple-value-bind (wname entry errs)
            (%dash-watcher-read-one (car candidate) (cdr candidate))
          (setf errors (append errs errors))
          (when wname (setf (gethash wname specs) entry)))))
    ;; **STOP WHAT IS RUNNING BEFORE THE TABLE IS REPLACED**, or a reload leaves a sampler pointing at
    ;; a watcher nobody can see — running for ever with no row left to stop it.
    (maphash (lambda (k w) (declare (ignore k)) (when (dash-watcher-running-p w) (dash-watcher-stop w)))
             *dash-watchers*)
    (clrhash *dash-watchers*)
    (clrhash *dash-sinks*)
    (maphash (lambda (wname entry)
               (multiple-value-bind (landed errs) (%dash-watcher-add wname entry)
                 (setf errors (append errs errors))
                 (when landed (incf n))))
             specs)
    (setf *dash-file-errors* (nreverse (append errors *dash-file-errors*)))
    (values n errors)))

(defun %dash-watcher-read-one (path scope)
  "PATH as `(values WNAME ENTRY ERRORS)`. WNAME is NIL when nothing could be read.

**Extracted from `dash-watcher-load`, and that is a bug fix rather than tidying.** The nesting there
had grown to four lambdas, and a `handler-case` buried that deep is a handler whose VARIABLE cannot
be seen: SBCL reported `E is undefined` about a clause that reads perfectly well, because an earlier
paren had closed the protected form early and left the clause outside its own `handler-case`. Shallow
is not a style preference here — it is what made the defect findable."
  (handler-case
      (multiple-value-bind (spec msg) (dash-read-spec-file path)
        (if msg
            (values nil nil (list (cons path msg)))
            (progn
              (dash-spec-format-check spec path)
              (let* ((wname (or (getf spec :name) (%dash-file-stem path)))
                     (enabled (if (member :enabled spec) (getf spec :enabled) t)))
                (if enabled
                    (values wname (list :spec spec :path path :scope scope) nil)
                    (values wname (list :off t :path path) nil))))))
    (error (e) (values nil nil (list (cons path (format nil "~a" e)))))))

(defun %dash-watcher-add (wname entry)
  "Register ONE decoded watcher ENTRY under WNAME, and its sinks. Returns `(values LANDED ERRORS)`.

**ERRORS ARE RETURNED AND NOT PUSHED**, and that is not a style choice: a `push` inside this function
would set a LOCAL binding, so the caller's list would never see the pair and a broken sink would be
silent with nothing on the pane. The caller owns the accumulation for exactly that reason."
  (if (getf entry :off)
      (values nil nil)
      (multiple-value-bind (watcher err)
          (handler-case (dash-watcher-from-spec (getf entry :spec) (getf entry :path)
                                                (getf entry :scope))
            (error (e) (values nil (format nil "~a" e))))
        (cond
          (err (values nil (list (cons (getf entry :path) err))))
          (t
           (setf (gethash wname *dash-watchers*) watcher)
           (let ((errs '()))
             (dolist (sink (getf (getf entry :spec) :sinks))
               ;; **A SINK NAME COLLISION BETWEEN FILES IS REPORTED, NOT SILENTLY RESOLVED.** Two
               ;; watcher files that each declare a sink called `node` are both right and would both
               ;; work alone — but a sink name is a KEY in `*dash-sinks*`, so the second registration
               ;; REPLACES the first and the first watcher's series stop being pushed with nothing on
               ;; the pane to say so. MEASURED: my own two watcher files did exactly this while I was
               ;; proving retention, and the first one's readings simply stopped.
               ;;
               ;; The same rule as every other broken-file case: the file is not refused, the working
               ;; half still works, and the pane carries one line naming both files. A file that
               ;; declares ONE sink is unaffected, and the default name is qualified by the watcher
               ;; (`<watcher>-sink`), so the ordinary case cannot collide at all.
               (let* ((sname (or (getf sink :name)
                                 (format nil "~a-sink" (getf watcher :name))))
                      (prior (gethash sname *dash-sinks*))
                      (pfile (and prior (getf prior :file))))
                 (when (and pfile (not (equal pfile (getf entry :path))))
                   (push (cons (getf entry :path)
                               (format nil "sink ~a is already declared by ~a — this file's series would not be pushed under it"
                                       sname (file-namestring pfile)))
                         errs)))
               (handler-case
                   (multiple-value-bind (sname serrs) (dash-sink-add-from-spec sink watcher)
                     (declare (ignore sname))
                     ;; a `retain` that could not be read is REPORTED here, one level out from the
                     ;; sink — the publisher still works, and the pane says which key was ignored
                     (dolist (e serrs) (push e errs)))
                 (error (e) (push (cons (getf entry :path) (format nil "~a" e)) errs))))
             (values t (nreverse errs))))))))

;;; ------------------------------------------------------------ 4. the sinks ;;;

