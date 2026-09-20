;;;; replay.lisp — render a recorded event log. No daemon, no socket, no model.
;;;;
;;;; This is the instrument a 1:1 rendering claim needs, and it is the
;;;; reference's own (`crates/tui/src/bin/letibot-tui.rs`, `fn replay`, line
;;;; 236). Until it existed the only way to compare the two heads was to look at
;;;; two LIVE heads — two processes, two scroll positions, two fold states, two
;;;; clocks — and one comparison in the last round was invalid for exactly that
;;;; reason: the panes were at different scroll offsets, so rows that matched
;;;; were compared against rows that were not on the other screen at all.
;;;;
;;;; A replay removes every one of those variables. The input is a file, the
;;;; size is a number, and the answer is bytes.
;;;;
;;;; Two modes, matching the reference:
;;;;
;;;;   --replay FILE.jsonl            fold, paint, poll keys, 8 ms between
;;;;                                  envelopes, then the live loop until quit —
;;;;                                  a head you can drive in tmux with no daemon
;;;;   --replay FILE.jsonl --no-tty   fold everything, print the screen at a
;;;;                                  FIXED size, exit
;;;;
;;;; The second is the one the comparison uses, and it has one requirement the
;;;; first does not: **same file in, same bytes out**. Two things in this head
;;;; read a wall clock while folding — the turn's start time (`*turn-started-ms*`,
;;;; session.lisp:321) and a call's start/end (`note-call-started`) — and both
;;;; would put a different number on the screen on every run. So `--no-tty` binds
;;;; `*fixed-clock-ms*` to 0 for the whole fold and the whole frame, which is
;;;; also what the reference's `--no-tty` has: its `now_ms` is never set, and its
;;;; `started_ms` comes off the envelope's own `ts`, so its duration is
;;;; `0.saturating_sub(ts)` = 0 every time.
;;;;
;;;; Everything else a replay shows is a function of the file: the prefs are read
;;;; the way the reference reads them (`app.load_prefs()`, app.rs:6373), so the
;;;; prefs file is an INPUT to both heads and the comparison holds it fixed by
;;;; using the same one for both.
;;;;
;;;; This file is last in the system so it may name every global the frame reads
;;;; — a `let` over a symbol that is not yet special is a lexical binding, and
;;;; the reset below would then silently do nothing.

