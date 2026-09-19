;;;; test-highlight.lisp — exercise the rano shim end-to-end (dev check, not the
;;;; FiveAM suite). Run: sbcl --script scripts/test-highlight.lisp

(require :asdf)
(require :sb-bsd-sockets)
(require :sb-posix)
(let ((root (uiop:getcwd)))   ; run from the repo root
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
  (asdf:load-system :leticl))

(in-package #:leticl)

(format t "shim available: ~a~%" (hl-available-p))
(format t "lang-for a.rs:    ~a (want 1=Rust)~%" (lang-for "a.rs"))
(format t "lang-for x.lisp:  ~a (want 7=CommonLisp)~%" (lang-for "x.lisp"))
(format t "lang-for noext:   ~a (want 0=none)~%" (lang-for "noext"))

(let* ((src (format nil "fn main() {~%    let x = 42; // answer~%    println!(\"{x}\");~%}~%"))
       (lang (lang-for "a.rs"))
       (grid (class-grid src lang)))
  (format t "grid: ~a~%" (if grid (format nil "~a entries (src has ~a chars)" (length grid) (length src)) "NIL"))
  (when grid
    (format t "roles: ~a~%" (coerce grid 'list))
    (dolist (line (highlight-lines src lang))
      (format t "  | ~a~%" (mapcar (lambda (s) (format nil "~a=~a" (car s) (cdr s))) line)))))
