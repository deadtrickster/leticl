;;;; chrome.lisp — the frame furniture: the top border, the status line, and
;;;; the composer's line.
;;;;
;;;; This is the strip the operator looks at while typing. It draws no
;;;; transcript and reads only `head` state, so it can be restyled without
;;;; touching a single row renderer.

(in-package #:leticl)

;;; --------------------------------------------------------------- chrome ;;;
(defun %model-from-settings ()
  "The live `model` setting, when the head has asked for the rows (§7.4).

Reads the GLOBAL head, so it must only be called from a context where `*head*`
is bound — which the paint is, and which a test of the render is not. Callers
that may be outside the head pass nil for the rows; see `%model-name`."
  (let ((settings (and *head* (head-settings *head*))))
    (and settings
         (let ((row (find "model" settings
                          :key (lambda (r) (getf r :key)) :test #'string=)))
           (and row (let ((v (getf row :value)))
                      (and (stringp v) (plusp (length v)) v)))))))

(defun %model-name (s)
  "The model this session is ACTUALLY on, best known first.

The wiring's model arrives on `Hello` and never changes; the turn's arrives on
`TurnStarted` and is the truth while (and after) a turn runs. Reading only the
wiring is what put `qwen-3.8-27b` on the header of a session running
`deepseek/deepseek-flash` — a number on screen that was wrong, which is the
defect class this head exists against.

Once the settings rows land (§7.4) the live `model` row is the third and best
source; until then the turn is the newest thing we have.

`SettingRow` carries the flag's own name in `key` and its rendered value in
`value` (protocol.rs:214) — `row(\"model\", …)` is emitted by the daemon
(config.rs:825), and `mode` beside it."
  (or (%model-from-settings)
      (let ((turn-model (getf (session-turn s) :model)))
        (and (stringp turn-model) (plusp (length turn-model)) turn-model))
      (let ((wire (getf (session-wiring s) :model)))
        (and (stringp wire) wire))
      ""))

(defun top-border (head cols)
  (let* ((s (head-session head))
         (title (if (plusp (length (session-title s)))
                    (session-title s) (session-session-id s)))
         (model (%model-name s))
         (left (format nil " leticl · ~a~@[ · ~a~] " title
                       (and (plusp (length model)) model)))
         (right (format nil "seq ~a · ~d heads "
                        (session-seq s) (length (session-heads s))))
         (pad (max 0 (- cols (string-width left) (string-width right)))))
    (list (cons left '(:bold t :fg :cyan))
          (cons (make-string pad :initial-element #\─) '(:fg :bright-black))
          (cons right '(:fg :bright-black)))))

(defun status-line (head cols)
  (let* ((conn (if (head-connected head) "" " · DISCONNECTED — retrying"))
         (scroll (if (plusp (head-scroll head))
                     (format nil " · ↑~a" (head-scroll head)) ""))
         (queued (if (head-queued head)
                     (format nil " · ~d queued" (length (head-queued head))) ""))
         (text (format nil " ~a~a~a~a"
                       (or (head-status-note head) "") conn scroll queued))
         (style (if (head-connected head) '(:fg :bright-black) '(:fg :red :bold t))))
    (list (cons (if (> (string-width text) cols)
                    (subseq text 0 cols) text)
                style)
          (cons (make-string (max 0 (- cols (min cols (string-width text))))
                             :initial-element #\─)
                '(:fg :bright-black)))))

(defun composer-line (head cols)
  (let* ((c (head-composer head))
         (buf (composer-buffer c))
         (prefix "› ")
         (visible (if (> (+ (string-width prefix) (string-width buf)) cols)
                      ;; keep the cursor end visible: show the tail
                      (subseq buf (max 0 (- (length buf)
                                            (- cols (length prefix)))))
                      buf)))
    (list (cons prefix '(:fg :bright-cyan :bold t))
          (cons visible nil))))


