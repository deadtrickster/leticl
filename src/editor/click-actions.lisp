;;;; click-actions — what a click on a row does, per pane
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defun %pick-card-top (head)
  "The screen row the picker card's FIRST line landed on.

 **READ OFF THE LAST PAINT, not recomputed** (letibot `9e82bdb`). The render places a card at
 `chrome-top`, which is the composer's row minus the NOTICE and the STALL rows — and the arithmetic
 this used to do counted only the hint bar, the box and the card, so **with any head note up every
 click landed one rung off**, and a click on the FIRST rung computed a negative line and selected
 nothing. MEASURED by the sweep's batch A. The render now records the row it drew the card from
 (`*card-top*` in `render/history-cache.lisp`), which is the same shape the panes have kept all along
 (`*pane-top*`, `*pane-room*`) — and the old arithmetic survives here ONLY as the fallback for a caller
 that asks before any paint, where it is the version that is wrong when a note is up."
  (or *card-top*
      ;; **THE FALLBACK, and it is the version that is wrong when a note is up** — kept so a caller
      ;; that asks before any frame has been drawn gets a number rather than a NIL it would have to
      ;; handle. A click cannot arrive before a frame, so this path is the tests' and the first
      ;; frame's own, and `chrome-top`'s subtractions (the notice and the stall) are what it cannot do.
      (let* ((cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
             (composer-rows (length (composer-line head cols)))
             (card-rows (length (pick-card-lines head cols))))
        (- (head-rows head) 1 composer-rows card-rows))))

(defun %pick-click (head row)
  "A click on the mode/model picker card: the row under the pointer becomes the
cursor's row, and NOTHING is taken — select and confirm stay two acts, because a
gesture that commits on press is how a misclick moves somebody's session
(app.rs:3639-3651).

The card runs with `head-mode` :normal and `*pick-open*` set, so the pane click
arm — which tests `head-mode` — never saw it and a click on the card fell through
to the composer and was dropped."
  (let* ((n (length (pick-choices head)))
         ;; the card's first line is its title; the choices follow —
         ;; **ONE ROW EACH, EXCEPT THE VERBOSITY CARD'S TWO** (sweep 2026-10-11, B.3): that card
         ;; draws each rung with its gloss under it (`pick-card-lines`, R38), so `row - top - 1`
         ;; named the wrong rung for every row but the first and a click on a gloss line fell
         ;; between two. The layout is the card's own: two lines a choice there, one everywhere
         ;; else, and a click on either line of a pair is the same choice.
         (per-choice (if (eq *pick-open* :verbosity) 2 1))
         (line (- row (%pick-card-top head) 1))
         (sel (if (minusp line) -1 (floor line per-choice))))
    (when (and (plusp n) (<= 0 sel) (< sel n))
      (setf (head-picker-sel head) sel (head-dirty head) t))
    t))

