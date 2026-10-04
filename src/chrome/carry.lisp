;;;; carry — the carry line: a compaction's numbers on the glass
;;;;
;;;; Split out of `chrome.lisp`, which was one 2711-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; -------------------------------------------------------- the carry line ;;;
;;;
;;; **One line for a bulk announcement whose bodies are still coming**, and it exists
;;; because `/reseat` and `/compact` announce every carried row before a single body
;;; follows. Drawn one per row that is a screen of placeholders — the operator's word
;;; was *"insane amount of grainess"*, and their instruction was to reuse what already
;;; exists: *\"we have this cat animation for progress and we have prefill progress bar
;;; for local models\"*.
;;;
;;; So: `cat-frame` (the walking cat the pre-attach wait draws) and `progress-bar`
;;; (the three-valued bar the local prefill draws), fed with ROWS instead of tokens.
;;;
;;; **IT SAYS WHAT IT KNOWS AND NOT WHY.** The head can see that a bulk announcement
;;; left rows without bodies; it cannot see whether the operation behind it was a
;;; reseat, a `/compact`, a resume or a plain attach. So the sentence is cause-free —
;;; `N rows announced, waiting for the daemon to send them` — and the named version
;;; (`carrying the conversation onto the new prompt`) belongs to a daemon that reports
;;; the operation it is running, which is what `SessionEvent::ImportProgress` landed
;;; for at protocol 23. A head that names a cause it has not observed is the same
;;; defect as a counter derived from a proxy: the sentence claims something the
;;; evidence does not know.

