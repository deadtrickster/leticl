;;;; notice-card.lisp — the notice rows: a job or a task settling, what kind it is, and
;;;; how much of it the conversation shows.

(in-package #:leticl)

(defparameter +notice-prefixes+ (list "[job] " "[task] " "[todo check] ")
  "The daemon's own openings for a completion notice: a settled job, and a finished subagent.

**The prefix is the daemon's, not this head's invention** — the same discipline as keying a note's
remedy on its CODE: a settlement arrives as a `User` row with `speaker: agent` and nothing else to
identify it, so the text is what says what it is, and this is the one word in it that is the daemon's
own voice rather than a job's.

**`[task]` is why this is a list rather than a constant.** `[job]` was the only one handled, so an
agent's completion — the same shape, the same `speaker: agent`, the same closing paragraph addressed to
the model — was drawn as full prose while the job's was a one-liner. The operator found it: *\"too much,
for example i dont want to see that message to you 'This is the completion…' I also dont care about
'sabagent you started…' it must be something like Job <id> <command summary or wrap> finished <result
result summary or wrap> same for agents.\"*")

(defun %notice-kind (text)
  "`:job`, `:task`, `:todo`, or NIL — which of the daemon's notices TEXT is, by its own opening.

**`[todo check] ` is the third, and it is a NUDGE rather than a settlement** — a heading, the item, and
a closing paragraph addressed to the MODEL (*do this one, or mark it done, or drop it*). Its prefix is
the daemon's, the same discipline as the other two: the text is what says what it is."
  (cond ((and (stringp text) (uiop:string-prefix-p "[job] " text)) :job)
        ((and (stringp text) (uiop:string-prefix-p "[task] " text)) :task)
        ((and (stringp text) (uiop:string-prefix-p "[todo check] " text)) :todo)
        (t nil)))

(defun %notice-folds-p (text)
  "Is TEXT drawn as a card rather than as prose?

**A settlement always folds — the operator asked for that in their own words. A TODO NAG folds only at
a READING rung**: *\"in read verbosity todo nag shouldnt show me model prompt only todo head\"* is a
statement about a RUNG and not about the row, so above `reading` the whole nag is drawn, advice and all,
which is what letibot does at the same rung (their 281f3d6). Per-kind because a nag's advice and a
settlement's closing promise are different things that sit in the same place."
  (let ((kind (%notice-kind text)))
    (and kind (or (not (eq kind :todo)) (reading-p)))))

(defun %job-notice-p (text)
  "Is TEXT one of the daemon's completion notices? — R41's own message, in its own voice."
  (and (stringp text)
       (some (lambda (p) (uiop:string-prefix-p p text)) +notice-prefixes+)))

(defun %job-notice-parts (text)
  "TEXT split into `(values OPENING FACTS REST)`.

  · **OPENING** — the daemon's first line, as written (`a job you backgrounded has ended:`);
  · **FACTS** — the `  - \`ID\` …` lines, one per settled job, in the daemon's own words;
  · **REST** — the closing paragraph, which is a promise TO THE MODEL (*you do not need to wait for
    it*) rather than anything the reader needs told.

The split is on the daemon's own shape and not on a guess: the fact lines are the ones that begin
with `- ` after trim, and everything after them is the closing sentence."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (opening (or (first lines) ""))
         (tail (rest lines))
         (facts (remove-if-not (lambda (l) (uiop:string-prefix-p "- " (string-left-trim " " l)))
                               tail))
         (rest (remove-if (lambda (l) (uiop:string-prefix-p "- " (string-left-trim " " l)))
                          tail)))
    (values opening
            (mapcar (lambda (l) (string-left-trim " -" l)) facts)
            (string-trim " " (format nil "~{~a~^ ~}" rest)))))

(defun %notice-card-lines (text)
  "The notice as ROWS — the parts the operator asked to see, each on its own line.

**Their words, twice over.** First the shape: *\"we wanted to have separate rows with parts of cmd and
prompt and result visible.\"* Then the field that must not lead: *\"these j90 and s-* do not give me any
information … like do you think i remember job ids?\"* — an id is a lookup key, and `/jobs` is where a
key lives. So:

    Job  sleep 3; echo done
        result  exited 0 after 3.0s, wrote 5 bytes
    Agent  Answer with one word: ready.
        result  done: ready

**The headline is WHAT IT WAS** — a job's own command, an agent's own task — and the result sits under
it. Nothing is re-worded: the split is the DAEMON's own colon, because a job fact is
`<id> <state> after <t>, wrote <b> bytes: <command>` (`harness.rs:668`) and a subagent's is
`<id> done: <what it answered>`. The id is the first token of the head and is dropped; the report is
the rest of it.

**The kind is the FACT's own**, not the row's first heading: the daemon coalesces a job's notice and a
subagent's into ONE row, so each fact is labelled by the heading it sits under.

**An agent's TASK is not in the notice at all** — it carries what the child answered, not what it was
asked — so it is looked up from the subagent row (`:prompt`, the same string the subagents pane draws
as its title). A head that cannot see the child falls back to the id, since a headline with nothing in
it is worse than a key."
  (let ((out nil) (kind nil))
    (dolist (line (uiop:split-string text :separator '(#\newline)))
      (cond
        ((uiop:string-prefix-p "[job] " line) (setf kind :job))
        ((uiop:string-prefix-p "[task] " line) (setf kind :task))
        ((uiop:string-prefix-p "- " (string-left-trim " " line))
         (let* ((task-p (eq kind :task))
                (fact (string-trim " " (remove #\` (string-trim " -" line))))
                (at (search ": " fact))
                (head (if at (subseq fact 0 at) fact))
                (tail (and at (subseq fact (+ at 2))))
                (id (subseq head 0 (or (position #\space head) (length head))))
                (report (string-left-trim
                         " " (subseq head (min (length head) (1+ (length id))))))
                (task (and task-p (%notice-agent-task-for id))))
           (push (format nil "~a~a" (if task-p "Agent " "Job ")
                         (if task-p (or task id) (or tail report)))
                 out)
           (push (format nil "    result  ~a"
                         (if task-p (format nil "~a~@[: ~a~]" report tail) report))
                 out)))))
    (nreverse out)))

(defun %notice-agent-task-for (id)
  "The subagent's own task, by the id a fact line carries — see `%notice-card-lines`.

Split from `%notice-agent-task` because a coalesced row has several facts and each needs ITS child: a
lookup keyed on the whole text would answer the first fact's task for every one of them."
  (let ((row (and *payload-head*
                  (find id (ignore-errors (subagent-rows *payload-head*))
                        :key (lambda (r) (getf r :session-id)) :test #'string=))))
    (and row (getf row :prompt))))

(defun %job-notice-rows (text)
  "The daemon's notice as rows a reader can OPEN — R41's own vocabulary, verbatim.

**The full message is what `ctrl-t` reveals**, minus nothing: the facts, the command in full, and
the closing sentence. Re-wording any of it here would be a second copy of the daemon's meaning, and
the point of the one-liner is that the reader may choose to read the whole thing."
  ;; **the backticks go here as well as in the one-liner.** They are markdown for the MODEL, and
  ;; this is the screen: a reader opening the window to read the command should not be reading the
  ;; quoting the prompt needed.
  (mapcar (lambda (l) (remove #\` l))
          (uiop:split-string text :separator '(#\newline))))

