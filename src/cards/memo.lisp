;;;; memo.lisp — the one place a rendered row is REMEMBERED: the per-context
;;;; frame table, the render context it is stamped with, and the signature a row
;;;; compares against to decide whether its lines may be reused.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.

(in-package #:leticl)

(defvar *item-lines-frames* nil
  "`((:STAMP S :TABLE H) …)` — the memo, ONE FRAME PER RENDER CONTEXT, newest first.

**Per frame and not per item, which is what the earlier versions got wrong.** `item-lines` reads the
walk's dynamic context — `*call-started-ms*`, the two fact tables, `*call-targets*`,
`*answered-calls*`, `*payload-view*`, `*payload-head*`, `*hidden-run-head*` — so its input is the
CONTEXT and not the item, and that is the same for every item in a walk.

**AND ONE SLOT IS NOT ENOUGH, WHICH IS THE BUG THIS LIST FIXES — MEASURED.** A single-slot memo
under a context that has TWO live values inside one frame does not miss once; it misses on every
call, because the second context's ask THROWS THE TABLE AWAY and the first context's ask then misses
the line it just rendered. That is what one walk did here: `%history-until` asks `item-lines` twice
per item — once itself with the head's prefs (`render.lisp`), and once through `%row-invisible-p`,
which passes NIL (`cards.lisp`) — so the stamp's `prefs` element alternated and no call ever hit.

    MEASURED, 2038 items, 214x60, a live turn, cold frame:
      one slot       44-296 %ITEM-LINES-RENDER calls a frame, growing every frame — never a hit;
      four slots      1-2  the row that changed, and the frame 5.3 ms -> 3.0 ms.

The alternative fixes are to make the two call sites agree on `prefs` or to stop asking
`item-lines` a blankness question at all; both change what a row DRAWS. A memo that holds the
contexts it is asked about changes nothing but the arithmetic, which is why this is the fix.

A `defvar`, so a live push does not drop a running head's tables.")

(defparameter +item-lines-contexts+ 4
  "How many render contexts the memo holds at once — more than the three this tree asks in.

One walk has two (the head's prefs, and NIL through `%row-invisible-p`); `hidden-run-lines` adds
`(head-prefs *hidden-run-head*)`, and a pane drawing a row of its own adds the head's again. Four
leaves room for a `prefs` list that is rebuilt between two asks, which is the one shape that could
otherwise evict the walk's own table. The oldest is dropped when the list is full — a NEARLY-filled
walk table is worth less than the one in use, and a context that comes back pays one frame's render
and then holds its lines again.")

(defun %item-lines-frame (cols prefs)
  "The table for this ask's render context, made — and the oldest context evicted — when it is new."
  (let ((stamp (%item-lines-stamp cols prefs)))
    (or (find stamp *item-lines-frames* :key (lambda (f) (getf f :stamp)) :test #'equal)
        (let ((frame (list :stamp stamp :table (make-hash-table :test #'equal))))
          (setf *item-lines-frames*
                (cons frame (subseq *item-lines-frames* 0
                                    (min (length *item-lines-frames*)
                                         (1- +item-lines-contexts+)))))
          frame))))

(defun %item-lines-stamp (cols prefs)
  "The render context as one value: everything `item-lines` reads besides the item itself.

**The tick is deliberately NOT here** — it moves ten times a second and changes exactly one row, so it
belongs in that row's signature rather than in a stamp that would rebuild the frame.

**And every entry above was MEASURED, not listed from memory**: the last two failures came from
`*payload-view*`, which the tests for the payload seam and the long-payload window bind by name, and
which no amount of reading the renderer had turned up. When a memo is wrong it is always a missing
input, and the input is whatever the tests bind."
  (list cols prefs *verbosity* *marker-seam* *payload-head* *hidden-run-head* *payload-view*
        *call-facts* *item-facts* *answered-calls* *call-started-ms*
        ;; **`*bound-prompts*`, AND IT IS HERE BECAUSE THE RENDERER READS IT.** `bound-prompt-for`
        ;; answers from this alist by item id, so an ANNOUNCED row draws its text the moment the
        ;; prompt is bound — a row that re-renders to something else with no item and no body
        ;; changing. It is the same class of input as `*payload-view*` below it, and it was found
        ;; the same way: a memo that stops holding does not fail, and a memo that holds across an
        ;; input it does not name draws the row as it was.
        *bound-prompts*
        ;; **AND `*code-generation*`: A PUSH CHANGES THE CODE THAT DRAWS EVERY ROW.** MEASURED, on
        ;; the very push that added the rule above — `/lisp` was pushed to a live head with this
        ;; memo already full, and the rows kept the OLD rendering until something else happened to
        ;; invalidate them, because a push bumps `*code-generation*` and nothing here read it. That
        ;; is `*code-generation*`'s own paragraph (`head.lisp`) one cache over: the counter exists
        ;; because *a cache validated against the FILE it was read from stays valid across a
        ;; redefinition — the file did not move* — and `*repo-todo-cache*` was the only reader of
        ;; it until now. One bump, one frame of re-renders, and the screen matches the image.
        *code-generation*))

(defun %item-live-p (item)
  "Does this ITEM draw something that is a function of the CLOCK, or of a count that keeps moving?

**Asked of the table the renderer itself asks** — `*call-started-ms*`, an alist of `(call-id .
start-ms)` that `note-call-finished` empties — so the memo cannot disagree with the drawing: a row is
live when one of the TOOL CALLS IT CARRIES has started and not finished, the row that counts from the
moment a command starts.

**And the newest item**, where the walk glues the `[n tool calls, m thinking lines]` counts."
  (let ((body (item-body item)))
    (or (some (lambda (c)
                (let ((id (or (getf c :call-id) (getf c :id))))
                  (and id *call-started-ms*
                       (numberp (cdr (assoc id *call-started-ms* :test #'string=))))))
              (getf body :tool-calls))
        (let* ((v (and *head* (session-items (head-session *head*))))
               (n (length v)))
          (and (plusp n) (equal (getf item :item-id) (getf (aref v (1- n)) :item-id)))))))

(defun %item-lines-sig (item)
  "What one item's rendered LINES depend on besides the render context.

**THE ITEM'S OWN FIELDS, NOT THE ITEM.** `:retired` is set on the item IN PLACE
(`(setf (getf item :retired) t)`), so a signature holding the item itself would compare it against
ITSELF and answer *unchanged* for ever. That is not a hypothesis: the `retired-warning` tests are
what said so — with the memo finally holding, *\"and gone from the screen\"* failed on a row that was
still drawn, because `%item-lines-render` reads `(getf item :retired)` and nothing in the signature
moved when it was set. One input, and the screen it was found on.

The body is held by REFERENCE and that is correct: `fill-item` REPLACES `:item` with a new plist
rather than editing the old one, so two bodies are two objects and a body that arrived is a
signature that moved. `:ts` is here for the same reason `:retired` is — `%item-lines-render` draws
the operator block's clock from it."
  (list (and (%item-live-p item) (floor (internal-real-time-ms) +live-frame-ms+))
        (getf item :retired)
        (item-ts item)
        (item-body item)))

