;;;; width.lisp — display width, ported from crates/ui/src/width.rs.
;;;;
;;;; **A character is not a column, and a character is not a cell either.** An
;;;; emoji is a ZWJ sequence of several code points; a flag is two regional
;;;; indicators; an accented letter may be a base plus a combining mark. Measured
;;;; per CHARACTER, `👨‍👩‍👧` is six columns and a flag is four — and the failure
;;;; mode of a miss is not an error but a line that is wrong by a few columns,
;;;; which in a frame with a right border is a border drawn through the text.
;;;;
;;;; So the unit is the ESCAPE-PREFIXED GRAPHEME CLUSTER, as the reference's
;;;; `clusters()` has it.

(in-package #:leticl)

(defparameter +esc-zwj+ (code-char #x200d)
  "ZERO WIDTH JOINER. Named because `#\\u200d` is not reader syntax on this box;
`(code-char #x200d)` is.")
(defparameter +zwsp+ (code-char #x200b))   ; not used yet; here so it is named

(defun %ranges (spec)
  "SPEC is a list of (lo hi) integer pairs; returns a sorted simple-vector of
conses for binary search."
  (let ((pairs (sort (mapcar (lambda (p) (cons (first p) (second p))) spec) #'< :key #'car)))
    (coerce pairs 'simple-vector)))

(defparameter *zero-width-ranges*
  (%ranges
   '((#x0300 #x036f)      ; combining diacritical marks
     (#x0483 #x0489)      ; Cyrillic combining
     (#x0591 #x05bd) (#x05bf #x05bf) (#x05c1 #x05c2) (#x05c4 #x05c5) (#x05c7 #x05c7)
     (#x0610 #x061a) (#x064b #x065f) (#x0670 #x0670)
     (#x06d6 #x06dc) (#x06df #x06e4) (#x06e7 #x06e8) (#x06ea #x06ed)
     (#x0900 #x0903) (#x093a #x093c) (#x0941 #x0948) (#x094d #x094d)
     (#x0951 #x0957) (#x0962 #x0963)
     (#x0e31 #x0e31) (#x0e34 #x0e3a) (#x0e47 #x0e4e)   ; Thai
     (#x1ab0 #x1aff)      ; combining extended
     (#x1dc0 #x1dff)      ; combining supplement
     (#x200b #x200f)      ; ZWSP, ZWNJ, ZWJ, LRM, RLM
     (#x2028 #x202e)      ; line/para separators, bidi overrides
     (#x2060 #x2064)      ; word joiner, invisible operators
     (#x20d0 #x20f0)      ; combining marks for symbols
     (#xfe00 #xfe0f)      ; variation selectors
     (#xfe20 #xfe2f)      ; combining half marks
     (#xfeff #xfeff)      ; BOM / ZWNBSP
     (#xe0100 #xe01ef)))) ; variation selectors supplement

(defparameter *wide-ranges*
  (%ranges
   '((#x1100 #x115f)      ; Hangul Jamo initial
     (#x231a #x231b) (#x23e9 #x23ec) (#x23f0 #x23f0) (#x23f3 #x23f3)
     (#x25fd #x25fe) (#x2614 #x2615) (#x2648 #x2653)
     (#x267f #x267f) (#x2693 #x2693) (#x26a1 #x26a1) (#x26aa #x26ab) (#x26bd #x26be)
     (#x26c4 #x26c5) (#x26ce #x26ce) (#x26d4 #x26d4) (#x26ea #x26ea) (#x26f2 #x26f3)
     (#x26f5 #x26f5) (#x26fa #x26fa) (#x26fd #x26fd) (#x2705 #x2705) (#x270a #x270b)
     (#x2728 #x2728) (#x274c #x274c) (#x274e #x274e) (#x2753 #x2755) (#x2757 #x2757)
     (#x2795 #x2797) (#x27b0 #x27b0) (#x27bf #x27bf) (#x2b1b #x2b1c) (#x2b50 #x2b50)
     (#x2b55 #x2b55)
     (#x2e80 #x2e99) (#x2e9b #x2ef3)   ; CJK radicals
     (#x2f00 #x2fd5)      ; Kangxi radicals
     (#x2ff0 #x2ffb)      ; ideographic description
     (#x3000 #x303e)      ; CJK symbols and punctuation
     (#x3041 #x3096) (#x3099 #x30ff)   ; kana
     (#x3105 #x312f) (#x3131 #x318e) (#x3190 #x31e3)
     (#x31f0 #x321e) (#x3220 #x3247) (#x3250 #x4dbf)
     (#x4e00 #xa48c)      ; CJK unified ideographs, Yi
     (#xa490 #xa4c6)
     (#xa960 #xa97c)      ; Hangul Jamo extended-A
     (#xac00 #xd7a3)      ; Hangul syllables
     (#xf900 #xfaff)      ; CJK compatibility ideographs
     (#xfe10 #xfe19) (#xfe30 #xfe52) (#xfe54 #xfe66) (#xfe68 #xfe6b)
     (#xff01 #xff60)      ; fullwidth forms
     (#xffe0 #xffe6)
     (#x16fe0 #x16fe4) (#x17000 #x18d08)
     (#x1b000 #x1b2fb)
     (#x1f004 #x1f004) (#x1f0cf #x1f0cf) (#x1f18e #x1f18e) (#x1f191 #x1f19a)
     (#x1f1e6 #x1f1ff)    ; regional indicators, paired into flags at cluster level
     (#x1f200 #x1f320) (#x1f32d #x1f335) (#x1f337 #x1f37c)
     (#x1f37e #x1f393) (#x1f3a0 #x1f3ca) (#x1f3cf #x1f3d3)
     (#x1f3e0 #x1f3f0) (#x1f3f4 #x1f3f4) (#x1f3f8 #x1f43e) (#x1f440 #x1f440)
     (#x1f442 #x1f4fc) (#x1f4ff #x1f53d) (#x1f54b #x1f54e)
     (#x1f550 #x1f567) (#x1f57a #x1f57a) (#x1f595 #x1f596) (#x1f5a4 #x1f5a4)
     (#x1f5fb #x1f64f) (#x1f680 #x1f6c5) (#x1f6cc #x1f6cc)
     (#x1f6d0 #x1f6d2) (#x1f6d5 #x1f6d7) (#x1f6eb #x1f6ec)
     (#x1f6f4 #x1f6fc) (#x1f7e0 #x1f7eb)
     (#x1f90c #x1f93a) (#x1f93c #x1f945) (#x1f947 #x1f9ff)
     (#x1fa70 #x1faff)
     (#x20000 #x3fffd)))) ; CJK extension B and beyond

(defun %in-ranges-p (table u)
  (let ((lo 0) (hi (1- (length table))))
    (loop
      while (<= lo hi)
      for mid = (floor (+ lo hi) 2)
      for pair = (aref table mid)
      do (cond ((< u (car pair)) (setf hi (1- mid)))
               ((> u (cdr pair)) (setf lo (1+ mid)))
               (t (return-from %in-ranges-p t))))
    nil))

(defun char-width (ch)
  "Columns one character claims, STANDING ALONE: zero, one or two. C0/C1 and DEL
are zero — a head should never be measuring these (width.rs:191). A cluster is
wider than the sum of its parts only in the direction of being NARROWER; see
`cells`."
  (let ((u (char-code ch)))
    (cond ((%c1-control-p u) 0)
          ((%in-ranges-p *zero-width-ranges* u) 0)
          ((%in-ranges-p *wide-ranges* u) 2)
          (t 1))))

;;; ------------------------------------------------------------- clusters ;;;

(defstruct (cluster (:constructor %make-cluster (esc text cols)))
  (esc "" :type string)                 ; escapes carried WITH the cluster
  (text "" :type string)
  (cols 0 :type fixnum))

(defun %c1-control-p (u)
  "C0, C1 and DEL. Zero columns, and never part of the cluster beside them."
  (or (< u #x20) (and (>= u #x7f) (< u #xa0))))

(defun %regional-indicator-p (ch)
  (<= #x1f1e6 (char-code ch) #x1f1ff))

(defun %skip-escape (string i)
  "Index past the escape sequence starting at I.

CSI (`ESC[…` ended by `@`-`~`), OSC (`ESC]…` ended by BEL or ST) and the
two-byte forms. An UNTERMINATED sequence consumes the rest, which is the right
answer for a partially-arrived frame: it is not content."
  (let ((n (length string)))
    (if (>= (1+ i) n)
        n
        (case (char string (1+ i))
          (#\[ (loop for j from (+ i 2) below n
                     when (<= #x40 (char-code (char string j)) #x7e)
                       return (min n (1+ j))
                     finally (return n)))
          (#\] (loop for j from (+ i 2) below n
                     when (char= (char string j) (code-char 7)) return (1+ j)
                     when (and (char= (char string j) +esc+)
                               (< (1+ j) n)
                               (char= (char string (1+ j)) #\\))
                       return (+ j 2)
                     finally (return n)))
          (t (min n (+ i 2)))))))

(defun clusters (string)
  "STRING to a list of `cluster`s: escape-prefixed grapheme clusters, in order.

A cluster begins at the first character that occupies a column and EXTENDS with
anything that does not. Three rules, each one the reference states and each one a
bug it had:

  · a **control character is not a combining mark.** A newline measures zero
    columns for the same reason a combining mark does, and that is the whole of
    the resemblance: absorbing one into the cluster before it hides a row break
    inside a cell, and a break inside a cell is not a break — which is how a
    two-line composer once wrapped to one row with a literal newline in it;
  · a **ZWJ joins whatever follows it** into the cluster, which is what makes an
    emoji family one cell of two columns;
  · two **regional indicators** are a flag: two columns however wide each half
    claims to be.

A trailing run of escapes with no text after it becomes an escape-only cell,
because dropping it would leave attributes open on the terminal."
  (let ((n (length string))
        (out nil)
        (i 0))
    (loop while (< i n) do
      (let* ((esc-start i))
        (loop while (and (< i n) (char= (char string i) +esc+))
              do (setf i (%skip-escape string i)))
        (let ((esc (subseq string esc-start i)))
          (if (>= i n)
              (when (plusp (length esc))
                (push (%make-cluster esc "" 0) out))
              (let ((cluster-start i)
                    (cols 0)
                    (prev-ri nil)
                    (first t))
                (loop while (< i n) do
                  (let ((ch (char string i)))
                    (if (char= ch +esc+)
                        (return)
                        (let ((w (char-width ch)))
                          (cond
                            (first
                             (setf cols w
                                   first nil
                                   prev-ri (%regional-indicator-p ch))
                             (incf i))
                            ((and prev-ri (%regional-indicator-p ch))
                             (setf cols 2
                                   prev-ri nil)
                             (incf i))
                            ;; a ZWJ immediately before this one joins it in
                            ((char= (char string (1- i)) +esc-zwj+)
                             (setf cols (max cols w))
                             (incf i))
                            ;; extend with anything that stands alone at zero —
                            ;; but NOT a control character, per the rule above
                            ((zerop w)
                             (if (%c1-control-p (char-code ch))
                                 (return)
                                 (incf i)))
                            (t (return)))))))
                (push (%make-cluster esc (subseq string cluster-start i) cols) out))))))
    (nreverse out)))

;;; ---------------------------------------------------------------- width ;;;

(defun string-width (string)
  "Columns STRING occupies on a terminal, escapes excluded, CLUSTERS measured.

The cluster-aware answer: a ZWJ emoji is one cell of two columns, a flag is two,
and an escape sequence is none — which is what makes a right border land where
the frame put it."
  (let ((w 0))
    (dolist (c (clusters string)) (incf w (cluster-cols c)))
    w))

(defun truncate-to-width (string cols)
  "STRING cut to at most COLS columns, escapes kept whole, no cluster split.

A cluster is never cut in half: half a ZWJ sequence is a different glyph, and half
a flag is a letter. Styles are carried with their cluster, so a cut does not leave
an attribute open."
  (if (<= (string-width string) cols)
      string
      (let ((out (make-string-output-stream))
            (w 0))
        (dolist (c (clusters string))
          (when (> (+ w (cluster-cols c)) cols) (return))
          (write-string (cluster-esc c) out)
          (write-string (cluster-text c) out)
          (incf w (cluster-cols c)))
        (get-output-stream-string out))))

(defun fit-to-width (string cols)
  "STRING padded or truncated to EXACTLY COLS columns."
  (let* ((cut (truncate-to-width string cols))
         (w (string-width cut)))
    (if (< w cols)
        (concatenate 'string cut (make-string (- cols w) :initial-element #\space))
        cut)))
