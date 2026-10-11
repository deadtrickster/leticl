;;;; pane-protocol.lisp — the PANE protocol: one class per full-body screen, and the
;;;; generics the rest of the head asks it through.
;;;;
;;;; **Why this exists.** A pane used to be a keyword dispatched through a `case` in
;;;; each of several files: the frame's lines and total (`render.lisp`), the cursor's
;;;; row count and what Enter does (`editor.lisp`), where Esc goes and where the
;;;; cursor opens (`panes.lisp`), the hint bar's tail (`chrome.lisp`). Adding a pane
;;;; meant remembering all of them, and the copies had already drifted: the hint bar
;;;; carried a second, DEAD `:jobs` arm, and the dashboard's `case` arm returned a
;;;; vector where a line number was wanted (`render failed — the head is alive`,
;;;; MEASURED). One class per pane and one generic per question is the same fix the
;;;; cards got, for the same reason.
;;;;
;;;; **What is deliberately NOT here: the key map.** `%pane-key` (`editor.lisp`) is
;;;; ONE key map, not twelve: the panes share one cursor (`head-picker-sel`), one
;;;; scroll offset, one Esc, and the page/wheel/arrow handling is genuinely common —
;;;; its arms differ by a handful of mode tests, not by pane. Twelve `pane-key`
;;;; methods would be twelve copies of the same movement code. So the facts a key
;;;; NEEDS are per pane and live here (`pane-row-count`, `pane-escape-target`), and
;;;; the map that reads them stays one function.
;;;;
;;;; **A pane holds no state.** Everything a pane draws comes from the head or from a
;;;; global, exactly as the functions it delegates to always did; the instances below
;;;; are singletons because the dispatch needs an object and nothing else.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------------- the classes ;;;

