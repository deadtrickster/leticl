<!-- abstract: The terminal's SCREEN MODEL, written and NOT applied: paste into src/pane-protocol.lisp before the term-pane's pane-lines method, then run the suite and wire the pane. -->

# The terminal's screen model — WRITTEN, NOT APPLIED, NOT RUN

**State:** this is the code for `!term`'s remaining half, written on 2026-10-11 but never applied,
because the exec gate refused the `bash` call that would have written and tested it (the session's
seated schema is stale — see `todo-md-queue-state`). It is here so it is not lost, and it is
**NOT in the tree**: nothing below has been compiled or run.

**How to land it (one pass, ~10 minutes):**

1. append everything from `;;; --- the terminal's SCREEN` to the end of this note's code block into
   `src/pane-protocol.lisp`, immediately BEFORE `(defmethod pane-lines ((pane term-pane) head cols
   room)` — i.e. after `%term-lines-from-output`;
2. `python3 scripts/count-parens.py src/pane-protocol.lisp` (expect `file final depth: 0`);
3. run the suite: it must stay GREEN — nothing calls the new code yet, which is the point;
4. add tests: a CUP then text lands on the right row; `ESC [ 2 J` blanks; a scroll drops the top row;
   `\n` at the bottom row scrolls; a long line wraps; `ESC [ 31m` is DROPPED (roles, not colours);
5. only then wire it: give the pane screen-drawing (the screen model replaces
   `%term-lines-from-output` as the pane's source, and `term_output` feeds it instead of appending
   to a string);
6. and record in `TODO.md` that the screen is in, with what is still counted.

**Two things to keep from the interim, because they are the box's rule:** every sequence the head
cannot honour is COUNTED and the count is SAID on the pane, and the pane names the half it lacks.
A confident wrong screen is worse than a named missing one.

