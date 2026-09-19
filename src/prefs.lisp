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
  '("diff" "thinking" "tools" "raw_calls")
  "The keys THIS build owns. Anything else in the file is somebody else's — a
newer build's, or the operator's — and is preserved verbatim.")

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
(defun prefs-path (p)     (getf p :path))

(defun (setf prefs-diff) (v p)     (setf (getf p :diff) v))
(defun (setf prefs-thinking) (v p) (setf (getf p :thinking) v))
(defun (setf prefs-tools) (v p)    (setf (getf p :tools) v))
(defun (setf prefs-raw-calls) (v p)(setf (getf p :raw-calls) v))
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
  "Apply a loaded `prefs` to HEAD's live plist."
  (setf (getf (head-prefs head) :show-reasoning) (fold-on-p (prefs-thinking p))
        (getf (head-prefs head) :show-tools) (fold-on-p (prefs-tools p))
        (getf (head-prefs head) :raw-calls) (prefs-raw-calls p)
        (getf (head-prefs head) :diff) (prefs-diff p))
  (setf *prefs* p)
  head)

(defun head-into-prefs (head)
  "HEAD's live plist as a `prefs`, for saving."
  (let ((p (or *prefs* (make-prefs))))
    (setf (prefs-thinking p) (fold-name (getf (head-prefs head) :show-reasoning))
          (prefs-tools p) (fold-name (getf (head-prefs head) :show-tools))
          (prefs-raw-calls p) (and (getf (head-prefs head) :raw-calls) t)
          (prefs-diff p) (or (getf (head-prefs head) :diff) "split"))
    p))

(defun load-prefs-into (head &optional path)
  "Read the file (default `prefs-path`) and apply it to HEAD.

Returns the notes the load produced, which are worth SAYING once — a value this
build cannot read is named rather than swallowed — and does not treat a missing
file or a bad line as a reason to refuse to start."
  (multiple-value-bind (p notes) (load-prefs path)
    (prefs-into-head head p)
    notes))

(defun save-head-prefs (head &optional path)
  "Write HEAD's live choices. Returns the path, or NIL if there is nowhere."
  (save-prefs (head-into-prefs head) path))

(defun %flip-fold (head which)
  "Toggle one fold in the live plist AND persist it.

Saving here rather than at each call site is the point: a fold the operator set
should outlive the process, and the reference's header records exactly the
defect this fixes — the choices *\"used to live in the process and die with it,
and was moved by slash commands nobody remembered\"*."
  (setf (getf (head-prefs head) which) (not (getf (head-prefs head) which))
        (head-dirty head) t)
  (ignore-errors (save-head-prefs head))
  (getf (head-prefs head) which))

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
      (dolist (line (%parse-prefs (uiop:read-file-string path)))
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
              (t (push (format nil "head.toml: `~a` is not a key this head knows"
                               key) notes)))))))
    (values p (nreverse notes))))

(defun save-prefs (p &optional path)
  "Write P, keeping every line that is not one of ours where it was.

A comment, a `[section]`, a key from a newer build — all preserved in place, and
a key of ours that is already in the file is REPLACED rather than appended, so
the file does not grow a second `diff =` on every change. Creates the directory.
Returns the path written, or NIL for a head with nowhere to write."
  (let* ((path (or path (default-prefs-path)))
         (ours (list (cons "diff" (format nil "~s" (prefs-diff p)))
                     (cons "thinking" (format nil "~s" (prefs-thinking p)))
                     (cons "tools" (format nil "~s" (prefs-tools p)))
                     (cons "raw_calls" (if (prefs-raw-calls p) "true" "false")))))
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
