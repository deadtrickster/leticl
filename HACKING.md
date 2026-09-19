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
$XDG_RUNTIME_DIR/tui-<pid>.sock             # when XDG_RUNTIME_DIR is set
/tmp/leticl-<uid>/tui-<pid>.sock            # fallback (agent contexts)
```

`<pid>` is the head's process id. **The runtime dir is the one the head was
STARTED under**, which need not be yours: a head launched from a real terminal
has `XDG_RUNTIME_DIR=/run/user/<uid>`, while an agent context usually has none
and would look in `/tmp/leticl-<uid>`. `scripts/tui-eval` searches both, and
`--socket` names one outright. The line protocol is one request per line:

```
→ eval <form>
← {"ok":true,"value":"…","ms":3}
← {"ok":false,"error":"…"}
```

`<form>` is one s-expression, read in the `:leticl` package with `*head*`
bound to the running head. The reply's `value` is the printed result, JSON-
encoded; `ms` is the eval's wall time.

## The CLI: `scripts/tui-eval`

```
tui-eval --list                 # print the pids of the live heads
tui-eval --pid 412345 FORM      # eval FORM in that head
tui-eval --socket PATH FORM     # eval FORM in the head at that socket
tui-eval FORM                   # eval FORM in the only live head
tui-eval --file PATH            # push a file's top-level forms, live
tui-eval --file PATH --all      # … including the ones skipped by default
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

## `--file`: patch a running head from the source

**This is the one that saves a restart.** Edit `src/head.lisp`, then:

```sh
tui-eval --file src/head.lisp
# {"ok":true,"value":"(:EVALUATED 25 :SKIPPED (\"in-package\" \"eval-when\" \"defstruct\") :FAILED NIL)"}
```

The head opens the file and evaluates each top-level form **in order, in its own
image**. That is why the reading happens there and not in `tui-eval`: the forms
are read with the head's `*package*` (`:leticl`, which uses alexandria), so
`alet`, the reader macros, and every symbol resolve exactly as they do at load
time. A reader in some other process could not promise that.

Each form is evaluated independently: a form that errors is reported in
`:FAILED` and the rest are still tried, so one bad `defun` does not hold the
file hostage. `:EVALUATED` and `:SKIPPED` say what happened to the rest.

**Forms that are skipped by default** (`--all` sends them anyway), because they
change layout or definitions the running image already copied:

| form | why |
|---|---|
| `defstruct` `defclass` | existing instances keep the old layout — a live redefinition is a trap, not a patch |
| `defconstant` | a changed constant value is undefined behaviour |
| `defpackage` | the package exists; re-evaluating adds nothing and can unuse |
| `define-symbol-macro` | expands at compile time; already-compiled code keeps the old one |
| `eval-when` `require` `in-package` | side effects already happened at load; skipped so the load stays pure |

To push the whole tree (what a fresh image would have):

```sh
for f in src/*.lisp; do tui-eval --file "$f"; done   # package.lisp skips to a no-op
```

Every `defun` redefinition is live on the next repaint: the eval marks the head
dirty, and the loop repaints when dirty. **What genuinely needs a restart** is
narrow — and worth knowing, so `--file` is not mistaken for a rebuild:

- a change to the **toplevel** (`freeze.lisp`'s `main`) or to the frozen image
  itself: that is a new binary by definition;
- a change to a **macro** that already-compiled code expanded;
- a change to a **struct layout** or a **class** (see the table);
- a change the running loop has already captured, e.g. a thread's body
  (`make-thread` has already been called), or an in-flight `unwind-protect`.

Everything else — functions, `defparameter`s, render logic, the daemon
discovery — is live.

### Live state must be `defvar`, never `defparameter`

`defparameter` **assigns unconditionally**, so pushing a file that holds a
`defparameter` re-initialises that variable in a head that is mid-session. That
is right for a fresh image and wrong for a live one. `defvar` assigns only when
the variable is unbound, which is exactly the meaning a live push needs.

This is not a style point. It has already cost an operator a session: a push of
`src/head.lisp` ran `(defparameter *stdout* nil)`, and every frame afterwards
was written nowhere. The head stayed alive and answered evals while the screen
tore, with nothing in any log.

Anything in this tree that holds RUNNING state is `defvar` and must stay so:

| variable | holds |
|---|---|
| `*head*`, `*stdout*` | the running head, and the stream it paints on |
| `*styles*` (cells) | the style intern table — cells hold INDICES into it, so resetting it repaints the screen in wrong colours |
| `*saved-termios*`, `*raw-termios*`, `*raw-fd*` (term) | the terminal state — lose the first and a head cannot put your terminal back |
| `*hl-so*`, `*hl-attempted*` (highlight) | the loaded shim handle; resetting it silently turns highlighting off |
| `*request-counter*` (protocol) | a monotonic id counter, which a rewind could repeat |

Static data — colour-name tables, SGR strings, ranges, `*slash-commands*` — may
stay `defparameter`; re-initialising it is harmless.

## The render gate

**Every eval is gated on the render.** After the form runs, `tui-eval` captures
the head's own state and refuses to call it a success if the head can no longer
paint. In order:

1. it pokes a repaint (`(setf (head-dirty *head*) t)`) and checks the loop
   cleared it — a dead render thread leaves it `T` forever;
2. it checks the head still has a stream to paint on (`*stdout*` non-nil);
3. it checks a **full frame** is on screen (rows == the terminal's rows).

A green run says so on stderr:

```
$ tui-eval --file src/render.lisp
{ "ok": true, "value": "(:EVALUATED 31 :SKIPPED (\"in-package\") :FAILED NIL)", "ms": 27 }
gate: stdout=ok rows=61/61 cols=227/227 rows-n=61
```

A failure is **exit 3** — the eval RAN, the head is in the state it left it, and
the message names what broke:

```
GATE FAILED — the head is not rendering correctly:
  · *stdout* is NIL — the head has no stream to paint on; every frame is being written nowhere (a live `defparameter` can clobber it)
```

`--screen` prints **what the head last drew** — the rows it painted, ANSI and
all, which is the same bytes `/cells` sends. Use it to see the render rather
than being told about it:

```sh
tui-eval --screen            # the drawn frame, ANSI stripped for reading
```

`--no-verify` skips the gate. Use it for a deliberate eval that is expected to
break the render (as the gate's own test does), never for a source push.

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

**A `FORM` must be one line.** The socket is line-based: the head reads one line
and one form from it, so a form with a newline in it is cut off at the first
line. Write it on one line (long lines are fine), or put it in a file and use
`--file`, which reads whole forms.

```sh
# 1. see what is running
tui-eval --list
# 2. look at the current status line
tui-eval '(status-line *head* (head-cols *head*))'
# 3. redefine it on one line — the next frame uses your version
tui-eval '(defun lt:status-line (head cols) (list (cons (format nil " ★ ~a · seq ~a " (session-title (head-session head)) (session-seq (head-session head))) (list :bold t :fg :magenta))))'
# 4. if it is wrong, redefine again — no restart, no detach
```

Or keep the definition in a scratch file and push it whole:

```sh
cat > /tmp/status.lisp <<'EOF'
(defun status-line (head cols)
  (list (cons (format nil " ★ ~a · seq ~a "
                      (session-title (head-session head))
                      (session-seq (head-session head)))
              '(:bold t :fg :magenta))))
EOF
tui-eval --file /tmp/status.lisp
```

The redefinition takes effect on the next call to `status-line`, which is the
next paint. That is the whole trick: the render path is just functions, and the
image keeps its state across redefinitions.
