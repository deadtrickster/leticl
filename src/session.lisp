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
`Responded in …` would be a claim about a turn that is no longer the last one."
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
walking under the new session's composer."
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
        ;; SUBAGENTS ARE NOT SESSIONS a picker lists: they are children of this
        ;; one, shown in the subagent tree and reached by `/switch id`. The
        ;; reference filters them before storing, on both frames that carry the
        ;; list (app.rs:1668-1671, 1732-1735).
        (remove-if (lambda (b) (getf b :parent-session-id)) (getf hello :sessions))
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
  "Is the `:reading` rung on? — the conversation, and nothing the head did to produce it."
  (eq *verbosity* :reading))

(defun next-verbosity (v)
  "The next rung UP the ladder, wrapping: `reading` → `terse` → `normal` → `loud` → `reading`.

**NO LONGER A USER-FACING CYCLE, and that is R38's ruling** (`.verbosity` opens a card now):
*a setting with more than two values is chosen from a card that shows all of them; only a true
toggle may cycle.* What survives is the ORDER — the ring is how `+verbosity-ladder+` is stated, and
this function is the ring written down once so the two cannot disagree about which rung is next."
  (ecase v (:reading :terse) (:terse :normal) (:normal :loud) (:loud :reading)))

(defparameter +verbosity-ladder+ '(:reading :terse :normal :loud)
  "The rungs, least-drawn first. One list, read by `next-verbosity`, `verbosity-at-least`
and the status row, so the order cannot be written down twice.")

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

(defun %fnv1a-64 (string)
  "FNV-1a, 64-bit, over STRING's UTF-8 BYTES — letibot's own hash, byte for byte.

**Hand-rolled for the same reason letibot's is**: `sxhash` is not stable across an SBCL
version, and a key that changes when the head is rebuilt would resurrect every note the
operator had retired, which is the defect the whole identity exists to prevent.

The offset basis and the prime are the published ones (`offset_basis =
0xcbf29ce484222325`, `prime = 0x100000001b3`), and the arithmetic is masked to 64 bits after
every multiply because SBCL has bignums and Rust wraps — an unmasked product would keep
growing and the two heads would disagree on the first string long enough to matter.

Over UTF-8 bytes because that is what `s.as_bytes()` is on the other side: a detail is a
sentence, sentences contain `→` and `—`, and hashing CHARACTERS here would give a different
key from hashing their encoding."
  (let ((h #xcbf29ce484222325))
    (loop for byte across (sb-ext:string-to-octets string :external-format :utf-8)
          do (setf h (ldb (byte 64 0) (* (logxor h byte) #x100000001b3))))
    h))

(defun %fnv1a-hex (string)
  "The 16 lowercase hex digits letibot writes in a note key (`{:016x}`)."
  (format nil "~16,'0x" (%fnv1a-64 string)))

(defun warning-identity (w)
  "The name a warning keeps across a resync, a reattach **and a restart — in a file two
heads share.**

**Built from the warning's own facts and nothing about where it is on the screen**, and it
is `w|{code}|{ts}|{fnv1a(detail)}` — **letibot's format, character for character**
(`app.rs`, `note_key`: `format!(\"w|{}|{}|{:016x}\", w.code, w.ts, fnv1a(&w.detail))`).
`ts` is the log's clock for the envelope that carried it, which is what tells one
announcement from a redelivery of the same one.

**This head used to use `code|ts|escaped-detail`, and the difference was not cosmetic.**
The retired set now lives in ONE file for every head on the box, and both heads compare
keys against that file by string equality — so two formats in one file is a file both
heads write and neither can read. The escaping machinery went with it: a hash has no comma
and no newline in it, which is what the escaping was for, and the code and clock are the
daemon's own identifiers.

**The `w|` prefix is a KIND, not decoration.** letibot writes `n|…` for a 'refusal nobody
made' note and `d|{req_id}` for a settled decision; this head files only warnings, so it
produces only `w|…` — and it KEEPS the others on the way through, because a save merges
the file and a key this head did not write is another head's dismissal. See
`merge-retired-keys`."
  (format nil "w|~a|~a|~a"
          (or (getf w :code) "") (or (getf w :ts) 0)
          (%fnv1a-hex (or (getf w :detail) ""))))

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

(defparameter +failure-warnings+
  '("auto_compact_failed" "auto_compact_skipped" "auto_compact_no_progress"
    "context_wall" "gate" "gate_timeout" "turn_failed"
    "job_output_refused" "session_unavailable" "resume_failed"
    "reseat_refused" "reseat_unchecked" "mode_unknown" "mode_set_refused"
    "mode_unpersisted" "length_batch_refused" "length_empty_turn"
    "ledger_chain_mismatch" "row_coverage_gap" "reasoning_stall"
    "repetition_collapse" "ended_in_reasoning" "monitor_wake_not_armed"
    "fabric_refresh_failed" "flowy_not_seated" "frame_capture_failed"
    "transcript_store" "decision_corpus" "title_not_stored"
    "record_item_pairing" "orphan_body" "log_gap" "protocol_skew"
    "unreadable_frame" "slash_refused" "answer_unclaimed"
    "prefix_divergence" "prefix_check_skipped" "secret_late" "sudo"
    "absolute_path" "endpoint" "dated" "data_claim")
  "The FAILURE-register codes this head draws — the other half of the vocabulary.

**The list lived in a test until R29 needed it in the source.** `the-severity-split-is-a-table`
walked it as a literal to assert that each one stays loud; R29's rule one then needed the
SAME set to assert that each one offers a remedy, and two copies of one vocabulary is the
drift this file keeps recording (see `+routine-warnings+` above: twenty codes, one head
classifying and the other not). So the list moved here, both tests read it, and a code
added to one arm cannot miss the other.

**`a_code_from_a_daemon_this_build_has_never_met` is deliberately NOT in it.** That string
is a test's standing example of an UNKNOWN code, and an unknown code must fall through both
tables — it is the fail-safe direction, not a member.

**Every member must also have a `+note-remedies+` entry** (R29 rule one), which
`every-note-code-offers-a-remedy` asserts by walking this list and `+routine-warnings+`
together, so the two facts about a code — how loud it is, and what the reader can do — are
answered in the same place or not at all.")

(defparameter +routine-warnings+
  '("auto_compact" "compacted"
    "reseated" "frame_capture_written" "frame_capture_disabled"
    "mode_set" "mode_set_next_session_only" "mode_session_only"
    "model_endpoint_retry" "interrupt_idle" "promote_idle"
    "daemon_stopping" "resume_note" "open_note"
    "reattached" "slash"
    "imported" "import_scrap" "imported_summary"
    "steering_urgent" "cache_reuse_shortfall" "test"
    ;; **R24 part two's own report, and it came from the OTHER tree.** The guard
    ;; (`a-routine-warning-code-is-one-letibot-calls-routine`) caught this head missing it the
    ;; day letibot landed `/run`: their row reads *a sentence about something the operator
    ;; asked for that worked … the opposite of a fault*. Without the entry this head's
    ;; fail-safe drew it RED — an alarm for the door working as designed, which is R19 itself
    ;; and exactly the direction the guard exists for.
    "operator_call_ran"
    ;; **AGAIN FROM THE OTHER TREE, AND THE SAME GUARD CAUGHT IT.** letibot's `e54b48a` — *a
    ;; provider that is slow says so, instead of looking like one that is gone* — added
    ;; `model_slow_first_byte`, because DeepSeek was measured at 12.4 s to first byte on a
    ;; streaming completion while `GET /models` answered in 0.28 s. The fact is that the provider
    ;; is SLOW, which is housekeeping rather than a fault — and without this entry the fail-safe
    ;; here drew it RED, which is the direction that turns *wait a moment* into an alarm. That is
    ;; R19 itself, and the exact direction this list exists to prevent.
    "model_slow_first_byte"
    ;; **AND THE COMPACTION'S OWN TWO LINES** (letibot `f273300`). `compact_half` is `Class::Routine`
    ;; in its table: a fold that is running is housekeeping, and *"a silent wait is what a reader calls
    ;; a failure"*. Without this entry the fail-safe here drew it RED — an alarm for the minutes the
    ;; operator is already waiting through, at the moment the session is largest and the model slowest.
    "compact_half")
  "The warning codes whose fact is ROUTINE — drawn faint with a middot, not red with a bang.

**R19 part 2, and this list is now letibot's rather than mine.** Both heads render these
codes, so a register either head can decide alone is a register the two disagree about on
screen. letibot put its whole table in the crate the codes are defined in
(`crates/sessionlog/src/warning.rs`, `TABLE`), with a reason per row and a guard that
fails until every `code: …` literal in its tree has one — and its own module doc makes the
argument §11.6 makes about `JobState::word`: *the codes are the log's vocabulary … so a
split that only one head knew would have to be copied by the other and the two copies
would drift.*

**And it drifted, which is why this is a measurement rather than an agreement in
principle.** Measured 2026-09-22 by extracting letibot's `TABLE` and diffing it against
this list: **both heads called ten codes routine; four codes were classified differently;
and twenty codes one head had classified had no row in the other's list at all** — nine of
those reachable from this head, so an orderly `daemon_stopping` or a compaction's cache
note would have been drawn RED here while letibot drew it dim. Two of the four differences
were mine and were wrong for one reason worth writing down: **I classified the
`auto_compact_*` family by its PREFIX** — housekeeping the daemon does to itself — and two
of its members are housekeeping that did *not* happen (`auto_compact_skipped`,
`auto_compact_no_progress`: the session is at the wall with automatic compaction off, and
the operator has to read that). The rule is about the FACT, not the name.

The third, `model_endpoint_retry`, is letibot's: **the retry IS the handling** — the round
is taken again and the operator can watch it happen — and the failure arrives under its own
code, `turn_failed`, when the retries are spent. Red on the retry is red on a turn that is
still trying.

**The nine gaps are all letibot's too**, and every one of them drew RED here while letibot
drew it dim, for the same fact: `daemon_stopping`, `imported`, `import_scrap`,
`imported_summary`, `mode_session_only`, `mode_set_next_session_only`, `open_note`,
`cache_reuse_shortfall`, `steering_urgent`. Each satisfies the rule's *something that
worked, something you asked for, or by design* — and two are the rule's boundary case: a
*write that did not happen* because the operator asked for it not to, which reads like a
failure and is not. The tenth routine-side gap, `test`, is letibot's testing helper with no
production fact behind it.

**The fourth difference needed a refinement rather than a row, and that is why it is the
interesting one.** `frame_capture_disabled` — a frame was refused and no capture directory was
configured, so the evidence that would identify it was not kept — reads like letibot's own
*\"a caveat that a check did not happen is a failure\"*, the sentence that makes
`reseat_unchecked` and `prefix_check_skipped` failures. It is not that shape, and the clause
that separates them is now part of the rule:

> **A caveat about a check that DID NOT HAPPEN is a failure. A note that a diagnostic was
> switched off — after the check happened and its result is known — is routine.**

Measured rather than argued: `report_capture` returns early unless `capture.is_armed()`
(letibot `engine.rs:1602`), and `arm` is called from exactly three places, all of them
turn-defect paths (`:1363`, `:1386`, `:1407`) — so this warning never fires on a healthy
turn, and the *check* did happen: a frame was refused and the refusal is reported by the
turn's own code. What is absent is the RECORD, and its absence is by configuration.
**letibot's row stands and the rule gains the clause.**

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a constant
here could never be corrected on a running head — and a severity list is exactly the kind
of thing that gets corrected.

**`a-routine-warning-code-is-one-letibot-calls-routine` reads letibot's own table and fails
if this list moves**, which is the §11.5 shape: the copy stays, because a head must render
without the reference tree present, and the GUARD points at the source.")

(defun routine-warning-p (w)
  "Is W's fact routine — housekeeping, or the outcome of the reader's own act?

By code alone. The wire carries `code`, `detail` and `ts` and no severity
(`view.rs:306-310`), so the head is the only layer that can answer this, and it answers
it for the whole code rather than by reading the detail: a sentence-parsing severity
would be a second, silent protocol."
  (and (member (or (getf w :code) "") +routine-warnings+ :test #'string=) t))

(defun warning-glyph (w)
  "The mark a warning is written under: `!` for the failure register, `·` for routine.

**ONE definition, two surfaces** — the row in the conversation and the `/notes` listing
must not spell the same severity two ways, which is what they would do if each picked its
own mark. R19 part 2's whole point is that the register be readable at a glance, and a
listing that said `!` about a note the conversation had just drawn faint would put the
argument back where it started."
  (if (routine-warning-p w) "·" "!"))

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

;;; ------------------------------------------- a compaction is a tool call ;;;
;;;
;;; **R24 part one.** A compaction announces itself as WARNINGS today — `compacted` and
;;; `auto_compact` as routine, `context_wall` as failure — so the most information-dense
;;; event in a long session arrives as the one shape on the screen with NO AFFORDANCES:
;;; it cannot be folded, `ctrl-t` does nothing to it, its numbers are buried in prose,
;;; and it competes for the note band with denials.
;;;
;;; **A tool call already has every affordance this wants** — a headline carrying the
;;; stats, `ctrl-t` for the detail, folding, the payload pager you built, and a row that
;;; scrolls with the conversation instead of stacking above the composer. So a
;;; compaction that was ATTEMPTED is filed as a tool row whose payload is the daemon's
;;; own sentence.
;;;
;;; **Nothing about compaction's behaviour changes, only what it is rendered as** — which
;;; is why this is a fold and two optional fields on a body, and not a new frame.
;;;
;;; **And it collapses R19's wall rather than dismissing it.** Three of the four notes
;;; the operator was met by on restart were `compacted` and `auto_compact`; as rows they
;;; stop being notes at all, and the band goes back to being what R10 says it is — *how a
;;; head shows a fact once*, for facts with nowhere else to live.
;;;
;;; **ATTEMPTED is the line, and it is the whole of the code list.** A code that reports
;;; a compaction somebody TRIED becomes a row. A code that reports one nobody tried stays
;;; a note, because there is nothing to report and the absence IS the fact:
;;; `auto_compact_skipped` (automatic compaction is off for this session) and
;;; `context_wall` (the wall itself — delivered BEFORE any compaction exists, and in the
;;; cases where none will). `context_wall` is ruled separately below.

(defparameter +compaction-row-codes+
  '("compacted" "auto_compact" "auto_compact_no_progress" "auto_compact_failed")
  "The warning codes this head renders as a TOOL ROW rather than as a note.

Each reports a compaction that was attempted: `compacted` and `auto_compact` their
reports, `auto_compact_no_progress` one that ran and did not help,
`auto_compact_failed` one that was tried and did not run.

**`reseated` is deliberately not here.** A re-seat publishes that code AND a
`compacted` whose detail is the token account, so the note carries the tools the model
gained and lost and the row carries the numbers — two facts, two shapes.

**`auto_compact` does double duty** — it is the ANNOUNCEMENT (`N of M tokens resident …
compacting now`) and, after the fork, a second REPORT (`compacted: N tokens resident
now, was M`). One code, two facts, which is why `compaction-facts` reads the SENTENCE
and not the code: the same warning code is a row saying *Compacting* and a row saying
*Compacted*, and only the words tell them apart. Filed as an observation for the
daemon's side rather than fixed here — the daemon naming one thing twice is its
business, and inferring a join between them would be this head inventing a fact.")

(defun %digits-at (text start)
  "TEXT's integer beginning at START, and the index one past it. NIL when none does.

The daemon writes counts with no separators (`format!(\"{}\", u64)`), so a run of digits
is the whole number and there is no locale to guess at."
  (when (and (integerp start) (< -1 start (length text)) (digit-char-p (char text start)))
    (let ((end start))
      (loop while (and (< end (length text)) (digit-char-p (char text end)))
            do (incf end))
      (values (parse-integer text :start start :end end) end))))

(defun %number-after (text marker &optional (from 0))
  "The integer that follows MARKER's first occurrence at or after FROM, across the space.

**The gap is one space in every sentence the daemon writes** — `compacted from 943000` —
and skipping it HERE rather than spelling `\"from \"` into the marker keeps each marker
the phrase a person would quote, and keeps it equal to what stands in the `format!`
strings that the guard test reads, where the placeholder sits immediately after the word.
Measured: without this, `no-progress` read its `:was` as NIL."
  (let ((at (search marker text :start2 (max 0 (or from 0)))))
    (when at
      (let ((i (+ at (length marker))))
        (loop while (and (< i (length text)) (member (char text i) '(#\space #\tab)))
              do (incf i))
        (%digits-at text i)))))

;;; ### `context_wall`, ruled separately, because the ruling differs
;;;
;;; **It stays a note, and it is the only one of the family that does.** The requirement
;;; asked which, and there are three reasons:
;;;
;;;   · **It is terminal in the cases where nothing follows.** `context_wall` is
;;;     published when the turn hits the wall — and then a compaction may be skipped
;;;     (automatic compaction off), may fail, or may never fire at all. A fact that is
;;;     SOMETIMES the compaction's reason and SOMETIMES the only sentence there is has to
;;;     be a fact in its own right, or the case where nothing compacted is the case that
;;;     says nothing. That is R17's rule one more time: a disclosure that is conditional
;;;     on a later event is a disclosure that does not happen.
;;;   · **It is a failure** — the turn stopped before it finished — and letibot classifies
;;;     it that way. The failure register is where a stopped turn belongs.
;;;   · **Its numbers are already on the row.** The wall and the announcement carry the
;;;     same pair (`938,669 of 999,999`); folding the wall into the compaction's row would
;;;     print one measurement twice on one card.
;;;
;;; So: `context_wall` and `auto_compact_skipped` are notes — the two codes whose fact is
;;; *nothing was attempted* — and every code that reports an attempt is a row.

(defun compaction-facts (detail)
  "WHAT a compaction warning says, as numbers — R24's extraction and its ONE assumption.

**The daemon states these facts in PROSE and a headline needs numbers**, so this reads
the sentences letibot's `sessions.rs` writes. That is the thing this head refuses
everywhere else — `JobOutput` carries its offsets *beside* the text precisely so a pane
need not take a footer sentence apart — so this is a **bridge and not a design**: the
numbers want to be fields, and the ask is filed. Two things make it safe meanwhile:

  · **the assumption is CHECKED rather than believed** —
    `every-compaction-sentence-this-head-parses-is-still-the-one-letibot-writes` reads
    that file and fails if a format string moves, so a reword is a red suite and not a
    silently wrong row;
  · **a detail this cannot read returns NIL**, and the caller falls back to a plain note
    — today's behaviour. The failure mode of a reword is *a note again*, never a row
    with invented numbers.

Returns a plist whose `:kind` is `:compacted`, `:compacting`, `:no-progress`, `:failed`
or `:reseat`. NIL means *this head cannot read that sentence*."
  (let ((d (or detail "")))
    (cond
      ;; the failure, which has no numbers to give: "the automatic compaction did not run"
      ((search "the automatic compaction did not run" d)
       (list :kind :failed))
      ;; "compacted from R to A tokens and that is STILL within H of the W window, …"
      ((search " tokens and that is STILL within " d)
       (list :kind :no-progress
             :was (%number-after d "compacted from")
             :after (%number-after d " to " (search "compacted from" d))
             :headroom (%number-after d " tokens and that is STILL within ")
             :window (%number-after d " of the ")))
      ;; "compacted: W → A tokens, on transcript ID."
      ((search " tokens, on transcript " d)
       (let* ((mark " tokens, on transcript ")
              (at (search mark d))
              (from (+ at (length mark))))
         (list :kind :compacted
               :was (%number-after d "compacted: ")
               :after (%number-after d " → ")
               :transcript (subseq d from (or (position #\. d :start from) (length d))))))
      ;; the re-seat's own account: "re-seated: N tokens of conversation carried …"
      ((search "re-seated: " d)
       (list :kind :reseat :tokens (%number-after d "re-seated: ")))
      ;; the second report after the fork: "compacted: A tokens resident now, was W."
      ((search " tokens resident now, was " d)
       (list :kind :compacted
             :after (%number-after d "compacted: ")
             :was (%number-after d " tokens resident now, was ")))
      ;; the announcement: "R of W tokens resident, leaving less than the H …"
      ((search " tokens resident, leaving less than the " d)
       (list :kind :compacting
             :resident (nth-value 0 (%digits-at d 0))
             :window (%number-after d " of ")
             :headroom (%number-after d " tokens resident, leaving less than the ")))
      (t nil))))

;;; ### R27's record: the structure the wire now carries beside the sentence
;;;
;;; **`detail` stays exactly as it is** — it is the sentence every reader falls back to, and a
;;; head that ignores `compaction` entirely is a correct head (R28). This is the same compaction
;;; as FIELDS, and what it buys is that the head no longer takes the sentence apart: the section
;;; list, the tail, the truncation and the template are all facts on the frame.

(defparameter +compaction-sections-key+ "compaction.sections"
  "The settings row carrying the headings a record has, comma-joined with no spaces.

**A row and not a list here**, for the reason `head-run.tools` exists: a head holding its own
copy of the headings would drift the first time the template gained one. It is also what makes
the TWO ABSENCES tellable apart — a name in this row with no section on the report is *nobody
said*, and it can only be known by asking the daemon's list. An absent row is a daemon older
than this one, and then the head draws the sections the report carries and says nothing about
the rest, which is the same shape as every other absent row in this tree.")

(defvar *compaction-sections* nil
  "The headings a compaction record has, off the daemon's own row — or NIL when it has not said.

**A `defvar` and not a slot in the session, and this is the same choice `*daemon-protocol*`
makes for the same two reasons.** The names are needed by a function that has no head in hand:
`note-compaction` files the row from a SESSION, on the `apply-event` path, and the payload it
builds has to know which headings nobody wrote. A session slot would also be a struct layout
change, and this tree's own note is that a layout change is a restart while a push must survive —
so live daemon state read by the renderer lives in a global, as `*daemon-protocol*` does.

It is set in ONE place (`%fold-settings`, beside `(head-settings head)`) and rebound by
`with-replay-globals`, because a replay folds frames and a stale list would put one session's
headings into another's record.")

(defun compaction-section-names (settings)
  "The headings a compaction record has, as the DAEMON lists them, or NIL when it has not said.

Read from the row and never from a constant here, for the reason `head-run-tools` reads its own
row: a head holding its own copy of the headings would drift the first time the template gained
one. An absent row is a daemon older than R28 and is the same NIL as a daemon that named none."
  (let ((row (and settings
                  (find +compaction-sections-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (when row (%split-commas (or (getf row :value) "")))))

(defun %fold-settings (settings)
  "Take the daemon's rows: store them, and take the two facts this head uses BELOW the head.
The settings frame is the only place `head-settings` is written, so it is the only place these
can go stale — and putting the fold here rather than at each reader is what keeps one writer."
  (setf *compaction-sections* (compaction-section-names settings))
  settings)

(defun compaction-report (w)
  "W's `compaction` object as a plist this head can draw, or NIL when there is none.

**NIL is a fact about the daemon, not about the compaction**: every warning that is not a
compaction has no such object, and so does every daemon older than R28. The caller then draws
what it always drew — the sentence — which is why this returns NIL rather than an empty shape.
R28 is explicit that the wire is `null`/missing and never `{}`: *a present-but-empty object
would be a compaction nobody could describe.*

**The two absences are made explicit HERE rather than at the drawing**, so that a section list
with a heading nobody wrote and a heading written empty cannot be confused one level down. A
section present with an empty body keeps its entry — *nothing is under it* — and a heading in the
daemon's list with no entry at all is not manufactured here: the drawer asks
`compaction-section-names` about it.

The fields are read defensively: this is the other half's grammar, and a field that arrives in a
shape this build does not expect is DROPPED rather than drawn as a blank — the same rule the
`head-run.tools` descriptors keep."
  (let ((c (getf w :compaction)))
    (when (consp c)
      (list :kind (getf c :kind)
            :tokens-before (getf c :tokens-before)
            :tokens-after (getf c :tokens-after)
            :transcript (getf c :transcript)
            :resident (getf c :resident)
            :window (getf c :window)
            :headroom (getf c :headroom)
            :cut-off (and (getf c :cut-off) t)
            :template (and (stringp (getf c :template)) (getf c :template))
            :sections (loop for s in (getf c :sections)
                            when (and (consp s) (stringp (getf s :name)))
                              collect (cons (getf s :name) (or (getf s :body) "")))
            :tail (let ((t* (getf c :tail)))
                    (and (consp t*)
                         (list :turns (loop for tn in (getf t* :turns)
                                            when (and (consp tn) (stringp (getf tn :text)))
                                              collect (cons (or (getf tn :role) "") (getf tn :text)))
                               :carried (getf t* :carried)
                               :because (or (getf t* :because) "")
                               :dropped (getf t* :dropped))))))))

(defun compaction-record (w)
  "The record W's `compaction` carries, as TEXT for the row's payload, or NIL when there is none.

**This IS what the row draws when the structure is present**, and the sentence is what it draws
when it is not — one row, one record, and no reader sees the same compaction twice. The sentence
stays on the item (`:compaction`), so nothing is lost by preferring the fields: it is the
fallback and the thing `/diagnostic`-style readers can still reach, not a second copy on the
glass. R24's own counting rule, which the operator wrote: *how many times is nothing-ran
needed* — once.

**Sections are drawn in the DAEMON'S order, which is the settings row's order**, so a heading
nobody wrote keeps its place in the shape rather than being appended to the bottom. Each heading
draws its body, or `(none)` when the model wrote the heading and nothing under it, or
`(not stated)` when the daemon's list names it and the record has no such section. **Those two
are different facts and the whole shape turns on them**: a reader that renders the second as the
first has reported silence as a clean bill of health.

**The tail is a block of its own and never folded into the last section.** It is what was carried
VERBATIM, which is a different kind of thing from what was summarised — and a tail appended to
`Relevant Files` would read as more of that section.

**An unknown `because` is printed raw.** The daemon's vocabulary, and a head that met a fifth
reason must show it rather than choose between dropping the fact and inventing one — R28's own
rule, and the reason it is a string on the wire."
  (let ((r (compaction-report w)))
    (when r
      (let* ((names *compaction-sections*)
             (found (getf r :sections))
             ;; the daemon's list when it sent one, else the sections it found, in its order
             (order (or names (mapcar #'car found)))
             (seen nil)
             (out nil))
        (dolist (name order)
          (let* ((hit (assoc name found :test #'string=))
                 (body (and hit (cdr hit))))
            ;; **ONE wrap, not two.** The first cut wrote `(list (list :heading …))`, so
            ;; `(car piece)` was a LIST rather than `:heading` and every heading fell through the
            ;; text renderer's `case` — the record drew its bodies with no names over them, which
            ;; is the one thing a section list is for. Found by the probe that printed the
            ;; record's own pieces, not by reading the code.
            (push (list :heading name (not hit)) out)
            (cond
              ((not hit) nil)                       ; `(not stated)` is the heading's own mark
              ((zerop (length (string-trim " " body))) (push (list :empty) out))
              (t (dolist (l (%payload-lines body))
                   (push (list :body l) out))))
            (push name seen)))
        ;; **sections the daemon sent and its own list does not name.** A template that gained a
        ;; heading, or a row written by a newer daemon: drawn after the known ones rather than
        ;; dropped, because a head that hid a section because it could not place it would be
        ;; withholding the record it was sent.
        (dolist (s found)
          (unless (member (car s) seen :test #'string=)
            (push (list :heading (car s) nil) out)
            (dolist (l (%payload-lines (cdr s)))
              (push (list :body l) out))))
        ;; --- the tail, its own block, introduced by its own header
        (let* ((t* (getf r :tail))
               (turns (getf t* :turns))
               (because (getf t* :because))
               (carried (getf t* :carried))
               (dropped (getf t* :dropped)))
          (push (list :tail-head
                      (format nil "tail — ~a~@[ · ~d item~:p of the newest exchange left off the front~]"
                              (cond
                                ;; an EMPTY tail says WHY, which is the requirement's third
                                ;; clause: a local compaction carries no turns by ruling, and a
                                ;; tail that drew nothing at all would read as a bug
                                (turns (format nil "~d turn~:p carried~@[ (~a)~]"
                                               (length turns) because))
                                (t (format nil "nothing carried (~a)" because)))
                              dropped))
                out)
          (dolist (tn turns)
            (push (list :turn (car tn) (cdr tn)) out)))
        (when (getf r :template)
          (push (list :template (getf r :template)) out)
          (push (list :blank) out))
        (nreverse out)))))

(defun compaction-record-text (record)
  "RECORD (from `compaction-record`) as the text a tool row's payload is, or NIL.

**The payload is text** — that is the wire's field and the fold's unit — so the record is
rendered to it here rather than the drawer being taught a second shape. The MARKS are the
record's own: a heading, `(none)` for a heading the model wrote and left empty, `(not stated)`
for one the daemon's list names and the record has not got."
  (when record
    (let ((out nil))
      (dolist (piece record)
        (case (car piece)
          (:heading (push (cadr piece) out)
                    (when (caddr piece) (push "      (not stated)" out)))
          (:empty (push "      (none)" out))
          (:body (push (format nil "      ~a" (cadr piece)) out))
          (:blank (push "" out))
          (:tail-head (push "" out) (push (cadr piece) out))
          (:turn (push (format nil "      ~a: ~a" (cadr piece) (caddr piece)) out))
          (:template (push (format nil "template ~a" (cadr piece)) out))))
      (format nil "~{~a~^~%~}" (nreverse out)))))

(defun compaction-row-p (w)
  "Is W a compaction this head renders as a TOOL ROW rather than a note?

Both halves, and the second is what makes the fallback honest: the code must be one of
`+compaction-row-codes+` **and the sentence must be readable**. A compaction warning
whose words this head cannot parse is a note, which is exactly what it was before R24."
  (and (member (or (getf w :code) "") +compaction-row-codes+ :test #'string=)
       (compaction-facts (getf w :detail))
       t))

(defun %compaction-subject (facts)
  "The headline's SUBJECT — **the numbers**, in the shape the ruling asked for.

`~:d` is Common Lisp's thousands-separator directive, which is the operator's own
spelling in the requirement (`939,708 → 8,703 tokens`) and the one number format on
this screen that is neither `747.5k` nor a raw integer. A count you are deciding about
is read digit by digit, not scaled."
  (case (getf facts :kind)
    (:compacting (format nil "~:d of ~:d tokens"
                         (or (getf facts :resident) 0) (or (getf facts :window) 0)))
    (:reseat (format nil "~:d tokens carried" (or (getf facts :tokens) 0)))
    (:failed "the automatic compaction did not run")
    (t (format nil "~:d → ~:d tokens"
               (or (getf facts :was) 0) (or (getf facts :after) 0)))))

(defun %compaction-verb (facts)
  "The word for the row: a compaction that is happening, one that happened, or a
re-seat, which is a compaction that lands on a different prompt."
  (case (getf facts :kind)
    (:compacting "Compacting")
    (:reseat "Re-seated")
    (t "Compacted")))

(defun %compaction-failed-p (facts)
  "Is FACTS a compaction that was tried and is not a success?

**Two of the five kinds, and they are not the same failure.** `:no-progress` ran and did
not help — the summary is still near the wall, so automatic compaction switched itself
off. `:failed` was never run. letibot's severity table calls both failures, and the row
carries the same red the note did."
  (member (getf facts :kind) '(:no-progress :failed) :test #'eq))

(defun %compaction-cut-off-said (w)
  "` · cut off` when the record ran out of room before it finished, and the empty string otherwise.

**On the HEADLINE and not only in the payload**, which is the whole reason R28 carries it as a
bool: a templated record is exactly where *truncated* stops being readable out of any one section
— the cut falls wherever the model ran out, which with seven headings can be inside `Relevant
Files` — and a FOLDED row shows one payload line and a seam. A fact only visible after expanding
the fold is a fact the reader who did not expand it does not have. The daemon's sentence carries
the same fact in words; this is the fact, where it cannot be missed."
  (let ((r (compaction-report w)))
    (if (and r (getf r :cut-off)) " · cut off" "")))

(defun note-compaction (session w)
  "FILE W as a TOOL ROW. T when one was filed; NIL when W is not a compaction row.

**The row IS a `tool_result`** — `:name \"compact\"`, an outcome, and the daemon's own
sentence as its payload — so every affordance comes from machinery that already exists
and is already tested: `%tool-result-lines` draws the headline and folds the payload,
`payload-view-seed` gives it `ctrl-t`, the seam and the pager are the payload window's,
the payload is sanitised by `%without-control` as every other result is, and it scrolls
with the conversation because it is IN the conversation.

**`:verb` and `:subject` are the ROW's own**, and that is a general capability rather
than a compaction special case: a tool row derives its verb from the tool's name and its
subject from the `Assistant` row that proposed the call, and **a compaction has no
proposing row** — nobody called it, the daemon did — so there is no `call_id` to look a
target up by, and the numbers are what belongs on the headline. Both fields are optional
and default to today's derivation, so nothing else changes shape.

**It is not a note**, and that is the point of the filing rather than an accident of it:
`session-warnings` does not get it, so `/notes` does not list it, `/status` does not
count it, and the retired set does not apply. The ROW is its record — the whole sentence
is its payload, which is more than a note ever kept."
  (when (compaction-row-p w)
    (let* ((facts (compaction-facts (getf w :detail)))
           ;; **R27: the record the wire carries, when it carries one.** The row draws the
           ;; STRUCTURE then — sections, tail, template — and falls back to the daemon's sentence
           ;; when there is no such object, which is every daemon before R28 and every warning
           ;; that is not a compaction. One row, one record: the sentence stays on the item rather
           ;; than being drawn under the structure, because it is the same numbers said twice and
           ;; R24 already settled how many times is enough.
           (record (and (compaction-report w)
                        (compaction-record-text (compaction-record w))))
           (bad (%compaction-failed-p facts))
           (id (format nil "leticl-compaction-~d" (incf *filed-notes*)))
           (row (list :item-id id
                      :kind "tool_result"
                      :ts (or (getf w :ts) 0)
                      ;; the warning is kept on the item, as `:warning` is kept on a
                      ;; note row: the row is the record, and the sentence is on it.
                      :compaction w
                      :item (list :type "tool_result"
                                  :call-id (format nil "compaction-~a" id)
                                  :name "compact"
                                  :verb (%compaction-verb facts)
                                  :subject (concatenate 'string (%compaction-subject facts)
                                                        (%compaction-cut-off-said w))
                                  :outcome (list :outcome (if bad "failed" "ok"))
                                  :payload (or record (getf w :detail) "")))))
      (push-item session row)
      row)))

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
  '(:explain :screen-requested :secret-requested :secret-settled
    ;; R24 part two. The head RUNS the call and sends the result from the frame
    ;; path, because a run is an act and not a fold: it needs the socket, the
    ;; door and — if this head ever has fetchers — the network, none of which the
    ;; session's folder can reach. Named here so a frame this head reads and acts
    ;; on is not reported as one it has never heard of.
    :operator-call-allowed)
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

(defparameter *stall-ms* 15000
  "How long a silence before the head says so — the reference's own number
(`stuck_line`, app.rs:7594: `if quiet > 15_000`). Ours was 20 000, which is five
seconds of a dead turn nobody is told about; long enough that a slow model
thinking is not a stall, short enough that a dead socket is not a mystery.

**Two questions, one number.** `stall-text` (chrome.lisp) asks it about the turn — has the
daemon said anything about the work it is running — and `filling-active-p` asks it about a
counted operation — has the daemon ticked the bar lately. Both are *has the daemon stopped
talking to me*, both are measured from RECEIVED-at, and this file owns it because the
filling state does and because it loads first. A second window is how the two would come to
disagree about what silence means.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a constant
could never be moved on a running head.")

(defvar *filling* nil
  "The counted operation in flight, or NIL: a plist
`(:what W :unit U :done D :total T :at-ms M)`.

A defvar, not a session slot, for the reason all live state is: a struct layout change
is a restart. Bound by `with-replay-globals`, because a replay must answer the same
bytes twice.")

(defun filling-active-p ()
  "Is a counted operation in flight that the head should draw?

**Three ways it ends, and the third was found on the operator's screen.** The first two are
facts rather than timers: the count COMPLETES (`done >= total`), or the connection does —
a socket that goes mid-import would otherwise leave a bar claiming progress for ever. The
file's own rule has always been *a bar that cannot end is worse than no bar*.

**What the third closes is a bar that DID not end.** Measured on a live head: `republish`
(a resume's carry) published 57 ticks and stopped — and because the loop emits one tick per
row that has a BODY, a session whose rows and items disagree ends the walk without ever
sending `done == total`. The head holds no completing tick, `done < total` stays true, and
the bar sat at *57 of 1790 rows* for **three and a half minutes** while the operator watched
a frozen screen. The tick's own arrival time was in `*filling*`'s `:at-ms` the whole time and
nothing read it.

So a tick older than `*stall-ms*` is not news, and the bar is not drawn. That is the same
sentence the stall line makes — *the daemon has gone quiet* — applied to the other thing on
this screen that claims the daemon is working. It is deliberately the SAME number and the
same clock: both measure received-at, and one window means the two cannot disagree.

**A tick with no clock does not expire.** `:at-ms` is NIL in a replay and in any test that
has not told the head what time it is (`note-filling` only stamps it when `*now-ms*` is
positive), and expiring on an unknown age would make the bar's behaviour depend on whether a
clock was running rather than on the operation." 
  (and *filling*
       (let ((done (or (getf *filling* :done) 0))
             (total (or (getf *filling* :total) 0))
             (at (getf *filling* :at-ms)))
         (and (plusp total) (< done total)
              ;; **the news test**: a stamped tick must be recent, an unstamped one is
              ;; not aged at all — see the docstring
              (or (null at) (not (plusp *now-ms*))
                  (< (- *now-ms* at) *stall-ms*))))))

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

;;; -------------------------------------------------------- the compaction ;;;
;;;
;;; **THE FOLD'S OWN FIGURE, AND IT IS NOT `PromptProgress`.** (letibot `f273300`, protocol 27.)
;;; The overrun compaction summarises a SCRATCH transcript through a `NullSink`, so until this
;;; event landed nothing of it reached a head at all: minutes of a still screen, at the moment the
;;; session is largest and the model slowest. The operator asked *"leticl compacts but why no
;;; progress bar?"* and then sharpened it — *"even more so for this overruns when we compact in
;;; turns."*
;;;
;;; **AND THE REASON THE EVENT IS ITS OWN IS A DEFECT WORTH NOT REPEATING HERE.** Forwarding the
;;; scratch turn's raw `PromptProgress` put the SCRATCH prompt's token count into `turn.progress`,
;;; which is the SESSION's — so the operator watched `69k` sit over a 240k conversation that had
;;; not changed. *The number was never wrong; its label was.* So this is a defvar of its own and
;;; nothing here writes `*turn-progress*`.

(defvar *compaction* nil
  "The fold in flight, or NIL: a plist
`(:half H :halves N :prompt P :processed X :written W :unit U :at-ms M)`.

A defvar, not a session slot, for the reason all live state is: a struct layout change is a
restart. Bound by `with-replay-globals`, because a replay must answer the same bytes twice.")

(defun compaction-active-p ()
  "Is a fold running that the head should draw?

Ephemeral, like `Filling`: a progress frame from four minutes ago is a lie about now, so this is
cleared by the fold's own end — the `compacted` warning, or a turn finishing — rather than by a
timer in here."
  (and *compaction* t))

(defun note-compaction-progress (env)
  "Fold one `compaction_progress` tick. Returns `:dirty`.

**THE BAR IS DRIVEN FROM `written`, AND THAT IS THE WHOLE TRAP THIS EVENT CARRIES.** `processed`
is how much of the half's prompt the server has READ, and on a messages transport — which is what
the operator's deepseek sessions use — the server reports no prefill at all, so it arrives as
`0`. That is *this transport does not count that*, NOT *nothing has happened*: a bar filling from
`processed` would sit at zero for the whole fold and look exactly like the hang this event exists
to remove.

`unit` is kept as it arrives and never assumed — `tokens` where the transport reports the server's
own count, `chars` where it reports only text. The two do not count the same thing, so one name
for both would be a lie about one."
  (let ((half (or (getf env :half) 0))
        (halves (or (getf env :halves) 0)))
    (setf *compaction* (when (and (integerp half) (plusp half))
                         (list :half half :halves (max 1 (or halves 1))
                               :prompt (or (getf env :prompt-tokens) 0)
                               :processed (or (getf env :processed) 0)
                               :written (or (getf env :written) 0)
                               :unit (getf env :unit)
                               :at-ms (and (plusp *now-ms*) *now-ms*))))
    :dirty))

(defun reset-compaction ()
  "Forget the fold. For its own end, a session change, and a dead socket."
  (setf *compaction* nil))

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

;;; ------------------------------------------- the rows this head does not hold ;;;
;;;
;;; **A transcript that begins where the head's window begins, and does not say so, is
;;; a lie by omission.** `ViewBounds` bounds a snapshot by count and by bytes — 2,000
;;; rows or 8 MB of row text, whichever comes first (`view.rs:308-347`) — so a head on
;;; a long session holds the NEWEST slice of the conversation and `items_dropped` says
;;; how many rows came before it. That number was stored and **read by nothing**: no
;;; seam, no counter, no `/status` row. Scroll to the top of such a session and the
;;; transcript ends as cleanly as a session whose first row that is, which is the
;;; defect R17 spent a commit on for body-less rows — *"a disclosure that does not
;;; happen cannot be dismissed"*.
;;;
;;; The rows above are named by ORDINAL (`FetchRow`, `protocol.rs:783-797`) and the
;;; daemon answers a window of one of them. **What the head asks for is the row
;;; immediately above its oldest**, which is `items_dropped - 1`, and a `Some` answer
;;; is prepended to the transcript — so scrolling up walks back into the conversation
;;; one row at a time.
;;;
;;; MEASURED against today's daemon, and this is the honest half of the capability:
;;; **`FetchRow` can never answer a row the head does not already have.** The snapshot
;;; is `view.items.clone()` (`view.rs:821`) and `row_body_at` reads the same
;;; `self.items` (`view.rs:745-747`) — one view, one bound — so an ordinal the snapshot
;;; trimmed answers `null`, and an ordinal the snapshot carried is a row the head
;;; already holds. The frame's own test says the same thing from the other side: *"the
;;; store read that would answer it is R19.2(b) in `letibot`'s TODO"*. The head's half
;;; is built anyway, because the head cannot know WHICH of those two worlds it is in
;;; without asking, and the seam cannot be honest without it.

(defparameter +row-fetch-len+ 65536
  "How many bytes of a row this head asks for in one `FetchRow`.

The daemon's own cap (`server.rs`: `MAX_FETCH_ROW`), not a smaller number of our own:
the frame is a *window* and the head renders a transcript row out of it, so asking for
less than the daemon will send would only mean the same row arriving in pieces for no
reason. A body longer than this is drawn with a seam saying how much more there is —
the same instrument the payload window already uses.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defvar *row-fetch* nil
  "`(:row N :at MS)` while this head has asked for a row above its oldest, else NIL.

A `defvar` rather than a slot — a struct change is a restart — and it holds ONE
request, because the transcript has one top: a head that pipelined fetches up its own
history would be fetching rows it may never show.

Bound by `with-replay-globals`, because a replay must answer the same bytes twice.")

(defvar *rows-above-unserved* nil
  "T once the daemon has answered `body: null` for a row above this head's oldest.

**Not a failure, and not retried** — but the old name and the old sentence said the rows
were GONE, and **nothing is gone.** Measured against the operator's own store on
2026-10-02: session `s-1789639478142928813` is a chain of 27 transcripts (`#t0` … `#t26`),
`transcript_item` is append-only by trigger, and the current link holds 145 rows while the
links behind it hold 28198, 22802, 145017 and up to 913523 of them. Every row the reader
was scrolling to is on disk.

What `null` means is narrower, and the daemon wrote the distinction down for the caller:
`SessionView::row_body_at` returns `None` *\"when the ordinal is outside what this view
holds: trimmed by `ViewBounds`, or past the end of the session. **That distinction is the
caller's to make**\"*. leticl IS that caller, and it did not make it — it turned an answer
about a bounded window into an assertion about the world.

**The two tiers also number rows differently, which is the mechanism.** `items_dropped`
counts rows trimmed out of the DAEMON'S VIEW, which accumulates across a session's whole
link chain; `FetchRow`'s store tier resolves the same number against
`current_transcript_id` and `seq`, and `seq` is *\"0-based, dense\"* **per link**. So the
ordinal the seam advertises names nothing in the current transcript, the store tier
answers `null` honestly — `row_body`'s own comment says *\"the ordinal is relative to the
CURRENT transcript\"* — and what comes back looks like absence.

So the flag still does the job it was introduced for, which is to stop a head asking once
per scroll for ever; it just no longer claims the rows do not exist. **Saying where they
ARE needs a fact no head is sent**: there is no fork event in the session stream, the
parent id is in `ForkReport` and on no wire, and the daemon's own module note for the
`transcript` tool says *\"everything a compaction folded into a summary is in the links
behind it\"* — reachable by that tool and by no head.

A `defvar` and not a session slot: it is about THIS head's window, not about the session,
and a snapshot must not clear it — the head that discovered the rows are out of reach
still has that fact after a resync.")

(defun rows-above (session)
  "The ordinal of the row immediately above this head's oldest, or NIL when there is none.

`items_dropped` counts the rows that came before the ones held, so the row above the
oldest held one is `items_dropped - 1` — and zero means there is nothing above, because
ordinal 0 IS the session's first row ever. The same arithmetic `view.rs:736` states:
*\"the row above my oldest is `items_dropped - 1`\"*."
  (let ((dropped (or (session-items-dropped session) 0)))
    (when (plusp dropped) (1- dropped))))

(defun note-row-fetched (session row body total)
  "Fold one `RowFetched`. Returns `:dirty` when something visible changed.

**Three answers, and they are three different facts:**

  · `body` is a STRING — the daemon holds the row, and it goes at the TOP of the
    transcript. It is prepended, not appended: its ordinal says it is older than
    everything held, and the transcript is oldest-first. `items_dropped` is decremented
    with it, because that count and the items must keep summing to the session's length
    or `rows-above` starts naming the wrong row;
  · `body` is NIL — the daemon will not serve it, and `*rows-above-unserved*` makes the
    seam say that instead of offering a fetch that will keep failing. **It is not a
    statement that the rows are gone**: see that flag, and the note above about the two
    ordinal spaces, for what `null` does and does not mean;
  · and a row that arrives while NOTHING is pending is ignored, because it is the answer
    to a question this head is no longer asking (a fetch another head's scroll started,
    or one from before a resync).

`total` is the WHOLE body's length and is kept with the row, so a fetched row longer
than the window this head asked for can say how much more there is — the one thing the
frame exists to make sayable."
  (let ((want (getf *row-fetch* :row)))
    (setf *row-fetch* nil)
    (cond
      ((null want) :quiet)
      ;; a redelivery, or an answer about a row this head has already caught up past
      ((or (/= want row) (null (rows-above session)))
       (when (null body) (setf *rows-above-unserved* t))
       :dirty)
      ((null body)
       (setf *rows-above-unserved* t)
       :dirty)
      (t
       (prepend-item session
                     (list :item-id (format nil "leticl-row-~d" row)
                           :kind "fetched"
                           :ts 0
                           :item (list :type "fetched" :row row :text body :total total)))
       (decf (session-items-dropped session))
       :dirty))))

(defun rows-above-line (session cols)
  "The seam above the oldest row this head holds, or NIL when it holds all of them.

**The disclosure R17 argues for, one layer out.** A window that does not say it is a
window is read as the whole conversation — and the operator scrolling to the top of a
long session has no way to tell *\"this is where it begins\"* from *\"this is where my
head stops\"*. Three states, because there are three facts:

  · **asking** — a request is in flight for a named ordinal;
  · **unserved** — the daemon answered `null`, and the seam stops offering a fetch rather
    than promising one that cannot happen. **The word is `unserved` and not `gone`,
    which is what this said until 2026-10-02**: `null` means the ordinal is outside what
    the daemon's view holds and its store tier can resolve, and the operator's own store
    says the rows are all still there in the links behind. A seam that told a reader their
    conversation had been destroyed when it had been neither destroyed nor reachable was
    wrong twice, and the second is the one that costs them a scrollback they still had;
  · **here** — rows above exist and this head will load the next one as the reader
    reaches this line.

It is DIM, like the other seams in this tree (`… +N lines · ctrl-t`): it is an
instrument, not part of the conversation."
  (let ((n (session-items-dropped session)))
    (when (and (integerp n) (plusp n))
      (let ((row (rows-above session))
            (text (cond
                    (*row-fetch*
                     (format nil "… ~d row~:p above · asking the daemon for row ~d…"
                             n (getf *row-fetch* :row)))
                    (*rows-above-unserved*
                     (format nil "… ~d row~:p above · the daemon does not serve these for this transcript"
                             n))
                    (t (format nil "… ~d row~:p above · scroll to this line to load the next"
                               n)))))
        (list (list (cons (truncate-to-width text cols) '(:dim t))))))))

(defun prepend-item (session item)
  "ITEM at the FRONT of the transcript, and the render cache invalidated.

**A prepend is not a push**, and the difference is why this is not `push-item`: the
items vector is oldest-first and grows at the END, so a row discovered on the older
side has to go in front of every row held. Rebuilt rather than shifted in place,
because it happens on a keypress at the top of a scrolled transcript and not per frame:
2,000 conses is nothing beside the frame it provokes.

The vector's IDENTITY changes, which is in `%hist-key` — so the cached lines are
dropped rather than reused against a transcript that gained a row at the front."
  (incf *hist-generation*)
  (setf (session-items session)
        (%items-vector (cons item (coerce (session-items session) 'list))))
  item)

;;; --------------------------------------------------------- the seq gap ;;;
;;;
;;; MISSING IN BOTH HEADS, and the last item of §10: *"neither checks `seq`
;;; continuity"*. A gap in the stream is a fact this head can see for itself, and
;;; nothing looked.
;;;
;;; **Why it matters even though `dropped` exists.** `session-dropped` is what the
;;; DAEMON says it threw away — it arrives on a `Hello` and on a `Resync`, so a head
;;; that attached before the daemon's scrollback overflowed is told, and a head that
;;; merely fell behind mid-batch is not. And the two are not the same measurement: a
;;; `dropped` of 358324 says *the daemon holds 358324 events I will never see*, while a
;;; jump of eleven says *this stream went from 40 to 52, and nobody said so*. The
;;; second is the one that turns a transcript into a document with a hole in it and no
;;; mark in it.
;;;
;;; **Reported where the other connection facts are reported**, because it is the same
;;; class: a row in the conversation at the point it was noticed, and a counter on
;;; `/status`. Not a note (they expire), and not `filtered` (that is *I chose not to
;;; show this*, which the daemon reads back).

(defvar *seq-gaps* 0
  "How many discontinuities this head has seen in the event stream, over its life.

A `defvar` rather than a slot, and NOT reset by a snapshot: it counts this head's
lifetime, so a `/status` row reading 0 is a head that has never met one, which is a
different statement from a head that does not count them. The same distinction
`*unreadable-total*` keeps.")

(defun note-seq-gap (session from to)
  "FILE a row for a gap from FROM to TO, count it, and return how many went missing.

**A step of one is not a gap.** A reconnect replays from the read mark by design
(§13.2b: *a crash then costs a duplicate, never a silence*), so `to` can be less than
`from` or equal to it, and neither is a hole — both are the protocol working. A jump
FORWARD is the only shape the daemon's bounded scrollback can produce: it dropped what
it could no longer hold, and the next event it had is `to`."
  (let ((missing (- to from 1)))
    (when (plusp missing)
      (incf *seq-gaps*)
      (file-head-note session
                      (format nil "the event stream jumped from ~a to ~a — ~d ~
                                   event~:p never arrived. The daemon's scrollback is ~
                                   bounded, so events are dropped when a head falls ~
                                   far enough behind; this head has asked for a fresh ~
                                   snapshot (`/resync` takes another), and `/status` ~
                                   counts these."
                              from to missing))
      missing)))

(defun apply-event (session env)
  "Fold one envelope into state. Returns :dirty when something visible
changed, :quiet when not — the head loop paints on :dirty and acks on both."
  (let ((name (event-name env))
        (seq (getf env :seq))
        (gap nil))
    ;; **THE GAP IS MEASURED BEFORE THE MARK MOVES**, because afterwards there is
    ;; nothing left to compare against. `session-seq` is the last seq FOLDED, which is
    ;; the right thing to compare with: the loop's own `last-seq` counts frames READ,
    ;; and a frame this head rejected still arrived in order.
    ;; a mark of ZERO is *nothing folded yet*, not a gap from zero: a head that
    ;; attaches to a session already at seq 5, or a replay of a log that starts
    ;; there, is told where it is starting by `resumed_from` rather than by a hole
    (when (and (integerp seq) (integerp (session-seq session))
               (plusp (session-seq session)))
      (setf gap (note-seq-gap session (session-seq session) seq)))
    ;; the seq is consumed either way: a filtered frame still advances the read
    ;; mark, or a head that draws little rereads its own output forever
    ;; guarded: the slots are fixnums, and an envelope without a `seq` (a fixture built by hand,
    ;; a frame from a daemon that forgot) would otherwise take the head down on a type error
    (when (integerp seq)
      (setf (session-seq session) seq
            (session-expected-seq session) seq))
    ;; **A GAP DOES NOT SWALLOW THE EVENT THAT REVEALED IT.** This used to be
    ;; `(when gap (return-from apply-event :dirty))` — the row was filed, and the frame
    ;; that carried the new seq was never folded. So every gap cost the head one MORE
    ;; event than the daemon dropped, and it was always the first one to arrive
    ;; afterwards: a `tool_finished` whose call then stayed `running` for ever, a
    ;; `turn_finished` whose turn stayed busy. The gap is about the STREAM; the frame is
    ;; a frame like any other and is folded below. `gap` only decides the disposition
    ;; at the end — the row is a visible change even when the event is one this head
    ;; filters.
    ;;
    ;; a stranger's turn is consumed and not folded — before any side effect
    (when (and (member name +per-turn-events+) (%foreign-turn-p session env))
      (return-from apply-event (if gap :dirty :quiet)))
    (let ((disposition
    (case name
      ((:turn-started)
       ;; WHEN it started, on our own clock, so the composer's edge can say how
       ;; long this has been going. A turn that came out of a SNAPSHOT has no
       ;; start time — `*turn-started-ms*` stays NIL and the edge says "started
       ;; before this head attached" rather than a duration nobody measured.
       (let* ((old (session-turn session))
              ;; **THE LAST FINISHED TURN'S MEASUREMENTS CARRY ONTO THE NEW ONE.** `last_timings`
              ;; and `usage` are the reference's own kept-past-the-end pair (app.rs:3447, 4218,
              ;; read at 10236), and without them `22 tok/s`, the duration and `38 out` — all three
              ;; of them facts about the turn that JUST ENDED — vanished the instant the next turn
              ;; began and came back when it ended. The operator saw exactly that: *"again — rate
              ;; comes and goes"*. `%usage-numbers` reads the current state first and falls back
              ;; here, so a finished turn still wins.
              ;;
              ;; The OR is for the terminal arms that carry no timings at all (an interrupt, a
              ;; failure): the newer turn's state says nothing, so the older slot still answers
              ;; rather than the three fields blinking on every cancelled turn.
              (prev (getf old :state)))
         ;; **FROM THE EMITTER'S STAMP, not from the event's arrival.** `:began-ms` is the
         ;; whole turn's start (see `wire-stamp->started-ms`); taking our own clock here is what
         ;; restarted the duration at every round, because this event fires once per round.
         ;;
         ;; A snapshot still measures nothing — its `:snapshot` flag says so — and a wire value
         ;; nobody set falls back to our own arrival, which is the old behaviour and no worse for
         ;; a turn whose start was not stamped.
         (setf *turn-started-ms*
               (and (not (getf env :snapshot))
                    (or (wire-stamp->started-ms (getf env :began-ms))
                        (internal-real-time-ms))))
         ;; **THE REPORT ABOUT THE PREVIOUS TURN GOES WITH IT.** The row above the composer is
         ;; ALWAYS on the screen (the operator: *"permanently occupy the row"*), so its two states
         ;; — `Responding …` and `Responded in …` — are mutually exclusive by construction rather
         ;; than by a test at the drawing end.
         (note-turn-finished nil)
         ;; the turn names the model answering it, unprompted — the one word about
         ;; the model a head is told after attach, so the header ranks it by seq
         (when (plusp (length (or (getf env :model) "")))
           (setf *model-from-turn-at* seq))
         (setf (session-turn session)
               (list :turn-id (getf env :turn-id) :model (getf env :model)
                     :ledger-head (getf env :ledger-head)
                     :text "" :reasoning "" :raw-calls ""
                     :calls nil :appended nil :progress nil :tokens 0
                     :usage (or (and prev (getf prev :usage)) (and old (getf old :usage)))
                     :timings (or (and prev (getf prev :timings)) (and old (getf old :timings)))
                     :state (list :state "running"))))
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
             ;; **AT `:terse` THE WORKING-OUT IS KEPT AND DRAWN — AS THE FOLD.** This said
             ;; `:normal`, and its comment said terse neither keeps nor draws it, so at terse the
             ;; live turn had no reasoning and the SETTLED row drew one line anyway
             ;; (`▸ Thought · 23 lines · ctrl-r`, because `reading-hides-p` needs `(reading-p)` and
             ;; terse is above reading). **So the fold was INSERTED ABOVE THE ANSWER the reader had
             ;; already read.** The operator, 2026-10-02: *"it took 23 thinking lines before you
             ;; replied … it appeared like 'Still failing…' and then [23 thinking lines] added
             ;; before it."* Right row, wrong moment.
             ;;
             ;; The two rungs this gate has to keep apart: at `:reading` the body type is in
             ;; `+reading-hides+`, so a delta nobody will draw is discarded and the snapshot stays
             ;; small; at terse the same row IS drawn on settle, so the only consistent thing is to
             ;; have it drawn while it runs too — one fold header, in the position it will keep.
             ((:reasoning) (if (verbosity-at-least :terse)
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
         ;; **what the row above the composer reports from here on** — the full turn's wall time and
         ;; the clock time it ended, neither of which is on the wire (see `*turn-last*`)
         (note-turn-finished "finished")
         :dirty))
      ((:turn-interrupted)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :progress) nil)   ; terminal, as above
           (setf (getf turn :state)
                 (list :state "interrupted" :reason (getf env :reason)
                       :partial-kept (getf env :partial-kept))))
         ;; a turn nobody answered did not *respond*, so the row reports nothing rather than
         ;; borrowing the previous turn's sentence
         (note-turn-finished "interrupted")
         :dirty))
      ((:turn-failed)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :progress) nil)   ; terminal, as above
           (setf (getf turn :state)
                 (list :state "failed" :error (getf env :error)
                       :partial-kept (getf env :partial-kept))))
         (note-turn-finished "failed")
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
           (let ((turn (session-turn session)))
             ;; **THE HANDOVER, and it is `:appended`'s own stated reason.** That list was
             ;; *"initialised at `turn_started` and written by nothing"*; it is written now, and
             ;; this is the reader it was written for. `view.rs:246-253`: a head shows a running
             ;; turn from `text`/`reasoning` and a finished one from the transcript, **and it needs
             ;; to know which rows are the finished form or it renders the answer twice.**
             ;;
             ;; Measured without this, on one head and one sequence: the reply appeared on TWO
             ;; rows — the committed assistant row at 4 and the live pane's copy at 6 — and that
             ;; duplicate is what made a queued prompt appear to cross the reply when its own row
             ;; landed. Two bugs, one cause: the live pane kept drawing text the transcript had
             ;; taken over.
             ;;
             ;; **The guard is the `:appended` membership**, not the body's kind. A row that this
             ;; turn did not publish — a snapshot's history, a row from a turn already closed —
             ;; must not clear the LIVE turn's text, and the id is the only thing that says whose
             ;; row it is. The answer arrives whole, and the turn's `:text` is that whole answer,
             ;; so the handover is exact rather than approximate.
             (when (and turn
                        (member (getf env :item-id) (getf turn :appended) :test #'equal))
               (setf (getf turn :text) "")))
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
       (push (%decision-clock-rule
               (list :req-id (getf env :req-id)
                     :kind (getf env :kind)
                     :call-id (getf env :call-id)
                     :summary (getf env :summary)
                     :target (getf env :target)
                     :detail (getf env :detail)
                     :options (getf env :options)
                     :choices (getf env :choices)
                     :because (getf env :because)
                     :advice (getf env :advice)
                     ;; **§11.7's field, MEASURED on the wire rather than read from a
                     ;; document**: a real protocol-25 daemon's `tool_started` — and the
                     ;; `decision_requested` beside it — carries `access: "read"` for a
                     ;; read and `access: "exec"` for a call that declares exec. The card
                     ;; draws its `the access is what asks:` sentence on `exec` and nothing
                     ;; else; an ABSENT field is an older daemon and draws nothing either,
                     ;; because the head does not know.
                     :access (getf env :access)
                     ;; **converted through the ONE rule, and not at the card** — see
                     ;; `%decision-clock-rule`. This arm and the snapshot's
                     ;; `open_decisions` are the two places a decision is folded,
                     ;; and they must agree about which clock the deadline is on;
                     ;; they did not, and a head that attached to a session with an
                     ;; ask already open drew 56 years of countdown for it.
                     :deadline (getf env :deadline)
                     :on-timeout (getf env :on-timeout)
                     :asked-ts (getf env :ts)))
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
       ;; **`compaction` rides across too** (R27/R28). The plist is built from named keys rather
       ;; than copied, which is right — a warning is three facts and a head that kept the whole
       ;; envelope would be keeping every frame's shape — but a new field then has to be carried
       ;; BY NAME or it is dropped on the way in. Measured: the record was on the wire, the row
       ;; drew the sentence, and the only thing missing was this line.
       (let ((w (list :code (getf env :code) :detail (getf env :detail)
                      :ts (getf env :ts)
                      :compaction (getf env :compaction))))
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
           ;; **AND A COMPACTION IS A TOOL CALL** (R24 part one). Filed as a ROW and
           ;; deliberately NOT into `session-warnings`: the requirement is that these
           ;; stop being notes at all, so `/notes` does not list them and `/status`
           ;; does not count them — the row IS the record, and its payload carries the
           ;; whole sentence, which is more than a note ever kept.
           ;;
           ;; `context_wall` and `auto_compact_skipped` are NOT here and fall through
           ;; to the note below: theirs is the fact that nothing was attempted, which
           ;; has nowhere else to live. See the block above for the ruling and why.
           ((note-compaction session w) :dirty)
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
       ;; **the model can move one of the OPERATOR's rows now** — `todo_write`'s `operator` field,
       ;; naming the row by its own words — so this event is where the head learns its row was
       ;; answered, and it must take the status: leaving it would draw the row as pending for ever
       ;; AND push the stale status back over the daemon's at the next add or delete.
       (fold-board-statuses (getf env :todos))
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
      ((:compaction-progress)
       ;; **THE FOLD'S OWN COUNT, AND ITS OWN NAME.** See `note-compaction-progress` for why this
       ;; is not folded into anything the SESSION's turn already holds.
       (note-compaction-progress env))
      ((:job-output)
       ;; **THE DASHBOARD'S FEED READS EVERY WINDOW, asked for or not.** This line is BEFORE the
       ;; overlay's `cond` on purpose: the overlay keeps a window only for the job it is showing
       ;; (`*job-out*`, and only while it is open), while a job-backed panel wants the NUMBERS from
       ;; whichever window arrives — including one answering ANOTHER head's read, because
       ;; `hub.publish` broadcasts. The two readers want different things from one fact and neither
       ;; is derived from the other, which is why this is a call and not a branch in the fold.
       (dash-note-job env)
       ;; **The answer to the jobs pane's Enter, folded into the overlay that
       ;; asked and nowhere else.** The whole window is kept — job, from, to,
       ;; produced, dropped, state, never-ran, lines, next — because the pane draws
       ;; its own header out of the OFFSETS rather than parsing `/job`'s footer
       ;; sentence (app.rs:2169-2205).
       ;;
       ;; Taken only when an overlay is open for THIS job: a head may have closed
       ;; the pane with Esc before the reply landed, and the event is published to
       ;; the session, so a head that never asked sees it too. A window for a job
       ;; nobody is looking at is nothing to keep — and keeping it would be the
       ;; stale window `scrub::is_interactive` exists to prevent.
       ;;
       ;; **`never-ran` is folded because an empty window is TWO facts** (§11.6,
       ;; letibot `e1cd2b0`): a process that ran and wrote nothing, and a command that
       ;; was never started because the wrapper could not join its cgroup. The window's
       ;; emptiness is identical in both, and this head had ONE sentence for them —
       ;; see `job-out-lines`. A daemon older than the field sends nothing, this reads
       ;; NIL, and the pane draws exactly what it drew before, which is the honest
       ;; reading of silence: such a daemon had only one answer for an empty window.
       ;; No version bump — an added, defaulted field on an existing variant, the
       ;; precedent `ModelAdvice.consulted` set.
       (cond
         ((and *job-out* (equal (getf *job-out* :job) (getf env :job)))
          (setf (getf *job-out* :state) (or (getf env :state) "")
                (getf *job-out* :from) (or (getf env :from) 0)
                (getf *job-out* :to) (or (getf env :to) 0)
                (getf *job-out* :produced) (or (getf env :produced) 0)
                (getf *job-out* :dropped) (or (getf env :dropped) 0)
                (getf *job-out* :lines) (getf env :lines)
                (getf *job-out* :next) (getf env :next)
                ;; **an empty window is TWO facts, and this is which one** —
                ;; see `job-out-lines`. NIL from a daemon that does not send
                ;; the field, which draws exactly what it drew before.
                (getf *job-out* :never-ran) (and (getf env :never-ran) t)
                ;; **AN ANSWER ARRIVED, whatever it weighs.** Set here and not
                ;; inferred from the window: a zero-byte window is an answer, and the
                ;; pane must say so rather than look like it is still waiting (R41).
                ;; See `*job-out*` for why this is not `:loading` and not the state
                ;; word.
                (getf *job-out* :answered) t
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
      (if gap :dirty disposition))))

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
