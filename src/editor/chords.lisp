;;;; chords — the global chords: ctrl-c, the secret ask, the quit card, the door
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defun %wheel-notches (key)
  "How many notches this event stands for. **A batch, not one event** — see the loop's
`wheel-notches`: several events drained in one pass are summed and applied as ONE move, so by the
time the key ladders see them the count is in `:notches`. Defaults to 1, which is what a single
event from a test or a terminal without batching carries."
  (or (getf key :notches) 1))

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
  "The quit card: leave, or leave and stop the daemon (v20).

**The two rows are two different promises, and only one of them is instant.**
Row 0 leaves and is done — the daemon keeps the session and keeps running. Row 1
asks the daemon to stop, and *asking is not an outcome*: the head does not leave
here, it enters the wait `begin-stop-request` records and `tick-stop-request` in
the loop decides. The operator's report is why — they chose this twice and the
daemon stayed both times, with the head that asked already gone."
  (flet ((leave (choice)
           (setf (head-quit-open head) nil)
           (if (zerop choice)
               (setf (head-running head) nil)
               ;; the answer that stops the daemon travels over the protocol,
               ;; not around it to a pid (protocol.rs, v20) — and the head stays
               ;; until that daemon is GONE, or until it can say it is not
               (begin-stop-request head))))
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
  (when (or (eq (getf key :type) :ctrl)
            ;; **the operator-call chord.** `alt+r` rather than a control byte, because every
            ;; control byte with a mnemonic is taken (see `%run-command`) — and it is decoded
            ;; here by this head's own reader, so it cannot be confused with `ctrl-r`, which
            ;; IS a control byte and flips the thinking fold. Handling it above the `:ctrl`
            ;; guard is what keeps the two apart: both arrive as `#\r` and differ only in type.
            (and (eq (getf key :type) :alt) (eql (getf key :ch) #\r)))
    (if (eq (getf key :type) :alt)
        (progn (%op-call-draft-open head) t)
    (flet ((pane (mode verb)
             (if (eq (head-mode head) mode)
                 (setf (head-mode head) :normal (head-dirty head) t)
                 (%command head verb))
             t))
      (case (getf key :ch)
        ((#\r) (%flip-fold head :show-reasoning) t)   ; the reasoning fold
        ((#\t) (pane :todos "todos"))                 ; the todos pane (was ctrl-p)
         ;; **THE COMMENTS BELOW ARE THE RECORD OF THE ARM AS IT WAS**, and they are kept because
         ;; they are WHY the per-row window moved off a chord and onto a verb: the seam under a long
         ;; row names a key that acts on THAT row, and a chord that also unfolded the conversation
         ;; made the seam a lie. The window is `%row-window` now and its only door is `/t`.
         ;; **ONE ROW, NOT A SWITCH — R10's ruling on the overload, and R40 converges this head
         ;; onto letibot's split.**
         ;;
         ;; This used to flip the conversation-wide tool fold *and* seed a window on the newest
         ;; long result, so one chord did two things: the wall, and one row's rest. The seam
         ;; under the reader's eyes says `… +N lines · ctrl-t opens it`, which reads PER-ROW, and
         ;; the operator's report is exactly that **what surprised them was that ctrl-t triggered
         ;; the wall AT ALL**. A chord cannot be named by a per-row seam and mean the whole
         ;; conversation, so it keeps the meaning a seam can honestly name; the conversation-wide
         ;; unfold is `/t`, where it already was.
         ;;
         ;; **Why this head agrees rather than arguing** (R40 asks): its own tree had already
         ;; split the two for the echo — R33's seam says `/t opens it` — so `ctrl-t` and `/t` were
         ;; already two names for *unfold* here, and the chord was the one doing both jobs. The
         ;; measurement that decided which of the two the BAR shows: on the operator's own session
         ;; the payload seam names its key **3,211 times** and the reasoning header names `ctrl-r`
         ;; **1,642 times** — a screen talks about the long rows twice as often as about the
         ;; working-out, so the long rows keep the visible place.
         ;;
         ;; The window follows the newest long result for the reason `payload-view-seed` gives
         ;; (that is the row a reader is looking at), and the seam names this chord only on that
         ;; row — every other row names `/t`, because a chord may only be named where it acts.
         ;; **AT `:reading` THE SAME CHORD ACTS ON THE RUN MARKER** (R37 amended). The marker's
         ;; own seam says `ctrl-t opens it`, and at that rung the long rows it would otherwise
         ;; open ARE the run — a hidden tool result draws no per-row seam at all. So the chord
         ;; closes an open run first, else opens the newest run; only when nothing is hidden does
         ;; it fall through to the payload window it has always opened.
         ;; **THE WINDOW BODY IS `%row-window` NOW**, with the order of its clauses and the reason
         ;; for each in its own docstring. The arm above keeps nothing of it.
        ((#\l) (setf (head-full-repaint head) t (head-dirty head) t) t)
        ;; **THE VIEW IS HELD** — the operator's ruling — and the chord is `ctrl-p` for *pause*.
        ;; **NOT `ctrl-f`, which was the operator's first pick and is TAKEN**: the composer's emacs
        ;; motions bind it (*ctrl-f goes right*, and the reference's decoder binds it too —
        ;; `the-emacs-motions-the-reference-decodes-are-bound` says so and failed the moment this was
        ;; `#\f`). `ctrl-p` is free because the todos pane gave it up when that moved to `ctrl-t`, and
        ;; *pause* is the better mnemonic anyway. The reader is the only party who knows a selection
        ;; exists (Shift makes the TERMINAL select and keeps the events from this head), so the reader
        ;; is who holds the screen; see `*frozen*` for the measurement and for why *write nothing* is
        ;; the whole of the contract.
        ((#\p) (%toggle-freeze head))
        ;; `o` on the subagents pane switches INTO the row under the cursor
        ;; (app.rs:3696-3707); anywhere else it promotes the running command,
        ;; which is what this chord has always meant here.
        ((#\o) (if (eq (head-mode head) :subagents)
                   (subagent-switch head)
                   (%command head "promote"))
               t)
        ((#\s) (pane :picker "sessions"))             ; the session list
        ((#\n)
         ;; **R22: retire every note this head holds.** *n* for notes, and the byte is
         ;; the one letibot ruled free from the other side: `0x0e` is unbound in its
         ;; decoder and in this one, `letibot_ui::editor::Key` has no `CtrlN`, and the
         ;; only other free control bytes are `0x16` (`ctrl-v`, the terminal's
         ;; literal-next in several emulators) and the five with no mnemonic.
         ;;
         ;; **It is the `/notes dismiss all` path and not a second one.** The sentence
         ;; the operator reads is the same sentence whichever door they came through,
         ;; and so is the persistence — which is the whole reason this is a `%command`
         ;; and not a call to `retire-all-warnings`. A chord that did its own retiring
         ;; would be a second implementation of a verb, and the fifth site is the one
         ;; that would forget to write the file.
         ;;
         ;; **And it answers when there is nothing to retire** — *nothing to retire*,
         ;; in the routine register, which is the one thing letibot wanted different
         ;; from the first draft and is now agreed in both trees. A chord the hint bar
         ;; names unconditionally has to answer unconditionally: silence after a press
         ;; is indistinguishable from a key that was never received, and the operator
         ;; presses again to find out.
         (%command head "notes dismiss all")
         t)
        ((#\g) (pane :subagents "subagents"))         ; the subagent tree
        ((#\j)
         ;; **THE JOBS PANE, AND THE ONE THING THAT CAN MAKE THIS KEY AMBIGUOUS — SAID ONCE.**
         ;; `keys.lisp` frees LF for `ctrl-j` (the operator's ruling); LF is also what a terminal
         ;; sends for Return on the paths that do not send CR, and those two are the same byte, so
         ;; an Enter that never submitted and a reader checking jobs look identical here. What is
         ;; legible is the state rather than the byte: LF arriving with text in the composer. See
         ;; `*lf-note-said*` for why the head says so exactly once.
         (when (and (not *lf-note-said*)
                    (plusp (length (composer-buffer (head-composer head)))))
           (setf *lf-note-said* t)
           (say head "that was LF — ctrl-j, the jobs pane. if you meant Enter, this terminal is sending LF for Return; Enter is usually CR (0x0d)"))
         (pane :jobs "jobs"))
        ((#\x)
         ;; raw `<function=…>` markup, which is NOT a fold: a fold hides
         ;; something the reader knows is there, while this reveals markup the
         ;; default view is required never to show. Off by default and behind a
         ;; chord, both halves of what was asked for.
         (setf (head-pref head :raw-calls)
               (not (head-pref head :raw-calls)))
         t)
        (t nil))))))

