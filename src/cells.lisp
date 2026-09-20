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

;; The style intern table is LIVE state: cells hold indices into it, so a
;; redefinition that reset it would repaint the whole screen with wrong colours
;; (measured: a live push of this file did exactly that). defvar assigns only
;; when unbound, so a push leaves a running head's table — and its indices —
;; alone.
(defvar *styles* (make-array 8 :adjustable t :fill-pointer 1 :initial-element nil)
  "Interned style specs. Index 0 is always the default (empty) style.")

;; *style-sgrs* is LIVE state for the same reason *styles* is, and it is
;; PARALLEL to it: index N of one describes index N of the other. A push that
;; reset only this one left the two out of step — cells held style indices the
;; SGR table had no entry for, and the next paint died with "Invalid index 8 for
;; (VECTOR T 8)". That is the same defect class as *styles*, missed because the
;; table looked like static data and its twin did not.
(defvar *style-sgrs*
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

(defun rebuild-style-sgrs ()
  "Recompute the SGR cache from the style SPECS, restoring parallelism.

The two tables are parallel by construction — index N of `*style-sgrs*` is the
SGR for index N of `*styles*` — so one can always be rebuilt from the other, and
`*styles*` is the source of truth because it holds the specs.

This exists because the pairing BROKE in a way the old code could not survive: a
live push reset one table and not the other, cells kept style indices the SGR
cache had no entry for, and the next paint died with \"Invalid index 8 for
(VECTOR T 8)\". Both tables are `defvar` now so a push cannot do that again, but
a head already carrying the desync can be repaired in place rather than
restarted — which is the whole point of a head that can be patched while it
runs. Idempotent, so calling it on a healthy head is a no-op in effect."
  (let ((specs (coerce *styles* 'vector)))
    (setf *style-sgrs*
          (make-array (max 8 (length specs)) :adjustable t :fill-pointer 0))
    (loop for spec across specs
          do (vector-push-extend (%style-sgr spec) *style-sgrs*))
    *style-sgrs*))

(defparameter *style-key-order*
  '(:bold :dim :italic :underline :reverse :strikethrough :fg :bg)
  "The one order a style spec's keys are written in, for `%canonical-style`.

The order `%style-sgr` already emits in, so a canonical spec reads the way its
escape does.")

(defun %canonical-style (spec)
  "SPEC with its pairs in `*style-key-order*`, duplicates dropped and every pair
whose value is NIL removed.

**Two spellings of one style were two styles.** `'(:fg :red :bold t)` and
`'(:bold t :fg :red)` are the same rendition, and `style-index` interned them at
different indices with different bytes — `ESC[0;31;1m` against `ESC[0;1;31m` —
so a frame drawn by one and repainted by the other emitted a style change where
nothing had changed, and `compare-heads` read a difference that was not one.
Both spellings are in the tree today (`src/chrome.lisp:271,329` against
`src/cards.lisp:1065`).

A NIL value is dropped rather than kept, because `'(:bold nil)` renders as
nothing and index 0 renders as nothing, and two indices for one rendition is the
same defect one level down. A key nobody knows is kept, in the order it was
written, so `%style-sgr` still refuses it out loud rather than ignoring it."
  (when spec
    (let ((pairs (loop for (k v) on spec by #'cddr
                       unless (or (null v) (assoc k seen))
                         collect (cons k v) into seen
                       finally (return seen))))
      (append
       (loop for k in *style-key-order*
             for hit = (assoc k pairs)
             when hit append (list k (cdr hit)))
       (loop for (k . v) in pairs
             unless (member k *style-key-order*) append (list k v))))))

(defun style-index (spec)
  "Intern a style spec plist (:fg :cyan :bold t …) into a small integer.
Index 0 is the default; EQUAL is the identity of a CANONICAL spec — see
`%canonical-style`, which is what makes the key order not matter."
  (let ((spec (%canonical-style spec)))
    (if (null spec)
      0
      (or (position spec *styles* :test #'equal)
          (progn
            (vector-push-extend spec *styles*)
            (vector-push-extend (%style-sgr spec) *style-sgrs*)
            (1- (length *styles*)))))))

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

;;; ---------------------------------------------------------------- paint ;;;

(declaim (inline %cell=))
(defun %cell= (a b)
  (declare (type cell a b))
  (and (char= (cell-ch a) (cell-ch b))
       (= (cell-style a) (cell-style b))))

(defun %write-decimal (n out)
  "N, a non-negative fixnum, in decimal on OUT — what `(format out \"~D\" n)`
does, without going through the format interpreter. The painter emits one
cursor move per changed run: measured, up to a few hundred a frame, and `format`
was 2.6% of the paint for two numbers per move."
  (declare (type fixnum n) (type stream out))
  (if (< n 10)
      (write-char (code-char (+ 48 n)) out)
      (progn (%write-decimal (floor n 10) out)
             (write-char (code-char (+ 48 (mod n 10))) out))))

(defun %move-to (out row col)
  "`ESC[row;colH`, 1-based, from 0-based ROW and COL."
  (declare (type fixnum row col) (type stream out))
  (write-char +esc+ out)
  (write-char #\[ out)
  (%write-decimal (1+ row) out)
  (write-char #\; out)
  (%write-decimal (1+ col) out)
  (write-char #\H out))

(defvar *caret* nil
  "Where the terminal's own caret belongs, as (ROW . COL), or NIL for hidden.

Set by `%render` from the composer; read by the painter, which ends every frame
with the move and `ESC[?25h` — or with `ESC[?25l` when nothing wants it. A defvar
and not a head slot, because a slot is a struct layout change and that is a
restart, which is the one thing a live push must not need."
  )

(defun paint-diff (prev cur out &key (sync t))
  "Emit the escape sequence that turns the terminal showing PREV into the
terminal showing CUR. PREV nil paints everything. Both screens must have the
same shape. Runs of changed cells are written behind one absolute cursor move;
styles are tracked across the whole frame so SGR is emitted only on change.

Typed, and at DEFAULT safety, on purpose. The loop reads a `cell` out of each
screen's `simple-vector` and the declaration makes every accessor a direct load —
that is where the time was (measured: 18.7% of the frame, of which the two
`format`s and the untyped struct reads were most). What (safety 0) would remove
is one struct-tag test per cell, and the vector holds whatever a hack put there:
`(fill (screen-cells s) nil)` off the eval socket is one line, and with the check
gone that is a memory fault in the main thread — the exact failure this head has
already died of once. The check stays, and it was measured to cost nothing: 200
paints of a 210×63 frame with every row changed took 15 ms at default safety and
14–16 ms with (safety 0) — the same number, inside the run-to-run noise."
  (declare (type screen cur) (type (or null screen) prev) (type stream out))
  (when prev
    (assert (and (= (screen-cols prev) (screen-cols cur))
                 (= (screen-rows prev) (screen-rows cur)))
            (prev cur) "paint-diff screens must have the same shape"))
  (let* ((cols (screen-cols cur))
         (rows (screen-rows cur))
         (cells (screen-cells cur))
         ;; paint-full has just cleared: a default cell needs no writing, so
         ;; that is the sentinel — ONE of them, not one per cell
         (blank (%cell #\space 0))
         (pcells (if prev (screen-cells prev) nil))
         ;; Every paint ends with a reset, so every paint begins at default
         ;; style — SGR for style 0 is never needed mid-frame.
         (last-style 0))
    (declare (type fixnum cols rows last-style)
             (type simple-vector cells)
             (type (or null simple-vector) pcells))
    (when sync (sync-begin out))
    (dotimes (r rows)
      (declare (type fixnum r))
      (let ((c 0)
            (base (* r cols)))
        (declare (type fixnum c base))
        (loop while (< c cols)
              do (let* ((i (+ base c))
                        (cell (svref cells i))
                        (pcell (if pcells (svref pcells i) blank)))
                   (declare (type fixnum i) (type cell cell pcell))
                   (if (%cell= pcell cell)
                       (incf c)
                       (progn
                         ;; start of a changed run: move there, write until it ends
                         (%move-to out r c)
                         (loop while (< c cols)
                               do (let* ((j (+ base c))
                                         (cc (svref cells j))
                                         (pp (if pcells (svref pcells j) blank)))
                                    (declare (type fixnum j) (type cell cc pp))
                                    (when (%cell= pp cc) (return))
                                    (let ((ch (cell-ch cc)))
                                      (cond
                                        ((char= ch +wide-cont+)
                                         ;; covered by the wide char before it
                                         (incf c))
                                        (t
                                         (when (/= (cell-style cc) last-style)
                                           (write-string (%sgr (cell-style cc)) out)
                                           (setf last-style (cell-style cc)))
                                         (let ((w (char-width ch)))
                                           (if (and (= 2 w) (= c (1- cols)))
                                               ;; a wide char on the last column would
                                               ;; wrap; the buffer never holds one there
                                               ;; (screen-put-string degrades it), but a
                                               ;; direct screen-put could — guard anyway
                                               (progn (write-char #\space out) (incf c))
                                               (progn (write-char ch out)
                                                      (incf c (max 1 w))))))))))))))))
    (write-char +esc+ out)
    (write-string "[0m" out)
    ;; THE CARET, last: a frame is a run of absolute moves, so wherever the last
    ;; changed run left the cursor is arbitrary — the caret has to be placed after
    ;; the painting and only then shown.
    (if *caret*
        (progn (%move-to out (car *caret*) (cdr *caret*))
               (write-char +esc+ out)
               (write-string "[?25h" out))
        (progn (write-char +esc+ out)
               (write-string "[?25l" out)))
    (when sync (sync-end out))
    (force-output out)))

(defun paint-full (cur out)
  "Clear and paint everything — after a resize, on attach, on resync."
  (write-string (format nil "~C[2J" +esc+) out)
  (paint-diff nil cur out))

(defun move-to (out row col)
  (format out "~C[~D;~DH" +esc+ (1+ row) (1+ col)))

(defun screen-row (screen row)
  "ROW of SCREEN as a list of cells. NIL for a row off the screen, rather than an
error: a caller rendering a frame that just shrank is asking a reasonable
question."
  (let ((cols (screen-cols screen))
        (rows (screen-rows screen)))
    (when (and (>= row 0) (< row rows))
      (loop for c from 0 below cols collect (screen-cell screen row c)))))

(defun screen-rows-ansi (screen)
  "One string per row, escape codes included — the answer to ScreenRequested
and the body of /cells: what this head actually drew, at its real size, not a
description of it (protocol.rs on ClientFrame::Screen).

Built every frame (`%render-and-paint` keeps the last drawn rows), so it is
typed like the painter and reads the cell vector directly. Default safety, for
the painter's reason: the vector is a `simple-vector` of whatever was put there."
  (declare (type screen screen))
  (let* ((out nil)
         (cols (screen-cols screen))
         (cells (screen-cells screen)))
    (declare (type fixnum cols) (type simple-vector cells))
    (dotimes (r (screen-rows screen))
      (declare (type fixnum r))
      (with-output-to-string (s)
        (let ((last-style -1)
              (base (* r cols)))
          (declare (type fixnum last-style base))
          (dotimes (c cols)
            (declare (type fixnum c))
            (let ((cell (svref cells (+ base c))))
              (declare (type cell cell))
              (unless (char= (cell-ch cell) +wide-cont+)
                (when (/= (cell-style cell) last-style)
                  (write-string (%sgr (cell-style cell)) s)
                  (setf last-style (cell-style cell)))
                (write-char (cell-ch cell) s))))
          (write-char +esc+ s)
          (write-string "[0m" s))
        (push (get-output-stream-string s) out)))
    (nreverse out)))
