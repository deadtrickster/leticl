;;;; peek.lisp — the peek pane: a subagent's conversation, tailed live
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

(defvar *peeked-session* nil
  "The subagent whose scrollback `head-peeked` holds — for the title. A defvar
beside the slot rather than a second slot: a struct layout change is a restart.")

(defvar *peeked-dropped* 0
  "How many of that subagent's events fell off the daemon's ring before the read.")

(defvar *peeked-snapshot* nil
  "The ROWS a peek answered with, when the daemon sends them — else NIL.

**A `Peeked` MAY CARRY A SNAPSHOT NOW** (letibot `1520bb5`): a defaulted field on a frame the head
already sends, so no protocol bump and an older daemon is unaffected. That field is what lets this head
draw a child with the SAME renderer as any session — markdown, air rule, tool cards, the rung —
instead of hand-drawing a ring of events nobody may fold (*for reading, NOT FOR FOLDING INTO THE
HEAD'S STATE*, `Peeked`'s own docstring).

**ABSENT ROWS ARE NOT AN ERROR, and the fallback SAYS SO.** The shape is OPT-IN: a peek that asks for
rows gets a snapshot and an empty ring, and one that asks for events gets the ring and no rows — by
design, and not by absence. A daemon older than the field answers an `Events` request whatever the head
asked for, which is the same absent-means-old rule every field on this wire keeps. So the pane says which
rendering the reader is looking at rather than drawing a degraded one that looks plain.
See `peek-lines`, where the reader is looking.

A `defvar` and not a head slot, for the reason all live state is: a struct change is a restart.")

(defvar *peek-render-head* nil
  "A scratch head for drawing a peeked session's rows, kept so one child costs one head.

Rebuilt whenever the pane opens on a different child, and drawn under `with-replay-globals` so the
child's frame cannot touch the globals the MAIN view is built from — the history cache, the scroll
anchor, the depth high-water. Without that, scrolling a child and coming back would leave the parent
anchored to the child's row.")

(defun peeked-rows-p ()
  "Did the last peek answer with ROWS?"
  (and *peeked-snapshot* (getf *peeked-snapshot* :items) t))

(defun subagent-out-lines (events &key (payloads t))
  "A subagent's scrollback as the reference draws it (`subagent_out_lines`,
letibot `2ac6200`): every tool result as `· name — outcome` over its payload, and
the model's ANSWER text in order beside them — a `digest` subagent calls no tools
by design and its whole product is prose, and the pane that drew only tool results
told the operator there was nothing (*\"when i enter - no output\"*). Reasoning
stays out: it is the model thinking rather than its answer. Spills are listed at
the end, so the full output is one path away.

**AND THIS FUNCTION IS A COPY, WHICH IS THE THING TO FIX RATHER THAN IMPROVE.** It exists because
`Peeked` hands back a ring of EVENTS and says what they are for — *these events are for reading, NOT
FOR FOLDING INTO THE HEAD'S STATE* — so a head holding a peek has nothing it may fold and nothing to
do but draw the events by hand. That is `sub_out_lines` (letibot `app.rs:12682`, `out.push(l.clone())`)
and this is its copy; two head-local renderers for one conversation is the drift this pair has now hit
five times in two days.

**A CHILD IS A SESSION**, and the door that returns rows already exists: `SessionEvent::Subagent`'s
`subagent_id` is documented as *the subagent's own session id*, and `Attach`/`Resync` with
`since_seq = 0` answers with a `Snapshot` — rows, which this head draws with its real renderer,
markdown and air rule and rung and all.

**AND THE REASON A HEAD DOES NOT SIMPLY ATTACH TO ONE IS FIVE LINES THAT HIDE IT.** The operator, on
being read a plan that made a child something to *view*: *\"why readonly? subagent session is more like
you driving others via tmux. I already can post to subagent, and agent can talk back and forth too.\"*
A child is attachable, promptable and answers — this session's own relationship with the head it is
spoken through, one level down — and both heads filter sub-sessions out of the picker
(`head.lisp:1053`, `session.lisp:382`, `panes.lisp:77` here; two sites in letibot), with
`chrome.lisp:363` stating the belief out loud: *a subagent is not a session a picker lists*. That
belief is the bug, and **this function is its downstream scaffolding — it is deleted rather than
taught**, together with `Peek`'s special verb if letibot judges it no longer earns its place.

**Do not fold these events into a scratch session** — that would fold what the protocol says must not
be folded, and it would be the sixth copy of a session that was hidden by five lines.

**AND THE CHILD'S TASK IS THE FIRST THING IN IT, in full.** The operator, reading the pane:
*\"the first prompt is truncated too early\"* and *\"I want to be able to easily see it in full\"*.
MEASURED, and the truncation is not this head's: the daemon publishes the `Subagent` event's
`prompt` as `derive_title(prompt)` — `harness.rs:7177` — **the subtask's FIRST LINE**, because the
field doubles as the picker's title, and on the finishing event it publishes the child's *answer's*
first line instead (`publish(\"done\", &first_line)`). So the pane's row can only ever show a title
and, once the child is done, not even the task. **The transcript read is the only place the task
survives**, and this function was dropping it: the child's own `user` row is drawn here now, wrapped
by the caller like everything else, so the question is above its answer where it belongs.

**AND THE RUNG GOVERNS IT**, because this is a view and view rules are the rung's: with `:payloads`
NIL the answers are still drawn and the tool payloads are held back behind a seam that counts them —
the same question the transcript asks a committed row (`reading-p`), asked of a conversation that is
not the session's own. `peek-lines` passes it, so the pane follows `:reading` like every other view."
  (let ((out nil) (spills nil) (hidden 0))
    (flet ((emit (text) (push text out)))
      (dolist (env events)
        (case (event-name env)
          ((:transcript-content)
           (let ((item (getf env :item)))
             (when item
               (switch ((getf item :type) :test #'string=)
                 ("user"
                  ;; **THE TASK, WHICH THE EVENT'S `prompt` ONLY EVER CARRIED AS A TITLE.** Both user
                  ;; shapes the wire uses: `:text`, and `:parts` for a row the daemon built from
                  ;; fragments.
                  (let ((text (or (getf item :text)
                                  (getf (first (getf item :parts)) :text))))
                    (when (and text (plusp (length (string-trim " " text))))
                      (emit (format nil "▌ ~a" text))
                      (emit ""))))
                 ("tool_result"
                  (emit (format nil "· ~a — ~a" (getf item :name)
                                (%outcome-word (outcome-name (getf item :outcome)))))
                  (let ((rows (%payload-lines (getf item :payload))))
                    (if payloads
                        (dolist (l rows) (emit (format nil "  ~a" l)))
                        (incf hidden (length rows))))
                  (emit ""))
                 ("assistant"
                  (let ((text (or (getf item :text) "")))
                    (when (plusp (length (string-trim " " text)))
                      (dolist (l (uiop:split-string text :separator '(#\newline)))
                        (emit l))
                      (emit ""))))))))
          ((:tool-finished)
           (awhen (getf env :spill) (push it spills)))))
      (when (plusp hidden)
        (emit (format nil "  … +~d line~:p at a higher rung · /verbosity" hidden)))
      (when spills
        (emit "full output on disk:")
        (dolist (sp (nreverse spills)) (emit (format nil "  ~a" sp)))
        (emit "")))
    (nreverse out)))

(defvar *peek-total* 0
  "How many LINES the peek pane has in total, header and footer included — what
`*pane-lines*` must be set to for this pane, so `pane-scroll-max` clamps against
the whole read and not against the window drawn from it. Set by `peek-lines`,
which is the only place the wrapped total is known.")

(defvar *peek-spill* nil
  "`(KEY . PATH)` for the scrollback already written to disk, so one peek is
written once however many frames draw it. KEY is the subagent and the number of
lines, which is what changes when a running subagent produces more.")

(defun peek-spill-path (session-id)
  "Where a peeked subagent's whole scrollback goes — the reference's
`spill_sub_out` (app.rs:8025-8060), which writes
`<runtime>/letibot/subagent-<id>.log` and names it in the pane's footer.

`<runtime>/leticl/` rather than `letibot/` on purpose: two heads writing one
path would each claim the other's file, and the footer's whole job is to name a
file the operator can open and trust."
  (format nil "~a/leticl/subagent-~a.log" (runtime-dir) session-id))

(defun spill-peek (session-id lines)
  "Write LINES for SESSION-ID and return the path, or NIL when it could not be
written — the reference returns `None` the same way and the footer then says
`not written`. A pane that promises a file it did not write is worse than one
that promises nothing.

Written from the DRAW rather than from the frame that built the view, which is
where the reference writes it: the arm that folds a `peeked` frame is in
`src/head.lisp` and belongs to another strand. Idempotent through `*peek-spill*`,
so the cost is one write per peek and not one per frame."
  (let ((key (cons session-id (length lines))))
    (if (equal (car *peek-spill*) key)
        (cdr *peek-spill*)
        (let ((path (ignore-errors
                     (let ((p (peek-spill-path session-id)))
                       (ensure-directories-exist p)
                       (with-open-file (out p :direction :output
                                              :if-exists :supersede
                                              :if-does-not-exist :create
                                              :external-format :utf-8)
                         (dolist (l lines) (write-line l out)))
                       p))))
          (setf *peek-spill* (cons key path))
          path))))

(defun peek-row-count (head)
  "How many BODY lines the peek pane has — what `pane-row-count` should answer
for `:peek`, where `src/editor.lisp:749` answers 0.

That zero is the whole of the pane's arrow keys: `move-cursor` clamps the cursor
to `(1- 0)` and Up and Down move nothing, while the pane's own last line
advertises that they scroll. The count is the body's, not the rendered pane's,
because the header and the footer are not rows a cursor may land on."
  (declare (ignorable head))
  (length (subagent-out-lines (head-peeked head))))

(defun pane-escape-target (mode)
  "Where Esc goes from pane MODE — the reference's `sub_out` arm (app.rs:3251-3262)
sits ahead of the generic Esc on purpose: **Esc in the peek pane means back to
the tree, not close everything**. Everywhere else it means `:normal`.

`:job-out` is the same shape one door over: the job-output view is an OVERLAY
over the jobs list, not a replacement for it, so Esc goes back to the list the
row was chosen from — *\"and Esc returns to the jobs list, which never closed\"*
(letibot `3aabe4f`). The list itself survives because `head-jobs` and
`head-picker-sel` are untouched while the overlay is up.

The key itself is dispatched in `src/editor.lisp:242`, which sends every pane to
`:normal`; this is the fact that arm needs and the one line it is missing."
  (pane-esc-target (pane-for mode)))


(defvar *peek-prompt-only* nil
  "Did the reader press `p` — the child's PROMPT rather than its conversation?

The operator: *\"when i select an agent and press 'p' it should show me prompt in a scrollable popup.\"*
Set by the key, read by `peek-lines`, and CLEARED by every other way into the peek pane (Enter, `/peek`)
so the narrow view cannot outlive the press that asked for it.")

(defun %peek-prompt-pane (head cols room)
  "The child's own task, whole, in a popup that scrolls — what `p` opens.

**The pane's first line is an EXCERPT; this is the whole thing.** The pane draws `Subagent.prompt`, which
is `derive_title(prompt)` — the task's first line and nothing more — so a long task is cut there for
ever. The full text survives in exactly one place: **the child's own transcript**, whose first row is the
`user` row the daemon gave it when it spawned it.

Drawn through `item-lines` — the renderer every transcript row uses — so the prompt arrives with the
same block and wrapping it has in a conversation, and SCROLLS with the keys every overlay already has:
the same `*pane-scroll*`, the same tail-origin window, the same Esc.

`PeekShape::Rows` is what makes this possible at all: the reply carries the child's rows, so the head has
the task without reading events it may not fold."
  (let* ((snapshot *peeked-snapshot*)
         (id (getf snapshot :session-id))
         (items (getf snapshot :items))
         (task (first (remove-if-not (lambda (i)
                                       (equal (getf (leticl::item-body i) :type) "user"))
                                     items)))
         (card (if task
                   (item-lines task cols (head-prefs head))
                   (list (list (cons "    this child's transcript carries no prompt — nothing was asked, or its
 first rows fell off the daemon's scrollback." '(:dim t))))))
         (room (max 8 (or room 40)))
         (head-lines (list (list (cons (format nil "prompt — ~a" (if id (short-id id) "?"))
                                          '(:bold t)))
                           nil))
         (footer (list nil (list (cons "    arrows scroll · esc back" '(:dim t)))))
         (visible (max 1 (- room (length head-lines) (length footer))))
         (total (length card))
         (scroll (min (max 0 *pane-scroll*) (max 0 (- total visible))))
         (end (- total scroll))
         (start (max 0 (- end visible))))
    (setf *pane-scroll* scroll
          *peek-total* (+ (length head-lines) total (length footer)))
    (append head-lines
            (subseq card start end)
            (make-list (max 0 (- visible (- end start))))
            footer)))

(defun %peek-snapshot-pane (head cols room)
  "The peeked child's rows, drawn by the renderer that draws the conversation.

**ONE RENDERER, NOT TWO.** A peek can answer with the session's ROWS when it asks for them
(`PeekShape::Rows`, letibot `1520bb5`), and a snapshot is a session's rows — so this builds a session from it and calls `%viewport-lines`, the function every
frame of the main conversation comes through. Markdown, the air rule, the tool cards, the rung and the
seams are all its, by construction rather than by imitation; `subagent-out-lines` is left to the path
where no rows arrived.

**Under `with-replay-globals`**, because that renderer reads globals the MAIN view owns — the history
cache, the scroll anchor, the depth high-water — and a child drawn inside them would leave the parent
anchored to the child's row. The scratch head is kept for the child it was built for, so opening one
child costs one head rather than one per frame.

**The dropped count STAYS.** A snapshot can be short the same way the ring could — the daemon bounds a
view by count and by bytes — and a truncated read that renders as a complete one is the `Abstained`
defect in another costume.

`*pane-scroll*` is the child's scroll and `*peek-total*` its whole length: the pane measures off the
BOTTOM (the tail is the origin, the reference's own `v.scroll`), which is what `head-scroll` 0 means,
so the two agree without a conversion."
  (let* ((snapshot *peeked-snapshot*)
         (id (getf snapshot :session-id))
         (head-lines (append
                      (list (list (cons (format nil "subagent output — ~a"
                                                (if id (short-id id) "?"))
                                        '(:bold t))))
                      (when (plusp *peeked-dropped*)
                        (list (list (cons (format nil "    ~d earlier event~:p fell off the daemon's scrollback before this read"
                                                  *peeked-dropped*)
                                          '(:dim t)))))
                      (list nil)))
         (footer (list nil
                       (list (cons "    arrows scroll · esc back · the same renderer as any session"
                                   '(:dim t)))))
         (room (max 8 (or room 40)))
         (visible (max 1 (- room (length head-lines) (length footer))))
         (scratch (let ((h *peek-render-head*))
                    (if (and h id (equal (session-session-id (head-session h)) id))
                        h
                        (let ((h (%make-head)))
                          (setf *peek-render-head* h)
                          h))))
         (s (head-session scratch)))
    (ingest-snapshot s snapshot)
    (when id (setf (session-session-id s) id))
    (setf (head-cols scratch) cols
          (head-rows scratch) room
          (head-prefs scratch) (head-prefs head)
          (head-scroll scratch) (max 0 *pane-scroll*))
    (let* (;; **THE RUNG IS THE HEAD'S, NOT THE REPLAY'S.** `call-with-replay-globals` resets
           ;; `*verbosity*` to `:normal` (the macro's job is to answer the same bytes twice), but
           ;; this is a LIVE peek, and the operator's rung is the view they chose: the event path
           ;; already follows it (`subagent-out-lines`'s `:payloads (not (reading-p))`), and this
           ;; path's own docstring claims *the rung … is all its, by construction*. Captured
           ;; before the reset and restored inside, so the child's rows are drawn at the parent's
           ;; rung rather than at the replay's `:normal`.
           (rung *verbosity*)
           (lines (call-with-replay-globals
                   (lambda ()
                     (let ((*scroll-max* 0)
                           (*verbosity* rung))
                       (prog1 (%viewport-lines scratch cols visible)
                         (setf *peek-total* (+ (length head-lines) *scroll-max* visible (length footer))
                               *pane-scroll* (head-scroll scratch))))))))
      (append head-lines
              lines
              ;; pad, so the footer sits on the pane's last row rather than floating under a short read
              (make-list (max 0 (- visible (length lines))))
              footer))))

(defun peek-lines (head cols &optional room)
  "A peeked subagent's scrollback — the reference's `sub_out_lines`
(app.rs:6844-6892): the title names the subagent, a dropped count when the ring
lost events before the read, then the output, and the empty case SAYS what it
means — *neither an answer nor tool output* — and names the two reasons that can
be true of, because \"no tool output\" reads as a fault for a subagent that was
never going to produce any.

**A TERMINAL, NOT A DOCUMENT**, which is what it was not. The reference shows the
TAIL by default and clamps the scroll *here*, where the visible height is
actually known — `a key handler cannot clamp what it cannot see`. Ours returned
every line and let the generic pane window take the TOP of it, so opening a
subagent that had produced two hundred lines showed its first screenful and the
answer, which is at the end, was off the bottom.

ROOM is the rows the frame gave the pane. Without it (a test, `%pane-head`) the
whole thing comes back unwindowed, which is the shape every other pane has.

`*pane-scroll*` counts lines hidden **off the BOTTOM** for this pane — the
reference's own `v.scroll` — because the tail is the origin here and everything
else is measured back from it.

The footer names the SPILL FILE, which had no counterpart at all: the pane
advertised three keys and a full copy on disk, and the copy was never written."
  ;; **`p` SHOWS THE PROMPT AND NOTHING ELSE** — the narrow view of the same fetch. See
  ;; `%peek-prompt-pane`; Enter and `/peek` clear the flag, so this cannot outlive the press.
  (when (and *peek-prompt-only* (peeked-rows-p))
    (return-from peek-lines (%peek-prompt-pane head cols room)))
  ;; **A SNAPSHOT IS DRAWN BY THE REAL RENDERER** — see `%peek-snapshot-pane`. Everything below is the
  ;; path for a daemon that answers a peek with events and no rows, and that path SAYS which it is.
  (when (peeked-rows-p)
    (return-from peek-lines (%peek-snapshot-pane head cols room)))
  (let* ((events (head-peeked head))
         ;; **THE RUNG GOVERNS THIS VIEW TOO** — see `subagent-out-lines`: at `:reading` the child's
         ;; answers are drawn and its tool payloads are held behind a seam, which is the same question
         ;; the transcript asks a committed row.
         (body (subagent-out-lines events :payloads (not (reading-p))))
         (spill (and body *peeked-session* (spill-peek *peeked-session* body)))
         (shown (or body
                    (list "    this subagent's scrollback has neither an answer nor tool output. It may still be running, or its rows may have fallen off the daemon's ring.")))
         (head-rows (append
                     (list (list (cons (format nil "subagent output — ~a"
                                               (if *peeked-session* (short-id *peeked-session*) "?"))
                                       '(:bold t))))
                     (when (plusp *peeked-dropped*)
                       (list (list (cons (format nil "    ~d earlier event~:p fell off the daemon's scrollback before this read"
                                                 *peeked-dropped*)
                                         '(:dim t)))))
                     ;; **SAID, because a degraded render must not look like a plain one.** This daemon
                     ;; answered the peek with events and no rows — older than the field, or a path that
                     ;; did not ask — so the child is hand-drawn by `subagent-out-lines` rather than by
                     ;; the renderer the conversation uses.
                     (list (list (cons "    drawn from the event list — no rows came back for this peek (a daemon older than `PeekShape::Rows`, or a caller that asked for events)"
                                       '(:dim t))))
                     (list nil)))
         (wrapped (mappend (lambda (l) (or (wrap-segments (list (cons l nil)) (pane-width cols))
                                           (list nil)))
                           shown))
         (footer (list nil
                       (list (cons (format nil "    arrows scroll, Enter re-reads, Esc back — full: ~a"
                                           (or spill "not written"))
                                   '(:dim t))))))
    (if (null room)
        (append head-rows wrapped footer)
        ;; the tail, clamped where the height is known
        (let* ((visible (max 1 (- room (length head-rows) (length footer))))
               (total (length wrapped))
               (max-scroll (max 0 (- total visible)))
               (scroll (min (max 0 *pane-scroll*) max-scroll))
               (end (- total scroll))
               (start (max 0 (- end visible))))
          (setf *pane-scroll* scroll
                *peek-total* (+ (length head-rows) total (length footer)))
          (append head-rows
                  (subseq wrapped start end)
                  ;; pad, so the footer sits on the pane's last row rather than
                  ;; floating under a short read
                  (make-list (max 0 (- visible (- end start))))
                  footer)))))

