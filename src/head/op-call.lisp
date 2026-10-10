;;;; op-call — the operator-call door (R24 part two)
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------ the operator-call door (R24 part two) ;;;
;;;
;;; **The split contract, and which half is whose.** The daemon names and ENFORCES the
;;; tools a head may run for the operator, writes the ADMISSION before anything happens,
;;; and appends the row. The head is *the environment that can reach what the daemon
;;; cannot* — it runs the call in its own process, on the operator's own machine, and
;;; hands the outcome back through the same writer a turn's rows go through, so the model
;;; sees it and every head draws it as the person's act.
;;;
;;; Two frames and one event, and the ORDER is the whole requirement: asking is not
;;; permission (`Accepted` says *queued*), and the permission is the
;;; `operator_call_allowed` event, which arrives only once the daemon has WRITTEN the
;;; admission. A head that ran on `Accepted` can have run a call whose admission never
;;; got written — which is a row in the corpus claiming the operator decided something
;;; they did not.

(defparameter +op-call-wait-ms+ 30000
  "How long this head waits for an answer to one `operator_call` before it says so.

Not a network timeout: `Rejected` and `Accepted` come back on the same connection in
the same read loop, and the `operator_call_allowed` event follows the admission write.
Generous because the call may sit QUEUED behind a running turn — which is exactly why
the sentence differs when an `Accepted` was heard (see `tick-op-calls`).")

(defvar *head-tool-runners* nil
  "NAME → how THIS head runs it, as an alist of `(name . function)`.
The function takes `(head arguments-json)` and returns `(values outcome payload)`,
`outcome` a `ToolOutcome` wire word.

**Empty, and `/run` says so rather than pretending.** R24 part two is a split
contract: the daemon names the door, and the head's REACH is the head's to implement.
No fetcher is a separate landing — this head's only socket is a unix one, so reaching
an https URL means a TLS stack in a zero-dep image — and a head with no runner must
NOT ask, because the admission it would be asking for is a corpus row saying the
operator decided to run something this head then cannot run. `%op-call-ask` refuses
before the frame goes out, which is the only cheap place to refuse it.

A runner is a pure function of its arguments, so the suite binds this rather than
measuring the network (`the-answer-runs-the-call…`).")

(defvar *op-calls* nil
  "The operator-run calls this head has ASKED for and not yet finished with, newest
first; each a plist `:call-id :name :arguments :client-request-id :asked-at :deadline
:accepted :told`.

**An entry outlives its deadline**, and that is deliberate: *the daemon never answered*
is a sentence this head says, not a reason to forget what it asked. A permission that
lands after the head has said so still runs the call, because the admission exists and
running on it is what the protocol says to do. Only a `Rejected` or the permission
itself takes an entry away.

A defvar and not a head slot: a struct layout change is a restart, and this has to
live through a push. Bound by `with-replay-globals`, so two replays in one image
cannot inherit each other's asks.")

(defun %op-call-runner (name)
  "How this head runs NAME, or NIL when it has no way to."
  (cdr (assoc name *head-tool-runners* :test #'string=)))

(defun %op-call-entry (key &key request)
  "The pending call whose `call-id` is KEY, or whose `client-request-id` is KEY when
REQUEST is true. NIL when this head never asked — which is the answer for another
head's call on the same session, and is why both matchers exist."
  (find key *op-calls*
        :key (lambda (e) (getf e (if request :client-request-id :call-id)))
        :test #'equal))

(defun %op-call-ask (head name arguments)
  "Ask the daemon to admit running NAME with ARGUMENTS for the operator. The call id, or
NIL when nothing went out — with the reason said either way.

**Nothing is sent unless this head can run it.** The daemon's answer would be an
admission, and an admission is a corpus row saying the operator decided to run this;
asking and then failing would put a decision on the record that nobody could carry out.
So the door is checked here too, and so is the runner — refusal is free on this side and
a retraction is not available on that one."
  (let ((door (head-run-tools (head-settings head))))
    (cond
      ((null door)
       (say head "this daemon offers no operator-call door — it has published no tool list, so nothing was asked for")
       nil)
      ((null (%op-call-runner name))
       (say head (format nil "this head cannot run `~a` itself~@[ — it can run ~{~a~^, ~}~] — so nothing was asked for, and no decision was recorded"
                         name (remove name door)))
       nil)
      (t
       (let* ((call-id (next-call-id))
              (frame (make-operator-call call-id name arguments
                                         (session-expected-seq (head-session head))))
              (now (internal-real-time-ms)))
         (%send head frame)
         (push (list :call-id call-id :name name :arguments arguments
                     :client-request-id (getf frame :client-request-id)
                     :asked-at now :deadline (+ now +op-call-wait-ms+)
                     ;; **BOTH PRESENT AND NIL, and that is load-bearing.** A `setf` of
                     ;; `(getf entry :accepted)` on a key that is ABSENT pushes a cons onto
                     ;; the list and stores the new head in the LOCAL variable, so the
                     ;; record would be lost and the eventual sentence would say *never
                     ;; answered* about a call the daemon had queued. Measured by
                     ;; `an-accepted-call…` failing exactly that way.
                     :accepted nil :told nil)
               *op-calls*)
         (say head (format nil "asked the daemon to admit `~a` (~a) as your act — nothing runs until it says the call was admitted"
                           name call-id))
         call-id)))))

(defun %payload-size (payload)
  "PAYLOAD as the account of what a deposit is about to cost (R31 (e)).

**R31: *it spends the window, visibly. A 40k-token page is 40k of context the operator chose
to buy — the size is shown before it lands, because the alternative is discovering it at the
next compaction.***

    `12 lines · 1.19k bytes · ~305 tokens`

**Bytes and lines are FACTS; the token count is an ESTIMATE and is marked as one.** This head
has no tokeniser and will not carry a model's vocabulary to draw a number — but the unit the
requirement speaks in (*40k-token page*) is the one the operator spends context in, so a size
said only in bytes would be a number they have to convert. Four bytes a token is the usual
rule of thumb and a `~` says so."
  (let* ((text (or payload ""))
         ;; **`sb-ext:string-to-octets`, the same call `%fnv1a-64` already makes** for the same
         ;; reason: letibot measures bytes and a head that measured characters would report a
         ;; different size for the same page the moment it contains `→` or `—`.
         (bytes (length (sb-ext:string-to-octets text :external-format :utf-8)))
         ;; **A TRAILING NEWLINE IS A TERMINATOR, NOT ANOTHER LINE.** `split-string` answers a
         ;; final empty piece for one, so a 40-line page came back as 41 and the number the
         ;; reader was shown overstated what they bought — by one, which is exactly the kind of
         ;; number nobody checks. One trailing empty piece is dropped; the newlines INSIDE the
         ;; text still count, because those are lines the reader sees.
         (pieces (uiop:split-string text :separator '(#\newline)))
         (lines (if (and (cdr pieces) (string= "" (car (last pieces))))
                    (1- (length pieces))
                    (length pieces))))
    (format nil "~d line~:p · ~,2f bytes · ~~~d tokens"
            lines (float bytes) (ceiling bytes 4))))

(defun %op-call-answer (head env)
  "**The only thing in this head that RUNS a call.** Folded from the
`operator_call_allowed` event, which the daemon publishes after it has written the
admission.

**The event's words are the ones used**, not the ones this head asked with: the record
is the daemon's, and `who` — the identity of the person the hub sees — is a fact only the
event carries. Its `arguments` fall back to this head's own only if the event somehow
carries none, so a run is never attempted with nothing.

**The result goes out before anything is said.** The window between the run and the row
is the only part of this protocol a head can shorten, and it is the part a later reader
is missing if this head dies inside it — the admission is already on the record saying a
call was permitted, so the outcome is the half that would be absent (`op-<call-id>` is
what a reader has otherwise)."
  (let ((entry (%op-call-entry (getf env :call-id))))
    (when entry
      (setf *op-calls* (remove entry *op-calls*))
      (let* ((name (or (getf env :name) (getf entry :name)))
             (who (getf env :who))
             (args (or (getf env :arguments) (getf entry :arguments) "{}"))
             (runner (%op-call-runner name)))
        (multiple-value-bind (outcome payload)
            (if runner
                (handler-case (funcall runner head args)
                  ;; **A runner that blows up is an OUTCOME, not a lost call.** The
                  ;; admission is written and the daemon holds the entry as pending;
                  ;; a head that let the error reach the loop would send no result at
                  ;; all, leaving the model with nothing and the daemon with a
                  ;; permission nothing consumed.
                  (error (e) (values "failed" (format nil "this head could not run it: ~a" e))))
                (values "failed" (format nil "this head has no runner for `~a`, so it did not run" name)))
          ;; **THE SIZE IS MEASURED BEFORE ANYTHING GOES OUT** (R31 (e)), and measured HERE
          ;; because here is the only moment it exists: the payload is this head's from the
          ;; instant the runner returns to the instant the frame leaves.
          ;;
          ;; **What this head CANNOT do, said rather than implied.** R31 asks for the size
          ;; "before it lands", and on the wire that means before the `operator_result` —
          ;; which this head may not delay. The frame goes out FIRST and that ordering has its
          ;; own recorded reason (see the docstring: the deposit is what a later reader is
          ;; missing if this head dies inside the window). So the ordering here is
          ;; *measured, then sent, then said*: the number is composed before the deposit is
          ;; committed, and both reach the screen together. **A VETO is not available in this
          ;; protocol** — the daemon admitted the call and waits for an outcome, and the only
          ;; way to withhold the payload is to answer `abstained`, which would be this head
          ;; deciding the operator's window for them. That is a design with its own argument
          ;; (a decision card, or a stated budget) and it is filed rather than invented here.
          (let* ((size (%payload-size payload))
                 (said (if (string= outcome "ok")
                           (format nil "ran `~a` as ~a — ~a, in the conversation"
                                   name (or who "you") size)
                           (format nil "`~a` as ~a did not go through (~a) — ~a"
                                   name (or who "you") outcome size))))
            ;; FIRST on the wire, then the sentence.
            ;;
            ;; **AND A FAILURE ALWAYS CARRIES A REASON, even when the runner did not write one.**
            ;; `make-operator-result` refuses a bare `failed` because the daemon does (*missing
            ;; field `reason`*) and its read loop goes with it — so a runner that answered `failed`
            ;; with an empty payload would otherwise turn its own report into the end of the session.
            ;; The stand-in is a fact about this head and says so, rather than a frame that kills
            ;; the connection.
            (%send head (make-operator-result (getf env :call-id) outcome payload
                                              :reason (and (string= outcome "failed")
                                                           (if (and payload (plusp (length payload)))
                                                               payload
                                                               "the runner did not say why"))))
            (say head said)))))))

(defun tick-op-calls (head)
  "Say the wait out loud, once, for any call the daemon has not answered.

Two silences and two sentences, because they are different facts: a call the daemon
never even acknowledged is not in its queue, while one it `Accepted` IS queued — behind
a turn, perhaps — and *never admitted* would be a claim this head cannot make about it.
**The entry is not dropped either way**: this is a sentence, not a decision to forget,
and a permission that arrives afterwards still runs the call, because the admission
exists and running on it is exactly what the protocol asks for. Only a `Rejected` or the
permission itself retires an entry."
  (let ((now (internal-real-time-ms)))
    (dolist (entry (copy-list *op-calls*))
      (when (and (not (getf entry :told)) (>= now (getf entry :deadline)))
        (setf (getf entry :told) t
              (head-dirty head) t)
        (say head (if (getf entry :accepted)
                      (format nil "the daemon queued `~a` (~a) and has not admitted it yet — nothing has run. If it is admitted later this head will run it"
                              (getf entry :name) (getf entry :call-id))
                      (format nil "the daemon never answered `~a` (~a) — nothing ran, and it was not re-sent under a new id"
                              (getf entry :name) (getf entry :call-id))))))))

(defun %op-call-accepted (head frame)
  "An `Accepted` for an operator call: QUEUED, and NOT permission. Records it and says
nothing — the ask's own sentence already promised that nothing runs until it is admitted,
and a second line for the routine cue is the noise the reference suppresses for a queued
prompt. The record matters: it is what makes the eventual silence say the true sentence."
  (let ((entry (%op-call-entry (getf frame :client-request-id) :request t)))
    (when entry (setf (getf entry :accepted) t (head-dirty head) t))
    entry))

(defun %op-call-refused (head frame)
  "A `Rejected` for an operator call — the name is not in the door. Returns the entry when
it was ours (the caller says the reason), or NIL for a rejection that belongs to some
other ask.

**No retry, and the reason is the daemon's own sentence** naming what was asked for, the
names the door accepts, and that nothing ran. A head that retried, or that asked again
under a fresh id, would be negotiating with the list the daemon does not negotiate —
and the list is the daemon's to hold precisely so a head cannot widen it."
  (let ((entry (%op-call-entry (getf frame :client-request-id) :request t)))
    (when entry (setf *op-calls* (remove entry *op-calls*)))
    entry))

(defun %answer-screen-requests (head)
  "Answer every queued `screen_requested` with the rows this head just PAINTED.

*\"A tool asked what the operator is looking at; this is the only place in the
system that knows, because it is the place that put the bytes on the terminal\"*
(driver.rs:93-99). Called after the paint, never during the drain: the arm that
answered from `head-last-rows` while the frames were still arriving sent the
PREVIOUS frame — one tick stale at rest, and simply the wrong screen across a
resize or a pane change, which is the one thing this frame exists to report.
Oldest request first."
  (when (head-screen-reqs head)
    ;; **THE ROWS AND THE SIZE COME FROM THE SAME PAINT.** The size is a required
    ;; argument of `make-screen-answer` and not derived from a row's length, because
    ;; that derivation reported the character count of row zero with its escape bytes
    ;; in it. `head-last-cols`/`head-last-rows-n` are set beside `head-last-rows` by
    ;; `%render-and-paint`, so all three describe one frame; before any paint there is
    ;; no frame to describe, and the head's own size is the honest answer.
    (let* ((painted (head-last-rows head))
           (cols (if painted (head-last-cols head) (head-cols head)))
           (rows-n (if painted (head-last-rows-n head) (head-rows head)))
           (rows (or painted (list (make-string (max 1 cols) :initial-element #\space)))))
      (dolist (req (nreverse (head-screen-reqs head)))
        (%send head (make-screen-answer req cols rows-n rows)))
      (setf (head-screen-reqs head) nil))))

(defparameter *idle-poll-ms* 0.002
  "How long the loop waits when there is nothing to do. **This number IS the head's input
latency**, and it was 30 ms until the operator said scrolling *\"feels sluggish, steppier\"*.

**MEASURED, all three at the operator's own size (63 rows x 210 cols, an 87-item transcript):**

  · a full `%render`: **0.07 ms** — so render alone could sustain ~15,000 passes/s;
  · an idle pass (`tick-notice`, both dash ticks, both drains, `live-frame-due-p`): **under
    0.001 ms**, i.e. below the timer's resolution — free;
  · the old `(sleep 0.03)`: **30 ms**, about 430 times the cost of the work it guarded.

**RE-MEASURED 2026-10-04, AND THE FIRST AND SECOND NUMBERS WERE BOTH TOO KIND — the THIRD is what
stands.** On a running head with a real terminal and a real daemon (pid 2536078, 257 items): 5158
passes in 10 s at 30 ms of CPU, which is **about 6 us a pass** — 516 passes/s, ~0.3% of a core — and
a frame is **2.1-2.6 ms** at 214x60 with anything live on it (the 0.07 ms reading was an 87-item
transcript and nothing moving; `render.lisp`'s header carries the correction). So a pass is not free
and a frame is not the resolution of a timer. **The number below is still right, and by the same
argument at a smaller multiple:** 30 ms was ~5,000x the work it guarded, and 2 ms is ~330x, so the
wait is still the largest thing in the loop and the thing to shrink. What the correction costs is the
claim that a pass is free — a pass is cheap, and 500 of them a second is the price of the wake-up
rate, not of the work.

**WHY THE OLD NUMBER WAS SO BAD, and it is the second half of the diagnosis.** A paint CLEARS
`head-dirty`, so the pass after a paint had nothing to do and slept again. That made the loop's
event ceiling **one wheel event per 30 ms — 33 a second** — however fast input arrived. A trackpad
sends far more than that, so events queued and each paint jumped by however many had accumulated:

  · *sluggish* — the first notch waited up to 30 ms to be read at all;
  · *steppier* — the scroll moved in 3N-row jumps at 33 Hz instead of 3-row steps at the rate the
    finger actually moved.

Two symptoms, one number.

**POLLING IS THE RIGHT SHAPE HERE, and the measurement is why that is not a contradiction.** The
usual objection to a polling loop is that it spends CPU discovering there is nothing to do; at 500
wakeups/s of ~6 us of work that is about 0.3% of a core, and the sleep's own syscall is most of the
rest. An event-driven loop would have to wait on the KEYS mailbox, which cannot wake it for a daemon
FRAME — so it would trade an *input* latency of 2 ms for a *frame* latency of whatever that wait was,
and a frame latency is a streaming reply's responsiveness. Polling both queues at a rate above any
input device's is simpler and strictly better while a pass costs microseconds; **the in-turn CPU the
operator reported was never this loop** — see PERF.md.

**A `defparameter` and not a `defconstant`**, for the reason every tunable in this tree is: the file
pusher skips constants, so a `defconstant` could not be recompiled to a new value on a live image.

**BUT THE DOCSTRING'S FIRST VERSION OVERCLAIMED, and the measurement that caught it is worth
keeping.** It said the value could never be changed on a running head were it a constant — true —
and implied the SAME about this parameter being live, which is FALSE for this variable in a way it is
not for `*scroll-notch*`. MEASURED: pushed to a running head, `*loop-passes*` stayed at 0 while the
head kept painting, because **the loop is executing its old body**. CL does not re-enter a function
that has been redefined under a running call, and `run-loop` is entered once and runs for ever. So:

  · the 30 ms wait is still in force on the head that was already running when this landed — **this
    change needs a head RESTART, and it is one of the few here that does**; and
  · once restarted, `(setf *idle-poll-ms* …)` takes effect on the very next pass, because the loop
    reads it every time round rather than capturing it.

That distinction — a value read per pass versus a body already running — is the whole reason this
paragraph exists rather than a line saying \"live\".")

(defvar *loop-passes* 0
  "How many times the main loop has come round. **The instrument for the loop's own PERIOD**, which is
what `*idle-poll-ms*` sets and what the operator's sluggish-scroll complaint was about: a FRAME count
answers *how fast does it draw*, and this answers *how often does it look at the input at all*.

**MEASURED, both sides, on a real head running the real loop with no daemon and no terminal** (an
idle head has nothing dirty and nothing live, so it takes the branch under test every pass):

    wait 30 ms  ->   69 passes in 2.0 s =   34 passes/s, 28.99 ms per pass
    wait  2 ms  ->  974 passes in 2.0 s =  487 passes/s,  2.05 ms per pass

So the change is **14x**, and a pass is now 2.05 ms against a wait of 2.00 ms — the wait and the work
are finally the same order, where before the wait was 400x the work. The OLD reading also
corroborates `+notice-ttl-ms+`'s docstring, which got ~38 passes/s from the note-expiry instrument on
an idle screen: 34 and 38 are one configuration measured twice by two methods.

**THE FIRST ATTEMPT AT THIS MEASUREMENT WAS WRONG IN A WAY WORTH KEEPING.** It `let`-bound
`*idle-poll-ms*` for the old value and reported 486 and 486 — because `run-loop` runs in its OWN
THREAD, and a thread does not inherit the parent's dynamic bindings. **Two identical numbers read as
agreement rather than as a probe measuring one configuration twice.** `setf` on the global is what the
second attempt used.

**And this counter could not confirm anything on the head it was pushed to** — `*loop-passes*` stayed
at 0 there while the head kept painting, because that head's loop is executing its OLD body. That is
itself the measurement that proved a restart is needed, and it is why the reading above is from a
THROWAWAY head rather than from the live one.

A `defvar`, so a live push does not reset a running head's count.")

(defvar *frames-painted* 0
  "How many frames this head has painted. **The instrument for this class of question**, and it did
not exist when scrolling was reported as sluggish: `*idle-poll-ms*` is only justifiable against a
pass cost, and a pass cost is only measurable against a count of passes. A `defvar` for the house
reason — a live push must not reset a running head's count.")

(defvar *code-generation* 0
  "Bumped by every live push, so a cache that holds **what CODE derived from a file** can tell that the
code changed.

**THE TRAP THIS EXISTS FOR, MEASURED on the operator's own head.** `*repo-todo-cache*` in
`panes.lisp` validates itself against the FILE — the path and an `(mtime, len)` stamp — which is the
right key for the file being edited while somebody watches it. It is the WRONG key for a live push:

  1. the pane reads `TODO.md` with the code that is loaded, and caches the rows;
  2. a push redefines `read-todo-md` so its rows carry `:line`, the number the surgical edit and the
     `i` composition both address the file by;
  3. the file has not changed, so the stamp matches, so the cache is trusted — and the pane keeps
     drawing rows the OLD code produced, twenty of them with `:line` NIL;
  4. `i` then refuses **on every repo row**, with a sentence that blames the row (*\"that row cannot be
     addressed in the file\"*) rather than the cache — a false refusal, on the good rows.

That is the third face of the same hazard `tui-eval`'s own docstring records twice: the render gate
checks that the head can PAINT, not that the change is LOADED, and this one is neither — the change is
loaded and a value derived from the old one is still live. A cache with a generation is the fix
`*hist-generation*` already carries for the DATA version of this question; this is the CODE version.

A `defvar`, so a push does not reset the counter (which would invalidate every cache on every push
rather than only the caches that must be).")

(defun paint-wanted-p (head)
  "Does anything want a frame THIS pass? — the one place the freeze is enforced.

**Three reasons, and a held view outranks two of them.** A frame is wanted when an event set
`head-dirty`, or when the clock says something on the screen is a function of time (`live-frame-due-p`,
R13), or when a view that is HELD owes exactly one frame — the one that draws the marker saying so
(`*frozen-frame*`, spent by the paint itself).

**While `*frozen*` the first two do not count**, and that is the whole of the contract: one written
cell is one lost selection, so a frozen head writes NOTHING — not a spinner, not a clock, not a
counter that ticks. The events keep arriving and the head keeps folding them; it simply stops
drawing, which is the one thing about this that needs no protocol.

The loop's else-branch sleeps on a NIL from here, **including while frozen with a frame waiting**: a
head that skipped the paint and also skipped the sleep would spin a core for as long as the reader
holds the screen. And because `head-dirty` is NOT cleared by a frame that was never drawn, the
release paints the whole accumulated state in one pass — which is what *follows again* means."
  (or *frozen-frame*
      (and (not *frozen*) (or (head-dirty head) (live-frame-due-p head)))))

(defparameter *peek-poll-ms* 1000
  "How often a peeked subagent's scrollback is re-read while its pane is open.

**The pane TAILS now, and this is what makes it a tail rather than a snapshot.** It read ONCE — the
footer said `Enter re-reads` and that was the whole of it — so a child still working showed whatever
it had produced at the moment somebody opened it, and nothing after. The operator: *\"when i 'enter'
subagent i do not want to hit enter to refresh the view i want it to tail as a normal conversation
while i look at it.\"*

One second, because it IS a tail: the reply is bounded (the daemon's ring, already read once) and the
head already polls for exactly this shape of absence — *its progress has no push path at all, it has
to be asked for*, `tick-dash-feeds`. The daemon has no subscription for a session this head is not
attached to, so asking again is the only way there is; if one ever lands, this is the function that
goes.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so this could never be
tuned on a running head.")

(defvar *peek-asked-at* 0
  "When the peek last asked, on the loop's clock — so a pane that is open asks once a second and not
once a pass. A defvar, and not reset by a session change: the next ask is a second away at worst.")

(defun tick-peek (head)
  "Re-read the peeked subagent's scrollback while its pane is open — see `*peek-poll-ms*`.

**Only while the pane is OPEN**, and only when a clock is running. A head that kept asking after one
`/peek` would read a child's scrollback for the rest of the session, which is the accumulation T24 is
written about; and a replay has no clock, so it must not ask at all — the bytes it answers with have
to be the bytes it was given."
  (when (and (plusp *now-ms*)
             (eq (head-mode head) :peek)
             *peeked-session*
             (<= (+ *peek-asked-at* *peek-poll-ms*) *now-ms*))
    (setf *peek-asked-at* *now-ms*)
    (%send head (make-peek *peeked-session*))))

(defun run-loop (head)
  (loop while (head-running head)
        do (let ((rendered 0)
                 (filtered 0)
                 (last-seq 0))            ; the read mark, from step 1 only
             ;; the clock, and the arrival of anything at all: the stall line is
             ;; about the DAEMON going quiet, so it is measured from the last
             ;; frame to land, on OUR clock and not on the event's own `ts`
             (setf *now-ms* (internal-real-time-ms))
             (incf *loop-passes*)
             (tick-notice head)
             ;; **the wait for a daemon this head asked to stop** — before the
             ;; drain, so the row it marks dirty is painted in THIS pass, and so
             ;; the pass that ends the loop is the one that says why
             (tick-stop-request head)
             ;; **the wait for an operator call this head asked for** — beside the stop's
             ;; wait, for the same reason: a silence with a deadline has to be said, and
             ;; the pass that says it must be the pass that paints it
             (tick-op-calls head)
             ;; **THE DASHBOARD'S JOB FEED** — and it runs HERE, on the main loop, because that is
             ;; the thread that owns the socket. A job's ENDING arrives as an event; its PROGRESS
             ;; has no push path at all (`JobOutput` is published only in reply to a read), so it
             ;; has to be asked for, and the asking cannot come from the collector thread
             ;; (`leticl-dash-collector`) without writing a frame from a thread that does not own
             ;; the connection. See `tick-dash-feeds`.
             (tick-dash-feeds head)
             ;; **AND A SUBAGENT'S SCROLLBACK, WHILE ITS PANE IS OPEN** — the same shape of absence as
             ;; the job feed above: the daemon has no subscription for a session this head is not
             ;; attached to, so a peek is a read and the pane tails by asking again.
             ;; the header's git reading, on the same beat as the peek's tail — both are
             ;; measurements this head takes for itself, and neither belongs in a paint
             (tick-git head)
             (tick-peek head)
             ;; **AND THE WATCHERS' LIFECYCLE** (R56), on the same thread for the same reason: it asks
             ;; for the job list while something is waiting, and asking is `%send`. It is also where a
             ;; job-bound watcher STARTS the collector — an import that runs for hours cannot have its
             ;; history begin when somebody happens to open the pane and looks at it.
             (tick-dash-watchers head)
             ;; 1. drain. An error while FOLDING a frame must not kill the loop
             ;; either: a frame this head cannot handle is one bad frame, not a
             ;; reason to lose the session. The failure is remembered so the
             ;; gate can say so, and the loop reads the next one.
             (dolist (frame (%drain (head-frames head)))
               (note-frame-arrived)
               ;; `(%frame-p frame)`, not `(consp frame)`: the reader pushes
               ;; `(:disconnected)` — a ONE-element list — and `frame-name` calls
               ;; `(getf frame :frame)` on it, which is a malformed plist and a
               ;; TYPE-ERROR in the main thread. With --disable-debugger that is
               ;; not a wrong frame, it is a head that refuses to start: measured,
               ;; `leticl` exited at launch for 45 minutes of this session.
               ;; A frame is a plist whose car is `:frame`; nothing else is one.
               (when (%frame-plist-p frame)
                 (when (and (string= (frame-name frame) "event")
                            (getf frame :seq))
                   (setf last-seq (getf frame :seq))))
               (handler-case
                   (case (%handle-frame head frame)
                     (:rendered (incf rendered) (incf *rendered-total*))
                     (:filtered (incf filtered) (incf *filtered-total*))
                     (t nil))
                 (error (e)
                   (setf *last-render-error* e
                         (head-dirty head) t))))
             ;; **WHEEL NOTCHES ARE COALESCED INTO ONE MOVE PER PASS** — `%wheel-batch` holds the rule
             ;; and its measurements; this is only the ordering that rule requires. The non-wheel keys
             ;; go first, in arrival order, so an `esc` or a printable key that changes what a notch
             ;; MEANS is applied BEFORE the gesture — the gesture lands on the view it was made on.
             ;;
             ;; **AND THE WHOLE BATCH IS INSIDE A GUARD, WHICH IS A REGRESSION THIS EXTRACTION CAUSED
             ;; AND ITS OWN REPORT CAUGHT.** The inline version had every key inside a `handler-case`;
             ;; writing the batch as a call put `%drain` and `%wheel-batch` OUTSIDE it, so an error
             ;; raised while merely READING or CLASSIFYING a key escaped `run-loop` — and with
             ;; `--disable-debugger` an unhandled error on the main thread prints the condition and
             ;; QUITS THE HEAD. The operator's report was *"it was complaining about wrong character
             ;; code while i was typing"* and a restart. The outer `handler-case` is the fix: nothing
             ;; a KEY can do — being malformed, unreadable, or unclassifiable — may take the head down,
             ;; which is the same rule `%handle-key`'s own guard has always followed.
             (handler-case
                 (multiple-value-bind (others wheel-kind wheel-notches)
                     (%wheel-batch (%drain (head-keys head)))
                   (dolist (key others)
                     (handler-case (%handle-key head key)
                       (error (e) (ignore-errors (say head (format nil "key error: ~a" e))))))
                   (when (and wheel-kind (plusp wheel-notches))
                     (handler-case
                         (%handle-key head (list :type :mouse :kind wheel-kind
                                                 :notches wheel-notches :x 0 :y 0))
                       (error (e) (ignore-errors (say head (format nil "key error: ~a" e)))))))
               (error (e) (ignore-errors (say head (format nil "key batch error: ~a" e)))))
             (handler-case (%poll-resize head)
               (error (e) (ignore-errors (say head (format nil "resize error: ~a" e)))))
             ;; `*replaying*`: a replay has no socket to come back to, and
             ;; "not connected" there is the normal state rather than a loss
             (unless (or *replaying* (head-connected head))
               (%try-reconnect head))
             ;; **A DAEMON THAT TOOK THE CONNECTION AND SAID NOTHING IS NOT AN
             ;; ABSENT ONE.** Past the deadline the head stops waiting and says
             ;; which of the two it is looking at, naming the two commands that
             ;; reach a daemon from outside (`attach-gave-up-said`). Set AFTER the
             ;; reconnect attempt: a socket that died mid-wait is the reconnect
             ;; path's business, and this is about one that is alive and mute.
             (when (attach-overdue-p)
               (setf (head-farewell head) (attach-gave-up-said)
                     (head-running head) nil))
             ;; 2. draw (guarded in %render-and-paint: a render error paints
             ;; itself and the loop carries on, so the operator can see what
             ;; broke and re-push instead of losing the head)
             ;;
             ;; **TWO reasons to paint, and only one of them is an event.** An
             ;; event sets `head-dirty`; the CLOCK asks for a frame while anything
             ;; on it is a function of time, because a number computed from
             ;; `*now-ms*` and never asked for is a number drawn once (R13 — see
             ;; `live-frame-p`). An idle head has neither, so it waits.
             ;;
             ;; **AND THE WAIT IS SHORT BECAUSE A PASS IS CHEAP — 6 us, MEASURED.** This was
             ;; `(sleep 0.03)`, and that single number was the whole of the head's input
             ;; latency — see `*idle-poll-ms*` for the three measurements, re-taken 2026-10-04.
             ;; The short version: a pass costs ~6 us and a full frame 2.1-2.6 ms at 214x60, so a
             ;; 30 ms sleep was ~5,000x the cost of the work it guarded and the 2 ms one is ~330x;
             ;; and because a paint CLEARS `head-dirty` the next pass slept again — capping the head
             ;; at one wheel event per 30 ms whatever rate the trackpad sent at.
             (if (paint-wanted-p head)
                 (%render-and-paint head)
                 ;; **AND THE SLEEP IS TAKEN WHENEVER NOTHING WANTS A FRAME — including while the
                 ;; view is HELD with a frame waiting.** A frozen head that skipped the paint and
                 ;; skipped the sleep would spin a core for as long as the reader holds the screen.
                 (sleep *idle-poll-ms*))
             ;; 2b. answer every screen request with the frame just painted
             (%answer-screen-requests head)
             ;; 3. ack, and only when a frame was actually read this pass: an
             ;; idle tick has no seq to report and must not invent one
             (when (plusp last-seq)
               (%send head (make-ack last-seq rendered filtered))))))

