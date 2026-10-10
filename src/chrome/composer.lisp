;;;; composer — the composer: the operator's line, drawn
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; --------------------------------------------------------- the composer ;;;
;;;
;;; A box with a title, whose bottom edge carries the WIRING (model · dialect ·
;;; endpoint) — the reference's shape, and the most visible structural
;;; difference this head had: a bare `›` line against a framed one.
;;;
;;; Degrades on a short screen: drawing a box costs two rows (its top and bottom
;;; edges) and this returns the bare line instead when the frame has not got
;;; them, so the composer never eats the last row of the transcript.

(defvar *subagents-seen* 0
  "DELETED — the pointer this counted was reverted. A finish is announced by the DAEMON, as a
`User { speaker: Agent }` transcript row every head already renders; a head-side pointer beside it
would be a second announcement of one fact. Kept as a stub only long enough to say so if a running
image still holds it.")

(defun composer-title (head)
  "The right-hand legend of the box's TOP edge: what is RUNNING — subagents and jobs.

**MOVED BACK HERE 2026-10-04, on the operator's word:** *\"ok, so please bring counters back to the input
box border top right.\"* `9954b2c` had moved the SUBAGENT count down to the row above the box (and the
jobs count was already on that row), which answered *\"subagents count shown in one place and jobs count
in another\"* — this answers the same question the other way: one place for both, and the place is the
border, right-hand side, which is where the reference puts its `N subagents running`.

**Nothing is nothing**, on both halves: a zero is not drawn rather than drawn as `0 jobs running`, so a
quiet head has a bare top edge and the border is the border.

The history below stands as written: it is the reverted-pointer decision, and it is still the reason no
announcement of a count reaching zero is drawn on an edge.

**Not the session title** — I put one there first, guessing from a code comment
instead of reading the code, and the operator's screen showed a bare `╭───╮` where
mine said `╭ hello, what we are doing here ───╮`. The reference's top edge carries
`N subagents running` when any are, and nothing otherwise.

Counted from the SUBAGENT events whose latest state for that subagent is
`running` — `subagent-rows`, the same fold the subagents pane draws, so the edge
and the pane cannot disagree. It used to fold here by the envelope's `session_id`,
which is the PARENT's (event.rs:841), so two children of one session counted as
one.

**And the count that REACHES zero is NOT announced here, which is a decision rather than a gap.**
The operator watched it go 1, 0, hidden — *\"leticl's sub agents count in the status line went to 0
and was hidden\"* — and the first fix built a pointer here: `N subagent done · ctrl-g`, held until the
reader opened the pane. **It was reverted, because the announcement belongs one layer down.** The
daemon wakes the model with a durable `User { speaker: Agent }` transcript row when a child finishes,
and every head renders that row already; a sentence — or a pointer — from this side would be a
SECOND announcement of one fact, which is the defect this tree keeps finding under other names (a
count drawn twice and in the tail, two file lists, a detector and a renderer with nothing between
them). The crossing from 1 to 0 is a real event and the zero rule three screens up does trade it
away — but the reader is told by the transcript row that follows, not by a label that lingers.

**What stays is the running half**, unchanged: `N subagents running` while any are, and nothing
otherwise. If the finish still needs saying on the edge once the wake lands and can be looked at,
that is a decision to take against a screen, which is the only place it can be taken."
  (let ((subagents (count "running" (subagent-rows head)
                         :key (lambda (r) (or (getf r :state) "")) :test #'string=))
        (jobs (running-jobs head)))
    (format nil "~{~a~^ · ~}"
            (remove nil
                    (list (and (plusp subagents) (format nil "~d subagent~:p running" subagents))
                          (and (plusp jobs) (format nil "~d job~:p running" jobs)))))))

(defun composer-wiring (head &optional (cols 40))
  "The right-hand label of the box's BOTTOM edge: the alarm and the turn's status.

**Not the wiring** — same mistake as the title, same fix: the reference's bottom
edge is where the alarm triangle and the running turn's own status live, and the
wiring's model is in the header where it belongs.

COLS is the edge's width, passed through to `turn-status` so the prefill bar is
sized to the border it is inlaid into (`app.rs:5183`, `turn_status(w)`).

An alarm is `⚠` alone, because the counters behind it are `/status`'s and were
never worth a resident sentence of bright yellow. With nothing running and nothing
wrong, the edge is bare."
  ;; **THE TURN'S STATUS IS NOT HERE ANY MORE — it is the row ABOVE the box** (`turn-report-row`),
  ;; on the operator's word: *"responding has to be brought back up to the left on top of the input
  ;; area and stay here."* The alarm stays: it is about the SESSION and not about a turn, and it is
  ;; the one thing on this edge that must be visible while nothing is running.
  (let ((parts (remove nil (list (and (alarmed-p head) "⚠")))))
    ;; NOTHING is nothing: returning a space put a stray `─ ╯` on the box where
    ;; letibot draws `──╯`. Same defect as `composer-title`'s, one function over —
    ;; and only a column-precise diff shows a one-column difference.
    (if parts
        ;; no padding of its own: `box-edge` frames the legend (` … ─`), and a
        ;; legend that pads itself as well puts two spaces where the reference
        ;; has one on both sides of it
        (format nil "~{~a~^ · ~}" parts)
        "")))

(defvar *composer-ranges-cache* nil
  "`(BUFFER . (INNER . RANGES))` — the last composer buffer wrapped, at the last width.

**THE COMPOSER WAS WRAPPED FIVE TIMES A FRAME** (drawing reviewer, 2026-10-11): `%render` asks
`%composer-rows`, `composer-line` asks both `composer-box-body` and `composer-window`, and
`composer-caret` asks `composer-window` and `composer-ranges` again — each call re-consing the
whole range list. The buffer is a fresh string per keystroke and is not mutated in place (the
editor concatenates and subseqs), so IDENTITY is the right key, exactly as it is for the
reasoning count: one wrap per keystroke instead of five per frame.")

(defun composer-ranges (head cols)
  "The composer buffer's wrapped rows, as index ranges at the box's inner width.

Memoised on the buffer's IDENTITY and the width — the five callers a frame can share one answer,
and the key is exact rather than cheap: a buffer that changed is a different string."
  (let* ((buf (composer-buffer (head-composer head)))
         (inner (composer-inner cols))
         (hit *composer-ranges-cache*))
    (if (and hit (eq (car hit) buf) (eql (cadr hit) inner))
        (caddr hit)
        (let ((ranges (wrap-ranges buf inner)))
          (setf *composer-ranges-cache* (list buf inner ranges))
          ranges))))

(defun %composer-rows (head cols)
  "How many rows the composer buffer renders to, wrapped at the box's inner width.

The WRAP, not a ceiling of the whole buffer's width: the two disagreed on any
buffer with a newline in it, and the row count decides where the box's top edge
goes — so the box was one row short of its own body and the transcript moved
under it.

Takes HEAD rather than reaching for the global: the paint has `*head*` bound and
a TEST of the paint does not, and the difference is a render that dies with `NIL
is not of type LETICL::HEAD` — measured, twice, in this file. Anything here that
can be given the head is given it."
  (if (head-secret-req head)
      ;; a password is one row of dots however long it is, and the text is never
      ;; measured — see `composer-box-body`
      1
      (max 1 (length (composer-ranges head cols)))))

(defun composer-inner (cols)
  "The columns of editable text inside the box.

The row is `│ ` (2) + `› ` (2) + text + ` │` (2) = COLS, so the text gets COLS-6.
It was COLS-4 and every body row rendered two columns wide — measured: a 60-column
frame drew a 62-column row, which wraps in a terminal and pushes the whole frame
down a line on every keystroke."
  (max 1 (- cols 6)))

(defun box-edge (cols open close left right &optional (right-style '(:dim t)))
  "One edge of the composer's box, as segments — the reference's `box_edge`
(app.rs:5384-5411), which both of ours had only half of.

    ╭──────────────────────────── 2 subagents running ─╮
    ╰─────────────────────── ⚠ · ⠹ Responding · 4.2s ─╯

Three things ours got wrong and this fixes, each read off the reference's own
raw row rather than its plain text:

  · the legend is pinned **RIGHT**, not left. `composer-box-top` put the
    subagent count immediately after the `╭`, where the eye is not looking and
    where it collides with the header's left half one row above;
  · it is **framed** — ` {legend} ─` — so the legend sits in a notch in the
    border rather than being border that happens to be words;
  · and it is gated: no legend at all below `inner >= 10`, and the right legend
    is dropped rather than squeezed when its room falls under 4 columns. A
    legend squeezed to two characters is a legend nobody can read occupying
    room the border needs.

Invisible today on both edges because both legends are usually empty, which is
exactly why it went two rounds of `compare-heads` unnoticed: the difference only
exists while a subagent runs or a turn is answering.

The reference reopens `Role::Faint` after each legend because its palette closes
a span with a plain reset (`a reset is not a restore`). Cells carry their own
style here, so the reopen is structural: the border's segments are dim and the
legend's is its own."
  (let* ((w (max 4 cols))
         (inner (- w 2))
         (left-text (if (and (plusp (length left)) (>= inner 10))
                        (format nil "─ ~a " (truncate-to-width left (max 1 (- inner 4))))
                        ""))
         (left-cols (string-width left-text))
         (room (max 0 (- inner left-cols 2)))
         ;; the reference computes the legend's room as `inner - left - 2` and
         ;; then spends three columns on the framing (` `, the legend, ` ─`), so
         ;; a legend that uses all of its room makes the edge one column wider
         ;; than the box. An edge one column over WRAPS, and a border that wraps
         ;; scrolls the whole frame by a row every time it is drawn, so the gate
         ;; is the reference's and the truncation is one tighter.
         (shown (if (and (plusp (length right)) (>= inner 10) (>= room 4))
                    (truncate-to-width right (max 0 (- room 1)))
                    ""))
         (right-cols (if (plusp (length shown)) (+ 3 (string-width shown)) 0))
         (fill (max 0 (- inner left-cols right-cols))))
    (append (list (cons (string open) '(:dim t)))
            (when (plusp (length left-text)) (list (cons left-text '(:dim t))))
            (list (cons (make-string fill :initial-element #\─) '(:dim t)))
            (when (plusp (length shown))
              (list (cons " " '(:dim t))
                    (cons shown right-style)
                    (cons " ─" '(:dim t))))
            (list (cons (string close) '(:dim t))))))

(defun composer-box-top (head cols)
  "The box's top edge, with `N subagents running` pinned right.

`Role::Pending` — yellow (`style.rs:174`) — not `Strong`: the count is a thing
that is happening, which is the register the spinner on the bottom edge is
already in, and ours painted it bold, which is the header's register."
  (box-edge cols #\╭ #\╮ "" (composer-title head) '(:fg :yellow)))

(defun running-jobs (head)
  "How many background jobs have not settled — the number `composer-title` draws on the box's top edge.

**`:running` is the daemon's own flag** on a `JobEntry`, the same one the jobs pane draws as its
yellow `[~]` mark, so this count and that pane cannot disagree about a job: the pane lists them and
this says how many are still going.

Counted rather than derived from `:state`, because `state` is a sentence (`exited 0`, `running`,
`not run (could not join its scope)`) and a sentence is not a predicate — parsing one back into a
question the daemon already answered is the same mistake as re-deriving a duration from prose.

Cleared jobs leave `head-jobs` when the daemon's next `Jobs` reply omits them, so this needs no
notion of its own about what a job's lifetime is."
  (count-if (lambda (j) (getf j :running)) (head-jobs head)))

(defun turn-report-row (head cols)
  "The one row ABOVE the composer box: the running turn, or the last turn's report.

**The operator's spec, verbatim:** *\"responding has to be brought back up to the left on top
of the input area and stay here. It will permanently occupy the row for now and will be either
Responding spinner we have now or 'Responded in <full turn time> at <end-timestamp> as hh:mm'.\"*

Three requirements in that sentence, and each is a different kind of decision:

  · **LEFT-ANCHORED**, which is where this legend started before it was moved to the box's
    bottom edge — *\"please move Responding back to the right side\"* — and the operator has now
    moved it back. The left is also the only side where the spinner cannot move: it is the FIRST
    glyph, so a right-pinned legend slides leftward every time the duration or the count gains a
    digit. Anchored here, growth runs rightward into empty columns and the spinner is fixed by
    construction (see `+turn-status-head+`, which explains why nothing is held open for it).
  · **IT STAYS AFTER THE TURN**, with the two facts nothing else on the screen carries: the whole
    turn's wall time and the clock time it ended.
  · **IT PERMANENTLY OCCUPIES THE ROW.** This is the axiom read as a layout rule — *nothing must
    jump* — and it is why the row exists when there is nothing to say. A row that appeared with
    the turn and vanished with it would move the transcript up and down on every exchange; a row
    that is always there costs one line and moves nothing, ever.

**NIL when the composer has no box**, because there is no row to occupy: a short frame drops the
box (it costs two rows and the composer must never eat the last of them), and a bare `›` line has
no `above` to be above.

The states are mutually exclusive by CONSTRUCTION and not by a test: the running-turn arm clears
the report when a turn starts (`note-turn-finished nil`), so the running form and the finished
form cannot both be true at once."
  (when (composer-boxed-p head)
    ;; **a LINE is a list of SEGMENTS** — one row here, and one segment in it. Returned as a bare
    ;; `(cons text style)` first, which the painter took for a list of lines and died on:
    ;; `TYPE-ERROR expected-type: LIST datum: "Responded in 0ms at "`, measured.
    ;;
    ;; **and exactly COLS wide**, which is the composer's own rule and the same reason: a row one
    ;; column over wraps in a terminal and pushes the whole frame down a line. The pad is PLAIN
    ;; while the text is dim, so the trail of spaces carries no colour — the same choice the box's
    ;; own fill makes.
    ;;
    ;; **AND NO COUNTS SIT AT THE RIGHT EDGE ANY MORE** — see the body: both are on the box's TOP edge,
    ;; which is where the operator asked for them. This comment used to explain the jobs count's
    ;; right-anchoring here; that argument moved with the count, and a layout argument left behind on a
    ;; row it no longer describes is the kind of stale claim this file keeps finding.
    (let* (;; **NO COUNTS ON THIS ROW ANY MORE.** Both are on the box's TOP edge (`composer-title`), on
           ;; the operator's word: *"ok, so please bring counters back to the input box border top
           ;; right."* This row is the TURN's — `Responding · 1.2s` or `Responded in 12.4s at 21:07` —
           ;; and a count of anything else here would be the second place the same question is answered.
           (status (truncate-to-width (or (turn-status head cols) (turn-report-text)) (max 1 cols)))
           (pad (max 0 (- cols (string-width status)))))
      (list (append (list (cons status
                                ;; **GREEN WHILE THE TURN GOES, YELLOW WHEN IT GOES QUIET, and
                                ;; nothing else is said** (the operator, 2026-10-08: *"let usual
                                ;; Responding be green and when we detect delays - yellow it"*).
                                ;; The row used to be dim — a colour that says nothing — so a slow
                                ;; turn and a live one read the same, and the sentence that used to
                                ;; sit here (*"nothing received for 40s"*) was retired with it:
                                ;; a failed turn ends now, so silence is only ever slowness, and
                                ;; the colour carries it without a notification nobody asked for.
                                (if (turn-slow-p head)
                                    '(:fg :yellow)
                                    '(:fg :green)))
                          (cons (make-string pad :initial-element #\space) nil)))))))

(defun turn-report-text ()
  "`Responded in 12.4s at 21:07` for the last turn this head watched finish, or empty.

The DURATION is the full turn — `*turn-last*` records `now - *turn-started-ms*` at `turn_finished` —
and the stamp is `HH:MM` LOCAL, which is the operator's own format for it. Empty for a turn nobody
watched: an absent measurement shows NOTHING rather than a fabricated zero, the same rule the
settled tool row keeps for a duration it did not see."
  (let ((last *turn-last*))
    ;; **BOTH facts or neither.** A duration with no stamp, or a stamp with no duration, is half a
    ;; report — and the row is always on the screen, so half a report is a half-sentence left there
    ;; for the rest of the session. `%clock-hm` answers empty for a value it cannot read (a replay's
    ;; clock has no wall epoch), and that emptiness is the signal to say nothing.
    (let ((at (and last (%clock-hm (getf last :at)))))
      (if (and last (numberp (getf last :ms)) (plusp (length at)))
          (format nil "Responded in ~a at ~a" (duration (getf last :ms)) at)
          ""))))

(defun composer-boxed-p (head)
  "Does HEAD's composer draw its box at this frame size?

One predicate for the two places that must agree: the box's own rows and the status row above it. A
row drawn above a box that was not drawn is a stray line on a short terminal."
  (and (>= (head-rows head) 8)
       (plusp (head-cols head))))

(defun composer-box-bottom (head cols)
  "The box's bottom edge, with the alarm and the turn's status **pinned RIGHT** — the reference's
side for both edges, restored on the operator's word: *\"please move Responding back to the right
side\"*.

**It was anchored left for one reason, and the reason still holds.** The spinner is the legend's
FIRST glyph, so on a right-pinned legend every digit the duration or the count gains slides it
leftward; anchored left it cannot move, because the row grows rightward into the border's own fill.
The alternatives were measured and both were rejected by the operator — reserving the unused digits
left a hole in the border between the count and `─╯` (*\"look at the responding gap\"*), and drawing
those columns as `─` ran border through the legend (*\"I guss remove those bottom char entirely\"*).

**So the jump is a known, accepted cost rather than an oversight** — the operator has read both and
chose the reference's side, which is their call to make. A turn whose rate goes `724ms` → `12.3s` and
whose count goes `3 tok` → `12.3k tok` moves the spinner by however many digits it gained. The one
thing that would keep both — putting the spinner LAST, so growth runs leftward into the border — is
where `box-edge` truncates from, and it inverts the reference's own word order.

Both edges are right-pinned now, so they agree with letibot."
  (box-edge cols #\╰ #\╯ "" (composer-wiring head cols) '(:dim t)))

(defun %composer-body-rows (lines start inner)
  "LINES as box rows, the prompt on the FIRST row of the buffer only."
  (let ((lines (or lines (list ""))))
    (loop for line in lines
          for i from start
          for shown = (truncate-to-width line inner)
          ;; the wall and the prompt are DIM, and the wall is its own segment with
          ;; a plain space after it — read off the two screens' escapes, which is
          ;; the only place the difference shows: ours was `ESC[2m│ ESC[0;1mESC[96m›`
          ;; against letibot's `ESC[2m│ESC[0m space ESC[2m›ESC[0m`.
          collect (list (cons "│" '(:dim t))
                        (cons " " nil)
                        (if (zerop i)
                            (cons "› " '(:dim t))
                            (cons "  " nil))
                        (cons shown nil)
                        ;; `inner - shown + 1`: the closing wall used to carry its
                        ;; own leading space (`" │"`), and splitting it into the
                        ;; pad is what makes the escape boundaries match letibot's
                        ;; without changing the row's width
                        (cons (make-string (max 0 (1+ (- inner (string-width shown))))
                                           :initial-element #\space) nil)
                        ;; the closing wall is its OWN dim segment with the space
                        ;; in the pad, not `" │"` together — one space inside the
                        ;; escape is the last column of difference between the two
                        ;; screens' box rows
                        (cons "│" '(:dim t))))))

(defun composer-window (head cols &optional max-rows)
  "Which wrapped rows of the composer the box draws, as `(values START SHOW N
CROW)` — the reference's `composer_rows` window (app.rs:5355-5358).

MAX-ROWS is what the fit ladder left the composer. A composer taller than the
rows it was given **scrolls to the caret, never to the top**: the person is
typing somewhere, and a window pinned at row 0 puts that somewhere off screen."
  (if (head-secret-req head)
      (values 0 1 1 0)
      (let* ((ranges (composer-ranges head cols))
             (n (max 1 (length ranges)))
             (show (max 1 (min (or max-rows n) n)))
             (crow (nth-value 0 (locate-in-ranges
                                 (composer-buffer (head-composer head))
                                 (composer-cursor (head-composer head))
                                 ranges)))
             (start (min (max 0 (- crow (1- show))) (- n show))))
        (values start show n crow))))

(defun composer-box-body (head cols &optional max-rows)
  "The body rows of the box: `│ › text… │`, the buffer WRAPPED.

It used to split on newlines and TRUNCATE each one, so a typed line longer than
the box was cut at the edge with no way to see the rest of it — and the caret,
which is a position in the text, had nowhere on the screen to be. The prompt is
on the first row only and continuation rows are indented by its width, as the
reference's editor does."
  (let* ((c (head-composer head))
         (inner (composer-inner cols))
         (buf (composer-buffer c))
         (all (if (head-secret-req head)
                  ;; **A DOT PER CHARACTER, and the text never even measured** —
                  ;; the reference's own comment at `app.rs:5343-5347`. Ours kept
                  ;; painting the ordinary buffer under the password card, so
                  ;; whatever had been typed before sudo asked sat on the screen
                  ;; while a password was being entered over the top of it.
                  (list (make-string (length (head-secret-buf head))
                                     :initial-element #\•))
                  (loop for (a . b) in (composer-ranges head cols)
                        collect (string-right-trim '(#\space) (subseq buf a b))))))
    (multiple-value-bind (start show) (composer-window head cols max-rows)
      (%composer-body-rows (subseq all (min start (length all))
                                   (min (+ start show) (length all)))
                           start inner))))

(defun composer-line (head cols &key (boxed (composer-boxed-p head)) max-rows ghost)
  "The composer, as the rows it occupies — box plus body, or one bare line.

Returns a LIST of rows, because the box is three or more rows tall; the caller
places them from the bottom up. A single-row list is the degraded form.

BOXED and MAX-ROWS are the **fit ladder's** answers (`%fit-ladder`, render.lisp):
the ladder gives up the composer's rows one at a time and then the box itself,
in that order, and this used to decide both for itself from `head-rows`. The
defaults keep a caller that has not run the ladder working.

**GHOST is the live `/command` matches, and they are a row of the box** (see
`composer-ghost-row`). It goes under the body and above the bottom edge, which is where a list of
what you could type belongs — under the line you are typing it into — and it is drawn on the row
the box's top edge vacates, so nothing outside the input area moves when it appears.

**The ghost is a ROW OF THE COMPOSER and still a row of the LADDER'S making.** `%fit-ladder` counts
it exactly as it counted the chrome row it used to be, and gives it up first for the same reason —
it is a typing aid, not a message. What changed is only where the row lands."
  (let ((inner (max 1 (- cols 2))))
    (declare (ignorable inner))
    (if (not boxed)
        ;; too short for a box: the bare line, with the prompt and the tail of
        ;; the buffer keeping the cursor end visible
        (let* ((buf (composer-buffer (head-composer head)))
               (prefix "› ")
               (visible (if (> (+ 2 (string-width buf)) cols)
                            (subseq buf (max 0 (- (length buf) (- cols 2))))
                            buf)))
          (append (list (list (cons prefix '(:fg :bright-cyan :bold t))
                              (cons visible nil)))
                  ;; **and the ghost under it, indented by the prompt** — there is no box to put it
                  ;; in, and the row it takes is the row it took before, so a short terminal loses
                  ;; nothing to it either.
                  (when ghost
                    (list (list (cons "  " nil)
                                (cons (truncate-to-width ghost (max 1 (- cols 2))) '(:dim t)))))))
        (append
                ;; **THE STATUS ROW GOES ABOVE THE BOX, AND IT IS ALWAYS THERE.** See
                ;; `turn-report-row` for the operator's spec and for why a permanent row is the
                ;; axiom read as a layout rule: a row that came and went with the turn would move
                ;; the transcript on every exchange.
                (turn-report-row head cols)
                (list (composer-box-top head cols))
                (composer-box-body head cols max-rows)
                (when ghost (list (composer-ghost-row ghost cols)))
                (list (composer-box-bottom head cols))))))

(defun composer-caret (head cols &key (boxed (composer-boxed-p head)) max-rows)
  "Where the terminal's own caret goes, as (ROW . COL) inside the composer's own
rows — the reference's `composer_rows` third value.

**The composer's whole affordance is that caret.** This head asked for a steady
block at startup (`ESC[2 q`), hid the cursor (`ESC[?25l`) and then never said
where it went, so the prompt had no cursor at all — the operator: *\"the creepy
thing about leticl - prompt input doesnt have caret or cursor\"*. The box draws a
`›` and that is a decoration; the caret is the thing that says where the next
character lands."
  (let* ((c (head-composer head))
        ;; **THE ROWS ABOVE THE BOX IN THE COMPOSER BLOCK** — `turn-report-row`, which is the
        ;; first row of `composer-line` and therefore of everything this counts from. It was
        ;; zero for as long as the box was the whole block, so every offset below assumed row 0
        ;; was the top edge; the operator found the result immediately — *"hmm cursor now goes
        ;; above the text i type lol"* — because the caret was one row high, sitting on the
        ;; status row while the text was below it.
        ;;
        ;; This is the arithmetic, not a fudge: `composer-line` starts with the status row, so
        ;; the box's top edge is at LEAD and the body's first row is at `lead + 1`.
        (lead (if boxed 1 0)))
    (if (not boxed)
        ;; the bare line: the prompt is two columns and the tail is what is shown
        (let* ((buf (composer-buffer c))
               (cut (max 0 (- (length buf) (- cols 2)))))
          (cons 0 (+ 2 (string-width buf :start (min cut (composer-cursor c))
                                        :end (composer-cursor c)))))
        ;; a password puts the caret after the last DOT, and the buffer it is a
        ;; caret into is never measured (app.rs:5343-5347)
        (if (head-secret-req head)
            (cons (1+ lead) (+ 4 (length (head-secret-buf head))))
            (multiple-value-bind (start) (composer-window head cols max-rows)
              (multiple-value-bind (row col)
                  (locate-in-ranges (composer-buffer c) (composer-cursor c)
                                    (composer-ranges head cols))
                ;; +1 for the box's wall, +1 for the space after it, +2 for `› `;
                ;; the body's first row is one below the top edge, and START is
                ;; how many rows the window has scrolled past
                (cons (+ lead 1 (- row start)) (+ 4 col))))))))

(defun composer-rows-needed (head cols &key (boxed (composer-boxed-p head)) max-rows ghost)
  "How many rows `composer-line` will return. The render needs this BEFORE it
composes the frame, because the transcript gets what is left.

GHOST is counted here for the reason it is drawn at all: a caller asking how tall the composer will
be is asking about the frame's arithmetic, and a ghost that is a row of the box is a row of the
answer.

**AND THE STATUS ROW IS ONE OF THEM** (`turn-report-row`), which is the half that would have gone
wrong silently: this function is how the transcript is told how much room is left, so a row drawn and
not counted gives the transcript one row too many and pushes the box — or the status row itself — off
the bottom of the frame."
  (if (not boxed)
      (if ghost 2 1)
      (+ 2 (nth-value 1 (composer-window head cols max-rows)) (if ghost 1 0) 1)))

