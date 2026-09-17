# leticl — plan

The letibot TUI head, rewritten in Common Lisp. The daemon (`harnessd`, Rust)
stays exactly as it is; this is a head that speaks the same wire protocol and
can be modified while it runs — by a person at a REPL, or by a model through a
tool — with every change visible on the next frame.

Companion docs: `TODO.md` (the work items, with dependencies) and later
`HACKING.md` (the live-modification surface, written once it exists).

## 1. Why this is worth doing in CL

A TUI head is a loop: read frames, fold them into state, paint cells. In Rust,
changing how anything looks means a rebuild and a restart, and the restart
detaches the head from a live turn. In Common Lisp the running process *is* the
development environment: `defun`/`defmethod` redefinition takes effect on the
next call, the image keeps its state across changes, and the whole render path
is just functions. So the rewrite is not a port for its own sake — it exists to
make the head a **live image** that a model can restyle, re-layout and extend
through an eval socket, per instance, with no rebuild and no detach.

## 2. Scope

**In**: everything a head does — connect, attach, snapshot, events, render,
keys, composer, cards, picker — plus the live-modification layer.

**Out**: the daemon, the protocol (we speak v18 as-is, no new frames), the
model connection, tools, the ledger. If something is missing on the wire we
note it and live with it; a protocol change is a Rust PR, not ours.

## 3. Repo layout and conventions

- Main checkout: `~/Projects/leticl/leticl` — which is this directory. Topic
  worktrees as siblings, per the operator's letibot convention.
- Commits: lowercase sentence subject, explanatory body, no trailers.
- Network egress: ask first, every time. (Approved once: the vendor clones.)
- `vendor/` is gitignored; `scripts/bootstrap.sh` pins what it clones.
- The shell adjudicator on this box refuses `$var`/`$(...)` in interactive
  command lines; scripts may use them, typed command lines may not.

## 4. Environment facts (measured, not assumed)

- SBCL 2.6.0, ASDF contrib present (`(require :asdf)` works).
- `sb-bsd-sockets` for unix sockets, `sb-alien` for termios/ioctl — no CFFI,
  no compiler needed (there is no gcc/curl on the box).
- Locales: `C.utf8`, `en_US.utf8` exist, but the session runs `POSIX`. We do
  **not** depend on libc locale at all: width comes from our own table.
- Two live daemons run under `/run/user/1000/letibot/` with `<hash>.json`
  (`workspace`, `socket`, `pid`, `role`, `model`, `dialect`, …) and matching
  `.sock` files. Real test targets from day one. Agent contexts on this box
  run **without** `XDG_RUNTIME_DIR` but **with** `LETIBOT_SOCKET` naming the
  daemon of their own folder — discovery uses both (`src/socket.lisp`).
- The Rust TUI's terminal setup is `\e[?1049h\e[?25l\e[?2004h\e[?1002h\e[?1006h\e[2 q`
  and teardown `\e[?2026l\e[?1006l\e[?1002l\e[?2004l\e[0 q\e[?25h\e[?1049l`
  (`crates/tui/src/term.rs:188,461`). We mirror these byte-for-byte: alt
  screen, cursor hide, bracketed paste, mouse motion+SGR, synchronized output.

## 5. The seam: protocol 18 in one page

Source of truth: `../letibot/letibot/crates/sessionlog/src/protocol.rs`
(`PROTOCOL_VERSION = 18`). Framing (`wire.rs`): newline-delimited JSON over any
stream, blank lines skipped, flush per frame, EOF = detach (not an error).

Both directions tag with `"frame"`; events tag with `"event"`; all names
`snake_case`.

**Client frames (24)**: `attach ack resync prompt interrupt promote
compact_session reseat_session mode slash askpass secret screen answer
answer_question list_sessions list_todos new_session resume_session
rename_session switch peek settings detach`.

**Server frames (11)**: `hello secret sessions todos settings peeked event
resync accepted rejected bye`.

**Session events (27)**: `turn_started prompt_progress delta tool_call_proposed
decision_requested decision_answered tool_started tool_progress tool_finished
turn_finished turn_interrupted turn_failed transcript_appended
transcript_content head_attached head_detached warning screen_requested
secret_requested secret_settled explain command_issued session_renamed
todos_updated denial_raised subagent job_settled`.

**The rules the frame shapes enforce** (each one is a bug that already happened
in Rust; we inherit the shape, not the bug):

