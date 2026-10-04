# keys.md — the operator's input

**The `src/…` citations below were RE-POINTED when this tree was cut into directories**,
by `scripts/repoint-citations` — which reads the cited line from the pre-split tree
(`git show b72df84:src/<file>.lisp`), finds that text under `src/<file>/`, and rewrites
the citation to the file and line it is NOW. It is measured, not guessed: a text that
matches two places is left alone, a range divided by a cut is written as BOTH ends, and
what could not be found is left as the record it was. **This document cites no
`src/…:NNN` lines** — its `src/` mentions are paths, and those are the directories now.
The tool re-points the LINE a
citation names; whether the row's own prose describes that line is this document's
question, measured against the reference pin above.

**Reference: letibot `8af671e`.** Subject: leticl at `dc62ddf` (2026-09-20 22:19; the
pass finished at `7c2c6fc`, 23:37). Every row below cites a file and a line on both
sides — **measured at that pin, which has since moved to `149edf9` (2026-10-04): of the
130 `file.rs:NNN` citations below, 5 are still exact against the new one and 125 have
moved, so re-read the FUNCTION and not the line (`scripts/repin-check`, and the pin
section of TODO.md for what the move was).** Nothing here was run: the reference
was read at `crates/tui/src/term.rs` (the decoder), `crates/tui/src/app.rs`
(`enum Key`, `App::key`, `command`, `SLASH_COMMANDS`) and
`crates/ui/src/editor.rs` (the composer); leticl at `src/keys.lisp`,
`src/editor/`, `src/commands/` and the picker arms in `src/panes/`.

**A SNAPSHOT, NOT THE TREE — and on 2026-09-22 that cost a day's work.** Twenty-three
minutes after this pass closed, `b7a2620` landed (**Enter on a jobs row opens the
output in a pane**) — and nothing re-measured the rows that said otherwise: **G20**
here, `panes.md` **G4**, `wire.md` **W2**, and `TODO.md`'s T1(3). They went on saying
MISSING, and on 2026-09-22 a driver read them and handed that line to the head as
work: *"Take T1(3) — it is the one B-side defect left"*, on a defect that had been
closed for a day and a half. **The §2.6 incident, mirrored**: that one was a commit
message claiming work that was not there, this one is four files claiming work was
MISSING that was there. Neither is catchable by a test, and both are catchable by one
rule — *a criterion names a test, and the test is run from the tree as committed*.

Those rows now carry the measurement and its date. **Every other row here is true of
`dc62ddf` and says nothing about today; re-measure before acting on one.** Re-measured
2026-09-22 against the tree at `047f9ad` (the behaviour landed in `b7a2620`): this
file's **G20** and the **§3 rows 5 and 16**; `panes.md` **G4** names the evidence for all
of them.

---

## Summary

**Keys: 35 of 38 · Commands: 36 of 39.**

The reference decodes 38 distinct chords (`enum Key`, app.rs:194-255, produced by
`decode_prefix`/`escape`/`csi`, term.rs:513-830). leticl binds 35 of them
(`read-key`, keys.lisp:132-164; `%handle-key`/`%normal-key`, editor.lisp:136-478)
and misses three outright — **word-left, word-right and redo**. Of the 35 it does
bind, **14 behave exactly as the reference does**; the other 21 differ, and the
differences cluster in four places: the composer has no vertical motion and a
weaker history, `ctrl-c` means something else, the panes swallow every printable
character, and the paste ledger's markers are not unique. On commands, leticl
accepts 36 of the 39 verb spellings the reference accepts with the same effect —
`/s`, `/i` and `/reseat summarise` are the three that silently do the wrong thing
— and it adds nine verbs of its own (`/subagents`, `/todos`, `/peek`, `/resume`,
`/promote`, and their short forms), all of which the reference reaches by chord
only.

The single most damaging finding is not a missing key. It is that **in leticl no
printable character reaches the composer while any full-body pane is open**
(editor.lisp:232, 323-324), including the session picker whose own hint bar says
*"type a number to switch · /new [title]"* (chrome.lisp:363). The reference lets
every pane's text fall through to the composer and gates only Enter on an empty
line (app.rs:3508-3548).

---

## 1. The decoder — bytes to keys

| reference behaviour | citation | leticl behaviour | citation | verdict |
|---|---|---|---|---|
| Printable ≥0x20 decoded as UTF-8, held when a read cuts a character in half | term.rs:666-683 | `read-char` on a character stream; the external format joins the bytes | keys.lisp:164 | SAME |
| `ESC[200~ … ESC[201~` → one `Key::Paste`, held incomplete until the terminator arrives | term.rs:520-535 | `%read-paste` blocks on `read-char` until `ESC[201~`; a nested ESC that is not the terminator is kept as content | keys.lisp:87, 95-117 | DIFFERS — a paste whose terminator never arrives blocks the input thread rather than being carried into the next read |
| Lone `ESC` is `Esc`; held only when `force` is off and the buffer ends there | term.rs:700-706, 760-769 | Lone `ESC` is `:esc` after a 60 ms silence (`*escape-wait-ms*`); a CSI waits 1000 ms for its final byte (`*csi-wait-ms*`) | keys.lisp:14, 42-47, 136-141 | DIFFERS — a timer instead of a held tail. Same outcome for a human, and see gap G1 for the case it does not cover |
| `ESC ESC` → **two** `Esc`, explicitly so a double-tap in one read is not eaten as Alt+Esc | term.rs:707-711 | `ESC` then `ESC` within 60 ms → `(:type :alt :ch #\Esc)`, which the `:alt` arm drops | keys.lisp:157 + editor.lisp:388-395 | DIFFERS — **gap G1**, the interrupt is eaten |
| `ESC O A/B/C/D/H/F` (SS3) → Up/Down/Right/Left/Home/End | term.rs:715-733 | `ESC O` decodes 65-68 only; `H` and `F` fall through to `:esc` | keys.lisp:147-156 | DIFFERS — SS3 Home/End missing |
| `ESC \r` / `ESC \n` → `SoftEnter` | term.rs:737 | `(:type :alt :ch #\Return)` → newline in `%normal-key` | keys.lisp:157, editor.lisp:388-395 | SAME |
| `ESC b` → `WordLeft`, `ESC f` → `WordRight` | term.rs:738-739 | `(:type :alt :ch b/f)` → dropped by the `:alt` arm | keys.lisp:157, editor.lisp:392 | MISSING |
| `ESC z` → `Redo` (Ctrl+Shift+Z is byte-identical to Ctrl+Z in many terminals) | term.rs:740-742 | dropped | editor.lisp:392 | MISSING |
| `ESC 0x7f` (Alt+Backspace) → `KillWordBack` | term.rs:743 | dropped | editor.lisp:392 | MISSING |
| Any other `Alt+key` swallowed, never typed | term.rs:744-746 | same — the `:alt` arm inserts only for `#\Return` | editor.lisp:388-395 | SAME |
| CSI `A B C D H F` → Up Down Right Left Home End | term.rs:776-782 | same | keys.lisp:72-77 | SAME |
| CSI `1;5C` / `1;5D` → `WordRight` / `WordLeft` (the modifier is param 2, `5` is Ctrl) | term.rs:773-780 | params are parsed but the modifier is never read; `1;5C` → `:right` | keys.lisp:67-70, 74-75 | MISSING — Ctrl+arrow is a plain arrow |
| CSI `~`: `1`/`7`→Home, `3`→Delete, `4`/`8`→End, `5`→PageUp, `6`→PageDown | term.rs:783-790 | identical table | keys.lisp:78-88 | SAME |
| SGR mouse `?1006`: `M`+64 WheelUp, `M`+65 WheelDown, `M`+0 Click; **every other report decoded and dropped** | term.rs:791-826 | 64/65 wheel; `≥32` motion; otherwise press/release with the button number, all emitted | keys.lisp:89-92, 122-130 | DIFFERS — leticl emits releases, motion and buttons 1-2; the click arm tests `:kind :press` and not the button (editor.lisp:209-211), so a **right-click selects a row** |
| Coordinates 1-based on the wire, 0-based in the key | term.rs:802-818 | 1-based kept; the pane arm subtracts the border row itself | keys.lisp:126-130, editor.lisp:213-215 | DIFFERS — an off-by-one moved rather than removed; correct today, but the two sides do not agree on what `x`/`y` mean |
| Terminal modes switched on: `?1049h ?25l ?2004h ?1002h ?1006h` | term.rs:21 (header), and the enter sequence | the same five, in the same order | term.lisp:125 | SAME |

