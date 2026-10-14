;;;; **The operator-ask card** — the question a todo row is waiting on a PERSON for, whole.
;;;;
;;;; `TodoNeed::Operator` carries the question the model put to the operator and the options it offered,
;;;; and a row draws it as `waits on you` (`%todo-needs-said`) — which is a sentence a reader meets while
;;;; scanning a plan and not the question itself. The resident line above the composer says the head is
;;;; waiting on somebody (R91); this is the card it names, where the question is readable whole.
;;;;
;;;; **IT IS A READER AND NOT AN ANSWER**, deliberately: the rows are the model's own question and its
;;;; own options, and nothing here sends anything. How an answer travels back to the daemon is its own
;;;; piece of work — the wire's reply shape is not this card's business, and a card that guessed at it
;;;; would be a key that looked like it answered and did not.

(in-package #:leticl)

(defvar *operator-card-open* nil
  "T while the operator-ask card is up.

**THE READER'S STATE AND NOTHING ELSE'S**: what the card SHOWS comes off the board every frame, so a
question the model takes back takes the card with it — the same rule the resident line keeps, and the
one letibot `c224585`'s test pins for its own card. There is nothing here to go stale.")

(defun operator-card-p (head)
  "Is there a card to draw? T only while the reader has it open AND there is still a question.

**The second half is the retraction**: `waiting-on-you-line` answers NIL when no open row waits on a
person any more, and this asks the same question of the same board — so a card left open over a
question that has been taken back stops being drawn rather than lying."
  (declare (ignore head))
  (and *operator-card-open* (find-if (lambda (r)
                                      (and (equal (getf r :status) "open")
                                           (%operator-ask r)))
                                    *operator-todos*)))

(defun operator-card-lines (head cols)
  "The question whole, its options under it, and the way out.

**THE MODEL'S OWN WORDS, and the row's**: the question is what the model wrote, the options are the ones
it offered, and the row's content is what the work IS — because a reader deciding an answer needs both
*what is stuck* and *what they are being asked*, and neither is rewritten here."
  (declare (ignore head))
  (let* ((row (find-if (lambda (r)
                         (and (equal (getf r :status) "open")
                              (%operator-ask r)))
                       *operator-todos*))
         (ask (and row (%operator-ask row)))
         (wrap (lambda (s)
                 (let ((room (max 20 (- cols 6))))
                   (if (> (length (or s "")) room)
                       (format nil "~a…" (subseq s 0 room))
                       (or s ""))))))
    (when row
      (append
       (list (list (cons "the model is waiting on you" '(:bold t))))
       (list (list (cons (format nil "  ~a" (funcall wrap (getf row :content))) nil)))
       (list (list (cons "" nil)))
       (list (list (cons (format nil "  ~a" (funcall wrap (getf ask :question))) nil)))
       ;; **THE OPTIONS ARE THE MODEL'S LIST, in its own order** — a reader picking one needs to see
       ;; them as they were offered, and a menu this head re-sorted would be a different question.
       (loop for o in (getf ask :options)
             collect (list (cons (format nil "    · ~a" (funcall wrap (if (stringp o) o (format nil "~a" o)))) '(:dim t))))
       (list (list (cons "" nil)))
       (list (list (cons "  esc puts this away — the model is still waiting" '(:dim t))))))))

(defun %operator-card-key (head key type)
  "The card's keys: Esc puts it away, and nothing else is claimed.

**ESC HERE DOES NOT ANSWER**, and that is the whole of what this card decides: the question belongs to
the model, an answer to the daemon, and a key that looked like an answer would be worse than no key —
which is the same rule the decision card's Esc keeps for a permission."
  (declare (ignore type))
  (when (eq (getf key :type) :esc)
    (setf *operator-card-open* nil
          (head-dirty head) t)
    t))
