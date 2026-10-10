;;;; decisions.lisp — what an outcome and an approval are SAID as: the outcome's
;;;; word and reason, the oracle's advice, and `%decision-card-lines`, the one
;;;; spelling of the gated-by block that the live card and the settled row share.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

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
    ("backgrounded" "backgrounded")
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

**The oracle block fires**: `:advice` is copied onto the settled decision by
`session/seq-gap.lisp`'s `decision-answered` arm (`:advice (getf req :advice)`, beside
`:basis`), so the lines below are live on every settled row that had one. This paragraph
read *'cannot fire today'* and named the missing line as *'one line in another strand's
file'* — the line landed at `70dfa9f` and the sentence stayed (found by the cards reviewer,
2026-10-11: a comment that tells a reader a whole branch is dead is worse than no comment,
because it is the kind of thing a reader deletes)."
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

(defun %decision-card-lines (decision w &key open rows lead)
  "The approval a call was gated by, as card lines — ONE spelling for the settled
row and the live card, which were two blocks kept in step by convention and
had already drifted: the echoed-basis skip below was the settled row's fix
alone, so the live card drew the decider's line twice for the fraction of a
second before the settled row replaced it.

`lead` is the settled row's two columns — its card is stepped to the activity
indent by the row, so `  ·` is written here; the live card indents its whole
body uniformly at budget time, so it passes no lead and `·` lands in the same
SCREEN column by the other mechanism. `rows` is the card's own visible text,
strings, which is what the echo test searches."
  (when decision
    (append
     (list (list (cons (format nil "~a· ~a, by ~a"
                               (or lead "")
                               (%decision-word decision)
                               (%decision-who decision))
                       '(:dim t))))
     ;; and, open, what it was grounded in — `decision_detail`, the whole block
     ;; rather than the one line. The decider's own line is dropped when the
     ;; card already carries it verbatim: the operator, counting the repeats in
     ;; one card, *"how many times is 'nothing ran' needed?"*
     (when open
       (let* ((b (getf decision :basis))
              (first (and b (string-trim " " (%first-line b))))
              (echoed (and first (>= (length first) 40)
                           (some (lambda (l) (search first l)) rows))))
         (mapcar (lambda (l)
                   (list (cons (concatenate 'string (or lead "") "  ") '(:dim t))
                         (cons l '(:dim t))))
                 (%decision-detail decision (max 4 (- w 4)) :skip-basis echoed)))))))

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

