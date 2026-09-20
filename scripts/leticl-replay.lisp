;;;; leticl-replay.lisp — `--replay` without a frozen image.
;;;;
;;;;   sbcl --script scripts/leticl-replay.lisp FILE.jsonl [--no-tty] [--cols N] [--rows N]
;;;;
;;;; Same entry point as `bin/leticl-head --replay` (freeze.lisp's `%main`), for
;;;; the two cases where there is no image: CI, and a worktree that has not been
;;;; frozen yet. It costs the system load — about ten seconds against a fraction
;;;; of one — so `scripts/compare-1-1` prefers the image and falls back here.
;;;;
;;;; **The load is silenced onto stderr.** ASDF narrates compilation on
;;;; `*standard-output*`, and `--no-tty` writes the frame to fd 1: without the
;;;; rebinding below the first rows of the comparison are `; compiling
;;;; (DEFUN ...)` and every fixture differs for a reason that has nothing to do
;;;; with rendering. `replay-print` writes to its own fd-1 stream, so it is not
;;;; affected by the rebinding — which is why this works at all.

(require :asdf)
(require :sb-bsd-sockets)
(require :sb-posix)
(require :sb-concurrency)

(let* ((here (or *load-truename* (uiop:getcwd)))
       (root (uiop:pathname-directory-pathname
              (merge-pathnames "../" (uiop:pathname-directory-pathname here)))))
  (asdf:initialize-source-registry
   `(:source-registry
     (:directory ,root)
     (:directory ,(merge-pathnames "vendor/alexandria/" root))
     (:directory ,(merge-pathnames "vendor/trivial-gray-streams/" root))
     (:directory ,(merge-pathnames "vendor/yason/" root))
     (:directory ,(merge-pathnames "vendor/anaphora/" root))
     (:directory ,(merge-pathnames "vendor/fiveam/" root))
     (:directory ,(merge-pathnames "vendor/asdf-flv/" root))
     (:directory ,(merge-pathnames "vendor/trivial-backtrace/" root))
     :inherit-configuration))
  (let ((*standard-output* *error-output*))
    (handler-bind ((warning #'muffle-warning))
      (asdf:load-system :leticl)))

  (let ((path nil) (no-tty nil) (cols 100) (rows 40)
        (args (uiop:command-line-arguments)))
    (loop while args
          for arg = (pop args)
          do (cond ((string= arg "--replay") (setf path (pop args)))
                   ((string= arg "--no-tty") (setf no-tty t))
                   ((string= arg "--cols")
                    (setf cols (or (parse-integer (or (pop args) "") :junk-allowed t) cols)))
                   ((string= arg "--rows")
                    (setf rows (or (parse-integer (or (pop args) "") :junk-allowed t) rows)))
                   ((null path) (setf path arg))))
    (unless (and path (probe-file path))
      (format *error-output* "usage: leticl-replay.lisp FILE.jsonl [--no-tty] [--cols N] [--rows N]~%")
      (uiop:quit 2))
    (uiop:symbol-call :leticl '#:replay path :no-tty no-tty :cols cols :rows rows)
    (uiop:quit 0)))
