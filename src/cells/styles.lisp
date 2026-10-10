;;;; cells.lisp — the cell buffer and the ANSI diff painter.
;;;;
;;;; A screen is a flat vector of cells; a cell is a character plus an interned
;;;; style index. The painter compares the previous frame against the current
;;;; one and emits absolute cursor moves for changed runs only, wrapped in
;;;; synchronized output (?2026) so a burst of deltas never shows a half frame.
;;;; Every drawing decision stays a plain function here — that is what makes
;;;; the live-hack property real (PLAN.md §1).

(in-package #:leticl)

(defparameter +wide-cont+ (code-char 0)
  "Marks the second half of a double-width character. Never written to the
terminal: the wide char before it advances the cursor over both columns.")

;;; ---------------------------------------------------------------- styles ;;;

;; The style intern table is LIVE state: cells hold indices into it, so a
;; redefinition that reset it would repaint the whole screen with wrong colours
;; (measured: a live push of this file did exactly that). defvar assigns only
;; when unbound, so a push leaves a running head's table — and its indices —
;; alone.
(defvar *styles* (make-array 8 :adjustable t :fill-pointer 1 :initial-element nil)
  "Interned style specs. Index 0 is always the default (empty) style.")

;; *style-sgrs* is LIVE state for the same reason *styles* is, and it is
;; PARALLEL to it: index N of one describes index N of the other. A push that
;; reset only this one left the two out of step — cells held style indices the
;; SGR table had no entry for, and the next paint died with "Invalid index 8 for
;; (VECTOR T 8)". That is the same defect class as *styles*, missed because the
;; table looked like static data and its twin did not.
(defvar *style-sgrs*
  (make-array 8 :adjustable t :fill-pointer 1
              :initial-element (format nil "~C[0m" (code-char 27)))
  "Cached SGR sequences, parallel to *styles*. Index 0 is the plain reset —
initialized here, because a default-style cell must never read whatever
make-array leaves in unallocated slots.")

(defparameter *color-names*
  '(:black :red :green :yellow :blue :magenta :cyan :white
    :bright-black :bright-red :bright-green :bright-yellow
    :bright-blue :bright-magenta :bright-cyan :bright-white))

(defun %color-sgr (color backgroundp)
  "SGR parameter string for one color: named 0-15, 256-index, or (r g b)."
  (let ((base (if backgroundp 40 30)))
    (typecase color
      (keyword
       (let ((n (position color *color-names*)))
         (unless n (error "unknown color name ~s" color))
         (if (< n 8) (format nil "~d" (+ base n))
             (format nil "~d" (+ base 60 (- n 8))))))
      (integer
       (unless (<= 0 color 255) (error "color index out of range: ~d" color))
       (format nil "~d;5;~d" (+ base 8) color))
      (cons
       (destructuring-bind (r g b) color
         (format nil "~d;2;~d;~d;~d" (+ base 8) r g b)))
      (t (error "bad color ~s" color)))))

(defun %style-sgr (spec)
  "The SGR sequence that switches from default to SPEC. Always begins with
ESC[0m: styles compose by full reset, because the painter only ever switches
between interned styles and never layers them."
  (with-output-to-string (s)
    (write-string (format nil "~C[0" +esc+) s)
    (loop for (k v) on spec by #'cddr
          do (case k
               (:bold (when v (write-string ";1" s)))
               (:dim (when v (write-string ";2" s)))
               (:italic (when v (write-string ";3" s)))
               (:underline (when v (write-string ";4" s)))
               (:reverse (when v (write-string ";7" s)))
               (:strikethrough (when v (write-string ";9" s)))
               (:fg (format s ";~a" (%color-sgr v nil)))
               (:bg (format s ";~a" (%color-sgr v t)))
               (t (error "unknown style key ~s" k))))
    (write-char #\m s)))

(defun rebuild-style-sgrs ()
  "Recompute the SGR cache from the style SPECS, restoring parallelism.

The two tables are parallel by construction — index N of `*style-sgrs*` is the
SGR for index N of `*styles*` — so one can always be rebuilt from the other, and
`*styles*` is the source of truth because it holds the specs.

This exists because the pairing BROKE in a way the old code could not survive: a
live push reset one table and not the other, cells kept style indices the SGR
cache had no entry for, and the next paint died with \"Invalid index 8 for
(VECTOR T 8)\". Both tables are `defvar` now so a push cannot do that again, but
a head already carrying the desync can be repaired in place rather than
restarted — which is the whole point of a head that can be patched while it
runs. Idempotent, so calling it on a healthy head is a no-op in effect."
  (let ((specs (coerce *styles* 'vector)))
    (setf *style-sgrs*
          (make-array (max 8 (length specs)) :adjustable t :fill-pointer 0))
    (loop for spec across specs
          do (vector-push-extend (%style-sgr spec) *style-sgrs*))
    *style-sgrs*))

(defparameter *style-key-order*
  '(:bold :dim :italic :underline :reverse :strikethrough :fg :bg)
  "The one order a style spec's keys are written in, for `%canonical-style`.

The order `%style-sgr` already emits in, so a canonical spec reads the way its
escape does.")

(defun %canonical-style (spec)
  "SPEC with its pairs in `*style-key-order*`, duplicates dropped and every pair
whose value is NIL removed.

**Two spellings of one style were two styles.** `'(:fg :red :bold t)` and
`'(:bold t :fg :red)` are the same rendition, and `style-index` interned them at
different indices with different bytes — `ESC[0;31;1m` against `ESC[0;1;31m` —
so a frame drawn by one and repainted by the other emitted a style change where
nothing had changed, and `compare-heads` read a difference that was not one.
Both spellings are in the tree today (`src/chrome/counters.lisp:271,329` against
`src/cards/decisions.lisp:93`).

A NIL value is dropped rather than kept, because `'(:bold nil)` renders as
nothing and index 0 renders as nothing, and two indices for one rendition is the
same defect one level down. A key nobody knows is kept, in the order it was
written, so `%style-sgr` still refuses it out loud rather than ignoring it."
  (when spec
    (let ((pairs (loop for (k v) on spec by #'cddr
                       unless (or (null v) (assoc k seen))
                         collect (cons k v) into seen
                       finally (return seen))))
      (append
       (loop for k in *style-key-order*
             for hit = (assoc k pairs)
             when hit append (list k (cdr hit)))
       (loop for (k . v) in pairs
             unless (member k *style-key-order*) append (list k v))))))

(defun style-index (spec)
  "Intern a style spec plist (:fg :cyan :bold t …) into a small integer.
Index 0 is the default; EQUAL is the identity of a CANONICAL spec — see
`%canonical-style`, which is what makes the key order not matter."
  (let ((spec (%canonical-style spec)))
    (if (null spec)
      0
      (or (position spec *styles* :test #'equal)
          (progn
            (vector-push-extend spec *styles*)
            (vector-push-extend (%style-sgr spec) *style-sgrs*)
            (1- (length *styles*)))))))

(defun %sgr (index)
  "The escape for style INDEX. Out of range gives style 0, and that is a RULE.

**A cell can hold a style index the table no longer has, and that must cost one
cell's colour and never the screen.** `%intern-style` pushes pairs onto `*styles*`
and `*style-sgrs*`, so the two are parallel BY CONSTRUCTION — and a live push that
redefines the style vocabulary rebuilds them under cells that were written with the
OLD numbering. `(aref *style-sgrs* index)` then reads past the end and SIGNALS, from
inside `paint-diff`'s write loop.

That is not hypothetical: it is the recorded incident at `df9bd3f`, and it is the
only mechanism that explains the operator's symptom — *\"scroll doesnt work on tool
and thinking expansions … only switching byobu windows fixes scroll\"*. Here is the
whole chain, every step of it measured or in the tree:

  1. the index is out of range, so EVERY paint dies at its first style change;
  2. `%paint-failure` runs, writes `ESC[2J`, and dies in the same place — so the
     terminal is CLEARED and nothing is redrawn, while the head's record
     (`head-prev-screen`) is set to the frame it *intended*;
  3. the head keeps painting and keeps dying, and a diff writes only what CHANGED
     against a record that is already a lie — **so nothing in the head can repair
     it**, which is what \"even after collapsing back\" means;
  4. a byobu window switch resizes the pane, and `screen-resize` allocates a FRESH
     cell vector (`cells.lisp:176`) — the out-of-range cells are gone, the paints
     succeed, and `head-full-repaint` redraws everything. **That is why only a
     window switch fixes it.**

So the bounds check is the fix for the operator's symptom, and it belongs here rather
than in a caller: a wrong index is a fact about a CELL, and a cell must not be able to
stop the frame. The cost is one comparison per style change, which is the same trade
`paint-diff` already makes for the cell vector itself (*\"the vector holds whatever a
hack put there\"*)."
  (if (and (integerp index) (< -1 index) (< index (length *style-sgrs*)))
      (aref *style-sgrs* index)
      (aref *style-sgrs* 0)))

