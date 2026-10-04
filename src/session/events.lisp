;;;; events — folding a frame into the state, and the frames this head cannot read
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------ event application ;;;

(defvar *model-from-settings-at* 0
  "The session seq when the `model` settings row was last received.")
(defvar *model-from-turn-at* 0
  "The session seq when a TurnStarted last named the model answering.")

(defvar *verbosity* :normal
  "How much of the event stream is drawn, as a LADDER of four rungs — chosen from
`/verbosity`'s card (R38). The reference's `Verbosity` is three of them, and its own docstrings are
the vocabulary: Terse (*assistant text and tool outcomes only*), Normal (*plus
reasoning*), Loud (*plus head arrivals and who issued which command*).

**`:reading` is the fourth rung, BELOW terse** (R37): the conversation alone — user and
assistant text — and **nothing the head did to produce it**. Tool calls, outcomes,
payloads, reasoning, head arrivals and command attribution all go. It is a rung of the
same ladder rather than a new mechanism, which is why `verbosity-at-least` keeps its
meaning: every gate written for the three rungs above answers as it did.

**Three things it may NOT hide, and each is a different reason.**
`+reading-never-hides+` is the list, and this docstring is where the reasons live:

  · **a WARNING.** letibot's own ruling, and the reasoning transfers whole: *a warning
    is a fact the daemon chose to INTERRUPT with, and a level that hides it makes the
    head the thing that decides the operator should not have seen it.* Sharper still
    for this shape: the filter applies to the WHOLE transcript at once, so a rung that
    hid warnings would retroactively erase one already read — not a filter but a
    revision. What a reader has against a warning is `/notes dismiss`: per-note,
    visible, counted.
  · **a DECISION CARD.** A gate card is not a tool row. Hiding it makes the session
    unanswerable and the call times out to `on_timeout` against a quiet screen — a head
    that hides the question has decided it on the operator's behalf by inaction.
  · **the live turn's FOOTER.** This is the rung's own risk: with tool rows hidden, a
    ten-minute tool-heavy turn draws NOTHING AT ALL, and a reader cannot tell working
    from wedged. The footer keeps the running state and its elapsed time (R13).

**It is a VIEW.** Nothing leaves the transcript, the ledger, the corpus or what is sent
to the model; switching back restores every row, retroactively, including the span the
rung was on. That is what makes hiding safe here where an elision would need a
disclosure per row: R29's remedy rule is satisfied by the MODE BEING NAMED on the screen
(`chrome.lisp`'s status row) rather than by a placeholder the operator asked to be rid
of.

A defvar so a push can introduce it and a head slot need not change.")

(defparameter +reading-hides+
  '(:tool-result :reasoning :system)
  "The body types the `:reading` rung HIDES. Everything else is drawn.

**A DENYLIST, and the first cut of this was an allowlist that hid the conversation itself.**
Written as `(user and assistant text and nothing else)` it read as *keep only these*, and the
fixture immediately showed what that means: the operator's own message and the model's answer
drew NOTHING, because `:user` and `:assistant` were not in the list — while the one entry in it
was `:note`. The rule is about what GOES, so the list is the three kinds that are the head's
work:

  · `:tool-result` — a payload and an outcome: what the call returned, not what was said
  · `:reasoning` — the working-out, which is explicitly not the answer
  · `:system` — head arrivals and who issued which command

**A body type this build has never met is DRAWN**, and that is the direction the choice has to
fall: a new kind is at least as likely to be conversation the operator wants as it is to be
work, and being shown something unexpected is the safe failure when the alternative is silently
withholding it. `:note` is not in this list because R37 forbids hiding a warning — and the
allowlist's own one entry is what proved the list was the wrong shape.")

(defun set-verbosity (level)
  "Set the rung, and INVALIDATE WHAT HAS BEEN RENDERED.

**The one writer, and the invalidation is the whole reason it exists.** The rung is read at DRAW
time — `item-lines` asks `reading-p` and hides a row — but `%hist-key` is (generation, width, the
items vector's identity, the live tick) and none of the four moves when a rung does. So the lines already
rendered would be served back out of the cache and the new rung would appear to do nothing, which
is the defect this tree has now found at four surfaces (the fold, the payload page, the width, the
retired note). The generation is what the cache watches, so it is bumped here.

**It says nothing.** The verb and the card own their sentences; a setter that spoke would put two
of them on the screen for one keypress."
  (unless (member level +verbosity-ladder+ :test #'eq)
    (error "~s is not a rung of ~s" level +verbosity-ladder+))
  (setf *verbosity* level)
  (incf *hist-generation*)
  level)

(defun reading-p ()
  "Is a READING rung on? — the conversation, and only so much of the head's work as it keeps.

**Two rungs answer yes** (`:reading` and `:read-edits`): they hide the same three kinds and differ
in exactly one place — `reading-hides-p` keeps an edit card at `:read-edits` — so every other reader
of this predicate (raw calls, the narration, the run markers) is asking the question they mean."
  (or (eq *verbosity* :reading) (eq *verbosity* :read-edits)))

(defun read-edits-p ()
  "Is the `:read-edits` rung on? — reading, plus the cards that say what the head CHANGED."
  (eq *verbosity* :read-edits))

(defun next-verbosity (v)
  "The next rung UP the ladder, wrapping: `reading` → `read-edits` → `terse` → `normal` → `loud` → `reading`.

**NO LONGER A USER-FACING CYCLE, and that is R38's ruling** (`.verbosity` opens a card now):
*a setting with more than two values is chosen from a card that shows all of them; only a true
toggle may cycle.* What survives is the ORDER — the ring is how `+verbosity-ladder+` is stated, and
this function is the ring written down once so the two cannot disagree about which rung is next."
  (ecase v (:reading :read-edits) (:read-edits :terse) (:terse :normal) (:normal :loud) (:loud :reading)))

(defparameter +verbosity-ladder+ '(:reading :read-edits :terse :normal :loud)
  "The rungs, least-drawn first. One list, read by `next-verbosity`, `verbosity-at-least`
and the status row, so the order cannot be written down twice.

**`:read-edits` SITS BETWEEN `:reading` AND `:terse`**, which is where it belongs rather than
beside `:reading`: it draws everything `:reading` draws PLUS the cards that say what the head
CHANGED, and less than `:terse` does. The operator asked for it by name, 2026-10-04.")

(defun verbosity-at-least (level)
  "Is `*verbosity*` at or above LEVEL, in the order reading < terse < normal < loud?

**The order is the whole of this function**, and adding a rung BELOW `:terse` is what
keeps every existing gate meaningful: `(verbosity-at-least :loud)` is still false at
`:terse`, and now also at `:reading`; `(verbosity-at-least :normal)` drops the model's
reasoning at both. Nothing above the rung moved."
  (>= (position *verbosity* +verbosity-ladder+)
      (position level +verbosity-ladder+)))

(defun verbosity-name (&optional (v *verbosity*))
  "The rung's own WORD — what the card, `/status`, `/config` and `head.toml` all spell.

**One place a rung becomes a string**, for the reason `reasoning-line-count` is one place a block
becomes a number: the persisted value, the card's `← now` mark and the status row's register must
agree, and two spellings of one rung is how a setting comes back as a value this build cannot read."
  (string-downcase (symbol-name v)))

(defparameter +verbosity-other-words+
  '( ;; **letibot's name for this rung is `conversation` and this head's is `reading`** — one rung
    ;; under two words, which is R37's NAME row and is still outstanding between the two heads.
    ;; READING both lets a file either head wrote be understood here; WRITING stays this head's
    ;; word, so nothing this head saves puts a spelling letibot would report as unknown into a
    ;; file it reads. When the word is agreed, the rename is deleting one cons.
    ("conversation" . :reading))
  "Spellings this head READS for a rung but does not write.

A synonym and not a second name: the two heads agree on `terse`, `normal` and `loud` and differ
only on the rung R37 added, so this is the whole of the difference.")

(defun verbosity-for-word (word)
  "WORD as a rung, or NIL when it names none — the ladder's own spellings, plus the ones in
`+verbosity-other-words+` that this head reads and does not write."
  (let ((w (string-downcase (or word ""))))
    (or (find w +verbosity-ladder+
              :key (lambda (rung) (string-downcase (symbol-name rung))) :test #'string=)
        (cdr (assoc w +verbosity-other-words+ :test #'string=)))))



(defparameter +per-turn-events+
  '(:delta :prompt-progress :tokens-generated
    :turn-finished :turn-interrupted :turn-failed)
  "The events whose `turn_id` says which turn they are about.

A head folds one turn at a time, and every one of these arrived carrying an id
that nothing compared: measured, a `delta` for turn `OTHER` appended to the
CURRENT turn's text and reported `:dirty`. Both the reference and the view
require the id to match before folding (`app.rs:2278-2297`, `view.rs:406-419`),
and a frame from a turn this head is no longer watching is `Filtered`. Benign on
one turn at a time, load-bearing the moment concurrent subagents publish on one
hub.")

(defun %foreign-turn-p (session env)
  "T when ENV names a turn that is not the one this head is folding.

An EMPTY or absent `turn_id` is never foreign: a turn can fail before it ever
published a `TurnStarted`, and the reference's view says so outright
(`view.rs:595-606`). Only a non-empty id that disagrees with a non-empty id we
hold is."
  (let* ((turn (session-turn session))
         (id (getf env :turn-id))
         (mine (and turn (getf turn :turn-id))))
    (and (stringp id) (plusp (length id))
         (stringp mine) (plusp (length mine))
         (not (string= id mine)))))

;;; ------------------------------------------------------ unreadable frames ;;;
;;;
;;; **A frame this head cannot read is SAID, COUNTED, and SURVIVED.**
;;;
;;; The wire is JSON and both ends are internally tagged — `{"frame": "event", …}`,
;;; `{"event": "delta", …}` — so the first frame two builds do not share is exactly
;;; what a daemon one version ahead looks like from here. leticl has always
;;; SURVIVED one: the reader loop catches the decode error and reads on, and an
;;; unknown tag falls through to the end of the fold. What it never did was SAY so
;;; — and that silence is the failure this section exists to end, because *"this
;;; daemon is sending me something I do not understand"* then looks exactly like a
;;; quiet daemon, which is how an afternoon goes into debugging the wrong half.
;;;
;;; There are three ways to meet one, and all three go through `note-unreadable`:
;;;
;;;   · **a line that is not JSON at all** — the reader loop's `wire-error`;
;;;   · **a frame tag this head does not know** — `%handle-frame`'s last arm, which
;;;     used to answer `:control` and nothing else;
;;;   · **an event tag this head does not know** — `apply-event`'s last arm, which
;;;     used to answer `:quiet` and nothing else.
;;;
;;; The reference has only the first, because serde fails the whole line on an
;;; unknown tag where this reader is structural and hands the plist over. Being
;;; structural and silent is strictly worse: it is why this head could step over a
;;; frame from a newer daemon and never say a word about it.

