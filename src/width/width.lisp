;;;; width — width: how many columns a string takes
;;;;
;;;; Split out of `width.lisp`, which was one 466-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------------------- width ;;;

(declaim (ftype (function (simple-string fixnum fixnum) fixnum) %width-between))
(defun %width-between (string start end)
  "Columns of STRING between START and END, by the cluster rules, in ONE pass and
with NO consing. This is `clusters` with the struct left out: the same three
rules (control, ZWJ, flag), the same escape skipping, and the width of each
cluster added as the cluster closes. A test (`string-width-agrees-with-clusters`)
holds the two to the same answer on the tricky strings.

Measured on the frame benchmark (2000 items, 210×63, 200 frames): `string-width`
through `clusters` was 41% of the frame and 53% of `markdown-lines`; corpus (c) —
100k widths of a 200-character mixed string — went from 2158 ms to 65 ms.

(safety 0) is safe because the entry (`string-width`) coerces the argument to a
`simple-string` and passes its own bounds: START and END are 0 ≤ START ≤ END ≤
(length STRING), and a simple-string's length cannot change under the loop. Every
index read here is either I in [START, END) or (1- I) with I > START."
  (declare (optimize (speed 3) (safety 0))
           (type simple-string string)
           (type fixnum start end))
  (let ((total 0) (i start))
    (declare (type fixnum total i))
    (loop while (< i end) do
      ;; escapes: none of them a column
      (loop while (and (< i end) (char= (schar string i) +esc+))
            do (setf i (min end (%skip-escape string i))))
      (when (>= i end) (return))
      ;; a cluster: its first character sets the width, the rest may only
      ;; join (ZWJ), pair (flag) or extend (zero-width, not a control)
      (let* ((ch (schar string i))
             (cols (%code-width (char-code ch)))
             (prev-ri (%regional-indicator-p ch)))
        (declare (type fixnum cols))
        (incf i)
        (loop while (< i end) do
          (let ((ch (schar string i)))
            (when (char= ch +esc+) (return))
            (let ((w (%code-width (char-code ch))))
              ;; the same order as `clusters`, for the same reason: zero-width
              ;; first, so a control character can end the cluster before the
              ;; ZWJ rule swallows it (width.rs:107-139)
              (cond ((zerop w)
                     (if (%c1-control-p (char-code ch)) (return) (incf i)))
                    ((and prev-ri (%regional-indicator-p ch))
                     (setf cols 2 prev-ri nil) (incf i))
                    ((char= (schar string (1- i)) +esc-zwj+)
                     (setf cols (max cols w)) (incf i))
                    (t (return))))))
        (incf total cols)))
    total))

(declaim (ftype (function ((or null string) &key (:start fixnum) (:end (or null fixnum))) fixnum)
                string-width))
(defun string-width (string &key (start 0) end)
  "Columns STRING occupies on a terminal, escapes excluded, CLUSTERS measured.

The cluster-aware answer: a ZWJ emoji is one cell of two columns, a flag is two,
and an escape sequence is none — which is what makes a right border land where
the frame put it. START and END bound the measurement so a caller can measure a
word without its trailing space without allocating the trimmed word
(`wrap-segments`).

Default safety: this is the public entry and the boundary the walker's (safety
0) relies on — the argument is coerced to a simple-string here and the bounds
are clamped to it. NIL measures zero, as before."
  (declare (type (or null string) string) (type fixnum start))
  (let* ((s (%simple string))
         (n (length s))
         (end (if end (min (the fixnum end) n) n))
         (start (max 0 start)))
    (declare (type simple-string s) (type fixnum n end start))
    (if (>= start end) 0 (%width-between s start end))))

(declaim (ftype (function ((or null string)) boolean) plain-columns-p))
(defun plain-columns-p (string)
  "Is every character of STRING one plain column — no escape, nothing wide,
nothing zero-width — so that its width is its length and character K sits in
column K?

The question the painter asks before it walks clusters at all: measured, 463
`screen-put-string`s a frame, and nearly every one of them a run of letters and
box-drawing glyphs. A string that answers yes is placed one cell per character,
which is what the cluster rules reduce to when no character can join, pair or
extend the one before it.

Default safety: the entry coerces and the loop's index is bounded by the length."
  (declare (type (or null string) string))
  (let* ((s (%simple string))
         (n (length s)))
    (declare (type simple-string s) (type fixnum n))
    (loop for i of-type fixnum from 0 below n
          always (let ((ch (schar s i)))
                   (and (char/= ch +esc+)
                        (= 1 (%code-width (char-code ch))))))))

(defun %truncate-cells (string cols)
  "STRING cut to at most COLS columns, escapes kept whole, no cluster split, and
NOTHING said about it. The silent half of `truncate-to-width`, which is the only
caller that should want it: a cut with no mark on it is a cut a reader cannot
see, so the mark is added one level up and this stays the place that knows where
a cluster ends.

A cluster is never cut in half: half a ZWJ sequence is a different glyph, and half
a flag is a letter. Escapes are carried with their cluster, so a cut does not leave
an attribute open."
  (if (<= (string-width string) cols)
      string
      (let ((out (make-string-output-stream))
            (w 0))
        (dolist (c (clusters string))
          (when (> (+ w (cluster-cols c)) cols) (return))
          (write-string (cluster-esc c) out)
          (write-string (cluster-text c) out)
          (incf w (cluster-cols c)))
        (get-output-stream-string out))))

(defun truncate-to-width (string cols)
  "STRING cut to at most COLS columns, with an `…` where the rest went.

**The elision is disclosed** (`width::truncate`, width.rs:329-353). Ours cut
silently, so `…/worktrees/agent` and `…/worktrees/agent-a19da2/crates` ended at
the same place on the screen and read as the same path — and every pane row, every
card header and every diff row on this head elided without a mark. The last column
is spent on saying so, which is why the content is fitted to `cols - 1`: a cap that
forgets the ellipsis costs is a cap the output is allowed to exceed.

COLS of zero is the empty string: there is no column to put the mark in."
  (cond ((<= (string-width string) cols) (or string ""))
        ((<= cols 0) "")
        (t (concatenate 'string (%truncate-cells string (1- cols)) "…"))))

(defun fit-to-width (string cols)
  "STRING padded or truncated to EXACTLY COLS columns."
  (let* ((cut (truncate-to-width string cols))
         (w (string-width cut)))
    (if (< w cols)
        (concatenate 'string cut (make-string (- cols w) :initial-element #\space))
        cut)))
