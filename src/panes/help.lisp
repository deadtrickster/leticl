;;;; help.lisp — the /help screen: the verbs, and what each one does
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defparameter *help-rows*
  '(("enter" . "send what you typed; while a turn runs it is queued as a follow-up")
    ("alt+enter" . "a newline inside the prompt, without sending it")
    ("esc esc" . "interrupt the running turn — twice, within five seconds")
    ("ctrl-c" . "clear what you typed; twice on an empty prompt, within a second, quits")
    ("↑ ↓" . "move inside the prompt, then walk the prompts you have sent")
    ("pgup pgdn" . "scroll the transcript; esc returns to following the stream")
    ;; **THE WHEEL ROW SAYS WHAT IS IN FRONT** (sweep 2026-10-11, B.9): it read *scroll the
    ;; transcript*, and the wheel has scrolled a pane, a card's content and a job's output for as
    ;; long as those existed — `%pane-key` and `%decision-key` both have wheel arms. A help row
    ;; that names one of five surfaces is R29's defect on the page that IS the contract.
    ("wheel" . "scroll whatever is in front — a pane, an output window, the ask card's content — else the transcript; shift+drag selects text")
    ("ctrl-a ctrl-e" . "start and end of the line; ctrl-w and ctrl-u kill, ctrl-y yanks")
    ("ctrl-z" . "undo — a word at a time, and a kill is always its own step")
    ("paste" . "five lines or more collapses to a marker and is sent in full")
    ("ctrl-s" . "the session list: type a number or part of a name to switch")
    ;; **THE EDITOR'S DOOR** — the reference's help has this row before AND after the commit this sweep
    ;; is measured against (`5be9113`), and this head had NONE of it: `ctrl-]` opens rano on the newest
    ;; file the conversation changed (`%open-editor`). A key a reader cannot look up is a key they do
    ;; not use, and this one is the whole of the editor here.
    ("ctrl-]" . "open rano on the newest file this conversation changed — the file itself, not rano's review overlay")
    ("tab" . "complete the /command being typed; more tabs walk the matches")
    ;; **THE CLICK ROW NAMES EVERY SURFACE `%click` ROUTES TO** (click-actions.lisp), not the one
    ;; it was written for: the edge's count labels, the picker card, the dashboard's panels, the
    ;; five list panes, and — the sweep's own additions — the ask card's rungs and the quit card's
    ;; two choices. Selecting, never confirming: a gesture that commits on press is how a misclick
    ;; moves somebody's session.
    ("click" . "selects the row under the pointer — in the session list, the jobs, subagents, todos and config panes, on a picker card, on the ask card's rungs and the quit card's choices, on a dashboard panel; the edge's `N jobs running` / `N subagents running` labels open their pane. Enter still confirms")
    ("ctrl-t" . "the todos pane: the model's plan, and the repo's TODO.md — ↑↓ moves, enter or tab unfolds (enter on your own row opens it whole), space marks, i composes a prompt from a subtree, h hides the done ones, pgup/pgdn scrolls")
    ("ctrl-g" . "the subagents pane: the tree of children this session has started — enter or o switches into one, p reads its prompt")
    ;; **`ctrl-j` AND NOT `ctrl-q`** — the operator's ruling (TODO.md, section D): LF is the jobs
    ;; pane, and the decoder keeps CR and LF apart so the chord exists at all (`keys.lisp`).
    ("ctrl-j" . "the jobs pane: the background commands — enter reads one's output, d opens its dashboard")
    ("ctrl-o" . "move the command that is running now to the background — it keeps running as a job")
    ("/queue" . "the merge queue: every entry with its state, reviews and gate steps — enter opens one in full")
    ("/standing" . "the notes the harness is reading into this session's prompt right now — enter opens one whole")
    ("/term" . "a terminal in this session, in a pane: keys go to the program, ctrl-\\ detaches and leaves it running, /term returns to it, /term close ends it")
    ("/new [title]" . "start a session in this daemon and go there")
    ("/switch WHAT" . "go to a session by number, id or part of its name")
    ("ctrl-r" . "fold or unfold the model's reasoning")
    ("/t" . "open a window on ONE row: the newest long result, or the run at the reading rung — the same verb folds it back")
    ("/notes" . "the disclosures this head has shown; /notes dismiss [N|all] retires one or every one, /notes restore brings them back")
    ("ctrl-n" . "retire every note this head holds — the same as /notes dismiss all. /notes still lists them and /status still counts them")
    ("ctrl-x" . "show the raw <function=…> text of tool calls, as the model wrote it")
    ("ctrl-l" . "repaint the screen")
    ("/status" . "this head's counters — dropped, scrubbed, resync — and what each means")
    ;; **THE EVAL SOCKET'S OWN SURFACE, ON THE GLASS.** HACKING.md's contract is that this head is
    ;; a live image you can redefine while it runs; the socket was the only door to it, and this is
    ;; the same door with the transcript behind it. The row says what Enter does because that is the
    ;; whole pane, and it names the arrows because they are the composer's here and not the pane's.
    ("/lisp" . "this head's own image, live — the REPL pane: enter evaluates the prompt, ↑ walks the forms you have evaluated, /lisp FORM evaluates one from the prompt")
    ("/verbosity" . "the card that picks what the transcript shows — conversation, terse, normal or loud; /status counts what has been filtered")
    ("/interrupt" . "interrupt, when a key is awkward")
    ("alt+r" . "run a tool the DAEMON names on this machine, as your act — it opens a composer for the tool's own JSON, and `/run NAME {…json…}` is the one-line form")
    ("/config" . "every setting and where it came from; the first row toggles the diff view between split and unified")
    ("/compact" . "summarize this session down to one record; the old transcript is forked, not lost")
    ("/mode" . "move this project to a point: read-only, always-ask, writes-allowed, automode, automode-edits, allow-all (next session)")
    ("/supervise" . "the guard model answers every gated call before you do, from the next call — on, off, status")
    ("/gate" . "what the gate decided, and rule on it afterwards: recent, todo, corpus, ok|grant|revoke ID")
    ("/flowy" . "the seat on the fabric: /flowy status · /flowy login [SEAT] [--token T] · /flowy logout")
    ("/models" . "which model answers: /models lists them with their auth; /models deepseek/deepseek-chat switches and sticks; /models local")
    ;; **THE KEY ROW IS NEXT TO /models BECAUSE IT IS THE SAME QUESTION.** `/models` picks who
    ;; answers and names the auth it found; this is where that auth is PUT when there is none.
    ;; The row says *masked* and *never sent* because those are the two things a person wants to
    ;; know before typing a credential into a terminal.
    ("/key" . "NAME — paste a cloud provider's API key (deepseek | glm | grok) into providers.toml; the field is masked and the text is never sent to the model")
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

