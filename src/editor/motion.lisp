;;;; motion — moving in a prompt: words, lines, the ends
;;;;
;;;; Split out of `editor.lisp`, which was one 2688-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ----------------------------------------------------- motion in a prompt ;;;
;;;
;;; This head has had `alt+enter` since S4, so a prompt can be several lines and
;;; several wrapped rows — and none of these keys knew it. `home` went to the
;;; start of the BUFFER, `ctrl-k` killed to the end of the BUFFER, `↑` always
;;; walked history, and there was no word motion at all: a multi-line prompt you
;;; cannot navigate is a prompt you retype. The reference's editor is line-wise
;;; and row-wise throughout (editor.rs:362-389, 500-516, 687-758).

(defun %whitespace-p (ch)
  (member ch '(#\space #\tab #\newline #\return)))

(defun %word-class (ch style)
  "Which side of a word boundary CH is on. `:small` is the reference's
`WordStyle::Small` — a word is alphanumerics and `_`, so `foo_bar.baz` is three
stops; `:big` is `WhitespaceDelimited`, which is what a kill takes."
  (ecase style
    (:small (or (alphanumericp ch) (char= ch #\_)))
    (:big (not (%whitespace-p ch)))))

(defun composer-word-left (buf cursor &optional (style :small))
  "The index one word to the left of CURSOR (`word_left`)."
  (let ((i cursor))
    ;; the whitespace immediately behind the cursor is skipped first, so a press
    ;; at the end of `one two ` lands at the start of `two` and not in the gap
    (loop while (and (plusp i) (%whitespace-p (char buf (1- i)))) do (decf i))
    (if (zerop i)
        0
        (let ((class (%word-class (char buf (1- i)) style))
              (out i))
          (loop for j downfrom (1- i) to 0
                for ch = (char buf j)
                while (and (not (%whitespace-p ch))
                           (eq (%word-class ch style) class))
                do (setf out j))
          out))))

(defun composer-word-right (buf cursor &optional (style :small))
  "The index one word to the right of CURSOR, past the gap after it
(`word_right`) — so a second press lands on the next word rather than the space
before it."
  (let ((n (length buf))
        (out (length buf)))
    (when (< cursor n)
      (let ((class (%word-class (char buf cursor) style)))
        (loop for j from (1+ cursor) below n
              for ch = (char buf j)
              when (or (%whitespace-p ch) (not (eq (%word-class ch style) class)))
                do (setf out j) (return))))
    (loop while (and (< out n) (%whitespace-p (char buf out))) do (incf out))
    out))

(defun composer-line-start (c)
  "The start of the LINE the cursor is on, not of the buffer."
  (let ((i (position #\newline (composer-buffer c)
                     :end (composer-cursor c) :from-end t)))
    (if i (1+ i) 0)))

(defun composer-line-end (c)
  "The end of the LINE the cursor is on."
  (or (position #\newline (composer-buffer c) :start (composer-cursor c))
      (length (composer-buffer c))))

(defun composer-move (c key)
  (case key
    (:left (setf (composer-cursor c) (max 0 (1- (composer-cursor c)))))
    (:right (setf (composer-cursor c) (min (length (composer-buffer c))
                                           (1+ (composer-cursor c)))))
    ;; the LINE's ends, which is what `home` means in every editor and what this
    ;; one got wrong the moment a prompt could hold a newline
    (:home (setf (composer-cursor c) (composer-line-start c)))
    (:end (setf (composer-cursor c) (composer-line-end c)))
    (:word-left (setf (composer-cursor c)
                      (composer-word-left (composer-buffer c) (composer-cursor c))))
    (:word-right (setf (composer-cursor c)
                       (composer-word-right (composer-buffer c) (composer-cursor c))))))

(defun composer-kill-to-end (c)
  "Ctrl+K: cut from the cursor to the end of the LINE, into the kill ring."
  (composer-kill-region c (composer-cursor c) (composer-line-end c)))

(defun composer-kill-line (c)
  "Ctrl+U: cut from the start of the LINE to the cursor, into the kill ring."
  (composer-kill-region c (composer-line-start c) (composer-cursor c)))

(defun composer-kill-word (c)
  "Ctrl+W: cut back to the start of the word before the cursor, into the ring.

Whitespace-delimited, as the reference's is — and whitespace, not `#\\space`
alone: the scan tested for a space, so a newline was not a boundary and one
ctrl-w on a multi-line prompt ate back through the line above."
  (composer-kill-region c
                        (composer-word-left (composer-buffer c) (composer-cursor c) :big)
                        (composer-cursor c)))

(defun composer-push-history (c line)
  "Remember LINE, unless it repeats the newest entry. Oldest dropped past the cap.

Consecutive duplicates are dropped because the shape they come from — send, edit
one word, send again — is the shape that fills the history with the same line and
makes `↑ ↑ ↑` walk nothing (editor.rs:588-593)."
  (let ((h (composer-history c)))
    (unless (and (plusp (fill-pointer h))
                 (string= line (aref h (1- (fill-pointer h)))))
      (vector-push-extend line h)
      (when (> (fill-pointer h) *history-max*)
        (replace h h :start2 1)
        (decf (fill-pointer h))))
    (setf (composer-hist-pos c) (fill-pointer h))))

(defun composer-history-step (c delta)
  "Up/Down through sent lines. T when the buffer moved.

The in-progress line is kept at position `length`, so leaving history restores
what was half-typed — and a RECALLED line that has since been edited stops the
walk, rather than being thrown away by the next press."
  (when (and *history-recalled*
             (not (string= *history-recalled* (composer-buffer c))))
    (return-from composer-history-step nil))
  (let* ((n (length (composer-history c)))
         (target (+ (composer-hist-pos c) delta)))
    (when (<= 0 target n)
      (when (= (composer-hist-pos c) n)
        (setf (get 'composer :draft) (composer-buffer c)))
      (setf (composer-hist-pos c) target)
      (setf (composer-buffer c)
            (if (= target n)
                (or (get 'composer :draft) "")
                (aref (composer-history c) target)))
      (setf (composer-cursor c) (length (composer-buffer c))
            *history-recalled* (composer-buffer c))
      t)))

(defun %offset-in-range (text range col)
  "The index in TEXT, inside the wrapped row RANGE, that sits COL columns in."
  (let ((i (car range))
        (end (cdr range))
        (w 0))
    (loop while (and (< i end) (< w col))
          do (incf w (char-width (char text i)))
             (incf i))
    i))

(defun composer-cols (head)
  "The content width the composer is measured against: the frame less the gutter
and the right margin, which is `%render`'s own `cols` (render.lisp:288).
`composer-ranges` takes it from there to the box's inner width, so motion asks
the same question the painter does, through the same two functions."
  (max 20 (- (head-cols head) +gutter+ +right-margin+)))

(defun composer-vertical (head up)
  "Move the cursor one VISUAL row. T when it moved; NIL at the edge.

By visual row and not by logical line: a pasted paragraph soft-wrapped over six
rows should take six presses to cross, and anything else puts the cursor
somewhere the operator was not looking. The rows are the ones the COMPOSER IS
DRAWN WITH (`composer-ranges`, chrome.lisp), so motion and drawing cannot
disagree about where a row ends.

NIL at the top and bottom is the caller's cue to walk history instead, which is
what a one-line composer's ↑ always meant (editor.rs:500-516)."
  (let* ((c (head-composer head))
         (buf (composer-buffer c))
         (ranges (composer-ranges head (composer-cols head)))
         (rows (length ranges)))
    (multiple-value-bind (row col) (locate-in-ranges buf (composer-cursor c) ranges)
      (let ((col (or *preferred-col* col)))
        (cond ((and up (zerop row)) nil)
              ((and (not up) (>= (1+ row) rows)) nil)
              (t (setf (composer-cursor c)
                       (%offset-in-range buf (nth (if up (1- row) (1+ row)) ranges) col)
                       *preferred-col* col)
                 t))))))



(defun composer-buffer-set (c text)
  "Replace the buffer wholesale, for undo."
  (setf (composer-buffer c) text
        (composer-cursor c) (length text)))

(defun %undo-push (c)
  "Snapshot the buffer, unless it already matches the newest snapshot."
  (unless (and *undo-stack* (string= (car *undo-stack*) (composer-buffer c)))
    (push (composer-buffer c) *undo-stack*)
    (when (> (length *undo-stack*) *undo-max*)
      (setf *undo-stack* (butlast *undo-stack*)))))

(defun composer-undo (c)
  "Undo one snapshot. T when something was undone.

Undo is BATCHED by the caller — a kill pushes its own snapshot, and a run of
characters pushes one at the start of the word — so this pops whatever is there
rather than trying to decide how much to take back. The kill ring is deliberately
untouched: undo restores the document, not the clipboard."
  (when *undo-stack*
    (push (composer-buffer c) *redo-stack*)
    (composer-buffer-set c (pop *undo-stack*))
    t))

(defun composer-redo (c)
  "Redo one undone buffer. T when something came back.

`alt+z`, because Ctrl+Shift+Z arrives byte-identical to Ctrl+Z in many terminals
and there is no second chord to give it (term.rs:740-742)."
  (when *redo-stack*
    (push (composer-buffer c) *undo-stack*)
    (composer-buffer-set c (pop *redo-stack*))
    t))

(defun composer-kill-region (c start end)
  "Cut [START, END) into the kill ring, newest first."
  (let ((buf (composer-buffer c)))
    (when (< start end)
      (setf *redo-stack* nil)
      (push (subseq buf start end) *kill-ring*)
      (when (> (length *kill-ring*) *kill-ring-max*)
        (setf *kill-ring* (butlast *kill-ring*)))
      (setf (composer-buffer c) (concatenate 'string
                                             (subseq buf 0 start)
                                             (subseq buf end))
            (composer-cursor c) start)
      t)))

(defun composer-yank (c)
  "Insert the head of the kill ring at the cursor. T when it did."
  (when *kill-ring*
    (composer-insert c (first *kill-ring*))
    t))

(defun %paste-lines (text)
  "How many lines TEXT holds, as a person would count them.

`(1+ (count #\\newline text))` — the obvious formula — gives 301 for 300 lines
each ending in a newline, because it counts the empty tail as a line. A paste
whose marker says `301 lines` when the operator pasted 300 is a small lie in the
one number the marker exists to carry, so the final newline does not start a
line."
  (let ((n (count #\newline text)))
    (if (and (plusp n) (char= (char text (1- (length text))) #\newline))
        n
        (1+ n))))

(defparameter *paste-bytes* 800
  "A paste this long collapses to a marker whatever its line count — the
reference's `PASTE_BYTES`. Five lines is not the only shape a paste nobody wants
in the composer comes in: a three-line, four-kilobyte log fills the box and
pushes the transcript off the screen, and the line count says `3`.")

(defun %paste-marker (n)
  "The marker for a paste of N lines, NUMBERED.

**The number is what makes it unique**, and it was not there: the marker keyed on
the line count alone, so two twelve-line pastes in one prompt produced the SAME
marker and `expand-pastes` replaced both occurrences with whichever text the
ledger found first. Two stack traces pasted into one prompt became the same stack
trace twice — silent corruption in the one path that exists to carry large text
faithfully (editor.rs:564-566). The count of the ledger is the number, and the
ledger is cleared per submitted line, so it restarts at 1 for every prompt."
  (format nil "[⋮ pasted ~a lines #~d ⋮]" n (1+ (length *paste-ledger*))))

(defun %normalise-paste (text)
  "CRLF, then bare CR, to newlines.

Windows ConPTY sends CR-only newlines inside a bracketed paste, and a naive
CRLF replace leaves those behind as control characters a terminal renders as a
carriage return — and the line count is wrong as well (editor.rs:557-561)."
  (substitute #\newline #\return
              (with-output-to-string (s)
                (loop for i from 0 below (length text)
                      for ch = (char text i)
                      unless (and (char= ch #\return)
                                  (< (1+ i) (length text))
                                  (char= (char text (1+ i)) #\newline))
                        do (write-char ch s)))))

(defun composer-insert-paste (c text)
  "Insert TEXT, or a marker standing for it when it is large.

A three-thousand-line paste as three thousand lines of composer is a buffer
nobody can see the end of; as a marker it is one visible token that still sends
whole. The marker is opaque and the ledger holds the text, so nothing is lost by
rounding. Large is five lines OR more than `*paste-bytes*` of it."
  (let ((text (%normalise-paste text)))
    (if (and (< (%paste-lines text) 5)
             (<= (length text) *paste-bytes*))
        (progn (composer-insert c text) nil)
        (let ((marker (%paste-marker (%paste-lines text))))
          (push (cons marker text) *paste-ledger*)
          (composer-insert c marker)
          marker))))

(defun expand-pastes (text)
  "Replace every paste marker in TEXT with the text it stands for."
  (let ((out text))
    (dolist (pair *paste-ledger*)
      (when (search (car pair) out)
        (setf out (with-output-to-string (s)
                    (let ((i 0)
                          (marker (car pair))
                          (full (cdr pair)))
                      (loop for j = (search marker out :start2 i)
                            while j
                            do (write-string (subseq out i j) s)
                               (write-string full s)
                               (setf i (+ j (length marker))))
                      (write-string (subseq out i) s))))))
    out))

