;;;; compaction — a compaction: a tool call, a counted operation, and the carry it needs
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ------------------------------------------- a compaction is a tool call ;;;
;;;
;;; **R24 part one.** A compaction announces itself as WARNINGS today — `compacted` and
;;; `auto_compact` as routine, `context_wall` as failure — so the most information-dense
;;; event in a long session arrives as the one shape on the screen with NO AFFORDANCES:
;;; it cannot be folded, `ctrl-t` does nothing to it, its numbers are buried in prose,
;;; and it competes for the note band with denials.
;;;
;;; **A tool call already has every affordance this wants** — a headline carrying the
;;; stats, `ctrl-t` for the detail, folding, the payload pager you built, and a row that
;;; scrolls with the conversation instead of stacking above the composer. So a
;;; compaction that was ATTEMPTED is filed as a tool row whose payload is the daemon's
;;; own sentence.
;;;
;;; **Nothing about compaction's behaviour changes, only what it is rendered as** — which
;;; is why this is a fold and two optional fields on a body, and not a new frame.
;;;
;;; **And it collapses R19's wall rather than dismissing it.** Three of the four notes
;;; the operator was met by on restart were `compacted` and `auto_compact`; as rows they
;;; stop being notes at all, and the band goes back to being what R10 says it is — *how a
;;; head shows a fact once*, for facts with nowhere else to live.
;;;
;;; **ATTEMPTED is the line, and it is the whole of the code list.** A code that reports
;;; a compaction somebody TRIED becomes a row. A code that reports one nobody tried stays
;;; a note, because there is nothing to report and the absence IS the fact:
;;; `auto_compact_skipped` (automatic compaction is off for this session) and
;;; `context_wall` (the wall itself — delivered BEFORE any compaction exists, and in the
;;; cases where none will). `context_wall` is ruled separately below.

