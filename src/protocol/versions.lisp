;;;; protocol.lisp — the head frame vocabulary, protocol version 28.
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

(defparameter +protocol-version+ 28
  "The version this head announces at ATTACH, and the number is a CLAIM rather than a flag.

The protocol's only compatibility check is EQUALITY at ATTACH, so a head that announces a
version is saying *I know what those frames are* — and a head that announces a number it does
not understand has traded a clear refusal for a mid-session surprise. So what 24, 25 and 27
added is written down here rather than assumed:

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

