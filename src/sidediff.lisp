;;;; sidediff.lisp — the two-panel file-edit diff: before on the left, after on
;;;; the right.
;;;;
;;;; Ported from crates/ui/src/sidediff.rs. The shape is opencode's diff viewer
;;;; (MIT) as the reference's own header records, with two deliberate departures:
;;;;
;;;;  · opencode distinguishes added from removed by BACKGROUND TINTS. A head
;;;;    that must survive a terminal with no colour cannot spend the diff on
;;;;    backgrounds, so the SIGN COLUMN alone carries the distinction — a glyph,
;;;;    not a colour — and the code keeps its syntax colours in both panels. The
;;;;    information survives a pipe to a file, which is the same bar the unified
;;;;    renderer's three-glyph bar already set. The operator's trial then put the
;;;;    tint ON TOP of the glyph for terminals that do have colour: a row is
;;;;    drawn inside its own role to the panel's edge, and the glyph is still the
;;;;    whole of the distinction when there is no palette at all.
;;;;  · opencode picks split-or-unified from the pane's WIDTH. Here it is the
;;;;    operator's own toggle and nothing else: a narrow pane gets a narrow
;;;;    split rather than no diff, because an edit drawn cramped is still an
;;;;    edit they can read, and an edit not drawn is one they approved blind.
;;;;
;;;; The panels are aligned by DIFFING THE EXCERPTS AGAIN rather than by
;;;; remembering which line went where — `diff.lisp` owns the only edit script
;;;; in this process, and a second, worse one here is how two answers to one
;;;; question start disagreeing.
;;;;
;;;; Everything here is a pure function of its inputs: no clock, no filesystem,
;;;; no terminal.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defparameter +split-sep+ " │ " "Between the panels, and the air either side.")
(defparameter +split-sep-width+ 3 "Columns `+split-sep+` occupies.")
(defparameter +split-min-body+ 8
  "A panel body narrower than this cannot show code and its gutter at once. The
renderer DEGRADES rather than refusing: a caller should not have to guess whether
the panels will fit, and a cramped diff beats no diff.

A FLOOR, not a gate — `sidediff.rs:168,471-477`. It was read here as a gate for
one version: below it the renderer answered one yellow row saying the pane was
too narrow and drew no diff at all, which is the behaviour this file's own header
promises it does not have, and which is how an operator ends up approving an edit
they never saw.")

;;; ------------------------------------------------------------- pairing ;;;
;;;
;;; One terminal row is a ROW. A row is either a context pair (one line from
;;; each side) or one half of a change — and a CHANGE RUN pairs the k-th removal
;;; with the k-th addition, so a rewritten line sits beside the line it replaced
;;; rather than above it.

;; Named `split-half`/`split-pair` rather than `half`/`pair`: this is one package,
;; and two of the shortest words in it are not worth spending on internals.
(defstruct (split-half (:constructor make-split-half))
  (line nil)
  (sign #\space :type character)
  (role :plain :type symbol))

(defstruct (split-pair (:constructor make-split-pair))
  (left nil)
  (right nil))

(defun %split-pairs (rows)
  "Hunk ROWS to PAIRs: the alignment the two panels are drawn from.

A run of removals and additions is paired POSITIONALLY — the k-th removal with
the k-th addition — which is what puts a rewritten line beside the line it
replaced. When the sides are unequal the longer one gets lone halves, and the
other panel is blank on those rows: a deletion has nothing on the right and an
insertion has nothing on the left, and saying so is the whole of what the row is
for."
  (let ((out nil)
        (rows (coerce rows 'vector))
        (n (length rows))
        (i 0))
    (loop while (< i n) do
      (if (eq (first (aref rows i)) :context)
          (progn
            (push (make-split-pair :left (make-split-half :line (second (aref rows i))
                                             :sign #\space :role :plain)
                             :right (make-split-half :line (third (aref rows i))
                                               :sign #\space :role :plain))
                  out)
            (incf i))
          (let ((removed nil) (added nil))
            (loop while (and (< i n)
                             (member (first (aref rows i)) '(:removed :added)))
                  do (if (eq (first (aref rows i)) :removed)
                         (push (second (aref rows i)) removed)
                         (push (second (aref rows i)) added))
                     (incf i))
            (setf removed (nreverse removed) added (nreverse added))
            (loop for k from 0 below (max (length removed) (length added))
                  do (push (make-split-pair
                            :left (when (< k (length removed))
                                    (make-split-half :line (nth k removed)
                                               :sign #\- :role :removed))
                            :right (when (< k (length added))
                                     (make-split-half :line (nth k added)
                                                :sign #\+ :role :added)))
                           out)))))
    (nreverse out)))

;;; -------------------------------------------------------------- drawing ;;;
;;;
;;; Each half is `number space sign space code`, laid out exactly as
;;; `sidediff.rs:167,363` lays it out: the gutter a cell carries before its code
;;; is `numw + 3`, or two columns (sign, space) when line numbers are off. This
;;; file used to spend `numw + 1`, running the code hard against the sign on both
;;; sides of the separator — two columns of difference per row against the
;;; reference, and a `+x` that reads as one token.
;;;
;;; A half longer than its panel WRAPS inside its own column and blanks the
;;; other (`sidediff.rs:270-287,308-326`); a pair therefore emits
;;; `max(left-rows, right-rows)` rows and is charged to the budget whole.
;;; Truncating was the previous answer here, and `diff.rs:336-341` names hiding
;;; the changed tail of a line as "the one thing a diff must not do".

(defun %gutter (line width start)
  "LINE right-justified in WIDTH columns, or WIDTH spaces when there is no line
on this side — a blank half must keep its gutter empty rather than shorten it,
or the panels stop lining up.

LINE is the diff's 0-based index into the EXCERPT and START is the 1-based line
of the whole file that excerpt begins at, so the number PRINTED is the file's.
Conflating the two is what made the first version draw a panel of spaces: the
text was filed under one numbering and looked up under the other."
  (if line
      (let ((s (format nil "~d" (+ start line))))
        (if (< (length s) width)
            (concatenate 'string (make-string (- width (length s)) :initial-element #\space) s)
            s))
      (make-string width :initial-element #\space)))

(defun %panel-body-width (panelw numw line-numbers)
  "The columns a cell has left for CODE, after its gutter.

`Geometry::of` (`sidediff.rs:154-170`): `numw + 3` with line numbers, 2
without, and the remainder floored at `+split-min-body+` — a FLOOR, which is
what makes a narrow pane a narrow split instead of no diff. At that floor the
cell is wider than its panel and the row runs past the frame, which is the
degradation the file header promises and which the refusal it replaced was not."
  (max +split-min-body+
       (- panelw (if line-numbers (+ numw 3) 2))))

(defun %segs-width-of (segs)
  "Display width of a list of (TEXT . STYLE) segments."
  (reduce #'+ segs :key (lambda (seg) (string-width (car seg))) :initial-value 0))

(defun %split-pad (segs width style)
  "SEGS padded on the right to WIDTH columns, the padding carrying STYLE.

The padding is INSIDE the row's own style — `sidediff.rs:365-370`'s \"pad inside
the tint\" — so an added line is green to the panel's edge and not merely as far
as its text happens to reach. A cell already at or past WIDTH is handed back
unpadded: `pad_to` never truncates, and at the `+split-min-body+` floor there is
nothing to truncate it to."
  (let ((w (%segs-width-of segs)))
    (if (>= w width)
        segs
        (append segs (list (cons (make-string (- width w) :initial-element #\space)
                                 style))))))

(defun %blank-cell (width)
  "One blank row of a panel's full width — an absent half, or a side that ran
out of wrap rows while the other had more. A repeat of the last line would read
as content that is there twice (`sidediff.rs:277-279`)."
  (list (cons (make-string width :initial-element #\space) nil)))

(defun %half-lines (half panelw numw start lines classes line-numbers)
  "One side of a pair as a list of segment lines — one per terminal row.

`side_lines` (`sidediff.rs:310-372`). An absent half is ONE blank row of the
full panel width, so the opposite side's wrap still has somewhere to go and the
separator does not move between rows.

The whole cell is drawn inside the line's own role: gutter, sign, code and the
padding to the panel edge all carry the background (`48;5;22` added, `48;5;52`
removed, the same two the unified renderer already spends), the sign keeps the
green or red FOREGROUND it always had, and the line number takes the row's
foreground on a changed row while staying dim on a context row. Before this the
whole cell was one flat `:fg :bright-white` segment on every row, which is the
one thing that is neither the tint nor the glyph. Under no colour at all the
glyph in the sign column is still the whole of the distinction, which is this
file's first departure from opencode.

A continuation row keeps the panel and loses its number and its sign, exactly as
`diff.lisp`'s continuation loses its sign. Its blank gutter is `numw + 1` columns
and then the sign's two; the reference spends `numw + 1` on a continuation even
when line numbers are OFF, where its first row spends none, so its continuations
sit one column right of the row they continue. That is a bug, not a decision, and
is not ported."
  (if (null half)
      (list (%blank-cell panelw))
      (let* ((idx (split-half-line half))
             (text (or (gethash idx lines) ""))
             (cls (when (and classes (< idx (length classes))) (aref classes idx)))
             (role (split-half-role half))
             (tinted (not (eq role :plain)))
             (base (case role
                     (:added +diff-added-bg+)
                     (:removed +diff-removed-bg+)
                     (t nil)))
             (fg (case role (:added '(:fg :green)) (:removed '(:fg :red)) (t nil)))
             (body-w (%panel-body-width panelw numw line-numbers))
             (wrapped (or (wrap-segments (classed-segments text cls base) body-w)
                          ;; an empty line is still a line: it takes a row, with
                          ;; its number (`sidediff.rs:322-325`)
                          (list (list (cons "" base))))))
        (loop for body in wrapped
              for k from 0
              collect
              (let* ((gutter
                       (cond ((not line-numbers) nil)
                             ((plusp k)
                              (list (cons (make-string (1+ numw) :initial-element #\space)
                                          (if tinted base '(:dim t)))))
                             (t
                              (list (cons (format nil "~a " (%gutter idx numw start))
                                          (if tinted (append fg base) '(:dim t)))))))
                     (sign (if (plusp k)
                               (list (cons "  " base))
                               (list (cons (string (split-half-sign half))
                                           (if fg (append fg base) base))
                                     (cons " " base)))))
                (%split-pad (append gutter sign body) panelw base))))))

(defun %lines-of (text)
  "TEXT as a list of lines; an empty side is NO lines rather than one blank one.

`str::lines()` (`sidediff.rs:451-452`) does NOT yield a final empty line for a
text ending in a newline, and `uiop:split-string` does — which put a phantom
blank row, signed and numbered, at the foot of every diff whose side ended in a
newline, claiming a line that is not in the file. Exactly ONE trailing empty is
dropped, so a side that really does end in a blank line still shows it."
  (if (zerop (length text))
      nil
      (let ((ls (uiop:split-string text :separator '(#\newline))))
        (if (string= "" (car (last ls)))
            (butlast ls)
            ls))))

(defvar *split-old* (make-hash-table)
  "Index → text for the LEFT panel. A defvar because a push must not reset it,
and a defvar rather than a head slot because a slot is a restart.")
(defvar *split-new* (make-hash-table)
  "Index → text for the RIGHT panel.

**Two tables, not one.** The first version had one, keyed by index, filled from
BOTH sides — so the new text overwrote the old at every index and both panels drew
the after-side. A diff that shows the same line on both sides looks like a
correctly aligned row and is the one thing it must not be.")

(defun %split-hunk-header (h old-start new-start)
  "The `@@ -o,co +n,cn @@` row, faint (`hunk_header`, `sidediff.rs:173-194`).

The split view had none at all, so a multi-hunk edit ran its hunks together with
nothing between them and the second hunk read as a continuation of the first. The
counts and the arithmetic are the unified renderer's, because it is the same
hunk."
  (let ((count-old (count-if (lambda (r) (member (first r) '(:context :removed)))
                             (getf h :rows)))
        (count-new (count-if (lambda (r) (member (first r) '(:context :added)))
                             (getf h :rows))))
    (list (cons (format nil "@@ -~a,~a +~a,~a @@"
                        (+ old-start (getf h :old-start)) count-old
                        (+ new-start (getf h :new-start)) count-new)
                '(:dim t)))))

(defun render-split (old new &key (width 100) (context 3) (max-rows 60)
                                 (old-start 1) (new-start 1) (line-numbers t)
                                 (lang 0))
  "The two-panel view of OLD → NEW, as segment lines.

`width` is the FULL row; the panels split it. Returns one segment-line per
terminal row, so the caller places them like any other. LANG is the highlighter's
language id for the edited file (0 = none), and it is what makes the code in both
panels syntax-coloured: the shim, `class-rows` and `role-style` were all here and
only the path in was missing.

Follows `render_split` (`sidediff.rs:88-141`) row for row: `no change` when the
two sides agree, the degraded banner when Myers gave up, a hunk header between
hunks charged against the budget, and a budget counted in TERMINAL rows that
drops a wrapped pair WHOLE rather than leaving half of it — half a pair is an
aligned row with one panel missing, which reads as a deletion or an insertion
that never happened."
  (let* ((old (coerce old 'vector))
         (new (coerce new 'vector))
         ;; the LEFT panel takes the floor and the RIGHT takes the remainder, so
         ;; the row is EXACTLY `width` — one column short is a row that does not
         ;; line up with the frame it is drawn in
         (panelw (floor (- width +split-sep-width+) 2))
         (rpanelw (- width +split-sep-width+ panelw))
         (numw (if line-numbers
                   (length (format nil "~d" (max 1 (+ old-start (length old))
                                                 (+ new-start (length new)))))
                   0))
         (d (diff-lines old new))
         (hs (hunks d context)))
    (if (null hs)
        ;; the same row, in the same words, the unified renderer answers with
        (list (list (cons "no change" '(:dim t))))
        (let ((*split-old* (make-hash-table :test #'eql))
              (*split-new* (make-hash-table :test #'eql))
              (old-classes (class-rows old lang))
              (new-classes (class-rows new lang))
              (out (when (diff-degraded d)
                     (list (list (cons
                                  "! diff gave up on the minimal edit script; the changed region is shown as a whole replacement"
                                  '(:bold t :fg :yellow)))))))
          ;; the line text, keyed by the 0-based index the DIFF hands back
          ;; (see `%gutter`), one table per side
          (loop for i from 0 below (length old)
                do (setf (gethash i *split-old*) (aref old i)))
          (loop for i from 0 below (length new)
                do (setf (gethash i *split-new*) (aref new i)))
          (let ((rows-left max-rows)
                (dropped 0)
                (rows nil))
            (loop for h in hs
                  for hi from 0
                  do (when (or (plusp hi) (> (length hs) 1))
                       (if (zerop rows-left)
                           (incf dropped)
                           (progn
                             (decf rows-left)
                             (push (%split-hunk-header h old-start new-start) rows))))
                     (dolist (p (%split-pairs (getf h :rows)))
                       (let* ((l (%half-lines (split-pair-left p) panelw numw
                                              old-start *split-old* old-classes
                                              line-numbers))
                              (r (%half-lines (split-pair-right p) rpanelw numw
                                              new-start *split-new* new-classes
                                              line-numbers))
                              (n (max (length l) (length r))))
                         (if (>= rows-left n)
                             (progn
                               (decf rows-left n)
                               (loop for k from 0 below n
                                     do (push (append (or (nth k l) (%blank-cell panelw))
                                                      (list (cons +split-sep+ '(:dim t)))
                                                      (or (nth k r) (%blank-cell rpanelw)))
                                              rows)))
                             (progn
                               (incf dropped n)
                               (setf rows-left 0))))))
            (setf out (append out (nreverse rows)))
            (when (plusp dropped)
              (setf out (append out
                                (list (list (cons (format nil "… ~a more diff lines not shown"
                                                          dropped)
                                                  '(:dim t)))))))
            out)))))

(defun edit-split-lines (edit cols)
  "The two-panel diff of an EDIT (a `ToolEditExcerpt` plist), or NIL.

The view the operator asked for twice: the same evidence the unified card carries,
drawn side by side. `:before-start`/`:after-start` are 1-based lines of the WHOLE
file, so the gutters number the file and not the excerpt.

`:path` is carried through to `lang-for` here. `render_edit`
(`sidediff.rs:443-460`) passes `lang_for(path)` into the render, and this dropped
the path on the floor — which is the whole reason the split panels were flat
while the fences beside them were coloured. A path nobody has a grammar for
answers 0 and both panels render plain, which is what a terminal with no palette
reads anyway."
  (when edit
    (render-split (%lines-of (or (getf edit :before) ""))
                  (%lines-of (or (getf edit :after) ""))
                  :width (max 20 (- cols 4))
                  :context 3
                  :line-numbers t
                  :max-rows 60
                  :lang (lang-for (or (getf edit :path) ""))
                  :old-start (or (getf edit :before-start) 1)
                  :new-start (or (getf edit :after-start) 1))))
