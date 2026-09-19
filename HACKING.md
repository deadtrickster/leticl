# HACKING — the live-modification surface

A leticl head is a **live image**: the running process is the development
environment. You can redefine how it renders, restyle it, and inspect its
state while it is attached to a live turn — no rebuild, no restart, no detach.
Every change is visible on the next frame, because an eval marks the head
dirty and the main loop repaints on its next tick.

This is the point of the rewrite (PLAN.md §1, §8). This document names what is
**contract** (stable, safe to build on) and what is **incidental** (works today,
may move).

## Trust model — read this first

The eval socket is **arbitrary code execution in the head's image, by design.**
It is the same trust a person at a REPL has, and the same trust the daemon's
exec tool already grants. Concretely:

- The socket is per-user, mode `0600`, under your runtime dir. Anyone who can
  read it can run any Lisp in the head — including `(quit)`, `(sb-ext:quit)`,
  or redefining the render path.
- There is no sandbox. Do not point a head's socket at a directory a stranger
  can write.
- A bad eval does not kill the head: `hack-handle` catches the error and
  answers `{"ok":false,"error":"…"}`. But a redefinition that breaks the render
  path *will* show on the next frame — that is how you see your change, for
  better or worse. Redefine, look, and if it is wrong, redefine again.

## The socket

Each head listens on its own unix socket:

```
$XDG_RUNTIME_DIR/leticl/tui-<pid>.sock      # when XDG_RUNTIME_DIR is set
/tmp/leticl-<uid>/tui-<pid>.sock            # fallback (agent contexts)
```

`<pid>` is the head's process id. The line protocol is one request per line:

```
→ eval <form>
← {"ok":true,"value":"…","ms":3}
← {"ok":false,"error":"…"}
```

`<form>` is one s-expression, read in the `:leticl` package with `*head*`
bound to the running head. The reply's `value` is the printed result, JSON-
encoded; `ms` is the eval's wall time.

## The CLI: `scripts/tui-eval`

The model calls this through its exec tool. It speaks the socket for you:

```
tui-eval --list                 # print the pids of the live heads
tui-eval --pid 412345 FORM      # eval FORM in that head
tui-eval FORM                   # eval FORM in the only live head
```

`FORM` is one argument (quote it in the shell). Examples:

```sh
# inspect the running head
tui-eval '(head-cols *head*)'
tui-eval '(session-seq (head-session *head*))'

# restyle: hide the reasoning rows on the next frame
tui-eval '(setf (getf (head-prefs *head*) :show-reasoning) nil)'

# change the status note (top of the status line)
tui-eval '(setf (head-status-note *head*) "restyled by the model")'
```

## The contract surface

The package `:leticl` (nickname `:lt`) **is** the public API — one package on
purpose, so a hack reaches everything without imports (PLAN.md §6, D3). Within
it, these are the **contract**: stable names a restyle can rely on.

**The root and its state** — read these to inspect, `setf` them to change:

| symbol | is |
|---|---|
| `*head*` | the running head; the root every eval reaches |
| `head-cols` / `head-rows` | the terminal size the head is painting at |
| `head-screen` / `head-prev-screen` | the current / previous cell buffer |
| `head-prefs` | a plist: `:show-reasoning`, `:show-tools` |
| `head-mode` | `:normal :picker :help :status :config :jobs :subagents :peek` |
| `head-dirty` | `t` when a repaint is pending (an eval sets this) |
| `head-session` | the session state (below) |
| `head-composer` | the composer (the line being typed) |
| `head-status-note` | the note on the status line, or nil |

**The session** — the folded transcript:

| symbol | is |
|---|---|
| `session-seq` / `session-expected-seq` | last consumed / expected seq |
| `session-session-id` / `session-title` | identity |
| `session-items` | the transcript items (a vector) |
| `session-turn` | the in-progress turn, or nil |
| `session-wiring` | `{endpoint, model, dialect, role}` |
| `session-todos` | the todo entries, or nil |

**Rendering** — the functions that turn state into cells. Redefine one and the
next frame uses your version:

| symbol | is |
|---|---|
| `status-line` / `top-border` | the chrome (redefine to restyle the frame) |
| `markdown-lines` | transcript text → styled lines |
| `decision-card-lines` / `picker-lines` / `help-lines` | the cards and screens |
| `item-lines` / `turn-lines` | one item / the turn → lines |
| `style-index` | intern a style spec `(:fg :cyan :bold t …)` → an index |

**Cells** — the buffer a render writes into:

`make-screen`, `screen-put`, `screen-put-string`, `screen-cell`, `cell-ch`,
`cell-style`, `paint-diff`, `paint-full`.

A **line** is a list of **segments**; a segment is `(cons TEXT STYLE)` where
`STYLE` is a style plist (or nil for default). Style keys: `:bold :dim
:italic :underline :reverse :strikethrough :fg :bg`. Colors are a name
(`:cyan`, `:bright-black`), an integer 0–255, or `(r . (g . b))`.

## What is incidental

Everything else in the package works today but is not promised: the `%`-
prefixed internals (`%make-head`, `%render`, `%handle-key`, …), the mailbox
and thread plumbing, the exact plist shapes of decoded frames. If a restyle
needs one of these, it can use it — but expect it to move.

## A restyle, end to end

```sh
# 1. see what is running
tui-eval --list
# 2. look at the current status line
tui-eval '(status-line *head* (head-cols *head*))'
# 3. redefine it — the next frame uses your version
tui-eval '(defun lt:status-line (head cols)
           (list (cons (format nil " ★ ~a · seq ~a "
                               (session-title (head-session head))
                               (session-seq (head-session head)))
                       '(:bold t :fg :magenta))))'
# 4. if it is wrong, redefine again — no restart, no detach
```

The redefinition takes effect on the next call to `status-line`, which is the
next paint. That is the whole trick: the render path is just functions, and the
image keeps its state across redefinitions.
