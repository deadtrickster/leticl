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

(defun look-string (spec)
  "SPEC written as a LOOK line `parse-look` reads back — the INVERSE, and it must stay one.

 **ONE SPELLING, CHECKED BY ROUND-TRIP.** A template a reader edits and a theme this head reads are the
 same grammar, so a test asserts that parsing this back gives the very spec it was printed from — for
 every default, which is the only way a printer can be kept honest about a grammar it does not own."
  (let ((words nil))
    (loop for (k v) on spec by #'cddr do
      (case k
        (:fg (push (format nil "fg:~a" (%color-word v)) words))
        (:bg (push (format nil "bg:~a" (%color-word v)) words))
        (t (push (string-downcase (symbol-name k)) words))))
    (if words (format nil "~{~a~^ ~}" (nreverse words)) "plain")))

(defun %color-word (value)
  "VALUE as the colour word `parse-look` reads: a slot name, `#rrggbb`, or `cube:N` — the three forms
 `%theme-color` accepts, which are `%color-sgr`'s own."
  (typecase value
    (keyword (string-downcase (symbol-name value)))
    (integer (format nil "cube:~d" value))
    (cons (format nil "#~{~2,'0x~}" value))
    (t (format nil "~a" value))))

(defun %theme-directory ()
  "The `themes/` directory BESIDE this head's own head.toml.

 **BESIDE THIS HEAD'S CONFIG AND NOT LETIBOT'S**, which is the decision the sweep's batch D named: a
 reader's existing `~/.config/letibot/themes/` is deliberately NOT read, because a theme names ROLES this
 head draws and a file written for the other head's roles would half-apply — which is worse than not
 applying at all."
  (merge-pathnames "themes/" (uiop:pathname-directory-pathname (default-prefs-path))))

(defun read-theme (name &optional (dir (%theme-directory)))
  "NAME's overrides as `(values PAIRS NOTES)` — or `(values nil nil)` when there is no such file.

 **A MISSING FILE IS NOT A NOTE**: a reader who has never made a `themes/` directory should not be told
 about it on every start, and the reference's own acceptance test writes the theme it paints.

 The lines are read by `%parse-prefs`, the SAME reader head.toml uses — one file format and one reader,
 so a theme cannot grow a grammar the preferences do not have."
  (let ((path (and name (plusp (length name)) (merge-pathnames (format nil "~a.toml" name) dir))))
    (if (and path (uiop:file-exists-p path))
        (let ((pairs nil) (notes nil))
          (dolist (line (%parse-prefs (uiop:read-file-string path)))
            (when (eq (first line) :pair)
              (destructuring-bind (key value) (rest line)
                (cond
                  ((not (uiop:string-prefix-p "color." key))
                   (push (format nil "~a: `~a` is not a theme key" path key) notes))
                  (t
                   (let ((role (theme-role-of (subseq key 6))))
                     (cond
                       ((null role)
                        (push (format nil "~a: `~a` is not a role" path (subseq key 6)) notes))
                       (t
                        (multiple-value-bind (spec bad) (parse-look value)
                          (if bad
                              (push (format nil "~a: ~a: `~a` is not a colour or an attribute"
                                            path key bad)
                                    notes)
                              (setf pairs (append pairs (list (cons role spec))))))))))))))
          (values pairs notes))
        (values nil nil))))

(defun theme-looks (name colors)
  "The role overrides a head runs with: the theme file's lines, then HEAD.TOML'S OWN — which win.

 **THE ORDER IS THE REFERENCE'S** (letibot `d7288a8`): a named theme is a whole SET chosen at once, and a
 `color.ROLE` line beside it is one entry the reader disagreed with afterwards. The reverse order would
 make the file a head reads on EVERY start lose to the one it reads once.

 `COLORS` is what `load-prefs` already parsed (it names what it cannot read); this adds the file's own
 lines and its notes to them. A NIL NAME — the common case — reads nothing at all."
  (multiple-value-bind (from-file notes) (read-theme name)
    ;; **BOTH SIDES ARE `(ROLE . SPEC)` PAIRS AND `*role-looks*` IS A PLIST**, which is the join this has to
    ;; make: a list of conses appended to a plist is a MALFORMED plist, and `getf` on one answers `nil` for
    ;; every role past the first — a theme that reads as nothing at all.
    ;;
    ;; **HEAD.TOML'S LINES GO FIRST BECAUSE `getf` TAKES THE FIRST MATCH.** Writing the append the other way
    ;; round reads identically and gives the theme file the win, which is the opposite of the rule above —
    ;; and the kind of inversion that survives review because both spellings look right.
    (values (append (loop for (r . s) in colors append (list r s))
                    (loop for (r . s) in from-file append (list r s)))
            notes)))

(defun theme-template ()
  "The roles a theme may set, one line per role, with the look each DEFAULT draws — what a reader starts
 a file from, and what a `--theme-template` flag prints.

 **THE DEFAULTS COME THROUGH `role-look` WITH NO THEME IN PLACE**, so the template cannot print a look
 the head would not draw; and it is the one place the file's names and the keywords are both visible,
 which is what makes it a template rather than a list."
  (let ((*role-looks* nil))
    (format nil "~{~a~%~}"
            (mapcar (lambda (pair)
                      (format nil "color.~a = ~s" (cdr pair)
                              (look-string (role-look (car pair)))))
                    +theme-roles+))))
