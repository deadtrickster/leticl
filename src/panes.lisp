;;;; panes.lisp — the full-body screens: the session picker, help, status,
;;;; config, the background jobs, the subagent tree, the repo's TODO.md, the
;;;; model's plan, and peek.
;;;;
;;;; Each returns lines of segments like any other renderer, and `head-mode`
;;;; selects one in `%render` (render.lisp). They replace the transcript rather
;;;; than riding above it.

(in-package #:leticl)

;;; ------------------------------------------------------------- screens ;;;
(defun picker-lines (session sel cols)
  "The session picker: every row the daemon sent, current one marked, and the
cursor's LINE as a second value (see `subagent-lines`)."
  (declare (ignore cols))
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
    (values (nreverse lines) (1+ sel))))

(defun help-lines (cols)
  (declare (ignore cols))
  (append
   (list (list (cons " leticl keys " '(:bold t))))
   (mapcar (lambda (pair)
             (list (cons (format nil "  ~13a" (car pair)) '(:bold t))
                   (cons (format nil "  ~a" (cdr pair)) '(:fg :bright-black))))
           '(("enter" . "send the line; queued if a turn runs")
             ("ctrl+c" . "interrupt the running turn")
             ("ctrl+d" . "quit")
             ("pgup/pgdn" . "scroll the transcript")
             ("up/down" . "history, or move in lists")
             ("alt+enter" . "a newline inside the prompt")
             ("esc esc" . "interrupt the running turn, twice within five seconds")
             ("tab" . "complete a slash command")
             ("ctrl-r" . "fold or unfold the model's thinking")
             ("ctrl-t" . "fold or unfold tool output")
             ("ctrl-x" . "show the raw <function=…> markup of tool calls")
             ("ctrl-s" . "the session list")
             ("ctrl-p" . "the todos pane")
             ("ctrl-g" . "the subagent tree")
             ("ctrl-q" . "the background jobs")
             ("ctrl-o" . "move the running command to the background")
             ("ctrl-u" . "kill the line, or take back a queued prompt")
             ("ctrl-y" . "yank the last kill")
             ("ctrl-z" . "undo, a word at a time")
             ("ctrl-l" . "repaint the screen")))
   (list nil (list (cons " commands " '(:bold t))))
   (mapcar (lambda (pair)
             (list (cons (format nil "  /~a" (car pair)) '(:fg :cyan))
                   (cons (format nil "  ~a" (cdr pair)) '(:fg :bright-black))))
           *slash-commands*)))

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
  "One row per setting. `SettingRow` is `key`/`value`/`source`/`editable`
(protocol.rs:214) — NOT `name`, which this read for a while and therefore
printed `NIL` for every row's label. `source` says where the value came from
(a flag, a project store, `permission.json`); `editable` names the slash verb
that changes it, or is empty for one that needs a restart."
  (declare (ignore cols))
  (append
   (list (list (cons " settings " '(:bold t))
               (cons "  (the daemon owns this list; it ships with the setting)"
                     '(:fg :bright-black))))
   (mapcar (lambda (r)
             (list (cons (format nil "  ~a" (getf r :key)) '(:bold t))
                   (cons (format nil "  ~a" (getf r :value)) '(:fg :bright-white))
                   (awhen (getf r :source)
                     (cons (format nil "  ~a" it) '(:fg :bright-black)))
                   (awhen (and (getf r :editable) (plusp (length it)))
                     (cons (format nil "  ~a" it) '(:fg :cyan)))
                   (awhen (getf r :choices)
                     (cons (format nil "  of ~{~a~^|~}" it)
                           '(:fg :bright-black)))))
           settings)))

(defun jobs-lines (head cols)
  "The background jobs, with the cursor on row `head-picker-sel`. Second value is
the cursor's LINE — see `subagent-lines`."
  (declare (ignore cols))
  (let* ((header (list (list (cons " background jobs " '(:bold t)))
                       (list (list (cons "" '(:fg :bright-black))))))
         (rows (head-jobs head))
         (sel (head-picker-sel head)))
    (values
     (append header
             (if rows
                 (loop for j in rows
                       for i from 0
                       collect (list (cons (format nil "  ~a" (getf j :handle))
                                           (if (= i sel)
                                               '(:reverse t :bold t)
                                               '(:bold t)))
                                     (cons (format nil "  ~a" (getf j :summary))
                                           '(:fg :bright-white))))
                 (list (list (cons "  none" '(:fg :bright-black))))))
     (+ (length header) sel))))

(defun subagent-lines (head cols)
  "The subagent tree, with the cursor on row `head-picker-sel`.

Returns the lines and, as a second value, the LINE the cursor is on. A pane's
cursor indexes ROWS while the scroll offset counts LINES, and the two differ by
every header above the list — passing one where the other was meant scrolls to
the wrong place, which is how the reference found this in its own test."
  (declare (ignore cols))
  (let* ((header (list (list (cons " subagents " '(:bold t))
                             (cons "  (enter peeks a row's scrollback without moving there)"
                                   '(:fg :bright-black)))
                       (list (list (cons "" '(:fg :bright-black))))))
         (rows (head-subagents head))
         (sel (head-picker-sel head)))
    (values
     (append header
             (if rows
                 (loop for s in rows
                       for i from 0
                       collect (list (cons (format nil "  ~a" (getf s :session-id))
                                           (if (= i sel)
                                               '(:reverse t :bold t)
                                               '(:bold t)))
                                     (cons (format nil "  ~a" (getf s :kind))
                                           '(:fg :bright-black))))
                 (list (list (cons "  none" '(:fg :bright-black))))))
     (+ (length header) sel))))

;;;; The repo's TODO.md, read the way org reads it.
;;;;
;;;; Three commits in the reference are one feature here, and each is measured
;;;; from the operator's own words in them:
;;;;
;;;;   *"our todo pane doesnt render them - only section titles and sub todos
;;;;    count. make sure it follows org mode - subtodos shown, when all subtodos
;;;;    checked section becomes also checked"*
;;;;   *"colors?"*
;;;;   *"if a todo has some associated text? should i be able to expand it
;;;;    somehow?"*

(defparameter +todo-marks+
  '(("x" . :done) ("X" . :done) (" " . :open) ("~" . :doing) ("-" . :open))
  "The marks this file's own legend defines and `todo_write` uses, so both halves
of the pane read alike. `-` counts as open: it is a bullet nobody has picked up.")

(defun %todo-mark-of (line)
  "LINE as a checkbox, or NIL.

A checkbox is `- [x] …`, `- [ ] …` or a bare `[x] …` — markdown's list bullet is
optional, because a TODO.md written by hand does not always carry one."
  (let ((trimmed (string-left-trim " " line)))
    (when (>= (length trimmed) 3)
      (let ((body (cond ((and (>= (length trimmed) 6)
                              (or (uiop:string-prefix-p "- [" trimmed)
                                  (uiop:string-prefix-p "* [" trimmed)))
                         ;; strip the bullet AND its space: `- [x] one` → `[x] one`
                         ;; at offset 2. At 3 the body starts `] one` and nothing
                         ;; matches, which is how the first version read every
                         ;; checkbox as prose.
                         (subseq trimmed 2))
                        ((char= (char trimmed 0) #\[) trimmed)
                        (t nil))))
        (when (and body (>= (length body) 3) (char= (char body 0) #\[)
                   (char= (char body 2) #\]))
          (let ((mark (cdr (assoc (string (char body 1)) +todo-marks+ :test #'string=))))
            (when mark
              (values mark (string-left-trim " " (subseq body 4))))))))))

(defun strip-todo-markup (text)
  "`**T1** git init` -> `T1 git init`. Backticks go too; nothing else is
interpreted, because this is a reader and not a renderer."
  (let ((out text))
    (dolist (marker '("**" "`"))
      (loop for i = (search marker out)
            while i
            do (setf out (concatenate 'string (subseq out 0 i) (subseq out (+ i (length marker)))))))
    out))

(defun %todo-rollup (marks)
  "Org's rule for a parent, and the whole of it: every child done makes the parent
done; any child started makes it started; otherwise open."
  (cond ((every (lambda (m) (eq m :done)) marks) :done)
        ((some (lambda (m) (not (eq m :open))) marks) :doing)
        (t :open)))

(defun read-todo-md (body)
  "BODY (a TODO.md) to a list of `todo-row` plists.

Each row: `:indent` (columns before the mark), `:mark` (`:open`/`:doing`/`:done`
or NIL for a heading with no checkboxes under it), `:text`, `:body` (the detail
lines under an item) and `:item` (T for a checkbox row, NIL for a heading).

The indent is carried rather than baked into the text, because it belongs BEFORE
the mark and the mark is the part that gets painted — pre-indented it renders as
`[x]     Phase 0` with the colour in front of the whitespace instead of on the
box. And `:item` exists because a heading carries a mark TOO (its roll-up), so
the mark cannot be what tells a row from a heading."
  (let ((out nil)
        (section nil)
        (items nil)                     ; newest first: mark, head, body
        (collecting nil))
    (labels ((flush ()
               (when section
                 (if (null items)
                     ;; no box and no cookie: an empty section is one nobody has
                     ;; filled in, and org does not mark it done either
                     (push (list :indent 4 :mark nil :text section :body nil
                                 :item nil)
                           out)
                     (let ((marks (mapcar #'first items)))
                       (push (list :indent 4
                                   :mark (%todo-rollup marks)
                                   :text (format nil "~a  [~a/~a]"
                                                 section
                                                 (count :done marks)
                                                 (length items))
                                   :body nil :item nil)
                             out)
                       ;; oldest first under the heading
                       (dolist (it (reverse items))
                         (push (list :indent 8 :mark (first it) :text (second it)
                                     :body (third it) :item t)
                               out))))))
             (end-item () (setf collecting nil)))
      (dolist (line (uiop:split-string body :separator '(#\newline)))
        (cond
          ;; `##` and deeper. `###` is a subsection and owns its own items, which
          ;; is what org's outline says too.
          ((or (uiop:string-prefix-p "## " line)
               (uiop:string-prefix-p "### " line))
           (flush)
           (let ((n (if (uiop:string-prefix-p "### " line) 4 3)))
             (setf section (string-trim " " (subseq line n))
                   items nil
                   collecting nil)))
          (t
           (multiple-value-bind (mark text) (%todo-mark-of line)
             (cond
               (mark
                (push (list mark (strip-todo-markup text) nil) items)
                (setf collecting t))
               ((zerop (length (string-trim " " line)))
                ;; a blank line CLOSES an item: two items a blank apart would
                ;; otherwise merge, and the prose between a heading and its list
                ;; would land on whatever came before
                (end-item))
               ((and collecting
                     (or (char= (char line 0) #\space)
                         (char= (char line 0) #\tab))
                     items)
                ;; an indented line under an item is that item's DETAIL — where a
                ;; TODO.md puts the commit it pins and the `Deps:` line.
                ;;
                ;; APPENDED, not pushed: the detail reads top-to-bottom as the
                ;; file does, and pushing put the `Deps:` line above the commit it
                ;; was pinned to. `(third (first items))` is the CURRENT item;
                ;; `items` itself is newest-first.
                (let ((det (strip-todo-markup (string-trim " " line))))
                  (setf (third (first items))
                        (append (third (first items)) (list det)))))
               (t (end-item)))))))
      (flush)
      (nreverse out))))

(defun repo-todo-rows (workspace)
  "The repo's TODO.md as rows, or one row saying why there are none."
  (if (not (plusp (length (or workspace ""))))
      (list (list :indent 4 :mark nil :text "(no workspace in the wiring)"
                  :body nil :item nil))
      (let ((path (format nil "~a/TODO.md" workspace)))
        (if (probe-file path)
            (read-todo-md (uiop:read-file-string path))
            (list (list :indent 4 :mark nil
                        :text (format nil "(no TODO.md in ~a)" workspace)
                        :body nil :item nil))))))

;;; ---------------------------------------------------------- the watcher ;;;
;;;
;;; The pane used to read the file at open, so a file edited WHILE the pane was up
;;; showed the old read — and this file is edited exactly while somebody is
;;; looking at it. The operator: *"since the file can be updated, dont cache it i
;;; guess or do a watcher with a nice syscall"*.
;;;
;;; One `stat` per draw rather than an inotify thread: a watcher means a
;;; descriptor, a thread and an event routed into a head whose design is one loop
;;; over one channel, and the pane is drawn only while it is open. `(mtime, len)`
;;; rather than mtime alone, because a second-granularity mtime misses two writes
;;; inside one second and a length change catches most of those.

(defvar *repo-todo-cache* nil "The rows last read, or NIL.")
(defvar *repo-todo-stamp* nil "The (mtime len) they were read at.")

(defun %todo-stamp (path)
  (ignore-errors
    (let ((w (sb-posix:stat path)))
      (list (sb-posix:stat-mtime w) (sb-posix:stat-size w)))))

(defvar *repo-todo-path* nil
  "The workspace the cache was read for, so a Switch does not show the old
project's queue.")

(defun repo-todo-rows-cached (workspace)
  "The repo's rows, re-read when the file changes (or the workspace does)."
  (let* ((path (and (plusp (length (or workspace "")))
                    (format nil "~a/TODO.md" workspace)))
         (stamp (and path (probe-file path) (%todo-stamp path))))
    (unless (and (equal path *repo-todo-path*) (equal stamp *repo-todo-stamp*))
      (setf *repo-todo-path* path
            *repo-todo-stamp* stamp
            *repo-todo-cache* (repo-todo-rows workspace)))
    *repo-todo-cache*))

(defun repo-todo-lines (workspace)
  "The repo's TODO.md as plain lines, for callers that want text. The pane uses
`repo-todo-rows-cached`; this stays for the rest."
  (mapcar (lambda (row) (format nil "~a~@[~a ~]~a"
                                (make-string (getf row :indent) :initial-element #\space)
                                (case (getf row :mark) (:done "[x]") (:doing "[~]") (:open "[ ]"))
                                (getf row :text)))
          (repo-todo-rows workspace)))

(defvar *todos-open* nil
  "Which repo todo rows are unfolded, by their TEXT.

Keyed by text rather than by index, because the file is re-read while the pane is
open and an index would then point at a different line. A defvar, not a head slot:
a struct layout change is a restart.")

(defun %todo-mark-style (mark)
  "A mark's colour: done green, doing yellow, OPEN LEFT ALONE.

An open item is the default state and the majority of any list, and colouring the
majority spends the signal the other two carry."
  (case mark
    (:done '(:fg :green))
    (:doing '(:fg :yellow))
    (t nil)))

(defun %todo-mark-text (mark)
  (case mark (:done "[x]") (:doing "[~]") (:open "[ ]") (t "   ")))

(defun %todo-row-lines (row)
  "One repo todo row to segment lines — the mark PAINTED, the indent separate.

The indent is its own segment so the colour lands on the box and not in front of
the whitespace; `TodoMark::painted` in the reference exists for the same reason,
and so does the assertion in the test that checks the ESCAPES rather than the
glyphs."
  (let* ((mark (getf row :mark))
         (indent (make-string (getf row :indent) :initial-element #\space))
         (style (%todo-mark-style mark))
         (text (getf row :text))
         (open (member text *todos-open* :test #'string=))
         (detail (getf row :body)))
    ;; returns a LIST OF LINES. One row is one line (mark painted, indent its
    ;; own segment), plus one line per detail row when it is unfolded. The caller
    ;; must FLATTEN these — see `todos-lines`, which appends them — because a
    ;; nesting mistake here is invisible: it renders as a list printed into a
    ;; cell rather than as an error.
    (append
     (list (list (cons indent nil)
                 (cons (%todo-mark-text mark) style)
                 (cons (format nil " ~a" text) nil)
                 ;; a folded item that HAS more says so; one that does not, does
                 ;; not — so the mark means "there is more" rather than "this is
                 ;; an item"
                 (cons (if (and detail (not open)) "  ···" "")
                       '(:fg :bright-black))))
     (when (and detail open (getf row :item))
       (mapcar (lambda (l) (list (cons "            " nil)
                                 (cons l '(:fg :bright-black))))
               detail)))))

(defun todos-lines (head cols)
  "The todos pane: the session's plan (what the model writes with `todo_write`),
and the repo's TODO.md — items drawn, rolled up, painted and unfoldable.

Second value is the cursor's LINE, for the scroll offset (see `subagent-lines`)."
  (declare (ignore cols))
  (let* ((s (head-session head))
         (todos (session-todos s))
         (sel (head-picker-sel head))
         (header (list (list (cons " todos " '(:bold t))
                             (cons "  ↑↓ moves · enter unfolds · esc closes"
                                   '(:fg :bright-black)))
                       (list nil)
                       (list (cons "  this session — the model's plan, live:"
                                   '(:fg :bright-black)))))
         (todo-rows
          (if todos
              (loop for t2 in todos
                    for i from 0
                    for st = (cond ((string= (getf t2 :status) "in_progress") :doing)
                                   ((string= (getf t2 :status) "completed") :done)
                                   (t :open))
                    ;; a LINE is a list of SEGMENTS — `(list (cons …) (cons …))`,
                    ;; NOT `(list (list (cons …)))`, which is a line containing a
                    ;; line and renders as a list inside the cell
                    collect (list (cons "  " nil)
                                  (cons (%todo-mark-text st) (%todo-mark-style st))
                                  (cons (format nil " ~a" (getf t2 :content))
                                        (if (= i sel) (list :reverse t) nil))))
              (list (list (cons "    none written yet. The model writes them with todo_write."
                                '(:fg :bright-black))))))
         (repo-header (list nil
                            (list (cons "  the repo's TODO.md — the operator's queue, read-only here:"
                                        '(:fg :bright-black)))))
         (rows (repo-todo-rows-cached (getf (session-wiring s) :workspace)))
         ;; APPEND, not mapcar: each row renders to several lines, and mapcar
         ;; leaves a list of lists — which prints into the cell instead of
         ;; erroring, so nothing catches it
         (repo-lines (mappend #'%todo-row-lines rows)))
    (values
     (append header todo-rows repo-header
             (if repo-lines repo-lines
                 (list (list (cons "    (nothing in it)" '(:fg :bright-black)))))
             (list (list (cons "" '(:fg :bright-black)))
                   (list (cons "  the file is in the workspace; this pane never writes it."
                               '(:fg :bright-black)))))
     ;; the cursor is on the session's plan, which starts after the header
     (+ (length header) sel))))

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



;;; ------------------------------------------------------------ pickers ;;;
;;;
;;; The MODE and MODELS pickers, the session picker's twins for one question each.
;;; Both read their choices from the daemon's own settings rows — `SettingRow`
;;; carries `choices` from protocol 18 — so the head keeps no list to drift.
;;;
;;; The reference has one flag per picker for the same reason it has one cursor
;;; for all of them: the choices, the cursor, the scroll offset and the drawing
;;; are shared, because the one thing this file has already been burned by is a
;;; second copy of a list that then drifts.

(defun setting-choices (head key)
  "The choices the daemon reports for setting KEY, or NIL.

From the settings rows the head asks for at attach, which is why it asks: a
picker whose list is empty because nobody ever asked the daemon is a picker that
looks broken (P44 in TODO.md is the same bug one layer down)."
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :choices)))

(defun setting-value (head key)
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :value)))

(defun %choice-lines (head label key cols)
  "A picker body: every choice, the CURRENT one marked, the cursor reversed.

Returns the lines and, as a second value, the cursor's LINE — see
`subagent-lines` for why the two are different numbers."
  (declare (ignore cols))
  (let* ((choices (setting-choices head key))
         (current (setting-value head key))
         (sel (head-picker-sel head))
         (header (list (list (cons (format nil " ~a " label) '(:bold t))
                             (cons "  ↑↓ then enter · esc closes" '(:fg :bright-black)))
                       nil)))
    (values
     (append header
             (if choices
                 (loop for c in choices
                       for i from 0
                       for here = (and current (string= c current))
                       collect (list (cons (format nil "  ~a ~a" (if here "●" " ") c)
                                           (cond ((= i sel) '(:reverse t :bold t))
                                                 (here '(:fg :bright-cyan :bold t))
                                                 (t nil)))))
                 (list (list (cons (format nil "  (the daemon reports no choices for ~a — has it been asked?)" key)
                                   '(:fg :bright-black))))))
     (+ (length header) sel))))

(defun mode-picker-lines (head cols)
  "The modes this session's project can be moved to."
  (%choice-lines head "mode" "mode" cols))

(defun models-picker-lines (head cols)
  "The models this daemon can reach."
  (%choice-lines head "model" "model" cols))
