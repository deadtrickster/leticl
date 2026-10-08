;;;; warnings — the warning record: R10's disclosures, their codes and their remedies
;;;;
;;;; Split out of `session.lisp`, which was one 2916-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.

(in-package #:leticl)

;;; ---------------------------------------------------- the warning record ;;;
;;;
;;; R10. **A warning is a DISCLOSURE, not a permanent record.**
;;;
;;; The defect this file had was the mirror of letibot's, and the operator's own
;;; measurement is the specification: a `warning` envelope arrived, `session-warnings`
;;; went from 9 to 10, and it was visible NOWHERE — not a row, not a note, not a
;;; counter, not the alarm. So `auto_compact`, `compacted`, `context_wall`,
;;; `transcript_store`, `decision_corpus` and `mode_set` had never once reached this
;;; head, and every one of those is a sentence the daemon meant the operator to read.
;;;
;;; Two halves, and they are the two halves of the same rule:
;;;
;;;   · **draw it.** A warning is filed as a row in the conversation AT THE POINT IT
;;;     ARRIVED — `note-warning`, the `note-unreadable` shape — because a status note
;;;     expires on a TTL and takes the fact with it, while an item scrolls away with
;;;     the conversation, which is what "where it arrived" means.
;;;   · **keep it retired.** A reader can retire one, and a retired warning stays
;;;     retired across a resync and a reattach. Both of those REPLACE the transcript
;;;     from a snapshot, so a retirement stored on the row itself would be undone by
;;;     the very event the requirement names: the set is keyed by the warning's own
;;;     `(code detail ts)` identity and kept on the session, outside anything a
;;;     snapshot replaces.
;;;
;;; **The retired set is NOT cleared by a `/switch`**, and that is deliberate: it is
;;; this head's memory of what it has shown, and the reference keeps its `dismissed`
;;; the same way (`app.rs:886` is not in its `load`'s clear list, `app.rs:1902-1934`).
;;; An identity is `(code ts detail)` and `ts` is the log's clock, so two sessions
;;; colliding on one is the same warning at the same instant either way.
;;;
;;; **What is NOT here, deliberately.** `turn_failed` is filed by neither half: the
;;; turn's own terminal state already says it on the screen, the log holds it, and a
;;; second copy three lines under the first is the shape this head avoids everywhere
;;; (app.rs:3320-3330 answers `Disposition::Filtered`). `job_output_refused` answers
;;; the pane that asked AND files the row; `slash`/`slash_refused` open the listing
;;; pane when they are long enough to be one and file the row otherwise. A code with
;;; a better home keeps it; this default is for every other code, including the ones
;;; the daemon has not invented yet.

(defparameter +note-lines+ 3
  "Lines of a warning the conversation shows before it is a wall.

R10's other half, and the number is the reference's `NOTE_LINES` rather than a taste
of ours: two gate timeouts rendered 27 red lines there (*\"how to remove this red
wall?\"*), which is about thirteen lines a warning — a `denied:` detail carrying the
whole rule. Three lines keeps the code, the first sentence and the fact that there is
more, and puts the rest one verb away. `/notes` prints the whole text, so this is a
disclosure decision and NEVER a cap on the record.

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a
constant here could never be changed on a running head.")

(defun %fnv1a-64 (string)
  "FNV-1a, 64-bit, over STRING's UTF-8 BYTES — letibot's own hash, byte for byte.

**Hand-rolled for the same reason letibot's is**: `sxhash` is not stable across an SBCL
version, and a key that changes when the head is rebuilt would resurrect every note the
operator had retired, which is the defect the whole identity exists to prevent.

The offset basis and the prime are the published ones (`offset_basis =
0xcbf29ce484222325`, `prime = 0x100000001b3`), and the arithmetic is masked to 64 bits after
every multiply because SBCL has bignums and Rust wraps — an unmasked product would keep
growing and the two heads would disagree on the first string long enough to matter.

Over UTF-8 bytes because that is what `s.as_bytes()` is on the other side: a detail is a
sentence, sentences contain `→` and `—`, and hashing CHARACTERS here would give a different
key from hashing their encoding."
  (let ((h #xcbf29ce484222325))
    (loop for byte across (sb-ext:string-to-octets string :external-format :utf-8)
          do (setf h (ldb (byte 64 0) (* (logxor h byte) #x100000001b3))))
    h))

(defun %fnv1a-hex (string)
  "The 16 lowercase hex digits letibot writes in a note key (`{:016x}`)."
  (format nil "~16,'0x" (%fnv1a-64 string)))

(defun warning-identity (w)
  "The name a warning keeps across a resync, a reattach **and a restart — in a file two
heads share.**

**Built from the warning's own facts and nothing about where it is on the screen**, and it
is `w|{code}|{ts}|{fnv1a(detail)}` — **letibot's format, character for character**
(`app.rs`, `note_key`: `format!(\"w|{}|{}|{:016x}\", w.code, w.ts, fnv1a(&w.detail))`).
`ts` is the log's clock for the envelope that carried it, which is what tells one
announcement from a redelivery of the same one.

**This head used to use `code|ts|escaped-detail`, and the difference was not cosmetic.**
The retired set now lives in ONE file for every head on the box, and both heads compare
keys against that file by string equality — so two formats in one file is a file both
heads write and neither can read. The escaping machinery went with it: a hash has no comma
and no newline in it, which is what the escaping was for, and the code and clock are the
daemon's own identifiers.

**The `w|` prefix is a KIND, not decoration.** letibot writes `n|…` for a 'refusal nobody
made' note and `d|{req_id}` for a settled decision; this head files only warnings, so it
produces only `w|…` — and it KEEPS the others on the way through, because a save merges
the file and a key this head did not write is another head's dismissal. See
`merge-retired-keys`."
  (format nil "w|~a|~a|~a"
          (or (getf w :code) "") (or (getf w :ts) 0)
          (%fnv1a-hex (or (getf w :detail) ""))))

(defun session-retired-p (session w)
  "Has the reader already retired W?"
  (and (member (warning-identity w) (session-retired session) :test #'string=) t))

(defun %reflag-warning-rows (session)
  "Point every warning row at the session's retired set, after the set moved.

The row carries `:retired` so `item-lines` can answer without a session — it is
handed an item and nothing else — and the set is the truth, so the rows are derived
from it rather than the other way round."
  (loop for item across (session-items session)
        when (getf item :warning)
          do (setf (getf item :retired)
                   (and (session-retired-p session (getf item :warning)) t))))

(defparameter +weather-warnings+
  '("model_slow_first_byte" "model_endpoint_retry")
  "The ROUTINE codes that are WEATHER — noted, pointed at, and never drawn in the conversation.

**The operator's ruling, verbatim:** *\"regarding model_slow_first_byte - it is important diagnostics -
we have a yellow triangle for that. both heads should not emit it inside conversation\"*. The
diagnostic is WANTED; its PLACEMENT was wrong. So it is not deleted, not quietened, not made
conditional — it leaves the transcript, lights the `⚠` (the pointer that already means *the head is
alive and something was said — look at `/status`*), and `/notes` still lists the sentence in full,
with `warning-identity` retiring it as before. Nothing is lost but the row.

**AND IT IS A SUBSET OF `+routine-warnings+`, WHICH ALREADY EXISTED.** That list is the REGISTER
— routine is drawn faint with a middot rather than red with a bang — and this one is the PLACEMENT:
routine AND not a row. `model_slow_first_byte` has been in the register list since letibot's
`e54b48a` put it there; what it lacked was somewhere to be that was not the conversation. The
difference is the one the operator named, and the two lists must stay in that relation: a code in
this list and not in that one would be a RED warning silenced, which is why
`every-weather-code-is-a-routine-code` asserts the subset rather than trusting it.

**The rule, because it is what tells the next person which register a NEW code belongs in — and
because letibot's `Class::Routine` is not the test.** `auto_compact` and `compacted` are routine too,
and they are things the operator has repeatedly wanted to SEE. The difference is that **a compaction
changes the conversation and a slow first byte does not**: one is an event in the record, the other is
a note about the weather. An event is a row; weather is not. Widening this list to *everything
routine* would take the compactions off the screen, which is why it is a list of codes and not a
class.

**And the operator's other report of the same evening is the confirmation of the reading:** *\"leticl
has troubles with thinking lines stat after it\"* — the stat was disturbed by exactly this row landing
in the middle of a streaming turn, and once the row stopped being a row the operator's verdict was
*\"yeah i think marker is fine\"*. Recorded because it is a MEASURED confirmation and not a plausible
one: the interloper, the counts, and the fix are one sentence, and the next reader who sees a stat
move during a turn has a place to start.

**And the family is *a moment that passed*, not *provider*.** `model_endpoint_retry` is here — the
endpoint was retried and answered, nothing to do — while `prefix_check_skipped` is deliberately NOT:
D10 rules that a skipped check is *said, never counted as a pass*, so that one keeps its row. The
boundary is whether the sentence still needs saying after the moment is over.")

(defvar *weather-notes* 0
  "How many weather notes this head has kept off the conversation — the counter the `⚠` reads.

A `defvar` and not a session slot, for the reason every counter here is one: a struct change is a
restart. It is counted rather than merely suppressed so that *\"I chose not to draw this\"* stays
distinguishable from *\"nothing happened\"* — the division `/status`'s `filtered` counter keeps, and
the reason this is a pointer at a screen rather than a silence.")

(defparameter +failure-warnings+
  '("auto_compact_failed" "auto_compact_skipped" "auto_compact_no_progress"
    "context_wall" "gate" "gate_timeout" "turn_failed"
    "job_output_refused" "session_unavailable" "resume_failed"
    "reseat_refused" "reseat_unchecked" "mode_unknown" "mode_set_refused"
    "mode_unpersisted" "length_batch_refused" "length_empty_turn"
    "ledger_chain_mismatch" "row_coverage_gap" "reasoning_stall"
    "repetition_collapse" "ended_in_reasoning" "monitor_wake_not_armed"
    "fabric_refresh_failed" "flowy_not_seated" "frame_capture_failed"
    "transcript_store" "decision_corpus" "title_not_stored"
    "record_item_pairing" "orphan_body" "log_gap" "protocol_skew"
    "unreadable_frame" "slash_refused" "answer_unclaimed"
    "prefix_divergence" "prefix_check_skipped" "secret_late" "sudo"
    "absolute_path" "endpoint" "dated" "data_claim")
  "The FAILURE-register codes this head draws — the other half of the vocabulary.

**The list lived in a test until R29 needed it in the source.** `the-severity-split-is-a-table`
walked it as a literal to assert that each one stays loud; R29's rule one then needed the
SAME set to assert that each one offers a remedy, and two copies of one vocabulary is the
drift this file keeps recording (see `+routine-warnings+` above: twenty codes, one head
classifying and the other not). So the list moved here, both tests read it, and a code
added to one arm cannot miss the other.

**`a_code_from_a_daemon_this_build_has_never_met` is deliberately NOT in it.** That string
is a test's standing example of an UNKNOWN code, and an unknown code must fall through both
tables — it is the fail-safe direction, not a member.

**Every member must also have a `+note-remedies+` entry** (R29 rule one), which
`every-note-code-offers-a-remedy` asserts by walking this list and `+routine-warnings+`
together, so the two facts about a code — how loud it is, and what the reader can do — are
answered in the same place or not at all.")

(defparameter +routine-warnings+
  '("auto_compact" "compacted"
    "reseated" "frame_capture_written" "frame_capture_disabled"
    "mode_set" "mode_set_next_session_only" "mode_session_only"
    "model_endpoint_retry" "interrupt_idle" "promote_idle"
    "daemon_stopping" "resume_note" "open_note"
    "reattached" "slash"
    "imported" "import_scrap" "imported_summary"
    "steering_urgent" "cache_reuse_shortfall" "test"
    ;; **R24 part two's own report, and it came from the OTHER tree.** The guard
    ;; (`a-routine-warning-code-is-one-letibot-calls-routine`) caught this head missing it the
    ;; day letibot landed `/run`: their row reads *a sentence about something the operator
    ;; asked for that worked … the opposite of a fault*. Without the entry this head's
    ;; fail-safe drew it RED — an alarm for the door working as designed, which is R19 itself
    ;; and exactly the direction the guard exists for.
    "operator_call_ran"
    ;; **`message_idle`, from letibot `272acb2`** ("job_list shows the ACTIVE jobs by
    ;; default"): the daemon's own housekeeping when a message has been idle. Caught by
    ;; the guard, which is the guard working.
    "message_idle"
    ;; **`operator_shell_ran`** — daemon `7dca40f` ("a line that starts with ! is the
    ;; operator's own shell command"). The daemon's own housekeeping for a command the
    ;; operator typed at the `!` prompt and the daemon ran; the same class as
    ;; `operator_call_ran` — a sentence about something that worked.
    "operator_shell_ran"
    ;; **`subagents_stopped`** — from the supervision tree (daemon `fb479d8`): the
    ;; daemon stopped a session's tree and this is the receipt. A sentence about
    ;; something the operator asked for that worked.
    "subagents_stopped"
    ;; **`merge_queued`** — from the merge queue (daemon `0d870ce`): the branch is
    ;; in the queue, said to the parent that started it. A sentence about something
    ;; the operator asked for that worked.
    "merge_queued"
    ;; **`daemon_stopping_runs`** — the daemon is stopping and there are runs in
    ;; flight; a receipt for the wait. Routine because the daemon said it would
    ;; stop and did.
    "daemon_stopping_runs"
    ;; **`provider_key_saved`** — the operator saved a provider key; routine
    ;; because it is a receipt for a thing they asked for that worked.
    "provider_key_saved"
    ;; **`operator_shell_failed`** — the operator's own `!` command failed.
    ;; FAILURE because the operator needs to know.
    ;; **`operator_run_unreadable`** — a run this daemon cannot look at.
    ;; FAILURE because the inability to tell is a fact that matters.
    ;; **`prompt`** — the operator's run is asking a question (protocol 33).
    ;; FAILURE because it is a request that needs an answer.
    ;; **`prompt_late`** — an answer arrived after the question was gone.
    ;; FAILURE because something was sent that nothing was waiting for.
    ;; **`sudo`** — a sudo run was refused. FAILURE.
    ;; These four are NOT in this list (the failure register is the default for
    ;; codes not here), but they ARE in the remedies table below.
    ;; **`merge_not_queued`** — the same act's refusal, but it is a FAILURE (the
    ;; daemon's own `Class::Failure`), so it is NOT in this list: codes not here
    ;; default to the failure register, which is where the operator needs to see
    ;; it. The routine-warning guard caught this: putting it here drew a refused
    ;; queue entry in the quiet register.
    ;; **AGAIN FROM THE OTHER TREE, AND THE SAME GUARD CAUGHT IT.** letibot's `e54b48a` — *a
    ;; provider that is slow says so, instead of looking like one that is gone* — added
    ;; `model_slow_first_byte`, because DeepSeek was measured at 12.4 s to first byte on a
    ;; streaming completion while `GET /models` answered in 0.28 s. The fact is that the provider
    ;; is SLOW, which is housekeeping rather than a fault — and without this entry the fail-safe
    ;; here drew it RED, which is the direction that turns *wait a moment* into an alarm. That is
    ;; R19 itself, and the exact direction this list exists to prevent.
    "model_slow_first_byte"
    ;; **AND THE COMPACTION'S OWN TWO LINES** (letibot `f273300`). `compact_half` is `Class::Routine`
    ;; in its table: a fold that is running is housekeeping, and *"a silent wait is what a reader calls
    ;; a failure"*. Without this entry the fail-safe here drew it RED — an alarm for the minutes the
    ;; operator is already waiting through, at the moment the session is largest and the model slowest.
    "compact_half")
  "The warning codes whose fact is ROUTINE — drawn faint with a middot, not red with a bang.

**R19 part 2, and this list is now letibot's rather than mine.** Both heads render these
codes, so a register either head can decide alone is a register the two disagree about on
screen. letibot put its whole table in the crate the codes are defined in
(`crates/sessionlog/src/warning.rs`, `TABLE`), with a reason per row and a guard that
fails until every `code: …` literal in its tree has one — and its own module doc makes the
argument §11.6 makes about `JobState::word`: *the codes are the log's vocabulary … so a
split that only one head knew would have to be copied by the other and the two copies
would drift.*

**And it drifted, which is why this is a measurement rather than an agreement in
principle.** Measured 2026-09-22 by extracting letibot's `TABLE` and diffing it against
this list: **both heads called ten codes routine; four codes were classified differently;
and twenty codes one head had classified had no row in the other's list at all** — nine of
those reachable from this head, so an orderly `daemon_stopping` or a compaction's cache
note would have been drawn RED here while letibot drew it dim. Two of the four differences
were mine and were wrong for one reason worth writing down: **I classified the
`auto_compact_*` family by its PREFIX** — housekeeping the daemon does to itself — and two
of its members are housekeeping that did *not* happen (`auto_compact_skipped`,
`auto_compact_no_progress`: the session is at the wall with automatic compaction off, and
the operator has to read that). The rule is about the FACT, not the name.

The third, `model_endpoint_retry`, is letibot's: **the retry IS the handling** — the round
is taken again and the operator can watch it happen — and the failure arrives under its own
code, `turn_failed`, when the retries are spent. Red on the retry is red on a turn that is
still trying.

**The nine gaps are all letibot's too**, and every one of them drew RED here while letibot
drew it dim, for the same fact: `daemon_stopping`, `imported`, `import_scrap`,
`imported_summary`, `mode_session_only`, `mode_set_next_session_only`, `open_note`,
`cache_reuse_shortfall`, `steering_urgent`. Each satisfies the rule's *something that
worked, something you asked for, or by design* — and two are the rule's boundary case: a
*write that did not happen* because the operator asked for it not to, which reads like a
failure and is not. The tenth routine-side gap, `test`, is letibot's testing helper with no
production fact behind it.

**The fourth difference needed a refinement rather than a row, and that is why it is the
interesting one.** `frame_capture_disabled` — a frame was refused and no capture directory was
configured, so the evidence that would identify it was not kept — reads like letibot's own
*\"a caveat that a check did not happen is a failure\"*, the sentence that makes
`reseat_unchecked` and `prefix_check_skipped` failures. It is not that shape, and the clause
that separates them is now part of the rule:

> **A caveat about a check that DID NOT HAPPEN is a failure. A note that a diagnostic was
> switched off — after the check happened and its result is known — is routine.**

Measured rather than argued: `report_capture` returns early unless `capture.is_armed()`
(letibot `engine.rs:1602`), and `arm` is called from exactly three places, all of them
turn-defect paths (`:1363`, `:1386`, `:1407`) — so this warning never fires on a healthy
turn, and the *check* did happen: a frame was refused and the refusal is reported by the
turn's own code. What is absent is the RECORD, and its absence is by configuration.
**letibot's row stands and the rule gains the clause.**

A `defparameter` and not a `defconstant`: the file pusher SKIPS constants, so a constant
here could never be corrected on a running head — and a severity list is exactly the kind
of thing that gets corrected.

**`a-routine-warning-code-is-one-letibot-calls-routine` reads letibot's own table and fails
if this list moves**, which is the §11.5 shape: the copy stays, because a head must render
without the reference tree present, and the GUARD points at the source.")

(defun routine-warning-p (w)
  "Is W's fact routine — housekeeping, or the outcome of the reader's own act?

By code alone. The wire carries `code`, `detail` and `ts` and no severity
(`view.rs:306-310`), so the head is the only layer that can answer this, and it answers
it for the whole code rather than by reading the detail: a sentence-parsing severity
would be a second, silent protocol."
  (and (member (or (getf w :code) "") +routine-warnings+ :test #'string=) t))

(defun warning-glyph (w)
  "The mark a warning is written under: `!` for the failure register, `·` for routine.

**ONE definition, two surfaces** — the row in the conversation and the `/notes` listing
must not spell the same severity two ways, which is what they would do if each picked its
own mark. R19 part 2's whole point is that the register be readable at a glance, and a
listing that said `!` about a note the conversation had just drawn faint would put the
argument back where it started."
  (if (routine-warning-p w) "·" "!"))

(defun warning-note-text (w)
  "What a warning SAYS, without the register.

ONE function, because the row in the conversation and the `/notes` listing must not
describe the same warning two ways: the reference makes the same point by rendering
the listing with the transcript's own `note_lines_unfolded` (`app.rs:5860-5864`). The
row prefixes this with `!` at its own renderer; the listing prefixes it here."
  (format nil "~a — ~a" (or (getf w :code) "?") (or (getf w :detail) "")))

(defun note-warning (session w)
  "DISCLOSE W: file a row for it where it arrived. Returns the row.

A retired warning is filed too, HIDDEN. That is not laziness: `/notes restore` then
has a row to bring back instead of one to invent, and a snapshot that replants the
wall replants it retired, which is the whole point of keying the set outside the
transcript. The row is the disclosure and `session-warnings` is the record — the
same division `/status`'s `filtered` counter keeps, where *\"I chose not to show
this\"* must not look like *\"nothing happened\"*."
  (let* ((id (warning-identity w))
         (row (list :item-id (format nil "leticl-note-~d" (incf *filed-notes*))
                    :kind "note"
                    :ts (or (getf w :ts) 0)
                    :warning w
                    :retired (and (member id (session-retired session) :test #'string=) t)
                    :item (list :type "note"
                                :text (warning-note-text w)
                                :cap +note-lines+
                                :seam "/notes"))))
    (push-item session row)
    row))

