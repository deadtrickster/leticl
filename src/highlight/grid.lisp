;;;; grid — the grid: a highlighted block as cells
;;;;
;;;; Split out of `highlight.lisp`, which was one 444-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; --------------------------------------------------------------- grid ;;;

(defun string-to-utf8 (string)
  "A character string to a vector of UTF-8 bytes. SBCL has no public encoder
  (checked 2.6.0), so this is the small portable one: one to four bytes per
  scalar value."
  (let ((bytes (make-array (max 1 (* 4 (length string)))
                           :element-type '(unsigned-byte 8))))
    (let ((n 0))
      (loop for ch across string
            for u = (char-code ch)
            do (cond
                 ((< u #x80)
                  (setf (aref bytes n) u) (incf n))
                 ((< u #x800)
                  (setf (aref bytes n) (logior #xc0 (ldb (byte 5 6) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 0) u))) (incf n))
                 ((< u #x10000)
                  (setf (aref bytes n) (logior #xe0 (ldb (byte 4 12) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 6) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 0) u))) (incf n))
                 (t
                  (setf (aref bytes n) (logior #xf0 (ldb (byte 3 18) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 12) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 6) u))) (incf n)
                  (setf (aref bytes n) (logior #x80 (ldb (byte 6 0) u))) (incf n))))
      (subseq bytes 0 n))))

;; defvar, not defparameter: a live push of this file must not throw away the
;; running head's memo (and, more sharply, must not reset the call counter a
;; test or a profile is reading).
(defvar *hl-grid-calls* 0
  "How many times the shim's `hl_grid` has actually been entered. The memo below
exists to hold this number down; a test that cannot see the number can only
assert that the answer is the same, which is true with or without the memo.")

(defvar *hl-memo* (make-hash-table :test #'equal)
  "`(lang-id . source)` → the class grid for it, or NIL for \"the shim had no
answer\". See `class-grid` for why this cache needs no invalidation.")

(defparameter +hl-memo-max-chars+ 65536
  "Sources longer than this are not memoised at all. A fence — or a diff
excerpt — is arbitrary size, and a cache with no bound on the VALUE it holds is
a leak with a nicer name. Past this the parse is the cheaper of the two costs
anyway.")

(defparameter +hl-memo-entries+ 64
  "How many grids the memo holds before it is dropped whole.

The bound is on the COUNT as well as the size because both are unbounded
otherwise: a scrolling transcript shows new fences forever. Dropped whole
rather than by least-recent-use because an LRU needs bookkeeping on every hit,
in the render path, to save a re-parse of something that by then is off screen —
and a working set larger than this is a screen nobody is reading twice.")

(defun hl-memo-clear ()
  "Empty the highlight memo. Nothing in a running head needs to call this — the
memo cannot go stale (see `class-grid`) — but a test that counts shim calls
does, and so does anyone measuring a cold parse."
  (clrhash *hl-memo*)
  (values))

(defun %class-grid-uncached (source lang-id)
  "The shim call itself: SOURCE's class grid, or NIL.

**The two vectors are PINNED for the duration of the call.** SBCL's collector
moves objects, and `sb-sys:vector-sap` hands out the address a vector has
*right now*; without `with-pinned-objects` a collection triggered on another
thread — or by the alien call's own stack — may relocate `bytes` or `out` while
the shim is reading and writing through those raw addresses. What that buys is
not a crash: it is the shim writing role indices into whatever Lisp object was
moved into that memory, which is silent heap corruption discovered somewhere
else entirely. `RANO.md` describes the caller-provided output buffer; pinning is
how a *Lisp* vector may be that buffer at all, and is why this code needs no
`sb-alien:make-alien` and no copy back.

The SAPs are taken INSIDE the pinning form on purpose: a SAP computed outside it
is already the wrong answer by the time the form is entered."
  (let* ((bytes (string-to-utf8 source))
         (blen (length bytes))
         (n (length source))
         ;; The shim writes the grid straight into this vector, through its
         ;; SAP — no copy back.
         (out (make-array n :element-type '(unsigned-byte 8) :initial-element 0)))
    (incf *hl-grid-calls*)
    (let ((written (sb-sys:with-pinned-objects (bytes out)
                     (%hl-grid (sb-alien:sap-alien (sb-sys:vector-sap bytes) hl-u8-ptr)
                               blen
                               lang-id
                               (sb-alien:sap-alien (sb-sys:vector-sap out) hl-u8-ptr)
                               n))))
      (when (= written n)
        out))))

(defun class-grid (source lang-id)
  "A vector of u8 role indices, one per character of SOURCE (newline = 0), or
NIL when the shim is absent, the language is unknown, or the parse failed.

**Memoised on `(lang-id . source)`.** The head re-renders the whole viewport
every frame, so every visible fence and every visible diff panel was paying one
tree-sitter parse per frame at 10 Hz for bytes that had not changed. This is the
one cache in the renderer with no invalidation problem: the grid is a pure
function of the source text and the language id, both of which are in the key,
so a stale entry cannot exist — a changed fence is a different key. The bound is
`+hl-memo-max-chars+` and `+hl-memo-entries+`; a NIL answer is memoised too,
because \"this language cannot parse these bytes\" is just as pure and just as
expensive to rediscover."
  (when (and (hl-available-p) (plusp lang-id) (plusp (length source)))
    (if (> (length source) +hl-memo-max-chars+)
        (%class-grid-uncached source lang-id)
        (let ((key (cons lang-id source)))
          (multiple-value-bind (hit foundp) (gethash key *hl-memo*)
            (if foundp
                hit
                (let ((grid (%class-grid-uncached source lang-id)))
                  (when (>= (hash-table-count *hl-memo*) +hl-memo-entries+)
                    (clrhash *hl-memo*))
                  (setf (gethash key *hl-memo*) grid))))))))

