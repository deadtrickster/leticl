;;;; tests/replay.lisp — the regression net under the 1:1 instrument.
;;;;
;;;; `scripts/compare-1-1` is the measurement and this is the guard on the thing
;;;; that takes it. A comparison is only worth reading if the replay itself is
;;;; honest: the same file has to produce the same bytes, the frame has to be the
;;;; size it was asked for, and the fixtures have to be in the order the daemon
;;;; publishes rather than in row order. Each of those is a check here, because
;;;; each of them, when it broke, made the comparison lie rather than fail.

(in-package #:leticl/tests)

(in-suite leticl)

(defun fixture-dir ()
  (asdf:system-relative-pathname :leticl "tests/fixtures/"))

(defun fixture (name)
  (namestring (merge-pathnames (format nil "~a.jsonl" name) (fixture-dir))))

(defun fixture-names ()
  "Every committed fixture, so a new one is covered the day it lands.

The wildcard is merged onto the DIRECTORY rather than handed to
`system-relative-pathname`, which escapes the `*` — the first version of this
returned an empty list, and every test that walks the fixtures then passed by
running zero checks. A green suite that measured nothing is the failure mode a
fixture-driven net is most exposed to, so: the count is asserted below."
  (let ((names (sort (mapcar #'pathname-name
                             (directory (merge-pathnames "*.jsonl" (fixture-dir))))
                     #'string<)))
    (assert (>= (length names) 9) ()
            "tests/fixtures has ~d files; the fixture walk would test nothing"
            (length names))
    names))

(defun visible-row (row)
  "ROW with the SGR sequences taken out — the text a reader sees."
  (with-output-to-string (s)
    (let ((i 0) (n (length row)))
      (loop while (< i n)
            do (let ((ch (char row i)))
                 (cond ((and (char= ch #\escape) (< (1+ i) n)
                             (char= (char row (1+ i)) #\[))
                        (incf i 2)
                        (loop while (and (< i n)
                                         (not (alpha-char-p (char row i))))
                              do (incf i))
                        (incf i))
                       (t (write-char ch s) (incf i))))))))

(def-test a-replay-answers-the-frame-it-was-asked-for ()
  "The size is a parameter and the row count is exactly it.

The reference's `--no-tty` is `app.screen(100, 40)` — a fixed frame, printed and
gone — and a comparison against a head that answered 39 or 41 rows would be
comparing two different screens and calling the offset a rendering fault."
  (let ((rows (leticl::replay-screen (fixture "hello") :cols 100 :rows 40)))
    (is (= 40 (length rows)))
    (is (every (lambda (r) (<= (length (visible-row r)) 100)) rows)))
  (let ((rows (leticl::replay-screen (fixture "hello") :cols 72 :rows 24)))
    (is (= 24 (length rows)))
    (is (every (lambda (r) (<= (length (visible-row r)) 72)) rows))))

(def-test a-replay-is-deterministic ()
  "Same file in, same bytes out — twice in ONE image.

This is the whole contract `--no-tty` exists for, and it was not free: folding a
`turn_started` reads a wall clock, so the composer's edge said `· 0ms` on one run
and `· 1ms` on the next. `with-replay-globals` freezes the clock and resets every
global a frame reads, and the second call here is what proves the reset covers
them — a fixture that passed alone and failed in a batch would be the worst
possible shape for a regression net."
  (dolist (name (fixture-names))
    (let ((a (leticl::replay-screen (fixture name)))
          (b (leticl::replay-screen (fixture name))))
      (is (equal a b) "~a: two replays of one file differ" name))))

(def-test a-replay-folds-every-envelope-it-is-given ()
  "A blank line is skipped, a malformed line is dropped, the rest fold.

The dropping is the REFERENCE's behaviour (`filter_map(… .ok())`,
letibot-tui.rs:258) and it is copied rather than improved on: a fixture that one
head silently shortens and the other refuses is a comparison of two different
inputs. Worth a test because it is silent — a `usage` with the wrong field names
cost a whole afternoon of `Responding` on a turn that had finished."
  (let ((envs (leticl::replay-envelopes-from-lines
               (list "{\"session_id\":\"s\",\"seq\":1,\"ts\":0,\"event\":\"turn_started\"}"
                     ""
                     "   "
                     "{ not json at all"
                     "{\"session_id\":\"s\",\"seq\":2,\"ts\":0,\"event\":\"turn_finished\"}"))))
    (is (= 2 (length envs)))
    (is (equal "turn_started" (getf (first envs) :event)))
    (is (equal "turn_finished" (getf (second envs) :event)))))

(def-test the-hello-fixture-renders-the-screen-it-always-rendered ()
  "A fixture in, an expected screen out — the smallest possible turn.

One user row, one assistant row, one finished turn. What is asserted is the
VISIBLE text of the body, not the escapes: the styles are what the other strand
is moving, and a golden that failed on every colour change would be deleted
within a day. The shape is what this guards — that a replay still puts the
prompt, the answer and a blank row between them where it puts them."
  (let* ((rows (leticl::replay-screen (fixture "hello") :cols 100 :rows 40))
         (v (mapcar #'visible-row rows)))
    ;; row 0 is the header (`rows >= 6`), row 1 the prompt, row 3 the answer
    (is (search "qwen3-coder-480b" (nth 0 v)))
    (is (search "say hello" (nth 1 v)))
    (is (string= "" (string-trim " " (nth 2 v))))
    (is (string= "Hello." (string-trim " " (nth 3 v))))
    (loop for i from 4 below 36
          do (is (string= "" (string-trim " " (nth i v)))
                 "row ~d should be blank, got ~s" i (nth i v)))
    ;; and the composer's box is still the last three rows
    (is (search "╰" (nth 38 v)))))

(def-test every-fixture-puts-a-tool-finished-before-its-own-row ()
  "The ordering letibot's `docs/tui-testing.md` says is the whole point.

  > The engine invokes every call in a round *before* appending any of that
  > round's result rows, so a `ToolFinished` always precedes its own row's
  > `TranscriptAppended`. A fixture that interleaves them the other way
  > exercises a path the daemon never produces.

This head reads that ordering to carry a call's duration onto its settled card,
so a fixture built the other way round would silently lose the field and the
comparison would report the loss as a rendering difference. Checked over the
COMMITTED files, because those are what the comparison reads — `make-fixture`
being right is not evidence that what is on disk was built by it."
  (dolist (name (fixture-names))
    (let ((finished (make-hash-table :test #'equal))
          (results 0))
      (dolist (env (leticl::replay-envelopes (fixture name)))
        (let ((event (getf env :event)))
          (cond
            ((equal event "tool_finished")
             (setf (gethash (getf env :call-id) finished) t))
            ((equal event "transcript_content")
             (let ((item (getf env :item)))
               (when (equal (getf item :type) "tool_result")
                 (incf results)
                 (is (gethash (getf item :call-id) finished)
                     "~a: the row for call ~a landed before its tool_finished"
                     name (getf item :call-id))))))))
      (is (>= results 0) "~a" name))))

(def-test every-fixture-renders-without-taking-the-head-down ()
  "Every committed fixture, folded and painted, with no render error left behind.

`%render-and-paint` turns a render error into a frame that says so, and a replay
would print that frame instead of the session — a comparison that then reports
forty differing rows and none of them about rendering. `*last-render-error*` is
the head's own record of it, so it is what is asserted rather than the pixels.

This is the check that found the one that mattered: a stored `ToolEditExcerpt`
reached `lang-for` with a yason string, `sb-alien` bound it as a SIMPLE-STRING,
and the process exited. Nothing in this tree had ever fed a real edit excerpt to
the card before there were fixtures."
  (dolist (name (fixture-names))
    (finishes (leticl::replay-screen (fixture name)))
    (multiple-value-bind (rows err) (leticl::replay-screen (fixture name))
      (is (= 40 (length rows)) "~a" name)
      (is (null err) "~a: ~a" name err))))
