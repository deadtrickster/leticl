;;;; freeze.lisp — build the standalone leticl head image.
;;;;
;;;;   sbcl --script freeze.lisp
;;;;
;;;; Produces bin/leticl-head: a frozen SBCL image with :leticl already loaded,
;;;; so `leticl --continue` starts in milliseconds instead of re-interpreting
;;;; run.lisp and re-loading the system + vendor deps on every launch.
;;;;
;;;; The image's toplevel is leticl/cli:main: it dispatches on the command line
;;;; and, for the head (the default, and --continue/-c/head), calls leticl:run,
;;;; which attaches to the daemon named by $LETIBOT_SOCKET (~/bin/leticl sets
;;;; that from the current directory).
;;;;
;;;; The dev commands (test, demo, smoke, smoke-head) stay in run.lisp; the
;;;; frozen image is the fast head launcher, not a dev REPL.

(require :asdf)
(require :sb-bsd-sockets)
(require :sb-posix)
;; sb-introspect is a CONTRIB, not part of SBCL's core image: without this
;; require, (find-package :sb-introspect) is NIL and the head keeps no record of
;; where a definition came from. `tui-eval --where` reads that record to answer
;; "did my push land" — a pushed function has a null source and an image-baked
;; one carries its .lisp path — and `require` is skipped by `--file`, so a
;; running head cannot gain this by pushing. It has to be here.
(require :sb-introspect)

(defpackage :leticl/cli (:use :cl))
(in-package :leticl/cli)

(defparameter *image-path* nil)

(defun usage (stream)
  (write-line "usage: leticl [--continue|-c]   attach the head to the newest session in this dir" stream)
  (write-line "       leticl --session ID      attach to a specific session" stream)
  (write-line "       leticl -h|help           this message" stream)
  (write-line "" stream)
  (write-line "       the head attaches to the daemon named by $LETIBOT_SOCKET; ~/bin/leticl" stream)
  (write-line "       sets it from the current directory and resolves --continue to the newest" stream)
  (write-line "       session (harnessd --latest-session). Dev commands stay in run.lisp." stream))

(defun main ()
  (let ((args (uiop:command-line-arguments)))
    (when (uiop:getenv "LETICL_DEBUG")
      (format *error-output* "leticl main: args = ~S~%" args))
    (cond
      ((string= (first args) "--session")
       (uiop:symbol-call :leticl '#:run :session-id (or (second args) "")))
      ((or (null args)
           (string= (first args) "--continue")
           (string= (first args) "-c")
           (string= (first args) "head"))
       (uiop:symbol-call :leticl '#:run))
      ((or (string= (first args) "-h")
           (string= (first args) "help"))
       (usage *standard-output*))
      (t
       (format *error-output* "leticl: unknown argument ~A~%~%" (first args))
       (usage *error-output*)
       (uiop:quit 2)))))

(let ((root (uiop:pathname-directory-pathname (or *load-truename* (uiop:getcwd)))))
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
  (asdf:load-system :leticl)
  (let ((bindir (merge-pathnames "bin/" root)))
    (ignore-errors (sb-posix:mkdir (namestring bindir) #o755))
    (setf *image-path* (namestring (merge-pathnames "bin/leticl-head" root)))))

(format t "freezing leticl head image to ~A~%" *image-path*)
(sb-ext:save-lisp-and-die *image-path* :executable t :toplevel #'main)
