;;;; edit-card.lisp — the EDIT card: the excerpt a file change carries, and the diff
;;;; it is drawn as.
;;;;
;;;; **What is NOT here is the decision to draw a diff**, and that is R35 rather than an
;;;; omission: the trigger is the EXCERPT PRIORITY, not the tool name — `bash` editing one
;;;; file under a heredoc carries the same excerpt and gets the same card. So the class
;;;; and its diff live here, and `%tool-result-lines`/`call-lines` (the two rows that can
;;;; show it) ask `(and edit ...)`, one guard each, deliberately.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defclass edit-card    (tool-result-card) ())

(defun %edit-lines-text (text)
  "TEXT as a list of lines. An empty side is NO lines, not one empty line:
a pure insertion has no `before`, and rendering that as a blank line claims a
line was there (`ToolEditExcerpt::before` — \"empty when the side has no lines
in the range\")."
  ;; and ONE trailing empty is dropped, as `str::lines()` does: the unified card
  ;; drew a signed, numbered blank row at the foot of every diff whose side ended
  ;; in a newline, claiming a line that is not in the file. `%lines-of` is the
  ;; one rule; this is its caller, not a second copy of it.
  (%lines-of text))

(defun %subject-names-path-p (subject path)
  "Does the row's own SUBJECT name this PATH — so the diff below it must not repeat it?

**ONE FILE, ONE NAME.** MEASURED on the operator's screen (2026-10-04): their `write` row drew
`Wrote \"<path>\"` and the diff drew `  <path> (new)` in cyan directly under it — the same string
twice, the second time in the loudest style on the frame. The header is the row a reader reads; the
diff's job is the CHANGE.

**AND THE ROW THAT STILL NEEDS IT IS WHY THIS IS A PREDICATE RATHER THAN A DELETION.** A `bash`
command that edited a file in passing is a row whose subject is the COMMAND — `Ran \"python3 - <<'PY'…\"`
— and the file is named NOWHERE else on that card. Stripped of the quoting a path argument is drawn
with, the subject must LEAD with the path: that is exactly what `display-target` composes for a write
or an edit, and it cannot be true of a command that merely mentions the file in the middle."
  (let ((s (string-trim "\"" (or subject ""))))
    (and (plusp (length path))
         (>= (length s) (length path))
         (string= path (subseq s 0 (length path))))))

(defun edit-lines (edit cols &key (folded nil) (split nil) (subject nil))
  "The diff of an EDIT, as segment lines.

This is the twice-requested diff, and it is why `render-diff` exists: the edit
carries both sides and the excerpt's place in each file, so the engine can show
hunks with context, line numbers, and word-level emphasis inside a changed line.
The old version printed every removed line and then every added line —
unnumbered, unemphasised, no context and no notion of what actually changed —
which is what the operator reported as *\"nothing really shown\"*.

`before_start`/`after_start` are 1-based lines of the WHOLE file, so the gutter
numbers the file and not the excerpt (\"a diff numbered from 1 tells the reader
line 4 changed when it was line 313\").

**AND THE DIFF DOES NOT LABEL A FILE THE CARD HAS ALREADY NAMED.** The card's header carries it —
`Wrote \"<path>\"`, the row a reader reads — and a second copy in bold cyan on the row directly under
it is the same string twice, the second time in the loudest style on the frame. The screen that said
so is quoted in `*body-keys*` (their 2026-10-04 report: the header's subject was the file's BODY, so
the path appeared only here).

**IT IS A CONDITION AND NOT A DELETION, because one card still needs it**: a `bash` row whose subject
is the COMMAND — `Ran \"python3 - <<'PY'…\"` — names the file nowhere else. `%subject-names-path-p`
answers whether THIS card has already named it; a caller that passes no `:subject` (a test, a pane)
gets the row, which is the old behaviour and the safe direction. What a reader needs from a diff is
the CHANGE; the file is named above it when the row knows its name."
  (when edit
    (let* ((path (getf edit :path))
           (created (getf edit :created))
           ;; **THE CARD THAT ALREADY NAMED THE FILE DOES NOT DRAW IT AGAIN** — see
           ;; `%subject-names-path-p`, and note that the row is KEPT for a caller that passes no
           ;; subject (a test, a pane) and for a bash row, whose subject is the command.
           (head-line
             (unless (%subject-names-path-p subject path)
               (list (list (cons (format nil "  ~a~a" path
                                         (if created " (new)" ""))
                                 '(:bold t :fg :cyan))))))
           (body (if split
                     ;; the two-panel view, when the operator has asked for it
                     ;; (`/config`'s diff row): before on the left, after on the
                     ;; right, the sign column carrying the change
                     (edit-split-lines edit cols)
                     (render-diff (%edit-lines-text (or (getf edit :before) ""))
                              (%edit-lines-text (or (getf edit :after) ""))
                              :width (max 20 (- cols 4))
                              :context 3
                              :line-numbers t
                              ;; **Both reference call sites pass `intra_line:
                              ;; false`** (app.rs:8817, 9934). The wiring for word
                              ;; emphasis was dead here — `%pair-rows` bound
                              ;; `add-start` after consuming the addition run —
                              ;; and fixing that made this head start emitting
                              ;; emphasis the reference deliberately suppresses.
                              ;; `render-diff`'s own default stays T, matching
                              ;; `DiffConfig::default`; the choice belongs at the
                              ;; call site, which is what the reference's two are.
                              :intra-line nil
                              :max-rows (if folded 8 60)
                              :old-start (or (getf edit :before-start) 1)
                              :new-start (or (getf edit :after-start) 1))))
           (tail (when (getf edit :truncated)
                   (list (list (cons
                                (format nil "  … the excerpt was capped; the file is ~a lines now"
                                        (or (getf edit :after-lines) 0))
                                '(:dim t)))))))
      (append head-line body tail))))




