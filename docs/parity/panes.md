# Panes, cards and head state — leticl against letibot

**Surface:** the full-body screens, the cards, the head's own persisted state, the
head's lifecycle and the instrumentation the operator reads. Not the key table, not
the wire, not transcript row rendering — those are measured elsewhere.

**Reference:** `/home/dead/Projects/letibot/letibot` at `8af671e`
(`git -C … rev-parse HEAD` → `8af671e3467ce0a139ba25d99a18378ba39c910b`).
Cited as `app.rs:N`, `term.rs:N`, `prefs.rs:N`, `bin/letibot-tui.rs:N`, `driver.rs:N`
— all under `crates/tui/src/`.

**Subject:** `/home/dead/Projects/leticl` at `dc62ddf` (2026-09-20 22:19; the pass
finished at `7c2c6fc`, 23:37). Cited as `src/NAME.lisp:N`.

**A SNAPSHOT, NOT THE TREE — and on 2026-09-22 that cost a day's work.** Twenty-three
minutes after this pass closed, `b7a2620` landed (**Enter on a jobs row opens the
output in a pane**) — and nothing re-measured the three rows that said otherwise:
**G4** here, `keys.md` **G20**, `wire.md` **W2**. They went on saying MISSING, and on
2026-09-22 a driver read them and handed that line to the head as work: *"Take T1(3) —
it is the one B-side defect left"*, on a defect that had been closed for a day and a
half. **The §2.6 incident, mirrored**: that one was a commit message claiming work
that was not there, this one is four documents claiming work was MISSING that was
there. Neither is catchable by a test, and both are catchable by one rule — *a
criterion names a test, and the test is run from the tree as committed*.

Those rows now carry the measurement and its date. **Every other row here is true of
`dc62ddf` and says nothing about today; re-measure before acting on one.** Re-measured
2026-09-22 against the tree at `047f9ad` (the behaviour landed in `b7a2620`): this
file's **G4** and the **job_out** row.

**Method.** Read on both sides; every verdict below carries a line on each. Nothing
was run, no keys were sent, no head was restarted.

**A caveat about the archived captures.** `docs/archive/2026-09-20/captures-panes/`
was read and is useful, but it is **stale relative to HEAD**: commit `26bb3a8` (two
before HEAD) changed `hint-bar` and the pickers, and the captures still show the
pre-fix screens. Two examples measured: the captures show leticl's hint bar with no
composer prefix, which `src/chrome.lisp:349-359` now emits; and they show a markless
TODO heading at column 6 against letibot's 8, which `src/panes.lisp:761` now sets to
`:indent 6` → column 8. **Every verdict below is from source.** Where a capture
disagrees with source it is called out and the resolution is "re-capture", not "fix".

---

## Summary

**Parity (SAME):** the session picker, the mode/models picker card, the quit card,
the jobs pane, the subagents pane, the `/status` screen's structure and prose, the
help screen, the config pane's rows and render, the todos pane's parsing and roll-up,
the `allow-all` confirmation, the terminal enter/exit byte sequences, the
drain→draw→ack loop order, the money meter, the header's shape and degrade-by-deletion
ladder, and the prefs file format, parser, malformed-line notes and
non-destructive save.

**Differs:** the decision/permission card (no oracle verdict, no option ids, no glob
hint), the secret card (no countdown, dots in the card rather than in the composer),
the cat's frames and its padding direction, the attach wait's two extra rows, the
short-screen fit ladder, the config pane's cursor wrap and Enter guard, the counters'
accumulation across a resync, `--resume`, `--new-session`'s workspace, and the
identity every attach announces.

**Missing entirely:** the `slash_out` pane, the `job_out` pane, the notice line, the
stall line, the empty-session opening banner, the peek pane's spill file, `o` on a
subagent row, `--no-tty`, `--replay`, `--probe`, `--list-sessions`, `--interrupt-all`,
`--since`, `--body-lines`, `--reasoning-lines`, and a terminal restore on an unhandled
error.

**Two of these are not cosmetic and are covered in *What would stop the operator
switching today*:** the head's own notices are drawn on a row that a normal-sized
terminal never has, and the walking-cat attach wait cannot be reached on the startup
path.

---

## 1. Every full-body screen and card

### 1.1 The dispatcher

| | reference | leticl |
|---|---|---|
| where | `app.rs:5235-5273` (`fn screen`, the `if/else if` chain) | `src/render.lisp:343` (the `member` of `head-mode`) |
| screens | `slash_out`, `help`, `stats`, `picker`, `todos_pane`, `config_pane`, `sub_out`, `job_out`, `subagents_pane`, `jobs_pane`, else transcript | `:help :status :config :jobs :subagents :peek :picker :todos`, else attach-wait, else transcript |
| cards | `secret` → `decision` → `quit_card` → `mode_picker`/`models_picker`, `app.rs:5053-5066`; `mode_confirm` pinned above all chrome, `app.rs:5130-5136` | same order, `src/render.lisp:329-341`; `mode-confirm-lines` prepended at `:342` |
| verdict | — | **DIFFERS**: `slash_out` and `job_out` have no leticl mode; `sub_out` is a *mode* (`:peek`) in leticl rather than an *overlay*, so it replaces the subagents pane instead of sitting on it |

### 1.2 The screens

