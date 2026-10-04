;;;; format — the format
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------ the format ;;;

(defun %quote-value (v)
  "V as a `key = \"value\"` line's value, wrapped in quotes and escaped by NOTHING.

**Not `~s`, and the difference is a real one found by R19 part 3's round-trip test.**
`~s` escapes a `\"` as `\\\"` and a `\\` as `\\\\`; `%unquote`, which reads the file back,
strips the outer pair and unescapes neither — so a value carrying a quote or a backslash
comes back one backslash away from what went in. Harmless for `diff`, `thinking`, `tools`
and `raw_calls`, whose values come from fixed sets and are written with `~s` on purpose;
wrong for every OTHER value in the file, which is any key a person or a newer build put
there. Measured on the fixture this record keeps for it, `nearly full, and \"quoted\" — see
a|b`: `~s` round-tripped it to `nearly full, and \\\"quoted\\\" — see a|b`, and a membership
test on it missed — silently, which is the failure this whole part exists to stop.

What the file gets instead is the TOML spelling a person would write by hand: a quoted
value with the quotes only at the ends, which `%unquote` reads back exactly."
  (format nil "~c~a~c" #\" v #\"))

(defun %unquote (v)
  "Strip the quotes a value may carry, from either kind of quote."
  (let ((s (string-trim " " v)))
    (if (and (>= (length s) 2)
             (member (char s 0) '(#\" #\'))
             (char= (char s (1- (length s))) (char s 0)))
        (subseq s 1 (1- (length s)))
        s)))

(defun %parse-prefs (text)
  "TEXT to a list of lines, each `(:pair key value)` or `(:other raw)`.

A blank line, a comment and a `[section]` header are all `:other` — kept, in
order, so a write can put them back where they were. A line with no `=` is also
somebody else's.

A text ending in a newline splits into one MORE element than it has lines, the
last being empty; that trailing element is dropped, because keeping it means
every save appends a blank line and the file grows on each change — which is the
same defect as duplicating a key, one line at a time."
  (let ((raw-lines (uiop:split-string text :separator '(#\newline))))
    (when (and raw-lines (zerop (length (car (last raw-lines)))))
      (setf raw-lines (butlast raw-lines)))
    (loop for raw in raw-lines
          for l = (string-trim '(#\space #\tab #\return) raw)
          collect (cond ((or (zerop (length l))
                             (char= (char l 0) #\#)
                             (char= (char l 0) #\[))
                         (list :other raw))
                        (t (let ((eq (position #\= l)))
                             (if eq
                                 (list :pair (string-trim " " (subseq l 0 eq))
                                       (%unquote (subseq l (1+ eq))))
                                 (list :other raw))))))))

(defun %bool-value (v)
  "T, NIL, or :unknown for a string that is neither."
  (cond ((member v '("true" "yes" "on") :test #'string=) t)
        ((member v '("false" "no" "off") :test #'string=) nil)
        (t :unknown)))

