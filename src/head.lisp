;;;; head.lisp — the running head: threads, the paint-on-dirty loop, key
;;;; ownership, slash commands, cards, the picker, reconnect.
;;;;
;;;; Key ownership has the Rust head's fixed precedence, gated on an empty
;;;; composer so a half-typed line always means the line (agents.md): the
;;;; decision ladder, then the picker, then other cards/panes, then the
;;;; composer. The loop paints only when dirty and acks after painting, never
;;;; on receipt (cursor.rs).

(in-package #:leticl)

;; the reader interns sb-concurrency symbols in the defstruct below, so the
;; module must be present at compile time, not just at load
(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-concurrency))

(defparameter *head* nil
  "The running head — the root a hack-socket eval reaches.")

(defstruct (head (:constructor %make-head))
  (session (make-session))
  (stream nil)
  (cols 80 :type fixnum)
  (rows 24 :type fixnum)
  (screen (make-screen 80 24))
  (prev-screen (make-screen 80 24))
  (dirty t :type boolean)
  (full-repaint t :type boolean)
  (last-rows nil)                        ; strings with ANSI — Screen answers, /cells
  (last-cols 0 :type fixnum)
  (last-rows-n 0 :type fixnum)
  (scroll 0 :type fixnum)
  (composer (make-composer))
  (mode :normal :type symbol)            ; :normal :picker :help :status :config :jobs :subagents :peek
  (picker-sel 0 :type fixnum)
  (decision-sel 0 :type fixnum)
  (secret-req nil)
  (secret-buf "" :type string)
  (peeked nil)
  (settings nil)
  (jobs nil)
  (subagents nil)
  (prefs (list :show-reasoning t :show-tools t))
  (status-note nil)
  (queued nil :type list)                ; prompts sent, user row not yet seen
  (connected nil :type boolean)
  (frames (sb-concurrency:make-mailbox :name "leticl frames"))
  (keys (sb-concurrency:make-mailbox :name "leticl keys"))
  (reader nil) (input nil) (hack-listener nil) (hack-thread nil)
  (hack-path nil)
  (running t :type boolean)
  (last-reconnect 0 :type fixnum)
  (socket-path nil)
  (quit-open nil :type boolean)
  (quit-sel 0 :type fixnum))

;;; ---------------------------------------------------------------- io ;;;

(defun %send (head frame)
  "Main thread only — the writer is single-threaded by construction."
  (when (and (head-stream head) (head-connected head))
    (handler-case
        (write-frame (encode-frame frame) (head-stream head))
      (error (e)
        (setf (head-connected head) nil
              (head-status-note head) (format nil "send failed: ~a" e))))))

