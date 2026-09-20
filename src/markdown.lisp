;;;; markdown.lisp — assistant text to styled lines. A compact port of the
;;;; shapes crates/tui/src/markdown.rs renders: headings, fenced code, quotes,
;;;; lists, GFM pipe tables, and the inline spans a code assistant actually
;;;; meets (bold, italic, inline code). Not a full CommonMark implementation —
;;;; the Rust file is equally explicit about what it skips.
;;;;
;;;; A LINE is a list of segments; a segment is (string . style-spec) where the
;;;; spec is a plist for style-index. The renderer interns them.

(in-package #:leticl)

(defun appendf-attr (style key value)
  (append style (list key value)))

(defun %inline-spans (text style)
  "Inline markdown to segments: `code`, **bold**, *italic*."
  (let ((segs nil)
        (buf (make-string-output-stream))
        (n (length text))
        (i 0))
    (flet ((flush ()
             (let ((s (get-output-stream-string buf)))
               (when (plusp (length s))
                 (push (cons s style) segs)))))
      (loop while (< i n)
            do (cond
                 ((char= (char text i) #\`)
                  (let ((end (position #\` text :start (1+ i))))
                    (if end
                        (progn (flush)
                               (push (cons (subseq text (1+ i) end) '(:fg :cyan)) segs)
                               (setf i (1+ end)))
                        (progn (write-char #\` buf) (incf i)))))
                 ((and (< i (1- n)) (char= (char text i) #\*) (char= (char text (1+ i)) #\*))
                  (let ((end (search "**" text :start2 (+ i 2))))
                    (if end
                        (progn (flush)
                               (push (cons (subseq text (+ i 2) end)
                                           (appendf-attr style :bold t))
                                     segs)
                               (setf i (+ end 2)))
                        (progn (write-char #\* buf) (incf i)))))
                 ((char= (char text i) #\*)
                  (let ((end (position #\* text :start (1+ i))))
                    (if (and end (> end (1+ i)))
                        (progn (flush)
                               (push (cons (subseq text (1+ i) end)
                                           (appendf-attr style :italic t))
                                     segs)
                               (setf i (1+ end)))
                        (progn (write-char #\* buf) (incf i)))))
                 (t (write-char (char text i) buf) (incf i))))
      (flush))
    (nreverse segs)))

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

(defun markdown-lines (text &optional (base-style nil))
  "TEXT to a list of lines, each a list of (string . style-spec) segments."
  (let ((lines nil)
        (in-code nil)
        (code-lang "")
        (code-buf nil)                  ; raw fence lines, newest first
        (table-rows nil))
    (labels ((flush-table ()
               (when table-rows
                 (dolist (l (render-table (nreverse table-rows)))
                   (push l lines))
                 (setf table-rows nil)))
             (flush-code ()
               ;; the fence is styled as a WHOLE when it closes, or when the
               ;; message ends without one (a streaming turn is often mid-fence,
               ;; and dropping the lines would blank the code on screen)
               (when code-buf
                 (dolist (l (highlight-fence (nreverse code-buf) code-lang))
                   (push l lines))
                 (setf code-buf nil))))
      (dolist (line (uiop:split-string text :separator '(#\newline)))
        (cond
          ;; fenced code
          ((and (>= (length line) 3) (string= (subseq line 0 3) "```"))
           (flush-table)
           (if in-code
               (progn (flush-code) (setf in-code nil))
               (progn (setf in-code t
                            code-lang (string-trim " `" (subseq line 3)))
                      (push (list (cons (if (plusp (length code-lang))
                                            (format nil "── ~a " code-lang)
                                            "── ")
                                        '(:dim t)))
                            lines))))
          (in-code
           (flush-table)
           ;; ACCUMULATE the fence; do not emit yet. Highlighting is a
           ;; whole-buffer operation (tree-sitter parses the source, and a
           ;; multi-line string or comment only lexes correctly as a unit), so
           ;; the fence is styled when it CLOSES — see `flush-code`.
           (push line code-buf))
          ;; heading
          ((and (plusp (length line)) (char= (char line 0) #\#))
           (flush-table)
           (let* ((level (position-if (lambda (c) (char/= c #\#)) line))
                  (body (string-trim " #" line)))
             (push (list (cons body
                               (case (min (or level 1) 3)
                                 (1 '(:bold t :underline t))
                                 (2 '(:bold t))
                                 (t '(:bold t :fg :bright-white)))))
                   lines)))
          ;; blockquote
          ((and (plusp (length line)) (char= (char line 0) #\>))
           (flush-table)
           (push (list (cons "│ " '(:dim t))
                       (cons (string-trim " " (subseq line 1))
                             '(:italic t :dim t)))
                 lines))
          ;; table rows collect until the table ends
          ((%table-row-p line) (push line table-rows))
          ;; list item
          ((and (> (length line) 1)
                (member (char line 0) '(#\- #\*))
                (char= (char line 1) #\space))
           (flush-table)
           (push (list (cons "• " '(:fg :bright-cyan))
                       (cons (subseq line 2) base-style))
                 lines))
          ((and (> (length line) 2)
                (digit-char-p (char line 0))
                (string= (subseq line 1 (min 2 (length line))) ". "))
           (flush-table)
           (push (list (cons (subseq line 0 2) '(:fg :bright-cyan))
                       (cons (subseq line 2) base-style))
                 lines))
          ;; blank
          ((zerop (length (string-trim " " line)))
           (flush-table)
           (push nil lines))
          ;; plain paragraph
          (t
           (flush-table)
           (push (%inline-spans line base-style) lines))))
    (flush-table)
    ;; an UNCLOSED fence still has to render: a streaming turn is often
    ;; mid-fence, and the alternative is code that vanishes until the closing
    ;; backticks arrive
    (flush-code)
    (nreverse lines))))

(defun %table-row-p (line)
  "A GFM pipe row: has a pipe and is not a delimiter row (markdown.rs:476)."
  (and (plusp (length line))
       (find #\| line)
       (not (every (lambda (c) (member c '(#\space #\- #\: #\|))) line))))

(defun render-table (rows)
  "Rows to aligned lines: header bold, columns padded to the widest cell.
The column count is the header's; a row with more cells keeps them
(render.rs:360 keeps them too)."
  (when rows
    (let* ((cells (mapcar #'split-cells rows))
           (header (first cells))
           (ncols (length header))
           (widths (make-array ncols :initial-element 0)))
      (loop for row in cells
            do (loop for i from 0
                     for c in row
                     while (< i ncols)
                     do (setf (aref widths i)
                              (max (aref widths i) (string-width c)))))
      (flet ((emit (row style)
               (let ((segs nil))
                 (loop for i from 0
                       for c in row
                       while (< i ncols)
                       do (push (cons (pad-to c (aref widths i)) style) segs)
                          (unless (= i (1- ncols))
                            (push (cons " │ " '(:dim t)) segs)))
                 (list (nreverse segs)))))
        (append
         (emit header '(:bold t))
         (emit (make-list ncols :initial-element "") '(:dim t))
         (loop for row in (rest cells)
               append (emit row nil)))))))

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

(defun pad-to (string width)
  (let ((w (string-width string)))
    (if (< w width)
        (concatenate 'string string (make-string (- width w) :initial-element #\space))
        string)))
