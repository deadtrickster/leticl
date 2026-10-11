<!-- abstract: The reference's mouse routing, ported as far as the facts: the level filter, both encodings, and the ONE thing left to solve — the pane's origin in the head's coordinates, which the render layer must state. -->

# Sending the mouse to a `!term` program — what is known, and the one thing that is not

Measured 2026-10-11, reading `letibot/letibot/crates/tui/src/app/term_pane.rs` (`encode`, `mouse`,
`route`) against this head. The screen's side is LANDED (`ac09047`: `term-screen-mouse`, recording
`?9`/`?1000`/`?1002`/`?1003`/`?1006`). This is the SENDING half, which is not.

## What the head already has

`src/keys.lisp` decodes its own terminal's mouse into key plists — **the raw report is already
parsed**, so the port starts at the decision, not at the bytes:

    (:type :mouse :x X :y Y :kind :wheel-up)              ; codes 64/65, no :button
    (:type :mouse :x X :y Y :kind :wheel-down)
    (:type :mouse :x X :y Y :kind :wheel-other)           ; 66/67 and anything >= 64
    (:type :mouse :x X :y Y :button B :kind :motion)      ; +32, B with the bit masked OFF
    (:type :mouse :x X :y Y :button B :kind :press)       ; the SGR final was M
    (:type :mouse :x X :y Y :button B :kind :release)     ; … and m

**The modifier bits (shift 4, meta 8, ctrl 16) are masked and deliberately NOT kept** — `mouse-event`'s
own docstring is emphatic that a `:mods` field read by nothing is a claim rather than a placeholder.
So a shift+wheel is sent as a plain wheel; the reference keeps the raw byte and would send the
modifiers. That is a divergence to decide when the sending lands, not a bug.

## The reference's decision table (`TermPane::mouse`)

    let (x, y) = the TERMINAL's coordinate MINUS the pane's origin, kept only in 1..=cols / 1..=rows
    if tracking != Off:
        wanted = wheel?                          -> true
                 no motion                       -> true
                 motion, button held (b&3 != 3)  -> tracking in {Drag, Motion}
                 motion, NO button  (b&3 == 3)   -> tracking == Motion
        return encode(r, sgr, x, y) if wanted, else nothing
    else (Off): a wheel goes to the SCROLLBACK path (not built here); anything else sends nothing

## The two encodings (`encode`)

    SGR (?1006):  ESC [ < {button} ; {x} ; {y} {M press | m release}      button VERBATIM
    X10:          ESC [ M  32+button'  32+x  32+y                         one-based;
                  a release has NO flag, so it is button' = (button & !3) | 3;
                  and a column or row past 223 CANNOT be carried -> send NOTHING

## THE ONE THING NOT SOLVED: the pane's origin

The reference computes its x/y from `self.origin` — **where the pane actually sits in the terminal** —
and everything above depends on it. This head has the rectangle (`%term-rectangle`: cols = the head's
cols, rows = height - 1) and the pane draws the screen under a 2-column indent and a one-row header
plus a blank (`pane-lines` for `term-pane`: the `term WxH` line, a NIL, then the rows). So the
origin is *what the render layer placed*, and computing it by counting those lines in the pane's own
output is the honest way — a constant would be right until the first time the header changed.

**Do not send a report until that origin is read off the render, or every click is off by however many
rows the header happens to be** — and a wrong coordinate to a full-screen program is worse than no
mouse at all, because the program acts on it.
