;;;; status.lisp — the /status screen: the numbers the head knows about itself
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

(defun status-screen-lines (head cols)
  "The status screen: `this head`, then one row per counter with WHY it exists
under it — the reference's `status_lines` (app.rs:6717), which is a screen that
explains its numbers rather than listing them.

Measured against letibot's own screen: ours was a ` status ` title and fourteen
`key value` pairs, several of them things the reference does not show at all
(title, model, items, a raw usage plist) and one printing `NIL` for a role nobody
sent. The reference shows the counters `/status` exists for — session, head, seq,
filtered, dropped, scrubbed, resync, verbosity, workspace — each as `  key` twelve
wide and dim, the value plain, and a dim explanation wrapped at `w - 16` under a
fourteen-column indent, then a blank. 26 rows against our 18."
  (let* ((w (pane-width cols))
         (s (head-session head))
         (out (list nil (list (cons "this head" '(:bold t))))))
    (flet ((row (k v why)
             (push (list (cons (format nil "  ~12a" k) '(:dim t))
                         (cons (format nil "~a" v) nil))
                   out)
             (dolist (l (wrap-text why (max 4 (- w 16))))
               (push (list (cons (make-string 14 :initial-element #\space) nil)
                           (cons l '(:dim t)))
                     out))
             (push nil out)))
      (when (plusp (length (session-session-id s)))
        (row "session" (session-session-id s)
             "In full, because this is the form a command takes. The header shows the last eight characters, which is the part two sessions differ in."))
      (when (plusp (length (session-head-id s)))
        (row "head" (format nil "~a · ~d attached" (session-head-id s)
                            (max 1 (length (session-heads s))))
             "Every head on this session sees the same stream from its own read mark. Closing one does not stop the turn."))
      (row "seq" (format nil "~d · ~d rendered" (session-seq s) *rendered-total*)
           "The log's monotonic, gap-free position, and how many of those events reached the screen. Both counted by this head, not by the daemon.")
      (row "filtered" (format nil "~d (~(~a~))" *filtered-total* *verbosity*)
           "Events this head chose not to show at the current verbosity. /verbosity opens a card of four rungs.")
      ;; **R10's counted half.** The number `/status` reads so a dismissal is
      ;; COUNTED rather than a disappearance: retiring a warning takes its row off the
      ;; screen and changes nothing here — `/notes` lists it with its whole text, and
      ;; it stays retired across a resync and a reattach. Present at 0 of 0 on a head
      ;; that has never been warned, which is a different statement from a head that
      ;; does not count them — the same rule `unreadable` keeps below.
      (multiple-value-bind (held retired) (warning-counts s)
        (row "notes" (format nil "~d of ~d retired" retired held)
             "The warnings this head holds, and how many the reader has retired. A retired one is off the screen and still in the log: /notes lists it with its text, /status counts it here, and a resync does not put it back."))
      (row "dropped" (or (session-dropped s) 0)
           "Events the daemon's bounded scrollback threw away before this head asked for them. Not a rendering choice: they are gone.")
      (row "scrubbed" *scrubbed-total*
           "Interactive-only frames withheld from a head that attached late — partial tool output and the like, which has no durable form.")
      (row "resync" *resyncs*
           "Times this head threw its state away and took a fresh snapshot, because the gap since its read mark was past the daemon's bound.")
      ;; **PRESENT AND ZERO**, which is the point of the row. A head that has never met
      ;; a frame it cannot read says 0 — a different statement from a head that does not
      ;; count them at all, and the one that tells an operator where to look when a
      ;; screen is wrong. A daemon one version ahead is the cause almost every time.
      ;; **the eval channel**, and it is a row because a count nobody shows is a
      ;; number nobody can act on: a head that has stopped being evaluatable and has
      ;; not said so cannot be told from a head nobody has asked. 0 is a real reading
      ;; here — this head has never had an accept fail — and that is a different
      ;; statement from a head that does not count them, which is the rule the
      ;; `unreadable` row below already keeps.
      (row "eval" (format nil "~a listening · ~d failed accept~:p"
                          (if (head-hack-listener head) "yes" "NO")
                          *hack-accept-errors*)
           "The live-modification socket: whether this head is still accepting eval connections, and how many times an accept failed and was retried. A head that stopped accepting runs on with a socket file and nothing behind it, which is what this row is for.")
      (row "unreadable" *unreadable-total*
           "Frames that arrived and could not be read. Almost always a daemon newer than this head: the frames the two share read fine, and the first one they do not is this. Each one is named in the conversation where it arrived.")
      ;; **The version, always present, and the DIRECTION when they differ.** §13.2b in
      ;; the other direction from the counters: the question "which build is on the
      ;; other end of this socket" has no answer anywhere else on the screen, and it is
      ;; the first thing to check when a head behaves strangely. `not told yet` is a
      ;; different statement from a version number — the same distinction the empty
      ;; transcript banner draws — and the row is here BEFORE the handshake has happened
      ;; so that "nobody told me" cannot be read as "we agree".
      (row "protocol" (if (integerp *daemon-protocol*)
                           (format nil "~d · ~a"
                                   *daemon-protocol*
                                   (cond ((= *daemon-protocol* +protocol-version+)
                                          (format nil "the same build as this head (protocol ~d)"
                                                  +protocol-version+))
                                         ((> *daemon-protocol* +protocol-version+)
                                          (format nil "this head speaks ~d — NEWER build"
                                                  +protocol-version+))
                                         (t (format nil "this head speaks ~d — OLDER build"
                                                    +protocol-version+))))
                           "not told yet")
           "The protocol both halves were built against, compared at the handshake. A NEWER daemon sends frames this build may not know: they are reported as they arrive and skipped. An OLDER one cannot read a command it has never heard of, and answers that by closing the connection — so a session with an older daemon can end on the next thing you type, and a restart of the daemon is the fix either way.")
      ;; THE RENDER ERROR, first among the things that can go wrong, because it is
      ;; the one that can hide its own report: a render error paints a failure
      ;; frame, and if the failure is IN the painting the frame saying so is
      ;; exactly what does not arrive. It has a row here so the question "why is
      ;; the screen wrong" has an answer that does not depend on the screen.
      (when *last-render-error*
        (row "render" (format nil "~a" (type-of *last-render-error*))
             (format nil "THE LAST FRAME FAILED TO RENDER: ~a — the failure is painted into the screen and this line is the same fact in a place that survives it. Fix the definition and re-push; clearing it is not the fix." *last-render-error*)))
      (row "verbosity" (verbosity-name)
           "What reaches the transcript at the current filter. /verbosity opens a card of four rungs. It used to sit on the composer's border, which was a row of attention paid for ever for a fact read once.")
      (let ((ws (getf (session-wiring s) :workspace)))
        (when (plusp (length (or ws "")))
          (row "workspace" (tilde-path ws)
               "Where the daemon is standing. Tools resolve relative paths here.")))
      ;; **AND WHAT THE READER HAS ALREADY SEEN** — the one line that keeps a quiet `⚠` from
      ;; reading as a zero counter. Opening this screen acknowledges every counter at the value it
      ;; holds (`acknowledge-alarms`), which is what takes the triangle off the composer's edge;
      ;; the numbers STAY here, exactly as a retired note stays in `/notes`. So the screen that
      ;; quiets the pointer is also the screen that says the pointer was quieted and why —
      ;; otherwise a reader coming back to find no triangle would conclude the count had reset.
      (let ((acked (remove-if-not (lambda (pair)
                                    (alarm-acked-p (car pair) (cdr pair)))
                                  (list (cons "dropped" (or (session-dropped s) 0))
                                        (cons "scrubbed" *scrubbed-total*)
                                        (cons "resync" *resyncs*)
                                        (cons "unreadable" *unreadable-total*)))))
        (when acked
          (push nil out)
          (push (list (cons (format nil "  acknowledged: ~{~a~^, ~} — seen here, so the edge is quiet; a counter\n above these values points again"
                                    (loop for (k . v) in acked collect (format nil "~a ~d" k v)))
                            '(:dim t)))
                out)))
      (push (list (cons "  /status or esc closes this" '(:dim t))) out)
      (nreverse out))))

