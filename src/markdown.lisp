;;;; markdown.lisp — assistant text to styled lines, to the reference's shape.
;;;;
;;;; A port of the BLOCK MODEL in crates/tui/src/markdown.rs and the renderer in
;;;; crates/tui/src/render.rs (`render_block_with`, `table_lines`, `fit_columns`,
;;;; `render_bounded`), rather than the line-at-a-time scan this file used to be.
;;;; The two differ in exactly the ways a screen comparison found:
;;;;
;;;;   · a paragraph is its LINES JOINED and wrapped to the width it is given —
;;;;     ours emitted one row per source line and never wrapped, so every long
;;;;     paragraph was CUT at the terminal's edge (measured: rows of exactly 210
;;;;     columns with no continuation, where letibot's wrapped to two);
;;;;   · inline markup is a grammar with NESTING: `**`code` in bold**` is a cyan
;;;;     code span inside a bold run, not a bold run with literal backticks;
;;;;   · a heading keeps its hashes, faint, and colours the text BY LEVEL, so
;;;;     the level survives a monochrome pipe;
;;;;   · a table's cells are runs (so `**1.6 s**` in a cell is bold), its
;;;;     columns are measured on the PAINTED text, and they give way wide-first;
;;;;   · blocks are separated by one blank row, whether or not the source had one.
;;;;
;;;; Not a full CommonMark implementation — the Rust file is equally explicit
;;;; about what it skips. Fences are highlighted as a unit, on close.
;;;;
;;;; A LINE is a list of segments; a segment is (string . style-spec) where the
;;;; spec is a plist for style-index. NIL is a blank line. The renderer interns.
;;;;
;;;; Optimisation policy (measured, 2026-09-20): `inline-spans` — the
;;;; per-character scan — is typed; the lexer's classifiers look at one character
;;;; before they copy a line. Everything else here runs once per BLOCK and is left
;;;; at the default policy on purpose: under (speed 3) `render-table`,
;;;; `fit-columns`, `markdown-blocks` and `lang-for-fence` raise notes about
;;;; generic arithmetic and `nth` on short lists, and a 3 KB text renders in
;;;; 0.34 ms with 315 KB consed — the cost is the strings the design makes, not
;;;; the arithmetic between them.

