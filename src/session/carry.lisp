;;;; carry — what a compaction carries across the boundary
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- the carry ;;;
;;;
;;; **A bulk announcement, and the rows it left outstanding.** `/reseat` and
;;; `/compact` publish an announcement for every carried row before a single body
;;; follows, so a head that draws one placeholder per row draws a screen of them —
;;; *"insane amount of grainess"*. One progress line instead (`carry-line`,
;;; chrome.lisp), and this is the state it needs.
;;;
;;; **The carry's rows are the ones THE ANNOUNCEMENT LEFT OUTSTANDING, recorded by
;;; id.** That is the fact, and it is not the same as "every row in the session that
;;; lacks a body" — measured on the operator's own live session, 2 of its 4451 rows
;;; have no body and never will (they are in the middle of its history, from a turn
;;; long finished), so a count over the whole transcript would put a progress line on
;;; their screen for a carry that is not happening. The reference's `peak - pending`
;;; has the same shape of error: its `pending` is measured over the session, so an
;;; ancient bodiless row is counted as work still to do.
;;;
;;; Recorded at the SNAPSHOT because that is where a bulk announcement arrives (the
;;; reference's `adopt` and its own test: *"the snapshot really does arrive carrying
;;; bodiless rows"*). A live `transcript_appended` announces one row whose body
;;; follows in the same drain pass, which is not a carry and never draws a line.

(defvar *carry-outstanding* nil
  "A hash table of the item ids a bulk announcement left without bodies, or NIL when
no carry is in flight. A defvar, not a session slot: a struct layout change is a
restart, and this has to be reachable from a push.")

(defun note-carry (raw-items)
  "Note which rows RAW-ITEMS announced without bodies, or clear the carry.

A snapshot with every body present clears it — a new snapshot replaces the world, and
a carry that was in flight when it landed is not one any more. Returns how many rows
the announcement left outstanding."
  (let ((out (make-hash-table :test #'equal))
        (n 0))
    (dolist (raw (coerce (or raw-items nil) 'list))
      (when (and (consp raw) (null (getf raw :item)) (getf raw :item-id))
        (setf (gethash (getf raw :item-id) out) t)
        (incf n)))
    (setf *carry-outstanding* (and (plusp n) out))
    n))

(defun reset-carry ()
  "Forget the carry. T when there was one."
  (let ((had (and *carry-outstanding* t)))
    (setf *carry-outstanding* nil)
    had))

(defun %carry-counts (session)
  "How many rows the carry announced, and how many of them have ARRIVED.

`(values 0 0)` when nothing is in flight. Both numbers are counted off the rows, every
frame — the ids were recorded when the announcement was made, and whether the row has
a body is read from the row itself. Nothing is remembered about the progress, which is
the rule this repo learned the hard way: an incremental tally kept alongside a
collection goes stale the moment something replaces the collection, and a fork is
exactly when something does. The reference shipped that and the operator saw a bar
that never moved — *\"so, counter wasnt moving - 0 always\"*."
  (if (null *carry-outstanding*)
      (values 0 0)
      (let ((total (hash-table-count *carry-outstanding*))
            (done 0))
        (declare (type fixnum total done))
        (loop for item across (session-items session)
              do (when (and (gethash (item-id item) *carry-outstanding*)
                            (item-body item))
                   (incf done)))
        (values total done))))

