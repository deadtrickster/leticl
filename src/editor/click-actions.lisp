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

Recomputed from the layout rather than read off the last paint, because the
render records where a PANE landed (`*pane-room*`, `*pane-scroll*`) and nothing
records where a CARD did. The arithmetic is `%render`'s own, bottom up: the hint
bar is the last row, the composer box sits on it, and the card sits on the box
(render.lisp:306-312, 396-398). A `*card-top*` set by the render would be the
honest version of this and belongs to that file."
  (let* ((cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
         (composer-rows (length (composer-line head cols)))
         (card-rows (length (pick-card-lines head cols))))
    (- (head-rows head) 1 composer-rows card-rows)))

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
      ((member (head-mode head) '(:picker :jobs :subagents :todos :config))
       ;; the pane starts at screen row 1 (row 0 is the top border), and the
       ;; offset says how many pane LINES are hidden above it
       (let ((line (+ *pane-scroll* (- row 1))))
         (when (and (>= line 0) (< line (+ *pane-scroll* *pane-room*)) (< line *pane-lines*))
           ;; the cursor counts ROWS and the click found a LINE; the panes that
           ;; own a cursor report where their first row sits, so walk back
           (let ((sel (click-row->sel head (head-mode head) line)))
             (when sel
               (setf (head-picker-sel head) sel
                     (head-dirty head) t)))))
       t)
      (t nil))))

