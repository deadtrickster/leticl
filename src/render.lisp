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

;;; ------------------------------------------------------------ rendering ;;;
(defun segs-text-of (line)
  "A segment-line's text, for asking whether it renders as nothing."
  (if line (format nil "~{~a~}" (mapcar #'car line)) ""))

(defun %white-char-p (ch)
  "Every character that occupies columns without saying anything.

**`#\\space` ALONE IS NOT THE QUESTION, and the cost was a hole on the operator's screen.**
Measured 2026-09-26: an assistant row whose text is `\"  \\n \"` rendered as ONE line that this
file did NOT consider blank — because the character it tripped over is a NEWLINE — so the row
earned the air rule's separator AND drew its own whitespace-only line. **Two screen lines for a
row with nothing in it**, which reads as a gap in the transcript: the operator's *\"line just
disappeared lol, hole on the screen\"*.

A tab counts for the same reason a space does: it is columns nobody can read. So does a carriage
return, which a dialect may leave in a stream."
  (member ch '(#\space #\tab #\newline #\return #\page) :test #'char=))

(defun %line-blank-p (line)
  "Does LINE render as nothing — every segment's text whitespace or empty? The
question `%viewport-lines` asks of every line of every row it places, each
frame; it used to be asked through `format nil` and `string-trim`, which is two
copies per line to learn one bit.

See `%white-char-p` for why the answer is not `(char= ch #\\space)`."
  (every (lambda (seg)
           (let ((text (car seg)))
             ;; a non-string prints as its name under `~a`, which is not blank
             (and (stringp text)
                  (every #'%white-char-p text))))
         line))

(defun item-row-class (item)
  "Which KIND of row this is, for the one question the layout asks of its
neighbours: does a blank line belong between them. The reference's `RowClass`."
  (let ((body (item-body item)))
    (if (null body)
        :other
        (case (intern (string-upcase (getf body :type)) :keyword)
          ;; **A user-kind row is Speech for BOTH `operator` and an absent speaker** (the additive
          ;; rule, R42): the class is what the layout reads for *does a blank line belong between
          ;; these two*, and a row that predates the field draws exactly as it always did — block
          ;; and all. A row this session appended, and one naming a speaker this build cannot read,
          ;; is `:other`: it is not somebody in the conversation speaking, and its air says so.
          ;; letibot draws its `agent` rows as `RowClass::Other` for the same reason.
          ((:user) (let ((who (%user-speaker body)))
                     (if (or (eq who :operator) (eq who :unrecorded)) :speech :other)))
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

(defun %hist-live-tick (head cols)
  "A value that changes while a COMMITTED row's content is a function of the CLOCK.

**The cache was the other half of the operator's complaint, and it was the half that made
the first fix invisible.** They watched a two-minute `cargo test` and saw the same row the
whole time; the row was then drawn `→ Ran … · no result`, and after that was fixed it STILL
did not move — because `%hist-key` is `(generation cols items-vector)`, and **none of those
three changes when a call starts or while it runs.** A call starting is not an event folded,
the items vector is the same vector, and the width is the width. So the cache answered with
the lines it had built before the call began, for the whole of the call, and the paragraph
that says *the clock starts when the command starts* had no display to stand on.

**Only a RUNNING CALL needs this**, and it is worth being narrow about it. The other
clock-driven parts of a frame — the composer's spinner, the carry line, a deadline countdown
— are drawn from the session and the panes, not from a transcript row, so they never went
through this cache and do not want it bypassed. A running call is the only case where a
COMMITTED row's text is a function of the clock.

A TENTH, because that is the resolution the number has: `%live-elapsed-ms` rounds to 100 ms,
and `+live-frame-ms+` is 100 ms, so the head rebuilds this frame ten times a second anyway
while a call runs. Measured on this head at 3,693 items: **2.8 ms per rebuild**, and only
while a call is actually running — `%history-until` walks back from the newest row and stops
when the viewport is full, so the cost is the window and not the session."
  (let ((turn (session-turn (head-session head))))
    (when turn
      (or
       ;; a CALL RUNNING: the clock, because a committed row draws a live duration
       (when (some (lambda (c)
                     (string= (or (getf (getf c :state) :state) "") "running"))
                   (getf turn :calls))
         (floor (internal-real-time-ms) +live-frame-ms+))
       ;; **AND THE MODELS THINKING: the LINE COUNT, NOT the clock.** This is the other case where
       ;; a committed row text is a function of something that is not an event -- a marker reading
       ;; `[2 tool calls, 43 thinking lines]` is a function of the reasoning text -- and it is the
       ;; half the gate was missing, so the count sat in the cache until an unrelated invalidation
       ;; happened to land. The operator: *"they backfill randomly at the latest [ ] stats block"*,
       ;; and then the control that proved it: *"1 tool call saved it - the stats appeared
       ;; immediately after the prompt"* -- live while a call ran, backfilled while it thought.
       ;;
       ;; **NOT the clock, and that is the whole point of using the count here.** Moving the tick to
       ;; the clock for this case was tried and reverted: the tick own docstring measures the cliff
       ;; it creates -- a HIT is 0.2 ms, a MISS is 11-13 ms -- and ten of those a second for the whole
       ;; of a long think is visibly an animation in the composer. A LINE COUNT changes only when a
       ;; screen line wraps, which is a handful of times a minute rather than ten times a second, so
       ;; the count stays live for a fraction of that cost. Keying on counts was recorded as wrong
       ;; one screen up, and it was: for the CALL case, where the row draws a duration. It is exactly
       ;; right for this one, where the row draws a number.
       (let ((r (getf turn :reasoning)))
         (when (and (stringp r) (plusp (length r)))
           (reasoning-line-count r (max 20 (- cols (activity-indent cols))))))))))

(defun %hist-key (head cols)
  "Generation, width, the IDENTITY of the items vector, and the live tick.

**Four things, because no three of them are enough.** The first version was
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
place leaves the vector and its count identical, and that case is the generation's.

**And the tick, because a running call is the fourth way a row changes with no event at
all** — see `%hist-live-tick`, which is NIL whenever nothing is running and so costs the
ordinary frame nothing.

**THE TICK IS A MEASURED 50x CLIFF, AND IT HAS TO STAY UNTIL THE CACHE SPLITS.** At the operator's
2075-item session: a cache HIT is 0.2 ms per render and a MISS is 11-13 ms, walking ~2017 lines — and
while a call runs the tick changes ten times a second, so EVERY frame is a miss. That is the remaining
sluggishness.

I tried keying on the in-flight COUNTS instead of the clock — which is what the marker's own text is
made of (`[2 tool calls, 43 thinking lines]`), so it looked like the honest key — and it is WRONG, for
a reason worth recording: **a COMMITTED row draws a live duration.** `cards.lisp:3049` renders a
running call's committed row as `◐ {Verb} {subject} · 1.2s` through the same `call-lines` the turn pane
uses, so a key that does not move with the clock FREEZES that timer at whatever tenth it was built on.
The operator reported exactly that symptom once already, which is why the tick is here.

So the fix is not a coarser key — it is the SPLIT the operator named: *\"only the most recent line
changes… the composition of previous conversation can be cached.\"* The walk must be cacheable as a
SETTLED PREFIX plus a rebuilt TIP, with the tick invalidating only the tip. That is a change to
`%history-until`'s walk, not to this key.\""
  (list *hist-generation* cols (session-items (head-session head))
        (%hist-live-tick head cols)))

(defun %hist-key= (a b)
  "Two keys equal on the two numbers, the vector's IDENTITY, and the live tick."
  (and a b
       (= (first a) (first b))
       (= (second a) (second b))
       (eq (third a) (third b))
       (eql (fourth a) (fourth b))))

(defvar *live-counts-seen* nil
  "The `(:calls N :thinking M)` the last walk armed the live marker with.

**LETIBOT'S OWN ANSWER TO THE SAME DEFECT, AND IT IS A COMPARISON RATHER THAN A CACHE TEST.**
`letibot`'s walk bakes the marker -- counts and all -- into its cache of rendered rows, so nothing in
it moves when the live counts move, because the counts are not rows. Their comment says it exactly:

    *the number is BACKFILLED, and what fills it is the arrival of a ROW -- the first non-thinking
    line -- which invalidates the cache and re-renders the marker with whatever the counts had become.*

and their fix is to remember the counts and invalidate **the one row the live work belongs to** when
they change: *what is invalidated is one run, not the transcript.* `self.marker_counts` is this value.

leticl had no such comparison. It had `live-pending`, which is `(and live (not cached) t)` -- ALL OR
NOTHING, and off on every cache HIT. So on a hit the marker was served stale from the cache (the count
frozen at whatever the frame that built it had), and on a miss the live counts were re-armed onto the
newest row. Two different renderings of the same counts, decided by the cache, and the marker's HEIGHT
differed between them -- which is the flash this path has been chasing all night.

A `defvar`, so a push can introduce it.")

(defun %history-until (head cols need &optional until-id)
  "The committed transcript's lines, oldest first, at least NEED of them.

Cached: a call that needs no more than the cache holds does no rendering at all,
which is the case that matters — scrolling.

**UNTIL-ID is R36's anchor row, and the walk must reach it.** The window is `need` lines measured
back from the newest row, which is right for a reader at the bottom and WRONG for a reader parked
on a row: rows arriving below push the anchored row outside that window, `%anchor-end` then finds
nothing, and the view silently falls back to the count — which is the defect the anchor exists to
prevent, reintroduced from the other end. Measured: a 40-row transcript scrolled to `row-38`, then
thirty rows appended, and the view jumped to `row-62`."
  (let* ((key (%hist-key head cols))
         (s (head-session head))
         ;; **WHICH RUN IS THE NEWEST**, for the seam's own wording (R40): the newest run's names
         ;; `ctrl-t`, and every other run's names `/verbosity`, the verb that does reach it. Computed
         ;; once from the SESSION (the unjoined items), because the run the walk flushes is a slice of
         ;; whichever vector it was handed.
         (newest-run (newest-hidden-run-id s))
         (items (let ((raw (session-items s)))
                  ;; **R37's open question, as a switch** - see `%reading-joined-items`: with it on,
                  ;; a narration and the report it points at are ONE paragraph rather than two.
                  (if *reading-join-prose* (%reading-joined-items raw cols) raw)))
         (cached (and *hist-cache* (%hist-key= key (first *hist-cache*)) *hist-cache*))
         (lines (if cached (second cached) nil))
         (next-i (if cached (third cached) (1- (length items))))
         (class-above (if cached (fourth cached) nil)))
    ;; **THE BOUNDS ARE COLLECTED IN THE SAME WALK** (R36): which ROW each stretch of lines
    ;; came from, so a line can be named as *this row, this offset into it* rather than as a
    ;; count. A second pass over the items would have to reproduce this walk's air rule (a
    ;; blank line before a class change) and would disagree with it the first time the rule
    ;; moved — the arithmetic that decides which row a line belongs to is the arithmetic that
    ;; decided what the lines are.
    ;; **A `let*`, because `live-pending` is bound FROM `live`** — in a `let` the init forms are
    ;; evaluated in the enclosing environment, so the second would have read the global `live` and
    ;; the head died on `The variable LIVE is unbound` at the first frame.
    (let* ((bounds (if cached (fifth cached) nil))
          (raw nil)
          ;; **THE RUN OF HIDDEN ROWS** (R37 amended): consecutive items this rung hides, counted
          ;; here because this is the function that turns a SEQUENCE of items into lines and a run
          ;; is a property of the sequence. `item-lines` cannot see it — it is handed one item.
          (run nil)
          ;; **THE WORK STILL IN FLIGHT** (the operator's *"nothing for awhile while you write a
          ;; tool call and tool executes … otherwise it looks like you hanged"*). A run is defined by
          ;; ROWS, and a call that has not returned has none — so the window between the colon and the
          ;; first result row is a window this rung draws nothing in. See `%hidden-run-live-work`.
          ;;
          ;; It belongs to the NEWEST row the reader can see, which the walk reaches FIRST (it runs
          ;; newest to oldest), so one flag is the whole of the bookkeeping.
          (live (%hidden-run-live-work (session-turn s) cols))
          ;; **AND NOT ON A CACHE HIT.** A hit means the newest rows — the row the live work rides
          ;; on among them — are already in `lines`, drawn with the marker they had; the walk that
          ;; follows only EXTENDS downward into older rows to fill the screen. Re-arming this flag
          ;; there put the in-flight counts, and the yellow, on the first OLD row the extension
          ;; reached: a settled counter from an earlier turn lit up while a call ran. The live
          ;; marker's freshness on a hit is `%hist-live-tick`'s job, which is in the key.
          ;; **RE-ARMED WHEN THE COUNTS CHANGE, WHICH IS LETIBOT'S RULE.** `(not cached)` alone
          ;; means a hit never refreshes the marker, so the count sat frozen until a real row
          ;; arrived and invalidated the cache -- the operator's *"backfilled after the first
          ;; non-thinking line"*, verbatim. Comparing against what the last walk armed with is
          ;; what makes the count LIVE without putting in-flight figures on an old row: the flag
          ;; still only rides the newest row, and it now rides it on the frame the number moved.
          (live-pending (and live
                             ;; **ARMED ON A MISS *OR* WHEN THE COUNTS MOVED** — letibot's rule.
                             ;; `(not cached)` alone means a hit never refreshes the marker, so the
                             ;; count sat frozen until a real row arrived and invalidated the cache:
                             ;; the operator's *"backfilled after the first non-thinking line"*,
                             ;; verbatim. What it must NOT become is `live` itself — this flag is
                             ;; SPENT (set to nil) by the first row that carries the marker, which is
                             ;; what keeps one marker on the row the turn is at instead of one per
                             ;; visible row.
                             (let ((moved (not (equal live *live-counts-seen*))))
                               (setf *live-counts-seen* live)
                               (or (not cached) moved))))
          ;; **IS THE TURN STILL WORKING** — the COUNTS' question is `live` (what is in flight) and
          ;; the COLOUR's is this: a call finishing and the next round's first delta arriving are
          ;; two events, and between them `live` is nil while the turn runs on. Keying the yellow on
          ;; `live` made it flicker off mid-turn — *"running tool is no longer yellow the counter,
          ;; wtf why it regressed."*
          (busy (and (session-turn s) (turn-busy-p (session-turn s)))))
    (loop while (and (>= next-i 0)
                     (or (< (length lines) (1+ need))
                         ;; **the anchor's row has not been reached yet: keep walking down to it.**
                         ;;
                         ;; **AND IT SEARCHES `raw`, NOT `bounds` — which is a bug this line had, and it
                         ;; cost 11 ms on every frame of a scrolled-up reader.** `bounds` is DERIVED
                         ;; from `raw` after this loop (see the `mapcar` at the end); during the walk
                         ;; it is NIL on every miss. So the search over `bounds` was always NIL, the
                         ;; condition was always true, and the anchor never stopped the walk — every
                         ;; miss walked the WHOLE transcript down to the oldest row.
                         ;;
                         ;; MEASURED at the operator's 2075-item session, 63x210:
                         ;;
                         ;;     cache MISS with the anchor reachable   11 ms  (2017 lines)
                         ;;     cache MISS with no anchor at all      0.2 ms
                         ;;
                         ;; and the anchor is passed only when `head-scroll` is positive, so this was
                         ;; paid by a reader SCROLLING UP and never by one at the bottom — which is
                         ;; exactly the shape of the complaint (*"scroll feels sluggish"*) and why it
                         ;; survived: the bottom of the transcript was always fast.
                         ;;
                         ;; A HIT hid it completely, because a hit returns the cached lines without
                         ;; entering the loop at all. So the cost appeared only when the cache was
                         ;; cold — a resize, a generation bump, and the live tick's ten changes a
                         ;; second while a call runs, which is the window the operator watches.
                         ;;
                         ;; `raw` entries are `(item-id . (start . end))`, hence `:key #'car`.
                         (and until-id
                              (not (find until-id raw :key #'car :test #'string=)))
                         ;; **and a run in hand is finished before the window stops.** A reader
                         ;; whose viewport ends inside a run of hidden work must still be told how
                         ;; much of it there was; a marker dropped for being past `need` is a run
                         ;; that vanishes at the edge of the screen.
                         run))
          ;; **ONE `do` FORM, AND IT IS A `progn`.** `loop`'s `do` takes MANY forms, and each is
          ;; a body form — so `do (let* …) (decf …)` reads as though the `decf` merely FOLLOWS the
          ;; `let*` while both are inside the loop, and a form written after them is inside it too.
          ;; Measured, and it is not a style point: the block that draws a run's marker was such a
          ;; form, so the marker fired ONCE PER HIDDEN ROW — the very wall this rung exists to
          ;; abolish. The `progn` says where the body ENDS, so what is written after the loop is
          ;; after the loop.
          do (progn
               (let* ((item (aref items next-i))
                      (il (item-lines item cols (head-prefs head)))
                      (class (item-row-class item))
                      ;; **ONE ANSWER TO *IS THIS ROW ON THE SCREEN*** — the same predicate
                      ;; `newest-hidden-run-id` cuts the run with, so the run the walk flushes and the
                      ;; run the seam names cannot disagree about their extent.
                      (blank (%row-invisible-p item cols)))
                 (cond
                   ;; **HIDDEN: it joins the run** and contributes no lines of its own.
                   ((reading-hides-p item)
                    (push item run))
                   ;; **A ROW THIS RUNG DOES NOT DRAW IS INVISIBLE TO THE RUN** (R37 amended).
                   ;; It neither joins a run nor ENDS one. Prose the reader can SEE ends a run; an
                   ;; empty assistant part, a whitespace-only text row, or any item whose only
                   ;; content this rung hides does not. **Contiguity is a property of the RENDERED
                   ;; SCREEN, not of the item list** — computing it over the list broke one turn's
                   ;; work into eight markers with no prose between any of them, which is the wall
                   ;; this rung exists to abolish, now with brackets.
                   ;;
                   ;; It still gets a bounds entry, so an anchor parked on it is not called lost.
                   (blank
                    (push (cons (getf item :item-id) (cons (length lines) (length lines))) raw))
                   ;; **A ROW THE READER SEES.** The run of NEWER hidden rows belongs to its prose:
                   ;; its counts end this row's last line, so the sentence the row closes on runs
                   ;; into the numbers (R37 final). A run still in hand when the walk ends has no
                   ;; visible row older than it and stands on its own line below.
                   (t
                    (let* ((open (and run (equal (%hidden-run-id run) *hidden-run-open*)))
                           (newest (and run (equal (%hidden-run-id run) newest-run)))
                           ;; **THE COUNTS CONTINUE THE MODEL'S SENTENCE AND NOTHING ELSE** (R37
                           ;; final): only an assistant row with visible text takes them. See
                           ;; `%run-continues-prose-p` for the screen that named the rule.
                           ;;
                           ;; **AND LIVE WORK CARRIES THE SAME MARKER ON THE SAME ROW — WHEN THAT
                           ;; ROW IS ONE THE COUNTS MAY CONTINUE.** The row live work rides on is the
                           ;; newest row the reader can see (`live-pending`, taken once), and when that
                           ;; row is the narration the model just wrote, the call it is running for hangs
                           ;; off the end of it — the shape the operator asked for.
                           ;;
                           ;; **BUT NOT WHEN IT IS THEIR OWN MESSAGE, AND THAT IS WHAT `live-here` USED
                           ;; TO FORCE.** The second clause was `(or live-here (%run-continues-prose-p
                           ;; item))`, so ONE FRAME WITH WORK IN FLIGHT made any row the counts' carrier —
                           ;; including the operator's own message, which is drawn as a bar padded to the
                           ;; frame's width (MEASURED: 172 columns of 172 at their terminal, the
                           ;; timestamp right-aligned at its edge). The join is then refused, because
                           ;; there is no room on a full line, and `%marker-onto-last-line` came back
                           ;; with the row unchanged — while `glue` was already true, so the standalone
                           ;; branch below was skipped and the counts were drawn NOWHERE.
                           ;;
                           ;; The screen the operator watched, and the words that name this defect:
                           ;; *"your own stats flashes after my prompt."* The block came and went
                           ;; because the carrier row changes as work lands — their message, which
                           ;; cannot take the counts, then a note or a narration, which can. So the join
                           ;; asks ONE question now, the same one the marker's own rule has always asked
                           ;; (`%run-continues-prose-p`: *only the MODEL's own prose carries a run's
                           ;; counts*), and a row that cannot take the counts does not try: the marker
                           ;; stands on its own line, which is what a run with no sentence above it has
                           ;; always done.
                           ;; **AND THE MARKER'S ROW DOES NOT DEPEND ON THE CACHE.** This was
                           ;; `(and live-pending live)`, and `live-pending` is `(and live (not cached) t)` --
                           ;; deliberately nil on a HIT, so that a hit does not re-arm the live counts onto a row
                           ;; that already carries them. Sound for the count's FRESHNESS. It also made the
                           ;; marker's HEIGHT depend on whether the history cache happened to be warm: on a hit
                           ;; `live-here` was nil, `glue` fell through, and the marker took the standalone path --
                           ;; marker plus a blank each side, three rows -- while the miss frame glued the same
                           ;; counts onto a row for NOTHING. Same counts, two heights, decided by a cache.
                           ;;
                           ;; The operator watched it happen and named the shape without the code: *"is 'That
                           ;; intuition ...' I see the lisp snippet, and then [113 thinking lines] appears below
                           ;; the prompt and above 'That intuition...'"* -- the marker on its own line, under
                           ;; the prompt, between the two. So `live-pending` keeps the job it was written for,
                           ;; which is whether the counts need RE-ARMING, and it no longer decides whether the
                           ;; marker gets a row of its own.
                           ;; and the counts this walk stands behind, so the NEXT frame can tell whether they moved
          (live-here (and live-pending live))
                           (glue (and (not open)
                                      (or run live-here)
                                      (%run-continues-prose-p item)))
                           (marker-items (or run nil))
                           ;; **IS THIS MARKER'S NUMBER STILL GOING UP?** — the colour's question, and it is NOT
                           ;; *is the turn running*: the walk draws a marker for EVERY run in the transcript, so
                           ;; keying on the turn alone lit up a turn's whole history behind it (*"all tool call
                           ;; counters are yellow now"*). Two things must both hold: the turn must still be
                           ;; running, and this must be the LIVE EDGE — the newest run, or the row live work
                           ;; rides on (which is `live-here`, and can be set with no run at all while a call is
                           ;; in flight and its results have not landed).
                           (rising (marker-rising-p busy live live-here))
                           ;; **THE SENTENCE WRAPS AT THE FRAME'S OWN WIDTH, NOT AT `cols - room`.**
                           ;;
                           ;; Reserving the marker's room from every line was the second version of this
                           ;; and it bought stillness at a price the operator refused: their prose broke
                           ;; early for a marker that is almost never that wide. Measured at 210
                           ;; columns, the sentence wrapped at 154 while the tail needed 55:
                           ;;
                           ;;     Let me confirm where the
                           ;;     committed history sits: [1 tool call, 23 thinking lines]
                           ;;
                           ;; *"there is no need to have the line break here because the whole tail
                           ;; fits. you didnt try the 'tool calls' -> 'tools' -> 't' progressing. so I
                           ;; complain about line wrapping here."*
                           ;;
                           ;; So the room is spent where it is needed and nowhere else: the prose is
                           ;; rendered at `cols`, and `%marker-onto-last-line` fits the marker to what
                           ;; the LAST line has left, stepping down `+hidden-run-marker-ladder+` if it
                           ;; must. Every line above it is untouched, which is also why nothing jumps:
                           ;; an earlier line cannot be affected by a marker that lives on the last
                           ;; one.
                           ;; **TWO ANSWERS, BECAUSE THE TWO REFUSALS ARE DIFFERENT.** `glue` nil means
                           ;; *this row was never the counts' to carry*; `glued` nil with `glue` true
                           ;; means *it was, and the sentence's last line had no room* — and the second
                           ;; falls to the standalone branch rather than losing the counts. letibot's own
                           ;; shape: `match joined { Some(line) => …, None => (Activity, vec![painted]) }`
                           ;; — *counts with no sentence are still the fact.*
                           (joined (if glue
                                       (multiple-value-list
                                        (%marker-onto-last-line
                                         (item-lines item cols (head-prefs head))
                                         marker-items cols (and marker-items newest) live-here rising))
                                       (list il nil)))
                           (il (first joined))
                           (glued (second joined)))
                      ;; **an OPEN run draws its rows between this row and the newer one** — this
                      ;; row is prepended after them, so they land in the gap the counts would have
                      ;; filled. They are real lines now, and the anchor may name them.
                      (when (and run open)
                        (let ((rb (length lines)))
                          (setf lines (append (hidden-run-lines run cols) lines))
                          (dolist (it run)
                            (push (cons (getf it :item-id) (cons rb (length lines))) raw))))
                      ;; **a run that cannot glue stands on its own line, WITH THE BLANK
                      ;; PROSE GETS** — the operator asked for exactly that empty line (*"add an empty
                      ;; line between them"*), and it is what says the counts are not part of the
                      ;; sentence above them.
                      ;;
                      ;; **AND ON BOTH SIDES OF IT.** The blank above was the first half and it was not
                      ;; enough: the operator's screen showed the counts separated from THEIR message
                      ;; and then glued to the model's report — `[2 tool calls, 31 thinking lines] ·
                      ;; /verbosity` running straight into `You're right, and it is a fair hit.`
                      ;; **The report keeps its paragraph break** wherever the marker went, and with
                      ;; the marker glued into the model's own sentence that break arrives for free
                      ;; (the air rule's blank lands after the counts, because the counts are at the
                      ;; END of that row) — so a standalone marker has to supply it, or the report's
                      ;; air would depend on which side the marker happened to land.
                      ;;
                      ;; **One blank each side and never two.** The air rule below supplies its own
                      ;; blank above when the class changes, so ours is added only when it will not:
                      ;; two nils there is the hole the first cut of this measured.
                      ;; **AND THE COLOUR IS `rising`, WHICH IS NOT `busy`.** This call site handed
                      ;; the marker the TURN's own state for as long as it existed, so every
                      ;; STANDALONE marker — a run whose counts do not continue a sentence — went
                      ;; yellow for the whole of every turn. The operator reported it twice in the same
                      ;; words: *"all tool call counters are yellow now"*, and later *"al tool calls
                      ;; stay yellow sometimes"*. MEASURED on their screen, a fresh build of their own
                      ;; transcript had FIVE markers yellow where exactly one — the newest run — is
                      ;; the live edge.
                      ;;
                      ;; **The `sometimes` is this branch and not the turn.** The GLUED path was
                      ;; fixed (`%marker-onto-last-line` takes the narrowed answer), so only the runs
                      ;; that do NOT glue to prose were lit — which is why one frame showed four
                      ;; markers and the next showed one, and why the same transcript renders
                      ;; differently as its prose changes.
                      ;;
                      ;; `rising` is bound once above, so there is nothing to narrow here a second
                      ;; time. **And the guard for it is now STRUCTURAL**, because the string-anchored
                      ;; version forbade a SPELLING — `(hidden-run-marker run cols newest nil nil
                      ;; busy)` — and this is the same bug, written another way.
                      (when (and (or run live-here) (not open) (or (not glue) (not glued)))
                        (let* (;; **THE BLANK ABOVE IS THE AIR RULE'S, and this must not add a
                               ;; second one.** The walk prepends OLDER rows, so at this moment the
                               ;; row that will sit above the marker has not been seen yet — a blank
                               ;; added here is on the marker's NEWER side, and the air rule then adds
                               ;; its own when the older row arrives: measured, two blanks between the
                               ;; operator's own message and the counts, which is one too many. The
                               ;; separation above is bought by `class-above :other` below instead.
                               (prefix (append
                                        (list (hidden-run-marker marker-items cols (and marker-items newest) live-here nil rising))
                                        ;; the blank BELOW is this branch's to add: the row under it
                                        ;; has already been drawn (`lines` holds it), so nothing else
                                        ;; will supply the break.
                                        (when lines (list nil))))
                               (rb (length lines))
                               ;; the marker's own line, in the newest-end numbering the walk
                               ;; accumulates in — the bounds flip it with everything else
                               (at (+ rb (1- (length prefix)))))
                          (setf lines (append prefix lines)
                                ;; **AND THE MARKER IS NOW WHAT THE NEXT ROW SITS UNDER** — its own
                                ;; class, `:other`, or the air rule has nothing to compare with. The
                                ;; walk's `class-above` was the last VISIBLE row's, which is not the
                                ;; frontier any more: the marker is. Without this a report arriving
                                ;; after a marker at the TOP of the screen was glued to it, because
                                ;; there was no earlier visible row to have set a class at all —
                                ;; measured as `[1 tool call…]` then the report with no blank, which
                                ;; is the operator's `[] … glued together` shape one case further out.
                                class-above :other)
                          (dolist (it run)
                            (push (cons (getf it :item-id) (cons at (1+ at))) raw))))
                      (let ((before (length lines)))
                        (when (and lines class-above
                                   (not (and (eq class :activity) (eq class-above :activity))))
                          (setf lines (cons nil lines)))
                        (setf class-above class)
                        ;; `append`, NOT `revappend`. `(append il lines)` copies IL — the
                        ;; one item just rendered, a handful of lines — and SHARES the
                        ;; accumulated tail, so it is O(len il) and the walk is linear.
                        ;; `revappend` is `(append (reverse il) lines)`: it reverses the
                        ;; item's own lines as well, so every tool card rendered
                        ;; upside-down. Measured: a six-line payload came back
                        ;; `line 6 … line 1` with the header last.
                        ;;
                        ;; An earlier comment here claimed `append` was O(depth²). It is
                        ;; not, and acting on that claim is what introduced the reversal —
                        ;; the quadratic copy was in `%viewport-lines`' `(append hist …)`,
                        ;; which `%window-of` fixed.
                        (setf lines (append il lines))
                        ;; `before` to `(length lines)` is THIS row's stretch, blank line included —
                        ;; **counted from the NEWEST end**, because that is how the walk accumulates,
                        ;; and `raw` holds them that way until the total is known and they can be
                        ;; flipped. INSIDE the `let`, because `item` is what names it: one line lower
                        ;; it was outside the binding and every render died on an unbound variable.
                        (push (cons (getf item :item-id) (cons before (length lines))) raw)
                        ;; **a CLOSED run's rows anchor to the line its counts were appended to** —
                        ;; this row's last line, which is the nearest surviving row by construction
                        ;; (R36). Without this an anchor parked on a hidden row finds nothing and the
                        ;; view silently falls back to the count.
                        (when (and run (not open))
                          (dolist (it run)
                            (push (cons (getf it :item-id) (cons before (1+ before))) raw))))
                      ;; **THE RUN IS SPENT** — this row's own prose now carries its counts, so the
                      ;; next hidden row begins a NEW run. Without this the run never clears and
                      ;; every visible row after it takes the same marker again: three markers on
                      ;; one screen, which is the eight-marker wall one notch quieter.
                      (setf run nil)
                      ;; **and the LIVE marker is spent with it.** This is the newest row the reader
                      ;; can see; every row below it is older, and work in flight does not belong to
                      ;; the middle of a transcript. One marker, on the row the turn is at.
                      (setf live-pending nil))))
               (decf next-i)))
    ;; **THE OFFSETS ARE FLIPPED TO OLDEST-FIRST HERE**, once the total is known: a row whose
    ;; stretch ended `e` lines from the newest end starts `total - e` lines from the oldest, and
    ;; that is the numbering the viewport and the anchor both speak in. The first cut stored the
    ;; newest-end numbers and the anchor then computed a position 30-odd lines out — measured as
    ;; a view that jumped to the live end.
    ;; **ONLY ON A MISS.** A cache hit brings its own bounds and leaves `raw` NIL, and the first
    ;; cut recomputed from `raw` unconditionally — which wiped the cached bounds on the second
    ;; frame of every cache, so the anchor worked on the frame that built the list and vanished
    ;; on the one after it. The measured symptom was a viewport that jumped to the live end.
    ;; **A RUN WITH NO SENTENCE TO CONTINUE STANDS ON ITS OWN LINE.** The only run that reaches
    ;; here is the very oldest thing in the transcript — nothing the reader can see is older than
    ;; it — so there is no narration for its counts to end. This is the one case the marker is a
    ;; row, and it is not the shape the operator's turn produces (prompt → narration → work →
    ;; report always has a narration above the work).
          ;; **`finally`, so the block runs AFTER the loop.** It was a second `do` form — `loop`'s
          ;; `do` takes many forms and each is a body form — which made the marker fire once per
          ;; hidden row. A `finally` clause cannot be a body form.
          finally (when run
                    (let* ((newest (equal (%hidden-run-id run) newest-run))
                           (before (length lines))
                           ;; **the SAME shape the in-walk flush lands** — the marker, and a blank
                           ;; below it whenever there is a row underneath. The two paths must
                           ;; agree or the report's paragraph break would depend on whether the
                           ;; run came first or last in the walk; measured, this path drew
                           ;; `[1 tool call…]` glued to the report while the other separated them.
                           (prefix (if lines
                                       (list (hidden-run-marker run cols newest nil nil (marker-rising-p busy live nil)) nil)
                                       (list (hidden-run-marker run cols newest nil nil (marker-rising-p busy live nil)))))
                           (at (+ before (1- (length prefix)))))
                      (setf lines (append prefix lines))
                      (dolist (it run)
                        (push (cons (getf it :item-id) (cons at (1+ at))) raw)))))
    (when raw
      (let ((total (length lines)))
        (setf bounds (mapcar (lambda (r)
                               (list (car r) (- total (cddr r)) (- total (cadr r))))
                             (nreverse raw)))))
    (setf *hist-cache* (list key lines next-i class-above bounds))
    (values lines bounds))))

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

(defvar *scroll-anchor* nil
  "WHERE THE READER IS READING: `(ITEM-ID . LINE-OFFSET-INTO-IT)`, or NIL at the bottom.

**R36's anchor, and the whole reason it is a row and an offset rather than a number.** A count
from the bottom is invalidated by every arrival — the transcript grew, so the same number names
different lines — and a count from the top by anything above being rewritten. Both happen here:
R29's remedy line grows a row, a warning's detail expands, a tail lands, a snapshot replaces the
whole list. With a row anchor none of that moves the reader by a line.

**It is written by the RENDERER, from the row it actually drew at the top**, and not by the key
handler: the key knows a number, and only the frame knows which row that number landed on. That
is also what keeps it honest across a resize, where every offset moves.

**Cleared at the bottom and only by an act that goes there** (`esc`, an explicit end, or enough
`PgDn`s): following the live end is a STATE, and arriving content must never return the reader to
it. `%anchor-end` is what re-finds it, `%anchor-forget` is what says a row is gone.")

(defvar *hist-bounds* nil
  "The rows the last `%history-until` rendered, oldest first, as `(ITEM-ID START END)`.

**Set by `%viewport-lines` and read by the anchor**, because a line index is only meaningful
against the list it was counted in: the bounds and the lines come out of one walk, so the answer
to *which row is line 812* is derived from the same arithmetic that made the lines.")

(defvar *anchor-lost-said* nil
  "The item id this head has already told the reader it can no longer carry.

**A flag rather than a note each frame**, because `%viewport-lines` runs on every paint: a loss
that repeated would be a status row nobody can read, which is the R29 defect one surface over.")

(defun %anchor-for (bounds index)
  "The `(ITEM-ID . OFFSET)` for line INDEX in BOUNDS, or NIL when the index is not in a row.

NIL for a line in the TAIL — the live turn, a queued echo, the carry line. Those are not rows
with an identity across a frame, so there is nothing to anchor to and the numeric scroll is the
honest fallback."
  (let ((hit (find-if (lambda (b) (and (<= (second b) index) (< index (third b)))) bounds)))
    (and hit (cons (first hit) (- index (second hit))))))

(defun %anchor-end (head anchor bounds want n)
  "The exclusive END this anchor asks for, or NIL when it cannot be placed.

**The row the reader was on is put back at the same offset**, which is the whole of R36's
arithmetic: the answer is *that row's start, plus how far into it they were, plus a window*. A
count would have to know how many lines arrived; this needs to know nothing."
  (declare (ignore head))
  (let ((hit (find-if (lambda (b) (string= (first b) (car anchor))) bounds)))
    (when hit
      (setf *anchor-lost-said* nil)
      (min n (+ (second hit) (cdr anchor) want)))))

(defun %anchor-lose (head anchor)
  "Say that the row the reader was on is no longer carried, once.

**A row that has been summarised away is SAID, not jumped over.** R36: *if it was summarised away,
SAY SO rather than jumping — the reader was looking at something no longer carried, and that is a
fact about their session.* A view that silently teleported is a view the reader cannot trust to be
where they left it.

**Called from the frame, and BEFORE the scroll clamp** — see the call site: a transcript that now
fits the window clamps the scroll to zero, and the first version detected the loss after that
clamp, which is the one case where the reader is guaranteed to be told nothing.

`head` is passed in and never `*head*`: the render path runs on a head a test built directly as
often as on the live one, and reaching for the global died with `expected-type HEAD, datum NIL` —
inside a render, which is the one place this tree cannot afford a guess."
  (unless (equal *anchor-lost-said* (car anchor))
    (setf *anchor-lost-said* (car anchor))
    (say head (format nil "the row you were reading (row ~a, ~d line~:p in) is no longer in this transcript — a compaction or a resync replaced it, so the view is holding its place as a count instead"
                      (car anchor) (1+ (cdr anchor))))))

(defun %anchor-observe (head start bounds)
  "Remember the row the frame has just drawn at line START; forget it at the bottom.

**At the bottom the anchor is NIL, and that is the STATE R36 is about.** Following the live end is
not a position — *a reader who scrolled up has left it and only an explicit act returns them* —
so the anchor is cleared by the frame that is genuinely at the bottom (which only a key that went
there can produce) and by nothing else. Content arriving below cannot clear it, because arriving
content does not move `start`."
  ;; **`head-scroll`, not `start`.** The first cut tested `(plusp start)`, and `start` is
  ;; positive on EVERY frame whose transcript is longer than the viewport — including the frame
  ;; at the very bottom, where the reader is following the live end. Measured by the test that
  ;; goes back to the bottom: it kept an anchor, so the next arrival would have carried the
  ;; reader away from the end they had just returned to. The state is `head-scroll`, because
  ;; that is the variable the keys move.
  (setf *scroll-anchor* (and (plusp (head-scroll head))
                             (%anchor-for bounds start))))

(defvar *scroll-max* 0
  "How far back the last frame let the reader scroll, in LINES — `n - want`, the value
the clamp itself uses.

**Stashed because the reader's own key cannot recompute it.** Whether a scroll has
reached the top of the transcript is `(>= (head-scroll head) *scroll-max*)`, and the
only thing that knows `n` (the transcript's total line count) is the renderer. A key
handler that re-derived it would be a second answer to the same question, which is how
two of them drift.

A `defvar`, so a push can introduce it, and it is read by `editor.lisp`'s scroll arms
to decide when the reader has asked for the rows above the window (`fetch-row-above`).")

(defvar *hist-depth* 0
  "How many SCREEN LINES of history the last frame asked the walk for.

**A GENERATION BUMP MUST NOT MATERIALISE LESS THAN THE LAST FRAME DID.** `n` — the line count that
`*scroll-max*`, the scroll clamp and the window are all taken from — is not the length of the
conversation. It is the length of what has been MATERIALISED: `%history-until` returns at least
`need` lines and stops, so on a CACHE HIT `lines` carries everything this session accumulated from
deeper walks, and on a CACHE MISS it starts empty and stops at `need`.

Measured on the operator's head, 2026-10-02, sampling `*scroll-max*` and `*hist-generation*` from
outside at 3 Hz across a settle:

    sample   scroll-max   hist-generation
        1        27          4007      steady
       43        19          4009      DROP of 8, generation +2
       85        27          4026      recovered
      155        34          4040
      157        48          4040      content GROWING, generation FLAT
      161        40          4044      DROP of 30, generation +4
      200      4605          4044      settled, full history

Growth does not bump; the drop does. Samples 155-160 are a reply streaming in — `scroll-max` climbs
34 to 70 with the generation flat at 4040 — and the only move in that window is the drop at 161,
exactly where the generation jumps 4040 to 4044. So the invalidation is the TRIGGER and the collapse
is that a frame rebuilt from scratch reports a transcript two or three lines long.

**The dips bottom at 2-3 because that is the tail plus the air row**, with a one-line tail.
Arithmetic, not a half-rebuilt cache: the walk is CORRECT, and was asked only for a viewport.

So this holds the DEPTH, not the content: after an invalidation the walk re-renders to the depth it
had, and `n` does not fall. It is a high-water mark for how much to ASK for, which is what keeps it
bounded — a cache HIT costs nothing, so a deep depth is paid for only on the frame after a bump,
which is the frame the reader is already looking at. Asking for less than the reader is looking at
is the defect this exists to stop.

A `defvar`, so a push can introduce it, and because it is a rendering hint rather than session state.")

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
         ;; **THE QUEUED PROMPTS ARE DRAWN LAST — BELOW THE LIVE TURN, AT THE BOTTOM.** See the
         ;; account at `tail` below for why this is where they belong and for the one version of
         ;; this that got it wrong.
         (tail (append
                ;; the running turn, then ITS FOOTER — the footer belongs to the turn and
                ;; sits under it, and only when the turn has actually ended
                (turn-lines (session-turn s) cols (head-prefs head))
                (turn-footer-lines (session-turn s) cols)
                ;; **THEN THE QUEUED PROMPTS — AT THE BOTTOM, WHERE THEIR ROWS LAND.**
                ;;
                ;; This order was changed once and changed back, and the measurement is why.
                ;; Drawn ABOVE the live turn, a queued message sits above the streaming reply —
                ;; and the row that replaces it lands BELOW that reply, because a round's answer
                ;; is committed before the step boundary appends the follow-up. Measured on one
                ;; head, one sequence:
                ;;
                ;;     reply streaming      row 4 = ▌ queued · Q2   row 6 = R2 the reply
                ;;     reply committed      row 4 = R2 the reply     row 6 = ▌ queued · Q2
                ;;
                ;; The message jumps DOWN past the reply. Below the turn it does not move at all:
                ;; the turn pane is empty by the time the row lands (the round's answer went to the
                ;; transcript), and an empty pane contributes no lines, so the echo's place and the
                ;; row's place are the same row.
                ;;
                ;; **The operator's earlier reading — *"rendered rightfully above the reply"* — is
                ;; about the reply that ANSWERS the message, and that reply is the NEXT round's,
                ;; drawn below it. The reply above is the one answering the PREVIOUS message, and a
                ;; queued row belongs under it because that is the order the transcript keeps.**
                ;; They settled it themselves: *"the queued messages must be still coalesced and
                ;; still pinned to the bottom."*
                (queued-lines head cols)
                ;; **AND THE ECHO CARRIES THE AIR A LANDED ROW HAS AFTER IT.** `hist` is followed by
                ;; one blank row (`gap`, below — *"air above the chrome"*), and a row that LANDS is
                ;; part of `hist`, so a committed row brings that blank with it. The echo in the
                ;; tail does not, and the frame gained one row when the row landed: measured, 7 rows
                ;; waiting and 8 landed, identical for their first seven. Nothing moved, which is
                ;; what the operator asked for, but the screen still grew by a line.
                (when (queued-lines head cols) (list nil))
                ;; AND THE CARRY LAST: `/reseat` and `/compact` announce every row before a single
                ;; body follows, so the tail is where the row count is going. Drawn one-per-row that
                ;; is a screen of placeholders; this is one line, and it removes itself when the
                ;; last body lands (chrome.lisp, `carry-line`). It stays at the very end because it
                ;; is about the WHOLE transcript filling in rather than about a row's place in it.
                (carry-line head cols)))
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
         ;; **the head the payload seam's predicate reads** (R40): a row's line function is handed
         ;; an item and a preference list, so *is this the newest pageable row* needs the session
         ;; from somewhere. Set here, in the one place that draws rows, and read only inside the
         ;; frame it is set for.
         (*payload-head* head)
         ;; **and the head the OPEN run renders with** (R37 amended): the open form calls
         ;; `item-lines` on the hidden rows at the rung above, and that needs the same head.
         (*hidden-run-head* head)
         (hist (multiple-value-bind (lines bounds)
                   ;; **the anchored row is walked to, not assumed to be in the window** — see
                   ;; `%history-until`'s note: a reader parked on a row is the case the window
                   ;; was not built for, and it is the case R36 is about.
                   (%history-until head cols (max need *hist-depth*)
                                   (and *scroll-anchor* (plusp (head-scroll head))
                                        (car *scroll-anchor*)))
                 (setf *hist-bounds* bounds
                       *hist-depth* (max *hist-depth* (length lines)))
                 lines)))
    ;; **AIR ABOVE THE CHROME.** One blank row after the committed rows, always
    ;; (`body_window`: `if !hist_lines.is_empty() { segs.push(gap) }`), so the
    ;; transcript never sits on the box's top edge and the live turn never sits
    ;; on the last settled row. Measured on letibot's screen: row 59 blank, row
    ;; 60 the box's top edge; ours had prose on 59.
    ;; **AND THE SEAM ABOVE THE OLDEST ROW THIS HEAD HOLDS.** A window that does not say
    ;; it is a window is read as the whole conversation — the reader scrolling to the top
    ;; of a long session cannot tell *"this is where it begins"* from *"this is where my
    ;; head stops"*, and `items_dropped` was stored and read by nothing. It goes in
    ;; FRONT of `hist` rather than inside it, because it is not derived from any item and
    ;; must not be cached as one.
    (let* ((seam (rows-above-line s cols))
           (hist (if seam (append seam hist) hist))
           (lh (length hist))
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
           ;; **AND NOT AFTER A FAREWELL.** `attached, and this session has said nothing
           ;; yet` is a claim about a SESSION, and a head the daemon just refused with a
           ;; `Bye` is in no position to make it — the daemon said why it ended, and the
           ;; screen answering with a cheerful banner about a quiet conversation is the
           ;; same defect as the walking cat standing in for a session nobody has
           ;; described. Momentary (the loop exits on the next pass, and `run` prints the
           ;; farewell on stderr once the terminal is back), but it is the frame the
           ;; operator sees first, and on a version skew it is the frame they will
           ;; screenshot.
           (empty (and (zerop all-len) (not (attaching-p head)) (null (head-farewell head))))
           (empty-lines (when empty (empty-session-lines cols)))
           (n (if empty (length empty-lines) all-len)))
      ;; the scroll is clamped to what exists: past the top there is nothing to
      ;; show, and a wheel that kept counting would need as many turns back
      (setf *scroll-max* (max 0 (- n want))
            (head-scroll head) (max 0 (min (head-scroll head) *scroll-max*)))
      ;; **R36: A SCROLLED VIEWPORT IS ANCHORED TO A ROW, NOT TO A COUNT.**
      ;;
      ;; *"scroll must be preserved — if i scrolled i want my view to hold, regardless of the
      ;; new stuff below."* A count from the bottom is invalidated by every arrival (the
      ;; transcript grew, so the same number names different lines) and a count from the top by
      ;; anything above being rewritten — and both happen in this head: R29's remedy line grows
      ;; a row, a note's detail expands, a tail lands. So the reader's place is stored as
      ;; *that row, that many lines into it*, and it is re-found by identity on every frame.
      ;;
      ;; **The anchor is REFRESHED from what was actually drawn**, at the end of this function,
      ;; which is why it can never drift from the screen: it is not a record of a keypress, it
      ;; is a record of the top row of the last frame. `head-scroll` stays as the fallback and as
      ;; the thing the fetch-above tests read.
      (let* (;; **THE LOSS IS DETECTED BEFORE THE CLAMP, and that order was a real defect.**
             ;; `head-scroll` is clamped to `*scroll-max*` two forms up, and a transcript that
             ;; now FITS the window clamps it to zero — so a reader whose row was taken by a
             ;; compaction was silently returned to the bottom instead of being told. Measured:
             ;; the whole 40-row fixture replaced by 4 carried passages, and no note at all.
             ;; The fact is about the ROW, not about how much there is to scroll, so it is
             ;; answered from the row.
             (lost (and *scroll-anchor*
                        (not (find (car *scroll-anchor*) *hist-bounds*
                                   :key #'first :test #'string=))))
             (anchored (and *scroll-anchor* (not lost) (> (head-scroll head) 0)
                            (%anchor-end head *scroll-anchor* *hist-bounds* want n)))
             (end (or anchored (max 0 (- n (head-scroll head)))))
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
        ;; **R36: THE ANCHOR IS REFRESHED FROM WHAT WAS JUST DRAWN**, which is why it cannot
        ;; drift from the glass — it records the top ROW of this frame, not a keypress. Done
        ;; here, after the window is known and before the caller paints it, and it is the only
        ;; writer of `*scroll-anchor*` besides the keys that return to the bottom.
        ;;
        ;; `head-scroll` is kept in step when the anchor decided the window, because two things
        ;; read it that must not disagree with the screen: the fetch-above test (`>= scroll
        ;; *scroll-max*` is *the reader has reached the oldest row this head holds*) and the
        ;; `↑N` the status row prints. An anchor that moved the window while leaving the number
        ;; alone would make both of them lie by however many lines had arrived.
        (when anchored
          (setf (head-scroll head) (max 0 (min (- n end) *scroll-max*))))
        ;; **and a row that is gone is SAID here, once**, with the anchor dropped: there is
        ;; nothing left to hold a place against. The sentence is R29's shape — the fact and what
        ;; the reader can do with it — and `*anchor-lost-said*` is what keeps it from repeating
        ;; on every paint.
        (when lost
          (%anchor-lose head *scroll-anchor*)
          (setf *scroll-anchor* nil))
        (%anchor-observe head start *hist-bounds*)
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

(defun %fit-ladder (head cols rows card-rows pinned-rows stall-p notice-p comp-p)
  "Which chrome survives on a terminal of ROWS rows — the reference's fit loop
(app.rs:5094-5126), which this head did not have at all.

Returns `(values CARD-ROWS HINT-P NOTICE-P STALL-P COMPLETIONS-P BODY-ROWS
BOXED)`. The ladder **drops the most expendable row first and stops as soon as
the whole thing fits with a line of transcript left over**, in this order:

    completions → the hint bar → the notice → a composer row (down to one)
                → the stall sentence → the box → the card's CONTENT (down to one row)

and the card's LADDER is never given up at all (R20): the floor is the pinned rows plus
one row of content, because the choices are why the card exists.

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
        ;; **THE CARD'S FLOOR IS THE LADDER, AND THAT IS R20.** This arm used to
        ;; read `((> dec 1) (decf dec))` — the card shrank to one row like
        ;; everything else — and because the card is drawn from the FRONT of one
        ;; list, every row it gave up came off the END, which is where the OPTIONS
        ;; are. Measured with a 40-line diff on a 30-row screen: not one option, not
        ;; the hint, not the deadline. The operator, on a card carrying a giant
        ;; `replace`: *"I'm shown a permission prompt and I just can't see the
        ;; selector."*
        ;;
        ;; So the ladder is not part of what the ladder gives up. The floor is the
        ;; pinned rows PLUS one content row when there is content, because a card
        ;; that shows its choices and no question is the same defect with the sign
        ;; flipped. Everything else on the screen is still given up first, and if
        ;; even the floor does not fit, the loop returns and the frame clips — the
        ;; composer and the ladder are what the operator must see, and a transcript
        ;; row is what they lose.
        ((> dec (if (plusp pinned-rows) (1+ pinned-rows) 1)) (decf dec))
        (t (return)))))
    (values dec hint notice-p stall-p comp-p body-rows boxed)))

(defparameter *card-page* 10
  "How many rows one press pages a card's content viewport.

**The payload window's own number** (`*payload-page*`, `src/cards.lisp`), and reused
rather than chosen a second time for the reason that one gives: the window's height is a
function of the frame and the content, and the key handler knows neither, so the unit is
a constant and the CLAMP is where the height is known. Two windows in one head that paged
by different amounts would be two conventions for one idea.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defparameter *scroll-notch* 3
  "How many rows ONE WHEEL NOTCH moves a viewport — the transcript, a pane, a card.

**THE UNIT IS A RENDERED ROW, NOT A TRANSCRIPT ROW, and that is the whole reason the number is 3
rather than 1.** A wheel notch is a row at a time in a pager, because a pager's rows ARE screen rows.
A transcript row here can be two screen rows after wrapping, so a notch of one wrapped row reads as
nothing happened and the reader scrolls three times to move one message. letibot states this in its own
words at `crates/tui/src/app.rs:5368` — *\"Three lines a notch: a wheel notch is a row at a time in a
pager, but a transcript row can be two screen rows after wrapping, and a notch that moves one wrapped
row reads as nothing happened.\"* — and this head had the same number with no note saying why, which is
how a considered number becomes a magic one.

**Three, and the two implementations agree by ARRIVAL rather than by copying**, which is the same
pattern R57 catalogues for the row shape, the no-reading states and the trim-at-2× policy. Neither
side read the other's number; both wrote the same comment about wrapping.

**A `defparameter` and not a `defconstant`**: the file pusher SKIPS constants, so a constant here
could never be changed on a running head — and a head whose entire purpose is runtime redefinition is
exactly the wrong place to pin an input's feel. It is also the number a reader is most likely to want
different: a trackpad and a notched wheel on one desk, a wrapped transcript on a narrow terminal, and
a pane of one-line rows where 3 is already most of a screen.

One value for every viewport on purpose. `*card-page*` pages and this notches, and the wheel and the
page keys must not disagree about WHICH — but two viewports differing about how far a notch goes would
be two conventions for one gesture, which is the defect `*card-page*`'s docstring names for paging.")

(defvar *card-scroll* 0
  "How far the CARD's content viewport has been scrolled, in rows.

**R20's second half, and it is a `defvar` for the reason the payload window is**: it
changes what the frame DRAWS and every frame reads it, so a head slot would be a struct
change and a struct change is a restart. Bound by `with-replay-globals`, because a replay
must answer the same bytes twice.

**Reset whenever the card is not the same card**: a scroll offset is an offset into one
diff, and carrying it to the next ask would open a card already scrolled past its own
headline. `%render` does that by keying on the `req_id` it last drew for, the same shape
`*payload-view*` uses for the row it is open on.")

(defvar *card-scroll-for* nil
  "The `req_id` `*card-scroll*` belongs to, so a new ask starts at the top.")

(defun reset-card-scroll ()
  "The next card starts at its own top."
  (setf *card-scroll* 0
        *card-scroll-for* nil))

(defun card-scroll-by (n)
  "Page the card's content viewport by N rows. The clamp is the render's.

**Here is where the SIGN lives, one place for every key that scrolls this viewport**, by
the same argument `editor.lisp` makes for the panes: the offset counts rows hidden ABOVE,
so moving toward the beginning DECREASES it, and a second sign convention written at a
second key would be the bug the panes already had once."
  (setf *card-scroll* (max 0 (+ *card-scroll* n))))

(defun card-content-window (content room rows-that-matter)
  "CONTENT as a viewport of ROOM rows, with the seam R20 asks for.

Returns the lines to draw, at most ROOM of them. **The seam is a row of the viewport and
not a line of the card**, so it is counted here; whatever is left after it is content.

**The seam says how much is OUT OF VIEW, not that there is more** — the operator's own
correction, and it is the difference between a count and a shrug. Three shapes, because
there are three places the reader can be:

    … 34 rows out of view below · PgDn scrolls
    … 12 rows out of view above · PgUp scrolls
    … 12 rows above, 34 below out of view · PgUp/PgDn scrolls

and NOTHING when the whole thing is visible: a seam on a card that fits is a promise of
content that is not there.

**The clamp is here because this is where the height is known**, the rule the payload
window and every pane keep: `*card-scroll*` is set by a key handler that cannot see the
frame, so the offset it wrote is clamped to what this room can actually show, and the
clamped value is written BACK — otherwise `PgDn` at the bottom would keep raising an
offset nobody reads and the next `PgUp` would appear to do nothing.

ROWS-THAT-MATTER is the count of content rows a caller wants visible at minimum, used
only to decide whether a seam may be afforded at all; it is 0 for every caller today and
exists so a future one can say *I would rather cut the content than the seam*."
  (declare (ignorable rows-that-matter))
  (let* ((total (length content))
         (room (max 0 room)))
    (cond
      ;; nothing to show, or no room to show it in
      ((zerop room) nil)
      ((<= total room)   (subseq content 0 (min total room)))
      (t
       ;; **ONE ROW OF THE ROOM IS THE SEAM, AND THE WINDOW IS NEVER TALLER THAN ITS
       ;; ROOM.** Measured, and this is the off-by-one that put a card eleven rows tall
       ;; into ten: the floor here used to be `(max 1 (1- room))`, so a room of ONE gave
       ;; one content row PLUS the seam — two lines — and the card drew over the alarm row
       ;; below it, which came out on the glass as `⚠ detached — retryingf nobody answers,
       ;; nothing runs`. A room of one can afford the seam or a line of content, and the
       ;; seam is the honest one: one line of a diff says nothing about the eighty-five
       ;; below it.
       (let* ((visible (max 0 (1- room)))
              (max-scroll (max 0 (- total visible)))
              (start (max 0 (min max-scroll *card-scroll*)))
              (hidden-above start)
              (hidden-below (max 0 (- total (+ start visible)))))
         (setf *card-scroll* start)
         (when (and (zerop hidden-above) (zerop hidden-below))
           (return-from card-content-window (subseq content 0 room)))
         (let* ((plural (if (= 1 (max hidden-above hidden-below)) "" "s"))
                (window (subseq content start (min total (+ start visible))))
                (where (cond ((and (plusp hidden-above) (plusp hidden-below))
                              (format nil "~d row~a above, ~d below out of view · PgUp/PgDn scrolls"
                                      hidden-above plural hidden-below))
                             ((plusp hidden-above)
                              (format nil "~d row~a out of view above · PgUp scrolls"
                                      hidden-above plural))
                             (t
                              (format nil "~d row~a out of view below · PgDn scrolls"
                                      hidden-below plural)))))
           (append window
                   (list (list (cons (format nil "    … ~a" where) '(:dim t)))))))))))

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
         ;; the chrome's candidates, each nil or one line — and the ghost, which is the one
         ;; candidate that is not a chrome row at all: it is the composer's (`:ghost` below)
         (stall (stall-row head cols))
         (notice (notice-line head cols))
         (completions (%completions-text head))
         (card-lines nil)
         ;; **R20: the ladder is a SECOND list, and it is the pinned one.** NIL for
         ;; every card that does not have one, which is all of them but the decision.
         (card-ladder nil))
    (screen-clear s)
    ;; **THE LINK LAYER BEGINS A FRAME HERE**, beside the clear, because the two are the same
    ;; statement: what follows is drawn from nothing. The table is per-frame (an id means nothing
    ;; outside the frame that minted it) and the cwd is what a relative path resolves against —
    ;; `*link-cwd*` from the session's own workspace, since a terminal has no idea where this head
    ;; is and a relative `file://` URL is not a broken link but a meaningless one.
    (link-reset)
    (setf *link-enabled* (not (null (getf (head-prefs head) :links)))
          *link-cwd* (getf (session-wiring (head-session head)) :workspace))
    ;; The card that owns the keyboard, in the reference's own order
    ;; (app.rs:5053-5066): a password, then a decision, then the way out, then a
    ;; picker. The `allow-all` question rides at the FRONT of all of it, because
    ;; while it is up every key belongs to it and a question that owns the
    ;; keyboard has to be the thing on the screen.
    (cond ((head-secret-req head)
           (setf card-lines (secret-ask-lines head cols)))
          ((%open-decision head)
           ;; **TWO VALUES, and the second is the LADDER** (R20). The scroll offset
           ;; is keyed to THIS ask, so a new card opens at its own top rather than
           ;; inheriting an offset into somebody else's diff — the shape
           ;; `*payload-view*` keeps for the row its window is open on.
           (let ((id (getf (%open-decision head) :req-id)))
             (unless (equal id *card-scroll-for*)
               (setf *card-scroll* 0
                     *card-scroll-for* id))
             (multiple-value-setq (card-lines card-ladder)
               (permission-card-lines head cols))))
          ((head-quit-open head)
           (setf card-lines (quit-card-lines head cols)))
          ;; **the operator-call composer, between the way out and a picker.** The order is
          ;; the keyboard's: the quit card and an open ask are asked for keys before this
          ;; one (`%handle-key`), so they are drawn before it — a card drawn above
          ;; something that owns the keyboard would be a picture of a key that does not work.
          ((op-call-draft-open-p)
           (setf card-lines (op-call-card-lines head cols)))
          ;; **the new-todo card**, beside it and for the same reason: both are modal dialogs whose
          ;; field is the composer, and a card drawn above a field that is not its own is a picture
          ;; of a key that does not work.
          ;; **THE API-KEY CARD**, in the same chain and for the same reason: a modal
          ;; dialog whose field is the composer, so the composer drawing under a card
          ;; that is not its own is a picture of a key that does not work.
          ((and *key-draft* t)
           (setf card-lines (key-card-lines head cols)))
          ((todo-draft-open-p)
           (setf card-lines (todo-card-lines head cols)))
          (*pick-open*
           (setf card-lines (pick-card-lines head cols))))
    ;; a card with no ladder is all content, and the mode-confirm question rides
    ;; ABOVE whatever it is (it owns the keyboard while it is up)
    (setf card-lines (append (mode-confirm-lines cols) card-lines))
    (multiple-value-bind (card-rows hint-p notice-p stall-p comp-p body-rows boxed)
        ;; **THE CARD'S TOTAL IS CONTENT PLUS LADDER**, and passing only the content
        ;; here was a real bug the tests caught: the loop decremented a `dec` that
        ;; counted the content, so a card whose content exactly filled the room came out
        ;; with a one-row viewport and a seam, on a screen with thirty rows to spare.
        ;; The total is what has to fit, and the ladder is what the floor is made of.
        ;;
        ;; **THE COMPLETIONS ARE NO LONGER A ROW THE LADDER CAN SPEND** — they are the box's own
        ;; last row now, paid for by the hint bar's row (below), so there is nothing here to give
        ;; up. Telling the ladder about a row that is not drawn made it one row conservative and
        ;; cost the transcript a line; that is the same jump in a quieter coat.
        (%fit-ladder head cols rows (+ (length card-lines) (length card-ladder))
                     (length card-ladder)
                     (and stall t) (and notice t) nil)
      (declare (ignore comp-p))
      (let* (;; **THE GHOST TAKES THE HINT BAR'S ROW.** Both are one line of live advice about what
             ;; you can do next, and the completions are the better answer to that question —
             ;; the hint bar's own `tab completes /commands` is exactly what the ghost is showing.
             ;; So they are ONE row in the frame, whichever one it is, and the frame's height does
             ;; not change when a `/` goes in.
             ;;
             ;; **That is the whole fix for the operator's jump** — *"this grey help ghost appears
             ;; above the area and the conversation is jumping again"*. The viewport is
             ;; bottom-anchored, so any row the chrome gains pushes the conversation up one line
             ;; and drops its oldest line; taking the ghost's row from the hint bar rather than
             ;; from the transcript is what stops it. And when the frame is too short for the hint
             ;; bar at all, the ghost goes WITH it: the ladder's rule is that the completions are
             ;; the first thing given up, and a typing aid may not cost a row the frame has not
             ;; got.
             (ghost (and hint-p completions))
             (hint-shown (and hint-p (not ghost)))
             (composer (composer-line head cols :boxed boxed :max-rows body-rows :ghost ghost))
             (composer-rows (length composer))
             ;; the hint bar owns the LAST row when it survived the ladder; when
             ;; it did not, the composer does
             (hint-row (if hint-shown (1- rows) rows))
             ;; the alarm falls back to a row of its own only when there is no
             ;; box to carry the triangle on its bottom edge — and it goes
             ;; BETWEEN the composer and the hint, which is where the reference
             ;; pushes it (app.rs:5199-5201), not above the composer
             (alarm (and (not boxed) (alarmed-p head) (alarm-line head cols)))
             (alarm-row (and alarm (1- hint-row)))
             (cursor (- (or alarm-row hint-row) composer-rows))
             ;; the chrome above the box, in the reference's order: the card, the
             ;; stall sentence, the head's note — and NO completions row, because
             ;; there is no such row any more. **THE GHOST IS IN THE BOX, AND THIS
             ;; IS THE SECOND HALF OF WHY THE CONVERSATION STOPS JUMPING**: the
             ;; composer is one row taller, so it starts one row higher
             ;; (`cursor`, above), and the hint bar's row has already been given to
             ;; that same composer.
             (chrome-top (- cursor (if notice-p 1 0) (if stall-p 1 0) card-rows))
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
          ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :job-out :picker :todos :slash :dash))
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
                 (:todos (todos-lines head cols))
                 ;; **THE DASHBOARD (dash.lisp).** Composed from whatever panels are
                 ;; REGISTERED, so this line does not change when a panel is added — which is
                 ;; the whole point of a panel being data.
                 ;; **ONE VALUE, and that is a REQUIREMENT rather than a style.** This `case`
                 ;; feeds a `multiple-value-setq (lines sel-line)`, so a pane function's SECOND
                 ;; value becomes the cursor's LINE — `dash-frame-lines` returns the line each
                 ;; panel starts on as its second, and the frame then handed that vector to
                 ;; `scroll-pane-into-view`, which died with `#(2 9) is not of type REAL`.
                 ;; MEASURED, on the operator's head: `render failed — the head is alive`.
                 ;;
                 ;; The starts vector is not wasted — `dash-click-sel` asks for it at click time,
                 ;; which is the same re-ask `todos-click-sel` does. **`:todos` has always returned
                 ;; three values here and gets away with it only because its second IS a line
                 ;; number**, which is exactly the kind of luck a one-value rule removes.
                 (:dash (values (dash-frame-lines cols :nav *dash-nav*)))
                 ;; a listing that ARRIVED, drawn from the TOP like a document —
                 ;; `*pane-lines*` below takes this list's length, so its scroll
                 ;; clamps against the whole thing and `pane-view` windows it
                 (:slash (slash-out-lines head cols room))))
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
        (let* ((room-for-card card-rows)
               ;; **R20: THE LADDER KEEPS ITS ROWS AND THE CONTENT GETS THE REST.**
               ;; Measured before this existed, with a 40-line diff at every size from
               ;; 8 rows to 30: not one option, not the hint, not the deadline on the
               ;; screen — the card was drawn as `(subseq card-lines 0 card-rows)` and the
               ;; fit loop took its rows off the END. The ladder is now a list of its own,
               ;; drawn LAST inside the card and never trimmed; what shrinks is the
               ;; content, in a viewport with a seam that says how much is out of view,
               ;; and that viewport SCROLLS, so the whole diff is still readable.
               ;;
               ;; The room is the card's fitted rows minus the ladder, floored at one, so
               ;; a card always has something of its question above its choices —
               ;; `%fit-ladder` guarantees at least that by refusing to go below
               ;; `(1+ pinned)`.
               (content-room (max 1 (- room-for-card (length card-ladder))))
               (content (card-content-window card-lines content-room 0))
               ;; the card's ACTUAL height: the windowed content plus the pinned ladder.
               ;; It can be LESS than the room it was offered, when the content fits.
               (card-total (+ (length content) (length card-ladder)))
               ;; `chrome-top` was computed from the FITTED rows, so the difference
               ;; between what the card was offered and what it took is handed back to
               ;; the transcript rather than left as a gap above it.
               (r (- chrome-top (- room-for-card card-total))))
          (flet ((row (line) (put-segments s r gutter line) (incf r)))
            (dolist (line content) (row line))
            (dolist (line card-ladder) (row line))
            (when stall-p (row (first stall)))
            (when notice-p (row (first notice)))
            ;; **NO completions row here** — it is inside the box, drawn with the composer.
            ;; See `composer-ghost-row` for the screen that moved it.
            (dolist (line composer) (row line))))
        (when alarm-row (put-segments s alarm-row gutter alarm))
        ;; **and the hint bar, when the ghost is not standing in its row** — see `ghost` above.
        (when hint-shown (put-segments s hint-row gutter (hint-bar head cols)))
        ;; **and where the terminal's own caret goes.** The painter emits the move
        ;; and `ESC[?25h` after the frame; without it the head hid the cursor at
        ;; startup and never showed it again, so the composer had no caret at all.
        ;; Clamped at BOTH ends: the ladder can be beaten on a two-row terminal,
        ;; and a negative caret row is a cursor the terminal puts wherever it
        ;; likes.
        (let ((caret (composer-caret head cols :boxed boxed :max-rows body-rows)))
          (setf *caret* (cons (max 0 (min (1- rows) (+ cursor (car caret))))
                              (max 0 (min (1- term-cols) (+ gutter (cdr caret)))))))))))

;;; `+right-margin+` and `+gutter+` were defined a SECOND time here, with a second docstring that
;;; contradicted the first (this one called the margin a constant of its own; the first says it is
;;; the gutter mirrored). Both values were 2, so nothing showed — but the later `defparameter` was
;;; the one a reader of this region found, and it was the wrong story. One definition each, above.

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
      (let ((painted nil))
        (ignore-errors
          (screen-clear (head-screen head))
          (%place-lines (head-screen head) lines 0
                        (max 0 (- (head-rows head) 3)) (head-cols head))
          (paint-full (head-screen head) out)
          (setf painted t))
        (ignore-errors
          (setf (head-last-rows head) (screen-rows-ansi (head-screen head))
                (head-last-cols head) (head-cols head)
                (head-last-rows-n head) (head-rows head)))
        ;; **THE RECORD IS ONLY UPDATED FOR A PAINT THAT WENT OUT.**
        ;;
        ;; `(replace prev cur)` is an ASSERTION about the terminal — "this is what you
        ;; are showing" — and every later diff is computed against it: a cell where
        ;; the record and the new frame agree is a cell NOTHING is ever written to
        ;; again. So a record written by a paint that did not complete is not a stale
        ;; record, it is a permanent hole. Measured on a scratch head with the paint
        ;; injected to die after `ESC[2J`: the head believed it had drawn 30 rows the
        ;; terminal did not have, and no ordinary paint could repair it.
        ;;
        ;; `paint-full` returning normally is the only evidence available here, and it
        ;; is weak — which is why the failure ALSO asks for a full repaint below.
        (when painted
          (ignore-errors
            (replace (screen-cells (head-prev-screen head))
                     (screen-cells (head-screen head)))))))
    ;; **A FAILED PAINT MEANS THIS HEAD NO LONGER KNOWS WHAT IS ON THE TERMINAL.**
    ;;
    ;; Unconditional, and outside every guard: the point is that the NEXT paint
    ;; clears and redraws everything, so nothing the failed paint wrote — or failed to
    ;; write — can persist. Without it, recovery depends on the next frame happening
    ;; to differ from a record that is already a lie, which is exactly the coincidence
    ;; the operator's symptom consists of and which a byobu window switch supplies
    ;; instead, by resizing.
    (ignore-errors (setf (head-full-repaint head) t))))

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
    (incf *frames-painted*)
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
  ;; ONE place, on every path including the failure one — a paint that fell back to
  ;; the failure frame is still a frame, and a stamp that did not move would ask for
  ;; another one immediately, which is a head that spins on a broken renderer.
  (setf *last-paint-ms* (internal-real-time-ms))
  (setf (head-dirty head) nil))


