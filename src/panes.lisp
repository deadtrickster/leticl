;;;; panes.lisp — the full-body screens: the session picker, help, status,
;;;; config, the background jobs, the subagent tree, the repo's TODO.md, the
;;;; model's plan, and peek.
;;;;
;;;; Each returns lines of segments like any other renderer, and `head-mode`
;;;; selects one in `%render` (render.lisp). They replace the transcript rather
;;;; than riding above it.

(in-package #:leticl)

;;; ------------------------------------------------------------- helpers ;;;
;;;
;;; Every pane below was measured against the reference's screen at 210x63
;;; (`scripts/compare-heads`, the `pane-*-lb.ans` captures), and these are the
;;; things every one of them needed: a plain-text WRAP, the `~` a path is written
;;; with, the short id, and the right-aligned row. The body's WIDTH, `pane-width`,
;;; is in render.lisp beside the gutter constants it reads.

(defun wrap-text (text cols)
  "TEXT to plain lines of at most COLS columns — `wrap` in the reference's
width.rs, over `wrap-segments` so the two wrappers here cannot break differently.

Each line is one string with its trailing space trimmed, because a painter that
erases to end of row would otherwise paint one column past the text."
  (mapcar (lambda (line) (apply #'concatenate 'string (mapcar #'car line)))
          (wrap-segments (list (cons text nil)) cols)))

(defun tilde-path (path)
  "PATH with `$HOME` written as `~` — the reference's `tilde`. NIL stays NIL."
  (let ((home (uiop:getenv "HOME")))
    (cond ((null path) nil)
          ((and home (plusp (length home))
                (>= (length path) (length home))
                (string= (subseq path 0 (length home)) home))
           (concatenate 'string "~" (subseq path (length home))))
          (t path))))

(defun short-id (id)
  "The last eight characters behind an ellipsis, or the whole of a short id —
`short_id` in the reference's registry.rs, which is what an unnamed session is
listed as."
  (let ((n (length id)))
    (if (<= n 10) id (format nil "…~a" (subseq id (- n 8))))))

(defun bytes-human (n)
  "`512 B`, `1.5 KB`, `2.0 MB` — the reference's `bytes_human` (render.rs:899)."
  (let ((k 1024))
    (cond ((< n k) (format nil "~d B" n))
          ((< n (* k k)) (format nil "~,1f KB" (/ n (float k 1d0))))
          ((< n (* k k k)) (format nil "~,1f MB" (/ n (float (* k k) 1d0))))
          (t (format nil "~,1f GB" (/ n (float (* k k k) 1d0)))))))

(defun split-row (left right cols)
  "LEFT at the left edge and RIGHT at the right, as one segment line — the
reference's `split_row`. When the two do not fit with two columns between them the
right half is dropped and the left is kept whole, which is the reference's choice
too: the facts are the part a narrow screen can do without."
  (let ((lw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) left)))
        (rw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) right))))
    (if (<= (+ lw rw 2) cols)
        (append left
                (list (cons (make-string (- cols lw rw) :initial-element #\space) nil))
                right)
        left)))

;;; ------------------------------------------------------------- screens ;;;

(defun picker-sessions (session)
  "The sessions the picker lists: the daemon's, MINUS the subagents.

The reference filters `parent_session_id.is_none()` on both `Hello` and
`Sessions` (app.rs:1391), because a subagent is a child of a session, shown in the
subagent tree and reached by `/switch id`. Ours listed them — measured on the
same daemon, letibot's picker had 28 rows and ours 58 — so the header's count
(`%session-position`) and the picker disagreed about how many sessions there
were. One filter, here, that both read."
  (remove-if (lambda (b) (getf b :parent-session-id)) (session-sessions session)))

(defun picker-lines (session sel cols)
  "The session picker, row for row the reference's `picker_lines`:

    sessions in this daemon
    <blank>
    ▸  1  title                              2647 rows · 2 heads · qwen-3.8-27b
          s-1789639478142928813  ~/Projects/leticl
       2  other title                     on disk · 1799 rows · glm-5.3-flash
          s-1789462738453908838  ~/Projects/letibot
    <blank>
    ↑↓ moves · enter switches · …
    switching does not stop anything: …

The row under the cursor is reversed and the mark `▸` is what Enter takes; the
session this head is IN keeps its name bold, so \"where am I\" and \"what Enter
takes\" stay two readable facts. The facts on the right are the daemon's:
`generating` while a turn runs, `on disk` for a stored session, the store's row
count (the view's `items` is bounded and would make a long session look short),
the heads attached and the model. Under EVERY row, the full id and the workspace —
the id because it is the thing you would type, the workspace because for a stored
session it is the only thing on the row that says what the conversation was about.

Second value is the cursor's LINE: two lines per session, after a two-line header."
  (let* ((w (pane-width cols))
         (rows (picker-sessions session))
         (n (length rows))
         (sel (if (plusp n) (min sel (1- n)) 0))
         (header (list (list (cons "sessions in this daemon" '(:bold t)))
                       nil))
         (lines nil))
    (when (null rows)
      (push (list (cons "  none listed yet — the daemon has not answered, or this head is replaying a recorded log and has no daemon to ask."
                        '(:dim t)))
            lines))
    (loop for s in rows
          for i from 0
          do (let* ((here (equal (getf s :session-id) (session-session-id session)))
                    (picked (= i sel))
                    (status (getf s :status))
                    (title (or (getf s :title) ""))
                    (name (if (plusp (length title)) title (short-id (getf s :session-id))))
                    (running (getf status :running))
                    (stored (or (getf s :stored-items) 0))
                    (rows-n (if (plusp stored) stored (or (getf status :items) 0)))
                    (heads (or (getf status :heads) 0))
                    (model (or (getf (getf s :wiring) :model) ""))
                    (workspace (or (getf (getf s :wiring) :workspace) ""))
                    (facts (remove nil
                                   (list (and running "generating")
                                         (and (not (getf s :live)) "on disk")
                                         (and (plusp rows-n) (format nil "~d rows" rows-n))
                                         (and (plusp heads)
                                              (format nil "~d head~:p" heads))
                                         (and (plusp (length model)) model))))
                    ;; the reference reverses the WHOLE left half, mark and name
                    ;; alike, and the name's bold rides inside it
                    (left (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i))
                                      (and picked '(:reverse t)))
                                (cons name (cond ((and picked here) '(:reverse t :bold t))
                                                 (picked '(:reverse t))
                                                 (here '(:bold t))
                                                 (t nil)))))
                    (right (list (cons (format nil "~{~a~^ · ~}" facts)
                                       (if running '(:fg :yellow) '(:dim t))))))
               (push (split-row left right w) lines)
               (push (list (cons (if (plusp (length workspace))
                                     (format nil "      ~a  ~a" (getf s :session-id)
                                             (tilde-path workspace))
                                     (format nil "      ~a" (getf s :session-id)))
                                 '(:dim t)))
                     lines)))
    (push nil lines)
    (push (list (cons "  ↑↓ moves · enter switches · or type a number or part of a name and press enter · /new [title] makes one · /rename NAME names this one · esc closes"
                      '(:dim t)))
          lines)
    (push (list (cons "  switching does not stop anything: a turn keeps running in the session you left, and it is still there when you come back."
                      '(:dim t)))
          lines)
    (values (append header (nreverse lines))
            (+ (length header) (* 2 sel)))))

(defparameter *help-rows*
  '(("enter" . "send what you typed; while a turn runs it is queued as a follow-up")
    ("alt+enter" . "a newline inside the prompt, without sending it")
    ("esc esc" . "interrupt the running turn — twice, within five seconds")
    ("ctrl-c" . "clear what you typed; twice on an empty prompt, within a second, quits")
    ("↑ ↓" . "move inside the prompt, then walk the prompts you have sent")
    ("pgup pgdn" . "scroll the transcript; esc returns to following the stream")
    ("wheel" . "scroll the transcript; shift+drag selects text")
    ("ctrl-a ctrl-e" . "start and end of the line; ctrl-w and ctrl-u kill, ctrl-y yanks")
    ("ctrl-z" . "undo — a word at a time, and a kill is always its own step")
    ("paste" . "five lines or more collapses to a marker and is sent in full")
    ("ctrl-s" . "the session list: type a number or part of a name to switch")
    ("tab" . "complete the /command being typed; more tabs walk the matches")
    ("click" . "in the session list, picks the row under the pointer; enter still switches")
    ("ctrl-p" . "the todos pane: the model's plan, and the repo's TODO.md read-only — ↑↓ moves, enter or tab unfolds an item, pgup/pgdn scrolls")
    ("/new [title]" . "start a session in this daemon and go there")
    ("/switch WHAT" . "go to a session by number, id or part of its name")
    ("ctrl-r" . "fold or unfold the model's thinking")
    ("ctrl-t" . "fold or unfold tool output")
    ("ctrl-x" . "show the raw <function=…> text of tool calls, as the model wrote it")
    ("ctrl-l" . "repaint the screen")
    ("/status" . "this head's counters — dropped, scrubbed, resync — and what each means")
    ("/verbosity" . "terse → normal → loud; /status counts what has been filtered")
    ("/interrupt" . "interrupt, when a key is awkward")
    ("/config" . "every setting and where it came from; the first row toggles the diff view between split and unified")
    ("/compact" . "summarize this session down to one record; the old transcript is forked, not lost")
    ("/mode" . "move this project to a point: read-only, always-ask, writes-allowed, automode, automode-edits, allow-all (next session)")
    ("/supervise" . "the guard model answers every gated call before you do, from the next call — on, off, status")
    ("/gate" . "what the gate decided, and rule on it afterwards: recent, todo, corpus, ok|grant|revoke ID")
    ("/flowy" . "the seat on the fabric: /flowy status · /flowy login [SEAT] [--token T] · /flowy logout")
    ("/models" . "which model answers: /models lists them with their auth; /models deepseek/deepseek-chat switches and sticks; /models local")
    ("/job" . "read a background job's output: /job lists them, /job ID prints it, --offset N resumes")
    ("/tools" . "the tools seated here — and any the prompt has never been told about, which the model cannot call")
    ("/default-model" . "what a NEW session starts on: /default-model PROVIDER/MODEL, or `local` to clear it. Not this conversation — that is /models")
    ("/resync" . "throw this head's state away and take a fresh snapshot")
    ("/quit" . "detach. The turn keeps running: idle means quiet, not unwatched"))
  "The help's rows, in the reference's order (`help_lines`, app.rs:7510).

Keys and slash verbs interleaved as the reference has them — the order is by
what an operator reaches for, not by kind — and the text is the reference's
verbatim, because the help is the one screen an operator reads to learn the
OTHER head too.")

(defun help-lines (cols)
  "The help screen: `keys and commands`, a blank, the rows, a blank, the closer.

Measured against letibot's own screen: ours had a ` leticl keys ` title, a bold
key column with a dim description, and a second `commands` section listing every
slash verb; the reference has one title, a CYAN key column sixteen wide with a
plain description wrapped at `w - 19` and continued under itself, and no verb
list — 41 rows against our 50. The two heads should teach the same keys the same
way."
  (let ((w (pane-width cols)))
    (append
     (list (list (cons "keys and commands" '(:bold t))) nil)
     (mappend (lambda (pair)
                (loop for l in (wrap-text (cdr pair) (max 4 (- w 19)))
                      for i from 0
                      collect (if (zerop i)
                                  (list (cons (format nil "  ~16a" (car pair)) '(:fg :cyan))
                                        (cons l nil))
                                  (list (cons (make-string 19 :initial-element #\space) nil)
                                        (cons l nil)))))
              *help-rows*)
     (list nil (list (cons "  /help or esc closes this" '(:dim t)))))))

(defun status-screen-lines (head cols)
  "The status screen: `this head`, then one row per counter with WHY it exists
under it — the reference's `status_lines` (app.rs:6717), which is a screen that
explains its numbers rather than listing them.

Measured against letibot's own screen: ours was a ` status ` title and fourteen
`key value` pairs, several of them things the reference does not show at all
(title, model, items, a raw usage plist) and one printing `NIL` for a role nobody
sent. The reference shows the counters `/status` exists for — session, head, seq,
filtered, dropped, scrubbed, resync, verbosity, workspace — each as `  key` twelve
wide and dim, the value plain, and a dim explanation wrapped at `w - 16` under a
fourteen-column indent, then a blank. 26 rows against our 18."
  (let* ((w (pane-width cols))
         (s (head-session head))
         (out (list nil (list (cons "this head" '(:bold t))))))
    (flet ((row (k v why)
             (push (list (cons (format nil "  ~12a" k) '(:dim t))
                         (cons (format nil "~a" v) nil))
                   out)
             (dolist (l (wrap-text why (max 4 (- w 16))))
               (push (list (cons (make-string 14 :initial-element #\space) nil)
                           (cons l '(:dim t)))
                     out))
             (push nil out)))
      (when (plusp (length (session-session-id s)))
        (row "session" (session-session-id s)
             "In full, because this is the form a command takes. The header shows the last eight characters, which is the part two sessions differ in."))
      (when (plusp (length (session-head-id s)))
        (row "head" (format nil "~a · ~d attached" (session-head-id s)
                            (max 1 (length (session-heads s))))
             "Every head on this session sees the same stream from its own read mark. Closing one does not stop the turn."))
      (row "seq" (format nil "~d · ~d rendered" (session-seq s) *rendered-total*)
           "The log's monotonic, gap-free position, and how many of those events reached the screen. Both counted by this head, not by the daemon.")
      (row "filtered" (format nil "~d (~(~a~))" *filtered-total* *verbosity*)
           "Events this head chose not to show at the current verbosity. /verbosity walks terse → normal → loud.")
      (row "dropped" (or (session-dropped s) 0)
           "Events the daemon's bounded scrollback threw away before this head asked for them. Not a rendering choice: they are gone.")
      (row "scrubbed" *scrubbed-total*
           "Interactive-only frames withheld from a head that attached late — partial tool output and the like, which has no durable form.")
      (row "resync" *resyncs*
           "Times this head threw its state away and took a fresh snapshot, because the gap since its read mark was past the daemon's bound.")
      (row "verbosity" (string-downcase (symbol-name *verbosity*))
           "What reaches the transcript at the current filter. /verbosity walks terse → normal → loud. It used to sit on the composer's border, which was a row of attention paid for ever for a fact read once.")
      (let ((ws (getf (session-wiring s) :workspace)))
        (when (plusp (length (or ws "")))
          (row "workspace" (tilde-path ws)
               "Where the daemon is standing. Tools resolve relative paths here.")))
      (push (list (cons "  /status or esc closes this" '(:dim t))) out)
      (nreverse out))))

;;; --------------------------------------------------------- the config pane ;;;

(defparameter *head-setting-rows*
  '("diff" "thinking" "tools" "raw_calls")
  "The settings the HEAD owns, in the config pane's own order.

The daemon's rows are its own and read-only here — this head cannot change what a
daemon flag is. But the four above are the head's own choices, they live in
`head.toml` (S5), and a pane that lists them and cannot change them is a pane that
teaches the operator the wrong thing about what is editable.")

(defun %head-setting-value (head key)
  "One of the HEAD's own settings, READ FROM THE LIVE PLIST rather than from the
file — the file is where it is written, the plist is what is actually in effect,
and the two disagree for the moment between a change and a save.

The words are the reference's (`config_rows`): `split`/`unified`, `open`/`folded`,
and `shown`/`hidden` for the raw calls — measured, its pane says `raw tool calls
hidden` where ours said `raw_calls = off`."
  (cond ((string= key "diff") (or (getf (head-prefs head) :diff) "split"))
        ((string= key "thinking")
         (if (getf (head-prefs head) :show-reasoning) "open" "folded"))
        ((string= key "tools")
         (if (getf (head-prefs head) :show-tools) "open" "folded"))
        ((string= key "raw_calls")
         (if (getf (head-prefs head) :raw-calls) "shown" "hidden"))
        (t "?")))

(defun %flip-head-setting (head key)
  "Flip one of the HEAD's own settings in the live plist and persist it.

The plist is the source of truth while the head runs; `head-into-prefs` reads it
back at save time, so there is one direction of flow and no second copy to keep in
step."
  (cond
    ((string= key "diff")
     (setf (getf (head-prefs head) :diff)
           (if (string= (%head-setting-value head "diff") "split") "unified" "split")))
    ((string= key "thinking") (%flip-fold head :show-reasoning))
    ((string= key "tools") (%flip-fold head :show-tools))
    ((string= key "raw_calls")
     (setf (getf (head-prefs head) :raw-calls)
           (not (getf (head-prefs head) :raw-calls)))))
  (ignore-errors (save-head-prefs head))
  (setf (head-dirty head) t))

(defparameter *daemon-config-files*
  '("modes.tsv" "permission.json" "providers.toml" "sensitive.json")
  "The daemon's files the config pane lists under `files — edit with an editor`,
the reference's four (`config_rows`). A person edits these, not a pane.")

(defun daemon-config-dir ()
  "Where the daemon keeps its files: `$XDG_CONFIG_HOME/letibot/`, or
`~/.config/letibot/` — the daemon's own convention (crates/tui/src/prefs.rs:72
names the same directory for the reference head, which shares it).

Ours is `leticl/` beside it and holds only `head.toml`; the four files the pane
lists are the DAEMON's, so this is the directory to look in. A wrong guess shows
as `not present` with the path it looked at, never as an invented count. NIL when
neither variable is set."
  (let ((xdg (uiop:getenv "XDG_CONFIG_HOME"))
        (home (uiop:getenv "HOME")))
    (cond ((and xdg (plusp (length xdg)))
           (merge-pathnames "letibot/" (uiop:ensure-directory-pathname xdg)))
          ((and home (plusp (length home)))
           (merge-pathnames ".config/letibot/" (uiop:ensure-directory-pathname home)))
          (t nil))))

(defun %count-lines-in (path)
  "How many lines the file at PATH has, or 0 when it cannot be read."
  (or (ignore-errors
       (with-open-file (in path :external-format :utf-8)
         (loop for line = (read-line in nil nil) while line count t)))
      0))

(defun config-rows (head &optional (settings (head-settings head)))
  "The config pane's rows, the reference's `config_rows` (app.rs:5579): the HEAD's
four, then the daemon's SETTINGS, then the daemon's files.

Each row is a plist: `:section`, `:key`, `:value`, `:source` (where the value came
from, shown under the selected row; \"\" when nobody tracks it), `:choices` (the
daemon's, protocol 18, or NIL), and `:edit` — one of `(:head KEY)` for a row Enter
flips and writes to head.toml, `(:session KEY HOW)` for one an existing verb
changes now, or `(:no WHY)` for one that takes a restart or an editor.

`SettingRow` is `key`/`value`/`source`/`editable`/`choices` (protocol.rs:214) —
NOT `name`, which this read for a while and therefore printed `NIL` for every
row's label."
  (let* ((prefs-path (or (and *prefs* (prefs-path *prefs*)) (default-prefs-path)))
         (head-source (if prefs-path (namestring prefs-path) "not persisted"))
         (dir (daemon-config-dir)))
    (append
     (loop for key in *head-setting-rows*
           for label in '("diff view" "thinking" "tool output" "raw tool calls")
           collect (list :section "head — this window"
                         :key label
                         :value (%head-setting-value head key)
                         :source head-source
                         :choices nil
                         :edit (list :head key)))
     (mapcar (lambda (r)
               (let ((editable (or (getf r :editable) "")))
                 (list :section "session — the daemon"
                       :key (or (getf r :key) "")
                       :value (format nil "~a" (or (getf r :value) ""))
                       :source (or (getf r :source) "")
                       :choices (getf r :choices)
                       :edit (if (plusp (length editable))
                                 (list :session (getf r :key) editable)
                                 (list :no "takes a restart of the daemon")))))
             settings)
     (mapcar (lambda (f)
               (let ((path (and dir (merge-pathnames f dir))))
                 (multiple-value-bind (value source)
                     (cond ((null path) (values "no config directory" ""))
                           ((probe-file path)
                            (values (format nil "~d lines" (%count-lines-in path))
                                    (namestring path)))
                           (t (values "not present" (namestring path))))
                   (list :section "files — edit with an editor"
                         :key f :value value :source source :choices nil
                         :edit (list :no "a file the guard protects: a person edits it, not a pane")))))
             *daemon-config-files*))))

(defun config-lines (head settings cols)
  "The settings screen, row for row the reference's `config_lines` (app.rs:5748):

    config
    <blank>
      head — this window
    ▸ ✎ diff view        split
           from /home/dead/.config/leticl/head.toml
      ✎ thinking         folded
      ✎ tool output      open
      ✎ raw tool calls   hidden
    <blank>
      session — the daemon
      ✎ mode             allow-all (this box, consented)
        session          s-1789639478142928813
      …
    <blank>
      files — edit with an editor
        modes.tsv        5 lines
      …
    <blank>
        ✎ changes now and is kept (head → head.toml, mode → project store); …

A dim section name introduces each group, with a blank between groups. Every row
is `{▸| } {✎| } {key:<keyw}  {value}` where `keyw` is the longest key (capped at
28); `✎` marks a row Enter changes; the selected row is REVERSED whole and shows
its source dim under it. The cursor walks ALL the rows, not only the head's —
Enter on a daemon row cycles the mode, flips supervise, or says which verb changes
it; on a file row it says a person edits it.

This used to render `The variable IT is unbound`: an `awhen` over `(getf r
:source)` whose body was fine, then a SECOND `awhen` whose test was `(and (getf r
:editable) (plusp (length it)))` — `it` used inside the TEST, where it is not yet
bound. The pane never drew at all. SETTINGS is passed rather than read so a test
can hand the pane rows without a daemon."
  (let* ((w (pane-width cols))
         (rows (config-rows head settings))
         (n (length rows))
         (sel (if (plusp n) (min (head-picker-sel head) (1- n)) 0))
         (keyw (let ((longest (reduce #'max (mapcar (lambda (r) (string-width (getf r :key))) rows)
                                      :initial-value 0)))
                 (min 28 (if (zerop longest) 8 longest))))
         (section "")
         (out (list nil (list (cons "config" '(:bold t))))))
    (loop for r in rows
          for i from 0
          do (unless (string= (getf r :section) section)
               (when (plusp (length section)) (push nil out))
               (push (list (cons (format nil "  ~a" (getf r :section)) '(:dim t))) out)
               (setf section (getf r :section)))
             (let* ((edit (first (getf r :edit)))
                    (line (format nil "~a ~a ~va  ~a"
                                  (if (= i sel) "▸" " ")
                                  (if (member edit '(:head :session)) "✎" " ")
                                  keyw (getf r :key)
                                  (getf r :value))))
               (push (list (cons (truncate-to-width line (max 1 (- w 2)))
                                 (and (= i sel) '(:reverse t))))
                     out)
               (when (and (= i sel) (plusp (length (getf r :source))))
                 (push (list (cons (format nil "       from ~a" (getf r :source)) '(:dim t)))
                       out))))
    (when (null settings)
      (push nil out)
      (push (list (cons (if (plusp (length (session-session-id (head-session head))))
                            "  session — asked the daemon; nothing back yet"
                            "  session — not attached, so nothing to list")
                        '(:dim t)))
            out))
    (push nil out)
    (push (list (cons "    ✎ changes now and is kept (head → head.toml, mode → project store); the rest shows its source and takes a restart"
                      '(:dim t)))
          out)
    (values (nreverse out)
            ;; the cursor's LINE: the title and blank, a section name per group
            ;; entered, a blank between groups, and one line per row before it
            (let ((line 2) (sec ""))
              (loop for r in rows
                    for i from 0
                    do (unless (string= (getf r :section) sec)
                         (when (plusp (length sec)) (incf line))
                         (incf line)
                         (setf sec (getf r :section)))
                       (when (= i sel) (return line))
                       (incf line)
                    finally (return line))))))

(defun config-change (head)
  "Enter on the config pane's selected row — the reference's `config_change`.

A head row flips and is written to head.toml, and the note says the new value. A
session row goes through the verb that already exists, so the pane is a way to SEE
and not a second way to set: `mode` cycles the daemon's own `choices` (a daemon
older than protocol 18 sends none, and then the pane says so rather than cycling a
list it made up — the reference's `const NAMES` offered a mode that did not exist
and missed one that did); `supervise` flips on/off; anything else names the verb.
A row that cannot change says why."
  (let* ((rows (config-rows head))
         (row (and rows (nth (min (head-picker-sel head) (1- (length rows))) rows))))
    (when row
      (let ((edit (getf row :edit)))
        (ecase (first edit)
          (:head
           (%flip-head-setting head (second edit))
           (let ((after (nth (position row rows) (config-rows head))))
             (say head (format nil "~a → ~a" (getf after :key) (getf after :value)))))
          (:session
           (let ((key (second edit)) (how (third edit)))
             (cond
               ((string= key "mode")
                (if (null (getf row :choices))
                    (say head "this daemon does not send the mode list; use `/mode NAME`")
                    (let* ((choices (getf row :choices))
                           (cur (first (uiop:split-string (getf row :value) :separator " ")))
                           (at (or (position cur choices :test #'string=) 0))
                           (next (nth (mod (1+ at) (length choices)) choices)))
                      (say head (format nil "mode → ~a (asking the daemon)" next))
                      (%send head (list :frame "mode"
                                        :client-request-id (next-request-id)
                                        :expected-seq (session-expected-seq (head-session head))
                                        :name next)))))
               ((string= key "supervise")
                (let ((line (format nil "supervise ~a"
                                    (if (uiop:string-prefix-p "on" (getf row :value)) "off" "on"))))
                  (say head (format nil "~a (asking the daemon)" line))
                  (%send-slash head line)))
               (t (say head (format nil "change it with ~a" how))))))
          (:no (say head (format nil "~a: ~a" (getf row :key) (second edit)))))))
    (setf (head-dirty head) t)))

;;; ------------------------------------------------ the jobs and subagents ;;;

(defun jobs-lines (head cols)
  "The background jobs, the reference's `jobs_lines` (app.rs:6039):

    background jobs
    <blank>
        none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one.
    <blank>
        a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone.

or, with jobs, two lines each in place of the `none` row: `▸ [~] j12 command`
(the mark yellow while running, green for `exited 0`, red otherwise; the picked
row reversed) over a dim `         how · running · 1.2 KB out so far` or
`         how · exited 0 · 1.2 KB out · ran 3.4s`. Every field is the daemon's
`JobEntry` — `id`, `command`, `how`, `state`, `running`, `produced`, `elapsed_ms`.

This pane NEVER RENDERED before: its header was `(list LINE (list LINE))` — the
second element a list containing a line, so a \"line\" whose segment was a line —
and `put-segments` died with `The value (\"\" :DIM T) is not of type STRING`.
Measured on the live head as `render failed — the head is alive; fix and re-push`.
A blank line is NIL, not a line with an empty dim segment.

Second value is the cursor's LINE: two lines per job after a two-line header."
  (let* ((w (pane-width cols))
         (rows (head-jobs head))
         (n (length rows))
         (sel (if (plusp n) (min (head-picker-sel head) (1- n)) 0))
         (out (list nil (list (cons "background jobs" '(:bold t))))))
    (when (null rows)
      (push (list (cons "    none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one."
                        '(:dim t)))
            out))
    (loop for j in rows
          for i from 0
          do (let* ((running (getf j :running))
                    (state (or (getf j :state) ""))
                    (mark (cond (running "[~]")
                                ((uiop:string-prefix-p "exited 0" state) "[x]")
                                (t "[!]")))
                    (colour (cond (running '(:fg :yellow))
                                  ((uiop:string-prefix-p "exited 0" state) '(:fg :green))
                                  (t '(:fg :red))))
                    (picked (= i sel))
                    (produced (or (getf j :produced) 0))
                    (elapsed (or (getf j :elapsed-ms) 0))
                    (tail (if running
                              (format nil "running · ~a out so far" (bytes-human produced))
                              (format nil "~a · ~a out · ran ~d.~ds" state (bytes-human produced)
                                      (floor elapsed 1000) (floor (mod elapsed 1000) 100)))))
               (push (list (cons (format nil "~a " (if picked "▸" " ")) (and picked '(:reverse t)))
                           (cons mark (if picked (append '(:reverse t) colour) colour))
                           (cons (format nil " ~a ~a" (getf j :id) (getf j :command))
                                 (and picked '(:reverse t))))
                     out)
               (push (list (cons (truncate-to-width
                                  (format nil "         ~a · ~a" (getf j :how) tail) w)
                                 '(:dim t)))
                     out)))
    (push nil out)
    (push (list (cons "    a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone."
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel)))))

(defun subagent-rows (head)
  "The subagents this session spawned, oldest first, one row per subagent — the
reference's `subagents: Vec<SubagentState>`, folded the same way.

The `Subagent` events arrive one per state change and `apply-event` keeps them
all (newest first, in `session-subagents`); the reference folds each into the row
with the same id so `running` becomes `done` rather than a second line
(app.rs:1846). This is that fold, done at draw time so the wire state stays what
the daemon sent. The id is the event's `subagent_id` — the envelope's own
`session_id` is the PARENT's (event.rs:841), and a fold keyed on that counted every
child of one session as one subagent. Rows are `(:session-id :state :prompt :role)`."
  (let ((rows nil))
    (dolist (env (reverse (session-subagents (head-session head))))
      (let* ((id (or (getf env :subagent-id) (getf env :session-id)))
             (row (find id rows :key (lambda (r) (getf r :session-id)) :test #'equal)))
        (if row
            (setf (getf row :state) (getf env :state)
                  (getf row :prompt) (getf env :prompt)
                  (getf row :role) (getf env :role))
            (push (list :session-id id :state (getf env :state)
                        :prompt (getf env :prompt) :role (getf env :role))
                  rows))))
    (nreverse rows)))

(defun subagent-lines (head cols)
  "The subagent tree, the reference's `subagents_lines` (app.rs:5936):

    subagents
    <blank>
        none spawned yet. The model spawns them with the task tool.
    <blank>
        arrows move, Enter reads the subagent's output, o switches into it — subagents are hidden from ctrl-s.

or, with subagents, two lines each in place of the `none` row: `▸ [~] prompt`
(`[…]` opening, `[~]` running yellow, `[x]` done green, `[!]` failed red; the
picked row reversed) over a dim `       …3908838 · role NAME · state`, with
` — not attachable yet` while it is still opening.

Never rendered before, for the same nested-line header as `jobs-lines`.

Returns the lines and, as a second value, the LINE the cursor is on. A pane's
cursor indexes ROWS while the scroll offset counts LINES, and the two differ by
every header above the list — passing one where the other was meant scrolls to
the wrong place, which is how the reference found this in its own test."
  (let* ((w (pane-width cols))
         (rows (subagent-rows head))
         (n (length rows))
         (sel (if (plusp n) (min (head-picker-sel head) (1- n)) 0))
         (out (list nil (list (cons "subagents" '(:bold t))))))
    (when (null rows)
      (push (list (cons "    none spawned yet. The model spawns them with the task tool."
                        '(:dim t)))
            out))
    (loop for s in rows
          for i from 0
          do (let* ((state (or (getf s :state) ""))
                    (mark (cond ((string= state "opening") "[…]")
                                ((string= state "running") "[~]")
                                ((string= state "done") "[x]")
                                ((string= state "failed") "[!]")
                                (t "[ ]")))
                    (colour (cond ((string= state "running") '(:fg :yellow))
                                  ((string= state "done") '(:fg :green))
                                  ((string= state "failed") '(:fg :red))
                                  (t nil)))
                    (picked (= i sel)))
               (push (list (cons (format nil "~a " (if picked "▸" " ")) (and picked '(:reverse t)))
                           (cons mark (if picked (append '(:reverse t) colour) colour))
                           (cons (format nil " ~a" (or (getf s :prompt) ""))
                                 (and picked '(:reverse t))))
                     out)
               (push (list (cons (truncate-to-width
                                  (format nil "       ~a · role ~a · ~a~a"
                                          (short-id (or (getf s :session-id) ""))
                                          (or (getf s :role) "") state
                                          (if (string= state "opening") " — not attachable yet" ""))
                                  w)
                                 '(:dim t)))
                     out)))
    (push nil out)
    (push (list (cons "    arrows move, Enter reads the subagent's output, o switches into it — subagents are hidden from ctrl-s."
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel)))))

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
                     ;; filled in, and org does not mark it done either. Indent
                     ;; 6, not 4: with no mark to paint, the reference's row is
                     ;; `{pad}{cursor}{text}` at `indent - 2`, and measured
                     ;; against its screen `Dependency graph` sits six in, where
                     ;; a heading WITH a box has its `[x]` at four.
                     (push (list :indent 6 :mark nil :text section :body nil
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

(defvar *repo-todo-open* nil
  "Whether the repo item under the cursor is UNFOLDED — the reference's
`repo_open`, one flag beside one cursor.

The cursor is `head-picker-sel` while the todos pane is up (one cursor for every
pane, because only one is open at a time), and moving it folds the item again, so
at most one item is ever open: the reference's rule, and the one the captures
show. Keyed to the cursor rather than to the row's text because that is what Up,
Down, Enter and Tab all agree on. A defvar, not a head slot: a struct layout
change is a restart.")

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

(defun %todo-row-lines (row &key here open)
  "One repo todo row to segment lines — the mark PAINTED, the indent separate.

The reference's row (`todos_lines`, app.rs:5898) is `{pad}{cursor}{mark} {text}{more}`
with `pad` two columns SHORT of the indent and `cursor` either `▸ ` or two spaces,
so a row's box sits at its indent whether or not the cursor is on it. HERE is
that cursor; OPEN unfolds the body under the row, one dim line per detail line at
`pad + 8`. A folded item with a body ends in ` ···` — ONE space, plain, measured:
ours drew two and dimmed it.

The indent is its own segment so the colour lands on the box and not in front of
the whitespace; `TodoMark::painted` in the reference exists for the same reason,
and so does the assertion in the test that checks the ESCAPES rather than the
glyphs. A heading with no mark is one dim segment: it is the operator's prose,
not a task.

Returns a LIST OF LINES — the row, then its body when open. The caller must
FLATTEN these (see `todos-lines`, which appends them), because a nesting mistake
here is invisible: it renders as a list printed into a cell rather than as an
error."
  (let* ((mark (getf row :mark))
         (pad (make-string (max 0 (- (getf row :indent) 2)) :initial-element #\space))
         (cursor (if here "▸ " "  "))
         (text (getf row :text))
         (detail (getf row :body))
         (more (if (and detail (not open)) " ···" "")))
    (append
     (list (if mark
               (list (cons (concatenate 'string pad cursor) nil)
                     (cons (%todo-mark-text mark) (%todo-mark-style mark))
                     (cons (format nil " ~a~a" text more) nil))
               (list (cons (format nil "~a~a~a" pad cursor text) '(:dim t)))))
     (when (and detail open (getf row :item))
       (mapcar (lambda (l) (list (cons (format nil "~a        ~a" pad l) '(:dim t))))
               detail)))))

(defun repo-todo-stops (rows)
  "The indices of the ITEMS in ROWS — where the todos cursor may stop.

Headings roll up the rows beneath them and have nothing to unfold, so the cursor
skips them: the reference's `stops` (app.rs:3268)."
  (loop for r in rows for i from 0 when (getf r :item) collect i))

(defun todos-lines (head cols)
  "The todos pane, row for row the reference's `todos_lines` (app.rs:5859):

    todos
    <blank>
      this session — the model's plan, live:
        [x] S0 decomposition (DONE)
        [ ] S6 panes — …
    <blank>
      the repo's TODO.md — the operator's queue, read-only here:
          Dependency graph
        [x] Phase 0 — repo  [2/2]
            [x] T1 git init, .gitignore, commit PLAN.md + TODO.md.
          ▸ [x] T3 leticl.asd (+ /test system), src/package.lisp (one package
                  :leticl), run.lisp entry (test / demo), source-registry setup for
            [x] T4 src/term.lisp: … ···
    <blank>
      the file itself is in the workspace; this pane never writes it.

The session's plan is what the model writes with `todo_write`, four in with a
painted mark. The repo's TODO.md is drawn, rolled up and painted, and the cursor
(`head-picker-sel`, an index into the repo ROWS) stops only on its items — Up and
Down walk them, Enter or Tab unfolds the one under the cursor
(`*repo-todo-open*`). Measured against letibot's screen: ours put the cursor on the
session's plan (reversed, and Up/Down moved nothing useful), titled the pane
` todos   ↑↓ moves · enter unfolds · esc closes`, indented the plan two columns
short, and closed with `the file is …` where the reference says `the file itself
is …`.

Second value is the cursor's LINE, for the scroll offset (see `subagent-lines`):
the repo's first line plus the cursor's row — nothing above the cursor is ever
unfolded, because only the row under it can be."
  (declare (ignore cols))
  (let* ((s (head-session head))
         (todos (session-todos s))
         (rows (repo-todo-rows-cached (getf (session-wiring s) :workspace)))
         (sel (if rows (min (head-picker-sel head) (1- (length rows))) 0))
         (out (list (list (cons "  this session — the model's plan, live:" '(:dim t)))
                    nil
                    (list (cons "todos" '(:bold t))))))
    (if todos
        (dolist (t2 todos)
          (let ((st (cond ((string= (getf t2 :status) "in_progress") :doing)
                          ((string= (getf t2 :status) "completed") :done)
                          (t :open))))
            ;; a LINE is a list of SEGMENTS — `(list (cons …) (cons …))`, NOT
            ;; `(list (list (cons …)))`, which is a line containing a line
            (push (list (cons "    " nil)
                        (cons (%todo-mark-text st) (%todo-mark-style st))
                        (cons (format nil " ~a" (getf t2 :content)) nil))
                  out)))
        (push (list (cons "    none written yet. The model writes them with todo_write."
                          '(:dim t)))
              out))
    (push nil out)
    (push (list (cons "  the repo's TODO.md — the operator's queue, read-only here:" '(:dim t)))
          out)
    (let ((repo-first (length out)))
      (if (null rows)
          (push (list (cons "    no sections found." '(:dim t))) out)
          (loop for r in rows
                for i from 0
                do (let ((here (and (getf r :item) (= i sel))))
                     ;; APPENDED one line at a time: a row renders to several
                     ;; lines when open, and pushing the list whole would nest it
                     (dolist (line (%todo-row-lines r :here here
                                                      :open (and here *repo-todo-open*)))
                       (push line out)))))
      (push nil out)
      (push (list (cons "  the file itself is in the workspace; this pane never writes it."
                        '(:dim t)))
            out)
      (values (nreverse out) (+ repo-first sel)))))

(defvar *peeked-session* nil
  "The subagent whose scrollback `head-peeked` holds — for the title. A defvar
beside the slot rather than a second slot: a struct layout change is a restart.")

(defvar *peeked-dropped* 0
  "How many of that subagent's events fell off the daemon's ring before the read.")

(defun subagent-out-lines (events)
  "A subagent's scrollback as the reference draws it (`subagent_out_lines`,
letibot `2ac6200`): every tool result as `· name — outcome` over its payload, and
the model's ANSWER text in order beside them — a `digest` subagent calls no tools
by design and its whole product is prose, and the pane that drew only tool results
told the operator there was nothing (*\"when i enter - no output\"*). Reasoning
stays out: it is the model thinking rather than its answer. Spills are listed at
the end, so the full output is one path away."
  (let ((out nil) (spills nil))
    (dolist (env events)
      (case (event-name env)
        ((:transcript-content)
         (let ((item (getf env :item)))
           (when item
             (switch ((getf item :type) :test #'string=)
               ("tool_result"
                (push (format nil "· ~a — ~a" (getf item :name)
                              (%outcome-word (outcome-name (getf item :outcome))))
                      out)
                (dolist (l (%payload-lines (getf item :payload)))
                  (push (format nil "  ~a" l) out))
                (push "" out))
               ("assistant"
                (let ((text (or (getf item :text) "")))
                  (when (plusp (length (string-trim " " text)))
                    (dolist (l (uiop:split-string text :separator '(#\newline)))
                      (push l out))
                    (push "" out))))))))
        ((:tool-finished)
         (awhen (getf env :spill) (push it spills)))))
    (when spills
      (push "full output on disk:" out)
      (dolist (sp (nreverse spills)) (push (format nil "  ~a" sp) out))
      (push "" out))
    (nreverse out)))

(defun peek-lines (head cols)
  "A peeked subagent's scrollback — the reference's `sub_out_lines`: the title
names the subagent, a dropped count when the ring lost events before the read,
then the output oldest first, and the empty case SAYS what it means — *neither an
answer nor tool output* — and names the two reasons that can be true of, because
\"no tool output\" reads as a fault for a subagent that was never going to produce
any."
  (let* ((events (head-peeked head))
         (body (or (subagent-out-lines events)
                   (list "    this subagent's scrollback has neither an answer nor tool output. It may still be running, or its rows may have fallen off the daemon's ring."))))
    (append
     (list (list (cons (format nil "subagent output — ~a"
                               (if *peeked-session* (short-id *peeked-session*) "?"))
                       '(:bold t))))
     (when (plusp *peeked-dropped*)
       (list (list (cons (format nil "    ~d earlier event~:p fell off the daemon's scrollback before this read"
                                 *peeked-dropped*)
                         '(:dim t)))))
     (list nil)
     (mappend (lambda (l) (or (wrap-segments (list (cons l nil)) (pane-width cols))
                              (list nil)))
              body)
     (list nil
           (list (cons "    arrows scroll, Enter re-reads, Esc back" '(:dim t)))))))

;;; ------------------------------------------------------------ pickers ;;;
;;;
;;; The MODE and MODELS pickers, to the reference's shape (`mode_picker_lines`,
;;; app.rs): a CARD above the composer with the transcript still visible, not a
;;; full-body pane — the operator, looking at ours: *"in letibot it is not a full
;;; pane"*. Both read their choices from the daemon's own settings rows
;;; (`SettingRow.choices`, protocol 18), so the head keeps no list to drift.
;;;
;;; One flag for both, one cursor (`head-picker-sel`), one drawing, because the
;;; one thing this file has already been burned by is a second copy of a list that
;;; then drifts. The flag is a defvar: a head slot is a struct layout change, which
;;; is a restart.

(defvar *pick-open* nil
  "Which picker is up: NIL, `:mode` or `:model`.")

(defvar *mode-confirm* nil
  "The mode name awaiting the operator's [y]/[enter], or NIL. `allow-all` is the
one mode that asks first — it is the point where privilege escalation, deletes
outside the project and first contact with a new host all stop asking.")

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

(defun pick-key (which)
  (ecase which (:mode "mode") (:model "model")))

(defun pick-choices (head &optional (which *pick-open*))
  (and which (setting-choices head (pick-key which))))

(defun pick-current (head &optional (which *pick-open*))
  "The choice that answers NOW, as the picker's list spells it: the mode row's
value is `allow-all (this box, consented)` and the list says `allow-all`, so the
first word; the model row's is `local (qwen-3.8-27b)` or `deepseek/…`, and the
list says the bare form the header shows."
  (let ((v (or (and which (setting-value head (pick-key which))) "")))
    (ecase which
      (:mode (subseq v 0 (or (position #\space v) (length v))))
      (:model (%header-model v))
      ((nil) ""))))

(defun %header-model (value)
  "`local (qwen-3.8-27b)` → `qwen-3.8-27b`; anything else as written — the
reference's `header_model`."
  (if (and (alexandria:starts-with-subseq "local (" value)
           (alexandria:ends-with #\) value))
      (subseq value 7 (1- (length value)))
      value))

(defun open-pick (head which)
  "Open the picker for WHICH, seeded on what answers now so enter on an untouched
list is a no-op — the courtesy the reference pays. One list on the screen at a
time: any pane closes."
  (unless (head-settings head) (%send head (make-settings)))
  (setf *pick-open* which
        (head-mode head) :normal
        (head-picker-sel head)
        (or (position (pick-current head which) (pick-choices head which) :test #'string=) 0)
        (head-dirty head) t))

(defun close-pick (head)
  (setf *pick-open* nil (head-dirty head) t))

(defun pick-card-lines (head cols)
  "The picker's card — `mode_picker_lines` row for row: a bold title, each choice
as `▸  1  name` with the cursor's row reversed whole and `← now` at the right of
the one that answers, then the two dim hint rows (three for models)."
  (let* ((models (eq *pick-open* :model))
         (choices (pick-choices head))
         (current (pick-current head))
         (n (length choices))
         (sel (min (head-picker-sel head) (max 0 (1- n))))
         (w (max 20 cols)))
    (append
     (list (list (cons (if models "what answers this conversation"
                           "the mode this session runs under")
                       '(:bold t))))
     (unless choices
       (list (list (cons (if models
                             "  this daemon has not named its models — `/models PROVIDER/MODEL` still works, if you know the name."
                             "  this daemon has not named its modes — `/mode NAME` still works, if you know the name.")
                         '(:dim t)))))
     (loop for name in choices
           for i from 0
           for here = (string= name current)
           for picked = (= i sel)
           collect (let* ((left (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i)) nil)
                                      (cons name (if here '(:bold t) nil))))
                          (right (if here (list (cons "← now" '(:dim t))) nil))
                          ;; the cursor's row is reversed over its TEXT — mark,
                          ;; number, name — and the padding is plain: the
                          ;; reference wraps `left` in REVERSE…RESET before
                          ;; `split_row` pads it. Measured on its raw row.
                          (left (if picked
                                    (mapcar (lambda (seg) (cons (car seg) (append (cdr seg) '(:reverse t))))
                                            left)
                                    left)))
                     (split-row left right w)))
     (list (list (cons "  ↑↓ moves · enter switches · or type a name or the number on the left · esc closes"
                       '(:dim t)))
           (list (cons (if models
                           "  this conversation only, from the next turn; the transcript and the tools are untouched"
                           "  a mode change moves THIS session from its next call, and every later session in this project.")
                       '(:dim t))))
     (when models
       (list (list (cons "  `/default-model NAME` is what new sessions start on · this is not that"
                         '(:dim t))))))))

(defun mode-confirm-lines (cols)
  "The `allow-all` question, wrapped rather than trimmed: this one is read, not
glanced at."
  (when *mode-confirm*
    (mapcar (lambda (l) (mapcar (lambda (seg) (cons (car seg) '(:bold t :fg :yellow))) l))
            (wrap-segments
             (list (cons "allow-all: privilege escalation, deletes outside the project and first contact with a new host all stop asking. On this box that is this box. It lasts for this session only, and a daemon restart drops it.  [y] or [enter] confirm   [esc] or any other key cancels"
                         nil))
             (max 20 cols)))))

(defun %send-mode (head name consented)
  "The mode frame. CONSENTED is a JSON **boolean**, never null.

`Mode.consented` is `consented: bool` with `#[serde(default)]` (protocol.rs:452):
serde's default accepts a MISSING key, not a present `null`. Our encoder writes
NIL as `null`, so `:consented nil` made the daemon's read loop break with an Err
and **close the connection** — every mode but `allow-all` went through that path.
The encoder has `:false` for exactly this, and `t` is the true side."
  (%send head (list :frame "mode"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :name name
                    :consented (if consented t :false))))

(defun mode-action (head name)
  "Move the session to mode NAME — `allow-all` asks first (`mode_action`)."
  (if (string= name "allow-all")
      (setf *mode-confirm* name (head-dirty head) t)
      (progn (%send-mode head name nil)
             (say head (format nil "mode → ~a" name)))))

(defun take-pick (head name)
  "The picker's choice NAME, taken: the card closes; a mode already in force is
said and not sent; a model goes as the slash line the operator would have typed
(`take_pick`, `take_mode`)."
  (let ((which *pick-open*))
    (close-pick head)
    (ecase which
      (:mode (if (string= name (pick-current head :mode))
                 (say head "already that mode")
                 (mode-action head name)))
      (:model (say head (format nil "switching to ~a…" name))
              (%send-slash head (format nil "models ~a" name))
              (%send head (make-settings))))))

(defun pick-by-text (head typed)
  "What the operator TYPED while the picker was up, at enter — `pick_mode`: the
row's number, an exact name (case, `_` and spaces forgiven), or a unique prefix;
otherwise say why not and keep the card."
  (let* ((choices (pick-choices head))
         (typed (string-trim " " typed)))
    (cond
      ((zerop (length typed)) (close-pick head))
      ((null choices)
       (say head (if (eq *pick-open* :model)
                     "this daemon does not send the model list; use `/models PROVIDER/MODEL`"
                     "this daemon does not send the mode list; use `/mode NAME`")))
      (t
       (let* ((n (ignore-errors (parse-integer typed)))
              (norm (lambda (s) (substitute #\- #\space (substitute #\- #\_ (string-downcase s)))))
              (want (funcall norm typed))
              (exact (find want choices :key norm :test #'string=))
              (hits (remove-if-not (lambda (c) (alexandria:starts-with-subseq want (funcall norm c)))
                                   choices)))
         (cond
           ((and n (<= 1 n (length choices))) (take-pick head (nth (1- n) choices)))
           (exact (take-pick head exact))
           ((= (length hits) 1) (take-pick head (first hits)))
           ((null hits)
            (say head (format nil "no ~a matches ~s — esc closes the list"
                              (if (eq *pick-open* :model) "model" "mode") typed)))
           (t (say head (format nil "~d ~as match ~s; type the number on the left instead"
                                (length hits) (if (eq *pick-open* :model) "model" "mode") typed)))))))))

(defun pick-key-event (head key)
  "The picker's own keys — the reference's arm: ↑↓ wrap, enter takes the cursor's
row and a digit takes that row, both only when nothing is typed; esc closes.
Returns T when the key was the picker's; anything else is the composer's, which is
how a name gets typed."
  (let* ((type (getf key :type))
         (n (length (pick-choices head)))
         (empty (zerop (length (composer-buffer (head-composer head))))))
    (cond
      ((and (eq type :up) (plusp n))
       (setf (head-picker-sel head) (mod (1- (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :down) (plusp n))
       (setf (head-picker-sel head) (mod (1+ (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :enter) empty)
       (if (zerop n)
           (say head (if (eq *pick-open* :model)
                         "this daemon does not send the model list; use `/models PROVIDER/MODEL`"
                         "this daemon does not send the mode list; use `/mode NAME`"))
           (take-pick head (nth (min (head-picker-sel head) (1- n)) (pick-choices head))))
       t)
      ((and (eq type :char) empty (digit-char-p (getf key :ch))
            (<= 1 (digit-char-p (getf key :ch)) n))
       (let ((at (1- (digit-char-p (getf key :ch)))))
         (setf (head-picker-sel head) at)
         (take-pick head (nth at (pick-choices head))))
       t)
      ((eq type :esc) (close-pick head) t)
      (t nil))))

(defun mode-confirm-key (head key)
  "The `allow-all` question owns every key while it is up: [y] or [enter] send the
mode with consent; anything else cancels."
  (let ((type (getf key :type)))
    (if (or (eq type :enter)
            (and (eq type :char) (member (getf key :ch) '(#\y #\Y))))
        (let ((name *mode-confirm*))
          (setf *mode-confirm* nil)
          (%send-mode head name t)
          (say head (format nil "mode → ~a (consented)" name)))
        (progn (setf *mode-confirm* nil)
               (say head "allow-all not taken")))
    (setf (head-dirty head) t)
    t))

