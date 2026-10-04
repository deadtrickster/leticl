;;;; permission.lisp — the permission card: what is being asked, the ladder, and the oracle's advice
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

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

