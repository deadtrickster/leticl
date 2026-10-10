;;;; retain — what a reading retains, and the flowy seat a sink posts to
;;;;
;;;; Split out of `dashwatch.lisp`, which was one 1016-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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
        (per nil)
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
    ;; **`per` WAS AN UNDECLARED FREE VARIABLE** — bound nowhere above and not a `defvar`
    ;; anywhere in the tree, so this `setf` created a global `LETICL::PER` and the retain tests
    ;; passed on a value nothing else could see (found by the dashboard reviewer, 2026-10-11).
    ;; One `let` entry, and the binding is what it always read like.
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

