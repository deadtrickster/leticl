;;;; language — which language a fence is
;;;;
;;;; Split out of `highlight.lisp`, which was one 444-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- language ;;;

(defun lang-for (path)
  "The shim's language id for a file path, by rano's extension table. 0 = none.

**The path is coerced to a SIMPLE-STRING first, and that is not a formality.**
`sb-alien`'s `c-string` conversion binds its argument as a `simple-string`, and a
string that came out of yason is not one — it is the adjustable buffer the parser
filled. Every path a head renders an edit card for arrives that way, so the FIRST
split diff over a real `ToolEditExcerpt` killed the process:

    leticl: The value \"PARITY.md\" is not of type SIMPLE-STRING when binding STRING
    0: (SB-ALIEN::STRING-TO-C-STRING \"PARITY.md\" :UTF-8)
    1: (LETICL::%HL-DETECT \"PARITY.md\")
    2: (LETICL:EDIT-SPLIT-LINES (:PATH \"PARITY.md\" …) 92)

Measured 2026-09-20 by `scripts/compare-1-1` on `tests/fixtures/edit-diff.jsonl`,
which is the first thing in this tree that ever fed a stored edit excerpt to the
card. It is a MAIN-thread error, so with `--disable-debugger` it is not a wrong
card, it is a head that exits. Found by the replay; it was always there.

`coerce` on a string that is already simple returns it, so this costs nothing on
the path where the shim is not reached at all."
  (if (and (hl-available-p) (stringp path))
      (%hl-detect (coerce path 'simple-string))
      0))

