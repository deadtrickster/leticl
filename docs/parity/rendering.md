# What a turn looks like on screen — leticl ↔ letibot

**Reference**: `~/Projects/letibot/letibot` @ `8af671e3467ce0a139ba25d99a18378ba39c910b`
(verified with `git rev-parse HEAD`, 2026-09-20). Every `app.rs`/`render.rs`/
`card.rs` line number below is a line in **that** commit; `.claude/worktrees/*`
copies in the reference tree are stale and were not read.

**Subject**: `~/Projects/leticl` @ `dc62ddf` — the tree as it stood when this pass
started. **It moved underneath the pass**: `4e32354` landed while this was being
written and touched `src/chrome.lisp`, `src/render.lisp` and `src/panes.lisp`.
Everything below was read at `dc62ddf`, and the two findings `4e32354` already
changes are marked inline (§4's stall row, and gap 19). Re-read the function
before trusting a `src/` line number — a citation is a pointer, not a
specification.

**Scope**: the transcript row, markdown, diff/highlight, the frame, styles and
width. Keys, commands, the wire and the panes are covered elsewhere.

**Method**: both files read function by function; file:line on both sides for
every claim. Two live captures (`tmux capture-pane -e -t 1:3` / `-t 1:7`) and one
`scripts/compare-heads` run were taken read-only to check claims about the frame.
No key was sent to either head, nothing was restarted, no source was modified.

---

## Summary

**Where the two are byte-identical today.** On the screen both heads are
currently showing — a settled conversation, 210×63, no turn running — the frame
furniture matches. `scripts/compare-heads` flags row 1 for one field only
(`$0.5602`, this head's own spend since attach, which the reference head has and
ours has not yet accumulated); the rest of the diff is the two heads sitting at
different scroll and fold positions, not a rendering difference. The header's
escape structure is identical segment for segment
(`\e[34m▌ \e[1m\e[39m{title}\e[0;2m  {path}\e[0m{pad}\e[2m{tail}`), the composer
box, the hint bar and the `┃` reasoning rail all match, and the archived
round-3/round-4 measurements (60 of 63 rows, then every pane row) still hold.

The parts that are genuinely byte-identical *by construction*, not by luck:

- **The width tables.** `*zero-width-ranges*` and `*wide-ranges*`
  (`src/width.lisp:41-60`, `:62-102`) are the same range sets as
  `crates/ui/src/width.rs:216-237` and `:241-282`, machine-diffed, with zero
  ranges on either side only. `char-width`, `is_control`,
  `is_regional_indicator` and `skip_escape` all agree.
- **Seventeen of the twenty-two `Role`s.** `Faint`, `Strong`, `Heading`,
  `Subheading`, `UserAccent`, `UserBlock`, `Success`, `Pending`, `Failure`,
  `Reasoning`, `Code`, `Added`, `Removed`, `Keyword`, `StringLit`, `Comment`,
  `TypeName` all emit the same SGR attributes (modulo leticl's reset prefix, §5).
  `Plain` and `Emphasis` match in rendition but not in bytes; only `Attention`,
  `NumberLit` and `FuncName` are genuinely different colours.
- **The card vocabulary**: `Verb::of` and `Verb::label` (`crates/ui/src/card.rs:125-156`)
  against `*verb-map*`/`verb-label` (`src/cards.lisp:404-437`) — the same 25 tool
  names, the same 14 tense pairs, the same "an unknown name keeps its own name".
- **`display_target`**, the markdown block→role mapping, the diff chrome roles,
  and the user block's bar/padding/timestamp arithmetic.
- **The unified diff.** `src/diff.lisp` is a line-for-line port of `diff.rs`:
  the same Myers with the same `DEFAULT_MAX_D`, the same hunk stitching, the
  same gutter arithmetic, the same `@@` header, the same background-only
  tinting, the same row budget and the same two disclosure strings.
- **The markdown *renderer***: `render_block_with`, `table_lines`, `fit_columns`
  and `render_bounded` are close ports, down to the `─┼─` rule and the
  `… {n} lines elided …` seam.
- **The syntax role map**: `role_for_capture` is reproduced byte for byte in the
  shim (`native/hl/src/lib.rs:105-122`).

**Where they are not.** Grouped by kind:

1. **Row kinds the subject does not draw at all**: `SegmentMark`
   (`app.rs:10042` vs `src/cards.lisp:901`) and the payload window / paging view
   (`app.rs:9968-10036` — a whole mechanism with no counterpart).
2. **Row kinds drawn differently**: `System` (`◦` yellow vs `system (Origin)` +
   dim body), the unanswered-call row (`→ Read x` dim vs
   `→ Read x · no result` in `Attention`), `fold_cells` (the subject keeps the
   marker line, the reference replaces the block with a one-line note).
3. **The live card is missing three of its four body parts**: the §8.3 bytes
   disclosure, the settled decision, and `head_tail`'s budget over the body.
4. **The frame has no fit ladder.** The reference gives up chrome rows in a
   defined order on a short screen (`app.rs:5094-5126`) and drops the gutter
   below 40 columns (`app.rs:5325`); leticl does neither.
5. **Wrapping has no wide-cluster rule and two divergent breakpoint finders** —
   the single biggest correctness gap on this surface.
6. **Payload bytes are not sanitised.** The reference maps every control
   character to a space (`app.rs:9712`); leticl elides escapes entirely, so a
   payload carrying one renders narrower than the reference's.
7. **The markdown *lexer* leaks markers.** `***both***` reaches the screen with
   its asterisks (`src/markdown.lisp:78-87`); a fence inside a quote or on a
   list marker's line is never found; a 4-backtick fence is closed by an inner
   3-backtick line; autolinks keep their `<>`; indented code blocks are mangled
   into prose.
8. **There is no incremental layer and no cache.** `IncrementalMarkdown` and
   `BlockCache` have no counterpart, so every visible message is re-lexed and
   re-rendered on every frame, and every visible fence is re-highlighted through
   the FFI on every frame.
9. **Intra-line diff emphasis is dead code.** `%pair-rows` binds its addition
   run's start *after* consuming the run (`src/diff.lisp:297-298`), so the
   pairing branch is never taken. Screen parity is accidental: both reference
   call sites pass `intra_line: false` anyway.
10. **The split diff is a reduced port**: it truncates where the reference
    wraps, has no role tint, no syntax colour, no hunk header, no `no change`
    row and no degraded banner, and it *refuses* at a narrow width where the
    reference degrades.

The full per-section tables follow. Sizes for closing each gap are in
**Gaps worth closing**.

---

## 1. The transcript row

Reference: `fn item_lines` (`crates/tui/src/app.rs:9509`), `enum RowClass`
(`:9333`), `fn user_block` (`:8933`), `fn call_card` (`:8731`), and
`crates/ui/src/card.rs` (`Card`, `Verb`, `Phase`, `Outcome`, `Budget`,
`head_tail`, `reasoning`).
Subject: `src/cards.lisp`.

### 1.1 Dispatch and row class

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `RowClass::{Speech,Activity,Other}` — the one question the layout asks of a row's neighbours | `app.rs:9333-9341` | `:speech`/`:activity`/`:other` | `src/render.lisp:194-205` | SAME |
| Assistant class: `Speech` if it spoke, `Activity` if it only acted, else `Other` | `app.rs:9659-9665` | `:speech` if text non-blank else `:activity` — never `:other` | `src/render.lisp:202-203` | DIFFERS-minor: an assistant row with no text and no unanswered call is `Activity` here and `Other` there. Both are dropped by the blank-row test before the class is used, so no visible effect today. |
| A body that has not arrived draws **nothing** | `app.rs:9525-9542` | draws `[{kind} — content not loaded]` in red | `src/cards.lisp:813-815` | **DIFFERS**: this is the exact `/reseat` failure the reference removed — "thousands of them at once", *"insane amount of grainess with s- and whatever tool lines"*. |
| Row is rendered with an `ItemCtx` carrying targets, answered set, `drawn_live`, elapsed, edit, decision, `diff_split`, `payload_view` | `app.rs:9348-9380` | the same facts, from `*call-targets*` / `*answered-calls*` / `*item-facts*` defvars + the `prefs` plist | `src/cards.lisp:170-300`, `:522-535` | SAME in effect; `drawn_live` has no counterpart (see 1.4) |

### 1.2 `User`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `▌` in `Role::UserAccent` (blue), one unpainted space, message in `Role::UserBlock` (reverse), padded to `w-2` | `app.rs:8938,8960-8963` | identical segment shape | `src/cards.lisp:844-850` | SAME |
| First row's width shares with the stamp: `w - 2 - width(stamp) - (stamp?1:0)`, floored at 8 | `app.rs:8941-8942` | same arithmetic | `src/cards.lisp:835-836` | SAME |
| Timestamp `HH:MM:SS` local, **empty when `ts == 0`** | `app.rs:9053-9067` | same, via `decode-universal-time` (local) | `src/cards.lisp:1240-1252` | SAME |
| Empty wrap ⇒ one empty row | `app.rs:8943-8945` | same | `src/cards.lisp:837` | SAME |
| Parts joined with **`" "`**; `Image` → `[image {media_type}]`, `FileRef` → `[file {path}]` | `app.rs:8550-8558` | text parts only, joined with **no separator**; non-text parts render as `""` | `src/session.lisp:426` | **DIFFERS**: a two-part message runs its parts together, and an attached image or file reference is invisible. |
| `fold_cells`: the screen block is **replaced** by `· {rows} rows of this screen ({size}) went with this message` on its own line after the words | `app.rs:8980-9001` | keeps the words, keeps the `⟦screen WxH …⟧` marker head, appends `" …"`, keeps everything after the close marker | `src/cards.lisp:361-376` | **DIFFERS**: different text, different shape, and leticl keeps text that followed the block where the reference drops it. |

### 1.3 `Reasoning`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Header `{▸\|▾} {word}{dim " · N lines · ctrl-r"}` | `app.rs:8102-8133` | same shape, same strings | `src/cards.lisp:744-764` | SAME |
| Word: `Thinking…` in `Role::Reasoning` while running; `Thought` in `Role::Strong` settled; `Thought for 4.2s` when a duration exists | `card.rs:551-562` | `Thinking…` `(:dim t :italic t)` / `Thought` `(:bold t)` — **no `for {duration}` form at all** | `src/cards.lisp:760-762` | DIFFERS: a live turn's `Thought for 4.2s` is unreachable. A *settled* row has no duration on either side, so the visible transcript matches. |
| Screen-line count measured at `w = cfg.width.max(20)` — the **full** width, before the step | `app.rs:8109-8114` | measured at `w = max(20, cols - activity-indent)` — two columns narrower | `src/cards.lisp:754-757` | **DIFFERS**: the two counts diverge for any line whose width falls between `w-2` and `w`. The number on the header is the only thing this changes. |
| Rail: `Decor.prefix = "{step}{Faint ┃} "` with the space **outside** the `┃`'s paint and **inside** the reasoning block's open | `app.rs:8084-8087`, `render.rs:660-667` | `(cons "┃ " '(:dim t))` — the space carries dim **without** italic | `src/cards.lisp:774` | DIFFERS-one-cell: the space after the rail is dim in leticl and dim+italic in the reference. Invisible to the eye, visible to `compare-heads`. |
| Body wrapped at `width - (activity_indent + REASONING_RAIL_WIDTH)`, min 20 | `app.rs:8062-8068` | `(max 20 (- cols (activity-indent cols) 2))` | `src/cards.lisp:781` | SAME |
| Body budget `reasoning_lines = 8` | `render.rs:88-95` | `+reasoning-lines-budget+ 8` | `src/cards.lisp:741` | SAME |
| Span inside the block **switches** to the span's role and restores the block (`Painter::inside` + `rebase_resets`) | `card.rs:584-592`, `style.rs:264-269` | `(append (cdr seg) '(:dim t :italic t))` — the block style is **merged into** the span | `src/cards.lisp:776-779` | **DIFFERS-composition**: a code span inside reasoning is cyan there and cyan+dim+italic here. |
| `card::reasoning`'s own `head_tail` over the body (first/last/`… +N lines`) | `card.rs:576-579` | `markdown-lines … :limit 8` — `render-bounded`, not `head_tail` | `src/cards.lisp:781-782` | DIFFERS-mechanism: see §2 on `render_bounded`. |

### 1.4 `Assistant`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Prose through the markdown cache at `cfg.budget.body_lines` (40), at the body's own column | `app.rs:5581-5589` | `markdown-lines … :width cols :limit 40` | `src/cards.lisp:871-873` | SAME (modulo §2) |
| A call **already answered** draws no proposal row | `app.rs:9608-9613` | same, via `*answered-calls*` | `src/cards.lisp:877` | SAME |
| A call the **live pane is drawing** (`drawn_live`) also draws no row | `app.rs:9608` | no counterpart | — | **MISSING**: while a turn runs, a call is drawn by both the assistant row and the live card. The reference's own note: `→ Read foo.rs · no result` above `◐ Reading foo.rs` is "both a duplicate and, while the call is still running, false". |
| The surviving row: `→ {verb} {target} · no result`, whole line in `Role::Attention` (`\e[1;33m`), prefixed by `" ".repeat(ind)` and `trim_to(_, width)` | `app.rs:9614-9645` | `"  → "` dim + verb dim + `" {target}"` plain; **no `· no result`**, no `Attention`, indent hard-coded to 2, no truncation | `src/cards.lisp:878-883` | **DIFFERS** four ways. The missing `· no result` is the one that matters: the reference says "a row that looks like every other tool row and quietly has no output is the shape a person reads straight past. It is the only thing this row now means." |
| Empty target ⇒ ` ({call_id})` | `app.rs:9628-9632` | omitted entirely | `src/cards.lisp:880-882` | MISSING |
| `ctrl-x` raw form: `raw_call_lines` under the row, `┌─ raw tool call · ctrl-x` / `│ ` + `Role::Code` / `└─` | `app.rs:8715-8729`, `:9652-9654` | the live turn has a raw block (`src/cards.lisp:1130-1135`) but with no fence and `"    "` + dim; the **settled** row has none | `src/cards.lisp:1130-1135` | DIFFERS + MISSING on the settled row |

### 1.5 `ToolResult` — the header

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `flat = payload.lines().map(without_control)` — **every control char becomes a space** before anything measures it | `app.rs:9712` | no sanitisation; escapes are consumed as zero-width clusters and elided by the painter | `src/cards.lisp:607`, `src/width.lisp:347-348`, `src/cells.lisp:213-215` | **DIFFERS**: an `\e[?1002l` in a payload renders as ` [?1002l` (8 columns) there and as nothing here. leticl is *safe* — the escape never reaches the terminal — but the row's visible width differs. The reference measured 44 such rows and 20 mode strings in the operator's own store. |
| Envelope lines dropped, matched by shape: trimmed, `starts_with("<<<") && ends_with(">>>") && len > 6` | `app.rs:7925-7928` | left-trim, `starts_with "<<<"` only | `src/cards.lisp:491-499` | DIFFERS: a payload line that merely *opens* with `<<<` is dropped here and kept there. |
| `mark = ▾/▸`, `Faint` (or `Failure` when bad) | `app.rs:9719,9800` | same | `src/cards.lisp:601,621` | SAME |
| ` {verb} ` `Faint`; subject `Role::Plain` (**no bytes at all**, the brightest thing on the row) | `app.rs:9801-9802` | `(cons subject nil)` → style index 0 | `src/cards.lisp:622-623` | SAME rendition; leticl emits `\e[0m` where the reference emits nothing (§5) |
| ` · {word}` in `outcome_role` (`Faint` when ok, `Failure` when not); `{took}` `Faint` | `app.rs:9803-9804` | same | `src/cards.lisp:624-625` | SAME |
| `outcome_word`: ok / **ABSTAINED** / failed / **REFUSED** / timeout / not run / **STILL RUNNING** | `app.rs:8890-8902` | `%outcome-word`: same seven | `src/cards.lisp:548-556` | SAME |
| `outcome_why`: `None` for Ok and Timeout; Denied → `the call was denied ({req_id})`; Backgrounded → ``as `{handle}` — {next}`` | `app.rs:8905-8914` | same four arms | `src/cards.lisp:537-546` | SAME |
| `BIG = 40`: line count `Strong` at or above it, `Faint` below | `app.rs:9766-9774` | `+big-output-lines+ 40` | `src/cards.lisp:475,613` | SAME |
| Tail measured first, subject given the rest: `tail_cols = 3 + width(word) + width(took) + 3 + 6 + len(count)`, `lead = "{mark} {verb} "`, subject floored at 8 | `app.rs:9789-9799` | identical arithmetic | `src/cards.lisp:617-620` | SAME |
| `shorten_subject`: a path (has `/`, no `* ? { [ "`) loses its **left at a `/` separator** — `ellipsise_left` walks `match_indices('/')` for the longest suffix that fits, falling back to a **width**-counted character cut; anything else `trim_to`s the right | `app.rs:9123-9138`, `:9074-9109` | same path/prose test, but the path branch is a plain `(subseq subject cut)` on **character length**, not at a separator and not width-counted; the prose branch is also character-indexed | `src/cards.lisp:501-520` | **DIFFERS**: this is the `…/1f0655c6-…/scratchpad` shape the reference fixed — "two lies in twenty-two columns", and neither segment can be pasted back into a shell. On any non-ASCII path it also overshoots the column budget. |
| One-line result inlaid on the header when `!bad && len==1 && edit.is_none() && strip_gutter(l)` non-empty and it fits | `app.rs:9811-9833` | identical condition | `src/cards.lisp:669-677` | SAME |
| `strip_gutter`: digits then exactly `"\| "` | `app.rs:9285-9292` | same, `trim_end` is space-only rather than all whitespace | `src/cards.lisp:567-578` | SAME (tab edge case aside) |
| Header truncated with `trim_to(&head, w)` | `app.rs:9826,9847` | `%truncate-segs … w` | `src/cards.lisp:681-683` | SAME shape; `%truncate-segs` goes through the cluster-unsafe `%truncate-width` (§6) |

### 1.6 `ToolResult` — the body

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Reason on its own wrapping line at `w-2`, `"  {l}"`, in `outcome_role`; first sentence when folded or echoed, whole when open and not echoed; `echoed` = first line ≥ 40 chars appearing verbatim in the payload | `app.rs:9852-9897` | identical, including the 40-character rule and `why-folded` | `src/cards.lisp:688-700` | SAME |
| `first_sentence`: cut at `". "`, hard cap 140 chars, `…` appended | `app.rs:7906-7916` | same | `src/cards.lisp:558-565` | SAME |
| `decision_lines`, folded: `  · {allowed\|refused\|cancelled\|not answered}, by {kind identity}` in `Faint` | `app.rs:9387-9413` | same four words, same format | `src/cards.lisp:633-649` | SAME |
| `decision_lines`, open: `decision_detail` at `w-4`, indented 4 — `asked: {summary}`, `{by.kind}: {basis}`, `oracle ({by}, {latency}ms) would {would}: {basis}`, one `oracle cited: {c}` per cite **or** `oracle cited: nothing — it could not ground this in anything you said`, or `no oracle was consulted for this one` | `app.rs:9462-9507` | only `{by.kind}: {basis}`, and only when not echoed in the payload | `src/cards.lisp:650-665` | **DIFFERS/MISSING**: the summary, the whole oracle block, the empty-cites disclosure and the "no oracle" line are absent. The reference's note — "*empty cites is loud*" and "'no oracle was asked' and 'an oracle was asked and said nothing' are different" — has no counterpart. |
| Decision lines are **not** width-bounded in either head | `app.rs:9406` | `src/cards.lisp:649` | — | SAME (both can overrun; the reference's outer `trim_to` at `:10039` catches it, leticl's does not — see below) |
| An edit on an `Edit`/`Write` verb, not bad: `sidediff::render_edit_view` at `w-2`, `context 3`, `line_numbers true`, **`intra_line false`**, `max_rows 60`; then the `truncated` note; then `keep = open ? all : min(8)`; each row prefixed `"  "`; `… +{hidden} diff rows · ctrl-t` | `app.rs:9925-9967` | same shape, same `keep`/`hidden`, same seam string — but `:intra-line t` and the truncated note already carries its own two spaces so it lands at column 4 | `src/cards.lisp:704-716`, `:1009-1013` | **DIFFERS** twice: intra-line emphasis is on in the settled row (off in the reference) and the capped-excerpt note is two columns further in. |
| **The payload window.** `payload_view: Option<(item_id, page)>`; `↑ {page} more lines above · ↑ scrolls up`, a page of `body` rows, `… +{hidden} lines · ↓ pages down · esc closes` / `… end of output · esc closes` when the view is open, `… +{hidden} lines · ctrl-t pages` when it is not | `app.rs:9968-10036` | no view, no page, no offset. Seam reads `… +{N} lines · ctrl-t` | `src/cards.lisp:726` | **MISSING**, whole mechanism. The reference's note: for a 418 KB log the fold reported `… +N lines` and the chord revealed nothing, "because opening the fold changed the *budget*, not the *offset*. There was no offset." |
| Folded shows 1 row + seam; open (or bad with no reason) shows `body_lines` | `app.rs:9981-9997` | `limit = (or open (and bad (null why))) ? 40 : 2`, then `(1- limit)` rows + seam | `src/cards.lisp:722-733` | SAME |
| `… the rest of the reason · ctrl-t` when the payload fit whole but the reason was cut | `app.rs:10033-10035` | same | `src/cards.lisp:732-733` | SAME |
| **Every** emitted line passes `trim_to(&l, w)` before `step_in` | `app.rs:10037-10040` | only the header, the dim body rows and the wrapped reason are bounded; decision rows and diff rows are not | `src/cards.lisp:681,632,698,713` | DIFFERS: a long `by` identity or a wide diff row can exceed `w`. |
| `step_in(out, ind)` — empty rows stay empty | `app.rs:9296-9305` | `step-in-lines` — same rule | `src/cards.lisp:784-800` | SAME |
| `activity_indent`: 2 at ≥60 columns, else 0 | `app.rs:9267-9273` | same | `src/cards.lisp:480-489` | SAME |

### 1.7 `System` and `SegmentMark`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `System` → `dim("system ({origin:?})")` then the text wrapped at `cfg.width`, every line dim; class `Other` | `app.rs:9544-9548` | `◦ ` yellow + text yellow, wrapped at `cols`; class `:other` | `src/cards.lisp:896-900` | **DIFFERS**: no origin line, and yellow where the reference is dim. |
| `SegmentMark` → `dim("─── {label} ───")`; class `Other` | `app.rs:10042-10044` | the `case` has no arm; falls to `(t nil)` — the row draws nothing | `src/cards.lisp:901` | **MISSING** |

### 1.8 The live card — `call_card` and `card::Card`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Mark: `○` `Faint` / `◐` `Pending` / `●` `outcome.role()` | `card.rs:393-399` | `○` `(:dim t)` / `◐` `(:fg :yellow)` / `●` outcome-style | `src/cards.lisp:938-940` | SAME (`Pending` is `\e[33m`) |
| Verb `Role::Strong`, in the running tense; target `Role::Plain` | `card.rs:403-407` | `(:bold t)` / `nil` | `src/cards.lisp:955-956` | SAME |
| `Phase::Proposed{note}` tail = note, else `"proposed"` | `card.rs:415-421` | same | `src/cards.lisp:952` | SAME |
| `Phase::Running` tail = `[duration(elapsed), note]` | `card.rs:422-427` | same | `src/cards.lisp:948` | SAME |
| `Phase::Finished` tail = `[duration]` + (when not Ok) `[word, reason]` | `card.rs:428-441` | same | `src/cards.lisp:949-951` | SAME |
| `Phase::Replayed` — **no duration invented** when the snapshot carried no timestamps | `card.rs:442-449`, `app.rs:8783-8792` | `ms` is `nil` when `*call-facts*` has none, so no duration | `src/cards.lisp:943-945` | SAME in effect |
| `display_outcome` maps the wire onto `card::Outcome`: **Timeout → `Failed("timed out")`**, **NotRun → `Failed("not run — {why}")`**, Denied → `Denied("denied, {req_id}")` | `app.rs:8644-8665` | `call-lines` uses the *settled row's* `%outcome-word`/`%outcome-why` | `src/cards.lisp:950-951` | **DIFFERS**: a timed-out live call reads `· timeout` here and `· failed · timed out` there; a not-run one reads `· not run` vs `· failed · not run — {why}`; a denied one reads `· REFUSED` vs `· refused` (`card.rs:203` is lower-case; `app.rs:8897` shouts — the reference draws the *word* differently in the two places on purpose). |
| Outcome role: Abstained / Denied / Backgrounded → `Attention` (`\e[1;33m`); Failed / Interrupted → `Failure` | `card.rs:185-196` | failed/timeout → red; every other bad → `(:bold t :fg :yellow)`; backgrounded elsewhere is cyan | `src/cards.lisp:934-936`, `:386` | DIFFERS-partly; see §5 |
| Tail dropped **whole** when it does not fit, never truncated into an ambiguity | `card.rs:471-478` | same | `src/cards.lisp:960-962` | SAME |
| **Body line 1: the §8.3 bytes disclosure** — `bytes_human(inline)`, or `{inline} of {full} went to the model, the rest is kept — read_spill hash={h}` | `app.rs:8767-8780` | absent | — | **MISSING** |
| **Body: the decision block** — `· {word}, by {who}` and, open, `decision_detail` | `app.rs:8842-8864` | absent from the live card (present only on the settled row) | — | **MISSING** |
| Body: the edit diff **replaces** the body, width `cfg.width - (2 + activity_indent)` | `app.rs:8800-8838` | appended after the header, width `(cols - ind) - 4` | `src/cards.lisp:965`, `:1002` | DIFFERS by 2 columns (`ind` is subtracted twice in effect) |
| `Card::render` applies `head_tail(body, first, last)` with `Budget::for_verb` — Read/List 5/3, Run 2/3, else 10/3, `expanded_max 400` — and indents the body `"  "`, truncating each line to `width` | `card.rs:482-511`, `:276-304` | no `head_tail`, no per-verb budget, no `"  "` body indent, no per-line truncation | `src/cards.lisp:959-965` | **MISSING**: a folded live card with a 60-row diff draws all 60 rows here; the reference draws 10, `… +47 lines`, 3. |
| `Collapsed` mode adds `  … {N} lines`; the fold cycle never expands a running block | `card.rs:484-491`, `:92-99` | leticl has one boolean per kind (`:show-tools`, `:show-reasoning`), not three modes | `src/cards.lisp:598`, `:770` | DIFFERS-model: two states, not three. `DisplayMode::Truncated` — "a finished `bash` call should show its last three lines without being asked" — has no counterpart. |
| `head_tail`'s marker: `… +{hidden} lines` in `Faint`, a **separator row** | `card.rs:521-532` | the same string appears at `src/cards.lisp:726` with ` · ctrl-t` appended | — | DIFFERS-string on the live card (leticl's live card has no marker at all) |

### 1.9 The turn footer and queued prompts

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `eos`/`word` ⇒ **no line** | `app.rs:8204-8205` | same | `src/cards.lisp:1044-1046` | SAME |
| `length` / `aborted` / unrecognised ⇒ one yellow line, same three strings | `app.rs:8189-8211` | same three strings | `src/cards.lisp:1047-1055` | SAME |
| `Interrupted` ⇒ `── interrupted: {reason} ({kept})`, yellow | `app.rs:8214-8228` | same | `src/cards.lisp:1056-1060` | SAME |
| `Failed` ⇒ `── FAILED — {error} ({kept})`, **wrapped at `cfg.width`**, each line `warn_line` (red) | `app.rs:8232-8245` | one line, `(:fg :red :bold t)`, **not wrapped** (`cols` is declared ignored) | `src/cards.lisp:1036`, `:1061-1065` | **DIFFERS**: the reference's own rule is "wrapped rather than truncated, because the reason is the whole content of the event". A long error is cut at the frame edge here. |
| `queued_lines`: `{▌} {Pending "queued · "}{Faint text}`, continuation rows indented `width("queued")+3`, wrapped at `w - 2 - 6 - 3` | `app.rs:9017-9046` | `› ` bright-cyan bold + first line dim + `  · queued` dim; no wrap, no bar, tag at the end | `src/cards.lisp:1082-1087` | **DIFFERS**: different glyph, different colour, tag on the wrong side, multi-line prompts show only their first line. |
| `queued_lines` folds `/cells` too, so the pending row matches the user row it becomes | `app.rs:9023-9024` | no fold | `src/cards.lisp:1084` | MISSING |

---

## 2. Markdown

Reference: `crates/tui/src/markdown.rs` (the `Block` model, the lexer,
`IncrementalMarkdown`) and the markdown half of `crates/tui/src/render.rs`
(`render_block_with`, `table_lines`, `fit_columns`, `render_bounded`,
`BlockCache`, `Decor`, `paint_runs`).
Subject: `src/markdown.lisp`; callers at `src/cards.lisp:781-782,872-873,1124`.

**The structural fact.** The reference's engine is a tree-sitter two-pass parser
(`Lang::Markdown` over a fence-masked source, `Lang::MarkdownInline` per inline
range) driven by a streaming window and cached per frame. leticl is a
hand-written line lexer plus a hand-written character scanner, re-run from
scratch every frame. Where the two agree they agree because the *renderer* was
deliberately ported from `render_block_with`/`table_lines`/`fit_columns`/
`render_bounded`; the *lexer* and the *incremental layer* are not ports at all.
Budgets match: 40 body lines, 8 reasoning lines (`src/cards.lisp:737,741` vs
`render.rs:88-95`).

### 2.1 The block model

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| 7 `Block` variants, run-bearing | `markdown.rs:66-121` | the same 7 as plists, but text fields are **raw strings** parsed inline at render time | `src/markdown.lisp:247-255,606-671` | SAME set, DIFFERS-timing |
| ATX heading, levels 1–6 | `markdown.rs:990-1003` | `%heading-of` — run of `#`, `1≤level≤6`, space required | `src/markdown.lisp:282-287` | SAME |
| **Setext** heading (`Title\n====`) → level 1/2 | `markdown.rs:950,993-994` | `====` joins the paragraph; `----` is caught by `%rule-p` | `src/markdown.lisp:289-296,381-384` | **MISSING** |
| Heading render: `{faint #*level} {role runs}`, truncated to `w`; roles Heading/Subheading/Strong | `render.rs:334-350` | identical, `+md-heading+`/`+md-subheading+`/`+md-strong+` | `src/markdown.lisp:44-46,611-620` | SAME |
| Paragraph: lines joined `" "`, wrapped to `w` | `render.rs:351-354,884-896` | same | `src/markdown.lisp:621-625` | SAME |
| **Indented** code block (4 spaces) → a `┌─ code` box | `markdown.rs:971,1161-1177` | a paragraph, and the indent is `string-trim`ed away | `src/markdown.lisp:458-463` | **MISSING** — the code is not merely uncoloured, it is mangled |
| One `List` block per list, items flattened, `start` = the first item's written number | `markdown.rs:82-102,1198-1280` | one `:list` block per run of item lines; each item carries its own `:ordered :number :indent` | `src/markdown.lisp:298-318,437-456` | DIFFERS-model |
| Ordered numbering is `start + i` — `1. / 1. / 1.` renders `1. 2. 3.` | `render.rs:408-414` | the number the model wrote, per item — `1. 1. 1.` | `src/markdown.lisp:646-648` | **DIFFERS** |
| A loose list is **one** block — no blank row between items | `markdown.rs:2016-2040` | a blank line closes the block, so N blocks and N−1 blank rows | `src/markdown.lisp:437-456,695-701` | **DIFFERS-spacing**: a six-point answer is twice as tall here |
| A nested list renders **flat** | `markdown.rs:1211-1217`, `render.rs:421-428` | nested items indent `min(8, 2*floor(indent/2))` | `src/markdown.lisp:645` | DIFFERS-EXTRA |
| Bullet `· ` `Faint`; ordered `"{n}. "` `Plain`; continuations padded by `width(marker)` | `render.rs:404-428` | identical glyphs and padding | `src/markdown.lisp:646-662` | SAME |
| Task-list marker dropped: `- [x] done` → `· done` | `markdown.rs:1050-1052,1242-1244` | not recognised → `· [x] done` | `src/markdown.lisp:298-318` | DIFFERS |
| Quote: joined, wrapped `w-2`, `│ ` rail, whole row dim | `render.rs:433-439` | identical | `src/markdown.lisp:664-669` | SAME |
| A fence **inside a quote** becomes a real code box, `> ` stripped | `markdown.rs:713-747,842-860` | `%fence-open` never fires on a `>` line — the backticks stay as literal characters | `src/markdown.lisp:270-276` | **MISSING** |
| A table inside a quote becomes rows with the pipes gone | `markdown.rs:1063-1081` | the pipes survive into the quote text | `src/markdown.lisp:430-434` | DIFFERS |
| Table shape `head`/`align`/`rows`; detection requires a pipe row **and** a delimiter row | `markdown.rs:111-119,1282-1306`, `render.rs:1286-1299` | same three negatives hold | `src/markdown.lisp:329-337,416-426` | SAME |
| Thematic break → `"─" × min(w,60)`, faint | `markdown.rs:974`, `render.rs:441` | same | `src/markdown.lisp:671` | SAME |
| Unknown node → a paragraph, shown unstyled — "a head that silently loses a block is worse" | `markdown.rs:978-987` | falls into the paragraph arm, but the inline scanner still runs over it | `src/markdown.lisp:458-463` | DIFFERS-minor |
| One blank row between blocks, trailing blanks popped | `render.rs:788-790,813-818` | same | `src/markdown.lisp:695-704` | SAME |

### 2.2 Inline spans

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Six inline styles; `nest`: Bold∘Italic = BoldItalic, BoldItalic absorbs, else the inner container wins | `markdown.rs:144-171` | `%nest-style` — the same three rules, same rationale | `src/markdown.lisp:52-70` | SAME |
| SGR: bold `\e[1m`, italic `\e[3m`, bold-italic `\e[1;3m`, code `\e[36m`, strikethrough **`\e[2m`** (deliberately not `9m`) | `render.rs:47-66,850-878` | same four attributes | `src/markdown.lisp:44-48,173-174` | SAME (leticl's reset prefix aside, §5) |
| `**` `__` `*` `_` `` ` `` `~~` all become runs, markers gone | `markdown.rs:561-626` | same six, hand-scanned | `src/markdown.lisp:157-176` | SAME |
| `snake_case` is not emphasis; `2 * 3` stays literal | grammar flanking rules, `markdown.rs:1963-1968` | explicit `:word-boundary` guard; opener not followed by space, closer not preceded by one | `src/markdown.lisp:78-90,132-147` | SAME |
| `***both***` → **one BoldItalic run**, text `both` | `markdown.rs:1947-1956` | `**` closes at the inner `*` run → `*both*` **with the asterisks on screen**; `**bold *and italic***` → `bold and italic*` | `src/markdown.lisp:78-87,169-176` | **DIFFERS-BUG**: markers reach the screen, which is the one thing this whole surface exists to prevent |
| Code span: raw interior, N-backtick runs, no nesting | `markdown.rs:566-577,665-673` | same | `src/markdown.lisp:157-168` | SAME |
| Code-span interior is literal — `` ` a ` `` → `" a "` | `markdown.rs:665-673` | applies the GFM one-space rule → `"a"` | `src/markdown.lisp:92-103` | DIFFERS-minor (leticl is more GFM) |
| `[text](url)` → text only, URL dropped | `markdown.rs:136-142,614-623` | same | `src/markdown.lisp:178-186` | SAME |
| Reference/collapsed/shortcut links `[t][r]`, `[t][]`, `[t]` → the label | `markdown.rs:614-623` | not recognised — brackets shown | `src/markdown.lisp:178-186` | MISSING |
| **Autolink** `<https://x>` → `https://x` | `markdown.rs:599-608` | `<`/`>` are ordinary characters | `src/markdown.lisp:187` | **MISSING** |
| Image `![alt](u)` → `alt` | `markdown.rs:614-623` | `!` is literal, then the link rule fires → `!alt` | `src/markdown.lisp:178-186` | DIFFERS-minor |
| Backslash escape before ASCII punctuation, not inside a code span | `markdown.rs:1375-1408` | `\` + any non-alphanumeric; scanner-level, so code spans are untouched | `src/markdown.lisp:151-154` | SAME in practice |
| Adjacent same-style runs coalesced | `markdown.rs:1375-1391` | not coalesced across an escape — three segments where the reference has one | `src/markdown.lisp:124-127` | DIFFERS-cosmetic |

### 2.3 Fences, tables and the budget

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `┌─ {lang}` / `│ ` / `└─`, frame dim; open fence → `└─ (still writing…)` | `render.rs:375-391` | byte-identical glyphs and string | `src/markdown.lisp:630-638` | SAME |
| The header names **the grammar that ran**: `rs`→`┌─ rust`, `ts`→`┌─ typescript`, `sh`→`┌─ bash`; bare → `┌─ code` | `render.rs:296-298,375-379` | prints the raw info string — `┌─ rs`, `┌─ ts`, `┌─ sh`; bare → `┌─ code` | `src/markdown.lisp:633` | DIFFERS |
| An unhighlightable fence's body is drawn **plain** — "a wrong colour is worse than none" | `render.rs:190-192,256-258` | the fallback paints every body line `(:dim t)` | `src/markdown.lisp:240-243` | **DIFFERS-style**: all code in a language the shim lacks reads as de-emphasised |
| Fence openers: `` ``` `` **and** `~~~`, any run ≥3 | `markdown.rs:722-726` | backticks only | `src/markdown.lisp:270-276` | MISSING |
| A closing fence must be **≥ the opener's length** — ```` ```` ```` can quote ``` ``` ``` | `markdown.rs:819-834` | any all-backtick line ≥3 closes | `src/markdown.lisp:278-280` | **DIFFERS-BUG**: a model teaching about fences gets its demonstration cut in half |
| A line that merely *ends* in backticks is content (box art) | `markdown.rs:2598-2610` | same rule | `src/markdown.lisp:278-280` | SAME |
| A fence on a list marker's line is a code box | `markdown.rs:781-784` | becomes item text | `src/markdown.lisp:437-456` | MISSING |
| A fence in a list item has the item's indent stripped | `markdown.rs:842-860` | the fence is found but the 2-space indent stays in the code | `src/markdown.lisp:398-409` | DIFFERS-indent |
| A 4-space-indented fence is a fence (documented CommonMark deviation) | `markdown.rs:2726-2736` | the same deviation, same reason | `src/markdown.lisp:270-276` | SAME |
| Long code lines neither wrapped nor truncated; the frame clips | `render.rs:381-383` | same | `src/markdown.lisp:635-636` | SAME |
| Highlighting is incremental: `rano::syntax::Stream` is fed only the delta, one `CodePaint` kept per open block across frames | `render.rs:188-242,685-692` | `highlight-fence` joins all lines and calls the shim over the whole fence, every frame, for every visible fence | `src/markdown.lisp:228-243,636` | **DIFFERS-perf** |
| `fit_columns` water-filling: settle every column ≤ share, redistribute, floor of 4 when nothing moves | `render.rs:552-590` | a line-for-line port | `src/markdown.lisp:520-552` | SAME |
| Cells painted then measured; header `Strong`; `gaps = 3*(cols-1)`; too-narrow cell **wraps**, never truncates; row height = tallest cell | `render.rs:479-515` | same | `src/markdown.lisp:568-587` | SAME |
| Separator `" │ "` faint, rule joined `─┼─`, no outer box; alignment from the delimiter row's colons; escaped `\|` is a pipe | `render.rs:502,523,533-538`, `markdown.rs:1308-1321,1394-1408` | same | `src/markdown.lisp:349-379,582,595-602` | SAME |
| A row's trailing padding removed with `row.trim_end()` over the **whole** row | `render.rs:528` | `%trim-line-end` right-trims only the **last segment** — a row whose last cell is empty keeps `… │ ` | `src/markdown.lisp:495-504,596` | DIFFERS-minor |
| `render_bounded`: `full ≤ limit \|\| limit < 3` → full; else `keep = limit-2`, `▸ {title}` dim, `  … {n} lines elided …` dim, then the last `keep` lines | `render.rs:610-635` | identical arithmetic, identical strings | `src/markdown.lisp:673-687` | SAME bytes |
| Title truncation: `trim_to(title, w)` **then** `"▸ "` prepended (the line may be `w+2`) | `render.rs:631` | the whole `"▸ {title}"` is truncated to `w` | `src/markdown.lisp:684` | DIFFERS-off-by-2 |
| `Block::title()` is `runs_text` — markers already gone | `markdown.rs:184-199` | `block-title` returns the **raw source**, so a bounded block's title can show `**markers**` | `src/markdown.lisp:506-518` | DIFFERS |
| Title strings `"{lang} · {n} lines"`, `"table · {r} × {c}"`, `"───"` | `markdown.rs:188-197` | identical format strings | `src/markdown.lisp:511-518` | SAME |
| `wrap` clamps `cols.max(4)`; `render_block_with` clamps `w.max(20)` | `width.rs:382`, `render.rs:325` | `render-block` clamps 20; `wrap-segments` has no floor of 4, only a `cols<=0` short-circuit | `src/markdown.lisp:608`, `src/render.lisp:61-88` | DIFFERS-edge |

### 2.4 Incremental and cache

| reference behaviour | ref citation | leticl | verdict |
|---|---|---|---|
| `IncrementalMarkdown`: `raw` + `window_start` + `stable` + `tail`; `push(delta)` is the only mutator | `markdown.rs:227-263` | nothing — `markdown-lines` takes the whole accumulated text every call (`src/markdown.lisp:689-704`) | **MISSING** |
| Settle rule: re-project the window, `cut_point`, re-parse the prefix standalone, move it to `stable`; ≤8 rounds per push | `markdown.rs:328-355` | — | MISSING |
| Cut guards: `stable_boundary_with` (strictly inside, balanced fences, no indented continuation, list provably closed), relaxed past `DEFAULT_MAX_UNFROZEN` = 4096, never inside a fence | `markdown.rs:877-884,1450-1471,1594-1689` | — | MISSING |
| `tail_cut(src, min_bytes)` — render only the bottom of a huge transcript, exact below its first block | `markdown.rs:1533-1585` | — | MISSING |
| Instrumentation `bytes_lexed`/`lex_calls`/`window_len`, asserted against a quadratic baseline | `markdown.rs:291-310`, tests `:1807-1877` | none | **MISSING** |
| One inline parse **per range**, so a `` ``` `` in one paragraph cannot pair with one ten blocks later | `markdown.rs:460-485` | `inline-spans` already runs per block — the bug class cannot occur | SAME-by-construction |
| `BlockCache` keyed on `(width, color, base, limit)` + `Decor`; stores `stable_lines`, `rendered_blocks`, one `CodePaint` per live code block by absolute index; any key change clears all three; `split()` returns the prefix **by reference** | `render.rs:676-820` | no cache of any kind (`src/render.lisp:207-250`) | **MISSING** |
| `Decor` applied **once**, when a line enters the cache — that is how the reasoning `┃ ` rail survives without per-frame copying | `render.rs:646-672,788-789` | the rail and dim-italic are `mapcar`ed over every line every frame (`src/cards.lisp:771-782`) | DIFFERS-perf, same picture |
| `base: Option<Role>` — an inline run closes back to the enclosing block's role | `render.rs:102-116,146-151` | `:base-style` exists but applies only to segments with no style of their own, and **no caller passes it** | DIFFERS-mechanism (see §1.3) |

### 2.5 The reference's markdown tests against leticl

`markdown.rs`'s tests assert on the block model; `render.rs`'s on rendered
strings. Applying each:

**PASS**: `inline_markers_become_runs` (`:1927`), `a_star_that_is_not_emphasis_stays_literal`
(`:1963`), `a_table_is_cells_and_alignment_from_the_tree` (`:1981`),
`an_unterminated_fence_still_renders` (`:1991`), `a_list_item_does_not_keep_its_marker`
(`:2042`), `a_quote_does_not_keep_its_markers` (`:2059`),
`a_fence_in_an_unknown_language_is_still_code` (`:2243`),
`a_line_that_merely_ends_in_backticks_is_content` (`:2598`),
`a_four_space_indented_fence_is_read_as_a_fence` (`:2726`),
`the_box_art_that_broke_it_keeps_all_six_lines` (`:2739`),
`a_long_block_becomes_a_title_a_count_and_a_tail` (`render.rs:936`),
`the_bound_is_configurable` (`render.rs:953`), `markers_are_styles_on_the_screen`
(`render.rs:1328`), the whole table module (`render.rs:1194-1314`).

**FAIL**: `nested_emphasis_is_one_style_not_two_markers` (`:1947`),
`a_link_shows_its_text_and_not_its_destination` (`:1971` — the autolink half),
`a_fence_inside_a_quote_is_not_dropped` (`:2197`),
`a_table_inside_a_quote_keeps_its_cells` (`:2230`),
`a_fence_cannot_quote_itself` (`:2261`, the 4-backtick half),
`a_fence_on_a_list_markers_line_is_not_item_text` (`:2677`),
`stripping_a_content_column_does_not_eat_content` (`:2699`, two of three),
`a_longer_fence_can_quote_a_shorter_one` (`:2756`),
`a_quoted_fence_closes_on_a_prefixed_line` (`:2766`),
`the_header_names_the_grammar_that_ran` (`render.rs:1602`),
`a_bare_fence_is_named_code_and_left_plain` (`render.rs:1619` — text passes,
styling does not), `a_heading_does_not_keep_its_hashes` (`:1909`, the setext
half), `a_loose_ordered_list_keeps_the_numbers` (`:2016`),
`a_nested_list_reads_flat` (`:2049`).

**N/A — the mechanism does not exist**: `streaming_matches_one_parse` (`:2306`),
`tail_cut_is_exact` (`:2841`), the window tests (`:1807-1905`).

leticl's own suite already pins the glyphs it does have
(`tests/tests.lisp:271-295, 2427-2527`): `┌─ lisp`, `│ `, `└─`, `· ` faint,
`─┼─`, `▸ item 1`, `… 22 lines elided …`, `#` faint plus `(:bold t :fg :cyan)`.
Those are the same bytes the reference produces.

---

## 3. Diff and highlighting

Reference: `crates/ui/src/diff.rs`, `crates/ui/src/sidediff.rs`,
`crates/ui/src/highlight.rs`.
Subject: `src/diff.lisp`, `src/sidediff.lisp`, `src/highlight.lisp`, `native/hl/`.

**Headline**: `diff.lisp` is a faithful port with one dead-code bug;
`sidediff.lisp` is a much-reduced port; the highlighter is architecturally
*better* than the reference's but is wired only into markdown fences, never into
the diff panels.

### 3.1 `diff.rs` ↔ `src/diff.lisp` — a close port

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `DiffConfig` defaults: width 100, context 3, line_numbers true, intra_line true, max_rows 60 | `diff.rs:307-333` | the same defaults as keyword args | `src/diff.lisp:413-414` | SAME |
| `DEFAULT_MAX_D = 2000`; strip common prefix then suffix; Myers greedy with `v` sized `2(n+m)+1`, `off = n+m`, trace per D, early return at `(n,m)` | `diff.rs:82,105-194` | identical | `src/diff.lisp:53,141-159,74-112` | SAME |
| Cap hit ⇒ whole middle as delete-all + insert-all, `degraded = true` | `diff.rs:190-193` | identical | `src/diff.lisp:109-112` | SAME |
| `backtrack` with the `prev_k` rule | `diff.rs:196-233` | identical | `src/diff.lisp:114-137` | SAME |
| `hunks(d, context)`: stitch while `changed[j+1] <= changed[j] + 2*context + 1`; `start = changed[i]-context`; `end = changed[j]+context+1` | `diff.rs:253-303` | identical arithmetic | `src/diff.lisp:178-222` | SAME |
| Row kinds; `usize::MAX` sentinel → 0 | `diff.rs:236-299` | `most-positive-fixnum` sentinel → 0 | `src/diff.lisp:181-218` | SAME |
| No hunks ⇒ one `"no change"` row, `Faint` | `diff.rs:364-367` | same string, `'(:dim t)` | `src/diff.lisp:426-427` | SAME |
| Degraded banner: `! diff gave up on the minimal edit script; the changed region is shown as a whole replacement`, `Attention` | `diff.rs:368-374` | same string, `'(:bold t :fg :yellow)` | `src/diff.lisp:434-437` | SAME |
| Gutter width `len(str(max(old_base+len(old), new_base+len(new), 1)))`; gutter `{:>numw} {:>numw} ` | `diff.rs:375-380,461-470` | same | `src/diff.lisp:337-344,385-391,429-433` | SAME |
| Hunk header `@@ -{o},{co} +{n},{cn} @@`, faint, only when `hi>0 \|\| hs.len()>1` | `diff.rs:383-405` | identical | `src/diff.lisp:443-455` | SAME |
| Signs `" "`/`"-"`/`"+"`; gutter faint on context else `role.foreground()`; body background-only `48;5;22` / `48;5;52` | `diff.rs:441-489`, `style.rs:121-127,200-201` | same | `src/diff.lisp:373-398` | SAME |
| `body_w = width - (width(gutter)+1)`, floor 8; continuation rows keep the colour, drop the sign, prefix `width(gutter)+1` faint spaces; an empty line still occupies a row | `diff.rs:471-499`, `width.rs:526-528` | same, with an explicit empty-row fallback | `src/diff.lisp:392,400-409` | SAME |
| `max_rows` counted in **hunk rows**, headers not charged; overflow disclosed as `… {n} more diff lines not shown`, faint | `diff.rs:381-426` | identical accounting and string | `src/diff.lisp:439-472` | SAME |
| `word_spans` + `SIMILARITY_FLOOR = 0.35`, token Myers capped at D=512, `ratio = 2*equal/(len a + len b)`; `merge` coalesces touching spans; `tokens` = alphanumeric-or-`_` runs vs everything else | `diff.rs:78,590-648` | identical, with **character** rather than byte spans (safer for non-ASCII) | `src/diff.lisp:48,226-280` | SAME |
| `paint_with_emphasis` walks spans, skips a span starting before `at`, clamps, emits the tail | `diff.rs:504-542` | `%emphasize`, same guards | `src/diff.lisp:346-366` | SAME |
| `expand_tabs(s, 4)`, column-aware, applied to the body and to both sides before `word_spans` | `diff.rs:652-669,577-578` | same | `src/diff.lisp:319-333,306-309,399` | SAME |
| **`pair_rows`**: `add_start = i` is bound at `diff.rs:555`, **before** the addition loop at `:556-558`, so `add_end != add_start` and the pairing runs | `diff.rs:545-586` | `add-start` **and** `add-end` are both bound to `i` at `src/diff.lisp:297-298`, **after** the addition loop at `:295-296` — so `(= add-end add-start)` is always true, the `if` always takes the false branch, and `out` is all `NIL` | `src/diff.lisp:295-300` | **DIFFERS-dead-code**: intra-line word emphasis never reaches the screen, even though `src/cards.lisp:1005` asks for it and `src/diff.lisp:456` consults the flag. `word-spans`, `%merge-spans`, `%emphasize` and `+diff-emphasis+` are all correct and tested in isolation (`tests/tests.lisp:560-575`); only the wiring is wrong. |
| Both head call sites pass `intra_line: **false**` | `app.rs:8817,9934` | the caller passes `:intra-line t` | `src/cards.lisp:1005` | DIFFERS-intent. **Screen parity today is accidental**: fixing the bug above without also setting the call site to `nil` would make leticl start emitting emphasis the reference deliberately suppresses. |
| Caller's `max_rows` is always 60 | `app.rs:8818,9935` | 8 when folded, else 60 | `src/cards.lisp:1006` | EXTRA |
| Out-of-range line index renders as `""` | `diff.rs:445,449,457` | `(elt old …)` signals | `src/diff.lisp:376-383` | DIFFERS-robustness |
| Side text split with `str::lines()` — a trailing `\n` does **not** add an empty line | `sidediff.rs:451-452` | `uiop:split-string` keeps the final `""` ⇒ a phantom blank diff row on any side ending in `\n` | `src/cards.lisp:967-974`, `src/sidediff.lisp:137-139` | **DIFFERS-phantom-row** |
| `\ No newline at end of file`; binary-file case; in-hunk `…` collapse | absent | absent | — | SAME (neither has them) |
| — | — | exported `apply-diff-to-new` / `apply-diff-to-old` | `src/diff.lisp:477-488` | EXTRA, harmless |
| Element compare is generic, slices index O(1) | `diff.rs:150,179` | `elt`/`nth` on **lists** in `hunks` and the token Myers ⇒ O(n²) indexing; output accumulated with `append` in a loop | `src/diff.lisp:194-203,262-264,448-471` | DIFFERS-perf-only, invisible at card sizes |

### 3.2 `sidediff.rs` ↔ `src/sidediff.lisp` — a much-reduced port

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `render_split` → one string per terminal row; panels re-diffed from the excerpts | `sidediff.rs:88-141` | `render-split` → segment lines, same re-diff | `src/sidediff.lisp:152-206,177,188` | SAME shape |
| `SEP = " │ "`, `SEP_W = 3`, `Faint` | `sidediff.rs:72-73,283` | same constants, `'(:dim t)` | `src/sidediff.lisp:28-29,199` | SAME |
| `MIN_BODY = 8` is a **floor** — "a narrow pane gets a narrow split rather than no diff" | `sidediff.rs:29-32,75-77,168,471-477` | the same constant used as a **gate**: below it, one yellow row `{n}-column pane is too narrow for two panels; /diff unified` and no diff at all | `src/sidediff.lisp:30-33,169-174` | **DIFFERS-refuses** — and it contradicts leticl's own ported file header at `src/sidediff.lisp:13-16` |
| `panel_w = (width-3)/2` for **both** panels; the odd column is unused | `sidediff.rs:155` | left `floor((width-3)/2)`, right `width-3-panelw` so the row is exactly `width` | `src/sidediff.lisp:163-164` | DIFFERS-exact-width: asymmetric panels, arguably better, but the halves no longer measure the same |
| `numw` from the same max expression | `sidediff.rs:156-164` | identical | `src/sidediff.lisp:165-168` | SAME |
| Cell layout `number + space + sign + space + body`; `gutter_w = numw + 3` (2 with numbers off) | `sidediff.rs:167,363` | `number + sign + body`; body `= max(1, panelw - numw - 1)` — **no space either side of the sign** | `src/sidediff.lisp:128-134` | DIFFERS-spacing: code starts two columns earlier and abuts the sign |
| Pairing: context with itself, else the run of removals against the run of additions, k-th↔k-th, the longer side gets lone halves | `sidediff.rs:218-252` | `%split-pairs`, identical single pass and `max(len)` loop | `src/sidediff.lisp:53-92` | SAME |
| An absent half is one blank row padded to `panel_w` | `sidediff.rs:198-201,315-316` | same | `src/sidediff.lisp:135` | SAME |
| Long code **wraps** inside its column; continuations keep their panel and blank the other; a pair emits `max(left_rows, right_rows)` rows | `sidediff.rs:270-287,308-326` | **truncates** with `fit-to-width`; a pair is always exactly one row | `src/sidediff.lisp:94-100,134` | **DIFFERS-truncates** — `diff.rs:336-341` calls truncating a diff "the one thing a diff must not do" |
| Hunk header in the split view, charged against the budget | `sidediff.rs:112-119,173-194` | none — a multi-hunk split diff runs its hunks together | `src/sidediff.lisp:188-201` | **MISSING** |
| `"no change"` row; degraded banner | `sidediff.rs:93-103` | returns `NIL`; none | `src/sidediff.lisp:186-206` | **MISSING** both |
| Budget charged per **terminal row**; a pair that does not fit whole is dropped whole | `sidediff.rs:109-133` | one decrement per pair | `src/sidediff.lisp:186-201` | DIFFERS-accounting (moot while there is no wrap) |
| Overflow notice `… {n} more diff lines not shown` | `sidediff.rs:134-139` | `… {n} more diff **rows** not shown` | `src/sidediff.lisp:202-205` | DIFFERS-string |
| A changed row is tinted to the **full panel width** inside its own role (`Painter::inside`, pad inside the tint, `RESET` so the separator starts clean); `rebase_resets` stops a syntax span ending the background | `sidediff.rs:290-374`, `style.rs:246-330` | both halves are one flat `'(:fg :bright-white)` segment — no background, no `Painter` analogue | `src/sidediff.lisp:198-200` | **MISSING** |
| The sign keeps its green/red foreground inside the tint; the line number takes the row's foreground, faint on context | `sidediff.rs:335-355` | sign and number are plain bright-white on every row | `src/sidediff.lisp:102-116,133,198-200` | **MISSING** |
| Under `Palette::None` the glyph alone carries the change | `sidediff.rs:17-21,659-662` | true by accident — the glyph is all there is | `src/sidediff.lisp:133` | SAME, degenerately |
| Both panels syntax-coloured: `class_grid` over the excerpt, `paint_classed` runs, `role_for_capture`; tabs expand to 4 carrying their own class; `lang_for(path)` delegates to rano's `detect` | `sidediff.rs:106-107,78-80,389-439` | none — `render-split` never calls `class-grid`; `edit-split-lines` drops `(getf edit :path)`; no tab expansion in the split path | `src/sidediff.lisp:152-222`, `src/highlight.lisp:57-61` | **MISSING** (the machinery all exists; only the wiring is absent) |
| `render_edit(path, before, after, before_start, after_start, cfg)`; width `width - (2 + activity_indent)` | `sidediff.rs:443-460`, `app.rs:8811` | `edit-split-lines(edit, cols)`, path dropped, width `(max 20 (- cols 4))` | `src/sidediff.lisp:208-222` | DIFFERS-signature and width |
| `EditView::{Split,Unified}` + `edit_view(split_wanted)` + `render_edit_view` | `sidediff.rs:462-505` | the same toggle, resolved in the card layer | `src/cards.lisp:709,997-1008` | SAME (different home) |
| Panel text read straight from the slices | `sidediff.rs:264-269` | two `defvar` hash tables `*split-old*`/`*split-new*` rebound and refilled per render | `src/sidediff.lisp:141-185` | EXTRA: two hash tables per frame for what is a vector index |

### 3.3 `highlight.rs` ↔ `src/highlight.lisp` + `native/hl/`

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| Backend is rano's tree-sitter `syntax` (~28 languages); no hand-written lexer | `highlight.rs:1-34` | the same engine, reached through a Rust `cdylib` over a C ABI, called with `sb-alien` (no CFFI) | `src/highlight.lisp:1-6`, `native/hl/Cargo.toml:7-14` | SAME engine, DIFFERS-transport |
| `role_for_capture`: `comment`→Comment; `string\|escape`→StringLit; `number\|constant\|property`→NumberLit; `type\|constructor\|label`→TypeName; `keyword\|include\|preproc\|variable.builtin`→Keyword; `function`→FuncName; else split on `.` and recurse; unknown ⇒ Plain | `highlight.rs:53-66` | byte-for-byte the same table and the same dotted-prefix recursion, returning `u8` 1..6 with 0 = plain | `native/hl/src/lib.rs:105-122` | SAME |
| Six roles, deliberately not rano's dozen; unmapped keeps the reader's own foreground | `highlight.rs:45-52` | the same six indices | `src/highlight.lisp:111-122` | SAME |
| Role→colour, six of six | `style.rs:203-211` | four match; **NumberLit is `bright-yellow` (93) not `33`**, **FuncName is `bright-cyan` (96) not `34`** | `src/highlight.lisp:118,121` | DIFFERS-colour on two |
| Language detection `rano::syntax::detect(Some(Path), None)`, typed `Lang` — the property `a_language_rano_gains_arrives_without_a_second_table` pins that there is no second table | `sidediff.rs:437-439,748-757` | `hl_detect(path)` over a hand-written two-way id↔Lang table (1..27) in the shim | `native/hl/src/lib.rs:28-103,124-140` | **DIFFERS-shape**: a new rano language needs the shim's table edited |
| Fence language from a name via rano's `Lang::from_token` | `render.rs:216-218` | a **third** table: 30 fence names → fake extensions, fed to `hl_detect("fence.<ext>")` | `src/markdown.lisp:197-226` | DIFFERS-extra-table |
| Class grid `Vec<Vec<Role>>`, one entry per char per line | `sidediff.rs:419-433` | one `u8` per Unicode scalar, row-major, newline = 0, so it indexes 1:1 against a Lisp string | `native/hl/src/lib.rs:176-199` | SAME-equivalent |
| A fresh `Highlighter` (and query compile) per render | `sidediff.rs:424` | one `Highlighter` per language id, thread-local, for the process life | `native/hl/src/lib.rs:31-38,169-174` | **EXTRA (better)** |
| No unwind guard needed (in-process Rust) | — | `catch_unwind` at both entry points; a short or zero write is read as uncoloured | `native/hl/src/lib.rs:127,156,201`, `src/highlight.lisp:106-107` | EXTRA |
| Unknown language ⇒ empty grid ⇒ everything `Plain` | `sidediff.rs:420-422` | shim absent, lang 0, or a parse failure ⇒ `class-grid` NIL ⇒ one plain segment per line; fences fall back to `'(:dim t)` | `src/highlight.lisp:46-53,91-107,130-133` | SAME in spirit (the fence fallback differs, §2.3) |
| Compiled in; no discovery | — | `$LETICL_HL_SO`, then `native/libleticl-hl.so`, then `native/hl/target/release/…`, then a **hardcoded** `/home/dead/Projects/rano/rano/target/release/libleticl_hl.so`; loaded once, `defvar`-guarded | `src/highlight.lisp:35-53` | EXTRA — note that `native/hl/target` is not built in this checkout, so only the absolute path resolves |
| — | — | a hand-rolled 1–4 byte UTF-8 encoder (SBCL has no public one) | `src/highlight.lisp:65-89` | EXTRA, correct as written |
| — | — | `sb-sys:vector-sap` on two Lisp vectors with **no `sb-sys:with-pinned-objects`** around the alien call — a moving GC may relocate either vector mid-call. `RANO.md:85-87` documents `sb-alien:make-alien`, which the code does not use | `src/highlight.lisp:101-105` | **EXTRA-latent-bug** |
| Cost recorded (~0.1 µs/byte, ~1.1 µs/line); the embedder is told to bound what it hands over | `highlight.rs:30-34` | no bound on `highlight-lines` input | `src/highlight.lisp:126-158` | MISSING, minor |

---

## 4. The frame

Reference: `fn screen` (`app.rs:5028`), `fn body_window` (`:5618`),
`fn header_line` (`:6201`), `fn hint_bar` (`:5418`), `fn composer_rows` (`:5341`),
`fn turn_status` (`:7501`), `fn turn_footer` (`:8184`), `fn box_edge` (`:5384`),
`fn gutter` (`:5325`).
Subject: `src/render.lisp` (`%render`, `%viewport-lines`, `%place-lines`) and
`src/chrome.lisp`.

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `gutter = 2` at ≥40 columns, **0 below** — "the first thing given up on a very narrow screen, before any content is" | `app.rs:5320-5327` | `+gutter+ 2` and `+right-margin+ 2`, both constant at every width | `src/render.lisp:414-428` | **DIFFERS**: at 30 columns the reference gives the body 30 and leticl gives it 26. |
| `w = term_w - 2 * gutter` — the right margin is *implicit* | `app.rs:5035` | `cols = head-cols - gutter - right-margin` — two separate constants that happen to sum to the same | `src/render.lisp:288` | SAME arithmetic at ≥40 columns |
| **The fit ladder**: while the chrome does not fit, drop in order — completions, hint, notice, a composer row (down to 1), the stuck line, the box, a decision row | `app.rs:5094-5126` | no ladder. `boxed = (>= rows 8)` is the only degradation; the hint bar always occupies the last row; the composer always gets `composer-rows-needed` | `src/render.lisp:306-320`, `src/chrome.lisp:547`, `:585-591` | **MISSING**. At `h=2` the reference still shows a composer; leticl's `cursor` can go negative. |
| Backstop: `if chrome.len() >= h { chrome.drain(..) }` so the head never returns more rows than the terminal has | `app.rs:5206-5208` | none | — | MISSING |
| Unboxed costs one row **only when there is an alarm**; a clean head owes that row to the transcript | `app.rs:5099-5103` | `alarm-row` only when `alarm` and not boxed; `status-row` only when the status text is non-empty | `src/render.lisp:314-318` | SAME intent |
| Header drawn only when `h >= 6 && !session_id.is_empty()` | `app.rs:5231` | `top-border` drawn unconditionally at row 0 | `src/render.lisp:326` | DIFFERS on a very short screen |
| `header_line`: `▌ ` `UserAccent`, title `Strong`, workspace `Faint` ellipsised from the left, tail `Faint` right-aligned, **degrading by dropping tail fields from the end** | `app.rs:6201`+ | identical structure and identical degrade rule | `src/chrome.lisp:210-254` | SAME — confirmed byte-for-byte on the live capture (row 1, both heads) |
| `box_edge(w, open, close, left, right)`: whole edge `Faint`; the legend pinned **right** as `" {legend}{reopen} ─"`, gated on `inner >= 10` and `room >= 4`; `reopen` re-enters `Faint` after the legend's own paint — "a reset is not a restore" | `app.rs:5384-5411` | `composer-box-top`: `╭` + legend **left, bold** + fill + `╮`. `composer-box-bottom`: `╰` + fill + legend dim + `╯` | `src/chrome.lisp:480-501` | **DIFFERS**: the top legend is on the wrong side and in the wrong role (`Strong` vs `Pending`), and neither edge has the ` … ─` framing. Invisible today because both legends are currently empty. |
| Top edge legend: `{N} subagent{s} running`, `Role::Pending`, only while any are | `app.rs:5157-5173` | same text via `composer-title` | `src/chrome.lisp:412-432` | SAME text, wrong placement/role (above) |
| Bottom edge legend: `["⚠" if alarmed, turn_status]` joined `" · "` | `app.rs:5177-5189` | same, via `composer-wiring` | `src/chrome.lisp:434-451` | SAME content |
| `turn_status`, generating: `{spin} Responding{since}{count}` — spinner **first**, then `since`, then the count | `app.rs:7560-7566` | `Responding{count}{since} · {spin}` — spinner **last**, count and since swapped | `src/chrome.lisp:389-400` | **DIFFERS** |
| `turn_status`, prefilling: `{spin} {progress::prefill_line(pf, w-6, p)}` | `app.rs:7538-7550` | no prefill arm at all; `prefill-line` exists (`src/progress.lisp:172`) and is never called from the status | `src/chrome.lisp:377-400` | **MISSING**: the prefill bar never appears on the composer's edge. |
| `since`: `" · started before this head attached"` when `started_ms == 0` | `app.rs:7513-7519` | same string | `src/chrome.lisp:386` | SAME |
| `stuck_line`: at **15 s** of silence, a yellow row **of its own above the border** — `{model} — nothing received for {d}. The turn is still marked running; esc esc interrupts it.` | `app.rs:7582-7601` | at `dc62ddf`: at **20 s**, ` · no frames for {d}` appended to the *status line*, which is only drawn when the frame is **unboxed**. **`4e32354` has since fixed this**: `stall-text` now takes the head, gates on a running turn, names the model and uses the reference's sentence; `stall-row` and `notice-line` are placed above the box by `%render`'s new `extra` rows | `src/chrome.lisp:285-311,328` (before); `src/chrome.lisp:308-344` and `src/render.lisp:314-320,409-411` (after) | was DIFFERS, now **SAME but for the threshold** (20 s vs 15 s) |
| The notice row: `· {n}` in magenta, in the chrome above the box, one of the fit ladder's rungs | `app.rs:5071-5074,5113` | at `dc62ddf` the note rode `status-line`, drawn only when unboxed — i.e. never on a real screen, so every `say` went into silence including `detached — reconnecting…`. `4e32354` adds `notice-line` above the box | `src/chrome.lisp:322-334` (before), `:326-337` (after) | was **MISSING**, now SAME placement — but still outside any ladder (gap 16) |
| `hint_bar`: composer half + `" · "` + context tail; ten context arms, exact strings | `app.rs:5418-5459` | the same ten arms, the same strings | `src/chrome.lisp:338-375` | SAME — confirmed on the live capture (row 63, identical bytes) |
| `composer_rows`: box walls, padded to full width, caret `(row, col)` returned | `app.rs:5341`+ | `composer-box-body` + `composer-caret`, segment boundaries tuned to the reference's escapes | `src/chrome.lisp:503-583` | SAME (documented as escape-matched at `src/chrome.lisp:519-538`) |
| `body_window` air: separator **before** a row whose `RowClass` changed; two `Activity` rows pack; a row that renders to nothing gets no separator; one gap row between the history and the live pane | `app.rs:5809-5830`, `:5886-5893` | identical rule, same three clauses | `src/render.lisp:240-258` | SAME |
| Scroll clamp `total - room`, and the last visible row is **overwritten** by `── scrolled back · {behind} lines below · ↓ or esc to follow · wheel scrolls · shift+drag selects` in yellow | `app.rs:6142-6157` | identical string, identical overwrite | `src/render.lisp:262-275` | SAME |
| Live pane order: reasoning, calls, text, writing-call, raw-call, footer — each followed by a blank | `app.rs:5916-5995` | reasoning, **calls**, text, raw-calls — same order | `src/cards.lisp:1104-1135` | SAME order; `writing_call_line` (`app.rs:8698-8707`) has no counterpart — MISSING |
| Live pane stands down when `superseded` (the transcript owns every appended row **and** no call is in flight) | `app.rs:5651-5665` | `turn-lines` draws only while `(string= (turn-state-name turn) "running")` | `src/cards.lisp:1100` | DIFFERS: leticl's test is the turn's state, the reference's is per-row ownership. The reference's own note says the state test is what produced a fifteen-minute `→ no result`. |
| `%place-lines` clips at both ends | — | `src/render.lisp:442-448` | — | SAME as the reference's `out.truncate(h)` |

---

## 5. Styles

Reference: `crates/ui/src/style.rs` (`Role`, `Palette::open`, `Painter`) and the
painter `paint_runs`/`Decor` in `crates/tui/src/render.rs:850-878`, `:646-672`.
Subject: leticl's style plists, interned by `style-index` (`src/cells.lisp:101-110`)
and turned into SGR by `%style-sgr` (`src/cells.lisp:61-78`).

**The two models.** The reference is string-oriented: `open(Role)` hands out a raw
SGR opener, callers splice it into a `String`, and a span closes with
`width::RESET` (`width.rs:285`) or, inside a block, `Painter::close()`
(`style.rs:296-304`). leticl is cell-oriented: every cell carries a style index and
the painter emits an SGR only when the index changes (`src/cells.lisp:327-329`).
The cell model makes the reference's whole `Painter` class of defect
unrepresentable — but it also changes the emission form and the composition rule.

### 5.1 Role by role

| Role | ref citation + SGR | leticl plist (and SGR) | leticl citation | verdict |
|---|---|---|---|---|
| `Plain` | `style.rs:153` → **no bytes** | `nil` → index 0 → `\e[0m` | `src/cells.lisp:105` | DIFFERS-bytes, same rendition |
| `Faint` | `style.rs:157` → `\e[2m` (73 sites) | `'(:dim t)` → `\e[0;2m` | `src/markdown.lisp:47` + 85 sites | SAME |
| `Strong` | `style.rs:158` → `\e[1m` | `'(:bold t)` → `\e[0;1m` | `src/markdown.lisp:46` | SAME |
| `Heading` | `style.rs:162` → `\e[1;36m` | `'(:bold t :fg :cyan)` | `src/markdown.lisp:44` | SAME |
| `Subheading` | `style.rs:163` → `\e[1;34m` | `'(:bold t :fg :blue)` | `src/markdown.lisp:45` | SAME |
| `UserAccent` | `style.rs:164` → `\e[34m` | `'(:fg :blue)` | `src/cards.lisp:844`, `src/chrome.lisp:240` | SAME |
| `UserBlock` | `style.rs:172` → `\e[7m` | `'(:reverse t)` | `src/cards.lisp:848,850` | SAME |
| `Success` | `style.rs:173` → `\e[32m` | `'(:fg :green)` | `src/cards.lisp:380,937` | SAME |
| `Pending` | `style.rs:174` → `\e[33m` | `'(:fg :yellow)` | `src/cards.lisp:898,933,938` | SAME |
| `Failure` | `style.rs:175` → `\e[31m` | `'(:fg :red)` | `src/cards.lisp:382,612,621` | SAME |
| `Attention` | `style.rs:180` → `\e[1;33m`, deliberately distinct from `Pending` | inconsistent: `'(:bold t :fg :yellow)` at `cards.lisp:936,1149,1228`, but plain `'(:fg :yellow)` at the outcome sites and `'(:fg :cyan)` for backgrounded | `src/cards.lisp:381,383,386`, `src/diff.lisp:436`, `src/sidediff.lisp:174` | **DIFFERS-collapsed**: `Attention` folds onto `Pending` (and once onto `Code`). The reference pins the pair apart with a test (`style.rs:468-485`). |
| `Reasoning` | `style.rs:186` → `\e[2;3m` | `'(:dim t :italic t)` | `src/cards.lisp:761,778` | SAME sequence, DIFFERS-composition (§1.3) |
| `Code` | `style.rs:187` → `\e[36m` | `'(:fg :cyan)` | `src/markdown.lisp:48` | SAME |
| `Added` | `style.rs:200` → `\e[48;5;22m` | `'(:bg 22)` | `src/diff.lisp:60` | SAME |
| `Removed` | `style.rs:201` → `\e[48;5;52m` | `'(:bg 52)` | `src/diff.lisp:61` | SAME |
| `Added/Removed.foreground()` | `style.rs:127-133` → `Success`/`Failure` | `(case role (:added :green) (:removed :red))` | `src/diff.lisp:393-395` | SAME |
| `Emphasis` | `style.rs:202` → `\e[1;4m`, composed as two stacked escapes `\e[48;5;22m\e[1;4m` | merged into one: `\e[0;48;5;22;1;4m` | `src/diff.lisp:64,352` | DIFFERS-bytes, same rendition |
| `Keyword` | `style.rs:203` → `\e[35m` | `'(:fg :magenta)` | `src/highlight.lisp:120` | SAME |
| `StringLit` | `style.rs:204` → `\e[32m` | `'(:fg :green)` | `src/highlight.lisp:117` | SAME |
| `NumberLit` | `style.rs:205` → `\e[33m` | `'(:fg :bright-yellow)` → `\e[0;93m` | `src/highlight.lisp:118` | **DIFFERS-colour** |
| `Comment` | `style.rs:209` → `\e[2m` | `'(:dim t)` | `src/highlight.lisp:116` | SAME |
| `TypeName` | `style.rs:210` → `\e[36m` | `'(:fg :cyan)` | `src/highlight.lisp:119` | SAME |
| `FuncName` | `style.rs:211` → `\e[34m` | `'(:fg :bright-cyan)` → `\e[0;96m` | `src/highlight.lisp:121` | **DIFFERS-colour**, and it puts `TypeName`/`FuncName` on one hue, which `style.rs:28-31` rules out |

leticl styles with no `Role`: `'(:fg :bright-white)` on both split-diff panels
(`src/sidediff.lisp:198,200`, `src/cards.lisp:1155,1231`) where the reference paints
through syntax roles or `Plain`; `'(:fg :bright-cyan :bold t)` for prompt/queued
prefixes (`src/chrome.lisp:555`, `src/cards.lisp:1083`); `'(:reverse t :bold t)`
for a chosen decision row (`src/cards.lisp:1169`) where the reference uses bare
`sgr::REVERSE` (`render.rs:65`). The markdown inline styles (`:italic`,
`:bold :italic`, dim-as-strikethrough — `src/markdown.lisp:174-176`) match
`paint_runs` exactly (`render.rs:51,55,869-871`) and are SAME.

`'(:fg :red :bold t)` (`src/chrome.lisp:271,329`, `src/cards.lisp:1065`) and
`'(:bold t :fg :red)` intern as **two different styles** with different bytes —
`style-index` does not canonicalise key order.

### 5.2 Emission form

| behaviour | reference | leticl | verdict |
|---|---|---|---|
| opener | bare attributes, `\e[1;36m` (`style.rs:162`) | always reset-prefixed, `\e[0;1;36m` (`src/cells.lisp:65-78`; pinned by `tests/tests.lisp:69-80`) | DIFFERS-form. Self-consistent; costs 2 bytes per switch and forbids additive styles. |
| colour space | sixteen theme slots, cube only for the two diff backgrounds, **enforced by a test** that bans `38;5;`/`48;5;`/`38;2;` (`style.rs:413-455`) | `%color-sgr` accepts keywords, cube integers and `(r g b)` truecolour (`src/cells.lisp:44-59`); only `(:bg 22)`/`(:bg 52)` use it today, and nothing forbids the next one | EXTRA capability, no guard |
| mid-line change | per run: `code + text + close`, `close` skipped when `code` is empty (`render.rs:850-878`) | per cell, tracked across the whole frame (`src/cells.lisp:327-329`) | DIFFERS-mechanism, equivalent result, fewer bytes |
| no-colour mode | `Palette::None` returns `""` everywhere; asserted by `the_none_palette_emits_no_bytes_a_terminal_would_eat` (`style.rs:336-341`) | none | **MISSING** |
| sync output | in `tui/src/term.rs`, not on this surface | `?2026h`/`?2026l` per frame (`src/cells.lisp:299,350`) | EXTRA |

---

## 6. Width

Reference `crates/ui/src/width.rs`; subject `src/width.lisp` plus the wrapping,
which lives in `src/render.lisp`, and two further truncators in
`src/progress.lisp` and `src/markdown.lisp`.

| reference behaviour | ref citation | leticl | leticl citation | verdict |
|---|---|---|---|---|
| `char_width` 0/1/2 | `width.rs:191-202` | `char-width` → `%code-width`, precomputed byte table under `#x20000`, binary search above | `src/width.lisp:180-191,163-178,141-151` | SAME result, EXTRA table |
| `is_control` — `u < 0x20 \|\| 0x7f..0xa0` | `width.rs:205-208` | `%c1-control-p` | `src/width.lisp:136-139` | SAME |
| zero-width range set (23 ranges) | `width.rs:216-237` | `*zero-width-ranges*` | `src/width.lisp:41-60` | SAME — machine-diffed, identical |
| wide range set (~60 ranges) | `width.rs:241-282` | `*wide-ranges*` | `src/width.lisp:62-102` | SAME — machine-diffed, identical |
| `is_regional_indicator` | `width.rs:210-212` | `%regional-indicator-p` | `src/width.lisp:200-203` | SAME |
| `skip_escape` — CSI, OSC BEL/ST, two-byte; unterminated eats the rest | `width.rs:155-183` | `%skip-escape` | `src/width.lisp:205-231` | SAME |
| `cells(s)` — escape-prefixed clusters, trailing escape-only cell kept | `width.rs:67-148` | `clusters` | `src/width.lisp:250-320` | SAME except the order below |
| Cluster extension order: **control test first**, then RI-pair, then ZWJ-join | `width.rs:107-139` (control at `:116`) | RI-pair, ZWJ-join, **then** control | `src/width.lisp:298-318`, `:361-367` | DIFFERS-edge: a ZWJ immediately followed by a C0 byte absorbs the control. One-line reorder. |
| `width(s)` = Σ cluster cols | `width.rs:186-188` | `string-width` → `%width-between`, one pass, no consing, `:start`/`:end` | `src/width.lisp:373-391,325-369` | SAME + EXTRA |
| `Sgr` state carrier replays open SGR onto each wrapped line | `width.rs:294-323` | none — style lives on the segment `cdr` and is carried onto continuations | `src/render.lisp:108,111,115` | MISSING as code, SAME as behaviour |
| `truncate(s, cols)` reserves a column and appends **`…`**, closes open SGR | `width.rs:329-353` | `truncate-to-width` — cluster-aware, **no ellipsis**, no reserve | `src/width.lisp:415-430` | **DIFFERS**: elision is silent |
| one truncator | — | **three**: `truncate-to-width` (cluster-aware), `%truncate-width` (per-**character**), `%truncate-segs` (segment-aware, built on `%truncate-width`) | `src/width.lisp:415`, `src/progress.lisp:160-170`, `src/markdown.lisp:473-482` | **DIFFERS-duplication**: `%truncate-width` cuts ZWJ sequences and flags in half, and it is on the card-header path (`src/cards.lisp:681,758`) |
| `fit(s, cols)` truncate-then-pad | `width.rs:356-364` | `fit-to-width` | `src/width.lisp:432-438` | SAME shape |
| `wrap(s, cols)` — three break rules in priority: space/**tab**, **between two wide clusters**, hard-break an over-wide run; hard-breaks on `\n`; `cols.max(4)` | `width.rs:380-408`, `break_cells` `:420-513` | `wrap-segments` + `%split-words` — space and `\n` end a chunk, a wide cluster is a break opportunity before itself, and an over-wide chunk is cut **by columns over clusters**; **tab is not a break opportunity** | `src/render.lisp:130-235,40-117` | **SAME for (a) (b) (c)** as of `W1`; **DIFFERS still at (d)**: a tab measures zero columns and is dropped by `clusters`/`screen-put-string`, so a tab-separated payload loses its indentation whatever the wrapper does — a separate finding, not a wrapping one |
| leading whitespace preserved; trailing space belongs to the row and is then stripped | `width.rs:464-470`, `:399-401` | same contract, documented | `src/render.lisp:36-38,65-71`, `src/markdown.lisp:495-504` | SAME |
| `wrap_ranges` shares `break_cells` with `wrap` **by construction** — "two functions kept in sync by a comment is a bug with a schedule" | `width.rs:525-542`, `:410-419` | `wrap-ranges` is an independent char-by-char walker with different rules (`\n` breaks here and not in `wrap-segments`; hard-break at a *column* vs a *character count*) | `src/render.lisp:120-154` | **DIFFERS-drift**: exactly the defect the reference's comment names |
| `wrap_ranges` is cluster- and escape-aware | `width.rs:529` | bare `char-width` per character | `src/render.lisp:141-142` | DIFFERS: a pasted emoji mis-places the composer caret |
| `locate(s, byte, cols)` | `width.rs:552-560` | `locate-in-ranges` — measures cluster-wise over char-wise breakpoints | `src/render.lisp:156-162` | SAME shape, internally inconsistent |
| `offset_at(s, row, col, cols)` — byte offset at a display column, never parked on the break space | `width.rs:567-591` | none; the composer has no up/down movement | `src/editor.lisp:509-515` | **MISSING** |

### 6.1 The reference's own width tests, against leticl

| test | ref citation | leticl |
|---|---|---|
| `a_cjk_char_is_two_columns` | `width.rs:658-664` | PASS |
| `a_combining_mark_is_not_a_column` | `width.rs:667-671` | PASS |
| `a_zwj_emoji_sequence_is_one_cluster` | `width.rs:674-680` | PASS |
| `a_flag_is_one_cluster_of_two_columns` | `width.rs:683-688` | PASS |
| `escapes_are_zero_columns_and_are_never_split` | `width.rs:691-698` | PASS |
| `truncation_does_not_cut_a_cluster_in_half` | `width.rs:701-707` | **FAIL** (no `…`; via `%truncate-width`, also splits the cluster) |
| `truncation_closes_an_open_attribute` | `width.rs:710-714` | N/A (leticl text carries no escapes) |
| `cjk_prose_wraps_even_though_it_has_no_spaces` | `width.rs:717-725` | PASS (was FAIL; `W1`) |
| `an_unbreakable_run_is_hard_broken_not_overflowed` | `width.rs:728-737` | PASS (ASCII) |
| `every_wrapped_line_is_independently_paintable` | `width.rs:740-750` | PASS |
| `wrapping_never_exceeds_the_width_for_any_input` | `width.rs:753-769` | PASS (was FAIL on every CJK input; `W1`) |
| `fit_pads_to_exactly_the_width` | `width.rs:771-776` | PASS |
| `a_newline_is_a_row_break_and_never_reaches_the_terminal` | `width.rs:598-617` | PASS (`W1`); the terminal half of it is asserted on the CELLS, because a newline is dropped by the painter's zero-width arm and never reaches the screen either way — which is what made the defect silent |
| `wrap_ranges_tile_the_input_and_agree_with_wrap` | `width.rs:620-656` | **FAIL** |

---

## Performance: the reference caches, we re-render

### What each head actually does per frame

**The reference** keeps three things across frames:

- `hist_lines: Vec<String>` — every committed row's **painted output**, appended
  once and never rebuilt unless something invalidates it
  (`app.rs:5702-5836`). `hist_upto` is "every row at or below this index is
  accounted for", so a steady-state frame with no new row does **zero**
  `item_lines` calls. `hist_renders` counts them, and a test asserts the budget
  (`app.rs:13475-13503`).
- `hist_marks: Vec<HistMark>` — `(lines, note_upto, class)` before each row, so
  `invalidate_history_from(k)` can rebuild from row *k* instead of from zero
  (`app.rs:9322-9330`, `:4822`).
- `BlockCache` per markdown document (`render.rs:676-703`) — the frozen blocks'
  lines, keyed on `(width, color, base, decor, limit)`, plus one streaming
  highlighter per open code block. A growing decode re-lexes only the tail.

Plus `fill_backward` (`app.rs:5484-5563`): above `SELF_WALK_LIMIT = 2 MiB`
(`app.rs:9191`) the head renders only the tail — `room + TAIL_SLACK` (40) lines —
and walks further back only when the reader scrolls. Measured in the reference's
own notes: 1200 rows, full walk 9.6 ms, tail 0.1 ms.

**leticl** rebuilds the visible window every frame. `%viewport-lines`
(`src/render.lisp:207-276`) walks the item vector backwards from the newest,
calling `item-lines` on each row until it has `head-scroll + want + 1` lines, and
throws all of it away when the frame ends. There is no `hist_lines`, no
`hist_marks`, no `BlockCache`; `markdown-lines` (`src/markdown.lisp:689`) re-lexes
every visible paragraph on every tick, and `highlight-fence`
(`src/markdown.lisp:228-243`) makes one FFI call per visible fence per frame over
the **whole** fence, where the reference keeps a `CodePaint` per open block and
feeds it only the delta (`render.rs:188-242,685-692`). The reasoning rail is
`mapcar`ed onto every line every frame (`src/cards.lisp:771-782`) where the
reference applies it once, as a `Decor`, when the line enters the cache
(`render.rs:646-672,788-789`) — §13.3's rule, in the reference's own words.

### What we already have, and what it cost to get there

leticl **already has the architecture half** of `fill_backward`: the backward
walk means a 160 MB session does not get lexed to draw its last forty rows. What
it does not have is the *memo*. The archived measurement
(`docs/archive/2026-09-20/PARITY.md:746`) puts the whole frame at **0.46 ms at
210×63** after the declaration/typing pass — `string-width` through `clusters` was
41% of the frame and 53% of `markdown-lines` before that pass, and the
`%width-between` rewrite took a 100k-width corpus from 2158 ms to 65 ms
(`src/width.lisp:332-334`).

So at 63 rows the per-frame re-render costs about half a millisecond, against a
frame budget of 16 ms. It is not the bottleneck today.

### What a cache would gain

- **Scrollback into a long session.** The cost of `%viewport-lines` is linear in
  the *window*, not the transcript — but each PageUp re-renders the whole new
  window from scratch. The reference's `scroll_up` (`app.rs:5607-5615`) renders
  once and keeps it. On a session where a single row is a 400-line diff, our
  window render is dominated by `render-diff` and `highlight`, and we pay it
  again on every frame the reader spends looking at it.
- **Headroom for the gaps in this document.** The payload window (§1.6), a
  `head_tail` budget on the live card (§1.8), a proper wide-cluster wrap (§6),
  syntax colour in the split panels (D4) and a wrapping split diff (D2) all add
  per-row work. 0.46 ms is comfortable; 0.46 ms × 4 on a 30 Hz tick is not.
- **The one cache that is unambiguously worth it first.** A memo on
  `highlight-fence` keyed on the fence text (D10) is not a cache of *the screen*
  — it is a cache of a pure function of bytes, so none of the invalidation
  problem below applies to it. A screenful of code blocks currently pays the
  whole FFI grid every tick.
- **A number to assert on.** `hist_renders` lets the reference write a test that
  says "a frame with no new row renders no rows". We have no such invariant and
  therefore no way to notice when a change makes the frame quadratic.

### What it would cost

The invalidation key is the hard part, and the reference pays for it explicitly:
`BlockCache` keys on width, colour, base role, decor **and** the line limit
(`render.rs:676-703`, "collapsing reasoning changes it, and a prefix rendered
under the old bound is as stale as one rendered at the old width"). On our side
the key would also have to include `head-prefs` (`:show-reasoning`, `:show-tools`,
`:diff`, `:raw-calls`), `*item-facts*` (a settled row's duration and diff arrive
*after* the row), `*call-targets*`, `*answered-calls*` and `*pane-scroll*`. Every
one of those is a defvar that any eval can change — which is the whole point of
this head — so a cache also needs an explicit "a push invalidates me" hook or it
becomes the thing that makes `tui-eval --file src/cards.lisp` stop working.

That is the real trade: **a cache is a second source of truth about the screen, in
a head whose contract is that redefining a renderer changes the screen on the next
frame.** The reference does not have that constraint. Recommendation: do not port
`hist_lines` yet. Port the *instrumentation* first — a counter of `item-lines`
calls per frame, and a test that bounds it — so that when the number does start to
matter there is evidence rather than a guess. If a cache does land, it should be a
`defclass` (HACKING.md: classes reshape live, structs do not) and
`%render-and-paint` should clear it whenever `*last-render-error*` was set or the
paint lock was taken by an eval.

---

## Gaps worth closing

Ordered by what a person would notice first.

### The transcript row

1. ~~**Wide/CJK prose does not wrap**~~ — **CLOSED in `W1`.**
   `src/render.lisp:40-117,130-235` vs `width.rs:373-377,454-478`. Two halves,
   and both were needed: `%split-words` split on spaces alone, so a CJK paragraph
   was ONE chunk; an over-budget chunk was then cut **by character index**, so each
   piece was `2×cols` columns and the painter dropped everything past the right
   edge **in silence**. Measured on a 300-cluster paragraph in a 24-column body:
   **156 of 300 clusters reached the screen and 144 were destroyed**, each row
   ending mid-word and looking merely short. Now 300 of 300, in 25 rows rather
   than 13. Asserted by `a-wide-character-line-wraps-at-the-column-budget`,
   `a-cjk-run-fills-the-row-it-started-on` and
   `an-over-wide-mixed-run-keeps-every-cluster` — each verified to fail without its
   own half of the rule — and by the same paragraph drawn through a live head's
   screen, 60 of 60 clusters. **S** (was estimated M; the fix is two functions and
   a helper in `width.lisp`).
2. **Two divergent breakpoint finders** — `wrap-segments` (`src/render.lisp:130`)
   vs `wrap-ranges` (`src/render.lisp:240`). The reference routes both through
   one `break_cells` and says why (`width.rs:410-419`). Composer caret placement
   and transcript wrapping can disagree. **L.** The row above this one is now
   closed and the drift is narrower: both finders break at a newline and at a wide
   cluster, and differ only in where they cut an over-wide run (a column budget vs
   a character index).
3. **`shorten_subject` cuts a path at a character, not at a `/`** —
   `src/cards.lisp:501-520` vs `app.rs:9074-9109`. Every long tool-result header
   in a deep tree shows a subject that cannot be pasted back into a shell, and on
   a non-ASCII path it overshoots the column budget. **S**
4. **The `→` row does not say `· no result`, and is not in `Attention`** —
   `src/cards.lisp:878-883` vs `app.rs:9614-9645`. The row's only meaning today is
   "asked for, nothing came back", and nothing on it says so. **S**
5. **`SegmentMark` renders nothing** — `src/cards.lisp:901` vs `app.rs:10042`.
   A `/compact` boundary is invisible. **S**
6. **A row whose body has not arrived draws a red placeholder** —
   `src/cards.lisp:813-815` vs `app.rs:9525-9542`. On a `/reseat` this is the
   *"insane amount of grainess"* the reference removed by drawing nothing. **S**
7. **The payload window** — `app.rs:9968-10036` has no counterpart. A 400-line
   tool result is unreadable past its first forty lines: `ctrl-t` changes the
   budget and there is no offset to page. **M**
8. **`fold_cells` keeps the marker instead of replacing the block** —
   `src/cards.lisp:361-376` vs `app.rs:8980-9001`. Different text and a different
   shape, on every `/cells` message in the transcript. **S**
9. **`decision_detail` is one line of five** — `src/cards.lisp:650-665` vs
   `app.rs:9462-9507`. The oracle's advice, its citations, the loud empty-cites
   case and "no oracle was consulted" are all absent, so an authorisation that was
   grounded in nothing looks the same as one grounded in four utterances. **M**
10. **User parts are joined with no separator and non-text parts vanish** —
    `src/session.lisp:426` vs `app.rs:8550-8558`. **S**
11. **`System` rows are yellow and carry no origin** — `src/cards.lisp:896-900`
    vs `app.rs:9544-9548`. **S**
12. **The live card has no bytes disclosure, no decision block and no `head_tail`
    budget** — `src/cards.lisp:959-965` vs `app.rs:8767-8780,8842-8864` and
    `card.rs:482-511`. The §8.3 disclosure is the one with an obligation attached;
    the budget is the one that stops a folded card from filling the screen. **M**
13. **A failed turn's footer is not wrapped** — `src/cards.lisp:1036,1061-1065`
    vs `app.rs:8232-8245`. A long error is cut at the frame edge, and "the reason
    is the whole content of the event". **S**
14. **`queued_lines` has the wrong glyph, colour and tag position, and shows one
    line** — `src/cards.lisp:1082-1087` vs `app.rs:9017-9046`. **S**
15. **`drawn_live` has no counterpart** — while a turn runs, an unsettled call is
    drawn by both the assistant row and the live card. `app.rs:9608`. **S**

### Markdown

M1. **`***both***` and `**bold *italic***` leak their asterisks** —
   `src/markdown.lisp:78-87` vs `markdown.rs:1947-1956`. The most common
   emphasis shape after `**`, and a marker on screen is the one failure this
   whole surface exists to remove. Fix: try the 3-character `***` case first, or
   skip a `*` run longer than the delimiter when scanning for the closer. **S**

M2. **A fence inside a quote, and a fence on a list marker's line, are not
   found** — `src/markdown.lisp:270-276` vs `markdown.rs:713-789`. The model's
   code renders as prose with literal ``` markers. This is exactly what the
   reference wrote `split_container` for. **M**

M3. **A closing fence ignores the opener's length** — `src/markdown.lisp:278-280`
   vs `markdown.rs:819-834`. ```` ```` ```` is how a model quotes a fence when it
   is *teaching*; leticl cuts the demonstration in half and spills the rest as
   prose. Carry the opener's char and length through `markdown-blocks`. **S**

M4. **Indented code blocks render as prose with the indent trimmed away** —
   `src/markdown.lisp:458-463` vs `markdown.rs:971,1161-1177`. The code is not
   merely uncoloured, it is mangled. **S**

M5. **Ordered lists renumber per item and a loose list gains blank rows** —
   `src/markdown.lisp:646-648,695-701` vs `render.rs:408-414`,
   `markdown.rs:2016-2040`. `1. / 1. / 1.` (very common model output) renders as
   three `1.`s, and a six-point answer is twice as tall as the reference's.
   Needs the `:list` block to survive a blank line and to carry a `start`. **M**

M6. **An unhighlightable fence's body is dim** — `src/markdown.lisp:240-243` vs
   `render.rs:190-192,256-258`. Every language the shim lacks reads as
   de-emphasised, which is the opposite of what a code box is for. **S**

M7. **Autolinks and reference links show their brackets** —
   `src/markdown.lisp:178-187` vs `markdown.rs:599-623`. `<https://…>` is what a
   model writes for a bare URL. About ten lines. **S**

M8. **Setext headings, `~~~` fences and task-list checkboxes are unrecognised** —
   `markdown.rs:950,722,1050`. Three small independent lexer additions. **S** each

M9. **The fence header names the raw info string, not the grammar** —
   `src/markdown.lisp:633` vs `render.rs:296-298,375-379`. `┌─ sh` where the
   reference says `┌─ bash`. **S**

M10. **The bounded-block title is the raw source** — `src/markdown.lisp:506-518`
    vs `markdown.rs:184-199`. A folded block's title can show `**markers**`.
    Also off by 2 in its truncation (`src/markdown.lisp:684` vs
    `render.rs:631`). **S**

M11. **Trailing-space trim is per-segment, not per-row** —
    `src/markdown.lisp:495-504,596` vs `render.rs:528`. A table row ending in an
    empty cell keeps `│ ` with a trailing space. Invisible until copied, and the
    reference explicitly fixed exactly this. **S**

M12. **Tables and lists inside quotes keep their pipes and markers** —
    `src/markdown.lisp:430-434` vs `markdown.rs:1045-1085`. Lower frequency than
    M2, same class. **M**

### Diff and highlighting

D1. **Intra-line word emphasis is dead code** — `src/diff.lisp:297-298` binds
   `add-start` and `add-end` after consuming the addition run, where
   `diff.rs:555` binds `add_start` before it. `%pair-rows` therefore always
   returns all-`NIL`. All the machinery beneath it is correct and tested
   (`tests/tests.lisp:560-575`); only the wiring is wrong. **Note the second
   half**: both reference call sites pass `intra_line: false`
   (`app.rs:8817,9934`) while ours passes `t` (`src/cards.lisp:1005`), so
   fixing the bug alone would make leticl start emitting emphasis the reference
   deliberately suppresses. Fix both, or the fix is a regression. **S**

D2. **The split diff truncates where the reference wraps** —
   `src/sidediff.lisp:94-100,134` vs `sidediff.rs:270-287,308-326`. This
   silently hides the changed tail of any line longer than half the pane, which
   `diff.rs:336-341` names as "the one thing a diff must not do". Needs per-side
   wrap, `max(left,right)` rows, blank-the-other-side, and a per-terminal-row
   budget that keeps pairs atomic. **M**

D3. **The split diff has no role colour at all** — `src/sidediff.lisp:198-200`
   vs `sidediff.rs:290-374`. No `48;5;22`/`48;5;52` tint to the panel edge, no
   green/red sign, no line-number foreground. The cell painter already resets
   per segment, so the `Painter::rebase_resets` half of the reference's problem
   is free here; what is needed is per-half role plumbing and a
   pad-inside-the-tint segment. **M**

D4. **The split diff is not syntax-coloured** — `sidediff.rs:106-107,389-433`
   has no counterpart. The shim, `class-grid` and `role-style` all exist;
   `edit-split-lines` simply drops `(getf edit :path)`
   (`src/sidediff.lisp:208-222`). **M**

D5. **The split diff refuses at a narrow width where the reference degrades** —
   `src/sidediff.lisp:169-174` vs `sidediff.rs:168,471-477`. leticl's own file
   header at `src/sidediff.lisp:13-16` promises the reference's behaviour. **S**

D6. **The split diff has no hunk header, no `no change` row and no degraded
   banner** — `sidediff.rs:93-119,173-194`. A multi-hunk split diff currently
   runs its hunks together with nothing between them. **S**

D7. **Split cell arithmetic is one space short either side of the sign** —
   `src/sidediff.lisp:128-134` (`numw + 1`) vs `sidediff.rs:167,363`
   (`numw + 3`). **S**

D8. **A trailing newline adds a phantom blank diff row** —
   `src/cards.lisp:967-974`, `src/sidediff.lisp:137-139` vs
   `sidediff.rs:451-452`. `uiop:split-string` keeps the final `""` where
   `str::lines()` drops it. **S**

D9. **SAPs are passed unpinned across the alien boundary** —
   `src/highlight.lisp:101-105`. `sb-sys:vector-sap` on two Lisp vectors with no
   `sb-sys:with-pinned-objects`; a moving GC may relocate either mid-call.
   `RANO.md:85-87` documents an allocation strategy the code does not use, so
   fix the code and the note. **S**

D10. **Fences are re-highlighted through the FFI on every frame** —
    `src/markdown.lisp:228-243` vs `render.rs:188-242`. One `hl_grid` call per
    visible fence per frame, where the reference feeds only the delta once. A
    memo keyed on the fence text is the minimum. **M**

D11. **Three language tables where the reference has none** — the shim's
    `id_from_lang`/`lang_from_id` pair (`native/hl/src/lib.rs:40-103`) and the
    markdown fence-name table (`src/markdown.lisp:197-226`), against rano's own
    `detect`/`Lang::from_token`. Adding `hl_detect_token` to the shim deletes
    the third. The reference pins the property with
    `a_language_rano_gains_arrives_without_a_second_table`
    (`sidediff.rs:748-757`). **S/M**

D12. Perf only, invisible at card sizes: `nth`/`elt` over lists in `hunks` and
    the token Myers are O(n²) in the changed-op / token count, and `render-diff`
    accumulates with `append` in a loop (`src/diff.lisp:194-203,262-264,448-471`). **S**

### The frame

16. **No fit ladder and no backstop** — `src/render.lisp:306-320` vs
    `app.rs:5094-5126,5206-5208`. On a short terminal the head can compute a
    negative cursor row and return more rows than the terminal has. **M**
17. **The gutter is never given up** — `src/render.lisp:414-428` vs
    `app.rs:5325-5327`. At 30 columns we throw away 4 of them. **S**
18. **`turn_status` has the spinner and the count in the wrong places, and no
    prefill arm** — `src/chrome.lisp:377-400` vs `app.rs:7538-7566`. The prefill
    bar never reaches the composer's edge, which is the one number this harness
    exists to move. **M**
19. ~~**The stall line is on the wrong row, at the wrong threshold, with the
    wrong text**~~ — **closed by `4e32354`** while this pass was running, along
    with the notice row that had the same defect. What is left is one constant:
    `*stall-ms*` is 20000 (`src/chrome.lisp:285`) where the reference fires at
    15000 (`app.rs:7592`). **S**
20. **The box's top legend is left-pinned and bold** — `src/chrome.lisp:480-490`
    vs `app.rs:5384-5411,5157-5173`. Invisible until a subagent runs. **S**

### Styles and width

21. **`truncate-to-width` has no `…`** — `src/width.lisp:415-430` vs
    `width.rs:329-353`. Every elision on the pane and diff paths is silent. **S**
22. **Three truncators, one cluster-unsafe** — `%truncate-width`
    (`src/progress.lisp:160-170`) walks characters and is what every card header
    uses. **S**
23. **`Role::Attention` is collapsed onto `Pending`** — `src/cards.lisp:381,383,386`
    vs `style.rs:180`, `card.rs:186-195`. Abstained, denied and backgrounded read
    as one colour, and §8.2's rule is a rule about exactly this display. **S**
24. **No `Palette::None`** — `style.rs:142-151` has no counterpart. There is no
    byte-identical uncoloured output for a replay, a pipe or CI. **M**
25. **No guard against leaving the sixteen theme slots** — `src/cells.lisp:44-59`
    accepts truecolour and any cube index; the reference pins the two allowed
    exceptions with a test (`style.rs:413-455`). Port the test. **S**
26. **`NumberLit` and `FuncName` use bright slots** —
    `src/highlight.lisp:118,121` vs `style.rs:205,211`; `96` also puts
    `TypeName`/`FuncName` on one hue. **S**
27. **Reasoning nesting merges instead of switching** — `src/cards.lisp:776-779`
    vs `card.rs:584-592`. **M**
28. **Payload control characters are elided, not spaced** — `src/cards.lisp:607`
    vs `app.rs:9712`. Safe, but the row's visible width differs from the
    reference's on every payload carrying an escape. **S**
29. **`style-index` does not canonicalise plist key order** —
    `src/cells.lisp:101-110`. `'(:fg :red :bold t)` and `'(:bold t :fg :red)`
    intern as two styles with different bytes. **S**
30. **ZWJ-before-control absorbs the control** — `src/width.lisp:309` fires
    before `:314`, inverting `width.rs:116` vs `:134`. One-line reorder. **S**
31. **`offset_at` is missing** — `width.rs:567-591`; the composer has no up/down
    movement (`src/editor.lisp:509-515`). **M**

---

## How each gap should be tested

### Pure renderers — assert the bytes

Everything in §1, §2, §5 and §6 is a function from data to lines, so the
assertion is on the **exact output**, not on a property. `tests/tests.lisp` is
FiveAM (`def-test … (:suite leticl)`) and already exercises `item-lines`,
`markdown-lines` and `render-diff`.

- **Row arms** (gaps 4, 5, 6, 8, 10, 11, 13, 14) — build the wire plist by hand,
  call `item-lines` with a fixed `cols` and `prefs`, and `is (equal … )` against
  the full segment list. A segment list is `((text . style) …)`, so this pins the
  text *and* the style in one assertion — which is what the reference's
  `assert!(h.contains(...))` cannot do. For the `→` row:
  `(is (equal (list (cons "  → " '(:dim t)) …)) …)`. For `SegmentMark`, assert
  one line whose text is `"─── {label} ───"` and whose style is `'(:dim t)`.
- **The header arithmetic** (gap 3) — port `shorten_subject`'s own measured cases
  verbatim: `…/worktrees/agent-a19da2/crates/tui` must come back with a leading
  `…` followed by a **`/`**, and `**/*.{md,json,toml,yaml,yml} 40` must be cut
  from the right. Assert `(string-width result) <= max` for both.
- **Width** (gaps 1, 21, 22, 30, 31) — port the thirteen `#[cfg(test)]` cases in
  `width.rs:598-776` one for one. They are already written as byte assertions and
  four of them fail today (§6.1); a port that does not make them fail first is a
  port of the wrong thing. The property test
  `wrapping_never_exceeds_the_width_for_any_input` (`width.rs:753-769`) is the one
  that catches the wide-cluster gap, and its inputs are in the source.
- **Styles** (gaps 23, 25, 26, 29) — assert `%style-sgr` output directly, the way
  `tests/tests.lisp:69-80` already does for `\e[0;1;36m`. For gap 25, port
  `no_role_paints_outside_the_sixteen_colours_a_theme_defines`
  (`style.rs:413-455`) as a grep over `src/*.lisp` for `:fg`/`:bg` integers,
  allowing exactly `22` and `52` — the same shape as the existing
  `live-state-tables-are-defvar` check. For gap 29, assert
  `(= (style-index '(:fg :red :bold t)) (style-index '(:bold t :fg :red)))`.
- **`Palette::None`** (gap 24) — the test is that `screen-rows-ansi` under a
  no-colour mode contains no `\e[` at all, on a frame that exercises every role.
- **Markdown** (M1–M12) — the reference's own `#[cfg(test)]` cases are already
  written as exact assertions on `runs_text`, `lines`, `lang`, `closed` and
  `align`, and §2.5 lists which fourteen fail today. Port those fourteen first,
  as `markdown-blocks` assertions where the reference asserts on the model and
  as `markdown-lines` segment-list assertions where it asserts on the string.
  The four that matter most are byte-level one-liners:
  `(is (equal (inline-spans "***both***") '(("both" :bold t :italic t))))`;
  `(is (equal (getf (first (markdown-blocks "````~%```rust~%```~%````")) :lines) '("```rust" "```")))`;
  `(is (equal (inline-spans "<https://x>") '(("https://x" . nil))))`; and the
  quoted-fence case, which asserts `markdown-blocks` returns a `:code` block
  whose `:lines` have no `>` in them.
- **Diff** (D1, D7, D8) — `tests/tests.lisp:560-575` already exercises
  `word-spans` in isolation and passes, which is exactly why the dead wiring
  survived. The missing test is one level up: call `render-diff` with
  `:intra-line t` on two lines that differ by one word and assert that some
  emitted segment carries `:underline t`. That test fails today and is the whole
  proof of D1. D7 is an assertion on `(string-width (segs-text-of row))` and on
  the column the body starts at; D8 is `(is (= 1 (length (render-diff '("a")
  '("b") …))))` for a side built from text ending in a newline.

### Everything else — a capture comparison, and what it has to show

Gaps 7, 12, 15, 16, 17, 18, 19, 20 are about *state the current screen does not
reach*, so a byte assertion on a synthetic plist proves the renderer and not the
head. Each needs `scripts/compare-heads` in a **specific** state, and the finding
is the row:

| gap | the state to put both heads in | what the capture must show |
|---|---|---|
| D2–D6 split diff | `/config` → diff = split, then a landed `edit` whose new side has a line longer than half the pane | letibot's panel wraps that line onto a second row with the other side blank, tints both rows to the panel edge, and colours the code; leticl shows one row, truncated, flat bright-white |
| D10 fence highlight | any screen with a visible fenced code block, held for 60 frames | not a capture — an `item-lines` call counter (below) |
| M2/M3 fences | a message containing a fence inside a `>` quote, and a 4-backtick fence quoting a 3-backtick one | letibot draws two `┌─ … └─` boxes; leticl draws quote prose with literal backticks and a box that ends early |
| M5 lists | a six-item loose ordered list all written `1.` | letibot: six rows numbered `1.`–`6.`, no blanks between; leticl: eleven rows, all numbered `1.` |
| 7 payload window | a tool result of >40 lines, `ctrl-t`, then `↓` twice | leticl's seam row reads `… +N lines · ctrl-t` and never moves; letibot's reads `↑ 2 more lines above · ↑ scrolls up` at the top and `… +N lines · ↓ pages down · esc closes` at the bottom, and the body rows differ |
| 12 live card budget | a live `edit` call mid-turn with a 60-row diff, tools folded | letibot's card is 14 rows (header + 10 + marker + 3); leticl's is 61 |
| 12 bytes disclosure | any finished live call | letibot's card carries a `{n} B` body row; leticl's does not |
| 15 `drawn_live` | a turn with two calls in flight | leticl shows `→ Read x` above `◐ Reading x`; letibot shows only the card |
| 16 fit ladder | resize the pane to 10 rows, then 4, then 2 | at each size letibot returns exactly `h` rows with a composer visible; leticl's row count and caret position are the finding |
| 17 gutter | resize to 30 columns | letibot's header starts at column 0 and is 30 wide; leticl's starts at 2 and is 26 |
| 18 turn_status | a turn running with prefill in progress | letibot's bottom border carries `⠙ prefill 61% ▐████▓▓░░░▌ · 2.4k tok/s · ~12s left`; leticl's carries `Responding · 1.2k chars · 4.2s · ⠙` |
| 19 stall threshold | stop the daemon's event flow mid-turn; capture at 16 s and again at 21 s | letibot has the yellow row at both; leticl (post-`4e32354`) only at 21 s. That one constant is the whole remaining difference |
| 20 box legend | a session with a subagent running | letibot: `╰…… ⚠ · ⠙ Responding ─╯` and `╭…… 1 subagent running ─╮`; leticl: `╭ 1 subagent running ────╮` |

Two rules for these, from `HACKING.md`:

- **Both heads must be at the same scroll and the same fold state**, or the diff
  is a diff of positions. The run taken for this document was not — rows 2
  onward differed because one head had `ctrl-r` open and the other `ctrl-t`, and
  nothing in that diff is a rendering finding.
- **`-e` is the point.** `compare-heads` captures escapes, and tmux re-emits from
  its own cell buffer — so what is being compared is the *cell attributes*, not
  the byte stream. That is the right comparison for this head (segment splitting
  is free) and the wrong one for a claim about emitted bytes, which belongs in a
  unit test against `screen-rows-ansi`.

### Performance — count, do not time

The reference's `hist_renders` (`app.rs:5785`) exists so a test can say "a frame
with no new row renders no rows" (`app.rs:13475-13503`). We have no such
invariant, so a change that makes the frame quadratic would be invisible until
somebody noticed the head feeling slow. Before any cache work, add two counters
— `item-lines` calls per frame and `hl-grid` calls per frame — and two tests
that bound them on a fixed transcript. A count is reproducible on any box; a
millisecond is not, and the 0.46 ms figure in this document is a measurement of
one machine on one day.

Finally: gaps 1, 2, 3, 22 and 30 change what `string-width` and the wrap agree
on, and `screen-put-string` places what `string-width` measured
(`src/cells.lisp:176-181`). Any fix to one of them needs
`string-width-agrees-with-clusters` (`src/width.lisp:329`) re-run, and a capture
at 210×63 to confirm no border moved.
