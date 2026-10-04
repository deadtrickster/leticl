;;;; render.lisp — the frame engine: state to cells, and the paint.
;;;;
;;;; The segment and line machinery (`wrap-segments`, `put-segments`) and the
;;;; viewport and frame composition (`%viewport-lines`, `%render`,
;;;; `%place-lines`, `%render-and-paint`). What each part of the frame looks
;;;; like lives beside this file: transcript rows in `cards.lisp`, the frame
;;;; furniture in `chrome.lisp`, the full-body screens in `panes.lisp`.
;;;;
;;;; Everything here is a plain function so a model can redefine any layer of
;;;; it live (PLAN.md §1).
;;;;
;;;; Optimisation policy (measured, 2026-09-20; the FRAME's own cost re-measured
;;;; 2026-10-04): the per-word loop in `wrap-segments` and its helpers are typed;
;;;; `%render`, `%viewport-lines` and `%place-lines` run ONCE a frame over a few
;;;; dozen lines and are left at the default policy on purpose — under (speed 3)
;;;; they raise notes about generic arithmetic on per-frame scalars
;;;; (`head-scroll`, list lengths).
;;;;
;;;; **THE 0.07 ms FRAME THIS POLICY USED TO QUOTE WAS WRONG, and the correction is
;;;; worth more than the number.** MEASURED on a 214x60 frame: 2.1-2.6 ms warm and
;;;; cold alike, on sessions of 200-4000 rows and payloads from 2 to 300 lines —
;;;; and 0.1 ms for the same frame with nothing live and small rows on it. So
;;;; `%render` is not a constant at all: it is a function of WHAT IS ON THE SCREEN,
;;;; and the old reading was taken on a 63x210 head with an 87-item transcript —
;;;; the one session a head never spends a turn in. Two digits out, on the file whose
;;;; job is to say where a frame goes; see PERF.md.

