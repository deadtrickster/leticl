;;;; panes.lisp — the full-body screens: the session picker, help, status,
;;;; config, the background jobs, the subagent tree, the repo's TODO.md, the
;;;; model's plan, and peek.
;;;;
;;;; Each returns lines of segments like any other renderer, and `head-mode`
;;;; selects one in `%render` (render.lisp). They replace the transcript rather
;;;; than riding above it.

(in-package #:leticl)

;;; ------------------------------------------------------------- helpers ;;;
;;;
;;; Every pane below was measured against the reference's screen at 210x63
;;; (`scripts/compare-heads`, the `pane-*-lb.ans` captures), and these are the
;;; things every one of them needed: a plain-text WRAP, the `~` a path is written
;;; with, the short id, and the right-aligned row. The body's WIDTH, `pane-width`,
;;; is in render.lisp beside the gutter constants it reads.

(defun wrap-text (text cols)
  "TEXT to plain lines of at most COLS columns — `wrap` in the reference's
width.rs, over `wrap-segments` so the two wrappers here cannot break differently.

Each line is one string with its trailing space trimmed, because a painter that
erases to end of row would otherwise paint one column past the text."
  (mapcar (lambda (line) (apply #'concatenate 'string (mapcar #'car line)))
          (wrap-segments (list (cons text nil)) cols)))

(defun tilde-path (path)
  "PATH with `$HOME` written as `~` — the reference's `tilde`. NIL stays NIL."
  (let ((home (uiop:getenv "HOME")))
    (cond ((null path) nil)
          ((and home (plusp (length home))
                (>= (length path) (length home))
                (string= (subseq path 0 (length home)) home))
           (concatenate 'string "~" (subseq path (length home))))
          (t path))))

(defun short-id (id)
  "The last eight characters behind an ellipsis, or the whole of a short id —
`short_id` in the reference's registry.rs, which is what an unnamed session is
listed as."
  (let ((n (length id)))
    (if (<= n 10) id (format nil "…~a" (subseq id (- n 8))))))

(defun bytes-human (n)
  "`512 B`, `1.5 KB`, `2.0 MB` — the reference's `bytes_human` (render.rs:899)."
  (let ((k 1024))
    (cond ((< n k) (format nil "~d B" n))
          ((< n (* k k)) (format nil "~,1f KB" (/ n (float k 1d0))))
          ((< n (* k k k)) (format nil "~,1f MB" (/ n (float (* k k) 1d0))))
          (t (format nil "~,1f GB" (/ n (float (* k k k) 1d0)))))))

(defun split-row (left right cols)
  "LEFT at the left edge and RIGHT at the right, as one segment line — the
reference's `split_row`. When the two do not fit with two columns between them the
right half is dropped and the left is kept whole, which is the reference's choice
too: the facts are the part a narrow screen can do without."
  (let ((lw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) left)))
        (rw (reduce #'+ (mapcar (lambda (s) (string-width (car s))) right))))
    (if (<= (+ lw rw 2) cols)
        (append left
                (list (cons (make-string (- cols lw rw) :initial-element #\space) nil))
                right)
        left)))

;;; ------------------------------------------------------------- screens ;;;

(defun picker-sessions (session)
  "The sessions the picker lists: the daemon's own, with a SUB-SESSION under its parent.

The reference filters `parent_session_id.is_none()` on both `Hello` and
`Sessions` (app.rs:1391), because a subagent is a child of a session, shown in the
subagent tree and reached by `/switch id`. Ours listed them — measured on the
same daemon, letibot's picker had 28 rows and ours 58 — so the header's count
(`%session-position`) and the picker disagreed about how many sessions there
were. One filter, here, that both read.

**CORRECTED 2026-10-03, after the operator read a plan that made a child something to VIEW:**

  > why readonly? subagent session is more like you driving others via tmux. I already can post to
  > subagent, and agent can talk back and forth too

A child is a SESSION: it has a hub, rows, a store, a snapshot on request, and an id `/switch` already
takes — and this head deliberately hid it from the one list that reaches sessions. Everything built to
work around that hiding (the peek verb's renderer, `subagent-out-lines`, the pane's own Enter) is
vestigial now that Enter attaches and the peek asks for rows.

**WHAT THE FILTER WAS REACHING FOR IS REAL AND IS KEPT**: twenty subagents must not bury the four
conversations the operator cares about. So a child is drawn UNDER its parent and UNNUMBERED, and
`%session-position` counts the numbered rows only — the header says `1/3` for three conversations
however many children they have."
  (let* ((all (session-sessions session))
         (out nil))
    ;; **THE DAEMON'S ORDER, WITH EACH PARENT'S CHILDREN MOVED UP UNDER IT.** A child is a session —
    ;; attachable, promptable, and it answers; see the docstring for the operator's words and for why the
    ;; filter this replaces was the bug rather than the quiet.
    (dolist (p all)
      (unless (getf p :parent-session-id)
        (push p out)
        (dolist (c all)
          (when (equal (getf c :parent-session-id) (getf p :session-id))
            (push c out)))))
    ;; a child whose parent is not in the list — a daemon that trimmed it — is still a session
    (dolist (b all)
      (unless (member b out :test #'equal)
        (push b out)))
    (nreverse out)))

(defun picker-lines (session sel cols)
  "The session picker, row for row the reference's `picker_lines`:

    sessions in this daemon
    <blank>
    ▸  1  title                              2647 rows · 2 heads · qwen-3.8-27b
          s-1789639478142928813  ~/Projects/leticl
       2  other title                     on disk · 1799 rows · glm-5.3-flash
          s-1789462738453908838  ~/Projects/letibot
    <blank>
    ↑↓ moves · enter switches · …
    switching does not stop anything: …

The row under the cursor is reversed and the mark `▸` is what Enter takes; the
session this head is IN keeps its name bold, so \"where am I\" and \"what Enter
takes\" stay two readable facts. The facts on the right are the daemon's:
`generating` while a turn runs, `on disk` for a stored session, the store's row
count (the view's `items` is bounded and would make a long session look short),
the heads attached and the model. Under EVERY row, the full id and the workspace —
the id because it is the thing you would type, the workspace because for a stored
session it is the only thing on the row that says what the conversation was about.

Second value is the cursor's LINE: two lines per session, after a two-line header."
  (let* ((w (pane-width cols))
         (rows (picker-sessions session))
         (n (length rows))
         (sel (if (plusp n) (min sel (1- n)) 0))
         (header (list (list (cons "sessions in this daemon" '(:bold t)))
                       nil))
         (lines nil))
    (when (null rows)
      (push (list (cons "  none listed yet — the daemon has not answered, or this head is replaying a recorded log and has no daemon to ask."
                        '(:dim t)))
            lines))
    (loop for s in rows
          for i from 0
          do (let* ((here (equal (getf s :session-id) (session-session-id session)))
                    (picked (= i sel))
                    (status (getf s :status))
                    (title (or (getf s :title) ""))
                    (name (if (plusp (length title)) title (short-id (getf s :session-id))))
                    (running (getf status :running))
                    (stored (or (getf s :stored-items) 0))
                    (rows-n (if (plusp stored) stored (or (getf status :items) 0)))
                    (heads (or (getf status :heads) 0))
                    ;; **THE MODEL ON THE ROW THE HEAD IS IN COMES FROM THE HEAD, NOT FROM THE
                    ;; DAEMON'S ROW.** `wiring.model` is the daemon's word from its own attach, and
                    ;; it is never revised — `ServerFrame::Settings` has one send site and it is the
                    ;; ANSWER to a request (see `%model-name`), so a session whose provider changed
                    ;; mid-life has a stale model on every daemon row forever. That is the same fact
                    ;; `%model-name` was written for the HEADER, and leaving the picker on the raw
                    ;; `wiring` field made the two surfaces disagree about one session on one
                    ;; screen: the operator's *"in sessions list this session presented as qwen"*
                    ;; while the header of the same head said `deepseek/deepseek-flash`.
                    ;;
                    ;; The head only knows better about the session it is IN; for every other row
                    ;; the daemon's own word is the only thing anyone has.
                    (model (or (and here
                                    (let ((m (%model-name session)))
                                      (and (plusp (length m)) m)))
                               (getf (getf s :wiring) :model)
                               ""))
                    (workspace (or (getf (getf s :wiring) :workspace) ""))
                    (facts (remove nil
                                   (list (and running "generating")
                                         (and (not (getf s :live)) "on disk")
                                         (and (plusp rows-n) (format nil "~d rows" rows-n))
                                         (and (plusp heads)
                                              (format nil "~d head~:p" heads))
                                         (and (plusp (length model)) model))))
                    ;; the reference reverses the WHOLE left half, mark and name
                    ;; alike, and the name's bold rides inside it
                    (child (and (getf s :parent-session-id) t))
                    (number (1+ (count-if-not (lambda (b) (getf b :parent-session-id))
                                              (subseq rows 0 i))))
                    (left (list (cons (if child
                                         ;; **UNNUMBERED, and the number is what makes a row a CONVERSATION.**
                                         ;; The header counts the same rows this numbers, so twenty
                                         ;; subagents cannot turn it into `1/21`: a child sits under its
                                         ;; parent, where it is both visible and quiet.
                                         (format nil "~a   ↳ " (if picked "▸" " "))
                                         (format nil "~a ~2d  " (if picked "▸" " ") number))
                                       (and picked '(:reverse t)))
                                (cons name (cond ((and picked here) '(:reverse t :bold t))
                                                 (picked '(:reverse t))
                                                 (here '(:bold t))
                                                 (t nil)))))
                    (right (list (cons (format nil "~{~a~^ · ~}" facts)
                                       (if running '(:fg :yellow) '(:dim t))))))
               (push (split-row left right w) lines)
               (push (list (cons (if (plusp (length workspace))
                                     (format nil "      ~a  ~a" (getf s :session-id)
                                             (tilde-path workspace))
                                     (format nil "      ~a" (getf s :session-id)))
                                 '(:dim t)))
                     lines)))
    (push nil lines)
    (push (list (cons "  ↑↓ moves · enter switches · or type a number or part of a name and press enter · /new [title] makes one · /rename NAME names this one · esc closes"
                      '(:dim t)))
          lines)
    (push (list (cons "  switching does not stop anything: a turn keeps running in the session you left, and it is still there when you come back."
                      '(:dim t)))
          lines)
    (values (append header (nreverse lines))
            (+ (length header) (* 2 sel)))))

(defparameter *help-rows*
  '(("enter" . "send what you typed; while a turn runs it is queued as a follow-up")
    ("alt+enter" . "a newline inside the prompt, without sending it")
    ("esc esc" . "interrupt the running turn — twice, within five seconds")
    ("ctrl-c" . "clear what you typed; twice on an empty prompt, within a second, quits")
    ("↑ ↓" . "move inside the prompt, then walk the prompts you have sent")
    ("pgup pgdn" . "scroll the transcript; esc returns to following the stream")
    ("wheel" . "scroll the transcript; shift+drag selects text")
    ("ctrl-a ctrl-e" . "start and end of the line; ctrl-w and ctrl-u kill, ctrl-y yanks")
    ("ctrl-z" . "undo — a word at a time, and a kill is always its own step")
    ("paste" . "five lines or more collapses to a marker and is sent in full")
    ("ctrl-s" . "the session list: type a number or part of a name to switch")
    ("tab" . "complete the /command being typed; more tabs walk the matches")
    ("click" . "in the session list, picks the row under the pointer; enter still switches")
    ("ctrl-t" . "the todos pane: the model's plan, and the repo's TODO.md — ↑↓ moves, enter or tab unfolds, space marks, i composes a prompt from a subtree, h hides the done ones, pgup/pgdn scrolls")
    ("/new [title]" . "start a session in this daemon and go there")
    ("/switch WHAT" . "go to a session by number, id or part of its name")
    ("ctrl-r" . "fold or unfold the model's reasoning")
    ("/t" . "open a window on ONE row: the newest long result, or the run at the reading rung — the same verb folds it back")
    ("/notes" . "the disclosures this head has shown; /notes dismiss [N|all] retires one or every one, /notes restore brings them back")
    ("ctrl-n" . "retire every note this head holds — the same as /notes dismiss all. /notes still lists them and /status still counts them")
    ("ctrl-x" . "show the raw <function=…> text of tool calls, as the model wrote it")
    ("ctrl-l" . "repaint the screen")
    ("/status" . "this head's counters — dropped, scrubbed, resync — and what each means")
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

(defun status-screen-lines (head cols)
  "The status screen: `this head`, then one row per counter with WHY it exists
under it — the reference's `status_lines` (app.rs:6717), which is a screen that
explains its numbers rather than listing them.

Measured against letibot's own screen: ours was a ` status ` title and fourteen
`key value` pairs, several of them things the reference does not show at all
(title, model, items, a raw usage plist) and one printing `NIL` for a role nobody
sent. The reference shows the counters `/status` exists for — session, head, seq,
filtered, dropped, scrubbed, resync, verbosity, workspace — each as `  key` twelve
wide and dim, the value plain, and a dim explanation wrapped at `w - 16` under a
fourteen-column indent, then a blank. 26 rows against our 18."
  (let* ((w (pane-width cols))
         (s (head-session head))
         (out (list nil (list (cons "this head" '(:bold t))))))
    (flet ((row (k v why)
             (push (list (cons (format nil "  ~12a" k) '(:dim t))
                         (cons (format nil "~a" v) nil))
                   out)
             (dolist (l (wrap-text why (max 4 (- w 16))))
               (push (list (cons (make-string 14 :initial-element #\space) nil)
                           (cons l '(:dim t)))
                     out))
             (push nil out)))
      (when (plusp (length (session-session-id s)))
        (row "session" (session-session-id s)
             "In full, because this is the form a command takes. The header shows the last eight characters, which is the part two sessions differ in."))
      (when (plusp (length (session-head-id s)))
        (row "head" (format nil "~a · ~d attached" (session-head-id s)
                            (max 1 (length (session-heads s))))
             "Every head on this session sees the same stream from its own read mark. Closing one does not stop the turn."))
      (row "seq" (format nil "~d · ~d rendered" (session-seq s) *rendered-total*)
           "The log's monotonic, gap-free position, and how many of those events reached the screen. Both counted by this head, not by the daemon.")
      (row "filtered" (format nil "~d (~(~a~))" *filtered-total* *verbosity*)
           "Events this head chose not to show at the current verbosity. /verbosity opens a card of four rungs.")
      ;; **R10's counted half.** The number `/status` reads so a dismissal is
      ;; COUNTED rather than a disappearance: retiring a warning takes its row off the
      ;; screen and changes nothing here — `/notes` lists it with its whole text, and
      ;; it stays retired across a resync and a reattach. Present at 0 of 0 on a head
      ;; that has never been warned, which is a different statement from a head that
      ;; does not count them — the same rule `unreadable` keeps below.
      (multiple-value-bind (held retired) (warning-counts s)
        (row "notes" (format nil "~d of ~d retired" retired held)
             "The warnings this head holds, and how many the reader has retired. A retired one is off the screen and still in the log: /notes lists it with its text, /status counts it here, and a resync does not put it back."))
      (row "dropped" (or (session-dropped s) 0)
           "Events the daemon's bounded scrollback threw away before this head asked for them. Not a rendering choice: they are gone.")
      (row "scrubbed" *scrubbed-total*
           "Interactive-only frames withheld from a head that attached late — partial tool output and the like, which has no durable form.")
      (row "resync" *resyncs*
           "Times this head threw its state away and took a fresh snapshot, because the gap since its read mark was past the daemon's bound.")
      ;; **PRESENT AND ZERO**, which is the point of the row. A head that has never met
      ;; a frame it cannot read says 0 — a different statement from a head that does not
      ;; count them at all, and the one that tells an operator where to look when a
      ;; screen is wrong. A daemon one version ahead is the cause almost every time.
      ;; **the eval channel**, and it is a row because a count nobody shows is a
      ;; number nobody can act on: a head that has stopped being evaluatable and has
      ;; not said so cannot be told from a head nobody has asked. 0 is a real reading
      ;; here — this head has never had an accept fail — and that is a different
      ;; statement from a head that does not count them, which is the rule the
      ;; `unreadable` row below already keeps.
      (row "eval" (format nil "~a listening · ~d failed accept~:p"
                          (if (head-hack-listener head) "yes" "NO")
                          *hack-accept-errors*)
           "The live-modification socket: whether this head is still accepting eval connections, and how many times an accept failed and was retried. A head that stopped accepting runs on with a socket file and nothing behind it, which is what this row is for.")
      (row "unreadable" *unreadable-total*
           "Frames that arrived and could not be read. Almost always a daemon newer than this head: the frames the two share read fine, and the first one they do not is this. Each one is named in the conversation where it arrived.")
      ;; **The version, always present, and the DIRECTION when they differ.** §13.2b in
      ;; the other direction from the counters: the question "which build is on the
      ;; other end of this socket" has no answer anywhere else on the screen, and it is
      ;; the first thing to check when a head behaves strangely. `not told yet` is a
      ;; different statement from a version number — the same distinction the empty
      ;; transcript banner draws — and the row is here BEFORE the handshake has happened
      ;; so that "nobody told me" cannot be read as "we agree".
      (row "protocol" (if (integerp *daemon-protocol*)
                           (format nil "~d · ~a"
                                   *daemon-protocol*
                                   (cond ((= *daemon-protocol* +protocol-version+)
                                          (format nil "the same build as this head (protocol ~d)"
                                                  +protocol-version+))
                                         ((> *daemon-protocol* +protocol-version+)
                                          (format nil "this head speaks ~d — NEWER build"
                                                  +protocol-version+))
                                         (t (format nil "this head speaks ~d — OLDER build"
                                                    +protocol-version+))))
                           "not told yet")
           "The protocol both halves were built against, compared at the handshake. A NEWER daemon sends frames this build may not know: they are reported as they arrive and skipped. An OLDER one cannot read a command it has never heard of, and answers that by closing the connection — so a session with an older daemon can end on the next thing you type, and a restart of the daemon is the fix either way.")
      ;; THE RENDER ERROR, first among the things that can go wrong, because it is
      ;; the one that can hide its own report: a render error paints a failure
      ;; frame, and if the failure is IN the painting the frame saying so is
      ;; exactly what does not arrive. It has a row here so the question "why is
      ;; the screen wrong" has an answer that does not depend on the screen.
      (when *last-render-error*
        (row "render" (format nil "~a" (type-of *last-render-error*))
             (format nil "THE LAST FRAME FAILED TO RENDER: ~a — the failure is painted into the screen and this line is the same fact in a place that survives it. Fix the definition and re-push; clearing it is not the fix." *last-render-error*)))
      (row "verbosity" (verbosity-name)
           "What reaches the transcript at the current filter. /verbosity opens a card of four rungs. It used to sit on the composer's border, which was a row of attention paid for ever for a fact read once.")
      (let ((ws (getf (session-wiring s) :workspace)))
        (when (plusp (length (or ws "")))
          (row "workspace" (tilde-path ws)
               "Where the daemon is standing. Tools resolve relative paths here.")))
      ;; **AND WHAT THE READER HAS ALREADY SEEN** — the one line that keeps a quiet `⚠` from
      ;; reading as a zero counter. Opening this screen acknowledges every counter at the value it
      ;; holds (`acknowledge-alarms`), which is what takes the triangle off the composer's edge;
      ;; the numbers STAY here, exactly as a retired note stays in `/notes`. So the screen that
      ;; quiets the pointer is also the screen that says the pointer was quieted and why —
      ;; otherwise a reader coming back to find no triangle would conclude the count had reset.
      (let ((acked (remove-if-not (lambda (pair)
                                    (alarm-acked-p (car pair) (cdr pair)))
                                  (list (cons "dropped" (or (session-dropped s) 0))
                                        (cons "scrubbed" *scrubbed-total*)
                                        (cons "resync" *resyncs*)
                                        (cons "unreadable" *unreadable-total*)))))
        (when acked
          (push nil out)
          (push (list (cons (format nil "  acknowledged: ~{~a~^, ~} — seen here, so the edge is quiet; a counter\n above these values points again"
                                    (loop for (k . v) in acked collect (format nil "~a ~d" k v)))
                            '(:dim t)))
                out)))
      (push (list (cons "  /status or esc closes this" '(:dim t))) out)
      (nreverse out))))

;;; --------------------------------------------------------- the config pane ;;;

(defparameter *head-setting-rows*
  '("diff" "verbosity" "thinking" "tools" "raw_calls" "marker_seam")
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
    ((string= key "raw_calls")
     (setf (head-pref head :raw-calls)
           (not (head-pref head :raw-calls)))))
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
                          "marker seam")
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
                    finally (return line))))))

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

;;; ------------------------------------------------ the jobs and subagents ;;;

(defun jobs-lines (head cols)
  "The background jobs, the reference's `jobs_lines` (app.rs:6039):

    background jobs
    <blank>
        none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one.
    <blank>
        a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone.

or, with jobs, two lines each in place of the `none` row: `▸ [~] j12 command`
(the mark yellow while running, green for `exited 0`, red otherwise; the picked
row reversed) over a dim `         how · running · 1.2 KB out so far`,
`         how · exited 0 · 1.2 KB out · ran 3.4s`, or — for the one state where
nothing was ever executed — `         how · not run (could not join its scope) ·
0 B out`, with **no duration clause**: a job that never ran has no run to have
taken time (§11.6). Every field is the daemon's `JobEntry` — `id`, `command`,
`how`, `state`, `running`, `never_ran`, `produced`, `elapsed_ms`.

This pane NEVER RENDERED before: its header was `(list LINE (list LINE))` — the
second element a list containing a line, so a \"line\" whose segment was a line —
and `put-segments` died with `The value (\"\" :DIM T) is not of type STRING`.
Measured on the live head as `render failed — the head is alive; fix and re-push`.
A blank line is NIL, not a line with an empty dim segment.

Second value is the cursor's LINE: two lines per job after a two-line header."
  (let* ((w (pane-width cols))
         (rows (head-jobs head))
         (n (length rows))
         (sel (if (plusp n) (min (head-picker-sel head) (1- n)) 0))
         (out (list nil (list (cons "background jobs" '(:bold t))))))
    (when (null rows)
      (push (list (cons "    none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one."
                        '(:dim t)))
            out))
    (loop for j in rows
          for i from 0
          do (let* ((running (getf j :running))
                    (state (or (getf j :state) ""))
                    (mark (cond (running "[~]")
                                ((uiop:string-prefix-p "exited 0" state) "[x]")
                                (t "[!]")))
                    (colour (cond (running '(:fg :yellow))
                                  ((uiop:string-prefix-p "exited 0" state) '(:fg :green))
                                  (t '(:fg :red))))
                    (picked (= i sel))
                    (produced (or (getf j :produced) 0))
                    (elapsed (or (getf j :elapsed-ms) 0))
                    (never-ran (getf j :never-ran))
                    ;; **A job that never ran has no duration, and this row claimed
                    ;; one** (§11.6, letibot `e1cd2b0`). It read
                    ;;
                    ;;     not run (could not join its scope) · 0 B out · ran 0.0s
                    ;;
                    ;; — the state word denying *ran* two fields before the row said
                    ;; it. **The byte count stays**: `0 B out` is a measurement that
                    ;; exists (nothing was produced) and the word beside it says why.
                    ;; R17 again — *a row with nothing behind it must not look like a
                    ;; row with an empty something behind it* — and here the something
                    ;; is the run itself.
                    (tail (cond (running
                                 (format nil "running · ~a out so far" (bytes-human produced)))
                                (never-ran
                                 (format nil "~a · ~a out" state (bytes-human produced)))
                                (t
                                 (format nil "~a · ~a out · ran ~d.~ds" state (bytes-human produced)
                                         (floor elapsed 1000) (floor (mod elapsed 1000) 100))))))
               (push (list (cons (format nil "~a " (if picked "▸" " ")) (and picked '(:reverse t)))
                           (cons mark (if picked (append '(:reverse t) colour) colour))
                           (cons (format nil " ~a ~a" (getf j :id) (getf j :command))
                                 (and picked '(:reverse t)))
                           ;; **A JOB WITH A DASHBOARD SAYS SO ON ITS OWN ROW.** The operator's
                           ;; ask: *"link to dashboard from jobs if a job has associated
                           ;; dashboard."* It has to be ON THE ROW rather than in the hint bar —
                           ;; the hint says what a key does, the row says whether there is
                           ;; anything to open, and only the row can differ from job to job.
                           (cons (if (dash-panel-for-job j) "  · dash" "")
                                 ;; and the mark rides the selection's reverse video, or it is
                                 ;; the one part of the row that stays lit when the cursor leaves
                                 (if picked '(:reverse t) '(:dim t))))
                     out)
               (push (list (cons (truncate-to-width
                                  (format nil "         ~a · ~a" (getf j :how) tail) w)
                                 '(:dim t)))
                     out)))
    (push nil out)
    (push (list (cons "    a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone."
                      '(:dim t)))
          out)
    (values (nreverse out) (+ 2 (* 2 sel)))))

(defun subagent-rows (head)
  "The subagents this session spawned, oldest first, one row per subagent — the
reference's `subagents: Vec<SubagentState>`, folded the same way.

The `Subagent` events arrive one per state change and `apply-event` keeps them
all (newest first, in `session-subagents`); the reference folds each into the row
with the same id so `running` becomes `done` rather than a second line
(app.rs:1846). This is that fold, done at draw time so the wire state stays what
the daemon sent. The id is the event's `subagent_id` — the envelope's own
`session_id` is the PARENT's (event.rs:841), and a fold keyed on that counted every
child of one session as one subagent. Rows are `(:session-id :state :prompt :role)`."
  (let ((rows nil))
    (dolist (env (reverse (session-subagents (head-session head))))
      (let* ((id (or (getf env :subagent-id) (getf env :session-id)))
             (row (find id rows :key (lambda (r) (getf r :session-id)) :test #'equal)))
        (if row
            (setf (getf row :state) (getf env :state)
                  (getf row :prompt) (getf env :prompt)
                  (getf row :role) (getf env :role))
            (push (list :session-id id :state (getf env :state)
                        :prompt (getf env :prompt) :role (getf env :role))
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
               (push (list (cons (truncate-to-width
                                  (format nil "       ~a · role ~a · ~a~a"
                                          (short-id (or (getf s :session-id) ""))
                                          (or (getf s :role) "") state
                                          (if (string= state "opening") " — not attachable yet" ""))
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

(defparameter +todo-marks+
  '(("x" . :done) ("X" . :done) (" " . :open) ("~" . :doing) ("-" . :open))
  "The marks this file's own legend defines and `todo_write` uses, so both halves
of the pane read alike. `-` counts as open: it is a bullet nobody has picked up.")

(defun %todo-mark-of (line)
  "LINE as a checkbox, or NIL.

A checkbox is `- [x] …`, `- [ ] …` or a bare `[x] …` — markdown's list bullet is
optional, because a TODO.md written by hand does not always carry one."
  (let ((trimmed (string-left-trim " " line)))
    (when (>= (length trimmed) 3)
      (let ((body (cond ((and (>= (length trimmed) 6)
                              (or (uiop:string-prefix-p "- [" trimmed)
                                  (uiop:string-prefix-p "* [" trimmed)))
                         ;; strip the bullet AND its space: `- [x] one` → `[x] one`
                         ;; at offset 2. At 3 the body starts `] one` and nothing
                         ;; matches, which is how the first version read every
                         ;; checkbox as prose.
                         (subseq trimmed 2))
                        ((char= (char trimmed 0) #\[) trimmed)
                        (t nil))))
        (when (and body (>= (length body) 3) (char= (char body 0) #\[)
                   (char= (char body 2) #\]))
          (let ((mark (cdr (assoc (string (char body 1)) +todo-marks+ :test #'string=))))
            (when mark
              (values mark (string-left-trim " " (subseq body 4))))))))))

(defun strip-todo-markup (text)
  "`**T1** git init` -> `T1 git init`. Backticks go too; nothing else is
interpreted, because this is a reader and not a renderer."
  (let ((out text))
    (dolist (marker '("**" "`"))
      (loop for i = (search marker out)
            while i
            do (setf out (concatenate 'string (subseq out 0 i) (subseq out (+ i (length marker)))))))
    out))

(defun %todo-rollup (marks)
  "Org's rule for a parent, and the whole of it: every child done makes the parent
done; any child started makes it started; otherwise open."
  (cond ((every (lambda (m) (eq m :done)) marks) :done)
        ((some (lambda (m) (not (eq m :open))) marks) :doing)
        (t :open)))

(defun read-todo-md (body)
  "BODY (a TODO.md) to a list of `todo-row` plists.

Each row: `:indent` (columns before the mark), `:mark` (`:open`/`:doing`/`:done`
or NIL for a heading with no checkboxes under it), `:text`, `:body` (the detail
lines under an item) and `:item` (T for a checkbox row, NIL for a heading).

The indent is carried rather than baked into the text, because it belongs BEFORE
the mark and the mark is the part that gets painted — pre-indented it renders as
`[x]     Phase 0` with the colour in front of the whitespace instead of on the
box. And `:item` exists because a heading carries a mark TOO (its roll-up), so
the mark cannot be what tells a row from a heading."
  (let ((out nil)
        (section nil)
        (items nil)                     ; newest first: mark, head, body
        (collecting nil)
        ;; **THE SOURCE LINE EVERY ITEM WAS PARSED FROM** (R44 editable), so a caller can rewrite
        ;; exactly one line of the file instead of regenerating it.
        ;;
        ;; This is not a convenience. `%todo-row-lines` re-renders a row from its PARSED fields, so
        ;; writing the rows back would reformat the whole file and discard everything this parser
        ;; does not model — prose between items, the `Deps:` indent, wrapping, trailing space. On a
        ;; SHARED, COMMITTED file that is a diff nobody asked for and a conflict for whoever else is
        ;; editing it. The line number is what makes the edit surgical instead.
        (line-no 0))
    (labels ((flush ()
               (when section
                 (if (null items)
                     ;; no box and no cookie: an empty section is one nobody has
                     ;; filled in, and org does not mark it done either. Indent
                     ;; 6, not 4: with no mark to paint, the reference's row is
                     ;; `{pad}{cursor}{text}` at `indent - 2`, and measured
                     ;; against its screen `Dependency graph` sits six in, where
                     ;; a heading WITH a box has its `[x]` at four.
                     (push (list :indent 6 :mark nil :text section :body nil
                                 :item nil)
                           out)
                     (let ((marks (mapcar #'first items)))
                       (push (list :indent 4
                                   :mark (%todo-rollup marks)
                                   :text (format nil "~a  [~a/~a]"
                                                 section
                                                 (count :done marks)
                                                 (length items))
                                   :body nil :item nil)
                             out)
                       ;; oldest first under the heading
                       (dolist (it (reverse items))
                         (push (list :indent 8 :mark (first it) :text (second it)
                                     :body (third it) :item t :line (fourth it))
                               out))))))
             (end-item () (setf collecting nil)))
      (dolist (line (uiop:split-string body :separator '(#\newline)))
        (incf line-no)
        (cond
          ;; `##` and deeper. `###` is a subsection and owns its own items, which
          ;; is what org's outline says too.
          ((or (uiop:string-prefix-p "## " line)
               (uiop:string-prefix-p "### " line))
           (flush)
           (let ((n (if (uiop:string-prefix-p "### " line) 4 3)))
             (setf section (string-trim " " (subseq line n))
                   items nil
                   collecting nil)))
          (t
           (multiple-value-bind (mark text) (%todo-mark-of line)
             (cond
               (mark
                ;; the LINE is the fifth element, carried so an edit can address the file
                (push (list mark (strip-todo-markup text) nil line-no) items)
                (setf collecting t))
               ((zerop (length (string-trim " " line)))
                ;; a blank line CLOSES an item: two items a blank apart would
                ;; otherwise merge, and the prose between a heading and its list
                ;; would land on whatever came before
                (end-item))
               ((and collecting
                     (or (char= (char line 0) #\space)
                         (char= (char line 0) #\tab))
                     items)
                ;; an indented line under an item is that item's DETAIL — where a
                ;; TODO.md puts the commit it pins and the `Deps:` line.
                ;;
                ;; APPENDED, not pushed: the detail reads top-to-bottom as the
                ;; file does, and pushing put the `Deps:` line above the commit it
                ;; was pinned to. `(third (first items))` is the CURRENT item;
                ;; `items` itself is newest-first.
                (let ((det (strip-todo-markup (string-trim " " line))))
                  (setf (third (first items))
                        (append (third (first items)) (list det)))))
               (t (end-item)))))))
      (flush)
      (nreverse out))))

;;; ----------------------------------------------------- which checkout ;;;
;;;
;;; **THE REPO SECTION IS A SHARED FILE, AND WHICH FILE STOPPED BEING OBVIOUS THE MOMENT WORKTREES
;;; ARRIVED.** The operator's ruling, in their words: *"since we are on git - I'm trying to automate
;;; and set worktrees rules… indeed `<name>/<name>` is a deliberate pattern and then the idea is
;;; basically this - the main workspace `<name>` displays todo from `<name>/<name>` and this is fine
;;; because if i will have agents specific to worktrees i will have workspaces inside
;;; `<name>/<worktree>`."*
;;;
;;; So `<name>/<name>` is the MAIN CHECKOUT and `<name>` is a CONTAINER that holds it, and an agent
;;; seated in a worktree is handed a workspace that IS a checkout. Two questions, no search:
;;;
;;;   1. is the workspace ITSELF a checkout? -> its own `TODO.md`. Covers `leticl`, `stroppy`,
;;;      `stroppy-pfn`, and every agent seated in a worktree;
;;;   2. else is `<workspace>/<basename workspace>` a checkout? -> THAT one. Covers the container:
;;;      `rano` -> `rano/rano`, `letibot` -> `letibot/letibot`;
;;;   3. else the caller NAMES WHERE IT LOOKED — and reads the workspace's own `TODO.md` if there is
;;;      one, which is what this pane did before the rule existed and what keeps a workspace that is
;;;      not a checkout working rather than blank.
;;;
;;; **`basename` IS THE WHOLE OF THE DETERMINISM.** *"The single repo one level down"* is a search
;;; that has to refuse an ambiguity; *the one NAMED AFTER ME* cannot be ambiguous, because the main
;;; checkout is identifiable by NAME.
;;;
;;; **AND NOTHING HERE ENUMERATES WORKTREES, WHICH IS NOT FASTIDIOUSNESS.** MEASURED on this box:
;;; letibot has 19 registered worktrees and AT LEAST FOUR whose directories are GONE (three under
;;; `.claude/worktrees/agent-*`, one at `/tmp/claude-1000/wt2`), so a rule that walked
;;; `git worktree list` would hand out paths that do not exist. This one copes with a layout it does
;;; not know — main at `<name>/<name>`, agent worktrees under `<name>/.claude/worktrees/`, and at
;;; least one worktree (`letibot-profiles`) that is a SIBLING of the container rather than inside it.
;;; `<name>/<worktree>` is the intent; the disk is what the rule has to survive.
;;;
;;; **AND A WORKTREE AGENT READS ITS OWN BRANCH'S `TODO.md`** — the same tracked file as that branch
;;; has it. Two heads on two worktrees can hold different repo sections and both be right, which is
;;; exactly why the pane names WHICH checkout instead of saying "the repo's" and leaving it there.

(defun %workspace-dir (workspace)
  "WORKSPACE with trailing slashes trimmed, so one directory does not have two spellings."
  (string-right-trim "/" (or workspace "")))

(defun %dir-basename (dir)
  "DIR's last path component, or NIL for a path that has none (the root)."
  (let ((base (car (last (pathname-directory (uiop:ensure-directory-pathname dir))))))
    (and (stringp base) base)))

(defun %checkout-root-p (dir)
  "T when DIR is the ROOT of a git checkout — a main checkout, a LINKED WORKTREE, or a submodule.

**`probe-file` AND NOT A DIRECTORY TEST, MEASURED, AND THIS IS THE TRAP.** In a linked worktree
`.git` IS A FILE:

    /home/dead/Projects/letibot-profiles/.git
      -> \"gitdir: /home/dead/Projects/letibot/letibot/.git/worktrees/letibot-profiles\"

so any IS-IT-A-DIRECTORY test answers NOT-A-REPO for EVERY worktree — `test -d` in a shell, `isdir`
in a script, `directoryp` in Lisp — and the operator's table mislabelled `letibot-profiles` for
exactly that reason.

**AND THE MEASURED CORRECTION TO THE WARNING, because the version I was given is narrower than the
trap.** The operator described the trap as `probe-file` on the TRAILING-SLASHED path answering NIL.
**On this SBCL it does NOT** — a trailing slash still resolves a regular file, and this docstring said
otherwise until the test beside it failed by returning the truename. So the trap is the DIRECTORY TEST
and not `probe-file`, which is the right side for this predicate to be wrong on: a bare probe of the
untrailed path answers for a file and for a directory alike, so it cannot be fooled in either
spelling. What must never appear here is `directoryp`, and the test records the `test -d` NO with a
control beside it.

**NOT `git rev-parse --show-toplevel` EITHER — not because it would be wrong, but because of where
this runs.** It agrees with the test above on every checkout measured here, and what it would ADD is
a fork on the pane's draw path. This tree has already priced that: `dash.lisp` and `dashwatch.lisp`
both wrap their child processes in coreutils' `timeout` because `uiop:run-program`'s own `:timeout`
was MEASURED doing nothing, and a `git` that hangs while the pane is drawing is a pane that freezes
with nothing to recover from. It would also answer a DIFFERENT question by walking up —
`rano/rano/src` resolves to `rano/rano` — where the rule asks whether the workspace *itself* is a
checkout. A filesystem test asks exactly that and costs no process."
  (and (plusp (length dir))
       (probe-file (format nil "~a/.git" dir))))

(defun %todo-path-for (dir)
  (format nil "~a/TODO.md" dir))

(defun repo-todo-path (workspace)
  "The `TODO.md` this workspace's repo section reads: `(values PATH ROOT TRIED)`.

PATH is NIL when there is nothing to read. ROOT is the DIRECTORY the file came from — the thing the
pane NAMES, so a reader can tell one worktree's section from another's — and it is NIL only where
PATH is. TRIED is every directory the rule examined, in order, and it comes back on EVERY outcome,
because a refusal that cannot say where it looked is a refusal the operator cannot act on."
  (let* ((ws (%workspace-dir workspace))
         (inner (and (plusp (length ws))
                     (let ((base (%dir-basename ws)))
                       (and base (format nil "~a/~a" ws base))))))
    (cond
      ((zerop (length ws)) (values nil nil nil))
      ((%checkout-root-p ws) (values (%todo-path-for ws) ws (list ws)))
      ((and inner (%checkout-root-p inner))
       (values (%todo-path-for inner) inner (list ws inner)))
      ;; **3. NO CHECKOUT — READ THE WORKSPACE'S OWN FILE IF IT HAS ONE.** This is what the pane did
      ;; before any of this existed, and dropping it would silently blank a workspace that is not a
      ;; checkout: the suite's own fixture is a temp directory holding a `TODO.md` and nothing else,
      ;; and the operator's scratch workspaces are the same shape. It is a FIXED PATH AND NOT A
      ;; SEARCH, so the determinism the rule is built on is untouched — it is the same file the space
      ;; key has always written.
      ((probe-file (%todo-path-for ws)) (values (%todo-path-for ws) ws (list ws)))
      ;; and otherwise say where we looked, NAMING THE NAMESAKE when there was one to name
      (t (values nil nil (if (and inner (probe-file inner)) (list ws inner) (list ws)))))))

(defun repo-todo-checkout (workspace)
  "The directory the repo section is showing, or NIL when it is showing none."
  (nth-value 1 (repo-todo-path workspace)))

(defun %repo-checkout-label (workspace)
  "WHICH checkout the repo section reads, short enough for a heading — or NIL.

`(leticl)` when the workspace IS the checkout and `(rano/rano)` when it is a container, which are the
two cases the rule has. The heading says this because with worktrees the answer stopped being
obvious: two heads can hold different repo sections and both be right."
  (let* ((ws (%workspace-dir workspace))
         (root (and (plusp (length ws)) (repo-todo-checkout ws))))
    (and root
         (let ((rb (%dir-basename root)))
           (cond ((null rb) root)
                 ((string= root ws) rb)
                 (t (format nil "~a/~a" (or (%dir-basename ws) "") rb)))))))

(defun %repo-todo-missing-why (path root tried)
  "The sentence for a repo section with nothing to read, naming EVERY directory examined.

`(no TODO.md in …)` alone was the defect: the pane said it about `/home/dead/Projects/rano`, where
the repo is one level down, so it read as *there is no TODO.md* rather than *I looked in the wrong
place*. Naming where it looked is the operator's own third step, and it is the only reason this case
was visible at all."
  (cond
    ((null tried) "this session has no workspace, so there is no TODO.md")
    ((null path) (format nil "no TODO.md — looked in ~{~a~^ and ~})" tried))
    (t (format nil "no TODO.md in ~a" root))))

(defun repo-todo-rows (workspace)
  "The repo's TODO.md as rows, or one row saying why there are none."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((null tried)
       (list (list :indent 4 :mark nil :text "(no workspace in the wiring)"
                   :body nil :item nil)))
      ((and path (probe-file path))
       (read-todo-md (uiop:read-file-string path)))
      ;; **A REFUSAL THAT NAMES EVERY DIRECTORY IT LOOKED IN.** See `%repo-todo-missing-why`: the old
      ;; sentence named the workspace and stopped, which read as *there is no TODO.md* about a repo
      ;; sitting one level down.
      (t
       (list (list :indent 4 :mark nil
                   :text (format nil "(~a)" (%repo-todo-missing-why path root tried))
                   :body nil :item nil))))))

;;; ---------------------------------------------------------- the watcher ;;;
;;;
;;; The pane used to read the file at open, so a file edited WHILE the pane was up
;;; showed the old read — and this file is edited exactly while somebody is
;;; looking at it. The operator: *"since the file can be updated, dont cache it i
;;; guess or do a watcher with a nice syscall"*.
;;;
;;; One `stat` per draw rather than an inotify thread: a watcher means a
;;; descriptor, a thread and an event routed into a head whose design is one loop
;;; over one channel, and the pane is drawn only while it is open. `(mtime, len)`
;;; rather than mtime alone, because a second-granularity mtime misses two writes
;;; inside one second and a length change catches most of those.

(defvar *repo-todo-cache* nil "The rows last read, or NIL.")
(defvar *repo-todo-stamp* nil "The (mtime len) they were read at.")

(defvar *repo-todo-generation* -1
  "The `*code-generation*` the cached rows were read UNDER, which is the half of the key the file's
stamp cannot supply.

**The file's `(mtime, len)` answers *did the FILE change*, and a live push is not the file changing.**
MEASURED on the operator's own head: the pane cached the rows, a push redefined `read-todo-md` to carry
`:line`, the stamp still matched, and every repo row went on being drawn without one — so `i` refused
on all of them, blaming the row. `-1` rather than 0 so the FIRST read is taken as stale whatever the
counter happens to hold, including in a fresh image (where both are 0).

See `*code-generation*` in `head.lisp` for the whole reading.")

(defun %todo-stamp (path)
  (ignore-errors
    (let ((w (sb-posix:stat path)))
      (list (sb-posix:stat-mtime w) (sb-posix:stat-size w)))))

(defvar *repo-todo-path* nil
  "The workspace the cache was read for, so a Switch does not show the old
project's queue.")

(defun repo-todo-rows-cached (workspace)
  "The repo's rows, re-read when the file changes (or the workspace does), OR WHEN THE CODE DOES."
  (let* ((path (repo-todo-path workspace))
         (stamp (and path (probe-file path) (%todo-stamp path))))
    (unless (and (equal path *repo-todo-path*)
                 (equal stamp *repo-todo-stamp*)
                 ;; **THE CODE'S OWN GENERATION IS PART OF THE KEY.** A push can change the SHAPE these
                 ;; rows have without the file moving at all, and a cache that only watches the file
                 ;; then hands back what the old code produced — see `*code-generation*`.
                 (eql *code-generation* *repo-todo-generation*))
      (setf *repo-todo-path* path
            *repo-todo-stamp* stamp
            *repo-todo-generation* *code-generation*
            *repo-todo-cache* (repo-todo-rows workspace)))
    *repo-todo-cache*))

(defun %todo-md-toggle-line (text line-no)
  "TEXT (a TODO.md) with line LINE-NO's checkbox flipped, or `(values NIL REASON)`.

**ONE LINE, and every other byte of the file identical.** The alternative — parse the rows, flip one,
render them all back — is what `%todo-row-lines` would give you, and it would reformat the whole file:
prose between items, the indent under an item, wrapping and trailing space all go, because the parser
does not model them. On a file the operator COMMITS and COLLABORATES on, that is a diff nobody asked
for plus a conflict for whoever else is editing it. So the edit is a splice on one line.

**The marks are `[ ]`, `[x]` and `[~]`, and only the first and second flip.** `[~]` means *in
progress* — a state somebody is holding — and a space bar that cleared it would be dropping somebody's
claim on a row. Flipping `[~]` is not defined here rather than guessed at; the caller says so.

**THREE VALUES AND NOT TWO, because two positions meant two things.** The first cut returned
`(values TEXT MARK)` on success and `(values NIL REASON)` on failure, so the SECOND value was a keyword
in one case and a sentence in the other — and a caller that reached for it got `:open` where it expected
a reason. MEASURED, in this feature's own test: `TYPE-ERROR expected-type: SEQUENCE datum: :OPEN`.

So: `(values TEXT MARK REASON)`. TEXT is NIL exactly when nothing was written, MARK is `:done`/`:open`
exactly when something was, and REASON is a sentence exactly when nothing was."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (line (and (> line-no 0) (<= line-no (length lines)) (nth (1- line-no) lines))))
    (cond
      ((null line) (values nil nil (format nil "line ~d is not in the file any more" line-no)))
      (t (let ((at (or (search "[ ]" line) (search "[x]" line) (search "[X]" line)
                       (search "[~]" line))))
           (cond
             ((null at) (values nil nil "that line has no checkbox to mark"))
             ((or (search "[~]" line) (and (>= (length line) (+ at 3)) (string= "[~]" (subseq line at (+ at 3)))))
              ;; `[~]` is somebody's claim; said rather than silently cleared
              (values nil nil "that row is in progress — a space bar does not clear somebody's claim"))
             (t
              (let* ((was (subseq line at (+ at 3)))
                     (now (if (or (string= was "[ ]")) "[x]" "[ ]"))
                     (fresh (concatenate 'string (subseq line 0 at) now (subseq line (+ at 3)))) )
                (setf (nth (1- line-no) lines) fresh)
                (values (format nil "~{~a~^~%~}" lines)
                        (if (string= now "[x]") :done :open)
                        nil)))))))))

(defun %todo-md-subtree-range (text line-no)
  "The RAW LINES of TEXT covering the subtree that starts at LINE-NO: `(values FIRST LAST)`.

**READ FROM THE FILE, NOT FROM THE PARSED ROWS, and that is forced rather than chosen.** MEASURED on
this head: `read-todo-md` FLATTENS the tree — every item comes back `:item T :indent 8`, so

    - [ ] parent task
      - [ ] child one      <- indented two spaces in the FILE

both arrive at indent 8, and a sibling after them does too. The real nesting is gone, so a subtree
cannot be recovered from the rows at all. This walks the raw lines, where the indentation still is.

**The rule is markdown's list rule**, which is also rano's schema's rule: the block runs until a
non-blank line whose indent is at or below the parent's, and blank lines and anything deeper belong to
it. Blank lines do not end it because a subtree with a blank line between two children is still one
subtree, and it is how this repo's own TODO.md is written.

**THE LAST NON-BLANK LINE IS THE END**, so a run of blanks after the subtree is not swallowed into the
range — a range that claims trailing empty lines would make the prompt name lines that say nothing."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (n (length lines)))
    (when (and (> line-no 0) (<= line-no n))
      (let* ((first (1- line-no))
             (base (let ((l (nth first lines)))
                     (- (length l) (length (string-left-trim " " l)))))
             (last first))
        (loop for i from (1+ first) below n
              for raw = (nth i lines)
              for blank = (zerop (length (string-trim '(#\space #\tab) raw)))
              for indent = (- (length raw) (length (string-left-trim " " raw)))
              do (cond
                   ;; deeper or blank: inside the subtree
                   ((or blank (> indent base))
                    (unless blank (setf last i)))
                   ;; at or below the parent and not blank: the subtree ended before this line
                   (t (loop-finish))))
        (values (1+ first) (1+ last))))))

(defun repo-todo-implement-text (workspace line-no)
  "The sentence to put in the composer for the `TODO.md` subtree at LINE-NO — or `(values NIL REASON)`.

**AN INSTRUCTION AND THE LITERAL TREE, which is the operator's ruling arriving twice.** First:
*\"whole tree - we keep context.\"* Then, on where that context lands: *\"the literal text of the whole
tree goes into the prompt, which is exactly where context belongs — the model reads the why and the
surrounding items as prose, once, at the moment it is asked.\"*

**THIS REVERSES WHAT THIS FUNCTION DID FIRST, AND WHY IT IS NOT A CONTRADICTION IS LIFETIME.** The first
cut was *a reference, not a transcription* — name the file and the range, paste nothing — on the rule
that a COPY goes stale. That rule is right about DURABLE state: this head's scratchpad, the model's
board, anything that sits. **A prompt is consumed once**, in the turn it is sent, so *goes stale* does
not apply to it, and the operator's reason is the better one for the case at hand: the model reads the
why and its neighbours at the moment it is asked, rather than hunting for them.

**THE WHOLE FILE AND NOT THE SUBTREE**, which is the ruling's own distinction: *\"untagged siblings
included - not the tagged node and not its spine.\"* Siblings are not descendants, so a copy that
included them is a copy of everything. MEASURED, that is a lot of text — this repo's own `TODO.md` is
~63 KB and rano's is ~107 KB — and it is deliberate: the body is the WHY (*\"because I expect todos have
not only titles right? bodies too. so when you build a component you want to know why\"*), and an item
read without its neighbours is an item whose reasons were cut off.

**THE LABEL IS STILL THE TITLE ALONE, WHICH IS WHAT KEEPS THE TWO DECISIONS COMPATIBLE.** The quoted
words are the item's own FIRST LINE and the body is not joined onto them, because at this level a body
line and a CHILD's line are both just *one line under the parent*. So the prompt has three parts with
three jobs and none is redundant: the label names WHAT, the literal text carries the WHY, and the range
is the handle.

**AND THE TEXT IS THE FILE AS READ — byte for byte**, not a re-rendering of the parsed rows. The parser
models boxes, titles and indented bodies; it does not model the prose between items, the blank lines or
the wrapping, so a round trip through it would hand the model a file that is not the one on disk.

**THE PATH IS NAMED WITH ITS CHECKOUT**, because with worktrees *the model's `TODO.md`* is ambiguous —
its workspace holds its own branch's copy (R58).

**AND NOTHING HERE WRITES A FILE.** *\"we can do copying via model … it is essentially a scratch pad
for shared todos\"* — the model writes the scratchpad, so there is no tree-copy operation here and no
divergence for the head to resolve.

**UNPLACED ON PURPOSE: the sha, the file hash and the mtime at this moment.** The operator: *\"when you
copy you have things - hash and commit and modified timestamp of the shared todo.md\"*, and those are
what answer *did upstream change under me* later. **Where they go — the ask, the scratchpad's text, or
both — is NOT ruled**, and the instruction is explicit: *\"Do not invent a store for it; note that it is
unplaced.\"* So it is noted and not built. The composer is the obvious place once it is ruled."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((or (null path) (not (probe-file path)))
       (values nil (%repo-todo-missing-why path root tried)))
      (t (handler-case
             (let* ((text (uiop:read-file-string path))
                    (lines (uiop:split-string text :separator '(#\newline)))
                    (row (nth (1- line-no) lines)))
               (cond
                 ((or (null row) (null line-no))
                  (values nil "that row is no longer in the file"))
                 (t (multiple-value-bind (first last) (%todo-md-subtree-range text line-no)
                      ;; **THE WORDS COME FROM THE RAW LINE**, so what the model reads back matches
                      ;; what the operator selected character for character — the parsed row's text
                      ;; has been through `strip-todo-markup`, which is the RENDERER's transformation
                      ;; and would hand the model a spelling the file does not contain.
                      (let* ((words (%todo-md-item-text row))
                             (label (%repo-checkout-label workspace))
                             (where (if label (format nil " (the ~a checkout)" label) ""))
                             (what (if (= first last)
                                       (format nil "Implement the TODO.md item \"~a\" — TODO.md line ~d."
                                               words first)
                                       (format nil "Implement the TODO.md subtree \"~a\" — TODO.md lines ~d–~d."
                                               words first last))))
                        (values
                         ;; **THE LITERAL TREE FOLLOWS THE INSTRUCTION**, and `text` is the file AS READ —
                         ;; byte for byte, so what the model sees is what is on disk rather than a
                         ;; re-rendering of the parsed rows (which drops the prose between items, the blank
                         ;; lines and the wrapping, none of which the parser models).
                         (format nil "~a~%~%The whole of ~a~a as it stands, so the surrounding items and their reasons are in view rather than the named lines alone:~%~%~a"
                                 what path where text)
                         nil))))))
           ;; **ONE FEWER CLOSE ON THE LINE ABOVE, ONE MORE HERE**, and the depth is what says so:
           ;; the protected form's `(values …)` needs six closes to get back to the `handler-case`
           ;; itself, and seven reached past it — which left THIS clause outside the `handler-case`
           ;; as a stray form, so `(error (e) …)` read as a call to the function `e`. Measured the
           ;; same way as the `dash-watcher-source-fn` defect: `scripts/count-parens.py FILE FIRST LAST`
           ;; prints the depth at every line, and it goes to 5 here and 0 at the clause, rather than
           ;; to 4 and 0 — which is the whole of the difference and took a counter to see.
           (error (e) (values nil (format nil "TODO.md could not be read: ~a" e))))))))

(defun %todo-md-item-text (raw-line)
  "RAW-LINE's own words, with the markdown bullet and checkbox taken off.

**NOT `strip-todo-markup`** — that one is the RENDERER's and strips emphasis and code markers for the
screen. This is naming a line back to the model, so the words should be the file's own.

**ONE LINE, SO A WRAPPED ITEM'S LABEL IS ITS FIRST LINE AND ENDS MID-SENTENCE — deliberate, MEASURED on
the operator's own `TODO.md`**, whose `T1 · the payload window` (line 440) wraps across 25 lines. The
composed prompt then reads

    Implement the TODO.md subtree \"**T1 · the payload window** (`keys.md` G13/G20, `wire.md` W2,\" — TODO.md lines 440–464.

and the comma at the end is where the file's own line ended, not a truncation: the RANGE names the
rest, which is the handle the model reads the file by. **JOINING THE WRAPPED LINES WAS THE ALTERNATIVE
AND IT IS WORSE**, for the reason that gave this whole gesture its shape: an item's continuation lines
are indistinguishable from a CHILD'S at this level — T1's prose runs to the end of its block — so
joining would paste twenty-five lines of prose into the composer under the name of `words`, which is
the transcription `repo-todo-implement-text` exists to refuse. A label that is a fragment plus an
unambiguous range beats a label that is a copy."
  (let* ((t* (string-left-trim " \t" raw-line))
         ;; the bullet: `- [ ] `, `* [x] ` or a bare `[ ] `
         (t* (cond ((and (>= (length t*) 2)
                         (member (char t* 0) '(#\- #\*) :test #'char=)
                         (char= (char t* 1) #\space))
                    (string-left-trim " " (subseq t* 2)))
                   (t t*)))
         (t* (cond ((>= (length t*) 3)
                    (let ((at (or (search "[ ]" t*) (search "[x]" t*) (search "[X]" t*)
                                  (search "[~]" t*) (search "[-]" t*))))
                      (if (and at (zerop at)) (string-left-trim " " (subseq t* 3)) t*)))
                   (t t*))))
    (string-trim " " t*)))

(defun repo-todo-toggle (workspace line-no)
  "Flip the checkbox on LINE-NO of WORKSPACE's TODO.md. Returns `(values MARK REASON)`.

**The shared half of the todo list, and the whole point is that it is a FILE.** R44's split, in the
operator's own words: the todos that live near the session are the head's own (per project, in sqlite,
and nobody else sees them), and the ones you tick here are the ones you mean to SHARE — they are
committed, they travel with the repo, and another person may be editing the same file.

That is why this returns a reason rather than signalling: every refusal is something to SAY (no
checkbox on that line, an in-progress row, a file that cannot be written), and a space bar that
appears to do nothing is the defect this pane has already been fixed for twice.

**The write is a whole-file rewrite of a file whose only change is one line**, so a reader
mid-`git diff` sees one line move. It is not atomic — a crash between the read and the write could
truncate — and that is accepted rather than hidden: a TODO.md is in git, `git checkout` is the
recovery, and a temp-file-and-rename dance would be a second thing to get wrong for a file whose
worst case is one lost edit."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((or (null path) (not (probe-file path)))
       (values nil (%repo-todo-missing-why path root tried)))
      (t (handler-case
             (let* ((text (uiop:read-file-string path)))
               (multiple-value-bind (new mark why) (%todo-md-toggle-line text line-no)
                 ;; the same three-value shape as `%todo-md-toggle-line`, for the same reason: a
                 ;; MARK and a REASON must not share a position, or a caller cannot tell *ticked* from
                 ;; *refused* without knowing which branch produced it.
                 (cond
                   (new (with-open-file (out path :direction :output :if-exists :supersede
                                                  :if-does-not-exist :error
                                                  :external-format :utf-8)
                          (write-string new out))
                        ;; the cache is keyed on (mtime len) and this write may land inside the same
                        ;; second as the read that filled it — so it is dropped rather than trusted
                        (setf *repo-todo-cache* nil *repo-todo-stamp* nil)
                        (values mark nil))
                   (t (values nil why)))))
           (error (e) (values nil (format nil "TODO.md could not be written: ~a" e))))))))

(defun repo-todo-lines (workspace)
  "The repo's TODO.md as plain lines, for callers that want text. The pane uses
`repo-todo-rows-cached`; this stays for the rest."
  (mapcar (lambda (row) (format nil "~a~@[~a ~]~a"
                                (make-string (getf row :indent) :initial-element #\space)
                                (case (getf row :mark) (:done "[x]") (:doing "[~]") (:open "[ ]"))
                                (getf row :text)))
          (repo-todo-rows workspace)))

(defvar *repo-todo-open* nil
  "Whether the repo item under the cursor is UNFOLDED — the reference's
`repo_open`, one flag beside one cursor.

The cursor is `head-picker-sel` while the todos pane is up (one cursor for every
pane, because only one is open at a time), and moving it folds the item again, so
at most one item is ever open: the reference's rule, and the one the captures
show. Keyed to the cursor rather than to the row's text because that is what Up,
Down, Enter and Tab all agree on. A defvar, not a head slot: a struct layout
change is a restart.")

(defun %todo-mark-style (mark)
  "A mark's colour: done green, doing yellow, OPEN LEFT ALONE.

An open item is the default state and the majority of any list, and colouring the
majority spends the signal the other two carry."
  (case mark
    (:done '(:fg :green))
    (:doing '(:fg :yellow))
    (t nil)))

(defun %todo-mark-text (mark)
  (case mark (:done "[x]") (:doing "[~]") (:open "[ ]") (t "   ")))

(defun %todo-row-lines (row &key here open)
  "One repo todo row to segment lines — the mark PAINTED, the indent separate.

The reference's row (`todos_lines`, app.rs:5898) is `{pad}{cursor}{mark} {text}{more}`
with `pad` two columns SHORT of the indent and `cursor` either `▸ ` or two spaces,
so a row's box sits at its indent whether or not the cursor is on it. HERE is
that cursor; OPEN unfolds the body under the row, one dim line per detail line at
`pad + 8`. A folded item with a body ends in ` ···` — ONE space, plain, measured:
ours drew two and dimmed it.

**AND THE BODY IS THE WHY, WHICH IS THE WHOLE REASON THIS ROW UNFOLDS AT ALL.** The operator: *\"because
I expect todos have not only titles right? bodies too. so when you build a component you want to know
why.\"* **MEASURED on this head's own `TODO.md`, on `T1 · the payload window` (file line 440): the body
is 24 lines and 1643 bytes, EVERY line of it is drawn when the row is open, and opening adds exactly
24 lines to the pane.** So nothing here is *preserved but unreachable* — and that was worth measuring
rather than assuming, because a body parsed into a field nobody can see is indistinguishable from a
body that was never kept.

**The title/body split is therefore STRUCTURAL, and it is why the `i` prompt takes the first line and
nothing more.** Those 24 lines are the item's BODY; the label `%todo-md-item-text` builds for the
composer is the title alone, because at this level a body line and a CHILD's line are both just *one
line under the parent* — so joining them would paste the whole body into the composer under the name of
the item's words, which is the transcription `repo-todo-implement-text` exists to refuse. The prompt
names the line RANGE instead, and the body is the reason that range is worth naming.

The indent is its own segment so the colour lands on the box and not in front of
the whitespace; `TodoMark::painted` in the reference exists for the same reason,
and so does the assertion in the test that checks the ESCAPES rather than the
glyphs. A heading with no mark is one dim segment: it is the operator's prose,
not a task.

Returns a LIST OF LINES — the row, then its body when open. The caller must
FLATTEN these (see `todos-lines`, which appends them), because a nesting mistake
here is invisible: it renders as a list printed into a cell rather than as an
error."
  (let* ((mark (getf row :mark))
         (pad (make-string (max 0 (- (getf row :indent) 2)) :initial-element #\space))
         (cursor (if here "▸ " "  "))
         (text (getf row :text))
         (detail (getf row :body))
         (more (if (and detail (not open)) " ···" "")))
    (append
     (list (if mark
               (list (cons (concatenate 'string pad cursor) nil)
                     (cons (%todo-mark-text mark) (%todo-mark-style mark))
                     (cons (format nil " ~a~a" text more) nil))
               (list (cons (format nil "~a~a~a" pad cursor text) '(:dim t)))))
     (when (and detail open (getf row :item))
       (mapcar (lambda (l) (list (cons (format nil "~a        ~a" pad l) '(:dim t))))
               detail)))))

(defun repo-todo-stops (rows)
  "The indices of the ITEMS in ROWS — where the todos cursor may stop.

Headings roll up the rows beneath them and have nothing to unfold, so the cursor
skips them: the reference's `stops` (app.rs:3268)."
  (loop for r in rows for i from 0 when (getf r :item) collect i))

(defun %todo-item-lines (item author show-detail &optional here)
  "ITEM as the pane's lines: the mark, the words, and whose they are — plus the description under
them when SHOW-DETAIL and the item has one.

**The author label is on the ROW and not in a heading**, because the two lists interleave in one
list and a reader scanning it needs to know which is which per line, not per section. `  — you` /
`  — model` is the whole of the distinction the operator asked for: *\"it should be marked as
created by me, and created by model as created by model.\"*

The description hangs under the title at six columns, which is two past the mark, so the item's
words and its detail read as a block rather than as two entries."
  (let ((st (cond ((string= (or (getf item :status) "") "in_progress") :doing)
                  ((string= (or (getf item :status) "") "completed") :done)
                  (t :open))))
    (append
     ;; **the cursor mark, in the pane's own column** — `▸ ` or two spaces, like every other
     ;; selectable row here, so a reader who has learnt this pane's cursor finds it on a
     ;; session item too. The row is reversed when it is the one the cursor is on, which is
     ;; what every other pane does and what makes `delete` mean *this row*.
     (list (list (cons (if here "  ▸ " "    ") (and here '(:reverse t)))
                 (cons (%todo-mark-text st) (%todo-mark-style st))
                 (cons (format nil " ~a" (getf item :content)) (and here '(:reverse t)))
                 (cons (format nil "  — ~a" author) (if here '(:reverse t) '(:dim t)))))
     (let ((detail (getf item :detail)))
       (when (and show-detail detail (plusp (length detail)))
         (list (list (cons "      " nil)
                     (cons detail '(:dim t)))))))))

(defvar *todos-hide-done* nil
  "Hide the DONE rows in the todos pane. The operator's ask: *\"in todo panel i want a mode where done
items hidden\"*.

**A MODE AND NOT A FILTER, because the two sections answer it the same way and a reader should learn it
once.** A done row is still a row: `todos-stops` still refuses to offer it to the cursor, and this
hides it only from the DRAWING — so with the mode on the cursor walks what is on the screen and nothing
else, which is the invariant this pane has broken twice before (see `todos-stops`: *\"arrows dont go
here\"*, and a stop whose row was never drawn).

**Both authors, both sections.** The operator's rows, the model's, and the file's — a done item is done
whoever wrote it, and hiding only one half would make the mode mean two things.

**It is a `defvar` like `*repo-todo-open*`, and like that flag it does NOT survive a restart.** It is
where your eyes are, not a preference, and the pane is opened and closed many times a session. If it
turns out to want remembering, it belongs in `head.toml` beside the diff view rather than in a
long-lived special — say the word and it moves there."
)

(defun %todo-hidden-p (item)
  "Is ITEM a row this pane is hiding? Only the DONE ones, and only in the mode — see `*todos-hide-done*`."
  (and *todos-hide-done*
       (string= (or (getf item :status) "") "completed")))

(defun %todo-row-hidden-p (row)
  "Is the FILE's ROW hidden? Its own vocabulary: the parser's mark, not a status string.

The two predicates are separate rather than one taking a plist because the two lists genuinely say it
differently — a session item carries `:status \"completed\"` and the parser hands back `:mark :done` —
and a single predicate guessing which shape it was given is how a row stops being hidden the day one of
them is renamed."
  (and *todos-hide-done* (eq (getf row :mark) :done)))

(defun todos-stops (head)
  "Every row of the todos pane the cursor may land on, in the order the pane draws them.

**One enumeration, and everything that asks *where is the cursor* reads this one** — the
arrows, the click, the cursor's LINE, and the key that acts on a row. R44's first cut had it
spread over a `-1` sentinel and the repo's own stop indices, and both of the operator's
reports came from that: *\"arrows dont go here\"* was the cursor moving to a row whose line
the pane then reported from another list's arithmetic, and *\"mouse doesnt click\"* was a
click on the add row computing a negative index and being thrown away. Two enumerations was
the defect; this is the one.

A stop is tagged, and **the tag carries the row's IDENTITY rather than its position**:

  · `(:add)` — the one control, at the head;
  · `(:mine . ID)` — the operator's own item, by its id (see `*operator-todos*`: *\"a todo item is
    identified by a hash or something like a commit\"*);
  · `(:repo . I)` — a row of the workspace's `TODO.md`, index I into `repo-todo-rows-cached`, which
    has no ids because it is a file the head reads rather than a list it owns.

**Identity and not position, and the difference is the whole of it.** A position is a fact about
the list at the moment it was drawn; a list changes between a draw and a keypress — a `TodosUpdated`
arriving, an item removed, the session switching — and every action then lands on the row that took
its neighbour's place. With the id, `delete` removes the row the operator was looking at or nothing
at all. The repo's rows keep an index because they are addressed by their own file's order and the
pane re-reads that file, so the index IS their identity there.

**The model's items are drawn and are NOT stops, and that is the R44 boundary rather than
an omission.** The head has no frame that writes a todo (`ListTodos` is documented as *a
question, not an act*), so there is no key that could act on one of the model's rows —
and a cursor that stops where no key acts is a cursor the operator presses keys into and
nothing happens. They are skipped the way the repo's headings always were.

`head-picker-sel` is an ORDINARY INDEX INTO THIS LIST, which is why the head's slot type is
untouched and why the cursor survives a list changing under it: a deletion shifts the index
and the row it lands on is still a row."
  (let* ((s (head-session head))
         (rows (repo-todo-rows-cached (getf (session-wiring s) :workspace))))
    (append (list (list :add))
            ;; **A HIDDEN ROW IS NOT A STOP**, which is the half that keeps the cursor honest: the
            ;; pane draws no line for it, so a stop for it would be a cursor position with nothing
            ;; under it — and every key that acts on the row would act on a row nobody can see.
            (loop for item in *operator-todos*
                  unless (%todo-hidden-p item)
                    collect (cons :mine (getf item :id)))
            ;; the index is the row's identity here and is NOT renumbered by the hiding: `:repo`
            ;; stops are addresses into `repo-todo-rows-cached`, which the mode does not change.
            (loop for r in rows
                  for i from 0
                  when (and (getf r :item) (not (%todo-row-hidden-p r)))
                    collect (cons :repo i)))))

(defun todos-lines (head cols)
  "The todos pane: the session's plan with its authors, the add control, and the repo's TODO.md.

    todos
    <blank>
      this session — the plan, and who wrote each line:
      ▸ [+] add todo item
        [ ] check the logs  — you
          the daemon log, not the head's
        [x] a model item  — model
    <blank>
      the repo's TODO.md (rano/rano) — what the PROJECT intends, not the model's board:
          Dependency graph
        [x] T1 …
    <blank>
      space ticks one line of it in place; i composes a prompt from a subtree.

**THREE VALUES**: the lines, the cursor's LINE, and a vector of every stop's line, parallel to
`todos-stops`. The second is an `aref` of the third — never arithmetic over one of the three lists
this draws from, which is what put the pane four lines above the row it was scrolling to.

**EVERY LINE GOES THROUGH ONE `emit`**, and a line is recorded as a stop's line only when the
caller says so. The index is `(length out)` taken inside `emit` — the line's index in the list
this function RETURNS, because `out` is built in reverse and flipped at the end. Two other forms
of *push this line, and maybe record it* is how the first cut came to record one entry for five
stops: the recorded index was the length before some pushes and after others."
  (declare (ignore cols))
  (let* ((s (head-session head))
         (todos (session-todos s))
         (ws (getf (session-wiring s) :workspace))
         (rows (repo-todo-rows-cached ws))
         (stops (todos-stops head))
         (n (length stops))
         (sel (if (plusp n) (min (max 0 (head-picker-sel head)) (1- n)) 0))
         (out nil)
         (stop-lines (make-array 0 :adjustable t :fill-pointer 0))
         (at 0))
    (flet ((emit (line &optional stop-p)
             (when stop-p (vector-push-extend (length out) stop-lines))
             (push line out))
           ;; **IS THIS ROW THE CURSOR'S?** — and the two halves of that question are different
           ;; ones, which is what the first cut of this got wrong: it asked *is this row AT `at`*,
           ;; and `at` walks EVERY stop, so the mark landed on the first row whose tag matched
           ;; rather than on the row the cursor was actually sitting on. The operator's own report
           ;; is what that looked like: the pane opened with the cursor on the add row and a `▸`
           ;; drawn somewhere else, and every repo item came out double-indented because its row
           ;; thought it was selected.
           ;;
           ;; `at` is where the WALK is (advancing once per row, so it and `stops` stay in step);
           ;; `sel` is where the CURSOR is. The tag and the identity are the third check, and they
           ;; stay because they make the comparison impossible to make against a row of the wrong
           ;; kind — belt to the braces above, and cheap.
           (this (tag id) (and (< at n) (= at sel) (nth at stops)
                               (eq (car (nth at stops)) tag)
                               (equal (cdr (nth at stops)) id))))
      (emit (list (cons "todos" '(:bold t))))
      (emit nil)
      (emit (list (cons "  this session — the plan, and who wrote each line:" '(:dim t))))
      ;; **the add control**, at the head of the session's list because that is where an addition
      ;; goes: `[+]` in the items' own mark column, BOLD, so it reads as a control rather than as a
      ;; line of the list. *"it looks like a regular text"*, said of the first cut, which was plain
      ;; `    add todo item` in the items' own register with nothing but the cursor to tell them
      ;; apart.
      (let ((on (and (< at n) (eq (car (nth at stops)) :add))))
        (emit (list (cons (if on "  ▸ " "    ") (and on '(:reverse t)))
                    (cons "[+] " '(:bold t))
                    (cons "add todo item" '(:bold t)))
              t))
      (incf at)
      ;; the operator's items and the model's, one list with the author on every row
      (dolist (item *operator-todos*)
        (unless (%todo-hidden-p item)
        (let ((here (this :mine (getf item :id)))
              (first t))
          (dolist (line (%todo-item-lines item "you" t here))
            ;; **EVERY item records its line, not only the cursor's** — `stop-lines` is parallel to
            ;; `todos-stops`, and its whole job is to say where each stop is DRAWN. Recording only
            ;; the selected row left a vector with one entry in it and made `(aref stop-lines sel)`
            ;; an out-of-bounds read for every cursor position but the first.
            (emit line first)
            (setf first nil)))
        (incf at)))
      ;; **THE MODEL'S ITEMS ADVANCE NOTHING**, because they are not stops: `todos-stops` skips
      ;; them for the reason its docstring gives (no key acts on one), and a walk that advanced
      ;; here would run `at` past the stop it is comparing against — which is how the pane came to
      ;; index its stop-lines array out of bounds on a plan that had any model rows in it.
      ;; **THE WIRE'S LIST HELD BOTH AUTHORS, AND THIS DREW THE OPERATOR'S ROWS TWICE.** `session-todos`
      ;; is the daemon's UNION (both halves — see `TodoBoard::snapshot`), while the rows above come from
      ;; `*operator-todos*`, which is this head's own half. So every row the operator wrote was drawn
      ;; once as theirs and again here, **labelled `model`** — a duplicate AND a false author. MEASURED
      ;; on the live head with one row on the board: `[x] push leticl to github — you` immediately
      ;; followed by `[x] push leticl to github — model`.
      ;;
      ;; The fix is to draw each half once, from the half that OWNS it: the operator's rows from this
      ;; head's list (which is what the add and delete keys act on, and what carries the ids the
      ;; cursor's stops are tagged with), and the model's rows from the wire. **The tag is read rather
      ;; than assumed**, because `by` is the whole of the difference between the two halves and a pane
      ;; that re-derives authorship from which list a row arrived in is the drift this feature exists
      ;; to prevent.
      (dolist (item todos)
        (unless (or (string= (or (getf item :by) "") "operator")
                    (%todo-hidden-p item))
          (dolist (line (%todo-item-lines item "model" nil))
            (emit line nil))))
      (when (and (null *operator-todos*) (null todos))
        (emit (list (cons "    none written yet. The model writes them with todo_write, and the row above adds one of yours."
                          '(:dim t)))))
      ;; **AND WHEN THE MODE IS WHAT EMPTIED IT.** The distinction the pane keeps insisting on: a
      ;; section with nothing in it and a section whose contents are HIDDEN are different facts, and a
      ;; reader who cannot tell them apart concludes the key did nothing — which is the defect this
      ;; pane has been fixed for three times.
      (when (and *todos-hide-done*
                 (or *operator-todos* todos)
                 (every #'%todo-hidden-p
                        (append *operator-todos*
                                (remove-if (lambda (i) (string= (or (getf i :by) "") "operator"))
                                           todos))))
        (emit (list (cons "    everything here is done — h shows them." '(:dim t)))))
      (emit nil)
      ;; **letibot's sentence, and it is load-bearing rather than tidy**: two sections that look alike
      ;; and BEHAVE differently have to say which is which. One is what the project intends, the other
      ;; is what the agent is doing — and until this pane had a key that writes the file, a reader
      ;; could tell them apart by the `— you` / `— model` marks alone. They are not a plan in two
      ;; places, and they are not synced: nothing here reaches the model's board, and nothing on that
      ;; board ticks this file.
      (emit (list (cons (format nil "  the repo's TODO.md~@[ (~a)~] — what the PROJECT intends (space ticks it, i composes a prompt):"
                                (%repo-checkout-label ws))
                        '(:dim t))))
      (if (null rows)
          (emit (list (cons "    no sections found." '(:dim t))))
          (loop for r in rows
                for i from 0
                ;; **`at` AND `stops` STAY IN STEP, so `at` advances only on the rows that ARE
                ;; stops** — the repo rows carrying an item. Headings are drawn and are not stops,
                ;; so advancing for them walked the walk past the entries it was comparing against
                ;; and no repo row ever matched: the pane drew no cursor mark on the file's items
                ;; at all, which is the one thing this pane has always done.
                for item-row = (and (getf r :item) t)
                ;; **A HIDDEN ROW IS NOT DRAWN AND NOT A STOP**, so `at` does not advance for it:
                ;; the same rule the headings below keep, one step further.
                for hidden = (%todo-row-hidden-p r)
                for here = (and item-row (not hidden) (this :repo i))
                ;; **a row's stop is its FIRST line**, so the body of an unfolded item does not
                ;; move the cursor's target — and the line is taken before the row draws, because
                ;; the row renders to as many lines as its body needs.
                for first-line = (length out)
                unless hidden
                  do (dolist (line (%todo-row-lines r :here here
                                                      :open (and here *repo-todo-open*)))
                       (emit line nil))
                     ;; **and the same here: an item row records its line whether or not the cursor
                     ;; is on it.** `here` is the MARK; `item-row` is the STOP.
                     (when item-row (vector-push-extend first-line stop-lines))
                     (when item-row (incf at))))
      (emit nil)
      (when (and *todos-hide-done*
                 (some (lambda (r) (getf r :item)) rows)
                 (notany (lambda (r) (and (getf r :item) (not (%todo-row-hidden-p r)))) rows))
        (emit (list (cons "    every item here is done — h shows them." '(:dim t)))))
      (emit (list (cons "  space ticks one line of that file, in place; it is not the board the model is reminded of."
                        '(:dim t))))
      ;; **THE KEY TEACHES ITSELF HERE AND NOT ONLY IN `/help`.** A mode nobody can find is a mode
      ;; that does not exist, and this line says which STATE it is in as well as which key changes it.
      (emit (list (cons (if *todos-hide-done*
                            "  done items are hidden — h shows them again."
                            "  h hides the done ones.")
                        '(:dim t)))))
    (values (nreverse out)
            (if (or (zerop (length stop-lines)) (zerop n)) 0 (aref stop-lines sel))
            stop-lines)))

(defvar *peeked-session* nil
  "The subagent whose scrollback `head-peeked` holds — for the title. A defvar
beside the slot rather than a second slot: a struct layout change is a restart.")

(defvar *peeked-dropped* 0
  "How many of that subagent's events fell off the daemon's ring before the read.")

(defvar *peeked-snapshot* nil
  "The ROWS a peek answered with, when the daemon sends them — else NIL.

**A `Peeked` MAY CARRY A SNAPSHOT NOW** (letibot `1520bb5`): a defaulted field on a frame the head
already sends, so no protocol bump and an older daemon is unaffected. That field is what lets this head
draw a child with the SAME renderer as any session — markdown, air rule, tool cards, the rung —
instead of hand-drawing a ring of events nobody may fold (*for reading, NOT FOR FOLDING INTO THE
HEAD'S STATE*, `Peeked`'s own docstring).

**ABSENT ROWS ARE NOT AN ERROR, and the fallback SAYS SO.** The shape is OPT-IN: a peek that asks for
rows gets a snapshot and an empty ring, and one that asks for events gets the ring and no rows — by
design, and not by absence. A daemon older than the field answers an `Events` request whatever the head
asked for, which is the same absent-means-old rule every field on this wire keeps. So the pane says which
rendering the reader is looking at rather than drawing a degraded one that looks plain.
See `peek-lines`, where the reader is looking.

A `defvar` and not a head slot, for the reason all live state is: a struct change is a restart.")

(defvar *peek-render-head* nil
  "A scratch head for drawing a peeked session's rows, kept so one child costs one head.

Rebuilt whenever the pane opens on a different child, and drawn under `with-replay-globals` so the
child's frame cannot touch the globals the MAIN view is built from — the history cache, the scroll
anchor, the depth high-water. Without that, scrolling a child and coming back would leave the parent
anchored to the child's row.")

(defun peeked-rows-p ()
  "Did the last peek answer with ROWS?"
  (and *peeked-snapshot* (getf *peeked-snapshot* :items) t))

(defun subagent-out-lines (events &key (payloads t))
  "A subagent's scrollback as the reference draws it (`subagent_out_lines`,
letibot `2ac6200`): every tool result as `· name — outcome` over its payload, and
the model's ANSWER text in order beside them — a `digest` subagent calls no tools
by design and its whole product is prose, and the pane that drew only tool results
told the operator there was nothing (*\"when i enter - no output\"*). Reasoning
stays out: it is the model thinking rather than its answer. Spills are listed at
the end, so the full output is one path away.

**AND THIS FUNCTION IS A COPY, WHICH IS THE THING TO FIX RATHER THAN IMPROVE.** It exists because
`Peeked` hands back a ring of EVENTS and says what they are for — *these events are for reading, NOT
FOR FOLDING INTO THE HEAD'S STATE* — so a head holding a peek has nothing it may fold and nothing to
do but draw the events by hand. That is `sub_out_lines` (letibot `app.rs:12682`, `out.push(l.clone())`)
and this is its copy; two head-local renderers for one conversation is the drift this pair has now hit
five times in two days.

**A CHILD IS A SESSION**, and the door that returns rows already exists: `SessionEvent::Subagent`'s
`subagent_id` is documented as *the subagent's own session id*, and `Attach`/`Resync` with
`since_seq = 0` answers with a `Snapshot` — rows, which this head draws with its real renderer,
markdown and air rule and rung and all.

**AND THE REASON A HEAD DOES NOT SIMPLY ATTACH TO ONE IS FIVE LINES THAT HIDE IT.** The operator, on
being read a plan that made a child something to *view*: *\"why readonly? subagent session is more like
you driving others via tmux. I already can post to subagent, and agent can talk back and forth too.\"*
A child is attachable, promptable and answers — this session's own relationship with the head it is
spoken through, one level down — and both heads filter sub-sessions out of the picker
(`head.lisp:1053`, `session.lisp:382`, `panes.lisp:77` here; two sites in letibot), with
`chrome.lisp:363` stating the belief out loud: *a subagent is not a session a picker lists*. That
belief is the bug, and **this function is its downstream scaffolding — it is deleted rather than
taught**, together with `Peek`'s special verb if letibot judges it no longer earns its place.

**Do not fold these events into a scratch session** — that would fold what the protocol says must not
be folded, and it would be the sixth copy of a session that was hidden by five lines.

**AND THE CHILD'S TASK IS THE FIRST THING IN IT, in full.** The operator, reading the pane:
*\"the first prompt is truncated too early\"* and *\"I want to be able to easily see it in full\"*.
MEASURED, and the truncation is not this head's: the daemon publishes the `Subagent` event's
`prompt` as `derive_title(prompt)` — `harness.rs:7177` — **the subtask's FIRST LINE**, because the
field doubles as the picker's title, and on the finishing event it publishes the child's *answer's*
first line instead (`publish(\"done\", &first_line)`). So the pane's row can only ever show a title
and, once the child is done, not even the task. **The transcript read is the only place the task
survives**, and this function was dropping it: the child's own `user` row is drawn here now, wrapped
by the caller like everything else, so the question is above its answer where it belongs.

**AND THE RUNG GOVERNS IT**, because this is a view and view rules are the rung's: with `:payloads`
NIL the answers are still drawn and the tool payloads are held back behind a seam that counts them —
the same question the transcript asks a committed row (`reading-p`), asked of a conversation that is
not the session's own. `peek-lines` passes it, so the pane follows `:reading` like every other view."
  (let ((out nil) (spills nil) (hidden 0))
    (flet ((emit (text) (push text out)))
      (dolist (env events)
        (case (event-name env)
          ((:transcript-content)
           (let ((item (getf env :item)))
             (when item
               (switch ((getf item :type) :test #'string=)
                 ("user"
                  ;; **THE TASK, WHICH THE EVENT'S `prompt` ONLY EVER CARRIED AS A TITLE.** Both user
                  ;; shapes the wire uses: `:text`, and `:parts` for a row the daemon built from
                  ;; fragments.
                  (let ((text (or (getf item :text)
                                  (getf (first (getf item :parts)) :text))))
                    (when (and text (plusp (length (string-trim " " text))))
                      (emit (format nil "▌ ~a" text))
                      (emit ""))))
                 ("tool_result"
                  (emit (format nil "· ~a — ~a" (getf item :name)
                                (%outcome-word (outcome-name (getf item :outcome)))))
                  (let ((rows (%payload-lines (getf item :payload))))
                    (if payloads
                        (dolist (l rows) (emit (format nil "  ~a" l)))
                        (incf hidden (length rows))))
                  (emit ""))
                 ("assistant"
                  (let ((text (or (getf item :text) "")))
                    (when (plusp (length (string-trim " " text)))
                      (dolist (l (uiop:split-string text :separator '(#\newline)))
                        (emit l))
                      (emit ""))))))))
          ((:tool-finished)
           (awhen (getf env :spill) (push it spills)))))
      (when (plusp hidden)
        (emit (format nil "  … +~d line~:p at a higher rung · /verbosity" hidden)))
      (when spills
        (emit "full output on disk:")
        (dolist (sp (nreverse spills)) (emit (format nil "  ~a" sp)))
        (emit "")))
    (nreverse out)))

(defvar *peek-total* 0
  "How many LINES the peek pane has in total, header and footer included — what
`*pane-lines*` must be set to for this pane, so `pane-scroll-max` clamps against
the whole read and not against the window drawn from it. Set by `peek-lines`,
which is the only place the wrapped total is known.")

(defvar *peek-spill* nil
  "`(KEY . PATH)` for the scrollback already written to disk, so one peek is
written once however many frames draw it. KEY is the subagent and the number of
lines, which is what changes when a running subagent produces more.")

(defun peek-spill-path (session-id)
  "Where a peeked subagent's whole scrollback goes — the reference's
`spill_sub_out` (app.rs:8025-8060), which writes
`<runtime>/letibot/subagent-<id>.log` and names it in the pane's footer.

`<runtime>/leticl/` rather than `letibot/` on purpose: two heads writing one
path would each claim the other's file, and the footer's whole job is to name a
file the operator can open and trust."
  (format nil "~a/leticl/subagent-~a.log" (runtime-dir) session-id))

(defun spill-peek (session-id lines)
  "Write LINES for SESSION-ID and return the path, or NIL when it could not be
written — the reference returns `None` the same way and the footer then says
`not written`. A pane that promises a file it did not write is worse than one
that promises nothing.

Written from the DRAW rather than from the frame that built the view, which is
where the reference writes it: the arm that folds a `peeked` frame is in
`src/head.lisp` and belongs to another strand. Idempotent through `*peek-spill*`,
so the cost is one write per peek and not one per frame."
  (let ((key (cons session-id (length lines))))
    (if (equal (car *peek-spill*) key)
        (cdr *peek-spill*)
        (let ((path (ignore-errors
                     (let ((p (peek-spill-path session-id)))
                       (ensure-directories-exist p)
                       (with-open-file (out p :direction :output
                                              :if-exists :supersede
                                              :if-does-not-exist :create
                                              :external-format :utf-8)
                         (dolist (l lines) (write-line l out)))
                       p))))
          (setf *peek-spill* (cons key path))
          path))))

(defun peek-row-count (head)
  "How many BODY lines the peek pane has — what `pane-row-count` should answer
for `:peek`, where `src/editor.lisp:749` answers 0.

That zero is the whole of the pane's arrow keys: `move-cursor` clamps the cursor
to `(1- 0)` and Up and Down move nothing, while the pane's own last line
advertises that they scroll. The count is the body's, not the rendered pane's,
because the header and the footer are not rows a cursor may land on."
  (declare (ignorable head))
  (length (subagent-out-lines (head-peeked head))))

(defun pane-escape-target (mode)
  "Where Esc goes from pane MODE — the reference's `sub_out` arm (app.rs:3251-3262)
sits ahead of the generic Esc on purpose: **Esc in the peek pane means back to
the tree, not close everything**. Everywhere else it means `:normal`.

`:job-out` is the same shape one door over: the job-output view is an OVERLAY
over the jobs list, not a replacement for it, so Esc goes back to the list the
row was chosen from — *\"and Esc returns to the jobs list, which never closed\"*
(letibot `3aabe4f`). The list itself survives because `head-jobs` and
`head-picker-sel` are untouched while the overlay is up.

The key itself is dispatched in `src/editor.lisp:242`, which sends every pane to
`:normal`; this is the fact that arm needs and the one line it is missing."
  (case mode
    (:peek :subagents)
    (:job-out :jobs)
    (t :normal)))

;;; ---------------------------------------------------- the slash listing ;;;
;;;
;;; **A verb's answer, when it is a listing rather than a sentence.**
;;;
;;; `/tools`, `/gate recent`, `/flowy status` and `/models` all answer through the
;;; daemon under one warning code, `slash`, and until this existed every one of them
;;; landed as a note on the session log and scrolled away. The reference splits them by
;;; the only thing that distinguishes them — the reply's length — and opens a pane for
;;; anything past three lines (app.rs:3266-3275, `app.rs:5873-5880`).
;;;
;;; **This is the third instance of a shape this head already had twice, and that is the
;;; point.** A pane whose content does NOT come from the session is a `defvar` holding
;;; what arrived plus a mode that draws it: `*peeked*`/`:peek` and `*job-out*`/`:job-out`
;;; are the first two. Adding `:slash` is not a third hand-rolled pane — it is the
;;; existing overlay shape applied to a reply that had nowhere to go, and the two axes
;;; are independent enough to say out loud:
;;;
;;;   · **where the CONTENT comes from** — the session (a pure function of it, like
;;;     `:help` and `:config`) or a `defvar` holding what a reply brought (`:peek`,
;;;     `:job-out`, `:slash`);
;;;   · **which END it is read from** — a document you read from the top (`pane-view`,
;;;     head-first) or a log whose newest line matters (`:peek` and `:job-out`, which
;;;     window tail-first and clamp their own scroll).
;;;
;;; A slash listing is the first of one and the first of the other: content that arrived,
;;; read from the top. So there is no new machinery here — a defvar, a mode, `pane-view`
;;; and `pane-row-count` — and the question a reader should ask of the NEXT pane is
;;; which corner it sits in, not how to write it.

(defvar *slash-out* nil
  "The open slash listing: a cons `(ECHO . LINES)`, or NIL.

ECHO is the command the daemon echoed back — drawn BOLD, because a listing with no
memory of what was typed is a listing you cannot place. LINES is its body, already
stripped of control characters, one string per line.

A `defvar` and not a head slot: a struct layout change is a restart, and this has to
be reachable from a push. Bound by `with-replay-globals`.")

(defun close-slash-out ()
  "Close the listing. T when there was one."
  (let ((had (and *slash-out* t)))
    (setf *slash-out* nil)
    (reset-pane-scroll)
    had))

(defparameter +slash-listing-lines+ 3
  "How long a slash reply has to be before it is a LISTING and opens a pane.

The reference's `lines.len() > 3` (app.rs:3271). It is a length and not a marker
because the daemon sends both kinds under one code — `detail` is the command echoed
back, then the reply — so length is the only thing that distinguishes `/tools`'s table
from `mode → allow-all`'s sentence. A constant with a citation rather than a taste.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a
constant could never be changed on a running head.")

(defun %slash-reply-split (detail)
  "DETAIL as `(values ECHO LINES)`: the echoed command and the reply's body.

The daemon's format is the command, a newline, then the reply (app.rs:3268-3270), so
the first line is the echo and the rest is the body. A detail with NO newline is a
sentence — an echo and an empty body — which is how the caller ends up with 0 lines and
leaves it as a note."
  (let* ((nl (position #\newline (or detail "")))
         (echo (if nl (subseq detail 0 nl) (or detail "")))
         (body (if nl (subseq detail (1+ nl)) "")))
    (values echo (mapcar #'%without-control (uiop:split-string body :separator '(#\newline))))))

(defun note-slash-reply (detail)
  "Open the listing when DETAIL is long enough to be one. T when it opened.

Called from the warning arm, which is where this arrives: the daemon publishes a slash
reply as a `Warning` with code `slash` (or `slash_refused`), so a head that only pushes
warnings to a list has every verb's output in the log and none of it on a screen."
  (multiple-value-bind (echo lines) (%slash-reply-split detail)
    ;; a trailing empty line is the daemon's terminator, not a row: the reply is
    ;; `str::lines`' shape, and a pane one row longer than the text is a pane with a
    ;; blank at the end that reads as content
    (when (and lines (zerop (length (car (last lines)))))
      (setf lines (butlast lines)))
    (when (> (length lines) +slash-listing-lines+)
      (setf *slash-out* (cons echo lines))
      (reset-pane-scroll)
      t)))

(defun slash-out-lines (head cols &optional room)
  "The listing: the echoed command, its body, and how to leave.

    /tools
    <blank>
    read  failed  1.2s  read a file
    …                    (wrapped at COLS)
    <blank>
        esc closes · up/down scrolls

**The footer names the keys that WORK**, which is the rule every pane here keeps: the
arrows scroll, esc closes, and a footer that named a key the pane did not take is the
defect this repo has now found four times (the seam that named `ctrl-t` with the fold
already open was the last one). `q` closes it too, and is not named — the reference's
footer names esc alone (app.rs:5878).

The body is WRAPPED rather than truncated: a listing is prose an operator reads to the
end, and `/gate recent`'s rows are sentences, so a cut line costs the reason."
  ;; ROOM is accepted and unused, like `help-lines`: this listing does not window
  ;; itself. `pane-view` does that, head-first, with `*pane-lines*` set from this
  ;; list's length — the same division every document pane here uses.
  (declare (ignorable head room))
  (let* ((echo (or (car *slash-out*) ""))
         (lines (or (cdr *slash-out*) nil))
         (w (pane-width cols))
         (out (list (list (cons echo '(:bold t))) nil)))
    (dolist (l lines)
      (dolist (row (or (wrap-segments (list (cons l nil)) w) (list nil)))
        (push row out)))
    (push nil out)
    (push (list (cons "    esc closes · up/down scrolls" '(:dim t))) out)
    (nreverse out)))

(defun slash-out-row-count (head)
  "How many rows the listing has for its arrows to walk — 0, and that zero is the
same fact `peek-row-count` records: this pane has no CURSOR, so Up and Down scroll it.
`pane-row-count` answering a positive number here would clamp a cursor to rows nobody
can select and leave the pane unscrollable."
  (declare (ignorable head))
  0)

;;; ------------------------------------------------------------- the notes ;;;
;;;
;;; R10's reader: what this head has warned about, and how to retire one. The listing
;;; is a slash listing — content that arrived, read from the top — so it is
;;; `*slash-out*` and `:slash`, not a pane of its own.

(defun warning-listing-lines (session)
  "The `/notes` listing: every warning this head holds, in the order the conversation
has them, numbered for `/notes dismiss N`.

**The whole text, not the fold.** A listing that hid the tail of the very thing it
exists to make findable would be the defect it is the answer to; the reference
renders it with the transcript's own unfolded renderer for the same reason
(app.rs:5860-5864). Lines come back UNWRAPPED — the slash pane wraps at its own
width, and wrapping here as well would wrap twice."
  (let* ((ws (warning-order session))
         (held (length ws))
         (retired (count-if (lambda (w) (session-retired-p session w)) ws))
         (out (if (zerop held)
                  (list "this head holds no warnings. A warning is the daemon's own \
sentence about this session — a compaction, a context wall, an interrupted turn — and \
the session log holds it whether or not this head is showing it.")
                  (list (format nil "~d warning~a, ~d retired — the log holds the durable \
fact and this head shows it once"
                                held (if (= held 1) "" "s") retired)))))
    (loop for w in ws
          for i from 1
          do (push (format nil "~3d  ~a" i
                           (if (session-retired-p session w) "[retired]" ""))
                   out)
             (push (format nil "~a ~a" (warning-glyph w) (warning-note-text w)) out))
    (when (plusp held)
      (push "" out)
      (push "/notes dismiss [N|all] retires one, or every one · /notes restore brings them all back"
            out))
    (nreverse out)))

(defun open-notes-listing (session)
  "Open the `/notes` listing in the slash pane. T when there is a listing.

Fills `*slash-out*` and does NOT touch the mode: the mode is head state, and the one
thing the head has to do with what arrived here is the same thing it does with a
listing the daemon sent — follow the state after the fold (`head.lisp:495-497`)."
  (setf *slash-out* (cons "/notes" (warning-listing-lines session)))
  (reset-pane-scroll)
  t)

(defun notes-listing-open-p ()
  "Is the listing on the screen the NOTES one? Used to decide whether a retirement
should redraw it: a daemon slash reply that happens to be up is not this head's to
replace."
  (and (consp *slash-out*) (equal (car *slash-out*) "/notes")))

;;; ------------------------------------------------- the job-output overlay ;;;

(defvar *job-out-total* 0
  "How many LINES the job-output overlay has in total, header and footer
included — what `*pane-lines*` must be set to for this pane, so `pane-scroll-max`
clamps against the whole window and not against the slice drawn from it. Set by
`job-out-lines`, which is the only place the total is known. The same arrangement
`*peek-total*` has, for the same reason.")

(defun open-job-out (job)
  "Open the job-output overlay on JOB, empty and waiting.

Opened at the KEYPRESS, before any answer: the pane says `reading…` rather than
showing nothing, and — the part that matters — `apply-event` takes a `JobOutput`
window only when an overlay is open for that job, so the overlay has to exist
before the frame goes out or this head would drop its own answer.

**`:answered` starts NIL and `:loading` starts T, and the two are not the same
fact** (R41): one means *a read is in flight*, the other *one has come back*. The
pane says `reading…` on the first and only the first, so an answer of ZERO BYTES
stops being indistinguishable from an answer that never came."
  (setf *job-out* (list :job job :state "" :never-ran nil :from 0 :to 0 :produced 0
                        :dropped 0 :lines nil :next nil :back nil :loading t
                        :answered nil :error nil))
  (reset-pane-scroll)
  *job-out*)

(defun close-job-out ()
  (setf *job-out* nil)
  (reset-pane-scroll))

(defun job-out-body (&optional (view *job-out*))
  "The overlay's BODY lines — the window the daemon sent, control characters
neutralised (`%without-control`): a job's output is whatever the command wrote,
escape sequences included, and a pane that repaints one hands the operator's
terminal to a build log."
  (mapcar #'%without-control (getf view :lines)))

(defun job-out-row-count (head)
  "How many lines the overlay has for its arrows to walk — what `pane-row-count`
answers for `:job-out`. The BODY's, not the rendered pane's: the header and the
footer are not rows a cursor may land on. Same as `peek-row-count`, and for the
same measured reason — a pane that answers 0 here has its arrows clamped to
`(1- 0)` while its own last line advertises that they scroll."
  (declare (ignorable head))
  (length (job-out-body)))

(defun job-out-lines (head cols &optional room)
  "One background job's retained output — the reference's `job_out_lines`
(app.rs:6828-6938), which is the pane the operator asked for: *\"on the job pane
when i press enter im not shown the tailed job output but brought back to the
conversation with /job <id> sent\"*.

    job output — j3
        exited 0 — bytes 0..16384 of 40000 (512 earlier bytes gone off the front)

        line one
        …
        arrows scroll · → next page · ← back · Esc to jobs

**The header is built from the OFFSETS, not from a parsed sentence.** That is the
whole of why the read is a `JobOutput` event and not the `Warning` `/job` replies
with: `/job`'s footer says `[exited 0 — bytes 0..16384 of 40000 produced]` in
prose a pane would have to take apart, and this arrives as numbers beside the
text (event.rs on `SessionEvent::JobOutput`).

`dropped` is disclosed in the HEADER rather than the footer: a window that begins
mid-log is otherwise read as the job's beginning, and that is a lie about what the
job did, not a detail about paging.

A TERMINAL, NOT A DOCUMENT, like `peek-lines`: the TAIL shows by default and the
scroll is clamped HERE, where the visible height is actually known. ROOM is the
rows the frame gave the pane; without it (a test) the whole thing comes back
unwindowed, which is the shape every other pane has."
  (declare (ignorable head))
  (let* ((view *job-out*)
         (job (or (getf view :job) "?"))
         (w (pane-width cols))
         (head-rows (list (list (cons (format nil "job output — ~a" job) '(:bold t))))))
    (cond
      ;; **A refusal is not a window.** The daemon could not answer — a job that
      ;; fell out of the exec host's table between the listing and Enter — so the
      ;; pane says what it said, rather than drawing an empty log the operator
      ;; would read as "the job wrote nothing".
      ((getf view :error)
       (let ((rows (append head-rows
                           (list (list (cons "    the daemon refused this read:" '(:dim t)))
                                 nil)
                           ;; WRAPPED, not truncated: a refusal is prose the
                           ;; operator has to read to the end — the window above
                           ;; is a log and a cut line there costs a byte, while a
                           ;; cut sentence here costs the reason
                           (mappend (lambda (l)
                                      (or (wrap-segments (list (cons l nil)) w)
                                          (list nil)))
                                    (uiop:split-string (getf view :error)
                                                       :separator '(#\newline)))
                           (list nil
                                 (list (cons "    Esc back to jobs" '(:dim t)))))))
         (setf *job-out-total* (length rows))
         rows))
      (t
       (let* ((dropped (or (getf view :dropped) 0))
              ;; **which page keys ACT, from the one function that answers it** — the
              ;; bottom row was promising `→ next page · ← back` for a job with neither
              ;; (R41); see `job-out-pages`.
              (pages (job-out-pages view))
              (meta
                ;; NIL defaults throughout, and a NIL view reads as `reading…`:
                ;; this pane draws from a plist the daemon fills a field at a
                ;; time, and a header that says `NIL — bytes NIL..NIL` is a
                ;; render fault dressed as a measurement.
                ;;
                ;; **`reading…` is `(not :answered)`, and that is R41's whole
                ;; finding: ZERO BYTES IS AN ANSWER.** The rule used to be
                ;; `:loading` AND an empty state word, which is a guess at arrival
                ;; made out of two things that are not arrival — a re-read sets
                ;; `:loading` again on a pane that has ALREADY been told what it
                ;; needs to know, and the state word is non-empty from the moment
                ;; the first answer lands, so it can only answer *have I ever been
                ;; answered*, never *is this window the one I am waiting for*. Keyed
                ;; on the arrival, a pane that has heard `running, 0 bytes` keeps
                ;; saying so — including while it waits for the next page.
                (if (not (getf view :answered))
                    "    reading…"
                    ;; the state and the measurement on ONE line, because they are
                    ;; one fact: what the job is, and what window of how much is on
                    ;; the screen
                    (format nil "    ~a — bytes ~d..~d of ~d~@[~a~]"
                            (getf view :state) (or (getf view :from) 0)
                            (or (getf view :to) 0) (or (getf view :produced) 0)
                            (when (plusp dropped)
                              (format nil " (~d earlier byte~:p gone off the front)"
                                      dropped)))))
              (body (job-out-body view))
              (shown
                (or body
                    ;; **THE EMPTINESS SENTENCE IS THE DAEMON'S OWN CONDITION: `produced == 0`.**
                    ;; Not *the window holds no lines* — that is the window's SHAPE, and the two
                    ;; come apart the moment a window holds nothing while the job HAS produced
                    ;; bytes (a read at an offset past the end, a window the ring dropped
                    ;; entirely). Called `produced > 0` with nothing in hand, `it wrote nothing at
                    ;; all.` is a lie about the job, and it is §11.6's own R17 inversion one case
                    ;; over: *a row with no output must not look like a row whose output is
                    ;; empty*. The daemon draws the line in exactly this place —
                    ;; `harness.rs:3746`, `if slice.produced == 0` — and a head that keyed it on
                    ;; the window would disagree with the daemon about the same job.
                    (when (and (getf view :answered)
                               (zerop (or (getf view :produced) 0)))
                      ;; **AND IT IS DRAWN FROM WHAT WE HAVE BEEN TOLD, not from whether a
                      ;; read is in flight** (R41): the window's emptiness is a fact the
                      ;; last answer settled, so a page re-read must not take the sentence
                      ;; away. Measured, it drew a header with NOTHING under it — which is
                      ;; the blank the operator read as *waiting for the output*, and the
                      ;; same shape as a log whose every line is whitespace.
                      ;;
                      ;; **A job that never ran is not a job that wrote nothing**
                      ;; (§11.6, letibot `e1cd2b0` — *A rules the words; both heads
                      ;; render the same string*).
                      ;;
                      ;; An empty window is TWO facts and this head had ONE sentence
                      ;; for them: `it wrote nothing at all.` under a header reading
                      ;; `not run (could not join its scope)`, which is the operator's
                      ;; own R17 rule inverted — *a row with no output must not look
                      ;; like a row whose output is empty*. The case is chosen by the
                      ;; daemon's `never-ran` FIRST, because the window's emptiness
                      ;; cannot carry the difference; `running` is still read off the
                      ;; state word, which is the daemon's own spelling of the state
                      ;; it holds (`JobState::word`), tested literally for the same
                      ;; reason the jobs pane tests `exited 0` literally: the head
                      ;; renders the daemon's vocabulary and keeps no second copy of
                      ;; the enum. An unfamiliar state word falls to `wrote nothing`,
                      ;; which is letibot's own choice and is pinned there by a test
                      ;; that names every variant.
                      (list (cond ((getf view :never-ran)
                                   ;; **The one sentence of this fix that is not the
                                   ;; daemon's**, and it is written in full so the two
                                   ;; heads cannot hold two sentences about one state.
                                   "    it never ran, so there is nothing it could have written.")
                                  ((equal (getf view :state) "running")
                                   "    it is running and has written nothing yet.")
                                  (t
                                   "    it wrote nothing at all."))))))
              (top (append head-rows
                           (list (list (cons meta '(:dim t))) nil)))
              (wrapped (mappend (lambda (l)
                                  (or (wrap-segments (list (cons l nil)) w) (list nil)))
                                shown))
              ;; The footer names only the keys that DO something here. `→` with
              ;; no `next` would promise a page that does not exist and `←` at the
              ;; front of the log a page before the first byte.
              (footer
                (list nil
                      (list (cons (format nil "    ~a"
                                          (cond ((and (getf pages :next) (getf pages :back))
                                                 "arrows scroll · → next page · ← back · Esc to jobs")
                                                ((getf pages :next)
                                                 "arrows scroll · → next page · Esc to jobs")
                                                ((getf pages :back)
                                                 "arrows scroll · ← back · Esc to jobs")
                                                (t "arrows scroll · Esc to jobs")))
                                  '(:dim t))))))
         (if (null room)
             (append top wrapped footer)
             (let* ((visible (max 1 (- room (length top) (length footer))))
                    (total (length wrapped))
                    (max-scroll (max 0 (- total visible)))
                    (scroll (min (max 0 *pane-scroll*) max-scroll))
                    (end (- total scroll))
                    (start (max 0 (- end visible))))
               (setf *pane-scroll* scroll
                     *job-out-total* (+ (length top) total (length footer)))
               (append top
                       (subseq wrapped start end)
                       ;; pad, so the footer sits on the pane's last row rather
                       ;; than floating under a short window
                       (make-list (max 0 (- visible (- end start))))
                       footer))))))))

(defun %peek-snapshot-pane (head cols room)
  "The peeked child's rows, drawn by the renderer that draws the conversation.

**ONE RENDERER, NOT TWO.** A peek can answer with the session's ROWS when it asks for them
(`PeekShape::Rows`, letibot `1520bb5`), and a snapshot is a session's rows — so this builds a session from it and calls `%viewport-lines`, the function every
frame of the main conversation comes through. Markdown, the air rule, the tool cards, the rung and the
seams are all its, by construction rather than by imitation; `subagent-out-lines` is left to the path
where no rows arrived.

**Under `with-replay-globals`**, because that renderer reads globals the MAIN view owns — the history
cache, the scroll anchor, the depth high-water — and a child drawn inside them would leave the parent
anchored to the child's row. The scratch head is kept for the child it was built for, so opening one
child costs one head rather than one per frame.

**The dropped count STAYS.** A snapshot can be short the same way the ring could — the daemon bounds a
view by count and by bytes — and a truncated read that renders as a complete one is the `Abstained`
defect in another costume.

`*pane-scroll*` is the child's scroll and `*peek-total*` its whole length: the pane measures off the
BOTTOM (the tail is the origin, the reference's own `v.scroll`), which is what `head-scroll` 0 means,
so the two agree without a conversion."
  (let* ((snapshot *peeked-snapshot*)
         (id (getf snapshot :session-id))
         (head-lines (append
                      (list (list (cons (format nil "subagent output — ~a"
                                                (if id (short-id id) "?"))
                                        '(:bold t))))
                      (when (plusp *peeked-dropped*)
                        (list (list (cons (format nil "    ~d earlier event~:p fell off the daemon's scrollback before this read"
                                                  *peeked-dropped*)
                                          '(:dim t)))))
                      (list nil)))
         (footer (list nil
                       (list (cons "    arrows scroll · esc back · the same renderer as any session"
                                   '(:dim t)))))
         (room (max 8 (or room 40)))
         (visible (max 1 (- room (length head-lines) (length footer))))
         (scratch (let ((h *peek-render-head*))
                    (if (and h id (equal (session-session-id (head-session h)) id))
                        h
                        (let ((h (%make-head)))
                          (setf *peek-render-head* h)
                          h))))
         (s (head-session scratch)))
    (ingest-snapshot s snapshot)
    (when id (setf (session-session-id s) id))
    (setf (head-cols scratch) cols
          (head-rows scratch) room
          (head-prefs scratch) (head-prefs head)
          (head-scroll scratch) (max 0 *pane-scroll*))
    (let ((lines (call-with-replay-globals
                  (lambda ()
                    (let ((*scroll-max* 0))
                      (prog1 (%viewport-lines scratch cols visible)
                        (setf *peek-total* (+ (length head-lines) *scroll-max* visible (length footer))
                              *pane-scroll* (head-scroll scratch))))))))
      (append head-lines
              lines
              ;; pad, so the footer sits on the pane's last row rather than floating under a short read
              (make-list (max 0 (- visible (length lines))))
              footer))))

(defun peek-lines (head cols &optional room)
  "A peeked subagent's scrollback — the reference's `sub_out_lines`
(app.rs:6844-6892): the title names the subagent, a dropped count when the ring
lost events before the read, then the output, and the empty case SAYS what it
means — *neither an answer nor tool output* — and names the two reasons that can
be true of, because \"no tool output\" reads as a fault for a subagent that was
never going to produce any.

**A TERMINAL, NOT A DOCUMENT**, which is what it was not. The reference shows the
TAIL by default and clamps the scroll *here*, where the visible height is
actually known — `a key handler cannot clamp what it cannot see`. Ours returned
every line and let the generic pane window take the TOP of it, so opening a
subagent that had produced two hundred lines showed its first screenful and the
answer, which is at the end, was off the bottom.

ROOM is the rows the frame gave the pane. Without it (a test, `%pane-head`) the
whole thing comes back unwindowed, which is the shape every other pane has.

`*pane-scroll*` counts lines hidden **off the BOTTOM** for this pane — the
reference's own `v.scroll` — because the tail is the origin here and everything
else is measured back from it.

The footer names the SPILL FILE, which had no counterpart at all: the pane
advertised three keys and a full copy on disk, and the copy was never written."
  ;; **A SNAPSHOT IS DRAWN BY THE REAL RENDERER** — see `%peek-snapshot-pane`. Everything below is the
  ;; path for a daemon that answers a peek with events and no rows, and that path SAYS which it is.
  (when (peeked-rows-p)
    (return-from peek-lines (%peek-snapshot-pane head cols room)))
  (let* ((events (head-peeked head))
         ;; **THE RUNG GOVERNS THIS VIEW TOO** — see `subagent-out-lines`: at `:reading` the child's
         ;; answers are drawn and its tool payloads are held behind a seam, which is the same question
         ;; the transcript asks a committed row.
         (body (subagent-out-lines events :payloads (not (reading-p))))
         (spill (and body *peeked-session* (spill-peek *peeked-session* body)))
         (shown (or body
                    (list "    this subagent's scrollback has neither an answer nor tool output. It may still be running, or its rows may have fallen off the daemon's ring.")))
         (head-rows (append
                     (list (list (cons (format nil "subagent output — ~a"
                                               (if *peeked-session* (short-id *peeked-session*) "?"))
                                       '(:bold t))))
                     (when (plusp *peeked-dropped*)
                       (list (list (cons (format nil "    ~d earlier event~:p fell off the daemon's scrollback before this read"
                                                 *peeked-dropped*)
                                         '(:dim t)))))
                     ;; **SAID, because a degraded render must not look like a plain one.** This daemon
                     ;; answered the peek with events and no rows — older than the field, or a path that
                     ;; did not ask — so the child is hand-drawn by `subagent-out-lines` rather than by
                     ;; the renderer the conversation uses.
                     (list (list (cons "    drawn from the event list — no rows came back for this peek (a daemon older than `PeekShape::Rows`, or a caller that asked for events)"
                                       '(:dim t))))
                     (list nil)))
         (wrapped (mappend (lambda (l) (or (wrap-segments (list (cons l nil)) (pane-width cols))
                                           (list nil)))
                           shown))
         (footer (list nil
                       (list (cons (format nil "    arrows scroll, Enter re-reads, Esc back — full: ~a"
                                           (or spill "not written"))
                                   '(:dim t))))))
    (if (null room)
        (append head-rows wrapped footer)
        ;; the tail, clamped where the height is known
        (let* ((visible (max 1 (- room (length head-rows) (length footer))))
               (total (length wrapped))
               (max-scroll (max 0 (- total visible)))
               (scroll (min (max 0 *pane-scroll*) max-scroll))
               (end (- total scroll))
               (start (max 0 (- end visible))))
          (setf *pane-scroll* scroll
                *peek-total* (+ (length head-rows) total (length footer)))
          (append head-rows
                  (subseq wrapped start end)
                  ;; pad, so the footer sits on the pane's last row rather than
                  ;; floating under a short read
                  (make-list (max 0 (- visible (- end start))))
                  footer)))))

;;; ------------------------------------------------------------ pickers ;;;
;;;
;;; The MODE and MODELS pickers, to the reference's shape (`mode_picker_lines`,
;;; app.rs): a CARD above the composer with the transcript still visible, not a
;;; full-body pane — the operator, looking at ours: *"in letibot it is not a full
;;; pane"*. Both read their choices from the daemon's own settings rows
;;; (`SettingRow.choices`, protocol 18), so the head keeps no list to drift.
;;;
;;; One flag for both, one cursor (`head-picker-sel`), one drawing, because the
;;; one thing this file has already been burned by is a second copy of a list that
;;; then drifts. The flag is a defvar: a head slot is a struct layout change, which
;;; is a restart.

(defvar *pick-unseeded* nil
  "Has the picker's cursor been placed by US, with nobody having moved it yet?

T when `open-pick` could not compute the seed — its list had not arrived — so the settings arm may
place it once the rows land, and any key that moves the cursor clears it so a move the operator made
is never overwritten. Reset by `close-pick` and by `with-replay-globals`.")

(defvar *pick-open* nil
  "Which picker is up: NIL, `:mode`, `:model` or `:verbosity`.

**Three, and `:verbosity` joined last** (R38). It is the same card and the same keys rather than a
fourth mechanism, because the requirement's own words are *one picker vocabulary per head, not a
third*: a reader who has chosen a mode has learned how to choose a verbosity.")

(defvar *mode-confirm* nil
  "The mode name awaiting the operator's [y]/[enter], or NIL. `allow-all` is the
one mode that asks first — it is the point where privilege escalation, deletes
outside the project and first contact with a new host all stop asking.")

(defun setting-choices (head key)
  "The choices the daemon reports for setting KEY, or NIL.

From the settings rows the head asks for at attach, which is why it asks: a
picker whose list is empty because nobody ever asked the daemon is a picker that
looks broken (P44 in TODO.md is the same bug one layer down)."
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :choices)))

(defun setting-value (head key)
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :value)))

(defun pick-key (which)
  "The DAEMON's settings key a picker reads its choices from, or NIL for a choice that is the
head's own.

**`verbosity` is not a daemon setting**, so it has no key — and that is a fact about which half
owns the value rather than a gap. The mode and the model arrive on rows the daemon publishes; what
this head draws is its own business, so its choices are its own list."
  (ecase which (:mode "mode") (:model "model") (:verbosity nil)))

(defparameter +verbosity-said+
  '(("reading" . "the conversation only — nothing the head did to produce it")
    ("terse" . "the conversation and every tool row")
    ("normal" . "terse, plus the model's reasoning")
    ("loud" . "normal, plus head arrivals and who issued each command"))
  "What each rung MEANS, in the reader's terms — R38's requirement, and the reason this card is not
just a list of names.

*Terse, Normal, Loud and R37's rung are not self-describing*, and a reader is choosing between what
will be on their screen. So each row says what they will see. **The three sentences are letibot's
own** (`Verbosity`'s variant docstrings: *assistant text and tool outcomes only*, *plus reasoning*,
*plus head arrivals and who issued which command*), because a setting spelled differently on two
heads is two settings — and the fourth is this head's, pending the name letibot owes (filed).")

(defun pick-choices (head &optional (which *pick-open*))
  "The rows the picker offers: the daemon's choices for its settings, or this head's own ladder."
  (when which
    (if (eq which :verbosity)
        (mapcar (lambda (v) (string-downcase (symbol-name v))) +verbosity-ladder+)
        (setting-choices head (pick-key which)))))

(defun pick-current (head &optional (which *pick-open*))
  "The choice that answers NOW, as the picker's list spells it: the mode row's
value is `allow-all (this box, consented)` and the list says `allow-all`, so the
first word; the model row's is `local (qwen-3.8-27b)` or `deepseek/…`, and the
list says the bare form the header shows."
  (ecase which
    (:verbosity (verbosity-name))
    (:mode (let ((v (or (setting-value head "mode") "")))
             (subseq v 0 (or (position #\space v) (length v)))))
    (:model (%header-model (or (setting-value head "model") "")))
    ((nil) "")))

(defun %header-model (value)
  "`local (qwen-3.8-27b)` → `qwen-3.8-27b`; anything else as written — the
reference's `header_model`."
  (if (and (alexandria:starts-with-subseq "local (" value)
           (alexandria:ends-with #\) value))
      (subseq value 7 (1- (length value)))
      value))

(defun open-pick (head which)
  "Open the picker for WHICH, seeded on what answers now so enter on an untouched
list is a no-op — the courtesy the reference pays. One list on the screen at a
time: any pane closes."
  (unless (head-settings head) (%send head (make-settings)))
  (setf *pick-open* which
        (head-mode head) :normal
        (head-picker-sel head)
        (or (position (pick-current head which) (pick-choices head which) :test #'string=) 0)
        ;; **THE SEED IS A PROMISE, AND IT CANNOT BE KEPT YET.** The line above is right, and it
        ;; is computed against a list that does not exist the first time — `/mode` asks for the
        ;; settings here and the rows come back a frame later. So the cursor falls to `0`, and
        ;; this flag records that NOBODY HAS CHOSEN IT: the settings arm re-seeds from the real
        ;; list when it arrives, and any key that moves the cursor clears the flag so their own
        ;; choice is never overwritten. See the operator's report — *"mode selectors has selection
        ;; on the first not on the current again"* — in `head.lisp`'s settings arm.
        *pick-unseeded* (null (pick-choices head which))
        (head-dirty head) t))

(defun close-pick (head)
  (setf *pick-open* nil *pick-unseeded* nil (head-dirty head) t))

(defun pick-card-lines (head cols)
  "The picker's card — `mode_picker_lines` row for row: a bold title, each choice
as `▸  1  name` with the cursor's row reversed whole and `← now` at the right of
the one that answers, then the two dim hint rows (three for models)."
  (let* ((models (eq *pick-open* :model))
         (verbosity (eq *pick-open* :verbosity))
         (choices (pick-choices head))
         (current (pick-current head))
         (n (length choices))
         (sel (min (head-picker-sel head) (max 0 (1- n))))
         (w (max 20 cols)))
    (append
     (list (list (cons (cond (models "what answers this conversation")
                             (verbosity "what the transcript shows")
                             (t "the mode this session runs under"))
                       '(:bold t))))
     (unless choices
       (list (list (cons (cond (models "  this daemon has not named its models — `/models PROVIDER/MODEL` still works, if you know the name.")
                             (verbosity "  no rungs to offer — this head starts at normal")
                             (t "  this daemon has not named its modes — `/mode NAME` still works, if you know the name."))
                         '(:dim t)))))
     (loop for name in choices
           for i from 0
           for here = (string= name current)
           for picked = (= i sel)
           append (let* ((left (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i)) nil)
                                      (cons name (if here '(:bold t) nil))))
                          (right (if here (list (cons "← now" '(:dim t))) nil))
                          ;; the cursor's row is reversed over its TEXT — mark,
                          ;; number, name — and the padding is plain: the
                          ;; reference wraps `left` in REVERSE…RESET before
                          ;; `split_row` pads it. Measured on its raw row.
                          (left (if picked
                                    (mapcar (lambda (seg) (cons (car seg) (append (cdr seg) '(:reverse t))))
                                            left)
                                    left)))
                     (cons (split-row left right w)
                           ;; **WHAT EACH RUNG MEANS, under its own name** (R38): *Terse, Normal,
                           ;; Loud and R37's rung are not self-describing, and a reader is
                           ;; choosing between what will be on their screen.* Drawn as a sub-row
                           ;; in the dim register so the list still reads as a list of CHOICES —
                           ;; the mark, the number and the name are the row, and the sentence is
                           ;; its gloss.
                           (when verbosity
                             (list (list (cons (format nil "       ~a"
                                                       (or (cdr (assoc name +verbosity-said+
                                                                       :test #'string=))
                                                           ""))
                                               '(:dim t))))))))
     (list (list (cons "  ↑↓ moves · enter switches · or type a name or the number on the left · esc closes"
                       '(:dim t)))
           (list (cons (cond (models "  this conversation only, from the next turn; the transcript and the tools are untouched")
                             ;; **THE ONE THING A READER MUST BE TOLD ABOUT THIS CARD** (R38):
                             ;; verbosity applies to the whole transcript at once, because it is
                             ;; read at draw time. A reader who does not know that expects it to
                             ;; apply only to what comes next and concludes it did nothing.
                             (verbosity "  every row above is redrawn — this is a VIEW: nothing leaves the transcript, the ledger or the corpus, and switching back restores every row including the span you were on")
                             (t "  a mode change moves THIS session from its next call, and every later session in this project."))
                       '(:dim t))))
     (when models
       (list (list (cons "  `/default-model NAME` is what new sessions start on · this is not that"
                         '(:dim t)))))
     ;; **and the two typed paths are named, because the card's own hint row promises one of
     ;; them** (*or type a name or the number on the left*) and a reader who wants none of this
     ;; should not have to press esc to find out they could have typed it.
     (when verbosity
       (list (list (cons "  `/verbosity NAME` sets it without the card · esc closes this and changes nothing"
                         '(:dim t))))))))

(defun mode-confirm-lines (cols)
  "The `allow-all` question, wrapped rather than trimmed: this one is read, not
glanced at."
  (when *mode-confirm*
    (mapcar (lambda (l) (mapcar (lambda (seg) (cons (car seg) '(:bold t :fg :yellow))) l))
            (wrap-segments
             (list (cons "allow-all: privilege escalation, deletes outside the project and first contact with a new host all stop asking. On this box that is this box. It lasts for this session only, and a daemon restart drops it.  [y] or [enter] confirm   [esc] or any other key cancels"
                         nil))
             (max 20 cols)))))

(defun %send-mode (head name consented)
  "The mode frame. CONSENTED is a JSON **boolean**, never null.

`Mode.consented` is `consented: bool` with `#[serde(default)]` (protocol.rs:452):
serde's default accepts a MISSING key, not a present `null`. Our encoder writes
NIL as `null`, so `:consented nil` made the daemon's read loop break with an Err
and **close the connection** — every mode but `allow-all` went through that path.
The encoder has `:false` for exactly this, and `t` is the true side."
  (%send head (list :frame "mode"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :name name
                    :consented (if consented t :false))))

(defun mode-action (head name)
  "Move the session to mode NAME — `allow-all` asks first (`mode_action`)."
  (if (string= name "allow-all")
      (setf *mode-confirm* name (head-dirty head) t)
      (progn (%send-mode head name nil)
             (say head (format nil "mode → ~a" name)))))

(defun take-pick (head name)
  "The picker's choice NAME, taken: the card closes; a mode already in force is
said and not sent; a model goes as the slash line the operator would have typed
(`take_pick`, `take_mode`)."
  (let ((which *pick-open*))
    (close-pick head)
    (ecase which
      (:mode (if (string= name (pick-current head :mode))
                 (say head "already that mode")
                 (mode-action head name)))
      ;; **R38: it applies to the transcript ALREADY DRAWN, and the card says so.** Verbosity is
      ;; read at DRAW time over the whole conversation, so this is a view change and not a
      ;; setting for what comes next — and the writer is where the render cache is invalidated:
      ;; without that the lines already rendered would be served back out of the cache and the new
      ;; rung would appear to do nothing.
      ;;
      ;; **`%choose-verbosity` and not `set-verbosity`** (the persistence gap): the card is the
      ;; second interactive path to the rung, so it must write the choice down as the verb does.
      (:verbosity (if (string= name (pick-current head :verbosity))
                      (say head (format nil "verbosity is already ~a" name))
                      (let ((note (%choose-verbosity head (verbosity-for-word name))))
                        (say head (format nil "verbosity → ~a — the whole transcript, including everything above this line~@[~a~]"
                                          (verbosity-name) note)))))
      (:model (say head (format nil "switching to ~a…" name))
              (%send-slash head (format nil "models ~a" name))
              (%send head (make-settings))))))

(defun %pick-noun ()
  "What the list on the screen is a list OF, for the sentences that say *no X matches*."
  (ecase *pick-open* (:model "model") (:verbosity "verbosity") (:mode "mode")))

(defun pick-by-text (head typed)
  "What the operator TYPED while the picker was up, at enter — `pick_mode`: the
row's number, an exact name (case, `_` and spaces forgiven), or a unique prefix;
otherwise say why not and keep the card."
  (let* ((choices (pick-choices head))
         (typed (string-trim " " typed)))
    (cond
      ((zerop (length typed)) (close-pick head))
      ((null choices)
       (say head (ecase *pick-open*
                   (:model "this daemon does not send the model list; use `/models PROVIDER/MODEL`")
                   (:verbosity "this head has no rungs to offer, which cannot happen — the ladder is the head's own list")
                   (:mode "this daemon does not send the mode list; use `/mode NAME`"))))
      (t
       (let* ((n (ignore-errors (parse-integer typed)))
              (norm (lambda (s) (substitute #\- #\space (substitute #\- #\_ (string-downcase s)))))
              (want (funcall norm typed))
              (exact (find want choices :key norm :test #'string=))
              (hits (remove-if-not (lambda (c) (alexandria:starts-with-subseq want (funcall norm c)))
                                   choices)))
         (cond
           ((and n (<= 1 n (length choices))) (take-pick head (nth (1- n) choices)))
           (exact (take-pick head exact))
           ((= (length hits) 1) (take-pick head (first hits)))
           ((null hits)
            (say head (format nil "no ~a matches ~s — esc closes the list"
                              (%pick-noun) typed)))
           (t (say head (format nil "~d ~as match ~s; type the number on the left instead"
                                (length hits) (%pick-noun) typed)))))))))

(defun pick-key-event (head key)
  "The picker's own keys — the reference's arm: ↑↓ wrap, enter takes the cursor's
row and a digit takes that row, both only when nothing is typed; esc closes.
Returns T when the key was the picker's; anything else is the composer's, which is
how a name gets typed."
  (let* ((which *pick-open*)
         (type (getf key :type))
         (n (length (pick-choices head)))
         (empty (zerop (length (composer-buffer (head-composer head))))))
    (cond
      ((and (eq type :up) (plusp n))
       (setf (head-picker-sel head) (mod (1- (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :down) (plusp n))
       (setf (head-picker-sel head) (mod (1+ (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :enter) empty)
       (if (zerop n)
           (say head (if (eq *pick-open* :model)
                         "this daemon does not send the model list; use `/models PROVIDER/MODEL`"
                         "this daemon does not send the mode list; use `/mode NAME`"))
           (take-pick head (nth (min (head-picker-sel head) (1- n)) (pick-choices head))))
       t)
      ((and (eq type :char) empty (digit-char-p (getf key :ch))
            (<= 1 (digit-char-p (getf key :ch)) n))
       (let ((at (1- (digit-char-p (getf key :ch)))))
         (setf (head-picker-sel head) at)
         (take-pick head (nth at (pick-choices head))))
       t)
      ;; **R38: esc is a REAL ANSWER, and it says so.** *Dismissed leaves the setting alone and
      ;; says nothing was changed.* The other two lists are silent on esc because what they choose
      ;; is the daemon's and the screen behind them has not moved; this one changes what the whole
      ;; transcript looks like, so a reader who pressed esc has to be able to tell that it did not
      ;; happen — the same rule the payload window keeps (*esc closes the view and leaves the fold
      ;; open*), said out loud.
      ((eq type :esc)
       (close-pick head)
       (when (eq which :verbosity)
         (say head (format nil "verbosity left as ~a — nothing was changed"
                           (pick-current head :verbosity))))
       t)
      (t nil))))

(defun mode-confirm-key (head key)
  "The `allow-all` question owns every key while it is up: [y] or [enter] send the
mode with consent; anything else cancels."
  (let ((type (getf key :type)))
    (if (or (eq type :enter)
            (and (eq type :char) (member (getf key :ch) '(#\y #\Y))))
        (let ((name *mode-confirm*))
          (setf *mode-confirm* nil)
          (%send-mode head name t)
          (say head (format nil "mode → ~a (consented)" name)))
        (progn (setf *mode-confirm* nil)
               (say head "allow-all not taken")))
    (setf (head-dirty head) t)
    t))

;;; --------------------------------------------- the empty-session banner ;;;

(defun empty-session-lines (cols)
  "What the transcript says when there is nothing in it — the reference's opening
banner (`app.rs:6112-6131`), which leticl did not have at all.

The distinction it turns on is the one the walking cat above already makes:
**attached and quiet** is not **not answered yet**. The cat covers the second,
and this covers the first, so an empty screen is never left to mean both. The
reference guards it with `&& !self.attaching` for exactly that reason and
`%viewport-lines` guards it the same way.

One word differs from the reference on purpose: it names itself `letibot` and
this head is `leticl`, and a banner whose whole job is to say which head you are
looking at must not lie about that. Every other sentence is verbatim."
  (let ((w (max 20 cols)))
    (append
     (list (list (cons "leticl" '(:bold t)))
           nil)
     (mapcar (lambda (l) (list (cons l '(:dim t))))
             (wrap-text "attached, and this session has said nothing yet. Type a question and press enter." w))
     (mapcar (lambda (l) (list (cons l '(:dim t))))
             (wrap-text "The turn runs in the daemon: closing this window does not stop it, and reattaching picks it up." w))
     (list nil
           (list (cons "/help lists the keys." '(:dim t)))))))

;;; ------------------------------------------------- the permission card ;;;
;;;
;;; The reference's `decision_lines` (app.rs:7329-7466), ported whole. What was
;;; here before (`decision-card-lines`, cards.lisp) drew the summary, the target,
;;; the detail, the options and a hint — and dropped, in order of what it cost:
;;;
;;;   · the ORACLE'S VERDICT. The head already receives it (`:advice`,
;;;     src/session.lisp:324) and folded it onto the open decision, where nothing
;;;     read it. Under `/mode supervised` the question on the screen is not
;;;     *should this run* but *do you agree with the model*, and the model's
;;;     answer was off-screen;
;;;   · the OPTION IDS, so the ladder and the typed path showed two different
;;;     spellings of the same choice;
;;;   · the GLOB HINT, which the reference shows only when `allow_always` is on
;;;     offer, because a hint for an option this request does not have teaches
;;;     the operator to stop reading the hints;
;;;   · and `ask_without_target`, so the command appeared twice — once inside the
;;;     summary sentence and once on its own line under it.

(defun ask-without-target (summary target)
  "SUMMARY with its TARGET taken off the end: `` `bash` wants exec access `` from
`` `bash` wants exec access to `cargo test` `` — the reference's
`ask_without_target` (app.rs:7865-7874).

NIL when the sentence does not end in the target, which is the honest answer for
a summary some other builder wrote: then the whole sentence is shown and nothing
is lost. ` to ` is the joint in every sentence this daemon writes, and trimming
it is what makes the remainder read as a heading rather than as a clipped
sentence."
  (when (and (stringp summary) (stringp target)
             (plusp (length target)) (plusp (length summary)))
    (let ((suffix (format nil "`~a`" target)))
      (when (and (>= (length summary) (length suffix))
                 (string= suffix summary :start2 (- (length summary) (length suffix))))
        (let ((stem (string-right-trim " " (subseq summary 0 (- (length summary)
                                                                (length suffix))))))
          (if (and (>= (length stem) 3)
                   (string= " to" stem :start2 (- (length stem) 3)))
              (subseq stem 0 (- (length stem) 3))
              stem))))))

(defun %option-kind-p (options word)
  "Is any of OPTIONS of kind WORD (`allow_always`, `reject_always`)?

By substring on the serialised kind, which is how the daemon spells
`OptionKind` on the wire. A question's `:choices` are bare strings and have no
kind, so they answer NIL rather than signalling."
  (find-if (lambda (o)
             (and (listp o)
                  (search word (string-downcase (or (getf o :kind) "")))))
           options))

(defun advice-lines (advice w)
  "The oracle's verdict, as the reference draws it (app.rs:7377-7409): `model
says {would}: {basis}`, then `{by} · {grounds} · {N} ms`.

The grounds sentence is **said out loud when it is a fact and omitted when it is
not one**. Citations, when there are any; `cites nothing from your words` ONLY
when the verdict was `admit`, because an oracle that did not authorise anything
has nothing to cite and saying so about it claims a search that was never the
question. The reference printed it unconditionally once and a screen carried
`the operator authorised this: … (citing trail entry 0)` and `cites nothing from
your words` one line apart."
  (let* ((cites (getf advice :cites))
         (grounds (cond (cites (format nil "cites ~{~a~^ · ~}" cites))
                        ((equal (getf advice :would) "admit")
                         "cites nothing from your words")
                        (t nil)))
         (tail (if grounds
                   (format nil "  ~a · ~a · ~a ms" (or (getf advice :by) "?")
                           grounds (or (getf advice :latency-ms) 0))
                   (format nil "  ~a · ~a ms" (or (getf advice :by) "?")
                           (or (getf advice :latency-ms) 0)))))
    (mapcar (lambda (l) (list (cons l '(:dim t))))
            (append (wrap-text (format nil "  ~a" (%advice-line advice)) w)
                    (wrap-text tail w)))))

(defun permission-card-lines (head cols)
  "The ask card — `decision_lines`, app.rs:7329-7466, line for line:

    ? `bash` wants exec access [exec]
        cargo test --workspace
      the guard read this as a build, in this project
      model says allow: it is the project's own test command
      oracle-local · cites trail entry 4 · 310 ms
    ▸ Allow once  (allow_once)
      Always allow  (allow_always)
      Deny  (reject_once)
      ↑↓ to choose · Enter to answer · or type the id ·  `allow_always <glob>` …
      `deny_and_tell <why>` denies and sends those words to the model

The question is yellow, the thing being asked about is bold and indented four —
`a command is the one thing here worth the rows` — the evidence is dim under it,
and the ladder's own row is reversed rather than recoloured, because the prompt
is already yellow and a highlight in a second hue reads as a second kind of
thing rather than as *this one*.

**Nothing here preselects an option.** `head-decision-sel` is untouched by the
advice: the verdict informs the answer and must never supply it, or the corpus
fills with rows recording a keystroke rather than a judgement.

**AND THIS RETURNS TWO VALUES, WHICH IS R20** (letibot `3a9b183`-era; the operator,
seeing a card with a giant `replace` in it: *\"I'm shown a permission prompt and I just
can't see the selector\"*). The card is **content** — headline, target, detail, `because`,
the oracle's advice — and a **ladder**: the options, the hints that say how to answer, and
what silence does. The content is unbounded (a diff, a commit message) and the ladder is
bounded and is *the reason the card exists*.

They used to be ONE list, drawn as `(subseq card-lines 0 card-rows)` while the fit loop
shrank `card-rows` from the end — so a long diff ate the hint, then the options bottom-up,
and kept the content. **Measured before the fix, at every size from 8 rows to 30, with a
40-line diff**: not one option, not the hint, not the deadline on the screen. A card that
has dropped its choices is a question with no way to answer it, and it is the same defect
letibot found in its own `dec_rows -= 1` (`app.rs:6641`).

So the ladder is returned separately and `%render` **pins it**: it is never trimmed and
never scrolled. The content becomes a viewport that SHRINKS to whatever room is left and
**scrolls**, with a seam saying how much is out of view."
  (let ((d (first (session-open-decisions (head-session head)))))
    (when d
      (let* ((w (max 20 cols))
             (kind (or (getf d :kind) ""))
             (question (string= kind "question"))
             (options (or (if question (getf d :choices) (getf d :options)) nil))
             (n (length options))
             (sel (max 0 (min (head-decision-sel head) (max 0 (1- n)))))
             (target (or (getf d :target) ""))
             (summary (or (getf d :summary) ""))
             (headline (or (ask-without-target summary target) summary))
             ;; **TWO ACCUMULATORS, AND THAT IS R20.** `out` is the CONTENT — the
             ;; unbounded part — and `lad` is the LADDER: the options, the hints that
             ;; say how to answer, and what silence does. Only the content is
             ;; windowed and trimmed; see this function's docstring.
             (out nil)
             (lad nil))
        (flet ((wrapped (text style)
                 (dolist (l (wrap-text text w))
                   (push (list (cons l style)) out)))
               (ladder (text style)
                 "A line of the LADDER: pinned to the bottom, never trimmed."
                 (dolist (l (wrap-text text w))
                   (push (list (cons l style)) lad))))
          (wrapped (format nil "? ~a [~a]" headline kind) '(:fg :yellow))
          (when (plusp (length target))
            ;; bold rather than yellow: the question is yellow, and the thing
            ;; being asked about is not a second question
            (wrapped (format nil "    ~a" target) '(:bold t)))
          ;; **R35: THE FILES THIS ACTION WRITES, in the register the target is in.** Drawn
          ;; here — immediately under the target, inside the content — because that is where a
          ;; reader looks for *what is this about to touch*, and because the edit tool's own
          ;; path is drawn two lines up in exactly this style. A reader comparing the two cards
          ;; must not have to know which mechanism produced them.
          ;;
          ;; **Only when the DAEMON sent the field**, and that guard is the whole of why the
          ;; edit card does not draw its path twice: `%write-targets` falls back to the target
          ;; itself for a `write` access, and that path is ALREADY on the line above. The block
          ;; is for the case the single `target` cannot express — a script whose target is a
          ;; command and whose writes are elsewhere, which is exactly the case R35 was filed
          ;; for. Inert until the daemon sends the field: no daemon sends it today.
          (when (getf d :write-targets)
            (dolist (l (write-target-lines (%write-targets d) w))
              (push l out)))
          (when (plusp (length (or (getf d :detail) "")))
            (wrapped (format nil "  ~a" (getf d :detail)) '(:dim t)))
          ;; the reference's card has no `because`; ours carries it and it is the
          ;; deterministic half of the same evidence, so it sits with the rest
          (when (plusp (length (or (getf d :because) "")))
            (wrapped (format nil "  because: ~a" (getf d :because)) '(:dim t)))
          ;; **the model's verdict, above the ladder** — read before the choice
          (let ((a (getf d :advice)))
            (cond (a (dolist (l (advice-lines a w)) (push l out)))
                  ((not question)
                   ;; NOT the reference's: it draws nothing when there is no
                   ;; advice. An absence is evidence under `/mode supervised` —
                   ;; "the model was not asked" and "the model said nothing" look
                   ;; identical on a card that omits both — so this head says
                   ;; which one it is, once, in the same dim register as the
                   ;; verdict it replaces.
                   (wrapped "  no oracle was consulted for this one — the judgement is yours alone"
                            '(:dim t)))))
          ;; one option per line: the marker IS the thing Enter takes, and the id
          ;; stays on the line so the typed path and the ladder agree
          (loop for o in options
                for i from 0
                do (let* ((label (if question o (or (getf o :label) "?")))
                          (oid (and (not question) (getf o :option-id)))
                          (picked (= i sel))
                          (body (if oid
                                    (format nil "~a ~a  (~a)" (if picked "▸" " ") label oid)
                                    (format nil "~a ~a" (if picked "▸" " ") label))))
                     (dolist (l (wrap-text (format nil "  ~a" body) w))
                       (push (list (cons l (if picked '(:reverse t) '(:fg :yellow))))
                             lad))))
          (cond
            (question
             (ladder "  ↑↓ to choose · Enter to answer · or type the id · esc leaves it open"
                     '(:fg :yellow)))
            ((%option-kind-p options "allow_always")
             ;; the rule an *always allow* will write is in the option's own
             ;; label, so the hint points at EDITING it rather than at inventing
             ;; one: the offer that never said which tool and verb it would
             ;; permit was a pattern the operator could not see and so could not
             ;; adjust
             (ladder "  ↑↓ to choose · Enter to answer · or type the id ·              `allow_always <glob>` to widen or narrow the rule shown above"
                     '(:fg :yellow)))
            (t (ladder "  ↑↓ to choose · Enter to answer · or type the id"
                       '(:fg :yellow))))
          ;; **the option that asks for words says where to type them.** Its label
          ;; promised "tell the model why" and the card never said how, so the why
          ;; was typed into the composer and left sitting there unanswered.
          (when (and (not question) (%option-kind-p options "reject_always"))
            (ladder "  `deny_and_tell <why>` denies and sends those words to the model"
                    '(:fg :yellow)))
          ;; **§11.7: WHAT ASKS, WHEN WHAT ASKS IS THE DECLARATION.** letibot landed this
          ;; wording at `11f07e7` and the operator ruled it both heads' — the sentence is
          ;; SHARED and not this head's to reword, because two heads that explain one call
          ;; differently argue with the operator about the same fact.
          ;;
          ;; **The gap it closes, and it cost three 300-second refusals in one night.** The
          ;; headline says what the tool DECLARES (`? `bash` wants exec access [exec]`) and
          ;; the line above is layer A's reading of the ACTION (`ask — intents [inspect]…`).
          ;; Nothing joined them, so an operator looking at `[exec]` over a line that reads
          ;; `inspect` had two sentences to reconcile and no statement that they are about
          ;; DIFFERENT things — the declaration and this action.
          ;;
          ;; **THE GUARD IS THE WHOLE SENTENCE**, and both halves are falsified below: it is
          ;; drawn for `exec` and nothing else, because a `read` is asked about by a rule, a
          ;; path or a mode — a sentence blaming its DECLARATION would be false on the very
          ;; card carrying it, which is the `because: workspace: /` fault (a fact named
          ;; after one thing and read from another). And it is NOT drawn when `access` is
          ;; absent: an older daemon did not say, and a head that guessed `exec` would
          ;; print a claim about a declaration nobody made.
          (when (and (not question) (equal (getf d :access) "exec"))
            (ladder "  the access is what asks: a tool declared to `exec` is asked about on its declaration, and the line above is a reading of this action"
                    '(:dim t)))
          ;; **§1.6: WHAT SILENCE DOES, AND HOW LONG THERE IS.** Both facts ride on
          ;; the frame (`deadline`, `on_timeout`, event.rs:569-574) and neither was
          ;; drawn, so two cards sailed past their own 300-second budget and the
          ;; operator learned the consequence *afterwards*, from the daemon's
          ;; `not_run by gate:timeout` sentence in the log.
          ;;
          ;; It is DIM, not yellow: the ladder and the keys are what the card is
          ;; asking for, and a second yellow line competes with them. It sits below
          ;; them, because the order a person reads is the question, then the
          ;; options, then what happens if they do nothing.
          ;;
          ;; Each half is OMITTED rather than improvised when the daemon did not say
          ;; it — see `deadline-said` and `on-timeout-said` for why each silence is
          ;; right, and why the two silences are not the same silence.
          ;;
          ;; **PART OF THE LADDER, and the ruling is why**: the consequence of not
          ;; answering is about the ANSWER, so it is pinned with the choices. A card
          ;; that kept its options and dropped `if nobody answers, nothing runs`
          ;; would be a card the operator can answer without knowing what their
          ;; silence does.
          (let ((time (deadline-said (getf d :deadline)))
                (silence (on-timeout-said (getf d :on-timeout))))
            ;; ` · ` between the clauses, and neither is improvised: a conditional
            ;; consequence and a deadline past are two facts about the same card, and
            ;; the operator reads one line rather than two
            (when (or time silence)
              (ladder (format nil "  ~{~a~^ · ~}"
                              (remove nil (list time silence)))
                      '(:dim t)))))
        (values (nreverse out) (nreverse lad))))))

;;; ----------------------------------------------------- the secret card ;;;

(defun op-call-card-lines (head cols)
  "The operator-call card (R24 part two): which tool, and exactly what its two keys do.

    running a tool as your act
      tool    NAME                          (or: type one — the names the door gives)
      enter   asks the daemon to admit this call as your act, and nothing runs
              until it says the call was admitted
      esc     cancels, and asks for nothing

**It draws the door's names.** This card is the only thing on the screen that knows what
the daemon will accept, and the operator is one keypress away from asking for a call that
would be refused by name. A list of its own here would be the same drift as a list held in
this head — which is why the example above is `NAME` and not a tool: nothing under `src/`
knows a door's name, and a test asserts exactly that.

**And it is the composer's card**: the argument is typed in the box below, so there is a
`tool` field rather than a prompt, and the two key rows are the whole instruction."
  (let* ((w (max 20 cols))
         (door (head-run-tools (head-settings head)))
         (name (getf *op-call-draft* :name))
         (indent (make-string 10 :initial-element #\space)))
    (flet ((row (key text)
             (cons (list (cons (format nil "  ~8a" key) '(:dim t))
                         (cons (car text) nil))
                   (mapcar (lambda (l) (list (cons indent nil) (cons l '(:dim t))))
                           (cdr text)))))
      (append
       (list (list (cons "running a tool as your act" '(:bold t))))
       (list (list (cons "  tool    " '(:dim t))
                   (cons (or name (format nil "type one — ~{~a~^, ~}" door))
                         '(:fg :bright-white))))
       (row "enter" (wrap-text
                      (format nil "asks the daemon to admit this call as your act~@[ (one of ~{~a~^, ~})~]; nothing runs until it says so"
                              (and (null name) door))
                      (max 8 (- w 10))))
       (row "esc" (wrap-text "cancels, and asks for nothing" (max 8 (- w 10))))))))

(defun todo-card-lines (head cols)
  "The new-todo card: the two fields, which one is being typed, and the three keys.

    adding a todo item

      title    add a way to edit todos
      detail   a modal with a title and a description

      tab      moves between the fields
      enter    adds it to the session's plan, as yours
      esc      cancels, and adds nothing

**The card is the modal and the composer is the field**, which is this head's one text widget —
`op-call-card-lines` has the same shape for the same reason. The focused field is drawn from the
DRAFT's copy and the other from the composer, so the row under the cursor is never a keystroke
behind: `%todo-draft-focus` stores the one it is leaving.

**The last line says who this is for**, because that is the limitation of the whole feature and the
place the reader will look for it: an item added here is the head's, and the model does not see it.
A screen that let them believe otherwise would be the same defect class as a disclosure that
guesses."
  (let* ((w (max 20 cols))
         (field (%todo-draft-field))
         (composer (composer-buffer (head-composer head)))
         (title (if (eq field :title) composer (or (getf *todo-draft* :title) "")))
         (detail (if (eq field :detail) composer (or (getf *todo-draft* :detail) "")))
         (indent (make-string 11 :initial-element #\space)))
    (flet ((fld (name key value)
             (list (cons (format nil "  ~7a " key) '(:dim t))
                   (cons (if (plusp (length value)) value "(empty)")
                         (if (eq field name) '(:fg :bright-white) '(:dim t))))))
      (append
       (list (list (cons "adding a todo item" '(:bold t))))
       (list nil)
       (list (fld :title "title" title))
       (list (fld :detail "detail" detail))
       (list nil)
       (list (list (cons (format nil "  ~7a" "tab") '(:dim t))
                   (cons "moves between the fields" nil)))
       (list (list (cons (format nil "  ~7a" "enter") '(:dim t))
                   (cons "adds it to the session's plan, marked as yours" nil)))
       (list (list (cons (format nil "  ~7a" "esc") '(:dim t))
                   (cons "cancels, and adds nothing" nil)))
       (list nil)
       ;; **AND THE LIMITATION SAID HERE WAS FALSE.** It read *"the model does not see these — the
       ;; wire has no frame that writes a todo"*, and both halves had stopped being true: R44 landed
       ;; `ClientFrame::SetOperatorTodos`, the daemon's board is one list with two authors, and the
       ;; nag reads it — so the model is not only shown these rows, it is now nagged about them and
       ;; can answer one. A card that tells the operator their row is invisible would have them
       ;; wondering why the model kept bringing it up.
       (list (list (cons "  the model sees these and is reminded of them; it can mark one done"
                         '(:dim t))))
       (list (list (cons "  it cannot remove your row — that is yours alone, with the delete key"
                         '(:dim t))))))))

(defun %size-said (n)
  "N BYTES as a person reads it, with the unit named. Nothing for zero, which is not a
size — a zero-byte body is the *recorded and empty* fact and its own sentence says so."
  (cond ((null n) nil)
        ((>= n 1024) (format nil "~,1f KB" (/ n 1024.0)))
        (t (format nil "~d bytes" n))))

(defun diagnostic-listing-lines (diag)
  "The `/diagnostic` listing: the oracle's brief and its reply, each labelled with what it
IS and how big it is — the R11 half that had never reached a head.

**THREE states per half, and they are three different sentences.** `body: None` is *nobody
kept this* — a row written before R11 kept the exchange, or an id no adjudication has;
`Some(\"\")` is *recorded, and empty* — the gate really was shown nothing. The second is not
a rendering of the first, and a head that drew both as an empty pane would have rebuilt the
defect this file's `%advice-said` exists for, one field over.

**`total` is drawn, not derived.** `body.map(len)` cannot tell the two absences apart, and
the daemon sends the byte count precisely so a head does not have to guess it.

Lines come back UNWRAPPED: the slash pane wraps at its own width, and wrapping here too
would wrap twice — the same division `warning-listing-lines` keeps."
  (let* ((answers (getf diag :answers))
         (out nil))
    (dolist (kind +diagnostic-kinds+)
      (let ((ans (cdr (assoc kind answers :test #'string=))))
        ;; the daemon's own word for which half this is, at the head of the block
        (push (format nil "~a~@[ · ~a~]"
                      (if (string= kind "brief") "brief — what the gate was shown"
                          "reply — what the gate answered, verbatim")
                      (%size-said (getf ans :total)))
              out)
        (cond
          ;; **NOT ANSWERED YET**: the frame is out and nothing has come back. Said
          ;; rather than drawn as an absence, because the two are different facts.
          ((null (getf ans :decided))
           (push "  reading…" out))
          ;; **NOTHING KEPT IT** — `body: None`, and the sentence names both reasons
          ((null (getf ans :body))
           (push (format nil "  nobody kept this. The row predates the store keeping the ~
                             exchange, or ~a names no adjudication here."
                         (or (getf diag :request-id) "that id"))
                 out))
          ;; **RECORDED AND EMPTY** — a body that is present and is nothing
          ((zerop (length (getf ans :body)))
           (push "  recorded, and empty — this half was kept and holds nothing." out))
          (t (dolist (l (%lines-of (getf ans :body)))
               (push l out))))
        (push "" out)))
    (nreverse out)))

(defun open-diagnostic-listing (diag head)
  "Put the `/diagnostic` listing in the slash pane. T when there is one.

Fills `*slash-out*` and does NOT touch the mode — except that the CALLER opened the pane
from a keypress, which is where the mode belongs (the job overlay's rule: opened at the
keypress, saying `reading…`, rather than showing an empty screen for the answer)."
  (declare (ignore head))
  (setf *slash-out* (cons (format nil "/diagnostic ~a" (or (getf diag :request-id) ""))
                          (diagnostic-listing-lines diag)))
  t)

(defun secret-ask-lines (head cols)
  "The password card — the reference's `secret_lines` (app.rs:7305-7327):

    sudo wants a password — [sudo] password for dead:
    for: apt install ripgrep
    type it below (shown as dots), Enter sends it once to sudo and nowhere else; Esc refuses · 47s left

Two differences from what was on the screen before, both measured:

  · **the countdown.** `SecretAsk.deadline` (app.rs:10060) arrives on the frame
    and was folded onto `head-secret-req` and never read, so a sudo prompt about
    to time out looked exactly like one that had just arrived. It is drawn from the same
    `deadline-said` ladder the gate card uses, so the two cannot disagree about what
    a countdown looks like, and it is omitted rather than guessed when the daemon
    sent no deadline;
  · **the dots are not here.** They are drawn in the composer's own box
    (`composer-box-body`), which is where the field is; this card says what is
    being asked and for what, and never measures the text."
  (let ((req (head-secret-req head)))
    (when req
      (let* ((w (max 20 cols))
             ;; **the deadline is already on THIS head's clock.** It is converted
             ;; where the frame arrived (`wire-deadline->monotonic`), because the
             ;; wire's value is a Unix instant and this head's clock is a counter
             ;; since process start. This card subtracted one from the other and drew
             ;; the result, so its countdown read a number in the hundreds of
             ;; thousands of seconds — R13's two-clocks trap, in a second place, and
             ;; found here first.
             (time (deadline-said (getf req :deadline))))
        (append
         (list (list (cons (truncate-to-width
                            (format nil "sudo wants a password — ~a"
                                    (string-trim " " (or (getf req :prompt) "")))
                            w)
                           '(:fg :yellow))))
         (mapcar (lambda (l) (list (cons l nil)))
                 (wrap-text (format nil "for: ~a" (or (getf req :command) "")) w))
         (list (list (cons (truncate-to-width
                            (format nil "type it below (shown as dots), Enter sends it once to sudo and nowhere else; Esc refuses~@[ · ~a~]"
                                    time)
                            w)
                           '(:dim t)))))))))

;;; ---------------------------------------- where a pane's cursor opens ;;;

(defun picker-initial-sel (head)
  "The row the session picker opens on: **the session this head is in**.

The reference seeds `picker_sel` from the current session when Ctrl+S opens the
list (app.rs:3080-3087), so Enter on an untouched list is a no-op — the same
courtesy `open-pick` pays the mode picker two hundred lines above. `%open-pane`
(`src/commands.lisp:178-191`) sets the shared cursor to 0 for every pane, so
Ctrl+S then Enter switched the operator to session #1, which is very rarely the
one they were in.

0 when the current session is not in the list, which is a daemon that has not
answered `sessions` yet — and row 0 is then the only row there is to be on."
  (or (position (session-session-id (head-session head))
                (picker-sessions (head-session head))
                :key (lambda (b) (getf b :session-id)) :test #'equal)
      0))

(defun pane-initial-sel (head mode)
  "Where pane MODE's cursor belongs the moment it opens.

One function so `%open-pane` has a single line to call rather than a `case` of
its own, and so the seeding lives beside the pane that defines what a row is.
Every pane but the session picker opens at the top, which is the honest place
when one cursor is shared: a position left by the last pane means nothing to the
next (`src/commands.lisp:181-186`)."
  (if (eq mode :picker) (picker-initial-sel head) 0))

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
