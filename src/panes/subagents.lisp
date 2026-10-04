;;;; subagents.lisp — the subagents pane: the tree this session spawned, and what the
;;;; `o` key does on one of its rows (attach this head to it).
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

(defun subagent-rows (head)
  "The subagents this session spawned, oldest first, one row per subagent — the
reference's `subagents: Vec<SubagentState>`, folded the same way.

The `Subagent` events arrive one per state change and `apply-event` keeps them
all (newest first, in `session-subagents`); the reference folds each into the row
with the same id so `running` becomes `done` rather than a second line
(app.rs:1846). This is that fold, done at draw time so the wire state stays what
the daemon sent. The id is the event's `subagent_id` — the envelope's own
`session_id` is the PARENT's (event.rs:841), and a fold keyed on that counted every
child of one session as one subagent. Rows are `(:session-id :state :prompt :answer :role)` — and **`:prompt` and `:answer` are two things
because the daemon sends them in one field**: the task's first line while the child runs, its answer's
first line once it is done. The fold keeps the FIRST as the prompt and the LAST as the answer, so a
finished child's row can still say what it was asked."
  (let ((rows nil))
    (dolist (env (reverse (session-subagents (head-session head))))
      (let* ((id (or (getf env :subagent-id) (getf env :session-id)))
             (row (find id rows :key (lambda (r) (getf r :session-id)) :test #'equal)))
        (if row
            (setf (getf row :state) (getf env :state)
                  ;; **THE PROMPT IS THE FIRST THING THE DAEMON SAID; THE ANSWER IS THE LAST.**
                  ;; The daemon publishes `derive_title(prompt)` — the task's first line — on `opening`
                  ;; and `running`, and the child's ANSWER's first line on `done`, into the SAME field
                  ;; (`harness.rs:7177`, `:7322`). Last-wins therefore replaced the task with the answer:
                  ;; measured on the operator's head, four finished children whose `:prompt` read
                  ;; `ready`, `4191 lines.`, … — which is why the pane could not show what a child was
                  ;; asked, and why the operator asked for it. A later value is the answer; the prompt
                  ;; is whatever the FIRST event carried. The residual is stated rather than hidden: a
                  ;; child whose first event is `done` never had a prompt here, so its row has none.
                  (getf row :answer) (getf env :prompt)
                  (getf row :role) (getf env :role))
            (push (list :session-id id :state (getf env :state)
                        :prompt (getf env :prompt) :answer nil :role (getf env :role))
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
               ;; **THE SECOND LINE IS THE CHILD'S ANSWER, NOT ITS ID.** The operator: *"right now each
               ;; agent takes two lines on the agents pane and they are underutilized. so the first line
               ;; can gain a prompt excerpt and the second line - response excerpt."* The first line
               ;; already carries the prompt (which the fold now keeps as the TASK rather than letting
               ;; `done` overwrite it with this very answer), the id is a lookup key, and the state is
               ;; already the mark on the first row — so this line carries what the child SAID.
               (push (list (cons (truncate-to-width
                                  (format nil "       ~@[→ ~a~]~@[~a~]"
                                          (getf s :answer)
                                          (if (string= state "opening")
                                              "not attachable yet — it is still opening"
                                              (if (getf s :answer) "" state)))
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


;;; ------------------------------------------ `o` on a subagent row ;;;

(defun subagent-switch (head)
  "Switch this head INTO the subagent under the cursor — the reference's
`Key::Char('o')` on the subagents pane (app.rs:3696-3707). T when a frame went
out.

The pane's own footer has advertised this since it was written
(`arrows move, Enter reads the subagent's output, o switches into it`) and no key
was ever bound to it, so the one row on the screen that names a key named a key
that did nothing. A subagent still `opening` has no session to switch to yet, and
the row already says `— not attachable yet`; refusing here with the same words is
what keeps the two from disagreeing.

The KEY is `src/editor.lisp:283-296`'s — its `:char` arm handles only `#\\q` —
and this is the act that arm is missing."
  (let ((row (nth (max 0 (head-picker-sel head)) (subagent-rows head))))
    (cond ((null row) (say head "no subagent under the cursor") nil)
          ((string= (or (getf row :state) "") "opening")
           (say head "not attachable yet — it is still opening") nil)
          ((null (getf row :session-id))
           (say head "that subagent has no session id to switch to") nil)
          (t (%send head (make-switch (getf row :session-id) 0))
             (setf (head-mode head) :normal
                   (head-dirty head) t)
             t))))
