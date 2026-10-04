;;;; click — the mouse: which row a click landed on, and what it selected
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- click ;;;
;;;
;;; A click lands on a pane LINE; the cursor counts pane ROWS. The two differ by
;;; every header line above the list — the reference found this in its own test
;;; after passing one where the other was meant — so the conversion is done in
;;; ONE place per pane rather than recomputed at the click site.

(defun click-header-lines (head)
  "How many lines of MODE's pane come before its first selectable row.

Read from the pane function itself, by asking it where the cursor is with the
cursor forced to row 0: a pane that owns a cursor returns `header + sel` as its
second value, so at 0 that value IS the header. Asking rather than recounting
means the two cannot drift — a header that grows (a click hint, say) moves both
together."
  (let* ((mode (head-mode head))
         (saved (head-picker-sel head)))
    (unwind-protect
         (progn
           (setf (head-picker-sel head) 0)
           (multiple-value-bind (lines sel-line)
               (case mode
                 (:picker (picker-lines (head-session head) 0 80))
                 (:jobs (jobs-lines head 80))
                 (:subagents (subagent-lines head 80))
                 (:todos (todos-lines head 80))
                 (:config (config-lines head (head-settings head) 80))
                 (t (values nil nil)))
             (declare (ignore lines))
             (or sel-line 0)))
      (setf (head-picker-sel head) saved))))

(defun todo-stop-at (head)
  "The stop the todos cursor is on, and its index in `todos-stops` — as two values.

**The single answer to *which row is the cursor on*, and every caller comes through it**: a key
that acts on a row, a click converting a line to a row, and the pane deciding where to draw the
mark. R44's first cut answered it in three places — the pane from the repo's indices, the key
from a `minusp`, the click from `line - header` — and each of the operator's two reports was one
of the three disagreeing with the pane.

The index is CLAMPED to the enumeration the way the pane clamps when it draws, because a list
can change under the cursor: a deletion, a `TodosUpdated`, a different workspace. A key pressed
against a list that just changed acts on a row rather than on an index that no longer exists."
  (let* ((stops (todos-stops head))
         (n (length stops))
         (i (if (plusp n) (min (max 0 (head-picker-sel head)) (1- n)) 0)))
    (values (if (plusp n) (nth i stops) nil) i)))

(defun todo-stop-at-line (head line)
  "The stop index drawn on pane LINE, or NIL when that line is not a selectable row.

Read from `todos-lines`' third value — the lines the stops were actually drawn on — so a click and
the drawing cannot disagree about where a row is. That disagreement is exactly the operator's
*\"mouse doesnt click\"*: the add row is the first selectable row of the pane and `line - header`
made it a negative index, which the old conversion threw away."
  (let* ((*pane-scroll* 0) (*pane-room* 1000))
    (multiple-value-bind (lines sel stop-lines) (todos-lines head 80)
      (declare (ignore lines sel))
      (position line stop-lines))))

(defun %todo-implement (head)
  "Compose a prompt from the `TODO.md` subtree under the cursor. T when a key was taken.

**AN INSTRUCTION, NOT A BOARD WRITE**, in the operator's words: *\"take the todo subtree and implement
it.\"* The gesture puts a SENTENCE IN THE COMPOSER and does not submit — *\"the operator gets to edit the
instruction before sending, which matters because 'implement this' is rarely the whole of what they
mean\"* — which is the same shape `%op-call-draft-open` already has for the operator-call door.

**NOTHING CROSSES THE WIRE, and that is what dissolves every objection a promotion had.** R57's
amendment records letibot's four: an authorship question (a pulled row needs a `by`, and a third author
was the real blocker), the half-replace problem, prompt-content changing as a side effect, and
hierarchy. A prompt has none of them — the operator is the author of their own sentence, nothing on the
board moves, a prompt IS a turn so changing what the model is told is the point, and the tree stays in
the file where it never left.

