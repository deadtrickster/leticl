;;;; tests/sweep-transcript.lisp — the 2026-10-11 sweep's tests for the transcript area (TODO.md, "Sweep 2026-10-11").
(in-package #:leticl/tests)

;;; Each test here fails on the code before the sweep's change it pins; the measurement that
;;; made the rule is in the test's docstring, and the rule itself is in the source beside the
;;; code (`reading-hides-p`, `+reading-never-hides+`, `%diff-panel-lines`, `%sgr-to-style`).

(defun %sweep-edit (&optional (lines 20))
  "An edit excerpt LINES long, every line changed — long enough that a folded diff has to cut."
  (list :path "src/fib.lisp" :created nil
        :before-start 10 :after-start 10
        :before-lines lines :after-lines lines :truncated nil
        :before (format nil "~{l~d~%~}" (loop for i below lines collect i))
        :after (format nil "~{L~d~%~}" (loop for i below lines collect i))))

(defun %sweep-tool-row (id &rest body)
  "A settled `tool_result` item with ID, its body the plist BODY (`:type` supplied)."
  (list :item-id id :kind "tool_result" :ts 0
        :item (list* :type "tool_result" body)))

(defun %sweep-diff-row-count (text)
  "How many DIFF rows TEXT draws — the path row `edit-lines` draws when the header does not name
the file, and the rows carrying a changed `l<n>` line of `%sweep-edit`. The fold counts the path row
as one of its rows, because it IS one of the diff's rows: a `Ran` row's panel keeps the path and
seven lines, an `Edited src/fib.lisp` row's keeps eight lines."
  (count-if (lambda (line)
              (or (search "-l" line) (search "+L" line)
                  (string= "src/fib.lisp" (string-trim " " line))))
            (uiop:split-string text :separator '(#\newline))))

(defun %sweep-seam (text)
  "The `… +N diff rows · …` seam line in TEXT, or NIL."
  (find-if (lambda (line) (search "diff rows" line))
           (uiop:split-string text :separator '(#\newline))))

;;; ------------------------------------------------- B.6: the operator's `!` row ;;;

(def-test an-operator-run-row-is-drawn-at-every-reading-rung (:suite leticl)
  "**Verbosity governs how much of the MODEL's working you see; it must not hide what YOU did**
(letibot `4237b19`). MEASURED there: the operator typed `! ls`, the store held the `tool_result`
with `origin: {operator …}`, and at `read-edits` the listing was never on the screen — *\"i guess
it was eaten by verbosity level\"*. This head's `reading-hides-p` hid the same row, because it asked
only the body's KIND, and a `!` result is a `tool_result` like the model's own.

The control is the same row with no origin — the model's call, and every row written before the
field existed — which the rung hides as it always did."
  (let ((bang (%sweep-tool-row "bang-1" :call-id "bang-1" :name "bash" :subject "ls"
                               :outcome (list :outcome "ok")
                               :payload (format nil "Cargo.toml~%src~%target")
                               :origin (list :operator (list :who "human:dead"))))
        (model (%sweep-tool-row "c-1" :call-id "c-1" :name "bash" :subject "ls"
                                :outcome (list :outcome "ok")
                                :payload (format nil "Cargo.toml~%src~%target"))))
    (dolist (rung '(:reading :read-edits))
      (let ((leticl::*verbosity* rung))
        (is (not (leticl::reading-hides-p bang))
            "~a: the operator's own row is not hidden" rung)
        (is (leticl::reading-hides-p model)
            "~a: the model's call still is — the control" rung)
        (let ((text (segs-of (item-lines bang 80 nil))))
          (is (search "Cargo.toml" text)
              "~a: the listing the operator asked for is on the screen: ~s" rung text)
          (is (search "by human:dead" text)
              "~a: and the row says whose act it was" rung))
        (is (null (item-lines model 80 nil))
            "~a: the model's row draws nothing at this rung" rung)))))

(def-test an-operator-run-row-ends-a-run-and-is-not-counted-into-it (:suite leticl)
  "**The `!` row is the conversation, so it is a VISIBLE row to the run walk**: it ends the run of
hidden work before it and is not one of the `[N tool calls]`. Before the change the walk folded it
in — the operator's listing became one unit of a count on the model's sentence.

One hidden call before the `!` row, so the marker says `[1 tool call` and never `[2`."
  (let ((leticl::*verbosity* :reading) (leticl::*scroll-anchor* nil)
        (leticl::*hist-cache* nil) (leticl::*hist-generation* 0)
        (leticl::*hidden-run-open* nil) (leticl::*marker-seam* t))
    (let ((h (%on-head :cols 100 :rows 40)))
      (setf (head-connected h) t)
      (setf (session-items (head-session h))
            (coerce
             (list (list :item-id "u" :kind "user" :ts 0
                         :item (list :type "user" :parts (list (list :text "run the tests"))))
                   (list :item-id "a1" :kind "assistant" :ts 0
                         :item (list :type "assistant" :text "running them now:"))
                   (%sweep-tool-row "t1" :call-id "c1" :name "bash" :subject "cargo test"
                                    :outcome (list :outcome "ok") :payload "MODEL PAYLOAD")
                   (%sweep-tool-row "bang-1" :call-id "bang-1" :name "bash" :subject "ls"
                                    :outcome (list :outcome "ok")
                                    :payload (format nil "OPERATOR LISTING~%src~%target")
                                    :origin (list :operator (list :who "human:dead")))
                   (list :item-id "a2" :kind "assistant" :ts 0
                         :item (list :type "assistant" :text "all green")))
             'vector))
      (let ((view (segs-of (leticl::%viewport-lines h 100 36))))
        (is (search "OPERATOR LISTING" view) "the operator's listing is drawn: ~s" view)
        (is (not (search "MODEL PAYLOAD" view)) "the model's call is still hidden")
        (is (search "[1 tool call" view)
            "the run before the `!` row is ONE call — the `!` row is not counted into it: ~s" view)
        (is (not (search "[2 tool calls" view)) "and never two")))))

;;; ------------------------------- B.7: the detected diff under `Ran`, and the 8-row rule ;;;

(def-test a-detected-diff-under-ran-follows-the-output-and-says-how-it-was-obtained (:suite leticl)
  "**The output, then the diff, then — folded or open — how the diff was obtained** (letibot
`e09d77c`, `6ba1ede`; `call.rs:236-255`). R35 made the `bash` row draw its detected diff, but the
branch `return-from`ed with the diff ALONE, so the one row whose output explains the change lost
that output the moment the daemon detected a file under it; and nothing on the panel said the
command had made the change rather than an `edit`.

An `edit` verb is the control: its payload is the tool's prose (`wrote`) and the diff is what it
means, so the diff replaces the body and no provenance line is drawn — `edit` made it."
  (let* ((ran (%sweep-tool-row "r1" :call-id "c9" :name "bash" :subject "python3 - <<'PY'"
                               :outcome (list :outcome "ok")
                               :payload (format nil "OUT one~%OUT two~%OUT three")
                               :edit (%sweep-edit)))
         (folded (segs-of (item-lines ran 100 nil)))
         (open (segs-of (item-lines ran 100 (list :show-tools t)))))
    ;; --- the output comes first, then the diff
    (is (search "OUT one" folded) "the command's own output is drawn: ~s" folded)
    (is (and (search "OUT one" folded) (search "-l0" folded)
             (< (search "OUT one" folded) (search "-l0" folded)))
        "and it comes BEFORE the diff, which explains it")
    ;; --- the provenance line, folded AND open
    (is (search leticl::+detected-diff-provenance+ folded)
        "folded, the panel says how its diff was obtained")
    (is (search leticl::+detected-diff-provenance+ open) "and open too")
    (is (search "not made by `edit`" leticl::+detected-diff-provenance+)
        "in the reference's own words")
    ;; --- the fold is the shared rule, and the seam counts what it cut
    (is (= leticl::+diff-fold-rows+ (%sweep-diff-row-count folded))
        "folded keeps `+diff-fold-rows+` diff rows: ~s" folded)
    (is (%sweep-seam folded) "and a seam says how many went")
    (is (> (%sweep-diff-row-count open) leticl::+diff-fold-rows+) "open draws the diff whole")
    (is (null (%sweep-seam open)) "with no seam")
    ;; --- the control: an edit verb's diff IS its body
    (let ((edited (segs-of (item-lines (%sweep-tool-row "e1" :call-id "c8" :name "edit"
                                                        :subject "src/fib.lisp"
                                                        :outcome (list :outcome "ok")
                                                        :payload "wrote"
                                                        :edit (%sweep-edit))
                                       100 nil))))
      (is (not (search "wrote" edited)) "an `edit`'s prose is not drawn under its diff")
      (is (not (search "detected afterwards" edited))
          "and no line says `edit` did not make it: ~s" edited))))

(def-test the-diff-seam-names-the-verb-that-acts-on-its-row (:suite leticl)
  "**R40, one seam down**: the diff seam said `/config unfolds it` on every row, including the one
row `/t` acts on — the lie R40 removed from the payload seam. Both seams on a row now ask one
function, so the newest long row names `/t` and every other names the wall's home."
  (let ((h (%on-head :cols 100 :rows 40)))
    (setf (head-connected h) t)
    (let ((newest (%sweep-tool-row "r-new" :call-id "c9" :name "bash" :subject "python3 - <<'PY'"
                                   :outcome (list :outcome "ok")
                                   :payload (format nil "OUT one~%OUT two~%OUT three")
                                   :edit (%sweep-edit)))
          (older (%sweep-tool-row "r-old" :call-id "c7" :name "bash" :subject "python3 - <<'PY'"
                                  :outcome (list :outcome "ok")
                                  :payload (format nil "OUT one~%OUT two~%OUT three")
                                  :edit (%sweep-edit))))
      (setf (session-items (head-session h)) (coerce (list older newest) 'vector))
      (let ((leticl::*payload-head* h) (leticl::*newest-payload* nil)
            (leticl::*payload-view* nil))
        (let ((seam (%sweep-seam (segs-of (item-lines newest 100 nil)))))
          (is (and seam (search "/t opens it" seam))
              "the newest long row's diff seam names the chord that acts on it: ~s" seam))
        (let ((seam (%sweep-seam (segs-of (item-lines older 100 nil)))))
          (is (and seam (search "/config unfolds it" seam))
              "an older row's names the setting that unfolds the wall: ~s" seam))
        ;; and the window the chord opens unfolds the DIFF too, or the seam lied
        (let ((leticl::*payload-view* (cons "r-new" 0)))
          (is (null (%sweep-seam (segs-of (item-lines newest 100 nil))))
              "with the window open on the row, the diff is whole"))))))

(def-test the-live-card-and-the-settled-row-fold-a-detected-diff-alike (:suite leticl)
  "**The same panel the settled row draws, for the same reason** (`call.rs:375-387`): the card is on
screen until the row's body lands, and a diff that changed shape when the card settled would be the
hand-over flickering — one frame with the change drawn one way and the next another, for one call.
The live card kept its tool BUDGET over the diff — ten head rows, a marker and three tail rows for
an edit; two and three for a `bash` — while the settled row kept eight and a seam.

Both renderers now call `%diff-panel-lines`, so the test is that their diff rows and their seams
agree, for a detected diff under `Ran` and for an `edit`'s own."
  (let ((leticl::*call-facts* nil) (leticl::*item-facts* nil) (leticl::*call-started-ms* nil))
    (dolist (case (list (list "bash" "python3 - <<'PY'" (format nil "OUT one~%OUT two~%OUT three"))
                        (list "edit" "src/fib.lisp" "wrote")))
      (destructuring-bind (name target payload) case
        (let* ((live (segs-of (call-lines (list :call-id "c9" :name name :target target
                                                :state (list :state "finished"
                                                             :outcome (list :outcome "ok")
                                                             :edit (%sweep-edit)))
                                          100 nil)))
               (settled (segs-of (item-lines (%sweep-tool-row "s9" :call-id "c9" :name name
                                                              :subject target
                                                              :outcome (list :outcome "ok")
                                                              :payload payload
                                                              :edit (%sweep-edit))
                                             100 nil))))
          (is (= leticl::+diff-fold-rows+ (%sweep-diff-row-count live))
              "~a: the live card keeps the settled row's eight diff rows, not its tool budget: ~s"
              name live)
          (is (= (%sweep-diff-row-count live) (%sweep-diff-row-count settled))
              "~a: the two renderers keep the same number of diff rows" name)
          (let ((live-seam (%sweep-seam live)) (settled-seam (%sweep-seam settled)))
            (is (and live-seam settled-seam) "~a: both draw a diff seam" name)
            (is (equal (and live-seam
                            (string-left-trim " " (subseq live-seam 0 (search " · " live-seam))))
                       (and settled-seam
                            (string-left-trim " " (subseq settled-seam 0 (search " · " settled-seam)))))
                "~a: and the seams count the same hidden rows: ~s vs ~s" name live-seam settled-seam))
          (is (not (search "… +" (or (find-if (lambda (l) (and (search "… +" l)
                                                                 (not (search "diff rows" l))))
                                              (uiop:split-string live :separator '(#\newline)))
                                     "")))
              "~a: no `head_tail` marker cuts the live diff a second time: ~s" name live)
          (is (eq (and (search "detected afterwards" live) t)
                  (and (search "detected afterwards" settled) t))
              "~a: the provenance line is on both or on neither" name))))))

;;; ------------------------------------------------- B.8: a compaction is one line ;;;

(def-test a-compaction-is-one-line-at-the-reading-rungs (:suite leticl)
  "**One line in the conversation, and the model's record is not it** (letibot `8fb629a`). The
operator: *\"compaction leads to too much noise in the conversation for me. in conversation and
show edits i want a one line - compacted blabla\"*. This head files a compaction as a `compact`
tool row (`note-compaction`), which `+reading-hides+` folded into a `[1 tool call]` count — the
most information-dense event of a long session, counted as a chore.

At the reading rungs the row is kept by name (`+reading-never-hides+`) and drawn as its headline
alone; at the rungs above, the folded shape is unchanged and the record is the payload."
  (is (boundp 'leticl::+reading-never-hides+)
      "the list `events.lisp`'s docstring named exists now")
  (is (member "compact" leticl::+reading-never-hides+ :test #'string-equal)
      "and the compaction is on it")
  (let ((row (%sweep-tool-row "leticl-compaction-1" :call-id "compaction-1" :name "compact"
                              :verb "Compacted" :subject "941,290 → 9,449 tokens"
                              :outcome (list :outcome "ok")
                              :payload (format nil "record line 1~%record line 2~%record line 3"))))
    (dolist (rung '(:reading :read-edits))
      (let ((leticl::*verbosity* rung))
        (is (not (leticl::reading-hides-p row)) "~a: the row is kept" rung)
        (let ((lines (item-lines row 80 nil)))
          (is (= 1 (length lines)) "~a: and it is ONE line: ~s" rung (segs-of lines))
          (is (search "Compacted 941,290 → 9,449 tokens" (segs-of lines))
              "~a: the headline — the verb and the numbers" rung)
          (is (not (search "record line" (segs-of lines)))
              "~a: and nothing of the record" rung))))
    (let ((leticl::*verbosity* :normal))
      (let ((text (segs-of (item-lines row 80 nil))))
        (is (search "record line 1" text) "at the rungs above, the record is the payload, folded")
        (is (search "+2 lines" text) "with its seam")))))

(def-test a-compaction-is-not-counted-into-a-run-of-hidden-work (:suite leticl)
  "The compaction stands between two pieces of hidden work and is DRAWN, so the work before it is
its own run and the compaction is in nobody's count — `[1 tool call`, not `[2`."
  (let ((leticl::*verbosity* :reading) (leticl::*scroll-anchor* nil)
        (leticl::*hist-cache* nil) (leticl::*hist-generation* 0)
        (leticl::*hidden-run-open* nil) (leticl::*marker-seam* t))
    (let ((h (%on-head :cols 100 :rows 40)))
      (setf (head-connected h) t)
      (setf (session-items (head-session h))
            (coerce
             (list (list :item-id "u" :kind "user" :ts 0
                         :item (list :type "user" :parts (list (list :text "go on"))))
                   (list :item-id "a1" :kind "assistant" :ts 0
                         :item (list :type "assistant" :text "checking:"))
                   (%sweep-tool-row "t1" :call-id "c1" :name "bash" :subject "cargo test"
                                    :outcome (list :outcome "ok") :payload "MODEL PAYLOAD")
                   (%sweep-tool-row "leticl-compaction-1" :call-id "compaction-1" :name "compact"
                                    :verb "Compacted" :subject "941,290 → 9,449 tokens"
                                    :outcome (list :outcome "ok")
                                    :payload (format nil "record line 1~%record line 2"))
                   (list :item-id "a2" :kind "assistant" :ts 0
                         :item (list :type "assistant" :text "done")))
             'vector))
      (let ((view (segs-of (leticl::%viewport-lines h 100 36))))
        (is (search "Compacted 941,290 → 9,449 tokens" view) "the compaction's line is drawn: ~s" view)
        (is (not (search "record line" view)) "and not its record")
        (is (search "[1 tool call" view) "the hidden work before it is one call")
        (is (not (search "[2 tool calls" view)) "the compaction is not the second")))))

;;; ------------------------------------------------- B.10: `%sgr-to-style` ;;;

(def-test sgr-bold-red-paints-one-segment-with-a-plist-style (:suite leticl)
  "**`ESC[1;31m` through `%paint-line`, end to end**: the operator's own run carries its colour
(daemon `8a033cc`) and the painter hands `%sgr-to-style`'s answer on as a STYLE. The cards
reviewer (2026-10-11) found it broken three ways — `(push :bold style)` pushed a bare keyword,
`(apply #'append …)` then returned the keyword or signalled, and `39` compared `:fg` to `(:fg)` —
so any bold or dim in a `!` row's output took the frame down. `%paint-line` had no test at all.

And a fourth way, found writing this: `parse-integer` with no `:junk-allowed` signalled on the
colon-separated truecolour form every modern terminal emits."
  (let ((segs (leticl::%paint-line (format nil "~c[1;31mred~c[0m plain" #\Esc #\Esc))))
    (is (= 2 (length segs)) "two segments — the painted word and the plain rest: ~s" segs)
    (is (equal "red" (car (first segs))) "the painted text")
    (is (equal '(:bold t :fg :red) (cdr (first segs)))
        "**its style is ONE plist** — bold and the colour, in order: ~s" (cdr (first segs)))
    (is (null (cdr (second segs))) "the reset leaves the rest unstyled"))
  (is (equal '(:bold t :fg :red) (leticl::%sgr-to-style "1;31")) "the parameters alone")
  (is (null (leticl::%sgr-to-style "31;39")) "and 39 resets the colour it set")
  (finishes (leticl::%sgr-to-style "38:2::255:0:0")
            "a colon-separated parameter is dropped, not signalled on")
  (is (equal '(:bold t) (leticl::%sgr-to-style "1;38:2::255:0:0"))
      "and what was understood around it survives"))

;;; ------------------------------------------------- the review's Cards section ;;;

(def-test the-cards-review-s-dead-code-is-gone-and-item-is-bound-only-where-read (:suite leticl)
  "**The cards reviewer's list (2026-10-11), checked against the tree rather than remembered**:
`raw-call-lines` defined twice identically; `%job-notice-facts` dead and cited as authority;
`awhen-edit-lines` and `%payload-line-count` with no call site; five `card-lines` methods binding
an `item` they never read (a style warning on every build). The source is read, because a symbol
that is merely unbound in this image says nothing about a definition that was deleted."
  (let ((cards (source-of "cards")))
    (flet ((defuns (name)
             (let ((needle (format nil "(defun ~a " name)) (n 0) (start 0))
               (loop for i = (search needle cards :start2 start)
                     while i do (incf n) (setf start (1+ i)))
               n)))
      (is (= 1 (defuns "raw-call-lines")) "`raw-call-lines` is defined once")
      (is (= 0 (defuns "%job-notice-facts")) "`%job-notice-facts` is gone")
      (is (= 0 (defuns "%payload-line-count")) "`%payload-line-count` is gone")
      (is (not (search "(defmacro awhen-edit-lines" cards)) "`awhen-edit-lines` is gone")
      (is (not (search "%job-notice-facts" cards))
          "and nothing cites `%job-notice-facts` as the authority for what a row draws"))
    (dolist (sym '("%JOB-NOTICE-FACTS" "AWHEN-EDIT-LINES" "%PAYLOAD-LINE-COUNT"))
      (let ((s (find-symbol sym :leticl)))
        (is (not (and s (fboundp s))) "~a is not a function in the image" sym)))
    ;; **`item` is bound only by the methods that read it.** The five that did not: system,
    ;; segment-mark, fetched, reasoning, assistant. `user-card` and `note-card` read it (the
    ;; clock, the warning) and keep it.
    (dolist (file '("static-cards" "reasoning-card" "assistant-card"))
      (let ((text (source-of (format nil "cards/~a" file))))
        (is (not (search "(let ((item (card-item card))" text))
            "~a.lisp binds no `item` it never reads" file)))))
