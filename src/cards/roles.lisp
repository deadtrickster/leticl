;;;; roles.lisp — how a row's words and registers are chosen: the pane step, the
;;;; outcome roles, the verb vocabulary (`*verb-map*`, `verb-label`, `%verb-kind`),
;;;; the payload's line splitting, the row budgets, and the subject elision.
;;;;
;;;; **This is the SHARED vocabulary, not a card**: every card file below reads the
;;;; words and the registers from here, so it loads first among them and a word
;;;; cannot be spelled twice. The module was one 4,800-line `cards.lisp`, then a
;;;; split by layer, and is now one file per CARD (the reader looking for the edit
;;;; card wants `edit-card.lisp`) plus the vocabulary the cards share; `leticl.asd`
;;;; lists them in DEPENDENCY order rather than the old file's, which is why two
;;;; `undefined variable` warnings this tree used to emit are gone.

(in-package #:leticl)

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
    ("backgrounded" +role-faint+)
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

(defun %verb-kind (name)
  "The `card::Verb` a tool name maps onto, or NIL when nobody knows it.

 **Beside the table it reads, which the split is what allowed**: it used to sit
 three thousand lines below `*verb-map*` in `cards.lisp`, under the card protocol
 that is one of its callers. Both readers of a name — the word (`verb-label`) and
 the kind (`%verb-kind`, which `tool-card-of` turns into a class) — are now one
 screen apart."
  (car (cdr (assoc (string-downcase (or name "")) *verb-map* :test #'string=))))

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

(defun %subject-room (cols mark verb tail-width)
  "How many columns a tool row's SUBJECT may take — the row's arithmetic, in ONE place.

 A tool row is `mark verb subject · tail`, and **the tail is measured FIRST** (R25): the
subject gets what is left after the mark, a space, the verb, a space, and the tail as it
will be DRAWN. `tail-width` is that drawing's own width — the settled row counts its
parts, the live card measures the string it built — and 0 when there is no tail.

 **Two renderers had this arithmetic spelled twice, and one spelling was a coincidence.**
The settled row counted `(+ (length mark) 1 (length verb) 1)`; the live card wrote
`(+ 2 (string-width verb) 1)` with the 2 standing for *mark and space*, which is true only
while every mark is one column wide. The two agree today because every mark in this tree
(`▸ ▾` and `◐ ● ○`) IS one column — which is the point: a number that agrees by accident
is the one that stops agreeing when a mark is not, and the marks are a rendering decision
rather than a constant.

 The floor of 8 is the one the old inline calls used: below it a subject is an ellipsis
with a letter in it, and the mark, the verb and the tail already say what the row is."
  (max 8 (- cols (+ (length mark) 1 (length verb) 1 (or tail-width 0)))))

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


;;; ---- the row budgets and the step ---- ;;;
;;;
;;; Moved here from `rows.lisp` when the module was re-cut by card: a budget and a
;;; step are how a ROW is laid out, which is what this file is about, and every card
;;; that draws a body reads them.

(defparameter +body-lines-budget+ 40
  "The reference's `Budget::body_lines`: a block over this many rows is shown as
its title, an elision count and its tail.")


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

