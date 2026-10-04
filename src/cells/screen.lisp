;;;; screen — the cell buffer
;;;;
;;;; Split out of `cells.lisp`, which was one 556-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------------------- screen ;;;

(defstruct (cell (:constructor %cell (ch style))
                 (:predicate nil)
                 (:copier nil))
  (ch #\space :type character)
  (style 0 :type fixnum))

(defstruct (screen (:constructor %make-screen)
                   (:copier nil))
  (cols 0 :type fixnum)
  (rows 0 :type fixnum)
  (cells #() :type simple-vector))

(defun make-screen (cols rows)
  (%make-screen :cols cols :rows rows
                :cells (make-array (* cols rows)
                                   :initial-element (%cell #\space 0))))

(defun screen-resize (screen cols rows)
  "Fresh blank buffer at the new size. The caller repaints full after a
resize; carrying cells over buys nothing a full paint does not."
  (setf (screen-cols screen) cols
        (screen-rows screen) rows
        (screen-cells screen) (make-array (* cols rows)
                                          :initial-element (%cell #\space 0)))
  screen)

(defun screen-clear (screen &optional (style 0))
  (fill (screen-cells screen) (%cell #\space style))
  screen)

(declaim (inline %index))
(defun %index (screen row col)
  (declare (type screen screen) (type fixnum row col))
  (the fixnum (+ (the fixnum (* row (screen-cols screen))) col)))

(defun screen-put (screen row col ch &optional (style 0))
  "One cell, bounds-checked. Out-of-range writes are dropped, not errors: a
render function that overshoots by one column should not take the head down.

Typed, at DEFAULT safety, deliberately: this is a contract function
(HACKING.md) that an eval off the socket may call with anything, and the checks
it keeps — a struct tag, two fixnum tags, a character tag and one bounds check on
the vector — are each one instruction. What the declarations buy is the fixnum
arithmetic and the direct `simple-vector` store. Measured: 1.1M calls in 300
frames, 1.9% of the frame before, under the noise floor after."
  (declare (type screen screen) (type fixnum row col style) (type character ch))
  (when (and (<= 0 row (1- (screen-rows screen)))
             (<= 0 col (1- (screen-cols screen))))
    (setf (svref (screen-cells screen) (%index screen row col))
          (%cell ch style)))
  screen)

(defun screen-cell (screen row col)
  (declare (type screen screen) (type fixnum row col))
  (svref (screen-cells screen) (%index screen row col)))

(defun screen-put-string (screen row col string &optional (style 0))
  "Write STRING at row,col; returns the column after the last written cell.

**Walks CLUSTERS, not characters.** A ZWJ emoji sequence or a flag is one glyph
of two columns, so placing it per CHARACTER writes six cells for something the
terminal draws in two — and since the border arithmetic measures with
`string-width` (cluster-aware), the two would disagree and the border would land
inside the text. Measurement and placement have to count the same thing or fixing
one just moves the defect.

The cluster's FIRST character goes in the first cell and the second cell is the
continuation marker. **The rest of the cluster's code points are not written**, so
a ZWJ sequence renders as its first component rather than as the joined glyph —
`👨‍👩‍👧` shows a man, at the right width, where it used to show three people
stitched into six columns. The exact glyph needs a cell that holds a STRING, and
that is a struct change (a restart); it is recorded in TODO.md rather than
half-done here.

A wide cluster that does not fit degrades to a space rather than wrapping.

**The plain case is placed without clusters.** When every character of STRING is
one plain column (`plain-columns-p`: no escape, nothing wide, nothing zero-width)
no character can join, pair or extend its neighbour, so the cluster walk reduces
to one cell per character — and that is what is done, with no consing. Measured:
463 calls a frame, 20% of the frame through `clusters`; the fast path is what the
prose, the borders and the box glyphs all take. Anything else still walks
clusters, so the two paths agree by construction of `plain-columns-p`."
  (declare (type screen screen) (type fixnum row col style) (type (or null string) string))
  (let ((c col) (cols (screen-cols screen)))
    (declare (type fixnum c cols))
    (if (plain-columns-p string)
        (let ((s (%simple string)))
          (declare (type simple-string s))
          (loop for i of-type fixnum from 0 below (length s)
                do (screen-put screen row c (schar s i) style)
                   (incf c)))
        (dolist (cl (clusters string))
          (let ((w (cluster-cols cl))
                (text (cluster-text cl)))
            (cond
              ((or (zerop w) (zerop (length text)))
               ;; an escape-only cell, or a zero-width cluster with nothing to draw
               nil)
              ((= w 2)
               (if (< (1+ c) cols)
                   (progn (screen-put screen row c (char text 0) style)
                          (screen-put screen row (1+ c) +wide-cont+ style)
                          (incf c 2))
                   (progn (screen-put screen row c #\space style)
                          (incf c))))
              (t (screen-put screen row c (char text 0) style)
                 (incf c))))))
    c))

