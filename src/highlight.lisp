;;;; highlight.lisp — syntax colouring through the rano shim (native/hl).
;;;;
;;;; The head is SBCL and CFFI-free; it reaches rano's tree-sitter highlighter
;;;; through a small Rust cdylib called with sb-alien (already in the tree for
;;;; termios). See RANO.md for the ABI and the design. A missing .so is a
;;;; dimmer screen, not a crash: every entry point degrades to uncoloured.

(in-package #:leticl)

;;; ------------------------------------------------------------- the .so ;;;

(sb-alien:define-alien-type hl-u8   (sb-alien:unsigned 8))
(sb-alien:define-alien-type hl-u32  (sb-alien:unsigned 32))
(sb-alien:define-alien-type hl-size (sb-alien:unsigned 64))   ; size_t, 64-bit box
;; A pointer to a byte, for passing Lisp byte vectors across the boundary by
;; SAP. `sap-alien` is a macro that reads the type unquoted, so it needs a
;; defined type symbol, not an inline spec.
(sb-alien:define-alien-type hl-u8-ptr (* hl-u8))

;; Resolved at call time against the loaded shim; guarded by hl-available-p so
;; an absent .so never reaches a lookup.
(sb-alien:define-alien-routine ("hl_detect" %hl-detect) hl-u32
  (path sb-alien:c-string))

(sb-alien:define-alien-routine ("hl_grid" %hl-grid) hl-size
  (src (* hl-u8))
  (src-len hl-size)
  (lang-id hl-u32)
  (out (* hl-u8))
  (out-cap hl-size))

;; defvar: *hl-so* is the handle of the RUNNING head's loaded shim, and a live
;; push of this file would otherwise set it back to nil and silently turn
;; highlighting off (measured: pushing this file did exactly that).
(defvar *hl-so* nil "The loaded shim, or NIL when uncoloured.")
(defvar *hl-attempted* nil)

(defun hl-so-path ()
  "Where the shim lives: $LETICL_HL_SO, else the build outputs, in order."
  (or (uiop:getenv "LETICL_HL_SO")
      (first (remove-if-not (lambda (p) (uiop:file-exists-p (merge-pathnames p)))
                            '("native/libleticl-hl.so"
                              "native/hl/target/release/libleticl_hl.so"
                              "/home/dead/Projects/rano/rano/target/release/libleticl_hl.so")))))

(defun hl-available-p ()
  "T when the shim is loaded (loading it once, on first ask). NIL = uncoloured."
  (unless *hl-attempted*
    (setf *hl-attempted* t)
    (let ((path (hl-so-path)))
      (when path
        (setf *hl-so* (ignore-errors (sb-alien:load-shared-object (namestring path)))))))
  (not (null *hl-so*)))

;;; ------------------------------------------------------------- language ;;;

(defun lang-for (path)
  "The shim's language id for a file path, by rano's extension table. 0 = none."
  (if (hl-available-p)
      (%hl-detect path)
      0))

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

;;; -------------------------------------------------------------- roles ;;;

(defun role-style (role)
  "A role index to a style plist; 0 (plain) is NIL, the default style. The
index → colour decision lives here, in the head, not in the parser."
  (case role
    (0 nil)
    (1 '(:dim t))   ; comment
    (2 '(:fg :green))          ; string
    (3 '(:fg :bright-yellow))  ; number / constant
    (4 '(:fg :cyan))           ; type
    (5 '(:fg :magenta))        ; keyword
    (6 '(:fg :bright-cyan))    ; function
    (t nil)))

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
  "Tabs in S to the next CHARACTER stop.

`sidediff.rs:398-402` counts the stop in characters, not display columns, and
this path must agree with it: the class grid has one entry per character, so a
stop measured in columns would slide the classes off the text it describes the
first time a panel holds a CJK glyph. `diff.lisp`'s `expand-tabs` measures
columns, which is the right answer for the unified view, where nothing is
indexing the line."
  (if (null (position #\tab s))
      s
      (let ((out (make-string-output-stream)))
        (loop for i from 0 below (length s)
              for ch = (char s i)
              do (if (char= ch #\tab)
                     (write-string (make-string (- (* (1+ (floor i stop)) stop) i)
                                                :initial-element #\space)
                                   out)
                     (write-char ch out)))
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

;;; ------------------------------------------------------------- lines ;;;

(defun highlight-lines (source lang-id)
  "SOURCE to a list of lines; each line is a list of (cons TEXT STYLE) segments
with syntax colour. A missing shim, unknown language, or failed parse gives one
plain segment per line — the same thing a Palette::None terminal reads."
  (let ((grid (class-grid source lang-id)))
    (if (null grid)
        (mapcar (lambda (line) (list (cons line nil)))
                (uiop:split-string source :separator '(#\newline)))
        (let ((lines nil)
              (segs nil)
              (buf (make-string-output-stream))
              (role nil))
          (labels ((flush-seg ()
                    (let ((text (get-output-stream-string buf)))
                      (when (plusp (length text))
                        (push (cons text (role-style role)) segs))
                      (setf buf (make-string-output-stream))))
                   (flush-line ()
                     (flush-seg)
                     (push (nreverse segs) lines)
                     (setf segs nil)))
            (loop for i from 0 below (length source)
                  for ch = (char source i)
                  for r = (aref grid i)
                  do (if (char= ch #\newline)
                         (flush-line)
                         (progn
                           (unless (and role (eql role r))
                             (flush-seg)
                             (setf role r))
                           (write-char ch buf))))
            (flush-line)
            (nreverse lines))))))
