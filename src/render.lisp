;;;; render.lisp — state to cells. Ported from crates/tui/src/render.rs's
;;;; shape: the transcript is lines of styled segments, wrapped to the width;
;;;; chrome is a top border and a status line; cards ride above the composer;
;;;; full-body screens replace the transcript. Everything here is a plain
;;;; function so a model can redefine any layer of it live (PLAN.md §1).

(in-package #:leticl)

;;; /cells delimiters — copied from app.rs:868 so a leticl screen folds out of
;;; a Rust transcript and vice versa. Kept beside the command that writes them
;;; (head.lisp) so the pair cannot drift.
(defparameter *cells-open* (format nil "⟦screen "))
(defparameter *cells-mark-end* "⟧")
(defparameter *cells-close* "⟦end screen⟧")

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
         ((:tool-result)
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

(defun awhen-edit-lines (edit cols)
  "Both sides of an edit as a unified view: - before, + after."
  (when edit
    (let ((lines (list (list (cons (format nil "    ~a~a"
                                         (getf edit :path)
                                         (if (getf edit :created) " (new)" ""))
                                   '(:bold t :fg :cyan))))))
      (flet ((side (text prefix style)
               (when (plusp (length text))
                 (dolist (l (uiop:split-string text :separator '(#\newline)))
                   (push (list (cons (format nil "    ~a " prefix) style)
                               (cons l style))
                         lines)))))
        (side (getf edit :before) "-" '(:fg :red))
        (side (getf edit :after) "+" '(:fg :green)))
      (when (getf edit :truncated)
        (push (list (cons "    … truncated" '(:fg :bright-black))) lines))
      (nreverse lines))))

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

;;; ------------------------------------------------------------- screens ;;;

(defun picker-lines (session sel cols)
  "The session picker: every row the daemon sent, current one marked."
  (let ((lines (list (list (cons " sessions " '(:bold t)))))
        (i 0))
    (dolist (s (session-sessions session))
      (let* ((current (string= (getf s :session-id) (session-session-id session)))
             (title (if (plusp (length (or (getf s :title) "")))
                        (getf s :title) "(unnamed)"))
             (style (cond ((= i sel) '(:reverse t))
                          (current '(:fg :bright-cyan))
                          (t nil))))
        (push (list (cons (format nil " ~a ~a" (if current "●" " ") title) style))
              lines))
      (incf i))
    (nreverse lines)))

(defun help-lines (cols)
  (declare (ignore cols))
  (append
   (list (list (cons " leticl keys " '(:bold t))))
   (mapcar (lambda (pair)
             (list (cons (format nil "  ~a" (car pair)) '(:bold t))
                   (cons (format nil "  ~a" (cdr pair)) '(:fg :bright-black))))
           '(("enter" . "send the line")
             ("ctrl+c" . "interrupt the running turn")
             ("ctrl+d" . "quit")
             ("pgup/pgdn" . "scroll the transcript")
             ("up/down" . "history, or move in lists")
             ("tab" . "complete a slash command")))
   (list nil (list (cons " commands " '(:bold t))))
   (mapcar (lambda (pair)
             (list (cons (format nil "  /~a" (car pair)) '(:fg :cyan))
                   (cons (format nil "  ~a" (cdr pair)) '(:fg :bright-black))))
           *slash-commands*)))

(defparameter *slash-commands*
  '(("new" . "TITLE — start a fresh session")
    ("sessions" . "the session picker")
    ("switch" . "ID — go to another session")
    ("rename" . "NAME — name the session you are in")
    ("help" . "the key and command reference")
    ("status" . "telemetry, full screen")
    ("think" . "fold or unfold the model's reasoning")
    ("tools" . "fold or unfold tool output")
    ("config" . "every setting, as the daemon reports it")
    ("mode" . "NAME — move this session's project to a mode")
    ("jobs" . "the background-jobs pane")
    ("subagents" . "the subagent tree")
    ("cells" . "MESSAGE — send it with a copy of this screen")
    ("compact" . "summarise this session and fork it")
    ("reseat" . "rebuild the prompt from the tools seated now")
    ("interrupt" . "stop the running turn")
    ("quit" . "leave the head")))

(defun status-screen-lines (head cols)
  (let* ((s (head-session head))
         (w (session-wiring s))
         (turn (session-turn s))
         (usage (when turn (getf (getf turn :state) :usage))))
    (flet ((row (k v)
             (list (cons (format nil "  ~a " k) '(:bold t))
                   (cons (format nil "~a" v) '(:fg :bright-white)))))
      (append
       (list (list (cons " status " '(:bold t))))
       (list (row "session" (session-session-id s)))
       (list (row "title" (if (plusp (length (session-title s)))
                              (session-title s) "(unnamed)")))
       (list (row "model" (format nil "~a @ ~a"
                                  (getf w :model) (getf w :endpoint))))
       (list (row "role" (getf w :role)))
       (list (row "head" (format nil "~a (~a)" (session-head-id s) "leticl")))
       (list (row "seq" (session-seq s)))
       (list (row "dropped" (format nil "~a events, ~a items"
                                    (session-dropped s)
                                    (session-items-dropped s))))
       (list (row "heads" (length (session-heads s))))
       (list (row "items" (length (session-items s))))
       (when usage (list (row "usage" usage)))
       (list nil)
       (list (row "warnings" (length (session-warnings s))))
       (list (row "denials" (length (session-denials s))))))))

(defun config-lines (settings cols)
  (declare (ignore cols))
  (append
   (list (list (cons " settings " '(:bold t))
               (cons "  (the daemon owns this list; it ships with the setting)"
                     '(:fg :bright-black))))
   (mapcar (lambda (r)
             (list (cons (format nil "  ~a" (getf r :name)) '(:bold t))
                   (cons (format nil "  ~a" (getf r :value)) '(:fg :bright-white))
                   (when (getf r :choices)
                     (cons (format nil "  of ~{~a~^|~}" (getf r :choices))
                           '(:fg :bright-black)))))
           settings)))

(defun jobs-lines (head cols)
  (declare (ignore cols))
  (append
   (list (list (cons " background jobs " '(:bold t))))
   (if (head-jobs head)
       (mapcar (lambda (j)
                 (list (cons (format nil "  ~a" (getf j :handle)) '(:bold t))
                       (cons (format nil "  ~a" (getf j :summary))
                             '(:fg :bright-white))))
               (head-jobs head))
       (list (list (cons "  none" '(:fg :bright-black)))))))

(defun subagent-lines (head cols)
  (declare (ignore cols))
  (append
   (list (list (cons " subagents " '(:bold t))
               (cons "  (enter peeks a row's scrollback without moving there)"
                     '(:fg :bright-black))))
   (if (head-subagents head)
       (mapcar (lambda (s)
                 (list (cons (format nil "  ~a" (getf s :session-id)) '(:bold t))
                       (cons (format nil "  ~a" (getf s :kind)) '(:fg :bright-black))))
               (head-subagents head))
       (list (list (cons "  none" '(:fg :bright-black)))))))

(defun peek-lines (head cols)
  (let ((events (head-peeked head)))
    (append
     (list (list (cons " peeked scrollback " '(:bold t))
                 (cons "  (esc closes)" '(:fg :bright-black))))
     (if events
         (let ((lines nil))
           (dolist (env events)
             (let ((name (event-name env)))
               (case name
                 ((:delta) (push (getf env :text) lines))
                 ((:transcript-content)
                  (awhen (getf env :item)
                    (push (or (getf it :text) (getf it :payload) "") lines)))
                 (t (push (format nil "[~a]" name) lines)))))
           (mapcar (lambda (l) (wrap-segments (list (cons l nil)) cols))
                   (nreverse lines)))
         (list (list (cons "  nothing" '(:fg :bright-black))))))))

;;; --------------------------------------------------------------- chrome ;;;

(defun top-border (head cols)
  (let* ((s (head-session head))
         (title (if (plusp (length (session-title s)))
                    (session-title s) (session-session-id s)))
         (model (getf (session-wiring s) :model))
         (left (format nil " leticl · ~a · ~a " title model))
         (right (format nil "seq ~a · ~d heads "
                        (session-seq s) (length (session-heads s))))
         (pad (max 0 (- cols (string-width left) (string-width right)))))
    (list (cons left '(:bold t :fg :cyan))
          (cons (make-string pad :initial-element #\─) '(:fg :bright-black))
          (cons right '(:fg :bright-black)))))

(defun status-line (head cols)
  (let* ((conn (if (head-connected head) "" " · DISCONNECTED — retrying"))
         (scroll (if (plusp (head-scroll head))
                     (format nil " · ↑~a" (head-scroll head)) ""))
         (queued (if (head-queued head)
                     (format nil " · ~d queued" (length (head-queued head))) ""))
         (text (format nil " ~a~a~a~a"
                       (or (head-status-note head) "") conn scroll queued))
         (style (if (head-connected head) '(:fg :bright-black) '(:fg :red :bold t))))
    (list (cons (if (> (string-width text) cols)
                    (subseq text 0 cols) text)
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:fg :bright-black)))))

(defun composer-line (head cols)
  (let* ((c (head-composer head))
         (buf (composer-buffer c))
         (prefix "› ")
         (visible (if (> (+ (string-width prefix) (string-width buf)) cols)
                      ;; keep the cursor end visible: show the tail
                      (subseq buf (max 0 (- (length buf)
                                            (- cols (length prefix)))))
                      buf)))
    (list (cons prefix '(:fg :bright-cyan :bold t))
          (cons visible nil))))

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
