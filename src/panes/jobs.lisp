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

;;; ------------------------------------------- the review queue and the merge queue ;;;
;;;
;;; **Two queues, two views, one pane** (letibot R61, protocol 43). The operator: *"review is review
;;; and merge is merge. separate steps. separate queues."* The daemon answers `ListMergeQueue` with
;;; ONE `QueueSnapshot` — both queues, each repository's lease, the target branches' health and the
;;; last moves — and every change after it is a `QueueMoved` that means *ask again*. The snapshot is
;;; daemon-level and lives below the head in `*queues*`; `head-merge-queue` is THE CURRENT VIEW's rows,
;;; which is what the shared cursor walks, `pane-enter` opens and a verb names.

(defvar *queues* nil
  "The last `queues` snapshot, as the wire's plist — `(:at-ms N :reviews (…) :merges (…) :leases (…)
:targets (…) :recent (…) :archived N :unreadable WHY)` — or NIL before the first answer.

**A `defvar` and not a head slot**, for HACKING.md's reason: live state the renderer reads goes in
a global because a struct layout change is a restart and a push must survive. Daemon-level, like
the queue itself: there is one main branch and one queue, and a `/switch` does not change it.")

(defvar *queue-view* :review
  "Which queue the pane lists — `:review` or `:merge`. The reference opens on review (its
`QueueView::default`), because a red target's review is the emergency the pane leads with.")

(defvar *queues-got-ms* 0
  "`internal-real-time-ms` when `*queues*` landed, so the snapshot's `at_ms` can be carried
forward on this head's clock (`queue-now-ms`). 0 is *never*.")

(defvar *queues-asked-ms* 0
  "`internal-real-time-ms` of the last `ListMergeQueue` this head sent — the re-read's clock.")

(defvar *queues-in-flight* nil
  "T between an `ask-queues` and the `queues` that answers it, so a burst of `QueueMoved`s (the
daemon writes one per row moved, to every session) asks ONCE and not once per event. The 5 s tick
asks regardless, which is what recovers an ask the socket lost.")

(defparameter +queue-refresh-ms+ 5000
  "How often an OPEN pane asks for a fresh snapshot — the reference's `REFRESH_MS`: *the heartbeats
move without an event*, so a pane that waited for `QueueMoved` would draw a lease as alive for ever.")

(defparameter +job-refresh-ms+ 1000
  "How often an OPEN job window re-reads while its job is STILL RUNNING.

 **ONE SECOND, AND IT IS THE REFERENCE'S NUMBER** (`516c5a4` says it in passing — *the jobs pane
 started re-reading its window once a second*): a running job's output is a LIVE view and a head that
 read it once at Enter showed the program's first page for as long as it stayed open. **A SETTLED JOB
 IS NOT RE-READ**: its output is final, and asking again for ever would be a loop that could only
 return what it already has.")

(defvar *job-asked-ms* 0
  "When the job window was last asked — the clock `tick-job-window` measures its second against.")

(defun ask-job-window (head)
  "Re-read the OPEN job window at the page it is showing — the ONE sender.

 **THE PAGE AND NOT THE FIRST PAGE**: a refresh that asked for offset 0 would drag a reader on page
 three back to the start every second, which is worse than a window that never follows. `:next` is the
 offset the view is showing (`(or :next at)` is how the paging code reads it) and 0 is the first page."
  (let ((job (getf *job-out* :job)))
    (when job
      (setf *job-asked-ms* (internal-real-time-ms))
      (%send head (make-read-job-output job (or (getf *job-out* :next) 0))))))

(defun %window-job-running-p (head)
  "Is the job the open window belongs to still running? NIL for one the table no longer lists.

 A job the head cannot find is not re-read: there is nothing to follow, and asking about a handle the
 board has dropped would be a window inventing work."
  (let* ((id (getf *job-out* :job))
         (job (and id (find id (head-jobs head)
                            :key (lambda (j) (getf j :id)) :test #'equal))))
    (and job (getf job :running))))

(defun tick-job-window (head)
  "The window's re-read: while a RUNNING job's window is open, ask again every `+job-refresh-ms+`.

 Called from the loop's tick beside `tick-queues`, and for its reason — the two are the same shape:
 a pane that only ever heard about its subject through an event would draw a live thing as a still
 one. **This is the head's own number and not the daemon's**: the daemon answers a read with whatever
 the job has written by then, so the interval is how often the reader looks, not how often it changes."
  (when (and (eq (head-mode head) :job-out)
             (head-connected head)
             (not *replaying*)
             (%window-job-running-p head)
             (>= (- (internal-real-time-ms) *job-asked-ms*) +job-refresh-ms+))
    (ask-job-window head)))

(defvar *held-results* nil
  "What the daemon is holding back from its model right now — `(JOBS SUBAGENTS FAILED)` — or NIL.

 **THE REFERENCE'S `SessionEvent::HeldResults`** (`event.rs:2212`), and its own source has the whole
 spec: *what this session is holding back from its model right now: the results nothing in the plan waits
 on, held so a RUNNING turn is not interrupted, **counted by kind***. The operator asked for it in these
 words — *\"what would be useful is a counter of how much and what kind is held - somewhere close to
 Responding\"* — and that is exactly where it is drawn (`turn-report-row`).

 **NOT TRANSCRIPT CONTENT**, which is the half that decides the shape: the reference's view folds it to
 nothing (`view.rs:964`) and this head files it as an event it READS rather than folds, so it never
 becomes a row of its own. It is appended to the responding row instead, which is why a count appearing
 or going does not move the conversation by a line.

 **EPHEMERAL, so a snapshot DROPS it ** — *a count from four minutes ago is a lie about now*, and the
 daemon says it again the moment the held set changes. Holding exists only while a turn runs (the
 operator: *\"once turn ends no reason to hold\"*), so outside a turn the counts are zero and the row
 says nothing.")

(defun held-results-note (cols)
  "The held counts as one clause — or NIL when there is nothing held, or no room for it.

 **ZERO DRAWS NOTHING** (the daemon's own rule: *draws nothing once they are all zero*), and the kinds
 are named only when they are non-zero: `holding 2 jobs, 1 subagent` and never `holding 0 subagents`.

 NIL when the frame cannot afford it: this row also carries the turn's own report and the operator's
 asked-for legend, and a count that pushed the legend off a narrow terminal would be trading the thing
 they asked for against a thing they mentioned."
  (let ((j (or (first *held-results*) 0))
        (s (or (second *held-results*) 0))
        (f (or (third *held-results*) 0)))
    (when (and *held-results* (plusp (+ j s f)) (>= cols 60))
      (format nil "holding ~{~a~^, ~}"
              (remove nil
                      (list (and (plusp j) (format nil "~d job~:p" j))
                            (and (plusp s) (format nil "~d subagent~:p" s))
                            (and (plusp f) (format nil "~d failed" f))))))))

(defparameter +lease-stale-ms+ 90000
  "A heartbeat older than this is drawn STALE — the daemon's own lease lifetime
(`mergequeue::lease::LEASE_TTL_MS`, the reference's `LEASE_STALE_MS`), so the pane's word and the
daemon's takeover agree.")

(defparameter +queue-recent-ms+ (* 24 60 60 1000)
  "How long a FINISHED row stays in the view — the recent past, not every row ever (rows are never
deleted; the history is the record). The reference's `RECENT_MS`.")

(defun queue-now-ms ()
  "The snapshot's own *now*, carried forward by this head's clock since it arrived — every age in the
pane is measured against it, so a lease's heartbeat ages while the pane is open."
  (if (and *queues* (integerp (getf *queues* :at-ms)) (plusp *queues-got-ms*))
      (+ (getf *queues* :at-ms) (max 0 (- (internal-real-time-ms) *queues-got-ms*)))
      (unix-now-ms)))

(defun %dur-human (ms)
  "A duration a person reads: `3s`, `4m`, `2h 5m`, `3d 2h`."
  (let* ((s (floor (max 0 (or ms 0)) 1000))
         (m (floor s 60)) (h (floor m 60)) (d (floor h 24)))
    (cond ((< s 60) (format nil "~ds" s))
          ((< m 60) (format nil "~dm" m))
          ((< h 24) (format nil "~dh ~dm" h (mod m 60)))
          (t (format nil "~dd ~dh" d (mod h 24))))))

(defun %repo-name (repo)
  "The repository's last path component — the name a person knows it by; `(unresolved)` for none."
  (let ((r (string-right-trim "/" (or repo ""))))
    (if (zerop (length r))
        "(unresolved)"
        (let ((slash (position #\/ r :from-end t)))
          (if slash (subseq r (1+ slash)) r)))))

(defun %owner-word (owner)
  "`host/pid`, the start stamp dropped — the owner as a person reads it."
  (let* ((o (or owner "")) (a (position #\/ o)) (b (and a (position #\/ o :start (1+ a)))))
    (if b (subseq o 0 b) o)))

(defun %first-line (s)
  (let ((s (or s ""))) (subseq s 0 (or (position #\newline s) (length s)))))

(defun %review-open-p (state) (member state '("waiting" "reviewing" "blocked") :test #'equal))
(defun %merge-open-p (state) (member state '("queued" "gating" "blocked") :test #'equal))

(defun queue-view-rows (snapshot view)
  "The rows VIEW lists from SNAPSHOT, in the reference's order (`queue_rows`): the OPEN rows first —
a red target's review before every other review, a fix for the red target before every other
merge — oldest first; then the rows that FINISHED within the last day, newest first. Each row is
the wire's own plist with `:queue` (`\"review\"` or `\"merge\"`) in front, so a reader of the row can
tell which queue it came from without being told."
  (let* ((now (queue-now-ms))
         (recent (lambda (ms) (<= (- now (or ms 0)) +queue-recent-ms+)))
         (rows (if (eq view :merge) (getf snapshot :merges) (getf snapshot :reviews)))
         (open-p (if (eq view :merge) #'%merge-open-p #'%review-open-p))
         (first-p (if (eq view :merge)
                      (lambda (r) (getf r :fixes))
                      (lambda (r) (equal (getf r :kind) "target"))))
         (open (remove-if-not (lambda (r) (funcall open-p (getf r :state))) rows))
         (done (remove-if (lambda (r) (or (funcall open-p (getf r :state))
                                          (not (funcall recent (getf r :state-ms)))))
                          rows)))
    (setf open (stable-sort (copy-list open)
                            (lambda (a b)
                              (let ((fa (and (funcall first-p a) t)) (fb (and (funcall first-p b) t)))
                                (cond ((and fa (not fb)) t)
                                      ((and fb (not fa)) nil)
                                      ((/= (or (getf a :created-ms) 0) (or (getf b :created-ms) 0))
                                       (< (or (getf a :created-ms) 0) (or (getf b :created-ms) 0)))
                                      (t (string< (or (getf a :id) "") (or (getf b :id) ""))))))))
    (setf done (stable-sort (copy-list done)
                            (lambda (a b) (> (or (getf a :state-ms) 0) (or (getf b :state-ms) 0)))))
    (mapcar (lambda (r) (list* :queue (if (eq view :merge) "merge" "review") r))
            (append open done))))

(defun queue-refresh-rows (head)
  "Recompute `head-merge-queue` from the snapshot for the current view, and keep the cursor on a
row that exists. A no-op without a snapshot, so a test that put rows on the head by hand keeps them."
  (when *queues*
    (setf (head-merge-queue head)
          ;; **AND THE PANE'S COPY IS CUT TO THE SCOPE IT SHOWS** (letibot R92.5): the snapshot is
          ;; daemon-level and holds every repository's rows, so a pane that drew them all made the
          ;; reader hunt for their own work among strangers'. The EDGE is a different question —
          ;; `%queue-scope`, always this session's — and it is deliberately not this one.
          (let ((rows (queue-view-rows *queues* *queue-view*))
                (scope (queue-pane-scope head)))
            (if scope
                (remove-if-not (lambda (r) (%queue-row-here-p r scope)) rows)
                rows)))
    (setf (head-picker-sel head)
          (max 0 (min (head-picker-sel head) (max 0 (1- (length (head-merge-queue head)))))))
    (setf (head-dirty head) t)))

(defun fold-queues (head snapshot)
  "The `queues` frame's fold: REPLACE the snapshot (it is the whole of both queues as of now, so
folding it into what the head held would let a landed row survive a reset), recompute the view, and
SAY the counts — and say the store's refusal when the daemon could not read it, because *a read that
failed is said in the snapshot's `unreadable`, never drawn as an empty queue* (R61 defect 12)."
  (setf *queues* snapshot
        *queues-got-ms* (internal-real-time-ms)
        *queues-in-flight* nil)
  (queue-refresh-rows head)
  (let ((unreadable (getf snapshot :unreadable)))
    (say head (if (and (stringp unreadable) (plusp (length unreadable)))
                  (format nil "the queue store could not be read — ~a" unreadable)
                  (format nil "the review queue holds ~d, the merge queue ~d"
                          (length (getf snapshot :reviews)) (length (getf snapshot :merges)))))))

