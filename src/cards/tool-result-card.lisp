;;;; tool-result-card.lisp — the SETTLED tool row: the header, the one-line inline, the
;;;; diff beside it, the fold and the window into it — and the tool FAMILIES
;;;; (`read-card`, `run-card`, …) whose only per-tool facts are a verb and a budget.
;;;;
;;;; `edit-card` and `write-card` are the two families with a file of their own, because
;;;; a diff and a set of write targets are shapes rather than a word.

(in-package #:leticl)

(defclass tool-result-card (card)
  ((name :initarg :name :initform nil :reader card-tool-name
         :documentation "The TOOL NAME — held apart from the body because the LIVE card
of a running call has a name and no body: the two wire shapes differ, the tool's
identity does not, and sharing it is the point of the class."))
  (:documentation "One settled tool-result row. The per-tool subclasses below add no
slots — they exist so the things a TOOL decides (its verb, its body budget) are one
method each, shared by the live card and the settled row rather than agreed by
convention."))


;;; ------------------------------------------------------ the tool families ;;;
;;;
;;; One class per `card::Verb` kind — the kinds `*verb-map*` spells — plus
;;; `generic-tool-card` for a name the map does not know, which keeps the map's own
;;; additive rule: an unknown tool draws its own name and the default budget rather
;;; than a guess dressed as a fact.
;;;
;;; **What deliberately does NOT live here:** the diff-draw trigger. R35's ruling is
;;; that the EXCERPT'S PRESENCE is the signal, not the tool's name — a `bash` command
;;; that changed one file under a heredoc gets the diff card — so no `edit-card`
;;; method turns diffs on. See `%tool-result-lines` and `call-lines`, the two places
;;; that guard on `(and edit …)` and the two places R35 fixed.


(defclass read-card    (tool-result-card) ())
(defclass search-card  (tool-result-card) ())
(defclass list-card    (tool-result-card) ())
(defclass run-card     (tool-result-card) ())
(defclass compact-card (tool-result-card) ())
(defclass fetch-card   (tool-result-card) ())
(defclass generic-tool-card (tool-result-card) ())

(defmethod card-verb ((card tool-result-card) &key running)
  (verb-label (card-tool-name card) :running running))

(defmethod card-body-budget ((card tool-result-card))
  (cons 10 3))

(defmethod card-body-budget ((card read-card))  (cons 5 3))
(defmethod card-body-budget ((card list-card))  (cons 5 3))
(defmethod card-body-budget ((card run-card))   (cons 2 3))

(defmethod card-indent ((card tool-result-card) cols)
  (activity-indent cols))


(defmethod card-lines ((card tool-result-card) cols prefs)
  (%tool-result-lines (card-item card) (card-body card) cols prefs))
;; **`system (Bootstrap)` on its own line, then the text, all dim**

(defun %tool-result-lines (item body cols prefs)
  "One settled tool-result row — the reference's `TranscriptItem::ToolResult` arm,
followed step for step, because a screen comparison showed ours had folded the
reference's three rows into one:

    ▸ Ran \"cd … && python3 - <<'PY'…\" · ok · 13 lines     (header)
      P5 recorded                                        (the first line, dim)
      … +12 lines · ctrl-t                               (the seam, and the chord)

Ours put the seam ON the header and dropped the first line, so a folded row said
how much there was and nothing of what. And a ONE-line result, inlined on the
header, also printed `· 1 line` — a count for a fold with nothing to fold."
  (let* ((facts (item-facts (getf item :item-id)))
         (name (getf body :name))
         (outcome (getf body :outcome))
         (payload (or (getf body :payload) ""))
         (ms (getf facts :ms))
         (edit (or (getf facts :edit) (getf body :edit)))
         (open (getf prefs :show-tools))
         (word (outcome-name outcome))
         ;; bound HERE rather than where the header is built, because `outcome-style` below
         ;; needs it — the quiet register is what a row that went fine is drawn in
         (faint '(:dim t))
         ;; **`bad` IS THE STRUCTURE, NOT THE COLOUR.** It asks one question — did this call
         ;; come back `ok` — and it decides whether a one-line result may be inlined on the
         ;; header, whether a failed edit may draw its diff, and whether a failure with no
         ;; reason must show its body. Those are all about what there is to SHOW.
         (bad (not (string= word "ok")))
         ;; **THE COLOUR IS THE ROLE, and this row spelled the mapping a SECOND time.**
         ;;
         ;; It said `(if bad '(:fg :red) faint)`, so **every outcome that was not `ok` was a
         ;; failure** — and the operator, looking at a job that had just been moved to the
         ;; background, asked *"why on earth backgrounding message is in red"*.
         ;;
         ;; They were right to ask. `%outcome-style` is the one place this mapping lives and
         ;; it has said otherwise all along: abstained, denied and **backgrounded** are
         ;; `Attention`, not `Failure`, because a process that is still working must not be
         ;; drawn as something to retry. `call-lines` was already fixed to use it and its own
         ;; comment warns that *"it used to be spelled again here, and the two spellings
         ;; disagreed about `not_run` and about backgrounded"* — the second spelling was
         ;; **this row**, one function away, and it was still there.
         ;;
         ;; The reference's `display_outcome` (`app.rs:13973`) has `Backgrounded` as its own
         ;; variant for exactly this reason: *"not `Failed`, which would put a retry in front
         ;; of the operator for a command that is still working, and not `Ok`, which would
         ;; read as a finish."*
         ;;
         ;; **`ok` stays dim and does not become `Success`.** The settled row is quiet when
         ;; the call went fine — the whole row is faint on the screen — and a green line
         ;; under every command in the transcript is a colour that says nothing. Only a row
         ;; that wants the reader's eye takes a colour, and `%outcome-style` says which
         ;; colour that is. An outcome this build does not know is `pending`, the same
         ;; fallback `call-lines` uses, rather than the red this row used to guess.
         (outcome-style (if (string= word "ok")
                            faint
                            (or (%outcome-style outcome) +role-pending+)))
         (mark (if open "▾" "▸"))
         ;; **A ROW MAY STATE ITS OWN VERB AND SUBJECT** (R24), and it is here rather
         ;; than in a second renderer because the derivation below is a DEFAULT and not
         ;; a rule: a tool row's verb comes from the tool's name and its subject from
         ;; the `Assistant` row that proposed the call — and a call nobody proposed has
         ;; neither. A compaction is one: the daemon runs it, no row proposed it, and
         ;; what belongs on the headline is its numbers. Both fields are optional, and
         ;; every other tool result takes exactly the path it took before.
         (verb (%tool-row-verb body))
         (subject (%tool-row-subject body))
         (decision (getf facts :decision))
         ;; Sanitised FIRST and filtered second, the reference's order
         ;; (app.rs:9712) — a payload's bytes are the command's, not this
         ;; terminal's (`%without-control`) — and then the envelope lines, which
         ;; are addressed to the model, are not output.
         (rows (%tool-payload-rows body))
         (n (length rows))
         (ind (activity-indent cols))
         (w (max 20 (- cols ind)))
         (size-style (if (>= n +big-output-lines+) '(:bold t) faint))
         (shown-word (%outcome-word word))
         (took (if (numberp ms) (format nil " · ~a" (duration ms)) ""))
         ;; **WHO ASKED FOR THIS CALL** — `nil` for the model's own, which is every row
         ;; that has no `origin` at all. See `%call-origin-said`.
         (asked (let ((said (%call-origin-said body)))
                  (if (and said (plusp (length said)))
                      (format nil " · by ~a" said)
                      "")))
         ;; the tail is measured FIRST and the subject is given what is left
         (tail-cols (+ 3 (string-width shown-word) (string-width took)
                       (string-width asked)
                       3 6 (length (format nil "~d" n))))
         (room (%subject-room w mark verb tail-cols))
         ;; **THE IMAGE PATH IS A LINK** (R55), computed from the subject BEFORE it is shortened —
         ;; so an elided `…/shots/chart.png` still opens the file it names rather than a path with
         ;; an ellipsis in it.
         ;;
         ;; **`image-path-link` REFUSES MORE THAN IT ACCEPTS**, and each refusal is a rule rather than
         ;; caution: not a picture by its extension, not absolute after resolution, or not a file
         ;; that exists — each renders as plain text, because a link that does nothing when clicked
         ;; is worse than no link, having told the reader it was clickable.
         (link (image-path-link subject))
         (subject (%shorten-subject subject room))
         ;; **the actor's segment is APPENDED, not always present**, so a row the model
         ;; proposed has the same SEGMENTS in the same order as it had before this field
         ;; existed — not merely the same text.
         (head (append (list (cons mark outcome-style)
                             (cons (format nil " ~a " verb) faint)
                             ;; the link rides the subject's own segment; `nil` when there is none,
                             ;; and `put-segments` strips it before the style is interned
                             (if link (cons subject (list :link link)) (cons subject nil)))
                       (when (plusp (length asked)) (list (cons asked faint)))
                       (list (cons (format nil " · ~a" shown-word) outcome-style)
                             (cons took faint))))
         (head-width (%segs-width head))
         (why (%outcome-why outcome))
         (out nil))
    (labels ((emit (line) (push line out))
             (dim-line (text)
               (list (cons "  " faint)
                     (cons (truncate-to-width (or text "") (max 4 (- w 2))) faint)))
             (decision-lines ()
               ;; the approval this call was gated by, in the dim register —
               ;; `%decision-card-lines`, the ONE spelling the live card draws too
               (dolist (l (%decision-card-lines decision w :open open :rows rows
                                                :lead "  "))
                 (emit l))))
      ;; A result of ONE line goes on the header — one row where the folded form
      ;; is two, and the second carried the count and a chord for a fold with
      ;; nothing to fold. Not for an edit with an excerpt: that draws its diff.
      (let ((inline (and (not bad) (= n 1) (null edit)
                         (let ((l (%strip-gutter (first rows))))
                           (and (plusp (length l))
                                (<= (+ head-width 3 (string-width l)) w)
                                l)))))
        (when inline
          (emit (append head (list (cons " · " faint) (cons inline nil))))
          (decision-lines)
          (return-from %tool-result-lines (nreverse out))))
      ;; the count, Strong once the output is big enough to be worth a fold. No
      ;; `· ctrl-t` here: the chord belongs on the seam row below, which exists
      ;; exactly when something is hidden.
      (emit (%truncate-segs
             (append head (list (cons (format nil " · ~d line~:p" n) size-style)))
             w))
      ;; The reason, on its own wrapping line, in the outcome's role: the first
      ;; sentence always, the rest with ctrl-t — a refusal's reason is a DOCUMENT
      ;; addressed to the model, and printing it whole "throws up on the chat".
      ;; When the payload says the same line it is not said twice.
      (let* ((why-folded nil))
        (when why
          (let* ((first (string-trim " " (%first-line why)))
                 (echoed (and (>= (length first) 40)
                              (some (lambda (l) (search first l)) rows)))
                 (shown (if (and open (not echoed))
                            why
                            (let ((gist (%first-sentence why)))
                              (setf why-folded (< (length gist) (length why)))
                              gist))))
            (dolist (l (wrap-segments (list (cons shown nil)) (max 4 (- w 2))))
              (emit (cons (cons "  " outcome-style)
                          (mapcar (lambda (seg) (cons (car seg) outcome-style)) l))))))
        (decision-lines)
        ;; a file edit draws its DIFF, not the tool's prose: folded keeps the
        ;; first hunk's opening rows, open shows it whole
        ;; **THE EXCERPT'S PRESENCE IS THE SIGNAL, NOT THE TOOL'S NAME.**
        ;;
        ;; This read `(member <verb-kind> '(:edit :write))` and the guard was wrong by exactly one
        ;; caller: a `bash` command that edits a file. The operator: *"why im not show normal diff
        ;; card"*, and then *"right and i want diff card for python edits you all love so much"*.
        ;;
        ;; **letibot already attaches the diff for that case and says so in words** —
        ;; `bash.rs` builds a `FileEdit` when the command changed exactly one file, with the note
        ;; *"this command changed `<path>` — the diff beside it was detected afterwards, not made
        ;; by `edit`"*. So the daemon sent an excerpt, the row under the note promised a diff
        ;; *beside* it, and this line threw it away because the tool was called `bash`.
        ;;
        ;; **And that is R35's own sentence, one layer up.** `%write-targets`' docstring has it:
        ;; *a write made through the `write`/`edit` tool and a write made by a script the gate read
        ;; out of a heredoc body are the SAME FACT — this action writes this file — and a card that
        ;; drew them from two code paths would drift into two shapes for one fact.* The two code
        ;; paths were here, and the drift was that one of them drew nothing at all.
        ;;
        ;; `bad` is kept, and it is a different question from the tool's name: a call that failed
        ;; has its own row above saying so, and the run that carries this excerpt succeeded.
        (when (and edit (not bad))
          (let* ((rows (edit-lines edit (- w 2) :folded nil
                                   :subject subject
                                   :split (string= (or (getf prefs :diff) "unified") "split")))
                 (keep (if open (length rows) (min 8 (length rows))))
                 (hidden (- (length rows) keep)))
            (dolist (l (subseq rows 0 keep))
              (emit (cons (cons "  " nil) l)))
            (when (plusp hidden)
              (emit (list (cons (format nil "  … +~d diff rows · /config unfolds it" hidden)
                                faint)))))
          (return-from %tool-result-lines (nreverse out)))
        ;; Folded shows the first line, which is where a tool puts what it did,
        ;; then the seam: `… +N lines`, a separator row and not a sentence — it is
        ;; not content, it is where content was taken out — and the chord goes on
        ;; it, where there is something for it to do. Open, or a failure with no
        ;; reason printed above it, shows the body up to the budget.
        ;;
        ;; **FOLDED, OPEN, AND A WINDOW INTO IT.** Three states and not two, and the
        ;; third is what makes the rest of a long result reachable: the fold alone
        ;; raises the BUDGET, and a budget is not an offset — a 418 KB log was
        ;; readable to its fortieth line however many times the chord was pressed.
        ;;
        ;; The window is the reference's (app.rs:10828-10893): `shown` includes the
        ;; seam rows, the body gives up one for a seam that is present and one more
        ;; for the one above when the reader has paged past the top, and `below`
        ;; decides whether there is more. Every seam says which key does what NOW —
        ;; the chord opens the view, the arrows move inside it, esc closes it —
        ;; because a row that named only the chord was the row that could not be read
        ;; past its head.
        (let* ((window (payload-view-for item))
               (page (if window (min window (max 0 (1- n))) 0))
               ;; **THE WINDOW IS THE ROW'S OWN LENGTH, NOT THE FOLD'S** (R40). This read
               ;; `(or open …)`, so a window that was open on a row whose conversation was not
               ;; unfolded drew ONE body line and paged one line per keypress — and the only way
               ;; to give one result its rest was to unfold every result in the session, which is
               ;; exactly what made `ctrl-t` a wall. `window` is first for that reason: the
               ;; reader asked for THIS row's rest, and the fold's state is a different question
               ;; about a different scope.
               (shown (if (or window open (and bad (null why)))
                          +body-lines-budget+ 2))
               (above (plusp page))
               (body-rows (max 1 (- shown 1 (if above 1 0))))
               (end (min n (+ page body-rows)))
               (below (< end n)))
          (when above
            (emit (list (cons (format nil "  ↑ ~d more lines above · ↑ scrolls up" page)
                              faint))))
          (dolist (l (subseq rows page end)) (emit (dim-line l)))
          (cond
            (below
             (emit (list (cons (format nil "  … +~d lines · ~a" (- n end)
                                       (cond
                                         ;; the window is open on THIS row: the keys are the
                                         ;; window's own
                                         (window "↓ pages down · esc closes")
                                         ;; **the chord, on the row it acts on**, and the verb
                                         ;; everywhere else. **The newest long row names the verb
                                         ;; that acts on it; every other row names the setting that
                                         ;; unfolds the wall** — `/t` opens ONE row's window now, and
                                         ;; the conversation-wide unfold is `/config`'s `tools` row.
                                         ((newest-payload-row-p item) "/t opens it")
                                         ;; **the WALL's home, not a key** — every other long row is
                                         ;; unfolded by the `tools` row in `/config` (the setting
                                         ;; `/t` used to toggle), so that is what the seam names.
                                         (t "/config unfolds it")))
                               faint))))
            ;; The end of the payload, SAID — so "no more" cannot be confused with
            ;; "the arrow stopped working", which is the other half of a seam's job.
            (window
             (emit (list (cons "  … end of output · esc closes" faint))))
            ;; the payload was short enough to show whole, but the REASON was
            ;; cut — so the affordance has to be here
            (why-folded
             (emit (list (cons "  … the rest of the reason · /config unfolds it" faint)))))))
      ;; `item-lines` steps the whole row in by the activity indent
      (nreverse out))))


(defparameter +call-origin-cols+ 32
  "How many columns of an actor's identity a row will carry.

**Bounded because the row's arithmetic depends on it** (R25): the actor goes in the TAIL,
which is measured first so the subject is given what is left. An unbounded identity would
be a row whose subject is squeezed by a name, and the name is the daemon's to keep short —
`human:dead` is ten columns. Thirty-two is `human:` plus a long one, disclosed with an `…`
like every other cut in this tree.")

(defun %call-origin-said (body)
  "WHO this row's call came from, as the daemon named them, or NIL for the MODEL's own call.

**R24 part two, decision 1**, and the field it renders is letibot `dd81999`.
`TranscriptItem::ToolResult` carries `origin: Option<CallOrigin>`, and the wire spells it:

    {\"origin\": {\"operator\": {\"who\": \"human:dead\"}}}

**ABSENCE is a fact with a meaning, not a hole**, and that is the half a head gets wrong.
`None` is *the model proposed this call* — which is also what every row written before the
field existed means, since a missing key for an `Option` reads as `None` and that is why
the field needs no version bump. So this answering NIL must leave the row drawing exactly
what it drew before the field was thought of; it does not mean *nobody asked*.

**A shape this build cannot read still NAMES somebody.** The field exists so that a call
the model did not make is not drawn as the model's, so an `origin` this build does not
recognise renders its own key rather than falling back to silence — *a wrong colour is
worse than none*, but silence here is not no colour, it is the model's colour.

`who` is the gate's own identity (`human:dead`, the same string `verdict_by` records), so
the row and the adjudication for one call name the actor the same way. It is drawn
VERBATIM: a head that stripped the `human:` scope would be recomposing a name the daemon
owned."
  (let ((origin (getf body :origin)))
    (cond
      ((null origin) nil)
      ;; an origin named as a word — the shape `SystemOrigin` uses on a system row, kept
      ;; so one function reads both and a tool row never mis-draws one as the model's
      ((stringp origin) (truncate-to-width origin +call-origin-cols+))
      ((consp origin)
       ;; **the VALUE is guarded before `getf` reads it**: an origin this build does not know
       ;; may carry a word rather than a plist (`{"flowy": "seat-3"}`), and a reader that
       ;; signalled on it would take the head down over a fact it was only trying to NAME.
       (let* ((kind (loop for (k v) on origin by #'cddr return k))
              (val (and kind (getf origin kind)))
              (who (and (consp val) (getf val :who))))
         (truncate-to-width
          (if (and (stringp who) (plusp (length who)))
              who
              (string-downcase (string kind)))
          +call-origin-cols+)))
      (t nil))))

(defun %tool-row-verb (body)
  "The word a tool result draws first — its own, or the tool's name through `verb-label`.
One function, because R37's marker names the same acts the rows do."
  (or (getf body :verb) (verb-label (getf body :name))))

(defun %tool-row-subject (body)
  "What a tool result draws after its verb — the row's own subject, the call's target, or the
call id when there is nothing better. Extracted with the verb so the marker and the row cannot
disagree about what a hidden row was."
  (or (getf body :subject)
      (call-target-of (getf body :call-id))
      (format nil "(~a)" (getf body :call-id))))

