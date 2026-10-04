;;;; decoding — decoding a frame
;;;;
;;;; Split out of `protocol.lisp`, which was one 783-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------------------------- decoding ;;;

(defun decode-frame (line)
  "One wire line to a plist. Malformed JSON raises wire-error with the line
kept, per wire.rs — a decoder that reports \"bad frame\" without the frame
turns a precise complaint into a shrug."
  (handler-case (json-decode line)
    (error (e) (error 'wire-error :line line :detail (format nil "~a" e)))))

(defun encode-frame (frame)
  (json-encode-to-string frame))

(defun frame-name (frame) (getf frame :frame))
(defun event-name (event)
  "The event tag as a keyword. The wire sends it as a snake_case string
(event.rs:380, #[serde(tag = \"event\", rename_all = \"snake_case\")]) and the
matchers in apply-event and %handle-frame speak keywords — \"turn_started\"
must become :turn-started or no case arm ever matches and every live event is
silently dropped (measured: seq climbed, nothing rendered, prompts stuck
queued)."
  (let ((s (getf event :event)))
    (and s (%key-from-wire s))))

