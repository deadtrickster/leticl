;;;; the-operator-todos — the operator's own todo items (R44)
;;;;
;;;; Split out of `commands.lisp`, which was one 1784-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ----------------------- the operator's own todo items (R44) ----------------------- ;;;
;;;
;;; **The operator, on the shape they want:** *"I want to be able to edit todo list alongside you.
;;; it should be marked as created by me, and created by model as created by model. so /todos gains
;;; 'add todo item' and this gets me to a modal dialog - Title and descript and ok and cancel."*
;;;
;;; **What this can and cannot be, said here because it is a boundary and not an oversight.**
;;; The wire has no frame that writes a todo: `ClientFrame::ListTodos` is the only one and the
;;; protocol calls it what it is — *"read-only … a list is a question, not an act"* — while the
;;; model's list is written by its own `todo_write` tool and arrives as `TodosUpdated`. The
;;; operator-call door would be the way round that (`*op-call-draft*`), and the daemon's published
;;; door on this box does not include `todo_write` — measured against the live row rather than
;;; assumed, and NOT written out here: `the-door-is-the-daemons-list-and-not-a-copy-in-this-head`
;;; forbids this tree from naming a door tool anywhere, and it is right to — a copy in the head is
;;; the drift the row exists to stop.
;;;
;;; So the operator's items are **the head's own**, drawn in the same list and marked by author.
;;; Two honest consequences, both of which the screen and the docs say rather than hide:
;;;
;;;   · **the MODEL DOES see them, and that is R44's frame rather than this head's doing.**
;;;     `ClientFrame::SetOperatorTodos` carries this head's half to the daemon, whose board is ONE
;;;     list with two authors; so the nag reads them, the model is reminded of one when a turn ends
;;;     with it open, and — since `todo_write` grew its `operator` field — it can mark one DONE. It
;;;     still cannot remove one: a row is the operator's own words, and a model that misquoted must
;;;     not be able to take it off the board. This block used to say the opposite (*"the MODEL does
;;;     not see them … that is an ask to file"*), which is what it was before the ask was answered;
;;;   · **they are stored in sqlite**, on the operator's own ruling (*"use sqlite as always, not
;;;     files"*) — `src/store.lisp`'s `operator_todo` table, this head's own, separate from the
;;;     daemon's `todo` row that holds the union. A restart brings them back.

(defvar *operator-todos* nil
  "The todos the OPERATOR added: plists `(:id STRING :content TITLE :detail TEXT :status STRING)`.

Oldest first, which is the order they were written and the order the pane draws them in. A
`defvar` for the reason every other piece of live state here is — a struct layout change is a
restart — and reset by `with-replay-globals`, because a replay that inherited one would draw this
session's items on a screen recorded before they existed.

**EVERY ITEM CARRIES AN ID, and the operator is who said it had to.** *\"a todo item is
identified by a hash or something like a commit\"* — and the point is not the hash, it is that a
row's TEXT is not its identity. Every action this pane takes is *act on that row*: remove it, mark
it, and (once the wire carries them) tell the model about it. Keyed on the words, all of them are
wrong in the same way the moment two items say the same thing or one is edited — `(remove item …)`
takes the first `equal` neighbour, not the row under the cursor. A commit needs a hash for exactly
this reason and the class of defect is the same one.

`operator-todo-next-id` is a counter rather than a content hash: it is unique by construction,
stable for the item's whole life, and it says nothing about the words — which is the property a
keyed-by-text scheme lacks. The `t` prefix is the head's own namespace, so an id here can never be
mistaken for one the daemon issues for its rows.")

(defvar *operator-todo-seq* 0
  "The counter behind `operator-todo-next-id`. A defvar so a live push cannot rewind it.")

(defun %todo-id-number (item)
  "The number in ITEM's id (`t7` → 7), or 0 for anything this build cannot read.

**Read back rather than trusted**, because the ids are the PRIMARY KEY of the store: a counter that
does not know what is already there mints an id that exists, and `insert or replace` then OVERWRITES
a real row instead of adding one. MEASURED on the live head — with the store holding `t5` and `t6`, a
fresh `operator-todo-add` minted `t1`, which happens to have been free; the next restart would have
minted `t1` again over whatever `t1` had become."
  (let ((id (getf item :id)))
    (or (and (stringp id) (plusp (length id))
             (let ((n (ignore-errors (parse-integer id :start 1 :junk-allowed t))))
               (and n (plusp n) n)))
        0)))

(defun note-todo-ids (items)
  "Raise `*operator-todo-seq*` past every id in ITEMS. Answers the new counter.

**The one place the counter learns what already exists.** A restart starts the counter at 0 and the
store's ids are the primary key, so without this the first add after a restart collides — and
`insert or replace` would silently replace somebody's item rather than adding one. Called by
`load-operator-todos`, which is the only moment the head learns the list."
  (dolist (item items)
    (setf *operator-todo-seq* (max *operator-todo-seq* (%todo-id-number item))))
  *operator-todo-seq*)

(defun operator-todo-next-id ()
  "A fresh id for one of the operator's items. See `*operator-todos*` for why items have them."
  (format nil "t~d" (incf *operator-todo-seq*)))

(defun operator-todos-workspace (&optional (head *head*))
  "Which project the operator's rows belong to: **the DAEMON's workspace, or NIL.**

**One function, because three write paths have to agree about it** — the add, the remove and the
whole-list save. A second spelling would let one of them file a row under a different key from the
others, and the symptom is a row that appears once and then cannot be found: `insert or replace`
writes it under one project, the reload reads another, and the operator sees their item vanish.

The key is the daemon's own workspace for the reason `load-operator-todos` gives: it is the same
string `modes.tsv` keys a project root by, and it is the project whose board the model reads.

NIL — no session yet, or a daemon that has not said — is the orphan key, and storing it means the row
belongs to no project rather than to the wrong one. Reads do the same, so a head that attaches later
picks those rows up by `store-adopt-orphan-todos`."
  (and head (ignore-errors (%daemon-workspace head))))

(defun save-operator-todos ()
  "Write the operator's list down, if this head is allowed to write.

**Behind `*write-prefs*`, which is the suite's own switch** — its docstring records the measurement
the suite was editing the operator's own `head.toml`. A test that adds an item must not append to the
operator's real file, and it is one switch rather than a path check per call site for the reason that
docstring gives: the fifth site is the one that would forget.

**A save that fails says so and keeps the list in memory.** The alternative — dropping the item
because it could not be written — would lose the operator's words to a permissions error, which is
strictly worse than a list that survives only this session."
  (when *write-prefs*
    (unless (store-replace-todos *operator-todos* (operator-todos-workspace))
      ;; **SAID, WHICH THE DOCSTRING CLAIMED AND THE CODE DID NOT DO.** This branch was `(unless …
      ;; nil)` — it evaluated a comment. The failure went into `*store-unavailable*`, which nothing on
      ;; the screen reads, so a write that did not land looked exactly like one that did until the
      ;; next restart put the old list back. MEASURED, and it is the operator's report: their row
      ;; worked, the head restarted, and the row was gone while an older one reappeared.
      ;;
      ;; Once per save is enough — the pane is where they read it, and a repeating notice would push
      ;; everything else off the status line.
      (when *head*
        (say *head* (format nil "todo not saved: ~a"
                            (or *store-unavailable* "the store refused"))))))
  *operator-todos*)

(defun todo-template-path ()
  "Where the starter todos come from: the `todo_template` setting, as a path.

`t` means the default beside this head's own preferences; a STRING is the path the operator named; NIL
means the switch is off and nothing is read. One function because the setting has three shapes and two
callers (the seeding and the `/config` row) must not spell them differently."
  (let ((v (prefs-todo-template (or *prefs* (make-prefs)))))
    (cond ((null v) nil)
          ((eq v t)
           (let ((prefs (default-prefs-path)))
             (and prefs (merge-pathnames "todo-template.md"
                                         (uiop:pathname-directory-pathname prefs)))))
          ((stringp v) (pathname v))
          (t nil))))

(defun %seed-operator-todos (workspace)
  "Put the starter todos into WORKSPACE, once. Answers a note, or NIL when there is nothing to say.

**THE OPERATOR'S ASK:** *\"this default todo can be a way to help new sessions initialize, can we have a
new session todo template with a config switch?\"* — asked about orphan rows that were turning up in
every new session, which was a BUG (a blanket adoption, see `store-adopt-orphan-todos`) whose useful half
this is: a new project can start with a checklist.

**ONCE PER PROJECT, not per session and not per head**, and that is forced rather than chosen: the
operator's todos are per PROJECT, so a per-session seed would duplicate the list for every session in
the same project, and a per-head seed would add another copy on every restart. `store-todo-seeded-p` is
the record, and it is a table rather than an *is the list empty* test for the reason its own docstring
gives: deleting a starter todo must not bring it back.

**THE TEMPLATE IS A `TODO.md`**, parsed by the same reader the repo section uses — so a starter list is
written in the format the operator already writes by hand, boxes and indented bodies included, and there
is no second syntax to learn. A mark of `[x]` seeds a done row, which is how a template can carry
something already settled.

Refusals are NOTES rather than silences: a switch that is on and a template that is not there is
something to say, because from the operator's side *the feature did not work* and *I never turned it on*
look identical otherwise."
  (let ((v (prefs-todo-template (or *prefs* (make-prefs)))))
    (when (and v (plusp (length (or workspace ""))))
      (cond
        ;; already seeded: nothing, and no note — this is the common path on every later start
        ((store-todo-seeded-p workspace) nil)
        (t
         (let ((path (todo-template-path)))
           (cond
             ((null path)
              (format nil "todo_template is on but this head has no config directory to read it from"))
             ((not (probe-file path))
              (format nil "todo_template is on but ~a is not there" (namestring path)))
             (t
              (let* ((rows (ignore-errors (read-todo-md (uiop:read-file-string path))))
                     (items (remove-if-not (lambda (r) (and (getf r :item) (getf r :text))) rows)))
                (cond
                  ((null items)
                   (store-mark-todo-seeded workspace)
                   (format nil "~a has no items in it, so nothing was added"
                           (file-namestring path)))
                  (t
                   (loop for r in items
                         for item = (list :id (operator-todo-next-id)
                                          :content (getf r :text)
                                          :detail (format nil "~{~a~^~%~}" (getf r :body))
                                          :status (if (eq (getf r :mark) :done) "completed" "open"))
                         do (setf *operator-todos* (append *operator-todos* (list item)))
                            (when *write-prefs*
                              (store-save-todo item (length *operator-todos*) workspace)))
                   ;; **MARKED SEEDED EVEN IF A ROW FAILED TO WRITE**, because the alternative is
                   ;; worse in the direction that matters: an unmarked project re-seeds on the next
                   ;; start, and the operator gets the duplicates this feature exists to avoid. The
                   ;; failure is visible as a short list, and the store says so itself.
                   (store-mark-todo-seeded workspace)
                   (format nil "~d starter todo~:p from ~a"
                           (length items) (file-namestring path)))))))))))))
(defun load-operator-todos (&optional workspace)
  "The operator's list FOR WORKSPACE from the STORE onto `*operator-todos*`, answering a note or NIL.

**PER PROJECT, on the operator's ruling** — *\"todos must be perproject\"*. They found the leak
themselves: a row written in a leticl window (`push leticl to github`) turned up on the RANO daemon's
board, because one table with no key plus a push on every HELLO put this head's whole list in front of
every session's model. The workspace is the DAEMON's own — the same string `modes.tsv` keys a project
root by — so *which project is this* has one answer in this tree rather than two.

**WORKSPACE IS NIL AT STARTUP AND THAT IS THE SHAPE, not an oversight.** `run` calls this before the
socket exists, so the daemon has not yet said where it is seated. The list is loaded AGAIN on the HELLO
arm, which is also the moment a SWITCH lands — so attaching and switching both reload and push the
project they are in. A NIL workspace loads the rows that belong to no project, which is the closest
honest answer for a head that does not yet know which project it is in.

**SQLITE, on the operator's ruling:** *\"regarding local todo storage - use sqlite as always, not
files.\"* `src/store.lisp` owns the database; this is the one caller that reads it at startup.

**AND IT IMPORTS THE OLD FILE ONCE**, which is the part a migration has to get right or it loses the
operator's own words: the previous cut of this wrote `todos.sexp` beside the preferences, and a head
that simply started reading sqlite would look exactly like one they had never added anything to.
So an empty table plus an existing file means *import, then say so* — and the file is left where it
is rather than deleted, because deleting somebody's data on the strength of a successful import is a
claim this code is in no position to make.

A store that is not there answers NIL and says nothing: the list stays in memory for the session,
which is the same behaviour as before that store existed."
  (let ((items (store-load-todos workspace)))
    (cond
      ;; the table is empty FOR THIS PROJECT and the old file is not: the items are in the file
      ;;
      ;; **AND ONLY IF THAT HAS NOT HAPPENED BEFORE**, which is the correction. This branch used to fire
      ;; whenever the table was empty, so an EMPTIED project re-imported the file — MEASURED on the
      ;; operator's head: two rows they had told me to delete were emptied from the table, the head was
      ;; restarted, and both came back under a different workspace. The docstring has said *"ONCE"*
      ;; since the import was written; `store-legacy-import-pending-p` is what makes it true.
      ((and (null items)
            (store-legacy-import-pending-p)
            (operator-todos-path)
            (probe-file (operator-todos-path)))
       (multiple-value-bind (old readable) (read-operator-todos)
         (if (and readable old)
             (progn (setf *operator-todos* (copy-list old))
                    (note-todo-ids *operator-todos*)
                    (store-replace-todos old workspace)
                    ;; **THE VERSION IS SET EVEN IF THE WRITE FAILED**, for the reason the orphan
                    ;; adoption gives: an unmarked import re-fires, and a re-import is how a row the
                    ;; operator deleted comes back. A short list is visible; a resurrected row is not.
                    (store-mark-legacy-imported)
                    (format nil "moved ~d todo~:p into the head's database from ~a"
                            (length old) (file-namestring (operator-todos-path))))
             (progn (setf *operator-todos* (copy-list (or items nil)))
                    (when (and readable (null old)) nil)))))
      (t (setf *operator-todos* (copy-list (or items nil)))
         ;; **and the id counter learns what is already there**, so the next add cannot mint an id
         ;; the store already holds — see `note-todo-ids` for the measurement.
         ;;
         ;; **AND IT LEARNS IT OVER THE WHOLE TABLE, not just this project.** Ids are the store's
         ;; PRIMARY KEY across every workspace (`t7` is unique in the FILE), so a counter raised past
         ;; this project's ids alone can still mint one another project holds — and `insert or
         ;; replace` would OVERWRITE somebody else's row rather than adding one. That is the same
         ;; defect `note-todo-ids`' docstring measures, one project over.
         (note-todo-ids *operator-todos*)
         (let ((ceiling (store-todo-id-ceiling)))
           (when (> ceiling *operator-todo-seq*)
             (setf *operator-todo-seq* ceiling)))
         ;; **and the store's own one-off sentence is passed on** — the orphan adoption is the one
         ;; step that claims to know a row's project without being told, so it is said rather than
         ;; silent. Read and cleared here, because it is news once.
         (let ((note *store-note*))
           (setf *store-note* nil)
           ;; **AND THE STARTER TODOS, in this same place and for the same reason**: this is the one
           ;; function where a head learns its list, so it is the one place a list can be STARTED.
           ;; `%seed-operator-todos` refuses on its own when the project has been seeded before, when
           ;; the switch is off, and when the workspace is not yet known — that last one matters,
           ;; because a head loads before the socket exists and a project it cannot name is not a
           ;; project it may put rows into.
           (let ((seeded (%seed-operator-todos workspace)))
             (cond (seeded (if note (format nil "~a; ~a" note seeded) seeded))
                   (t note))))))))

(defvar *todo-file-unreadable* nil
  "Set when the todo file existed and could not be read, so a save must not overwrite it.")

(defun push-operator-todos (head)
  "Send this head's operator rows to the daemon's board — the ONE sender.

**One writer, because the two halves of the board must not drift**: the daemon replaces its operator
half with exactly what it is handed, so a caller that sent a stale list would delete rows the pane is
still drawing. Every mutation that changes `*operator-todos*` comes through here, and there are
three: add, remove, and the load at startup.

**HEAD defaults to `*head*`**, which is what a caller inside a card or a test wants: the live head
is the only head there is, and threading it through every caller would be a parameter nobody
passes anything else for. A NIL head — or one with no session yet — answers NIL rather than
sending, which is the honest answer for a test or a replay."
  (when (and head (session-session-id (head-session head)))
    ;; **THE ITEMS GO AS THEY ARE** — `make-set-operator-todos` owns the mapping into the wire's
    ;; shape, and mapping them here as well is how a hardcoded status hid for a whole session.
    (%send head (make-set-operator-todos
                 (session-expected-seq (head-session head))
                 *operator-todos*))))

(defun fold-board-statuses (todos)
  "The BOARD's status for each of this head's own rows, taken by content — the model's returns.

**The board is one list with two authors, and the two halves are owned differently. This is the
head's half of that split, and it is one rule:**

  · **membership and order are THIS HEAD's.** It adds, deletes and reorders its own rows, pushes the
    whole list, and the daemon's half is what it sent. So nothing here adds or removes a row, and a
    row on the wire that this head does not have is left alone rather than adopted;
  · **status is the DAEMON's.** The model can move the state of one of these rows now — it names the
    row by quoting its words (`todo_write`'s `operator` field, see `TodoBoard::set_operator_states`) —
    and the daemon announces the union with the new status.

**Without this fold the model's move is lost, and it is lost LOUDLY**: the pane keeps drawing the row
as pending, the nag keeps naming it, and this head's next `push-operator-todos` — any add, any delete
— pushes the stale status back over the daemon's, undoing the model's answer. So the fold is not
bookkeeping; it is the half of the feature that makes the move stick.

**By content, because that is the only name a row has.** The wire's `TodoEntry` is `content`, `status`
and `by` — there is no id (the operator ruled out a protocol bump for one), and this head's own ids
(`t6`, `t7`) are local to it and were never sent. So a row is found by the words it carries, and the
match is restricted to rows the daemon marks `operator`: a model row that happened to read the same
would otherwise take a status meant for the operator's.

PERSISTED when something moved, so a restart does not put the row back to pending. In a replay there
is nothing to fold and `*write-prefs*` is off, which is why the two guards at the top are the whole
of the replay story."
  (when (and todos *operator-todos*)
    (let ((changed nil))
      (dolist (item *operator-todos*)
        (let ((wire (find (getf item :content) todos
                          :key (lambda (r) (getf r :content))
                          :test #'string=)))
          (when (and wire
                     (string= (or (getf wire :by) "") "operator"))
            ;; **THE STATUS, as ever** — the daemon's board owns the state once a row
            ;; reaches it.
            (when (and (getf wire :status)
                       (not (equal (getf item :status) (getf wire :status))))
              (setf (getf item :status) (getf wire :status)
                    changed t))
            ;; **AND THE CONDITION, WHICH THE DAEMON SPENDS.** A row whose job ended is
            ;; fired — reported to the model, and its `when` CLEARED so it cannot fire
            ;; twice — while the status stays open: a fired row is ordinary open work.
            ;; Without this half the fold, the board says *no condition* and this head
            ;; still holds the handle, so the NEXT push (any add, any delete) re-arms a
            ;; row the daemon already fired — the same two-writers defect the status
            ;; fold exists to prevent, one field along. The clear is folded exactly like
            ;; a change: unequal is what moves.
            (unless (equal (getf item :when) (getf wire :when))
              (setf (getf item :when) (getf wire :when)
                    changed t)))))
      (when changed (save-operator-todos))
      changed)))

(defun operator-todo-add (title &optional detail (head *head*))
  "Add the operator's item. The new item when it was added, NIL when TITLE was blank.

**A blank title is refused rather than stored**, and it is refused HERE rather than at the card:
an item with no words is a row that says nothing, and the one place that can decide what *nothing*
is, is the place that owns the list. It returns the ITEM rather than T so a caller can name it —
and so the identity is minted in the one place that owns the list, not by whoever asked."
  (let ((title (string-trim " " (or title ""))))
    (when (plusp (length title))
      (let ((item (list :id (operator-todo-next-id)
                        :content title
                        :detail (string-trim " " (or detail ""))
                        :status "open")))
        (setf *operator-todos* (append *operator-todos* (list item)))
        ;; **AND WRITE IT DOWN — the ONE row, not the whole list.** Without persisting at all the
        ;; item lived in a `defvar` and died with the process, which is the operator's report
        ;; (*"todo items i add do not survive the head restart"*). With the whole list written on
        ;; every add it would be a transaction per keystroke and a window in which nothing is on
        ;; disk; the store's own docstring says adds save one row and removals delete one, so the
        ;; command path has to be what makes that true. SEQ is the item's index, which is the order
        ;; the pane draws.
        (when *write-prefs*
          (store-save-todo item (length *operator-todos*) (operator-todos-workspace)))
        ;; **AND TELL THE DAEMON, so the reminder can see it.** The board on the daemon holds one
        ;; list with two authors, and this head is the source of truth for its own half; the idle nag
        ;; asks that board for unfinished work, so until these rows reach it a reminder could only
        ;; ever be about something the MODEL wrote. `push-operator-todos` is the one sender.
        (push-operator-todos head)
        item))))
(defun todo-postpone-command (head rest)
  "`/todo postpone N`, `/todo resume N`, and `/todo when N JOB` — the three typed verbs over
the OPERATOR's rows, by the numbers the pane prints on them. T when the line was taken.

The operator's ask (the reference's own, commands.rs): *\"can we handle postponed todo item
properly? i.e. they persist but without nag and with some counter visible to me\"*. The state is
THEIRS and this is the door: on the daemon's side the ruling is that a model that could set its
own row aside would have a way to silence the check that exists to stop it abandoning a plan —
`todo_write` still takes three words, and the two that are missing are typed ones. On this head
the boundary is already the shape of the code: `*operator-todos*` is the operator's half and no
key or card of the model's reaches it, so the verb is the operator's by construction.

**The verb pair and not a key on the row.** Enter on one of these rows already means *toggle
done* — the pane's own act since R44 — and a second row key would be a second thing to learn for
an act that has a typed door; the two are in the verb table (which is what `/help` and tab read)
and named in the pane's own hint lines.

**`resume` and not a second spelling of `done`**, because the two answers are different
questions: `done` is *this is finished*, `resume` is *ask me about this again*. Lifting a row
puts it back as open work — which is what the queue and the idle check read. **The condition
is carried across both verbs by construction**: neither touches `:when`, and a row set aside
while waiting on a job goes back to waiting on the same one — the daemon's own ruling, and the
pane says so on the row (`· waits on HANDLE`).

Numbered over the operator's half exactly as the pane numbers it (`mine-at`, 1-based), and
refused by name when the number is not one of theirs — so a typo cannot set aside a row nobody
named. A bare `/todo postpone` with no number is a USAGE note rather than the daemon's
*new row's text* reading, because on this head the add door is the card (`/todos add`) and a
line that silently created a row titled `postpone` would be a row nobody meant to add."
  (let* ((words (uiop:split-string (string-trim " " (or rest "")) :separator " "))
         (verb (first words))
         (n (second words)))
    (cond
      ((not (member verb '("postpone" "resume" "when") :test #'string=))
       (say head "usage: /todo postpone N · /todo resume N · /todo when N JOB — the pane numbers your rows")
       t)
      ((null n)
       (say head (format nil "which row? /todo ~a N~@[ ~a~] — the todos pane numbers your rows"
                         verb (and (string= verb "when") "JOB")))
       t)
      ;; **`when N JOB` — the condition, attached by number** (`when N -` takes it off).
      ;; The operator's own shape: *"if you are telling me 'job ends and i do this and
      ;; that' then 'this and that' is a todo item, which is conditioned by job status
      ;; (end)"*, and *"when I file a todo"* is where it belongs — the row is filed first
      ;; and the condition is put on it here. **`-` clears it, and that is not a
      ;; courtesy**: a condition nobody can take off is a row waiting for ever on a job
      ;; that already ended, and the daemon's evaluator would go on reporting it as due.
      ((string= verb "when")
       (let ((job (third words)))
         (cond
           ((null job)
            (say head "`/todo when N JOB` — a row number and the handle it waits on. `/todo when N -` takes the condition off.")
            t)
           (t
            (let ((at (ignore-errors (parse-integer n :junk-allowed t))))
              (cond
                ((null at)
                 (say head (format nil "`~a` is not a row number — the todos pane numbers your rows" n))
                 t)
                ((or (< at 1) (> at (length *operator-todos*)))
                 (say head (format nil "there is no row ~d of yours — you have ~d"
                                   at (length *operator-todos*)))
                 t)
                (t
                 (let* ((item (nth (1- at) *operator-todos*))
                        (clear (string= job "-"))
                        (now (and (not clear) (list :kind "job" :handle job))))
                   ;; **SET THROUGH THE PLACE, NOT THE LOCAL.** A row that has never
                   ;; carried a condition has no `:when` key, and `(setf (getf item …))`
                   ;; on an ABSENT key rebinds the local to a fresh cons — the store's
                   ;; list still points at the old one and the condition silently goes
                   ;; nowhere. Every other verb here sets keys that already exist
                   ;; (`:status`), where setf getf updates in place; this is the one
                   ;; arm that can ADD a key, so it writes through `(nth …)`'s own
                   ;; setf, which stores the new list head back into the slot.
                   (setf (getf (nth (1- at) *operator-todos*) :when) now)
                   ;; and the local follows, for the store save below
                   (setf item (nth (1- at) *operator-todos*))
                   ;; ONE ROW, the same store discipline as every other mutation here
                   (when *write-prefs*
                     (store-save-todo item at (operator-todos-workspace head)))
                   ;; **AND THE BOARD, which is where the evaluator reads it**: the
                   ;; daemon fires the row when the job ends, spends the condition,
                   ;; and tells the model — none of which a head-only handle can do.
                   (push-operator-todos head)
                   (setf (head-dirty head) t)
                   (say head (if clear
                                 (format nil "row ~d no longer waits on anything" at)
                                 (format nil "row ~d is due once `~a` is not running — a job this ~
                                              daemon has never heard of counts as ended, which is ~
                                              what a restart looks like."
                                         at job)))
                   t))))))))
      (t
       (let ((at (ignore-errors (parse-integer n :junk-allowed t))))
         (cond
           ((null at)
            (say head (format nil "`~a` is not a row number — the todos pane numbers your rows" n))
            t)
           ((or (< at 1) (> at (length *operator-todos*)))
            (say head (format nil "there is no row ~d of yours — you have ~d"
                              at (length *operator-todos*)))
            t)
           (t
            (let* ((item (nth (1- at) *operator-todos*))
                   (now (if (string= verb "postpone") "postponed" "open")))
              (setf (getf item :status) now)
              ;; **ONE ROW, not the whole list** — the same store discipline as the add and the
              ;; toggle: a transaction per keystroke is what the store's own docstring refuses.
              (when *write-prefs*
                (store-save-todo item at (operator-todos-workspace head)))
              ;; **AND THE DAEMON'S BOARD, which is the whole point of the state**: the idle check
              ;; reads that board, so a row set aside only in this head would keep being asked
              ;; about — the exact nag the operator asked to stop. `make-set-operator-todos`
              ;; carries `postponed` through to the wire, and the next board snapshot folds it
              ;; back unchanged.
              (push-operator-todos head)
              (setf (head-dirty head) t)
              (say head (if (string= verb "postpone")
                            (format nil "row ~d is set aside — it stays on your list and the model ~
                                         still sees it, and nothing is reminded of it until you ~
                                         lift it with /todo resume ~d" at at)
                            (format nil "row ~d is back in the list — the check may ask about it again" at)))
              t))))))))

(defvar *todo-draft* nil
  "The new-todo card: `(:title TEXT :detail TEXT :field :title)`, or NIL when it is closed.

**Two fields and one composer**, which is this head's arrangement rather than a second text widget:
the field being typed is the one in the composer below the card, and `tab` moves it. The modal the
operator asked for — *\"a modal dialog - Title and descript and ok and cancel\"* — is the card, the
two fields, and three keys.")

(defun todo-draft-open-p () (and *todo-draft* t))

(defun %todo-draft-field () (getf *todo-draft* :field))

(defun %todo-draft-store (head)
  "The composer's text into the field being typed. The ONE writer of the draft's two fields."
  (setf (getf *todo-draft* (%todo-draft-field)) (composer-buffer (head-composer head)))
  head)

(defun %todo-draft-focus (head field)
  "Put FIELD's text in the composer and make it the field being typed."
  (%todo-draft-store head)
  (setf (getf *todo-draft* :field) field
        (composer-buffer (head-composer head)) (or (getf *todo-draft* field) "")
        (composer-cursor (head-composer head)) (length (composer-buffer (head-composer head)))
        (head-dirty head) t))

(defun %todo-draft-open (head)
  "Open the new-todo card — the `add todo item` row on `/todos`.

**A picker is closed and the composer is the draft's now**, for the reasons
`%op-call-draft-open` gives: one field has one owner, and a half-typed prompt left under a card
whose Enter adds an item is the shape that costs somebody a message."
  (setf *todo-draft* (list :title "" :detail "" :field :title)
        *pick-open* nil
        (composer-buffer (head-composer head)) ""
        (composer-cursor (head-composer head)) 0
        (head-dirty head) t)
  (say head "adding a todo item — title, then tab for the description; enter adds it to the session's plan as yours, esc cancels")
  t)

(defun %todo-draft-close (head)
  "Take the card and its field down. The ONE place the card's state is cleared."
  (setf *todo-draft* nil
        (composer-buffer (head-composer head)) ""
        (composer-cursor (head-composer head)) 0
        (head-dirty head) t))

(defun %todo-draft-cancel (head)
  "Esc (or ctrl-c): nothing was added."
  (%todo-draft-close head)
  (say head "nothing added")
  t)

(defun %todo-draft-submit (head)
  "Enter: add the item, or say why not.

**A title is required and the card stays up without one**, which is the only field rule: the
description is optional and the title is the item. Saying so beats storing a row of nothing."
  (%todo-draft-store head)
  (let ((title (getf *todo-draft* :title)))
    (if (operator-todo-add title (getf *todo-draft* :detail))
        (progn
          (%todo-draft-close head)
          (say head (format nil "added `~a` to the plan — it is yours, and the model will be reminded of it"
                            (string-trim " " title)))
          t)
        (progn
          (say head "a todo item needs a title — type one, or esc to cancel")
          t))))

(defun %todo-draft-key (head key type)
  "The keys the new-todo card owns: enter adds, tab moves the field, esc and `ctrl-c` cancel.

**Everything else is the composer's**, so the title and the description are typed, edited, pasted
and undone with the keys the operator already has — the same split `%op-call-draft-key` keeps. T
only for a key it took, or the field would stop taking letters."
  (case type
    (:enter (%todo-draft-submit head))
    (:tab (%todo-draft-focus head (if (eq (%todo-draft-field) :title) :detail :title)))
    (:esc (%todo-draft-cancel head))
    (:ctrl (and (eql (getf key :ch) #\c) (%todo-draft-cancel head)))
    (t nil)))

(defun %json-text-p (text)
  "Is TEXT the arguments as JSON? — by PARSING it, and by nothing else.

**The question is *is this already the wire's shape*, and the parser is the only thing that
answers it.** The JSON form's promise is that what goes on the wire IS json text, and a
brace test cannot keep that promise: `NAME {…` with its closing brace missing
starts with a brace and is not json, and a head that passed it through would have sent the
daemon an unchecked line while believing it had checked.

**What a brace test would NOT buy, said plainly because this is where the rule is a choice.**
The tempting justification for testing the character is *a person searching for a JSON snippet
types braces and a colon* — but such a search is a COMPLETE snippet, it parses, and this rule
already takes it as the arguments: neither rule can tell that search from a call. So the two
rules differ on exactly one kind of line, the unparseable one, and there this head's answer is
the bare one — the line is searched for, verbatim, into the field the daemon named, and the
row shows what was searched. That is a cost with a name rather than a hidden one."
  (and (stringp text) (plusp (length (string-trim " " text)))
       (handler-case (progn (json-decode text) t) (error () nil))))

(defun %door-name (head token)
  "The DAEMON's own name for the door tool a person typed as TOKEN, or NIL.

**The transform is textual and holds no knowledge of any tool** (R34): the door's tool names are
the daemon's, spelled with underscores because they come straight from the tool's own name, and
**a slash verb is typed with hyphens** — `/some-tool`, not `/some_tool` — because every other
verb in this head's vocabulary is one word and none of them needs the shift key. So a typed
`-` is matched against a published `_` and nothing else is touched: `read` is `read`, and a tool
whose name has neither is unaffected.

**Both spellings are ACCEPTED and the WIRE name is the daemon's.** *an operator who types what
the daemon calls it should not be told they are wrong* — so `/some_tool` works exactly as
`/some-tool` does, and the name this head SENDS is always the published one. A head that sent
the hyphen would be asking the daemon for a tool it does not have."
  (let ((door (head-run-tools (head-settings head))))
    (find-if (lambda (n)
               (string-equal (substitute #\- #\_ n)
                             (substitute #\- #\_ token)))
             door)))

(defun %door-arguments (head name line)
  "NAME and a person's LINE as the wire's arguments JSON, or `(values NIL WHY)`.

The ONE place both spellings meet, so the bare verb and `/run` cannot disagree about what a
line means:

  · **a line that parses as JSON IS the arguments**, verbatim — the form that shipped first,
    kept because a tool with several fields still needs it and because the head must not
    reinterpret something already in the wire's shape;
  · **anything else is the BARE form** (`%bare-arguments`), where the field comes from the
    daemon's row and this head holds no schema."
  (if (%json-text-p line)
      (values (string-trim " " line) nil)
      (%bare-arguments head name line)))

(defun %arguments-object (field line defaults)
  "The arguments object as JSON TEXT: FIELD set to LINE, then the daemon's DEFAULTS.

**Built by hand rather than with the encoder, and that is a correctness point and not a
style.** A default arrives from the daemon as JSON *text* — `10` for a number, `high` unquoted
for a string — so it is spliced in raw. The encoder would quote it, sending `{\"limit\":\"10\"}`
where a model's own call carries `{\"limit\":10}`, and the same tool would then answer two
different questions depending on who asked.

The LINE itself IS encoded, because it is a person's typing: a search containing a quote or a
backslash has to survive the trip to the daemon as the characters they typed."
  (with-output-to-string (s)
    (write-string "{" s)
    (format s "~a:~a" (json-encode-to-string field) (json-encode-to-string line))
    (loop for (k v) on defaults by #'cddr
          ;; **`(k v)`, not `(k . v)`, and the difference was a real bug**: the dotted form binds
          ;; `v` to the CDR, so a default of `(:limit 10)` spliced `(10)` into the arguments —
          ;; which is not JSON, and the daemon's parser said so one call later.
          do (format s ",~a:~a" (json-encode-to-string (%key-to-wire k)) v))
    (write-string "}" s)))

(defun %bare-arguments (head name line)
  "NAME + a person's LINE as the wire's arguments JSON, or `(values NIL WHY)`.

**The whole requirement, in one function: `/NAME blabla` and the head holds no schema.** The
field comes from the daemon's own row, looked up by name — so this knows nothing about the
tool, and a daemon that renames the field changes nothing here. `why` is the sentence the
caller shows when the bare form cannot be built, and it NAMES the reason rather than leaving
the operator to guess which tools take a sentence and which take JSON:

  · **no descriptors at all** — an older daemon: the head does not know, so it says it does not
    know, and quotes the name rather than a field;
  · **a name the row does not describe** — said as that, because *the daemon describes other
    tools and not this one* is a different fact from *the daemon said nothing*;
  · **a tool the daemon itself says has no bare form** — `:why-json` is the daemon's own
    sentence and THIS HEAD READS IT rather than inventing one, which is the same rule as the
    field name: the knowledge is the daemon's;
  · **a required field with nothing typed for it** — names the field, so the next keystroke is
    obvious."
  (let* ((descs (head-run-descriptors (head-settings head)))
         (d (cdr (assoc name descs :test #'string=)))
         (field (getf d :field))
         (why-json (getf d :why-json)))
    (cond
      ((null descs)
       (values nil
               (format nil "this daemon has not said which field a bare line fills for `~a`, so type the arguments as JSON — `~a {\"…\": \"…\"}`"
                       name name)))
      ((null d)
       (values nil
               (format nil "this daemon has not described `~a` — it named it in the door and said nothing about its arguments, so type them as JSON: `~a {\"…\": \"…\"}`"
                       name name)))
      ;; **the daemon's own sentence**, which is why `why_json` is on the row at all
      ((plusp (length why-json))
       (values nil (format nil "this daemon says `~a` takes no single argument — ~a; type it as JSON: `~a {\"…\": \"…\"}`"
                           name why-json name)))
      ((zerop (length field))
       (values nil
               (format nil "the daemon says `~a` takes no single argument — type it as JSON: `~a {\"…\": \"…\"}`"
                       name name)))
      ((zerop (length (string-trim " " line)))
       (values nil
               (format nil "`~a` needs its ~a — as `~a SOMETHING`" name field name)))
      (t (%arguments-object field line (getf d :defaults))))))

(defun %op-call-verb (head verb rest)
  "The operator's own shape — `/NAME blabla` — or NIL to let the verb fall through.

**A DOOR NAME IS ITS OWN VERB, and only the names the daemon published.** The lookup is
against `head-run.tools`, so a door offering one name gets that one verb: this head invents no
alias, no abbreviation and no friendly spelling, because the name IS the daemon's
(`head-run.tools`' own reason, applied to the verb).

**Two spellings of ONE name, and they are not two verbs** (R34): the typed form is hyphenated
and the wire form is the daemon's, so both are accepted and `%door-name` resolves each to the
single published name. That is a difference of SPELLING and not a vocabulary — the head still
answers only to names the daemon published, and to all of them.

**A name that is NOT in the door falls through untouched** — it travels to the daemon as the
slash line the operator typed, which is what every other verb does and what keeps a daemon-side
verb of the same name working.

**The gating is identical to every other door path**, and that is a constraint rather than an
observation: this calls `%op-call-ask`, so the bare form gets the same allowlist, the same two
frames and the same admission recorded as the operator's act. Sugar that skipped the door
would be a second door."
  (let ((name (%door-name head verb)))
    (when name
      (multiple-value-bind (args why) (%door-arguments head name rest)
        (if args
            (progn (%op-call-draft-close head)
                   (%op-call-ask head name args))
            (say head why)))
      t)))

(defun %run-command (head rest)
  "`/run` — run a tool the DAEMON names, on this machine, as the operator's own act.

**Two doors and one path.** `/run NAME what you want` is the operator's short form (R31):
the daemon's row says which field a bare line goes into, so this head turns the sentence into
the wire's JSON while knowing nothing about the tool. `/run NAME {…json…}` is the form that
shipped first and STAYS, because a tool with several fields still needs it.

**`/run` with nothing after it LISTS the door**, and that is a default changed on the
operator's review (*you guys do interfaces for yourself*): the old arm opened a JSON
composer, which is the shape an agent finds natural and a person has to learn. A person who
types `/run` wants to know what they can run, so they get a sentence naming the names and the
field each bare line fills. `alt+r` still opens the composer, which is the escape hatch for a
tool with several fields.

**Why the chord is not a control byte**, in one measurement: every control byte
a mnemonic can hang on is taken here. The composer owns `a b e f k u w y z` and `Rubout`,
the head owns `r t x l o s n p g q`, and the remaining letters do not arrive as control
bytes at all — `h` is Backspace, `i` is Tab, `j`/`m` are Enter, and `v` is the terminal's
literal-next in several emulators. R22 took `ctrl-n` on the same arithmetic (*the last free
byte with a mnemonic*), so what is left is an ESC-prefixed chord: `alt+r` is decoded by
this head's own reader, is not a prefix in tmux, and is bound to nothing else.

The arguments are the tool's own JSON — the shape a model's call carries — because a head
that knew one tool takes `{\"url\": …}` would be holding a copy of that tool's schema,
which is the same drift the settings row exists to stop one level up. They are validated as
JSON and nothing else: the wire says the field IS json text, and a head that passed
`https://example.com` through as the arguments would put a non-JSON string into the corpus
and hand it to the model as the call."
  (let* ((space (position #\space rest))
         (name (if space (subseq rest 0 space) rest))
         (args (if space (string-trim '(#\space #\tab) (subseq rest (1+ space))) "")))
    (cond
      ;; NO NAME: **LIST what the door accepts and how to type it** — not the composer.
      ;; The composer is an agent's shape and it was the wrong default: the common case is
      ;; `/NAME blabla`, and a person who types `/run` to find out what is available
      ;; should be told the short form rather than dropped into a JSON field. `alt+r` still
      ;; opens the composer, which is the escape hatch for a tool with several fields.
      ((zerop (length name))
       (let* ((door (head-run-tools (head-settings head)))
              (descs (head-run-descriptors (head-settings head))))
         (say head
              (if (null door)
                  "this daemon offers no operator-call door — it has published no tool list, so there is nothing to run"
                  (with-output-to-string (s)
                    ;; **hyphenated on the glass** (R34): the names here are what a person
                    ;; types, and the daemon's own spelling is what goes on the wire.
                    (format s "the daemon will run ~{~a~^, ~} for you — type `/NAME what you want`, as the tool's own name and then a sentence"
                            (mapcar #'%verb-spelling door))
                    (let ((described (remove-if-not (lambda (d) (plusp (length (getf (cdr d) :field))))
                                                    descs)))
                      (when described
                        (format s "; the bare form goes into ~{~{~a → ~a~}~^, ~}"
                                (loop for d in described
                                      collect (list (%verb-spelling (car d))
                                                    (getf (cdr d) :field)))))
                      (let ((json (remove-if (lambda (n) (assoc n described :test #'string=)) door)))
                        (when json
                          (format s "; ~{~a~^, ~} still take JSON" json))))
                    (format s " — and nothing runs until it says the call was admitted; alt+r types the JSON by hand"))))))
      ;; A NAME with a line: JSON if it IS json, the bare form otherwise — one decision,
      ;; made in `%door-arguments`, so `/run` and the bare verb cannot disagree.
      ;;
      ;; **And `/run some-tool …` is the same spelling question as the bare verb** (R34):
      ;; `%door-name` resolves either spelling to the daemon's own, so both doors accept both
      ;; and the wire always carries the published name. A name the door does not publish is
      ;; passed through untouched, which is what `/run` has always done with an unknown name —
      ;; the daemon refuses it, in the daemon's words.
      (t
       (%op-call-draft-close head)
       (let ((wire-name (or (%door-name head name) name)))
         (multiple-value-bind (built why) (%door-arguments head wire-name args)
           (if built
               (%op-call-ask head wire-name built)
               (say head why))))))))

(defvar *diag* nil
  "The diagnostic read in flight or on the screen: a plist
`:request-id ID :kinds (KIND…) :answers ((KIND :decided B :body S :total N)…)`.

**One at a time, deliberately.** The answer is keyed by the ADJUDICATION's id, so two
reads open at once would put two ids' answers in one pane and neither labelled; asking for
a second id REPLACES this, which is also what the pane does.

**`*diag*` is not cleared when the pane closes.** The answers are already here, and an
operator who left the listing with Esc and comes back with `/diagnostic` — with the same id
still the newest — should not be sent to the daemon again for two bodies this head is
holding. Bound by `with-replay-globals`, because a replay that folds a `diagnostic` frame
must not inherit another replay's read.")

(defun %diagnostic-ask (head request-id)
  "Open the pane and ask for BOTH halves, one frame each. T when the ask went out.

**Opened at the keypress, before any answer** — the job overlay's own rule: a pane that
appears only when the second frame lands is a pane the operator has been staring at an
empty screen for, and `reading…` is a fact rather than a blank.

**Both kinds, from `+diagnostic-kinds+`**, so a third kind is a name in that list and not a
second call site to remember."
  (let ((answers (loop for kind in +diagnostic-kinds+
                       collect (list kind :decided nil :body nil :total nil))))
    (setf *diag* (list :request-id request-id :kinds (copy-list +diagnostic-kinds+)
                       :answers answers))
    (open-diagnostic-listing *diag* head)
    ;; **THE VERB TAKES THE SCREEN**, which is the head's rule for a reply the operator
    ;; asked for (`note-slash-reply`'s own comment: a reply the operator asked for takes the
    ;; screen rather than scrolling past). Opening the listing without the mode would leave
    ;; the pane in `*slash-out*` and the conversation on the glass.
    (setf (head-mode head) :slash)
    (reset-pane-scroll)
    (setf (head-dirty head) t)
    (dolist (kind +diagnostic-kinds+)
      (%send head (make-fetch-diagnostic request-id kind)))
    (say head (format nil "reading the oracle's brief and reply for ~a — what the gate was shown, and what it answered"
                      request-id))
    t))

(defun %diagnostic-target (head)
  "The adjudication this head would read the oracle's exchange for, or NIL.

**The newest settled decision first, then an open ask.** Both `req-id`s are the
adjudication's own — the same id `/gate` takes — and the order is what an operator means by
*that one*: the ask in front of them if there is one, otherwise the last thing decided. A
head that picked the oldest, or the first, would read the wrong row on a session with more
than one decision in it."
  (let* ((s (head-session head))
         (open (session-open-decisions s))
         (settled (session-settled-decisions s))
         (last (and settled (getf (car (last settled)) :req-id))))
    (or (and open (getf (car open) :req-id))
        last)))

(defun %diagnostic-command (head rest)
  "`/diagnostic [ID]` — the oracle's brief and its reply, as the gate saw and heard them.

**A verb, because it is a READ of one named row.** `/gate` already takes a request id and
lists what the gate decided; this is the other half of that row, and it is asked for by the
same id so the two cannot disagree about which adjudication is being talked about.

With no id the head reads the newest one it can name — the open ask if there is one,
otherwise the last settled decision — and says which it chose, because a pane about
the wrong adjudication looks exactly like a pane about the right one."
  (let ((rest (string-trim " " rest)))
    (cond
      ((plusp (length rest)) (%diagnostic-ask head rest))
      (t
       (let ((id (%diagnostic-target head)))
         (if id
             (progn (%diagnostic-ask head id)
                    (say head (format nil "reading ~a — the newest adjudication this head can name (~a)"
                                      id (if (session-open-decisions (head-session head))
                                             "the ask in front of you"
                                             "the last one settled"))))
             (say head "nothing to read: `/diagnostic ID` names an adjudication, and this head has met none yet — `/gate recent` lists them")))))))

(defun %refresh-notes-listing (head)
  "Redraw the notes listing, if the listing on the screen is the NOTES one.

A daemon slash reply that happens to be up is not this head's to replace, and a
listing that has just gone stale — the reader retired one and the `[retired]` marks
moved — is exactly the pane that must not be left showing the old answer."
  (when (notes-listing-open-p)
    (open-notes-listing (head-session head))
    (setf (head-dirty head) t)))

(defun %toggle-pane (head mode &optional ask)
  "Open MODE, or CLOSE it when it is already the screen — and call ASK first when
it opens.

Every one of these is a toggle in the reference (app.rs:3071-3137, 4503-4566) and
reads as one. Here they only ever opened: `/help` twice left the help screen up,
and `ctrl-s ctrl-s` left the picker up, so Esc was a second thing to remember per
pane. ASK is the frame the pane needs filling — it is not sent on the close,
because a pane going away has nothing to ask for."
  (if (eq (head-mode head) mode)
      (setf (head-mode head) :normal (head-dirty head) t)
      (progn (when ask (funcall ask))
             (%open-pane head mode))))

(defun %open-pane (head mode)
  "Open the full-body screen MODE with its cursor at the top and nothing scrolled.

The panes share ONE cursor (`head-picker-sel`) and one scroll offset, because only
one is open at a time — so a position left by the last pane means nothing to the
next, and opening on it put the todos cursor three items down because the picker
had been there. The reference keeps a cursor per pane; with one, the top is the
only honest place to start."
  ;; one list on the screen at a time, the rule the pickers keep between themselves
  (setf *pick-open* nil)
  ;; **OPENING `/status` IS THE ACKNOWLEDGEMENT.** The alarm is a pointer — *something was
  ;; wrong, look here* — and its job is finished the moment the reader has looked. No key and no
  ;; verb: the act of opening the screen IS the act of seeing the numbers. See `*alarms-acked*`
  ;; for why this is safe rather than a way to switch the alarm off (a counter that grows past
  ;; the value that was seen points again), and why the filter lives in `alarm-counts` rather than
  ;; at the two surfaces it quiets.
  ;;
  ;; Taken BEFORE the mode is set, so the screen the reader is about to see is drawn from the
  ;; same numbers that were acknowledged — a resync arriving between the two would otherwise be
  ;; acknowledged without ever having been on the screen.
  (when (eq mode :status) (acknowledge-alarms head))
  (setf (head-mode head) mode
        ;; the session picker opens ON THE SESSION YOU ARE IN — `ctrl-s` then
        ;; enter moved you off your own session, which is the shape of mistake
        ;; that costs a turn. Every other pane opens at the top, which is the
        ;; honest place when one cursor is shared.
        (head-picker-sel head) (pane-initial-sel head mode)
        (head-dirty head) t)
  (reset-pane-scroll))

(defun %send-slash (head line)
  "LINE as a `slash` frame — the line the operator would have typed, minus the
slash, which is how a daemon-side verb travels (`Action::Slash`). One place, so the
request id and the expected seq are filled the same way by every caller."
  (%send head (list :frame "slash"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :line line)))

(defun %interrupt (head reason)
  (%send head (make-interrupt (session-expected-seq (head-session head)) reason)))

(defun %cells (head message)
  "The operator pointing: the message, and this screen exactly as drawn —
ANSI included, delimited so both readers find the edges (app.rs:2977)."
  (if (or (zerop (head-last-cols head)) (zerop (head-last-rows-n head)))
      (say head "nothing has been drawn on this head yet — no cells to send")
      (let* ((w (head-last-cols head))
             (h (head-last-rows-n head))
             (text (format nil "~a~a~a~dx~d — my terminal exactly as this head drew it, ANSI escape codes included, so what you are reading IS the rendering and not a description of it~a~%~{~a~%~}~a~%"
                           message
                           (if (plusp (length message)) "

" "")
                           *cells-open* w h *cells-mark-end*
                           (head-last-rows head)
                           *cells-close*)))
        (%prompt head text))))

