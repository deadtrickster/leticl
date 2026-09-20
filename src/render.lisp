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
         (hist nil))
    ;; prepend committed rows, newest first, until enough lines exist; the
    ;; accumulator stays oldest-first because each older row goes in front
    ;;
    ;; **AIR WHERE THE KIND CHANGES**, which is the reference's `RowClass` rule and
    ;; the spacing this head was missing: a blank line goes before a row unless
    ;; BOTH it and the row above are `Activity`. Two tool cards in a row are one
    ;; block and read as one — a blank between each was a third of the vertical
    ;; budget spent separating what a glyph in the first column already separates —
    ;; while prose against a card is a change of kind and gets the air.
    ;;
    ;; A row that renders NOTHING gets no separator either. An assistant row whose
    ;; text is whitespace and whose every call is drawn by its own result is a
    ;; common shape (it is what a tool-calling round looks like), and paying two
    ;; blank lines for it puts a hole in the transcript.
    (let ((class-above nil))
      (loop for i from (1- (length (session-items s))) downto 0
            ;; one more than needed: the gap below costs a row
            while (< (+ (length hist) (length tail)) (1+ need))
            do (let* ((item (aref (session-items s) i))
                      (il (item-lines item cols (head-prefs head)))
                      (class (item-row-class item)))
                 (unless (every #'%line-blank-p il)
                   (when (and hist class-above
                              (not (and (eq class :activity) (eq class-above :activity))))
                     (setf hist (cons nil hist)))
                   (setf class-above class))
                 (setf hist (append il hist)))))
    ;; **AIR ABOVE THE CHROME.** One blank row after the committed rows, always
    ;; (`body_window`: `if !hist_lines.is_empty() { segs.push(gap) }`), so the
    ;; transcript never sits on the box's top edge and the live turn never sits
    ;; on the last settled row. Measured on letibot's screen: row 59 blank, row
    ;; 60 the box's top edge; ours had prose on 59.
    (let* ((all (append hist (and hist (list nil)) tail))
           (n (length all)))
      ;; the scroll is clamped to what exists: past the top there is nothing to
      ;; show, and a wheel that kept counting would need as many turns back
      (setf (head-scroll head) (max 0 (min (head-scroll head) (- n want))))
      (let* ((end (max 0 (- n (head-scroll head))))
             (start (max 0 (- end want)))
             (out (subseq all start end)))
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

(defun %render (head)
  "State to the cell buffer.

The bottom of the frame is laid out BACKWARDS from the last row, because the
composer's height is not fixed: it is a box whose body grows with the buffer, so
the transcript gets what is left. Getting that order wrong is how a composer
scrolls the transcript by a row every keystroke.
"
  (let* ((s (head-screen head))
         ;; content width: the frame less the gutter AND the right margin
         (cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
         (rows (head-rows head))
         (composer (composer-line head cols))
         (composer-rows (length composer))
         (hint (hint-bar head cols))
         (alarm (alarm-line head cols))
         (status (status-line head cols))
         ;; **From the bottom: hint bar, composer, status, alarm.**
         ;;
         ;; Measured against letibot's own 63-row screen: its LAST row is the hint
         ;; bar and the composer box sits directly above it. Ours had the box at
         ;; the bottom with the hint above it, which puts the hint — the line that
         ;; tells you what the keys do — above the thing you are typing into.
         ;;
         ;; A status row with nothing to say is NO row: it was drawing all dashes,
         ;; and a row that costs a line to say nothing is the defect the reference's
         ;; own comment names ("a number that is zero costs a row of attention for
         ;; ever in exchange for being noticed once").
         (hint-row (1- rows))
         (cursor (- hint-row composer-rows))
         ;; **The alarm and the turn's status ride the box's bottom edge**, which
         ;; is what the reference does and why it has no status row at all: a
         ;; resident row that is usually empty costs a line of transcript for
         ;; ever. They fall back to their own rows only when there is no box (a
         ;; screen too short for one), where there is no edge to carry them.
         (boxed (>= rows 8))
         (status-text (and status (not boxed)
                           (string-trim " ─" (apply #'concatenate 'string
                                                    (mapcar #'car status)))))
         (status-row (when (and status-text (plusp (length status-text))) (1- cursor)))
         (alarm-row (when (and alarm (not boxed)) (- (or status-row cursor) 1)))
         (body-top 1)
         (body-bottom (or alarm-row status-row cursor))
         (card-lines nil))
    (screen-clear s)
    ;; top border, inside the gutter like everything else
    ;; the header is as wide as the body: measured against letibot's row 1, its
    ;; tail ends where the box's right edge does, and ours stopped three short
    (put-segments s 0 +gutter+ (top-border head cols))
    ;; the ask card rides at the front of the chrome, transcript visible above
    ;; the `allow-all` question sits at the FRONT of the chrome, above any card:
    ;; while it is up every key belongs to it, and a question that owns the
    ;; keyboard has to be the thing on the screen
    (cond ((head-secret-req head)
           (setf card-lines (secret-card-lines head cols)))
          ((%open-decision head)
           (setf card-lines (decision-card-lines head cols)))
          ;; the pickers are CARDS, with the transcript visible above them, as the
          ;; reference draws them — ours were full-body panes
          (*pick-open*
           (setf card-lines (pick-card-lines head cols))))
    (setf card-lines (append (mode-confirm-lines cols) card-lines))
    (let ((card-rows (length card-lines)))
      (cond
        ;; full-body screens replace the transcript
        ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :picker :todos))
         (let* ((lines nil)
                (sel-line nil)
                (room (max 1 (- body-bottom body-top))))
           ;; A pane that owns a cursor returns the LINE it is on as a second
           ;; value, because its cursor counts ROWS and this offset counts LINES —
           ;; the two differ by every header above the list.
           (multiple-value-setq (lines sel-line)
             (case (head-mode head)
               (:help (help-lines cols))
               (:status (status-screen-lines head cols))
               (:config (config-lines head (head-settings head) cols))
               (:jobs (jobs-lines head cols))
               (:subagents (subagent-lines head cols))
               (:peek (peek-lines head cols))
               (:picker (picker-lines (head-session head)
                                      (head-picker-sel head) cols))
               (:todos (todos-lines head cols))))
           ;; tell the KEY handler what it may scroll: it clamps without
           ;; re-rendering, and the cursor can then scroll itself into view
           (setf *pane-lines* (length lines)
                 *pane-room* room)
           ;; a cursor that walked out of the window drags the window with it
           (when sel-line (scroll-pane-into-view sel-line))
           (%place-lines s (pane-view lines) body-top
                         (1- (+ body-top room)) cols)))
        ;; transcript empty and nothing has arrived yet: the wait, which is a
        ;; thing to SHOW rather than a banner claiming the session is empty — a
        ;; claim a head that has not been answered is in no position to make.
        ;; BEFORE the transcript arm: this clause sat after a `(t …)` and the
        ;; compiler deleted it, so the walking cat never once drew.
        ((attaching-p head)
         (let* ((wait (attach-lines head cols))
                (room (max 1 (- body-bottom body-top)))
                (skip (max 0 (- (floor room 2) (floor (length wait) 2)))))
           (%place-lines s wait (+ body-top skip) body-bottom cols)))
        (t
         ;; transcript viewport, then the card just above the chrome
         ;; THE QUIT CARD'S OWN HEIGHT. `card-rows` above is the decision
         ;; card's, which is NIL when ctrl-c opens this one — so the quit card was
         ;; placed at `body-bottom + 1`, off the body, while `want` still gave up
         ;; the rows for it: the operator saw the transcript step up and three
         ;; blank rows where the card should be (*"Cc doesnt work"*).
         (let* ((card-lines (if (head-quit-open head)
                                (quit-card-lines head cols)
                                card-lines))
                (card-rows (length card-lines))
                ;; the card takes exactly its rows: the viewport already ends
                ;; with the gap row, so no blank is added between them — the
                ;; reference's chrome is [card…, box] straight under the gap
                (want (max 1 (- body-bottom body-top card-rows)))
                (lines (%viewport-lines head cols want)))
           (%place-lines s lines body-top (+ body-top (length lines) -1) cols)
           ;; `body-bottom` is the composer's FIRST row — exclusive. Placing the
           ;; card through it put its last line under the box's top edge.
           (when card-lines
             (%place-lines s card-lines (- body-bottom card-rows) (1- body-bottom) cols))))))
    ;; the chrome, each row where the layout above put it
    (when alarm-row (put-segments s alarm-row +gutter+ alarm))
    (when status-row (put-segments s status-row +gutter+ status))
    (loop for row in composer
          for r from cursor
          do (put-segments s r +gutter+ row))
    (put-segments s hint-row +gutter+ hint)))

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

(defun %place-lines (screen lines top bottom cols)
  "Segment lines into rows top..bottom, clipping both ends, inside the gutter."
  (let ((r top))
    (dolist (line lines)
      (when (> r bottom) (return))
      (put-segments screen r +gutter+ line)
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
            ;; the cursor belongs at the end of the line being typed
            (let* ((c (head-composer head))
                   (buf (composer-buffer c)))
              (move-to out (1- (head-rows head))
                       (min (1- (head-cols head))
                            (+ 2 (string-width
                                  (if (> (+ 2 (string-width buf)) (1- (head-cols head)))
                                      (subseq buf (max 0 (- (length buf)
                                                            (- (1- (head-cols head)) 2))))
                                      buf)))))))
          ;; a GOOD frame clears the flag, so a fixed head goes green again
          ;; without a restart — which is the whole point of pushing a fix
          (setf *last-render-error* nil))
      (error (e)
        ;; remember it (the gate reads this) AND draw it (the operator reads it)
        (setf *last-render-error* e)
        (%paint-failure head e))))
  (setf (head-dirty head) nil))


