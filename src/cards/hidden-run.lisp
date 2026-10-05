;;;; hidden-run.lisp — R37: what the `:reading` rung hides, the ONE line a
;;;; contiguous run of hidden rows collapses to, the counts on it, and the
;;;; switch that merges a narration and its report into one prose.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.

(in-package #:leticl)

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
         (member (%key-from-wire (getf body :type)) +reading-hides+)
         ;; **`read-edits` KEEPS THE EDITS, AND THIS IS THE ONLY PLACE THAT DECIDES IT.** Every hide
         ;; in this head goes through this predicate — `item-lines` before drawing a row and
         ;; `%history-until` when it finds the run — so the exception lives here or it does not exist.
         ;;
         ;; **THE EDIT CARD SURVIVES AND THE PAYLOAD BESIDE IT DOES NOT**, which is the whole
         ;; difference between this rung and `:reading`: the reader sees what the head changed and
         ;; not what the call returned. The operator's rule (2026-10-04) is that edits are the
         ;; `edit` tool *plus* the heredoc-shaped writes, and both are `item-shows-an-edit-p`'s.
         (not (and (read-edits-p) (item-shows-an-edit-p item))))))

(defun item-shows-an-edit-p (item)
  "Does ITEM show an EDIT — what the `:read-edits` rung exists to keep on the screen?

**Two signals, both the tree's own rather than a rule invented here.** The daemon sends `:edit` on
a finished call (`session.lisp` folds both sides of the file it changed) — and that is the signal a
bash command carries when the file changed under it, which is why the heredoc case needs no second
rule here. The other is the call's NAME through `*verb-map*`: `edit`, `patch`, `apply_patch` and
`str_replace` are `:edit`, `write`, `write_file` and `create` are `:write`.

**An unknown tool name is NOT an edit.** `*verb-map*` keeps a name it does not know rather than
inventing a verb for it, and inventing a KIND here would be the same guess one layer up — this
predicate is allowed to be wrong in the direction of hiding, never in the direction of claiming."
  (let ((body (item-body item)))
    (and body
         (or (getf body :edit)
             (member (%verb-kind (getf body :name)) '(:edit :write) :test #'eq)))))

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
  ;;
  ;; **`:calls` IS THE CALLS WITH NO RESULT ROW YET, NOT THE CALLS STILL RUNNING — and `:running`
  ;; is the other number.** The marker's number is landed result rows PLUS this, and the two halves
  ;; have to hand over exactly: a call leaves this count at the moment its row starts being counted,
  ;; which is when the row's BODY lands (`note-answered-call`, on `transcript_content`), and not a
  ;; moment earlier. Counting the UNFINISHED calls here — the first version — handed over at
  ;; `tool_finished` instead, which arrives BEFORE the row, so for that window the call was in
  ;; neither half. The operator watched it: *"2 (in yellow) tool calls dropping to 1 (in yellow)
  ;; tool calls and then changing back to 2 (in white) tool calls."* A number that is a count of
  ;; work done cannot go down, and it did.
  ;;
  ;; The colour is a different fact — *is a call still executing* — and that is `:running`, which
  ;; `marker-rising-p` reads. A finished call whose row is still in flight keeps the number and
  ;; drops the yellow, which is what the screen should say about it.
  ;;
  ;; **AND `:running` EXCLUDES THE CALLS THE TRANSCRIPT HAS ANSWERED** — daemon commit `5910161`
  ;; ("tui: a call the transcript has answered is not executing, so the yellow clears"). A call
  ;; whose result row has landed is over, whatever its state says: nothing else clears a call this
  ;; head never received a `tool_finished` for, so the colour has to read the row. `:calls` already
  ;; excludes those calls (`call-answered-p`), and the colour must be counted over the SAME set or
  ;; it goes on colouring a number that has stopped counting them — the stuck yellow, exactly: the
  ;; operator's *"yellow tool calls are not resolved unfortunately"*, a marker whose digits stay
  ;; pending on a turn whose calls have all finished and whose daemon has published every row.
  (when turn
    (let* ((all (getf turn :calls))
           (calls (count-if-not (lambda (c) (call-answered-p (getf c :call-id))) all))
           (running (count-if (lambda (c) (let ((st (getf c :state)))
                                            (and st
                                                 (not (string= (or (getf st :state) "") "finished"))
                                                 (not (call-answered-p (getf c :call-id))))))
                              all))
           (reasoning (or (getf turn :reasoning) ""))
           (thinking (if (plusp (length reasoning))
                         (reasoning-line-count reasoning cols)
                         0)))
      (when (or (plusp calls) (plusp running) (plusp thinking))
        (list :calls calls :running running :thinking thinking)))))

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
  (vector (cons " · /t opens it" " · /verbosity")
          (cons " · /t" " · /verbosity")
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

(defun marker-rising-p (busy live live-here)
  "Is THIS marker's number still going up — the one question the yellow answers.

**Two things must both hold, and each was learned by getting it wrong.**

  · **THE TURN MUST STILL BE RUNNING** (`busy`). The first cut keyed the colour on `live` — the work
    IN FLIGHT — and it flickered: a call finishing and the next round's first delta arriving are two
    different events, so in the gap between them there was no work in flight and the number went
    plain in the middle of a turn. *\"running tool is no longer yellow the counter, wtf why it
    regressed.\"*
  · **AND THIS MUST BE THE LIVE EDGE** (`newest` or `live-here`). The second cut keyed on the turn
    alone and lit up the whole transcript: the walk draws a marker for EVERY run in it, so a turn's
    own history, already settled, went yellow behind it. *\"all tool call counters are yellow now.\"*

`live` is the work IN FLIGHT (`%hidden-run-live-work`), and **its `:calls` is what the yellow is
about**: the styled number is the call count, and that number is only moving while a call has not
finished. `live-here` is the row live work rides on, and it can be set with NO run at all — a call in
flight whose results have not landed yet — so it carries the colour on a marker whose counts are the
live work's own.

**A function, and not the one-line `and` at each call site**, because there are two call sites (the
in-walk flush and the end-of-walk one) and this colour has now been wrong twice in opposite
directions. One definition the walk and a test can both ask.

**AND IT ANSWERS A BOOLEAN.** `(and busy (or live-here newest))` returns `live-here` itself when that
is what made it true — and `live-here` is `%hidden-run-live-work`'s plist, so the function handed
`:calls 1 :thinking 0` to a caller asking yes-or-no. Truthy, so the colour was right by accident, and
measured on the live head before this was caught:

    (marker-rising-p t t live) => (:CALLS 1 :THINKING 0)

A predicate that returns somebody else's data is a predicate whose next reader will destructure it."
  ;;
  ;; **AND THE THIRD THING IS THE ONE THAT WAS MISSING: A CALL THAT HAS NOT FINISHED.** `busy` is
  ;; true for the whole of a turn, and a turn is mostly not waiting on a tool — so gating on it alone
  ;; left the number yellow while the model wrote its answer, which is the operator's third report of
  ;; this colour, in the same words as the second: *"still some finished toolcalls are yellow"*. The
  ;; number the yellow is on is the CALLS number, and it only moves while a call is unfinished — so
  ;; that is the fact, and `live` is where it lives (`%hidden-run-live-work`'s `:calls`).
  ;;
  ;; **Reasoning alone does not light it** (`:calls` zero, `:thinking` streaming): the styled clause
  ;; is the calls number, and a thinking count that is rising while the calls are final is a different
  ;; fact that this marker already shows by going up on its own.
  ;;
  ;; **AND *THE LIVE EDGE* MEANS THE ROW THE WORK RIDES ON, NOT THE NEWEST RUN.** The operator, once
  ;; more, watching a call run: *"yes one old tool call is still yellow"* — and `newest` is exactly
  ;; how: the newest run of HIDDEN rows can be a row from the PREVIOUS turn while the current turn has
  ;; a call in flight with no result row yet, so the marker that lit up was an old counter, on the old
  ;; turn's words. The fact the yellow is about is *the number on THIS line still has work behind it*,
  ;; and the line that carries live work is `live-here` — the newest row the reader can see, which is
  ;; where the in-flight count is drawn when a call has been proposed and nothing has landed. An older
  ;; run's marker is never that line, so it is never yellow, whatever the turn is doing.
  ;;
  ;; **`:running`, not `:calls`, since the two came apart**: `:calls` is now the calls with no
  ;; result row yet, which includes a call that has FINISHED and whose row is a frame away. That
  ;; one keeps the number (it is still work the marker counts) and must not keep the colour — the
  ;; yellow says *executing*, and nothing is.
  (and busy
       (plusp (or (getf live :running) 0))
       live-here
       t))

(defun hidden-run-marker (items cols &optional newest live max-width rising)
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
         ;; **YELLOW WHILE THIS NUMBER IS STILL GOING UP — and only on the marker at the live
         ;; edge.** `rising` is the caller's answer to exactly that, and it is NOT simply *is the
         ;; turn running*, which is what the second cut of this got wrong.
         ;;
         ;; The first cut keyed on `live` — the work IN FLIGHT — and the colour flickered: a call
         ;; finishing and the next round's first delta arriving are two different events, and in
         ;; the gap `%hidden-run-live-work` returns NIL. *"running tool is no longer yellow the
         ;; counter, wtf why it regressed."*
         ;;
         ;; The second cut keyed on `turn-busy-p` alone and the operator reported *"all tool call
         ;; counters are yellow now"* — because `busy` is true for the WHOLE turn and the walk
         ;; draws a marker for every run in the transcript, so a turn's own history went yellow
         ;; behind it. Both halves are needed: this marker must belong to the newest run (or be
         ;; carrying live work), AND the turn must still be running. See `render.lisp`, which
         ;; narrows it once so the two call sites cannot disagree.
         (counts-style (if rising +role-pending+ nil))
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

(defun %marker-onto-last-line (il items cols &optional newest live rising)
  "IL with the run's marker **appended to its last line**, split by ONE SPACE.

**AND A SECOND VALUE SAYING WHETHER THE JOIN HAPPENED** — `T` when IL comes back with the counts on
its last line, `NIL` when the join was refused. The caller has to be able to tell the two apart,
because a refused join used to come back as IL and nothing else, and the counts were then drawn
NOWHERE: `glue` had already been decided, so the walk skipped its own standalone branch and the
marker was gone with no seam and no error.

letibot answers the same question in one `match`, and this is that shape — the joined line is
`Some(line)` only when the sentence's last line has room for it and the row is one the counts may
continue, and `None` in every other case, which is the marker *drawn as a row of its own*:

    let joined = … .filter(|l| visible_width(l) <= cfg.width);
    match joined { Some(line) => { …glue… }, None => (RowClass::Activity, vec![painted]) }

Their reason is this one, verbatim: *counts with no sentence are still the fact, and a marker
clipped to fit would lose them.*

**What NIL costs and what it buys.** Nothing of the marker is drawn here — IL comes back untouched —
and the caller stands the marker on its own line instead, with the blank prose gets. So the counts
may cost a row there, and that is deliberate: the alternative on the screen is not *no extra row*
but *no counts*, and a dropped count is a marker that did nothing.

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
         ;;
         ;; **AND FOR A ROW THAT FILLS THE FRAME THIS IS NOT A ROOM AT ALL.** `room` is negative,
         ;; `hidden-run-marker` is never asked, and the counts have nowhere to go. A user row is
         ;; always this case: it is drawn as a bar padded to the frame's own width with the
         ;; timestamp right-aligned at its edge — MEASURED, 172 columns of 172 on the operator's
         ;; terminal — so work in flight rides a row with no columns left. The caller stands the
         ;; marker on its own line there now, rather than dropping it (R37's flash).
         (room (- cols used 1))
         (marker (if (plusp room)
                     (hidden-run-marker items cols newest live (max 4 room) rising)
                     nil)))
    (if (null marker)
        ;; **AND THE PROSE KEEPS ITS LAST LINE WHEN THE MARKER WILL NOT FIT.**
        ;; This returned `(butlast il)` -- the item's lines WITH THE LAST ONE REMOVED --
        ;; so a marker that could not be fitted did not move to a line of its own, as this
        ;; function's docstring promises: a line of the model's prose simply vanished, with
        ;; no error and no seam. Reachable wherever a line fills the frame, and MORE likely
        ;; the narrower the terminal.
        ;;
        ;; **It was also the residual turn-end jump.** The fit is computed against the newest
        ;; row, and live and settled fit the same counts onto DIFFERENT rows (a hidden run's
        ;; newest row while a turn runs, the assistant row once it lands). Whichever of the
        ;; two happened to land on a full line took this branch, so one frame had a line the
        ;; other did not -- intermittent, decided by line width, which is why turns held and
        ;; then one moved.
        ;;
        ;; **AND IT NO LONGER ENDS HERE.** This branch returns IL and a SECOND VALUE of NIL, which
        ;; is the walk's signal to stand the marker on its own line instead of dropping the counts.
        ;; Leaving the counts out was the one answer the operator's own screen refused: the block
        ;; after their prompt came and went, because whether the counts had anywhere to go depended
        ;; on which row they happened to ride — see `%history-until`'s glue. A dropped SENTENCE is
        ;; still not acceptable; a vanished COUNT no longer is either.
        (values il nil)
        (let ((out (append (butlast il)
                (wrap-segments (append last (list (cons " " nil)) marker) (max 20 cols)))))
        ;; **AND THE MARKER MAY NEVER ADD A ROW** — the operator's ruling is that the number
        ;; inside a marker may change and its HEIGHT may not, and this is that ruling as a property
        ;; rather than as a case. `(max 4 room)` renders the marker into four columns even when the
        ;; last line has one, two or three left, so `wrap-segments` pushes it onto a SECOND ROW and the
        ;; rendering is a row taller than the sentence alone — and a marker too wide is the NORMAL end
        ;; of a turn, because the count grows as the work does: `[1 tool call, 88 thinking lines]` is at
        ;; its longest exactly when the settle finalises it, and the ladder that steps `tool calls`
        ;; down to `t` cannot help once four columns are handed out to a line with none. So if the
        ;; fitted result is taller than the prose alone, the join is REFUSED — and the second value
        ;; says so, which is the walk's cue to stand the marker on a line of its own. What is refused
        ;; is the row growing by a WRAP of its own sentence; a refused join that quietly lost the
        ;; counts is the defect this value exists to end.
        (if (> (length out) (length il)) (values il nil) (values out t))))))

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
     (list (list (cons (format nil "  … /t folds this back into ~d line~:p" (length items))
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
  ;; **THE MEMO'S KEY IS THE VECTOR, THE GENERATION AND THE WIDTH — not the vector alone.**
  ;; `push-item` is `vector-push-extend`, so a session that gains a row keeps the SAME vector, and a
  ;; key that was only its identity never missed: with join-prose on, a new row or a body landing
  ;; in an announced one was not in the joined copy until something replaced the vector. The
  ;; generation is what every writer of a committed row already bumps (`*hist-generation*`), and
  ;; the width decides where a run's counts wrap, so both are part of what the join depends on.
  (if (and *reading-joined*
           (equal (car *reading-joined*) (list items *hist-generation* cols)))
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
          (setf *reading-joined* (cons (list items *hist-generation* cols) joined))
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

