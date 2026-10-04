;;;; assistant-card.lisp — the model's PROSE row: the answer at the body's own column,
;;;; and the `→ verb target · no result` line a call with nothing back keeps.

(in-package #:leticl)

(defclass assistant-card (card) ())

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


(defmethod card-lines ((card assistant-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    ;; The answer sits at the body's own column, with the question: it is
    ;; the one thing on the screen not subordinate to something else.
    ;;
    ;; **An empty row draws NOTHING.** Ours drew a lone `·`, which left a
    ;; row of punctuation between every pair of cards — measured against
    ;; letibot's screen, where an assistant row with no prose and no
    ;; unanswered call is simply absent.
    ;;
    ;; **And a call with no result gets a `→` row**, which is what survives
    ;; of the proposal: a call the transcript has taken over is drawn by its
    ;; RESULT, and drawing it here too is two rows and one fact. `→` therefore
    ;; means exactly "asked for, nothing came back" — the turn was
    ;; interrupted, or the body has not arrived.
    ;;
    ;; **Wrapped to the width it has**, and bounded at the reference's
    ;; `body_lines` budget. `markdown-lines` used to be called with no width
    ;; at all and `%place-lines` clips, so every paragraph longer than the
    ;; terminal was CUT at its edge — measured against letibot's screen,
    ;; where the same paragraphs wrapped to two rows.
    (let ((rows (when (plusp (length (getf body :text)))
                  (markdown-lines (getf body :text) :width cols
                                  :limit +body-lines-budget+))))
      (append
       rows
       ;; **`→ {verb} {target} · no result`, the whole line in
       ;; `Role::Attention`** (app.rs:9614-9645). Four things were wrong
       ;; and one of them is the row's entire meaning: the reference's own
       ;; note is that *"a row that looks like every other tool row and
       ;; quietly has no output is the shape a person reads straight past.
       ;; It is the only thing this row now means."* A call the transcript
       ;; has taken over is drawn by its RESULT; what survives here is the
       ;; case the proposal line is actually for — the turn was
       ;; interrupted, the round is still running, or the body has not
       ;; arrived.
       ;;
       ;; The target is derived from the arguments ON THIS ROW and never
       ;; looked up by call id: the row holds the very bytes the rule
       ;; reads, and an id-keyed lookup is how `→ Read TODO.md` came to sit
       ;; above a card whose payload was `README.md`. An EMPTY target earns
       ;; the call id its columns, because that is then the only thing
       ;; distinguishing two calls to the same tool. The indent is the
       ;; activity step (ours hard-coded two, which is wrong below sixty
       ;; columns), and the row is trimmed to the width like every other.
       ;; **the settled row's half of `ctrl-x`** (app.rs:11055-11061). A live
       ;; turn shows the raw markup the model WROTE, from the `ToolCall`
       ;; deltas; once the row is committed the markup is gone — the parser
       ;; read it — so what is left to show is the name and the arguments it
       ;; read, which is the fact the markup encoded. Without this arm the pref
       ;; did nothing at all on a transcript, which is every row but the one
       ;; being written.
       ;; **and the CALLS go with them** (R37): a tool call is the head's working, and
       ;; a row that kept its `→ Read src/cards.lisp · no result` line while claiming to
       ;; hide tool calls would be the half-hiding this rung exists to avoid. The row's
       ;; TEXT is untouched — it is the conversation.
       (when (and (not (reading-p)) (getf prefs :raw-calls))
         (loop for tc in (getf body :tool-calls)
               when (and (call-answered-p (getf tc :id))
                         (plusp (length (or (getf tc :arguments) ""))))
               append (raw-call-lines
                       (format nil "~a ~a" (getf tc :name)
                               (getf tc :arguments))
                       cols)))
       (unless (reading-p)
         ;; **`append`, not `collect`** — a row of the head's working can be more than
         ;; one LINE (a running card with a body, an edit with a diff), and `collect`
         ;; takes ONE item per call. Collected, the lines arrived as a single element and
         ;; the row was nested one level too deep: the reader saw `(  )` — a list printed
         ;; where a string belonged — which is how this was caught.
         (loop for tc in (getf body :tool-calls)
               unless (call-answered-p (getf tc :id))
               append (let* ((tgt (display-target (getf tc :arguments)))
                             (id (getf tc :id)))
                        (if (%call-running-p id)
                            ;; **A CALL THAT IS RUNNING IS DRAWN RUNNING, WITH ITS CLOCK
                            ;; — and this is the half the row was missing.**
                            ;;
                            ;; The operator, watching a `cargo test` that took two
                            ;; minutes: *"you do 'blablabla:' and then long ass tool call
                            ;; and I see nothing — literally indistinguishable from
                            ;; connection break or a crash. told you long time ago — to
                            ;; start counting before running command."*
                            ;;
                            ;; MEASURED on their own screen, capturing it at 6s, 14s and
                            ;; 24s while a command ran: the three frames were **byte
                            ;; identical**. The row was `→ Ran "…" · no result` — the form
                            ;; below, all of it `Role::Attention` — and it did not move.
                            ;; `→` means *asked for, nothing came back*, which is what a
                            ;; row says about a turn that was INTERRUPTED; saying it
                            ;; about a command running right now is the one reading it
                            ;; must not carry, and it is the reading the operator had.
                            ;;
                            ;; So a running call takes the LIVE card's own header —
                            ;; `◐ {Verb} {subject} · 1.2s`, the very `call-lines` the turn
                            ;; pane draws for it. ONE renderer, so the row and the live
                            ;; card cannot drift into two announcements of one call, and
                            ;; the number is `%live-elapsed-ms` over `%call-elapsed-ms`,
                            ;; whose clock starts at `ToolStarted` — when the command
                            ;; started, not when the model asked for it, so a call that
                            ;; waited on a decision does not count that wait as running
                            ;; time (`app.rs:3996-4005`).
                            (step-in-lines
                             (call-lines (list :call-id id
                                               :name (getf tc :name)
                                               :target tgt
                                               :state (list :state "running"))
                                         (max 20 (- cols (activity-indent cols)))
                                         prefs)
                             (activity-indent cols))
                            ;; **started, and nothing came back** — the turn was
                            ;; interrupted, or the body has not arrived yet. This is what
                            ;; `→` is for, and the whole of what the row now means
                            ;; (app.rs:9614-9645).
                            (let ((line (format nil "→ ~a~a · no result"
                                                (verb-label (getf tc :name))
                                                (if (plusp (length tgt))
                                                    (format nil " ~a" tgt)
                                                    (format nil " (~a)" id)))))
                              (list (%truncate-segs
                                     (list (cons (make-string (activity-indent cols)
                                                              :initial-element #\space)
                                                 nil)
                                           (cons line +role-attention+))
                                     cols))))))))))
  )


