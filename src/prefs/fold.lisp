;;;; fold — the fold setter
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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

(defun %flip-fold (head which &optional (value :toggle))
  "Set one fold in the live plist AND persist it.

Saving here rather than at each call site is the point: a fold the operator set
should outlive the process, and the reference's header records exactly the
defect this fixes — the choices *\"used to live in the process and die with it,
and was moved by slash commands nobody remembered\"*.

**VALUE, when given, sets rather than toggles** — `/verbosity thinking=off`
sets `nil` where a chord toggles. The default `:toggle` keeps every existing
caller's behaviour unchanged."
  (let ((now (if (eq value :toggle)
                 (not (head-pref head which))
                 (and value t))))
    (setf (head-pref head which) now)
    (incf *hist-generation*)
    (ignore-errors (save-head-prefs head))
    now))

