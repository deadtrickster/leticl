# leticl — TODO

Derived from `PLAN.md`. Status: `[ ]` open, `[~]` in progress, `[x]` done.
Dependencies are explicit; **do not start an item before its deps are done**.
This file is mirrored into the harness todo list; update both together.

## Dependency graph

```
T1 ─┬─ T3 ─┬─ T4 ──────┐
    │      ├─ T5 ──────┼─ T6 ────┐
    │      ├─ T7       │         │
    │      └─ T10      │         │
T2 ─┴─ T8 ─────────────┴─ T9 ─ T11 ─ T12 ─┬─ T13 ─ T14 ─┬─ T18 ── T22
                                          │             ├─ T19
                                          └─ T15 ─┬─ T16│
                                                  └─ T17 ┴─ T20, T21
```

Reading: T6 needs T4+T5; T9 needs T8; T11 needs T9; T12 needs T6+T11; T13
needs T10+T12; T14 needs T13; T15 needs T12; T16/T17 need T15; T18 needs T14;
T20/T21 need T14/T17; T22 needs T18.

## Phase 0 — repo

- [x] **T1** git init, `.gitignore`, commit PLAN.md + TODO.md.
- [x] **T2** vendor yason + alexandria + trivial-gray-streams, pinned in
  `scripts/bootstrap.sh` (yason `0c84b29`, t-g-s `257d73e`, alexandria
  `f283e25`).

## Phase 1 — foundation (M1)

- [x] **T3** `leticl.asd` (+ `/test` system), `src/package.lisp` (one package
  `:leticl`), `run.lisp` entry (`test` / `demo`), source-registry setup for
  `vendor/`. Deps: T1.
- [x] **T4** `src/term.lisp`: termios via sb-alien (tcgetattr/tcsetattr/
  cfmakeraw, TCSADRAIN), `with-raw-mode`, winsize ioctl (`terminal-size`),
  UTF-8 fd-streams, enter/exit sequences mirrored from `term.rs:188,461`
  byte-for-byte, synchronized-output helpers. Deps: T3.
- [x] **T5** `src/width.lisp`: `char-width`/`string-width`, compact port of the
  `ui/width.rs` ranges (CJK, Hangul, fullwidth, common emoji, combining,
  variation selectors, ZWJ). Full cluster-aware port (ZWJ sequences, regional
  pairs, escape-aware walking) stays open until T19/T20 need it. Deps: T3.
- [x] **T6** `src/cells.lisp`: cell buffer (char + interned style plist),
  `style-index` + cached SGR builder, `screen-put-string` (wide-char
  continuation cells, non-fitting wide char degrades to space),
  `paint-diff` (run-based, absolute moves, style tracked across the frame,
  `?2026` wrapper), `paint-full`. Deps: T4, T5.
- [x] **T7** `src/wire.lisp`: `read-frame` (skip blanks, `:eof` on close),
  `write-frame` (flush per frame), `wire-error` carrying the offending line.
  Deps: T3.
- [x] **T8** `src/json.lisp`: yason wrappers — decode to keyword-key plists,
  encode per PLAN §7 (never elide, nil→null, keyword value→snake string,
  plist→object, list→array). Deps: T2, T3.
- [x] **T9** `src/protocol.lisp`: `+protocol-version+` 18, constructors for the
  client frames we send (attach/ack/resync/prompt/interrupt/answer/
  answer_question/list_sessions/list_todos/new_session/rename_session/switch/
  peek/settings/detach first; the rest as needed), decode passthrough,
  request-id generator, reject-code constants, golden tests. Deps: T8.
- [x] **T10** `src/socket.lisp`: `connect-unix`, `discover-daemons` (parse
  `$XDG_RUNTIME_DIR/letibot/*.json`). Deps: T3.

## Phase 2 — attach (M2)

- [ ] **T11** `src/session.lisp`: attach/hello handling, snapshot ingestion
  (read `view.rs` first — do not guess the shape), event application into a
  transcript model, ack bookkeeping per PLAN §5.1, resync handling. Deps: T9.
- [ ] **T12** `src/head.lisp`: reader thread + mailbox, input thread + mailbox,
  main loop (drain, fold, paint-on-dirty), resize poll, ack-after-paint.
  Deps: T6, T11.
- [ ] **T13** live smoke: attach to a real daemon, render the snapshot as plain
  lines, acks accepted, resync survives. Verified against the running daemons
  under `/run/user/1000/letibot/`. Deps: T10, T12.

## Phase 3 — real TUI (M3)

- [ ] **T14** `src/render.lisp`: transcript items → styled cells, chrome
  (status line, wiring disclosure), fit loop with the ported drop order.
  Deps: T13.
- [ ] **T15** `src/keys.lisp` + composer: escape decoding (port term.rs tables,
  bracketed paste, mouse SGR), line editing, prompt/interrupt send. Deps: T12.
- [ ] **T16** decision/question cards: `DecisionRequested`/question rendering,
  `Answer`/`AnswerQuestion` frames, one-list-at-a-time rule, card steps aside
  while a decision is up. Deps: T15.
- [ ] **T17** session picker: `Sessions`/`ListSessions`, `Switch`,
  `NewSession`/`ResumeSession`/`RenameSession`, click facts recorded by the
  frame. Deps: T15.

## Phase 4 — the point (M4)

- [ ] **T18** `src/hack.lisp` + `scripts/tui-eval`: per-instance eval socket
  (PLAN §8), repaint-on-eval, `--list`/`--pid`, `HACKING.md` naming the
  contract surface. Demo: a model restyles the live TUI. Deps: T14.

## Phase 5 — parity (M5)

- [ ] **T19** markdown rendering (port `tui/markdown.rs`). Deps: T14.
- [ ] **T20** diff/sidediff/highlight (port `ui/diff.rs`, `ui/sidediff.rs`,
  `ui/highlight.rs`). Deps: T14.
- [ ] **T21** prefs/settings/peek/subagent rows/todos screens. Deps: T17.

## Phase 6 — hardening (M6)

- [ ] **T22** resync/reconnect drills, `Screen` frame answers (last painted
  frame retained), long-session memory behavior, saved-core note. Deps: T18.
