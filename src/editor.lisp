;;;; editor.lisp — the input surface: the composer and the key ladder.
;;;;
;;;; The composer (cursor, history, kills) and the precedence ladder that decides
;;;; who a key belongs to. The ladder has the Rust head's fixed precedence: the
;;;; cards that own the keyboard, then the head's own chords, then a click, then
;;;; whatever list is on the screen, then the composer.
;;;;
;;;; **What is gated on an empty composer is ENTER and the digits, not the arrows
;;;; and not the letters.** The whole ladder used to be gated, which reads as a
;;;; rule — a half-typed line always means the line — and cost the operator the
;;;; line it was protecting: an ask arriving mid-sentence could only be answered
;;;; by emptying the composer first, and a pane on the screen swallowed every
;;;; character typed under it. Arrows belong to whatever list is up; Enter and a
;;;; row number belong to the line being typed, and a line that names no option
;;;; answers the marked row and is HELD.
;;;;
;;;; The terminal DECODER is not here — that is `keys.lisp`, the port of
;;;; term.rs's tables. This file receives decoded key plists.

(in-package #:leticl)

;;; ------------------------------------------------------------------ S4 ;;;
;;;
;;; The editor's windows, and every one of them is a GLOBAL rather than a
;;; `composer` slot. A defstruct layout change is a hard error in this SBCL, so a
;;; slot would mean a restart — the one thing a live head must not need. There is
;;; one composer per process, so a defvar each costs nothing and pushes.
;;;
;;; They sit at the TOP of the file rather than beside the functions that use
;;; them, because the key ladder below reaches for several of them and a special
;;; referenced before its defvar is a full compile-time warning (chrome.lisp says
;;; the same about `*esc-at*`).

(defvar *kill-ring* nil
  "Killed text, newest first. `ctrl-y` yanks the head of it.

A ring rather than a single slot: `ctrl-k` then some editing then `ctrl-y` is
the common shape, and a single slot loses the first kill the moment you make a
second one.")
(defparameter *kill-ring-max* 16
  "How many kills to keep. A ring nobody can exhaust is a leak.")

(defvar *undo-stack* nil
  "Snapshots of the composer buffer, newest first, for `ctrl-z`.

Snapshots rather than an operation log: a buffer is a string and a string is
cheap, while replaying operations has to get every one of them right. Batched at
WORD granularity by the caller, so `ctrl-z` undoes a word rather than a
character — a per-character undo makes you hold the key and hope.")
(defparameter *undo-max* 400
  "How many snapshots to keep before dropping the oldest.")

(defvar *paste-ledger* nil
  "Alist of MARKER → the text that marker stands for.

A paste of five lines or more collapses to a marker in the composer and the full
text is remembered here, then SUBSTITUTED BACK on submit. The point is that a
three-thousand-line paste is one visible token while you are typing and still
arrives whole — the operator sees a marker, the model receives the paste.")

(defparameter *history-max* 50
  "How many submitted prompts are remembered — the reference's `HISTORY_CAP`.
An uncapped history is a leak with a friendly name.")

(defvar *history-recalled* nil
  "The text a history walk last put in the composer, or NIL.

The rule worth having, and the one this head did not have: **once a recalled
entry has been edited, the walk stops**, because the next press would silently
destroy the edit (editor.rs:519-527).")

(defvar *redo-stack* nil
  "Buffers an undo took back, newest first, for `alt+z`.

Cleared by the next EDIT and not by the next key, which is the rule that makes a
redo stack usable: undo, undo, redo, redo walks back and forth, and the moment
you type something the branch you abandoned is gone (editor.rs:441-454, 629).")

(defvar *preferred-col* nil
  "The column a run of ↑/↓ is trying to keep.

Sticky, so walking down through a short line and on to a long one comes back to
the column you started in rather than the end of the short one. Cleared by any
key that is not ↑ or ↓, which is where a vertical walk ends.")

;;; ------------------------------------------------------------- keys ;;;
(defun %open-decision (head)
  (first (session-open-decisions (head-session head))))

(defun match-option (decision typed)
  "TYPED as an answer to DECISION: `(values option-id pattern note)`, or NIL.

Three things, and each is a rule the reference learned the hard way:

  · the WORD is matched against the option id or its label, case-insensitively,
    falling back to a unique PREFIX — the ladder's option ids are long, and an
    operator who types `allow` means the one option that starts with it;
  · trailing words are a GLOB on the option that writes a rule (always-allow),
    and the operator's own words on the option that promised to carry a reason
    (`deny_and_tell`) — which used to be REFUSED, so the line stayed in the
    composer and NOTHING was answered while the operator looked at their own
    sentence;
  · on any other option trailing words are refused rather than dropped: somebody
    who typed them meant them, and answering as though they had not is the answer
    they did not give."
  (when decision
    (let* ((line (string-trim " " (or typed "")))
           (sp (position #\space line))
           (word (if sp (subseq line 0 sp) line))
           (rest (if sp (string-trim " " (subseq line (1+ sp))) ""))
           (options (if (string= (getf decision :kind) "question")
                        (getf decision :choices)
                        (getf decision :options)))
           (opt (find-if (lambda (o)
                           (let ((id (or (getf o :option-id) ""))
                                 (label (or (getf o :label) "")))
                             (or (string-equal word id) (string-equal word label))))
                         options)))
      (when opt
        (let ((kind (getf opt :kind))
              (id (getf opt :option-id)))
          (cond
            ((zerop (length rest)) (list id nil nil))
            ;; the option that WRITES a rule takes the glob
            ((and kind (search "allow_always" (string-downcase kind)))
             (list id rest nil))
            ;; the option that PROMISED a reason takes the words
            ((and kind (search "reject_always" (string-downcase kind)))
             (list id nil rest))
            ;; every other option refuses them, rather than dropping them
            (t nil)))))))

(defun decision-options (decision)
  "The rows DECISION offers, whichever name the frame gives them — one place,
because the ladder, the digits and the answer each asked separately and a
`question` whose rows live under `:choices` answered the wrong list from two of
the three."
  (and decision
       (if (string= (getf decision :kind) "question")
           (getf decision :choices)
           (getf decision :options))))

(defun %answer-decision (head index)
  "Answer the open ask with row INDEX. T when an answer went out.

Returns whether it answered, because `%submit-line` now has a caller that must
say something different when it did not: an ask with no rows at all cannot be
taken by Enter, and answering `0` into it would send an option id nobody
offered (app.rs:3934-3940)."
  (let* ((d (%open-decision head))
         (options (decision-options d)))
    (when (and d options)
      (let* ((question (string= (getf d :kind) "question"))
             (idx (min (max 0 index) (1- (length options)))))
        (if question
            (%send head (make-answer-question (getf d :req-id)
                                              (list :option idx)))
            (let ((option-id (getf (nth idx options) :option-id)))
              (%send head (make-answer (getf d :req-id)
                                       (or option-id (format nil "~d" idx))))))
        (setf (head-decision-sel head) 0
              (head-dirty head) t)
        t))))

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
       (let ((m (match-option decision line)))
         (cond
           (m (destructuring-bind (id pattern note) m
                (%send head (make-answer (getf decision :req-id) id pattern note))
                (setf (head-decision-sel head) 0)))
           ;; IT NAMED NO OPTION. The line is not disposable — the ask arrived
           ;; while it was being typed — and neither is the ask: Enter on a card
           ;; means "answer this". So the words go BACK to the composer and the
           ;; MARKED ROW is answered, which is what the reference does
           ;; (app.rs:3983-4000). Saying *"…is not an option here"* and answering
           ;; nothing left the operator looking at their own sentence with the ask
           ;; still open — the same shape as the deny-and-tell defect, one arm over.
           (t (composer-insert (head-composer head) line)
              (say head (if (%answer-decision head (head-decision-sel head))
                            "answered the ask — your line is held, enter sends it"
                            "this ask offers no options — your line is held"))))))
      (t (%prompt head line)))
    (setf (head-dirty head) t)))

(defun %pick-session (head typed)
  "What the operator TYPED while the session picker was up, at enter — the
reference's `pick` (app.rs:4068-4109): the row's number, or enough of an id to be
unique, or a word in a title.

An ambiguous prefix is REFUSED WITH THE COUNT rather than resolved to the first
match. Switching to the wrong session is not a keystroke you can take back — the
prompt you type next lands there."
  (let* ((rows (picker-sessions (head-session head)))
         (typed (string-trim " " typed))
         (n (ignore-errors (parse-integer typed))))
    (cond
      ((zerop (length typed)) (setf (head-mode head) :normal (head-dirty head) t))
      ((and n (<= 1 n (length rows)))
       (%send head (make-switch (getf (nth (1- n) rows) :session-id) 0))
       (setf (head-mode head) :normal (head-dirty head) t))
      (t
       (let ((hits (remove-if-not
                    (lambda (b)
                      (or (uiop:string-prefix-p typed (or (getf b :session-id) ""))
                          (let ((title (or (getf b :title) "")))
                            (and (plusp (length title))
                                 (search (string-downcase typed) (string-downcase title))))))
                    rows)))
         (case (length hits)
           (1 (%send head (make-switch (getf (first hits) :session-id) 0))
              (setf (head-mode head) :normal (head-dirty head) t))
           (0 (say head (format nil "no session matches ~s — esc closes the list" typed)))
           (t (say head (format nil "~d sessions match ~s; type the number on the left instead"
                                (length hits) typed)))))))))

(defvar *completion* nil
  "The tab cycle: `(NAMES INDEX)` — every command the last fresh prefix matched,
and which of them is on the line now.

A defvar rather than a head slot, for the reason every other editor window here
is one: a struct layout change is a restart.")

(defun %set-composer (head text)
  "Replace the whole line. Completion words are single tokens, so there is
nothing to preserve around them."
  (let ((c (head-composer head)))
    (setf (composer-buffer c) text
          (composer-cursor c) (length text))))

(defun %complete (head)
  "Tab on a `/command` — the reference's `complete_slash` (app.rs:4292-4324).

A fresh prefix completes to its FIRST match and MORE TABS WALK THE REST, which is
what `/help` already promised and what the old one could not do: it inserted only
on a unique prefix and otherwise wrote the candidates to the status line, so
`/re` — four commands — printed a list and left the line alone.

The cycle only walks while the line is exactly what the cycle last wrote, so a
character typed on the end starts a fresh match rather than clobbering it. A line
with whitespace in it is not a bare verb and is left alone (`/mode x` + Tab used
to silently do nothing anyway, having no unique hit). A prefix nothing matches
SAYS SO rather than deleting what was typed to explain why nothing happened."
  (let ((buf (composer-buffer (head-composer head))))
    (when (and (uiop:string-prefix-p "/" buf)
               (not (find-if (lambda (ch) (member ch '(#\space #\tab #\newline))) buf)))
      (let ((walked
              (when *completion*
                (destructuring-bind (names idx) *completion*
                  (when (and names (string= buf (format nil "/~a" (nth idx names))))
                    (let ((next (mod (1+ idx) (length names))))
                      (setf *completion* (list names next))
                      (%set-composer head (format nil "/~a" (nth next names)))
                      t))))))
        (unless walked
          (let* ((needle (subseq buf 1))
                 (names (mapcar #'car
                                (remove-if-not (lambda (c) (uiop:string-prefix-p needle (car c)))
                                               *slash-commands*))))
            (cond (names
                   (setf *completion* (list names 0)
                         (head-status-note head) nil)
                   (%set-composer head (format nil "/~a" (first names))))
                  (t (setf *completion* nil)
                     (say head (format nil "no /command starts with ~s" buf)))))))
      (setf (head-dirty head) t))))

(defun %key-type (key)
  "The TYPE the ladders dispatch on.

A wheel event is `(:type :mouse :kind :wheel-up)`, and the ladders dispatch on
TYPE — so their `:wheel-up` / `:wheel-down` arms never matched and a wheel did
NOTHING, in the transcript and in every pane. The kind is the key for a wheel; a
press keeps `:mouse`, which the click arm reads."
  (let ((k (getf key :kind)))
    (if (and (eq (getf key :type) :mouse) (member k '(:wheel-up :wheel-down)))
        k
        (getf key :type))))

(defun %ctrl-c-p (key)
  (and (eq (getf key :type) :ctrl) (eql (getf key :ch) #\c)))

(defun %refuse-secret (head)
  (%send head (list :frame "secret"
                    :req-id (getf (head-secret-req head) :req-id)
                    :secret nil))
  (setf (head-secret-req head) nil (head-secret-buf head) ""))

(defun %secret-key (head key type)
  "The secret card owns every key while it is up: a password field is not a
composer and must never leak into one (app.rs:2985-3016).

Two of these arms were missing and one of them mattered: **`ctrl-c` refuses the
prompt**, beside Esc. With a password ask on the screen there was no way to
refuse it with the key a person reaches for — Esc worked, ctrl-c fell through the
whole ladder and offered to quit the head. `ctrl-u`/`ctrl-k` clear the field,
which is the other half of the reference's arm, and a PASTED password is trimmed
of the trailing newline the copy took with it: sending that newline is a password
that does not match and no way to see why."
  (case type
    ((:char) (setf (head-secret-buf head)
                   (concatenate 'string (head-secret-buf head)
                                (string (getf key :ch)))))
    ((:paste) (setf (head-secret-buf head)
                    (concatenate 'string (head-secret-buf head)
                                 (string-right-trim '(#\newline #\return)
                                                    (or (getf key :text) "")))))
    ((:backspace) (setf (head-secret-buf head)
                        (subseq (head-secret-buf head)
                                0 (max 0 (1- (length (head-secret-buf head)))))))
    ((:enter)
     (%send head (list :frame "secret"
                       :req-id (getf (head-secret-req head) :req-id)
                       :secret (head-secret-buf head)))
     (setf (head-secret-req head) nil (head-secret-buf head) ""))
    ((:ctrl)
     (case (getf key :ch)
       ((#\c) (%refuse-secret head))
       ((#\u #\k) (setf (head-secret-buf head) ""))))
    ((:esc) (%refuse-secret head)))
  (setf (head-dirty head) t)
  t)

(defun %quit-card-key (head key type)
  "The quit card: leave, or leave and stop the daemon (v20)."
  (flet ((leave (choice)
           (setf (head-quit-open head) nil)
           (unless (zerop choice)
             ;; the answer that stops the daemon travels over the protocol,
             ;; not around it to a pid (protocol.rs, v20)
             (%send head (make-stop (session-expected-seq (head-session head))
                                    "leticl")))
           (setf (head-running head) nil)))
    (case type
      ;; two rows: up and down both flip
      ((:up :down) (setf (head-quit-sel head) (- 1 (min 1 (head-quit-sel head)))
                         (head-dirty head) t))
      ((:enter) (leave (head-quit-sel head)))
      ;; `1` and `2` choose, as the hint bar says, when there is nothing typed
      ((:char)
       (let ((d (digit-char-p (getf key :ch))))
         (when (and d (<= 1 d 2)
                    (zerop (length (composer-buffer (head-composer head)))))
           (leave (1- d)))))
      ;; esc — and a THIRD ctrl-c — close the card. The reference's hint bar
      ;; used to say "ctrl+c again to exit", which stopped being true the
      ;; moment the second press started opening a card: the habitual double
      ;; press must not leave.
      ((:esc) (setf (head-quit-open head) nil (head-dirty head) t)
              (say head "staying"))
      ((:ctrl) (when (eql (getf key :ch) #\c)
                 (setf (head-quit-open head) nil (head-dirty head) t)
                 (say head "staying")))
      (t nil)))
  t)

(defun %global-chord (head key)
  "The chords that belong to the HEAD rather than to whatever is on the screen:
`ctrl-r t x l o` and the four pane toggles. T when the chord was claimed.

**They run before any view**, which is where the reference runs them
(app.rs:3017-3245) and where this head did not: they lived at the bottom of
`%normal-key`, under the pane arm, so a pane swallowed every one of them —
`ctrl-l` could not repaint a torn screen while a pane was up, and `ctrl-o` could
not background a command while you were reading the jobs list.

Hoisting them is also what makes the pane chords TOGGLE. Every one of these is a
toggle in the reference and reads as one; here the second press was eaten by the
pane the first press opened, so `ctrl-s ctrl-s` left the picker on the screen and
Esc was a second thing to remember per pane."
  (when (eq (getf key :type) :ctrl)
    (flet ((pane (mode verb)
             (if (eq (head-mode head) mode)
                 (setf (head-mode head) :normal (head-dirty head) t)
                 (%command head verb))
             t))
      (case (getf key :ch)
        ((#\r) (%flip-fold head :show-reasoning) t)   ; fold the thinking
        ((#\t) (%flip-fold head :show-tools) t)       ; fold tool output
        ((#\l) (setf (head-full-repaint head) t (head-dirty head) t) t)
        ;; `o` on the subagents pane switches INTO the row under the cursor
        ;; (app.rs:3696-3707); anywhere else it promotes the running command,
        ;; which is what this chord has always meant here.
        ((#\o) (if (eq (head-mode head) :subagents)
                   (subagent-switch head)
                   (%command head "promote"))
               t)
        ((#\s) (pane :picker "sessions"))             ; the session list
        ((#\p) (pane :todos "todos"))                 ; the todos pane
        ((#\g) (pane :subagents "subagents"))         ; the subagent tree
        ((#\q) (pane :jobs "jobs"))                   ; the jobs pane
        ((#\x)
         ;; raw `<function=…>` markup, which is NOT a fold: a fold hides
         ;; something the reader knows is there, while this reveals markup the
         ;; default view is required never to show. Off by default and behind a
         ;; chord, both halves of what was asked for.
         (setf (getf (head-prefs head) :raw-calls)
               (not (getf (head-prefs head) :raw-calls))
               (head-dirty head) t)
         t)
        (t nil)))))

(defun %pick-card-top (head)
  "The screen row the picker card's FIRST line landed on.

Recomputed from the layout rather than read off the last paint, because the
render records where a PANE landed (`*pane-room*`, `*pane-scroll*`) and nothing
records where a CARD did. The arithmetic is `%render`'s own, bottom up: the hint
bar is the last row, the composer box sits on it, and the card sits on the box
(render.lisp:306-312, 396-398). A `*card-top*` set by the render would be the
honest version of this and belongs to that file."
  (let* ((cols (max 20 (- (head-cols head) +gutter+ +right-margin+)))
         (composer-rows (length (composer-line head cols)))
         (card-rows (length (pick-card-lines head cols))))
    (- (head-rows head) 1 composer-rows card-rows)))

(defun %pick-click (head row)
  "A click on the mode/model picker card: the row under the pointer becomes the
cursor's row, and NOTHING is taken — select and confirm stay two acts, because a
gesture that commits on press is how a misclick moves somebody's session
(app.rs:3639-3651).

The card runs with `head-mode` :normal and `*pick-open*` set, so the pane click
arm — which tests `head-mode` — never saw it and a click on the card fell through
to the composer and was dropped."
  (let* ((n (length (pick-choices head)))
         ;; the card's first line is its title; the choices follow, one a row
         (sel (- row (%pick-card-top head) 1)))
    (when (and (plusp n) (<= 0 sel) (< sel n))
      (setf (head-picker-sel head) sel (head-dirty head) t))
    t))

(defun %click (head key)
  "A CLICK selects the row under the pointer. T when the click was a list's.

Before the text keys, because a click is unambiguous about what it means and
there is nothing else to weigh it against. Guarded by the rows the frame actually
DREW — a click into the space below a short list must not select a row nobody can
see, which is why the pane records its room and offset from the last paint rather
than from the click."
  (let ((row (getf key :y)))
    (cond
      (*pick-open* (%pick-click head row))
      ((member (head-mode head) '(:picker :jobs :subagents :todos :config))
       ;; the pane starts at screen row 1 (row 0 is the top border), and the
       ;; offset says how many pane LINES are hidden above it
       (let ((line (+ *pane-scroll* (- row 1))))
         (when (and (>= line 0) (< line (+ *pane-scroll* *pane-room*)) (< line *pane-lines*))
           ;; the cursor counts ROWS and the click found a LINE; the panes that
           ;; own a cursor report where their first row sits, so walk back
           (let ((sel (click-row->sel head (head-mode head) line)))
             (when sel
               (setf (head-picker-sel head) sel
                     (head-dirty head) t)))))
       t)
      (t nil))))

(defun %subagent-switch (head)
  "`o` on the subagent tree: open that subagent's session for good.

Enter READS a subagent without leaving this session and `o` MOVES — two keys,
one apart, and the pane's own last line says so (`o switches into it`). The key
did not exist here, because the pane arm read only `q` out of a printable
character (app.rs:3696-3706)."
  (let ((row (nth (head-picker-sel head) (subagent-rows head))))
    (cond ((null row) nil)
          ((equal (getf row :state) "opening")
           (say head "that subagent is still opening — nothing to attach to yet"))
          (t (awhen (getf row :session-id)
               (setf (head-mode head) :normal)
               (%send head (make-switch it 0))
               (setf (head-dirty head) t))))))

(defun %job-out-page (head forward)
  "The job-output overlay's paging — the reference's `job_out_page`
(app.rs:6828-6853).

FORWARD asks for the page after the one on screen, or RE-READS the last page
when the end is already here, because a running job appends and that is how you
see what it has written since. `(not forward)` walks back the way forward came,
and does nothing at the front of the log, where there is no page before the first
byte.

**The `:back` stack lives on the head because the page size is the DAEMON's.**
The head remembers the offsets it was GIVEN rather than recomputing `from - page`
— the same reason `next` arrives on the event at all: only the daemon knows how
much of the ring survives, and a second copy of that number here would page the
two sides in circles."
  (let ((view *job-out*))
    (when view
      (let ((offset (if forward
                        (let ((at (getf view :from)))
                          (when (getf view :next)
                            (setf (getf view :back)
                                  (append (getf view :back) (list at))))
                          (or (getf view :next) at))
                        (let ((back (getf view :back)))
                          (when back
                            (setf (getf view :back) (butlast back))
                            (car (last back)))))))
        (when offset
          (setf (getf view :loading) t
                (head-dirty head) t)
          (%send head (make-read-job-output (getf view :job) offset))
          t)))))

(defun %pane-enter (head)
  "Enter on a full-body screen, per pane."
  (case (head-mode head)
    (:config
     ;; ENTER CHANGES IT. The pane lists the head's own choices and it
     ;; can change them in place — which is what was asked for: a pane
     ;; with runtime-editable configurations, not a list to read. The
     ;; cursor walks EVERY row now, as the reference's does, and
     ;; `config-change` says what each kind of row does on Enter.
     (config-change head))
    (:subagents
     ;; the pane's enter is the one it advertises: read that subagent's
     ;; scrollback without moving this session there. It is `peek`, the command
     ;; that existed as a frame nobody sent. A subagent still `opening` has
     ;; nothing to read and the daemon would refuse the peek by name, so saying
     ;; it here keeps the operator in the pane they were using rather than
     ;; bouncing them through a rejection (app.rs:3678-3689).
     (let ((row (nth (head-picker-sel head) (subagent-rows head))))
       (cond ((null row) nil)
             ((equal (getf row :state) "opening")
              (say head "that subagent is still opening — nothing to read yet"))
             (t (awhen (getf row :session-id)
                  (%send head (make-peek it))
                  (setf (head-status-note head)
                        (format nil "peeking ~a…" it)))))))
    (:peek
     ;; The pane's hint bar says *"enter re-reads"* and it did not: `:peek` was
     ;; not in this case at all. A running subagent has new output, which is the
     ;; whole reason to press it again (app.rs:3272-3277).
     (awhen *peeked-session*
       (%send head (make-peek it))
       (setf (head-status-note head) (format nil "re-reading ~a…" it))))
    (:jobs
     ;; **Enter opens the job's output IN A PANE, not in the conversation.**
     ;;
     ;; This arm used to send `/job ID` as a slash line and close the pane. A
     ;; slash reply is a `Warning` on the session log, so for a finished job the
     ;; operator got a 16 KB build log scrolling past in the chat and the list
     ;; they were reading gone. Their words, 2026-09-20: *"on the job pane when i
     ;; press enter im not shown the tailed job output but brought back to the
     ;; conversation with /job <id> sent"*, and the earlier narrowing that says
     ;; which half was broken: *"entering the running job works fine - but
     ;; finished does /job <id>"* — one path served both, and what differed was
     ;; the size of the reply.
     ;;
     ;; Now it is a `ReadJobOutput`: the answer comes back as a `JobOutput` event
     ;; with the offsets attached and the overlay draws it. The jobs list stays
     ;; behind it — `head-mode` moves, `head-jobs` and `head-picker-sel` do not —
     ;; so Esc returns to the row the operator chose (app.rs:3776-3805).
     (let ((row (nth (head-picker-sel head) (head-jobs head))))
       (awhen (and row (getf row :id))
         ;; opened BEFORE the send: `apply-event` folds a window only into an
         ;; overlay already open for that job
         (open-job-out it)
         (setf (head-mode head) :job-out)
         (%send head (make-read-job-output it 0)))))
    (:job-out
     ;; Enter takes the next page, or re-reads the last one when the end is
     ;; already here — a running job appends, and that is how you see what it
     ;; has written since (app.rs:3272-3277, the same key on the peek pane).
     (%job-out-page head t))
    (:todos
     ;; Enter unfolds the repo item under the cursor — the operator
     ;; asked for this directly: *"if a todo has some associated text?
     ;; should i be able to expand it somehow?"*. The cursor is first
     ;; SNAPPED to an item (a cursor at 0 on a heading counts from the
     ;; first item below it, as the reference's `stops[at]` does), then
     ;; the one flag flips: at most one item is open, and moving folds it.
     (let* ((rows (repo-todo-rows-cached
                   (getf (session-wiring (head-session head)) :workspace)))
            (stops (repo-todo-stops rows)))
       (when stops
         (let ((at (or (position-if (lambda (i) (>= i (head-picker-sel head))) stops)
                       0)))
           (setf (head-picker-sel head) (nth at stops)
                 *repo-todo-open* (not *repo-todo-open*))))))
    (:picker
     (let ((hit (nth (head-picker-sel head)
                     (picker-sessions (head-session head)))))
       (when hit
         (%send head (make-switch (getf hit :session-id) 0))
         (setf (head-mode head) :normal)))))
  (setf (head-dirty head) t))

(defun %pane-key (head key type)
  "A full-body screen's own keys. T when the pane claimed the key — and
**anything else is the COMPOSER's**.

That last clause is the whole change. This arm used to claim every key for the
nine modes and read only `q` out of a printable one, so no character reached the
composer while any pane was open — including the session picker, whose own hint
bar says *\"type a number to switch · /new [title]\"* and meant neither
(chrome.lisp:363). A pane open was a head you could not talk to: Esc out, type,
and lose the list. The reference lets a pane's text fall through and gates only
Enter and the pane's own letters on an empty line (app.rs:3370-3394, 3508-3548).

`esc`/`q` closes any of them; the LIST panes also take a cursor (up/down) and an
enter, and they share ONE cursor — `head-picker-sel` — because only one pane is
open at a time, which is the same argument the pane scroll offset makes. A
per-pane cursor would be a `head` slot each, and a struct slot is a RESTART: the
one thing this head must not need."
  (let ((mode (head-mode head))
        (empty (zerop (length (composer-buffer (head-composer head))))))
    (flet ((rows () (pane-row-count head mode))
           ;; **Esc in the peek pane means back to the TREE**, not close
           ;; everything — the reference's `sub_out` arm sits ahead of the
           ;; generic Esc for exactly that (app.rs:3251-3262). Everywhere else
           ;; it is `:normal`.
           (shut () (setf (head-mode head) (pane-escape-target (head-mode head))
                          (head-dirty head) t)
             ;; the overlay goes with the key that leaves it: a window kept open
             ;; after Esc would quietly take the answer to a read nobody is
             ;; waiting for any more (app.rs:3277-3281)
             (when (eq mode :job-out) (close-job-out))
             (reset-pane-scroll)
             t))
      (flet ((move-cursor (n)
               (setf (head-picker-sel head)
                     (max 0 (min (max 0 (1- (rows))) (+ (head-picker-sel head) n)))
                     (head-dirty head) t)
               ;; and the offset follows the cursor, so a selection is never
               ;; scrolled off the screen it is being made on
               (scroll-pane-into-view (head-picker-sel head)))
             (scroll (n)
               ;; **N is "toward the beginning is negative", which is
               ;; `*pane-scroll*`'s sign for an ordinary pane and the OPPOSITE of
               ;; it for the job-output overlay.** That pane's origin is its TAIL
               ;; — `job-out-lines` windows `end = total - scroll`, because a
               ;; running job appends and the newest bytes are what the pane was
               ;; opened for — so the offset there counts rows hidden BELOW the
               ;; bottom, and moving toward the beginning ADDS to it. Every key
               ;; that scrolls goes through here, so the arrows, the page keys
               ;; and the wheel cannot disagree about which way is back.
               (pane-scroll-by (if (eq mode :job-out) (- n) n))
               (setf (head-dirty head) t)
               t))
        (case type
          ((:esc :q-press) (shut))
          ;; The todos pane's cursor stops only on the repo's ITEMS and wraps
          ;; at either end — the reference's `stops` (app.rs:3268). Measured:
          ;; from the top, two Downs land on T3 (T1's stop is where a cursor on
          ;; the heading above it counts from), and Enter there unfolds T3.
          ;; Moving folds whatever was open.
          ((:up :down)
           (let ((n (if (eq type :up) -1 1)))
             (case mode
               (:todos (%todos-move head n))
               ;; the peek view has no rows to walk — `pane-row-count` says 0 —
               ;; so its arrows SCROLL, which is what its hint bar promises and
               ;; what `move-cursor` could never do on it (app.rs:3260-3270).
               ;; The polarity is the pane's: up moves toward the beginning,
               ;; the same direction PgUp goes.
               (:peek (pane-scroll-by n) (setf (head-dirty head) t))
               ;; the job-output overlay is the same shape: a window of bytes
               ;; with no rows to select, so its arrows scroll the loaded window
               ;; rather than walking a cursor (app.rs:3256-3268)
               (:job-out (scroll n))
               (t (move-cursor n))))
           t)
          ;; **→ and ← PAGE the job-output overlay**, by the offsets the daemon
          ;; named — and they are the overlay's alone: anywhere else these are the
          ;; composer's cursor keys, which is why this arm tests the mode rather
          ;; than claiming the key for every pane.
          ((:left :right)
           (when (and (eq mode :job-out) empty)
             (%job-out-page head (eq type :right)))
           (and (eq mode :job-out) empty))
          ;; PAGE and WHEEL scroll the PANE. They used to be swallowed here,
          ;; which left a pane taller than the body with no way to see the rest
          ;; of it — and the repo's own TODO.md is 98 rows. The polarity is
          ;; `*pane-scroll*`'s, which is the OPPOSITE of the transcript's: page
          ;; DOWN moves forward through the pane.
          ((:page-down) (scroll (max 1 (- *pane-room* 1))))
          ((:page-up) (scroll (- (max 1 (- *pane-room* 1)))))
          ((:wheel-down) (scroll 3))
          ((:wheel-up) (scroll -3))
          ;; Tab unfolds a todo, BESIDE enter and under enter's own condition, so
          ;; the two cannot disagree about whose key it is. On every OTHER pane it
          ;; is not the pane's key at all: it used to set `head-dirty` to NIL
          ;; there — against its own comment — which suppressed the next repaint.
          ((:tab) (when (and (eq mode :todos) empty) (%pane-enter head))
                  (and (eq mode :todos) empty))
          ((:enter) (when empty (%pane-enter head)) empty)
          ((:char)
           (let ((ch (getf key :ch)))
             (cond ((not empty) nil)
                   ((eql ch #\q) (shut))
                   ((and (eql ch #\o) (eq mode :subagents)) (%subagent-switch head) t)
                   (t nil))))
          (t nil))))))

(defun %ladder-key (head key type)
  "The :normal ladder — the decision ask, then the composer.

**Up and Down move the ladder whether or not a line is being typed.** The whole
arm used to be gated on an empty composer, and the cost of that was not visible
until the operator hit it: a permission arrives while you are typing, and the only
way into the menu was to empty the composer first — so the words you were writing
were the price of choosing an option. Their words, 2026-09-20: *\"suppose i type a
prompt and permission ask arrives — until i press down arrow I wont get into the
permissions menu, by which time my prompt is erased and gone\"*.

Nothing is taken from the composer by that: a one-line composer does not edit
with Up and Down, and what moves aside is scrollback scrolling for as long as an
ask is open — PageUp and PageDown still do that.

**Enter and the digits keep the empty-composer guard**, for the opposite reason:
with a typed line Enter is `%submit-line`'s, which answers the marked row and
HOLDS the words, and a line being typed keeps its digits (app.rs:3474-3498)."
  (let* ((decision (%open-decision head))
         (options (decision-options decision))
         (n (length options))
         (empty (zerop (length (composer-buffer (head-composer head))))))
    (if (and decision (plusp n))
        (case type
          ((:up) (setf (head-decision-sel head) (max 0 (1- (head-decision-sel head)))
                       (head-dirty head) t))
          ((:down) (setf (head-decision-sel head)
                         (min (1- n) (1+ (head-decision-sel head)))
                         (head-dirty head) t))
          ((:enter) (if empty
                        (%answer-decision head (head-decision-sel head))
                        (%normal-key head key)))
          ((:char)
           (let ((digit (digit-char-p (getf key :ch))))
             ;; a digit that names no row is the composer's, as is every digit
             ;; once a line is being typed
             (if (and empty digit (<= 1 digit n))
                 (%answer-decision head (1- digit))
                 (%normal-key head key))))
          (t (%normal-key head key)))
        (%normal-key head key))))

(defun %handle-key (head key)
  "Who a key belongs to, in the reference's precedence order (`App::key`).

The ladder is one `cond` and the reference's is one `match`, which is what makes
the ORDER reviewable: the cards that own the keyboard, then the head's own
chords, then a click, then whatever list is on the screen, then the composer."
  (let ((type (%key-type key)))
    (cond
      ((eq type :eof) (setf (head-running head) nil))
      ;; the secret card owns everything while it is up: a password field is
      ;; not a composer and must never leak into one
      ((head-secret-req head) (%secret-key head key type))
      ;; the `allow-all` question owns every key while it is up
      (*mode-confirm* (mode-confirm-key head key))
      ;; the quit card: leave, or leave and stop the daemon (v20)
      ((head-quit-open head) (%quit-card-key head key type))
      ;; the head's own chords, before any view — see `%global-chord`
      ((%global-chord head key))
      ;; `ctrl-c` closes whatever list is on the screen, exactly as Esc does
      ;; (app.rs:3273, 3306, 3321, 3379). It was unhandled in the pane arm and in
      ;; `pick-key-event`, so it fell through both and offered to quit the head
      ;; instead of closing the thing the operator was looking at.
      ((and (%ctrl-c-p key)
            (or *pick-open*
                (member (head-mode head)
                        '(:help :status :config :jobs :subagents :peek :job-out :todos :picker))))
       (if *pick-open*
           (close-pick head)
           (progn
             ;; the job-output overlay is a SPECIAL, not a mode flag, so leaving
             ;; the mode is not leaving the overlay: an open one would go on
             ;; taking windows into a pane nobody can see (app.rs:3277-3281)
             (when (eq (head-mode head) :job-out) (close-job-out))
             (setf (head-mode head) :normal (head-dirty head) t)))
       t)
      ((and (eq type :mouse) (eq (getf key :kind) :press) (%click head key)))
      ;; a picker's own keys; what it does not take is the composer's, so a name
      ;; can be typed under the card
      ((and *pick-open* (pick-key-event head key)))
      ((and (member (head-mode head)
                    '(:help :status :config :jobs :subagents :peek :job-out :todos :picker))
            (%pane-key head key type)))
      (t (%ladder-key head key type)))))

(defun %withdraw-queued (head)
  "Take the last queued prompt back into the composer (v19).

On `↑` with an empty composer at the tail, which is where the reference puts it
(app.rs:3851-3861). It used to be on `ctrl-u` — which also means kill-to-start,
so one chord carried two meanings — and the one key readline taught for *the
previous entry* did not do it."
  (let ((text (first (last (head-queued head)))))
    (%send head (make-withdraw-prompts (session-expected-seq (head-session head))))
    (setf (head-queued head) (butlast (head-queued head)))
    (composer-insert (head-composer head) (or text ""))
    (setf (head-dirty head) t)))

(defun %ctrl-c (head)
  "`ctrl-c` on the composer — the reference's `Key::CtrlC` (editor.rs:466-484).

Three things it did not do. **A non-empty composer is CLEARED**, never quit:
ctrl-c to clear a half-written paragraph offered to leave the head instead, while
`/help` and the hint bar both promised the clear (panes.lisp:164,
chrome.lisp:358). **An empty one ARMS**, and only a second press within a second
opens the quit card — the first press is the warning, and a warning is the whole
mechanism by which anybody learns the second press does something. And it no
longer interrupts a running turn: the interrupt is `esc esc`, which is exactly
what the hint bar says while one runs (`esc interrupt · ctrl+c clear`)."
  (let ((c (head-composer head)))
    (if (plusp (length (composer-buffer c)))
        (progn (setf *ctrlc-at* nil)
               (%undo-push c)
               (setf (composer-buffer c) ""
                     (composer-cursor c) 0
                     ;; the markers left with the line they were standing in, so
                     ;; the ledger goes with them (editor.rs:475)
                     *paste-ledger* nil
                     (head-dirty head) t))
        (let ((now (get-internal-real-time))
              (ms (/ internal-time-units-per-second 1000.0)))
          (if (and *ctrlc-at* (< (- now *ctrlc-at*) (* *ctrlc-window-ms* ms)))
              (setf *ctrlc-at* nil
                    (head-quit-open head) t
                    (head-quit-sel head) 0
                    (head-dirty head) t)
              (setf *ctrlc-at* now (head-dirty head) t))))))

(defun %normal-key (head key)
  (let ((c (head-composer head))
        ;; a wheel is its KIND, as `%handle-key` reads it — see there
        (type (%key-type key)))
    ;; **Any key that is not Esc disarms the interrupt double-tap**, and any key
    ;; that is not ctrl-c disarms the quit one (editor.rs:304-306). `*esc-at*`
    ;; used to be cleared only by a second Esc: press Esc, type a paragraph, press
    ;; Esc four seconds later, and the turn was interrupted — with the hint bar
    ;; promising exactly that the whole time.
    (unless (eq type :esc) (setf *esc-at* nil))
    (unless (%ctrl-c-p key) (setf *ctrlc-at* nil))
    ;; a horizontal act ends the vertical walk: the sticky column belongs to a run
    ;; of ↑/↓ and to nothing else
    (unless (member type '(:up :down)) (setf *preferred-col* nil))
    (case type
      ((:char)
       ;; one undo snapshot per word: push when the character before the cursor
       ;; ends a word, so ctrl-z takes back a word rather than a letter
       (let ((before (composer-buffer c))
             (i (composer-cursor c)))
         (when (or (zerop i)
                   (let ((prev (char before (1- i))))
                     (and (or (char= prev #\space) (char= prev #\newline))
                          (not (char= (getf key :ch) #\space))
                          (not (char= (getf key :ch) #\newline)))))
           (%undo-push c)))
       (composer-insert c (string (getf key :ch)))
       (setf (head-dirty head) t))
      ((:paste)
       (%undo-push c)
       (composer-insert-paste c (getf key :text))
       (setf (head-dirty head) t))
      ((:backspace) (composer-delete-backward c) (setf (head-dirty head) t))
      ((:delete) (composer-delete-forward c) (setf (head-dirty head) t))
      ((:enter) (%submit-line head))
      ((:tab) (%complete head))
      ((:left :right :home :end) (composer-move c type) (setf (head-dirty head) t))
      ((:word-left :word-right) (composer-move c type) (setf (head-dirty head) t))
      ((:kill-word-back) (%undo-push c) (composer-kill-word c) (setf (head-dirty head) t))
      ((:redo) (when (composer-redo c) (setf (head-dirty head) t)))
      ((:up)
       (cond
         ;; an EMPTY composer at the tail with a prompt queued: take it back
         ((and (zerop (length (composer-buffer c)))
               (zerop (head-scroll head))
               (head-queued head))
          (%withdraw-queued head))
         ;; inside a multi-line prompt ↑ moves one VISUAL row, and only walks
         ;; history from the top one — what every editor does, and what `/help`
         ;; already promised: *"↑ ↓ move inside the prompt"* (panes.lisp:164)
         ((composer-vertical head t))
         (t (composer-history-step c -1)))
       (setf (head-dirty head) t))
      ((:down)
       ;; parked in the scrollback, ↓ follows the stream again — it is what the
       ;; banner says it does; only then does it move inside the prompt
       (cond ((plusp (head-scroll head)) (setf (head-scroll head) 0))
             ((composer-vertical head nil))
             (t (composer-history-step c 1)))
       (setf (head-dirty head) t))
      ((:alt)
       ;; alt+enter is a newline inside the prompt. Any other alt chord is not
       ;; the composer's, and must not become text — an unhandled chord that
       ;; inserts its own letter is how a prompt grows a stray `x`.
       (when (and (getf key :ch) (char= (getf key :ch) #\return))
         (%undo-push c)
         (composer-insert c (string #\newline))
         (setf (head-dirty head) t)))
      ((:esc)
       ;; Esc while parked in the scrollback means "follow the stream again",
       ;; which is what the banner says it means. Only then does esc start
       ;; arming an interrupt: `esc esc` — twice within the gesture window.
       (when (plusp (head-scroll head))
         (setf (head-scroll head) 0 (head-dirty head) t)
         (return-from %normal-key nil))
       (let ((now (get-internal-real-time))
             (ms (/ internal-time-units-per-second 1000.0)))
         (if (and *esc-at* (< (- now *esc-at*) (* *esc-double-ms* ms)))
             (progn (setf *esc-at* nil)
                    (when (and (session-turn (head-session head))
                               (string= (turn-state-name (session-turn (head-session head)))
                                        "running"))
                      (%interrupt head "interrupted with esc esc")))
             (setf *esc-at* now))))
      ((:page-up) (incf (head-scroll head) (max 1 (- (head-rows head) 3)))
                  (setf (head-dirty head) t))
      ((:page-down) (setf (head-scroll head) (max 0 (- (head-scroll head)
                                                       (max 1 (- (head-rows head) 3)))))
                    (setf (head-dirty head) t))
      ((:wheel-up) (incf (head-scroll head) 3) (setf (head-dirty head) t))
      ((:wheel-down) (setf (head-scroll head) (max 0 (- (head-scroll head) 3)))
                     (setf (head-dirty head) t))
      ((:ctrl)
       (case (getf key :ch)
         ((#\c) (%ctrl-c head))
         ((#\d)
          ;; quit only on an EMPTY composer (editor.rs:485-491). It used to quit
          ;; unconditionally, so the chord that means "end of input" also meant
          ;; "throw away the paragraph I am in the middle of".
          (when (zerop (length (composer-buffer c)))
            (setf (head-running head) nil)))
         ((#\u) (%undo-push c) (composer-kill-line c) (setf (head-dirty head) t))
         ((#\k) (%undo-push c) (composer-kill-to-end c) (setf (head-dirty head) t))
         ((#\w) (%undo-push c) (composer-kill-word c) (setf (head-dirty head) t))
         ((#\y) (when (composer-yank c) (setf (head-dirty head) t)))
         ((#\z) (when (composer-undo c) (setf (head-dirty head) t)))
         ((#\a) (composer-move c :home) (setf (head-dirty head) t))
         ((#\e) (composer-move c :end) (setf (head-dirty head) t)))
       ;; a ctrl chord that means nothing here must not become text. The chords
       ;; that belong to the HEAD rather than to the composer — ctrl-r t x l o s
       ;; p g q — are `%global-chord`'s, which ran above this and before any view.
       )
      (t nil))))


(defstruct (composer (:constructor make-composer ()))
  (buffer "" :type string)
  (cursor 0 :type fixnum)
  (history (make-array 0 :adjustable t :fill-pointer 0) :type vector)
  (hist-pos 0 :type fixnum))

(defun composer-insert (c string)
  ;; an EDIT abandons the redo branch: undo, undo, then typing means the
  ;; buffers that undo took back are not coming back (editor.rs:629)
  (setf *redo-stack* nil)
  (setf (composer-buffer c)
        (concatenate 'string
                     (subseq (composer-buffer c) 0 (composer-cursor c))
                     string
                     (subseq (composer-buffer c) (composer-cursor c))))
  (incf (composer-cursor c) (length string)))

(defun composer-delete-backward (c)
  (setf *redo-stack* nil)
  (when (plusp (composer-cursor c))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (1- (composer-cursor c)))
                       (subseq (composer-buffer c) (composer-cursor c))))
    (decf (composer-cursor c))))

(defun composer-delete-forward (c)
  (setf *redo-stack* nil)
  (when (< (composer-cursor c) (length (composer-buffer c)))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (composer-cursor c))
                       (subseq (composer-buffer c) (1+ (composer-cursor c)))))))

;;; ----------------------------------------------------- motion in a prompt ;;;
;;;
;;; This head has had `alt+enter` since S4, so a prompt can be several lines and
;;; several wrapped rows — and none of these keys knew it. `home` went to the
;;; start of the BUFFER, `ctrl-k` killed to the end of the BUFFER, `↑` always
;;; walked history, and there was no word motion at all: a multi-line prompt you
;;; cannot navigate is a prompt you retype. The reference's editor is line-wise
;;; and row-wise throughout (editor.rs:362-389, 500-516, 687-758).

(defun %whitespace-p (ch)
  (member ch '(#\space #\tab #\newline #\return)))

(defun %word-class (ch style)
  "Which side of a word boundary CH is on. `:small` is the reference's
`WordStyle::Small` — a word is alphanumerics and `_`, so `foo_bar.baz` is three
stops; `:big` is `WhitespaceDelimited`, which is what a kill takes."
  (ecase style
    (:small (or (alphanumericp ch) (char= ch #\_)))
    (:big (not (%whitespace-p ch)))))

(defun composer-word-left (buf cursor &optional (style :small))
  "The index one word to the left of CURSOR (`word_left`)."
  (let ((i cursor))
    ;; the whitespace immediately behind the cursor is skipped first, so a press
    ;; at the end of `one two ` lands at the start of `two` and not in the gap
    (loop while (and (plusp i) (%whitespace-p (char buf (1- i)))) do (decf i))
    (if (zerop i)
        0
        (let ((class (%word-class (char buf (1- i)) style))
              (out i))
          (loop for j downfrom (1- i) to 0
                for ch = (char buf j)
                while (and (not (%whitespace-p ch))
                           (eq (%word-class ch style) class))
                do (setf out j))
          out))))

(defun composer-word-right (buf cursor &optional (style :small))
  "The index one word to the right of CURSOR, past the gap after it
(`word_right`) — so a second press lands on the next word rather than the space
before it."
  (let ((n (length buf))
        (out (length buf)))
    (when (< cursor n)
      (let ((class (%word-class (char buf cursor) style)))
        (loop for j from (1+ cursor) below n
              for ch = (char buf j)
              when (or (%whitespace-p ch) (not (eq (%word-class ch style) class)))
                do (setf out j) (return))))
    (loop while (and (< out n) (%whitespace-p (char buf out))) do (incf out))
    out))

(defun composer-line-start (c)
  "The start of the LINE the cursor is on, not of the buffer."
  (let ((i (position #\newline (composer-buffer c)
                     :end (composer-cursor c) :from-end t)))
    (if i (1+ i) 0)))

(defun composer-line-end (c)
  "The end of the LINE the cursor is on."
  (or (position #\newline (composer-buffer c) :start (composer-cursor c))
      (length (composer-buffer c))))

(defun composer-move (c key)
  (case key
    (:left (setf (composer-cursor c) (max 0 (1- (composer-cursor c)))))
    (:right (setf (composer-cursor c) (min (length (composer-buffer c))
                                           (1+ (composer-cursor c)))))
    ;; the LINE's ends, which is what `home` means in every editor and what this
    ;; one got wrong the moment a prompt could hold a newline
    (:home (setf (composer-cursor c) (composer-line-start c)))
    (:end (setf (composer-cursor c) (composer-line-end c)))
    (:word-left (setf (composer-cursor c)
                      (composer-word-left (composer-buffer c) (composer-cursor c))))
    (:word-right (setf (composer-cursor c)
                       (composer-word-right (composer-buffer c) (composer-cursor c))))))

(defun composer-kill-to-end (c)
  "Ctrl+K: cut from the cursor to the end of the LINE, into the kill ring."
  (composer-kill-region c (composer-cursor c) (composer-line-end c)))

(defun composer-kill-line (c)
  "Ctrl+U: cut from the start of the LINE to the cursor, into the kill ring."
  (composer-kill-region c (composer-line-start c) (composer-cursor c)))

(defun composer-kill-word (c)
  "Ctrl+W: cut back to the start of the word before the cursor, into the ring.

Whitespace-delimited, as the reference's is — and whitespace, not `#\\space`
alone: the scan tested for a space, so a newline was not a boundary and one
ctrl-w on a multi-line prompt ate back through the line above."
  (composer-kill-region c
                        (composer-word-left (composer-buffer c) (composer-cursor c) :big)
                        (composer-cursor c)))

(defun composer-push-history (c line)
  "Remember LINE, unless it repeats the newest entry. Oldest dropped past the cap.

Consecutive duplicates are dropped because the shape they come from — send, edit
one word, send again — is the shape that fills the history with the same line and
makes `↑ ↑ ↑` walk nothing (editor.rs:588-593)."
  (let ((h (composer-history c)))
    (unless (and (plusp (fill-pointer h))
                 (string= line (aref h (1- (fill-pointer h)))))
      (vector-push-extend line h)
      (when (> (fill-pointer h) *history-max*)
        (replace h h :start2 1)
        (decf (fill-pointer h))))
    (setf (composer-hist-pos c) (fill-pointer h))))

(defun composer-history-step (c delta)
  "Up/Down through sent lines. T when the buffer moved.

The in-progress line is kept at position `length`, so leaving history restores
what was half-typed — and a RECALLED line that has since been edited stops the
walk, rather than being thrown away by the next press."
  (when (and *history-recalled*
             (not (string= *history-recalled* (composer-buffer c))))
    (return-from composer-history-step nil))
  (let* ((n (length (composer-history c)))
         (target (+ (composer-hist-pos c) delta)))
    (when (<= 0 target n)
      (when (= (composer-hist-pos c) n)
        (setf (get 'composer :draft) (composer-buffer c)))
      (setf (composer-hist-pos c) target)
      (setf (composer-buffer c)
            (if (= target n)
                (or (get 'composer :draft) "")
                (aref (composer-history c) target)))
      (setf (composer-cursor c) (length (composer-buffer c))
            *history-recalled* (composer-buffer c))
      t)))

(defun %offset-in-range (text range col)
  "The index in TEXT, inside the wrapped row RANGE, that sits COL columns in."
  (let ((i (car range))
        (end (cdr range))
        (w 0))
    (loop while (and (< i end) (< w col))
          do (incf w (char-width (char text i)))
             (incf i))
    i))

(defun composer-cols (head)
  "The content width the composer is measured against: the frame less the gutter
and the right margin, which is `%render`'s own `cols` (render.lisp:288).
`composer-ranges` takes it from there to the box's inner width, so motion asks
the same question the painter does, through the same two functions."
  (max 20 (- (head-cols head) +gutter+ +right-margin+)))

(defun composer-vertical (head up)
  "Move the cursor one VISUAL row. T when it moved; NIL at the edge.

By visual row and not by logical line: a pasted paragraph soft-wrapped over six
rows should take six presses to cross, and anything else puts the cursor
somewhere the operator was not looking. The rows are the ones the COMPOSER IS
DRAWN WITH (`composer-ranges`, chrome.lisp), so motion and drawing cannot
disagree about where a row ends.

NIL at the top and bottom is the caller's cue to walk history instead, which is
what a one-line composer's ↑ always meant (editor.rs:500-516)."
  (let* ((c (head-composer head))
         (buf (composer-buffer c))
         (ranges (composer-ranges head (composer-cols head)))
         (rows (length ranges)))
    (multiple-value-bind (row col) (locate-in-ranges buf (composer-cursor c) ranges)
      (let ((col (or *preferred-col* col)))
        (cond ((and up (zerop row)) nil)
              ((and (not up) (>= (1+ row) rows)) nil)
              (t (setf (composer-cursor c)
                       (%offset-in-range buf (nth (if up (1- row) (1+ row)) ranges) col)
                       *preferred-col* col)
                 t))))))



(defun composer-buffer-set (c text)
  "Replace the buffer wholesale, for undo."
  (setf (composer-buffer c) text
        (composer-cursor c) (length text)))

(defun %undo-push (c)
  "Snapshot the buffer, unless it already matches the newest snapshot."
  (unless (and *undo-stack* (string= (car *undo-stack*) (composer-buffer c)))
    (push (composer-buffer c) *undo-stack*)
    (when (> (length *undo-stack*) *undo-max*)
      (setf *undo-stack* (butlast *undo-stack*)))))

(defun composer-undo (c)
  "Undo one snapshot. T when something was undone.

Undo is BATCHED by the caller — a kill pushes its own snapshot, and a run of
characters pushes one at the start of the word — so this pops whatever is there
rather than trying to decide how much to take back. The kill ring is deliberately
untouched: undo restores the document, not the clipboard."
  (when *undo-stack*
    (push (composer-buffer c) *redo-stack*)
    (composer-buffer-set c (pop *undo-stack*))
    t))

(defun composer-redo (c)
  "Redo one undone buffer. T when something came back.

`alt+z`, because Ctrl+Shift+Z arrives byte-identical to Ctrl+Z in many terminals
and there is no second chord to give it (term.rs:740-742)."
  (when *redo-stack*
    (push (composer-buffer c) *undo-stack*)
    (composer-buffer-set c (pop *redo-stack*))
    t))

(defun composer-kill-region (c start end)
  "Cut [START, END) into the kill ring, newest first."
  (let ((buf (composer-buffer c)))
    (when (< start end)
      (setf *redo-stack* nil)
      (push (subseq buf start end) *kill-ring*)
      (when (> (length *kill-ring*) *kill-ring-max*)
        (setf *kill-ring* (butlast *kill-ring*)))
      (setf (composer-buffer c) (concatenate 'string
                                             (subseq buf 0 start)
                                             (subseq buf end))
            (composer-cursor c) start)
      t)))

(defun composer-yank (c)
  "Insert the head of the kill ring at the cursor. T when it did."
  (when *kill-ring*
    (composer-insert c (first *kill-ring*))
    t))

(defun %paste-lines (text)
  "How many lines TEXT holds, as a person would count them.

`(1+ (count #\\newline text))` — the obvious formula — gives 301 for 300 lines
each ending in a newline, because it counts the empty tail as a line. A paste
whose marker says `301 lines` when the operator pasted 300 is a small lie in the
one number the marker exists to carry, so the final newline does not start a
line."
  (let ((n (count #\newline text)))
    (if (and (plusp n) (char= (char text (1- (length text))) #\newline))
        n
        (1+ n))))

(defparameter *paste-bytes* 800
  "A paste this long collapses to a marker whatever its line count — the
reference's `PASTE_BYTES`. Five lines is not the only shape a paste nobody wants
in the composer comes in: a three-line, four-kilobyte log fills the box and
pushes the transcript off the screen, and the line count says `3`.")

(defun %paste-marker (n)
  "The marker for a paste of N lines, NUMBERED.

**The number is what makes it unique**, and it was not there: the marker keyed on
the line count alone, so two twelve-line pastes in one prompt produced the SAME
marker and `expand-pastes` replaced both occurrences with whichever text the
ledger found first. Two stack traces pasted into one prompt became the same stack
trace twice — silent corruption in the one path that exists to carry large text
faithfully (editor.rs:564-566). The count of the ledger is the number, and the
ledger is cleared per submitted line, so it restarts at 1 for every prompt."
  (format nil "[⋮ pasted ~a lines #~d ⋮]" n (1+ (length *paste-ledger*))))

(defun %normalise-paste (text)
  "CRLF, then bare CR, to newlines.

Windows ConPTY sends CR-only newlines inside a bracketed paste, and a naive
CRLF replace leaves those behind as control characters a terminal renders as a
carriage return — and the line count is wrong as well (editor.rs:557-561)."
  (substitute #\newline #\return
              (with-output-to-string (s)
                (loop for i from 0 below (length text)
                      for ch = (char text i)
                      unless (and (char= ch #\return)
                                  (< (1+ i) (length text))
                                  (char= (char text (1+ i)) #\newline))
                        do (write-char ch s)))))

(defun composer-insert-paste (c text)
  "Insert TEXT, or a marker standing for it when it is large.

A three-thousand-line paste as three thousand lines of composer is a buffer
nobody can see the end of; as a marker it is one visible token that still sends
whole. The marker is opaque and the ledger holds the text, so nothing is lost by
rounding. Large is five lines OR more than `*paste-bytes*` of it."
  (let ((text (%normalise-paste text)))
    (if (and (< (%paste-lines text) 5)
             (<= (length text) *paste-bytes*))
        (progn (composer-insert c text) nil)
        (let ((marker (%paste-marker (%paste-lines text))))
          (push (cons marker text) *paste-ledger*)
          (composer-insert c marker)
          marker))))

(defun expand-pastes (text)
  "Replace every paste marker in TEXT with the text it stands for."
  (let ((out text))
    (dolist (pair *paste-ledger*)
      (when (search (car pair) out)
        (setf out (with-output-to-string (s)
                    (let ((i 0)
                          (marker (car pair))
                          (full (cdr pair)))
                      (loop for j = (search marker out :start2 i)
                            while j
                            do (write-string (subseq out i j) s)
                               (write-string full s)
                               (setf i (+ j (length marker))))
                      (write-string (subseq out i) s))))))
    out))

;;; ------------------------------------------------------------- click ;;;
;;;
;;; A click lands on a pane LINE; the cursor counts pane ROWS. The two differ by
;;; every header line above the list — the reference found this in its own test
;;; after passing one where the other was meant — so the conversion is done in
;;; ONE place per pane rather than recomputed at the click site.

(defun click-header-lines (head)
  "How many lines of MODE's pane come before its first selectable row.

Read from the pane function itself, by asking it where the cursor is with the
cursor forced to row 0: a pane that owns a cursor returns `header + sel` as its
second value, so at 0 that value IS the header. Asking rather than recounting
means the two cannot drift — a header that grows (a click hint, say) moves both
together."
  (let* ((mode (head-mode head))
         (saved (head-picker-sel head)))
    (unwind-protect
         (progn
           (setf (head-picker-sel head) 0)
           (multiple-value-bind (lines sel-line)
               (case mode
                 (:picker (picker-lines (head-session head) 0 80))
                 (:jobs (jobs-lines head 80))
                 (:subagents (subagent-lines head 80))
                 (:todos (todos-lines head 80))
                 (:config (config-lines head (head-settings head) 80))
                 (t (values nil nil)))
             (declare (ignore lines))
             (or sel-line 0)))
      (setf (head-picker-sel head) saved))))

(defun click-row->sel (head mode line)
  "The cursor ROW a click on pane LINE means, or NIL when it is not a row.

Guarded three ways, and every one of them is a click that must not select
something nobody can see:

  · the line must be inside the WINDOW THE FRAME ACTUALLY DREW — not merely
    inside the list. A click in the blank space below a short list, or below a
    truncated one, lands on a line that is not on screen;
  · it must be past the header, which is not a row;
  · and it must be within the list.

The first guard is here rather than at the call site so it cannot be forgotten
by a second caller — which is how the reference found this, in its own test."
  (declare (ignore mode))
  (let* ((window-start *pane-scroll*)
         (window-end (+ *pane-scroll* *pane-room*))
         ;; the picker, the jobs and the subagents draw TWO lines per row — the
         ;; row and the dim fact line under it — so a click on either half is
         ;; the same row
         (per-row (if (member (head-mode head) '(:picker :jobs :subagents)) 2 1))
         (sel (floor (- line (click-header-lines head)) per-row))
         (n (pane-row-count head (head-mode head))))
    (when (and (>= line window-start) (< line window-end)
               (>= sel 0) (< sel n))
      sel)))

(defun pane-row-count (head mode)
  "How many ROWS the pane MODE has for its cursor to walk — one place, read by the
arrow keys and the click conversion alike, so the two cannot disagree about what
the last row is.

The picker's count is the FILTERED list (`picker-sessions`), the config pane's is
every row (`config-rows`), the todos pane's is the repo's rows, the subagents' is
the folded tree — each the same list the pane draws from."
  (case mode
    (:subagents (length (subagent-rows head)))
    (:jobs (length (head-jobs head)))
    (:todos (length (repo-todo-rows-cached
                     (getf (session-wiring (head-session head)) :workspace))))
    (:picker (length (picker-sessions (head-session head))))
    (:config (length (config-rows head)))
    ;; the peek pane's rows are its BODY lines, and answering 0 was the whole of
    ;; its arrow keys: `move-cursor` clamped to `(1- 0)` while the pane's own
    ;; last line advertised that they scroll
    (:peek (peek-row-count head))
    ;; the job-output overlay is the same: a window of bytes, no selectable rows
    (:job-out (job-out-row-count head))
    (t 0)))

(defun %todos-move (head n)
  "Up (N = -1) or Down (N = 1) on the todos pane: the cursor walks the repo's
ITEMS, wrapping at either end, and folds whatever was open — the reference's
`Key::Up`/`Key::Down` under `todos_pane` (app.rs:3275).

`at` is the first stop at or past the cursor, so a cursor resting on a heading
(row 0 at open) counts from the item below it: Down from the top goes to the
SECOND item, which is what letibot's screen shows after two Downs — T3, not T2 —
and this pane must agree with it."
  (let* ((rows (repo-todo-rows-cached
                (getf (session-wiring (head-session head)) :workspace)))
         (stops (repo-todo-stops rows)))
    (when stops
      (let* ((at (or (position-if (lambda (i) (>= i (head-picker-sel head))) stops) 0))
             (next (mod (+ at n) (length stops))))
        (setf (head-picker-sel head) (nth next stops)
              *repo-todo-open* nil
              (head-dirty head) t)))))
