;;;; width.lisp — per-character display width, ported from
;;;; crates/ui/src/width.rs (is_zero_width / is_wide / char_width). The Rust
;;;; file's own doc comment is the design rationale: a char is not a column,
;;;; and the failure mode of a miss is a line one column narrow, once.
;;;;
;;;; This is the per-character table only. Cluster handling (ZWJ sequences,
;;;; regional-indicator pairs, escape-aware walking) is a render-layer concern
;;;; and arrives with T19/T20; TODO.md keeps that half open on purpose.

(in-package #:leticl)

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
  "Columns one character claims, standing alone: zero, one or two. C0/C1 and
DEL are zero — a head should never be measuring these (width.rs:191)."
  (let ((u (char-code ch)))
    (cond ((or (< u #x20) (and (>= u #x7f) (< u #xa0))) 0)
          ((%in-ranges-p *zero-width-ranges* u) 0)
          ((%in-ranges-p *wide-ranges* u) 2)
          (t 1))))

(defun string-width (string)
  "Columns a string occupies, escapes excluded. Per-character for now; the
cluster-aware, escape-aware version arrives with the markdown/diff ports."
  (let ((w 0))
    (map nil (lambda (ch) (incf w (char-width ch))) string)
    w))
