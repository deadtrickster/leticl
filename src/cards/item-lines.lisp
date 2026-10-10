;;;; item-lines.lisp — THE DOOR: one item to lines, the memo that makes it cheap, and the
;;;; factories (`item-card`, `tool-card-of`) that pick which card class answers.
;;;;
;;;; It comes after every card file, because it names them all.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defun item-lines (item cols prefs)
  "ITEM as segment lines — and the one place the work is remembered.

**The context is stamped once; the items are cached under it.** A walk then re-renders the rows that
changed — a live row, a body filled in — and reuses every other line in a session of thousands, which
is the operator's 90% of a core: while a call ran, ten frames a second re-rendered 2600 frozen rows to
redraw one live duration.

**THE CONTEXTS ARE A LIST, NOT A SLOT, and that is what makes the paragraph above true rather than
intended** — see `*item-lines-frames*` for the measurement of the single slot that missed on every
call, because two call sites inside one walk stamp two different contexts."
  (let* ((frame (%item-lines-frame cols prefs))
         (table (getf frame :table))
         (id (getf item :item-id))
         (sig (%item-lines-sig item))
         (hit (and id (gethash id table))))
    (if (and hit (equal (car hit) sig))
        (cdr hit)
        (let ((lines (%item-lines-render item cols prefs)))
          (when id (setf (gethash id table) (cons sig lines)))
          lines))))

