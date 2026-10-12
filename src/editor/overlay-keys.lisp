;;;; overlay-keys — the decision card's keys, and the payload window's
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defun %card-scrollable-p (head)
  "Does the open ask's card have content OUT OF VIEW — something for the page keys and the wheel
to scroll? Read from the screen the head DREW (`docs/code-review-2026-10-11.md`,
overlay-keys.lisp:65-72): `card-content-window` draws a seam saying `… N rows out of view` exactly
when the content did not fit, and nothing at all when it did, so the seam's presence on the cell
buffer IS the fact — the same rule `%composer-edge-buttons` keeps, *read from the painted row, not
recomputed*. Before the first frame there is no screen and nothing to scroll."
  (when (head-screen head)
    (loop for r from 0 below (head-rows head)
          for text = (%screen-row-text head r)
          thereis (and text (search "out of view" text) t))))

(defun %decision-key (head key type)
  "The keys an OPEN ASK owns, and only those — NIL when this key is not one.

**Up and Down move the ladder whether or not a line is being typed.** The whole
arm used to be gated on an empty composer, and the cost of that was not visible
until the operator hit it: a permission arrives while you are typing, and the only
way into the menu was to empty the composer first — so the words you were writing
were the price of choosing an option. Their words, 2026-09-20: *\"suppose i type a
prompt and permission ask arrives — until i press down arrow I wont get into the
permissions menu, by which time my prompt is erased and gone\"*.

Nothing is taken from the composer by that: a one-line composer does not edit
with Up and Down, and what moves aside is scrollback scrolling for as long as an
ask is open — PageUp and PageDown still do that.

**Enter and the digits keep the empty-composer guard**, for the opposite reason:
with a typed line Enter is `%submit-line`'s, which answers the marked row and
HOLDS the words, and a line being typed keeps its digits (app.rs:3604-3608).

**This is a function of its own, not folded into the composer's arm, and the ORDER
it is called in is the point.** An ask must be asked BEFORE every list on the screen
— see `%handle-key`, which is where the reference's own order puts it (app.rs:3609,
ahead of the session picker at :3643, the mode and models pickers at :3736 and the
subagent, todos and jobs panes at :3795, :3852 and :3917). They used to be asked
first, so a permission arriving over an open session picker left Up and Down
moving the PICKER: two cursors on one screen and the ladder out of reach for as
long as the picker stayed open."
  (let* ((decision (%open-decision head))
         (options (decision-options decision))
         (n (length options))
         (empty (zerop (length (composer-buffer (head-composer head))))))
    (when (and decision (plusp n))
      (case type
        ;; **ESC PUTS A QUESTION AWAY** (letibot `2ad7b9b`): *a question card moves on after an answer, and
        ;; Esc puts it away.* **A QUESTION only** — a permission's Esc means something else (it is a
        ;; refusal, and a card that quietly vanished instead of denying would be a permission nobody
        ;; answered), so the kind is what gates it rather than the fact that a card is up.
        ;;
        ;; The card is still OPEN ON THE DAEMON: this is a view, `alt-a` brings it back, and a head that
        ;; restarts shows it again because the question was never answered.
        ((:esc) (when (equal (getf decision :kind) "question")
                  (%decision-away head decision)))
        ((:up) (setf (head-decision-sel head) (max 0 (1- (head-decision-sel head)))
                     (head-dirty head) t))
        ((:down) (setf (head-decision-sel head)
                       (min (1- n) (1+ (head-decision-sel head)))
                       (head-dirty head) t))
        ((:enter) (when empty (%answer-decision head (head-decision-sel head))))
        ((:char)
         (let ((digit (digit-char-p (getf key :ch))))
           ;; a digit that names no row is the composer's, as is every digit
           ;; once a line is being typed
           (when (and empty digit (<= 1 digit n))
             (%answer-decision head (1- digit)))))
        ;; **PAGE, THE WHEEL AND HOME/END SCROLL THE CONTENT VIEWPORT, AND THAT IS
        ;; R20.** The ladder is pinned and never scrolls, so the content above it needs
        ;; keys of its own — and they cannot be ↑/↓, which are the ladder's (the
        ;; reference's own split: `app.rs:3410-3466` gives the arrows to the options).
        ;;
        ;; The four are claimed HERE rather than in the composer's arms because a card
        ;; that owns the keyboard has to own what the card advertises: the seam on the
        ;; viewport says `PgUp/PgDn scrolls`, and a seam that names a key the composer
        ;; swallows is the lie this repo keeps refusing to ship. Gated on `empty` for
        ;; the same reason Enter is: a line being typed is the composer's, and its
        ;; history walk is on ↑/↓ anyway.
        ;; **AND ONLY WHEN THERE IS SOMETHING TO SCROLL** (the review, overlay-keys.lisp:65-72):
        ;; claimed on an empty composer alone, a card that fit on the screen still took PgUp,
        ;; PgDn and the wheel away from the transcript for as long as the ask stood — a reader
        ;; with a four-line permission card up could not page the conversation behind it. The
        ;; `nil` these arms answer on a card with nothing out of view hands the key back to
        ;; `%normal-key`, where the transcript's own scroll lives. Home and End are left as they
        ;; were: on an empty composer they move nothing else, so there is nothing to hand back.
        ((:page-up) (when (and empty (%card-scrollable-p head))
                      (card-scroll-by (- *card-page*)) (setf (head-dirty head) t)))
        ((:page-down) (when (and empty (%card-scrollable-p head))
                        (card-scroll-by *card-page*) (setf (head-dirty head) t)))
        ((:home) (when empty (setf *card-scroll* 0 (head-dirty head) t)))
        ;; Home/End are the two ends. End is a big number rather than a computed
        ;; maximum: how far the viewport goes is a function of the frame, and the
        ;; render CLAMPS it there — the same rule as every other window in this head,
        ;; where the key handler asks and the draw decides.
        ((:end) (when empty (setf *card-scroll* most-positive-fixnum (head-dirty head) t)))
        ;; **the wheel dispatches on its KIND, not on `:mouse`** — `%key-type` is the
        ;; one place that knows, and it exists because the ladders' `:wheel-*` arms never
        ;; matched and a wheel did nothing anywhere. A wheel is `:wheel-up`/`:wheel-down`
        ;; by the time it reaches here.
        ;; **THE WHEEL NOTCHES, IT DOES NOT PAGE** — and that is a parity fix rather than an
        ;; opinion. letibot moves a card by the same `by` its page keys use ONLY on the page keys:
        ;; the wheel is `3` and a page is `screen_rows` (`app.rs:5364-5369`). This head's two wheel
        ;; arms were added beside the page arms when the `:wheel-*` KIND bug was fixed — and they
        ;; took the page arms' AMOUNT along with their polarity, so a card jumped a whole page per
        ;; notch where the reference moves three rows. A copy that came with a bug fix is the kind
        ;; that goes unnoticed: the wheel worked, so nobody measured how far.
        ((:wheel-up) (when (and empty (%card-scrollable-p head))
                       (card-scroll-by (- (* (%wheel-notches key) *scroll-notch*)))
                       (setf (head-dirty head) t)))
        ((:wheel-down) (when (and empty (%card-scrollable-p head))
                         (card-scroll-by (* (%wheel-notches key) *scroll-notch*))
                         (setf (head-dirty head) t)))
        (t nil)))))

