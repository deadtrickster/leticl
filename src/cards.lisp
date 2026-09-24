;;;; cards.lisp — the card vocabulary: one transcript row, one tool call, the
;;;; running turn, and the cards that ride above the composer.
;;;;
;;;; `item-lines` renders a committed transcript row and is what the viewport
;;;; is built from; `call-lines` and `turn-lines` render the live turn; the
;;;; decision, quit and secret cards are here because they are cards, while the
;;;; frame furniture is `chrome.lisp`.
;;;;
;;;; An item is a WIRE PLIST and never an object (PLAN.md D4, §7): a model must
;;;; be able to read exactly what the daemon sent. To render a row type this head
;;;; has never seen, specialise on the kind keyword and leave the data alone —
;;;; HACKING.md, "Wire state stays a plist".

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
       (let ((parts nil)
             (subject-seen nil)
             (subject-value nil))
         ;; `on JSON`, not `on (cdr JSON)`: a plist's pairs are the WHOLE list.
         ;; Taking the cdr binds the first VALUE as a key and leaves the first
         ;; pair unread, so every target came out `null` — measured against
         ;; letibot, whose cards said `Ran "cd /tmp/…"` while ours said `Ran "null"`.
         (loop for (k v) on json by #'cddr
               do (when (member k *subject-keys*)
                    (setf subject-seen t
                          subject-value (or subject-value v)))
                  (push (%part v) parts))
         (setf parts (nreverse parts))
         ;; a subject the loop never reached is PREPENDED: a write's content
         ;; buries its path, and the file is what a person reads
         (when (and (not subject-seen) subject-value)
           (push (%part subject-value) parts))
         ;; **and a nested part is dropped when a subject named the row.** The
         ;; ruling (R15, the operator): a batch `edit` writes its `edits` array
         ;; before its `path`, so the placeholder took the row's best position to
         ;; point at the diff drawn underneath it. Not moved, not reordered —
         ;; gone; the file is the label, and the line this draws is that a nested
         ;; value is a placeholder, never a peer of a subject.
         (truncate-target
          (string-trim " "
                       (format nil "~{~a~^ ~}"
                               (loop for p in parts
                                     for text = (%part-text p subject-seen)
                                     when text collect text))))))
      ;; an array is not a label
      ((consp json) (truncate-target "[…]"))
      (t (let ((label (%scalar-label json)))
           (truncate-target (if (eq label :elided) "{}" (or label ""))))))))

