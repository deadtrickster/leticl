;;;; leticl.asd — the letibot head, rewritten in Common Lisp.
;;;; See PLAN.md for the architecture; TODO.md for what exists so far.

(asdf:defsystem #:leticl
  :description "Common Lisp head (TUI) for the letibot harness daemon"
  :long-description "Speaks protocol 26 (NDJSON over a unix socket) to an
untouched Rust harnessd, renders with its own cell buffer and ANSI diff
painter, and is a live image: a model can redefine its render path at runtime
through an eval socket and see the change on the next frame."
  :author "dead"
  :license "Apache-2.0"
  :depends-on (#:alexandria
               #:anaphora
               #:trivial-gray-streams
               #:yason)
  :serial t
  :components ((:file "src/package")
               (:file "src/prefs")
               (:file "src/term")
               (:file "src/width")
               (:file "src/progress")
               (:file "src/cells")
               (:file "src/json")
               (:file "src/wire")
               (:file "src/protocol")
               ;; the head's own sqlite store (R46): the operator's ruling is that local
               ;; data lives in sqlite, and `store` is the only file that touches the C library
               (:file "src/store")
               (:file "src/socket")
               (:file "src/session")
               ;; The ENGINES come before the things that call them: markdown
               ;; styles a fence with `highlight-lines`, and a card diffs an edit
               ;; with `render-diff`. Order here is compile order, so a caller
               ;; before its callee is a style-warning per call site.
               (:file "src/highlight")
               (:file "src/diff")
               ;; the two-panel view; it diffs the excerpts with the engine above
               (:file "src/sidediff")
               (:file "src/markdown")
               (:file "src/keys")
               ;; `head` defines the head STRUCT and the loop. It comes before
               ;; everything that reaches through it, so accessors resolve at
               ;; compile time; the few functions it calls forward
               ;; (%render-and-paint, %handle-key, make-composer) are runtime
               ;; calls and warn rather than fail.
               (:file "src/head")
               (:file "src/commands")
               (:file "src/cards")
               (:file "src/chrome")
               ;; **THE DASHBOARD VOCABULARY** (serenedash's philosophy, composed at runtime):
               ;; values, series, panels and the keys. After `chrome` because it reads the
               ;; loop's clock (`*now-ms*`) — a series stamped with a monotonic reading would
               ;; not survive the comparison that makes `stale` mean anything — and before the
               ;; panes, which are the only thing that draws it.
               (:file "src/dash")
               (:file "src/panes")
               ;; `render` is the frame engine: it composes the screen out of
               ;; the cards, chrome and panes above, and owns the segment and
               ;; viewport machinery.
               (:file "src/render")
               (:file "src/editor")
               (:file "src/hack")
               (:file "src/demo")
               ;; LAST, and it has to be: `replay` rebinds every global a frame
               ;; reads so two replays in one image cannot see each other's
               ;; state, and a `let` over a symbol that is not yet special is a
               ;; lexical binding that silently resets nothing.
               (:file "src/replay")))

(asdf:defsystem #:leticl/test
  :description "Tests for leticl — FiveAM suite: cell buffers, escape strings,
protocol goldens, wire framing (see PLAN.md §11)."
  :depends-on (#:leticl #:fiveam)
  :serial t
  :components ((:file "tests/package")
               (:file "tests/tests")
               ;; the net under `scripts/compare-1-1`: a fixture in, a screen out
               (:file "tests/replay"))
  :perform (asdf:test-op (o c)
             (declare (ignore o c))
             (uiop:symbol-call :leticl/tests '#:run-all)))
