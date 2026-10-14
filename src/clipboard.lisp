;;;; **The clipboard: what OSC 52 carries, and the verb that puts something there.**
;;;;
;;;; The row this exists for says the rule in one line — *`/copy` takes the open window else the last
;;;; reply* — and the escape is the terminal's own: `ESC ] 52 ; c ; <base64> ESC \`. **The head already
;;;; writes an OSC** (`\x1b]22;pointer`, the hand pointer), so this is the same shape rather than new
;;;; machinery; what was missing is the ENCODER, and the verb.

(in-package #:leticl)

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  "The standard alphabet, in the standard order. Written out rather than computed, because the ORDER is
the format and a table built by arithmetic would be a second statement of it.")

(defun %base64 (string)
  "STRING's UTF-8 bytes, base64 — what an OSC 52 payload is.

**UTF-8 BYTES AND NOT CHARACTER CODES**, which is the whole reason this is a function rather than a loop
over characters: a transcript is full of characters outside ASCII, and `(char-code #\\é)` is 233, whose
base64 is a different byte than the two the terminal will decode. `string-to-octets` is SBCL's and it is
the same encoder the rest of this head's output goes through.

**Padding is `=`, and it is not optional**: a decoder reads three-byte groups and a payload whose length
is not a multiple of three is truncated without it — the last characters of a copied answer, quietly."
  (let* ((bytes (sb-ext:string-to-octets string :external-format :utf-8))
         (n (length bytes))
         (out (make-string-output-stream)))
    (loop for i from 0 below n by 3
          for b0 = (aref bytes i)
          for b1 = (and (< (+ i 1) n) (aref bytes (+ i 1)))
          for b2 = (and (< (+ i 2) n) (aref bytes (+ i 2)))
          for word = (+ (ash b0 16) (ash (or b1 0) 8) (or b2 0))
          do (write-char (char +base64-alphabet+ (ldb (byte 6 18) word)) out)
             (write-char (char +base64-alphabet+ (ldb (byte 6 12) word)) out)
             (write-char (if b1 (char +base64-alphabet+ (ldb (byte 6 6) word)) #\=) out)
             (write-char (if b2 (char +base64-alphabet+ (ldb (byte 6 0) word)) #\=) out))
    (get-output-stream-string out)))

(defun %segs-text (lines)
  "SEGMENT LINES as plain text — each line's segments joined, one line per line.

 The inverse of what the painter does, and it drops the STYLES on purpose: a clipboard carries characters,
 and an answer pasted into a document with escape codes in it is worse than one with none."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (line)
                    (format nil "~{~a~}" (mapcar (lambda (seg) (if (consp seg) (car seg) seg)) line)))
                  lines)))

(defun %copy-text (head)
  "What `/copy` takes — the OPEN WINDOW if one is up, else the last reply (letibot's rule).

 **THE WINDOW WINS WHEN IT IS OPEN**, because an open window is the thing the reader is looking at: they
 opened a diff, a note or a run to read it, and `/copy` beside it means *copy THAT*. NIL when there is
 neither — a head with nothing to copy says so rather than putting an empty string on the clipboard."
  (or (let ((over (and (read-overlay-open-p head) (read-overlay-lines head (head-cols head)))))
        (and over (%segs-text (pane-view over))))
      (let ((items (session-items (head-session head))))
        (loop for i from (1- (length items)) downto 0
              for it = (aref items i)
              when (equal (or (item-kind it) "") "assistant")
                return (let ((text (item-display-text it)))
                         (and text (plusp (length text)) text))))))

(defun copy-command (head rest)
  "`/copy` — the open window, else the last reply, onto the terminal's clipboard. T when it was taken.

 **The reader is TOLD either way**: a copy that said nothing is a copy you cannot tell from a key that did
 not register, and the sentence names WHICH thing went — the window or the reply — because the two are
 different things to have on a clipboard."
  (declare (ignore rest))
  (let ((text (%copy-text head)))
    (say head (if text
                  (progn (copy-to-clipboard text)
                         (format nil "copied ~d characters~@[ (the open window)~]"
                                 (length text)
                                 (and (read-overlay-open-p head) t)))
                  "nothing to copy — no window is open and this session has no reply yet"))
    t))

(defun copy-to-clipboard (text)
  "TEXT onto the terminal's clipboard, through OSC 52 — T when it was written.

**IT GOES STRAIGHT AT THE STREAM, BESIDE THE POINTER'S SHAPE**, and for that shape's reason: it is not a
frame and it must not wait for one. `%open-stdout` is the same door the painter uses (it reacquires the
stream if a live push clobbered it), and the flush is OURS — a clipboard write that sat in a buffer until
the next repaint would be a copy that worked only if the screen happened to move.

**A terminal that does not speak OSC 52 ignores the bytes**, which is why this answers T rather than
claiming the clipboard is set: the head cannot see the clipboard, and the reference says the same thing
in the same breath about the pointer."
  (let ((out (ignore-errors (%open-stdout))))
    (when out
      (write-string (format nil "~C]52;c;~a~C\\" +esc+ (%base64 text) +esc+) out)
      (finish-output out)
      t)))