1. `Ack{seq, rendered, filtered}` — `seq` is the last seq **consumed from the
   batch**, rendered or not; there is no other way to obtain one. Ack is sent
   **after** painting, never on receipt.
2. `Hello.dropped` is present and zero, never omitted. An absent field and an
   empty field must not be the same bytes (the Rust module enforces this with a
   test that greps its own source).
3. Every mutating command carries `client_request_id` + `expected_seq`; a stale
   one is `Rejected` with **both** numbers. Resync is a normal outcome, never
   an error.
4. `Attach{protocol_version, session_id, since_seq, kind, identity, caps}`;
   `since_seq = 0` takes a snapshot, anything else resumes. `caps` is
   `{queue: usize = 1024, can_decide: bool = true, features: [String]}`.
5. A head must answer `ScreenRequested` with `Screen{req_id, cols, rows_n,
   rows[]}` — its own last rendered rows, ANSI included, at its real size. We
   keep the last painted frame for exactly this.
6. **The first frame on a connection must be ATTACH** — anything else is
   answered with `Bye{"the first frame must be ATTACH"}` (`server.rs:205`),
   even `ListSessions`. An empty `session_id` means *"whatever this daemon
   calls current"* (`registry.rs:600`), which is how a head attaches before it
   knows any ids; the `Hello` carries the full session list, so no second
   round trip is needed.

## 6. Architecture (bottom-up)

| layer | file(s) | is |
|---|---|---|
| term | `src/term.lisp` | raw mode (sb-alien termios), alt screen enter/exit, winsize ioctl, UTF-8 fd-streams |
| width | `src/width.lisp` | per-char display width, ported from `crates/ui/src/width.rs` (cluster-aware version later) |
| cells | `src/cells.lisp` | cell buffer (char + interned style), SGR builder, diff painter, full painter |
| json | `src/json.lisp` | yason wrappers; the key convention lives here |
| wire | `src/wire.lisp` | NDJSON read/write, `wire-error` carrying the offending line |
| protocol | `src/protocol.lisp` | v18 constants, frame constructors, encode/decode |
| socket | `src/socket.lisp` | unix connect, daemon discovery from `$XDG_RUNTIME_DIR/letibot/*.json` |
| session | `src/session.lisp` | attach/hello/snapshot ingestion, event application, ack bookkeeping, resync |
| head | `src/head.lisp` | threads + mailboxes, paint-on-dirty loop, resize poll |
| render | `src/render.lisp` | transcript items → cells, chrome, fit loop |
| keys | `src/keys.lisp` | escape-sequence decoding (port of term.rs tables), composer editing |
| hack | `src/hack.lisp` | the eval socket; `scripts/tui-eval` is its CLI |

**One package** (`:leticl`, nickname `:lt`), on purpose: a model hacking a live
instance reaches everything without package imports. The package *is* the
public API; `HACKING.md` will name the functions that are contract vs
incidental.

## 7. Conventions on the JSON boundary

- Wire objects decode to **plists with keyword keys**: `"session_id"` →
  `:session-id`. Encoding is the inverse. This lives in `json.lisp` and
  nowhere else.
- Frames stay plists at the boundary (v1). Typed CLOS views may be added for
  hot paths (deltas) later; the boundary stays plists so a model can always
  inspect the raw frame.
- Encoder law: **every key present in the plist is emitted**; `nil` → `null`;
  `t` → `true`; a keyword *value* encodes as its snake_case string (enum
  vocabulary like `:in_progress` → `"in_progress"`); a plist → object; any
  other list → array. Empty arrays are not representable (NIL is null), so
  constructors **omit serde-default fields at their default** instead of
  writing `[]` — the daemon's `serde(default)` makes the outcomes identical.
  Fields whose *presence* is the disclosure (`dropped`, `created`) are always
  included explicitly.
- A plist is recognized by "cons whose car is a keyword and whose length is
  even"; we never send arrays of keywords, so the ambiguity is closed by
  convention and stated here.

## 8. The live-hack layer (the point)

- Each TUI instance listens on `$XDG_RUNTIME_DIR/leticl/tui-<pid>.sock`
  (fallback `/tmp/leticl-<uid>/`), mode 0600. Separate namespace from the
  daemons' `letibot/` so discovery of either stays unambiguous.
