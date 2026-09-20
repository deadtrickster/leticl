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
user item by the daemon when a turn runs — never rejected (§13.2).

Paste markers are EXPANDED here, at the last moment before the text leaves: the
composer shows `[⋮ pasted 312 lines ⋮]` and the daemon receives the 312 lines.
History keeps what was typed, so an Up recalls the marker and not a wall of
text — which is what makes the ledger safe to forget about."
  (let* ((typed (composer-buffer (head-composer head)))
         (line (expand-pastes typed)))
    (composer-push-history (head-composer head) typed)
    (%undo-push (head-composer head))
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
      ;; full-body screens. `esc`/`q` closes any of them; the LIST panes also
      ;; take a cursor (up/down) and an enter, and they share ONE cursor —
      ;; `head-picker-sel` — because only one pane is open at a time, which is
      ;; the same argument the pane scroll offset makes. A per-pane cursor would
      ;; be a `head` slot each, and a struct slot is a RESTART: the one thing
      ;; this head must not need.
      ((member (head-mode head) '(:help :status :config :jobs :subagents :peek :todos :picker
                                       :mode-picker :models-picker))
       (flet ((rows () (case (head-mode head)
                         (:subagents (length (head-subagents head)))
                         (:jobs (length (head-jobs head)))
                         (:todos (length (session-todos (head-session head))))
                         (:picker (length (session-sessions (head-session head))))
                         (:mode-picker (length (setting-choices head "mode")))
                         (:models-picker (length (setting-choices head "model")))
                         (t 0)))
              (move-cursor (n)
                (setf (head-picker-sel head)
                      (max 0 (min (max 0 (1- (rows))) (+ (head-picker-sel head) n)))
                      (head-dirty head) t)
                ;; and the offset follows the cursor, so a selection is never
                ;; scrolled off the screen it is being made on
                (scroll-pane-into-view (head-picker-sel head))))
         (case type
           ((:esc :q-press) (setf (head-mode head) :normal (head-dirty head) t))
           ((:up) (move-cursor -1))
           ((:down) (move-cursor 1))
           ;; PAGE and WHEEL scroll the PANE. They used to be swallowed here,
           ;; which left a pane taller than the body with no way to see the rest
           ;; of it — and the repo's own TODO.md is 98 rows. The polarity is
           ;; `*pane-scroll*`'s, which is the OPPOSITE of the transcript's: page
           ;; DOWN moves forward through the pane.
           ((:page-down) (pane-scroll-by (max 1 (- *pane-room* 1)))
                         (setf (head-dirty head) t))
           ((:page-up) (pane-scroll-by (- (max 1 (- *pane-room* 1))))
                       (setf (head-dirty head) t))
           ((:wheel-down) (pane-scroll-by 3) (setf (head-dirty head) t))
           ((:wheel-up) (pane-scroll-by -3) (setf (head-dirty head) t))
           ((:tab)
            ;; Tab unfolds too, as the operator asked, BESIDE enter and under
            ;; enter's own condition, so the two cannot disagree about whose key
            ;; it is. On every other pane it does what enter does.
            (when (not (eq (head-mode head) :todos))
              (setf (head-dirty head) nil))
            (when (eq (head-mode head) :todos)
              (%handle-key head (list :type :enter))))
           ((:enter)
            ;; The subagent pane's enter is the one the pane already advertises:
            ;; read that subagent's scrollback without moving this session there.
            ;; It is `peek`, the command that existed as a frame nobody sent.
            (case (head-mode head)
              (:subagents
               (let ((row (nth (head-picker-sel head) (head-subagents head))))
                 (awhen (and row (getf row :session-id))
                   (%send head (make-peek it))
                   (setf (head-status-note head)
                         (format nil "peeking ~a…" it)))))
              (:todos
               ;; Enter unfolds a repo item that HAS detail — the operator asked
               ;; for this directly: *"if a todo has some associated text? should
               ;; i be able to expand it somehow?"*. Keyed by the row's TEXT, not
               ;; its index, because the file is re-read while the pane is open
               ;; and an index would then point at a different line.
               (let* ((rows (repo-todo-rows-cached
                             (getf (session-wiring (head-session head)) :workspace)))
                      (row (nth (head-picker-sel head) rows)))
                 (when (and row (getf row :body) (getf row :item))
                   (let ((text (getf row :text)))
                     (if (member text *todos-open* :test #'string=)
                         (setf *todos-open* (remove text *todos-open* :test #'string=))
                         (push text *todos-open*))
                     (setf (head-dirty head) t)))))
              (:picker
               (let ((hit (nth (head-picker-sel head)
                               (session-sessions (head-session head)))))
                 (when hit
                   (%send head (make-switch (getf hit :session-id) 0))
                   (setf (head-mode head) :normal))))
              (:mode-picker
               ;; the mode travels as its own frame with the name the daemon
               ;; listed, so the head keeps no vocabulary of its own to drift
               (let ((c (nth (head-picker-sel head) (setting-choices head "mode"))))
                 (awhen c
                   (%send head (list :frame "mode"
                                     :client-request-id (next-request-id)
                                     :expected-seq (session-expected-seq (head-session head))
                                     :name it))
                   (say head (format nil "mode → ~a" it))
                   (setf (head-mode head) :normal))))
              (:models-picker
               ;; /models is a daemon-side verb: the head sends the line it would
               ;; have typed, which is how `slash` frames work
               (let ((c (nth (head-picker-sel head) (setting-choices head "model"))))
                 (awhen c
                   (%send head (list :frame "slash"
                                     :client-request-id (next-request-id)
                                     :expected-seq (session-expected-seq (head-session head))
                                     :line (format nil "models ~a" it)))
                   (say head (format nil "model → ~a" it))
                   (setf (head-mode head) :normal)))))
            (setf (head-dirty head) t))
           ((:char) (when (eql (getf key :ch) #\q)
                      (setf (head-mode head) :normal (head-dirty head) t)))
           (t nil))))
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
      ((:char)
       ;; one undo snapshot per word: push when the character before the cursor
       ;; ends a word, so ctrl-z takes back a word rather than a letter
       (let ((before (composer-buffer c))
             (i (composer-cursor c)))
         (when (or (zerop i)
                   (let ((prev (char before (1- i))))
                     (and (or (char= prev #\space) (char= prev #\newline))
                          (not (char= (getf key :ch) #\space))
                          (not (char= (getf key :ch) #\newline)))))
           (%undo-push c)))
       (composer-insert c (string (getf key :ch)))
       (setf (head-dirty head) t))
      ((:paste)
       (%undo-push c)
       (composer-insert-paste c (getf key :text))
       (setf (head-dirty head) t))
      ((:backspace) (composer-delete-backward c) (setf (head-dirty head) t))
      ((:delete) (composer-delete-forward c) (setf (head-dirty head) t))
      ((:enter) (%submit-line head))
      ((:tab) (%complete head))
      ((:left :right :home :end) (composer-move c type) (setf (head-dirty head) t))
      ((:up) (composer-history-step c -1) (setf (head-dirty head) t))
      ((:down) (composer-history-step c 1) (setf (head-dirty head) t))
      ((:alt)
       ;; alt+enter is a newline inside the prompt. Any other alt chord is not
       ;; the composer's, and must not become text — an unhandled chord that
       ;; inserts its own letter is how a prompt grows a stray `x`.
       (when (and (getf key :ch) (char= (getf key :ch) #\return))
         (%undo-push c)
         (composer-insert c (string #\newline))
         (setf (head-dirty head) t)))
      ((:esc)
       ;; `esc esc` interrupts — twice within the gesture window. A single esc
       ;; does nothing yet; it MAY become "return to the following the stream",
       ;; and the double tap has to be decided first or the two fight.
       (let ((now (get-internal-real-time))
             (ms (/ internal-time-units-per-second 1000.0)))
         (if (and *esc-at* (< (- now *esc-at*) (* *esc-double-ms* ms)))
             (progn (setf *esc-at* nil)
                    (when (and (session-turn (head-session head))
                               (string= (turn-state-name (session-turn (head-session head)))
                                        "running"))
                      (%interrupt head "interrupted with esc esc")))
             (setf *esc-at* now))))
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
              (progn (%undo-push c) (composer-kill-line c)
                     (setf (head-dirty head) t))))
         ((#\k) (%undo-push c) (composer-kill-to-end c) (setf (head-dirty head) t))
         ((#\w) (%undo-push c) (composer-kill-word c) (setf (head-dirty head) t))
         ((#\y) (when (composer-yank c) (setf (head-dirty head) t)))
         ((#\z) (when (composer-undo c) (setf (head-dirty head) t)))
         ((#\a) (composer-move c :home) (setf (head-dirty head) t))
         ((#\e) (composer-move c :end) (setf (head-dirty head) t))
         ((#\l) (setf (head-full-repaint head) t (head-dirty head) t))
         ;; ---- the chords the reference has and this head did not (S9) ----
         ;;
         ;; Bound HERE rather than in a table, because the ladder above is the
         ;; one place a key's owner is decided, and a chord bound to a feature
         ;; that does not exist is worse than no chord — which is why they landed
         ;; after the features.
         ((#\r) (%flip-fold head :show-reasoning))          ; fold the thinking
         ((#\t) (%flip-fold head :show-tools))              ; fold tool output
         ((#\o) (%command head "promote"))                  ; promote the command
         ((#\s) (%command head "sessions"))                 ; the session list
         ((#\p) (%command head "todos"))                    ; the todos pane
         ((#\g) (%command head "subagents"))                ; the subagent tree
         ((#\q) (%command head "jobs"))                     ; the jobs pane
         ((#\x)
          ;; raw `<function=…>` markup, which is NOT a fold: a fold hides
          ;; something the reader knows is there, while this reveals markup the
          ;; default view is required never to show. Off by default and behind a
          ;; chord, both halves of what was asked for.
          (setf (getf (head-prefs head) :raw-calls)
                (not (getf (head-prefs head) :raw-calls))
                (head-dirty head) t)))
       ;; a ctrl chord that means nothing here must not become text
       )
      (t nil))))

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
  "Ctrl+K: cut from the cursor to the end, into the kill ring."
  (composer-kill-region c (composer-cursor c) (length (composer-buffer c))))

(defun composer-kill-line (c)
  "Ctrl+U: cut from the start to the cursor, into the kill ring."
  (composer-kill-region c 0 (composer-cursor c)))

(defun composer-kill-word (c)
  "Ctrl+W: cut back to the start of the word before the cursor, into the ring."
  (let ((i (composer-cursor c))
        (buf (composer-buffer c)))
    (loop while (and (plusp i) (char= (char buf (1- i)) #\space)) do (decf i))
    (loop while (and (plusp i) (char/= (char buf (1- i)) #\space)) do (decf i))
    (composer-kill-region c i (composer-cursor c))))

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



;;; ------------------------------------------------------------------ S4 ;;;
;;;
;;; The editor's windows, and every one of them is a GLOBAL rather than a
;;; `composer` slot. A defstruct layout change is a hard error in this SBCL, so a
;;; slot would mean a restart — the one thing a live head must not need. There is
;;; one composer per process, so a defvar each costs nothing and pushes.

(defvar *kill-ring* nil
  "Killed text, newest first. `ctrl-y` yanks the head of it.

A ring rather than a single slot: `ctrl-k` then some editing then `ctrl-y` is
the common shape, and a single slot loses the first kill the moment you make a
second one.")
(defparameter *kill-ring-max* 16
  "How many kills to keep. A ring nobody can exhaust is a leak.")

(defvar *undo-stack* nil
  "Snapshots of the composer buffer, newest first, for `ctrl-z`.

Snapshots rather than an operation log: a buffer is a string and a string is
cheap, while replaying operations has to get every one of them right. Batched at
WORD granularity by the caller, so `ctrl-z` undoes a word rather than a
character — a per-character undo makes you hold the key and hope.")
(defparameter *undo-max* 400
  "How many snapshots to keep before dropping the oldest.")

(defvar *paste-ledger* nil
  "Alist of MARKER → the text that marker stands for.

A paste of five lines or more collapses to a marker in the composer and the full
text is remembered here, then SUBSTITUTED BACK on submit. The point is that a
three-thousand-line paste is one visible token while you are typing and still
arrives whole — the operator sees a marker, the model receives the paste.")

(defvar *esc-at* nil
  "When the last bare ESC arrived, for the double-tap interrupt.

Kept next to the key handler rather than in the head, because it is about the
KEY STREAM and not about the session.")
(defparameter *esc-double-ms* 5000
  "How long a second `esc` still counts as the same gesture. The reference's
number: a double tap is one intent, and five seconds is the width of a hesitation
rather than a second thought.")

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
rather than trying to decide how much to take back."
  (when *undo-stack*
    (composer-buffer-set c (pop *undo-stack*))
    t))

(defun composer-kill-region (c start end)
  "Cut [START, END) into the kill ring, newest first."
  (let ((buf (composer-buffer c)))
    (when (< start end)
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

(defun %paste-marker (n)
  (format nil "[⋮ pasted ~a lines ⋮]" n))

(defun composer-insert-paste (c text)
  "Insert TEXT, or a marker standing for it when it is five lines or more.

A three-thousand-line paste as three thousand lines of composer is a buffer
nobody can see the end of; as a marker it is one visible token that still sends
whole. The marker is opaque and the ledger holds the text, so nothing is lost by
rounding."
  (if (< (%paste-lines text) 5)
      (progn (composer-insert c text) nil)
      (let ((marker (%paste-marker (%paste-lines text))))
        (push (cons marker text) *paste-ledger*)
        (composer-insert c marker)
        marker)))

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
