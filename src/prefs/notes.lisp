;;;; notes — the note file, and TWO writers
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- the note file, and TWO writers ;;;
;;;
;;; **ONE file for every head on the box.** `~/.config/letibot/head.toml` — letibot's own
;;; path — holds the retired set, because that is where the operator's dismissals already
;;; are and because two heads that each keep their own file never share anything. The
;;; requirement: *"persist into the same file, with the same discipline — merge on save,
;;; re-read on listing, never write what you did not read first."*
;;;
;;; **letibot's fix, `e7b6caf`, is the measurement.** Their instrument dumped every warning
;;; in the log against the keys in the file and found six of seven IDENTICAL — code, clock
;;; and detail hash — so the key was never the problem. The problem was the file: each head
;;; loaded it once at startup and wrote its own list back WHOLE, so one head's save erased
;;; another's dismissals. The operator: *"i dismissed letibot notes but they stay."*
;;;
;;; **This head had the same shape waiting for it.** R19 part 3 gave it persistence, and in
;;; doing so made it the second writer to a file it did not own — so a wholesale write here
;;; would clobber letibot's dismissals exactly as letibot was clobbering its own, and the
;;; operator would see the bug they had just had fixed come back wearing this head's name.
;;;
;;; Two things are taken from letibot's `prefs.rs` and they must match **byte for byte**,
;;; because a format that differs is a file that is corrupt rather than shared:
;;;
;;;   · **the format**: `retired = "k1,k2,k3"` — one quoted line, comma-joined, no spaces,
;;;     through the same flat `key = "value"` parser this file already has;
;;;   · **the merge**: a save UNIONS with the file and caps at 512 from the FRONT (oldest
;;;     dropped first). A dismissal is an assertion that a key is retired, and no other
;;;     head's save is evidence to the contrary.
;;;
;;; Nothing else is taken: the four preference keys stay this head's own, in this head's own
;;; file. `diff`/`thinking`/`tools`/`raw_calls` happen to share a vocabulary, but sharing
;;; them would mean `ctrl-t` in one head moving the other's screen, which is a different and
;;; much larger decision than the one that was asked for.

