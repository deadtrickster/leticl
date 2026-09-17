;;;; tests/package.lisp

(in-package #:leticl/tests)

(defparameter *tests* nil)
(defparameter *failures* nil)

(defmacro deftest (name &body body)
  `(progn
     (pushnew ',name *tests*)
     (defun ,name ()
       (handler-case (progn ,@body (format t "  ok ~a~%" ',name))
         (error (e)
           (push (cons ',name (format nil "~a" e)) *failures*)
           (format t "  FAIL ~a: ~a~%" ',name e))))))

(defun check= (want got &optional (msg ""))
  (unless (equal want got)
    (error "~a: want ~s got ~s" msg want got)))

(defun run-all ()
  "Run every deftest; print a line per test; return the failure count (0 is
success). The asdf test-op wrapper signals when this is nonzero."
  (setf *failures* nil)
  (let ((count 0))
    (dolist (name (reverse *tests*))
      (incf count)
      (funcall name))
    (format t "~d tests, ~d failures~%" count (length *failures*))
    (length *failures*)))
