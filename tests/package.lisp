;;;; tests/package.lisp — the suite, on FiveAM. The hand-rolled runner this
;;;; replaces had one trick (count failures); FiveAM adds per-assertion
;;;; continuation, selective re-runs, and for-all properties.

(defpackage #:leticl/tests
  (:documentation "FiveAM suite for the leticl head.")
  (:use #:cl #:leticl)
  ;; curated, not :use — fiveam also exports `run', which must stay leticl:run
  (:import-from #:it.bese.fiveam
                #:def-suite #:in-suite #:def-test #:is
                ;; `skip` was USED by highlight-rust-roles and never imported, so
                ;; the one test that guards the no-shim contract died with
                ;; "The function LETICL/TESTS::SKIP is undefined" the moment the
                ;; .so was absent — which is the only time it runs.
                #:skip
                #:signals #:finishes #:for-all
                #:gen-integer #:gen-string #:gen-list #:gen-one-element
                #:run!)
  (:export #:leticl #:run-all))

(in-package #:leticl/tests)

(def-suite leticl
    :description "Cell buffers, escape strings, protocol goldens, wire
framing — everything that can be tested without a live daemon.")

(in-suite leticl)

(defun run-all ()
  "Run the suite; return the failure count for run.lisp's exit code."
  (if (run! 'leticl) 0 1))
