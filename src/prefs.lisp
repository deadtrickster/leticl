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
  '("diff" "thinking" "tools" "raw_calls" "verbosity")
  "The keys THIS build owns, in THIS head's own file. Anything else is somebody else's — a
newer build's, or the operator's — and is preserved verbatim.

**Five, and `retired` is not one of them (R24).** `retired` was the odd one out: the others are
choices about how the head DRAWS, and it was a memory of what the reader has already read. R19
part 3 put it here because this file has the right lifetime — it has to outlive the process —
and the requirement then moved it to the file EVERY head writes (`~/.config/letibot/head.toml`),
so that a dismissal made in either head is honoured by both: a set in two files is a set that
disagrees with itself. See `load-retired-into`.

**`verbosity` is the fifth and it belongs here rather than in the shared file** (R42's sibling,
letibot's `1da8f08`). Two reasons, and the second is a measurement rather than a preference: the
rung is a drawing choice like the folds, and **the two heads spell R37's rung with two different
words** — this head's `reading`, letibot's `conversation`. Writing this head's word into the file
letibot reads would put a value IT cannot read in front of it on every start, and letibot reports
an unknown value by name and leaves it in the file — so the bug would be permanent and visible on
their screen. The shared `retired` line is different: its keys are opaque text both heads keep
without parsing. `verbosity-for-word` still READS letibot's word, so a file either head wrote is
understood here.")

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
        ;; **The seam on the run marker** (R37 amended). ` · ctrl-t opens it` / ` · /verbosity`
        ;; after the counts — the head talking about its own key. The operator wants it gone:
        ;; *"also make showing \" dot /verbosity\" a config and switch it off."* Default NIL, and
        ;; the default is the ruling: a seam that has to be asked for is a seam nobody removes.
        ;;
        ;; It is a PREFERENCE rather than a deletion because the seam is the only thing on that
        ;; line that says the rows can be opened at all — R29's discoverability obligation, which
        ;; every other elided row in this head meets with `· /t unfolds it`. Off by default, and
        ;; the obligation is met by the rung naming itself and by `/t` being in the hint bar.
        :marker-seam nil
        ;; **The rung this head draws at** (R42's sibling, and letibot's `1da8f08`). It was the
        ;; one choice the CARD could change and the file did not keep — so a reader who chose
        ;; `reading` got `normal` back on every restart, which is a setting they have to keep
        ;; re-making. The word is `verbosity-name`'s to spell, so a rename is one edit.
        ;;
        ;; **`normal` is the default, and it is `*verbosity*`'s own initial value** — a head that
        ;; starts at `reading` would hide the working of every session it opens. Measured: with
        ;; `reading` here the whole suite went red in the tests that assert a tool or system row
        ;; is DRAWN, which is the default being wrong rather than any of them.
        :verbosity "normal"
        :path nil)           ; where it came from, so a save goes back there; NIL
                             ; for a head with nowhere to write, which SAYS SO
                             ; rather than writing into the working directory
  "The defaults: split diff, folds closed, raw calls hidden.")

(defun make-prefs ()
  "The defaults, as a fresh plist."
  (copy-list *prefs-defaults*))

;; Field accessors over the plist — the same four names the reference uses, so a
;; reader of either knows the other.
(defun prefs-diff (p)     (getf p :diff))
(defun prefs-thinking (p) (getf p :thinking))
(defun prefs-tools (p)    (getf p :tools))
(defun prefs-raw-calls (p)(getf p :raw-calls))
(defun prefs-marker-seam (p) (getf p :marker-seam))
(defun prefs-verbosity (p) (getf p :verbosity))
(defun prefs-path (p)     (getf p :path))

