;;;; op-call — the operator-call draft
;;;;
;;;; Split out of `commands.lisp`, which was one 1784-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defvar *op-call-draft* nil
  "The operator-call composer: a plist `:name NAME`, or NIL when it is closed.

NAME is the tool this head is about to ask about, or NIL when the operator still has to
name one — which is the only difference between a door with one name and a door with
several, and it is DRAWN rather than guessed.

**A defvar and not a head slot**, for the reason every other piece of live state here is:
a struct layout change is a restart, and this has to be reachable from a push. Bound by
`with-replay-globals` all the same — not because a replay ever opens it, but because a
render reads it and a replay DOES render: a draft left open by one test would put this
card into the next replay's golden.")

(defun op-call-draft-open-p () (and *op-call-draft* t))

(defun %op-call-draft-open (head)
  "Open the operator-call composer — the `alt+r` chord, and `/run` with nothing after it.

**The tool is PREFILLED when the door has exactly one name**, so the common case is *type
the arguments and press enter* rather than *type the name and the arguments*. With several
names the composer is left empty and the card draws them, because guessing which door the
operator meant is the same failure as guessing the list.

**What was in the composer is the draft's now.** A half-typed prompt left under a card
whose Enter sends the line is the shape that costs somebody a message, and the card says
so before anything is typed.

**A picker is closed.** One field, one owner: a mode or model card left up behind this
would draw two cards and take the arrows."
  (let* ((door (head-run-tools (head-settings head)))
         (name (and door (null (cdr door)) (car door)))
         (seed (if name (format nil "~a " name) "")))
    (cond
      ((null door)
       (say head "this daemon offers no operator-call door — it has published no tool list, so there is nothing to run")
       nil)
      (t
       (setf *op-call-draft* (list :name name)
             *pick-open* nil
             (composer-buffer (head-composer head)) seed
             (composer-cursor (head-composer head)) (length seed)
             (head-dirty head) t)
       (say head (if name
                     (format nil "asking the daemon to admit `~a` as your act — one of ~{~a~^, ~}; type its arguments as JSON and press enter, and nothing runs until it says the call was admitted"
                             name door)
                     (format nil "type `NAME {…json…}` and press enter — the daemon admits one of ~{~a~^, ~} as your act, and nothing runs until it says so"
                             door)))
       t))))

(defun %op-call-draft-close (head)
  "Take the draft and its field down. The ONE place the card's state is cleared."
  (setf *op-call-draft* nil
        (composer-buffer (head-composer head)) ""
        (composer-cursor (head-composer head)) 0
        (head-dirty head) t))

(defun %op-call-draft-cancel (head)
  "Esc (or ctrl-c) in the operator-call composer: nothing was asked for.

**It says so**, which is the rule this head's chords keep: `esc` on a card the operator
opened is not a key that never arrived, and a composer that went away in silence is one
they press again to see whether the first press landed."
  (%op-call-draft-close head)
  (say head "nothing was asked for")
  t)

(defun %op-call-draft-submit (head line)
  "Enter in the operator-call composer. Two shapes, and the card says which one is live:
`{…json…}` when the card already named the tool, `NAME {…json…}` when it did not.

**The arguments are checked for BEING json and for nothing else** — the wire says the
field is json text, and a head that knew one tool takes `{\"url\": …}` would be holding
a copy of that tool's schema, which is the drift the daemon's own list exists to stop.

A refusal keeps the draft and says why, so the line can be fixed rather than retyped.

**Every ending here returns T, and that is load-bearing**: `%handle-key` treats a NIL from
this arm as *not mine* and passes the key down to `%normal-key`, whose Enter SUBMITS THE
LINE AS A PROMPT — so a refusal that returned NIL sent the operator's JSON to the model as
if they had typed it as a message. Measured: `the-composer-…`'s refusal assertion fails and
a `prompt` frame is on the wire. The key was acted on; it is claimed either way."
  (let* ((draft *op-call-draft*)
         (named (getf draft :name))
         ;; **A LEADING REPEAT OF THE NAME IS THE SAME AS ERASING IT.** The field is
         ;; prefilled `NAME ▌` when the door has one name, and an operator who leaves it
         ;; there and types the JSON after it means exactly what one who backspaces four
         ;; times means. Refusing the first spelling would be a head insisting on its own
         ;; prefill being undone before it would read the line in front of it.
         (line (if (and named (eql 0 (search named line)))
                   (string-trim '(#\space #\tab) (subseq line (length named)))
                   line))
         (space (position #\space line))
         (name (or named
                   (and space (subseq line 0 space))
                   (and (plusp (length line)) line)))
         (args (cond (named line)
                     (space (string-trim '(#\space #\tab) (subseq line (1+ space))))
                     (t ""))))
         (cond
      ((null name)
       (say head (format nil "name the tool as well — `NAME {…json…}`, and the door accepts ~{~a~^, ~}"
                         (head-run-tools (head-settings head)))))
      ((and (plusp (length args))
            (handler-case (progn (json-decode args) nil) (error () t)))
       (say head (format nil "the arguments are the tool's own JSON — as `~a {\"…\": \"…\"}` — so `~a` was not asked for"
                         name (let ((l (length args)))
                                (if (> l 40) (concatenate 'string (subseq args 0 40) "…") args)))))
      (t
       ;; **the field is cleared either way.** A refusal from this head — a call it has
       ;; no runner for — is a sentence, not something to retype in the same field
       (let ((asked (%op-call-ask head name (if (plusp (length args)) args "{}"))))
         (%op-call-draft-close head)
         asked)))
    ;; claimed, whatever it said: see the docstring's third paragraph
    t))

(defun %op-call-draft-key (head key type)
  "The keys the operator-call composer owns: Enter asks, Esc and `ctrl-c` cancel.

**Everything else is the composer's**, so the JSON can be typed, edited, pasted and
undone with the keys the operator already has — the same split the picker's card keeps.

T only for a key it took, or the field would stop taking letters."
  (case type
    (:enter (%op-call-draft-submit head (expand-pastes (composer-buffer (head-composer head)))))
    (:esc (%op-call-draft-cancel head))
    (:ctrl (and (eql (getf key :ch) #\c) (%op-call-draft-cancel head)))
    ;; **`ctrl-d` is NOT the composer's here.** On an empty field it would leave the head
    ;; with an argument half typed; on a filled one it does nothing already, because the
    ;; quit is guarded on an empty composer. Falling through keeps both.
    (t nil)))