**AND THE BOARD STAYS THE MODEL'S OWN DECOMPOSITION.** `todo_write` is how it breaks work down; a board
pre-filled with the project's intent would be the model being handed a plan instead of making one. Its
own first `todo_write` of the turn produces that row with better wording than this could copy.

Only a `TODO.md` row composes anything. The session's own rows are already the board."
  (multiple-value-bind (stop i) (todo-stop-at head)
    (declare (ignore i))
    (if (not (eq (car stop) :repo))
        (progn (say head "that is a session row — only a TODO.md item becomes a prompt") t)
        (let* ((ws (getf (session-wiring (head-session head)) :workspace))
               (row (nth (cdr stop) (repo-todo-rows-cached ws)))
               (line (getf row :line)))
          (cond
            ((null line) (say head "that row cannot be addressed in the file") t)
            (t (multiple-value-bind (text why) (repo-todo-implement-text ws line)
                 (cond
                   (why (say head why) t)
                   (t
                    ;; **THE COMPOSER, REPLACED RATHER THAN APPENDED.** `%op-call-draft-open` sets
                    ;; the buffer for the same reason: an instruction composed from a subtree is a
                    ;; whole thought, and appending it to a half-typed prompt would silently join two
                    ;; of the operator's sentences into one the model reads as a single request.
                    (setf (composer-buffer (head-composer head)) text
                          (composer-cursor (head-composer head)) (length text)
                          (head-dirty head) t)
                    (say head "composed from TODO.md — edit it, then enter sends it")
                    t)))))))))

(defun %todo-toggle (head)
  "Mark the row under the cursor done, or open again. T when a key was taken.

**The missing half of an editable list.** Add and delete existed; a row you can create and destroy but
never FINISH is not editable, and until this the only hand that could move one of the operator's rows
was the MODEL's — `todo_write`'s `operator` field, naming the row by quoting its words. So the operator
could be reminded about a row they had already done and had no key to say so.

**Which section decides what the mark MEANS, and the two are genuinely different things:**

  · `(:mine . ID)` — the head's OWN rows: per project, in sqlite, pushed to the daemon's board as
    `:by operator`. Ticking one flips its status, saves that row, and re-pushes the board — so the idle
    nag stops naming it. Nobody else ever sees it;
  · `(:repo . I)` — a row of the workspace's **TODO.md**: the SHARED queue, committed, and possibly
    being edited by somebody else right now. Ticking one writes ONE LINE of that file. The operator's
    own split, and the reason they are two sections rather than one list.

The third case is a refusal that SAYS so, on every path — the model's rows are not stops (no key acts
on them), a heading has no checkbox, and a `[~]` row is somebody's claim.

