;;;; roles — the roles a token takes
;;;;
;;;; Split out of `highlight.lisp`, which was one 444-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; -------------------------------------------------------------- roles ;;;

(defun role-style (role)
  "A role index to a style plist; 0 (plain) is NIL, the default style. The
index → colour decision lives here, in the head, not in the parser."
  (case role
    (0 nil)
    (1 '(:dim t))   ; comment
    (2 '(:fg :green))          ; string
    ;; the sixteen theme slots, and the REFERENCE'S choice of them
    ;; (style.rs:203-211): a number is `33` and a function name `34`, not their
    ;; bright cousins. Bright slots are a different palette entry in every
    ;; terminal theme, so the same Rust rendered two colours in two panes of one
    ;; screen — the thing one shared table exists to stop.
    (3 '(:fg :yellow))         ; number / constant  (NumberLit, 33)
    (4 '(:fg :cyan))           ; type               (TypeName, 36)
    (5 '(:fg :magenta))        ; keyword            (Keyword, 35)
    (6 '(:fg :blue))           ; function           (FuncName, 34)
    (t nil)))

