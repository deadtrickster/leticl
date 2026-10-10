;;;; user-card.lisp — a `user` row, drawn by WHO SPOKE (R42): the operator block, the
;;;; session's own rows, and the parts a message carries.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

(defclass user-card (card) ())

(defparameter +session-label+ "session · "
  "The word a row THIS SESSION appended carries — R42's `agent` speaker.

**In the place `queued ·` takes on an echo**, and for the same reason: a row nobody can
attribute is the defect, not the fix. Faint, because it is the head talking about its own
origin rather than content — the register R29's rule gives every sentence a reader could
delete with no loss.")

(defun %user-speaker (body)
  "WHO spoke this user row — R42's whole question, and the wire's three answers.

Returns `:operator`, `:agent`, `:unrecorded`, or `(:other . \"word\")` for a speaker this build
does not know.

**THE RULE IS ADDITIVE, and that is the operator's own correction of their first ruling — recorded
here because the first ruling is the one a reader would otherwise reconstruct from the field's
name.** They said: *\"a User row with no speaker is not 'the operator', it is 'not recorded' — draw
it as the operator only when the field says so.\"* Applied to the `▌` BLOCK, that made every user
row on every running daemon draw as plain prose, including the operator's own and their next one.

**The error is precise and it generalises: the block is not a claim about who spoke.** It is the
SHAPE of a user-kind row, and it has never said *operator* — it says *this is an item of user kind*.
What must not be asserted without the field is **the WORD `operator`, or any label naming a
speaker**. So the field ADDS a mark; it does not remove a rendering from every row that predates
it:

  · **no `speaker` at all** — drawn EXACTLY as it always was. The block, no label, no claim, no
    regression. Every historical row in every log, and every row on a daemon that does not send
    the field yet.
  · **`agent`** — the mark that says so: no block, the faint `session · ` label.
  · **`operator`** — the block, which is the operator's mark and was already theirs.
  · **any other word** — that word in the label's own place, rather than falling back to the
    operator's colour.

`:unrecorded` is still its OWN answer rather than `:operator`, because *absent* and *the operator*
are not the same FACT — the argument `%call-origin-said` makes one row over, and the reason
`%call-origin-said` does not render an absent `origin` as the model either. The two differ in what
they mean, not in which block they draw: the label is where a claim about a speaker would go, and
absence puts nothing there.

**letibot's wire defaults an absent `speaker` to `operator` for its own reader** (`Speaker::default`),
which is the honest reading FOR THE DAEMON — a row it wrote before the field cannot say who spoke,
and the reading available to it is the one it already acted on. This head reaches the same SHAPE by
the additive route instead, which is the difference between *drawing what was always drawn* and
*asserting a speaker nobody recorded*.

The values are the authorisation trail's own words (`operator`, `agent`), so a row and the record
the oracle reads cannot spell one speaker two ways."
  (let ((s (getf body :speaker)))
    (cond
      ((null s) :unrecorded)
      ((stringp s)
       (cond ((string-equal s "operator") :operator)
             ((string-equal s "agent") :agent)
             ;; **A word this build does not know still NAMES somebody.** The field exists so that
             ;; a row the session wrote is not drawn as the person's, so an unrecognised speaker
             ;; renders its own word rather than falling back to the operator's — the rule
             ;; `%call-origin-said` keeps for `origin`, where *a wrong colour is worse than none*.
             (t (cons :other s))))
      (t :unrecorded))))

(defparameter +operator-block-style+ '(:bold t)
  "The register the operator's OWN message is drawn in, the blue bar excluded.

**Ours, and NOT letibot's** — the one place in the frame where the two heads deliberately differ,
and the operator asked for it: *\"my own messages — they jump out too much, i like the blue bar on the
left, but inverted colors look too much. Maybe we can try to render my messages more calm? like blue
bar stays and my messages come in bold?\"*

The reference draws the message in REVERSE VIDEO (`Role::UserBlock` is `ESC[7m`), and its style
module says why with some care: *\"there is no light-mode and no dark-mode here … it names it as `7`
(reverse video), which asks the terminal to swap its own two colours. That is self-consistent under
any theme by construction.\"* That argument is sound and it is not an argument against this: a bold
message is self-consistent under any theme too, because bold is an attribute and not a pair. What it
gives up is the *block* — the filled rectangle that says this is a different voice at a glance — and
the operator has read both and prefers the quiet one.

A `defparameter` so the choice is one edit and a live push, and named for what it is rather than
inlined at the draw site, because a register that lives in two places is two registers.")

(defun %operator-block-lines (text stamp cols)
  "THE OPERATOR'S OWN MESSAGE — a blue `▌` bar, the message in `+operator-block-style+`, the
timestamp right-aligned on the first row.

**The bar is the claim that the person spoke**, and it is `Role::UserAccent` (`ESC[34m`) as letibot
has it. What follows it is ours: see `+operator-block-style+` for the register and for the argument
the reference makes for its own.

Measured off letibot's screen, the differences a screenshot shows and a test does not:

  · a BLUE `▌` bar, not a cyan `›`;
  · the message PADDED to the full width, so it reads as a block rather than a ragged line; and
  · the timestamp right-aligned on the FIRST row, which is why that row is wrapped narrower than
    the rest.

The padding stays even now that the fill is gone: the rows are the same width either way, so the
next row's wrap cannot depend on which register the operator chose."
  (let* (;; the first row shares its width with the timestamp
         (head-cols (max 8 (- cols 2 (length stamp) (if (plusp (length stamp)) 1 0))))
         (rows (wrap-segments (list (cons text nil)) head-cols))
         (rows (if rows rows (list (list (cons "" nil))))))
    (loop for row in rows
          for i from 0
          for row-text = (format nil "~{~a~}" (mapcar #'car row))
          for pad = (max 0 (- (max 0 (- cols 2)) (string-width row-text)
                              (if (and (= i 0) (plusp (length stamp)))
                                  (string-width stamp) 0)))
          collect (list (cons "▌" '(:fg :blue))
                        (cons " " nil)
                        (cons (format nil "~a~a" row-text
                                      (make-string pad :initial-element #\space))
                              +operator-block-style+)
                        (cons (if (and (= i 0) (plusp (length stamp))) stamp "")
                              +operator-block-style+)))))


(defun %session-block-lines (text stamp cols label &optional item)
  "TEXT as a row THIS SESSION appended — R42's `agent` speaker, and letibot's `session_block`.

**The opposite of the operator's block in the three ways that block is made of**: no `▌` accent
bar, no raised background, and the FAINT register rather than theirs. What it keeps is the LABEL
— `session · `, in the faint register — because a row nobody can attribute is the defect this
exists to fix, and because a reader who sees a block they did not type needs to know what it is.

The timestamp CLOSES the last line rather than sitting on the first: the operator's block stamps
its first row because that row is the person speaking, and this row is a note about something
that happened, so the stamp goes where the sentence ends. The same `label` is reused so an
unknown speaker can name itself in the same place."
  (let* ((indent (make-string (length label) :initial-element #\space))
         (w (max 20 cols))
         (head-cols (max 8 (- w (length label) (length stamp) 2)))
         (settlement (%job-notice-p text))
         (window (and settlement item (payload-view-for item)))
         (texts
           (cond
             ;; **A JOB SETTLEMENT IS ONE LINE, AND IT OPENS.** The operator, looking at two of
             ;; their own screens: *"we have to do something with this huge job blobs - make them
             ;; one liners for conversation and Ctrl-t'able otherwise"* — and *"something like exit
             ;; code, time spent and some one-line summary will be just fine."*
             ;;
             ;; Every one of those facts is ALREADY IN THE DAEMON'S OWN SENTENCE — the job, how it
             ;; ended, how long it ran, how many bytes it wrote and its command (see
             ;; `%notice-card-lines`, which is what draws it) — so the line costs nothing and is
             ;; true by construction. That
             ;; is R37's ladder on a second surface, and it is why no model is in the path: a
             ;; summary would be a slower, lossier spelling of what arrived spelled out.
             ;;
             ;; The closing paragraph is dropped from the line because it is a promise TO THE
             ;; MODEL (*you do not need to wait for it*) and not something the reader needs told.
             ;; It is still there in full behind the chord, which is the point of the door.
             ((and settlement (not window))
              ;; **the SEAM'S ROOM IS RESERVED BEFORE THE FACTS ARE CUT.** The first cut built the
              ;; line as one string and truncated it, so on a notice whose facts fill the frame the
              ;; `· ctrl-t opens it` was cut away — the door invisible on exactly the rows that
              ;; needed it, and `Ctrl-t'able` is the operator's own word for what this owes them.
              ;; The facts give up the seam's width first, and the seam is ALWAYS kept.
              (let* (;; **the seam SHORTENS before the facts do.** At a narrow frame the full
                     ;; sentence costs sixteen of the reader's columns, and the facts are the
                     ;; content — so the door gives way to `· ctrl-t`, which still names the key.
                     ;; R29 asks that a remedy be visible; it does not ask that it be verbose.
                     (seam (if (>= head-cols 60) " · /t opens it" " · /t"))
                     (named (and item (newest-payload-row-p item) t))
                     (room (if named (max 8 (- head-cols (length seam))) head-cols))
                     ;; **the chord only on the row it acts on** (R40): the window opens on the
                     ;; NEWEST openable row, so a seam elsewhere would name a key that does
                     ;; nothing. Silence is the honest seam; a lie is not.
                     ;; **THE PARTS ARE THEIR OWN ROWS.** See `%notice-card-lines`: the headline is
                     ;; what it WAS — a job's command, an agent's task — and the result under it, with
                     ;; the id dropped. The door goes on the LAST row, where a sentence ends.
                     (card (%notice-card-lines text))
                     (lines (loop for l in card
                                  for i from 0
                                  for last = (= i (1- (length card)))
                                  collect (%truncate-segs
                                           (append (list (cons l nil))
                                                   (if (and named last)
                                                       (list (cons seam +role-faint+))
                                                       nil))
                                           (if (and named last) room head-cols)))))
                lines))
             ;; opened: the daemon's own message, whole, and the key that folds it back
             ((and settlement window)
              (append (%job-notice-rows text) (list "  … esc closes")))
             (t (list text))))
         (rows
           (cond
             ;; **ONE ROW, WHATEVER THE WIDTH.** A settlement's line is truncated to the frame
             ;; rather than wrapped, because *a one-liner that becomes four lines on a narrow pane
             ;; is not a one-liner* — and the facts come FIRST, so the cut eats the tail of the
             ;; command rather than the exit code, the duration or the byte count. The whole thing
             ;; is one chord away. The same rule the echo's seam keeps (R33): the ellipsis is the
             ;; fallback, never a second row.
             ((and settlement (not window)) texts)
             (t (mappend (lambda (s)
                           (or (wrap-segments (list (cons s nil)) head-cols)
                               (list (list (cons "" nil)))))
                         texts))))
         (rows (if rows rows (list (list (cons "" nil)))))
         (n (length rows)))
    (loop for row in rows
          for i from 0
          for row-text = (format nil "~{~a~}" (mapcar #'car row))
          collect (list (cons "  " nil)
                        (cons (if (zerop i) label indent) +role-faint+)
                        (cons (if (and (= i (1- n)) (plusp (length stamp)))
                                  (format nil "~a  ~a" row-text stamp)
                                  row-text)
                              +role-faint+)))))

(defun %user-parts-text (body)
  "A `TranscriptItem::User`'s parts as the one string the block wraps —
app.rs:8550-8558.

Two things this fixes, both of them invisible in the source and loud on screen.
The parts are joined with a **space**: ours concatenated them, so a two-part
message ran its parts together into a word that is in neither of them. And a
part that is not text is NAMED rather than skipped — `[image image/png]`,
`[file src/cards.lisp]` — because ours rendered those as the empty string, so an
attached image was a message the operator could see they had sent and could not
see they had attached anything to.

`item-display-text` (session.lisp) joined the parts with NOTHING, so two parts
were one word; it feeds search and the pane summaries, and it is another
strand's file. The RENDERING reads this one."
  (format nil "~{~a~^ ~}"
          (mapcar (lambda (p)
                    (switch ((or (getf p :kind) "text") :test #'string=)
                      ("image" (format nil "[image ~a]" (or (getf p :media-type) "")))
                      ("file_ref" (format nil "[file ~a]" (or (getf p :path) "")))
                      (t (or (getf p :text) ""))))
                  (getf body :parts))))


(defmethod card-lines ((card user-card) cols prefs)
  (let ((item (card-item card))
        (body (card-body card)))
    ;; **R42: A USER ROW SAYS WHO SPOKE, AND THE TWO ARE DRAWN DIFFERENTLY.**
    ;;
    ;; Everything this session injects is a `User` item — the operator's prompt, a head's
    ;; steering, a salvage notice, the intent check, a job settlement — so on the old wire
    ;; a completion was drawn exactly as the person typing. The operator: *"why job
    ;; completion events arrive as my messages?"*
    ;;
    ;; **And the security half is not decoration.** The oracle refuses to let agent text
    ;; authorise an action; a head drawing agent text as the operator's shows the READER the
    ;; exact lie the oracle is defended against, and the reader is the other party the gate
    ;; serves. See `%user-speaker` for the three answers and why absence is its own.
    (let ((text (%fold-cells (%user-parts-text body)))
          (stamp (%clock-time (item-ts item)))
          (who (%user-speaker body)))
      ;; **`cond` and not `case`**: an unknown speaker's answer is a `cons` naming the word,
      ;; and `case` matches its keys with `eql` — so `(:other "web-hook")` fell through the
      ;; `(:other)` arm to the not-recorded one and an unnamed-but-spoken row drew as
      ;; nothing. Measured on the four-speaker fixture, which is why it carries one.
      (cond
        ;; **`:unrecorded` DRAWS THE SAME BLOCK** (the additive rule): the block is the shape of a
        ;; user-kind row, not a claim about who spoke, so a row that predates the field keeps
        ;; exactly the rendering it always had. The distinction the field adds is a MARK — for
        ;; the session's own rows and for a speaker this build cannot name.
        ((or (eq who :operator) (eq who :unrecorded)) (%operator-block-lines text stamp cols))
        ;; **`item` travels, because a settlement's `ctrl-t` window is keyed on the row's id** —
        ;; the same arrangement the tool-result rows use, and the reason this takes one now.
        ((eq who :agent) (%session-block-lines text stamp cols +session-label+ item))
        ;; **AN UNKNOWN WORD NAMES ITSELF** rather than falling back to the operator's — the
        ;; rule `%call-origin-said` keeps for `origin`: a wrong speaker is worse than an
        ;; unusual one, and the row must not be drawn as the person's.
        ((and (consp who) (eq (car who) :other))
         (%session-block-lines text stamp cols (format nil "~a · " (cdr who))))
        (t (%operator-block-lines text stamp cols)))))
  )


