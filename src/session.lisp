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
  (open-decisions nil :type list)        ; OpenDecision plists, oldest first
  (settled-decisions nil :type list)
  (warnings nil :type list)
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
        (session-warnings session) (getf snapshot :warnings)
        (session-heads session) (getf snapshot :heads)
        (session-items session) (%items-vector (getf snapshot :items)))
  ;; ONE PASS over the items, for the display targets a head that attached AFTER
  ;; a turn has no live proposals to learn from: the assistant row is the only
  ;; place that call is described, and a `ToolResult` row carries no target.
  (note-snapshot-targets (getf snapshot :items))
  (note-snapshot-answered (getf snapshot :items))
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
       (endp-open (session-open-decisions session))
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
       ;; **A refused job-output read is answered IN THE PANE THAT ASKED**, which
       ;; is still open — otherwise it sits at `reading…` for ever, waiting for a
       ;; window that is not coming. A job can fall out of the exec host's table
       ;; between the listing and Enter, and the daemon says so with this code
       ;; (app.rs:2764-2774). The conversation gets the note as well: the warning
       ;; is still pushed below, because suppressing it here would make this head's
       ;; screen disagree with the log every other head sees — which is the first
       ;; shortcut letibot ruled out (`bacf495`).
       (when (and *job-out* (equal (getf env :code) "job_output_refused"))
         (setf (getf *job-out* :loading) nil
               (getf *job-out* :error) (or (getf env :detail) "")))
       (push (list :code (getf env :code) :detail (getf env :detail)
                   :ts (getf env :ts))
             (session-warnings session))
       :dirty)
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
      ;; screen_requested / secret_requested are answered by the head loop,
      ;; which owns the last frame and the input focus; explain is untyped
      ;; until W14 says what it is (event.rs:698)
      (t :quiet))))

(defun appendf-text (turn slot text)
  (setf (getf turn slot) (concatenate 'string (getf turn slot) text)))

(defun endp-open (open-decisions)
  "One list on the screen at a time (agents.md): a new decision closes the
others' cursor state. The daemon never leaves two genuinely open; this keeps
the head honest if it ever does."
  (declare (ignore open-decisions)))

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
          (t "")))))

(defun outcome-name (outcome)
  "ToolOutcome and DecisionOutcome are both tagged :outcome on the wire with
snake_case names; yason hands us the name as a string."
  (typecase outcome
    (cons (or (getf outcome :outcome) "ok"))
    (keyword (string-downcase (symbol-name outcome)))
    (t "ok")))
