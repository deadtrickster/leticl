;;;; markdown.lisp — assistant text to styled lines, to the reference's shape.
;;;;
;;;; A port of the BLOCK MODEL in crates/tui/src/markdown.rs and the renderer in
;;;; crates/tui/src/render.rs (`render_block_with`, `table_lines`, `fit_columns`,
;;;; `render_bounded`), rather than the line-at-a-time scan this file used to be.
;;;; The two differ in exactly the ways a screen comparison found:
;;;;
;;;;   · a paragraph is its LINES JOINED and wrapped to the width it is given —
;;;;     ours emitted one row per source line and never wrapped, so every long
;;;;     paragraph was CUT at the terminal's edge (measured: rows of exactly 210
;;;;     columns with no continuation, where letibot's wrapped to two);
;;;;   · inline markup is a grammar with NESTING: `**`code` in bold**` is a cyan
;;;;     code span inside a bold run, not a bold run with literal backticks;
;;;;   · a heading keeps its hashes, faint, and colours the text BY LEVEL, so
;;;;     the level survives a monochrome pipe;
;;;;   · a table's cells are runs (so `**1.6 s**` in a cell is bold), its
;;;;     columns are measured on the PAINTED text, and they give way wide-first;
;;;;   · blocks are separated by one blank row, whether or not the source had one.
;;;;
;;;; Not a full CommonMark implementation — the Rust file is equally explicit
;;;; about what it skips. Fences are highlighted as a unit, on close.
;;;;
;;;; A LINE is a list of segments; a segment is (string . style-spec) where the
;;;; spec is a plist for style-index. NIL is a blank line. The renderer interns.
;;;;
;;;; Optimisation policy (measured, 2026-09-20): `inline-spans` — the
;;;; per-character scan — is typed; the lexer's classifiers look at one character
;;;; before they copy a line. Everything else here runs once per BLOCK and is left
;;;; at the default policy on purpose: under (speed 3) `render-table`,
;;;; `fit-columns`, `markdown-blocks` and `lang-for-fence` raise notes about
;;;; generic arithmetic and `nth` on short lists, and a 3 KB text renders in
;;;; 0.34 ms with 315 KB consed — the cost is the strings the design makes, not
;;;; the arithmetic between them.

(in-package #:leticl)

(defun appendf-attr (style key value)
  (append style (list key value)))

;;; --------------------------------------------------------------- roles ;;;
;;;
;;; The reference's palette (crates/ui/src/style.rs), as style specs.

(defparameter +md-heading+ '(:bold t :fg :cyan) "Role::Heading — `#`.")
(defparameter +md-subheading+ '(:bold t :fg :blue) "Role::Subheading — `##`.")
(defparameter +md-strong+ '(:bold t) "Role::Strong — `###` and deeper.")
(defparameter +md-faint+ '(:dim t) "Role::Faint — hashes, bullets, rails, rules.")
(defparameter +md-code+ '(:fg :cyan) "InlineStyle::Code.")

