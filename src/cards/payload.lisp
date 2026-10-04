;;;; payload.lisp — one payload's own window: the memo that splits a result into
;;;; rows, the one row whose window is open, and the seam that pages it.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.

(in-package #:leticl)

;;; ------------------------------------------------ the payload's own window ;;;
;;;
;;; **What makes the rest of a long result reachable at all.**
;;;
;;; A settled tool row drew `… +N lines · ctrl-t`, and the reader pressed ctrl-t and
;;; got the same row back: the fold raises the BUDGET (which rows may be long — two
;;; rows folded, forty open) and gives no row an OFFSET. So the chord the seam named
;;; revealed nothing, and a 418 KB log was readable to its fortieth line and no
;;; further. The reference records exactly this at the site this is ported from
;;; (app.rs:10828-10840):
;;; *"opening the fold changed the budget, not the offset. There was no offset."*
;;;
;;; So a row whose window is open draws a WINDOW into its payload — one line per
;;; source line, which is why the seams can talk in lines — and the arrows page it.

(defparameter *payload-page* 10
  "How many lines one press pages a payload window.

The reference's `BY` (app.rs:3863), and deliberately the SAME unit for the arrows
and the page keys rather than a screenful: the window's height is a function of the
frame, the fold and the payload, and the key handler knows none of those. The offset
is clamped where it is USED — by the render, which is the only place that knows how
long the payload is — which is what the reference does for the same reason.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a
constant could never be changed on a running head.")

(defvar *payload-view* nil
  "The one row whose payload window is OPEN, and how far into it the reader has
paged: a cons `(ITEM-ID . OFFSET)`.

**A pair and not a bare offset**, because *the view is open* and *how far down it
is* have to agree about WHICH row: several rows can be long on one screen, and a
bare offset would page every one of them together.

**Keyed on the ITEM ID**, which is what `item-lines` holds and what is unique per
row. `call-id` is the tempting key and the wrong one — it is round-positional and
reused, so a view keyed on it opens on the wrong row after the next round; the
reference's first version did exactly that and its own test caught it, the seam
saying `ctrl-t pages` while ctrl-t had been pressed (`app.rs:10231-10238`).

A `defvar` and not a head slot, for the reason all live state is: a struct layout
change is a restart, and this has to be reachable from a push. Bound by
`with-replay-globals`, because a replay must answer the same bytes twice.")

(defun %payload-view-set (value)
  "The ONE writer of `*payload-view*`, and the place that invalidates the rendered
history.

A page offset changes what a row RENDERS TO without moving any of the line cache's
three terms — the generation, the width, the items vector's identity — so a paging
that did not bump the generation would be served the previous window out of the
cache and look like a key that does nothing. That is the reference's own finding at
its cache (*the page moved to 10 and the screen still showed line 0*) and ours would
have been the same one.

One writer rather than an `(incf …)` at each call site, for the reason the
preference setter gives: *\"the fifth site is the one that would forget\"*.
(`*hist-generation*` is defined in `render.lisp`, beside the cache it invalidates and
after this file — the same forward reference `push-item` in `session.lisp` already
makes.)"
  (setf *payload-view* value)
  (incf *hist-generation*)
  value)

(defun payload-view-for (item)
  "The offset THIS row's window is at, or NIL when this row has no window."
  (let ((id (getf item :item-id)))
    (when (and *payload-view* id (equal id (car *payload-view*)))
      (cdr *payload-view*))))

(defun payload-view-open-p () (and *payload-view* t))

(defun newest-payload-row-p (item)
  "Is ITEM the row `ctrl-t` would open — the newest one with something to page?

**This exists because of R40's rule**: *a chord is named only where it acts*. `ctrl-t` opens the
window on ONE row, so a seam may name it on that row and on no other — every other folded row
names `/t`, the verb that unfolds the whole conversation. Before the split, every seam could
honestly say `ctrl-t` because the chord did both; after it, a seam that named `ctrl-t` on an
older row would be telling the reader to press a key that does nothing to the row they are on.

**The test is `payload-view-seed`'s own walk and not a second opinion**: it asks whether this
item's id is the one the seed would pick, by calling the same function, so the seam and the chord
cannot disagree about which row that is.

**With no head in scope the answer is NO, and that is the safe direction rather than a fallback
for convenience.** A row can be drawn outside a frame — a test, a pane, a file that builds rows
to measure them — and a head that cannot see the session cannot assert that `ctrl-t` acts on this
row. `/t unfolds it` is the claim that is TRUE of every folded row whatever the session is, so an
unknowable case takes it. Measured: reaching for the head unconditionally made every direct
`item-lines` call die with `expected-type HEAD, datum NIL`, which is ten tests telling the same
story about a predicate that answered a question it had no information for."
  (let ((head *payload-head*))
    (and head
         (getf item :item-id)
         ;; **the PURE question**, not the seeder: asking must not open a window
         (equal (newest-payload-item-id (head-session head)) (getf item :item-id)))))

(defvar *payload-head* nil
  "The head whose items `newest-payload-row-p` judges, for the one thing that needs it.

**A defvar because a row's LINE function is handed an item and a preference list and nothing
else** (`item-lines`), so asking *is this the newest pageable row* needs the session from
somewhere. Set by `%viewport-lines` — the one place that draws rows and therefore the one place
that can know — and read only inside a frame, so it never outlives the paint that set it.")

(defun payload-view-close ()
  "Close the window. T when there was one."
  (when (payload-view-open-p)
    (%payload-view-set nil)
    t))

(defun payload-view-page (delta)
  "Move the open window DELTA lines, floored at zero. T when there was a window.

The UPPER clamp is the render's, not this function's: how far down a payload goes is
a function of the payload and the frame, and neither is known here."
  (when (payload-view-open-p)
    (%payload-view-set (cons (car *payload-view*)
                             (max 0 (+ (cdr *payload-view*) delta))))
    t))

(defvar *payload-rows* nil
  "An `eq` hash of PAYLOAD STRING -> the rows it draws as, or NIL before the first ask.

**Keyed on the payload's OWN OBJECT, and that is what makes handing the rows out safe.** The payload
hangs off a body the session owns and is REPLACED rather than edited (`fill-item` sets `:item`
whole), so two asks with the same string object are two asks about the same bytes — and
`%tool-payload-rows` is a pure function of those bytes.

**MEASURED, and this is the operator's in-turn 80% one layer down.** A `tool_result`'s payload was
split, sanitised one character at a time (`%without-control`) and filtered on EVERY ask, and a frame
asks for the same row's rows two or three times over: once to draw it, and once per
`newest-payload-item-id` scan for the seam. At 300 payload lines (about 90 KB) one ask measured
**1.45 ms** and a frame made dozens of them: **168 ms for a single frame** at 214x60 on a 2038-item
session, against 3.2 ms for the same frame warm.

A `defvar`, so a live push does not drop a running head's table — the shape every memo in this tree
keeps — and bounded, because a session's payloads are not.")

(defparameter +payload-rows-cache-max+ 512
  "How many payloads the rows memo holds before it is emptied WHOLE.

Emptying rather than evicting: the asks arrive row by row inside one frame, so choosing a victim
would cost more than re-splitting the payload, and the case the bound exists for — a session with
thousands of results — is served as correctly from an empty table as from a stale one.")

(defun %payload-rows-of (payload)
  "PAYLOAD as its rows: sanitised FIRST and filtered second, the reference's order (app.rs:9712) —
a payload's bytes are the command's and not this terminal's (`%without-control`), and the envelope
lines, the wrapper the harness adds around a result and addresses to the model, are not output."
  (remove-if #'%envelope-line-p
             (mapcar #'%without-control (%payload-lines payload))))

(defun %tool-payload-rows (body)
  "The rows a tool result's payload draws as — `%payload-rows-of`, remembered by PAYLOAD.

See `*payload-rows*` for why the key is the string's identity and for the measurement that put the
memo here. A body with no payload at all does not reach the table: it answers the empty payload's
zero rows directly, because every such row sharing one `\"\"` would be one entry whose lookup costs
more than the split it saved."
  (let ((payload (getf body :payload)))
    (if (not (stringp payload))
        (%payload-rows-of "")
        (let ((table (or *payload-rows* (setf *payload-rows* (make-hash-table :test #'eq)))))
          (multiple-value-bind (rows hit) (gethash payload table)
            (if hit
                rows
                (let ((rows (%payload-rows-of payload)))
                  (when (> (hash-table-count table) +payload-rows-cache-max+)
                    (clrhash table))
                  (setf (gethash payload table) rows)
                  rows)))))))

(defparameter +payload-pageable-lines+ 2
  "A payload longer than this is worth a window.

The reference's test in `newest_payload_row` (`payload.lines().count() > 2`), and the
same number for a reason rather than by coincidence: a folded row already draws one
line and the seam, so two is the point past which paging gains anything.")

(defun %row-openable-rows (item)
  "The rows THIS row's `ctrl-t` would reveal, or NIL when it has nothing to page.

**ONE ANSWER, because two readers ask it** — the seeder that decides which row the chord opens, and
a row's own drawing, which must know whether its seam may name the chord at all (R40). A second
opinion would let a seam promise a window the seeder would not open.

Two kinds of row can open, and they are the two the reader gets buried by:

  · **a tool result**, whose rest is its payload (`%tool-payload-rows`);
  · **a job settlement** — the daemon's completion notice, which arrives as a `User` row with
    `speaker: agent` and is a paragraph of blather on the conversation (R41's own message).

Everything else answers NIL, and the callers drop a row with nothing to page rather than inventing
one — the same rule `payload-view-seed` already keeps."
  (let ((body (item-body item)))
    (cond
      ((null (consp body)) nil)
      ((string= (getf body :type) "tool_result") (%tool-payload-rows body))
      ((and (string= (getf body :type) "user")
            (eq (%user-speaker body) :agent))
       (let ((text (%user-parts-text body)))
         (and (%notice-folds-p text) (%job-notice-rows text))))
      (t nil))))

(defvar *newest-payload* nil
  "`(:KEY (ITEMS GENERATION) :ID …)` — the last answer to `newest-payload-item-id`, and the state it
was asked about.

**ONE ANSWER PER FRAME, which is the whole of this memo.** The question is asked from a row's own
seam (`newest-payload-row-p`), so it is asked once per folded tool row DRAWN — and the answer is a
property of the session, so every one of those asks is asking the same thing. MEASURED at 2038
items: **43-60 asks in a single cold frame**, and where no row in the session is pageable each ask
walks the WHOLE transcript (`%row-openable-rows` -> `%tool-payload-rows` per candidate): **47 ms a
frame, 94% of it** in an `sb-sprof` flat profile — for an answer that had not moved.

The key is the items vector and the generation, and no narrower pair is enough: a row is openable
when its BODY has rows, and a body arrives through `fill-item`, which bumps the generation without
replacing the vector. `%row-openable-rows` reads the body and nothing else.")

(defun newest-payload-item-id (session)
  "WHICH row a window would open on — the newest with something to page — or NIL.

**PURE, and split from `payload-view-seed` for a reason that cost a real defect** (R40): the
predicate that decides whether a row's seam may name `ctrl-t` has to ASK this question, and the
first version asked it by calling the seeder — so drawing a row OPENED A WINDOW. Every frame
would have opened one on the newest long result, and the reader's `ctrl-t` would then close a
window they never asked for.

**The newest, because that is the row a reader is looking at**: rows are appended at the bottom,
so the command just run is at the end. Only ONE row has a window at a time, and it is this one —
which is also the whole limit of the mechanism, written down rather than implied.

**The walk is the expensive half and it is paid ONCE PER FRAME** — `*newest-payload*` is the memo,
and its docstring carries the measurement (43-60 asks a frame, 47 ms of them, for one answer)."
  (let* ((items (session-items session))
         (key (list items *hist-generation*))
         (cached (and *newest-payload*
                      (equal (getf *newest-payload* :key) key)
                      *newest-payload*)))
    (if cached
        (getf cached :id)
        (let ((id (loop for i of-type fixnum from (1- (length items)) downto 0
                        for item = (aref items i)
                        ;; **via `%row-openable-rows`, so a job settlement is openable too** (the
                        ;; operator: *"make them one liners for conversation and Ctrl-t'able
                        ;; otherwise"*). This asked for a `tool_result` by name, which is how the
                        ;; one row type that buries a conversation most was the one kind the chord
                        ;; could not open.
                        when (> (length (%row-openable-rows item)) +payload-pageable-lines+)
                          return (getf item :item-id))))
          (setf *newest-payload* (list :key key :id id))
          id))))

(defun payload-view-seed (session)
  "Open the window on the newest row with something to page, at its first line.
NIL when no row has one — which is the right answer for a session whose last result is
one line long, and leaves the fold with no view rather than inventing one."
  (%payload-view-set
   (let ((id (newest-payload-item-id session)))
     (and id (cons id 0)))))

(defun %row-window (head)
  "**THE PER-ROW WINDOW, AND ITS ONLY DOOR IS `/t`.** Moved here from the `ctrl-t` arm when the
chord was rebound to the todos pane; the logic is unchanged, and it is one function because a
window is one thing.

The ORDER is the whole of it, and each clause has a reason:

  · an OPEN run closes first, so the same verb folds back what it opened;
  · at the `:reading` rung it acts on the RUN MARKER rather than on a long row, because at that rung
    the long rows it would otherwise open ARE the run — a hidden tool result draws no per-row seam
    at all — and the marker's own seam says `ctrl-t opens it`;
  · an open payload window closes next;
  · and only then does it seed one on the newest long result (`payload-view-seed`), which is the row
    a reader is looking at.

**What it does NOT do is unfold the conversation.** That is the `tools` row in `/config`, and it is
where the operator always wanted it: *\"what surprised them was that ctrl-t triggered the wall AT
ALL.\"* A verb that opens ONE row's window and a verb that opens every row are different acts, and
the wall has a setting rather than a key."
  (cond
    (*hidden-run-open* (%set-hidden-run-open nil))
    ((reading-p)
     (let ((id (newest-hidden-run-id (head-session head))))
       (when id (%set-hidden-run-open id))))
    ((payload-view-open-p) (payload-view-close))
    (t (payload-view-seed (head-session head)))))

