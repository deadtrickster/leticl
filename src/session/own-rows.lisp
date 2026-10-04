;;;; own-rows — the rows this head writes into its own conversation
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------- this head's own rows ;;;
;;;
;;; **A sentence this head writes ABOUT ITSELF, filed where it happened.** The
;;; conversation is the only place a fact about the connection can live and still be
;;; readable an hour later: a status note sits pinned above the composer and expires
;;; on a TTL, so anything filed there is gone — and gone SILENTLY — by the time
;;; anybody thinks to look, which is the failure this shape exists to avoid.
;;;
;;; Two facts are filed this way and both are about the SOCKET rather than the session
;;; log, which is why `ts` is 0 rather than invented: a frame this head could not read
;;; (`note-unreadable`) and a protocol skew at the handshake (`note-protocol-skew`).

(defvar *filed-notes* 0
  "How many rows this head has filed about itself, over its life.

A `defvar` so a push can introduce the next filer without a struct slot, and not a
constant, because a constant is the one kind of definition the file pusher SKIPS.")

(defun file-head-note (session text)
  "FILE TEXT into the conversation as a row of this head's own, at the point it
happened. Returns the item.

`:kind`/`:type` are both `note`, which no daemon item uses — the wire's are `user`,
`assistant`, `reasoning`, `tool_result`, `system` and `segment_mark` — so
`item-lines` renders it as `! …` in the failure role, the reference's `warn_line`
(app.rs:8425-8427), without a tag anybody could also send.

An item id unique to this head, because the wire's ids are `s.3`, `t1.0` and the
like and nothing the daemon sends must ever be confused with a row this head wrote."
  (incf *filed-notes*)
  (let ((item (list :item-id (format nil "leticl-note-~d" *filed-notes*)
                    :kind "note"
                    :ts 0
                    :item (list :type "note" :text text))))
    (push-item session item)
    item))

(defvar *unreadable-total* 0
  "Frames that arrived and could not be read, over this head's life.

The bucket the reference's `/status` gained with this requirement, and the one
number that keeps *the daemon is sending me something I do not understand* apart
from *the daemon is quiet*. A `defvar` rather than a session slot, and NOT reset
by a snapshot: it counts this head's lifetime, so a row that reads 0 is a head that
has never met one — a different statement from a head that does not count them.")

(defparameter *unreadable-line-cols* 200
  "How much of the offending line the complaint carries.

A `defparameter` and not a `defconstant`: the file pusher SKIPS `defconstant` (it
changes a definition the image has already copied), so a constant here could never
be changed on a running head — the one thing every value in this repo must allow.")

(defun unreadable-said (detail line)
  "The sentence this head says about a frame it cannot read.

ONE function, so the three places that can meet one cannot describe it three
ways: a head that exits, a head that shrugs and a head that counts have to agree
about what happened, and the only way to guarantee that is one string.

It names this head's OWN protocol version, because the two numbers are the whole
comparison — a daemon newer than this head is almost always the cause, and saying
so is what sends the operator to the right half. The offending line rides along
TRUNCATED rather than dropped: the line is the evidence, a decoder that reports
\"bad frame\" without the frame turns a precise complaint into a shrug, and the
first question anybody asks about a skew is *which frame*."
  (let* ((width (string-width (or line "")))
         (shown (and (plusp width) (truncate-to-width line *unreadable-line-cols*)))
         (cut (> width *unreadable-line-cols*)))
    (format nil "the daemon sent a frame this head cannot read (~a). This head ~
                 speaks protocol ~d; a daemon built against a newer one will do ~
                 this on the first frame the two do not share, and it is almost ~
                 always that rather than a corrupt stream. The connection is ~
                 still up.~@[ The line was: ~a~a~]"
            detail +protocol-version+ shown (if cut "…" ""))))

(defun note-unreadable (session detail line)
  "SAY it, COUNT it, keep going — the one entry point for a frame this head cannot
read. Returns `:dirty`, so a caller folding an envelope hands it straight back.

**The sentence is filed as a ROW IN THE CONVERSATION, at the point it arrived** —
not as a status note, which is the head state this repo already has and is the
wrong shape twice over: a note sits pinned above the composer for a few frames and
then expires on a TTL, so a frame this head could not read would be gone by the
time anybody looked for it, and it would be gone silently, which is the failure
again. An item is anchored where it landed and scrolls away with the rest of the
conversation, which is what \"where it arrived\" means and why `ts` is 0 rather than
invented: this happened on the SOCKET, and the session log's clock is not this.

**Nothing is acked and the read mark does not move.** No frame was parsed, so
there is no seq to report, and inventing one would rewind the mark over frames
already read — the one thing a mark must never do. `/status`'s `filtered` is \"events
I chose not to show\" and this is not that either."
  (incf *unreadable-total*)
  (file-head-note session (unreadable-said detail line))
  :dirty)

(defun note-protocol-skew (session said)
  "FILE the skew sentence into the conversation, at the handshake. Returns `:dirty`.

**Not counted as unreadable.** A skew is a fact about two BUILDS and it is said once
per connection — counting it there would make `/status`'s number mean *frames I could
not read* PLUS *times I noticed two versions*, and that first number is the one an
operator uses to tell a chatty daemon from a broken one. The version it was about has
its own `/status` row, which is the other half of this fact.

**Nothing is acked for it and the read mark does not move**: a `Hello` carries no
`seq` (it is a snapshot, not an event), so there is nothing to report and inventing
one would rewind the mark over frames already read."
  (file-head-note session said)
  :dirty)

