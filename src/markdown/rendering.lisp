;;;; rendering — blocks to segment lines, at the width they have
;;;;
;;;; Split out of `markdown.lisp`, which was one 1144-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------ rendering ;;;

(defun %segs-width (segs)
  (let ((w 0))
    (declare (type fixnum w))
    (dolist (s segs w) (incf w (string-width (car s))))))

(defun %truncate-segs (segs cols)
  "SEGS cut to COLS columns, style boundaries kept, with an `…` where the rest
went — `trim_to` over a painted line (`width::truncate`, width.rs:329-353).

Two things changed here together and neither works alone. The cut walked
CHARACTERS (a per-character truncator that lived in `progress.lisp` and is now
DELETED — one truncator, `truncate-to-width`, and this builds on its
`%truncate-cells`), which halves a ZWJ sequence and turns a flag into a letter —
and this is the function every card header goes through. And it cut SILENTLY, so a
header that had dropped its tail looked exactly like one that had not.

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
  "Trailing spaces off the END OF THE ROW: they are invisible until copied, and a
painter that erases to the end of the row paints them anyway.

The whole row, not the last segment — `row.trim_end()` (render.rs:528). A table
row whose last cell is empty ends in a padded blank and then the SEPARATOR, so
trimming one segment left `… │ ` with its trailing space on every such row. The
reference fixed exactly this."
  (let ((rev (reverse segs)))
    (loop while (and rev (zerop (length (string-right-trim " " (car (first rev))))))
          do (pop rev))
    (when rev
      (let* ((last (first rev))
             (text (string-right-trim " " (car last))))
        (nreverse (cons (cons text (cdr last)) (rest rev)))))))

(defun %runs-text (raw)
  "RAW with its inline markers consumed — `Block::title`'s `runs_text`
(markdown.rs:184-199).

A title is a NAME for a block somebody cannot see, and ours was the raw source:
a folded paragraph that opened `**The measurement**` showed its asterisks in the
one row that was supposed to stand in for the whole thing."
  (format nil "~{~a~}" (mapcar #'car (inline-spans (or raw "")))))

(defun block-title (block)
  "A one-line name for the block, for the bound's `▸ title` row."
  (ecase (getf block :kind)
    (:heading (%runs-text (getf block :text)))
    (:paragraph (%runs-text (or (first (getf block :lines)) "")))
    (:code (format nil "~a · ~d lines"
                   (or (fence-grammar-name (getf block :lang))
                       (if (plusp (length (getf block :lang))) (getf block :lang) "code"))
                   (length (getf block :lines))))
    (:list (%runs-text (or (getf (first (getf block :items)) :text) "")))
    (:quote (%runs-text (or (first (getf block :lines)) "")))
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
       (let* ((lang (getf block :lang))
              ;; **the name, or NIL for a bare fence** — a grammar we can colour, or the word
              ;; the model wrote, or nothing at all. `nil` is what the branch below turns into
              ;; the unlabelled box; it is deliberately not a third name like `code`.
              (named (or (fence-grammar-name lang)
                         (and (plusp (length lang)) lang))))
         (append
          ;; the header names the GRAMMAR that ran, not the token the model
          ;; typed: `┌─ bash` over ```sh, `┌─ rust` over ```rs. A name nobody
          ;; can colour is printed as written — naming a language we are not
          ;; colouring is honest, inventing one we are is not.
          ;;
          ;; **AND A BARE FENCE GETS NO NAME AT ALL** — just `┌─`. The operator:
          ;; *"when you render code blocks and no particular language is set … it shows the
          ;; bracket and 'code' as the highlight language - we dont need to show 'code' in
          ;; this case."* They are right, and the word fails the test the two cases above
          ;; pass: `bash` and `brainfuck` EARN their label by saying which grammar ran, and
          ;; `code` says only *this is a code block* — which the box already says, on every
          ;; row of it, in a column of its own. A label that names nothing is a label that
          ;; teaches the reader to stop reading labels.
          ;;
          ;; **This DEPARTS from letibot** (`render.rs:378`: `None => "┌─ code"`, with a test
          ;; asserting it), so it is recorded as ours and not as parity — the one divergence
          ;; a reader of both heads will see on an unlabelled block.
          (list (list (cons (if named (format nil "┌─ ~a" named) "┌─")
                            +md-faint+)))
          (mapcar (lambda (l) (cons (cons "│ " +md-faint+) l))
                  (highlight-fence (getf block :lines) lang))
          (list (list (cons (if (getf block :closed) "└─" "└─ (still writing…)")
                            +md-faint+))))))
      ;; `·` faint for a bullet, which is structure and marks the indent; the
      ;; number of an ordered item is content — it is what the prose refers back
      ;; to — so it keeps the number the model WROTE and is not de-emphasised.
      ;; Continuation lines sit under the text, by the marker's COLUMNS.
      ;; **An ordered list counts UP from its own start** (render.rs:408-414):
      ;; `1. / 1. / 1.` — very common model output — renders `1. 2. 3.`, because
      ;; the numbers are what the prose refers back to and three `1.`s refer to
      ;; nothing. Ours printed the number each item was written with.
      (:list
       (let ((n (1- (or (getf block :start) 1))))
       (loop for item in (getf block :items)
             append (let* ((indent (min 8 (* 2 (floor (getf item :indent) 2))))
                           (marker (if (getf item :ordered)
                                       (format nil "~d. " (incf n))
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
                                              line)))))))
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
           ;; `trim_to(title, w)` and THEN the mark (render.rs:631): the row may
           ;; be `w + 2`, which is the reference's own choice — the two columns
           ;; belong to the affordance and not to the title, and truncating the
           ;; whole thing took two characters of the name instead.
           (list (list (cons (format nil "▸ ~a" (truncate-to-width (block-title block) w))
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
