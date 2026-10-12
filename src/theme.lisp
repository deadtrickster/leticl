;;;; theme.lisp — a theme's LOOK strings, parsed into this head's own style specs.
;;;;
;;;; **THE PARSER IS THE WHOLE OF WHAT A THEME FILE CAN SAY.** A theme is a table of role → look, and a
;;;; look is a line of words. Everything a line can mean is here, and everything it cannot is refused by
;;;; name — because the failure mode of the other choice is a reader who believes they themed something
;;;; they did not.

(in-package #:leticl)

(defparameter +theme-roles+
  '((:faint . "faint")
    (:success . "success")
    (:pending . "pending")
    (:attention . "attention")
    (:failure . "failure")
    (:operator . "operator_block"))
  "The roles a theme may name, as `(KEYWORD . THE-NAME-THAT-STAND-IN-A-FILE)`, in template order.

 **THE TABLE IS THE CONTRACT** (letibot `d7288a8`): a line naming anything else is REFUSED BY NAME — the
 reference's own acceptance test expects exactly *``wat`` is not a role* — and a silent drop is how a
 reader comes to believe they have themed something they have not.

 The keywords are `role-look`'s own, because that is the door every draw site asks. Two names differ from
 the keyword because a person WRITES these: `operator_block` is the reference's own spelling of the
 operator's block, and `faint`/`dim` are two words for one idea — the keyword follows `Role::Faint` and
 the file follows what a person would type.")

(defparameter +theme-attributes+
  '(("bold" . :bold)
    ("dim" . :dim)
    ("italic" . :italic)
    ("underline" . :underline)
    ("reverse" . :reverse)
    ("strikethrough" . :strikethrough))
  "The attribute words, one per key `%style-sgr` draws.

 **THE LIST IS THAT FUNCTION'S OWN ARMS, and nothing else** — a word here that `%style-sgr` did not draw
 would be a theme that parsed and then painted as nothing.")

(defun theme-role-of (name)
  "The role keyword NAME means in a theme file, or NIL when it names no role — see `+theme-roles+`."
  (car (find name +theme-roles+ :key #'cdr :test #'string-equal)))

(defun %theme-color (word)
  "WORD as a colour value the style plist understands, or NIL when it is not one at all.

 **THE THREE FORMS ARE `%color-sgr`'s OWN, and that is the whole point**: a slot name (one of the sixteen
 a terminal defines), `#rrggbb`, and `cube:N` for the 256-colour cube. A parser that accepted something
 the renderer cannot draw would push the failure to paint time, where it is a frame nobody can read
 rather than a line the reader is told about."
  (cond
    ((zerop (length word)) nil)
    ((char= (char word 0) #\#)
     (when (and (= (length word) 7)
                (every (lambda (c) (digit-char-p c 16)) (subseq word 1)))
       (list (parse-integer word :start 1 :end 3 :radix 16)
             (parse-integer word :start 3 :end 5 :radix 16)
             (parse-integer word :start 5 :radix 16))))
    ((and (> (length word) 5) (string-equal (subseq word 0 5) "cube:"))
     (let ((n (ignore-errors (parse-integer word :start 5))))
       (and n (<= 0 n 255) n)))
    (t (find word *color-names* :test #'string-equal))))

(defun parse-look (text)
  "TEXT as a style plist — the reference's `Look` grammar, in this head's own vocabulary.

    `fg:NAME` `bg:NAME`         a colour: a slot name, `#rrggbb`, or `cube:N`
    `bold` `dim` `italic` `underline` `reverse` `strikethrough`
    `plain`                     the default — no attribute and no colour

 **RETURNS `(values SPEC BAD)`.** SPEC is NIL for a look this cannot read, and BAD is the ONE WORD that
 stopped it — so a caller can say WHICH part of a line was wrong rather than that the line was, which is
 the difference between a reader fixing their theme and a reader guessing at it.

 **`plain` IS A WORD AND NOT AN EMPTY LINE**, because *the default* is a thing a reader may want to say
 deliberately, and `color.x =` with nothing after it is a typo far more often than a decision. Later
 words win over earlier ones — the line reads left to right, like the escape it becomes."
  (let ((spec nil) (bad nil))
    (dolist (word (uiop:split-string text :separator '(#\space #\tab)))
      (when (plusp (length word))
        (cond
          ((string-equal word "plain") (setf spec nil))
          ((assoc word +theme-attributes+ :test #'string-equal)
           (setf spec (list* (cdr (assoc word +theme-attributes+ :test #'string-equal)) t spec)))
          ((and (> (length word) 3)
                (or (string-equal (subseq word 0 3) "fg:") (string-equal (subseq word 0 3) "bg:")))
           (let* ((background (string-equal (subseq word 0 3) "bg:"))
                  (value (%theme-color (subseq word 3))))
             (if value
                 (setf spec (list* (if background :bg :fg) value spec))
                 (setf bad word))))
          (t (setf bad word)))))
    (values (and (null bad) (%canonical-style spec)) bad)))
