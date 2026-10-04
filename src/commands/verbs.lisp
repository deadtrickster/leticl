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
    ;; **THE REPL — the head's own image as a screen** (`repl.lisp`). It shares `hack-eval-form`
    ;; with the eval socket, so a form that works at `tui-eval` works here, and the two cannot
    ;; come to disagree about what an eval IS — what they differ on is the PAINT LOCK, which the
    ;; pane must not take because it runs on the paint thread (see `hack-eval-form`).
    ("lisp" . "this head's own image — the REPL pane; /lisp FORM evaluates one from the prompt")
    ("stats" . "this head's counters — the same as /status")
    ("notes" . "what this head has warned about — and retire one")
    ("dismiss" . "retire every warning on the screen (/notes has the rest)")
    ;; the folds
    ;; **`/t` HAS A ROW and is not an alias, because it is now an ADVERTISED key**: the queued
    ;; echo's seam reads *"/t opens it"* (R33), so a reader types it. With no row, Tab on `/t`
    ;; would complete to `/think` — a different fold — which is how an alias becomes a trap the
    ;; moment something points at it. `/tools` is the daemon's listing verb and is not this
    ;; head's to describe.
    ;; **`/t` IS THE PER-ROW WINDOW, AND THE ONLY DOOR TO ONE.** It was `ctrl-t`'s job until the
    ;; chord was rebound to the todos pane; the logic is `%row-window`, unchanged. The
    ;; conversation-wide unfold — every long row at once, the wall — is the `tools` row in
    ;; `/config` and has no verb: the operator's own report is that a per-row seam cannot honestly
    ;; name a key that opens every row.
    ("t" . "open a window on ONE row: the newest long result, or the run at the reading rung — the same verb folds it back")
    ("think" . "fold or unfold the model's reasoning")
    ;; **R38: it is a PICKER, and the row must say so.** This said *"cycle the event-stream detail"*
    ;; — true until R38 and false after it, and it is the row a reader reads while typing `/v`. A
    ;; verb whose advertisement names the mechanism it no longer uses is R29's defect on the
    ;; completion row: the reader is told what will not happen. `/mode` two rows down already
    ;; reads *"the mode picker — or /mode NAME to type it"*, so this is the same shape, not a new one.
    ("verbosity" . "the verbosity picker — or /verbosity NAME to type it")
    ;; the surfaces
    ("config" . "every setting, as the daemon reports it")
    ("settings" . "every setting — the same as /config")
    ("mode" . "the mode picker — or /mode NAME to type it")
    ;; **THE KEY IS TYPED INTO A CARD, never into the composer** — see `*key-draft*`. The row
    ;; says where it goes, because *where did that key end up* is the question a person asks
    ;; after typing one.
    ("key" . "NAME — paste a cloud provider's API key (deepseek | glm | grok) into providers.toml")
    ("models" . "which model answers: the picker, or /models PROVIDER/MODEL")
    ("model" . "which model answers — the same as /models")
    ("jobs" . "the background-jobs pane")
    ("subagents" . "the subagent tree")
    ("todos" . "the plan and the repo's TODO.md — or /todos add for one of your own")
    ("dashboards" . "the live dashboard — panels are DATA, in ~/.config/letibot/dashboards/")
    ("dash-reload" . "re-read the dashboard directories from disk")
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
  "Send TEXT as a prompt, and remember it until its row lands.

**BEHIND A RUNNING TURN THE ECHO COALESCES, AND THAT IS THE DAEMON'S OWN RULE.** The engine merges
consecutive prompts from ONE HEAD into a single held message — `steering.rs:210`:

    if m.from_operator && let Some(last) = self.queued.last_mut() && last.from_operator {
        last.text.push('\\n');
        last.text.push_str(&m.text);
    }

— *\"the model reads one user turn, not a stack of fragments\"*. So two prompts typed behind a turn
arrive as ONE transcript row whose text is the two joined by a newline, and an echo that kept them
apart could never match it. That is not cosmetic: **the landing row retires the echo by BEING its
text** (`%retire-pending`), so an unjoined echo leaves both entries on the screen for the rest of
the session — and the operator sees two queued lines for a message the conversation will show as
one.

The operator, twice: *\"the queued messages must be still coalesced and still pinned to the
bottom\"*, and then, watching it: *\"you still got 2 queued as 2 separate\"*.

**Idle submits stay separate**, which is letibot's other half and the same reason read the other
way: an idle prompt lands as its own row within a tick, so there is nothing to merge it with — and
merging it into the PREVIOUS message would put two turns' words in one row. The test that says so
in letibot is `queued_prompts_behind_a_running_turn_are_one_message`.

**A notice is never merged in**: the harness's own injections stand alone, because folding them
into the operator's text would put the harness's words in the operator's mouth (`SteeringMessage`'s
own comment). That distinction is the daemon's and is mirrored here by only ever joining a
head-queued prompt — this function is the only writer of `head-queued`.

**AND *BEHIND A RUNNING TURN* MEANS BUSY, NOT THE STATE NAME `\"running\"`.** The daemon drains its
source at the ROUND boundary — *\"the greedy poll before a generation\"* — so everything typed during
one round is one held message, and a round is the generation AND the tool calls it made. The state
name is `\"running\"` only while the model generates; it reads `\"finished\"` for the whole of a tool
call (see `turn-busy-p`), which is exactly when the operator has the longest to type. MEASURED on the
live head, two prompts sent while a 40-second `sleep` ran, `:STATE \"finished\" :BUSY T`:

    ▌ queued · first queued
    ▌ queued · second queued

— two rows, and the daemon landed them as ONE row, `first queued⏎second queued`. The retirement
stood both echoes down (it is piecewise), so nothing was left standing; but for the whole wait the
screen promised two messages where the conversation would show one — the operator's *\"when multiple
messages queued all subsequent enqueues displayed with the first enqueue message\"*, read from the
other side: they belong together and were drawn apart."
  (let ((turn (session-turn (head-session head))))
    (if (and turn (turn-busy-p turn)
             (head-queued head))
        ;; **the JOIN is a NEWLINE, character for character** — the retirement is a text match, so
        ;; anything else (a separator, a trimmed copy) would leave the echo standing
        (setf (first (head-queued head))
              (format nil "~a~%~a" (first (head-queued head)) text))
        (push text (head-queued head))))
  (%send head (make-prompt (session-expected-seq (head-session head)) text)))

(defun %choose-verbosity (head level)
  "Set the rung AND write it down — the ONE interactive writer (R42's sibling).

**Not `set-verbosity`, and the difference is the file discipline.** A LOAD applies what the file
said and must not save back: a head that could not read the file (`load-prefs`'s unreadable case)
would otherwise write over a file it never saw — *never write what you did not read first*. So the
rung has two writers by necessity: `set-verbosity` for the value, and this for the value AND the
file, which the card's Enter and `/verbosity NAME` both come through. One interactive writer rather
than a `(save-head-prefs)` at each site, for the reason `%flip-fold` exists: *the fifth site is the
one that would forget*.

Returns the save's complaint, or NIL when it landed — a setting that did not persist is a
different fact from one that did, and the caller owns the sentence."
  (set-verbosity level)
  (handler-case (progn (save-head-prefs head) nil)
    (error (e) (format nil " (not saved: ~a)" e))))

