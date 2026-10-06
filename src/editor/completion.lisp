;;;; completion — Tab: completing a verb, a path, and an argument
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

(defvar *completion* nil
  "The tab cycle: `(NAMES INDEX)` — every command the last fresh prefix matched,
and which of them is on the line now.

A defvar rather than a head slot, for the reason every other editor window here
is one: a struct layout change is a restart.")

(defun %set-composer (head text)
  "Replace the whole line. Completion words are single tokens, so there is
nothing to preserve around them."
  (let ((c (head-composer head)))
    (setf (composer-buffer c) text
          (composer-cursor c) (length text))))

(defun %daemon-workspace (head)
  "The workspace the DAEMON is seated in, or NIL when it has not said.

**R32's constraint 1: a relative path completes against the DAEMON's workspace, not this
head's cwd and not `$PWD`.** The two are the same directory on this box and are not the same
fact: a head started from one place attached to a daemon seated in another has been telling the
daemon paths it resolves elsewhere all day, and a completion that offered this head's files
would be offering paths the tool cannot reach.

The wiring is where the daemon says it, and it arrives on the `hello`; NIL is a daemon that has
not said, and the caller then completes nothing rather than guessing a root — the same rule
every absent field in this tree keeps."
  (getf (session-wiring (head-session head)) :workspace))

(defun %path-root (head typed)
  "The directory a leading fragment of TYPED is resolved against, or NIL for *nowhere to look*.

R32's first constraint, in one place: **a leading `/` completes from the filesystem root**,
anything else from the daemon's workspace. The `~` form is not special-cased — the daemon said a
path, and a path with a tilde is the shell's business rather than a completion's."
  (if (and (plusp (length typed)) (char= (char typed 0) #\/))
      #p"/"
      (let ((ws (%daemon-workspace head)))
        (and ws (plusp (length ws)) (uiop:ensure-directory-pathname ws)))))

(defun %dir-name (pathname)
  "The last component of a DIRECTORY pathname's name — `sub/` reads as `sub`.

**`file-namestring` answers the EMPTY STRING for a directory** (measured on this box: the
namestring of `/tmp/x/sub/` is the directory part and nothing after it), so a listing built from
it would offer a row with no name on it. The component is what a person typed and what has to be
spliced back, so it is read from the pathname's own directory list."
  (let ((parts (pathname-directory pathname)))
    (or (and (consp parts) (car (last parts))) "")))

(defun %dir-entries (dir)
  "Every entry in DIR as `(NAME . IS-DIRECTORY)`, sorted by name.

**Two listings, because `uiop:directory-files` returns files only** — measured: a directory built
beside three files came back with three entries and the directory missing, which would have made
`rust-tools/` unreachable by Tab on exactly the tree that has one. So files come from
`directory-files` and directories from the `dir/*/` wildcard, each named by the function that
knows how to name it."
  (let ((files (ignore-errors
                 (mapcar (lambda (p) (cons (file-namestring p) nil))
                         (uiop:directory-files dir))))
        (subdirs (ignore-errors
                   (mapcar (lambda (p) (cons (%dir-name p) t))
                           (directory (merge-pathnames "*/" dir))))))
    (sort (append files subdirs)
          #'string< :key #'car)))

(defun %path-completions (head typed)
  "Every entry TYPED is a prefix of, as the strings to splice into the line.

**The kind comes from the daemon's row, never from a list here** (R32): the caller has already
established that this tool's bare field is `path`, and nothing in this function knows which tool
it is. What it offers is what EXISTS — the directory is read, not guessed — and the entries are
returned as typed-relative names so the splice is a string substitution.

**A directory completes to a trailing separator and does NOT end the completion** (constraint 2):
the separator is what makes the next Tab read the level below instead of starting again, and it is
added ONCE because a `//` would be a different prefix from the one that was written.

**Matching is CASE-SENSITIVE, and that is a measurement rather than an oversight**: these are
filenames on a case-sensitive filesystem, so offering `README.md` for `ru` would offer a path that
does not resolve — constraint 4's *the completions offered must exist*, read as *under the spelling
the reader is typing*."
  (let* ((root (%path-root head typed))
         ;; the part of TYPED that names a directory to read, and the part that is the needle
         (slash (position #\/ typed :from-end t))
         (dir-part (if slash (subseq typed 0 (1+ slash)) ""))
         (needle (if slash (subseq typed (1+ slash)) typed))
         (dir (and root
                   (probe-file (if (string= "" dir-part)
                                   root
                                   ;; **the resolved pathname, so `directory-pathname-p` sees a
                                   ;; directory**: `merge-pathnames` of a bare name answers a
                                   ;; NAME-only pathname, which is neither a file nor a dir
                                   (merge-pathnames dir-part root))))))
    (when (and dir (uiop:directory-pathname-p (probe-file dir)))
      ;; **THE ANSWER IS THE WHOLE FRAGMENT, not the name.** What comes back stands in for what
      ;; was typed, so the directory the reader had already walked is spliced back with the
      ;; entry — measured as the bug that turned `/read /etc/ho` into `/read host.conf`, losing
      ;; `/etc/` and silently pointing the call at a file in the daemon's workspace.
      (loop for (n . is-dir) in (%dir-entries (uiop:ensure-directory-pathname dir))
            when (and (>= (length n) (length needle))
                      (string= needle n :end2 (length needle)))
              collect (concatenate 'string dir-part
                                   (if is-dir (concatenate 'string n "/") n))))))

(defun %argument-position (head buf)
  "Is BUF a command with an ARGUMENT being typed? — `(values VERB ARGUMENT)`, else NIL.

A line of the form `/name rest` where `name` resolves to a door tool. **Whether a tool has a
bare form at all comes from the daemon's row**, so this answers NIL for a tool the daemon did
not describe and for every verb this head owns — a `/mode al` is not a path and Tab on it stays
the verb's business."
  (let* ((space (position #\space buf))
         (verb (and space (subseq buf 1 space)))
         (arg (and space (subseq buf (1+ space)))))
    (when (and space (not (find #\tab buf)) (not (find #\newline buf)))
      (let* ((name (and verb (%door-name head verb)))
             (d (and name (cdr (assoc name (head-run-descriptors (head-settings head))
                                      :test #'string=)))))
        (when d (values name arg))))))

(defun %complete-argument (head verb arg)
  "Tab in an ARGUMENT position: complete it by the KIND the daemon published, or say why not.

**This is R32's whole design in one function: the head holds no list of which tools take
paths.** `kind` arrives on the tool's own row (`path`, `url`, `text`), and this branches on it:

  · **`path`** — filenames, from the filesystem, relative to the daemon's workspace or from `/`.
  · **`url`** and **`text`** — nothing is offered. A URL has no local completion and a sentence
    has no candidates; inventing a fuzzy match over the repository would be the file picker R32
    explicitly says this is not.
  · **a kind this build has never met** — nothing, and it says so rather than guessing. The
    vocabulary is closed on purpose (a head branches on it), so an unknown kind is a daemon
    newer than this head, and the honest answer is the same one an absent row gets.

**One completion behaviour per key** (constraint 3): the walk is `*completion*`'s, exactly as
the verb position uses it — first match on the first Tab, more Tabs walking the rest — so the
two positions cannot drift into two feels."
  (let* ((d (cdr (assoc verb (head-run-descriptors (head-settings head)) :test #'string=)))
         (kind (getf d :kind)))
    (cond
      ((string= kind "path")
       (let* ((line (composer-buffer (head-composer head)))
              (base (subseq line 0 (- (length line) (length arg))))
              (names (%path-completions head arg)))
         (cond
           (names
            ;; **ONE behaviour per key, and the walk is the verb position's** (constraint 3):
            ;; first match on the first Tab, more Tabs walking the rest — so the two positions
            ;; cannot drift into two feels. The cycle carries the BASE as well, because an
            ;; argument is a fragment of a line rather than the whole of one: the splice has to
            ;; know what came before it, and a character typed on the end must start a fresh
            ;; walk rather than clobber what is there.
            (let ((walked
                    ;; **THE CYCLE IS SHARED BETWEEN TWO POSITIONS, so its SHAPE has to be
                    ;; checked before it is taken apart.** A verb completion leaves
                    ;; `(NAMES IDX)` and an argument completion leaves `(BASE NAMES IDX)`;
                    ;; walking the wrong one is a `destructuring-bind` error thrown from a
                    ;; keystroke — measured by falsifying this file, which is the only reason
                    ;; it was found. Three elements is the argument cycle's own signature.
                    (when (and (consp *completion*) (= 3 (length *completion*)))
                      (destructuring-bind (arg-base seen idx) *completion*
                        (when (and (string= base arg-base) (string= arg (nth idx seen)))
                          (let ((next (mod (1+ idx) (length seen))))
                            (setf *completion* (list base seen next))
                            (%set-composer head (concatenate 'string base (nth next seen)))
                            t))))))
              (unless walked
                (setf *completion* (list base names 0))
                (clear-note head)
                (%set-composer head (concatenate 'string base (first names)))))
            (setf (head-dirty head) t)
            t)
           (t
            (setf *completion* nil)
            (clear-note head)
            (say head (format nil "no file here starts with ~s — the daemon's workspace is ~a"
                              arg (or (%daemon-workspace head) "unknown")))
            (setf (head-dirty head) t)
            t))))
      ((or (string= kind "url") (string= kind "text"))
       (setf *completion* nil)
       (clear-note head)
       (say head (format nil "`~a` takes a ~a — there is nothing here to complete" verb kind))
       (setf (head-dirty head) t)
       t)
      ((zerop (length kind))
       ;; the daemon described the tool and its field but not what the field IS: a daemon newer
       ;; than this row's `kind`, or a tool whose field is its own name
       (setf *completion* nil)
       (say head (format nil "the daemon has not said what kind of thing `~a` takes" verb))
       (setf (head-dirty head) t)
       t)
      (t
       (setf *completion* nil)
       (say head (format nil "`~a`'s argument is a kind this head does not know (`~a`) — nothing is completed for it"
                         verb kind))
       (setf (head-dirty head) t)
       t))))

(defvar *shell-suggestions* nil
  "The model's proposed `!` completions, from the last `shell_suggestions` frame.
 NIL when none has arrived, or when the operator has typed past the prefix they
 were for. Read by `%complete-bang` on the Tab after the history has nothing.")

(defvar *shell-suggestions-for* nil
  "The prefix the last `suggest_shell` frame was sent for. The daemon echoes it
 back on the answer, and this is what the comparison drops a stale answer with.")

(defun %bang-candidates (head)
  "The lines a `!` completion offers, newest first, deduped.

 Two sources, the operator's own and the model's: the operator's `!` rows are
 found by their text (a `User` row whose text starts with `!`, the words verbatim,
 bang included), and the model's `bash` calls are found by their `ToolResult`
 rows (a tool result named `bash`, whose subject is the command it ran, prefixed
 with `!` to make it the same shape as the operator's own). DEDUPED because the
 same command run twice is one candidate, not two."
  (let ((seen (make-hash-table :test #'equal))
        (out nil))
    (loop for item across (session-items (head-session head))
          for body = (item-body item)
          when (and body (string= (getf body :type) "user")
                    (plusp (length (or (getf body :text) "")))
                    (char= (char (getf body :text) 0) #\!))
            do (let ((line (getf body :text)))
                 (unless (gethash line seen)
                   (setf (gethash line seen) t)
                   (push line out))))
    (loop for item across (session-items (head-session head))
          for body = (item-body item)
          when (and body (string= (getf body :type) "tool_result")
                    (string= (or (getf body :name) "") "bash"))
            do (let* ((subject (or (getf body :subject) ""))
                      (line (format nil "! ~a" subject)))
                 (unless (gethash line seen)
                   (setf (gethash line seen) t)
                   (push line out))))
    out))

(defun %complete-bang (head buf)
  "Tab on a `!` line — complete from the commands this session has run, and when
the history has nothing, ask the local model once (protocol 30).

 The candidates are the whole lines from `%bang-candidates`, newest first. A
 prefix nothing matches SAYS SO and sends a `suggest_shell` frame — the daemon
 asks the local model (never a metered provider), and the answer arrives as a
 `shell_suggestions` frame that fills `*shell-suggestions*` for the NEXT Tab.
 A suggestion only fills the composer; Enter is still the operator's."
  (let ((candidates (append
                           ;; **THE MODEL'S SUGGESTIONS, when they are for this prefix** (protocol 30).
                           ;; Appended AFTER the history because the operator's own commands are the
                           ;; better answer — the model's are a guess, and the history is a fact.
                           (and *shell-suggestions*
                                (string= buf (or *shell-suggestions-for* ""))
                                (remove-if-not
                                 (lambda (line) (uiop:string-prefix-p buf line))
                                 *shell-suggestions*))
                           (remove-if-not
                            (lambda (line) (uiop:string-prefix-p buf line))
                            (%bang-candidates head)))))
    (cond
      (candidates
       (%set-composer head (first candidates))
       (setf (head-dirty head) t))
      (t
       ;; **THE HISTORY HAS NOTHING — ASK THE MODEL, ONCE** (daemon `8c9a7b0`).
       ;; The answer arrives later, on a frame the key handler doesn't wait for;
       ;; this Tab says it asked, and the NEXT Tab reads what came back.
       (setf *shell-suggestions-for* buf)
       (%send head (make-suggest-shell buf))
       (say head (format nil "asking the model for a completion…"))))))

(defun %complete (head)
  "Tab on a `/command` — or, when the line starts with `!`, on the commands this
session has run (daemon `b269a36`).

A fresh prefix completes to its FIRST match and MORE TABS WALK THE REST, which is
what `/help` already promised and what the old one could not do: it inserted only
on a unique prefix and otherwise wrote the candidates to the status line, so
`/re` — four commands — printed a list and left the line alone.

The cycle only walks while the line is exactly what the cycle last wrote, so a
character typed on the end starts a fresh match rather than clobbering it. A prefix
nothing matches SAYS SO rather than deleting what was typed to explain why nothing
happened.

**And Tab is TWO POSITIONS now, not one** (R32): a bare `/verb` completes the verb, and
`/verb ARG` completes the argument **by the kind the daemon published for that tool's field** —
filenames for a `path`, nothing for a `url` or free text. The head holds no list of which tools
take paths; that fact arrives on the tool's own row like every other fact about it. **A kind the
daemon has not sent, or one this build has never met, completes nothing and says so** rather
than guessing, which is the same rule an absent descriptor row gets."
  (let ((buf (composer-buffer (head-composer head))))
    ;; **A `!` LINE IS THE SHELL COMPLETION'S OWN QUESTION** (daemon `b269a36`): the
    ;; candidates are the session's own `!` rows and `bash` calls, newest first. Checked
    ;; BEFORE the slash arm because a `!` line is not a command and must not fall through
    ;; to the slash matcher. A bang with nothing after it does nothing, the same refusal
    ;; the submit keeps.
    (if (and (plusp (length buf)) (char= (char buf 0) #\!))
        (%complete-bang head buf)
    (when (uiop:string-prefix-p "/" buf)
      (multiple-value-bind (verb arg) (%argument-position head buf)
        (if verb
            ;; --- the ARGUMENT position
            (%complete-argument head verb arg)
            (when (not (find-if (lambda (ch) (member ch '(#\space #\tab #\newline))) buf))
              ;; --- the VERB position, unchanged
              (let ((walked
                      ;; **and the other half of the same guard**: an ARGUMENT cycle left in
                      ;; the global must not be walked as a verb one. Two elements is the verb
                      ;; cycle's signature, and the check is what keeps one key's memory from
                      ;; being another key's error.
                      (when (and (consp *completion*) (= 2 (length *completion*)))
                        (destructuring-bind (names idx) *completion*
                          (when (and names (string= buf (format nil "/~a" (nth idx names))))
                            (let ((next (mod (1+ idx) (length names))))
                              (setf *completion* (list names next))
                              (%set-composer head (format nil "/~a" (nth next names)))
                              t))))))
                (unless walked
                  (let* ((needle (subseq buf 1))
                         ;; **THE UNION, and not `*slash-commands*` alone.** The head's own rows
                         ;; joined with what the daemon published — five working daemon verbs were
                         ;; missing from completion because this read the head's table as the
                         ;; whole namespace.
                         (names (mapcar #'car
                                        (remove-if-not (lambda (c) (uiop:string-prefix-p needle (car c)))
                                                       (%slash-completions head)))))
                    (cond (names
                           (setf *completion* (list names 0))
                           (clear-note head)
                           (%set-composer head (format nil "/~a" (first names))))
                          (t (setf *completion* nil)
                             (say head (format nil "no /command starts with ~s" buf)))))))
              (setf (head-dirty head) t))))))))
