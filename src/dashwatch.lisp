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

(defvar *dash-sinks* (make-hash-table :test #'equal)
  "sink name → a plist:

  :name    what the pane calls it
  :file    the watcher file that declared it
  :kind    \"flowy\" (the built-in) or \"command\" (the general form)
  :series  the series it publishes
  :command the shell command, run with the body on stdin
  :body    the body template, with `{series}` and `{value}`")

(defvar *dash-sink-errors* (make-hash-table :test #'equal)
  "sink name → the last failure, as a string. **A `defvar` and not a `defparameter`**, for the house
reason: a live push must not throw away what a running head is holding.")

(defvar *dash-sink-stat* (make-hash-table :test #'equal)
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

(defun dash-retain-plist (points seconds)
  "POINTS and SECONDS as the `retain` object the node reads, or NIL when neither is given.

**NIL KEYS ARE OMITTED RATHER THAN SENT AS NULL.** The node's `Retention` is a Go struct of ints, so
`{\"points\":null}` decodes to 0 and means *the default* — which is the right ANSWER by accident. A
body that says what it means is the difference between a protocol and a coincidence."
  (when (or (and points (integerp points) (plusp points))
            (and seconds (integerp seconds) (plusp seconds)))
    ;; the node's own rule, from `TestRetentionOf`: *an age bound alone keeps the default count*, and
    ;; a count alone takes no age bound — so a missing half is ZERO, which is the node's own word for
    ;; "the default" and "no bound" respectively.
    (list :points (if (and points (integerp points) (plusp points)) points 0)
          :seconds (if (and seconds (integerp seconds) (plusp seconds)) seconds 0))))

(defun dash-flowy-body (series value &key points seconds)
  "The body flowy's node reads, MEASURED against the node and then against its SOURCE.

    {\"type\":\"memory\",\"kind\":\"metric\",\"title\":\"<name>\",
     \"fields\":{\"name\":\"<name>\",\"value\":<v>,\"retain\":{\"points\":N,\"seconds\":M}}}

**`retain` GOES INSIDE `fields`, AND THAT IS THE WHOLE CORRECTION** (R56, fifth amendment).
`flowy/internal/store/dashboards.go:585` reads it off the row's FIELDS:

    func RetentionOf(a *Artifact) Retention { ... json.Unmarshal(a.Fields, &outer) ... }

so `fields.retain` is the policy and a TOP-LEVEL `retain` is an unknown field the door refuses with
400 — which is what I measured, honestly, against the wrong shape. The briefing had the nesting wrong
and I tested the briefing's shape instead of the document's; §11 records that, because a doc that says
who got it wrong is the only kind that stops it recurring.

**And retention is real, not cosmetic.** `RetainDefaultPoints = 4096` (`dashboards.go:567`), the
ceiling is `RetainMaxPoints = 65536`, the ceiling cannot be raised by a producer (*\"keep ten million
is a denial of service written as a preference\"*), and it is wired on the WRITE path —
`artifacts.go:340` calls `pruneAfterMetric` → `pruneSeries`, enforcing points AND seconds. So a
`retain` here is a CAPABILITY: a `produced` counter on an overnight import wants a different window
from a load average, and `seconds` suits a watcher that samples rarely.

**Built by `json-encode-to-string`** rather than a format string, because the tree already has one
JSON convention (`src/json.lisp`) and hand-rolling a second is how a series name with a quote in it
becomes a body the node rejects."
  (let ((retain (dash-retain-plist points seconds)))
    (json-encode-to-string
     (list :type "memory" :kind "metric" :title series
           :fields (if retain
                       (list :name series :value value :retain retain)
                       (list :name series :value value))))))

(defun dash-retain-from-value (value what)
  "VALUE (a `retain` from a file) as `(values PLIST ERROR)`.

  · a POSITIVE WHOLE NUMBER is `points` — the short form for the common case;
  · an OBJECT may carry `points`, `seconds`, or both;
  · anything else is REPORTED and omitted, never sent.

**REPORTED AND OMITTED RATHER THAN REFUSED, and the two halves come from two different places.**
The node tolerates a garbage hint by DESIGN — `dashboards.go:591`'s comment, verbatim: *\"UNPARSABLE IS
THE DEFAULT, NOT AN ERROR. This is read on the write path, and losing a measurement to protect the
housekeeping is the wrong trade.\"* That is right for a SERVER reading a row, and this is not that: a
`retain` in a watcher file is a person's typo, they are sitting in front of the pane, and a key that
silently does nothing is the defect this whole feature keeps naming. So the omission is total (nothing
malformed is ever posted) and the report is a line the operator can act on."
  (cond
    ((null value) (values nil nil))
    ((and (integerp value) (plusp value)) (values (list :points value) nil))
    ((listp value)
     (let ((p (getf value :points))
           (s (getf value :seconds)))
       (cond
         ((and (or (null p) (and (integerp p) (plusp p)))
               (or (null s) (and (integerp s) (plusp s)))
               (or p s))
          (values (list :points (or p 0) :seconds (or s 0)) nil))
         (t (values nil (format nil "~a: \"retain\" must carry a positive whole \"points\" or \"seconds\"~@[ (got points ~s)~]~@[ (got seconds ~s)~]"
                                what p s))))))
    (t (values nil (format nil "~a: \"retain\" is ~s — it must be a number of points, or an object with points/seconds"
                           what value)))))

(defun dash-sink-retains (spec watcher series)
  "The retention each of a sink's SERIES is pushed with, as `(values ALIST ERRORS)`.

ALIST is `((FULLY-QUALIFIED-SERIES . PLIST) …)`, keyed by the names the sink actually PUBLISHES —
the caller passes them in already qualified, and **that is a bug fix rather than a convenience**: the
first cut built this list from the FILE's names, which are unqualified, so every key missed the
qualified series the body function looks up and no `retain` was ever applied. MEASURED on the live
head: `:RETAINS ((\"load1\") (\"srcfiles\"))` — right shape, wrong keys, silently no retention.

**THREE PLACES CAN SAY IT, AND THE ORDER IS THE POINT.** A series knows its own push rate best —
`dashboards.go:572`'s own argument for carrying retention on the reading at all: *\"a node-wide number
cannot be right for a series sampled every five seconds and one pushed hourly at the same time.\"* So
the most specific wins:

  1. the sink's `series` entry as an OBJECT — the last word, and the only place that can override what
     the series itself declared;
  2. the watcher's `series` declaration — where a series already describes itself (unit, label), and
     therefore its natural home;
  3. the sink's own `retain` — the default for everything that sink publishes.

**A `retain` THAT CANNOT BE READ IS REPORTED AND OMITTED.** The errors land on the pane and nothing
malformed is ever posted. The node tolerates a bad hint by design (it would rather keep a measurement
than lose one), but a typo in a FILE is a person sitting in front of the pane, and a key that silently
does nothing is the defect this feature keeps naming."
  (let ((errors '())
        (default nil)
        (sink-per '())
        (watch-per '())
        (file (getf watcher :file))
        (wname (getf watcher :name)))
    (flet ((take (value)
             ;; **`PROGN` AND AN EXPLICIT NIL, because `(if e (push …) r)` returns the PUSHED LIST** when
             ;; the test is true — so a malformed `retain` leaked the whole error list in as the
             ;; DEFAULT. MEASURED: the test asserting that nothing malformed is carried caught it.
             (multiple-value-bind (r e) (dash-retain-from-value value file)
               (if e (progn (push (cons file e) errors) nil) r)))
           (qualify (n)
             (if (search "." n) n (format nil "~a.~a" wname n))))
      (setf default (take (getf spec :retain)))
      ;; **THE SINK'S OWN ENTRIES COME FIRST, BECAUSE AN ALIST IS SEARCHED FRONT TO BACK** and the
      ;; most specific thing said about a series has to be found FIRST. The first cut pushed both
      ;; lists and `nreverse`d the whole thing, which put the WATCHER's entry in front — so the least
      ;; specific rung won. MEASURED by the test asserting the sink's override.
      (dolist (s (getf spec :series))
        (when (and (listp s) (stringp (getf s :name)) (member :retain s))
          (let ((r (take (getf s :retain))))
            (when r (push (cons (qualify (getf s :name)) r) sink-per)))))
      (dolist (s (getf watcher :series))
        (when (and (stringp (getf s :name)) (member :retain s))
          (let ((r (take (getf s :retain))))
            (when r (push (cons (qualify (getf s :name)) r) watch-per))))))
    (setf per (append (nreverse sink-per) (nreverse watch-per)))
    (values (mapcar (lambda (s)
                      (cons s (or (cdr (assoc s per :test #'string=)) default)))
                    series)
            errors)))

(defun dash-flowy-seat-file (seat)
  "Where a seat's environment lives: `~/.config/flowy/env-<seat>`.

MEASURED convention, taken from the systemd units on this box — `gpu-metrics.service` sources
`%h/.config/flowy/env-claude-lab2x1`, and its own comment says why it cannot use `EnvironmentFile=`:
*\"That parser takes only literal KEY=value: it rejects the `export` prefix and cannot evaluate the
`$(cat ...)` that reads the seat token.\"* So the file is SOURCED, and this head never reads it."
  (let ((home (uiop:getenv "HOME")))
    (and home (merge-pathnames (format nil "env-~a" seat)
                               (merge-pathnames ".config/flowy/"
                                                (uiop:ensure-directory-pathname home))))))

(defun dash-flowy-command (seat seat-file addr timeout)
  "The shell command a flowy sink runs: source the seat's environment, then POST the body on STDIN.

**THE TOKEN NEVER ENTERS THIS HEAD.** The head checks that SEAT-FILE exists and then the SHELL
sources it, so the credential is in one process's environment for the length of one curl. It is not
in the pane, not in a log, and not in `*dash-sinks*` — which is what makes a watcher file safe to
commit, and is the property that makes this feature shippable at all.

**And it is a refusal rather than a fallback.** `set -a; . missing; set +a` leaves `$FLOWY_TOKEN`
EMPTY, curl sends `Bearer `, and the node answers 401 — a misconfiguration that reads as a node
problem. The caller refuses before this command is ever built (`dash-sink-add-from-spec` checks the
file exists), and `${FLOWY_TOKEN:?…}` is the second belt: a message, not a silent unauthenticated
post. Every expansion is quoted through `%dash-sh-quote`, because these values come out of a file."
  (format nil "set -a; FLOWY_ADDR=~a; . ~a 2>/dev/null; set +a; : \"${FLOWY_TOKEN:?no FLOWY_TOKEN after sourcing ~a}\"; exec timeout ~d curl -s -m ~d -o /dev/null -w '%{http_code}' -X POST -H \"Authorization: Bearer $FLOWY_TOKEN\" -H 'Content-Type: application/json' --data-binary @- \"$FLOWY_ADDR/api/artifacts\""
          (%dash-sh-quote addr)
          (%dash-sh-quote (namestring seat-file))
          (namestring seat-file)
          timeout timeout))

(defun dash-sink-add (name &key kind series command body body-fn file (retain 200) retains timeout)
  "Register a sink. Returns NAME.

A sink PUBLISHES readings: `dash-sinks-run` calls COMMAND once per series with the body on stdin.
**The `command` kind is the general form and `flowy` is a convenience over it**, not a second
mechanism — the built-in only fills in a command and a body that any file could have written out by
hand, which is what makes `curl` the first sink rather than a special case.

**`BODY-FN` IS FOR A BODY THE TEMPLATE CANNOT SAY.** A `body` template is a string with `{series}`
and `{value}` in it, which is enough for any flat JSON object and NOT enough for the metric row: that
one NESTS (`fields:{name,value}` inside the row), so no template could produce it.

MEASURED, and the node said so out loud: the flowy sink written as a template got **HTTP 400 for
every series**, because the head was posting a flat `series`/`value` object to a door that wanted
`{type,kind,title,fields}`. A function of `(series value)` is the honest shape for the one body this
feature ships; the template stays for everything a person writes out by hand."
  (setf (gethash name *dash-sinks*)
        (list :name name :kind (or kind "command") :series series
              :command command :body body :body-fn body-fn :file file
              :retain retain :retains retains :timeout (or timeout 15)))
  name)

(defparameter +dash-flowy-addr-default+ nil
  "No address is baked in. A sink names its own `addr`, or the head's environment carries
`FLOWY_ADDR`, and **neither is a fallback for the other being wrong** — a default here would be a
box's address in the source of a head that runs on every box.")

(defun dash-flowy-addr (spec)
  "The node address for SPEC: its own `addr`, or the head's `FLOWY_ADDR`. NIL when neither."
  (or (getf spec :addr)
      (let ((env (uiop:getenv "FLOWY_ADDR"))) (and env (plusp (length env)) env))))

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
                     ;; **AND A `retain` THE FILE NAMED IS SAID OUT LOUD** — the node refuses that key,
                     ;; so the head does not send it. A config option that silently does nothing is
                     ;; worse than one that refuses, and this is the line that refuses it.
                     (cons (if (getf sink :retain-refused)
                               (format nil "  (retain ~a ignored: this node answers *unknown field retain*)"
                                       (getf sink :retain-refused))
                               "")
                           '(:dim t)))
               rows)))
     *dash-sinks*)
    (nreverse rows)))

(defun dash-watcher-count ()
  "How many watchers are running, for the pane's heading."
  (let ((n 0))
    (maphash (lambda (k w) (declare (ignore k w)) (incf n)) *dash-watchers*)
    n))

(defun dash-watchers-reset ()
  "Forget every watcher and sink, and stop their samplers. The suite's door; a live reload does NOT
do this, because a reload must not throw away a running watcher's history."
  (maphash (lambda (k w) (declare (ignore k)) (dash-watcher-stop w)) *dash-watchers*)
  (clrhash *dash-watchers*)
  (clrhash *dash-sinks*)
  (clrhash *dash-sink-errors*)
  (clrhash *dash-sink-stat*)
  (values))
