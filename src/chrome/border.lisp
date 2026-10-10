;;;; border — the top and bottom borders and what sits on them
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ---------------------------------------------------------------- border ;;;

(defun %workspace (s)
  "The session root with `$HOME` written as `~`.

Twelve columns of an eighty-column header spent on `/home/dead` is twelve
columns not spent on the session's name."
  (let ((ws (getf (session-wiring s) :workspace))
        (home (uiop:getenv "HOME")))
    (cond ((null ws) nil)
          ((and home (>= (length ws) (length home))
                (string= (subseq ws 0 (length home)) home))
           (concatenate 'string "~" (subseq ws (length home))))
          (t ws))))

(defun %session-position (s)
  "`1/71` — which of the daemon's CONVERSATIONS this is, of how many. The reference's
rule, from `header_line`: shown for one session too, because \"1/1\" is a fact —
this daemon holds one session and you are in it — where two absences are not.

**A SUB-SESSION IS LISTED AND NOT COUNTED**, and the two are one rule rather than two: the picker draws
a child under its parent with NO NUMBER, and this counts the numbered rows. The reason a child is
unnumbered is the one the old filter was reaching for — a session with twenty subagents must not turn
the header into `1/21` — and the reason it is listed at all is that a child is a session the operator
can attach to and be answered by: *\"subagent session is more like you driving others via tmux.\"*"
  (let* ((all (remove-if (lambda (b) (getf b :parent-session-id)) (picker-sessions s)))
         (at (position (session-session-id s) all
                       :key (lambda (b) (getf b :session-id)) :test #'equal)))
    (format nil "~d/~d" (if at (1+ at) 0) (max 1 (length all)))))

(defun %ellipsise-left (path room)
  "PATH shortened from its LEFT to ROOM columns: the end of a path is the part
that identifies it, and `~/Projects/…` names nothing."
  (if (<= (string-width path) room)
      path
      (let ((keep (max 1 (- room 1))))
        (concatenate 'string "…" (subseq path (max 0 (- (length path) keep)))))))

(defun %session-brief (s)
  "This session's OWN row from the daemon's list, or NIL when it is not there.

The list arrives on the `Hello` and on every `sessions` frame, and this head already
keeps it and reads it for `:stored-items` (the picker's `N rows`). The two fields it
did not read are the ones that answer *how big is this conversation* without a turn.

**A subagent session finds no row here, and the reference has the same gap**: both
heads filter `parent_session_id` rows out of the list they keep (a subagent is not a
session a picker lists), so a head switched INTO one has nothing to read. Recorded
rather than half-fixed — the fix is a second, unfiltered list, and it is not needed for
the screen R8 is about."
  (find (session-session-id s) (session-sessions s)
        :key (lambda (b) (getf b :session-id)) :test #'string=))

(defun %usage-backfilled (s)
  "The context the SESSION's own row remembers, as a usage plist, or NIL.

**R8: the context size is a property of the SESSION, not of this head's uptime.**
A daemon that restarted has no turn state in the snapshot — `TurnFinished` is
ephemeral and a view rebuilt from the transcript has no turn — so after a reattach, a
resume, or opening a session from disk, the turn's usage is empty and this head's
whole `ctx` segment disappeared. On the operator's screen the symptom was intermittent
in exactly the way the cause predicts: it showed while a turn had run in THIS head's
lifetime and showed nothing after a reattach — most of the time, and precisely when
somebody asks how big the conversation is (*\"leticl doesnt show context size for
whatever reason\"*).

The daemon writes both columns on EVERY round finish (`persist_context`,
harness.rs:4930-4941, from `TurnMetrics`), so the row is the durable half of the same
measurement. The reference reads it in its `Sessions` arm (app.rs:2116-2140) and only
when it has no usage of its own.

**Two disciplines, and they are the reason this is not a one-liner.**

  · **The size is known and the cache FRACTION may not be.** A row carries
    `context_cached` only if a turn finished after that column existed, so the same
    refusal the header already makes applies here: `:cached-tokens` is ABSENT from the
    plist rather than zero, and `%usage-numbers`' own `(third ctx)` guard is what keeps
    `0% cached` off the screen. A zero would read as *nothing was cached*, which is a
    measurement, where the truth is that nobody measured.
  · **A backfilled row carries NO COST.** `:cost-micros-usd` is absent, never 0 —
    nothing recorded a per-turn cost on the row, and a zero there would report a
    metered session as free. That is §13.2b in its most expensive form: a number that is
    absent is not a number that is zero."
  (let* ((brief (%session-brief s))
         (tokens (and brief (getf brief :context-tokens)))
         ;; the same guard the turn path uses: a count of zero is not a measurement of a
         ;; prompt, it is a row nobody wrote
         (cached (and brief (getf brief :context-cached))))
    (when (and (numberp tokens) (plusp tokens))
      (append (list :prompt-tokens tokens)
              (when (numberp cached) (list :cached-tokens cached))))))

(defun %turn-elapsed-ms ()
  "How long the running turn has been going, or **NIL when that cannot be measured honestly.**

The one place this is computed, so the composer edge and the status bar cannot disagree — which is
what the operator saw when they did: 151s beside 4.5s in one frame.

**AND IT REFUSES A NEGATIVE, which is a MEASURED case and not a guard for tidiness.** The start time
comes off the wire as a Unix stamp (`wire-stamp->started-ms`, progress.lisp) and is converted with
this head's `unix-now-ms`, whose offset is established ONCE from `get-universal-time` and then
advanced by the internal counter. That is correct only while the wall clock holds still: if it MOVES
under a running head the offset is stale by exactly that much, and the converted start lands in the
future. MEASURED on the operator's own head — `:started 42711437` against `:internal-now 14891669`, a
start 27 819 768 ms ahead — and the screen showed `-27819768ms` beside the word *Responding*.

NIL here means *this head cannot say*, and both callers already have the sentence for it: the composer
edge writes *started before this head attached*, which is the honest reading of a start time this
process never measured. A negative duration is worse than no duration — a measurement's costume on a
number that cannot be a measurement."
  (let ((ms (and *turn-started-ms* (- (internal-real-time-ms) *turn-started-ms*))))
    (and ms (not (minusp ms)) ms)))

(defun %usage-numbers (s)
  "The four telemetry numbers the header shows, each present only when measured:
context size, cache fraction, decode rate, elapsed — plus output tokens.

A number nobody measured is ABSENT, not zero: `0% cached` is the same defect as a
rate nobody took, and it is the rule the meter and the footer are both held to.

**The LIVE PREFILL WINS while a turn runs.** `header_line` (app.rs:6274-6281)
reads `turn.progress.total/cache` first and falls back to the kept usage only
when there is no prefill in flight, because *how big is this prompt* is a
question about the prompt being sent — not about the last one that finished.
Ours read `state.usage` or `turn.usage` and had no `progress` path at all, so
through the whole of a long turn the header showed the PREVIOUS turn's context
while the bar on the composer's edge was expanding a different one. Measured
against `src/session/state.lisp:225-230`, which already folds `PromptProgress` onto the
turn as `(:total :cache :processed :time-ms)` and had no reader."
  (let* ((turn (session-turn s))
         (state (and turn (getf turn :state)))
         (usage (or (and state (getf state :usage))
                    ;; a finished turn's usage is kept past the end of the turn,
                    ;; so the header still says what the conversation costs while
                    ;; nothing is running — which is most of the time
                    (and turn (getf turn :usage))
                    ;; **AND WHEN THERE IS NO TURN AT ALL** — a reattach, a resume, a
                    ;; session opened from disk — the SESSION's own row. This is the
                    ;; fallback that was missing: without it the whole `ctx` segment
                    ;; vanished on exactly the screens where nobody can answer the
                    ;; question any other way.
                    (%usage-backfilled s)))
         (pp (getf turn :progress))
         ;; `(TOTAL CACHED CACHE-MEASURED)`, the reference's own triple: a live
         ;; prefill always measured its own cache, a kept usage did so only if it
         ;; carried the number.
         (live (and pp (numberp (getf pp :total)) (plusp (getf pp :total))
                    (list (getf pp :total) (or (getf pp :cache) 0) t)))
         (kept (and usage (numberp (getf usage :prompt-tokens))
                    (plusp (getf usage :prompt-tokens))
                    (list (getf usage :prompt-tokens)
                          (or (getf usage :cached-tokens) 0)
                          (numberp (getf usage :cached-tokens)))))
         (ctx (or live kept))
         ;; **THE LAST FINISHED TURN'S TIMINGS, KEPT ACROSS THE NEXT ONE** — the reference's
         ;; `last_timings` (app.rs:1229, set at 3447 and 4218, read at 10236), and the reason
         ;; these three fields used to blink. Ours read the CURRENT turn's state, which
         ;; `:turn-started` replaces with a fresh `(:state "running")`, so `22 tok/s`, the
         ;; duration and `38 out` vanished the instant a turn began and came back when it ended:
         ;; *"the rate comes and goes"*. `:turn-started` carries the finished turn's state onto
         ;; the new one (src/session/), so this falls back exactly as the reference's does.
         (timings (or (and state (getf state :timings))
                      (and turn (getf turn :timings))))
         (parts nil))
    (when ctx
      (push (cons :ctx (format nil "~a ctx" (thousands (first ctx)))) parts))
    (when (and ctx (third ctx))
      (push (cons :cached
                  (format nil "~d% cached"
                          (round (* 100 (/ (float (second ctx)) (first ctx))))))
            parts))
    (when (and timings (numberp (getf timings :predicted-ms))
               (plusp (getf timings :predicted-ms))
               (numberp (getf usage :predicted-tokens))
               (plusp (getf usage :predicted-tokens)))
      (push (cons :rate
                  (format nil "~d tok/s"
                          (round (/ (* (float (getf usage :predicted-tokens)) 1000.0)
                                    (getf timings :predicted-ms)))))
            parts))
    ;; **AND THE DURATION IS THE TURN'S WHILE A TURN RUNS — the one field of the trio that moves.**
    ;;
    ;; The operator: *"its responding timer resets not at the turn end but on jobs and tool
    ;; calls."* MEASURED on their own head, side by side in one frame:
    ;;
    ;;     composer edge   Responding · 151s      <- *turn-started-ms*, monotonic over 4 samples
    ;;     status bar      ... 184 tok/s · 12.0s  <- the LAST ROUND's wall-ms, replaced per round
    ;;
    ;; `last_timings` is why the trio is on that basis and it is right for two of the three: a
    ;; RATE from the round that just ended is information (*"the rate comes and goes"*, the
    ;; complaint that put it there), and so is an output count. A DURATION from that round,
    ;; sitting beside the word *Responding*, is a claim about the wrong span — it reads as *this
    ;; turn has been running 4.5s* when the turn has been running for two and a half minutes.
    ;; So one field moves and the other two stay, and the two timers on the screen now agree.
    ;;
    ;; **BOTH HEADS, BY THE OPERATOR'S RULING (*"yes, letibot too"*), AND BOTH NOW DIFFER FROM THE
    ;; REFERENCE — which is the thing a reader will trip over.** The reference shows the last
    ;; round's duration here, and letibot's comment calls that parity with `app.rs:1229`'s
    ;; `last_timings`. After this change NEITHER head matches it, so somebody diffing against the
    ;; reference finds two heads disagreeing with it in the same way — and that is a ruling, not a
    ;; shared defect. Recorded as such in the parity row.
    ;;
    ;; The guard is `%turn-elapsed-ms`, which is the same thing the composer edge reads, so the two
    ;; timers cannot drift apart again — and it REFUSES A NEGATIVE, measured: see its docstring.
    (let ((elapsed-ms (or (%turn-elapsed-ms)
                          ;; **IDLE: THE LAST TURN'S DURATION IS THE ONLY ONE THERE IS**, and it is
                          ;; kept past the end of the turn — which is what `last_timings` is for.
                          (and timings
                               (numberp (getf timings :wall-ms))
                               (plusp (getf timings :wall-ms))
                               (getf timings :wall-ms)))))
      (when elapsed-ms (push (cons :elapsed (duration elapsed-ms)) parts)))
    (when (and usage (numberp (getf usage :predicted-tokens))
               (plusp (getf usage :predicted-tokens)))
      (push (cons :out (format nil "~a out" (thousands (getf usage :predicted-tokens)))) parts))
    (nreverse parts)))

(defun %usage-fields (s)
  "The same five fields `%usage-numbers` measures, **in the canonical order and always all five**,\nwith NIL where nothing was measured.

**This is what the header's reservation is computed from, and that is the whole reason it exists.**\n`%usage-numbers` returns only what is present — the right thing for a sentence about measurements, and\nthe wrong thing for deciding how much room to keep, because a decision taken from today's fields\nmoves when tomorrow's arrive. Measured with the former: the model name sat at column 171 on a head\nthat had measured nothing and at 109 with a full tail, because the tail being reserved was the tail\nthat happened to be there.\n\nThe order is the display order, and `nil` here means *this slot is here and empty* — which is a\ndifferent statement from *this field does not exist*, and exactly the difference the header needs."
  (let ((by-key (%usage-numbers s)))
    (loop for key in '(:ctx :cached :rate :elapsed :out)
          collect (cons key (cdr (assoc key by-key))))))