(defun %payload-key (head key type)
  "The keys an OPEN PAYLOAD WINDOW owns. T when the key was claimed.

`↑`/`↓` page it; `esc` closes it. **Esc closes the WINDOW and nothing else** — it
does not arm the interrupt, and it does not jump the transcript back to the tail,
because the seam on the row says `esc closes` and a key that did something else would
make the seam a lie of exactly the kind this window was built to end. Esc giving the
arrows BACK is part of the contract, not an afterthought: the reference's own test
says why (*\"the original bug was that expanding tools cost the ability to scroll at
all\"*, app.rs:14767-14772).

**PageUp/PageDown and the wheel are deliberately NOT claimed**, and this is the
reference's real behaviour rather than its written one. Its payload arm lists
`Key::PageUp | Key::PageDown` (app.rs:3866-3889) and those patterns are DEAD CODE:
the screen-moving arm for `PageUp | PageDown | WheelUp | WheelDown` is at :3628,
inside the same `match`, and it returns — the payload arm is an `if` after the match.
So in letibot an open window pages with ↑/↓ and the page keys still move the
transcript, which is this head's contract too, and it is the one worth keeping: in
this head the page keys and the wheel ARE the scroll, and a window that took them
until Esc is indistinguishable from *\"scrolling broke again\"* — the complaint this
operator has already made twice.

**A view the reader OPENED keeps the arrows; an ask that ARRIVES does not take
them.** A permission card is the one thing on the screen nobody asked for, and the
reference puts the payload window ahead of the ladder for that reason
(app.rs:3855-3862): with a 400-line log open and a call waiting to be answered,
`↑` is still the reader's. `enter` is deliberately NOT claimed, so the ask is
answered where it always was.

**And it stands down entirely while something the reader opened is on top.** The
window lives in the transcript: with the todos pane up, or the mode card, the
transcript is not on the screen at all, and arrows that paged a window nobody can
see would be the same class of defect as the seam that named a chord that revealed
nothing.

The reference is INCONSISTENT here and this head is not: its payload arm
(app.rs:3862) sits after `sub_out`, `job_out` and `config_pane` — so those keep
their arrows — and before the todos, subagents and jobs panes (:4167 and on), so
those lose them to a window that is not on the screen. One rule — *anything the
reader put on top wins* — is the version of that with nothing to remember."
  (when (and (payload-view-open-p)
             (eq (head-mode head) :normal)
             (null *pick-open*))
    (case type
      ((:esc) (payload-view-close) (setf (head-dirty head) t) t)
      ((:up) (payload-view-page (- *payload-page*)) (setf (head-dirty head) t) t)
      ((:down) (payload-view-page *payload-page*) (setf (head-dirty head) t) t)
      (t nil))))

