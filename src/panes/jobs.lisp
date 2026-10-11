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
            ;; **SAID IN PLAIN LISP, not with format gymnastics** — the first cut used `~@[…~]~:[…~]`
            ;; and got the branches the wrong way round, which is how a renderer comes to say *no
            ;; reason given* about a row that has one.
            (push (list (cons (format nil "         ~a" (or evidence "no reason given"))
                              '(:dim t)))
                  out))))
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
                           (cons (format nil " ~a ~a" (getf j :id) (getf j :command))
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

