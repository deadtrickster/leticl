;;;; overlays.lisp — the cards that are not the decision card: the operator-call draft, a todo, a diagnostic, the secret ask
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ----------------------------------------------------- the secret card ;;;

(defun op-call-card-lines (head cols)
  "The operator-call card (R24 part two): which tool, and exactly what its two keys do.

    running a tool as your act
      tool    NAME                          (or: type one — the names the door gives)
      enter   asks the daemon to admit this call as your act, and nothing runs
              until it says the call was admitted
      esc     cancels, and asks for nothing

**It draws the door's names.** This card is the only thing on the screen that knows what
the daemon will accept, and the operator is one keypress away from asking for a call that
would be refused by name. A list of its own here would be the same drift as a list held in
this head — which is why the example above is `NAME` and not a tool: nothing under `src/`
knows a door's name, and a test asserts exactly that.

**And it is the composer's card**: the argument is typed in the box below, so there is a
`tool` field rather than a prompt, and the two key rows are the whole instruction."
  (let* ((w (max 20 cols))
         (door (head-run-tools (head-settings head)))
         (name (getf *op-call-draft* :name))
         (indent (make-string 10 :initial-element #\space)))
    (flet ((row (key text)
             (cons (list (cons (format nil "  ~8a" key) '(:dim t))
                         (cons (car text) nil))
                   (mapcar (lambda (l) (list (cons indent nil) (cons l '(:dim t))))
                           (cdr text)))))
      (append
       (list (list (cons "running a tool as your act" '(:bold t))))
       (list (list (cons "  tool    " '(:dim t))
                   (cons (or name (format nil "type one — ~{~a~^, ~}" door))
                         '(:fg :bright-white))))
       (row "enter" (wrap-text
                      (format nil "asks the daemon to admit this call as your act~@[ (one of ~{~a~^, ~})~]; nothing runs until it says so"
                              (and (null name) door))
                      (max 8 (- w 10))))
       (row "esc" (wrap-text "cancels, and asks for nothing" (max 8 (- w 10))))))))

(defun todo-card-lines (head cols)
  "The new-todo card: the two fields, which one is being typed, and the three keys.

    adding a todo item

      title    add a way to edit todos
      detail   a modal with a title and a description

      tab      moves between the fields
      enter    adds it to the session's plan, as yours
      esc      cancels, and adds nothing

**The card is the modal and the composer is the field**, which is this head's one text widget —
`op-call-card-lines` has the same shape for the same reason. The focused field is drawn from the
DRAFT's copy and the other from the composer, so the row under the cursor is never a keystroke
behind: `%todo-draft-focus` stores the one it is leaving.

**The last line says who this is for**, because that is the limitation of the whole feature and the
place the reader will look for it: an item added here is the head's, and the model does not see it.
A screen that let them believe otherwise would be the same defect class as a disclosure that
guesses."
  (let* ((w (max 20 cols))
         (field (%todo-draft-field))
         (composer (composer-buffer (head-composer head)))
         (title (if (eq field :title) composer (or (getf *todo-draft* :title) "")))
         (detail (if (eq field :detail) composer (or (getf *todo-draft* :detail) "")))
         (indent (make-string 11 :initial-element #\space)))
    (flet ((fld (name key value)
             (list (cons (format nil "  ~7a " key) '(:dim t))
                   (cons (if (plusp (length value)) value "(empty)")
                         (if (eq field name) '(:fg :bright-white) '(:dim t))))))
      (append
       (list (list (cons "adding a todo item" '(:bold t))))
       (list nil)
       (list (fld :title "title" title))
       (list (fld :detail "detail" detail))
       (list nil)
       (list (list (cons (format nil "  ~7a" "tab") '(:dim t))
                   (cons "moves between the fields" nil)))
       (list (list (cons (format nil "  ~7a" "enter") '(:dim t))
                   (cons "adds it to the session's plan, marked as yours" nil)))
       (list (list (cons (format nil "  ~7a" "esc") '(:dim t))
                   (cons "cancels, and adds nothing" nil)))
       (list nil)
       ;; **AND THE LIMITATION SAID HERE WAS FALSE.** It read *"the model does not see these — the
       ;; wire has no frame that writes a todo"*, and both halves had stopped being true: R44 landed
       ;; `ClientFrame::SetOperatorTodos`, the daemon's board is one list with two authors, and the
       ;; nag reads it — so the model is not only shown these rows, it is now nagged about them and
       ;; can answer one. A card that tells the operator their row is invisible would have them
       ;; wondering why the model kept bringing it up.
       (list (list (cons "  the model sees these and is reminded of them; it can mark one done"
                         '(:dim t))))
       (list (list (cons "  it cannot remove your row — that is yours alone, with the delete key"
                         '(:dim t))))))))

(defun %size-said (n)
  "N BYTES as a person reads it, with the unit named. Nothing for zero, which is not a
size — a zero-byte body is the *recorded and empty* fact and its own sentence says so."
  (cond ((null n) nil)
        ((>= n 1024) (format nil "~,1f KB" (/ n 1024.0)))
        (t (format nil "~d bytes" n))))

(defun diagnostic-listing-lines (diag)
  "The `/diagnostic` listing: the oracle's brief and its reply, each labelled with what it
IS and how big it is — the R11 half that had never reached a head.

**THREE states per half, and they are three different sentences.** `body: None` is *nobody
kept this* — a row written before R11 kept the exchange, or an id no adjudication has;
`Some(\"\")` is *recorded, and empty* — the gate really was shown nothing. The second is not
a rendering of the first, and a head that drew both as an empty pane would have rebuilt the
defect this file's `%advice-said` exists for, one field over.

**`total` is drawn, not derived.** `body.map(len)` cannot tell the two absences apart, and
the daemon sends the byte count precisely so a head does not have to guess it.

Lines come back UNWRAPPED: the slash pane wraps at its own width, and wrapping here too
would wrap twice — the same division `warning-listing-lines` keeps."
  (let* ((answers (getf diag :answers))
         (out nil))
    (dolist (kind +diagnostic-kinds+)
      (let ((ans (cdr (assoc kind answers :test #'string=))))
        ;; the daemon's own word for which half this is, at the head of the block
        (push (format nil "~a~@[ · ~a~]"
                      (if (string= kind "brief") "brief — what the gate was shown"
                          "reply — what the gate answered, verbatim")
                      (%size-said (getf ans :total)))
              out)
        (cond
          ;; **NOT ANSWERED YET**: the frame is out and nothing has come back. Said
          ;; rather than drawn as an absence, because the two are different facts.
          ((null (getf ans :decided))
           (push "  reading…" out))
          ;; **NOTHING KEPT IT** — `body: None`, and the sentence names both reasons
          ((null (getf ans :body))
           (push (format nil "  nobody kept this. The row predates the store keeping the ~
                             exchange, or ~a names no adjudication here."
                         (or (getf diag :request-id) "that id"))
                 out))
          ;; **RECORDED AND EMPTY** — a body that is present and is nothing
          ((zerop (length (getf ans :body)))
           (push "  recorded, and empty — this half was kept and holds nothing." out))
          (t (dolist (l (%lines-of (getf ans :body)))
               (push l out))))
        (push "" out)))
    (nreverse out)))

(defun open-diagnostic-listing (diag head)
  "Put the `/diagnostic` listing in the slash pane. T when there is one.

Fills `*slash-out*` and does NOT touch the mode — except that the CALLER opened the pane
from a keypress, which is where the mode belongs (the job overlay's rule: opened at the
keypress, saying `reading…`, rather than showing an empty screen for the answer)."
  (declare (ignore head))
  (setf *slash-out* (cons (format nil "/diagnostic ~a" (or (getf diag :request-id) ""))
                          (diagnostic-listing-lines diag)))
  t)

(defvar *prompt-away* nil
  "The prompt card is put AWAY (esc) without the request being answered or the run
ended. The request's presence and the card's visibility are TWO FACTS — the reference's
own `prompt_away` — and the difference is the window the operator's `y` fell through
(2026-10-09, measured: card away, bare line submitted, the words reached the MODEL while
the operator's own command waited and was killed at its deadline).

A `defvar` and not a head slot: pushed state, kept out of the frozen image's struct
layout.")

(defun prompt-card-lines (head cols)
  "The card for a run that is asking: the question and the two ways in. The
composer IS the field (in the open — not masked, not a secret). Enter sends
`PromptAnswer`; `!send LINE` always works (protocol 33).

**TWO CARDS, AND `reading` IS WHAT TELLS THEM APART** (the reference's `PromptReading`,
`b0ff4f8`). The asking card is drawn when the daemon READ the run and saw it blocked;
the UNREADABLE card — `reading: \"unreadable\"` — is the honest one for a run the daemon
may not look at (one process of it belongs to another uid, so `/proc/<pid>/fd/0` is
`EACCES`), and it must not borrow the asking card's headline: *your command is asking*
would be exactly the guess the design refuses — a long quiet command that is asking
nothing looks the same from here. The unreadable card says so, and that a line goes in
either way."
  (let ((req (head-prompt-req head)))
    (when (and req (not *prompt-away*))
      (let ((w (pane-width cols)))
        (if (string= (or (getf req :reading) "blocked") "unreadable")
            ;; **THE CARD THE DAEMON COULD NOT BACK WITH A READING** — one sentence for
            ;; the fact there is no reading, one for what the person can do about it
            ;; (the same thing they would have done with a card that had read the
            ;; process), the run named because the question cannot be.
            (list nil
                  (list (cons "  your command is running, and this daemon could not read it"
                              '(:bold t)))
                  nil
                  (list (cons (format nil "  run: ~a"
                                      (truncate-to-width
                                       (or (getf req :command) "")
                                       (max 8 (- w 4))))
                              '(:dim t)))
                  nil
                  (list (cons "  I cannot tell whether it is waiting for a line — part of it belongs to another user, so I may not look at what it is doing. A line you type here goes into its input either way."
                              '(:dim t)))
                  nil
                  (list (cons (format nil "  enter sends it · esc puts the card away · !send LINE also works~@[ · ~a~]"
                                      (getf req :job))
                              '(:dim t))))
            (list nil
                  (list (cons "  the command is asking" '(:bold t)))
                  nil
                  (list (cons (format nil "  ~a"
                                      (truncate-to-width (or (getf req :question) "")
                                                         (max 8 (- w 4))))
                              '(:fg :yellow)))
                  nil
                  (list (cons "  type the answer and press enter · esc puts the card away · !send LINE always works"
                              '(:dim t)))))))))

(defun secret-ask-lines (head cols)
  "The password card — the reference's `secret_lines` (app.rs:7305-7327):

    sudo wants a password — [sudo] password for dead:
    for: apt install ripgrep
    type it below (shown as dots), Enter sends it once to sudo and nowhere else; Esc refuses · 47s left

Two differences from what was on the screen before, both measured:

  · **the countdown.** `SecretAsk.deadline` (app.rs:10060) arrives on the frame
    and was folded onto `head-secret-req` and never read, so a sudo prompt about
    to time out looked exactly like one that had just arrived. It is drawn from the same
    `deadline-said` ladder the gate card uses, so the two cannot disagree about what
    a countdown looks like, and it is omitted rather than guessed when the daemon
    sent no deadline;
  · **the dots are not here.** They are drawn in the composer's own box
    (`composer-box-body`), which is where the field is; this card says what is
    being asked and for what, and never measures the text."
  (let ((req (head-secret-req head)))
    (when req
      (let* ((w (max 20 cols))
             ;; **the deadline is already on THIS head's clock.** It is converted
             ;; where the frame arrived (`wire-deadline->monotonic`), because the
             ;; wire's value is a Unix instant and this head's clock is a counter
             ;; since process start. This card subtracted one from the other and drew
             ;; the result, so its countdown read a number in the hundreds of
             ;; thousands of seconds — R13's two-clocks trap, in a second place, and
             ;; found here first.
             (time (deadline-said (getf req :deadline))))
        (append
         (list (list (cons (truncate-to-width
                            (format nil "sudo wants a password — ~a"
                                    (string-trim " " (or (getf req :prompt) "")))
                            w)
                           '(:fg :yellow))))
         (mapcar (lambda (l) (list (cons l nil)))
                 (wrap-text (format nil "for: ~a" (or (getf req :command) "")) w))
         (list (list (cons (truncate-to-width
                            (format nil "type it below (shown as dots), Enter sends it once to sudo and nowhere else; Esc refuses~@[ · ~a~]"
                                    time)
                            w)
                           '(:dim t)))))))))

