;;;; bridge — the bridge to a running head
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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
        (head-pref head :diff) (prefs-diff p)
        ;; **THE GIT FORMAT IS A LIVE PREFERENCE TOO**, and these two lines are the whole bridge:
        ;; the file's template lands here on load and `head-into-prefs` reads it back on save — so
        ;; `/config` and `head.toml` cannot drift into two answers.
        (head-pref head :git-format) (prefs-git-format p))
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
          (prefs-git-format p) (getf (head-prefs head) :git-format)
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
      ;; **NO WORKSPACE YET, and that is deliberate rather than forgotten.** This runs from `run`
      ;; before the socket exists, so the daemon has not said where it is seated; the load that
      ;; matters happens again on the HELLO arm, where the project IS known. Passing nothing here
      ;; loads only the rows that belong to no project, which is the honest answer for a head that
      ;; does not yet know its own.
      (let ((todos (load-operator-todos)))
        (when todos (push todos notes)))
      (nreverse notes))))

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

