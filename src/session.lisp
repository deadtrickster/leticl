;;;; session.lisp — the head's half of a session: snapshot ingestion, event
;;;; application, the read mark. Ported from crates/sessionlog's view.rs,
;;;; event.rs and cursor.rs, keeping their rules:
;;;;
;;;; - Ack.seq is the last seq CONSUMED from the batch, rendered or not
;;;;   (cursor.rs); there is no other way to obtain one.
;;;; - A snapshot is true as of its seq; the next event is seq+1, no gap.
;;;; - TranscriptAppended announces a row with no body; TranscriptContent fills
;;;;   it (event.rs:622 — the placeholder is not a loading state, it is the
;;;;   final state until content arrives).
;;;;
;;;; State is plists all the way down, matching the wire (PLAN.md §7, D4): a
;;;; model hacking a live head inspects exactly what the daemon sent.

(in-package #:leticl)

(defvar *turn-started-ms* nil
  "When the running turn began, on our clock, or NIL for a turn this head did not
watch start — one that came out of a snapshot. NIL is why the composer's edge can
say *started before this head attached* instead of a duration nobody measured.")

(defvar *job-out* nil
  "The job-output overlay: what the jobs pane's Enter asked for and what came
back, or NIL when no overlay is open. A plist —

    (:job ID :state WORD :from N :to N :produced N :dropped N
     :lines (STRING…) :next N-or-NIL :back (N…) :loading BOOL :error STRING-or-NIL)

— which is the reference's `JobOut` struct field for field (app.rs:425-462).

**A defvar, and NOT a slot on `session`, because the window is EPHEMERAL.** The
reference says so in the mechanism rather than in a comment: `scrub::is_interactive`
returns true for `JobOutput`, so `StoredProjection::keep` strips it from the stored
projection and counts it in `ScrubReport::job_output` — *a window from four minutes
ago is a lie about now*. A slot on `session` is exactly the stored projection this
head has; a special that no snapshot writes and no reconnect carries is the same
fact expressed where it cannot be got wrong. (It is also what `*peeked-session*`
and `*peeked-dropped*` already are, for the pane one door over, and a struct layout
change is a restart — which this head must not need.)

`:back` is a STACK of the offsets this head was given, not `from - page`
arithmetic: the page size is the DAEMON's (`JOB_OUTPUT_WINDOW`), and recomputing
it here would be a second copy of a number only the daemon knows — the same
reason `next` arrives on the event at all.")

(defstruct (session (:constructor %make-session))
  (session-id "" :type string)
  (head-id "" :type string)
  (dropped 0 :type fixnum)              ; events fallen off the scrollback
  (items-dropped 0 :type fixnum)        ; transcript rows trimmed from snapshot
  (seq 0 :type fixnum)                  ; last seq consumed
  (expected-seq 0 :type fixnum)         ; what our next command carries
  (items (make-array 0 :adjustable t :fill-pointer 0) :type vector)
  turn                                   ; TurnView plist or nil
  (open-decisions nil :type list)        ; OpenDecision plists, NEWEST first: a fresh
                                         ; ask is PUSHED, so `%open-decision` (and
                                         ; panes.lisp) take `first`. The reference
                                         ; APPENDS (app.rs:2599), so its `first` is
                                         ; the OLDEST — unobservable while the
                                         ; daemon serializes on the tool call and
                                         ; only one ask is ever open.
  (settled-decisions nil :type list)
  (warnings nil :type list)              ; Warning plists, NEWEST first
  (retired nil :type list)               ; warning identities the reader has retired
  (denials nil :type list)               ; DenialRaised, newest first
  (notices nil :type list)               ; CommandIssued etc, newest first
  (heads nil :type list)                 ; HeadPresence plists
  (todos nil :type list)                 ; TodoEntry plists
  (title "" :type string)
  (sessions nil :type list)              ; SessionBrief plists (picker)
  (subagents nil :type list)             ; Subagent events, newest first
  (jobs nil :type list)                  ; JobSettled, newest first
  wiring)                                ; SessionWiring plist

(defun make-session ()
  (%make-session))

(defun %items-vector (items)
  "Items arrive as a list from yason. Make an adjustable fill-pointer vector
so push-item can grow it and fill-item can fill rows in place. (coerce to
'vector gives a FIXED vector with no fill pointer — vector-push-extend
refuses it: 'not an array with a fill pointer'.)"
  (let ((v (make-array (length items) :adjustable t :fill-pointer 0)))
    (loop for item in items do (vector-push-extend item v))
    v))

(defun %clear-session-scoped (session)
  "Throw away everything that belonged to the session we are LEAVING.

A snapshot is a replacement, and it carries only what `view.rs:278-297` lists —
so every session-scoped table the snapshot does NOT carry survived a `/switch`
and arrived wearing the last conversation's clothes. `load` (app.rs:1902-1934)
clears each of these with a measured reason behind it: the subagent tree is the
PARENT's fact and carried across a switch it put *\"1 subagent running\"* on the
composer of the very subagent being looked at; the job rows kept drawing the old
session's ids and byte counts, and now that Enter on a row asks THIS session for
that id, a carried row is a question about a job that was never here; a denial or
a notice from a conversation that is no longer on the screen is the same lie a
carried-over model name is. The running turn's clock goes with them — nothing
cleared `*turn-started-ms*`, so a switch left the previous session's start time
walking under the new session's composer."
  (setf (session-subagents session) nil
        (session-jobs session) nil
        (session-denials session) nil
        (session-notices session) nil)
  (setf *turn-started-ms* nil)
  ;; the staged call facts are keyed by a call id that only existed over there
  (%round-boundary))

(defun ingest-snapshot (session snapshot)
  "Replace state with SNAPSHOT's. Resync is a normal outcome, never an error
— this is also the Resync-frame path.

The id is compared BEFORE it is assigned, because that comparison is the only
thing that knows whether this is the same conversation (app.rs:1897-1934)."
  ;; the transcript's lines are replaced wholesale, so the render cache is stale
  (incf *hist-generation*)
  (let ((id (or (getf snapshot :session-id) "")))
    (unless (string= id (session-session-id session))
      (%clear-session-scoped session)))
  (setf (session-session-id session) (or (getf snapshot :session-id) "")
        (session-seq session) (or (getf snapshot :seq) 0)
        (session-expected-seq session) (or (getf snapshot :seq) 0)
        ;; `dropped` only ever grows: it is this head's running count of events
        ;; it will never see, and a snapshot that knows of fewer than we have
        ;; already counted is not a correction (app.rs:1937 takes the max)
        (session-dropped session) (max (session-dropped session)
                                       (or (getf snapshot :dropped) 0))
        (session-items-dropped session) (or (getf snapshot :items-dropped) 0)
        (session-turn session) (getf snapshot :turn)
        (session-open-decisions session) (getf snapshot :open-decisions)
        (session-settled-decisions session) (getf snapshot :settled-decisions)
        ;; **REVERSED into this slot's own order.** A snapshot's warnings are the
        ;; daemon's `Vec` pushed in arrival order — oldest first (`view.rs:660`) —
        ;; while a live warning is PUSHED here, so the slot is newest-first. The two
        ;; orders have to agree or `/notes` numbers the list backwards after a resync,
        ;; and `warning-order` would then hand `/notes dismiss N` the wrong warning.
        (session-warnings session) (reverse (getf snapshot :warnings))
        (session-heads session) (getf snapshot :heads)
        (session-items session) (%items-vector (getf snapshot :items)))
  ;; ONE PASS over the items, for the display targets a head that attached AFTER
  ;; a turn has no live proposals to learn from: the assistant row is the only
  ;; place that call is described, and a `ToolResult` row carries no target.
  (note-snapshot-targets (getf snapshot :items))
  (note-snapshot-answered (getf snapshot :items))
  ;; and the carry, which is what a snapshot with bodiless rows IS: see `note-carry`
  (note-carry (getf snapshot :items))
  ;; **A snapshot's warnings are history this head has not shown, so it shows it.**
  ;; The rows went with the transcript the snapshot replaced, and the retired set —
  ;; which a snapshot does NOT carry and must not — decides which of them come back
  ;; visible. This is the path that made the reference's wall come back at position 0
  ;; above the whole conversation, and keying the set outside the transcript is the
  ;; answer: a retired warning is filed HIDDEN here, so a resync and a reattach
  ;; replant the wall retired.
  ;;
  ;; `turn_failed` is filtered here as well as on the live path, which the reference
  ;; needs too and for the same reason: a snapshot that put it back would replant the
  ;; one sentence the screen already says in the turn's own footer
  ;; (app.rs:2527-2534), and the two paths have to agree about every filter
  ;; (`bacf495`).
  (dolist (w (session-warnings session))
    (unless (equal (getf w :code) "turn_failed")
      (note-warning session w)))
  session)

(defvar *scrubbed-total* 0
  "Interactive-only frames the daemon withheld from this head because it attached
late — the `ScrubReport` on `Hello` (protocol.rs:706), its four counts summed the
way the reference's `scrubbed.total()` sums them. Shown on `/status`; a defvar so a
push can introduce it without a slot.")

(defun %scrub-total (report)
  "The sum of a `ScrubReport` plist's counts, or 0 for none.

Summed by SHAPE rather than by a list of field names, which is why
`job_output` — the count letibot added with `SessionEvent::JobOutput`, for the
windows `StoredProjection::keep` strips because a window from four minutes ago
is a lie about now — needed no change here to be counted. A head that enumerated
the four names it knew would have dropped the fifth silently, and the whole
point of the number is to keep *\"busy, none of it was for me\"* apart from
*\"quiet\"*."
  (loop for (nil v) on report by #'cddr when (integerp v) sum v))

(defun ingest-hello (session hello)
  "Fold a `Hello`, with or without a snapshot.

**A Hello answering a resume carries no snapshot.** Every reconnect
(`%try-reconnect` re-attaches with `since_seq = session-seq`, which is nonzero)
and every resume whose gap is still in the daemon's ring is served from the
scrollback: `hub.rs:628-652` sends `Hello { snapshot: null, resumed_from: N }`
and the gap follows as `Event` frames. This function called `ingest-snapshot`
unconditionally, which assigned `session-session-id` ← `\"\"` and then `NIL` into
a `:type fixnum` slot and signalled — swallowed by `run-loop`'s handler into
`*last-render-error*`, so the head neither crashed nor recovered: the session id
was wiped, `head_id`, `wiring`, `sessions`, the title and `resumed_from` were
never read, the settings were never asked for and the attach indicator walked
forever. Measured: `RESUME-ERROR: TYPE-ERROR` against `SNAPSHOT-OK` for the same
Hello with a snapshot. No reconnect and no resume had ever worked. The reference
assigns the id explicitly on that path and keeps the state it already has
(`app.rs:1680-1685`)."
  (incf *scrubbed-total* (%scrub-total (getf hello :scrubbed)))
  (setf (session-head-id session) (or (getf hello :head-id) ""))
  ;; `dropped` ACCUMULATES. It was assigned, so a reattach reset this head's
  ;; running count of the events it will never see, and `/status` under-reported
  ;; every time it mattered (app.rs:1672 `+=`, app.rs:1937 `max`).
  (incf (session-dropped session) (or (getf hello :dropped) 0))
  (setf (session-sessions session)
        ;; SUBAGENTS ARE NOT SESSIONS a picker lists: they are children of this
        ;; one, shown in the subagent tree and reached by `/switch id`. The
        ;; reference filters them before storing, on both frames that carry the
        ;; list (app.rs:1668-1671, 1732-1735).
        (remove-if (lambda (b) (getf b :parent-session-id)) (getf hello :sessions))
        (session-wiring session) (getf hello :wiring))
  (if (getf hello :snapshot)
      (ingest-snapshot session (getf hello :snapshot))
      (let ((id (or (getf hello :session-id) "")))
        ;; the resumed-from path: what is already here IS this session's state,
        ;; unless the Hello names a different session — then none of it is
        (unless (string= id (session-session-id session))
          (%clear-session-scoped session))
        (setf (session-session-id session) id)))
  ;; THE TITLE FROM THE SESSION LIST. Our `session-title` was only ever set by a
  ;; `session_renamed` EVENT, so a head that attached to a named session showed
  ;; its raw id in the header while letibot showed the name. Measured against
  ;; letibot's own screen: `▌ hello, what we are doing here` against
  ;; `▌ s-1789639478142928813`. The name is in the Hello's session list, which is
  ;; also what the picker reads.
  ;;
  ;; Looked up in the Hello's OWN list, not in the filtered one we just stored: a
  ;; head attached to a subagent session is looking at a row the picker filter
  ;; drops, and it still has a name.
  (let ((brief (find (session-session-id session) (getf hello :sessions)
                     :key (lambda (b) (getf b :session-id)) :test #'string=)))
    (when brief
      (setf (session-title session) (or (getf brief :title) ""))))
  (unless (getf hello :snapshot)
    ;; a resume served from scrollback: the gap follows as Event frames, and
    ;; our mark is where we asked to resume from
    (setf (session-seq session) (or (getf hello :resumed-from) 0)
          (session-expected-seq session) (session-seq session)))
  session)

;;; ------------------------------------------------------------ items ;;;

(defun item-id (item) (getf item :item-id))
(defun item-kind (item) (getf item :kind))
(defun item-body (item) (getf item :item))
(defun item-ts (item) (getf item :ts))

(defun find-item (session item-id)
  (loop for i across (session-items session)
        when (string= (item-id i) item-id) return i))

(defun push-item (session item)
  ;; a new committed row: the render cache is one line stale
  (incf *hist-generation*)
  (vector-push-extend item (session-items session)))

(defun fill-item (session item-id body)
  (let ((hit (find-item session item-id)))
    (when hit
      ;; a body arriving changes how the row RENDERS, and the item count does not
      ;; move — which is why the cache's key is a generation and not a count
      (incf *hist-generation*)
      (setf (getf hit :item) body))))

;;; ------------------------------------------------------------- turns ;;;

(defun turn-state-name (turn)
  (getf (getf turn :state) :state))

(defun call-view (turn call-id)
  (when turn
    (find call-id (getf turn :calls) :key (lambda (c) (getf c :call-id))
          :test #'string=)))

(defun %call-put (call key value)
  "Write KEY on CALL's plist IN PLACE, and answer CALL.

`(setf (getf call key) v)` on a LOCAL holding a plist whose KEY is absent conses
a fresh head and assigns the local — the list inside `turn.calls` is never
touched. That is exactly what `ToolProgress` did: every progress note this head
ever folded went nowhere, measured as `PROGRESS-NOTE-AFTER-FINISH = NIL`, with
the card's slot for it (`cards.lisp:942`) permanently empty. A key already
present is written through its own cons; an absent one is appended at the tail,
which mutates the very list the turn holds. `:progress-note` is this head's own
key and never on the wire (`CallView` has no `note` field), so a call that came
out of a SNAPSHOT is always the absent case."
  (let ((cell (loop for c on call by #'cddr when (eq (car c) key) return c)))
    (if cell
        (setf (second cell) value)
        (nconc call (list key value))))
  call)

(defun ensure-call (turn call-id name target)
  "The call CALL-ID on TURN, moved to RUNNING — created if ToolStarted is the
first this head heard of it.

This was `(or (call-view …) (push …))`, so a call that already existed as
`proposed` was returned UNCHANGED and the running card never appeared: measured,
`CALL-STATE-AFTER-STARTED = \"proposed\"`, and the card drew `○ bash ls ·
proposed` for the whole run instead of `◐ bash ls · 3.2s`. The reference sets
`Running`, restarts the clock and clears the note (`app.rs:2356-2400`).

The note is CLEARED rather than kept: the notes a call collects while it is
proposed are about the DECISION — *\"asking the guard\"* — and `app.rs:2365-2386`
records what one cost when it rode the card through the whole run. The operator
read the screen exactly as it was written, reported the session hung requesting
the oracle, and the diagnosis cost an hour over a guard that had answered in
milliseconds."
  (let ((call (call-view turn call-id)))
    (cond (call
           (setf (getf call :state) (list :state "running"))
           (%call-put call :progress-note nil)
           call)
          (t
           ;; ToolStarted carries no target and none is invented (app.rs:2391)
           (let ((new (list :call-id call-id :name name :target target
                            :args-digest "" :progress-note nil
                            :state (list :state "running"))))
             (push new (getf turn :calls))
             new)))))

;;; ------------------------------------------------------ event application ;;;

(defvar *model-from-settings-at* 0
  "The session seq when the `model` settings row was last received.")
(defvar *model-from-turn-at* 0
  "The session seq when a TurnStarted last named the model answering.")

(defvar *verbosity* :normal
  "How much of the event stream is drawn: `:terse`, `:normal` or `:loud` — the
reference's `Verbosity`, cycled by `/verbosity`. Terse drops the model's reasoning
deltas on the floor (they are FILTERED, and the ack says so); loud draws the
head-attached and head-detached events that normal keeps off the screen. A defvar
so a push can introduce it and a head slot need not change.")

(defun next-verbosity (v)
  (ecase v (:terse :normal) (:normal :loud) (:loud :terse)))

(defun verbosity-at-least (level)
  "Is `*verbosity*` at or above LEVEL, in the order terse < normal < loud?"
  (>= (position *verbosity* '(:terse :normal :loud))
      (position level '(:terse :normal :loud))))

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

;;; ------------------------------------------------- this head's own rows ;;;
;;;
;;; **A sentence this head writes ABOUT ITSELF, filed where it happened.** The
;;; conversation is the only place a fact about the connection can live and still be
;;; readable an hour later: a status note sits pinned above the composer and expires
;;; on a TTL, so anything filed there is gone — and gone SILENTLY — by the time
;;; anybody thinks to look, which is the failure this shape exists to avoid.
;;;
;;; Two facts are filed this way and both are about the SOCKET rather than the session
;;; log, which is why `ts` is 0 rather than invented: a frame this head could not read
;;; (`note-unreadable`) and a protocol skew at the handshake (`note-protocol-skew`).

(defvar *filed-notes* 0
  "How many rows this head has filed about itself, over its life.

A `defvar` so a push can introduce the next filer without a struct slot, and not a
constant, because a constant is the one kind of definition the file pusher SKIPS.")

(defun file-head-note (session text)
  "FILE TEXT into the conversation as a row of this head's own, at the point it
happened. Returns the item.

`:kind`/`:type` are both `note`, which no daemon item uses — the wire's are `user`,
`assistant`, `reasoning`, `tool_result`, `system` and `segment_mark` — so
`item-lines` renders it as `! …` in the failure role, the reference's `warn_line`
(app.rs:8425-8427), without a tag anybody could also send.

An item id unique to this head, because the wire's ids are `s.3`, `t1.0` and the
like and nothing the daemon sends must ever be confused with a row this head wrote."
  (incf *filed-notes*)
  (let ((item (list :item-id (format nil "leticl-note-~d" *filed-notes*)
                    :kind "note"
                    :ts 0
                    :item (list :type "note" :text text))))
    (push-item session item)
    item))

(defvar *unreadable-total* 0
  "Frames that arrived and could not be read, over this head's life.

The bucket the reference's `/status` gained with this requirement, and the one
number that keeps *the daemon is sending me something I do not understand* apart
from *the daemon is quiet*. A `defvar` rather than a session slot, and NOT reset
by a snapshot: it counts this head's lifetime, so a row that reads 0 is a head that
has never met one — a different statement from a head that does not count them.")

(defparameter *unreadable-line-cols* 200
  "How much of the offending line the complaint carries.

A `defparameter` and not a `defconstant`: the file pusher SKIPS `defconstant` (it
changes a definition the image has already copied), so a constant here could never
be changed on a running head — the one thing every value in this repo must allow.")

(defun unreadable-said (detail line)
  "The sentence this head says about a frame it cannot read.

ONE function, so the three places that can meet one cannot describe it three
ways: a head that exits, a head that shrugs and a head that counts have to agree
about what happened, and the only way to guarantee that is one string.

It names this head's OWN protocol version, because the two numbers are the whole
comparison — a daemon newer than this head is almost always the cause, and saying
so is what sends the operator to the right half. The offending line rides along
TRUNCATED rather than dropped: the line is the evidence, a decoder that reports
\"bad frame\" without the frame turns a precise complaint into a shrug, and the
first question anybody asks about a skew is *which frame*."
  (let* ((width (string-width (or line "")))
         (shown (and (plusp width) (truncate-to-width line *unreadable-line-cols*)))
         (cut (> width *unreadable-line-cols*)))
    (format nil "the daemon sent a frame this head cannot read (~a). This head ~
                 speaks protocol ~d; a daemon built against a newer one will do ~
                 this on the first frame the two do not share, and it is almost ~
                 always that rather than a corrupt stream. The connection is ~
                 still up.~@[ The line was: ~a~a~]"
            detail +protocol-version+ shown (if cut "…" ""))))

(defun note-unreadable (session detail line)
  "SAY it, COUNT it, keep going — the one entry point for a frame this head cannot
read. Returns `:dirty`, so a caller folding an envelope hands it straight back.

**The sentence is filed as a ROW IN THE CONVERSATION, at the point it arrived** —
not as a status note, which is the head state this repo already has and is the
wrong shape twice over: a note sits pinned above the composer for a few frames and
then expires on a TTL, so a frame this head could not read would be gone by the
time anybody looked for it, and it would be gone silently, which is the failure
again. An item is anchored where it landed and scrolls away with the rest of the
conversation, which is what \"where it arrived\" means and why `ts` is 0 rather than
invented: this happened on the SOCKET, and the session log's clock is not this.

**Nothing is acked and the read mark does not move.** No frame was parsed, so
there is no seq to report, and inventing one would rewind the mark over frames
already read — the one thing a mark must never do. `/status`'s `filtered` is \"events
I chose not to show\" and this is not that either."
  (incf *unreadable-total*)
  (file-head-note session (unreadable-said detail line))
  :dirty)

(defun note-protocol-skew (session said)
  "FILE the skew sentence into the conversation, at the handshake. Returns `:dirty`.

**Not counted as unreadable.** A skew is a fact about two BUILDS and it is said once
per connection — counting it there would make `/status`'s number mean *frames I could
not read* PLUS *times I noticed two versions*, and that first number is the one an
operator uses to tell a chatty daemon from a broken one. The version it was about has
its own `/status` row, which is the other half of this fact.

**Nothing is acked for it and the read mark does not move**: a `Hello` carries no
`seq` (it is a snapshot, not an event), so there is nothing to report and inventing
one would rewind the mark over frames already read."
  (file-head-note session said)
  :dirty)

;;; ---------------------------------------------------- the warning record ;;;
;;;
;;; R10. **A warning is a DISCLOSURE, not a permanent record.**
;;;
;;; The defect this file had was the mirror of letibot's, and the operator's own
;;; measurement is the specification: a `warning` envelope arrived, `session-warnings`
;;; went from 9 to 10, and it was visible NOWHERE — not a row, not a note, not a
;;; counter, not the alarm. So `auto_compact`, `compacted`, `context_wall`,
;;; `transcript_store`, `decision_corpus` and `mode_set` had never once reached this
;;; head, and every one of those is a sentence the daemon meant the operator to read.
;;;
;;; Two halves, and they are the two halves of the same rule:
;;;
;;;   · **draw it.** A warning is filed as a row in the conversation AT THE POINT IT
;;;     ARRIVED — `note-warning`, the `note-unreadable` shape — because a status note
;;;     expires on a TTL and takes the fact with it, while an item scrolls away with
;;;     the conversation, which is what "where it arrived" means.
;;;   · **keep it retired.** A reader can retire one, and a retired warning stays
;;;     retired across a resync and a reattach. Both of those REPLACE the transcript
;;;     from a snapshot, so a retirement stored on the row itself would be undone by
;;;     the very event the requirement names: the set is keyed by the warning's own
;;;     `(code detail ts)` identity and kept on the session, outside anything a
;;;     snapshot replaces.
;;;
;;; **The retired set is NOT cleared by a `/switch`**, and that is deliberate: it is
;;; this head's memory of what it has shown, and the reference keeps its `dismissed`
;;; the same way (`app.rs:886` is not in its `load`'s clear list, `app.rs:1902-1934`).
;;; An identity is `(code ts detail)` and `ts` is the log's clock, so two sessions
;;; colliding on one is the same warning at the same instant either way.
;;;
;;; **What is NOT here, deliberately.** `turn_failed` is filed by neither half: the
;;; turn's own terminal state already says it on the screen, the log holds it, and a
;;; second copy three lines under the first is the shape this head avoids everywhere
;;; (app.rs:3320-3330 answers `Disposition::Filtered`). `job_output_refused` answers
;;; the pane that asked AND files the row; `slash`/`slash_refused` open the listing
;;; pane when they are long enough to be one and file the row otherwise. A code with
;;; a better home keeps it; this default is for every other code, including the ones
;;; the daemon has not invented yet.

(defparameter +note-lines+ 3
  "Lines of a warning the conversation shows before it is a wall.

R10's other half, and the number is the reference's `NOTE_LINES` rather than a taste
of ours: two gate timeouts rendered 27 red lines there (*\"how to remove this red
wall?\"*), which is about thirteen lines a warning — a `denied:` detail carrying the
whole rule. Three lines keeps the code, the first sentence and the fact that there is
more, and puts the rest one verb away. `/notes` prints the whole text, so this is a
disclosure decision and NEVER a cap on the record.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defun warning-identity (w)
  "The name a warning keeps across a resync and a reattach.

Built from the warning's OWN facts and nothing about where it is on the screen: its
`code`, the log's `ts` for the envelope that carried it, and its `detail`. `ts` is
what tells one announcement from a redelivery of it, which is the same reason the
reference's `note` dedupes on the triple (`app.rs:5689-5697`).

The detail is NOT hashed, where the reference hashes it: its key is written into
`head.toml` as one comma-separated value and a paragraph there would be a file
nobody can read, while this set lives in memory for the life of the process. If it
ever has to be written down, it has to be hashed — and that is a change to make
when it is asked for, not a cost to pay now."
  (format nil "~a|~a|~a"
          (or (getf w :code) "") (or (getf w :ts) 0) (or (getf w :detail) "")))

(defun session-retired-p (session w)
  "Has the reader already retired W?"
  (and (member (warning-identity w) (session-retired session) :test #'string=) t))

(defun %reflag-warning-rows (session)
  "Point every warning row at the session's retired set, after the set moved.

The row carries `:retired` so `item-lines` can answer without a session — it is
handed an item and nothing else — and the set is the truth, so the rows are derived
from it rather than the other way round."
  (loop for item across (session-items session)
        when (getf item :warning)
          do (setf (getf item :retired)
                   (and (session-retired-p session (getf item :warning)) t))))

(defun warning-note-text (w)
  "What a warning SAYS, without the register.

ONE function, because the row in the conversation and the `/notes` listing must not
describe the same warning two ways: the reference makes the same point by rendering
the listing with the transcript's own `note_lines_unfolded` (`app.rs:5860-5864`). The
row prefixes this with `!` at its own renderer; the listing prefixes it here."
  (format nil "~a — ~a" (or (getf w :code) "?") (or (getf w :detail) "")))

(defun note-warning (session w)
  "DISCLOSE W: file a row for it where it arrived. Returns the row.

A retired warning is filed too, HIDDEN. That is not laziness: `/notes restore` then
has a row to bring back instead of one to invent, and a snapshot that replants the
wall replants it retired, which is the whole point of keying the set outside the
transcript. The row is the disclosure and `session-warnings` is the record — the
same division `/status`'s `filtered` counter keeps, where *\"I chose not to show
this\"* must not look like *\"nothing happened\"*."
  (let* ((id (warning-identity w))
         (row (list :item-id (format nil "leticl-note-~d" (incf *filed-notes*))
                    :kind "note"
                    :ts (or (getf w :ts) 0)
                    :warning w
                    :retired (and (member id (session-retired session) :test #'string=) t)
                    :item (list :type "note"
                                :text (warning-note-text w)
                                :cap +note-lines+
                                :seam "/notes"))))
    (push-item session row)
    row))

(defun warning-order (session)
  "The warnings this head holds, OLDEST first — the order `/notes` numbers them in.

`session-warnings` is newest-first because a live warning is pushed; a snapshot's
own list is the daemon's, which is chronological. Reversing gives the reading order
the listing wants, and the numbering a reader types back."
  (reverse (session-warnings session)))

(defun retire-warning (session w)
  "Retire W: take its row off the screen and remember that it is retired.

**Retired is not deleted.** The warning stays in `session-warnings`, `/status` counts
it, and `/notes` lists it with its whole text — the temptation is a dismiss key that
drops the sentence, and a head that can drop a warning silently is a head whose
warnings cannot be trusted to be complete. Returns NIL when it was already retired."
  (let ((id (warning-identity w)))
    (if (member id (session-retired session) :test #'string=)
        nil
        (progn
          (push id (session-retired session))
          (%reflag-warning-rows session)
          ;; a row that renders as nothing is a change the cache cannot see: the
          ;; item count and the vector's identity both hold still
          (incf *hist-generation*)
          t))))

(defun retire-all-warnings (session)
  "Retire every warning this head holds. Returns how many newly went.

Through `retire-warning` one at a time rather than by emptying the list, so the row
flags and the generation bump happen by the one path that knows how to do them."
  (let ((n 0))
    (dolist (w (session-warnings session))
      (when (retire-warning session w) (incf n)))
    n))

(defun restore-warnings (session)
  "Put every retired warning back on the screen. Returns how many came back."
  (let ((back (length (session-retired session))))
    (setf (session-retired session) nil)
    (%reflag-warning-rows session)
    (incf *hist-generation*)
    back))

(defun warning-counts (session)
  "`(values HELD RETIRED)` for `/status`: how many warnings this head holds, and how
many of them the reader has retired.

Computed from the WARNINGS rather than kept as a counter, for the reason the
reference computes it the same way (`app.rs:5727-5732`): a counter can disagree with
the screen, and a count of what is hidden is the one count that may not be wrong.
`HELD` is the session's list, so `RETIRED` can never exceed it."
  (let ((ws (session-warnings session)))
    (values (length ws)
            (count-if (lambda (w) (session-retired-p session w)) ws))))

(defparameter +events-not-folded-here+
  '(:explain :screen-requested :secret-requested :secret-settled)
  "Events this head KNOWS and does not fold into session state.

Two kinds, and both have to be named or the counter cries wolf:

  · **folded by the head LOOP, which owns the last painted frame and the input
    focus** — `screen_requested` is answered with the rows just drawn,
    `secret_requested` raises the masked field, `secret_settled` dismisses it.
    `apply-event` is the session's folder and cannot do any of those; it is handed
    these only by a caller that skipped the loop (a test, a replay), so without
    this list a head would report a frame it reads perfectly well;
  · **`explain`**, which the reference answers `Filtered` (app.rs:3017) and this
    head has no renderer for.

Named here rather than left to the fallthrough so that *I know this tag and it is
not mine to fold* stays separable from *I have never heard of this tag* — which is
the difference between a quiet head and a silent one, and the whole point of
`*unreadable-total*`.")

;;; ------------------------------------------------------ a counted operation ;;;
;;;
;;; **The daemon's own counter, when there is one.** `SessionEvent::Filling
;;; { what, unit, done, total }`: `what` is the operation in the daemon's own words,
;;; `unit` the noun its count is in, and `done`/`total` the count. It exists because
;;; **the layer that owns the fact should state it** — a head can see that rows are
;;; missing bodies, and cannot see whether that is a reseat, a `/compact`, a resume or
;;; a plain attach. A carry is the same kind of fact and is the reason the event is
;;; general rather than an import's: one event, one renderer, and the head infers only
;;; when nobody has told it.
;;;
;;; **Ephemeral**, like `JobOutput`: a tick from four minutes ago is a lie about now.
;;; The durable residue of an import is the rows themselves and its finish note. So
;;; this is a defvar and not a session slot, it is not snapshot-carried, and it is
;;; cleared the moment the count is complete — a bar left at `total of total` would sit
;;; on the screen for ever, and a bar that cannot end is worse than no bar.

(defvar *filling* nil
  "The counted operation in flight, or NIL: a plist
`(:what W :unit U :done D :total T :at-ms M)`.

A defvar, not a session slot, for the reason all live state is: a struct layout change
is a restart. Bound by `with-replay-globals`, because a replay must answer the same
bytes twice.")

(defun filling-active-p ()
  "Is a counted operation in flight that the head should draw?

Two ways it ends, and both are facts rather than timers: the count COMPLETES
(`done >= total`), or the connection does. The second matters because the daemon
publishes ticks while it works, so a socket that goes mid-import would otherwise leave
a bar claiming progress for ever — and *a bar that cannot end is worse than no bar*."
  (and *filling*
       (let ((done (or (getf *filling* :done) 0))
             (total (or (getf *filling* :total) 0)))
         (and (plusp total) (< done total)))))

(defun note-filling (env)
  "Fold one `filling` tick. Returns `:dirty` when the line should be redrawn.

**The completion is the clear.** `done == total` is the daemon saying it is finished,
and the line goes — the operation's own finish note is what says it ended, and a bar
left at `total of total` would sit on the screen for ever. A tick with no `total`, or
with `total` zero, is not an operation to draw either: there is nothing to be a
fraction OF, and a line reading `0 of 0` is a render fault dressed as a measurement.

**`what` and `unit` are the daemon's and are kept as they arrive**, verbatim, including
`NIL` — `filling-progress-line` is what decides how to draw each, so one place knows
the fallbacks rather than two. A daemon that sent `filling` without the words (a
version skew, R5) gets the head's own cause-free sentence rather than a `NIL` where a
noun goes."
  (let ((done (or (getf env :done) 0))
        (total (or (getf env :total) 0)))
    (setf *filling* (when (and (integerp total) (plusp total)
                               (integerp done) (< done total))
                      (list :what (getf env :what)
                            :unit (getf env :unit)
                            :done done :total total
                            :at-ms (and (plusp *now-ms*) *now-ms*))))
    :dirty))

(defun reset-filling ()
  "Forget a counted operation. For a session change, and for a dead socket."
  (setf *filling* nil))

;;; ------------------------------------------------------------- the carry ;;;
;;;
;;; **A bulk announcement, and the rows it left outstanding.** `/reseat` and
;;; `/compact` publish an announcement for every carried row before a single body
;;; follows, so a head that draws one placeholder per row draws a screen of them —
;;; *"insane amount of grainess"*. One progress line instead (`carry-line`,
;;; chrome.lisp), and this is the state it needs.
;;;
;;; **The carry's rows are the ones THE ANNOUNCEMENT LEFT OUTSTANDING, recorded by
;;; id.** That is the fact, and it is not the same as "every row in the session that
;;; lacks a body" — measured on the operator's own live session, 2 of its 4451 rows
;;; have no body and never will (they are in the middle of its history, from a turn
;;; long finished), so a count over the whole transcript would put a progress line on
;;; their screen for a carry that is not happening. The reference's `peak - pending`
;;; has the same shape of error: its `pending` is measured over the session, so an
;;; ancient bodiless row is counted as work still to do.
;;;
;;; Recorded at the SNAPSHOT because that is where a bulk announcement arrives (the
;;; reference's `adopt` and its own test: *"the snapshot really does arrive carrying
;;; bodiless rows"*). A live `transcript_appended` announces one row whose body
;;; follows in the same drain pass, which is not a carry and never draws a line.

(defvar *carry-outstanding* nil
  "A hash table of the item ids a bulk announcement left without bodies, or NIL when
no carry is in flight. A defvar, not a session slot: a struct layout change is a
restart, and this has to be reachable from a push.")

(defun note-carry (raw-items)
  "Note which rows RAW-ITEMS announced without bodies, or clear the carry.

A snapshot with every body present clears it — a new snapshot replaces the world, and
a carry that was in flight when it landed is not one any more. Returns how many rows
the announcement left outstanding."
  (let ((out (make-hash-table :test #'equal))
        (n 0))
    (dolist (raw (coerce (or raw-items nil) 'list))
      (when (and (consp raw) (null (getf raw :item)) (getf raw :item-id))
        (setf (gethash (getf raw :item-id) out) t)
        (incf n)))
    (setf *carry-outstanding* (and (plusp n) out))
    n))

(defun reset-carry ()
  "Forget the carry. T when there was one."
  (let ((had (and *carry-outstanding* t)))
    (setf *carry-outstanding* nil)
    had))

(defun %carry-counts (session)
  "How many rows the carry announced, and how many of them have ARRIVED.

`(values 0 0)` when nothing is in flight. Both numbers are counted off the rows, every
frame — the ids were recorded when the announcement was made, and whether the row has
a body is read from the row itself. Nothing is remembered about the progress, which is
the rule this repo learned the hard way: an incremental tally kept alongside a
collection goes stale the moment something replaces the collection, and a fork is
exactly when something does. The reference shipped that and the operator saw a bar
that never moved — *\"so, counter wasnt moving - 0 always\"*."
  (if (null *carry-outstanding*)
      (values 0 0)
      (let ((total (hash-table-count *carry-outstanding*))
            (done 0))
        (declare (type fixnum total done))
        (loop for item across (session-items session)
              do (when (and (gethash (item-id item) *carry-outstanding*)
                            (item-body item))
                   (incf done)))
        (values total done))))

(defun apply-event (session env)
  "Fold one envelope into state. Returns :dirty when something visible
changed, :quiet when not — the head loop paints on :dirty and acks on both."
  (let ((name (event-name env))
        (seq (getf env :seq)))
    ;; the seq is consumed either way: a filtered frame still advances the read
    ;; mark, or a head that draws little rereads its own output forever
    (setf (session-seq session) seq
          (session-expected-seq session) seq)
    ;; a stranger's turn is consumed and not folded — before any side effect
    (when (and (member name +per-turn-events+) (%foreign-turn-p session env))
      (return-from apply-event :quiet))
    (case name
      ((:turn-started)
       ;; WHEN it started, on our own clock, so the composer's edge can say how
       ;; long this has been going. A turn that came out of a SNAPSHOT has no
       ;; start time — `*turn-started-ms*` stays NIL and the edge says "started
       ;; before this head attached" rather than a duration nobody measured.
       (setf *turn-started-ms* (and (not (getf env :snapshot)) (internal-real-time-ms)))
       ;; the turn names the model answering it, unprompted — the one word about
       ;; the model a head is told after attach, so the header ranks it by seq
       (when (plusp (length (or (getf env :model) "")))
         (setf *model-from-turn-at* seq))
       (setf (session-turn session)
             (list :turn-id (getf env :turn-id) :model (getf env :model)
                   :ledger-head (getf env :ledger-head)
                   :text "" :reasoning "" :raw-calls ""
                   :calls nil :appended nil :progress nil :tokens 0
                   :state (list :state "running")))
       :dirty)
      ((:tokens-generated)
       ;; **The live token counter.** This event was on the wire and handled by
       ;; NOTHING in this head — the same shape as the four frames P2 found, and
       ;; it is why the box's edge could not show `· 188 tok` the way letibot's
       ;; does.
       ;; TAKEN, NEVER ASSIGNED. `setf` walks the counter BACKWARDS on a
       ;; reordered or duplicated frame — measured, `50` then `10` left `10` —
       ;; and both the reference and the view use `max` for exactly that
       ;; (app.rs:2281, view.rs:419): a token count that can fall is a number
       ;; nobody can read.
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :tokens)
                 (max (or (getf turn :tokens) 0) (or (getf env :tokens) 0))))
         (if turn :dirty :quiet)))
      ((:delta)
       (let ((turn (session-turn session)))
         (when turn
           ;; target is a snake_case string on the wire (DeltaTarget,
           ;; event.rs:52) — "tool_call" must become :tool-call to match.
           (case (and (getf env :target) (%key-from-wire (getf env :target)))
             ((:text) (appendf-text turn :text (getf env :text)))
             ;; at terse the working-out is not kept and not drawn: filtered,
             ;; which the ack counts, rather than rendered
             ((:reasoning) (if (verbosity-at-least :normal)
                               (appendf-text turn :reasoning (getf env :text))
                               (return-from apply-event :quiet)))
             ((:tool-call) (appendf-text turn :raw-calls (getf env :text)))))
         ;; a delta for a turn we never saw TurnStarted for: quiet, not a crash
         (if turn :dirty :quiet)))
      ((:prompt-progress)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :progress)
                 (list :total (getf env :total) :cache (getf env :cache)
                       :processed (getf env :processed) :time-ms (getf env :time-ms))))
         (if turn :dirty :quiet)))
      ((:tool-call-proposed)
       ;; the live proposal carries the daemon's OWN derivation of the target
       (note-call-target (getf env :call-id) (getf env :target))
       (let ((turn (session-turn session)))
         (when turn
           (push (list :call-id (getf env :call-id) :name (getf env :name)
                       :args-digest (getf env :args-digest)
                       :target (getf env :target)
                       :state (list :state "proposed"))
                 (getf turn :calls)))
         (if turn :dirty :quiet)))
      ((:tool-started)
       ;; note WHEN it began: neither ToolFinished nor the row that lands
       ;; afterwards carries a duration, so this is the only source for it
       (note-call-started (getf env :call-id))
       (let ((turn (session-turn session)))
         (when turn
           (ensure-call turn (getf env :call-id) (getf env :name) ""))
         (if turn :dirty :quiet)))
      ((:tool-progress)
       ;; written THROUGH the place, never onto a local: see `%call-put`
       (let ((call (call-view (session-turn session) (getf env :call-id))))
         (when call (%call-put call :progress-note (getf env :note)))
         (if call :dirty :quiet)))
      ((:tool-finished)
       ;; stage what the live card knows, for the row that is about to land:
       ;; a settled ToolResult carries no duration and no timestamps at all
       (note-call-finished (getf env :call-id) :edit (getf env :edit))
       (let ((call (call-view (session-turn session) (getf env :call-id))))
         (when call
           ;; the note described a moment that has now passed (app.rs:2445). It
           ;; could never go stale while `ToolProgress` wrote nowhere; it can now.
           (%call-put call :progress-note nil)
           (setf (getf call :state)
                 (list :state "finished"
                       :outcome (getf env :outcome)
                       :inline-bytes (getf env :inline-bytes)
                       :full-bytes (getf env :full-bytes)
                       :spill (getf env :spill)
                       :edit (getf env :edit))))
         (if call :dirty :quiet)))
      ((:turn-finished)
       ;; FEED THE METER. It was defined, exported and called from nowhere, so the
       ;; header showed no cost at all while the reference sat there saying
       ;; `$0.0768` — dead code that looked like a feature, which is the same
       ;; shape as the four frames P2 found.
       (note-turn-cost (getf env :usage))
       (let ((turn (session-turn session)))
         (when turn
           ;; *"A progress frame is true only while it is happening"*
           ;; (view.rs:254-256). Nothing cleared it, so a finished turn kept
           ;; drawing the prefill bar of the prompt it had already answered —
           ;; measured, `:progress` still held `(:TOTAL 10 :CACHE 2 …)` after
           ;; `turn_finished`. All three terminal arms clear it, on both sides
           ;; (app.rs:2565, 2596, 2619; view.rs:572, 588, 608).
           (setf (getf turn :progress) nil)
           (setf (getf turn :state)
                 (list :state "finished"
                       :finish-reason (getf env :finish-reason)
                       :usage (getf env :usage) :timings (getf env :timings))))
         :dirty))
      ((:turn-interrupted)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :progress) nil)   ; terminal, as above
           (setf (getf turn :state)
                 (list :state "interrupted" :reason (getf env :reason)
                       :partial-kept (getf env :partial-kept))))
         :dirty))
      ((:turn-failed)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :progress) nil)   ; terminal, as above
           (setf (getf turn :state)
                 (list :state "failed" :error (getf env :error)
                       :partial-kept (getf env :partial-kept))))
         :dirty))
      ((:transcript-appended)
       ;; THE ROWS THIS TURN HAS PUBLISHED, in order. The field was initialised
       ;; at `turn_started` and written by nothing, so it was dead: `view.rs:246-253`
       ;; says what it is for — *"a head shows a running turn from `text`/`reasoning`
       ;; and a finished one from the transcript, and it needs to know which rows
       ;; are the finished form or it renders the answer twice"* (app.rs:2650-2651).
       ;; Appended at the tail, because the order is the fact.
       (let ((turn (session-turn session)))
         (when (and turn (getf env :item-id))
           (setf (getf turn :appended)
                 (append (getf turn :appended) (list (getf env :item-id))))))
       (push-item session (list :item-id (getf env :item-id)
                                :kind (getf env :kind)
                                :ledger-head (getf env :ledger-head)
                                :ts (getf env :ts)
                                :item nil))
       :dirty)
      ((:transcript-content)
       (let ((body (getf env :item)))
         (fill-item session (getf env :item-id) body)
         ;; THE HANDOVER. The row now exists, so the facts staged against its
         ;; call id move to the row's ITEM id — which is unique, where the call
         ;; id is round-positional and about to be reused.
         (when (and body (string= (getf body :type) "tool_result"))
           (%adopt-call-facts (getf env :item-id) (getf body :call-id))
           ;; and note it, so the assistant row above stops drawing a proposal
           ;; for a call whose result is now on the screen
           (note-answered-call (getf body :call-id)))
         ;; an Assistant row ends a round, so the call ids in the staging table
         ;; must not survive into the next one
         (when (and body (string= (getf body :type) "assistant"))
           (note-assistant-targets body)
           (%round-boundary)))
       :dirty)
      ((:decision-requested)
       ;; A fresh ask is PUSHED, so `%open-decision`'s `first` is the newest —
       ;; which is what "one list on the screen at a time" needs. There used to be
       ;; an `endp-open` call here that did nothing while its docstring claimed to
       ;; close the others' cursor state; it was removed rather than left, because
       ;; the cursor is HEAD state and a function in this file could never have
       ;; touched it. The head resets it now, in `%handle-frame`.
       ;;
       ;; **THE SAME ASK DOES NOT JOIN THE LIST TWICE.** A reconnect replays from
       ;; the read mark, so a `decision_requested` this head already drew arrives
       ;; again — and without the line below the list grew a second, third, tenth
       ;; identical entry. Measured on the live head: two deliveries of one
       ;; `req_id` left `open` at 2, three left it at 3, while `%open-decision`
       ;; kept handing back a row that answered for the same question over and
       ;; over. The reference does this in one line, ahead of its own push
       ;; (app.rs:2596): `self.open.retain(|d| d.req_id != req_id)`. A `req_id`
       ;; names one question for its whole life, so a redelivery REPLACES the
       ;; entry rather than appending a twin.
       (setf (session-open-decisions session)
             (remove (getf env :req-id) (session-open-decisions session)
                     :key (lambda (d) (getf d :req-id)) :test #'string=))
       (push (list :req-id (getf env :req-id)
                   :kind (getf env :kind)
                   :call-id (getf env :call-id)
                   :summary (getf env :summary)
                   :target (getf env :target)
                   :detail (getf env :detail)
                   :options (getf env :options)
                   :choices (getf env :choices)
                   :because (getf env :because)
                   :advice (getf env :advice)
                   :deadline (getf env :deadline)
                   :on-timeout (getf env :on-timeout)
                   :asked-ts (getf env :ts))
             (session-open-decisions session))
       :dirty)
      ((:decision-answered)
       ;; the settled decision is worth keeping on the ROW its call produced, so
       ;; the approval does not leave the screen with the live card
       (let ((req (find (getf env :req-id) (session-open-decisions session)
                        :key (lambda (d) (getf d :req-id)) :test #'string=)))
         (setf (session-open-decisions session)
               (remove req (session-open-decisions session)))
         (when req
           ;; THREE things are read off the open decision before it goes, because
           ;; the answer event carries only the `req_id` (app.rs:2503-2524,
           ;; view.rs:494-516): the summary, the call to put the outcome on, and
           ;; the ORACLE'S ADVICE. The last is the one the answer can never carry
           ;; — its `basis` is the DECIDER's, and under `/supervise` the decider
           ;; is usually the operator — so dropping it here is the one loss
           ;; nothing downstream can recover. `call_id` went the same way, which
           ;; is why the settled record could not be matched to its call.
           (let ((settled (list :req-id (getf env :req-id)
                                :call-id (getf req :call-id)
                                :summary (getf req :summary)
                                :advice (getf req :advice)
                                :outcome (getf env :outcome)
                                :by (getf env :by)
                                :basis (getf env :basis)
                                :late (getf env :late))))
             (push settled (session-settled-decisions session))
             ;; and onto the CALL, so the row that lands later can keep it: the
             ;; approval must not leave the screen with the live card
             (when (getf req :call-id)
               (note-call-decision (getf req :call-id) settled)))))
       :dirty)
      ((:warning)
       ;; **A warning is a DISCLOSURE** (R10). See the note above `note-warning`:
       ;; the record is `session-warnings`, the disclosure is a row filed where the
       ;; envelope arrived, and three codes have a better home than a plain row.
       (let ((w (list :code (getf env :code) :detail (getf env :detail)
                      :ts (getf env :ts))))
         (cond
           ;; 1. **`turn_failed` has a better home: the turn's own terminal state.**
           ;;    The daemon publishes both on purpose — one is state, the other is
           ;;    history (app.rs:3320-3327) — and on a screen they are one sentence
           ;;    twice, three lines apart. So the footer draws it and this counts as
           ;;    FILTERED, not dropped: `:quiet` here becomes `*filtered-total*` in
           ;;    `run-loop`, which is what keeps "I chose not to show this" apart
           ;;    from "nothing happened". It is not added to the record either,
           ;;    because the record is what `/notes` lists and a snapshot filters it
           ;;    out of its own notes for the same reason (app.rs:2527-2534).
           ((equal (getf w :code) "turn_failed") :quiet)
           (t
            ;; 2. **A refused job-output read is answered IN THE PANE THAT ASKED**,
            ;;    which is still open — otherwise it sits at `reading…` for ever,
            ;;    waiting for a window that is not coming. A job can fall out of the
            ;;    exec host's table between the listing and Enter, and the daemon
            ;;    says so with this code (app.rs:2764-2774). The conversation gets
            ;;    the row as well, below: suppressing it would make this head's
            ;;    screen disagree with the log every other head sees — the first
            ;;    shortcut letibot ruled out (`bacf495`).
            (when (and *job-out* (equal (getf w :code) "job_output_refused"))
              (setf (getf *job-out* :loading) nil
                    (getf *job-out* :error) (or (getf w :detail) "")))
            (if
             ;; 3. **A slash LISTING opens a pane; a slash SENTENCE stays a row.**
             ;;    The daemon sends both under one code — `detail` is the command
             ;;    echoed back, then the reply — so the head splits them by the only
             ;;    thing that distinguishes them, which is length (app.rs:3266-3275).
             ;;    A listing that opened a pane is ON a screen, so a second copy in
             ;;    the log would be the same text twice; it does not enter the record
             ;;    either, which is why this branch returns before the push.
             (and (member (getf w :code) '("slash" "slash_refused") :test #'string=)
                  (note-slash-reply (getf w :detail)))
             :dirty
             (progn
               ;; 4. **Everything else is a row**, and everything that is a row is
               ;;    also the record: what `/status` counts and `/notes` lists is
               ;;    this list. `secret_late` lands here, which is a statement about
               ;;    this head's OWN answer to a password request ("nothing was
               ;;    waiting on …"): the card that asked is already gone, so the row
               ;;    is the only place left that can say the password was not used
               ;;    (`wire.md` W14).
               (push w (session-warnings session))
               (note-warning session w)
               :dirty))))))
      ((:denial-raised)
       (push (list :request-id (getf env :request-id)
                   :tool (getf env :tool) :summary (getf env :summary)
                   :baseline (getf env :baseline) :by (getf env :by)
                   :basis (getf env :basis) :tier (getf env :tier)
                   :outcome (getf env :outcome)
                   :repeat-count (getf env :repeat-count)
                   :ts (getf env :ts))
             (session-denials session))
       :dirty)
      ((:head-attached)
       (unless (find (getf env :head-id) (session-heads session)
                     :key (lambda (h) (getf h :head-id)) :test #'string=)
         (push (list :head-id (getf env :head-id) :kind (getf env :kind)
                     :identity (getf env :identity))
               (session-heads session)))
       ;; another head coming or going is loud-only: the count is on /status,
       ;; and nothing on the default screen changes
       (if (verbosity-at-least :loud) :dirty :quiet))
      ((:head-detached)
       (setf (session-heads session)
             (remove (getf env :head-id) (session-heads session)
                     :key (lambda (h) (getf h :head-id)) :test #'string=))
       (if (verbosity-at-least :loud) :dirty :quiet))
      ((:session-renamed)
       (setf (session-title session) (or (getf env :title) ""))
       :dirty)
      ((:todos-updated)
       (setf (session-todos session) (getf env :todos))
       :dirty)
      ((:command-issued)
       ;; TWO HUMANS IN ONE SESSION: seeing who did what is the point, and seeing
       ;; YOURSELF do what you just did is not — our own routine acceptances are
       ;; already covered by `Accepted` (app.rs:2815). The Hello's `head_id` was
       ;; stored and read by nothing, so this head could not tell its own
       ;; commands from anybody else's and announced both.
       (let ((mine (session-head-id session)))
         (cond ((and (stringp mine) (plusp (length mine))
                     (equal mine (getf env :head-id)))
                :quiet)
               (t
                (push (list :head-id (getf env :head-id) :identity (getf env :identity)
                            :command (getf env :command) :note (getf env :note)
                            :ts (getf env :ts))
                      (session-notices session))
                (if (verbosity-at-least :loud) :dirty :quiet)))))
      ((:subagent)
       (push env (session-subagents session))
       :dirty)
      ((:job-settled)
       (push env (session-jobs session))
       :dirty)
      ((:filling)
       ;; **The daemon's own count, and the daemon's own words.** `what` and `unit`
       ;; are its to name — `parts` for an import, `rows` for a carry are not the same
       ;; thing — so they are drawn verbatim: a head that renames the operation is
       ;; naming a cause it inferred, which is the defect this event exists to end.
       ;;
       ;; The four fields are checked rather than assumed, because a head meets this
       ;; event across a version skew (R5) as well as in a test: `unit` reached this
       ;; protocol with the rename, so a daemon that sends `filling` without it is not
       ;; a shape `protocol.rs` produces and the line falls back to the head's
       ;; unnamed form rather than printing `NIL` where a noun goes.
       (note-filling env))
      ((:job-output)
       ;; **The answer to the jobs pane's Enter, folded into the overlay that
       ;; asked and nowhere else.** The whole window is kept — job, from, to,
       ;; produced, dropped, state, lines, next — because the pane draws its own
       ;; header out of the OFFSETS rather than parsing `/job`'s footer sentence
       ;; (app.rs:2169-2205).
       ;;
       ;; Taken only when an overlay is open for THIS job: a head may have closed
       ;; the pane with Esc before the reply landed, and the event is published to
       ;; the session, so a head that never asked sees it too. A window for a job
       ;; nobody is looking at is nothing to keep — and keeping it would be the
       ;; stale window `scrub::is_interactive` exists to prevent.
       (cond
         ((and *job-out* (equal (getf *job-out* :job) (getf env :job)))
          (setf (getf *job-out* :state) (or (getf env :state) "")
                (getf *job-out* :from) (or (getf env :from) 0)
                (getf *job-out* :to) (or (getf env :to) 0)
                (getf *job-out* :produced) (or (getf env :produced) 0)
                (getf *job-out* :dropped) (or (getf env :dropped) 0)
                (getf *job-out* :lines) (getf env :lines)
                (getf *job-out* :next) (getf env :next)
                (getf *job-out* :loading) nil
                (getf *job-out* :error) nil)
          ;; A window lands at its TAIL: a fresh page, or a re-read of a running
          ;; job, should show what it has just written. `:back` is left alone, so
          ;; ← still walks the pages the reader came through.
          (reset-pane-scroll)
          :dirty)
         (t :quiet)))
      ;; `screen_requested`, `secret_requested` and `secret_settled` are answered by
      ;; the head loop, which owns the last frame and the input focus. Everything
      ;; else that reaches here is a tag this head does not know — a daemon one
      ;; version ahead, by construction — and it is SAID and COUNTED rather than
      ;; answered `:quiet` under a comment that named the three events it meant.
      (t
       (if (member name +events-not-folded-here+)
           :quiet
           ;; **The line it ARRIVED as, not a re-encoding of the plist.** The reader
           ;; attaches `:wire-line` to every frame it decodes; `encode-frame` would
           ;; produce a line that is not what the daemon sent — and would nest this
           ;; frame's own `:wire-line` inside it, which the first run of this did and
           ;; rendered as a line inside a line. `encode-frame` stays as the fallback
           ;; for the paths that build an envelope themselves: a replay from a
           ;; fixture, and a test.
           (note-unreadable session
                            (format nil "unknown event ~s" (or (getf env :event) "?"))
                            (or (getf env :wire-line) (encode-frame env))))))))

(defun appendf-text (turn slot text)
  (setf (getf turn slot) (concatenate 'string (getf turn slot) text)))

;;; `endp-open` used to live here: a function whose docstring said *"a new decision
;;; closes the others' cursor state … this keeps the head honest if it ever does"*
;;; and whose whole body was `(declare (ignore open-decisions))`. It could not have
;;; done what it claimed — the cursor is `head-decision-sel`, HEAD state, and
;;; nothing in this file can reach a head slot — so the head did not reset its
;;; cursor on a new ask, and a typed line that named no option was answered at
;;; whichever row the last decision left behind. Removed rather than left with a
;;; corrected docstring: a hook that promises what the file cannot deliver is what
;;; let the bug stand for as long as it did.

;;; `ack-frame` used to live here: a second spelling of the loop's own ack,
;;; which read
;;; `session-seq` — the last seq FOLDED — where `run-loop` reads `last-seq`, the
;;; last seq READ. `protocol.rs:717-720` allows exactly one way to obtain an ack
;;; *"so a head cannot ack what it chose to keep"*, and the two disagree on every
;;; batch that ends in a filtered frame. Nothing called it, so nothing was wrong
;;; on the wire; a dead wrong spelling beside a live right one is a trap for
;;; whoever reaches for the one with the better name. Deleted, not fixed: the
;;; loop's own ack, built from `last-seq`, is the only one.

;;; ---------------------------------------------------------- rendering ;;;

(defun item-display-text (item)
  "The text an item renders as, before wrapping. A row whose content never
arrived renders as a placeholder, honestly (view.rs on SnapshotItem.item)."
  (let ((body (item-body item)))
    (if (null body)
        (format nil "[~a — content not loaded]" (item-kind item))
        (case (intern (string-upcase (getf body :type)) :keyword)
          ((:system) (getf body :text))
          ;; parts joined with a SPACE, and a part that is not text says what it
          ;; is — `app.rs:8489-8497`. Joined with nothing, two parts ran into one
          ;; word, and an image or a file attachment was invisible: the operator
          ;; sent something and the row showed nothing of it.
          ((:user) (format nil "~{~a~^ ~}"
                           (mapcar (lambda (p)
                                     (switch ((or (getf p :kind) "text") :test #'string=)
                                       ("image" (format nil "[image ~a]" (or (getf p :media-type) "")))
                                       ("file_ref" (format nil "[file ~a]" (or (getf p :path) "")))
                                       (t (or (getf p :text) ""))))
                                   (getf body :parts))))
          ((:reasoning) (getf body :text))
          ((:assistant) (getf body :text))
          ((:tool_result)
           (format nil "~a ~a → ~a" (getf body :name) (getf body :call-id)
                   (outcome-name (getf body :outcome))))
          ((:segment_mark) "")          ; zero-width by design (lib.rs:55)
          ;; a row this head filed itself — see `note-unreadable`
          ((:note) (getf body :text))
          (t "")))))

(defun outcome-name (outcome)
  "ToolOutcome and DecisionOutcome are both tagged :outcome on the wire with
snake_case names; yason hands us the name as a string."
  (typecase outcome
    (cons (or (getf outcome :outcome) "ok"))
    (keyword (string-downcase (symbol-name outcome)))
    (t "ok")))
