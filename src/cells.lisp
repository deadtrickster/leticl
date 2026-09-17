;;;; cells.lisp — the cell buffer and the ANSI diff painter.
;;;;
;;;; A screen is a flat vector of cells; a cell is a character plus an interned
;;;; style index. The painter compares the previous frame against the current
;;;; one and emits absolute cursor moves for changed runs only, wrapped in
;;;; synchronized output (?2026) so a burst of deltas never shows a half frame.
;;;; Every drawing decision stays a plain function here — that is what makes
;;;; the live-hack property real (PLAN.md §1).

(in-package #:leticl)

(defparameter +wide-cont+ (code-char 0)
  "Marks the second half of a double-width character. Never written to the
terminal: the wide char before it advances the cursor over both columns.")

;;; ---------------------------------------------------------------- styles ;;;

(defparameter *styles* (make-array 8 :adjustable t :fill-pointer 1 :initial-element nil)
  "Interned style specs. Index 0 is always the default (empty) style.")

(defparameter *style-sgrs*
  (make-array 8 :adjustable t :fill-pointer 1
              :initial-element (format nil "~C[0m" (code-char 27)))
  "Cached SGR sequences, parallel to *styles*. Index 0 is the plain reset —
initialized here, because a default-style cell must never read whatever
make-array leaves in unallocated slots.")

(defparameter *color-names*
  '(:black :red :green :yellow :blue :magenta :cyan :white
    :bright-black :bright-red :bright-green :bright-yellow
    :bright-blue :bright-magenta :bright-cyan :bright-white))

(defun %color-sgr (color backgroundp)
  "SGR parameter string for one color: named 0-15, 256-index, or (r g b)."
  (let ((base (if backgroundp 40 30)))
    (typecase color
      (keyword
       (let ((n (position color *color-names*)))
         (unless n (error "unknown color name ~s" color))
         (if (< n 8) (format nil "~d" (+ base n))
             (format nil "~d" (+ base 60 (- n 8))))))
      (integer
       (unless (<= 0 color 255) (error "color index out of range: ~d" color))
       (format nil "~d;5;~d" (+ base 8) color))
      (cons
       (destructuring-bind (r g b) color
         (format nil "~d;2;~d;~d;~d" (+ base 8) r g b)))
      (t (error "bad color ~s" color)))))

(defun %style-sgr (spec)
  "The SGR sequence that switches from default to SPEC. Always begins with
ESC[0m: styles compose by full reset, because the painter only ever switches
between interned styles and never layers them."
  (with-output-to-string (s)
    (write-string (format nil "~C[0" +esc+) s)
    (loop for (k v) on spec by #'cddr
          do (case k
               (:bold (when v (write-string ";1" s)))
               (:dim (when v (write-string ";2" s)))
               (:italic (when v (write-string ";3" s)))
               (:underline (when v (write-string ";4" s)))
               (:reverse (when v (write-string ";7" s)))
               (:strikethrough (when v (write-string ";9" s)))
               (:fg (format s ";~a" (%color-sgr v nil)))
               (:bg (format s ";~a" (%color-sgr v t)))
               (t (error "unknown style key ~s" k))))
    (write-char #\m s)))

(defun style-index (spec)
  "Intern a style spec plist (:fg :cyan :bold t …) into a small integer.
Index 0 is the default; EQUAL is the identity of a spec."
  (if (null spec)
      0
      (or (position spec *styles* :test #'equal)
          (progn
            (vector-push-extend spec *styles*)
            (vector-push-extend (%style-sgr spec) *style-sgrs*)
            (1- (length *styles*))))))

(defun %sgr (index)
  (aref *style-sgrs* index))

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

(defun %index (screen row col)
  (+ (* row (screen-cols screen)) col))

(defun screen-put (screen row col ch &optional (style 0))
  "One cell, bounds-checked. Out-of-range writes are dropped, not errors: a
render function that overshoots by one column should not take the head down."
  (when (and (<= 0 row (1- (screen-rows screen)))
             (<= 0 col (1- (screen-cols screen))))
    (setf (aref (screen-cells screen) (%index screen row col))
          (%cell ch style)))
  screen)

(defun screen-cell (screen row col)
  (aref (screen-cells screen) (%index screen row col)))

(defun screen-put-string (screen row col string &optional (style 0))
  "Write STRING at row,col; returns the column after the last written cell.
Zero-width characters (combining marks, joiners) are skipped for now — the
cluster-aware renderer will attach them properly at T19/T20. A wide character
that does not fit degrades to a space rather than wrapping the line."
  (let ((c col) (cols (screen-cols screen)))
    (map nil (lambda (ch)
               (let ((w (char-width ch)))
                 (cond ((zerop w))                       ; combining/control: skip
                       ((and (= w 2) (< (1+ c) cols))
                        (screen-put screen row c ch style)
                        (screen-put screen row (1+ c) +wide-cont+ style)
                        (incf c 2))
                       ((= w 2)                          ; does not fit
                        (screen-put screen row c #\space style)
                        (incf c))
                       (t
                        (screen-put screen row c ch style)
                        (incf c)))))
         string)
    c))

;;; ---------------------------------------------------------------- paint ;;;

(defun %cell= (a b)
  (and (char= (cell-ch a) (cell-ch b))
       (= (cell-style a) (cell-style b))))

(defun paint-diff (prev cur out &key (sync t))
  "Emit the escape sequence that turns the terminal showing PREV into the
terminal showing CUR. PREV nil paints everything. Both screens must have the
same shape. Runs of changed cells are written behind one absolute cursor move;
styles are tracked across the whole frame so SGR is emitted only on change."
  (when prev
    (assert (and (= (screen-cols prev) (screen-cols cur))
                 (= (screen-rows prev) (screen-rows cur)))
            (prev cur) "paint-diff screens must have the same shape"))
  (let ((cols (screen-cols cur))
        (rows (screen-rows cur))
        ;; Every paint ends with a reset, so every paint begins at default
        ;; style — SGR for style 0 is never needed mid-frame.
        (last-style 0))
    (when sync (sync-begin out))
    (dotimes (r rows)
      (let ((c 0))
        (loop while (< c cols)
              for i = (+ (* r cols) c)
              for cell = (aref (screen-cells cur) i)
              for pcell = (if prev
                              (aref (screen-cells prev) i)
                              ;; paint-full has just cleared: a default cell
                              ;; needs no writing, so that is the sentinel
                              (%cell #\space 0))
              do (if (%cell= pcell cell)
                     (incf c)
                     (progn
                       ;; start of a changed run: move there, write until it ends
                       (format out "~C[~D;~DH" +esc+ (1+ r) (1+ c))
                       (loop while (< c cols)
                             for j = (+ (* r cols) c)
                             for cc = (aref (screen-cells cur) j)
                             for pp = (if prev
                                          (aref (screen-cells prev) j)
                                          (%cell #\space 0))
                             while (not (%cell= pp cc))
                             do (cond
                                  ((char= (cell-ch cc) +wide-cont+)
                                   ;; covered by the wide char before it
                                   (incf c))
                                  (t
                                   (when (/= (cell-style cc) last-style)
                                     (write-string (%sgr (cell-style cc)) out)
                                     (setf last-style (cell-style cc)))
                                   (if (and (= 2 (char-width (cell-ch cc)))
                                            (= c (1- cols)))
                                       ;; a wide char on the last column would
                                       ;; wrap; the buffer never holds one there
                                       ;; (screen-put-string degrades it), but a
                                       ;; direct screen-put could — guard anyway
                                       (progn (write-char #\space out) (incf c))
                                       (progn (write-char (cell-ch cc) out)
                                              (incf c (max 1 (char-width (cell-ch cc))))))))))))))
    (write-string (format nil "~C[0m" +esc+) out)
    (when sync (sync-end out))
    (force-output out)))

(defun paint-full (cur out)
  "Clear and paint everything — after a resize, on attach, on resync."
  (write-string (format nil "~C[2J" +esc+) out)
  (paint-diff nil cur out))

(defun move-to (out row col)
  (format out "~C[~D;~DH" +esc+ (1+ row) (1+ col)))