(in-package #:leticl)

(defun appendf-attr (style key value)
  (append style (list key value)))

;;; --------------------------------------------------------------- roles ;;;
;;;
;;; The reference's palette (crates/ui/src/style.rs), as style specs.

(defparameter +md-heading+ '(:bold t :fg :cyan) "Role::Heading — `#`.")
(defparameter +md-subheading+ '(:bold t :fg :blue) "Role::Subheading — `##`.")
(defparameter +md-strong+ '(:bold t) "Role::Strong — `###` and deeper.")
(defparameter +md-faint+ '(:dim t) "Role::Faint — hashes, bullets, rails, rules.")
(defparameter +md-code+ '(:fg :cyan) "InlineStyle::Code.")

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
two asterisks)."
  (declare (type simple-string text delim) (type fixnum start))
  (loop for j of-type fixnum from start below (length text)
        when (and (%delim-at-p text j delim)
                  (> j start)
                  (not (member (schar text (1- j)) '(#\space #\tab))))
          return j))

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
                   ((and (char= c #\*) (%delim-at-p text i "**")
                         (try-span "**" '(:bold t))))
                   ((and (char= c #\_) (%delim-at-p text i "__")
                         (try-span "__" '(:bold t) :word-boundary t)))
                   ((and (char= c #\~) (%delim-at-p text i "~~")
                         (try-span "~~" '(:dim t))))
                   ((and (char= c #\*) (try-span "*" '(:italic t))))
                   ((and (char= c #\_) (try-span "_" '(:italic t) :word-boundary t)))
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

;;; -------------------------------------------------------------- fences ;;;

(defun lang-for-fence (name)
  "A fenced block's language, as the highlighter's id. 0 = none.

`hl_detect` takes a PATH (rano's extension table), while a fence carries a NAME
(`lisp`, `rust`, `sh`), so the name is dressed as a filename. The mapping is
deliberately small and honest: a name not here, or a shim that is not built,
gives 0 and the fence renders plain — which is what an unhighlighted terminal
sees anyway and what `hl-available-p` is there to make cheap."
  (let ((ext (cdr (assoc (string-downcase (string-trim " " name))
                         '(("lisp" . "lisp") ("cl" . "lisp") ("common-lisp" . "lisp")
                           ("emacs-lisp" . "el") ("elisp" . "el")
                           ("rust" . "rs") ("rs" . "rs")
                           ("python" . "py") ("py" . "py")
                           ("sh" . "sh") ("shell" . "sh") ("bash" . "sh")
                           ("zsh" . "sh") ("console" . "sh")
                           ("c" . "c") ("h" . "h")
                           ("cpp" . "cpp") ("c++" . "cpp") ("cc" . "cpp")
                           ("json" . "json") ("toml" . "toml") ("yaml" . "yaml")
                           ("yml" . "yaml") ("sql" . "sql")
                           ("js" . "js") ("javascript" . "js")
                           ("ts" . "ts") ("typescript" . "ts")
                           ("go" . "go") ("java" . "java") ("ruby" . "rb")
                           ("html" . "html") ("css" . "css")
                           ("md" . "md") ("markdown" . "md"))
                         :test #'string=))))
    ;; 0, never NIL: `lang-for`'s contract is "0 = none", and a caller that
    ;; arithmetic's the answer (`plusp`) must not get a type error for a fence
    ;; whose language nobody knows. Measured — `(plusp nil)` is how this line
    ;; first failed.
    (if ext (lang-for (format nil "fence.~a" ext)) 0)))

(defun highlight-fence (raw-lines lang)
  "RAW-LINES (strings, oldest first) as styled segments, highlighted as LANG.

Falls back to one dim segment per line when the shim is absent or does not know
the language, so a fence is never WORSE than it was before highlighting
existed: it used to render dim, and a plain `nil` style would be a regression
in a terminal with no syntax colour."
  (let* ((source (format nil "~{~a~^~%~}" raw-lines))
         (id (lang-for-fence lang))
         (styled (if (plusp id)
                     (highlight-lines source id)
                     nil)))
    (if styled
        styled
        (mapcar (lambda (l) (list (cons l '(:dim t))))
                raw-lines))))

;;; --------------------------------------------------------------- lexer ;;;
;;;
;;; Text to blocks. A block is a plist with a `:kind`:
;;;
;;;   (:kind :heading :level N :text S)
;;;   (:kind :paragraph :lines (S…))
;;;   (:kind :code :lang S :lines (S…) :closed BOOL)
;;;   (:kind :list :items ((:ordered BOOL :number N :indent N :text S)…))
;;;   (:kind :quote :lines (S…))
;;;   (:kind :table :head (S…) :align (KW…) :rows ((S…)…))
;;;   (:kind :rule)

(defun %blank-p (line)
  (zerop (length (string-trim '(#\space #\tab) line))))

(defun %first-non-space (line)
  "The index of LINE's first character that is not a space, or its length.

The lexer's guard: every classifier below used to begin with a `string-left-trim`
or a `subseq`, so every line of every paragraph was copied five times to learn
that it is prose. Each classifier now looks at ONE character first and copies
only when that character says it might match."
  (declare (type string line))
  (or (position #\space line :test-not #'char=) (length line)))

(defun %fence-open (line)
  "The info string when LINE opens a fence, else NIL."
  (let ((i (%first-non-space line)))
    (when (and (< i (length line)) (char= (char line i) #\`))
      (let ((t0 (subseq line i)))
        (when (and (>= (length t0) 3) (string= (subseq t0 0 3) "```"))
          (string-trim " `" (subseq t0 3)))))))

(defun %fence-close-p (line)
  (let ((t0 (string-trim " " line)))
    (and (>= (length t0) 3) (every (lambda (c) (char= c #\`)) t0))))

(defun %heading-of (line)
  "(LEVEL . TEXT) when LINE is an ATX heading."
  (let* ((level (or (position-if (lambda (c) (char/= c #\#)) line) (length line))))
    (when (and (<= 1 level 6) (> (length line) level)
               (char= (char line level) #\space))
      (cons level (string-trim " #" (subseq line level))))))

(defun %rule-p (line)
  "`---`, `***`, `___`, with or without spaces between."
  (let ((i (%first-non-space line)))
    (and (< i (length line))
         (member (char line i) '(#\- #\* #\_))
         (let ((t0 (remove #\space (string-trim " " line))))
           (and (>= (length t0) 3)
                (every (lambda (c) (char= c (char t0 0))) t0))))))

(defun %list-item-of (line)
  "(:ordered BOOL :number N :indent N :text S) when LINE starts a list item."
  (let* ((indent (or (position-if (lambda (c) (char/= c #\space)) line) 0))
         (c0 (and (< indent (length line)) (char line indent)))
         ;; the copy only when the first character can start an item
         (rest (if (and c0 (or (member c0 '(#\- #\* #\+)) (digit-char-p c0)))
                   (subseq line indent)
                   "")))
    (cond
      ((and (>= (length rest) 2)
            (member (char rest 0) '(#\- #\* #\+))
            (char= (char rest 1) #\space))
       (list :ordered nil :number nil :indent indent :text (subseq rest 2)))
      ((and (plusp (length rest)) (digit-char-p (char rest 0)))
       (let ((end (position-if-not #'digit-char-p rest)))
         (when (and end (< (1+ end) (length rest))
                    (member (char rest end) '(#\. #\)))
                    (char= (char rest (1+ end)) #\space))
           (list :ordered t :number (parse-integer rest :end end)
                 :indent indent :text (subseq rest (+ end 2))))))
      (t nil))))

(defun %quote-of (line)
  "The text after the `>` when LINE is a quote line."
  (let ((i (%first-non-space line)))
    (when (and (< i (length line)) (char= (char line i) #\>))
      (let ((body (subseq line (1+ i))))
        (if (and (plusp (length body)) (char= (char body 0) #\space))
            (subseq body 1)
            body)))))

(defun %table-row-p (line)
  "A GFM pipe row: has a pipe and is not a delimiter row (markdown.rs:476)."
  (and (plusp (length line))
       (find #\| line)
       (not (every (lambda (c) (member c '(#\space #\- #\: #\|))) line))))

(defun %delimiter-line-p (line)
  "A raw delimiter LINE: `|---|---|`. See `%delimiter-row-p`."
  (and (find #\- line) (%delimiter-row-p (split-cells line))))

(defun %delimiter-row-p (cells)
  "A GFM delimiter row: every cell is only `-`, `:` and spaces. It is the
table's SYNTAX, never a line of it."
  (and cells
       (every (lambda (c)
                (let ((cell (string-trim " " c)))
                  (and (plusp (length cell))
                       (every (lambda (ch) (member ch '(#\- #\:))) cell))))
              cells)))

(defun %align-of (cells)
  "What the delimiter row's colons asked for, one keyword per column."
  (mapcar (lambda (c)
            (let* ((c (string-trim " " c))
                   (l (and (plusp (length c)) (char= (char c 0) #\:)))
                   (r (and (plusp (length c)) (char= (char c (1- (length c))) #\:))))
              (cond ((and l r) :center) (r :right) (t :left))))
          cells))

(defun split-cells (line)
  "The cells of one table row, outer pipes dropped, \\| kept literal
(markdown.rs:481)."
  (let ((cells nil)
        (cur (make-string-output-stream))
        (n (length line)))
    (let ((i 0))
      (loop while (< i n)
            do (cond
                 ((and (char= (char line i) #\\) (< i (1- n)) (char= (char line (1+ i)) #\|))
                  (write-char #\| cur) (incf i 2))
                 ((char= (char line i) #\|)
                  (push (get-output-stream-string cur) cells) (incf i))
                 (t (write-char (char line i) cur) (incf i)))))
    (push (get-output-stream-string cur) cells)
    (setf cells (nreverse cells))
    (when (and cells (zerop (length (string-trim " " (first cells)))))
      (setf cells (rest cells)))
    (when (and (> (length cells) 1)
               (zerop (length (string-trim " " (first (last cells))))))
      (setf cells (butlast cells)))
    (mapcar (lambda (c) (string-trim " " c)) cells)))

(defun %block-start-p (line)
  "Does LINE start something that is not a paragraph continuation?"
  (or (%blank-p line) (%fence-open line) (%heading-of line) (%rule-p line)
      (%list-item-of line) (%quote-of line)))

(defun markdown-blocks (text)
  "TEXT to a list of blocks, in order."
  (let ((lines (coerce (uiop:split-string text :separator '(#\newline)) 'vector))
        (blocks nil)
        (i 0))
    (flet ((line (k) (aref lines k))
           (more (k) (< k (length lines))))
      (loop while (more i)
            do (let ((l (line i)))
                 (cond
                   ((%blank-p l) (incf i))
                   ;; a fence, to its close or the end of the text
                   ((%fence-open l)
                    (let ((lang (%fence-open l))
                          (body nil)
                          (closed nil))
                      (incf i)
                      (loop while (more i)
                            do (if (%fence-close-p (line i))
                                   (progn (setf closed t) (incf i) (return))
                                   (progn (push (line i) body) (incf i))))
                      (push (list :kind :code :lang lang :lines (nreverse body)
                                  :closed closed)
                            blocks)))
                   ((%heading-of l)
                    (let ((h (%heading-of l)))
                      (push (list :kind :heading :level (car h) :text (cdr h)) blocks)
                      (incf i)))
                   ;; a table is a header row over a delimiter row; a lone row of
                   ;; pipes is a paragraph with pipes in it
                   ((and (%table-row-p l) (more (1+ i)) (%delimiter-line-p (line (1+ i))))
                    (let ((head (split-cells l))
                          (align (%align-of (split-cells (line (1+ i)))))
                          (rows nil))
                      (incf i 2)
                      (loop while (and (more i) (%table-row-p (line i))
                                       (not (%block-start-p (line i))))
                            do (push (split-cells (line i)) rows) (incf i))
                      (push (list :kind :table :head head :align align
                                  :rows (nreverse rows))
                            blocks)))
                   ((%rule-p l)
                    (push (list :kind :rule) blocks) (incf i))
                   ;; a quote runs while the lines carry `>`
                   ((%quote-of l)
                    (let ((body nil))
                      (loop while (and (more i) (%quote-of (line i)))
                            do (push (%quote-of (line i)) body) (incf i))
                      (push (list :kind :quote :lines (nreverse body)) blocks)))
                   ;; a list: items until a blank line or another block. An
                   ;; indented non-item line continues the item before it.
                   ((%list-item-of l)
                    (let ((items nil))
                      (loop while (more i)
                            do (let ((item (%list-item-of (line i))))
                                 (cond
                                   (item (push item items) (incf i))
                                   ((and items (not (%blank-p (line i)))
                                         (not (%fence-open (line i)))
                                         (not (%heading-of (line i)))
                                         (not (%quote-of (line i)))
                                         (or (and (plusp (length (line i)))
                                                  (char= (char (line i) 0) #\space))
                                             (not (%rule-p (line i)))))
                                    ;; lazy continuation
                                    (setf (getf (first items) :text)
                                          (concatenate 'string (getf (first items) :text)
                                                       " " (string-trim " " (line i))))
                                    (incf i))
                                   (t (return)))))
                      (push (list :kind :list :items (nreverse items)) blocks)))
                   ;; a paragraph: lines until a blank or a block start
                   (t
                    (let ((body nil))
                      (loop while (and (more i)
                                       (or (null body) (not (%block-start-p (line i)))))
                            do (push (string-trim " " (line i)) body) (incf i))
                      (push (list :kind :paragraph :lines (nreverse body)) blocks)))))))
    (nreverse blocks)))

;;; ------------------------------------------------------------ rendering ;;;

(defun %segs-width (segs)
  (let ((w 0))
    (declare (type fixnum w))
    (dolist (s segs w) (incf w (string-width (car s))))))

(defun %truncate-segs (segs cols)
  "SEGS cut to COLS columns, style boundaries kept, with an `…` where the rest
went — `trim_to` over a painted line (`width::truncate`, width.rs:329-353).

Two things changed here together and neither works alone. The cut walked
CHARACTERS (`%truncate-width`, progress.lisp), which halves a ZWJ sequence and
turns a flag into a letter — and this is the function every card header goes
through. And it cut SILENTLY, so a header that had dropped its tail looked
exactly like one that had not.

The mark is a segment of its own, in the style of whatever was being cut when
the budget ran out, so an elision inside a bold run stays inside it. One column
is reserved for it before anything is kept, which is why the budget below is
`cols - 1`: the reference reserves the same column for the same reason."
  (if (<= (%segs-width segs) cols)
      segs
      (let ((out nil) (w 0) (room (max 0 (1- cols))) (cut-style nil))
        (dolist (seg segs)
          (let ((sw (string-width (car seg))))
            (cond ((<= (+ w sw) room) (push seg out) (incf w sw))
                  (t (let ((left (- room w)))
                       (when (plusp left)
                         (push (cons (%truncate-cells (car seg) left) (cdr seg)) out)
                         (incf w left)))
                     (setf cut-style (cdr seg))
                     (return)))))
        (when (plusp cols)
          (push (cons "…" cut-style) out))
        (nreverse out))))

(defun %pad-segs (segs width align)
  "SEGS padded to WIDTH with plain spaces, on the side ALIGN says."
  (let* ((have (%segs-width segs))
         (slack (max 0 (- width have))))
    (flet ((spaces (n) (and (plusp n) (list (cons (make-string n :initial-element #\space) nil)))))
      (case align
        (:right (append (spaces slack) segs))
        (:center (let ((left (floor slack 2)))
                   (append (spaces left) segs (spaces (- slack left)))))
        (t (append segs (spaces slack)))))))

(defun %trim-line-end (segs)
  "Trailing spaces off the last segment: they are invisible until copied, and a
painter that erases to the end of the row paints them anyway."
  (when segs
    (let* ((rev (reverse segs))
           (last (first rev))
           (text (string-right-trim " " (car last))))
      (nreverse (if (plusp (length text))
                    (cons (cons text (cdr last)) (rest rev))
                    (rest rev))))))

(defun block-title (block)
  "A one-line name for the block, for the bound's `▸ title` row."
  (ecase (getf block :kind)
    (:heading (getf block :text))
    (:paragraph (or (first (getf block :lines)) ""))
    (:code (format nil "~a · ~d lines"
                   (if (plusp (length (getf block :lang))) (getf block :lang) "code")
                   (length (getf block :lines))))
    (:list (or (getf (first (getf block :items)) :text) ""))
    (:quote (or (first (getf block :lines)) ""))
    (:table (format nil "table · ~d × ~d" (length (getf block :rows))
                    (length (getf block :head))))
    (:rule "───")))

(defun fit-columns (natural available)
  "Each column its natural width if they all fit; otherwise the wide ones give
way first.

Water-filling: every column narrower than an equal share keeps what it wants, and
the slack they leave is shared again among the rest. An equal cut instead would
take the same columns off a two-character `n` column as off a sixty-character
`status` one, and the short columns are the ones that cannot spare it. A floor of
four: narrower and a wrapped word is one letter per line, which is not a table."
  (let ((n (length natural)))
    (cond
      ((zerop n) nil)
      ((<= (reduce #'+ natural) available) (copy-list natural))
      (t
       (let ((widths (make-list n :initial-element 0))
             (settled (make-list n :initial-element nil)))
         (loop
           (let* ((taken (loop for w in widths for s in settled when s sum w))
                  (free (count nil settled)))
             (when (zerop free) (return))
             (let ((share (floor (max 0 (- available taken)) free))
                   (moved nil))
               (loop for i from 0 below n
                     when (and (not (nth i settled)) (<= (nth i natural) share))
                       do (setf (nth i widths) (nth i natural)
                                (nth i settled) t
                                moved t))
               (unless moved
                 (loop for i from 0 below n
                       unless (nth i settled)
                         do (setf (nth i widths) (max 4 share)))
                 (return)))))
         widths)))))

(defun render-table (head align rows w)
  "A pipe table at the width the terminal actually has — `render.rs::table_lines`.

Columns are as wide as their content wants until they do not fit, then the wide
ones give way first (`fit-columns`). A cell too narrow WRAPS: a row is as tall as
its tallest cell, and truncation would lose bytes the model wrote — in a table,
where the numbers are. No outer box: one faint rule under the header and a faint
`│` between columns, the weight of the quote rail and the code fence. The last
column is not padded: trailing whitespace on the screen is trailing whitespace in
a copy-paste, and the columns before it already say where it starts."
  (let* ((ncols (max 1 (length head)
                     (reduce #'max (mapcar #'length rows) :initial-value 0)))
         (cell (lambda (row i) (or (nth i row) "")))
         ;; painted once: the paint is what is measured, wrapped and padded
         (head-p (loop for i from 0 below ncols
                       collect (inline-spans (funcall cell head i) +md-strong+)))
         (rows-p (mapcar (lambda (r)
                           (loop for i from 0 below ncols
                                 collect (inline-spans (funcall cell r i) nil)))
                         rows))
         (natural (loop for i from 0 below ncols
                        collect (max 1 (%segs-width (nth i head-p))
                                     (reduce #'max (mapcar (lambda (r) (%segs-width (nth i r)))
                                                           rows-p)
                                             :initial-value 0))))
         (gaps (* 3 (max 0 (1- ncols))))
         (available (max ncols (- w gaps)))
         (widths (fit-columns natural available))
         (sep (cons " │ " +md-faint+))
         (out nil))
    (flet ((push-row (cells)
             (let* ((wrapped (loop for c in cells for wd in widths
                                   collect (or (wrap-segments c wd) (list nil))))
                    (height (reduce #'max (mapcar #'length wrapped) :initial-value 1)))
               (dotimes (k height)
                 (let ((row nil))
                   (loop for i from 0 below ncols
                         for col in wrapped
                         do (when (plusp i) (setf row (append row (list sep))))
                            (setf row (append row
                                              (%pad-segs (nth k col) (nth i widths)
                                                         (or (nth i align) :left)))))
                   (push (%trim-line-end row) out))))))
      (push-row head-p)
      (push (list (cons (format nil "~{~a~^─┼─~}"
                                (mapcar (lambda (wd) (make-string wd :initial-element #\─))
                                        widths))
                        +md-faint+))
            out)
      (dolist (r rows-p) (push-row r)))
    (nreverse out)))

(defun render-block (block w)
  "One block to segment lines at width W — `render.rs::render_block_with`."
  (let ((w (max 20 w)))
    (ecase (getf block :kind)
      ;; Coloured by level, with the hashes kept and de-emphasised: the colour
      ;; carries the level for everyone with colour, the hashes for the reader
      ;; in a monochrome pipe. Truncated, not wrapped — a heading is a label.
      (:heading
       (let* ((level (getf block :level))
              (role (case level (1 +md-heading+) (2 +md-subheading+) (t +md-strong+))))
         (list (%truncate-segs
                (append (list (cons (make-string level :initial-element #\#) +md-faint+)
                              (cons " " nil))
                        (inline-spans (getf block :text) role))
                w))))
      ;; A paragraph's source lines are one paragraph: the renderer wraps the
      ;; whole thing, so the source's newlines are a wrap the model did not mean.
      (:paragraph
       (or (wrap-segments (inline-spans (format nil "~{~a~^ ~}" (getf block :lines)) nil) w)
           (list nil)))
      ;; A boxed fence: `┌─ lang`, a faint `│ ` on every line, `└─` at the end —
      ;; the same faint frame as the quote rail and the table rule. An UNCLOSED
      ;; fence says so: code that vanishes until the closing backticks arrive is
      ;; bad, and code whose box looks finished when it is not is worse.
      (:code
       (let ((lang (getf block :lang)))
         (append
          (list (list (cons (if (plusp (length lang)) (format nil "┌─ ~a" lang) "┌─ code")
                            +md-faint+)))
          (mapcar (lambda (l) (cons (cons "│ " +md-faint+) l))
                  (highlight-fence (getf block :lines) lang))
          (list (list (cons (if (getf block :closed) "└─" "└─ (still writing…)")
                            +md-faint+))))))
      ;; `·` faint for a bullet, which is structure and marks the indent; the
      ;; number of an ordered item is content — it is what the prose refers back
      ;; to — so it keeps the number the model WROTE and is not de-emphasised.
      ;; Continuation lines sit under the text, by the marker's COLUMNS.
      (:list
       (loop for item in (getf block :items)
             append (let* ((indent (min 8 (* 2 (floor (getf item :indent) 2))))
                           (marker (if (getf item :ordered)
                                       (format nil "~d. " (getf item :number))
                                       "· "))
                           (marker-style (if (getf item :ordered) nil +md-faint+))
                           (pad (+ indent (string-width marker)))
                           (body (or (wrap-segments (inline-spans (getf item :text) nil)
                                                    (max 4 (- w pad)))
                                     (list nil))))
                      (loop for line in body
                            for j from 0
                            collect (if (zerop j)
                                        (append (and (plusp indent)
                                                     (list (cons (make-string indent :initial-element #\space) nil)))
                                                (list (cons marker marker-style))
                                                line)
                                        (cons (cons (make-string pad :initial-element #\space) nil)
                                              line))))))
      ;; the rail, and the whole row dim
      (:quote
       (mapcar (lambda (l) (cons (cons "│ " +md-faint+)
                                 (mapcar (lambda (s) (cons (car s) (appendf-attr (cdr s) :dim t))) l)))
               (or (wrap-segments (inline-spans (format nil "~{~a~^ ~}" (getf block :lines)) nil)
                                  (max 4 (- w 2)))
                   (list nil))))
      (:table (render-table (getf block :head) (getf block :align) (getf block :rows) w))
      (:rule (list (list (cons (make-string (min w 60) :initial-element #\─) +md-faint+)))))))

(defun render-bounded (block w limit)
  "A block's lines, summarised when it exceeds LIMIT rows — `render_bounded`.

The shape is title, elision count, tail. Never a silent truncation: the count is
the disclosure, the same rule the log applies to `dropped`."
  (let ((full (render-block block w)))
    (if (or (null limit) (<= (length full) limit) (< limit 3))
        full
        (let* ((keep (- limit 2))
               (elided (- (length full) keep)))
          (append
           (list (list (cons (truncate-to-width (format nil "▸ ~a" (block-title block)) w)
                             +md-faint+))
                 (list (cons (format nil "  … ~d lines elided …" elided) +md-faint+)))
           (last full keep))))))

(defun markdown-lines (text &key (width 80) (limit nil) (base-style nil))
  "TEXT to a list of lines, each a list of (string . style-spec) segments, wrapped
to WIDTH. Blocks are separated by one blank line; a block over LIMIT rows is
bounded (`render-bounded`). BASE-STYLE is laid under every segment that has none
of its own — the reasoning pane's dim italic."
  (let ((out nil))
    (dolist (block (markdown-blocks (or text "")))
      (dolist (l (render-bounded block width limit))
        (push (if (and base-style l)
                  (mapcar (lambda (s) (cons (car s) (or (cdr s) base-style))) l)
                  l)
              out))
      (push nil out))
    ;; trailing blanks off
    (loop while (and out (null (first out))) do (pop out))
    (nreverse out)))

(defun pad-to (string width)
  (let ((w (string-width string)))
    (if (< w width)
        (concatenate 'string string (make-string (- width w) :initial-element #\space))
        string)))
