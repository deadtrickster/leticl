;;;; **The reseat card, and the strip it leaves behind** (letibot R89, `crates/tui/src/app/reseat.rs`
;;;; and `ui/cards/reseat.rs`).
;;;;
;;;; A session's message 0 is FIXED when it is created (protocol §14), so a build that has since
;;;; changed the system instructions, the tool schemas or the seat hands that session a prompt it will
;;;; never speak — and nothing said so on any screen. The daemon detects it by hashing the frozen half
;;;; of the prefix and sending `prefix_stale`; the remedy is the reader's own (`/reseat`).
;;;;
;;;; **THE OPERATOR'S OWN ASK IS THE WHOLE SHAPE OF THIS**: *"since it is important id suggest to show
;;;; me \"select\" with one option - reseat and abstain and then when on abstain keep reseat select
;;;; open. this way i keep reseat in mind because it stares at me yet can continue at my risk."*

(in-package #:leticl)

(defvar *reseat-said* nil
  "The daemon's `prefix_stale` sentence while this session's prompt is stale — NIL when it is not.

**ONLY THE DAEMON SETS AND CLEARS IT.** `prefix_stale` says it; `prefix_current` (the sentence was
cleared — a reseat, or any fork onto the seated prompt) and `reseated` take it down, and the latter is
broadcast, so **a reseat chosen on one head clears the card on every one of them**. A `Hello` forgets
it too, because the daemon says `prefix_stale` again on every attach while it is still true — which is
what makes the card survive a reattach and a daemon restart without this head remembering anything of
its own.

A `defvar` and not a head slot: a slot is a struct change and a struct change is a restart, and this is
state the daemon owns anyway.")

(defvar *reseat-card-open* nil
  "T while the CARD is up rather than the STRIP.

**ABSTAINING NEVER DISMISSES IT** — that is the operator's ask, quoted above. `Not now`, Esc and typing
into the composer all PIN it rather than closing it, and `alt-p` opens the card again. So there are two
states and one of them is always on the screen while the prompt is stale: the card, or the line that
says the prompt is stale and offers the card.")

(defun reseat-card-p (head)
  "Is there a card to draw?

 T only while the daemon says the prompt is stale, the reader has the card open, **and the composer is
 EMPTY** — the reference's own rule, and the reason the guard is here rather than at the door: *typing
 into an empty composer does the same and the key goes to the composer, so the card never stands between
 the operator and the line they started*. A reader mid-sentence gets the STRIP, which takes no keys."
  (and *reseat-said* *reseat-card-open*
       (zerop (length (composer-buffer (head-composer head))))))

(defun reseat-strip-line (head cols)
  "The pinned line: `PROMPT IS STALE … · alt-p shows the card` — or NIL when there is nothing to say.

**It stays until the DAEMON says otherwise**, which is the whole point of pinning: a card that
dismissed itself on one keystroke would be a warning the reader can lose by accident, and the operator
asked for the opposite — *it stares at me*.

Its keys are named the way this head names keys everywhere else, so the bar's own vocabulary and these
words are the same vocabulary."
  (declare (ignore head))
  (when (and *reseat-said* (not *reseat-card-open*))
    (format nil "PROMPT IS STALE — ~a · alt-p shows the card"
            (let ((one (first (uiop:split-string *reseat-said* :separator '(#\newline)))))
              (if (> (length one) (max 20 (- cols 40)))
                  (subseq one 0 (max 20 (- cols 40)))
                  one)))))

(defun reseat-card-lines (head cols)
  "The card, to the reference's shape: the daemon's sentence SHORT, and the two ways forward.

**THE ROWS ARE THE REFERENCE'S OWN WORDS**, because they are sentences the operator reads under
pressure and a paraphrase would be a second place for the meaning to live. The FIRST row is
`/reseat summarise` when the daemon has said the conversation no longer fits verbatim — the operator
once pasted the card still offering `alt-r reseats now` under the refusal that said it could not.

**The whole of the daemon's sentence is one `tab` away**, not on the card: the card is the remedy, and
the explanation is for whoever asks. What the card keeps is the FIRST sentence, which is what changed."
  (declare (ignore head))
  (let* ((one (or (first (uiop:split-string (or *reseat-said* "") :separator '(#\newline))) ""))
         (short (if (> (length one) (max 30 (- cols 8)))
                    (subseq one 0 (max 30 (- cols 8)))
                    one))
         (summarise (search "summar" (string-downcase (or *reseat-said* "")))))
    (list
     (list (cons "the prompt this session was seated on is stale" '(:bold t)))
     (list (cons short '(:dim t)))
     ;; **THE FIRST ROW, WHICH IS THE ONE ENTER TAKES**
     (list (cons "▸  1  " nil)
           (cons (if summarise
                     "/reseat summarise — the conversation no longer fits onto the prompt verbatim"
                     "/reseat — carry the conversation onto the current prompt")
                 '(:bold t)))
     ;; **AND THE ABSTAIN, WHICH PINS RATHER THAN CLOSES**
     (list (cons "   2  " nil)
           (cons "Not now — continue on the old prompt (at my risk)" nil)))))

(defun reseat-note (said)
  "The daemon has said a `prefix_stale` sentence (or NIL for its clearing).

 **It takes no HEAD, because the daemon owns this state and nothing else about it is the head's**: the
 reader's half is `*reseat-card-open*`, and the composer guard is in `reseat-card-p`, where the head is.
 The card OPENS here — a warning that arrived minimized would be one the reader has to go looking for,
 and the operator's ask was the opposite."
  (setf *reseat-said* said
        *reseat-card-open* (and said t))
  said)

(defun reseat-answer (head index)
  "Take row INDEX of the open card. T when it was taken.

**The rows are ACTS, not a daemon's ask**: index 0 sends `/reseat` (with `summarise` when the card was
drawn for that case) and the card stands down, because the daemon will answer either way — `reseated`
on every head, or `prefix_current` if the reseat cleared the sentence. Index 1 pins it."
  (cond
    ((= index 0)
     (setf *reseat-card-open* nil)
     (%command head (if (search "summar" (string-downcase (or *reseat-said* "")))
                        "reseat summarise"
                        "reseat"))
     t)
    ((= index 1)
     ;; **ABSTAINING PINS**: the card becomes the strip, and `alt-p` brings it back.
     (setf *reseat-card-open* nil
           (head-dirty head) t)
     (say head "continuing on the stale prompt — alt-p shows the card again")
     t)
    (t nil)))

(defun %reseat-card-key (head key type)
  "The open card's keys: the rows by digit, Enter takes the first, Esc pins, and nothing else.

**Esc is `Not now` and not a dismissal** — the operator's ask is that abstaining *keep reseat select
open*, so the card is reachable again from the strip with `alt-p`."
  (declare (ignore type))
  (let ((ch (and (eq (getf key :type) :char) (getf key :ch))))
    (cond
      ((and ch (digit-char-p ch))
       (reseat-answer head (1- (digit-char-p ch))))
      ((eq (getf key :type) :enter) (reseat-answer head 0))
      ((eq (getf key :type) :esc) (reseat-answer head 1))
      (t nil))))
