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

## Seeing both heads: `scripts/compare-heads`

```sh
compare-heads                     # byobu windows named `letibot` and `leticl`
compare-heads --lb 1:3 --lc 1:7   # explicit tmux targets
compare-heads --rows 19-63        # only these rows
compare-heads --plain             # text only, no escapes
```

Captures both windows back to back with `tmux capture-pane -e` and prints every
row that differs, **escapes included**. The `-e` is the point: a bold title over a
dim path and an all-bold header are the same plain text, and a plain diff had been
reading that difference straight past for two rounds. Two heads on the same
session at the same size should be byte-identical except where a number was
measured by the head itself (its own cost since attach, its own call durations,
its own `dropped`); every other row it prints is a rendering difference, and the
row is the finding. Exit 0 when every row matched.

## The CLI: `scripts/tui-eval`

```
tui-eval --list                 # print the pids of the live heads
tui-eval --pid 412345 FORM      # eval FORM in that head
tui-eval --socket PATH FORM     # eval FORM in the head at that socket
tui-eval FORM                   # eval FORM in the only live head
tui-eval --file PATH            # push a file's top-level forms, live
tui-eval --file PATH --all      # … including the ones skipped by default
tui-eval --tree                 # push EVERY src file, in leticl.asd order
tui-eval --where SYMBOL         # which definition is live, and where it came from
tui-eval --screen               # what the head last drew, ANSI stripped
tui-eval --no-verify            # eval without the render gate
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

### A measurement that takes time starves what it measures

**An eval holds the paint lock, and the loop you are measuring runs under it.** `tui-eval`
takes `paint-lock` for the whole eval so a push cannot land in the middle of a frame
(`src/render.lisp:873-895`), and the same mutex is held by `%render-and-paint`. So a form
that blocks — a `sleep`, a long walk, a big allocation — holds the lock for its whole
duration, and **the head stops drawing, stops folding and stops counting until it returns**.
The loop is not slow; it is not running.

This was measured the wrong way and produced a wrong constant. The loop rate and the
`head-status-note` TTL were first read with the `sleep` **inside one eval**:

```sh
# WRONG — the sleep holds the paint lock and freezes the loop for the whole 60 s
tui-eval '(progn (sleep 60) *tick-count*)'
```

`*tick-count*` barely moved and the TTL read 60 → 59, i.e. "one loop pass a minute" — which
is exactly the bias, stated as a fact. The sleep belongs in the **shell, between short
evals**, so the lock is held for microseconds per call:

```sh
tui-eval '*tick-count*'; sleep 2; tui-eval '*tick-count*'
```

Run that way the loop is ~43 passes/s and the TTL goes 60 → 31 in 0.3 s (R10, and the
table in `docs/parity/panes.md`). **The rule: a measurement that takes time starves what it
measures, and a constant derived from it carries the bias silently.** If the form you want
to run is slow, run it in pieces — or measure from outside the head, where there is no
lock to hold.

### A chord you press through the socket is pressed for real

The second half of the same lesson, and it has cost more: **an eval that drives a key is
not a test, it is the operator typing.** There is no sandbox — the head it lands on is the
one on their terminal, with their session, their composer and their daemon.

```sh
tui-eval '(%handle-key *head* (list :type :ctrl :ch #\c))'   # opens the QUIT CARD
tui-eval '(%handle-key *head* (list :type :char :ch #\2))'    # …and asks the daemon to STOP
```

Two of those in a row, on a live head, are the operator's afternoon: a card they did not
ask for on their screen, and a daemon going away under them. It is not hypothetical — a
probe in this session wrote exactly that sequence into a live head while looking for a
counter, and a batch of `:enter`s into a decision card would be worse, because those
answer for them.

So: **for anything that is a keystroke, use a scratch head.** Start a daemon and a head of
its own (a `tmux` pane, or `--replay --no-tty` for the render path) and drive *that*.
Global state has the same shape — `*head*` is the live one, and a form that redefines
`head-status-note` or binds a global changes what the operator is looking at.

**And a struct change cannot be pushed at all.** `notice-until` on `%make-head` (the R10
follow-up) is a layout change, and this SBCL treats one as a hard error: a `--tree` push
of `head.lisp` at a running head is not a soft failure, it is a head that dies mid-push
with half a tree. When a change is to the struct, say so and take the restart instead.

### A fixture poked into a live head is indistinguishable from the thing it imitates

**The fourth probe lesson, and the worst, because the first three cost a wrong
number and this one costs the operator a decision.**

A synthetic card is a *fixture*, and a fixture on the operator's screen is not on a
screen at all — it is in front of somebody who has to act on it. There is no way for them
to tell a decision this head was handed from one the daemon actually raised: same card,
same words, same keys, same consequence if they press one. **Two identical things, one of
which is a test, is the one shape a fixture must never have.**

Measured, and it is why this entry exists: a probe for R20 built a decision in memory —
`edit` wants write access with a sixty-line patch — pushed it into `*head*`, and read the
result off the glass. The comment said *"poked into MY head only: a decision is per-head
state, so nothing here reaches the operator's head or the daemon."* **The first half is
true and the conclusion is false: `*head*` IS the operator's head.** They were looking at
that window, saw a permission card with no selector in it, and had to ask a third party
what was asking them for permission. Nothing was.

So the rule is the file's oldest one with a sharper edge, and it extends the keystroke
rule above rather than repeating it: **a keystroke you send is the operator typing; a
CARD you inject is the operator being asked.** A card is worse, because they cannot even
tell it happened — a keystroke at least produces a visible result they caused.

```sh
# WRONG — this is a decision on their screen, and it is indistinguishable from a real one
tui-eval '(setf (session-open-decisions (head-session *head*)) (list <synthetic>))'
```

**How to do it instead.** A scratch head, always, with its own daemon or a session of its
own — the three measurements this session already did that way, and the pattern is in this
file:

* a job-pane measurement on the operator's daemon: attach a head of its OWN to that
  daemon's session and read *that* head's screen. The daemon state is shared; the head's
  screen is not, and the screen is what a fixture changes.
* `--replay FILE --no-tty` for anything on the render path, which needs no daemon at all.
* a scratch daemon (`--workspace /tmp/…`) when the fixture has to be a real session.

**And when a fixture genuinely cannot be avoided on a live head** — it can't always — say
so out loud in the same message, and clean it up in the same breath: the fixture's blast
radius is the operator's attention, and the least a probe can do is take its card down.
That is not a licence to keep doing it; it is what to do if you find you already have.

**A scratch head needs an IDENTITY, not a heuristic — and the heuristic is how the damage
above happened a second time.** A run that started its own head and then looked for it with
`tui-eval --list | sort -n | tail -1` did not find its own: it found the largest pid, which
is one of the operator's, pushed the fixture and then **two source files** into that head,
and knocked it over. The head it hit was in the `rano` window, mid-session.

So: **take the list BEFORE you start your head and diff it after.** The pid that was not
there before is yours, and nothing else is.

```sh
PRE=$(tui-eval --list | sort -n)
tmux new-session -d -s probe -x 80 -y 24
# … start the head …
for p in $(tui-eval --list | sort -n); do
  echo "$PRE" | grep -qx "$p" || PID=$p
