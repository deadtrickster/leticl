;;;; subagents.lisp — the subagents pane: the tree this session spawned, and what the
;;;; `o` key does on one of its rows (attach this head to it).
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

(defun subagent-rows (head)
  "The subagents this session spawned, oldest first, one row per subagent — the
reference's `subagents: Vec<SubagentState>`, folded the same way.

The `Subagent` events arrive one per state change and `apply-event` keeps them
all (newest first, in `session-subagents`); the reference folds each into the row
with the same id so `running` becomes `done` rather than a second line
(app.rs:1846). This is that fold, done at draw time so the wire state stays what
the daemon sent. The id is the event's `subagent_id` — the envelope's own
`session_id` is the PARENT's (event.rs:841), and a fold keyed on that counted every
child of one session as one subagent. Rows are `(:session-id :state :prompt :answer :role :task :model)` — and the slot is
also seeded from a SNAPSHOT's `subagents` field (`%subagent-view->event`), which is
what brings the parent's tree back on a switch back: a seeded envelope carries
`:answer` under its own name and `:task` in full, and the fold cannot tell it from
the live thing."
  (let ((rows nil))
    (dolist (env (reverse (session-subagents (head-session head))))
      (let* ((id (or (getf env :subagent-id) (getf env :session-id)))
             (row (find id rows :key (lambda (r) (getf r :session-id)) :test #'equal)))
        (if row
            (setf (getf row :state) (getf env :state)
                  ;; **AN EXPLICIT `:answer` KEY WINS, and truth is not the test.** A current
                  ;; daemon's events carry `answer` under its own name (`#[serde(default)]`, so
                  ;; nil while the child runs — said, not absent); the SNAPSHOT's seeded rows
                  ;; carry it too (`%subagent-view->event`). An OLDER daemon's events have no
                  ;; key at all, and for those the finish's `prompt` still IS the answer —
                  ;; presence, not truth, separates *there is none* from *it cannot say*.
                  (getf row :answer) (if (member :answer env)
                                         (getf env :answer)
                                         (getf env :prompt))
                  (getf row :role) (getf env :role)
                  ;; `task`/`model` are the same on every state, so last non-empty wins —
                  ;; a first event from an older daemon has neither, and a later one from
                  ;; a current daemon should still put them on the row
                  (getf row :task) (or (and (plusp (length (or (getf env :task) "")))
                                            (getf env :task))
                                       (getf row :task))
                  (getf row :model) (or (and (plusp (length (or (getf env :model) "")))
                                             (getf env :model))
                                        (getf row :model)))
            (push (list :session-id id :state (getf env :state)
                        ;; **THE TITLE IS THE TASK IN FULL WHEN THE WIRE CARRIES IT** — the
                        ;; event's own rule (event.rs, `Subagent::prompt`): `prompt` means the
                        ;; subtask's first line while the child opens and the ANSWER's first line
                        ;; on the finish, and a row titled by the last event's `prompt` is titled
                        ;; by its own answer. `task` is the subtask whole, the same on every
                        ;; state, and this head truncates for a row as it does for everything
                        ;; else it draws — which is the reference's own row. `task` empty is a
                        ;; daemon older than the field: `prompt`'s first line, the pre-field
                        ;; behaviour, and the pane's own comment about *the fold keeps the task*
                        ;; is finally true rather than aspirational.
                        :prompt (let ((task (or (getf env :task) "")))
                                  (if (plusp (length task)) task (getf env :prompt)))
                        :answer (and (member :answer env) (getf env :answer))
                        :role (getf env :role)
                        :task (getf env :task)
                        :model (getf env :model))
                  rows))))
    (nreverse rows)))

(defvar *subagents-finished-open* nil
  "Whether the `finished (N)` group on the subagents pane is UNFOLDED.

COLLAPSED BY DEFAULT, which is the operator's own ruling (2026-10-06): *'i went to
subagents panel and dont see it here'* — a child just started, and the pane drew the
finished ones first and pushed the running one off the bottom — and then *'please group
finished separately in the finished group which will be collapsed'*. A pane opened to see
what is happening shows what is happening; what finished is one row and one enter away.

A `defvar` like `*repo-todo-open*`: where your eyes are, not a preference, and not a head
slot (a struct layout change is a restart).")

(defun %subagent-finished-p (row)
  "Is ROW a settled child? Anything but `running` and `opening` — `done`, `failed`, and a
row with NO state word, which is the honest reading for a row the daemon's session list
rebuilt: that list says whether a turn is generating and nothing about how a settled child
ended."
  (not (member (or (getf row :state) "") '("running" "opening") :test #'string=)))

(defun %subagents-all-rows (head)
  "The pane's rows: the events' fold, then the list-derived strangers. ONE function,
because stops, lines and the stop resolution must all see the same list — an enumeration
over one list acting on another is the defect `todos-stops` names."
  (append (subagent-rows head) (%list-derived-subagent-rows head)))

(defun %list-derived-subagent-rows (head)
  "Children of THIS session the events never mentioned, from the session list — or nothing.

**THE FALLBACK THE REFERENCE'S PANE HAS AND THIS ONE LACKED** (found live, 2026-10-09: the
rano head, four children running, the pane empty). A daemon that is REPLACED loses its
registry — the registry is in memory — and the store keeps transcript rows, not
`SessionEvent`s, so the replacement's view folds no `Subagent` events and its snapshot
carries no children. Children that SURVIVED the restart (they are processes of their own)
were adopted by the new daemon's task table without a new spawn, and a spawn is the only
thing that publishes the event. Result: a head attached after the restart — any head, the
reference included — has no events and no seed, and the pane is empty while four agents
run. The reference's pane draws list-derived rows in exactly this case (*'a head then
draws the list-derived rows it always did'*, view.rs); this is that half.

**The list says less than the event, and the row says so.** `:running` in a brief is *a
turn is generating in that session at this instant* — for a child parked on its own
background job it is NIL while the child is perfectly alive, so a generating child is
`running` (it is, right now) and everything else carries NO state word: `[?]` and *state
unknown*, which is a fact about the host that was not watching, not an invented `done`.
The title is the picker's derive_title — the task's first line, the best the list has.
The model comes from the brief's wiring, which the child inherited or chose.

Rows already known from an event or the snapshot seed are LEFT ALONE — the event's words
are richer (the whole task, the role, the answer) and the list cannot improve them."
  (let ((mine (session-session-id (head-session head)))
        (out nil))
    (unless (or (null mine) (zerop (length mine)))
      (dolist (brief (session-sessions (head-session head)))
        (let ((parent (getf brief :parent-session-id)))
          (when (and parent (string= parent mine))
            (let ((id (getf brief :session-id)))
              (unless (find id (subagent-rows head)
                            :key (lambda (r) (getf r :session-id)) :test #'string=)
                (let* ((running (getf (getf brief :status) :running))
                       (live (getf brief :live))
                       (stored (getf brief :stored-end))
                       (kind (and (listp stored) (getf stored :kind)))
                       (answered (and (stringp kind) (string= kind "answered"))))
                  (push (list :session-id id
                              ;; **HOW IT ENDED, IN WORDS, AFTER A RESTART** (letibot
                              ;; `8eb9135`, the reference's own four-arm rule read off
                              ;; `panes.rs`): generating is `running`; a last item that was
                              ;; a finished assistant answer is `done`; a mid-turn last item
                              ;; on a session nobody is attached to is `stopped mid-turn` —
                              ;; three different facts that used to be one silence, and the
                              ;; reader had no way to tell a child that answered from one
                              ;; that died in the middle. Nothing at all is still nothing:
                              ;; the list must not guess.
                              :state (cond (running "running")
                                           (answered "done")
                                           ((and (stringp kind)
                                                 (string= kind "mid_turn")
                                                 (not live))
                                            "stopped mid-turn")
                                           (t ""))
                              ;; and the answer itself when there is one to show: the first
                              ;; line of its last words, which the fact line draws as the
                              ;; row's last clause
                              :answer (and answered (not running)
                                           (getf stored :first-line))
                              :prompt (or (getf brief :title) "")
                              :role ""
                              :task "" :model (or (getf (getf brief :wiring) :model) ""))
                            out))))))))
    (nreverse out)))

(defun subagents-stops (head)
  "The rows the subagents pane's cursor may land on, in the order the pane draws them:
the children still going first (in spawn order), then ONE `finished` group row when any
finished exist, then — only while the group is unfolded — the finished children.

Tags, not positions: `(:agent . I)` is the Ith of `subagent-rows`, `(:finished)` is the
group row. ONE enumeration, read by the drawing, the arrows, Enter, `o` and `p` alike —
the drawn `▸` and the key that acts cannot disagree about which row is selected, which is
the defect `todos-stops` exists for and this pane now shares its rule.

The children still going are NEVER pushed off the bottom by the finished ones, which is
the whole point: the row the operator opened the pane to see is at the top."
  (let* ((rows (%subagents-all-rows head))
         (actives (loop for r in rows for i from 0
                        unless (%subagent-finished-p r) collect (cons :agent i)))
         (finished (loop for r in rows for i from 0
                         when (%subagent-finished-p r) collect (cons :agent i))))
    (append actives
            (and finished
                 (cons '(:finished)
                       (and *subagents-finished-open* finished))))))

(defun subagent-stop-at (head)
  "The stop the subagents cursor is on — `(:agent . I)` or `(:finished)` — and the ROW
under it (NIL for the group row, which is a heading and not a child)."
  (let* ((stops (subagents-stops head))
         (n (length stops))
         (sel (if (plusp n) (min (max 0 (head-picker-sel head)) (1- n)) 0))
         (stop (nth sel stops)))
    (values stop
            (and stop (eq (car stop) :agent)
                 (nth (cdr stop) (%subagents-all-rows head))))))

(defun subagent-lines (head cols)
  "The subagent tree, the reference's own frame (rano's `SubagentsPane::content`):

    subagents
    <blank>
      ▸ [~] the task it was asked, whole
           …3908838 · role coder · on glm · running
      · [+] finished (2)
           enter shows the ones that have ended
    <blank>
        arrows move · enter or o switches into the subagent, or folds the finished group ·
        p reads its prompt · esc closes

The children still going first, then ONE `finished (N)` row that stays folded unless the
operator unfolded it (see `*subagents-finished-open*`). The second line is the row's own
facts as CLAUSES THAT VANISH when the daemon did not say them — a row rebuilt from the
session list carries a name and a model and no role, and a fixed `role X · state` would
draw two holes on every rebuilt row.

Returns the lines and, as a second value, the LINE the cursor is on. Every stop draws
exactly two lines — the row and its fact line — which is also what the click conversion
assumes (`per-row 2`), so a click on either half of either kind of stop is the same stop."
  (let* ((w (pane-width cols))
         ;; **THE UNION: the events' rows, then the list-derived ones the events never
         ;; mentioned.** The derived rows sit AFTER the known actives because they are
         ;; strangers with less to say — but they are drawn, which is the whole fix.
         (rows (%subagents-all-rows head))
         (stops (subagents-stops head))
         (n (length stops))
         (sel (if (plusp n) (min (max 0 (head-picker-sel head)) (1- n)) 0))
         (out (list nil (list (cons "subagents" '(:bold t))))))
    (when (null rows)
      (push (list (cons "    none spawned yet. The model spawns them with the task tool."
                        '(:dim t)))
            out))
    (loop for k from 0
          for stop in stops
          for picked = (= k sel)
          do (cond
               ((eq (car stop) :finished)
                ;; **THE GROUP ROW: a heading and not a child.** There is nobody to switch
                ;; into, and Enter (and `o`, which does the same) folds or unfolds — the
                ;; one key a group row owns. `[+]` folded, `[-]` open, the count beside the
                ;; word, and the faint line under it says what the key does in the state it
                ;; is in, which is how a fold teaches itself.
                (let ((n-finished (count-if #'%subagent-finished-p rows)))
                  (push (list (cons (format nil "~a " (if picked "▸" " "))
                                    (and picked '(:reverse t)))
                              (cons (if *subagents-finished-open* "[-]" "[+]")
                                    (and picked '(:reverse t)))
                              (cons (format nil " finished (~d)" n-finished)
                                    (and picked '(:reverse t))))
                        out)
                  (push (list (cons (if *subagents-finished-open*
                                        "       the ones that have ended · enter folds them away"
                                        "       enter shows the ones that have ended")
                                      '(:dim t)))
                        out)))
               (t
                (let* ((s (nth (cdr stop) rows))
                       (state (or (getf s :state) ""))
                       (mark (cond ((string= state "opening") "[…]")
                                   ((string= state "running") "[~]")
                                   ((string= state "done") "[x]")
                                   ((string= state "failed") "[!]")
                                   ;; no state word — a row rebuilt from the session list,
                                   ;; which cannot say how a settled child ended. `[?]`
                                   ;; means THE HOST WAS NOT WATCHING, not `done`.
                                   (t "[?]")))
                       (colour (cond ((string= state "running") '(:fg :yellow))
                                     ((string= state "done") '(:fg :green))
                                     ((string= state "failed") '(:fg :red))
                                     (t nil))))
                  (push (list (cons (format nil "~a " (if picked "▸" " "))
                                    (and picked '(:reverse t)))
                              (cons mark (if picked (append '(:reverse t) colour) colour))
                              (cons (format nil " ~a" (or (getf s :prompt) ""))
                                    (and picked '(:reverse t))))
                        out)
                  ;; **THE ROW'S OWN FACTS, as clauses that vanish when unsaid.** The id
                  ;; first (it is the lookup key), then `role X` and `on MODEL` only when
                  ;; the daemon sent them — the model clause is the operator's 2026-10-05
                  ;; ask, a tree of children on different models is a fact the pane has to
                  ;; show. The state word: `state unknown` for a rebuilt row, the word
                  ;; itself otherwise. The ANSWER joins as the last clause when there is
                  ;; one — the row is the question and the fact line carries what the
                  ;; child said (the operator's own two-line ask). `not attachable yet`
                  ;; while the child is still opening, in the row's own words.
                  (let ((clauses (list (format nil "…~a"
                                               (subseq (or (getf s :session-id) "")
                                                       (max 0 (- (length (getf s :session-id)) 7)))))))
                    (when (plusp (length (getf s :role)))
                      (push (format nil "role ~a" (getf s :role)) clauses))
                    (when (plusp (length (or (getf s :model) "")))
                      (push (format nil "on ~a" (getf s :model)) clauses))
                    (push (if (zerop (length state)) "state unknown" state) clauses)
                    (when (and (getf s :answer) (string= state "done"))
                      (push (getf s :answer) clauses))
                    (when (string= state "opening")
                      (push "not attachable yet" clauses))
                    (push (list (cons (truncate-to-width
                                       (format nil "       ~{~a~^ · ~}" (reverse clauses))
                                       w)
                                      '(:dim t)))
                          out))))))
    (push nil out)
    (push (list (cons "    arrows move · enter or o switches into the subagent, or folds the finished group · p reads its prompt · esc closes"
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel)))))

;;;; The repo's TODO.md, read the way org reads it.
;;;;
;;;; Three commits in the reference are one feature here, and each is measured
;;;; from the operator's own words in them:
;;;;
;;;;   *"our todo pane doesnt render them - only section titles and sub todos
;;;;    count. make sure it follows org mode - subtodos shown, when all subtodos
;;;;    checked section becomes also checked"*
;;;;   *"colors?"*
;;;;   *"if a todo has some associated text? should i be able to expand it
;;;;    somehow?"*


;;; ------------------------------------------ `o` on a subagent row ;;;

(defun subagent-switch (head)
  "Switch this head INTO the subagent under the cursor — the reference's
`Key::Char('o')` on the subagents pane (app.rs:3696-3707). T when a frame went
out.

The pane's own footer has advertised this since it was written
(`arrows move, Enter reads the subagent's output, o switches into it`) and no key
was ever bound to it, so the one row on the screen that names a key named a key
that did nothing. A subagent still `opening` has no session to switch to yet, and
the row already says `— not attachable yet`; refusing here with the same words is
what keeps the two from disagreeing.

The KEY is `src/editor.lisp:283-296`'s — its `:char` arm handles only `#\\q` —
and this is the act that arm is missing."
  (multiple-value-bind (stop row) (subagent-stop-at head)
    (cond
      ;; **THE GROUP ROW IS NOT A CHILD.** There is nobody to switch into; `o` does what
      ;; Enter does here and folds the group, which is the one key a heading owns. Said,
      ;; because a key that appears to do nothing on the row it was pressed on is the
      ;; defect this pane's own footer exists to prevent.
      ((eq (car stop) :finished)
       (setf *subagents-finished-open* (not *subagents-finished-open*)
             (head-dirty head) t)
       (say head (if *subagents-finished-open*
                     "finished group open"
                     "finished group folded"))
       t)
      ((null row) (say head "no subagent under the cursor") nil)
      ((string= (or (getf row :state) "") "opening")
       (say head "not attachable yet — it is still opening") nil)
      ((null (getf row :session-id))
       (say head "that subagent has no session id to switch to") nil)
      (t (%send head (make-switch (getf row :session-id) 0))
         (setf (head-mode head) :normal
               (head-dirty head) t)
         t))))
