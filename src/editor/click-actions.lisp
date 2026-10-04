;;;; click-actions — what a click on a row does, per pane
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

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
         ;; the card's first line is its title; the choices follow, one a row
         (sel (- row (%pick-card-top head) 1)))
    (when (and (plusp n) (<= 0 sel) (< sel n))
      (setf (head-picker-sel head) sel (head-dirty head) t))
    t))

(defun %click (head key)
  "A CLICK selects the row under the pointer. T when the click was a list's.

Before the text keys, because a click is unambiguous about what it means and
there is nothing else to weigh it against. Guarded by the rows the frame actually
DREW — a click into the space below a short list must not select a row nobody can
see, which is why the pane records its room and offset from the last paint rather
than from the click."
  (let ((row (getf key :y)))
    (cond
      (*pick-open* (%pick-click head row))
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

