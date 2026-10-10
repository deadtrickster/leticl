;;;; the-operator-call-door — the operator-call door (R24 part two)
;;;;
;;;; Split out of `protocol.lisp`, which was one 783-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- the operator-call door (R24 two) ;;;
;;;
;;; The daemon ENFORCES which tools a head may run for the operator and PUBLISHES the
;;; names, so a head never holds a copy of the list. This is the same rule letibot
;;; states for `SettingRow.choices` — *"the head had its own copy of the mode names and
;;; it drifted"* — and the row exists exactly so a head that is never rebuilt still
;;; offers the door the daemon is currently willing to open.

(defparameter +head-run-tools-key+ "head-run.tools"
  "The settings row carrying the operator-call door's names, comma-joined in `value`.
The daemon's `HEAD_RUN_TOOLS_KEY`, and the ONE place this head knows it by name.")

(defun %split-commas (value)
  "VALUE split on `,` with each piece trimmed and empties dropped.
*Comma-joined; no spaces* is what the daemon promises, and tolerating a space costs
one trim and buys a head that still reads a hand-written row."
  (loop with n = (length value)
        for start = 0 then (1+ end)
        for end = (or (position #\, value :start start) n)
        for piece = (string-trim '(#\space #\tab) (subseq value start end))
        unless (zerop (length piece)) collect piece
        while (< end n)))

(defun head-run-tools (settings)
  "The names this daemon will let this head run for the operator, or NIL for NO DOOR.

**NIL is a fact and not an empty list.** A daemon older than the row offers no door at
all, and a head that invented a list would offer one the daemon will refuse — the same
*do not guess the disclosure* rule this head follows for every absent field. A row that
IS there with an empty `value` means the same thing to a head choosing what to offer,
because a door with no names opens on nothing.

Read from the row's `value` and never from a constant in this file: that is the whole
reason the row exists. `the-door-is-the-daemons-list…` in the suite asks a row naming
DIFFERENT tools and gets them back, which a copy in this file could not do."
  (let ((row (and settings
                  (find +head-run-tools-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (when row (%split-commas (or (getf row :value) "")))))

(defvar *call-counter* 0
  "A monotonic counter for `call_id`s, for the reason `*request-counter*` is one: a live
push must not rewind it, or two calls on an open socket could share an id.")

(defun next-call-id ()
  "THIS head's handle for one operator-run call, unique in the session.

Deliberately NOT `next-request-id`. The two travel on the same frame and answer
different questions: `client_request_id` says *which ask is this a reply to*, and
`call_id` is what the daemon keys the admission by and what this head matches the
permission against. The corpus row is `op-<call_id>`, so the prefix here is
`headrun-`; reusing `leticl-N` would make that row read `op-leticl-7`, a name that
looks like a request id in a column that is not asking for one."
  (format nil "headrun-~d" (incf *call-counter*)))

(defun head-run-descriptors (settings)
  "Per tool, what the DAEMON says a bare line means — or NIL when it has said nothing.

An alist `(NAME :FIELD \"query\" :KIND \"text\" :DEFAULTS ((\"limit\" . \"10\")) :WHY-JSON \"\")`, read
off the `head-run.tools` row and never merged with anything this file knows. **A tool missing
from it is a tool whose bare form this head cannot build**, and the caller says so rather than
guessing a field name — which is the one thing the whole row exists to prevent.

**WHERE IT IS READ FROM, and this was wrong once — measured, not assumed.** The daemon carries
these as a TYPED FIELD on the row that already publishes the door's names: `SettingRow.tools`,
an array of `HeadRunTool { name, field, kind, defaults, why_json }`. It is not a second row.
The first cut of this file invented a `head-run.arguments` row with the descriptors as JSON
*text* in `value`, which is a shape no daemon has ever sent — it was the shape convenient on
this side, and a head that invents the other half's grammar is committing the same defect as
one that guesses its list.

  · **`:field`** is where the sentence goes. Empty means this tool has no single obvious field,
    and then `:why-json` carries the daemon's OWN sentence saying why — said in the daemon's
    words rather than in a head-side guess at them.
  · **`:kind`** is `path`, `url` or `text` (R32): what the field IS, so Tab can complete it
    without this head holding a list of which tools take paths. Closed on purpose — a head
    branches on it, so a fourth value is a head rebuilt.
  · **`:defaults`** maps a name to **JSON TEXT, not to a JSON string**: the daemon renders a
    numeric default as `10` and a string one unquoted, so a value here is spliced into the
    arguments as raw JSON. Encoding it as a string would send `{\"limit\":\"10\"}` where the
    daemon sends `{\"limit\":10}`, and the same tool would answer two different questions
    depending on who asked.

**NIL is a fact and not an empty list**, on `head-run-tools`' own rule: a daemon older than the
field sends no `tools` at all, and a head that invented descriptors would offer a form the
daemon cannot answer."
  (let ((row (and settings
                  (find +head-run-tools-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (loop for d in (and row (getf row :tools))
          when (and (consp d) (stringp (getf d :name)) (plusp (length (getf d :name))))
            collect (cons (getf d :name)
                          (list :field (or (getf d :field) "")
                                :kind (or (getf d :kind) "")
                                :defaults (getf d :defaults)
                                :why-json (or (getf d :why-json) ""))))))

(defparameter +daemon-verbs-key+ "daemon.verbs"
  "The settings row on which the DAEMON publishes the verbs IT answers — R32's third constraint.

**A head completes `/`-commands from a table, and a head that does not recognise a verb
FORWARDS it.** So the namespace has two owners, and neither may enumerate the other's half:
this head offers its own verbs from `*slash-commands*`, and these from the row the daemon
publishes.

The measured reason, 2026-09-23 (`scripts/slash-audit`): this head forwards five names that
appear in its source only as string literals, and `/gate`, `/flowy` and `/job` do not appear in
this tree AT ALL — so no amount of reading it finds them. That is the shape and not an
oversight, and the daemon's list is the authority for the daemon's half.

`value` is the names, comma-joined with no spaces. **An absent row is a daemon older than this
one**, and the head then offers its own verbs and says nothing about the rest rather than
guessing.")

(defun head-daemon-verbs (settings)
  "The verbs the daemon answers, as IT published them, or NIL when it has not said.

Read from the row's `value` and never from a constant in this file — the same reason
`head-run-tools` reads its own row and not a list. NIL and the empty list mean the same thing to
a head choosing what to offer, which is what an empty row comes back as."
  (let ((row (and settings
                  (find +daemon-verbs-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (when row (%split-commas (or (getf row :value) "")))))

(defun make-operator-call (call-id name arguments &optional (expected-seq 0))
  "Frame 1: the head ASKS, before it runs anything (R24 part two).

`arguments` is the arguments as JSON TEXT — the shape a model's call carries — and it
is a STRING on the wire and not an object, so the head hands the text through without
knowing any tool's schema. That is the point of the pair: the daemon names and enforces
the door, and the head is the environment.

`expected_seq` is the ordinary read mark for a mutating call; 0 is accepted, and it is
what a head that has folded nothing yet honestly has.

**The answer is not this frame's return, and the two answers are different kinds**: a
`Rejected` (the name is not in the door — do not retry) or an `Accepted` (queued, and
NOT permission). The permission is the `operator_call_allowed` EVENT, which arrives once
the admission has been WRITTEN — that is why a head runs nothing on `Accepted`."
  (list :frame "operator_call"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :call-id call-id
        :name name
        :arguments (or arguments "{}")))

(defparameter +tool-outcomes+ '("ok" "abstained" "failed" "denied" "timeout" "not_run" "backgrounded")
  "The `ToolOutcome` variants, MEASURED off the daemon rather than read from source.

Asked for an unknown one, this daemon answers with its own list — *unknown variant `zzz`,
expected one of `ok`, `abstained`, `failed`, `denied`, `timeout`, `not_run`,
`backgrounded`* — so the vocabulary is a fact about the daemon on this box and not about
this file. `+outcomes-taking-a-reason+` is the same measurement one step further: a
`failed` WITHOUT a `reason` is refused by name (*missing field `reason`*) while an `ok`
with one is accepted, so exactly one variant carries it.")

(defparameter +outcome-fields+
  '(("failed"    . "reason")
    ("abstained" . "reason")
    ("not_run"   . "why"))
  "Every payload-carrying variant THIS head's runners can answer, and the field name the daemon wants.

**THE FIELD NAME IS PER VARIANT, WHICH IS THE WHOLE REASON THIS IS A TABLE.** The daemon's
`ToolOutcome` (`crates/transcript/src/lib.rs:415`) has `Abstained{reason}`, `Failed{reason}`,
`Denied{req_id}`, `NotRun{why}` and `Backgrounded{handle, ran_for_ms, how, …}` — so `not_run` wants
`why` and the other two want `reason`, and a head with one hard-coded spelling would send a frame the
daemon refuses for the other. MEASURED by the wire-format reviewer against the enum, 2026-10-11: the
previous table was `(\"failed\")`, which read as *only `failed` carries a field* — it means *only the
three above are ones a runner here answers*, and `denied`/`backgrounded` are refused by name in
`%outcome-fields-this-head-cannot-build` because their fields are the daemon's own values.")

(defparameter +outcomes-taking-a-reason+ (mapcar #'car +outcome-fields+)
  "The variants this head must supply a field for — the table's keys, so the two cannot drift.")

(defun %outcome-field-name (outcome)
  "The field OUTCOME's payload goes in, or NIL for a variant that carries none."
  (cdr (assoc outcome +outcome-fields+ :test #'string=)))

(defun %outcome-fields-this-head-cannot-build (outcome)
  "The variants whose required field this head has no value for, or NIL.

**A FRAME WITH A MISSING REQUIRED FIELD IS NOT ONE FRAME REFUSED — IT IS THE SESSION. The daemon's
read loop fails the whole `ClientFrame` deserialiser and answers `bye`, which this head leaves on**
(the same measurement the constructor's own docstring records for a bare outcome word). So an
outcome this path cannot build COMPLETELY is refused here, where a caller can see it, rather than
sent and lost."
  (cond ((string= outcome "denied") "a request id only the daemon's own refusal carries")
        ((string= outcome "backgrounded") "a job handle and a duration, which are the daemon's to write")
        (t nil)))

(defun make-operator-result (call-id outcome payload &key reason)
  "Frame 2: the head hands back what happened (R24 part two).

**No `expected_seq`, deliberately and not by omission.** This frame does not move the
session, it hands over a fact the session is missing, and a head that asked while the
screen moved still meant it. The daemon appends a `ToolResult` carrying
`origin: Operator { who }` through the same writer a turn's rows go through, so the
model sees the result and every head draws it as the person's act.

**`outcome` IS AN OBJECT, not a word — and getting that wrong ended a live session.**
`ToolOutcome` is an internally-tagged serde enum, so the field is `{outcome: ok}`
and a bare `ok` fails the daemon's deserialiser — which is not one frame refused, it
is the READ LOOP: measured against a real protocol-25 daemon, the reply was

    bye: this connection sent a frame this daemon could not read
         (malformed frame (invalid type: string, expected internally tagged enum ToolOutcome))

and **a `bye` is the end of the session for this head** (`head.lisp`, the `bye` arm), so
the live proof of R24 killed its own head by sending the shape this function used to
build. The same probe measured the rest of the vocabulary: `ok`, `abstained`, `failed`,
`denied`, `timeout`, `not_run`, `backgrounded`, and `failed` REQUIRES a `reason`.

**AND A PAYLOAD-CARRYING VARIANT WITHOUT ITS FIELD IS THE SAME DEATH one step along**: the
daemon refuses a `failed` with no `reason` by name (*missing field `reason`*), so a runner
answering `abstained` or `not_run` without one would end the session it was reporting on. A
`reason` alone cannot say which field a variant wants, so the table is explicit and the two
variants this path cannot build COMPLETELY are refused rather than guessed.

REASON is that field, and it is passed only for the variants that take one — an `ok`
carrying a `reason` happens to be accepted today (serde ignores it) and would be the same
kind of guess one variant later."
  (let ((impossible (%outcome-fields-this-head-cannot-build outcome))
        (field (%outcome-field-name outcome)))
    (when impossible
      (error "a `~a` outcome is not this head's to build: it needs ~a" outcome impossible))
    (when (and field (or (null reason) (zerop (length reason))))
      (error "a `~a` outcome with no ~a is a frame the daemon refuses by name — and its read loop goes with it"
             outcome field))
    (list :frame "operator_result"
          :call-id call-id
          :outcome (if field
                       (list :outcome outcome (intern (string-upcase field) :keyword) reason)
                       (list :outcome outcome))
          :payload (or payload ""))))

