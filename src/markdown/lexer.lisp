;;;; lexer — the lexer: text to blocks
;;;;
;;;; Split out of `markdown.lisp`, which was one 1144-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

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

(defun %fence-at (line)
  "(CHAR RUN INFO INDENT) when LINE carries a fence marker, else NIL.

Two things the old `%fence-open` did not carry, and both of them are bugs it
could not have avoided without carrying them:

  · the fence CHARACTER. `~~~` is a fence opener too (markdown.rs:722-726) and
    backticks were all we looked for, so a `~~~` block rendered as prose with
    its tildes on screen;
  · the RUN LENGTH. A closing fence must be at least as long as the opener
    (markdown.rs:819-834), which is how a model QUOTES a fence when it is
    teaching — ```` ```` ```` around ``` ``` ```. Any run of three closed
    anything here, so the demonstration was cut in half and the rest spilled out
    as prose.

The INDENT is kept for the same reason the reference keeps it: a fence opened
inside a list item is indented, and that indent belongs to the container, not to
the code (`stripping_a_content_column_does_not_eat_content`).

A 4-space-indented fence is still a fence — a documented CommonMark deviation on
both sides, for the same reason: a model writing inside a list item indents its
fence and means a fence."
  (let ((i (%first-non-space line))
        (n (length line)))
    (when (< i n)
      (let ((c (char line i)))
        (when (member c '(#\` #\~))
          (let ((run (loop for k from i below n
                           while (char= (char line k) c) count t)))
            (when (>= run 3)
              (list c run (string-trim " " (subseq line (+ i run))) i))))))))

(defun %fence-open (line)
  "The info string when LINE opens a fence, else NIL. The block-start test's
view of `%fence-at`; the lexer wants the whole thing."
  (let ((f (%fence-at line)))
    (and f (third f))))

(defun %fence-closes-p (line ch run)
  "Does LINE close a fence opened with RUN of CH?

At least as long, the same character, and NOTHING after it — which is also what
keeps a line that merely *ends* in backticks (box art) content rather than a
closing fence."
  (let ((f (%fence-at line)))
    (and f (char= (first f) ch) (>= (second f) run)
         (zerop (length (third f))))))

(defun %setext-underline (line)
  "1 for a `===` underline, 2 for a `---` one, else NIL — markdown.rs:950,993-994.

`Title` over `====` is a heading, and ours joined the `====` into the paragraph
and drew it; `----` was caught by `%rule-p` and drew a rule under a paragraph
that was the heading. Only ever asked with a paragraph already open, so a bare
`---` is still a thematic break."
  (let ((t0 (string-trim '(#\space #\tab) line)))
    (and (plusp (length t0))
         (cond ((every (lambda (c) (char= c #\=)) t0) 1)
               ((every (lambda (c) (char= c #\-)) t0) 2)
               (t nil)))))

(defparameter +indented-code-columns+ 4
  "Columns of indent that make a line a code block rather than prose
(markdown.rs:971,1161-1177).")

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

(defun %indented-code-p (line)
  "Is LINE the start of an indented code block?

Ours trimmed the indent away and rendered the line as a paragraph, so the code
was not merely uncoloured — it was MANGLED, its indentation being most of what
code written without a fence has.

A list item is excluded where the reference would not exclude it: this head
renders nested list items by their indent (a deliberate extra over the
reference's flat lists), and reading a top-level `    - sub` as code would take
that away."
  (let ((i (%first-non-space line)))
    (and (>= i +indented-code-columns+)
         (< i (length line))
         (not (%list-item-of line)))))

(defun %quote-of (line)
  "The text after the `>` when LINE is a quote line."
  (let ((i (%first-non-space line)))
    (when (and (< i (length line)) (char= (char line i) #\>))
      (let ((body (subseq line (1+ i))))
        (if (and (plusp (length body)) (char= (char body 0) #\space))
            (subseq body 1)
            body)))))

(defun %table-row-p (line)
  "A GFM pipe row: has a pipe and is not a DELIMITER row.

The delimiter test is the precise one, and it has to be: the previous guard
rejected any line made only of spaces, dashes, colons and pipes, so a table whose
HEADER has empty cells — `| | |` — never opened, and neither did the `|---|---|`
under it, because a delimiter row only counts when the table is already open. The
whole table then fell through to the paragraph path and rendered as one line of
raw pipes joined by spaces. Measured on the operator's screen in the `rano`
window: *\"the three commits that are now on GitHub\"* and its three-row table came
out as `| | | |---|---| | 2cd1dae | …`.

A table with an empty header is what a model writes when the first column is a
list rather than a name, so this is not a corner: it is a table."
  (and (plusp (length line))
       (find #\| line)
       (not (%delimiter-line-p line))))

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

(defun %task-marker-stripped (text)
  "`[x] done` → `done` — a task-list item does not keep its checkbox
(markdown.rs:1050-1052,1242-1244). Ours drew `· [x] done`, which is a marker on
the screen with a bullet already beside it."
  (if (and (>= (length text) 4)
           (char= (char text 0) #\[)
           (member (char text 1) '(#\space #\x #\X))
           (char= (char text 2) #\])
           (char= (char text 3) #\space))
      (subseq text 4)
      text))

(defun %strip-indent (line n)
  "Up to N leading spaces off LINE, and no more.

The container's indent is the container's; anything past it is the code's own.
The reference makes the same distinction and keeps a test for it
(`stripping_a_content_column_does_not_eat_content`, markdown.rs:2699)."
  (let ((k (min n (or (position #\space line :test-not #'char=) (length line)))))
    (subseq line k)))

(defun %fence-block (lines i ch run info indent)
  "The `:code` block a fence at I opens, and the index after it.

Returns (BLOCK . NEXT). The close must be at least as long as the opener and of
the same character; the opener's INDENT comes off every body line."
  (let ((body nil)
        (closed nil)
        (n (length lines))
        (k (1+ i)))
    (loop while (< k n)
          do (if (%fence-closes-p (aref lines k) ch run)
                 (progn (setf closed t) (incf k) (return))
                 (progn (push (%strip-indent (aref lines k) indent) body)
                        (incf k))))
    (cons (list :kind :code :lang info :lines (nreverse body) :closed closed)
          k)))

(defun %quote-lines-of (block)
  "One inner block of a quote as the plain lines the quote shows.

A quote's content is lexed like any other text and then FLATTENED back to lines
— which is what makes a table inside a quote read as `1 2` rather than
`| 1 | 2 |`, and a list inside one keep its words and lose its markers
(`a_table_inside_a_quote_keeps_its_cells`, markdown.rs:2230). A code block is
never flattened; the caller lifts it out whole."
  (case (getf block :kind)
    (:paragraph (getf block :lines))
    (:heading (list (getf block :text)))
    (:list (mapcar (lambda (it) (getf it :text)) (getf block :items)))
    (:table (mapcar (lambda (r) (format nil "~{~a~^ ~}" r))
                    (cons (getf block :head) (getf block :rows))))
    (:quote (getf block :lines))
    (:rule (list "───"))
    (t nil)))

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
                   ;; a fence, to a close AT LEAST AS LONG as its opener, or the
                   ;; end of the text
                   ((%fence-at l)
                    (destructuring-bind (ch run info indent) (%fence-at l)
                      (let ((r (%fence-block lines i ch run info indent)))
                        (push (car r) blocks)
                        (setf i (cdr r)))))
                   ;; **a fence ON a list marker's line is a code box**, not item
                   ;; text (markdown.rs:781-784). `- ```rust` is how a model
                   ;; writes code inside a bullet, and it read as a bullet with
                   ;; backticks and the word `rust` in the middle of it.
                   ((and (%list-item-of l) (%fence-at (getf (%list-item-of l) :text)))
                    (let* ((item (%list-item-of l))
                           (content (- (length l) (length (getf item :text)))))
                      (destructuring-bind (ch run info fi) (%fence-at (getf item :text))
                        (declare (ignore fi))
                        (let ((r (%fence-block lines i ch run info content)))
                          (push (car r) blocks)
                          (setf i (cdr r))))))
                   ;; **an INDENTED code block**, which ours trimmed into prose
                   ((%indented-code-p l)
                    (let ((body nil))
                      (loop while (and (more i)
                                       (or (%blank-p (line i)) (%indented-code-p (line i))))
                            do (push (%strip-indent (line i) +indented-code-columns+) body)
                               (incf i))
                      ;; trailing blanks belong to the text, not to the block
                      (loop while (and body (%blank-p (first body)))
                            do (pop body) (decf i))
                      (push (list :kind :code :lang "" :lines (nreverse body) :closed t)
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
                   ;; **A quote is a CONTAINER**, not a run of lines. Its content
                   ;; is lexed like any other text, a fence in it is lifted out
                   ;; as a real code box (markdown.rs:713-747 — `%fence-at` never
                   ;; fired on a `>` line, so the backticks stayed as characters),
                   ;; and everything else is flattened back to the lines the rail
                   ;; carries — which is how a table in a quote loses its pipes.
                   ((%quote-of l)
                    (let ((body nil))
                      (loop while (and (more i) (%quote-of (line i)))
                            do (push (%quote-of (line i)) body) (incf i))
                      (let ((inner (markdown-blocks
                                    (format nil "~{~a~^~%~}" (nreverse body))))
                            (pending nil))
                        (flet ((flush-quote ()
                                 (when pending
                                   (push (list :kind :quote :lines (nreverse pending))
                                         blocks)
                                   (setf pending nil))))
                          (dolist (b inner)
                            (if (eq (getf b :kind) :code)
                                (progn (flush-quote) (push b blocks))
                                (dolist (ql (%quote-lines-of b)) (push ql pending))))
                          (flush-quote)))))
                   ;; **A list survives a blank line**: a loose list is ONE block
                   ;; (markdown.rs:2016-2040), and closing it at the blank made a
                   ;; six-point answer twice as tall as the reference's — N
                   ;; blocks and N−1 blank rows between them.
                   ((%list-item-of l)
                    (let ((items nil))
                      (loop while (more i)
                            do (let ((item (%list-item-of (line i))))
                                 (cond
                                   (item
                                    (setf (getf item :text)
                                          (%task-marker-stripped (getf item :text)))
                                    (push item items) (incf i))
                                   ;; blank lines, kept only when another item
                                   ;; follows them
                                   ;; …and only for another item of the SAME
                                   ;; kind: a bullet list under an ordered one
                                   ;; is a second list, and merging them
                                   ;; renumbers the bullets into it.
                                   ((and items (%blank-p (line i))
                                         (let ((k i))
                                           (loop while (and (more k) (%blank-p (line k)))
                                                 do (incf k))
                                           (let ((next (and (more k) (%list-item-of (line k)))))
                                             (and next
                                                  (eq (not (getf next :ordered))
                                                      (not (getf (first items) :ordered)))))))
                                    (loop while (and (more i) (%blank-p (line i)))
                                          do (incf i)))
                                   ((and items (not (%blank-p (line i)))
                                         (not (%fence-at (line i)))
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
                      (setf items (nreverse items))
                      (push (list :kind :list :items items
                                  ;; the list's own first written number, which
                                  ;; is what the rendering counts UP from
                                  :start (or (loop for it in items
                                                   when (getf it :ordered)
                                                     return (getf it :number))
                                             1))
                            blocks)))
                   ;; a paragraph: lines until a blank, a block start, or the
                   ;; `====` that turns everything above it into a heading
                   (t
                    (let ((body nil)
                          (level nil))
                      (loop while (more i)
                            do (cond
                                 ((and body (%setext-underline (line i)))
                                  (setf level (%setext-underline (line i)))
                                  (incf i)
                                  (return))
                                 ((and body (%block-start-p (line i))) (return))
                                 (t (push (string-trim " " (line i)) body) (incf i))))
                      (setf body (nreverse body))
                      (push (if level
                                (list :kind :heading :level level
                                      :text (format nil "~{~a~^ ~}" body))
                                (list :kind :paragraph :lines body))
                            blocks)))))))
    (nreverse blocks)))

