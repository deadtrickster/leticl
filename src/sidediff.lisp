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
;;;;    renderer's three-glyph bar already set.
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

(in-package #:leticl)

(defparameter +split-sep+ " │ " "Between the panels, and the air either side.")
(defparameter +split-sep-width+ 3 "Columns `+split-sep+` occupies.")
(defparameter +split-min-body+ 8
  "A panel body narrower than this cannot show code and its gutter at once. The
renderer DEGRADES rather than refusing: a caller should not have to guess whether
the panels will fit, and a cramped diff beats no diff.")

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
;;; Each half is `gutter sign code`, and the two halves are joined by the
;;; separator. A half that is longer than its panel is TRUNCATED rather than
;;; wrapped: a wrap would push the pair apart and the eye would read the wrap
;;; instead of the change. The unified view has the room to wrap; two panels do
;;; not, which is the cost of the shape and worth naming.

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

(defun %half-text (half panelw numw start lines)
  "One half as a string: gutter, sign, then the code cut to its panel.

A blank half keeps its FULL width, gutter included, or the separator would move
between rows and the two panels would stop lining up."
  (if half
      (let ((line (split-half-line half))
            ;; gutter + sign + body = panelw exactly: `- numw 1`, not `- numw 2`.
            ;; One column short per half is two short per row, which is a row that
            ;; does not line up with the frame it is drawn in.
            (body (max 1 (- panelw numw 1))))
        (concatenate 'string
                     (%gutter line numw start)
                     (string (split-half-sign half))
                     ;; the line's TEXT comes from the table `render-split`
                     ;; filled, keyed by the number the DIFF produced
                     (fit-to-width (or (gethash line lines) "") body)))
      (make-string panelw :initial-element #\space)))

(defun %lines-of (text)
  "TEXT as a list of lines; an empty side is NO lines rather than one blank one."
  (if (zerop (length text)) nil (uiop:split-string text :separator '(#\newline))))

(defvar *split-old* (make-hash-table)
  "Index → text for the LEFT panel. A defvar because a push must not reset it,
and a defvar rather than a head slot because a slot is a restart.")
(defvar *split-new* (make-hash-table)
  "Index → text for the RIGHT panel.

**Two tables, not one.** The first version had one, keyed by index, filled from
BOTH sides — so the new text overwrote the old at every index and both panels drew
the after-side. A diff that shows the same line on both sides looks like a
correctly aligned row and is the one thing it must not be.")

(defun render-split (old new &key (width 100) (context 3) (max-rows 60)
                                 (old-start 1) (new-start 1) (line-numbers t))
  "The two-panel view of OLD → NEW, as segment lines.

`width` is the FULL row; the panels split it. Returns one segment-line per
terminal row, so the caller places them like any other."
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
                   0)))
    (if (< (- panelw numw 1) +split-min-body+)
        ;; DEGRADE, do not refuse: a cramped diff beats no diff, and a caller
        ;; should not have to ask whether the panels fit
        (list (list (cons (format nil "~a-column pane is too narrow for two panels; /diff unified"
                                  width)
                          '(:fg :yellow))))
        (let ((*split-old* (make-hash-table :test #'eql))
              (*split-new* (make-hash-table :test #'eql))
              (d (diff-lines old new))
              (out nil))
          ;; the line text, keyed by the number the diff will hand back
          ;; keyed by the 0-based index the DIFF hands back (see `%gutter`),
          ;; one table per side
          (loop for i from 0 below (length old)
                do (setf (gethash i *split-old*) (aref old i)))
          (loop for i from 0 below (length new)
                do (setf (gethash i *split-new*) (aref new i)))
          (let ((rows-left max-rows)
                (dropped 0))
            (dolist (h (hunks d context))
              (dolist (p (%split-pairs (getf h :rows)))
                (if (zerop rows-left)
                    (incf dropped)
                    (progn
                      (decf rows-left)
                      (let ((l (%half-text (split-pair-left p) panelw numw
                                           old-start *split-old*))
                            (r (%half-text (split-pair-right p) rpanelw numw
                                           new-start *split-new*)))
                        (push (list (cons l '(:fg :bright-white))
                                    (cons +split-sep+ '(:dim t))
                                    (cons r '(:fg :bright-white)))
                              out))))))
            (when (plusp dropped)
              (push (list (cons (format nil "… ~a more diff rows not shown" dropped)
                                '(:dim t)))
                    out))
            (nreverse out))))))

(defun edit-split-lines (edit cols)
  "The two-panel diff of an EDIT (a `ToolEditExcerpt` plist), or NIL.

The view the operator asked for twice: the same evidence the unified card carries,
drawn side by side. `:before-start`/`:after-start` are 1-based lines of the WHOLE
file, so the gutters number the file and not the excerpt."
  (when edit
    (render-split (%lines-of (or (getf edit :before) ""))
                  (%lines-of (or (getf edit :after) ""))
                  :width (max 20 (- cols 4))
                  :context 3
                  :line-numbers t
                  :max-rows 60
                  :old-start (or (getf edit :before-start) 1)
                  :new-start (or (getf edit :after-start) 1))))
