;;;; fetch — the rows this head does not hold, pulled in one at a time
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- the rows this head does not hold ;;;
;;;
;;; **A transcript that begins where the head's window begins, and does not say so, is
;;; a lie by omission.** `ViewBounds` bounds a snapshot by count and by bytes — 2,000
;;; rows or 8 MB of row text, whichever comes first (`view.rs:308-347`) — so a head on
;;; a long session holds the NEWEST slice of the conversation and `items_dropped` says
;;; how many rows came before it. That number was stored and **read by nothing**: no
;;; seam, no counter, no `/status` row. Scroll to the top of such a session and the
;;; transcript ends as cleanly as a session whose first row that is, which is the
;;; defect R17 spent a commit on for body-less rows — *"a disclosure that does not
;;; happen cannot be dismissed"*.
;;;
;;; The rows above are named by ORDINAL (`FetchRow`, `protocol.rs:783-797`) and the
;;; daemon answers a window of one of them. **What the head asks for is the row
;;; immediately above its oldest**, which is `items_dropped - 1`, and a `Some` answer
;;; is prepended to the transcript — so scrolling up walks back into the conversation
;;; one row at a time.
;;;
;;; MEASURED against today's daemon, and this is the honest half of the capability:
;;; **`FetchRow` can never answer a row the head does not already have.** The snapshot
;;; is `view.items.clone()` (`view.rs:821`) and `row_body_at` reads the same
;;; `self.items` (`view.rs:745-747`) — one view, one bound — so an ordinal the snapshot
;;; trimmed answers `null`, and an ordinal the snapshot carried is a row the head
;;; already holds. The frame's own test says the same thing from the other side: *"the
;;; store read that would answer it is R19.2(b) in `letibot`'s TODO"*. The head's half
;;; is built anyway, because the head cannot know WHICH of those two worlds it is in
;;; without asking, and the seam cannot be honest without it.

