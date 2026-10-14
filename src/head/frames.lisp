;;;; frames — the head's own state: the struct, the accessors, the fold from a frame
;;;;
;;;; Split out of `head.lisp`, which was one 2243-line file; the ranges are
;;;; consecutive, so every reference kept the direction it had and the split
;;;; moved no behaviour.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------------ frames ;;;

(defun %frame-plist-p (x)
  "T when X is a decoded frame: a plist with a `:frame` key.

THE guard, in one place. `:disconnected` is a one-element list the reader pushes
to signal a dead socket, and any code that assumes `consp` means `plist` will call
`getf` on it and die in the main thread — which is a head that will not start."
  (and (consp x) (keywordp (car x)) (evenp (length x)) (getf x :frame)))

(defvar *queued-unconfirmed* nil
  "The texts in `head-queued` whose binding a SNAPSHOT could not resolve (R16).

**A third mark, and it is the requirement's own second clause.** A `queued` echo is a
claim about the daemon's queue, and the head made it on the strength of its own
transcript: *I sent this and have not seen its row*. **A snapshot replaces that
transcript**, so when one arrives the claim has lost its footing in both directions —
a prompt that HAS landed may have had its row summarised away, and a prompt that has
NOT landed looks exactly the same from here.

So an echo a snapshot cannot resolve is neither `queued` (the head can no longer
support it) nor silently dropped (which would be the opposite lie, and would lose the
one signal R2 exists to give). It is `unconfirmed`: sent, not seen, and the transcript
changed under it. It retires the ordinary way the moment its row DOES land, so the
mark is transient for a prompt that is genuinely still queued and permanent only for
one whose row is never coming.

Invariant, kept by `%resolve-queued` and `%retire-pending`: every text here is also in
`head-queued`. It is a `defvar` for the usual reason — a struct change is a restart.")

(defvar *bound-prompts* nil
  "`(ITEM-ID . TEXT)` — the queued prompt each ANNOUNCED row is drawing.

**The operator's own report is what this fixes, and letibot had it right first:** *\"you start
replying while my message still queued.\"* Their message was sent while a turn ran, so the daemon
queued it; the row was announced, and this head drew the announcement as NOTHING (`item-lines`
returns no lines for a row with no body) while the words stayed in the TAIL echo — which is drawn
BELOW the running turn. So their sentence sat under the reply that was already streaming above it.

letibot's rule, from its own comment: *the row is drawn from the words the head already holds, at
the position the transcript gave it — **above the reply it caused** — instead of being invisible
until its body catches up while the reply streams above it.* Two halves, and both are needed:

  · **bind** — the announcement says a user row exists, and this head knows which of its queued
    texts has not been claimed by one yet; the oldest unbound one is bound to that item id, and the
    row draws from it in the transcript's own place;
  · **skip** — an echo a bound row is already drawing must not be drawn a second time at the tail.

**The binding is a DRAWING and not a retirement.** The echo stays in `head-queued` until its row's
body lands (that is what `%retire-pending` is for), because the words are still this head's to show
if the row goes away — a snapshot can replace the whole vector and take the announcement with it.

A `defvar` for the usual reason, and reset by `with-replay-globals` because a replay that
inherited one would draw another session's prompt on a row that never carried it.")

(defvar *resync-asked* nil
  "T while a `resync` this head sent for a SEQ GAP has not been answered.

Set in the event arm of `%handle-frame` when a fold counts a new gap, cleared by the `resync`
arm when the snapshot lands. One outstanding ask at a time: two jumps inside one batch are one
hole, and the one snapshot fills it. A `defvar` for the usual reason — a struct change is a restart.")

(defvar *short-snapshot-asked* nil
  "The session id this head has already asked a fresh snapshot for, because the transcript it applied
 looked SHORTER than the session the daemon describes.

 Keyed by session, and ONE ask each: the two ways the check can be true are *the daemon has not
 finished sending* and *the daemon will never send it*, and from a head those look exactly alike —
 so asking again would be a loop, and asking once turns five minutes of a wrong screen into a round
 trip. A `defvar` for the usual reason.")

(defun %snapshot-looks-short-p (head)
  "Does the transcript this head now holds look SHORTER than the session the daemon describes?

 **A SNAPSHOT IS NOT ALWAYS THE WHOLE CONVERSATION.** MEASURED 2026-10-11 on the operator's own head:
 after a restart it applied a snapshot holding ONE row and `items_dropped 0` — the daemon saying *this
 row is everything* — while the daemon's own store held 184 rows for that transcript. The head sat on
 that one row for five minutes: `*resyncs*` was 0, so nothing ever asked again, and the operator's
 messages were simply gone from their screen until a manual `/resync` brought them back.

 **Both numbers are the daemon's and both are already here.** `stored-items` is the session's row
 count on the session list the `Hello` carries (`chrome/border.lisp` reads it for the picker's
 `N rows`), and `items + items_dropped` is the conversation this head holds — `items_dropped` counts
 the rows trimmed off the FRONT of the daemon's window (`session/fetch.lisp`), so the two together
 are its length and cannot honestly be less than the count the daemon just gave. Measured on a
 HEALTHY head: 379 held + 1152 dropped against a `stored-items` of 360 — the check does not fire,
 which is why this is a comparison and not a threshold."
  (let* ((s (head-session head))
         (row (find (session-session-id s) (session-sessions s)
                    :key (lambda (b) (getf b :session-id)) :test #'string=)))
    (let ((stored (and row (getf row :stored-items))))
      (and (integerp stored) (plusp stored)
           (< (+ (length (session-items s)) (or (session-items-dropped s) 0)) stored)))))

(defun %ask-if-short-snapshot (head)
  "Ask once for a fresh snapshot when the transcript just applied is shorter than the session the
 daemon describes. Returns T when a `Resync` frame went out. See `%snapshot-looks-short-p`.

 **It rides `*resync-asked*` as well**, the flag the seq-gap path uses: one outstanding ask at a
 time, and the `resync` arm clears it when the answer lands — so a snapshot that arrives and is STILL
 short is not re-asked, because `*short-snapshot-asked*` remembers the session."
  (let ((id (session-session-id (head-session head))))
    (unless (equal id *short-snapshot-asked*)
      (when (and (not *resync-asked*) (%snapshot-looks-short-p head))
        (setf *short-snapshot-asked* id
              *resync-asked* t)
        (%send head (make-resync))
        t))))

(defun %echo-leftover (queued bound)
  "Each queued ENTRY minus the pieces an announced row already draws — oldest first, one block each.

**THE DEFECT THIS ENDS, and it needs the two steps to be visible at all:**

  1. the operator sends A behind a running turn. A is queued, `%bind-echo` gives A's announced row the
     text `\"A\"` — correctly, that is the whole entry;
  2. the operator sends B. `%queue-prompt` COALESCES it onto the entry — `\"A\\nB\"` — because the daemon
     will commit the two as ONE row, which is the operator's own ruling (*\"the queued messages must be
     still coalesced and still pinned to the bottom\"*).

Now the binding says `\"A\"` and the queue says `\"A\\nB\"`, and the tail's filter asked whether the ENTRY
was in the bound set. It was not — so the tail drew the whole coalesced block while row 1 went on
drawing `\"A\"`, and A was on the screen **twice**, under a second message that had A as its first line.
The operator, twice: *\"queue problem - items queued twice, at least usually - visually\"*, then *\"that
second message with 'unellow' was presented with 'still...' as a first line\"*.

**The entry stays ONE block, which is the half that must not be lost.** An earlier attempt at this fix
drew each unclaimed PIECE as its own queued row and broke the coalescing the operator asked for — one
message arriving as two rows. So the unit of DISPLAY is the entry and the unit of CLAIMING is the
piece, and this function is where those two meet: a piece a row draws is dropped, and what is left of
the entry is joined back up and drawn once.

Blank pieces are dropped for `%strip-landed`'s reason: a trailing newline would otherwise be handed on
as a piece that can never be drawn or claimed."
  (let ((taken (remove-if (lambda (p) (zerop (length p))) bound)))
    (loop for entry in (reverse queued)          ; oldest first: the order rows are announced
          for keep = (remove-if (lambda (piece)
                                  (or (zerop (length piece))
                                      (member piece taken :test #'equal)))
                                (uiop:split-string entry :separator '(#\newline)))
          when keep collect (format nil "~{~a~^~%~}" keep))))

(defun %bind-echo (head item-id)
  "Bind the OLDEST queued prompt no announced row has claimed to ITEM-ID.

**Oldest first, because that is the order their rows are announced in** — several prompts in the
air at once is ordinary behind a running turn, and pairing the newest with the first announcement
would swap two sentences on the screen. A text already bound is skipped, so two announcements
take two different prompts.

An echo the head cannot resolve (`*queued-unconfirmed*`) is the same kind of thing and is bound
the same way: the row is on the screen and the words are what it draws."
  (let ((taken (mapcar #'cdr *bound-prompts*)))
    ;; **AND IT WILL NOT CLAIM AN ENTRY ONE OF WHOSE PIECES IS ALREADY CLAIMED.** The bound text is
    ;; the WHOLE entry — a coalesced pair is one row's worth of words when the daemon merges them, and
    ;; drawing it as one block is the operator's own ruling (*"the queued messages must be still
    ;; coalesced"*). But the entry GROWS: bound when it was `"A"`, it becomes `"A\nB\nC"` when two
    ;; more prompts coalesce onto it — and the old test asked whether the ENTRY was in the taken list.
    ;; It was not, so a LATER announcement claimed the grown entry as well, and the screen drew the
    ;; message twice: the first row with the one line it claimed, the second with the whole thing.
    ;;
    ;; **This is the operator's screen, measured rather than guessed** — one message, two `queued`
    ;; rows, the second carrying `… +2 lines` the first did not:
    ;;
    ;;     ▌ queued · <the message>
    ;;     ▌ queued · <the same message>  … +2 lines · /t opens it
    ;;
    ;; The unit of CLAIMING is the piece and the unit of DRAWING is the entry, so the question here
    ;; is piecewise: one announcement claims an entry that no other announcement has a piece of.
    (let ((text (find-if (lambda (q)
                           (let ((pieces (remove-if (lambda (p) (zerop (length p)))
                                                    (uiop:split-string q :separator '(#\newline)))))
                             (and pieces
                                  (notany (lambda (p) (member p taken :test #'equal)) pieces))))
                         ;; oldest first: the order their rows are announced in
                         (reverse (head-queued head)))))
      (when (and item-id text)
        (setf *bound-prompts* (acons item-id text *bound-prompts*))
        (setf (head-dirty head) t)
        t))))

(defun %unbind-echo (item-id)
  "Forget ITEM-ID's bound prompt — its body has arrived and the row draws its own words now."
  (when item-id
    (setf *bound-prompts* (remove item-id *bound-prompts* :key #'car :test #'equal))))

(defun bound-prompt-for (item)
  "The text this ANNOUNCED row is drawing, or NIL.

Read by `item-lines` — which is handed an item and nothing else — so the binding is a global, the
same arrangement `*payload-head*` and `*hidden-run-open*` have and for the same reason."
  (cdr (assoc (getf item :item-id) *bound-prompts* :test #'equal)))

;;; **`%piece-of` USED TO LIVE HERE**, and it was deleted when `%strip-landed` subsumed it. It asked
;;; whether the LANDING ROW contained a queued text as a whole piece, and its docstring carried the
;;; measurement that put it there — **28 echoes still on the screen two hours after their rows
;;; landed**, the oldest from 15:39, where one row's part text was 1,741 characters over 5 lines and
;;; all five lines were queued texts exactly. The equality rule retired 0 of 28 and that rule retired
;;; 28 of 28.
;;;
;;; **The piece-wise walk retires the same 28 and the mirror case besides**, which is why the
;;; function has no second caller to keep: splitting the queued entry at its own newlines and
;;; matching each piece against the row's lines is the same rule stated whole. A piece is bounded by
;;; newlines because the entries ARE newline-separated, so `second` can still never be retired by a
;;; row reading `first\\nsecond-guess` — the boundary is now the split rather than a character test.
;;;
(defun %strip-landed (entry lines claimed cursor)
  "ENTRY against the LINES a landing row holds — as letibot's `strip_landed` does it.

Returns `(values REST HIT CURSOR)`. REST is the words still owed, HIT says whether any piece
landed at all, and CURSOR is where the next entry's search should start.

**PIECE-WISE, and that is the correction.** The old rule asked whether the LANDING ROW contained
the whole queued text (`%piece-of`) and, failing that, whether the queued text began with the row.
Both are about ONE side of the mirror:

  · a row that is `a\\nb` retires the separate echoes `a` and `b` — the daemon merged them;
  · but the daemon does NOT always merge, and a head that joined `a\\nb\\nc` into one entry then
    needs the reverse: a row that is just `b` retires that PIECE of it and leaves the rest owed.

The operator found the second half on their own screen: three messages were typed, two landed as
their own rows, and the joined entry matched neither — so it stayed queued for ever, showing
*\"i still see queued messages\"*. letibot's answer is this walk, and it is exact:

  · split the entry at its newlines, and claim each piece that an UNCLAIMED line of the row equals;
  · **a line is spent once** (`CLAIMED`) and the search runs forward from `CURSOR`, so two prompts
    that say the same thing retire separately and in the order they were sent;
  · what is left is the words still owed — empty means the echo stands down whole.

**A blank piece is not a claim and is not content.** It matches nothing (so it can never be
claimed) and it is dropped from REST: an entry whose only remaining pieces are blank has had every
word accounted for, and keeping the newlines would hand the caller a string that is truthy and
empty — an echo left on the screen for the rest of the session showing nothing."
  (let ((pieces (uiop:split-string entry :separator '(#\newline)))
        (kept nil) (hit nil) (cur cursor))
    (dolist (piece pieces)
      (when (plusp (length piece))
        (let ((at (loop for k from cur below (length lines)
                        when (and (not (aref claimed k))
                                  (string= (elt lines k) piece))
                          return k)))
          (if at
              (setf (aref claimed at) t
                    cur (1+ at)
                    hit t)
              (push piece kept)))))
    (values (format nil "~{~a~^~%~}" (nreverse kept)) hit cur)))

(defun %resolve-queued (queued rows)
  "QUEUED (newest-first texts) resolved against ROWS (landing user texts).

Returns `(values KEPT UNCONFIRMED)`.

**The ONE place the rule lives**, so a row arriving on the socket and a transcript
arriving in a snapshot cannot retire different things. Each landing row is applied to every
entry in turn — oldest entry first, because the row that lands first is the prompt that was
sent first — and `%strip-landed` is the whole of what *retires* means.

**A row neither CONFIRMS nor DENIES what it does not name.** An entry whose pieces did not
match keeps its place untouched, which is why a row for a later message cannot retire an
earlier one that has not landed yet."
  (let ((entries (reverse queued))       ; OLDEST first — the order rows land in
        (unconfirmed nil))
    (dolist (row rows)
      (let* ((lines (uiop:split-string row :separator '(#\newline)))
             ;; **A line is spent once**, and the set is per-ROW: two entries that say the same
             ;; thing retire separately, in the order they were sent.
             (claimed (make-array (length lines) :initial-element nil))
             (cursor 0)
             (next nil))
        (dolist (entry entries)
          (multiple-value-bind (rest hit cur) (%strip-landed entry lines claimed cursor)
            (setf cursor cur)
            (cond ((not hit) (push entry next))              ; nothing of it is in this row
                  ((zerop (length rest)) nil)               ; every piece landed: stands down
                  (t (push rest next)))))                   ; some did: the echo shrinks
        (setf entries (nreverse next))))
    (let ((kept (nreverse entries)))     ; back to NEWEST-first, the caller's order
      (dolist (text kept) (push text unconfirmed))
      (values kept (nreverse unconfirmed)))))

(defun %retire-pending (head text)
  "Stand down the echo of the queued prompt whose row has landed, by TEXT.

The transcript takes the words over by BEING them, so the match is on the TEXT and not
on an id — but **it is no longer equality, because the row is not one prompt**: the
daemon merges consecutive queued prompts into one item joined by newlines, so ONE row
stands down every echo it holds. That is `%piece-of`, and the coalescing and the
oldest-first walk are in `%resolve-queued`, which the snapshot path shares.

Nothing is left UNCONFIRMED by a live row: a row that arrived is proof for the prompt
it names, and silence about the others. So the unconfirmed set only ever shrinks here.

**AND IT MUST SHRINK TO A SUBSET OF THE QUEUE, which the first version did not.** It
removed the ROW's text from the unconfirmed set, and a merged row's text is not any
queued text — so an echo marked unconfirmed by an earlier snapshot, whose row then
landed inside a merged item, was retired from the queue and **left in the unconfirmed
set for ever**. The invariant is the intersection with what is still queued, which is
the same statement as the global's docstring." 
  (let ((before (head-queued head)))
    (multiple-value-bind (kept) (%resolve-queued before (list text))
      ;; **THE LIST, not its length.** The coalesced case replaces `a\nb` with `b` —
      ;; one entry either way — so a length check calls that no change and leaves the
      ;; whole echo on the screen, which is the coalescing branch of this very test.
      (unless (equal kept before)
        (setf *queued-unconfirmed*
              (intersection *queued-unconfirmed* kept :test #'equal))
        (setf (head-queued head) kept
              (head-dirty head) t)))))

(defun %re-resolve-queued (head items)
  "Re-resolve every queued echo against a transcript that has just been REPLACED.

**R16, and this head FAILED it.** MEASURED with the instruction the requirement itself
gives — queue a prompt, force a compaction under it:

    queued before the compaction                        (\"third thing\" \"second\" \"first\")
    the snapshot LANDED (seq / items held)              (900 4)
    the user rows the echoes are waiting for            (\"first thing\" \"second thing\" \"third thing\")
    queued AFTER the compaction                         (\"third thing\" \"second\" \"first\")

All three prompts were in the transcript the snapshot carried, and all three echoes
still read `queued`. `%retire-pending` is reached from ONE place — the live
`transcript_content` arm — and a snapshot does not go through it, so **a row that
arrives inside a snapshot retires nothing**, forever, and the mark R2 exists to make
trustworthy becomes furniture.

Called after every snapshot lands, from both frames that carry one (the `resync` frame
and a `hello` with a snapshot). Returns T when the queue moved."
  (let* ((rows (loop for i in (coerce items 'list)
                     when (equal (getf (getf i :item) :type) "user")
                       append (loop for p in (getf (getf i :item) :parts)
                                    when (getf p :text) collect (getf p :text))))
         (had (head-queued head)))
    (when had
      (multiple-value-bind (kept unconfirmed) (%resolve-queued had rows)
        (setf (head-queued head) kept
              *queued-unconfirmed* unconfirmed)
        (unless (equal kept had)
          (setf (head-dirty head) t))
        t))))

;;;
;;; `%handle-frame` returns a DISPOSITION, which is what the ack counts
;;; (driver.rs:31 classifies each frame the same three ways):
;;;
;;;   :rendered  something visible changed
;;;   :filtered  consumed, nothing to draw (a head at terse renders little and
;;;              must still advance, or it rereads its own output forever)
;;;   :control   not session content: hello, ack-of-our-own, settings, bye
;;;
;;; The ack itself is sent by the loop, after painting, from the last seq READ
;;; — never from this function, which does not know whether the frame went out.
(defvar *pending-resume* nil
  "The session id `--resume ID` asked for, held until a Hello brings the daemon's list.

**It cannot ride the ATTACH.** `--session ID` puts the id on `make-attach`, which is right for a
session the daemon already holds and wrong for one on disk: the daemon has never opened it, and the
attach is refused by name. The reference draws the same line (`app.rs:1602-1610`) and its answer is
that `--resume` is a different act from `--session`, so this head asks for it the way the PICKER
does once the list has arrived — see the `hello` arm, which is the only reader.

A global rather than a head slot because the launcher's flag is per PROCESS: `run` creates one head
and the flag is consumed by the first Hello it sees.")

(defun %frame-for-another-session-p (head frame)
  "Is FRAME a reply about a session that is not the one this head is on?

**Two arms ask this and they ask it for the same reason** (T6 in `TODO.md`): a `Jobs` or `Todos`
reply is answered to a request that may have been made before a `/switch`, and the daemon's reply
names the session it is about. Applying it unconditionally puts one conversation's rows on another's
screen — invisible, because a job list looks the same whoever it belongs to.

**Empty on either side is NOT another session.** A daemon older than the field, and a head that has
not attached yet, both mean *this head cannot tell* — and a guard that refused then would draw an
empty pane on every attach, which is the defect the guard exists to prevent, inverted."
  (let ((mine (session-session-id (head-session head)))
        (theirs (getf frame :session-id)))
    (and (plusp (length (or mine "")))
         (plusp (length (or theirs "")))
         (not (equal mine theirs)))))

(defun %term-frame-is-mine-p (frame)
  "Is FRAME about the pane this head is DRAWING?

 **A 44 daemon fans every pane's output out to EVERY head of the session** (`TermOutput { pane,
 bytes }`, and `TermEnded { pane, reason }` with it), so a head that fed them all would mix two
 programs' bytes into one screen — the second pane's redraw landing on the first's, which looks
 exactly like a terminal going mad. The frame's own `pane` is the test, and a head draws ONE pane at
 a time: `!term N` changes which, and `*term-pane*` follows the `TermAttached` that answers it.

 **A frame without a `pane` is this head's**, which is the 43 daemon's whole vocabulary: that
 session held one pane by construction, and a REFUSAL carries `pane: null` (`TermEnded` for a pane
 that never started) and must still reach the head that asked, or a failed `!term` would sit silent."
  (let ((pane (getf frame :pane)))
    (or (null pane) (eql pane *term-pane*))))

(defun %term-status-command (panes has-panes command)
  "What a `TermStatus` answer says, as one string — **a LIST of panes since 44**, a bare command before.

 A 44 daemon answers with every pane the session holds (`{panes: [{pane, command}]}`), and a head
 that read only the old `command` would say *nothing is running* over a session with three programs
 in it. One pane keeps the old sentence; SEVERAL are named with their numbers, because a head drawing
 one of them must not let the others go unsaid.

 **`panes` ABSENT AND `panes` EMPTY ARE NOT THE SAME FACT, and `listp` cannot tell them apart** —
 it is true of `nil`, so a head that tested `(listp panes)` reads a 43 daemon's bare `command` as *no
 panes* and says nothing is running over a program that is. Hence HAS-PANES, which is whether the key
 is there at all: the field's presence is the disclosure, the same rule `dropped` and `created` are
 written under."
  (cond (has-panes
         (cond ((null panes) nil)
               ((null (cdr panes)) (getf (first panes) :command))
               (t (format nil "~{~a~^, ~}"
                          (mapcar (lambda (p) (format nil "#~d ~a" (getf p :pane) (getf p :command)))
                                  panes)))))
        ((stringp command) command)
        (t nil)))

(defun %handle-frame (head frame)
  (cond
    ((and (consp frame) (eq (car frame) :disconnected))
     ;; **A STALE READER'S GOODBYE IS NOT THIS CONNECTION'S.** The marker names the stream its
     ;; reader was on. After a reconnect the OLD reader is still unwinding — `%try-reconnect`
     ;; closed its stream, and it posts `(:disconnected)` for that — while `head-stream` is
     ;; already the new socket; taking that marker flipped the new connection to "detached" and
     ;; cost a second reconnect two seconds later, every time. A marker with no stream (a
     ;; fixture, a test) is about the current one.
     (when (and (second frame) (not (eq (second frame) (head-stream head))))
       (return-from %handle-frame :control))
     (setf (head-connected head) nil)
     ;; **the socket took two outstanding asks with it**: the resync this head sent for a gap
     ;; will never be answered on a dead connection, and left set it disabled automatic resync
     ;; for the rest of the process; a row fetch in flight the same. The reattach carries
     ;; `since-seq`, so the gap is re-measured on the new connection if it is still there.
     (setf *resync-asked* nil
           *row-fetch* nil)
     (say head "detached — reconnecting…")
     ;; **A DAEMON OLDER THAN `read_job_output` DROPS THE SOCKET, and this is the
     ;; only place that can say so.**
     ;;
     ;; `ClientFrame` is an internally-tagged serde enum, so an unknown `frame`
     ;; value does not fail one frame — it fails the DESERIALIZER, which ends the
     ;; daemon's read loop and closes the connection. This head has already been
     ;; bitten by that exact class: `consented: null` on `/mode NAME` broke the
     ;; read loop the same way, and the whole symptom was a head that went quiet
     ;; (tests: `a-boolean-field-goes-out-as-a-boolean`).
     ;;
     ;; There is deliberately NO version negotiation invented here — the server
     ;; side landed without a `PROTOCOL_VERSION` bump, so the version cannot tell
     ;; us and a handshake this head made up would be a second, private protocol.
     ;; What is chosen instead is HONESTY: the reconnect path below already brings
     ;; the head back, and the one thing it could not do was say why it went. A
     ;; read that was in flight when the socket died is named — by frame, and with
     ;; the verb that still works on an old daemon — in the overlay that asked and
     ;; on the status line, so the operator is never left with a pane at `reading…`
     ;; and a head that looks merely slow.
     (when (and *job-out* (getf *job-out* :loading))
       (setf (getf *job-out* :loading) nil
             (getf *job-out* :error)
             (format nil "the daemon closed the connection on `read_job_output`.~2%~
                          That frame is newer than this daemon: an unknown frame ~
                          fails serde's whole read loop rather than one message, ~
                          so the socket goes with it. Reconnecting — until the ~
                          daemon is updated, `/job ~a` in the composer still ~
                          reads this job, into the conversation."
                     (getf *job-out* :job)))
       (say head
            "read_job_output: the daemon closed the connection — it is older than this frame; reconnecting"))
     :control)
    ((and (consp frame) (eq (car frame) :unreadable))
     ;; **A FRAME THIS HEAD CANNOT READ: said, counted, survived.** The marker is
     ;; head-internal — the reader loop makes one for a line that will not decode —
     ;; and the two unknown-tag arms below reach the same function directly. It is
     ;; NOT a status note and NOT `:filtered`: nothing was parsed, so there is no seq
     ;; to ack, and `filtered` is "events I chose not to show", which the daemon reads
     ;; back. See `note-unreadable`.
     (note-unreadable (head-session head)
                      (or (getf frame :detail) "no detail")
                      (getf frame :line))
     (setf (head-dirty head) t)
     :control)
    ((and (consp frame) (string= (frame-name frame) "warning")
          (getf frame :code) (member (getf frame :code)
                                     '("read-error")
                                     :test #'string=))
     ;; our own transport warnings, not session events. **`malformed-frame` is no
     ;; longer one of them**: a line that would not decode is a frame this head could
     ;; not read, and it goes through `note-unreadable` with the rest.
     (say head (format nil "~a: ~a" (getf frame :code) (getf frame :detail)))
     :control)
    ((string= (frame-name frame) "hello")
     ;; **THE VERSION, BEFORE ANYTHING ELSE — AND THE HEAD STAYS.**
     ;;
     ;; A daemon that speaks a different protocol refuses with a `Bye` and no `Hello`
     ;; (server.rs:332-342), so a skew normally arrives the other way round — but this
     ;; check is the head's OWN, and it is not redundant, because **the two halves are
     ;; built and run separately**: a check is a thing a protocol GAINS at some
     ;; version, so a daemon older than the check has none, and a check is a candidate
     ;; for being relaxed — which is the direction `R3` itself argues for.
     ;;
     ;; **It used to EXIT**, with the sentence on a status note: `head-running` nil on
     ;; a version the daemon had merely disagreed about, which took the session with it
     ;; and said so in a place that expires. That is the failure framing the fix, on
     ;; the same argument `note-unreadable` is built on — a head that quits at the
     ;; handshake never gets to use the survival the rest of the protocol is for, and
     ;; the operator loses the conversation over a number.
     ;;
     ;; The sentence NAMES THE DIRECTION and the two directions are different
     ;; problems: a NEWER daemon is a reading problem (`R3`: the frames the two share
     ;; read fine, the first one they do not is reported and skipped), and an OLDER
     ;; daemon is a WRITING problem this head cannot survive from its side, because a
     ;; `ClientFrame` it has never heard of fails ITS deserialiser and its read loop
     ;; answers by closing the socket — silent until fatal, which is the case the
     ;; operator is entitled to know about before they spend an hour in it.
     ;; `protocol-skew-said` is the one place that sentence is built, beside the
     ;; number it is about, so every head says it the same way.
     (let* ((theirs (getf frame :protocol-version))
            (said (protocol-skew-said theirs +protocol-version+)))
       (setf *daemon-protocol* (and (integerp theirs) theirs))
       ;; held until the snapshot is folded in: `ingest-snapshot` replaces the
       ;; session's items wholesale, so a row filed before it is not "anchored at
       ;; the frame that revealed this", it is thrown away. Found by the test that
       ;; asserts the sentence exists, which is the only reason this is not a
       ;; silence nobody would have noticed.
       (setf *skew-said-pending* said))
     ;; **AND WHICH DAEMON THAT IS — the seating, checked where a seating happens.**
     ;;
     ;; A head outlives the daemon that gave it its facts (the operator's box has had
     ;; three `letibot-tui` processes up for days while the daemon was replaced under
     ;; them), and the daemon's registry is in memory — so the party at the other end
     ;; of this socket has to be checked rather than assumed. The pid is `SO_PEERCRED`
     ;; off the live stream (`daemon-pid`, measured against this box's own `harnessd`),
     ;; and the protocol rides this frame; a PAIR, because the kernel reuses pids and a
     ;; rebuild that moved the wire is the case a head most needs to be told about.
     ;;
     ;; **The check is on the SEATING, which is where it belongs**: a `Hello` is an
     ;; attach, a re-attach and the return from a switch, and a switch is answered on
     ;; the same socket by the same process — so this fires once per connection that
     ;; lands somewhere new, not once per keystroke. Held like the skew sentence: the
     ;; refetch the sentence promises is the one this arm already does (the plan
     ;; re-pushed, the settings re-asked, the session list in this frame, the children
     ;; in its snapshot).
     (let ((seat (cons (daemon-pid (head-stream head))
                       (and (integerp (getf frame :protocol-version))
                            (getf frame :protocol-version)))))
       (setf *seat-said-pending* (daemon-replaced-said *daemon-seat* seat)
             *daemon-seat* seat))
     ;; A Switch lands as a Hello on the new session, and the money meter is the
     ;; CONVERSATION's — carrying one session's bill onto another's header is
     ;; wrong in the direction that costs money. Cleared, not guessed.
     (reset-spent)
     ;; **THE WAIT IS OVER — UNLESS THE HEAD ASKED FOR A DIFFERENT SESSION** (letibot `ef31893`).
     ;; This Hello attaches whatever session the daemon is on, and `--resume` then asks for another one
     ;; through the pending check below. Clearing the cat HERE spent the whole restore showing *has said
     ;; nothing yet* over a session the head had not been asked about yet — the placeholder standing in
     ;; for a conversation nobody had claimed.
     ;;
     ;; The asked-for id is still live at this point (the pending check consumes it twenty lines down),
     ;; so this needs no second piece of state: a Hello for the ASKED session clears the cat as it always
     ;; did, one for any other leaves it standing until `%switch-to` brings the asked one in.
     (unless (and *pending-resume*
                  (plusp (length *pending-resume*))
                  (not (equal *pending-resume* (session-session-id (head-session head)))))
       (setf *attach-started-ms* nil))
     ;; THE HEAD'S OWN session-scoped state goes with the session, the way
     ;; `ingest-snapshot` drops the session's (app.rs:1902-1934). These four are
     ;; not in any snapshot and nothing cleared them, so a `/switch` carried the
     ;; old session's job rows, its peeked scrollback and the echo of prompts
     ;; queued in a conversation that is no longer on the screen.
     (let ((moved (and (plusp (length (session-session-id (head-session head))))
                       (not (equal (session-session-id (head-session head))
                                   (getf frame :session-id))))))
       (when moved
         (setf (head-jobs head) nil
               (head-peeked head) nil
               (head-queued head) nil
               *queued-unconfirmed* nil
               ;; the third leg of the echo: a row id from the old session must not draw a
               ;; prompt in the new one
               *bound-prompts* nil
               ;; **the rows-above facts are the OLD transcript's.** `*rows-above-unserved*` is
               ;; the daemon saying THAT transcript's top is out of reach; carried across a switch
               ;; it stopped the new session from ever asking for its own rows. A fetch in flight
               ;; is an answer that will name a row this head no longer holds.
               *row-fetch* nil
               *rows-above-unserved* nil
               (head-picker-sel head) 0)
         ;; and the overlays, for the reason the job ROWS are cleared: a window
         ;; belongs to the session that produced it, so a `j12` carried across a
         ;; switch is a question about a job that was never here — and a slash
         ;; listing carried across one is another session's `/tools` on this
         ;; screen, which is worse, because it looks like an answer to something
         ;; nobody asked here.
         (shut-overlays)
         (when (member (head-mode head) '(:job-out :slash))
           (setf (head-mode head) :normal))))
     (ingest-hello (head-session head) frame)
      ;; **THE SNAPSHOT IS CHECKED BEFORE ANYTHING IS SAID ABOUT IT** — see
      ;; `%ask-if-short-snapshot`: a snapshot that is not the whole conversation is the one failure
      ;; that looks exactly like an empty session, and nothing else in this head would notice it.
      (%ask-if-short-snapshot head)
    ;; **AND THE QUEUES ARE ASKED FOR AT SEATING** (letibot `031239d`, R92.5). The head's only ask for
    ;; the queues' snapshot was OPENING THE PANE, plus a `QueueMoved` seen while it was open — so a head
    ;; that had never opened `/queue` drew NO standing on its composer edge at all, and one that had
    ;; opened it once kept that snapshot for ever (`‼ 1 red target(s)` long after main was green).
    ;; Seating is where a head learns what it is attached to, so it is where it asks what that
    ;; repository's queue is doing. A re-attach and a switch come through this same arm.
    (when (head-connected head)
      (ask-queues head))
     ;; **`--resume ID`, AT THE MOMENT THE LIST EXISTS** (T4 in `TODO.md`). A session the daemon does
     ;; not hold cannot be attached to BY ID: `--session ID` puts the id on the ATTACH, and the daemon
     ;; refuses a session it has never opened (`app.rs:1602-1610` is the reference's own note on why
     ;; its `--resume` is a different act). So the flag attaches to whatever the daemon is on and then
     ;; asks for that session the way the PICKER does — `%switch-to` reads the list this Hello just
     ;; delivered and sends `switch` for a live row or `resume_session` for one on disk. ONE path, so
     ;; the CLI and the picker cannot disagree about which frame brings a session in.
     (when (and *pending-resume* (plusp (length *pending-resume*)))
       (let ((id *pending-resume*))
         (setf *pending-resume* nil)
         (unless (equal id (session-session-id (head-session head)))
           (%switch-to head id))))
     ;; the same, for the other frame a snapshot arrives on: a HELLO after a
     ;; reattach. (A SWITCH's snapshot is a different session's, and the `moved` check
     ;; above has already cleared the echoes rather than resolving them — a prompt
     ;; queued in another conversation is not this one's to confirm.)
     (%re-resolve-queued head (getf (getf frame :snapshot) :items))
     (progn
       (setf (head-connected head) t
             (head-full-repaint head) t
             (head-dirty head) t)
       ;; **THE OPERATOR'S TODOS GO TO THE DAEMON'S BOARD HERE, and here is the only place that can.**
       ;;
       ;; `load-operator-todos` runs in `run`, BEFORE the socket is marked connected — MEASURED:
       ;; `load-prefs-into` is called at `head.lisp:1670` and `(head-connected head) t` at `:1678`, so
       ;; a push from the loader hit `%send`'s disconnected guard and sent NOTHING. The list was read,
       ;; the store was right, and the board stayed empty — which would have looked exactly like the
       ;; feature not working, on a head whose todo pane was showing the rows.
       ;;
       ;; A HELLO is the moment the session is known and the socket is live, and it is also the
       ;; moment a SWITCH lands — so this covers attach and switch with one send, the same rule the
       ;; comments below give for the settings request.
       ;;
       ;; **AND IT RELOADS FIRST, because todos are PER PROJECT** (the operator's ruling: *"todos must
       ;; be perproject"*). `run` loaded them before the daemon had said where it is seated, so the
       ;; list in hand at this moment belongs to whatever workspace was known then — nothing. Reading
       ;; it again here is what makes attach correct AND makes a switch correct: the HELLO that lands
       ;; on a different project replaces the rows with that project's.
       ;;
       ;; Without the reload the push below would send the PREVIOUS project's rows to the new
       ;; project's board, which is the leak the operator found (a leticl row on rano's board) with
       ;; the sign flipped — now it would be rano's rows on leticl's, and it would happen on every
       ;; switch rather than once.
       (let ((note (load-operator-todos (operator-todos-workspace head))))
         (when note (say head note)))
       (push-operator-todos head)
       (clear-note head))
     ;; A `Switch` lands as a Hello on the new session, so asking here covers
     ;; attach AND switch with one send (§7.4). Without it the header keeps the
     ;; old session's model, and the rows a picker would read are another
     ;; session's.
     (%send head (make-settings))
     ;; **Now it can be said.** A row in the conversation, not a status note: the
     ;; fact is about the connection and outlives the next keystroke, and a note
     ;; that expires would make a version skew disappear silently — the same
     ;; argument `note-unreadable` is built on. Said ONCE per distinct sentence,
     ;; because a `Switch` lands as a second `Hello` on the same connection and
     ;; three Hellos must not be three identical rows (the reference dedupes its
     ;; notes on `(code, detail, ts)` for exactly this).
     (when (and *skew-said-pending*
                (not (equal *skew-said-pending* *skew-last-said*)))
       (note-protocol-skew (head-session head) *skew-said-pending*)
       (setf *skew-last-said* *skew-said-pending*
             (head-dirty head) t))
     (setf *skew-said-pending* nil)
     ;; **AND THE SEAT'S, filed beside the skew's and for the same reasons** — held
     ;; until the snapshot was folded, deduped so the same change is not filed twice,
     ;; and a ROW rather than a note because the fact is about the connection and
     ;; outlives the next keystroke: a silent stale picture is exactly what
     ;; `note-unreadable` exists to prevent, and a replacement daemon under a picture
     ;; nobody refreshes is the biggest one there is.
     (when (and *seat-said-pending*
                (not (equal *seat-said-pending* *seat-last-said*)))
       (file-head-note (head-session head) *seat-said-pending*)
       (setf *seat-last-said* *seat-said-pending*
             (head-dirty head) t))
     (setf *seat-said-pending* nil)
     :control)
    ((string= (frame-name frame) "event")
     (let* ((env frame)
            (name (event-name env)))
       ;; the two events a head answers rather than renders
       (case name
         ((:screen-requested)
          ;; QUEUED, NOT ANSWERED HERE. The answer is the rows this head draws,
          ;; and they do not exist until the frame is built: answering from
          ;; `head-last-rows` during the drain sends the PREVIOUS frame, which
          ;; is a lie about the one frame in the system whose whole point is
          ;; what the operator is looking at right now. At 30 ms a tick that is
          ;; usually harmless and at a resize or a pane change it is wrong. The
          ;; loop answers after the paint, with what it put on the terminal
          ;; (driver.rs:93-99, app.rs:2723-2732).
          (push (getf env :req-id) (head-screen-reqs head))
          (setf (head-dirty head) t))
         ((:secret-requested)
          ;; the deadline is converted ON ARRIVAL, like the gate's: the wire's
          ;; `deadline` is a Unix instant and this head's clock is not one
          (setf (head-secret-req head)
                (list* :deadline (wire-deadline->monotonic (getf env :deadline)) env)
                (head-secret-buf head) ""
                (head-dirty head) t))
         ;; **A RUN OF THE OPERATOR'S OWN IS WAITING FOR AN ANSWER** (protocol 33).
         ;; The daemon reads /proc/<pid>/fd/0 against the write end's inode and /proc/<pid>/task/*/wchan
         ;; for a pipe read — THAT is what raises this, not a text match on "Continue?" (which is
         ;; per-program, per-locale, per-version and fails silently on the next program).
         ;;
         ;; Stored like the secret ask but drawn DIFFERENTLY: the field is not masked,
         ;; the card is in the open, and the answer goes back as `PromptAnswer` (a line,
         ;; never a password — those have their own path through `SecretRequested`).
         ((:prompt-requested)
          ;; **A NEW REQUEST BRINGS THE CARD BACK** — the daemon re-offers an unreadable
          ;; run once per run (`apt` asks more than one question), and a re-offer must
          ;; not arrive onto an away-state from the last one.
          (setf (head-prompt-req head) env
                *prompt-away* nil
                (head-dirty head) t))
         ;; **AND ITS SETTLEMENT CLOSES THE CARD.** `sent` says whether a line reached the
         ;; run; `by` is a person's identity or a sentence (the run ended with the card up,
         ;; or the send failed — two facts told apart by who). The record stays; the card
         ;; does not. Like the secret settlement, only OUR ask is dismissed.
         ((:prompt-settled)
          (when (and (head-prompt-req head)
                     (equal (getf (head-prompt-req head) :req-id)
                            (getf env :req-id)))
            (setf (head-prompt-req head) nil
                  *prompt-away* nil
                  (head-dirty head) t)
            (say head (if (getf env :sent)
                          (format nil "answer sent by ~a" (getf env :by))
                          (format nil "no answer sent (~a)" (getf env :by))))))
         ((:secret-settled)
          ;; SOMEBODY ELSE ANSWERED. Without this the masked field stayed up
          ;; over a `sudo` that was already through, and the daemon's own
          ;; `secret_late` warning — which would have explained it — is a
          ;; `Warning`, which this head does not draw either (app.rs:2750-2765).
          ;; Only OUR ask is dismissed: a settlement for another req_id is
          ;; another question, and closing this one on it would drop the
          ;; operator's keystrokes on the floor.
          (when (and (head-secret-req head)
                     (equal (getf (head-secret-req head) :req-id)
                            (getf env :req-id)))
            (progn
              (setf (head-secret-req head) nil
                    (head-secret-buf head) "")
              (say head (if (getf env :given)
                            (format nil "password given by ~a" (getf env :by))
                            (format nil "no password given (~a)" (getf env :by)))))))
         ((:operator-call-allowed)
          ;; **R24 part two: THE ONLY THING THAT RUNS A CALL.** The daemon has written
          ;; the admission and says so here; anything earlier — `Accepted` — is *queued*.
          ;; It lives in the frame path and not in `apply-event` because a run is an ACT:
          ;; it needs the socket to hand the result back, and what it reaches is this
          ;; head's own environment, not session state.
          (%op-call-answer head env)
          (setf (head-dirty head) t))
         ((:decision-requested)
          ;; **A FRESH QUESTION STARTS AT THE TOP OF ITS LADDER.**
          ;;
          ;; The reference's own reason (app.rs:2597-2600): *"the highlight must
          ;; never be somewhere the operator did not put it when Enter is one key
          ;; away"*. This head never reset it — `endp-open` in `session.lisp` was
          ;; called here and did NOTHING (`(declare (ignore open-decisions))`), and
          ;; the slot was zeroed only AFTER an answer went out
          ;; (`editor.lisp`'s two `%answer-decision` paths). So an ask inherited
          ;; the cursor of the last one, and with the no-match arm answering the
          ;; marked row, a typed line that named nothing was answered at a row the
          ;; operator had selected for a decision already dealt with.
          ;;
          ;; It lives HERE and not in `session.lisp` because the cursor is HEAD
          ;; state: the session cannot reach a head slot, which is why the hook
          ;; there could never have done it.
          ;;
          ;; **AND ONLY A FRESH ONE STARTS THERE.** The reset is guarded on the
          ;; `req_id`, because a reconnect replays from the read mark and delivers
          ;; an ask this head has already drawn — the same question a second time.
          ;; Zeroing on that undid the operator's keystroke: measured on the live
          ;; head, `down` left the cursor at 1 and a redelivery of the same
          ;; `req_id` put it back to 0, which is exactly what "the selector does
          ;; not work" looked like. A redelivery is the SAME question, not a fresh
          ;; one, and the reference only resets unconditionally because its reset
          ;; sits INSIDE the arm that has already dropped the old entry
          ;; (app.rs:2596-2601: `retain`, then `sel = 0`, then `push`) — and its
          ;; own comment names the thing that justifies the zero: a *FRESH*
          ;; question. This head's hook runs BEFORE `apply-event` drops the twin,
          ;; so the twin is still here to be asked about.
          (unless (member (getf env :req-id)
                          (session-open-decisions (head-session head))
                          :key (lambda (d) (getf d :req-id)) :test #'string=)
            ;; **AND THE LINE A READER HAD GOING IS HELD** (letibot `07509a3`, R90.3): recorded the moment
            ;; a FRESH card arrives, and checked by `%submit-line` before a free-form answer may be sent.
            ;; This hook is the right place for it for the same reason it is the right place for the
            ;; cursor reset: it fires once per NEW question, not once per event about one.
            (setf *line-when-card-arrived* (composer-buffer (head-composer head))
                  (head-decision-sel head) 0
                  (head-dirty head) t)))
         ;; **THE ONE EVENT THAT MAKES THE QUEUES LIVE RATHER THAN A SNAPSHOT** (protocol 43):
         ;; `QueueMoved {queue, id, to, why}` replaced `MergeEntryAdded`/`MergeEntryMoved`/
         ;; `MergeEntryRemoved`, whose arms sat here matching tags no daemon sends while every real
         ;; move filed an *unknown event* row on every head (the 2026-10-11 sweep, section A). It is
         ;; STATE PLUS EVIDENCE folded onto the row the snapshot gave us — never invented — and a hint
         ;; to ask again; `queue-moved` does both and stays quiet, because the daemon broadcasts it
         ;; to every session's log. A redelivery through a reconnect's replay sets the same state
         ;; twice, which is the duplicate-by-design the read mark allows.
         ((:queue-moved)
          (queue-moved head env)
          :dirty)
         ;; **AND THE DAEMON'S HELD COUNT** (the reference's `SessionEvent::HeldResults`, R79): *what this
         ;; session is holding back from its model right now … counted by kind*. **NOT transcript
         ;; content** — the reference's view folds it to nothing and this head files it as an event it
         ;; READS rather than folds — so it never becomes a row of its own: it rides the responding row.
         ;; The daemon publishes it every time the held set changes and says nothing once they are all
         ;; zero, so the head draws what it was last given.
         ((:held-results)
          (setf *held-results* (list (or (getf env :jobs) 0)
                                     (or (getf env :subagents) 0)
                                     (or (getf env :failed) 0))
                (head-dirty head) t)
          :dirty)
         ((:job-settled)
          ;; FOLDED INTO THE ROW THE DAEMON GAVE US, never invented. The jobs
          ;; pane draws `head-jobs`, which is only ever the `Jobs` reply, so an
          ;; open pane showed `running` for a job that had exited until `/jobs`
          ;; was run again — the exact lie event.rs:857-864 says this event
          ;; exists to prevent. A settlement for a job this head has not been
          ;; told about is not a row to make up: it arrives with the next
          ;; `ListJobs` (app.rs:2176-2195).
          (let ((row (find (getf env :job) (head-jobs head)
                           :key (lambda (j) (getf j :id)) :test #'equal)))
            (when row
              (setf (getf row :state) (getf env :state)
                    (getf row :running) nil
                    (getf row :produced) (getf env :produced)
                    (getf row :elapsed-ms) (getf env :elapsed-ms)
                    (head-dirty head) t))))
         (t))
       ;; **AN ANNOUNCED USER ROW DRAWS THE WORDS THIS HEAD IS HOLDING** — see `*bound-prompts*`
       ;; for the operator's report and letibot's rule. The announcement carries no body, so
       ;; without this the row draws nothing and the only copy of their sentence is the tail echo,
       ;; which sits BELOW the running turn: their message under the reply it never got to start.
       (when (and (eq name :transcript-appended)
                  (equal (getf env :kind) "user")
                  (getf env :item-id))
         (%bind-echo head (getf env :item-id)))
       ;; a queued prompt's row has landed: stop announcing it. The ROW's TEXT
       ;; is the match (app.rs:4744-4751), because the transcript takes the
       ;; words over by being them — `pop` retired the NEWEST entry for a row
       ;; that is almost certainly the OLDEST prompt, so with two queued
       ;; prompts of different lengths the wrong one came off first.
       ;;
       ;; **EVERY TEXT PART, and that is the snapshot path's own collection.** This arm
       ;; read the FIRST part with a `:text` and dropped the rest, so an item carrying
       ;; two text parts (a message and an attachment's caption) retired one echo and
       ;; left the other — one row, two of this head's own facts, and the two paths
       ;; disagreeing about which rows exist. `%re-resolve-queued` appends every part's
       ;; text for exactly this reason; the rule is that the LIVE path and the SNAPSHOT
       ;; path see the same rows, or they retire different things.
       (when (eq name :transcript-content)
         ;; **the body is here, so the binding goes: the row draws its own words now.** Leaving it
         ;; would draw the echo a second time on a row that already carries the text.
         (%unbind-echo (getf env :item-id))
         (let ((body (getf env :item)))
           (when (and (consp body) (equal (getf body :type) "user"))
             (dolist (p (getf body :parts))
               (let ((text (getf p :text)))
                 (when (and (stringp text) (plusp (length text)))
                   (%retire-pending head text)))))))
       ;; **THE JOB COUNT IS ONLY AS FRESH AS THE LAST TIME SOMETHING ASKED FOR IT.**
       ;;
       ;; `head-jobs` is filled by the daemon's answer to `list_jobs`, and until this
       ;; existed the only asker was `/jobs` — the pane's opener — so a count drawn from
       ;; it would sit at zero for the whole life of a background job unless the operator
       ;; happened to open that pane. That is the difference between a readout and a
       ;; souvenir, and the operator asked for the readout.
       ;;
       ;; **Three events, and the third is the one I got wrong first.** A job SETTLED drops
       ;; the count; a TOOL FINISHED with a `backgrounded` outcome is **the job starting**,
       ;; and it is the only event that says so — there is no `JobStarted` on the wire (see
       ;; `event.rs`: the job vocabulary is `JobSettled` and nothing else).
       ;;
       ;; I first put this on `:turn-finished`, on the reasoning that a backgrounded call's
       ;; result lands inside the turn and the turn's end is near enough. **MEASURED, and it
       ;; is not:** the operator asked for four jobs and watched the status line stay empty
       ;; for the whole turn that started them, because "the turn ends soon" is however long
       ;; the model keeps working — minutes, when it is doing the thing the job is for. A
       ;; count that arrives after the work it counts is a souvenir.
       ;;
       ;; `:turn-finished` stays as well, for the one case the tool result cannot cover: a
       ;; job that was already running when this head attached, which no event announces.
       ;;
       ;; It lives HERE and not in `apply-event`, which is the pure fold and sends
       ;; nothing: a fold that wrote to the socket would make the same event produce
       ;; different bytes depending on what else was in flight.
       (when (or (member name '(:job-settled :turn-finished))
                 ;; **THE JOB'S OWN HANDLE IS THE PROOF**, not a guess from the tool's name:
                 ;; only a call that was actually backgrounded carries one, and the daemon
                 ;; minted it a moment ago.
                 (and (eq name :tool-finished)
                      (equal (outcome-name (getf env :outcome)) "backgrounded")))
         (%send head (make-list-jobs)))
       ;; apply-event is the classifier: :dirty means something visible moved.
       (let* ((gaps-before *seq-gaps*)
              (disposition (apply-event (head-session head) env)))
         ;; **A GAP IS REPAIRED, NOT ONLY FILED — and the repair is the daemon's to make.** The
         ;; fold counts the jump and files the row that names it; it sends nothing, by design.
         ;; But a row is a notice, and what the head has after a gap is a STATE with a hole in
         ;; it: the events that never arrived were folded by nobody. When one of them was a
         ;; `tool_finished`, the call it ends stays `running` here for ever — `turn-busy-p`
         ;; says busy, `%hidden-run-live-work` counts it, and the marker's number stays
         ;; yellow through the reply and past the turn's end. That is the operator's *"yellow
         ;; tool count stucks sometimes"*, and *sometimes* is when the daemon's bounded
         ;; scrollback overflowed under a slow stream. The reference queues a `Resync` on
         ;; every gap (app.rs:3262-3286: *"the head cannot take a snapshot of a transcript it
         ;; does not hold"*); this head only told the operator to type `/resync`.
         ;;
         ;; Once per outstanding request: a batch that jumps twice before the snapshot lands
         ;; is one hole, and the snapshot that answers the first ask fills it. The `resync`
         ;; arm clears the flag.
         ;; **AND A FORK IS THE OTHER MOMENT THE HEAD KNOWS ITS ROWS WERE REPLACED.** The
         ;; `:transcript-forked` arm drops the PARENT's rows and waits for the child's, published
         ;; under new ids — and MEASURED 2026-10-11 on the operator's own head they did not all
         ;; arrive: their own messages were the parent's, so they LEFT THE SCREEN while the head sat
         ;; at `items-dropped 0` and `*resyncs*` 0, believing itself complete, and a full repaint
         ;; changed nothing (it had drawn exactly what it meant to). No count can tell the head that
         ;; the carry did not land — the fork REMOVED the rows, and that is the fact it has — so the
         ;; fork asks, once, exactly as a counted gap does, and the `resync` arm clears the flag.
         (when (and (eq name :transcript-forked) (not *resync-asked*))
           (setf *resync-asked* t)
           (%send head (make-resync)))
         (when (and (> *seq-gaps* gaps-before) (not *resync-asked*))
           (setf *resync-asked* t)
           (%send head (make-resync)))
         ;; **A REPLY THAT ARRIVED IS SHOWN, AND THAT IS THE ONE THING THE SESSION
         ;; CANNOT DO.** `note-slash-reply` — called from the `:warning` arm inside
         ;; `apply-event` — fills `*slash-out*`; the MODE is head state, so the head
         ;; follows the state HERE, after the fold that produced it. (It was first
         ;; written above the fold, where `*slash-out*` was always still empty: a
         ;; check with nothing to check, which the live probe caught and no test
         ;; could, because both halves are correct on their own.)
         ;;
         ;; The operator typed the verb, so the answer is what they asked for and it
         ;; takes the screen — the reference draws `slash_out` ahead of every other
         ;; pane for the same reason. A pane that was up is not lost (`/help` is one
         ;; key away again), and the alternative is worse: a reply CONSUMED as a
         ;; listing and then drawn nowhere at all.
         (when (and *slash-out* (not (eq (head-mode head) :slash)))
           (setf (head-mode head) :slash
                 (head-dirty head) t))
         (if (eq disposition :dirty)
             (progn (setf (head-dirty head) t) :rendered)
             :filtered))))
    ((string= (frame-name frame) "resync")
     ;; a resync means this head lost its place; the count is on /status and in
     ;; the alarm, because "it happened at all" is the operator's business
     (incf *resyncs*)
     ;; the snapshot answers the gap this head asked about (the event arm), so the next
     ;; gap may ask again
     (setf *resync-asked* nil)
     ;; BOTH COUNTS TRAVEL ON THIS FRAME and both were dropped on this path, so
     ;; `/status`'s `dropped` and `scrubbed` under-reported after a resync —
     ;; which is precisely when they are worth reading. The reference adds both
     ;; (app.rs:1843-1845). `ingest-snapshot` takes the max of its own, so this
     ;; is counted first and cannot be overwritten by a smaller snapshot.
     (incf (session-dropped (head-session head)) (or (getf frame :dropped) 0))
     (incf *scrubbed-total* (%scrub-total (getf frame :scrubbed)))
     (ingest-snapshot (head-session head) (getf frame :snapshot))
     ;; **AND THE QUEUED ECHOES ARE RE-RESOLVED AGAINST IT** (R16): the rows they were
     ;; waiting for may be IN this snapshot, and a row that arrives inside one retires
     ;; nothing on its own — `%retire-pending` is reached from the live
     ;; `transcript_content` arm and nowhere else, which is how three echoes survived
     ;; a compaction that carried all three of their rows.
     (%re-resolve-queued head (getf (getf frame :snapshot) :items))
     (progn
       (setf (head-full-repaint head) t
             (head-dirty head) t)
       (say head (format nil "resync: ~a" (getf frame :reason))))
     :control)
    ((string= (frame-name frame) "accepted")
     ;; Telling the person who just pressed enter that their prompt was
     ;; accepted is not information — and the note sits on the status line for
     ;; the rest of the session. Anything other than the routine acceptance
     ;; still gets said (app.rs:1315, NOTE_PROMPT_QUEUED).
     (let ((note (getf frame :note)))
       ;; **R24 part two: an `Accepted` for an OPERATOR CALL is not permission.**
       ;; It is the daemon saying the call is QUEUED; the permission is the
       ;; `operator_call_allowed` event, which lands once the admission has been
       ;; written. Asked separately from the note, because a call this head asked
       ;; for gets no line here at all — its own ask said *nothing runs until it says
       ;; the call was admitted* — and the RECORD is what makes the eventual silence
       ;; say the true sentence (`tick-op-calls`).
       (unless (%op-call-accepted head frame)
         (unless (and note (string= note +note-prompt-queued+))
           (say head note))
         ;; **AND IF THIS IS THE ACK TO A STOP, IT IS NOT THE OUTCOME** — it is the
         ;; daemon saying it heard. Recorded and said; `tick-stop-request` decides
         ;; when the wait is over (`head.lisp`, "a stop that is an OUTCOME").
         (heard-stop head note))
       (setf (head-dirty head) t))
     :control)
    ((string= (frame-name frame) "rejected")
     ;; **NO RETRY, AND THE DAEMON'S SENTENCE IS THE ONE SHOWN** for a call this head
     ;; asked for: it names what was asked for, the names the door accepts, and that
     ;; nothing ran. It is also the only refusal that means anything — the head is
     ;; going to run the thing either way, which is why the list is enforced THERE.
     (if (%op-call-refused head frame)
         (say head (format nil "~a — not re-sent: the door is the daemon's and the list is not negotiable at this layer"
                           (or (getf frame :reason) "the daemon refused the call")))
         (say head (format nil "rejected: ~a (expected seq ~a, daemon at ~a)"
                           (getf frame :reason) (getf frame :expected-seq)
                           (getf frame :actual-seq))))
     :control)
    ((string= (frame-name frame) "diagnostic")
     ;; **R11's answer, and only the reader who ASKED takes it.** The frame is a read and
     ;; the daemon keys it by the ADJUDICATION's own id — the thing `/gate` takes — so a
     ;; head that asked for one id draws the answer to that id and nothing else. An answer
     ;; for something nobody is reading is not an error and not a row: it is `:filtered`,
     ;; which `/status` counts, and which is the honest word for *I read this and chose not
     ;; to show it*.
     (let ((diag *diag*))
       (cond
         ((null diag) :filtered)
         ((not (equal (getf frame :request-id) (getf diag :request-id)))
          ;; **SAID, not swallowed**: a mismatched id is either a head that asked for two
          ;; ids at once (this one does not) or a daemon answering an id nobody named, and
          ;; a reader who is looking at an empty pane deserves to know which.
          (say head (format nil "a diagnostic for ~a arrived while this head was reading ~a — nothing of it was taken"
                            (or (getf frame :request-id) "no id") (or (getf diag :request-id) "nothing")))
          :control)
         (t
          (let* ((kind (or (getf frame :kind) ""))
                 (ans (cdr (assoc kind (getf diag :answers) :test #'string=))))
            ;; **an ANSWER, which is a different thing from a WAIT**: `:decided` is what
            ;; turns *reading…* into one of the three endings, and it is set HERE rather
            ;; than inferred from a body being present, because `body: None` is an answer.
            (when ans
              (setf (getf ans :decided) t
                    (getf ans :body) (getf frame :body)
                    (getf ans :total) (getf frame :total)))
            (open-diagnostic-listing diag head)
            (when (not (eq (head-mode head) :slash))
              (setf (head-mode head) :slash))
            (reset-pane-scroll)
            (setf (head-dirty head) t)
            :control)))))
    ((string= (frame-name frame) "sessions")
     (setf (session-sessions (head-session head))
           ;; **A CHILD IS A SESSION, on this frame as on the Hello** — see `picker-sessions` for the
           ;; operator's words and for why the filter this replaces was the bug rather than the quiet.
           (getf frame :sessions)
           (head-picker-sel head) 0
           (head-dirty head) t)
     ;; `current` is the daemon's word for where this connection IS. It was
     ;; dropped, along with `created`.
     (let ((current (getf frame :current))
           (created (getf frame :created)))
       (when (and (stringp current) (plusp (length current)))
         (setf (session-session-id (head-session head)) current))
       (cond
         ;; A SESSION WAS MADE BECAUSE THIS HEAD ASKED. Going there is what was
         ;; meant: `/new` that leaves you where you were is a command whose
         ;; effect is invisible, and that is what `/new` and `--new TITLE` did —
         ;; they created a session and left the operator in the old one
         ;; (app.rs:1736-1744).
         ((and created (head-want-new head))
          (setf (head-want-new head) nil)
          (%send head (make-switch created 0)))
         ;; somebody else's: said, not followed
         (created (say head (format nil "session ~a created" created)))
         ;; **Not** an open picker. This frame answers three different questions
         ;; — a list, a rename, and a switch to the session you are in — and only
         ;; the first wants one; the command that asks for a list opens it itself.
         (t nil)))
     :control)
    ((string= (frame-name frame) "term_attached")
     ;; the daemon accepted the open; the pane is live, and the PROGRAM is told the size the pane has
     ;; rather than the size it asked with — the window may have changed between the two.
     ;; **THE TERMINAL GETS A SCREEN AT ATTACH, AND THE RECTANGLE IS THE PANE'S OWN.** The frame
     ;; carries ONLY the command (`TermAttached { command }`, protocol.rs:2572 — *a command and not
     ;; the line*: the daemon never saw the verb) — the daemon has no screen, so the size is this
     ;; head's fact and `%term-rectangle` is where it is computed. This arm read `:cols`/`:rows` off
     ;; the frame and `(max 1 nil)` was a type error on every real attach (the 2026-10-11 sweep,
     ;; section A). A frame that does carry them (a fixture) is honoured, because a daemon that said
     ;; a size meant it.
     (multiple-value-bind (cols rows) (%term-rectangle head)
       (let ((cols (or (getf frame :cols) cols))
             (rows (or (getf frame :rows) rows)))
         (setf *term-pane* (or (getf frame :pane) 1)
              (head-term head) (list :cols cols :rows rows :output ""
                                      :command (getf frame :command)
                                      :screen (term-screen-new rows cols)
                                      :dropped 0 :pending nil :pane *term-pane* :back 0)
               
              (head-mode head) :term
               (head-dirty head) t)
         ;; the PROGRAM is told the size the pane has — the window may have changed between the
         ;; ask and the answer
         (%send head (make-term-resize cols rows))))
     :control)
    ((string= (frame-name frame) "term_output")
     ;; **THE BYTES, APPENDED** — the pane draws from this and nothing else, so it cannot disagree
     ;; with what arrived. A frame for a terminal this head is not showing is DROPPED, not buffered:
     ;; one pane per session, and the daemon's own refusal is why.
     ;;
     ;; **`bytes: Vec<u8>` — a JSON array of byte values, UTF-8 decoded HERE** (protocol.rs:2597:
     ;; *raw: cursor addressing, `\r`, a partial UTF-8 character and all*). This arm read `:data` as
     ;; a string and always got `""`, so a live terminal drew nothing (the sweep, section A). A
     ;; character cut across two frames waits in `:pending` for its tail (`%term-decode-bytes`).
     (when (and (head-term head) (%term-frame-is-mine-p frame))
       (let* ((term (head-term head))
              (text (cond ((getf frame :bytes) (%term-decode-bytes term (getf frame :bytes)))
                          ;; a fixture's string, for the readers that build one by hand
                          ((stringp (getf frame :data)) (getf frame :data))
                          (t ""))))
         ;; **THE BYTES GO INTO THE SCREEN AND ARE ALSO KEPT — CAPPED.** The screen is what the pane
         ;; DRAWS — a program that moved the cursor is drawn where it moved it — and the raw text is
         ;; kept because it is the only thing that can be re-fed if the rectangle changes; kept
         ;; through an adjustable buffer and to the last `+term-output-cap+`, because the
         ;; `concatenate` that was here copied the whole history on every frame and never let go
         ;; of any of it.
         (%term-append-output term text)
         (setf (head-dirty head) t)
         (let ((scr (getf term :screen)))
           (when scr
             (let ((before (term-screen-scrolled scr)))
                (incf (getf term :dropped) (term-screen-feed scr text))
                ;; **A READER'S PAGE STAYS PUT.** A row pushed past the top while they are reading is
                ;; counted into `back`, so the view does not slide under them — the reference's own
                ;; `feed`, and the difference between reading a scrollback and chasing one.
                (when (plusp (or (getf term :back) 0))
                  (setf (getf term :back)
                        (min (+ (getf term :back) (- (term-screen-scrolled scr) before))
                             (length (term-screen-history scr))))))))))
     :control)
    ((string= (frame-name frame) "term_status")
     ;; **WHAT THIS SESSION'S PANE IS RUNNING, OR NOTHING** — the answer to `/term status`
     ;; (`TermStatus { command: Option<String> }`, protocol.rs:2557). `null` is *no live pane*, the
     ;; ordinary state of a session nobody ran `!term` in, and the daemon's own rule is that a head
     ;; draws it as NOTHING rather than as a row — so both answers are said once on the status
     ;; line and nothing is filed.
     (let* ((panes (getf frame :panes))
            (has (and (member :panes frame) t))
            (command (%term-status-command panes has (getf frame :command)))
            (n (if has (length panes) (if command 1 0))))
       (setf *term-status* command)
       (say head (cond ((zerop n) "nothing is running in this session's pane")
                       ((= n 1) (format nil "a pane is running `!term ~a` — /term attaches to it" command))
                       (t (format nil "~d panes are running: ~a — `!term N` attaches to one" n command)))))
     :control)
    ((string= (frame-name frame) "term_ended")
     ;; the ENDING, and which one — a person's `TermClose` and the daemon ending it are different
     ;; facts, and the pane says which rather than falling silent.
     (when (and (head-term head) (%term-frame-is-mine-p frame))
       (setf (getf (head-term head) :ended) (or (getf frame :reason) "the daemon ended it")
             (head-dirty head) t))
     :control)
    ((string= (frame-name frame) "standing_notes")
     ;; **THE LIST OF WHAT THE HARNESS IS READING IN**, one row per note. REPLACES, for the
     ;; reason the queue's own fold does: this is a snapshot of a mailbox, and folding it into
     ;; what the head held would leave a note the harness has stopped injecting on the pane.
     (let ((notes (getf frame :notes)))
       (setf (head-standing-notes head) notes
             (head-dirty head) t)
       (say head (format nil "the harness is reading ~d note~:p into this session" (length notes))))
     :control)
    ((string= (frame-name frame) "queues")
     ;; **BOTH QUEUES AS OF NOW** (protocol 43, `ServerFrame::Queues { snapshot }`), replacing the
     ;; `merge_queue {entries}` arm that matched a frame no daemon sends any more — so `/queue` drew
     ;; nothing (the 2026-10-11 sweep, section A). The snapshot is the WHOLE of both queues, each
     ;; repository's lease, the targets' health and the recent moves, so `fold-queues` REPLACES
     ;; rather than merges — folding it into what the head held would let a landed row survive a
     ;; reset. Not scoped to this head's session: the queues are daemon-level.
     (fold-queues head (getf frame :snapshot))
     :control)
    ((string= (frame-name frame) "jobs")
     ;; **A REPLY WHOSE SESSION IS NOT THIS ONE IS NOT THIS HEAD'S COPY** (T6 in `TODO.md`).
     ;; A `/jobs` asked before a `/switch` is answered after it, and the daemon's reply names the
     ;; session it is about — so applying it unconditionally put ONE conversation's job rows on
     ;; another's screen, with nothing on the glass saying where they came from. The same guard is
     ;; on `todos` below, and the pairs are why it is written twice rather than in a helper: each
     ;; arm's fold is its own, and a shared wrapper would have to know both.
     ;;
     ;; The two empty cases are NOT refusals: a frame from a daemon that does not carry the field,
     ;; and a head that has not attached yet. Both mean *I cannot tell*, and a head that dropped
     ;; the reply then would draw an empty list on every attach.
     (if (%frame-for-another-session-p head frame)
         :quiet
         (progn
           (setf (head-jobs head) (getf frame :jobs)
                 (head-dirty head) t)
           :control)))
    ((string= (frame-name frame) "todos")
     ;; **the reply carries the UNION, so the operator's half of it is folded into this head's own
     ;; list before the wire's copy is stored** — see `fold-board-statuses`, the one rule for who
     ;; owns what: membership is this head's, status is the daemon's
     ;;
     ;; AND NOT FOR ANOTHER SESSION, for `jobs`' reason: the operator's half must not be folded
     ;; against a board from a conversation this head has left.
     (if (%frame-for-another-session-p head frame)
         :quiet
         (progn
           (fold-board-statuses (getf frame :todos))
           (setf (session-todos (head-session head)) (getf frame :todos)
                 (head-dirty head) t)
           :control)))
    ((string= (frame-name frame) "settings")
     ;; STORE the rows and stop there. Opening the pane is the COMMAND's act,
     ;; not the reply's: the head asks for settings on attach now (they are only
     ;; ever sent in reply to a request, §7.4), and a reply that opened the pane
     ;; would pop `/config` at every attach.
     ;;
     ;; **AND THE FOLD BELOW THE HEAD GOES WITH IT** — `%fold-settings` is the one writer of
     ;; `*compaction-sections*`, and it had NO CALLER ANYWHERE: the daemon's own list of the
     ;; sections a compaction keeps (R28) reached the head on this frame, `head-settings` was
     ;; set, and the list was dropped on the floor — so `(not stated)` could never be drawn, and
     ;; a compaction report whose sections the daemon did not name drew as *nothing to say*
     ;; instead of *the daemon did not say* (found by the wire reviewer, 2026-10-11). The suite
     ;; hid it by binding the variable by hand, which is exactly what a hand-bound variable
     ;; does. One call, in the one place the settings land.
     (setf (head-settings head) (%fold-settings (getf frame :rows))
           ;; when the rows were last heard, so the header can rank them against
           ;; the turn's own word for the model (`%model-name`)
           *model-from-settings-at* (session-seq (head-session head))
           (head-dirty head) t)
     ;; **A PICKER THAT OPENED BEFORE ITS OWN LIST ARRIVED MUST SEED NOW.**
     ;;
     ;; The operator: *"mode selectors has selection on the first not on the current again."*
     ;; `open-pick` seeds the cursor on `(position (pick-current head which) (pick-choices head
     ;; which))` — correct, and EMPTY the first time, because `/mode` opens the picker and ASKS for
     ;; the settings in the same breath (`open-pick` sends `make-settings` when `head-settings` is
     ;; nil). `pick-choices` then reads a list that does not exist yet, so `position` answers NIL,
     ;; the fallback `0` is taken, and nothing re-seeds when the rows land: the cursor sits on the
     ;; FIRST row while `← now` marks the current one further down.
     ;;
     ;; It works on the SECOND open, settings being known by then — which is why the report is
     ;; *"again"* rather than a permanent break, and why a test that sets the settings up first
     ;; would never see it.
     ;;
     ;; **Re-seeded only while the cursor is still untouched**, so a settings frame arriving while
     ;; the operator is arrowing through the list cannot snap their cursor back — a worse defect
     ;; than the one this fixes.
     (when (and *pick-open* *pick-unseeded*)
       (setf (head-picker-sel head)
             (or (position (pick-current head) (pick-choices head) :test #'string=) 0)
             *pick-unseeded* nil))
     :control)
    ((string= (frame-name frame) "shell_suggestions")
     ;; **THE MODEL'S PROPOSED `!` COMPLETIONS** (protocol 30). The head sent a
     ;; `suggest_shell` frame with the typed prefix; this is the daemon's answer —
     ;; candidate lines, `!` first, in the order the model offered them. **Nothing
     ;; here is a command**: a suggestion only fills the composer, and Enter is
     ;; still the operator's. Stored in `*shell-suggestions*` for the completion
     ;; to read on the next Tab, keyed by the echoed prefix so a stale answer for
     ;; a prefix the operator has already typed past is dropped on the floor.
     (when (and *shell-suggestions-for*
                (string= (getf frame :prefix) *shell-suggestions-for*))
       (setf *shell-suggestions* (getf frame :lines)))
     :control)
    ((string= (frame-name frame) "row_fetched")
     ;; **THE ANSWER ARRIVES ON THE SAME STREAM AS THE SESSION'S OWN TRAFFIC**, which is
     ;; why it is folded here and not awaited: a head that blocked on this would stop
     ;; drawing the conversation it is reading. `note-row-fetched` decides what the
     ;; three answers mean — a body that goes at the TOP of the transcript, a `null`
     ;; that says the rows above are gone, and a row nobody is waiting for.
     (note-row-fetched (head-session head)
                       (getf frame :row)
                       (getf frame :body)
                       (or (getf frame :total) 0))
     :control)
    ((string= (frame-name frame) "peeked")
     ;; **THE PANE TAILS, SO A REPEAT REPLY MUST NOT MOVE THE READER.** `reset-pane-scroll` belongs to
     ;; the FIRST peek — the pane opening on that child — and not to every reply: with the re-ask in
     ;; `tick-peek`, a reader who scrolled up to read a child's earlier output would be yanked back to
     ;; the tail once a second. The test is whether this reply is the pane's own, which is the same
     ;; question `*peeked-session*` answers for every other reader of it.
     ;; **AND IT OPENS ONLY FOR WHAT WAS ASKED FOR** (letibot `81463c0`). A `Peeked` frame names a child
     ;; and nothing else, so without the ASK written down the head cannot tell the answer to what the
     ;; reader just asked from the answer to a question whose pane they closed a minute ago. The
     ;; reference's rule is that a late reply is NOT opened — and `*peek-want*` is what makes it checkable.
     (let ((same (and (eq (head-mode head) :peek)
                      (equal *peeked-session* (getf frame :session-id)))))
       (when (equal *peek-want* (getf frame :session-id))
         (setf (head-peeked head) (getf frame :events)
               *peeked-session* (getf frame :session-id)
               *peeked-dropped* (or (getf frame :dropped) 0)
               ;; **the rows, when the daemon sends them** — and NIL when it does not, so a later reply
               ;; cannot inherit the previous child's snapshot. See `*peeked-snapshot*`.
               *peeked-snapshot* (getf frame :snapshot)
               (head-mode head) :peek
               (head-dirty head) t)
         (unless same (reset-pane-scroll))))
     :control)
    ((string= (frame-name frame) "bye")
     ;; **A BYE IS FINAL — UNLESS THIS HEAD ASKED FOR IT.** The daemon writes one
     ;; and returns; the reference's pump stops on it and the head leaves
     ;; (client.rs:548, app.rs:1886-1889). This head only dropped `connected`, so
     ;; `%try-reconnect` re-attached two seconds later, forever — a refusal the
     ;; daemon meant as the end of the conversation became a loop, and a version
     ;; skew became unreadable AND unescapable: `bye: protocol version 21, this
     ;; daemon speaks 22` flashing under a head that never attaches and never
     ;; exits.
     ;;
     ;; **When a stop is pending, this Bye is the ANSWER to it**, and the outcome
     ;; is still the daemon's absence: leaving here would be the same defect one
     ;; frame later — the operator told nothing while a process that was *asked*
     ;; to go does whatever it does next. So it is recorded and the wait goes on.
     (if *stop-request*
         (progn
           (heard-stop head (format nil "bye — ~a" (getf frame :reason)))
           (progn
             (setf (head-connected head) nil)
             (say head (format nil "bye: ~a" (getf frame :reason)))
             :control))
         (progn
           (progn
             (setf (head-connected head) nil
                   (head-running head) nil
                   (head-farewell head) (format nil "the daemon said goodbye: ~a"
                                                (getf frame :reason)))
             (say head (format nil "bye: ~a" (getf frame :reason)))
             :control))))
    ;; **A FRAME TAG THIS HEAD DOES NOT KNOW IS A FRAME IT CANNOT READ**, and it used
    ;; to be neither said nor counted — the arm answered `:control` and the line went
    ;; past. This is the other half of what a daemon one version ahead looks like from
    ;; a STRUCTURAL reader: serde fails the whole line on an unknown tag, so the
    ;; reference only ever meets this case in its decoder, while this head is handed
    ;; the plist and has to notice for itself.
    ;;
    ;; Silent is the worse of the two failures: a head that steps over a frame from a
    ;; newer daemon in silence makes "this daemon is sending me something I do not
    ;; understand" look exactly like a quiet daemon.
    (t
     ;; **Not a plist at all is also unreadable, and it is reported rather than
     ;; swallowed.** This file has been bitten by exactly that shape before: the
     ;; reader pushes `(:disconnected)` — a one-element list — and a `frame-name`
     ;; call on it is a TYPE-ERROR in the main thread, which under
     ;; `--disable-debugger` is a head that refuses to start (see `%frame-plist-p`).
     ;; The old `(t :control)` hid any other such marker in silence; now the one
     ;; thing that must never happen to an unreadable frame happens to it too.
     (let ((framep (%frame-plist-p frame)))
       (note-unreadable (head-session head)
                        (if framep
                            (format nil "unknown frame ~s" (or (frame-name frame) "?"))
                            (format nil "not a frame at all: ~s" frame))
                        (and framep (getf frame :wire-line))))
     (setf (head-dirty head) t)
     :control)))

(defun %poll-resize (head)
  "The loop's per-tick poll: the terminal's size, and — riding the same tick, because this is the
one function in this file the loop calls every round — the queue pane's 5 s re-read
(`tick-queues`). The honest home for that second call is the loop's own tick list beside
`tick-peek` (`op-call.lisp`); it is here so the pane re-reads without that file changing hands,
and a reader looking for who asks the daemon for the queues every five seconds finds it by name."
  (multiple-value-bind (cols rows) (terminal-size 1)
    (when (or (/= cols (head-cols head)) (/= rows (head-rows head)))
      (setf (head-cols head) cols (head-rows head) rows)
      (screen-resize (head-screen head) cols rows)
      (screen-resize (head-prev-screen head) cols rows)
      (setf (head-full-repaint head) t
            (head-dirty head) t)))
  (tick-queues head)
  ;; **AND THE RUNNING JOB'S WINDOW** (letibot `516c5a4`): the same shape one pane over — a live thing is
  ;; re-read, not remembered. Here rather than in the tick list for the reason above: this is the one
  ;; function the loop calls every round, and a reader looking for who asks the daemon for a running
  ;; job's output every second finds it by name.
  (tick-job-window head)
  ;; **AND A NAG PAUSE WHOSE TIME IS UP** (R83): ended here and SAID, because a pause that ended
  ;; silently would leave the reader believing the head had stopped reminding them for good.
  (tick-nag-pause head))

