;;;; commands.lisp — the command surface: the registry, the senders, and /cells.
;;;;
;;;; `*slash-commands*` is the HEAD's OWN vocabulary: the canonical spelling of every verb
;;;; `%command` acts on, and nothing else. Tab and the live completion row walk it joined with
;;;; the verbs the DAEMON publishes (`+daemon-verbs-key+`), because the namespace has two
;;;; owners and neither may enumerate the other's half.
;;;;
;;;; **This file used to claim the three could not drift.** It said `*slash-commands*` was
;;;; "the one list the help screen, tab completion and the dispatcher all read" — and the
;;;; dispatcher read nothing: it is a `cond` of string literals, and the help screen draws
;;;; `*help-rows*`. Measured 2026-09-23 (`scripts/slash-audit`), **twelve verbs this head acts
;;;; on had no row and one row named a verb this head does not act on** — a registry read as a
;;;; dispatcher because it was the only list of verbs anybody had, and nearly right, which is
;;;; why nothing said so. `the-registry-and-the-dispatcher-cannot-drift` is what keeps it
;;;; honest now, and it reads the dispatcher rather than trusting this sentence.
;;;;
;;;; The frames here are the ones a person or a model asks for by name; anything this file does
;;;; not know travels to the daemon as a `slash` frame.

