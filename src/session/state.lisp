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

(defvar *turn-last* nil
  "The LAST turn this head watched finish, as `(:ms DURATION :at EPOCH-MS)`, or NIL.

**What the row above the composer says once the turn is over:** *Responded in 12.4s at 21:07*.
The operator's spec, verbatim — *\"either Responding spinner we have now or 'Responded in <full turn
time> at <end-timestamp> as hh:mm'\"* — and BOTH halves are about the same row, which is why they
are two states of one piece of state and not two features.

**The DURATION is the whole turn**, `now - *turn-started-ms*` at `turn_finished`, not the last
round's: the row answers *how long did that take me*, and the model's last round is only the tail
of it. That is also why it cannot be reconstructed later — nothing on the wire carries it, so a turn
nobody watched has no duration and the row says nothing rather than a zero.

**`at` is the END timestamp, on the wall clock**, which is the other thing the wire does not carry:
the daemon's frames have a `ts` for ROWS and none for a turn's end.

Cleared when a new turn starts, so the row can never show a report about the turn BEFORE the one
that is running — the two states are mutually exclusive by construction rather than by a test.")

(defun note-turn-finished (state)
  "Record what the row needs about a turn that just ended — see `*turn-last*`.

STATE is the turn's terminal state name: only `finished` is a *responding*, so an interrupted or
failed turn does not report one. It CLEARS the slot instead, which is the honest thing to do with a
row that is always on the screen: the turn that just ended did not answer, and the previous turn's
`Responded in …` would be a claim about a turn that is no longer the last one.

**AND A TURN'S END IS A FOLD'S END, which is why `reset-compaction` is called from HERE.** Every
terminal arm of `apply-event` comes through this function — finished, interrupted, failed — and so
does `turn_started`, and the fold this head draws is one the TURN ran: a compaction that begins
inside a turn cannot outlive it. The old docstring on `compaction-active-p` claimed the state was
*\"cleared by the fold's own end — the `compacted` warning, or a turn finishing\"* and MEASURED, that
was false twice: `reset-compaction` had no caller anywhere in the tree, and the only clear was a
progress tick whose `half` is not positive. The operator's report is the consequence — *\"compacting
the conversation still spins\"* — with a fold whose ticks stopped mid-turn and the spinner up for the
rest of the head's life."
  (reset-compaction)
  (setf *turn-last*
        (when (and (string= (or state "") "finished") *turn-started-ms*)
          (list :ms (max 0 (- (internal-real-time-ms) *turn-started-ms*))
                :at (unix-now-ms)))))

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

(defun job-out-pages (&optional (view *job-out*))
  "Which page keys this overlay can act on, as `(:next BOOL :back BOOL)` — or NIL with no
overlay open.

**One answer, because TWO surfaces name these keys and only one of them was careful.** The
pane's own footer computes them from the window it is drawing; the composer's hint bar names
them for the MODE, and a mode is not a job — so on a job that has written nothing the footer
correctly said `arrows scroll · Esc to jobs` while the bottom row still promised `→ next page ·
← back`. Measured on the operator's own scenario, a build whose output went to a file so that
`produced` is 0 and `next` is NIL: the pane told the truth and the row under it did not.

R40's rule is why it matters rather than being tidiness — *a chord is named only where it
acts* — and it is the same defect `peek-row-count` records one pane over: a surface
advertising a key that moves nothing."
  (when view
    (list :next (and (getf view :next) t)
          :back (and (getf view :back) t))))

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

(defun %decision-clock-rule (d)
  "D with its `:deadline` moved onto THIS head's clock, the wire's value kept.

**The ONE place a decision's deadline is converted**, and the reason it is a named
function is R16's lesson one field over: a rule applied at two call sites is a rule
that drifts, and the two call sites here — a live `decision_requested` and the
`open_decisions` inside a snapshot — are exactly the pair that drifts silently,
because each is right on its own and only the screen shows the difference.

**`access` rides through here for the same reason**, and it is §11.7's field: the
card draws a sentence about what the tool DECLARES only when `access` is `exec`, so a
snapshot ask that reached the card without its `access` would draw a card that says
nothing about the very thing the sentence exists to explain — and a live one would.
One carrier, two folds, so the two cannot disagree about what a card is allowed to
say.

**R18, MEASURED LIVE 2026-09-22, on the operator's own card.** The wire says *Unix
millis* (`event.rs:573`) and `internal-real-time-ms` is a counter since this process
started, so a deadline that reaches the RENDERER unconverted is an instant tens of
thousands of years away. The live arm converted and the snapshot arm did not, so a
head that attached to a session with an ask already open drew

    expires in 29833973 min · if nobody answers, nothing runs

for a card whose real remaining time was 229308 ms — `3m49s left`. Read off the
live head, not inferred: `:DEADLINE 1790038382308` (a Unix instant), `:DEADLINE-WIRE
NIL` (never converted, so the key that marks a converted one was absent), against
`unix-now 1790038153000`. **56 years of countdown on the one surface where the
operator is being asked to decide**, and a lie of the class this head keeps finding:
a rendering fault dressed as a measurement.

It was found by looking at a card rather than by a test, which is why it is written
out here: the suite had a live-path conversion and a secret-card conversion and
nothing that attached AFTER the ask."
  (list* :deadline (wire-deadline->monotonic (getf d :deadline))
         (list* :deadline-wire (getf d :deadline)
                (list* :access (getf d :access) d))))

(defun %decisions-in-head-time (decisions)
  "Every decision in DECISIONS through `%decision-clock-rule`. A snapshot's list.

NIL in, NIL out — a session with no open ask has no clock to move, and
`(mapcar #'… nil)` would be the same list and a needless call."
  (when decisions (mapcar #'%decision-clock-rule decisions)))

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
walking under the new session's composer.

**The subagent clear is now the FALLBACK and not the whole story**: the wire's
`Snapshot` carries the session's children (`subagents`, `#[serde(default)]`), and
`ingest-snapshot` REPLACES the rows with them a few lines after this clear — so a
switch into a child leaves the clear standing (its snapshot has no children) and
a switch BACK to the parent restores the tree whole, which is what the clear
alone could never do. See `%subagent-view->event`."
  (setf (session-subagents session) nil
        (session-jobs session) nil
        (session-denials session) nil
        (session-notices session) nil)
  (setf *turn-started-ms* nil
        ;; **and the report about the turn we just left.** It is a measurement of the OLD session's
        ;; turn, and the row it is drawn on is still on the screen — a `/switch` that carried it
        ;; would put *Responded in 12.4s at 21:07* under a conversation that never asked anything.
        *turn-last* nil)
  ;; the staged call facts are keyed by a call id that only existed over there
  (%round-boundary))

(defvar *snapshotted-sessions* nil
  "The session ids this head has ingested a snapshot for, this process.

**R19 part 1 hangs on this list and nothing else.** A snapshot is the ATTACH of a
session the head has not seen yet, and the RESYNC of one it has — and the difference is
the whole of *\"history arrives as news\"*. Four notes — `daemon_stopping`, `compacted`,
two `auto_compact` — folded correctly to three red lines each, at the top of a session
that had just started, over a conversation they did not precede: a fresh head planted
its snapshot's warnings at position 0 because everything in a snapshot is history and
none of it is anchored.

A `defvar` and not a head slot, and **not cleared by anything**: it is a fact about this
process, so a `/switch` away and back, or a reconnect, keeps its meaning. Bound by
`with-replay-globals`, because a replay must answer the same bytes twice.")

(defun session-snapshotted-p (id)
  "Has this head ingested a snapshot for ID in this process?"
  (and (member id *snapshotted-sessions* :test #'string=) t))

(defun note-snapshotted (id)
  "Record that ID has had a snapshot. Returns T when it was NEW — an attach."
  (if (session-snapshotted-p id)
      nil
      (progn (push id *snapshotted-sessions*) t)))

(defun %subagent-view->event (view)
  "One `SubagentView` — a snapshot's `subagents` row — to the ENVELOPE shape the
`:subagent` arm of `apply-event` leaves in `session-subagents`.

**The whole point of the mapping is that the fold cannot tell it from the live
thing** (`subagent-rows` runs over both), so every field keeps the name the live
event uses: `subagent-id` (the event's own name for the child's session, because
`session-id` on a live envelope is the PARENT's), `state`, `role`, `ts`.

**The title comes from `task` and not from `prompt`, which is the event's own
rule** (event.rs, `Subagent::prompt`): `prompt` is the subtask's first line on
the opening states and the child's ANSWER's first line on the finish — a field
with two meanings, whose meaning depends on the state — while `task` is the
subtask in full, the same string on every state. The view takes its fields from
the LAST event verbatim, so a finished child's `prompt` IS the answer line; a
row titled from it would be titled by its own answer. `task` empty (a daemon
older than the field) falls back to `prompt`, which is the pre-field behaviour
the event's own `#[serde(default)]` documents.

**`:answer` is present even when NIL**, and that is the distinction the fold
reads: a live envelope from an older daemon has no `answer` KEY at all (the
field is `#[serde(default)]` on the wire), and for those the finish's `prompt`
still IS the answer — so presence, not truth, is what separates *the daemon said
there is none* from *the daemon cannot say*."
  (list :subagent-id (or (getf view :session-id) "")
        :state (or (getf view :state) "")
        :prompt (let ((task (or (getf view :task) "")))
                  (if (plusp (length task)) task (or (getf view :prompt) "")))
        :role (or (getf view :role) "")
        :task (or (getf view :task) "")
        :model (or (getf view :model) "")
        :answer (getf view :answer)
        :ts (or (getf view :ts) 0)))

(defun ingest-snapshot (session snapshot &key attach)
  "Replace state with SNAPSHOT's. Resync is a normal outcome, never an error
— this is also the Resync-frame path.

**ATTACH says this snapshot is how the head MET the session**, and the caller knows
because `ingest-hello` asks `note-snapshotted` before calling this (R19 part 1). On an
attach a snapshot's warnings are HISTORY: they are stored, listed by `/notes` and
counted by `/status`, and **not filed as rows**. A head that has just attached has shown
nothing, so filing them replays hours of announcements as though they had just happened,
above a conversation they did not precede.

**Default NIL, and that is load-bearing.** A resync replaces a transcript this head was
already showing, so R10's rule stands there unchanged: the rows come back, and the
retired set decides which of them are visible. A caller that does not know whether this
is an attach must pass NIL — the conservative reading is *the head has been here*, and
the other one silently loses a wall somebody was meant to read.

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
        (session-open-decisions session) (%decisions-in-head-time
                                           (getf snapshot :open-decisions))
        (session-settled-decisions session) (getf snapshot :settled-decisions)
        ;; **REVERSED into this slot's own order.** A snapshot's warnings are the
        ;; daemon's `Vec` pushed in arrival order — oldest first (`view.rs:660`) —
        ;; while a live warning is PUSHED here, so the slot is newest-first. The two
        ;; orders have to agree or `/notes` numbers the list backwards after a resync,
        ;; and `warning-order` would then hand `/notes dismiss N` the wrong warning.
        (session-warnings session) (reverse (getf snapshot :warnings))
        (session-heads session) (getf snapshot :heads)
        (session-items session) (%items-vector (getf snapshot :items)))
  ;; **THE PARENT'S CHILDREN, CARRIED BY THE SNAPSHOT — the fix for the count that
  ;; disappeared on a switch back.** The wire's `Snapshot` grows a `subagents` field
  ;; (`#[serde(default)]`, so a daemon older than it omits it and this `member` is the
  ;; whole of the skew story): one folded row per child, the SAME words the head that
  ;; watched the spawn had — state, the task, the model, the answer — instead of the one
  ;; bit (`running`) the session list can supply, which is *a turn is generating in that
  ;; session at this instant* and reads `false` for a child parked between rounds while
  ;; being perfectly alive.
  ;;
  ;; REPLACED and not appended, which is `%clear-session-scoped`'s own rule taken one
  ;; step further: a row in this slot belongs to the session the event arrived in, and
  ;; the fold cannot tell such a row from a child of THIS session the snapshot has not
  ;; listed — so the snapshot's list is the session's children, whole. An empty list is
  ;; the same statement as an absent one (*this daemon told me about no children*) and
  ;; both leave the clear standing; a NON-empty one is the parent's tree back, on the
  ;; switch back and on the resync alike.
  (when (member :subagents snapshot)
    (setf (session-subagents session)
          (reverse (mapcar #'%subagent-view->event (getf snapshot :subagents)))))
  ;; ONE PASS over the items, for the display targets a head that attached AFTER
  ;; a turn has no live proposals to learn from: the assistant row is the only
  ;; place that call is described, and a `ToolResult` row carries no target.
  (note-snapshot-targets (getf snapshot :items))
  (note-snapshot-answered (getf snapshot :items))
  ;; and the carry, which is what a snapshot with bodiless rows IS: see `note-carry`
  (note-carry (getf snapshot :items))
  ;; **A snapshot's warnings: planted on a RESYNC, not on an ATTACH (R19 part 1).**
  ;;
  ;; On a resync the rows went with the transcript the snapshot replaced, and the
  ;; retired set — which a snapshot does NOT carry and must not — decides which of them
  ;; come back visible. This is the path that made the reference's wall come back at
  ;; position 0 above the whole conversation, and keying the set outside the transcript
  ;; is the answer: a retired warning is filed HIDDEN here, so a resync and a reattach
  ;; replant the wall retired.
  ;;
  ;; **On an attach none of that is asked.** The head has just started, or has just
  ;; switched to a conversation it has never shown: every warning in this snapshot
  ;; happened before it arrived, so there is nothing for a row to be anchored TO and no
  ;; reader who is owed the news. They stay in `session-warnings`, which is what `/notes`
  ;; lists and `/status` counts — *the log keeps them; the head does not have to open
  ;; with them* — and the first LIVE warning after the attach is filed normally.
  ;;
  ;; `turn_failed` is filtered on both paths, which the reference needs too and for the
  ;; same reason: a snapshot that put it back would replant the one sentence the screen
  ;; already says in the turn's own footer (app.rs:2527-2534), and the two paths have to
  ;; agree about every filter (`bacf495`).
  (unless attach
    (dolist (w (session-warnings session))
      (unless (equal (getf w :code) "turn_failed")
        ;; **AND A COMPACTION IS A TOOL CALL ON THIS PATH TOO** (R24). A snapshot's
        ;; warnings are the daemon's own log, so they carry the compaction codes even
        ;; though the live path never stores them — and a resync has to land in the
        ;; same shape as the turn did, or the same fact has two renderings on one
        ;; screen depending on when it arrived.
        ;;
        ;; It is filed as a row and REMOVED from the list, because `session-warnings`
        ;; is what `/notes` lists and `/status` counts: a compaction that stayed in it
        ;; would be a row that is also a note, which is the thing this requirement is
        ;; getting rid of. `compaction-row-p` failing (a detail this head cannot read)
        ;; leaves it exactly where it was, filed as a note.
        (if (note-compaction session w)
            (setf (session-warnings session)
                  (remove w (session-warnings session)))
            (note-warning session w)))))
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
        ;; **NO FILTER: A CHILD IS A SESSION.** This removed them, with the reference's own reason
        ;; (*they are children of this one, shown in the subagent tree and reached by `/switch id`*) —
        ;; and the operator's correction is that the reaching part was already true and the hiding was
        ;; the bug: *"subagent session is more like you driving others via tmux"*. The list is stored as
        ;; the daemon sent it and the PICKER decides how it draws — under its parent, unnumbered, with
        ;; `%session-position` counting the numbered rows — so the quiet is the view's business and not
        ;; the state's.
        (getf hello :sessions)
        (session-wiring session) (getf hello :wiring))
  (if (getf hello :snapshot)
      ;; **A `Hello` is the ATTACH frame, so the first one for a session is the
      ;; head meeting it** (R19 part 1). Ask BEFORE ingesting, because the ingest is
      ;; what records the id. Everything after the first is a reattach — a reconnect,
      ;; or a `/switch` back — where R10's replant applies.
      (ingest-snapshot session (getf hello :snapshot)
                       :attach (note-snapshotted
                                (or (getf (getf hello :snapshot) :session-id) "")))
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

(defun turn-running-p (head)
  "Is a turn running on HEAD's session?

**One predicate, because four callers open-coded this string comparison and a fifth was about to.**
They are the same question — *is the model working right now* — asked by the header, the marker's
live work, the composer's edge and the take-back, and the take-back is where the copy finally cost
something: `↑` may only withdraw while a turn runs, because the daemon honours a take-back at its
steering poll and IGNORES one that reaches the worker (`sessions.rs:1600`).

A turn that has finished keeps its state plist for the header's sake — `:state finished` — so
`turn` being non-NIL says nothing about whether anything is running, which is the distinction every
one of those four callers needed and each of them spelled out separately."
  (let ((turn (session-turn (head-session head))))
    (and turn (turn-busy-p turn))))

(defun turn-busy-p (turn)
  "Is this turn still WORKING — generating, or waiting on a call it made?

**Not the turn's state name, and that was measured as a defect on the operator's own screen:**
*\"our 'responded, responding' is off — while your turn not finished you are 'Responding' regardless
of the tool calls or thinking or ongoing replies.\"*

`turn-state-name` is `\"running\"` only while the model is GENERATING, and the daemon sets it to
`\"finished\"` when the round's generation ends — which is exactly when a tool call starts. So the whole
time a command was executing, and every second of the reasoning and the reply still to come, the row
read `Responded in 12.4s at 21:07`: the past tense for work in progress.

MEASURED while fixing the running-call clock, and the evidence was already in hand:

    (:turn-state finished
     :calls ((call_00_2BEv4qYe4aW9V9hRz4400585 running)))

A turn is busy if it is generating (`\"running\"`) **or** if any of its calls has not finished. Those
are the two ways a turn can still have work in it, and together they are what the reader means by
*Responding*: the command is still going, the thinking is still coming, the reply has not landed."
  (or (string= (or (turn-state-name turn) "") "running")
      (some (lambda (c) (let ((st (getf c :state)))
                          (and st (not (string= (or (getf st :state) "") "finished")))))
            (getf turn :calls))))

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

