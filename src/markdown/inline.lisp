;;;; inline — inline markup: emphasis, code spans, links
;;;;
;;;; Split out of `markdown.lisp`, which was one 1144-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; -------------------------------------------------------------- inline ;;;

(defun %style-kind (style)
  "Which of the reference's `InlineStyle`s a spec is, for the nesting rule."
  (cond ((and (getf style :bold) (getf style :italic)) :bold-italic)
        ((getf style :bold) :bold)
        ((getf style :italic) :italic)
        (t :other)))

(defun %nest-style (outer inner)
  "The style of text INSIDE a container: `InlineStyle::nest`.

Bold inside italic is italic inside bold; beyond that the container being
entered decides, and there is no deeper level — a terminal has no more attributes
to spend, and a font that stacks them is unreadable. So a code span inside bold is
cyan and NOT bold, which is what the reference draws."
  (let ((o (%style-kind outer)) (i (%style-kind inner)))
    (cond ((eq o :bold-italic) outer)
          ((and (eq o :bold) (eq i :italic)) '(:bold t :italic t))
          ((and (eq o :italic) (eq i :bold)) '(:bold t :italic t))
          (t inner))))

(defun %delim-at-p (text i delim)
  (declare (type simple-string text delim) (type fixnum i))
  (let ((n (length delim)))
    (and (<= (+ i n) (length text))
         (string= delim text :start2 i :end2 (+ i n)))))

(defun %find-closing (text start delim)
  "The index of the closing DELIM at or after START, or NIL. A closer must not
follow whitespace (`a * b` is arithmetic) and must close something (`**` alone is
two asterisks).

**A RUN longer than the delimiter closes at its END.** `**bold *and italic***`
ends in three asterisks: the outer `**` is the last two of them and the third
belongs to the italic that opened inside. Taking the run's START instead left the
odd marker on the screen — and a marker on the screen is the one failure this
whole surface exists to remove (markdown.rs:1947-1956)."
  (declare (type simple-string text delim) (type fixnum start))
  (let ((len (length delim))
        (dc (schar delim 0))
        (n (length text)))
    (declare (type fixnum len n))
    (loop for j of-type fixnum from start below n
          when (and (%delim-at-p text j delim)
                    (> j start)
                    (not (member (schar text (1- j)) '(#\space #\tab))))
            return (let ((run (loop for k of-type fixnum from j below n
                                    while (char= (schar text k) dc) count t)))
                     (declare (type fixnum run))
                     (if (> run len) (+ j (- run len)) j)))))

(defun %autolink-at (text i)
  "The URL inside an autolink starting at I, or NIL — `<https://x>` and
`<a@b.c>` (markdown.rs:599-608).

A bare URL is what a model writes when it means a bare URL, and `<` and `>` were
ordinary characters here, so the brackets reached the screen. Recognised by
shape and nothing else: no whitespace inside, and either a scheme or an `@`."
  (declare (type simple-string text) (type fixnum i))
  (let ((close (position #\> text :start i)))
    (when (and close (> close (1+ i)))
      (let ((inner (subseq text (1+ i) close)))
        (and (not (find-if (lambda (c) (member c '(#\space #\tab #\<))) inner))
             (or (search "://" inner) (find #\@ inner))
             inner)))))

(defun %word-char-p (c)
  (or (alphanumericp c) (char= c #\_)))

(defun %code-span-text (inner)
  "A code span's text, by the GFM rule: ONE space comes off each end when the
span both begins and ends with one and is not all spaces — `` ` a ` `` is `a`, and
`` `┃ ` `` keeps its trailing space. Measured: the reference painted `┃ ` with the
space inside the cyan, and a `string-trim` here had eaten it."
  (let ((n (length inner)))
    (if (and (>= n 2)
             (char= (char inner 0) #\space)
             (char= (char inner (1- n)) #\space)
             (find-if (lambda (c) (char/= c #\space)) inner))
        (subseq inner 1 (1- n))
        inner)))

(defun inline-spans (text &optional (style nil))
  "Inline markdown to segments, with the markers gone and the styles nested.

`code`, **bold**, __bold__, *italic*, _italic_, ~~struck~~ (dim, never `9m`:
half the terminals in use do not carry it), [text](url) as its text (this head has
no pointer, so a destination is noise), and a backslash escapes the character
after it. An underscore only opens or closes at a word boundary, so `snake_case`
stays what it is.

TEXT is coerced to a `simple-string` once, at the entry, and the scan is typed
on it: this is markdown's per-character loop, and under (speed 3) every `char`
and every index compare in it raised a note. Default safety — the coercion is
the check, and the text is wire-shaped (an assistant row's prose)."
  (let* ((text (if (simple-string-p text) text (coerce text 'simple-string)))
         (segs nil)
         (buf (make-string-output-stream))
         (n (length text))
         (i 0))
    (declare (type simple-string text) (type fixnum n i))
    (labels ((flush ()
               (let ((s (get-output-stream-string buf)))
                 (when (plusp (length s))
                   (push (cons s style) segs))))
             (nested (inner-text inner-style)
               (flush)
               (dolist (seg (inline-spans inner-text (%nest-style style inner-style)))
                 (push seg segs)))
             (try-span (delim inner-style &key word-boundary)
               ;; a delimited span at I, or NIL when it does not close
               (let* ((len (length delim))
                      (end (and (or (not word-boundary)
                                    (zerop i)
                                    (not (%word-char-p (char text (1- i)))))
                                (< (+ i len) n)
                                (not (member (char text (+ i len)) '(#\space #\tab)))
                                (%find-closing text (+ i len) delim))))
                 (when (and end
                            (or (not word-boundary)
                                (>= (+ end len) n)
                                (not (%word-char-p (char text (+ end len))))))
                   (nested (subseq text (+ i len) end) inner-style)
                   (setf i (+ end len))
                   t))))
      (loop while (< i n)
            do (let ((c (char text i)))
                 (cond
                   ;; an escape: the next character, literally
                   ((and (char= c #\\) (< (1+ i) n)
                         (not (alphanumericp (char text (1+ i)))))
                    (write-char (char text (1+ i)) buf) (incf i 2))
                   ;; a code span: no nesting inside, and a backtick that never
                   ;; closes is a backtick
                   ((char= c #\`)
                    (let* ((ticks (loop for j from i below n
                                        while (char= (char text j) #\`) count t))
                           (delim (make-string ticks :initial-element #\`))
                           (end (search delim text :start2 (+ i ticks))))
                      (if end
                          (progn (flush)
                                 (push (cons (%code-span-text (subseq text (+ i ticks) end))
                                             (%nest-style style +md-code+))
                                       segs)
                                 (setf i (+ end ticks)))
                          (progn (write-string delim buf) (incf i ticks)))))
                   ;; `***both***` FIRST, or the `**` rule takes two of the
                   ;; three and leaves the odd asterisk on the screen. The most
                   ;; common emphasis shape after `**`, and the reference reads
                   ;; it as one BoldItalic run (markdown.rs:1947-1956).
                   ((and (char= c #\*) (%delim-at-p text i "***")
                         (try-span "***" '(:bold t :italic t))))
                   ((and (char= c #\_) (%delim-at-p text i "___")
                         (try-span "___" '(:bold t :italic t) :word-boundary t)))
                   ((and (char= c #\*) (%delim-at-p text i "**")
                         (try-span "**" '(:bold t))))
                   ((and (char= c #\_) (%delim-at-p text i "__")
                         (try-span "__" '(:bold t) :word-boundary t)))
                   ((and (char= c #\~) (%delim-at-p text i "~~")
                         (try-span "~~" '(:dim t))))
                   ((and (char= c #\*) (try-span "*" '(:italic t))))
                   ((and (char= c #\_) (try-span "_" '(:italic t) :word-boundary t)))
                   ;; an autolink is its URL, brackets gone
                   ((and (char= c #\<)
                         (let ((url (%autolink-at text i)))
                           (when url
                             (flush)
                             (push (cons url style) segs)
                             (setf i (+ i 2 (length url)))
                             t))))
                   ;; an image is its alt text: `![alt](u)` → `alt`. The `!` was
                   ;; literal and then the link rule fired, so it read `!alt`.
                   ((and (char= c #\!) (< (1+ i) n) (char= (char text (1+ i)) #\[)
                         (let* ((close (position #\] text :start i))
                                (paren (and close (< (1+ close) n)
                                            (char= (char text (1+ close)) #\()
                                            (position #\) text :start close))))
                           (when paren
                             (nested (subseq text (+ i 2) close) style)
                             (setf i (1+ paren))
                             t))))
                   ;; a link is its text
                   ((and (char= c #\[)
                         (let* ((close (position #\] text :start i))
                                (paren (and close (< (1+ close) n)
                                            (char= (char text (1+ close)) #\()
                                            (position #\) text :start close))))
                           (when paren
                             (nested (subseq text (1+ i) close) style)
                             (setf i (1+ paren))
                             t))))
                   (t (write-char c buf) (incf i)))))
      (flush))
    (nreverse segs)))

(defun %inline-spans (text style)
  "The old name, kept for the callers that have it."
  (inline-spans text style))

