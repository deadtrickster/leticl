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
;;;    more without pretending a JSON dump is a label.

(defparameter *target-max-bytes* 120
  "How much of a display target a person reads before the rest is an ellipsis.")

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
  "How a nested value is shown: `[…]` for an array, `{…}` for an object."
  (if (%json-object-p json) "{…}" "[…]"))

(defun truncate-target (s)
  "S cut to `*target-max-bytes*` with an ellipsis, control characters flattened.

The ellipsis COUNTS: `…` is three bytes, and a cap that forgets that is a cap the
output is allowed to exceed — which is the off-by-a-few that puts a line one
column past the terminal and scrolls the frame."
  (let* ((clean (map 'string (lambda (c) (if (or (char< c #\space)
                                                 (= (char-code c) 127))
                                            #\space
                                            c))
                     s))
         (limit (max 1 (- *target-max-bytes* 3))))
    (if (<= (length clean) *target-max-bytes*)
        clean
        (concatenate 'string (subseq clean 0 limit) "…"))))

(defun display-target (arguments)
  "The one argument a person reads, from a tool call's ARGUMENTS string."
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
                  (let ((label (%scalar-label v)))
                    (push (if (eq label :elided) (%elision-of v) label) parts)))
         (setf parts (nreverse parts))
         ;; a subject the loop never reached is PREPENDED: a write's content
         ;; buries its path, and the file is what a person reads
         (unless subject-seen
           (when subject-value
             (let ((label (%scalar-label subject-value)))
               (push (if (eq label :elided) (%elision-of subject-value) label)
                     parts))))
         (truncate-target (string-trim " " (format nil "~{~a~^ ~}" parts)))))
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
  "Alist CALL-ID → the monotonic ms when its ToolStarted arrived.

Neither `tool_finished` nor the row that lands afterwards carries a duration, so
the only way to keep *\"that grep took 4.1 s\"* on the screen is to have noted
when it began.")

(defun note-call-started (call-id)
  (when call-id
    (setf (alexandria:assoc-value *call-started-ms* call-id :test #'string=)
          (internal-real-time-ms))))

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
  "A /cells message folds back out of the transcript at render time
(app.rs:6264): the delimited block becomes one marker line. Returns the
folded text, or the text unchanged when it holds no screen."
  (let ((start (search *cells-open* text)))
    (if (null start)
        text
        (let* ((head-end (search *cells-mark-end* text :start2 start))
               (close (search *cells-close* text)))
          (if (and head-end close)
              (concatenate 'string
                           (subseq text 0 start)
                           (subseq text start (+ head-end (length *cells-mark-end*)))
                           " …"
                           (subseq text (+ close (length *cells-close*))))
              text)))))

