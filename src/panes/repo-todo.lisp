;;;; repo-todo.lisp — the repo's own TODO.md as a pane: which checkout, the watcher, the rows
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ----------------------------------------------------- which checkout ;;;
;;;
;;; **THE REPO SECTION IS A SHARED FILE, AND WHICH FILE STOPPED BEING OBVIOUS THE MOMENT WORKTREES
;;; ARRIVED.** The operator's ruling, in their words: *"since we are on git - I'm trying to automate
;;; and set worktrees rules… indeed `<name>/<name>` is a deliberate pattern and then the idea is
;;; basically this - the main workspace `<name>` displays todo from `<name>/<name>` and this is fine
;;; because if i will have agents specific to worktrees i will have workspaces inside
;;; `<name>/<worktree>`."*
;;;
;;; So `<name>/<name>` is the MAIN CHECKOUT and `<name>` is a CONTAINER that holds it, and an agent
;;; seated in a worktree is handed a workspace that IS a checkout. Two questions, no search:
;;;
;;;   1. is the workspace ITSELF a checkout? -> its own `TODO.md`. Covers `leticl`, `stroppy`,
;;;      `stroppy-pfn`, and every agent seated in a worktree;
;;;   2. else is `<workspace>/<basename workspace>` a checkout? -> THAT one. Covers the container:
;;;      `rano` -> `rano/rano`, `letibot` -> `letibot/letibot`;
;;;   3. else the caller NAMES WHERE IT LOOKED — and reads the workspace's own `TODO.md` if there is
;;;      one, which is what this pane did before the rule existed and what keeps a workspace that is
;;;      not a checkout working rather than blank.
;;;
;;; **`basename` IS THE WHOLE OF THE DETERMINISM.** *"The single repo one level down"* is a search
;;; that has to refuse an ambiguity; *the one NAMED AFTER ME* cannot be ambiguous, because the main
;;; checkout is identifiable by NAME.
;;;
;;; **AND NOTHING HERE ENUMERATES WORKTREES, WHICH IS NOT FASTIDIOUSNESS.** MEASURED on this box:
;;; letibot has 19 registered worktrees and AT LEAST FOUR whose directories are GONE (three under
;;; `.claude/worktrees/agent-*`, one at `/tmp/claude-1000/wt2`), so a rule that walked
;;; `git worktree list` would hand out paths that do not exist. This one copes with a layout it does
;;; not know — main at `<name>/<name>`, agent worktrees under `<name>/.claude/worktrees/`, and at
;;; least one worktree (`letibot-profiles`) that is a SIBLING of the container rather than inside it.
;;; `<name>/<worktree>` is the intent; the disk is what the rule has to survive.
;;;
;;; **AND A WORKTREE AGENT READS ITS OWN BRANCH'S `TODO.md`** — the same tracked file as that branch
;;; has it. Two heads on two worktrees can hold different repo sections and both be right, which is
;;; exactly why the pane names WHICH checkout instead of saying "the repo's" and leaving it there.

(defun %workspace-dir (workspace)
  "WORKSPACE with trailing slashes trimmed, so one directory does not have two spellings."
  (string-right-trim "/" (or workspace "")))

(defun %dir-basename (dir)
  "DIR's last path component, or NIL for a path that has none (the root)."
  (let ((base (car (last (pathname-directory (uiop:ensure-directory-pathname dir))))))
    (and (stringp base) base)))

(defun %checkout-root-p (dir)
  "T when DIR is the ROOT of a git checkout — a main checkout, a LINKED WORKTREE, or a submodule.

**`probe-file` AND NOT A DIRECTORY TEST, MEASURED, AND THIS IS THE TRAP.** In a linked worktree
`.git` IS A FILE:

    /home/dead/Projects/letibot-profiles/.git
      -> \"gitdir: /home/dead/Projects/letibot/letibot/.git/worktrees/letibot-profiles\"

so any IS-IT-A-DIRECTORY test answers NOT-A-REPO for EVERY worktree — `test -d` in a shell, `isdir`
in a script, `directoryp` in Lisp — and the operator's table mislabelled `letibot-profiles` for
exactly that reason.

**AND THE MEASURED CORRECTION TO THE WARNING, because the version I was given is narrower than the
trap.** The operator described the trap as `probe-file` on the TRAILING-SLASHED path answering NIL.
**On this SBCL it does NOT** — a trailing slash still resolves a regular file, and this docstring said
otherwise until the test beside it failed by returning the truename. So the trap is the DIRECTORY TEST
and not `probe-file`, which is the right side for this predicate to be wrong on: a bare probe of the
untrailed path answers for a file and for a directory alike, so it cannot be fooled in either
spelling. What must never appear here is `directoryp`, and the test records the `test -d` NO with a
control beside it.

**NOT `git rev-parse --show-toplevel` EITHER — not because it would be wrong, but because of where
this runs.** It agrees with the test above on every checkout measured here, and what it would ADD is
a fork on the pane's draw path. This tree has already priced that: `dash.lisp` and `dashwatch.lisp`
both wrap their child processes in coreutils' `timeout` because `uiop:run-program`'s own `:timeout`
was MEASURED doing nothing, and a `git` that hangs while the pane is drawing is a pane that freezes
with nothing to recover from. It would also answer a DIFFERENT question by walking up —
`rano/rano/src` resolves to `rano/rano` — where the rule asks whether the workspace *itself* is a
checkout. A filesystem test asks exactly that and costs no process."
  (and (plusp (length dir))
       (probe-file (format nil "~a/.git" dir))))

(defun %todo-path-for (dir)
  (format nil "~a/TODO.md" dir))