(in-package #:leticl)

(defun replay-envelopes-from-lines (lines)
  "Decode LINES (strings) into envelope plists, in order.

Blank lines are skipped and a line that will not decode is DROPPED, which is the
reference's own behaviour — `filter_map(|l| serde_json::from_str(&l).ok())`,
letibot-tui.rs:258. Worth knowing when a fixture looks short: a field name the
Rust does not recognise is not an error over there, it is a missing line, and
that is how a `turn_finished` with the wrong `usage` keys came to leave the
composer's edge saying `Responding` on a turn that had ended."
  (loop for line in lines
        for trimmed = (string-trim '(#\space #\tab #\return) line)
        unless (zerop (length trimmed))
          append (handler-case (list (decode-frame trimmed))
                   (error () nil))))

(defun replay-envelopes (path)
  "Every envelope in the file at PATH, in file order."
  (with-open-file (in path :direction :input :external-format :utf-8)
    (replay-envelopes-from-lines
     (loop for line = (read-line in nil nil) while line collect line))))

(defun %make-replay-head (cols rows)
  "A head with no socket, sized COLS x ROWS, with the operator's prefs applied.

`load-prefs-into` is here and not left out because the reference does it
(`app.load_prefs()` on the first line of `fn replay`): the fold state a replay
paints with is the one the operator left behind, and a comparison that read the
prefs on one side only would differ on every row a fold covers."
  (let ((head (%make-head)))
    (let ((notes (ignore-errors (load-prefs-into head))))
      (dolist (note notes)
        (setf (head-status-note head)
              (format nil "~a~@[ · ~a~]" note (head-status-note head)))))
    (setf (head-cols head) cols
          (head-rows head) rows
          ;; **CONNECTED, with no socket.** `%send` is `(and (head-stream head)
          ;; (head-connected head))`, so a NIL stream already makes every send a
          ;; no-op and this flag does not open a wire. What it does is answer the
          ;; question `alarmed-p` asks: *is anything wrong enough to spend a row
          ;; on*, whose own clause is `(not (head-connected head))` — a head that
          ;; LOST its daemon. A replay never had one, and leaving this NIL put a
          ;; `⚠` on the bottom border of every fixture in the first comparison:
          ;; nine findings that were one fact about the instrument, and none of
          ;; them about rendering.
          (head-connected head) t)
    (screen-resize (head-screen head) cols rows)
    (screen-resize (head-prev-screen head) cols rows)
    head))

(defun replay-fold (head envelopes)
  "Fold ENVELOPES into HEAD, one at a time, through the live head's own handler.

`%handle-frame`, not `apply-event` directly: the two events a head ANSWERS
rather than renders (`screen_requested`, `secret_requested`) and the queued-prompt
retirement live there, and a replay that skipped them would be folding through a
path the running head does not use — which is the one thing an instrument for a
1:1 claim must not do. An envelope on the wire has no `frame` key because the
daemon's `ServerFrame::Event` supplies it, so it is put back here.

A frame that will not fold is remembered and skipped rather than fatal, for the
same reason the loop does it: one bad row is one bad row, not a lost session."
  (dolist (env envelopes)
    (handler-case (%handle-frame head (list* :frame "event" env))
      (error (e) (setf *last-render-error* e)))))

(defmacro with-replay-globals ((&key (clock nil)) &body body)
  "Run BODY with every global the frame reads back at its start-of-process value.

A replay has to answer the same bytes on the second call as on the first, and
half of what a frame draws is not in the head struct: the staged call facts, the
money meter, the resync count, the ESC double-tap window. In a fresh process
those are already at their defaults; in the TEST suite, where two replays run in
one image, the second would otherwise inherit the first's — which is a golden
that passes alone and fails in a batch, the worst shape a regression net has.

CLOCK, when given, is what `internal-real-time-ms` answers for the whole
extent — the fold AND the frame. That is what makes `--no-tty` deterministic;
see this file's header."
  `(let ((*fixed-clock-ms* ,clock)
         (*now-ms* 0)
         (*last-event-ms* nil)
         (*attach-started-ms* nil)
         (*turn-started-ms* nil)
         (*spent-micros* 0)
         (*spent-seen* nil)
         (*resyncs* 0)
         (*scrubbed-total* 0)
         (*notice-ttl* 0)
         (*model-from-settings-at* 0)
         (*model-from-turn-at* 0)
         (*verbosity* :normal)
         (*filtered-total* 0)
         (*rendered-total* 0)
         (*pane-scroll* 0)
         (*pick-open* nil)
         (*mode-confirm* nil)
         (*peeked-session* nil)
         (*peeked-dropped* 0)
         (*job-out* nil)
         (*job-out-total* 0)
         (*call-facts* nil)
         (*item-facts* nil)
         (*call-started-ms* nil)
         (*call-targets* nil)
         (*answered-calls* nil)
         (*esc-at* nil)
         (*ctrlc-at* nil)
         (*last-render-error* nil)
         (*replaying* t))
     ,@body))

(defun replay-screen-from-envelopes (envelopes &key (cols 100) (rows 40))
  "Fold ENVELOPES and answer the screen as one ANSI string per row.

The same `screen-rows-ansi` a `screen_requested` is answered with, so what this
prints is what the head would have told a tool it was showing — not a second
description of the frame written for the printer.

Second value: the condition a fold or a render left behind, or NIL. It is
returned rather than merely remembered because `with-replay-globals` rebinds
`*last-render-error*` — so a caller that read the global afterwards would read
the one from before the call and conclude the frame was clean. The comparison's
regression net asserts on this value."
  (with-replay-globals (:clock 0)
    (let ((head (%make-replay-head cols rows)))
      (replay-fold head envelopes)
      (%render head)
      (values (screen-rows-ansi (head-screen head)) *last-render-error*))))

(defun replay-screen (path &key (cols 100) (rows 40))
  "The screen the file at PATH produces at COLS x ROWS. Deterministic.

Second value: the condition a fold or a render left behind, or NIL."
  (replay-screen-from-envelopes (replay-envelopes path) :cols cols :rows rows))

(defun replay-print (path &key (cols 100) (rows 40))
  "`--replay FILE --no-tty`: the frame on stdout, one row per line, then exit.

100x40 is the reference's fixed size (`app.screen(100, 40)`,
letibot-tui.rs:271); `--cols`/`--rows` move it so a difference can be checked at
the width it was reported at."
  (let ((out (%open-stdout)))
    (dolist (line (replay-screen path :cols cols :rows rows))
      (write-string line out)
      (write-char #\newline out))
    (force-output out)))

(defparameter *replay-pace-seconds* 0.008
  "8 ms between envelopes on a tty — the reference's own pacing
(`thread::sleep(Duration::from_millis(8))`, letibot-tui.rs:296). It is there so a
replay SHOWS the streaming behaviour instead of the finished document; at 0 the
whole session lands in one frame and the thing you wanted to look at never
happened on the screen.")

(defun replay-tty (path)
  "`--replay FILE` on a real terminal: paced paint, then the live loop.

The same shape as the reference (letibot-tui.rs:280-330) — fold one envelope,
paint, take whatever keys arrived, sleep 8 ms — and then a normal `run-loop`, so
the operator can scroll it, open the panes and fold the cards with no daemon
anywhere. The clock is REAL here: this mode is for looking, and a frozen spinner
on a paced replay would misreport the one thing the pacing exists to show."
  (%open-stdout)
  (unless (plusp (%isatty 1))
    (error "the head paints on the real terminal — use --no-tty on a pipe"))
  (with-replay-globals ()
    (let ((head (%make-replay-head (nth-value 0 (terminal-size 1))
                                   (nth-value 1 (terminal-size 1)))))
      (setf *head* head)
      (setf (head-input head)
            (sb-thread:make-thread (lambda () (%input-loop head)) :name "leticl input"))
      (with-tui-terminal (*stdout*)
        (block paced
          (dolist (env (replay-envelopes path))
            (unless (head-running head) (return-from paced))
            (setf *now-ms* (internal-real-time-ms))
            (note-frame-arrived)
            (handler-case (%handle-frame head (list* :frame "event" env))
              (error (e) (setf *last-render-error* e)))
            (ignore-errors (%poll-resize head))
            (when (head-dirty head) (%render-and-paint head))
            (dolist (key (%drain (head-keys head)))
              (handler-case (%handle-key head key) (error () nil)))
            (sleep *replay-pace-seconds*)))
        (when (head-running head)
          (setf (head-dirty head) t)
          (run-loop head))))))

(defun replay (path &key no-tty (cols 100) (rows 40))
  "The `--replay` entry point. NO-TTY prints one fixed-size frame and returns."
  (if no-tty
      (replay-print path :cols cols :rows rows)
      (replay-tty path)))