`space` because it is the todo convention everywhere else, and because it is free here: Enter is add
and unfold, delete is remove, and a space that typed a character into the composer while the pane was
up was already the fall-through this key now owns."
  (multiple-value-bind (stop i) (todo-stop-at head)
    (declare (ignore i))
    (case (car stop)
      (:mine
       (let* ((id (cdr stop))
              (item (find id *operator-todos* :key (lambda (x) (getf x :id)) :test #'equal)))
         (if (null item)
             (progn (say head "that row is not in this head's list any more") t)
             (let* ((done (string-equal (or (getf item :status) "open") "completed"))
                    (now (if done "open" "completed")))
               (setf (getf item :status) now)
               ;; **ONE ROW, not the whole list** — `save-operator-todos` would be a transaction per
               ;; keypress, which the store's own docstring refuses for the add path and for the same
               ;; reason.
               (when *write-prefs*
                 (store-save-todo item nil (operator-todos-workspace head)))
               ;; **and the daemon's board, so the reminder stops counting it.** The nag reads that
               ;; board; a tick this head kept to itself would leave the model being asked about work
               ;; that is finished.
               (push-operator-todos head)
               (say head (if done "marked open again" "marked done"))
               t))))
      (:repo
       ;; **THE SHARED FILE, one line of it.** The row's index is into `repo-todo-rows-cached`, and
       ;; the LINE comes from the row itself — recorded by the parser, because re-deriving it here is
       ;; a second arithmetic over the same file (R44's *two enumerations is the defect*).
       (let* ((ws (getf (session-wiring (head-session head)) :workspace))
              (row (nth (cdr stop) (repo-todo-rows-cached ws)))
              (line (getf row :line)))
         (cond
           ((null line) (say head "that row cannot be addressed in the file") t)
           (t (multiple-value-bind (mark why) (repo-todo-toggle ws line)
                (say head (cond (why why)
                                ((eq mark :done) "marked done in TODO.md")
                                (t "marked open again in TODO.md")))
                ;; and the pane redraws from the file it just changed
                (setf *repo-todo-cache* nil *repo-todo-stamp* nil)
                t)))))
      (t (say head "nothing to mark on that row") t))))

(defun %todo-remove (head)
  "Delete the operator's own item under the cursor. T when a key was taken.

**Only the operator's own rows, and only ones nothing has started** — *\"i want to be able to
remove non-started todos\"*, and *non-started* is the whole of the guard: an item in progress is
work somebody is doing, and dropping it from under them is not a note being tidied up.

**The model's rows are refused by name**, which is the R44 boundary on the keyboard: the head has
no frame that writes a todo, so deleting one of the model's rows would take it off this screen
while the model went on holding it — and the next `TodosUpdated` would put it back, which reads as
the head having lost the operator's instruction. Saying who owns the row is the honest answer.

A refusal SAYS something, on every path: a key that appears to do nothing is the defect this head
keeps finding elsewhere."
  (multiple-value-bind (stop i) (todo-stop-at head)
    (case (car stop)
      (:mine
       ;; **BY ID, and that is the operator's own point** — *"a todo item is identified by a hash
       ;; or something like a commit"*. There is no position here and nothing to go stale: the id
       ;; was minted when the item was added and it addresses that item for the item's whole life,
       ;; whatever the list has done in between.
       (let* ((id (cdr stop))
              (item (find id *operator-todos* :key (lambda (x) (getf x :id)) :test #'equal))
              (status (or (and item (getf item :status)) "open")))
         (cond
           ((null item)
            ;; the id is not in the list any more — a `remove` already landed, or the list was
            ;; replaced under the cursor. Said rather than crashing on a `getf` of NIL.
            (say head "that item is not in the plan any more")
            t)
           ((string= status "in_progress")
            (say head "that one is in progress — an item something is working on is not a note any more")
            t)
           (t
            (setf *operator-todos*
                  (remove id *operator-todos* :key (lambda (x) (getf x :id)) :test #'equal))
            ;; **and the STORE follows it, one row at a time** — a list that lost a row on
            ;; restart would come back with the row, which is the same defect as losing the add
            (when leticl::*write-prefs*
              ;; (the remove path needs no workspace: the id is the primary key, so a row is
              ;; deleted where it lives whichever project that is)
              (leticl::store-delete-todo id))
            ;; **and the DAEMON's board, so the reminder stops counting it.** The board holds the
            ;; operator's rows beside the model's and the idle nag reads it; a removal this head
            ;; kept to itself would leave the nag asking about work the operator had dropped.
            (leticl::push-operator-todos head)
            ;; the cursor may now point past a shorter enumeration, which `todo-stop-at` clamps
            ;; for the next key — but the screen has to say something NOW, so the mark is put
            ;; back on a row that exists rather than left on the one just deleted.
            (let ((n (length (todos-stops head))))
              (setf (head-picker-sel head) (if (plusp n) (min i (1- n)) 0)))
            (say head (format nil "removed `~a`" (getf item :content)))
            t))))
      ;; **the two refusals, each naming WHO owns the row** — the model's are on the screen and the
      ;; head cannot write them (no frame; see R44), and the repo's are a file a person edits.
      ;;
      ;; The `:model` arm is **unreachable while `todos-stops` skips the model's rows**, and it is
      ;; kept rather than deleted: it is the refusal that must already be written on the day those
      ;; rows become stops, and a `case` whose other arms are reachable is the place a reader looks
      ;; for it. A dead arm with a reason is cheaper than a missing one found by a keypress.
      ((:model)
       (say head "that is the model's own item — this head cannot write its list, so dropping the row here would take it off your screen while the model went on holding it. ask the model to drop it")
       t)
      (:repo
       (say head "a TODO.md item is the project's intent, not the model's board — space ticks that one line in place, and i composes a prompt from its subtree")
       t)
      (t nil))))

(defun dash-click-sel (head line)
  "Select the panel a click on pane LINE lands on. T when it selected one.

**The layout is asked AGAIN at click time**, which is what `todos-click-sel` does one pane over and
for its reason: the function that DREW the pane is the only thing that knows where its rows are, so
re-asking it cannot disagree with what is on the screen. Recomputing the arithmetic here would be a
second layout that drifts from the first — `todos-stops`' docstring calls that *\"the defect\"*.

The panel is left CLOSED, because a click is a selection: opening on a click as well would make a
mis-aimed click both move the cursor and unfold a box, and the second half is the one you cannot see
coming."
  (declare (ignore head))
  ;; **THE MAP FROM THE DRAW**, not a second layout: `*dash-line-map*` is written by
  ;; `dash-frame-lines` on the frame the operator is looking at, so a click cannot disagree with
  ;; the screen it was aimed at. (It used to be this function's return value, and the frame bound
  ;; it to the cursor's line — see `dash-frame-lines`.)
  (let ((i (dash-panel-at-line line *dash-line-map*)))
    (when i
      (setf *dash-nav* (list :sel i :scroll 0 :open nil)
            (head-dirty *head*) t)
      t)))

(defun click-row->sel (head mode line)
  "The cursor ROW a click on pane LINE means, or NIL when it is not a row.

Guarded three ways, and every one of them is a click that must not select
something nobody can see:

  · the line must be inside the WINDOW THE FRAME ACTUALLY DREW — not merely
    inside the list. A click in the blank space below a short list, or below a
    truncated one, lands on a line that is not on screen;
  · it must be past the header, which is not a row;
  · and it must be within the list.

The first guard is here rather than at the call site so it cannot be forgotten
by a second caller — which is how the reference found this, in its own test."
  (declare (ignore mode))
  (let* ((window-start *pane-scroll*)
         (window-end (+ *pane-scroll* *pane-room*))
         ;; the picker, the jobs and the subagents draw TWO lines per row — the
         ;; row and the dim fact line under it — so a click on either half is
         ;; the same row
         (per-row (if (member (head-mode head) '(:picker :jobs :subagents)) 2 1))
         (sel (floor (- line (click-header-lines head)) per-row))
         (n (pane-row-count head (head-mode head))))
    (when (and (>= line window-start) (< line window-end))
      (cond
        ;; **THE ADD ROW IS A ROW, AND IT IS THE ONE ROW THAT IS NOT AN INDEX** (R44). It sits
        ;; above the repo's first row, so `line - header` is NEGATIVE on it and the guard below
        ;; rejected it: the operator's *"mouse doesnt click"*. Asked of the pane rather than
        ;; counted here, for `click-header-lines`' own reason — the row's line is a fact the pane
        ;; knows and this function does not, and two spellings of it drift the first time the
        ;; header above it grows.
        ((eq (head-mode head) :todos) (todo-stop-at-line head line))
        ((and (>= sel 0) (< sel n)) sel)))))

(defun pane-row-count (head mode)
  "How many ROWS the pane MODE has for its cursor to walk — one place, read by the
arrow keys and the click conversion alike, so the two cannot disagree about what
the last row is.

The picker's count is the FILTERED list (`picker-sessions`), the config pane's is
every row (`config-rows`), the todos pane's is the repo's rows, the subagents' is
the folded tree — each the same list the pane draws from."
  (pane-cursor-rows (pane-for mode) head))

(defun %todo-toggle-hide-done (head)
  "Show or hide the DONE rows in the todos pane. T when a key was taken.

**The operator's ask:** *\"in todo panel i want a mode where done items hidden\"*. It flips
`*todos-hide-done*` and nothing else — `todos-stops` and `todos-lines` both read that flag, so the
rows that disappear are the rows the cursor stops offering in the same frame.

**AND THE CURSOR IS CLAMPED, which is the one thing this has to get right.** `head-picker-sel` is an
INDEX INTO `todos-stops`, and hiding rows SHORTENS that list: a cursor left at 7 in a list that is now
3 long draws no mark at all, so the pane would come back with nothing selected and every key acting on
row 0. `%todos-move`'s own clamp is the shape — `(min (max 0 sel) (1- len))` — and it is repeated here
rather than shared because this is not a movement: there is no step to add, and a helper taking a step
of 0 would be one more thing to be wrong.

**IT SAYS WHAT IT DID.** A mode is invisible by nature — the rows are simply gone — so the one thing
the head must do is confirm the press, in the count the pane can honestly give. The pane draws its own
line for the state as well (see `todos-lines`); this is the notice for the moment of the press, which
is when the reader is looking for one."
  (setf *todos-hide-done* (not *todos-hide-done*))
  (let ((len (length (todos-stops head))))
    (setf (head-picker-sel head)
          (if (plusp len) (min (max 0 (head-picker-sel head)) (1- len)) 0)
          ;; folding on a hide is not a nicety: `*repo-todo-open*` belongs to the row under the
          ;; cursor, and the cursor has just landed on a different row.
          *repo-todo-open* nil
          (head-dirty head) t))
  (say head (if *todos-hide-done*
                "done items are hidden — h shows them again"
                "done items are shown again"))
  t)

(defun %todos-move (head n)
  "Up (N = -1) or Down (N = 1) on the todos pane: the cursor walks `todos-stops` and wraps
at either end, folding whatever was open.

**One ring, one enumeration, no special cases** — and both of those were corrections the
operator made by using it. The first cut kept the add row OUTSIDE the ring (reachable by `Up`
from the top, never by `Down`) so that the repo's own wrap could be preserved; *\"add todo item
is not reachable - arrows dont go here\"*. The second walked `-1` plus the repo's stop indices
while the pane drew its rows from a third list, so the row the cursor was on and the row the
pane scrolled to were computed two ways; *\"arrows dont go here\"* again, from the other end.

`(mod … (length stops))` is the whole of the movement. `todos-stops` is the list; nothing here
knows what a row IS."
  (let* ((stops (todos-stops head))
         ;; **`len`, NOT `n`** — and the shadow is not a style point. N is the MOVEMENT (+1 or -1)
         ;; and this is the LENGTH, and the first cut of this named the length `n` too: the
         ;; arithmetic below then read `(mod (+ sel n) n)` — the length used as its own step — which
         ;; is `(mod (+ sel len) len)`, always ZERO. The cursor sat on the head of the ring and no
         ;; arrow moved it, which is the operator's *"arrows dont go here"* in its third and silliest
         ;; costume. Measured: `[PRE sel=0 value=0]` inside the function while the same expression
         ;; written outside it with a literal step gave 1.
         (len (length stops)))
    (when (plusp len)
      (setf *repo-todo-open* nil
            ;; a stale index — a deletion, a `TodosUpdated` — wraps to a row rather than off the
            ;; end, which is the same clamp the pane makes when it draws
            (head-picker-sel head)
            (mod (+ (min (max 0 (head-picker-sel head)) (1- len)) n) len)
            (head-dirty head) t))))

