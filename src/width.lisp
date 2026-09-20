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
  "SPEC is a list of (lo hi) integer pairs; returns them sorted by LO as ONE flat
`(simple-array fixnum (*))` — lo0 hi0 lo1 hi1 … — for `%in-ranges-p`'s binary
search.

It used to be a simple-vector of conses. Measured with sb-sprof on a 300-frame
render: `%in-ranges-p` was 32% of the frame, and a third of that was
`vector-hairy-data-vector-ref` — the vector's element type was unknown to the
compiler, so every `aref` dispatched at run time, and every `car`/`cdr`/`<` was a
full call on a boxed value. A flat fixnum array is one typed load per probe."
  (let* ((pairs (sort (mapcar (lambda (p) (cons (first p) (second p))) spec) #'< :key #'car))
         (out (make-array (* 2 (length pairs)) :element-type 'fixnum)))
    (loop for (lo . hi) in pairs
          for i from 0 by 2
          do (setf (aref out i) lo (aref out (1+ i)) hi))
    out))

;; Declared, so the compiler knows what `%in-ranges-p` is handed and a `setf`
;; of the wrong shape is refused at the boundary rather than read at (safety 0).
(declaim (type (simple-array fixnum (*)) *zero-width-ranges* *wide-ranges*))

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

(declaim (ftype (function ((simple-array fixnum (*)) fixnum) boolean) %in-ranges-p))
(defun %in-ranges-p (table u)
  "Is code point U inside one of TABLE's (lo hi) pairs? Binary search on the flat
pair array `%ranges` builds.

(safety 0) here is safe because both inputs are guaranteed by the only callers:
TABLE is one of the two arrays this file builds at load, and U is a `char-code`,
so it is a non-negative fixnum. The index arithmetic stays inside
0 ≤ lo ≤ hi < (length table)/2 by construction of the search."
  (declare (optimize (speed 3) (safety 0))
           (type (simple-array fixnum (*)) table)
           (type fixnum u))
  (let ((lo 0)
        (hi (1- (ash (length table) -1))))
    (declare (type fixnum lo hi))
    (loop while (<= lo hi)
          do (let* ((mid (ash (+ lo hi) -1))
                    (k (ash mid 1)))
               (declare (type fixnum mid k))
               (cond ((< u (aref table k)) (setf hi (1- mid)))
                     ((> u (aref table (1+ k))) (setf lo (1+ mid)))
                     (t (return-from %in-ranges-p t)))))
    nil))

;; The byte table covers code points below #x20000: every emoji, every flag half
;; and the whole BMP, which is everything a transcript actually contains; above
;; it — CJK extension B and the variation-selector supplement — the binary search
;; answers. 128 KB is the cost. The bound is written as a LITERAL in the three
;; places it is used rather than as a defconstant, because `tui-eval --file`
;; skips defconstant forms (HACKING.md) and a live push of this file into a head
;; built before it would then leave the leaf reading an unbound name.

(defun %c1-control-p (u)
  "C0, C1 and DEL. Zero columns, and never part of the cluster beside them."
  (declare (type fixnum u))
  (or (< u #x20) (and (>= u #x7f) (< u #xa0))))

(defun %build-width-table ()
  "The byte table, DERIVED from the range lists so there is one source of truth:
0 for a control or a zero-width code point, 2 for a wide one, else 1."
  (let ((table (make-array #x20000 :element-type '(unsigned-byte 8)
                                   :initial-element 1)))
    (dotimes (u #x20000 table)
      (setf (aref table u)
            (cond ((%c1-control-p u) 0)
                  ((%in-ranges-p *zero-width-ranges* u) 0)
                  ((%in-ranges-p *wide-ranges* u) 2)
                  (t 1))))))

(declaim (type (simple-array (unsigned-byte 8) (*)) *width-table*))
(defparameter *width-table* (%build-width-table)
  "Columns per code point below #x20000, one byte each.

Static data derived from static data, so `defparameter` is right: re-initialising
it on a live push rebuilds the same bytes (HACKING.md, the note on static data).
Not live state — nothing holds an index into it.")

(declaim (inline %code-width))
(declaim (ftype (function (fixnum) (integer 0 2)) %code-width))
(defun %code-width (u)
  "Columns for code point U, standing alone. The hot leaf of the whole render
path — every character on the screen goes through it at least twice a frame
(measured: 8.9M calls in 300 frames, 46% of the frame before this table).

(safety 0) is safe because U is always a `char-code` — every caller takes it from
a CHARACTER it just read out of a string or a cell — so it is a non-negative
fixnum below `char-code-limit`, and the table probe is guarded by the `< u
#x20000` test, which is the size `%build-width-table` makes the table."
  (declare (optimize (speed 3) (safety 0)) (type fixnum u))
  (cond ((< u #x20) 0)
        ((< u #x7f) 1)
        ((< u #x20000) (aref *width-table* u))
        ((%in-ranges-p *zero-width-ranges* u) 0)
        ((%in-ranges-p *wide-ranges* u) 2)
        (t 1)))

(declaim (ftype (function (character) (integer 0 2)) char-width))
(defun char-width (ch)
  "Columns one character claims, STANDING ALONE: zero, one or two. C0/C1 and DEL
are zero — a head should never be measuring these (width.rs:191). A cluster is
wider than the sum of its parts only in the direction of being NARROWER; see
`cells`.

Default safety here, on purpose: this is the public entry and a caller off the
eval socket may hand it anything. The `character` check is one tag test; the
work is in `%code-width`."
  (declare (type character ch))
  (%code-width (char-code ch)))

;;; ------------------------------------------------------------- clusters ;;;

(defstruct (cluster (:constructor %make-cluster (esc text cols)))
  (esc "" :type string)                 ; escapes carried WITH the cluster
  (text "" :type string)
  (cols 0 :type fixnum))

(declaim (inline %regional-indicator-p))
(defun %regional-indicator-p (ch)
  (declare (type character ch))
  (<= #x1f1e6 (char-code ch) #x1f1ff))

(declaim (ftype (function (simple-string fixnum) fixnum) %skip-escape))
(defun %skip-escape (string i)
  "Index past the escape sequence starting at I.

CSI (`ESC[…` ended by `@`-`~`), OSC (`ESC]…` ended by BEL or ST) and the
two-byte forms. An UNTERMINATED sequence consumes the rest, which is the right
answer for a partially-arrived frame: it is not content.

Typed but at default safety: the string was checked by `%simple` at the entry
above it, and the cost of the remaining checks is nothing beside the render."
  (declare (type simple-string string) (type fixnum i))
  (let ((n (length string)))
    (if (>= (1+ i) n)
        n
        (case (schar string (1+ i))
          (#\[ (loop for j of-type fixnum from (+ i 2) below n
                     when (<= #x40 (char-code (schar string j)) #x7e)
                       return (min n (1+ j))
                     finally (return n)))
          (#\] (loop for j of-type fixnum from (+ i 2) below n
                     when (char= (schar string j) (code-char 7)) return (1+ j)
                     when (and (char= (schar string j) +esc+)
                               (< (1+ j) n)
                               (char= (schar string (1+ j)) #\\))
                       return (+ j 2)
                     finally (return n)))
          (t (min n (+ i 2)))))))

(declaim (inline %simple))
(defun %simple (string)
  "STRING as a `simple-string`, which is what the walkers below are typed on.

Every string this head renders is already simple — `subseq`, `concatenate`,
`format nil`, `make-string` and the JSON decoder all produce one — so this is a
type test that almost never copies. The test is what lets the loops run on a
declared type, and it is the boundary the (safety 0) walkers rely on.

NIL is the empty string, as it was when `clusters` took `(length nil)`: a wire
plist with a key missing puts NIL in a segment (`secret-card-lines` and
`(getf req :command)`), and that must stay a row with nothing on it rather than
a render failure."
  (cond ((simple-string-p string) string)
        ((null string) "")
        (t (coerce string 'simple-string))))

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
because dropping it would leave attributes open on the terminal.

`string-width` and `screen-put-string` no longer call this on the common case:
it conses a struct and two `subseq`s per cluster, and at 3.5M clusters per 300
frames that was 56% of the frame. It remains THE definition of a cluster — the
one-pass walkers mirror its rules and are tested against it — and it is what
`truncate-to-width` and the wide-character path of the painter still use."
  (let* ((string (%simple string))
         (n (length string))
         (out nil)
         (i 0))
    (declare (type simple-string string) (type fixnum n i))
    (loop while (< i n) do
      (let* ((esc-start i))
        (loop while (and (< i n) (char= (schar string i) +esc+))
              do (setf i (%skip-escape string i)))
        (let ((esc (subseq string esc-start i)))
          (if (>= i n)
              (when (plusp (length esc))
                (push (%make-cluster esc "" 0) out))
              (let ((cluster-start i)
                    (cols 0)
                    (prev-ri nil)
                    (first t))
                (declare (type fixnum cluster-start cols))
                (loop while (< i n) do
                  (let ((ch (schar string i)))
                    (if (char= ch +esc+)
                        (return)
                        (let ((w (%code-width (char-code ch))))
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
                            ((char= (schar string (1- i)) +esc-zwj+)
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

(declaim (ftype (function (simple-string fixnum fixnum) fixnum) %width-between))
(defun %width-between (string start end)
  "Columns of STRING between START and END, by the cluster rules, in ONE pass and
with NO consing. This is `clusters` with the struct left out: the same three
rules (control, ZWJ, flag), the same escape skipping, and the width of each
cluster added as the cluster closes. A test (`string-width-agrees-with-clusters`)
holds the two to the same answer on the tricky strings.

Measured on the frame benchmark (2000 items, 210×63, 200 frames): `string-width`
through `clusters` was 41% of the frame and 53% of `markdown-lines`; corpus (c) —
100k widths of a 200-character mixed string — went from 2158 ms to 65 ms.

(safety 0) is safe because the entry (`string-width`) coerces the argument to a
`simple-string` and passes its own bounds: START and END are 0 ≤ START ≤ END ≤
(length STRING), and a simple-string's length cannot change under the loop. Every
index read here is either I in [START, END) or (1- I) with I > START."
  (declare (optimize (speed 3) (safety 0))
           (type simple-string string)
           (type fixnum start end))
  (let ((total 0) (i start))
    (declare (type fixnum total i))
    (loop while (< i end) do
      ;; escapes: none of them a column
      (loop while (and (< i end) (char= (schar string i) +esc+))
            do (setf i (min end (%skip-escape string i))))
      (when (>= i end) (return))
      ;; a cluster: its first character sets the width, the rest may only
      ;; join (ZWJ), pair (flag) or extend (zero-width, not a control)
      (let* ((ch (schar string i))
             (cols (%code-width (char-code ch)))
             (prev-ri (%regional-indicator-p ch)))
        (declare (type fixnum cols))
        (incf i)
        (loop while (< i end) do
          (let ((ch (schar string i)))
            (when (char= ch +esc+) (return))
            (let ((w (%code-width (char-code ch))))
              (cond ((and prev-ri (%regional-indicator-p ch))
                     (setf cols 2 prev-ri nil) (incf i))
                    ((char= (schar string (1- i)) +esc-zwj+)
                     (setf cols (max cols w)) (incf i))
                    ((zerop w)
                     (if (%c1-control-p (char-code ch)) (return) (incf i)))
                    (t (return))))))
        (incf total cols)))
    total))

(declaim (ftype (function ((or null string) &key (:start fixnum) (:end (or null fixnum))) fixnum)
                string-width))
(defun string-width (string &key (start 0) end)
  "Columns STRING occupies on a terminal, escapes excluded, CLUSTERS measured.

The cluster-aware answer: a ZWJ emoji is one cell of two columns, a flag is two,
and an escape sequence is none — which is what makes a right border land where
the frame put it. START and END bound the measurement so a caller can measure a
word without its trailing space without allocating the trimmed word
(`wrap-segments`).

Default safety: this is the public entry and the boundary the walker's (safety
0) relies on — the argument is coerced to a simple-string here and the bounds
are clamped to it. NIL measures zero, as before."
  (declare (type (or null string) string) (type fixnum start))
  (let* ((s (%simple string))
         (n (length s))
         (end (if end (min (the fixnum end) n) n))
         (start (max 0 start)))
    (declare (type simple-string s) (type fixnum n end start))
    (if (>= start end) 0 (%width-between s start end))))

(declaim (ftype (function ((or null string)) boolean) plain-columns-p))
(defun plain-columns-p (string)
  "Is every character of STRING one plain column — no escape, nothing wide,
nothing zero-width — so that its width is its length and character K sits in
column K?

The question the painter asks before it walks clusters at all: measured, 463
`screen-put-string`s a frame, and nearly every one of them a run of letters and
box-drawing glyphs. A string that answers yes is placed one cell per character,
which is what the cluster rules reduce to when no character can join, pair or
extend the one before it.

Default safety: the entry coerces and the loop's index is bounded by the length."
  (declare (type (or null string) string))
  (let* ((s (%simple string))
         (n (length s)))
    (declare (type simple-string s) (type fixnum n))
    (loop for i of-type fixnum from 0 below n
          always (let ((ch (schar s i)))
                   (and (char/= ch +esc+)
                        (= 1 (%code-width (char-code ch))))))))

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
