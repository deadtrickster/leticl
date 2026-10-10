;;;; fences — fenced code: which language, and how it is highlighted
;;;;
;;;; Split out of `markdown.lisp`, which was one 1144-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; -------------------------------------------------------------- fences ;;;

(defparameter *fence-tokens*
  '(("rust" . "rs") ("rs" . "rs")
    ("go" . "go") ("golang" . "go")
    ("sh" . "sh") ("bash" . "sh") ("shell" . "sh") ("zsh" . "sh")
    ("py" . "py") ("python" . "py") ("python2" . "py") ("python3" . "py")
    ("c" . "c") ("h" . "c")
    ("json" . "json")
    ("lisp" . "lisp") ("cl" . "lisp") ("commonlisp" . "lisp") ("common-lisp" . "lisp")
    ("elisp" . "el") ("emacs-lisp" . "el") ("el" . "el")
    ("js" . "js") ("jsx" . "js") ("javascript" . "js") ("mjs" . "js") ("node" . "js")
    ("ts" . "ts") ("typescript" . "ts") ("mts" . "ts") ("cts" . "ts")
    ("tsx" . "tsx")
    ("md" . "md") ("markdown" . "md") ("gfm" . "md")
    ("toml" . "toml")
    ("yaml" . "yaml") ("yml" . "yaml")
    ("html" . "html") ("htm" . "html") ("xhtml" . "html")
    ("xml" . "html") ("svg" . "html")
    ("css" . "css")
    ("lua" . "lua")
    ("rb" . "rb") ("ruby" . "rb")
    ("php" . "php")
    ("java" . "java")
    ("make" . "mk") ("makefile" . "mk") ("gnumakefile" . "mk")
    ("dockerfile" . "dockerfile") ("docker" . "dockerfile")
    ("ini" . "ini") ("cfg" . "ini") ("conf" . "ini") ("properties" . "ini")
    ("editorconfig" . "ini")
    ("diff" . "diff") ("patch" . "diff") ("udiff" . "diff")
    ("scm" . "scm") ("scheme" . "scm") ("ss" . "scm") ("rkt" . "scm")
    ("sql" . "sql") ("psql" . "sql") ("mysql" . "sql") ("plpgsql" . "sql")
    ("clj" . "clj") ("cljs" . "clj") ("cljc" . "clj") ("edn" . "clj")
    ("clojure" . "clj"))
  "(TOKEN . EXTENSION) for every fence language this head colours — the whole
vocabulary, keyed by what a PERSON WRITES, not by what a file is called.

**This is `rano::syntax::Lang::from_token`'s table, and that is the point.**
letibot colours a fence by calling that function (`crates/tui/src/render.rs:217`),
so the two heads agree only if this head answers the same token the same way. The
table is not invented here and must not drift: `from_token` answers every
`Lang::name()`, and vice versa, so a token added on one side and not the other is
the divergence this file exists to prevent.

**Why tokens and not extensions.** `detect` (the path table) and `from_token` (the
token table) overlap and disagree, and rano's own docstring names the cases: `mk`
is Make as an extension and nothing as a token, `py` is Python in both, and `c` is
a letter that is only clear as a language when a fence names it. A fence carries a
NAME, so the token table is the one that applies — a fence saying `make` means Make
and a fence saying `mk` means nothing, which is the opposite of the path table.

The extension column is how the grammar is REACHED: it is fed to the painter's own
extension table as a filename (`fence.rs`), so a grammar this build does not have
resolves to nothing and the fence renders plain. That is deliberate — **a row in a
table claiming a language the painter cannot draw is worse than an honest miss**,
and it is why `xml`/`svg` map to `html` (there is no XML lexer; the HTML grammar is
what colours them in letibot too) while a language rano has no grammar for at all
is simply not in this list.")