(defun %outcome-style (outcome)
  (switch ((outcome-name outcome) :test #'string=)
    ("ok" '(:fg :green))
    ("abstained" '(:fg :yellow))
    ("failed" '(:fg :red))
    ("denied" '(:fg :yellow))
    ("timeout" '(:fg :red))
    ("not_run" '(:dim t))
    ("backgrounded" '(:fg :cyan))
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
folded row has."
  (let ((trimmed (string-left-trim " " line)))
    (and (>= (length trimmed) 3) (string= (subseq trimmed 0 3) "<<<"))))

(defun %shorten-subject (subject max)
  "SUBJECT cut to MAX columns the way a person reads it.

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
            ;; keep the TAIL: the end of a path is what names it
            (let* ((n (length subject))
                   (cut (max 0 (- n (max 1 (- max 1))))))
              (concatenate 'string "…" (subseq subject cut)))
            ;; keep the HEAD: prose announces itself at the front
            (concatenate 'string (subseq subject 0 (max 1 (- max 1))) "…")))))

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
         (bad (not (string= word "ok")))
         (mark (if open "▾" "▸"))
         (verb (verb-label name))
         (subject (or (call-target-of (getf body :call-id))
                      (format nil "(~a)" (getf body :call-id))))
         (decision (getf facts :decision))
         ;; the envelope lines are not output
         (rows (remove-if #'%envelope-line-p (%payload-lines payload)))
         (n (length rows))
         (ind (activity-indent cols))
         (w (max 20 (- cols ind)))
         (faint '(:dim t))
         (outcome-style (if bad '(:fg :red) faint))
         (size-style (if (>= n +big-output-lines+) '(:bold t) faint))
         (shown-word (%outcome-word word))
         (took (if (numberp ms) (format nil " · ~a" (duration ms)) ""))
         ;; the tail is measured FIRST and the subject is given what is left
         (tail-cols (+ 3 (string-width shown-word) (string-width took)
                       3 6 (length (format nil "~d" n))))
         (lead (+ (length mark) 1 (length verb) 1))
         (subject (%shorten-subject subject (max 8 (- w lead tail-cols))))
         (head (list (cons mark (if bad '(:fg :red) faint))
                     (cons (format nil " ~a " verb) faint)
                     (cons subject nil)
                     (cons (format nil " · ~a" shown-word) outcome-style)
                     (cons took faint)))
         (head-width (%segs-width head))
         (why (%outcome-why outcome))
         (out nil))
    (labels ((emit (line) (push line out))
             (dim-line (text)
               (list (cons "  " faint)
                     (cons (%truncate-width (or text "") (max 4 (- w 2))) faint)))
             (decision-lines ()
               ;; the approval this call was gated by, in the dim register — the
               ;; same block the live card draws, carried across with the card
               (when decision
                 (let* ((o (getf decision :outcome))
                        (option (and (consp o) (getf o :option-id)))
                        (dword (cond ((and option (alexandria:starts-with-subseq "allow" option))
                                      "allowed")
                                     (option "refused")
                                     ((equal (outcome-name o) "cancelled") "cancelled")
                                     ((equal (outcome-name o) "timed_out") "not answered")
                                     (t "answered")))
                        (by (getf decision :by))
                        (who (format nil "~a~@[ ~a~]" (or (getf by :kind) "")
                                     (let ((id (getf by :identity)))
                                       (and id (plusp (length id)) id)))))
                   (emit (list (cons (format nil "  · ~a, by ~a" dword who) faint)))
                   ;; the basis under it while the tools are open — unless the
                   ;; payload already says it: the operator, counting the repeats
                   ;; in one card, *"how many times is 'nothing ran' needed?"*
                   (when open
                     (let* ((b (getf decision :basis))
                            (first (and b (string-trim " " (%first-line b))))
                            (echoed (and first (>= (length first) 40)
                                         (some (lambda (l) (search first l)) rows))))
                       (when (and b (plusp (length b)) (not echoed))
                         (dolist (l (wrap-segments (list (cons (format nil "~a: ~a"
                                                                       (or (getf by :kind) "decided")
                                                                       b)
                                                               nil))
                                                   (max 4 (- w 4))))
                           (emit (cons (cons "    " faint)
                                       (mapcar (lambda (seg) (cons (car seg) faint)) l)))))))))))
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
              (emit (list (cons (format nil "  … +~d diff rows · ctrl-t" hidden) faint)))))
          (return-from %tool-result-lines (nreverse out)))
        ;; Folded shows the first line, which is where a tool puts what it did,
        ;; then the seam: `… +N lines`, a separator row and not a sentence — it is
        ;; not content, it is where content was taken out — and the chord goes on
        ;; it, where there is something for it to do. Open, or a failure with no
        ;; reason printed above it, shows the body up to the budget.
        (let ((limit (if (or open (and bad (null why))) 40 2)))
          (if (and (> n limit) (>= limit 2))
              (progn
                (dolist (l (subseq rows 0 (1- limit))) (emit (dim-line l)))
                (emit (list (cons (format nil "  … +~d lines · ctrl-t" (- n (1- limit)))
                                  faint))))
              (progn
                (dolist (l rows) (emit (dim-line l)))
                ;; the payload was short enough to show whole, but the REASON was
                ;; cut — so the affordance has to be here
                (when why-folded
                  (emit (list (cons "  … the rest of the reason · ctrl-t" faint))))))))
      ;; `item-lines` steps the whole row in by the activity indent
      (nreverse out))))

(defparameter +body-lines-budget+ 40
  "The reference's `Budget::body_lines`: a block over this many rows is shown as
its title, an elision count and its tail.")

(defparameter +reasoning-lines-budget+ 8
  "The reference's `Budget::reasoning_lines`, the same bound for a reasoning block.")

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
         (n (max 1 (reduce #'+ (mapcar (lambda (l) (max 1 (ceiling (string-width l) w)))
                                       (uiop:split-string (or text "") :separator '(#\newline)))
                           :initial-value 0))))
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

(defun item-lines (item cols prefs)
  "One transcript row to segment lines.

The model's WORKING — reasoning and tool calls — is stepped in
`(activity-indent cols)` columns, under what it SAYS. Measured against letibot's
screen: its cards sit at column 4 and its prose at 2, while every row of ours was
at 2. The step is what makes a turn readable as a turn — the answer at the body's
own column, the working subordinate to it — and it costs no colour, so it survives
a terminal-native palette."
  (let ((body (item-body item)))
    (cond
      ((null body)
       (list (list (cons (format nil "[~a — content not loaded]" (item-kind item))
                         '(:fg :red)))))
      (t
       (step-in-lines
        (case (intern (string-upcase (getf body :type)) :keyword)
         ((:user)
          ;; THE OPERATOR'S OWN MESSAGE, to the reference's shape — read off its
          ;; screen because the three differences are all things a screenshot
          ;; shows and a test would not:
          ;;
          ;;   · a BLUE `▌` bar (`Role::UserAccent` is `ESC[34m`), not a cyan `›`;
          ;;   · the message in REVERSE VIDEO (`Role::UserBlock` is `ESC[7m`) —
          ;;     the block IS the highlight, which is why it carries no colour of
          ;;     its own and survives a terminal-native palette;
          ;;   · the message PADDED to the full width, so the block is a block: a
          ;;     background that stops early leaves a ragged right edge;
          ;;   · and the timestamp right-aligned on the FIRST row, which is why
          ;;     that row is wrapped narrower than the rest.
          (let* ((text (%fold-cells (item-display-text item)))
                 (stamp (%clock-time (item-ts item)))
                 ;; the first row shares its width with the timestamp
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
                                      '(:reverse t))
                                (cons (if (and (= i 0) (plusp (length stamp))) stamp "")
                                      '(:reverse t))))))
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
             (loop for tc in (getf body :tool-calls)
                   unless (call-answered-p (getf tc :id))
                     collect (list (cons "  → " '(:dim t))
                                   (cons (verb-label (getf tc :name)) '(:dim t))
                                   (cons (let ((tgt (display-target (getf tc :arguments))))
                                           (if (plusp (length tgt))
                                               (format nil " ~a" tgt) ""))
                                         nil))))))
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
         ((:system)
          (wrap-segments
           (list (cons "◦ " '(:fg :yellow))
                 (cons (item-display-text item) '(:fg :yellow)))
           cols))
         (t nil))
        ;; the step: reasoning and tool calls are the model WORKING, under the
        ;; answer. Speech — the operator's message and the model's prose — sits at
        ;; the body's own column, which is what says it is the conversation.
        (case (intern (string-upcase (getf body :type)) :keyword)
          ((:reasoning :tool_result) (activity-indent cols))
          (t 0)))))))

(defun %call-elapsed-ms (call)
  "How long a running call has been going, from the moment its ToolStarted arrived."
  (let ((start (cdr (assoc (getf call :call-id) *call-started-ms* :test #'string=))))
    (and (numberp start) (max 0 (- (internal-real-time-ms) start)))))

(defun call-lines (call cols)
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
         (outcome-style (cond ((not finished) '(:fg :yellow))
                              (bad (case (intern (string-upcase word) :keyword)
                                     ((:failed :timeout) '(:fg :red))
                                     (t '(:bold t :fg :yellow))))
                              (t '(:fg :green))))
         (mark (cond (running (cons "◐" '(:fg :yellow)))
                     (finished (cons "●" outcome-style))
                     (t (cons "○" '(:dim t)))))
         (target (or (getf call :target) ""))
         (note (getf call :progress-note))
         (ms (and finished (getf (alexandria:assoc-value *call-facts* (getf call :call-id)
                                                          :test #'string=)
                                 :ms)))
         (tail (remove nil
                       (cond
                         (running (list (duration (or (%call-elapsed-ms call) 0)) note))
                         (finished (append (and (numberp ms) (list (duration ms)))
                                           (and bad (list (%outcome-word word)))
                                           (and bad (list (%outcome-why outcome)))))
                         (t (list (or note "proposed"))))))
         (head (list mark
                     (cons " " nil)
                     (cons (verb-label (getf call :name) :running running) '(:bold t))
                     (cons (if (plusp (length target)) (format nil " ~a" target) "") nil)))
         (joined (and tail (format nil " · ~{~a~^ · ~}" tail)))
         (tail-style (if bad outcome-style '(:dim t))))
    (append
     (list (if (and joined (<= (+ (%segs-width head) (string-width joined)) cols))
               (append head (list (cons joined tail-style)))
               (%truncate-segs head cols)))
     ;; a file-editing call carries both sides of the change, bounded to what
     ;; differs (event.rs:75) — the raw material of the diff view
     (awhen-edit-lines (getf st :edit) cols))))

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
  (declare (ignore cols))
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
          ((string= name "failed")
           (say (format nil "── FAILED — ~a (~a)" (getf state :error)
                        (if (getf state :partial-kept)
                            "what it had written is kept" "nothing was recorded"))
                '(:fg :red :bold t)))
          ;; running: the numbers belong on the box's edge, not here
          (t nil))))))

(defun queued-lines (head cols)
  "Prompts sent that the transcript does not hold yet, marked `queued`.

A prompt sent while a turn runs is queued as a FOLLOW-UP USER ITEM, and the item is
appended only at the next step boundary — which for a turn with no tool calls is
the turn's end. Between the enter press and that append the words existed NOWHERE
on the screen: the composer had handed them off, the daemon had accepted them, and
the operator was looking at a conversation that had swallowed a sentence they had
just typed.

It comes back at the boundary, so nothing is lost — but NOT LOST and VISIBLE are
different requirements, and this is the second one."
  (declare (ignore cols))
  (mapcar (lambda (text)
            (list (cons "› " '(:fg :bright-cyan :bold t))
                  (cons (%first-line text) '(:dim t))
                  (cons "  · queued" '(:dim t))))
          ;; oldest first, so the order they will land in is the order they read
          (reverse (head-queued head))))

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
      (flet ((emit (lines) (setf out (append out lines))))
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
                                     (cons (%truncate-width last (max 4 (- cols ind 2)))
                                           '(:dim t :italic t))))))
                   ind))
            (emit (list nil))))
        (let ((calls (reverse (getf turn :calls))))
          (when calls
            (emit (step-in-lines (mappend (lambda (c) (call-lines c (- cols ind))) calls) ind))
            (emit (list nil))))
        (alet (getf turn :text)
          (when (plusp (length it))
            (emit (markdown-lines it :width cols :limit +body-lines-budget+))
            (emit (list nil))))
        ;; The raw `<function=…>` markup the model wrote, when ctrl-x has asked for
        ;; it. NOT a fold: a fold hides something the reader knows is there, while
        ;; this reveals markup the default view is required never to show, so it is
        ;; off unless asked for by name.
        (when (getf prefs :raw-calls)
          (let ((raw (getf turn :raw-calls)))
            (when (and (stringp raw) (plusp (length raw)))
              (emit (mapcar (lambda (l) (list (cons "    " '(:dim t))
                                              (cons l '(:dim t))))
                            (uiop:split-string raw :separator '(#\newline))))))))
      out)))

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
      (multiple-value-bind (s m h) (decode-universal-time (floor ts 1000))
        (format nil "~2,'0d:~2,'0d:~2,'0d" h m s))
      ""))