done
```

**And a pid is not a head.** A scratch head you started is not the same process a minute
later if it died and something restarted it, and the operator's heads come and go all day.
Two guards, both cheap: the list is taken inside the same script that starts the head, and
the first thing done with the pid is a `--where` or a read of its screen to check it is the
session you think it is. **A push is not a read** — `--file` at the wrong pid writes code
into somebody else's running conversation, and a head cannot tell you it was the wrong one.

### A falsification can skip the DOCSTRING and leave the body that was the point

**Found 2026-09-23, while falsifying the merged-row fix, and it is the same shape as
*the arms of an experiment that all agree* — except the experiment was the falsification
itself.**

The fix under test was a predicate. To falsify it the predicate's body was replaced by
the old, wrong rule, spelled the obvious way:

    (defun %piece-of (text row)
      ;; FALSIFICATION: equality, which is what the tree had
      (equal text row)
      #+nil
      "TEXT is a WHOLE PIECE of ROW: …"
      (loop …))

`#+nil` skips the NEXT FORM, and the next form was the **docstring**, not the loop. So
the body became `((equal text row) (loop …))` — two forms, and a `defun` returns its
LAST one. The rule still answered by pieces. The suite came back **5156 green**, and the
honest reading of that is not *the fix is not needed* but *the falsification did not
falsify*.

What caught it was not the suite: it was asking the predicate the question directly
(`(funcall piece "a" "a<newline>b")` → `T`, when it had just been set to `equal`). **A
falsification that passes deserves the same suspicion as an experiment whose arms all
agree.** Move the wrong rule to the END of the body, or wrap the real one:

    #+nil (loop …)
    (equal text row)

and check the falsified form answers differently before believing the run.

### A probe that waits before applying its variable measures the wait