(defun fence-token (info)
  "INFO's FIRST WORD as a token: the part that names a grammar.

**First word only, case-insensitively, and the split is on BOTH a comma and
whitespace** — `from_token`'s own rule (`rano/src/syntax.rs:98-104`) and the reason
the doc calls for it: an info string may carry options or a title after the
language (```` ```rust,ignore ````, ```` ```python title=\"x\" ````) and none of that
names a grammar. Ours matched the whole string, so any fence with an attribute fell
through to plain — measured on `` ```rust,ignore ```, which rendered as prose while
letibot coloured it."
  (let* ((comma (position #\, info))
         (head (if comma (subseq info 0 comma) info))
         (sp (position #\space (string-trim '(#\space #\tab) head))))
    (string-downcase (string-trim '(#\space #\tab)
                                  (if sp (subseq head 0 sp) head)))))

(defun fence-grammar-name (info)
  "The grammar that will run over a fence named INFO, or NIL when none will.

**The name of the grammar that RAN, not the token the model typed** — the
reference's rule (`render.rs:296-298,375-379`): `┌─ bash` over a fence written
```` ```sh ````, `┌─ make` over ```` ```makefile ````. Ours printed the raw info
string, so one language read three ways depending on which abbreviation the model
reached for, and a header could claim a grammar that did not run."
  (let* ((token (fence-token info))
         (ext (cdr (assoc token *fence-tokens* :test #'string=))))
    (and ext (plusp (lang-for (format nil "fence.~a" ext)))
         (%grammar-name-for ext))))

(defun %grammar-name-for (ext)
  "The reader-facing name of the grammar reached by EXT.

A second small table because the painter's API answers with an ID, not a name; each
row here is `rano::syntax::Lang::name()` verbatim, which is the string letibot
prints in the same place. It is derived from the extension the token resolved to,
so the two tables cannot disagree about WHICH grammar ran — only about what it is
called."
  (or (cdr (assoc ext '(("rs" . "rust") ("go" . "go") ("sh" . "bash") ("py" . "python")
                        ("c" . "c") ("h" . "c") ("json" . "json") ("lisp" . "lisp")
                        ("el" . "elisp") ("js" . "javascript") ("ts" . "typescript")
                        ("tsx" . "tsx") ("md" . "markdown") ("toml" . "toml")
                        ("yaml" . "yaml") ("html" . "html") ("css" . "css")
                        ("lua" . "lua") ("rb" . "ruby") ("php" . "php")
                        ("java" . "java") ("mk" . "make") ("dockerfile" . "dockerfile")
                        ("ini" . "ini") ("diff" . "diff") ("scm" . "scheme")
                        ("sql" . "sql") ("clj" . "clojure"))
                    :test #'string=))
      ext))

(defun lang-for-fence (info)
  "A fence's language as the highlighter's id. 0 = none.

`hl_detect` takes a PATH (rano's extension table), while a fence carries a NAME, so
the name is resolved to a token here and the token is dressed as a filename. A
token not in `*fence-tokens*` — or one whose grammar this build lacks — gives 0 and
the fence renders plain, which is what an unhighlighted terminal sees anyway."
  (let ((ext (cdr (assoc (fence-token (or info "")) *fence-tokens* :test #'string=))))
    ;; 0, never NIL: `lang-for`'s contract is "0 = none", and a caller that
    ;; arithmetic's the answer (`plusp`) must not get a type error for a fence
    ;; whose language nobody knows. Measured — `(plusp nil)` is how this line
    ;; first failed.
    (if ext (lang-for (format nil "fence.~a" ext)) 0)))

(defun highlight-fence (raw-lines lang)
  "RAW-LINES (strings, oldest first) as styled segments, highlighted as LANG.

**An unhighlightable fence's body is drawn PLAIN**, not dim
(render.rs:190-192,256-258): *\"a wrong colour is worse than none\"*, and dim is
a colour — it says de-emphasised. Every language the shim lacks read as
de-emphasised here, which is the opposite of what a code box is for. The frame,
the `│ ` rail and the header stay faint; the code inside them does not."
  (let* ((source (format nil "~{~a~^~%~}" raw-lines))
         (id (lang-for-fence lang))
         (styled (if (plusp id)
                     (highlight-lines source id)
                     nil)))
    (if styled
        styled
        ;; **A FENCE WITH NO GRAMMAR IS STILL INDENTED CODE.** When `lang-for-fence` answers 0 the
        ;; body was handed straight through, so after `highlight-lines` grew its tab arm a ```go
        ;; block was indented and a ```text or bare fence was not — the two paths disagreeing about
        ;; what a fence body IS, which is the same split that let the bug exist at all: the diff
        ;; path had the tab arm and the fence path never did.
        ;;
        ;; MEASURED before this: `(highlight-fence (list "x" "\ty") "nosuchlang")` gave
        ;; `(("x")) (("\ty"))` — the tab verbatim.
        ;;
        ;; The docstring above already insists the body is drawn PLAIN rather than dim. **Plain
        ;; means uncoloured, not unindented**, and the same 4-stop is used so an unhighlightable
        ;; fence is indented exactly like a highlighted one.
        (mapcar (lambda (l) (list (cons (%expand-tabs-chars l 4) nil))) raw-lines))))

