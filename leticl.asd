;;;; leticl.asd — the letibot head, rewritten in Common Lisp.
;;;; See PLAN.md for the architecture; TODO.md for what exists so far.

(asdf:defsystem #:leticl
  :description "Common Lisp head (TUI) for the letibot harness daemon"
  :long-description "Speaks protocol 27 (NDJSON over a unix socket) to an
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
               ;; **THE LINK LAYER, BEFORE THE CELLS.** `paint-diff` consults it while it walks the
               ;; grid, so loading it first is what keeps that call a call rather than a forward
               ;; reference — and the module has nothing to say about cells anyway: it is a table
               ;; of head-authored URLs and a per-frame map of integer spans.
               (:file "src/links")
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
               (:file "src/cards/protocol")
               ;; **THE CARDS, ONE FILE PER CARD** — plus the machinery they share. This was one
               ;; 4,800-line `cards.lisp`, then a layer-named split; a reader looking for the
               ;; edit card should find `edit-card.lisp`. The order is dependency order, not the
               ;; old file's: the base class and generics, the shared vocabulary (`targets` what
               ;; a call names, `roles` the words and row budgets, `decisions` what an approval
               ;; is said as, `payload` the window into a long result, `hidden-run` R37, `memo`
               ;; the render memo), then the cards that are SHAPES (`edit-card` the diff,
               ;; `write-card` the paths a write opens), then one file per row kind, then
               ;; `tool-result-card` (the settled tool row and the tool families),
               ;; `live-call-card` (the running one), `item-lines` (the door and the factories,
               ;; which name every class above) and `turn`.
               (:file "src/cards/targets")
               (:file "src/cards/roles")
               (:file "src/cards/decisions")
               (:file "src/cards/payload")
               (:file "src/cards/hidden-run")
               (:file "src/cards/memo")
               (:file "src/cards/edit-card")
               (:file "src/cards/write-card")
               (:file "src/cards/live-call-card")
               (:file "src/cards/notice-card")
               (:file "src/cards/user-card")
               (:file "src/cards/assistant-card")
               (:file "src/cards/reasoning-card")
               (:file "src/cards/note-card")
               (:file "src/cards/static-cards")
               (:file "src/cards/tool-result-card")
               (:file "src/cards/item-lines")
               (:file "src/cards/turn")
               (:file "src/chrome")
               ;; **THE DASHBOARD VOCABULARY** (serenedash's philosophy, composed at runtime):
               ;; values, series, panels and the keys. After `chrome` because it reads the
               ;; loop's clock (`*now-ms*`) — a series stamped with a monotonic reading would
               ;; not survive the comparison that makes `stale` mean anything — and before the
               ;; panes, which are the only thing that draws it.
               (:file "src/dash")
               ;; **THE FILES A DASHBOARD CAN BE** (R56): the panel vocabulary above rendered
               ;; from data on disk, so an agent in another project can write one without
               ;; editing this head's source at all. After `dash`, whose vocabulary it only
               ;; calls — it is a READER of that API and adds no drawing of its own.
               (:file "src/dashfiles")
               ;; **AND WHAT PRODUCES THE NUMBERS, AND WHERE THEY GO** (R56): watchers — a command, a
               ;; file or a job's own output — and SINKS, a command the collector runs with the
               ;; reading on stdin. After `dashfiles`, whose directory convention and refusal rules
               ;; it reuses rather than restates. One file for both because a sink is a source
               ;; pointed the other way: same timeout, same failure discipline, same visibility.
               (:file "src/dashwatch")
               ;; **EVERY FULL-BODY SCREEN, ONE FILE PER PANE.** This was one 3,578-line
               ;; `panes.lisp`; the ranges are consecutive, so every reference kept its
               ;; direction and the split moved no behaviour.
               (:file "src/panes/helpers")
               (:file "src/panes/session-picker")
               (:file "src/panes/help")
               (:file "src/panes/status")
               (:file "src/panes/config")
               (:file "src/panes/jobs")
               (:file "src/panes/subagents")
               (:file "src/panes/todos")
               (:file "src/panes/repo-todo")
               (:file "src/panes/peek")
               (:file "src/panes/slash")
               (:file "src/panes/notes")
               (:file "src/panes/job-out")
               (:file "src/panes/pick")
               (:file "src/panes/empty")
               (:file "src/panes/permission")
               (:file "src/panes/overlays")
               (:file "src/panes/cursor")
                ;; **THE PANE PROTOCOL** — one class per full-body screen. After `panes`,
                ;; whose functions its methods delegate to, and BEFORE `render`/`editor`/
                ;; `chrome`, which were the files dispatching on the mode keyword by hand.
                (:file "src/pane-protocol")
               ;; `render` is the frame engine: it composes the screen out of
               ;; the cards, chrome and panes above, and owns the segment and
               ;; viewport machinery. Three files now: `wrapping` how a row is wrapped
               ;; to the columns it has, `rendering` the frame itself, `history-cache`
               ;; the line cache and the paint lock.
               (:file "src/render/wrapping")
               (:file "src/render/rendering")
               (:file "src/render/history-cache")
               (:file "src/editor")
               (:file "src/hack")
               ;; **THE EVAL SURFACE ON THE GLASS** (the `/lisp` pane): after `hack`, whose
               ;; `hack-eval-form` it shares so the socket and the pane cannot drift about what an
               ;; eval IS, and after `render`/`panes`, whose pane machinery it draws with. That
               ;; puts the pane's dispatch in `render.lisp` one file EARLIER than this definition —
               ;; `lisp-pane-lines` is called forward, a runtime call that warns rather than fails,
               ;; which is the shape `make-composer` and `%handle-key` already have there.
               (:file "src/repl")
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
