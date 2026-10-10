;;;; live-call-card.lisp — the LIVE card of a running call: the clock it is drawn
;;;; against, its header, and the body the reference's `Card::render` gives it.
;;;;
;;;; The same call gets the same CLASS here and in `tool-result-card.lisp`: the wire
;;;; shapes differ, the tool does not.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defun %call-elapsed-ms (call)
  "How long a running call has been going, from the moment its ToolStarted arrived.

**On THIS head's clock, anchored when the event ARRIVED** — `note-call-started`
records `internal-real-time-ms` at `:tool-started`, and nothing here reads the
envelope's `ts`. That is not an accident to preserve, it is the trap avoided: the
daemon's `ts` is the daemon's clock and `internal-real-time-ms` is ours, and a
duration measured across the two is silently wrong by whatever they disagree by —
worst exactly when a head attaches to a daemon on another box, which is where this
fleet is going. The question the row answers is *how long have I been waiting*, and
the reader's clock is the right one for that.

It is short by the delivery latency of the one frame that started the call, and that
is the honest cost of answering in one clock rather than two. The alternative the
document offers — have the daemon report an elapsed — needs a progress event, and the
whole point here is not to need one."
  (let ((start (cdr (assoc (getf call :call-id) *call-started-ms* :test #'string=))))
    (and (numberp start) (max 0 (- (internal-real-time-ms) start)))))

(defun %live-elapsed-ms (ms)
  "MS rounded DOWN to a tenth, for a duration that is still moving.

**Coarse on purpose, and it is the operator's number**: what the row answers is *is
this moving, and roughly how long has it been — a live coarse timer would be nice,
say 1/10th of a second*. A figure that turned over on every millisecond would churn
two digits nobody reads, and — the reason it is here rather than left to the
formatter — it would spend a frame saying what the next frame says again. The frame
is rebuilt a tenth apart (`+live-frame-ms+`), so a tenth is the finest thing that can
reach the screen anyway; rounding here makes the number honest about its own
resolution instead of pretending to a precision it cannot deliver.

**The SETTLED duration is not rounded** — `note-call-finished` measures it once,
exactly, and the row shows that (app.rs:2702-2713 is the reference's arithmetic, and
it is not changed here). Only a number that is still moving is coarse."
  (* 100 (floor (max 0 (or ms 0)) 100)))

;; `%verb-kind` is not here: it moved up to `roles.lisp`, beside the table it
;; reads (`*verb-map*`). It used to sit below the card protocol that calls it,
;; which was harmless at runtime and wrong in the file — a name-to-kind lookup
;; belongs with the name-to-word one. The split is the moment to say so.

;; `%budget-for-verb` is gone: the budget is `card-body-budget` now, a method per
;; tool family — its old docstring moved onto the generic. `(cons 10 3)` is the
;; `tool-result-card` base, so a tool nobody has classified keeps the default the
;; `case`'s `t` arm gave it.

(defparameter +expanded-max-rows+ 400
  "`Budget::expanded_max`. A 40,000-line result expanded into a terminal is not
\"expanded\", it is the conversation gone.")

(defun head-tail-lines (lines first last)
  "FIRST lines, then LAST lines, and a row saying how many went — `head_tail`
(card.rs:512-532).

The marker is a SEPARATOR ROW and not a line of the content, because a reader
must never mistake the elision for output. It is never a silent cut: the count
is the disclosure, the same rule the log applies to `dropped`."
  (if (<= (length lines) (+ first last 1))
      lines
      (let ((hidden (- (length lines) first last)))
        (append (subseq lines 0 first)
                (list (list (cons (format nil "… +~d lines" hidden) '(:dim t))))
                (when (plusp last) (last lines last))))))

(defun call-lines (call cols &optional prefs)
  "One tool call of the running turn — the reference's `card::Card::header`:

    ○ Read src/cards.lisp · proposed
    ◐ Reading src/cards.lisp · 1.2s
    ● Read src/cards.lisp · 27ms

The mark carries the phase (faint / pending / the outcome's role), the verb is
Strong and in the running TENSE — a card that says `Ran` while the command is
still going lies about the one thing it exists to say — the target is Plain, and
the tail is faint unless the outcome is not `ok`. Ours drew `· bash → running` in
three colours, none of them the reference's."
  (let* ((card (tool-card-of (getf call :name)))
         (st (getf call :state))
         (state (getf st :state))
         (running (string= state "running"))
         (finished (string= state "finished"))
         (outcome (getf st :outcome))
         (word (and finished (outcome-name outcome)))
         (bad (and finished (not (string= word "ok"))))
         ;; `Phase::Running`'s mark is `Pending`; a settled one takes the
         ;; OUTCOME's role, and `%outcome-style` is the one place that mapping
         ;; lives now — it used to be spelled again here, and the two spellings
         ;; disagreed about `not_run` and about backgrounded.
         (outcome-style (if finished
                            (or (%outcome-style outcome) +role-pending+)
                            +role-pending+))
         (mark (cond (running (cons "◐" +role-pending+))
                     (finished (cons "●" outcome-style))
                     (t (cons "○" '(:dim t)))))
         (target-raw (or (getf call :target) ""))
         (note (getf call :progress-note))
         (ms (and finished (getf (alexandria:assoc-value *call-facts* (getf call :call-id)
                                                          :test #'string=)
                                 :ms)))
         (tail (remove nil
                       (cond
                         (running (list (duration (%live-elapsed-ms (%call-elapsed-ms call)))
                                        note))
                         (finished (append (and (numberp ms) (list (duration ms)))
                                           (and bad (list (%outcome-word word)))
                                           (and bad (list (%outcome-why outcome)))))
                         (t (list (or note "proposed"))))))
         (joined (and tail (format nil " · ~{~a~^ · ~}" tail)))
         (tail-style (if bad outcome-style '(:dim t)))
         (verb-str (card-verb card :running running))
         ;; **THE TAIL IS MEASURED FIRST AND THE SUBJECT IS GIVEN WHAT IS LEFT** — R25's rule,
         ;; and the whole reason the operator could not tell a running command from a crash.
         ;;
         ;; The header tail is *dropped whole when it does not fit* below, so a long command
         ;; pushed the clock off the row and the one number that says **this is alive** went
         ;; with it. MEASURED on their screen: `◐ Running "cd /tmp && (sleep 6; …) & …"` — the
         ;; mark and the running tense, and no `· 12.4s` anywhere, on a command with two
         ;; hundred characters of arguments.
         ;;
         ;; The tail does not shrink — it is the fact, and half of `· 12.4s` is not a duration.
         ;; What gives way is the SUBJECT, which is what `%shorten-subject` is for and what
         ;; `%tool-result-lines` already did. One rule, two rows: measured against letibot's
         ;; screen, a subject that runs to the edge is how the reference draws it too.
         ;; **THE SAME ARITHMETIC AS THE SETTLED ROW'S** (`%subject-room`): this card used
         ;; to count its leading columns itself, with a literal 2 standing for the mark and
         ;; its space — true only while a mark is one column wide, which is a rendering
         ;; decision rather than a constant. **The old spelling is described here and not
         ;; quoted**: a source assertion cannot tell code from the prose explaining it, and
         ;; the test that pins this one reads this very file (`the-tool-row-arithmetic-has-
         ;; one-spelling` — the lesson is `render.lisp`'s, learned the same way).
         (room (%subject-room cols (car mark) verb-str (and joined (string-width joined))))
         (target (if (plusp (length target-raw))
                     (%shorten-subject target-raw room)
                     ""))
         (head (list mark
                     (cons " " nil)
                     (cons verb-str '(:bold t))
                     (cons (if (plusp (length target)) (format nil " ~a" target) "") nil))))
    ;; **The card's BODY, which had three of its four parts missing**
    ;; (app.rs:8767-8864, card.rs:482-511). Built in the reference's order and
    ;; then given the reference's budget.
    (let* ((open (getf prefs :show-tools))
           (inline-bytes (getf st :inline-bytes))
           (full-bytes (getf st :full-bytes))
           (spill (getf st :spill))
           (decision (getf (alexandria:assoc-value *call-facts* (getf call :call-id)
                                                   :test #'string=)
                           :decision))
           (edit (getf st :edit))
           (body nil))
      ;; §8.3's disclosure, as prose and in units a person reads. In the BODY
      ;; rather than the header tail, because the header tail is dropped whole
      ;; when it does not fit and "there is more, and here is how to get it" is
      ;; not a line that may vanish on a narrow terminal. It is the one line on
      ;; this card with an obligation attached.
      (when (numberp inline-bytes)
        (setf body
              (list (list (cons (if spill
                                    (format nil "~a of ~a went to the model, the rest is kept — read_spill hash=~a"
                                            (bytes-human inline-bytes)
                                            (bytes-human (or full-bytes inline-bytes))
                                            spill)
                                    (bytes-human inline-bytes))
                                '(:dim t))))))
      ;; a file-editing call carries both sides of the change (event.rs:75), and
      ;; the diff REPLACES the body rather than following it. Two columns
      ;; narrower than we had it: the card indents its body by two, and `ind` was
      ;; in effect being subtracted twice.
      ;; **AND THE SAME FIX HERE, because the card and the settled row are two renderers of one
      ;; fact** — the second place this same guard was written, and the reason the drift would
      ;; have survived a fix to only one of them. See `%tool-result-lines` for the measurement.
      (when edit
        (setf body (edit-lines edit (- cols 2) :subject target-raw)))
      ;; the approval this call was gated by — `%decision-card-lines`, the ONE
      ;; spelling the settled row draws too. It was a second copy here, and it
      ;; had already drifted: the echoed-basis skip was the settled row's fix
      ;; alone, so the live card drew the decider's line twice for the fraction
      ;; of a second before the settled row replaced it. `rows` is the card's
      ;; own visible text, as strings, which is what the echo test searches.
      (when decision
        (setf body (append body
                           (%decision-card-lines decision cols :open open
                                                 :rows (mapcar (lambda (l)
                                                                 (apply #'concatenate 'string
                                                                        (mapcar #'car l)))
                                                               body)))))
      (cons (if (and joined (<= (+ (%segs-width head) (string-width joined)) cols))
                (append head (list (cons joined tail-style)))
                (%truncate-segs head cols))
            ;; `Card::render`: the budget over the body, then two columns of
            ;; indent, then every row trimmed to the width. A folded card with a
            ;; sixty-row diff drew all sixty rows here; the reference draws ten,
            ;; a marker, and three.
            (let ((budget (card-body-budget card)))
              (mapcar (lambda (l) (%truncate-segs (cons (cons "  " nil) l) cols))
                      (if open
                          (head-tail-lines body +expanded-max-rows+ 0)
                          (head-tail-lines body (car budget) (cdr budget)))))))))