**The sibling of *a measurement that takes time starves what it measures*, and it bit
2026-09-23 while re-measuring the orphaned-daemon race.**

The thing under test was a TIMING: a `Stop` frame followed by the socket closing, where
closing at once leaves the daemon alive and closing a second later does not. The first probe
sent the `Stop` and then **read frames for three seconds** before closing — so every arm had
three seconds to finish, all three read `gone after 200ms`, and the conclusion would have been
*the race is fixed*. It is not: closing at once still strands the daemon, and the corrected
probe — which closes before any read — shows it.

**The rule: the variable has to be applied before the thing it is a variable of can finish.**
A probe that reads to EOF, sleeps, or waits for a reply before doing the thing it is varying
has measured the wait. **And if the arms of a probe all agree, that is the first thing to
suspect** — three arms built to differ, and differing in nothing, is a probe that never
applied its difference.

Two smaller tells from the same run, both worth knowing:

- **A daemon that answers `bye` on ATTACH is refusing a version, not failing.** The reply
  carries the reason: `"protocol version 23, this daemon speaks 24"`. A probe that prints only
  the frame names sees `['bye']` and learns nothing.
- **A scratch daemon must be killed by HANDLE.** `pkill -f <path>` matches the shell writing
  the pattern, so it refuses itself; `pkill` (the tool) with `action: list` then `kill` +
  `pids` is the way, and it reports what it actually killed.

### The gate REFRESHES what it measures

The third of these, and the one that wasted the most time, because it does not look like
a measurement problem — it looks like good news.

`scripts/tui-eval` proves the head can still paint by **poking `head-dirty`** and checking
the loop clears it (`:220`, `POKE_FORM`). So every eval asks for a frame. A probe that
reads the head twice to see whether something on the screen is *moving* therefore gets a
screen that moves **because the probe is poking it**:

```sh
# WRONG — this answers "does the loop paint on an eval", not "is the frame live"
tui-eval '…'; sleep 2; tui-eval '…'
```