(in-package #:leticl)

;;; ------------------------------------------------------------- wrapping ;;;
;;;
;;; **ONE breakpoint rule, and everything that wraps goes through it.**
;;;
;;; `%break-ranges` is that rule: TEXT's wrapped rows as (START . END) character
;;; index pairs that TILE the text. It is the reference's `break_cells`
;;; (width.rs:420-513) ported whole, and both callers are derived from it —
;;; `wrap-ranges` returns the pairs (the composer needs INDICES, because the caret
;;; is a position in the text) and `wrap-segments` slices the text by them. The
;;; reference routes both of its own wrappers through one `break_cells` and says why
;;; in one line (`width.rs:410-419`): *two functions kept in sync by a comment is a
;;; bug with a schedule*.
;;;
;;; **This used to be two scanners, and they disagreed.** `wrap-ranges` was an
;;; independent walker measuring `char-width` per CHARACTER — not cluster-aware, not
;;; escape-aware — so the composer's caret arithmetic and the transcript's wrapping
;;; broke in different places on the same text. Measured, before the merge:
;;;
;;;   text                             transcript rows   range boundaries
;;;   `中文中文中文` at 4 columns       (2 4 6)           (2 4 6)      same
;;;   `hello 中文中文中文` at 10        (3 7)             (6 11 12)    DRIFT
;;;   `e◌́abcd◌́efgh` at 4 (combining)   (1 2 3)           (5 10 11)    DRIFT
;;;   an SGR escape, 8 letters at 6     (1 2)             (7 14 17)    DRIFT
;;;   a ZWJ family then `x` at 2        (2 4)             (2 4 5 6)    DRIFT
;;;   `ab<TAB>cd<TAB>ef` at 4           (1 2)             (6 8)        DRIFT
;;;
;;; The first row of the CJK-after-prose case is TEN columns to the transcript and
;;; SIX to the caret — the same disagreement that ate half of every double-width line
;;; (the W1 commit), with a longer fuse: nothing is dropped, the caret is simply
;;; drawn on a row that is not where the reader thinks it is.
;;;
;;; The four break rules, in priority order, and they are letibot's:
;;;
;;;   1. at a SPACE (or a TAB, which is a break opportunity and no columns), the
;;;      ordinary case — and the space belongs to the row it ends, so the ranges tile
;;;      the text and re-joining them is the text again;
;;;   2. at a NEWLINE, a HARD break: a C0 byte measures zero columns for the same
;;;      reason a combining mark does, so without this rule a two-line reason wraps to
;;;      one row with a literal newline inside the segment — which
;;;      `screen-put-string` drops on the floor (its zero-width arm), reflowing two
;;;      lines into one blob;
;;;   3. BETWEEN TWO WIDE CLUSTERS, which is what makes CJK wrap at all: a space-only
;;;      wrapper returns one 400-column line for a paragraph of Chinese;
;;;   4. ANYWHERE, when a single unbreakable run is longer than the width — a URL, a
;;;      base64 blob — and that cut is by COLUMNS over clusters.
;;;
;;; **The cells come from `clusters`, so the rule cannot disagree with the painter
;;; about what a column is.** That is the property the old scanner got wrong and the
;;; one that matters: `string-width` and `screen-put-string` both count clusters, and
;;; so does this.
;;;
;;; **The plain case is placed without clusters**, the same way `screen-put-string`
;;; places it: a string with nothing wide, nothing zero-width and no escape is walked
;;; one character at a time, because `clusters` conses a struct and two `subseq`s per
;;; cluster and this runs on every visible row of every frame. The two paths are held
;;; to the same answer by `the-two-breakpoint-paths-agree`, which is what makes this
;;; one rule rather than two implementations of one idea.

(defun %break-ranges-plain (s n cols)
  "The break rule over a string whose every character is one plain column.

S is a simple-string, N its length, COLS at least 1, and `plain-columns-p` holds of
it — so there is no wide cluster, no escape and no control character, and the cell
walk below reduces to one character per cell of one column each."
  (declare (type simple-string s) (type fixnum n cols))
  (let ((out nil) (row-start 0) (used 0) (word-start nil) (word-cols 0))
    (declare (type fixnum row-start used word-cols))
    (macrolet ((cut (end) `(progn (push (cons row-start ,end) out)
                                  (setf row-start ,end used 0))))
      (loop for i of-type fixnum from 0 below n
            do (if (char= (schar s i) #\space)
                   (progn
                     (when word-start
                       (when (and (plusp used) (> (+ used word-cols) cols))
                         (cut word-start))
                       (incf used word-cols)
                       (setf word-start nil word-cols 0))
                     (incf used)
                     (when (> used cols) (cut (1+ i))))
                   (progn
                     (unless word-start (setf word-start i word-cols 0))
                     (when (> (1+ word-cols) cols)
                       (when (and (plusp used) (> (+ used word-cols) cols))
                         (cut word-start))
                       (cut i)
                       (setf word-start i word-cols 0))
                     (incf word-cols))))
      (when (and word-start (plusp used) (> (+ used word-cols) cols))
        (cut word-start))
      (push (cons row-start n) out))
    (nreverse out)))

(defun %break-ranges-cells (s n cols)
  "The same rule over `clusters`, for a string with anything wide, zero-width or
escaped in it. S, N and COLS as above.

An escape-only cell OCCUPIES nothing and is not a break opportunity: it is a style
change riding on the text beside it, and splitting a row between the escape and the
glyph it colours would leave the colour on the row it does not describe."
  (declare (type simple-string s) (type fixnum n cols))
  (let ((out nil) (row-start 0) (used 0) (word-start nil) (word-cols 0) (i 0))
    (declare (type fixnum row-start used word-cols i))
    (macrolet ((cut (end) `(progn (push (cons row-start ,end) out)
                                  (setf row-start ,end used 0))))
      (dolist (cl (clusters s))
        (let* ((text (cluster-text cl))
               (len (+ (length (cluster-esc cl)) (length text)))
               (cw (cluster-cols cl)))
          (declare (type fixnum len cw))
          (when (plusp (length text))
            (let ((end (+ i len)))
              (declare (type fixnum end))
              (cond
                ;; 2. a HARD break, and it belongs to the row it ends
                ((string= text (string #\Newline))
                 (when word-start
                   (when (and (plusp used) (> (+ used word-cols) cols))
                     (cut word-start))
                   (setf word-cols 0))
                 (cut end))
                ;; 1 and 3: a space, a tab, or a wide cluster
                ((or (string= text " ") (string= text (string #\Tab)) (= cw 2))
                 (when word-start
                   (when (and (plusp used) (> (+ used word-cols) cols))
                     (cut word-start))
                   (incf used word-cols)
                   (setf word-start nil word-cols 0))
                 (if (and (= cw 1) (or (string= text " ") (string= text (string #\Tab))))
                     (progn (incf used cw)
                            (when (> used cols) (cut end)))
                     ;; a WIDE CLUSTER IS A BREAK OPPORTUNITY BEFORE ITSELF: it may
                     ;; not straddle the edge, so the row ends here and the cluster
                     ;; starts the next one
                     (progn (when (and (plusp used) (> (+ used cw) cols))
                              (cut i))
                            (incf used cw))))
                ;; 4. an ordinary cluster joins the pending word, and a word longer
                ;; than a whole row is cut here rather than overflowed
                (t
                 (unless word-start (setf word-start i word-cols 0))
                 (when (> (+ word-cols cw) cols)
                   (when (and (plusp used) (> (+ used word-cols) cols))
                     (cut word-start))
                   (cut i)
                   (setf word-start i word-cols 0))
                 (incf word-cols cw)))))
          (incf i len)))
      (when (and word-start (plusp used) (> (+ used word-cols) cols))
        (cut word-start))
      (push (cons row-start n) out))
    (nreverse out)))

(defun %break-ranges (text cols)
  "**The breakpoint rule.** TEXT's wrapped rows as (START . END) character index
pairs that TILE it: the first starts at 0, each END is the next START, and the last
END is the length — a trailing space belongs to the row it ended, so a row's slice
may be one column over COLS *in trailing whitespace only*.

The reference's `break_cells`, and the ONE place this head decides where a line
ends. Every caller that wraps goes through it: `wrap-segments` slices by these
ranges, `wrap-ranges` returns them (`locate-in-ranges` then turns a caret position
into a row and a column, so the caret and the text cannot disagree).

COLS is floored at 1: a zero-column frame is not a frame, and the reference's
`.max(4)` has no counterpart here because the callers pass widths that are already
floored (`pane-width`, the composer's inner box)."
  (declare (type (or null string) text) (type fixnum cols))
  (let* ((s (%simple text))
         (n (length s))
         (cols (max 1 cols)))
    (declare (type simple-string s) (type fixnum n cols))
    (cond ((zerop n) (list (cons 0 0)))
          ((plain-columns-p s) (%break-ranges-plain s n cols))
          (t (%break-ranges-cells s n cols)))))

(defun wrap-ranges (text cols)
  "TEXT's wrapped rows as (START . END) character-index pairs that tile it.

**This is `%break-ranges`, and it is not a second scanner.** It used to be one — a
character-at-a-time walker with its own rules and its own width arithmetic, which
measured an escape sequence as 2 columns where the painter measures 6, and broke a
ZWJ family into five rows of one cluster each. So the composer's caret and the
transcript disagreed about where a line ended, on the same text: see
`%break-ranges`' docstring for the measurements that made this a merge.

The composer needs the INDICES and not the strings: the caret is a position in the
text, and to draw it you have to know which row it landed on and how many columns
into it (`locate-in-ranges`)."
  (declare (type (or null string) text) (type fixnum cols))
  (%break-ranges text cols))

(defun %slice-line (segs offsets from to)
  "The segments of SEGS covering character indices FROM..TO, with their styles.

OFFSETS is the character index each segment starts at, PAD is where SEGS ends.
Adjacent pieces of one segment that a break decision did not separate are merged:
the rows are what the painter gets, and two spans of one style side by side are one
span."
  (declare (type fixnum from to))
  (let ((out nil))
    (loop for rest on segs
          for start of-type fixnum in offsets
          for seg = (car rest)
          for text = (car seg)
          for len of-type fixnum = (length text)
          for end of-type fixnum = (+ start len)
          when (and (< start to) (> end from))
            do (let ((lo (max from start)) (hi (min to end)))
                 (when (< lo hi)
                   (let ((piece (subseq text (- lo start) (- hi start))))
                     (if (and out (eq (cdr (car out)) (cdr seg)))
                         (setf (car (car out))
                               (concatenate 'string (car (car out)) piece))
                         (push (cons piece (cdr seg)) out))))))
    (nreverse out)))

(defun wrap-segments (segs cols)
  "Segments to lines of at most COLS columns, by `%break-ranges`.

Style carries onto continuation lines; each returned line is independently
paintable. A trailing space belongs to the row it ended and is then TRIMMED off it —
it is invisible until something copies it, and a painter that erases to the end of
the row paints the background one column further than the text goes. A newline ends a
row and is never painted; a text that ENDS in one leaves a last row with nothing on
it, which is what the reference's `break_cells` returns and what this head's composer
already did.

**The words are not re-joined here.** This used to split each segment into words
itself, with its own width arithmetic and its own `%hard-break`; now the text is
concatenated, the rule above decides where the rows end, and each row is a SLICE of
the text. So the composer, the transcript and the painter agree by construction
rather than by review, which is the whole point of the merge.

COLS is declared a fixnum at default safety: every caller passes a column count, and
the declaration is what lets the arithmetic compile to fixnum compares."
  (declare (type fixnum cols))
  (cond ((null segs) nil)
        ((<= cols 0) (list segs))
        ;; a text with nothing in it is no rows, not one empty row: the empty string is
        ;; what a secret ask's missing `command` gives, and an empty segment list
        ;; already answered nil before this went through the range finder
        (t (let* ((text (if (null (cdr segs))
                            (or (car (car segs)) "")
                            (apply #'concatenate 'string
                                   (mapcar (lambda (s) (or (car s) "")) segs))))
                  (offsets nil)
                  (pos 0))
             (declare (type fixnum pos))
             (dolist (seg segs)
               (push pos offsets)
               (incf pos (length (or (car seg) ""))))
             (setf offsets (nreverse offsets))
             (when (zerop (length text)) (return-from wrap-segments nil))
             (let ((out nil))
               (dolist (r (%break-ranges text cols))
                 (push (%trim-row (%slice-line segs offsets (car r) (cdr r))) out))
               (nreverse out))))))

(defun %trim-row (line)
  "LINE with the whitespace that ended it taken off: spaces, and a newline with its
CR. Those characters are what told the wrapper the row ended and the terminal must
never see them — a newline left in a row is obeyed by the terminal, which puts a line
on the screen the head did not count and scrolls the frame it had just painted."
  (let ((out (reverse line)))
    (loop while (and out (zerop (length (string-right-trim " " (car (car out))))))
          do (pop out))
    (when out
      (let* ((last (first out))
             (text (string-right-trim '(#\space #\newline #\return) (car last))))
        (nreverse (cons (cons text (cdr last)) (rest out)))))))
(defun locate-in-ranges (text cursor ranges)
  "Which wrapped ROW the CURSOR is on, and how many COLUMNS into it — the
reference's `width::locate`."
  (let* ((cursor (min (max 0 cursor) (length text)))
         (row (or (position-if (lambda (r) (<= (car r) cursor)) ranges :from-end t) 0))
         (start (car (nth row ranges))))
    (values row (string-width text :start start :end cursor))))

(defun put-segments (screen row col segs)
  "One segment line to the buffer; returns the column after it.

**AND THIS IS WHERE A HYPERLINK'S SPAN IS RECORDED**, because this is the only function that
knows both the row and the columns its text actually landed in — after wide-character degradation
and after a truncation, which are facts about the SCREEN and not about the segment. The URL is not
here: the segment carries an INTEGER id into `*link-urls*`, and the URL is looked up at paint time
by the one module that mints them (`src/links.lisp`), so nothing that arrives as text can become a
target."
  (let ((c col))
    (dolist (seg segs c)
      (let ((id (getf (cdr seg) :link))
            (from c))
        ;; `:link` STRIPPED before the style is interned: a URL inside a style spec would enter the
        ;; style table as CONTENT, one entry per distinct path for ever, and the grid's whole safety
        ;; argument is that what goes in it is a character and an integer.
        (setf c (screen-put-string screen row c (car seg)
                                   (style-index (if id (link-strip-style (cdr seg)) (cdr seg)))))
        (when id (link-note row from c id))))))

(defun put-wrapped (screen row col segs cols)
  "Wrapped segments starting at row; returns the next row."
  (let ((r row))
    (dolist (line (wrap-segments segs cols) r)
      (put-segments screen r col line)
      (incf r))))