(defun repo-todo-path (workspace)
  "The `TODO.md` this workspace's repo section reads: `(values PATH ROOT TRIED)`.

PATH is NIL when there is nothing to read. ROOT is the DIRECTORY the file came from — the thing the
pane NAMES, so a reader can tell one worktree's section from another's — and it is NIL only where
PATH is. TRIED is every directory the rule examined, in order, and it comes back on EVERY outcome,
because a refusal that cannot say where it looked is a refusal the operator cannot act on."
  (let* ((ws (%workspace-dir workspace))
         (inner (and (plusp (length ws))
                     (let ((base (%dir-basename ws)))
                       (and base (format nil "~a/~a" ws base))))))
    (cond
      ((zerop (length ws)) (values nil nil nil))
      ((%checkout-root-p ws) (values (%todo-path-for ws) ws (list ws)))
      ((and inner (%checkout-root-p inner))
       (values (%todo-path-for inner) inner (list ws inner)))
      ;; **3. NO CHECKOUT — READ THE WORKSPACE'S OWN FILE IF IT HAS ONE.** This is what the pane did
      ;; before any of this existed, and dropping it would silently blank a workspace that is not a
      ;; checkout: the suite's own fixture is a temp directory holding a `TODO.md` and nothing else,
      ;; and the operator's scratch workspaces are the same shape. It is a FIXED PATH AND NOT A
      ;; SEARCH, so the determinism the rule is built on is untouched — it is the same file the space
      ;; key has always written.
      ((probe-file (%todo-path-for ws)) (values (%todo-path-for ws) ws (list ws)))
      ;; and otherwise say where we looked, NAMING THE NAMESAKE when there was one to name
      (t (values nil nil (if (and inner (probe-file inner)) (list ws inner) (list ws)))))))

(defun repo-todo-checkout (workspace)
  "The directory the repo section is showing, or NIL when it is showing none."
  (nth-value 1 (repo-todo-path workspace)))

(defun %repo-checkout-label (workspace)
  "WHICH checkout the repo section reads, short enough for a heading — or NIL.

`(leticl)` when the workspace IS the checkout and `(rano/rano)` when it is a container, which are the
two cases the rule has. The heading says this because with worktrees the answer stopped being
obvious: two heads can hold different repo sections and both be right."
  (let* ((ws (%workspace-dir workspace))
         (root (and (plusp (length ws)) (repo-todo-checkout ws))))
    (and root
         (let ((rb (%dir-basename root)))
           (cond ((null rb) root)
                 ((string= root ws) rb)
                 (t (format nil "~a/~a" (or (%dir-basename ws) "") rb)))))))

(defun %repo-todo-missing-why (path root tried)
  "The sentence for a repo section with nothing to read, naming EVERY directory examined.

`(no TODO.md in …)` alone was the defect: the pane said it about `/home/dead/Projects/rano`, where
the repo is one level down, so it read as *there is no TODO.md* rather than *I looked in the wrong
place*. Naming where it looked is the operator's own third step, and it is the only reason this case
was visible at all."
  (cond
    ((null tried) "this session has no workspace, so there is no TODO.md")
    ((null path) (format nil "no TODO.md — looked in ~{~a~^ and ~})" tried))
    (t (format nil "no TODO.md in ~a" root))))

(defun repo-todo-rows (workspace)
  "The repo's TODO.md as rows, or one row saying why there are none."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((null tried)
       (list (list :indent 4 :mark nil :text "(no workspace in the wiring)"
                   :body nil :item nil)))
      ((and path (probe-file path))
       (read-todo-md (uiop:read-file-string path)))
      ;; **A REFUSAL THAT NAMES EVERY DIRECTORY IT LOOKED IN.** See `%repo-todo-missing-why`: the old
      ;; sentence named the workspace and stopped, which read as *there is no TODO.md* about a repo
      ;; sitting one level down.
      (t
       (list (list :indent 4 :mark nil
                   :text (format nil "(~a)" (%repo-todo-missing-why path root tried))
                   :body nil :item nil))))))

;;; ---------------------------------------------------------- the watcher ;;;
;;;
;;; The pane used to read the file at open, so a file edited WHILE the pane was up
;;; showed the old read — and this file is edited exactly while somebody is
;;; looking at it. The operator: *"since the file can be updated, dont cache it i
;;; guess or do a watcher with a nice syscall"*.
;;;
;;; One `stat` per draw rather than an inotify thread: a watcher means a
;;; descriptor, a thread and an event routed into a head whose design is one loop
;;; over one channel, and the pane is drawn only while it is open. `(mtime, len)`
;;; rather than mtime alone, because a second-granularity mtime misses two writes
;;; inside one second and a length change catches most of those.

(defvar *repo-todo-cache* nil "The rows last read, or NIL.")
(defvar *repo-todo-stamp* nil "The (mtime len) they were read at.")

