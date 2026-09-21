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
;;;; Optimisation policy (measured, 2026-09-20): the per-word loop in
;;;; `wrap-segments` and its helpers are typed; `%render`, `%viewport-lines` and
;;;; `%place-lines` run ONCE a frame over a few dozen lines and are left at the
;;;; default policy on purpose — under (speed 3) they raise notes about generic
;;;; arithmetic on per-frame scalars (`head-scroll`, list lengths), and the whole
;;;; of `%render` outside the leaves measures under 0.1 ms a frame.

(in-package #:leticl)

;;; ------------------------------------------------------------- wrapping ;;;
(defun %split-words (text)
  "Word chunks with their trailing spaces attached, so re-joining preserves
spacing exactly.

By index and `subseq`, not through a string stream: measured, the stream version
was 6% of the frame (`character-out` + `get-output-stream-string` per word, then a
`remove` pass for the empty chunk) and this is one allocation per word."
  (declare (type (or null string) text))
  (let* ((s (%simple text))                ; NIL is no words, as `across nil` was
         (n (length s))
         (out nil)
         (start 0))
    (declare (type simple-string s) (type fixnum n start))
    (loop for i of-type fixnum from 0 below n
          do (when (char= (schar s i) #\space)
               (push (subseq s start (1+ i)) out)
               (setf start (1+ i))))
    (when (< start n)
      (push (subseq s start n) out))
    (nreverse out)))

(defun %hard-break (word cols)
  "One over-wide word to cols-sized chunks — a 400-column URL wraps, it does
not overflow (width.rs's third mistake)."
  (let ((out nil))
    (loop for i from 0 below (length word) by (max 1 cols)
          do (push (subseq word i (min (length word) (+ i (max 1 cols)))) out))
    (nreverse out)))

(defun %visible-end (word)
  "The index after the last non-space character of WORD: where its VISIBLE part
ends. What `(length (string-right-trim \" \" word))` says, without the copy."
  (declare (type simple-string word))   ; a `%split-words` chunk: a `subseq`
  (let ((e (length word)))
    (declare (type fixnum e))
    (loop while (and (> e 0) (char= (schar word (1- e)) #\space))
          do (decf e))
    e))

(defun wrap-segments (segs cols)
  "Segments to lines of at most COLS columns. Style carries onto continuation
lines; each returned line is independently paintable.

A trailing space belongs to the row it ended and is not counted against the
width — the usual line-breaking contract, and the reference's (`break_cells`: a
row's slice may be one column over COLS *in trailing whitespace only*). It is then
TRIMMED off the row: it is invisible until something copies it, and a painter that
erases to the end of the row paints the background one column further than the
text goes. Without this rule a paragraph whose words fit exactly wrapped one word
early, and a row's last word could carry a space past the edge.

The visible width of a word is measured IN PLACE (`string-width … :end`) rather
than on a trimmed copy: every word used to be copied once and measured twice, and
the trimmed copy is only needed when the word is too wide for a row. Measured on
the (d) corpus — a 1 KB paragraph wrapped 2000 times — 423 ms before the width
rewrite, 37 ms after it, 19 ms with this and the typed word loop.

COLS is declared a fixnum at default safety: every caller passes a column count,
and the declaration is what lets the per-word comparisons compile to fixnum
compares instead of generic ones (the note speed 3 raised here)."
  (declare (type fixnum cols))
  (if (<= cols 0)
      (list segs)
      (let ((lines nil)
            (cur nil)
            (w 0))
        (declare (type fixnum w))
        (flet ((break-line ()
                 (when cur (push (%trim-line-end (nreverse cur)) lines))
                 (setf cur nil w 0)))
          (dolist (seg segs)
            (dolist (word (%split-words (car seg)))
              (let* ((ww (string-width word))
                     (ve (%visible-end word))
                     ;; a word is its visible part plus trailing spaces, each
                     ;; one column, so the visible width is the difference
                     (vw (if (= ve (length word)) ww (string-width word :end ve))))
                (declare (type fixnum ww ve vw))
                (cond
                  ((> vw cols)
                   (break-line)
                   ;; ONE CHUNK PER ROW. The chunks were all pushed onto one row
                   ;; and then broken once, so a 400-column URL still overflowed —
                   ;; the exact thing the docstring on `%hard-break` says cannot
                   ;; happen. Found reading the profile's hot loop, not the screen.
                   (dolist (c (%hard-break (subseq word 0 ve) cols))
                     (push (cons c (cdr seg)) cur)
                     (break-line)))
                  ((<= (+ w vw) cols)
                   (push (cons word (cdr seg)) cur)
                   (incf w ww))
                  (t
                   (break-line)
                   (push (cons word (cdr seg)) cur)
                   (setf w ww))))))
          (break-line))
        (nreverse lines))))

(defun wrap-ranges (text cols)
  "TEXT's wrapped rows as (START . END) character-index pairs that tile it — the
reference's `width::wrap_ranges`, which is the same breakpoint finder its `wrap`
uses, because two functions kept in step by a comment is a bug with a schedule.

The composer needs the INDICES and not the strings: the caret is a position in
the text, and to draw it you have to know which row that position landed on and
how many columns into it. A newline ends a row; an over-wide word hard-breaks."
  (declare (type string text) (type fixnum cols))
  (let ((cols (max 1 cols))
        (n (length text))
        (out nil)
        (start 0)
        (i 0)
        (w 0)
        (last-break nil))
    (declare (type fixnum n start i w))
    (flet ((emit (end next)
             (push (cons start end) out)
             (setf start next i next w 0 last-break nil)))
      (loop while (< i n)
            do (let* ((ch (char text i))
                      (cw (char-width ch)))
                 (cond
                   ((char= ch #\newline) (emit i (1+ i)))
                   ((> (+ w cw) cols)
                    ;; break at the last space if there was one, else hard-break
                    (if (and last-break (> last-break start))
                        (emit last-break last-break)
                        (emit i i)))
                   (t (when (char= ch #\space) (setf last-break (1+ i)))
                      (incf w cw)
                      (incf i)))))
      (push (cons start n) out))
    (nreverse out)))

(defun locate-in-ranges (text cursor ranges)
  "Which wrapped ROW the CURSOR is on, and how many COLUMNS into it — the
reference's `width::locate`."
  (let* ((cursor (min (max 0 cursor) (length text)))
         (row (or (position-if (lambda (r) (<= (car r) cursor)) ranges :from-end t) 0))
         (start (car (nth row ranges))))
    (values row (string-width text :start start :end cursor))))

(defun put-segments (screen row col segs)
  "One segment line to the buffer; returns the column after it."
  (let ((c col))
    (dolist (seg segs c)
      (setf c (screen-put-string screen row c (car seg) (style-index (cdr seg)))))))

(defun put-wrapped (screen row col segs cols)
  "Wrapped segments starting at row; returns the next row."
  (let ((r row))
    (dolist (line (wrap-segments segs cols) r)
      (put-segments screen r col line)
      (incf r))))

;;; ------------------------------------------------------------ rendering ;;;
(defun segs-text-of (line)
  "A segment-line's text, for asking whether it renders as nothing."
  (if line (format nil "~{~a~}" (mapcar #'car line)) ""))

(defun %line-blank-p (line)
  "Does LINE render as nothing — every segment's text spaces or empty? The
question `%viewport-lines` asks of every line of every row it places, each
frame; it used to be asked through `format nil` and `string-trim`, which is two
copies per line to learn one bit."
  (every (lambda (seg)
           (let ((text (car seg)))
             ;; a non-string prints as its name under `~a`, which is not blank
             (and (stringp text)
                  (every (lambda (ch) (char= ch #\space)) text))))
         line))

(defun item-row-class (item)
  "Which KIND of row this is, for the one question the layout asks of its
neighbours: does a blank line belong between them. The reference's `RowClass`."
  (let ((body (item-body item)))
    (if (null body)
        :other
        (case (intern (string-upcase (getf body :type)) :keyword)
          ((:user) :speech)
          ((:assistant) (if (plusp (length (string-trim " " (or (getf body :text) ""))))
                            :speech :activity))
          ((:reasoning :tool_result) :activity)
          (t :other)))))

;;; ------------------------------------------- the history line cache ;;;
;;;
;;; **Scroll cost nothing to find the lines and everything to build them.** The
;;; walk renders every item from the newest down to the scroll depth, so a frame
;;; at the bottom of a 2434-item session builds 61 lines and one 6000 lines back
;;; builds 5098 — measured 0.5 ms and 62 ms, per frame, with nothing reused (two
;;; identical viewports cost 63 ms and 61 ms). Holding the wheel then queues
;;; events faster than the head can draw them, and the head looks frozen: the
;;; operator's *"scroll doesn't work"*.
;;;
;;; The reference solves this with `hist_lines` and a careful invalidation key,
;;; and `rendering.md` argues against porting that key — it would have to include
;;; five defvars any eval can change, and a screen cache is a second source of
;;; truth in a head whose contract is that redefining a renderer changes the next
;;; frame. **This is a narrower cache with a narrower key**: only the committed
;;; transcript's LINES, only while the things that produce them are unchanged.
;;;
;;; The key is everything `item-lines` reads — the read mark (bumped by every
;;; event), the width, the item count, and the three prefs that change how a row
;;; is drawn. Anything else is a bug in the key, so the key is built from what the
;;; renderer actually reads rather than from a guess about what matters.
;;;
;;; **Scrolling changes none of them**, which is the whole point: while the
;;; operator scrolls and no event arrives, the cache holds and a deep frame costs
;;; a `subseq`. The walk is also EXTENDABLE: if a deeper scroll needs more lines
;;; than the cache holds, it continues from where it stopped instead of starting
;;; over, so scrolling further costs the difference and not the whole depth.

(defvar *hist-cache* nil
  "`(key lines next-index class-above)` for the committed transcript, or NIL.

A defvar: a push must not drop a running head's cache, which would cost one
rebuild rather than a wrong frame, but a cache that resets on every push is a
cache that never helps while working on this file.")

(defvar *hist-generation* 0
  "Bumped by anything that can change a committed row: an event folded, a snapshot
taken, a switch. The cache's key, and the reason it cannot be a guess at which
fields matter.

**Not** bumped by scrolling, by a keystroke, or by the composer — those change what
is DRAWN, not what the rows are, and bumping on them would rebuild the history
every frame and lose the whole point.")

(defun %hist-key (head cols)
  "Generation, width, and the IDENTITY of the items vector.

**Three things, because no two of them are enough.** The first version was
`(seq cols count prefs)` and it is wrong: two sessions can sit at the same seq with
the same width and the same item COUNT and hold entirely different content — a
resync or a switch can land on any of those. Measured by a test that set
`session-items` directly and got the PREVIOUS test's lines back.

  · `*hist-generation*` catches an event folded, a body filled in, a snapshot
    taken — the things that change a row WITHOUT changing the count;
  · the width catches a resize, which re-wraps every line;
  · the vector's IDENTITY catches a wholesale replacement that no counter saw,
    which is what `(setf (session-items …))` is.

`eq` on the vector rather than `equal` on its contents: an item body filled in
place leaves the vector and its count identical, and that case is the generation's."
  (list *hist-generation* cols (session-items (head-session head))))

(defun %hist-key= (a b)
  "Two keys equal on the two numbers and the vector's IDENTITY."
  (and a b
       (= (first a) (first b))
       (= (second a) (second b))
       (eq (third a) (third b))))

(defun %history-until (head cols need)
  "The committed transcript's lines, oldest first, at least NEED of them.

Cached: a call that needs no more than the cache holds does no rendering at all,
which is the case that matters — scrolling."
  (let* ((key (%hist-key head cols))
         (s (head-session head))
         (items (session-items s))
         (cached (and *hist-cache* (%hist-key= key (first *hist-cache*)) *hist-cache*))
         (lines (if cached (second cached) nil))
         (next-i (if cached (third cached) (1- (length items))))
         (class-above (if cached (fourth cached) nil)))
    (loop while (and (>= next-i 0) (< (length lines) (1+ need)))
          do (let* ((item (aref items next-i))
                    (il (item-lines item cols (head-prefs head)))
                    (class (item-row-class item)))
               (unless (every #'%line-blank-p il)
                 (when (and lines class-above
                            (not (and (eq class :activity) (eq class-above :activity))))
                   (setf lines (cons nil lines)))
                 (setf class-above class))
               ;; `revappend`: prepends IL in order in O(len il). `append` copies
               ;; the whole accumulated list per item, which is O(depth²).
               (setf lines (revappend il lines)))
             (decf next-i))
    (setf *hist-cache* (list key lines next-i class-above))
    lines))

(defun %window-of (hist tail start end)
  "Elements START..END of the conceptual list `hist` + a blank + `tail`.

Walks the three pieces and copies only the WINDOW, which is the point: `(append
hist …)` copies every cached line to show sixty, and that copy is where the cache's
whole win went — measured: a cached frame at 6000 lines back still cost 76 ms per
twenty, the same as building it, because the 5098-line append dominated.

START is never large (it is `1 + (length tail)` by construction), so the `nthcdr`
costs nothing either."
  (let* ((lh (length hist))
         (lt (length tail))
         (gap (if hist 1 0))
         (n (+ lh gap lt))
         (end (min end n))
         (start (min start end))
         (out nil)
         (k start))
    ;; the part inside HIST
    (when (< k lh)
      (let ((cursor (nthcdr k hist))
            (take (min (- end k) (- lh k))))
        (dotimes (i take)
          (push (car cursor) out)
          (setf cursor (cdr cursor)))
        (incf k take)))
    ;; THE GAP between the committed rows and the live turn
    (when (and (plusp gap) (= k lh) (< k end))
      (push nil out)
      (incf k))
    ;; the part inside TAIL — only once the window has actually passed HIST and the
    ;; gap. Without the guard `(- k lh gap)` goes NEGATIVE for a window that ends
    ;; inside hist, and `nthcdr` wants an unsigned byte: measured, `-6` for a
    ;; 20-item test at scroll 6.
    (when (>= k (+ lh gap))
      (let ((cursor (nthcdr (- k lh gap) tail)))
        (loop while (and cursor (< k end))
              do (push (car cursor) out)
                 (setf cursor (cdr cursor))
                 (incf k))))
    (nreverse out)))

(defun %viewport-lines (head cols want)
  "The conversation's last WANT lines (scrolled up by head-scroll), as
 segment lines oldest-first. The running turn is the newest thing there is, so
 its lines go at the END, after every committed row: reasoning, then the answer,
 then the calls — the bottom of the screen, just above the composer. (Building
 newest-first and reversing the slice put the live turn at the TOP of the
 viewport, above the user prompt it answers — measured on the operator's
 terminal: the newest content sat at row 1 and the oldest at row 57.)"
  (let* ((s (head-session head))
         (need (+ (head-scroll head) want))
         ;; the running turn, then ITS FOOTER — the footer belongs to the turn and
         ;; sits under it, and only when the turn has actually ended
         (tail (append (turn-lines (session-turn s) cols (head-prefs head))
                       (turn-footer-lines (session-turn s) cols)
                       ;; QUEUED PROMPTS, at the tail, where they will land: a
                       ;; sentence the conversation has swallowed is visible here
                       ;; until the daemon appends its row
                       (queued-lines head cols)))
         ;; **AIR WHERE THE KIND CHANGES**, which is the reference's `RowClass` rule
         ;; and the spacing this head was missing: a blank line goes before a row
         ;; unless BOTH it and the row above are `Activity`. Two tool cards in a row
         ;; are one block and read as one — a blank between each was a third of the
         ;; vertical budget spent separating what a glyph in the first column
         ;; already separates — while prose against a card is a change of kind and
         ;; gets the air.
         ;;
         ;; A row that renders NOTHING gets no separator either. An assistant row
         ;; whose text is whitespace and whose every call is drawn by its own result
         ;; is a common shape (it is what a tool-calling round looks like), and
         ;; paying two blank lines for it puts a hole in the transcript.
         ;;
         ;; All of that lives in `%history-until` now, because it is per-ROW state
         ;; (`class-above`) and a cache that forgets it inserts the gaps wrongly on
         ;; the frame after a hit.
         (hist (%history-until head cols need)))
    ;; **AIR ABOVE THE CHROME.** One blank row after the committed rows, always
    ;; (`body_window`: `if !hist_lines.is_empty() { segs.push(gap) }`), so the
    ;; transcript never sits on the box's top edge and the live turn never sits
    ;; on the last settled row. Measured on letibot's screen: row 59 blank, row
    ;; 60 the box's top edge; ours had prose on 59.
    (let* ((lh (length hist))
           (lt (length tail))
           (gap (if hist 1 0))
           (all-len (+ lh gap lt))
           ;; **NOTHING HAS HAPPENED YET.** An empty screen with a status line
           ;; under it is indistinguishable from a head attached to the wrong
           ;; socket — the reference's own sentence (app.rs:6112-6117) — so it says
           ;; so, and says what this window is and is not.
           ;;
           ;; Guarded on `attaching-p` the way the reference guards it on
           ;; `!self.attaching`: the walking cat covers *not answered yet*, and a
           ;; banner asserting the session is empty while nobody has reported
           ;; would be a claim this head is in no position to make.
           (empty (and (zerop all-len) (not (attaching-p head))))
           (empty-lines (when empty (empty-session-lines cols)))
           (n (if empty (length empty-lines) all-len)))
      ;; the scroll is clamped to what exists: past the top there is nothing to
      ;; show, and a wheel that kept counting would need as many turns back
      (setf (head-scroll head) (max 0 (min (head-scroll head) (- n want))))
      (let* ((end (max 0 (- n (head-scroll head))))
             (start (max 0 (- end want)))
             ;; **The window, not the whole transcript.** `(append hist …)` and then
             ;; `subseq` copies every cached line to show sixty, and that copy is
             ;; where the cache's whole win went — measured: a cached frame at 6000
             ;; lines back still cost 76 ms per twenty, because the append of 5098
             ;; lines dominated everything the cache had saved.
             (out (if empty
                      (subseq empty-lines start end)
                      (%window-of hist tail start end))))
        ;; **PARKED IN THE SCROLLBACK, the last row says so** — the reference's
        ;; banner, in yellow, in the transcript's own last row: how far behind
        ;; the tail is, and how to follow it again. Without it a scrolled head is
        ;; indistinguishable from a quiet one, which is the shape the operator
        ;; reads straight past.
        (when (and (plusp (head-scroll head)) out)
          (setf (car (last out))
                (list (cons (format nil "── scrolled back · ~d lines below · ↓ or esc to follow · wheel scrolls · shift+drag selects"
                                    (- n end))
                            '(:fg :yellow)))))
        out))))

(defparameter +right-margin+ 2
  "Columns of right margin, so the frame is not flush against the edge.

Measured from letibot's own screen: in a 210-column pane its box spans columns 2
to 207, which is a 2-column gutter, 206 of content and 2 columns of right margin.
Ours drew flush to 209.

**It is the gutter mirrored, and no longer a constant of its own.** `%render`
computes the body as `term_w - 2 * gutter`, which is the reference's arithmetic
(`app.rs:5035`) and the only version that can give the margin up when the gutter
does. Two independent constants that happened to sum to the same number agreed at
every width this head had been looked at and disagreed at 30 columns, where the
reference hands the body all thirty and this head handed it twenty-six.")

(defparameter +gutter+ 2
  "Columns of left margin the whole frame sits inside, when the terminal can
afford them — see `frame-gutter`.

Measured against letibot's own screen: its body, its chrome and its composer box
are all indented two columns, and the box is 208 wide in a 210 frame. The gutter
is what makes a frame read as a frame rather than as text that happens to start at
the left edge — and it is the last visible difference between the two heads'
layout.")

(defun frame-gutter (term-cols)
  "The gutter this terminal can afford: `+gutter+` at 40 columns or more, and
**zero below** — the reference's `gutter` (app.rs:5320-5327).

Its own words: the gutter is \"the first thing given up on a very narrow screen,
before any content is: four columns out of forty is a tenth of the line, and out
of twenty it is a fifth.\" Ours were two constants that never moved at any width,
so on a 30-column terminal the reference wrapped the body at 30 and this head
wrapped it at 26 — four columns of a narrow screen spent on margin."
  (if (>= term-cols 40) +gutter+ 0))

(defun %fit-ladder (head cols rows card-rows stall-p notice-p comp-p)
  "Which chrome survives on a terminal of ROWS rows — the reference's fit loop
(app.rs:5094-5126), which this head did not have at all.

Returns `(values CARD-ROWS HINT-P NOTICE-P STALL-P COMPLETIONS-P BODY-ROWS
BOXED)`. The ladder **drops the most expendable row first and stops as soon as
the whole thing fits with a line of transcript left over**, in this order:

    completions → the hint bar → the notice → a composer row (down to one)
                → the stall sentence → the box → a decision row

Every position in that order is an argument. The completions row is a typing aid
and goes first; the hint bar is learnable and goes next; the notice has a TTL and
will be gone shortly anyway; the composer gives up rows before it gives up its
walls, because a container with one side is worse than none; the stall sentence
outlives the box because it is the only thing on the screen saying why nothing is
happening; and the decision card is last, because it is the thing being asked.

`boxed` was the whole of this head's degradation — `(>= rows 8)`, one step, taken
whether or not anything else could have been given up first — and nothing at all
clamped the result, so at `h = 2` the composer's first row came out at a NEGATIVE
index. The backstop for that is in `%render`: rows outside the screen are dropped
by `screen-put`, which is the same frame the reference gets from draining the
front of its chrome vector (app.rs:5206-5208).

Unboxed costs one row **only when there is an alarm to show**: the counters move
off the border onto a line of their own, and a clean head owes that row to the
transcript."
  (let ((body-rows (%composer-rows head cols))
        (hint t)
        (boxed t)
        (dec card-rows))
    (loop
      (let ((n (+ dec
                  (if stall-p 1 0)
                  (if notice-p 1 0)
                  (if comp-p 1 0)
                  (if boxed 2 (if (alarmed-p head) 1 0))
                  body-rows
                  (if hint 1 0))))
        (when (< n rows) (return))
        (cond (comp-p (setf comp-p nil))
              (hint (setf hint nil))
              (notice-p (setf notice-p nil))
              ((> body-rows 1) (decf body-rows))
              (stall-p (setf stall-p nil))
              (boxed (setf boxed nil))
              ((> dec 1) (decf dec))
              (t (return)))))
    (values dec hint notice-p stall-p comp-p body-rows boxed)))

(defun %render (head)
  "State to the cell buffer.

The bottom of the frame is laid out BACKWARDS from the last row, because the
composer's height is not fixed: it is a box whose body grows with the buffer, so
the transcript gets what is left. Getting that order wrong is how a composer
scrolls the transcript by a row every keystroke.
"
  (let* ((s (head-screen head))
         (term-cols (head-cols head))
         ;; the gutter is given up before any content is (`frame-gutter`), and
         ;; the right margin is the same number mirrored — `term_w - 2 * gutter`,
         ;; the reference's own arithmetic
         (gutter (frame-gutter term-cols))
         (cols (max 20 (- term-cols (* 2 gutter))))
         (rows (max 1 (head-rows head)))
         ;; the chrome's candidates, each nil or one line
         (stall (stall-row head cols))
         (notice (notice-line head cols))
         (completions (completions-line head cols))
         (card-lines nil))
    (screen-clear s)
    ;; The card that owns the keyboard, in the reference's own order
    ;; (app.rs:5053-5066): a password, then a decision, then the way out, then a
    ;; picker. The `allow-all` question rides at the FRONT of all of it, because
    ;; while it is up every key belongs to it and a question that owns the
    ;; keyboard has to be the thing on the screen.
    (cond ((head-secret-req head)
           (setf card-lines (secret-ask-lines head cols)))
          ((%open-decision head)
           (setf card-lines (permission-card-lines head cols)))
          ((head-quit-open head)
           (setf card-lines (quit-card-lines head cols)))
          (*pick-open*
           (setf card-lines (pick-card-lines head cols))))
    (setf card-lines (append (mode-confirm-lines cols) card-lines))
    (multiple-value-bind (card-rows hint-p notice-p stall-p comp-p body-rows boxed)
        (%fit-ladder head cols rows (length card-lines)
                     (and stall t) (and notice t) (and completions t))
      (let* ((composer (composer-line head cols :boxed boxed :max-rows body-rows))
             (composer-rows (length composer))
             ;; the hint bar owns the LAST row when it survived the ladder; when
             ;; it did not, the composer does
             (hint-row (if hint-p (1- rows) rows))
             ;; the alarm falls back to a row of its own only when there is no
             ;; box to carry the triangle on its bottom edge — and it goes
             ;; BETWEEN the composer and the hint, which is where the reference
             ;; pushes it (app.rs:5199-5201), not above the composer
             (alarm (and (not boxed) (alarmed-p head) (alarm-line head cols)))
             (alarm-row (and alarm (1- hint-row)))
             (cursor (- (or alarm-row hint-row) composer-rows))
             ;; the chrome above the box, in the reference's order: the card, the
             ;; stall sentence, the head's note, the completions
             (chrome-top (- cursor
                            (if comp-p 1 0) (if notice-p 1 0) (if stall-p 1 0)
                            card-rows))
             ;; **the header is not drawn on a screen too short for it.** The
             ;; reference gates it on `h >= 6 && !session_id.is_empty()`
             ;; (app.rs:5231); ours drew it at row 0 unconditionally, so a
             ;; five-row frame spent one of its five on a header.
             ;;
             ;; Only the HEIGHT half is taken. The `session_id.is_empty()` half
             ;; would move the body's first row to 0 on a head that has not been
             ;; told its session yet, and `click-row->sel` (`src/editor.lisp:213`)
             ;; converts a click with `(- row 1)` — the pane's origin is written
             ;; down in a second place, in another strand's file, and moving one
             ;; of the two would put every click in a pane one row out. The
             ;; clause belongs with that arithmetic, not ahead of it.
             (header-p (>= rows 6))
             (body-top (if header-p 1 0))
             (body-bottom (max body-top chrome-top)))
        (when header-p
          (put-segments s 0 gutter (top-border head cols)))
        (cond
          ;; full-body screens replace the transcript
          ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :job-out :picker :todos))
           (let ((room (max 1 (- body-bottom body-top)))
                 (lines nil)
                 (sel-line nil))
             ;; A pane that owns a cursor returns the LINE it is on as a second
             ;; value, because its cursor counts ROWS and this offset counts
             ;; LINES — the two differ by every header above the list.
             (multiple-value-setq (lines sel-line)
               (case (head-mode head)
                 (:help (help-lines cols))
                 (:status (status-screen-lines head cols))
                 (:config (config-lines head (head-settings head) cols))
                 (:jobs (jobs-lines head cols))
                 (:subagents (subagent-lines head cols))
                 ;; the peek pane windows ITSELF, tail-first, because the tail is
                 ;; where a subagent's answer is and the clamp needs the height
                 (:peek (peek-lines head cols room))
                 ;; and the job-output overlay windows itself for the same
                 ;; reason: the tail is where a running job's newest bytes are,
                 ;; and the clamp needs the height
                 (:job-out (job-out-lines head cols room))
                 (:picker (picker-lines (head-session head)
                                        (head-picker-sel head) cols))
                 (:todos (todos-lines head cols))))
             ;; tell the KEY handler what it may scroll: it clamps without
             ;; re-rendering, and the cursor can then scroll itself into view
             (setf *pane-lines* (case (head-mode head)
                                  (:peek *peek-total*)
                                  (:job-out *job-out-total*)
                                  (t (length lines)))
                   *pane-room* room)
             (when sel-line (scroll-pane-into-view sel-line))
             (%place-lines s (if (member (head-mode head) '(:peek :job-out))
                                 lines
                                 (pane-view lines))
                           body-top (1- (+ body-top room)) cols gutter)))
          ;; transcript empty and nothing has arrived yet: the wait, which is a
          ;; thing to SHOW rather than a banner claiming the session is empty — a
          ;; claim a head that has not been answered is in no position to make.
          ((attaching-p head)
           (let* ((wait (attach-lines head cols))
                  (room (max 1 (- body-bottom body-top)))
                  (skip (max 0 (- (floor room 2) (floor (length wait) 2)))))
             (%place-lines s wait (+ body-top skip) (1- body-bottom) cols gutter)))
          (t
           ;; the transcript viewport gets whatever the chrome left
           (let* ((want (max 1 (- body-bottom body-top)))
                  (lines (%viewport-lines head cols want)))
             (%place-lines s lines body-top (+ body-top (length lines) -1) cols gutter))))
        ;; the chrome, top to bottom, exactly the order the ladder counted it in
        (let ((r chrome-top))
          (flet ((row (line) (put-segments s r gutter line) (incf r)))
            (dolist (line (subseq card-lines 0 (min (max 0 card-rows) (length card-lines))))
              (row line))
            (when stall-p (row (first stall)))
            (when notice-p (row (first notice)))
            (when comp-p (row (first completions)))
            (dolist (line composer) (row line))))
        (when alarm-row (put-segments s alarm-row gutter alarm))
        (when hint-p (put-segments s hint-row gutter (hint-bar head cols)))
        ;; **and where the terminal's own caret goes.** The painter emits the move
        ;; and `ESC[?25h` after the frame; without it the head hid the cursor at
        ;; startup and never showed it again, so the composer had no caret at all.
        ;; Clamped at BOTH ends: the ladder can be beaten on a two-row terminal,
        ;; and a negative caret row is a cursor the terminal puts wherever it
        ;; likes.
        (let ((caret (composer-caret head cols :boxed boxed :max-rows body-rows)))
          (setf *caret* (cons (max 0 (min (1- rows) (+ cursor (car caret))))
                              (max 0 (min (1- term-cols) (+ gutter (cdr caret)))))))))))

(defparameter +right-margin+ 2
  "Columns of right margin, so the frame is not flush against the edge.

Measured from letibot's own screen: in a 210-column pane its box spans columns 2
to 207, which is a 2-column gutter, 206 of content and 2 columns of right margin.
Ours drew flush to 209.")

(defparameter +gutter+ 2
  "Columns of left margin the whole frame sits inside.

Measured against letibot's own screen: its body, its chrome and its composer box
are all indented two columns, and the box is 208 wide in a 210 frame. The gutter
is what makes a frame read as a frame rather than as text that happens to start at
the left edge — and it is the last visible difference between the two heads'
layout.")

(defun pane-width (cols)
  "The columns a pane's ROW may use, from the body width COLS it is handed.

`%render` calls every pane with COLS already net of the gutter and the right
margin (`(- (head-cols head) +gutter+ +right-margin+)`), which is the reference's
`term_w - 2 * gutter` (app.rs:4498). The first version subtracted the two again,
so the picker's right-aligned facts ended four columns short of the header's and
the box's edge — measured on a 227-column terminal: letibot's rows end at 225,
ours at 221. The floor is the reference's own `w.max(4)`, raised to 20 so a wrap
never degenerates."
  (max 20 cols))

(defun %place-lines (screen lines top bottom cols &optional (gutter +gutter+))
  "Segment lines into rows top..bottom, clipping both ends, inside the gutter.

GUTTER is passed rather than read, because it is `frame-gutter`'s answer for THIS
terminal and is zero below forty columns."
  (declare (ignorable cols))
  (let ((r top))
    (dolist (line lines)
      (when (> r bottom) (return))
      (put-segments screen r gutter line)
      (incf r))))

(defvar *last-render-error* nil
  "The last error the RENDER path raised, or nil.

A defvar and not a slot on `head`, deliberately: adding a slot is a struct
LAYOUT change, which this SBCL refuses to redefine (\"STRUCTURE-OBJECT class …
incompatibly\") and which therefore needs a restart — the one thing a live push
must not need. A global costs nothing here because there is one head per
process, and it can be introduced by the same push that uses it.")

(defvar *paint-lock* nil
  "Serialises PAINTING against a live redefinition.

Without it a push races the frame: the hack thread evals a `defun` while the
main thread is halfway through `%render-and-paint`, so an in-flight call can
reach a function whose definition just changed under it — an arity or type
mismatch in the MAIN thread, which with `--disable-debugger` quits the process.
That is what killed the operator's head twice while `--tree` pushed, at a
different file each time: the signature of a race, not of a bad file.

So a push takes this lock for the whole eval and the paint takes it for the
whole frame. A push therefore waits for the frame in flight to finish, and a
frame waits for the push. Lazy so that it can be introduced by a push itself —
a mutex made at load time is not in a frozen image's heap the same way.

**An eval must not paint.** Taking this lock inside an eval deadlocks, which is
the one thing a hack surface must never do.")

(defun paint-lock ()
  "The paint/redefinition mutex, made on first use. See `*paint-lock*`."
  (or *paint-lock*
      (setf *paint-lock* (sb-thread:make-mutex :name "leticl paint"))))

(defun %paint-failure (head condition)
  "Draw the failure instead of dying of it.

Everything here runs on the MAIN thread, and with `--disable-debugger` an error
in the main thread QUITS the process. So one bad row — a plist that changed
shape, a push that half-landed — is not a wrong frame, it is a dead head: the
operator loses the session, the screen, and the value of the whole exercise.

A head that can be restyled while it runs must survive being restyled wrongly.
So a render error becomes a frame that says so, and the loop carries on: the
mistake is visible on the screen it broke, and `tui-eval --tree` after a fix
repairs it in place. Never silent — a swallowed error would put the head back
in the state where the gate says green and the screen is wrong, which is the
defect this file's neighbours exist against."
  (ignore-errors
    (let ((out (%open-stdout))
          (lines (list (list (cons " render failed — the head is alive; fix and re-push "
                                   '(:bold t :fg :red)))
                       (list (cons (format nil "  ~a" (type-of condition))
                                   '(:fg :yellow)))
                       (list (cons (format nil "  ~a" condition) '(:dim t))))))
      ;; a minimal frame drawn by hand: the cell buffer cannot be trusted to
      ;; render the failure of rendering itself
      (ignore-errors
        (screen-clear (head-screen head))
        (%place-lines (head-screen head) lines 0
                      (max 0 (- (head-rows head) 3)) (head-cols head))
        (paint-full (head-screen head) out))
      (ignore-errors
        (setf (head-last-rows head) (screen-rows-ansi (head-screen head))
              (head-last-cols head) (head-cols head)
              (head-last-rows-n head) (head-rows head)))
      (ignore-errors
        (replace (screen-cells (head-prev-screen head))
                 (screen-cells (head-screen head)))))))

(defun %render-and-paint (head)
  "Render and paint, and do not die of it.

The whole body is guarded because this is the MAIN thread: with
`--disable-debugger` an unhandled error here does not print a backtrace and
carry on, it quits. A live push that leaves one bad row therefore costs the
head — measured, twice — which makes `--file` unusable as a way to work. A
failure now paints itself and the loop continues.

And it holds `paint-lock` for the whole frame, so a live redefinition cannot
land in the middle of one. Without that, a push races the paint and an
in-flight call reaches a function that changed under it — an error in the main
thread, which is a dead head. `--tree` takes the same lock per file."
  (sb-thread:with-mutex ((paint-lock))
    (handler-case
        (progn
          (%render head)
          ;; reacquire the stream if a live push clobbered it: a frame written to
          ;; NIL is a type error in the main thread, which quits the head
          (let ((out (%open-stdout)))
            (if (head-full-repaint head)
                (progn (paint-full (head-screen head) out)
                       (setf (head-full-repaint head) nil))
                (paint-diff (head-prev-screen head) (head-screen head) out))
            (replace (screen-cells (head-prev-screen head)) (screen-cells (head-screen head)))
            (setf (head-last-rows head) (screen-rows-ansi (head-screen head))
                  (head-last-cols head) (head-cols head)
                  (head-last-rows-n head) (head-rows head))
            ;; **The caret is the painter's, and only the painter's.** This
            ;; moved the cursor HERE, after the frame — to the last row, the hint
            ;; bar's, at the width of the whole buffer — and never sent `?25h`,
            ;; so the terminal kept the `?25l` from startup and the composer had
            ;; no caret at all while an invisible one sat on the wrong row. The
            ;; operator: *"prompt input doesnt have caret or cursor"*. Measured
            ;; after the fix: tmux reported our pane's cursor at (2,62) and
            ;; letibot's at (6,60) on the same screen.
            )
          ;; a GOOD frame clears the flag, so a fixed head goes green again
          ;; without a restart — which is the whole point of pushing a fix
          (setf *last-render-error* nil))
      (error (e)
        ;; remember it (the gate reads this) AND draw it (the operator reads it)
        (setf *last-render-error* e)
        (%paint-failure head e))))
  (setf (head-dirty head) nil))


