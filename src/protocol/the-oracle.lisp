;;;; the-oracle — R11: the oracle's own exchange
;;;;
;;;; Split out of `protocol.lisp`, which was one 783-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------ R11: the oracle's own exchange (25) ;;;
;;;
;;; **A LOCATOR, not a payload.** R11 put both halves of the oracle's exchange on the
;;; corpus row (`shown`, `oracle_reply`) and neither reached a head, because a card that
;;; carried a whole brief and a whole reply would carry them for every card on the
;;; screen. This is the same shape as `FetchRow`, which is this document's own precedent
;;; for *the head asks the daemon for something big it does not normally hold*.
;;;
;;; **`body: None` and `body: Some("")` are two facts.** The store holds NULL on every row
;;; written before R11 kept the exchange, and an oracle that never answered has no reply
;;; either — *"nobody kept this"* and *"here it is, and it is empty"* are both real, and
;;; `total` is on the frame rather than inferred because `body.map(len).unwrap_or(0)`
;;; cannot tell them apart either.
;;;
;;; **A `request_id` nobody has is `body: None`, NOT an error and NOT a `Rejected`**: the
;;; row may have been compacted, the id may be from another session, and *not recorded* is
;;; the honest answer to all of it. A head draws the same sentence and does not retry.
;;;
;;; **No `expected_seq`**: this is a read, it moves nothing, and a head that asked while
;;; the screen moved still meant it. The wire says `brief`/`reply`; the store has always
;;; said `shown`/`oracle_reply`, and that mapping is the daemon's own (`DiagnosticSource`)
;;; — neither vocabulary is flattened into the other.

(defparameter +diagnostic-kinds+ '("brief" "reply")
  "The two halves, in the order a card reads them. The daemon's own spellings.

A `defparameter` rather than a constant because the file pusher skips constants, and it
is the ONE place this head knows that there are two: `%diagnostic-ask` walks it, so a
third kind would be asked for by adding a name here and nowhere else.")

(defun make-fetch-diagnostic (request-id kind)
  "The read: the oracle's brief or its reply, for the adjudication REQUEST-ID.

Two fields, and both absences are deliberate: no `expected_seq` (a read moves nothing) and
no `client_request_id` (there is no per-ask reply — the answer is a `diagnostic` frame
keyed by the ADJUDICATION's id, which is also what `/gate` takes)."
  (list :frame "fetch_diagnostic"
        :request-id request-id
        :kind kind))

(defun make-detach ()
  "A clean goodbye. Not required: close is detach too, and detach is never
abort (protocol.rs on ClientFrame::Detach)."
  (list :frame "detach"))

;;; The one frame only a head can answer: its own screen, as it drew it
;;; (protocol.rs on ClientFrame::Screen). ROWS is one string per row, escapes
;;; included, at the head's real size.
(defun make-screen-answer (req-id cols rows-n rows)
  "This head's screen as it drew it: COLS columns by ROWS rows, one row per string.

**COLS IS A COLUMN COUNT, NOT A STRING LENGTH.** This sent
`(length (first rows))` — the character length of row zero, **ANSI escape bytes
included** — so a 100-column frame reported 100 plus every SGR byte in its top row,
and the daemon believed it. That is the worst available kind of wrong: not an error,
a number that parses.

The reference sends its terminal size (`driver.rs:287` — `self.client.screen(&req_id,
size.0, size.1, …)`), and its own doc on this frame asks for *\"last rendered, ANSI
and all, at its real terminal size\"* (protocol.rs on `ClientFrame::Screen`). The two
numbers are REQUIRED arguments rather than derived here, because the derivation is
exactly what was wrong: a row's length is a length of characters or bytes, and the
head's own width is a count of CELLS by the one rule this tree has (`string-width`,
width.lisp, whose tables are the reference's code point for code point).

`%answer-screen-requests` passes `head-last-cols`/`head-last-rows-n` — the size the
paint that produced ROWS actually used."
  (declare (type fixnum cols rows-n))
  (list :frame "screen"
        :req-id req-id
        :cols cols
        :rows-n rows-n
        :rows rows))
