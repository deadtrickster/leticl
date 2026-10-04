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

(defun %notice-agent-task (text)
  "The subagent's own task, for a `[task]` notice — the first line the daemon titled it with.

**Looked up rather than parsed out of the notice**, because the notice does not carry it: the fact line
is `<id> done: <what it answered>`, and what it was ASKED lives on the subagent row (`:prompt`, which is
`derive_title(prompt)` — the task's first line — the same string the subagents pane draws as its title,
so the two surfaces cannot disagree). `*payload-head*` is the head the row is being drawn for, bound in
`%viewport-lines` where rows are drawn; a render with no head bound answers NIL and the field is simply
absent rather than wrong."
  (let* ((facts (multiple-value-bind (o f r) (%job-notice-parts text)
                  (declare (ignore o r)) f))
         ;; **THE ID IS ON THE FACT LINE, not in the opening sentence.** The opening reads `a subagent
         ;; you started has finished:`, whose second word is `subagent` — measured, and the first
         ;; version of this took exactly that. The fact line is `\`s-…\` done: …`, so the id is its
         ;; first token with the daemon's backticks off.
         (first-fact (first facts))
         (id (and first-fact (subseq first-fact 0 (or (position #\space first-fact)
                                                      (length first-fact)))))
         (row (and id *payload-head*
                   (find (remove #\` id)
                         (ignore-errors (subagent-rows *payload-head*))
                         :key (lambda (r) (getf r :session-id)) :test #'string=))))
    (and row (getf row :prompt))))

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

(defun %notice-counts (text)
  "How many JOBS and how many SUBAGENTS TEXT reports — counted per group, by the daemon's own headings.

**A heading counts none of its own facts**: `[job] 3 jobs you backgrounded have ended:` is ONE
opening line and THREE settlements under it, so counting the openings read *1 job ended (j12, j15,
j19)* for a batch of three — measured on the first run of this. A heading (`[job] `/`[task] `) starts a
group and each `- ` line under it is one settlement of that kind."
  (let ((jobs 0) (tasks 0) (kind nil))
    (dolist (line (uiop:split-string text :separator '(#\newline)))
      (cond ((uiop:string-prefix-p "[job] " line) (setf kind :job))
            ((uiop:string-prefix-p "[task] " line) (setf kind :task))
            ((uiop:string-prefix-p "- " (string-left-trim " " line))
             (case kind (:job (incf jobs)) (:task (incf tasks)) (t nil)))))
    (values jobs tasks)))

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

(defun %job-notice-facts (text)
  "The settlement's facts as ONE line — `j152 killed by job_kill after 27.6s, wrote 15 bytes`.

**Built from the daemon's own sentence and not from a summary of it**, which is R37's ladder
applied to a second surface: the source that costs nothing is the one already computed, and a
settlement arrives with the job, its ending, its duration and its byte count already spelled out.
The backticks go because they are markdown for the MODEL — the reader is looking at a rendered
screen, not at the prompt.

**A model was offered for this and is not needed**, and the measurement is the reason: every fact
the reader wants is in this line before anything reads it. That is worth writing down because *a
model could summarize it* is the shape of answer that adds a latency and a failure mode to a path
that has neither."
  (let* ((facts (multiple-value-bind (o f r) (%job-notice-parts text)
                  (declare (ignore o r)) f))
         ;; **the backticks are REMOVED, not blanked.** `substitute` put a space where each one was,
         ;; which read ` j152  killed by job_kill` — two spaces for every quote, measured on the
         ;; first run of this. They are markdown for the MODEL; the reader is looking at a
         ;; rendered screen.
         (one (mapcar (lambda (f)
                        (string-trim " "
                                     (remove #\` (string-trim " " f))))
                      facts)))
    (cond ((null one) nil)
          ;; **AN AGENT'S NOTICE NAMES THE AGENT AND WHAT IT WAS ASKED.** A job's one-liner is the
          ;; daemon's own fact and needs nothing added; a subagent's reads `<id> done: <answer>`, and
          ;; the operator's shape for it is `Agent <id> · <task> · <result>` — the task being the one
          ;; field the notice does not carry, which is why it is looked up (see `%notice-agent-task`)
          ;; rather than parsed. The daemon's `done:` is kept verbatim: it is their word for it, and a
          ;; second spelling here is another thing that can drift.
          ((= 1 (length one))
           (let ((fact (first one)))
             (if (eq :task (%notice-kind text))
                 (format nil "Agent ~a · ~@[~a · ~]~a"
                         (short-id (subseq fact 0 (or (position #\space fact) (length fact))))
                         (%notice-agent-task text)
                         fact)
                 ;; **THE NOUN IS HERE, AND NOWHERE ELSE.** A job's fact is the daemon's sentence;
                 ;; naming it is this function's business, because a CALLER that prefixed its own
                 ;; noun produced `Job 1 job and 1 subagent finished ended (…)` on the operator's
                 ;; screen for a coalesced row — the branch below.
                 (format nil "Job ~a" fact))))
          ;; **SEVERAL NOTICES IN ONE ROW, AND THEY ARE NOT ALL JOBS.** The daemon coalesces notices
          ;; that arrive together, so this branch sees a mixed row: measured on the operator's screen,
          ;; `2 jobs ended (j66, s-…-sub-…)` — a subagent called a job by a line that counted the two
          ;; openings in a row that had one of each. The count is of the OPENINGS, which are the
          ;; daemon's own words, so the sentence cannot be wrong about what settled.
          ;; **COMPLETE SENTENCES, BECAUSE NOTHING IS PREPENDED TO THEM ANY MORE.** The measured defect
          ;; was `Job 1 job and 1 subagent finished ended (…)`: one caller added a noun while another
          ;; added `ended` to a phrase that had already said `finished`. One writer, one sentence.
          (t (multiple-value-bind (j k) (%notice-counts text)
               (let ((ids (format nil "(~{~a~^, ~})"
                                  (mapcar (lambda (f) (subseq f 0 (or (position #\space f)
                                                                      (length f))))
                                          one))))
                 (cond ((and (plusp j) (plusp k))
                        (format nil "~d job~:p and ~d subagent~:p finished ~a" j k ids))
                       ((plusp k) (format nil "~d subagent~:p finished ~a" k ids))
                       (t (format nil "~d job~:p ended ~a" j ids)))))))))

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

