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
child of one session as one subagent. Rows are `(:session-id :state :prompt :answer :role :task :model)` — and the slot is
also seeded from a SNAPSHOT's `subagents` field (`%subagent-view->event`), which is
what brings the parent's tree back on a switch back: a seeded envelope carries
`:answer` under its own name and `:task` in full, and the fold cannot tell it from
the live thing."
  (let ((rows nil))
    (dolist (env (reverse (session-subagents (head-session head))))
      (let* ((id (or (getf env :subagent-id) (getf env :session-id)))
             (row (find id rows :key (lambda (r) (getf r :session-id)) :test #'equal)))
        (if row
            (setf (getf row :state) (getf env :state)
                  ;; **AN EXPLICIT `:answer` KEY WINS, and truth is not the test.** A current
                  ;; daemon's events carry `answer` under its own name (`#[serde(default)]`, so
                  ;; nil while the child runs — said, not absent); the SNAPSHOT's seeded rows
                  ;; carry it too (`%subagent-view->event`). An OLDER daemon's events have no
                  ;; key at all, and for those the finish's `prompt` still IS the answer —
                  ;; presence, not truth, separates *there is none* from *it cannot say*.
                  (getf row :answer) (if (member :answer env)
                                         (getf env :answer)
                                         (getf env :prompt))
                  (getf row :role) (getf env :role)
                  ;; `task`/`model` are the same on every state, so last non-empty wins —
                  ;; a first event from an older daemon has neither, and a later one from
                  ;; a current daemon should still put them on the row
                  (getf row :task) (or (and (plusp (length (or (getf env :task) "")))
                                            (getf env :task))
                                       (getf row :task))
                  (getf row :model) (or (and (plusp (length (or (getf env :model) "")))
                                             (getf env :model))
                                        (getf row :model)))
            (push (list :session-id id :state (getf env :state)
                        ;; **THE TITLE IS THE TASK IN FULL WHEN THE WIRE CARRIES IT** — the
                        ;; event's own rule (event.rs, `Subagent::prompt`): `prompt` means the
                        ;; subtask's first line while the child opens and the ANSWER's first line
                        ;; on the finish, and a row titled by the last event's `prompt` is titled
                        ;; by its own answer. `task` is the subtask whole, the same on every
                        ;; state, and this head truncates for a row as it does for everything
                        ;; else it draws — which is the reference's own row. `task` empty is a
                        ;; daemon older than the field: `prompt`'s first line, the pre-field
                        ;; behaviour, and the pane's own comment about *the fold keeps the task*
                        ;; is finally true rather than aspirational.
                        :prompt (let ((task (or (getf env :task) "")))
                                  (if (plusp (length task)) task (getf env :prompt)))
                        :answer (and (member :answer env) (getf env :answer))
                        :role (getf env :role)
                        :task (getf env :task)
                        :model (getf env :model))
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
    (flet ((group-of (state)
              (cond ((string= state "running") 0)
                    ((string= state "opening") 1)
                    ((string= state "done") 2)
                    ((string= state "failed") 3)
                    (t 4))))
       (let ((sorted (sort (copy-list rows) #'<
                           :key (lambda (s) (group-of (or (getf s :state) ""))))))
    (loop for s in sorted
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
                     out))))
     (push nil out)
    (push (list (cons "    arrows move, Enter or o switches into it, p reads its prompt — subagents are hidden from ctrl-s."
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel))))))

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
