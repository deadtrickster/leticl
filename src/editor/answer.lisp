;;;; answer — matching what was typed to a decision's options, and answering it
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- keys ;;;
(defun %open-decision (head)
  (first (session-open-decisions (head-session head))))

;;; **A ROW IS ONE OF TWO SHAPES AND EVERY ACCESSOR HAS TO KNOW IT.**
;;; A `permission`'s row is a `DecisionOption` — a plist with `:label` and
;;; `:option-id` — and a `question`'s is a BARE STRING (`event.rs:530-537`,
;;; `choices: Vec<String>`, and the comment above it says why: *"the index into
;;; this list is what `QuestionAnswer::option` names, so a head must not reorder
;;; it"* — the row IS the string). Reading `:option-id` out of that string signals
;;; `SIMPLE-TYPE-ERROR: malformed property list`, MEASURED on the exact path and the
;;; prefix path both, which is why nothing below reaches into a row directly. The
;;; sibling guard `%option-kind-p` (`panes.lisp:1906-1915`) documents exactly this,
;;; and it had been applied to the CARD and not to the ladder.
;;;
;;; A plist is recognised by `consp` and not by `%plist-p`: what matters is the
;;; row's SHAPE, and a bare string is the only other thing the daemon sends.

(defun %choice-id (choice)
  "CHOICE's IDENTITY — the spelling that always works and the one a message names.

For a permission that is `:option-id`; for a question it is the row's own text,
because a question's identity IS its position in `choices` and the text is what a
person points at. `:option-id` first when a row has both, so the id stays the
spelling that resolves and a label stays for reading — the rule the ladder already
keeps (*\"the ID is the spelling that always works; a label is for reading\"*)."
  (cond ((stringp choice) choice)
        ((consp choice) (or (getf choice :option-id) (getf choice :label) ""))
        (t "")))

(defun %choice-label (choice)
  "The text a person READS: a permission's `:label`, a question's own string."
  (cond ((stringp choice) choice)
        ((consp choice) (or (getf choice :label) (getf choice :option-id) ""))
        (t "")))

(defun %choice-names-p (word choice)
  "WORD answers CHOICE by name: its ID or its LABEL, case-insensitively.

Two spellings, and the pair is deliberate — the reference matches both, and this
head's ladder was built to (`Allow Once` is what a person sees; `allow_once` is what
always resolves)."
  (or (string-equal word (%choice-id choice))
      (string-equal word (%choice-label choice))))

(defun %word-prefixes-choice-p (word choice)
  "WORD is a case-insensitive PREFIX of CHOICE's ID.

**The ID and not the label**, which is the reference's own limit and is kept here:
`Always allow` splits at its first space into the word `Always`, and letting that
prefix the LABEL would make a multi-word label resolve where the reference refuses.
The cost is one more character from an operator who typed the label, and the benefit
is that the two heads answer the same line the same way."
  (let ((text (string-downcase (%choice-id choice)))
        (w (string-downcase word)))
    (and (plusp (length w))
         (<= (length w) (length text))
         (string= w (subseq text 0 (length w))))))

