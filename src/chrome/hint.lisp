;;;; hint — the hint bar: what the key you are about to press would do
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; --------------------------------------------------------------- hint bar ;;;

(defun %armed-p (at window-ms)
  "Is a two-tap gesture still within its window? NIL when it was never started."
  (and at (< (- (get-internal-real-time) at)
             (* window-ms (/ internal-time-units-per-second 1000.0)))))

(defun hint-bar (head cols)
  "The line under the composer that says what the keys do HERE.

The reference's `hint_bar`: ONE constant string per context — a key that closes
a card is not the key that interrupts a turn, and a hint that names the wrong key
is worse than no hint at all."
  (declare (ignore cols))
  ;; **ONE CONSTANT STRING, no prefix.** It used to open with the keys that
  ;; change — `enter send` idle, `esc interrupt` while a turn runs — and those
  ;; are three different lengths in front of the same tail, so the line moved
  ;; sideways whenever a turn started or the first character was typed. The
  ;; reference deleted exactly that and says so at app.rs:5001-5004; this head
  ;; had copied the prefix from an older commit of it, and the 1:1 rig caught
  ;; the row on every frame of all ten fixtures.
  (let* ((armed (cond
                  ;; the ARMED warnings stay: `Editor::hint` still returns these
                  ;; two and nothing else (editor.rs:820-834), because a gesture
                  ;; half-made is the one thing the bottom row must say.
                  ((head-quit-open head) nil)
                  ((%armed-p *esc-at* *esc-double-ms*)
                   (cons "esc again to interrupt" '(:bold t :fg :yellow)))
                  ((%armed-p *ctrlc-at* *ctrlc-window-ms*)
                   (cons "ctrl+c again to exit" '(:bold t :fg :yellow)))
                  (t nil)))
         (tail (cond
                 ((head-quit-open head) "1/2 or ↑↓ then enter · esc stays")
                 ;; **ONE ARM FOR EVERY PANE** — the words are the pane's own now (`pane-hint`),
                  ;; so a pane that names a key it does not have cannot describe itself
                  ;; that way. The bar's own order around them is unchanged: the quit
                  ;; prompt above outranks any hint, and `*pick-open*` below keeps its
                  ;; place after the modes.
                 ;; **A LIST THE PICKER PUT UP IS NOT A MODE, and its PRECEDENCE is kept** —
                 ;; the old `cond` had this arm after `:slash` and `:picker` and before every
                 ;; other pane, so a pick's keys won over the pane you were in — except in the
                 ;; two panes whose own words already describe it. One clause rather than a
                 ;; position, because the panes share one arm now.
                 ((and *pick-open* (not (member (head-mode head) '(:slash :picker))))
                  "a row number switches · ↑↓ then enter · or type a name · esc closes")
                  ((pane-hint (current-pane head) head))
                 ((head-secret-req head) "enter submits · esc refuses the password")
                 ;; **the operator-call composer** (R24 part two). The two keys it owns,
                 ;; said in the register the secret card's own row uses — and this arm is
                 ;; what makes the card's promise checkable from the bottom row.
                 ((op-call-draft-open-p) "the tool's own JSON, then enter asks the daemon to admit it as your act · esc cancels")
                 ((%open-decision head) "a row number answers · ↑↓ then enter · or type an option · /help")
                 ;; **`ctrl-n` IS SECOND, AND THE PLACEMENT IS A MEASUREMENT** (R22).
                 ;; This bar is 136 characters — the same 136 as letibot's, item for
                 ;; item — and at the usual 80 columns everything past column 80 is off
                 ;; the screen. Appending `ctrl-n notes` at the END puts it at 137 and
                 ;; invisible; second, right after `ctrl-s sessions`, it starts at 18.
                 ;; `ctrl-s` keeps first place because opening the session list is what
                 ;; an operator reaches for with no notes in front of them; `ctrl-n` is
                 ;; a reflex, and a reflex nobody can see is a key nobody presses.
                 ;; **R40: WHAT THE CHORD DOES, AND WHERE `/t` GOES.** The bar said
                 ;; `ctrl-t tool output`, which stopped being true when the chord became the
                 ;; window on one row — letibot's own defect, one head over, and R29's rule
                 ;; failing on the bar instead of on a note. Both facts have to fit, so
                 ;; something gives up its space and the measurement says what:
                 ;;
                 ;;   · **`/t row window` goes THIRD, and it is the one new item that had to
                 ;;     fit.** R22's ruling puts `ctrl-n` second and that stands untouched: it
                 ;;     is at column 18, where it was. `/t` — the per-row window's only door,
                 ;;     and the key every folded row's seam now names — takes the third slot at
                 ;;     column 33, inside the first forty columns where a reader looking for a
                 ;;     verb will see it;
                 ;;   · and the two REBINDINGS take their items' slots in place: `ctrl-t` is
                 ;;     the todos pane where `ctrl-p` was (and `ctrl-p` is UNBOUND — a second
                 ;;     spelling of one pane is a key to learn for nothing), and `ctrl-r` says
                 ;;     *reasoning* where it said *thinking*.
                 ;;
                 ;; **`ctrl-j` IS THE JOBS PANE — THE OPERATOR RULED, AND THE DECODER FOLLOWED.**
                 ;; The bar said this was impossible for one round, on `keys.lisp`'s own line mapping
                 ;; BOTH `#\return` and `#\newline` to `:enter`. That line is gone: Enter arrives as
                 ;; CR (0x0D, and `cfmakeraw` clears `ICRNL` so nothing translates it) while Ctrl+J
                 ;; arrives as LF (0x0A), so the two were always different bytes on the wire and
                 ;; collapsing them was a decoder choice rather than a terminal constraint. `h`, `i`
                 ;; and `m` do stay unavailable — those three ARE their control bytes, which is
                 ;; physics — and `j` was only ever in that list because of the deleted line.
                 ;; The risk is in `keys.lisp` rather than here: a terminal path that delivers a bare
                 ;; LF for Return now opens this pane instead of submitting.
                 ;;
                 ;; **The arithmetic, measured rather than asserted**, because R22's own note
                 ;; here is that this bar's placement is a measurement and not a taste:
                 ;;
                 ;;     this bar                147 characters, 9 items
                 ;;     at 80 columns           ctrl-s @0 · ctrl-n @18 · /t @33 · ctrl-t @49 ·
                 ;;                             ctrl-g @64 · and ctrl-r @83 falls off the edge
                 ;;     at the operator's 210   every item on screen
                 ;;
                 ;; So at 210 nothing is lost, at 80 something is — and what falls off is
                 ;; `ctrl-r`, whose key is named on the reasoning header the reader is looking
                 ;; at (1,642 times in the operator's own session) rather than only here. `/t`
                 ;; has no other affordance on a 40-column screen, which is why it takes the
                 ;; slot ahead of it.
                 (t "ctrl-s sessions · ctrl-n notes · /t row window · ctrl-t todos · ctrl-g subagents · ctrl-r reasoning · ctrl-j jobs · tab completes /commands · /help"))))
    (if armed
        (list armed (cons (format nil " · ~a" tail) '(:dim t)))
        (list (cons tail '(:dim t))))))

(defparameter +turn-status-head+ " Responding · "
  "The words between the spinner and the first measured field, in one place.")

;;; **NO SLOTS ON THIS LEGEND, AND THE REASON IS WHERE IT IS ANCHORED.**
;;;
;;; The first cut reserved fixed columns for the duration and the count, because the legend was pinned
;;; to the RIGHT of the composer's bottom edge and the spinner is its LEFTMOST glyph — so every digit
;;; either field gained moved the spinner, and the columns had to be held open to stop it.
;;;
;;; That fixed the jump and made two new things visible, both worse. Absent fields left a hole in the
;;; border (`⠼ Responding ·  724ms` then thirteen blank columns and then `─╯`); filling it with `─`
;;; ran border THROUGH the legend (`⠼ Responding ·  724ms ─────╯`). The operator, on the second:
;;; *"I guss remove those bottom char entirely."*
;;;
;;; Both were symptoms of the ANCHORAGE and not of the fields. **The legend is anchored at the LEFT
;;; corner now** (see `composer-box-bottom`): the spinner sits at a fixed column by construction,
;;; growth runs rightward into the border's own fill, and nothing is held open — there is no hole to
;;; fill and no character to invent.
;;;
;;; This is still *nothing must jump*, which is the axiom. What changed is that the LAYOUT pays for
;;; it rather than the reader. The top edge's subagent legend stays right-pinned, as the reference has
;;; it; a legend whose first glyph is a moving spinner is the one that cannot be.

(defparameter +slow-after-ms+ 15000
  "How long a GENERATING turn may be silent before the Responding row turns yellow
(rano's `SLOW_AFTER_MS`, one number so the two heads agree on what *slow* is).

Fifteen seconds and not forty: the old sentence this replaces said 40s because a FAILED
turn used to look exactly like a slow one, and failed turns end with `TurnFailed` now, so
silence here is only ever slowness — and the operator's ask was *'when we detect delays -
yellow it'*, a delay being something a person notices inside half a minute.")

(defun turn-slow-p (head)
  "Is the turn GENERATING and silent past `+slow-after-ms+`?

**`generating` and deliberately NOT `turn-busy-p`** — the reference's own ruling: a
`cargo test` that runs silently for two minutes is a call, not a slow model, and gated on
busy the row would go yellow through every long command — the false alarm that trains a
reader to ignore it. The colour is the WHOLE of the signal: no sentence, no notification
(*'I dont want notification that it is slow yet we continue'*).

NIL when no turn is on, when the turn is between tokens arriving on a call, before any
event has arrived at all, or on a replay whose clock is pinned."
  (let ((turn (session-turn (head-session head))))
    (and turn
         (string= (turn-state-name turn) "running")
         *last-event-ms* *now-ms*
         (>= (- *now-ms* *last-event-ms*) +slow-after-ms+))))

(defun turn-status (head &optional (cols 40))
  "The running turn in a few words, or NIL when no turn is running — the
reference's `turn_status` (app.rs:7501-7566).

**Two orderings and a missing phase, all measured off `app.rs:7560-7566`.**

  · the SPINNER COMES FIRST — `{spin} Responding{since}{count}` — and ours had
    it last, after a ` · `, which puts the one moving glyph on the edge where a
    narrow border truncates it away first;
  · `since` comes before the count, not after;
  · and there was **no prefill arm at all**. While `turn.progress` says the
    prompt is still expanding, the reference replaces the whole status with
    `{spin} {prefill_line(pf, w-6)}` — the bar, the rate and the estimate. Ours
    had `prefill-line` (`src/progress.lisp:172`) written, tested and called from
    nowhere, so the one number this harness exists to move never reached the
    composer's edge. COLS is the border's width, which is why it is a parameter:
    the line is sized to the edge it is being pinned to."
  ;; **`turn-busy-p`, not the state name** — see its docstring: the state is `finished` for the
  ;; whole of a tool call, so gating here on `running` announced the past tense over work in
  ;; progress. The operator's own report: *"while your turn not finished you are 'Responding'
  ;; regardless of the tool calls or thinking or ongoing replies."*
  (let* ((turn (session-turn (head-session head)))
         (running (and turn (turn-busy-p turn))))
    (when running
      (let* ((pp (getf turn :progress))
             (spin (string (spinner *now-ms*))))
        (if (and pp (numberp (getf pp :total)) (plusp (getf pp :total))
                 (< (or (getf pp :processed) 0) (getf pp :total)))
            ;; prefilling: the bar says everything the words would have
            (format nil "~a ~a" spin (prefill-line pp (max 1 (- cols 6))))
            (let ((since (let ((elapsed (%turn-elapsed-ms)))
                             ;; **THE SAME HELPER THE STATUS BAR READS**, so the two timers are one
                             ;; computation in two places rather than two that happen to agree — and
                             ;; so a start time that cannot be measured honestly (a wall clock that
                             ;; moved under this head, measured) says so here too instead of drawing
                             ;; a negative.
                             (if elapsed
                             (format nil "~a" (duration elapsed))
                             ;; **a turn that came out of a snapshot measured nothing**, and this
                             ;; sentence is the case that never grows — so there is nothing here for
                             ;; the layout to hold still.
                             "started before this head attached")))
                  (tokens (getf turn :tokens)))
              (concatenate
               'string
               spin
               +turn-status-head+
               since
               ;; **the count, or the character count where the server has not spoken**, or a
               ;; `messages`-backend turn whose seam carries no token count — and NOTHING is
               ;; nothing, which is the rule the reference keeps too: a zero is a zero wearing a
               ;; measurement's clothes.
               (cond ((and (numberp tokens) (plusp tokens))
                      (format nil " · ~a tok" (thousands tokens)))
                     ((plusp (length (or (getf turn :text) "")))
                      (format nil " · ~a chars" (thousands (length (getf turn :text)))))
                     (t "")))))))))

