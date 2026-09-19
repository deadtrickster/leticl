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
    ("mode" . "NAME — move this session's project to a mode")
    ("jobs" . "the background-jobs pane")
    ("subagents" . "the subagent tree")
    ("cells" . "MESSAGE — send it with a copy of this screen")
    ("todos" . "the model's plan, and the repo's TODO.md — ask, then open it")
    ("peek" . "SESSION-ID — read a subagent's output without leaving this session")
    ("resync" . "throw this head's state away and take a fresh snapshot")
    ("resume" . "SESSION-ID — bring a stored session back to life")
    ("compact" . "summarise this session and fork it")
    ("reseat" . "rebuild the prompt from the tools seated now")
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
      ((string= verb "config")
       ;; Ask, and open the pane. The REPLY does not open it (a head asks for
       ;; settings on attach now, and a reply that opened the pane would pop
       ;; `/config` at every attach), so the command owns both halves.
       (%send head (make-settings))
       (setf (head-mode head) :config (head-dirty head) t))
      ((string= verb "mode")
       (if (plusp (length rest))
           (%send head (list :frame "mode"
                             :client-request-id (next-request-id)
                             :expected-seq (session-expected-seq (head-session head))
                             :name rest))
           (setf (head-status-note head) "usage: /mode NAME" (head-dirty head) t)))
      ((string= verb "jobs") (setf (head-mode head) :jobs (head-dirty head) t))
      ((string= verb "subagents") (setf (head-mode head) :subagents (head-dirty head) t))
      ((string= verb "todos")
       ;; Ask for the list AND open the pane. The session's plan is carried by
       ;; `todos_updated` events, so a head that attached after the model wrote
       ;; them has none — the bootstrap read is what makes the pane honest about
       ;; a plan written before this head existed.
       (%send head (make-list-todos))
       (setf (head-mode head) :todos (head-dirty head) t))
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