(defun %prefs-with-every-key (p)
  "P with every key in `*prefs-defaults*` present, a missing one pushed on the FRONT.

**Because `(setf (getf p k) v)` only mutates IN PLACE when K is already there.** On a plist with
no K it conses a fresh list onto the LOCAL variable the accessor was handed, so the caller's
plist is untouched and the write vanishes silently. The four older keys never met this because
every plist in the tree already carried them — `:verbosity` is the first key added SINCE there
were files and running heads in the world, and it broke on exactly the plists that predate it:

  · **a live head pushed onto rather than restarted.** Its `*prefs*` was loaded by a build that
did not know the key, so `head-into-prefs` consed and discarded, `prefs-verbosity` stayed NIL,
    and `save-prefs` wrote `verbosity = \"NIL\"` into the OPERATOR'S OWN `head.toml`. Measured,
    and that file then failed to load on the next start.

**The fix is to make the key exist before anything sets it**, at the two doors a plist enters
through (`load-prefs` already builds on `make-prefs`, so the third door is complete by
construction). A normaliser rather than a cleverer setter: no accessor can add a pair to a plist
the caller still holds, so the honest place to repair it is where the plist is adopted."
  (let ((missing (loop for (k v) on *prefs-defaults* by #'cddr
                       unless (loop for (k2 v2) on p by #'cddr thereis (eq k k2))
                         collect (cons k v))))
    (if missing
        (append (loop for (k . v) in missing append (list k v)) p)
        p)))

(defun (setf prefs-diff) (v p)     (setf (getf p :diff) v))
(defun (setf prefs-thinking) (v p) (setf (getf p :thinking) v))
(defun (setf prefs-tools) (v p)    (setf (getf p :tools) v))
(defun (setf prefs-raw-calls) (v p)(setf (getf p :raw-calls) v))
(defun (setf prefs-marker-seam) (v p) (setf (getf p :marker-seam) v))
(defun (setf prefs-verbosity) (v p) (setf (getf p :verbosity) v))
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
  "Apply a loaded `prefs` to HEAD — the five choices, and nothing else.

Through the setter, so loading a file invalidates the render cache exactly as
flipping a chord does — a head whose `head.toml` says `tools = \"open\"` must draw
the tool output on the first frame, not on the second.

**The retired set is not here any more (R24),** which is why this is shorter than it was.
R19 part 3 applied it from this file's own `retired` key; it comes from the file every head
shares now, by `load-retired-into`, which `load-prefs-into` calls beside this."
  (setf (head-pref head :show-reasoning) (fold-on-p (prefs-thinking p))
        (head-pref head :show-tools) (fold-on-p (prefs-tools p))
        (head-pref head :raw-calls) (prefs-raw-calls p)
        (head-pref head :diff) (prefs-diff p))
  ;; **the run marker's seam is a RENDER input, so it bumps the generation like the folds** —
  ;; and it is its own form because `%set-marker-seam` is a function call and not a place, which
  ;; `(setf place …)` cannot take. Measured: it read as a `(setf %set-marker-seam)` and the head
  ;; said so at the first compile rather than at the first frame.
  (%set-marker-seam (prefs-marker-seam p))
  ;; **The rung, through `set-verbosity` and NOT through the persisting writer.** A load applies
  ;; what the file said; saving it back here would write a file this head may never have read
  ;; (the load's own `unreadable` case), which is the one thing the file discipline forbids.
  (let ((rung (verbosity-for-word (prefs-verbosity p))))
    (when rung (set-verbosity rung)))
  ;; **ADOPTED THROUGH THE NORMALISER, so a later pref change can be SET on it.** A plist
  ;; missing a key cannot take that key's `(setf (getf …))` — see `%prefs-with-every-key`.
  (setf *prefs* (%prefs-with-every-key p))
  head)

(defun load-retired-into (head)
  "The retired set from the SHARED notes file onto HEAD's session. A note, or NIL.

**It goes onto the SESSION because that is where the membership test reads it, and it has
to be in place BEFORE the first snapshot lands**: a warning retired on a previous run must
be replanted retired, not drawn and then hidden a frame later. `run` calls this before it
attaches, and `ingest-snapshot` is only reached through the attach.

**A file that cannot be READ leaves the set empty and SAYS SO.** That is the second value
of `read-retired-keys` and the whole of the rule: the alternative is the defect the shared
file exists to prevent — a head that cannot read it silently starting from nothing and then
saving over a list it never saw. Nothing is written here either way; this only reads."
  (multiple-value-bind (keys readable) (read-retired-keys)
    (if readable
        (progn (setf (session-retired (head-session head)) (copy-list keys)) nil)
        (concatenate 'string
                     "the shared notes file exists and could not be read — nothing is "
                     "retired this run, and it will not be written over"))))

(defun head-into-prefs (head)
  "HEAD's live plist as a `prefs`, for saving.

  **Adopted through `%prefs-with-every-key` first**, so a plist that predates a key still takes
  the setf below — without it the new key silently did not stick and the SAVE wrote `NIL`."
  (let ((p (%prefs-with-every-key (or *prefs* (make-prefs)))))
    (setf (prefs-thinking p) (fold-name (getf (head-prefs head) :show-reasoning))
          (prefs-tools p) (fold-name (getf (head-prefs head) :show-tools))
          (prefs-raw-calls p) (and (getf (head-prefs head) :raw-calls) t)
          (prefs-marker-seam p) (and *marker-seam* t)
          (prefs-diff p) (or (getf (head-prefs head) :diff) "split")
          ;; **the rung, read from the LIVE variable** — the plist and the file disagree for the
          ;; moment between a change and a save, and the plist is what is actually in effect.
          (prefs-verbosity p) (verbosity-name))
    p))

(defun load-prefs-into (head &optional path)
  "Read the file (default `prefs-path`) and apply it to HEAD, then the shared notes file.

Returns the notes the load produced, which are worth SAYING once — a value this
build cannot read is named rather than swallowed — and does not treat a missing
file or a bad line as a reason to refuse to start.

**Two files, and this is the one place both are read at startup.** The four choices are
this head's own (`prefs-path`); the retired set is every head's (`notes-path`), and which is
which is not an implementation detail — it is the difference between a preference and a
shared record. The second file's note comes out of `load-retired-into`."
  (multiple-value-bind (p notes) (load-prefs path)
    (prefs-into-head head p)
    ;; **the operator's own todos are read here too**, and it is the same place for the same
    ;; reason `load-retired-into` is: this is where a head reads everything it carries between
    ;; runs, so a third file cannot be forgotten by whoever adds the fourth. A replay does NOT
    ;; come through here with them — `with-replay-globals` binds `*operator-todos*` to NIL, and a
    ;; recorded screen must not draw the todos of the day it is being replayed on.
    (let ((note (load-retired-into head)))
      (nreverse (if note (push note notes) notes)))))

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
  "Write HEAD's live choices, unless this image is a test. Returns the path, or NIL.

**The normalised plist is ADOPTED back onto `*prefs*`**, so a head that started with an
incomplete plist is whole from its first save on — and a later preference change can then be
`(setf (getf …))`'d into it in place, which is the only way a plist takes a NEW key. See
`%prefs-with-every-key`: without this, every save would normalise a fresh copy and the head
would keep the incomplete one for ever."
  (when *write-prefs*
    (let ((p (head-into-prefs head)))
      (setf *prefs* p)
      (save-prefs p path))))

