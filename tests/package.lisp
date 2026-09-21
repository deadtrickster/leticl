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
  "Run the suite; return the failure count for run.lisp's exit code.

**A suite run does not write the operator's files.** Bound HERE rather than in each
test, because it is a property of running tests and not of any one of them — and it
was not: measured with `XDG_CONFIG_HOME` pointed at an empty directory, `sbcl --script
run.lisp test` CREATES `…/leticl/head.toml` and writes whatever fold the last chord
test left in the head. On this box that meant every suite run rewrote the choice the
operator had made with `ctrl-t` or `/config`, and the next head they started read it
back. A test that changes the answer to the question it is asking is the same class of
defect as a global that survives between tests, except that this one outlives the
process.

A test that needs to see a write rebinds `leticl:*write-prefs*` to T for itself."
  (let ((leticl:*write-prefs* nil))
    (if (run! 'leticl) 0 1)))