```lisp
;;; ------------------------------------------------------- the terminal's SCREEN ;;;
;;;
;;; **A ROWS x COLS GRID WITH A CURSOR — which is what a terminal IS.** The line model above
;;; (`%term-lines-from-output`) was the honest interim while there was no screen to draw into: it
;;; could honour an overwrite and an erase because both are expressible on a line, and it had to
;;; COUNT cursor addressing because a line has nowhere to put a row. This is where rows go.
;;;
;;; It is a PORT, not an invention (`rano/src/term/` on this box: 3021 lines across six modules —
;;; decode, event, features, graphics, links, terminal). The sequences below are the ones that
;;; matter for a program drawing in a pane; everything else is still COUNTED and still said.

(defstruct (term-screen (:constructor %make-term-screen (rows cols cells)))
  (rows 0 :type fixnum)
  (cols 0 :type fixnum)
  ;; a string, row-major: cell (r, c) is at (+ (* r cols) c)
  (cells "" :type string)
  (row 0 :type fixnum)
  (col 0 :type fixnum))

(defun term-screen-new (rows cols)
  "A blank screen, cursor at home."
  (let ((rows (max 1 rows)) (cols (max 1 cols)))
    (%make-term-screen rows cols (make-string (* rows cols) :initial-element #\space))))

(defun %ts-index (s r c) (+ (* r (term-screen-cols s)) c))

(defun %ts-put (s ch)
  "Write CH at the cursor and advance, wrapping at the right edge — what a terminal does with a
full line, and why a program that prints a long line sees it break."
  (when (>= (term-screen-col s) (term-screen-cols s))
    (setf (term-screen-col s) 0)
    (%ts-next-row s))
  (when (< (term-screen-row s) (term-screen-rows s))
    (setf (char (term-screen-cells s) (%ts-index s (term-screen-row s) (term-screen-col s))) ch))
  (incf (term-screen-col s)))

(defun %ts-next-row (s)
  "Down one row, SCROLLING on the last — the bottom row is where output lives, and a terminal that
refused to scroll would draw nothing after the first screenful."
  (if (>= (1+ (term-screen-row s)) (term-screen-rows s))
      (%ts-scroll s)
      (incf (term-screen-row s))))

(defun %ts-scroll (s)
  "Drop the top row, blank the bottom, and leave the cursor on the last row."
  (let* ((cols (term-screen-cols s)) (rows (term-screen-rows s)) (cells (term-screen-cells s)))
    (replace cells (subseq cells cols) :start1 0 :end1 (* (1- rows) cols))
    (fill cells #\space :start (* (1- rows) cols))
    (setf (term-screen-row s) (1- rows))))

(defun %ts-erase-row (s row from to)
  (let ((cols (term-screen-cols s)))
    (loop for c from (max 0 from) below (min cols to)
          do (setf (char (term-screen-cells s) (%ts-index s row c)) #\space))))

(defun term-screen-cup (s row col)
  "Cursor position — `H`/`f`. Its arguments are 1-BASED in the notation and 0-based here."
  (setf (term-screen-row s) (min (1- (term-screen-rows s)) (max 0 (1- row)))
        (term-screen-col s) (min (1- (term-screen-cols s)) (max 0 (1- col)))))

(defun term-screen-el (s n)
  "Erase in line — `K`: 0 (default) to the end, 1 from the start, 2 the whole row."
  (let ((row (term-screen-row s)) (col (term-screen-col s)) (cols (term-screen-cols s)))
    (case n
      (0 (%ts-erase-row s row col cols))
      (1 (%ts-erase-row s row 0 (1+ col)))
      (2 (%ts-erase-row s row 0 cols)))))

(defun term-screen-ed (s n)
  "Erase in display — `J`: 0 below-and-right, 1 above-and-left, 2 everything."
  (let ((row (term-screen-row s)) (col (term-screen-col s)) (rows (term-screen-rows s))
        (cols (term-screen-cols s)))
    (case n
      (0 (%ts-erase-row s row col cols)
         (loop for r from (1+ row) below rows do (%ts-erase-row s r 0 cols)))
      (1 (%ts-erase-row s row 0 (1+ col))
         (loop for r from 0 below row do (%ts-erase-row s r 0 cols)))
      (2 (loop for r from 0 below rows do (%ts-erase-row s r 0 cols))))))

(defun term-screen-lines (s)
  "The rows as a reader sees them, right-trimmed — a blank row is an EMPTY line, not a row of spaces."
  (loop for r from 0 below (term-screen-rows s)
        collect (string-right-trim '(#\space)
                                   (subseq (term-screen-cells s) (%ts-index s r 0)
                                           (+ (%ts-index s r 0) (term-screen-cols s))))))

(defun term-screen-feed (s output)
  "Feed OUTPUT into SCREEN, honouring what can be honoured. Returns the count of sequences DROPPED.

A VT SUBSET and it says so: `CR`, `LF`, `BS`, `TAB`, the cursor moves (`A`–`D`, `H`/`f`), the erases
(`J`/`K`). SGR (`m`) is dropped on purpose — this head draws ROLES, not terminal colours — and
everything else is counted, never guessed at, which is the rule the pane keeps."
  (let ((dropped 0) (args "") (state :text) (n (length output)) (i 0))
    (labels ((num () (if (plusp (length args)) (or (parse-integer args :junk-allowed t) 0) 0))
             (arg1 () (if (plusp (length args)) (or (parse-integer args :junk-allowed t) 1) 1))
             (arg2 () (let ((semi (position #\; args)))
                        (if semi (or (parse-integer (subseq args (1+ semi)) :junk-allowed t) 1) 1)))
             (seq (final)
               (case final
                 ((#\H #\f) (term-screen-cup s (arg1) (arg2)))
                 (#\K (term-screen-el s (num)))
                 (#\J (term-screen-ed s (num)))
                 (#\A (setf (term-screen-row s)
                            (max 0 (- (term-screen-row s) (max 1 (num))))))
                 (#\B (dotimes (k (max 1 (num))) (%ts-next-row s)))
                 (#\C (setf (term-screen-col s)
                            (min (1- (term-screen-cols s))
                                 (+ (term-screen-col s) (max 1 (num))))))
                 (#\D (setf (term-screen-col s)
                            (max 0 (- (term-screen-col s) (max 1 (num))))))
                 (t nil))
               (setf args "" state :text)))
      (loop while (< i n) do
        (let ((ch (char output i)))
          (case state
            (:text (case ch
                     (#\newline (setf (term-screen-col s) 0) (%ts-next-row s))
                     (#\return (setf (term-screen-col s) 0))
                     (#\tab (dotimes (k 8) (%ts-put s #\space)))
                     (#\backspace (when (plusp (term-screen-col s)) (decf (term-screen-col s))))
                     (#\escape (setf state :esc))
                     (t (%ts-put s ch)))
                   (incf i))
            (:esc (if (char= ch #\[)
                      (setf state :csi)
                      (progn (incf dropped) (setf state :text)))
                  (incf i))
            (:csi (cond ((<= 48 (char-code ch) 57)
                         (setf args (concatenate 'string args (string ch)))
                         (incf i))
                        ((char= ch #\;)
                         (setf args (concatenate 'string args ";"))
                         (incf i))
                        ((<= 64 (char-code ch) 126)
                         (incf dropped) (seq ch) (incf i))
                        (t (incf i))))))))
    dropped))
```

**A note on the shape, from what landed earlier today**: write it as FLAT clauses where you can —
the four-arm version of the CSI branch in `%term-lines-from-output` landed first try, where the
nested version failed twice on a stray paren. And assert every string replacement in a script; an
unasserted one is a coin flip.
