;;;; render.lisp — the frame engine: state to cells, and the paint.
;;;;
;;;; The segment and line machinery (`wrap-segments`, `put-segments`) and the
;;;; viewport and frame composition (`%viewport-lines`, `%render`,
;;;; `%place-lines`, `%render-and-paint`). What each part of the frame looks
;;;; like lives beside this file: transcript rows in `cards.lisp`, the frame
;;;; furniture in `chrome.lisp`, the full-body screens in `panes.lisp`.
;;;;
;;;; Everything here is a plain function so a model can redefine any layer of
;;;; it live (PLAN.md §1).

(in-package #:leticl)

;;; ------------------------------------------------------------- wrapping ;;;
(defun %split-words (text)
  "Word chunks with their trailing spaces attached, so re-joining preserves
spacing exactly."
  (let ((out nil)
        (buf (make-string-output-stream)))
    (loop for ch across text
          do (progn (write-char ch buf)
                    (when (char= ch #\space)
                      (push (get-output-stream-string buf) out))))
    (push (get-output-stream-string buf) out)
    (nreverse (remove "" out :test #'string=))))

(defun %hard-break (word cols)
  "One over-wide word to cols-sized chunks — a 400-column URL wraps, it does
not overflow (width.rs's third mistake)."
  (let ((out nil))
    (loop for i from 0 below (length word) by (max 1 cols)
          do (push (subseq word i (min (length word) (+ i (max 1 cols)))) out))
    (nreverse out)))

(defun wrap-segments (segs cols)
  "Segments to lines of at most COLS columns. Style carries onto continuation
lines; each returned line is independently paintable."
  (if (<= cols 0)
      (list segs)
      (let ((lines nil)
            (cur nil)
            (w 0))
        (flet ((break-line ()
                 (when cur (push (nreverse cur) lines))
                 (setf cur nil w 0)))
          (dolist (seg segs)
            (dolist (word (%split-words (car seg)))
              (let ((ww (string-width word)))
                (cond
                  ((> ww cols)
                   (break-line)
                   (let ((chunks (%hard-break word cols)))
                     (dolist (c chunks)
                       (push (cons c (cdr seg)) cur))
                     (break-line)))
                  ((<= (+ w ww) cols)
                   (push (cons word (cdr seg)) cur)
                   (incf w ww))
                  (t
                   (break-line)
                   (push (cons word (cdr seg)) cur)
                   (setf w ww))))))
          (break-line))
        (nreverse lines))))

(defun put-segments (screen row col segs)
  "One segment line to the buffer; returns the column after it."
  (let ((c col))
    (dolist (seg segs c)
      (setf c (screen-put-string screen row c (car seg) (style-index (cdr seg)))))))

(defun put-wrapped (screen row col segs cols)
  "Wrapped segments starting at row; returns the next row."
  (let ((r row))
    (dolist (line (wrap-segments segs cols) r)
      (put-segments screen r col line)
      (incf r))))

;;; ------------------------------------------------------------ rendering ;;;
(defun %viewport-lines (head cols want)
  "The conversation's last WANT lines (scrolled up by head-scroll), as
segment lines oldest-first. The running turn is the newest thing there is, so
its lines go at the END, after every committed row: reasoning, then the answer,
then the calls — the bottom of the screen, just above the composer. (Building
newest-first and reversing the slice put the live turn at the TOP of the
viewport, above the user prompt it answers — measured on the operator's
terminal: the newest content sat at row 1 and the oldest at row 57.)"
  (let* ((s (head-session head))
         (need (+ (head-scroll head) want))
         (all (turn-lines (session-turn s) cols (head-prefs head))))
    ;; prepend committed rows, newest first, until enough lines exist; the
    ;; accumulator stays oldest-first because each older row goes in front
    (loop for i from (1- (length (session-items s))) downto 0
          while (< (length all) need)
          do (let ((il (item-lines (aref (session-items s) i) cols (head-prefs head))))
               (setf all (append il all))))
    (let* ((n (length all))
           (end (max 0 (- n (head-scroll head))))
           (start (max 0 (- end want))))
      (subseq all start end))))

(defun %render (head)
  "State to the cell buffer."
  (let* ((s (head-screen head))
         (cols (head-cols head))
         (rows (head-rows head))
         (body-top 1)
         (body-bottom (- rows 3))            ; top border, status, composer
         (card-lines nil))
    (screen-clear s)
    ;; top border
    (put-segments s 0 0 (top-border head cols))
    ;; the ask card rides at the front of the chrome, transcript visible above
    (cond ((head-secret-req head)
           (setf card-lines (secret-card-lines head cols)))
          ((%open-decision head)
           (setf card-lines (decision-card-lines head cols))))
    (let ((card-rows (length card-lines)))
      (cond
        ;; full-body screens replace the transcript
        ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :picker :todos))
         (let ((lines (case (head-mode head)
                        (:help (help-lines cols))
                        (:status (status-screen-lines head cols))
                        (:config (config-lines (head-settings head) cols))
                        (:jobs (jobs-lines head cols))
                        (:subagents (subagent-lines head cols))
                        (:peek (peek-lines head cols))
                        (:picker (picker-lines (head-session head)
                                               (head-picker-sel head) cols))
                        (:todos (todos-lines head cols)))))
           (%place-lines s lines body-top body-bottom cols)))
        (t
         ;; transcript viewport, then the card just above the status line
         (let* ((card-lines (if (head-quit-open head)
                                (quit-card-lines head cols)
                                card-lines))
                (want (max 1 (- body-bottom body-top (if card-lines (+ 2 card-rows) 0))))
                (lines (%viewport-lines head cols want)))
           (%place-lines s lines body-top (+ body-top (length lines) -1) cols)
           (when card-lines
             (%place-lines s card-lines (- body-bottom card-rows -1) body-bottom cols))))))
    ;; status + composer
    (put-segments s (- rows 2) 0 (status-line head cols))
    (put-segments s (1- rows) 0 (composer-line head cols))))

(defun %place-lines (screen lines top bottom cols)
  "Segment lines into rows top..bottom, clipping both ends."
  (let ((r top))
    (dolist (line lines)
      (when (> r bottom) (return))
      (put-segments screen r 0 line)
      (incf r))))

(defun %render-and-paint (head)
  (%render head)
  ;; reacquire the stream if a live push clobbered it: a frame written to NIL
  ;; is a type error in the main thread, which quits the head with no log
  (let ((out (%open-stdout)))
    (if (head-full-repaint head)
        (progn (paint-full (head-screen head) out)
               (setf (head-full-repaint head) nil))
        (paint-diff (head-prev-screen head) (head-screen head) out))
    ;; keep the previous frame for the next diff, and the rows for Screen//cells
    (replace (screen-cells (head-prev-screen head)) (screen-cells (head-screen head)))
    (setf (head-last-rows head) (screen-rows-ansi (head-screen head))
          (head-last-cols head) (head-cols head)
          (head-last-rows-n head) (head-rows head))
    ;; the cursor belongs at the end of the line being typed
    (let* ((c (head-composer head))
           (buf (composer-buffer c)))
      (move-to out (1- (head-rows head))
               (min (1- (head-cols head))
                    (+ 2 (string-width
                          (if (> (+ 2 (string-width buf)) (1- (head-cols head)))
                              (subseq buf (max 0 (- (length buf)
                                                    (- (1- (head-cols head)) 2))))
                              buf)))))))
  (setf (head-dirty head) nil))