(defun match-option (decision typed)
  "TYPED as an answer to DECISION. See the end of this docstring for the three values
it returns.

Three things, and each is a rule the reference learned the hard way:

  · the WORD is matched against the option id or its label, case-insensitively,
    falling back to a prefix of the option id — the ladder's option ids are long,
    and an operator who types `deny_and` means `deny_and_tell`;
  · trailing words are a GLOB on the option that writes a rule (always-allow),
    and the operator's own words on the option that promised to carry a reason
    (`deny_and_tell`) — which used to be REFUSED, so the line stayed in the
    composer and NOTHING was answered while the operator looked at their own
    sentence;
  · on any other option trailing words are refused rather than dropped: somebody
    who typed them meant them, and answering as though they had not is the answer
    they did not give.

**The prefix fallback was documented here and not implemented**, which is what
made a typed line dangerous rather than merely annoying: `allow` matched nothing,
fell through to the arm that answers the MARKED ROW, and told the operator their
ask had been answered. The safety was in the half that was not ported.

**An AMBIGUOUS prefix is refused, with the candidates named, rather than resolved
by list position.** This is a gate — it decides what the model may do — and the
live ladder is `allow_once, allow_session, allow_always`: `allow` prefixes three
options, and picking one of them by its position in a list is *an answer the
operator did not give*, which is the whole defect class this arm exists against.
The reference takes the first match; it can afford to, because its alternative
when nothing matches is to answer the marked row anyway. Here the alternative is
to decline, so declining on an ambiguity costs the operator one more character and
cannot grant something they did not name.

Returns THREE values — PICK, PICK-KIND, WHY — and the second is the whole of the fix
for a question, which is why it is a tag and not a convention:

  · `:index`  — PICK is an integer index into a question's `choices`. Only a
    question answers by position, and `QuestionAnswer::option` is that index
    (question.rs:55-65), so nothing else may be returned here;
  · `:option` — PICK is a permission's option-id STRING, the thing `make-answer`
    carries;
  · `:free`   — PICK is the operator's own words, for a question whose choices name
    none of what they mean. `QuestionAnswer::free` is *a typed answer, and a
    first-class one* (question.rs:70-73) and is the half of D10 that was
    unreachable: a question with no choices at all could be answered by nothing.

WHY is the sentence to show when the answer is NIL, so the caller names the reason
rather than printing one of two sentences."
  (when decision
    (let* ((line (string-trim " " (or typed "")))
           (sp (position #\space line))
           (word (if sp (subseq line 0 sp) line))
           (rest (if sp (string-trim " " (subseq line (1+ sp))) ""))
           (question (string= (getf decision :kind) "question"))
           (choices (if question (getf decision :choices) (getf decision :options)))
           ;; **THE WHOLE LINE IS CHECKED AS A NAME FIRST**, and it is the arm that
           ;; makes a typed-out CHOICE *a choice*. `no, carry on as it is` splits at
           ;; its first space into `no,` plus trailing words, so without this it
           ;; answered by prefix and filed the rest of the row's own text as a NOTE
           ;; — a qualification of itself.
           (whole (and question
                       (find-if (lambda (o) (string-equal line (%choice-id o))) choices)))
           (exact (unless whole
                    (find-if (lambda (o) (%choice-names-p word o)) choices)))
           (prefixed (unless (or whole exact)
                       (remove-if-not (lambda (o) (%word-prefixes-choice-p word o))
                                      choices)))
           (opt (cond (whole whole)
                      (exact exact)
                      ((= 1 (length prefixed)) (first prefixed))
                      (t nil))))
      ;; An empty or all-space word cannot match: `%submit-line` never sends one
      ;; here (the zero-length check is its first arm), and an all-space line
      ;; gives an empty word, which falls to the "names no option" arm below
      ;; rather than being special-cased.
      (cond
        ;; **A QUESTION ANSWERS WITH WHAT THE OPERATOR SAID.** There is no gate on
        ;; this path — a question decides *which way should I go*, and the answer is
        ;; attributed to a person — so a line that names no choice IS the answer, and
        ;; it goes in `QuestionAnswer::free`, *a typed answer, and a first-class one*
        ;; (question.rs:70-73). It is also the only way a question offering NO
        ;; choices can be answered at all: such a card is a headline and a blank
        ;; line, and before this the head told the operator their sentence "names no
        ;; option here".
        ;;
        ;; **And a word that prefix-matches MORE THAN ONE choice is refused rather
        ;; than sent as free text.** Free is the fallback, not the tie-break: a
        ;; fragment that half-names two rows is an answer they did not give, the
        ;; same defect class as answering the marked row, one notch quieter.
        (question
         (cond
           ((and (null opt) (> (length prefixed) 1))
            (values nil nil
                    (format nil "~s matches ~{~a~^, ~} — type more of one, or ~
                                 more than a word to answer in your own words"
                            word (mapcar #'%choice-id prefixed))))
           ((null opt) (values line :free nil))
           ;; the row it named, and anything after it as the NOTE that qualifies it:
           ;; `QuestionAnswer::note` "requires `option`" (question.rs:66-73), and this
           ;; is the one shape where both halves are legal together. A typed-out row
           ;; has nothing after it, which is why the whole-line arm comes first.
           (t (values (position opt choices :test #'equal)
                      :index
                      ;; a typed-out ROW carries no note: its trailing words are its
                      ;; own text, so the `whole` arm must not file them as a
                      ;; qualification of the thing they just spelled
                      (and (null whole) (plusp (length rest)) rest)))))
        ;; a permission: the ladder's own rules, unchanged
        ;; **`:refused` and not merely a `why`**, because the caller has two different things to
        ;; do with a line that named nothing: *it matched several* is a REFUSAL — answering the
        ;; marked row would grant an option the operator did not name — while *it matched nothing
        ;; at all* is a draft, and Enter on a card means *answer this*. Without the tag the two
        ;; are one `nil` and the caller cannot tell a refusal from a draft.
        ((and (null opt) (> (length prefixed) 1))
         (values nil :refused
                 (format nil "~s matches ~{~a~^, ~} — type more of one"
                         word (mapcar #'%choice-id prefixed))))
        ;; nothing at all matched
        ((null opt)
         (values nil nil (format nil "~s names no option here — the ask is still open"
                                 word)))
        (t
         (let ((kind (getf opt :kind))
               (id (getf opt :option-id)))
           (cond
             ((zerop (length rest)) (values id :option nil))
             ;; the option that WRITES a rule takes the glob
             ((and kind (search "allow_always" (string-downcase kind)))
              (values id :glob rest))
             ;; the option that PROMISED a reason takes the words
             ((and kind (search "reject_always" (string-downcase kind)))
              (values id :note rest))
             ;; every other option refuses them, rather than dropping them
             (t (values nil :refused
                        (format nil "~a takes no words after it — ~s is held"
                                id rest))))))))))


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
            ;; through `question-answer`, like every other question answer: the three
            ;; field names live there, and `(list :option idx)` was a second spelling
            ;; of one of them
            (%send head (make-answer-question (getf d :req-id)
                                              (question-answer :option idx)))
            (let ((option-id (getf (nth idx options) :option-id)))
              (%send head (make-answer (getf d :req-id)
                                       (or option-id (format nil "~d" idx))))))
        (setf (head-decision-sel head) 0
              (head-dirty head) t)
        t))))