(defun %reader-loop (head)
  "Socket → frames mailbox. EOF is detach, never abort (§13.2)."
  (loop
    (handler-case
        (multiple-value-bind (line eof) (read-frame (head-stream head))
          (cond (eof
                 (sb-concurrency:send-message (head-frames head) '(:disconnected))
                 (return))
                (t
                 (handler-case
                     (sb-concurrency:send-message (head-frames head)
                                                  (decode-frame line))
                   (wire-error (e)
                     (sb-concurrency:send-message
                      (head-frames head)
                      (list :frame "warning" :code "malformed-frame"
                            :detail (format nil "~a" e))))))))
      (error (e)
        (sb-concurrency:send-message (head-frames head) '(:disconnected))
        (sb-concurrency:send-message
         (head-frames head)
         (list :frame "warning" :code "read-error" :detail (format nil "~a" e)))
        (return)))))

(defun %input-loop (head)
  "Terminal → keys mailbox."
  (let ((in (sb-sys:make-fd-stream 0 :input t :element-type 'character
                                   :external-format :utf-8 :buffering :none)))
    (loop
      (let ((key (read-key in)))
        (sb-concurrency:send-message (head-keys head) key)
        (when (eq (getf key :type) :eof) (return))))))

;;; ------------------------------------------------------------ frames ;;;

(defun %handle-frame (head frame)
  (cond
    ((and (consp frame) (eq (car frame) :disconnected))
     (setf (head-connected head) nil
           (head-status-note head) "detached — reconnecting…"
           (head-dirty head) t))
    ((and (consp frame) (string= (frame-name frame) "warning")
          (getf frame :code) (member (getf frame :code)
                                     '("malformed-frame" "read-error")
                                     :test #'string=))
     ;; our own transport warnings, not session events
     (setf (head-status-note head)
           (format nil "~a: ~a" (getf frame :code) (getf frame :detail))
           (head-dirty head) t))
    ((string= (frame-name frame) "hello")
     (ingest-hello (head-session head) frame)
     (setf (head-connected head) t
           (head-status-note head) nil
           (head-full-repaint head) t
           (head-dirty head) t))
    ((string= (frame-name frame) "event")
     (let* ((env frame)
            (name (event-name env)))
       ;; the two events a head answers rather than renders
       (case name
         ((:screen-requested)
          (%send head (make-screen-answer (getf env :req-id)
                                          (or (head-last-rows head)
                                              (list "")))))
         ((:secret-requested)
          (setf (head-secret-req head) env
                (head-secret-buf head) ""
                (head-dirty head) t))
         (t))
       (when (eq (apply-event (head-session head) env) :dirty)
         (setf (head-dirty head) t))
       ;; a queued prompt's row has landed: stop announcing it (app.rs:3018)
       (when (and (eq name :transcript-appended)
                  (string= (getf env :kind) "user")
                  (head-queued head))
         (pop (head-queued head))
         (setf (head-dirty head) t))))
    ((string= (frame-name frame) "resync")
     (ingest-snapshot (head-session head) (getf frame :snapshot))
     (setf (head-full-repaint head) t
           (head-dirty head) t
           (head-status-note head) (format nil "resync: ~a" (getf frame :reason))))
    ((string= (frame-name frame) "accepted")
     (setf (head-status-note head) (getf frame :note)
           (head-dirty head) t))
    ((string= (frame-name frame) "rejected")
     (setf (head-status-note head)
           (format nil "rejected: ~a (expected seq ~a, daemon at ~a)"
                   (getf frame :reason) (getf frame :expected-seq)
                   (getf frame :actual-seq))
           (head-dirty head) t))
    ((string= (frame-name frame) "sessions")
     (setf (session-sessions (head-session head)) (getf frame :sessions)
           (head-picker-sel head) 0
           (head-dirty head) t))
    ((string= (frame-name frame) "todos")
     (setf (session-todos (head-session head)) (getf frame :todos)
           (head-dirty head) t))
    ((string= (frame-name frame) "settings")
     (setf (head-settings head) (getf frame :rows)
           (head-mode head) :config
           (head-dirty head) t))
    ((string= (frame-name frame) "peeked")
     (setf (head-peeked head) (getf frame :events)
           (head-mode head) :peek
           (head-dirty head) t))
    ((string= (frame-name frame) "bye")
     (setf (head-connected head) nil
           (head-status-note head) (format nil "bye: ~a" (getf frame :reason))
           (head-dirty head) t))
    (t nil)))

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

(defun %prompt (head text)
  (push text (head-queued head))
  (%send head (make-prompt (session-expected-seq (head-session head)) text)))

(defun %command (head line)
  "One verb per slash command; anything the head does not handle goes to the
daemon as the line the operator typed, without the leading slash (protocol.rs
on ClientFrame::Slash)."
  (let* ((space (position #\space line))
         (verb (string-downcase (if space (subseq line 0 space) line)))
         (rest (if space (string-trim " " (subseq line (1+ space))) "")))
    (cond
      ((string= verb "cells") (%cells head rest))
      ((string= verb "new") (%send head (make-new-session rest "")))
      ((string= verb "sessions")
       (%send head (make-list-sessions))
       (setf (head-mode head) :picker (head-dirty head) t))
      ((string= verb "switch")
       (%send head (make-switch rest 0))
       (setf (head-mode head) :normal))
      ((string= verb "rename")
       (%send head (make-rename-session (session-session-id (head-session head)) rest)))
      ((string= verb "help") (setf (head-mode head) :help (head-dirty head) t))
      ((string= verb "status") (setf (head-mode head) :status (head-dirty head) t))
      ((string= verb "think")
       (setf (getf (head-prefs head) :show-reasoning)
             (not (getf (head-prefs head) :show-reasoning))
             (head-dirty head) t))
      ((string= verb "tools")
       (setf (getf (head-prefs head) :show-tools)
             (not (getf (head-prefs head) :show-tools))
             (head-dirty head) t))
      ((string= verb "config") (%send head (make-settings)))
      ((string= verb "mode")
       (if (plusp (length rest))
           (%send head (list :frame "mode"
                             :client-request-id (next-request-id)
                             :expected-seq (session-expected-seq (head-session head))
                             :name rest))
           (setf (head-status-note head) "usage: /mode NAME" (head-dirty head) t)))
      ((string= verb "jobs") (setf (head-mode head) :jobs (head-dirty head) t))
      ((string= verb "subagents") (setf (head-mode head) :subagents (head-dirty head) t))
      ((string= verb "compact")
       (%send head (list :frame "compact_session"
                         :client-request-id (next-request-id)
                         :expected-seq (session-expected-seq (head-session head)))))
      ((string= verb "reseat")
       (%send head (list :frame "reseat_session"
                         :client-request-id (next-request-id)
                         :expected-seq (session-expected-seq (head-session head)))))
      ((string= verb "interrupt") (%interrupt head "interrupted from the head"))
      ((string= verb "quit") (setf (head-running head) nil))
      ;; unknown verbs travel; the daemon acts and announces on the log
      (t (%send head (list :frame "slash"
                           :client-request-id (next-request-id)
                           :expected-seq (session-expected-seq (head-session head))
                           :line line))))))

(defun %interrupt (head reason)
  (%send head (make-interrupt (session-expected-seq (head-session head)) reason)))

(defun %cells (head message)
  "The operator pointing: the message, and this screen exactly as drawn —
ANSI included, delimited so both readers find the edges (app.rs:2977)."
  (if (or (zerop (head-last-cols head)) (zerop (head-last-rows-n head)))
      (setf (head-status-note head)
            "nothing has been drawn on this head yet — no cells to send"
            (head-dirty head) t)
      (let* ((w (head-last-cols head))
             (h (head-last-rows-n head))
             (text (format nil "~a~a~a~dx~d — my terminal exactly as this head drew it, ANSI escape codes included, so what you are reading IS the rendering and not a description of it~a~%~{~a~%~}~a~%"
                           message
                           (if (plusp (length message)) "

" "")
                           *cells-open* w h *cells-mark-end*
                           (head-last-rows head)
                           *cells-close*)))
        (%prompt head text))))

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
      ((member (head-mode head) '(:help :status :config :jobs :subagents :peek))
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

;;; ------------------------------------------------------------ rendering ;;;

(defun %viewport-lines (head cols want)
  "The conversation's last WANT lines (scrolled up by head-scroll), as
segment lines oldest-first. Collection stops once enough exist — a delta
per token must not re-render the whole history."
  (let* ((s (head-session head))
         (nf nil)                              ; newest first
         (need (+ (head-scroll head) want)))
    (setf nf (reverse (turn-lines (session-turn s) cols (head-prefs head))))
    (loop for i from (1- (length (session-items s))) downto 0
          while (< (length nf) need)
          do (let ((il (item-lines (aref (session-items s) i) cols (head-prefs head))))
               (setf nf (append (reverse il) nf))))
    (let* ((n (length nf))
           (start (max 0 (min n (head-scroll head))))
           (end (max start (min n (+ start want)))))
      (reverse (subseq nf start end)))))

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
        ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :picker))
         (let ((lines (case (head-mode head)
                        (:help (help-lines cols))
                        (:status (status-screen-lines head cols))
                        (:config (config-lines (head-settings head) cols))
                        (:jobs (jobs-lines head cols))
                        (:subagents (subagent-lines head cols))
                        (:peek (peek-lines head cols))
                        (:picker (picker-lines (head-session head)
                                               (head-picker-sel head) cols)))))
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
  (if (head-full-repaint head)
      (progn (paint-full (head-screen head) *stdout*)
             (setf (head-full-repaint head) nil))
      (paint-diff (head-prev-screen head) (head-screen head) *stdout*))
  ;; keep the previous frame for the next diff, and the rows for Screen//cells
  (replace (screen-cells (head-prev-screen head)) (screen-cells (head-screen head)))
  (setf (head-last-rows head) (screen-rows-ansi (head-screen head))
        (head-last-cols head) (head-cols head)
        (head-last-rows-n head) (head-rows head))
  ;; the cursor belongs at the end of the line being typed
  (let ((c (head-composer head))
        (buf (composer-buffer c)))
    (move-to *stdout* (1- (head-rows head))
             (min (1- (head-cols head))
                  (+ 2 (string-width
                        (if (> (+ 2 (string-width buf)) (1- (head-cols head)))
                            (subseq buf (max 0 (- (length buf)
                                                  (- (1- (head-cols head)) 2))))
                            buf))))))
  (setf (head-dirty head) nil))

(defun %poll-resize (head)
  (multiple-value-bind (cols rows) (terminal-size 1)
    (when (or (/= cols (head-cols head)) (/= rows (head-rows head)))
      (setf (head-cols head) cols (head-rows head) rows)
      (screen-resize (head-screen head) cols rows)
      (screen-resize (head-prev-screen head) cols rows)
      (setf (head-full-repaint head) t
            (head-dirty head) t))))

;;; ------------------------------------------------------------- the loop ;;;

(defun %drain (mailbox)
  (sb-concurrency:receive-pending-messages mailbox))

(defun %try-reconnect (head)
  "Detach is not abort; a dead socket is retried with the seq we had, which
is a resume — the gap arrives as events, or a Resync does (§13.2)."
  (let ((now (get-universal-time)))
    (when (> now (+ (head-last-reconnect head) 2))
      (setf (head-last-reconnect head) now)
      (handler-case
          (progn
            (ignore-errors (close (head-stream head)))
            (let ((stream (connect-unix (head-socket-path head))))
              (setf (head-stream head) stream)
              (%send head (make-attach
                           :session-id (session-session-id (head-session head))
                           :since-seq (session-seq (head-session head))
                           :identity "leticl"))
              (setf (head-connected head) t)))
        (error (e)
          (setf (head-status-note head) (format nil "reconnect: ~a" e)))))))

(defun run-loop (head)
  (loop while (head-running head)
        do (dolist (frame (%drain (head-frames head)))
             (%handle-frame head frame))
           (dolist (key (%drain (head-keys head)))
             (%handle-key head key))
           (%poll-resize head)
           (unless (head-connected head)
             (%try-reconnect head))
           (if (head-dirty head)
               (%render-and-paint head)
               (sleep 0.03))))

;;; ------------------------------------------------------------- lifecycle ;;;

(defparameter *stdout* nil)

(defun run (&key socket-path session-id)
  "Attach to a daemon and run until /quit or ctrl+d."
  (unless *stdout*
    (setf *stdout* (sb-sys:make-fd-stream 1 :output t :element-type 'character
                                          :external-format :utf-8 :buffering :none)))
  (unless (plusp (%isatty 1))
    (error "the head paints on the real terminal — run it on a tty, not a pipe"))
  (let* ((path (or socket-path
                   (getf (first (discover-daemons)) :socket)
                   (error "no daemon found — start one or pass :socket-path")))
         (head (%make-head))
         (stream (connect-unix path)))
    (setf *head* head
          (head-stream head) stream
          (head-socket-path head) path
          (head-cols head) (nth-value 0 (terminal-size 1))
          (head-rows head) (nth-value 1 (terminal-size 1)))
    (screen-resize (head-screen head) (head-cols head) (head-rows head))
    (screen-resize (head-prev-screen head) (head-cols head) (head-rows head))
    ;; ATTACH is the first frame on every connection (server.rs:205); an empty
    ;; session id means "the daemon's current session" (registry.rs:600)
    (%send head (make-attach :session-id (or session-id "")
                             :identity "leticl"))
    (hack-start head)
    (setf (head-reader head)
          (sb-thread:make-thread (lambda () (%reader-loop head)) :name "leticl reader")
          (head-input head)
          (sb-thread:make-thread (lambda () (%input-loop head)) :name "leticl input"))
    (with-tui-terminal (*stdout*)
      (unwind-protect
           (run-loop head)
        (ignore-errors (%send head (make-detach)))
        (hack-stop head)))
    (ignore-errors (close stream))))
