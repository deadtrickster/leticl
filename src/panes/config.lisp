;;;; config.lisp — the /config pane: the head's own settings, changeable in place
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; --------------------------------------------------------- the config pane ;;;

(defparameter *head-setting-rows*
  '("diff" "verbosity" "thinking" "tools" "raw_calls" "marker_seam" "git_format")
  "The settings the HEAD owns, in the config pane's own order.

The daemon's rows are its own and read-only here — this head cannot change what a
daemon flag is. But the five above are the head's own choices, they live in
`head.toml` (S5), and a pane that lists them and cannot change them is a pane that
teaches the operator the wrong thing about what is editable.

**`verbosity` is second, and that is letibot's order** (its pane lists diff view, verbosity,
thinking, tool output, raw tool calls) — two panes for one box should be read the same way. It is
also the one row here that is not a toggle, which its `:edit` below says.")

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
        ((string= key "marker_seam")
         ;; the reference's own word for a fold, which is what this is: the seam shown or not
         (if *marker-seam* "shown" "hidden"))
        ((string= key "verbosity") (verbosity-name))
        ;; **THE GIT FIELD'S FORMAT IS HERE BECAUSE THE OPERATOR LOOKED FOR IT HERE.** The row names
        ;; the template IN FORCE (so the pane and the row can never disagree), and the first stop of
        ;; the cycle is the built-in default. A FREE template stays the file's business — `git_format`
        ;; takes any of them, and the pane cycles presets rather than pretending to edit text.
        ((string= key "git_format")
         (or (getf (head-prefs head) :git-format)
             (format nil "default (~a)" +git-format-default+)))
        (t "?")))

(defun %save-head-prefs-note (head)
  "Persist HEAD's choices; NIL when it was written, and ` (not saved: …)` when it
was not — the reference appends exactly that to the notice
(app.rs:6413-6423, 6541-6545).

`ignore-errors` was swallowing it whole: a read-only `head.toml`, a full disk or
a `$XDG_CONFIG_HOME` that is not there left the pane saying `diff view → unified`
and the file saying `split`, and the next start of the head silently undid the
change. A setting that did not persist is a different fact from one that did."
  (handler-case (progn (save-head-prefs head) nil)
    (error (e) (format nil " (not saved: ~a)" e))))

(defun %flip-head-setting (head key)
  "Flip one of the HEAD's own settings in the live plist and persist it.

The plist is the source of truth while the head runs; `head-into-prefs` reads it
back at save time, so there is one direction of flow and no second copy to keep in
step. Returns the save's complaint, or NIL when it landed."
  (cond
    ((string= key "diff")
     (setf (head-pref head :diff)
           (if (string= (%head-setting-value head "diff") "split") "unified" "split")))
    ((string= key "thinking") (%flip-fold head :show-reasoning))
    ((string= key "tools") (%flip-fold head :show-tools))
    ((string= key "git_format")
     ;; Three stops: the shipped default, a spaced one, and the branch alone. `nil` is the default
     ;; rather than a fourth string, because the default has to stay one value in one place.
     (let ((now (getf (head-prefs head) :git-format)))
       (setf (head-pref head :git-format)
             (cond ((null now) "%b %!%+")
                   ((string= now "%b %!%+") "%b")
                   (t nil)))))
    ((string= key "raw_calls")
     (setf (head-pref head :raw-calls)
           (not (head-pref head :raw-calls))))
    ;; **`marker_seam` IS A ROW THE PANE DRAWS AND COULD NOT FLIP.** The pane lists it
    ;; (`*head-setting-rows*`), `config-rows` gives it the edit mark and the `:head` dispatch,
    ;; and `%head-setting-value` answers `shown`/`hidden` from `*marker-seam*` — while this
    ;; `cond` had no arm for it: Enter wrote head.toml, changed nothing, and reported the value
    ;; unchanged. `%set-marker-seam` is documented as its only writer and nothing called it
    ;; (found by the panes reviewer, 2026-10-11). The value is the head's own, not a preference —
    ;; it changes what the ROW renders to — so the setter is the act and the save below is harmless.
    ((string= key "marker_seam")
     (%set-marker-seam (not *marker-seam*))))
  (%save-head-prefs-note head))

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
five, then the daemon's SETTINGS, then the daemon's files.

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
           for label in '("diff view" "verbosity" "reasoning" "tool output" "raw tool calls"
                          "marker seam" "git format")
           collect (list :section "head — this window"
                         :key label
                         :value (%head-setting-value head key)
                         :source head-source
                         :choices nil
                         ;; **A row with more than two values POINTS AT THE VERB rather than
                         ;; cycling** (R38). Four rungs walked through one Enter at a time is the
                         ;; interface R38 removed, one screen over; the other four rows are true
                         ;; toggles, which the rule permits cycling. letibot's pane says the same
                         ;; sentence, word for word.
                         :edit (if (string= key "verbosity")
                                   (list :no "`/verbosity` with nothing after it opens the card")
                                   (list :head key))))
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
      ✎ verbosity        reading
      ✎ reasoning        folded
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
                    finally (return line)))
            ;; **AND WHERE EVERY OTHER ROW LANDED** — a click needs the row's own line, and a
            ;; section heading plus a blank sits between groups, so `(line - header)` is wrong by
            ;; two for every group after the first: `click-row->sel` used `per-row 1` against this
            ;; pane's variable layout and selected a neighbour of the row under the pointer (found
            ;; by two reviews, 2026-10-11 — the same defect shape as the subagents pane's Enter).
            ;; The lines come out of the SAME walk that drew them, which is this file's rule for
            ;; every pane: the click asks the pane rather than recounting its geometry.
            (let ((line 2) (sec "") (lines nil))
              (loop for r in rows
                    for i from 0
                    do (unless (string= (getf r :section) sec)
                         (when (plusp (length sec)) (incf line))
                         (incf line)
                         (setf sec (getf r :section)))
                       (push (cons i line) lines)
                       (incf line))
              (nreverse lines)))))

(defun config-stop-at-line (head line)
  "The config pane's row on LINE, or NIL — the pane's own answer, asked by the click conversion.

**The pane's rows are NOT one line apart**, and that is the whole of this function: a section
heading and a blank sit between groups and a `from …` line sits under the selected row, so
`(line - header)` names a neighbouring row for every group after the first. `todos-stops` grew
`todo-stop-at-line` for exactly this reason and the click path asks it; this is the same door for
the same fact (found by the panes and editor reviewers, 2026-10-11).

Reads the third value `config-lines` returns — the lines its rows were drawn on, from the walk
that drew them — so a heading the pane grows moves this with it."
  (multiple-value-bind (lines sel-line per-row)
      (config-lines head (head-settings head) 80)
    (declare (ignore lines sel-line))
    (let ((hit (find line per-row :key #'cdr)))
      (and hit (car hit)))))

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
           (let ((failed (%flip-head-setting head (second edit)))
                 (after (nth (position row rows) (config-rows head))))
             (say head (format nil "~a → ~a~@[~a~]"
                               (getf after :key) (getf after :value) failed))))
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

