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

(defun ingest-snapshot (session snapshot)
  "Replace state with SNAPSHOT's. Resync is a normal outcome, never an error
— this is also the Resync-frame path."
  (setf (session-session-id session) (or (getf snapshot :session-id) "")
        (session-seq session) (getf snapshot :seq)
        (session-expected-seq session) (getf snapshot :seq)
        (session-dropped session) (getf snapshot :dropped)
        (session-items-dropped session) (getf snapshot :items-dropped)
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
  "The sum of a `ScrubReport` plist's counts, or 0 for none."
  (loop for (nil v) on report by #'cddr when (integerp v) sum v))

(defun ingest-hello (session hello)
  (ingest-snapshot session (getf hello :snapshot))
  (incf *scrubbed-total* (%scrub-total (getf hello :scrubbed)))
  (setf (session-head-id session) (or (getf hello :head-id) "")
        (session-dropped session) (getf hello :dropped)
        (session-sessions session) (getf hello :sessions)
        (session-wiring session) (getf hello :wiring))
  ;; THE TITLE FROM THE SESSION LIST. Our `session-title` was only ever set by a
  ;; `session_renamed` EVENT, so a head that attached to a named session showed
  ;; its raw id in the header while letibot showed the name. Measured against
  ;; letibot's own screen: `▌ hello, what we are doing here` against
  ;; `▌ s-1789639478142928813`. The name is in the Hello's session list, which is
  ;; also what the picker reads.
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
  (vector-push-extend item (session-items session)))

(defun fill-item (session item-id body)
  (let ((hit (find-item session item-id)))
    (when hit (setf (getf hit :item) body))))

;;; ------------------------------------------------------------- turns ;;;

(defun turn-state-name (turn)
  (getf (getf turn :state) :state))

(defun call-view (turn call-id)
  (when turn
    (find call-id (getf turn :calls) :key (lambda (c) (getf c :call-id))
          :test #'string=)))

(defun ensure-call (turn call-id name target)
  "A call first seen as ToolStarted has no Proposed row behind it (view.rs on
CallView.target) — add it rather than dropping the fact it runs."
  (or (call-view turn call-id)
      (let ((call (list :call-id call-id :name name :target target
                        :args-digest "" :state (list :state "running"))))
        (push call (getf turn :calls))
        call)))

;;; ------------------------------------------------------ event application ;;;

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

(defun apply-event (session env)
  "Fold one envelope into state. Returns :dirty when something visible
changed, :quiet when not — the head loop paints on :dirty and acks on both."
  (let ((name (event-name env))
        (seq (getf env :seq)))
    (setf (session-seq session) seq
          (session-expected-seq session) seq)
    (case name
      ((:turn-started)
       ;; WHEN it started, on our own clock, so the composer's edge can say how
       ;; long this has been going. A turn that came out of a SNAPSHOT has no
       ;; start time — `*turn-started-ms*` stays NIL and the edge says "started
       ;; before this head attached" rather than a duration nobody measured.
       (setf *turn-started-ms* (and (not (getf env :snapshot)) (internal-real-time-ms)))
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
       (let ((turn (session-turn session)))
         (when turn (setf (getf turn :tokens) (getf env :tokens)))
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
       (let ((call (call-view (session-turn session) (getf env :call-id))))
         (when call (setf (getf call :progress-note) (getf env :note)))
         (if call :dirty :quiet)))
      ((:tool-finished)
       ;; stage what the live card knows, for the row that is about to land:
       ;; a settled ToolResult carries no duration and no timestamps at all
       (note-call-finished (getf env :call-id) :edit (getf env :edit))
       (let ((call (call-view (session-turn session) (getf env :call-id))))
         (when call
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
           (setf (getf turn :state)
                 (list :state "finished"
                       :finish-reason (getf env :finish-reason)
                       :usage (getf env :usage) :timings (getf env :timings))))
         :dirty))
      ((:turn-interrupted)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :state)
                 (list :state "interrupted" :reason (getf env :reason)
                       :partial-kept (getf env :partial-kept))))
         :dirty))
      ((:turn-failed)
       (let ((turn (session-turn session)))
         (when turn
           (setf (getf turn :state)
                 (list :state "failed" :error (getf env :error)
                       :partial-kept (getf env :partial-kept))))
         :dirty))
      ((:transcript-appended)
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
           (let ((settled (list :req-id (getf env :req-id)
                                :summary (getf req :summary)
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
       (push (list :head-id (getf env :head-id) :identity (getf env :identity)
                   :command (getf env :command) :note (getf env :note)
                   :ts (getf env :ts))
             (session-notices session))
       :dirty)
      ((:subagent)
       (push env (session-subagents session))
       :dirty)
      ((:job-settled)
       (push env (session-jobs session))
       :dirty)
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

(defun ack-frame (session rendered filtered)
  "The read mark. seq is the last seq consumed — this session's seq, whether
or not what arrived was rendered (cursor.rs)."
  (make-ack (session-seq session) rendered filtered))

;;; ---------------------------------------------------------- rendering ;;;

(defun item-display-text (item)
  "The text an item renders as, before wrapping. A row whose content never
arrived renders as a placeholder, honestly (view.rs on SnapshotItem.item)."
  (let ((body (item-body item)))
    (if (null body)
        (format nil "[~a — content not loaded]" (item-kind item))
        (case (intern (string-upcase (getf body :type)) :keyword)
          ((:system) (getf body :text))
          ((:user) (format nil "~{~a~}" (mapcar (lambda (p) (or (getf p :text) "")) (getf body :parts))))
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
