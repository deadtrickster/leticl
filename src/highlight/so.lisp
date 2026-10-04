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
  "Where the shim lives, in the order a head should look for it.

  1. **`$LETICL_HL_SO`** — an explicit override, always first;
  2. **beside the running image** — the INSTALL case, and it was missing. `install.sh` puts
     `libleticl_hl.so` in the same directory as `leticl-head`, so the two are siblings and the
     head can find its own shim without being told where it is;
  3. the two build paths, relative to the CHECKOUT, then rano's own build tree — the
     developer's case, where the shim is a build product and the head runs from the repo.

**WHY 2 EXISTS, MEASURED.** The first cut had only (1) and (3), and (3)'s paths are relative to
whatever directory the head happens to run IN — a person runs `leticl` in their project folder,
not in leticl's checkout, so `native/hl/target/release/…` never resolved for them. The third
candidate was an absolute path into the author's rano tree, which is the crate that could not
build off this box at all. So on every install the shim was present and never found, and the
head ran uncoloured without saying anything — the silent-degradation shape, from a lookup that
knew only how to find a developer's build.

`sb-ext:*runtime-pathname*` is the image's own path, which is exactly what is needed: it answers
*where am I installed* rather than *where was I started from*. **It is a global LEXICAL variable and
cannot be `let`-bound** — MEASURED, by trying, and the compiler's own words are that it *names a
global lexical variable, and cannot be used in LET* — which is why the sibling lookup is its own
function taking the path. A test cannot fake the running image's pathname, so it passes one to `%shim-beside` instead."
  (or (uiop:getenv "LETICL_HL_SO")
      (%shim-beside sb-ext:*runtime-pathname*)
      (first (remove-if-not (lambda (p) (uiop:file-exists-p (merge-pathnames p)))
                            '("native/libleticl-hl.so"
                              "native/hl/target/release/libleticl_hl.so"
                              "hl-target/release/libleticl_hl.so"
                              "/home/dead/Projects/rano/rano/target/release/libleticl_hl.so")))))

(defun %shim-beside (image-path)
  "The shim sitting next to IMAGE-PATH as a namestring, or NIL.

**Its own function so it can be tested.** `sb-ext:*runtime-pathname*` is a global lexical and cannot
be bound, so a test cannot pretend to be an image installed somewhere — but it CAN hand this function
the path such an image would have. That is the difference between an assertion and a hope: the install
case was broken for months precisely because nothing could exercise it."
  (let ((p (ignore-errors
            (merge-pathnames "libleticl_hl.so"
                             (uiop:pathname-directory-pathname image-path)))))
    (and p (uiop:file-exists-p p) (namestring p))))

(defun hl-available-p ()
  "T when the shim is loaded (loading it once, on first ask). NIL = uncoloured."
  (unless *hl-attempted*
    (setf *hl-attempted* t)
    (let ((path (hl-so-path)))
      (when path
        (setf *hl-so* (ignore-errors (sb-alien:load-shared-object (namestring path)))))))
  (not (null *hl-so*)))

