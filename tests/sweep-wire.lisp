;;;; tests/sweep-wire.lisp — the 2026-10-11 sweep's tests for the wire area (TODO.md, "Sweep 2026-10-11").
(in-package #:leticl/tests)

;;; Every test here is one item of the sweep's wire list (sections A and B.1), and each would have
;;; FAILED on the tree as it stood that morning: the frame shapes are asserted on the JSON that
;;; leaves the head, the folds on the state a fed envelope leaves behind. Fixtures reset the queue
;;; globals they touch, because those are `defvar`s that outlive a test.

(defun %sw-json (frame)
  "FRAME as the wire line it becomes — the thing serde reads, so the keys are the assertion."
  (leticl::json-encode-to-string frame))

(defun %sw-text (lines)
  "Pane LINES as one string, blank lines as empty rows."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (l) (if (null l) "" (format nil "~{~a~}" (mapcar #'car l)))) lines)))

(defun %sw-reset-queues ()
  (setf leticl::*queues* nil leticl::*queue-view* :review leticl::*queues-in-flight* nil
        leticl::*queues-got-ms* 0 leticl::*queues-asked-ms* 0))

(defparameter +sw-snapshot-template+
  (list :at-ms 1000000
        :reviews (list (list :id "r-target" :repository "/w/leticl" :target "main" :kind "target"
                             :session-id "s-9" :branch "" :state "waiting" :owner "" :head-sha "deadbeef0123"
                             :evidence "main is red at deadbeef" :created-ms 900000 :state-ms 950000)
                       (list :id "r1" :repository "/w/leticl" :target "main" :kind "branch" :session-id "s-1"
                             :branch "topic-a" :state "reviewing" :owner "lab2x1/4242/1700"
                             :head-sha "4f2a1c9abcd" :evidence "the gatekeeper is reading it"
                             :created-ms 800000 :state-ms 940000 :brief "add the thing")
                       (list :id "r2" :repository "/w/leticl" :target "main" :kind "branch" :session-id "s-2"
                             :branch "topic-c" :state "rejected" :reasons (list "changes the renderer")
                             :verdict "reject" :head-sha "0000aaaa" :evidence "" :created-ms 700000 :state-ms 990000))
        :merges (list (list :id "m1" :review-id "r0" :repository "/w/leticl" :target "main" :branch "topic-b"
                            :state "gating" :owner "lab2x1/4242/1700" :approved-sha "77777777abc" :approved-by "operator"
                            :evidence "cargo test running" :gate-steps (list (list :command "cargo test" :outcome "passed"))
                            :created-ms 600000 :state-ms 999000)
                      (list :id "m2" :review-id "r5" :repository "/w/leticl" :target "main" :branch "topic-d"
                            :state "failed" :approved-sha "88888888abc" :evidence "gate: fmt"
                            :created-ms 500000 :state-ms 980000))
        :leases (list (list :repository "/w/leticl" :owner "lab2x1/4242/1700" :pid 4242 :host "lab2x1"
                            :build "abc1234" :heartbeat-ms 998000 :acquired-ms 1000)
                      (list :repository "/w/other" :owner "dogfood/1/1" :pid 1 :host "dogfood"
                            :build "old9999" :heartbeat-ms 800000 :acquired-ms 1000))
        :targets (list (list :repository "/w/leticl" :target "main" :sha "deadbeef0123" :state "red"
                             :checked-ms 990000 :evidence "cargo test failed"))
        :recent (list (list :queue "review" :entry-id "r1" :repository "/w/leticl" :from "waiting" :to "reviewing"
                            :at-ms 940000 :by "lab2x1/4242/1700" :why "lease taken"))
        :archived 3)
  "A protocol-43 snapshot with one of everything the pane draws: a red target and its review row,
a review in flight, a rejected one, a merge gating, a merge failed, a fresh lease and a STALE one.
A TEMPLATE: `queue-moved` mutates rows in place, so every test takes its own copy (`%sw-snapshot`).")

(defun %sw-snapshot () (copy-tree +sw-snapshot-template+))

;;; ------------------------------------------------------------------ 1. !term ;;;

(def-test term-open-carries-the-line-and-term-input-carries-bytes (:suite leticl)
  "**The two `!term` frames the daemon refused** (sweep A). `TermOpen { line, cols, rows }` needs the
operator's line, verb included; `TermInput { bytes }` needs the keys as a byte array. Both went out
in another shape and each cost a reconnect."
  (let ((open (%sw-json (leticl::make-term-open "!term mc" 80 24)))
        (key (%sw-json (leticl::make-term-input "é")))
        (empty (%sw-json (leticl::make-term-input ""))))
    (is (search "\"line\":\"!term mc\"" open) "**`line` is on the frame, verb included**: ~a" open)
    (is (search "\"cols\":80" open) "with the rectangle")
    (is (search "\"bytes\":[195,169]" key) "**the keystroke is its UTF-8 bytes, as a JSON number array**: ~a" key)
    (is (not (search "\"data\"" key)) "and the old `data` string is gone")
    (is (search "\"bytes\":[]" empty) "an empty keystroke is `[]`, never an elided required field: ~a" empty)
    (is (search "\"frame\":\"term_status\"" (%sw-json (leticl::make-term-status))) "and `TermStatus` exists")))

(def-test term-attached-carries-only-the-command-and-the-pane-sizes-itself (:suite leticl)
  "`TermAttached { command }` (protocol.rs:2572) carries NO rectangle: the fold read `:cols`/`:rows` and
`(max 1 nil)` was a type error on every real attach. The size is the pane's own, the program is told
it, and the header says what is running."
  (let* ((h (%on-head :cols 100 :rows 30))
         (wire (%wire h)))
    (leticl::%handle-frame h (list :frame "term_attached" :command "mc"))
    (is (eq :term (head-mode h)) "the pane opens")
    (is (= 100 (getf (head-term h) :cols)) "the columns are the head's: ~s" (getf (head-term h) :cols))
    (is (= 29 (getf (head-term h) :rows)) "and the rows one under its height")
    (is (getf (head-term h) :screen) "and a screen exists at that rectangle")
    (let ((resize (find "term_resize" (%sent wire) :key #'frame-name :test #'string=)))
      (is (and resize (= 100 (getf resize :cols)) (= 29 (getf resize :rows)))
          "**the program is told the same rectangle**: ~s" resize))
    (is (search "!term mc" (%sw-text (leticl::pane-lines (leticl::pane-for :term) h 100 30)))
        "and the header says what is running, verb put back on")))

(def-test term-output-is-a-byte-array-decoded-as-utf8-and-capped (:suite leticl)
  "`TermOutput { bytes }` is a number array; the fold read a `:data` string and always got `\"\"`. A
character cut across two frames is held for its tail, and the kept output is capped at the last
256 KB through a buffer that does not copy the whole history per frame."
  (let ((h (%on-head :cols 40 :rows 10)))
    (%wire h)
    (leticl::%handle-frame h (list :frame "term_attached" :command "cat"))
    ;; "héllo" is 68 C3 A9 6C 6C 6F — cut between C3 and A9
    (leticl::%handle-frame h (list :frame "term_output" :bytes (list #x68 #xC3)))
    (leticl::%handle-frame h (list :frame "term_output" :bytes (list #xA9 #x6C #x6C #x6F)))
    (is (equal "héllo" (getf (head-term h) :output))
        "**decoded as UTF-8 across the frame boundary**: ~s" (getf (head-term h) :output))
    (is (null (getf (head-term h) :pending)) "nothing is left waiting")
    ;; the cap: 300 KB of 'a' then a marker
    (let ((chunk (make-list 65536 :initial-element (char-code #\a))))
      (dotimes (i 5) (leticl::%handle-frame h (list :frame "term_output" :bytes chunk))))
    (leticl::%handle-frame h (list :frame "term_output" :bytes (list (char-code #\Z))))
    (let ((out (getf (head-term h) :output)))
      (is (= leticl::+term-output-cap+ (length out))
          "**the kept output is the cap exactly** — ~d characters, not ~d" (length out) (+ 5 (* 5 65536)))
      (is (char= #\Z (char out (1- (length out)))) "and it is the LAST bytes that are kept"))))

(def-test term-status-is-asked-by-the-verb-and-said-when-answered (:suite leticl)
  "`/term status` asks `TermStatus`; the answer is said once — a command, or that nothing runs — and
never filed as a row (protocol.rs:2557). `/term CMD` sends the line; `/term` alone with no pane is the
daemon's ATTACH reading."
  (let* ((h (%make-head))
         (wire (%wire h)))
    (leticl::%command h "term status")
    (is (find "term_status" (%sent wire) :key #'frame-name :test #'string=) "the verb asks")
    (leticl::%handle-frame h (list :frame "term_status" :command "mc"))
    (is (search "!term mc" (head-status-note h)) "a live pane is said with its command: ~s" (head-status-note h))
    (leticl::%handle-frame h (list :frame "term_status" :command nil))
    (is (search "nothing is running" (head-status-note h)) "and none is said as none")
    (leticl::%command h "term nano notes.txt")
    (let ((open (find "term_open" (%sent wire) :key #'frame-name :test #'string=)))
      (is (equal "!term nano notes.txt" (getf open :line)) "`/term CMD` sends `!term CMD`: ~s" open))
    (leticl::%command h "term")
    (let ((open (find "term_open" (%sent wire) :key #'frame-name :test #'string=)))
      (is (equal "!term" (getf open :line)) "and a bare `/term` with no pane is the attach reading: ~s" open))
    (leticl::%command h "term close")
    (is (find "term_close" (%sent wire) :key #'frame-name :test #'string=)
        "**`/term close` is the ending** — the explicit act, since `ctrl-\\` detaches and sends nothing")))

;;; ------------------------------------------------------------------ 2. todos ;;;

(def-test every-todo-status-reaches-the-board-as-the-daemon-spells-it-and-moved-rides-along (:suite leticl)
  "`set_operator_todos` mapped only `completed` and `postponed`; `cancelled` went out as `pending`, so
`/todo rm` resurrected the row on the next `todos_updated` (sweep A). Every enum word goes as it is,
and `moved` (protocol 41) carries the operator's hand on the model's rows."
  (let ((json (%sw-json (leticl::make-set-operator-todos
                         7
                         (list (list :content "a" :status "cancelled")
                               (list :content "b" :status "in_progress")
                               (list :content "c" :status "postponed")
                               (list :content "d" :status "completed")
                               (list :content "e" :status "open"))
                         (list (list :content "fix the test" :status "postponed"))))))
    (is (search "\"content\":\"a\",\"status\":\"cancelled\"" json) "**`cancelled` survives**: ~a" json)
    (is (search "\"content\":\"b\",\"status\":\"in_progress\"" json) "`in_progress` survives")
    (is (search "\"content\":\"c\",\"status\":\"postponed\"" json) "`postponed` survives")
    (is (search "\"content\":\"d\",\"status\":\"completed\"" json) "`completed` survives")
    (is (search "\"content\":\"e\",\"status\":\"pending\"" json) "the head's `open` is the wire's `pending`")
    (is (search "\"moved\":[{\"content\":\"fix the test\",\"status\":\"postponed\"}]" json)
        "**and `moved` carries the model's row by its words**: ~a" json))
  (is (not (search "moved" (%sw-json (leticl::make-set-operator-todos 7 nil))))
      "with nothing to move the key is omitted, which is what `#[serde(default)]` and an older daemon want"))

(def-test todo-rm-on-a-models-row-sends-a-move (:suite leticl)
  "`/todo rm WORDS` — not a number — names a row the MODEL wrote, and reaches the board as `moved`."
  (let* ((h (%make-head))
         (wire (%wire h)))
    (setf (leticl::session-session-id (head-session h)) "s-moves")
    (let ((leticl::*operator-todos* nil) (leticl::*todo-moves* nil) (leticl::*write-prefs* nil))
      (leticl::%command h "todo rm fix the flaky test")
      (let ((frame (find "set_operator_todos" (%sent wire) :key #'frame-name :test #'string=)))
        (is (not (null frame)) "a push went out")
        (is (equal (list (list :content "fix the flaky test" :status "cancelled")) (getf frame :moved))
            "**with the move, as `cancelled`**: ~s" (getf frame :moved)))
      (is (null leticl::*todo-moves*) "and the move is one-shot")
      (leticl::%command h "todo postpone wait for the operator")
      (is (equal "postponed" (getf (first (getf (find "set_operator_todos" (%sent wire) :key #'frame-name :test #'string=) :moved)) :status))
          "`postpone WORDS` is `postponed`"))))

;;; --------------------------------------------------------- 3. QueueMoved ;;;

(def-test queue-moved-moves-the-row-in-place-and-files-nothing-as-unknown (:suite leticl)
  "`QueueMoved {queue,id,to,why}` is broadcast to EVERY session's log; it used to file an *unknown
event* row on every head and bump the alarm. It moves the row in place, and asks again only while
the pane is open and no ask is in flight."
  (%sw-reset-queues)
  (let* ((h (%make-head))
         (wire (%wire h))
         (before leticl::*unreadable-total*))
    (leticl::%handle-frame h (list :frame "queues" :snapshot (%sw-snapshot)))
    (let ((said (head-status-note h)))
      (leticl::%handle-frame h (list :frame "event" :seq 2 :event "queue_moved"
                                     :queue "review" :id "r1" :to "approved" :why "the operator approved it"))
      (is (equal said (head-status-note h)) "nothing was said on the status line — it is a broadcast"))
    (is (= before leticl::*unreadable-total*) "**nothing is filed as unknown**")
    (is (null (session-warnings (head-session h))) "and nothing is filed as a warning")
    (let ((row (find "r1" (getf leticl::*queues* :reviews) :key (lambda (r) (getf r :id)) :test #'equal)))
      (is (equal "approved" (getf row :state)) "the snapshot's row moved: ~s" (getf row :state))
      (is (equal "the operator approved it" (getf row :evidence)) "with the reason"))
    (is (find "r1" (getf leticl::*queues* :recent) :key (lambda (m) (getf m :entry-id)) :test #'equal)
        "and the move is in the history")
    (is (not (find "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=))
        "**a closed pane asks nothing** — the event is quiet")
    ;; open pane: one ask, and a second move while it is in flight asks nothing more
    (setf (head-mode h) :queue)
    (leticl::%handle-frame h (list :frame "event" :seq 3 :event "queue_moved" :queue "merge" :id "m2" :to "queued" :why "restarted"))
    (leticl::%handle-frame h (list :frame "event" :seq 4 :event "queue_moved" :queue "merge" :id "m2" :to "gating" :why ""))
    (is (= 1 (count "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=))
        "an open pane re-reads ONCE while the ask is in flight")
    (let ((row (find "m2" (getf leticl::*queues* :merges) :key (lambda (r) (getf r :id)) :test #'equal)))
      (is (equal "gating" (getf row :state)) "the state moves")
      (is (equal "restarted" (getf row :evidence)) "**and a move that says nothing keeps the reason we have**"))
    (%sw-reset-queues)))

;;; ------------------------------------------------------- 4. protocol 44 ;;;

(def-test protocol-44-is-claimed-and-the-queues-frame-folds-both-queues (:suite leticl)
  "`+protocol-version+` is 44 and the moves are recorded; the `queues` frame folds into a snapshot with
both queues, the leases, the red target and the moves — and `/queue` asks with the daemon's name."
  (%sw-reset-queues)
  (is (= 44 leticl:+protocol-version+) "the claim")
  (is (search "**44**" (uiop:read-file-string (merge-pathnames "src/protocol/versions.lisp"
                                                               (asdf:system-source-directory :leticl))))
      "and versions.lisp records what 44 is — the pane's number this head now sends")
  (let* ((h (%make-head))
         (wire (%wire h)))
    (leticl::%command h "queue")
    (is (find "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=) "the ask is `ListMergeQueue` still")
    (leticl::%handle-frame h (list :frame "queues" :snapshot (%sw-snapshot)))
    (is (= 3 (length (getf leticl::*queues* :reviews))) "both queues are on the head: the reviews")
    (is (= 2 (length (getf leticl::*queues* :merges))) "and the merges")
    (is (= 2 (length (getf leticl::*queues* :leases))) "the leases")
    (is (equal "red" (getf (first (getf leticl::*queues* :targets)) :state)) "the red target")
    (is (= 1 (length (getf leticl::*queues* :recent))) "and the moves")
    (is (search "review queue holds 3, the merge queue 2" (head-status-note h)) "said: ~s" (head-status-note h))
    ;; the view's rows: the red target's review FIRST, then open rows oldest first, then recent finished
    (is (equal '("r-target" "r1" "r2") (mapcar (lambda (r) (getf r :id)) (head-merge-queue h)))
        "**the red target first, then the open rows, then the finished**: ~s"
        (mapcar (lambda (r) (getf r :id)) (head-merge-queue h)))
    (is (equal "review" (getf (first (head-merge-queue h)) :queue)) "each row knows its queue")
    ;; an unreadable store is said, never drawn as an empty queue
    (leticl::%handle-frame h (list :frame "queues" :snapshot (list :at-ms 5 :unreadable "is locked by another daemon")))
    (is (search "could not be read — is locked" (head-status-note h)) "**`unreadable` is said**: ~s" (head-status-note h))
    (%sw-reset-queues)))

;;; ----------------------------------------------------------- 5. the pane ;;;

(def-test the-queue-pane-draws-both-views-the-lease-the-red-target-and-the-moves (:suite leticl)
  "The pane (R61): emergencies first, the lease with STALE past 90 s, the tab strip, time in the
CURRENT state, the selected row's moves; `/queue review|merge` switches; the edge counts the red target."
  (%sw-reset-queues)
  (let ((h (%make-head)))
    (%wire h)
    (leticl::%handle-frame h (list :frame "queues" :snapshot (%sw-snapshot)))
    (setf leticl::*queues-got-ms* (leticl::internal-real-time-ms))
    (let ((text (%sw-text (leticl::merge-queue-lines h 120))))
      (is (search "EMERGENCY" text) "the red target leads: ~a" text)
      (is (search "`main` is RED at deadbeef01 in leticl" text) "named, with its sha and repo")
      (is (search "leticl served by lab2x1 (pid 4242, abc1234) · heartbeat 2s ago" text) "the fresh lease")
      (is (search "STALE: another daemon takes it over" text) "**and the stale one says STALE** — 200 s is past 90")
      (is (search "[review queue (2)]" text) "the tab strip: review is up, with its open count (waiting + reviewing)")
      (is (search " merge queue (1) " text) "and the merge count beside it")
      (is (search "RED TARGET `main`" text) "the target's review row is marked")
      (is (search "[reviewing] topic-a · 1m in state · leticl · by lab2x1/4242" text)
          "**time in the CURRENT state, the repo and the daemon working it**: ~a" text)
      (is (search "no moves in the recent history" text)
          "the cursor is on the target's row, which has no moves, and that is said: ~a" text))
    ;; the cursor on r1 draws ITS moves
    (setf (head-picker-sel h) 1)
    (let ((text (%sw-text (leticl::merge-queue-lines h 120))))
      (is (search "waiting → reviewing · 1m ago · by lab2x1/4242/1700 — lease taken" text)
          "**the selected row's moves**: ~a" text)
      (is (search "3 row(s) of the pre-split queue are archived" text) "and the archived count"))
    ;; the merge view
    (leticl::%command h "queue merge")
    (is (eq :merge leticl::*queue-view*) "`/queue merge` switches the view")
    (let ((text (%sw-text (leticl::merge-queue-lines h 120))))
      (is (search "[merge queue (1)]" text) "the strip follows")
      (is (search "[gating] topic-b" text) "the gating merge is listed first")
      (is (search "passed cargo test" text) "with its gate steps")
      (is (search "[failed] topic-d" text) "and the failed one after it"))
    (is (search "2 in review · 1 being merged · 2 parked · 1 RED target" (merge-standings-line h))
        "**the edge counts both queues and the red target**: ~s" (merge-standings-line h))
    (%sw-reset-queues)))

(def-test slash-queue-verbs-send-the-daemons-line-or-say-why-not (:suite leticl)
  "`/queue approve|veto|rm|restart ID` sends the SAME slash line the reference's keys send
(`queue VERB ID`); a row the daemon would refuse is said, not sent."
  (%sw-reset-queues)
  (let* ((h (%make-head))
         (wire (%wire h)))
    (leticl::%handle-frame h (list :frame "queues" :snapshot (%sw-snapshot)))
    (%sent wire)
    (leticl::%command h "queue approve r1")
    (let ((slash (find "slash" (%sent wire) :key #'frame-name :test #'string=)))
      (is (equal "queue approve r1" (getf slash :line)) "**the verb is the daemon's slash line**: ~s" slash))
    (leticl::%command h "queue approve m1")
    (is (null (find "slash" (%sent wire) :key #'frame-name :test #'string=)) "a merge row cannot be approved: nothing sent")
    (is (search "a merge row is approved already" (head-status-note h)) "and the reason is said: ~s" (head-status-note h))
    (leticl::%command h "queue restart m2")
    (is (equal "queue restart m2" (getf (find "slash" (%sent wire) :key #'frame-name :test #'string=) :line))
        "a failed merge can be restarted")
    (leticl::%command h "queue rm")
    (is (search "which row?" (head-status-note h)) "a verb with no id asks for one")
    (leticl::%command h "queue veto r-target")
    (is (equal "queue veto r-target" (getf (find "slash" (%sent wire) :key #'frame-name :test #'string=) :line))
        "an open review can be vetoed")
    (%sw-reset-queues)))

(def-test the-queue-pane-rereads-every-five-seconds-while-open (:suite leticl)
  "`tick-queues`, from the loop's tick: an OPEN pane asks again every 5 s; a closed one never."
  (%sw-reset-queues)
  (let* ((h (%make-head))
         (wire (%wire h)))
    (setf (head-mode h) :queue
          leticl::*queues-asked-ms* (- (leticl::internal-real-time-ms) 6000))
    (leticl::tick-queues h)
    (is (= 1 (count "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=)) "six seconds on: one ask")
    (leticl::tick-queues h)
    (is (= 0 (count "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=)) "at once again: none")
    (setf (head-mode h) :normal
          leticl::*queues-asked-ms* (- (leticl::internal-real-time-ms) 6000))
    (leticl::tick-queues h)
    (is (= 0 (count "list_merge_queue" (%sent wire) :key #'frame-name :test #'string=)) "**a closed pane asks nothing**")
    (%sw-reset-queues)))

;;; ------------------------------------------------------ 6. write_targets ;;;

(def-test a-live-decision-carries-its-write-targets (:suite leticl)
  "`DecisionRequested.write_targets` was dropped on the live arm, so the card showed a write's
targets only after a resync."
  (let ((s (head-session (%make-head))))
    (apply-event s (list :seq 1 :event "decision_requested" :req-id "r1" :kind "permission" :call-id "c1"
                         :summary "python fix.py" :options nil :ts 5
                         :write-targets (list (list :path "src/syntax.rs" :unresolved nil))))
    (let ((d (first (leticl::session-open-decisions s))))
      (is (equal "src/syntax.rs" (getf (first (getf d :write-targets)) :path))
          "**the live decision carries its targets**: ~s" d))))

;;; ------------------------------------------------------ 7. compaction ;;;

(def-test compaction-sentences-are-read-by-shape-whatever-the-unit (:suite leticl)
  "The sentences carry a `{unit}` and a `{basis}` now; every arm keyed on ` tokens …` and a deepseek
session's compactions were notes again. The dead ` tokens resident now, was ` arm is gone."
  (let ((f (compaction-facts "compacted: 941290 → 9449 deepseek tokens, on transcript s-1#t15. Nothing of the summary …")))
    (is (eq :compacted (getf f :kind)) "the fork's account, in deepseek tokens")
    (is (= 941290 (getf f :was))) (is (= 9449 (getf f :after)))
    (is (equal "s-1#t15" (getf f :transcript)) "with the transcript: ~s" f))
  (let ((f (compaction-facts "compacted: 500 → 80 ledger tokens (unscaled: no round on deepseek has measured yet), on transcript s-2#t1.")))
    (is (eq :compacted (getf f :kind)) "the unscaled unit, with its parenthesis")
    (is (= 500 (getf f :was))) (is (= 80 (getf f :after)))
    (is (equal "s-2#t1" (getf f :transcript)) "and the transcript past the parenthesis: ~s" f))
  (let ((f (compaction-facts "938669 of 999999 deepseek tokens resident (740000 at the last round + 3000 appended since), leaving less than the 62499 the next turn needs — compacting now.")))
    (is (eq :compacting (getf f :kind)) "the announcement with a basis clause")
    (is (= 938669 (getf f :resident))) (is (= 999999 (getf f :window)))
    (is (= 62499 (getf f :headroom)) "~s" f))
  (let ((f (compaction-facts "compacted: 937686 → 75408 deepseek tokens resident.")))
    (is (eq :compacted (getf f :kind)) "the closing line")
    (is (= 937686 (getf f :was))) (is (= 75408 (getf f :after)))
    (is (null (getf f :transcript)) "with no transcript invented"))
  (is (eq :compacted (getf (compaction-facts "compacted: 1200 deepseek tokens resident before.") :kind))
      "the no-base sentence classifies")
  (is (= 940000 (getf (compaction-facts "compacted from 943000 to 940000 tokens and that is STILL within 62499 of the 999999 window, so …") :after))
      "no-progress still reads")
  (is (null (compaction-facts "compacted: 9449 tokens resident now, was 938669."))
      "**the dead arm is dead** — that sentence is stderr's now"))

(def-test the-queue-codes-are-routine-and-the-two-compaction-codes-are-rows (:suite leticl)
  "`merge_queue_recovered` and `queue_lease_lost` are letibot's routine codes; `compact_half` and
`reseated` are compaction rows when their sentence is readable; `queue_moved` is a known event."
  (is (routine-warning-p (list :code "merge_queue_recovered" :detail "x")) "merge_queue_recovered is routine")
  (is (routine-warning-p (list :code "queue_lease_lost" :detail "x")) "queue_lease_lost is routine")
  (is (member "compact_half" leticl::+compaction-row-codes+ :test #'string=) "compact_half is a row code")
  (is (leticl::compaction-row-p (list :code "reseated"
                                      :detail "re-seated: 8703 tokens of conversation carried onto the new prompt as they are, on transcript s-1#t2."))
      "**`reseated` with the daemon's sentence is a ROW**")
  (is (null (leticl::compaction-row-p (list :code "reseated" :detail "x"))) "and with an unreadable one a note, as before")
  (is (member :queue-moved leticl::+events-not-folded-here+) "the folder knows `queue_moved`"))

(def-test a-settings-frame-sets-the-compaction-sections (:suite leticl)
  "`%fold-settings` is `*compaction-sections*`'s only writer and had no caller; the settings arm calls it."
  (let ((leticl::*compaction-sections* nil)
        (h (%make-head)))
    (leticl::%handle-frame h (list :frame "settings"
                                   :rows (list (list :key "compaction.sections" :value "Objective,Active,Blocked"))))
    (is (equal '("Objective" "Active" "Blocked") leticl::*compaction-sections*)
        "**the daemon's section list lands**: ~s" leticl::*compaction-sections*)))

;;; -------------------------------------------------------- 8. ToolOutcome ;;;

(def-test every-payload-variant-of-tool-outcome-is-in-the-table-or-refused-by-name (:suite leticl)
  "`+outcomes-taking-a-reason+` was `(\"failed\")` against an enum with five payload variants. Read
the enum (`crates/transcript/src/lib.rs`) and check each payload variant is either in
`+outcome-fields+` with the field the daemon wants, or refused by name as one this head cannot build."
  (let* ((path "/home/dead/Projects/letibot/letibot/crates/transcript/src/lib.rs")
         (src (and (probe-file path) (uiop:read-file-string path))))
    (if (null src)
        (skip "letibot's transcript crate is not on this box")
        (let* ((at (search "pub enum ToolOutcome" src))
               ;; from the enum's own `{` onward, so the first variant's brace is the first found
               (body (subseq src (+ 2 (search " {" src :start2 at))
                             (search (format nil "~%}") src :start2 at)))
               (seen 0))
          (is (> (length body) 100) "a plausible enum")
          ;; each `Name {` opens a payload variant; its first `field:` is what a frame must carry
          (loop with i = 0
                for open = (search " {" body :start2 i)
                while open
                do (let* ((line-start (1+ (or (position #\newline body :end open :from-end t) -1)))
                          (name (string-trim " " (subseq body line-start open)))
                          (close (position #\} body :start open))
                          (inner (subseq body open close))
                          (colon (position #\: inner))
                          (field (and colon (string-trim '(#\space #\newline #\tab #\/)
                                                         (let ((s (subseq inner 0 colon)))
                                                           (subseq s (1+ (or (position-if (lambda (c) (member c '(#\space #\newline #\{))) s :from-end t) -1))))))))
                     (setf i (1+ close))
                     (when (and (plusp (length name)) (every (lambda (c) (or (alpha-char-p c))) name))
                       (incf seen)
                       (let* ((snake (string-downcase
                                      (with-output-to-string (o)
                                        (loop for c across name for k from 0
                                              do (when (and (upper-case-p c) (plusp k)) (write-char #\_ o))
                                                 (write-char c o)))))
                              (want (cdr (assoc snake leticl::+outcome-fields+ :test #'string=))))
                         (is (or (and want (equal want field))
                                 (leticl::%outcome-fields-this-head-cannot-build snake))
                             "**`~a` carries `~a`** — the table says ~s and the refusal says ~s"
                             snake field want (leticl::%outcome-fields-this-head-cannot-build snake))))))
          (is (>= seen 5) "the five payload variants were read: ~d" seen)
          (is (equal '("failed" "abstained" "not_run") leticl::+outcomes-taking-a-reason+)
              "and the keys this head supplies are the three a runner here answers")))))
