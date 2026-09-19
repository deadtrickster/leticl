;;;; editor.lisp — the input surface: the composer and the key ladder.
;;;;
;;;; The composer (cursor, history, kills) and the precedence ladder that decides
;;;; who a key belongs to. The ladder has the Rust head's fixed precedence, gated
;;;; on an empty composer so a half-typed line always means the line (agents.md):
;;;; the decision ladder, then the picker, then other cards and panes, then the
;;;; composer.
;;;;
;;;; The terminal DECODER is not here — that is `keys.lisp`, the port of
;;;; term.rs's tables. This file receives decoded key plists.

(in-package #:leticl)

;;; ------------------------------------------------------------- keys ;;;
(defun %open-decision (head)
  (first (session-open-decisions (head-session head))))

(defun %answer-decision (head index)
  (let ((d (%open-decision head)))
    (when d
      (let* ((question (string= (getf d :kind) "question"))
             (options (if question (getf d :choices) (getf d :options)))
             (idx (min index (1- (max 1 (length options))))))
        (if question
            (%send head (make-answer-question (getf d :req-id)
                                              (list :option idx)))
            (let ((option-id (getf (nth idx options) :option-id)))
              (%send head (make-answer (getf d :req-id)
                                       (or option-id (format nil "~d" idx))))))
        (setf (head-decision-sel head) 0
              (head-dirty head) t)))))

(defun %submit-line (head)
  "Enter on the composer: a slash command, or a prompt. Queued as a follow-up
user item by the daemon when a turn runs — never rejected (§13.2)."
  (let ((line (composer-buffer (head-composer head))))
    (composer-push-history (head-composer head) line)
    (setf (composer-buffer (head-composer head)) ""
          (composer-cursor (head-composer head)) 0)
    (cond
      ((zerop (length line)))
      ((char= (char line 0) #\/) (%command head (subseq line 1)))
      (t (%prompt head line)))
    (setf (head-dirty head) t)))

(defun %complete (head)
  "Tab: complete a slash command prefix; unique completion inserts, ambiguous
shows the candidates on the status line."
  (let* ((buf (composer-buffer (head-composer head))))
    (when (uiop:string-prefix-p "/" buf)
      (let* ((prefix (subseq buf 1))
             (hits (remove-if-not (lambda (c) (uiop:string-prefix-p prefix (car c)))
                                  *slash-commands*)))
        (cond ((= (length hits) 1)
               (let ((full (format nil "/~a " (car (first hits)))))
                 (setf (composer-buffer (head-composer head)) full
                       (composer-cursor (head-composer head)) (length full)
                       (head-status-note head) nil)))
              ((> (length hits) 1)
               (setf (head-status-note head)
                     (format nil "~{/~a~^ ~}" (mapcar #'car hits)))))
        (setf (head-dirty head) t)))))

(defun %handle-key (head key)
  (let ((type (getf key :type)))
    (cond
      ((eq type :eof) (setf (head-running head) nil))
      ;; the secret card owns everything while it is up: a password field is
      ;; not a composer and must never leak into one
      ((head-secret-req head)
       (case type
         ((:char :paste) (setf (head-secret-buf head)
                               (concatenate 'string (head-secret-buf head)
                                            (or (getf key :ch)
                                                (getf key :text) ""))))
         ((:backspace) (setf (head-secret-buf head)
                             (subseq (head-secret-buf head)
                                     0 (max 0 (1- (length (head-secret-buf head)))))))
         ((:enter)
          (%send head (list :frame "secret"
                            :req-id (getf (head-secret-req head) :req-id)
                            :secret (head-secret-buf head)))
          (setf (head-secret-req head) nil (head-secret-buf head) ""))
         ((:esc)
          (%send head (list :frame "secret"
                            :req-id (getf (head-secret-req head) :req-id)
                            :secret nil))
          (setf (head-secret-req head) nil)))
       (setf (head-dirty head) t))
      ;; the quit card: leave, or leave and stop the daemon (v20)
      ((head-quit-open head)
       (case type
         ((:up) (setf (head-quit-sel head) 0 (head-dirty head) t))
         ((:down) (setf (head-quit-sel head) 1 (head-dirty head) t))
         ((:enter)
          (if (zerop (head-quit-sel head))
              (setf (head-running head) nil)
              (progn
                ;; the answer that stops the daemon travels over the protocol,
                ;; not around it to a pid (protocol.rs, v20)
                (%send head (make-stop (session-expected-seq (head-session head))
                                       "leticl"))
                (setf (head-running head) nil))))
         ((:esc) (setf (head-quit-open head) nil (head-dirty head) t))
         (t nil)))
      ;; full-body screens: esc closes, everything else is theirs later
      ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :todos))
       (case type
         ((:esc :q-press) (setf (head-mode head) :normal (head-dirty head) t))
         ((:char) (when (eql (getf key :ch) #\q)
                    (setf (head-mode head) :normal (head-dirty head) t)))
         (t nil)))
      ((eq (head-mode head) :picker)
       (case type
         ((:esc) (setf (head-mode head) :normal (head-dirty head) t))
         ((:up) (setf (head-picker-sel head)
                      (max 0 (1- (head-picker-sel head)))
                      (head-dirty head) t))
         ((:down) (setf (head-picker-sel head)
                        (min (max 0 (1- (length (session-sessions (head-session head)))))
                             (1+ (head-picker-sel head)))
                        (head-dirty head) t))
         ((:enter)
          (let ((hit (nth (head-picker-sel head)
                          (session-sessions (head-session head)))))
            (when hit
              (%send head (make-switch (getf hit :session-id) 0))
              (setf (head-mode head) :normal (head-dirty head) t))))
         (t nil)))
      ;; :normal — the precedence ladder, gated on an empty composer
      (t
       (let ((composer-empty (zerop (length (composer-buffer (head-composer head)))))
             (decision (%open-decision head)))
         (cond
           ;; the decision ladder first — but a half-typed line always means the line
           ((and decision composer-empty)
            (case type
              ((:up) (setf (head-decision-sel head)
                           (max 0 (1- (head-decision-sel head)))
                           (head-dirty head) t))
              ((:down) (setf (head-decision-sel head)
                             (min (1- (max 1 (length (if (string= (getf decision :kind) "question")
                                                         (getf decision :choices)
                                                         (getf decision :options)))))
                                  (1+ (head-decision-sel head)))
                             (head-dirty head) t))
              ((:enter) (%answer-decision head (head-decision-sel head)))
              ((:char)
               (let ((digit (digit-char-p (getf key :ch))))
                 (when digit (%answer-decision head (1- digit)))))
              (t (%normal-key head key))))
           (t (%normal-key head key))))))))

(defun %normal-key (head key)
  (let ((c (head-composer head)))
    (case (getf key :type)
      ((:char) (composer-insert c (string (getf key :ch)))
               (setf (head-dirty head) t))
      ((:paste) (composer-insert c (getf key :text)) (setf (head-dirty head) t))
      ((:backspace) (composer-delete-backward c) (setf (head-dirty head) t))
      ((:delete) (composer-delete-forward c) (setf (head-dirty head) t))
      ((:enter) (%submit-line head))
      ((:tab) (%complete head))
      ((:left :right :home :end) (composer-move c type) (setf (head-dirty head) t))
      ((:up) (composer-history-step c -1) (setf (head-dirty head) t))
      ((:down) (composer-history-step c 1) (setf (head-dirty head) t))
      ((:page-up) (incf (head-scroll head) (max 1 (- (head-rows head) 3)))
                  (setf (head-dirty head) t))
      ((:page-down) (setf (head-scroll head) (max 0 (- (head-scroll head)
                                                       (max 1 (- (head-rows head) 3)))))
                    (setf (head-dirty head) t))
      ((:wheel-up) (incf (head-scroll head) 3) (setf (head-dirty head) t))
      ((:wheel-down) (setf (head-scroll head) (max 0 (- (head-scroll head) 3)))
                     (setf (head-dirty head) t))
      ((:ctrl)
       (case (getf key :ch)
         ((#\c)
          ;; ctrl+c asks, it no longer assumes (protocol.rs, v20): a running
          ;; turn is interrupted, an idle head opens the quit card, and a
          ;; second ctrl+c while the card is up leaves
          (cond ((head-quit-open head)
                 (setf (head-running head) nil))
                ((and (session-turn (head-session head))
                      (string= (turn-state-name (session-turn (head-session head)))
                               "running"))
                 (%interrupt head "interrupted with ctrl+c"))
                (t (setf (head-quit-open head) t
                         (head-quit-sel head) 0
                         (head-dirty head) t))))
         ((#\d) (setf (head-running head) nil))
         ((#\u)
          ;; an empty composer plus a queued prompt: take it back (v19)
          (if (and (zerop (length (composer-buffer c))) (head-queued head))
              (let ((text (first (last (head-queued head)))))
                (%send head (make-withdraw-prompts
                             (session-expected-seq (head-session head))))
                (setf (head-queued head)
                      (butlast (head-queued head)))
                (composer-insert c (or text ""))
                (setf (head-dirty head) t))
              (progn (composer-kill-line c) (setf (head-dirty head) t))))
         ((#\k) (composer-kill-to-end c) (setf (head-dirty head) t))
         ((#\w) (composer-kill-word c) (setf (head-dirty head) t))
         ((#\a) (composer-move c :home) (setf (head-dirty head) t))
         ((#\e) (composer-move c :end) (setf (head-dirty head) t))
         ((#\l) (setf (head-full-repaint head) t (head-dirty head) t)))
       ;; a ctrl chord that means nothing here must not become text
       )
      ((:esc) nil)
      (t nil))))

;;; ------------------------------------------------------------ composer ;;;
(defstruct (composer (:constructor make-composer ()))
  (buffer "" :type string)
  (cursor 0 :type fixnum)
  (history (make-array 0 :adjustable t :fill-pointer 0) :type vector)
  (hist-pos 0 :type fixnum))

(defun composer-insert (c string)
  (setf (composer-buffer c)
        (concatenate 'string
                     (subseq (composer-buffer c) 0 (composer-cursor c))
                     string
                     (subseq (composer-buffer c) (composer-cursor c))))
  (incf (composer-cursor c) (length string)))

(defun composer-delete-backward (c)
  (when (plusp (composer-cursor c))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (1- (composer-cursor c)))
                       (subseq (composer-buffer c) (composer-cursor c))))
    (decf (composer-cursor c))))

(defun composer-delete-forward (c)
  (when (< (composer-cursor c) (length (composer-buffer c)))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (composer-cursor c))
                       (subseq (composer-buffer c) (1+ (composer-cursor c)))))))

(defun composer-move (c key)
  (case key
    (:left (setf (composer-cursor c) (max 0 (1- (composer-cursor c)))))
    (:right (setf (composer-cursor c) (min (length (composer-buffer c))
                                           (1+ (composer-cursor c)))))
    (:home (setf (composer-cursor c) 0))
    (:end (setf (composer-cursor c) (length (composer-buffer c))))))

(defun composer-kill-to-end (c)
  (setf (composer-buffer c) (subseq (composer-buffer c) 0 (composer-cursor c))))

(defun composer-kill-line (c)
  (setf (composer-buffer c) (subseq (composer-buffer c) (composer-cursor c))
        (composer-cursor c) 0))

(defun composer-kill-word (c)
  "Ctrl+W: back to the start of the word before the cursor."
  (let ((i (composer-cursor c))
        (buf (composer-buffer c)))
    (loop while (and (plusp i) (char= (char buf (1- i)) #\space)) do (decf i))
    (loop while (and (plusp i) (char/= (char buf (1- i)) #\space)) do (decf i))
    (setf (composer-buffer c) (concatenate 'string (subseq buf 0 i) (subseq buf (composer-cursor c)))
          (composer-cursor c) i)))

(defun composer-push-history (c line)
  (vector-push-extend line (composer-history c))
  (setf (composer-hist-pos c) (length (composer-history c))))

(defun composer-history-step (c delta)
  "Up/Down through sent lines. The in-progress line is kept at position
`length`, so leaving history restores what was half-typed."
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
      (setf (composer-cursor c) (length (composer-buffer c))))))