(defun %item-lines-render (item cols prefs)

  "One transcript row to segment lines.

The model's WORKING — reasoning and tool calls — is stepped in
`(activity-indent cols)` columns, under what it SAYS. Measured against letibot's
screen: its cards sit at column 4 and its prose at 2, while every row of ours was
at 2. The step is what makes a turn readable as a turn — the answer at the body's
own column, the working subordinate to it — and it costs no colour, so it survives
a terminal-native palette."
  ;; **A row the reader has retired draws NOTHING** (R10). It is still an ITEM — it
  ;; is in the transcript, `/status` counts it and `/notes` lists it with its text —
  ;; and only its rendering is withheld, which is what "retired is not deleted"
  ;; means. The flag is on the item rather than read from the session because this
  ;; function is handed an item and nothing else, and the session's set is what
  ;; keeps the two from disagreeing across a resync.
  (when (getf item :retired)
    (return-from %item-lines-render nil))
  (let ((body (item-body item)))
    ;; **R37's rung, at the one place a row is turned into lines.** What goes is the head's
    ;; WORK — `+reading-hides+` — and everything else is drawn, including a body type this
    ;; build has never met. That direction is deliberate: a denylist that hides three named
    ;; kinds cannot hide the conversation by omission, which is exactly what the first cut
    ;; (an allowlist of one) did to the operator's own message.
    ;; **`%key-from-wire`, not `intern`** — and this was a real bug for one run. The wire's
    ;; type is snake case (`tool_result`) and `(intern (string-upcase …) :keyword)` makes
    ;; `:|TOOL_RESULT|`, UNDERSCORE and all, which is a different symbol from the `:tool-result`
    ;; the list holds: the row was drawn and the test said so. `%key-from-wire` is the tree's
    ;; own answer to exactly this, and `apply-event` already uses it for the same reason
    ;; (`"tool_call" must become :tool-call to match`).
    (when (reading-hides-p item)
      (return-from %item-lines-render nil))
    (cond
      ;; **The announcement arrived and the body has not — so draw NOTHING**
      ;; (app.rs:9525-9542). This drew `[{kind} — content not loaded]` in red,
      ;; one line per row, which was tolerable while the state lasted a frame in
      ;; the middle of a turn. A fork makes it intolerable: `/reseat` carries the
      ;; whole conversation across and publishes an announcement for every item
      ;; before a single body follows, so the operator gets thousands of them at
      ;; once — the reference's operator, on exactly this: *"i again so insane
      ;; amount of grainess with s- and whatever tool lines"*.
      ;;
      ;; A row with no body is not information, and a screen full of identical
      ;; placeholders is not a diagnostic — it is noise with the shape of one.
      ;; Both callers drop a render with no lines, so no lines is how a row says
      ;; "not yet".
      ((null body)
       ;; **UNLESS IT IS A PENDING PROMPT, WHICH DRAWS ITS OWN WORDS IN ITS OWN PLACE.** The
       ;; operator: *"you start replying while my message still queued."* This head knew the
       ;; text — it is in `head-queued` — and drew it only at the TAIL, **below the running
       ;; turn**, so their sentence sat under the reply already streaming above it. The row draws
       ;; it here instead, at the position the transcript gave it, which is above that reply.
       ;;
        ;; **AND IT NO LONGER WEARS THE `queued` MARK, WHICH IS THE SECOND HALF OF THE SAME REPORT.**
        ;; This branch used to hand the text to `queued-lines`, so a row the daemon had already
        ;; ANNOUNCED — appended to the transcript, by then in the model's own prompt, with its answer
        ;; streaming below it — still said *queued*. MEASURED on the operator's screen, and it is
        ;; their report verbatim: *"a message was queued to harnessd, delivered to model, reply
        ;; started streaming above the queued message and then some tick goes off and queued message
        ;; dequeued"* — *"pure ui desync"*, said twice.
        ;;
        ;; **The announcement IS the delivery.** The daemon appends the row at the step boundary and
        ;; publishes `TranscriptAppended` in the same breath (`engine.rs:1040`), and the prompt
        ;; reaches the model through that same append — so from this moment the message is in the
        ;; conversation and `queued` is a claim about a queue it has left. What is still pending is
        ;; the BODY, and the head does not need it to draw the row: it has the words (the binding)
        ;; and the time (the item's own `:ts`).
        ;;
        ;; **AND THIS REMOVES THE JUMP RATHER THAN MOVING IT.** Drawing the operator's own block here
        ;; makes the row's shape at announce the shape it keeps when the body lands, so the second
        ;; transition — the one the old rendering made at `transcript_content` — is gone too.
        ;; `%operator-block-lines` is the renderer the body path already uses, so the two agree by
        ;; construction rather than by being kept in step.
       ;; is drawing: one pending message, two places it can sit, and one shape for both.
       ;;
       ;; `*payload-head*` because `item-lines` is handed an item and a preference list and nothing
       ;; else — the arrangement every other row-level global here has. With no head in scope (a
       ;; test, a pane, a file measuring rows) the row draws NOTHING, which is what it drew before:
       ;; the fallback is the old behaviour rather than a guess.
       (let ((bound (bound-prompt-for item)))
         (when (and bound *payload-head*)
           (%operator-block-lines (%fold-cells bound) (%clock-time (item-ts item)) cols))))
      (t
       (let ((card (item-card item body)))
         (step-in-lines (card-lines card cols prefs)
                        (card-indent card cols)))))))


(defun tool-card-of (name &key item body)
  "The tool family a NAME belongs to — `%verb-kind` through the class table.

 Both factories meet here: `item-card` for a settled row (ITEM and BODY in hand)
 and `call-lines` for a live one (a NAME and no body), so the SAME call is the same
 CLASS on both sides of the wire and the verb and budget come from the same method."
  (let ((args (list :name name :item item :body body)))
    (case (%verb-kind name)
      ((:read)    (apply #'make-instance 'read-card args))
      ((:edit)    (apply #'make-instance 'edit-card args))
      ((:write)   (apply #'make-instance 'write-card args))
      ((:search)  (apply #'make-instance 'search-card args))
      ((:list)    (apply #'make-instance 'list-card args))
      ((:run)     (apply #'make-instance 'run-card args))
      ((:compact) (apply #'make-instance 'compact-card args))
      ((:fetch)   (apply #'make-instance 'fetch-card args))
      (t          (apply #'make-instance 'generic-tool-card args)))))


(defun item-card (item body)
  "The card class a row's BODY type selects.

 **`%key-from-wire` and not `(intern (string-upcase …))`** — the same trap the
 reading rung's predicate records: the wire spells `tool_result` and `segment_mark`
 with underscores, and a bare `intern` makes `:|TOOL_RESULT|`, a different symbol
 from `:tool-result`. The keys below are the hyphenated spellings `%key-from-wire`
 produces, and an unknown type falls to `unknown-card`, which draws what `(t nil)`
 drew."
  (let ((kind (%key-from-wire (getf body :type))))
    (case kind
      ((:user)          (make-instance 'user-card :item item :body body))
      ((:assistant)     (make-instance 'assistant-card :item item :body body))
      ((:reasoning)     (make-instance 'reasoning-card :item item :body body))
      ((:tool-result)   (tool-card-of (getf body :name) :item item :body body))
      ((:system)        (make-instance 'system-card :item item :body body))
      ((:segment-mark)  (make-instance 'segment-mark-card :item item :body body))
      ((:fetched)       (make-instance 'fetched-card :item item :body body))
      ((:note)          (make-instance 'note-card :item item :body body))
      (t                (make-instance 'unknown-card :item item :body body)))))

