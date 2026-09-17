;;;; leticl.asd — the letibot head, rewritten in Common Lisp.
;;;; See PLAN.md for the architecture; TODO.md for what exists so far.

(asdf:defsystem #:leticl
  :description "Common Lisp head (TUI) for the letibot harness daemon"
  :long-description "Speaks protocol 18 (NDJSON over a unix socket) to an
untouched Rust harnessd, renders with its own cell buffer and ANSI diff
painter, and is a live image: a model can redefine its render path at runtime
through an eval socket and see the change on the next frame."
  :author "dead"
  :license "Apache-2.0"
  :depends-on (#:alexandria
               #:trivial-gray-streams
               #:yason)
  :serial t
  :components ((:file "src/package")
               (:file "src/term")
               (:file "src/width")
               (:file "src/cells")
               (:file "src/json")
               (:file "src/wire")
               (:file "src/protocol")
               (:file "src/socket")
               (:file "src/demo")))

(asdf:defsystem #:leticl/test
  :description "Tests for leticl — zero-dep harness, asserts on cell buffers
and emitted escape strings (see PLAN.md §11)."
  :depends-on (#:leticl)
  :serial t
  :components ((:file "tests/package")
               (:file "tests/tests"))
  :perform (asdf:test-op (o c)
             (declare (ignore o c))
             (uiop:symbol-call :leticl/tests '#:run-all)))
