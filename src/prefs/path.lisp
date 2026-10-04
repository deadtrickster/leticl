;;;; path — the path
;;;;
;;;; Split out of `prefs.lisp`, which was one 1014-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

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

