;;;; cards.lisp — the card vocabulary: one transcript row, one tool call, the
;;;; running turn, and the cards that ride above the composer.
;;;;
;;;; `item-lines` renders a committed transcript row and is what the viewport
;;;; is built from; `call-lines` and `turn-lines` render the live turn; the
;;;; decision, quit and secret cards are here because they are cards, while the
;;;; frame furniture is `chrome.lisp`.
;;;;
;;;; An item is a WIRE PLIST and never an object (PLAN.md D4, §7): a model must
;;;; be able to read exactly what the daemon sent. To render a row type this head
;;;; has never seen, specialise on the kind keyword and leave the data alone —
;;;; HACKING.md, "Wire state stays a plist".

(in-package #:leticl)

;;; ------------------------------------------------------- the item-id maps ;;;
;;;
;;; ## Why this exists
;;;
;;; The live card knows three things the settled row does not: how long the call
;;; took, both sides of the file it changed, and the decision that gated it. A
;;; `TranscriptItem::ToolResult` carries the tool's prose and **no timestamps at
;;; all** (`edit` is display-only, lib.rs:74), so the moment the row lands those
;;; facts leave the screen — which is exactly what happened, and the operator
;;; reported it twice: *"nothing really shown"*, and *"past edits lose their diff
;;; panels"*.
;;;
;;; ## Why the key is the item id and not the call id
;;;
;;; A call id is **round-positional**: the engine assigns `call_{n}` from the
;;; round's own call list, so every round of every turn starts again at `call_0`.
;;; A table keyed on it alone has all fourteen rounds of a long turn writing the
;;; same three keys, and every settled card reads back whichever round wrote last
;;; — which is how a head comes to name a file the tool never opened. An item id
;;; is unique per row, so it cannot do that.
;;;
;;; Both are defvars, not `head` slots: a defstruct layout change is a hard error
;;; in this SBCL, so a slot would mean a restart.

(defvar *call-facts* nil
  "Alist CALL-ID → plist of what the live turn knows about one call: `:ms` (how
long it ran), `:edit` (both sides of the file it changed), `:decision` (what
gated it).

Keyed by the ROUND-POSITIONAL call id, so it is cleared at every round boundary
(`%round-boundary`). It is a STAGING table: facts land here from `tool_finished`
and `decision_answered`, and move to `*item-facts*` under the row's item id when
the transcript row arrives with its body.")

(defvar *item-facts* nil
  "Alist ITEM-ID → the same plist, once the row it belongs to exists.

The durable half, and what `%tool-result-lines` reads: this is what keeps a
settled row's diff, duration and approval on the screen after the live card is
gone. An item id is unique per row, so two rounds cannot collide here.")

(defvar *call-started-ms* nil
  "Alist CALL-ID → the monotonic ms when its ToolStarted arrived.

Neither `tool_finished` nor the row that lands afterwards carries a duration, so
the only way to keep *\"that grep took 4.1 s\"* on the screen is to have noted
when it began.")

(defun note-call-started (call-id)
  (when call-id
    (setf (alexandria:assoc-value *call-started-ms* call-id :test #'string=)
          (internal-real-time-ms))))

(defun note-call-finished (call-id &key edit)
  "Fold what ToolFinished carried into the staging table.

The facts plist is written THROUGH the place, never bound to a local first:
`(let ((f (assoc-value table k))) (setf (getf f :ms) …))` mutates the local and
leaves the table untouched, which is how the first version of this recorded
nothing at all while looking like it recorded something. A test caught it."
  (when call-id
    (let ((start (cdr (assoc call-id *call-started-ms* :test #'string=))))
      (when (numberp start)
        (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :ms)
              (max 0 (- (internal-real-time-ms) start)))))
    (when edit
      (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :edit)
            edit))))

(defun note-call-decision (call-id decision)
  "Attach the settled decision to its call, so a settled row shows what gated it."
  (when call-id
    (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :decision)
          decision)))

(defun %round-boundary ()
  "A round is over: the call ids in the staging table are about to be reused.

Called when an Assistant row lands, which is what delimits a round — the engine
appends a round's assistant row before generating the next, so no delta of round
N+1 can arrive before round N's row."
  (setf *call-facts* nil
        *call-started-ms* nil))

(defun item-facts (item-id)
  "What the live turn knew about the row ITEM-ID, or NIL."
  (and item-id (cdr (assoc item-id *item-facts* :test #'string=))))

(defun %adopt-call-facts (item-id call-id)
  "Move the staging facts for CALL-ID onto ITEM-ID, once the row exists.

This is the handover: the row is now the durable artifact, so the facts have to
be reachable from the ROW rather than from a call id that the next round will
reuse."
  (when (and item-id call-id)
    (let ((facts (cdr (assoc call-id *call-facts* :test #'string=))))
      (when facts
        (setf (alexandria:assoc-value *item-facts* item-id :test #'string=)
              (copy-list facts))))))

(defvar *pane-scroll* 0
  "Rows hidden ABOVE THE TOP of an open pane.

**The polarity is the opposite of `head-scroll` and that is not a detail.**
`head-scroll` counts rows back from the BOTTOM — it is a distance from the live
tail, so `up` increases it. A pane has no live tail: it is a fixed list, and its
offset is a distance from the START, so `down` increases it. Copying the
transcript's polarity makes PageDown a no-op that looks exactly like the bug it
replaced, which is how the reference found it — in its own test, after shipping
the wrong sign once.

One offset for every pane, because only one is open at a time. A per-pane offset
would be a `head` struct slot each, and a slot is a restart.")

(defvar *pane-lines* 0
  "How many lines the open pane's content has. The render sets it so the KEY
handler can clamp without re-rendering, and `*pane-room*` is how many of them fit.")

(defvar *pane-room* 0
  "How many rows the open pane's content may occupy, from the last render.")

(defun pane-scroll-max ()
  "The largest offset that still shows something."
  (max 0 (- *pane-lines* *pane-room*)))

(defun pane-scroll-by (n)
  "Move the pane by N rows, clamped to its content."
  (setf *pane-scroll* (max 0 (min (pane-scroll-max) (+ *pane-scroll* n)))))

(defun reset-pane-scroll ()
  "A newly opened pane starts at its top."
  (setf *pane-scroll* 0))

(defun pane-view (lines)
  "LINES, windowed by `*pane-scroll*` to `*pane-room*` rows.

The pane's own window function rather than `%place-lines`, because that one
clips from the top and a pane must be able to look past it. Returns the slice,
so the caller places it from the top of the body."
  ;; `let*`, not `let`: START's init form uses ROOM, and under `let` the init
  ;; forms are evaluated in the OUTER environment — so `room` would be a free
  ;; reference to cl:room, unbound. Same defect as `%render-and-paint`'s earlier
  ;; in this pass, and the same silent shape: it compiles.
  (let* ((room (max 1 *pane-room*))
         (start (max 0 (min (max 0 (- (length lines) room)) *pane-scroll*))))
    (subseq lines start (min (length lines) (+ start room)))))

(defun scroll-pane-into-view (sel)
  "Move the offset so the cursor on row SEL is visible.

The cursor scrolls ITSELF into view: a pane whose cursor can walk into rows that
are never drawn is a pane with a selection the operator cannot see, which is worse
than one that cannot scroll at all."
  (let ((room (max 1 *pane-room*)))
    (cond ((< sel *pane-scroll*) (setf *pane-scroll* sel))
          ((>= sel (+ *pane-scroll* room))
           (setf *pane-scroll* (max 0 (- (1+ sel) room)))))))

;;; ------------------------------------------------------- pane rendering ;;;
(defun %fold-cells (text)
  "A /cells message folds back out of the transcript at render time
(app.rs:6264): the delimited block becomes one marker line. Returns the
folded text, or the text unchanged when it holds no screen."
  (let ((start (search *cells-open* text)))
    (if (null start)
        text
        (let* ((head-end (search *cells-mark-end* text :start2 start))
               (close (search *cells-close* text)))
          (if (and head-end close)
              (concatenate 'string
                           (subseq text 0 start)
                           (subseq text start (+ head-end (length *cells-mark-end*)))
                           " …"
                           (subseq text (+ close (length *cells-close*))))
              text)))))

(defun %outcome-style (outcome)
  (switch ((outcome-name outcome) :test #'string=)
    ("ok" '(:fg :green))
    ("abstained" '(:fg :yellow))
    ("failed" '(:fg :red))
    ("denied" '(:fg :yellow))
    ("timeout" '(:fg :red))
    ("not_run" '(:fg :bright-black))
    ("backgrounded" '(:fg :cyan))
    (t nil)))

(defun %first-line (text)
  (if-let (nl (position #\newline text))
    (subseq text 0 nl)
    text))

(defun %tool-result-lines (item body cols prefs)
  "One settled tool-result row: the call, its outcome, its duration, its diff, and
the decision that gated it — everything the live card had.

The facts come from `item-facts` (see the header) and are ABSENT for a row this
head did not watch run: a snapshot, or a replay of a log recorded elsewhere. An
absent fact shows nothing rather than a fabricated `0ms`, which is the same rule
the reference's `Replayed` phase holds."
  (let* ((facts (item-facts (getf item :item-id)))
         (name (getf body :name))
         (outcome (getf body :outcome))
         (payload (getf body :payload))
         (ms (getf facts :ms))
         (edit (getf facts :edit))
         (decision (getf facts :decision))
         (headline
          (list (list (cons "  · " '(:fg :bright-black))
                      (cons (or name "tool") '(:bold t))
                      (cons " → " '(:fg :bright-black))
                      (cons (outcome-name outcome) (%outcome-style outcome))
                      ;; a duration only when one was MEASURED
                      (cons (if (numberp ms) (format nil " · ~a" (duration ms)) "")
                            '(:fg :bright-black)))))
         ;; the oracle's brief and reply, on the row rather than on a card that
         ;; has already left the screen
         (decision-line
          (when decision
            (let ((basis (getf decision :basis))
                  (verdict (getf (getf decision :outcome) :outcome)))
              (list (list (cons "    ⚖ " '(:fg :bright-black))
                          (cons (or verdict "answered") '(:fg :bright-black))
                          (cons (if basis (format nil " — ~a" (%first-line basis)) "")
                                '(:fg :bright-black)))))))
         (detail
          (when (getf prefs :show-tools)
            (cond
              ;; a file-editing call: both sides, as a real diff
              (edit (edit-lines edit cols :folded (not (getf prefs :tools-open))))
              (t (let ((preview (%first-line (or payload ""))))
                   (when (plusp (length preview))
                     (wrap-segments
                      (list (cons "    " '(:fg :bright-black))
                            (cons preview '(:fg :bright-black)))
                      (max 4 (- cols 4))))))))))
    (append headline decision-line detail)))

(defun item-lines (item cols prefs)
  "One transcript row to segment lines."
  (let ((body (item-body item)))
    (cond
      ((null body)
       (list (list (cons (format nil "[~a — content not loaded]" (item-kind item))
                         '(:fg :red)))))
      (t
       (case (intern (string-upcase (getf body :type)) :keyword)
         ((:user)
          (let ((text (%fold-cells (item-display-text item))))
            (wrap-segments
             (list (cons "› " '(:fg :bright-cyan :bold t))
                   (cons text nil))
             cols)))
         ((:assistant)
          (if (plusp (length (getf body :text)))
              (markdown-lines (getf body :text) nil)
              (list (list (cons "·" '(:fg :bright-black))))))
         ((:reasoning)
          (when (getf prefs :show-reasoning)
            (mapcar (lambda (segs)
                      (cons (cons "  " '(:fg :bright-black)) segs))
                    (wrap-segments
                     (list (cons (getf body :text) '(:italic t :fg :bright-black)))
                     (max 2 (- cols 2))))))
         ((:tool_result) (%tool-result-lines item body cols prefs))
         ((:system)
          (wrap-segments
           (list (cons "◦ " '(:fg :yellow))
                 (cons (item-display-text item) '(:fg :yellow)))
           cols))
         (t nil))))))

(defun call-lines (call cols)
  "One tool call of the running turn, with its state."
  (let* ((state (getf (getf call :state) :state))
         (style (if (string= state "finished")
                    (%outcome-style (getf (getf call :state) :outcome))
                    '(:fg :yellow)))
         (target (getf call :target))
         (note (getf call :progress-note))
         (label (switch (state :test #'string=)
                  ("finished" "done")
                  ("running" (or note "running"))
                  (t "proposed"))))
    (append
     (wrap-segments
      (list (cons "  · " '(:fg :bright-black))
            (cons (getf call :name) '(:bold t))
            (cons (if (plusp (length target))
                      (format nil " ~a" target) "")
                  '(:fg :bright-white))
            (cons (format nil " — ~a" label) style))
      cols)
     ;; a file-editing call carries both sides of the change, bounded to what
     ;; differs (event.rs:75) — the raw material of the diff view
     (awhen-edit-lines (getf (getf call :state) :edit) cols))))

(defun %edit-lines-text (text)
  "TEXT as a list of lines. An empty side is NO lines, not one empty line:
a pure insertion has no `before`, and rendering that as a blank line claims a
line was there (`ToolEditExcerpt::before` — \"empty when the side has no lines
in the range\")."
  (if (zerop (length text))
      nil
      (uiop:split-string text :separator '(#\newline))))

(defun edit-lines (edit cols &key (folded nil))
  "The diff of an EDIT, as segment lines.

This is the twice-requested diff, and it is why `render-diff` exists: the edit
carries both sides and the excerpt's place in each file, so the engine can show
hunks with context, line numbers, and word-level emphasis inside a changed line.
The old version printed every removed line and then every added line —
unnumbered, unemphasised, no context and no notion of what actually changed —
which is what the operator reported as *\"nothing really shown\"*.

`before_start`/`after_start` are 1-based lines of the WHOLE file, so the gutter
numbers the file and not the excerpt (\"a diff numbered from 1 tells the reader
line 4 changed when it was line 313\")."
  (when edit
    (let* ((path (getf edit :path))
           (created (getf edit :created))
           (head-line (list (list (cons (format nil "  ~a~a" path
                                                (if created " (new)" ""))
                                      '(:bold t :fg :cyan)))))
           (body (render-diff (%edit-lines-text (or (getf edit :before) ""))
                              (%edit-lines-text (or (getf edit :after) ""))
                              :width (max 20 (- cols 4))
                              :context 3
                              :line-numbers t
                              :intra-line t
                              :max-rows (if folded 8 60)
                              :old-start (or (getf edit :before-start) 1)
                              :new-start (or (getf edit :after-start) 1)))
           (tail (when (getf edit :truncated)
                   (list (list (cons
                                (format nil "  … the excerpt was capped; the file is ~a lines now"
                                        (or (getf edit :after-lines) 0))
                                '(:fg :bright-black)))))))
      (append head-line body tail))))

(defun awhen-edit-lines (edit cols)
  "Both sides of an edit, as a real diff. See `edit-lines`."
  (edit-lines edit cols))

(defun turn-lines (turn cols prefs)
  "The running turn, live: reasoning, text, calls. A finished turn renders
from the transcript instead (view.rs on TurnView.appended) — rendering both
would show the answer twice."
  (when (and turn (string= (turn-state-name turn) "running"))
    (append
     (when (getf prefs :show-reasoning)
       (alet (getf turn :reasoning)
         (when (plusp (length it))
           (mapcar (lambda (segs)
                     (cons (cons "  " '(:fg :bright-black)) segs))
                   (wrap-segments
                    (list (cons it '(:italic t :fg :bright-black)))
                    (max 2 (- cols 2)))))))
     (alet (getf turn :text)
       (when (plusp (length it))
         (markdown-lines it nil)))
     (mappend (lambda (c) (call-lines c cols))
              (getf turn :calls))
     ;; The raw `<function=…>` markup the model wrote, when ctrl-x has asked for
     ;; it. NOT a fold: a fold hides something the reader knows is there, while
     ;; this reveals markup the default view is required never to show, so it is
     ;; off unless asked for by name.
     (when (getf prefs :raw-calls)
       (let ((raw (getf turn :raw-calls)))
         (when (and (stringp raw) (plusp (length raw)))
           (mapcar (lambda (l) (list (cons "    " '(:fg :bright-black))
                                     (cons l '(:fg :bright-black))))
                   (uiop:split-string raw :separator '(#\newline)))))))))

(defun decision-card-lines (head cols)
  "The ask card: transcript visible above, one list on the screen at a time
(agents.md). A permission has the ladder; a question has choices."
  (let ((d (first (session-open-decisions (head-session head)))))
    (when d
      (let* ((kind (getf d :kind))
             (question (string= kind "question"))
             (options (if question (getf d :choices) (getf d :options)))
             (sel (head-decision-sel head))
             (body nil))
        (push (list (cons (format nil " ~a " (if question "question" "permission"))
                          '(:bold t :fg :yellow))
                    (cons (format nil " ~a" (or (getf d :summary) ""))
                          '(:bold t)))
              body)
        (when (plusp (length (or (getf d :target) "")))
          (push (list (cons " " '(:fg :yellow))
                      (cons (getf d :target) '(:fg :bright-white)))
                body))
        (when (plusp (length (or (getf d :detail) "")))
          (push (list (cons (format nil " ~a" (getf d :detail))
                            '(:fg :bright-black)))
                body))
        (when (plusp (length (or (getf d :because) "")))
          (push (list (cons (format nil " because: ~a" (getf d :because))
                            '(:italic t :fg :bright-black)))
                body))
        (let ((i 0))
          (dolist (o options)
            (let* ((label (if question o (getf o :label)))
                   (chosen (= i sel))
                   (style (cond (chosen '(:reverse t :bold t))
                                (t nil))))
              (push (list (cons (format nil " ~a ~a. " (if chosen "❯" " ") (1+ i)) style)
                          (cons (or label "?") style))
                    body))
            (incf i)))
        (push (list (cons (format nil " enter answers · up/down moves · esc ~a"
                                  (if question "leaves it open" "does nothing"))
                          '(:fg :bright-black)))
              body)
        (nreverse body)))))

(defun quit-card-lines (head cols)
  (declare (ignore cols))
  (flet ((row (i label)
           (let ((chosen (= i (head-quit-sel head))))
             (list (cons (format nil " ~a ~a" (if chosen "❯" " ") label)
                         (if chosen '(:reverse t :bold t) nil))))))
    (list (list (cons " quit " '(:bold t :fg :yellow))
                (cons " the turn runs in the daemon: closing this window does not stop it"
                      '(:fg :bright-black)))
          (row 0 "leave — the head detaches, the daemon keeps going")
          (row 1 "leave and stop the daemon")
          (list (cons " enter chooses · esc takes it back" '(:fg :bright-black))))))

(defun secret-card-lines (head cols)
  (declare (ignore cols))
  (let ((req (head-secret-req head)))
    (when req
      (list (list (cons " sudo " '(:bold t :fg :yellow))
                  (cons (format nil " ~a" (getf req :prompt)) '(:bold t)))
            (list (cons " for " '(:fg :bright-black))
                  (cons (getf req :command) '(:fg :bright-white)))
            (list (cons " password: " '(:fg :bright-cyan :bold t))
                  (cons (make-string (length (head-secret-buf head))
                                     :initial-element #\*)
                        nil))
            (list (cons " enter submits · esc refuses" '(:fg :bright-black)))))))


