# Panes, cards and head state — leticl against letibot

**Surface:** the full-body screens, the cards, the head's own persisted state, the
head's lifecycle and the instrumentation the operator reads. Not the key table, not
the wire, not transcript row rendering — those are measured elsewhere.

**Reference:** `/home/dead/Projects/letibot/letibot` at `8af671e`
(`git -C … rev-parse HEAD` → `8af671e3467ce0a139ba25d99a18378ba39c910b`).
Cited as `app.rs:N`, `term.rs:N`, `prefs.rs:N`, `bin/letibot-tui.rs:N`, `driver.rs:N`
— all under `crates/tui/src/`.

**Subject:** `/home/dead/Projects/leticl` at `dc62ddf` (working tree clean except this
file). Cited as `src/NAME.lisp:N`.

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
| **job_out** | its own overlay: `job output — id`, `state — bytes A..B of N`, `→`/`←` paging on a `back` stack, refusal rendered in the pane that asked | `app.rs:6894-6994`, `app.rs:3277-3300`, `app.rs:2794-2800` | **absent** | — | **MISSING**. leticl's jobs-pane Enter closes the pane and sends `/job ID` as a slash line (`src/editor.lisp:305-313`) — the exact behaviour the reference removed on the operator's report quoted at `app.rs:3830-3838` |
| **picker (sessions)** | header, two lines per session, facts right, id+workspace under every row, two dim closers | `app.rs:7049-7148` | identical, plus the subagent filter the reference also has (`app.rs:1667-1671`) | `src/panes.lisp:68-158` | **SAME to draw**; the cursor does not open on the current session — see 1.4 |
| **slash_out** | a slash reply of >3 lines opens a pane: bold echo, blank, wrapped body, `esc closes · up/down scrolls`; owns Esc/Up/Down while up | `app.rs:2785-2790`, `app.rs:5235-5243`, `app.rs:3319-3335` | **absent** — no mode, no `"slash"`-warning split; `%send-slash` just writes the frame (`src/commands.lisp:193-201`) | — | **MISSING** |
| **attach indicator** | centred cat, pawprints, `asking the daemon for this session`, elapsed, and at ≥2 s `the daemon has not answered. ctrl-c twice, or wait` | `app.rs:6061-6105`, `ATTACH_IMPATIENT` `app.rs:1313` | same seven rows, no impatient row | `src/chrome.lisp:663-682`, drawn `src/render.lisp:374-378` | **DIFFERS** on content **and unreachable at startup** — see 1.5 |
| **empty-session banner** | `letibot` + `attached, and this session has said nothing yet…` + `/help lists the keys.` | `app.rs:6112-6131` | **absent** | — | **MISSING** |

### 1.3 The cards

| card | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| **decision / permission** | `? {headline} [{kind}]` in yellow with the target *stripped out of the summary*; target alone, bold, 4 in; detail dim; **the oracle's verdict** (`model says X: basis`, cites, `by · N ms`); one option per line as `▸ {label}  ({option_id})`; hint `↑↓ to choose · Enter to answer · or type the id`, **plus a glob line only when `allow_always` is offered**; plus `deny_and_tell <why>` when `reject_always` is | `app.rs:7329-7466`; `ask_without_target` `app.rs:7865-7874` | yellow ` permission ` badge + bold summary **unstripped**; target bright-white 1 in; detail dim; `:because` (not the oracle); options as `❯ 1. {label}` with **no option id**; hint `enter answers · up/down moves · esc does nothing`; no glob line; `type: {id} <the words…>` for reject_always | `src/cards.lisp:1138-1193` | **DIFFERS** — four ways, listed as G6 below |
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

**G4 — Enter on a jobs row posts `/job ID` into the conversation. `M`.
`src/editor.lisp:305-313`, new pane in `src/panes.lisp`.**
The reference removed exactly this on the operator's report quoted verbatim at
`app.rs:3830-3838`; the replacement is the `job_out` overlay (`app.rs:6916-6994`) with
`→`/`←` paging on a `back` stack (`app.rs:6894-6914`), the daemon's byte offsets in the
header, and a refusal rendered **in the pane that asked** (`app.rs:2794-2800`).
*Why it matters:* reading a build log is what the jobs pane is for, and leticl's Enter
closes the pane and scrolls the log past in chat.

**G5 — the peek pane does not scroll, does not re-read, and does not go back. `S`.
`src/editor.lisp:242-256,275-321,749`.**
`pane-row-count` returns `0` for `:peek`, so Up/Down move nothing; Enter has no `:peek`
arm though the footer promises `Enter re-reads`; Esc goes to `:normal` rather than back
to the tree (`app.rs:3237-3262` does all three). No spill file either — `app.rs:8025-8060`
writes the whole view under the head's runtime dir and names it in the footer.
*Why it matters:* the pane's own last line advertises three keys, two of which do
nothing.

**G6 — the permission card is missing four things. `M`. `src/cards.lisp:1138-1193`.**
(a) The **oracle's verdict** — `model says {would}: {basis}`, its citations, `by · N ms`
(`app.rs:7377-7409`). leticl already receives it (`:advice`, `src/session.lisp:324`) and
never draws it; under `/mode supervised` the question is *do you agree with the model*
and the model's answer is off-screen.
(b) The **option ids** — the reference prints `▸ {label}  ({option_id})`
(`app.rs:7419-7424`) so the typed path and the ladder show the same choice; leticl
prints `❯ 1. {label}` only.
(c) The **glob hint**, shown only when `allow_always` is on offer (`app.rs:7434-7448`).
(d) `ask_without_target` (`app.rs:7865-7874`) — leticl prints the summary unstripped and
then the target again, so the command appears twice.

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