(defparameter +compaction-row-codes+
  '("compacted" "auto_compact" "auto_compact_no_progress" "auto_compact_failed")
  "The warning codes this head renders as a TOOL ROW rather than as a note.

Each reports a compaction that was attempted: `compacted` and `auto_compact` their
reports, `auto_compact_no_progress` one that ran and did not help,
`auto_compact_failed` one that was tried and did not run.

**`reseated` is deliberately not here.** A re-seat publishes that code AND a
`compacted` whose detail is the token account, so the note carries the tools the model
gained and lost and the row carries the numbers — two facts, two shapes.

**`auto_compact` does double duty** — it is the ANNOUNCEMENT (`N of M tokens resident …
compacting now`) and, after the fork, a second REPORT (`compacted: N tokens resident
now, was M`). One code, two facts, which is why `compaction-facts` reads the SENTENCE
and not the code: the same warning code is a row saying *Compacting* and a row saying
*Compacted*, and only the words tell them apart. Filed as an observation for the
daemon's side rather than fixed here — the daemon naming one thing twice is its
business, and inferring a join between them would be this head inventing a fact.")

(defun %digits-at (text start)
  "TEXT's integer beginning at START, and the index one past it. NIL when none does.

The daemon writes counts with no separators (`format!(\"{}\", u64)`), so a run of digits
is the whole number and there is no locale to guess at."
  (when (and (integerp start) (< -1 start (length text)) (digit-char-p (char text start)))
    (let ((end start))
      (loop while (and (< end (length text)) (digit-char-p (char text end)))
            do (incf end))
      (values (parse-integer text :start start :end end) end))))

(defun %number-after (text marker &optional (from 0))
  "The integer that follows MARKER's first occurrence at or after FROM, across the space.

**The gap is one space in every sentence the daemon writes** — `compacted from 943000` —
and skipping it HERE rather than spelling `\"from \"` into the marker keeps each marker
the phrase a person would quote, and keeps it equal to what stands in the `format!`
strings that the guard test reads, where the placeholder sits immediately after the word.
Measured: without this, `no-progress` read its `:was` as NIL."
  (let ((at (search marker text :start2 (max 0 (or from 0)))))
    (when at
      (let ((i (+ at (length marker))))
        (loop while (and (< i (length text)) (member (char text i) '(#\space #\tab)))
              do (incf i))
        (%digits-at text i)))))

;;; ### `context_wall`, ruled separately, because the ruling differs
;;;
;;; **It stays a note, and it is the only one of the family that does.** The requirement
;;; asked which, and there are three reasons:
;;;
;;;   · **It is terminal in the cases where nothing follows.** `context_wall` is
;;;     published when the turn hits the wall — and then a compaction may be skipped
;;;     (automatic compaction off), may fail, or may never fire at all. A fact that is
;;;     SOMETIMES the compaction's reason and SOMETIMES the only sentence there is has to
;;;     be a fact in its own right, or the case where nothing compacted is the case that
;;;     says nothing. That is R17's rule one more time: a disclosure that is conditional
;;;     on a later event is a disclosure that does not happen.
;;;   · **It is a failure** — the turn stopped before it finished — and letibot classifies
;;;     it that way. The failure register is where a stopped turn belongs.
;;;   · **Its numbers are already on the row.** The wall and the announcement carry the
;;;     same pair (`938,669 of 999,999`); folding the wall into the compaction's row would
;;;     print one measurement twice on one card.
;;;
;;; So: `context_wall` and `auto_compact_skipped` are notes — the two codes whose fact is
;;; *nothing was attempted* — and every code that reports an attempt is a row.

(defun compaction-facts (detail)
  "WHAT a compaction warning says, as numbers — R24's extraction and its ONE assumption.

**The daemon states these facts in PROSE and a headline needs numbers**, so this reads
the sentences letibot's `sessions.rs` writes. That is the thing this head refuses
everywhere else — `JobOutput` carries its offsets *beside* the text precisely so a pane
need not take a footer sentence apart — so this is a **bridge and not a design**: the
numbers want to be fields, and the ask is filed. Two things make it safe meanwhile:

  · **the assumption is CHECKED rather than believed** —
    `every-compaction-sentence-this-head-parses-is-still-the-one-letibot-writes` reads
    that file and fails if a format string moves, so a reword is a red suite and not a
    silently wrong row;
  · **a detail this cannot read returns NIL**, and the caller falls back to a plain note
    — today's behaviour. The failure mode of a reword is *a note again*, never a row
    with invented numbers.

Returns a plist whose `:kind` is `:compacted`, `:compacting`, `:no-progress`, `:failed`
or `:reseat`. NIL means *this head cannot read that sentence*."
  (let ((d (or detail "")))
    (cond
      ;; the failure, which has no numbers to give: "the automatic compaction did not run"
      ((search "the automatic compaction did not run" d)
       (list :kind :failed))
      ;; "compacted from R to A tokens and that is STILL within H of the W window, …"
      ((search " tokens and that is STILL within " d)
       (list :kind :no-progress
             :was (%number-after d "compacted from")
             :after (%number-after d " to " (search "compacted from" d))
             :headroom (%number-after d " tokens and that is STILL within ")
             :window (%number-after d " of the ")))
      ;; "compacted: W → A tokens, on transcript ID."
      ((search " tokens, on transcript " d)
       (let* ((mark " tokens, on transcript ")
              (at (search mark d))
              (from (+ at (length mark))))
         (list :kind :compacted
               :was (%number-after d "compacted: ")
               :after (%number-after d " → ")
               :transcript (subseq d from (or (position #\. d :start from) (length d))))))
      ;; the re-seat's own account: "re-seated: N tokens of conversation carried …"
      ((search "re-seated: " d)
       (list :kind :reseat :tokens (%number-after d "re-seated: ")))
      ;; the second report after the fork: "compacted: A tokens resident now, was W."
      ((search " tokens resident now, was " d)
       (list :kind :compacted
             :after (%number-after d "compacted: ")
             :was (%number-after d " tokens resident now, was ")))
      ;; the announcement: "R of W tokens resident, leaving less than the H …"
      ((search " tokens resident, leaving less than the " d)
       (list :kind :compacting
             :resident (nth-value 0 (%digits-at d 0))
             :window (%number-after d " of ")
             :headroom (%number-after d " tokens resident, leaving less than the ")))
      (t nil))))

;;; ### R27's record: the structure the wire now carries beside the sentence
;;;
;;; **`detail` stays exactly as it is** — it is the sentence every reader falls back to, and a
;;; head that ignores `compaction` entirely is a correct head (R28). This is the same compaction
;;; as FIELDS, and what it buys is that the head no longer takes the sentence apart: the section
;;; list, the tail, the truncation and the template are all facts on the frame.

(defparameter +compaction-sections-key+ "compaction.sections"
  "The settings row carrying the headings a record has, comma-joined with no spaces.

**A row and not a list here**, for the reason `head-run.tools` exists: a head holding its own
copy of the headings would drift the first time the template gained one. It is also what makes
the TWO ABSENCES tellable apart — a name in this row with no section on the report is *nobody
said*, and it can only be known by asking the daemon's list. An absent row is a daemon older
than this one, and then the head draws the sections the report carries and says nothing about
the rest, which is the same shape as every other absent row in this tree.")

(defvar *compaction-sections* nil
  "The headings a compaction record has, off the daemon's own row — or NIL when it has not said.

**A `defvar` and not a slot in the session, and this is the same choice `*daemon-protocol*`
makes for the same two reasons.** The names are needed by a function that has no head in hand:
`note-compaction` files the row from a SESSION, on the `apply-event` path, and the payload it
builds has to know which headings nobody wrote. A session slot would also be a struct layout
change, and this tree's own note is that a layout change is a restart while a push must survive —
so live daemon state read by the renderer lives in a global, as `*daemon-protocol*` does.

It is set in ONE place (`%fold-settings`, beside `(head-settings head)`) and rebound by
`with-replay-globals`, because a replay folds frames and a stale list would put one session's
headings into another's record.")

(defun compaction-section-names (settings)
  "The headings a compaction record has, as the DAEMON lists them, or NIL when it has not said.

Read from the row and never from a constant here, for the reason `head-run-tools` reads its own
row: a head holding its own copy of the headings would drift the first time the template gained
one. An absent row is a daemon older than R28 and is the same NIL as a daemon that named none."
  (let ((row (and settings
                  (find +compaction-sections-key+ settings
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (when row (%split-commas (or (getf row :value) "")))))

(defun %fold-settings (settings)
  "Take the daemon's rows: store them, and take the two facts this head uses BELOW the head.
The settings frame is the only place `head-settings` is written, so it is the only place these
can go stale — and putting the fold here rather than at each reader is what keeps one writer."
  (setf *compaction-sections* (compaction-section-names settings))
  settings)

(defun compaction-report (w)
  "W's `compaction` object as a plist this head can draw, or NIL when there is none.

**NIL is a fact about the daemon, not about the compaction**: every warning that is not a
compaction has no such object, and so does every daemon older than R28. The caller then draws
what it always drew — the sentence — which is why this returns NIL rather than an empty shape.
R28 is explicit that the wire is `null`/missing and never `{}`: *a present-but-empty object
would be a compaction nobody could describe.*

**The two absences are made explicit HERE rather than at the drawing**, so that a section list
with a heading nobody wrote and a heading written empty cannot be confused one level down. A
section present with an empty body keeps its entry — *nothing is under it* — and a heading in the
daemon's list with no entry at all is not manufactured here: the drawer asks
`compaction-section-names` about it.

The fields are read defensively: this is the other half's grammar, and a field that arrives in a
shape this build does not expect is DROPPED rather than drawn as a blank — the same rule the
`head-run.tools` descriptors keep."
  (let ((c (getf w :compaction)))
    (when (consp c)
      (list :kind (getf c :kind)
            :tokens-before (getf c :tokens-before)
            :tokens-after (getf c :tokens-after)
            :transcript (getf c :transcript)
            :resident (getf c :resident)
            :window (getf c :window)
            :headroom (getf c :headroom)
            :cut-off (and (getf c :cut-off) t)
            :template (and (stringp (getf c :template)) (getf c :template))
            :sections (loop for s in (getf c :sections)
                            when (and (consp s) (stringp (getf s :name)))
                              collect (cons (getf s :name) (or (getf s :body) "")))
            :tail (let ((t* (getf c :tail)))
                    (and (consp t*)
                         (list :turns (loop for tn in (getf t* :turns)
                                            when (and (consp tn) (stringp (getf tn :text)))
                                              collect (cons (or (getf tn :role) "") (getf tn :text)))
                               :carried (getf t* :carried)
                               :because (or (getf t* :because) "")
                               :dropped (getf t* :dropped))))))))

(defun compaction-record (w)
  "The record W's `compaction` carries, as TEXT for the row's payload, or NIL when there is none.

**This IS what the row draws when the structure is present**, and the sentence is what it draws
when it is not — one row, one record, and no reader sees the same compaction twice. The sentence
stays on the item (`:compaction`), so nothing is lost by preferring the fields: it is the
fallback and the thing `/diagnostic`-style readers can still reach, not a second copy on the
glass. R24's own counting rule, which the operator wrote: *how many times is nothing-ran
needed* — once.

**Sections are drawn in the DAEMON'S order, which is the settings row's order**, so a heading
nobody wrote keeps its place in the shape rather than being appended to the bottom. Each heading
draws its body, or `(none)` when the model wrote the heading and nothing under it, or
`(not stated)` when the daemon's list names it and the record has no such section. **Those two
are different facts and the whole shape turns on them**: a reader that renders the second as the
first has reported silence as a clean bill of health.

**The tail is a block of its own and never folded into the last section.** It is what was carried
VERBATIM, which is a different kind of thing from what was summarised — and a tail appended to
`Relevant Files` would read as more of that section.

**An unknown `because` is printed raw.** The daemon's vocabulary, and a head that met a fifth
reason must show it rather than choose between dropping the fact and inventing one — R28's own
rule, and the reason it is a string on the wire."
  (let ((r (compaction-report w)))
    (when r
      (let* ((names *compaction-sections*)
             (found (getf r :sections))
             ;; the daemon's list when it sent one, else the sections it found, in its order
             (order (or names (mapcar #'car found)))
             (seen nil)
             (out nil))
        (dolist (name order)
          (let* ((hit (assoc name found :test #'string=))
                 (body (and hit (cdr hit))))
            ;; **ONE wrap, not two.** The first cut wrote `(list (list :heading …))`, so
            ;; `(car piece)` was a LIST rather than `:heading` and every heading fell through the
            ;; text renderer's `case` — the record drew its bodies with no names over them, which
            ;; is the one thing a section list is for. Found by the probe that printed the
            ;; record's own pieces, not by reading the code.
            (push (list :heading name (not hit)) out)
            (cond
              ((not hit) nil)                       ; `(not stated)` is the heading's own mark
              ((zerop (length (string-trim " " body))) (push (list :empty) out))
              (t (dolist (l (%payload-lines body))
                   (push (list :body l) out))))
            (push name seen)))
        ;; **sections the daemon sent and its own list does not name.** A template that gained a
        ;; heading, or a row written by a newer daemon: drawn after the known ones rather than
        ;; dropped, because a head that hid a section because it could not place it would be
        ;; withholding the record it was sent.
        (dolist (s found)
          (unless (member (car s) seen :test #'string=)
            (push (list :heading (car s) nil) out)
            (dolist (l (%payload-lines (cdr s)))
              (push (list :body l) out))))
        ;; --- the tail, its own block, introduced by its own header
        (let* ((t* (getf r :tail))
               (turns (getf t* :turns))
               (because (getf t* :because))
               (carried (getf t* :carried))
               (dropped (getf t* :dropped)))
          (push (list :tail-head
                      (format nil "tail — ~a~@[ · ~d item~:p of the newest exchange left off the front~]"
                              (cond
                                ;; an EMPTY tail says WHY, which is the requirement's third
                                ;; clause: a local compaction carries no turns by ruling, and a
                                ;; tail that drew nothing at all would read as a bug
                                (turns (format nil "~d turn~:p carried~@[ (~a)~]"
                                               (length turns) because))
                                (t (format nil "nothing carried (~a)" because)))
                              dropped))
                out)
          (dolist (tn turns)
            (push (list :turn (car tn) (cdr tn)) out)))
        (when (getf r :template)
          (push (list :template (getf r :template)) out)
          (push (list :blank) out))
        (nreverse out)))))

(defun compaction-record-text (record)
  "RECORD (from `compaction-record`) as the text a tool row's payload is, or NIL.

**The payload is text** — that is the wire's field and the fold's unit — so the record is
rendered to it here rather than the drawer being taught a second shape. The MARKS are the
record's own: a heading, `(none)` for a heading the model wrote and left empty, `(not stated)`
for one the daemon's list names and the record has not got."
  (when record
    (let ((out nil))
      (dolist (piece record)
        (case (car piece)
          (:heading (push (cadr piece) out)
                    (when (caddr piece) (push "      (not stated)" out)))
          (:empty (push "      (none)" out))
          (:body (push (format nil "      ~a" (cadr piece)) out))
          (:blank (push "" out))
          (:tail-head (push "" out) (push (cadr piece) out))
          (:turn (push (format nil "      ~a: ~a" (cadr piece) (caddr piece)) out))
          (:template (push (format nil "template ~a" (cadr piece)) out))))
      (format nil "~{~a~^~%~}" (nreverse out)))))

(defun compaction-row-p (w)
  "Is W a compaction this head renders as a TOOL ROW rather than a note?

Both halves, and the second is what makes the fallback honest: the code must be one of
`+compaction-row-codes+` **and the sentence must be readable**. A compaction warning
whose words this head cannot parse is a note, which is exactly what it was before R24."
  (and (member (or (getf w :code) "") +compaction-row-codes+ :test #'string=)
       (compaction-facts (getf w :detail))
       t))

(defun %compaction-subject (facts)
  "The headline's SUBJECT — **the numbers**, in the shape the ruling asked for.

`~:d` is Common Lisp's thousands-separator directive, which is the operator's own
spelling in the requirement (`939,708 → 8,703 tokens`) and the one number format on
this screen that is neither `747.5k` nor a raw integer. A count you are deciding about
is read digit by digit, not scaled."
  (case (getf facts :kind)
    (:compacting (format nil "~:d of ~:d tokens"
                         (or (getf facts :resident) 0) (or (getf facts :window) 0)))
    (:reseat (format nil "~:d tokens carried" (or (getf facts :tokens) 0)))
    (:failed "the automatic compaction did not run")
    (t (format nil "~:d → ~:d tokens"
               (or (getf facts :was) 0) (or (getf facts :after) 0)))))

(defun %compaction-verb (facts)
  "The word for the row: a compaction that is happening, one that happened, or a
re-seat, which is a compaction that lands on a different prompt."
  (case (getf facts :kind)
    (:compacting "Compacting")
    (:reseat "Re-seated")
    (t "Compacted")))

(defun %compaction-failed-p (facts)
  "Is FACTS a compaction that was tried and is not a success?

**Two of the five kinds, and they are not the same failure.** `:no-progress` ran and did
not help — the summary is still near the wall, so automatic compaction switched itself
off. `:failed` was never run. letibot's severity table calls both failures, and the row
carries the same red the note did."
  (member (getf facts :kind) '(:no-progress :failed) :test #'eq))

(defun %compaction-cut-off-said (w)
  "` · cut off` when the record ran out of room before it finished, and the empty string otherwise.

**On the HEADLINE and not only in the payload**, which is the whole reason R28 carries it as a
bool: a templated record is exactly where *truncated* stops being readable out of any one section
— the cut falls wherever the model ran out, which with seven headings can be inside `Relevant
Files` — and a FOLDED row shows one payload line and a seam. A fact only visible after expanding
the fold is a fact the reader who did not expand it does not have. The daemon's sentence carries
the same fact in words; this is the fact, where it cannot be missed."
  (let ((r (compaction-report w)))
    (if (and r (getf r :cut-off)) " · cut off" "")))

(defun note-compaction (session w)
  "FILE W as a TOOL ROW. T when one was filed; NIL when W is not a compaction row.

**The row IS a `tool_result`** — `:name \"compact\"`, an outcome, and the daemon's own
sentence as its payload — so every affordance comes from machinery that already exists
and is already tested: `%tool-result-lines` draws the headline and folds the payload,
`payload-view-seed` gives it `ctrl-t`, the seam and the pager are the payload window's,
the payload is sanitised by `%without-control` as every other result is, and it scrolls
with the conversation because it is IN the conversation.

**`:verb` and `:subject` are the ROW's own**, and that is a general capability rather
than a compaction special case: a tool row derives its verb from the tool's name and its
subject from the `Assistant` row that proposed the call, and **a compaction has no
proposing row** — nobody called it, the daemon did — so there is no `call_id` to look a
target up by, and the numbers are what belongs on the headline. Both fields are optional
and default to today's derivation, so nothing else changes shape.

**It is not a note**, and that is the point of the filing rather than an accident of it:
`session-warnings` does not get it, so `/notes` does not list it, `/status` does not
count it, and the retired set does not apply. The ROW is its record — the whole sentence
is its payload, which is more than a note ever kept."
  (when (compaction-row-p w)
    (let* ((facts (compaction-facts (getf w :detail)))
           ;; **R27: the record the wire carries, when it carries one.** The row draws the
           ;; STRUCTURE then — sections, tail, template — and falls back to the daemon's sentence
           ;; when there is no such object, which is every daemon before R28 and every warning
           ;; that is not a compaction. One row, one record: the sentence stays on the item rather
           ;; than being drawn under the structure, because it is the same numbers said twice and
           ;; R24 already settled how many times is enough.
           (record (and (compaction-report w)
                        (compaction-record-text (compaction-record w))))
           (bad (%compaction-failed-p facts))
           (id (format nil "leticl-compaction-~d" (incf *filed-notes*)))
           (row (list :item-id id
                      :kind "tool_result"
                      :ts (or (getf w :ts) 0)
                      ;; the warning is kept on the item, as `:warning` is kept on a
                      ;; note row: the row is the record, and the sentence is on it.
                      :compaction w
                      :item (list :type "tool_result"
                                  :call-id (format nil "compaction-~a" id)
                                  :name "compact"
                                  :verb (%compaction-verb facts)
                                  :subject (concatenate 'string (%compaction-subject facts)
                                                        (%compaction-cut-off-said w))
                                  :outcome (list :outcome (if bad "failed" "ok"))
                                  :payload (or record (getf w :detail) "")))))
      (push-item session row)
      row)))

(defun warning-order (session)
  "The warnings this head holds, OLDEST first — the order `/notes` numbers them in.

`session-warnings` is newest-first because a live warning is pushed; a snapshot's
own list is the daemon's, which is chronological. Reversing gives the reading order
the listing wants, and the numbering a reader types back."
  (reverse (session-warnings session)))

(defun retire-warning (session w)
  "Retire W: take its row off the screen and remember that it is retired.

**Retired is not deleted.** The warning stays in `session-warnings`, `/status` counts
it, and `/notes` lists it with its whole text — the temptation is a dismiss key that
drops the sentence, and a head that can drop a warning silently is a head whose
warnings cannot be trusted to be complete. Returns NIL when it was already retired."
  (let ((id (warning-identity w)))
    (if (member id (session-retired session) :test #'string=)
        nil
        (progn
          (push id (session-retired session))
          (%reflag-warning-rows session)
          ;; a row that renders as nothing is a change the cache cannot see: the
          ;; item count and the vector's identity both hold still
          (incf *hist-generation*)
          t))))

(defun retire-all-warnings (session)
  "Retire every warning this head holds. Returns how many newly went.

Through `retire-warning` one at a time rather than by emptying the list, so the row
flags and the generation bump happen by the one path that knows how to do them."
  (let ((n 0))
    (dolist (w (session-warnings session))
      (when (retire-warning session w) (incf n)))
    n))

(defun restore-warnings (session)
  "Put every retired warning back on the screen. Returns how many came back."
  (let ((back (length (session-retired session))))
    (setf (session-retired session) nil)
    (%reflag-warning-rows session)
    (incf *hist-generation*)
    back))

(defun warning-counts (session)
  "`(values HELD RETIRED)` for `/status`: how many warnings this head holds, and how
many of them the reader has retired.

Computed from the WARNINGS rather than kept as a counter, for the reason the
reference computes it the same way (`app.rs:5727-5732`): a counter can disagree with
the screen, and a count of what is hidden is the one count that may not be wrong.
`HELD` is the session's list, so `RETIRED` can never exceed it."
  (let ((ws (session-warnings session)))
    (values (length ws)
            (count-if (lambda (w) (session-retired-p session w)) ws))))

(defparameter +events-not-folded-here+
  '(:explain :screen-requested :secret-requested :secret-settled
    ;; the prompt card's two events, the same first kind as the secret's: the
    ;; loop raises the card from `:prompt-requested` and closes it from
    ;; `:prompt-settled`, and the folder has no card to raise. Found by the first
    ;; test ever to send one (2026-10-09): every prompt event filed an *unknown
    ;; event* row and bumped `*unreadable-total*`, so a live head raising the card
    ;; was also alarming `⚠ unreadable 1` about a frame it reads perfectly well.
    :prompt-requested :prompt-settled
    ;; R24 part two. The head RUNS the call and sends the result from the frame
    ;; path, because a run is an act and not a fold: it needs the socket, the
    ;; door and — if this head ever has fetchers — the network, none of which the
    ;; session's folder can reach. Named here so a frame this head reads and acts
    ;; on is not reported as one it has never heard of.
    :operator-call-allowed)
  "Events this head KNOWS and does not fold into session state.

Two kinds, and both have to be named or the counter cries wolf:

  · **folded by the head LOOP, which owns the last painted frame and the input
    focus** — `screen_requested` is answered with the rows just drawn,
    `secret_requested` raises the masked field, `secret_settled` dismisses it.
    `apply-event` is the session's folder and cannot do any of those; it is handed
    these only by a caller that skipped the loop (a test, a replay), so without
    this list a head would report a frame it reads perfectly well;
  · **`explain`**, which the reference answers `Filtered` (app.rs:3017) and this
    head has no renderer for.

Named here rather than left to the fallthrough so that *I know this tag and it is
not mine to fold* stays separable from *I have never heard of this tag* — which is
the difference between a quiet head and a silent one, and the whole point of
`*unreadable-total*`.")

;;; ------------------------------------------------------ a counted operation ;;;
;;;
;;; **The daemon's own counter, when there is one.** `SessionEvent::Filling
;;; { what, unit, done, total }`: `what` is the operation in the daemon's own words,
;;; `unit` the noun its count is in, and `done`/`total` the count. It exists because
;;; **the layer that owns the fact should state it** — a head can see that rows are
;;; missing bodies, and cannot see whether that is a reseat, a `/compact`, a resume or
;;; a plain attach. A carry is the same kind of fact and is the reason the event is
;;; general rather than an import's: one event, one renderer, and the head infers only
;;; when nobody has told it.
;;;
;;; **Ephemeral**, like `JobOutput`: a tick from four minutes ago is a lie about now.
;;; The durable residue of an import is the rows themselves and its finish note. So
;;; this is a defvar and not a session slot, it is not snapshot-carried, and it is
;;; cleared the moment the count is complete — a bar left at `total of total` would sit
;;; on the screen for ever, and a bar that cannot end is worse than no bar.

(defparameter *stall-ms* 15000
  "How long a silence before the head says so — the reference's own number
(`stuck_line`, app.rs:7594: `if quiet > 15_000`). Ours was 20 000, which is five
seconds of a dead turn nobody is told about; long enough that a slow model
thinking is not a stall, short enough that a dead socket is not a mystery.

**Two questions, one number.** `stall-text` (chrome.lisp) asks it about the turn — has the
daemon said anything about the work it is running — and `filling-active-p` asks it about a
counted operation — has the daemon ticked the bar lately. Both are *has the daemon stopped
talking to me*, both are measured from RECEIVED-at, and this file owns it because the
filling state does and because it loads first. A second window is how the two would come to
disagree about what silence means.

A `defparameter` and not a `defconstant`: the file pusher skips constants, so a constant
could never be moved on a running head.")

(defvar *filling* nil
  "The counted operation in flight, or NIL: a plist
`(:what W :unit U :done D :total T :at-ms M)`.

A defvar, not a session slot, for the reason all live state is: a struct layout change
is a restart. Bound by `with-replay-globals`, because a replay must answer the same
bytes twice.")

(defun tick-recent-p (state)
  "Has STATE's tick been heard from LATELY? — one clock and one window for every progress state
this head draws.

**Written once because the rule was learned on one of them and the other went without it.** A
progress state whose ticks stopped is not progress, and `filling-active-p`'s docstring carries the
measurement: `republish` published 57 ticks and stopped, a session whose rows and items disagree
ends the walk without ever sending `done == total`, and the bar sat at *57 of 1790 rows* for three
and a half minutes while the operator watched a frozen screen. `*stall-ms*` is the window and
`*now-ms*` the clock, and **both states read the same two so they cannot come to disagree about what
silence means** — the argument the stall line next door already makes for sharing one number.

**A state with no clock does not expire.** `:at-ms` is NIL in a replay and in any test that has not
told the head what time it is (the note functions stamp it only when `*now-ms*` is positive), and
expiring on an unknown age would make a head's behaviour depend on whether a clock was running
rather than on the thing it is drawing."
  (let ((at (getf state :at-ms)))
    (or (null at) (not (plusp *now-ms*)) (< (- *now-ms* at) *stall-ms*))))

(defun filling-active-p ()
  "Is a counted operation in flight that the head should draw?

**Three ways it ends, and the third was found on the operator's screen.** The first two are
facts rather than timers: the count COMPLETES (`done >= total`), or the connection does —
a socket that goes mid-import would otherwise leave a bar claiming progress for ever. The
file's own rule has always been *a bar that cannot end is worse than no bar*.

**What the third closes is a bar that DID not end.** Measured on a live head: `republish`
(a resume's carry) published 57 ticks and stopped — and because the loop emits one tick per
row that has a BODY, a session whose rows and items disagree ends the walk without ever
sending `done == total`. The head holds no completing tick, `done < total` stays true, and
the bar sat at *57 of 1790 rows* for **three and a half minutes** while the operator watched
a frozen screen. The tick's own arrival time was in `*filling*`'s `:at-ms` the whole time and
nothing read it.

So a tick older than `*stall-ms*` is not news, and the bar is not drawn. That is the same
sentence the stall line makes — *the daemon has gone quiet* — applied to the other thing on
this screen that claims the daemon is working. It is deliberately the SAME number and the
same clock: both measure received-at, and one window means the two cannot disagree.

**A tick with no clock does not expire.** `:at-ms` is NIL in a replay and in any test that
has not told the head what time it is (`note-filling` only stamps it when `*now-ms*` is
positive), and expiring on an unknown age would make the bar's behaviour depend on whether a
clock was running rather than on the operation." 
  (and *filling*
       (let ((done (or (getf *filling* :done) 0))
             (total (or (getf *filling* :total) 0)))
         (and (plusp total) (< done total)
              ;; **the news test**: a stamped tick must be recent, an unstamped one is
              ;; not aged at all — see `tick-recent-p`
              (tick-recent-p *filling*)))))

(defun note-filling (env)
  "Fold one `filling` tick. Returns `:dirty` when the line should be redrawn.

**The completion is the clear.** `done == total` is the daemon saying it is finished,
and the line goes — the operation's own finish note is what says it ended, and a bar
left at `total of total` would sit on the screen for ever. A tick with no `total`, or
with `total` zero, is not an operation to draw either: there is nothing to be a
fraction OF, and a line reading `0 of 0` is a render fault dressed as a measurement.

**`what` and `unit` are the daemon's and are kept as they arrive**, verbatim, including
`NIL` — `filling-progress-line` is what decides how to draw each, so one place knows
the fallbacks rather than two. A daemon that sent `filling` without the words (a
version skew, R5) gets the head's own cause-free sentence rather than a `NIL` where a
noun goes."
  (let ((done (or (getf env :done) 0))
        (total (or (getf env :total) 0)))
    (setf *filling* (when (and (integerp total) (plusp total)
                               (integerp done) (< done total))
                      (list :what (getf env :what)
                            :unit (getf env :unit)
                            :done done :total total
                            :at-ms (and (plusp *now-ms*) *now-ms*))))
    :dirty))

(defun reset-filling ()
  "Forget a counted operation. For a session change, and for a dead socket."
  (setf *filling* nil))

;;; -------------------------------------------------------- the compaction ;;;
;;;
;;; **THE FOLD'S OWN FIGURE, AND IT IS NOT `PromptProgress`.** (letibot `f273300`, protocol 27.)
;;; The overrun compaction summarises a SCRATCH transcript through a `NullSink`, so until this
;;; event landed nothing of it reached a head at all: minutes of a still screen, at the moment the
;;; session is largest and the model slowest. The operator asked *"leticl compacts but why no
;;; progress bar?"* and then sharpened it — *"even more so for this overruns when we compact in
;;; turns."*
;;;
;;; **AND THE REASON THE EVENT IS ITS OWN IS A DEFECT WORTH NOT REPEATING HERE.** Forwarding the
;;; scratch turn's raw `PromptProgress` put the SCRATCH prompt's token count into `turn.progress`,
;;; which is the SESSION's — so the operator watched `69k` sit over a 240k conversation that had
;;; not changed. *The number was never wrong; its label was.* So this is a defvar of its own and
;;; nothing here writes `*turn-progress*`.

(defvar *compaction* nil
  "The fold in flight, or NIL: a plist
`(:half H :halves N :prompt P :processed X :written W :unit U :at-ms M)`.

A defvar, not a session slot, for the reason all live state is: a struct layout change is a
restart. Bound by `with-replay-globals`, because a replay must answer the same bytes twice.")

(defun compaction-active-p ()
  "Is a fold running that the head should draw?

Ephemeral, like `Filling` — and **this was the one that did not expire.** The operator: *\"compacting
the conversation still spins\"*, with the fold's end never arriving mid-turn.

The docstring here used to say the state was *cleared by the fold's own end — the `compacted`
warning, or a turn finishing — rather than by a timer in here*, and MEASURED, that was false twice
over:

  · `reset-compaction` **had no caller anywhere in the tree** — it was defined, documented as the
    one writer, and called from nothing;
  · and the only clear that existed was a progress tick whose `half` is not positive. So a fold
    whose ticks STOPPED — which is what an overrun compaction mid-turn looks like from here — left
    `*compaction*` set for the rest of the head's life, and the spinner spun on three surfaces
    (chrome.lisp draws it in three places) for a fold that had finished minutes ago.

Both halves are fixed where the shape says: the tick clause is `tick-recent-p` (the same clock and
the same window as the filling bar, because two answers to *has the daemon gone quiet* is how they
come to disagree), and the fold's own end is real now — `note-turn-finished` calls
`reset-compaction`, and every terminal arm of `apply-event` goes through it."
  (and *compaction* (tick-recent-p *compaction*)))

(defun note-compaction-progress (env)
  "Fold one `compaction_progress` tick. Returns `:dirty`.

**THE BAR IS DRIVEN FROM `written`, AND THAT IS THE WHOLE TRAP THIS EVENT CARRIES.** `processed`
is how much of the half's prompt the server has READ, and on a messages transport — which is what
the operator's deepseek sessions use — the server reports no prefill at all, so it arrives as
`0`. That is *this transport does not count that*, NOT *nothing has happened*: a bar filling from
`processed` would sit at zero for the whole fold and look exactly like the hang this event exists
to remove.

`unit` is kept as it arrives and never assumed — `tokens` where the transport reports the server's
own count, `chars` where it reports only text. The two do not count the same thing, so one name
for both would be a lie about one."
  (let ((half (or (getf env :half) 0))
        (halves (or (getf env :halves) 0)))
    (setf *compaction* (when (and (integerp half) (plusp half))
                         (list :half half :halves (max 1 (or halves 1))
                               :prompt (or (getf env :prompt-tokens) 0)
                               :processed (or (getf env :processed) 0)
                               :written (or (getf env :written) 0)
                               :unit (getf env :unit)
                               :at-ms (and (plusp *now-ms*) *now-ms*))))
    :dirty))

(defun reset-compaction ()
  "Forget the fold. For its own end, a session change, and a dead socket."
  (setf *compaction* nil))

