;;;; protocol.lisp — the head frame vocabulary, protocol version 18.
;;;; Source of truth: crates/sessionlog/src/protocol.rs. Frames are plists in
;;;; the image (PLAN.md §7, D4); the constructors below are the only place
;;;; that knows what a frame looks like on the wire.
;;;;
;;;; The rules inherited with the shape (protocol.rs, top of file):
;;;; 1. Ack.seq comes from the batch, not from the kept events.
;;;; 2. Fields whose presence is the disclosure (dropped, created) are always
;;;;    written, present and zero/null rather than omitted.
;;;; 3. Every mutating command carries client_request_id and expected_seq.

(in-package #:leticl)

(defparameter +protocol-version+ 21)
;; 21 added ListJobs (a read-only frame answered at once, not through the command
;; queue: `/job` during a long turn used to arrive after the turn ended, which is
;; useless for a pane that opens).
;; 19 added WithdrawPrompts (a queued prompt can be taken back into the
;; composer; consecutive queued messages merge daemon-side), 20 added Stop
;; (the head asks whether the daemon goes too, instead of a second terminal
;; and letibot --stop). Both are client frames, hence the ATTACH-time refusal
;; that told us about the bump in the first place.

;;; Why a Rejected was sent — stable codes a head branches on (protocol.rs).
(defparameter +reject-stale-seq+ "stale expected_seq")
(defparameter +reject-unknown-decision+ "no such open decision")
(defparameter +reject-read-only+ "this head declared can_decide: false")
(defparameter +reject-unknown-session+ "no such session")
(defparameter +reject-not-in-store+ "no such session in the store")

;;; The note on a prompt/compact accepted behind a running turn.
(defparameter +note-prompt-queued+ "queued as a user item")
(defparameter +note-compact-queued+ "queued after the running turn")

;; defvar: a monotonic counter a live push must not rewind, or request ids
;; could repeat on a socket that is already open.
(defvar *request-counter* 0)

(defun next-request-id ()
  "Unique per head connection is all the daemon needs; monotonic across a
Switch, which reuses the socket (protocol.rs on ClientFrame::Switch)."
  (format nil "leticl-~d" (incf *request-counter*)))

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

;;; ---------------------------------------------------------- constructors ;;;
;;; Field order follows protocol.rs so a diff against the Rust reads naturally.
;;; Keys whose value is nil are omitted by the caller's choice here — serde
;;; defaults them daemon-side — except where presence itself is the disclosure.

(defun make-attach (&key (session-id "") (since-seq 0) (kind "tui") identity
                      (queue 1024) (can-decide t) features)
  (list :frame "attach"
        :protocol-version +protocol-version+
        :session-id session-id
        :since-seq since-seq
        :kind kind
        :identity (or identity "")
        :caps (append (list :queue queue :can-decide can-decide)
                      (when features (list :features features)))))

(defun make-ack (seq rendered filtered)
  "The read mark. seq is the last seq CONSUMED from the batch, rendered or
not — there is deliberately no other way to obtain one (protocol.rs on Ack)."
  (list :frame "ack" :seq seq :rendered rendered :filtered filtered))

(defun make-resync ()
  (list :frame "resync"))

(defun make-prompt (expected-seq text)
  (list :frame "prompt"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :text text))

(defun make-interrupt (expected-seq reason)
  (list :frame "interrupt"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :reason reason))

(defun make-withdraw-prompts (expected-seq)
  "Take back what this head queued — the original leaves the daemon's queue so
the operator can edit it rather than stack under it (protocol.rs, v19)."
  (list :frame "withdraw_prompts"
        :client-request-id (next-request-id)
        :expected-seq expected-seq))

(defun make-stop (expected-seq who)
  "Stop the daemon, not just this head — one shutdown sequence, every head
wakes with Closed (protocol.rs, v20)."
  (list :frame "stop"
        :client-request-id (next-request-id)
        :expected-seq expected-seq
        :who who))

(defun make-answer (req-id option-id &optional pattern note)
  "Grant or deny a permission, by option id.

PATTERN is the operator's own glob, for always-allow only. NOTE is what they
want the MODEL told, for `deny_and_tell` only. Each is ignored on every other
option rather than quietly widening one: a glob on an `allow_once` would be a
grant nobody named, and a note on one would be a sentence nobody reads, which is
worse than dropping it.

Both are ADDED, DEFAULTED fields on an existing frame, so an older daemon ignores
them and answers as it did before (protocol.rs on `pattern` and `note`)."
  (append (list :frame "answer"
                :client-request-id (next-request-id)
                :req-id req-id
                :option-id option-id)
          (when pattern (list :pattern pattern))
          (when note (list :note note))))

(defun make-answer-question (req-id answer)
  "ANSWER is the QuestionAnswer payload: a choice, a note, a typed reply, or a
choice and a note together. There is no variant for \"not now\" — deferring is
not sending (protocol.rs on ClientFrame::AnswerQuestion)."
  (list :frame "answer_question"
        :client-request-id (next-request-id)
        :req-id req-id
        :answer answer))

(defun make-list-sessions ()
  (list :frame "list_sessions"))

(defun make-list-todos ()
  (list :frame "list_todos"))

(defun make-list-jobs ()
  "This session's background jobs, answered IMMEDIATELY.

Deliberately not a `slash` line: those ride the command queue and are answered
between turns, so `/job` during a long turn arrived after it had finished — which
is useless for a pane that opens. Added at protocol 21, which is why the daemon
refused us with `bye` until this head learned to say 21 too."
  (list :frame "list_jobs"))

(defun make-new-session (title workspace)
  (list :frame "new_session"
        :client-request-id (next-request-id)
        :title (or title "")
        :workspace (or workspace "")))

(defun make-resume-session (session-id)
  (list :frame "resume_session"
        :client-request-id (next-request-id)
        :session-id session-id))

(defun make-rename-session (session-id title)
  (list :frame "rename_session"
        :client-request-id (next-request-id)
        :session-id session-id
        :title (or title "")))

(defun make-switch (session-id since-seq)
  "Move this connection to another session, same socket, answered with a
second Hello."
  (list :frame "switch" :session-id session-id :since-seq since-seq))

(defun make-peek (session-id)
  (list :frame "peek" :session-id session-id))

(defun make-settings ()
  (list :frame "settings"))

(defun make-detach ()
  "A clean goodbye. Not required: close is detach too, and detach is never
abort (protocol.rs on ClientFrame::Detach)."
  (list :frame "detach"))

;;; The one frame only a head can answer: its own screen, as it drew it
;;; (protocol.rs on ClientFrame::Screen). ROWS is one string per row, escapes
;;; included, at the head's real size.
(defun make-screen-answer (req-id rows)
  (list :frame "screen"
        :req-id req-id
        :cols (length (first rows))
        :rows-n (length rows)
        :rows rows))