Measured while chasing R13 (a running call's number frozen on the glass): through the
socket the number read *moving* — `1m15s` then `1m18s` — and the conclusion would have
been that there was nothing to fix. The same head, the same two seconds, read from the
shell with **no eval in between**:

```sh
tmux capture-pane -p -t <session> | grep 'Running ·'   # x4, two seconds apart
#   Running · 1m19s   Running · 1m19s   Running · 1m19s   Running · 1m19s
```

Frozen. So: **to watch a live screen, watch the screen** — `tmux capture-pane`, or
`--screen` on a head you are not also probing — and keep the eval socket for reading and
changing state. The two rules are one rule from two sides: an eval that takes time
starves what it measures, and an eval that pokes dirt REFRESHES it.

## `--tree`: make the head match disk

**The gate checks that the head can *paint*, not that your change is *loaded*.**
Those came apart as soon as rendering lived in more than one file: edit
`src/cards.lisp`, push `src/render.lisp` (which used to hold all of it), and you
get `exit 0` with a green gate and the old cards still on screen. A green gate
means the head is healthy, never that your file is in it.

```sh
tui-eval --tree
# pushing the tree in leticl.asd order (23 files)
#   package.lisp   (:EVALUATED 0 :SKIPPED ("defpackage" "defpackage") :FAILED NIL)
#   …
# ok: 23 files pushed
```

It reads `leticl.asd` for the file list, so it pushes exactly what the system
loads, **in the order the system loads them** — the asd is `:serial t`, and some
other order can evaluate a form before the thing it calls exists. (The asd writes
components without the extension, so `src/package` means `src/package.lisp`.)

**It stops at the first failure**, and says so loudly, because the failure mode
it guards is the quiet one: a half-pushed tree is a new `cards` beside an old
`render` — coherent enough to pass the gate and wrong on the screen. Fix, re-run
`--tree`, and only then believe what you see.

## `--where`: which code is live

```sh
tui-eval --where item-lines
# item-lines: from the IMAGE — (:FILE "/home/dead/Projects/leticl/src/cards.lisp" :FORM-PATH (4) …)

tui-eval --tree
tui-eval --where item-lines
# item-lines: PUSHED — came down the eval socket, not from the image (source is null)
```

Two states, and it is the pair that answers "was that push applied": a definition
**baked into the image** carries the `.lisp` path it was compiled from, and one
that came down the eval socket was `EVAL`'d, so its source is null. Neither
answer is derivable from the other — a green gate cannot tell you, and neither
can the file's mtime.

It reads the head's own record via `sb-introspect`, which is **a contrib, not
part of SBCL's core**: `freeze.lisp` requires it, and a bare SBCL has no such
package until `(require :sb-introspect)`. Two traps worth knowing if you touch
this:

- `sb-introspect:find-definition-source` is **read before anything is
  evaluated**, so a guard inside the form never gets to run — a head without the
  contrib fails with a *reader* error, not a helpful one. The form uses
  `find-symbol` + `funcall` so the package is never named at read time.
- `:sb-introspect` is **not pushed onto `*features*`** even after the require, so
  a `#+sb-introspect` reader conditional silently picks the wrong branch. Do not
  reach for one.

A head built without the contrib says so, and says how to fix it.

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
| `*styles*`, `*style-sgrs*` (cells) | the style intern table and its SGR cache, which are **PARALLEL** — index N of one describes index N of the other. Cells hold indices into the pair, so resetting either repaints the screen in wrong colours or, worse, indexes the other past its end |
| `*saved-termios*`, `*raw-termios*`, `*raw-fd*` (term) | the terminal state — lose the first and a head cannot put your terminal back |
| `*hl-so*`, `*hl-attempted*` (highlight) | the loaded shim handle; resetting it silently turns highlighting off |
| `*request-counter*` (protocol) | a monotonic id counter, which a rewind could repeat |
| `*last-render-error*`, `*paint-lock*` (render) | the render failure flag and the paint/eval mutex |

**The pairing is the trap, twice now.** `*styles*` was made a `defvar` and
`*style-sgrs*` — the very next declaration in the same file — was not, because
one looked like live state and the other looked like a cache. They are one piece
of state in two vectors: a push reset the cache, cells kept the indices, and the
next paint died with *"Invalid index 8 for (VECTOR T 8)"*. **When a table has a
sibling, the sibling is live state too** — check what else is parallel to what
you are changing. A head already carrying the split can be repaired in place
(`rebuild-style-sgrs`) rather than restarted, which is the point of a head that
can be patched while it runs.

`tests/tests.lisp` has a check for this class (`live-state-tables-are-defvar`):
it greps the sources for the declarations of every name in the table above and
fails if one is a `defparameter`. Add your name to that list when you add one to
this table — a rule in a document has already failed to prevent this once.

Static data — colour-name tables, SGR strings, ranges, `*slash-commands*` — may
stay `defparameter`; re-initialising it is harmless.

### The paint heals its own stream

`*stdout*` going missing is a special case, because of what it does to the MAIN
thread: `%render-and-paint` writes the frame there, and a write to `NIL` is a
type error, which in `--disable-debugger` mode **quits the process**. So a
clobbered stream did not just stop the rendering — it took the head down with
nothing in any log.

`%render-and-paint` therefore calls `%open-stdout`, which returns the live
stream or opens fd 1 again. A clobbered `*stdout*` now costs one repaint, not
the head; the gate still reports it, and the head keeps running so it can be
fixed in place.

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

## Freezing the image while heads are running

**Not an injury — a hazard that was noticed before it fired.** It sits under its own
heading rather than inside `## Injuries`, because that section's contract is *a real
accident against a real head*, and writing a predicted cost as if it were a suffered one
is the overstatement this document exists to avoid. What follows is therefore *reasoning
about a risk*, marked as such, with the parts that WERE measured named as measured.

**How the obvious way is wrong.** `sbcl --script freeze.lisp` writes `bin/leticl-head`
**in place**, and the heads you are looking at are *executing that file*: their text
pages are mapped from it. MEASURED — `ps -eo pid,cmd | grep bin/leticl-head` showed
**six** running heads the last time this was checked, the oldest up 6 days 17 hours. So
the dangerous case is the normal one, not the rare one: the operator's own pane is
usually among them.

**What it would cost (PREDICTED, not measured).** A write to a mapped executable is not
atomic; a process can be served a page that is mid-update. In the benign case that is a
torn frame; in the bad case it is a fault inside a head that has no way to recover — the
same shape as the `Unhandled memory fault at #x0` this tree has already spent a session
on. It would be worse than the `defparameter` injury below, where a clobbered stream
costs a repaint: a clobbered `.text` costs the head, and the six running heads are the
ones at risk. **I have not seen a head die this way.** The counter-argument that it is
harmless because the rename never happens is exactly what is being removed.

**The transaction** (`scripts/freeze-safe`, which has run successfully):

1. **`mv` the current image aside first.** A rename does not touch the inode, so every
running process keeps *exactly* the bytes it started with — and the move incidentally
produces the `bin/leticl-head.prev-HHMM` backup the directory already kept by hand,
which is where that convention came from;
2. **freeze.** `save-lisp-and-die` now creates a NEW file at the canonical path, so
nothing maps the file being written;
3. **if the freeze FAILS, move the old one back**, so the path is never left without an
image and a failed build costs nothing.

```sh
scripts/freeze-safe          # the freeze log goes to /tmp/leticl-freeze.log
```

**Two things to know when checking a fresh image**, both MEASURED, and both of which
cost me a wrong reading the first time:

- **`strings` does not find your work.** Comments and docstrings never enter an image, so
grepping the binary for a line of prose finds nothing and reads as a failed build. **Symbol
names DO land** — `strings -a bin/leticl-head | grep -c ECHO-LEFTOVER` — and so do a
function's own string literals. `./bin/leticl-head -h` and a `--replay` over a fixture are
the two checks that actually exercise it.
- **`/proc/<pid>/exe` names the file the process STARTED from, not the current one.** After
this transaction a running head's exe reads `.../bin/leticl-head.prev-1540`, which looks
alarming and is exactly right. A head showing `(deleted)` was started from an image an
EARLIER freeze had already replaced — it is not a symptom of this one.

## Injuries

What the live surface has actually cost, so the next person recognises the shape
before it happens to them. Each entry is a real accident against a real head,
with what it did to the operator and what changed because of it.

### A live `defparameter` clobbered the head's stream — the head died

**How.** `tui-eval --file src/head.lisp`, pushing a whole file into a head that
was mid-session. The file contains `(defparameter *stdout* nil)`, and
`defparameter` assigns unconditionally, so the push re-initialised the running
head's output stream to NIL at load time.

**What the operator saw.** The screen tore: every frame after that was written
nowhere, and the half-written frames left the terminal disagreeing with the
head's cell buffer. Then it got worse — `%render-and-paint` writes the frame on
the **main thread**, and a write to NIL is a type error, which in
`--disable-debugger` mode **quits the process**. The head exited. Nothing in any
log said why.

**What changed.** Every variable in this tree that holds RUNNING state is
`defvar` (see the table above), so a push cannot re-initialise it.
`%render-and-paint` reacquires the stream through `%open-stdout`, so a clobbered
`*stdout*` costs one repaint instead of the head. `tui-eval` grew the render
gate, which names this exact failure and exits 3 — and `--screen`, which prints
what the head did draw, so a torn screen can be read rather than described.

### Resetting the style table repainted the frame in wrong colours

**How.** The same push, `src/cells.lisp`, whose `*styles*` was then a
`defparameter`.

**What the operator saw.** Colour mangle across the whole render: cells hold
**indices** into `*styles*`, so re-initialising the table (a fresh array with
only the default) left every on-screen cell pointing at a style that was no
longer there. Not a crash — a screen that was wrong in a way that looks like a
rendering bug and is not one.

**What changed.** `*styles*` is `defvar`. The rule generalised: a table whose
entries are referenced by index from live state is live state.

### A compile note painted over the render and desynced the screen

**How.** An ordinary `tui-eval '(defun …)'` whose form compiled with a warning.
The eval ran with `*standard-output*` bound to the head's own terminal stream,
so SBCL's compile report was written **into the TUI**.

**What the operator saw.** The report painted over the render. The damage that
mattered was not the ugly frame but the desync: the terminal no longer matched
the head's cell buffer, and `/cells` — which sends the cell buffer — therefore
could not show what the operator was actually looking at, which is the one thing
`/cells` exists to do.

**What changed.** `hack-handle` binds `*standard-output*` and `*error-output*` to
string streams and mutes `warning` and `style-warning` (`hack-mute`), so nothing
an eval compiles or prints can reach the TUI. Note for whoever edits this: the
binding must be **string streams, not NIL** — `*standard-output*` is declared
type `stream`, and the compiler prints notes directly rather than through a
condition handler, so NIL turns the leak into a `SIMPLE-TYPE-ERROR` at the worst
moment.

### A multi-line form was cut at its first line

**How.** A `FORM` argument that contained a real newline — a `defun` written
across lines and passed as one shell argument:

```sh
tui-eval '(defun status-line (head cols)
           (list (cons "x" nil)))'
```

**What the operator saw.** Nothing — which is the trap. The protocol is
line-based and the head reads one line, so it received an unbalanced form: no
error anyone looks at, just a redefinition that did not happen.

**What changed.** Documented loudly (see *A restyle, end to end*), and `--file`
exists so a multi-line definition can be pushed as a whole form. The test suite
asserts the cut is real, so the rule cannot quietly rot.

**And collapsing the newlines is not enough — a COMMENT turns the rest of the form
into prose.** The obvious workaround is to flatten the form before sending it:

```sh
FORM=$(cat <<'EOF' | tr '\n' ' '
(let ((h leticl::*head*))
  ;; note the thing
  (list :a 1 :b 2))
EOF
)
```

The newline is gone, so `;; note the thing` now runs to the end of the form, and
the head answers `#<END-OF-FILE>` — which reads like a syntax error and is not
one. Measured 2026-09-23 while probing R25, twice, in both spellings of the
workaround: the first attempt used comments inside the form, and the second tried
to strip them with `sed 's/;.*//'`, **which also ate `~;` inside a format string**
and mangled a `format` call in the same probe. **Comments go outside the form.**
If a form must be built by a programme, strip comments only with something that
knows a string literal when it sees one — or, better, do not put them in.

**Two more shapes of the same injury, for the same reason.** A form that came back
`#<UNDEFINED-FUNCTION GET-OUTPUT-STRING>` was not a missing function: the eval's
package has no binding for that name, so a form should use what the head itself
uses or take the text as a **literal spliced in by the caller**. And a form that
carries a JSON string needs its double quotes escaped **for the Lisp reader**
before it is spliced — the raw text `{` `"command": …` `}` has its quotes eaten
by the outer string, and the head answers `#<UNBOUND-VARIABLE COMMAND>`, which is
the tell.

### A fixture that borrows another test's keys inherits its state

**How.** Two sets of tests, each building a head whose tool rows are keyed `c1`,
`c2` … — the payload-window fixtures and, later, R25's subject fixtures. Both write
into `*call-targets*`, which is a `defvar`.

**What happened.** R25's tests put a 300-character subject under `c1`; the payload
tests' rows, which carry no `arguments` and so are supposed to fall back to `(c1)`,
picked the long subject up and two seam assertions failed with a `…` on a header
that has nothing to do with them. **Both files were right and the suite was wrong**, in
the way this file keeps describing: a global that survives between tests is not
state, it is an *environment*.

**What changed.** The R25 fixtures use their own keys (`r25-c1`), and `%payload-head`
clears the targets for the ids it is about to use, so its fixture is deterministic
whatever ran before it. The general rule is the one `run-all` already applies to
files: a fixture declares everything its assertions depend on, including the parts
of it that live in a global.

### The wrong daemon, from a direct invocation

**How.** Running `bin/leticl-head --session <id>` directly, without
`~/bin/leticl` to set `$LETIBOT_SOCKET` from the working directory.

**What the operator saw.** A fresh, empty session — the head had attached to
another workspace's daemon, found by directory order. The session the operator
named was never opened, and the daemon that did answer wasn't theirs.

**What changed.** `discover-daemons` prefers the daemon whose `workspace`
contains the current directory, and among matches the **longest** — `/home/dead`
contains `/home/dead/Projects/leticl`, so a shorter match must not win. This is
the one injury here that is not the live surface's fault, and it is recorded
because the symptom (an empty screen) looks exactly like a render bug.

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

### Wire state stays a plist — and that is the point

**What the daemon sent is never converted to an object.** A frame, a snapshot
item, an event — all keyword plists, exactly the keys the daemon wrote
(`PLAN.md` D4 and §7). So an eval can read the raw truth:

```sh
tui-eval '(getf (aref (session-items (head-session *head*)) 0) :item)'
# → the item as the daemon serialised it, not this head's opinion of it
```

If you are extending the render for a row type, **do not give the row a class**.
Add a method specialised on the kind keyword and leave the data alone:

```lisp
;; the dispatch reads the wire type; the item stays a plist
(defmethod item-lines-for ((kind (eql :tool_result)) item cols head)
  (list (list (cons (format nil "  ~a" (getf item :name)) '(:bold t)))))
```

A model can therefore teach a running head a row type it has never seen, from
the eval socket, without touching the dispatcher and without losing the ability
to inspect what arrived. That is the trade this document exists to protect.

What *does* become a class is the head's **own** state — a card cache, a
pickset, anything this head invents that is not on the wire. Classes reshape
live (an added slot reaches existing instances with its `:initform`); `defstruct`
refuses a layout change outright (*"redefine the STRUCTURE-OBJECT class …
incompatibly"*), which is why `--file` skips it.

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
