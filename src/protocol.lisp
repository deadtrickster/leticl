;;;; protocol.lisp — the head frame vocabulary, protocol version 25.
;;;; Source of truth: crates/sessionlog/src/protocol.rs. Frames are plists in
;;;; the image (PLAN.md §7, D4); the constructors below are the only place
;;;; that knows what a frame looks like on the wire.
;;;;
;;;; The rules inherited with the shape (protocol.rs, top of file):
;;;; 1. Ack.seq comes from the batch, not from the kept events.
;;;; 2. Fields whose presence is the disclosure (dropped, created) are always
;;;;    written, present and zero/null rather than omitted.
;;;; 3. Every mutating command carries client_request_id and expected_seq.

(in-package #:leticl)

(defparameter +protocol-version+ 25
  "The version this head announces at ATTACH, and the number is a CLAIM rather than a flag.

The protocol's only compatibility check is EQUALITY at ATTACH, so a head that announces a
version is saying *I know what those frames are* — and a head that announces a number it does
not understand has traded a clear refusal for a mid-session surprise. So what 24 and 25 added
is written down here rather than assumed:

  · **25** is TWO FIELDS, both additive and both from this head's own asks (letibot
    `bc852c7`): `unsure: Option<String>` on the wire `ModelAdvice`, carrying
    `UnsureKind::as_str()` — the token, so the card can say WHICH of four non-answers it was
    instead of echoing prose; and `FetchDiagnostic { request_id, kind }` answered by
    `Diagnostic { request_id, kind, body: Option<String>, total }`, the locator for the
    oracle's brief and reply.
  · **24** is R24 part two, the operator's own tool call: `ClientFrame::OperatorCall`,
    `ClientFrame::OperatorResult`, `SessionEvent::OperatorCallAllowed`, the
    `head-run.tools` settings row, and `CallOrigin::Operator { who }` on a tool row.

**Why announcing 25 is honest for a head that uses none of it yet**: every one of those is
additive, this head SENDS only what it sent at 23 unless a feature is being used, and a frame
or event it does not fold is already reported and survived rather than dropped (R3). The
version is not a promise to use everything; it is a promise not to be surprised by it.

**Measured before the bump, against the daemon on this box** — because a version is a fact
about a running process, not about a constant in a file I can read: 23 and 24 are refused at
ATTACH (`bye: protocol version 23, this daemon speaks 25`) and 25 answers `hello`.")
;; 23 is `SessionEvent::Filling { what, unit, done, total }` — a **named** operation
;; the daemon is filling rows for, with its own counter (letibot `4d01aca`). It
;; replaced `ImportProgress`, which was the same event under a narrower name: four
;; things look identical from a head (an import, a reseat, a compaction, an ordinary
;; turn) because all four announce rows before their bodies, and the head that tried
;; to tell them apart drew *"carrying the conversation onto the new prompt"* over
;; every ordinary reply. `what` is the daemon's own words and `unit` is what its
;; count is in — `parts` for an import, `rows` for a carry — because those are not
;; the same thing. `SessionEvent` is internally tagged, so a 22 head meeting one
;; mid-session fails that line and nothing else. See R9.
;;
;; The rename is why this head's fold carried a compatibility arm for
;; `import-progress` between the two letibot commits: it was a translation table for
;; a rename in flight, it said so, and it was DELETED when the rename landed rather
;; than left to become a second spelling for ever.
;;
;; 22 is `ReadJobOutput` + the `JobOutput` event — the pane reads a job's window
;; instead of posting `/job ID` into the conversation. The reference landed both
;; at 21 and left the CONSTANT at 21, so ATTACH agreed and the skew surfaced
;; mid-session: the daemon could not parse the frame, its read loop broke, and
;; the socket went with nothing said (letibot `872f8dd`). It bumped to 22 and
;; made a frame it cannot read send a `Bye` naming both versions first. Our
;; `job-output` work is that feature, so this head spoke 22 too.
;; 21 added ListJobs (a read-only frame answered at once, not through the command
;; queue: `/job` during a long turn used to arrive after the turn ended, which is
;; useless for a pane that opens).
;; 19 added WithdrawPrompts (a queued prompt can be taken back into the
;; composer; consecutive queued messages merge daemon-side), 20 added Stop
;; (the head asks whether the daemon goes too, instead of a second terminal
;; and letibot --stop). Both are client frames, hence the ATTACH-time refusal
;; that told us about the bump in the first place.

;;; ------------------------------------------------- other halves' versions ;;;
;;;
;;; **The protocol version is compared at the HANDSHAKE, the DIRECTION is named, and
;;; the head does not exit.** The daemon's ATTACH check is exact equality and it is
;;; the strict first line; this is the head's own, and it is not redundant for the
;;; reason the whole skew sequence exists: **the two halves are built and run
;;; separately.** A check is a thing a protocol GAINS at some version, so a daemon
;;; older than the check has none — and a check is a candidate for being relaxed,
;;; which is the direction `R3` itself argues for, since *a skew is usually
;;; survivable* is exactly why an unknown event is passed through. A head must not be
;;; silent about a skew because it is trusting the other side to have mentioned it.
;;;
;;; **The direction is not decoration: the two cases are different problems.**
;;;
;;;   · **A NEWER daemon is a READING problem, and a head survives it.** What arrives
;;;     is a frame with a tag this build has never heard of, because it was added
;;;     after this head was built. That is what `note-unreadable` answers: the line is
;;;     kept, the sentence names it, the count goes on `/status`, and the reader
;;;     carries on. Nothing is lost but what the unknown frame said, which is exactly
;;;     the part this build cannot use.
;;;   · **An OLDER daemon is a WRITING problem, and a head cannot survive it from its
;;;     side.** Everything this head reads parses — the older half wrote it. What
;;;     breaks is the other direction: a `ClientFrame` the daemon has never heard of
;;;     fails ITS deserialiser, and its read loop answers by saying goodbye and
;;;     closing the socket. **That is the case worth reading twice**: it is silent
;;;     until it is fatal, and the operator is entitled to know before they spend an
;;;     hour in a session that is going to drop on them.
;;;
;;; Neither sentence tells anybody to leave, and that is deliberate: a head that
;;; exited at the handshake would never get to use `R3`, which is the mechanism that
;;; makes surviving a skew real (letibot `787092b` on the same reasoning).

(defvar *daemon-protocol* nil
  "The protocol version the daemon last TOLD this head, or NIL for not told yet.

NIL is a different statement from a number and `/status` renders it as one — the
same distinction the empty-transcript banner draws. A `defvar` rather than a head
slot: a struct layout change is a restart, and a live push of this head must not
need one. Set from every `Hello`, so a `Switch` updates it and a reconnect re-states
it.")

(defun protocol-skew-said (daemon head)
  "The sentence about a version skew, or NIL when there is none to say.

ONE function, in the protocol's own file beside the number it is about, so every
head says the same thing the same way — a sentence that lives in a head is a
sentence the next head rewrites.

HEAD is passed rather than taken from `+protocol-version+` so the function is a
question about two numbers and can be tested as one. The daemon is named FIRST in
the sentence, and the direction is spelled out, because a bare pair of numbers makes
the reader work out which side they are on — and which side they are on changes what
they should expect to happen next."
  (when (and (integerp daemon) (integerp head) (/= daemon head))
    (if (> daemon head)
        (format nil "this daemon speaks protocol ~d and this head speaks ~d: the daemon is ~
                     from a NEWER build. Frames it sends that this build does not know are ~
                     reported as they arrive, counted on /status, and skipped — the ~
                     connection stays up and the rest of the stream is unaffected. ~
                     Restarting the daemon so both halves are the same build is the way ~
                     to stop seeing them."
                daemon head)
        (format nil "this daemon speaks protocol ~d and this head speaks ~d: the daemon is ~
                     from an OLDER build. Everything this head reads is fine; what is not ~
                     safe is what it SENDS — a command the daemon has never heard of fails ~
                     its reader, and it answers by saying goodbye and closing the socket. ~
                     The session can end on the next command the two do not share. ~
                     Restarting the daemon is the way to make them the same build."
                daemon head))))

;;; Why a Rejected was sent — stable codes a head branches on (protocol.rs).
(defparameter +reject-stale-seq+ "stale expected_seq")
(defparameter +reject-unknown-decision+ "no such open decision")
(defparameter +reject-read-only+ "this head declared can_decide: false")
(defparameter +reject-unknown-session+ "no such session")
(defparameter +reject-not-in-store+ "no such session in the store")

;;; The note on a prompt/compact accepted behind a running turn.
(defparameter +note-prompt-queued+ "queued as a user item")
(defparameter +note-compact-queued+ "queued after the running turn")

;; defvar: a monotonic counter a live push must not rewind, or request ids
;; could repeat on a socket that is already open.
(defvar *request-counter* 0)

(defun next-request-id ()
  "Unique per head connection is all the daemon needs; monotonic across a
Switch, which reuses the socket (protocol.rs on ClientFrame::Switch)."
  (format nil "leticl-~d" (incf *request-counter*)))

;;; ------------------------------------------------------------- decoding ;;;

(defun decode-frame (line)
  "One wire line to a plist. Malformed JSON raises wire-error with the line
kept, per wire.rs — a decoder that reports \"bad frame\" without the frame
turns a precise complaint into a shrug."
  (handler-case (json-decode line)
    (error (e) (error 'wire-error :line line :detail (format nil "~a" e)))))

(defun encode-frame (frame)
  (json-encode-to-string frame))

(defun frame-name (frame) (getf frame :frame))
(defun event-name (event)
  "The event tag as a keyword. The wire sends it as a snake_case string
(event.rs:380, #[serde(tag = \"event\", rename_all = \"snake_case\")]) and the
matchers in apply-event and %handle-frame speak keywords — \"turn_started\"
must become :turn-started or no case arm ever matches and every live event is
silently dropped (measured: seq climbed, nothing rendered, prompts stuck
queued)."
  (let ((s (getf event :event)))
    (and s (%key-from-wire s))))

;;; ---------------------------------------------------------- constructors ;;;
;;; Field order follows protocol.rs so a diff against the Rust reads naturally.
;;; Keys whose value is nil are omitted by the caller's choice here — serde
;;; defaults them daemon-side — except where presence itself is the disclosure.

(defun make-attach (&key (session-id "") (since-seq 0) (kind "tui") identity
                      (queue 1024) (can-decide t) features)
  (list :frame "attach"
        :protocol-version +protocol-version+
        :session-id session-id
        :since-seq since-seq
        :kind kind
        :identity (or identity "")
        :caps (append (list :queue queue :can-decide can-decide)
                      (when features (list :features features)))))

(defun make-ack (seq rendered filtered)
  "The read mark. seq is the last seq CONSUMED from the batch, rendered or
not — there is deliberately no other way to obtain one (protocol.rs on Ack)."
  (list :frame "ack" :seq seq :rendered rendered :filtered filtered))

(defun make-resync ()
  (list :frame "resync"))

(defun make-prompt (expected-seq text)
  (list :frame "prompt"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :text text))

(defun make-interrupt (expected-seq reason)
  (list :frame "interrupt"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :reason reason))

(defun make-withdraw-prompts (expected-seq)
  "Take back what this head queued — the original leaves the daemon's queue so
the operator can edit it rather than stack under it (protocol.rs, v19)."
  (list :frame "withdraw_prompts"
        :client-request-id (next-request-id)
        :expected-seq expected-seq))

(defun make-stop (expected-seq who)
  "Stop the daemon, not just this head — one shutdown sequence, every head
wakes with Closed (protocol.rs, v20)."
  (list :frame "stop"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :who who))

(defun make-answer (req-id option-id &optional pattern note)
  "Grant or deny a permission, by option id.

PATTERN is the operator's own glob, for always-allow only. NOTE is what they
want the MODEL told, for `deny_and_tell` only. Each is ignored on every other
option rather than quietly widening one: a glob on an `allow_once` would be a
grant nobody named, and a note on one would be a sentence nobody reads, which is
worse than dropping it.

Both are ADDED, DEFAULTED fields on an existing frame, so an older daemon ignores
them and answers as it did before (protocol.rs on `pattern` and `note`)."
  (append (list :frame "answer"
                :client-request-id (next-request-id)
                :req-id req-id
                :option-id option-id)
          (when pattern (list :pattern pattern))
          (when note (list :note note))))

(defun question-answer (&key option note free)
  "A `QuestionAnswer` payload (question.rs:55-65): a choice, a note, a typed
reply, or a choice and a note together.

Only `{\"option\":N}` was ever built, and `free` is the half the operator's own
requirement names — *\"opencode style free user reply input\"* (question.rs:10-20)
— so a typed answer to a question was unreachable. An empty payload is NIL rather
than `{}`: there is no variant for \"not now\", because deferring is not sending."
  (append (when option (list :option option))
          (when (and note (plusp (length note))) (list :note note))
          (when (and free (plusp (length free))) (list :free free))))

(defun make-answer-question (req-id answer)
  "ANSWER is the QuestionAnswer payload: a choice, a note, a typed reply, or a
choice and a note together — build it with `question-answer`, which is the only
place that knows the three field names.

**AN EMPTY ANSWER IS NOT A FRAME, and the constructor refuses to build one.**
`QuestionAnswer` is a plain struct and NOT an `Option` on the wire
(protocol.rs:644-648, question.rs:55-65), so `\"answer\": null` fails the WHOLE
`ClientFrame` deserialiser — not one frame, the daemon's read loop, and the socket
goes with it. Measured by encoding it: `make-answer-question` with a nil answer
wrote `{\"frame\":\"answer_question\",…,\"answer\":null}`.

This is the same hazard this head has already fixed twice by hand: `Mode.consented`
(`%send-mode`, panes.lisp) and `ReseatSession.summarise` (commands.lisp) both had to
become `:false` rather than NIL, because `#[serde(default)]` accepts a MISSING key
and not a present `null`. **A hazard fixed three times by hand is a pattern, not an
accident**, so this instance is refused where the frame is BUILT rather than left to
the caller to remember — and see `%encode-object` (json.lisp) for the half that IS
general: a NIL-valued key is elided now, which closes the `#[serde(default)]` and
`Option<T>` cases for good. It cannot close this one, because both a missing key and
a null are fatal to a required field, and that is why the refusal has to be here.

There is nothing to fall back to, either: the daemon has `AnswerDefect::Empty` for
exactly this payload (question.rs:73-75), so `{}` is a legal *empty* answer and null
is not a legal anything. The head never wants either — `question-answer` returns NIL
for \"nothing to say\", and *deferring is not sending*."
  (when (null answer)
    (error "make-answer-question: no answer to send. QuestionAnswer is a REQUIRED ~
            struct on the wire, so an empty one is a frame the daemon cannot read — ~
            and it fails the whole ClientFrame deserialiser, which ends its read loop ~
            and the connection with it. Deferring is not sending: do not send the ~
            frame."))
  (list :frame "answer_question"
        :client-request-id (next-request-id)
        :req-id req-id
        :answer answer))

(defun make-list-sessions ()
  (list :frame "list_sessions"))

(defun make-list-todos ()
  (list :frame "list_todos"))

(defun make-list-jobs ()
  "This session's background jobs, answered IMMEDIATELY.

Deliberately not a `slash` line: those ride the command queue and are answered
between turns, so `/job` during a long turn arrived after it had finished — which
is useless for a pane that opens. Added at protocol 21, which is why the daemon
refused us with `bye` until this head learned to say 21 too."
  (list :frame "list_jobs"))

(defun make-read-job-output (job offset)
  "One window of background job JOB's output, starting at OFFSET.

**Why this is a frame and not `/job ID`.** The operator, 2026-09-20: *\"on the job
pane when i press enter im not shown the tailed job output but brought back to
the conversation with /job <id> sent\"*. `/job` is a slash line, and a slash
reply is a `Warning` on the session log — so the pane closed and a 16 KB build
log scrolled past in the chat. This asks the same read as a COMMAND, and the
daemon publishes the answer as `SessionEvent::JobOutput` with the OFFSETS beside
the text, which is what lets a pane draw its own header and its own paging
instead of parsing `/job`'s footer sentence (protocol.rs on
`ClientFrame::ReadJobOutput`, event.rs on `SessionEvent::JobOutput`).

It is not answered on this connection the way `Peek`, `Settings` and `Jobs` are:
those read what the SERVER can reach, and job output lives in the exec host,
which is the worker's — answering it here would make the server block its own
read loop on a worker and stall this connection's live events for the duration
(letibot `bacf495`, the design note).

**No `+protocol-version+` bump**, deliberately: `SessionEvent` is internally
tagged and `JobOutput` is an additive variant, the way `TranscriptContent` and
`JobSettled` were added. The cost of that is on the OTHER side and is handled in
`src/head.lisp`: a daemon older than this frame fails the whole frame in serde
and drops the connection, which is the same shape `consented: null` had."
  (list :frame "read_job_output"
        :client-request-id (next-request-id)
        :job job
        :offset offset))

(defun make-new-session (title workspace)
  "A fresh session under TITLE, seated at WORKSPACE.

**An empty workspace is not a default, it is a wrong tree.** `protocol.rs:599-607`
records what it cost: the daemon seats the new session's read-only tools at its
OWN working directory, *\"and every path in it resolved, so the only symptom was
answers about the wrong tree\"*. Every `/new` and every `--new TITLE` this head
sent carried `\"\"`. The reference sends its own cwd (`driver.rs:147-150`), and so
does this — from here, so no caller can forget: a caller that has a directory to
name passes it and wins."
  (list :frame "new_session"
        :client-request-id (next-request-id)
        :title (or title "")
        :workspace (if (and workspace (plusp (length workspace)))
                       workspace
                       (%cwd-string))))

(defun %cwd-string ()
  "This head's working directory, the way a path is written rather than the way
a pathname prints: no trailing slash, because that is what the daemon stores and
what a session brief shows back."
  (let ((s (uiop:native-namestring (uiop:getcwd))))
    (if (and (> (length s) 1) (char= (char s (1- (length s))) #\/))
        (subseq s 0 (1- (length s)))
        s)))

(defun make-resume-session (session-id)
  (list :frame "resume_session"
        :client-request-id (next-request-id)
        :session-id session-id))

(defun make-rename-session (session-id title)
  (list :frame "rename_session"
        :client-request-id (next-request-id)
        :session-id session-id
        :title (or title "")))

(defun make-switch (session-id since-seq)
  "Move this connection to another session, same socket, answered with a
second Hello."
  (list :frame "switch" :session-id session-id :since-seq since-seq))

(defun make-fetch-row (session-id row &key (at 0) (len +row-fetch-len+))
  "A window of ONE row's body, by its ORDINAL in the session.

**The ordinal and not an index**, which the protocol is emphatic about
(`protocol.rs:783-797`): `0` is the session's first row ever, and it is the only
number a head can express — a head knows the rows it holds and how many came before
them (`items_dropped`), so *the row above my oldest* is `items_dropped - 1`, while an
index into the daemon's window would name a different row after every trim.

Answered with `RowFetched` on the same stream as the session's own traffic, and it
does not move the connection — the same contract `Peek` keeps (`server.rs`: *\"a read,
not a move\"*). `at` is clamped to the body rather than refused (a head paging forward
does not know where the end is), and `len` is capped by the daemon at
`MAX_FETCH_ROW` — 64 KiB, an order of magnitude above any window a head draws.

**`body: null` is not an empty row.** It is the daemon saying it does not hold that
ordinal — trimmed by `ViewBounds`, or past the end — and *\"nobody has it\"* and *\"it
is empty\"* must not look alike (`view.rs:732-740`, `server.rs:683-690`)."
  (list :frame "fetch_row"
        :session-id session-id
        :row row
        :at at
        :len len))

(defun make-peek (session-id)
  (list :frame "peek" :session-id session-id))

(defun make-settings ()
  (list :frame "settings"))

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

(defparameter +head-run-arguments-key+ "head-run.arguments"
  "The settings row that says, per tool, WHICH FIELD A BARE LINE GOES INTO.

**The shape of a tool's arguments is the daemon's, and this is how the head gets it without
holding a copy.** `head-run.tools` publishes the NAMES the door opens on; this publishes how a
person's sentence becomes the arguments — for each name, the field a bare line fills and any
fields the daemon defaults. The head then turns `/NAME what you want` into the wire's JSON by
LOOKING UP the name in what the daemon sent, so it still knows nothing about the tool.

**Why a row and not a head-side table**, which is the whole requirement: a head that knew
one tool takes `{\"url\": …}` would be holding a copy of that tool's schema — the same drift
this pair of rows exists to stop — and the alternative that shipped first moved that cost onto
the operator, who had to type braces. The knowledge stays here and the typing gets short.

**The value is JSON text**: an array of `{\"name\", \"field\", \"defaults\"}`, or an object keyed
by name with the same fields. Both are accepted (see `%argument-descriptors`) because the row
is the daemon's to spell and a head that insisted on one spelling of a shape it ASKED for
would be moving the cost back. A daemon that predates this row sends none: the bare form says
so and JSON still works.")

(defun %argument-descriptors (value)
  "VALUE (a settings row's JSON text) as `(NAME :FIELD F :DEFAULTS plist)`, or NIL.

NIL for anything this head cannot read, and that is a FACT rather than an error: a row
absent, empty, or in a shape from a newer daemon all leave the bare form unavailable and JSON
working, which is the honest fallback (`head-run-tools` keeps the same rule for a missing
list).

**TWO SPELLINGS ARE ACCEPTED**, an array of objects or an object keyed by name, because the
row is the daemon's to spell and a head that insisted on one spelling of a shape it ASKED for
would be moving the cost back to the other side. The conversion is guarded: a row that decodes
to something neither shape is NIL rather than a half-read alist, since a descriptor missing
its `field` would silently drop a person's sentence."
  (when (and (stringp value) (plusp (length value)))
    (handler-case
        (let* ((parsed (json-decode value))
               (rows (cond
                       ;; an object keyed by name: `{"tool-a": {"field": "q"}}`
                       ((and (consp parsed) (keywordp (car parsed)))
                        (loop for (k v) on parsed by #'cddr
                              when (and (consp v) (stringp (getf v :field)))
                                collect (list :name (%key-to-wire k)
                                              :field (getf v :field)
                                              :defaults (getf v :defaults))))
                       ;; an array of descriptors
                       ((listp parsed)
                        (loop for v in parsed
                              when (and (consp v) (stringp (getf v :name))
                                        (stringp (getf v :field)))
                                collect (list :name (getf v :name)
                                              :field (getf v :field)
                                              :defaults (getf v :defaults))))
                       (t nil))))
          (when rows
            (loop for r in rows
                  collect (cons (getf r :name)
                                (list :field (getf r :field)
                                      :defaults (getf r :defaults))))))
      (error () nil))))

(defun head-run-arguments (settings)
  "The daemon's per-tool argument descriptors, or NIL when it has published none.

An alist `(NAME . (:FIELD \"query\" :DEFAULTS (:LIMIT 10)))`, read from the row and never
merged with anything this file knows. **A tool missing from it is a tool whose bare form the
head cannot offer**, and the caller says so rather than guessing a field name — which is the
one thing this whole row exists to prevent."
  (let ((row (and settings
                  (find +head-run-arguments-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (and row (%argument-descriptors (getf row :value)))))

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

(defparameter +outcomes-taking-a-reason+ '("failed")
  "The variants whose payload is a FIELD and not just the text handed back.")

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

REASON is that field, and it is passed only for the variants that take one — an `ok`
carrying a `reason` happens to be accepted today (serde ignores it) and would be the same
kind of guess one variant later."
  (list :frame "operator_result"
        :call-id call-id
        :outcome (if (and reason (member outcome +outcomes-taking-a-reason+
                                         :test #'string=))
                     (list :outcome outcome :reason reason)
                     (list :outcome outcome))
        :payload (or payload "")))

;;; ------------------------------------------ R11: the oracle's own exchange (25) ;;;
;;;
;;; **A LOCATOR, not a payload.** R11 put both halves of the oracle's exchange on the
;;; corpus row (`shown`, `oracle_reply`) and neither reached a head, because a card that
;;; carried a whole brief and a whole reply would carry them for every card on the
;;; screen. This is the same shape as `FetchRow`, which is this document's own precedent
;;; for *the head asks the daemon for something big it does not normally hold*.
;;;
;;; **`body: None` and `body: Some("")` are two facts.** The store holds NULL on every row
;;; written before R11 kept the exchange, and an oracle that never answered has no reply
;;; either — *"nobody kept this"* and *"here it is, and it is empty"* are both real, and
;;; `total` is on the frame rather than inferred because `body.map(len).unwrap_or(0)`
;;; cannot tell them apart either.
;;;
;;; **A `request_id` nobody has is `body: None`, NOT an error and NOT a `Rejected`**: the
;;; row may have been compacted, the id may be from another session, and *not recorded* is
;;; the honest answer to all of it. A head draws the same sentence and does not retry.
;;;
;;; **No `expected_seq`**: this is a read, it moves nothing, and a head that asked while
;;; the screen moved still meant it. The wire says `brief`/`reply`; the store has always
;;; said `shown`/`oracle_reply`, and that mapping is the daemon's own (`DiagnosticSource`)
;;; — neither vocabulary is flattened into the other.

(defparameter +diagnostic-kinds+ '("brief" "reply")
  "The two halves, in the order a card reads them. The daemon's own spellings.

A `defparameter` rather than a constant because the file pusher skips constants, and it
is the ONE place this head knows that there are two: `%diagnostic-ask` walks it, so a
third kind would be asked for by adding a name here and nowhere else.")

(defun make-fetch-diagnostic (request-id kind)
  "The read: the oracle's brief or its reply, for the adjudication REQUEST-ID.

Two fields, and both absences are deliberate: no `expected_seq` (a read moves nothing) and
no `client_request_id` (there is no per-ask reply — the answer is a `diagnostic` frame
keyed by the ADJUDICATION's id, which is also what `/gate` takes)."
  (list :frame "fetch_diagnostic"
        :request-id request-id
        :kind kind))

(defun make-detach ()
  "A clean goodbye. Not required: close is detach too, and detach is never
abort (protocol.rs on ClientFrame::Detach)."
  (list :frame "detach"))

;;; The one frame only a head can answer: its own screen, as it drew it
;;; (protocol.rs on ClientFrame::Screen). ROWS is one string per row, escapes
;;; included, at the head's real size.
(defun make-screen-answer (req-id cols rows-n rows)
  "This head's screen as it drew it: COLS columns by ROWS rows, one row per string.

**COLS IS A COLUMN COUNT, NOT A STRING LENGTH.** This sent
`(length (first rows))` — the character length of row zero, **ANSI escape bytes
included** — so a 100-column frame reported 100 plus every SGR byte in its top row,
and the daemon believed it. That is the worst available kind of wrong: not an error,
a number that parses.

The reference sends its terminal size (`driver.rs:287` — `self.client.screen(&req_id,
size.0, size.1, …)`), and its own doc on this frame asks for *\"last rendered, ANSI
and all, at its real terminal size\"* (protocol.rs on `ClientFrame::Screen`). The two
numbers are REQUIRED arguments rather than derived here, because the derivation is
exactly what was wrong: a row's length is a length of characters or bytes, and the
head's own width is a count of CELLS by the one rule this tree has (`string-width`,
width.lisp, whose tables are the reference's code point for code point).

`%answer-screen-requests` passes `head-last-cols`/`head-last-rows-n` — the size the
paint that produced ROWS actually used."
  (declare (type fixnum cols rows-n))
  (list :frame "screen"
        :req-id req-id
        :cols cols
        :rows-n rows-n
        :rows rows))