(defparameter +body-patience-ms+ 5000
  "How long a row may sit announced-without-a-body before the head says it never came.

**MEASURED, and the measurement is why it is not the reference's 3000.** On a live
session (this head, pid 2889943, 59 consecutive announce→body pairs): the longest gap
was **31 ms**, the 90th percentile **1 ms**, the median **0**, and none exceeded
1000 ms. A body normally follows its announcement inside the same 30 ms tick.

So 3000 would work — and the reference's 3000 still produced a FALSE alarm
(*\"9,570 row(s) announced and never filled in\"*, three seconds into a healthy import),
because its sentence fired on a *rendering* of the gap rather than on the gap. Two
things follow, and they are the whole of this constant:

  · **the patience has to cover a gap that is genuinely slow.** This head adds no case
    of its own, and 5000 ms is 160× the slowest ordinary body measured.
  · **the case that CAN honestly take minutes is excluded by the TRIGGER, not waited
    for.** A prompt queued behind a running turn is a live `transcript_appended` whose
    content arrives when the prompt is sent — R2, *\"a queued prompt first reaches model,
    thinking starts, and after some time the prompt goes out of queue and appears\"* —
    and that can be minutes. It never enters this count: the count is a **bulk
    announcement's** rows (`note-carry`), and a queued prompt arrives one event at a
    time. Waiting five minutes to report a hole would make the diagnostic useless;
    knowing which rows are waiting on a queue is what makes a five-second patience
    honest.")


(defparameter +carry-min-rows+ 64
  "How big a bulk announcement has to be before it is drawn as a carry BAR.

**MEASURED.** Over the daemon's own store (242 turns across its sessions): rows per turn
— median **12**, p90 **317**, maximum **3635**; and the two carries this session has
actually seen were **2702** and **4473** rows. So 64 sits above an ordinary turn's tail
and below any real carry, with the median turn five times under it.

**And it gates the BAR, not the DIAGNOSTIC.** A small batch — a resync of a three-row
session, a snapshot with a couple of holes in it — draws no bar, because a bar with a cat
on it for three rows is noise dressed as information. But if those rows never arrive,
`carry-line` still says so: that sentence is the only thing on the screen that ever
reports a row the daemon announced and never sent, and the operator learned about a real
daemon-side hole from exactly it. Suppressing it for being small would throw away the
diagnostic to protect the decoration.")

(defvar *carry-last-done* nil
  "How many carried rows had arrived at the last frame that asked, or NIL.

The only state the line needs, and it is about the SEQUENCE of frames rather than about
the session — which is why it is here and not in `session.lisp`: the clock it is
compared against is this file's (`*now-ms*`). Bound by `with-replay-globals`, because a
replay must answer the same bytes twice.")

(defvar *carry-moved-at* nil
  "When `*carry-last-done*` last changed, on `*now-ms*`'s clock. NIL before any carry.")

(defun %carry-counts-text (done total &optional (unit "rows"))
  "`1400 of 2.7k rows`, with the numerator right-aligned in the width of its own
denominator — which is the widest it can ever be.

**Every field that can change width sits left of everything that cannot.** Two things
vary as a carry runs: this numerator, which grows from `0` to `2.7k`, and the cat,
whose frames are eight and nine columns. Anything drawn to the RIGHT of either moves
when it changes, and the operator watched exactly that: *\"move cat to the right most
position or thngs jump around\"*. So the numerator pads to the denominator's width,
the cat occupies a fixed SLOT, and the bar's own width is fixed by the columns rather
than by the fraction — leaving the bar's edge as the only thing on the row that is
meant to move."
  (let* ((d (thousands total))
         (d-w (length d)))
    ;; `~v@a` and not `~va`: `~A` pads on the RIGHT and this number is padded on the
    ;; LEFT. The first version of this line read `0    of 2702 rows` — the alignment
    ;; was there and on the wrong side, which is the same defect wearing the opposite
    ;; coat.
    (format nil "~v@a of ~a ~a" d-w (thousands done) d unit)))

(defun %carry-row-width (row)
  "The columns ROW occupies. `%segs-width` lives in markdown.lisp, later in the load
order; this is the same sum and one of the two has to exist twice."
  (loop for seg in row sum (string-width (car seg))))

(defun %carry-row (done total cat cols &optional (unit "rows"))
  "The bar, the count and the cat — as wide as COLS, or as near as the count alone
can be.

**It degrades by DELETION from the bar back**, which is `prefill-line`'s own rule, and
the order is what matters: the bar is the most expensive field and the least
load-bearing, the count is the FACT, and the cat is decoration. A carry on a
30-column terminal still has to say how far along it is — a row that overflowed and
lost its tail to the painter would say `1400 of` and nothing else, silently.

The bar's width is fixed by COLS and the fixed fields rather than by the fraction, so
its edge is the only thing on the row that moves."
  (let* ((counts (%carry-counts-text done total unit))
         (bar-cols (max 8 (min 40 (- cols (+ +cat-slot+ (length counts) 8)))))
         (full (list (cons "  " nil)
                     (cons (progress-bar (list :total total :cache done :processed done)
                                         bar-cols)
                           nil)
                     (cons " " nil)
                     (cons counts '(:dim t))
                     (cons "  " nil)
                     (cons cat '(:dim t))))
         (no-bar (list (cons "  " nil)
                       (cons counts '(:dim t))
                       (cons "  " nil)
                       (cons cat '(:dim t)))))
    (cond
      ((<= (%carry-row-width full) cols) full)
      ((<= (%carry-row-width no-bar) cols) no-bar)
      (t (list (cons "  " nil)
               (cons (truncate-to-width counts (max 1 (- cols 2)))
                     '(:dim t)))))))

(defun filling-progress-line (what unit done total cols &optional (now *now-ms*))
  "**THE one renderer for a counted operation**, whoever counted it.

A blank, the bar with `done of total {unit}` and the cat, and the operation's own word
under it. Every caller goes through here — the daemon's `filling` event and the head's
own bulk-announcement inference — so the two cannot drift apart, and the operator's
instruction (*\"we have this cat animation for progress and we have prefill progress bar
for local models. reuse that instead of spanning me with grayness\"*) is served by one
piece of code rather than two that look alike today.

    ▐███████████████████▊░░░░░░░░░░░░░░░░░░▌ 1400 of 2702 rows  (=^.^=)~
      carrying the conversation onto the new prompt

`WHAT` is the daemon's own word for the operation and is drawn VERBATIM — a head that
composes a sentence about an operation it inferred is the defect this whole line keeps
being an example of. When there is no `what` (the head's own inference) the sentence is
cause-free: `N rows announced, waiting for the daemon to send them`.

`UNIT` is the noun the count is in — `parts` for an import, `rows` for a carry. The
daemon chooses it because the daemon is the layer counting.

The bar is two-valued: landed cells are `█` and the rest `░`, and `▓` — the prefill's
`processed`, the band that means *being computed now and costing you* — never appears,
because neither a carry nor a read spends anything. The reference paints that band with
its `cache` role for exactly this reason (*\"that one is yellow\"*, on the first version),
and here it is carried in the GLYPH, so it survives a terminal with no colour at all."
  (let ((cat (format nil "~va" +cat-slot+ (cat-frame (or now 0)))))
    (list nil
          (%carry-row done total cat cols (or unit "rows"))
          (list (cons (truncate-to-width
                       (if (and what (plusp (length what)))
                           (format nil "  ~a" what)
                           ;; TRUNCATED WITH DISCLOSURE rather than left for the painter:
                           ;; a painter that silently drops what passes the right edge is
                           ;; the §6 gap, and a sentence cut with an `…` is at least a
                           ;; sentence the reader knows was cut.
                           (format nil "  ~d ~a announced, waiting for the daemon to send them"
                                   (- total done) (or unit "row")))
                       cols)
                      '(:dim t))))))

(defun compaction-progress-line (c cols &optional (now *now-ms*))
  "The fold's own line, or NIL. **The one place `CompactionProgress` is drawn.**

**THE BAR IS DRIVEN FROM `processed` ONLY WHEN THE TRANSPORT REPORTS IT, and the reason is the
whole of this event.** On a messages transport — which is what the operator's deepseek sessions
use — the server reports no prefill, so `processed` arrives as `0`. That is *this transport does
not count that*, NOT *nothing has happened*: a bar filling from it would sit at zero for the whole
fold and look exactly like the hang this event exists to remove. `%compaction-figure` decides
which number is drawn and the row NAMES it — `read` or `written` — so a reader is never looking
at a figure whose meaning they have to infer.

**AND THERE IS NO BAR IN THE SECOND CASE, because there is no denominator.** `prompt_tokens` is
the half's PROMPT — its input — and `written` is what the half has PRODUCED; a fraction of one
over the other would be two scales divided. So the messages case gets the spinner and the count,
which is exactly what `⠼ Responding · 724ms` is: a spinner beside a moving figure, and no claim
about how far through anything is.

`unit` is the daemon's and is printed BESIDE the figure rather than implied: `tokens` where the
transport reports the server's own count, `chars` where it reports only text. *The two transports
do not count the same thing and one name for both would be a lie about one.*"
  (cond
    ((null c) nil)
    (t
     (let* ((half (or (getf c :half) 1))
            (halves (or (getf c :halves) 1))
            (prompt (or (getf c :prompt) 0))
            (processed (or (getf c :processed) 0))
            (written (or (getf c :written) 0))
            (unit (or (getf c :unit) "tokens"))
            (readable (and (plusp processed) (plusp prompt)))
            (where (if (> halves 1)
                       (format nil "half ~d of ~d" half halves)
                       "the conversation")))
       (list nil
             (if readable
                 ;; the transport counts prefill: a real bar, and it says READ
                 (%carry-row processed prompt
                             (format nil "~va" +cat-slot+ (cat-frame (or now 0)))
                             cols (format nil "~a read" unit))
                 ;; no prefill: a spinner and the produced count — no denominator exists
                 (list (cons (truncate-to-width
                              (format nil "~a compacting ~a · ~a ~a written"
                                      (string (spinner (or now 0))) where
                                      (thousands written) unit)
                              cols)
                             '(:bold t))))
             (list (cons (truncate-to-width
                          (format nil "  summarising ~a~@[ — ~a~]"
                                  where
                                  (if readable
                                      (format nil "~a of ~a ~a read"
                                              (thousands processed) (thousands prompt) unit)
                                      nil))
                          cols)
                         '(:dim t))))))))

(defun carry-line (head cols)
  "The line for a bulk announcement the DAEMON has not reported, or NIL.

**When the daemon reports the operation, this yields to it** — a `filling` event is the
count and the name from the layer that owns them, and drawing an inferred line beside it
would be two bars for one operation. Everything below is the inference, and it is the
inference that has to be careful about what it claims.

Four things it is careful about, each measured on this session:

  · **the trigger is the announcement SHAPE, not a row without a body.** Letibot's
    `bodies_pending > 0` is true for the R2 window of every ordinary message, so its line
    comes up over and over for a carry that is not happening (*\"it literally appears over
    and over — carrying the conversation onto the new prompt\"*). Here the trigger is a
    snapshot that announced rows with no bodies (`note-carry`), which is what a bulk carry
    looks like on the wire. A prompt queued behind a running turn is a live
    `transcript_appended` and never enters this count.
  · **the sentence names no cause.** A reseat, a `/compact`, a resume and an attach all
    arrive as a snapshot of bodiless rows and the head cannot tell them apart, so it says
    what it knows. The named form is `filling`'s, and the daemon is the only layer that
    has it.
  · **a small batch draws no BAR** (`+carry-min-rows+`) — but it is still DIAGNOSED if it
    never lands, because that sentence is the only place a row the daemon announced and
    never sent is ever reported.
  · **past the patience it stops claiming to be progress** (`+body-patience-ms+`), and
    says what happened instead.

It disappears by itself the moment the last body lands. The stalled form is TWO rows and
not three, and that is the whole of the claim: the blank, and one quiet sentence. **The
live sentence must not be under it** — that sentence says rows are still coming, and a
head that says both is worse than the bar it replaced."
  (multiple-value-bind (total done) (%carry-counts (head-session head))
    (let ((outstanding (- total done)))
      (cond
        ;; **THE FOLD'S OWN LINE, and it comes FIRST.** A compaction is the most specific thing
        ;; that can be running: it holds the session while it works, and the two lines below
        ;; measure OTHER operations -- a bulk announcement's rows, the session's prefill. Drawing
        ;; one of those during a fold is the 69k-over-a-240k-conversation shape: a true number
        ;; under a label about something else.
        ((compaction-active-p)
         (compaction-progress-line *compaction* cols (and (plusp *now-ms*) *now-ms*)))
        ;; **the daemon is counting this one**: its line, its numbers, its name.
        ;;
        ;; **DRAWN HERE, and it is a fix rather than a phrasing.** This branch used to
        ;; answer NIL, on the intent stated in this function's own docstring — *"when the
        ;; daemon reports the operation, this yields to it"* — with the yielding
        ;; implemented and the thing it yields TO not. `filling-progress-line` had exactly
        ;; ONE call site (the carry branch below) and was therefore unreachable for the
        ;; case it was written for. Measured on the glass during a real opencode import
        ;; (9,570 parts, the filling active at every sample from t=0 to t=8 s, 320 → 2,816
        ;; of 9,570): **the screen carried no count, no bar and no operation name**, while
        ;; the head asked the loop for a frame ten times a second (`live-frame-tenths-p`
        ;; includes `filling-active-p`) for a line it never drew. So the two halves of the
        ;; old sentence were both true and joined by nothing.
        ((filling-active-p)
         (filling-progress-line (getf *filling* :what) (getf *filling* :unit)
                                (getf *filling* :done) (getf *filling* :total)
                                cols (and (plusp *now-ms*) *now-ms*)))
        ((or (minusp outstanding) (zerop outstanding))
         ;; every row the announcement promised has arrived — or there is no carry at
         ;; all. Either way the line is done, and it forgets the carry it measured.
         (when *carry-outstanding* (reset-carry))
         (setf *carry-last-done* nil *carry-moved-at* nil)
         nil)
        (t
         ;; the clock, and the movement it measures: an unknown clock (a test, a replay)
         ;; can never be stalled, because a stall is a claim about time
         (let ((now (and (plusp *now-ms*) *now-ms*)))
           (when (and now (not (eql done *carry-last-done*)))
             (setf *carry-moved-at* now))
           (setf *carry-last-done* done)
           (cond
             ;; **PAST THE PATIENCE IT IS NOT PROGRESS ANY MORE**, whatever the size.
             ;; This is the only thing on the screen that will ever report a row the
             ;; daemon announced and never sent — a bodiless row draws NOTHING in the
             ;; transcript — and it is therefore NOT gated on the batch being big, nor on
             ;; an operation being named. The operator learned about a real daemon-side
             ;; hole from exactly here.
             ((and now *carry-moved-at*
                   (>= (- now *carry-moved-at*) +body-patience-ms+))
              (list nil
                    (list (cons (truncate-to-width
                                 (format nil "  ~d row~:p announced and never filled in — the ~
                                              daemon said they exist and did not send them"
                                         outstanding)
                                 cols)
                                '(:dim t)))))
             ;; **the threshold gates the BAR, not the sentence.** Three rows are not
             ;; worth a bar with a cat on it; they are still worth telling the truth
             ;; about if they never land, so the arm above comes FIRST and this one
             ;; leaves the movement clock ALONE. Clearing it here — the first version of
             ;; this did — means a small batch can never reach the patience arm at all,
             ;; because the clock it is measured against is reset on every frame: found
             ;; by the live probe, where a two-row batch that never landed drew nothing
             ;; rather than the sentence that is the whole reason the sentence exists.
             ((< total +carry-min-rows+) nil)
             (t (filling-progress-line nil "rows" done total cols now)))))))))

(defun attach-lines (head cols)
  "The wait, or NIL when there is nothing to wait for."
  (when (attaching-p head)
    (let* ((elapsed (max 0 (- (internal-real-time-ms) *attach-started-ms*)))
           ;; LEFT-justified in a fixed slot (`{cat:<CAT_SLOT$}`): the frames are
           ;; different widths, and right-justifying moves the cat's own centre
           ;; as it walks — the jitter the fixed slot exists to prevent.
           (slot (format nil "~va" +cat-slot+ (cat-frame elapsed))))
      (append
       (list (list (cons "" nil))                ; the caller centres vertically
            (%centred-row slot cols)
            (list (cons "" nil))
            (%centred-row "· · · · ›" cols)        ; a pawprint trail, so a still
            (list (cons "" nil))                   ; frame still reads as going
            (%centred-row "asking the daemon for this session" cols)
            (list (cons "" nil))
             (%centred-row (duration elapsed) cols))
       ;; past the impatient mark the frame says how to get OUT, so a wait on a
       ;; daemon that will never answer is not a screen you have to guess at
       (when (>= elapsed +attach-impatient-ms+)
         (list (list (cons "" nil))
               (%centred-row "the daemon has not answered. ctrl-c twice, or wait" cols)))))))
