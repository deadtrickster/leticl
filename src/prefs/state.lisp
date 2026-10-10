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

(defparameter *prefs-defaults*
  (list :diff "split"        ; `split` (two panels) or `unified` always — the
                             ; toggle is the whole choice; the width is the
                             ; renderer's business
        :thinking "folded"   ; `open` or `folded`
        :tools "folded"
        :raw-calls nil       ; show the model's `<function=…>` markup under a call
        ;; **A NEW PROJECT'S STARTER TODOS.** `nil` is off; `t` reads the default template file
        ;; (`todo-template-path`); a STRING is a path to another file, which is what makes this one
        ;; key rather than two. See `%seed-operator-todos` — the operator's ask: *"this default todo
        ;; can be a way to help new sessions initialize, can we have a new session todo template with
        ;; a config switch?"*, and it is the deliberate half of a bug they had just found.
        :todo-template nil
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
        ;; **THE GIT FIELD'S FORMAT** — a template of `%b %d %a %s %m %~ %+ %! %?`, one
        ;; placeholder per segment and `%%` for a literal per cent; `+git-format-default+` says
        ;; what each one is. NIL means the built-in default: a preference whose default is a
        ;; COPY of a constant is a second place to keep one value, and the first time they
        ;; disagree nobody can say which is the default.
        :git-format nil
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
(defun prefs-todo-template (p) (getf p :todo-template))
(defun prefs-path (p)     (getf p :path))
(defun prefs-git-format (p) (getf p :git-format))

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
(defun (setf prefs-todo-template) (v p) (setf (getf p :todo-template) v))
(defun (setf prefs-path) (v p)     (setf (getf p :path) v))
(defun (setf prefs-git-format) (v p) (setf (getf p :git-format) v))

