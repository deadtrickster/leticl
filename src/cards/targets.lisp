;;;; cards/ — the card vocabulary, one transcript row at a time: what a row IS
;;;; (`item-lines` for a committed one, `call-lines`/`turn-lines` for the live
;;;; turn), what it is DRAWN as, and the cards that ride above the composer.
;;;;
;;;; **The module was one 4,800-line `cards.lisp` and is now one file per CARD** —
;;;; `edit-card.lisp` holds the edit card, `user-card.lisp` the operator's rows,
;;;; `tool-result-card.lisp` the settled tool row and its families — plus the files
;;;; holding what the cards SHARE (`protocol` the classes and generics, `targets`
;;;; what a call names, `roles` the words and budgets, `decisions`, `payload`,
;;;; `hidden-run`, `memo`) and the door (`item-lines`). `leticl.asd` lists them in
;;;; dependency order; each file's own header says what it holds and why.
;;;;
;;;; An item is a WIRE PLIST and never an object (PLAN.md D4, §7): a model must
;;;; be able to read exactly what the daemon sent. To render a row type this head
;;;; has never seen, specialise on the kind — a class and a method now, not a
;;;; `case` arm — and leave the data alone: HACKING.md, "Wire state stays a plist".

(in-package #:leticl)

;;; ------------------------------------------------------- display targets ;;;
;;;
;;; Ported from `sessionlog::display_target`. **Why it is derived and not
;;; tool-supplied**: the tool knows which of its arguments a person reads, and
;;; `ToolCallProposed` is emitted from the PARSED call before anything has been
;;; dispatched — so the daemon's own `target` is a derivation of the arguments it
;;; already has, and a head that renders a settled row (whose proposal it never
;;; saw: it attached after the turn, or switched into the session) has to do the
;;; same derivation from the same input. Two spellings of one display is how they
;;; drift, so this is the one spelling.
;;;
;;; The rules, and the reason for each:
;;;
;;;  · `path`, `file_path`, `file` name a call's SUBJECT. A tool whose subject has
;;;    another name keeps the written order — except that if the loop never
;;;    reached a subject key, the first one is PREPENDED: a write's `content` is
;;;    huge and buries the `path` behind it, so the file leads and the content
;;;    head follows;
;;;  · a string with whitespace is QUOTED, so `grep "two words" src` cannot be
;;;    misread as three arguments;
;;;  · nested values are ELIDED, never flattened: `[…]` and `{…}` say there is
;;;    more without pretending a JSON dump is a label — **and a nested value is a
;;;    PLACEHOLDER, not a part, so a row that already names a SUBJECT does not
;;;    draw one.** See `display-target`: what a `[…]` points at is the card drawn
;;;    directly underneath it, so beside a file name it spends four characters of
;;;    the most valuable space on the row saying nothing. It stays exactly where
;;;    the row would otherwise be empty or a bare modifier — `todo_write` sends
;;;    `{todos: […]}` and nothing else, and that label has no other source.

(defparameter *target-max-cols* 2048
  "How many COLUMNS of a call's subject this head will KEEP for a row.

**Not a display width, and that is R25.** This parameter was 120 and was where the
elision happened: `display-target` cut every subject to 120 columns at the moment the
head derived it, and the row then drew that string. So a 227-column pane drew a
120-column subject with ~36 columns of headline around it and **threw away seventy
columns of the viewport it had been given** — the operator's report: *\"some commands
head lines like 'Ran blabla' truncate too early — they dont use the whole conversation
history viewport, unlike say thinking.\"* Measured before the fix, one event, three
viewports: the headline was 77 columns at 80, 137 at 140, and **156 at 227** — it grew
and then stopped, pinned by this number instead of by the room the row had.

**The elision is the VIEWPORT's now, and it happens at DRAW time.** `%shorten-subject`
in `%tool-result-lines` cuts the subject to `(cols - gutter - indent - lead - tail)`,
which is exactly what that row has left after its own mark, verb, outcome and
duration — so the subject gets the whole remainder and no more. Two consequences worth
naming: a wider pane gets more of the subject back, and a narrower one gives it up,
because nothing stored here remembers a width.

**Why a bound at all, when the daemon has one.** Two of the three sources are bounded
by the wire (`TARGET_MAX_BYTES`, 2048 bytes) but the third is not: the head re-derives
a subject from an assistant row's `arguments` JSON, and `ToolCall.arguments` is
uncapped BY DESIGN on letibot's side — *\"the exact bytes are what must be replayed to
keep the prefix stable\"*. So one string per call id would otherwise be as long as the
model's largest argument, for the life of the session.

**The number is letibot's own wire bound, in this head's unit**, and it is chosen so
that this bound can never be the binding constraint: **2048 BYTES is at most 2048
COLUMNS** (ASCII is one column per byte, CJK two columns per three bytes, emoji two per
four), so the head keeps everything a daemon can send, whole. The same argument from
the other side fixes it too: an 8K display at a small monospace font is ~960 columns,
and 2048 covers that with 2× spare — letibot's own reasoning for the byte bound,
applied to the unit this head counts in.

**Columns, and the unit is still the point (§3.3).** The two heads agreed on 120 and
disagreed about what *of*: the reference counts BYTES (`s.len()`, `is_char_boundary`,
`event.rs`) and this head counted CHARACTERS (`(length clean)`), and both are wrong in
opposite directions for text that is not ASCII — measured on the same subject:

| subject | reference | this head, before |
|---|---|---|
| 121 ASCII characters | 117 + `…` (118 columns) | 117 + `…` — the same |
| a subject carrying `0x9B` | stripped | **kept** — the two measured it differently |
| 61 `中` (122 columns) | 39 + `…` (79 columns) | **all 61 (122 columns)**, untruncated |
| 40 `🙂` (80 columns) | 29 + `…` (59 columns) | **all 40 (80 columns)** |

Counting characters lets a wide subject EXCEED the budget — 61 CJK characters are 122
columns — which is the exact failure a cap exists to prevent and the one this tree
spent `W1` learning about rendering. Counting bytes under-fills it by a factor of two.
The bound is about how much room a row has, so it is measured in the unit the row is
drawn in, and `truncate-to-width` is the same instrument every other row here uses.")

(defparameter *subject-keys* '(:path :file-path :file)
  "The keys that name a call's subject, in preference order.

KEYWORDS, because objects decode to keyword-key plists (`json.lisp`) — an
arguments string is JSON like any other, so `{\"path\": \"a\"}` arrives as
`(:PATH \"a\")` and a string comparison against \"path\" would never match.")

(defparameter *body-keys* '(:content)
  "Argument keys whose value is a file's whole BODY rather than a label: **not part of the subject.**

**THE SAME ARGUMENT THE NESTED PLACEHOLDER IS DROPPED ON, one case further out.** A nested value is
a pointer at the card drawn underneath the row; a write's `content` IS the card drawn underneath the
row — the edit excerpt is a diff of it. Spending the row's best columns restating it, quoted and
escaped, is the operator's own report from their screen (2026-10-04):

    ▾ Wrote \"repl: the eval socket's own surface, as a pane — `/lisp`\\n\\nHACKING.md's contract…\" · ok · 1ms · 1 line
        /tmp/letibot-scratch-2197601/repl-msg.txt (new)

two rows, and **neither of them is a headline a person can use**: the body's first forty characters
are not a filename, and the file only appears on the row below, in cyan, as a thing the diff drew.
What the row is FOR is `Wrote <file>`.

**Only when a subject named the row**, the guard the nested rule keeps and for the same reason: a
call with a body and no path has nothing else to be labelled by, and its body is then the honest
label — a nested value is a placeholder, not a part, unless it is the only thing there is.")

(defun %json-object-p (x)
  "A decoded JSON object: the repo's own plist test, which is what closes the
object/array ambiguity (PLAN §7)."
  (%plist-p x))

(defun %debug-quote (s)
  "S as Rust's `{:?}` prints a string: quoted, with `\\n`, `\\t`, `\\\"` and `\\\\`
written as escapes.

The reference's `display_target` quotes a whitespace-bearing argument this way,
so a heredoc command reads `<<'MSG'\\nthe step…` on its screen. Ours used `~s`,
which prints the newline itself, and `truncate-target` then flattened it to a
space — so the same call read `<<'MSG' the step…` here, one of the differences a
side-by-side of the two heads showed."
  (with-output-to-string (o)
    (write-char #\" o)
    (loop for c across s
          do (case c
               (#\" (write-string "\\\"" o))
               (#\\ (write-string "\\\\" o))
               (#\newline (write-string "\\n" o))
               (#\tab (write-string "\\t" o))
               (#\return (write-string "\\r" o))
               (t (if (< (char-code c) 32)
                      (format o "\\u{~(~x~)}" (char-code c))
                      (write-char c o)))))
    (write-char #\" o)))

(defun %scalar-label (json)
  "One scalar value as a label, or :elided for a nested one."
  (cond
    ((null json) "null")
    ((stringp json)
     ;; quoted when it has whitespace, so `grep \"two words\" src` cannot be
     ;; misread as three arguments
     (if (find-if (lambda (c) (member c '(#\space #\tab #\newline))) json)
         (%debug-quote json)
         json))
    ((numberp json) (format nil "~a" json))
    ((eq json t) "true")
    (t :elided)))

(defun %elision-of (json)
  "How a nested value is shown when it is the only thing there is: `[…]` for an
array, `{…}` for an object."
  (if (%json-object-p json) "{…}" "[…]"))

(defun %part (v)
  "V as one part of a display label: its text, or `(:nested . V)` for a value that
is not scalar. The CALLER decides whether a nested one is drawn at all.

A cons and not a marker symbol, because the elision's own text depends on V — an
array says `[…]` and an object says `{…}` — so the part has to carry the value it
came from."
  (let ((label (%scalar-label v)))
    (if (eq label :elided) (cons :nested v) label)))

(defun %part-text (part subject-seen)
  "PART as text, or NIL when it is not to be drawn.

**The one rule about a nested part**: it is drawn only when the arguments named no
subject. A subject is what the row is ABOUT — for an `edit` the file, for a `read`
the file — and the nested value's own content is the card drawn directly underneath
it, so the placeholder spends the best position on the row announcing what the
reader is already looking at. Where there is no subject it is the only thing the
label CAN say, and it stays: `todo_write` sends `{todos: [...]}` and nothing else."
  (if (consp part)
      (and (not subject-seen) (%elision-of (cdr part)))
      part))

(defun %control-char-p (c)
  "C is a character that must never reach the terminal from a label: C0, DEL, C1.

**C1 belongs here and was missing** — `U+0080`–`U+009F`, of which `0x9B` is the
8-bit CSI. It used to be stripped by the reference and not by this head (`(char< c
#\space)` covers C0 and 127 is DEL, and nothing covered 128–159), so the two heads
measured the same target differently, which is the whole of §3.3. Measured: `0x9B`
does not reach the terminal — its width is 0 and the painter drops it — but a string
carrying one `truncate-to-width`s to a different answer here than there, and two
heads that disagree about how wide a label is will place the same row differently.

Rust's `char::is_control` is exactly this set (`event.rs:426`), so the three ranges
are written out rather than reached for through a Unicode table."
  (or (char< c #\space)
      (= (char-code c) 127)
      (<= #x80 (char-code c) #x9f)))

(defun truncate-target (s)
  "S flattened of control characters, then cut to `*target-max-cols*` columns.

**The cut here is the KEEP bound, not the elision** (R25). It bounds what the head
holds per call; the elision a reader sees is `%shorten-subject`'s, at the width of the
row being drawn. See `*target-max-cols*`.

The ellipsis counts, which both heads already agreed on and which `truncate-to-width`
is written around: a bound that forgets the mark is a bound the output is allowed to
exceed, which is the off-by-a-few that puts a line one column past the terminal and
scrolls the frame. The unit is COLUMNS for the same reason.

Control characters go FIRST, before anything is measured: a newline inside a header
would put a row on the screen the head did not count, and a tab measures as one column
and draws as eight (`%control-char-p`)."
  (truncate-to-width
   (map 'string (lambda (c) (if (%control-char-p c) #\space c)) s)
   *target-max-cols*))

(defun display-target (arguments)
  "The one argument a person reads, from a tool call's ARGUMENTS string.

**It composes the subject and does not elide it for a screen** (R25): the result is
bounded only by `*target-max-cols*`, the head's keep bound, and the elision a reader
sees happens in `%shorten-subject` at the width of the row being drawn. A caller that
is about to DRAW this must give it a width."
  (let ((json (ignore-errors (json-decode (or arguments "")))))
    (cond
      ;; not JSON at all: the model wrote it, so it is still the most
      ;; informative thing available
      ((null json) (truncate-target (string-trim " " (or arguments ""))))
      ((%json-object-p json)
       (let ((parts nil)                 ; `(KEY . PART)`, in written order
             (subject-entry nil))       ; the FIRST subject key's entry — it leads
         ;; `on JSON`, not `on (cdr JSON)`: a plist's pairs are the WHOLE list.
         ;; Taking the cdr binds the first VALUE as a key and leaves the first
         ;; pair unread, so every target came out `null` — measured against
         ;; letibot, whose cards said `Ran "cd /tmp/…"` while ours said `Ran "null"`.
         (loop for (k v) on json by #'cddr
               do (let ((entry (cons k (%part v))))
                    (when (and (member k *subject-keys*) (null subject-entry))
                      (setf subject-entry entry))
                    (push entry parts)))
         (setf parts (nreverse parts))
         ;; **THE SUBJECT LEADS, AND IT ALWAYS DID IN THE COMMENT.** What stood here moved it to the
         ;; front only when the loop had NOT reached one — `(and (not subject-seen) subject-value)` —
         ;; and that condition could never be true: `subject-value` was assigned inside the same
         ;; `when` that set `subject-seen`. So the parts stayed in WRITTEN order, and MEASURED on the
         ;; operator's own screen that is a row about nothing: their `write` sent `content` first,
         ;; so the headline was the first forty characters of a five-kilobyte file and the PATH was
         ;; elided off the end of the row (`*target-max-cols*` is a KEEP bound, and it cut there).
         ;; The file is what a person reads: it is first, and the body is not on the row at all.
         ;; See `*body-keys*` for the second half and for the screen it came from.
         (when subject-entry
           (setf parts (cons subject-entry
                             (remove-if (lambda (e)
                                          (or (eq e subject-entry)
                                              (member (car e) *body-keys*)))
                                        parts))))
         ;; **and a nested part is dropped when a subject named the row.** The
         ;; ruling (R15, the operator): a batch `edit` writes its `edits` array
         ;; before its `path`, so the placeholder took the row's best position to
         ;; point at the diff drawn underneath it. Not moved, not reordered —
         ;; gone; the file is the label, and the line this draws is that a nested
         ;; value is a placeholder, never a peer of a subject.
         (let ((subject-seen (and subject-entry t)))
           (truncate-target
            (string-trim " "
                         (format nil "~{~a~^ ~}"
                                 (loop for e in parts
                                       for text = (%part-text (cdr e) subject-seen)
                                       when text collect text)))))))
      ;; an array is not a label
      ((consp json) (truncate-target "[…]"))
      (t (let ((label (%scalar-label json)))
           (truncate-target (if (eq label :elided) "{}" (or label ""))))))))


;;; ------------------------------------------------------- the item-id maps ;;;
;;;
;;; ## Why this exists
;;;
;;; The live card knows three things the settled row does not: how long the call
;;; took, both sides of the file it changed, and the decision that gated it. A
;;; `TranscriptItem::ToolResult` carries the tool's prose and **no timestamps at
;;; all** (`edit` is display-only, lib.rs:74), so the moment the row lands those
;;; facts leave the screen — which is exactly what happened, and the operator
;;; reported it twice: *"nothing really shown"*, and *"past edits lose their diff
;;; panels"*.
;;;
;;; ## Why the key is the item id and not the call id
;;;
;;; A call id is **round-positional**: the engine assigns `call_{n}` from the
;;; round's own call list, so every round of every turn starts again at `call_0`.
;;; A table keyed on it alone has all fourteen rounds of a long turn writing the
;;; same three keys, and every settled card reads back whichever round wrote last
;;; — which is how a head comes to name a file the tool never opened. An item id
;;; is unique per row, so it cannot do that.
;;;
;;; Both are defvars, not `head` slots: a defstruct layout change is a hard error
;;; in this SBCL, so a slot would mean a restart.

(defvar *call-facts* nil
  "Alist CALL-ID → plist of what the live turn knows about one call: `:ms` (how
long it ran), `:edit` (both sides of the file it changed), `:decision` (what
gated it).

Keyed by the ROUND-POSITIONAL call id, so it is cleared at every round boundary
(`%round-boundary`). It is a STAGING table: facts land here from `tool_finished`
and `decision_answered`, and move to `*item-facts*` under the row's item id when
the transcript row arrives with its body.")

(defvar *item-facts* nil
  "Alist ITEM-ID → the same plist, once the row it belongs to exists.

The durable half, and what `%tool-result-lines` reads: this is what keeps a
settled row's diff, duration and approval on the screen after the live card is
gone. An item id is unique per row, so two rounds cannot collide here.")

(defvar *call-started-ms* nil
  "Alist CALL-ID → the monotonic ms when its ToolStarted arrived, for calls THAT ARE STILL
RUNNING.

Neither `tool_finished` nor the row that lands afterwards carries a duration, so
the only way to keep *\"that grep took 4.1 s\"* on the screen is to have noted
when it began.

**AND THE ENTRY LEAVES WHEN THE CALL DOES.** It used to be kept to the end of the round,
and that made \"is this call running?\" unanswerable from here — a finished call still had a
start time, so the only way to tell the two apart was to ask the turn, which the row renderer
cannot reach. `note-call-finished` moves the entry into `*call-facts*` (where the duration now
lives, for the settled row), so **a key in this table means exactly one thing: this call
started and has not finished.** That is the predicate the transcript's `◐` row needs, and it
is why the running row can be drawn from a plain `item-lines` with no session in hand.")

(defun note-call-started (call-id)
  (when call-id
    (setf (alexandria:assoc-value *call-started-ms* call-id :test #'string=)
          (internal-real-time-ms))))

(defun %call-running-p (call-id)
  "Has CALL-ID started and not yet finished — see `*call-started-ms*`."
  (and call-id (numberp (cdr (assoc call-id *call-started-ms* :test #'string=)))))

(defun note-call-finished (call-id &key edit)
  "Fold what ToolFinished carried into the staging table.

The facts plist is written THROUGH the place, never bound to a local first:
`(let ((f (assoc-value table k))) (setf (getf f :ms) …))` mutates the local and
leaves the table untouched, which is how the first version of this recorded
nothing at all while looking like it recorded something. A test caught it."
  (when call-id
    (let ((start (cdr (assoc call-id *call-started-ms* :test #'string=))))
      (when (numberp start)
        (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :ms)
              (max 0 (- (internal-real-time-ms) start)))))
    ;; **and the call stops being RUNNING here**, which is the same moment it stops spending
    ;; time. The duration moved into the facts table above, so keeping the start entry would
    ;; leave a key that no longer answers the question it is asked — and *"has this started and
    ;; not finished?"* is asked of every unanswered proposal on the screen.
    (setf *call-started-ms*
          (remove call-id *call-started-ms* :key #'car :test #'string=))
    (when edit
      (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :edit)
            edit))))

(defun note-call-decision (call-id decision)
  "Attach the settled decision to its call, so a settled row shows what gated it."
  (when call-id
    (setf (getf (alexandria:assoc-value *call-facts* call-id :test #'string=) :decision)
          decision)))

(defun %round-boundary ()
  "A round is over: the call ids in the staging table are about to be reused.

Called when an Assistant row lands, which is what delimits a round — the engine
appends a round's assistant row before generating the next, so no delta of round
N+1 can arrive before round N's row."
  (setf *call-facts* nil
        *call-started-ms* nil))

;;; --------------------------------------------------------- call targets ;;;
;;;
;;; A `ToolResult` row carries `call_id, name, outcome, payload, edit` — and NOT
;;; what the call was about. The answer is on the ASSISTANT row that proposed it,
;;; under the same `call_id`, so the target has to be correlated.
;;;
;;; This model's ids are unique per call (`call_00_AU1w4hjdLQNw13o3SNIo9409`,
;;; measured off the wire), so a plain map works. The reference's note about ids
;;; being ROUND-POSITIONAL is about the fallback it applies when the wire carries
;;; no id at all — `format!("call_{}", calls.len())` — which would make a map keyed
;;; on it collide across rounds. Worth knowing which case you are in, so the map
;;; is cleared at a round boundary either way.

(defvar *call-targets* nil
  "Alist CALL-ID → display target, from every assistant row and every live
proposal this head has seen. Cleared at a round boundary so a positional id
could not collide.") 

(defun note-call-target (call-id target)
  (when (and call-id target (plusp (length target)))
    (setf (alexandria:assoc-value *call-targets* call-id :test #'string=) target)))

(defun call-target-of (call-id)
  (and call-id (cdr (assoc call-id *call-targets* :test #'string=))))

(defun note-assistant-targets (body)
  "Record the display target of every call BODY proposed.

BODY is a `TranscriptItem::Assistant` plist. Its `:tool-calls` are the daemon's
own parsed calls, each with a `:arguments` JSON string — so the SAME derivation
the daemon does (`display-target`) is applied to the same input, which is what
keeps the live card and the settled row saying one thing."
  (dolist (tc (getf body :tool-calls))
    (when (and (consp tc) (getf tc :id))
      (note-call-target (getf tc :id)
                        (display-target (getf tc :arguments))))))

(defun note-snapshot-answered (items)
  "Record every call that HAS a result in ITEMS, so the assistant row above it
does not draw the proposal as well."
  (dolist (item (coerce items 'list))
    (let ((body (getf item :item)))
      (when (and (consp body) (string= (getf body :type) "tool_result"))
        (note-answered-call (getf body :call-id))))))

(defun note-snapshot-targets (items)
  "Walk a SNAPSHOT's items once, recording every assistant row's call targets.

One pass at attach, because a head that attached after a turn has no proposals to
learn from — the row is the only place the call is described. Without this every
settled row older than the attach would render with no target at all.

**And the same walk is what a PUSH needs** — see `refresh-call-targets`: a target is
DERIVED from the arguments by code, so redefining that code leaves every recorded target
saying what the previous version said."
  (dolist (item (coerce items 'list))
    (let ((body (getf item :item)))
      (when (and (consp body) (string= (getf body :type) "assistant"))
        (note-assistant-targets body)))))

(defvar *call-targets-generation* 0
  "The `*code-generation*` the targets in `*call-targets*` were DERIVED under.

**THE THIRD CACHE WITH THIS SHAPE, and it is the one a reader actually sees.** A target is not
what the arguments say — it is what `display-target` makes of them — so a push that redefines the
derivation leaves every recorded target holding the OLD reading, and `*call-targets*` is a defvar
that outlives the push. MEASURED, on the push that fixed the write card's subject: the head's own
row for `/tmp/…/dbg7.lisp` still answered the file's CONTENT after the fix landed, because the
target had been derived before it.

The other two are `*repo-todo-cache*` (which reads `*code-generation*` itself) and the item memo's
stamp (which reads it too, added with this). A `defvar`, so a push does not drop the table it
belongs to.")

(defun refresh-call-targets (head)
  "Re-derive every target when the CODE that derives them has moved. T when it did.

One comparison a frame and one walk per PUSH — not per frame, which is why the generation is
remembered rather than recomputed: the walk is over the session's rows, and the frame path may not
pay that twice.

**It does not CLEAR the table first, deliberately.** The walk covers the rows this head HOLDS, and
the ids above that window keep their old reading rather than losing their target entirely — a row
older than the window draws `(call-id)` for its subject either way, and one of the two is a
re-derivation away from being right. The alternative — an empty table — costs every fetched row its
subject until it is scrolled past again."
  (when (> *code-generation* *call-targets-generation*)
    (setf *call-targets-generation* *code-generation*)
    (note-snapshot-targets (session-items (head-session head)))
    t))

(defun item-facts (item-id)
  "What the live turn knew about the row ITEM-ID, or NIL."
  (and item-id (cdr (assoc item-id *item-facts* :test #'string=))))

(defun %adopt-call-facts (item-id call-id)
  "Move the staging facts for CALL-ID onto ITEM-ID, once the row exists.

This is the handover: the row is now the durable artifact, so the facts have to
be reachable from the ROW rather than from a call id that the next round will
reuse."
  (when (and item-id call-id)
    (let ((facts (cdr (assoc call-id *call-facts* :test #'string=))))
      (when facts
        (setf (alexandria:assoc-value *item-facts* item-id :test #'string=)
              (copy-list facts))))))

(defvar *pane-scroll* 0
  "Rows hidden ABOVE THE TOP of an open pane.

**The polarity is the opposite of `head-scroll` and that is not a detail.**
`head-scroll` counts rows back from the BOTTOM — it is a distance from the live
tail, so `up` increases it. A pane has no live tail: it is a fixed list, and its
offset is a distance from the START, so `down` increases it. Copying the
transcript's polarity makes PageDown a no-op that looks exactly like the bug it
replaced, which is how the reference found it — in its own test, after shipping
the wrong sign once.

One offset for every pane, because only one is open at a time. A per-pane offset
would be a `head` struct slot each, and a slot is a restart.")

(defvar *pane-lines* 0
  "How many lines the open pane's content has. The render sets it so the KEY
handler can clamp without re-rendering, and `*pane-room*` is how many of them fit.")

(defvar *pane-room* 0
  "How many rows the open pane's content may occupy, from the last render.")

(defun pane-scroll-max ()
  "The largest offset that still shows something."
  (max 0 (- *pane-lines* *pane-room*)))

(defun pane-scroll-by (n)
  "Move the pane by N rows, clamped to its content."
  (setf *pane-scroll* (max 0 (min (pane-scroll-max) (+ *pane-scroll* n)))))

(defun reset-pane-scroll ()
  "A newly opened pane starts at its top."
  (setf *pane-scroll* 0))

(defun pane-view (lines)
  "LINES, windowed by `*pane-scroll*` to `*pane-room*` rows.

The pane's own window function rather than `%place-lines`, because that one
clips from the top and a pane must be able to look past it. Returns the slice,
so the caller places it from the top of the body."
  ;; `let*`, not `let`: START's init form uses ROOM, and under `let` the init
  ;; forms are evaluated in the OUTER environment — so `room` would be a free
  ;; reference to cl:room, unbound. Same defect as `%render-and-paint`'s earlier
  ;; in this pass, and the same silent shape: it compiles.
  (let* ((room (max 1 *pane-room*))
         (start (max 0 (min (max 0 (- (length lines) room)) *pane-scroll*))))
    (subseq lines start (min (length lines) (+ start room)))))

(defun scroll-pane-into-view (sel)
  "Move the offset so the cursor on row SEL is visible.

The cursor scrolls ITSELF into view: a pane whose cursor can walk into rows that
are never drawn is a pane with a selection the operator cannot see, which is worse
than one that cannot scroll at all."
  (let ((room (max 1 *pane-room*)))
    (cond ((< sel *pane-scroll*) (setf *pane-scroll* sel))
          ((>= sel (+ *pane-scroll* room))
           (setf *pane-scroll* (max 0 (- (1+ sel) room)))))))

