;;;; jobs.lisp — the jobs pane: the background jobs this session started
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------ the jobs and subagents ;;;

(defun merge-queue-lines (head cols)
  "The merge queue, one BLOCK per entry — the rows the `/queue` pane will draw.

**STATE AND EVIDENCE, and the evidence is the whole point of the field**: *the evidence is the
reason for the state in the queue's own words* (the unmet dependencies while Waiting, the gate's
failure while Failed, the conflict while Conflict, the dead job while Stale, the landed tip while
Landed). A move without its reason is a row that changed state with nothing saying why, which is
the defect the field exists to prevent — so the renderer never draws a state without its evidence
when it has one, and says so when it does not.

Two lines per entry, the shape the jobs pane uses for the same reason (a list of facts needs a
second, dim line to carry them): `▸ [state] branch` over `         evidence`.

The queue is daemon-level and held on the head (`head-merge-queue`), so this draws from there and
never asks: the ASK is `/queue`'s own act (`make-list-merge-queue`), which is what keeps a frame
out of a renderer."
  (let ((entries (head-merge-queue head))
        (out (list (list (cons "merge queue" '(:bold t))))))
    (push nil out)
    (if (null entries)
        (progn
          (push (list (cons "    empty — nothing is waiting to land" '(:dim t))) out)
          (push nil out)
          (push (list (cons "    `/queue` asks the daemon for it again; entries arrive as they are filed"
                            '(:dim t)))
                out))
        (dolist (e entries)
          (let* ((id (or (getf e :id) "?"))
                 (branch (or (getf e :branch) "?"))
                 (state (or (getf e :state) "?"))
                 (evidence (getf e :evidence))
                 ;; the cursor's entry is REVERSED, exactly as every other pane's is
                 (picked (= (or (position id entries :key (lambda (x) (getf x :id)) :test #'equal) -1)
                            (head-picker-sel head))))
            (push (list (cons "  ▸ " '(:dim t))
                        (cons (format nil "[~a] " state) (merge-state-style state))
                        (cons branch (and picked '(:reverse t))))
                  out)
            ;; **`priority` AND `needs` ARE DRAWN, because the daemon sends them and a reader
            ;; deciding what to look at wants both**: the priority is the queue's own rank, and
            ;; `needs` is the list of entries this one waits for — MEASURED against
            ;; `sessionlog/src/event.rs:402` (`MergeEntry`), which carries `id, session_id, branch,
            ;; base_sha, priority, needs, state, brief, evidence, created_ms`. The first cut drew
            ;; only state, branch and evidence, so a row waiting on two other branches looked
            ;; exactly like one that was ready.
            (when (or (getf e :priority) (and (getf e :needs) (plusp (length (getf e :needs)))))
              (push (list (cons (format nil "         ~@[~a~]~@[ · needs ~{~a~^, ~}~]"
                                        (getf e :priority) (getf e :needs))
                                '(:dim t)))
                    out))
            ;; **SAID IN PLAIN LISP, not with format gymnastics** — the first cut used `~@[…~]~:[…~]`
            ;; and got the branches the wrong way round, which is how a renderer comes to say *no
            ;; reason given* about a row that has one.
            (push (list (cons (format nil "         ~a" (or evidence "no reason given"))
                              '(:dim t)))
                  out)
            ;; **AND THE GATE'S STEPS, IN THE ORDER `main` DECLARED THEM.** They are already on the
            ;; wire — `MergeEntry.gate_steps` (`event.rs:461`, `serde(default)`, no version bump) —
            ;; each `{command, outcome, output, started_ms, elapsed_ms}`, where the command is *the
            ;; string a person would paste into a shell to reproduce the row*.
            ;;
            ;; **AND AN EMPTY CHECKLIST IS NEVER DRAWN, WHICH IS THE RULE THIS STEP TURNS ON**: the
            ;; reference makes `no_gate` a VARIANT rather than an empty list because *"the gate
            ;; declared nothing to run"* and *"the gate has not run yet"* are different facts — and
            ;; an empty list reads as a third one, *all steps passed*, which is the lie the
            ;; operator's own rule forbids. So a `no_gate` row is drawn as its own sentence, and an
            ;; entry whose steps have not arrived says that rather than showing a blank.
            (dolist (step (getf e :gate-steps))
              (let ((outcome (or (getf step :outcome) "?"))
                    (command (or (getf step :command) "")))
                (push (list (cons (format nil "         ~a ~a"
                                          (if (string-equal outcome "no_gate") "no gate —" outcome)
                                          (if (string-equal outcome "no_gate")
                                              "nothing declared to run"
                                              command))
                                  (merge-state-style (if (string-equal outcome "green") "landed" outcome))))
                      out)))
            ;; **AND THE ENTRIES THIS ONE DEPENDS ON OR IS REVIEWED BY** — the reviews are on the
            ;; wire (`MergeEntry.reviews`) and `merge-review-line` keeps their three facts apart;
            ;; a review that has been asked and has not answered draws nothing, so the filter is
            ;; here rather than in the renderer's caller.
            (dolist (review (getf e :reviews))
              (let ((line (merge-review-line review)))
                (when line
                  (push (list (cons (format nil "         ~a" line) '(:dim t))) out))))
            ;; nothing at all: said, not shown as a checklist that looks complete
            (when (null (getf e :gate-steps))
              (push (list (cons "         the gate has not run on this entry" '(:dim t))) out)))))
    (push nil out)
    (push (list (cons (format nil "    ~d entries — `q` closes · the gate runs when a branch is picked"
                              (length entries)) '(:dim t)))
          out)
    (nreverse out)))

(defun merge-state-style (state)
  "The register a queue STATE is drawn in — the same vocabulary the panes already use: a landed
entry is Success, a failure or a conflict is Failure, a waiting or stale one is Pending, and a
state this build has never met is drawn plain rather than guessed at."
  (cond ((string-equal state "landed") +role-success+)
        ((member state '("failed" "conflict") :test #'string-equal) +role-failure+)
        ;; **`taken` IS IN FLIGHT, WHICH IS A FACT RATHER THAN A TASTE** — the daemon's own
        ;; `MergeState::Taken` means a runner has the entry, so it belongs in the register *is
        ;; happening* beside waiting and stale. MEASURED against `tokencore/src/store.rs`, whose
        ;; enum has SEVEN states (`Waiting, Taken, Landed, Failed, Conflict, Stale, Vetoed`) while
        ;; this head's first cut mapped five.
        ((member state '("waiting" "stale" "taken" "running") :test #'string-equal) +role-pending+)
        ;; **AND `vetoed` STAYS PLAIN FOR NOW, DELIBERATELY.** It is a PERSON's act rather than a
        ;; state of the work — the daemon's `veto_entry` *parks the row* with its evidence — and
        ;; whether that reads as Failure (something went wrong) or Attention (a person must look) is
        ;; a decision to take against a screen with a real queue on it, not from this desk. A wrong
        ;; colour mis-states consequence silently, which is what the tree's own rule forbids; plain
        ;; is the honest register until somebody has seen one.
        (t nil)))

(defun merge-review-line (review)
  "One review of one queue entry, as a string — `REVIEW` as the wire sends it.

**THE THREE FACTS ARE KEPT APART, WHICH IS THE WHOLE POINT OF THE FIELDS** (measured,
`event.rs:516`): a `decision` is a verdict (*accept*, *reject* or *needs_human*), `decision` nil
with an empty `failure` is *asked and has not answered yet*, and a non-empty `failure` is a review
that DIED — *a reviewer whose turn failed reached no judgement, so `decision` is None*, and the
daemon's own note says the field exists because the pane drew *has not answered* over an attempt
that was already dead. A pane built from `decision` alone cannot tell the second from the third,
which is the mistake the field was added to end.

Returns NIL for a review with nothing to say — no entry id and no decision and no failure — so a
caller can filter rather than draw a blank row."
  (let ((decision (getf review :decision))
        (failure (getf review :failure))
        (reasons (getf review :reasons))
        (answered (getf review :answered-ms)))
    (when (or decision (and (stringp failure) (plusp (length failure))))
      (cond
        ;; a DIED review is not a quiet one, and says so in its own words rather than the head's
        ((and (stringp failure) (plusp (length failure)))
         (format nil "review failed — ~a" failure))
        ;; a verdict, with the reviewer's own reasons when it gave any — and `answered` is not
        ;; drawn: a verdict that is THERE is by definition answered, so a timestamp beside it is
        ;; furniture (the rule this tree keeps for every marker).
        (t (format nil "review: ~a~@[ · ~a~]"
                   decision
                   (and (stringp reasons) (plusp (length reasons)) reasons)))))))

(defun job-label (job)
  "JOB as the reader should be told about it: its NAME when the daemon sent one, else its command.

**MEASURED, not invented** (`sessionlog/src/protocol.rs:1268`): `JobEntry.name` is *the name the
caller gave this job* — the agent's own stated intent, `bash(slug: \"release-build\")` — **and never
a parse of the command line**, because *a slug derived from `W=…; cd /tmp && cargo test …` would be
the machine inventing an intent*. Empty means nobody named it, and then the command is what a
reader needs: it is already on the row beside the id.

**`j57` is a counter**, which is the whole reason the field exists: *a person watching the pane
cannot tell which running job is the release build and which is the fold's tests, and a name is what
makes a row ring a bell.*"
  (let ((name (and job (getf job :name))))
    (if (and (stringp name) (plusp (length name)))
        name
        (or (and job (getf job :command)) ""))))

(defun merge-standings-line (head)
  "The merge queue's three counts, as the composer edge draws them — or NIL when NOTHING STANDS.

**MEASURED, not invented** (`ui/panes/queue.rs:254`): `Standings` is `review` (`waiting`: *in the
queue, not taken — the gatekeeper's review is what it waits on*), `merging` (`taken`) and `parked`
(`failed`/`conflict`/`stale`/`vetoed`: *the queue has stopped, and a person moves it*).

**AND NOTHING STANDS FOR A QUEUE THAT IS EMPTY OR ALL-LANDED, so the edge says NOTHING** — not
`0 in review · 0 being merged · 0 parked`: *a row of zeroes is a row of attention paid for ever for
a fact nobody has*. The disclosure is `/queue`, which says *none* in words. And when something DOES
stand, **all three counts are drawn, zeroes included**, because a count that vanishes reads as
though the queue had forgotten it."
  (let* ((entries (head-merge-queue head))
         (review (count-if (lambda (e) (string-equal (getf e :state) "waiting")) entries))
         (merging (count-if (lambda (e) (string-equal (getf e :state) "taken")) entries))
         (parked (count-if (lambda (e) (member (getf e :state)
                                               '("failed" "conflict" "stale" "vetoed")
                                               :test #'string-equal))
                           entries)))
    (when (plusp (+ review merging parked))
      (format nil "~d in review · ~d being merged · ~d parked" review merging parked))))

(defun jobs-lines (head cols)
  "The background jobs, the reference's `jobs_lines` (app.rs:6039):

    background jobs
    <blank>
        none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one.
    <blank>
        a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone.

or, with jobs, two lines each in place of the `none` row: `▸ [~] j12 command`
(the mark yellow while running, green for `exited 0`, red otherwise; the picked
row reversed) over a dim `         how · running · 1.2 KB out so far`,
`         how · exited 0 · 1.2 KB out · ran 3.4s`, or — for the one state where
nothing was ever executed — `         how · not run (could not join its scope) ·
0 B out`, with **no duration clause**: a job that never ran has no run to have
taken time (§11.6). Every field is the daemon's `JobEntry` — `id`, `command`,
`how`, `state`, `running`, `never_ran`, `produced`, `elapsed_ms`.

This pane NEVER RENDERED before: its header was `(list LINE (list LINE))` — the
second element a list containing a line, so a \"line\" whose segment was a line —
and `put-segments` died with `The value (\"\" :DIM T) is not of type STRING`.
Measured on the live head as `render failed — the head is alive; fix and re-push`.
A blank line is NIL, not a line with an empty dim segment.

Second value is the cursor's LINE: two lines per job after a two-line header."
  (let* ((w (pane-width cols))
         (rows (head-jobs head))
         (n (length rows))
         (sel (if (plusp n) (min (head-picker-sel head) (1- n)) 0))
         (out (list nil (list (cons "background jobs" '(:bold t))))))
    (when (null rows)
      (push (list (cons "    none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one."
                        '(:dim t)))
            out))
    (loop for j in rows
          for i from 0
          do (let* ((running (getf j :running))
                    (state (or (getf j :state) ""))
                    (mark (cond (running "[~]")
                                ((uiop:string-prefix-p "exited 0" state) "[x]")
                                (t "[!]")))
                    (colour (cond (running '(:fg :yellow))
                                  ((uiop:string-prefix-p "exited 0" state) '(:fg :green))
                                  (t '(:fg :red))))
                    (picked (= i sel))
                    (produced (or (getf j :produced) 0))
                    (elapsed (or (getf j :elapsed-ms) 0))
                    (never-ran (getf j :never-ran))
                    ;; **A job that never ran has no duration, and this row claimed
                    ;; one** (§11.6, letibot `e1cd2b0`). It read
                    ;;
                    ;;     not run (could not join its scope) · 0 B out · ran 0.0s
                    ;;
                    ;; — the state word denying *ran* two fields before the row said
                    ;; it. **The byte count stays**: `0 B out` is a measurement that
                    ;; exists (nothing was produced) and the word beside it says why.
                    ;; R17 again — *a row with nothing behind it must not look like a
                    ;; row with an empty something behind it* — and here the something
                    ;; is the run itself.
                    (tail (cond (running
                                 (format nil "running · ~a out so far" (bytes-human produced)))
                                (never-ran
                                 (format nil "~a · ~a out" state (bytes-human produced)))
                                (t
                                 (format nil "~a · ~a out · ran ~d.~ds" state (bytes-human produced)
                                         (floor elapsed 1000) (floor (mod elapsed 1000) 100))))))
               (push (list (cons (format nil "~a " (if picked "▸" " ")) (and picked '(:reverse t)))
                           (cons mark (if picked (append '(:reverse t) colour) colour))
                           (cons (format nil " ~a ~a" (getf j :id) (job-label j))
                                 (and picked '(:reverse t)))
                           ;; **A JOB WITH A DASHBOARD SAYS SO ON ITS OWN ROW.** The operator's
                           ;; ask: *"link to dashboard from jobs if a job has associated
                           ;; dashboard."* It has to be ON THE ROW rather than in the hint bar —
                           ;; the hint says what a key does, the row says whether there is
                           ;; anything to open, and only the row can differ from job to job.
                           (cons (if (dash-panel-for-job j) "  · dash" "")
                                 ;; and the mark rides the selection's reverse video, or it is
                                 ;; the one part of the row that stays lit when the cursor leaves
                                 (if picked '(:reverse t) '(:dim t))))
                     out)
               (push (list (cons (truncate-to-width
                                  (format nil "         ~a · ~a" (getf j :how) tail) w)
                                 '(:dim t)))
                     out)))
    (push nil out)
    (push (list (cons "    a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone."
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel)))))