| screen | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| **help** | title `keys and commands`, 16-col cyan key, text wrapped at `w-19`, closer `/help or esc closes this` | `app.rs:8491` | identical rows, same order, same verbatim text | `src/panes.lisp:160-224` | **SAME** |
| **status** | `this head` + 9 counter rows, key 12 wide dim, gloss wrapped at `w-16` under a 14-col indent, closer | `app.rs:7674-7755` | same rows, same glosses verbatim | `src/panes.lisp:226-277` | **SAME** (structure; the numbers differ — §4) |
| **config** | 3 sections, `{▸}{✎}{key:<28} {value}`, selected row reversed with `from PATH` under it | `app.rs:6594-6648` | identical, plus a second return value (the cursor's line) | `src/panes.lisp:400-484` | **SAME** |
| **todos** | session plan + repo `TODO.md`, org roll-up, `···` for a folded body, unfold at `pad+8` | `app.rs:6705-6776`, `app.rs:8395-8478` | same rows, same roll-up, same `···` | `src/panes.lisp:737-816`, `901-936`, `944-1016` | **SAME** (the captures' 2-col heading gap is closed at `src/panes.lisp:761`) |
| **subagents** | title, `▸ [~] prompt` over dim `id · role · state`, footer naming `o` | `app.rs:6782-6838` | same rows, same footer text | `src/panes.lisp:619-690` | **SAME to draw**; the footer names a key leticl does not bind — see 1.4 |
| **jobs** | `▸ [~] id command` over dim `how · state · N out · ran Ns` | `app.rs:6996-7046` | same | `src/panes.lisp:532-593` | **SAME** |
| **sub_out / peek** | tail-first, `scroll` clamped where the height is known, `dropped` note, footer `arrows scroll, Enter re-reads, Esc back — full: {spill}` | `app.rs:6844-6892` | same title, same `dropped` note, footer without the spill | `src/panes.lisp:1061-1085` | **DIFFERS**: no spill file (`spill_sub_out`, `app.rs:8025-8060`, has no counterpart — `grep -rn spill src/*.lisp` finds only the per-call `:spill` field); Esc leaves to `:normal`, not back to the tree (`src/editor.lisp:242`); Enter is not handled for `:peek` (`src/editor.lisp:275-321` has no `:peek` arm) though the footer promises it; Up/Down move a cursor over `pane-row-count … :peek → 0` (`src/editor.lisp:749`), i.e. do nothing |
| **job_out** | its own overlay: `job output — id`, `state — bytes A..B of N`, `→`/`←` paging on a `back` stack, refusal rendered in the pane that asked | `app.rs:6894-6994`, `app.rs:3277-3300`, `app.rs:2794-2800` | same title, same `state — bytes A..B of N` line built from the offsets, the `dropped` note in the header, a `back` stack of offsets the daemon gave, a refusal wrapped in the pane that asked, and `reading…` until the first answer | `src/panes.lisp:1382-1544`, `src/session.lisp:1419-1446` | **SAME — re-measured 2026-09-22**, live: `job output — j74` / `exited 0 — bytes 0..899 of 899`, and on a running job with nothing written `it is running and has written nothing yet.` |
| **picker (sessions)** | header, two lines per session, facts right, id+workspace under every row, two dim closers | `app.rs:7049-7148` | identical, plus the subagent filter the reference also has (`app.rs:1667-1671`) | `src/panes.lisp:68-158` | **SAME to draw**; the cursor does not open on the current session — see 1.4 |
| **slash_out** | a slash reply of >3 lines opens a pane: bold echo, blank, wrapped body, `esc closes · up/down scrolls`; owns Esc/Up/Down while up | `app.rs:2785-2790`, `app.rs:5235-5243`, `app.rs:3319-3335` | **absent** — no mode, no `"slash"`-warning split; `%send-slash` just writes the frame (`src/commands.lisp:193-201`) | — | **MISSING** |
| **attach indicator** | centred cat, pawprints, `asking the daemon for this session`, elapsed, and at ≥2 s `the daemon has not answered. ctrl-c twice, or wait` | `app.rs:6061-6105`, `ATTACH_IMPATIENT` `app.rs:1313` | same seven rows, no impatient row | `src/chrome.lisp:663-682`, drawn `src/render.lisp:374-378` | **DIFFERS** on content **and unreachable at startup** — see 1.5 |
| **empty-session banner** | `letibot` + `attached, and this session has said nothing yet…` + `/help lists the keys.` | `app.rs:6112-6131` | **absent** | — | **MISSING** |

### 1.3 The cards

| card | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| **decision / permission** | `? {headline} [{kind}]` in yellow with the target *stripped out of the summary*; target alone, bold, 4 in; detail dim; **the oracle's verdict** (`model says X: basis`, cites, `by · N ms`); one option per line as `▸ {label}  ({option_id})`; hint `↑↓ to choose · Enter to answer · or type the id`, **plus a glob line only when `allow_always` is offered**; plus `deny_and_tell <why>` when `reject_always` is | `app.rs:7329-7466`; `ask_without_target` `app.rs:7865-7874` | the headline (target stripped by `ask-without-target`), the target, the detail, `because:` (the deterministic half the reference has no home for), the verdict **or an explicit *no oracle was consulted* under a permission**, the options with their ids, the glob line only when `allow_always` is on offer, the `deny_and_tell` hint, **and §1.6's `expires in … · if nobody answers, …`** | `src/panes.lisp:1955-2072` | **SAME, plus two** — the §1.6 line is this head's and the reference draws neither half (`550bc94`); the `because` line is the daemon's and is drawn verbatim. **R18 measured the card whole on 2026-09-22**: five of its statements are the daemon's (`3a9b183`, R18 in the criteria — now §12 of `~/Projects/head-parity-2026-09-21.md`) and the sixth — the time left — was this head's and was 56 years wrong until that commit |
| **question** | not a separate shape; `d.options` throughout | `app.rs:7329` | `kind == "question"` reads `:choices` and relabels the badge | `src/cards.lisp:1143-1150` | **DIFFERS (extra)** — harmless |
| **secret / password** | `sudo wants a password — {prompt}`, `for: {command}` wrapped, faint `type it below (shown as dots), Enter sends it once to sudo and nowhere else; Esc refuses · {N}s left`; **the dots are rendered in the composer box** and the text never even measured | `app.rs:7305-7327`; composer `app.rs:5343-5348`; `SecretAsk.deadline` `app.rs:10060` | 4 rows, ` password: ****` **inside the card**; footer `enter submits · esc refuses`; the composer keeps painting the ordinary buffer | `src/cards.lisp:1224-1238`; `src/chrome.lisp:503-537` has no secret branch | **DIFFERS** — no countdown, and the composer under the card still shows whatever was typed before the ask |
| **quit** | bold title, `▸ 1 leave this head` / `2 leave and stop the daemon`, consequence wrapped dim 8 in, the second naming how many other heads will be told | `app.rs:7175-7226` | identical text, identical shape | `src/cards.lisp:1194-1222` | **SAME** |
| **mode / models picker** | bold title, `▸ 1 name` with the row reversed whole and `← now` right, two dim hints (three for models) | `app.rs:7228-7303` | identical, reversal applied per-segment to match the reference's raw escapes | `src/panes.lisp:1163-1205` | **SAME** |
| **allow-all confirm** | wrapped not trimmed, attention role, pinned at the front of the chrome; `y`/`Y`/Enter confirm, everything else cancels | `app.rs:5130-5136`, `app.rs:2963-2978` | same text verbatim, same keys | `src/cards.lisp` → `src/panes.lisp:1208-1216`, `1304-1318` | **SAME** (the two notices differ in wording only) |
| **notice / `say` line** | its own chrome row, magenta `· {n}`, TTL 60 FRAMES, first-but-one thing the fit ladder drops | `app.rs:5069-5073`, `app.rs:5112-5121`, `app.rs:4709-4712` | its own chrome row (`notice-line`), magenta, one that **expires in TIME** — `+notice-ttl-ms+` 1600, armed by `say`, stopped by `clear-note`, the deadline a slot of the head — and a wait for a daemon that was asked to stop outranks it | `src/chrome.lisp:441-477, 934-1035` | **SAME screen, DIFFERENT clock** — see R10's follow-up, `57d20dc` |
| **stall line** | its own yellow chrome row; gated on a **running turn**, quiet > 15 s; names the model and `esc esc interrupts it` | `app.rs:7582-7608` | a fragment appended inside `status-line`; 20 s; **not** gated on a running turn | `src/chrome.lisp:285-312`, `327` | **MISSING in practice** — same suppression |
| **alarm indicator** | `⚠` inlaid in the composer's bottom border beside the turn status; the counters themselves on `/status`; an unboxed screen gets `⚠ dropped N · scrubbed N · resync N · /status` on its own row | `app.rs:5180-5192`, `app.rs:7650-7672` | `⚠` on the bottom edge via `composer-wiring` | `src/chrome.lisp:434-451`, `492-501` | **SAME** for the boxed case; the unboxed fallback row is suppressed the same way the notice is |
| **a daemon `Warning`** | drawn as a note anchored where it arrived, folded to 3 lines + `… +N lines · /notes`, retired by the reader and still listed by `/notes` and counted on `/status` | `app.rs:3320-3358`, `app.rs:11365-11430`, `app.rs:5767-5882` | a row filed where the envelope arrived, folded to `+note-lines+` + `/notes`, retired by `/notes`/`/dismiss`, still in `session-warnings` and counted as `notes  N of M retired` | `src/session.lisp:490-660,1061-1111`, `src/cards.lisp:1351-1381`, `src/panes.lisp:261-269,1318-1369`, `src/commands.lisp:204-268` | **SAME** (R10, done) |
| **turn status on the border** | `Responding · N tok · 4.2s · ⠹` pinned right on `╰…╯` | `app.rs:5180-5192`, `app.rs:7501+` | same | `src/chrome.lisp:377-410`, `444-445` | **SAME** |
| **attach indicator (top border)** | `N subagents running` pinned right on `╭…╮` when any are | `app.rs:5157-5177` | same, folded from `subagent-rows` | `src/chrome.lisp:412-432` | **SAME** |
| **completions line** | dim row above the composer listing `/name hint` matches; the first thing the fit ladder drops | `app.rs:4342-4358`, `app.rs:5075-5078` | Tab completes (`src/editor.lisp:118`) but **nothing is drawn** — `grep -rn completion src/*.lisp` finds only `%complete` | — | **MISSING** |

### 1.4 Keys the screens take

| screen | reference keys | citation | leticl keys | citation | verdict |
|---|---|---|---|---|---|
| any pane | Esc / Ctrl+C close; **every head chord still works** (Ctrl+R/T/X/L/S/P/G/Q/O are handled at the top of `key`, before every pane arm, so a chord can close or switch panes) | `app.rs:3016-3160`, `app.rs:3369-3390` | Esc closes; `q` closes; **`:ctrl` falls into the pane arm's `(t nil)` and is swallowed** — so Ctrl+C, Ctrl+D, Ctrl+L and every pane chord do nothing while a pane is open, and a chord cannot close or switch a pane | `src/editor.lisp:232-324` (`case type` has no `:ctrl`) | **DIFFERS** — G1 |
| any pane | PageUp/PageDown = a screen; wheel = 3 | `app.rs:3162-3235` | PageUp/Down = `room-1`; wheel = 3 | `src/editor.lisp:257-266` | **DIFFERS-trivially** |
| picker | Up/Down **wrap**, Enter on an empty composer switches, click selects; **the cursor opens on the session you are in** | `app.rs:3508-3547`; open at `app.rs:3080-3087` | Up/Down **clamp**, Enter switches, click selects; **the cursor opens at row 0** | `src/editor.lisp:234-241`, `297-303`; `src/commands.lisp:178-191`, `src/head.lisp:230` | **DIFFERS** — G2 |
| mode/models | Up/Down wrap, Enter, digit, click, type-a-name | `app.rs:3599-3656` | same but no click | `src/panes.lisp:1275-1302` | **SAME** (click is the reference's only extra here) |
| config | Up/Down **wrap**; Enter **gated on an empty composer** | `app.rs:3345-3369` | Up/Down clamp; Enter **not gated** | `src/editor.lisp:234-241`, `273-282` | **DIFFERS** — G3 |
| subagents | Up/Down, Enter peeks, **`o` switches into it** | `app.rs:3661-3717` | Up/Down, Enter peeks; **no `o`** (the arm's `:char` handles only `#\q`) | `src/editor.lisp:283-296`, `322-323` | **MISSING** — and the pane's own footer advertises it (`src/panes.lisp:686`) |
| todos | Up/Down over item stops with wrap, Enter **or Tab** unfolds | `app.rs:3719-3785` | identical logic (`(mod (+ at n) len)`) | `src/editor.lisp:752-768`, `267-272` | **SAME** (the captures' cursor divergence is a stale-capture artefact, not a code difference) |
| jobs | Up/Down, Enter opens the **job_out overlay** | `app.rs:3787-3860` | Up/Down, Enter **closes the pane and posts `/job ID`** | `src/editor.lisp:305-313` | **DIFFERS** — G4 |
| sub_out / peek | Up/Down scroll the view, Enter re-reads, Esc back **to the tree** | `app.rs:3237-3262` | Up/Down move a zero-length cursor, Enter unhandled, Esc to `:normal` | `src/editor.lisp:242-256`, `749` | **DIFFERS** — G5 |
| decision ladder | Up/Down **unconditional** (a permission that arrives mid-typing must not cost the typed line); Enter and digits gated on empty; selection **wraps** | `app.rs:3410-3466` | Up/Down/Enter/digits **all gated on an empty composer**; selection **clamps** | `src/editor.lisp:326-346` | **DIFFERS** — G7 |
| secret | every key is the field's; Enter sends, Esc/Ctrl+C refuses | `app.rs:2988-3013` | same, minus Ctrl+C | `src/editor.lisp:148-169` | **SAME** |
| quit card | Up/Down flip, 1/2, Enter, Esc/Ctrl+C stay | `app.rs:3559-3595` | same | `src/editor.lisp:172-201` | **SAME** |

### 1.5 Two suppressions worth their own paragraph

**The notice, the stall, the scroll count and the queue count are drawn on a row a
usable terminal never has.** `%render` computes
`status-text (and status (not boxed) …)` and `boxed` is `(>= rows 8)`
(`src/render.lisp:314,317`, `src/render.lisp:313`), so `status-row` and `alarm-row`
are both `NIL` on every terminal of 8 rows or more. `head-status-note` has **21 write
sites** — `grep -rn head-status-note src/*.lisp` — including
`"detached — reconnecting…"` (`src/head.lisp:150`), `"resync: …"` (`:211`),
`"bye: …"` (`:264`), `"reconnect: …"` (`:316`), `"send failed: …"` (`:81`),
`"key error: …"` (`:369`), every prefs-load note (`:415`), and every `say` from the
pickers and the config pane. None of them reach the screen. The reference draws the
notice as its own chrome row (`app.rs:5069-5073`, `app.rs:5112-5121`) and the stall as
another (`app.rs:5054`, `app.rs:5122-5124`).

**The walking cat cannot be reached on the startup path.** `attaching-p` is
`(and *attach-started-ms* (not (head-connected head)))` (`src/chrome.lisp:667-668`),
but `run` sets `(head-connected head) t` at `src/head.lisp:425` — deliberately, so the
ATTACH frame is not dropped, and the comment at `:420-424` says so — **before** it sets
`*attach-started-ms*` at `src/head.lisp:439`. The only other writer of the clock clears
it on Hello (`src/head.lisp:168`). So the predicate is false for the whole wait, and a
head attaching to a 2 600-row session draws an empty transcript instead. The unit test
that covers the screen sets `(head-connected h) nil` by hand
(`tests/tests.lisp:3227-3241`), which no startup path does. The reference's own comment
on why this frame exists is at `app.rs:6053-6060`.

---

## 2. Preferences

Four keys on both sides, and nothing else: `diff`, `thinking`, `tools`, `raw_calls`
(`prefs.rs:24,26,28,30` and the save whitelist `prefs.rs:147-152`; `src/prefs.lisp:20-21`
and `src/prefs.lisp:240-243`).

| setting | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| `diff` | `DiffPref::Split` default; accepts split/side-by-side/auto, unified/single | `prefs.rs:24,34-37,46-51,64` | `:diff` a **string**, default `"split"`, same six words | `src/prefs.lisp:38,55,206-209` | **SAME**; but the renderer's absent-value fallback is `"unified"` (`src/cards.lisp:709`), contradicting every declared default |
| `thinking` | `"folded"`; open/folded → `Fold` | `prefs.rs:26,65,122-131` | `:thinking` string ↔ `:show-reasoning` boolean | `src/prefs.lisp:41,57,85-86,212-216` | **SAME** |
| `tools` | `"folded"`; open/folded → `Fold` | `prefs.rs:28,66,122-131` | `:tools` ↔ `:show-tools` | `src/prefs.lisp:42,58,217-221` | **SAME** for the persisted value; the reference's Ctrl+T *also* opens the newest payload view (`app.rs:3026-3044`), leticl's does not (`src/editor.lisp:462`) |
| `raw_calls` | `false`; true/yes/on, false/no/off; written unquoted | `prefs.rs:30,67,132-136,151` | `:raw-calls`, same | `src/prefs.lisp:43,58,185-187,243` | **SAME** |
| (none) | — | — | — | — | Neither side persists `verbosity` (`app.rs:4534-4541`, `src/commands.lisp:80-83`), a theme, a width or a mouse setting |

| persistence | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| path | `$XDG_CONFIG_HOME\|$HOME/.config` + `/letibot/head.toml`, else `None` | `prefs.rs:75-81` | …`/leticl/head.toml`, else NIL | `src/prefs.lisp:134-144` | **DIFFERS, by design** (`src/prefs.lisp:15-16`) — a `head.toml` written by one head is not read by the other |
| format | hand-rolled flat TOML, `key = "value"` | `prefs.rs:88-107,145-180` | identical subset | `src/prefs.lisp:157-181,232-281` | **SAME** |
| missing file | defaults, no notes | `prefs.rs:112-114` | defaults, no notes | `src/prefs.lisp:200` | **SAME** |
| malformed line | names the bad value, keeps the default, word-for-word the same sentences | `prefs.rs:120,130,135,137` | same sentences | `src/prefs.lisp:210-211,215-216,220-221,225-226,228-229` | **SAME** |
| **unreadable file** | `read_to_string` Err swallowed → defaults | `prefs.rs:112-114` | `uiop:read-file-string` **unguarded**; the startup caller has no handler | `src/prefs.lisp:200-201`, `src/head.lisp:413-416` | **DIFFERS** — a permission error or a non-UTF-8 byte aborts startup |
| saved when | **only** from the config pane | `app.rs:6541` (sole caller) | from the config pane **and** from every fold key/verb | `src/panes.lisp:320`, `src/prefs.lisp:129` | **DIFFERS — leticl is ahead**, except Ctrl+X does not save (`src/editor.lisp:471-475`), so two of three fold chords persist and one does not |
| save failure | appended to the notice: `" (not saved: …)"` | `app.rs:6413-6423,6541-6545` | swallowed by `ignore-errors`; the note says only `key → value` | `src/panes.lisp:320,505` | **DIFFERS** |
| atomic write | no; plain truncate-in-place | `prefs.rs:179` | no; `:supersede` | `src/prefs.lisp:277-280` | **SAME** |
| non-owned lines | kept in place, owned keys replaced where they sit, header comment on an empty file | `prefs.rs:153-174` | same | `src/prefs.lisp:252-275` | **SAME** |
| load notes | `say`n one at a time, so only the last survives the TTL | `app.rs:6391` | all concatenated with ` · ` into `head-status-note`, but **not through `say`**, so no TTL is started | `src/head.lisp:413-416` | **DIFFERS**; moot while the note row is never drawn (§1.5) |

| config pane can edit | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| rows | 3 sections; `head` rows editable in place; `session` rows editable iff the daemon sent `editable`; `files` rows never | `app.rs:6425-6506` | identical, same order, same labels | `src/panes.lisp:351-395`, `278-280`, `321-324` | **SAME** |
| Enter on a head row | flips, invalidates history, **saves**, says `key → value{saved}` | `app.rs:6521-6548` | flips, marks dirty, saves under `ignore-errors`, says `key → value` | `src/panes.lisp:501-505`, `305-320` | **SAME effect**, minus the save report |
| Enter on `mode` | cycles the **daemon's** choices; with none, `use \`/mode NAME\`` | `app.rs:6562-6577` | same sentence | `src/panes.lisp:508-518` | **SAME** |
| Enter on `supervise` | flips via the slash verb | `app.rs:6578-6583` | same | `src/panes.lisp:519-523` | **SAME** |
| left/right/space | **none on either side** — Enter is the only editor | `grep config_sel app.rs` → no Left/Right/Char arm | none | `grep -n ":left\|:right" src/editor.lisp` → composer only | **SAME** |
| files directory | `prefs_path.parent()` | `app.rs:6488-6491` | hardcoded `letibot/` (it cannot follow its own prefs path any more) | `src/panes.lisp:326-343` | **DIFFERS-trivially** — same directory on a real box |

---

## 3. Lifecycle and the CLI

| phase | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| arg parse | 16 flags; unknown → exit 2 with usage | `bin/letibot-tui.rs:56-123` | 4 forms; unknown → exit 2 with usage | `freeze.lisp:33-78` | **DIFFERS** — see the flag table |
| startup order | **terminal first**, then attach, then a first frame **before any answer** | `bin/letibot-tui.rs:543-590` | connect + prefs + ATTACH first, terminal **last** | `src/head.lisp:402-452` | **DIFFERS-how**; no frame is drawn before the ask |
| the wait | 120 ms recv loop that reads keys and redraws; **30 s deadline** with an explanatory error; **2 s impatient line** | `bin/letibot-tui.rs:611-654`, `:167`, `:174` | keys are live (separate input thread) but there is **no deadline, no impatient line, and the cat never draws** | `src/head.lisp:448-451`; §1.5 | **DIFFERS** |
| first paint | on the first loop pass | `driver.rs:90-91` | on the first dirty pass | `src/head.lisp:379-381` | **SAME** |
| resize | no SIGWINCH; polled per frame; TIOCGWINSZ on **fd 0**; fallback 100×30 | `term.rs:219-229,298-302` | no SIGWINCH; polled per loop pass; TIOCGWINSZ on **fd 1**; fallback 80×24 | `src/head.lisp:269-276`, `src/term.lisp:99-109` | **SAME mechanism**, two byte-level divergences |
| reconnect | **none** — a dead socket exits 1 | `driver.rs:102-108`, `bin/letibot-tui.rs:154-157` | throttled 2 s retry, re-ATTACH with `:since-seq`, reader thread restarted | `src/head.lisp:283-316` | **leticl is ahead** |
| switch session | `switch_to` short-circuits, resumes a stored session, else `Switch`; the head **re-seats** its id | `app.rs:4360-4386`, `app.rs:1571-1573`, `driver.rs:71-73` | same three frames; **no re-seat** | `src/protocol.lisp:160-180`, `src/head.lisp:162-179` | **DIFFERS** — every leticl ack lands under the id `leticl` |
| detach | `client.detach()` on quit and on exit | `driver.rs:198-200` | `make-detach` in the unwind-protect | `src/head.lisp:455` | **SAME** |
| quit | `should_quit`; `StopDaemon` over the protocol | `app.rs:1539-1541`, `driver.rs:205-211` | `head-running`; `make-stop` over the protocol | `src/editor.lisp:173-180`, `src/protocol.lisp:110-116` | **SAME** |
| terminal enter | `ESC[?1049h ?25l ?2004h ?1002h ?1006h ESC[2 q`; isatty on **stdin**; `cfmakeraw`; VMIN=0/VTIME=1; **TCSANOW**; panic hook installed | `term.rs:159-216`, `:188` | **byte-identical sequence**; isatty on **fd 1**; `cfmakeraw`; **TCSADRAIN**; no VMIN/VTIME (a blocking reader thread instead) | `src/term.lisp:76-89,124-128` | **SAME bytes**, different fd and flush mode |
| terminal exit | `ESC[?2026l ?1006l ?1002l ?2004l ESC[0 q ?25h ?1049l` | `term.rs:461` | **byte-identical** | `src/term.lisp:131-135` | **SAME** |
| per-frame sync | `?2026h`/`?2026l` around every written frame; **zero bytes for an unchanged frame** | `term.rs:289-341,444-446` | same sync pair; a dirty-but-identical frame still emits ~20 bytes | `src/cells.lisp:299,339-350` | **DIFFERS-trivially** |
| panic / crash restore | `std::panic::set_hook` restores before the message prints, **plus** `Drop` | `term.rs:191-197,365-369` | `unwind-protect` only; the image is saved with **no** `disable-debugger` and no `*invoke-debugger-hook*` | `src/term.lisp:143-144`, `freeze.lisp:120`, `freeze.lisp:51-55` | **MISSING** — an escaped error lands in the SBCL debugger with the terminal raw and the alt screen up |
| loop order | drain → seat → keys → draw → screen requests → ack | `driver.rs:35-108` | clock → drain → keys → resize → reconnect → draw → ack | `src/head.lisp:332-385` | **SAME**, deliberately (`src/head.lisp:318-330` cites `driver.rs:1`) |

### CLI flags

The launcher `~/bin/letibot` hands the head exactly four flags and keeps the utility
flags on the Rust binary (`~/bin/letibot:44,48,795,855`), so `scripts/leticl-head:31-40`
is the whole adapter. That is why the long MISSING list below is not an equally long
list of breakages.

| flag | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| `--socket PATH` | default `$XDG_RUNTIME_DIR/harnessd.sock` | `bin/letibot-tui.rs:58,77` | no flag; `$LETIBOT_SOCKET`, set by the wrapper | `scripts/leticl-head:34`, `src/socket.lisp:81` | **DIFFERS** — `run` already takes `:socket-path` (`src/head.lisp:398,405`), nothing on the CLI reaches it |
| `--session ID` | attach to that id | `bin/letibot-tui.rs:78,561` | same | `freeze.lisp:62-63`, `src/head.lisp:440` | **SAME** |
| `--resume ID` | `ResumeSession` then `Switch` after Hello — because a daemon refuses an attach to a session it does not hold | `bin/letibot-tui.rs:79,668-670`, `app.rs:1602-1617` | wrapper **rewrites it to `--session`**, i.e. a plain attach | `scripts/leticl-head:36` | **DIFFERS** — `leticl --continue` onto a session that aged out of the daemon behaves differently |
| `--new-session TITLE` | `NewSession(title, cwd)` with the cwd filled in | `driver.rs:143-151` | `--new TITLE`, workspace `""` | `freeze.lisp:65-66`, `src/head.lisp:445-446` | **DIFFERS** |
| `--identity NAME` | `$USER` else `operator`, sent on Attach | `bin/letibot-tui.rs:67,83,564` | dropped by the wrapper; hardcoded `"leticl"` | `scripts/leticl-head:35`, `src/head.lisp:441,303` | **DIFFERS, deliberate** — two leticl heads are indistinguishable in the daemon's head list |
| `--since SEQ` | resume rather than snapshot | `bin/letibot-tui.rs:81,562` | absent; only the reconnect path uses a real seq | `src/head.lisp:302` | **MISSING** |
| `--replay FILE` | render a recorded log, no daemon | `bin/letibot-tui.rs:82,236-332` | absent | — | **MISSING** |
| `--demo` | built-in recorded session | `bin/letibot-tui.rs:93,239-249` | `sbcl --script run.lisp demo` only | `run.lisp:28-29` | **DIFFERS** |
| `--no-tty` | render one frame to stdout and exit | `bin/letibot-tui.rs:94,267-285` | **refuses a non-tty outright** | `src/head.lisp:403-404` | **MISSING**, and actively refused |
| `--probe` | is there a daemon, does it speak this protocol | `bin/letibot-tui.rs:95,176-233` | absent | — | **MISSING** (not on leticl's path) |
| `--interrupt-all [--wait N]` | interrupt every running turn | `bin/letibot-tui.rs:96,419-473` | absent | — | **MISSING** (not on leticl's path) |
| `--list-sessions` | TSV for `letibot --ls` | `bin/letibot-tui.rs:99,359-417` | absent (the frame exists) | `src/protocol.lisp:145-146` | **MISSING** (not on leticl's path) |
| `--body-lines N`, `--reasoning-lines N` | budgets | `bin/letibot-tui.rs:85-92` | absent | — | **MISSING** |
| `-h`/`--help` | usage, exit 2 | `bin/letibot-tui.rs:101,108-115` | `-h`/`help` | `freeze.lisp:33-41,72-74` | **SAME** |
| `LETIBOT_TUI_WRITE_STATS` | frames/silent/bytes/rows/repeats/clears | `term.rs:39,209-211,373-383` | not read | — | **MISSING** |

---

## 4. Instrumentation

| number | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| `seq` / `rendered` | `seq` from the event; `rendered` incremented per `Disposition::Rendered` | `app.rs:1850-1858` | same, via `%handle-frame` returning `:rendered` | `src/head.lisp:361`, `src/panes.lisp:257` | **SAME** — both are since-attach, which is why the captures' `23144` vs `0` is an attach-age artefact, not a defect |
| `filtered` | per `Disposition::Filtered`, shown with the verbosity word | `app.rs:1857`, `app.rs:7714-7718` | same | `src/head.lisp:362`, `src/panes.lisp:259` | **SAME** |
| `dropped` | **accumulated**: `+=` on Hello (`app.rs:1672`) and on Resync (`app.rs:1844`), then `= max(self, snapshot)` in `load` (`app.rs:1937`) | — | **assigned**: from the snapshot (`src/session.lisp:62`) then overwritten from the Hello (`src/session.lisp:91`); the resync arm neither adds nor maxes | `src/head.lisp:205-212` | **DIFFERS** — a leticl resync onto a snapshot with a smaller `dropped` silently loses the earlier count |
| `scrubbed` | `+=` on Hello **and on Resync** | `app.rs:1673,1845` | `incf` on Hello only; the resync path calls `ingest-snapshot`, which does not touch it | `src/session.lisp:89`, `src/head.lisp:205-212` | **DIFFERS** — undercounts after a resync |
| `resync` | `+= 1` | `app.rs:1843` | `incf *resyncs*` | `src/head.lisp:207` | **SAME** |
| `alarmed` | `dropped + scrubbed + resyncs > 0` | `app.rs:7619-7620` | `dropped` and `resync` only — **`scrubbed` is not an alarm** — plus `(not connected)` | `src/chrome.lisp:82-93` | **DIFFERS** — a scrubbed-only head shows no ⚠; a detached head shows a ⚠ the reference would not |
| where the alarm shows | `⚠` on the box's bottom edge; full counters on the unboxed fallback row | `app.rs:5180-5192`, `app.rs:7650-7672` | `⚠` on the bottom edge; the fallback row exists but is never drawn (§1.5) | `src/chrome.lisp:444-445`, `263-283` | **DIFFERS** |
| money meter | `$%.4f` from `spent_micros`, only when `spent_seen`; **reset on a session switch** | `app.rs:6291-6294`, `App::spent_*` `app.rs:984-987` | identical rule and identical reset-on-Hello | `src/chrome.lisp:110-136`, `src/head.lisp:164` | **SAME**; the `$0.5602` vs `$0.0074` in the captures is each head's own since-attach spend, which is the contract |
| context / cache | **live prefill wins while a turn runs** (`turn.progress.total/cache`), else the kept usage, else **the session's own row**; `% cached` refused unless the usage measured its own cache | `app.rs:6274-6301`, and the row at `app.rs:2116-2140` | the same four-step order — live prefill, then `state.usage`, then `turn.usage`, then the brief's `context_tokens`/`context_cached`; the fraction is refused unless the row carried `context_cached` | `src/chrome.lisp:207-300` | **SAME**. The third step is **R8** (below) and the second was G12, both closed |
| tok/s, elapsed, out | printed only when measured | `app.rs:6305-6322` | same rule | `src/chrome.lisp:190-207` | **SAME** |
| session position | `at/total`, shown for one session too, subagents excluded | `app.rs:6213-6221`, `app.rs:1667-1671` | same, via the shared `picker-sessions` filter | `src/chrome.lisp:151-160` | **SAME** |
| model on the header | later of `settings.model` and the turn's model, ranked by seq | `app.rs:6245-6268` | same rule | `src/chrome.lisp:49-73`, `src/session.lisp:187` | **SAME** |
| header gating | drawn only when `h >= 6` and the session id is non-empty | `app.rs:5235` (`header`) | drawn unconditionally | `src/render.lisp:326` | **DIFFERS-trivially** |
| write stats | frames / silent / bytes / rows / repeats / clears behind an env var | `term.rs:373-383` | none | — | **MISSING** |

---

## Gaps worth closing

Ordered by what they cost, not by size.

**G1 — a pane swallows every chord, including Ctrl+C. `S`. `src/editor.lisp:232-324`.**
The pane arm's `case type` has no `:ctrl` branch, so it hits `(t nil)`. Ctrl+C does not
close a pane, Ctrl+D does not quit, Ctrl+L does not repaint, and Ctrl+S from inside the
todos pane cannot reach the picker. The reference handles all of them at the top of
`key` (`app.rs:3016-3160`), ahead of every pane arm, which is also how its chords toggle
panes shut. Note `((:esc :q-press) …)` at `src/editor.lisp:242` references a key type
nothing emits — `grep -rn q-press src/` returns that one line.
*Why it matters:* Ctrl+C is the habitual way out of anything; a pane that does not
answer it reads as a hung head.

**G2 — the head's own notices, the stall line and the scroll/queue counts are never
drawn. `S`. `src/render.lisp:313-318` (+ `src/chrome.lisp:315-336`).**
`status-row` and `alarm-row` are computed `(and … (not boxed))` and `boxed` is
`(>= rows 8)`. 21 write sites of `head-status-note` and every `say` go nowhere.
The reference gives the notice its own chrome row (`app.rs:5069-5073`, `5112-5121`),
the stall another (`app.rs:5054`, `5122-5124`), and both ride the fit ladder.
*Why it matters:* `detached — reconnecting…`, `resync: …`, `bye: …`, `no mode matches
"x"`, `already that mode`, `diff view → unified` — the head is talking and nothing is
listening. This is the single largest behavioural gap in the whole surface.

**G3 — the walking cat never draws. `S`. `src/chrome.lisp:667-668`.**
`attaching-p` requires `(not (head-connected head))`; `run` sets connected `T` at
`src/head.lisp:425` before setting the clock at `:439`, for a reason documented at
`:420-424` that is correct and must not be undone. Drop the `head-connected` clause —
the clock is already `NIL` after Hello (`src/head.lisp:168`), which is the real signal.
Then add the ≥2 s impatient row (`app.rs:6095-6101`, `ATTACH_IMPATIENT` `app.rs:1313`)
and pad the cat **left** (`~vA`, not `~v@A` — `src/chrome.lisp:677` right-justifies,
which makes a 7-wide and an 8-wide frame jitter instead of walk, the exact defect
`app.rs:1322-1332` exists to prevent).
*Why it matters:* attaching to a large session shows a blank screen, which is
indistinguishable from the wrong socket.

**G4 — Enter on a jobs row posts `/job ID` into the conversation. `M`. CLOSED in
`b7a2620`, 2026-09-21 00:00 — and this section said MISSING until 2026-09-22.**
It was measured at `7c2c6fc`, **twenty-three minutes before the fix landed**, and
nothing re-measured it: this line, `keys.md` G20 and `wire.md` W2 went on saying the
Enter sent a slash line, and on 2026-09-22 the driver handed that stale line to the
head as work. **The measurement, live, on a real daemon and a real finished job:
Enter on `j74` drew `job output — j74` and `exited 0 — bytes 0..899 of 899` over the
bytes themselves, with the jobs list still standing behind it, and Enter on `j248`
(a running job that has written nothing) drew `it is running and has written nothing
yet.`** Five of the six tests below fail with the arm put back the way it was
(`%send-slash "job jID"` and `:normal`, the parent commit's arm) — 17 of 36
assertions, two of them erroring outright; the sixth feeds the fold directly rather
than the key, and passes either way. Evidence:
`enter-on-a-jobs-row-reads-its-output-into-a-pane`,
`the-job-output-window-fills-the-overlay-and-it-pages`,
`the-job-output-overlay-scrolls-and-discloses-what-fell-off`,
`a-refused-job-output-read-lands-in-the-pane`,
`a-job-output-window-is-ephemeral-and-never-stored`,
`the-hint-bar-names-the-job-output-overlays-keys`.
The reference removed exactly this on the operator's report quoted verbatim at
`app.rs:3830-3838`; the replacement is the `job_out` overlay (`app.rs:6916-6994`) with
`→`/`←` paging on a `back` stack (`app.rs:6894-6914`), the daemon's byte offsets in the
header, and a refusal rendered **in the pane that asked** (`app.rs:2794-2800`).
*Why it mattered:* reading a build log is what the jobs pane is for, and leticl's Enter
closed the pane and scrolled the log past in chat.

**G5 — the peek pane does not scroll, does not re-read, and does not go back. `S`.
`src/editor.lisp:242-256,275-321,749`.**
`pane-row-count` returns `0` for `:peek`, so Up/Down move nothing; Enter has no `:peek`
arm though the footer promises `Enter re-reads`; Esc goes to `:normal` rather than back
to the tree (`app.rs:3237-3262` does all three). No spill file either — `app.rs:8025-8060`
writes the whole view under the head's runtime dir and names it in the footer.
*Why it matters:* the pane's own last line advertises three keys, two of which do
nothing.

**G6 — the permission card was missing four things. `M`. CLOSED — and the row had gone stale.**
The reference's citations still hold; this head now draws all four:
(a) the **oracle's verdict** — `model says {would}: {basis}`, its citations and `by · N ms`
(`app.rs:7377-7409`), with an explicit *no oracle was consulted for this one* when there is
none, because under `/mode supervised` an absence is evidence too;
(b) the **option ids** — `▸ {label}  ({option_id})`, so the typed path and the ladder name
the same choice;
(c) the **glob hint**, shown only when `allow_always` is on offer;
(d) `ask_without_target` (`app.rs:7865-7874`) — this head trims the target off the summary
and draws it once.
The live card is `permission-card-lines` (`src/panes.lisp:1955-2072`), **not**
`cards.lisp:1138-1193`, which is where this row's citation pointed. **R18, 2026-09-22**:
that same measurement found the card's §1.6 countdown reading 56 years on a session
already holding an ask (`3a9b183`), and found `decision-card-lines` still sitting in
`src/cards.lisp` as a superseded second renderer of this one card — exported, pinned by a
test, and drawing no deadline at all. **Finding, not fixed**: two renderers for one
control is the hazard `src/cards.lisp:1925` names in its own words.

**G7 — the decision ladder is gated on an empty composer. `S`. `src/editor.lisp:326-346`.**
The reference made Up/Down unconditional on the operator's report quoted at
`app.rs:3437-3444` (*"until i press down arrow I wont get into the permissions menu, by
which time my prompt is erased and gone"*); only Enter and the digits keep the guard
(`app.rs:3448-3463`). leticl gates all four, and clamps where the reference wraps.

**G8 — no restore on an unhandled error. `M`. `freeze.lisp:120`.**
`save-lisp-and-die` carries no runtime options, there is no `sb-ext:disable-debugger`
and no `*invoke-debugger-hook*` (`grep -rn "invoke-debugger-hook\|disable-debugger"
freeze.lisp src/` finds prose only). The reference restores inside the panic hook
before anything prints (`term.rs:191-197`) *and* on `Drop` (`term.rs:365-369`), and
`term.rs:8-13` calls this the whole risk. `%render-and-paint`'s guard
(`src/render.lisp:531-561`) covers the common source, not a key handler or a thread
join. `term.lisp` already exports `leave-tui` and `leave-raw`.

**G9 — `--resume` is downgraded to a plain attach. `M`. `scripts/leticl-head:36`,
`freeze.lisp:62-63`.** `letibot --continue` resolves to `--resume ID`; the wrapper
rewrites it to `--session ID`. `app.rs:1602-1610` states why the reference cannot do
that: a daemon refuses an attach to a session it does not currently hold, and "not held
yet" is what resume is for. Both frames already exist
(`make-resume-session`, `src/protocol.lisp:166-169`).

**G10 — no `slash_out` pane. `M`. `src/head.lisp` (the warning arm) + `src/panes.lisp`.**
A slash reply of more than three lines opens a scrollable pane in the reference
(`app.rs:2782-2790`); in leticl every reply scrolls past in the transcript.

**G11 — `dropped`/`scrubbed` lose their history on a resync. `S`.
`src/head.lisp:205-212`, `src/session.lisp:62,91`.** The reference accumulates
(`app.rs:1672-1673,1843-1845,1937`); leticl assigns. And `alarmed-p` omits `scrubbed`
entirely (`src/chrome.lisp:87-89` vs `app.rs:7620`).

**G12 — the header shows the previous turn's context while a turn runs. `S`.
`src/chrome.lisp:170-208`.** The reference prefers `turn.progress.total/cache`
(`app.rs:6274-6281`) — the live prefill — and only falls back to the kept usage.

**G13 — no `o` on a subagent row. `S`. `src/editor.lisp:283-296`.** The pane's own
footer advertises it (`src/panes.lisp:686`); the reference binds it at
`app.rs:3696-3707`.

**G14 — the session picker opens at row 0. `S`. `src/commands.lisp:178-191`,
`src/head.lisp:230`.** The reference opens the cursor on the session you are in
(`app.rs:3080-3087`) so that Enter on an untouched list is a no-op. In leticl, Ctrl+S
then Enter switches you to session #1.

**G15 — no completions row. `S`. `src/chrome.lisp` (a new row) + `src/commands.lisp:21`.**
Tab completes but nothing lists the matches (`app.rs:4342-4358`).

**G16 — config pane: cursor clamps, Enter is not gated, a failed save is silent. `S`.
`src/editor.lisp:234-241,273`, `src/panes.lisp:320,505`.** Against `app.rs:3349-3365`
and `app.rs:6413-6423,6541-6545`. Careful with the cursor: `move-cursor` is shared by
five panes, so wrapping must be per-pane or checked against each pane's reference arm.

**G17 — an unreadable `head.toml` aborts startup. `S`. `src/prefs.lisp:200-201`.**
Wrap the read in `handler-case` and push a note, as `prefs.rs:112-114` does.
Highest value per line in the whole list.

**G18 — no `--no-tty`. `M`. `freeze.lisp` + `src/head.lisp:403-404`.** The head refuses
a pipe outright; the reference renders one frame to stdout (`bin/letibot-tui.rs:267-285`).
This forecloses capture-based comparison in CI and any non-pty screenshot.
`--replay` (`L`) and `--probe`/`--list-sessions`/`--interrupt-all` (`M` each) are the
rest of that family, and none of them are on leticl's daily path.

**G19 — secret card: no countdown, dots in the wrong place. `S`.
`src/cards.lisp:1224-1238`, `src/chrome.lisp:503-537`.** `app.rs:7305-7327` shows
`{N}s left` from `SecretAsk.deadline`, and `app.rs:5343-5348` renders the dots in the
composer box while never measuring the text.

**G20 — one shared pane cursor. `S`/`M`. `src/commands.lisp:178-191`.** The reference
keeps `picker_sel`, `jobs_sel`, `subagents_sel`, `repo_sel`, `config_sel`, `mode_sel`
and `quit_sel` separately; leticl resets one cursor to the top on every open. Documented
as deliberate at `src/commands.lisp:182-186`; the cost is that reopening Ctrl+G does not
remember which subagent you were reading.

**G21 — smaller, real, cheap.** `Ctrl+X` does not persist while Ctrl+R/Ctrl+T do
(`src/editor.lisp:471-475` vs `src/prefs.lisp:129`); no fold announcement after a fold
key (`app.rs:4051-4061`); `:diff`'s absent-value fallback is `"unified"` against a
`"split"` default (`src/cards.lisp:709`); no empty-session opening banner
(`app.rs:6112-6131`); the header is drawn on a 5-row screen where the reference
suppresses it (`src/render.lisp:326`); `--new` sends an empty workspace
(`src/head.lisp:446` vs `driver.rs:147-150`); the identity is hardcoded
(`src/head.lisp:441`); raw mode and TIOCGWINSZ use fd 1 where the reference uses fd 0
(`src/term.lisp:137`, `src/head.lisp:426` vs `term.rs:160,219`); fallback size 80×24 vs
100×30. All `S`.

---

## What would stop the operator switching today

Ranked by how soon it bites in the first hour of daily use.

1. **The head goes silent.** (G2) Every notice the head produces — including
   `detached — reconnecting…` and `resync: …` — is written to a row `%render` does not
   draw on any terminal of 8 rows or more. The first time a socket blips, leticl will
   reconnect correctly and say nothing at all. *Minutes in.*
2. **Ctrl+C does nothing inside a pane.** (G1) Open `/help`, press Ctrl+C by habit,
   nothing happens. Same in every pane, and no chord switches panes either. *Minutes in.*
3. **Attaching to a real session shows a blank screen.** (G3) The cat is unreachable,
   there is no deadline and no impatient line, so a slow snapshot looks like a broken
   head. *First attach to a big session.*
4. **Ctrl+S, Enter moves you off your session.** (G14) The picker opens at row 0 instead
   of on the session you are in. *First time you look at the session list.*
5. **Enter on a jobs row dumps a build log into the chat.** (G4) The pane closes and the
   output scrolls past — the exact complaint the reference fixed. *First background job.*
6. **The permission card hides the model's verdict and the option ids.** (G6) Under
   `/mode supervised` the whole point is to agree or disagree with the model, and the
   model's answer is not on the card. *First supervised permission.*
7. **A permission that arrives mid-typing costs you the typed line.** (G7) The arrows
   do not reach the ladder until the composer is empty. *First permission while typing.*
8. **`leticl --continue` may not find a session letibot would have resumed.** (G9)
   *First continue onto an aged-out session.*
9. **The peek pane advertises three keys and honours one.** (G5) *First subagent read.*
10. **A crash leaves the terminal raw.** (G8) Low frequency, high cost: an unusable
    shell, requiring `reset`. *Whenever it happens.*
11. ~~**The header's context number is stale while a turn runs.**~~ (G12) **CLOSED** —
    the live prefill path (`turn.progress`) won the header, as the reference's
    `header_line` has it. See R8 below for the other half of the same screen: the
    number was also *absent* whenever the head had not seen a turn itself.
12. **A slash listing scrolls past instead of opening a pane.** (G10) *First `/gate
    recent`, `/tools` or `/models`.*

Everything else on the gap list is real and none of it would stop a switch.

### R10 — a note is a DISCLOSURE, not a permanent record

**DONE.** Below is the measurement that found the defect, then the shape of the fix.

The operator, looking at letibot's 27 red lines: *"how do I remove them"*. There the
answer was *you cannot* — no dismiss key, no verbosity level that hides a warning even
though the `Warning` type's own doc claims `loud` adds them, and a resync or a reattach
REPLANTED the wall at position 0, because a snapshot's warnings are unanchored history.

**MEASURED on this head before it was fixed, and the answer was the opposite defect.**

| | `head-status-note` | `session-warnings` | specialised arms |
|---|---|---|---|
| what it is for | the head's own `say`s | everything the daemon warns about | `turn_failed`, `job_output_refused`, `slash`/`slash_refused`, `secret_late` |
| **was it drawn?** | yes, magenta above the composer | **NO — nothing read it** | yes, by the arm |
| **lifetime** | was `*notice-ttl-frames*` = 60 loop passes ≈ **1.6 s** (measured 60 → 31 after 0.3 s, NIL by 0.8 s, both from the shell; the loop is ~38-43 passes/s). **Now a millisecond deadline on the head** — `+notice-ttl-ms+` 1600, the same wall time, a unit that does not depend on the frame rate (`57d20dc`) | accumulated for the life of the session | — |
| **dismiss key** | **none** — and not "any key" either: `%handle-key` has no notice arm at all, where the reference drops `notice_ttl` to 1 on every key but the four scroll keys (`app.rs:3080`) | N/A | esc, by the arm |
| **verbosity hid it?** | no | no (and nothing was drawn to hide) | no |
| **a RESYNC did** | **replace** it — a snapshot's `resync` note overwrote the one that was up | **replace** the list with the snapshot's (measured: 3 live → 2 from the snapshot) | — |
| **a HELLO (reattach) did** | **clear** it | **replace** the list (measured: 2 → 3 from the snapshot) | — |

**And the decisive measurement:** a `warning` envelope handed to the live head —

    warnings before 9 · after 10 · note NIL · on-screen NIL · detail-on-screen NIL
    alarmed-p → (("dropped" . 358324) ("scrubbed" . 1) ("resync" . 1))

— was **stored and appeared nowhere**. Not a row, not a note, not a counter, and not on the
alarm, which was truthy only for the three counters it already had. So the operator's 27
red lines were **not this head's symptom**: mine drew zero of them. **That is worse, not
better, and it is the same defect from the other side.** A disclosure that does not happen
cannot be dismissed, and the rule this document keeps hearing — `event.rs:772-791`, *"a
denial the operator cannot see manufactures the workaround"* — applied to every warning
with no specialised arm: `auto_compact`, `compacted`, `context_wall`, `transcript_store`,
`decision_corpus`, `mode_set`, and whatever the daemon adds next.

#### What landed, and why each half is where it is

1. **DRAWN where it arrived.** A `Warning` is filed as a row of this head's own, the
   `note-unreadable` shape — an item scrolled away with the conversation rather than a
   status note that expires on a TTL and takes the fact with it. `src/session.lisp`
   `note-warning`; the row's renderer is `src/cards.lisp`'s `:note` arm.
2. **FOLDED, because the wall is the complaint.** A warning with more than `+note-lines+`
   (3) lines shows three and a dim `  … +N lines · /notes` seam — the reference's
   `NOTE_LINES` and its instrument. The whole text stays in `session-warnings`, so this
   folds a disclosure and never the record.
3. **RETIRED, keyed outside the transcript.** `session-retired` holds the warning's own
   `(code detail ts)` identity, which a snapshot does **not** carry — so a resync and a
   reattach replant the wall **retired**, which is exactly what the two events used to
   undo. The row is still an item and still in the list; only its rendering is withheld,
   so *"retired is not deleted"* is a property of the data and not of the code path.
   `src/session.lisp` `retire-warning` / `restore-warnings` / `%reflag-warning-rows`.
4. **COUNTED as `N of M`.** `/status`'s `notes` row reads how many are retired against how
   many are held, computed from the warnings rather than kept as a counter
   (`src/panes.lisp:261-269`), so a dismissal is counted rather than a disappearance.
5. **THE READER** is the reference's grammar, kept verbatim so the two heads take the same
   sentence: `/notes`, `/notes dismiss N`, `/notes dismiss all`, `/dismiss`,
   `/notes restore` (`src/commands.lisp:204-268`). The listing is a **slash listing** —
   the pane this head already has for a verb's answer, `*slash-out*` + `:slash` — which is
   why there is no fourth hand-rolled pane here.
6. **The four specialised homes are kept**, and the reason each is *not* a plain row is
   written where it is taken: `turn_failed` → the turn's own footer (FILTERED, and filtered
   out of a snapshot's notes too, `app.rs:3320-3330`/`2527-2534`); `job_output_refused` →
   the pane that asked **and** the row; `slash`/`slash_refused` → the listing pane when long
   enough to be one; `secret_late` → the row, which is the only place left to say a
   password was not used once the card that asked is gone (`wire.md` W14).

**A deliberate divergence, named.** The reference anchors a snapshot's notes at position
**0** (`app.rs:2530-2534`) because they are unanchored history; this head **appends** them,
so a resync's replanted warnings land as the newest disclosure rather than above the whole
conversation. Both are honest about the fact that the head cannot recover the historical
position; append is what `file-head-note` already does and keeps one shape for "a row this
head wrote".

**And one thing R10 did NOT take.** The retired set lives in memory for the life of the
process. `app.rs:886` persists it to `head.toml` (a `note_key` hash, `RETIRED_CAP` 512),
which is what makes a retirement survive a **restart**; this head's set survives a resync
and a reattach, which are the two events the operator named, and adds no head.toml key for
long detail strings until it is asked for.

**The other half, still open and still worth taking**: `head-status-note` has no dismiss
key *and* a 0.55 s life, where the reference acknowledges its notice on any key but the
four scroll keys (`app.rs:3080`). A note a keystroke can retire and a note that expires
before it can be read are the same bug in two directions.

#### And then the field found the third thing: the note outlived its own clock

The operator, on a magenta `· permission answered` that would not go: frozen above the
composer while a turn streamed underneath it. Measured through the eval socket —

    :note "permission answered"  :ttl 0  :dirty NIL     <- identical 2 s later

— a note with **no clock**, on a head whose loop was painting the whole time. The
countdown was guarded on `(plusp ttl)` and left at 0 by every one of the **seventeen
call sites that set `head-status-note` directly** rather than through `say`; a note with
no clock was therefore IMMORTAL, and the guard that made it so was written as a feature
("an alarm persists"). Two lessons, and they are the same one twice:

  · **a TTL counted in FRAMES is a timer that stops when the frames stop** — which is
    exactly when a notice is left standing longest; and
  · **a clock that does not live with the thing it times is not that thing's clock.**
    The deadline is now a slot of the head (`head-notice-until`), so no `let` of a
    global — and this tree rebinds its globals wholesale for every replay — can give
    one of them a private copy. Same class as `*hist-generation*` and the prefs write
    switch, and the third time it has cost this repo a real defect.

**Handed to letibot, not changed there**: `app.rs:5954` decrements `notice_ttl` inside
its chrome builder and clears at 0, armed at 60 by `say` (`app.rs:5431`) — the same
frame-counted shape, one layer down. Its `notice_ttl` is a field of the `App`, so it
does not have the second defect, but on a quiet screen its count does not advance.

**The measurement bias this requirement nearly shipped, recorded here because it is the
first real cost of live-eval anybody here has named.** The TTL figures above were first
taken the wrong way: a probe that ran 60 s of `sleep` **inside one `tui-eval` eval** held
the head's paint lock for the whole eval and starved the loop it was measuring, so the tick
counter froze and the TTL read 60→59 — implying one loop pass a minute. Re-measured with
the sleep in the **shell between short evals**, it is 43 passes/s and 60→31 in 0.3 s, which
is the number in the table. **A measurement that takes time starves what it measures, and a
constant derived from it carries the bias silently.** See `HACKING.md` and
`scripts/tui-eval`.

### §1.6 — the gate card says what silence will do, and how long there is

**MISSING IN BOTH HEADS, and this head is now the reference for both** (`letibot` was
blocked on an operator card, so there was nothing to take an argument from). The
operator was bitten the same night: *"two gate cards timed out unanswered at 300
seconds with `not_run by gate:timeout` — nothing on the card had said that was
coming."* Both heads carried the two fields (`deadline`, `on_timeout`,
`event.rs:569-574`) and drew neither, while **both drew a countdown on the SECRET
card** — the instrument existed in both trees and was never pointed at the gate,
where the consequence of silence is a decision rather than a missing password.

#### First, a defect found by measuring the instrument that already existed

`SecretRequested.deadline` is *"Unix millis"* (`event.rs:746`) and this head's clock
is `internal-real-time-ms` — SBCL's counter since process start — so the secret card's
countdown was subtracting a Unix instant from a monotonic counter. Measured:

    monotonic now : 105 ms
    unix now      : 1790030450000 ms

The card drew the difference, so its countdown read a number in the hundreds of
thousands of seconds: **R13's two-clocks trap in a second place, and the one it had
been living with since the countdown was written.** The conversion now happens where
the frame ARRIVES (`wire-deadline->monotonic`, R13's *anchor on arrival* — the one
moment the two readings describe the same thing, and the two clocks differ by a
constant measured once), so the card subtracts two readings of one clock.

#### The three rulings letibot should build from

**1. A SHORT deadline and a LONG one — a ladder, not a number.** *"A countdown that
ticks for five minutes is furniture and one that ticks for ten seconds is a pressure
the operator did not ask for"*. Both are avoided by changing the UNIT with the
remaining time, measured on the glass with a real 300 s budget:

| left | the card | |
|---|---|---|
| 300 s → 240 s | `expires in 5 min` | whole minutes, and it changes once a minute |
| 181 s | `expires in 4 min` | **rounded UP**: never claim less time than there is |
| 120 s | `expires in 2 min` | |
| 119 s | `1m59s left` | from here it counts in seconds, where the number is acted on |
| 59 s | `59s left` | whole seconds under a minute — `47s`, never `47.0s` |
| 47 s | `47s left` | the spelling the secret card already used, and the reference's |
| 0 s | `0s left` | |

The daemon's own `ANSWER_BUDGET` is 300 s (`harnessd/src/answers.rs:66`), so at the
real value the card reads whole minutes for its first three and seconds for its last
two. **And the ladder is why the repaint is affordable**: a countdown says whole
seconds at the finest, so an ask waiting on its own clock asks for ONE frame a second
(`live-frame-interval-ms`, `+live-frame-coarse-ms+`), not the ten a spinner needs.

**2. A card that has ALREADY timed out — the case the operator actually hit.**

    past its deadline by 14s; the daemon has not said what became of it · if nobody answers, it RUNS anyway

A card still on the screen after its own deadline is one whose answer the daemon has
already settled, and the head has not been told which way. What it must NOT do is keep
counting into negative seconds — that is a number that means nothing and reads as a
rendering fault — and what it must say is that the clock ran out and the outcome is
unreported. The consequence clause stays, because it is a RULE rather than an
observation: an operator looking at an expired card with `on_timeout: allow` learns
the thing they most need to from it.

**3. NO deadline — draw nothing.** `deadline: null` is §11.5's *"wait forever"*
(`event.rs:571-573`): a policy, not missing information, so an ask that cannot expire
says nothing about time. This is the §13.2b present-and-zero question answered in the
other direction, and deliberately — `unreadable 0` on `/status` IS shown at zero,
because a head that does not count frames it cannot read is a different head, while a
countdown on an ask with no deadline is a number nobody took. `permission.jsonl` is
this case (`"deadline": null`), so the fixture's golden is unchanged.

#### What silence does, in the daemon's own three words

    deny  → if nobody answers, nothing runs
    allow → if nobody answers, it RUNS anyway
    ask   → if nobody answers, the guard model decides

Drawn on every card that has a deadline, dim, **below the options** — the order a
person reads is the question, then the choices, then what happens if they do nothing.
The upper case on `RUNS` is deliberate: it is the only one of the three that does
something nobody asked for, and an operator who walked away believing the default was
`deny` when it was `allow` has been told nothing by a clock. A word this head does not
know draws no clause rather than a guess — the same rule the unreadable-frame path
keeps, because a wrong consequence is worse than an absent one.

### §2.6 — a fence's first word names the grammar, and `console` is not one

**DONE**, and it brings a **ruling letibot should follow** — the one CONFLICT in the
item.

#### The rule, and why this head's table was the wrong table

*A fence info string resolves to a grammar by its FIRST WORD, case-insensitively,
ignoring trailing attributes.* letibot gets this from
`rano::syntax::Lang::from_token` (`crates/tui/src/render.rs:217`), so for the two heads
to agree this head has to answer the same token the same way.

What it had was the **extension** table (`fence.{ext}` dressed as a filename) with no
comma or whitespace splitting, so every info string carrying anything after the
language fell through to plain. Measured, `fence-token` before and after:

| info string | before | after |
|---|---|---|
| `rust` | rust | rust |
| `RUST` | rust | rust |
| `rust,ignore` | **plain** | rust |
| `python title="x"` | **plain** | python |
| `rust title="y" ignore` | **plain** | rust |

and of the doc's list of colours-here-plain-there, every one now resolves:

    tsx lua php make makefile dockerfile ini cfg conf diff patch
    scheme scm rkt clojure clj edn golang python3 mjs jsx xml svg htm gfm psql

**Resolution is by TOKEN, not by extension**, and the difference is not cosmetic —
`mk` IS Make as a path extension (`detect`, `syntax.rs:646`) and is NOTHING as a token,
which `from_token` says twice (it is absent, and `make`/`makefile` map to Make). A fence
carries a name, so the token table is the one that applies.

**Only grammars this build HAS are in the table**, and that is a rule rather than a
shortcut: the painter's 27 grammars (`native/hl/src/lib.rs:32-60`) reach the token table
through a representative extension, so a grammar this build lacks resolves to nothing
and the fence renders plain. **A row claiming a language the painter cannot draw is
worse than an honest miss**, because the box header names the grammar that ran. `xml`
and `svg` map to the HTML grammar — there is no XML lexer, and `from_token` maps them
the same way — and a language with no grammar at all is simply not in the list.

Live, rendering rather than resolving:

    fence rust,ignore        resolved=rust        5 distinct roles on the line
    fence python title="x"   resolved=python      4
    fence makefile           resolved=make        2
    fence psql               resolved=sql         2
    fence xml                resolved=html        1
    fence console            resolved=NIL         0
    fence text               resolved=NIL         0

#### RULED: `console` is not a language. Plain, in both heads.

This head coloured `console` as bash; letibot returns `None` deliberately, calling it
*the archetypal unknown* (`rano/src/syntax.rs:93-96`). Four reasons, in the order they
weigh, and the first is the one that decides it:

1. **A console transcript is not a language.** `console` is a convention (Pygments,
   Chroma) for a terminal SESSION: a prompt, a command, then the command's OUTPUT. What
   a bash grammar would colour is mostly output, and output is not bash — so the painter
   **invents structure the bytes do not have**, which is the rule this file already
   keeps three lines above `highlight-fence`: *a wrong colour is worse than none*.
2. **The invented structure HIDES things.** A `#` that opens a comment — a shebang, a
   glob, a `#` inside a path — greys out the rest of the line, and in a transcript the
   rest of the line is often THE OUTPUT, which is the one thing the fence is being read
   for. A quote in output opens a string that never closes. `if`, `do` and `in` appear in
   output as prose and would take keyword colour.
3. **The painter owns the vocabulary.** `from_token` is one function, in one crate, with
   one caller, and it answers `None` because there is no ShellSession grammar to point
   at. A head that answers differently keeps a private dialect of a shared table, which
   is the drift this task exists to end.
4. **There is no other way for the two to agree.** letibot colours by calling
   `from_token`; agreeing means answering what it answers. Keeping `bash` here means
   permanent divergence on a token, or changing letibot's shared table to suit one head.

What would change the ruling is a **real ShellSession grammar** — one that knows a prompt
from output. Then `console` is a language and colouring it is honest. That is a painter
change, not a head change.

### §3.3 — `truncate-target` must agree

**DONE**, both halves, and the first half is a **ruling for letibot** as well.

**The cap is 120 COLUMNS, and one column of it is spent on the mark.** The two heads
agreed on 120 and disagreed about what of: the reference counts BYTES (`s.len()`,
`is_char_boundary`, `event.rs:428-439`) and this head counted CHARACTERS — wrong in
opposite directions for anything not ASCII, measured on the same input:

| target | reference | this head, before |
|---|---|---|
| 121 ASCII characters | 117 + mark, **118 columns** | 117 + mark, the same |
| 61 CJK characters (122 columns) | 39 + mark, 79 columns | **all 61, 122 columns**, untruncated |
| 61 emoji (122 columns) | 39 + mark, 79 columns | **all 61, 122 columns** |
| a target carrying `0x9B` | **stripped** | **kept** — the two measured it differently |

**Counting characters lets a wide target EXCEED the budget** — 61 CJK characters are 122
columns — which is the exact failure the cap exists to prevent, and the one this tree
spent `W1` learning about rendering; counting bytes under-fills it by a factor of two.
The reference's own comment states the intent it is failing (*"that puts a status line
one column past the terminal and scrolls the frame"*): what it wants is the room the row
has, which is columns. So the ruling is **both heads count columns**, and the reference
should move — its two-column shortfall on ASCII is the smaller half of the same bug.

**And the strip class is C0 + DEL + C1.** C1 was missing here: `0x9B` is 8-bit CSI, the
reference strips it (Rust's `char::is_control` covers `U+0080`–`U+009F`,
`event.rs:426`) and this head's `(char< c #\space)` covered only C0 with `127` for DEL.
It does not reach the terminal — width 0, dropped by the painter — but a string carrying
one truncates to a DIFFERENT ANSWER in the two heads, and two heads that disagree about
how wide a label is place the same row differently.

After, every case at or under the budget:

    121 a                       in 121 cols -> out 120 cols (mark at 119)
    61 CJK                      in 122 cols -> out 119 cols
    61 emoji                    in 122 cols -> out 119 cols
    60 CJK (exactly 120 cols)   in 120 cols -> out 120 cols, untouched

### §3.2's third candidate — FOUND, and it is not the sync pair

**The record said *we do not know*:** the `unwind-protect` at `6ab9204` was *"incidental
but defensible. NOT the confirmed fix"*, `ed92b64` explained slowness and not recovery,
`b12daf5` touched nothing here, and a head died once with no cause established. The
operator's symptom stayed live on both heads: *"scroll doesnt work on tool and thinking
expansions … only switching byobu windows fix scroll."*

#### First, the sync pair is RULED OUT — three measurements, not an argument

`6ab9204`'s reasoning was: sync left open suspends every update, so the screen freezes
and a tmux window switch restores it. Three things say no:

1. **tmux does not advertise `Sync`.** `infocmp -1 tmux-256color` has no `Sync` and no
   `?2026`; the operator's panes run under it (`default-terminal` is `tmux-256color`).
2. **The pair is balanced in every frame this head writes.** `tmux pipe-pane -O` gives
   the exact byte stream: 28 `?2026h` and 28 `?2026l` across a run of real gestures, and
   6/6 on the deliberately-failing run below.
3. **The protect works**: driven with a paint that dies at its first style change, the
   close still lands, exactly once.

And two more mechanisms the operator asked me to chase were ruled out by measurement:
**copy mode** survives a window switch (`pane_in_mode=1` before and after), and a window
switch changes **no** terminal mode (`alt`, `mouse_*`, `sgr`, `bracket_paste` identical
either side). So the switch helps by REDRAWING — which meant asking what a redraw
repairs that a repaint does not.

#### The instrument, and the divergence it found

`tmux capture-pane` reads tmux's MODEL, and the eval socket's liveness probe **pokes
`head-dirty`** — so a probe that watches the screen keeps it fresh (HACKING.md). Neither
can see a divergence, so the hunt used a third thing: **the head's `head-prev-screen`
against tmux's model**, the belief against the reality, with the belief read as CELLS
rather than through `screen-rows-ansi` (which calls `%sgr`, the very function a paint can
die in — a probe that fails from inside itself, measured).

Then a paint was injected to die *after* `ESC[2J`, which is what a failure inside
`paint-diff` does. The byte stream, captured with `tmux pipe-pane -O`:

```
ESC[?2026h ESC[0m ESC[28;7H ESC[?25h ESC[?2026l   <- a normal caret-only frame
ESC[2J                                            <- the FAILURE paint's clear
ESC[?2026h ESC[1;3H ESC[0m ESC[?2026l             <- and then it died: 8 bytes
```

and the comparison:

    head believes 30 rows, the terminal shows 0: DIVERGE on 30 row(s)
      row 1  HEAD | render failed — the head is alive; fix and re-push|
             TTY  |<none>|

**`ESC[2J` had landed and nothing else had.** `%paint-failure` swallowed the rest with
`ignore-errors`, and then recorded `head-prev-screen := head-screen` — the frame it
*intended* — which is an assertion about the terminal it was in no position to make.
Every later paint is a DIFF against that record, and a cell where the record and the new
frame AGREE is a cell nothing is ever written to again. **So the record is not stale, it
is a permanent hole, and nothing in the head can repair it** — which is exactly what
*"even after collapsing back"* means.

#### Why ONLY a byobu window switch fixes it — the last link

`screen-resize` allocates a **fresh cell vector** (`cells.lisp:176`). A resize is
therefore the one operation that discards whatever poisoned the frame and re-derives
both screens — and it sets `head-full-repaint`, so the very next paint clears and redraws
everything. Nothing else in the head does either: every other path re-uses the cells.

That is also why the failure clears when the trigger is undone and not when the content
is: the poison is in the CELLS or in the TABLES, not in the transcript.

#### The fix, two halves

1. **`%sgr` is bounds-checked** (`cells.lisp:149`). `*styles*` and `*style-sgrs*` are
   parallel by construction, and a live push that redefines the style vocabulary rebuilds
   them under cells written with the OLD numbering — the recorded `df9bd3f` incident,
   where *"the next paint died on `%sgr`'s `aref`"*. A wrong index is a fact about a
   CELL, so it now costs that cell's colour and never the frame: the cell draws as style
   0. Measured, with every cell in the frame poisoned: **the head paints and the terminal
   agrees.** The old regression test arranged its signal exactly this way, which is why
   that test now drives a `nil` cell instead — a test that cannot fail guards nothing.
2. **A failed paint forces the next one to be FULL** (`render.lisp`). `head-prev-screen`
   is the head's only record of the terminal, so a paint that did not complete must not
   be allowed to leave a record behind it: the failure path now records only when the
   failure frame got out, and sets `head-full-repaint` either way. This is the half that
   covers a poison nobody has thought of — recovery no longer depends on the next frame
   happening to differ, which is the coincidence the symptom consisted of and which a
   window switch supplied instead. Measured on the wire after the fix: every paint that
   follows a failure is a full one (`ESC[2J` + the whole frame), so the moment the
   painter works again the screen is redrawn from nothing. Ends AGREE.

**What I did NOT establish, said plainly.** I could not construct a NATURAL
out-of-range style tonight: `rebuild-style-sgrs` keeps the tables parallel (measured:
4 entries, 4 sgrs, and the frame's highest cell style is 3), so it takes a push that
shortens the vocabulary — which is what the recorded incident was and what my own old
test did by hand. And the general defence is deliberately blind to the poison: it does
not need to know what went wrong, only that a paint did not finish.

### FetchRow — the rows above this head's window

**The disclosure is DONE and the capability is built; the daemon half is not, and the
measurement says so.** This is the last item of §10 and the only wire capability in the
tree that nothing used.

#### The defect that is real, and it is R17's rule one layer out

`ViewBounds` bounds a snapshot by count and by bytes — 2,000 rows or 8 MB of row text,
whichever comes first (`view.rs:308-347`) — so a head on a long session holds the
**newest** slice of the conversation, and `items_dropped` says how many rows came before
it. That number was **stored and read by nothing**: no seam, no counter, no `/status`
row. Scroll to the top of such a session and the transcript ends as cleanly as a session
whose first row that is. **Two different facts, one appearance** — which is the shape
R17 spent a commit on for body-less rows.

Now, on the glass, in three states (measured on a scratch head with `items_dropped`
set, which is the state a long session puts the head in and which no small session can
produce):

    … 5 rows above · scroll to this line to load the next
    … 5 rows above · asking the daemon for row 4…
    … 5 rows above · the daemon does not hold them any more

The third is the one that matters: it stops promising a fetch that cannot happen.

#### WHEN a head fetches: on demand, triggered by reaching the top

The requirement asks this explicitly, and the numbers decide it. **Eagerly filling the
gap would fetch exactly what `ViewBounds` just refused to put in the snapshot** —
thousands of rows, over a socket that already costs the daemon a clone per attaching
head — for an operator looking at the newest end of the conversation. The rows are
wanted at exactly one moment: the reader has reached the oldest line they have.

So the trigger is that moment, and it is the KEY loop that sends rather than the
renderer (`editor.lisp`'s scroll arms): `*scroll-max*` is what the render last clamped
the scroll to — the only thing in the tree that knows the transcript's line count — so
`(>= scroll max)` before the increment means *the reader was already at the top and has
asked to go further*. A render with a socket side effect is a render that behaves
differently on a second paint.

Three refusals, each a fact rather than a guard: nothing above, a request already in
flight (a transcript has one top — this is what stops a wheel that keeps turning from
sending a request per tick), and the daemon having already said those rows are gone.
Measured on a fully-held session: **ten scrolls past the top sent nothing, recorded
nothing, drew no seam.**

#### What a fetched row LOOKS like

A row of its own kind, `:fetched`, because the frame is all the head has: `RowFetched`
carries a body and an ordinal and **no kind, name or timestamp** — so drawing it as a
tool card or as prose would be inventing facts about a row this head has never seen.
What it CAN say is where the row sits in the session and what its body is:

    ▸ row 4999 of the session
      812 lines
      … the body …
      … +772 lines · +391204 bytes

The byte count comes from the frame's `total`, which is the WHOLE body's length, so the
seam counts what the window did not carry rather than guessing from the lines that
arrived.

#### The measurement that settles the capability: it cannot answer, today

**`FetchRow` can never return a row the head does not already have.** The snapshot is
`view.items.clone()` (`view.rs:821`) and `row_body_at` reads the same `self.items`
(`view.rs:745-747`) — **one view, one bound** — so: an ordinal the snapshot trimmed
answers `null`; an ordinal the snapshot carried is a row the head already holds; and a
row held without a body answers `null` too. The frame's own test says the same from the
other side: *"the store read that would answer it is R19.2(b) in `letibot`'s TODO"*.

So the three answers the head folds are honest and one of them is currently
unreachable. The head's half is built anyway, because **it cannot know which of those
worlds it is in without asking** — the seam cannot be true without it — and because the
day the store read lands, the head already asks. The wire was pinned against a real
daemon rather than against the plist this head expects:

    asking:            {"frame": "fetch_row", "session_id": "s-…", "row": 99999, …}
    <-                 {"frame":"row_fetched","session_id":"s-…","row":99999,"at":0,"body":null,"total":0}
    (unknown session)  <- {"frame":"rejected","reason":"no such session \"s-not-here\""}

and the loop end to end on a scratch head: the seam offered, the scroll asked, the
daemon answered `null`, the head marked the rows gone and the seam said so, **with
nothing prepended and the count unmoved** — `body: null` is not an empty row.

**Not established live:** the `Some` path. Making a real daemon hold a row needs either
a turn (metered here) or the operator's own store, and neither is mine to spend — the
unit test covers the prepend, and the live run covers the wire and the refusal.

### §3.1 — content this head did not author cannot drive the terminal

**PROVEN, not patched.** The section's claim is *control characters in anything the head
did not write are neutralised before they reach the tty*, and the finding here is that
**this head does it with one invariant rather than a list of sanitised call sites** —
which is the sentence letibot needs, because it says what to build toward instead of
which four places to patch.

#### The measurement

Each source the section names, carrying each real byte (an SGR pair, `?1002`, `?1006`,
`?1049`, `?2004`, `?2026`, an OSC title, `[2J`, `[8m`, `0x9B`, `0x9C`, DEL), through the
real pipeline and out through `--replay --no-tty`, which writes `screen-rows-ansi` —
the same function that answers `ScreenRequested` and that `/cells` sends:

| the payload the model wrote | what reached the tty |
|---|---|
| `ESC[?1002h mouse on` | `mouse on` |
| `ESC[?2004h paste on` | `paste on` |
| `ESC[?1049h alt screen` | `alt screen` |
| `ESC[?2026h sync on` | `sync on` |
| `ESC]0;pwned BEL` | *(nothing)* |
| `ESC[31mredESC[0m` | `red` |
| `0x9B[31m 8-bit CSI` | `[31m 8-bit CSI` |
| `a DEL b` | `ab DEL` |

**Not one ESC-prefixed sequence reached stdout**, and the frame is not vacuous — it
carries 103 of the head's OWN escapes, which is the contrast that makes the count mean
something. Two shapes are worth naming: an **ESC run is consumed whole** (`?1002h`
vanishes with its introducer, because `%skip-escape` walks the sequence to its final
byte), while a **C1 or DEL is dropped alone** and its following text stays — harmless
either way, and `ESC[?1049h` is the one that would have switched the operator's screen.

#### Where the guarantee lives, and why it is one invariant and not six patches

Nothing sanitises the model's prose, its reasoning, the user's own message, the system
row, a fence body or a diff excerpt read off disk — **and the test asserts that**, so a
reader knows the safety is at the painter rather than at the source. Four facts, and
together they close the path:

1. **The frame is a CELL GRID**, and every cell is written by `screen-put-string`
   (`cells.lisp:210`), which walks **clusters** and **skips any cluster of zero
   columns** (`cells.lisp:243-248`, the `(or (zerop w) (zerop (length text)))` arm).
2. **A control character measures zero columns** — `%c1-control-p` covers C0, C1 and
   DEL (`width.lisp:136-139`) and the width table is derived from it
   (`width.lisp:144-150`).
3. **So a control character cannot reach a cell**, whatever the caller does: the
   painter is not *choosing* not to write it, it has no cell to write it into. The
   guarantee is `zero columns ⇒ unwritable`, not `six call sites sanitise`.
4. **The one-character fast path is not a hole either**: `plain-columns-p` refuses any
   string containing `+esc+` (`width.lisp:421`), so a string with an escape in it takes
   the cluster walk, where (1) applies.

This is why the sanitising this head already has — `%without-control`, on the tool
payload and the job pane — is **belt-and-braces rather than the rule**, and why adding
it to the other four sources would have been work that does nothing. Which is worth
saying plainly, because the section's *resolution for phase 1* is *sanitise the
remaining sources in both*, and for this head the honest answer is that the remaining
sources are already safe and the sanitising would be a no-op.

**It is still a backstop rather than a contract**, which is the caveat the section
raises and this measurement does not remove: it would not survive a change of painter.
So the two tests are written at the two layers — the pipeline (every source, no
sequence on the frame) and the mechanism (`%code-width`, `plain-columns-p`,
`screen-put-string`) — and a painter that stopped skipping zero-width clusters would
fail the second one rather than the first.

#### What letibot needs, since its painter is different

Its `paint_full` writes ANSI-bearing strings verbatim (`term.rs:441`), so an escape in
model prose reaches its terminal and this is a real exposure there, not a confirmation.
The property to build toward is the one stated above — **a control character must not
be storable in a cell** — whether the cells hold a string or a `(char, style)` pair. A
sanitiser on each source is the other shape, and it is strictly worse: it has to be
remembered at seven sites, and the eighth is the one that leaks.

### §6 — the last of the B-side list

Eight items, and each was a chord, a verb or a row that existed on the other head and
did not exist here. All are now `SAME`, and two found something while being written.

**`ctrl-x` on a SETTLED row.** The reference draws the raw call in two places
(`app.rs:7061-7062` live, `:11055-11061` settled); this head drew only the live turn's,
so the pref did nothing on a transcript — every row but the one being written. The two
are different TEXT for the same fact (a live turn shows the `<function=…>` markup the
model wrote; a settled row's markup is gone, so it shows the name and the arguments the
parser read) and they now share one renderer, `raw-call-lines`, which is the labelled
faint block `┌─ raw tool call · ctrl-x` / `│ …` / `└─`.

**The attach deadline.** `ATTACH_WAIT` is 30 s and its failure names `letibot --status`
and `letibot --stop` (`bin/letibot-tui.rs:167, 611-652`). This head waited FOREVER,
with a two-second line that said `ctrl-c twice, or wait` and nothing about the daemon
being hung. The distinction the sentence draws is the point of it: **a daemon that
accepted the connection and sent no `Hello` is a HUNG daemon, not an absent one** —
absent means start one, hung means find out why — and the two commands that reach it
are not on any screen the head can draw, because the head is the thing that is stuck.
Ctrl-C still works during the wait, which the hint bar has promised since before there
was a frame.

**A row labelled `on disk` is resumed, not switched to.** `switch_to`
(`app.rs:5098-5150`) sends `ResumeSession` when the row is stored and not live, and the
head sends the switch itself when the daemon answers. This sent `switch`
unconditionally — measured before the fix: the picker listed the stored session, the
row said `on disk`, Enter sent `{"frame":"switch","session_id":"s-2"}`, and nothing
happened, because the daemon had nothing under that id. And picking the session you are
already in now says `already here` rather than looking identical to a silent failure.

**`/switch` resolves what the picker resolves.** The reference calls one `pick()`
(`app.rs:4806-4855`) from both its `/switch` arm and its picker's Enter, so a row
number, an id prefix or a title substring mean the same thing through either door. This
sent the text as an id, so `/switch 3` and `/switch parity` were a round trip that
answered nothing — while the picker two keys away accepted exactly those. One
`%resolve-session` now serves both, and an ambiguous match is still refused with the
count.

**`/rename` has both guards**, and they are different guards: an empty session id (the
state before the first `Hello`) says `not attached to a session yet` and sends nothing,
where it used to send `rename_session` for the empty id; an empty NAME says what it is
about to do and still sends, because that is how a name is cleared.

**`ctrl-b`, `ctrl-f` and `ctrl-_`.** The reference binds these in its DECODER
(`term.rs:562-576, 590-594`) and this head had no arm for any of the three, on a tree
carrying the rest of the emacs set. `ctrl-_` is `0x1f`, which `read-key` maps to
`(code-char 127)` — Rubout — and it cannot collide with a backspace because a literal
`0x7f` is matched EARLIER, as `:type :backspace`.

**Not done, and it needs both heads:** `/models` and `/resync` in the completion table.
This head's table HAS both (it is the table the help screen, Tab completion and the
dispatcher all read); the doc records it as A's gap too, and C14 makes the table a
shared artefact — byte-identical in every head — which is a two-head job.

### R13 — a running tool call shows a live elapsed time

**DONE** (the commit after `9d08b8d`). The operator, on a `cargo build` that prints
nothing: *"when a tool call takes time it is frozen at 0ms until it finishes. A live
coarse timer would be nice, say 1/10th of a second."*

**The diagnosis here is NOT letibot's, and that is why it was measured before it was
fixed.** In letibot the number beside a running call is written from a `ToolProgress`
event, so a command that says nothing produces no number. Here the running elapsed was
**already read from this head's own clock** (`%call-elapsed-ms`, anchored by
`note-call-started` when `:tool-started` ARRIVED) — and measured on a scratch head, it
moves:

    value  75637 ms -> 78680 ms            (moves: read from this head's clock)
    glass  Running · 1m19s · 1m19s · 1m19s (frozen: four seconds, no event)

**R13's defect is one layer above where it was reported: the number was never the
problem, the ASKING was.** The loop paints when `head-dirty` is set and only a frame or
a key sets it, so a number computed from `*now-ms*` is computed and never drawn again —
the frame is a SNAPSHOT of the clock, kept until an event replaces it. Two things
already animate from that clock (the spinner and the cat) and they were frozen with it.

**And the measurement nearly missed it.** `scripts/tui-eval`'s liveness probe POKES
`head-dirty` (`:220`) to prove the loop can paint, so an eval-based freshness probe
**keeps the frame fresh**: a first pass through the socket read the glass *moving*
(1m15s → 1m18s) and would have concluded there was nothing to fix. The numbers above
are from `tmux capture-pane` with no eval in between — the operator's own view, touching
nothing. The general rule is in `HACKING.md`: a measurement that takes time starves what
it measures; this one REFRESHES it.

**The fix**: a second reason to paint, and it is the clock. `live-frame-p` is true while
something on the frame is a function of time — a running turn (the spinner, `· {since}`,
the stall row becoming due), a running call, the carry/filling line — and
`live-frame-due-p` asks for a frame at most once per `+live-frame-ms+` = **100 ms**,
which is the operator's tenth rather than a choice of ours. A notice and a pending
stop-wait are deliberately NOT in the list: they arm their own deadline and set `dirty`
themselves.

    after:  Running · 50.8s · 52.7s · 54.8s · 56.8s · 58.7s   (two seconds apart)
            Running · 800ms · 1.1s · 1.6s · 2.0s               (sub-second, in tenths)

**Cost, measured over 30 s on a 24x80 scratch head**: idle 1 tick of CPU (0.03 % of one
core), live frame 3 ticks (0.10 %) — so ten frames a second costs 0.07 % of a core, and
an idle head still sleeps.

**The trap, answered rather than avoided.** A start instant that came from the DAEMON is
on the daemon's clock and `*now-ms*` is ours; subtracting one from the other is a
duration measured across two clocks, silently wrong by whatever they disagree by, worst
exactly when a head attaches to a daemon on another box. The anchor here is
`note-call-started`'s own reading at arrival, so the whole duration is in one clock;
it is short by the delivery latency of the one frame that started the call, and that is
the honest cost of answering *how long have I been waiting* in the reader's clock. The
alternative — have the daemon report an elapsed — needs a progress event, and not
needing one is the point.

**Not changed**: the settled duration. `note-call-finished` measures it once, exactly,
and the row shows that (measured: 10047 ms stored, which `%live-elapsed-ms` would have
flattened to 10000). Only a number that is still moving is rounded down to a tenth.

**A consequence worth naming**: the stall row. It becomes due after `*stall-ms*` of
silence — itself a function of the clock — so it could not appear until an event did
either. Measured on the glass after this change, with no event since the attach:
`nothing received for 2m51s. The turn is still marked running; esc esc interrupts it.`

### R15 — an edit card's label is the file, with no elided-array placeholder

**DONE** (`0446585`). The operator's rows, and the ruling on them:

    ▸ Edited […] letibot/crates/harnessd/src/answers.rs · ok · 3ms · 10 lines
    ▸ Edited […] /home/dead/Projects/leticl/src/commands.lisp · ok · 30ms · 195 lines

*"`[…]` should be gone for Edit."* Not moved, not reordered — **gone**. This head's
`display-target` is a faithful port of `sessionlog::display_target` (the scalar argument
values in written order, a nested one elided at `cards.lisp:93`/`:142`), and the rule is
right in general: what was wrong is that a batch `edit` writes its `edits` array before
its `path`, so the placeholder took the best position on the row to point at the diff
drawn directly underneath it. Measured, ten shapes:

| arguments | before | after |
|---|---|---|
| `{"edits":[…],"path":"…/commands.lisp"}` | `[…] /home/dead/…/commands.lisp` | `/home/dead/…/commands.lisp` |
| `{"path":"a.rs","edits":[{"old":"x"}]}` | `a.rs […]` | `a.rs` |
| `{"path":"src/cards.lisp","ranges":[…]}` | `src/cards.lisp […]` | `src/cards.lisp` |
| `{"todos":[…]}` | `[…]` | `[…]` |
| `{"signal":"term","pids":[1,2,3]}` | `term […]` | `term […]` |
| `[1,2,3]` | `[…]` | `[…]` |
| `{}` | `{}` | `{}` |

**Where the line is drawn**: the elision STAYS. What changed is what a nested value IS —
**a placeholder, not a part of a label** — so it is dropped exactly when the arguments
name a SUBJECT (`path`, `file_path`, `file`) and kept when they name nothing. **The tools
that keep it**: `todo_write` (`{"todos":[…]}` — no scalar argument at all, so `[…]` is the
only thing its label can say), and a `pkill`/`kill` with pids (`{"signal":"term","pids":
[…]}` — `signal` is a MODIFIER, not a subject, so `term` alone would read as if `term`
were the thing being signalled). A bare top-level array still says `[…]` and `{}` is
still `{}`.

**Not ported**: letibot's subject-key PREPEND (`event.rs:354-365`) is kept here — it is
the same idea from the other side and it is still right for a `write`, where a huge
`content` genuinely buries the `path`. The proposed extension of it to REORDER every
edit row was rejected by the operator in favour of removal, and the reason is the better
one: *a row should not need a rule to put the file first when on an edit nothing else
belongs first.*

Deliberate divergence, named: `event.rs:1061` pins `a.rs […]` as a unit test in the
reference. That case now differs between the heads on purpose.

### R8, in its general form

**A number about the SESSION is a property of the session, not of this head's uptime.**

The header's `ctx` was correct whenever a turn had run in the head's own lifetime and
ABSENT on every other screen — after a daemon restart, a reattach, a `--resume`, or a
session opened from disk — because the only place it looked was the turn, and
`TurnFinished` is ephemeral: a view rebuilt from the transcript has no turn. That is
most of the time, and precisely when somebody asks how big the conversation is
(*"leticl doesnt show context size for whatever reason"*). The answer was already on the
wire, on the session's own row, written at every round finish.

Two disciplines come with it, and they are why it is not a one-liner:

1. **A backfilled row knows the size and may not know the cache FRACTION.** It carries
   `context_cached` only if a turn finished after that column existed, so the size is
   shown and the percentage is absent — never `0% cached`, which is a measurement
   nobody made. The header already refused an unmeasured fraction (G12's guard); it
   simply had nothing to feed it.
2. **A backfilled row carries NO COST.** Nothing recorded a per-turn cost on that row,
   and a zero there reports a metered session as free — §13.2b in its most expensive
   form. A number that is ABSENT is not a number that is zero.

The order is the reference's and each step wins over the next: **the prompt being sent
(live prefill), what the last turn cost, then the session's own row.** The row is a
round behind by construction — it is written when a round finishes — so it is the last
word and never the first.

---

## How each gap should be tested

The rule throughout: **guard the fact, not the proxy.** A pane that renders is not a
pane that is reachable, and a green render gate says the head is healthy, never that a
screen is right.

| gap | test |
|---|---|
| G1 chords in panes | Unit: drive `%handle-key` with `(:type :ctrl :ch #\c)` at each `head-mode` and assert the mode returned to `:normal`. Live: open each pane and press Ctrl+C, then compare against letibot with `scripts/compare-heads`. |
| G2 the notice row | Unit: `(say head "x")`, render at 61 rows, and assert `"x"` appears in the rendered rows — the current code passes only at `rows < 8`, which is the bug. Add a case for the stall line with `*now-ms*` set past `*stall-ms*` **and a running turn**. Live: `tui-eval '(say *head* "probe")'` then `tui-eval --screen` and grep. |
| G3 the cat | Unit: call `run`'s startup ordering in isolation — or, cheaper, assert `(attaching-p head)` is true for a head with `*attach-started-ms*` set and `head-connected` T, which is the startup state. The existing test (`tests/tests.lisp:3227-3241`) sets `connected` NIL and therefore proves nothing about startup; fix the test first. Live: attach to the largest session and `tui-eval --screen` within the first second. |
| G4 job_out | Unit: feed a `job_output` frame and assert the pane's header carries `bytes A..B of N` and that `→` pushes the `back` stack. Live: start a long `background: true` command, Enter on its row, and assert the transcript did **not** gain a `/job` line. |
| G5 peek | Unit: `pane-row-count` for `:peek` should be the line count, not 0; assert Up moves `*pane-scroll*` and that Esc from `:peek` returns to `:subagents`. |
| G6 permission card | Golden-line test: build an `OpenDecision` plist carrying `:advice` and `:options` with `reject_always` + `allow_always`, render, and assert line-for-line against the reference's own output for the same decision. `compare-heads` on a live gated call is the stronger check — the two cards must be byte-identical. |
| G7 ladder | Unit: type into the composer, send `:down`, assert `head-decision-sel` moved and the composer is untouched; send `:enter`, assert the line was **submitted**, not the option answered. |
| G8 restore | Manual and deliberate: `tui-eval --no-verify` a form that signals on the main thread (a key handler, not a render — the render already has a guard), then check `stty -a` in the same terminal. The gate exists for exactly this and must be bypassed here. |
| G9 `--resume` | End-to-end: stop the daemon, start a fresh one, `leticl --continue` into a session that is on disk but not held. letibot succeeds; leticl must too. |
| G10 slash_out | Unit: feed a `warning` frame with code `slash` whose detail has 5+ lines and assert a pane opened. Live: `/gate recent` and compare screens. |
| G11 counters | Unit: ingest Hello with `dropped 10`, then a Resync snapshot with `dropped 3`, and assert `/status` still says at least 10. Add a `scrubbed` case across a resync. Then assert `alarmed-p` is true for `scrubbed > 0` alone. |
| G12 header ctx | Unit: a running turn with a `:progress` plist whose `total` differs from the kept usage; assert the header shows the progress number. Landed: `the-header-prefers-the-prompt-being-sent`. |
| R8 session ctx | Unit, three cases, because the discipline is the point: a head with **no turn at all** and a brief carrying `context_tokens`+`context_cached` shows `N ctx` and the percentage; the same brief **without** `context_cached` shows the size and says nothing about the cache; and neither lights the money meter. Then the order: a live prefill beats a turn's usage, which beats the row. Landed: `the-context-size-survives-a-daemon-restart`, `a-live-turn-still-wins-over-the-sessions-own-row`, `the-session-row-is-read-not-invented`. |
| G13 `o` | Unit: `:char #\o` on `:subagents` sends a `switch` frame. |
| G14 picker cursor | Unit: open the picker on a session list where the current session is row 3 and assert `head-picker-sel` is 2. |
| G16 config | Unit: Enter at the last row wraps to 0; Enter with a non-empty composer submits the line rather than flipping the row; give `*prefs*` a real temp `:path` and **read the file back** after Enter (the existing test at `tests/tests.lisp:2043-2066` uses a NIL path and never touches disk, which is the one assertion the reference has and leticl does not — `app.rs:11256-11260`). |
| G17 unreadable prefs | Unit: `chmod 000` a temp `head.toml`, call `load-prefs-into`, assert defaults and a note, and assert nothing signalled. |
| G18 `--no-tty` | Once it exists: `bin/leticl-head --no-tty < /dev/null > frame.txt` in CI, diffed against a golden frame — which is also what makes every other test in this table cheap. |
| all pane rendering | `scripts/compare-heads --plain` on two heads attached to the same session at the same size, per pane. Per HACKING.md the two screens should be byte-identical except where a number was measured by the head itself. **Re-capture first** — the archived captures predate HEAD and at least two of their differences are already closed. |
