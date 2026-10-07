;;;; submit — submitting the line, and switching session by name or id
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun %submit-line (head)
  "Enter on the composer: a slash command, or a prompt. Queued as a follow-up
user item by the daemon when a turn runs — never rejected (§13.2).

Paste markers are EXPANDED here, at the last moment before the text leaves: the
composer shows `[⋮ pasted 312 lines ⋮]` and the daemon receives the 312 lines.
History keeps what was typed, so an Up recalls the marker and not a wall of
text — which is what makes the ledger safe to forget about."
  (let* ((typed (composer-buffer (head-composer head)))
         (line (expand-pastes typed))
         (decision (%open-decision head)))
    ;; a blank Enter is not an entry: the reference never reaches its `take` on
    ;; one (editor.rs:319-325), and this head pushed BEFORE the empty check, so
    ;; every stray Enter put a blank line in the history to walk past
    (unless (zerop (length (string-trim " " typed)))
      (composer-push-history (head-composer head) typed))
    (%undo-push (head-composer head))
    (setf (composer-buffer (head-composer head)) ""
          (composer-cursor (head-composer head)) 0)
    ;; the ledger belongs to the line that is leaving: it is cleared HERE, as the
    ;; reference clears it in `take` (editor.rs:596). It used to grow for the life
    ;; of the process, so every marker ever made was still a live substitution
    ;; rule against every later prompt.
    (setf *paste-ledger* nil
          *history-recalled* nil
          *redo-stack* nil
          (get 'composer :draft) nil)
    (cond
      ;; A SLASH LINE IS A COMMAND, whatever is on the screen — first, as the
      ;; reference's `submit` has it (app.rs:3961-3963). It used to sit under the
      ;; picker arm, so `/new a title` typed under the session picker the hint bar
      ;; itself advertises was read as the name of a session to switch to.
      ((and (plusp (length line)) (char= (char line 0) #\/))
       (%command head (subseq line 1)))
      ;; **AN `!` LINE IS THE OPERATOR'S OWN SHELL COMMAND** (daemon `7dca40f`,
      ;; protocol 28). The line is sent VERBATIM, bang included — the daemon strips the
      ;; `!` at the execution site, one rule, applied once. A line that is nothing but
      ;; the bang and whitespace is refused HERE, because a blank shell command is not
      ;; an act; the daemon re-checks for the same reason (a hand-written socket must
      ;; not be able to file an arbitrary sentence as the operator's).
      ;;
      ;; The result lands as two rows the head already draws: the operator's line as a
      ;; `User` row (speaker: Operator) and the output as a `ToolResult` named `bash`
      ;; with `origin: Operator` — the same folded, paged, sanitised treatment every
      ;; tool result gets. And `sudo` works, because the daemon runs it through the
      ;; same path `bash` takes, with the same `SUDO_ASKPASS` environment that raises
      ;; `SecretRequested` to a head.
      ((and (plusp (length line))
            (char= (char line 0) #\!)
            ;; **A `!send` LINE IS THE MANUAL ANSWER** (protocol 33) — one line to
            ;; the running command, on demand, no card needed.
            (> (length line) 5) (string= (subseq line 0 5) "!send"))
       (let ((rest (string-trim " " (subseq line 5))))
         (%send head (make-send-line rest))
         (say head (format nil "sent: ~s" rest))))
      ((and (plusp (length line))
            (char= (char line 0) #\!)
            ;; nothing but the bang and whitespace is refused — the daemon's own check
            (plusp (length (string-trim " !" line))))
       (%send head (make-operator-shell line)))
      ;; A PICKER IS UP: the line is a row's number or a name, as the card says
      (*pick-open* (pick-by-text head line))
      ((zerop (length line)))
      ;; THE SESSION PICKER IS UP: a bare `2` means the second session and cannot
      ;; sensibly mean anything else while the list is on the screen (app.rs:3963-3969)
      ((eq (head-mode head) :picker) (%pick-session head line))
      ;; A DECISION IS OPEN: the line is an answer to it, not a prompt.
      ;;
      ;; This is the bug the reference records in the operator's own words —
      ;; *"deny and tell doesnt work - there is no input for the 'tell' part"* —
      ;; and the shape of it was worse than a missing feature: the words were
      ;; REFUSED, so the line stayed in the composer and NOTHING was answered
      ;; while the operator looked at their own sentence, with the ask still open.
      (decision
       (multiple-value-bind (pick pick-kind why) (match-option decision line)
         (cond
           (pick
            ;; **THE TAG IS THE FIELD, so no arm here has to know one.** PICK-KIND is
            ;; the name of the thing PICK goes in, except for a question's two, which
            ;; name a `QuestionAnswer` field instead — and the two frames differ, so
            ;; the `case` is where that difference lives rather than in a flag.
            (case pick-kind
              (:option (%send head (make-answer (getf decision :req-id) pick nil nil)))
              (:glob (%send head (make-answer (getf decision :req-id) pick why nil)))
              (:note (%send head (make-answer (getf decision :req-id) pick nil why)))
              ;; **A QUESTION'S ANSWER IS `QuestionAnswer` AND NOTHING ELSE.** Its
              ;; three fields are `option`, `note`, `free`; `question-answer` is the
              ;; one place that knows them, and building `(list :option …)` here by
              ;; hand was a second spelling. `note` only travels WITH an option — the
              ;; daemon refuses `NoteQualifiesNothing` otherwise.
              (:index (%send head (make-answer-question
                                   (getf decision :req-id)
                                   (question-answer :option pick :note why))))
              (:free (%send head (make-answer-question
                                  (getf decision :req-id)
                                  (question-answer :free pick)))))
            (setf (head-decision-sel head) 0))
           ;; **IT NAMED NO OPTION, AND THERE ARE TWO KINDS OF THAT.**
           ;;
           ;; **A REFUSAL** (`pick-kind` is `:refused`): the line matched SEVERAL options, or it
           ;; named one and added words that option does not take. Nothing is answered, the words
           ;; are held, and the reason is said — an ambiguous `allow` must not be resolved by list
           ;; position, because that is an answer the operator did not give and this is a gate.
           ;;
           ;; **A DRAFT** (nothing matched at all): **an open ask owns Enter, typed line or not**,
           ;; and the marked row is the answer. The operator hit the other arrangement and it cost
           ;; him his words: *"if i have drafted prompt in the input and permission prompt menu
           ;; comes — enter doesnt work. i had to delete my message first."* Answering the marked
           ;; row is safe now because both halves of the reference's rule are here — `match-option`
           ;; has its prefix fallback with ambiguity refused by name, and the cursor is reset to
           ;; row one on every NEW ask (`head.lisp`), so it is never a row a previous ask left.
           ;;
           ;; The words are not disposable and are not sent: the ask settles, the line goes back
           ;; to the composer, and the next Enter sends it (letibot, app.rs:5778-5784).
           ((eq pick-kind :refused)
            (composer-insert (head-composer head) line)
            (say head (or why "that names no option here — the ask is still open")))
           (t (let* ((row (head-decision-sel head))
                     (rows (decision-options decision))
                     ;; WHAT was answered, named BEFORE the answer resets the cursor
                     (what (or (getf (nth row rows) :option-id)
                               (getf (nth row rows) :label)
                               (format nil "row ~d" (1+ row)))))
                (%answer-decision head row)
                (composer-insert (head-composer head) line)
                ;; **The `why` is NOT repeated here**, and that is not tidiness: it ends
                ;; *"— the ask is still open"*, which the answer has just made false. A
                ;; sentence that contradicts what the line above it did is worse than no
                ;; sentence, and the reason still travels on the refusal arm that needs it.
                (say head (format nil "answered `~a` — your line is held" what)))))))
      (t (%prompt head line)))
    (setf (head-dirty head) t)))

(defun %pick-session (head typed)
  "What the operator TYPED while the session picker was up, at enter — the
reference's `pick` (app.rs:4068-4109): the row's number, or enough of an id to be
unique, or a word in a title.

An ambiguous prefix is REFUSED WITH THE COUNT rather than resolved to the first
match. Switching to the wrong session is not a keystroke you can take back — the
prompt you type next lands there."
  (let* ((typed (string-trim " " typed)))
    (cond
      ((zerop (length typed)) (setf (head-mode head) :normal (head-dirty head) t))
      (t (multiple-value-bind (id why) (%resolve-session head typed)
           (cond (id (%switch-to head id))
                 (why (say head why))
                 (t (setf (head-mode head) :normal (head-dirty head) t))))))))

(defun %resolve-session (head typed)
  "TYPED as a session: `(values ID WHY)`, ID NIL when it names none.

**The picker's own resolution, which `/switch` shares** — the reference's `pick`
(`app.rs:4806-4855`) is called from both its `/switch` arm (`:5186`) and its
picker's Enter, so the two cannot answer one line differently. Three spellings, in
this order: the ROW NUMBER on the left of the list, enough of an ID to be unique, or
a word in a TITLE.

An ambiguous match is REFUSED WITH THE COUNT rather than resolved to the first:
switching to the wrong session is not a keystroke you can take back, because the
prompt you type next lands there.

With no list at all — a head that has not asked, or a daemon that has not answered —
the text goes to the daemon as an id, which is what `/switch` did for everything and
is still right for the one case it can serve."
  (let* ((rows (picker-sessions (head-session head)))
         (typed (string-trim " " (or typed "")))
         (n (ignore-errors (parse-integer typed))))
    (cond
      ((zerop (length typed)) (values nil nil))
      ((null rows) (values typed nil))
      ((and n (<= 1 n (length rows)))
       (values (getf (nth (1- n) rows) :session-id) nil))
      (t (let ((hits (remove-if-not
                      (lambda (b)
                        (or (uiop:string-prefix-p typed (or (getf b :session-id) ""))
                            (let ((title (or (getf b :title) "")))
                              (and (plusp (length title))
                                   (search (string-downcase typed)
                                           (string-downcase title))))))
                      rows)))
           (case (length hits)
             (1 (values (getf (first hits) :session-id) nil))
             (0 (values nil (format nil "no session matches ~s — `/s` lists them" typed)))
             (t (values nil (format nil "~d sessions match ~s; type the number on the left instead"
                                    (length hits) typed)))))))))

(defun %switch-to (head id)
  "Go to session ID — the one place that knows what \"go\" means, the reference's
`switch_to` (`app.rs:5098-5150`).

**Two frames when the row is on disk and not in this daemon.** A stored session has to
be BROUGHT IN before it can be switched to, and that is `ResumeSession` — the same
first step `/resume` takes — with the head sending the switch itself when the daemon
answers. This sent `switch` unconditionally, so picking an `on disk` row from the
picker asked the daemon for a session it had never opened: the picker listed it, the
label said it was there, and choosing it did nothing.

**And `already here` is said rather than silently ignored.** Picking the session you
are in is not an error and is not nothing: without the sentence the screen looks
identical either way, and the operator presses Enter again."
  (cond
    ((string= id (session-session-id (head-session head)))
     (setf (head-mode head) :normal)
     (say head "already here"))
    ((let ((b (find id (picker-sessions (head-session head))
                    :key (lambda (s) (getf s :session-id)) :test #'string=)))
       (and b (not (getf b :live))))
     ;; the resume's answer is a `Sessions` reply carrying `created`, and
     ;; `want-new` is what tells the head to FOLLOW it — one flag for one
     ;; behaviour, as the reference reuses its own
     (setf (head-want-new head) t
           (head-mode head) :normal)
     (say head (format nil "resuming ~a from the store…" id))
     (%send head (make-resume-session id)))
    (t (%send head (make-switch id 0))
       (setf (head-mode head) :normal)))
  (setf (head-dirty head) t))

