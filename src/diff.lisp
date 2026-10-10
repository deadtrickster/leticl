;;;; diff.lisp — a unified diff: a Myers edit script, hunks, and a
;;;; segment-line renderer. Ported from crates/ui/src/diff.rs.
;;;;
;;;; # Why a head needs this at all
;;;;
;;;; A completed `edit` tool call used to render as a byte count. That answers
;;;; none of the questions a person has, which are: *which file, and what
;;;; changed in it*. This module is the answer: a line diff with hunk context,
;;;; line numbers, and an intra-line word highlight on the changed run.
;;;;
;;;; # The algorithm, and the bound on it
;;;;
;;;; Myers' greedy O(ND) edit-script algorithm, with the two standard
;;;; preconditioners (strip the common prefix and suffix first) and one
;;;; non-standard guard: **max-d**. Myers is O(ND) where D is the size of the
;;;; edit script, so two unrelated 10,000-line files cost 10^8 steps — and a
;;;; head is not allowed to stall for a frame, ever, because the same loop is
;;;; servicing the socket. Past max-d the diff gives up and reports the region
;;;; as a whole replacement, which is both honest and what a reader would
;;;; conclude anyway. `diff-degraded` says when that happened, so it is never
;;;; silent.
;;;;
;;;; # Word-level highlight, and where it stops
;;;;
;;;; Inside a hunk, a removed line adjacent to an added line is *usually* an
;;;; edit of that line, and showing which run of characters changed is the
;;;; difference between reading a diff and scanning it. The pairing rule is
;;;; positional — the k-th removal in a run pairs with the k-th addition —
;;;; which is what every terminal diff does and is wrong when the run is a
;;;; reordering. The guard is that pairing is only attempted when the two lines
;;;; are similar enough (+similarity-floor+), so two entirely different lines
;;;; are shown plainly rather than as a sea of emphasis.
;;;;
;;;; # The rendering model
;;;;
;;;; The Rust original returns strings with ANSI escapes embedded. leticl's
;;;; render model is segment lines — a list of lines, each a list of
;;;; (cons TEXT STYLE) — so this port returns those instead. The diff roles
;;;; map onto leticl styles: an added line carries the xterm cube's darkest
;;;; green background (22) and a removed line the darkest red (52), the text
;;;; keeps its own foreground, and the changed run inside a paired line is
;;;; bold+underline. The sign glyph keeps the original green and red.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;; ---------------------------------------------------------------- constants ;;;