---

## 2. Every chord, and what it does

Contexts are the reference's precedence order. "composer" means it reaches
`letibot_ui::editor::Editor` (app.rs:3876-3880).

| chord | reference behaviour | citation | leticl behaviour | citation | verdict |
|---|---|---|---|---|---|
| printable char | insert at the cursor; on a card, a digit `1`-`9` picks that row when nothing is typed | editor.rs:311-314, app.rs:7843-7847 | insert; digit picks a row on the decision ladder, the quit card and the pickers | editor.lisp:358-370, 344-346, 187-191, panes.lisp:1295-1300 | SAME |
| printable char, **pane open** | falls through to the composer; only `o` on the subagent pane is claimed | app.rs:3370-3394, 3696 | **swallowed**; only `q` is read, and it closes the pane | editor.lisp:323-324 | DIFFERS — **gap G2** |
| paste | one key; ≥5 lines **or** >800 bytes collapses to `[Pasted #N ~L lines]`; CRLF and bare CR normalised | editor.rs:557-571, 215-217 | ≥5 lines only; marker `[⋮ pasted N lines ⋮]`, **keyed on the line count alone**; no CR normalisation | editor.lisp:629-657 | DIFFERS — **gap G3** |
| `enter` | submit the expanded text; empty/whitespace-only is `Idle` | editor.rs:319-325 | submit; empty line is a no-op **after** the history push | editor.lisp:76-116 | DIFFERS — **gap G4** (empty Enter enters history) |
| `alt+enter` | newline, no submit | editor.rs:326-329 | newline, no submit | editor.lisp:388-395 | SAME |
| `backspace` | delete the grapheme before the cursor | editor.rs:330-337 | delete one character before the cursor | editor.lisp:494-500 | SAME |
| `delete` | delete the grapheme at the cursor | editor.rs:338-345 | delete one character at the cursor | editor.lisp:502-507 | SAME |
| `←` / `ctrl-b` | one grapheme left | term.rs:561-564, editor.rs:346-353 | `←` only | keys.lisp:75, editor.lisp:379 | DIFFERS — `ctrl-b` unbound |
| `→` / `ctrl-f` | one grapheme right | term.rs:569-572, editor.rs:354-361 | `→` only | keys.lisp:74, editor.lisp:379 | DIFFERS — `ctrl-f` unbound |
| `↑` (composer) | move up one **visual** row; at the top row, walk history | editor.rs:382-389, 500-516 | walk history, always | editor.lisp:380 | DIFFERS — **gap G5** |
| `↑` (empty composer, at the tail, queue non-empty) | recall the queued prompt **and** `WithdrawPrompts` | app.rs:3851-3861 | not bound to `↑`; `ctrl-u` does it | editor.lisp:436-447 | DIFFERS — **gap G6** |
| `↑` (empty composer, no history, nothing queued) | scroll the transcript one line | app.rs:3908-3919 | nothing | editor.lisp:380 | DIFFERS |
| `↓` (composer) | move down one visual row; past the last row, walk history forward | editor.rs:382-389, 509-511 | unpark the scrollback if parked, else step history | editor.lisp:381-387 | DIFFERS — no vertical motion |
| `ctrl-a` / `home` | start of the **line** (not the buffer) | editor.rs:372-376, 687-692 | start of the **buffer** | editor.lisp:514 | DIFFERS — wrong on a multi-line prompt |
| `ctrl-e` / `end` | end of the line | editor.rs:377-381, 694-699 | end of the buffer | editor.lisp:515 | DIFFERS — same |
| `alt+b` / `ctrl-←` | word left, `WordStyle::Small` | editor.rs:362-366, 701-726 | — | — | MISSING — **gap G7** |
| `alt+f` / `ctrl-→` | word right, then skip the gap | editor.rs:367-371, 728-758 | — | — | MISSING — **gap G7** |
| `ctrl-k` | kill from the cursor to end of **line**, into the kill buffer | editor.rs:390-398 | kill from the cursor to end of **buffer**, into a 16-deep ring | editor.lisp:448, 517-519, 561-568 | DIFFERS — line vs buffer |
| `ctrl-u` | kill from start of line to the cursor | editor.rs:399-407 | kill start-of-buffer to cursor — **unless** the composer is empty and a prompt is queued, then withdraw it | editor.lisp:436-447 | DIFFERS — two meanings on one chord |
| `ctrl-w` / `alt+backspace` | kill the word back, `WhitespaceDelimited` | editor.rs:408-416, term.rs:743 | `ctrl-w` only; the scan tests `#\space` alone, so a newline is not a boundary | editor.lisp:449, 525-531 | DIFFERS |
| `ctrl-y` | yank the single kill buffer | editor.rs:417-424 | yank the head of a 16-entry kill ring | editor.lisp:450, 623-627 | SAME (leticl's ring is an EXTRA the key does not expose) |
| `ctrl-z` / `ctrl-_` | undo, batched at word granularity; a kill is always its own step; the kill buffer is **not** restored | editor.rs:425-440, 638-670 | undo, batched at word granularity by the caller; the ring is not restored; `ctrl-_` unbound | editor.lisp:451, 358-368, 593-608 | DIFFERS — `ctrl-_` unbound |
| `alt+z` (redo) | pop the redo stack | editor.rs:441-454 | — | — | MISSING — **gap G8** |
| `esc` (parked in scrollback) | follow the stream again | app.rs:3398-3401 | same | editor.lisp:396-402 | SAME |
| `esc` (pane/card open) | closes it | app.rs:3370-3394 | closes it | editor.lisp:242, panes.lisp:1301 | SAME |
| `esc esc` (within 5 s) | interrupt; **any other key disarms the first press** | editor.rs:304-306, 455-465 | interrupt within `*esc-double-ms*` = 5000 ms; nothing disarms it | editor.lisp:403-411, chrome.lisp:16-22 | DIFFERS — **gap G9** |
| `esc esc` with no turn running | says *"nothing is running"* | app.rs:3883-3892 | silent | editor.lisp:407-410 | DIFFERS |
| `ctrl-c`, composer non-empty | **clears what you typed**, never quits | editor.rs:466-477 | opens the quit card (or interrupts a running turn) | editor.lisp:422-434 | DIFFERS — **gap G10** |
| `ctrl-c`, composer empty, idle | first press arms; **second within 1 s** opens the quit card | editor.rs:478-484, app.rs:3899-3904 | **first press** opens the quit card | editor.lisp:432-434 | DIFFERS — **gap G10** |
| `ctrl-c`, turn running | clears the composer (the interrupt is `esc esc`) | editor.rs:466-477 | interrupts the turn | editor.lisp:428-431 | DIFFERS |
| `ctrl-c`, pane or picker open | closes it, like Esc | app.rs:3273, 3306, 3321, 3379 | **unhandled** in the pane arm and in `pick-key-event`; falls through and opens the quit card | editor.lisp:241-325, panes.lisp:1275-1302 | DIFFERS — **gap G11** |
| `ctrl-c`, secret card up | refuses the password | app.rs:3003-3011 | unhandled — nothing happens | editor.lisp:149-168 | MISSING — **gap G11** |
| `ctrl-d` | quit **only on an empty composer** | editor.rs:485-491 | quit unconditionally | editor.lisp:435 | DIFFERS — **gap G12** |
| `ctrl-r` | flip the thinking fold, refold, say the three fold states | app.rs:3018-3022, 4051-4061 | flip and **persist to head.toml** | editor.lisp:461, prefs.lisp:120-130 | SAME (+ persistence, EXTRA) |
| `ctrl-t` | flip the tool fold; opening it also **opens the payload view** on the newest row that has one; closing it closes the view | app.rs:3023-3046 | flip the fold only | editor.lisp:462 | DIFFERS — **gap G13** |
| `ctrl-x` | show/hide raw `<function=…>` markup | app.rs:3062-3066 | same | editor.lisp:468-475 | SAME |
| `ctrl-l` | repaint from scratch | app.rs:3067-3070 | same (`head-full-repaint`) | editor.lisp:454 | SAME |
| `ctrl-s` | **toggle** the session picker; on open, seed the cursor to this session and ask for a fresh list | app.rs:3071-3095 | `/sessions`: ask and open. Pressing it again does nothing (the pane arm has no `:ctrl`) | editor.lisp:464, commands.lisp:60-62 | DIFFERS — **gap G14** |
| `ctrl-p` | toggle the todos pane; on open, re-read `TODO.md` and ask for the session's list | app.rs:3096-3115 | `/todos`: ask and open; no toggle-off | editor.lisp:465, commands.lisp:114-120 | DIFFERS — **gap G14** |
| `ctrl-g` | toggle the subagent tree | app.rs:3119-3124 | open only | editor.lisp:466, commands.lisp:113 | DIFFERS — **gap G14** |
| `ctrl-q` | toggle the jobs pane; on open, ask the daemon | app.rs:3129-3137 | ask and open; no toggle-off | editor.lisp:467, commands.lisp:104-112 | DIFFERS — **gap G14** |
| `ctrl-o` | promote the running command; two different silences when there is none | app.rs:3152-3168 | identical, including both silences | editor.lisp:463, commands.lisp:149-169 | SAME |
| `pgup` / `pgdn` | a **screen** at a time; an open output view takes them; an open pane scrolls itself (opposite polarity); the two pickers are excluded | app.rs:3178-3244 | a screen minus 3 in the transcript; panes scroll themselves at `*pane-room* - 1`, opposite polarity | editor.lisp:257-260, 412-416 | SAME in kind; the step differs by three rows |
| wheel up / down | 3 lines; same routing as the page keys | app.rs:3185-3190 | 3 lines, same routing | editor.lisp:261-262, 417-419 | SAME |
| `tab`, typing a `/command` | complete to the first match; **more tabs walk the matches**; refuses when the line has whitespace; says `no /command starts with …` | app.rs:3868-3872, 4292-4324 | unique prefix inserts `/name `; ambiguous prints the candidates on the status line; no whitespace guard; no cycling; silent on no match | editor.lisp:118-134 | DIFFERS — **gap G15** |
| live completion row above the composer while `/…` is typed | app.rs:4342-4358, drawn at 5078 | — | — | MISSING — **gap G15** |
| `tab`, todos pane | unfolds the item, beside Enter and under Enter's own condition | app.rs:3753-3768 | unfolds on `:todos`; on **every other pane it sets `head-dirty` to NIL**, against its own comment | editor.lisp:263-270 | DIFFERS — a live bug, **gap G16** |
| left-click | session picker: select the row under the pointer, only within the rows the frame drew; mode/model picker: the same | app.rs:3529-3545, 3639-3651 | `:picker :jobs :subagents :todos :config` panes: select the row, guarded by the drawn window, header and list length | editor.lisp:202-222, 683-733 | DIFFERS — **gap G17**: no click on the mode/model picker card |

---

## 3. The context ladders, in order

| # | reference context and what it owns | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| 1 | **`allow-all` confirmation** owns every key: `y`/`Y`/Enter confirm, everything else cancels | app.rs:2964-2980 | identical | panes.lisp:1304-1317, editor.lisp:170 | SAME |
| 2 | **secret card** owns every key: Char/Paste append (paste trimmed of trailing newlines), Backspace pops, `ctrl-u`/`ctrl-k` clear, Enter sends, Esc/Ctrl+C refuse | app.rs:2985-3016 | Char/Paste append (paste **untrimmed**), Backspace pops, Enter sends, Esc refuses. No clear, no Ctrl+C | editor.lisp:149-168 | DIFFERS — see G11 |
| 3 | global chords (`ctrl-r t x l s p g q o`, page, wheel) run before any view | app.rs:3017-3245 | run **last**, inside `%normal-key`, so a pane swallows them | editor.lisp:232-325, 420-475 | DIFFERS — **gap G18**: `ctrl-r`/`ctrl-t`/`ctrl-l`/`ctrl-o` do nothing while any pane is open |
| 4 | **subagent output view**: ↑↓ scroll, Enter re-reads, Esc back to the tree | app.rs:3255-3280 | `:peek` mode is in the generic pane list; `pane-row-count` returns 0 for it, so ↑↓ move nothing and Enter is not in the `case` | editor.lisp:232-325, 735-750 | DIFFERS — **gap G19**: the hint bar advertises both (chrome.lisp:369) |
| 5 | **job output view**: ↑↓ scroll, →/Enter next page, ← back, Esc to the jobs list | app.rs:3287-3313, 6894 | the whole ladder, in one sign-aware place (the pane's origin is its TAIL); `→`/Enter take the offset the daemon NAMED and `←` pops a stack of offsets it was GIVEN | editor.lisp:767-798, 987-994 | SAME — **re-measured 2026-09-22** (gap G20, closed in `b7a2620`) |
| 6 | **slash listing overlay**: Esc closes, ↑↓ scroll | app.rs:3319-3339 | does not exist | — | MISSING (rendering's surface; noted for the keys it would own) |
| 7 | **config pane**: ↑↓ wrap, Enter changes the row | app.rs:3346-3369 | ↑↓ **clamp**, Enter → `config-change` | editor.lisp:234-251, panes.lisp:487-528 | DIFFERS — clamp vs wrap |
| 8 | Esc/Ctrl+C close help, picker, mode picker, models picker, stats, todos, subagents, jobs, config | app.rs:3370-3394 | Esc closes them; Ctrl+C does not | editor.lisp:242 | DIFFERS — G11 |
| 9 | **payload view**: Esc closes, ↑/PgUp and ↓/PgDn page by 10 | app.rs:3412-3445 | does not exist | — | MISSING — **gap G13** |
| 10 | **decision ladder**: ↑↓ move **whether or not a line is being typed**; Enter and digits require an empty composer | app.rs:3474-3498 | the whole ladder is gated on an empty composer | editor.lisp:330-347 | DIFFERS — **gap G21**, the exact defect the reference fixed on 2026-09-20 |
| 11 | **session picker**: ↑↓ wrap, Enter on an empty line switches, click selects; typed text still reaches the composer and `submit` routes it to `pick` | app.rs:3508-3548, 3963-3969 | ↑↓ clamp, Enter switches; **no text can be typed** | editor.lisp:232-325 | DIFFERS — G2 |
| 12 | **quit card**: ↑↓ flip, digits 1-2 on an empty line, Enter takes the row, Esc/Ctrl+C stay | app.rs:3563-3599 | identical, Ctrl+C included | editor.lisp:172-201 | SAME |
| 13 | **mode / models picker**: ↑↓ wrap, Enter on empty, digits, click; typed text reaches the composer and `pick_mode` | app.rs:3601-3653, 4120-4163 | ↑↓ wrap, Enter on empty, digits, typed text via `pick-by-text`; **no click** | panes.lisp:1246-1302, editor.lisp:231 | DIFFERS — G17 |
| 14 | **subagent pane**: ↑↓ wrap, Enter peeks (refusing `opening`), **`o` switches into it** | app.rs:3660-3709 | ↑↓ clamp, Enter peeks with no `opening` guard, no `o` | editor.lisp:283-291 | DIFFERS — **gap G22** |
| 15 | **todos pane**: cursor stops on items, wraps, folds on move; Enter/Tab unfold and scroll the body into view | app.rs:3717-3772 | identical stops and wrap; the body is not scrolled into view | editor.lisp:301-315, 752-769 | SAME (minus the scroll-to-body) |
| 16 | **jobs pane**: ↑↓ wrap, Enter opens the output **in a pane** | app.rs:3782-3835 | ↑↓ wrap, Enter opens the `:job-out` overlay on the row under the cursor and the jobs list stays behind it | editor.lisp:848-854 | SAME on Enter (**re-measured 2026-09-22**); ↑↓ clamp where the reference wraps |
| 17 | Up recalls the queued prompt with `WithdrawPrompts` | app.rs:3851-3861 | on `ctrl-u` | editor.lisp:436-447 | DIFFERS — G6 |
| 18 | Tab completes | app.rs:3868-3872 | Tab completes | editor.lisp:378 | DIFFERS — G15 |
| 19 | the composer | app.rs:3876-3928 | `%normal-key` | editor.lisp:350-478 | see §2 |

---

## 4. Slash commands

### The tables

| reference `SLASH_COMMANDS` (app.rs:1376-1411) | in leticl's `*slash-commands*` (commands.lisp:21-44)? | verdict |
|---|---|---|
| `new`, `sessions`, `switch`, `rename`, `help`, `status`, `think`, `mode`, `jobs`, `cells`, `compact`, `reseat`, `interrupt`, `quit` | yes, same hints | SAME |
| `tools` — *"what this conversation can call, and what it only looks like it can"* | present, but hinted *"fold or unfold tool output"* — the behaviour `/t` has, not the behaviour `/tools` has | DIFFERS — the hint is stale; `%command` has no `tools` arm so the verb forwards to the daemon and does the reference's thing |
| `default-model` | absent from the table (the verb still forwards and works) | MISSING from the listing |
| `verbosity` | absent from the table (`%command` dispatches it at commands.lisp:80-83) | MISSING from the listing — undiscoverable by Tab or `/help` |
| `config` | present | SAME |
| `reseat summarise` (its own row) | absent | MISSING — see G23 |
| — | `models`, `subagents`, `todos`, `peek`, `resync`, `resume`, `promote` | EXTRA — nine verbs the reference reaches only by chord or not at all |

### What each side actually dispatches

| verb | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| `cells [MSG]` | message + the frame as drawn, between `CELLS_OPEN`/`CLOSE`; refuses before the first paint | app.rs:4398-4437 | identical, same delimiters, same refusal | commands.lisp:14-18, 205-222 | SAME |
| `new [TITLE]` | `want_new_session`, `NewSession` | app.rs:4438-4442 | `make-new-session` | commands.lisp:59 | SAME |
| `sessions` / `s` | open the picker + `ListSessions` | app.rs:4443-4447 | `sessions` only — **`/s` falls to the daemon** | commands.lisp:60-62, 173-176 | DIFFERS — **gap G24** |
| `switch ID` | `pick(id)`: row number, or a unique id prefix, ambiguity refused with the count | app.rs:4448-4450, 4063-4068 | `make-switch` with the raw text | commands.lisp:63-65 | DIFFERS — no number/prefix resolution |
| `rename NAME` | refuses when unattached; empty clears the name | app.rs:4455-4468 | sends unconditionally | commands.lisp:66-67 | DIFFERS — no guard |
| `mode` / `mode NAME` | bare opens the picker seeded on the current mode and asks `Settings`; a name goes through `mode_action`, which is the one place `allow-all` can be confirmed | app.rs:4469-4496, 4183-4197 | identical, including the single `allow-all` funnel | commands.lisp:90-99, panes.lisp:1225-1230 | SAME |
| `models` / `model` | bare opens the picker and asks `Settings`; with an argument the line goes to the daemon | app.rs:4618-4646 | identical | commands.lisp:100-103 | SAME |
| `quit` / `q` | quit | app.rs:4498-4501 | quit | commands.lisp:171 | SAME |
| `resync` | `Action::Resync` | app.rs:4502 | `make-resync` | commands.lisp:128-133 | SAME |
| `help` / `h` / `?` | toggle the help screen | app.rs:4503-4508 | open (no toggle) | commands.lisp:69-70 | DIFFERS — G14 |
| `status` / `stats` | toggle | app.rs:4510-4515 | open | commands.lisp:71-72 | DIFFERS — G14 |
| `think` / `r` | flip the thinking fold | app.rs:4516-4520 | flip and persist | commands.lisp:73-74 | SAME |
| `t` | flip the tool fold | app.rs:4528-4532 | flip the tool fold | commands.lisp:78-79 | SAME |
| `verbosity` / `v` | cycle and say the count filtered | app.rs:4533-4541 | cycle and say the count filtered | commands.lisp:80-83 | SAME |
| `config` / `settings` | toggle the pane, ask `Settings`, close the pickers | app.rs:4542-4560 | ask and open (no toggle) | commands.lisp:84-89 | DIFFERS — G14 |
| `jobs` | toggle + `ListJobs` | app.rs:4561-4566 | `ListJobs` + open | commands.lisp:104-112 | DIFFERS — G14 |
| `interrupt` / `i` | interrupt | app.rs:4567 | `interrupt` only — **`/i` falls to the daemon** | commands.lisp:170 | DIFFERS — G24 |
| `compact` | refuses when unattached | app.rs:4568-4578 | sends unconditionally | commands.lisp:141-144 | DIFFERS — no guard |
| `reseat` / `reseat keep` / `reseat verbatim` / `reseat summarise` / `reseat summarize` | one arm; `summarise` is read off the tail and carried on the action; both branches say which one ran | app.rs:4590-4608 | `reseat` only; the argument is **parsed off and dropped**, and the frame carries no `summarise` | commands.lisp:145-148 | DIFFERS — **gap G23** |
| `flowy login supervise supervised gate job jobs tools default-model default_model default` | forwarded to the daemon as typed; refused when unattached | app.rs:4647-4670 | forwarded by the catch-all | commands.lisp:172-176 | SAME |
| anything else | **`unknown command /X — try /help`** | app.rs:4671-4672 | forwarded to the daemon | commands.lisp:172-176 | DIFFERS — a typo reaches the daemon instead of being named |
| `subagents` `todos` `peek ID` `resume ID` `promote` | not verbs; `ctrl-g`, `ctrl-p`, Enter on a pane, and `ctrl-o` | app.rs:3119, 3096, 3677, 3152 | real verbs with usage messages | commands.lisp:113-127, 134-140, 149-169 | EXTRA — keep |

**Answering an open decision by typing.** `match_option` is the same function on
both sides — exact id or label, then unique prefix; trailing words become a glob
on `allow_always` and a note on `reject_always`, refused on anything else
(app.rs:7777-7814 / editor.lisp:18-59). The difference is what happens when the
line names **no** option: the reference puts the line back and **answers the
marked row**, saying *"answered the ask — your line is held, enter sends it"*
(app.rs:3983-4000); leticl says *"…is not an option here"* and answers nothing
(editor.lisp:109-113). See G21.

---

## 5. The editor

| behaviour | reference | citation | leticl | citation | verdict |
|---|---|---|---|---|---|
| model | `Editor` struct: text, cursor, preferred column, kill, undo+redo stacks, history, history cursor, paste ledger, two tap counters | editor.rs:223-245 | a 4-slot `composer` defstruct plus five process globals (`*kill-ring*`, `*undo-stack*`, `*paste-ledger*`, `*esc-at*`, the draft on a symbol plist) | editor.lisp:480-484, 561-586 | DIFFERS — deliberate: a struct slot is a restart (editor.lisp:554-559). Keep |
| clock | injected (`now_ms`), so timing rules are testable | editor.rs:298-300 | read from `get-internal-real-time` inside the arm | editor.lisp:403-404 | DIFFERS — the esc-window rule cannot be unit-tested without stubbing the clock |
| vertical motion | by **visual** row, sticky preferred column, falls out to history at the edges | editor.rs:500-516 | none | — | MISSING — G5 |
| history walk | capped at 50, consecutive duplicates dropped, **navigation stops once a recalled entry is edited** | editor.rs:519-548, 591-593, 606-610, 219 | uncapped vector; no dedup; no edit-stops rule; the draft lives on `(get 'composer :draft)` and is never cleared | editor.lisp:533-550 | DIFFERS — **gap G25** |
| history content | the text **as shown** (markers, not the expansion) | editor.rs:588-594 | the text as typed | editor.lisp:84-87 | SAME |
| undo batching | consecutive inserts coalesce; a cursor jump or a whitespace↔non-whitespace crossing breaks the batch; kill and paste are always their own entry; depth 200 | editor.rs:638-670 | the **caller** pushes a snapshot at a word start, and before every kill/paste/submit; depth 400 | editor.lisp:358-368, 593-598, 577 | SAME in effect |
| redo | a stack, cleared on every edit | editor.rs:441-454, 629 | none | — | MISSING — G8 |
| kill buffer restored by undo? | no, deliberately | editor.rs:434-435 | no | editor.lisp:600-608 | SAME |
| kill storage | one `String` | editor.rs:228 | a 16-deep ring | editor.lisp:561-568 | EXTRA — keep |
| paste threshold | ≥5 lines **or** >800 bytes | editor.rs:563, 215-217 | ≥5 lines | editor.lisp:652 | DIFFERS — a 3-line, 4 KB paste fills leticl's composer |
| paste line count | `matches('\n') + 1` | editor.rs:562 | does not count the trailing newline as a line | editor.lisp:629-640 | DIFFERS — leticl is the more honest of the two |
| marker uniqueness | `[Pasted #N ~L lines]` — **N makes it unique by construction** | editor.rs:564-566 | `[⋮ pasted L lines ⋮]` — **two pastes of the same line count share a marker** | editor.lisp:642-643 | DIFFERS — **gap G3**, a correctness bug |
| ledger lifetime | cleared on submit and on a `ctrl-c` clear | editor.rs:475, 596 | `*paste-ledger*` is never cleared; it grows for the life of the process | editor.lisp:580-586 | DIFFERS — G3 |
| expansion | markers substituted at submit; a deleted marker drops its paste; an edited one is sent literally | editor.rs:579-585 | same substitution at submit | editor.lisp:82-85, 659-674 | SAME |
| CR normalisation | CRLF then bare CR → `\n` (ConPTY) | editor.rs:557-561 | none | editor.lisp:645-657 | DIFFERS |
| composer height | never more than a third of the screen, floor 6 | editor.rs:765-769 | rendering's surface | — | not measured here |
| double-tap hint | `esc again to interrupt` / `ctrl+c again to exit`, from the armed counters | editor.rs:827-835 | `esc again to interrupt` from `*esc-at*`; there is no ctrl-c counter to show | chrome.lisp:351-359 | DIFFERS — G10 |

---

## Gaps worth closing

Ordered by what would stop the operator soonest.

### G2 — no printable character reaches the composer while a pane is open · **M**
**What.** `%handle-key`'s pane arm claims every key for the nine full-body modes
and its `:char` arm reads only `q` (editor.lisp:232, 323-324). The reference lets
Char fall through and gates only Enter on an empty line.
**Why it matters.** The session picker's own hint bar says *"type a number to
switch · /new [title]"* (chrome.lisp:363) and neither works. A pane open means a
head you cannot talk to — the operator has to Esc out, type, and lose the list.
**Reference:** app.rs:3370-3394, 3508-3548, 3963-3975. **Change:** `src/editor/`
(the pane arm) — pass unclaimed keys down to `%normal-key`, and gate the pane's
Enter on an empty composer as the reference does.

### G21 — the decision ladder is gated on an empty composer · **S**
**What.** `((and decision composer-empty) …)` (editor.lisp:332). With a half-typed
line, ↑↓ go to history instead of the ladder.
**Why it matters.** This is the defect the reference fixed on 2026-09-20 with the
operator's own words attached: a permission arrives while you are typing, and the
only way into the menu is to empty the composer first. Also: a submitted line that
names no option should answer the **marked row** and hold the words
(app.rs:3983-4000) — leticl answers nothing (editor.lisp:109-113).
**Reference:** app.rs:3447-3498. **Change:** `src/editor/`.

### G10 — `ctrl-c` means the wrong thing three ways · **S**
**What.** It does not clear a non-empty composer, it opens the quit card on the
**first** press rather than the second within a second, and `%normal-key` has no
tap counter at all (editor.lisp:422-434).
**Why it matters.** Muscle memory. `ctrl-c` to clear a half-written paragraph
currently offers to quit; `/help` and the hint bar both promise the reference's
behaviour (panes.lisp:164, chrome.lisp:358).
**Reference:** editor.rs:466-484, `QUIT_WINDOW_MS` editor.rs:213. **Change:**
`src/editor/`, plus a `*ctrlc-at*` beside `*esc-at*` in `src/chrome/`.

### G11 — `ctrl-c` does not close a pane, a picker or the secret card · **S**
**What.** The pane arm (editor.lisp:241-325), `pick-key-event` (panes.lisp:1275-1302)
and the secret arm (editor.lisp:149-168) have no `:ctrl` case, so `ctrl-c` falls
through and opens the quit card instead.
**Why it matters.** With a password prompt up there is **no way to refuse it** —
Esc works (editor.lisp:163) but Ctrl+C, the key a person reaches for, does not.
**Reference:** app.rs:3003-3011, 3273, 3306, 3321, 3379. **Change:** `src/editor/`,
`src/panes/`.

### G14 — the pane chords open but never close · **S**
**What.** `ctrl-s/p/g/q`, `/help`, `/status`, `/config`, `/jobs` all open; pressing
the same chord again does nothing, because the pane arm never sees a `:ctrl` key.
**Why it matters.** Every one of these is a toggle in the reference and reads as a
toggle. Closing by Esc only is a second thing to remember per pane.
**Reference:** app.rs:3071-3137, 4503-4566. **Change:** `src/editor/` (let the
global chords run ahead of the pane arm — which also closes **G18**).

### G18 — the global chords are unreachable under a pane · **S**
**What.** The reference runs `ctrl-r/t/x/l/s/p/g/q/o`, page and wheel **before**
any view (app.rs:3017-3245). leticl runs them last, inside `%normal-key`, so a
pane swallows them (editor.lisp:232-325).
**Why it matters.** `ctrl-l` cannot repaint a torn screen while a pane is up, and
`ctrl-o` cannot background a command while you are reading the jobs list.
**Change:** `src/editor/` — hoist the `:ctrl` global arm above the pane cond.
Fixes G14 in the same move.

### G3 — paste markers are not unique and the ledger is immortal · **S**
**What.** `%paste-marker` keys on the line count alone (editor.lisp:642-643), so
two 12-line pastes in one prompt produce the **same** marker; `expand-pastes`
replaces every occurrence with one of them (editor.lisp:659-674). `*paste-ledger*`
is never cleared (editor.lisp:580-586).
**Why it matters.** Silent data corruption in the one path that exists to carry
large text faithfully. Two stack traces pasted into one prompt become the same
stack trace twice.
**Reference:** editor.rs:564-566 (`#N`), 475 and 596 (cleared). **Change:**
`src/editor/` — number the markers, clear the ledger in `%submit-line`. Add the
byte threshold (`PASTE_BYTES` = 800, editor.rs:217) while there.

### G5 / G7 / G8 — the composer's motion and redo · **M**
**What.** No vertical motion inside a multi-line prompt (`↑`/`↓` always walk
history, editor.lisp:380-387); no word-left/word-right (`alt+b`/`alt+f` and
`ctrl-←`/`ctrl-→` are dropped at editor.lisp:392 and keys.lisp:74-75); no redo.
`ctrl-a`/`ctrl-e`/`home`/`end` go to the buffer's ends, not the line's
(editor.lisp:509-515).
**Why it matters.** leticl already supports multi-line prompts (`alt+enter`), and a
multi-line prompt you cannot navigate is a prompt you retype. `/help` promises
*"↑ ↓ move inside the prompt"* (panes.lisp:164).
**Reference:** editor.rs:362-371, 382-389, 441-454, 500-516, 687-758; decode at
term.rs:738-742, 773-780. **Change:** `src/keys.lisp` (read the CSI modifier
parameter; map `alt+b/f/z` and `alt+backspace`), `src/editor/`.

### G19 — the peek pane's arrows and Enter do nothing · **S**
**What.** `:peek` is in the generic pane list but `pane-row-count` returns 0 for it
(editor.lisp:735-750), so `move-cursor` is a no-op, and `:peek` is not in the Enter
`case` (editor.lisp:275-321). The hint bar says *"arrows scroll · enter re-reads"*
(chrome.lisp:369).
**Why it matters.** A hint bar that names two keys and means neither. PgUp/PgDn and
the wheel do scroll it, so the feature is one arm away.
**Reference:** app.rs:3255-3280. **Change:** `src/editor/`.

### G20 — Enter on the jobs pane posts `/job ID` into the conversation · **M** · CLOSED in `b7a2620`
**What.** `editor.lisp:848-854` opens the `:job-out` overlay and sends
`ClientFrame::ReadJobOutput`; the answer arrives as `SessionEvent::JobOutput` and
`apply-event` folds it into the overlay that asked (`session.lisp:1419-1446`). That is
precisely what the reference's operator rejected on 2026-09-20 (*"im not shown the
job output im brought back to the main conversation with /job <id> posted"*).
**This row said MISSING from 2026-09-20 23:37 until 2026-09-22**: it was measured at
`7c2c6fc` and the fix landed in `b7a2620` twenty-three minutes later, and nothing
re-measured it. The measurement is in `panes.md` G4 — a live daemon, a real finished
job, and the pane. **Change:** none. *(`↑↓` clamp here where the reference wraps — see
the table above; that is G2's shape, not this row's.)*

### G13 — `ctrl-t` does not open a payload view · **M**
**What.** The fold flips (editor.lisp:462) but no row gets an offset, so a payload
past its first screenful stays unreachable and the seam's `… +N lines` points at
nothing.
**Reference:** app.rs:3023-3046 (the fold opens the newest payload row) and
3412-3445 (Esc closes, ↑/↓/PgUp/PgDn page by 10). **Change:** `src/editor/`,
`src/cards/`.

### G15 — Tab does not cycle and there is no completion row · **S**
**What.** `%complete` inserts only on a unique prefix and otherwise writes the
candidates to the status line (editor.lisp:118-134); it has no whitespace guard, so
`/mode x` + Tab silently does nothing; and leticl draws no live completion row.
**Why it matters.** `/help` says *"more tabs walk the matches"* (panes.lisp:164).
**Reference:** app.rs:4292-4324 (cycle, `completion` triple, the `no /command
starts with` message), 4342-4358 and 5078 (the row). **Change:** `src/editor/`,
`src/chrome/` or `src/render/`.

### G9 — the esc-interrupt arming is never disarmed · **S**
**What.** `*esc-at*` is set by Esc and cleared only by a second Esc
(editor.lisp:403-411). The reference clears the counter on **any** other key
(editor.rs:304-306).
**Why it matters.** Press Esc, type a paragraph, press Esc four seconds later — the
turn is interrupted. And the hint bar shows *"esc again to interrupt"* the whole
time (chrome.lisp:351-355).
**Change:** `src/editor/` — clear `*esc-at*` at the top of `%normal-key` for
every non-`:esc` type.

### G1 — a fast `esc esc` decodes as Alt+Esc and is eaten · **S**
**What.** `read-key` sees ESC, polls 60 ms, gets the second ESC, and falls to
`(t (list :type :alt :ch next))` (keys.lisp:157); the `:alt` arm drops anything but
Return (editor.lisp:392).
**Why it matters.** The reference names this exact trap and guards it
(term.rs:707-711). Rare for a slow double-tap; certain for a fast one, and the one
key that stops a runaway turn.
**Change:** `src/keys.lisp` — `ESC` after `ESC` returns `(:type :esc)` and leaves
the second byte to the next `read-key`.

### G12 — `ctrl-d` quits with text in the composer · **S**
**What.** editor.lisp:435 sets `head-running` to nil unconditionally.
**Reference:** editor.rs:485-491 — quit only on an empty composer.
**Change:** `src/editor/`.

### G23 — `/reseat summarise` silently re-seats without summarising · **S**
**What.** `%command` splits the verb, binds `rest` and then ignores it; the frame
carries no `summarise` (commands.lisp:145-148).
**Why it matters.** The operator asks for the destructive variant by name and gets
the other one, with no word either way. The reference says which one ran
(app.rs:4596-4607).
**Change:** `src/commands/`, and the frame in `src/protocol/` (see
`wire.md`).

### G24 — `/s` and `/i` reach the daemon instead of the head · **S**
**What.** commands.lisp has `quit|q`, `help|h|?`, `status|stats`, `think|r`,
`verbosity|v` but not `sessions|s` or `interrupt|i`; the catch-all forwards them.
**Reference:** app.rs:4443, 4567. **Change:** `src/commands/` — two `member`
clauses. While there: the reference **names** an unknown verb
(app.rs:4671) where leticl forwards everything, so `/hlep` becomes a daemon
round-trip instead of a sentence.

### G6 — the queued-prompt recall is on the wrong key · **S**
**What.** leticl puts recall-and-withdraw on `ctrl-u` (editor.lisp:436-447), which
also means kill-to-start; the reference puts it on `↑` with an empty composer at the
tail (app.rs:3851-3861).
**Why it matters.** Two meanings on one chord, and the one key readline taught for
"the previous entry" does not do it.
**Change:** `src/editor/`. Depends on G5 (vertical motion) landing first, so
`↑` has a defined fall-through order.

### G22 — `o` does not switch into a subagent · **S**
**What.** The subagent pane's `:char` arm reads only `q` (editor.lisp:323-324), and
its Enter has no `opening` guard (editor.lisp:283-291) — the pane's own text says
*"o switches into it"* in the reference (app.rs:6835).
**Reference:** app.rs:3677-3706. **Change:** `src/editor/`. Subsumed by G2.

### G25 — history is uncapped, undeduplicated and does not stop on an edit · **S**
**What.** editor.lisp:533-550. No cap, no consecutive-duplicate drop, no
"navigation stops once a recalled entry is edited" rule, and empty Enters are
pushed (editor.lisp:87 runs before the empty check at 94).
**Why it matters.** The edit-stops rule is the one that prevents losing an edit to a
keystroke; the rest is hygiene that shows up after an hour of use.
**Reference:** editor.rs:519-548, 591-593, 606-610, 219. **Change:** `src/editor/`.

### G16 — Tab on a non-todos pane clears `head-dirty` · **S**
**What.** editor.lisp:263-270: `(when (not (eq mode :todos)) (setf (head-dirty head) nil))`.
The comment above it says Tab "does what enter does" on every other pane; the code
suppresses the next repaint instead.
**Change:** `src/editor/` — one line.

### G17 — no click on the mode/model picker card · **S**
**What.** The click arm tests `head-mode` (editor.lisp:209-211) but the mode/model
picker runs with `head-mode` = `:normal` and `*pick-open*` set (panes.lisp:1149-1158),
so a click falls through to `%normal-key` and is dropped.
**Reference:** app.rs:3639-3651. **Change:** `src/editor/` or
`pick-key-event` in `src/panes/`.

---

## Differences to keep

**The composer's state lives in globals, not struct slots** (editor.lisp:554-586).
A `defstruct` layout change is a hard error in this SBCL, and a layout change means
a restart — the one thing a live head must not need (HACKING.md). There is one
composer per process, so a `defvar` each costs nothing and pushes over the eval
socket. Keep.

**A 16-deep kill ring instead of one kill slot** (editor.lisp:561-568 vs
editor.rs:228). `ctrl-k`, some editing, `ctrl-y` is the common shape and a single
slot loses the first kill. The key's behaviour is identical for one yank, so this is
a strictly larger capability behind the same chord. Keep, and do not add a
`ctrl-alt-y` to expose the rest until somebody asks.

**Folds persist to `head.toml`** (prefs.lisp:120-130). The reference's own header
records this as a defect it has: the choices *"used to live in the process and die
with it"*. leticl fixed it. Keep.

**The paste line count does not count the trailing newline** (editor.lisp:629-640).
The reference's `matches('\n') + 1` says 301 for 300 newline-terminated lines.
leticl's marker tells the truth in the one number the marker exists to carry. Keep —
and note it means the two heads' markers will differ by one on the same paste, which
is expected and not a rendering bug.

**Nine local verbs the reference has no word for** — `/subagents`, `/todos`,
`/peek`, `/resume`, `/promote`, `/models` (commands.lisp:100-169). Each names a
thing that is otherwise chord-only or unreachable, each prints a usage line when
given nothing, and none of them shadows a daemon verb. Keep.

**A timer-based ESC disambiguation rather than a held tail** (keys.lisp:14, 42-59).
leticl reads a character stream, not 100 ms buffers, so it has no "incomplete tail"
to carry; the 1000 ms CSI wait is the right answer for a byte split by ssh or a pty.
Keep the mechanism; fix only the `ESC ESC` case (G1).

**`%command` forwards unknown verbs instead of refusing them** (commands.lisp:172-176).
This is arguably better than the reference's whitelist: a daemon that grows a verb
works immediately in leticl and needs an app.rs edit in the reference. The cost is
that a typo makes a round trip. Keep the forwarding; consider naming the miss when
the daemon answers (that is `wire.md`'s call, not this one).

---

## How each gap should be tested

Unit tests go in `tests/tests.lisp`, which already has `key-from`
(tests.lisp:224), `%press` (tests.lisp:1838), `%make-head`, `%on-head`
(tests.lisp:1265) and `%decision-with` (tests.lisp:1904). "Live-head" means
`scripts/tui-eval` against a running head and `scripts/compare-heads` against
letibot at the same size.

| gap | the assertion that proves it closed |
|---|---|
| G1 | `(read-key (make-string-input-stream (format nil "~C~C" +esc+ +esc+)))` returns `(:type :esc)`, **and** a second `read-key` on the same stream returns `(:type :esc)` — two keys from two bytes, not one alt |
| G2 | On a head with `head-mode` `:picker`, `%handle-key` with `(:type :char :ch #\2)` leaves `head-mode` `:picker` and puts `"2"` in `(composer-buffer (head-composer h))`. Then Enter switches to session 2. Same for `:todos` and `#\q`: `q` types a `q` when the composer is non-empty |
| G3 | Two `composer-insert-paste` calls with different 12-line texts produce two **different** markers; `(expand-pastes (composer-buffer c))` contains both texts in order. After `%submit-line`, `*paste-ledger*` is `nil` |
| G3 (bytes) | A 3-line, 900-byte paste collapses to a marker |
| G5 | With `"aaa\nbbb"` in the composer and the cursor at the end, `↑` puts the cursor in the first line at the same column and does **not** change the buffer; a second `↑` from the first row walks history |
| G6 | On a head with `head-queued` holding one prompt and an empty composer at `head-scroll` 0, `↑` fills the composer with it and a `withdraw_prompts` frame is on the outbox; with a non-empty composer `↑` walks history and sends nothing |
| G7 | `(read-key …"\e[1;5D")` → `(:type :word-left)`; `"\eb"` → the same. With `"one two three"` and the cursor at the end, one `:word-left` puts the cursor at index 8 |
| G8 | `"abc"`, `ctrl-z`, `alt+z` → the buffer is `"abc"` again |
| G9 | `%press` esc, then `#\x`, then esc within 5 s → **no** interrupt frame; `(status-line …)` does not contain `esc again to interrupt` after the `x` |
| G10 | Composer `"half a thought"`, idle: `ctrl-c` empties it and `head-quit-open` stays nil. Empty composer, idle: one `ctrl-c` leaves `head-quit-open` nil; a second within 1000 ms sets it; a second after 2000 ms does not |
| G11 | With `head-secret-req` set, `ctrl-c` sends a `secret` frame with `:secret nil` and clears the card. With `head-mode` `:jobs`, `ctrl-c` sets it to `:normal`. With `*pick-open*` `:mode`, `ctrl-c` clears it and `head-quit-open` stays nil |
| G12 | Composer `"x"`: `ctrl-d` leaves `head-running` true. Empty: it sets it false |
| G13 | `ctrl-t` opening the fold sets a payload selection to the newest row that has one; `↓` advances its page by 10; `esc` clears it and leaves `head-mode` `:normal`. Live-head: `compare-heads` is byte-identical with a long tool payload open |
| G14 / G18 | `ctrl-s` twice leaves `head-mode` `:normal`. With `head-mode` `:jobs`, `ctrl-r` flips `:show-reasoning` and `ctrl-l` sets `head-full-repaint` — the pane is still `:jobs` |
| G15 | Composer `"/re"`: Tab gives `"/rename"`, a second Tab `"/resync"`, a third `"/resume"`, a fourth back to `"/rename"`. `"/mode x"` + Tab is a no-op. `"/zz"` + Tab sets a status note naming the miss. Live-head: the completion row is drawn above the composer while `/re` is typed |
| G16 | With `head-mode` `:jobs` and `head-dirty` T, Tab leaves `head-dirty` T |
| G17 | With `*pick-open*` `:mode` and a drawn card, `(:type :mouse :kind :press :y R)` for the row of choice 3 sets `head-picker-sel` to 2 and takes nothing |
| G19 | With `head-mode` `:peek`, `↑` increases the peek scroll and Enter sends a `peek` frame for the same session id |
| G20 | With `head-mode` `:jobs`, Enter on a row leaves the mode a job-output view (not `:normal`), sends a read-output frame, and sends **no** `slash` frame. Live-head: `compare-heads` matches letibot with a job's output open |
| G21 | `%decision-with` open **and** `"some prose"` in the composer: `↓` moves `head-decision-sel` and leaves the buffer untouched; Enter answers the marked row, holds the line, and says so |
| G22 | With `head-mode` `:subagents` and an empty composer, `o` sends a `switch` frame; Enter on a row whose `:state` is `"opening"` sends nothing and says *"still opening"* |
| G23 | `(%command h "reseat summarise")` puts a `reseat_session` frame with `:summarise t` on the outbox; `(%command h "reseat")` puts one with `:summarise nil`; both say which ran |
| G24 | `(%command h "s")` sets `head-mode` to `:picker`; `(%command h "i")` sends an `interrupt` frame — neither sends a `slash` frame |
| G25 | Submitting `"a"`, `"a"`, `"b"` leaves a history of `("a" "b")`. Enter on an empty composer adds nothing. After `↑` recalls `"b"` and one character is typed, a second `↑` does **not** change the buffer. Fifty-one submissions leave fifty entries |
| whole-surface | A table-driven test that walks every chord in §2 against a head in each of the fourteen contexts in §3 and asserts the arm that claims it — the reference's own defence is that its ladder is one `match`, and leticl's is one `cond`, so the ladder is the unit |
