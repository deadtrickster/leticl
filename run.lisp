;;;; run.lisp — the entry: sbcl --script run.lisp [test|demo]
;;;; Sets up the source registry for vendor/, loads the system, dispatches.

(require :asdf)
(require :sb-bsd-sockets)
(require :sb-posix)

(let* ((here (or *load-truename* (uiop:getcwd)))
       (root (uiop:pathname-directory-pathname here)))
  (asdf:initialize-source-registry
   `(:source-registry
     (:directory ,root)
     (:directory ,(merge-pathnames "vendor/alexandria/" root))
     (:directory ,(merge-pathnames "vendor/trivial-gray-streams/" root))
     (:directory ,(merge-pathnames "vendor/yason/" root))
     :inherit-configuration))
  (asdf:load-system :leticl)
  (let ((cmd (or (first (uiop:command-line-arguments)) "test")))
    (cond
      ((string= cmd "test")
       (asdf:load-system :leticl/test)
       (let ((failures (uiop:symbol-call :leticl/tests '#:run-all)))
         (uiop:quit (if (plusp failures) 1 0))))
      ((string= cmd "demo")
       (uiop:symbol-call :leticl '#:demo))
      ((string= cmd "smoke")
       (load (merge-pathnames "scripts/smoke-list.lisp" root)))
      (t
       (format t "usage: sbcl --script run.lisp [test|demo|smoke]~%")
       (uiop:quit 2)))))
