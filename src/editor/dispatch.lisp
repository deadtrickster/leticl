;;;; dispatch — the key dispatcher: which of the above gets a key, in what order
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun %handle-key (head key)
  "Who a key belongs to, in the reference's precedence order (`App::key`).

The ladder is one `cond` and the reference's is one `match`, which is what makes
the ORDER reviewable: the cards that own the keyboard, then the head's own
chords, then a click, then the overlays that keep their arrows under an ask, then
AN OPEN ASK, then every other list, then the composer. The ask's own place in that
line is the one that moved — see `%decision-key` — and the reference's is the
same order (app.rs:3384/3417/3481, then :3609 for the ask, then :3643 onward
for the lists)."
  (let ((type (%key-type key)))
    (cond
      ((eq type :eof) (setf (head-running head) nil))
      ;; the secret card owns everything while it is up: a password field is
      ;; not a composer and must never leak into one
      ((head-secret-req head) (%secret-key head key type))
      ;; **THE PROMPT CARD ALSO OWNS ENTER** — when the operator's run is asking, Enter
      ;; sends the composer's content as `PromptAnswer` (protocol 33). Unlike the secret
      ;; card, the prompt does NOT own every key: the field is the composer itself, drawn
      ;; in the open, so typing, editing, and every other chord still work. Only Enter is
      ;; claimed, because that is the act of answering.
      ;; **ESC PUTS THE CARD AWAY — and that is not answering it.** The request stays
      ;; open and the run keeps waiting (the reference's `prompt_away`, `b0ff4f8`): the
      ;; operator may want the transcript back while deciding, and the card is a window
      ;; onto a request, not the request. While the request is open — card up or away —
      ;; a bare line is HELD (see `%submit-line`), which is the window the operator's
      ;; `y` fell through on the reference: card away, bare line submitted, the words
      ;; reached the model while their own command waited and died at its deadline.
      ((and (head-prompt-req head) (not *prompt-away*) (eq type :esc))
       (setf *prompt-away* t
             (head-dirty head) t)
       (say head "the card is away — the request is still open, and a bare line is held until the run ends")
       t)
      ((and (head-prompt-req head) (eq type :enter))
       (let* ((req (head-prompt-req head))
              (line (composer-buffer (head-composer head))))
         (setf (head-prompt-req head) nil)
         (%send head (make-prompt-answer (getf req :req-id) line))
         (setf (composer-buffer (head-composer head)) ""
               (composer-cursor (head-composer head)) 0)
         (say head (format nil "sent: ~s" line))
         (setf (head-dirty head) t)
         t))
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
                        '(:help :status :config :jobs :subagents :peek :job-out :todos :picker
                          :slash :lisp))))
       (if *pick-open*
           (close-pick head)
           (progn
             ;; **A SPECIAL IS NOT A MODE FLAG**, so leaving the mode is not leaving
             ;; the thing: an overlay left holding bytes would go on taking what
             ;; arrives into a pane nobody can see, and a listing left holding a
             ;; reply would be shown again by the next `/tools` for one frame before
             ;; that reply replaced it (app.rs:3277-3281). Both are closed HERE, in
             ;; the one arm that closes panes, rather than in each key that can
             ;; leave one.
             (shut-overlays)
             (setf (head-mode head) :normal (head-dirty head) t)))
       t)
      ((and (eq type :mouse) (eq (getf key :kind) :press) (%click head key)))
      ;; **The three overlays keep the arrows even under an ask.** Each is opened
      ;; deliberately, and a permission arriving while one is up must not take the
      ;; arrows out from under the row being read — the reference keeps the
      ;; subagent-output view, the job-output view and the config pane ahead of the
      ;; decision ladder (app.rs:3384, 3417 and 3481, all before :3609).
      ((and (member (head-mode head) '(:peek :job-out :config))
            (%pane-key head key type)))
      ;; **A payload window is asked before the ASK.** It is a view the reader opened
      ;; with `ctrl-t`; a permission card is the one card nobody asked for, and the
      ;; reference settles this the same way (app.rs:3855-3862, ahead of the ladder).
      ;; Everything the reader opened ON TOP of it — a pane, a card — is asked
      ;; earlier and wins, which is where this head differs on purpose.
      ((%payload-key head key type))
      ;; **An open ask is asked before every LIST on the screen.** The reference's
      ;; order puts the ladder at app.rs:3609 — ahead of the session picker (:3643),
      ;; the mode and models pickers (:3736) and the subagent, todos and jobs panes
      ;; (:3795, :3852, :3917) — and this head used to put them all first, so a
      ;; permission arriving over an open session picker left Up and Down moving
      ;; the PICKER and the ladder out of reach until the picker was closed. That
      ;; is T5, and `%decision-key`'s own `when` is what keeps every key it does
      ;; not own falling through to the lists below.
      ((%decision-key head key type))
      ;; **THE OPERATOR-CALL COMPOSER** (R24 part two), after an open ask and before every
      ;; list. After the ask because a card nobody asked for outranks a card the operator
      ;; opened; before the lists because the field it fills IS the composer, so anything it
      ;; does not take must land there — Enter and Esc are all it owns.
      ((and *op-call-draft* (%op-call-draft-key head key type)))
      ;; **THE NEW-TODO CARD**, beside the operator-call composer and for the same reason: the
      ;; field it fills IS the composer, so anything it does not take must land there. It owns
      ;; enter, tab, esc and ctrl-c; everything else is typing.
      ;; **THE API-KEY CARD**, beside the todo card and for the same reason: the field it
      ;; fills IS the composer, so anything it does not take must land there. It is ABOVE
      ;; every other arm that could type, because the text being entered is a credential.
      ((and *key-draft* (%key-draft-key head key type)))
      ((and *todo-draft* (%todo-draft-key head key type)))
      ;; a picker's own keys; what it does not take is the composer's, so a name
      ;; can be typed under the card
      ((and *pick-open* (pick-key-event head key)))
      ((and (member (head-mode head)
                    '(:help :status :jobs :subagents :todos :picker :slash :dash :lisp))
            (%pane-key head key type)))
      (t (%normal-key head key)))))