(in-package #:leticl)

;;; /cells delimiters — copied from app.rs:868 so a leticl screen folds out of
;;; a Rust transcript and vice versa. They live beside `%cells`, the command
;;; that writes them, so the pair cannot drift; `%fold-cells` (cards.lisp) is
;;; the reader that folds them back out, and it loads after this file.
(defparameter *cells-open* (format nil "⟦screen "))

(defparameter *cells-mark-end* "⟧")

(defparameter *cells-close* "⟦end screen⟧")


(defparameter *slash-commands*
  '(;; the conversation
    ("new" . "TITLE — start a fresh session")
    ("sessions" . "the session picker")
    ("switch" . "ID — go to another session")
    ("rename" . "NAME — name the session you are in")
    ("help" . "the key and command reference")
    ("status" . "telemetry, full screen")
    ("stats" . "this head's counters — the same as /status")
    ("notes" . "what this head has warned about — and retire one")
    ("dismiss" . "retire every warning on the screen (/notes has the rest)")
    ;; the folds
    ;; **`/t` HAS A ROW and is not an alias, because it is now an ADVERTISED key**: the queued
    ;; echo's seam reads *"/t opens it"* (R33), so a reader types it. With no row, Tab on `/t`
    ;; would complete to `/think` — a different fold — which is how an alias becomes a trap the
    ;; moment something points at it. `/tools` is the daemon's listing verb and is not this
    ;; head's to describe.
    ;; **`/t` is the ONLY spelling of the conversation-wide unfold** (R40): `ctrl-t` opens a
    ;; window on one row, `/t` unfolds every tool row and a queued echo. The row used to say
    ;; *ctrl-t is the same fold*, which stopped being true when the chord was narrowed.
    ("t" . "unfold every long row: tool output, and a queued echo (ctrl-t opens one row's window)")
    ("think" . "fold or unfold the model's reasoning")
    ("verbosity" . "cycle the event-stream detail")
    ;; the surfaces
    ("config" . "every setting, as the daemon reports it")
    ("settings" . "every setting — the same as /config")
    ("mode" . "the mode picker — or /mode NAME to type it")
    ("models" . "which model answers: the picker, or /models PROVIDER/MODEL")
    ("model" . "which model answers — the same as /models")
    ("jobs" . "the background-jobs pane")
    ("subagents" . "the subagent tree")
    ("todos" . "the model's plan, and the repo's TODO.md — ask, then open it")
    ("peek" . "SESSION-ID — read a subagent's output without leaving this session")
    ;; the session's own machinery
    ("cells" . "MESSAGE — send it with a copy of this screen")
    ("resync" . "throw this head's state away and take a fresh snapshot")
    ("resume" . "SESSION-ID — bring a stored session back to life")
    ("compact" . "summarise this session and fork it")
    ("reseat" . "rebuild the prompt from the tools seated now, carrying the conversation")
    ("reseat summarise" . "…and summarise the conversation instead of carrying it")
    ("promote" . "move the RUNNING COMMAND to the background (ctrl-o)")
    ("interrupt" . "stop the running turn")
    ;; the door and the oracle
    ("run" . "NAME [JSON] — run a tool the daemon names, on this machine, as your act (or alt+r to type the JSON)")
    ("diagnostic" . "ID — the oracle's brief and its reply for one adjudication, as the gate saw and heard them")
    ("quit" . "leave the head"))
  "The HEAD's own verbs: the canonical spelling of each, with the hint the completion row draws.

**A row is a claim that `%command` acts on that name**, and
`the-registry-and-the-dispatcher-cannot-drift` reads the dispatcher's own source and fails when
the claim is false in either direction. That is the mechanism, because deriving one list from
the other would mean rebuilding the dispatcher as a table, and a `cond` of literals cannot be
read back at run time.

**A spelling of an action already listed is not a row** — it is in `+command-aliases+`, the
same division letibot's `HEAD_COMMAND_ALIASES` makes: offering both spellings doubles the list
to teach the same actions, and the dispatcher keeps taking them either way.

**A verb the DAEMON answers is not a row here either.** `/tools` was one, and it went because
its hint said *fold or unfold tool output* — which is `/t`, the head's own fold — while the head
has no arm for `/tools` at all and the daemon does. Two behaviours under one word, with this
table describing the wrong one, is exactly what a copy of the other half's list produces;
`/tools` comes back from `+daemon-verbs-key+`, with the daemon's meaning.")

(defparameter +command-aliases+
  '("?" "h" "i" "q" "r" "s" "v")
  "Spellings `%command` takes and the table does NOT advertise.

**Declared once, and the drift test subtracts them**, because otherwise *a verb with no row* and
*a shortcut of one* are the same measurement, and every alias would have to be listed to keep
the test quiet — which doubles the table to teach the same actions and is the opposite of the
point. A spelling earns a row when a person could reasonably reach for it first (`settings`,
`stats`, `model` all have one); a single letter never does.

**A name here still has to be a verb the dispatcher acts on**, or a dead name could hide in this
list: the drift test checks both directions, including this one.")

(defun %verb-spelling (name)
  "NAME as a SLASH VERB is typed: hyphens, not underscores (R34).

**The one transform, and it is textual.** The daemon's tool names are underscored because they
are the tools' own names (`some_tool`); a slash verb here is one word and none of the others
needs the shift key, so the door's are spelled with hyphens when they are DISPLAYED and
COMPLETED. `read` and any other name without an underscore come back unchanged, which is what
makes this a spelling rule and not a vocabulary: it holds no list of tools and knows nothing
about any of them."
  (substitute #\- #\_ name))

(defun %slash-completions (head)
  "What a `/` may complete to: THIS HEAD's rows joined with the DAEMON's published verbs.

The union is the whole design. **Neither half enumerates the other's**, and there is no third
list: the head's rows come from `*slash-commands*` (tied to the dispatcher by a test), the
daemon's come off its settings row, and a name in both is offered ONCE with the head's hint —
`/jobs` is the live case, where the head opens the pane and the daemon reads a job's output.

**A door verb is offered HYPHENATED** (`%verb-spelling`, R34), and that is the name a person
types and completes. The underscore form is still ACCEPTED — `%door-name` resolves both — so the
row and the key agree about what to show while neither tells the operator they are wrong.

**An absent row means no daemon verbs**: an older daemon has said nothing about its half, and a
head that guessed would offer names it cannot check. It offers its own and stays quiet, which is
`head-run-tools`' rule for a missing list."
  (let* ((own *slash-commands*)
         (own-names (mapcar (lambda (row) (if (consp row) (car row) row)) own))
         (settings (head-settings head))
         (fresh (lambda (n) (not (member n own-names :test #'string=))))
         ;; **THE DOOR'S OWN VERBS — THE TOOLS** (R34). These are slash verbs a person types
         ;; (`/some-tool blabla`), so they belong on the key as much as any verb does, and they
         ;; are offered HYPHENATED because that is the spelling the key takes.
         (tools (remove-if-not fresh
                               (mapcar #'%verb-spelling (head-run-tools settings))))
         ;; and the verbs the daemon answers, which are not this head's to enumerate
         (verbs (remove-if (lambda (n) (or (member n own-names :test #'string=)
                                           (member n tools :test #'string=)))
                           (mapcar #'%verb-spelling (head-daemon-verbs settings)))))
    (append (mapcar (lambda (row) (if (consp row) row (cons row ""))) own)
            ;; a door tool's hint is the field a bare line goes into, from the same row the
            ;; arguments come from — so the live row teaches the short form and not just the name
            (loop for n in tools
                  for field = (getf (cdr (assoc n (head-run-descriptors settings)
                                                :test #'string=)) :field)
                  collect (cons n (if (and field (plusp (length field)))
                                      (format nil "LINE → ~a — run it as your act" field)
                                      "run it as your act, in JSON")))
            (mapcar (lambda (n) (cons n "")) verbs))))

(defun %prompt (head text)
  (push text (head-queued head))
  (%send head (make-prompt (session-expected-seq (head-session head)) text)))

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
      ;; R10's reader: what this head has warned about, and how to retire one.
      ;; `/dismiss` is the same action under the word a person types at a red block.
      ((member verb '("notes" "dismiss") :test #'string=)
       (%notes head verb rest))
      ((member verb '("think" "r") :test #'string=)
       (%flip-fold head :show-reasoning))
      ;; **`/t` IS THE *UNFOLD THE LONG ROWS* VERB, and that is now more than tool output.**
      ;; It folds the tool rows AND opens a queued echo (R33) — one key for one idea: the echo
      ;; is drawn as one elided headline whose seam reads *"/t opens it"*, and a second fold
      ;; chord for a second kind of row would be a second thing to learn. The operator's words
      ;; were *"expandable the usual way"*, so the seam names the key they already have.
      ;; letibot ruled the same (`app.rs:6194-6203`).
      ;;
      ;; `/tools` is the DAEMON's listing verb and NOT a spelling of this fold: the reference
      ;; moved it off the fold (*"i think i want it to show me currently seated tools"*), and
      ;; the listing comes back on the session log. This head has no arm for it, so it travels.
      ((string= verb "t")
       (%flip-fold head :show-tools))
      ((member verb '("verbosity" "v") :test #'string=)
       (setf *verbosity* (next-verbosity *verbosity*))
       (say head (format nil "verbosity ~(~a~) — ~d events filtered so far"
                         *verbosity* *filtered-total*)))
      ((member verb '("config" "settings") :test #'string=)
       ;; Ask, and open the pane. The REPLY does not open it (a head asks for
       ;; settings on attach now, and a reply that opened the pane would pop
       ;; `/config` at every attach), so the command owns both halves.
       (%toggle-pane head :config (lambda () (%send head (make-settings)))))
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
       (if (plusp (length rest))
           (%send-slash head (format nil "models ~a" rest))
           (open-pick head :model)))
      ((string= verb "jobs")
       ;; ASK, then open. The jobs pane drew `N out` from JobSettled events, which
       ;; a head that attached after the jobs started never saw — so the pane was
       ;; empty for exactly the case it exists for. `ListJobs` is answered at once
       ;; (protocol 21, deliberately not a Slash: those ride the command queue and
       ;; are answered between turns, so `/job` during a long turn arrived after
       ;; it had finished).
       (%toggle-pane head :jobs (lambda () (%send head (make-list-jobs)))))
      ((string= verb "subagents") (%open-pane head :subagents))
      ((string= verb "todos")
       ;; Ask for the list AND open the pane. The session's plan is carried by
       ;; `todos_updated` events, so a head that attached after the model wrote
       ;; them has none — the bootstrap read is what makes the pane honest about
       ;; a plan written before this head existed.
       (%send head (make-list-todos))
       (%open-pane head :todos))
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

(defvar *op-call-draft* nil
  "The operator-call composer: a plist `:name NAME`, or NIL when it is closed.

NAME is the tool this head is about to ask about, or NIL when the operator still has to
name one — which is the only difference between a door with one name and a door with
several, and it is DRAWN rather than guessed.

**A defvar and not a head slot**, for the reason every other piece of live state here is:
a struct layout change is a restart, and this has to be reachable from a push. Bound by
`with-replay-globals` all the same — not because a replay ever opens it, but because a
render reads it and a replay DOES render: a draft left open by one test would put this
card into the next replay's golden.")

(defun op-call-draft-open-p () (and *op-call-draft* t))

(defun %op-call-draft-open (head)
  "Open the operator-call composer — the `alt+r` chord, and `/run` with nothing after it.

**The tool is PREFILLED when the door has exactly one name**, so the common case is *type
the arguments and press enter* rather than *type the name and the arguments*. With several
names the composer is left empty and the card draws them, because guessing which door the
operator meant is the same failure as guessing the list.

**What was in the composer is the draft's now.** A half-typed prompt left under a card
whose Enter sends the line is the shape that costs somebody a message, and the card says
so before anything is typed.

**A picker is closed.** One field, one owner: a mode or model card left up behind this
would draw two cards and take the arrows."
  (let* ((door (head-run-tools (head-settings head)))
         (name (and door (null (cdr door)) (car door)))
         (seed (if name (format nil "~a " name) "")))
    (cond
      ((null door)
       (say head "this daemon offers no operator-call door — it has published no tool list, so there is nothing to run")
       nil)
      (t
       (setf *op-call-draft* (list :name name)
             *pick-open* nil
             (composer-buffer (head-composer head)) seed
             (composer-cursor (head-composer head)) (length seed)
             (head-dirty head) t)
       (say head (if name
                     (format nil "asking the daemon to admit `~a` as your act — one of ~{~a~^, ~}; type its arguments as JSON and press enter, and nothing runs until it says the call was admitted"
                             name door)
                     (format nil "type `NAME {…json…}` and press enter — the daemon admits one of ~{~a~^, ~} as your act, and nothing runs until it says so"
                             door)))
       t))))

(defun %op-call-draft-close (head)
  "Take the draft and its field down. The ONE place the card's state is cleared."
  (setf *op-call-draft* nil
        (composer-buffer (head-composer head)) ""
        (composer-cursor (head-composer head)) 0
        (head-dirty head) t))

(defun %op-call-draft-cancel (head)
  "Esc (or ctrl-c) in the operator-call composer: nothing was asked for.

**It says so**, which is the rule this head's chords keep: `esc` on a card the operator
opened is not a key that never arrived, and a composer that went away in silence is one
they press again to see whether the first press landed."
  (%op-call-draft-close head)
  (say head "nothing was asked for")
  t)

(defun %op-call-draft-submit (head line)
  "Enter in the operator-call composer. Two shapes, and the card says which one is live:
`{…json…}` when the card already named the tool, `NAME {…json…}` when it did not.

**The arguments are checked for BEING json and for nothing else** — the wire says the
field is json text, and a head that knew one tool takes `{\"url\": …}` would be holding
a copy of that tool's schema, which is the drift the daemon's own list exists to stop.

A refusal keeps the draft and says why, so the line can be fixed rather than retyped.

**Every ending here returns T, and that is load-bearing**: `%handle-key` treats a NIL from
this arm as *not mine* and passes the key down to `%normal-key`, whose Enter SUBMITS THE
LINE AS A PROMPT — so a refusal that returned NIL sent the operator's JSON to the model as
if they had typed it as a message. Measured: `the-composer-…`'s refusal assertion fails and
a `prompt` frame is on the wire. The key was acted on; it is claimed either way."
  (let* ((draft *op-call-draft*)
         (named (getf draft :name))
         ;; **A LEADING REPEAT OF THE NAME IS THE SAME AS ERASING IT.** The field is
         ;; prefilled `NAME ▌` when the door has one name, and an operator who leaves it
         ;; there and types the JSON after it means exactly what one who backspaces four
         ;; times means. Refusing the first spelling would be a head insisting on its own
         ;; prefill being undone before it would read the line in front of it.
         (line (if (and named (eql 0 (search named line)))
                   (string-trim '(#\space #\tab) (subseq line (length named)))
                   line))
         (space (position #\space line))
         (name (or named
                   (and space (subseq line 0 space))
                   (and (plusp (length line)) line)))
         (args (cond (named line)
                     (space (string-trim '(#\space #\tab) (subseq line (1+ space))))
                     (t ""))))
         (cond
      ((null name)
       (say head (format nil "name the tool as well — `NAME {…json…}`, and the door accepts ~{~a~^, ~}"
                         (head-run-tools (head-settings head)))))
      ((and (plusp (length args))
            (handler-case (progn (json-decode args) nil) (error () t)))
       (say head (format nil "the arguments are the tool's own JSON — as `~a {\"…\": \"…\"}` — so `~a` was not asked for"
                         name (let ((l (length args)))
                                (if (> l 40) (concatenate 'string (subseq args 0 40) "…") args)))))
      (t
       ;; **the field is cleared either way.** A refusal from this head — a call it has
       ;; no runner for — is a sentence, not something to retype in the same field
       (let ((asked (%op-call-ask head name (if (plusp (length args)) args "{}"))))
         (%op-call-draft-close head)
         asked)))
    ;; claimed, whatever it said: see the docstring's third paragraph
    t))

(defun %op-call-draft-key (head key type)
  "The keys the operator-call composer owns: Enter asks, Esc and `ctrl-c` cancel.

**Everything else is the composer's**, so the JSON can be typed, edited, pasted and
undone with the keys the operator already has — the same split the picker's card keeps.

T only for a key it took, or the field would stop taking letters."
  (case type
    (:enter (%op-call-draft-submit head (expand-pastes (composer-buffer (head-composer head)))))
    (:esc (%op-call-draft-cancel head))
    (:ctrl (and (eql (getf key :ch) #\c) (%op-call-draft-cancel head)))
    ;; **`ctrl-d` is NOT the composer's here.** On an empty field it would leave the head
    ;; with an argument half typed; on a filled one it does nothing already, because the
    ;; quit is guarded on an empty composer. Falling through keeps both.
    (t nil)))

(defun %json-text-p (text)
  "Is TEXT the arguments as JSON? — by PARSING it, and by nothing else.

**The question is *is this already the wire's shape*, and the parser is the only thing that
answers it.** The JSON form's promise is that what goes on the wire IS json text, and a
brace test cannot keep that promise: `NAME {…` with its closing brace missing
starts with a brace and is not json, and a head that passed it through would have sent the
daemon an unchecked line while believing it had checked.

**What a brace test would NOT buy, said plainly because this is where the rule is a choice.**
The tempting justification for testing the character is *a person searching for a JSON snippet
types braces and a colon* — but such a search is a COMPLETE snippet, it parses, and this rule
already takes it as the arguments: neither rule can tell that search from a call. So the two
rules differ on exactly one kind of line, the unparseable one, and there this head's answer is
the bare one — the line is searched for, verbatim, into the field the daemon named, and the
row shows what was searched. That is a cost with a name rather than a hidden one."
  (and (stringp text) (plusp (length (string-trim " " text)))
       (handler-case (progn (json-decode text) t) (error () nil))))

(defun %door-name (head token)
  "The DAEMON's own name for the door tool a person typed as TOKEN, or NIL.

**The transform is textual and holds no knowledge of any tool** (R34): the door's tool names are
the daemon's, spelled with underscores because they come straight from the tool's own name, and
**a slash verb is typed with hyphens** — `/some-tool`, not `/some_tool` — because every other
verb in this head's vocabulary is one word and none of them needs the shift key. So a typed
`-` is matched against a published `_` and nothing else is touched: `read` is `read`, and a tool
whose name has neither is unaffected.

**Both spellings are ACCEPTED and the WIRE name is the daemon's.** *an operator who types what
the daemon calls it should not be told they are wrong* — so `/some_tool` works exactly as
`/some-tool` does, and the name this head SENDS is always the published one. A head that sent
the hyphen would be asking the daemon for a tool it does not have."
  (let ((door (head-run-tools (head-settings head))))
    (find-if (lambda (n)
               (string-equal (substitute #\- #\_ n)
                             (substitute #\- #\_ token)))
             door)))

(defun %door-arguments (head name line)
  "NAME and a person's LINE as the wire's arguments JSON, or `(values NIL WHY)`.

The ONE place both spellings meet, so the bare verb and `/run` cannot disagree about what a
line means:

  · **a line that parses as JSON IS the arguments**, verbatim — the form that shipped first,
    kept because a tool with several fields still needs it and because the head must not
    reinterpret something already in the wire's shape;
  · **anything else is the BARE form** (`%bare-arguments`), where the field comes from the
    daemon's row and this head holds no schema."
  (if (%json-text-p line)
      (values (string-trim " " line) nil)
      (%bare-arguments head name line)))

(defun %arguments-object (field line defaults)
  "The arguments object as JSON TEXT: FIELD set to LINE, then the daemon's DEFAULTS.

**Built by hand rather than with the encoder, and that is a correctness point and not a
style.** A default arrives from the daemon as JSON *text* — `10` for a number, `high` unquoted
for a string — so it is spliced in raw. The encoder would quote it, sending `{\"limit\":\"10\"}`
where a model's own call carries `{\"limit\":10}`, and the same tool would then answer two
different questions depending on who asked.

The LINE itself IS encoded, because it is a person's typing: a search containing a quote or a
backslash has to survive the trip to the daemon as the characters they typed."
  (with-output-to-string (s)
    (write-string "{" s)
    (format s "~a:~a" (json-encode-to-string field) (json-encode-to-string line))
    (loop for (k v) on defaults by #'cddr
          ;; **`(k v)`, not `(k . v)`, and the difference was a real bug**: the dotted form binds
          ;; `v` to the CDR, so a default of `(:limit 10)` spliced `(10)` into the arguments —
          ;; which is not JSON, and the daemon's parser said so one call later.
          do (format s ",~a:~a" (json-encode-to-string (%key-to-wire k)) v))
    (write-string "}" s)))

(defun %bare-arguments (head name line)
  "NAME + a person's LINE as the wire's arguments JSON, or `(values NIL WHY)`.

**The whole requirement, in one function: `/NAME blabla` and the head holds no schema.** The
field comes from the daemon's own row, looked up by name — so this knows nothing about the
tool, and a daemon that renames the field changes nothing here. `why` is the sentence the
caller shows when the bare form cannot be built, and it NAMES the reason rather than leaving
the operator to guess which tools take a sentence and which take JSON:

  · **no descriptors at all** — an older daemon: the head does not know, so it says it does not
    know, and quotes the name rather than a field;
  · **a name the row does not describe** — said as that, because *the daemon describes other
    tools and not this one* is a different fact from *the daemon said nothing*;
  · **a tool the daemon itself says has no bare form** — `:why-json` is the daemon's own
    sentence and THIS HEAD READS IT rather than inventing one, which is the same rule as the
    field name: the knowledge is the daemon's;
  · **a required field with nothing typed for it** — names the field, so the next keystroke is
    obvious."
  (let* ((descs (head-run-descriptors (head-settings head)))
         (d (cdr (assoc name descs :test #'string=)))
         (field (getf d :field))
         (why-json (getf d :why-json)))
    (cond
      ((null descs)
       (values nil
               (format nil "this daemon has not said which field a bare line fills for `~a`, so type the arguments as JSON — `~a {\"…\": \"…\"}`"
                       name name)))
      ((null d)
       (values nil
               (format nil "this daemon has not described `~a` — it named it in the door and said nothing about its arguments, so type them as JSON: `~a {\"…\": \"…\"}`"
                       name name)))
      ;; **the daemon's own sentence**, which is why `why_json` is on the row at all
      ((plusp (length why-json))
       (values nil (format nil "this daemon says `~a` takes no single argument — ~a; type it as JSON: `~a {\"…\": \"…\"}`"
                           name why-json name)))
      ((zerop (length field))
       (values nil
               (format nil "the daemon says `~a` takes no single argument — type it as JSON: `~a {\"…\": \"…\"}`"
                       name name)))
      ((zerop (length (string-trim " " line)))
       (values nil
               (format nil "`~a` needs its ~a — as `~a SOMETHING`" name field name)))
      (t (%arguments-object field line (getf d :defaults))))))

(defun %op-call-verb (head verb rest)
  "The operator's own shape — `/NAME blabla` — or NIL to let the verb fall through.

**A DOOR NAME IS ITS OWN VERB, and only the names the daemon published.** The lookup is
against `head-run.tools`, so a door offering one name gets that one verb: this head invents no
alias, no abbreviation and no friendly spelling, because the name IS the daemon's
(`head-run.tools`' own reason, applied to the verb).

**Two spellings of ONE name, and they are not two verbs** (R34): the typed form is hyphenated
and the wire form is the daemon's, so both are accepted and `%door-name` resolves each to the
single published name. That is a difference of SPELLING and not a vocabulary — the head still
answers only to names the daemon published, and to all of them.

**A name that is NOT in the door falls through untouched** — it travels to the daemon as the
slash line the operator typed, which is what every other verb does and what keeps a daemon-side
verb of the same name working.

**The gating is identical to every other door path**, and that is a constraint rather than an
observation: this calls `%op-call-ask`, so the bare form gets the same allowlist, the same two
frames and the same admission recorded as the operator's act. Sugar that skipped the door
would be a second door."
  (let ((name (%door-name head verb)))
    (when name
      (multiple-value-bind (args why) (%door-arguments head name rest)
        (if args
            (progn (%op-call-draft-close head)
                   (%op-call-ask head name args))
            (say head why)))
      t)))

(defun %run-command (head rest)
  "`/run` — run a tool the DAEMON names, on this machine, as the operator's own act.

**Two doors and one path.** `/run NAME what you want` is the operator's short form (R31):
the daemon's row says which field a bare line goes into, so this head turns the sentence into
the wire's JSON while knowing nothing about the tool. `/run NAME {…json…}` is the form that
shipped first and STAYS, because a tool with several fields still needs it.

**`/run` with nothing after it LISTS the door**, and that is a default changed on the
operator's review (*you guys do interfaces for yourself*): the old arm opened a JSON
composer, which is the shape an agent finds natural and a person has to learn. A person who
types `/run` wants to know what they can run, so they get a sentence naming the names and the
field each bare line fills. `alt+r` still opens the composer, which is the escape hatch for a
tool with several fields.

**Why the chord is not a control byte**, in one measurement: every control byte
a mnemonic can hang on is taken here. The composer owns `a b e f k u w y z` and `Rubout`,
the head owns `r t x l o s n p g q`, and the remaining letters do not arrive as control
bytes at all — `h` is Backspace, `i` is Tab, `j`/`m` are Enter, and `v` is the terminal's
literal-next in several emulators. R22 took `ctrl-n` on the same arithmetic (*the last free
byte with a mnemonic*), so what is left is an ESC-prefixed chord: `alt+r` is decoded by
this head's own reader, is not a prefix in tmux, and is bound to nothing else.

The arguments are the tool's own JSON — the shape a model's call carries — because a head
that knew one tool takes `{\"url\": …}` would be holding a copy of that tool's schema,
which is the same drift the settings row exists to stop one level up. They are validated as
JSON and nothing else: the wire says the field IS json text, and a head that passed
`https://example.com` through as the arguments would put a non-JSON string into the corpus
and hand it to the model as the call."
  (let* ((space (position #\space rest))
         (name (if space (subseq rest 0 space) rest))
         (args (if space (string-trim '(#\space #\tab) (subseq rest (1+ space))) "")))
    (cond
      ;; NO NAME: **LIST what the door accepts and how to type it** — not the composer.
      ;; The composer is an agent's shape and it was the wrong default: the common case is
      ;; `/NAME blabla`, and a person who types `/run` to find out what is available
      ;; should be told the short form rather than dropped into a JSON field. `alt+r` still
      ;; opens the composer, which is the escape hatch for a tool with several fields.
      ((zerop (length name))
       (let* ((door (head-run-tools (head-settings head)))
              (descs (head-run-descriptors (head-settings head))))
         (say head
              (if (null door)
                  "this daemon offers no operator-call door — it has published no tool list, so there is nothing to run"
                  (with-output-to-string (s)
                    ;; **hyphenated on the glass** (R34): the names here are what a person
                    ;; types, and the daemon's own spelling is what goes on the wire.
                    (format s "the daemon will run ~{~a~^, ~} for you — type `/NAME what you want`, as the tool's own name and then a sentence"
                            (mapcar #'%verb-spelling door))
                    (let ((described (remove-if-not (lambda (d) (plusp (length (getf (cdr d) :field))))
                                                    descs)))
                      (when described
                        (format s "; the bare form goes into ~{~{~a → ~a~}~^, ~}"
                                (loop for d in described
                                      collect (list (%verb-spelling (car d))
                                                    (getf (cdr d) :field)))))
                      (let ((json (remove-if (lambda (n) (assoc n described :test #'string=)) door)))
                        (when json
                          (format s "; ~{~a~^, ~} still take JSON" json))))
                    (format s " — and nothing runs until it says the call was admitted; alt+r types the JSON by hand"))))))
      ;; A NAME with a line: JSON if it IS json, the bare form otherwise — one decision,
      ;; made in `%door-arguments`, so `/run` and the bare verb cannot disagree.
      ;;
      ;; **And `/run some-tool …` is the same spelling question as the bare verb** (R34):
      ;; `%door-name` resolves either spelling to the daemon's own, so both doors accept both
      ;; and the wire always carries the published name. A name the door does not publish is
      ;; passed through untouched, which is what `/run` has always done with an unknown name —
      ;; the daemon refuses it, in the daemon's words.
      (t
       (%op-call-draft-close head)
       (let ((wire-name (or (%door-name head name) name)))
         (multiple-value-bind (built why) (%door-arguments head wire-name args)
           (if built
               (%op-call-ask head wire-name built)
               (say head why))))))))

(defvar *diag* nil
  "The diagnostic read in flight or on the screen: a plist
`:request-id ID :kinds (KIND…) :answers ((KIND :decided B :body S :total N)…)`.

**One at a time, deliberately.** The answer is keyed by the ADJUDICATION's id, so two
reads open at once would put two ids' answers in one pane and neither labelled; asking for
a second id REPLACES this, which is also what the pane does.

**`*diag*` is not cleared when the pane closes.** The answers are already here, and an
operator who left the listing with Esc and comes back with `/diagnostic` — with the same id
still the newest — should not be sent to the daemon again for two bodies this head is
holding. Bound by `with-replay-globals`, because a replay that folds a `diagnostic` frame
must not inherit another replay's read.")

(defun %diagnostic-ask (head request-id)
  "Open the pane and ask for BOTH halves, one frame each. T when the ask went out.

**Opened at the keypress, before any answer** — the job overlay's own rule: a pane that
appears only when the second frame lands is a pane the operator has been staring at an
empty screen for, and `reading…` is a fact rather than a blank.

**Both kinds, from `+diagnostic-kinds+`**, so a third kind is a name in that list and not a
second call site to remember."
  (let ((answers (loop for kind in +diagnostic-kinds+
                       collect (list kind :decided nil :body nil :total nil))))
    (setf *diag* (list :request-id request-id :kinds (copy-list +diagnostic-kinds+)
                       :answers answers))
    (open-diagnostic-listing *diag* head)
    ;; **THE VERB TAKES THE SCREEN**, which is the head's rule for a reply the operator
    ;; asked for (`note-slash-reply`'s own comment: a reply the operator asked for takes the
    ;; screen rather than scrolling past). Opening the listing without the mode would leave
    ;; the pane in `*slash-out*` and the conversation on the glass.
    (setf (head-mode head) :slash)
    (reset-pane-scroll)
    (setf (head-dirty head) t)
    (dolist (kind +diagnostic-kinds+)
      (%send head (make-fetch-diagnostic request-id kind)))
    (say head (format nil "reading the oracle's brief and reply for ~a — what the gate was shown, and what it answered"
                      request-id))
    t))

(defun %diagnostic-target (head)
  "The adjudication this head would read the oracle's exchange for, or NIL.

**The newest settled decision first, then an open ask.** Both `req-id`s are the
adjudication's own — the same id `/gate` takes — and the order is what an operator means by
*that one*: the ask in front of them if there is one, otherwise the last thing decided. A
head that picked the oldest, or the first, would read the wrong row on a session with more
than one decision in it."
  (let* ((s (head-session head))
         (open (session-open-decisions s))
         (settled (session-settled-decisions s))
         (last (and settled (getf (car (last settled)) :req-id))))
    (or (and open (getf (car open) :req-id))
        last)))

(defun %diagnostic-command (head rest)
  "`/diagnostic [ID]` — the oracle's brief and its reply, as the gate saw and heard them.

**A verb, because it is a READ of one named row.** `/gate` already takes a request id and
lists what the gate decided; this is the other half of that row, and it is asked for by the
same id so the two cannot disagree about which adjudication is being talked about.

With no id the head reads the newest one it can name — the open ask if there is one,
otherwise the last settled decision — and says which it chose, because a pane about
the wrong adjudication looks exactly like a pane about the right one."
  (let ((rest (string-trim " " rest)))
    (cond
      ((plusp (length rest)) (%diagnostic-ask head rest))
      (t
       (let ((id (%diagnostic-target head)))
         (if id
             (progn (%diagnostic-ask head id)
                    (say head (format nil "reading ~a — the newest adjudication this head can name (~a)"
                                      id (if (session-open-decisions (head-session head))
                                             "the ask in front of you"
                                             "the last one settled"))))
             (say head "nothing to read: `/diagnostic ID` names an adjudication, and this head has met none yet — `/gate recent` lists them")))))))

(defun %refresh-notes-listing (head)
  "Redraw the notes listing, if the listing on the screen is the NOTES one.

A daemon slash reply that happens to be up is not this head's to replace, and a
listing that has just gone stale — the reader retired one and the `[retired]` marks
moved — is exactly the pane that must not be left showing the old answer."
  (when (notes-listing-open-p)
    (open-notes-listing (head-session head))
    (setf (head-dirty head) t)))

(defun %toggle-pane (head mode &optional ask)
  "Open MODE, or CLOSE it when it is already the screen — and call ASK first when
it opens.

Every one of these is a toggle in the reference (app.rs:3071-3137, 4503-4566) and
reads as one. Here they only ever opened: `/help` twice left the help screen up,
and `ctrl-s ctrl-s` left the picker up, so Esc was a second thing to remember per
pane. ASK is the frame the pane needs filling — it is not sent on the close,
because a pane going away has nothing to ask for."
  (if (eq (head-mode head) mode)
      (setf (head-mode head) :normal (head-dirty head) t)
      (progn (when ask (funcall ask))
             (%open-pane head mode))))

(defun %open-pane (head mode)
  "Open the full-body screen MODE with its cursor at the top and nothing scrolled.

The panes share ONE cursor (`head-picker-sel`) and one scroll offset, because only
one is open at a time — so a position left by the last pane means nothing to the
next, and opening on it put the todos cursor three items down because the picker
had been there. The reference keeps a cursor per pane; with one, the top is the
only honest place to start."
  ;; one list on the screen at a time, the rule the pickers keep between themselves
  (setf *pick-open* nil)
  (setf (head-mode head) mode
        ;; the session picker opens ON THE SESSION YOU ARE IN — `ctrl-s` then
        ;; enter moved you off your own session, which is the shape of mistake
        ;; that costs a turn. Every other pane opens at the top, which is the
        ;; honest place when one cursor is shared.
        (head-picker-sel head) (pane-initial-sel head mode)
        (head-dirty head) t)
  (reset-pane-scroll))

(defun %send-slash (head line)
  "LINE as a `slash` frame — the line the operator would have typed, minus the
slash, which is how a daemon-side verb travels (`Action::Slash`). One place, so the
request id and the expected seq are filled the same way by every caller."
  (%send head (list :frame "slash"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :line line)))

(defun %interrupt (head reason)
  (%send head (make-interrupt (session-expected-seq (head-session head)) reason)))

(defun %cells (head message)
  "The operator pointing: the message, and this screen exactly as drawn —
ANSI included, delimited so both readers find the edges (app.rs:2977)."
  (if (or (zerop (head-last-cols head)) (zerop (head-last-rows-n head)))
      (say head "nothing has been drawn on this head yet — no cells to send")
      (let* ((w (head-last-cols head))
             (h (head-last-rows-n head))
             (text (format nil "~a~a~a~dx~d — my terminal exactly as this head drew it, ANSI escape codes included, so what you are reading IS the rendering and not a description of it~a~%~{~a~%~}~a~%"
                           message
                           (if (plusp (length message)) "

" "")
                           *cells-open* w h *cells-mark-end*
                           (head-last-rows head)
                           *cells-close*)))
        (%prompt head text))))


