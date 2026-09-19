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

;;; ------------------------------------------------------- item rendering ;;;
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
         ((:tool_result)
          (let* ((name (getf body :name))
                 (outcome (getf body :outcome))
                 (payload (getf body :payload))
                 (lines (list (list (cons "  · " '(:fg :bright-black))
                                    (cons name '(:bold t))
                                    (cons " → " '(:fg :bright-black))
                                    (cons (outcome-name outcome) (%outcome-style outcome))))))
            (when (getf prefs :show-tools)
              (let ((preview (%first-line payload)))
                (when (plusp (length preview))
                  (setf lines
                        (append lines
                                (wrap-segments
                                 (list (cons "    " '(:fg :bright-black))
                                       (cons preview '(:fg :bright-black)))
                                 (max 4 (- cols 4))))))))
            lines))
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
              (getf turn :calls)))))

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