(defvar *notes-path-override* nil
  "Where the notes file is, when a caller says. NIL means `shared-notes-path`.

**A `defvar` for the reason `*write-prefs*` is one, and worse.** The notes file is the
OPERATOR'S — `~/.config/letibot/head.toml`, shared with another head — and a test that reads
it makes the suite depend on their dismissals, while a test that writes it edits their
config. Measured within minutes of wiring this up: a test asserting a dismissal round-trips
through the file read the seven keys the operator actually had, and the next assertion wrote
over them.

So the suite binds this to a directory of its own (`run-all`), and every function in this
block goes through it rather than computing the path for itself.")

(defun notes-path ()
  "The notes file: the override when one is bound, else `shared-notes-path`."
  (or *notes-path-override* (shared-notes-path)))

(defun shared-notes-path ()
  "**The one file every head on this box retires notes in** — letibot's own path.

`$XDG_CONFIG_HOME/letibot/head.toml`, else `~/.config/letibot/head.toml`, else NIL. Not
`leticl/head.toml`: the share is the point, and the operator's existing dismissals are
already in this one."
  (let ((xdg (uiop:getenv "XDG_CONFIG_HOME"))
        (home (uiop:getenv "HOME")))
    (cond (xdg (merge-pathnames "letibot/head.toml"
                                (uiop:ensure-directory-pathname xdg)))
          (home (merge-pathnames "letibot/head.toml"
                                 (merge-pathnames ".config/"
                                                  (uiop:ensure-directory-pathname home))))
          (t nil))))

(defun read-retired-keys (&optional (path (notes-path)))
  "The retired keys in PATH, and whether the file could be READ.

`(values KEYS READABLE-P)`, and the second value is the whole of the discipline this file
needs. Three cases, and they are three facts rather than two:

  · **no path, or no file** — `(values nil t)`. A head with no config directory and a head
    starting for the first time are both *nothing retired*, and both may create the file.
  · **a file that exists and cannot be read** — `(values nil nil)`. **NOT the empty set.**
    This is the case the operator named: *a head that cannot read it must not silently start
    from empty and then save over a file it never read.* A permissions error, an invalid
    encoding, a directory where a file should be. The head keeps its own retirements in
    memory and **refuses to write the file** for the rest of the session, saying so once.
  · **a file that reads** — its keys, oldest first, capped from the front.

The keys are this head's own identity format (`w|code|ts|fnv1a16`, `warning-identity`) and
they sit in the file beside letibot's `n|…` and `d|…` ones, which are kept and never
produced here. Nothing in this function looks at the format: a key is opaque text that is
matched by equality."
  (cond
    ((null path) (values nil t))
    ((not (probe-file path)) (values nil t))
    (t (handler-case
           (let* ((text (uiop:read-file-string path))
                  (keys nil))
             (dolist (line (%parse-prefs text))
               (when (and (eq (first line) :pair)
                          (string= (second line) "retired"))
                 (setf keys (string->retired (third line)))))
             (values (last keys (min (length keys) +retired-cap+)) t))
         (error () (values nil nil))))))

(defun merge-retired-keys (path ours)
  "OURS unioned with what PATH holds, capped at `+retired-cap+` from the FRONT.

letibot's `merge_retired`, and the union is the correct write for a shared record: **no
other head's save is evidence against a dismissal**, so the file only ever grows from
either writer. The cap drops the OLDEST (the front), because a reader who dismissed
something today wants it to survive the restart tomorrow.

**The caller must have read the file first** — see `save-retired-keys`, which takes the keys
it read as an argument rather than re-reading behind the caller's back, so *never write what
you did not read* is enforced by the shape of the call and not by a comment."
  (let* ((existing (read-retired-keys path))
         (out (append existing (remove-if (lambda (k) (member k existing :test #'string=))
                                          ours))))
    (last out (min (length out) +retired-cap+))))

(defun save-retired-keys (keys &key replace)
  "Write KEYS into the shared file, KEEPING every other line where it was.

  · **default (a dismissal)** — the file's keys UNIONED with KEYS. Monotone.
  · **REPLACE (a restore)** — the file's list is REPLACED by KEYS. **A restore is contrary
    evidence and the union rule must not swallow it**: `/notes restore` is the same reader
    saying those keys are not retired after all, and a union would put every one of them
    back on the next re-read. That is a defect letibot's own tree has — see the report in
    the requirements document — and copying the merge without this distinction would copy it.

**A file this head could not read is never written.** The second value of
`read-retired-keys` is the gate: an unreadable file means *do not write*, and the reason is
returned so the caller can say it once. Writing a union requires having read the file; a
wholesale write over a file the head never saw is exactly the erase-other-heads'-dismissals
defect in a new costume.

**Through a temporary file and one rename**, letibot's discipline and for their reason:
`with-open-file` truncates then writes, so a second head reading at the wrong moment sees a
PARTIAL list — and a head that loaded a partial list would save the partial one back, which
is how a dismissal is lost with nothing to point at. The temporary is written in the SAME
directory so the rename cannot cross a filesystem, and it is named after the target so two
heads racing produce two temporaries rather than one collision.

Returns NIL when it wrote, and a string saying why when it did not."
  (let ((path (notes-path)))
    (cond
      ((null path) "no $HOME or $XDG_CONFIG_HOME to write the notes file to")
      (t
       (multiple-value-bind (existing readable) (read-retired-keys path)
         (cond
           ((not readable) "the notes file exists and could not be read, so it was left alone")
           (t
            (let* ((final (if replace
                              (last keys (min (length keys) +retired-cap+))
                              (let ((out (append existing
                                                 (remove-if (lambda (k)
                                                              (member k existing :test #'string=))
                                                            keys))))
                                (last out (min (length out) +retired-cap+)))))
                   (existing-text (if (probe-file path) (uiop:read-file-string path) "")))
              (handler-case
                  (progn
                    (ensure-directories-exist path)
                    (let ((tmp (merge-pathnames
                                (format nil ".~a.tmp" (file-namestring path))
                                (uiop:pathname-directory-pathname path))))
                      (with-open-file (f tmp :direction :output :if-exists :supersede
                                             :if-does-not-exist :create)
                        (dolist (line (%retired-file-lines existing-text final))
                          (write-line line f)))
                      (rename-file tmp path)))
                (error (e) (format nil "~a" e)))))))))))

(defun %retired-file-lines (existing-text keys)
  "EXISTING-TEXT with its `retired` line replaced by KEYS — or with one added.

**Everything else goes back BYTE FOR BYTE, and that is not tidiness — it is the property
that makes a shared file possible.** This file is written by two heads; a line this head did
not write is the other head's, and re-rendering it from a parsed value changes bytes that
are not this head's to change. Measured, and it cost the operator their file: an earlier
version of this function rebuilt every line as `~a = ~s`, which turned letibot's
`raw_calls = false` into `raw_calls = \"false\"` — the same preference spelled differently,
which letibot's own round trip then has to cope with, and which a `diff` of the file shows
as this head having rewritten somebody else's settings.

So this works on RAW LINES: the only line it touches is the one whose key is `retired`, and
a line is recognised by the same rule `%parse-prefs` uses (trimmed, not blank, not `#`, not
`[`, and it contains an `=`). The replacement is written at the position the line already
had, so a person reading the file sees it stay where they left it."
  (let* ((raw (uiop:split-string (or existing-text "") :separator '(#\newline)))
         ;; a text ending in a newline splits into one more element than it has lines, and
         ;; that trailing "" is dropped so every save does not append a blank line
         (lines (if (and raw (zerop (length (car (last raw))))) (butlast raw) raw))
         (out nil)
         (written nil))
    (dolist (line lines)
      (let ((trimmed (string-trim '(#\space #\tab #\return) line)))
        (if (and (plusp (length trimmed))
                 (not (char= (char trimmed 0) #\#))
                 (not (char= (char trimmed 0) #\[))
                 (let ((eq (position #\= trimmed)))
                   (and eq (string= "retired" (string-trim " " (subseq trimmed 0 eq))))))
            (progn
              (push (format nil "retired = ~a" (%quote-value (retired->string keys))) out)
              (setf written t))
            ;; **verbatim**, whatever it is: the other head's key, the operator's comment,
            ;; a section header, a line this build does not understand.
            (push line out))))
    (unless written
      (push (format nil "retired = ~a" (%quote-value (retired->string keys))) out))
    (when (null (cdr out))
      (push "# letibot head preferences — edited by the /config pane, or by hand" out))
    (nreverse out)))
(defparameter +retired-cap+ 512
  "How many retired notes one head remembers, on disk and in memory.

**The reference's own number** (`RETIRED_CAP`, `prefs.rs:18-26`) and the reference's own
reason: it is *a cap on this reader's memory, not on the log* — the notes themselves are
in the session log whatever is here, and `/notes` lists every one the head still holds.
What falls off the end is a dismissal, so a note that fell off would come back on the
next snapshot. Far above what any session produces, deliberately, rather than tuned to
it.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defun retired->string (identities)
  "IDENTITIES as the ONE value `head.toml` holds: comma-separated, newest LAST.

Newest last because that is the end the cap drops from — an old dismissal is the one
worth forgetting, and a reader who dismisses something today wants it to survive the
restart tomorrow. **A comma is a separator and nothing else**, because an identity has no
comma in it: it is `w|{code}|{ts}|{fnv1a-hex}`, and a hash is hex digits."
  (format nil "~{~a~^,~}"
          (last identities (min (length identities) +retired-cap+))))

(defun string->retired (value)
  "The inverse of `retired->string`. NIL for an empty value, and for a value that is not
a string at all — a hand-edited `head.toml` is the operator's file and a line they mangled
should cost a dismissal, not a start.

Each entry is TRIMMED and an all-whitespace one is dropped, so `retired = \"\"` and
`retired = \" , \"` both read as *nothing retired* rather than as one identity that can
never match. An identity never carries surrounding space — it is `w|{code}|{ts}|{hex}`,
built by `warning-identity` — so trimming cannot lose one."
  (when (and (stringp value) (plusp (length value)))
    (remove "" (mapcar (lambda (e) (string-trim '(#\space #\tab #\return) e))
                       (uiop:split-string value :separator '(#\,)))
            :test #'string=)))

(defun load-prefs (&optional path)
  "Read the file at PATH (default `prefs-path`) into a `prefs`.

A missing file is the defaults and NO complaint — the first run of a head is not
an error. A value this build cannot read is named in the second value and the
default is kept, because refusing to start over one bad line is a worse failure
than the bad line. Returns `(values prefs notes)`."
  (let ((path (or path (default-prefs-path)))
        (p (make-prefs))
        (notes nil))
    (setf (prefs-path p) path)
    (when (and path (uiop:file-exists-p path))
      ;; **A file that exists and cannot be READ is a note, not a refusal.** The
      ;; parser already treats a bad LINE that way, but the read itself was
      ;; unguarded: a `head.toml` owned by another user, or one holding bytes
      ;; that are not UTF-8, signalled out of `load-prefs-into` and the head
      ;; never started — the operator's own preferences file locking them out of
      ;; the tool. Same rule as the bad line: name it, keep the defaults.
      (dolist (line (%parse-prefs
                     (handler-case (uiop:read-file-string path)
                       (error (e)
                         (push (format nil "head.toml: cannot be read (~a) — using the defaults" e)
                               notes)
                         ""))))
        (when (eq (first line) :pair)
          (destructuring-bind (key value) (rest line)
            (cond
              ((string= key "diff")
               (cond ((member value '("split" "side-by-side" "auto") :test #'string=)
                      (setf (prefs-diff p) "split"))
                     ((member value '("unified" "single") :test #'string=)
                      (setf (prefs-diff p) "unified"))
                     (t (push (format nil "head.toml: diff = ~s is not split or unified"
                                      value) notes))))
              ((string= key "thinking")
               (if (member value '("open" "folded") :test #'string=)
                   (setf (prefs-thinking p) value)
                   (push (format nil "head.toml: thinking = ~s is not open or folded"
                                 value) notes)))
              ((string= key "tools")
               (if (member value '("open" "folded") :test #'string=)
                   (setf (prefs-tools p) value)
                   (push (format nil "head.toml: tools = ~s is not open or folded"
                                 value) notes)))
              ((string= key "raw_calls")
               (let ((b (%bool-value value)))
                 (if (eq b :unknown)
                     (push (format nil "head.toml: raw_calls = ~s is not true or false"
                                   value) notes)
                     (setf (prefs-raw-calls p) b))))
              ((string= key "marker_seam")
               (let ((b (%bool-value value)))
                 (if (eq b :unknown)
                     (push (format nil "head.toml: marker_seam = ~s is not true or false"
                                   value) notes)
                     (setf (prefs-marker-seam p) b))))
              ((string= key "verbosity")
               ;; **A word this build cannot read is NAMED, and the file keeps it** (letibot's own
               ;; rule for its rungs). The alternative — silently writing a different word back —
               ;; is how a typo and a deliberate value become the same screen; and a reader who
               ;; chose a rung should not have it quietly changed to another one.
               (let ((rung (verbosity-for-word value)))
                 (cond (rung (setf (prefs-verbosity p) (verbosity-name rung)))
                       (t (push (format nil "head.toml: verbosity = ~s is not one of ~{~a~^, ~}"
                                        value
                                        (mapcar #'verbosity-name +verbosity-ladder+))
                                notes)))))
              ((string= key "git_format")
                ;; **A QUOTED TEMPLATE, or `false` for the default.** A bare `git_format = %b`
                ;; would be a template nobody meant, so it has to be quoted the way
                ;; `todo_template`'s path is — and anything unquoted is refused BY NAME rather
                ;; than read as a one-word format.
                (cond ((and (>= (length value) 2)
                            (char= (char value 0) #\")
                            (char= (char value (1- (length value))) #\"))
                       (setf (prefs-git-format p) (subseq value 1 (1- (length value)))))
                      ((or (string= value "false") (string= value "nil") (string= value ""))
                       (setf (prefs-git-format p) nil))
                      (t (push (format nil "head.toml: git_format = ~s is a QUOTED template, or false for the default"
                                       value)
                               notes))))
               ((string= key "todo_template")
               ;; **THREE ANSWERS, and the third is why this is not a boolean.** `false` is off;
               ;; `true` is the default template file; a QUOTED STRING is a path to another one.
               ;; Reading a bare path as a truthy string would turn `todo_template = "typo.md"` into
               ;; "on, using the default", which is the wrong file silently.
               (cond
                 ((member value '("false" "off") :test #'string=)
                  (setf (prefs-todo-template p) nil))
                 ((member value '("true" "on") :test #'string=)
                  (setf (prefs-todo-template p) t))
                 ((and (>= (length value) 2)
                       (char= (char value 0) #\")
                       (char= (char value (1- (length value))) #\"))
                  (setf (prefs-todo-template p) (subseq value 1 (1- (length value)))))
                 (t (push (format nil "head.toml: todo_template = ~s is true, false, or a quoted path"
                                  value)
                          notes))))
              ((string= key "retired")
               ;; **A key that used to be ours, read as nothing and left where it is**
               ;; (R24). The retired set lives in the file every head shares now
               ;; (`~/.config/letibot/head.toml`), reached through `load-retired-into`;
               ;; this line is what R19 part 3 left in THIS head's file, and it is kept
               ;; because a save puts every line it did not write back where it found it.
               ;;
               ;; The arm exists so the line is RECOGNISED rather than reported as a key
               ;; this head does not know — the operator's own file grew one, and a build
               ;; that complained about its own history on every start would be the worse
               ;; bug. Nothing is set: a value here cannot be trusted to be current, and
               ;; the whole point of the move is that there is only one place it lives.
               nil)
              (t (push (format nil "head.toml: `~a` is not a key this head knows"
                               key) notes)))))))
    (values p (nreverse notes))))

(defun save-prefs (p &optional path)
  "Write P, keeping every line that is not one of ours where it was.

A comment, a `[section]`, a key from a newer build — all preserved in place, and
a key of ours that is already in the file is REPLACED rather than appended, so
the file does not grow a second `diff =` on every change. Creates the directory.
Returns the path written, or NIL for a head with nowhere to write."
  (let* (;; **THE PATH THE PREFERENCES CAME FROM, before the default.** `:path` is
         ;; documented as *"where it came from, so a save goes back there"* and it was
         ;; not honoured: `save-prefs` took the argument or fell through to
         ;; `default-prefs-path`, so a head that loaded `--prefs FILE` (or, in the
         ;; suite, a temp file) wrote its next change to `$HOME` instead. Found by
         ;; writing R19 part 3's test, which has to point a head at a file it owns.
         (path (or path (prefs-path p) (default-prefs-path)))
         (ours (list (cons "diff" (format nil "~s" (prefs-diff p)))
                     (cons "thinking" (format nil "~s" (prefs-thinking p)))
                     (cons "tools" (format nil "~s" (prefs-tools p)))
                     (cons "raw_calls" (if (prefs-raw-calls p) "true" "false"))
                      ;; **Quoted like `todo_template`'s path**, because a template with a space
                      ;; in it is legal and an unquoted one would come back as two keys. NIL is
                      ;; `false`, which is the default.
                      (cons "git_format" (if (prefs-git-format p)
                                             (format nil "~s" (prefs-git-format p))
                                             "false"))
                     (cons "marker_seam" (if (prefs-marker-seam p) "true" "false"))
                     ;; **Quoted like letibot spells its own**, so the two heads' files read
                     ;; alike for a key they share a vocabulary for.
                     (cons "verbosity" (format nil "\"~a\"" (prefs-verbosity p)))
                     ;; `true`/`false` for the switch and a QUOTED path for a file, so what is
                     ;; written is exactly what the parse arm above reads back.
                     (cons "todo_template"
                           (let ((v (prefs-todo-template p)))
                             (cond ((null v) "false")
                                   ((eq v t) "true")
                                   (t (format nil "~s" v))))))))
    ;; **`retired` is deliberately absent** (R24): the set it names belongs to the file
    ;; every head shares, and `persist-retired` writes it there. A save of the four choices
    ;; must not drag a copy of it back into this file — that is how a set comes to have two
    ;; homes and one of them stale. A `retired` line already here is preserved as somebody
    ;; else's key, which is what it now is.
    (unless path
      ;; say so rather than writing into the working directory, where a file
      ;; nobody asked for would appear
      (return-from save-prefs nil))
    (setf (prefs-path p) path)
    (let ((existing (if (uiop:file-exists-p path)
                        (uiop:read-file-string path)
                        ""))
          (written nil)
          (out nil))
      (dolist (line (%parse-prefs existing))
        (cond
          ((and (eq (first line) :pair)
                (assoc (second line) ours :test #'string=))
           (let* ((key (second line))
                  (pair (assoc key ours :test #'string=)))
             (push (format nil "~a = ~a" key (cdr pair)) out)
             (pushnew key written :test #'string=)))
          ((eq (first line) :pair)
           ;; somebody else's key: rewritten through the ONE function that can quote a
           ;; value a person might have put a `"` inside — see `%quote-value`. `~s` would
           ;; escape it as `\"`, which `%unquote` reads back with the backslash still on,
           ;; so the value would change on a save that was supposed to leave it alone.
           (push (format nil "~a = ~a" (second line) (%quote-value (third line))) out))
          ;; an `:other` line carries its RAW TEXT as the second element —
          ;; `(:other raw)`, two elements, which is what makes "keep what we do
          ;; not own" work. Reading `(third line)` here took NIL into a string
          ;; operation and the save died; the parse/save pair has to agree on the
          ;; shape, and this is the shape the parser writes.
          (t (push (second line) out))))
      (when (null out)
        (push "# leticl head preferences — edited by /config, or by hand" out))
      (dolist (pair ours)
        (unless (member (car pair) written :test #'string=)
          (push (format nil "~a = ~a" (car pair) (cdr pair)) out)))
      (ensure-directories-exist path)
      (with-open-file (f path :direction :output :if-exists :supersede
                              :if-does-not-exist :create)
        (dolist (l (nreverse out))
          (write-line l f)))
      path)))