(defun %withdraw-queued (head)
  "Take the queued prompts back into the composer (v19) — **the WHOLE queue, not the last one.**

On `↑` with an empty composer at the tail, which is where the reference puts it (app.rs:3851-3861).

**Three things were wrong with ours and letibot's is the specification for all three** — the
operator, after taking a message back to fix a typo: *\"taking a message back is broken\"*, and
*\"the fixed 'lol, it is a bug' stays queued\"*.

  · **THE WHOLE QUEUE COMES BACK, JOINED BY A NEWLINE.** Ours took only the newest entry and put
    it in the composer, while the daemon's take-back drops **every** queued prompt from that head
    (`hub.rs:1298`) plus the held operator text (`steering.rs:210`). So a second queued
    message stayed drawn on the screen with nothing behind it — a PHANTOM, which is exactly what
    the operator was looking at. letibot joins them oldest-first (`pending_prompts.join`),
    and this head's queue is newest-first, so the join reverses.
  · **THE COMPOSER IS REPLACED, NOT INSERTED INTO.** letibot's `set_composer` is Home, KillToEnd,
    insert — the whole line. Ours called `composer-insert`, which appends at the cursor, so taking
    a message back into a composer that already had something put the two together.
  · **AND THE TURN-RUNNING GUARD is what makes the take-back legal at all**: the daemon honours a
    withdraw only at its steering poll (a take-back reaching the worker is `Outcome::Ignored` —
    *\"whatever prompts it named have already run as their own turns\"*). So the frame is only
    worth sending while a turn is running, which is the condition this is called under."
  (let ((texts (reverse (head-queued head))))
    ;; the frame first: the daemon drops its own copy, and only then does the screen forget
    (%send head (make-withdraw-prompts (session-expected-seq (head-session head))))
    (setf (head-queued head) nil
          *bound-prompts* nil)
    ;; **REPLACE the line**, as letibot's `set_composer` does — Home, kill to end, insert. A
    ;; composer with something half-typed in it is not thrown away silently; it is replaced by
    ;; what the operator just asked to have back.
    (%undo-push (head-composer head))
    (setf (composer-buffer (head-composer head)) (format nil "~{~a~^~%~}" texts)
          (composer-cursor (head-composer head)) (length (composer-buffer (head-composer head))))
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

(defun %scroll-view (head delta)
  "Move the reader's view DELTA lines (positive is further back), and DROP THE ANCHOR.

**The anchor has to go, and that was a real defect — *scrolling is broken*, measured.** R36's anchor
is re-found every frame by row identity, and `%viewport-lines` keeps `head-scroll` in step with it
(`(setf (head-scroll head) (- n end))`). So while an anchor is set, the anchor decides the window:
a `page-down` that decremented `head-scroll` was overwritten by the anchor's own arithmetic before the
frame was drawn, and the view did not move at all. Measured on a 40-row transcript: six `page-down`s
from the top left the scroll at 66 and the same row at the top.

**Why dropping is the honest fix rather than a workaround.** The anchor's job is to survive *arrivals*
— content appearing below, which is not the reader moving. A scroll key IS the reader moving: they are
choosing a new place, so the row they were on has no claim on the frame. `%anchor-observe`
re-establishes the anchor from the row the NEXT frame actually draws, which is the same rule the rest
of R36 keeps — the anchor is a record of the top row of the last frame, never of a keypress."
  (setf *scroll-anchor* nil
        (head-scroll head) (max 0 (+ (head-scroll head) delta))
        (head-dirty head) t))

(defun %follow-tail (head)
  "Return to the TAIL — scroll to 0, drop the anchor, follow again.

 **NOT the wheel-down arm anymore** (daemon 8adc2c6 reversed the 1e4461b ruling).
 The cure for the October report — a reader who could not reach the bottom — made a single
 notch a JUMP, so
 the reader cannot walk down through a conversation at all. The reconciliation:
 wheel-down walks like wheel-up (`hold(+3)`), and following resumes when the walk
 actually arrives at the tail — so a run of notches still returns the reader to
 the bottom, which answers the original need without the one-notch jump. This
 function stays for the ↓ at the bottom and Esc, which ARE the jump-to-tail acts."
  (setf *scroll-anchor* nil
        (head-scroll head) 0
        (head-dirty head) t))

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
         ;; **AN EMPTY COMPOSER AT THE TAIL WITH SOMETHING QUEUED: TAKE IT ALL BACK.**
         ;;
         ;; **AND ONLY WHILE A TURN IS RUNNING**, which is letibot's own condition and the reason
         ;; the gesture works at all: the daemon honours a take-back at its steering poll, and a
         ;; withdraw that reaches the worker instead is `Outcome::Ignored` — *"whatever prompts it
         ;; named have already run as their own turns"* (`sessions.rs:1600`). With no turn running
         ;; there is nothing to steer, so the frame would be a no-op and the screen would forget a
         ;; message the daemon had already accepted. The queue exists BECAUSE a turn is running;
         ;; this is the same fact read from the other side.
         ((and (zerop (length (composer-buffer c)))
               (zerop (head-scroll head))
               (head-queued head)
               (turn-running-p head))
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
         ;; **R36: the explicit act that returns the reader to the live end, and the anchor goes
         ;; with the number.** Following the bottom is a STATE, so the two are cleared together —
         ;; a scroll of 0 with an anchor still set would put the reader back where they were on
         ;; the next frame, which reads as a key that does not work.
         (setf (head-scroll head) 0 *scroll-anchor* nil (head-dirty head) t)
         (return-from %normal-key nil))
       (let ((now (get-internal-real-time))
             (ms (/ internal-time-units-per-second 1000.0)))
         (if (and *esc-at* (< (- now *esc-at*) (* *esc-double-ms* ms)))
             (progn (setf *esc-at* nil)
                    ;; **BUSY, not "running".** The turn's state name reads "finished" for
                    ;; the whole of a tool call — measured on the live head, a `sleep 60`
                    ;; executing under `state=finished` — so gated on the name, esc esc did
                    ;; NOTHING while a command ran: the one key that stops a runaway command
                    ;; was dead exactly when it is needed, under a hint bar saying it works.
                    ;; `turn-busy-p` is generating OR a call unfinished, which is the fact.
                    (when (and (session-turn (head-session head))
                               (turn-busy-p (session-turn (head-session head))))
                      (%interrupt head "interrupted with esc esc")))
             (setf *esc-at* now))))
      ;; **SCROLLING PAST THE TOP ASKS FOR THE ROW ABOVE THE WINDOW.** This is the
      ;; "on demand" half of `FetchRow`: the moment the reader has reached the oldest
      ;; line this head holds is the moment those rows are wanted, and every other
      ;; moment they are not. `*scroll-max*` is what the renderer last clamped the
      ;; scroll to — the only thing in the tree that knows the transcript's line count —
      ;; so the test is `(>= scroll max)` BEFORE the increment, i.e. *the reader was
      ;; already at the top and has asked to go further*.
      ;;
      ;; `fetch-row-above` refuses what it cannot do (nothing above, one already in
      ;; flight, or the daemon having said they are gone) and says so through the
      ;; seam, so an extra call here costs nothing.
      ((:page-up) (when (>= (head-scroll head) *scroll-max*)
                    (fetch-row-above head))
                  (%scroll-view head (max 1 (- (head-rows head) 3))))
      ((:page-down) (%scroll-view head (- (max 1 (- (head-rows head) 3)))))
      ((:wheel-up) (when (>= (head-scroll head) *scroll-max*)
                     (fetch-row-above head))
                   (%scroll-view head (* (%wheel-notches key) *scroll-notch*)))
      ((:wheel-down) (%scroll-view head (- (* (%wheel-notches key) *scroll-notch*))))
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
         ((#\e) (composer-move c :end) (setf (head-dirty head) t))
         ;; **the two emacs motions, and the second undo spelling.** The reference
         ;; binds them in its DECODER (`term.rs:562-576, 590-594`: `0x02` → Left,
         ;; `0x06` → Right, `0x1f` → Undo) and this head had no arm for any of the
         ;; three — so the chords did nothing at all, on a head whose tree already
         ;; carries the rest of the emacs set (`ctrl-a`, `ctrl-e`, `ctrl-k`,
         ;; `ctrl-u`, `ctrl-w`, `ctrl-y`, `ctrl-z`).
         ;;
         ;; `ctrl-_` is `0x1f`, which `read-key` maps to `(code-char 127)` — the
         ;; character SBCL calls `#\Rubout`. It cannot collide with a backspace:
         ;; a literal `0x7f` is matched EARLIER, as `:type :backspace`, so only
         ;; `0x1f` ever arrives as a `:ctrl` holding Rubout.
         ((#\b) (composer-move c :left) (setf (head-dirty head) t))
         ((#\f) (composer-move c :right) (setf (head-dirty head) t))
         ((#\Rubout) (when (composer-undo c) (setf (head-dirty head) t))))
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