- Line protocol, one request per line: `eval <form>` — the rest of the line is
  one s-expression. Response: one JSON line `{"ok":true,"value":"…","ms":3}`
  or `{"ok":false,"error":"…"}`.
- After each eval the head marks itself dirty; the main loop repaints on the
  next tick. **Visible immediately** is a property of the loop, not a hope.
- `scripts/tui-eval` is the CLI the model calls through its exec tool:
  `tui-eval '(setf (getf lt::*prefs* :accent) "cyan")'`, with `--pid` to pick
  an instance and `--list` to enumerate them.
- Trust level: the socket is arbitrary code execution in the head's image, by
  design — the same trust a person at a REPL has, and the same trust the
  daemon's exec tool already grants. It is per-user, mode 0600, and documented
  loudly rather than hidden.

## 9. Concurrency

- Reader thread: blocking read on the socket, decode, push into a mailbox
  (`sb-concurrency`; if the contrib is missing, a hand-rolled condition-variable
  mailbox — decided at T12).
- Input thread: blocking read on stdin, decode keys, push into a second
  mailbox.
- Main thread: drain both, fold into state, paint when dirty. Resize by
  polling winsize each tick (one cheap ioctl); SIGWINCH later if polling shows
  latency.
- `save-lisp-and-die` cannot run with live threads — if we ever ship a saved
  core, it is taken at startup before threads spawn (M6 note, not earlier).

## 10. Milestones

- **M1 — foundation**: repo, vendored yason, term/width/cells/json/wire/
  protocol/socket, tests green, `run.lisp demo` paints a real frame. (T1–T10)
- **M2 — attach**: session state + head loop; attach to a live daemon, render
  the snapshot as plain lines, ack correctly, survive resync. (T11–T13)
- **M3 — real TUI**: transcript rendering with styles, chrome, composer, keys,
  prompt/interrupt, decision cards, picker. (T14–T17)
- **M4 — the point**: eval socket + `tui-eval` + repaint-on-eval +
  `HACKING.md`; the demo is a model restyling the live TUI. (T18)
- **M5 — parity**: markdown, diffs, highlight, prefs/settings/peek/subagents/
  todos. (T19–T21)
- **M6 — hardening**: resync/reconnect drills, `Screen` answers, long-session
  memory behavior. (T22)

## 11. Testing

- `leticl/test` system, zero-dep harness in `tests/` (the Rust repo keeps its
  TUI tests in-file and asserts on rendered screens; we keep ours in `tests/`
  and assert on cell buffers and emitted escape strings).
- Protocol goldens: exact JSON strings for every frame we send, and
  serde-shaped JSON for everything we decode. Goldens are written by hand from
  the serde semantics (field order is irrelevant to us; presence is not).
- Live smoke (`scripts/smoke-attach.lisp`): attach to the real daemon,
  `ListSessions`, print, detach. Read-only; never talks to the model server.

## 12. Risks and open questions

- Does `server.rs` validate the `kind` string? We send `"tui"` (known-good)
  until checked.
- `Snapshot`/`view.rs` shape is read at T11, not guessed now.
- yason's exact nil/t encoding is irrelevant — `json.lisp` writes
  `true`/`false`/`null` literals itself and uses yason only for string escaping
  and numbers.
- Wide-char-at-last-column and other painter edges are handled where they are
  cheapest: `screen-put-string` degrades a non-fitting wide char to a space,
  and the painter re-guards.
- The fit loop's drop order (completions, hint, notice, composer height, stuck
  line, box, card) is ported deliberately at T14, not invented.

## 13. Decisions so far

- **D1** (2026-09-17): daemon untouched; head-only rewrite; protocol 18 as-is.
- **D2**: SBCL builtins + vendored yason only; no quicklisp, no CFFI.
- **D3**: single package `:leticl` for live-hack ergonomics.
- **D4**: frames as keyword plists at the boundary; typed views only if a hot
  path demands them.
- **D5**: own width table ported from `ui/width.rs`; no libc locale dependency.
- **D6**: hack layer = per-instance unix socket + line eval protocol +
  `tui-eval` CLI; no daemon changes.
- **D7**: repo at `~/Projects/leticl/leticl`; `vendor/` gitignored, pinned by
  `scripts/bootstrap.sh`.
- **D8** (2026-09-17): tool paths are relative to the repo root (the session
  root *is* the main checkout). A `leticl/` prefix in a tool path is always
  wrong here — paid for once with an `rm -rf` that ate the first PLAN.md.
