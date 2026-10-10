;;;; seq-gap — the seq gap, and the rows around it
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

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
             ;; **KEPT AT EVERY RUNG, BECAUSE EVERY RUNG DRAWS IT — at the lowest one as a COUNT.**
             ;; This was gated on `:terse` (and on `:normal` before that), on the argument that a
             ;; delta nobody draws is a snapshot nobody needs. But nobody-draws was never true:
             ;; `reading-hides-p` hides reasoning as an ITEM and the run it joins is drawn anyway —
             ;; `[71 thinking lines]` — and the count is in SCREEN lines, so it cannot be computed
             ;; from a string that was thrown away. Gating it here is what made the marker arrive
             ;; only once the turn settled: the reader got the answer first and the count of the
             ;; thinking that produced it afterwards, above it. The operator: *"when you think after
             ;; my prompt you first show me response and then collapsed thinking stats."*
             ;;
             ;; `:reading` still hides the TEXT — `+reading-hides+` is unchanged, and `turn-lines`
             ;; draws one marker line for the live turn rather than the working out.
             ;; **AND THE GATE THAT USED TO CLOSE THIS ARM IS GONE, BECAUSE WHAT IT WAS HOLDING BACK
             ;; IS FIXED WHERE THE CAUSE WAS.** It read `(if (verbosity-at-least :normal) … (return-from
             ;; apply-event :quiet))`, so at `:reading` — the rung this head is actually set to — the
             ;; whole thinking phase was thrown away, and the bill came in now: *"the thinking lines
             ;; count appeared only with the first tool call after my prompt."* A proposed CALL is live
             ;; work whatever happened to the reasoning behind it, which is why the marker arrived
             ;; exactly then and not a delta earlier.
             ;;
             ;; **WHAT MADE A COUNT-IN-FLIGHT FLASH WAS THE PLACEMENT, AND THAT IS FIXED IN THE WALK.**
             ;; `live-pending` was `(and live (not cached) t)` — all or nothing, and off on every HIT —
             ;; and `glue` was forced by `live-here`, so work in flight was handed to whichever row was
             ;; newest, including a row that could not carry it: the join was refused, the counts were
             ;; dropped entirely, and whether they were on the screen at all depended on the cache and
             ;; on the carrier row. The operator's report is the result: *"the whole thing kinda flashes
             ;; now."*
             ;;
             ;; Both are fixed where the cause was, in `%history-until`: the counts re-arm when they MOVE
             ;; rather than only on a miss, and a row that cannot take them does not try — the marker
             ;; stands on its own line. With that in place the late-arriving marker this arm used to
             ;; cause is the only defect left, and it is the one the operator named above.
             ((:reasoning) (appendf-text turn :reasoning (getf env :text)))
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
      ;; **THE TRANSCRIPT IS REPLACED ON THE WIRE, NOT APPENDED TO** (protocol 40, letibot
      ;; `14f8e2b`). A fork — a `/reseat`, a `/compact`, a re-seat onto a rebuilt prompt —
      ;; opens a NEW transcript and carries the conversation into it, so every carried row is
      ;; published under the new transcript's ids and **not one of the ids the replaced
      ;; transcript's rows are held under is in the carry**. Nothing used to say so, and every
      ;; reader folded both conversations into one list: MEASURED on the operator's own screen
      ;; — scrolled up and reading, they typed `/reseat` and were left with *"thousands of
      ;; lines 'below'"* — and in the reference's fixtures, 40 rows plus a 60-row carry left
      ;; 100 items and a banner reading *144 line(s) below*.
      ;;
      ;; **Only the PARENT's rows go.** A head can hold rows of more than one transcript (a
      ;; resume republishes the tail of the transcripts a compaction put behind the current
      ;; one, on purpose, so a reader can scroll above the summary), and those are not what the
      ;; fork replaced — the event names exactly what it did. A row's id names the transcript
      ;; it is numbered in (`{transcript_id}.{n}`), so the test is the prefix.
      ;;
      ;; The reader's PLACE is dropped with the rows and said by `%anchor-lose` at the next
      ;; paint: this head's anchor is a row identity, and the row it named is the one that just
      ;; went. (The reference takes a CARRY here — the row's own words, to be re-found under
      ;; the new id — which is `53ac610`'s work and is filed; until then the honest fallback is
      ;; the sentence, which is what `%anchor-lose` is for.)
      ((:transcript-forked)
       ;; the arm's VALUE, not an early return: `apply-event` measures the seq gap after the
       ;; fold, and a fork that returned from inside would skip it — the shape its own comment
       ;; records as a defect once already ("a gap does not swallow the event that revealed it").
       (let* ((parent (or (getf env :parent-id) ""))
              (gone (and (plusp (length parent)) (concatenate 'string parent ".")))
              (items (session-items session)))
         (if (and gone
                  (some (lambda (i) (let ((id (item-id i)))
                                      (and (stringp id)
                                           (>= (length id) (length gone))
                                           (string= gone id :end2 (length gone)))))
                        items))
             (progn
               (setf (session-items session)
                     (coerce (remove-if (lambda (i)
                                          (let ((id (item-id i)))
                                            (and (stringp id)
                                                 (>= (length id) (length gone))
                                                 (string= gone id :end2 (length gone)))))
                                        (coerce items 'list))
                             'vector)
                     *scroll-anchor* nil)
               (incf *hist-generation*)
               :dirty)
             :quiet)))
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
         ;; **AND THE REASONING HANDS OVER THE WAY THE TEXT DOES, because it had no handover at
         ;; all.** The text is cleared below by the row that took it over; the reasoning was cleared
         ;; by NOTHING — not here, not at `turn_finished` — which did not matter while `apply-event`
         ;; kept it only at `:normal` and this head draws at `:reading`. With the count live at every
         ;; rung it matters three times in the last second of a turn, and a replay of a real
         ;; recorded one (`tests/fixtures/tool-short.jsonl`) shows all three:
         ;;
         ;;     tool_finished       live=(:CALLS 1 :RUNNING 0 :THINKING 2)  [1 tool call, 2 thinking lines]
         ;;     transcript_content  live=(:CALLS 1 :RUNNING 0 :THINKING 2)  [1 tool call, 4 thinking lines]
         ;;     transcript_content  live=(:CALLS 1 :RUNNING 0 :THINKING 2)  [2 thinking lines] [1 tool call, 2 thinking lines]
         ;;     turn_finished       live=(:CALLS 0 :RUNNING 0 :THINKING 2)
         ;;
         ;; **the number DOUBLES** as the row lands — the row counts the reasoning and the live copy
         ;; counts the same text again, 2 → 4 for one 2-line thought — **a second marker appears**
         ;; (the run's above the assistant row and the live counts ON it: one stretch of work drawn
         ;; twice), and **the live copy outlives the turn** (nothing clears it, so `turn_finished`
         ;; leaves it at `:THINKING 2` until the next turn replaces the turn object). Three
         ;; frame-to-frame changes in one second, which is the operator's *"it flickers on when you
         ;; stop replying - the very end."*
         ;;
         ;; The guard is `:appended` membership and not the body's kind, for the same reason the
         ;; text's is: a snapshot's history, or a row from a turn already closed, must not empty the
         ;; LIVE turn. And the row arrives whole — one reasoning row per round — so the handover is
         ;; exact, and the marker's number does not move as it happens.
         (when (and body (string= (getf body :type) "reasoning"))
           (let ((turn (session-turn session)))
             (when (and turn
                        (member (getf env :item-id) (getf turn :appended) :test #'equal))
               (setf (getf turn :reasoning) ""))))
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
                     ;; **Whose call this is, when it is not this session's own.**
                     ;; Present on the wire for exactly one case (event.rs:826-842,
                     ;; R58): a subagent's gate reached an `ask`, and the card was
                     ;; posted to the tree's ROOT, because a child has no head of its
                     ;; own — and **a card that arrived at the root unlabelled would
                     ;; be answered for the wrong thing** (event.rs:746). The decoder
                     ;; passes the plist through untouched (`:handle`, `:task`,
                     ;; `:root`); the card draws it — see `permission-card-lines`.
                     ;; Absent is this session's own call, which is every card from a
                     ;; daemon older than the field, and draws nothing new.
                     :subagent (getf env :subagent)
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
       ;;
       ;; **AND `mode_set` UPDATES THE SETTINGS CACHE** — the daemon confirms a mode change with
       ;; this warning but does not push a fresh settings frame, so `head-settings` still holds
       ;; the OLD mode and the picker reads from it. The operator: *"allow-all selection doesnt
       ;; survive anymore"*. The detail is the daemon's own sentence (`"<said>. <summary>"`),
       ;; and the new mode name is the FIRST WORD before the first `.` — parsed from the detail
       ;; because that is the only place the daemon says it on this event. The `head-settings`
       ;; row's `:value` is set to the whole detail (it is the most honest rendering of what the
       ;; daemon said), and `pick-current` takes the first word as the mode name.
       (when (and (string= (or (getf env :code) "") "mode_set")
                  *payload-head*
                  (head-settings *payload-head*))
         (let* ((detail (or (getf env :detail) ""))
                (dot (position #\. detail))
                (mode (if dot (subseq detail 0 dot) detail)))
           (when (plusp (length mode))
             (let ((row (find "mode" (head-settings *payload-head*)
                             :key (lambda (r) (getf r :key)) :test #'string=)))
               (when row
                 (setf (getf row :value) detail))))))
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
           ;; **AND A WEATHER NOTE IS RECORDED, POINTED AT, AND NOT DRAWN.** See
           ;; `+weather-warnings+` for the rule and for why letibot's `Class::Routine` is not the
           ;; test — a compaction is routine and stays a row, because it changes the conversation.
           ;;
           ;; The RECORD is kept: `/notes` lists the sentence in full and `warning-identity` still
           ;; retires it, so the diagnostic the operator calls important is one keypress away.
           ;; What goes is the row, which was landing in the middle of a streaming turn — exactly
           ;; the region `f3a1152`, `5d0d201`, `58d5ead` and `94895bb` had just made predictable,
           ;; and the likeliest cause of *"leticl has troubles with thinking lines stat after it."*
           ;;
           ;; `:dirty` and not `:quiet`: the `⚠` DOES change on this frame, and calling a frame
           ;; that gained a mark "filtered" would say nothing happened on a screen that just showed
           ;; something.
           ((member (getf w :code) +weather-warnings+ :test #'string=)
            (push w (session-warnings session))
            (incf *weather-notes*)
            :dirty)
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
       (dash-note-job env *head*)
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