(defun %screen-row-text (head row)
  "Screen ROW as the plain text the head DREW — the cells, not the segments that were put there.

Read from `head-screen` rather than `head-last-rows`: the cell buffer is what `%render` fills, and
it is there whether or not the frame has been painted to a terminal yet, so a hit test over it
agrees with the drawing the reader sees and can be exercised without a tty. NIL for a row that is
off the screen."
  (let ((cells (and (head-screen head) (screen-row (head-screen head) row))))
    (when cells
      (string-right-trim " " (format nil "~{~a~}" (mapcar #'cell-ch cells))))))

(defun %screen-edge-row (head)
  "The screen row the composer's top edge was DRAWN on, or NIL — from the cells, as
`%composer-edge-row` reads it from the painted rows. **Bottom up**: the composer is the lowest
box on the screen, and a tool card's own `╭` in the transcript above must not be taken for it."
  (when (head-screen head)
    (loop for r from (1- (head-rows head)) downto 0
          for text = (%screen-row-text head r)
          when (and text (search "╭" text)) return r)))

(defun %card-rows-hit (head row needles height)
  "Which of NEEDLES the click on screen ROW landed on, inside a card drawn in the HEIGHT rows
above the composer's edge — or NIL.

NEEDLES is one string per choice, in the card's order, each the text that opens that choice's
first row. The card's rows are scanned top-down and each needle's FIRST row is recorded (longest
needle first, so `Deny` cannot claim `Deny, and tell the model why`'s row); the click belongs to
the choice whose first row is the nearest at or above it, so a click on a wrapped continuation or
on the dim consequence under a quit choice still names that choice. A click above the first
choice or below the last choice's rows — on the card's question, or on its hint row — is NIL."
  (let ((edge (%screen-edge-row head)))
    (when (and edge (< row edge) (>= row (max 0 (- edge height))))
      (let ((starts (make-array (length needles) :initial-element nil))
            (order (sort (loop for i from 0 below (length needles) collect i) #'>
                         :key (lambda (i) (length (nth i needles))))))
        (loop for r from (max 0 (- edge height)) below edge
              for text = (or (%screen-row-text head r) "")
              do (dolist (i order)
                   (when (and (null (aref starts i)) (search (nth i needles) text))
                     (setf (aref starts i) r)
                     (return))))
        (let ((hit nil))
          (loop for i from 0 below (length needles)
                for start = (aref starts i)
                when (and start (<= start row)
                          (or (null hit) (> start (aref starts hit))))
                  do (setf hit i))
          hit)))))

(defun %decision-click (head row)
  "A click on the OPEN ASK's ladder selects that rung — select, never answer (the reference's
`hits.rs`: *the decision card; its stops are the ladder's rows*). T when the click was the
ladder's.

The rungs are found on the screen by their own text — `LABEL  (option_id)` for a permission,
the bare choice for a question — within the ladder's height above the composer's edge, and the
hint rows under the rungs are excluded by their own words. The click stops at `head-decision-sel`
and Enter still answers: a gesture that commits on press is how a misclick grants a permission."
  (let* ((d (%open-decision head))
         (options (decision-options d)))
    (when (and d options)
      (let* ((cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
             (ladder (nth-value 1 (permission-card-lines head cols)))
             (height (+ (length ladder) 2))
             (needles (mapcar (lambda (o)
                                (if (and (consp o) (getf o :option-id))
                                    (format nil "~a  (~a)" (%choice-label o) (getf o :option-id))
                                    (%choice-label o)))
                              options))
             (hit (%card-rows-hit head row needles height)))
        (when hit
          ;; the hint rows sit under the last rung, and a click there is on no rung
          (let ((text (or (%screen-row-text head row) "")))
            (unless (or (search "to choose" text) (search "denies and sends" text))
              (setf (head-decision-sel head) hit (head-dirty head) t)
              t)))))))

(defun %quit-card-click (head row)
  "A click on the quit card selects that choice — and takes nothing (the reference's `QuitCard`
hit: *its stops are its two choices*). T always, because the card owns the pointer while it is
up: a click that fell through to the transcript under a question about leaving would be a key
with a second meaning, which `%quit-card-key`'s fail-closed rule refuses."
  (let* ((cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
         (height (length (quit-card-lines head cols)))
         (hit (%card-rows-hit head row (mapcar #'car (quit-choices head)) height)))
    (when hit
      (setf (head-quit-sel head) hit (head-dirty head) t))
    t))

(defun %composer-edge-click (head key)
  "Did this click land on one of the composer edge's count labels? T when it took the click.

A press only (the mouse grammar's `:press` is what `%click` is called for), and only on the row
the box's TOP edge was actually painted on — a click one row off is a click on the transcript."
  (let ((row (getf key :y))
        (x (getf key :x)))
    (when (and row x)
      (let ((edge-row (%composer-edge-row head)))
        (when (and edge-row (= row edge-row))
          (let ((hit (find-if (lambda (b) (and (>= x (second b)) (< x (third b))))
                              (%composer-edge-buttons head))))
            (when hit
              (%open-pane head (first hit))
              t)))))))


(defun %composer-edge-row (head)
  "The screen row the composer's top edge was painted on, or NIL."
  (let ((rows (head-last-rows head)))
    (and rows (position-if (lambda (r) (and (stringp r) (search "╭" r))) rows))))

(defun %show-edit-change (head item)
  "An edit row's CHANGE in the read overlay — the whole of what this head holds about it: the excerpt
 the daemon sent (both sides, and the excerpt's place in each file) through `edit-lines`, the same
 renderer the inline diff under the row uses.

 **NOT the whole file, and the title does not pretend otherwise.** The reference's popup draws rano's
 review view OVER the file (`88b003d`), and a head holding an excerpt cannot; `ctrl-]` is this head's
 door to the file itself, so the title names it rather than leaving the reader to find out which half
 they got."
  (let ((edit (getf (item-body item) :edit)))
    (if (null edit)
        (say head "that row carries no change to open")
        ;; **THE MODE IS THE PANE IT IS DRAWN OVER, and the transcript's is `:normal`** — not a word
        ;; of its own. `read-overlay-open-p` asks the two to be EQUAL ("a record for another mode is
        ;; not a view"), so an overlay opened with a borrowed name would be invisible: the state would
        ;; be set and the screen unchanged, which is the defect the test beside this caught.
        (open-read-overlay head (head-mode head)
                           (format nil "change — ~a · ctrl-] opens the file"
                                   (or (getf edit :path) "?"))
                           (edit-lines edit (max 20 (- (head-cols head) +gutter+ +right-margin+))
                                       ;; **THE SUBJECT, so the path is named ONCE** (`901acc0`): the
                                       ;; overlay draws its title above the body, and without this the
                                       ;; diff repeats the file under it — the same string twice, the
                                       ;; second time in the loudest style on the card. The predicate
                                       ;; strips quotes and checks the subject LEADS with the path, so a
                                       ;; bare path is exactly the right subject.
                                       :subject (getf edit :path))))))

;;;; --- THE HINTS ARE BUTTONS (letibot `5296c6e`, the sweep's batch A) ---------------------- ;;;;

(defun %key-for-word (word)
  "The KEY EVENT the hint bar's WORD stands for, or NIL when it is not a key's own name.

 **THE BAR'S VOCABULARY, READ RATHER THAN GUESSED**: `esc`, `enter`, `tab`, `ctrl-x`, `alt-x` and
 `/verb`. `↑↓` is deliberately NOT here — it names two keys, and a button that had to choose would be
 guessing — and neither is `shift+drag`, which is the terminal's own gesture and not this head's. A
 word this cannot read answers NIL, and the click does NOTHING with it."
  (cond
    ((or (null word) (zerop (length word))) nil)
    ((string-equal word "esc") '(:type :esc))
    ((string-equal word "enter") '(:type :enter))
    ((string-equal word "tab") '(:type :tab))
    ((and (= (length word) 6) (string-equal (subseq word 0 5) "ctrl-"))
     (let ((ch (char-downcase (char word 5))))
       (and (alpha-char-p ch) (list :type :ctrl :ch ch))))
    ((and (= (length word) 5) (string-equal (subseq word 0 4) "alt-"))
     (let ((ch (char-downcase (char word 4))))
       (and (alpha-char-p ch) (list :type :alt :ch ch))))
    ((and (> (length word) 1) (char= (char word 0) #\/))
     (list :type :slash :verb (subseq word 1)))))

(defun %hint-word-at (text x)
  "The whitespace-delimited token of the DRAWN hint row that column X lies in.

 `ctrl-s sessions` is ONE button and this answers `ctrl-s`: the bar's shape is *key label · key
 label*, so the label after the space belongs to the button rather than naming it."
  (when (and text (<= 0 x) (< x (length text)))
    (let* ((n (length text))
           (right (or (position #\space text :start x) n))
           (left (1+ (or (position #\space text :end (min (1+ x) n) :from-end t) -1))))
      ;; **A CLICK ON A SEPARATOR IS NOBODY'S BUTTON.** The bar's items are separated by spaces and
      ;; `cdot`, so a pointer landing BETWEEN two words belongs to neither — and without this guard
      ;; `subseq` was handed a start past its end, which is a crash rather than a miss.
      (when (< left right)
        (string-trim " ·" (subseq text left right))))))

(defun %hint-key-at (head x)
  "The KEY the drawn hint bar stands for at column X — or NIL. **A PURE QUERY: it acts on nothing.**

 **IT IS A QUERY AND NOT ONLY A CLICK'S FIRST HALF, which is the whole point** (letibot `9c3e0b1`):
 *the hover is worked out from the frame that is drawn, not kept*. The render asks this for the light, and
 the click asks it for the act — so the light IS what a click at the pointer would act on now, and the two
 cannot disagree about which row is a button.

 **THE KEPT VERSION WAS WRONG IN A WAY NO TEST WOULD HAVE CAUGHT HERE**: it compared a ROW, so anything
 drawn over that row lit up — the reference's own words for the same defect are *the click that put the
 diff popup up lit the popup's text*. Reading the CELLS cannot do that: a word the table does not know is
 not a key, wherever it happens to be."
  (let ((text (%screen-row-text head (1- (head-rows head)))))
    (when text
      (%key-for-word (%hint-word-at text x)))))

(defun %hint-click (head x)
  "A click on the hint bar TYPES THE KEY THE HINT NAMES (letibot `5296c6e`).

 **THE BAR IS A LIST OF BUTTONS**, and this head drew it as prose for so long that a reader with a
 mouse had to lift their hand to the keyboard to take the advice the screen had just given them.

 **THE THREE GUARDS, the reference's own, each a way this could hurt a reader**: a `/command` goes in
 only into an EMPTY composer; `ctrl-\\` is never typed (a misclick that detaches from a running program
 is not a thing anybody asked for); and a word this head cannot read does NOTHING at all."
  (let ((key (%hint-key-at head x)))
    (when key
      (cond
        ((eq (getf key :type) :slash)
         (and (zerop (length (composer-buffer (head-composer head))))
              (progn (%run-command head (getf key :verb)) t)))
        ((and (eq (getf key :type) :ctrl) (eql (getf key :ch) #\|)) nil)
        (t (progn (%handle-key head key) t))))))

(defun %show-notice (head item)
  "A notice row's WHOLE text in the read overlay — what its one-line summary is a SUMMARY of.

 **The row is a hook and the paragraph is the fact** (letibot `161b34d`/`f076792`): an emergency is one
 line naming the target and the reason, and a stopped review is one line naming the branch and the
 verdict, because the alternative was a screenful of prose. The prose is not thrown away — it is here,
 read off the item the daemon sent rather than from a second copy this head kept."
  (let ((text (item-display-text item)))
    (open-read-overlay head (head-mode head)
                       (or (getf (item-body item) :name) "the daemon's notice")
                       (mapcar (lambda (l) (list (cons l nil)))
                               (uiop:split-string text :separator '(#\newline))))))

(defun %click (head key)
  "A CLICK selects the row under the pointer. T when the click was a list's.

Before the text keys, because a click is unambiguous about what it means and
there is nothing else to weigh it against. Guarded by the rows the frame actually
DREW — a click into the space below a short list must not select a row nobody can
see, which is why the pane records its room and offset from the last paint rather
than from the click."
  (let ((row (getf key :y)))
    (cond
      ;; **THE COMPOSER EDGE'S COUNT LABELS ARE BUTTONS** (`9ac7dad`), and they are checked FIRST
      ;; because they are not in a list and not a pane: a click on `2 subagents running` opens the
      ;; subagents pane, and on `1 job running` the jobs pane. The targets come from the PAINTED
      ;; row (`%composer-edge-buttons`), so this cannot disagree with what the reader sees.
      ((%composer-edge-click head key) t)
      ;; **AND THE HINT BAR IS A LIST OF BUTTONS TOO** (letibot `5296c6e`) — read from the cells, so a bar
      ;; that has dropped its tail items cannot offer a button that is not on the glass.
      ;;
      ;; **BELOW THE EDGE, WHICH SHARES THIS ROW.** When the fit ladder drops the hint bar the
      ;; COMPOSER takes the last row, and its count labels are buttons of their own — so they are asked
      ;; first and this answers for what is left. Asking this one first made a click on
      ;; `N subagents running` type nothing at all, which is how the suite caught the order.
      ((%hint-click head (getf key :x)) t)
      (*pick-open* (%pick-click head row))
      ;; **THE ASK CARD'S RUNGS ARE A LIST TOO** (sweep 2026-10-11, B.3) — the router had no card
      ;; arm, so a click on `▸ Allow once` fell through to the transcript and did nothing while
      ;; the picker card one row over took clicks. The quit card is not here because it owns every
      ;; key before this router is reached (`%quit-card-key`), and its click arm lives there.
      ((and (%open-decision head) (eq (head-mode head) :normal) (%decision-click head row)) t)
      ;; **THE DASHBOARD IS A LIST OF PANELS, AND A CLICK PICKS ONE.** It goes ahead of the shared
      ;; pane arm because a panel's row is a LINE and not an index into a per-row list — the boxes
      ;; are different heights, so `click-row->sel`'s arithmetic (which assumes one or two lines per
      ;; row) would land on the wrong box for every panel but the first.
      ((eq (head-mode head) :dash)
       (let ((line (+ *pane-scroll* (- row 1))))
         (when (and (>= line 0) (< line (+ *pane-scroll* *pane-room*)) (< line *pane-lines*))
           (dash-click-sel head line)))
       t)
      ;; **AND THE QUEUE PANES, WHICH WERE MISSING FROM THIS LIST** (letibot `8d5f418`, the sweep's batch
      ;; A). A click on a queue row — which HAS a cursor and the `a/v/d/r` verbs — did nothing here and
      ;; fell through to the TRANSCRIPT arm below, which opens an edit row read off `*hist-bounds*`: a
      ;; pane had replaced the transcript, so those bounds name rows nobody can see. Both views are the
      ;; same list (`*queue-view*`), and both have a cursor the click can move.
      ((member (head-mode head) '(:picker :jobs :subagents :todos :config :queue :standing))
       ;; the pane starts at screen row 1 (row 0 is the top border), and the
       ;; offset says how many pane LINES are hidden above it
       (let ((line (+ *pane-scroll* (- row 1))))
         (when (and (>= line 0) (< line (+ *pane-scroll* *pane-room*)) (< line *pane-lines*))
           ;; **AND THE `waits on …` WORDS ARE A LINK** (letibot `5054187`): the operator's own ask —
           ;; *"waits on j97" - make j97 a link to the real job*. **Asked BEFORE the row's selection**,
           ;; because a click ON the words means the job and one anywhere else on the row means the row —
           ;; a gesture that did both would open a window every time a reader selected a row.
           (let ((link (and (eq (head-mode head) :todos)
                            (%todo-link-at head line (getf key :x)))))
             (if link
                 (cond
                   ((eq (car link) :job)
                    (let ((job (find (cdr link) (head-jobs head)
                                     :key (lambda (j) (getf j :id)) :test #'equal)))
                      ;; **A JOB THE TABLE NO LONGER LISTS IS NOT OPENED FROM MEMORY**: there is nothing to
                      ;; read, and a window opened on nothing would be the pane inventing a job.
                      (if job
                          (progn (open-job-out job) t)
                          (progn (say head (format nil "~a is not in the jobs table any more" (cdr link))) t))))
                   (t
                    ;; **A CHILD'S EDGE OPENS THE CHILD'S READ** (letibot `79c32c1`), through the same door
                    ;; `/peek` uses. **The row draws the SHORT id and the frame wants the WHOLE one**, so
                    ;; the child is found by the tail `%short-id` printed — the same rule, read backwards
                    ;; — and a child this session does not know is SAID rather than silently ignored.
                    (let ((want (cdr link))
                          (child nil))
                      (dolist (r (ignore-errors (subagent-rows head)))
                        (let ((id (getf r :session-id)))
                          (when (and (stringp id) (<= (length want) (length id))
                                     (string= want (subseq id (- (length id) (length want)))))
                            (setf child r))))
                      (if child
                          (progn (%send head (make-peek (getf child :session-id))) t)
                          (progn (say head (format nil "~a is not a subagent this session knows" want))
                                 t)))))
                 (let ((sel (click-row->sel head (head-mode head) line)))
                   (when sel
                     (setf (head-picker-sel head) sel
                           (head-dirty head) t)))))))
       t)
      (t
       ;; **A CLICK ON AN EDIT ROW OPENS ITS CHANGE** — the reference's popup (`88b003d`) through the
       ;; door this head has. The row→item map is `*hist-bounds*` (`(ITEM-ID START END)`, counted in the
       ;; list `*view-start*` indexes), so a mouse ROW becomes a LINE and then an item; the change is the
       ;; row's own `:edit` excerpt.
       ;;
       ;; **A click that lands on no row does nothing** — the ordinary answer for the space below a short
       ;; conversation — and neither does one on a row that is not an edit: the transcript has no CURSOR
       ;; for a reader to select with, and inventing one here would be a second way to walk it.
       ;;
       ;; **AND THE LINE MUST BE INSIDE THE ITEM'S OWN ROWS.** `%bound-covering` answers *the last item
       ;; that starts at or before this line*, which is right for the anchor (a window's top row belongs
       ;; to the item it is in) and WRONG for a click: every line past the walk would resolve to the last
       ;; item, and a click into the empty space below a short conversation would open a change from a row
       ;; nobody can see — the defect this router's own docstring is written against. So the bound's END
       ;; is the other half of the test.
       (when (and (integerp row) (> row 0))
         (let* ((line (+ *view-start* (1- row)))
                (bound (%bound-covering line))
                (item (and bound (< line (third bound))
                           (find (first bound) (session-items (head-session head))
                                 :key #'item-id :test #'string=))))
           (when (and item (item-shows-an-edit-p item))
             (%show-edit-change head item))
           ;; **AND A NOTICE ROW OPENS ITS WHOLE TEXT** (letibot `161b34d`/`f076792`, the sweep's batch
           ;; A): the row carries the target and the reason, or the branch and the verdict, and the
           ;; paragraph it came from is what the click is FOR. Asked of the item the click resolved to,
           ;; so nothing has to remember where the ready-made row came from.
           (when (and item (ignore-errors (%notice-kind (item-display-text item))))
             (%show-notice head item))))
       t))))

