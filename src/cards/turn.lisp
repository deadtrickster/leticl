;;;; turn.lisp — the turn as a whole and the cards that ride above the composer:
;;;; `turn-lines`, raw call markup, the decision, quit and secret cards, and the
;;;; clock the rows are stamped with.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.

(in-package #:leticl)

(defun turn-lines (turn cols prefs)
  "The running turn, live, in the reference's order: the working first —
reasoning, then the calls, each stepped in — and the answer under it, with a
blank row after each part that is there. A finished turn renders from the
transcript instead (view.rs on TurnView.appended) — rendering both would show the
answer twice.

Folded reasoning still shows its LAST line under the header, on the rail: the
operator can see the model is still thinking and what about, without opening it.
Calls are drawn oldest first — the session pushes them, so the list is newest
first and was drawn that way.

**AND IT DRAWS WHILE A CALL RUNS, WHICH IS WHAT THIS GATE GOT WRONG.** The gate was the turn's state
NAME, `\"running\"` — and the daemon sets that to `\"finished\"` when the round's GENERATION ends, which is
exactly when a tool call STARTS. MEASURED on the operator's own head while fixing this: a `bash` call at
`:state \"running\"` under a turn whose name read `\"finished\"`, so this function returned NIL for the whole
of a long command and the call was **not on the screen at all** — *\"rano again hanged on tool call - look,
it is not even printed on the screen.\"* An invisible call is indistinguishable from a wedged head, which
is the same complaint `turn-busy-p`'s docstring records in its fifth place.

**THIS IS THE THIRD PLACE THE SAME CONFUSION WAS FOUND, AND THE FIRST ONE A READER LOOKS AT.** The status
row was fixed first (`turn-busy-p`, whose docstring has the measurement: the past tense for work in
progress), then the esc arm (`%normal-key`: *\"gated on the name, esc esc did NOTHING while a command
ran\"*), and this one was left behind both. Where a call is LIVE the gate is `turn-busy-p`.

**The double-draw the old gate protected against is still protected, by construction rather than by the
gate.** A turn's text and reasoning are APPENDED to the transcript and CLEARED when generation ends
(`:appended` names the item that took them, and MEASURED, `:text` is `\"\"` at state `\"finished\"`), so
the answer is drawn once, from the transcript, and the live block has nothing to repeat. Both parts are
already drawn only when non-empty, so the two cannot both draw the same bytes."
  ;; **THE TAIL HOLDS WHAT THE TRANSCRIPT HAS NOT TAKEN OVER — AND THAT, NOT `turn-busy-p`, IS THE
  ;; GATE.** The two are not the same question, and the operator's last report is the gap between
  ;; them: *"it flickers on when you stop replying - the very end."*
  ;;
  ;; `turn-busy-p` is false the moment a turn is neither generating nor waiting on a call — and the
  ;; round's generation ENDS when its calls are proposed, so the last thing keeping a turn busy is
  ;; its LAST UNFINISHED CALL. So every turn's end ran: the last `tool_finished` made the turn not
  ;; busy, this gate closed, the tail stopped drawing — **the answer included** — while `:text` was
  ;; still non-empty (no row had taken it over) and the assistant row's body had not landed yet. For
  ;; those frames the answer was on NEITHER side of the handover, the bottom-anchored window shifted
  ;; by the tail's height, and it shifted back when the body arrived. The operator's capture shows
  ;; exactly that: the whole screen bouncing ~3 rows at each turn end, with no counts row among the
  ;; movers (the counts scroll with the content) and the frame journal showing the body height
  ;; UNCHANGED, because a clamped window cannot show a content shift at all.
  ;;
  ;; The text's own rule was always the right one, and the docstring below already relied on it: **a
  ;; part is drawn while it is non-empty, and cleared when the row that took it over lands.** So the
  ;; answer is drawn while the head still holds it, whichever way the turn's state fell. That is
  ;; also what letibot's live pane does — it draws unless `superseded`, the fact that every row the
  ;; turn published has a body, and not a state name.
  (when (and turn (or (turn-busy-p turn)
                      (plusp (length (or (getf turn :text) "")))))
    (let ((ind (activity-indent cols))
          (out nil))
      ;; **R37: the rung hides the WORKING of a live turn and never the turn.** What goes is
      ;; the reasoning and the calls — the head's account of producing an answer. What STAYS
      ;; is the answer itself, the footer under it (`turn-footer-lines`, drawn separately at
      ;; the tail), and every blank row's position: a turn that is running must still be
      ;; visible AS running, or a ten-minute tool-heavy turn draws nothing at all and the
      ;; reader cannot tell working from wedged. That is the rung's own stated risk.
      (flet ((emit (lines) (setf out (append out lines))))
        ;; **THE READING RUNG DRAWS NOTHING FOR ITS WORKING, AND THAT IS CORRECT — THE COUNTS
        ;; COME FROM `live-here` INSTEAD.**
        ;;
        ;; This was briefly a running `[N thinking lines]` line, to stop the count arriving above an
        ;; answer already read. It did arrive on time, and it was WRONG in two ways the operator's own
        ;; screen showed inside one turn: the live turn is drawn in the TAIL, so before the answer has
        ;; text the marker's only neighbours are the chrome — *"right after my prompt - the running [N
        ;; thinking lines] appeared glued to 'Responding' status line - very ugly"* — and it DUPLICATED
        ;; the count, because `live-here` already glues live work onto the newest visible row. Two
        ;; markers, two numbers: `[195 thinking lines]` and `[240 thinking lines]`, for one stretch of
        ;; work. This file's own rule is that a run's rendering lives in one place; the second renderer
        ;; was mine and it is gone.
        ;;
        ;; What actually removes the late arrival is upstream, in `apply-event`: the reasoning deltas
        ;; are KEPT at every rung, so `%hidden-run-live-work` has counts to hand `live-here` from the
        ;; first delta instead of only once the turn settles and the item lands. The rung hides the
        ;; TEXT of the working, which it always did.
        (unless (reading-p)
          (alet (getf turn :reasoning)
          (when (plusp (length it))
            (emit (step-in-lines
                   (if (getf prefs :show-reasoning)
                       (reasoning-lines it cols prefs :running t)
                       (list (reasoning-header it cols nil t)
                             (let ((last (or (car (last (remove-if (lambda (l) (zerop (length (string-trim " " l))))
                                                                    (uiop:split-string it :separator '(#\newline)))))
                                             "")))
                               (list (cons "┃ " '(:dim t))
                                     (cons (truncate-to-width last (max 4 (- cols ind 2)))
                                           '(:dim t :italic t))))))
                   ind))
            (emit (list nil))))
          (let ((calls (reverse (getf turn :calls))))
            (when calls
              (emit (step-in-lines (mappend (lambda (c) (call-lines c (- cols ind) prefs)) calls) ind))
              (emit (list nil)))))
        (alet (getf turn :text)
          (when (plusp (length it))
            (emit (markdown-lines it :width cols :limit +body-lines-budget+))
            (emit (list nil))))
        ;; The raw `<function=…>` markup the model wrote, when ctrl-x has asked for
        ;; it. NOT a fold: a fold hides something the reader knows is there, while
        ;; this reveals markup the default view is required never to show, so it is
        ;; off unless asked for by name.
        (when (and (not (reading-p)) (getf prefs :raw-calls))
          (let ((raw (getf turn :raw-calls)))
            (when (and (stringp raw) (plusp (length raw)))
              (emit (raw-call-lines raw cols))))))
      out)))

(defun raw-call-lines (raw cols)
  "The raw, unparsed text of a tool call, behind `ctrl-x` — the reference's
`raw_call_lines` (`app.rs:10135-10152`).

    ┌─ raw tool call · ctrl-x
    │ {\"path\": \"src/cards.lisp\", \"old_string\": \"…\"}
    └─

**A labelled block and not an inline row**, and the reason is the whole point of the
control: this is NOT the assistant speaking. Faint frame, and the text itself in the
code role — it is EVIDENCE, and evidence that looks like prose is how the defect
started. The seam names the chord, because a block nobody can turn off again is a
trap.

**One function for both callers**, which is why it is here and not beside either of
them: the LIVE turn draws the `<function=…>` markup as the model writes it
(`turn.lines`, from the deltas), and a SETTLED row has no markup left — the parser
ate it — so it draws `{name} {arguments}` instead. Two renderers would have drifted
into two different-looking blocks for one control.

**COLS is required, and it is R25's other half.** This wrapped at
`(1- *target-max-cols*)` — 119 columns whatever the pane was — so a 227-column window
drew a raw call as a 119-column column of text with a hundred columns of nothing
beside it. That is the same defect as the headline's and it showed up in the same
audit: **a wrapper on a display path that does not know its width cannot wrap
honestly.** The rail costs two columns, so the text gets `(- cols 2)`, and the
remainder is disclosed by `wrap-text` rather than clipped by the painter."
  (let ((out (list (list (cons "┌─ raw tool call · ctrl-x" '(:dim t))))))
    (dolist (l (uiop:split-string (or raw "") :separator '(#\newline)))
      (dolist (w (wrap-text l (max 1 (- cols 2))))
        (push (list (cons "│ " '(:dim t)) (cons w nil)) out)))
    (push (list (cons "└─" '(:dim t))) out)
    (nreverse out)))

(defun decision-card-lines (head cols)
  "The ask card: transcript visible above, one list on the screen at a time
(agents.md). A permission has the ladder; a question has choices."
  (let ((d (first (session-open-decisions (head-session head)))))
    (when d
      (let* ((kind (getf d :kind))
             (question (string= kind "question"))
             (options (if question (getf d :choices) (getf d :options)))
             (sel (head-decision-sel head))
             (body nil))
        (push (list (cons (format nil " ~a " (if question "question" "permission"))
                          '(:bold t :fg :yellow))
                    (cons (format nil " ~a" (or (getf d :summary) ""))
                          '(:bold t)))
              body)
        (when (plusp (length (or (getf d :target) "")))
          (push (list (cons " " '(:fg :yellow))
                      (cons (getf d :target) '(:fg :bright-white)))
                body))
        (when (plusp (length (or (getf d :detail) "")))
          (push (list (cons (format nil " ~a" (getf d :detail))
                            '(:dim t)))
                body))
        (when (plusp (length (or (getf d :because) "")))
          (push (list (cons (format nil " because: ~a" (getf d :because))
                            '(:italic t :dim t)))
                body))
        (let ((i 0))
          (dolist (o options)
            (let* ((label (if question o (getf o :label)))
                   (chosen (= i sel))
                   (style (cond (chosen '(:reverse t :bold t))
                                (t nil))))
              (push (list (cons (format nil " ~a ~a. " (if chosen "❯" " ") (1+ i)) style)
                          (cons (or label "?") style))
                    body))
            (incf i)))
        (push (list (cons (format nil " enter answers · up/down moves · esc ~a"
                                  (if question "leaves it open" "does nothing"))
                          '(:dim t)))
              body)
        ;; WHERE THE WORDS GO. The option is labelled "Deny, and tell the model
        ;; why" and nothing said how — which is how the why ended up in the
        ;; composer with nothing to do with it. A card that names an affordance
        ;; has to say where the affordance is.
        (awhen (and (not question)
                    (find-if (lambda (o)
                               (search "reject_always"
                                       (string-downcase (or (getf o :kind) ""))))
                             options))
          (push (list (cons (format nil " type: ~a <the words the model should hear>"
                                    (getf it :option-id))
                            '(:dim t)))
                body))
        (nreverse body)))))

(defun quit-choices (head)
  "The two ways out and what each does to the daemon — `quit_choices`. The second
names how many OTHER heads will be told, from the session's own head list."
  (let ((others (max 0 (1- (length (session-heads (head-session head)))))))
    (list (cons "leave this head"
                "the daemon keeps running: the session stays warm and `letibot` reattaches to it")
          (cons "leave and stop the daemon"
                (case others
                  (0 "the session is written to disk and `letibot --continue` reopens it — but its prompt leaves the model server's cache, so the next turn prefills cold")
                  (1 "one other head is attached and will be told. The session is on disk; the next turn after reopening prefills cold")
                  (t (format nil "~d other heads are attached and will be told. The session is on disk; the next turn after reopening prefills cold" others)))))))

(defun quit-card-lines (head cols)
  "The quit card, to the reference's shape (`quit_card_lines`): a bold title, each
choice as `▸  1  name` with its consequence wrapped dim under it at eight in."
  (let ((w (max 20 cols))
        (sel (min 1 (head-quit-sel head))))
    (append
     (list (list (cons "leave — and what happens to the daemon" '(:bold t))))
     (loop for (name . why) in (quit-choices head)
           for i from 0
           for picked = (= i sel)
           append (cons (%truncate-segs
                         (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i)) nil)
                               (cons name (if picked '(:bold t) nil)))
                         w)
                        (mapcar (lambda (l) (cons (cons "       " nil)
                                                  (mapcar (lambda (seg) (cons (car seg) '(:dim t))) l)))
                                (wrap-segments (list (cons why nil)) (max 4 (- w 8)))))))))

(defun secret-card-lines (head cols)
  (declare (ignore cols))
  (let ((req (head-secret-req head)))
    (when req
      (list (list (cons " sudo " '(:bold t :fg :yellow))
                  (cons (format nil " ~a" (getf req :prompt)) '(:bold t)))
            (list (cons " for " '(:dim t))
                  (cons (getf req :command) '(:fg :bright-white)))
            (list (cons " password: " '(:fg :bright-cyan :bold t))
                  (cons (make-string (length (head-secret-buf head))
                                     :initial-element #\*)
                        nil))
            (list (cons " enter submits · esc refuses" '(:dim t)))))))



(defun %clock-time (ts)
  "TS (epoch ms) as `HH:MM:SS`, or empty when there is no timestamp.

Empty rather than `00:00:00`: a row read out of a snapshot may have no `ts`, and
midnight is a time nobody took — the same rule the duration on a card follows."
  (if (and (numberp ts) (plusp ts))
      ;; LOCAL time, which is what `localtime_r` gives the reference. Passing an
      ;; explicit 0 here is UTC, and the stamp then read 11:53:34 on a screen whose
      ;; clock said 13:53:34 — a timestamp that is wrong by the offset is worse
      ;; than no timestamp, because it looks like a measurement.
      ;; **A UNIX timestamp is not a universal time.** The epochs differ by
      ;; 2 208 988 800 seconds (25 567 days), and because that is a whole number
      ;; of days the H:M:S survived the mistake while the DATE landed in 1956 —
      ;; so the local offset was taken for 1956 (CET, no summer time) instead of
      ;; 2026 (CEST), and every prompt was stamped an hour early all summer.
      ;; Measured against letibot on the same row: `15:00:08` against `14:00:08`.
      (multiple-value-bind (s m h)
          (decode-universal-time (+ (floor ts 1000) 2208988800))
        (format nil "~2,'0d:~2,'0d:~2,'0d" h m s))
      ""))

(defun %clock-hm (ts)
  "TS (epoch ms) as `HH:MM` — the operator's own format for the row above the composer:
*\"Responded in <full turn time> at <end-timestamp> as hh:mm\"*.

The same LOCAL-time decoding as `%clock-time`, and for the same measured reason — an explicit 0 here
is UTC and the stamp is then wrong by the offset, which is worse than no stamp because it looks like a
measurement. Seconds are dropped because the question this row answers is *when*, to the minute, and
two more digits on a line that is otherwise about a duration is precision nobody reads."
  (if (and (numberp ts) (plusp ts))
      (multiple-value-bind (s m h)
          (decode-universal-time (+ (floor ts 1000) 2208988800))
        (declare (ignore s))
        (format nil "~2,'0d:~2,'0d" h m))
      ""))

(defun turn-footer-lines (turn cols)
  "The line under a finished turn — and only when it ended UNUSUALLY.

**Not the numbers.** I put `─ 1.01M in/1.01M cached · 91 out · 17.8 tok/s · 5.1s`
here, and the comparison against letibot's own screen showed a whole telemetry row
where it draws NOTHING: measured, row 58, ours 56 columns of numbers and its zero.
The reference's rule is that an ORDINARY ending reads as ordinary — `eos` and
`word` produce no line at all — and that the turn's numbers live on the composer
box's bottom edge while it is running (`turn-status`), not in the transcript.

So one line, yellow, and only for the endings a person must not have to go looking
for. `Failed` is a different register: red, shouted, and WRAPPED rather than
truncated, because the reason is the whole content of the event."
  (when turn
    (let* ((state (getf turn :state))
           (name (and state (getf state :state)))
           (finish (and state (getf state :finish-reason))))
      (flet ((say (text style) (list (list (cons text style)))))
        (cond
          ;; an ordinary ending is ordinary: no line
          ((and (string= name "finished")
                (member finish '("eos" "word") :test #'string=))
           nil)
          ((and (string= name "finished") (string= finish "length"))
           (say "── CUT SHORT — it hit the output limit mid-answer; ask it to continue"
                '(:fg :yellow)))
          ((and (string= name "finished") (string= finish "aborted"))
           (say "── stopped early (aborted)" '(:fg :yellow)))
          ((string= name "finished")
           ;; a reason nobody recognises is SHOWN, never normalised
           (say (format nil "── ended for an unrecognised reason: ~a" finish)
                '(:fg :yellow)))
          ((string= name "interrupted")
           (say (format nil "── interrupted: ~a (~a)" (getf state :reason)
                        (if (getf state :partial-kept)
                            "what it had written is kept" "nothing kept"))
                '(:fg :yellow)))
          ;; **Wrapped, not truncated** (app.rs:8232-8245). The rule is already
          ;; written three paragraphs up in this docstring and the code did the
          ;; opposite: `cols` was declared ignored and the line was emitted
          ;; whole, so a long provider error was cut at the frame's edge — and
          ;; the reason is the whole content of the event. A failure is not an
          ;; ending a turn is allowed to have, so it does not read like one.
          ((string= name "failed")
           (mapcar (lambda (l)
                     (mapcar (lambda (seg) (cons (car seg) '(:fg :red :bold t))) l))
                   (wrap-segments
                    (list (cons (format nil "── FAILED — ~a (~a)" (getf state :error)
                                        (if (getf state :partial-kept)
                                            "what it had written is kept"
                                            "nothing was recorded"))
                                nil))
                    (max 20 cols))))
          ;; running: the numbers belong on the box's edge, not here
          (t nil))))))

(defun queued-lines (head cols &optional texts)
  "Prompts sent that the transcript does not hold yet, marked `queued`.

**TEXTS is which pending prompts to draw, and it defaults to the head's whole queue.** The tail
echoes and an ANNOUNCED row are the same message at two moments — see `*bound-prompts*` — so the
one renderer takes the list rather than a second shape being built beside it. The tail passes the
queue minus everything a bound row is already drawing; the bound row passes just its own text.

A prompt sent while a turn runs is queued as a FOLLOW-UP USER ITEM, and the item is
appended only at the next step boundary — which for a turn with no tool calls is
the turn's end. Between the enter press and that append the words existed NOWHERE
on the screen: the composer had handed them off, the daemon had accepted them, and
the operator was looking at a conversation that had swallowed a sentence they had
just typed.

It comes back at the boundary, so nothing is lost — but NOT LOST and VISIBLE are
different requirements, and this is the second one.

**The shape a settled user row gets**, dimmed, with `queued` where the timestamp
goes (`queued_lines`, app.rs:9017-9046). Ours drew a bright-cyan `›`, put the tag
at the END of the line, and showed only the FIRST line of a multi-line prompt —
so a pasted paragraph queued as one sentence and then grew into a block when the
boundary landed, which reads as the head having changed what was sent.

The bar is `▌` in `UserAccent`, so the pending row occupies the place its real
row will take; the tag is `Role::Pending`, the colour the spinner already uses
for something in flight; and continuation rows hang under the text by the tag's
own columns. `/cells` is folded here as well as in the user row, and it has to
be the SAME text going in: the pending row is cleared by matching the user item
the daemon appends, so a head that queued an abbreviation and received the real
thing would leave the `queued` line on the screen for the rest of the session."
  (let ((w (max 20 cols)))
    ;; **THE TAG IS PER ENTRY, not per pane** (R16): an echo a snapshot could not
    ;; resolve is not `queued` — the head can no longer support that claim — and
    ;; saying queued anyway is the lie R2 exists to prevent.
    ;;
    ;; **The layout is the reference's rule applied to whichever word is there**: the
    ;; first row shares its width with the tag and the continuations hang under the
    ;; text, by `width(tag) + 3` (`app.rs:9017-9046`). So an `unconfirmed` echo
    ;; measures its own word rather than being padded to the other's — the reference's
    ;; arithmetic, on a tag it does not have.
    (let ((open (getf (head-prefs head) :show-tools))
          ;; **NOTHING A BOUND ROW IS ALREADY DRAWING IS DRAWN HERE** — the tail is for the queue,
          ;; which is what is NOT in the conversation yet (letibot's rule; see `*bound-prompts*`).
          (bound (mapcar #'cdr *bound-prompts*)))
      (loop for text in (if texts
                                     ;; **a bound row is handed its own ONE piece, and the tail's
                                     ;; list is ALREADY oldest-first** — `%unbound-echo-pieces`
                                     ;; answers in the order the rows will be announced, which is the
                                     ;; order the pieces must READ in, so the outer `reverse` that used
                                     ;; to turn the queue around applies to the caller's list alone.
                                     (reverse texts)
                                     ;; **PIECE-WISE, BECAUSE ONE QUEUED ENTRY CAN BE TWO MESSAGES.**
                                     ;; `%bind-echo` used to hand an announced row the WHOLE entry, and an
                                     ;; entry is two prompts whenever the operator sends twice behind a
                                     ;; running turn — the head coalesces them, newline-joined, to match
                                     ;; the one row the daemon will commit (`%queue-prompt`). The
                                     ;; equality filter below then dropped that entry from here while the
                                     ;; row drew both messages, so the FIRST message's row carried the
                                     ;; SECOND's words, and the piece left over after the row's content
                                     ;; landed came back here — the same sentence on the screen twice. The
                                     ;; operator, twice: *"queue problem - items queued twice, at least
                                     ;; usually - visually"* and *"that second message was presented with
                                     ;; the first as a first line"*. A piece a row is drawing is dropped; a
                                     ;; piece no row is drawing stays here, drawn by the tail — as ONE
                                     ;; block per entry, because one entry is one message to read.
                                     (%echo-leftover (head-queued head) bound))
            for tag = (if (member text *queued-unconfirmed* :test #'equal)
                          "unconfirmed"
                          "queued")
            for head-w = (max 8 (- w 2 (string-width tag) 3))
            for indent = (make-string (+ (string-width tag) 3) :initial-element #\space)
            append (let* ((rows (or (wrap-segments
                                     (list (cons (%fold-cells text) nil)) head-w)
                                    (list (list (cons "" nil)))))
                          ;; **R33: A THING WAITING IS ONE ELIDED HEADLINE.** The operator,
                          ;; looking at three of their own messages queued: *"three giant
                          ;; messages queued"* — and three of them filled a 63-row pane,
                          ;; the conversation pushed off the screen. They wrote it; they do
                          ;; not need it read back. What the row owes them is *your message
                          ;; is here and in flight*, which one row says, plus enough of it to
                          ;; recognise if they want to — not the whole of it.
                          ;;
                          ;; **The unit of the seam is SCREEN ROWS**, the same choice
                          ;; `reasoning-header` makes: a pasted paragraph is one source line
                          ;; that costs forty rows, so "1 line" beside a row that would eat
                          ;; half the pane answers the wrong question.
                          ;;
                          ;; **`/t` opens it — the head's own *unfold the long rows* verb**,
                          ;; which is letibot's ruling (`app.rs:6194-6203`) and is the same
                          ;; choice this head makes everywhere else: one key for one idea, and
                          ;; a second fold chord for a second kind of row is a second thing to
                          ;; learn. The operator asked for *expandable the usual way*, and
                          ;; this is the usual way, so the seam names THE KEY THE READER ALREADY
                          ;; HAS rather than a new one.
                          (closed (< 1 (length rows)))
                          (headline (first rows))
                          (headline-w (reduce #'+ headline :key (lambda (seg) (string-width (car seg)))
                                              :initial-value 0)))
                     (if (or open (not closed))
                         (loop for row in rows
                               for i from 0
                               collect (append
                                        (list (cons "▌ " '(:fg :blue)))
                                        (list (if (zerop i)
                                                  (cons (format nil "~a · " tag) +role-pending+)
                                                  (cons indent nil)))
                                        (mapcar (lambda (seg) (cons (car seg) +md-faint+))
                                                row)))
                         ;; **ONE ROW, and the seam fits or the seam goes — never a second
                         ;; row.** A seam that does not fit would push the echo to two rows and
                         ;; undo the requirement on exactly the narrow screens where it matters
                         ;; most, so the ellipsis the truncator adds is the fallback.
                         (let* ((seam (format nil "  … +~d line~:p · /t opens it"
                                              (1- (length rows))))
                                (room (- head-w (string-width seam))))
                           (list (append
                                  (list (cons "▌ " '(:fg :blue)))
                                  (list (cons (format nil "~a · " tag) +role-pending+))
                                  (mapcar (lambda (seg) (cons (car seg) +md-faint+))
                                          (%truncate-segs headline (if (>= room 16) room head-w)))
                                  (when (>= room 16)
                                    (list (cons seam '(:dim t)))))))))))))