(defvar *repo-todo-generation* -1
  "The `*code-generation*` the cached rows were read UNDER, which is the half of the key the file's
stamp cannot supply.

**The file's `(mtime, len)` answers *did the FILE change*, and a live push is not the file changing.**
MEASURED on the operator's own head: the pane cached the rows, a push redefined `read-todo-md` to carry
`:line`, the stamp still matched, and every repo row went on being drawn without one — so `i` refused
on all of them, blaming the row. `-1` rather than 0 so the FIRST read is taken as stale whatever the
counter happens to hold, including in a fresh image (where both are 0).

See `*code-generation*` in `head.lisp` for the whole reading.")

(defun %todo-stamp (path)
  (ignore-errors
    (let ((w (sb-posix:stat path)))
      (list (sb-posix:stat-mtime w) (sb-posix:stat-size w)))))

(defvar *repo-todo-path* nil
  "The workspace the cache was read for, so a Switch does not show the old
project's queue.")

(defun repo-todo-rows-cached (workspace)
  "The repo's rows, re-read when the file changes (or the workspace does), OR WHEN THE CODE DOES."
  (let* ((path (repo-todo-path workspace))
         (stamp (and path (probe-file path) (%todo-stamp path))))
    (unless (and (equal path *repo-todo-path*)
                 (equal stamp *repo-todo-stamp*)
                 ;; **THE CODE'S OWN GENERATION IS PART OF THE KEY.** A push can change the SHAPE these
                 ;; rows have without the file moving at all, and a cache that only watches the file
                 ;; then hands back what the old code produced — see `*code-generation*`.
                 (eql *code-generation* *repo-todo-generation*))
      (setf *repo-todo-path* path
            *repo-todo-stamp* stamp
            *repo-todo-generation* *code-generation*
            *repo-todo-cache* (repo-todo-rows workspace)))
    *repo-todo-cache*))

(defun %todo-md-toggle-line (text line-no)
  "TEXT (a TODO.md) with line LINE-NO's checkbox flipped, or `(values NIL REASON)`.

**ONE LINE, and every other byte of the file identical.** The alternative — parse the rows, flip one,
render them all back — is what `%todo-row-lines` would give you, and it would reformat the whole file:
prose between items, the indent under an item, wrapping and trailing space all go, because the parser
does not model them. On a file the operator COMMITS and COLLABORATES on, that is a diff nobody asked
for plus a conflict for whoever else is editing it. So the edit is a splice on one line.

**The marks are `[ ]`, `[x]` and `[~]`, and only the first and second flip.** `[~]` means *in
progress* — a state somebody is holding — and a space bar that cleared it would be dropping somebody's
claim on a row. Flipping `[~]` is not defined here rather than guessed at; the caller says so.

**THREE VALUES AND NOT TWO, because two positions meant two things.** The first cut returned
`(values TEXT MARK)` on success and `(values NIL REASON)` on failure, so the SECOND value was a keyword
in one case and a sentence in the other — and a caller that reached for it got `:open` where it expected
a reason. MEASURED, in this feature's own test: `TYPE-ERROR expected-type: SEQUENCE datum: :OPEN`.

So: `(values TEXT MARK REASON)`. TEXT is NIL exactly when nothing was written, MARK is `:done`/`:open`
exactly when something was, and REASON is a sentence exactly when nothing was."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (line (and (> line-no 0) (<= line-no (length lines)) (nth (1- line-no) lines))))
    (cond
      ((null line) (values nil nil (format nil "line ~d is not in the file any more" line-no)))
      (t (let ((at (or (search "[ ]" line) (search "[x]" line) (search "[X]" line)
                       (search "[~]" line))))
           (cond
             ((null at) (values nil nil "that line has no checkbox to mark"))
             ((or (search "[~]" line) (and (>= (length line) (+ at 3)) (string= "[~]" (subseq line at (+ at 3)))))
              ;; `[~]` is somebody's claim; said rather than silently cleared
              (values nil nil "that row is in progress — a space bar does not clear somebody's claim"))
             (t
              (let* ((was (subseq line at (+ at 3)))
                     (now (if (or (string= was "[ ]")) "[x]" "[ ]"))
                     (fresh (concatenate 'string (subseq line 0 at) now (subseq line (+ at 3)))) )
                (setf (nth (1- line-no) lines) fresh)
                (values (format nil "~{~a~^~%~}" lines)
                        (if (string= now "[x]") :done :open)
                        nil)))))))))

(defun %todo-md-subtree-range (text line-no)
  "The RAW LINES of TEXT covering the subtree that starts at LINE-NO: `(values FIRST LAST)`.

**READ FROM THE FILE, NOT FROM THE PARSED ROWS, and that is forced rather than chosen.** MEASURED on
this head: `read-todo-md` FLATTENS the tree — every item comes back `:item T :indent 8`, so

    - [ ] parent task
      - [ ] child one      <- indented two spaces in the FILE

both arrive at indent 8, and a sibling after them does too. The real nesting is gone, so a subtree
cannot be recovered from the rows at all. This walks the raw lines, where the indentation still is.

**The rule is markdown's list rule**, which is also rano's schema's rule: the block runs until a
non-blank line whose indent is at or below the parent's, and blank lines and anything deeper belong to
it. Blank lines do not end it because a subtree with a blank line between two children is still one
subtree, and it is how this repo's own TODO.md is written.

**THE LAST NON-BLANK LINE IS THE END**, so a run of blanks after the subtree is not swallowed into the
range — a range that claims trailing empty lines would make the prompt name lines that say nothing."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (n (length lines)))
    (when (and (> line-no 0) (<= line-no n))
      (let* ((first (1- line-no))
             (base (let ((l (nth first lines)))
                     (- (length l) (length (string-left-trim " " l)))))
             (last first))
        (loop for i from (1+ first) below n
              for raw = (nth i lines)
              for blank = (zerop (length (string-trim '(#\space #\tab) raw)))
              for indent = (- (length raw) (length (string-left-trim " " raw)))
              do (cond
                   ;; deeper or blank: inside the subtree
                   ((or blank (> indent base))
                    (unless blank (setf last i)))
                   ;; at or below the parent and not blank: the subtree ended before this line
                   (t (loop-finish))))
        (values (1+ first) (1+ last))))))

(defun repo-todo-implement-text (workspace line-no)
  "The sentence to put in the composer for the `TODO.md` subtree at LINE-NO — or `(values NIL REASON)`.

**AN INSTRUCTION AND THE LITERAL TREE, which is the operator's ruling arriving twice.** First:
*\"whole tree - we keep context.\"* Then, on where that context lands: *\"the literal text of the whole
tree goes into the prompt, which is exactly where context belongs — the model reads the why and the
surrounding items as prose, once, at the moment it is asked.\"*

**THIS REVERSES WHAT THIS FUNCTION DID FIRST, AND WHY IT IS NOT A CONTRADICTION IS LIFETIME.** The first
cut was *a reference, not a transcription* — name the file and the range, paste nothing — on the rule
that a COPY goes stale. That rule is right about DURABLE state: this head's scratchpad, the model's
board, anything that sits. **A prompt is consumed once**, in the turn it is sent, so *goes stale* does
not apply to it, and the operator's reason is the better one for the case at hand: the model reads the
why and its neighbours at the moment it is asked, rather than hunting for them.

**THE WHOLE FILE AND NOT THE SUBTREE**, which is the ruling's own distinction: *\"untagged siblings
included - not the tagged node and not its spine.\"* Siblings are not descendants, so a copy that
included them is a copy of everything. MEASURED, that is a lot of text — this repo's own `TODO.md` is
~63 KB and rano's is ~107 KB — and it is deliberate: the body is the WHY (*\"because I expect todos have
not only titles right? bodies too. so when you build a component you want to know why\"*), and an item
read without its neighbours is an item whose reasons were cut off.

**THE LABEL IS STILL THE TITLE ALONE, WHICH IS WHAT KEEPS THE TWO DECISIONS COMPATIBLE.** The quoted
words are the item's own FIRST LINE and the body is not joined onto them, because at this level a body
line and a CHILD's line are both just *one line under the parent*. So the prompt has three parts with
three jobs and none is redundant: the label names WHAT, the literal text carries the WHY, and the range
is the handle.

**AND THE TEXT IS THE FILE AS READ — byte for byte**, not a re-rendering of the parsed rows. The parser
models boxes, titles and indented bodies; it does not model the prose between items, the blank lines or
the wrapping, so a round trip through it would hand the model a file that is not the one on disk.

**THE PATH IS NAMED WITH ITS CHECKOUT**, because with worktrees *the model's `TODO.md`* is ambiguous —
its workspace holds its own branch's copy (R58).

**AND NOTHING HERE WRITES A FILE.** *\"we can do copying via model … it is essentially a scratch pad
for shared todos\"* — the model writes the scratchpad, so there is no tree-copy operation here and no
divergence for the head to resolve.

**UNPLACED ON PURPOSE: the sha, the file hash and the mtime at this moment.** The operator: *\"when you
copy you have things - hash and commit and modified timestamp of the shared todo.md\"*, and those are
what answer *did upstream change under me* later. **Where they go — the ask, the scratchpad's text, or
both — is NOT ruled**, and the instruction is explicit: *\"Do not invent a store for it; note that it is
unplaced.\"* So it is noted and not built. The composer is the obvious place once it is ruled."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((or (null path) (not (probe-file path)))
       (values nil (%repo-todo-missing-why path root tried)))
      (t (handler-case
             (let* ((text (uiop:read-file-string path))
                    (lines (uiop:split-string text :separator '(#\newline)))
                    (row (nth (1- line-no) lines)))
               (cond
                 ((or (null row) (null line-no))
                  (values nil "that row is no longer in the file"))
                 (t (multiple-value-bind (first last) (%todo-md-subtree-range text line-no)
                      ;; **THE WORDS COME FROM THE RAW LINE**, so what the model reads back matches
                      ;; what the operator selected character for character — the parsed row's text
                      ;; has been through `strip-todo-markup`, which is the RENDERER's transformation
                      ;; and would hand the model a spelling the file does not contain.
                      (let* ((words (%todo-md-item-text row))
                             (label (%repo-checkout-label workspace))
                             (where (if label (format nil " (the ~a checkout)" label) ""))
                             (what (if (= first last)
                                       (format nil "Implement the TODO.md item \"~a\" — TODO.md line ~d."
                                               words first)
                                       (format nil "Implement the TODO.md subtree \"~a\" — TODO.md lines ~d–~d."
                                               words first last))))
                        (values
                         ;; **THE LITERAL TREE FOLLOWS THE INSTRUCTION**, and `text` is the file AS READ —
                         ;; byte for byte, so what the model sees is what is on disk rather than a
                         ;; re-rendering of the parsed rows (which drops the prose between items, the blank
                         ;; lines and the wrapping, none of which the parser models).
                         (format nil "~a~%~%The whole of ~a~a as it stands, so the surrounding items and their reasons are in view rather than the named lines alone:~%~%~a"
                                 what path where text)
                         nil))))))
           ;; **ONE FEWER CLOSE ON THE LINE ABOVE, ONE MORE HERE**, and the depth is what says so:
           ;; the protected form's `(values …)` needs six closes to get back to the `handler-case`
           ;; itself, and seven reached past it — which left THIS clause outside the `handler-case`
           ;; as a stray form, so `(error (e) …)` read as a call to the function `e`. Measured the
           ;; same way as the `dash-watcher-source-fn` defect: `scripts/count-parens.py FILE FIRST LAST`
           ;; prints the depth at every line, and it goes to 5 here and 0 at the clause, rather than
           ;; to 4 and 0 — which is the whole of the difference and took a counter to see.
           (error (e) (values nil (format nil "TODO.md could not be read: ~a" e))))))))

(defun %todo-md-item-text (raw-line)
  "RAW-LINE's own words, with the markdown bullet and checkbox taken off.

**NOT `strip-todo-markup`** — that one is the RENDERER's and strips emphasis and code markers for the
screen. This is naming a line back to the model, so the words should be the file's own.

**ONE LINE, SO A WRAPPED ITEM'S LABEL IS ITS FIRST LINE AND ENDS MID-SENTENCE — deliberate, MEASURED on
the operator's own `TODO.md`**, whose `T1 · the payload window` (line 440) wraps across 25 lines. The
composed prompt then reads

    Implement the TODO.md subtree \"**T1 · the payload window** (`keys.md` G13/G20, `wire.md` W2,\" — TODO.md lines 440–464.

and the comma at the end is where the file's own line ended, not a truncation: the RANGE names the
rest, which is the handle the model reads the file by. **JOINING THE WRAPPED LINES WAS THE ALTERNATIVE
AND IT IS WORSE**, for the reason that gave this whole gesture its shape: an item's continuation lines
are indistinguishable from a CHILD'S at this level — T1's prose runs to the end of its block — so
joining would paste twenty-five lines of prose into the composer under the name of `words`, which is
the transcription `repo-todo-implement-text` exists to refuse. A label that is a fragment plus an
unambiguous range beats a label that is a copy."
  (let* ((t* (string-left-trim " \t" raw-line))
         ;; the bullet: `- [ ] `, `* [x] ` or a bare `[ ] `
         (t* (cond ((and (>= (length t*) 2)
                         (member (char t* 0) '(#\- #\*) :test #'char=)
                         (char= (char t* 1) #\space))
                    (string-left-trim " " (subseq t* 2)))
                   (t t*)))
         (t* (cond ((>= (length t*) 3)
                    (let ((at (or (search "[ ]" t*) (search "[x]" t*) (search "[X]" t*)
                                  (search "[~]" t*) (search "[-]" t*))))
                      (if (and at (zerop at)) (string-left-trim " " (subseq t* 3)) t*)))
                   (t t*))))
    (string-trim " " t*)))

(defun repo-todo-toggle (workspace line-no)
  "Flip the checkbox on LINE-NO of WORKSPACE's TODO.md. Returns `(values MARK REASON)`.

**The shared half of the todo list, and the whole point is that it is a FILE.** R44's split, in the
operator's own words: the todos that live near the session are the head's own (per project, in sqlite,
and nobody else sees them), and the ones you tick here are the ones you mean to SHARE — they are
committed, they travel with the repo, and another person may be editing the same file.

That is why this returns a reason rather than signalling: every refusal is something to SAY (no
checkbox on that line, an in-progress row, a file that cannot be written), and a space bar that
appears to do nothing is the defect this pane has already been fixed for twice.

**The write is a whole-file rewrite of a file whose only change is one line**, so a reader
mid-`git diff` sees one line move. It is not atomic — a crash between the read and the write could
truncate — and that is accepted rather than hidden: a TODO.md is in git, `git checkout` is the
recovery, and a temp-file-and-rename dance would be a second thing to get wrong for a file whose
worst case is one lost edit."
  (multiple-value-bind (path root tried) (repo-todo-path workspace)
    (cond
      ((or (null path) (not (probe-file path)))
       (values nil (%repo-todo-missing-why path root tried)))
      (t (handler-case
             (let* ((text (uiop:read-file-string path)))
               (multiple-value-bind (new mark why) (%todo-md-toggle-line text line-no)
                 ;; the same three-value shape as `%todo-md-toggle-line`, for the same reason: a
                 ;; MARK and a REASON must not share a position, or a caller cannot tell *ticked* from
                 ;; *refused* without knowing which branch produced it.
                 (cond
                   (new (with-open-file (out path :direction :output :if-exists :supersede
                                                  :if-does-not-exist :error
                                                  :external-format :utf-8)
                          (write-string new out))
                        ;; the cache is keyed on (mtime len) and this write may land inside the same
                        ;; second as the read that filled it — so it is dropped rather than trusted
                        (setf *repo-todo-cache* nil *repo-todo-stamp* nil)
                        (values mark nil))
                   (t (values nil why)))))
           (error (e) (values nil (format nil "TODO.md could not be written: ~a" e))))))))

(defun repo-todo-lines (workspace)
  "The repo's TODO.md as plain lines, for callers that want text. The pane uses
`repo-todo-rows-cached`; this stays for the rest."
  (mapcar (lambda (row) (format nil "~a~@[~a ~]~a"
                                (make-string (getf row :indent) :initial-element #\space)
                                (case (getf row :mark) (:done "[x]") (:doing "[~]") (:open "[ ]"))
                                (getf row :text)))
          (repo-todo-rows workspace)))

(defvar *repo-todo-open* nil
  "Whether the repo item under the cursor is UNFOLDED — the reference's
`repo_open`, one flag beside one cursor.

The cursor is `head-picker-sel` while the todos pane is up (one cursor for every
pane, because only one is open at a time), and moving it folds the item again, so
at most one item is ever open: the reference's rule, and the one the captures
show. Keyed to the cursor rather than to the row's text because that is what Up,
Down, Enter and Tab all agree on. A defvar, not a head slot: a struct layout
change is a restart.")

(defun %todo-mark-style (mark)
  "A mark's colour: done green, doing yellow, OPEN LEFT ALONE.

An open item is the default state and the majority of any list, and colouring the
majority spends the signal the other two carry."
  (case mark
    (:done '(:fg :green))
    (:doing '(:fg :yellow))
    (t nil)))

(defun %todo-mark-text (mark)
  (case mark (:done "[x]") (:doing "[~]") (:open "[ ]") (t "   ")))

(defun %todo-row-lines (row &key here open)
  "One repo todo row to segment lines — the mark PAINTED, the indent separate.

The reference's row (`todos_lines`, app.rs:5898) is `{pad}{cursor}{mark} {text}{more}`
with `pad` two columns SHORT of the indent and `cursor` either `▸ ` or two spaces,
so a row's box sits at its indent whether or not the cursor is on it. HERE is
that cursor; OPEN unfolds the body under the row, one dim line per detail line at
`pad + 8`. A folded item with a body ends in ` ···` — ONE space, plain, measured:
ours drew two and dimmed it.

**AND THE BODY IS THE WHY, WHICH IS THE WHOLE REASON THIS ROW UNFOLDS AT ALL.** The operator: *\"because
I expect todos have not only titles right? bodies too. so when you build a component you want to know
why.\"* **MEASURED on this head's own `TODO.md`, on `T1 · the payload window` (file line 440): the body
is 24 lines and 1643 bytes, EVERY line of it is drawn when the row is open, and opening adds exactly
24 lines to the pane.** So nothing here is *preserved but unreachable* — and that was worth measuring
rather than assuming, because a body parsed into a field nobody can see is indistinguishable from a
body that was never kept.

**The title/body split is therefore STRUCTURAL, and it is why the `i` prompt takes the first line and
nothing more.** Those 24 lines are the item's BODY; the label `%todo-md-item-text` builds for the
composer is the title alone, because at this level a body line and a CHILD's line are both just *one
line under the parent* — so joining them would paste the whole body into the composer under the name of
the item's words, which is the transcription `repo-todo-implement-text` exists to refuse. The prompt
names the line RANGE instead, and the body is the reason that range is worth naming.

The indent is its own segment so the colour lands on the box and not in front of
the whitespace; `TodoMark::painted` in the reference exists for the same reason,
and so does the assertion in the test that checks the ESCAPES rather than the
glyphs. A heading with no mark is one dim segment: it is the operator's prose,
not a task.

Returns a LIST OF LINES — the row, then its body when open. The caller must
FLATTEN these (see `todos-lines`, which appends them), because a nesting mistake
here is invisible: it renders as a list printed into a cell rather than as an
error."
  (let* ((mark (getf row :mark))
         (pad (make-string (max 0 (- (getf row :indent) 2)) :initial-element #\space))
         (cursor (if here "▸ " "  "))
         (text (getf row :text))
         (detail (getf row :body))
         (more (if (and detail (not open)) " ···" "")))
    (append
     (list (if mark
               (list (cons (concatenate 'string pad cursor) nil)
                     (cons (%todo-mark-text mark) (%todo-mark-style mark))
                     (cons (format nil " ~a~a" text more) nil))
               (list (cons (format nil "~a~a~a" pad cursor text) '(:dim t)))))
     (when (and detail open (getf row :item))
       (mapcar (lambda (l) (list (cons (format nil "~a        ~a" pad l) '(:dim t))))
               detail)))))

(defun repo-todo-stops (rows)
  "The indices of the ITEMS in ROWS — where the todos cursor may stop.

Headings roll up the rows beneath them and have nothing to unfold, so the cursor
skips them: the reference's `stops` (app.rs:3268)."
  (loop for r in rows for i from 0 when (getf r :item) collect i))

(defun %todo-item-lines (item author show-detail &optional here)
  "ITEM as the pane's lines: the mark, the words, and whose they are — plus the description under
them when SHOW-DETAIL and the item has one.

**The author label is on the ROW and not in a heading**, because the two lists interleave in one
list and a reader scanning it needs to know which is which per line, not per section. `  — you` /
`  — model` is the whole of the distinction the operator asked for: *\"it should be marked as
created by me, and created by model as created by model.\"*

The description hangs under the title at six columns, which is two past the mark, so the item's
words and its detail read as a block rather than as two entries."
  (let ((st (cond ((string= (or (getf item :status) "") "in_progress") :doing)
                  ((string= (or (getf item :status) "") "completed") :done)
                  (t :open))))
    (append
     ;; **the cursor mark, in the pane's own column** — `▸ ` or two spaces, like every other
     ;; selectable row here, so a reader who has learnt this pane's cursor finds it on a
     ;; session item too. The row is reversed when it is the one the cursor is on, which is
     ;; what every other pane does and what makes `delete` mean *this row*.
     (list (list (cons (if here "  ▸ " "    ") (and here '(:reverse t)))
                 (cons (%todo-mark-text st) (%todo-mark-style st))
                 (cons (format nil " ~a" (getf item :content)) (and here '(:reverse t)))
                 (cons (format nil "  — ~a" author) (if here '(:reverse t) '(:dim t)))))
     (let ((detail (getf item :detail)))
       (when (and show-detail detail (plusp (length detail)))
         (list (list (cons "      " nil)
                     (cons detail '(:dim t)))))))))

(defvar *todos-hide-done* nil
  "Hide the DONE rows in the todos pane. The operator's ask: *\"in todo panel i want a mode where done
items hidden\"*.

**A MODE AND NOT A FILTER, because the two sections answer it the same way and a reader should learn it
once.** A done row is still a row: `todos-stops` still refuses to offer it to the cursor, and this
hides it only from the DRAWING — so with the mode on the cursor walks what is on the screen and nothing
else, which is the invariant this pane has broken twice before (see `todos-stops`: *\"arrows dont go
here\"*, and a stop whose row was never drawn).

**Both authors, both sections.** The operator's rows, the model's, and the file's — a done item is done
whoever wrote it, and hiding only one half would make the mode mean two things.

**It is a `defvar` like `*repo-todo-open*`, and like that flag it does NOT survive a restart.** It is
where your eyes are, not a preference, and the pane is opened and closed many times a session. If it
turns out to want remembering, it belongs in `head.toml` beside the diff view rather than in a
long-lived special — say the word and it moves there."
)

(defun %todo-hidden-p (item)
  "Is ITEM a row this pane is hiding? Only the DONE ones, and only in the mode — see `*todos-hide-done*`."
  (and *todos-hide-done*
       (string= (or (getf item :status) "") "completed")))

(defun %todo-row-hidden-p (row)
  "Is the FILE's ROW hidden? Its own vocabulary: the parser's mark, not a status string.

The two predicates are separate rather than one taking a plist because the two lists genuinely say it
differently — a session item carries `:status \"completed\"` and the parser hands back `:mark :done` —
and a single predicate guessing which shape it was given is how a row stops being hidden the day one of
them is renamed."
  (and *todos-hide-done* (eq (getf row :mark) :done)))

(defun todos-stops (head)
  "Every row of the todos pane the cursor may land on, in the order the pane draws them.

**One enumeration, and everything that asks *where is the cursor* reads this one** — the
arrows, the click, the cursor's LINE, and the key that acts on a row. R44's first cut had it
spread over a `-1` sentinel and the repo's own stop indices, and both of the operator's
reports came from that: *\"arrows dont go here\"* was the cursor moving to a row whose line
the pane then reported from another list's arithmetic, and *\"mouse doesnt click\"* was a
click on the add row computing a negative index and being thrown away. Two enumerations was
the defect; this is the one.

A stop is tagged, and **the tag carries the row's IDENTITY rather than its position**:

  · `(:add)` — the one control, at the head;
  · `(:mine . ID)` — the operator's own item, by its id (see `*operator-todos*`: *\"a todo item is
    identified by a hash or something like a commit\"*);
  · `(:repo . I)` — a row of the workspace's `TODO.md`, index I into `repo-todo-rows-cached`, which
    has no ids because it is a file the head reads rather than a list it owns.

**Identity and not position, and the difference is the whole of it.** A position is a fact about
the list at the moment it was drawn; a list changes between a draw and a keypress — a `TodosUpdated`
arriving, an item removed, the session switching — and every action then lands on the row that took
its neighbour's place. With the id, `delete` removes the row the operator was looking at or nothing
at all. The repo's rows keep an index because they are addressed by their own file's order and the
pane re-reads that file, so the index IS their identity there.

**The model's items are drawn and are NOT stops, and that is the R44 boundary rather than
an omission.** The head has no frame that writes a todo (`ListTodos` is documented as *a
question, not an act*), so there is no key that could act on one of the model's rows —
and a cursor that stops where no key acts is a cursor the operator presses keys into and
nothing happens. They are skipped the way the repo's headings always were.

`head-picker-sel` is an ORDINARY INDEX INTO THIS LIST, which is why the head's slot type is
untouched and why the cursor survives a list changing under it: a deletion shifts the index
and the row it lands on is still a row."
  (let* ((s (head-session head))
         (rows (repo-todo-rows-cached (getf (session-wiring s) :workspace))))
    (append (list (list :add))
            ;; **A HIDDEN ROW IS NOT A STOP**, which is the half that keeps the cursor honest: the
            ;; pane draws no line for it, so a stop for it would be a cursor position with nothing
            ;; under it — and every key that acts on the row would act on a row nobody can see.
            (loop for item in *operator-todos*
                  unless (%todo-hidden-p item)
                    collect (cons :mine (getf item :id)))
            ;; the index is the row's identity here and is NOT renumbered by the hiding: `:repo`
            ;; stops are addresses into `repo-todo-rows-cached`, which the mode does not change.
            (loop for r in rows
                  for i from 0
                  when (and (getf r :item) (not (%todo-row-hidden-p r)))
                    collect (cons :repo i)))))

(defun todos-lines (head cols)
  "The todos pane: the session's plan with its authors, the add control, and the repo's TODO.md.

    todos
    <blank>
      this session — the plan, and who wrote each line:
      ▸ [+] add todo item
        [ ] check the logs  — you
          the daemon log, not the head's
        [x] a model item  — model
    <blank>
      the repo's TODO.md (rano/rano) — what the PROJECT intends, not the model's board:
          Dependency graph
        [x] T1 …
    <blank>
      space ticks one line of it in place; i composes a prompt from a subtree.

**THREE VALUES**: the lines, the cursor's LINE, and a vector of every stop's line, parallel to
`todos-stops`. The second is an `aref` of the third — never arithmetic over one of the three lists
this draws from, which is what put the pane four lines above the row it was scrolling to.

**EVERY LINE GOES THROUGH ONE `emit`**, and a line is recorded as a stop's line only when the
caller says so. The index is `(length out)` taken inside `emit` — the line's index in the list
this function RETURNS, because `out` is built in reverse and flipped at the end. Two other forms
of *push this line, and maybe record it* is how the first cut came to record one entry for five
stops: the recorded index was the length before some pushes and after others."
  (declare (ignore cols))
  (let* ((s (head-session head))
         (todos (session-todos s))
         (ws (getf (session-wiring s) :workspace))
         (rows (repo-todo-rows-cached ws))
         (stops (todos-stops head))
         (n (length stops))
         (sel (if (plusp n) (min (max 0 (head-picker-sel head)) (1- n)) 0))
         (out nil)
         (stop-lines (make-array 0 :adjustable t :fill-pointer 0))
         (at 0))
    (flet ((emit (line &optional stop-p)
             (when stop-p (vector-push-extend (length out) stop-lines))
             (push line out))
           ;; **IS THIS ROW THE CURSOR'S?** — and the two halves of that question are different
           ;; ones, which is what the first cut of this got wrong: it asked *is this row AT `at`*,
           ;; and `at` walks EVERY stop, so the mark landed on the first row whose tag matched
           ;; rather than on the row the cursor was actually sitting on. The operator's own report
           ;; is what that looked like: the pane opened with the cursor on the add row and a `▸`
           ;; drawn somewhere else, and every repo item came out double-indented because its row
           ;; thought it was selected.
           ;;
           ;; `at` is where the WALK is (advancing once per row, so it and `stops` stay in step);
           ;; `sel` is where the CURSOR is. The tag and the identity are the third check, and they
           ;; stay because they make the comparison impossible to make against a row of the wrong
           ;; kind — belt to the braces above, and cheap.
           (this (tag id) (and (< at n) (= at sel) (nth at stops)
                               (eq (car (nth at stops)) tag)
                               (equal (cdr (nth at stops)) id))))
      (emit (list (cons "todos" '(:bold t))))
      (emit nil)
      (emit (list (cons "  this session — the plan, and who wrote each line:" '(:dim t))))
      ;; **the add control**, at the head of the session's list because that is where an addition
      ;; goes: `[+]` in the items' own mark column, BOLD, so it reads as a control rather than as a
      ;; line of the list. *"it looks like a regular text"*, said of the first cut, which was plain
      ;; `    add todo item` in the items' own register with nothing but the cursor to tell them
      ;; apart.
      (let ((on (and (< at n) (eq (car (nth at stops)) :add))))
        (emit (list (cons (if on "  ▸ " "    ") (and on '(:reverse t)))
                    (cons "[+] " '(:bold t))
                    (cons "add todo item" '(:bold t)))
              t))
      (incf at)
      ;; the operator's items and the model's, one list with the author on every row
      (dolist (item *operator-todos*)
        (unless (%todo-hidden-p item)
        (let ((here (this :mine (getf item :id)))
              (first t))
          (dolist (line (%todo-item-lines item "you" t here))
            ;; **EVERY item records its line, not only the cursor's** — `stop-lines` is parallel to
            ;; `todos-stops`, and its whole job is to say where each stop is DRAWN. Recording only
            ;; the selected row left a vector with one entry in it and made `(aref stop-lines sel)`
            ;; an out-of-bounds read for every cursor position but the first.
            (emit line first)
            (setf first nil)))
        (incf at)))
      ;; **THE MODEL'S ITEMS ADVANCE NOTHING**, because they are not stops: `todos-stops` skips
      ;; them for the reason its docstring gives (no key acts on one), and a walk that advanced
      ;; here would run `at` past the stop it is comparing against — which is how the pane came to
      ;; index its stop-lines array out of bounds on a plan that had any model rows in it.
      ;; **THE WIRE'S LIST HELD BOTH AUTHORS, AND THIS DREW THE OPERATOR'S ROWS TWICE.** `session-todos`
      ;; is the daemon's UNION (both halves — see `TodoBoard::snapshot`), while the rows above come from
      ;; `*operator-todos*`, which is this head's own half. So every row the operator wrote was drawn
      ;; once as theirs and again here, **labelled `model`** — a duplicate AND a false author. MEASURED
      ;; on the live head with one row on the board: `[x] push leticl to github — you` immediately
      ;; followed by `[x] push leticl to github — model`.
      ;;
      ;; The fix is to draw each half once, from the half that OWNS it: the operator's rows from this
      ;; head's list (which is what the add and delete keys act on, and what carries the ids the
      ;; cursor's stops are tagged with), and the model's rows from the wire. **The tag is read rather
      ;; than assumed**, because `by` is the whole of the difference between the two halves and a pane
      ;; that re-derives authorship from which list a row arrived in is the drift this feature exists
      ;; to prevent.
      (dolist (item todos)
        (unless (or (string= (or (getf item :by) "") "operator")
                    (%todo-hidden-p item))
          (dolist (line (%todo-item-lines item "model" nil))
            (emit line nil))))
      (when (and (null *operator-todos*) (null todos))
        (emit (list (cons "    none written yet. The model writes them with todo_write, and the row above adds one of yours."
                          '(:dim t)))))
      ;; **AND WHEN THE MODE IS WHAT EMPTIED IT.** The distinction the pane keeps insisting on: a
      ;; section with nothing in it and a section whose contents are HIDDEN are different facts, and a
      ;; reader who cannot tell them apart concludes the key did nothing — which is the defect this
      ;; pane has been fixed for three times.
      (when (and *todos-hide-done*
                 (or *operator-todos* todos)
                 (every #'%todo-hidden-p
                        (append *operator-todos*
                                (remove-if (lambda (i) (string= (or (getf i :by) "") "operator"))
                                           todos))))
        (emit (list (cons "    everything here is done — h shows them." '(:dim t)))))
      (emit nil)
      ;; **letibot's sentence, and it is load-bearing rather than tidy**: two sections that look alike
      ;; and BEHAVE differently have to say which is which. One is what the project intends, the other
      ;; is what the agent is doing — and until this pane had a key that writes the file, a reader
      ;; could tell them apart by the `— you` / `— model` marks alone. They are not a plan in two
      ;; places, and they are not synced: nothing here reaches the model's board, and nothing on that
      ;; board ticks this file.
      (emit (list (cons (format nil "  the repo's TODO.md~@[ (~a)~] — what the PROJECT intends (space ticks it, i composes a prompt):"
                                (%repo-checkout-label ws))
                        '(:dim t))))
      (if (null rows)
          (emit (list (cons "    no sections found." '(:dim t))))
          (loop for r in rows
                for i from 0
                ;; **`at` AND `stops` STAY IN STEP, so `at` advances only on the rows that ARE
                ;; stops** — the repo rows carrying an item. Headings are drawn and are not stops,
                ;; so advancing for them walked the walk past the entries it was comparing against
                ;; and no repo row ever matched: the pane drew no cursor mark on the file's items
                ;; at all, which is the one thing this pane has always done.
                for item-row = (and (getf r :item) t)
                ;; **A HIDDEN ROW IS NOT DRAWN AND NOT A STOP**, so `at` does not advance for it:
                ;; the same rule the headings below keep, one step further.
                for hidden = (%todo-row-hidden-p r)
                for here = (and item-row (not hidden) (this :repo i))
                ;; **a row's stop is its FIRST line**, so the body of an unfolded item does not
                ;; move the cursor's target — and the line is taken before the row draws, because
                ;; the row renders to as many lines as its body needs.
                for first-line = (length out)
                unless hidden
                  do (dolist (line (%todo-row-lines r :here here
                                                      :open (and here *repo-todo-open*)))
                       (emit line nil))
                     ;; **and the same here: an item row records its line whether or not the cursor
                     ;; is on it.** `here` is the MARK; `item-row` is the STOP.
                     (when item-row (vector-push-extend first-line stop-lines))
                     (when item-row (incf at))))
      (emit nil)
      (when (and *todos-hide-done*
                 (some (lambda (r) (getf r :item)) rows)
                 (notany (lambda (r) (and (getf r :item) (not (%todo-row-hidden-p r)))) rows))
        (emit (list (cons "    every item here is done — h shows them." '(:dim t)))))
      (emit (list (cons "  space ticks one line of that file, in place; it is not the board the model is reminded of."
                        '(:dim t))))
      ;; **THE KEY TEACHES ITSELF HERE AND NOT ONLY IN `/help`.** A mode nobody can find is a mode
      ;; that does not exist, and this line says which STATE it is in as well as which key changes it.
      (emit (list (cons (if *todos-hide-done*
                            "  done items are hidden — h shows them again."
                            "  h hides the done ones.")
                        '(:dim t)))))
    (values (nreverse out)
            (if (or (zerop (length stop-lines)) (zerop n)) 0 (aref stop-lines sel))
            stop-lines)))

