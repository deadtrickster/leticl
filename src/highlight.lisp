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

(defparameter *hl-so* nil "The loaded shim, or NIL when uncoloured.")
(defparameter *hl-attempted* nil)

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

(defun class-grid (source lang-id)
  "A vector of u8 role indices, one per character of SOURCE (newline = 0), or
NIL when the shim is absent, the language is unknown, or the parse failed."
  (when (and (hl-available-p) (plusp lang-id) (plusp (length source)))
    (let* ((bytes (string-to-utf8 source))
           (blen (length bytes))
           (n (length source))
           ;; The shim writes the grid straight into this vector, through its
           ;; SAP — no copy back.
           (out (make-array n :element-type '(unsigned-byte 8) :initial-element 0)))
      (let ((written (%hl-grid (sb-alien:sap-alien (sb-sys:vector-sap bytes) hl-u8-ptr)
                               blen
                               lang-id
                               (sb-alien:sap-alien (sb-sys:vector-sap out) hl-u8-ptr)
                               n)))
        (when (= written n)
          out)))))

;;; -------------------------------------------------------------- roles ;;;

(defun role-style (role)
  "A role index to a style plist; 0 (plain) is NIL, the default style. The
index → colour decision lives here, in the head, not in the parser."
  (case role
    (0 nil)
    (1 '(:fg :bright-black))   ; comment
    (2 '(:fg :green))          ; string
    (3 '(:fg :bright-yellow))  ; number / constant
    (4 '(:fg :cyan))           ; type
    (5 '(:fg :magenta))        ; keyword
    (6 '(:fg :bright-cyan))    ; function
    (t nil)))

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
