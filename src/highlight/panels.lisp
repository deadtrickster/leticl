;;;; panels — the split panels
;;;;
;;;; Split out of `highlight.lisp`, which was one 444-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------- the split panels ;;;

(defun %style-over (role base-style)
  "The style for a syntax ROLE drawn over BASE-STYLE (a diff row's tint).

The tint is a background and the role is a foreground, so they compose by
appending — and the ROLE goes first so that a row whose base already names a
foreground keeps the syntax colour on top, the way the reference's
`Painter::rebase_resets` leaves the background running under a span that closes."
  (let ((rs (role-style role)))
    (cond ((null base-style) rs)
          ((null rs) base-style)
          (t (append rs base-style)))))

(defun %expand-tabs-chars (s stop)
  "Tabs in S to the next stop, counted over what has been WRITTEN.

**A PRE-EXISTING DEFECT, FOUND ONLY BECAUSE THE FENCE PATH STARTED USING THIS, and the old
docstring was protecting it rather than describing it.** The stop was computed from the SOURCE
index `i`, so at stop 4 `\"\t\tz\"` produced SEVEN spaces and not eight:

    i=0  tab -> (1+ (floor 0 4))*4 - 0 = 4
    i=1  tab -> (1+ (floor 1 4))*4 - 1 = 3     <- measured from the SOURCE index

The source index stops tracking the column the moment the first tab widens the output, so every
tab after the first in a run is short by whatever the ones before it added. MEASURED in the live
image before the fix.

The docstring used to justify the source index by the class grid — one entry per character, so
a stop measured in columns would slide the classes off the text — and that argument does not
apply HERE: `classed-segments` calls this function only in its `(null classes)` branch, where
there is no grid to slide, and the branch that HAS classes walks the text itself and already
tracks its own position. So nothing was relying on the wrong basis; the justification was
protecting a defect.

Characters, not display columns: `diff.lisp`'s `expand-tabs` measures columns, which is the right
answer for the unified view where nothing indexes the line."
  (if (null (position #\tab s))
      s
      (let ((out (make-string-output-stream))
            (col 0))
        (loop for ch across s
              do (if (char= ch #\tab)
                     (let ((next (* (1+ (floor col stop)) stop)))
                       (write-string (make-string (- next col) :initial-element #\space) out)
                       (setf col next))
                     (progn (write-char ch out) (incf col))))
        (get-output-stream-string out))))

(defun class-rows (lines lang-id)
  "One class vector per line of LINES, or NIL when there is no colour to be had.

`sidediff.rs:419-433`'s `class_grid`: the excerpt is joined with newlines and
parsed ONCE — a line parsed alone is a line with no context, and `}` closing a
block three lines up is exactly the thing tree-sitter is here for — then sliced
back per line. A short grid reads as uncoloured rather than as a bounds fault
(RANO.md's improvement #3, which the reference takes by panicking)."
  (when (zerop lang-id)
    ;; the common case on the diff path — an extension nobody has a grammar for —
    ;; and joining the whole excerpt to be told so is a copy of it per frame
    (return-from class-rows nil))
  (let* ((lines (coerce lines 'list))
         (source (format nil "~{~a~^~%~}" lines))
         (grid (class-grid source lang-id)))
    (when grid
      (let ((at 0)
            (n (length grid)))
        (map 'vector
             (lambda (line)
               (let* ((len (length line))
                      (row (if (<= (+ at len) n)
                               (subseq grid at (+ at len))
                               (make-array len :element-type '(unsigned-byte 8)
                                               :initial-element 0))))
                 (setf at (+ at len 1))   ; +1 for the newline the join added
                 row))
             lines)))))

(defun classed-segments (text classes &optional base-style (tab-stop 4))
  "TEXT to (cons TEXT STYLE) segments by its per-character role CLASSES.

`sidediff.rs:389-410`'s `paint_classed`: runs of one role open and close
together, and a tab expands to spaces that carry the TAB'S OWN class, so the
class grid and the visible columns stay one grid. The stop is counted in
CHARACTERS, not columns, which is the reference's own choice and the only one
that keeps `classes[i]` describing `(char text i)`.

BASE-STYLE is merged under every segment — the diff panel's background tint —
so a syntax colour never ends the row's role. NIL CLASSES gives one segment,
which is what a missing shim and a `Palette::None` terminal both read."
  (if (or (null classes) (zerop (length text)))
      (list (cons (%expand-tabs-chars text tab-stop) base-style))
      (let ((out nil)
            (buf (make-string-output-stream))
            (run nil))
        (labels ((flush ()
                   (let ((s (get-output-stream-string buf)))
                     (when (plusp (length s))
                       (push (cons s (%style-over run base-style)) out)))))
          (loop for i from 0 below (length text)
                for ch = (char text i)
                for role = (if (< i (length classes)) (aref classes i) 0)
                do (cond
                     ((char= ch #\tab)
                      (flush)
                      (setf run role)
                      (let ((stop (* (1+ (floor i tab-stop)) tab-stop)))
                        (write-string (make-string (- stop i) :initial-element #\space)
                                      buf))
                      (flush)
                      (setf run nil))
                     (t
                      (unless (and run (eql run role))
                        (flush)
                        (setf run role))
                      (write-char ch buf))))
          (flush))
        (nreverse out))))

