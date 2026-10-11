;;;; the-wire — the frame constructors: what this head sends
;;;;
;;;; Split out of `protocol.lisp`, which was one 783-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------------- constructors ;;;
;;; Field order follows protocol.rs so a diff against the Rust reads naturally.
;;; Keys whose value is nil are omitted by the caller's choice here — serde
;;; defaults them daemon-side — except where presence itself is the disclosure.

(defun make-attach (&key (session-id "") (since-seq 0) (kind "tui") identity
                      ;; **BIG ENOUGH FOR A RESUME, WHICH IS THE ONE THING THAT NEEDS IT.**
                      ;;
                      ;; The default is 1024, and a restore publishes **three events per stored
                      ;; row** — a `filling` tick, a `transcript_appended`, and the item body —
                      ;; so a 2706-row conversation is ~8100 events through a 1024-event queue.
                      ;; The daemon does not block and does not drop silently: it DEMOTES the
                      ;; head (`hub.rs:1366`), clears the queue, and hands it a snapshot — which
                      ;; is what the operator saw, three times, as the restore bar freezing at
                      ;; 44 rows and the conversation arriving in pieces.
                      ;;
                      ;; MEASURED on the running head: `:resyncs 3` after one resume.
                      ;;
                      ;; The protocol's own field docstring says what to do about it — *"a head
                      ;; that renders slowly can ask for a bigger queue instead of resyncing
                      ;; constantly"* — and there is no clamp daemon-side beyond `.max(1)`. So
                      ;; this asks for what a restore costs, with room to spare: 16384 events is
                      ;; ~2000 rows of the three-event shape, and costs the daemon a VecDeque of
                      ;; pointers when it is full.
                      (queue 16384) (can-decide t) features)
  (list :frame "attach"
        :protocol-version +protocol-version+
        :session-id session-id
        :since-seq since-seq
        :kind kind
        :identity (or identity "")
        ;; **`queue` AND `can_decide` ARE ALWAYS WRITTEN, WHATEVER THEY HOLD.** They are BARE
        ;; required fields daemon-side (`protocol.rs`: `queue: usize, can_decide: bool`, and
        ;; only `features` carries `#[serde(default)]`), and `%encode-object` OMITS every nil
        ;; value — so `(make-attach :can-decide nil)` emits a `caps` with no `can_decide`, which
        ;; fails the daemon's whole `ClientFrame` deserialiser: its read loop answers `Bye` and
        ;; closes the socket. That is the same shape as the `consented: null` this tree has paid
        ;; for twice, one field over, and it is cheap to make impossible rather than to remember
        ;; (found by the wire reviewer, 2026-10-11; both callers pass the defaults, so this was a
        ;; trap and not a live defect). `features` is left optional because the daemon DOES
        ;; default it.
        :caps (append (list :queue (or queue 0)
                            :can-decide (and can-decide t))
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

(defun make-set-operator-todos (expected-seq items)
  "The operator's todos, to the daemon that keeps the board — **ONE list, two authors.**

The operator's ruling: *\"the existing getter should return mine and yours, and the rest is also the
same. the only difference is who created and that is it.\"* So the daemon's board holds one list, the
head is the source of truth for its own half, and this carries that half whole on every change.

**The whole list and not a delta**, because a delta protocol for a list of tens of items is a second
source of truth about rows this head owns outright. `by` is `\"operator\"` on every row: the daemon
needs it to draw `— you` rather than `— model`, and to know which half to replace.

Why any of this is here at all: the idle nag asks the daemon's board for unfinished work, so until
the operator's rows reach it, a reminder can only ever be about something the MODEL wrote."
  (list :frame "set_operator_todos"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        ;; **A VECTOR, SO AN EMPTY LIST IS STILL SENT.** `items` is a REQUIRED field on the daemon
        ;; side, and an empty Lisp list is NIL — which the encoder elides, producing a frame with no
        ;; `items` at all and a dropped connection. MEASURED: clearing the operator's todos killed the
        ;; head, and every later head died on its HELLO the same way, because an empty list pushes an
        ;; empty list. An empty VECTOR is not NIL, so `[]` goes out and the daemon accepts it.
        ;; **THE ITEM'S OWN STATUS, and a hardcoded `"pending"` here was a bug that no test caught.**
        ;;
        ;; Two mappings stacked: `push-operator-todos` derives the wire status from the head's item,
        ;; and this function then THREW THAT AWAY and wrote a constant. So every operator row reached
        ;; the board as pending and could never be completed there — MEASURED, after marking one done
        ;; in the head's store and watching the daemon's board flip back to `pending` on the next
        ;; hello, and then reproduced in the frame itself:
        ;;
        ;;     {"frame":"set_operator_todos", … "items":[{"content":"push leticl to github",
        ;;       "status":"pending","by":"operator"}]}          <- the item said "completed"
        ;;
        ;; The consequence is the nag: `unfinished_plan` reads the board, so an operator item
        ;; announced as done still counted as open, for ever, and the reminder asked again every idle
        ;; period. **ONE mapping**, here, from the head's own item shape to the wire's — which is what
        ;; `make-set-operator-todos`'s name already promised.
        ;; **AND `postponed` IS THE THIRD WORD THIS MAP KNOWS.** The state is the OPERATOR's act
        ;; (`/todo postpone N`, see the pane) and it lives on the daemon's board exactly as long as
        ;; this head keeps saying it: a mapping that collapsed a set-aside row back to `pending`
        ;; would undo the act on the next push — any add, any delete — while the head's own list
        ;; still drew `[p]`, which is the same two-mappings defect the `completed` constant was,
        ;; one spelling further along. Every other status is the wire's `pending`, as before.
        :items (coerce (mapcar (lambda (item)
                                 (list :content (or (getf item :content) "")
                                       :status (cond ((equal (getf item :status) "completed")
                                                      "completed")
                                                     ((equal (getf item :status) "postponed")
                                                      "postponed")
                                                     (t "pending"))
                                       :by "operator"
                                       ;; **AND THE CONDITION, WHEN THERE IS ONE.** `when` is
                                       ;; `#[serde(default)]` on the wire, so it is OMITTED
                                       ;; when the row has none (`%encode` drops a nil value),
                                       ;; which is the shape every daemon older than the field
                                       ;; read as *unconditional*. The plist is the wire's own
                                       ;; decoded shape (`(:kind "job" :handle ...)`) and goes
                                       ;; out as the object it is — one variant exists, and a
                                       ;; second arrives here as a second plist without this
                                       ;; map learning anything.
                                       :when (getf item :when)))
                               items)
                       'vector)))

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

(defun make-list-notes ()
  "The STANDING notes — what the harness is reading into this session's prompt right now.

**Asked when the pane opens, not by a verb that rides the queue** (measured in the reference,
2026-10-11): `app/standing.rs:133` is `self.standing_pane.then_some(Action::ListNotes)`, and the
protocol's own docstring gives the reason — *a list is a question, not an act; a pane that opens
must answer while it is open, and a verb that rides the command queue answers after the turn.*
Read-only and unserialised like `ListJobs`, and the answer is the harness's mailbox rather than a
fresh read of the directory."
  (list :frame "list_notes"))

(defun make-list-merge-queue ()
  "The merge queue as of NOW — daemon-level, and the first thing a head asks for.

**THE SNAPSHOT CARRIES NONE OF IT BY DESIGN, so a head that never asks draws nothing** — the same
bootstrap rule `/todos` keeps. The reply is the whole queue and every change after it arrives as
`MergeEntryAdded`/`MergeEntryMoved`.
(`TODO.md`'s merge-queue box, step one of five: the frames and the ASK together — the suite's
`every-frame-constructor-is-actually-sent` refuses a wire half with no caller, which is the
invariant doing its job.)"
  (list :frame "list_merge_queue"))

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
  "Read another session's scrollback WITHOUT moving this head there.

**AND ASK FOR ROWS, which is a request field and not a favour.** `PeekShape` is opt-in with `Events` as
the default, and the two shapes are ALTERNATIVES: a head that asks for rows gets a snapshot and an EMPTY
ring, because sending both would put the same content on the wire twice. So `snapshot: NIL` beside a
full ring is the daemon answering an `Events` request exactly as designed — which is what this head did
while a commit of ours claimed rows were not reachable. The claim was wrong; the missing field was ours.

Rows are what make a peeked child draw like any other session: a `Snapshot` is the same thing an attach
answers with, so `%peek-snapshot-pane` draws it with `%viewport-lines` and no head-side renderer is
involved. `Events` stays reachable for a caller that wants the ring; nothing sends it today."
  (list :frame "peek" :session-id session-id :shape "Rows"))

(defun operator-line-refusal (text)
  "Why a pasted block must not be submitted as an `!` line, or NIL when it may.

THE RULE IN THE SHARED CRATE (the reference's `sessionlog::operator_line_refusal`,
`d0ba286`), so the composer that submits and the daemon that run cannot disagree about
what may run — which is why this lives here and not beside the composer's `!` arm.

MEASURED on the reference's own head, 2026-10-08: a copied `operator_run_unreadable`
notice — five lines, the first reading `! sudo apt install mc` — was submitted, and the
newlines the shell then split re-ran an earlier `sudo` with the notice's remaining words
as its arguments. The parse was RIGHT: it *is* a `!` line. This is not a fix to the parse
but a check in front of it.

A multi-line text that does NOT start with `!` is untouched — a pasted stack trace is a
prompt, and it is the ordinary reason somebody pastes. A `!` that is not the first
character of the line is not a `!` line at all. ONE line is a command and passes.

**AND A TRAILING NEWLINE IS NOT A LINE** — the reference counts with Rust's `text.lines()`,
which drops one final newline and never yields a trailing empty line, so a single command
with the newline a copy took with it is ONE line there and not a block. This counted the
newlines raw and added one, so `! ls` plus its newline was refused as a two-line block and a
genuine five-line paste was called six — **the two halves disagreeing about the commonest
paste there is, inside the one function whose whole purpose is that they cannot** (found by
the wire reviewer, 2026-10-11). The trailing newline is dropped first, which is what
`lines()` does."
  (let* ((text (if (and (plusp (length text))
                        (char= (char text (1- (length text))) #\newline))
                   (subseq text 0 (1- (length text)))
                   text))
         (end (position #\newline text))
         (first (subseq text 0 (or end (length text)))))
    (when (and end
               (plusp (length (string-left-trim '(#\space #\tab) first)))
               (char= (char (string-left-trim '(#\space #\tab) first) 0) #\!))
      (let ((rest (count #\newline text)))
        (format nil "that is ~d line~:p and its first one starts with `!`, so running it would run every line of the pasted block as its own shell command. Nothing was run. A `!` line is ONE line: send the command on its own."
                (1+ rest))))))

(defun make-operator-shell (line)
  "The operator's own shell command — a new client frame at protocol 28.

 LINE is the submitted line VERBATIM, `!` first (`! ls .`). The daemon strips the
 `!` at the execution site and runs the rest through the same path `bash` takes —
 the same confinement, the same scratch directory, the same `SUDO_ASKPASS`
 environment. No gate is consulted: the operator typed the line. The result lands
 as a `ToolResult` named `bash` with `origin: Operator`, which is what every head
 already draws with the tool-output treatment.

 A separate frame rather than the operator-call door, because the door RECORDS a
 tool call with a tool's own name and JSON arguments — and a raw shell line has
 neither. Widening the door's list to `bash` would make the list's recorded
 reason false and grow a permission-shaped admission row the feature is
 explicitly required not to have."
  (list :frame "operator_shell"
        :client-request-id (next-request-id)
        :expected-seq (session-expected-seq *session*)
        :line line))

(defun make-suggest-shell (prefix)
  "The model's proposed `!` completions — a new client frame at protocol 30.

 The daemon builds the prompt from the conversation and asks the LOCAL model
 (the `[gatekeeper]` endpoint, never a metered provider — a suggestion must not
 cost money per keystroke). The answer is a `shell_suggestions` server frame
 with a list of candidate lines; **nothing in the path submits** — a suggestion
 only fills the composer, and Enter is still the operator's.

 Empty when the model said nothing usable; the daemon always answers rather
 than staying silent, so the head can tell *no suggestion* from *no answer*."
  (list :frame "suggest_shell"
        :client-request-id (next-request-id)
        :expected-seq (session-expected-seq *session*)
        :prefix prefix))

(defun make-prompt-answer (req-id line)
  "The operator's answer to a command that asked them something.

 A LINE, not a keystroke: the run's stdin is a pipe, so there are no arrow keys —
 what a person types is a line and a newline makes it one. An empty LINE is a
 bare Enter and is a real answer (`Continue? [Y/n]` takes Enter as its default).

 NOT a secret and never one: the field is drawn in the open, and a password has
 its own path (`SUDO_ASKPASS`, the secret card) whose rules this must not borrow.
 Not a command: it is never queued, never announced and never logged with its
 payload — the session worker is BLOCKED inside the very command that is asking,
 so an answer queued behind that turn would be drained by the thread waiting for
 it, which is never."
  (list :frame "prompt_answer"
        :req-id req-id
        :line line))

(defun make-send-line (line)
  "One line to the running command, on demand — the manual way in.

 The card is raised by a heuristic, and a heuristic has misses (a program blocked
 on something other than its stdin, a program that asks and keeps drawing, a
 /proc this daemon may not read). This is the floor under it: a person watching
 the stream can answer whether or not anything looked like a question.

 No req-id and no job-id: it addresses whatever operator command this session is
 running right now, which the daemon knows and the head does not, so there is
 nothing for a head to get wrong. A session with nothing running gets a sentence
 saying so rather than silence."
  (list :frame "send_line"
        :line line))

(defun make-settings ()
  (list :frame "settings"))

