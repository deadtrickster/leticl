;;;; protocol.lisp — the head frame vocabulary, protocol version 37.
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

(defparameter +protocol-version+ 37
  "The version this head announces at ATTACH, and the number is a CLAIM rather than a flag.

The protocol's only compatibility check is EQUALITY at ATTACH, so a head that announces a
version is saying *I know what those frames are* — and a head that announces a number it does
not understand has traded a clear refusal for a mid-session surprise. So what 24, 25 and 27
added is written down here rather than assumed:

  · **37** is THE TODO AUTHOR'S THIRD VARIANT (letibot `38f10b0`): `TodoStatus`'s author,
    spelled `by` on every `Todos` row and on `TodosUpdated`, gains `Parent <session-id>` —
    a parent writes its child's board, and the child reads which of its rows it decided and
    which it was told. The reference MOVED THE NUMBER for it and gives the reason in its own
    words: `serde` has no catch-all on that enum and the author travels inside the frame, so
    a 36 head meeting one fails to DECODE it and takes every row in the frame down with it —
    mid-session, with no warning. Both sides say the mismatch by name at attach instead.

      TodoBy is one bare string, and the three it may spell are `model`, `operator`, and
      `Parent <session-id>` — not an object, so `sqlite3` reads the author as a word.

    **This head never had the decode failure** — its `by` is whatever yason read, a string —
    but the number is a CLAIM and not a flag (see the top of this docstring), so it steps with
    the wire. What it must DO with the third word is in `repo-todo.lisp`: a parent's row is
    not the operator's, and it is labelled in its own words rather than as the model's — the
    false author this pane was measured telling once already.

  · **27** is THE COMPACTION'S OWN PROGRESS, and it is a NEW VARIANT rather than a defaulted
    field — so a 26 head meeting one mid-session fails to decode the frame, which is why the
    attach-time refusal is the thing that tells it (letibot `f273300`):

      SessionEvent::CompactionProgress { half, halves, prompt_tokens, processed, written, unit }

    `half` is 1-based IN THE ORDER THEY RUN — the recent tail first on the local plan, because
    its cold prompt is the cheap one to warm the server's cache with — and `halves` is 1 for
    the cloud fold and 2 for the local two-half plan.

    **`processed` IS THE FIELD MOST LIKELY TO BE RENDERED WRONG, and letibot names the trap:**
    on a messages transport — which is what the operator's deepseek sessions use — the server
    reports no prefill, so `0` means *this transport does not count that*, NOT *nothing has
    happened*. A bar filling from `processed` sits at zero for the whole fold and looks exactly
    like the hang this event exists to remove. **This head drives its bar from `written` and
    says which number it is drawing.**

    **`unit` IS A STRING AND MUST NOT BE ASSUMED**: `tokens` where the transport reports the
    server's own count, `chars` where it reports only text. *The two transports do not count the
    same thing and one name for both would be a lie about one*, so the unit is printed beside
    the figure rather than implied.

    **And it must not be folded into `PromptProgress`.** The overrun compaction summarises a
    SCRATCH transcript, and forwarding its raw `PromptProgress` put the scratch prompt's count
    into `turn.progress` — the SESSION's turn — so the operator watched `69k` sit over a 240k
    conversation that had not changed. *The number was never wrong; its label was.*
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

(defvar *skew-override-seat* nil
  "The seat on which the operator lifted the read-only seating, or NIL.

A SEAT and not a boolean, because the override belongs to the daemon it was given on —
a `Switch` keeps it (same process, same socket) and a REPLACED daemon re-locks (a
different seat), which is the reference's own rule (`skew_override_for`).")

(defun skew-locked-p ()
  "Is this attach READ-ONLY because the daemon is from an older build?

**THE OPERATOR'S RULING, REVERSING A STATED POLICY** (letibot `f6e66f0`, and the
measurement behind it is theirs): a 17-day-old daemon speaking protocol 22 against a
head's 36 — its warm KV costing minutes to rebuild — was killed by a bare `Bye` at the
door. *'this is really sad, especially considering tui is newer'*, and then the rule:
*'so ideally it would be like - connect, look around and make informed decision'*. The
old gate did the opposite on the one half that could act; this puts the decision where
the ruling puts it, with the person at the keyboard.

**THE ASYMMETRY IS LOAD-BEARING and `protocol-skew-said` already argues it**: a NEWER
daemon is a reading problem this head survives (unknown frames are said, counted,
skipped) — nothing is disabled. An OLDER daemon is a WRITING problem: the first
`ClientFrame` it has never heard of fails its deserialiser and it answers with a `Bye`
and a closed socket. So an older daemon seats the head read-only — the conversation
readable and scrollable, nothing leaving — until `ctrl-^` lifts it.

Nothing here is a new wire shape: the `Hello` already carried the daemon's number, and
the only change is whether a number is a refusal. The reference deliberately did NOT
bump for it, and neither does this head."
  (let ((proto (and (consp *daemon-seat*) (integerp (cdr *daemon-seat*)) (cdr *daemon-seat*))))
    (and proto
         (< proto +protocol-version+)
         (not (equal *skew-override-seat* *daemon-seat*)))))

(defun skew-refusal-said ()
  "The sentence a refused act gets while the attach is read-only: the full informed
skew sentence, and what to do about it. NIL when nothing is locked."
  (when (skew-locked-p)
    (format nil "~a Nothing was sent — this attach is read-only by default, and ctrl-^ attaches anyway."
            (or (protocol-skew-said (cdr *daemon-seat*) +protocol-version+)
                "this attach is read-only."))))

(defun pid-word (pid)
  "`pid 1234`, or *a pid the kernel did not name* for NIL — never a pid of zero.

Two writers say this (the reference's own `pid_word`, session.rs): the
replaced-daemon note and, in its head, the stop's farewell. A pid this head
printed without having would send the operator to `ps` for a process that is
not there."
  (if pid (format nil "pid ~d" pid) "a pid the kernel did not name"))

(defun protocol-word (p)
  "`36`, or *a protocol it did not say* for NIL — the same rule as `pid-word`, for
the other half of the seat: a number a head did not have must not be printed as
one."
  (if (integerp p) (format nil "~d" p) "a protocol it did not say"))

(defun daemon-replaced-said (was now)
  "The sentence about a REPLACED daemon, or NIL when the seat did not move.

The reference's own sentence (events/hello.rs), kept word for word where this
head's facts are the same: both numbers on both sides, because a bare pair of
pids makes the reader work out which side they are on, and `None` said as *not
told* rather than as zero.

**The claim list is THIS head's, and says what this head actually re-asks**: a
`Hello` here reloads and re-pushes the operator's plan, re-sends the settings
request, and the Hello itself carries the session list — while the snapshot's
`subagents` field carries the children. The reference's sentence also names its
job table; this head's job rows are events the daemon replays, which is not a
refetch, so the sentence does not claim one."
  (when (and was now (not (equal was now)))
    (format nil
            "this is not the daemon this head was attached to. That one was ~a and ~
             spoke protocol ~a; this one is ~a and speaks ~a. Everything the old ~
             one told me that was its own — its session list, its children, your ~
             plan, the settings — has been asked for again, because a daemon's ~
             registry is in memory and a replacement holds none of it. What you ~
             are reading below is what THIS daemon holds."
            (pid-word (car was)) (protocol-word (cdr was))
            (pid-word (car now)) (protocol-word (cdr now)))))

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

