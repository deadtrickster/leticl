;;;; slash.lisp — a verb's answer when it is a listing rather than a sentence
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ---------------------------------------------------- the slash listing ;;;
;;;
;;; **A verb's answer, when it is a listing rather than a sentence.**
;;;
;;; `/tools`, `/gate recent`, `/flowy status` and `/models` all answer through the
;;; daemon under one warning code, `slash`, and until this existed every one of them
;;; landed as a note on the session log and scrolled away. The reference splits them by
;;; the only thing that distinguishes them — the reply's length — and opens a pane for
;;; anything past three lines (app.rs:3266-3275, `app.rs:5873-5880`).
;;;
;;; **This is the third instance of a shape this head already had twice, and that is the
;;; point.** A pane whose content does NOT come from the session is a `defvar` holding
;;; what arrived plus a mode that draws it: `*peeked*`/`:peek` and `*job-out*`/`:job-out`
;;; are the first two. Adding `:slash` is not a third hand-rolled pane — it is the
;;; existing overlay shape applied to a reply that had nowhere to go, and the two axes
;;; are independent enough to say out loud:
;;;
;;;   · **where the CONTENT comes from** — the session (a pure function of it, like
;;;     `:help` and `:config`) or a `defvar` holding what a reply brought (`:peek`,
;;;     `:job-out`, `:slash`);
;;;   · **which END it is read from** — a document you read from the top (`pane-view`,
;;;     head-first) or a log whose newest line matters (`:peek` and `:job-out`, which
;;;     window tail-first and clamp their own scroll).
;;;
;;; A slash listing is the first of one and the first of the other: content that arrived,
;;; read from the top. So there is no new machinery here — a defvar, a mode, `pane-view`
;;; and `pane-row-count` — and the question a reader should ask of the NEXT pane is
;;; which corner it sits in, not how to write it.

(defvar *slash-out* nil
  "The open slash listing: a cons `(ECHO . LINES)`, or NIL.

ECHO is the command the daemon echoed back — drawn BOLD, because a listing with no
memory of what was typed is a listing you cannot place. LINES is its body, already
stripped of control characters, one string per line.

A `defvar` and not a head slot: a struct layout change is a restart, and this has to
be reachable from a push. Bound by `with-replay-globals`.")

(defun close-slash-out ()
  "Close the listing. T when there was one."
  (let ((had (and *slash-out* t)))
    (setf *slash-out* nil)
    (reset-pane-scroll)
    had))

(defparameter +slash-listing-lines+ 3
  "How long a slash reply has to be before it is a LISTING and opens a pane.

The reference's `lines.len() > 3` (app.rs:3271). It is a length and not a marker
because the daemon sends both kinds under one code — `detail` is the command echoed
back, then the reply — so length is the only thing that distinguishes `/tools`'s table
from `mode → allow-all`'s sentence. A constant with a citation rather than a taste.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a
constant could never be changed on a running head.")

(defun %slash-reply-split (detail)
  "DETAIL as `(values ECHO LINES)`: the echoed command and the reply's body.

The daemon's format is the command, a newline, then the reply (app.rs:3268-3270), so
the first line is the echo and the rest is the body. A detail with NO newline is a
sentence — an echo and an empty body — which is how the caller ends up with 0 lines and
leaves it as a note."
  (let* ((nl (position #\newline (or detail "")))
         (echo (if nl (subseq detail 0 nl) (or detail "")))
         (body (if nl (subseq detail (1+ nl)) "")))
    (values echo (mapcar #'%without-control (uiop:split-string body :separator '(#\newline))))))

(defun note-slash-reply (detail)
  "Open the listing when DETAIL is long enough to be one. T when it opened.

Called from the warning arm, which is where this arrives: the daemon publishes a slash
reply as a `Warning` with code `slash` (or `slash_refused`), so a head that only pushes
warnings to a list has every verb's output in the log and none of it on a screen."
  (multiple-value-bind (echo lines) (%slash-reply-split detail)
    ;; a trailing empty line is the daemon's terminator, not a row: the reply is
    ;; `str::lines`' shape, and a pane one row longer than the text is a pane with a
    ;; blank at the end that reads as content
    (when (and lines (zerop (length (car (last lines)))))
      (setf lines (butlast lines)))
    (when (> (length lines) +slash-listing-lines+)
      (setf *slash-out* (cons echo lines))
      (reset-pane-scroll)
      t)))

(defun slash-out-lines (head cols &optional room)
  "The listing: the echoed command, its body, and how to leave.

    /tools
    <blank>
    read  failed  1.2s  read a file
    …                    (wrapped at COLS)
    <blank>
        esc closes · up/down scrolls

**The footer names the keys that WORK**, which is the rule every pane here keeps: the
arrows scroll, esc closes, and a footer that named a key the pane did not take is the
defect this repo has now found four times (the seam that named `ctrl-t` with the fold
already open was the last one). `q` closes it too, and is not named — the reference's
footer names esc alone (app.rs:5878).

The body is WRAPPED rather than truncated: a listing is prose an operator reads to the
end, and `/gate recent`'s rows are sentences, so a cut line costs the reason."
  ;; ROOM is accepted and unused, like `help-lines`: this listing does not window
  ;; itself. `pane-view` does that, head-first, with `*pane-lines*` set from this
  ;; list's length — the same division every document pane here uses.
  (declare (ignorable head room))
  (let* ((echo (or (car *slash-out*) ""))
         (lines (or (cdr *slash-out*) nil))
         (w (pane-width cols))
         (out (list (list (cons echo '(:bold t))) nil)))
    (dolist (l lines)
      (dolist (row (or (wrap-segments (list (cons l nil)) w) (list nil)))
        (push row out)))
    (push nil out)
    (push (list (cons "    esc closes · up/down scrolls" '(:dim t))) out)
    (nreverse out)))

