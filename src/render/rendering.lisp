;;;; rendering — the frame itself, composed from the cards, chrome and panes
;;;;
;;;; Split out of `render.lisp`, which was one 2043-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------ rendering ;;;
(defun segs-text-of (line)
  "A segment-line's text, for asking whether it renders as nothing."
  (if line (format nil "~{~a~}" (mapcar #'car line)) ""))

(defun %white-char-p (ch)
  "Every character that occupies columns without saying anything.

**`#\\space` ALONE IS NOT THE QUESTION, and the cost was a hole on the operator's screen.**
Measured 2026-09-26: an assistant row whose text is `\"  \\n \"` rendered as ONE line that this
file did NOT consider blank — because the character it tripped over is a NEWLINE — so the row
earned the air rule's separator AND drew its own whitespace-only line. **Two screen lines for a
row with nothing in it**, which reads as a gap in the transcript: the operator's *\"line just
disappeared lol, hole on the screen\"*.

A tab counts for the same reason a space does: it is columns nobody can read. So does a carriage
return, which a dialect may leave in a stream."
  (member ch '(#\space #\tab #\newline #\return #\page) :test #'char=))

(defun %line-blank-p (line)
  "Does LINE render as nothing — every segment's text whitespace or empty? The
question `%viewport-lines` asks of every line of every row it places, each
frame; it used to be asked through `format nil` and `string-trim`, which is two
copies per line to learn one bit.

See `%white-char-p` for why the answer is not `(char= ch #\\space)`."
  (every (lambda (seg)
           (let ((text (car seg)))
             ;; a non-string prints as its name under `~a`, which is not blank
             (and (stringp text)
                  (every #'%white-char-p text))))
         line))

(defun item-row-class (item)
  "Which KIND of row this is, for the one question the layout asks of its
neighbours: does a blank line belong between them. The reference's `RowClass`."
  (let ((body (item-body item)))
    (if (null body)
        :other
        (case (intern (string-upcase (getf body :type)) :keyword)
          ;; **A user-kind row is Speech for BOTH `operator` and an absent speaker** (the additive
          ;; rule, R42): the class is what the layout reads for *does a blank line belong between
          ;; these two*, and a row that predates the field draws exactly as it always did — block
          ;; and all. A row this session appended, and one naming a speaker this build cannot read,
          ;; is `:other`: it is not somebody in the conversation speaking, and its air says so.
          ;; letibot draws its `agent` rows as `RowClass::Other` for the same reason.
          ((:user) (let ((who (%user-speaker body)))
                     (if (or (eq who :operator) (eq who :unrecorded)) :speech :other)))
          ((:assistant) (if (plusp (length (string-trim " " (or (getf body :text) ""))))
                            :speech :activity))
          ((:reasoning :tool_result) :activity)
          (t :other)))))