(defparameter +row-fetch-len+ 65536
  "How many bytes of a row this head asks for in one `FetchRow`.

The daemon's own cap (`server.rs`: `MAX_FETCH_ROW`), not a smaller number of our own:
the frame is a *window* and the head renders a transcript row out of it, so asking for
less than the daemon will send would only mean the same row arriving in pieces for no
reason. A body longer than this is drawn with a seam saying how much more there is —
the same instrument the payload window already uses.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defvar *row-fetch* nil
  "`(:row N :at MS)` while this head has asked for a row above its oldest, else NIL.

A `defvar` rather than a slot — a struct change is a restart — and it holds ONE
request, because the transcript has one top: a head that pipelined fetches up its own
history would be fetching rows it may never show.

Bound by `with-replay-globals`, because a replay must answer the same bytes twice.")

(defvar *rows-above-unserved* nil
  "T once the daemon has answered `body: null` for a row above this head's oldest.

**Not a failure, and not retried** — but the old name and the old sentence said the rows
were GONE, and **nothing is gone.** Measured against the operator's own store on
2026-10-02: session `s-1789639478142928813` is a chain of 27 transcripts (`#t0` … `#t26`),
`transcript_item` is append-only by trigger, and the current link holds 145 rows while the
links behind it hold 28198, 22802, 145017 and up to 913523 of them. Every row the reader
was scrolling to is on disk.

What `null` means is narrower, and the daemon wrote the distinction down for the caller:
`SessionView::row_body_at` returns `None` *\"when the ordinal is outside what this view
holds: trimmed by `ViewBounds`, or past the end of the session. **That distinction is the
caller's to make**\"*. leticl IS that caller, and it did not make it — it turned an answer
about a bounded window into an assertion about the world.

**The two tiers also number rows differently, which is the mechanism.** `items_dropped`
counts rows trimmed out of the DAEMON'S VIEW, which accumulates across a session's whole
link chain; `FetchRow`'s store tier resolves the same number against
`current_transcript_id` and `seq`, and `seq` is *\"0-based, dense\"* **per link**. So the
ordinal the seam advertises names nothing in the current transcript, the store tier
answers `null` honestly — `row_body`'s own comment says *\"the ordinal is relative to the
CURRENT transcript\"* — and what comes back looks like absence.

So the flag still does the job it was introduced for, which is to stop a head asking once
per scroll for ever; it just no longer claims the rows do not exist. **Saying where they
ARE needs a fact no head is sent**: there is no fork event in the session stream, the
parent id is in `ForkReport` and on no wire, and the daemon's own module note for the
`transcript` tool says *\"everything a compaction folded into a summary is in the links
behind it\"* — reachable by that tool and by no head.

A `defvar` and not a session slot: it is about THIS head's window, not about the session,
and a snapshot must not clear it — the head that discovered the rows are out of reach
still has that fact after a resync.")

(defun rows-above (session)
  "The ordinal of the row immediately above this head's oldest, or NIL when there is none.

`items_dropped` counts the rows that came before the ones held, so the row above the
oldest held one is `items_dropped - 1` — and zero means there is nothing above, because
ordinal 0 IS the session's first row ever. The same arithmetic `view.rs:736` states:
*\"the row above my oldest is `items_dropped - 1`\"*."
  (let ((dropped (or (session-items-dropped session) 0)))
    (when (plusp dropped) (1- dropped))))

(defun note-row-fetched (session row body total)
  "Fold one `RowFetched`. Returns `:dirty` when something visible changed.

**Three answers, and they are three different facts:**

  · `body` is a STRING — the daemon holds the row, and it goes at the TOP of the
    transcript. It is prepended, not appended: its ordinal says it is older than
    everything held, and the transcript is oldest-first. `items_dropped` is decremented
    with it, because that count and the items must keep summing to the session's length
    or `rows-above` starts naming the wrong row;
  · `body` is NIL — the daemon will not serve it, and `*rows-above-unserved*` makes the
    seam say that instead of offering a fetch that will keep failing. **It is not a
    statement that the rows are gone**: see that flag, and the note above about the two
    ordinal spaces, for what `null` does and does not mean;
  · and a row that arrives while NOTHING is pending is ignored, because it is the answer
    to a question this head is no longer asking (a fetch another head's scroll started,
    or one from before a resync).

`total` is the WHOLE body's length and is kept with the row, so a fetched row longer
than the window this head asked for can say how much more there is — the one thing the
frame exists to make sayable."
  (let ((want (getf *row-fetch* :row)))
    (setf *row-fetch* nil)
    (cond
      ((null want) :quiet)
      ;; a redelivery, or an answer about a row this head has already caught up past
      ((or (/= want row) (null (rows-above session)))
       (when (null body) (setf *rows-above-unserved* t))
       :dirty)
      ((null body)
       (setf *rows-above-unserved* t)
       :dirty)
      (t
       (prepend-item session
                     (list :item-id (format nil "leticl-row-~d" row)
                           :kind "fetched"
                           :ts 0
                           :item (list :type "fetched" :row row :text body :total total)))
       (decf (session-items-dropped session))
       :dirty))))

(defun rows-above-line (session cols)
  "The seam above the oldest row this head holds, or NIL when it holds all of them.

**The disclosure R17 argues for, one layer out.** A window that does not say it is a
window is read as the whole conversation — and the operator scrolling to the top of a
long session has no way to tell *\"this is where it begins\"* from *\"this is where my
head stops\"*. Three states, because there are three facts:

  · **asking** — a request is in flight for a named ordinal;
  · **unserved** — the daemon answered `null`, and the seam stops offering a fetch rather
    than promising one that cannot happen. **The word is `unserved` and not `gone`,
    which is what this said until 2026-10-02**: `null` means the ordinal is outside what
    the daemon's view holds and its store tier can resolve, and the operator's own store
    says the rows are all still there in the links behind. A seam that told a reader their
    conversation had been destroyed when it had been neither destroyed nor reachable was
    wrong twice, and the second is the one that costs them a scrollback they still had;
  · **here** — rows above exist and this head will load the next one as the reader
    reaches this line.

It is DIM, like the other seams in this tree (`… +N lines · ctrl-t`): it is an
instrument, not part of the conversation."
  (let ((n (session-items-dropped session)))
    (when (and (integerp n) (plusp n))
      (let ((row (rows-above session))
            (text (cond
                    (*row-fetch*
                     (format nil "… ~d row~:p above · asking the daemon for row ~d…"
                             n (getf *row-fetch* :row)))
                    (*rows-above-unserved*
                     (format nil "… ~d row~:p above · the daemon does not serve these for this transcript"
                             n))
                    (t (format nil "… ~d row~:p above · scroll to this line to load the next"
                               n)))))
        (list (list (cons (truncate-to-width text cols) '(:dim t))))))))

(defun prepend-item (session item)
  "ITEM at the FRONT of the transcript, and the render cache invalidated.

**A prepend is not a push**, and the difference is why this is not `push-item`: the
items vector is oldest-first and grows at the END, so a row discovered on the older
side has to go in front of every row held. Rebuilt rather than shifted in place,
because it happens on a keypress at the top of a scrolled transcript and not per frame:
2,000 conses is nothing beside the frame it provokes.

The vector's IDENTITY changes, which is in `%hist-key` — so the cached lines are
dropped rather than reused against a transcript that gained a row at the front."
  (incf *hist-generation*)
  (setf (session-items session)
        (%items-vector (cons item (coerce (session-items session) 'list))))
  item)

