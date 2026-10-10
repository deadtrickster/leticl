;;;; lines — lines: a highlighted block as segment lines
;;;;
;;;; Split out of `highlight.lisp`, which was one 444-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------------- lines ;;;

(defun highlight-lines (source lang-id)
  "SOURCE to a list of lines; each line is a list of (cons TEXT STYLE) segments
with syntax colour. A missing shim, unknown language, or failed parse gives one
plain segment per line — the same thing a Palette::None terminal reads.

Tabs are expanded to the next 4-character stop, in BOTH branches: a fence with no grammar is
still indented code.

**THE FENCE PATH NEVER EXPANDED TABS, and the diff path always had.** MEASURED in the live image
before the fix — tabs reached the cell grid verbatim, so a `go` block lost its indentation and
every `func`, `if` and `return` sat flush left:
    a Go fence whose middle line is tab-indented came back with a segment holding ONE TAB
    and then the word RETURN — the tab reaching the cell grid verbatim, so every line drew
    flush left.
    => line2 (a TAB segment, then a magenta return segment)

**The diff path already had this arm and this one never grew it** — `classed-segments` has an
explicit tab branch and `%expand-tabs-chars` carries the reasoning. Two renderers of the same
fact, one of them complete, which is the split that has produced most of the defects on this
feature.

**`col` IS PER LINE, not derived from `i`.** `i` indexes the whole multi-line SOURCE, so using it
for the stop would make a line's indent depend on how far down the block that line sits. It
resets in `flush-line`, the only place a line ends.

The stop is 4 — `classed-segments`' default, and letibot's `sidediff.rs:80 const TAB_STOP:
usize = 4`, so the two heads agree on where a tab lands."
  (let ((grid (class-grid source lang-id)))
    (if (null grid)
        ;; **A FENCE WITH NO GRAMMAR IS STILL INDENTED CODE.** This branch used to hand `line`
        ;; straight through, so a ```text or bare fence kept its tabs after the branch above was
        ;; fixed and the two disagreed about what a fence body is.
        (mapcar (lambda (line) (list (cons (%expand-tabs-chars line 4) nil)))
                (uiop:split-string source :separator '(#\newline)))
        (let ((lines nil)
              (segs nil)
              (buf (make-string-output-stream))
              (role nil)
              (col 0))
          (labels ((flush-seg ()
                    (let ((text (get-output-stream-string buf)))
                      (when (plusp (length text))
                        (push (cons text (role-style role)) segs))
                      (setf buf (make-string-output-stream))))
                   (flush-line ()
                     (flush-seg)
                     (push (nreverse segs) lines)
                     (setf segs nil)
                     ;; **THE ONLY PLACE A LINE ENDS**, so the only place the column resets.
                     (setf col 0)))
            (loop for i from 0 below (length source)
                  for ch = (char source i)
                  for r = (aref grid i)
                  do (if (char= ch #\newline)
                         (flush-line)
                         (progn
                           (unless (and role (eql role r))
                             (flush-seg)
                             (setf role r))
                           (if (char= ch #\Tab)
                               (let ((stop (* (1+ (floor col 4)) 4)))
                                 (write-string
                                  (make-string (- stop col) :initial-element #\space)
                                  buf)
                                 (setf col stop))
                               (progn (write-char ch buf) (incf col))))))
            (flush-line)
            (nreverse lines))))))
