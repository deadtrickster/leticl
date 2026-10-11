;;;; note-card.lisp — a note the HEAD files about itself, in the register its warning
;;;; code earns — and, under a fault only, the remedy R29 says it must carry.

(in-package #:leticl)

(defclass note-card (card) ())

(defmethod card-lines ((card note-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    ;; **TWO REGISTERS, and R19 part 2 is why** (letibot `1a0d1f2`-era ruling).
    ;; `! …` in the failure role is the reference's `warn_line` and it is right
    ;; for a refusal, a gate timeout or a context wall. It was WRONG for
    ;; `compacted` and `auto_compact` — the session doing exactly what it should,
    ;; arriving in the same red as a denial — and the operator's words are the
    ;; requirement: *"a housekeeping notice and a refused call must not look
    ;; alike."*
    ;;
    ;; The register is read off the warning the ROW carries, through the one
    ;; table (`routine-warning-p`) and the one glyph (`warning-glyph`), so this
    ;; cannot disagree with the `/notes` listing about the same note. A routine
    ;; note is faint with a `·` instead of loud with a `!`, and the two are
    ;; distinguishable at a glance, which is the whole test — an operator who
    ;; learns to skip the red block is an operator who will skip the denial that
    ;; lives in it.
    ;;
    ;; A row this head files about ITSELF — `note-unreadable`, a protocol skew —
    ;; carries no `:warning`, so `routine-warning-p` answers NIL and it stays in
    ;; the failure register, which is right: those are the head saying it could
    ;; not do its job.
    ;;
    ;; **The failure register is unchanged**, deliberately: this moves codes OUT
    ;; of it only where the fact is *nothing is wrong*, and a code nobody has
    ;; classified stays red.
    (let* ((w (getf item :warning))
           (routine (routine-warning-p w))
           (glyph (warning-glyph w))
           (role (if routine +role-faint+ +role-failure+))
           (rows (wrap-segments
                  (list (cons (format nil "~a ~a" glyph (or (getf body :text) "")) nil))
                  cols))
           (cap (getf body :cap))
           (seam (getf body :seam))
           (hidden (and cap seam (> (length rows) cap) (- (length rows) cap)))
           (out (mapcar (lambda (l)
                          (mapcar (lambda (seg) (cons (car seg) role)) l))
                        (if hidden (subseq rows 0 cap) rows)))
           ;; **R29 RULE ONE: the note carries its own remedy.** Drawn AFTER the
           ;; seam, deliberately — the seam says how much text was cut, and a
           ;; remedy that the cap could cut is a remedy that was not offered,
           ;; which is the whole failure R29 is about. It is dim in every register
           ;; (the note's own role says how loud the FACT is; the remedy is an
           ;; instruction, not a second alarm), and it is one line plus its wrap.
           ;;
           ;; **AND ONLY UNDER A FAULT** (letibot R73): `note-remedy` answers NIL for a
           ;; routine code, so a housekeeping note is its fact and nothing under it.
           (remedy (note-remedy w)))
      (append out
              (when hidden
                (list (list (cons (format nil "  … +~d line~a · ~a"
                                          hidden (if (= hidden 1) "" "s") seam)
                                  '(:dim t)))))
              (when remedy
                (mapcar (lambda (l) (list (cons l '(:dim t))))
                        (wrap-text (format nil "  → ~a" remedy)
                                   (max 20 (- cols 2))))))))
  )


(defparameter +note-remedies+
  '(;; **the reader ASKED for something that does not exist.** The act is to see what
     ;; does; there is nothing to fix and saying so is the honest remedy.
     ("slash_refused" . "nothing to fix — that verb does not exist. /help lists the ones that do; ctrl-n clears this note")
     ("mode_unknown" . "nothing to fix — that mode name does not exist. /mode with no argument opens the picker")
     ("answer_unclaimed" . "nothing to fix — the ask was already answered. /status counts it; ctrl-n clears this note")
     ;; **a REFUSAL with a way round it.**
     ("job_output_refused" . "nothing can be done — that job's output is gone from the daemon and nobody holds it. /job lists the ones it still has")
     ("mode_set_refused" . "nothing was changed — the mode you named was not applied. /mode opens the picker")
     ("reseat_refused" . "/reseat rebuilds the prompt from the tools seated now; the conversation was NOT replaced")
     ("length_batch_refused" . "the turn was not sent as one batch; ask again, or split it")
     ;; **the session is under pressure and the reader can act.**
     ("context_wall" . "this turn stopped: /compact summarises now, or /new starts a fresh session")
     ("auto_compact_skipped" . "automatic compaction is off for this session; /compact runs one now")
     ("auto_compact_no_progress" . "compacting again will not help; /new starts a fresh session")
     ("auto_compact_failed" . "/compact runs one now, by hand, and says what it did")
     ;; **the session's INTEGRITY is in doubt, and there is no act.**
     ("ledger_chain_mismatch" . "nothing can be done from here — the ledger will not replay. /status has the counters; the store holds the evidence")
     ("row_coverage_gap" . "nothing can be done from here — the store and the log disagree. /gate corpus reads both")
     ("transcript_store" . "nothing can be done from here — the store refused the write. /status counts it")
     ("decision_corpus" . "nothing can be done from here — the corpus row was not written")
     ("prefix_divergence" . "the cached prefix is not the one the server holds; the next turn re-sends it and costs a full re-prefill")
     ("prefix_check_skipped" . "nothing to do — the prefix check does not run on this provider (D10)")
     ("log_gap" . "/resync takes a fresh snapshot; the gap is counted by /status")
     ("protocol_skew" . "nothing will fix it from here — the two halves speak different versions. Restart the head or the daemon")
     ("unreadable_frame" . "this head reads past frames it cannot parse; /verbosity loud shows the envelope")
     ("gate_timeout" . "nobody answered in time. /gate recent shows the decision, /gate todo lists any still open")
     ("gate" . "/gate recent shows what the gate decided; /gate ok|grant|revoke rules on one afterwards")
     ("turn_failed" . "the turn stopped. ctrl-r shows the working-out it got to; ask again")
     ("session_unavailable" . "/resume brings a stored session back; /sessions lists them")
     ("resume_failed" . "/sessions lists what the daemon can actually reach")
     ("mode_unpersisted" . "the mode is live in this process and not on disk; /mode again after a restart")
     ("secret_late" . "nothing to do — the password was already given by another head")
     ("sudo" . "nothing to do — the daemon reports it; the ask itself is a card")
     ("ended_in_reasoning" . "the turn stopped mid-thought; ctrl-r shows it and asking again continues")
     ("reasoning_stall" . "nothing to do — the model was thinking without writing; the turn is still running")
     ("repetition_collapse" . "the turn was cut short by a repeat detector; asking again usually gets past it")
     ("fabric_refresh_failed" . "nothing can be done from here — the fabric did not refresh")
     ("flowy_not_seated" . "/flowy login [SEAT] attaches a seat; /flowy status shows whether one is held")
     ("monitor_wake_not_armed" . "nothing can be done from here — a fired monitor wakes the model only on job_list")
     ("frame_capture_failed" . "nothing can be done from here — the capture write failed; the detail names the path")
     ("title_not_stored" . "nothing can be done from here — the title did not reach the store")
     ("record_item_pairing" . "nothing can be done from here — an item arrived without its pair")
     ("orphan_body" . "nothing can be done from here — a body arrived with no row to hang it on")
     ("absolute_path" . "nothing to do — a path in the arguments was absolute, which is a note about the call")
     ("endpoint" . "nothing can be done from here — the model endpoint refused; the detail names it")
     ("dated" . "nothing to do — the data is older than the session")
     ("data_claim" . "nothing to do — a claim in the answer was flagged; the detail says which")
     ;; two of the three the coverage test found missing on its first run — which is the test
     ;; doing its job: a FAULT the head draws with no entry is the dead end R29 is about.
     ("reseat_unchecked" . "nothing to do — the re-seat went ahead without checking the tool list; /tools shows what is seated")
     ("length_empty_turn" . "the turn carried no message and was not sent; type something and press enter again")
     ("merge_not_queued" . "the branch is not in the queue — read the note beside this row for the reason")
     ("operator_shell_failed" . "the command failed — read the row for its exit status and output")
     ("operator_run_unreadable" . "the daemon cannot read this run's state — it may still be running")
     ("prompt" . "the command is asking a question — type the answer and press enter, or !send LINE")
     ("prompt_late" . "an answer was sent after the question was gone — the command may have exited")
     ("sudo" . "sudo was refused — the daemon may not have the askpass helper configured"))
  "What the reader can DO about a note, per code — R29 rule one, on the note.

**A note that states a fact and not the act is a dead end on the screen.** The operator,
meeting two red rows from `/diff` and `/qwe` on a head whose `/dismiss` had worked for two
days: *when this red shit is show it should hint what to do next.* The affordance
existed and the note did not mention it — so the rule is that the remedy is ON THE NOTE,
not in the hint bar, not in `/help`, not in a key the reader has to already know.

**An empty slot is not allowed FOR A FAULT**, and that is the load-bearing half: the honest
entries here include `nothing can be done from here — …`, because *this cannot be fixed from
the glass* is a real answer and the operator's own rule says so (*nothing can be done and here
is why satisfies this rule*). What is forbidden is a refusal or a failure drawn in silence. A
test walks `+failure-warnings+` and fails on a code with no entry.

**AND A ROUTINE CODE HAS NO ENTRY AT ALL — a remedy line belongs to a fault** (letibot R73).
This table used to answer every routine code too, mostly with `nothing to do — …`, and the
operator pasted what one compaction then looked like: four `compact_half` notes, each with
*→ nothing to fix — the conversation is being summarised …* under it. A housekeeping notice
with an instruction under it reads as a thing to act on, which is R19's fault one register
down — the same `→` that carries */compact summarises now* under a context wall. So the
routine half of the vocabulary (`+routine-warnings+`, letibot's `Class::Routine`) draws its
fact and stops; where a routine fact has a verb worth knowing (`prefix_stale`'s `/reseat`),
the daemon's own sentence already says it. The suite asserts no routine code is in this
table, so an entry cannot drift back in.

**Why a table in the head and not a field from the daemon**: the ACT is the head's. The
daemon knows what happened; only this file knows that the gesture for clearing a note is
`ctrl-n`, that the picker is behind `/mode`, and that the corpus reader is `/gate corpus`.
letibot composes its own for the same reason, and R29 requires the two heads to OFFER a
remedy in the same places, not to say the same words.")

(defun %interrupt-idle-remedy ()
  "Why an `esc esc` did nothing — which is NOT always *nothing was running*.

**MEASURED on the operator's own head, four times in a row.** `esc esc` on a turn that was waiting on a
CALL came back `interrupt_idle — nothing was generating`, and this head drew its fixed sentence —
*nothing to do — there was no turn running to interrupt* — over a screen that said *Responding · 11m26s*
and *1 job running*. Four presses, four refusals, and every one of them a false statement about the
reader's own screen.

**The daemon is speaking about GENERATION and the reader is asking about a CALL.** `Interrupt` is handed
to the engine at a STEP BOUNDARY and letibot's own docstring defines it as *stops generation at the next
token*; while a tool call is executing there is no token and no boundary to reach. At the far end the
worker's arm treats anything that arrives elsewhere as *arrived between turns*, which is how a live turn
gets called idle.

**AND THE TWO CASES ARE GENUINELY DIFFERENT, so this does not replace one sentence with a better one — it
reads the state.** A command that is RUNNING can be backgrounded by `ctrl-o` (letibot's `Promote` is
documented as honoured by the exec backend mid-turn, which is the seam an interrupt never uses), and a
call the daemon has not yet STARTED is not reachable by any key in this head.

**AND THE THIRD CASE — no busy turn — ANSWERS NIL.** There the code's fact is what it says, the
session was idle, and that is a routine note: it draws no remedy line (letibot R73, `note-remedy`)."
  (let* ((head *head*)
         (turn (and head (session-turn (head-session head))))
         (calls (and turn (getf turn :calls)))
         (running (and calls
                       (some (lambda (c)
                               (string= (or (getf (getf c :state) :state) "") "running"))
                             calls))))
    (cond
      (running
       "the turn is waiting on a RUNNING COMMAND — ctrl-o moves it to the background, which is the gesture that reaches a call; esc esc reaches the model's generation, not a command")
      ((and turn (turn-busy-p turn))
       "the turn is waiting on the daemon — it holds a call the daemon has not started, so nothing typed here reaches it and esc esc cannot help")
      ;; idle: the routine case, and a routine note carries no remedy line
      (t nil))))

(defun note-remedy (w)
  "The line that says what the reader can DO about W, or NIL when there is none to draw.

NIL in three cases, and only these:

  · **a ROUTINE code** (`routine-warning-p`) — a remedy line belongs to a fault, and a routine
    event has none (letibot R73; see `+note-remedies+`);
  · **an unknown code** — an old head meeting a new daemon's warning names nothing, because any
    sentence here would be invented;
  · **no code at all**.

Every FAULT in this head's own set has an entry, which is what the suite checks.

**ONE ROUTINE CODE CAN STILL NAME AN ACT, AND ONLY FROM THE STATE**: `interrupt_idle`. Its fact is
routine when nothing is running — `esc esc` on an idle session — and then it draws nothing, like every
other routine code. But the daemon also sends it over a turn that is waiting on a CALL, where its
*nothing was generating* is true about generation and false about the reader's screen; there the
operator's gesture did not do what they meant, and the line under it is the one that says which key
does (`%interrupt-idle-remedy`). That is a refusal of the reader's act in all but name, and a remedy
belongs to it."
  (let ((code (getf w :code)))
    (cond ((null code) nil)
          ((string= code "interrupt_idle") (%interrupt-idle-remedy))
          ((routine-warning-p w) nil)
          (t (cdr (assoc code +note-remedies+ :test #'string=))))))