(defconstant +similarity-floor+ 0.35
  "Below this ratio of shared tokens, two paired lines are treated as
unrelated and no intra-line highlight is attempted. Chosen so that a renamed
variable highlights and a rewritten line does not.")

(defconstant +default-max-d+ 2000
  "Default cap on Myers' D. Roughly \"a thousand changed lines\", which is far
past the point where a human reads the diff rather than the file.")

;; The diff roles, as leticl style plists. Backgrounds only — the text keeps
;; whatever foreground it already had (the operator's ruling on the first cube
;; tint). 22 and 52 are the xterm cube's darkest green and red.
(defparameter +diff-added-bg+ '(:bg 22))
(defparameter +diff-removed-bg+ '(:bg 52))
;; The changed run inside a paired line: bold + underline, over the role's
;; background.
(defparameter +diff-emphasis+ '(:bold t :underline t))

;; ------------------------------------------------------------------- model ;;;

(defstruct diff
  (ops #() :type vector)   ; vector of op-lists: (:equal a b) (:delete a) (:insert b)
  (degraded nil :type boolean))

;; ------------------------------------------------------------------ myers ;;;

(defun %myers (a b max-d)
  "Myers' greedy algorithm with a D cap. A and B are sequences compared with
#'string=. Returns two values: OPS (a list of op-lists) and DEGRADED (t when
the cap was hit and the whole region is reported as a replacement)."
  (let ((n (length a))
        (m (length b)))
    (cond
      ((and (zerop n) (zerop m)) (values nil nil))
      ((zerop n)
       (values (loop for b below m collect (list :insert b)) nil))
      ((zerop m)
       (values (loop for a below n collect (list :delete a)) nil))
      (t
       (let* ((max (min (+ n m) max-d))
              (off (+ n m))
              (v (make-array (1+ (* 2 off)) :initial-element 0))
              (trace (make-array (1+ max) :adjustable t :fill-pointer 0
                                 :initial-element nil)))
         (loop for d from 0 to max
               do (vector-push-extend (copy-seq v) trace)
                  (loop for k from (- d) to d by 2
                        for ki = (+ k off)
                        do (let ((x (if (or (= k (- d))
                                             (and (/= k d)
                                                  (< (aref v (1- ki)) (aref v (1+ ki)))))
                                         (aref v (1+ ki))
                                         (1+ (aref v (1- ki))))))
                               (let ((y (- x k)))
                                 (loop while (and (< x n) (< y m)
                                                  (string= (elt a x) (elt b y)))
                                       do (incf x) (incf y))
                                 (setf (aref v ki) x)
                                 (when (and (>= x n) (>= y m))
                                   (return-from %myers
                                     (values (%backtrack trace n m off) nil)))))))
         ;; Gave up: report the whole middle as a replacement.
         (values (append (loop for a below n collect (list :delete a))
                         (loop for b below m collect (list :insert b)))
                 t))))))

(defun %backtrack (trace n m off)
  "Walk the per-D trace backwards to recover the edit script."
  (let ((ops nil)
        (x n)
        (y m))
    (loop for d from (1- (length trace)) downto 0
          do (let* ((v (aref trace d))
                    (k (- x y))
                    (ki (+ k off))
                    (prev-k (if (or (= k (- d))
                                    (and (/= k d)
                                         (< (aref v (1- ki)) (aref v (1+ ki)))))
                               (1+ k)
                               (1- k)))
                   (prev-x (aref v (+ prev-k off)))
                   (prev-y (- prev-x prev-k)))
              (loop while (and (> x prev-x) (> y prev-y))
                    do (decf x) (decf y)
                       (push (list :equal x y) ops))
              (when (zerop d) (return))
              (if (> x prev-x)
                  (progn (decf x) (push (list :delete x) ops))
                  (progn (decf y) (push (list :insert y) ops)))))
    ops))

;; ------------------------------------------------------------- diff-lines ;;;

(defun diff-lines (old new)
  "Line-level diff of OLD and NEW (sequences of strings). Returns a DIFF."
  (diff-lines-with old new +default-max-d+))

(defun diff-lines-with (old new max-d)
  "diff-lines with an explicit cap on Myers' D."
  (let* ((old (coerce old 'vector))
         (new (coerce new 'vector))
         (n (length old))
         (m (length new))
         (lo 0)
         (hi 0))
    ;; Strip the common prefix and suffix. On a real edit this removes almost
    ;; everything, which is what makes Myers affordable on a large file.
    (loop while (and (< lo n) (< lo m) (string= (elt old lo) (elt new lo)))
          do (incf lo))
    (loop while (and (< hi (- n lo)) (< hi (- m lo))
                     (string= (elt old (- n 1 hi)) (elt new (- m 1 hi))))
          do (incf hi))
    (let* ((a (subseq old lo (- n hi)))
           (b (subseq new lo (- m hi)))
           (ops (make-array (+ lo (length a) hi) :adjustable t :fill-pointer 0
                            :initial-element nil)))
      (dotimes (i lo) (vector-push-extend (list :equal i i) ops))
      (multiple-value-bind (mid degraded) (%myers a b max-d)
        (dolist (op mid)
          (case (first op)
            (:equal (vector-push-extend (list :equal (+ lo (second op))
                                               (+ lo (third op))) ops))
            (:delete (vector-push-extend (list :delete (+ lo (second op))) ops))
            (:insert (vector-push-extend (list :insert (+ lo (second op))) ops))))
        (dotimes (k hi)
          (vector-push-extend (list :equal (+ (- n hi) k) (+ (- m hi) k)) ops))
        (make-diff :ops (coerce ops 'vector) :degraded degraded)))))

;; ------------------------------------------------------------------ hunks ;;;

(defun hunks (diff context)
  "Group an edit script into hunks. CONTEXT is the number of unchanged lines
kept either side of a change; three is the `diff -u` convention. Returns a
list of hunk plists (:old-start :new-start :rows), each row a list
(:context a b) (:removed a) or (:added b)."
  (let ((ops (diff-ops diff))
        (n (length (diff-ops diff)))
        (changed (loop for op across (diff-ops diff)
                       for i from 0
                       when (not (eq (first op) :equal))
                       collect i)))
    (when (null changed) (return-from hunks nil))
    (let ((out nil)
          (i 0)
          (cn (length changed)))
      (loop while (< i cn)
            do (let ((start (max 0 (- (nth i changed) context)))
                     (j i))
                 ;; Extend while the next change is close enough that the
                 ;; context would overlap; otherwise a two-line gap becomes two
                 ;; hunks and reads worse.
                 (loop while (and (< (1+ j) cn)
                                  (<= (nth (1+ j) changed)
                                      (+ (nth j changed) (* 2 context) 1)))
                       do (incf j))
                 (let* ((end (min (+ (nth j changed) context 1) n))
                        (rows nil)
                        (old-start most-positive-fixnum)
                        (new-start most-positive-fixnum))
                   (loop for k from start below end
                         for op = (aref ops k)
                         do (case (first op)
                              (:equal (setf old-start (min old-start (second op))
                                           new-start (min new-start (third op)))
                                      (push (list :context (second op) (third op)) rows))
                              (:delete (setf old-start (min old-start (second op)))
                                       (push (list :removed (second op)) rows))
                              (:insert (setf new-start (min new-start (second op)))
                                       (push (list :added (second op)) rows))))
                   (push (list :old-start (if (= old-start most-positive-fixnum) 0 old-start)
                               :new-start (if (= new-start most-positive-fixnum) 0 new-start)
                               :rows (nreverse rows))
                         out)
                   (setf i (1+ j)))))
      (nreverse out))))

;; ---------------------------------------------------------- word-level ;;;

(defun %tokens (s)
  "Split S into runs of word characters (alphanumeric or _) and runs of
everything else, as (start end) character spans. Whitespace is its own token
so that an indentation change highlights."
  (let ((out nil)
        (n (length s))
        (i 0))
    (loop while (< i n)
          do (let ((word (or (alphanumericp (char s i)) (char= (char s i) #\_)))
                   (end (1+ i)))
               (loop while (< end n)
                     do (let ((w2 (or (alphanumericp (char s end))
                                      (char= (char s end) #\_))))
                          (when (not (eql w2 word)) (return))
                          (incf end)))
               (push (list i end) out)
               (setf i end)))
    (nreverse out)))

(defun %merge-spans (spans)
  "Coalesce adjacent (start end) spans into the fewest that cover the same
ground."
  (let ((out nil))
    (dolist (s spans)
      (if (and out (= (cadr (first out)) (first s)))
          (setf (cadr (first out)) (second s))
          (push (list (first s) (second s)) out)))
    (nreverse out)))

(defun word-spans (a b)
  "Character spans that differ between two similar lines, or NIL NIL when they
are not similar enough for the highlight to mean anything. The spans are into
the tab-expanded lines, in order and non-overlapping."
  (let ((at (%tokens a))
        (bt (%tokens b)))
    (when (or (null at) (null bt)) (return-from word-spans (values nil nil)))
    (let ((av (mapcar (lambda (span) (subseq a (first span) (second span))) at))
          (bv (mapcar (lambda (span) (subseq b (first span) (second span))) bt)))
      (multiple-value-bind (ops degraded) (%myers av bv 512)
        (when degraded (return-from word-spans (values nil nil)))
        (let ((n-equal (count-if (lambda (op) (eq (first op) :equal)) ops)))
          (let ((ratio (/ (* 2.0 n-equal) (+ (length av) (length bv)))))
          (when (< ratio +similarity-floor+)
            (return-from word-spans (values nil nil)))
          (let ((asp (loop for op in ops
                           when (eq (first op) :delete)
                           collect (nth (second op) at)))
                (bsp (loop for op in ops
                           when (eq (first op) :insert)
                           collect (nth (second op) bt))))
            (setf asp (%merge-spans asp)
                  bsp (%merge-spans bsp))
            (when (and (null asp) (null bsp))
              (return-from word-spans (values nil nil)))
            (values asp bsp))))))))

(defun %pair-rows (rows old new)
  "For each row of a hunk, the character spans that changed relative to its
pair, or NIL. A maximal run of removals followed by a maximal run of additions
is paired positionally — the k-th removal with the k-th addition."
  (let ((rows (coerce rows 'vector)))
    (let ((n (length rows)))
      (let ((out (make-array n :initial-element nil))
            (i 0))
        (loop while (< i n)
          do (let ((rem-start i))
               (loop while (and (< i n) (eq (first (aref rows i)) :removed))
                     do (incf i))
               (let* ((rem-end i)
                      ;; `add-start` is bound BEFORE the addition run is
                      ;; consumed, exactly as `diff.rs:555` binds it before the
                      ;; loop at `:556-558`. Binding it after — which is what
                      ;; this did until it was measured — leaves
                      ;; `(= add-end add-start)` true on every hunk, so the
                      ;; branch below always took the false arm, `out` came back
                      ;; all NIL and the whole word-emphasis path below
                      ;; `%emphasize` was dead code that nothing on screen could
                      ;; reach.
                      (add-start i))
                 (loop while (and (< i n) (eq (first (aref rows i)) :added))
                       do (incf i))
                 (let ((add-end i))
                   (if (or (= rem-end rem-start) (= add-end add-start))
                       (when (= i rem-start) (incf i))
                       (let ((kmax (min (- rem-end rem-start)
                                        (- add-end add-start))))
                         (loop for k below kmax
                               do (let* ((a (second (aref rows (+ rem-start k))))
                                          (b (second (aref rows (+ add-start k))))
                                          (ol (when (< a (length old))
                                                (expand-tabs (elt old a) 4)))
                                          (nl (when (< b (length new))
                                                (expand-tabs (elt new b) 4))))
                                    (when (and ol nl)
                                      (multiple-value-bind (os ns) (word-spans ol nl)
                                        (when os
                                          (setf (aref out (+ rem-start k)) os
                                                (aref out (+ add-start k)) ns))))))))))))
        out))))

;; ------------------------------------------------------------------ tabs ;;;

(defun expand-tabs (s stop)
  "Expand tabs to a tab stop. A diff that measures a tab as one column
mis-aligns every line that has one, which in Go and Makefiles is all of them."
  (unless (position #\tab s) (return-from expand-tabs s))
  (let ((out (make-string-output-stream))
        (col 0))
    (loop for ch across s
          do (if (char= ch #\tab)
                 (let ((n (- stop (mod col stop))))
                   (write-string (make-string n :initial-element #\space) out)
                   (incf col n))
                 (progn
                   (write-char ch out)
                   (incf col (char-width ch)))))
    (get-output-stream-string out)))

;; ---------------------------------------------------------- render helpers ;;;

(defun %pad-right (str width)
  "STR right-justified in WIDTH columns (character count, not display width —
the gutter is digits and spaces, so the two agree)."
  (let ((w (length str)))
    (if (>= w width)
        str
        (concatenate 'string (make-string (- width w) :initial-element #\space)
                     str))))

(defun %emphasize (text base-style spans)
  "TEXT to a list of (cons TEXT STYLE) segments, with the character ranges in
SPANS (a list of (start end)) getting BASE-STYLE plus bold+underline. NIL
SPANS gives one segment."
  (if (null spans)
      (list (cons text base-style))
      (let ((emph-style (append base-style +diff-emphasis+))
            (out nil)
            (at 0))
        (dolist (span spans)
          (let* ((s (min (first span) (length text)))
                 (e (min (second span) (length text))))
            (when (>= s at)
              (when (> s at)
                (push (cons (subseq text at s) base-style) out))
              (when (> e s)
                (push (cons (subseq text s e) emph-style) out))
              (setf at e))))
        (when (< at (length text))
          (push (cons (subseq text at) base-style) out))
        (nreverse out))))

(defun %row-lines (row old new width numw emph old-base new-base line-numbers)
  "One hunk row to segment lines, wrapped to WIDTH. The gutter takes the
line's own foreground on a changed row and stays dim on a context row; the
first wrapped line carries the sign, continuations keep the colour and lose
it, so the eye does not read a wrap as a second changed line."
  (let ((sign nil) (role nil) (text nil) (old-num nil) (new-num nil))
    (case (first row)
      (:context (setf sign " " role :plain
                     text (elt old (second row))
                     old-num (+ old-base (second row) 1)
                     new-num (+ new-base (third row) 1)))
      (:removed (setf sign "-" role :removed
                     text (elt old (second row))
                     old-num (+ old-base (second row) 1)))
      (:added (setf sign "+" role :added
                   text (elt new (second row))
                   new-num (+ new-base (second row) 1))))
    ;; **ONE column, carrying the line's number IN ITS OWN FILE**: the old file's
    ;; on a deletion and on a context row, the new file's on an addition. Two
    ;; columns print a number beside a blank on every changed line — `-` has no new
    ;; number and `+` has no old one — so half the gutter was empty exactly where
    ;; the reader is looking, and collapsing them is the point: a row always says
    ;; which line of SOME file it is.
    ;;
    ;; Right-aligned, and `numw` still spans BOTH files' numbering even though one
    ;; column is drawn, because that column carries either: a file that grew past
    ;; the other's last line would otherwise truncate its own numbers.
    ;;
    ;; `body-w` and the continuation's blank prefix both derive from
    ;; `(string-width gutter)`, so the body gains `numw + 1` columns and the prefix
    ;; narrows to match without either number appearing here.
    (let* ((num (if (eq (first row) :added) new-num old-num))
           (gutter (if line-numbers
                       (format nil "~a " (%pad-right (if num
                                                         (format nil "~d" num)
                                                         "")
                                                     numw))
                       ""))
           (body-w (max 8 (- width (string-width gutter) 1)))
           (fg (case role (:added :green) (:removed :red) (t nil)))
           (gut-style (if (eq role :plain) '(:dim t) (when fg (list :fg fg))))
           (sign-style (when fg (list :fg fg)))
           (base-style (case role (:added +diff-added-bg+)
                                (:removed +diff-removed-bg+)
                                (t nil)))
           (body-segs (%emphasize (expand-tabs text 4) base-style emph))
           (wrapped (or (wrap-segments body-segs body-w)
                        (list (list (cons "" nil))))))
      (let ((gutter-segs (if (string= gutter "")
                             nil
                             (list (cons gutter gut-style))))
            (cont-prefix (cons (make-string (1+ (string-width gutter))
                                            :initial-element #\space)
                               '(:dim t))))
        (cons (append gutter-segs (list (cons sign sign-style)) (first wrapped))
              (mapcar (lambda (l) (cons cont-prefix l)) (rest wrapped)))))))

;; ----------------------------------------------------------------- render ;;;

(defun render-diff (old new &key (width 100) (context 3) (line-numbers t)
                    (intra-line t) (max-rows 60) (old-start 1) (new-start 1))
  "A unified diff of OLD and NEW (sequences of strings) as segment lines.
OLD-START and NEW-START are the 1-based lines of the whole files the two
slices begin at, so the gutter and the hunk headers number the file and not
the excerpt."
  (let* ((old (coerce old 'vector))
         (new (coerce new 'vector))
         (old-base (max 0 (1- old-start)))
         (new-base (max 0 (1- new-start)))
         (d (diff-lines old new))
         (hs (hunks d context)))
    (cond
      ((null hs)
       (list (list (cons "no change" '(:dim t)))))
      (t
       (let* ((numw (if line-numbers
                        (length (format nil "~d"
                                         (max 1 (+ old-base (length old))
                                              (+ new-base (length new)))))
                        0))
              (out (if (diff-degraded d)
                       (list (list (cons
                                    "! diff gave up on the minimal edit script; the changed region is shown as a whole replacement"
                                    '(:bold t :fg :yellow))))
                       nil))
              (rows-left max-rows)
              (dropped 0))
         (loop for h in hs
               for hi from 0
               do (when (or (plusp hi) (plusp (1- (length hs))))
                    (let ((count-old (count-if (lambda (r) (member (first r) '(:context :removed)))
                                                (getf h :rows)))
                          (count-new (count-if (lambda (r) (member (first r) '(:context :added)))
                                                (getf h :rows))))
                      (setf out (append out
                                        (list (list (cons
                                                     (format nil "@@ -~a,~a +~a,~a @@"
                                                             (+ old-base (getf h :old-start) 1)
                                                             count-old
                                                             (+ new-base (getf h :new-start) 1)
                                                             count-new)
                                                     '(:dim t))))))))
               (let ((paired (if intra-line (%pair-rows (getf h :rows) old new) nil)))
                 (loop for r in (getf h :rows)
                       for ri from 0
                       do (if (zerop rows-left)
                              (incf dropped)
                              (progn
                                (decf rows-left)
                                (let ((emph (when paired (aref paired ri))))
                                  (setf out (append out
                                                    (%row-lines r old new width numw
                                                                emph old-base new-base
                                                                line-numbers)))))))))
         (when (plusp dropped)
           (setf out (append out
                             (list (list (cons
                                          (format nil "… ~a more diff lines not shown" dropped)
                                          '(:dim t)))))))
         out)))))

;; ------------------------------------------------------- apply (for tests) ;;;

(defun apply-diff-to-new (ops new)
  "Apply the edit script to NEW: the Equal and Insert lines, in order. The
property that makes a diff trustworthy — apply it and you get the new file."
  (loop for op across ops
        when (not (eq (first op) :delete))
        collect (elt new (if (eq (first op) :equal) (third op) (second op)))))

(defun apply-diff-to-old (ops old)
  "The inverse: the Equal and Delete lines give the old file back."
  (loop for op across ops
        when (not (eq (first op) :insert))
        collect (elt old (second op))))
