<!-- abstract: Chasing the reference's "derive the hover light from the frame" rule: the three things that were still wrong when I backed out, with the measured numbers. -->

# The hover light, and the two columns that beat me (2026-10-14)

The reference spent **two** commits on this (`76af4c1`, then `9c3e0b1`) — *"the hover is worked out
from the frame that is drawn, not kept"*. This head adopted the headline (`1856f4a`: `%hint-key-at`
is a pure query, `%hint-click` is the act, the light asks the query) and it is green. I then tried
to land its other half — the OSC 22 hand pointer, and the light derived per *draw* rather than from
the painted cells — and **backed out after ~20 rounds**, because the tree was green and my guesses
were not converging. What I measured, so the next attempt starts here:

## 1. The render's `cols` is NOT `head-cols`

`%render` (src/render/history-cache.lisp, ~1381-1386) binds:

    (term-cols (head-cols head))
    (gutter    (frame-gutter term-cols))
    (cols      (max 20 (- term-cols (* 2 gutter))))

and composes the hint bar to **`cols`** — the BODY width. Anything outside the render that wants to
know where the bar's words land must use that number, not `head-cols`. At 120 columns they differ by
exactly the gutters (116 vs 120), which is **two columns of error in the bar's start**, and it is
invisible in every test that uses a narrow head or a bar that fills its row.

## 2. `%hint-key-at`'s X is an index into the ROW's text, which already carries the centring spaces

`%screen-row-text` returns the whole row, so a screen column IS the index — **no subtraction**. (I
"fixed" that twice in opposite directions; the second time broke five click tests, which is what
told me.) The bar's SEGMENTS, by contrast, begin at its first word, so a reader working from
`(hint-bar head cols)`'s text DOES need `(- x start)`.

## 3. At render time the cells are not this frame

`%hint-key-at` reads the screen, and a render composes before it paints — so asking it *inside*
`%render` answers for the previous frame (or nothing). The want has to come from the segments the
render is about to place, at the bar's own columns.

## Where it stopped

With those three applied (`(+) (- *pointer-x* start)` against the segments, `%frame-body-cols` in
the test), the light still came out NIL at x=22/start=20, and I could not see why from the numbers
alone — `(%hint-word-at text 2)` on a bar beginning `"ctrl-s …"` is a key by inspection. **The next
attempt should print the RENDER's own `segs` string**, not just its column arithmetic; that is the
one value I never looked at, and it is the one that would settle it.

**Lesson kept**: when a fix has a green tree behind it and two rounds do not converge, back out and
write the numbers down. Twenty rounds of guessing is not cheaper than the twenty minutes a note costs.
