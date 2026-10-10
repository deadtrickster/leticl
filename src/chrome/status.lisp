;;;; status — the status row
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; --------------------------------------------------------------- status ;;;

(defun status-line (head cols)
  "The status row: the note, the connection, the scroll, the queue, the stall.

**Not on the frame\'s path any more.** `%render` used to draw this only when
there was no composer box — i.e. never on a real terminal — and now draws the
note and the stall as their own chrome rows (`notice-line`, `stall-row`) and the
unboxed fallback as `alarm-line`, which is what the reference pushes there
(app.rs:5199-5201). Kept because it is a named contract surface (HACKING.md) and
because `/status` and a restyle both still reach it; redefining it no longer
changes the frame, and `notice-line` is the function that does.

The counters moved to the ALARM line and to `/status`, which is the reference\'s
own change and the right one: `seq 907 · rendered 900 · filtered 1 · dropped 0` on
every frame next to the thing you are typing into is a row of attention spent for
ever on a number that is zero."
  (let* ((note (or (head-status-note head) ""))
         (scroll (if (plusp (head-scroll head))
                     (format nil " · ↑~a" (head-scroll head)) ""))
         (queued (if (head-queued head)
                     (format nil " · ~d queued" (length (head-queued head))) ""))
         (stall (or (stall-text) ""))
         (text (format nil " ~a~a~a~a" note scroll queued stall))
         (style (if (head-connected head) '(:dim t) '(:fg :red :bold t))))
    (list (cons (truncate-to-width text (max 1 (or cols 1)))
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:dim t)))))

