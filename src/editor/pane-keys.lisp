;;;; pane-keys — the pane key map and what Enter does in a pane
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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
               (%switch-to head it))))))

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

;;; ------------------------------------------- what Enter does, per pane ;;;
;;;
;;; The nine arms of the old `%pane-enter` `case`, one method each — the arms' own text,
;;; scaffolding aside.
;;;
;;; **They live HERE and not in each pane's file under `src/panes/`, and that is a
;;; dependency fact rather than a preference.** Every one of them but `:config` and
;;; `:dash` calls into the editor (`%switch-to`, `%job-out-page`), the head (`%send`) or
;;; the REPL (`lisp-eval-entry`), and `src/panes/` loads before all three: a method in
;;; the pane's own file would be a forward reference per call site, which is the class
;;; of thing the asd's comments say this tree turns into warnings rather than ordering.
;;; The panes' LINES live in their own files; the panes' ENTER lives with the key map
;;; that reaches it, and `pane-protocol.lisp` has the classes and the generic.

(defmethod pane-enter ((pane lisp-pane) head)
  ;; **THE ONE PANE WHOSE ENTER CONSUMES THE LINE, and that is the whole difference between it and
  ;; every arm below.** They leave `composer-buffer` alone because the words are not theirs — the
  ;; operator's sentence is held for when the pane closes (the rule the `:enter` arm states at
  ;; length). Here the line IS the act: it is read, evaluated in this head's own image, and pushed
  ;; to the SCROLLBACK, which is where the words went instead of being held.
  ;;
  ;; An evaluation that does not happen — a blank line — leaves the prompt exactly as it is, the
  ;; rule `%submit-line` keeps for a blank Enter: there is nothing to clear and an entry saying so
  ;; would be a row for nothing happening.
  (let* ((c (head-composer head))
         (typed (composer-buffer c)))
    (when (lisp-eval-entry head (expand-pastes typed))
      ;; **THE FORM GOES INTO THE COMPOSER'S OWN HISTORY**, which is what makes ↑ walk the forms
      ;; you evaluated. One mechanism rather than two: the help row for this pane says *↑ walks
      ;; what you have evaluated* and what actually walks is `composer-history-step`, the same
      ;; function that walks the prompts you have sent — see `%pane-key`, which refuses the arrows
      ;; for this pane so they arrive here.
      (composer-push-history c typed)
      (%undo-push c)
      (setf (composer-buffer c) ""
            (composer-cursor c) 0
            *paste-ledger* nil
            *history-recalled* nil
            *redo-stack* nil
            (get 'composer :draft) nil)))
  t)

(defmethod pane-enter ((pane config-pane) head)
  ;; ENTER CHANGES IT. The pane lists the head's own choices and it
  ;; can change them in place — which is what was asked for: a pane
  ;; with runtime-editable configurations, not a list to read. The
  ;; cursor walks EVERY row now, as the reference's does, and
  ;; `config-change` says what each kind of row does on Enter.
  (config-change head))

(defmethod pane-enter ((pane subagents-pane) head)
  ;; **ENTER READS; `o` ATTACHES.** The two heads agree on this, and the argument is letibot's:
  ;; *attaching on Enter silently redirects the next prompt to the child, which is exactly the hazard
  ;; the read exists to avoid* — an operator who pressed the key to LOOK must not find their next
  ;; message in somebody else's session.
  ;;
  ;; **And reading is no longer a lesser view**, which is what changed today: the peek asks for
  ;; `PeekShape::Rows`, so it draws the child with the renderer every other session uses, and
  ;; `tick-peek` re-reads it once a second — a live tail, looking exactly like a conversation, which
  ;; is the operator's own ask (*"i want it to tail as a normal conversation while i look at it"*).
  ;; It cost one field on the frame, and it buys the key that cannot misfire a prompt.
  ;;
  ;; A child still `opening` has nothing to read and the daemon would refuse the peek by name, so
  ;; the refusal is said here rather than bounced through the daemon (app.rs:3678-3689).
  (let ((row (nth (head-picker-sel head) (subagent-rows head))))
    (cond ((null row) nil)
          ((equal (getf row :state) "opening")
           (say head "that subagent is still opening — nothing to read yet"))
          (t (awhen (getf row :session-id)
                    ;; **ENTER IS THE CONVERSATION**, so it clears the narrow view (`p`) on its way in:
                    ;; a flag that outlived the key that set it would draw a prompt for a reader who
                    ;; asked for the answer.
                    (setf *peek-prompt-only* nil)
                    (%send head (make-peek it))
                    (say head (format nil "reading ~a…" it)))))))

(defmethod pane-enter ((pane peek-pane) head)
  ;; The pane's hint bar says *"enter re-reads"* and it did not: `:peek` was
  ;; not in this case at all. A running subagent has new output, which is the
  ;; whole reason to press it again (app.rs:3272-3277).
  (awhen *peeked-session*
	 (%send head (make-peek it))
	 (say head (format nil "re-reading ~a…" it))))

(defmethod pane-enter ((pane jobs-pane) head)
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

(defmethod pane-enter ((pane job-out-pane) head)
  ;; Enter takes the next page, or re-reads the last one when the end is
  ;; already here — a running job appends, and that is how you see what it
  ;; has written since (app.rs:3272-3277, the same key on the peek pane).
  (%job-out-page head t))

(defmethod pane-enter ((pane dash-pane) head)
  ;; Enter opens or closes the panel under the cursor, through the same nav every other key
  ;; goes through — so the key and the drawing cannot disagree about which panel is selected.
  (setf *dash-nav* (dash-nav *dash-nav* "\r") (head-dirty head) t)
  t)

(defmethod pane-enter ((pane todos-pane) head)
  ;; **Enter acts on WHAT THE CURSOR IS ON**, asked of the one enumeration rather than
  ;; re-derived (R44): the add control opens the card — the operator's *"add todo item … a
  ;; modal dialog"* — and a repo row unfolds, which is what they asked for directly (*"if a
  ;; todo has some associated text? should i be able to expand it somehow?"*). The operator's
  ;; own rows have nothing for Enter to do yet; the model's are not stops at all.
  ;;
  ;; `todo-stop-at` is the single answer to *which row is the cursor on*, with the clamp the
  ;; pane makes when it draws — so a key pressed against a list that just changed acts on a real
  ;; row rather than on an index that no longer exists.
  (let ((stop (todo-stop-at head)))
    (case (car stop)
      (:add (%todo-draft-open head))
      (:repo (setf *repo-todo-open* (not *repo-todo-open*)))
      (t nil))))

(defmethod pane-enter ((pane picker-pane) head)
  (let ((hit (nth (head-picker-sel head)
                  (picker-sessions (head-session head)))))
    (when hit
      (%switch-to head (getf hit :session-id)))))

(defun %pane-enter (head)
  "Enter on a full-body screen: the PANE's own act, and the repaint it always cost.

**Two lines, and one of them is shared.** The `case` that used to be here had exactly
one thing every arm had in common — `(setf (head-dirty head) t)` — because where a
pane's Enter lands the frame is not the pane's business. Each pane's Enter is its own
act and is a `pane-enter` method; this is the door the key map calls, and it keeps the
shared tail, so a pane that grows a method does not have to remember to repaint."
  (pane-enter (current-pane head) head)
  (setf (head-dirty head) t))



(defun shut-overlays ()
  "Close every overlay that is a SPECIAL rather than a mode flag.

**A special is not a mode flag**, and the rule they share is the one that is easy to
forget: *leaving the mode does not leave the thing.* A window left holding bytes goes on
taking what arrives into a pane nobody can see, and a listing left holding a reply is
shown again by the next `/tools` for one frame before that reply replaces it
(app.rs:3277-3281).

Named once because there are two of them now and a third is coming, and because the
alternative is what this file already had: `(when (eq mode :job-out) (close-job-out))`
written out in two arms, which is exactly how the next one gets forgotten. **It does not
touch the MODE** — where Esc goes is `pane-escape-target`'s decision and each caller
makes it, and the two keys that call this want different places."
  (close-slash-out)
  (close-job-out)
  t)

(defun %pane-key (head key type)
  "A full-body screen's own keys. T when the pane claimed the key — and
**anything else is the COMPOSER's**.

That last clause is the whole change. This arm used to claim every key for the
nine modes and read only `q` out of a printable one, so no character reached the
composer while any pane was open — including the session picker, whose own hint
bar says *\"type a number to switch · /new [title]\"* and meant neither
(chrome.lisp:363). A pane open was a head you could not talk to: Esc out, type,
and lose the list. The reference lets a pane's text fall through and gates only its letters on an empty
line (app.rs:3370-3394, 3508-3548); **Enter was in that list once and is not any
more** — letibot made it the pane's unconditionally at `ee33732`, and the arm below
is that rule.

`esc`/`q` closes any of them; the LIST panes also take a cursor (up/down) and an
enter, and they share ONE cursor — `head-picker-sel` — because only one pane is
open at a time, which is the same argument the pane scroll offset makes. A
per-pane cursor would be a `head` slot each, and a struct slot is a RESTART: the
one thing this head must not need."
  (let ((mode (head-mode head))
        (empty (zerop (length (composer-buffer (head-composer head))))))
    ;; **THE REPL KEEPS THE COMPOSER'S ARROWS, AND THIS IS THE ONE PLACE IT SAYS SO.** Every other
    ;; pane's ↑↓ move ITS cursor or scroll ITS window; the `/lisp` pane's walk the FORMS you have
    ;; evaluated, which is the composer's own history — one history, one mechanism, and no second
    ;; answer to *what did ↑ mean here*. NIL is the picker's own shape of *not mine* (the arm below),
    ;; and it is what hands the key back to `%normal-key` and the composer.
    (when (and (eq mode :lisp) (member type '(:up :down)))
      (return-from %pane-key nil))
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
             (shut-overlays)
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
               ;; the TAIL-ORIGIN panes are `:peek` and `:job-out`; every other
               ;; pane counts from the top
               (pane-scroll-by (if (member mode '(:job-out :peek)) (- n) n))
               (setf (head-dirty head) t)
               t))
        ;; **THE DASHBOARD IS DISPATCHED AHEAD OF THE SHARED CASE**, and that is a correctness
        ;; fix rather than tidiness: written as a clause INSIDE the case, the arm matched `:esc`
        ;; and `:up` for EVERY pane (a case takes its first matching clause), so the jobs and
        ;; peek panes stopped closing and stopped scrolling — **64 tests**, all of them about
        ;; panes that have nothing to do with a dashboard. A pane whose keys belong to one
        ;; function gets one entry point, and the others are untouched.
        ;;
        ;; Its keys are the ones it ACTS on and no more: a printable key it does not handle
        ;; falls through to `:char` below and reaches the composer, which is this file's own
        ;; rule (a pane that claimed every key was a head you could not talk to).
        (if (and (eq mode :dash)
                 (member type '(:esc :up :down :enter :page-up :page-down)))
            (let ((next (dash-nav *dash-nav*
                                  (case type
                                    (:esc "esc") (:up "k") (:down "j")
                                    (:enter "\r") (:page-up "K") (:page-down "J")))))
              (if next
                  (progn (setf *dash-nav* next (head-dirty head) t) t)
                  ;; NIL means NOT MINE AT DEPTH ZERO — the nav's own contract — so the pane
                  ;; leaves. That is also the only way out that is a way in.
                  (shut)))
        (case type
          ((:esc :q-press) (shut))
          ;; **The todos pane opens where it always did** (R44) — on the repo's first row, which is
          ;; a heading, so no mark shows. The ADD ROW is a stop of its own at `-1`, drawn first and
          ;; reached with one Up (or `/todos add`, which is the keystroke-saving spelling). Opening
          ;; ON it would have changed what Enter does the moment the pane appears, and Enter here
          ;; means *unfold this item* to everyone who has used it.
          ;;
          ;; The todos pane's cursor stops only on the repo's ITEMS and wraps
          ;; at either end — the reference's `stops` (app.rs:3268). Measured:
          ;; from the top, two Downs land on T3 (T1's stop is where a cursor on
          ;; the heading above it counts from), and Enter there unfolds T3.
          ;; Moving folds whatever was open.
          ((:up :down)
           (let ((n (if (eq type :up) -1 1)))
             (case mode
               (:todos (%todos-move head n))
               ;; the peek view has no rows to walk — `pane-row-count` counted
               ;; 0 for it — so its arrows SCROLL, which is what its hint bar
               ;; promises and what `move-cursor` could never do (app.rs:3260).
               ;;
               ;; **Through `scroll`, because this pane is tail-origin too.**
               ;; `peek-lines` windows `end = total - scroll` for the same reason
               ;; the job-output overlay does — a subagent's ANSWER is at the end
               ;; — so `*pane-scroll*` counts lines hidden below the bottom and
               ;; `↑` must ADD to it. Called with the top-origin sign, `↑` walked
               ;; toward the END while the hint bar said otherwise.
               (:peek (scroll n))
               ;; the job-output overlay is the same shape: a window of bytes
               ;; with no rows to select, so its arrows scroll the loaded window
               ;; rather than walking a cursor (app.rs:3256-3268)
               (:job-out (scroll n))
               ;; **and the slash listing**, which is a document read from the
               ;; top: `pane-row-count` answers 0 for it, so without this arm its
               ;; footer would name `up/down scrolls` and move nothing — the
               ;; defect `peek-row-count`'s own docstring records, one pane over
               (:slash (scroll n))
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
          ((:wheel-down) (scroll (* (%wheel-notches key) *scroll-notch*)))
          ((:wheel-up) (scroll (- (* (%wheel-notches key) *scroll-notch*))))
          ;; Tab unfolds a todo, beside enter — and it KEEPS the `empty` gate that
          ;; enter has just given up, DELIBERATELY: with a word in the composer Tab is the
          ;; composer's, because the hint bar promises *"tab completes /commands"*,
          ;; where Enter is the pane's whatever the line holds. On every OTHER pane it
          ;; is not the pane's key at all: it used to set `head-dirty` to NIL
          ;; there — against its own comment — which suppressed the next repaint.
          ((:tab) (when (and (eq mode :todos) empty) (%pane-enter head))
                  (and (eq mode :todos) empty))
          ;; **`delete` drops one of the operator's own items** (R44). Their ask: *"i want to be
          ;; able to remove non-started todos"* — and *non-started* is the whole of the guard,
          ;; because an item something is working on is not a note any more. Delete rather than a
          ;; letter: in a pane a letter is the COMPOSER's (the rule every pane here keeps), and a
          ;; key that both types and deletes is a key that loses somebody's sentence.
          ;; **the pane OWNS the key whenever it is up**, like Tab and Enter beside it — a NIL
          ;; here falls through to `%normal-key`, which sends `delete` to the COMPOSER. Nothing is
          ;; typed into a composer with the pane up in practice, so the fall-through would have been
          ;; invisible; it is still two owners for one key, and `%todo-remove` is what decides
          ;; whether there is anything to remove (and says so when there is not).
          ((:delete) (when (eq mode :todos) (%todo-remove head))
                     (eq mode :todos))
          ((:enter)
           ;; **ENTER IS THE PANE'S UNCONDITIONALLY, AND THIS `empty` GATE WAS THE BUG.** It read
           ;; `(when empty (%pane-enter head)) empty`: with one character in the composer the arm
           ;; returned NIL, the key fell through the ladder, and the half-written line was
           ;; SUBMITTED — so a pane's own advertised key became `submit` for anyone who had typed a
           ;; word. The operator hit it on the reference head (*"i went to jobs pane and hit
           ;; enter"*, and what reached the model was a stray backslash), and their ruling is the
           ;; whole of the rule: *"the pane own keyboard in a way, so enter is a pane thing."*
           ;; letibot fixed it at `ee33732`; this head does the same.
           ;;
           ;; **AND THE WORDS ARE HELD, NEVER EATEN.** Claiming the key is not enough on its own:
           ;; a pane that consumed the composer's line to keep the key would trade one silent loss
           ;; for another, so `%pane-enter`'s arms leave `composer-buffer` alone — and the test
           ;; beside this asserts that rather than assuming it.
           ;;
           ;; **THE ONE EXCLUSION IS THE SESSION PICKER, AND IT IS LETIBOT'S OWN LIST** (`ee33732`):
           ;; *"the pickers, the mode picker, the decision ladder and the todos stops are excluded on
           ;; purpose: for those a typed line IS the answer — a row number, an id prefix, a name — and
           ;; `submit` routes it and holds the words. The rule is the pane owns the key, not the
           ;; composer is dead."* `nil` here is what hands the key back to the composer's routing,
           ;; and it is the ONLY arm that does.
           ;;
           ;; Three of those four exclusions are already outside this function: the mode picker and
           ;; the ladder are asked in `%handle-key` before any pane is. The todos stops are NOT
           ;; excluded, and the difference is measured rather than copied: this head's todos pane has
           ;; no typed-line meaning — its Enter acts on the cursor, the add row or a fold — so
           ;; excluding it would send the line to the MODEL, which is the defect this arm exists to
           ;; stop. Two of the picker's checks (`/new notes` under the pane, and a row number) are
           ;; what says whether that reading is right, and they are in `tests.lisp`.
           (cond ((and (eq mode :picker) (not empty)) nil)
                 (t (%pane-enter head) t)))
          ;; **SPACE MARKS A TODO, AND IT OWNS THE KEY WHILE THE PANE IS UP** — the same rule delete
          ;; and enter keep beside it. The operator asked for the key by naming the convention (*"space
          ;; for marking todo?"*), and it is free in this pane: a space was previously a `:char` that
          ;; fell through and typed a SPACE into the composer while the todos pane was covering the
          ;; screen, which is a key doing something invisible to a buffer nobody can see.
          ;;
          ;; `:char` and not a named type: a space arrives as a character, so this is the only arm
          ;; that can see it. It claims the key on EVERY stop — `%todo-toggle` is what decides whether
          ;; there is anything to mark, and it says so when there is not, because a key that appears
          ;; to do nothing is the defect this pane has been fixed for twice.
          ((:char)
           (let ((ch (getf key :ch)))
             (cond ((and (eq mode :todos) empty (eql ch #\space)) (%todo-toggle head) t)
                   ;; **`i` COMPOSES AN INSTRUCTION FROM A TODO.md SUBTREE.** A letter and not a
                   ;; named key because it is a composer action, and it is free in this pane: the
                   ;; letters taken here are `q` (quit), `o` and `d` (subagents, jobs) and the dash's
                   ;; `jkJKgG`. Gated on `empty` like the others, so a half-typed prompt is not
                   ;; replaced by a key pressed to scroll.
                   ((and (eq mode :todos) empty (eql ch #\i)) (%todo-implement head) t)
                   ;; **`h` HIDES THE DONE ONES** — the operator's ask (*"in todo panel i want a mode
                   ;; where done items hidden"*). Free in this pane and gated on `empty` like `i`
                   ;; beside it, so a half-typed prompt is not disturbed by a key pressed to read
                   ;; the list. `h` for hide, and the state is drawn in the pane and confirmed in the
                   ;; notice, because a mode whose whole effect is ABSENT ROWS has nothing else to
                   ;; say it is on.
                   ((and (eq mode :todos) empty (eql ch #\h)) (%todo-toggle-hide-done head) t)
                   ((not empty) nil)
                   ((eql ch #\q) (shut))
                   ((and (eql ch #\o) (eq mode :subagents)) (%subagent-switch head) t)
                   ;; **`p` IS THE PROMPT, ALONE, IN A POPUP THAT SCROLLS.** The operator: *"when i select
                   ;; an agent and press 'p' it should show me prompt in a scrollable popup."* The pane's
                   ;; first line is an EXCERPT — the daemon's `Subagent.prompt` is the task's first line
                   ;; and nothing more — so the whole task needs a view of its own, and the child's own
                   ;; transcript is where it lives. The same peek Enter sends; the flag is what makes it
                   ;; narrow (see `%peek-prompt-pane`).
                   ((and (eql ch #\p) (eq mode :subagents))
                    (let ((row (nth (head-picker-sel head) (subagent-rows head))))
                      (cond ((null row) nil)
                            ((equal (getf row :state) "opening")
                             (say head "that subagent is still opening — nothing to read yet") t)
                            (t (let ((id (getf row :session-id)))
                                 (when id
                                   (setf *peek-prompt-only* t)
                                   (%send head (make-peek id))
                                   (say head (format nil "reading ~a's prompt…" id))))))))
                   ;; the operator's own ask: the job row links to its dashboard
                   ((and (eql ch #\d) (eq mode :jobs))
                    (let ((job (nth (head-picker-sel head) (head-jobs head))))
                      (when (dash-panel-for-job job)
                        (setf *dash-nav* (list :sel 0 :scroll 0 :open nil))
                        (pane :dash "dash")
                        t)))
                   ;; the dashboard's own letters, and no others — `g`/`G` jump to the first
                   ;; and last panel, which is the one navigation a `j`-only list cannot give.
                   ;; **`d` ON THE JOBS PANE OPENS THE JOB'S DASHBOARD.** Gated on there BEING
                   ;; one, so the key reports rather than doing nothing — a key that silently
                   ;; ignores a press is the defect `%pane-key`'s docstring records, and here
                   ;; the row itself already says `· dash` so the gate and the mark agree.
                   ((and (eq mode :jobs) (eql ch #\d))
                    (let ((job (nth (head-picker-sel head) (head-jobs head))))
                      (if (dash-panel-for-job job)
                          (progn (setf *dash-nav* (list :sel 0 :scroll 0 :open nil))
                                 (pane :dash "dash")
                                 t)
                          (progn (say head "no dashboard is registered for that job")
                                 t))))
                   ((and (eq mode :dash) (member ch '(#\j #\k #\J #\K #\g #\G) :test #'eql))
                    (setf *dash-nav* (dash-nav *dash-nav* (string ch))
                          (head-dirty head) t)
                    t)
                   (t nil))))
          (t nil)))))))