(defun ask-queues (head)
  "Send `ListMergeQueue` and mark the clock — the ONE sender, so the re-read and the verb's ask
cannot disagree about when the daemon was last asked."
  (setf *queues-asked-ms* (internal-real-time-ms)
        *queues-in-flight* t)
  (%send head (make-list-merge-queue)))

(defun tick-queues (head)
  "The pane's re-read: while the `:queue` pane is OPEN and the head is connected, ask again every
`+queue-refresh-ms+`. Called from the loop's tick (see `%poll-resize`); a closed pane asks nothing."
  (when (and (eq (head-mode head) :queue)
             (head-connected head)
             (not *replaying*)
             (>= (- (internal-real-time-ms) *queues-asked-ms*) +queue-refresh-ms+))
    (ask-queues head)))

(defun queue-switch-view (head view)
  "Show VIEW (`:review` or `:merge`) — the pane's Tab, and `/queue review|merge`'s act."
  (setf *queue-view* view
        (head-picker-sel head) 0
        (head-dirty head) t)
  (queue-refresh-rows head)
  (say head (format nil "the ~(~a~) queue" view)))

(defun queue-moved (head env)
  "Fold a `QueueMoved {queue, id, to, why}` (event.rs:2005): move the row's state IN PLACE on the
snapshot and the view, file the move in the recent history, and — when the pane is open and no ask
is in flight — ask for a fresh snapshot, which is what the event means (*the pane re-reads the
snapshot on it; the log keeps the sentence*).

**QUIET, because it is BROADCAST**: the queues are daemon-level and the daemon writes this into EVERY
session's log, so a `say` here would put another conversation's queue traffic on this head's status
line and the ⚠ alarm every few seconds. Nothing is filed as unknown (`+events-not-folded-here+`), and
a row this head has never been told about invents nothing: it arrives with the next snapshot."
  (let* ((id (getf env :id))
         (to (getf env :to))
         (why (getf env :why))
         (which (getf env :queue))
         (now (queue-now-ms)))
    (when (and *queues* id)
      (let ((row (find id (if (equal which "merge") (getf *queues* :merges) (getf *queues* :reviews))
                       :key (lambda (r) (getf r :id)) :test #'equal)))
        (when row
          (let ((from (getf row :state)))
            (when to (setf (getf row :state) to
                           (getf row :state-ms) now))
            ;; **a move that says nothing does not erase the reason we have** — the field exists
            ;; to prevent exactly that
            (when (and (stringp why) (plusp (length why))) (setf (getf row :evidence) why))
            (setf (getf *queues* :recent)
                  (append (getf *queues* :recent)
                          (list (list :queue (or which "") :entry-id id :repository (or (getf row :repository) "")
                                      :from from :to (or to "") :at-ms now :by "" :why (or why ""))))))))
      (queue-refresh-rows head))
      (when (and (head-connected head)
                 (not *queues-in-flight*))
        (ask-queues head))
    (setf (head-dirty head) t)))

(defun queue-row-by-id (head id)
  "The row ID names, from the snapshot (either queue) or, without one, from the view's rows."
  (or (and *queues*
           (or (find id (getf *queues* :reviews) :key (lambda (r) (getf r :id)) :test #'equal)
               (find id (getf *queues* :merges) :key (lambda (r) (getf r :id)) :test #'equal)))
      (find id (head-merge-queue head) :key (lambda (r) (getf r :id)) :test #'equal)))

(defun queue-row-queue (row)
  "`\"review\"` or `\"merge\"` for ROW: its `:queue` when the view put one on, else the snapshot's
list it is in — a merge row carries `:approved-sha`, a review row never does."
  (or (getf row :queue)
      (if (or (getf row :approved-sha) (getf row :review-id)) "merge" "review")))

(defun queue-verb-refusal (verb row)
  "Why VERB does nothing on ROW — the daemon's own rule (`mergequeue::verbs`, mirrored by the
reference's `verb_moves`) — or NIL when the verb moves it. Said rather than sent: a verb the daemon
would refuse is a round trip for a sentence this head already knows."
  (let* ((state (or (getf row :state) ""))
         (merge (equal (queue-row-queue row) "merge"))
         (kind (getf row :kind))
         (ok (cond ((string= verb "approve")
                    (and (not merge) (equal kind "branch")
                         (member state '("waiting" "reviewing" "rejected" "cannot_decide" "blocked") :test #'equal)))
                   ((string= verb "veto")
                    (if merge
                        (member state '("queued" "blocked" "failed" "timed_out" "conflict") :test #'equal)
                        (%review-open-p state)))
                   ((string= verb "restart")
                    (if merge
                        (member state '("failed" "timed_out" "conflict" "blocked" "withdrawn") :test #'equal)
                        (member state '("rejected" "cannot_decide" "blocked" "withdrawn") :test #'equal)))
                   ((string= verb "rm")
                    (if merge
                        (member state '("queued" "blocked" "failed" "timed_out" "conflict") :test #'equal)
                        (member state '("waiting" "reviewing" "blocked" "rejected" "cannot_decide") :test #'equal)))
                   (t nil))))
    (unless ok
      (cond ((and (string= verb "approve") merge) "a merge row is approved already")
            ((and (string= verb "approve") (equal kind "target")) "the red target's review is not a branch to land")
            ((string= state "gating") "the queue is gating it right now")
            ((string= state "landed") "it has landed")
            ((string= state "approved") "it is approved and in the merge queue")
            (t (format nil "it is `~a`" state))))))

(defun queue-verb (head verb id)
  "The person's verb on one row — `approve`, `veto`, `rm` or `restart` — as the slash line the
daemon takes (`queue VERB ID`), the SAME line the reference's keys send so the two spellings cannot
drift. A row the daemon would refuse is said and not sent; a row this head does not hold is sent
anyway, because the daemon holds rows this head's last snapshot may not."
  (let ((row (queue-row-by-id head id)))
    (let ((why (and row (queue-verb-refusal verb row))))
      (if why
          (say head (format nil "`~a`: ~a does nothing here — ~a. Nothing was sent."
                            (or (getf row :branch) id) verb why))
          (progn
            (%send-slash head (format nil "queue ~a ~a" verb id))
            (say head (format nil "queue ~a ~a — sent; the pane re-reads when the daemon moves it" verb id)))))))

(defun queue-act (head verb)
  "The two verbs that act on the QUEUE rather than on a row — `reset` and `clean` — as the slash line
 the daemon takes (`queue VERB`), which is the spelling its own command line has.

 **NO ID, which is why they are not `queue-verb`'s**: `approve`, `veto`, `rm` and `restart` each name a
 row, and a head that asked *which row?* for `reset` would be asking a question with no answer. The
 daemon is still the one that decides what they mean — a head that DID something on `reset` would be
 the second owner of the queue."
  (%send-slash head (format nil "queue ~a" verb))
  (say head (format nil "queue ~a — sent; the pane re-reads when the daemon moves the queue" verb)))

(defun queue-row-moves (id &optional (n 3))
  "The last N moves of row ID from the snapshot's recent history, oldest first."
  (let ((mine (remove-if-not (lambda (m) (equal (getf m :entry-id) id)) (getf *queues* :recent))))
    (if (and n (> (length mine) n)) (last mine n) mine)))

(defun %queue-move-lines (id n now indent)
  "The move rows under a queue row: `from → to · 3m ago · by X — why`, or one line saying there are
none. Drawn only with a snapshot: without the history there is nothing honest to say about it."
  (when *queues*
    (let ((moves (queue-row-moves id n)))
      (if (null moves)
          (list (list (cons (format nil "~a· no moves in the recent history" indent) '(:dim t))))
          (mapcar (lambda (m)
                    (list (cons (format nil "~a~@[~a ~]→ ~a · ~a ago~@[ · by ~a~]~@[ — ~a~]"
                                        indent
                                        (getf m :from)
                                        (or (getf m :to) "?")
                                        (%dur-human (- now (or (getf m :at-ms) now)))
                                        (let ((by (getf m :by))) (and (stringp by) (plusp (length by)) by))
                                        (let ((why (getf m :why))) (and (stringp why) (plusp (length why)) (%first-line why))))
                                '(:dim t))))
                  moves)))))

(defun %gate-evidence-tag (tg)
  "The evidence's opening WORD — `GATE_KILLED`, `GATE_SETUP_FAILED`, or whatever else — or NIL.

 It is a WORD because that is the daemon's own shape (`c88ba67`: *the evidence opening `GATE_KILLED`*),
 and reading it as one keeps this from matching a tag that merely appears later in the sentence."
  (let ((e (or (getf tg :evidence) "")))
    (when (plusp (length e))
      (let ((sp (position #\space e)))
        (subseq e 0 (or sp (length e)))))))

(defun %gate-unjudged-reason (tg)
  "What the daemon says killed it, in ITS OWN WORDS — the evidence minus its opening tag, first line.

 **The head does not name the reason, and that is the reference's rule**: *a killed step is not drawn as
 `failed`; what killed it is the line's word*. A memory cap, the machine, a setup that broke — the
 daemon wrote which, so this prints what it wrote rather than inventing a category."
  (let* ((e (or (getf tg :evidence) ""))
         (sp (position #\space e))
         (rest (string-left-trim " " (if sp (subseq e (1+ sp)) e)))
         (nl (position #\newline rest)))
    (let ((said (string-trim " " (subseq rest 0 (or nl (length rest))))))
      (if (plusp (length said)) said "the gate could not judge the code"))))

(defun %queue-tab-strip (standings)
  "`[review queue (N)]  merge queue (M)   · /queue review|merge switches` — the view that is up in
bold, the other faint, each with its OPEN count."
  (flet ((label (view word count)
           (if (eq *queue-view* view)
               (cons (format nil "[~a queue (~d)]" word count) '(:bold t))
               (cons (format nil " ~a queue (~d) " word count) '(:dim t)))))
    (list (cons "  " nil)
          (label :review "review" (getf standings :review))
          (label :merge "merge" (getf standings :merging))
          (cons "   · /queue review|merge switches" '(:dim t)))))

(defun %queue-header-lines (snapshot now w)
  "The emergencies first, then who serves each repository — the reference's order, because *a red
main is a high-severity emergency* and a lease nobody holds means nothing is being served."
  (let ((out nil))
    (let ((unreadable (getf snapshot :unreadable)))
      (when (and (stringp unreadable) (plusp (length unreadable)))
        (push (list (cons (truncate-to-width (format nil "  ⚠ the store ~a" unreadable) w) (role-look :failure))) out)))
    (dolist (tg (getf snapshot :targets))
      (let* ((sha (let ((s (or (getf tg :sha) ""))) (subseq s 0 (min 10 (length s)))))
             (repo (%repo-name (getf tg :repository)))
             (state (or (getf tg :state) "")))
        (cond ((string= state "red")
               (push (list (cons "  ‼ EMERGENCY " (role-look :failure))
                           (cons (truncate-to-width
                                  (format nil "`~a` is RED at ~a in ~a — nothing lands but its fix; its tip is first in review · ~a"
                                          (getf tg :target) sha repo (%dur-human (- now (or (getf tg :checked-ms) now))))
                                  (max 1 (- w 14)))
                                 (role-look :failure)))
                     out))
              ;; **AND A GATE THAT COULD NOT JUDGE IS NOT A FAILED ONE** (letibot R87, `c88ba67`) — and this
              ;; arm is ABOVE the `blocked` one for that reason: a killed step IS `blocked` as far as the
              ;; snapshot's state goes, so the arm below would call it failed and print the raw tag as
              ;; the reason, which is exactly the wrong line the reference fixed.
              ((member (%gate-evidence-tag tg) '("GATE_KILLED" "GATE_SETUP_FAILED") :test #'string=)
               (push (list (cons (truncate-to-width
                                  (format nil "  ‼ `~a` UNJUDGED at ~a in ~a — ~a"
                                          (getf tg :target) sha repo (%gate-unjudged-reason tg))
                                  w)
                                 (role-look :failure)))
                     out))
              ((member state '("timed_out" "blocked") :test #'string=)
               (push (list (cons (truncate-to-width
                                  (format nil "  ⚠ `~a` in ~a is ~a at ~a: ~a — nothing lands until it is green"
                                          (getf tg :target) repo (substitute #\space #\_ state) sha
                                          (%first-line (getf tg :evidence)))
                                  w)
                                 (role-look :attention)))
                     out))
              ((string= state "gating")
               (push (list (cons (format nil "  … `~a` in ~a is being gated at ~a" (getf tg :target) repo sha)
                                 (role-look :pending)))
                     out))
              (t
               (push (list (cons (format nil "  ✓ `~a` in ~a is green at ~a" (getf tg :target) repo sha)
                                 (role-look :success)))
                     out)))))
    (let ((leases (getf snapshot :leases)))
      (dolist (l leases)
        (let* ((age (- now (or (getf l :heartbeat-ms) 0)))
               (stale (> age +lease-stale-ms+)))
          (push (list (cons (truncate-to-width
                             (format nil "  ~a ~a served by ~a (pid ~a, ~a) · heartbeat ~a ago~a"
                                     (if stale "⚠" "◆")
                                     (%repo-name (getf l :repository))
                                     (or (getf l :host) "?") (or (getf l :pid) "?") (or (getf l :build) "?")
                                     (%dur-human age)
                                     (if stale " — STALE: another daemon takes it over" ""))
                             w)
                            (if stale (role-look :attention) (role-look :faint))))
                out)))
      (when (null leases)
        (push (list (cons "  ⚠ no daemon holds a queue lease — nothing is serving the queues" (role-look :attention))) out)))
    (nreverse out)))

(defun merge-queue-lines (head cols)
  "The review queue and the merge queue — the rows the `/queue` pane draws (R61, protocol 43).

From the daemon's one snapshot (`*queues*`), in the reference's order (`ui/panes/queue.rs`):

  · **the emergencies first** — a RED target branch at emergency severity, a target timed out or
    blocked, and a snapshot that could not be read, said in its own words and never drawn as an
    empty queue;
  · **who serves each repository** — the lease's owner, build and heartbeat age, STALE past 90 s;
  · **the tab strip** — which view is up, with each queue's open count;
  · **the view's rows** — each says its state, how long it has been IN that state (not since it
    was created, which was the old pane's lie), the repository and the daemon working it; the
    cursor's row carries its last moves and, in the merge view, the gate's steps;
  · and the footer with the archived count and the verbs' typed spelling.

**STATE AND EVIDENCE, and the evidence is the whole point of the field**: a move without its reason
is a row that changed state with nothing saying why, so no state is drawn without its evidence when
there is one, and a row with none says so. **States are drawn as the WORDS the wire carries** — a
word this build has never met is drawn plain rather than guessed at (`merge-state-style`).

The rows are `head-merge-queue` — the current view's — and the ASK is `/queue`'s own act and the
pane's 5 s re-read (`tick-queues`), which is what keeps a frame out of a renderer."
  (let* ((w (pane-width cols))
         (entries (head-merge-queue head))
         (now (queue-now-ms))
         (standings (queue-standings head))
         (out (list (list (cons "review queue · merge queue" '(:bold t)))
                    ;; **AND WHICH SCOPE THIS IS** (letibot R92.5): the pane can show one repository or
                    ;; all of them, and a reader who widened it has to be able to see that they did.
                    (list (cons (queue-scope-line head) '(:dim t))))))
    (push nil out)
    (when *queues*
      (dolist (l (%queue-header-lines *queues* now w)) (push l out))
      (push nil out)
      (push (%queue-tab-strip standings) out)
      (push nil out))
    (if (null entries)
        (cond ((null *queues*)
               (push (list (cons "    empty — nothing is waiting to land, and nothing is in review" '(:dim t))) out)
               (push nil out)
               (push (list (cons "    `/queue` asks the daemon for it again; rows arrive as they are filed"
                                 '(:dim t)))
                     out))
              ((eq *queue-view* :merge)
               (push (list (cons "    none. A branch lands here once its review approves it, at the head that was reviewed."
                                 '(:dim t)))
                     out))
              (t
               (push (list (cons "    none. A branch is put up for review when a `task_start` child finishes."
                                 '(:dim t)))
                     out)))
        (dolist (e entries)
          (let* ((id (or (getf e :id) "?"))
                 (branch (if (equal (getf e :kind) "target")
                             (format nil "RED TARGET `~a`" (or (getf e :target) "?"))
                             (or (getf e :branch) "?")))
                 (state (or (getf e :state) "?"))
                 (evidence (getf e :evidence))
                 (merge-row (equal (queue-row-queue e) "merge"))
                 ;; the cursor's entry is REVERSED, exactly as every other pane's is
                 (picked (= (or (position id entries :key (lambda (x) (getf x :id)) :test #'equal) -1)
                            (head-picker-sel head))))
            (push (append
                   (list (cons "  ▸ " '(:dim t))
                         (cons (format nil "[~a] " state) (merge-state-style state))
                         (cons branch (if (equal (getf e :kind) "target")
                                          (append (and picked '(:reverse t)) (role-look :failure))
                                          (and picked '(:reverse t)))))
                   ;; **TIME IN THE CURRENT STATE**, the repository and the daemon working it — the
                   ;; fields protocol 43 added; a row from a hand-made fixture carries none and draws
                   ;; none
                   (when (getf e :state-ms)
                     (list (cons (format nil " · ~a in state~@[ · ~a~]~@[ · by ~a~]~a"
                                         (%dur-human (- now (getf e :state-ms)))
                                         (and (getf e :repository) (%repo-name (getf e :repository)))
                                         (let ((o (getf e :owner))) (and (stringp o) (plusp (length o)) (%owner-word o)))
                                         (if (getf e :fixes) " · FIX for the red target" ""))
                                 '(:dim t)))))
                  out)
            ;; the row's own identity and the verdict, when the wire gave them
            (when (or (getf e :head-sha) (getf e :approved-sha) (getf e :verdict))
              (push (list (cons (truncate-to-width
                                 (format nil "         ~a~@[ · head ~a~]~@[ · approved ~a~]~@[ · ~a~]"
                                         id
                                         (let ((s (getf e :head-sha))) (and (stringp s) (plusp (length s)) (subseq s 0 (min 10 (length s)))))
                                         (let ((s (getf e :approved-sha))) (and (stringp s) (plusp (length s)) (subseq s 0 (min 10 (length s)))))
                                         (getf e :verdict))
                                 w)
                                '(:dim t)))
                    out))
            ;; **`priority` AND `needs` ARE DRAWN, because the daemon sends them and a reader
            ;; deciding what to look at wants both**: the priority is the queue's own rank, and
            ;; `needs` is the list of entries this one waits for.
            (when (or (getf e :priority) (and (getf e :needs) (plusp (length (getf e :needs)))))
              (push (list (cons (format nil "         ~@[~a~]~@[ · needs ~{~a~^, ~}~]"
                                        (getf e :priority) (getf e :needs))
                                '(:dim t)))
                    out))
            ;; **SAID IN PLAIN LISP, not with format gymnastics** — the first cut used `~@[…~]~:[…~]`
            ;; and got the branches the wrong way round, which is how a renderer comes to say *no
            ;; reason given* about a row that has one.
            (push (list (cons (truncate-to-width
                               (format nil "         ~a" (if (and (stringp evidence) (plusp (length evidence)))
                                                             (%first-line evidence)
                                                             "no reason given"))
                               w)
                              '(:dim t)))
                  out)
            ;; a review's reasons, one per row, when the reviewer gave any
            (dolist (reason (getf e :reasons))
              (push (list (cons (truncate-to-width (format nil "         · ~a" reason) w) '(:dim t))) out))
            ;; **AND THE GATE'S STEPS, IN THE ORDER `main` DECLARED THEM.** Each
            ;; `{command, outcome, output, started_ms, elapsed_ms}`, where the command is *the string a
            ;; person would paste into a shell to reproduce the row*.
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
            ;; **AND THE ENTRIES THIS ONE DEPENDS ON OR IS REVIEWED BY** — `merge-review-line` keeps
            ;; a review's three facts apart; a review that has been asked and has not answered
            ;; draws nothing, so the filter is here rather than in the renderer's caller.
            (dolist (review (getf e :reviews))
              (let ((line (merge-review-line review)))
                (when line
                  (push (list (cons (format nil "         ~a" line) '(:dim t))) out))))
            ;; nothing at all: said, not shown as a checklist that looks complete — a MERGE row's
            ;; fact (a review has no gate), and a hand-made row's
            (when (and (null (getf e :gate-steps)) (or merge-row (null (getf e :queue))))
              (push (list (cons "         the gate has not run on this entry" '(:dim t))) out))
            ;; **THE SELECTED ROW'S MOVES** — the transition history (R61 requirement 2)
            (when picked
              (dolist (l (%queue-move-lines id 3 now "         ")) (push l out))))))
    (when (and *queues* (integerp (getf *queues* :archived)) (plusp (getf *queues* :archived)))
      (push nil out)
      (push (list (cons (format nil "    ~d row(s) of the pre-split queue are archived (merge_queue_v23)"
                                (getf *queues* :archived))
                        '(:dim t)))
            out))
    (push nil out)
    (push (list (cons (format nil "    ~d entries — `q` closes · enter opens the row whole · /queue approve|veto|rm|restart ID"
                              (length entries)) '(:dim t)))
          out)
    (nreverse out)))

(defun merge-state-style (state)
  "The register a queue STATE is drawn in — the same vocabulary the panes already use: a landed
entry is Success, a failure or a conflict is Failure, a waiting or stale one is Pending, and a
state this build has never met is drawn plain rather than guessed at."
  (cond ((member state '("landed" "approved") :test #'string-equal) (role-look :success))
        ;; **PROTOCOL 43's WORDS JOIN THE V23 ONES** (`event.rs`, `QueueReview.state` and
        ;; `QueueMerge.state`): a merge `timed_out` or `blocked` is the machine saying no, like a
        ;; failed gate; a review `rejected` or `cannot_decide` is a verdict a PERSON has to look at,
        ;; which is the Attention register and not Failure — the reference's `mark_of` draws the
        ;; same split. `reviewing`, `gating` and `queued` are in flight, beside `waiting`.
        ((member state '("failed" "conflict" "timed_out" "blocked") :test #'string-equal) (role-look :failure))
        ((member state '("rejected" "cannot_decide") :test #'string-equal) (role-look :attention))
        ((member state '("reviewing" "gating" "queued") :test #'string-equal) (role-look :pending))
        ;; **`taken` IS IN FLIGHT, WHICH IS A FACT RATHER THAN A TASTE** — the daemon's own
        ;; `MergeState::Taken` means a runner has the entry, so it belongs in the register *is
        ;; happening* beside waiting and stale. MEASURED against `tokencore/src/store.rs`, whose
        ;; enum has SEVEN states (`Waiting, Taken, Landed, Failed, Conflict, Stale, Vetoed`) while
        ;; this head's first cut mapped five.
        ((member state '("waiting" "stale" "taken" "running") :test #'string-equal) (role-look :pending))
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

(defvar *queue-scope* :here
  "Which repository the `/queue` PANE shows — `:here` (this session's, the default), `:all`, or a path.

 **THE PANE'S SCOPE, AND NOT THE EDGE'S** (letibot R92.5, `031239d`). The edge ALWAYS counts this
 session's repository whatever the pane shows — that is `%queue-scope`, a different question with a
 different answer — and collapsing the two is how a pane that a reader widened would start alarming
 about other trees in the chrome.

 `:here` is the DEFAULT because the daemon serves every repository at once and a pane that opened on
 all of them made the reader hunt for their own work among strangers'. `/queue all` widens it and
 `/queue /PATH` narrows it to one tree the reader names.")

(defun queue-pane-scope (head)
  "The repository the PANE filters to — a directory name, or NIL for *show everything*.

 NIL has two causes and both mean the same to the caller: `/queue all`, and a session whose repository
 this head cannot name — because a filter it cannot evaluate must not hide rows it cannot judge."
  (cond ((eq *queue-scope* :all) nil)
        ((stringp *queue-scope*) (string-right-trim "/" *queue-scope*))
        (t (%queue-scope head))))

(defun queue-scope-line (head)
  "The pane's own sentence about WHICH repository it is showing — never NIL.

 **A FILTER NOBODY CAN SEE IS A PANE THAT LIES ABOUT WHAT EXISTS** (letibot R92.5): the pane can show
 one repository or all of them, and a reader who widened it has to be able to see that they did.

 **And a session in no repository is TOLD, not filtered**: `%queue-scope` answers NIL when it cannot
 name one, so the pane shows everything — which is the right answer and would be a confusing one without
 this line saying why. That case names no verb, because there is nothing to come back from."
  (let ((scope (queue-pane-scope head)))
    (cond ((stringp *queue-scope*) (format nil "showing ~a only · /queue here comes back" scope))
          ((eq *queue-scope* :all) "showing every repository · /queue here for this one only")
          (scope (format nil "showing ~a only · /queue all for every repository" scope))
          (t "this session is in no repository — showing every repository"))))

(defun %queue-scope (head)
  "The repository the EDGE counts, or NIL when this head cannot name one.

 **THE EDGE ALWAYS COUNTS THIS SESSION'S REPOSITORY ONLY, whatever the pane shows** (letibot
 `031239d`, R92.5): the queues are DAEMON-level, so one snapshot holds every repository's rows, and an
 unscoped edge counted another tree's red target as this session's emergency.

 The answer is the SAME RESOLVER the git field uses (`%project-dir`, with its follow-the-work case),
 so the two cannot disagree about which repository this session is in. Both sides are trimmed of a
 trailing slash: a directory name has one and the wire's `repository` does not."
  (let ((dir (and head (%project-dir (getf (session-wiring (head-session head)) :workspace) head))))
    (and dir (string-right-trim "/" (namestring dir)))))

(defun %queue-row-here-p (row scope)
  "Is ROW's repository SCOPE's? **TRUE when SCOPE is NIL** — a head that cannot name its repository
 counts everything rather than nothing, which is every head with no workspace, and the behaviour this
 had before it was scoped."
  (or (null scope)
      (equal scope (string-right-trim "/" (or (getf row :repository) "")))))

(defun queue-standings (head)
  "The queues' standings for the edge and the tab strip — `(:review N :merging N :parked N :red N)`,
the reference's `Standings` (`ui/panes/queue.rs:queue_standings`): in review (`waiting`/`reviewing`),
being merged (`queued`/`gating`), parked — *what a person has to act on* (a review `blocked`/
`rejected`/`cannot_decide`, a merge `blocked`/`failed`/`timed_out`/`conflict`) — and how many targets
are RED.

Read from the snapshot when there is one; a head holding rows with no snapshot (a fixture, a
daemon older than 43) is counted by the v23 words it has — `waiting`, `taken`, and the four parked
states — so the edge never goes blank over rows it can see."
  (if *queues*
      (let ((review 0) (merging 0) (parked 0)
            ;; **THE SCOPE THE EDGE COUNTS IN** (letibot `031239d`): this session's repository, from
            ;; the same resolver the git field uses. NIL means *cannot say*, and counts everything.
            (scope (%queue-scope head)))
        (dolist (r (getf *queues* :reviews))
          (let ((s (or (getf r :state) "")))
            (when (%queue-row-here-p r scope)
              (cond ((member s '("waiting" "reviewing") :test #'string=) (incf review))
                    ((member s '("blocked" "rejected" "cannot_decide") :test #'string=) (incf parked))))))
        (dolist (m (getf *queues* :merges))
          (let ((s (or (getf m :state) "")))
            (when (%queue-row-here-p m scope)
              (cond ((member s '("queued" "gating") :test #'string=) (incf merging))
                    ((member s '("blocked" "failed" "timed_out" "conflict") :test #'string=) (incf parked))))))
        (list :review review :merging merging :parked parked
              :red (count-if (lambda (tg) (and (%queue-row-here-p tg scope)
                                               (equal "red" (getf tg :state))))
                             (getf *queues* :targets))
              ;; **AND THE TARGETS A PERSON HAS NOT JUDGED** (letibot `031239d`): `timed_out` and
              ;; `blocked` are the states where the queue waits on a HUMAN, so they belong on the edge
              ;; as alarms rather than in a pane nobody has open.
              :unjudged (count-if (lambda (tg) (and (%queue-row-here-p tg scope)
                                                    (member (getf tg :state) '("timed_out" "blocked")
                                                            :test #'string=)))
                                  (getf *queues* :targets))))
      (let ((entries (head-merge-queue head)))
        (list :review (count-if (lambda (e) (member (getf e :state) '("waiting" "reviewing") :test #'string-equal)) entries)
              :merging (count-if (lambda (e) (member (getf e :state) '("taken" "queued" "gating") :test #'string-equal)) entries)
              :parked (count-if (lambda (e) (member (getf e :state)
                                                    '("failed" "conflict" "stale" "vetoed" "timed_out" "blocked"
                                                      "rejected" "cannot_decide")
                                                    :test #'string-equal))
                                entries)
              :red 0))))

(defun merge-standings-line (head)
  "The queues' counts, as the composer edge draws them — or NIL when NOTHING STANDS.

**MEASURED, not invented** (`ui/panes/queue.rs`): `Standings` is `review` (*in the queue, not taken
— the gatekeeper's review is what it waits on*), `merging` and `parked` (*the queue has stopped, and
a person moves it*) — and, since protocol 43, how many target branches are RED, which is the one
count that is an emergency and is drawn whenever it is not zero.

**AND NOTHING STANDS FOR A QUEUE THAT IS EMPTY OR ALL-LANDED, so the edge says NOTHING** — not
`0 in review · 0 being merged · 0 parked`: *a row of zeroes is a row of attention paid for ever for
a fact nobody has*. The disclosure is `/queue`, which says *none* in words. And when something DOES
stand, **all three counts are drawn, zeroes included**, because a count that vanishes reads as
though the queue had forgotten it."
  (let* ((s (queue-standings head))
         (review (getf s :review)) (merging (getf s :merging)) (parked (getf s :parked))
         (red (or (getf s :red) 0))
         (unjudged (or (getf s :unjudged) 0)))
    (when (plusp (+ review merging parked red unjudged))
      (format nil "~d in review · ~d being merged · ~d parked~a~a" review merging parked
              (if (plusp red) (format nil " · ~d RED target~:p" red) "")
              ;; **AND THE TARGETS NOBODY HAS JUDGED** (letibot `031239d`): a `timed_out` or `blocked`
              ;; target is one where the queue is waiting on a PERSON, so it is the second thing this
              ;; row says whenever it is not zero — a count, not an alarm, was the reference's whole
              ;; complaint about the pane being the only place it showed.
              (if (plusp unjudged) (format nil " · ⚠ ~d target~:p unjudged" unjudged) "")))))

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

