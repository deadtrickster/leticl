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

(in-package #:leticl)

;;; ------------------------------------------------------------- wrapping ;;;
(defun %split-words (text)
  "Word chunks with their trailing spaces attached, so re-joining preserves
spacing exactly."
  (let ((out nil)
        (buf (make-string-output-stream)))
    (loop for ch across text
          do (progn (write-char ch buf)
                    (when (char= ch #\space)
                      (push (get-output-stream-string buf) out))))
    (push (get-output-stream-string buf) out)
    (nreverse (remove "" out :test #'string=))))

(defun %hard-break (word cols)
  "One over-wide word to cols-sized chunks — a 400-column URL wraps, it does
not overflow (width.rs's third mistake)."
  (let ((out nil))
    (loop for i from 0 below (length word) by (max 1 cols)
          do (push (subseq word i (min (length word) (+ i (max 1 cols)))) out))
    (nreverse out)))

(defun wrap-segments (segs cols)
  "Segments to lines of at most COLS columns. Style carries onto continuation
lines; each returned line is independently paintable."
  (if (<= cols 0)
      (list segs)
      (let ((lines nil)
            (cur nil)
            (w 0))
        (flet ((break-line ()
                 (when cur (push (nreverse cur) lines))
                 (setf cur nil w 0)))
          (dolist (seg segs)
            (dolist (word (%split-words (car seg)))
              (let ((ww (string-width word)))
                (cond
                  ((> ww cols)
                   (break-line)
                   (let ((chunks (%hard-break word cols)))
                     (dolist (c chunks)
                       (push (cons c (cdr seg)) cur))
                     (break-line)))
                  ((<= (+ w ww) cols)
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
         (all (append (turn-lines (session-turn s) cols (head-prefs head))
                      (turn-footer-lines (session-turn s) cols)
                      ;; QUEUED PROMPTS, at the tail, where they will land: a
                      ;; sentence the conversation has swallowed is visible here
                      ;; until the daemon appends its row
                      (queued-lines head cols))))
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
            while (< (length all) need)
            do (let* ((item (aref (session-items s) i))
                      (il (item-lines item cols (head-prefs head)))
                      (class (item-row-class item)))
                 (unless (every (lambda (l) (zerop (length (string-trim " " (segs-text-of l)))))
                                il)
                   (when (and all class-above
                              (not (and (eq class :activity) (eq class-above :activity))))
                     (setf all (cons nil all)))
                   (setf class-above class))
                 (setf all (append il all)))))
    (let* ((n (length all))
           (end (max 0 (- n (head-scroll head))))
           (start (max 0 (- end want))))
      (subseq all start end))))

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
    (put-segments s 0 +gutter+ (top-border head (- cols +gutter+)))
    ;; the ask card rides at the front of the chrome, transcript visible above
    (cond ((head-secret-req head)
           (setf card-lines (secret-card-lines head cols)))
          ((%open-decision head)
           (setf card-lines (decision-card-lines head cols))))
    (let ((card-rows (length card-lines)))
      (cond
        ;; full-body screens replace the transcript
        ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :picker :todos
                                     :mode-picker :models-picker))
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
               (:todos (todos-lines head cols))
               (:mode-picker (mode-picker-lines head cols))
               (:models-picker (models-picker-lines head cols))))
           ;; tell the KEY handler what it may scroll: it clamps without
           ;; re-rendering, and the cursor can then scroll itself into view
           (setf *pane-lines* (length lines)
                 *pane-room* room)
           ;; a cursor that walked out of the window drags the window with it
           (when sel-line (scroll-pane-into-view sel-line))
           (%place-lines s (pane-view lines) body-top
                         (1- (+ body-top room)) cols)))
        (t
         ;; transcript viewport, then the card just above the chrome
         (let* ((card-lines (if (head-quit-open head)
                                (quit-card-lines head cols)
                                card-lines))
                (want (max 1 (- body-bottom body-top (if card-lines (+ 2 card-rows) 0))))
                (lines (%viewport-lines head cols want)))
           (%place-lines s lines body-top (+ body-top (length lines) -1) cols)
           (when card-lines
             (%place-lines s card-lines (- body-bottom card-rows -1) body-bottom cols))))))
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