(defun %write-targets (d)
  "The paths a decision's action OPENS FOR WRITING, as a list of
`(:path STRING :unresolved BOOLEAN)`, or NIL when it opens none.

**The one place the two mechanisms meet** (R35), which is the whole of why this function exists:
a write made through the `write`/`edit` tool and a write made by a script the gate read out of a
heredoc body are the SAME FACT — *this action writes this file* — and a card that drew them from
two code paths would drift into two shapes for one fact. The operator's requirement is that a
reader comparing two cards must not have to know which mechanism produced them, so both arrive
here and are drawn once.

    · **the daemon's own field**, when it sends one: `write_targets`, an array of
      `{path, unresolved}`, on the same frame that carries `access` and `target`. That is the
      ask filed for it (R35's wire); until it arrives this branch is never taken, which is the
      same *inert without the row* shape R32's argument-kind has.
    · **the edit tool's own `target`**, which is already on the wire and already a path: when the
      action's declared `access` is `write` and the field is absent, the single `target` IS the
      write target. This is what makes today's edit card and the coming heredoc card one shape.

**An `unresolved` entry is NOT an absent one**, and the difference is the requirement's own
sentence: *a write whose target could not be read* is exactly the case the operator most needs to
see — `open(sys.argv[1], 'w')`, a path built from `pathlib.Path.home()`. A head that folded it
into *no write* would be throwing away the one fact a person cannot get any other way.

**A `write` access with no target and no field is NIL, not an empty entry.** That is a real case
(a tool that declares a write and names nothing) and it draws nothing, which is what every
daemon draws today."
  (let ((field (getf d :write-targets)))
    (cond
      (field
       (loop for w in field
             ;; the field is the daemon's, so its shape is read defensively: an entry that is
             ;; not an object, or one with neither a path nor the unresolved mark, is not a
             ;; target and is dropped rather than drawn as a blank row
             when (and (consp w)
                       (or (and (stringp (getf w :path)) (plusp (length (getf w :path))))
                           (getf w :unresolved)))
               collect (list :path (or (getf w :path) "")
                             :unresolved (and (getf w :unresolved) t))))
      ;; the edit tool's target, which is already a path on the wire
      ((and (equal (getf d :access) "write")
            (stringp (getf d :target))
            (plusp (length (getf d :target))))
       (list (list :path (getf d :target) :unresolved nil))))))

(defun write-target-lines (targets cols)
  "TARGETS (from `%write-targets`) as card lines, in the card's own target register.

**One drawing for both mechanisms**, at the place and in the style the single `target` has always
had — indented four, bold (see `permission-card-lines`, where *a command is the one thing here
worth the rows*). The first resolved path therefore renders BYTE FOR BYTE as today's edit card
renders its target, which is the operator's requirement made checkable rather than asserted.

**The count is said on the line that names them, and that is R25's rule at this surface.** The
paths themselves are content and elide to the card's viewport like any other content — the
viewport's seam counts rows, not files — so the number of FILES goes where no elision can reach
it: above them, as `N files:`, and only when there is more than one. A single write is unchanged,
which is why the edit card does not grow a header.

**An unresolved write is drawn in `+role-attention+`** — *somebody has to look* — and never in
the path register. The requirement's words: it is *the one the operator most needs to see*, and a
sentence that looks like a path is a sentence that gets skimmed past. The same role a tool row's
own `no result` takes, for the same reason: it is the row whose whole meaning is *this is not what
you think it is*.

**The count of unresolved writes is in the sentence**, not in a header of its own: one such write
says *a write whose target could not be read* and two say *2 writes whose targets could not be
read*, which is a number a reader cannot misplace."
  (let ((w (max 20 cols))
        (out nil)
        (resolved (remove-if (lambda (x) (getf x :unresolved)) targets))
        (unresolved (remove-if-not (lambda (x) (getf x :unresolved)) targets)))
    ;; the count, above the names, so a window cannot hide it
    (when (> (length resolved) 1)
      (push (list (cons (format nil "    ~d files:" (length resolved)) '(:dim t))) out))
    (dolist (x resolved)
      (dolist (l (wrap-text (format nil "    ~a" (getf x :path)) w))
        (push (list (cons l '(:bold t))) out)))
    ;; **and the unresolved ones say what they are.** One sentence, in the attention register,
    ;; with its own count when there is more than one.
    (when unresolved
      (dolist (l (wrap-text (if (= 1 (length unresolved))
                                "    ✎ a write whose target could not be read — the script builds it at runtime, so the gate cannot name the file"
                                (format nil "    ✎ ~d writes whose targets could not be read — the script builds them at runtime, so the gate cannot name the files"
                                        (length unresolved)))
                            w))
        (push (list (cons l +role-attention+)) out)))
    (nreverse out)))

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
settled row older than the attach would render with no target at all."
  (dolist (item (coerce items 'list))
    (let ((body (getf item :item)))
      (when (and (consp body) (string= (getf body :type) "assistant"))
        (note-assistant-targets body)))))

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

;;; ------------------------------------------------------- pane rendering ;;;
(defun %fold-cells (text)
  "A /cells message folds back out of the transcript at render time — the
reference's `fold_cells` (app.rs:8980-9001).

**The screen block is REPLACED, not marked.** The operator sent sixty rows of
their own terminal; redrawing those sixty rows inside this terminal is a picture
of a picture, and on a settled screen it is most of the transcript. What stays is
the operator's words and ONE line saying what went with them:

    · 63 rows of this screen (210x63) went with this message

Nothing is hidden that the line does not name, and the model still has every row
— the fold belongs to the RENDERING, not to what was sent.

Ours kept the marker head, appended ` …`, and kept whatever followed the close
marker: a different string, a different shape, and text the reference drops. The
size is read from the marker head's first token and the row count from the lines
between the two markers, which is why neither delimiter line is counted."
  (let ((at (search *cells-open* text)))
    (if (null at)
        text
        (let* ((rest (subseq text at))
               (after-open (subseq rest (min (length rest) (length *cells-open*))))
               (sp (position #\space after-open))
               (size (if sp (subseq after-open 0 sp) ""))
               (rows (loop for l in (rest (%payload-lines rest))
                           until (alexandria:starts-with-subseq *cells-close* l)
                           count t))
               (words (string-right-trim '(#\space #\tab #\newline #\return)
                                         (subseq text 0 at)))
               (note (format nil "· ~d rows of this screen (~a) went with this message"
                             rows size)))
          (if (zerop (length words))
              note
              (format nil "~a~%~a" words note))))))

;;; ------------------------------------------------------------- the roles ;;;
;;;
;;; The three of `crates/ui/src/style.rs` this file spells more than once, named
;;; so they cannot drift apart again. The pair that matters is the last two.

(defparameter +role-faint+ '(:dim t)
  "Role::Faint — `ESC[2m`, style.rs:157. *A fact a reader may skip.*

The fourth role this file needs, added for R19 part 2 and not borrowed from the
markdown file's own `+md-faint+` for the reason the pair below is pinned apart on
purpose: `+md-faint+` means *structure inside a rendered document* — hashes, bullets,
rails — and a housekeeping note is not markdown. Two constants with one spelling each
would drift the day one of them wants a colour.")

(defparameter +role-success+ '(:fg :green) "Role::Success — style.rs:173.")

(defparameter +role-pending+ '(:fg :yellow)
  "Role::Pending — `ESC[33m`, style.rs:174. *Something is happening.*")

(defparameter +role-attention+ '(:bold t :fg :yellow)
  "Role::Attention — `ESC[1;33m`, style.rs:180. *Somebody has to look.*

**Bold yellow against `Pending`'s plain yellow, and the pair is pinned apart on
purpose** (the reference keeps a test for it, style.rs:468-485): \"needs a
person\" and \"is happening\" are close enough in meaning that a WEIGHT is the
right distinction, and a second orange was never one — the cube's orange is not
a slot any theme defines.

Ours had folded the two together: abstained, denied and backgrounded all read as
plain yellow at the outcome sites and backgrounded once read as `Code`'s cyan.
An abstention that looks like a spinner is §8.2's whole subject.")

(defparameter +role-failure+ '(:fg :red) "Role::Failure — style.rs:175.")

(defun %outcome-style (outcome)
  "The role a settled outcome is drawn in — `card::Outcome::role`
(card.rs:185-196), through `display_outcome`'s mapping of the wire onto it
(app.rs:8644-8665).

Timeout and `not_run` are `Failed` there, so they are `Failure` here.
Abstained, denied and backgrounded are `Attention`: something is off or still
moving and a person has to decide, which is not the same fact as a failure and
must not be the same colour. Backgrounded especially — the reference's own note:
*\"a backgrounded call rendered as `Failed` reads as something to retry, and
rendered as `Ok` reads as something that finished with nothing to say. Both are
wrong about a process that is still working.\"*"
  (switch ((outcome-name outcome) :test #'string=)
    ("ok" +role-success+)
    ("abstained" +role-attention+)
    ("failed" +role-failure+)
    ("denied" +role-attention+)
    ("timeout" +role-failure+)
    ("not_run" +role-failure+)
    ("backgrounded" +role-attention+)
    ("interrupted" +role-failure+)
    (t nil)))

(defun %first-line (text)
  (if-let (nl (position #\newline text))
    (subseq text 0 nl)
    text))

;;; ------------------------------------------------------------- the verb ;;;
;;;
;;; Ported from `card::Verb`: a tool name to the word a person reads, with the
;;; RUNNING form of each kept distinct (`Ran` against `Running`) because a card
;;; that says `Ran` while the command is still going is a card that lies about
;;; the one thing it exists to say.
;;;
;;; An unknown name keeps its OWN name, which is right: inventing a verb for a
;;; tool this head does not know is a guess presented as a fact.

(defparameter *verb-map*
  '(("read" . (:read "Read" "Reading"))
    ("read_file" . (:read "Read" "Reading"))
    ("cat" . (:read "Read" "Reading"))
    ("view" . (:read "Read" "Reading"))
    ("edit" . (:edit "Edited" "Editing"))
    ("patch" . (:edit "Edited" "Editing"))
    ("apply_patch" . (:edit "Edited" "Editing"))
    ("str_replace" . (:edit "Edited" "Editing"))
    ("write" . (:write "Wrote" "Writing"))
    ("write_file" . (:write "Wrote" "Writing"))
    ("create" . (:write "Wrote" "Writing"))
    ("grep" . (:search "Searched" "Searching"))
    ("search" . (:search "Searched" "Searching"))
    ("rg" . (:search "Searched" "Searching"))
    ("find" . (:search "Searched" "Searching"))
    ("ls" . (:list "Listed" "Listing"))
    ("list" . (:list "Listed" "Listing"))
    ("list_dir" . (:list "Listed" "Listing"))
    ("glob" . (:list "Listed" "Listing"))
    ("bash" . (:run "Ran" "Running"))
    ("shell" . (:run "Ran" "Running"))
    ("run" . (:run "Ran" "Running"))
    ("exec" . (:run "Ran" "Running"))
    ;; **A compaction is filed as a tool call** (R24), so it needs a word of its own —
    ;; and its own role, because the role is what the edit/write branch keys on to draw
    ;; a DIFF: a compaction has no excerpt, and saying `:write` here would send it
    ;; looking for one.
    ("compact" . (:compact "Compacted" "Compacting"))
    ("fetch" . (:fetch "Fetched" "Fetching"))
    ("web_fetch" . (:fetch "Fetched" "Fetching"))
    ("http" . (:fetch "Fetched" "Fetching"))))

(defun verb-label (tool &key running)
  "The word for TOOL: `Ran` when it is done, `Running` while it is not."
  (let ((hit (assoc (string-downcase (or tool "")) *verb-map* :test #'string=)))
    (if hit
        (if running (third (cdr hit)) (second (cdr hit)))
        (or tool "tool"))))

(defun %payload-lines (payload)
  "PAYLOAD split as Rust's `str::lines` splits it: a final newline ends the last
line and does not start an empty one, and an empty payload is NO lines.
`uiop:split-string` gives a trailing \"\" for both — measured as one extra blank
row at the bottom of every open card, against letibot's screen."
  (let ((rows (uiop:split-string (or payload "") :separator '(#\newline))))
    (if (and rows (zerop (length (car (last rows)))))
        (butlast rows)
        rows)))

(defun %payload-line-count (payload)
  "How many lines PAYLOAD is, which is the number the fold marker counts."
  (length (%payload-lines payload)))

(defun %without-control (line)
  "LINE with every control character replaced by a SPACE — the reference's
`without_control` (app.rs:369), applied where it applies it (app.rs:9712).

**A tool's output cannot be allowed to reconfigure the operator's terminal.** A
payload is whatever the command wrote, escape sequences included; the reference
counted them in the operator's own store, 2026-09-20 — 44 `tool_result` rows
carry an escape and **20 carry a MODE string**: `?1002` and `?1006` are mouse
reporting, `?1049` the alternate screen, `?2004` bracketed paste. That is the
bug they reported as *\"when i expand tools with Ct scroll stops working, even
after collapsing back\"*: ctrl-t renders payloads that were folded away, one of
them turns mouse reporting off, the wheel stops scrolling, and folding back
cannot undo what the terminal has already been told.

**This head's painter does not put an escape on the wire** — `clusters` carries
a sequence in the cluster's `esc`, `screen-put-string` writes only the cluster's
`text`, and a zero-width cluster draws nothing (`src/cells.lisp:209-224`). So
the mode string was already not reaching the terminal. But that is the painter
being incidentally lucky with bytes nobody sanitised, one refactor away from not
being true, and it is not free either: the escape vanished whole, so a row
carrying `ESC[?1002l` measured 0 columns here and 8 there, and every wrap and
every truncation downstream of it disagreed with the reference's. A space rather
than a deletion for exactly that reason — the wrapper about to measure these
lines counts columns.

Sanitised at RENDER, never in the store: the record is what the tool wrote and
must stay that.

A control character is Unicode's `Cc` — C0, DEL and C1 — which is what
`char::is_control` is and what `%c1-control-p` already answers."
  (map 'string (lambda (c) (if (%c1-control-p (char-code c)) #\space c))
       (or line "")))

;;; The settled tool row, to the reference's own weighting.
;;;
;;; Read from `crates/tui/src/app.rs`'s transcript arm rather than inferred, after
;;; a screen comparison showed our card had the emphasis in the wrong places:
;;;
;;;   ▸ Ran "cd /…/sed -n '6503,6560p' crates/…" · ok · 24ms · 59 lines
;;;   ^^^^^                                                       ^^^^^^^^
;;;   faint  verb faint   SUBJECT bright (Plain, NO escape) · ok faint  count BOLD
;;;
;;; The reference's rule, in its own comment: *"the subject — the path, the
;;; pattern — is Role::Plain, i.e. no sequence at all, so it is the brightest thing
;;; on the row. It is what a person is looking for. Everything structural around it
;;; is Faint: the glyph, the verb, the separators, the chord. `ok` is faint too —
;;; it is the boring case and it is most of them; anything else keeps its own loud
;;; role. And the line count is Strong once the output is big enough to be worth a
;;; fold — that is the size signal, and it is an ATTRIBUTE rather than a second
;;; colour, so it survives a terminal-native theme."*
;;;
;;; Our version had the verb bold, the target bright-white and the outcome GREEN —
;;; three colours on a row whose only job is to be scanned, with the size signal
;;; (the thing that tells you what matters before you read a word) nowhere.

(defparameter +big-output-lines+ 40
  "Lines past which the count is Bold rather than faint. The reference's BIG: the
size signal, and an attribute rather than a colour so it survives a
terminal-native theme.")

(defparameter +activity-indent-cols+ 2
  "Columns the model's WORKING is stepped in under what it SAYS.

A turn has four readable levels and they cost no colour: the operator's question
at the body's own column, the working stepped in one, the answer flush left again,
and a rule to close. Given up below 60 columns, where two columns of every line is
a bigger fraction than the hierarchy is worth.")

(defun activity-indent (cols)
  (if (>= cols 60) +activity-indent-cols+ 0))

(defun %envelope-line-p (line)
  "`<<<TOOL_ERROR 5ebfdef6>>>` and its END marker.

The envelope is addressed to the MODEL, not the operator: it is how a result says
where the harness's text stops and the payload starts, with a per-call nonce so a
payload cannot forge one. On a screen it is noise in the middle of the two lines a
folded row has.

Matched by SHAPE, and by the WHOLE shape — `<<<` at the front, `>>>` at the
back and something between them (`is_envelope`, app.rs:7925-7928). Ours tested
the opening only, so a payload line that merely begins `<<<` — a heredoc, a
diff conflict marker, a model quoting this very format — was silently dropped
from the output. A body line cannot forge a real marker: the envelope rewrites
every `<<<` in a payload to `< < <` precisely so it cannot."
  (let ((trimmed (string-trim '(#\space #\tab #\return #\newline) line)))
    (and (> (length trimmed) 6)
         (string= (subseq trimmed 0 3) "<<<")
         (string= (subseq trimmed (- (length trimmed) 3)) ">>>"))))

(defun %ellipsise-path-left (s max)
  "S shortened to MAX columns by eating its LEFT, at a separator —
`ellipsise_left` (app.rs:9074-9109).

**At a separator, not at a character.** `…/1f0655c6-…/scratchpad` was the
operator's example and it is two lies in twenty-two columns: the first ellipsis
says a prefix was dropped, which is true, and the second says a directory has a
shorter name than it does, which is not — and neither segment can be pasted back
into a shell. Dropping WHOLE segments leaves a suffix that is a real path, which
is what a person compares against.

The scan runs left to right, so the first candidate that fits is the LONGEST
suffix that fits. A single segment longer than the whole allowance has nothing to
cut on, and then the characters are all there is — walked from the right and
counted in COLUMNS, which is what ours did not do: a character count overshoots
the budget on every non-ASCII path.

**Not `%ellipsise-left`, and the name is the finding.** `src/chrome.lisp:162`
already holds a function by that name — the header's workspace path, cut at a
CHARACTER — and chrome is loaded after cards, so defining a second one here
silently replaced this rule with that one at load time and every test of it
passed against the wrong function. The reference has one `ellipsise_left` and
both call sites use it; collapsing chrome's into this one is the right end
state and it is chrome's file, so it is noted rather than done."
  (if (or (<= (string-width s) max) (< max 2))
      s
      (or (let ((i (position #\/ s)))
            (loop while i
                  do (let ((cand (concatenate 'string "…" (subseq s i))))
                       (when (<= (string-width cand) max) (return cand))
                       (setf i (position #\/ s :start (1+ i))))))
          (let ((keep (- max 1))
                (cols 0)
                (cut (length s)))
            (loop for i downfrom (1- (length s)) to 0
                  do (let ((cw (char-width (char s i))))
                       (when (> (+ cols cw) keep) (return))
                       (incf cols cw)
                       (setf cut i)))
            (concatenate 'string "…" (subseq s cut))))))

(defun %shorten-subject (subject max)
  "SUBJECT cut to MAX columns the way a person reads it.

**This is where a subject is elided for the screen, and MAX is the viewport's**
(R25). `%tool-result-lines` computes it as *everything the row has left after its own
mark, verb, outcome and duration*, so a wider pane gets more of the subject back and a
narrower one gives it up — the cut is a function of the row's room and of nothing that
was stored. It used to be `display-target`'s job at a constant 120 columns, which is
what made a 227-column pane draw a 156-column headline; see `*target-max-cols*`.

A path is shortened from its LEFT at a separator, because the end of a path is
what identifies it and `crates/tui/src/…` names nothing. Anything with a glob or a
quote in it is PROSE rather than a path — `display-target` quotes any argument with
whitespace — so it is cut from the RIGHT, keeping the question. Measured in the
reference: an `ask_code` subject left-cut to `…/ is responsible for, how main.rs,
editor.rs, and…` had thrown away the question and kept its tail."
  (if (<= (string-width subject) max)
      subject
      (let ((not-a-path (find-if (lambda (c) (member c '(#\* #\? #\{ #\[ #\")))
                                 subject)))
        (if (and (find #\/ subject) (not not-a-path))
            ;; keep the TAIL, at a separator: the end of a path is what names it
            (%ellipsise-path-left subject max)
            ;; keep the HEAD: prose announces itself at the front. `trim_to`,
            ;; which is width-counted and marks its own elision.
            (truncate-to-width subject max)))))

(defvar *answered-calls* nil
  "Call ids whose result row exists, so an assistant row does not also draw them.

A proposal says a call is COMING; once the result has settled nothing is coming,
and the result row already says everything the proposal did plus what happened.
The reference measured the doubling: a turn eight calls deep showed eight live rows
under eight settled ones, in the same order, saying less.")

(defun call-answered-p (call-id)
  (and call-id (member call-id *answered-calls* :test #'string=)))

(defun note-answered-call (call-id)
  (when (and call-id (not (call-answered-p call-id)))
    (push call-id *answered-calls*)))

(defun %outcome-why (outcome)
  "The reason a call's outcome carries, or NIL — the reference's `outcome_why`."
  (when (consp outcome)
    (switch ((outcome-name outcome) :test #'string=)
      ("ok" nil)
      ("timeout" nil)
      ("denied" (format nil "the call was denied (~a)" (or (getf outcome :req-id) "")))
      ("backgrounded" (format nil "as `~a` — ~a" (or (getf outcome :handle) "")
                              (or (getf outcome :next) "")))
      (t (or (getf outcome :reason) (getf outcome :why))))))

(defun %outcome-word (word)
  "The word the row prints for an outcome name — `outcome_word`. Shouted where the
reference shouts (§8.2: abstention must not read like success)."
  (switch (word :test #'string=)
    ("abstained" "ABSTAINED")
    ("denied" "REFUSED")
    ("not_run" "not run")
    ("backgrounded" "STILL RUNNING")
    (t word)))

(defparameter +unsure-said+
  '(;; **letibot's four tokens** (`UnsureKind::as_str`, `authorise.rs`) and the sentence THIS
    ;; HEAD writes for each. The token is the daemon's; the sentence is the head's, and that
    ;; division is the point — see `%advice-said`.
    ("could_not_decide" . "the guard read it and could not tell")
    ("between_thresholds" . "the guard's two scores landed between the thresholds")
    ("unreadable" . "the guard's reply was not a verdict")
    ("out_of_room" . "the guard ran out of room before it answered"))
  "What an `unsure` token means, as this head says it.

**The sentences are the head's and the tokens are the daemon's**, which is why they live here
rather than being echoed: letibot publishes the token precisely so a head *authors the
classification*, with the daemon's `basis` following as the detail. A head that printed the
token raw, or that parsed `basis` back into a kind, would be either unreadable or inventing
the very coupling the token exists to remove.")

(defparameter +would-said+
  '(((:no "ask") . "no model was asked — a rule puts this on the always-ask list")
    ((:no "unavailable") . "no model was asked — there was nothing to ask about")
    ((:no "refuse") . "no model was asked — a rule blocked this")
    ((:yes "admit") . "the guard found authorisation for this")
    ((:yes "ask") . "the guard found nothing that authorises this"))
  "The five cases `unsure` does NOT cover, keyed `(spoke-p would)` with `spoke-p` a keyword.

`(:yes ask)` — a guard that SPOKE and said no — is the one that used to be indistinguishable
from the four non-answers: a
guard that LOOKED and found no authorisation is an ANSWER, and it arrived in the same three
fields as *I could not answer at all*.")

(defparameter +unsure-since+ 25
  "The protocol version at which `ModelAdvice` gained `unsure`, so the head knows whether a
daemon can DISTINGUISH the four non-answers from a real `NotAuthorised` answer.

**A number here rather than a feature probe**, because the protocol's only handshake is an
equality check at ATTACH and this is the one thing on the wire that says which fields a frame
may carry. Below it, `consulted` + `would: \"ask\"` is ambiguous; at or above it, the absence
of `unsure` IS the fifth fact.")

(defun %advice-said (advice)
  "What the oracle's answer AMOUNTS TO, in this head's words, or NIL.

**R12, and this function is the whole of the head's half.** The criterion says the card must
say WHICH of the non-answers happened; the daemon now sends `unsure`, so the head does not
echo the daemon's prose to say it — it names the fact and lets the daemon's `basis` follow as
the detail beneath. Measured before this existed, on three real frames: `consulted: true`,
`would: \"ask\"`, `cites: []` is what FIVE distinct facts arrived as, so the card was
byte-identical for a guard that looked and said no and for a guard that never finished a
sentence.

**An unrecognised `unsure` token is printed RAW.** A daemon that gains a fifth kind must be
VISIBLE — a head that folded it into one of the four would reproduce this exact defect with a
new fact, and silently. `the guard could not answer (some_new_kind)` is ugly on purpose.

**And a `would` this build has never met is shown too**, by the caller falling back to
`model says {would}`: nothing on the wire is ever dropped for being new.

**A `:consulted` that is ABSENT is not `false`.** The wire always carries the field, so the
only way to see it missing is a frame this build built by hand — but reading it as false would
have the head say *no model was asked* about an advice that says a model admitted something,
which is a claim the frame never made. So absence falls through to the caller's *what I was
told* sentence, exactly as an unknown `would` does.

**A 23 DAEMON CANNOT SUPPORT THE `(:yes ask)` ROW, and this head was claiming it anyway.**
`consulted: true` plus `would: ask` with no `unsure` means *the guard looked and found
nothing* — but only on a daemon that HAS `unsure` to send. A daemon at 23 sets that same triple for the
four non-answers too, so on it the row asserts an answer where the fact may be a failure to
answer: **the R12 defect, reintroduced for old daemons by the fix for new ones.** Found while
deciding what could be pushed live to a head attached to a 23 daemon — the suite runs at 25
and cannot see it.

So that ROW is version-gated: it is used when the daemon can distinguish the cases
(`*daemon-protocol*` at or above `+unsure-since+`), and below that the caller's honest
`model says ask: {basis}` stands. The three `consulted: false` rows are NOT gated — those are
facts about whether a model was consulted, which 23 has always carried."
  (let* ((consulted (getf advice :consulted :absent))
         (spoke (cond ((eq consulted :absent) :absent)
                      (consulted :yes)
                      (t :no)))
         (would (getf advice :would))
         (unsure (getf advice :unsure))
         (ambiguous-on-23 (and (eq spoke :yes) (equal would "ask")
                               (not (and (stringp unsure) (plusp (length unsure))))
                               (< (or *daemon-protocol* 0) +unsure-since+))))
    (cond
      ;; a token the daemon sent, so the head can say exactly which non-answer this was
      ((and (stringp unsure) (plusp (length unsure)))
       (let ((hit (assoc unsure +unsure-said+ :test #'string=)))
         (if hit (cdr hit) (format nil "the guard could not answer (~a)" unsure))))
      ;; no token: the disposition AND whether a model spoke at all — EXCEPT the one a
      ;; daemon older than `unsure` cannot report; see the docstring's last paragraph.
      (ambiguous-on-23 nil)
      ((cdr (assoc (list spoke would) +would-said+ :test #'equal)))
      (t nil))))

(defun %advice-line (advice)
  "The ONE line that says what the oracle's answer amounts to, for both surfaces.

**One function because the card and the settled row are two views of one fact**, and the
repo's rule for that is one renderer: two would drift, and this one already had. The
classification is the head's (from the token), the `basis` is the daemon's and follows as the
detail — so a reader gets *the guard ran out of room before it answered* first and the
daemon's own sentence under it, and the two can never disagree because neither is derived
from the other.

When this head has no classification it says what it was told: `model says {would}`. That is
the fallback for an unknown `would` AND for a daemon that predates `unsure`, and it is
deliberately the OLD sentence, so an older daemon draws exactly what it drew before."
  (let ((said (%advice-said advice))
        (basis (or (getf advice :basis) "")))
    (if said
        (if (plusp (length basis))
            (format nil "~a: ~a" said basis)
            said)
        (format nil "model says ~a: ~a" (or (getf advice :would) "?") basis))))

(defun %decision-detail (d w &key skip-basis)
  "What a settled decision was grounded in, wrapped to W — `decision_detail`
(app.rs:9462-9507). Returns plain strings; each caller indents and paints its
own way, which is the point of one function: the card and the settled row cannot
then label the same fact differently.

We drew ONE of its five parts. The four that were missing:

  · `asked: {summary}` — what the question actually was, which a row that only
    says `allowed, by dead` never states;
  · `oracle ({by}, {latency}ms) would {would}: {basis}` — the guard model's own
    verdict. `basis` is the DECIDER's and `advice` is the oracle's; the
    reference had them as one line labelled `oracle:` once, and under
    `/supervise` that printed the operator's own words under the oracle's name;
  · **`oracle cited: nothing — it could not ground this in anything you said`.**
    *\"Empty cites is loud\"*: an authorisation the oracle could not ground in
    anything the operator said is a different fact from one grounded in four
    utterances, and rendering nothing for the first makes them look the same;
  · `no oracle was consulted for this one` — because \"no oracle was asked\" and
    \"an oracle was asked and said nothing\" are different, and a blank reads as
    the second.

SKIP-BASIS is ours and the reference has no counterpart. It drops the decider's
line when the payload below already carries it verbatim — the operator, counting
the repeats in one card: *\"how many times is 'nothing ran' needed?\"* The
oracle's lines are never skipped, because they are nowhere else.

**The oracle block cannot fire today**: `:advice` is carried on the OPEN
decision and `session.lisp`'s `decision-answered` arm does not copy it onto the
settled one, so every settled decision renders `no oracle was consulted`. That
is one line in another strand's file — `:advice (getf req :advice)` beside
`:basis` — and the shape is here waiting for it."
  (let ((out nil)
        (by (getf d :by))
        (advice (getf d :advice)))
    (flet ((say (text)
             (dolist (l (wrap-segments (list (cons text nil)) (max 4 w)))
               (push (format nil "~{~a~}" (mapcar #'car l)) out))))
      (let ((summary (or (getf d :summary) ""))
            (basis (or (getf d :basis) "")))
        (when (plusp (length summary))
          (say (format nil "asked: ~a" summary)))
        (when (and (plusp (length basis)) (not skip-basis))
          ;; named by the decider's own kind, so `decided:` never stands in for
          ;; a model when a person chose, or the reverse
          (say (format nil "~a: ~a"
                       (let ((kind (or (getf by :kind) "")))
                         (if (plusp (length kind)) kind "decided"))
                       basis))))
      (if advice
          (progn
            ;; the settled row keeps its own ATTRIBUTION — who and how long — on one line,
            ;; because a transcript row has one line to spend; the card puts them on a
            ;; second line beneath. What they share is the classification, which is the
            ;; half that must not be able to disagree.
            (say (format nil "oracle (~a, ~ams) ~a"
                         (or (getf advice :by) "") (or (getf advice :latency-ms) 0)
                         (%advice-line advice)))
            (let ((cites (getf advice :cites)))
              (if (null cites)
                  (say "oracle cited: nothing — it could not ground this in anything you said")
                  (dolist (c (coerce cites 'list))
                    (say (format nil "oracle cited: ~a" c))))))
          (say "no oracle was consulted for this one")))
    (nreverse out)))

(defun %decision-word (decision)
  "The one word a settled decision gets — app.rs:8843-8849, `decision_lines`."
  (let* ((o (getf decision :outcome))
         (option (and (consp o) (getf o :option-id))))
    (cond ((and option (alexandria:starts-with-subseq "allow" option)) "allowed")
          (option "refused")
          ((equal (outcome-name o) "cancelled") "cancelled")
          ((equal (outcome-name o) "timed_out") "not answered")
          (t "answered"))))

(defun %decision-who (decision)
  "Who decided: the kind, and the identity when there is one."
  (let ((by (getf decision :by)))
    (format nil "~a~@[ ~a~]" (or (getf by :kind) "")
            (let ((id (getf by :identity)))
              (and id (plusp (length id)) id)))))

(defun %first-sentence (basis)
  "The first sentence of BASIS's first line, capped at 140 characters."
  (let* ((line (string-trim " " (%first-line basis)))
         (dot (search ". " line))
         (s (if dot (subseq line 0 (1+ dot)) line)))
    (if (<= (length s) 140)
        s
        (format nil "~a…" (string-right-trim " " (subseq s 0 140))))))

(defun %strip-gutter (line)
  "A leading line-number gutter — `     1| ` — off ONE line of tool output.

Only ever applied to a one-line preview inlaid on a header, never to a body: a
body's gutter is how a reader refers to a line. On a header it is `1|` before the
only line there is, which is three columns saying \"this is line one of one\"."
  (let* ((t0 (string-left-trim " " line))
         (digits (or (position-if-not #'digit-char-p t0) (length t0))))
    (if (and (plusp digits) (> (length t0) (1+ digits))
             (char= (char t0 digits) #\|) (char= (char t0 (1+ digits)) #\space))
        (string-right-trim " " (subseq t0 (+ digits 2)))
        (string-trim " " line))))

;;; ------------------------------------------------ the payload's own window ;;;
;;;
;;; **What makes the rest of a long result reachable at all.**
;;;
;;; A settled tool row drew `… +N lines · ctrl-t`, and the reader pressed ctrl-t and
;;; got the same row back: the fold raises the BUDGET (which rows may be long — two
;;; rows folded, forty open) and gives no row an OFFSET. So the chord the seam named
;;; revealed nothing, and a 418 KB log was readable to its fortieth line and no
;;; further. The reference records exactly this at the site this is ported from
;;; (app.rs:10828-10840):
;;; *"opening the fold changed the budget, not the offset. There was no offset."*
;;;
;;; So a row whose window is open draws a WINDOW into its payload — one line per
;;; source line, which is why the seams can talk in lines — and the arrows page it.

(defparameter *payload-page* 10
  "How many lines one press pages a payload window.

The reference's `BY` (app.rs:3863), and deliberately the SAME unit for the arrows
and the page keys rather than a screenful: the window's height is a function of the
frame, the fold and the payload, and the key handler knows none of those. The offset
is clamped where it is USED — by the render, which is the only place that knows how
long the payload is — which is what the reference does for the same reason.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a
constant could never be changed on a running head.")

(defvar *payload-view* nil
  "The one row whose payload window is OPEN, and how far into it the reader has
paged: a cons `(ITEM-ID . OFFSET)`.

**A pair and not a bare offset**, because *the view is open* and *how far down it
is* have to agree about WHICH row: several rows can be long on one screen, and a
bare offset would page every one of them together.

**Keyed on the ITEM ID**, which is what `item-lines` holds and what is unique per
row. `call-id` is the tempting key and the wrong one — it is round-positional and
reused, so a view keyed on it opens on the wrong row after the next round; the
reference's first version did exactly that and its own test caught it, the seam
saying `ctrl-t pages` while ctrl-t had been pressed (`app.rs:10231-10238`).

A `defvar` and not a head slot, for the reason all live state is: a struct layout
change is a restart, and this has to be reachable from a push. Bound by
`with-replay-globals`, because a replay must answer the same bytes twice.")

(defun %payload-view-set (value)
  "The ONE writer of `*payload-view*`, and the place that invalidates the rendered
history.

A page offset changes what a row RENDERS TO without moving any of the line cache's
three terms — the generation, the width, the items vector's identity — so a paging
that did not bump the generation would be served the previous window out of the
cache and look like a key that does nothing. That is the reference's own finding at
its cache (*the page moved to 10 and the screen still showed line 0*) and ours would
have been the same one.

One writer rather than an `(incf …)` at each call site, for the reason the
preference setter gives: *\"the fifth site is the one that would forget\"*.
(`*hist-generation*` is defined in `render.lisp`, beside the cache it invalidates and
after this file — the same forward reference `push-item` in `session.lisp` already
makes.)"
  (setf *payload-view* value)
  (incf *hist-generation*)
  value)

(defun payload-view-for (item)
  "The offset THIS row's window is at, or NIL when this row has no window."
  (let ((id (getf item :item-id)))
    (when (and *payload-view* id (equal id (car *payload-view*)))
      (cdr *payload-view*))))

(defun payload-view-open-p () (and *payload-view* t))

(defun newest-payload-row-p (item)
  "Is ITEM the row `ctrl-t` would open — the newest one with something to page?

**This exists because of R40's rule**: *a chord is named only where it acts*. `ctrl-t` opens the
window on ONE row, so a seam may name it on that row and on no other — every other folded row
names `/t`, the verb that unfolds the whole conversation. Before the split, every seam could
honestly say `ctrl-t` because the chord did both; after it, a seam that named `ctrl-t` on an
older row would be telling the reader to press a key that does nothing to the row they are on.

**The test is `payload-view-seed`'s own walk and not a second opinion**: it asks whether this
item's id is the one the seed would pick, by calling the same function, so the seam and the chord
cannot disagree about which row that is.

**With no head in scope the answer is NO, and that is the safe direction rather than a fallback
for convenience.** A row can be drawn outside a frame — a test, a pane, a file that builds rows
to measure them — and a head that cannot see the session cannot assert that `ctrl-t` acts on this
row. `/t unfolds it` is the claim that is TRUE of every folded row whatever the session is, so an
unknowable case takes it. Measured: reaching for the head unconditionally made every direct
`item-lines` call die with `expected-type HEAD, datum NIL`, which is ten tests telling the same
story about a predicate that answered a question it had no information for."
  (let ((head *payload-head*))
    (and head
         (getf item :item-id)
         ;; **the PURE question**, not the seeder: asking must not open a window
         (equal (newest-payload-item-id (head-session head)) (getf item :item-id)))))

(defvar *payload-head* nil
  "The head whose items `newest-payload-row-p` judges, for the one thing that needs it.

**A defvar because a row's LINE function is handed an item and a preference list and nothing
else** (`item-lines`), so asking *is this the newest pageable row* needs the session from
somewhere. Set by `%viewport-lines` — the one place that draws rows and therefore the one place
that can know — and read only inside a frame, so it never outlives the paint that set it.")

(defun payload-view-close ()
  "Close the window. T when there was one."
  (when (payload-view-open-p)
    (%payload-view-set nil)
    t))

(defun payload-view-page (delta)
  "Move the open window DELTA lines, floored at zero. T when there was a window.

The UPPER clamp is the render's, not this function's: how far down a payload goes is
a function of the payload and the frame, and neither is known here."
  (when (payload-view-open-p)
    (%payload-view-set (cons (car *payload-view*)
                             (max 0 (+ (cdr *payload-view*) delta))))
    t))

(defun %tool-payload-rows (body)
  "The rows a tool result's payload draws as.

Sanitised FIRST and filtered second, the reference's order (app.rs:9712): a
payload's bytes are the command's and not this terminal's (`%without-control`), and
the envelope lines — the wrapper the harness adds around a result, addressed to the
model — are not output."
  (remove-if #'%envelope-line-p
             (mapcar #'%without-control
                     (%payload-lines (or (getf body :payload) "")))))

(defparameter +payload-pageable-lines+ 2
  "A payload longer than this is worth a window.

The reference's test in `newest_payload_row` (`payload.lines().count() > 2`), and the
same number for a reason rather than by coincidence: a folded row already draws one
line and the seam, so two is the point past which paging gains anything.")

(defun %row-openable-rows (item)
  "The rows THIS row's `ctrl-t` would reveal, or NIL when it has nothing to page.

**ONE ANSWER, because two readers ask it** — the seeder that decides which row the chord opens, and
a row's own drawing, which must know whether its seam may name the chord at all (R40). A second
opinion would let a seam promise a window the seeder would not open.

Two kinds of row can open, and they are the two the reader gets buried by:

  · **a tool result**, whose rest is its payload (`%tool-payload-rows`);
  · **a job settlement** — the daemon's completion notice, which arrives as a `User` row with
    `speaker: agent` and is a paragraph of blather on the conversation (R41's own message).

Everything else answers NIL, and the callers drop a row with nothing to page rather than inventing
one — the same rule `payload-view-seed` already keeps."
  (let ((body (item-body item)))
    (cond
      ((null (consp body)) nil)
      ((string= (getf body :type) "tool_result") (%tool-payload-rows body))
      ((and (string= (getf body :type) "user")
            (eq (%user-speaker body) :agent))
       (let ((text (%user-parts-text body)))
         (and (%job-notice-p text) (%job-notice-rows text))))
      (t nil))))

(defun newest-payload-item-id (session)
  "WHICH row a window would open on — the newest with something to page — or NIL.

**PURE, and split from `payload-view-seed` for a reason that cost a real defect** (R40): the
predicate that decides whether a row's seam may name `ctrl-t` has to ASK this question, and the
first version asked it by calling the seeder — so drawing a row OPENED A WINDOW. Every frame
would have opened one on the newest long result, and the reader's `ctrl-t` would then close a
window they never asked for.

**The newest, because that is the row a reader is looking at**: rows are appended at the bottom,
so the command just run is at the end. Only ONE row has a window at a time, and it is this one —
which is also the whole limit of the mechanism, written down rather than implied."
  (loop for i of-type fixnum from (1- (length (session-items session))) downto 0
        for item = (aref (session-items session) i)
        ;; **via `%row-openable-rows`, so a job settlement is openable too** (the operator: *"make
        ;; them one liners for conversation and Ctrl-t'able otherwise"*). This asked for a
        ;; `tool_result` by name, which is how the one row type that buries a conversation most
        ;; was the one kind the chord could not open.
        when (> (length (%row-openable-rows item)) +payload-pageable-lines+)
          return (getf item :item-id)))

(defun payload-view-seed (session)
  "Open the window on the newest row with something to page, at its first line.
NIL when no row has one — which is the right answer for a session whose last result is
one line long, and leaves the fold with no view rather than inventing one."
  (%payload-view-set
   (let ((id (newest-payload-item-id session)))
     (and id (cons id 0)))))

(defparameter +call-origin-cols+ 32
  "How many columns of an actor's identity a row will carry.

**Bounded because the row's arithmetic depends on it** (R25): the actor goes in the TAIL,
which is measured first so the subject is given what is left. An unbounded identity would
be a row whose subject is squeezed by a name, and the name is the daemon's to keep short —
`human:dead` is ten columns. Thirty-two is `human:` plus a long one, disclosed with an `…`
like every other cut in this tree.")

(defun %call-origin-said (body)
  "WHO this row's call came from, as the daemon named them, or NIL for the MODEL's own call.

**R24 part two, decision 1**, and the field it renders is letibot `dd81999`.
`TranscriptItem::ToolResult` carries `origin: Option<CallOrigin>`, and the wire spells it:

    {\"origin\": {\"operator\": {\"who\": \"human:dead\"}}}

**ABSENCE is a fact with a meaning, not a hole**, and that is the half a head gets wrong.
`None` is *the model proposed this call* — which is also what every row written before the
field existed means, since a missing key for an `Option` reads as `None` and that is why
the field needs no version bump. So this answering NIL must leave the row drawing exactly
what it drew before the field was thought of; it does not mean *nobody asked*.

**A shape this build cannot read still NAMES somebody.** The field exists so that a call
the model did not make is not drawn as the model's, so an `origin` this build does not
recognise renders its own key rather than falling back to silence — *a wrong colour is
worse than none*, but silence here is not no colour, it is the model's colour.

`who` is the gate's own identity (`human:dead`, the same string `verdict_by` records), so
the row and the adjudication for one call name the actor the same way. It is drawn
VERBATIM: a head that stripped the `human:` scope would be recomposing a name the daemon
owned."
  (let ((origin (getf body :origin)))
    (cond
      ((null origin) nil)
      ;; an origin named as a word — the shape `SystemOrigin` uses on a system row, kept
      ;; so one function reads both and a tool row never mis-draws one as the model's
      ((stringp origin) (truncate-to-width origin +call-origin-cols+))
      ((consp origin)
       ;; **the VALUE is guarded before `getf` reads it**: an origin this build does not know
       ;; may carry a word rather than a plist (`{"flowy": "seat-3"}`), and a reader that
       ;; signalled on it would take the head down over a fact it was only trying to NAME.
       (let* ((kind (loop for (k v) on origin by #'cddr return k))
              (val (and kind (getf origin kind)))
              (who (and (consp val) (getf val :who))))
         (truncate-to-width
          (if (and (stringp who) (plusp (length who)))
              who
              (string-downcase (string kind)))
          +call-origin-cols+)))
      (t nil))))

(defun %tool-row-verb (body)
  "The word a tool result draws first — its own, or the tool's name through `verb-label`.
One function, because R37's marker names the same acts the rows do."
  (or (getf body :verb) (verb-label (getf body :name))))

(defun %tool-row-subject (body)
  "What a tool result draws after its verb — the row's own subject, the call's target, or the
call id when there is nothing better. Extracted with the verb so the marker and the row cannot
disagree about what a hidden row was."
  (or (getf body :subject)
      (call-target-of (getf body :call-id))
      (format nil "(~a)" (getf body :call-id))))

;;; ------------------------------- a run of hidden rows: R37, amended (the marker) ------ ;;;
;;;
;;; **R37 was filed as *hide completely*, and the amendment is that hiding completely breaks the
;;; prose.** The operator read a screen where the model's sentence ended *"…and the one where
;;; R22's arithmetic has to give**:**"* — a colon pointing at the work that follows it — and in
;;; the rung as built the work was gone, so the sentence pointed at nothing. Their words: *"if
;;; toolcalls and thinking are just hidden completely the narrative breaks. something like [5
;;; tool calls and 43 thinking lines, "summary line"] would fit better here."*
;;;
;;; So a **contiguous run** of hidden rows collapses to **ONE line**, and it OPENS — *a marker
;;; that cannot be opened is the elision this document refuses everywhere else.*

(defvar *hidden-run-open* nil
  "The id of the hidden run this rung has OPEN, or NIL. One at a time, like the payload window.

Bound by `with-replay-globals`, because it changes what a row RENDERS TO and a replay that
inherited one would draw another session's work expanded.")

(defvar *hidden-run-head* nil
  "The head whose preferences the OPEN form renders with, for the same reason `*payload-head*`
exists: a row's line function is handed an item and a preference list, and the open form has to ask
for the rows the rung above would draw. Set by `%viewport-lines`, read only inside a frame.")

(defun reading-hides-p (item)
  "Does the `:reading` rung hide this ITEM?

**One predicate and two readers.** `item-lines` asks it before drawing a row, and `%history-until`
asks it to find the RUNS — and a second opinion about which rows are hidden would put a marker
beside a row that is still on the screen, or collapse a run that is not one."
  (let ((body (item-body item)))
    (and (reading-p)
         body
         (member (%key-from-wire (getf body :type)) +reading-hides+))))

(defun %hidden-run-id (items)
  "A stable id for a run of ITEMS, and stability is the whole requirement.

**Derived from the run's own content, not from a counter**: the window state and the anchor both
name a run across frames, and a run's first item is the same item next frame unless the run itself
grew — in which case the id changing is honest. `(first items)` is the OLDEST row in the run, which
is the end that does not move when new work arrives."
  (format nil "leticl-run-~a" (getf (first items) :item-id)))

(defun %row-invisible-p (item cols)
  "Is there NOTHING for the reader to see in ITEM? — the one question the run's contiguity asks.

**A run is broken only by a row this rung actually DRAWS** (R37 amended), so a hidden row and a row
that renders to nothing are both *invisible* and neither ends a run. Extracted because TWO readers ask
it — the walk that builds the runs and `newest-hidden-run-id` — and a second answer to *is this row on
the screen* is how a seam comes out naming the wrong chord for a run that is in fact the newest.
Measured: the interleaved fixture's single run named `/verbosity` (the every-other-run wording) because
the id-finder had stopped the run at a whitespace-only assistant row the walk stepped over."
  (every #'%line-blank-p (item-lines item cols nil)))

(defun newest-hidden-run-id (session)
  "The id of the NEWEST run of hidden rows in SESSION, or NIL when there is none.

Symmetric with `newest-payload-item-id`: the chord follows the newest run for the same reason the
payload window follows the newest long row — that is where a reader reaching for the key is. The
walk is newest-first and stops at the first hidden item; the id names that run's OLDEST end, which
is the end that does not move as new work arrives.

**The run is cut by the same rule the renderer cuts it with** — `%row-invisible-p` — so the run this
names and the run `%history-until` flushes cannot disagree about their extent. Only the HIDDEN rows go
into the id: an invisible row inside a run is stepped over, exactly as the walk steps over it."
  (let ((items (session-items session)))
    (flet ((hidden-p (i) (reading-hides-p (aref items i)))
           (invisible-p (i) (%row-invisible-p (aref items i) 120)))
      (loop with n = (length items)
            for i from (1- n) downto 0
            when (hidden-p i)
              return (let ((newest i))
                       (loop while (and (>= i 0) (or (hidden-p i) (invisible-p i)))
                             do (decf i))
                       (%hidden-run-id
                        (loop for k from (1+ i) to newest
                              when (hidden-p k) collect (aref items k))))))))

(defun %hidden-run-live-work (turn cols)
  "The work a RUNNING turn has in flight — `(:calls N :thinking M)` — or NIL.

**The window this closes is the one the operator named:** *\"suppose you write blablabla 'let me
check' — nothing for awhile while you write a tool call and tool executes, we need to see it
somehow, otherwise it looks like you hanged.\"*

The window has no marker in it today, and that is not an oversight but a consequence of how a run is
defined: a run is a stretch of item rows this rung hides, and **an in-flight call has no row yet**.
The narration is committed as an assistant row the moment the call is proposed, the call itself runs
with no transcript entry at all, and the result row is what finally gives the run something to
count — so for the whole of that window the head draws the model's colon and nothing else, and a
turn running a slow command looks exactly like a turn that has died.

The reference answers it with `live_work` (app.rs:13262): calls **proposed or running with no result
row yet**, plus the streamed reasoning's display lines, added to the counts of the marker at the live
edge. This is the same two numbers from the same place, in this head's own terms — `:calls` is the
turn's call list filtered to the unfinished, and `:thinking` is `reasoning-line-count` over the
reasoning that has streamed and not yet been committed, which is the SAME arithmetic the reasoning
row's own header uses.

NIL when there is nothing in flight, so a caller decides with one test and a quiet turn stays quiet.

**AND THE TURN'S OWN STATE IS NOT THE EVIDENCE — the CALLS are.** This gated on
`(turn-state-name turn)` being `\"running\"`, and MEASURED on the live head, with a bash call
plainly executing, that was `\"finished\"`:

    (:TURN-STATE \"finished\"
     :CALLS ((\"call_00_2BEv4qYe4aW9V9hRz4400585\" \"running\"))
     :LIVE NIL
     :MARKER ((\"[0 head events]\") (\"\" :DIM T)))

So the window this function exists to close was still open, and the marker said **`[0 head events]`
while a tool call ran** — the operator's *\"still no yellow counters for [] running tool calls\"*,
with the brackets nearly empty because the in-flight call was never counted. The turn's state name
lags the call that is executing: the model has stopped generating, so from the turn's own point of
view it is done, and the command it asked for is still going.

**So the gate is the TURN PANE'S EXISTENCE and nothing else**, which is what the reference does
(`live_work`, app.rs:13262): it asks whether there is a turn to look at, and then counts. `superseded`
there is its second test and it is nearly redundant — it fires only when every appended row already
has a body AND every call is finished, which is the case that counts zero anyway.

The text below is the gate: a turn with nothing unfinished counts zero, and the `when` returns NIL, so
a genuinely quiet turn stays quiet. A state name is not evidence about a call."
  (when turn
    (let* ((calls (count-if (lambda (c) (let ((st (getf c :state)))
                                            (and st (not (string= (or (getf st :state) "") "finished")))))
                              (getf turn :calls)))
             (reasoning (or (getf turn :reasoning) ""))
             (thinking (if (plusp (length reasoning))
                           (reasoning-line-count reasoning cols)
                           0)))
        (when (or (plusp calls) (plusp thinking))
          (list :calls calls :thinking thinking)))))

(defun %hidden-run-counts (items cols &optional live)
  "`(:calls N :thinking M)` for a run — the two numbers the marker carries, and there are only two.

**LIVE is the work still in flight, added in** — see `%hidden-run-live-work`. It is added HERE and
not by the caller so there is one arithmetic for *how much work this marker is about*, and the
marker's own room ladder sees the number that will actually be drawn.

**Thinking is counted in SCREEN lines** (`reasoning-line-count`) because that is what the reader is
being told the price of, and it is the same arithmetic the reasoning row's own `▸ Thought · 43 lines`
header uses — one function, so the marker and the header cannot disagree about the block between
them."
  (let ((calls 0) (thinking 0) (events 0))
    (dolist (item items)
      (let* ((body (item-body item))
             (type (%key-from-wire (getf body :type))))
        (case type
          (:tool-result (incf calls))
          (:reasoning (incf thinking (reasoning-line-count (or (getf body :text) "") cols)))
          (t (incf events)))))
    (list :calls (+ calls (or (getf live :calls) 0))
          :thinking (+ thinking (or (getf live :thinking) 0))
          :events events)))

(defparameter +hidden-run-marker-cols+ 56
  "The widest room a marker may claim from the sentence it continues, leading space included.

`[100 tool calls, 999 thinking lines] · ctrl-t opens it` is 54 columns, the longest marker a
realistic run writes, and this is that plus the space in front of it. It is a CEILING rather than
the room itself: the room a frame actually reserves is `hidden-run-marker-room`, which also takes
the frame's width into account.

A `defparameter` and not a `defconstant`, for the reason every other tunable here is: the file
pusher skips constants, so a constant could never be moved on a running head.")

(defparameter +hidden-run-marker-floor+ 22
  "The least room a marker may claim, however narrow the frame.

Below about twenty columns the two clauses stop being readable at all — `[100t, 246l]` and its
separator are twelve — and a marker that cannot be read is a marker that did nothing.")

(defun hidden-run-marker-room (cols)
  "How many columns of COLS the marker may occupy, its leading space included (R37 final).

**Fixed for a given frame, and that is the whole point.** It does not depend on the counts, and
the operator's own report is why: *\"the text starts to jump - counts add digits when grow, and at
some point the line could be split so things jump even more. I dont like jumps.\"* When the room
was the marker's ACTUAL width, every digit the counts gained re-wrapped the sentence above them —
the same transcript read two ways depending on how many calls a turn happened to run. A room
computed from COLS alone cannot move, so growth has nowhere to go but the marker's own words.

**At most half the frame, so a narrow terminal keeps half its line for the sentence**, at most
`+hidden-run-marker-cols+`, never less than `+hidden-run-marker-floor+`, and never more than the
frame itself — a room wider than the line it is on is not a room. The prose is rendered
`(- cols room)` wide and the counts land in what is left."
  (min cols +hidden-run-marker-cols+ (max +hidden-run-marker-floor+ (floor cols 2))))

(defparameter +hidden-run-count-rungs+
  (vector (list "~d tool call~:p"   "~d thinking line~:p" "~d head event~:p")
          (list "~d tool~:p"        "~d thinking"        "~d event~:p")
          (list "~d call~:p"        "~d line~:p"         "~d event~:p")
          (list "~dt"               "~dl"                "~de"))
  "The count clause, most-spelled first: `tool calls` → `tools` → `calls` → `t`.

**What gives way when the counts grow** — the operator's own ladder, verbatim: *\"we just start to
remove bloat - 'tool calls' -> 'tools' -> 't' and so on\"*. A rung is a triple because a run has
three kinds of clause and they must step down together: a marker reading `[2 tools, 3 thinking
lines]` is one rung's word beside another's, and the operator's ladder is about the marker and not
about the clauses in it.")

(defparameter +hidden-run-seam-rungs+
  (vector (cons " · ctrl-t opens it" " · /verbosity")
          (cons " · ctrl-t" " · /verbosity")
          (cons "" ""))
  "The seam, most-spelled first: the whole chord, the chord alone, nothing.

Dropped LAST, because the seam is the only thing on the line that says the rows can be opened at
all — and it is dropped at all only because a marker that will not fit is a marker that did
nothing. `ctrl-t` survives a rung longer than `opens it` does, which is the same rule R29 uses on
every other elided row: the key is the part that cannot go.")

(defparameter +hidden-run-marker-ladder+
  '((0 . 0) (1 . 0) (2 . 0) (3 . 0) (3 . 1) (3 . 2))
  "The order the two ladders are spent in: the counts step down through every rung first, and only
then does the seam start to go.

**Counts before seam**, because the counts are the fact the line exists to carry and the seam is
the head talking about its own keys. The seam still goes before the counts go to their last rung,
which is why the pairs interleave rather than running as two separate sweeps.")

(defun %counts-clause-segs (rung n style)
  "ONE count clause as SEGMENTS — `2` in STYLE, ` tools` plain.

The rung is a format string that spells the number and its word together (`~d tool call~:p`), so it
is formatted WHOLE and then split at the digits it printed — not split at its own `~d` first, which
is what the first cut did and it does not work: **`~:p` reuses the PREVIOUS argument rather than
taking one**, so a format string holding ` tool call~:p` and nothing that consumed a number has no
previous argument at all and signals. Measured: seventeen fixtures died on `FORMAT-ERROR`."
  (let* ((text (format nil rung n))
         (num (format nil "~d" n))
         (at (search num text)))
    (if at
        (list (cons (subseq text 0 at) nil)
              (cons num style)
              (cons (subseq text (+ at (length num))) nil))
        (list (cons text nil)))))

(defun %hidden-run-counts-segs (items cols &optional count-rung live style)
  "`[N tool calls, M thinking lines]` as SEGMENTS, with **only the tool-call number** in STYLE.

*\"you should yellow only tool call number, not the whole
[] thing.\"* The yellow marks the one number that is still going up — the calls — and nothing else:
not the brackets, which are punctuation, and not the thinking count, which is a count of a different
kind of work and would make the whole marker a highlight.

The counts are the same string as ever with no STYLE, so the merged paragraph's caller and the
width ladder are unaffected: this returns SEGMENTS rather than text precisely so the style costs no
character."
  (let* ((rung (or count-rung (aref +hidden-run-count-rungs+ 0)))
         (counts (%hidden-run-counts items cols live))
         (calls (getf counts :calls))
         (thinking (getf counts :thinking))
         (parts (remove nil
                        (list (when (plusp calls)
                                (%counts-clause-segs (first rung) calls style))
                              (when (plusp thinking)
                                (%counts-clause-segs (second rung) thinking nil))))))
    (if parts
        (append (list (cons "[" nil))
                (loop for p in parts
                      for i from 0
                      append (append (when (plusp i) (list (cons ", " nil))) p))
                (list (cons "]" nil)))
        ;; a run neither count can describe — this rung also hides head arrivals — falls back to
        ;; their count, because `[]` is not a marker, and THAT number is not a call count at all
        ;; so it takes no style
        (append (list (cons "[" nil))
                (%counts-clause-segs (third rung) (getf counts :events) nil)
                (list (cons "]" nil))))))

(defun %hidden-run-counts-text (items cols &optional count-rung live)
  "The counts as TEXT — `[N tool calls, M thinking lines]`, the same characters the segments draw.

**A zero clause is dropped**, which is letibot's own `counts.join(\", \")`: a run of tool calls says
`[2 tool calls]`, not `[2 tool calls, 0 thinking lines]` — the second number is ceremony about a row
nobody hid.

Kept as text for the MERGED PARAGRAPH, which folds the counts into the model's own sentence as a
string and has no segments to style; the marker itself draws `%hidden-run-counts-segs`.

**COUNT-RUNG chooses the spelling and defaults to the fullest**, which is the merged paragraph's
case: it has a whole paragraph to wrap in and no frame edge to clear, so it never needs a ladder."
  (format nil "~{~a~}"
          (mapcar #'car (%hidden-run-counts-segs items cols count-rung live))))

(defvar *marker-seam* nil
  "Whether the run marker's SEAM — ` · ctrl-t opens it` / ` · /verbosity` — is drawn.

**OFF by default, and that is the operator's ruling:** *\"also make showing \" dot /verbosity\" a
config and switch it off.\"* The seam is the head talking about its own key, and on a line whose whole
job is to be punctuation inside the model's sentence it is the one part that is not a fact.

**What turns it off is still there when it is off**, which is the R29 question and the reason this is
a preference rather than a deletion: the row it would have opened still says it can be opened — the
rung names itself on the alarm row, `ctrl-t` is in `%slash-completions` and in the hint bar, and the
counts are on the line pointing at the work. What goes is the advertisement on every marker.

**It is a variable rather than a head slot for the usual reason** — a struct layout change is a
restart — and because it changes what the ROW renders to, `%set-marker-seam` is the only writer and it
invalidates the history, exactly as `set-verbosity` does.")

(defun %set-marker-seam (on)
  "The ONE writer of `*marker-seam*`, and it invalidates the rendered history.

The seam is drawn into the marker, so a frame that cached the lines with it on would keep drawing it
with it off — the same defect the folds and the rung each had, and the same fix: bump the generation
at the writer."
  (setf *marker-seam* (and on t))
  (incf *hist-generation*)
  *marker-seam*)

(defun hidden-run-marker (items cols &optional newest live max-width)
  "The marker's SEGMENTS — `[N tool calls, M thinking lines] · ctrl-t opens it`.

**Two registers, and they say two different things.** The counts are a FACT — how much work there
was — and they are drawn in the PROSE's own register, because they are punctuation INSIDE the model's
sentence: `…has to give: [11 tool calls, 246 thinking lines]`. The seam is the HEAD talking about its
own keys, the same thing every other elided row says with `… +N lines · /t unfolds it`, and it is
**faint**: a note about a key rendered as more of the sentence it sits in is the one thing it is not.
That split is letibot's `marker_painted` plus the fact that only the seam is the head's voice.

**The counts are the two counts and nothing else** — no verbs, no targets, no summary line. The
narration above and the report below carry the act and the conclusion, so the marker carries neither;
this SUPERSEDES the verb-and-target sources R37's amendment first named.

**A zero clause is dropped**, which is letibot's own `counts.join(\", \")`: a run of tool calls says
`[2 tool calls]`, not `[2 tool calls, 0 thinking lines]`. The spelling itself lives in
`%hidden-run-counts-text`, so the marker and the merged paragraph cannot disagree about a run.

**The seam names the chord only on the run it acts on** (R40): the newest run's says
`ctrl-t opens it`; every other run's says ` · /verbosity`, the verb that does reach it. letibot lands
the same two strings, which is why they are here rather than invented.

**AND THE MARKER NEVER SPLITS AND NEVER OUTGROWS ITS ROOM.** The two clauses are spent down
`+hidden-run-marker-ladder+` until they fit `hidden-run-marker-room`, which is fixed for the frame —
so the counts gaining a digit cannot move the sentence above them and cannot push the seam onto a
line of its own. That was the operator's *\"at some point the line could be split so things jump
even more\"*, and this is the rung that answers it: growth is paid in words, not in layout.

**AND THE COUNTS GO YELLOW WHILE THE WORK THEY COUNT IS STILL RUNNING** — the operator's ruling:
*\"when you correctly do account running jobs in verbosity mode [], mark counters yellow if the tail
job is still running.\"*

**AND IT IS THE TOOL-CALL NUMBER, not the brackets and not the thinking count** — the operator's
second reading of his own ruling: *\"you should yellow only tool call number, not the whole [] thing.\"*
The yellow marks the one number that is still going up; the brackets are punctuation and the thinking
count is a count of a different kind of work, and colouring the whole marker would make it a highlight
rather than a signal.

A count that is still going up and a count that has stopped look exactly alike otherwise, and the
marker is the only thing on the screen that says how much work there is — so `[2 tool calls]` frozen
at two and `[2 tool calls]` about to become three are the same characters. Yellow is `Pending` in
this tree's own vocabulary: *is happening*, the same register the live card's `◐` mark takes for the
same reason. LIVE is what says so — it is non-nil exactly when this run has calls or reasoning in
flight (`%hidden-run-live-work`), so there is no second question to ask and nothing to thread.

The SEAM stays faint, and that is not an oversight: the counts are a fact about the work and the seam
is the head talking about its own key, so a yellow affordance would be the head shouting about itself.
When the run settles, the counts go back to the prose's own register with it."
  (let* ((room (or max-width (hidden-run-marker-room cols)))
         (limit (1- room))
         ;; **NO SEAM MEANS THE COUNTS, AND THE ROOM IS STILL THE ROOM.** The slots are kept even
         ;; when the seam is off: it is the sentence ABOVE this line that reserved them, and
         ;; shrinking the marker because it got shorter would move the sentence — the exact jump
         ;; `hidden-run-marker-room` exists to prevent.
         (rungs (if *marker-seam* +hidden-run-marker-ladder+ '((0 . 2))))
         ;; **THE TOOL-CALL NUMBER GOES YELLOW WHILE THE WORK IS STILL RUNNING, and `live` is the
         ;; whole question.** It is non-nil exactly when this run has calls or reasoning in flight,
         ;; so there is no second predicate to ask and nothing to thread down from the caller. The
         ;; style is handed to the counts builder, which puts it on the calls number alone.
         (counts-style (if live +role-pending+ nil))
         (segs nil))
    (dolist (step rungs)
      (let* ((seam-rung (aref +hidden-run-seam-rungs+ (cdr step)))
             (seam (if *marker-seam* (if newest (car seam-rung) (cdr seam-rung)) "")))
        (setf segs (append
                    (%hidden-run-counts-segs items cols (aref +hidden-run-count-rungs+ (car step))
                                             live counts-style)
                    (list (cons seam +role-faint+))))
        (when (<= (%segs-width segs) limit)
          (return))))
    ;; The room is the frame's, and the last rung is the last word: a marker nothing can shorten
    ;; still gets truncated rather than pushed past the edge, because counts off the screen are not
    ;; a marker at all. **Truncated to the LIMIT and not to the room**, so the one invariant holds
    ;; whichever way a marker is reached: it is at most `room - 1` wide, which is exactly what the
    ;; sentence above it left (see `hidden-run-marker-room`).
    (%truncate-segs segs (max 1 limit))))

(defun %marker-onto-last-line (il items cols &optional newest live)
  "IL with the run's marker **appended to its last line**, split by ONE SPACE.

**The space is the join, and it is what makes the counts read as part of the sentence.** letibot
writes `format!(\"{} {}\", prose, marker)`; the operator's screen without it read
`…commits.[3 tool calls, 7 thinking lines]` — *\"you miss spaces between [] and the sentence\"* —
where the bracket looks like it belongs to the last word rather than to the work the sentence
promised.

**THE MARKER IS FITTED TO THE SPACE THE LAST LINE ACTUALLY HAS — the last line only.** That is the
whole of this function, and getting it wrong cost the operator a line wrap they reported twice.

The first version was handed a prose already wrapped NARROWER by the marker's room — `cols - room`
for EVERY line — and it worked in the sense that the marker always fitted. It also broke every
sentence's wrap early for the sake of a marker that is almost never that wide. Measured on the
operator's terminal, 210 columns:

    Let me confirm where the            <- prose wrapped at 154 (210 - 56 reserved)
    committed history sits: [1 tool call, 23 thinking lines]

and the operator: *\"there is no need to have the line break here because the whole tail fits. you
didnt try the 'tool calls' -> 'tools' -> 't' progressing. so I complain about line wrapping here.\"*
They are right: the tail is 55 columns of a 210-column frame, and 56 columns were being held back
from a line that needed 55 once.

**So the prose wraps at the frame's own width, and the marker fits what is left of the last line.**
The ladder is the same one the marker's room uses (`+hidden-run-marker-ladder+`) and the same rule
applies at the end of it: **wrapping, not truncating**, because a count off the edge is a marker that
did nothing. A last line with no room left at all is the one case where the marker goes to its own
line, and that is a line that was already full of the sentence."
  (let* ((last (car (last il)))
         (used (loop for seg in last sum (string-width (car seg))))
         ;; what is left of the line once the sentence and its one joining space are in
         (room (- cols used 1))
         (marker (if (plusp room)
                     (hidden-run-marker items cols newest live (max 4 room))
                     nil)))
    (if (null marker)
        (butlast il)
        (append (butlast il)
                (wrap-segments (append last (list (cons " " nil)) marker) (max 20 cols))))))

(defun hidden-run-lines (items cols)
  "The ROWS a run stands for, for when it is OPEN — the rung lifted for these rows and no others.

**Opening is not a second rendering.** What this rung hides is exactly what `:terse` draws, so
binding the rung and calling the same renderer is the definition of *the work*. A bespoke *expanded
run* view would be a second way to draw a tool row, which is the copy this file keeps refusing to
make. The seam under them says how to fold it back.

**Only the OPEN case is lines.** Closed, the run is not lines at all — its counts are appended to the
sentence that points at it (`%marker-onto-last-line`), because a marker drawn as its own row is
exactly what the operator's final reading rejects. The one exception is a run with no visible row
older than it, which has no sentence to continue and stands on its own line (`%history-until`)."
  (let ((faint +role-faint+))
    (append
     (let ((*verbosity* :terse))
       (loop for item in items
             append (item-lines item cols (head-prefs *hidden-run-head*))))
     (list (list (cons (format nil "  … ctrl-t folds this back into ~d line~:p" (length items))
                       faint))))))

(defun %set-hidden-run-open (id)
  "The ONE writer of `*hidden-run-open*`, and it invalidates the rendered history.

**The same defect the payload window has, and the same fix**: whether a run is open changes what
those rows RENDER TO without moving the generation, the width or the items vector's identity — so
without the bump the cache serves the previous state back and the key looks dead. This tree has now
found that at six surfaces; the note here is that it is the price of a cached renderer, and the
place to pay it is the writer."
  (setf *hidden-run-open* id)
  (incf *hist-generation*))

;;; ------------------- R37's OPEN QUESTION, AS A SWITCH: one prose or two messages? ----- ;;;
;;;
;;; **From the operator, on the shape this produces:** *"so it will be then like this from model:
;;; Blablabla bla: [2 tool calls, 36 thinking lines]. Ok, now i understand blablabla:. and here I
;;; wonder if we have to render those two sentences like we do now - different messages because they
;;; arrived this way or we can compose a prose."*
;;;
;;; The narration and the report are TWO assistant items because a tool call split them. In this
;;; rung they sit next to each other with only the counts between. Two answers, and this file can
;;; draw both so the operator compares SCREENS rather than paragraphs:
;;;
;;;   · **two messages** (the default) - each its own paragraph, which is the blank line between
;;;     them; the item boundary is visible;
;;;   · **one prose** - the two texts merged into a SINGLE assistant row, so the paragraph wraps
;;;     once and the counts sit inside it. The item boundary is gone.
;;;
;;; Neither is obviously right, which is why the switch exists and the ruling is not this file's.

(defvar *reading-join-prose* nil
  "When true, `:reading` draws a narration and its report as ONE paragraph rather than two.

Off is the default and the shape this tree has always drawn: two rows, a blank between them.")

(defun %set-reading-join-prose (on)
  "The ONE writer: whether consecutive narration and report are joined into one paragraph.

It bumps the generation for the reason `set-verbosity` does - the switch changes what rows RENDER
TO without moving any of the line cache's three terms, so a frame would serve the old shape back."
  (setf *reading-join-prose* (and on t))
  (incf *hist-generation*)
  *reading-join-prose*)

(defvar *reading-joined* nil
  "`(SOURCE-VECTOR . JOINED-VECTOR)` - the merge memo, so a frame does not rebuild it.

Keyed on the SOURCE vector's identity, so a session that gains a row misses and a frame that does
not hits. Without it the joined vector would be a fresh object every call, `%hist-key` would differ
every frame, and the whole line cache would be dead - a toggle that made the head slow.")

(defun %reading-joined-items (items cols)
  "ITEMS with each `narration -> run -> report` merged into ONE assistant row.

**The merge is at the TEXT level, which is what *compose a prose* has to mean**: the two sentences
become one string - `narration` ++ the counts ++ the report - so a single `markdown-lines` call wraps
them as one paragraph. Two rows joined by deleting a blank line would still wrap as two paragraphs
and would still be two messages with the air turned off.

**Only the shape the operator named is merged**: an assistant row, a run of hidden rows, then
another assistant row. A row that is merely invisible does not break it (the run's own rule), and
anything the reader can SEE that is not assistant text - a report from a different kind of row, a
user message - ends the possibility, because there the item boundary is carrying real information.

The merged row is a COPY: the session's own plist is the session's, and this is a rendering."
  (if (and *reading-joined* (eq (car *reading-joined*) items))
      (cdr *reading-joined*)
      (let* ((n (length items))
             (out nil)
             (gap nil)
             (last nil))
        (labels ((assistant-text-p (it)
                   (let ((b (item-body it)))
                     (and b
                          (eq (%key-from-wire (getf b :type)) :assistant)
                          (plusp (length (string-trim " " (or (getf b :text) "")))))))
                 (invisible-p (it)
                   ;; **the same predicate the walk cuts runs with** — an invisible row neither joins
                   ;; a run nor ends one, so the merged paragraph and the drawn one agree.
                   (%row-invisible-p it cols))
                 (join-into (it)
                   (let* (;; **the COUNTS alone, with no seam**: in the merged paragraph the seam
                          ;; would sit mid-sentence, between the model's two halves, naming a chord
                          ;; for work the reader has not been shown yet. The counts are the sentence's
                          ;; punctuation; a key advertisement is not.
                          (marker (%hidden-run-counts-text gap cols))
                          ;; **the PLIST in a variable**: `(setf (getf (item-body last) :text) …)` is a
                          ;; `(setf item-body)` — a function call is not a place, and the head says
                          ;; so at the first eval rather than at the first frame.
                          (body (item-body last)))
                     (setf (getf body :text)
                           ;; **ONE SPACE before the counts and one after** — the merged paragraph is
                           ;; a sentence, and the operator's screen without the first space read
                           ;; `…commits.[3 tool calls]`, the bracket looking like it belonged to the
                           ;; last word. letibot writes `format!("{} {}", prose, marker)`.
                           (format nil "~a ~a ~a"
                                   (getf body :text)
                                   marker
                                   (getf (item-body it) :text))))))
          (dotimes (i n)
            (let ((it (aref items i)))
              (cond
                ((reading-hides-p it) (push it gap))
                ;; invisible: it neither joins a run nor ends one (the run's own rule)
                ((invisible-p it) nil)
                ;; **the merge** - narration, a run, report
                ((and last (assistant-text-p last) (assistant-text-p it) gap)
                 (join-into it)
                 (setf gap nil))
                (t (push (list :item-id (getf it :item-id)
                               :kind (getf it :kind)
                               :ts (getf it :ts)
                               :item (copy-list (item-body it)))
                         out)
                   (setf last (first out)
                         gap nil)))))
        (let ((joined (coerce (nreverse out) 'vector)))
          (setf *reading-joined* (cons items joined))
          joined)))))

(defun %run-continues-prose-p (item)
  "Does a run continue THIS row's sentence? — the rule is one-sided, and the bug named it.

**Only the MODEL's own prose carries a run's counts.** The operator's message does not. The screen
that named this rule was `▌ make verbosity a config option [2 tool calls] · ctrl-t opens it` — the
counts glued to the reader's OWN sentence, on any turn where the model worked without narrating
first. The operator: *\"the [] thing comes right after my message … add an empty line between them\"*,
and then, correcting the reading of when, *\"literally just happened without mid turns.\"*

So the row above the run must be an ASSISTANT row with text the reader can actually see. After
anything else — their own message, a system row, the top of the transcript — the marker stands as a
line of its own, **with the blank line prose gets**."
  (let ((body (item-body item)))
    (and body
         (eq (%key-from-wire (getf body :type)) :assistant)
         (plusp (length (string-trim " " (or (getf body :text) "")))))))

(defun %tool-result-lines (item body cols prefs)
  "One settled tool-result row — the reference's `TranscriptItem::ToolResult` arm,
followed step for step, because a screen comparison showed ours had folded the
reference's three rows into one:

    ▸ Ran \"cd … && python3 - <<'PY'…\" · ok · 13 lines     (header)
      P5 recorded                                        (the first line, dim)
      … +12 lines · ctrl-t                               (the seam, and the chord)

Ours put the seam ON the header and dropped the first line, so a folded row said
how much there was and nothing of what. And a ONE-line result, inlined on the
header, also printed `· 1 line` — a count for a fold with nothing to fold."
  (let* ((facts (item-facts (getf item :item-id)))
         (name (getf body :name))
         (outcome (getf body :outcome))
         (payload (or (getf body :payload) ""))
         (ms (getf facts :ms))
         (edit (or (getf facts :edit) (getf body :edit)))
         (open (getf prefs :show-tools))
         (word (outcome-name outcome))
         ;; bound HERE rather than where the header is built, because `outcome-style` below
         ;; needs it — the quiet register is what a row that went fine is drawn in
         (faint '(:dim t))
         ;; **`bad` IS THE STRUCTURE, NOT THE COLOUR.** It asks one question — did this call
         ;; come back `ok` — and it decides whether a one-line result may be inlined on the
         ;; header, whether a failed edit may draw its diff, and whether a failure with no
         ;; reason must show its body. Those are all about what there is to SHOW.
         (bad (not (string= word "ok")))
         ;; **THE COLOUR IS THE ROLE, and this row spelled the mapping a SECOND time.**
         ;;
         ;; It said `(if bad '(:fg :red) faint)`, so **every outcome that was not `ok` was a
         ;; failure** — and the operator, looking at a job that had just been moved to the
         ;; background, asked *"why on earth backgrounding message is in red"*.
         ;;
         ;; They were right to ask. `%outcome-style` is the one place this mapping lives and
         ;; it has said otherwise all along: abstained, denied and **backgrounded** are
         ;; `Attention`, not `Failure`, because a process that is still working must not be
         ;; drawn as something to retry. `call-lines` was already fixed to use it and its own
         ;; comment warns that *"it used to be spelled again here, and the two spellings
         ;; disagreed about `not_run` and about backgrounded"* — the second spelling was
         ;; **this row**, one function away, and it was still there.
         ;;
         ;; The reference's `display_outcome` (`app.rs:13973`) has `Backgrounded` as its own
         ;; variant for exactly this reason: *"not `Failed`, which would put a retry in front
         ;; of the operator for a command that is still working, and not `Ok`, which would
         ;; read as a finish."*
         ;;
         ;; **`ok` stays dim and does not become `Success`.** The settled row is quiet when
         ;; the call went fine — the whole row is faint on the screen — and a green line
         ;; under every command in the transcript is a colour that says nothing. Only a row
         ;; that wants the reader's eye takes a colour, and `%outcome-style` says which
         ;; colour that is. An outcome this build does not know is `pending`, the same
         ;; fallback `call-lines` uses, rather than the red this row used to guess.
         (outcome-style (if (string= word "ok")
                            faint
                            (or (%outcome-style outcome) +role-pending+)))
         (mark (if open "▾" "▸"))
         ;; **A ROW MAY STATE ITS OWN VERB AND SUBJECT** (R24), and it is here rather
         ;; than in a second renderer because the derivation below is a DEFAULT and not
         ;; a rule: a tool row's verb comes from the tool's name and its subject from
         ;; the `Assistant` row that proposed the call — and a call nobody proposed has
         ;; neither. A compaction is one: the daemon runs it, no row proposed it, and
         ;; what belongs on the headline is its numbers. Both fields are optional, and
         ;; every other tool result takes exactly the path it took before.
         (verb (%tool-row-verb body))
         (subject (%tool-row-subject body))
         (decision (getf facts :decision))
         ;; Sanitised FIRST and filtered second, the reference's order
         ;; (app.rs:9712) — a payload's bytes are the command's, not this
         ;; terminal's (`%without-control`) — and then the envelope lines, which
         ;; are addressed to the model, are not output.
         (rows (%tool-payload-rows body))
         (n (length rows))
         (ind (activity-indent cols))
         (w (max 20 (- cols ind)))
         (size-style (if (>= n +big-output-lines+) '(:bold t) faint))
         (shown-word (%outcome-word word))
         (took (if (numberp ms) (format nil " · ~a" (duration ms)) ""))
         ;; **WHO ASKED FOR THIS CALL** — `nil` for the model's own, which is every row
         ;; that has no `origin` at all. See `%call-origin-said`.
         (asked (let ((said (%call-origin-said body)))
                  (if (and said (plusp (length said)))
                      (format nil " · by ~a" said)
                      "")))
         ;; the tail is measured FIRST and the subject is given what is left
         (tail-cols (+ 3 (string-width shown-word) (string-width took)
                       (string-width asked)
                       3 6 (length (format nil "~d" n))))
         (lead (+ (length mark) 1 (length verb) 1))
         (subject (%shorten-subject subject (max 8 (- w lead tail-cols))))
         ;; **the actor's segment is APPENDED, not always present**, so a row the model
         ;; proposed has the same SEGMENTS in the same order as it had before this field
         ;; existed — not merely the same text.
         (head (append (list (cons mark outcome-style)
                             (cons (format nil " ~a " verb) faint)
                             (cons subject nil))
                       (when (plusp (length asked)) (list (cons asked faint)))
                       (list (cons (format nil " · ~a" shown-word) outcome-style)
                             (cons took faint))))
         (head-width (%segs-width head))
         (why (%outcome-why outcome))
         (out nil))
    (labels ((emit (line) (push line out))
             (dim-line (text)
               (list (cons "  " faint)
                     (cons (truncate-to-width (or text "") (max 4 (- w 2))) faint)))
             (decision-lines ()
               ;; the approval this call was gated by, in the dim register — the
               ;; same block the live card draws, carried across with the card
               (when decision
                 (emit (list (cons (format nil "  · ~a, by ~a"
                                           (%decision-word decision)
                                           (%decision-who decision))
                                   faint)))
                 ;; and, open, what it was grounded in — `decision_detail`, the
                 ;; whole block rather than the one line we drew. The decider's
                 ;; own line is dropped when the payload already carries it
                 ;; verbatim: the operator, counting the repeats in one card,
                 ;; *"how many times is 'nothing ran' needed?"*
                 (when open
                   (let* ((b (getf decision :basis))
                          (first (and b (string-trim " " (%first-line b))))
                          (echoed (and first (>= (length first) 40)
                                       (some (lambda (l) (search first l)) rows))))
                     (dolist (l (%decision-detail decision (max 4 (- w 4))
                                                  :skip-basis echoed))
                       (emit (list (cons "    " faint) (cons l faint)))))))))
      ;; A result of ONE line goes on the header — one row where the folded form
      ;; is two, and the second carried the count and a chord for a fold with
      ;; nothing to fold. Not for an edit with an excerpt: that draws its diff.
      (let ((inline (and (not bad) (= n 1) (null edit)
                         (let ((l (%strip-gutter (first rows))))
                           (and (plusp (length l))
                                (<= (+ head-width 3 (string-width l)) w)
                                l)))))
        (when inline
          (emit (append head (list (cons " · " faint) (cons inline nil))))
          (decision-lines)
          (return-from %tool-result-lines (nreverse out))))
      ;; the count, Strong once the output is big enough to be worth a fold. No
      ;; `· ctrl-t` here: the chord belongs on the seam row below, which exists
      ;; exactly when something is hidden.
      (emit (%truncate-segs
             (append head (list (cons (format nil " · ~d line~:p" n) size-style)))
             w))
      ;; The reason, on its own wrapping line, in the outcome's role: the first
      ;; sentence always, the rest with ctrl-t — a refusal's reason is a DOCUMENT
      ;; addressed to the model, and printing it whole "throws up on the chat".
      ;; When the payload says the same line it is not said twice.
      (let* ((why-folded nil))
        (when why
          (let* ((first (string-trim " " (%first-line why)))
                 (echoed (and (>= (length first) 40)
                              (some (lambda (l) (search first l)) rows)))
                 (shown (if (and open (not echoed))
                            why
                            (let ((gist (%first-sentence why)))
                              (setf why-folded (< (length gist) (length why)))
                              gist))))
            (dolist (l (wrap-segments (list (cons shown nil)) (max 4 (- w 2))))
              (emit (cons (cons "  " outcome-style)
                          (mapcar (lambda (seg) (cons (car seg) outcome-style)) l))))))
        (decision-lines)
        ;; a file edit draws its DIFF, not the tool's prose: folded keeps the
        ;; first hunk's opening rows, open shows it whole
        (when (and edit (member (car (cdr (assoc (string-downcase (or name "")) *verb-map*
                                                 :test #'string=)))
                                '(:edit :write))
                   (not bad))
          (let* ((rows (edit-lines edit (- w 2) :folded nil
                                   :split (string= (or (getf prefs :diff) "unified") "split")))
                 (keep (if open (length rows) (min 8 (length rows))))
                 (hidden (- (length rows) keep)))
            (dolist (l (subseq rows 0 keep))
              (emit (cons (cons "  " nil) l)))
            (when (plusp hidden)
              (emit (list (cons (format nil "  … +~d diff rows · /t unfolds it" hidden)
                                faint)))))
          (return-from %tool-result-lines (nreverse out)))
        ;; Folded shows the first line, which is where a tool puts what it did,
        ;; then the seam: `… +N lines`, a separator row and not a sentence — it is
        ;; not content, it is where content was taken out — and the chord goes on
        ;; it, where there is something for it to do. Open, or a failure with no
        ;; reason printed above it, shows the body up to the budget.
        ;;
        ;; **FOLDED, OPEN, AND A WINDOW INTO IT.** Three states and not two, and the
        ;; third is what makes the rest of a long result reachable: the fold alone
        ;; raises the BUDGET, and a budget is not an offset — a 418 KB log was
        ;; readable to its fortieth line however many times the chord was pressed.
        ;;
        ;; The window is the reference's (app.rs:10828-10893): `shown` includes the
        ;; seam rows, the body gives up one for a seam that is present and one more
        ;; for the one above when the reader has paged past the top, and `below`
        ;; decides whether there is more. Every seam says which key does what NOW —
        ;; the chord opens the view, the arrows move inside it, esc closes it —
        ;; because a row that named only the chord was the row that could not be read
        ;; past its head.
        (let* ((window (payload-view-for item))
               (page (if window (min window (max 0 (1- n))) 0))
               ;; **THE WINDOW IS THE ROW'S OWN LENGTH, NOT THE FOLD'S** (R40). This read
               ;; `(or open …)`, so a window that was open on a row whose conversation was not
               ;; unfolded drew ONE body line and paged one line per keypress — and the only way
               ;; to give one result its rest was to unfold every result in the session, which is
               ;; exactly what made `ctrl-t` a wall. `window` is first for that reason: the
               ;; reader asked for THIS row's rest, and the fold's state is a different question
               ;; about a different scope.
               (shown (if (or window open (and bad (null why)))
                          +body-lines-budget+ 2))
               (above (plusp page))
               (body-rows (max 1 (- shown 1 (if above 1 0))))
               (end (min n (+ page body-rows)))
               (below (< end n)))
          (when above
            (emit (list (cons (format nil "  ↑ ~d more lines above · ↑ scrolls up" page)
                              faint))))
          (dolist (l (subseq rows page end)) (emit (dim-line l)))
          (cond
            (below
             (emit (list (cons (format nil "  … +~d lines · ~a" (- n end)
                                       (cond
                                         ;; the window is open on THIS row: the keys are the
                                         ;; window's own
                                         (window "↓ pages down · esc closes")
                                         ;; **the chord, on the row it acts on**, and the verb
                                         ;; everywhere else (R40). `ctrl-t` opens the window on
                                         ;; the newest long result; `/t` unfolds every tool row,
                                         ;; after which this row's own window can be paged.
                                         ((newest-payload-row-p item) "ctrl-t opens it")
                                         (t "/t unfolds it")))
                               faint))))
            ;; The end of the payload, SAID — so "no more" cannot be confused with
            ;; "the arrow stopped working", which is the other half of a seam's job.
            (window
             (emit (list (cons "  … end of output · esc closes" faint))))
            ;; the payload was short enough to show whole, but the REASON was
            ;; cut — so the affordance has to be here
            (why-folded
             (emit (list (cons "  … the rest of the reason · /t unfolds it" faint)))))))
      ;; `item-lines` steps the whole row in by the activity indent
      (nreverse out))))

(defparameter +body-lines-budget+ 40
  "The reference's `Budget::body_lines`: a block over this many rows is shown as
its title, an elision count and its tail.")

(defparameter +reasoning-lines-budget+ 8
  "The reference's `Budget::reasoning_lines`, the same bound for a reasoning block.")

(defun reasoning-line-count (text width)
  "How many SCREEN lines TEXT costs at WIDTH — the reference's count, and the only one used.

Extracted from `reasoning-header` when R37's marker needed the same number: the marker says *43
thinking lines* and a header beside it says *43 lines*, and two pieces of arithmetic for one
quantity is how they come to disagree. The model writes its working-out as a handful of very long
paragraphs, so *lines* means what the terminal will spend, not how many newlines are in the text."
  (max 1 (reduce #'+ (mapcar (lambda (l) (max 1 (ceiling (string-width l) (max 1 width))))
                             (uiop:split-string (or text "") :separator '(#\newline)))
                 :initial-value 0)))

(defun reasoning-header (text cols open running)
  "`▸ Thought · 13 lines · ctrl-r` — the fold's own header, which is also where
its key is advertised: there is no pointer here and no selection, so the header
naming its chord is the whole discoverability mechanism.

The count is SCREEN lines, not source lines, as the reference counts them: the
model writes its working-out as a handful of very long paragraphs, so \"3 lines\"
beside a fold that opens to half a screen answers the wrong question. And the
mark is PLAIN, not dim — measured against letibot's row, where only the tail after
the word is faint."
  (let* ((w (max 20 (- cols (activity-indent cols))))
         (n (reasoning-line-count text w)))
    (%truncate-segs
     (list (cons (if open "▾ " "▸ ") nil)
           (if running
               (cons "Thinking…" '(:dim t :italic t))
               (cons "Thought" '(:bold t)))
           (cons (format nil " · ~d line~:p · ctrl-r" n) '(:dim t)))
     w)))

(defun reasoning-lines (text cols prefs &key running)
  "A reasoning block: the header, and — open — its body under the `┃ ` rail, in
the dim-italic register, rendered as markdown two columns narrower than the row so
the wrap and the rail agree. Folded, the header alone."
  (let ((open (getf prefs :show-reasoning)))
    (cons (reasoning-header text cols open running)
          (when open
            (mapcar (lambda (l)
                      (cons (cons "┃ " '(:dim t))
                            (mapcar (lambda (seg)
                                      (cons (car seg)
                                            (if (cdr seg)
                                                (append (cdr seg) '(:dim t :italic t))
                                                '(:dim t :italic t))))
                                    l)))
                    (markdown-lines text :width (max 20 (- cols (activity-indent cols) 2))
                                         :limit +reasoning-lines-budget+))))))

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

(defparameter +job-notice-prefix+ "[job] "
  "The daemon's own opening for a job-settlement notice (`harness.rs:661`, `completion_notice`).

**The prefix is the daemon's, not this head's invention** — the same discipline as keying a note's
remedy on its CODE: a settlement arrives as a `User` row with `speaker: agent` and nothing else to
identify it, so the text is what says what it is, and this is the one word in it that is the
daemon's own voice rather than a job's.")

(defun %job-notice-p (text)
  "Is TEXT the daemon's job-completion notice? — R41's own message, in its own voice."
  (and (stringp text)
       (uiop:string-prefix-p +job-notice-prefix+ text)))

(defun %job-notice-parts (text)
  "TEXT split into `(values OPENING FACTS REST)`.

  · **OPENING** — the daemon's first line, as written (`a job you backgrounded has ended:`);
  · **FACTS** — the `  - \`ID\` …` lines, one per settled job, in the daemon's own words;
  · **REST** — the closing paragraph, which is a promise TO THE MODEL (*you do not need to wait for
    it*) rather than anything the reader needs told.

The split is on the daemon's own shape and not on a guess: the fact lines are the ones that begin
with `- ` after trim, and everything after them is the closing sentence."
  (let* ((lines (uiop:split-string text :separator '(#\newline)))
         (opening (or (first lines) ""))
         (tail (rest lines))
         (facts (remove-if-not (lambda (l) (uiop:string-prefix-p "- " (string-left-trim " " l)))
                               tail))
         (rest (remove-if (lambda (l) (uiop:string-prefix-p "- " (string-left-trim " " l)))
                          tail)))
    (values opening
            (mapcar (lambda (l) (string-left-trim " -" l)) facts)
            (string-trim " " (format nil "~{~a~^ ~}" rest)))))

(defun %job-notice-facts (text)
  "The settlement's facts as ONE line — `j152 killed by job_kill after 27.6s, wrote 15 bytes`.

**Built from the daemon's own sentence and not from a summary of it**, which is R37's ladder
applied to a second surface: the source that costs nothing is the one already computed, and a
settlement arrives with the job, its ending, its duration and its byte count already spelled out.
The backticks go because they are markdown for the MODEL — the reader is looking at a rendered
screen, not at the prompt.

**A model was offered for this and is not needed**, and the measurement is the reason: every fact
the reader wants is in this line before anything reads it. That is worth writing down because *a
model could summarize it* is the shape of answer that adds a latency and a failure mode to a path
that has neither."
  (let* ((facts (multiple-value-bind (o f r) (%job-notice-parts text)
                  (declare (ignore o r)) f))
         ;; **the backticks are REMOVED, not blanked.** `substitute` put a space where each one was,
         ;; which read ` j152  killed by job_kill` — two spaces for every quote, measured on the
         ;; first run of this. They are markdown for the MODEL; the reader is looking at a
         ;; rendered screen.
         (one (mapcar (lambda (f)
                        (string-trim " "
                                     (remove #\` (string-trim " " f))))
                      facts)))
    (cond ((null one) nil)
          ;; **ONE JOB NAMES ITSELF**; several are COUNTED and their ids listed. Sized to what it
          ;; describes — the same adaptivity R37's marker has, and the same reason.
          ((= 1 (length one)) (first one))
          (t (format nil "~d jobs ended (~{~a~^, ~})"
                     (length one)
                     ;; **the IDS**, which is what a reader scanning for one of them wants — the
                     ;; first token of each fact line is the daemon's job id and nothing else.
                     (mapcar (lambda (f) (subseq f 0 (or (position #\space f) (length f))))
                             one))))))

(defun %job-notice-rows (text)
  "The daemon's notice as rows a reader can OPEN — R41's own vocabulary, verbatim.

**The full message is what `ctrl-t` reveals**, minus nothing: the facts, the command in full, and
the closing sentence. Re-wording any of it here would be a second copy of the daemon's meaning, and
the point of the one-liner is that the reader may choose to read the whole thing."
  ;; **the backticks go here as well as in the one-liner.** They are markdown for the MODEL, and
  ;; this is the screen: a reader opening the window to read the command should not be reading the
  ;; quoting the prompt needed.
  (mapcar (lambda (l) (remove #\` l))
          (uiop:split-string text :separator '(#\newline))))

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
             ;; `%job-notice-facts`) — so the line costs nothing and is true by construction. That
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
                     (seam (if (>= head-cols 60) " · ctrl-t opens it" " · ctrl-t"))
                     (named (and item (newest-payload-row-p item) t))
                     (room (if named (max 8 (- head-cols (length seam))) head-cols))
                     ;; **the chord only on the row it acts on** (R40): the window opens on the
                     ;; NEWEST openable row, so a seam elsewhere would name a key that does
                     ;; nothing. Silence is the honest seam; a lie is not.
                     (facts-segs (%truncate-segs
                                  (list (cons (format nil "~a~a"
                                                      +job-notice-prefix+
                                                      (or (%job-notice-facts text) "a job settled"))
                                              nil))
                                  room)))
                (list (if named
                          (append facts-segs (list (cons seam +role-faint+)))
                          facts-segs))))
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

`item-display-text` (session.lisp) still does the old concatenation; it feeds
search and the pane summaries, and it is another strand's file. The RENDERING
reads this one."
  (format nil "~{~a~^ ~}"
          (mapcar (lambda (p)
                    (switch ((or (getf p :kind) "text") :test #'string=)
                      ("image" (format nil "[image ~a]" (or (getf p :media-type) "")))
                      ("file_ref" (format nil "[file ~a]" (or (getf p :path) "")))
                      (t (or (getf p :text) ""))))
                  (getf body :parts))))

(defun step-in-lines (lines n)
  "LINES set N columns further in — the model's WORKING, under what it SAYS.

`activity-indent` existed and was used only to compute a subject's WIDTH, never to
move a row: measured against letibot's screen, its cards sit at column 4 and its
prose at column 2, while every row of ours was at 2. The step is what says a tool
call is subordinate to the answer rather than beside it, and it costs no colour.

An EMPTY row stays empty: trailing spaces on a blank line are invisible until
something copies them."
  (if (zerop n)
      lines
      (mapcar (lambda (line)
                (if (null line)
                    line
                    (cons (cons (make-string n :initial-element #\space) nil) line)))
              lines)))

(defparameter +note-remedies+
  '(;; **the reader ASKED for something that does not exist.** The act is to see what
     ;; does; there is nothing to fix and saying so is the honest remedy.
     ("slash_refused" . "nothing to fix — that verb does not exist. /help lists the ones that do; ctrl-n clears this note")
     ("mode_unknown" . "nothing to fix — that mode name does not exist. /mode with no argument opens the picker")
     ("answer_unclaimed" . "nothing to fix — the ask was already answered. /status counts it; ctrl-n clears this note")
     ;; **a REFUSAL with a way round it.**
     ("job_output_refused" . "nothing can be done — that job's output is gone from the daemon and nobody holds it. /job lists the ones it still has")
     ("mode_set_refused" . "nothing was changed — the mode you named was not applied. /mode opens the picker")
     ("reseat_refused" . "/reseat rebuilds the prompt from the tools seated now; the conversation was NOT replaced")
     ("length_batch_refused" . "the turn was not sent as one batch; ask again, or split it")
     ;; **the session is under pressure and the reader can act.**
     ("context_wall" . "this turn stopped: /compact summarises now, or /new starts a fresh session")
     ("auto_compact_skipped" . "automatic compaction is off for this session; /compact runs one now")
     ("auto_compact_no_progress" . "compacting again will not help; /new starts a fresh session")
     ("auto_compact_failed" . "/compact runs one now, by hand, and says what it did")
     ("compacted" . "nothing to do — the session compacted itself; /notes lists the record")
     ("auto_compact" . "nothing to do — the session is compacting itself")
     ("reseated" . "nothing to do — the prompt was rebuilt from the tools seated now")
     ;; **the session's INTEGRITY is in doubt, and there is no act.**
     ("ledger_chain_mismatch" . "nothing can be done from here — the ledger will not replay. /status has the counters; the store holds the evidence")
     ("row_coverage_gap" . "nothing can be done from here — the store and the log disagree. /gate corpus reads both")
     ("transcript_store" . "nothing can be done from here — the store refused the write. /status counts it")
     ("decision_corpus" . "nothing can be done from here — the corpus row was not written")
     ("prefix_divergence" . "the cached prefix is not the one the server holds; the next turn re-sends it and costs a full re-prefill")
     ("prefix_check_skipped" . "nothing to do — the prefix check does not run on this provider (D10)")
     ("log_gap" . "/resync takes a fresh snapshot; the gap is counted by /status")
     ("protocol_skew" . "nothing will fix it from here — the two halves speak different versions. Restart the head or the daemon")
     ("unreadable_frame" . "this head reads past frames it cannot parse; /verbosity loud shows the envelope")
     ("gate_timeout" . "nobody answered in time. /gate recent shows the decision, /gate todo lists any still open")
     ("gate" . "/gate recent shows what the gate decided; /gate ok|grant|revoke rules on one afterwards")
     ("turn_failed" . "the turn stopped. ctrl-r shows the working-out it got to; ask again")
     ("session_unavailable" . "/resume brings a stored session back; /sessions lists them")
     ("resume_failed" . "/sessions lists what the daemon can actually reach")
     ("mode_unpersisted" . "the mode is live in this process and not on disk; /mode again after a restart")
     ("mode_set_next_session_only" . "this applies to the NEXT session; /new starts one")
     ("mode_session_only" . "nothing to do — this applies for this session only")
     ("secret_late" . "nothing to do — the password was already given by another head")
     ("sudo" . "nothing to do — the daemon reports it; the ask itself is a card")
     ("daemon_stopping" . "nothing to do — the daemon is going down, by request")
     ("ended_in_reasoning" . "the turn stopped mid-thought; ctrl-r shows it and asking again continues")
     ("reasoning_stall" . "nothing to do — the model was thinking without writing; the turn is still running")
     ("repetition_collapse" . "the turn was cut short by a repeat detector; asking again usually gets past it")
     ("interrupt_idle" . "nothing to do — there was no turn running to interrupt")
     ("promote_idle" . "nothing to do — no command was running to background")
     ("cache_reuse_shortfall" . "nothing to do — the cache was reused less than the daemon hoped; /status has the numbers")
     ("fabric_refresh_failed" . "nothing can be done from here — the fabric did not refresh")
     ("flowy_not_seated" . "/flowy login [SEAT] attaches a seat; /flowy status shows whether one is held")
     ("monitor_wake_not_armed" . "nothing can be done from here — a fired monitor wakes the model only on job_list")
     ("frame_capture_written" . "nothing to do — the frame was written where the daemon was told to put it")
     ("frame_capture_disabled" . "set the capture variable the detail names, and restart the daemon, to capture frames")
     ("frame_capture_failed" . "nothing can be done from here — the capture write failed; the detail names the path")
     ("title_not_stored" . "nothing can be done from here — the title did not reach the store")
     ("record_item_pairing" . "nothing can be done from here — an item arrived without its pair")
     ("orphan_body" . "nothing can be done from here — a body arrived with no row to hang it on")
     ("absolute_path" . "nothing to do — a path in the arguments was absolute, which is a note about the call")
     ("endpoint" . "nothing can be done from here — the model endpoint refused; the detail names it")
     ("model_endpoint_retry" . "nothing to do — the endpoint was retried and answered")
     ("dated" . "nothing to do — the data is older than the session")
     ("data_claim" . "nothing to do — a claim in the answer was flagged; the detail says which")
     ("imported" . "nothing to do — the import finished")
     ("import_scrap" . "nothing to do — part of the import was skipped; the detail says how much")
     ("imported_summary" . "nothing to do — the import finished and was summarised")
     ("open_note" . "nothing to do — a note was opened; /notes lists it")
     ("resume_note" . "nothing to do — the session was resumed")
     ("reattached" . "nothing to do — this head reattached to the daemon")
     ("slash" . "nothing to do — that is a command's reply; /notes lists it, ctrl-n clears it")
     ("steering_urgent" . "nothing to do — the daemon marked the steering urgent")
     ("test" . "nothing to do — a test note")
     ;; the three the coverage test found missing on its first run — which is the test
     ;; doing its job: a code the head draws with no entry is the dead end R29 is about.
     ("mode_set" . "nothing to do — the mode is set for this session; /mode opens the picker")
     ("reseat_unchecked" . "nothing to do — the re-seat went ahead without checking the tool list; /tools shows what is seated")
     ("length_empty_turn" . "the turn carried no message and was not sent; type something and press enter again")
     ;; **R24 part two's own report, and the entry names the act rather than filling the slot.**
     ;; The code says the operator's call ran; what the reader may want next is what came back
     ;; of it, and that is on the row — so the honest remedy points at the row. R29's rule is
     ;; that the ENTRY exists and names the reason; `nothing to do — …` satisfies it, and
     ;; inventing a verb here to look useful would be the failure that test is written against.
     ("operator_call_ran" . "nothing to do — the call you asked for ran; the row under this note holds what it returned"))
  "What the reader can DO about a note, per code — R29 rule one, on the note.

**A note that states a fact and not the act is a dead end on the screen.** The operator,
meeting two red rows from `/diff` and `/qwe` on a head whose `/dismiss` had worked for two
days: *when this red shit is show it should hint what to do next.* The affordance
existed and the note did not mention it — so the rule is that the remedy is ON THE NOTE,
not in the hint bar, not in `/help`, not in a key the reader has to already know.

**An empty slot is not allowed**, and that is the load-bearing half: the honest entries
here include a great many `nothing to do — …` and `nothing can be done from here — …`,
because *nothing is wrong* and *this cannot be fixed from the glass* are real answers and
the operator's own rule says so (*nothing can be done and here is why satisfies this
rule*). What is forbidden is silence. A test walks the head's own code set and fails on a
code with no entry, so a new code cannot arrive without somebody deciding which of the
three it is.

**Why a table in the head and not a field from the daemon**: the ACT is the head's. The
daemon knows what happened; only this file knows that the gesture for clearing a note is
`ctrl-n`, that the picker is behind `/mode`, and that the corpus reader is `/gate corpus`.
letibot composes its own for the same reason, and R29 requires the two heads to OFFER a
remedy in the same places, not to say the same words.")

(defun note-remedy (w)
  "The line that says what the reader can DO about W, or NIL for a code this head does
not know.

NIL is for an unknown code only — an old head meeting a new daemon's warning names
nothing, because any sentence here would be invented. Every code in this head's own set
has an entry, which is what the suite checks."
  (cdr (assoc (getf w :code) +note-remedies+ :test #'string=)))

(defun item-lines (item cols prefs)
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
    (return-from item-lines nil))
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
      (return-from item-lines nil))
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
       ;; It is the SAME renderer as the tail echo (`queued-lines`), handed the one text this row
       ;; is drawing: one pending message, two places it can sit, and one shape for both.
       ;;
       ;; `*payload-head*` because `item-lines` is handed an item and a preference list and nothing
       ;; else — the arrangement every other row-level global here has. With no head in scope (a
       ;; test, a pane, a file measuring rows) the row draws NOTHING, which is what it drew before:
       ;; the fallback is the old behaviour rather than a guess.
       (let ((bound (bound-prompt-for item)))
         (when (and bound *payload-head*)
           (queued-lines *payload-head* cols (list bound)))))
      (t
       (step-in-lines
        (case (intern (string-upcase (getf body :type)) :keyword)
         ((:user)
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
         ((:assistant)
          ;; The answer sits at the body's own column, with the question: it is
          ;; the one thing on the screen not subordinate to something else.
          ;;
          ;; **An empty row draws NOTHING.** Ours drew a lone `·`, which left a
          ;; row of punctuation between every pair of cards — measured against
          ;; letibot's screen, where an assistant row with no prose and no
          ;; unanswered call is simply absent.
          ;;
          ;; **And a call with no result gets a `→` row**, which is what survives
          ;; of the proposal: a call the transcript has taken over is drawn by its
          ;; RESULT, and drawing it here too is two rows and one fact. `→` therefore
          ;; means exactly "asked for, nothing came back" — the turn was
          ;; interrupted, or the body has not arrived.
          ;;
          ;; **Wrapped to the width it has**, and bounded at the reference's
          ;; `body_lines` budget. `markdown-lines` used to be called with no width
          ;; at all and `%place-lines` clips, so every paragraph longer than the
          ;; terminal was CUT at its edge — measured against letibot's screen,
          ;; where the same paragraphs wrapped to two rows.
          (let ((rows (when (plusp (length (getf body :text)))
                        (markdown-lines (getf body :text) :width cols
                                                          :limit +body-lines-budget+))))
            (append
             rows
             ;; **`→ {verb} {target} · no result`, the whole line in
             ;; `Role::Attention`** (app.rs:9614-9645). Four things were wrong
             ;; and one of them is the row's entire meaning: the reference's own
             ;; note is that *"a row that looks like every other tool row and
             ;; quietly has no output is the shape a person reads straight past.
             ;; It is the only thing this row now means."* A call the transcript
             ;; has taken over is drawn by its RESULT; what survives here is the
             ;; case the proposal line is actually for — the turn was
             ;; interrupted, the round is still running, or the body has not
             ;; arrived.
             ;;
             ;; The target is derived from the arguments ON THIS ROW and never
             ;; looked up by call id: the row holds the very bytes the rule
             ;; reads, and an id-keyed lookup is how `→ Read TODO.md` came to sit
             ;; above a card whose payload was `README.md`. An EMPTY target earns
             ;; the call id its columns, because that is then the only thing
             ;; distinguishing two calls to the same tool. The indent is the
             ;; activity step (ours hard-coded two, which is wrong below sixty
             ;; columns), and the row is trimmed to the width like every other.
             ;; **the settled row's half of `ctrl-x`** (app.rs:11055-11061). A live
             ;; turn shows the raw markup the model WROTE, from the `ToolCall`
             ;; deltas; once the row is committed the markup is gone — the parser
             ;; read it — so what is left to show is the name and the arguments it
             ;; read, which is the fact the markup encoded. Without this arm the pref
             ;; did nothing at all on a transcript, which is every row but the one
             ;; being written.
             ;; **and the CALLS go with them** (R37): a tool call is the head's working, and
             ;; a row that kept its `→ Read src/cards.lisp · no result` line while claiming to
             ;; hide tool calls would be the half-hiding this rung exists to avoid. The row's
             ;; TEXT is untouched — it is the conversation.
             (when (and (not (reading-p)) (getf prefs :raw-calls))
               (loop for tc in (getf body :tool-calls)
                     when (and (call-answered-p (getf tc :id))
                               (plusp (length (or (getf tc :arguments) ""))))
                       append (raw-call-lines
                               (format nil "~a ~a" (getf tc :name)
                                       (getf tc :arguments))
                               cols)))
             (unless (reading-p)
               ;; **`append`, not `collect`** — a row of the head's working can be more than
               ;; one LINE (a running card with a body, an edit with a diff), and `collect`
               ;; takes ONE item per call. Collected, the lines arrived as a single element and
               ;; the row was nested one level too deep: the reader saw `(  )` — a list printed
               ;; where a string belonged — which is how this was caught.
               (loop for tc in (getf body :tool-calls)
                   unless (call-answered-p (getf tc :id))
                     append (let* ((tgt (display-target (getf tc :arguments)))
                                   (id (getf tc :id)))
                              (if (%call-running-p id)
                                   ;; **A CALL THAT IS RUNNING IS DRAWN RUNNING, WITH ITS CLOCK
                                   ;; — and this is the half the row was missing.**
                                   ;;
                                   ;; The operator, watching a `cargo test` that took two
                                   ;; minutes: *"you do 'blablabla:' and then long ass tool call
                                   ;; and I see nothing — literally indistinguishable from
                                   ;; connection break or a crash. told you long time ago — to
                                   ;; start counting before running command."*
                                   ;;
                                   ;; MEASURED on their own screen, capturing it at 6s, 14s and
                                   ;; 24s while a command ran: the three frames were **byte
                                   ;; identical**. The row was `→ Ran "…" · no result` — the form
                                   ;; below, all of it `Role::Attention` — and it did not move.
                                   ;; `→` means *asked for, nothing came back*, which is what a
                                   ;; row says about a turn that was INTERRUPTED; saying it
                                   ;; about a command running right now is the one reading it
                                   ;; must not carry, and it is the reading the operator had.
                                   ;;
                                   ;; So a running call takes the LIVE card's own header —
                                   ;; `◐ {Verb} {subject} · 1.2s`, the very `call-lines` the turn
                                   ;; pane draws for it. ONE renderer, so the row and the live
                                   ;; card cannot drift into two announcements of one call, and
                                   ;; the number is `%live-elapsed-ms` over `%call-elapsed-ms`,
                                   ;; whose clock starts at `ToolStarted` — when the command
                                   ;; started, not when the model asked for it, so a call that
                                   ;; waited on a decision does not count that wait as running
                                   ;; time (`app.rs:3996-4005`).
                                   (step-in-lines
                                    (call-lines (list :call-id id
                                                      :name (getf tc :name)
                                                      :target tgt
                                                      :state (list :state "running"))
                                                (max 20 (- cols (activity-indent cols)))
                                                prefs)
                                    (activity-indent cols))
                                   ;; **started, and nothing came back** — the turn was
                                   ;; interrupted, or the body has not arrived yet. This is what
                                   ;; `→` is for, and the whole of what the row now means
                                   ;; (app.rs:9614-9645).
                                   (let ((line (format nil "→ ~a~a · no result"
                                                       (verb-label (getf tc :name))
                                                       (if (plusp (length tgt))
                                                           (format nil " ~a" tgt)
                                                           (format nil " (~a)" id)))))
                                     (list (%truncate-segs
                                            (list (cons (make-string (activity-indent cols)
                                                                     :initial-element #\space)
                                                        nil)
                                                  (cons line +role-attention+))
                                            cols))))))))))
         ((:reasoning)
          ;; **The model's working-out, so it can never be mistaken for its
          ;; answer.** Three signals, because any one is lost somewhere: the WORD
          ;; (`Thought`), the RAIL (`┃`, two columns), and the dim-italic
          ;; attribute — de-emphasis by COLOUR alone is a no-op under a
          ;; terminal-native palette, so the attribute is what carries it.
          ;;
          ;; Folded by default, like a card and like letibot: `▸ Thought · 20
          ;; lines · ctrl-r`. A settled row is by definition not running, so the
          ;; word is `Thought`; `Thinking…` belongs to the live turn.
          (reasoning-lines (getf body :text) cols prefs :running nil))
         ((:tool_result) (%tool-result-lines item body cols prefs))
         ;; **`system (Bootstrap)` on its own line, then the text, all dim**
         ;; (app.rs:9544-9548). Ours drew `◦ ` and the text in YELLOW with no
         ;; origin at all — and the origin is the fact: the system prompt the
         ;; session opened with and a later change to it are two different
         ;; events, and only one of them means somebody reconfigured the model
         ;; mid-conversation. Yellow is `Pending`, which says something is
         ;; happening; a system row is the quietest thing in a transcript.
         ;;
         ;; `Bootstrap`/`Update` capitalised, because the reference prints the
         ;; enum with `{:?}` while the wire spells it `bootstrap`.
         ((:system)
          (let ((origin (or (getf body :origin) "")))
            (cons (list (cons (format nil "system (~a)"
                                      (if (plusp (length origin))
                                          (format nil "~a~a" (char-upcase (char origin 0))
                                                  (subseq origin 1))
                                          origin))
                              +md-faint+))
                  (mapcar (lambda (l)
                            (mapcar (lambda (seg) (cons (car seg) +md-faint+)) l))
                          (wrap-segments (list (cons (or (getf body :text) "") nil))
                                         cols)))))
         ;; **A `/compact` boundary is a row** (app.rs:10042-10044). The `case`
         ;; had no arm for it, so it fell to `(t nil)` and a segment boundary —
         ;; the one place in a transcript where the model's memory of everything
         ;; above it changed — drew nothing at all.
         ((:segment_mark)
          (list (list (cons (format nil "─── ~a ───" (or (getf body :label) ""))
                            +md-faint+))))
         ;; **A ROW FETCHED BACK FROM THE SESSION** (`FetchRow`) — a row older than
         ;; this head's window, pulled in one at a time as the reader scrolls to the
         ;; top. It is its own type because the head knows only what the frame says:
         ;; a body and an ordinal. `RowFetched` carries no kind, no name and no
         ;; timestamp, so drawing it as a tool card or as prose would be inventing
         ;; facts about a row the head has never seen — what it CAN say is where the
         ;; row sits in the session and what the body is.
         ;;
         ;; Folded like every other long thing here: the head of it, and a seam saying
         ;; how much more there is. `:total` is the WHOLE body's length from the
         ;; daemon, so the seam counts what the window did not carry rather than
         ;; guessing from the lines that arrived.
         ((:fetched)
          (let* ((row (getf body :row))
                 (text (or (getf body :text) ""))
                 (total (or (getf body :total) 0))
                 (rows (wrap-segments (list (cons text nil)) cols))
                 (cap +body-lines-budget+)
                 (hidden (max 0 (- (length rows) cap)))
                 (shown (if (plusp hidden) (subseq rows 0 cap) rows)))
            (append
             (list (list (cons (format nil "  ▸ row ~d of the session" row) '(:dim t)))
                   (list (cons (format nil "    ~a line~:p" (length rows)) '(:dim t))))
             (mapcar (lambda (l) (mapcar (lambda (seg) (cons (car seg) nil)) l)) shown)
             ;; the seam names the BYTES the window left behind when the daemon said
             ;; the body is longer than one fetch, and the rows when it did not — two
             ;; different truncations and only one of them may be claimed
             (when (plusp hidden)
               (list (list (cons (format nil "    … +~d line~:p~@[ · +~d bytes~]"
                                         hidden
                                         (let ((sent (length text)))
                                           (and (> total sent) (- total sent))))
                                 '(:dim t))))))))
         ;; **A ROW THIS HEAD WROTE ABOUT ITSELF.** No daemon item has this type — the
         ;; wire's are `user`, `assistant`, `reasoning`, `tool_result`, `system` and
         ;; `segment_mark` — so this is the head filing a sentence of its own into the
         ;; conversation at the point it happened. `note-unreadable` and `note-warning`
         ;; are the writers, and the contract is the one the reference's `warn_line`
         ;; keeps: an `!`, the words, and the failure role (app.rs:8425-8427).
         ;;
         ;; **`:cap` and `:seam` fold a long one** (R10). A warning's detail can be a
         ;; whole rule, and the operator-facing complaint was a WALL of them — 27 red
         ;; lines from two gate timeouts. A note with a `:cap` shows that many rows and
         ;; a `:seam` naming the verb that has the rest, and the seam is DIM rather than
         ;; failure-role because it is not part of the warning: it is the instrument.
         ;; The whole text is still what `/notes` prints, so this folds a disclosure
         ;; and never the record.
         ((:note)
          ;; **TWO REGISTERS, and R19 part 2 is why** (letibot `1a0d1f2`-era ruling).
          ;; `! …` in the failure role is the reference's `warn_line` and it is right
          ;; for a refusal, a gate timeout or a context wall. It was WRONG for
          ;; `compacted` and `auto_compact` — the session doing exactly what it should,
          ;; arriving in the same red as a denial — and the operator's words are the
          ;; requirement: *"a housekeeping notice and a refused call must not look
          ;; alike."*
          ;;
          ;; The register is read off the warning the ROW carries, through the one
          ;; table (`routine-warning-p`) and the one glyph (`warning-glyph`), so this
          ;; cannot disagree with the `/notes` listing about the same note. A routine
          ;; note is faint with a `·` instead of loud with a `!`, and the two are
          ;; distinguishable at a glance, which is the whole test — an operator who
          ;; learns to skip the red block is an operator who will skip the denial that
          ;; lives in it.
          ;;
          ;; A row this head files about ITSELF — `note-unreadable`, a protocol skew —
          ;; carries no `:warning`, so `routine-warning-p` answers NIL and it stays in
          ;; the failure register, which is right: those are the head saying it could
          ;; not do its job.
          ;;
          ;; **The failure register is unchanged**, deliberately: this moves codes OUT
          ;; of it only where the fact is *nothing is wrong*, and a code nobody has
          ;; classified stays red.
          (let* ((w (getf item :warning))
                 (routine (routine-warning-p w))
                 (glyph (warning-glyph w))
                 (role (if routine +role-faint+ +role-failure+))
                 (rows (wrap-segments
                        (list (cons (format nil "~a ~a" glyph (or (getf body :text) "")) nil))
                        cols))
                 (cap (getf body :cap))
                 (seam (getf body :seam))
                 (hidden (and cap seam (> (length rows) cap) (- (length rows) cap)))
                 (out (mapcar (lambda (l)
                                (mapcar (lambda (seg) (cons (car seg) role)) l))
                              (if hidden (subseq rows 0 cap) rows)))
                 ;; **R29 RULE ONE: the note carries its own remedy.** Drawn AFTER the
                 ;; seam, deliberately — the seam says how much text was cut, and a
                 ;; remedy that the cap could cut is a remedy that was not offered,
                 ;; which is the whole failure R29 is about. It is dim in every register
                 ;; (the note's own role says how loud the FACT is; the remedy is an
                 ;; instruction, not a second alarm), and it is one line plus its wrap.
                 (remedy (note-remedy w)))
            (append out
                    (when hidden
                      (list (list (cons (format nil "  … +~d line~a · ~a"
                                                hidden (if (= hidden 1) "" "s") seam)
                                        '(:dim t)))))
                    (when remedy
                      (mapcar (lambda (l) (list (cons l '(:dim t))))
                              (wrap-text (format nil "  → ~a" remedy)
                                         (max 20 (- cols 2))))))))
         (t nil))
        ;; the step: reasoning and tool calls are the model WORKING, under the
        ;; answer. Speech — the operator's message and the model's prose — sits at
        ;; the body's own column, which is what says it is the conversation.
        (case (intern (string-upcase (getf body :type)) :keyword)
          ((:reasoning :tool_result) (activity-indent cols))
          (t 0)))))))

(defun %call-elapsed-ms (call)
  "How long a running call has been going, from the moment its ToolStarted arrived.

**On THIS head's clock, anchored when the event ARRIVED** — `note-call-started`
records `internal-real-time-ms` at `:tool-started`, and nothing here reads the
envelope's `ts`. That is not an accident to preserve, it is the trap avoided: the
daemon's `ts` is the daemon's clock and `internal-real-time-ms` is ours, and a
duration measured across the two is silently wrong by whatever they disagree by —
worst exactly when a head attaches to a daemon on another box, which is where this
fleet is going. The question the row answers is *how long have I been waiting*, and
the reader's clock is the right one for that.

It is short by the delivery latency of the one frame that started the call, and that
is the honest cost of answering in one clock rather than two. The alternative the
document offers — have the daemon report an elapsed — needs a progress event, and the
whole point here is not to need one."
  (let ((start (cdr (assoc (getf call :call-id) *call-started-ms* :test #'string=))))
    (and (numberp start) (max 0 (- (internal-real-time-ms) start)))))

(defun %live-elapsed-ms (ms)
  "MS rounded DOWN to a tenth, for a duration that is still moving.

**Coarse on purpose, and it is the operator's number**: what the row answers is *is
this moving, and roughly how long has it been — a live coarse timer would be nice,
say 1/10th of a second*. A figure that turned over on every millisecond would churn
two digits nobody reads, and — the reason it is here rather than left to the
formatter — it would spend a frame saying what the next frame says again. The frame
is rebuilt a tenth apart (`+live-frame-ms+`), so a tenth is the finest thing that can
reach the screen anyway; rounding here makes the number honest about its own
resolution instead of pretending to a precision it cannot deliver.

**The SETTLED duration is not rounded** — `note-call-finished` measures it once,
exactly, and the row shows that (app.rs:2702-2713 is the reference's arithmetic, and
it is not changed here). Only a number that is still moving is coarse."
  (* 100 (floor (max 0 (or ms 0)) 100)))

(defun %verb-kind (name)
  "The `card::Verb` a tool name maps onto, or NIL when nobody knows it."
  (car (cdr (assoc (string-downcase (or name "")) *verb-map* :test #'string=))))

(defun %budget-for-verb (name)
  "(FIRST . LAST) body rows a verb's card deserves — `Budget::for_verb`
(card.rs:298-304).

Reading a file wants enough head to see what it is and enough tail to see it
ended (5/3); a shell command's tail is what matters and its head almost never is
(2/3); anything else 10/3. The numbers are grok-build's, kept because they were
measured there and not here."
  (case (%verb-kind name)
    ((:read :list) (cons 5 3))
    ((:run) (cons 2 3))
    (t (cons 10 3))))

(defparameter +expanded-max-rows+ 400
  "`Budget::expanded_max`. A 40,000-line result expanded into a terminal is not
\"expanded\", it is the conversation gone.")

(defun head-tail-lines (lines first last)
  "FIRST lines, then LAST lines, and a row saying how many went — `head_tail`
(card.rs:512-532).

The marker is a SEPARATOR ROW and not a line of the content, because a reader
must never mistake the elision for output. It is never a silent cut: the count
is the disclosure, the same rule the log applies to `dropped`."
  (if (<= (length lines) (+ first last 1))
      lines
      (let ((hidden (- (length lines) first last)))
        (append (subseq lines 0 first)
                (list (list (cons (format nil "… +~d lines" hidden) '(:dim t))))
                (when (plusp last) (last lines last))))))

(defun call-lines (call cols &optional prefs)
  "One tool call of the running turn — the reference's `card::Card::header`:

    ○ Read src/cards.lisp · proposed
    ◐ Reading src/cards.lisp · 1.2s
    ● Read src/cards.lisp · 27ms

The mark carries the phase (faint / pending / the outcome's role), the verb is
Strong and in the running TENSE — a card that says `Ran` while the command is
still going lies about the one thing it exists to say — the target is Plain, and
the tail is faint unless the outcome is not `ok`. Ours drew `· bash → running` in
three colours, none of them the reference's."
  (let* ((st (getf call :state))
         (state (getf st :state))
         (running (string= state "running"))
         (finished (string= state "finished"))
         (outcome (getf st :outcome))
         (word (and finished (outcome-name outcome)))
         (bad (and finished (not (string= word "ok"))))
         ;; `Phase::Running`'s mark is `Pending`; a settled one takes the
         ;; OUTCOME's role, and `%outcome-style` is the one place that mapping
         ;; lives now — it used to be spelled again here, and the two spellings
         ;; disagreed about `not_run` and about backgrounded.
         (outcome-style (if finished
                            (or (%outcome-style outcome) +role-pending+)
                            +role-pending+))
         (mark (cond (running (cons "◐" +role-pending+))
                     (finished (cons "●" outcome-style))
                     (t (cons "○" '(:dim t)))))
         (target-raw (or (getf call :target) ""))
         (note (getf call :progress-note))
         (ms (and finished (getf (alexandria:assoc-value *call-facts* (getf call :call-id)
                                                          :test #'string=)
                                 :ms)))
         (tail (remove nil
                       (cond
                         (running (list (duration (%live-elapsed-ms (%call-elapsed-ms call)))
                                        note))
                         (finished (append (and (numberp ms) (list (duration ms)))
                                           (and bad (list (%outcome-word word)))
                                           (and bad (list (%outcome-why outcome)))))
                         (t (list (or note "proposed"))))))
         (joined (and tail (format nil " · ~{~a~^ · ~}" tail)))
         (tail-style (if bad outcome-style '(:dim t)))
         (verb-str (verb-label (getf call :name) :running running))
         ;; **THE TAIL IS MEASURED FIRST AND THE SUBJECT IS GIVEN WHAT IS LEFT** — R25's rule,
         ;; and the whole reason the operator could not tell a running command from a crash.
         ;;
         ;; The header tail is *dropped whole when it does not fit* below, so a long command
         ;; pushed the clock off the row and the one number that says **this is alive** went
         ;; with it. MEASURED on their screen: `◐ Running "cd /tmp && (sleep 6; …) & …"` — the
         ;; mark and the running tense, and no `· 12.4s` anywhere, on a command with two
         ;; hundred characters of arguments.
         ;;
         ;; The tail does not shrink — it is the fact, and half of `· 12.4s` is not a duration.
         ;; What gives way is the SUBJECT, which is what `%shorten-subject` is for and what
         ;; `%tool-result-lines` already did. One rule, two rows: measured against letibot's
         ;; screen, a subject that runs to the edge is how the reference draws it too.
         (fixed (+ 2 (string-width verb-str) 1))    ; mark, space, verb, space
         (target (if (plusp (length target-raw))
                     (%shorten-subject target-raw
                                       (max 8 (- cols fixed
                                                  (if joined (string-width joined) 0))))
                     ""))
         (head (list mark
                     (cons " " nil)
                     (cons verb-str '(:bold t))
                     (cons (if (plusp (length target)) (format nil " ~a" target) "") nil))))
    ;; **The card's BODY, which had three of its four parts missing**
    ;; (app.rs:8767-8864, card.rs:482-511). Built in the reference's order and
    ;; then given the reference's budget.
    (let* ((open (getf prefs :show-tools))
           (inline-bytes (getf st :inline-bytes))
           (full-bytes (getf st :full-bytes))
           (spill (getf st :spill))
           (decision (getf (alexandria:assoc-value *call-facts* (getf call :call-id)
                                                   :test #'string=)
                           :decision))
           (edit (getf st :edit))
           (body nil))
      ;; §8.3's disclosure, as prose and in units a person reads. In the BODY
      ;; rather than the header tail, because the header tail is dropped whole
      ;; when it does not fit and "there is more, and here is how to get it" is
      ;; not a line that may vanish on a narrow terminal. It is the one line on
      ;; this card with an obligation attached.
      (when (numberp inline-bytes)
        (setf body
              (list (list (cons (if spill
                                    (format nil "~a of ~a went to the model, the rest is kept — read_spill hash=~a"
                                            (bytes-human inline-bytes)
                                            (bytes-human (or full-bytes inline-bytes))
                                            spill)
                                    (bytes-human inline-bytes))
                                '(:dim t))))))
      ;; a file-editing call carries both sides of the change (event.rs:75), and
      ;; the diff REPLACES the body rather than following it. Two columns
      ;; narrower than we had it: the card indents its body by two, and `ind` was
      ;; in effect being subtracted twice.
      (when (and edit (member (%verb-kind (getf call :name)) '(:edit :write)))
        (setf body (edit-lines edit (- cols 2))))
      ;; the approval this call was gated by, in the dim register: a fact about
      ;; the call, not a stray note. It was on the settled row and NOT here, so
      ;; the one moment a person can still act on it was the one moment it was
      ;; not shown.
      (when decision
        (setf body (append body
                           (list (list (cons (format nil "· ~a, by ~a"
                                                     (%decision-word decision)
                                                     (%decision-who decision))
                                             '(:dim t))))))
        (when open
          (setf body (append body
                             (mapcar (lambda (l)
                                       (list (cons "  " '(:dim t)) (cons l '(:dim t))))
                                     (%decision-detail decision (max 4 (- cols 4))))))))
      (cons (if (and joined (<= (+ (%segs-width head) (string-width joined)) cols))
                (append head (list (cons joined tail-style)))
                (%truncate-segs head cols))
            ;; `Card::render`: the budget over the body, then two columns of
            ;; indent, then every row trimmed to the width. A folded card with a
            ;; sixty-row diff drew all sixty rows here; the reference draws ten,
            ;; a marker, and three.
            (let ((budget (%budget-for-verb (getf call :name))))
              (mapcar (lambda (l) (%truncate-segs (cons (cons "  " nil) l) cols))
                      (if open
                          (head-tail-lines body +expanded-max-rows+ 0)
                          (head-tail-lines body (car budget) (cdr budget)))))))))

(defun %edit-lines-text (text)
  "TEXT as a list of lines. An empty side is NO lines, not one empty line:
a pure insertion has no `before`, and rendering that as a blank line claims a
line was there (`ToolEditExcerpt::before` — \"empty when the side has no lines
in the range\")."
  ;; and ONE trailing empty is dropped, as `str::lines()` does: the unified card
  ;; drew a signed, numbered blank row at the foot of every diff whose side ended
  ;; in a newline, claiming a line that is not in the file. `%lines-of` is the
  ;; one rule; this is its caller, not a second copy of it.
  (%lines-of text))

(defun edit-lines (edit cols &key (folded nil) (split nil))
  "The diff of an EDIT, as segment lines.

This is the twice-requested diff, and it is why `render-diff` exists: the edit
carries both sides and the excerpt's place in each file, so the engine can show
hunks with context, line numbers, and word-level emphasis inside a changed line.
The old version printed every removed line and then every added line —
unnumbered, unemphasised, no context and no notion of what actually changed —
which is what the operator reported as *\"nothing really shown\"*.

`before_start`/`after_start` are 1-based lines of the WHOLE file, so the gutter
numbers the file and not the excerpt (\"a diff numbered from 1 tells the reader
line 4 changed when it was line 313\")."
  (when edit
    (let* ((path (getf edit :path))
           (created (getf edit :created))
           (head-line (list (list (cons (format nil "  ~a~a" path
                                                (if created " (new)" ""))
                                      '(:bold t :fg :cyan)))))
           (body (if split
                     ;; the two-panel view, when the operator has asked for it
                     ;; (`/config`'s diff row): before on the left, after on the
                     ;; right, the sign column carrying the change
                     (edit-split-lines edit cols)
                     (render-diff (%edit-lines-text (or (getf edit :before) ""))
                              (%edit-lines-text (or (getf edit :after) ""))
                              :width (max 20 (- cols 4))
                              :context 3
                              :line-numbers t
                              ;; **Both reference call sites pass `intra_line:
                              ;; false`** (app.rs:8817, 9934). The wiring for word
                              ;; emphasis was dead here — `%pair-rows` bound
                              ;; `add-start` after consuming the addition run —
                              ;; and fixing that made this head start emitting
                              ;; emphasis the reference deliberately suppresses.
                              ;; `render-diff`'s own default stays T, matching
                              ;; `DiffConfig::default`; the choice belongs at the
                              ;; call site, which is what the reference's two are.
                              :intra-line nil
                              :max-rows (if folded 8 60)
                              :old-start (or (getf edit :before-start) 1)
                              :new-start (or (getf edit :after-start) 1))))
           (tail (when (getf edit :truncated)
                   (list (list (cons
                                (format nil "  … the excerpt was capped; the file is ~a lines now"
                                        (or (getf edit :after-lines) 0))
                                '(:dim t)))))))
      (append head-line body tail))))

(defun awhen-edit-lines (edit cols)
  "Both sides of an edit, as a real diff. See `edit-lines`."
  (edit-lines edit cols))




(defun turn-footer-lines (turn cols)
  "The line under a finished turn — and only when it ended UNUSUALLY.

**Not the numbers.** I put `─ 1.01M in/1.01M cached · 91 out · 17.8 tok/s · 5.1s`
here, and the comparison against letibot's own screen showed a whole telemetry row
where it draws NOTHING: measured, row 58, ours 56 columns of numbers and its zero.
The reference's rule is that an ORDINARY ending reads as ordinary — `eos` and
`word` produce no line at all — and that the turn's numbers live on the composer
box's bottom edge while it is running (`turn-status`), not in the transcript.

So one line, yellow, and only for the endings a person must not have to go looking
for. `Failed` is a different register: red, shouted, and WRAPPED rather than
truncated, because the reason is the whole content of the event."
  (when turn
    (let* ((state (getf turn :state))
           (name (and state (getf state :state)))
           (finish (and state (getf state :finish-reason))))
      (flet ((say (text style) (list (list (cons text style)))))
        (cond
          ;; an ordinary ending is ordinary: no line
          ((and (string= name "finished")
                (member finish '("eos" "word") :test #'string=))
           nil)
          ((and (string= name "finished") (string= finish "length"))
           (say "── CUT SHORT — it hit the output limit mid-answer; ask it to continue"
                '(:fg :yellow)))
          ((and (string= name "finished") (string= finish "aborted"))
           (say "── stopped early (aborted)" '(:fg :yellow)))
          ((string= name "finished")
           ;; a reason nobody recognises is SHOWN, never normalised
           (say (format nil "── ended for an unrecognised reason: ~a" finish)
                '(:fg :yellow)))
          ((string= name "interrupted")
           (say (format nil "── interrupted: ~a (~a)" (getf state :reason)
                        (if (getf state :partial-kept)
                            "what it had written is kept" "nothing kept"))
                '(:fg :yellow)))
          ;; **Wrapped, not truncated** (app.rs:8232-8245). The rule is already
          ;; written three paragraphs up in this docstring and the code did the
          ;; opposite: `cols` was declared ignored and the line was emitted
          ;; whole, so a long provider error was cut at the frame's edge — and
          ;; the reason is the whole content of the event. A failure is not an
          ;; ending a turn is allowed to have, so it does not read like one.
          ((string= name "failed")
           (mapcar (lambda (l)
                     (mapcar (lambda (seg) (cons (car seg) '(:fg :red :bold t))) l))
                   (wrap-segments
                    (list (cons (format nil "── FAILED — ~a (~a)" (getf state :error)
                                        (if (getf state :partial-kept)
                                            "what it had written is kept"
                                            "nothing was recorded"))
                                nil))
                    (max 20 cols))))
          ;; running: the numbers belong on the box's edge, not here
          (t nil))))))

(defun queued-lines (head cols &optional texts)
  "Prompts sent that the transcript does not hold yet, marked `queued`.

**TEXTS is which pending prompts to draw, and it defaults to the head's whole queue.** The tail
echoes and an ANNOUNCED row are the same message at two moments — see `*bound-prompts*` — so the
one renderer takes the list rather than a second shape being built beside it. The tail passes the
queue minus everything a bound row is already drawing; the bound row passes just its own text.

A prompt sent while a turn runs is queued as a FOLLOW-UP USER ITEM, and the item is
appended only at the next step boundary — which for a turn with no tool calls is
the turn's end. Between the enter press and that append the words existed NOWHERE
on the screen: the composer had handed them off, the daemon had accepted them, and
the operator was looking at a conversation that had swallowed a sentence they had
just typed.

It comes back at the boundary, so nothing is lost — but NOT LOST and VISIBLE are
different requirements, and this is the second one.

**The shape a settled user row gets**, dimmed, with `queued` where the timestamp
goes (`queued_lines`, app.rs:9017-9046). Ours drew a bright-cyan `›`, put the tag
at the END of the line, and showed only the FIRST line of a multi-line prompt —
so a pasted paragraph queued as one sentence and then grew into a block when the
boundary landed, which reads as the head having changed what was sent.

The bar is `▌` in `UserAccent`, so the pending row occupies the place its real
row will take; the tag is `Role::Pending`, the colour the spinner already uses
for something in flight; and continuation rows hang under the text by the tag's
own columns. `/cells` is folded here as well as in the user row, and it has to
be the SAME text going in: the pending row is cleared by matching the user item
the daemon appends, so a head that queued an abbreviation and received the real
thing would leave the `queued` line on the screen for the rest of the session."
  (let ((w (max 20 cols)))
    ;; **THE TAG IS PER ENTRY, not per pane** (R16): an echo a snapshot could not
    ;; resolve is not `queued` — the head can no longer support that claim — and
    ;; saying queued anyway is the lie R2 exists to prevent.
    ;;
    ;; **The layout is the reference's rule applied to whichever word is there**: the
    ;; first row shares its width with the tag and the continuations hang under the
    ;; text, by `width(tag) + 3` (`app.rs:9017-9046`). So an `unconfirmed` echo
    ;; measures its own word rather than being padded to the other's — the reference's
    ;; arithmetic, on a tag it does not have.
    (let ((open (getf (head-prefs head) :show-tools))
          ;; **NOTHING A BOUND ROW IS ALREADY DRAWING IS DRAWN HERE** — the tail is for the queue,
          ;; which is what is NOT in the conversation yet (letibot's rule; see `*bound-prompts*`).
          (bound (mapcar #'cdr *bound-prompts*)))
      (loop for text in (reverse (or texts
                                    (remove-if (lambda (q) (member q bound :test #'equal))
                                               (head-queued head))))
            for tag = (if (member text *queued-unconfirmed* :test #'equal)
                          "unconfirmed"
                          "queued")
            for head-w = (max 8 (- w 2 (string-width tag) 3))
            for indent = (make-string (+ (string-width tag) 3) :initial-element #\space)
            append (let* ((rows (or (wrap-segments
                                     (list (cons (%fold-cells text) nil)) head-w)
                                    (list (list (cons "" nil)))))
                          ;; **R33: A THING WAITING IS ONE ELIDED HEADLINE.** The operator,
                          ;; looking at three of their own messages queued: *"three giant
                          ;; messages queued"* — and three of them filled a 63-row pane,
                          ;; the conversation pushed off the screen. They wrote it; they do
                          ;; not need it read back. What the row owes them is *your message
                          ;; is here and in flight*, which one row says, plus enough of it to
                          ;; recognise if they want to — not the whole of it.
                          ;;
                          ;; **The unit of the seam is SCREEN ROWS**, the same choice
                          ;; `reasoning-header` makes: a pasted paragraph is one source line
                          ;; that costs forty rows, so "1 line" beside a row that would eat
                          ;; half the pane answers the wrong question.
                          ;;
                          ;; **`/t` opens it — the head's own *unfold the long rows* verb**,
                          ;; which is letibot's ruling (`app.rs:6194-6203`) and is the same
                          ;; choice this head makes everywhere else: one key for one idea, and
                          ;; a second fold chord for a second kind of row is a second thing to
                          ;; learn. The operator asked for *expandable the usual way*, and
                          ;; this is the usual way, so the seam names THE KEY THE READER ALREADY
                          ;; HAS rather than a new one.
                          (closed (< 1 (length rows)))
                          (headline (first rows))
                          (headline-w (reduce #'+ headline :key (lambda (seg) (string-width (car seg)))
                                              :initial-value 0)))
                     (if (or open (not closed))
                         (loop for row in rows
                               for i from 0
                               collect (append
                                        (list (cons "▌ " '(:fg :blue)))
                                        (list (if (zerop i)
                                                  (cons (format nil "~a · " tag) +role-pending+)
                                                  (cons indent nil)))
                                        (mapcar (lambda (seg) (cons (car seg) +md-faint+))
                                                row)))
                         ;; **ONE ROW, and the seam fits or the seam goes — never a second
                         ;; row.** A seam that does not fit would push the echo to two rows and
                         ;; undo the requirement on exactly the narrow screens where it matters
                         ;; most, so the ellipsis the truncator adds is the fallback.
                         (let* ((seam (format nil "  … +~d line~:p · /t opens it"
                                              (1- (length rows))))
                                (room (- head-w (string-width seam))))
                           (list (append
                                  (list (cons "▌ " '(:fg :blue)))
                                  (list (cons (format nil "~a · " tag) +role-pending+))
                                  (mapcar (lambda (seg) (cons (car seg) +md-faint+))
                                          (%truncate-segs headline (if (>= room 16) room head-w)))
                                  (when (>= room 16)
                                    (list (cons seam '(:dim t)))))))))))))

(defun turn-lines (turn cols prefs)
  "The running turn, live, in the reference's order: the working first —
reasoning, then the calls, each stepped in — and the answer under it, with a
blank row after each part that is there. A finished turn renders from the
transcript instead (view.rs on TurnView.appended) — rendering both would show the
answer twice.

Folded reasoning still shows its LAST line under the header, on the rail: the
operator can see the model is still thinking and what about, without opening it.
Calls are drawn oldest first — the session pushes them, so the list is newest
first and was drawn that way."
  (when (and turn (string= (turn-state-name turn) "running"))
    (let ((ind (activity-indent cols))
          (out nil))
      ;; **R37: the rung hides the WORKING of a live turn and never the turn.** What goes is
      ;; the reasoning and the calls — the head's account of producing an answer. What STAYS
      ;; is the answer itself, the footer under it (`turn-footer-lines`, drawn separately at
      ;; the tail), and every blank row's position: a turn that is running must still be
      ;; visible AS running, or a ten-minute tool-heavy turn draws nothing at all and the
      ;; reader cannot tell working from wedged. That is the rung's own stated risk.
      (flet ((emit (lines) (setf out (append out lines))))
        (unless (reading-p)
          (alet (getf turn :reasoning)
          (when (plusp (length it))
            (emit (step-in-lines
                   (if (getf prefs :show-reasoning)
                       (reasoning-lines it cols prefs :running t)
                       (list (reasoning-header it cols nil t)
                             (let ((last (or (car (last (remove-if (lambda (l) (zerop (length (string-trim " " l))))
                                                                    (uiop:split-string it :separator '(#\newline)))))
                                             "")))
                               (list (cons "┃ " '(:dim t))
                                     (cons (truncate-to-width last (max 4 (- cols ind 2)))
                                           '(:dim t :italic t))))))
                   ind))
            (emit (list nil))))
          (let ((calls (reverse (getf turn :calls))))
            (when calls
              (emit (step-in-lines (mappend (lambda (c) (call-lines c (- cols ind) prefs)) calls) ind))
              (emit (list nil)))))
        (alet (getf turn :text)
          (when (plusp (length it))
            (emit (markdown-lines it :width cols :limit +body-lines-budget+))
            (emit (list nil))))
        ;; The raw `<function=…>` markup the model wrote, when ctrl-x has asked for
        ;; it. NOT a fold: a fold hides something the reader knows is there, while
        ;; this reveals markup the default view is required never to show, so it is
        ;; off unless asked for by name.
        (when (and (not (reading-p)) (getf prefs :raw-calls))
          (let ((raw (getf turn :raw-calls)))
            (when (and (stringp raw) (plusp (length raw)))
              (emit (raw-call-lines raw cols))))))
      out)))

(defun raw-call-lines (raw cols)
  "The raw, unparsed text of a tool call, behind `ctrl-x` — the reference's
`raw_call_lines` (`app.rs:10135-10152`).

    ┌─ raw tool call · ctrl-x
    │ {\"path\": \"src/cards.lisp\", \"old_string\": \"…\"}
    └─

**A labelled block and not an inline row**, and the reason is the whole point of the
control: this is NOT the assistant speaking. Faint frame, and the text itself in the
code role — it is EVIDENCE, and evidence that looks like prose is how the defect
started. The seam names the chord, because a block nobody can turn off again is a
trap.

**One function for both callers**, which is why it is here and not beside either of
them: the LIVE turn draws the `<function=…>` markup as the model writes it
(`turn.lines`, from the deltas), and a SETTLED row has no markup left — the parser
ate it — so it draws `{name} {arguments}` instead. Two renderers would have drifted
into two different-looking blocks for one control.

**COLS is required, and it is R25's other half.** This wrapped at
`(1- *target-max-cols*)` — 119 columns whatever the pane was — so a 227-column window
drew a raw call as a 119-column column of text with a hundred columns of nothing
beside it. That is the same defect as the headline's and it showed up in the same
audit: **a wrapper on a display path that does not know its width cannot wrap
honestly.** The rail costs two columns, so the text gets `(- cols 2)`, and the
remainder is disclosed by `wrap-text` rather than clipped by the painter."
  (let ((out (list (list (cons "┌─ raw tool call · ctrl-x" '(:dim t))))))
    (dolist (l (uiop:split-string (or raw "") :separator '(#\newline)))
      (dolist (w (wrap-text l (max 1 (- cols 2))))
        (push (list (cons "│ " '(:dim t)) (cons w nil)) out)))
    (push (list (cons "└─" '(:dim t))) out)
    (nreverse out)))

(defun decision-card-lines (head cols)
  "The ask card: transcript visible above, one list on the screen at a time
(agents.md). A permission has the ladder; a question has choices."
  (let ((d (first (session-open-decisions (head-session head)))))
    (when d
      (let* ((kind (getf d :kind))
             (question (string= kind "question"))
             (options (if question (getf d :choices) (getf d :options)))
             (sel (head-decision-sel head))
             (body nil))
        (push (list (cons (format nil " ~a " (if question "question" "permission"))
                          '(:bold t :fg :yellow))
                    (cons (format nil " ~a" (or (getf d :summary) ""))
                          '(:bold t)))
              body)
        (when (plusp (length (or (getf d :target) "")))
          (push (list (cons " " '(:fg :yellow))
                      (cons (getf d :target) '(:fg :bright-white)))
                body))
        (when (plusp (length (or (getf d :detail) "")))
          (push (list (cons (format nil " ~a" (getf d :detail))
                            '(:dim t)))
                body))
        (when (plusp (length (or (getf d :because) "")))
          (push (list (cons (format nil " because: ~a" (getf d :because))
                            '(:italic t :dim t)))
                body))
        (let ((i 0))
          (dolist (o options)
            (let* ((label (if question o (getf o :label)))
                   (chosen (= i sel))
                   (style (cond (chosen '(:reverse t :bold t))
                                (t nil))))
              (push (list (cons (format nil " ~a ~a. " (if chosen "❯" " ") (1+ i)) style)
                          (cons (or label "?") style))
                    body))
            (incf i)))
        (push (list (cons (format nil " enter answers · up/down moves · esc ~a"
                                  (if question "leaves it open" "does nothing"))
                          '(:dim t)))
              body)
        ;; WHERE THE WORDS GO. The option is labelled "Deny, and tell the model
        ;; why" and nothing said how — which is how the why ended up in the
        ;; composer with nothing to do with it. A card that names an affordance
        ;; has to say where the affordance is.
        (awhen (and (not question)
                    (find-if (lambda (o)
                               (search "reject_always"
                                       (string-downcase (or (getf o :kind) ""))))
                             options))
          (push (list (cons (format nil " type: ~a <the words the model should hear>"
                                    (getf it :option-id))
                            '(:dim t)))
                body))
        (nreverse body)))))

(defun quit-choices (head)
  "The two ways out and what each does to the daemon — `quit_choices`. The second
names how many OTHER heads will be told, from the session's own head list."
  (let ((others (max 0 (1- (length (session-heads (head-session head)))))))
    (list (cons "leave this head"
                "the daemon keeps running: the session stays warm and `letibot` reattaches to it")
          (cons "leave and stop the daemon"
                (case others
                  (0 "the session is written to disk and `letibot --continue` reopens it — but its prompt leaves the model server's cache, so the next turn prefills cold")
                  (1 "one other head is attached and will be told. The session is on disk; the next turn after reopening prefills cold")
                  (t (format nil "~d other heads are attached and will be told. The session is on disk; the next turn after reopening prefills cold" others)))))))

(defun quit-card-lines (head cols)
  "The quit card, to the reference's shape (`quit_card_lines`): a bold title, each
choice as `▸  1  name` with its consequence wrapped dim under it at eight in."
  (let ((w (max 20 cols))
        (sel (min 1 (head-quit-sel head))))
    (append
     (list (list (cons "leave — and what happens to the daemon" '(:bold t))))
     (loop for (name . why) in (quit-choices head)
           for i from 0
           for picked = (= i sel)
           append (cons (%truncate-segs
                         (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i)) nil)
                               (cons name (if picked '(:bold t) nil)))
                         w)
                        (mapcar (lambda (l) (cons (cons "       " nil)
                                                  (mapcar (lambda (seg) (cons (car seg) '(:dim t))) l)))
                                (wrap-segments (list (cons why nil)) (max 4 (- w 8)))))))))

(defun secret-card-lines (head cols)
  (declare (ignore cols))
  (let ((req (head-secret-req head)))
    (when req
      (list (list (cons " sudo " '(:bold t :fg :yellow))
                  (cons (format nil " ~a" (getf req :prompt)) '(:bold t)))
            (list (cons " for " '(:dim t))
                  (cons (getf req :command) '(:fg :bright-white)))
            (list (cons " password: " '(:fg :bright-cyan :bold t))
                  (cons (make-string (length (head-secret-buf head))
                                     :initial-element #\*)
                        nil))
            (list (cons " enter submits · esc refuses" '(:dim t)))))))



(defun %clock-time (ts)
  "TS (epoch ms) as `HH:MM:SS`, or empty when there is no timestamp.

Empty rather than `00:00:00`: a row read out of a snapshot may have no `ts`, and
midnight is a time nobody took — the same rule the duration on a card follows."
  (if (and (numberp ts) (plusp ts))
      ;; LOCAL time, which is what `localtime_r` gives the reference. Passing an
      ;; explicit 0 here is UTC, and the stamp then read 11:53:34 on a screen whose
      ;; clock said 13:53:34 — a timestamp that is wrong by the offset is worse
      ;; than no timestamp, because it looks like a measurement.
      ;; **A UNIX timestamp is not a universal time.** The epochs differ by
      ;; 2 208 988 800 seconds (25 567 days), and because that is a whole number
      ;; of days the H:M:S survived the mistake while the DATE landed in 1956 —
      ;; so the local offset was taken for 1956 (CET, no summer time) instead of
      ;; 2026 (CEST), and every prompt was stamped an hour early all summer.
      ;; Measured against letibot on the same row: `15:00:08` against `14:00:08`.
      (multiple-value-bind (s m h)
          (decode-universal-time (+ (floor ts 1000) 2208988800))
        (format nil "~2,'0d:~2,'0d:~2,'0d" h m s))
      ""))