(defclass pane ()
  ((mode :initarg :mode :reader pane-mode))
  (:documentation "One full-body screen. The mode keyword IS the pane's identity —
the head stores the keyword (a struct slot, and a slot change is a RESTART), and
`pane-for` is the one place that keyword becomes a class."))

(defclass conversation-pane (pane) ()
  (:documentation "`:normal` — the transcript, and the answer for a mode nobody
registered. It replaces nothing and draws nothing of its own: the frame falls
through to the conversation, which is what the old `member` test's absence meant."))

(defclass help-pane        (pane) ())
(defclass status-pane      (pane) ())
(defclass config-pane      (pane) ())
(defclass jobs-pane        (pane) ())
(defclass merge-queue-pane (pane) ())
(defclass standing-notes-pane (pane) ())
(defclass merge-detail-pane (pane) ())
(defclass term-pane (pane) ())

(defvar *merge-detail* nil
  "The queue entry the `:merge-detail` VIEW is about — set by `pane-enter` on the queue pane.

**A VIEW AND NOT A SECOND LIST**, which is the item's own phrase: *two views of one list*. It is
held here rather than read again because *the data is already on the head* — the reviews and gate
steps ride the entry — so opening this view sends no frame and cannot disagree with the row the
reader came from.")
(defclass subagents-pane   (pane) ())
(defclass peek-pane        (pane) ())
(defclass job-out-pane     (pane) ())
(defclass picker-pane      (pane) ())
(defclass todos-pane       (pane) ())
(defclass slash-pane       (pane) ())
(defclass dash-pane        (pane) ())
(defclass lisp-pane        (pane) ())

;;; ------------------------------------------------------------ the registry ;;;
;;;
;;; **One alist, and it is the list of panes.** The old dispatch kept the same
;;; twelve keywords in four files; a pane that is missing here has no lines, no
;;; cursor, no Esc and no hint, which is the honest answer for a mode nobody
;;; registered and the reason the fallback is `conversation-pane` rather than an
;;; error.

(defparameter *pane-classes*
  '((:help . help-pane)
    (:status . status-pane)
    (:config . config-pane)
    (:jobs . jobs-pane)
    (:queue . merge-queue-pane)
    (:merge-detail . merge-detail-pane)
    (:term . term-pane)
    (:standing . standing-notes-pane)
    (:subagents . subagents-pane)
    (:peek . peek-pane)
    (:job-out . job-out-pane)
    (:picker . picker-pane)
    (:todos . todos-pane)
    (:slash . slash-pane)
    (:dash . dash-pane)
    (:lisp . lisp-pane))
  "The full-body screens, by the mode keyword that opens them.")

(defvar *panes* nil
  "The one instance per pane class, made on first ask.

 A `defvar` rather than a `defparameter`, for the reason every live table here is: a
 push of this file must not drop a running head's instances into a fresh list. They
 hold nothing but their mode, so rebuilding them would be harmless — which is
 exactly why the rule is worth keeping rather than arguing about.")

(defun pane-for (mode)
  "The pane MODE names, or `conversation-pane` — the fallback that replaces nothing.

 **An unknown mode is not an error and never was**: the old tests were `member`
 against a list, so a keyword nobody knew fell through to the conversation. That
 direction is kept deliberately — a new mode arrives with a class, and until it does
 the frame draws the transcript rather than a blank screen or a condition.”"
  (let ((class (cdr (assoc mode *pane-classes* :test #'eq))))
    (if (null class)
        (or (getf *panes* :normal)
            (setf (getf *panes* :normal) (make-instance 'conversation-pane :mode :normal)))
        (or (getf *panes* mode)
            (setf (getf *panes* mode) (make-instance class :mode mode))))))

(defun current-pane (head)
  "The pane the head is showing. One line, so no caller has to remember `pane-for`."
  (pane-for (head-mode head)))

;;; ------------------------------------------------------------- the protocol ;;;

(defgeneric pane-lines (pane head cols room)
  (:documentation "The pane's lines, and as a second value the LINE its cursor is on
(or NIL when it has no cursor).

**The second value is a LINE and not a row**, and that contract has a measurement
behind it: the frame feeds this into `scroll-pane-into-view`, and `:dash` once
returned a vector of panel starts as its second value, which died as
`#(2 9) is not of type REAL` — *render failed — the head is alive*. A pane with
something else to say returns ONE value."))

(defgeneric pane-total (pane head lines)
  (:documentation "How many lines the scroll clamps against.

The default is what the pane DREW; the two tail windows (`:peek`, `:job-out`) answer
the daemon's own total instead, because what they drew is a window into it — and the
count is what the keys clamp against, so the two cannot be the same number."))

(defgeneric pane-replaces-transcript-p (pane)
  (:documentation "Does this pane draw INSTEAD of the conversation? Every registered
pane does; `conversation-pane` does not, which is the whole of the fallback."))

(defgeneric pane-self-windows-p (pane)
  (:documentation "Does the pane window ITSELF, tail-first?

`:peek` and `:job-out` do, because the tail is where a subagent's answer and a
running job's newest bytes are, and the clamp needs the frame's height — so the
frame must hand them the room and NOT window them a second time."))

(defgeneric pane-enter (pane head)
  (:documentation "What Enter does in this pane: T when the pane took it.

The arms of the old `%pane-enter` `case`, one method each — the only key whose
behaviour was never shared: each pane's Enter is its own act. The shared tail (mark
the head dirty) stayed in the door, because it was shared."))

(defgeneric pane-cursor-rows (pane head)
  (:documentation "How many ROWS the cursor has to walk — one answer, read by the
arrow keys and by the click conversion alike, so the two cannot disagree about what
the last row is. 0 means *this pane has no cursor* (see the REPL's own method),
which is why the base method answers 0 rather than being absent.

Named `pane-cursor-rows` and not `pane-row-count` because that name is the DOOR the
key map calls (`pane-row-count head mode`, `editor.lisp`) — the door asks this."))

(defgeneric pane-opens-at (pane head)
  (:documentation "Where the cursor belongs the moment the pane opens. The top, for
every pane but the session picker — one cursor is shared, so a position left by the
last pane means nothing to the next. The door keeps the old name
(`pane-initial-sel head mode`)."))

(defgeneric pane-esc-target (pane)
  (:documentation "The mode Esc goes to from this pane. `:normal` unless the pane is
an OVERLAY over another list, where the list never closed and Esc means back. The
door keeps the old name (`pane-escape-target mode`)."))

(defgeneric pane-hint (pane head)
  (:documentation "The hint bar's tail for this pane, or NIL when it has no words of
its own. The bar keeps its order around these — the quit prompt and the secret card
outrank any pane's hint."))

;;; ------------------------------------------------------------ the fallbacks ;;;
;;;
;;; Each base method below is the arm the old `case`/`cond` fell through to, kept
;;; verbatim so that a pane nobody has written yet behaves exactly as it did.

(defmethod pane-lines ((pane pane) head cols room)
  (declare (ignore head cols room))
  nil)

(defmethod pane-total ((pane pane) head lines)
  (declare (ignore head))
  (length lines))

(defmethod pane-replaces-transcript-p ((pane pane)) nil)
(defmethod pane-self-windows-p ((pane pane)) nil)
(defmethod pane-cursor-rows ((pane pane) head) (declare (ignore head)) 0)
(defmethod pane-opens-at ((pane pane) head) (declare (ignore head)) 0)
(defmethod pane-esc-target ((pane pane)) :normal)
(defmethod pane-hint ((pane pane) head) (declare (ignore head)) nil)
(defmethod pane-enter ((pane pane) head) (declare (ignore head)) nil)

;;; ------------------------------------------------------- lines, per pane ;;;

(defmethod pane-lines ((pane help-pane) head cols room)
  (declare (ignore head room))
  (help-lines cols))

(defmethod pane-lines ((pane status-pane) head cols room)
  (declare (ignore room))
  (status-screen-lines head cols))

(defmethod pane-lines ((pane config-pane) head cols room)
  (declare (ignore room))
  (config-lines head (head-settings head) cols))

(defmethod pane-lines ((pane jobs-pane) head cols room)
  (declare (ignore room))
  (jobs-lines head cols))

(defmethod pane-lines ((pane subagents-pane) head cols room)
  (declare (ignore room))
  (subagent-lines head cols))

(defmethod pane-lines ((pane peek-pane) head cols room)
  (peek-lines head cols room))

(defmethod pane-lines ((pane job-out-pane) head cols room)
  (job-out-lines head cols room))

(defmethod pane-lines ((pane picker-pane) head cols room)
  (declare (ignore room))
  (picker-lines (head-session head) (head-picker-sel head) cols))

(defmethod pane-lines ((pane todos-pane) head cols room)
  (declare (ignore room))
  (todos-lines head cols))

(defmethod pane-lines ((pane slash-pane) head cols room)
  (slash-out-lines head cols room))

(defmethod pane-lines ((pane lisp-pane) head cols room)
  (declare (ignore room))
  ;; the REPL's second value is NIL on purpose — ↑↓ walk the forms you evaluated, so
  ;; a cursor here would be a second meaning for one key (`lisp-pane-lines` says so).
  (lisp-pane-lines head cols))

(defmethod pane-lines ((pane dash-pane) head cols room)
  (declare (ignore head room))
  ;; **ONE VALUE, and that is a requirement rather than a style** — the frame's
  ;; `multiple-value-setq` would take the panel-starts vector as a cursor LINE.
  (values (dash-frame-lines cols :nav *dash-nav*)))

;;; ------------------------------------------------------- totals, per pane ;;;

(defmethod pane-total ((pane peek-pane) head lines)
  (declare (ignore head lines))
  *peek-total*)

(defmethod pane-total ((pane job-out-pane) head lines)
  (declare (ignore head lines))
  *job-out-total*)

;;; ------------------------------------------------------- the frame's questions ;;;

(dolist (class '(help-pane status-pane config-pane jobs-pane merge-queue-pane standing-notes-pane merge-detail-pane term-pane subagents-pane peek-pane
                 job-out-pane picker-pane todos-pane slash-pane dash-pane lisp-pane))
  (eval `(defmethod pane-replaces-transcript-p ((pane ,class)) t)))

(defmethod pane-self-windows-p ((pane peek-pane)) t)
(defmethod pane-self-windows-p ((pane job-out-pane)) t)

;;; ----------------------------------------------------------- the cursor ;;;

;; **THE STOPS, NOT THE ROWS** — the finished group is one stop over many rows, and a
;; cursor that counted rows would run off the end of the drawn list every time the
;; group was folded (see `subagents-stops`).
(defmethod pane-cursor-rows ((pane subagents-pane) head) (length (subagents-stops head)))
(defmethod pane-cursor-rows ((pane jobs-pane) head) (length (head-jobs head)))
(defmethod pane-cursor-rows ((pane merge-queue-pane) head) (length (head-merge-queue head)))

(defmethod pane-lines ((pane merge-detail-pane) head cols room)
  "ONE entry of the merge queue, in full — the second view of the same list.

**THE DATA IS ALREADY ON THE HEAD**, which is what makes this view cheap: `MergeEntry` carries the
reviews and the gate steps, so unlike the jobs pane's overlay this one sends NO frame. It draws the
entry's own rows, its reviews (three facts kept apart by `merge-review-line`) and its gate steps.
The entry comes from `*merge-detail*`, which `pane-enter` on the queue pane sets."
  (declare (ignore room))
  (let ((e *merge-detail*))
    (if (null e)
        (list (list (cons "no entry — the queue moved under this view; esc returns to the list"
                          '(:dim t))))
        (append
         (list (list (cons (format nil "entry ~a  " (or (getf e :id) "?")) '(:bold t))
                     (cons (or (getf e :branch) "?") nil)
                     (cons (format nil "  [~a]" (or (getf e :state) "?"))
                           (merge-state-style (or (getf e :state) ""))))
               nil)
         (let ((out nil))
           (when (getf e :priority)
             (push (list (cons (format nil "  priority ~a" (getf e :priority)) '(:dim t))) out))
           (when (getf e :needs)
             (push (list (cons (format nil "  needs ~{~a~^, ~}" (getf e :needs)) '(:dim t))) out))
           (push (list (cons (format nil "  ~a" (or (getf e :evidence) "no reason given")) '(:dim t))) out)
           (when (and (getf e :brief) (plusp (length (getf e :brief))))
             (push nil out)
             (push (list (cons "  the ask:" '(:dim t))) out)
             (push (list (cons (format nil "    ~a" (getf e :brief)) nil)) out))
           (when (getf e :reviews)
             (push nil out)
             (push (list (cons "  reviews" '(:bold t))) out)
             (dolist (r (getf e :reviews))
               (let ((line (merge-review-line r)))
                 (when line (push (list (cons (format nil "    ~a" line) '(:dim t))) out)))))
           (when (getf e :gate-steps)
             (push nil out)
             (push (list (cons "  the gate" '(:bold t))) out)
             (dolist (step (getf e :gate-steps))
               (push (list (cons (format nil "    ~a ~a" (or (getf step :outcome) "?")
                                         (or (getf step :command) ""))
                                 (merge-state-style (if (string-equal (getf step :outcome) "green")
                                                        "landed" (getf step :outcome)))))
                     out)))
           (push nil out)
           (push (list (cons "  esc returns to the queue, on the row you chose" '(:dim t))) out)
           (nreverse out))))))

(defmethod pane-cursor-rows ((pane merge-detail-pane) head)
  ;; a VIEW, not a list: nothing to walk, which is what the cursor row count says
  (declare (ignore head)) 0)

(defmethod pane-esc-target ((pane merge-detail-pane)) :queue)

(defmethod pane-hint ((pane merge-detail-pane) head)
  (declare (ignore head))
  (list (cons "esc returns to the queue" '(:dim t))))

(defun %term-lines-from-output (output)
  "OUTPUT as the lines a reader sees — LINE DISCIPLINE, not a screen.

**`#\return` OVERWRITES, IT DOES NOT CLEAR** (measured, `TODO.md`): it moves to column 0 and what
follows replaces the characters there, column by column. So `'a\\r\\n'` is the line `a` — the return is
the first half of that line ending — while `'10%\\r50%\\r100%'` is ONE line, `100%`, which is how a
progress bar redraws itself. A buffer and a column index model both; a string that gets reset models
only the second.

Cursor addressing, scroll regions and the alternate screen are the VT renderer's job — the pane SAYS
so rather than drawing a confident wrong screen, because a wrong screen makes the missing half
invisible, which is worse than missing it.

Trailing blanks are trimmed: a line overwritten by a shorter one would otherwise carry the old
tail's spaces as a ragged gap."
  (let ((out nil) (buf (make-string 0)) (col 0) (dropped 0) (esc-p nil) (csi-p nil)
        (csi-args ""))
    (labels ((put (ch)
               (when (>= col (length buf))
                 (setf buf (concatenate 'string buf (make-string (1+ (- col (length buf)))
                                                                 :initial-element #\space))))
               (setf (char buf col) ch)
               (incf col))
             (emit ()
               (push (string-right-trim '(#\space) buf) out)
               (setf buf (make-string 0) col 0)))
      (loop for ch across output do
        (cond ((char= ch #\newline) (emit))
              ((char= ch #\return) (setf col 0))
              ;; the same rule in the line model, where there is no right edge to clamp against: a
              ;; tab lands ON a column, it does not lay down eight blanks.
              ((char= ch #\tab) (setf col (* 8 (1+ (floor col 8)))))
              ;; **A CONTROL SEQUENCE IS DROPPED AND COUNTED, never drawn and never faked.** `ESC [ …`
              ;; is cursor addressing, colour and erasure — the VT renderer's job, which this head does
              ;; not have. Drawing it would put `[0m` mid-line; honouring it would be worse. The count is
              ;; the SECOND value, so a caller that wants lines is unaffected (two values and not a cons:
              ;; a cons would change this function's shape for callers written an hour ago, which is a
              ;; signature change wearing a feature's clothes).
              ;;
              ;; Two flags rather than lookahead, because this walk is character by character: ESC starts
              ;; a sequence, `[` makes it a CSI one, and a byte in `@`..`~` ends it — which is the rule
              ;; the notation itself is built on.
              ((char= ch #\escape) (incf dropped) (setf esc-p t csi-args ""))
              (esc-p (setf esc-p nil csi-p (char= ch #\[)))
              ;; **THE PARAMETER IS READ, so two sequences that differ only by their argument can be
              ;; told apart.** `2 J` clears the screen — honourable in a line model, where clearing is
              ;; *drop what has been drawn* — while a bare `J` erases below a cursor this head cannot
              ;; place, so it stays COUNTED. Flat arms rather than nested ones: four clauses that each
              ;; say one thing are easier to keep balanced than one clause with three conds inside it.
              ((and csi-p (<= 48 (char-code ch) 57))
               (setf csi-args (concatenate 'string csi-args (string ch))))
              ((and csi-p (char= ch #\K))
               (setf csi-p nil csi-args "")
               (setf buf (subseq buf 0 (min col (length buf)))))
              ((and csi-p (char= ch #\J) (string= csi-args "2"))
               (setf csi-p nil csi-args "")
               (setf out nil buf (make-string 0) col 0))
              ((and csi-p (<= 64 (char-code ch) 126))
               (setf csi-p nil csi-args ""))
              (t (put ch))))
      (emit))
    (values (nreverse out) dropped)))

;;; **THE SCREEN IS LANDED, AND VERIFIED IN ISOLATION: the suite cannot run in this session**
;;; (the exec memory cap is 64 MiB and SBCL dies under it -- a 56 MiB heap exhausts during GC,
;;; the default heap is killed by the kernel). So this code was checked by loading IT ALONE
;;; under a small heap and asserting ten behaviours: text at home, CR OVERWRITING and not
;;; clearing, three rows, SCROLLING past the bottom, CUP being 1-BASED as the notation is,
;;; EL and ED erasing WITHOUT MOVING THE CURSOR (two things that first looked like failures
;;; and were my expectations, not the code), SGR counted and leaving no text, wrapping at the
;;; right edge, and a bare escape counted. **The suite is owed a run on a box without that
;;; cap**; nothing calls this yet, so the tree is untouched by it.

;;; ------------------------------------------------------- the terminal's SCREEN ;;;
;;;
;;; **A ROWS x COLS GRID WITH A CURSOR — which is what a terminal IS.** The line model above
;;; (`%term-lines-from-output`) was the honest interim while there was no screen to draw into: it
;;; could honour an overwrite and an erase because both are expressible on a line, and it had to
;;; COUNT cursor addressing because a line has nowhere to put a row. This is where rows go.
;;;
;;; It is a PORT, not an invention (`rano/src/term/` on this box: 3021 lines across six modules —
;;; decode, event, features, graphics, links, terminal). The sequences below are the ones that
;;; matter for a program drawing in a pane; everything else is still COUNTED and still said.

(defstruct (term-screen (:constructor %make-term-screen (rows cols cells)))
  (rows 0 :type fixnum)
  (cols 0 :type fixnum)
  ;; a string, row-major: cell (r, c) is at (+ (* r cols) c)
  (cells "" :type string)
  (row 0 :type fixnum)
  (col 0 :type fixnum)
  ;; **THE SCROLLING REGION** (`DECSTBM`), 0-based and INCLUSIVE: a line feed on the BOTTOM row
  ;; scrolls these rows and nothing else, which is how a full-screen program keeps a status line put.
  ;; The whole screen until a program sets one.
  (top 0 :type fixnum)
  (bottom 0 :type fixnum)
  ;; **WHETHER THE PROGRAM WANTS A CURSOR ON THE GLASS** (`?25h`/`?25l`, DECTCEM). This is what the
  ;; program ASKED FOR and not what the head must draw — a pane shows a cursor only while it holds the
  ;; keyboard, which is the pane's fact and not the screen's — but a full-screen program that hid its
  ;; cursor while redrawing and never showed it again must not leave one this head invented.
  (visible t :type boolean)
  ;; the ALTERNATE screen when one is up (`?1049`): `(cells top bottom)` saved whole, or NIL on the
  ;; main screen. The region is saved WITH the cells because it is part of what the program expects
  ;; to find unchanged when it comes back.
  (main nil))

(defun term-screen-new (rows cols)
  "A blank screen, cursor at home, and the WHOLE screen as the scrolling region."
  (let* ((rows (max 1 rows)) (cols (max 1 cols))
         (s (%make-term-screen rows cols (make-string (* rows cols) :initial-element #\space))))
    (setf (term-screen-bottom s) (1- rows))
    s))

(defun %ts-index (s r c) (+ (* r (term-screen-cols s)) c))

(defun %ts-put (s ch)
  "Write CH at the cursor and advance, wrapping at the right edge — what a terminal does with a
full line, and why a program that prints a long line sees it break."
  (when (>= (term-screen-col s) (term-screen-cols s))
    (setf (term-screen-col s) 0)
    (%ts-next-row s))
  (when (< (term-screen-row s) (term-screen-rows s))
    (setf (char (term-screen-cells s) (%ts-index s (term-screen-row s) (term-screen-col s))) ch))
  (incf (term-screen-col s)))

(defun %ts-next-row (s)
  "Down one row, SCROLLING THE REGION when the cursor is on its BOTTOM margin — the bottom row is
where output lives, and a terminal that refused to scroll would draw nothing after the first
screenful. A row BELOW the region just moves down and stops at the last row, which is what a program
parking a status line outside its region relies on."
  (if (= (term-screen-row s) (term-screen-bottom s))
      (%ts-scroll s)
      (when (< (1+ (term-screen-row s)) (term-screen-rows s))
        (incf (term-screen-row s)))))

(defun %ts-scroll (s)
  "Scroll the REGION up one line — what a line feed on the bottom margin does. The cursor does not
move; dropping the top row of the region and blanking its bottom is the whole of it."
  (%ts-scroll-up-in s (term-screen-top s) (term-screen-bottom s) 1))

(defun %ts-scroll-up-in (s top bot n)
  "Shift the rows TOP..BOT up by N: N dropped off the top, N blank rows at the bottom. INCLUSIVE
margins, which is why the caller passes them 0-based."
  (let* ((cols (term-screen-cols s)) (cells (term-screen-cells s))
         (n (min n (1+ (- bot top)))))
    (loop for r from top to bot
          do (if (> (+ r n) bot)
                 (%ts-erase-row s r 0 cols)
                 (replace cells cells :start1 (%ts-index s r 0)
                                    :start2 (%ts-index s (+ r n) 0)
                                    :end2 (%ts-index s (+ r n) cols))))))

(defun %ts-scroll-down-in (s top bot n)
  "Shift the rows TOP..BOT down by N: N blank rows at the top, N pushed off the bottom. Copied in
REVERSE (bottom to top) so a row is read before it is overwritten."
  (let* ((cols (term-screen-cols s)) (cells (term-screen-cells s))
         (n (min n (1+ (- bot top)))))
    (loop for r from bot downto top
          do (if (< (- r n) top)
                 (%ts-erase-row s r 0 cols)
                 (replace cells cells :start1 (%ts-index s r 0)
                                    :start2 (%ts-index s (- r n) 0)
                                    :end2 (%ts-index s (- r n) cols))))))

(defun %ts-reverse-index (s)
  "`ESC M` — up one row, SCROLLING THE REGION DOWN when the cursor is on its top margin, which is the
mirror of a line feed at the bottom one."
  (if (= (term-screen-row s) (term-screen-top s))
      (%ts-scroll-down-in s (term-screen-top s) (term-screen-bottom s) 1)
      (when (plusp (term-screen-row s))
        (decf (term-screen-row s)))))

(defun %ts-set-scroll-region (s top bot)
  "`DECSTBM` — the region a line feed scrolls. 1-BASED and inclusive in the notation, 0-based here.
An inverted or empty region is IGNORED rather than clamped: a program that sent one made a mistake,
and inventing a region would move the cursor somewhere it never asked for. Setting one HOMES THE
CURSOR, which is what a full-screen program's next redraw depends on."
  (let ((top (max 0 (1- (or top 1))))
        (bot (min (1- (term-screen-rows s)) (1- (max 1 (or bot (term-screen-rows s)))))))
    (when (< top bot)
      (setf (term-screen-top s) top
            (term-screen-bottom s) bot
            (term-screen-row s) 0
            (term-screen-col s) 0))))

(defun %ts-erase-row (s row from to)
  (let ((cols (term-screen-cols s)))
    (loop for c from (max 0 from) below (min cols to)
          do (setf (char (term-screen-cells s) (%ts-index s row c)) #\space))))

(defun term-screen-cup (s row col)
  "Cursor position — `H`/`f`. Its arguments are 1-BASED in the notation and 0-based here."
  (setf (term-screen-row s) (min (1- (term-screen-rows s)) (max 0 (1- row)))
        (term-screen-col s) (min (1- (term-screen-cols s)) (max 0 (1- col)))))

(defun term-screen-el (s n)
  "Erase in line — `K`: 0 (default) to the end, 1 from the start, 2 the whole row."
  (let ((row (term-screen-row s)) (col (term-screen-col s)) (cols (term-screen-cols s)))
    (case n
      (0 (%ts-erase-row s row col cols))
      (1 (%ts-erase-row s row 0 (1+ col)))
      (2 (%ts-erase-row s row 0 cols)))))

(defun term-screen-ed (s n)
  "Erase in display — `J`: 0 below-and-right, 1 above-and-left, 2 everything."
  (let ((row (term-screen-row s)) (col (term-screen-col s)) (rows (term-screen-rows s))
        (cols (term-screen-cols s)))
    (case n
      (0 (%ts-erase-row s row col cols)
         (loop for r from (1+ row) below rows do (%ts-erase-row s r 0 cols)))
      (1 (%ts-erase-row s row 0 (1+ col))
         (loop for r from 0 below row do (%ts-erase-row s r 0 cols)))
      (2 (loop for r from 0 below rows do (%ts-erase-row s r 0 cols))))))

(defun term-screen-lines (s)
  "The rows as a reader sees them, right-trimmed — a blank row is an EMPTY line, not a row of spaces."
  (loop for r from 0 below (term-screen-rows s)
        collect (string-right-trim '(#\space)
                                   (subseq (term-screen-cells s) (%ts-index s r 0)
                                           (+ (%ts-index s r 0) (term-screen-cols s))))))

(defun %ts-erase-chars (s n)
  "Erase N characters from the cursor without moving it (`X`) — the screen keeps its shape and the
cells become blanks, which is different from DELETING them."
  (let ((row (term-screen-row s)))
    (%ts-erase-row s row (term-screen-col s) (+ (term-screen-col s) n))))

(defun %ts-delete-chars (s n)
  "Delete N characters at the cursor (`P`), pulling the rest of the row LEFT — the row gets shorter in
content, which is what makes a shell's redraw land where it should."
  (let* ((row (term-screen-row s)) (col (term-screen-col s)) (cols (term-screen-cols s))
         (cells (term-screen-cells s)) (start (%ts-index s row 0)))
    (loop for c from col below cols
          do (setf (char cells (+ start c))
                   (if (< (+ c n) cols) (char cells (+ start c n)) #\space)))))

(defun %ts-insert-chars (s n)
  "Insert N blanks at the cursor (`@`), pushing the rest of the row RIGHT and losing the far end."
  (let* ((row (term-screen-row s)) (col (term-screen-col s)) (cols (term-screen-cols s))
         (cells (term-screen-cells s)) (start (%ts-index s row 0)))
    (loop for c from (1- cols) downto col
          do (setf (char cells (+ start c))
                   (if (>= (- c n) col) (char cells (+ start (- c n))) #\space)))))

(defun %ts-insert-lines (s n)
  "Insert N blank lines at the cursor (`L`), pushing the lines below DOWN — WITHIN THE REGION, and
ONLY when the cursor is inside it, which is what stops a program's insert-line from touching a
status line below its region."
  (let ((row (term-screen-row s)) (bot (term-screen-bottom s)))
    (when (and (>= row (term-screen-top s)) (<= row bot))
      (%ts-scroll-down-in s row bot n))))

(defun %ts-delete-lines (s n)
  "Delete N lines at the cursor (`M`), pulling the lines below UP — within the region and only when
the cursor is inside it."
  (let ((row (term-screen-row s)) (bot (term-screen-bottom s)))
    (when (and (>= row (term-screen-top s)) (<= row bot))
      (%ts-scroll-up-in s row bot n))))

(defun term-screen-feed (s output)
  "Feed OUTPUT into SCREEN, honouring what can be honoured. Returns the count of sequences DROPPED.

A VT SUBSET and it says so: `CR`, `LF`, `BS`, `TAB`, the cursor moves (`A`–`D`, `H`/`f`), the erases
(`J`/`K`). SGR (`m`) is dropped on purpose — this head draws ROLES, not terminal colours — and
everything else is counted, never guessed at, which is the rule the pane keeps."
  (let ((dropped 0) (args "") (state :text) (n (length output)) (i 0)
        ;; `ESC [ ? …` is a PRIVATE sequence — the screen switch and the cursor are spelled that way,
        ;; and the `?` is not a digit, so it has to be remembered rather than skipped.
        (private nil))
    (labels ((num () (if (plusp (length args)) (or (parse-integer args :junk-allowed t) 0) 0))
             (arg1 () (if (plusp (length args)) (or (parse-integer args :junk-allowed t) 1) 1))
             (arg2 () (let ((semi (position #\; args)))
                        (if semi (or (parse-integer (subseq args (1+ semi)) :junk-allowed t) 1) 1)))
             ;; the same, but with a D of its own — `DECSTBM`'s bottom margin defaults to the last
             ;; row, and a 1 would put the region on the first row.
             (arg2-or (d) (let ((semi (position #\; args)))
                            (if semi (or (parse-integer (subseq args (1+ semi)) :junk-allowed t) d) d)))
             (seq (final)
               (case final
                 ((#\H #\f) (term-screen-cup s (arg1) (arg2)))
                 (#\K (term-screen-el s (num)))
                 (#\J (term-screen-ed s (num)))
                 ;; **`CUU` and `CUD` STOP AT THE REGION'S MARGIN when the cursor is inside it**, and
                 ;; can reach the screen's own edge when it is outside — which is what a terminal does
                 ;; and what a program that parks its cursor outside its region relies on.
                 (#\A (setf (term-screen-row s)
                            (max (if (>= (term-screen-row s) (term-screen-top s))
                                     (term-screen-top s)
                                     0)
                                 (- (term-screen-row s) (max 1 (num))))))
                 (#\B (setf (term-screen-row s)
                            (min (if (<= (term-screen-row s) (term-screen-bottom s))
                                     (term-screen-bottom s)
                                     (1- (term-screen-rows s)))
                                 (+ (term-screen-row s) (max 1 (num))))))
                 (#\C (setf (term-screen-col s)
                            (min (1- (term-screen-cols s))
                                 (+ (term-screen-col s) (max 1 (num))))))
                 (#\D (setf (term-screen-col s)
                            (max 0 (- (term-screen-col s) (max 1 (num))))))
                 ;; **THE REST OF THE COMMON SET** — the column and row jumps, the character
                 ;; operations, and the line operations. Each is a few lines because the screen keeps
                 ;; its own shape: a program that deletes a character expects the row to CLOSE UP, and
                 ;; one that inserts a blank expects it to OPEN, which is why these are not erases.
                 (#\G (setf (term-screen-col s) (min (1- (term-screen-cols s)) (max 0 (1- (arg1))))))
                 (#\d (setf (term-screen-row s) (min (1- (term-screen-rows s)) (max 0 (1- (arg1))))))
                 (#\X (%ts-erase-chars s (max 1 (num))))
                 (#\P (%ts-delete-chars s (max 1 (num))))
                 (#\@ (%ts-insert-chars s (max 1 (num))))
                 (#\L (%ts-insert-lines s (max 1 (num))))
                 (#\M (%ts-delete-lines s (max 1 (num))))
                 ;; **`DECSTBM`** — the scrolling region itself. `#\r` here is the LETTER r (the
                 ;; sequence's final byte), not a carriage return; a carriage return is `#\return`,
                 ;; which the text state handles above.
                 (#\r (%ts-set-scroll-region s (arg1) (arg2-or (term-screen-rows s))))
                 ;; **THE ALTERNATE SCREEN** (`?1049 h`/`l`) — what a full-screen program switches to
                 ;; so that leaving it restores what was on the screen before. Honoured HERE rather
                 ;; than left to the caller because it is a fact about the TERMINAL, and a program
                 ;; that opened one and found its output mixed into the shell's would be drawn wrong.
                 ;; The sizes are the same and the saved screen is kept whole.
                 ;; **THE ALT SCREEN IS SWAPPED IN PLACE, inside the ONE struct the pane holds** —
                 ;; a caller's reference to the screen stays valid, which is the difference between
                 ;; switching screens and replacing one. The main cells AND the region are kept
                 ;; whole and the alt one starts blank with whole-screen margins, which is what a
                 ;; full-screen program expects to find.
                 ;; **PRIVATE MODES, each on its own clause** — `?1049` is the alternate screen and
                 ;; `?25` is DECTCEM, the cursor itself. A private mode this build does not know is
                 ;; still counted with the sequence that carried it (`seq`'s caller does that).
                 ((#\h) (cond
                          ;; DECTCEM: a full-screen program shows the cursor when it is done drawing.
                          ((and private (string= args "25")) (setf (term-screen-visible s) t))
                          ((and private (string= args "1049") (null (term-screen-main s)))
                           (setf (term-screen-main s) (list (term-screen-cells s)
                                                            (term-screen-top s)
                                                            (term-screen-bottom s))
                                 (term-screen-cells s) (make-string (* (term-screen-rows s)
                                                                        (term-screen-cols s))
                                                                     :initial-element #\space)
                                 (term-screen-top s) 0
                                 (term-screen-bottom s) (1- (term-screen-rows s))
                                 (term-screen-row s) 0
                                 (term-screen-col s) 0))))
                 ((#\l) (cond
                          ((and private (string= args "25")) (setf (term-screen-visible s) nil))
                          ((and private (string= args "1049") (term-screen-main s))
                           (destructuring-bind (cells top bot) (term-screen-main s)
                             (setf (term-screen-cells s) cells
                                   (term-screen-top s) top
                                   (term-screen-bottom s) bot
                                   (term-screen-main s) nil
                                   (term-screen-row s) 0
                                   (term-screen-col s) 0)))))
                 (t nil))
               (setf args "" state :text private nil)))
      (loop while (< i n) do
        (let ((ch (char output i)))
          (case state
            (:text (case ch
                     (#\newline (setf (term-screen-col s) 0) (%ts-next-row s))
                     (#\return (setf (term-screen-col s) 0))
                     ;; **`TAB` moves to the next multiple-of-eight COLUMN — it does not insert eight
                     ;; blanks** (the reference's `tab`). The difference shows the moment the cursor is
                     ;; not already on a stop: `ab<TAB>Z` puts `Z` at column 8, not column 10.
                     (#\tab (setf (term-screen-col s)
                                   (min (1- (term-screen-cols s))
                                        (* 8 (1+ (floor (term-screen-col s) 8))))))
                     (#\backspace (when (plusp (term-screen-col s)) (decf (term-screen-col s))))
                     (#\escape (setf state :esc))
                     (t (%ts-put s ch)))
                   (incf i))
            (:esc (cond ((char= ch #\[) (setf state :csi))
                        ;; `ESC M` is REVERSE INDEX — one row up, scrolling the region down at its
                        ;; top margin. Honoured because the region is what it scrolls, and the
                        ;; region is now here; every other two-byte `ESC x` is still counted.
                        ((char= ch #\M) (%ts-reverse-index s) (setf state :text))
                        (t (incf dropped) (setf state :text)))
                  (incf i))
            (:csi (cond ((<= 48 (char-code ch) 57)
                         (setf args (concatenate 'string args (string ch)))
                         (incf i))
                        ((char= ch #\?) (setf private t) (incf i))
                        ((char= ch #\;)
                         (setf args (concatenate 'string args ";"))
                         (incf i))
                        ((<= 64 (char-code ch) 126)
                         (incf dropped) (seq ch) (incf i))
                        (t (incf i))))))))
    dropped))

(defun %term-screen-row-segments (s row)
  "One row of SCREEN as pane SEGMENTS, with the CURSOR CELL reversed when the program asked for a
cursor (`?25h`).

**The characters are the same either way.** The cursor is a STYLE on one cell and never a character,
so a reader (or a test) that reads the text out of the pane still reads exactly what the program
wrote — and a cursor past the end of the trimmed line is drawn in the space it would occupy, which
is where a shell's cursor sits after a command it has already drawn."
  (let* ((cols (term-screen-cols s))
         (text (string-right-trim '(#\space)
                                  (subseq (term-screen-cells s) (%ts-index s row 0)
                                          (+ (%ts-index s row 0) cols))))
         (line (format nil "  ~a" text))
         (at (+ 2 (min (term-screen-col s) (length text)))))
    (if (not (and (term-screen-visible s) (= row (term-screen-row s))))
        (list (cons line nil))
        (cond ((< at (length line))
               (append (list (cons (subseq line 0 at) nil)
                             (cons (string (char line at)) '(:reverse t)))
                       (let ((after (subseq line (1+ at))))
                         (when (plusp (length after)) (list (cons after nil))))))
              ;; the cursor is past the text this row has: the cell it would overwrite is a blank
              (t (list (cons line nil) (cons " " '(:reverse t))))))))

(defmethod pane-lines ((pane term-pane) head cols room)
  "The terminal's bytes, as this head can HONESTLY draw them today, and the pane's own keys.

**THE WIRE IS NOT THE HARD PART** (measured, `TODO.md`): four client frames and three server ones,
four lines each — what turns BYTES into a screen is the EMULATOR, and this draws the bytes as text
because that is exactly what arrived. Inventing a screen would be a head pretending to be a terminal
it is not, which is the one thing that would make the missing half invisible."
  (declare (ignore room))
  (let ((term (head-term head)))
    (if (null term)
        (list (list (cons "no terminal — `!term` opens one in this session" '(:dim t))))
        (append
         (list (list (cons (format nil "term ~dx~d" (getf term :cols) (getf term :rows)) '(:bold t))))
         (when (getf term :ended)
           (list (list (cons (format nil "  ended: ~a" (getf term :ended)) '(:fg :yellow)))))
         (list nil)
         (let ((out nil))
           ;; **THE SCREEN IS WHAT IS DRAWN NOW** — a program that addressed its cursor is drawn
           ;; where it put it, which is the whole difference between this and the line model the
           ;; first cut used. The line model stays below as the fallback for a terminal that has no
           ;; screen (a frame from a daemon that never attached a rectangle).
           (let ((screen (getf term :screen)))
             (if screen
                 ;; **EVERY ROW, AS SEGMENTS, so the cursor cell can carry its own style** — see
                 ;; `%term-screen-row-segments`. The header and the footer below are the pane's own.
                 (dotimes (r (term-screen-rows screen))
                   (push (%term-screen-row-segments screen r) out))
                 (dolist (line (%term-lines-from-output (or (getf term :output) "")))
                   (push (list (cons (format nil "  ~a" line) nil)) out))))
           (nreverse out))
         (list nil)
         (list (list (cons "  keys go to the program · q closes the pane" '(:dim t))))
         (list (list (cons "  line discipline only — the VT renderer is this pane's remaining half"
                           '(:dim t))))))))

(defmethod pane-cursor-rows ((pane term-pane) head) (declare (ignore head)) 0)

(defmethod pane-hint ((pane term-pane) head)
  (declare (ignore head))
  (list (cons "keys go to the program · q closes the pane and ends the terminal" '(:dim t))))

(defmethod pane-lines ((pane standing-notes-pane) head cols room)
  "The standing notes' rows — the drawing is `standing-notes-lines`, landed ahead of this pane."
  (declare (ignore room))
  (standing-notes-lines head cols))

(defmethod pane-cursor-rows ((pane standing-notes-pane) head) (length (head-standing-notes head)))

(defmethod pane-hint ((pane standing-notes-pane) head)
  "What the standing-notes pane's own key does — `q` closes it, as every pane's does."
  (declare (ignore head))
  (list (cons "q closes · asked again whenever this pane opens" '(:dim t))))

(defmethod pane-lines ((pane merge-queue-pane) head cols room)
  "The queue's rows — the drawing is `merge-queue-lines`, landed ahead of this pane so the pane is
registration rather than a pile of drawing (see `TODO.md`'s merge-queue box)."
  (declare (ignore room))
  (merge-queue-lines head cols))

(defmethod pane-hint ((pane merge-queue-pane) head)
  "What the queue pane's own keys do — `q` closes it, and the gate runs when a branch is picked."
  (declare (ignore head))
  (list (cons "q closes · the gate runs when a branch is picked" '(:dim t))))
(defmethod pane-cursor-rows ((pane todos-pane) head)
  (length (repo-todo-rows-cached
           (getf (session-wiring (head-session head)) :workspace))))
(defmethod pane-cursor-rows ((pane picker-pane) head)
  (length (picker-sessions (head-session head))))
(defmethod pane-cursor-rows ((pane config-pane) head) (length (config-rows head)))
;; the peek pane's rows are its BODY lines, and answering 0 was the whole of its arrow
;; keys: `move-cursor` clamped to `(1- 0)` while the pane's own last line advertised
;; that they scroll
(defmethod pane-cursor-rows ((pane peek-pane) head) (peek-row-count head))
(defmethod pane-cursor-rows ((pane job-out-pane) head) (job-out-row-count head))
;; **THE REPL HAS NO CURSOR, and this line is a CLAIM rather than a default** (the old
;; `case` said the same): ↑↓ are the composer's history here, so a count that answered
;; anything else would let `move-cursor` walk a selection nobody can see. Written out
;; rather than left to the base method so that a later edit cannot quietly make it
;; selectable.
(defmethod pane-cursor-rows ((pane lisp-pane) head) (declare (ignore head)) 0)

(defmethod pane-opens-at ((pane picker-pane) head) (picker-initial-sel head))

(defmethod pane-esc-target ((pane peek-pane)) :subagents)
(defmethod pane-esc-target ((pane job-out-pane)) :jobs)

;;; ------------------------------------------------------------- the hint bar ;;;
;;;
;;; The strings moved here from `chrome.lisp`'s `cond`, unchanged — including the
;;; `:jobs` arm that asked the PANELS whether `d` would do anything, because a hint
;;; that offers a key which does nothing on this row is worse than a shorter hint.
;;;
;;; **A second, DEAD `:jobs` arm is not carried over.** The old `cond` had one at
;;; `chrome.lisp:1415` reading *"background jobs this session started · …"*, and the
;;; arm above it matched `:jobs` first, so it had never been drawn. Same words, same
;;; place, one arm.

(defmethod pane-hint ((pane help-pane) head) (declare (ignore head)) "esc closes this")
(defmethod pane-hint ((pane status-pane) head) (declare (ignore head)) "esc closes this")

(defmethod pane-hint ((pane slash-pane) head)
  (declare (ignore head))
  "↑↓ and the wheel scroll · esc closes")

(defmethod pane-hint ((pane picker-pane) head)
  (declare (ignore head))
  "type a number to switch · /new [title] · esc closes")

(defmethod pane-hint ((pane todos-pane) head)
  (declare (ignore head))
  "↑↓ moves · enter or tab unfolds · pgup/pgdn and the wheel scroll · esc closes")

;; the dashboard's hint is GENERATED FROM ITS OWN BINDING TABLE (dash.lisp), so a pane
;; that offers a key it does not have cannot describe itself that way — serenedash's
;; rule, and the same reason the key bar there is built from `BINDINGS` rather than typed
(defmethod pane-hint ((pane dash-pane) head)
  (declare (ignore head))
  (format nil "~a · esc closes" (dash-bindings)))

(defmethod pane-hint ((pane config-pane) head)
  (declare (ignore head))
  "arrows move · enter changes a row marked ✎ · esc closes")

(defmethod pane-hint ((pane subagents-pane) head)
  (declare (ignore head))
  "subagents this session spawned · enter or o switches into one · p its prompt · esc closes")

(defmethod pane-hint ((pane jobs-pane) head)
  (if (dash-panel-for-job (nth (head-picker-sel head) (head-jobs head)))
      "↑↓ moves · enter reads the output · d opens its dashboard · esc closes"
      "↑↓ moves · enter reads the output · esc closes"))

;; enter IS the pane here, so the hint names it — and it names the arrows as the
;; COMPOSER's, which is what they are (`%pane-key` refuses them for `:lisp` so they walk
;; the forms you evaluated). A hint bar that called them "scroll" would be teaching a
;; key this pane does not have.
(defmethod pane-hint ((pane lisp-pane) head)
  (declare (ignore head))
  "enter evaluates the prompt · ↑↓ walks the forms you evaluated · pgup/pgdn scrolls · esc closes")

(defmethod pane-hint ((pane peek-pane) head)
  (declare (ignore head))
  "tails live · arrows scroll · esc back")

(defmethod pane-hint ((pane job-out-pane) head)
  (declare (ignore head))
  ;; ESC BACK TO JOBS, not "closes": the jobs list never closed under it, and a bottom
  ;; row that says `esc closes` on a pane that goes back one level teaches the wrong
  ;; thing about the key (app.rs:5424). **And the PAGE keys are named only where they
  ;; act** (R41), through `job-out-pages` — the same function the pane's own footer
  ;; uses. Two plain conditionals and not two `~@[ … ~]`: measured on this SBCL,
  ;; `(format nil "|~@[A~]~@[B~]|" 1 nil)` answers `"|AB|"`, so the compressed spelling
  ;; would promise the very keys this exists to drop.
  (let ((pages (job-out-pages)))
    (format nil "↑↓ scroll~a~a · enter re-reads · esc back to jobs"
            (if (getf pages :next) " · → next page" "")
            (if (getf pages :back) " · ← back" ""))))
