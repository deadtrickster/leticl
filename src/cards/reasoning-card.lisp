;;;; reasoning-card.lisp — the model's WORKING-OUT: the folded header, the rail, and
;;;; the count of screen lines it costs.

(in-package #:leticl)

(defclass reasoning-card (card) ())

(defmethod card-indent ((card reasoning-card) cols)
  (activity-indent cols))


(defparameter +reasoning-lines-budget+ 8
  "The reference's `Budget::reasoning_lines`, the same bound for a reasoning block.")

(defun reasoning-line-count (text width)
  "How many SCREEN lines TEXT costs at WIDTH — the reference's count, and the only one used.

Extracted from `reasoning-header` when R37's marker needed the same number: the marker says *43
thinking lines* and a header beside it says *43 lines*, and two pieces of arithmetic for one
quantity is how they come to disagree. The model writes its working-out as a handful of very long
paragraphs, so *lines* means what the terminal will spend, not how many newlines are in the text."
  (max 1 (reduce #'+ (mapcar (lambda (l) (max 1 (ceiling (string-width l) (max 1 width))))
                             (uiop:split-string (or text "") :separator '(#\newline)))
                 :initial-value 0)))

(defun reasoning-header (text cols open running)
  "`▸ Thought · 13 lines · ctrl-r` — the fold's own header, which is also where
its key is advertised: there is no pointer here and no selection, so the header
naming its chord is the whole discoverability mechanism.

The count is SCREEN lines, not source lines, as the reference counts them: the
model writes its working-out as a handful of very long paragraphs, so \"3 lines\"
beside a fold that opens to half a screen answers the wrong question. And the
mark is PLAIN, not dim — measured against letibot's row, where only the tail after
the word is faint."
  (let* ((w (max 20 (- cols (activity-indent cols))))
         (n (reasoning-line-count text w)))
    (%truncate-segs
     (list (cons (if open "▾ " "▸ ") nil)
           (if running
               (cons "Thinking…" '(:dim t :italic t))
               (cons "Thought" '(:bold t)))
           (cons (format nil " · ~d line~:p · ctrl-r" n) '(:dim t)))
     w)))

(defun reasoning-lines (text cols prefs &key running)
  "A reasoning block: the header, and — open — its body under the `┃ ` rail, in
the dim-italic register, rendered as markdown two columns narrower than the row so
the wrap and the rail agree. Folded, the header alone."
  (let ((open (getf prefs :show-reasoning)))
    (cons (reasoning-header text cols open running)
          (when open
            (mapcar (lambda (l)
                      (cons (cons "┃ " '(:dim t))
                            (mapcar (lambda (seg)
                                      (cons (car seg)
                                            (if (cdr seg)
                                                (append (cdr seg) '(:dim t :italic t))
                                                '(:dim t :italic t))))
                                    l)))
                    (markdown-lines text :width (max 20 (- cols (activity-indent cols) 2))
                                         :limit +reasoning-lines-budget+))))))


(defmethod card-lines ((card reasoning-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    ;; **The model's working-out, so it can never be mistaken for its
    ;; answer.** Three signals, because any one is lost somewhere: the WORD
    ;; (`Thought`), the RAIL (`┃`, two columns), and the dim-italic
    ;; attribute — de-emphasis by COLOUR alone is a no-op under a
    ;; terminal-native palette, so the attribute is what carries it.
    ;;
    ;; Folded by default, like a card and like letibot: `▸ Thought · 20
    ;; lines · ctrl-r`. A settled row is by definition not running, so the
    ;; word is `Thought`; `Thinking…` belongs to the live turn.
    (reasoning-lines (getf body :text) cols prefs :running nil))
  )


