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

(defun repo-todo-lines (workspace)
  "The repo's TODO.md, summarised by section (app.rs:6099). Read-only: the
 pane never writes the file."
  (if (not (plusp (length (or workspace ""))))
      (list "    (no workspace in the wiring)")
      (let ((path (format nil "~a/TODO.md" workspace)))
        (if (probe-file path)
            (let ((body (uiop:read-file-string path))
                  (out nil)
                  (section nil)
                  (open 0)
                  (done 0))
              (flet ((flush ()
                       (when section
                         (push (format nil "    ~a — ~d open, ~d done"
                                       section open done)
                               out))))
                (dolist (line (uiop:split-string body :separator '(#\newline)))
                  (if (uiop:string-prefix-p "## " line)
                      (progn
                        (flush)
                        (setf section (string-trim " " (subseq line 3))
                              open 0 done 0))
                      (let ((trimmed (string-trim " " line)))
                        (cond ((uiop:string-prefix-p "- [ ]" trimmed) (incf open))
                              ((or (uiop:string-prefix-p "- [x]" trimmed)
                                   (uiop:string-prefix-p "- [X]" trimmed))
                               (incf done))))))
                (flush)
                (if out
                    (nreverse out)
                    (list "    no sections found."))))
            (list (format nil "    (no TODO.md in ~a)" workspace))))))

(defun todos-lines (head cols)
  "The todos pane: the session's plan (what the model writes with todo_write),
 and the repo's TODO.md read-only (app.rs:4776)."
  (declare (ignore cols))
  (let* ((s (head-session head))
         (todos (session-todos s))
         (todo-lines (if todos
                         (mapcar (lambda (todo)
                                   (let ((mark (cond ((string= (getf todo :status) "in_progress") "[~]")
                                                     ((string= (getf todo :status) "completed") "[x]")
                                                     (t "[ ]"))))
                                     (list (cons (format nil "    ~a ~a" mark
                                                        (getf todo :content)) nil))))
                                 todos)
                         (list (list (cons "    none written yet. The model writes them with todo_write."
                                           '(:fg :bright-black))))))
         (repo-lines (mapcar (lambda (l) (list (cons l '(:fg :bright-black))))
                             (repo-todo-lines (getf (session-wiring s) :workspace)))))
    (append
     (list (list (cons " todos " '(:bold t)))
           nil
           (list (cons "  this session — the model's plan, live:"
                       '(:fg :bright-black))))
     todo-lines
     (list nil
           (list (cons "  the repo's TODO.md — the operator's queue, read-only here:"
                       '(:fg :bright-black))))
     repo-lines
     (list nil
           (list (cons "  the file itself is in the workspace; this pane never writes it."
                       '(:fg :bright-black)))))))

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