(defun persist-retired (head)
  "Write the session's retired set to the file every head shares. NIL when it wrote.

**The ONE place a retirement is persisted**, called by the one place one is made
(`%notes`) — for the reason the preference setter gives, that *the fifth site is the one
that would forget*, and here forgetting means a dismissal the operator believes in and
the file does not.

**It is the shared notes file and not this head's `head.toml`**, which is the change R24's
requirement made: letibot's `e7b6caf` measured that a dismissal is ONE FILE FOR EVERY HEAD,
so a wholesale write from either head erases the other's. `save-retired-keys` unions with
what the file holds, writes through a rename, and refuses to write a file it could not
read. See the block above it for the measurement and the two things copied byte for byte.

**REPLACE is the caller's distinction and not this function's**: a dismissal unions (the
default) and a restore replaces. `/notes restore` is the same reader saying those keys are
not retired, which is contrary evidence the union must not swallow — so the caller passes
`:replace` there and this stays a two-line function whose whole job is to hand the keys
over.

**A failure is not fatal and is not silent either.** A read-only file, a full disk, a
missing `$XDG_CONFIG_HOME`, or a file that exists and cannot be read: the retirement stays
live in this process and absent from the file, and the reason comes back as a string the
caller says out loud. The alternative — signalling out of a `/notes` — would make a
cosmetic failure into a lost command."
  (save-retired-keys (session-retired (head-session head)) :replace nil))

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

**Not `~s`, and the difference is a real one found by R19 part 3's round-trip test.**
`~s` escapes a `\"` as `\\\"` and a `\\` as `\\\\`; `%unquote`, which reads the file back,
strips the outer pair and unescapes neither — so a value carrying a quote or a backslash
comes back one backslash away from what went in. Harmless for `diff`, `thinking`, `tools`
and `raw_calls`, whose values come from fixed sets and are written with `~s` on purpose;
wrong for every OTHER value in the file, which is any key a person or a newer build put
there. Measured on the fixture this record keeps for it, `nearly full, and \"quoted\" — see
a|b`: `~s` round-tripped it to `nearly full, and \\\"quoted\\\" — see a|b`, and a membership
test on it missed — silently, which is the failure this whole part exists to stop.

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
                     (cons "marker_seam" (if (prefs-marker-seam p) "true" "false"))
                     ;; **Quoted like letibot spells its own**, so the two heads' files read
                     ;; alike for a key they share a vocabulary for.
                     (cons "verbosity" (format nil "\"~a\"" (prefs-verbosity p))))))
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
