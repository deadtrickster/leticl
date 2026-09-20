;;;; commands.lisp — the command surface: the registry, the senders, and /cells.
;;;;
;;;; `*slash-commands*` is the one list the help screen, tab completion and the
;;;; dispatcher all read, so the three cannot drift apart. The frames here are
;;;; the ones a person or a model asks for by name; anything this file does not
;;;; know travels to the daemon as a `slash` frame.

(in-package #:leticl)

;;; /cells delimiters — copied from app.rs:868 so a leticl screen folds out of
;;; a Rust transcript and vice versa. They live beside `%cells`, the command
;;; that writes them, so the pair cannot drift; `%fold-cells` (cards.lisp) is
;;; the reader that folds them back out, and it loads after this file.
(defparameter *cells-open* (format nil "⟦screen "))

(defparameter *cells-mark-end* "⟧")

(defparameter *cells-close* "⟦end screen⟧")


(defparameter *slash-commands*
  '(("new" . "TITLE — start a fresh session")
    ("sessions" . "the session picker")
    ("switch" . "ID — go to another session")
    ("rename" . "NAME — name the session you are in")
    ("help" . "the key and command reference")
    ("status" . "telemetry, full screen")
    ("think" . "fold or unfold the model's reasoning")
    ("tools" . "fold or unfold tool output")
    ("config" . "every setting, as the daemon reports it")
    ("mode" . "the mode picker — or /mode NAME to type it")
    ("models" . "which model answers: the picker, or /models PROVIDER/MODEL")
    ("jobs" . "the background-jobs pane")
    ("subagents" . "the subagent tree")
    ("cells" . "MESSAGE — send it with a copy of this screen")
    ("todos" . "the model's plan, and the repo's TODO.md — ask, then open it")
    ("peek" . "SESSION-ID — read a subagent's output without leaving this session")
    ("resync" . "throw this head's state away and take a fresh snapshot")
    ("resume" . "SESSION-ID — bring a stored session back to life")
    ("compact" . "summarise this session and fork it")
    ("reseat" . "rebuild the prompt from the tools seated now")
    ("promote" . "move the RUNNING COMMAND to the background (ctrl-o)")
    ("interrupt" . "stop the running turn")
    ("quit" . "leave the head")))

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
       (%open-pane head :picker))
      ((string= verb "switch")
       (%send head (make-switch rest 0))
       (setf (head-mode head) :normal))
      ((string= verb "rename")
       (%send head (make-rename-session (session-session-id (head-session head)) rest)))
      ;; the reference's short forms, for the fingers that learnt them there
      ((member verb '("help" "h" "?") :test #'string=)
       (%open-pane head :help))
      ((member verb '("status" "stats") :test #'string=)
       (%open-pane head :status))
      ((member verb '("think" "r") :test #'string=)
       (%flip-fold head :show-reasoning))
      ;; `/t` folds tool output; `/tools` ASKS what this conversation can call —
      ;; the reference moved it off the fold (*"i think i want it to show me
      ;; currently seated tools"*), and the listing comes back on the session log
      ((string= verb "t")
       (%flip-fold head :show-tools))
      ((member verb '("verbosity" "v") :test #'string=)
       (setf *verbosity* (next-verbosity *verbosity*))
       (say head (format nil "verbosity ~(~a~) — ~d events filtered so far"
                         *verbosity* *filtered-total*)))
      ((member verb '("config" "settings") :test #'string=)
       ;; Ask, and open the pane. The REPLY does not open it (a head asks for
       ;; settings on attach now, and a reply that opened the pane would pop
       ;; `/config` at every attach), so the command owns both halves.
       (%send head (make-settings))
       (%open-pane head :config))
      ((string= verb "mode")
       (if (plusp (length rest))
           (%send head (list :frame "mode"
                             :client-request-id (next-request-id)
                             :expected-seq (session-expected-seq (head-session head))
                             :name rest))
           ;; with no name, OPEN THE PICKER rather than printing a list to copy a
           ;; name out of. The reference made the same change: *"for starters i
           ;; want it to be usual menu, like /mode"* — the wall of text was the
           ;; least visible part of the thing anybody types it for.
           (progn
             ;; make sure the rows are here: the picker's list IS the daemon's
             ;; choices, and a head that never asked has none to show
             (unless (head-settings head) (%send head (make-settings)))
             (setf (head-mode head) :mode-picker
                   (head-picker-sel head) 0)
             (reset-pane-scroll)
             (setf (head-dirty head) t))))
      ((or (string= verb "models") (string= verb "model"))
       ;; `/models` with no name opens the picker; with a name it is the daemon's
       ;; verb and travels as the line the operator would have typed
       (if (plusp (length rest))
           (%send head (list :frame "slash"
                             :client-request-id (next-request-id)
                             :expected-seq (session-expected-seq (head-session head))
                             :line (format nil "models ~a" rest)))
           (progn
             (unless (head-settings head) (%send head (make-settings)))
             (setf (head-mode head) :models-picker
                   (head-picker-sel head) 0)
             (reset-pane-scroll)
             (setf (head-dirty head) t))))
      ((string= verb "jobs")
       ;; ASK, then open. The jobs pane drew `N out` from JobSettled events, which
       ;; a head that attached after the jobs started never saw — so the pane was
       ;; empty for exactly the case it exists for. `ListJobs` is answered at once
       ;; (protocol 21, deliberately not a Slash: those ride the command queue and
       ;; are answered between turns, so `/job` during a long turn arrived after
       ;; it had finished).
       (%send head (make-list-jobs))
       (%open-pane head :jobs))
      ((string= verb "subagents") (%open-pane head :subagents))
      ((string= verb "todos")
       ;; Ask for the list AND open the pane. The session's plan is carried by
       ;; `todos_updated` events, so a head that attached after the model wrote
       ;; them has none — the bootstrap read is what makes the pane honest about
       ;; a plan written before this head existed.
       (%send head (make-list-todos))
       (%open-pane head :todos))
      ((string= verb "peek")
       ;; One subagent's output without leaving this session: the daemon answers
       ;; with `Peeked`, and `%handle-frame` opens the pane from that. The screen
       ;; existed and was unreachable — nothing sent the frame that fills it.
       (if (plusp (length rest))
           (%send head (make-peek rest))
           (setf (head-status-note head) "usage: /peek SESSION-ID" (head-dirty head) t)))
      ((string= verb "resync")
       ;; Throw this head's state away and take a fresh snapshot. The frame was
       ;; written in T9 and never sent, so the only resync this head ever saw was
       ;; one the DAEMON initiated — which is the case that works and therefore
       ;; the case that proves nothing.
       (%send head (make-resync)))
      ((string= verb "resume")
       ;; Bring a session that is in the store but not in this daemon back to
       ;; life. The daemon answers on the same `Sessions` reply a `/new` produces,
       ;; so the picker's switch machinery is what lands it.
       (if (plusp (length rest))
           (%send head (make-resume-session rest))
           (setf (head-status-note head) "usage: /resume SESSION-ID" (head-dirty head) t)))
      ((string= verb "compact")
       (%send head (list :frame "compact_session"
                         :client-request-id (next-request-id)
                         :expected-seq (session-expected-seq (head-session head)))))
      ((string= verb "reseat")
       (%send head (list :frame "reseat_session"
                         :client-request-id (next-request-id)
                         :expected-seq (session-expected-seq (head-session head)))))
      ((string= verb "promote")
       ;; Move the running COMMAND to the background. The fact to guard is a
       ;; command running, and the daemon honours this inside bash's own wait
       ;; loop — so a call still executing is not a proxy for the thing being
       ;; promoted, it IS it. Between turns the daemon announces idle, so this
       ;; says what it can see rather than guessing.
       (let ((call (find-if (lambda (c) (string= (getf (getf c :state) :state) "running"))
                            (getf (session-turn (head-session head)) :calls))))
         (if call
             (progn
               (%send head (list :frame "promote"
                                 :client-request-id (next-request-id)
                                 :expected-seq (session-expected-seq (head-session head))))
               (say head (format nil "moving ~a to the background" (getf call :name))))
             ;; TWO different silences, and saying the same thing for both sends
             ;; the operator looking for a command that was never started
             (say head (if (and (session-turn (head-session head))
                                (string= (turn-state-name (session-turn (head-session head)))
                                         "running"))
                           "the model is still working — no command running to move yet"
                           "nothing is running to move to the background")))))
      ((string= verb "interrupt") (%interrupt head "interrupted from the head"))
      ((member verb '("quit" "q") :test #'string=) (setf (head-running head) nil))
      ;; unknown verbs travel; the daemon acts and announces on the log
      (t (%send head (list :frame "slash"
                           :client-request-id (next-request-id)
                           :expected-seq (session-expected-seq (head-session head))
                           :line line))))))

(defun %open-pane (head mode)
  "Open the full-body screen MODE with its cursor at the top and nothing scrolled.

The panes share ONE cursor (`head-picker-sel`) and one scroll offset, because only
one is open at a time — so a position left by the last pane means nothing to the
next, and opening on it put the todos cursor three items down because the picker
had been there. The reference keeps a cursor per pane; with one, the top is the
only honest place to start."
  (setf (head-mode head) mode
        (head-picker-sel head) 0
        (head-dirty head) t)
  (reset-pane-scroll))

(defun %send-slash (head line)
  "LINE as a `slash` frame — the line the operator would have typed, minus the
slash, which is how a daemon-side verb travels (`Action::Slash`). One place, so the
request id and the expected seq are filled the same way by every caller."
  (%send head (list :frame "slash"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :line line)))

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


