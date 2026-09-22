;;;; prefs.lisp — the head's own preferences, on disk.
;;;;
;;;; Ported from crates/tui/src/prefs.rs. What a head chooses about how it draws
;;;; used to live only in the running struct and die with the process, and was
;;;; moved by slash commands nobody remembered. The operator's ask, verbatim:
;;;; *"i'd prefer a config option and a pane with runtime-able configurations
;;;; editable"*.
;;;;
;;;; The format is the flat `key = "value"` subset `providers.toml` already uses,
;;;; parsed by hand for the same reason: four keys do not earn a dependency, and
;;;; a file a person edits with `vi` must survive a comment and a key this build
;;;; does not know. **Unknown lines are kept where they were on write**, which is
;;;; the property that makes the file the operator's and not ours.
;;;;
;;;; `~/.config/leticl/head.toml` — deliberately our own name beside letibot's,
;;;; so the two heads do not fight over one file's keys.

(in-package #:leticl)

(defparameter *prefs-keys*
  '("diff" "thinking" "tools" "raw_calls" "retired")
  "The keys THIS build owns. Anything else in the file is somebody else's — a
newer build's, or the operator's — and is preserved verbatim.

`retired` is R19 part 3 and the odd one of the five: the other four are choices about
how the head DRAWS, and this is a memory of what the reader has already read. It belongs
in the same file because it has the same lifetime — it has to outlive the process — and
because a second file for one key is a second thing to find, back up and lose.")

;;; A PLIST, not a struct, and this is a live-update decision rather than a
;;; stylistic one. `defstruct` is SKIPPED by `tui-eval --file` because a changed
;;; struct layout is a hard error in this SBCL, so a struct defined here could
;;; never reach a head that started before this file existed — S5 would have
;;; needed a restart, which is the one thing a live head must not need. Measured:
;;; pushing this file to a head without it left `make-prefs` undefined.
;;;
;;; It is also this repo's own convention. PLAN.md D4: state is plists all the
;;; way down, so a model hacking a live head inspects exactly what it has. The
;;; reference uses a Rust struct because Rust has no other option; the fields
;;; are the same four, under the same four names.

(defparameter *prefs-defaults*
  (list :diff "split"        ; `split` (two panels) or `unified` always — the
                             ; toggle is the whole choice; the width is the
                             ; renderer's business
        :thinking "folded"   ; `open` or `folded`
        :tools "folded"
        :raw-calls nil       ; show the model's `<function=…>` markup under a call
        :retired nil         ; warning identities the reader has retired (R19 part 3)
        :path nil)           ; where it came from, so a save goes back there; NIL
                             ; for a head with nowhere to write, which SAYS SO
                             ; rather than writing into the working directory
  "The defaults: split diff, folds closed, raw calls hidden, nothing retired.")

(defun make-prefs ()
  "The defaults, as a fresh plist."
  (copy-list *prefs-defaults*))

;; Field accessors over the plist — the same four names the reference uses, so a
;; reader of either knows the other.
(defun prefs-diff (p)     (getf p :diff))
(defun prefs-thinking (p) (getf p :thinking))
(defun prefs-tools (p)    (getf p :tools))
(defun prefs-raw-calls (p)(getf p :raw-calls))
(defun prefs-retired (p)  (getf p :retired))
(defun prefs-path (p)     (getf p :path))

(defun (setf prefs-diff) (v p)     (setf (getf p :diff) v))
(defun (setf prefs-thinking) (v p) (setf (getf p :thinking) v))
(defun (setf prefs-tools) (v p)    (setf (getf p :tools) v))
(defun (setf prefs-raw-calls) (v p)(setf (getf p :raw-calls) v))
(defun (setf prefs-retired) (v p)  (setf (getf p :retired) v))
(defun (setf prefs-path) (v p)     (setf (getf p :path) v))

;;; ------------------------------------------- the bridge to a running head ;;;
;;;
;;; The head's live choices live in `head-prefs`, a keyword PLIST (wire-shaped
;;; state and the head's own state are both plists here, per PLAN D4), and the
;;; file holds them in a `prefs` struct. This is where the two are reconciled
;;; once — the same shape as the reference's `prefs()`/`load_prefs()` pair.
;;;
;;; The head object is NOT extended with a slot: a `defstruct` layout change is
;;; a hard error in this SBCL, so it would mean a restart, which is the one thing
;;; a live head must not need. The loaded file is a global instead; there is one
;;; head per process, so a global here costs nothing and is pushable.

(defvar *prefs* nil
  "The `prefs` loaded at startup, or NIL before `load-prefs-into` runs.

A defvar: a push must not replace a running head's preferences with a fresh
default struct.")

(defun fold-name (on) (if on "open" "folded"))
(defun fold-on-p (name) (string= name "open"))

(defun prefs-into-head (head p)
  "Apply a loaded `prefs` to HEAD's live plist.

Through the setter, so loading a file invalidates the render cache exactly as
flipping a chord does — a head whose `head.toml` says `tools = \"open\"` must draw
the tool output on the first frame, not on the second.

**And the retired set, which is the one thing here that is not a preference** (R19 part
3). It goes onto the SESSION because that is where the membership test reads it, and it
has to be in place BEFORE the first snapshot lands: a warning retired on a previous run
must be replanted retired, not drawn and then hidden a frame later. `run` calls this
before it attaches, and `ingest-snapshot` is only reached through the attach."
  (setf (head-pref head :show-reasoning) (fold-on-p (prefs-thinking p))
        (head-pref head :show-tools) (fold-on-p (prefs-tools p))
        (head-pref head :raw-calls) (prefs-raw-calls p)
        (head-pref head :diff) (prefs-diff p))
  (setf (session-retired (head-session head)) (copy-list (prefs-retired p)))
  (setf *prefs* p)
  head)

(defun head-into-prefs (head)
  "HEAD's live plist as a `prefs`, for saving."
  (let ((p (or *prefs* (make-prefs))))
    (setf (prefs-thinking p) (fold-name (getf (head-prefs head) :show-reasoning))
          (prefs-tools p) (fold-name (getf (head-prefs head) :show-tools))
          (prefs-raw-calls p) (and (getf (head-prefs head) :raw-calls) t)
          (prefs-diff p) (or (getf (head-prefs head) :diff) "split")
          ;; the session's own set, which the head did not choose and cannot lose
          (prefs-retired p) (copy-list (session-retired (head-session head))))
    p))

(defun load-prefs-into (head &optional path)
  "Read the file (default `prefs-path`) and apply it to HEAD.

Returns the notes the load produced, which are worth SAYING once — a value this
build cannot read is named rather than swallowed — and does not treat a missing
file or a bad line as a reason to refuse to start."
  (multiple-value-bind (p notes) (load-prefs path)
    (prefs-into-head head p)
    notes))

(defvar *write-prefs* t
  "Does a preference change go to the FILE? T for a head the operator is using, NIL
for a test.

**The suite has been editing the operator's `head.toml`.** Measured: with
`XDG_CONFIG_HOME` pointed at an empty directory, `sbcl --script run.lisp test`
CREATES `…/leticl/head.toml` and writes whatever the last chord test left in the
head — and on this box the real file's mtime moves on every suite run. A test that
changes the answer to the question it is asking is the same defect as a global that
survives between tests, and it is worse here: the value is on disk and outlives the
process, so a head started afterwards reads a fold the operator never chose.

A `defvar` so a test can bind it, and one switch rather than a path check per call
site, for the reason the preference setter gives: *the fifth site is the one that
would forget*.")

(defun save-head-prefs (head &optional path)
  "Write HEAD's live choices, unless this image is a test. Returns the path, or NIL."
  (when *write-prefs*
    (save-prefs (head-into-prefs head) path)))

(defun persist-retired (head)
  "Write the session's retired set, and swallow a failure into a NIL.

**The ONE place a retirement is persisted**, called by the one place one is made
(`%notes`) — for the reason the preference setter gives, that *the fifth site is the one
that would forget*, and here forgetting means a dismissal the operator believes in and
the file does not.

**A failure is not fatal and is not silent either.** A read-only `head.toml`, a full
disk or a missing `$XDG_CONFIG_HOME` leaves the retirement live in this process and
absent from the file; the caller says so, and the operator can see why their dismissal
did not survive the last restart. The alternative — signalling out of a `/notes` — would
make a cosmetic failure into a lost command."
  (handler-case (progn (save-head-prefs head) nil)
    (error (e) (format nil "not saved: ~a" e))))

;;; ------------------------------------------------------- the fold setter ;;;
;;;
;;; **One place sets a preference, and it is the place that invalidates the
;;; render cache.** Four sites were mutating `head-prefs` directly — `%flip-fold`,
;;; ctrl-x's reveal, `%flip-head-setting` and `prefs-into-head` — and every one of
;;; them changed how the transcript RENDERS. The line cache's key is a generation
;;; counter, the width and the items vector's identity, so a preference change is
;;; invisible to it: measured, flipping `:show-tools` moved the pref from T to NIL
;;; and left the generation at 29, so the cache served the previous lines back and
;;; `ctrl-t` did nothing on screen. The operator: *"thinking and tools are no
;;; longer togglable"*.
;;;
;;; A setter rather than a `(incf *hist-generation*)` at each site, because the
;;; fifth site is the one that would forget.

(defun (setf head-pref) (value head which)
  "Set HEAD's preference WHICH, and invalidate the rendered history.

Every preference changes how a row is drawn — the three folds and the diff shape
are read by `item-lines` — so the cache is stale the moment one moves."
  (setf (getf (head-prefs head) which) value)
  (incf *hist-generation*)
  (setf (head-dirty head) t)
  value)

(defun head-pref (head which)
  "HEAD's preference WHICH."
  (getf (head-prefs head) which))

(defun %flip-fold (head which)
  "Toggle one fold in the live plist AND persist it.

Saving here rather than at each call site is the point: a fold the operator set
should outlive the process, and the reference's header records exactly the
defect this fixes — the choices *\"used to live in the process and die with it,
and was moved by slash commands nobody remembered\"*."
  (let ((now (not (head-pref head which))))
    (setf (head-pref head which) now)
    (ignore-errors (save-head-prefs head))
    now))

;;; -------------------------------------------------------------- the path ;;;

(defun default-prefs-path ()
  "`$XDG_CONFIG_HOME/leticl/head.toml`, or `~/.config/leticl/head.toml`.
NIL when neither variable is set — a head with nowhere to write."
  (let ((xdg (uiop:getenv "XDG_CONFIG_HOME"))
        (home (uiop:getenv "HOME")))
    (cond (xdg (merge-pathnames "leticl/head.toml"
                                (uiop:ensure-directory-pathname xdg)))
          (home (merge-pathnames "leticl/head.toml"
                                 (merge-pathnames ".config/"
                                                  (uiop:ensure-directory-pathname home))))
          (t nil))))

;;; ------------------------------------------------------------ the format ;;;

(defun %quote-value (v)
  "V as a `key = \"value\"` line's value, wrapped in quotes and escaped by NOTHING.

**Not `~s`, which is what the four preference keys use, and the difference is a real
one found by R19 part 3's round-trip test.** `~s` escapes a `\"` as `\"` and a `\\` as
`\\\\`, and `%unquote` — which reads the file — strips the outer pair and unescapes
neither. That is harmless for `diff`, `thinking`, `tools` and `raw_calls`, whose values
come from fixed sets; it is wrong for an identity, which carries a warning's DETAIL, and
the operator's own detail was `nearly full, and \"quoted\" — see a|b`. Measured: the
identity read back was `nearly full%2C and \\\"quoted\\\" — see a%7Cb`, one backslash
away from the one in memory, so the membership test missed and the dismissal did not
survive the restart — silently, which is the failure this whole part is about.

What the file gets instead is the TOML spelling a person would write by hand: a quoted
value with the quotes only at the ends, which `%unquote` reads back exactly."
  (format nil "~c~a~c" #\" v #\"))

(defun %unquote (v)
  "Strip the quotes a value may carry, from either kind of quote."
  (let ((s (string-trim " " v)))
    (if (and (>= (length s) 2)
             (member (char s 0) '(#\" #\'))
             (char= (char s (1- (length s))) (char s 0)))
        (subseq s 1 (1- (length s)))
        s)))

(defun %parse-prefs (text)
  "TEXT to a list of lines, each `(:pair key value)` or `(:other raw)`.

A blank line, a comment and a `[section]` header are all `:other` — kept, in
order, so a write can put them back where they were. A line with no `=` is also
somebody else's.

A text ending in a newline splits into one MORE element than it has lines, the
last being empty; that trailing element is dropped, because keeping it means
every save appends a blank line and the file grows on each change — which is the
same defect as duplicating a key, one line at a time."
  (let ((raw-lines (uiop:split-string text :separator '(#\newline))))
    (when (and raw-lines (zerop (length (car (last raw-lines)))))
      (setf raw-lines (butlast raw-lines)))
    (loop for raw in raw-lines
          for l = (string-trim '(#\space #\tab #\return) raw)
          collect (cond ((or (zerop (length l))
                             (char= (char l 0) #\#)
                             (char= (char l 0) #\[))
                         (list :other raw))
                        (t (let ((eq (position #\= l)))
                             (if eq
                                 (list :pair (string-trim " " (subseq l 0 eq))
                                       (%unquote (subseq l (1+ eq))))
                                 (list :other raw))))))))

(defun %bool-value (v)
  "T, NIL, or :unknown for a string that is neither."
  (cond ((member v '("true" "yes" "on") :test #'string=) t)
        ((member v '("false" "no" "off") :test #'string=) nil)
        (t :unknown)))

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
restart tomorrow. The identities are already escaped by `warning-identity`, so a comma
here is a separator and nothing else."
  (format nil "~{~a~^,~}"
          (last identities (min (length identities) +retired-cap+))))

(defun string->retired (value)
  "The inverse of `retired->string`. NIL for an empty value, and for a value that is not
a string at all — a hand-edited `head.toml` is the operator's file and a line they mangled
should cost a dismissal, not a start.

Each entry is TRIMMED and an all-whitespace one is dropped, so `retired = \"\"` and
`retired = \" , \"` both read as *nothing retired* rather than as one identity that can
never match. An identity never carries surrounding space — it is `code|ts|detail` with the
detail escaped — so trimming cannot lose one."
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
              ((string= key "retired")
               ;; **Read, and it is the one key whose value came from elsewhere.** The
               ;; four above are choices the operator made in a pane; this is a list of
               ;; identities the head wrote down itself, keyed per incident, so two
               ;; sessions do not share a dismissal. Nothing to validate beyond the
               ;; shape: an identity is opaque here, and a wrong one costs a dismissal
               ;; (a note comes back), never a start.
               (setf (prefs-retired p) (string->retired value)))
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
                     ;; quoted, and by the ONE function that can quote a value
                     ;; containing a quote — see `%quote-value` for the measurement
                     (cons "retired" (%quote-value (retired->string
                                                    (prefs-retired p)))))))
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
           ;; somebody else's key: rewritten in our quoting so a save round-trips
           (push (format nil "~a = ~s" (second line) (third line)) out))
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
