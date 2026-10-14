<!-- abstract: R69's surface stack: the reference's own rule verbatim, this head's measured shape (18 write sites, 59 reads, 20 files, 3 scroll globals), the four tests that pin it, and the order to migrate in. -->

# R69, the surface stack — the rule, and this head's measured shape

## The rule, verbatim (`crates/tui/src/app/surface.rs`, header)

> **One stack, and its top is the surface.** Opening pushes (or brings an open one to the top), Esc
> pops, and `App::drawn` is the single answer that `main_area` draws, `App::key` routes and `hint_bar`
> describes. **A surface that is not on top is not drawn and receives nothing — its cursor and its
> scroll wait for it, kept per entry**, so coming back to it lands where the reader left it.
>
> The overlays a pane opens over itself … are surfaces on the same stack with the pane as their
> `parent`: **Esc goes back to the list because the list is the next entry down**, not because a
> handler was placed above another one in a long function.

## What it replaced, and what that cost — the reason not to do this by halves

Nine `bool`s (`help`, `stats`, `picker`, `todos_pane`, `config_pane`, `queue_pane`, `standing_pane`,
`subagents_pane`, `jobs_pane`), each toggle flipping only its own, and **three hand-written orders**
that decided what that meant: the draw order in `main_area`, the key order in `App::key`, and the hint
bar's. They disagreed. The review of 2026-10-11 measured it: *`ctrl-t` then `ctrl-g` drew the todos
pane while ↑↓ and Enter went to the hidden subagents list, and **Enter switched session into a row
nobody saw***. One shared `pane_scroll` made `scroll_into_view` jump the visible pane for a cursor
moving in a hidden one.

**So a stack that some paths push onto while others still `(setf (head-mode …))` is the same defect
wearing the fix's name.** Migrate all of it or none.

## This head's shape, measured 2026-10-14

    (setf (head-mode head) …)     18 sites
    head-mode reads               59 sites
    files touching head-mode      20
    scroll globals needing to become per-entry: *pane-scroll*, *card-scroll*, *payload-view*

`%open-pane` (`src/commands/the-operator-todos.lisp:987`) states the opposite as deliberate in its own
docstring — *only one is open at a time* — so the decision it encodes has to be reversed, not worked
around.

## The four tests that pin the reference's behaviour (from the survey)

`with_two_panes_open_the_keys_reach_the_one_drawn`,
`esc_pops_the_top_and_the_covered_pane_keeps_its_scroll`,
`a_chord_brings_a_covered_pane_forward_and_closes_the_one_in_front`,
`a_setting_card_over_a_pane_takes_esc_first`.

## Order to migrate in (each step green before the next)

1. **`*surfaces*` + `%push-surface`/`%promote-surface`/`%pop-surface`**, with `drawn` = `(first
   *surfaces*)` and `head-mode` kept as a DERIVED reader for the 59 read sites — so nothing changes
   behaviourally and the tests stay green. This is the only step that can be done alone safely.
2. **`*pane-scroll*`, `*card-scroll*`, `*payload-view*` become per-entry** (the "kept per entry" half).
   Step 1 without this is a stack that loses the reader's place on every pop.
3. **The 18 write sites become pushes**, in one commit per group (the pane toggles; the overlays with
   their parent; `shut-overlays`; `%switch-to`).
4. **Esc pops**, through `pane-escape-target`, and the four tests above are ported.
5. **The hint bar and the ladder ask `drawn`** rather than `head-mode`, which is what removes the three
   orders' ability to disagree.

## Why it is still on the board

Steps 1 and 2 are mechanical but large, and steps 3–5 are what actually change behaviour — with 18
sites and 20 files, an interrupted migration leaves the head in the state the reference spent a review
finding. **This is a session's work, not a round's.**
