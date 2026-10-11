;;;; dispatch — running a verb, and the notes listing
;;;;
;;;; Split out of `commands.lisp`, which was one 1784-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defun %command (head line)
  "One verb per slash command; anything the head does not handle goes to the
daemon as the line the operator typed, without the leading slash (protocol.rs
on ClientFrame::Slash)."
  (let* ((space (position #\space line))
         (verb (string-downcase (if space (subseq line 0 space) line)))
         (rest (if space (string-trim " " (subseq line (1+ space))) "")))
    (cond
      ((string= verb "cells") (%cells head rest))
      ((string= verb "new") (%send head (make-new-session rest "")))
      ((member verb '("sessions" "s") :test #'string=)
       ;; `/s` is the reference's own short form (app.rs:4443) and was not here,
       ;; so it fell to the catch-all and travelled to the daemon as a slash line
       ;; — a round trip that answers nothing, for the verb the picker is on.
       (%send head (make-list-sessions))
       (%open-pane head :picker))
      ((string= verb "switch")
       ;; **the same resolution the picker's Enter uses** — a row number, an id
       ;; prefix or a title substring (`%resolve-session`, the reference's `pick`).
       ;; This sent the text to the daemon as an id, so `/switch 3` and
       ;; `/switch parity` were both a round trip that answered nothing, while the
       ;; picker two keys away accepted exactly those.
       (multiple-value-bind (id why) (%resolve-session head rest)
         (cond (id (%switch-to head id))
               (why (say head why))
               (t (say head "usage: /switch NUMBER, ID or part of a title")))))
      ((string= verb "rename")
       ;; **not attached is its own sentence.** `(session-session-id …)` is `""` before
       ;; the first `Hello`, and this sent `rename_session` for the empty id — a frame
       ;; about a session that does not exist, answered by nothing. The reference says
       ;; so and stops (`app.rs:5195-5198`), and does the same for an empty NAME, which
       ;; it still sends because that is how a name is CLEARED (its own message says
       ;; so). Both halves, and they are different halves.
       (let ((id (session-session-id (head-session head))))
         (if (zerop (length id))
             (say head "not attached to a session yet")
             (progn
               (when (zerop (length rest))
                 (say head "/rename NAME — or /rename with nothing clears the name"))
               (%send head (make-rename-session id rest))))))
      ;; the reference's short forms, for the fingers that learnt them there
      ((member verb '("help" "h" "?") :test #'string=)
       (%toggle-pane head :help))
      ((member verb '("status" "stats") :test #'string=)
       (%toggle-pane head :status))
      ((string= verb "lisp")
       ;; **THE EVAL SURFACE ON THE GLASS.** `/lisp` alone toggles the pane like every other pane
       ;; verb here; `/lisp FORM` evaluates FORM and shows the answer IN the pane, opening it when
       ;; it is closed — so the verb is usable by somebody who would rather type one line than
       ;; open a screen, and there is still exactly ONE place the entries live.
       ;;
       ;; **NOTHING IS SAID ABOUT THE ANSWER HERE.** The entry is the answer, and it is drawn
       ;; where the reader is already looking; a note repeating the value would be a second
       ;; surface for one fact, which is the drift this tree names everywhere. The one sentence
       ;; this arm writes is the refusal to evaluate NOTHING (R29: a verb that does nothing says
       ;; so).
       (let ((form (string-trim " " rest)))
         (cond
           ((zerop (length form)) (%toggle-pane head :lisp))
           (t (unless (eq (head-mode head) :lisp) (%open-pane head :lisp))
              (unless (lisp-eval-entry head form)
                (say head "/lisp FORM — nothing to evaluate"))))))
      ;; R10's reader: what this head has warned about, and how to retire one.
      ;; `/dismiss` is the same action under the word a person types at a red block.
      ((member verb '("notes" "dismiss") :test #'string=)
       (%notes head verb rest))
      ((member verb '("think" "r") :test #'string=)
       (%flip-fold head :show-reasoning))
      ;; **THE PER-ROW WINDOW, moved off the chord onto the verb when the chord became the todos
      ;; pane.** `/t` used to be *unfold the long rows* — the wall, every tool row and a queued echo
      ;; at once — and that is now the `tools` row in `/config`, a setting rather than a verb: the
      ;; seam under a long row names a key that acts on THAT row, and the operator's report on the
      ;; wall was that a per-row seam cannot honestly name a key that opens every row. What `/t`
      ;; keeps is the one thing a seam can name: a window on ONE row, folded back by the same verb.
      ((string= verb "t")
       (%row-window head))
      ;; **R38: A SETTING WITH MORE THAN TWO VALUES IS CHOSEN, NOT CYCLED.**
      ;;
      ;; `/verbosity` used to cycle, and with R37's fourth rung the reader who wanted one of the
      ;; four had to press up to three times and watch the screen change twice to find out which
      ;; they were on. *A cycle moves the cost onto the person*: it makes them hold the list in
      ;; their head and discover the current value by changing it. The picker shows all four, marks
      ;; the current one, says what each MEANS, and takes one press.
      ;;
      ;; **A NAME still works and does the thing**, which is the grammar `/mode NAME` already has
      ;; here — and the card's own hint row says *or type a name or the number on the left*, so the
      ;; typed path and the ladder have to agree.
      ((member verb '("verbosity" "v") :test #'string=)
       (let ((name (string-trim " " rest))
             (rung nil))
         (cond
           ((zerop (length name)) (open-pick head :verbosity))
           ;; **A SWITCH=LEVEL is the chord's own spelling** (daemon `78177f3`):
           ;; `thinking=toggle`, `raw-calls=off`, `tools=open`. The switch names are
           ;; the preference keys this head already reads — `thinking` is
           ;; `:show-reasoning`, `raw-calls` is `:raw-calls`, `tools` is `:show-tools`
           ;; — and the ONE WRITER is the same function a chord calls, so a shortcut
           ;; and a verb cannot drift. `toggle` flips, `on`/`open` sets true,
           ;; `off`/`folded`/`closed` sets false.
           ((find #\= name :test #'char=)
            (multiple-value-bind (switch level word)
                (%parse-switch-level name)
              (if switch
                  (let ((note (%set-switch head switch level)))
                    (say head (format nil "verbosity ~a → ~a~@[~a~]"
                                    (string-downcase (symbol-name switch)) word note)))
                  (say head (format nil "`~a` is not a switch — the switches are ~{~a~^, ~}; a rung name, or SWITCH=LEVEL"
                                   name
                                   '("thinking" "tools" "raw-calls" "diff"))))))
           ;; **A WORD either head spells is read here** (`verbosity-for-word`), and it writes
           ;; THIS head's spelling back: letibot's name for R37's rung is `conversation` and
           ;; this head's is `reading`, so a reader who typed the other head's word gets the
           ;; rung rather than a refusal — and the file keeps one spelling.
           ((setf rung (verbosity-for-word name))
            (let ((was *verbosity*)
                  (note (%choose-verbosity head rung)))
              (say head (if (eq was *verbosity*)
                            (format nil "verbosity is already ~a~@[~a~]"
                                    (verbosity-name) note)
                            (format nil "verbosity → ~a — the whole transcript, including everything above this line~@[~a~]"
                                    (verbosity-name) note)))))
           ;; **an unknown rung is a sentence, not a silence** — and it names the four, because a
           ;; reader who typed one cannot guess the others from a refusal
           (t (say head (format nil "`~a` is not a verbosity — the four are ~{~a~^, ~}; `/verbosity` with no argument opens the card"
                                name
                                (mapcar #'verbosity-name +verbosity-ladder+)))))))
      ((member verb '("config" "settings") :test #'string=)
       ;; Ask, and open the pane. The REPLY does not open it (a head asks for
       ;; settings on attach now, and a reply that opened the pane would pop
       ;; `/config` at every attach), so the command owns both halves.
       (%toggle-pane head :config (lambda () (%send head (make-settings)))))
      ;; **THE API-KEY CARD.** The verb takes the PROVIDER and nothing else: the key itself
      ;; is typed into a masked field, because argv is the transcript and the transcript goes to
      ;; the model. See `*key-draft*`.
      ((string= verb "key")
       (%key-draft-open head rest))
      ((string= verb "mode")
       (if (plusp (length rest))
           ;; a NAME goes straight to `mode-action` — `allow-all` asks first,
           ;; whichever way it was chosen
           (mode-action head rest)
           ;; with no name, OPEN THE PICKER rather than printing a list to copy a
           ;; name out of. The reference made the same change: *"for starters i
           ;; want it to be usual menu, like /mode"* — the wall of text was the
           ;; least visible part of the thing anybody types it for.
           (open-pick head :mode)))
      ((or (string= verb "models") (string= verb "model"))
       ;; **A MODEL CHANGE MID-TURN TAKES, AND THE HEAD SAYS SO** (`12ade5e` — the head's half of
       ;; that item in `TODO.md`'s 48-commit list): the daemon reads a mid-turn `/models` at its next
       ;; round rather than refusing it, so the sentence is *the turn continues, and the next round
       ;; is the new model*. A reader who changed it and saw only `sent:` would not know whether they
       ;; had interrupted anything. Said only while a turn is actually running — between turns the
       ;; change is immediate and there is nothing to explain.
       ;;
       ;; `turn-busy-p` and not the state name, for the reason that predicate exists: the name reads
       ;; `finished` for the whole of a tool call, and a command issued then is just as mid-turn.
       (if (plusp (length rest))
           (progn
             (%send-slash head (format nil "models ~a" rest))
             (when (turn-busy-p (session-turn (head-session head)))
               (say head (format nil "the model changes at the next round — this turn continues on ~a"
                                 (or (getf (session-turn (head-session head)) :model)
                                     "the model it started with")))))
           (open-pick head :model)))
      ((string= verb "standing")
       ;; **ASK AND OPEN.** The ask belongs to the pane's OPEN — measured in the reference, where
       ;; the pane queues the read itself (`app/standing.rs:133`) — so the pane appears at the
       ;; keypress and fills when the mailbox answers. The first cut of this arm only ASKED, which is
       ;; why `/standing` left the screen on the conversation: the verb existed to satisfy the
       ;; constructor-needs-a-caller invariant, and the OPEN was never wired.
       (%toggle-pane head :standing (lambda () (%send head (make-list-notes))))
       (say head "asking the daemon which notes are standing…")
       t)
      ((string= verb "queue")
       ;; **THE ASK IS STEP ONE'S OTHER HALF** (see the merge queue's box in `TODO.md`): the queue is
       ;; daemon-level and no snapshot carries it, so a head that does not ask draws nothing. This
       ;; verb is what makes the frame SENT — and the suite's own invariant is why the constructor
       ;; could not land before it.
       ;; ASK **and** open, the jobs pane's own shape: a pane that appears only when the answer
       ;; lands is a pane the reader stared at an empty screen for.
       (%toggle-pane head :queue (lambda () (%send head (make-list-merge-queue))))
       (say head "asking the daemon for the merge queue…")
       t)
      ((string= verb "jobs")
       ;; ASK, then open. The jobs pane drew `N out` from JobSettled events, which
       ;; a head that attached after the jobs started never saw — so the pane was
       ;; empty for exactly the case it exists for. `ListJobs` is answered at once
       ;; (protocol 21, deliberately not a Slash: those ride the command queue and
       ;; are answered between turns, so `/job` during a long turn arrived after
       ;; it had finished).
       (%toggle-pane head :jobs (lambda () (%send head (make-list-jobs)))))
      ((string= verb "subagents") (%open-pane head :subagents))
      ((string= verb "dashboards")
       ;; **OPENING IT STARTS THE COLLECTORS**, because a dashboard with no series is a frame of
       ;; dashes — and starting a sampler that is already running is a no-op, so the verb is
       ;; idempotent. `*dash-nav*` is cleared so the cursor is never left on a panel that a
       ;; re-registration has moved.
       ;;
       ;; **AND IT LOADS THE PROJECT'S FILES IF IT HAS NOT** — the startup load happened before
       ;; this head knew which workspace it is in, so a project's `.letibot/dashboards/` is read
       ;; the first time the pane is opened rather than never. `dash-file-load-needed-p` is the
       ;; guard, so this is one file read per attached workspace and not per keypress.
       (when (dash-file-load-needed-p head) (dash-load-file-panels head))
       ;; and the project's WATCHERS, by the same guard and for the same reason (R56)
       (when (dash-file-load-needed-p head) (dash-watcher-load head))
       (setf *dash-nav* (list :sel 0 :scroll 0 :open nil))
       (dash-start)
       (%open-pane head :dash))
      ((string= verb "dash-reload")
       ;; **THE OPERATOR'S OWN VERB, because the files are theirs to edit while the head runs.**
       ;; Writes are not watched for (that is a separate step): this reads now, and it says what
       ;; it found — including every file it could not understand, which is the only way a broken
       ;; file is visible without opening the pane.
       (multiple-value-bind (n errors) (dash-load-file-panels head)
         (multiple-value-bind (wn werrors) (dash-watcher-load head)
           (let ((all (append errors werrors)))
             (say head (if all
                           (format nil "~d panel~:p · ~d watcher~:p from a file · ~d broken: ~{~a~^, ~}"
                                   n wn (length all)
                                   (mapcar (lambda (e) (file-namestring (car e))) all))
                           (format nil "~d panel~:p · ~d watcher~:p from a file" n wn)))))))
      ((string= verb "todo")
       ;; **`/todo postpone N` / `/todo resume N` — the state the operator owns, over the same
       ;; numbers the pane prints on their rows.** The daemon's verb family is wider on its side
       ;; (`TEXT`, `done N`, `rm N`); this head's doors for those are the card, the space key and
       ;; the delete key, so what travels as a typed verb here is the pair that has no key —
       ;; which is the reference's own ruling for exactly this act.
       (todo-postpone-command head rest))
      ((string= verb "todos")
       ;; **`/todos add` opens the card without opening the pane** (R44): the verb is the
       ;; keystroke-saving spelling of the pane's own first row, and `add` is a word this verb
       ;; takes because it is the thing an operator reaches for. Anything else after `/todos` is
       ;; still ignored, as it always was.
       (if (string= (string-trim " " (or rest "")) "add")
           (%todo-draft-open head)
           (progn
             ;; Ask for the list AND open the pane. The session's plan is carried by
             ;; `todos_updated` events, so a head that attached after the model wrote
             ;; them has none — the bootstrap read is what makes the pane honest about
             ;; a plan written before this head existed.
             (%send head (make-list-todos))
             (%open-pane head :todos))))
      ((string= verb "peek")
       ;; One subagent's output without leaving this session: the daemon answers
       ;; with `Peeked`, and `%handle-frame` opens the pane from that. The screen
       ;; existed and was unreachable — nothing sent the frame that fills it.
       (if (plusp (length rest))
           (%send head (make-peek rest))
           (say head "usage: /peek SESSION-ID")))
      ((string= verb "resync")
       ;; Throw this head's state away and take a fresh snapshot. The frame was
       ;; written in T9 and never sent, so the only resync this head ever saw was
       ;; one the DAEMON initiated — which is the case that works and therefore
       ;; the case that proves nothing.
       (%send head (make-resync)))
      ((string= verb "resume")
       ;; Bring a session that is in the store but not in this daemon back to
       ;; life. The daemon answers on the same `Sessions` reply a `/new` produces,
       ;; so the picker's switch machinery is what lands it.
       (if (plusp (length rest))
           (%send head (make-resume-session rest))
           (say head "usage: /resume SESSION-ID")))
      ((string= verb "compact")
       (%send head (list :frame "compact_session"
                         :client-request-id (next-request-id)
                         :expected-seq (session-expected-seq (head-session head)))))
      ((string= verb "reseat")
       ;; `/reseat summarise` asks for the LOSSY kind by name and got the other
       ;; one, with no word either way: the argument was parsed off and dropped,
       ;; and the frame carried no `summarise` at all. Both branches say which one
       ;; ran, because the difference between them is the conversation
       ;; (app.rs:4590-4608). The lossless one is the default — the operator: *"id
       ;; say flip it - reset is loseless and reset summarize will be not"*.
       (let ((summarise (member rest '("summarise" "summarize") :test #'string-equal)))
         (%send head (list :frame "reseat_session"
                           :client-request-id (next-request-id)
                           :expected-seq (session-expected-seq (head-session head))
                           ;; :false, not NIL: the daemon's field is a plain bool
                           ;; with `#[serde(default)]`, and this encoder writes
                           ;; NIL as `null`, which is not a bool and would be
                           ;; refused by the parser rather than defaulted
                           :summarise (if summarise t :false)))
         (say head (if summarise
                       "re-seating: summarising, so the summary replaces the conversation…"
                       "re-seating: carrying the conversation across as it is. The next turn re-sends all of it once."))))
      ((string= verb "promote")
       ;; Move the running COMMAND to the background. The fact to guard is a
       ;; command running, and the daemon honours this inside bash's own wait
       ;; loop — so a call still executing is not a proxy for the thing being
       ;; promoted, it IS it. Between turns the daemon announces idle, so this
       ;; says what it can see rather than guessing.
       (let ((call (find-if (lambda (c) (string= (getf (getf c :state) :state) "running"))
                            (getf (session-turn (head-session head)) :calls))))
         (if call
             (progn
               (%send head (list :frame "promote"
                                 :client-request-id (next-request-id)
                                 :expected-seq (session-expected-seq (head-session head))))
               (say head (format nil "moving ~a to the background" (getf call :name))))
             ;; TWO different silences, and saying the same thing for both sends
             ;; the operator looking for a command that was never started
             (say head (if (and (session-turn (head-session head))
                                (string= (turn-state-name (session-turn (head-session head)))
                                         "running"))
                           "the model is still working — no command running to move yet"
                           "nothing is running to move to the background")))))
      ((member verb '("interrupt" "i") :test #'string=)
       ;; `/i`, the reference's short form (app.rs:4567) — it fell to the daemon
       ;; too, which is a round trip for the one verb whose point is to be fast
       (%interrupt head "interrupted from the head"))
      ((string= verb "run") (%run-command head rest))
      ;; R11's locator: the oracle's brief and its reply, by the adjudication's own id
      ((string= verb "diagnostic") (%diagnostic-command head rest))
      ((member verb '("quit" "q") :test #'string=) (setf (head-running head) nil))
      ;; **R24 part two, THE OPERATOR'S OWN SHAPE: `/NAME blabla`.** LAST before the fallthrough,
      ;; and that placement is the rule rather than tidiness: **this head's own verbs win.**
      ;; A door row must not be a way to take `/quit` or `/help` away from the operator — a
      ;; daemon that publishes a tool called `quit` would otherwise retire the head's own word
      ;; for leaving — and nothing is lost, because `/run quit …` still names the door
      ;; explicitly. Guarded on the name being IN THE DOOR, so this head answers to the daemon's
      ;; names and to nothing else and any other verb still travels.
      ((%op-call-verb head verb rest))
      ;; unknown verbs travel; the daemon acts and announces on the log
      (t (%send head (list :frame "slash"
                           :client-request-id (next-request-id)
                           :expected-seq (session-expected-seq (head-session head))
                           :line line))))))

(defun %notes (head verb rest)
  "`/notes` and `/dismiss`: what this head has warned about, and how to retire one.

R10's reader. Three verbs in one because they are one subject: nothing listed the
warnings, nothing retired one, and a reader who has just retired a wall needs a way
back if they were wrong. `/dismiss` is the same action under the word a person types
at a red block, and with no argument it retires every one — the reference's grammar
(app.rs:5772-5839), kept so the two heads take the same sentence.

**Retired is not deleted**, and every message says so: the warning is off the screen,
counted on `/status`, and listed by `/notes` with its whole text. A verb that dropped
the sentence would be a head whose warnings cannot be trusted to be complete."
  (let* ((s (head-session head))
         ;; `/dismiss` with nothing after it means `all` (app.rs:5775-5779)
         (arg (if (and (string-equal verb "dismiss") (string= rest "")) "all" rest)))
    ;; **THE FILE IS RE-READ HERE, and it is the moment that matters.** The notes file is
    ;; one file for every head on the box (see `save-retired-keys`), and this head read it
    ;; once — at startup. Without this, a head that has been up for hours shows a note
    ;; another head retired as live on the screen, which is the operator's own report
    ;; (`"i dismissed letibot notes but they stay"`) read from the other side.
    ;;
    ;; The LISTING and the ACT are the two places the operator is looking, so they are the
    ;; two places that re-read — not a timer. Nothing here needs to notice a change nobody
    ;; asked about, and a read on a keypress is free while a poll loop is a poll loop.
    ;;
    ;; **The re-read never writes.** It cannot: it only sets the session's set from what the
    ;; file says, and a save is a separate call from the two verbs that mean to change it.
    ;; A file this head cannot read leaves the set exactly as it is — see
    ;; `read-retired-keys`, whose second value is the whole of that rule.
    (let ((on-disk (read-retired-keys)))
      (when on-disk
        (setf (session-retired s) (copy-list on-disk))
        (leticl::%reflag-warning-rows s)))
    (cond
      ;; nothing after the verb: SHOW them
      ((string= arg "")
       (open-notes-listing s)
       (setf (head-mode head) :slash
             (head-dirty head) t))
      ((member arg '("restore" "back" "undismiss") :test #'string=)
       (let ((back (restore-warnings s))
             ;; **A RESTORE IS CONTRARY EVIDENCE, so it REPLACES and does not union.**
             ;; `restore-warnings` empties this head's set and this writes the emptied
             ;; list over the file's — otherwise the union would put every one of them
             ;; back on the next re-read, which is a restore that does not restore.
             (miss (save-retired-keys (session-retired s) :replace t)))
         (%refresh-notes-listing head)
         (say head (format nil "~a~@[ · ~a~]"
                           (if (zerop back)
                               "nothing was retired, so nothing came back"
                               (format nil "~d retired warning~a back on the screen — the ~
                                            log was never the thing they were hidden from"
                                       back (if (= back 1) "" "s")))
                           miss))))
      (t
       ;; `dismiss` is the word itself: `/notes dismiss` and `/dismiss all` land here
       (let* ((tail (if (and (>= (length arg) 7) (string-equal arg "dismiss" :end1 7))
                        (string-trim " " (subseq arg 7))
                        arg)))
         (cond
           ((or (string= tail "") (string= tail "all"))
            (let ((hidden (retire-all-warnings s))
                  (miss (persist-retired head)))
              (%refresh-notes-listing head)
              ;; **THE EMPTY PRESS ANSWERS** (R22's one amendment, agreed in both trees).
              ;; A chord the hint bar names unconditionally has to answer
              ;; unconditionally — `ctrl-t` can be silent with nothing to open because
              ;; its seam names it only on the one row it can open, and a hint bar
              ;; cannot be conditional. So *nothing to retire* is ONE sentence, shared
              ;; by `/notes dismiss all` and by `ctrl-n`, rather than a second one for
              ;; the chord: the path is shared, and so is what it says.
              ;;
              ;; The write's own failure is still said in either case. A file that
              ;; could not be written is the one part of this a reader cannot deduce
              ;; from the screen — the dismissal holds in this process and not on disk
              ;; — and it is no less true when there was nothing new to retire.
              (say head (if (zerop hidden)
                            (format nil "nothing to retire~@[ · ~a~]" miss)
                            (format nil "retired ~d warning~a — off the screen, ~
                                         still counted on /status, and /notes shows ~
                                         them~@[ · ~a~]"
                                    hidden (if (= hidden 1) "" "s") miss)))))
           ((every #'digit-char-p tail)
            (let* ((n (parse-integer tail))
                   (ws (warning-order s)))
              (if (and (>= n 1) (<= n (length ws)))
                  (progn
                    (retire-warning s (nth (1- n) ws))
                    (let ((miss (persist-retired head)))
                      (%refresh-notes-listing head)
                      (say head (format nil "retired warning ~d — off the screen, still ~
                                             counted on /status, and /notes shows it~@[ · ~a~]"
                                        n miss))))
                  (say head (format nil "there is no warning ~d — /notes lists the ~d ~
                                         this head holds" n (length ws))))))
           (t
            (say head (format nil "`~a` is not a number — /notes lists them, and ~
                                   `/notes dismiss N` retires the Nth" tail)))))))))

