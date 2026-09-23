;;;; tests/tests.lisp — asserts on cell buffers and emitted escape strings
;;;; (PLAN.md §11). Protocol goldens are hand-written from the serde semantics:
;;;; field order is irrelevant to us, presence is not.

(in-package #:leticl/tests)

;;; ------------------------------------------------------------- width ;;;

(def-test width-ascii-is-one (:suite leticl)
  (is (= 1 (char-width #\a)) "ascii")
  (is (= 1 (char-width #\space)) "space")
  (is (= 5 (string-width "hello")) "string"))

(def-test width-control-is-zero (:suite leticl)
  (is (= 0 (char-width (code-char 7))) "bell")
  (is (= 0 (char-width (code-char #x7f))) "del")
  (is (= 0 (char-width (code-char #x85))) "c1 NEL"))

(def-test width-cjk-is-two (:suite leticl)
  (is (= 2 (char-width (code-char #x4e00))) "CJK ideograph")
  (is (= 2 (char-width (code-char #x3042))) "hiragana")
  (is (= 2 (char-width (code-char #xac00))) "hangul")
  (is (= 2 (char-width (code-char #xff21))) "fullwidth A"))

(def-test width-zero-width (:suite leticl)
  (is (= 0 (char-width (code-char #x301))) "combining acute")
  (is (= 0 (char-width (code-char #x200d))) "ZWJ")
  (is (= 0 (char-width (code-char #xfe0f))) "variation selector"))

(def-test width-emoji (:suite leticl)
  (is (= 2 (char-width (code-char #x1f680))) "rocket")
  (is (= 2 (char-width (code-char #x2757))) "heavy exclamation"))

;;; ------------------------------------------------------------- cells ;;;

(def-test put-string-advances-by-width (:suite leticl)
  (let ((s (make-screen 20 1)))
    (is (= 4 (screen-put-string s 0 0 "a漢b")) "a(1) 漢(2) b(1)")
    (is (char= #\a (cell-ch (screen-cell s 0 0))))
    (is (char= (code-char 0) (cell-ch (screen-cell s 0 2))) "wide continuation")
    (is (char= #\b (cell-ch (screen-cell s 0 3))))))

(def-test put-string-wide-at-edge-degrades (:suite leticl)
  (let ((s (make-screen 3 1)))
    ;; "ab漢" — the 漢 would need columns 2 and 3; only 2 exists
    (is (= 3 (screen-put-string s 0 0 "ab漢")))
    (is (char= #\a (cell-ch (screen-cell s 0 0))))
    (is (char= #\b (cell-ch (screen-cell s 0 1))))
    (is (char= #\space (cell-ch (screen-cell s 0 2))) "degraded to space")))

(def-test put-out-of-range-is-dropped (:suite leticl)
  (let ((s (make-screen 4 2)))
    (screen-put s 5 0 #\x)
    (screen-put s 0 9 #\x)
    (is (char= #\space (cell-ch (screen-cell s 0 0))) "nothing written")))

;;; ------------------------------------------------------------ painter ;;;

(def-test paint-diff-blank-to-text (:suite leticl)
  (let ((cur (make-screen 10 2)) (*caret* nil))
    (screen-put-string cur 0 0 "ab")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      ;; move to row1 col1, write "ab", then the trailing reset
      (is (equal (format nil "~C[1;1Hab~C[0m~C[?25l" (code-char 27) (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "one run, one move"))))

(def-test paint-diff-emits-sgr-on-style-change (:suite leticl)
  (let ((cur (make-screen 10 1))
        (*caret* nil)
        (bold-cyan (style-index '(:bold t :fg :cyan))))
    (screen-put cur 0 0 #\x 0)
    (screen-put cur 0 1 #\y bold-cyan)
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      (is (equal (format nil "~C[1;1Hx~C[0;1;36my~C[0m~C[?25l"
                         (code-char 27) (code-char 27) (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "default then bold-cyan"))))

(def-test paint-diff-writes-only-changes (:suite leticl)
  (let ((prev (make-screen 10 1))
        (cur (make-screen 10 1))
        (*caret* nil))
    (screen-put-string prev 0 0 "abcdef")
    (screen-put-string cur 0 0 "abXdef")
    (with-output-to-string (out)
      (paint-diff prev cur out :sync nil)
      ;; with no caret the frame ENDS by hiding the cursor: a terminal that was
      ;; told `?25h` by the last frame must not be left showing one somewhere
      ;; arbitrary, which is wherever the last changed run happened to end
      (is (equal (format nil "~C[1;3HX~C[0m~C[?25l" (code-char 27) (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "only the X moves and writes"))))

(def-test the-caret-is-placed-and-shown-after-the-frame (:suite leticl)
  "The operator: *\"the creepy thing about leticl - prompt input doesnt have caret
or cursor\"*. The head asked for a steady block at startup and hid the cursor, and
no frame ever said where it went. A frame is a run of absolute moves, so the
caret has to be placed AFTER the painting and only then shown."
  (let ((cur (make-screen 10 2))
        (*caret* (cons 1 4)))
    (screen-put-string cur 0 0 "hi")
    (is (search (format nil "~C[2;5H~C[?25h" (code-char 27) (code-char 27))
                (with-output-to-string (out) (paint-diff nil cur out :sync nil)))
        "the move is 1-based and the cursor is shown, last")))

(def-test paint-diff-sync-wraps-in-2026 (:suite leticl)
  (let ((cur (make-screen 4 1)) (*caret* nil))
    (screen-put-string cur 0 0 "hi")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync t)
      (is (equal (format nil "~C[?2026h~C[1;1Hhi~C[0m~C[?25l~C[?2026l"
                         (code-char 27) (code-char 27) (code-char 27) (code-char 27)
                         (code-char 27))
                 (get-output-stream-string out))
          "synchronized output brackets the frame"))))

;;; --------------------------------------------------------------- json ;;;

(def-test json-encode-frame-golden (:suite leticl)
  (is (equal "{\"frame\":\"ack\",\"seq\":3,\"rendered\":1,\"filtered\":2}"
             (json-encode-to-string (list :frame "ack" :seq 3 :rendered 1 :filtered 2)))
      "field order follows the plist, keys snake_case"))

(def-test json-encode-a-nil-key-is-elided-not-nulled (:suite leticl)
  "**A key whose value is NIL is omitted, and that is the only spelling the daemon
always accepts.** This test used to assert the opposite — *\"absent and empty must not
be the same bytes\"* — and the rule it was quoting is the DAEMON's: protocol.lisp's
header says a field whose PRESENCE is the disclosure is written zero/null rather than
omitted, and that is about the frames the daemon SENDS (`dropped`, `created`,
`snapshot`). This encoder writes the client's frames, and on the client side serde has
three field shapes that do not agree about a present null:

  · `Option<T>` — a missing key and a present null both deserialise to `None`;
  · `T` with `#[serde(default)]` — a MISSING key takes the default, a present null is
    an ERROR;
  · a bare `T` — both are errors.

So eliding is never worse and strictly better for the middle case, which is the one
that has cost this head two sockets: `Mode.consented` and `ReseatSession.summarise`
both had to be written `:false` by hand. See `%encode-object`.

**An ARRAY element is not a key** and keeps its null: `[null]` is a value in a
position, and a list element has no absence to fall back to."
  (is (equal "{}" (json-encode-to-string (list :a nil)))
      "a nil-valued key is absent, not null")
  (is (equal "{\"a\":false}" (json-encode-to-string (list :a :false)))
      "and `:false` is how a caller says this nil is a false")
  (is (equal "{\"a\":0}" (json-encode-to-string (list :a 0)))
      "a measured zero is a value like any other")
  (is (equal "{\"a\":\"\"}" (json-encode-to-string (list :a "")))
      "and so is an empty string")
  (is (equal "{\"b\":1}" (json-encode-to-string (list :a nil :b 1)))
      "the keys that remain are still comma-separated")
  (is (equal "{\"a\":[null,1]}" (json-encode-to-string (list :a (list nil 1))))
      "but an array element keeps its null: a list element has no absence"))

(def-test json-encode-keyword-value-is-snake-string (:suite leticl)
  (is (equal "{\"status\":\"in_progress\"}"
             (json-encode-to-string (list :status :in_progress)))
      "enum vocabulary travels as snake_case strings"))

(def-test json-encode-nested-and-arrays (:suite leticl)
  (is (equal "{\"caps\":{\"queue\":1024,\"can_decide\":true},\"rows\":[\"a\",\"b\"]}"
             (json-encode-to-string
              (list :caps (list :queue 1024 :can-decide t) :rows (list "a" "b"))))
      "plist inside, list array outside"))

(def-test json-decode-keys-become-keywords (:suite leticl)
  (let ((p (json-decode "{\"frame\":\"hello\",\"session_id\":\"s-1\",\"dropped\":0}")))
    (is (equal "hello" (getf p :frame)))
    (is (equal "s-1" (getf p :session-id)))
    (is (= 0 (getf p :dropped)))))

(def-test json-round-trip (:suite leticl)
  (let ((frame (list :frame "prompt" :client-request-id "r1" :expected-seq 12
                     :text "héllo 漢")))
    (is (equal frame (json-decode (json-encode-to-string frame)))
        "unicode survives, keys normalize back")))

;;; --------------------------------------------------------------- wire ;;;

(def-test wire-skips-blank-lines (:suite leticl)
  (with-input-from-string (in (format nil "~%~%~a~%" "{\"a\":1}"))
    (multiple-value-bind (line eof) (read-frame in)
      (is (null eof))
      (is (equal "{\"a\":1}" line)))))

(def-test wire-eof-is-detach-not-error (:suite leticl)
  (with-input-from-string (in "")
    (multiple-value-bind (line eof) (read-frame in)
      (is (eq :eof eof) "the second value names the close")
      (is (null line)))))

(def-test wire-crlf-trimmed (:suite leticl)
  (with-input-from-string (in (format nil "{\"a\":1}~a~%" #\return))
    (is (equal "{\"a\":1}" (read-frame in)))))

;;; ------------------------------------------------------------ protocol ;;;

(def-test attach-golden (:suite leticl)
  ;; the version is the CONSTANT's, not a literal: this golden is about the frame's
  ;; SHAPE — defaults, omitted serde-default fields, caps present — and a bump that
  ;; had to be applied here by hand would be a bump somebody forgets
  (is
   (equal
    (format nil "{\"frame\":\"attach\",\"protocol_version\":~d,\"session_id\":\"\",\"since_seq\":0,\"kind\":\"tui\",\"identity\":\"\",\"caps\":{\"queue\":1024,\"can_decide\":true}}"
            +protocol-version+)
    (encode-frame (make-attach)))
   "defaults, serde-default fields omitted, caps present"))

(def-test ack-golden (:suite leticl)
  (is (equal "{\"frame\":\"ack\",\"seq\":7,\"rendered\":3,\"filtered\":4}"
             (encode-frame (make-ack 7 3 4)))))

(def-test prompt-golden (:suite leticl)
  (let* ((frame (let ((*request-counter* 0)) (make-prompt 12 "hello")))
         (json (encode-frame frame)))
    (is (equal "{\"frame\":\"prompt\",\"client_request_id\":\"leticl-1\",\"expected_seq\":12,\"text\":\"hello\"}"
               json))
    (is (equal "leticl-1" (getf frame :client-request-id)))))

(def-test answer-with-pattern-golden (:suite leticl)
  (is
   (equal
    "{\"frame\":\"answer\",\"client_request_id\":\"leticl-2\",\"req_id\":\"d1\",\"option_id\":\"allow_always\",\"pattern\":\"crates/**/*.rs\"}"
    (encode-frame (let ((*request-counter* 1)) (make-answer "d1" "allow_always" "crates/**/*.rs"))))
   "the operator's own glob travels only when given"))

(def-test decode-hello-shape (:suite leticl)
  (let ((hello (decode-frame
                "{\"frame\":\"hello\",\"protocol_version\":18,\"session_id\":\"s-1\",\"head_id\":\"h1\",\"dropped\":0,\"snapshot\":null,\"resumed_from\":null,\"scrubbed\":{\"events\":0,\"items\":0},\"wiring\":{\"endpoint\":\"\",\"model\":\"\",\"dialect\":\"\",\"role\":\"\"},\"sessions\":[]}")))
    (is (equal "hello" (frame-name hello)))
    (is (= 0 (getf hello :dropped)) "present and zero, the disclosure")
    (is (null (getf hello :snapshot)))))

(def-test decode-malformed-keeps-the-line (:suite leticl)
  (is (equal "{\"frame\":\"nope"
             (handler-case (decode-frame "{\"frame\":\"nope")
               (wire-error (e) (wire-error-line e))
               (:no-error () nil)))
      "the offending line is kept"))

(def-test screen-answer-golden (:suite leticl)
  (is
   (equal
    "{\"frame\":\"screen\",\"req_id\":\"q1\",\"cols\":3,\"rows_n\":1,\"rows\":[\"abc\"]}"
    (encode-frame (make-screen-answer "q1" 3 1 (list "abc"))))
   "the size is an argument, and the rows are the rows"))

;;; ------------------------------------------------------------- keys ;;;

(defconstant +esc+ (code-char 27)
  "The ESC character, for building the key sequences the decoder must eat.")

(defun key-from (string)
  "One key event from a string stream — the decoder is transport-agnostic."
  (read-key (make-string-input-stream string)))

(def-test key-char-and-enter (:suite leticl)
  (is (equal (key-from "a") (list :type :char :ch #\a)))
  (is (equal (key-from (string #\return)) (list :type :enter)))
  (is (equal (key-from (string #\tab)) (list :type :tab))))

(def-test key-ctrl (:suite leticl)
  (is (equal (key-from (string (code-char 3))) (list :type :ctrl :ch #\c))
      "ctrl-c is the letter, not the control code"))

(def-test key-csi-arrows (:suite leticl)
  (is (equal (key-from (format nil "~C[A" +esc+)) (list :type :up)))
  (is (equal (key-from (format nil "~C[B" +esc+)) (list :type :down)))
  (is (equal (key-from (format nil "~C[C" +esc+)) (list :type :right)))
  (is (equal (key-from (format nil "~C[D" +esc+)) (list :type :left))))

(def-test key-csi-tildes (:suite leticl)
  (is (equal (key-from (format nil "~C[1~~" +esc+)) (list :type :home)))
  (is (equal (key-from (format nil "~C[3~~" +esc+)) (list :type :delete)))
  (is (equal (key-from (format nil "~C[4~~" +esc+)) (list :type :end)))
  (is (equal (key-from (format nil "~C[5~~" +esc+)) (list :type :page-up)))
  (is (equal (key-from (format nil "~C[6~~" +esc+)) (list :type :page-down))))

(def-test key-application-mode-arrows (:suite leticl)
  (is (equal (key-from (format nil "~COA" +esc+)) (list :type :up))
      "ESC O A — the application cursor keys"))

(def-test key-lone-esc (:suite leticl)
  (is (equal (key-from (string +esc+)) (list :type :esc))
      "silence after ESC means ESC"))

(def-test key-sgr-mouse (:suite leticl)
  (is (equal (key-from (format nil "~C[<0;5;3M" +esc+))
             (list :type :mouse :x 5 :y 3 :button 0 :kind :press))
      "SGR press")
  (is (equal (key-from (format nil "~C[<64;5;3M" +esc+))
             (list :type :mouse :x 5 :y 3 :kind :wheel-up))
      "SGR wheel"))

(def-test key-bracketed-paste (:suite leticl)
  (is (equal (key-from (format nil "~C[200~~hello~C[201~~" +esc+ +esc+))
             (list :type :paste :text "hello"))
      "the paste is one key event, terminator consumed"))

(def-test markdown-structure (:suite leticl)
  "The block model, to the reference's shapes (`render_block_with`)."
  (let ((lines (markdown-lines "# Title
- item one
```lisp
(+ 1 2)
```
> quoted
plain" :width 80)))
    ;; a heading keeps its hashes, faint, and colours the text by level
    (is (equal (first lines) (list (cons "#" '(:dim t)) (cons " " nil)
                                   (cons "Title" '(:bold t :fg :cyan))))
        "heading: faint hash, then the text in Role::Heading")
    (is (null (second lines)) "blocks are separated by one blank row")
    (is (member (cons "· " '(:dim t)) (third lines) :test #'equal)
        "the bullet is `·`, faint: it marks the indent and is not read")
    (is (equal "┌─ lisp" (car (first (fifth lines))))
        "the fence OPENS, naming the language")
    (is (equal "│ " (car (first (sixth lines))))
        "and every line of code carries its rail")
    (is (equal "└─" (car (first (seventh lines)))) "and it CLOSES")
    (is (member (cons "│ " '(:dim t)) (ninth lines) :test #'equal)
        "the quote's rail is the faint one, the same weight as the fence's frame")
    (is (equal "plain" (car (first (nth 10 lines)))) "and the paragraph")
    (is (= 11 (length lines)) "five blocks, four separators, eleven rows")))

(def-test todos-screen (:suite leticl)
  "The pane draws the ITEMS, rolls them up the way org does, and reports the
cursor's line.

It used to draw one line per `## ` heading and stop — `Phase 0 — repo — 0 open,
2 done` — and the items are the queue. The operator: *\"our todo pane doesnt
render them - only section titles and sub todos count. make sure it follows org
mode - subtodos shown, when all subtodos checked section becomes also checked\"*."
  (flet ((line-text (line)
           (if (null line) "" (format nil "~{~a~}" (mapcar #'car line)))))
    (let* ((dir-pathname (make-pathname :name nil :type nil
                                        :directory '(:absolute "tmp" "leticl-todos-test")))
           (dir "/tmp/leticl-todos-test")
           (path (make-pathname :name "TODO" :type "md"
                                :directory (pathname-directory dir-pathname)))
           (head (%make-head)))
      (unwind-protect
           (progn
             (ensure-directories-exist dir-pathname)
             (with-open-file (out path :direction :output
                                  :if-does-not-exist :create :if-exists :supersede)
               (format out "# TODO~%~%## Alpha~%~%~%- [ ] one~%~%- [x] two~%~%~%## Beta~%~%~%- [x] three~%~%- [x] four~%~%~%## Empty~%~%Some prose and no checkboxes.~%"))
             ;; the reader: items nested under their heading, with org's roll-up
             (let ((rows (read-todo-md (uiop:read-file-string path))))
               (flet ((find-row (needle)
                        (find-if (lambda (r) (search needle (getf r :text))) rows)))
                 (let ((alpha (find-row "Alpha")))
                   (is (not (null alpha)) "the heading is a row")
                   (is (eq :doing (getf alpha :mark))
                       "1 of 2 done is STARTED, not done — org's rule")
                   (is (search "[1/2]" (getf alpha :text)) "with org's cookie")
                   (is (null (getf alpha :item)) "a heading is not an item"))
                 (let ((beta (find-row "Beta")))
                   (is (eq :done (getf beta :mark))
                       "every child done makes the parent done")
                   (is (search "[2/2]" (getf beta :text))))
                 (let ((empty (find-row "Empty")))
                   (is (not (null empty)) "a section with no checkboxes is still a row")
                   (is (null (getf empty :mark))
                       "and gets NO mark — an empty section is one nobody filled in")
                   (is (not (search "[" (getf empty :text)))
                       "and no cookie, so it cannot read as finished work"))
                 (is (not (null (find-row "one"))) "the items are drawn")
                 (is (eq :open (getf (find-row "one") :mark)))
                 (is (eq :done (getf (find-row "two") :mark)))
                 (is (getf (find-row "one") :item)
                     "an item is an ITEM — the mark cannot tell them apart, since a heading carries its roll-up as one")
                 (is (= 8 (getf (find-row "one") :indent))
                     "an item is indented under its heading")))
             ;; `###` owns its own items, being a subsection in org's outline
             (let ((rows (read-todo-md (format nil "## Top~%~%- [x] t~%~%### Sub~%~%- [ ] s~%"))))
               (is (eq :done (getf (find-if (lambda (r) (search "Top" (getf r :text))) rows) :mark))
                   "Top is done by its own one item")
               (is (eq :open (getf (find-if (lambda (r) (search "Sub" (getf r :text))) rows) :mark))
                   "and Sub is open by ITS own, not folded into Top"))
             ;; an item's DETAIL is kept, which it used to be thrown away
             (let ((rows (read-todo-md (format nil "## S~%~%- [ ] item one~%    pin: abc123~%    Deps: T2~%~%- [ ] item two~%"))))
               (let ((one (find-if (lambda (r) (search "item one" (getf r :text))) rows)))
                 (is (= 2 (length (getf one :body)))
                     "the indented lines under an item are its detail")
                 (is (search "pin: abc123" (first (getf one :body)))
                     "kept whole, not cut off at the first line"))
               (let ((two (find-if (lambda (r) (search "item two" (getf r :text))) rows)))
                 (is (null (getf two :body)) "and an item without detail has none")))
             ;; a BLANK line closes an item, so prose does not attach to it
             (let ((rows (read-todo-md (format nil "## S~%~%- [ ] item~%~%prose at column zero~%"))))
               (is (null (getf (find-if (lambda (r) (search "item" (getf r :text))) rows) :body))
                   "column-zero prose is not an item's detail"))
             ;; the pane itself: the plan, marks, and the repo below it
             (setf (session-todos (head-session head))
                   (list (list :content "first" :status "pending")
                         (list :content "second" :status "in_progress")
                         (list :content "third" :status "completed"))
                   (session-wiring (head-session head))
                   (list :workspace dir))
             (multiple-value-bind (lines sel-line) (todos-lines head 80)
               (is (search "todos" (line-text (first lines)))
                   "the pane names itself, and its hint, on the first row")
               (is (some (lambda (l) (search "[ ] first" (line-text l))) lines)
                   "pending mark")
               (is (some (lambda (l) (search "[~] second" (line-text l))) lines)
                   "in-progress mark")
               (is (some (lambda (l) (search "[x] third" (line-text l))) lines)
                   "completed mark")
               (is (some (lambda (l) (search "Alpha" (line-text l))) lines)
                   "the repo's TODO.md is in the pane")
               (is (some (lambda (l) (search "one" (line-text l))) lines)
                   "and so are its ITEMS, which is the whole of P42")
               (is (integerp sel-line) "and the cursor's line comes back")
               (is (search "Alpha" (line-text (nth sel-line lines)))
                   "pointing at the repo's first row — the cursor walks the repo's items, as the reference's does, not the session's plan")))
        (ignore-errors (delete-file path))))))

(def-test decision-card (:suite leticl)
  (flet ((lines-text (lines)
           (format nil "~{~a~^~%~}"
                   (mapcar (lambda (l)
                             (if l (format nil "~{~a~}" (mapcar #'car l)) ""))
                           lines))))
    (let ((head (%make-head)))
      (setf (session-open-decisions (head-session head))
            (list (list :req-id "r1" :kind "permission" :summary "run rm -rf"
                        :target "/tmp" :detail "deletes files"
                        :options (list (list :label "allow") (list :label "deny")))))
      (let ((text (lines-text (decision-card-lines head 80))))
        (is (search "permission" text) "the kind is shown")
        (is (search "run rm -rf" text) "the summary is shown")
        (is (search "allow" text) "the options are shown")
        (is (search "deny" text) "both options are shown")))))

(def-test quit-card (:suite leticl)
  (flet ((lines-text (lines)
           (format nil "~{~a~^~%~}"
                   (mapcar (lambda (l)
                             (if l (format nil "~{~a~}" (mapcar #'car l)) ""))
                           lines))))
    (let ((head (%make-head)))
      (setf (head-quit-open head) t)
      (let* ((lines (quit-card-lines head 80))
             (text (lines-text lines)))
        ;; the reference's shape: a title, then each choice over its consequence
        (is (search "leave — and what happens to the daemon" text) "the title")
        (is (search "▸  1  leave this head" text) "the first choice, picked")
        (is (search "   2  leave and stop the daemon" text) "the second, not")
        (is (search "the daemon keeps running" text) "and what each does, under it")))))

(def-test secret-card (:suite leticl)
  (flet ((lines-text (lines)
           (format nil "~{~a~^~%~}"
                   (mapcar (lambda (l)
                             (if l (format nil "~{~a~}" (mapcar #'car l)) ""))
                           lines))))
    (let ((head (%make-head)))
      (setf (head-secret-req head)
            (list :req-id "s1" :prompt "password" :command "sudo apt install x"))
      (let ((text (lines-text (secret-card-lines head 80))))
        (is (search "sudo apt install x" text) "the command is shown")
        (is (search "password" text) "the prompt is shown")))))

(def-test picker-rows (:suite leticl)
  (flet ((lines-text (lines)
           (format nil "~{~a~^~%~}"
                   (mapcar (lambda (l)
                             (if l (format nil "~{~a~}" (mapcar #'car l)) ""))
                           lines))))
    (let ((session (make-session)))
      (setf (session-session-id session) "s-current"
            (session-sessions session)
            (list (list :session-id "s-current" :title "current")
                  (list :session-id "s-other" :title "other")))
      (let ((lines (picker-lines session 0 80)))
        (is (= 9 (length lines))
            "title, blank, two lines per session, blank, two closing hints")
        (let ((text (lines-text lines)))
          (is (search "current" text) "the current session is shown")
          (is (search "other" text) "the other session is shown")
          (is (search "▸  1  current" text) "the cursor's mark is what Enter takes")
          (is (search "      s-other" text) "and the full id sits under every row"))))))

(def-test ack-seq-round-trips-the-wire (:suite leticl)
  (for-all ((n (gen-integer :min 0 :max 1000000)))
    (is (= n (getf (decode-frame (encode-frame (make-ack n 1 0))) :seq))
        "seq survives encode/decode at the protocol boundary")))

(def-test printable-ascii-is-one-column (:suite leticl)
  (for-all ((i (gen-integer :min 32 :max 126)))
    (is (= 1 (char-width (code-char i)))
        "every printable ASCII char is one column")))

;;; --------------------------------------------------------- highlight ;;;

(def-test role-style-maps-indices (:suite leticl)
  "The role index → style table; 0 and unknown are plain (nil)."
  (is (null (role-style 0)) "plain")
  (is (equal (role-style 1) '(:dim t)) "comment")
  (is (equal (role-style 2) '(:fg :green)) "string")
  ;; the REFERENCE's slots (style.rs:203-211): a number is 33 and a function
  ;; name 34, not their bright cousins — a bright slot is a different palette
  ;; entry in every terminal theme, so the same Rust rendered two colours in two
  ;; panes of one screen
  (is (equal (role-style 3) '(:fg :yellow)) "number — NumberLit, 33")
  (is (equal (role-style 4) '(:fg :cyan)) "type — TypeName, 36")
  (is (equal (role-style 5) '(:fg :magenta)) "keyword — Keyword, 35")
  (is (equal (role-style 6) '(:fg :blue)) "function — FuncName, 34")
  (is (null (role-style 99)) "unknown is plain"))

(def-test highlight-degrades-without-lang (:suite leticl)
  "lang 0 gives one plain segment per line, shim or no shim."
  (let* ((lines (highlight-lines "fn main() {}" 0))
         (line (first lines))
         (seg (first line)))
    (is (= 1 (length lines)) "one line")
    (is (= 1 (length line)) "one segment")
    (is (string= "fn main() {}" (car seg)) "text intact")
    (is (null (cdr seg)) "plain style")))

(def-test highlight-rust-roles (:suite leticl)
  "With the shim, a Rust snippet gets keyword/number/comment roles.

The `skip` is the whole body's alternative, not a statement before it: fiveam's
`skip` RECORDS a skipped result and returns, it does not abort the test, so the
assertions below used to run anyway on a box with no `.so` and fail three times
over. (`skip` was also never imported into this package, so the same line died
with `The function LETICL/TESTS::SKIP is undefined`.) This file's contract is
that every highlight test passes with no shim present; it did not."
  (if (not (hl-available-p))
      (skip "the rano shim is not built")
      (let* ((src (format nil "fn main() {~%    let x = 42; // c~%}"))
             (lines (highlight-lines src (lang-for "a.rs"))))
        (is (= 3 (length lines)) "three lines")
        (is (some (lambda (s) (and (string= "fn" (car s))
                                   (equal (cdr s) '(:fg :magenta))))
                  (first lines)) "fn is a keyword")
        (is (some (lambda (s) (and (string= "42" (car s))
                                   (equal (cdr s) '(:fg :yellow))))
                  (second lines)) "42 is a number")
        (is (some (lambda (s) (and (string= "// c" (car s))
                                   (equal (cdr s) '(:dim t))))
                  (second lines)) "// c is a comment"))))

(defun repo-file (relative)
  "The text of a file in the repo, for a test that asserts on SOURCE.

`source-of` below does the same for `src/*.lisp` and is defined further down the
file; this one takes any path, because the alien boundary's guard has to agree
with what RANO.md says about it and that is not a Lisp file."
  (let ((p (merge-pathnames relative
                            (uiop:pathname-directory-pathname
                             (or *load-truename* #p"./")))))
    (uiop:read-file-string
     (if (probe-file p)
         p
         (merge-pathnames relative #p"/home/dead/Projects/leticl/")))))

(defun occurrences (needle haystack)
  "How many times NEEDLE appears in HAYSTACK, non-overlapping."
  (loop with n = 0 with at = 0
        for i = (search needle haystack :start2 at)
        while i do (incf n) (setf at (+ i (length needle)))
        finally (return n)))

(def-test the-alien-call-pins-the-vectors-it-hands-over (:suite leticl)
  "MEASURED: `sb-sys:vector-sap` on two Lisp vectors, unpinned, across the FFI.

`%class-grid-uncached` hands the shim the raw addresses of a byte vector to read
and a grid vector to WRITE, and SBCL's collector moves objects. Without
`sb-sys:with-pinned-objects` a collection during the call may relocate either,
and what that buys is not a crash: it is the shim writing role indices into
whatever Lisp object was moved into that memory — silent heap corruption
discovered somewhere else entirely, which is the class of bug this head has
already died of once. `RANO.md` documented an allocation strategy
(`sb-alien:make-alien`) the code did not use, so the note said the boundary was
safe when it was not.

A source assertion, in the shape of `live-state-tables-are-defvar` above: the
failure is a race, so there is no input that reproduces it on demand, and the
only honest test is that the guard is lexically around the call."
  (let* ((src (repo-file "src/highlight.lisp"))
         (pin (search "(sb-sys:with-pinned-objects" src))
         (sap (search "(sb-sys:vector-sap" src)))
    (is (not (null pin)) "the shim call pins its vectors")
    (is (and pin sap (< pin sap))
        "and the pinning form OPENS before the first SAP is taken — a SAP computed
outside it is already the wrong answer by the time the form is entered")
    (is (= 2 (occurrences "(sb-sys:vector-sap" src))
        "both vectors cross the boundary, and both are inside the one form")
    (is (search "with-pinned-objects" (repo-file "RANO.md"))
        "and RANO.md says so too, so the note and the code agree")))

(def-test the-highlight-grid-is-memoised-on-its-bytes (:suite leticl)
  "MEASURED: one `hl_grid` call per visible fence per frame, at 10 Hz.

The head rebuilds the whole viewport every frame, so every visible fence and
every visible diff panel paid a full tree-sitter parse for bytes that had not
changed. `class-grid` is the one cache in this renderer with no invalidation
problem: the grid is a pure function of `(lang-id, source)` and both are in the
key, so a stale entry cannot exist — a changed fence is a different key.

The assertion is the shim call COUNTER, not the answer: the answer is the same
with or without the memo, which is precisely why a test on the answer would not
have caught this."
  (hl-memo-clear)
  (if (hl-available-p)
      (let ((src (format nil "fn main() {~%    let x = 42;~%}"))
            (id (lang-for "a.rs")))
        (let ((before *hl-grid-calls*))
          (let ((a (class-grid src id)))
            (is (= (1+ before) *hl-grid-calls*) "a cold grid reaches the shim once")
            (let ((b (class-grid src id)))
              (is (= (1+ before) *hl-grid-calls*)
                  "and the same bytes again do not reach it at all")
              (is (eq a b) "the second caller gets the first caller's grid"))))
        ;; end to end, through the path the fences actually take
        (let ((before *hl-grid-calls*))
          (highlight-fence (list "let x = 1;") "rust")
          (highlight-fence (list "let x = 1;") "rust")
          (is (= (1+ before) *hl-grid-calls*)
              "a fence drawn twice is parsed once — this is what the frame loop was
paying for")))
      (is (null (class-grid "fn main() {}" 1))
          "no shim, no grid, and no call to count — the degrade path is the contract"))
  ;; the bound, which holds with or without a shim because it is arithmetic
  (is (> +hl-memo-max-chars+ 0) "a source past this size is not memoised at all")
  (is (> +hl-memo-entries+ 0) "and the table is dropped whole past this many")
  (when (hl-available-p)
    (hl-memo-clear)
    (loop for i from 0 below (* 3 +hl-memo-entries+)
          do (class-grid (format nil "let x~a = ~a;" i i) (lang-for "a.rs")))
    (is (<= (hash-table-count leticl::*hl-memo*) +hl-memo-entries+)
        "a fence is arbitrary size and a transcript is arbitrarily long: an
unbounded memo is a leak with a nicer name"))
  (hl-memo-clear))

;;; -------------------------------------------------------------- diff ;;;

(defun diff-lines-text (lines)
  "Segment lines to one string, for asserting on the rendered diff."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))

(defun diff-line-width (line)
  "Display width of one segment line."
  (reduce #'+ (mapcar (lambda (seg) (string-width (car seg))) line)))

(def-test diff-identical-has-no-hunks (:suite leticl)
  (let ((a (list "one" "two" "three")))
    (let ((d (diff-lines a a)))
      (is (null (hunks d 3)) "no hunks")
      (is (every (lambda (op) (eq (first op) :equal)) (diff-ops d)) "all equal"))))

(def-test diff-script-reconstructs-the-files (:suite leticl)
  "The property that makes a diff trustworthy: apply it and you get `new`;
delete the insertions and you get `old` back."
  (let ((cases (list (list (list "a" "b" "c") (list "a" "x" "c"))
                     (list (list "a" "b" "c") (list "a" "b" "c" "d"))
                     (list nil (list "a" "b"))
                     (list (list "a" "b") nil)
                     (list (list "a" "b" "c" "d" "e") (list "e" "d" "c" "b" "a"))
                     (list (list "one" "two") (list "one" "two")))))
    (dolist (case cases)
      (let* ((old (first case))
             (new (second case))
             (d (diff-lines old new)))
        (is (equal (apply-diff-to-new (diff-ops d) (or new #())) new)
            "apply gives the new file")
        (is (equal (apply-diff-to-old (diff-ops d) (or old #())) old)
            "the inverse gives the old file")))))

(def-test diff-large-file-is-cheap-and-local (:suite leticl)
  (let ((old (loop for i from 0 below 5000 collect (format nil "line ~a" i)))
        (new (loop for i from 0 below 5000
                   collect (if (= i 2500) "line 2500 CHANGED" (format nil "line ~a" i)))))
    (let ((d (diff-lines old new)))
      (is (not (diff-degraded d)) "not degraded")
      (let ((hs (hunks d 3)))
        (is (= 1 (length hs)) "one hunk")
        (is (= 8 (length (getf (first hs) :rows))) "3 context each side plus - and +")))))

(def-test diff-unrelated-files-degrade-not-stall (:suite leticl)
  (let ((old (loop for i from 0 below 3000 collect (format nil "aaa ~a" i)))
        (new (loop for i from 0 below 3000 collect (format nil "bbb ~a" (* i 7)))))
    (let ((d (diff-lines-with old new 64)))
      (is (diff-degraded d) "the cap must be reachable")
      (is (= 6000 (length (diff-ops d))) "and it is still a valid script"))
    (let ((out (render-diff old new :width 100)))
      (is (search "gave up" (diff-lines-text out)) "the degradation is announced"))))

(def-test diff-renamed-variable-highlights-only-the-name (:suite leticl)
  (multiple-value-bind (os ns) (word-spans "    let total = a + b;" "    let sum = a + b;")
    (is (not (null os)) "similar lines must pair")
    (is (= 1 (length os)) "one span in the old line")
    (is (string= "total" (subseq "    let total = a + b;"
                                 (first (first os)) (second (first os))))
        "the span is 'total'")
    (is (string= "sum" (subseq "    let sum = a + b;"
                               (first (first ns)) (second (first ns))))
        "the span is 'sum'")))

(def-test diff-intra-line-emphasis-reaches-the-screen (:suite leticl)
  "MEASURED: the word highlight was dead code — correct, tested, and unreachable.

`%pair-rows` bound `add-start` AND `add-end` to `i` AFTER consuming the addition
run, where `pair_rows` (`diff.rs:555`) binds `add_start` BEFORE the loop at
`:556-558`. So `(= add-end add-start)` was true on every hunk, the pairing branch
was never taken, `%pair-rows` returned a vector of all NIL, and nothing
`word-spans`, `%merge-spans`, `%emphasize` or `+diff-emphasis+` computed could
ever reach a segment. `diff-renamed-variable-highlights-only-the-name` above
passes either way, which is exactly why this survived: it tests `word-spans` in
isolation, one level below the wiring. This test is one level up, on the emitted
segments, and it is the whole proof."
  (let ((rows (render-diff (list "    let total = a + b;")
                           (list "    let sum = a + b;")
                           :width 60 :intra-line t)))
    (is (find (cons "total" '(:bg 52 :bold t :underline t))
              (first rows) :test #'equal)
        "the removed line emphasises the word that changed, and only it")
    (is (find (cons "sum" '(:bg 22 :bold t :underline t))
              (second rows) :test #'equal)
        "and so does the added line")
    ;; **The run beside the word, not a word-shaped segment of it.** `wrap-segments`
    ;; merges the pieces a break decision did not separate, so the emphasis is the
    ;; only segment on the row carrying an attribute: before the merge this asked for
    ;; `(cons "a " '(:bg 52))`, which was an artifact of the wrapper splitting every
    ;; word into its own segment.
    (is (find-if (lambda (seg) (and (equal '(:bg 52) (cdr seg))
                                    (search "= a + b;" (car seg))))
                 (first rows))
        "the unchanged run beside it keeps the plain role background"))
  (is (null (find-if (lambda (seg) (getf (cdr seg) :underline))
                     (apply #'append
                            (render-diff (list "    let total = a + b;")
                                         (list "    let sum = a + b;")
                                         :width 60 :intra-line nil))))
      "and `:intra-line nil` still emits none — which is what BOTH reference call
sites ask for (`app.rs:8817,9934` pass `intra_line: false`), so the flag is the
decision and the wiring is not")
  ;; the pairing itself, one level below the segments
  (let ((paired (leticl::%pair-rows (list '(:removed 0) '(:added 0))
                                    (vector "    let total = a + b;")
                                    (vector "    let sum = a + b;"))))
    (is (not (null (aref paired 0))) "the removal is paired with the addition")
    (is (not (null (aref paired 1))) "and the addition with the removal")))

(def-test diff-unrelated-lines-are-not-word-highlighted (:suite leticl)
  "Otherwise the whole line is emphasis, which is the same as none."
  (multiple-value-bind (os ns) (word-spans "let total = a + b;" "impl Display for Widget {}")
    (declare (ignore ns))
    (is (null os) "not similar enough to pair")))

(def-test diff-tabs-are-expanded-before-measuring (:suite leticl)
  (is (string= "    if x {" (expand-tabs (format nil "~c~c~c~c~c~c~c"
                                                 #\tab #\i #\f #\space #\x #\space #\{)
                                         4))
      "a leading tab to the first stop")
  (is (string= "ab  c" (expand-tabs (format nil "~c~c~c~c" #\a #\b #\tab #\c) 4))
      "a mid tab")
  (is (= 5 (string-width (expand-tabs (format nil "~c~c~c" #\a #\tab #\b) 4)))
      "width after expand"))

(def-test diff-rendering-respects-width-and-row-cap (:suite leticl)
  (let ((old (loop for i from 0 below 200 collect (format nil "old line number ~a" i)))
        (new (loop for i from 0 below 200 collect (format nil "new line number ~a" i))))
    (let ((out (render-diff old new :width 40 :max-rows 20)))
      (dolist (l out)
        (is (<= (diff-line-width l) 40) "no line over the width"))
      (is (some (lambda (l) (search "more diff lines not shown"
                                    (format nil "~{~a~}" (mapcar #'car l))))
                out)
          "the cap must disclose what it dropped"))))

(def-test diff-painting-does-not-change-the-text (:suite leticl)
  (let ((old (list "    let total = a + b;" "keep"))
        (new (list "    let sum = a + b;" "keep")))
    (let ((text (diff-lines-text (render-diff old new :width 200))))
      (is (search "let total = a + b;" text) "the old line is intact")
      (is (search "let sum = a + b;" text) "the new line is intact"))))

(def-test diff-excerpt-is-numbered-from-where-it-starts (:suite leticl)
  "An excerpt of lines 310..314 must be numbered 310..314, not 1..5: the pair
a finished edit carries is a window, and a diff numbered from 1 tells the
reader line 4 changed when it was line 313.

And ONE column, carrying the line's number in its own file — the old file's on a
deletion, the new file's on an addition. Both rows here are line 311 of the file
they came from, so a two-column gutter would print `311` in one column and a blank
in the other on BOTH of them."
  (let ((old (list "a" "b" "c"))
        (new (list "a" "B" "c")))
    (let ((text (diff-lines-text
                 (render-diff old new :width 80 :context 1 :line-numbers t
                              :intra-line nil :old-start 310 :new-start 310))))
      (is (search "311 -b" text) "the removed line, numbered from the OLD file")
      (is (search "311 +B" text) "the added line, numbered from the NEW file")
      (is (search "310  a" text) "and a context row carries the old file's number")
      (is (null (search " 1 " text)) "not numbered from 1")
      (is (null (search "311     " text))
          "no blank half-gutter: the collapse is the whole point"))))

(def-test the-unified-gutter-is-one-column (:suite leticl)
  "The property, measured on a line long enough to show the difference.

`numw` spans both files' numbering (three columns here), and one column is drawn
per row, right-aligned, then one space, then the sign. The body gets
`width - (numw + 1) - 1` columns — so at width 40 a 35-column body fits — and a
TWO-column gutter would leave only 31.

Asserting the row's total width would not distinguish the shapes: both fill the
width, they just show different amounts of CODE. So the assertion is how much
content is visible."
  (let* ((long-line (make-string 60 :initial-element #\x))
         (old (list "a" long-line "c"))
         (new (list "a" "B" "c"))
         (rows (render-diff old new :width 40 :context 3 :line-numbers t
                            :intra-line nil :old-start 310 :new-start 310))
         (context (find-if (lambda (r) (search "xxx" (format nil "~{~a~}" (mapcar #'car r))))
                           rows)))
    (is (not (null context)) "the long context line is drawn")
    (is (= 40 (leticl::%segs-width context))
        "the row fills the width it was given")
    ;; **How much CODE is visible**, which is the only thing that distinguishes the
    ;; two shapes: both fill the width, they just show different amounts of the
    ;; line. Counting the row's width passes for either — measured, which is how
    ;; the first version of this test failed to fail.
    (let* ((text (format nil "~{~a~}" (mapcar #'car context)))
           (xs (length (remove-if-not (lambda (c) (char= c #\x)) text))))
      (is (= 35 xs)
          "35 columns of code: gutter (3 + 1) + sign (1) from 40, and a two-column
gutter would show 31")
      (is (not (= 31 xs)) "which is the shape the requirement collapses"))))

(def-test deletions-precede-additions-in-a-change-region (:suite leticl)
  "THE INVARIANT `%pair-rows` WALKS, and the reason it is written down.

`%pair-rows` (`src/diff.lisp`) pairs a run of `:removed` rows with the run of
`:added` rows immediately after it, positionally — the k-th removal with the k-th
addition — and that pairing is what the intra-line emphasis is drawn from. It
scans with two consecutive `while` loops, so an INTERLEAVED region (`-a +b -c +d`)
would stop its second loop early and pair the wrong lines, or none.

So the order is not a style: it is what the emphasis walks. Asserted on the rows
themselves, in every shape a change region takes."
  (flet ((kinds (old new)
           (loop for h in (hunks (diff-lines (coerce old 'vector)
                                             (coerce new 'vector))
                                 3)
                 append (mapcar #'first (getf h :rows)))))
    (dolist (case (list (cons "a replacement" (list (list "a" "b" "c") (list "a" "B" "c")))
                        (cons "a whole-file replacement" (list (list "a" "b" "c") (list "X" "Y" "Z")))
                        (cons "2 removed, 1 added" (list (list "a" "b" "c" "d") (list "a" "Z" "d")))
                        (cons "1 removed, 2 added" (list (list "a" "b" "d") (list "a" "Y" "Z" "d")))
                        (cons "two regions" (list (list "a" "b" "c" "e" "f")
                                                  (list "a" "X" "c" "Y" "f")))))
      (let ((ks (kinds (first (cdr case)) (second (cdr case)))))
        ;; no `:added` may be followed later by a `:removed` inside one region:
        ;; the first transition added → removed means the runs were interleaved
        (is (not (loop for (a b) on ks while b
                       thereis (and (eq a :added) (eq b :removed))))
            (format nil "~a: every removal run precedes its addition run" (car case)))))))

;;; ------------------------------------------------------------- hack ;;;

(def-test hack-eval-socket (:suite leticl)
  (let ((head (%make-head)))
    (hack-start head)
    (unwind-protect
         (let ((st (connect-unix (hack-socket-path))))
           (write-line "eval (head-cols *head*)" st)
           (force-output st)
           (let ((reply (read-line st)))
             (is (search "\"ok\":true" reply) "eval answered ok")
             (is (search "80" reply) "the head's cols came back")
             (is (head-dirty head) "the eval marked the head dirty"))
           (write-line "bogus" st)
           (force-output st)
           (is (search "\"ok\":false" (read-line st))
               "anything but eval is refused")
           (ignore-errors (close st)))
      (hack-stop head))))

;;; ------------------------------------------------- render resilience ;;;

(def-test render-error-does-not-kill-the-head (:suite leticl)
  "A broken RENDER must not take the head down.

This is the guarantee that makes `tui-eval --file` usable. The render runs on
the MAIN thread, and with --disable-debugger an unhandled error there quits the
process rather than printing and carrying on — so one bad row, or a push that
half-landed, used to cost the operator the head, the session and the screen.
Measured twice; this is the test that says it cannot happen again.

`*stdout*` is bound to a string stream so the failure frame is painted into the
test rather than onto the terminal it is running in. The functions under test
are internals (`%render-and-paint`, `%paint-failure`), reached as
`leticl::name` on purpose: exporting them would promise a contract this test is
not asking for, and the guarantee is about the WHOLE call, so testing a piece
of it would be testing something else."
  (let ((leticl::*stdout* (make-string-output-stream))
        (leticl::*last-render-error* nil)
        (head (leticl::%make-head))
        (real (symbol-function 'top-border)))
    (unwind-protect
         (progn
           (screen-resize (head-screen head) 40 8)
           (screen-resize (head-prev-screen head) 40 8)
           (setf (head-cols head) 40
                 (head-rows head) 8
                 (head-dirty head) t
                 (symbol-function 'top-border)
                 (lambda (h c) (declare (ignore h c)) (error "deliberate break")))
           ;; the whole point: this RETURNS. It used to quit the process.
           (leticl::%render-and-paint head)
           (is (typep leticl::*last-render-error* 'error)
               "the failure is remembered, so the gate can report it")
           (let ((rows (format nil "~{~a~}" (head-last-rows head))))
             (is (search "render failed" rows)
                 "the failure is DRAWN: a silent swallow would leave the gate
green with a wrong screen, which is the defect this file's neighbours exist
against")
             (is (= 8 (length (head-last-rows head)))
                 "a full frame is still there, so the gate's row check holds")
             (is (null (head-dirty head))
                 "the loop's tick completed, so the next pass can run")))
      (setf (symbol-function 'top-border) real)
      (setf leticl::*last-render-error* nil))))

(def-test render-recovers-when-the-cause-is-fixed (:suite leticl)
  "The error flag clears on the next GOOD frame, so a fix needs no restart.

The stale error is what a push leaves behind when it was broken and the next
push fixed it. A head whose render works must go back to green on its own:
otherwise a fixed head stays marked FAILED until it is restarted, which is
exactly the restart this whole mechanism exists to avoid."
  (let ((leticl::*stdout* (make-string-output-stream))
        (leticl::*last-render-error* (make-condition 'simple-error
                                                     :format-control "stale"))
        (head (leticl::%make-head)))
    (unwind-protect
         (progn
           ;; the minimum a real head has before run-loop: a session to render
           ;; and a frame's worth of geometry. Without these the render itself
           ;; errors, which is a different case (and is the OTHER test).
           (setf (head-session head) (make-session))
           (setf (head-cols head) 40 (head-rows head) 8)
           (screen-resize (head-screen head) 40 8)
           (screen-resize (head-prev-screen head) 40 8)
           (leticl::%render-and-paint head)
           (is (null leticl::*last-render-error*)
               "a frame that renders clears the stale error")
           (is (null (head-dirty head)) "and the tick completed"))
      (setf leticl::*last-render-error* nil))))

;;; ------------------------------------------------- engines, wired ;;;

(defun segs-text (lines)
  "Segment lines to one string, for asserting on rendered output."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))

(def-test edit-card-renders-a-real-diff (:suite leticl)
  "An edit card diffs the two sides — hunks, numbering, emphasis — instead of
dumping every removed line and then every added one.

That dump was the old `awhen-edit-lines`, and it is what the operator reported
as \"nothing really shown\": unnumbered, unemphasised, with no context and no
notion of what actually changed. `render-diff` had been written and called from
nowhere for exactly this, so the test is that the card now routes to it."
  (let* ((edit (list :path "src/thing.lisp" :created nil
                     :before-start 310 :after-start 310
                     :before-lines 400 :after-lines 400 :truncated nil
                     :before (format nil "a~%b~%c")
                     :after (format nil "a~%B~%c")))
         (text (segs-text (edit-lines edit 80))))
    (is (search "src/thing.lisp" text) "the path is labelled")
    (is (search "311" text)
        "the changed line is numbered 311 — line numbers come from before_start,
so a diff of an excerpt does not claim line 1 changed when it was line 311")
    (is (search "-b" text) "the removed line is shown")
    (is (search "+B" text) "the added line is shown")
    (is (not (search " 1 " text)) "never numbered from 1")))

(def-test edit-card-is-not-worse-without-a-shim (:suite leticl)
  "A fence with no highlighter renders PLAIN, and the change is gap M6.

The point of `highlight-fence` is that wiring the engine cannot REGRESS a
terminal with no syntax colour: an unknown language, or a shim that is not
built, still gives one readable segment per line rather than dropping the code.

It used to give a DIM one, which this test pinned. `render.rs:190-192,256-258`
draws an unhighlightable body plain — *\"a wrong colour is worse than none\"* —
and dim IS a colour: it says de-emphasised. Every language the shim lacks read
as de-emphasised, which is the opposite of what a code box is for. The frame and
the rail stay faint; the code inside them does not."
  (let* ((lines (highlight-fence (list "let x = 1;" "let y = 2;") "some-unknown-language"))
         (first-seg (first (first lines))))
    (is (= 2 (length lines)) "one line per input line")
    (is (equal "let x = 1;" (car first-seg)) "the text survives verbatim")
    (is (null (cdr first-seg)) "and is plain, neither dimmed nor dropped")))

;;; ------------------- §3.3/R25: the unit is columns, the number is the viewport --- ;;;
;;;
;;; §3.3's claim: **a subject is measured in COLUMNS, not bytes and not characters.**
;;; Both heads agreed on 120 and disagreed about what of.
;;;
;;; R25's change, and the reason this test moved: **the 120 was a DISPLAY width, and a
;;; display width is not the head's to decide.** It is now a KEEP bound (2048 columns),
;;; and the elision a reader sees happens in `%shorten-subject` at the width of the row
;;; being drawn. The unit half of §3.3 is unchanged and is what this test still pins;
;;; the number half is `the-headline-follows-the-viewport`, below.

(def-test a-subject-is-measured-in-columns-not-bytes-or-characters (:suite leticl)
  "**Columns, and the unit is the whole of §3.3.**

The reference counts BYTES (`s.len()`, `is_char_boundary`, `event.rs`) and this head
counted CHARACTERS (`(length clean)`); both are wrong for text that is not ASCII, in
opposite directions. MEASURED on the same subject, before the fix:

| subject | reference | this head, before |
|---|---|---|
| 121 ASCII characters | 117 + an ellipsis, 118 columns | 117 + an ellipsis, the same |
| a subject carrying `0x9B` | stripped | **kept** — the two measured it differently |
| 61 CJK characters (122 columns) | 39 + a mark, 79 columns | **all 61, 122 columns**, untruncated |
| 61 emoji (122 columns) | 39 + a mark, 79 columns | **all 61, 122 columns** |

Counting characters lets a wide subject EXCEED the budget — 61 CJK characters are 122
columns — which is the exact failure a bound exists to prevent and the one this tree
spent `W1` learning about rendering; counting bytes under-fills it by a factor of two.
The bound is about how much room the row has, so it is measured in the unit the row is
drawn in.

**And the ellipsis counts**, which both heads already agreed on: a bound that forgets
the mark is a bound the output is allowed to exceed."
  (let ((cap leticl::*target-max-cols*))
    ;; **the number is not a display width any more** (R25), and this is the assertion
    ;; that says so: a subject a 227-column pane can hold is kept whole.
    (is (>= cap 2048)
        "**the keep bound is at least the daemon's wire bound, in this head's unit** —
 2048 BYTES is at most 2048 COLUMNS, so this head keeps everything a daemon can send,
 whole, and the bound can never be the binding constraint")
    (is (equal 300 (length (leticl::truncate-target (make-string 300 :initial-element #\a))))
        "**a 300-column subject is not cut at all** — the operator's own headline width,
 which the old 120-column bound cut in half. This is R25 in one assertion")
    ;; the unit: characters would overshoot and bytes would under-fill, on the same input
    (let ((cjk (make-string 1025 :initial-element #\中)))   ; 2050 columns, 3075 bytes
      (is (<= (leticl::string-width (leticl::truncate-target cjk)) cap)
          "a subject over the bound in COLUMNS is cut to it — counting characters would
 leave 2050 columns, and counting bytes would leave 682")
      (is (char= #\… (char (leticl::truncate-target cjk)
                           (1- (length (leticl::truncate-target cjk)))))
          "and the cut is disclosed"))
    (let ((emoji (make-string 1025 :initial-element (code-char #x1f642))))  ; 2050 columns
      (is (<= (leticl::string-width (leticl::truncate-target emoji)) cap)
          "and the same for text whose characters are not one column wide each"))
    ;; **the C1 half of the requirement.** `0x9B` is 8-bit CSI: the reference strips it
    ;; (Rust's `is_control` covers U+0080–U+009F) and this head did not, so the two
    ;; measured the same subject differently
    (is (leticl::%control-char-p (code-char #x9b)) "C1 is a control character")
    (is (leticl::%control-char-p (code-char #x80)) "from the bottom of the range")
    (is (leticl::%control-char-p (code-char #x9f)) "to the top of it")
    (is (leticl::%control-char-p (code-char 127)) "and DEL")
    (is (leticl::%control-char-p (code-char 10)) "and C0")
    (is (not (leticl::%control-char-p (code-char #xa0))) "and not U+00A0, which is a space")
    (is (not (leticl::%control-char-p #\a)) "nor an ordinary letter")
    (is (not (search (string (code-char #x9b))
                     (leticl::truncate-target (format nil "a~c b" (code-char #x9b)))))
        "and one inside a subject is flattened before anything is measured")
    (is (not (find #\newline (leticl::truncate-target (format nil "a~%b"))))
        "a newline in a header is not a row the head did not count")
    (is (not (find #\tab (leticl::truncate-target (format nil "a~cb" #\tab))))
        "nor a tab, which measures as one column and draws as eight")))

;;; ------------------------------- R25: the viewport decides the elision ---------- ;;;
;;;
;;; The operator, 2026-09-22: *"some commands head lines like 'Ran blabla' truncate too
;;; early — they dont use the whole conversation history viewport, unlike say thinking."*
;;;
;;; **The subject is DERIVED through the real path in every test below**: a snapshot with
;;; an assistant row carrying the call's `arguments`, which is what a head that attached
;;; to an existing session has, and which runs `note-snapshot-targets` →
;;; `note-assistant-targets` → `display-target` → `truncate-target`. Poking the subject
;;; into `*call-targets*` would test the renderer and skip the derivation, and the
;;; derivation is where the constant was.

(defun %r25-subject (n &optional (digit #\0))
  "N characters of a repeating pattern, so how much came through is countable."
  (with-output-to-string (s)
    (dotimes (i n) (write-char (code-char (+ (char-code digit) (mod i 10))) s))))

(defun %head-with-a-long-subject (subject &key (name "bash") (payload "one line")
                                          (call-id "r25-c1"))
  "A head whose one settled tool row has SUBJECT as its derived display subject.

The call id is `r25-c1` and not `c1` on purpose: `*call-targets*` and `*answered-calls*`
are `defvar`s that outlive a test, so a fixture that borrowed the payload tests' ids
would leave a long subject under them and those tests' rows would grow a `…`. Caught by
the suite when these tests first ran."
  (let ((h (%on-head :cols 80 :rows 24)))
    (ingest-snapshot (head-session h)
                     (list :session-id "s-r25" :seq 5 :dropped 0 :items-dropped 0
                           :turn nil :open-decisions nil :settled-decisions nil
                           :heads nil :warnings nil
                           :items (list
                                   (list :item-id "a1" :kind "assistant" :ts 0
                                         :item (list :type "assistant" :text "looking"
                                                     :tool-calls
                                                     (list (list :id call-id :name name
                                                                 :arguments
                                                                 (format nil "{\"command\":~s}"
                                                                         subject)))))
                                   (list :item-id "i1" :kind "tool_result" :ts 0
                                         :item (list :type "tool_result" :call-id call-id
                                                     :name name
                                                     :outcome (list :outcome "ok")
                                                     :payload payload)))))
    h))

(defun %r25-tool-row (h)
  "The head's one settled tool_result row."
  (find "tool_result" (session-items (head-session h))
        :key (lambda (i) (getf (leticl::item-body i) :type)) :test #'string=))

(defun %headline-at (h cols)
  "The headline that row DRAWS at COLS, as text."
  (segs-of (list (first (item-lines (%r25-tool-row h) cols (head-prefs h))))))

(def-test the-headline-follows-the-viewport (:suite leticl)
  "**R25's criterion, and the operator's own measurement.**

A settled tool row's subject is elided to **what the row has left after its own mark,
verb, outcome and duration** — the viewport's arithmetic and nothing else. Before the
fix the subject was cut to a constant 120 COLUMNS at the moment the head derived it, so
one event produced 77 columns of headline at 80, 137 at 140 and **156 at 227** — it grew
and then stopped, and the seventy columns between 156 and 227 belonged to nobody.

The subject here is 300 characters of a repeating digit pattern, so *how much came
through* is countable rather than eyeballed."
  (let* ((subject (%r25-subject 300))
         (h (%head-with-a-long-subject subject))
         (at (lambda (cols) (%headline-at h cols)))
         (digits (lambda (cols) (count-if #'digit-char-p (funcall at cols)))))
    (is (= 300 (length subject)) "the premise: a 300-column subject")
    ;; --- it GROWS with the viewport, which is the whole claim
    (is (< (funcall digits 80) (funcall digits 140))
        (format nil "at 140 columns the headline is wider than at 80: ~d against ~d"
                (funcall digits 80) (funcall digits 140)))
    (is (< (funcall digits 140) (funcall digits 227))
        (format nil "and wider again at 227: ~d against ~d"
                (funcall digits 140) (funcall digits 227)))
    ;; --- **THE REGRESSION ASSERTION**: past the old constant.
    (is (> (funcall digits 227) 120)
        (format nil "**at 227 columns more than 120 characters of subject reach the
 screen** (~d), where the old constant capped it there: ~s"
                (funcall digits 227) (funcall at 227)))
    ;; --- and the row never exceeds the viewport it was given
    (dolist (cols '(80 140 227 400))
      (is (<= (string-width (funcall at cols)) cols)
          (format nil "at ~d columns the headline fits: ~d wide"
                  cols (string-width (funcall at cols)))))
    ;; --- **the elision is DISCLOSED, and a subject that FITS is marked not at all**
    (dolist (cols '(80 140 227))
      (is (search "…" (funcall at cols))
          (format nil "at ~d columns 300 characters cannot fit, so the cut is disclosed" cols)))
    (is (not (search "…" (funcall at 400)))
        (format nil "**at 400 columns the whole subject fits and is marked NOT AT ALL** —
 a `…` on a complete subject is the same class of lie as hiding a cut: ~s"
                (funcall at 400)))
    (is (= 300 (funcall digits 400)) "and every one of the 300 characters is on the row")))

(def-test a-resize-re-elides-the-subject-on-the-screen (:suite leticl)
  "**A wider window gets more of the subject BACK, and it is the SCREEN that says so.**

The elision is computed at draw time from `cols`, so a resize is not a re-render of a
stored decision — there is no stored decision. What could still have frozen it is the
line cache, whose key is `(generation, width, items)`; the width is one of the three
terms, so a resize invalidates. This asserts the *visible* consequence at all three
widths, in order, including the return to a width already used: a cache keyed on
something narrower than the width would show the 227-column row again at 80."
  (let* ((h (%head-with-a-long-subject (%r25-subject 300)))
         (*stdout* (make-string-output-stream)))
    (labels ((headline-on-screen (cols)
               (setf (head-cols h) cols (head-rows h) 24)
               (screen-resize (head-screen h) cols 24)
               (screen-resize (head-prev-screen h) cols 24)
               (leticl::%render h)
               (find-if (lambda (l) (search "0123456789" l))
                        (uiop:split-string (%screen-text h) :separator '(#\newline))))
             (digits (cols) (count-if #'digit-char-p (or (headline-on-screen cols) ""))))
      (let ((narrow (digits 80)))
        (is (plusp narrow) "the headline is on the screen at 80")
        (let ((wide (digits 227)))
          (is (> wide narrow)
              (format nil "**widening the same head gives the subject back**: ~d
 characters at 227 against ~d at 80" wide narrow))
          (let ((narrow-again (digits 80)))
            (is (= narrow narrow-again)
                (format nil "**and narrowing it takes them away again**: ~d, the same as
 the first time at 80 — a cached 227-column row would have shown ~d"
                        narrow-again wide)))
          (is (= wide (digits 227))
              "and back at 227 it is the wide one again, so nothing was cached against it"))))))

(def-test a-cut-subject-lands-on-a-cluster-boundary-not-half-the-width (:suite leticl)
  "**The unit, on a subject whose characters are two cells wide.**

A cut of `120` in BYTES would leave 40 CJK characters — 80 columns, a little over half
the room — and a cut in CHARACTERS would leave 120 of them, 240 columns, past the edge
of the pane. So neither failure can pass this: the visible subject has to *use the room
it was given*, and every kept cluster has to be whole, which for `中` means the
segment's column count is exactly twice its length.

200 of them (400 columns) is the subject, so that it does not fit a 227-column pane and
there is a cut to inspect at all."
  (let* ((cjk (make-string 200 :initial-element #\中))
         (h (%head-with-a-long-subject cjk))
         (at (lambda (cols) (%headline-at h cols))))
    (is (= 400 (string-width cjk)) "the premise: 200 of them are 400 columns")
    (let ((wide (funcall at 227)))
      (let ((kept (remove-if-not (lambda (c) (char= c #\中)) wide)))
        (is (plusp (length kept)) "some of the subject is on the row")
        (is (= (* 2 (length kept)) (string-width kept))
            (format nil "**every kept cluster is whole** — the segment is ~d columns for
 ~d characters, and a cut inside one would make those disagree"
                    (string-width kept) (length kept)))
        ;; **not half the room.** The subject's share at 227 is ~199 columns; a byte-counted
        ;; cut would leave 80, and a character-counted one 240 (which would also overflow)
        (is (> (string-width kept) 190)
            (format nil "**the subject uses the room it was given, not half of it**: ~d
 columns of a ~d-column allowance" (string-width kept) 199)))
      (is (<= (string-width wide) 227) "and the row still fits its pane")
      (is (search "…" wide) "with the cut disclosed")
      (is (not (find #\space (remove-if (lambda (c) (member c '(#\space)))
                                        (subseq wide (1+ (search "Ran" wide))))))
          "as one unbroken run of the subject, not re-wrapped"))))

(def-test the-raw-call-block-wraps-to-the-viewport-too (:suite leticl)
  "**The same defect, one control away, and the same fix.**

`ctrl-x`'s raw block wrapped at `(1- *target-max-cols*)` — 119 columns whatever the pane
was — so on a 227-column window it drew a 119-column column of text with a hundred
columns of nothing beside it. A wrapper on a display path that does not know its width
cannot wrap honestly, so the width is now a required argument and both call sites pass
the viewport."
  (let ((raw (format nil "bash {\"command\":\"~a\"}" (%r25-subject 300))))
    (is (search "raw tool call · ctrl-x" (segs-of (leticl::raw-call-lines raw 227)))
        "the block is still labelled")
    (dolist (cols '(40 80 227))
      (let ((lines (leticl::raw-call-lines raw cols)))
        (is (every (lambda (l) (<= (leticl::%segs-width l) cols)) lines)
            (format nil "every line fits ~d columns" cols))
        (is (> (length lines) 2) "and the long call wrapped rather than being clipped"))
      ;; the wrap follows the width: a wider block is FEWER lines for the same text
      (let ((wider (leticl::raw-call-lines raw (max 40 (* 4 cols)))))
        (is (<= (length wider) (length (leticl::raw-call-lines raw cols)))
            (format nil "a wider block is not more lines than a narrow one at ~d" cols))))))

(def-test fence-language-names-map-to-the-highlighter (:suite leticl)
  "A fence carries a NAME; the shim takes a PATH. Both spellings work."
  (is (eq 0 (lang-for-fence "no-such-language")) "an unknown name is 0, not a guess")
  (is (integerp (lang-for-fence "lisp")) "a known name answers an id")
  (is (integerp (lang-for-fence "rust")) "and so does another"))

;;; ---------------------- §2.6: a fence's first word names the grammar ------------ ;;;
;;;
;;; The claim: **a fence info string resolves to a grammar by its FIRST WORD,
;;; case-insensitively, ignoring trailing attributes.** letibot gets this from
;;; `rano::syntax::Lang::from_token` (`crates/tui/src/render.rs:217`), so the two
;;; heads agree only if this one answers the same token the same way — and this
;;; head's table WAS the extension table, with no comma or whitespace splitting, so
;;; every fence carrying an option fell through to plain.

(def-test a-fence-resolves-by-its-first-word (:suite leticl)
  "The claim, in the four shapes an info string actually takes.

`rust,ignore` and `python title=\"x\"` were the two measured misses: the whole
string was looked up and matched nothing, so the fence rendered plain while letibot
coloured it. The rule is `from_token`'s own (`rano/src/syntax.rs:98-104`): split on a
comma, then on whitespace, take what is left, case-insensitively."
  (is (equal "rust" (fence-token "rust")) "a bare token")
  (is (equal "rust" (fence-token "RUST")) "case-insensitively")
  (is (equal "rust" (fence-token " rust ")) "trimmed")
  (is (equal "rust" (fence-token "rust,ignore")) "a comma and an option")
  (is (equal "python" (fence-token "python title=\"a b\"")) "a space and a title")
  (is (equal "python3" (fence-token "python3"))
      "a version suffix is the TOKEN itself — `python3` is its own name in `from_token`,
 not a prefix of `python`")
  (is (equal "" (fence-token "  ")) "and an empty one is empty, not a crash")
  ;; and every one of them reaches a grammar
  (dolist (info (list "rust,ignore" "python title=\"x\"" "rust title=\"y\" ignore" "RUST,"))
    (is (plusp (lang-for-fence info)) (format nil "~s colours" info))))

;;; **The guard reads `rano`, and this is the whole of §11.5.**
;;;
;;; The test below used to carry its own hand-written list of the tokens `rano` knows — a
;;; THIRD copy of a table that lives in `~/Projects/rano/rano/src/syntax.rs` and is mirrored
;;; here in `*fence-tokens*`. Three copies agreeing is a coincidence; the defect is that the
;;; guard **cannot fire for a token nobody wrote down**, because a new token in `rano` is not
;;; in the list the guard iterates. The drift it exists to catch is exactly the one it cannot
;;; see — §2.6's own shape one layer up, where the copy is the thing that guards the copy.
;;;
;;; So the tokens are EXTRACTED from `rano`'s source at test time. It is the real table by
;;; construction, it needs no build step or generator, and `rano` is already an absolute path
;;; dependency of three `Cargo.toml`s in the reference tree.
;;;
;;; Two traps, and both are answered below by a test rather than by care:
;;;   · **an extraction that finds nothing** would make the guard vacuous — the failure mode
;;;     it was written to end. The count is asserted, and a shape change in `rano` fails
;;;     LOUDLY rather than silently passing;
;;;   · **the extractor itself is a thing that can be wrong**, so `a-token-added-to-rano-is-
;;;     seen-by-the-guard` feeds it a source with a token this head has never heard of.

(defparameter +rano-syntax-rs+ "/home/dead/Projects/rano/rano/src/syntax.rs"
  "Where `rano::syntax::Lang::from_token` is. The same absolute path three `Cargo.toml`s in
`~/Projects/letibot/letibot` depend on, so the tree is reachable from a box that can build
that head. A `defparameter` and not a `defconstant`: the file pusher SKIPS constants.")

(defun %tokens-in-from-token (source)
  "Every fence token SOURCE's `from_token` answers, read out of the Rust.

NIL when SOURCE has no `from_token` at all, and — this is the part that matters — NIL when
it has one with NO arms. An empty list would let the caller loop over nothing and go green,
which is the vacuity this whole guard exists to end; `nil` says *I could not read this*.

The function runs from the `fn` to the first line that is exactly four spaces and a brace,
because that is where it ends: its `match` arms are indented deeper. Then only the **match
arms** are read — a line carrying `=>` — because the prologue holds strings that are not
tokens (its `unwrap_or` takes an empty literal, twice) and only arms name a grammar. `//`
comments are stripped first: the real table carries prose among its arms, and a quote in one
of them would otherwise be read as a token."
  (let ((at (search "pub fn from_token" source)))
    (when at
      (let* ((body (subseq source at))
             (cut (loop for start = 0 then (1+ lf)
                        for lf = (position #\Newline body :start start)
                        while lf
                        when (string= (subseq body start lf) "    }")
                          return lf)))
        ;; **NO CLOSING BRACE, NO LIST.** Scanning to the end of the file instead would
        ;; pick up every string below the function — a table of tokens plus whatever else
        ;; that file holds — and the guard would fail with tokens nobody can find. `nil`
        ;; means *I could not read this*, which is skip-able and visible as a skip.
        (when cut
          (let* ((head (subseq body 0 cut))
                 (code (with-output-to-string (s)
                         (dolist (line (uiop:split-string head :separator '(#\Newline)))
                           (let* ((bar (search "//" line))
                                  (arm (if bar (subseq line 0 bar) line)))
                             ;; **ARMS ONLY.** The prologue's `unwrap_or("")` are strings
                             ;; and not tokens; a token is what sits left of a `=>`.
                             (when (search "=>" arm)
                               (write-string arm s)
                               (write-char #\Newline s))))))
                 (toks nil) (in nil) (begin nil))
            (loop for i from 0 below (length code)
                  for ch = (char code i)
                  do (when (char= ch #\")
                       (if in
                           (progn (push (subseq code begin i) toks) (setf in nil))
                           (progn (setf in t begin (1+ i))))))
            (nreverse (delete-duplicates toks :test #'string=))))))))

(defun %rano-tokens ()
  "`rano`'s tokens, or NIL when its source is not on this box."
  (when (probe-file +rano-syntax-rs+)
    (%tokens-in-from-token (uiop:read-file-string +rano-syntax-rs+))))

(def-test a-token-added-to-rano-is-seen-by-the-guard (:suite leticl)
  "**The extractor is the half that can be subtly wrong, so it is held to a string this
file owns.** Not the operator's tree: a source written here, with a token this head has
never heard of. That is the falsification of the guard's whole purpose — §11.5's ruling is
*point the guard at `rano`*, and a guard that cannot see a token nobody wrote down is the
defect being fixed.

An extraction that finds NOTHING is the other failure, and the reason this returns NIL
rather than an empty list when the shape it expects is gone."
  (let ((synthetic (format nil "pub fn from_token(token: &str) -> Option<Lang> {~%
        match word.as_str() {~%
            \"rust\" | \"rs\" => Some(Lang::Rust),~%
            \"elixir\" => Some(Lang::Elixir),~%
            _ => None,~%
        }~%
    }~%")))
    (let ((toks (%tokens-in-from-token synthetic)))
      (is (equal '("rust" "rs" "elixir") toks)
          "the tokens come out of the source in order, none invented and none missed: ~s"
          toks)
      (is (member "elixir" toks :test #'string=)
          "**AND A TOKEN THIS HEAD HAS NEVER HEARD OF IS IN THE SET** — which is what makes
`every-token-rano-knows-is-a-token-this-head-knows` able to fail for a token nobody wrote
down. Asserted on a synthetic table rather than by editing the operator's `rano`."))
    (is (null (%tokens-in-from-token "pub fn detect(path: &str) -> Option<Lang> {\n    }\n"))
        "no `from_token`, no token list — NIL, so the caller must skip rather than pass
vacuously, which is the failure this whole guard exists to end")
    (is (null (%tokens-in-from-token "pub fn from_token(t: &str) -> Option<Lang> {\n    }"))
        "**and a `from_token` with no arms is the OTHER vacuity** — an empty list would let
the real test loop over nothing and go green")))

(def-test every-token-rano-knows-is-a-token-this-head-knows (:suite leticl)
  "**The painter IS the table**, so this asserts against `rano`'s OWN source rather than
restating it (§11.5).

`rano::syntax::Lang::from_token` is what letibot colours a fence with, and its docstring
says the property that keeps it honest: *`from_token` answers every `Lang::name()`, and vice
versa*. The requirement is that each of those tokens reaches a grammar THIS BUILD HAS.

**What this test did before, and why it could not fail.** It carried a hand-written list — a
third copy of the table, after `rano`'s and this head's `*fence-tokens*` — so a token added
to `rano` was invisible to it until somebody edited the list too. All three agreed at 75
tokens when this was written, which is exactly how a copy reads as a guard.

Skipped when `rano`'s source is not on the box (the same contract as the highlight shim,
which passes with no `.so` present) — but not silently: the count is asserted, so a shape
change in `rano` fails here rather than turning the guard off."
  (let ((toks (%rano-tokens)))
    (if (null toks)
        (skip "rano's source is not on this box")
        (progn
          (is (> (length toks) 50)
              "**a plausible table, so an extractor that stopped matching cannot pass** — ~d
 tokens read out of ~a" (length toks) +rano-syntax-rs+)
          (dolist (tk toks)
            (is (plusp (lang-for-fence tk))
                (format nil "rano's `~a` resolves to a grammar here" tk))
            (is (stringp (fence-grammar-name tk))
                (format nil "and `~a` names one" tk)))))))

(def-test a-token-this-build-cannot-draw-stays-plain (:suite leticl)
  "**A grammar you do not have is not an alias you can add.** The doc's list includes
`xml` and `svg`, and there is no XML lexer in the painter's 27 grammars
(`native/hl/src/lib.rs:32-60`) — so they map to the HTML grammar, which is what
colours them in letibot too, and `rano::syntax::Lang::from_token` maps them
identically. A language with *no* grammar at all is simply not in the table: a row
claiming one the painter cannot draw is worse than an honest miss, because the box
header would name a grammar that did not run.

`mk` is the case that proves the token table is its own table and not the extension
one: `mk` IS Make as a path extension (`detect`, `syntax.rs:646`) and is NOTHING as a
token, which `from_token` says twice — it is absent, and `make`/`makefile` map to
Make."
  (is (eq 0 (lang-for-fence "mk")) "`mk` is an extension, not a token")
  (is (plusp (lang-for-fence "make")) "but `make` is a token, and it colours")
  (is (plusp (lang-for-fence "makefile")) "so is a makefile")
  (is (eq 0 (lang-for-fence "text")) "a word with no grammar stays plain")
  (is (eq 0 (lang-for-fence "txt")) "and so does another")
  (is (eq 0 (lang-for-fence "")) "and so does nothing at all")
  (is (null (fence-grammar-name "no-such-thing")) "and names no grammar"))

(def-test console-is-not-a-language-and-stays-plain (:suite leticl)
  "**The conflict, ruled: letibot is right and this head was wrong.**

Both heads agree on almost the whole table (`from_token` is one function), and
`console` is where they disagreed — this head coloured it as bash, letibot returns
`None` deliberately, calling it *the archetypal unknown* (`rano/src/syntax.rs:93-96`).

**Ruled: plain, in both heads.** Four reasons, in the order they weigh:

1. **A console transcript is not a language.** `console` is a convention (Pygments,
   Chroma) for a terminal SESSION: a prompt, a command, then the command's OUTPUT.
   What a bash grammar would colour is mostly output, and output is not bash — so
   the painter invents structure the bytes do not have. That is the rule this file
   already keeps for an unknown language and for a fence the shim lacks: *a wrong
   colour is worse than none*, written three lines above `highlight-fence`.
2. **The invented structure HIDES things.** A `#` that opens a comment (a shebang, a
   shell glob, a `#` in a path) greys out the rest of the line — and in a console
   transcript the rest of the line is often THE OUTPUT, which is the one thing the
   operator is reading the fence for. A quote character in output opens a string that
   never closes it, and `if` / `do` / `in` appear in output as prose and would take
   keyword colour.
3. **The painter owns the vocabulary.** `from_token` is one function in one crate,
   used by one caller, and it answers `None` — because there is no ShellSession
   grammar to point at. A head that keeps its own answer here keeps a private dialect
   of a shared table, which is exactly the drift this task exists to end.
4. **And the two heads cannot be made to agree any other way.** letibot colours a
   fence by calling `from_token`; for the two to agree, this head must answer what
   `from_token` answers. Choosing `bash` here means choosing permanent divergence on
   a token, or a change in letibot's shared table to satisfy one head.

What would change this ruling is a real ShellSession grammar — one that knows a
prompt from output. Then `console` is a language and colouring it is honest. That is
a painter change, not a head change."
  (is (eq 0 (lang-for-fence "console")) "console resolves to no grammar")
  (is (null (fence-grammar-name "console")) "and names none")
  ;; the other side of the same rule: a fence the painter CAN draw still colours
  (is (plusp (lang-for-fence "bash")) "bash itself is unaffected")
  (is (plusp (lang-for-fence "sh")) "and so is sh"))

;;; ------------------------------------------- live state is defvar, not defparameter ;;;

(defun source-of (name)
  "The text of one src file, so a test can assert on declarations."
  (let ((p (merge-pathnames (format nil "src/~a.lisp" name)
                            (uiop:pathname-directory-pathname
                             (or *load-truename* #p"./")))))
    (if (probe-file p)
        (uiop:read-file-string p)
        ;; the test system loads from the repo root, but be explicit
        (uiop:read-file-string
         (merge-pathnames (format nil "src/~a.lisp" name) #p"/home/dead/Projects/leticl/")))))

;;; -------------------- a docstring that stops in the middle ---------------- ;;;
;;;
;;; **A double quote inside a docstring has to be escaped**, and forgetting costs the
;;; rest of the sentence. The string ends at that quote; the remainder of the paragraph
;;; is read as CODE; and the compiler is left with a handful of stray symbols in the
;;; defun's body, which it reports as one *undefined variable* per word.
;;;
;;; **Nothing fails, and that is what makes it worth a test.** The defun still compiles
;;; and still runs, because the strays land in front of the real body — so the only
;;; evidence is a docstring that stops mid-sentence, and a warning nobody reads.
;;; Measured 2026-09-22: eleven docstrings across seven files in this tree were cut
;;; this way, and the longest lost two thirds of itself.
;;;
;;; So it is CHECKED rather than remembered. The check reads every file with the READER
;;; — the thing the compiler does with it — and looks for the shape the wreckage has:
;;; **a body form that is not a form.**

(defun %lisp-source-files ()
  "Every `.lisp` file under `src/` and `tests/`, as (PATHNAME . PACKAGE-NAME).

The package is the one the file expects to be READ in: a name interned elsewhere would
be a different symbol, and the walk below matches heads by identity."
  (let ((root (uiop:pathname-directory-pathname (or *load-truename* #p"./"))))
    (loop for dir in '("src/" "tests/")
          for pkg in '("LETICL" "LETICL/TESTS")
          append (loop for p in (uiop:directory-files (merge-pathnames dir root))
                       for n = (file-namestring p)
                       for l = (length n)
                       when (and (> l 5) (string= ".lisp" n :start2 (- l 5)))
                         collect (cons p pkg)))))

(defparameter +forms-with-a-docstring+
  '((defun . 3) (defmacro . 3) (defmethod . 3) (def-test . 3) (lambda . 2)
    (defparameter . 3) (defvar . 3) (defconstant . 3))
  "Head, and how many leading elements precede an optional docstring.

A `defun` is `(defun NAME LAMBDA-LIST DOC BODY…)` and a `lambda` has no name, so those
two differ by one; `def-test` has an option list where a `defun` has its lambda list,
which is why the count is measured off real files rather than assumed.

**`defmethod` is here for the count and not for the qualifiers.** There is no
`defmethod` in this tree; one WITH a qualifier would put the body one element further
right than this says, and the check would name a string that is genuinely the docstring.
A false positive that says so out loud is the right failure for a table like this.")

(defparameter +symbols-that-are-a-form-alone+ '(t nil)
  "The two symbols that mean something as a whole form. `t` is a function and `nil` is
the empty list — any OTHER symbol standing alone in a body is not a form, it is what is
left of one.")

(defun %walk-forms (form fn)
  "Call FN on FORM and on every subform. Quoted data is not walked.

A form inside a quote is data — a list of names, a table of strings — and a symbol
standing alone in there is the point of it rather than a wreck. The loop is written
against `(cdr tail)` rather than with `dolist` so a dotted pair cannot take it down."
  (funcall fn form)
  (when (consp form)
    (unless (member (car form) '(quote function))
      (loop for tail = form then (cdr tail)
            while (consp tail)
            do (%walk-forms (car tail) fn)))))

(defun %stray-body-forms (top)
  "Every body form under TOP that is not a form, and is not the body's LAST form:
 a symbol or a string where a call belongs.

**The last-form exemption is the whole of what makes this precise.** A body may
legitimately end in a bare symbol — it is the value the function returns, and
`(defun %payload-view-set (value) … value)` is the shape this tree has several of — so a
symbol in FINAL position is a return value and a symbol anywhere else is not a form at
all, because its value would be discarded. A string in non-final position is the same
statement one louder: no body form is a string.

Each finding is reported as `(HEAD NAME FORM)`, so a failure names the definition and
the word as well as the file."
  (let ((bad nil))
    (%walk-forms
     top
     (lambda (form)
       (let ((how-many (and (consp form)
                            (cdr (assoc (first form) +forms-with-a-docstring+)))))
         (when how-many
           (let ((body (nthcdr how-many form)))
             (when (stringp (car body)) (setf body (cdr body)))
             ;; `(cdr tail)` non-nil is *something follows this one*, which is where a
             ;; stray cannot be a return value
             (loop for tail on body
                   for b = (car tail)
                   when (and (cdr tail)
                             (or (stringp b)
                                 (and (symbolp b)
                                      (not (keywordp b))
                                      (not (member b +symbols-that-are-a-form-alone+)))))
                     do (push (list (first form) (second form) b) bad)))))))
    (nreverse bad)))

(defun %docstring-truncations (path package-name)
  "Everything `%stray-body-forms` finds in every top-level form of PATH."
  (let ((*read-eval* nil)
        (*package* (find-package package-name))
        (forms nil))
    (with-open-file (in path :external-format :utf-8)
      (loop for form = (read in nil :eof)
            until (eq form :eof)
            do (push form forms)))
    (loop for form in (nreverse forms) append (%stray-body-forms form))))

(def-test no-docstring-is-cut-short-by-an-unescaped-quote (:suite leticl)
  "**The invariant, over every source file, because the defect is one character wide.**

Eleven docstrings in this tree were cut this way when this check was written — under
`src/` and under `tests/` both — and every one of them still COMPILED. That is the whole
reason it is a test rather than a note in a style guide: the compiler reports the
wreckage as undefined variables in a body, and a docstring that stops mid-sentence reads
as an interruption rather than as a mistake.

It reads the files the way the compiler does, and the assertion is on the absence of the
stray forms rather than on the words — so a fix that escapes the quote makes them go."
  (let ((files (%lisp-source-files)))
    (is (> (length files) 25)
        "**a plausible source set, so a bad directory cannot pass vacuously** — ~d files"
        (length files))
    (dolist (pair files)
      (let ((bad (%docstring-truncations (car pair) (cdr pair))))
        (is (null bad)
            (format nil "~a: ~d body form~:p that ~:[are~;is~] not a form, so a docstring
 above this one was cut short. First: ~s"
                    (file-namestring (car pair)) (length bad) (= 1 (length bad))
                    (first bad)))))))

(defparameter *symbol-chars*
  "*+-_/0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
  "What may continue a symbol name, for `declared-with`'s boundary check.")

(defun declared-with (text var)
  "How VAR is declared in TEXT: :defvar, :defparameter, or NIL.

The name may be followed by a newline rather than a space (`(defvar *styles*`
then the initform on the next line), so the boundary is 'not a symbol character'
rather than 'a space'. Two ways this helper was wrong before it worked: it
required a space, and it built its delimiter set as `\" \\n\\t(\"` — which in Lisp
is the literal characters backslash, n, backslash, t, NOT a newline and a tab,
so a newline did not match."
  (labels ((at (form)
             (let ((i (search form text)))
               (and i
                    (let ((j (+ i (length form))))
                      (or (>= j (length text))
                          (not (find (char text j) *symbol-chars* :test #'char=))))))))
    (cond ((at (format nil "(defvar ~a" var)) :defvar)
          ((at (format nil "(defparameter ~a" var)) :defparameter)
          (t nil))))

(def-test live-state-tables-are-defvar (:suite leticl)
  "The tables that hold RUNNING state must be `defvar`.

`defvar` assigns only when unbound, so a live push leaves the value alone;
`defparameter` assigns unconditionally, so a push RESETS it in a head that is
mid-session. That has cost an operator their session twice now, so it is a test
and not a rule in a document:

  · this was measured on this box. `*style-sgrs*` was a defparameter next to a
    defvar `*styles*`, and the two are PARALLEL — index N of one describes index
    N of the other. A push reset one and not the other, so cells held style
    indices the SGR cache had no entry for and the next paint died with
    \"Invalid index 8 for (VECTOR T 8)\". The head SURVIVED it (the render paints
    its own failure now) and said so in the gate; before that it would have quit.

Every name here holds something a running head has indices into, or a live
handle. If you add one, add it here."
  (dolist (pair '(("cells" "*styles*")
                  ("cells" "*style-sgrs*")   ; the one that bit
                  ("head" "*head*")
                  ("head" "*stdout*")
                  ("render" "*last-render-error*")
                  ("render" "*paint-lock*")
                  ("term" "*saved-termios*")
                  ("term" "*raw-termios*")
                  ("term" "*raw-fd*")
                  ("highlight" "*hl-so*")
                  ("highlight" "*hl-attempted*")
                  ("highlight" "*hl-memo*")        ; a push must not drop the parses
                  ("highlight" "*hl-grid-calls*")  ; nor reset what a profile is reading
                  ("protocol" "*request-counter*")))
    (let ((how (declared-with (source-of (first pair)) (second pair))))
      (is (eq :defvar how)
          (format nil "~a in src/~a.lisp must be defvar, not ~a — a push would ~
reset it mid-session" (second pair) (first pair) how)))))

(def-test style-tables-stay-parallel (:suite leticl)
  "The style table and its SGR cache must be the same length.

They are indexed by the same style index, so a length mismatch is a cell whose
style has no SGR — which is how the desync above surfaced. Interning a style
extends BOTH; this asserts the invariant directly rather than trusting the one
function that maintains it. Growing the tables is harmless and additive, so the
interned specs stay (a later test sees a bigger table, never a wrong one)."
  (let ((before (length *styles*)))
    (style-index '(:fg :yellow :underline t))
    (style-index '(:fg :bright-magenta :bold t))
    (is (= (length *styles*) (length *style-sgrs*))
        "interning a style must extend the SGR cache with it")
    (is (> (length *styles*) before) "…and it must have grown")))

(def-test style-sgrs-can-be-rebuilt-from-the-specs (:suite leticl)
  "The SGR cache is derivable from the style table, so a desync is repairable.

This is the recovery path for the accident above: a head already carrying the
mismatch can be fixed in place instead of restarted, which is the whole point of
patching a running head. The rebuild is idempotent in effect, so running it on a
healthy table changes nothing an assertion can see."
  (let ((healthy (copy-seq *style-sgrs*)))
    (rebuild-style-sgrs)
    (is (= (length *styles*) (length *style-sgrs*))
        "the two tables are parallel again")
    (is (= (length healthy) (length *style-sgrs*))
        "a healthy table is unchanged in length")
    (is (equalp (coerce healthy 'vector) (coerce *style-sgrs* 'vector))
        "and unchanged in content — the rebuild is a no-op when nothing is wrong")
    ;; and a deliberately broken table is repaired
    (setf *style-sgrs* (make-array 3 :adjustable t :fill-pointer 3))
    (rebuild-style-sgrs)
    (is (= (length *styles*) (length *style-sgrs*))
        "a truncated cache is rebuilt from the specs")))

;;; ------------------------------------------------- progress ;;;

(def-test thousands-shortens-and-never-separates (:suite leticl)
  "A status line has no room for a separator, and `40.1k` reads faster than
`40,132` when the digits past the first three are noise."
  (is (equal "0" (thousands 0)))
  (is (equal "9999" (thousands 9999)) "four digits stay exact")
  (is (equal "12.3k" (thousands 12345)))
  (is (equal "40.1k" (thousands 40082)))
  (is (equal "1.23M" (thousands 1234567)))
  (is (not (search "," (thousands 1234567))) "never a separator"))

(def-test duration-reads-at-a-glance (:suite leticl)
  (is (equal "840ms" (duration 840)))
  (is (equal "2.5s" (duration 2500)))
  (is (equal "1m05s" (duration 65000)))
  (is (equal "1h05m" (duration 3900000))))

(def-test spinner-follows-the-clock-not-a-counter (:suite leticl)
  "It is a liveness indicator for the CLOCK, and the caller is expected to stop
calling it when the turn stops rather than to read it as proof of progress."
  (is (char= (spinner 0) (spinner 0)) "deterministic for one time")
  (is (char= (spinner 0) (spinner 79)) "and holds for the first 80ms")
  (is (not (char= (spinner 0) (spinner 80))) "and advances after it")
  (is (= 10 (length (remove-duplicates
                     (loop for ms from 0 below 800 by 80 collect (spinner ms)))))))

(def-test prefill-measures-rate-over-computed-not-processed (:suite leticl)
  "Dividing the CACHE HIT by the wall clock is not a speed, it is an artefact in
the hundreds of thousands — so the rate is computed over what was actually
computed this turn."
  (let ((p (list :total 1000 :cache 900 :processed 950 :time-ms 1000)))
    (is (= 50 (prefill-computed p)) "950 processed minus 900 cached")
    (is (equal 50.0 (prefill-rate p)) "50 computed tokens in 1s is 50 tok/s")
    (is (not (equal 950.0 (prefill-rate p))) "NOT the processed count over time")
    (is (equal 0.9 (prefill-cached-fraction p)) "the cache fraction is the headline")
    (is (equal 0.95 (prefill-fraction p)))
    (is (equal 1000 (prefill-eta-ms p)) "50 left at 50 tok/s is a second")))

(def-test prefill-refuses-a-number-it-did-not-measure (:suite leticl)
  "No rate before there is enough elapsed time to divide by, and a cache
reported larger than the prompt it cached is clamped — a bar past its own end
is a lie about progress."
  (is (null (prefill-rate (list :total 100 :cache 0 :processed 10 :time-ms 20)))
      "under 50ms the divisor is noise, so there is no rate")
  (is (null (prefill-rate (list :total 100 :cache 100 :processed 100 :time-ms 900)))
      "all cached means nothing was computed, so there is no rate to divide")
  (is (equal 1.0 (prefill-cached-fraction (list :total 10 :cache 999 :processed 999
                                                :time-ms 100)))
      "an over-reported cache is clamped to the prompt, never past it")
  (is (equal 0.0 (prefill-fraction (list :total 0 :cache 0 :processed 0 :time-ms 0)))
      "and no prompt is not a division by zero"))

(def-test prefill-bar-carries-the-cache-split-in-glyphs (:suite leticl)
  "Three runs, three GLYPHS, so the information survives a terminal with no
colour and a pipe to a file."
  (let* ((p (list :total 100 :cache 50 :processed 75 :time-ms 1000))
         (bar (progress-bar p 22)))
    (is (char= #\▐ (char bar 0)) "opens")
    (is (char= #\▌ (char bar (1- (length bar)))) "and closes")
    (is (= 22 (string-width bar)) "exactly the width asked for")
    (is (find #\█ bar) "the cached run is drawn")
    (is (find #\▓ bar) "the computed run is drawn, in a different glyph")
    (is (find #\░ bar) "and the remainder is drawn")
    ;; a zero prompt is still a bar, not an error
    (is (= 8 (string-width (progress-bar (list :total 0) 8))))))

(def-test prefill-line-drops-the-least-useful-field-first (:suite leticl)
  "It never wraps: a status line that wraps scrolls the transcript by a row
every frame, and that reads as flicker."
  (let ((p (list :total 1000 :cache 800 :processed 900 :time-ms 1000)))
    (let ((wide (prefill-line p 80)))
      (is (search "prefill 90%" wide) "the percentage is never dropped")
      (is (search "tok/s" wide) "a wide line keeps the rate")
      (is (search "left" wide) "and the estimate"))
    (dolist (cols '(80 40 24 16 8 4))
      (is (<= (string-width (prefill-line p cols)) cols)
          (format nil "at ~a columns the line fits" cols)))
    (is (equal "prefill 90%" (prefill-line p 12))
        "given room for the head alone, the head is what is left (it is 11 wide)")
    ;; **The cut is disclosed** (`trim_to` is `width::truncate` in the reference,
    ;; render.rs:44): six columns hold five characters and the `…` that says more
    ;; existed. It used to say `prefil`, which is a silently truncated word — the
    ;; progress line was the one row on the screen that elided without a mark.
    (is (equal "prefi…" (prefill-line p 6))
        "and narrower than the head itself it truncates, saying so, rather than wrapping")))

(def-test decode-line-says-the-word-and-the-rate (:suite leticl)
  (let ((s (decode-line 1200 3000 80)))
    (is (search "generating" s) "the phase is named, so the wait has a shape")
    (is (search "1200" s) "the count is there (thousands only shortens past 9999)")
    (is (search "400.0 tok/s" s) "1200 tokens in 3s is 400 tok/s")
    (is (search "3.0s" s) "and the elapsed time is there"))
  (is (<= (string-width (decode-line 1200 3000 12)) 12) "and it truncates"))

;;; ------------------------------------------- every frame the head owes is sent ;;;

(defun protocol-constructors ()
  "The names of every `make-*` frame constructor in src/protocol.lisp."
  (let* ((text (source-of "protocol"))
         (names nil)
         (i 0)
         (tag "(defun make-"))
    (loop
      for j = (search tag text :start2 i)
      while j
      do (let* ((start (+ j (length "(defun ")))
                (end (or (position-if (lambda (c) (member c '(#\space #\( #\))))
                                      text :start start)
                         (length text))))
           (push (subseq text start end) names)
           (setf i end)))
    (nreverse names)))

(def-test every-frame-constructor-is-actually-sent (:suite leticl)
  "A frame the head defines and never sends is a feature that does not exist.

This is P2's whole defect class, and it was four-fifths of the protocol:
`make-ack`, `make-resync`, `make-peek`, `make-list-todos` and
`make-resume-session` were all written in T9 and called from NOWHERE. The head
never acked, the `:peek` screen was unreachable because nothing asked for the
frame that fills it, `/todos` never asked for the list it drew, and a resync
could only ever be one the DAEMON initiated — which is the case that works and
so the case that proves nothing.

A constructor may legitimately go unsent for one reason: a frame the head
ANSWERS rather than asks. Those are named here, so silence is a decision rather
than an oversight."
  (let ((answers-only '("make-answer" "make-answer-question" "make-screen-answer"
                        "make-attach" "make-detach" "make-prompt" "make-interrupt"
                        "make-ack" "make-withdraw-prompts" "make-stop"
                        "make-withdraw" "make-secret" "make-stop-daemon"))
        (sent nil))
    ;; every other src file, as one blob of text
    (dolist (name '("head" "commands" "editor" "cards" "chrome" "panes" "render"
                    "session" "hack" "keys" "prefs" "progress" "diff" "markdown"
                    "highlight" "socket" "cells" "wire" "json" "width" "term"))
      (ignore-errors (setf sent (concatenate 'string sent (source-of name)))))
    (dolist (ctor (protocol-constructors))
      ;; the call is `(ctor` followed by anything that is not a symbol
      ;; character — a space, `)`, or a newline. Requiring a SPACE is the same
      ;; bug twice: `(make-settings)` has no space after the name, so a rule
      ;; that demanded one reported a live call as missing.
      (is (or (loop for i = (search (format nil "(~a" ctor) sent) then
                                  (search (format nil "(~a" ctor) sent :start2 (1+ i))
                    while i
                    thereis (let ((j (+ i 1 (length ctor))))
                              (or (>= j (length sent))
                                  (not (find (char sent j) *symbol-chars*
                                             :test #'char=)))))
              (member ctor answers-only :test #'string=))
          (format nil "~a is defined in protocol.lisp and called from nowhere — ~
either send it, or name it in answers-only with the reason" ctor)))))

;;; ------------------------------------------------- prefs ;;;

(defun count-substring (needle haystack)
  "How many times NEEDLE occurs in HAYSTACK, non-overlapping."
  (let ((n 0) (i 0))
    (loop for j = (search needle haystack :start2 i)
          while j
          do (incf n) (setf i (1+ j)))
    n))

(defun temp-prefs-path (tag)
  "A unique path under the OS temp dir, so a test never touches the real file."
  (merge-pathnames (format nil "leticl-test-~a-~a/head.toml" tag (random 1000000))
                   (uiop:temporary-directory)))

(defun forget-prefs-file (p)
  "Delete P and the directory `temp-prefs-path` made for it. Always NIL.

**The four preference tests deleted only the FILE**, and `with-open-file` had already
created the directory around it, so every suite run left one empty `leticl-test-…`
directory in the temp dir for ever. Measured 2026-09-22: **144 of them** — one per test
per run since the first of these landed — while the notes tests beside them cleaned up
after themselves properly, which is why it went unnoticed for two days.

A suite that leaves a mark on the machine is the same defect as a test that changes the
answer to the question it is asking. It only takes longer to notice, which is the whole
of the difference."
  (ignore-errors (delete-file p))
  (ignore-errors (uiop:delete-directory-tree
                  (uiop:pathname-directory-pathname p) :validate t))
  nil)

(def-test prefs-a-missing-file-is-the-defaults-not-an-error (:suite leticl)
  "The first run of a head is not a failure."
  (let* ((p (temp-prefs-path "missing"))
         (prefs (load-prefs p)))
    (is (string= "split" (prefs-diff prefs)) "the default diff is split")
    (is (string= "folded" (prefs-thinking prefs)) "thinking starts folded")
    (is (string= "folded" (prefs-tools prefs)) "tools start folded")
    (is (null (prefs-raw-calls prefs)) "raw calls start hidden")))

(def-test prefs-round-trip (:suite leticl)
  "What is saved is what is loaded, for every key."
  (let ((p (temp-prefs-path "roundtrip")))
    (unwind-protect
         (let ((out (make-prefs)))
           (setf (prefs-diff out) "unified"
                 (prefs-thinking out) "open"
                 (prefs-tools out) "open"
                 (prefs-raw-calls out) t)
           (save-prefs out p)
           (let ((back (load-prefs p)))
             (is (string= "unified" (prefs-diff back)))
             (is (string= "open" (prefs-thinking back)))
             (is (string= "open" (prefs-tools back)))
             (is (eq t (prefs-raw-calls back)))))
      (forget-prefs-file p))))

(def-test prefs-keeps-what-it-does-not-own (:suite leticl)
  "A comment, a section, and a key from a NEWER build all survive a save.

This is the property that makes the file the operator's rather than the head's:
it is edited with vi, and a build that does not recognise a key must not delete
it. The reference names the same rule, and the value a second `diff =` would be
the bug — a file that grows one per change reads as a list of decisions rather
than a set of settings."
  (let ((p (temp-prefs-path "keep")))
    (unwind-protect
         (progn
           (ensure-directories-exist p)
           (with-open-file (f p :direction :output :if-exists :supersede)
             (write-line "# mine, hand-edited" f)
             (write-line "diff = \"unified\"" f)
             (write-line "future_key = \"x\"" f)
             (write-line "[section]" f)
             (write-line "thinking = \"sideways\"" f))
           (multiple-value-bind (prefs notes) (load-prefs p)
             (is (string= "unified" (prefs-diff prefs)) "a good value is read")
             (is (string= "folded" (prefs-thinking prefs))
                 "a bad value falls back to the default")
             (is (some (lambda (n) (search "future_key" n)) notes)
                 "an unknown key is NAMED, not swallowed")
             (is (some (lambda (n) (search "sideways" n)) notes)
                 "and a bad value is named too")
             (setf (prefs-diff prefs) "split")
             (save-prefs prefs p))
           (let ((text (uiop:read-file-string p)))
             (is (eql 0 (search "# mine, hand-edited" text))
                 "the comment is still the first line")
             (is (search "future_key = \"x\"" text) "the unknown key survives")
             (is (search "[section]" text) "so does the section header")
             (is (search "diff = \"split\"" text) "our key is rewritten")
             (is (= 1 (count-substring "diff =" text))
                 "and NOT duplicated — one key, not one per save")))
      (forget-prefs-file p))))

(def-test prefs-a-bad-bool-is-named-and-defaulted (:suite leticl)
  (let ((p (temp-prefs-path "bool")))
    (unwind-protect
         (progn
           (ensure-directories-exist p)
           (with-open-file (f p :direction :output :if-exists :supersede)
             (write-line "raw_calls = maybe" f))
           (multiple-value-bind (prefs notes) (load-prefs p)
             (is (null (prefs-raw-calls prefs)) "the default is kept")
             (is (some (lambda (n) (search "maybe" n)) notes) "and it is named")))
      (forget-prefs-file p))))

(def-test head-prefs-plist-and-the-file-agree (:suite leticl)
  "The bridge both ways: a loaded file reaches the live plist, and the live plist
is what a save writes."
  (let ((head (%make-head))
        (p (make-prefs)))
    (setf (prefs-thinking p) "open" (prefs-tools p) "folded"
          (prefs-raw-calls p) t (prefs-diff p) "unified")
    (prefs-into-head head p)
    (is (eq t (getf (head-prefs head) :show-reasoning)) "thinking → the plist")
    (is (null (getf (head-prefs head) :show-tools)) "tools → the plist")
    (is (eq t (getf (head-prefs head) :raw-calls)))
    (is (string= "unified" (getf (head-prefs head) :diff)))
    ;; and back
    (setf (getf (head-prefs head) :show-tools) t)
    (let ((back (head-into-prefs head)))
      (is (string= "open" (prefs-thinking back)))
      (is (string= "open" (prefs-tools back)) "the flip came back")
      (is (string= "unified" (prefs-diff back))))))

(def-test prefs-save-does-not-grow-the-file (:suite leticl)
  "Saving twice writes the same bytes as saving once.

Both ways this could grow: a key appended beside its existing self, and a
trailing empty line carried in from the parse and written back. A file that
grows on every change reads as a history of decisions rather than a set of
settings, and it is the operator's file."
  (let ((p (temp-prefs-path "grow")))
    (unwind-protect
         (let ((out (make-prefs)))
           (setf (prefs-diff out) "unified")
           (save-prefs out p)
           (let ((first (uiop:read-file-string p))
                 (fresh (load-prefs p)))
             (save-prefs fresh p)
             (let ((second (uiop:read-file-string p)))
               (is (string= first second)
                   "a second save is byte-identical to the first")
               (is (= 1 (count-substring "diff =" second))
                   "and still has exactly one diff key"))))
      (forget-prefs-file p))))

;;; ------------------------------------------------- editor (S4) ;;;

(defun %composer-with (text &optional (cursor nil))
  (let ((c (make-composer)))
    (composer-insert c text)
    (when cursor (setf (composer-cursor c) cursor))
    c))

(def-test kill-ring-keeps-more-than-the-last-kill (:suite leticl)
  "`ctrl-k` then some editing then `ctrl-y` is the common shape, and a single
slot loses the first kill the moment you make a second one."
  (let ((*kill-ring* nil)
        (c (%composer-with "one two")))
    (setf (composer-cursor c) 3)
    (composer-kill-to-end c)
    (is (equal "one" (composer-buffer c)) "the kill cut to the end")
    (is (equal (list " two") *kill-ring*) "and it landed in the ring")
    ;; a SECOND kill, from a fresh buffer, must not lose the first
    (let ((c2 (%composer-with "abc")))
      (composer-kill-line c2)              ; cursor is at the end, so 0..3
      (is (equal "abc" (car *kill-ring*)) "the newer kill is at the head")
      (is (member " two" *kill-ring* :test #'string=)
          "and the older one is still in the ring")))
  ;; and the ring is bounded — one nobody can exhaust is a leak
  (let ((*kill-ring* nil)
        (c (make-composer)))
    (dotimes (i 30)
      (composer-insert c (format nil "kill~a" i))
      (composer-kill-line c))
    (is (<= (length *kill-ring*) *kill-ring-max*) "the ring stays bounded")))

(def-test yank-inserts-the-head-of-the-ring (:suite leticl)
  (let ((*kill-ring* (list "yanked" "older"))
        (c (%composer-with "ab")))
    (is (eq t (composer-yank c)) "the yank reported it did something")
    (is (equal "abyanked" (composer-buffer c)) "at the cursor")
    (is (null (composer-yank (progn (setf *kill-ring* nil) c)))
        "and with an empty ring it says so rather than inserting nothing silently")))

(def-test undo-takes-back-a-step (:suite leticl)
  "Snapshots, and the caller decides the granule — a per-character undo makes you
hold the key and hope."
  (let ((*undo-stack* nil)
        (c (%composer-with "hello")))
    (leticl::%undo-push c)
    (composer-insert c " world")
    (is (equal "hello world" (composer-buffer c)))
    (is (eq t (composer-undo c)) "undo reported it worked")
    (is (equal "hello" (composer-buffer c)) "and took back the insertion")
    (is (null (composer-undo c)) "with nothing left it says so")))

(def-test undo-does-not-push-a-duplicate-snapshot (:suite leticl)
  "Two pushes of the same buffer would make ctrl-z take two presses to undo one
edit — a key that sometimes does nothing is a key nobody trusts."
  (let ((*undo-stack* nil)
        (c (%composer-with "same")))
    (leticl::%undo-push c)
    (leticl::%undo-push c)
    (leticl::%undo-push c)
    (is (= 1 (length *undo-stack*)) "one snapshot, not three")))

(def-test a-long-paste-becomes-a-marker-and-still-sends-whole (:suite leticl)
  "The operator sees a marker, the model receives the paste. Both halves matter:
a three-thousand-line paste as composer text is a buffer nobody can see the end
of, and a paste that arrives truncated is worse than one that is awkward."
  (let ((*paste-ledger* nil)
        (c (make-composer))
        (big (format nil "~{~a~%~}" (loop for i from 1 to 300 collect (format nil "line ~a" i)))))
    (is (eq 300 (leticl::%paste-lines big)) "300 lines counted")
    (composer-insert-paste c big)
    (is (search "pasted 300 lines" (composer-buffer c))
        "the composer shows a marker, not 300 lines")
    (is (< (length (composer-buffer c)) 100) "and the marker is short")
    (is (string= big (expand-pastes (composer-buffer c)))
        "and it expands back to exactly the paste, byte for byte")))

(def-test a-short-paste-is-inserted-as-itself (:suite leticl)
  "Below five lines the marker costs more than it saves."
  (let ((*paste-ledger* nil)
        (c (make-composer)))
    (composer-insert-paste c (format nil "a~%b~%c~%d"))
    (is (equal (format nil "a~%b~%c~%d") (composer-buffer c))
        "four lines go in as they are")
    (is (null *paste-ledger*) "and nothing was remembered")))

(def-test expanding-a-paste-leaves-other-text-alone (:suite leticl)
  (let ((*paste-ledger* nil)
        (c (make-composer)))
    (composer-insert-paste c (format nil "~{~a~%~}" (loop for i from 1 to 10 collect "x")))
    (composer-insert c " before")
    (setf (composer-buffer c)
          (concatenate 'string "prefix " (composer-buffer c) " suffix"))
    (let ((out (expand-pastes (composer-buffer c))))
      (is (eql 0 (search "prefix " out)) "the text before is untouched")
      (is (search "suffix" out) "and the text after")
      (is (not (search "pasted" out)) "and no marker is left")))
  ;; the same marker twice expands in both places
  (let ((*paste-ledger* nil)
        (c (make-composer))
        (body (format nil "~{~a~%~}" (loop for i from 1 to 6 collect "y"))))
    (composer-insert-paste c body)
    (let ((marker (composer-buffer c)))
      (setf (composer-buffer c) (concatenate 'string marker " and " marker))
      (let ((out (expand-pastes (composer-buffer c))))
        (is (not (search "pasted" out)) "every occurrence is expanded")
        (is (= 2 (count-substring body out))
            "both of them — the whole paste, twice")))))

;;; ------------------------------------------------- chrome (S8) ;;;

(defun %screen-text (head)
  "Every row of the head's screen, as one string — the cells, which is what the
head actually drew, not the segments that were put there."
  (format nil "~{~a~^~%~}"
          (loop for r from 0 below (head-rows head)
                collect (let ((row (screen-row (head-screen head) r)))
                          (if row
                              (format nil "~{~a~}" (mapcar #'cell-ch row))
                              "")))))

(defun %on-head (&key (cols 60) (rows 20) (buffer ""))
  "A head with a screen of the given size and an optional composer buffer."
  (let ((h (%make-head)))
    (setf (head-cols h) cols (head-rows h) rows)
    (screen-resize (head-screen h) cols rows)
    (screen-resize (head-prev-screen h) cols rows)
    (leticl::%undo-push (head-composer h))
    (composer-insert (head-composer h) buffer)
    h))

(def-test the-composer-is-a-box-that-grows-with-the-buffer (:suite leticl)
  "A box with a title, whose bottom edge carries the wiring — the reference's
shape, and the most visible structural difference this head had: a bare `›` line
against a framed one."
  (let ((h (%on-head :rows 20)))
    (let ((rows (composer-line h 60)))
      (is (>= (length rows) 3) "a top edge, a body, a bottom edge")
      (let ((text (format nil "~{~a~^~%~}"
                          (mapcar (lambda (l) (apply #'concatenate 'string
                                                     (mapcar #'car l)))
                                  rows))))
        (is (search "╭" text) "the top edge opens")
        (is (search "╮" text) "and closes")
        (is (search "╰" text) "the bottom edge opens")
        (is (search "╯" text) "and closes")
        (is (search "›" text) "the prompt is inside")
        ;; every row is exactly COLS: a row one column over wraps in a terminal
        ;; and pushes the whole frame down a line on every keystroke
        (dolist (row rows)
          (is (= 60 (string-width
                     (apply #'concatenate 'string (mapcar #'car row))))
              "a composer row is exactly the frame's width"))))
    ;; the box grows with a multi-line buffer
    (let ((h2 (%on-head :rows 20)))
      (composer-insert (head-composer h2) (format nil "one~%two~%three"))
      (is (= 5 (length (composer-line h2 60)))
          "three lines of buffer means three body rows, plus two edges")
      (dolist (row (composer-line h2 60))
        (is (= 60 (string-width
                   (apply #'concatenate 'string (mapcar #'car row))))
            "and every one of them is still exactly the width")))))

(def-test a-short-screen-gets-the-bare-line-not-a-box (:suite leticl)
  "A box costs two rows its edges, and a composer must not eat the last row of
the transcript to draw a border."
  (let ((h (%on-head :rows 7)))
    (is (= 1 (length (composer-line h 60))) "one row, not three")
    (is (search "›" (format nil "~{~a~}"
                            (mapcar #'car (first (composer-line h 60)))))
        "and it is still the prompt")))

(def-test the-alarm-exists-only-when-something-is-wrong (:suite leticl)
  "A row that is always present is a row that costs the transcript a line to say
nothing."
  (let ((*resyncs* 0)
        (h (%on-head)))
    (setf (head-connected h) t)         ; a fresh head starts disconnected
    (is (null (alarm-line h 60)) "nothing wrong, no row")
    (setf (session-dropped (head-session h)) 3)
    (is (search "dropped 3" (format nil "~{~a~}" (mapcar #'car (alarm-line h 60))))
        "a non-zero counter shows")
    (setf (session-dropped (head-session h)) 0)
    (setf (head-connected h) nil)
    (is (search "detached" (format nil "~{~a~}" (mapcar #'car (alarm-line h 60))))
        "a disconnect shows even with clean counters")))

(def-test the-money-meter-lights-only-when-a-cost-was-seen (:suite leticl)
  "Free and unpriced are both 'no number', and `$0.0000` on every local header
would be noise."
  (let ((*spent-micros* 0) (*spent-seen* nil))
    (is (null (spent-text)) "no cost seen means no meter")
    (is (null (note-turn-cost (list :prompt-tokens 10))) "an absent cost adds nothing")
    (is (null (spent-text)) "and still lights nothing")
    (is (eq t (note-turn-cost (list :cost-micros-usd 42100))))
    (is (equal "$0.0421" (spent-text)) "42,100 micro-USD is $0.0421")
    (note-turn-cost (list :cost-micros-usd 1000))
    (is (equal "$0.0431" (spent-text)) "and costs accumulate")
    ;; the total belongs to the CONVERSATION: a switch clears it
    (reset-spent)
    (is (null (spent-text)) "a new conversation has its own bill")))

(def-test the-meters-total-is-cleared-by-a-hello (:suite leticl)
  "Carrying one session's bill onto another's header is wrong in the direction
that costs money, so a Switch — which lands as a Hello — clears it."
  (let ((*spent-micros* 0) (*spent-seen* nil) (h (%make-head)))
    (note-turn-cost (list :cost-micros-usd 5000000))
    (is (equal "$5.0000" (spent-text)))
    (leticl::%handle-frame h (list :frame "hello" :head-id "h1" :dropped 0
                           :snapshot (list :session-id "s2" :seq 0 :dropped 0
                                           :items-dropped 0 :items nil
                                           :turn nil :open-decisions nil
                                           :settled-decisions nil :warnings nil
                                           :heads nil)
                           :sessions nil :wiring nil))
    (is (null (spent-text)) "the new session starts at nothing")))

(def-test a-stall-is-a-claim-about-the-clock (:suite leticl)
  "A head nobody has told the time to must not guess, because a stall is a claim
about the clock."
  (let ((*now-ms* 0) (*last-event-ms* nil))
    (is (null (stalled-ms)) "no frames yet is not a stall")
    (setf *now-ms* 100000 *last-event-ms* 100000)
    (is (= 0 (stalled-ms)) "a frame just arrived")
    (setf *last-event-ms* 50000)
    (is (= 50000 (stalled-ms)) "50s of silence is measured")
    (is (search "no frames for 50" (stall-text)) "and said in words")
    (setf *last-event-ms* 95000)
    (is (null (stall-text)) "under the threshold it says nothing")
    ;; and a head with no clock refuses rather than guessing
    (setf *now-ms* 0)
    (is (null (stalled-ms)) "no clock means no claim")))

(def-test a-notice-expires-and-an-alarm-does-not (:suite leticl)
  "A notice that never expires becomes furniture — the old head pinned one to the
status line for the rest of the session.

**And the expiry is TIME, not frames.** The old body took one off a counter per loop
pass, so the sentence's lifetime was a function of the frame rate — and a note whose
counter had already reached 0 could never be cleared at all, because the body was
guarded on `(plusp ttl)`. That is the shape the operator found on their screen: a
magenta `permission answered` nobody could get rid of, on a head the loop was
painting the whole time. Time is measurable; frames are a rendering of it."
  (let ((h (%make-head))
        (leticl::*fixed-clock-ms* 1000))
    (say h "hello")
    (is (equal "hello" (head-status-note h)) "the note is there")
    (is (= (+ 1000 +notice-ttl-ms+) (head-notice-until h))
        "and its clock started, on the head, at the deadline")
    ;; it survives its TTL and then goes — elapsed, not counted
    (setf leticl::*fixed-clock-ms* (+ 1000 +notice-ttl-ms+ -1))
    (tick-notice h)
    (is (equal "hello" (head-status-note h)) "still there a millisecond before")
    (setf leticl::*fixed-clock-ms* (+ 1000 +notice-ttl-ms+))
    (tick-notice h)
    (is (null (head-status-note h)) "and gone the millisecond it is due")
    (is (zerop (head-notice-until h)) "with the clock stopped")
    ;; **THE FIELD DEFECT, AS AN ASSERTION.** A note set without a clock is the note
    ;; that could never be cleared; there is now no way to set one without the other,
    ;; and `clear-note` is the one way to take one down.
    (setf (head-status-note h) "detached")
    (is (zerop (head-notice-until h)) "writing the slot directly arms no clock — hence `say`")
    (dotimes (i 3) (tick-notice h))
    (is (equal "detached" (head-status-note h))
        "and the tick refuses to clear one nobody timed, rather than clearing it at once")
    (clear-note h)
    (is (null (head-status-note h)) "clear-note takes it down")
    (is (zerop (head-notice-until h)) "and stops a clock it never started")))

(def-test a-note-and-its-clock-cannot-come-apart (:suite leticl)
  "The defect, stated as the invariant that was missing.

MEASURED on the live head, while the operator looked at the line: `head-status-note`
`\"permission answered\"`, the TTL global `0`, `head-dirty` NIL — and identical two
seconds later, with the loop painting a running turn underneath it the whole time.
The note was never going to go, because the tick that ages it was guarded on
`(plusp ttl)` and the global had already reached 0.

**The clock is now a slot of the head the note lives on**, so there is no binding
that can be reached by one and not the other, and no `let` anywhere that can shadow
it into a private copy — the failure mode a global special invites in a tree that
rebinds its globals for replays. `notice-remaining-ms` reads them together, which is
the question the operator actually asked."
  (let ((h (%make-head)))
    (is (null (notice-remaining-ms h)) "a head with no note has no clock")
    (say h "something")
    (is (plusp (notice-remaining-ms h)) "a note says how long it has left, from its own head")
    ;; a `let` of a global cannot shadow a slot — the exact trap that let the note and
    ;; its clock be different objects
    (let ((leticl::*fixed-clock-ms* (internal-real-time-ms)))
      (declare (ignorable leticl::*fixed-clock-ms*))
      (is (plusp (notice-remaining-ms h))
          "and still does inside a dynamic extent that binds a global"))
    (clear-note h)
    (is (null (notice-remaining-ms h)) "clearing the note stops the clock with it")
    (is (null (head-status-note h)) "and takes the note down")))

(def-test the-hint-names-the-keys-that-work-here (:suite leticl)
  "A hint that names the wrong key is worse than no hint: the card's second
ctrl+c CLOSES it, so the editor's 'again to exit' would be a lie."
  (let ((h (%make-head)))
    (is (search "ctrl-s" (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))
        "the normal hint names the real chords")
    (setf (head-quit-open h) t)
    (is (search "esc stays" (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))
        "and the card's hint is about the card")
    (setf (head-quit-open h) nil (head-mode h) :help)
    (is (search "esc closes" (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))
        "a screen says how to leave it")))

(def-test the-frame-lays-out-backwards-from-the-composer (:suite leticl)
  "The composer's height is not fixed, so the transcript gets what is left —
getting that order wrong scrolls the transcript by a row on every keystroke."
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 60 :rows 20)))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "▌" text) "the session marker is drawn")
      (is (search "╭" text) "the composer's box is drawn")
      (is (search "›" text) "and its prompt")
      (is (search "╰" text) "and its bottom edge"))
    ;; with a taller composer, the transcript's last row moves UP
    (composer-insert (head-composer h) (format nil "a~%b~%c~%d"))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "╭" text) "the box is still there")
      (is (search "╰" text) "and complete"))))

;;; ----------------------------------------- cards: evidence that survives (S3) ;;;

(defun segs-of (lines)
  "SEGMENT LINES joined, for asserting on rendered output.

A LINE is a list of SEGMENTS; a SEGMENT is `(cons TEXT STYLE)`. Getting the
nesting wrong twice in this file is why this helper exists: `(car line)` is a
segment, and `(car (car line))` is the text."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (line) (format nil "~{~a~}" (mapcar #'car line)))
                  lines)))

(defun %card-lines (head cols)
  "Both halves of the card — CONTENT and LADDER — as a list of two lists.

**R20 split the return value in two**, and a caller that takes only the first value gets
a card with no options: the exact defect the split exists to fix, made by the test that
is supposed to catch it. Every test that wants *what is on the card* goes through here;
the render path is the one place that treats the halves differently, because it is the
one place that knows there are two."
  (multiple-value-list (leticl::permission-card-lines head cols)))

(defun %card-lines-all (head cols)
  "The whole card as ONE list of lines — both halves, in the order they are drawn."
  (let ((all nil))
    (dolist (half (%card-lines head cols))
      (setf all (append all half)))
    all))

(defun %card-text (head cols)
  "The whole card as readable text, one row per line."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (line) (format nil "~{~a~}" (mapcar #'car line)))
                  (%card-lines-all head cols))))

(defun lines-text (lines)
  "One string per line, for asserting on a pane's rows."
  (mapcar (lambda (line) (format nil "~{~a~}" (mapcar #'car line))) lines))

(def-test a-settled-row-keeps-its-duration (:suite leticl)
  "A `ToolResult` row carries no timestamps at all, so unless the head noted when
the call began, \"that grep took 4.1s\" leaves the screen the moment the row lands."
  (let ((*call-facts* nil) (*item-facts* nil) (*call-started-ms* nil))
    (note-call-started "call_0")
    ;; pretend it ran for a measurable time
    (setf (cdr (assoc "call_0" *call-started-ms* :test #'string=))
          (- (internal-real-time-ms) 4100))
    (note-call-finished "call_0")
    (is (numberp (getf (cdr (assoc "call_0" *call-facts* :test #'string=)) :ms))
        "the duration was measured and staged")
    ;; the row lands and adopts it
    (leticl::%adopt-call-facts "s1#t1.4" "call_0")
    (let* ((item (list :item-id "s1#t1.4" :kind "tool_result"
                       :item (list :type "tool_result" :call-id "call_0"
                                   :name "grep" :outcome (list :outcome "ok")
                                   :payload "a match")))
           (text (segs-of (item-lines item 80 (list :show-tools t)))))
      ;; the card names the call the way letibot does: VERB, target, outcome,
      ;; duration, line count — `grep` becomes `Searched`, because the word a
      ;; person reads is the verb and not the tool's own name
      (is (search "Searched" text) "the VERB is shown, from the tool name")
      (is (search "ok" text) "and its outcome")
      (is (search "4.1s" text)
          "and the DURATION, which only the head could have kept")
      ;; a ONE-line result rides the header, and the count does not: `· 1 line`
      ;; beside an inlined line is a count for a fold with nothing to fold
      (is (search "a match" text) "and the one line it returned, inlined")
      (is (not (search "1 line" text)) "with no count beside it"))))

(def-test a-row-this-head-did-not-watch-shows-no-duration (:suite leticl)
  "An absent fact shows NOTHING rather than a fabricated `0ms` — the same rule the
reference's `Replayed` phase holds. A snapshot, a restart or a replay of a log
recorded elsewhere all land here."
  (let ((*call-facts* nil) (*item-facts* nil))
    (let* ((item (list :item-id "old#t1.0" :kind "tool_result"
                       :item (list :type "tool_result" :call-id "call_0"
                                   :name "read" :outcome (list :outcome "ok")
                                   :payload "x")))
           (text (segs-of (item-lines item 80 (list :show-tools t)))))
      (is (search "Read" text) "the row still renders, with its verb")
      (is (not (search "ms" text)) "but claims no duration")
      (is (not (search "0s" text)) "and not a zero one either"))))

(def-test a-settled-row-keeps-its-diff (:suite leticl)
  "The operator's second report: *\"past edits lose their diff panels\"*. The live
card had the pair and the transcript row does not."
  (let ((*call-facts* nil) (*item-facts* nil) (*call-started-ms* nil))
    (note-call-started "call_2")
    (note-call-finished "call_2"
                        :edit (list :path "src/fib.lisp" :created nil
                                    :before-start 10 :after-start 10
                                    :before-lines 20 :after-lines 20 :truncated nil
                                    :before (format nil "a~%b~%c")
                                    :after (format nil "a~%B~%c")))
    (note-call-finished "call_2"
                        :edit (getf (cdr (assoc "call_2" *call-facts* :test #'string=)) :edit))
    (leticl::%adopt-call-facts "s1#t2.1" "call_2")
    (let* ((item (list :item-id "s1#t2.1" :kind "tool_result"
                       :item (list :type "tool_result" :call-id "call_2"
                                   :name "write" :outcome (list :outcome "ok")
                                   :payload "wrote")))
           (text (segs-of (item-lines item 80 (list :show-tools t :tools-open t)))))
      (is (search "src/fib.lisp" text) "the file is named")
      (is (search "11" text) "the changed line is numbered from the FILE, not the excerpt")
      (is (search "-b" text) "the removed line")
      (is (search "+B" text) "and the added one"))))

(def-test a-settled-row-keeps-the-decision-that-gated-it (:suite leticl)
  "The oracle's brief and reply used to leave the screen with the live card."
  (let ((*call-facts* nil) (*item-facts* nil) (*call-started-ms* nil))
    (note-call-started "call_3")
    (note-call-decision "call_3" (list :req-id "adj-1"
                                       :outcome (list :outcome "selected"
                                                      :option-id "allow_session")
                                       :by (list :kind "model" :identity "oracle")
                                       :basis "the operator authorised this"))
    (note-call-finished "call_3")
    (leticl::%adopt-call-facts "s1#t3.1" "call_3")
    (let* ((item (list :item-id "s1#t3.1" :kind "tool_result"
                       :item (list :type "tool_result" :call-id "call_3"
                                   :name "bash" :outcome (list :outcome "ok")
                                   :payload "done")))
           (text (segs-of (item-lines item 80 (list :show-tools t)))))
      ;; the reference's `decision_lines`: `· allowed, by model oracle`, and the
      ;; basis under it while the tools are open
      (is (search "allowed" text) "the decision is marked on the row, by its word")
      (is (search "by model oracle" text) "with who made it")
      (is (search "the operator authorised this" text) "and its basis"))))

(def-test the-item-id-is-what-survives-the-round (:suite leticl)
  "A call id is round-positional — every round starts again at `call_0` — so a
table keyed on it alone has every round of a long turn writing the same keys, and
a settled card reads back whichever round wrote last. The ITEM id is unique, so
the same call id in two rounds cannot collide."
  (let ((*call-facts* nil) (*item-facts* nil) (*call-started-ms* nil))
    ;; round one: call_0 takes 100ms
    (note-call-started "call_0")
    (setf (cdr (assoc "call_0" *call-started-ms* :test #'string=))
          (- (internal-real-time-ms) 100))
    (note-call-finished "call_0")
    (leticl::%adopt-call-facts "r1#1" "call_0")
    ;; a round boundary: the staging table is cleared
    (leticl::%round-boundary)
    ;; round two: call_0 AGAIN, but 5000ms
    (note-call-started "call_0")
    (setf (cdr (assoc "call_0" *call-started-ms* :test #'string=))
          (- (internal-real-time-ms) 5000))
    (note-call-finished "call_0")
    (leticl::%adopt-call-facts "r2#1" "call_0")
    ;; each row keeps its OWN duration, which keying on the call id could not do
    (is (equal 100 (getf (item-facts "r1#1") :ms)) "round one's row keeps 100ms")
    (is (equal 5000 (getf (item-facts "r2#1") :ms)) "round two's keeps 5000ms")
    (is (not (equal (getf (item-facts "r1#1") :ms)
                    (getf (item-facts "r2#1") :ms)))
        "and they are not the same number, which is the whole point")))

;;; -------------------- R13: a running call shows a live elapsed time -------- ;;;
;;;
;;; The operator, on a `cargo build` that prints nothing: *"it is frozen at 0ms until
;;; it finishes. A live coarse timer would be nice, say 1/10th of a second."*
;;;
;;; MEASURED FIRST, and the answer here is not the one letibot has: **this head's
;;; running elapsed was already read from its own clock** (`%call-elapsed-ms`, fed by
;;; `note-call-started` at `:tool-started` arrival), and it moves. What did not move
;;; was the FRAME. From the shell, on a scratch head with a 45-second-old running
;;; call, no eval in between (an eval POKES `head-dirty` to prove the loop can paint,
;;; `scripts/tui-eval:220`, so a probe that watches freshness keeps the frame fresh):
;;;
;;;     value  75637 ms -> 78680 ms            (moves)
;;;     glass  Running · 1m19s · 1m19s · 1m19s (frozen, four seconds)
;;;
;;; so the number was computed correctly and never ASKED FOR. R13's defect is one
;;; layer above where it was reported.

(def-test a-running-call-counts-on-this-heads-clock-not-the-daemons (:suite leticl)
  "**The trap, as an assertion.** A start instant that came from the daemon is on the
daemon's clock and `internal-real-time-ms` is ours; subtracting one from the other is
a duration measured across two clocks, silently wrong by whatever they disagree by,
and worst exactly when a head attaches to a daemon on another box.

So the anchored instant is this head's, taken when `:tool-started` ARRIVED
(`note-call-started`), and an envelope `ts` from the future or the past cannot move
it: the two are asserted to disagree, and the row is asserted to be unaffected."
  (let ((*call-started-ms* nil) (*call-facts* nil))
    (note-call-started "c1")
    (let ((anchored (cdr (assoc "c1" *call-started-ms* :test #'string=))))
      (is (numberp anchored) "the start is recorded on arrival")
      (is (<= (abs (- anchored (internal-real-time-ms))) 50)
          "and it is THIS clock's now, not a number that arrived on the wire")
      ;; shift the anchor a known 4.2 s back and the elapsed follows, exactly
      (setf (cdr (assoc "c1" *call-started-ms* :test #'string=))
            (- (internal-real-time-ms) 4200))
      (let ((ms (leticl::%call-elapsed-ms (list :call-id "c1"))))
        (is (<= 4200 ms (+ 4200 100))
            "the elapsed is the difference between two readings of ONE clock: ~d" ms))
      ;; and a call nobody saw start has no elapsed rather than a guess
      (is (null (leticl::%call-elapsed-ms (list :call-id "never-seen")))
          "no anchor is no duration, not zero"))))

(def-test a-live-duration-is-coarse-on-purpose (:suite leticl)
  "Tenths, and the operator's number: what the row answers is *is this moving, and
roughly how long has it been — a live coarse timer would be nice, say 1/10th of a
second*. The frame is rebuilt a tenth apart, so a tenth is the finest thing that can
reach the screen; rounding here makes the number honest about its own resolution
rather than churning two digits nobody reads."
  (dolist (case '((0 . 0) (1 . 0) (99 . 0) (100 . 100) (199 . 100) (840 . 800)
                  (999 . 900) (1000 . 1000) (57821 . 57800)))
    (is (= (cdr case) (%live-elapsed-ms (car case)))
        (format nil "~dms reads as ~dms" (car case) (cdr case))))
  ;; and the ROW says it in tenths, in the running tense
  (let ((*call-started-ms* (list (cons "c1" (- (internal-real-time-ms) 8400)))))
    (let ((row (segs-of (call-lines (list :call-id "c1" :name "bash"
                                          :state (list :state "running"))
                                    100))))
      (is (search "Running" row) "the running tense")
      (is (search "8.4s" row) "and a tenth: ~s" row)))
  ;; **the SETTLED duration is NOT rounded** — it was measured once, exactly, and the
  ;; row shows that; only a number that is still moving is coarse
  (let ((*call-facts* nil) (*call-started-ms* nil) (*item-facts* nil))
    (note-call-started "c2")
    (setf (cdr (assoc "c2" *call-started-ms* :test #'string=))
          (- (internal-real-time-ms) 1843))
    (note-call-finished "c2")
    (is (<= 1843 (getf (alexandria:assoc-value *call-facts* "c2" :test #'string=) :ms)
            (+ 1843 100))
        "the settled measurement is kept to the millisecond")))

(def-test a-frame-with-a-clock-in-it-is-rebuilt-by-the-clock (:suite leticl)
  "**R13's fix, at the layer it belongs to.** The loop paints when `head-dirty` is
set, and only a frame or a key sets it — so a number computed from the clock was
computed and never drawn again. The second reason to paint is the clock, and it
applies exactly while something on the frame is a function of time."
  (let ((leticl::*last-paint-ms* 0)
        (h (%make-head)))
    ;; nothing live: an idle head does NOT ask for frames, which is what keeps it off
    ;; the operator's CPU
    (is (not (live-frame-p h)) "an idle head has nothing on its frame that is a function of time")
    (is (not (live-frame-due-p h)) "so the clock asks for no frame")
    ;; a running turn: the spinner and `· {since}` on the border
    (setf (session-turn (head-session h)) (list :state (list :state "running") :calls nil))
    (is (live-frame-p h) "a running turn is a function of time")
    (setf leticl::*last-paint-ms* (internal-real-time-ms))
    (is (not (live-frame-due-p h)) "and a tenth has not passed since the last frame")
    (setf leticl::*last-paint-ms* (- (internal-real-time-ms) +live-frame-ms+))
    (is (live-frame-due-p h) "so a tenth later the clock asks for one")
    ;; a running CALL is a reason even with no turn above it — a promoted command,
    ;; and the row R13 is about
    (setf (session-turn (head-session h)) nil)
    (is (not (live-frame-p h)) "no turn, no call: quiet again")
    (setf (session-turn (head-session h))
          (list :state (list :state "finished")
                :calls (list (list :call-id "c1" :state (list :state "running")))))
    (is (live-frame-p h) "a running call is a function of time on its own")
    ;; and the loop's own decision, which is the two reasons in one place
    (setf (session-turn (head-session h)) nil
          leticl::*last-paint-ms* (internal-real-time-ms)
          (head-dirty h) nil)
    (is (not (or (head-dirty h) (live-frame-due-p h))) "nothing to do: the loop sleeps")
    (setf (head-dirty h) t)
    (is (or (head-dirty h) (live-frame-due-p h)) "an event is still reason enough")))

;;; ------------------------------------------------- pane scrolling (P41) ;;;

(def-test pane-scroll-counts-from-the-top-not-the-bottom (:suite leticl)
  "The polarity is the OPPOSITE of the transcript's, and copying it makes PageDown
a no-op that looks exactly like the swallowing it replaced.

`head-scroll` is a distance from the live tail, so `up` increases it. A pane has
no tail: its offset is a distance from the START, so `down` increases it."
  (let ((*pane-scroll* 0) (*pane-lines* 100) (*pane-room* 10))
    (pane-scroll-by 5)
    (is (= 5 *pane-scroll*) "down moves FORWARD through the pane")
    (pane-scroll-by -2)
    (is (= 3 *pane-scroll*) "up moves back toward the top")
    (pane-scroll-by -99)
    (is (= 0 *pane-scroll*) "and it clamps at the top")
    (pane-scroll-by 999)
    (is (= 90 *pane-scroll*) "and at the last page — 100 lines, 10 visible")))

(def-test pane-view-windows-the-content (:suite leticl)
  (let ((*pane-lines* 20) (*pane-room* 5)
        (lines (loop for i from 0 below 20
                     collect (list (cons (format nil "L~a" i) nil)))))  ; a line is a list of segments
    (setf *pane-scroll* 0)
    (is (equal '("L0" "L1" "L2" "L3" "L4") (lines-text (pane-view lines)))
        "at the top it shows the first rows")
    (setf *pane-scroll* 5)
    (is (equal '("L5" "L6" "L7" "L8" "L9") (lines-text (pane-view lines)))
        "moved down, it shows the next ones")
    ;; a pane shorter than its room shows what there is, never pads
    (setf *pane-lines* 3 *pane-scroll* 0 *pane-room* 10)
    (is (equal '("L0" "L1" "L2") (lines-text (pane-view (subseq lines 0 3))))
        "and it does not invent rows")))

(def-test a-pane-fits-more-than-it-can-show-without-scrolling (:suite leticl)
  "The bug this fixes: every pane drew `rows.truncate(room)` and swallowed the
scroll keys, so a 98-row file on a 40-row terminal had more than half of itself
unreachable. This repo's own TODO.md is that long."
  (let* ((*stdout* (make-string-output-stream))
         (*pane-scroll* 0)
         (h (%on-head :cols 60 :rows 12)))
    (setf (head-mode h) :help)
    (leticl::%render h)
    (is (> *pane-lines* *pane-room*)
        "the help screen is taller than the room it has, so it NEEDS to scroll")
    (let ((top (mapcar #'cell-ch (screen-row (head-screen h) 1))))
      (is (search "keys" (format nil "~{~a~}" (remove nil top)))
          "the first row of a pane is its top"))
    ;; scroll and the content moves
    (pane-scroll-by 5)
    (leticl::%render h)
    (let ((now (mapcar #'cell-ch (screen-row (head-screen h) 1))))
      (is (not (search "keys" (format nil "~{~a~}" (remove nil now))))
          "after scrolling, row 1 is no longer the header"))))

(def-test the-cursor-drags-the-window-with-it (:suite leticl)
  "A pane whose cursor can walk into rows that are never drawn is a pane with a
selection the operator cannot see — worse than one that cannot scroll at all."
  (let ((*pane-scroll* 0) (*pane-lines* 100) (*pane-room* 10))
    (scroll-pane-into-view 3)
    (is (= 0 *pane-scroll*) "a visible cursor does not move the window")
    (scroll-pane-into-view 25)
    (is (<= *pane-scroll* 25) "a cursor below the window drags it down")
    (is (> (+ *pane-scroll* *pane-room*) 25) "and the cursor is then inside it")
    (scroll-pane-into-view 2)
    (is (<= *pane-scroll* 2) "a cursor above the window drags it up")))

(def-test a-list-pane-reports-its-cursors-line-not-its-row (:suite leticl)
  "A pane's cursor indexes ROWS; the scroll offset counts LINES, and they differ
by every header above the list. Passing one where the other was meant scrolls to
the wrong place — the reference found this in its own test."
  (let ((h (%make-head)))
    ;; the events, newest first, as `apply-event` keeps them
    (setf (session-subagents (head-session h))
          (list (list :subagent-id "sub-2" :state "running" :prompt "second task" :role "worker")
                (list :subagent-id "sub-1" :state "done" :prompt "first task" :role "worker")))
    (setf (head-picker-sel h) 1)
    (multiple-value-bind (lines sel-line) (subagent-lines h 80)
      (is (< 1 sel-line) "the second ROW is not line 1 — there are headers above it")
      (is (< sel-line (length lines)) "and it is a line that exists")
      (is (search "second task" (format nil "~{~a~}" (mapcar #'car (nth sel-line lines))))
          "the line it names is the row the cursor is on"))))

;;; ---------------------------------------------------- the todos pane (P42) ;;;

(def-test a-todo-is-painted-by-its-state-and-open-is-left-alone (:suite leticl)
  "The operator, on seeing the items finally drawn: *\"colors?\"* — they were not
painted at all, while the jobs pane two keys away had been painting the same
three states the whole time.

An OPEN item is left alone on purpose: it is the default state and the majority
of any list, and colouring the majority spends the signal the other two carry."
  (let ((done (leticl::%todo-row-lines (list :indent 4 :mark :done :text "d" :body nil :item t)))
        (doing (leticl::%todo-row-lines (list :indent 4 :mark :doing :text "g" :body nil :item t)))
        (open (leticl::%todo-row-lines (list :indent 4 :mark :open :text "o" :body nil :item t))))
    (is (equal '(:fg :green) (cdr (second (first done)))) "done is green")
    (is (equal '(:fg :yellow) (cdr (second (first doing)))) "doing is yellow")
    (is (null (cdr (second (first open)))) "and open is left plain")))

(def-test the-indent-is-its-own-segment-so-the-colour-lands-on-the-box (:suite leticl)
  "Baked into the text, an indented row painted as `[x]     Phase 0` — the colour
in front of the whitespace rather than on the box. So the indent is carried and
emitted as its own segment, BEFORE the mark."
  (let* ((row (list :indent 8 :mark :done :text "Phase 0" :body nil :item t))
         (line (first (leticl::%todo-row-lines row))))
    (is (equal "        " (car (first line))) "the indent is its own segment, first")
    (is (equal "[x]" (car (second line))) "then the mark")
    (is (equal '(:fg :green) (cdr (second line))) "and the mark carries the colour")
    (is (equal " Phase 0" (car (third line))) "then the text")))

(def-test painting-an-open-box-emits-no-bare-reset (:suite leticl)
  "A colour helper that appends a RESET unconditionally emits a bare `ESC[0m`
after the most common row in the pane — an escape that closes nothing.

Asserting the GLYPHS is not enough for this one: both the box and the escape come
out looking right until you count the escapes, which is the only way it is
visible. The reference caught it exactly this way."
  (let ((open (format nil "~{~a~}" (mapcar #'car (first (leticl::%todo-row-lines
                                                         (list :indent 4 :mark :open
                                                               :text "x" :body nil :item t))))))
        (done (format nil "~{~a~}" (mapcar #'car (first (leticl::%todo-row-lines
                                                         (list :indent 4 :mark :done
                                                               :text "x" :body nil :item t)))))))
    (is (search "[ ]" open) "an open box renders as an empty box")
    (is (not (search (string (code-char 27)) open))
        "and carries NO escape at all, because its style is empty")
    (is (search "[x]" done) "a done box renders checked")))

(def-test a-folded-item-that-has-more-says-so (:suite leticl)
  "A folded item with detail marks itself `···`; one without does not — so the mark
means \"there is more\" rather than \"this is an item\"."
  (let* ((with (first (leticl::%todo-row-lines (list :indent 4 :mark :open :text "x"
                                                    :body (list "detail") :item t))))
         (without (first (leticl::%todo-row-lines (list :indent 4 :mark :open :text "y"
                                                       :body nil :item t)))))
    (is (search " x ···" (format nil "~{~a~}" (mapcar #'car with)))
        "an item with detail says there is more — ONE space before the dots, as letibot's screen has it")
    (is (not (search "···" (format nil "~{~a~}" (mapcar #'car without))))
        "and one without stays quiet")))

(def-test an-unfolded-item-shows-its-detail (:suite leticl)
  "The operator: *\"if a todo has some associated text? should i be able to expand
it somehow?\"*. Unfolded, the detail is drawn under the row."
  (let* ((row (list :indent 4 :mark :open :text "item one"
                    :body (list "pin: abc123" "Deps: T2") :item t))
         (lines (leticl::%todo-row-lines row :here t :open t))
         (text (format nil "~{~a~^~%~}" (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines))))
    (is (= 3 (length lines)) "the row, and both detail lines")
    (is (search "pin: abc123" text) "the detail is drawn")
    (is (search "Deps: T2" text) "all of it, in file order")
    (is (search "▸ [ ] item one" text) "under the cursor, which is the only row that can be open")
    (is (not (search "···" text)) "and an open item does not also say there is more")))

;;; ------------------------------------------------- pickers (P22, P23) ;;;

(defun %head-with-settings ()
  (let ((h (%make-head)))
    (setf (head-settings h)
          (list (list :key "mode" :value "automode-edits (this box)"
                      :choices (list "read-only" "always-ask" "writes allowed" "automode"
                                     "automode-edits" "allow-all"))
                (list :key "model" :value "deepseek/deepseek-flash"
                      :choices (list "local" "deepseek/deepseek-flash" "glm/glm-5.3-flash"))))
    h))

(def-test the-mode-picker-is-a-card-with-the-references-rows (:suite leticl)
  "The operator: *\"mode switch doesnt work and it doesnt look like the one from
letibot … i cant change selection, and in letibot it is not a full pane\"*. The
reference's `mode_picker_lines`: a bold title, `▸  1  name` rows with the
cursor's text reversed and `← now` on the one in force, two dim hint rows — a
CARD above the composer, the transcript still above it."
  (let* ((h (%head-with-settings))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil))
    (open-pick h :mode)
    (is (eq :normal (head-mode h)) "no full-body pane: the transcript stays")
    (is (= 4 (head-picker-sel h)) "seeded on what answers now (automode-edits is the fifth)")
    (let* ((lines (pick-card-lines h 100))
           (text (lines-text lines)))
      (is (string= "the mode this session runs under" (first text)) "the title")
      (is (uiop:string-prefix-p "   1  read-only" (second text))
          "a row: mark, number, name — padded to the width, as `split_row` pads")
      (is (uiop:string-prefix-p "▸  5  automode-edits" (sixth text)) "the cursor's row")
      (is (search "← now" (sixth text)) "says it is the one in force")
      (is (= 100 (string-width (sixth text))) "and is padded to the card's width")
      (is (getf (cdr (first (sixth lines))) :reverse) "the mark and number are in reverse video")
      (is (getf (cdr (second (sixth lines))) :reverse) "and so is the name")
      (is (not (getf (cdr (third (sixth lines))) :reverse))
          "but the padding is plain, as the reference's raw row has it")
      (is (search "↑↓ moves · enter switches · or type a name or the number on the left · esc closes" (eighth text))
          "the hint row")
      (is (search "a mode change moves THIS session" (ninth text)) "and what a change means"))))

(def-test a-picker-with-no-choices-says-why-not-guesses (:suite leticl)
  "A picker whose list is empty because nobody asked the daemon is a picker that
looks broken — so it says which it is, in the reference's words."
  (let ((h (%make-head)) (leticl::*pick-open* :mode))
    (let ((text (format nil "~{~a~^~%~}" (lines-text (pick-card-lines h 120)))))
      (is (search "this daemon has not named its modes" text) "it names the problem")
      (is (search "/mode NAME" text) "and the way through"))))

(def-test the-models-picker-lists-models-not-modes (:suite leticl)
  (let* ((h (%head-with-settings)) (leticl::*pick-open* :model))
    (let ((text (format nil "~{~a~^~%~}" (lines-text (pick-card-lines h 120)))))
      (is (search "what answers this conversation" text) "its own title")
      (is (search "deepseek/deepseek-flash" text) "the model row's choices")
      (is (search "glm/glm-5.3-flash" text) "all of them")
      (is (not (search "read-only" text)) "and NOT the mode row's")
      (is (search "/default-model NAME" text) "and the third hint, which is the models'"))))

(def-test the-picker-moves-and-takes-its-pick (:suite leticl)
  "↑↓ wrap, a digit takes that row, enter takes the cursor's, esc closes — and a
name typed under the card is matched at enter (`pick_mode`): the number, an exact
name with `_`/space/case forgiven, or a unique prefix. The frames are witnessed on
the head's own stream, a string stream standing in for the socket."
  (let* ((h (%head-with-settings))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (wire (make-string-output-stream)))
    (setf (leticl::head-stream h) wire (head-connected h) t)
    (flet ((sent ()
             ;; every frame written so far, decoded, newest first
             (let ((text (get-output-stream-string wire)))
               (nreverse (mapcar #'json-decode
                                 (remove "" (uiop:split-string text :separator '(#\newline))
                                         :test #'string=))))))
      (open-pick h :mode)
      (is (= 4 (head-picker-sel h)) "seeded on the mode in force")
      (leticl::%handle-key h (list :type :down))
      (is (= 5 (head-picker-sel h)) "down moves the cursor")
      (leticl::%handle-key h (list :type :down))
      (is (= 0 (head-picker-sel h)) "and wraps")
      (leticl::%handle-key h (list :type :up))
      (is (= 5 (head-picker-sel h)) "up wraps the other way")
      ;; a digit takes that row
      (leticl::%handle-key h (list :type :char :ch #\2))
      (is (null leticl::*pick-open*) "the card closes")
      (let ((f (first (sent))))
        (is (equal "mode" (getf f :frame)) "a mode frame went out")
        (is (equal "always-ask" (getf f :name)) "carrying the row's name")
        (is (null (getf f :consented)) "not consented — only allow-all asks"))
      ;; the mode in force is said, not sent
      (open-pick h :mode)
      (leticl::%handle-key h (list :type :enter))
      (is (null (sent)) "enter on the mode already in force sends nothing")
      ;; a typed name
      (open-pick h :mode)
      (composer-insert (head-composer h) "Writes_Allowed")
      (leticl::%handle-key h (list :type :enter))
      (is (equal "writes allowed" (getf (first (sent)) :name))
          "a typed name matches with case, `_` and spaces forgiven")
      ;; a unique prefix
      (open-pick h :mode)
      (composer-insert (head-composer h) "read")
      (leticl::%handle-key h (list :type :enter))
      (is (equal "read-only" (getf (first (sent)) :name)) "a unique prefix")
      ;; allow-all asks first
      (open-pick h :mode)
      (leticl::%handle-key h (list :type :char :ch #\6))
      (is (equal "allow-all" leticl::*mode-confirm*) "allow-all opens the question")
      (is (null (sent)) "and sends nothing yet")
      (is (search "[y] or [enter] confirm" (format nil "~{~a~^~%~}" (lines-text (mode-confirm-lines 200))))
          "the question is on the screen")
      (leticl::%handle-key h (list :type :char :ch #\y))
      (let ((f (first (sent))))
        (is (equal "allow-all" (getf f :name)))
        (is (eq t (getf f :consented)) "y sends it consented"))
      (is (null leticl::*mode-confirm*) "and the question is gone")
      ;; esc closes
      (open-pick h :mode)
      (leticl::%handle-key h (list :type :esc))
      (is (null leticl::*pick-open*) "esc closes the card"))))

(def-test a-picker-opens-only-when-the-rows-are-asked-for (:suite leticl)
  "The picker's list IS the daemon's choices, so opening it asks if it has to."
  (let ((h (%make-head)))
    (is (null (setting-choices h "mode")) "with no rows, there is nothing to list")
    (setf (head-settings h) (list (list :key "mode" :value "x" :choices (list "x" "y"))))
    (is (equal '("x" "y") (setting-choices h "mode")) "and once asked, there is")))

;;; ------------------------------------------------------- bindings (S9) ;;;

(defun %press (head &rest keys)
  "Press each key in order on HEAD, as the key loop would.

Through `%handle-key`, which is what the loop calls: the head's own chords run
above every view now, so pressing one straight into `%normal-key` would test a
path the operator cannot reach."
  (dolist (k keys) (leticl::%handle-key head k)))

(def-test the-new-chords-reach-the-features-they-name (:suite leticl)
  "A chord bound to a feature that does not exist is worse than no chord, which is
why these landed AFTER the features."
  (let ((*pane-scroll* 0) (*repo-todo-open* nil)
        (h (%make-head)))
    ;; ctrl-r and ctrl-t flip the folds, which now persist (S5)
    (let ((before (getf (head-prefs h) :show-reasoning)))
      (%press h (list :type :ctrl :ch #\r))
      (is (not (eq before (getf (head-prefs h) :show-reasoning)))
          "ctrl-r flips the thinking fold"))
    (let ((before (getf (head-prefs h) :show-tools)))
      (%press h (list :type :ctrl :ch #\t))
      (is (not (eq before (getf (head-prefs h) :show-tools)))
          "ctrl-t flips the tool fold"))
    ;; ctrl-p/g/q open their panes through the one command path
    (%press h (list :type :ctrl :ch #\p))
    (is (eq :todos (head-mode h)) "ctrl-p opens the todos pane")
    (setf (head-mode h) :normal)
    (%press h (list :type :ctrl :ch #\g))
    (is (eq :subagents (head-mode h)) "ctrl-g opens the subagents pane")
    (setf (head-mode h) :normal)
    (%press h (list :type :ctrl :ch #\q))
    (is (eq :jobs (head-mode h)) "ctrl-q opens the jobs pane")
    (setf (head-mode h) :normal)
    (%press h (list :type :ctrl :ch #\s))
    (is (eq :picker (head-mode h)) "ctrl-s opens the session list")
    ;; ctrl-x reveals raw markup, which is NOT a fold
    (setf (head-mode h) :normal)
    (let ((before (getf (head-prefs h) :raw-calls)))
      (%press h (list :type :ctrl :ch #\x))
      (is (not (eq before (getf (head-prefs h) :raw-calls)))
          "ctrl-x flips the raw-call reveal"))))

(def-test the-help-names-the-chords-that-exist (:suite leticl)
  "The help IS the contract surface: a chord it does not name is a chord the
operator has to guess. The rows are the reference's own (`help_lines`), so the
list is what ITS help names — ctrl-g, ctrl-q and ctrl-o are bound in both heads
and named by neither's help, and the panes they open say so themselves."
  (let* ((text (format nil "~{~a~^~%~}" (lines-text (help-lines 100)))))
    (dolist (chord '("ctrl-r" "ctrl-t" "ctrl-n" "ctrl-x" "ctrl-s" "ctrl-p" "ctrl-c"
                     "ctrl-y" "ctrl-z" "alt+enter" "esc esc" "ctrl-l"))
      (is (search chord text) (format nil "the help names ~a" chord)))))

(def-test promote-says-which-silence-it-is (:suite leticl)
  "The reference's own distinction: a head that says the same thing for 'no
command running' and 'the model is still working' sends the operator looking for
a command that was never started."
  (let ((h (%make-head)))
    ;; no turn at all
    (leticl::%command h "promote")
    (is (search "nothing is running" (head-status-note h))
        "with no turn, it says nothing is running")
    ;; a turn running, no calls yet
    (setf (session-turn (head-session h))
          (list :turn-id "t" :text "" :reasoning "" :calls nil
                :state (list :state "running")))
    (leticl::%command h "promote")
    (is (search "still working" (head-status-note h))
        "with a turn but no command, it says the MODEL is working")))

;;; ------------------------------------- deny-and-tell, and one reason (P45/P46) ;;;

(defun %decision-with (&key (kind "permission"))
  (list :req-id "adj-1" :kind kind :summary "run a program"
        :options (list (list :option-id "allow_once" :label "Allow once" :kind "allow_once")
                       (list :option-id "allow_always" :label "Always allow" :kind "allow_always")
                       (list :option-id "reject_always" :label "Deny, and tell why"
                             :kind "reject_always")
                       (list :option-id "deny" :label "Deny" :kind "reject"))))

(def-test deny-and-tell-takes-the-words-that-were-refused (:suite leticl)
  "The operator: *\"deny and tell doesnt work - there is no input for the 'tell'
part\"*. The option was labelled `Deny, and tell the model why` and the why had
nowhere to go — worse, typing it was REFUSED, so the line stayed in the composer
and NOTHING was answered while they looked at their own sentence."
  (let ((d (%decision-with)))
    (multiple-value-bind (id tag note) (match-option d "reject_always use the scratch dir")
      (is (string= "reject_always" id) "the option is named")
      (is (eq :note tag) "the words go in the NOTE field, and the tag says so")
      (is (string= "use the scratch dir" note) "and the words ARE the note"))))

(def-test the-glob-still-goes-to-the-option-that-writes-a-rule (:suite leticl)
  "The change must not take the glob away from always-allow: both trailing-word
cases live in one matcher and only one of them may win per option."
  (let ((d (%decision-with)))
    (multiple-value-bind (id tag pattern) (match-option d "allow_always /tmp/*")
      (is (string= "allow_always" id))
      (is (eq :glob tag) "and its trailing words are a GLOB, which the tag says")
      (is (string= "/tmp/*" pattern) "the glob rides on always-allow"))))

(def-test an-option-that-promised-nothing-refuses-trailing-words (:suite leticl)
  "Somebody who typed them meant them, and answering as though they had not is the
answer they did not give — so the words are refused, not silently dropped."
  (let ((d (%decision-with)))
    (is (null (match-option d "deny because I said so"))
        "a plain deny takes no words")))

(def-test a-ladder-answer-needs-no-words (:suite leticl)
  "The ladder answers by id alone, which is what most answers are."
  (let ((d (%decision-with)))
    (multiple-value-bind (id tag extra) (match-option d "allow_once")
      (is (string= "allow_once" id) "the id matches")
      (is (eq :option tag) "and it answers by option id")
      (is (null extra) "with nothing extra"))))

(def-test a-refusal-does-not-say-its-reason-twice (:suite leticl)
  "The operator, counting the repeats in one card: *\"how many times is 'nothing
ran' needed?\"* — once. It was three, and the card was 21 lines for one refused
command."
  (let ((*item-facts* nil))
    (let* ((basis "refused: the request was for a path outside the workspace, and nothing ran because the programme was never started at all")
           (payload (format nil "outcome: not run~%~a~%extra detail" basis))
           (item (list :item-id "r1" :kind "tool_result"
                       :item (list :type "tool_result" :call-id "c" :name "bash"
                                   :outcome (list :outcome "not_run") :payload payload))))
      (setf *item-facts* (list (cons "r1" (list :decision (list :req-id "a"
                                                                :outcome (list :outcome "selected"
                                                                               :option-id "deny_once")
                                                                :by (list :kind "operator")
                                                                :basis basis)))))
      (let ((text (segs-of (item-lines item 120 (list :show-tools t)))))
        (is (<= (count-substring basis text) 1)
            "the reason is said at most ONCE, not once per place that knows it —
and here it is not repeated at all, because the payload renders its first line
and the decision line would have been the second copy")
        (is (search "refused, by operator" text)
            "and the verdict is still there, which is what the row adds"))))
  ;; and a reason the payload does NOT carry is still said
  (let ((*item-facts* nil))
    (let ((basis "the operator declined this because the path is outside every grant the session holds"))
      (setf *item-facts* (list (cons "r2" (list :decision (list :req-id "a"
                                                                :outcome (list :outcome "selected"
                                                                               :option-id "deny_once")
                                                                :by (list :kind "operator")
                                                                :basis basis)))))
      (let* ((item (list :item-id "r2" :kind "tool_result"
                         :item (list :type "tool_result" :call-id "c" :name "bash"
                                     :outcome (list :outcome "not_run") :payload "nothing ran")))
             (text (segs-of (item-lines item 120 (list :show-tools t)))))
        (is (search basis text)
            "where the payload does NOT say it, dropping it would lose the reason")))))

;;; ------------------------------------------------------- mouse click (P27) ;;;

(def-test a-click-selects-the-row-under-the-pointer (:suite leticl)
  "The reference's own guarded clicks: a click is only trusted for a row the frame
proved was on screen, because a click into the blank space below a short list must
not select a row nobody can see."
  (let ((*pane-scroll* 0) (*pane-lines* 20) (*pane-room* 10)
        (h (%make-head)))
    (setf (session-sessions (head-session h))
          (list (list :session-id "s1" :title "one")
                (list :session-id "s2" :title "two")
                (list :session-id "s3" :title "three"))
          (head-mode h) :picker
          (session-session-id (head-session h)) "s1")
    ;; the picker's header is two lines (title, blank) and every session is
    ;; two more (the row, the id under it), so lines 2 and 3 are both row 0
    (is (= 0 (click-row->sel h :picker 2)) "the first row is the first session")
    (is (= 0 (click-row->sel h :picker 3)) "and so is the id line under it")
    (is (= 1 (click-row->sel h :picker 4)) "the second is the second")
    (is (= 2 (click-row->sel h :picker 6)) "and the third")
    (is (null (click-row->sel h :picker 0)) "the title is not a row")
    (is (null (click-row->sel h :picker 1)) "nor is the blank under it")
    (is (null (click-row->sel h :picker 8)) "nor is the blank space below the list")))

(def-test a-click-is-not-trusted-below-a-truncated-list (:suite leticl)
  "The reference: *\"a click into the blank space below a truncated list must not
select a session nobody can see.\"*"
  (let ((*pane-scroll* 0) (*pane-lines* 5) (*pane-room* 3)
        (h (%make-head)))
    (setf (session-sessions (head-session h))
          (list (list :session-id "s1" :title "one")
                (list :session-id "s2" :title "two")
                (list :session-id "s3" :title "three")
                (list :session-id "s4" :title "four")
                (list :session-id "s5" :title "five"))
          (head-mode h) :picker)
    (is (integerp (click-row->sel h :picker 2)) "a visible row is selectable")
    ;; line 3 is past the visible room (3 lines) but before the list's end — a
    ;; click there must still be refused, because it is not on screen
    (is (null (click-row->sel h :picker 3))
        "a row below the drawn window is not") ))

(def-test the-click-conversion-asks-the-pane-for-its-header (:suite leticl)
  "One place per pane, so a header that grows moves the click arithmetic with it.
Asking the pane (by forcing its cursor to 0) rather than recounting is what keeps
the two from drifting."
  (let ((h (%make-head)))
    (setf (head-mode h) :picker
          (session-sessions (head-session h)) (list (list :session-id "s" :title "t")))
    (is (integerp (click-header-lines h)) "the picker reports its header")
    (setf (head-mode h) :todos)
    (is (integerp (click-header-lines h)) "so does the todos pane")
    ;; and forcing the cursor did not disturb it
    (setf (head-picker-sel h) 2)
    (click-header-lines h)
    (is (= 2 (head-picker-sel h)) "the cursor is restored after asking")))

;;; ---------------------------------------------- the config pane (P21) ;;;

(def-test the-config-pane-is-editable-in-place (:suite leticl)
  "The ask was a pane with runtime-editable settings, not a list to read. The
HEAD's own rows can be changed here; the daemon's cannot, and the pane says so."
  (let ((*prefs* (make-prefs))
        (h (%make-head)))
    (setf (head-prefs h) (list :show-reasoning nil :show-tools nil :raw-calls nil
                               :diff "split"))
    (let ((lines (config-lines h nil 80)))
      (let ((text (segs-of lines)))
        (is (search "config" text) "the pane names itself")
        (is (search "head — this window" text) "and says which half is the head's")
        (is (search "session — not attached, so nothing to list" text)
            "and, with no daemon rows yet, says so where the daemon's section would be")
        (is (search "✎ diff view" text) "the head's rows are marked changeable")
        (is (search "diff view        split" text)
            "and their values are shown from the LIVE plist"))
      ;; enter flips the selected row
      (setf (head-picker-sel h) 0)       ; `diff view` is the first head row
      (leticl::config-change h)
      (is (string= "unified" (getf (head-prefs h) :diff)) "enter flipped the diff shape")
      (is (search "diff view        unified" (segs-of (config-lines h nil 80)))
          "and the pane says so on the next frame")
      (is (search "diff view → unified" (head-status-note h))
          "and the note says what changed, as the reference's does"))))

(def-test the-config-pane-shows-the-live-value-not-the-file (:suite leticl)
  "The file is where a choice is WRITTEN; the plist is what is in effect. Between a
change and a save the two disagree, and the pane must show what is true."
  (let ((h (%make-head)))
    (setf (head-prefs h) (list :show-reasoning t :show-tools nil :raw-calls nil
                               :diff "unified"))
    (let ((text (segs-of (config-lines h nil 80))))
      (is (search "thinking         open" text) "the live fold, not the file's")
      (is (search "tool output      folded" text) "and the other"))))

;;; ------------------------------------------- the turn footer and queue (P13) ;;;

(def-test an-ordinary-turn-ending-draws-no-footer (:suite leticl)
  "The comparison against letibot's own screen is what found this: ours drew a
whole telemetry row (`─ 1.01M in/1.01M cached · 91 out · 17.8 tok/s · 5.1s`) where
the reference draws NOTHING, because an ordinary ending reads as ordinary and the
turn's numbers belong on the composer box's edge while it is running."
  (let ((turn (list :turn-id "t" :model "m" :text "" :reasoning "" :calls nil
                    :state (list :state "finished" :finish-reason "eos"
                                 :usage (list :prompt-tokens 40000 :cached-tokens 39000
                                              :predicted-tokens 150)
                                 :timings (list :predicted-ms 3000 :wall-ms 4200)))))
    (is (null (turn-footer-lines turn 80))
        "an eos ending produces no line at all")
    (setf (getf (getf turn :state) :finish-reason) "word")
    (is (null (turn-footer-lines turn 80)) "and neither does a `word` ending")
    (setf (getf (getf turn :state) :finish-reason) "length")
    (is (search "CUT SHORT" (segs-of (turn-footer-lines turn 80)))
        "but hitting the output limit says so")))

(def-test an-unusual-ending-is-shouted-and-a-failure-shouts-redder (:suite leticl)
  "The endings a person must not have to go looking for. `Failed` is a different
register: red and bold, because the reason is the whole content of the event."
  (let ((mk (lambda (state)
              (list :turn-id "t" :model "m" :text "" :reasoning "" :calls nil
                    :state state))))
    (is (search "stopped early" (segs-of (turn-footer-lines (funcall mk (list :state "finished" :finish-reason "aborted")) 80))))
    (is (search "unrecognised reason" (segs-of (turn-footer-lines (funcall mk (list :state "finished" :finish-reason "weird_new_thing")) 80)))
        "a reason nobody recognises is SHOWN, never normalised")
    (let* ((lines (turn-footer-lines (funcall mk (list :state "interrupted" :reason "ctrl+c" :partial-kept t)) 80))
           (style (cdr (first (first lines)))))
      (is (search "interrupted: ctrl+c" (segs-of lines)))
      (is (search "kept" (segs-of lines)) "and whether the partial was kept")
      (is (equal '(:fg :yellow) style) "in the alarm register"))
    (let* ((lines (turn-footer-lines (funcall mk (list :state "failed" :error "no route" :partial-kept nil)) 80))
           (style (cdr (first (first lines)))))
      (is (search "FAILED — no route" (segs-of lines)))
      (is (search "nothing was recorded" (segs-of lines)))
      (is (equal '(:fg :red :bold t) style) "and a failure is red and bold"))))

(def-test a-running-turn-has-no-footer-line (:suite leticl)
  "While a turn runs its numbers are on the box edge (`turn-status`), so a footer
row as well would be the same fact twice — the defect the reference names."
  (let ((turn (list :turn-id "t" :model "m" :text "hi" :reasoning "" :calls nil
                    :tokens 100 :state (list :state "running"))))
    (is (null (turn-footer-lines turn 80)) "no footer while running")
    (is (stringp (turn-status (let ((h (%make-head)))
                                (setf (session-turn (head-session h)) turn) h)))
        "and the edge is where the numbers are")))

(def-test a-queued-prompt-is-visible-before-its-row-lands (:suite leticl)
  "Between the enter press and the daemon appending the row, the words existed
NOWHERE on the screen: the composer had handed them off and the conversation had
swallowed them. Not lost and VISIBLE are different requirements."
  (let ((h (%make-head)))
    (setf (head-queued h) (list "second" "first"))   ; newest first, as pushed
    (let ((text (segs-of (queued-lines h 80))))
      (is (search "first" text) "the first queued prompt is drawn")
      (is (search "second" text) "and the second")
      (is (search "queued" text) "marked as queued")
      (is (< (search "first" text) (search "second" text))
          "and oldest first, so the order they will land in is the order they read")))
  ;; nothing queued is nothing drawn
  (is (null (queued-lines (%make-head) 80)) "an empty queue draws no rows"))

;;; ------------------------------------------------- cluster-aware width (P7) ;;;

(defun %ch (code) (code-char code))

(def-test a-cluster-is-not-a-chain-of-characters (:suite leticl)
  "The visible win, and the reason this matters at all: measured per CHARACTER a
ZWJ emoji family is six columns and a flag is four, so a right border lands three
columns inside the text."
  ;; 👨‍👩‍👧 — three emoji joined by ZWJ: ONE cluster, TWO columns
  (let ((family (format nil "~C~C~C~C~C" (%ch #x1f468) (%ch #x200d)
                        (%ch #x1f469) (%ch #x200d) (%ch #x1f467))))
    (is (= 1 (length (clusters family))) "the family is one cluster")
    (is (= 2 (string-width family)) "and two columns, not six"))
  ;; 🇬🇧 — two regional indicators: one cluster, two columns
  (let ((flag (format nil "~C~C" (%ch #x1f1ec) (%ch #x1f1e7))))
    (is (= 1 (length (clusters flag))) "a flag is one cluster")
    (is (= 2 (string-width flag)) "and two columns, not four"))
  ;; a combining mark rides with its base
  (let ((accented (format nil "e~C" (%ch #x301))))
    (is (= 1 (length (clusters accented))) "e + combining acute is one cluster")
    (is (= 1 (string-width accented)) "one column")))

(def-test a-control-character-is-not-a-combining-mark (:suite leticl)
  "A newline measures zero columns for the same reason a combining mark does, and
that is the whole of the resemblance: absorbing one into the cluster before it
hides a row break INSIDE a cell, and a break inside a cell is not a break. The
reference records the consequence — a two-line composer wrapped to one row with a
literal newline in it."
  (let ((two-lines (format nil "a~%b")))
    (is (= 3 (length (clusters two-lines)))
        "the newline is its own cluster, not absorbed into `a`")
    (is (= 2 (string-width two-lines)) "and it takes no columns")
    (is (find #\newline (mapcar #'cluster-text (clusters two-lines))
              :test (lambda (a b) (search (string a) b)))
        "it is present as text, which is what lets a caller SEE the break")))

(def-test escapes-measure-zero-and-stay-attached (:suite leticl)
  "An escape is not content, and dropping it would leave attributes open."
  (let ((styled (format nil "~C[0;1;36mred~C[0m" (%ch 27) (%ch 27))))
    (is (= 3 (string-width styled)) "the escapes take no columns")
    (is (= 4 (length (clusters styled)))
        "and they ride with their cluster rather than becoming text")
    (is (search (format nil "~C[0;1;36m" (%ch 27)) (cluster-esc (first (clusters styled))))
        "the opening escape is carried on the cluster it styles"))
  ;; a TRAILING escape with no text after it is kept as its own cluster, because
  ;; dropping it would leave attributes open on the terminal
  (let ((trailing (clusters (format nil "ab~C[0m" (%ch 27)))))
    (is (= 3 (length trailing)) "a, b, and the escape")
    (is (zerop (cluster-cols (car (last trailing)))) "the escape takes no columns")
    (is (plusp (length (cluster-esc (car (last trailing)))))
        "and its bytes are carried, which is what closes the attribute")))

(def-test truncation-never-cuts-a-cluster-in-half (:suite leticl)
  "Half a ZWJ sequence is a different glyph and half a flag is a letter.

**And the elision is disclosed.** `width::truncate` (width.rs:329-353) spends the
last column on an `…`, which ours did not — so a path cut at 20 columns and one
that happened to BE 20 columns read as the same string. The reference's own case
(`truncation_does_not_cut_a_cluster_in_half`, width.rs:701) is the last two
assertions: two columns comes back as one cluster plus the mark."
  (let ((family (format nil "~C~C~C~C~C" (%ch #x1f468) (%ch #x200d)
                        (%ch #x1f469) (%ch #x200d) (%ch #x1f467))))
    (is (string= family (truncate-to-width family 2))
        "a two-column cluster survives a two-column budget whole — nothing was cut, so nothing is said")
    (is (string= "…" (truncate-to-width family 1))
        "and is dropped rather than halved when it does not fit, with the mark in its place")
    (is (= 1 (string-width (truncate-to-width (concatenate 'string family family) 2)))
        "two of them in a two-column budget: one column of content will not hold one, so the mark is all there is")
    (is (string= "" (truncate-to-width family 0)) "and no column is no mark either"))
  (let* ((acute (%ch #x301))
         (s (format nil "a~Cb~Cc~C" acute acute acute))
         (cut (truncate-to-width s 2)))
    (is (= 2 (string-width cut)) "two columns: one cluster plus the ellipsis")
    (is (eql 0 (search (format nil "a~C" acute) cut))
        "and the cluster it kept is whole"))
  (let ((cut (truncate-to-width "…/Projects/leticl/src/cards.lisp" 12)))
    (is (<= (string-width cut) 12) "never over the budget the caller gave")
    (is (char= #\… (char cut (1- (length cut)))) "and it ends in the mark")))

(def-test fit-reaches-exactly-the-columns-asked-for (:suite leticl)
  (is (string= "ab   " (fit-to-width "ab" 5)) "padded")
  ;; `fit` truncates through `truncate` (width.rs:356-364), so the disclosure
  ;; comes with it: ours returned `abc`, which is a lie about a six-letter word.
  (is (string= "ab…" (fit-to-width "abcdef" 3)) "truncated, and said so")
  (is (= 5 (string-width (fit-to-width "中文" 5)))
      "and measured in columns, not characters"))

(def-test measurement-and-placement-count-the-same-thing (:suite leticl)
  "The property that matters, and the reason both halves had to change together:
`string-width` decides where a border goes and `screen-put-string` decides where
the text goes. If they count different things, fixing one just moves the defect —
the border lands inside the text instead of the text overflowing the border."
  (let ((s (make-screen 40 1)))
    (dolist (case (list (cons "ascii" "hello")
                        (cons "cjk" (format nil "~C~C" (%ch #x4e2d) (%ch #x6587)))
                        (cons "family" (format nil "~C~C~C~C~C" (%ch #x1f468) (%ch #x200d)
                                               (%ch #x1f469) (%ch #x200d) (%ch #x1f467)))
                        (cons "flag" (format nil "~C~C" (%ch #x1f1ec) (%ch #x1f1e7)))
                        (cons "combining" (format nil "e~C" (%ch #x301)))
                        (cons "escaped" (format nil "~C[1mx~C[0m" (%ch 27) (%ch 27)))))
      (let* ((label (car case))
             (text (cdr case))
             (end (screen-put-string s 0 0 text))
             (measured (string-width text)))
        (is (= measured end)
            (format nil "~a: the columns MEASURED (~a) are the columns PLACED (~a)"
                    label measured end))))))

;;; ------------------------------------------------- the two-panel diff (P5) ;;;

(defun %split-text (lines)
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))

(def-test the-two-panel-view-puts-before-on-the-left (:suite leticl)
  "The shape the operator asked for twice: the same evidence the unified card
carries, drawn side by side, with the SIGN COLUMN carrying the change rather than
a background tint — a glyph survives a terminal with no colour and a pipe to a
file, which a tint does not."
  (let* ((old (list "a" "b" "c"))
         (new (list "a" "B" "c"))
         (text (%split-text (render-split old new :width 60 :old-start 10 :new-start 10))))
    ;; every ROW is the same width, separator in the same column: that is what
    ;; "the panels line up" means, and a wide glyph in one is what breaks it
    (dolist (row (render-split old new :width 60 :old-start 10 :new-start 10))
      (is (= 60 (string-width
                 (format nil "~{~a~}" (mapcar #'car row))))
          "each row is exactly the width the caller asked for"))
    (is (search "10   a" text) "the left gutter numbers from the FILE, not the excerpt")
    (is (search "11 - b" text) "the removed line is signed MINUS on the left")
    (is (search "11 + B" text) "and the added line PLUS on the right")
    (is (search "│" text) "the panels are separated")
    ;; and the two SIDES differ where the change is: a bug that filled one table
    ;; from both sides drew the after-text in both panels, which looks like a
    ;; correctly aligned row and is exactly what it must not be
    (let* ((row (second (render-split old new :width 60 :old-start 10 :new-start 10)))
           (sep (position leticl::+split-sep+ row :key #'car :test #'string=))
           (left (format nil "~{~a~}" (mapcar #'car (subseq row 0 sep))))
           (right (format nil "~{~a~}" (mapcar #'car (subseq row (1+ sep))))))
      (is (search "-" left) "the left half carries the removal")
      (is (search "+" right) "the right half carries the addition")
      (is (not (string= left right)) "and the two are not the same text"))))

(def-test a-rewritten-line-sits-beside-the-line-it-replaced (:suite leticl)
  "A change run pairs the k-th removal with the k-th addition, which is what puts a
rewritten line BESIDE the line it replaced rather than above it. Two panels that
put them on different rows are two panels nobody can read across."
  (let* ((old (list "one" "two" "three"))
         (new (list "ONE" "TWO" "THREE"))
         (lines (render-split old new :width 60 :old-start 1 :new-start 1)))
    (is (= 3 (length lines)) "three paired rows, not six stacked ones")
    (let ((first-row (%split-text (list (first lines)))))
      (is (search "one" first-row) "the first removal")
      (is (search "ONE" first-row) "is on the SAME row as its replacement"))))

(def-test a-deletion-and-an-insertion-leave-the-other-panel-blank (:suite leticl)
  "Unequal sides: a deletion has nothing on the right and an insertion nothing on
the left, and saying so is the whole of what the row is for. The blank half keeps
its width, or the separator would move and the panels would stop lining up."
  ;; a pure insertion
  (let* ((lines (render-split (list "a" "c") (list "a" "b" "c")
                              :width 60 :old-start 1 :new-start 1))
         (text (%split-text lines)))
    (is (search "+ b" text) "the inserted line is signed")
    ;; one separator PER ROW, and the blank half keeps its width — that is what
    ;; keeps the two panels lined up rather than ragged
    (dolist (row lines)
      (let ((rowtext (format nil "~{~a~}" (mapcar #'car row))))
        (is (= 1 (count-if (lambda (c) (char= c #\│)) rowtext))
            "one separator per row")
        (is (= 60 (string-width rowtext)) "and the row keeps its full width"))))
  ;; a pure deletion
  (let ((text (%split-text (render-split (list "a" "b" "c") (list "a" "c")
                                         :width 60 :old-start 1 :new-start 1))))
    (is (search "- b" text) "the deleted line is signed")))

(def-test a-narrow-pane-degrades-rather-than-refusing (:suite leticl)
  "MEASURED: at any width the split view DRAWS the diff.

`+split-min-body+` is a FLOOR (`sidediff.rs:168,471-477`, `Geometry::of`), and
this file read it as a GATE: below it `render-split` answered one yellow row —
`{n}-column pane is too narrow for two panels; /diff unified` — and no diff at
all. That contradicted this file's own header, which promises \"a narrow pane
gets a narrow split rather than no diff, because an edit drawn cramped is still
an edit they can read, and an edit not drawn is one they approved blind\", and it
is how an operator ends up approving an edit they never saw.

The measurement is the refusal's own width: 20 columns, where the panel body
`(20-3)/2 - (numw+3)` is 3 and the floor lifts it to 8."
  (let* ((lines (render-split (list "a" "b") (list "a" "B")
                              :width 20 :old-start 1 :new-start 1))
         (text (%split-text lines)))
    (is (not (search "too narrow" text)) "it does not refuse")
    (is (not (search "/diff unified" text)) "and does not send the reader away")
    (is (= 2 (length lines)) "one context row and the changed pair")
    (is (search "- b" text) "the removal is drawn")
    (is (search "+ B" text) "and so is the addition"))
  ;; the floor itself, at the point the old gate fired
  (is (= 8 (leticl::%panel-body-width 8 1 t))
      "a body of 3 columns is LIFTED to the floor, not refused")
  (is (= 22 (leticl::%panel-body-width 24 0 nil))
      "and a panel with room keeps it — sign and space only, line numbers off"))

(def-test the-split-cell-spends-a-space-either-side-of-the-sign (:suite leticl)
  "MEASURED: `number space sign space code`, the reference's `numw + 3`.

`Geometry::of` (`sidediff.rs:167`) gives a cell `numw + 3` columns of gutter
before its code — the number, a space, the sign, a space — and `side_lines`
(`:363`) emits `{gutter}{sign} {body}`. This file spent `numw + 1`: no space
either side of the sign, so the code started two columns earlier than the
reference's on BOTH panels and `+B` read as one token rather than a sign and a
line. Asserted as the exact segments, text and style together, because that is
the only assertion that catches a fix which moves the text and forgets the tint."
  (let ((rows (render-split (list "a" "b" "c") (list "a" "B" "c")
                            :width 60 :old-start 10 :new-start 10)))
    (is (equal (second rows)
               (list (cons "11 " '(:fg :red :bg 52))
                     (cons "-"   '(:fg :red :bg 52))
                     (cons " "   '(:bg 52))
                     (cons "b"   '(:bg 52))
                     (cons "                      " '(:bg 52))
                     (cons " │ " '(:dim t))
                     (cons "11 " '(:fg :green :bg 22))
                     (cons "+"   '(:fg :green :bg 22))
                     (cons " "   '(:bg 22))
                     (cons "B"   '(:bg 22))
                     (cons "                       " '(:bg 22))))
        "the changed pair, column for column")
    (is (equal (first rows)
               (list (cons "10 " '(:dim t))
                     (cons " " nil)
                     (cons " " nil)
                     (cons "a" nil)
                     (cons "                      " nil)
                     (cons " │ " '(:dim t))
                     (cons "10 " '(:dim t))
                     (cons " " nil)
                     (cons " " nil)
                     (cons "a" nil)
                     (cons "                       " nil)))
        "a context row spends the same columns, dim and untinted")))

(def-test a-changed-split-row-is-tinted-to-the-panel-edge (:suite leticl)
  "MEASURED: a changed half carries its role's background to the panel's edge.

`side_lines` (`sidediff.rs:310-372`) paints the whole cell inside the line's own
role — gutter, sign, code and the padding — with the sign keeping the green or
red FOREGROUND and the number taking the row's foreground on a changed row. Both
halves here were one flat `(:fg :bright-white)` segment: no `48;5;22`/`48;5;52`,
no coloured sign, no coloured number. The padding is the half of this that is
easy to miss — a tint that stops where the text stops is a ragged block, not a
row — so the assertion is on the PAD segment's style."
  (let* ((rows (render-split (list "b") (list "B") :width 40))
         (row (first rows)))
    (is (equal row
               (list (cons "1 " '(:fg :red :bg 52))
                     (cons "-"  '(:fg :red :bg 52))
                     (cons " "  '(:bg 52))
                     (cons "b"  '(:bg 52))
                     (cons "             " '(:bg 52))      ; 13, to the panel edge
                     (cons " │ " '(:dim t))
                     (cons "1 " '(:fg :green :bg 22))
                     (cons "+"  '(:fg :green :bg 22))
                     (cons " "  '(:bg 22))
                     (cons "B"  '(:bg 22))
                     (cons "              " '(:bg 22))))   ; 14, the odd column
        "both pads run to their panel's edge, each inside its own tint")
    (is (equal '(:fg :red :bg 52) (cdr (second row)))
        "the sign keeps its own foreground inside the tint")
    (is (equal '(:fg :red :bg 52) (cdr (first row)))
        "and the line number takes the row's foreground, not dim")
    (is (null (find-if (lambda (s) (equal (cdr s) '(:fg :bright-white))) row))
        "nothing is flat bright-white any more")))

(def-test a-long-split-line-wraps-instead-of-being-truncated (:suite leticl)
  "MEASURED: a half longer than its panel wraps; the other side goes blank.

`side_lines`/`render_pair` (`sidediff.rs:270-287,308-326`) wrap each side inside
its own column and emit `max(left_rows, right_rows)` rows, blanking whichever
side ran out. This file called `fit-to-width` and a pair was always exactly one
row, so the changed TAIL of any line longer than half the pane was silently
dropped — which `diff.rs:336-341` names as \"the one thing a diff must not do\"."
  (let ((rows (render-split (list "x") (list "aaaa bbbb cccc dddd eeee")
                            :width 40)))
    (is (= 2 (length rows)) "the pair is two terminal rows, not one")
    (is (search "dddd eeee" (%split-text (list (second rows))))
        "the tail is on the screen rather than cut off")
    (is (equal (first (second rows))
               (cons "                  " nil))
        "the left panel is blank on the continuation, not a repeat of its line")
    (dolist (row rows)
      (is (= 40 (string-width (format nil "~{~a~}" (mapcar #'car row))))
          "and every row is still exactly the width asked for"))))

(def-test the-split-view-draws-its-hunk-headers-and-its-two-banners (:suite leticl)
  "MEASURED: `no change`, the degraded banner and `@@ -o,co +n,cn @@`.

`render_split` (`sidediff.rs:93-119,173-194`) emits all three; this file emitted
none of them. Two hunks ran together with nothing between them, so the second
read as a continuation of the first; two identical files returned NIL rather than
saying so; and a diff that gave up on the minimal edit script said nothing at all
in the split view while the unified view next to it announced it."
  (is (equal (render-split (list "a") (list "a") :width 40)
             (list (list (cons "no change" '(:dim t)))))
      "identical sides say so, in the unified renderer's own words")
  (let* ((old (loop for i from 1 to 30 collect (format nil "l~a" i)))
         (new (loop for i from 1 to 30
                    collect (if (member i '(3 25)) (format nil "L~a" i)
                                (format nil "l~a" i))))
         (rows (render-split old new :width 44 :context 1)))
    (is (equal (first rows) (list (cons "@@ -2,3 +2,3 @@" '(:dim t))))
        "the first hunk is headed, because there is more than one")
    (is (equal (fifth rows) (list (cons "@@ -24,3 +24,3 @@" '(:dim t))))
        "and so is the second, numbered from the FILE"))
  (let* ((old (loop for i from 0 below 3000 collect (format nil "aaa ~a" i)))
         (new (loop for i from 0 below 3000 collect (format nil "bbb ~a" (* i 7))))
         (rows (render-split old new :width 80 :max-rows 4)))
    (is (search "gave up" (%split-text (list (first rows))))
        "a degraded diff announces itself in the split view too")
    (is (search "more diff lines not shown" (%split-text (last rows)))
        "and the overflow is disclosed in the reference's words — LINES, because
the budget is now counted in terminal rows and a wrapped pair charges more than
one of them")))

(def-test a-trailing-newline-does-not-add-a-phantom-split-row (:suite leticl)
  "MEASURED: `str::lines()` drops one final empty line; `uiop:split-string` keeps it.

`sidediff.rs:451-452` splits the excerpt with `str::lines()`, which yields no
final empty line for a text ending in a newline. `%lines-of` used
`uiop:split-string` straight, so every side ending in `\\n` — which is every side
of every real file edit — gained a blank row at the foot of the diff, signed and
numbered, claiming a line that is not in the file."
  (is (equal '("a" "b") (leticl::%lines-of (format nil "a~%b~%")))
      "one trailing newline is a terminator, not a line")
  (is (equal '("a" "") (leticl::%lines-of (format nil "a~%~%")))
      "but a blank line that is really there survives")
  (is (equal '("a") (leticl::%lines-of "a")) "and a text with no newline is one line")
  (is (null (leticl::%lines-of "")) "an empty side is no lines at all")
  (let ((edit (list :path "f.txt" :created nil :before-start 1 :after-start 1
                    :before (format nil "a~%") :after (format nil "b~%"))))
    (is (= 1 (length (edit-split-lines edit 60)))
        "one changed line is ONE row, not a row and a phantom")))

(def-test the-split-panels-are-syntax-coloured (:suite leticl)
  "MEASURED: `edit-split-lines` dropped `(getf edit :path)` on the floor.

`render_edit` (`sidediff.rs:443-460`) passes `lang_for(path)` into the render and
`class_grid` colours BOTH panels (`:106-107,389-433`). Here the shim,
`class-rows` and `role-style` all existed and only the path in was missing, so
the split panels were flat while the markdown fences beside them were coloured.

Without the shim this asserts the contract instead: a path nobody has a grammar
for renders plain, which is what a terminal with no palette reads anyway."
  (if (hl-available-p)
      (let* ((edit (list :path "f.rs" :created nil :before-start 1 :after-start 1
                         :before "let x = 1;" :after "let y = 42;"))
             (row (first (edit-split-lines edit 64))))
        (is (find (cons "let" '(:fg :magenta :bg 52)) row :test #'equal)
            "the keyword is a keyword on the removed side, over its tint")
        (is (find (cons "42" '(:fg :yellow :bg 22)) row :test #'equal)
            "and the number a number on the added side, over its own")
        (is (null (class-rows (list "let x = 1;") 0))
            "language 0 is no colour, not a guess"))
      (let ((row (first (edit-split-lines
                         (list :path "f.rs" :before-start 1 :after-start 1
                               :before "let x = 1;" :after "let y = 42;")
                         64))))
        (is (null (class-rows (list "let x = 1;") (lang-for "f.rs")))
            "no shim, no grid")
        (is (search "let x = 1;" (format nil "~{~a~}" (mapcar #'car row)))
            "the code is still drawn — the contract of this file")
        (is (null (intersection '(:magenta :yellow :cyan)
                                (mapcar (lambda (seg) (getf (cdr seg) :fg)) row)))
            "and carries no syntax colour: no shim is a dimmer screen, not a crash"))))

(def-test the-card-chooses-the-view-from-the-pref (:suite leticl)
  "The choice is the operator's toggle and nothing else — not the width, which is
opencode's rule and would take the diff away on a narrow terminal."
  (let ((edit (list :path "f.lisp" :created nil :before-start 1 :after-start 1
                    :before-lines 3 :after-lines 3 :truncated nil
                    :before (format nil "a~%b~%c") :after (format nil "a~%B~%c"))))
    (is (search "│" (segs-of (edit-lines edit 60 :split t)))
        "split is the two-panel view")
    (is (not (search "│" (segs-of (edit-lines edit 60 :split nil))))
        "and unified is the one-panel view")))

(def-test a-folded-card-says-how-much-it-is-hiding (:suite leticl)
  "Folded by default, like letibot: the header carries the count and names the
chord, and the output is one press away. A card that prints two hundred lines
where the reference prints one row is a transcript nobody can scan."
  (let* ((*item-facts* nil)
         (body (list :type "tool_result" :call-id "c" :name "bash"
                     :outcome (list :outcome "ok")
                     :payload (format nil "~{~a~^~%~}"
                                      (loop for i from 1 to 30 collect (format nil "line ~a" i)))))
         (item (list :item-id "fold1" :kind "tool_result" :item body)))
    (let ((folded (segs-of (item-lines item 80 (list :show-tools nil)))))
      (is (search "30 line" folded) "the count says how much there is")
      (is (search "… +29 lines" folded) "and the fold names how many are hidden")
      (is (search "ctrl-t" folded) "and the chord that shows them")
      ;; the reference's three rows: the header, the FIRST LINE (which is where a
      ;; tool puts what it did), and the seam with the chord on it. Ours had put
      ;; the seam on the header and dropped the line, so a folded row said how
      ;; much there was and nothing of what.
      (is (search "line 1" folded) "and the first line, so the fold says WHAT as well as how much")
      (is (= 3 (length (item-lines item 80 (list :show-tools nil))))
          "three rows while folded: header, first line, seam"))
    (let ((open (segs-of (item-lines item 80 (list :show-tools t)))))
      (is (search "line 1" open) "open, the output is there"))))

(def-test the-fold-key-is-the-one-the-head-sets (:suite leticl)
  "`:tools-open` was read in four places and SET NOWHERE — the head's plist key is
`:show-tools`, so card bodies never rendered at all and ctrl-t flipped a key nothing
read. A test that presses the chord and looks for the output is what catches that
class; this one asserts the key itself."
  (let ((h (%make-head)))
    ;; BOUND, not true: folded is the new default, and the point is that the key
    ;; the card READS is the key the head SETS.
    (is (member :show-tools (head-prefs h) :test #'eq)
        "the head binds :show-tools, which is what the card must read"))
  (is (search ":SHOW-TOOLS" (string-upcase (source-of "cards")))
      "and the card reads that key, not a second spelling of it"))

(defun first-line-indent (item &optional (prefs (list :show-tools t)))
  "How far the item's first line is indented, and its text."
  (let ((lines (item-lines item 200 prefs)))
    (when lines
      (let ((text (format nil "~{~a~}" (mapcar #'car (first lines)))))
        (values (- (length text) (length (string-left-trim " " text)))
                text)))))

(def-test the-working-is-stepped-in-under-the-answer (:suite leticl)
  "Measured against letibot's screen: its CARDS sit at column 4 and its PROSE at
column 2, while every row of ours was at 2. `activity-indent` existed and was used
only to compute a subject's WIDTH, never to move a row — the same dead-code class
as `:tools-open`.

The step is what makes a turn readable as a turn: the answer sits at the body's own
column because it is the conversation, and the working — reasoning, tool calls —
is subordinate to it. It costs no colour, so it survives a terminal-native
palette."
  (let* ((tool (list :item-id "i1" :kind "tool_result" :ts 0
                     :item (list :type "tool_result" :call-id "c" :name "bash"
                                 :outcome (list :outcome "ok") :payload "x")))
         (think (list :item-id "i2" :kind "reasoning" :ts 0
                      :item (list :type "reasoning" :text "hmm")))
         (user (list :item-id "i3" :kind "user" :ts 1789905489676
                     :item (list :type "user" :text "hello")))
         (answer (list :item-id "i4" :kind "assistant" :ts 0
                       :item (list :type "assistant" :text "an answer"))))
    (multiple-value-bind (tool-ind) (first-line-indent tool)
      (multiple-value-bind (think-ind) (first-line-indent
                                        think (list :show-reasoning t))
        (multiple-value-bind (user-ind) (first-line-indent user)
          (multiple-value-bind (answer-ind) (first-line-indent answer)
            (is (= 2 tool-ind) "a tool card is stepped in")
            (is (= 2 think-ind) "and so is a reasoning row")
            (is (zerop user-ind)
                "the operator's message is NOT — it is the conversation")
            (is (zerop answer-ind)
                "nor is the model's ANSWER, which is the other half of it")))))))

(def-test the-step-is-two-columns-and-given-up-when-narrow (:suite leticl)
  "Two columns, matching the reasoning rail's width and the frame's gutter, so the
page reads as one repeated step. Given up below 60 columns, where two columns of
every line is a bigger fraction than the hierarchy is worth."
  (is (= 2 (activity-indent 100)) "two columns on a wide frame")
  (is (= 0 (activity-indent 40)) "and none on a narrow one")
  (let ((item (list :item-id "i" :kind "tool_result" :ts 0
                    :item (list :type "tool_result" :call-id "c" :name "bash"
                                :outcome (list :outcome "ok") :payload "x"))))
    (multiple-value-bind (wide) (first-line-indent item)
      (is (= 2 wide) "a wide pane steps the card in"))
    (let ((lines (item-lines item 40 (list :show-tools t))))
      (let ((text (format nil "~{~a~}" (mapcar #'car (first lines)))))
        (is (zerop (- (length text) (length (string-left-trim " " text))))
            "a narrow one leaves it at the column")))))

(def-test an-empty-row-is-not-indented (:suite leticl)
  "Trailing spaces on a blank line are invisible until something copies them."
  (let ((stepped (step-in-lines (list nil (list (cons "x" nil))) 2)))
    (is (null (first stepped)) "the blank row stays blank")
    (is (equal "  " (car (first (second stepped)))) "and the text row moves")))

;;; ------------------------------------ what the two screens said (2026-09-20) ;;;
;;;
;;; Each test here is one row where letibot's screen and ours differed, captured
;;; with `tmux capture-pane -e` on the same session at the same size and compared
;;; byte for byte. The reference is crates/tui/src/render.rs and app.rs at
;;; e9ee3c4; the shapes below are read off its raw escapes, not its plain text.

(def-test a-paragraph-wraps-to-the-width-it-is-given (:suite leticl)
  "Measured: every long paragraph on our screen was exactly 210 columns wide with
no continuation row — CUT at the terminal's edge — where letibot's wrapped to two.
`markdown-lines` was called with no width at all, and `%place-lines` clips."
  (let* ((text (format nil "~{~a~^ ~}" (loop repeat 40 collect "word")))
         (lines (markdown-lines text :width 50)))
    (is (> (length lines) 1) "a 200-column paragraph is more than one row at 50")
    (is (every (lambda (l) (<= (leticl::%segs-width l) 50)) lines)
        "and no row is wider than the width")
    (is (equal text (format nil "~{~a~^ ~}" (mapcar #'segs-of (mapcar #'list lines))))
        "and nothing was lost"))
  ;; the source's own line breaks are a wrap the model did not mean
  (let ((lines (markdown-lines (format nil "one~%two") :width 80)))
    (is (= 1 (length lines)) "two source lines are one paragraph")
    (is (equal "one two" (segs-of lines)) "joined with a space")))

(def-test a-heading-keeps-its-hashes-and-its-level-colour (:suite leticl)
  "letibot: `ESC[2m##ESC[0m ESC[1;34mWhat I measured`. Ours drew the text bold
and nothing else — no hashes, no colour, and so no level once the terminal is
monochrome."
  (let ((h1 (first (markdown-lines "# One" :width 80)))
        (h2 (first (markdown-lines "## Two" :width 80)))
        (h3 (first (markdown-lines "### Three" :width 80))))
    (is (equal (cons "#" '(:dim t)) (first h1)) "the hashes stay, faint")
    (is (equal '(:bold t :fg :cyan) (cdr (third h1))) "level one is Role::Heading")
    (is (equal (cons "##" '(:dim t)) (first h2)))
    (is (equal '(:bold t :fg :blue) (cdr (third h2))) "level two is Role::Subheading")
    (is (equal '(:bold t) (cdr (third h3))) "and deeper is Strong")))

(def-test inline-markup-nests (:suite leticl)
  "letibot: `ESC[36mactivity-indentESC[1mESC[39m was defined…` — a code span
inside a bold run. Ours rendered the whole `**…**` as one bold segment with the
backticks still in it."
  (let ((segs (inline-spans "**`code` was defined** and *it* `x`")))
    (is (equal (cons "code" '(:fg :cyan)) (first segs))
        "the code span inside the bold is cyan, and not bold: `nest` says the container entered decides")
    (is (equal (cons " was defined" '(:bold t)) (second segs)) "the rest of the run is bold")
    (is (member (cons "it" '(:italic t)) segs :test #'equal) "italic")
    (is (equal (cons "x" '(:fg :cyan)) (car (last segs))) "a plain code span")
    (is (not (find #\* (segs-of (list segs)))) "and no marker survives"))
  (is (equal (list (cons "snake_case is fine" nil)) (inline-spans "snake_case is fine"))
      "an underscore inside a word is not emphasis")
  (is (equal (list (cons "a " nil) (cons "link" nil)) (inline-spans "a [link](http://x)"))
      "a link is its text")
  (is (equal (list (cons "┃ " '(:fg :cyan))) (inline-spans "`┃ `"))
      "a code span keeps a single trailing space, by the GFM rule — measured, the reference paints it inside the cyan")
  (is (equal (list (cons "a" '(:fg :cyan))) (inline-spans "` a `"))
      "and one space comes off each end when both are there"))

(def-test a-table-cell-is-runs-and-the-columns-are-measured-painted (:suite leticl)
  "letibot: `ESC[0;1m1.6–2.7 sESC[0m of lexing`. Ours printed `**1.6–2.7 s**` with
the asterisks, and measured the column on them."
  (let* ((lines (markdown-lines (format nil "| a | b |~%|---|---|~%| **x** | y |") :width 80))
         (text (segs-of lines)))
    (is (not (find #\* text)) "no marker in a cell")
    (is (member (cons "x" '(:bold t)) (third lines) :test #'equal) "the cell's run is bold")
    (is (equal (cons "a" '(:bold t)) (first (first lines))) "the header is Strong")
    (is (search "─┼─" text) "one faint rule under the header")
    (is (not (search "|" text)) "and no pipe from the source")
    ;; the last column is not padded: trailing whitespace is trailing whitespace
    ;; in a copy-paste
    (is (every (lambda (l) (let ((s (segs-of (list l))))
                             (string= s (string-right-trim " " s))))
               lines)
        "no row ends in spaces"))
  ;; a wide column gives way first, and a cell wraps rather than being cut
  (let* ((long (format nil "~{~a~^ ~}" (loop repeat 20 collect "wide")))
         (lines (markdown-lines (format nil "| n | text |~%|---|---|~%| 1 | ~a |" long) :width 40)))
    (is (every (lambda (l) (<= (leticl::%segs-width l) 40)) lines) "nothing exceeds the width")
    (is (> (length lines) 3) "the wide cell wrapped to more than one row")
    (is (search "wide" (segs-of (last lines))) "and its tail is still there")))

(def-test list-markers-are-the-references (:suite leticl)
  "`·` faint for a bullet — it marks the indent and is not read — and the number
the model WROTE for an ordered item, plain. Ours drew `•` bright-cyan and the
number in the same colour. Continuation lines sit under the text."
  (let ((lines (markdown-lines (format nil "- one~%- two") :width 80)))
    (is (equal (cons "· " '(:dim t)) (first (first lines))) "the faint middle dot")
    (is (= 2 (length lines)) "two items, no blank between"))
  (let ((lines (markdown-lines "4. four" :width 80)))
    (is (equal (cons "4. " nil) (first (first lines))) "the written number, plain"))
  (let ((lines (markdown-lines (format nil "- ~{~a~^ ~}" (loop repeat 30 collect "w")) :width 20)))
    (is (> (length lines) 1) "a long item wraps")
    (is (equal "  " (car (first (second lines)))) "and its continuation is indented by the marker's columns")))

(def-test blocks-are-separated-and-bounded (:suite leticl)
  "One blank row between blocks whether or not the source had one, none at the
end; and a block over the budget is a title, a count and its tail."
  (let ((lines (markdown-lines (format nil "para~%# head~%- item") :width 80)))
    (is (= 5 (length lines)) "three blocks, two separators")
    (is (null (second lines)))
    (is (null (fourth lines))))
  (let* ((text (format nil "~{~a~^~%~}" (loop for i from 1 to 30 collect (format nil "- item ~d" i))))
         (lines (markdown-lines text :width 80 :limit 10)))
    (is (= 10 (length lines)) "bounded to the limit")
    (is (search "▸ item 1" (car (first (first lines)))) "the title")
    (is (search "… 22 lines elided …" (segs-of (list (second lines)))) "the count")
    (is (search "item 30" (segs-of (last lines))) "and the tail")))

(def-test the-header-has-three-registers-and-a-position (:suite leticl)
  "letibot's row 1, raw: `ESC[34m▌ ESC[1mhello…ESC[0;2m  ~/Projects/leticlESC[0m`
then `ESC[2m1/71 · model · …`. Ours painted the whole left half bold and had no
position; and it was three columns short of the box's edge, with a trailing space."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-title s) "hello"
          (session-session-id s) "s-1"
          (session-sessions s) (list (list :session-id "s-0" :title "other")
                                     (list :session-id "s-1" :title "hello")
                                     (list :session-id "s-1-sub" :title "child"
                                           :parent-session-id "s-1")))
    (let* ((line (top-border h 100))
           (text (segs-of (list line))))
      (is (equal (cons "▌ " '(:fg :blue)) (first line)) "the bar is UserAccent, blue")
      (is (equal (cons "hello" '(:bold t)) (second line)) "the title Strong")
      (is (search "2/2" text) "the position among the daemon's sessions, subagents not counted")
      (is (= 100 (leticl::%segs-width line)) "and the row is exactly as wide as the body")
      (is (equal '(:dim t) (cdr (car (last line)))) "the tail faint")
      (is (string= text (string-right-trim " " text)) "with nothing trailing"))))

;;; ------------------------------- the payload's own window (T1) --------- ;;;
;;;
;;; **The rest of a long result, reachable.** The fold raises the BUDGET and gives no
;;; row an OFFSET, so `… +N lines · ctrl-t` named a chord that revealed nothing above
;;; forty lines — and that is the reference's own recorded bug at the site this is
;;; ported from (*"opening the fold changed the budget, not the offset. There was no
;;; offset."*). Measured against its screen for `tests/fixtures/payload-window.jsonl`:
;;;
;;;     ▸ Ran "echo \"size 60\"" · ok · 60 lines
;;;       payload line 1 of 60
;;;       … +59 lines · ctrl-t pages

(defun %payload-text (n)
  "N numbered lines, so \"which part is on screen\" is a decidable question."
  (format nil "~{~a~^~%~}"
          (loop for i from 1 to n collect (format nil "line ~a of ~d" i n))))

(defun %payload-head (&rest sizes)
  "A head whose transcript is one settled `bash` result per SIZE, OLDEST FIRST.

The item ids are `t1`, `t2` … in that order, so the LAST is the newest and the one a
window is seeded on.

**The call ids are cleared before use, and that is a GLOBAL showing through.** These
rows carry no assistant row and no `arguments`, so their subject is the call-id
fallback — `(c1)` — which is what every assertion below was written against. But
`*call-targets*` is a `defvar`, so a target some OTHER test left under `c1` would be
picked up here and the fixture would stop being the fixture: measured 2026-09-22, when
the R25 tests wrote a 300-character subject under `c1` and two seam assertions in this
file failed with a `…` on the header. A fixture that depends on what ran before it is
the same defect as a global that survives between tests."
  (let ((h (%make-head)))
    (loop for i from 1 to (length sizes)
          do (setf (alexandria:assoc-value *call-targets* (format nil "c~d" i)
                                          :test #'string=)
                   nil))
    (setf (session-items (head-session h))
          (coerce
           (loop for n in sizes
                 for i from 1
                 collect (list :item-id (format nil "t~d" i) :kind "tool_result" :ts 0
                               :item (list :type "tool_result"
                                           :call-id (format nil "c~d" i)
                                           :name "bash"
                                           :outcome (list :outcome "ok")
                                           :payload (%payload-text n))))
           'vector))
    h))

(defun %payload-row (h &optional (index 0) (cols 80))
  "The lines row INDEX of H draws, under H's own prefs and window."
  (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l)))
          (item-lines (aref (session-items (head-session h)) index)
                      cols (head-prefs h))))

(def-test a-long-payload-is-unreachable-until-a-window-is-opened (:suite leticl)
  "The criterion, end to end: what the reader presses, what each seam says, and how
they know they are at the end.

Folded, a sixty-line result is its header, its first line, and a seam naming the key
that pages it. `ctrl-t` opens the fold AND a window on it, so the seam changes to the
key that moves INSIDE the window — and the row that used to say `… +59 lines · ctrl-t`
with nothing behind the chord can now be read to its last line."
  (let ((*item-facts* nil) (*payload-view* nil) (*hist-generation* 0)
        (leticl::*write-prefs* nil)
        (h (%payload-head 60)))
    (setf (getf (head-prefs h) :show-tools) nil)
    ;; --- folded: one line, and the seam names the chord that opens the view
    (let ((rows (%payload-row h)))
      (is (= 3 (length rows)) "header, first line, seam")
      (is (search "line 1 of 60" (second rows)) "the first line")
      (is (string= "    … +59 lines · ctrl-t pages" (third rows))
          "and the seam names the chord AND what it does"))
    ;; --- ctrl-t: the fold opens and the window is seeded on the newest payload
    (%press h (list :type :ctrl :ch #\t))
    (is (eq t (head-pref h :show-tools)) "the fold is open")
    (is (equal (cons "t1" 0) leticl::*payload-view*)
        "and a window is open on the row, at its first line")
    (let ((rows (%payload-row h)))
      (is (= 41 (length rows)) "header, 39 body rows, seam")
      (is (search "line 1 of 60" (second rows)) "it starts at the head")
      (is (search "line 39 of 60" (nth 39 rows)) "and runs to the fortieth row of the frame")
      (is (string= "    … +21 lines · ↓ pages down · esc closes" (car (last rows)))
          "the seam says which key moves INSIDE the window, and that esc leaves it")
      (is (notany (lambda (l) (search "ctrl-t" l)) rows)
          "and it never names the fold's chord: the fold is already open"))
    ;; --- paging: the seam above names where the reader IS
    (%press h (list :type :down))
    (let ((rows (%payload-row h)))
      (is (string= "    ↑ 10 more lines above · ↑ scrolls up" (second rows))
          "the seam above says how many lines are above and which key goes back")
      (is (search "line 11 of 60" (third rows)) "and the window moved ten lines")
      (is (string= "    … +12 lines · ↓ pages down · esc closes" (car (last rows)))
          "while the seam below counts what is left"))
    (%press h (list :type :up))
    (is (equal (cons "t1" 0) leticl::*payload-view*) "up comes back to the head")
    (is (notany (lambda (l) (search "more lines above" l)) (%payload-row h))
        "and the seam above is gone, because nothing is")
    ;; --- **to the end, which is the whole point**
    (dotimes (i 20) (%press h (list :type :down)))
    (let ((rows (%payload-row h)))
      (is (search "line 60 of 60" (apply #'concatenate 'string rows))
          "the LAST line of the payload reaches the screen")
      (is (string= "    … end of output · esc closes" (car (last rows)))
          "and the seam says so, so 'no more' is not 'the key stopped working'")
      (is (search "↑ 59 more lines above" (second rows))
          "with the reader's position stated in lines"))
    ;; --- esc gives the arrows back and closes NOTHING else
    (%press h (list :type :esc))
    (is (null leticl::*payload-view*) "esc closes the window")
    (is (eq t (head-pref h :show-tools)) "and leaves the fold open")
    ;; the fold is still open, so the row is the fold's 39-row body with the seam that
    ;; opens the view again — not the folded one-line form
    (is (string= "    … +21 lines · ctrl-t pages" (car (last (%payload-row h))))
        "and the seam goes back to naming the chord that opens a view")))

(def-test the-payload-seam-never-names-a-key-that-does-nothing (:suite leticl)
  "The defect this mechanism exists for, asserted as a property rather than as a
string: **a seam may not name `ctrl-t` while the fold is open**, because that is the
chord that closes it again. That was the row the operator could not read past."
  (let ((*item-facts* nil) (*payload-view* nil)
        (leticl::*write-prefs* nil)
        (h (%payload-head 60)))
    (setf (getf (head-prefs h) :show-tools) nil)
    (labels ((seams ()
               (remove-if-not (lambda (l) (search "…" l)) (%payload-row h))))
      (is (every (lambda (l) (search "ctrl-t pages" l)) (seams))
          "folded, the seam names the chord that opens the view")
      (%press h (list :type :ctrl :ch #\t))
      (is (notany (lambda (l) (search "ctrl-t" l)) (seams))
          "open, it never names it again")
      (is (every (lambda (l) (or (search "pages down" l) (search "end of output" l)))
                 (seams))
          "it names the arrows and esc, which are what work"))))

(def-test a-window-opens-on-the-newest-payload-that-has-one (:suite leticl)
  "One row at a time, keyed on the ITEM id — and a payload with nothing behind it gets
no view, because a seam offering a page with nothing there is a claim.

The reference's own test for the second half (app.rs:15125-15138): *\"a one-line
result has nothing to page, so a view on it is a claim\"*."
  (let ((*item-facts* nil) (*payload-view* nil)
        (leticl::*write-prefs* nil)
        ;; oldest first: a 1-line result, then an 80-line one, then a 2-line one
        (h (%payload-head 1 80 2)))
    (setf (getf (head-prefs h) :show-tools) nil)
    (%press h (list :type :ctrl :ch #\t))
    (is (equal (cons "t2" 0) leticl::*payload-view*)
        "the window is on the long row, not on the newest row outright")
    (is (some (lambda (l) (search "↓ pages down" l)) (%payload-row h 1))
        "that row's seam names the arrows that move inside it")
    (is (notany (lambda (l) (search "pages down" l)) (%payload-row h 0))
        "and the one-line result's row is not windowed at all — it is inlined whole")
    ;; the two-line result sits UNDER the pageable threshold, so it gets no view: with
    ;; the fold open it is simply drawn, both lines, and no seam anywhere
    (is (notany (lambda (l) (search "pages down" l)) (%payload-row h 2))
        "nor is the two-line one")
    (is (= 3 (length (%payload-row h 2))) "which the open fold shows whole"))
  ;; a session whose only result is one line long opens no view at all
  (let ((*item-facts* nil) (*payload-view* nil)
        (leticl::*write-prefs* nil)
        (h (%payload-head 1)))
    (setf (getf (head-prefs h) :show-tools) nil)
    (%press h (list :type :ctrl :ch #\t))
    (is (null leticl::*payload-view*)
        "nothing to page, so no view is claimed")))

(def-test a-payload-at-the-budget-shows-all-but-one-line (:suite leticl)
  "The window's arithmetic, at the two boundaries worth pinning.

`shown` INCLUDES the seam rows, so an open fold draws `budget - 1` body rows and
reserves the last one — which means a payload of exactly forty lines shows
thirty-nine and a seam. That is the reference's arithmetic and it moved this head's:
we drew all forty and no seam, so a two-line result and a forty-line one had the same
folded shape."
  (let ((*item-facts* nil) (*payload-view* nil)
        (leticl::*write-prefs* nil)
        (h (%payload-head 40)))
    (setf (getf (head-prefs h) :show-tools) t)
    (let ((rows (%payload-row h)))
      (is (= 41 (length rows)) "header, 39 body rows, seam")
      (is (search "line 39 of 40" (nth 39 rows)) "the body stops one short")
      (is (string= "    … +1 lines · ctrl-t pages" (car (last rows)))
          "and the seam admits it")))
  (let ((*item-facts* nil) (*payload-view* nil)
        (leticl::*write-prefs* nil)
        (h (%payload-head 39)))
    (setf (getf (head-prefs h) :show-tools) t)
    (let ((rows (%payload-row h)))
      (is (= 40 (length rows)) "one line under the budget: header and 39 body rows")
      (is (notany (lambda (l) (search "…" l)) rows) "and no seam at all"))))

(def-test paging-a-payload-invalidates-the-rendered-history (:suite leticl)
  "A page offset changes what a row RENDERS TO without moving the line cache's three
terms, so a paging that did not bump the generation would be served the previous
window out of the cache and look like a key that does nothing.

That is the reference's own finding at its cache (app.rs:3864-3872: *the page moved
to 10 and the screen still showed line 0*), found by its test. Ours is the same belt
on the same braces."
  (let ((*payload-view* (cons "t1" 0))
        (*hist-generation* 7))
    (is (payload-view-page 10) "paging says it moved something")
    (is (= 10 (cdr *payload-view*)) "and the offset is ten")
    (is (= 8 *hist-generation*) "and bumps the generation, so no cached frame is reused")
    (payload-view-close)
    (is (= 9 *hist-generation*) "closing is the same writer")
    (is (not (payload-view-page 10)) "and a page with no window is nobody's")))

(def-test the-payload-window-leaves-the-scroll-keys-alone (:suite leticl)
  "**↑/↓ page the payload; the page keys and the wheel still scroll the transcript.**

The reference's payload arm lists `Key::PageUp | Key::PageDown` (app.rs:3866-3889)
and those patterns are DEAD: the screen-moving arm at :3628 is inside the same `match`
and returns before the payload `if` is reached. So its real behaviour is this one, and
it is the one worth keeping — in this head the page keys and the wheel ARE the
scroll, and a window that took them until Esc is indistinguishable from *scrolling
broke*, which the operator has reported twice.

The reference's own test states the same contract from the other side
(app.rs:14746-14775): a window holds the ARROWS, and Esc gives them back."
  (let ((*item-facts* nil) (*payload-view* nil) (*pane-scroll* 0)
        (leticl::*write-prefs* nil)
        (h (%payload-head 60)))
    (setf (getf (head-prefs h) :show-tools) t)
    (leticl::payload-view-seed (head-session h))
    (is (equal (cons "t1" 0) leticl::*payload-view*) "a window is open")
    ;; the arrows page, and do NOT move the transcript
    (let ((scroll (head-scroll h)))
      (%press h (list :type :down))
      (is (= 10 (cdr leticl::*payload-view*)) "down pages the payload")
      (is (= scroll (head-scroll h)) "and leaves the transcript where it was"))
    ;; while the page keys and the wheel still scroll it
    (let ((scroll (head-scroll h)))
      (%press h (list :type :page-up))
      (is (> (head-scroll h) scroll) "page-up still scrolls the transcript")
      (is (= 10 (cdr leticl::*payload-view*)) "and does not page the payload"))
    (let ((scroll (head-scroll h)))
      (%press h (list :type :wheel-up))
      (is (> (head-scroll h) scroll) "and so does the wheel"))
    ;; **Esc gives the arrows back**, which in this head means back to the composer:
    ;; ↑/↓ are not the transcript's scroll keys here (the page keys and the wheel
    ;; are), so what Esc restores is that ↑ no longer pages a window.
    (%press h (list :type :esc))
    (is (null leticl::*payload-view*) "esc closed the window")
    (%press h (list :type :down))
    (is (null leticl::*payload-view*) "and down is nobody's paging key again")
    (let ((scroll (head-scroll h)))
      (%press h (list :type :page-up))
      (is (> (head-scroll h) scroll) "with the page keys still the transcript's")))
  ;; and the reference's own statement of the contract, on this head: a window holds
  ;; the arrows only while it is open, and nothing else about the transcript changes
  (let ((*item-facts* nil) (*payload-view* (cons "t1" 0)) (leticl::*write-prefs* nil)
        (h (%payload-head 60)))
    (setf (getf (head-prefs h) :show-tools) t)
    (let ((before (copy-list leticl::*payload-view*)))
      (%press h (list :type :down))
      (is (not (equal before leticl::*payload-view*)) "the window moved")
      (is (= 0 (head-scroll h)) "and the transcript did not"))))

(def-test a-pane-on-top-keeps-its-arrows (:suite leticl)
  "The window lives in the transcript, so anything the reader puts ON TOP of it wins —
including the panes whose arrows the reference hands to a window that is not on the
screen (its payload arm sits before the todos, subagents and jobs arms).

One rule instead of two: what the reader opened last is what the arrows move."
  (let ((*item-facts* nil) (*payload-view* (cons "t1" 0)) (*pane-scroll* 0)
        (*repo-todo-open* nil)
        ;; `lecticl::` because `*pick-open*` is NOT exported: spelled bare it is a
        ;; fresh LEXICAL in this package, the binding silently does nothing, and
        ;; `open-pick` writes the real global — which then hijacked the next test's
        ;; Esc. Measured, and the reason every test that binds it says `leticl::`.
        (leticl::*pick-open* nil)
        (h (%payload-head 60)))
    (setf (getf (head-prefs h) :show-tools) t)
    ;; the todos pane, which the reference would let a window steal the arrows from
    (setf (head-mode h) :todos (head-picker-sel h) 0)
    (%press h (list :type :down))
    (is (= 0 (cdr leticl::*payload-view*)) "the payload did not page")
    (is (eq :todos (head-mode h)) "and the pane kept the key")
    ;; and the mode card, which runs with `:normal` and `*pick-open*` set. It needs
    ;; the daemon's own rows to have a cursor at all (`pick-choices` reads them).
    (setf (head-mode h) :normal
          (head-settings h) (list (list :key "mode" :value "read-only"
                                        :choices (list "read-only" "always-ask"
                                                       "writes allowed"))))
    (open-pick h :mode)
    (let ((sel (head-picker-sel h)))
      (%press h (list :type :down))
      (is (= 0 (cdr leticl::*payload-view*)) "the card keeps its own arrows")
      (is (/= sel (head-picker-sel h)) "as it must, or a row could not be chosen"))))

(def-test a-payload-window-does-not-take-the-asks-keys (:suite leticl)
  "An ask ARRIVES; a window is OPENED. The reference settles it the same way — its
payload arm is ahead of the ladder (app.rs:3855-3862) — because a log being read is
not something a permission request gets to interrupt.

`enter` and the digits are deliberately NOT the window's, so the ask is answered
where it always was."
  (let ((*item-facts* nil) (*payload-view* (cons "t1" 0)) (*mode-confirm* nil)
        (leticl::*pick-open* nil)
        (h (%payload-head 60))
        (*unreadable-total* 0))
    (setf (getf (head-prefs h) :show-tools) t)
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (let ((wire (%wire h)))
      (%press h (list :type :down))
      (is (= 10 (cdr leticl::*payload-view*)) "down pages the log")
      (is (null (%sent wire)) "and does not answer the ask")
      (%press h (list :type :enter))
      (let ((answer (first (%sent wire))))
        (is (equal "answer" (getf answer :frame)) "while enter still answers it")
        (is (equal "allow_once" (getf answer :option-id)) "with the marked row's option")
        (is (equal "adj-1" (getf answer :req-id)) "and the ask's own id")))))

(def-test the-tool-row-is-three-rows-folded-and-one-inlined (:suite leticl)
  "letibot, folded: the header with the count, the FIRST line dim, then `… +N
lines · ctrl-t` as its own seam row. A one-line result rides the header with no
count. Ours had the seam on the header and the line nowhere."
  (let* ((*item-facts* nil)
         (many (list :type "tool_result" :call-id "c" :name "bash"
                     :outcome (list :outcome "ok")
                     :payload (format nil "first~%second~%third")))
         (lines (item-lines (list :item-id "t1" :kind "tool_result" :item many)
                            80 (list :show-tools nil))))
    (is (= 3 (length lines)) "header, first line, seam")
    (is (search "· 3 lines" (segs-of (list (first lines)))) "the count on the header")
    (is (not (search "ctrl-t" (segs-of (list (first lines))))) "no chord on the header")
    (is (search "first" (segs-of (list (second lines)))) "the first line")
    ;; `ctrl-t PAGES` — the chord opens the view and the arrows move inside it, and
    ;; the seam says which is which. Measured against the reference's own screen for
    ;; `tests/fixtures/payload-window.jsonl`: `… +59 lines · ctrl-t pages`.
    (is (equal "    … +2 lines · ctrl-t pages" (segs-of (list (third lines))))
        "the seam, stepped in, naming the key AND what it does"))
  ;; **A two-line payload folds to ONE line and a seam**, which is the reference's
  ;; arithmetic and was not ours: the folded body is `limit - 1` and the last row is
  ;; always reserved for the seam, whether or not it turns out to be needed. Ours
  ;; drew both lines and no seam, so a 2-line result and a 40-line one had the same
  ;; folded shape. (The seam's advice is honest here: ctrl-t opens the fold, which
  ;; shows the second line.)
  (let* ((*item-facts* nil)
         (two (list :type "tool_result" :call-id "c" :name "bash"
                    :outcome (list :outcome "ok") :payload (format nil "a~%b")))
         (lines (item-lines (list :item-id "t2" :kind "tool_result" :item two)
                            80 (list :show-tools nil))))
    (is (= 3 (length lines)) "header, one line, seam")
    (is (equal "    … +1 lines · ctrl-t pages" (segs-of (list (third lines))))
        "and the second line is what the fold would show")))

(def-test a-whitespace-bearing-target-is-debug-quoted (:suite leticl)
  "letibot shows a heredoc command as `<<'MSG'\\nthe step…`, Rust's `{:?}`; ours
printed the newline and then flattened it to a space."
  (is (equal "\"a\\nb\"" (leticl::%debug-quote (format nil "a~%b"))) "newline as \\n")
  (is (equal "\"say \\\"hi\\\"\"" (leticl::%debug-quote "say \"hi\"")) "quotes escaped")
  (is (search "<<'MSG'\\nthe step" (display-target "{\"command\":\"cd x <<'MSG'\\nthe step\\nMSG\"}"))
      "and so on the row"))

(def-test a-batch-edit-names-the-file-and-not-the-edits-array (:suite leticl)
  "R15, the operator's ruling: the ellipsis is GONE for `edit` — not moved, not
reordered.

A batch edit carries an `edits` array and a `path`, and the array is written FIRST,
so `[…]` took the most valuable position on the row to point at the diff sitting
directly underneath it. The file is the label. Both orders are asserted, because
which one arrives depends on the writer: a Rust `serde_json::Map` is a BTreeMap and
iterates `edits` before `path` alphabetically, while this head's decoder keeps the
order the model wrote — so the two heads see the array in different places and must
agree about dropping it.

**And the line this draws**: the elision rule STAYS. A nested value is a
PLACEHOLDER, not a part of a label, so it is dropped when the arguments name a
subject — and kept when they name nothing, which is the tool whose label would
otherwise be empty or a bare modifier. Both halves are asserted here, and the tools
that keep it are named."
  ;; an `edit` names a file, so nothing is drawn before it
  (is (equal "/home/dead/Projects/leticl/src/commands.lisp"
             (display-target
              "{\"edits\":[{\"old_string\":\"a\",\"new_string\":\"b\"}],\"path\":\"/home/dead/Projects/leticl/src/commands.lisp\"}"))
      "the array first, as the model wrote it")
  ;; the reference's own test case, `a.rs […]` before this ruling, `a.rs` after it
  (is (equal "a.rs" (display-target "{\"path\":\"a.rs\",\"edits\":[{\"old\":\"x\"}]}"))
      "and with the array after the path, which is the order letibot's own test uses")
  ;; the same rule one tool over: a `read` with ranges names its file
  (is (equal "src/cards.lisp"
             (display-target "{\"path\":\"src/cards.lisp\",\"ranges\":[{\"offset\":100}]}"))
      "a windowed read names the file and not the windows")
  ;; **THE HALF THAT MUST SURVIVE.** `todo_write` sends an array and nothing else —
  ;; no scalar at all — and `[…]` is the only thing its label can say.
  (is (equal "[…]"
             (display-target "{\"todos\":[{\"content\":\"x\",\"status\":\"pending\"}]}"))
      "todo_write has no scalar to name, so the placeholder is the label")
  ;; and where the only scalar is a MODIFIER rather than a subject, the placeholder
  ;; is what stops the row reading as if `term` were the thing being signalled
  (is (equal "term […]" (display-target "{\"signal\":\"term\",\"pids\":[1,2,3]}"))
      "a modifier is not a subject, so pkill keeps it")
  ;; a tool with no arguments at all is not made to invent one
  (is (equal "{}" (display-target "{}")) "and nothing is not stretched into something"))

(def-test the-reasoning-header-counts-screen-lines-and-its-mark-is-plain (:suite leticl)
  "letibot: `▸ ESC[1mThoughtESC[0;2m · 13 lines · ctrl-r` — the mark carries no
escape, and 13 is how many ROWS the fold would cost, not how many paragraphs."
  (let* ((text (format nil "~a~%short" (make-string 150 :initial-element #\x)))
         (line (reasoning-header text 80 nil nil)))
    (is (equal (cons "▸ " nil) (first line)) "the mark is plain")
    (is (equal (cons "Thought" '(:bold t)) (second line)))
    (is (search "· 3 lines · ctrl-r" (segs-of (list line)))
        "150 columns at 78 is two rows, plus one: three screen lines")))

(def-test the-transcript-does-not-sit-on-the-box (:suite leticl)
  "letibot row 59 is blank and row 60 the box's top edge; ours had prose on 59.
The reference always puts one gap after the committed rows."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-items s)
          (coerce (list (list :item-id "a" :kind "user"
                              :item (list :type "user" :parts (list (list :kind "text" :text "hi")))))
                  'vector))
    (let ((lines (leticl::%viewport-lines h 60 10)))
      (is (null (car (last lines))) "the last line of the viewport is the gap")
      (is (search "hi" (segs-of (butlast lines))) "and the row is above it"))))

;;; ------------------------------------------------- the wheel (2026-09-20) ;;;

(def-test a-sequence-already-in-the-buffer-decodes-after-the-deadline (:suite leticl)
  "The operator: *\"scrolling codes go straight to prompt input\"*. Under a burst of
wheel events the input thread was stopped past the 60 ms gesture window — the main
thread renders a frame per event, and the collector stops every thread — and
`%poll-char` consulted the clock before the buffer, so the byte after an ESC was
there and was reported absent. The ESC became a lone escape and `[<65;120;30M`
became text. Reproduced by injecting fifteen events: eight leaked."
  (let ((*escape-wait-ms* 0))          ; every deadline has already passed
    (let* ((burst (format nil "~{~C[<65;120;30M~}" (make-list 15 :initial-element (code-char 27))))
           (in (make-string-input-stream burst))
           (keys (loop repeat 15 collect (read-key in))))
      (is (every (lambda (k) (eq (getf k :type) :mouse)) keys)
          "fifteen wheel events, none of them text: ~s" (remove :mouse keys :key (lambda (k) (getf k :type))))
      (is (every (lambda (k) (eq (getf k :kind) :wheel-down)) keys)))))

(def-test the-wheel-scrolls-the-transcript-and-the-pane (:suite leticl)
  "A wheel event is `(:type :mouse :kind :wheel-up)` and the key ladders dispatched
on TYPE, so their `:wheel-up` arms never matched and a wheel did nothing anywhere —
the same dead-code class as `:tools-open`."
  (let ((h (%make-head)))
    (setf (head-scroll h) 0)
    (leticl::%handle-key h (list :type :mouse :x 5 :y 5 :kind :wheel-up))
    (is (= 3 (head-scroll h)) "wheel up scrolls the transcript back three")
    (leticl::%handle-key h (list :type :mouse :x 5 :y 5 :kind :wheel-down))
    (is (= 0 (head-scroll h)) "and wheel down follows again")
    (is (equal "" (composer-buffer (head-composer h))) "and nothing landed in the composer"))
  (let ((*pane-scroll* 0) (*pane-lines* 40) (*pane-room* 10)
        (h (%make-head)))
    (setf (head-mode h) :help)
    (leticl::%handle-key h (list :type :mouse :x 5 :y 5 :kind :wheel-down))
    (is (= 3 *pane-scroll*) "in a pane the wheel scrolls the pane")))

(def-test parked-in-the-scrollback-the-last-row-says-so (:suite leticl)
  "The reference's banner: `── scrolled back · N lines below · ↓ or esc to follow`,
yellow, in the transcript's last row; esc and ↓ follow again, and only then does
esc start arming an interrupt. The scroll is clamped to what exists."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-items s)
          (coerce (loop for i from 1 to 20
                        collect (list :item-id (format nil "u~d" i) :kind "user"
                                      :item (list :type "user"
                                                  :parts (list (list :kind "text"
                                                                     :text (format nil "message ~d" i))))))
                  'vector))
    (setf (head-scroll h) 6)
    (let ((lines (leticl::%viewport-lines h 60 10)))
      (is (search "── scrolled back · 6 lines below" (segs-of (last lines)))
          "the last row is the banner, with how far behind")
      (is (equal '(:fg :yellow) (cdr (first (car (last lines))))) "in yellow"))
    (leticl::%handle-key h (list :type :esc))
    (is (= 0 (head-scroll h)) "esc follows the stream again")
    (is (null leticl::*esc-at*) "and does not start arming an interrupt")
    (setf (head-scroll h) 6)
    (leticl::%handle-key h (list :type :down))
    (is (= 0 (head-scroll h)) "so does ↓")
    (setf (head-scroll h) 100000)
    (leticl::%viewport-lines h 60 10)
    (is (< (head-scroll h) 100000) "and a scroll past the top is clamped to what exists")))

;;; ------------------------------- the full-body panes against letibot's screen ;;;
;;;
;;; Every pane below was measured against the reference at 210x63 on the same
;;; session, both heads captured within a minute of each other. Two of them had
;;; never rendered at all; the rest differed in text, order, indent or style.

(defun %well-formed-lines-p (lines)
  "Every LINE is a list of SEGMENTS and every segment is `(string . plist)` — the
shape `put-segments` can paint. NIL is a blank line and is fine; a line whose
element is itself a line is not, and is exactly what killed two panes."
  (every (lambda (line)
           (every (lambda (seg) (and (consp seg) (stringp (car seg)) (listp (cdr seg))))
                  line))
         lines))

(defun %pane-head ()
  "A head with something in every pane: sessions, settings, jobs, subagents, a
plan, a peeked scrollback and a workspace with this repo's TODO.md."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-session-id s) "s-1789639478142928813"
          (session-head-id s) "h3"
          (session-wiring s) (list :workspace "/home/dead/Projects/leticl" :model "qwen")
          (session-sessions s)
          (list (list :session-id "s-1789639478142928813" :title "hello, what we are doing here"
                      :live t :stored-items 2647
                      :status (list :running nil :items 3 :heads 2)
                      :wiring (list :model "qwen-3.8-27b" :workspace "/home/dead/Projects/leticl"))
                (list :session-id "s-1789418841049398558" :title "" :live nil :stored-items 0
                      :status (list :running nil :items 0 :heads 0)
                      :wiring (list :model "glm-5.3-flash" :workspace "/home/dead/Projects/rano"))
                (list :session-id "s-child" :title "Fix an auto-compaction failure"
                      :parent-session-id "s-1789639478142928813" :live t
                      :status (list :running t :items 1 :heads 0) :wiring (list :model "x")))
          (session-todos s) (list (list :content "S0 decomposition (DONE)" :status "completed")
                                  (list :content "S6 panes" :status "in_progress")
                                  (list :content "P5 sidediff" :status "pending"))
          (session-subagents s)
          (list (list :subagent-id "s-child" :state "running" :prompt "Fix an auto-compaction failure" :role "worker")
                (list :subagent-id "s-child" :state "opening" :prompt "Fix an auto-compaction failure" :role "worker"))
          (head-settings h)
          (list (list :key "mode" :value "allow-all (this box, consented)" :source "" :editable "/mode"
                      :choices (list "read-only" "always-ask" "allow-all"))
                (list :key "model" :value "deepseek/deepseek-flash" :source "" :editable "/models"
                      :choices (list "deepseek/deepseek-flash" "local"))
                (list :key "supervise" :value "on — the guard model answers" :source "" :editable "/supervise")
                (list :key "session" :value "s-1789639478142928813" :source "" :editable "")
                (list :key "permission" :value "150 rule(s)" :source "permission.json" :editable "Always allow, from a prompt"))
          (head-jobs h)
          (list (list :id "j1" :command "sleep 10" :how "asked" :state "running" :running t
                      :produced 1500 :elapsed-ms 0)
                (list :id "j2" :command "ls" :how "promoted" :state "exited 0" :running nil
                      :produced 20 :elapsed-ms 3456))
          (head-peeked h) (list (list :event "delta" :text "hello")
                                (list :event "delta")
                                (list :event "turn_started")))
    h))

(def-test every-pane-renders-well-formed-segment-lines (:suite leticl)
  "The screen showed `render failed — the head is alive; fix and re-push /
TYPE-ERROR / The value (\"\" :DIM T) is not of type STRING` for BOTH the jobs pane
and the subagents pane: their header was `(list LINE (list LINE))`, a \"line\"
whose one segment was itself a line, and `put-segments` handed a list to
`screen-put-string`. Neither pane had ever rendered. This test calls every pane
function the way `%render` does and checks the one shape it can paint; it is the
check that would have caught the bug on the day it landed."
  (let ((h (%pane-head))
        ;; the job-output overlay is a SPECIAL rather than a head slot — the
        ;; window is ephemeral, and a slot is exactly the state a snapshot and a
        ;; reconnect carry (src/session.lisp on `*job-out*`) — so it is bound
        ;; here rather than seeded in `%pane-head`, where it would leak into
        ;; every other test that builds one
        (leticl::*job-out*
          (list :job "j2" :state "exited 0" :from 0 :to 32 :produced 40000
                :dropped 512 :lines (list "   Compiling letibot-tui" "    Finished")
                :next 32 :back (list 0) :loading nil :error nil)))
    (dolist (mode '(:help :status :config :jobs :subagents :peek :job-out :picker :todos))
      (setf (head-mode h) mode (head-picker-sel h) 1)
      (let ((lines (case mode
                     (:help (help-lines 210))
                     (:status (status-screen-lines h 210))
                     (:config (config-lines h (head-settings h) 210))
                     (:jobs (jobs-lines h 210))
                     (:subagents (subagent-lines h 210))
                     (:peek (peek-lines h 210))
                     (:job-out (job-out-lines h 210))
                     (:picker (picker-lines (head-session h) (head-picker-sel h) 210))
                     (:todos (todos-lines h 210)))))
        (is (plusp (length lines)) (format nil "the ~(~a~) pane has rows" mode))
        (is (%well-formed-lines-p lines)
            (format nil "and every one of the ~(~a~) pane's segments is (string . plist)" mode))))
    ;; the job-output overlay has a SECOND shape — the daemon's refusal drawn in
    ;; place of the window — and it is a different branch of the same function,
    ;; so it is painted here too
    (let ((leticl::*job-out* (list :job "j2" :loading nil :back nil
                                   :error "no job `j2` here; `/job` with no argument lists them")))
      (setf (head-mode h) :job-out)
      (is (%well-formed-lines-p (job-out-lines h 210))
          "and a refused read draws segments the painter can take too"))
    ;; and the CARDS, which ride in the same chrome slot and go through the same
    ;; `put-segments`: the permission card and the password card are drawn from
    ;; panes.lisp now, and a card whose \"line\" is a list of lines kills the paint
    ;; exactly the way the two panes above did
    (setf (session-open-decisions (head-session h))
          (list (list :req-id "r1" :kind "exec"
                      :summary "`bash` wants exec access to `ls`" :target "ls"
                      :detail "a listing" :because "the guard says so"
                      :advice (list :would "allow" :by "oracle" :basis "harmless"
                                    :cites (list "trail 1") :latency-ms 9)
                      :options (list (list :option-id "allow_once" :label "Allow once"
                                           :kind "allow_once")
                                     (list :option-id "reject_always" :label "Deny and tell"
                                           :kind "reject_always")))))
    (setf (head-secret-req h) (list :req-id "s1" :prompt "password:" :command "sudo ls"
                                    :deadline 0))
    (dolist (pair (list (cons "permission card" (%card-lines-all h 210))
                        (cons "password card" (leticl::secret-ask-lines h 210))))
      (is (plusp (length (cdr pair))) (format nil "the ~a has rows" (car pair)))
      (is (%well-formed-lines-p (cdr pair))
          (format nil "and every one of the ~a's segments is (string . plist)" (car pair))))
    (setf (head-secret-req h) nil
          (session-open-decisions (head-session h)) nil)
    ;; and through the render itself, onto a screen the size of the capture
    (let ((*stdout* (make-string-output-stream))
          (*pane-scroll* 0)
          (h2 (%on-head :cols 210 :rows 63)))
      (setf (head-jobs h2) (head-jobs h) (head-settings h2) (head-settings h))
      (dolist (mode '(:jobs :subagents :config :help :status :picker :todos))
        (setf (head-mode h2) mode)
        (leticl::%render h2)
        (is (not (search "render failed" (%screen-text h2)))
            (format nil "the ~(~a~) pane paints without a render error" mode))))))

(def-test the-jobs-pane-says-none-the-way-the-reference-does (:suite leticl)
  "letibot's jobs pane, row for row: `background jobs`, a blank, the `none` sentence
four in and dim, a blank, and the sentence about what `running` means. Ours had
never drawn; when it had a header it was ` background jobs ` with a stray dim
empty segment where the blank belongs."
  (let ((h (%make-head)))
    (multiple-value-bind (lines sel-line) (jobs-lines h 210)
      (is (equal '(("background jobs" :bold t)) (first lines)) "the title, bold, no padding")
      (is (null (second lines)) "then a BLANK — nil, not a line with an empty segment")
      (is (string= "    none. The model backgrounds a command with bash's `background: true`; ctrl-o moves the running one."
                   (car (first (third lines))))
          "the `none` sentence, verbatim")
      (is (equal '(:dim t) (cdr (first (third lines)))) "dim")
      (is (null (fourth lines)) "a blank")
      (is (string= "    a job still shows running until the daemon says it settled — between turns, that saying is the daemon's alone."
                   (car (first (fifth lines))))
          "and the closing sentence")
      (is (= 5 (length lines)) "and nothing else")
      (is (= 2 sel-line) "the cursor's line is the first row's, under the two-line header"))
    ;; with jobs: two lines each, the mark painted by state, the picked row reversed
    (setf (head-jobs h) (list (list :id "j1" :command "sleep 10" :how "asked" :state "running"
                                    :running t :produced 1500 :elapsed-ms 0)
                              (list :id "j2" :command "ls" :how "promoted" :state "exited 0"
                                    :running nil :produced 20 :elapsed-ms 3456))
          (head-picker-sel h) 1)
    (multiple-value-bind (lines sel-line) (jobs-lines h 210)
      (let ((text (lines-text lines)))
        (is (search "  [~] j1 sleep 10" (nth 2 text)) "a running job's row")
        (is (search "         asked · running · 1.5 KB out so far" (nth 3 text)) "and its fact line")
        (is (search "▸ [x] j2 ls" (nth 4 text)) "the picked job carries the mark")
        (is (search "         promoted · exited 0 · 20 B out · ran 3.4s" (nth 5 text))
            "a settled job says how it ended and how long it ran"))
      (is (equal '(:fg :yellow) (cdr (second (nth 2 lines)))) "running is yellow")
      (is (member :reverse (cdr (second (nth 4 lines)))) "the picked row is reversed")
      (is (= 4 sel-line) "two lines per row: the second row is line 4"))))

(def-test the-subagents-pane-says-none-the-way-the-reference-does (:suite leticl)
  "letibot's subagents pane: `subagents`, a blank, `none spawned yet…`, a blank,
`arrows move, Enter reads…`. Ours had never drawn (the same nested header as the
jobs pane), and the fold that draws it now is the one the composer's top edge
counts from — by the event's `subagent_id`, which is the child's, not the
envelope's `session_id`, which is the parent's."
  (let ((h (%make-head)))
    (multiple-value-bind (lines sel-line) (subagent-lines h 210)
      (is (equal '(("subagents" :bold t)) (first lines)) "the title")
      (is (null (second lines)) "a blank")
      (is (string= "    none spawned yet. The model spawns them with the task tool."
                   (car (first (third lines)))))
      (is (null (fourth lines)))
      (is (string= "    arrows move, Enter reads the subagent's output, o switches into it — subagents are hidden from ctrl-s."
                   (car (first (fifth lines)))))
      (is (= 2 sel-line)))
    ;; two children of one parent, each with two state events: two rows, latest state each
    (setf (session-subagents (head-session h))
          (list (list :session-id "parent" :subagent-id "s-aaaaaaaaaaaa11111111" :state "done" :prompt "first" :role "worker")
                (list :session-id "parent" :subagent-id "s-bbbbbbbbbbbb22222222" :state "running" :prompt "second" :role "worker")
                (list :session-id "parent" :subagent-id "s-bbbbbbbbbbbb22222222" :state "opening" :prompt "second" :role "worker")
                (list :session-id "parent" :subagent-id "s-aaaaaaaaaaaa11111111" :state "running" :prompt "first" :role "worker")))
    (let ((rows (subagent-rows h)))
      (is (= 2 (length rows)) "two subagents, not four events and not one parent")
      (is (string= "done" (getf (first rows) :state)) "the first, spawned first, is done")
      (is (string= "running" (getf (second rows) :state)) "the second is running"))
    (setf (head-picker-sel h) 0)
    (let ((text (lines-text (subagent-lines h 210))))
      (is (search "▸ [x] first" (nth 2 text)) "the picked row, its mark by state")
      (is (search "       …11111111 · role worker · done" (nth 3 text)) "the short id, role and state under it")
      (is (search "  [~] second" (nth 4 text)) "the other row"))
    (is (string= "1 subagent running" (leticl::composer-title h))
        "and the box's top edge counts the same fold")
    ;; the legend is the EDGE's to place: `box_edge` frames it and pins it right
    ;; (app.rs:5384-5411), so the title itself carries no padding of its own
    (let ((edge (lines-text (list (leticl::composer-box-top h 60)))))
      (is (search "1 subagent running ─╮" (first edge))
          "and the edge pins it to the RIGHT, framed, not hard against the ╭"))))

(def-test the-config-pane-renders-every-row-with-its-source-under-the-cursor (:suite leticl)
  "The screen showed `UNBOUND-VARIABLE / The variable ANAPHORA:IT is unbound.`:
an `awhen` whose TEST used `it` — `(and (getf r :editable) (plusp (length it)))` —
so any daemon row with an `editable` verb killed the pane. Against letibot's
screen the pane is `config`, a blank, a dim section name, `▸ ✎ diff view
split` reversed with `       from PATH` dim under it, the other head rows, a blank,
`session — the daemon` with `✎` only on the rows a verb changes, then the daemon's
files, then the closing sentence."
  (let ((h (%pane-head)))
    (setf (head-prefs h) (list :show-reasoning nil :show-tools t :raw-calls nil :diff "split")
          (head-picker-sel h) 0)
    (multiple-value-bind (lines sel-line) (config-lines h (head-settings h) 210)
      (let ((text (lines-text lines)))
        (is (string= "config" (nth 0 text)) "the title alone")
        (is (string= "" (nth 1 text)) "a blank")
        (is (string= "  head — this window" (nth 2 text)) "the head's section, dim")
        (is (equal '(:dim t) (cdr (first (nth 2 lines)))))
        (is (string= "▸ ✎ diff view        split" (nth 3 text)) "the cursor row, keyed to the longest key")
        (is (equal '(:reverse t) (cdr (first (nth 3 lines)))) "reversed whole")
        (is (uiop:string-prefix-p "       from " (nth 4 text)) "its source under it")
        (is (string= "  ✎ thinking         folded" (nth 5 text)))
        (is (string= "  ✎ tool output      open" (nth 6 text)) "the live fold's word")
        (is (string= "  ✎ raw tool calls   hidden" (nth 7 text)) "shown/hidden, the reference's words")
        (is (string= "" (nth 8 text)) "a blank between sections")
        (is (string= "  session — the daemon" (nth 9 text)))
        (is (string= "  ✎ mode             allow-all (this box, consented)" (nth 10 text))
            "a daemon row a verb changes carries ✎")
        (is (string= "    session          s-1789639478142928813" (nth 13 text))
            "one that takes a restart does not")
        (is (some (lambda (l) (search "files — edit with an editor" l)) text) "the daemon's files")
        (is (some (lambda (l) (search "permission.json" l)) text) "by name")
        (is (search "✎ changes now and is kept" (car (last text))) "and the closing sentence")
        (is (not (some (lambda (l) (search "NIL" l)) text)) "and nothing prints NIL"))
      (is (= 3 sel-line) "the cursor's line: title, blank, section, row"))
    ;; the cursor walks EVERY row, and the source follows it
    (setf (head-picker-sel h) 4)
    (multiple-value-bind (lines sel-line) (config-lines h (head-settings h) 210)
      (is (search "▸ ✎ mode" (nth sel-line (lines-text lines))) "the fifth row is the daemon's mode")
      (is (= 9 sel-line) "on line 9 — the blank and the second section name are counted, and the source line only follows the cursor"))
    ;; enter on a daemon row goes through the verb, not around it
    (setf (head-picker-sel h) 6)        ; supervise
    (leticl::config-change h)
    (is (search "supervise off" (head-status-note h)) "supervise flips through its own verb")
    (setf (head-picker-sel h) 7)        ; session, not editable
    (leticl::config-change h)
    (is (search "takes a restart" (head-status-note h)) "a read-only row says why")))

(def-test the-todos-cursor-walks-the-repo-items-and-enter-unfolds-one (:suite leticl)
  "letibot's screen, three captures: on open no `▸` anywhere (the cursor rests
on row 0, a heading, and only items show it); after two Downs `▸ [x] T3` — the
THIRD item, because a cursor on a heading counts from the item below it; after
Enter, T3's body under it at fourteen columns and its ` ···` gone. Ours put the
cursor on the session's plan, so Up and Down moved a reversed bar nobody asked for
and Enter did nothing to the file's items."
  (let* ((dir-pathname (make-pathname :name nil :type nil
                                      :directory '(:absolute "tmp" "leticl-todos-cursor-test")))
         (dir "/tmp/leticl-todos-cursor-test")
         (path (make-pathname :name "TODO" :type "md"
                              :directory (pathname-directory dir-pathname)))
         (*repo-todo-open* nil)
         (*pane-scroll* 0) (*pane-room* 40) (*pane-lines* 0)
         (h (%make-head)))
    (unwind-protect
         (progn
           (ensure-directories-exist dir-pathname)
           (with-open-file (out path :direction :output
                                :if-does-not-exist :create :if-exists :supersede)
             (format out "# TODO~%~%## Dependency graph~%~%prose~%~%## Phase 0~%~%- [x] T1 first~%    pinned abc~%~%- [x] T2 second~%~%## Phase 1~%~%- [x] T3 third~%    body one~%    body two~%~%- [ ] T4 fourth~%"))
           (setf (session-wiring (head-session h)) (list :workspace dir)
                 (head-mode h) :todos
                 (head-picker-sel h) 0)
           (flet ((text () (lines-text (todos-lines h 210)))
                  (key (k) (leticl::%handle-key h (list :type k))))
             (let ((text (text)))
               (is (string= "todos" (first text)) "the title alone — no hint suffix")
               (is (not (some (lambda (l) (search "▸" l)) text))
                   "on open the cursor is on a heading and shows nowhere")
               (is (some (lambda (l) (string= "      Dependency graph" l)) text)
                   "a heading with no items sits six in, with no box")
               (is (some (lambda (l) (string= "    [x] Phase 0  [2/2]" l)) text)
                   "a heading with items sits four in")
               (is (some (lambda (l) (string= "        [x] T1 first ···" l)) text)
                   "an item eight in, its `···` one space after the text")
               (is (string= "  the file itself is in the workspace; this pane never writes it."
                            (car (last text)))
                   "and the reference's closing line"))
             (key :down) (key :down)
             (is (some (lambda (l) (string= "      ▸ [x] T3 third ···" l)) (text))
                 "two Downs from the top land on the THIRD item, as letibot's did")
             (key :enter)
             (let ((text (text)))
               (is (some (lambda (l) (string= "      ▸ [x] T3 third" l)) text)
                   "Enter unfolds it — the `···` goes")
               (is (some (lambda (l) (string= "              body one" l)) text)
                   "and the body is drawn fourteen in")
               (is (some (lambda (l) (string= "              body two" l)) text) "all of it"))
             (key :down)
             (is (not (some (lambda (l) (search "body one" l)) (text)))
                 "moving folds it again")
             (is (some (lambda (l) (string= "      ▸ [ ] T4 fourth" l)) (text)) "on the fourth")
             (key :down)
             (is (some (lambda (l) (string= "      ▸ [x] T1 first ···" l)) (text))
                 "and past the end it wraps to the first")
             (key :tab)
             (is (some (lambda (l) (string= "              pinned abc" l)) (text))
                 "Tab unfolds too, as the operator asked")
             (key :up)
             (is (some (lambda (l) (string= "      ▸ [ ] T4 fourth" l)) (text))
                 "Up from the first wraps to the last")
             (multiple-value-bind (lines sel-line) (todos-lines h 210)
               (is (search "▸ [ ] T4" (nth sel-line (lines-text lines)))
                   "and the cursor's LINE names the row it is on"))))
      (ignore-errors (delete-file path)))))

(def-test the-help-is-the-references-row-for-row (:suite leticl)
  "letibot's help against ours, stripped: 41 non-blank rows against 50. Theirs is
one title, `keys and commands`, a cyan key column sixteen wide, a plain description
wrapped under itself at nineteen, no separate list of slash verbs, and `/help or
esc closes this`. Ours had ` leticl keys `, bold keys, dim text and a `commands`
section. The two heads must teach the same keys the same way."
  (let* ((lines (help-lines 210))
         (text (lines-text lines)))
    (is (string= "keys and commands" (first text)) "the title")
    (is (null (second lines)) "a blank under it")
    ;; 36 measured against letibot `2deceb8`'s screen; `ce31f1a` added the
    ;; `/config` row (the operator's running binary predates it, so its screen
    ;; still shows 36 — the source is the reference here, the binary the evidence),
    ;; and R10 added `/notes`, which the reference teaches too (`app.rs:9793-9797`)
    (is (= 39 (count-if (lambda (l) (plusp (length l))) text))
        "39 non-blank rows at the capture's width: the reference's 36 plus /config and
 /notes and, from R22, the `ctrl-n` row — which letibot lands too, so the two teach the
 same keys again")
    (is (string= "  enter           send what you typed; while a turn runs it is queued as a follow-up"
                 (third text))
        "the first row, key sixteen wide after two")
    (is (equal '(:fg :cyan) (cdr (first (third lines)))) "the key is cyan")
    (is (null (cdr (second (third lines)))) "and the description plain")
    (is (string= "  /help or esc closes this" (car (last text))) "the closer")
    (is (equal '(:dim t) (cdr (first (car (last lines))))) "dim")
    (is (not (some (lambda (l) (search "/sessions" l)) text))
        "and no list of every slash verb — the reference names the ones it teaches"))
  ;; narrow, a description wraps under itself at nineteen columns
  (let ((text (lines-text (help-lines 80))))
    (is (some (lambda (l) (and (> (length l) 19)
                               (string= (subseq l 0 19) (make-string 19 :initial-element #\space))))
              text)
        "a continuation line is indented nineteen")))

(def-test the-status-screen-explains-its-counters (:suite leticl)
  "letibot's /status: `this head`, then one row per counter — session, head, seq,
filtered, dropped, scrubbed, resync, verbosity, workspace — each with WHY it is
there wrapped dim under it, and `/status or esc closes this`. 26 non-blank rows on
its screen against our 18.
Ours was ` status ` and a bare list of pairs, three of which the reference does not
have and one of which printed `NIL`.

**The `unreadable` row is asserted here at ZERO on purpose**, which is R3's rule and
not an accident of the fixture: a head that has never met a frame it cannot read says
`0`, and that is a different statement from a head that does not count them at all.
The counting itself is the subject of
`an-unreadable-frame-is-said-counted-and-survived`, which moves it."
  (let* ((h (%pane-head))
         (*rendered-total* 23144) (*filtered-total* 46) (*scrubbed-total* 0) (*resyncs* 0)
         ;; **Bound here, with the other counters, because it is a GLOBAL.** A suite
         ;; runs two hundred heads in one image, and a counter that survives between
         ;; them stops being about the thing it names: this test read 3 the first time
         ;; it ran against the new code, from frames three OTHER tests had handed the
         ;; fold, and the number it was asserting on was nobody's.
         (*unreadable-total* 0)
         (*verbosity* :normal))
    (setf (session-seq (head-session h)) 27485
          (session-heads (head-session h)) (list (list :head-id "h3") (list :head-id "h18")))
    (let* ((lines (status-screen-lines h 210))
           (text (lines-text lines)))
      (is (string= "this head" (first text)) "the title")
      (is (= 34 (count-if (lambda (l) (plusp (length l))) text))
          "34 non-blank rows — 21 here when the reference's screen had 26, plus the three the unreadable row costs, the four the protocol row does, the three R10's `notes` row costs (its value and two wrapped lines of why), and the three the `eval` row costs")
      (is (string= "  session     s-1789639478142928813" (third text)) "the key twelve wide, the value plain")
      (is (equal '(:dim t) (cdr (first (third lines)))) "the key dim")
      (is (null (cdr (second (third lines)))) "the value not")
      (is (uiop:string-prefix-p "              In full, because this is the form a command takes."
                                (fourth text))
          "the explanation fourteen in")
      (is (some (lambda (l) (string= "  head        h3 · 2 attached" l)) text) "the head and how many")
      (is (some (lambda (l) (string= "  seq         27485 · 23144 rendered" l)) text) "seq and rendered")
      (is (some (lambda (l) (string= "  filtered    46 (normal)" l)) text) "filtered at the verbosity")
      (is (some (lambda (l) (string= "  unreadable  0" l)) text)
          "and the unreadable row is THERE and reads 0 — present and zero, not absent")
      (is (some (lambda (l) (string= "  workspace   ~/Projects/leticl" l)) text) "the workspace, with ~")
      (is (string= "  /status or esc closes this" (car (last text))) "the closer")
      (is (not (some (lambda (l) (search "NIL" l)) text)) "and nothing prints NIL"))))

(def-test the-picker-hides-subagents-and-right-aligns-the-facts (:suite leticl)
  "letibot's picker on the same daemon had 28 sessions; ours 58, because ours
listed the subagents too. Its rows are `▸  1  name` with the facts right-aligned
to the pane's width and the full id under every row; ours were ` ● name`."
  (let* ((h (%pane-head))
         (s (head-session h)))
    (is (= 2 (length (picker-sessions s))) "the child session is not listed")
    ;; 206 is the BODY width a 210-column terminal gives a pane: `%render` hands
    ;; every pane its cols net of the gutter and the right margin, and the row
    ;; fills exactly that — measured, letibot's facts end where its box does
    (multiple-value-bind (lines sel-line) (picker-lines s 0 206)
      (let ((text (lines-text lines)))
        (is (string= "sessions in this daemon" (first text)) "the title")
        (is (string= "" (second text)) "a blank")
        (is (uiop:string-prefix-p "▸  1  hello, what we are doing here" (third text))
            "the cursor's row: mark, number, name")
        (is (= 206 (string-width (third text)))
            "the facts end at the pane's right edge — 206 columns of 210")
        (is (search "2647 rows · 2 heads · qwen-3.8-27b" (third text))
            "the store's count, the heads and the model")
        (is (string= "      s-1789639478142928813  ~/Projects/leticl" (fourth text))
            "the full id and the workspace under it")
        (is (uiop:string-prefix-p "   2  …49398558" (fifth text))
            "an unnamed session shows its short id")
        (is (search "on disk · glm-5.3-flash" (fifth text)) "and that it is stored")
        (is (uiop:string-prefix-p "  ↑↓ moves · enter switches" (nth 7 text)) "the hints close it"))
      (is (member :reverse (cdr (first (third lines)))) "the picked row is reversed")
      (is (member :bold (cdr (second (third lines)))) "and the session we are in keeps its bold name")
      (is (= 2 sel-line) "the cursor's line is the first row's"))
    (is (= 4 (nth-value 1 (picker-lines s 1 210))) "two lines per row: the second is line 4")))

(def-test a-heading-with-no-items-sits-six-in-and-dim (:suite leticl)
  "letibot draws `      Dependency graph` — six in, dim, no box — where ours drew it
eight in and plain: its indent is 6 in the reference's `render_todo_md`, and a
heading with no mark is `{pad}{cursor}{text}` in one dim run."
  (let ((rows (read-todo-md (format nil "## Empty~%~%prose~%~%## Full~%~%- [ ] a~%"))))
    (is (= 6 (getf (first rows) :indent)) "an empty heading is indented six")
    (is (= 4 (getf (second rows) :indent)) "one with items, four")
    (let ((line (first (leticl::%todo-row-lines (first rows)))))
      (is (= 1 (length line)) "one segment")
      (is (string= "      Empty" (car (first line))) "pad and cursor, then the text")
      (is (equal '(:dim t) (cdr (first line))) "dim"))))

;;; ------------------------------------- the fast render path (2026-09-20) ;;;
;;;
;;; `string-width` and `screen-put-string` stopped going through `clusters` on
;;; the common case (measured: 56% of the frame), `char-width` became a table
;;; lookup, and the painter stopped calling `format`. Each of these is a second
;;; spelling of a rule that already had one, so each is held to the first.

(defparameter *tricky-strings*
  (list (cons "empty" "")
        (cons "spaces" "   ")
        (cons "ascii" "hello world")
        (cons "box glyphs" "┌─ lisp · ▸ Ran │")
        (cons "cjk" (format nil "a~C~Cb" (%ch #x4e2d) (%ch #x6587)))
        (cons "family" (format nil "~C~C~C~C~C" (%ch #x1f468) (%ch #x200d)
                               (%ch #x1f469) (%ch #x200d) (%ch #x1f467)))
        (cons "two families" (format nil "~C~C~C ~C~C~C" (%ch #x1f468) (%ch #x200d)
                                     (%ch #x1f469) (%ch #x1f468) (%ch #x200d) (%ch #x1f467)))
        (cons "flag" (format nil "~C~C" (%ch #x1f1ec) (%ch #x1f1e7)))
        (cons "three indicators" (format nil "~C~C~C" (%ch #x1f1ec) (%ch #x1f1e7) (%ch #x1f1fa)))
        (cons "combining" (format nil "e~Cx" (%ch #x301)))
        (cons "leading combining" (format nil "~Ce" (%ch #x301)))
        (cons "zwj after a letter" (format nil "a~C~Cb" (%ch #x200d) (%ch #x1f468)))
        (cons "newline" (format nil "a~%b"))
        (cons "control then mark" (format nil "a~C~Cb" (code-char 7) (%ch #x301)))
        (cons "escapes" (format nil "~C[0;1;36mred~C[0m" (%ch 27) (%ch 27)))
        (cons "trailing escape" (format nil "ab~C[0m" (%ch 27)))
        (cons "unterminated escape" (format nil "ab~C[3" (%ch 27)))
        (cons "osc" (format nil "~C]8;;http://x~Cx~C]8;;~C" (%ch 27) (code-char 7) (%ch 27) (code-char 7)))
        (cons "astral cjk" (format nil "~C" (%ch #x20000)))
        (cons "variation supplement" (format nil "a~C" (%ch #xe0100)))
        (cons "mixed" (format nil "abc 列宽度 🙂 терминал ~C~C z" (%ch #x1f1fa) (%ch #x1f1e6))))
  "Strings that exercise every rule the one-pass width walker mirrors.")

(def-test string-width-agrees-with-clusters (:suite leticl)
  "`clusters` is the definition of a cluster; `string-width` walks the same rules
without consing one. If they ever disagree the border lands inside the text."
  (dolist (case *tricky-strings*)
    (let ((text (cdr case)))
      (is (= (reduce #'+ (mapcar #'cluster-cols (clusters text)))
             (string-width text))
          (format nil "~a: clusters say ~a, string-width says ~a" (car case)
                  (reduce #'+ (mapcar #'cluster-cols (clusters text)))
                  (string-width text))))))

(def-test string-width-bounds-measure-a-prefix-in-place (:suite leticl)
  "The bounded form is what lets `wrap-segments` measure a word without its
trailing space and without copying it; it must say what the copy would."
  (let ((cjk (format nil "ab~C~C  " (%ch #x4e2d) (%ch #x6587))))
    (is (= 8 (string-width cjk)) "the whole: 2 + 4 + 2")
    (is (= 6 (string-width cjk :end 4)) "to the end of the wide pair")
    (is (= 4 (string-width cjk :end 3)) "a wide char at the boundary counts whole")
    (is (= (string-width (subseq cjk 2 4)) (string-width cjk :start 2 :end 4)) "start and end")
    (is (= 0 (string-width cjk :start 3 :end 3)) "an empty range is zero")
    (is (= 0 (string-width cjk :start 5 :end 2)) "an inverted range is zero, not an error")
    (is (= 8 (string-width cjk :end 100)) "an end past the string is clamped")
    (is (= 0 (string-width "")) "an empty string is zero")
    (is (= 3 (string-width (make-array 3 :element-type 'character :adjustable t
                                         :fill-pointer 3 :initial-element #\x)))
        "a non-simple string is measured, not refused")))

(def-test char-width-past-the-table-still-answers (:suite leticl)
  "The byte table stops at #x20000; above it the binary search answers, and the
two must agree at the seam."
  (is (= 1 (char-width (%ch #x1ffff))) "the last table entry")
  (is (= 2 (char-width (%ch #x20000))) "the first code past it, CJK extension B")
  (is (= 2 (char-width (%ch #x3fffd))) "the end of the wide range")
  (is (= 1 (char-width (%ch #x3fffe))) "and one past it")
  (is (= 0 (char-width (%ch #xe0100))) "the variation selector supplement is zero-width")
  (is (= 1 (char-width (%ch #x10ffff))) "the last code point is one column"))

(def-test plain-columns-decides-the-fast-path-honestly (:suite leticl)
  "The painter places a string one cell per character only when every character
is one plain column. Anything that could join, pair, extend or hide must say no."
  (is (leticl::plain-columns-p "hello ┌─ ▸ ·") "letters and box glyphs")
  (is (leticl::plain-columns-p "") "an empty string, vacuously")
  (is (not (leticl::plain-columns-p (format nil "a~Cb" (%ch #x4e2d)))) "a wide char")
  (is (not (leticl::plain-columns-p (format nil "e~C" (%ch #x301)))) "a combining mark")
  (is (not (leticl::plain-columns-p (format nil "~C[1mx" (%ch 27)))) "an escape")
  (is (not (leticl::plain-columns-p (format nil "a~%b"))) "a control")
  (is (not (leticl::plain-columns-p (format nil "~C~C" (%ch #x1f1ec) (%ch #x1f1e7)))) "a flag"))

(def-test placement-agrees-with-measurement-on-every-tricky-string (:suite leticl)
  "The property `measurement-and-placement-count-the-same-thing` states, over the
whole tricky corpus, on both of the painter's paths."
  (dolist (case *tricky-strings*)
    (let* ((text (cdr case))
           (s (make-screen 80 1))
           (end (screen-put-string s 0 0 text)))
      (is (= (string-width text) end)
          (format nil "~a: measured ~a, placed ~a" (car case) (string-width text) end)))))

(def-test a-wide-char-at-the-last-column-degrades-to-a-space (:suite leticl)
  "A two-column glyph that does not fit becomes a space, not a wrap; the cell
after it is untouched."
  (let ((s (make-screen 3 1)))
    (is (= 3 (screen-put-string s 0 0 (format nil "ab~C" (%ch #x4e2d))))
        "the wide char at column 2 of 3 takes the one column left")
    (is (char= #\space (cell-ch (screen-cell s 0 2))) "as a space"))
  (let ((s (make-screen 4 1)))
    (is (= 4 (screen-put-string s 0 0 (format nil "ab~C" (%ch #x4e2d)))) "with room it is two cells")
    (is (char= (%ch #x4e2d) (cell-ch (screen-cell s 0 2))) "the glyph")
    (is (char= leticl::+wide-cont+ (cell-ch (screen-cell s 0 3))) "and the continuation")))

(def-test the-breakpoint-ranges-tile-the-input (:suite leticl)
  "The invariant the whole surface rests on, and the reference states it in the same
words (`width.rs:525-542`): `ranges[0].start == 0`, each `end` is the next `start`,
the last `end` is the length, and no range is empty.

**Everything that wraps is derived from these ranges**, so a range list that does not
tile the text is not a mis-drawn row — it is a row whose characters are either
duplicated or gone, which is the class of defect this file exists to prevent.

The corpus is every character class the rule distinguishes: plain prose, CJK, a ZWJ
family, a flag, a combining mark, an escape sequence, a tab, a newline, a CRLF, and
an over-wide run — each at several widths, each checked at every width from 1 to 12."
  (dolist (text (list ""
                       "the quick brown fox jumps over the lazy dog"
                       (format nil "~{~C~}" (loop repeat 12 collect (%ch #x4e2d)))
                       (format nil "hello ~C~C~C~C~C~C" (%ch #x4e2d) (%ch #x597d)
                               (%ch #x4e16) (%ch #x754c) (%ch #x4e2d) (%ch #x597d))
                       (format nil "~C~C~C~C~C" (%ch #x1f468) leticl::+esc-zwj+
                               (%ch #x1f469) leticl::+esc-zwj+ (%ch #x1f467))
                       (format nil "~C~C" (%ch #x1f1e9) (%ch #x1f1ea))
                       (format nil "e~Cabcd~Cefgh" (%ch #x0301) (%ch #x0301))
                       (format nil "~C[31mabcdefgh~C[0m" (%ch 27) (%ch 27))
                       (format nil "ab~Ccd~Cef" #\tab #\tab)
                       (format nil "one~%two")
                       (format nil "one~C~Ctwo" #\return #\newline)
                       "https://example.com/abcdefghijklmnop"
                       (format nil "one~%")
                       (format nil "~%one")))
    (dotimes (w 12)
      (let ((cols (1+ w)) (prev 0))
        (dolist (r (wrap-ranges text cols))
          (is (= prev (car r))
              (format nil "~s at ~d: a range starts where the last ended (~s)" text cols r))
          ;; **At most one empty range, and it is the last one.** Two cases produce
          ;; it and the reference produces both: the empty text (`break_cells` always
          ;; emits one row) and a hard break at the very END of the text, which opens
          ;; the row the newline landed on. An empty range in the MIDDLE would be a
          ;; row with nothing on it and characters on both sides — which is a row the
          ;; text did not ask for.
          (if (= (cdr r) (car r))
              (is (equal r (car (last (wrap-ranges text cols))))
                  (format nil "~s at ~d: an empty range must be the last one" text cols))
              (is (plusp (length text))
                  (format nil "~s at ~d: only the empty text has a row of no width" text cols)))
          (setf prev (cdr r)))
        (is (= (length text) prev)
            (format nil "~s at ~d: the last range ends at the length" text cols))))))

(def-test the-transcript-and-the-caret-break-in-the-same-places (:suite leticl)
  "**The measurement that made this a merge, kept as a guard.**

Two scanners used to decide where a line ends: `wrap-segments` for the transcript and
`wrap-ranges` for the composer's caret. They disagreed on five of the eight inputs
below — and not subtly: `hello 中文中文中文` at ten columns was TWO rows to the
transcript and THREE to the caret, whose first row was six columns wide where the
transcript's was ten. Nothing was dropped; the caret was simply drawn on a row that
was not where the reader thought it was.

The invariant asserted here is the one the reference states for its own pair
(`width.rs:525-542`): **the rows and the ranges describe the same lines.** Same count,
and each row's text is the slice of the text that range covers — with the row-ending
whitespace and the newline trimmed, which is what a row is allowed to lose.

If a second scanner is ever added back, this fails on the corpus below rather than on
the operator's screen."
  (let ((cases (list (list "plain prose" "the quick brown fox jumps over the lazy dog" 12)
                     (list "an over-wide URL" "https://example.com/abcdefghijklmnop" 10)
                     (list "CJK with no spaces"
                           (format nil "~{~C~}" (loop repeat 8 collect (%ch #x4e2d))) 4)
                     (list "CJK after prose"
                           (format nil "hello ~C~C~C~C~C~C" (%ch #x4e2d) (%ch #x597d)
                                   (%ch #x4e16) (%ch #x754c) (%ch #x4e2d) (%ch #x597d)) 10)
                     (list "a combining mark"
                           (format nil "e~Cabcd~Cefgh" (%ch #x0301) (%ch #x0301)) 4)
                     (list "an escape sequence"
                           (format nil "~C[31mabcdefgh~C[0m" (%ch 27) (%ch 27)) 6)
                     (list "a ZWJ family"
                           (format nil "~C~C~C~C~Cx" (%ch #x1f468) leticl::+esc-zwj+
                                   (%ch #x1f469) leticl::+esc-zwj+ (%ch #x1f467)) 2)
                     (list "tabs" (format nil "ab~Ccd~Cef" #\tab #\tab) 4)
                     (list "a newline" (format nil "one~%two") 8)
                     (list "a trailing newline" (format nil "one~%") 8))))
    (dolist (c cases)
      (destructuring-bind (name text cols) c
        (let* ((lines (wrap-segments (list (cons text nil)) cols))
               (ranges (wrap-ranges text cols))
               (rows (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))
          (is (= (length lines) (length ranges))
              (format nil "~a: ~d rows but ~d ranges" name (length lines) (length ranges)))
          ;; compared by VISIBLE text, because a row carries its escapes and an
          ;; escape measures no columns: the interesting claim is which characters
          ;; each side puts on the line
          (loop for row in rows
                for r in ranges
                do (is (string= (visible-row row)
                                (string-right-trim '(#\space #\newline #\return)
                                                   (visible-row (subseq text (car r) (cdr r)))))
                       (format nil "~a: row ~s is not what the range ~s covers"
                               name (visible-row row) r))))))))

(def-test the-two-breakpoint-paths-agree (:suite leticl)
  "A plain string is walked one character at a time and anything else through
`clusters`, because the cell walk is a call per character and `wrap-segments` runs on
every visible row of every frame. **Two paths, one rule** — and this is what makes
that true rather than intended, the same way `string-width-agrees-with-clusters` holds
the two width walks together.

The plain path is reached by construction (`plain-columns-p`), so the check is that a
string it ACCEPTS gives the same answer through both: the corpus is restricted to
strings with nothing wide, nothing zero-width and no escape, which is exactly what
`plain-columns-p` promises, and the assertion is on the ranges themselves — the
boundaries a wrapped row is cut at, not a summary of them."
  (dolist (text (list "" "a" "ab cd" "  leading" "trailing  " "one  two   three"
                      "a b c d e f g h i j k" "https://example.com/abcdefghij"
                      (format nil "~a" (make-string 40 :initial-element #\x))
                      (format nil "word ~a word" (make-string 30 :initial-element #\y))))
    (is (leticl::plain-columns-p text) (format nil "~s is a plain-columns string" text))
    (dotimes (w 14)
      (let ((cols (1+ w)))
        (is (equal (leticl::%break-ranges-plain text (length text) cols)
                   (leticl::%break-ranges-cells text (length text) cols))
            (format nil "~s at ~d: the plain and cluster paths disagree" text cols))))))

(def-test wrap-measures-the-visible-word-in-place (:suite leticl)
  "The visible width of a word is measured without the trimmed copy; the
break decisions must not move."
  (flet ((texts (lines) (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))
    ;; words that fit exactly: the trailing space is not counted against the width
    (is (equal '("abc def" "ghi") (texts (wrap-segments (list (cons "abc def ghi" nil)) 7)))
        "a row whose words fit exactly is not broken early")
    ;; an over-wide run hard-breaks at the column budget, and the SPACE AFTER it is a
    ;; real space between two words on the row it lands on (`ef x`), which is the
    ;; reference's answer: it is not a chunk boundary and it is not thrown away
    (is (equal "abcdef x" (apply #'concatenate 'string
                                 (texts (wrap-segments (list (cons "abcdef x" nil)) 4))))
        "every character survives the hard break, and the word space with it")
    (is (equal '("abcd" "ef x") (texts (wrap-segments (list (cons "abcdef x" nil)) 4)))
        "four columns of letters, then the remainder with its space")
    ;; wide characters count two per cell on both measurements
    (let ((cjk (format nil "~C~C ~C~C" (%ch #x4e2d) (%ch #x6587) (%ch #x4e2d) (%ch #x6587))))
      (is (= 2 (length (wrap-segments (list (cons cjk nil)) 5)))
          "two wide pairs and a space do not fit in five columns")
      (is (= 1 (length (wrap-segments (list (cons cjk nil)) 9))) "but do in nine"))
    (is (equal (list (list (cons "a b" nil))) (wrap-segments (list (cons "a b" nil)) 0))
        "zero columns returns the segments as one line, unchanged")
    (is (null (wrap-segments nil 10)) "no segments, no rows")
    (is (null (wrap-segments (list (cons "" nil)) 10)) "an empty segment, no rows")))

(def-test the-painter-writes-decimals-like-format (:suite leticl)
  "`%write-decimal` replaced `~D` in the cursor move; the bytes must not change."
  (dolist (n '(0 1 7 9 10 11 63 99 100 210 999 1000 12345))
    (is (string= (format nil "~D" n)
                 (with-output-to-string (o) (leticl::%write-decimal n o)))
        (format nil "~d" n)))
  (is (string= (format nil "~C[64;211H" (code-char 27))
               (with-output-to-string (o) (leticl::%move-to o 63 210)))
      "a move is 1-based in both coordinates"))

(defun %screen-row-text (s row)
  "The row of SCREEN as a reader sees it: a wide cluster's continuation cell is not a
character of its own, and the row's padded tail is not text.

This is the only measurement that catches a cell DROPPED at the right edge —
`screen-put` refuses an out-of-range column in silence, so a line that overflows
looks merely short from inside and loses its tail on the terminal."
  (let ((out (make-string-output-stream)))
    (loop for c of-type fixnum from 0 below (screen-cols s)
          for ch = (cell-ch (screen-cell s row c))
          unless (char= ch leticl::+wide-cont+)
            do (write-char ch out))
    (string-right-trim " " (get-output-stream-string out))))

(defun %paint-lines (lines cols rows)
  "LINES placed at the left of a fresh screen; the ROWS of text that reached it."
  (let ((s (make-screen cols rows)))
    (loop for line in lines
          for r of-type fixnum from 0 while (< r rows)
          do (leticl::put-segments s r 0 line))
    (loop for r of-type fixnum from 0 below rows collect (%screen-row-text s r))))

(defun %four-wide (n)
  "N copies of a double-width character, as the wire would deliver them."
  (format nil "~{~C~}" (loop repeat n collect (%ch #x4e2d))))

;;; ------------------------ double-width text must not be eaten -------- ;;;
;;;
;;; The operator's report, and the ONLY entry in `docs/parity/` where content is
;;; LOST rather than mis-drawn. `%split-words` split on `#\space` alone, so a CJK
;;; paragraph was ONE word; `%hard-break` then chunked it by CHARACTER INDEX against
;;; a COLUMN budget — `(subseq word i (+ i cols))` — and each chunk was 2*cols
;;; COLUMNS. `screen-put` drops every write past the right edge without a word, so
;;; half of every line was gone and the row merely looked short.

(def-test a-wide-character-line-wraps-at-the-column-budget (:suite leticl)
  "Ten double-width characters, twenty columns of text, in a body eight columns wide.

Every cluster has to reach the terminal, which is a statement about the SCREEN and
not about the string: `wrap-segments` can return lines that look right and still lose
their tails, because the painter refuses an out-of-range column in silence.

The break opportunity that makes this work is BETWEEN TWO WIDE CLUSTERS, which is
letibot's second rule (width.rs:451-454): a space is not what separates one Chinese
run from the next, so a space-only splitter returns the whole paragraph as one word."
  (let* ((text (%four-wide 10))
         (lines (wrap-segments (list (cons text nil)) 8))
         (texts (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))
    (is (string= text (apply #'concatenate 'string texts))
        "wrapping alone keeps every cluster")
    (is (= 3 (length texts)) "twenty columns of double-width text in rows of eight is three rows")
    (dolist (row texts) (is (<= (string-width row) 8) "and no row exceeds the budget"))
    ;; and through the painter, which is where a lost cell would show
    (let ((rows (%paint-lines lines 8 4)))
      (is (string= text (apply #'concatenate 'string
                               (subseq rows 0 (length lines))))
          "every cluster is on the screen, none dropped at the right edge")
      (is (string= (%four-wide 4) (first rows)) "the first row is as many as fit")
      (is (string= (%four-wide 2) (third rows)) "and the last holds the remainder"))))

(def-test a-cjk-run-fills-the-row-it-started-on (:suite leticl)
  "The break opportunity before a wide cluster is not only about DATA — the column
rule alone keeps every cluster — it is about WHERE the line breaks, and this is the
assertion that holds it to that.

With the wide-cluster rule, each cluster is its own chunk and the row fills up:
`hello ` is six columns, so two ideographs finish the row at ten. Without it the whole
run is one chunk WIDER than the row, the row is closed at five columns, and the run is
cut into fresh rows of its own — the same clusters, one wasted third of the screen."
  (let* ((text (format nil "hello ~C~C~C~C~C~C"
                       (%ch #x4e2d) (%ch #x597d) (%ch #x4e16)
                       (%ch #x754c) (%ch #x4e2d) (%ch #x597d)))
         (texts (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l)))
                        (wrap-segments (list (cons text nil)) 10))))
    (is (= 2 (length texts)) "six columns of prose and six clusters of text in rows of ten is two rows")
    (is (string= text (apply #'concatenate 'string texts)) "and nothing is lost either way")
    (is (string= (format nil "hello ~C~C" (%ch #x4e2d) (%ch #x597d)) (first texts))
        "the row the run started on is filled to the budget, not closed early")
    (is (= 10 (string-width (first texts))) "which is exactly ten columns")))

(def-test an-over-wide-mixed-run-keeps-every-cluster (:suite leticl)
  "The same rule one level down: when a single run is wider than a whole row, the
HARD break has to be by COLUMNS over clusters too.

A run of letters is where the character-index cut looked harmless — one column is one
character — and the wide-cluster rule does not save it, because a run with ONE wide
character in it is still a single chunk: `~Cabcdefgh` is ten columns in a four-column
body, and cutting it four CHARACTERS at a time gives chunks of five, four and one
columns — each of which loses its tail at the right edge in silence."
  (let* ((mixed (format nil "~Cabcdefgh" (%ch #x4e2d)))
         (lines (wrap-segments (list (cons mixed nil)) 4))
         (texts (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))
    (is (string= mixed (apply #'concatenate 'string texts))
        "the hard break keeps every cluster")
    (dolist (row texts) (is (<= (string-width row) 4) "and every chunk is at most the budget"))
    ;; **The reference's rows, which is the point of the merge.** A wide cluster is a
    ;; break opportunity BEFORE itself and the word it precedes is then cut at the
    ;; column budget, so `中abcd` cannot share a row: the old wrapper packed it by
    ;; measured width into `中ab`/`cdef`/`gh`, which no other head agrees with.
    (is (equal (list (format nil "~C" (%ch #x4e2d)) "abcd" "efgh") texts)
        "a wide cluster counts two columns, and the run after it is cut at the budget")
    (let ((rows (%paint-lines lines 4 6)))
      (is (string= mixed (apply #'concatenate 'string
                                (subseq rows 0 (length lines))))
          "and all of it reaches the terminal"))))

(def-test a-wide-cluster-is-not-broken-in-half (:suite leticl)
  "The break opportunity is between CLUSTERS, and two code points can be one — a ZWJ
joins what follows it and two regional indicators are a flag. A guard on
`(= 2 (char-width ch))` alone splits both, which is how an emoji family renders as
three people at the right width."
  (let ((family (format nil "~C~C~C~C~C" (%ch #x1f468) leticl::+esc-zwj+ (%ch #x1f469)
                        leticl::+esc-zwj+ (%ch #x1f467)))
        (flag (format nil "~C~C" (%ch #x1f1e9) (%ch #x1f1ea))))
    ;; the assertion is on the BOUNDARIES, because that is what a wrapper produces:
    ;; a break inside the family would put its second code point on the next row, and
    ;; the terminal would draw two people where the text has one
    (dotimes (i (length family))
      (is (not (find-if (lambda (r) (and (< (cdr r) (length family))
                                         (= (cdr r) (1+ i))))
                        (wrap-ranges family 2)))
          (format nil "no row ends inside the family at index ~d" i)))
    (dotimes (i (length flag))
      (is (not (find-if (lambda (r) (and (< (cdr r) (length flag))
                                         (= (cdr r) (1+ i))))
                        (wrap-ranges flag 2)))
          (format nil "no row ends inside the flag at index ~d" i)))
    (is (= 1 (length (wrap-ranges family 2)))
        "a two-column body takes the whole family as one cluster")
    ;; and the family reaches a two-column body as ONE cluster of two columns, which
    ;; is the cell the painter can hold today: its first code point plus the
    ;; continuation marker. The rest of the sequence needs a cell that holds a
    ;; STRING, which is a struct change and is recorded in TODO.md rather than
    ;; half-done here — the point of this assertion is that the WRAPPER did not put a
    ;; break inside it.
    (let ((rows (%paint-lines (wrap-segments (list (cons family nil)) 2) 2 1)))
      (is (= 1 (length (wrap-segments (list (cons family nil)) 2)))
          "a body two columns wide wraps the family to one row")
      (is (= 2 (string-width (first rows))) "which is one cluster of two columns")
      (is (char= (%ch #x1f468) (char (first rows) 0)) "the family's own first code point"))))

(def-test a-newline-in-the-text-is-a-hard-break-and-is-not-painted (:suite leticl)
  "§2.2. `wrap-segments` had no newline rule at all, so `\\n` — which measures ZERO
columns, like a combining mark — survived into a segment and was then dropped by
`screen-put-string`'s zero-width arm (cells.lisp:248-251): two lines came back as one
reflowed blob, which is what a tool result's reason shows when its card is open and
what a system row's text showed always.

The break belongs to the row it ENDS and the character itself is never painted; a
CRLF is one break, not two."
  (flet ((texts (t2 &optional (cols 40))
           (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l)))
                   (wrap-segments (list (cons t2 nil)) cols))))
    (is (equal '("one" "two") (texts (format nil "one~%two")))
        "a newline ends the row and is not painted")
    (is (equal '("one" "two" "three") (texts (format nil "one~%two~%three")))
        "every newline is one")
    (is (equal '("one" "") (texts (format nil "one~%")))
        "a trailing newline ends the last row and paints nothing after it")
    (is (equal '("a" "") (texts (format nil "a~C~C" #\return #\newline)))
        "a CRLF is ONE break, and the CR is not painted either")
    (is (equal '("" "a") (texts (format nil "~%a"))) "a leading one starts an empty row")
    ;; the newline is a break and NOT a width problem: a long line still wraps
    (is (equal '("abc" "defgh") (texts (format nil "abc defgh") 5))
        "and ordinary wrapping still happens on either side of it")
    ;; through the painter: no newline character in any cell
    (let ((rows (%paint-lines (wrap-segments (list (cons (format nil "one~%two") nil)) 10) 10 3)))
      (is (equal '("one" "two") (subseq rows 0 2))
          "both lines are on the screen, one per row")
      (is (notany (lambda (ch) (or (char= ch #\newline) (char= ch #\return)))
                  (format nil "~{~a~}" rows))
          "and no newline character was painted into a cell"))))

(def-test the-wrap-rules-cost-nothing-on-the-prose-corpus (:suite leticl)
  "The wide-cluster and newline rules are two extra questions per character on the
frame's hot path. The same (d) corpus the docstring quotes — a 1 KB paragraph wrapped
2000 times — with the ceiling measured rather than asserted as a feeling."
  (let* ((para (with-output-to-string (o)
                 (dotimes (i 40)
                   (format o "the quick brown fox jumps over the lazy dog ~d " i))))
         (start (get-internal-real-time))
         (n 2000))
    (dotimes (i n) (wrap-segments (list (cons para nil)) 80))
    (let ((ms (/ (* 1000.0 (- (get-internal-real-time) start))
                 internal-time-units-per-second)))
      (format t "~&[wrap] ~d wraps of a 1 KB paragraph: ~,1f ms~%" n ms)
      (is (< ms 4000) "2000 wraps of a 1 KB paragraph stay well under four seconds"))))

(def-test the-viewport-blank-test-matches-the-text-it-replaced (:suite leticl)
  "`%line-blank-p` answers what `(zerop (length (string-trim \" \" (segs-text-of l))))`
did, without the copies."
  (dolist (line (list nil
                      (list (cons "" nil))
                      (list (cons "   " nil) (cons "" '(:bold t)))
                      (list (cons " " nil) (cons "x" nil))
                      (list (cons "▌" '(:fg :blue)))
                      (list (cons "  " nil) (cons "  " nil))))
    (is (eq (zerop (length (string-trim " " (leticl::segs-text-of line))))
            (and (leticl::%line-blank-p line) t))
        (format nil "~s" line))))

(def-test a-nil-text-is-still-an-empty-row-not-a-render-failure (:suite leticl)
  "A wire plist with a key missing puts NIL in a segment (`secret-card-lines`
and `(getf req :command)`). `clusters` took `(length nil)` and drew nothing; the
typed entries must keep that, or a missing key becomes a red frame."
  (is (= 0 (string-width nil)) "NIL measures zero")
  (is (null (clusters nil)) "and has no clusters")
  (let ((s (make-screen 10 1)))
    (is (= 3 (screen-put-string s 0 3 nil)) "and places nothing, returning the column it was given")
    (is (char= #\space (cell-ch (screen-cell s 0 3))) "with the cell untouched"))
  (is (null (wrap-segments nil 10)) "no segments, no rows")
  (is (null (wrap-segments (list (cons nil '(:dim t))) 10)) "and wraps to no rows"))

;;; ------------------------------ two things the profile's hot loop showed ;;;

(def-test an-over-wide-word-breaks-one-chunk-per-row (:suite leticl)
  "`%hard-break`'s docstring: *a 400-column URL wraps, it does not overflow*. The
chunks were all pushed onto ONE row and broken once, so it did overflow — found
while typing the loop, not on the screen, which is why it had lived."
  (let* ((url (format nil "https://example.com/~a" (make-string 100 :initial-element #\x)))
         (lines (wrap-segments (list (cons url nil)) 30)))
    (is (= 4 (length lines)) "120 columns at 30 is four rows")
    (is (every (lambda (l) (<= (leticl::%segs-width l) 30)) lines) "none wider than the width")
    (is (string= url (format nil "~{~a~}" (mapcar (lambda (l) (car (first l))) lines)))
        "and nothing lost")))

(def-test the-attach-wait-is-drawn-while-the-daemon-has-not-answered (:suite leticl)
  "The walking cat: its clause in `%render` sat behind a `(t …)` and the compiler
deleted it, so a head attaching to a two-thousand-item session drew an EMPTY
screen — indistinguishable from a head on the wrong socket — for the whole wait."
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 60 :rows 20))
         (leticl::*attach-started-ms* (- (internal-real-time-ms) 3000)))
    ;; CONNECTED is about the socket and is T from before the first paint —
    ;; `%send` refuses to write while disconnected and the ATTACH is the first
    ;; frame — so the wait keys on the CLOCK, which the `hello` arm clears. Ours
    ;; required `(not connected)` and the cat therefore never drew at all.
    (setf (head-connected h) t)
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "asking the daemon for this session" text)
          "the wait is on the screen while nothing has arrived, connected or not")
      (is (search "the daemon has not answered. ctrl-c twice, or wait" text)
          "and past the impatient mark it says how to get out"))
    (setf leticl::*attach-started-ms* nil)
    (leticl::%render h)
    (is (not (search "asking the daemon" (%screen-text h)))
        "and gone once the hello has landed")))

;;; ------------------------ a slash listing opens a pane (§2.4) ------------- ;;;
;;;
;;; The operator: *"12. A slash listing scrolls past instead of opening a pane. (G10)
;;; First /gate recent, /tools or /models."* A reply that is a LISTING has to be
;;; scrollable; a reply that is a sentence stays a note. The daemon sends both under one
;;; warning code, so `detail` — the command echoed back, a newline, then the reply — is
;;; the only thing that says which, and length is what splits them (app.rs:3266-3275).

(defun %slash-warning (detail &optional (code "slash"))
  "The FRAME the daemon publishes a slash reply as — a full event envelope.

Fed through `%handle-frame` rather than `apply-event`, because that is the operator's
path: the session folds the reply and the HEAD is what puts the pane up, so a test that
called the fold directly would be asserting half the mechanism (it did, and failed)."
  (list :frame "event" :seq 1 :event "warning" :code code :detail detail :ts 0))

(defun %slash-detail (echo &rest lines)
  "A reply's `detail`: ECHO, a newline, and LINES — the daemon's own format."
  (format nil "~a~%~{~a~^~%~}" echo lines))

(def-test a-long-slash-reply-opens-a-scrollable-pane (:suite leticl)
  "The criterion: `/gate recent`, `/tools`, `/flowy status` and `/models` open a screen
with the whole reply on it, the echo bold at the top and the keys that work at the
bottom.

The four verbs are the operator's own list, and they all reach the head the same way —
a `Warning` code `slash` whose detail is the command, a newline, then the reply — so one
test covers them and the count of lines is the only thing that differs."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (h (%on-head :cols 60 :rows 20)))
    ;; --- a LISTING opens a pane
    (leticl::%handle-frame h
                 (%slash-warning
                  (%slash-detail "/tools"
                                 "read        failed   1.2s   read a file"
                                 "glob        ok       0.3s   find by pattern"
                                 "grep        ok       0.4s   search contents"
                                 "bash        ok       2.1s   run a command"
                                 "task        declined 0.0s   spawn a subagent")))
    (is (not (null *slash-out*)) "a five-line reply opens the listing")
    (is (equal "/tools" (car *slash-out*)) "the echo is kept")
    (is (= 5 (length (cdr *slash-out*))) "and the five body lines")
    ;; --- and the pane draws it: bold echo, blank, wrapped body, the key row
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "/tools" text) "the command it is answering")
      (is (search "read" text) "and the reply")
      (is (search "task" text) "all of it, including the last line")
      (is (search "esc closes · up/down scrolls" text)
          "with the keys that work named under it"))
    ;; the footer is the one place a pane says what its keys do, so assert it is the
    ;; LAST content row rather than anywhere on the screen
    (let* ((lines (slash-out-lines h 60))
           (footer (car (last (remove-if #'null lines)))))
      (is (search "esc closes" (format nil "~{~a~}" (mapcar #'car footer)))
          "and it is the last row of the listing"))
    ;; --- a SENTENCE stays a note
    (setf *slash-out* nil)
    (leticl::%handle-frame h (%slash-warning "mode → allow-all"))
    (is (null *slash-out*) "a one-line reply does not open a pane")
    ;; --- and the boundary, which is the reference's `> 3`
    (setf (session-warnings (head-session h)) nil)
    (leticl::%handle-frame h
                 (%slash-warning (%slash-detail "/x" "one" "two" "three")))
    (is (null *slash-out*) "three lines is still a note — the split is `> 3`")
    (leticl::%handle-frame h
                 (%slash-warning (%slash-detail "/x" "one" "two" "three" "four")))
    (is (not (null *slash-out*)) "and four lines is a listing")))

(def-test a-slash-listing-keeps-its-text-on-the-screen (:suite leticl)
  "**A listing that opened and then scrolled away is the defect with extra steps.**

The reply is a LISTING and it has to be reachable to its end, which is the same claim the
payload window makes and for the same reason: the operator's `/gate recent` is how they
learn what the gate decided, and a pane that shows its first screenful and no more is a
screen they have to close and re-ask for."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (h (%on-head :cols 60 :rows 20)))
    (leticl::%handle-frame h
                 (%slash-warning
                  (%slash-detail "/gate recent"
                                 (loop for i from 1 to 40 collect (format nil "row ~d of the gate log" i)))))
    (leticl::%render h)
    (is (search "row 1 of the gate log" (%screen-text h)) "the listing starts at its top")
    (is (not (search "row 40 of the gate log" (%screen-text h)))
        "and forty rows do not fit on a twenty-row screen — the premise")
    ;; the pane's total is what the scroll clamps against, and the arrows walk it
    (is (> *pane-lines* 20) "the pane knows how many rows it has")
    (let ((first *pane-scroll*))
      (loop repeat 6 do (leticl::%handle-key h (list :type :page-down))
            until (>= *pane-scroll* (pane-scroll-max)))
      (is (> *pane-scroll* first) "page-down scrolls the listing forward")
      (leticl::%render h)
      (is (search "row 40 of the gate log" (%screen-text h))
          "to the last row of the reply"))
    (loop repeat 40 do (leticl::%handle-key h (list :type :page-up)))
    (is (zerop *pane-scroll*) "and page-up comes back to the top")))

(def-test a-slash-listing-owns-esc-and-the-arrows-and-nothing-else (:suite leticl)
  "The pane is up, so Esc closes it and the arrows scroll it — and a character still
reaches the composer, which is the rule every pane here keeps (`%pane-key`'s own
docstring: *\"a pane open was a head you could not talk to\"*)."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (*esc-at* nil) (*ctrlc-at* nil) (*pick-open* nil) (*mode-confirm* nil)
        (h (%on-head :cols 60 :rows 20)))
    (leticl::%handle-frame h
                 (%slash-warning (%slash-detail "/tools" "a" "b" "c" "d")))
    (is (eq :slash (head-mode h)) "the reply put the pane up")
    ;; the arrows scroll rather than walking a cursor
    (setf *pane-lines* 40 *pane-room* 10)
    (leticl::%handle-key h (list :type :down))
    (is (= 1 *pane-scroll*) "down scrolls the listing")
    (leticl::%handle-key h (list :type :up))
    (is (zerop *pane-scroll*) "and up comes back")
    ;; a letter is still the composer's
    (leticl::%handle-key h (list :type :char :ch #\z))
    (is (string= "z" (composer-buffer (head-composer h)))
        "a letter typed under the pane reaches the composer")
    ;; esc closes it, and closes NOTHING else
    (leticl::%handle-key h (list :type :esc))
    (is (null *slash-out*) "esc closes the listing")
    (is (eq :normal (head-mode h)) "and leaves nothing on the screen")
    (is (null *esc-at*) "and does not arm the interrupt")))

(def-test ctrl-c-closes-a-slash-listing (:suite leticl)
  "`ctrl-c` closes whatever list is on the screen, exactly as Esc does — and the listing
is a list. This is G11's own bug one pane over: an unhandled arm fell through and offered
to quit the head instead of closing the thing in front of the operator."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*ctrlc-at* nil) (*pick-open* nil)
        (*mode-confirm* nil) (h (%on-head :cols 80 :rows 24)))
    (leticl::%handle-frame h
                 (%slash-warning (%slash-detail "/gate recent" "a" "b" "c" "d")))
    (is (eq :slash (head-mode h)) "the pane is up")
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (null *slash-out*) "ctrl-c closes it")
    (is (eq :normal (head-mode h)) "and nothing is left on the screen")
    (is (not (head-quit-open h)) "and it does not offer to leave")))

(def-test a-listing-does-not-survive-a-session-switch (:suite leticl)
  "A reply belongs to the session it was asked in. Carried across a `/switch` it is
another session's `/tools` on this screen, which is worse than a stale job row: it looks
like an answer to something nobody asked here."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pick-open* nil) (*mode-confirm* nil)
        (h (%on-head :cols 80 :rows 24)))
    (setf (session-session-id (head-session h)) "s-1")
    (leticl::%handle-frame h
                 (%slash-warning (%slash-detail "/tools" "a" "b" "c" "d")))
    (is (eq :slash (head-mode h)) "the pane is up")
    ;; a Hello for a DIFFERENT session
    (leticl::%handle-frame h (list :frame "hello" :protocol-version 22
                                   :session-id "s-2" :snapshot nil :sessions nil
                                   :wiring nil))
    (is (null *slash-out*) "the listing is gone")
    (is (eq :normal (head-mode h)) "and the screen is the conversation again")))

(def-test a-slash-reply-is-not-said-twice (:suite leticl)
  "A listing that opened a pane is ON a screen; pushing it into the warnings list as well
is the same text twice, three lines apart — the shape `turn_failed` already avoids. A
SENTENCE is still a note, because a note is all there is."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pick-open* nil) (*mode-confirm* nil)
        (h (%on-head :cols 80 :rows 24))
        (s nil))
    (setf s (head-session h))
    (setf (session-warnings s) nil)
    (leticl::%handle-frame h (%slash-warning (%slash-detail "/tools" "a" "b" "c" "d")))
    (is (eq :slash (head-mode h)) "the listing opened")
    (is (null (session-warnings s)) "and the warning was consumed, not also noted")
    ;; a sentence still lands in the log
    (leticl::%handle-frame h (%slash-warning "mode → allow-all"))
    (is (= 1 (length (session-warnings s))) "a one-line reply is still a note")
    (is (equal "slash" (getf (first (session-warnings s)) :code))
        "with its code, so /status can count it")
    ;; and a REFUSED listing opens the same pane — the same code's other spelling
    (setf *slash-out* nil)
    (leticl::%handle-frame h (%slash-warning (%slash-detail "/gate grant 7" "not yours" "and" "four"
                                                   "lines") "slash_refused"))
    (is (eq :slash (head-mode h)) "a refused listing opens it too")))

;;; ----------------------- a warning is a DISCLOSURE (R10) ------------------- ;;;
;;;
;;; The operator's own measurement is the specification: *"a warning envelope arrives,
;;; session-warnings goes from 9 to 10, and it is visible NOWHERE — not a row, not a
;;; note, not a counter, not the alarm. So auto_compact, compacted, context_wall,
;;; transcript_store, decision_corpus and mode_set have never once reached this head."*
;;; Both halves of the rule are asserted here: it is DRAWN where it arrived, and a
;;; warning the reader has retired STAYS retired across the two events that used to
;;; replant it — a resync and a reattach — while never leaving the record.

;;; ---------------- R24: a compaction is a tool call ------------------------------- ;;;
;;;
;;; Ruled by the operator, 2026-09-22: *"make compaction a tool call. this will mean that
;;; i can have stats in the headline and Ct will expand to details as usual."*
;;;
;;; A compaction arrives as a WARNING today — the one shape on the screen with no
;;; affordances. It cannot be folded, `ctrl-t` does nothing to it, its numbers are buried
;;; in prose, and it competes for the note band with denials. A tool row already has every
;;; one of those.
;;;
;;; **The sentences below are letibot's own**, out of the `format!` calls in
;;; `crates/harnessd/src/sessions.rs`, and
;;; `every-compaction-sentence-this-head-parses-is-still-the-one-letibot-writes` reads that
;;; file and fails if one of them moves.

(defparameter +letibot-compacted+
  "compacted: 941290 → 9449 tokens, on transcript s-1789639478142928813#t15."
  "letibot `sessions.rs`, `compaction_said`: the account a compaction leaves behind.")

(defparameter +letibot-compacting+
  (format nil "938669 of 999999 tokens resident, leaving less than the 62499 the next ~
               turn needs — compacting now, as one more message so the prefix the ~
               server already holds is reused. This is the wall, not a judgement about ~
               the conversation.")
  "The announcement, published BEFORE the compaction runs, from the same code.")

(defparameter +letibot-no-progress+
  (format nil "compacted from 943000 to 940000 tokens and that is STILL within 62499 ~
               of the 999999 window, so automatic compaction is now off for this ~
               session rather than looping once per turn. The summary itself is near ~
               the wall: start a fresh session, or raise --context-window if the ~
               server really has more.")
  "A compaction that ran and did not help.")

(defparameter +letibot-with-summary+
  (format nil "compacted: 941290 → 9449 tokens, on transcript s-1#t15. Nothing of the ~
               summary turn reached this screen — it ran over a scratch transcript — so ~
               here is what the model now reads in place of everything before it:~%~%~
               The session built a parity harness. The operator asked for a head that ~
               draws both sides the same way, and the work went out in stages: first ~
               the frame, then the cards, then the width rules.~%~%~
               What is left is the daemon's half of the fetch row.")
  "The account whose payload is a WHOLE SUMMARY — the case `ctrl-t` exists for.")

(defparameter +letibot-reseated+
  (format nil "re-seated: 8703 tokens of conversation carried onto the new prompt as ~
               they are, on transcript s-1#t2. Nothing was summarised and nothing was ~
               dropped.")
  "The re-seat branch of the same function: nothing was summarised.")

(defparameter +letibot-compacted-cut+
  "compacted: 9449 tokens resident now, was 938669. The summary was CUT OFF at the model's length limit — it is incomplete, and the base says so too."
  "The post-fork re-measure, with the truncation sentence.")

(defun %collapse-rust-continuations (source)
  "SOURCE with Rust's string continuations collapsed — a `\\` at end of line, the newline,
and the next line's leading whitespace become nothing.

**This is what the compiler does**, so it is what has to be searched: letibot splits a
long format string across lines, and a guard searching the raw file would be looking for
a sentence that is not on any one of them."
  (let ((out (make-string-output-stream))
        (i 0))
    (loop while (< i (length source))
          do (let ((ch (char source i)))
               (if (and (char= ch #\\)
                        (< (1+ i) (length source))
                        (member (char source (1+ i)) '(#\newline #\return)))
                   (progn
                     (incf i 2)
                     (loop while (and (< i (length source))
                                      (member (char source i) '(#\space #\tab #\newline #\return)))
                           do (incf i)))
                   (progn (write-char ch out) (incf i)))))
    (get-output-stream-string out)))

(defun %compaction-rows (h)
  "The compaction rows in HEAD's transcript, oldest first."
  (loop for i across (session-items (head-session h))
        when (getf i :compaction) collect i))

(defun %note-rows (h)
  "The rows still filed as NOTES — head-filed rows carrying `:warning`."
  (loop for i across (session-items (head-session h))
        when (getf i :warning) collect i))

(defun %row-headline (h row)
  "ROW's first drawn line: the headline a person reads."
  (first (%pane-text (item-lines row 150 (head-prefs h)))))

(defun %row-text (h row)
  "EVERY line ROW draws, joined — the headline and its payload together."
  (format nil "~{~a~%~}" (%pane-text (item-lines row 150 (head-prefs h)))))

(defun %compaction-head (h &optional (nth 0))
  "The headline of the Nth compaction row (0 = the oldest)."
  (let ((row (nth nth (%compaction-rows h))))
    (and row (%row-headline h row))))

(def-test a-compaction-says-what-it-did-in-numbers (:suite leticl)
  "**R24's extraction, one case per sentence the daemon writes.**

The numbers are IN the prose and a headline needs them as numbers, so this reads the
sentences letibot writes. That is the one assumption in the whole change, and it is made
by a function whose failure mode is `NIL` — which means *a note again*, never a row with
invented numbers."
  (let ((f (compaction-facts +letibot-compacted+)))
    (is (eq :compacted (getf f :kind)) "the account reads as a compaction")
    (is (= 941290 (getf f :was)) "with the size it was")
    (is (= 9449 (getf f :after)) "and the size it left")
    (is (equal "s-1789639478142928813#t15" (getf f :transcript))
        "**and the transcript the summary landed on** — the row can name it"))
  (let ((f (compaction-facts +letibot-compacting+)))
    (is (eq :compacting (getf f :kind))
        "**the announcement is not mistaken for the report** — same code, other sentence")
    (is (= 938669 (getf f :resident)) "it carries what is resident")
    (is (= 999999 (getf f :window)) "and the window, the number that makes it a wall")
    (is (= 62499 (getf f :headroom)) "and the headroom the next turn needs"))
  (let ((f (compaction-facts +letibot-no-progress+)))
    (is (eq :no-progress (getf f :kind)) "a compaction that did not help is its own kind")
    (is (= 943000 (getf f :was)) "with both numbers")
    (is (= 940000 (getf f :after))))
  (let ((f (compaction-facts +letibot-compacted-cut+)))
    (is (eq :compacted (getf f :kind)) "the post-fork re-measure is a compaction report")
    (is (= 938669 (getf f :was))
        "**and its numbers run the other way in the sentence** (`A resident now, was W`) —
read correctly rather than assumed")
    (is (= 9449 (getf f :after)))
    (is (null (getf f :transcript)) "and it invents no transcript it was not told"))
  (let ((f (compaction-facts +letibot-reseated+)))
    (is (eq :reseat (getf f :kind)) "the re-seat branch is its own kind")
    (is (= 8703 (getf f :tokens)) "carrying its token count"))
  (is (eq :failed (getf (compaction-facts "the automatic compaction did not run: nope.")
                        :kind))
      "and a failure with no numbers in it still classifies")
  ;; **the fallback, which is the safety property**
  (is (null (compaction-facts "compacted: a hundred and twelve tokens")) "a reword gives NIL")
  (is (null (compaction-facts "")) "and so does nothing at all")
  (is (null (compaction-facts nil)) "and an absent detail"))

(def-test a-compaction-is-a-tool-row-with-the-numbers-in-its-headline (:suite leticl)
  "**The operator's ask, on the rendered row.** *\"i can have stats in the headline and Ct
will expand to details as usual\"* — so the headline carries `941,290 → 9,449 tokens`, and
the daemon's own sentence is the payload.

**And it is a `tool_result` row**, which is what buys the affordances: the fold, the
payload pager, the `… +N lines` seam, the sanitiser, and a row that scrolls with the
conversation rather than stacking above the composer."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 120 :rows 30)))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "compacted" :detail +letibot-compacted+ :ts 4))
    (let ((row (first (%compaction-rows h))))
      (is (not (null row)) "the compaction was filed as a row")
      (is (equal "tool_result" (getf (leticl::item-body row) :type))
          "**as a TOOL ROW**, which is what carries the affordances")
      (is (equal "compact" (getf (leticl::item-body row) :name)) "named as the tool it is")
      (is (equal +letibot-compacted+ (getf (leticl::item-body row) :payload))
          "and the daemon's own sentence is its payload, whole")
      (is (equal "ok" (getf (getf (leticl::item-body row) :outcome) :outcome)) "reported ok")
      (is (equal (format nil "~:d → ~:d tokens" 941290 9449)
                 (getf (leticl::item-body row) :subject))
          "**the subject is the stats**, the shape the ruling asked for")
      (is (equal "Compacted" (getf (leticl::item-body row) :verb)) "and the verb says what happened"))
    (let ((head (%compaction-head h)))
      (is (search "941,290 → 9,449 tokens" head)
          "**THE HEADLINE CARRIES THE NUMBERS** — `939,708 → 8,703 tokens` is the shape
that was asked for, and this is that row with this compaction's numbers: ~s" head)
      (is (search "Compacted" head) "with the verb in front of them: ~s" head))
    ;; **a ONE-LINE payload has nothing hidden, so there is no chord and no seam.**
    ;; That is the same rule every other seam keeps: a `… +N lines · ctrl-t` on a row
    ;; with nothing behind it names a chord that reveals nothing.
    (is (null (leticl::payload-view-seed (head-session h)))
        "one line: nothing to fold, so nothing to open")))

(def-test a-compaction-that-carried-a-summary-is-pageable-by-ctrl-t (:suite leticl)
  "**The other half of the ask: `Ctrl` expands to details — and there are details.**

A compaction that ran over a scratch transcript carries the WHOLE SUMMARY as its payload,
because nothing of that summary turn reached the screen. That is the case the affordance
exists for, and this asserts the three parts of it: the row is *already* the transcript's
own, the pager finds it, and the fold opens the summary rather than one sentence of it."
  (let ((*slash-out* nil) (*job-out* nil)
        ;; **the pager's offset is a global**, so seeding one is state a later test can
        ;; see. Bound here rather than cleaned up after, because a `let` survives an
        ;; assertion that fails — and this file has been bitten by exactly that.
        (*payload-view* nil)
        (h (%on-head :cols 120 :rows 30)))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "compacted" :detail +letibot-with-summary+ :ts 4))
    (let* ((row (first (%compaction-rows h)))
           (body (leticl::item-body row)))
      (is (search "941,290 → 9,449 tokens" (getf body :subject))
          "the headline is still the numbers")
      (is (> (length (leticl::%tool-payload-rows body)) leticl::+payload-pageable-lines+)
          "**and the payload is longer than a fold's worth** — the summary is in there")
      ;; the pager seeds on THIS row, by its own item id
      (is (equal (getf row :item-id) (car (leticl::payload-view-seed (head-session h))))
          "**`ctrl-t` opens this row** and seeds on it by item id")
      ;; **and `ctrl-t` ON THIS ROW opens it** — the real chord, through the real
      ;; handler, and not a `setf`: a seam that names a key the composer swallows is
      ;; the lie this repo keeps finding. The chord does two things and this asserts
      ;; both, because either alone is a half-measure — it opens the FOLD (which is
      ;; what decides whether a payload is drawn at all) and it seeds the window on
      ;; the newest pageable row, which is this one.
      (leticl::%handle-key h (list :type :ctrl :ch #\t))
      (let ((text (%row-text h row)))
        (is (search "parity harness" text)
            "**`Ctrl` expands to the details, and the details are what the model now
reads** — the whole summary is drawn on the row: ~s" text)
        (is (search "941,290 → 9,449 tokens" text)
            "with the stats still on the headline above it")))))

(def-test a-compaction-is-not-a-note-and-the-band-goes-back-to-its-job (:suite leticl)
  "**The collapse, which is a better fix for R19's wall than dismissing it.**

Three of the four notes the operator was met by on restart were `compacted` and
`auto_compact`. As rows they stop being notes AT ALL: not in `session-warnings`, so
`/notes` does not list them and `/status` does not count them, and the retired set has
nothing to hold. The band goes back to what R10 says it is — *how a head shows a fact
once*, for facts with nowhere else to live."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 120 :rows 30)))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "compacted" :detail +letibot-compacted+ :ts 4))
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "warning"
                                   :code "auto_compact" :detail +letibot-compacting+ :ts 5))
    (is (= 2 (length (%compaction-rows h))) "two compactions, two rows")
    (is (null (%note-rows h)) "and NOT ONE of them is a note row")
    (is (null (session-warnings (head-session h)))
        "**nothing entered the record `/notes` reads**")
    (is (null (session-retired (head-session h))) "and the retired set has nothing to hold")
    (multiple-value-bind (held retired) (warning-counts (head-session h))
      (is (zerop held) "`/status` has no note to count")
      (is (zerop retired) "and none retired"))
    ;; **AND A REAL NOTE IN THE SAME HEAD IS UNTOUCHED**
    (leticl::%handle-frame h (list :frame "event" :seq 3 :event "warning"
                                   :code "context_wall"
                                   :detail "stopping this turn after 41 round(s)"
                                   :ts 6))
    (is (= 1 (length (session-warnings (head-session h))))
        "a real note still lands in the record")
    (is (= 1 (length (%note-rows h))) "and is still a note row")
    (is (= 2 (length (%compaction-rows h))) "with the two compaction rows beside it")
    ;; and the row is IN the transcript, which is what "scrolls with the conversation"
    ;; means — the note band is drawn separately from it
    (is (eq (first (%compaction-rows h))
            (loop for i across (session-items (head-session h))
                  when (getf i :compaction) return i))
        "the row is an item of the transcript, in arrival order")))

(def-test the-wall-is-a-note-and-the-announcement-is-a-row (:suite leticl)
  "**`context_wall` ruled separately, as the requirement demanded — and it stays a note.**

Three reasons, and the first decides it. **It is terminal in the cases where nothing
follows**: it is published when the turn hits the wall, and then a compaction may be
skipped (automatic compaction off for the session), may fail, or may never fire — so a
fact that is *sometimes* the compaction's reason and *sometimes* the only sentence there
is must be a fact in its own right, or the case where nothing compacted is the case that
says nothing. That is R17's rule again: a disclosure conditional on a later event is a
disclosure that does not happen.

It is also a **failure** — a turn that stopped before it finished — so the failure
register is where it belongs; and its numbers are already on the announcement's row, so
folding it in would print one measurement twice.

**The line is ATTEMPTED.** A code reporting a compaction somebody tried is a row; a code
reporting one nobody tried is a note."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 120 :rows 30)))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "context_wall"
                                   :detail (format nil "stopping this turn after 41 ~
                                                        round(s): 938669 of 999999 ~
                                                        tokens are resident")
                                   :ts 1))
    (is (= 1 (length (%note-rows h))) "**the wall is a NOTE**")
    (is (null (%compaction-rows h)) "and not a compaction row")
    (is (equal "context_wall" (getf (first (session-warnings (head-session h))) :code))
        "in the record, where `/notes` finds it")
    (is (not (routine-warning-p (list :code "context_wall")))
        "and in the FAILURE register, which is where a stopped turn belongs")
    ;; the announcement: a row, because the compaction WAS attempted
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "warning"
                                   :code "auto_compact" :detail +letibot-compacting+ :ts 2))
    (is (= 1 (length (%compaction-rows h))) "**the announcement is a ROW**")
    (is (equal "Compacting" (getf (leticl::item-body (first (%compaction-rows h))) :verb))
        "saying it is happening, not that it happened")
    (is (search "938,669 of 999,999 tokens" (%compaction-head h))
        "with the wall's own numbers on the headline: ~s" (%compaction-head h))
    ;; skipped: nothing was attempted, so there is nothing to report
    (leticl::%handle-frame h (list :frame "event" :seq 3 :event "warning"
                                   :code "auto_compact_skipped"
                                   :detail (format nil "the turn stopped at the context ~
                                                        wall and nothing was compacted: ~
                                                        automatic compaction is off for ~
                                                        this session")
                                   :ts 3))
    (is (= 2 (length (%note-rows h)))
        "**a compaction that was never attempted stays a note** — there is nothing to report")
    (is (= 1 (length (%compaction-rows h))) "and files no row")
    ;; failed: an attempt, so a row — and it says failed
    (leticl::%handle-frame h (list :frame "event" :seq 4 :event "warning"
                                   :code "auto_compact_failed"
                                   :detail (format nil "the automatic compaction did ~
                                                        not run: the store is ~
                                                        read-only. The turn you asked ~
                                                        for succeeded")
                                   :ts 4))
    (is (= 2 (length (%compaction-rows h))) "an attempted-and-failed compaction IS a row")
    (let ((row (second (%compaction-rows h))))
      (is (equal "failed" (getf (getf (leticl::item-body row) :outcome) :outcome))
          "carrying a failed outcome, so it draws in the failure register")
      (is (search "FAILED" (string-upcase (%row-headline h row)))
          "**and the row says so on the glass** — a compaction that did not run is not a
success: ~s" (%row-headline h row)))))

(def-test a-resync-plants-a-compaction-in-the-same-shape-the-turn-did (:suite leticl)
  "**The other path, and the one that would have drifted.**

A snapshot's warnings are the daemon's own log, so they carry the compaction codes even
though the live path never stores them. A resync replaces the transcript, so the rows go
with it — and they have to come back as ROWS, or the same fact has two renderings
depending on when it arrived.

**And it comes out of `session-warnings` on the way through**, because that list is what
`/notes` lists and `/status` counts: a compaction left in it would be a row that is also a
note, which is the thing R24 is getting rid of."
  (let ((*slash-out* nil) (*job-out* nil)
        (*snapshotted-sessions* nil) (h (%on-head :cols 120 :rows 30)))
    (flet ((snap (seq)
             (list :frame "resync" :reason "auto-compaction" :dropped 0 :scrubbed nil
                   :snapshot (list :session-id "s-r24" :seq seq :dropped 0 :items-dropped 0
                                   :items nil :turn nil :open-decisions nil
                                   :settled-decisions nil :heads nil
                                   :warnings (list (list :code "compacted"
                                                         :detail +letibot-compacted+ :ts 4)
                                                   (list :code "context_wall"
                                                         :detail "stopping this turn" :ts 5))))))
      ;; a HELLO first, so the resync below is a reattach and not an attach
      (leticl::%handle-frame
       h (list :frame "hello" :protocol-version 23 :session-id "s-r24" :head-id "h1"
               :dropped 0 :sessions nil :wiring nil :resumed-from nil :scrubbed nil
               :snapshot (list :session-id "s-r24" :seq 899 :dropped 0 :items-dropped 0
                               :items nil :turn nil :open-decisions nil
                               :settled-decisions nil :heads nil :warnings nil)))
      (is (null (%compaction-rows h)) "the attach plants nothing (R19)")
      (leticl::%handle-frame h (snap 901))
      (is (= 1 (length (%compaction-rows h)))
          "**a RESYNC replants the compaction as a ROW** (R10's rule, R24's shape)")
      (is (equal "tool_result" (getf (leticl::item-body (first (%compaction-rows h))) :type))
          "in the same shape the live path files")
      (is (search "941,290 → 9,449 tokens" (%compaction-head h))
          "with the numbers in its headline: ~s" (%compaction-head h))
      (is (= 1 (length (session-warnings (head-session h))))
          "**and only the real note is left in the record**")
      (is (equal "context_wall" (getf (first (session-warnings (head-session h))) :code))
          "which is the wall, and it is a note")
      (is (= 1 (length (%note-rows h))) "filed as one"))))

(def-test a-compaction-whose-words-this-head-cannot-read-is-a-note-again (:suite leticl)
  "**The safety property, and what makes the extraction acceptable.**

The parsing is a bridge — the numbers want to be fields, and the ask is filed. What makes
a bridge safe is that its failure is BORING: a detail this head cannot read falls through
to the note it always was, so a reword on the daemon's side costs the affordances and
never the fact. *A test that cannot fail guards nothing*, and its cousin: a fallback that
has never been exercised is not a fallback."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 120 :rows 30)))
    (is (null (compaction-row-p (list :code "compacted" :detail "compacted: lots"))))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "compacted"
                                   :detail "compacted: a hundred and twelve tokens, roughly"
                                   :ts 1))
    (is (null (%compaction-rows h)) "no row: this head cannot read that sentence")
    (is (= 1 (length (%note-rows h)))
        "**so it is a note, which is what it was before R24** — the fact is never lost")
    (is (= 1 (length (session-warnings (head-session h)))) "in the record")
    (leticl::%render h)
    (is (search "a hundred and twelve tokens" (%screen-text h))
        "and it is on the screen, as a note")))

(def-test every-compaction-sentence-this-head-parses-is-still-the-one-letibot-writes (:suite leticl)
  "**The assumption, CHECKED rather than believed** — §11.5's shape a third time.

`compaction-facts` reads letibot's sentences, and they live in
`crates/harnessd/src/sessions.rs`. A reword there would silently turn every compaction
back into a note — quiet, correct-looking, and the headline gone. So this reads that file
and fails when a format string the parser keys on moves.

**Rust splits a long format string across lines with a `\\` continuation**, which strips
the newline and the next line's leading whitespace, so the source is collapsed the way the
compiler does before anything is searched for. A guard that searched the raw file would
pass on a string that only LOOKS right."
  (let* ((path "/home/dead/Projects/letibot/letibot/crates/harnessd/src/sessions.rs")
         (raw (and (probe-file path) (uiop:read-file-string path)))
         (src (and raw (%collapse-rust-continuations raw))))
    (if (null src)
        (skip "letibot's sessions.rs is not on this box")
        (progn
          (is (> (length src) 10000)
              "**a plausible source, so a bad read cannot pass vacuously** — ~d bytes"
              (length src))
          (dolist (marker '("compacted: {} → {} tokens, on transcript {}."
                            "re-seated: {} tokens of conversation carried"
                            "tokens resident, leaving less than the "
                            "tokens and that is STILL within "
                            "compacted: {after} tokens resident now, was {resident}."
                            "the automatic compaction did not run"))
            (is (search marker src)
                (format nil "**letibot still writes `~a`** — the sentence this head reads
the facts on a compaction row from. If it moved, `compaction-facts` moves with it; until
then every compaction is a note again." marker)))))))

(defun %warning-frame (code detail &optional (ts 0))
  "The frame the daemon publishes a warning as — a full event envelope."
  (list :frame "event" :seq 1 :event "warning" :code code :detail detail :ts ts))

(defun %warning-rows (h)
  "The warning rows in HEAD's transcript, oldest first."
  (loop for item across (session-items (head-session h))
        when (getf item :warning) collect item))

(defun %list-text (lines)
  "A listing's strings joined, for asserting on."
  (format nil "~{~a~^~%~}" lines))

;;; -------------------- R19: a fresh attach does not open with old news ------------- ;;;
;;;
;;; RULED by the operator, 2026-09-22, on restarting a head and being met by twelve red
;;; lines: *"i dont want to see that on restart."*
;;;
;;;     daemon_stopping · compacted · auto_compact · auto_compact
;;;
;;; four notes, folded correctly to three lines each, in the failure colour, at the top
;;; of a session that had just started. NONE had been dismissed, so persisting a retired
;;; set would not have helped on its own: a fresh head planted its snapshot's warnings at
;;; position 0 because everything in a snapshot is history and none of it is anchored.
;;;
;;; Three faults, and only the first is what was asked about. Each has its test here.

(defun %snapshot-with-warnings (warnings &key (session-id "s-r19") (seq 900))
  "A snapshot carrying WARNINGS, in the shape `ingest-snapshot` reads."
  (list :session-id session-id :seq seq :dropped 0 :items-dropped 0 :items nil
        :turn nil :open-decisions nil :settled-decisions nil :heads nil
        :warnings warnings))

(def-test an-attach-does-not-open-with-the-snapshots-warnings (:suite leticl)
  "**R19 part 1, and it is the fault that was actually reported.**

A warning is how a head shows a fact ONCE. A head that has just attached has shown
nothing — so filing the snapshot's warnings replays hours of announcements as though they
had just happened, above a conversation they did not precede. The four the operator saw
were `daemon_stopping`, `compacted` and two `auto_compact`.

They are not lost, and that is the half that makes this a fix rather than a silence: they
stay in `session-warnings`, so `/notes` lists them with their whole text and `/status`
counts them. **The log keeps them; the head does not have to open with them.**"
  (let ((*slash-out* nil) (*job-out* nil)
        (*snapshotted-sessions* nil)
        (h (%on-head :cols 96 :rows 24)))
    (leticl::%handle-frame
     h (list :frame "hello" :protocol-version 23 :session-id "s-r19" :head-id "h1"
             :dropped 0 :sessions nil :wiring nil :resumed-from nil :scrubbed nil
             :snapshot (%snapshot-with-warnings
                        (list (list :code "daemon_stopping" :detail "someone asked me to stop" :ts 1)
                              (list :code "compacted" :detail "12 rows folded" :ts 2)
                              (list :code "auto_compact" :detail "240 rows folded" :ts 3)
                              (list :code "auto_compact" :detail "260 rows folded" :ts 4)))))
    (is (= 4 (length (session-warnings (head-session h))))
        "all four are in the record — the log keeps them")
    (is (null (%warning-rows h))
        "**AND NOT ONE IS A ROW** — this is the twelve red lines: ~s"
        (mapcar (lambda (i) (getf (leticl::item-body i) :text)) (%warning-rows h)))
    (leticl::%render h)
    (is (not (search "240 rows folded" (%screen-text h)))
        "nothing from before the attach is on the screen")
    ;; reachable, which is the other half of the requirement
    (let ((text (%list-text (warning-listing-lines (head-session h)))))
      (is (search "4 warnings, 0 retired" text) "`/notes` lists them: ~s" text)
      (is (search "240 rows folded" text) "with their whole text"))
    ;; and the FIRST LIVE warning after the attach IS a row: it is news
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full" 9))
    (is (= 1 (length (%warning-rows h)))
        "a warning that arrives after the attach is filed — it IS news")
    (leticl::%render h)
    (is (search "the context is nearly full" (%screen-text h)) "and it is on the screen")))

(def-test a-resync-still-replants-the-wall-it-always-did (:suite leticl)
  "**The other side of part 1, and the one that must NOT move.**

R10's rule is unchanged for a resync and a reattach: the transcript was replaced, the
rows went with it, and the retired set — which a snapshot does not carry and must not —
decides which of them come back visible. That is what `a-retired-warning-stays-retired-
across-a-resync-and-a-reattach` pins, and this test pins the half it does not: a warning
that is NOT retired comes back VISIBLE on a resync.

An `attach` that was inferred too eagerly would take this away silently, which is why the
flag is a keyword the frame's own caller passes and not a property of the payload."
  (let ((*slash-out* nil) (*job-out* nil)
        (*snapshotted-sessions* nil)
        (h (%on-head :cols 96 :rows 24))
        (w (list :code "context_wall" :detail "the context is nearly full" :ts 5)))
    ;; the head meets the session: an attach, nothing planted
    (leticl::%handle-frame
     h (list :frame "hello" :protocol-version 23 :session-id "s-r19b" :head-id "h1"
             :dropped 0 :sessions nil :wiring nil :resumed-from nil :scrubbed nil
             :snapshot (%snapshot-with-warnings (list w) :session-id "s-r19b")))
    (is (null (%warning-rows h)) "the attach plants nothing")
    ;; then a RESYNC for the same session: the row comes back, visible
    (leticl::%handle-frame
     h (list :frame "resync" :reason "auto-compaction" :dropped 0 :scrubbed nil
             :snapshot (%snapshot-with-warnings (list w) :session-id "s-r19b")))
    (is (= 1 (length (%warning-rows h))) "a resync replants it, as R10 requires")
    (is (not (getf (first (%warning-rows h)) :retired)) "and visible, because it was never retired")))

(def-test a-second-attach-to-the-same-session-is-a-reattach (:suite leticl)
  "**What `*snapshotted-sessions*` decides, stated as its own test.**

The distinction is per PROCESS and per SESSION: the first snapshot for an id is the head
meeting that conversation, and every later one — a reconnect, a resync, a `/switch` back
— is a replacement of a transcript this head has already shown. A `/switch` to a session
it has never seen is an attach and opens clean, which is the same principle one
conversation over."
  (let ((*snapshotted-sessions* nil))
    (is (not (session-snapshotted-p "s-1")) "nothing is known before the first frame")
    (is (note-snapshotted "s-1") "the first sighting is an attach")
    (is (session-snapshotted-p "s-1") "and it is remembered")
    (is (not (note-snapshotted "s-1")) "the second is not")
    (is (note-snapshotted "s-2") "and a DIFFERENT session is an attach of its own")))

(def-test a-routine-notice-is-not-drawn-in-the-failure-register (:suite leticl)
  "**R19 part 2.** `compacted` and `auto_compact` are the session doing exactly what it
should, and they arrived in the same red as a denial or a gate timeout — *the colour
asserts a severity the fact does not have*, in the one place the operator cannot help but
look. A housekeeping notice and a refused call must not look alike.

**The failing case is the one to keep:** an operator met by a red block on every restart
learns to skip it, and the block is where a real denial lives. Making routine
announcements loud is how the loud ones stop being read.

Both surfaces, because a listing that said `!` about a note the conversation had drawn
faint would put the argument back where it started."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (*job-out* nil)
        (h (%on-head :cols 96 :rows 24)))
    ;; a routine one: faint, `·`, and NOT the failure role
    (leticl::%handle-frame h (%warning-frame "auto_compact" "240 rows folded"))
    (let ((line (first (item-lines (first (%warning-rows h)) 96 (head-prefs h)))))
      (is (equal "· auto_compact — 240 rows folded" (segs-of (list line)))
          "the mark is `·` and not `!`")
      (is (equal '(:dim t) (cdr (first line)))
          "drawn faint, which is the register the head uses for instruments")
      (is (not (equal +role-failure+ (cdr (first line))))
          "**and NOT the failure role** — this is the whole of part 2"))
    ;; a not-routine one in the same head: unchanged
    (leticl::%handle-frame h (%warning-frame "gate_timeout" "nobody answered" 3))
    (let* ((rows (%warning-rows h))
           (line (first (item-lines (second rows) 96 (head-prefs h)))))
      (is (equal "! gate_timeout — nobody answered" (segs-of (list line)))
          "a gate timeout keeps the `!`")
      (is (equal +role-failure+ (cdr (first line))) "and the failure role"))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "· auto_compact — 240 rows folded" text) "both are on the screen")
      (is (search "! gate_timeout — nobody answered" text)
          "and the two registers are visibly different in one frame"))
    ;; the listing agrees about the register, which is the one thing that could drift
    (let ((text (%list-text (warning-listing-lines (head-session h)))))
      (is (search "· auto_compact" text) "`/notes` marks the routine one the same way: ~s" text)
      (is (search "! gate_timeout" text) "and the other one the other way"))))

;;; --------- §11.5's shape, applied to the warning table: the GUARD reads letibot's ------ ;;;
;;;
;;; Measured 2026-09-22, comparing the two tables code by code, and both heads had
;;; written one down independently from the same requirement:
;;;
;;;     both routine                    10 codes
;;;     classified differently           4 codes
;;;     in one table and not the other  20 codes — 9 of them reachable from this head,
;;;                                     so letibot drew them dim and this head drew RED
;;;
;;; **A code one head renders and the other classifies, with no row in the second's
;;; table, is not agreement — it is a gap wearing agreement's clothes.** Both tables had
;;; a fail-safe default (unknown = failure) and both were well reasoned, and the two
;;; still disagreed about twenty codes, because each was written from its own head's view
;;; of what it emits.
;;;
;;; The fix is the one §11.5 ruled for the fence token table: **the copy stays, because a
;;; head must render with the reference tree absent, and the GUARD points at the source.**
;;; letibot's `TABLE` is where the codes are defined, so that table is what this reads.

(defparameter +letibot-warning-rs+
  "/home/dead/Projects/letibot/letibot/crates/sessionlog/src/warning.rs"
  "Where letibot's severity `TABLE` is — the crate every `Warning` code is defined in.

The same absolute path the `Cargo.toml`s of that tree already carry for `rano`, so a box
that can build either head can read it. A `defparameter` and not a `defconstant`: the file
pusher SKIPS constants.")

(defun %letibot-routine-codes ()
  "letibot's `Class::Routine` codes, read out of its source. NIL when it cannot be read.

NIL rather than an empty list, and the difference is the whole of what makes the guard
honest: an empty list would let the comparison below pass over nothing. The caller skips —
visibly, because the suite counts skips — and asserts a plausible count when it does not."
  (when (probe-file +letibot-warning-rs+)
    (let* ((src (uiop:read-file-string +letibot-warning-rs+))
           (at (search "pub const TABLE" src)))
      (when at
        ;; `search`'s haystack is the SECOND sequence, so the offset is `:start2` —
        ;; measured, because `:start` is not a keyword it knows and the compiler said so
        (let ((body (subseq src at (or (search "];" src :start2 at) (length src)))))
          (let ((out nil) (i 0))
            (loop while (< i (length body))
                  for open = (position #\( body :start i)
                  while open
                  do (let* ((close (or (position #\) body :start open) (length body)))
                            (row (subseq body open close))
                            (code (and (search "Class::Routine" row)
                                       (let ((q1 (position #\" row))
                                             (q2 (position #\" row :start (1+ (or (position #\" row) 0)))))
                                         (and q1 q2 (subseq row (1+ q1) q2))))))
                       (when code (push code out))
                       (setf i (1+ close))))
            (nreverse (remove-duplicates out :test #'string=))))))))

(def-test a-routine-warning-code-is-one-letibot-calls-routine (:suite leticl)
  "**The two severity tables agree, and a guard keeps them that way.**

Both heads emit these codes, so a register either head decides alone is a register the two
disagree about on screen — which is exactly what they did until this was measured. The
point of the comparison is not that one table is right: it is that **there is one answer**,
and a head that quietly holds a different one is a head showing a different screen.

This is §11.5's shape for the second table: the copy stays (a head renders without the
reference tree), and a test reads the source and fails when they part. It has to be
falsified by moving a code and watching it fail.

Both directions are asserted, because they fail differently:
  · **a code letibot calls routine that this head does not** draws RED here where letibot
    draws dim — the operator sees an alarm for housekeeping, which is R19 itself;
  · **a code this head calls routine and letibot does not** draws dim here where letibot
    draws red — the direction that HIDES something, and the one the rule's fail-safe is
    written against."
  (let ((theirs (%letibot-routine-codes)))
    (if (null theirs)
        (skip "letibot's warning.rs is not on this box")
        (progn
          (is (> (length theirs) 15)
              "**a plausible table, so a regex that stopped matching cannot pass** — ~d
 codes read out of ~a" (length theirs) +letibot-warning-rs+)
          (let ((mine (sort (copy-list +routine-warnings+) #'string<))
                (his (sort (copy-list theirs) #'string<)))
            (is (equal mine his)
                "**THE SAME SET**, so neither head can move a code's register alone.
~%  letibot calls routine and this head does not: ~s~%  this head calls routine and \
letibot does not: ~s"
                (set-difference his mine :test #'string=)
                (set-difference mine his :test #'string=)))))))

(def-test the-severity-split-is-a-table-and-what-is-not-in-it-stays-loud (:suite leticl)
  "**The default direction, asserted**, because it is the half somebody would get wrong.

The wire carries `code`, `detail` and `ts` and **no severity** (`view.rs:306-310`), so
this head is the only layer that can answer the question — which makes the answer a table
in the head, and makes its DEFAULT load-bearing. A code nobody has classified is drawn
exactly as it always was: loud. A mistake in the direction of too-quiet hides a real
denial; a mistake in the direction of too-loud is what R19 was filed about, and it is the
one that gets fixed by adding a name to this list.

Two codes were deliberately kept loud and a reader may argue with both — `secret_late`
(a password that went unused) and `sudo` (half of whose cases are the ordinary one) — so
they are pinned here rather than left to memory."
  ;; the ones that ARE routine, one assertion each so a removal is visible
  (dolist (code '("auto_compact" "compacted" "reseated" "frame_capture_written"
                  "frame_capture_disabled" "mode_set" "mode_set_next_session_only"
                  "mode_session_only" "model_endpoint_retry" "interrupt_idle"
                  "promote_idle" "daemon_stopping" "resume_note" "open_note"
                  "reattached" "slash" "imported" "import_scrap" "imported_summary"
                  "steering_urgent" "cache_reuse_shortfall" "test"))
    (is (routine-warning-p (list :code code :detail "x"))
        (format nil "~a is routine" code)))
  ;; and the ones that are not, including every one a reader could mistake for routine
  (dolist (code '("auto_compact_failed" "auto_compact_skipped" "auto_compact_no_progress"
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
                  "absolute_path" "endpoint" "dated" "data_claim"
                  ;; and the one that does not exist yet: the fail-safe direction
                  "a_code_from_a_daemon_this_build_has_never_met"))
    (is (not (routine-warning-p (list :code code :detail "x")))
        (format nil "~a stays in the failure register" code)))
  ;; a warning with no code at all, which is what a malformed frame leaves
  (is (not (routine-warning-p (list :detail "no code"))) "a codeless warning is not routine")
  (is (equal "!" (warning-glyph (list :code "context_wall"))) "the failure glyph")
  (is (equal "·" (warning-glyph (list :code "compacted"))) "and the routine one"))

;;; --------------------------------------------------- the shared notes file ;;;
;;;
;;; **The run-wide file was not enough, and this is the measurement.** `run-all` points
;;; `*notes-path-override*` at a directory of the run's own, which is what keeps the
;;; OPERATOR'S `~/.config/letibot/head.toml` out of the suite's reach — and that is all it
;;; does. It is still ONE FILE shared by every test in the run, and since R24 both the
;;; listing and the act RE-READ it (two heads share it; that is the whole of R24's
;;; requirement), so a test that starts from *nothing retired* inherits whatever the
;;; previous notes test left behind. Measured: `the-notes-verb-lists-retires-and-restores`
;;; failed `one went` and `the rest went`, because `a-snapshot-warning-list-keeps-the-
;;; conversations-order` had already written its dismissal into the run-wide file — a test
;;; that changes the answer to the question it is asking, which is the same defect as a
;;; global that survives between tests, one layer further down.
;;;
;;; So a test that touches the notes file gets one of its own. `a-dismissal-survives-a-
;;; restart` binds a path by hand because it also needs to NAME it; every other test that
;;; touches the file takes this fixture, which is the one place the pattern is written.

(defvar *notes-fixture-serial* 0
  "Counts the notes files this run has handed out, so two tests in the same second do not
share a directory if one of them fails to clean up.")

(it.bese.fiveam:def-fixture notes-of-its-own ()
  (let ((*notes-path-override*
          (merge-pathnames (format nil "leticl-test-notes-~d-~d/head.toml"
                                   (get-universal-time) (incf *notes-fixture-serial*))
                           (uiop:temporary-directory))))
    (unwind-protect (&body)
      (ignore-errors
        (uiop:delete-directory-tree
         (uiop:pathname-directory-pathname *notes-path-override*)
         :validate t)))))

(def-test a-dismissal-survives-a-restart (:suite leticl)
  "**R19 part 3, and it supersedes §11.2's ruling** — *restart is a different requirement
and nobody had asked for it*, correct when written and overtaken by the operator asking
by hitting it.

The round trip is what matters, so this test writes a file and reads it back into a
FRESH head: a dismissal recorded by one process and honoured by the next. Two details are
load-bearing and both are asserted here rather than trusted:

  · **the identity is escaped**, because it is written as one comma-separated value on one
    line of a `key = value` file. A warning whose detail carries a comma, a newline or a
    `|` would otherwise split into two entries — or two lines — and the dismissal would
    silently not survive, which is the exact defect this part exists to fix;
  · **`*write-prefs*` is bound T**, because the suite must not edit the operator's
    `head.toml`; the file lives in the test's own temp directory."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/leticl-r19-~a/" (get-universal-time))))
         (file (merge-pathnames "head.toml" dir))
         (*write-prefs* t)
         ;; **the shared notes file, pointed at this test's own directory** (R24) — it is
         ;; the OPERATOR'S file in production, and this test writes and reads it.
         (*notes-path-override* file)
         (*slash-out* nil) (*job-out* nil)
         (h (%on-head :cols 96 :rows 24))
         (s (head-session h)))
    ;; **SAY WHERE THE HEAD WRITES, BEFORE IT WRITES ANYTHING**, and this line is
    ;; here because its absence cost the operator a line in their real
    ;; `~/.config/leticl/head.toml`. The first version of this test bound
    ;; `*write-prefs*` T and then let a dismissal save — and `save-prefs` fell through
    ;; to `default-prefs-path`, so a test about a RESTART wrote an identity from a
    ;; temp directory into the operator's own file. Measured, and repaired by hand.
    ;;
    ;; **The dismissal goes to `*notes-path-override*` and NOT to `*prefs*`'s path since
    ;; R24**, which is the change that made this test's file a SHARED one: the retired set
    ;; left `leticl/head.toml` for the file every head writes. The two are the same file
    ;; here, deliberately, so one `let` covers both — and the assertion below is against
    ;; the shared file's own reader rather than against a preference field.
    (setf leticl::*prefs* (let ((p (make-prefs))) (setf (prefs-path p) file) p))
    (unwind-protect
         (progn
           (load-prefs-into h file)
           ;; a detail with every character that could break the file
           (leticl::%handle-frame
            h (%warning-frame "context_wall" "nearly full, and \"quoted\" — see a|b" 7))
           (leticl::%notes h "notes" "dismiss 1")
           (is (= 1 (length (session-retired s))) "one dismissal in memory")
           (is (probe-file file) "and the file was written")
           ;; **AND A FRESH HEAD READS IT BACK.** Not the same head re-reading its own
           ;; set: the next start is the case that was broken.
           (let ((fresh (%on-head :cols 96 :rows 24)))
             (is (null (session-retired (head-session fresh)))
                 "a head that has read nothing has retired nothing")
             (load-prefs-into fresh file)
             (is (equal (read-retired-keys) (session-retired (head-session fresh)))
                 "and the READER sees it too, so a later save cannot drop it")
             (is (equal (session-retired s) (session-retired (head-session fresh)))
                 "**the dismissal came back with the file** — ~s against ~s"
                 (session-retired (head-session fresh)) (session-retired s)))
           ;; and the identity survived the trip, which is what makes the membership
           ;; test work on the other side
           (let ((w (list :code "context_wall" :detail "nearly full, and \"quoted\" — see a|b"
                          :ts 7)))
             (is (equal (warning-identity w) (first (session-retired s)))
                 "the identity on disk is the identity in memory"))
           ;; a warning retired in the LAST run is replanted retired by this one
           (leticl::%handle-frame
            (%on-head :cols 96 :rows 24) (%warning-frame "auto_compact" "x")))
      (ignore-errors (delete-file file))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(def-test the-retired-set-comes-from-the-shared-file-and-not-this-heads-own
    (:suite leticl :fixture (notes-of-its-own))
  "**R24's line between the two files, and it is the one an earlier version of this work
crossed.** The four choices are this head's own (`~/.config/leticl/head.toml`); the retired
set is every head's (`~/.config/letibot/head.toml`). Writing the set to the shared file and
then READING it back from this head's own — which is what R19's `prefs-retired` did — is a
dismissal that is saved and never honoured, and it stays invisible for exactly as long as
the two paths happen to be the same file. They were the same file in this test's
neighbour, which is why it passed either way.

So the two are pointed at different files here ON PURPOSE, and the assertion is that a
fresh start finds the set in the shared one with nothing to help it in its own."
  (let* ((dir (uiop:ensure-directory-pathname
               (format nil "/tmp/leticl-r24-prefs-~d/" (get-universal-time))))
         (own (merge-pathnames "head.toml" dir))
         (h (%on-head :cols 96 :rows 24)))
    (unwind-protect
         (progn
           ;; the shared file gets a dismissal, as if another head had made it
           (setf (session-retired (head-session h)) (list "w|context_wall|42|feedfacefeedface"))
           (persist-retired h)
           (is (search "w|context_wall|42|feedfacefeedface"
                       (uiop:read-file-string (notes-path)))
               "the dismissal went to the shared file")
           ;; this head's own file is written, and says NOTHING about retiring
           (save-prefs (make-prefs) own)
           (let ((own-text (uiop:read-file-string own)))
             (is (search "diff" own-text) "the choices are in this head's own file")
             (is (not (search "retired" own-text))
                 "**and the set is not** — one home for it, or two answers to one question"))
           ;; a fresh start reads the set from the SHARED file, which is the whole point
           (let ((fresh (%on-head :cols 96 :rows 24)))
             (load-prefs-into fresh own)
             (is (equal '("w|context_wall|42|feedfacefeedface")
                        (session-retired (head-session fresh)))
                 "so the next start has the dismissal, from the file that held it")))
      (ignore-errors (uiop:delete-directory-tree dir :validate t)))))

(def-test an-identity-with-punctuation-round-trips-through-the-file (:suite leticl)
  "An identity survives the ONE value `head.toml` holds it in, whatever the warning said.

**The reason is different from the reason this test was written, and the reason is worth
keeping straight (R24).** R19 part 3 escaped the detail — `%2C` for a comma, `%0A` for a
newline — because the detail was IN the key and the key is one comma-separated value on one
line. The key is now `w|{code}|{ts}|{fnv1a(detail)}`: a hash has no comma and no newline in
it, so the escaping is not merely unnecessary, it would be a second format in a file two
heads share. What the test still checks is the property the escaping was for — **a warning
whose detail is nothing but punctuation retires to a key that comes back identical** — and
that is why the details below are still the awkward ones."
  (flet ((round-trip (detail)
           (let* ((w (list :code "gate" :detail detail :ts 3))
                  (back (string->retired (retired->string (list (warning-identity w))))))
             (equal (list (warning-identity w)) back))))
    (is (round-trip "plain") "an ordinary detail")
    (is (round-trip "a, b") "a comma is IN the detail and not a separator in the key")
    (is (round-trip (format nil "two~%lines")) "a newline does not split the line")
    (is (round-trip "a|b") "and `|` inside the detail is not one of the key's three")
    (is (round-trip "100% done") "a `%` is a byte like any other")
    ;; the case a substitution-based scheme gets wrong: the detail is hashed, so `%2C` in it
    ;; is four ordinary bytes rather than an escape anybody has to un-apply
    (is (round-trip "already %2C here") "**a detail that LOOKS escaped is hashed like anything else**")
    (is (round-trip (format nil "tab~Cand~Ccontrol" #\Tab #\Return)) "tabs and returns too")
    ;; the cap, which is the only thing that may lose one
    (let ((many (loop for i from 0 below 600 collect (format nil "c|~d|d" i))))
      (is (= +retired-cap+ (length (string->retired (retired->string many))))
          "the file holds at most the cap")
      (is (equal (car (last many)) (car (last (string->retired (retired->string many)))))
          "and it drops the OLDEST, because the newest dismissal is the one being made")))
  ;; a hand-mangled value costs a dismissal, never a start
  (is (null (string->retired "")) "an empty value is nothing retired")
  (is (null (string->retired nil)) "and neither is an absent one")
  (is (null (string->retired "  ")) "and a value of spaces is not an identity"))

(def-test a-warning-the-daemon-sends-is-drawn-where-it-arrived (:suite leticl)
  "R10's DRAW half. A warning is filed as a row ANCHORED WHERE THE ENVELOPE ARRIVED —
the `note-unreadable` shape — and not as a status note, which expires on a TTL and takes
the fact with it by the time anybody looks.

**The code here is `context_wall`, and that changed with R19 part 2.** This test used
`auto_compact`, which R19 moved OUT of the failure register — a compaction firing is the
session doing exactly what it should. The failure register is still a real register and
this is the code that belongs in it: the turn was stopped because the context is nearly
full. The routine half is `a-routine-notice-is-not-drawn-in-the-failure-register`."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (*job-out* nil)
        (h (%on-head :cols 96 :rows 24)))
    (is (eq :rendered (leticl::%handle-frame
                       h (%warning-frame "context_wall" "the context is nearly full")))
        "the frame renders rather than being silently consumed")
    (is (= 1 (length (session-warnings (head-session h)))) "it is in the record")
    (is (equal "context_wall" (getf (first (session-warnings (head-session h))) :code))
        "with the daemon's own code, which is what /status counts")
    (let ((row (first (%warning-rows h))))
      (is (equal "note" (getf row :kind)) "filed as a row of this head's own")
      (is (equal "context_wall — the context is nearly full"
                 (getf (leticl::item-body row) :text))
          "saying exactly what the daemon said")
      (is (equal "! context_wall — the context is nearly full"
                 (segs-of (item-lines row 96 (head-prefs h))))
          "drawn in the failure role, the reference's warn_line"))
    (leticl::%render h)
    (is (search "! context_wall — the context is nearly full" (%screen-text h))
        "and it is ON THE SCREEN, which is the whole point")))

(def-test a-long-warning-folds-to-three-lines-and-names-the-verb (:suite leticl)
  "R10's other half, and the number is the reference's rather than a taste of ours: two
gate timeouts rendered 27 red lines there. Three lines keeps the code, the first sentence
and the fact that there is more, and `/notes` prints the whole text — so this folds a
DISCLOSURE and never the record."
  (let* ((*slash-out* nil) (*job-out* nil)
         (detail (format nil "~{~a ~}" (loop for i from 1 to 60 collect (format nil "w~d" i))))
         (h (%on-head :cols 40 :rows 40)))
    (leticl::%handle-frame h (%warning-frame "context_wall" detail))
    (let* ((row (first (%warning-rows h)))
           (rows (item-lines row 40 (head-prefs h))))
      (is (> (length (wrap-segments (list (cons (format nil "! context_wall — ~a" detail) nil)) 40))
             3)
          "the premise: the unfolded warning is longer than the cap")
      (is (= 4 (length rows)) "three lines, then the seam")
      (is (search "… +" (segs-of (last rows))) "the seam counts what went")
      (is (search "· /notes" (segs-of (last rows))) "and names the verb that has the rest"))
    ;; **the record is the WHOLE text** — the fold is a disclosure decision, not a cap
    (is (string= detail (getf (first (session-warnings (head-session h))) :detail))
        "every word is still in the record")
    (is (search detail (%list-text (warning-listing-lines (head-session h))))
        "and /notes prints it unfolded")))

(def-test a-retired-warning-leaves-the-screen-and-stays-counted (:suite leticl)
  "**Retired is not deleted.** The row stops being drawn and nothing else changes: the
warning stays in `session-warnings`, `/notes` lists it with its whole text, and `/status`
counts it — the same rule `/status`'s `filtered` counter keeps, where *\"I chose not to
show this\"* must not look like *\"nothing happened\"*."
  ;; **`context_wall`, not `mode_set`, and R19 part 2 is why**: `mode_set` is a
  ;; routine notice now and draws faint with a `·`, while this test is about
  ;; retirement. Same for the `/notes` test below. The register has its own tests.
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (*job-out* nil)
        (h (%on-head :cols 96 :rows 24)))
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full"))
    (leticl::%render h)
    (is (search "! context_wall — the context is nearly full" (%screen-text h))
        "the row is up")
    (leticl::%notes h "notes" "dismiss 1")
    (leticl::%render h)
    (is (not (search "the context is nearly full" (%screen-text h)))
        "and gone from the screen")
    (is (= 1 (length (session-warnings (head-session h)))) "but not from the record")
    (multiple-value-bind (held retired) (warning-counts (head-session h))
      (is (= 1 held) "the warning is still held")
      (is (= 1 retired) "and counted as retired, so a dismissal is counted and not a disappearance"))
    (is (search "[retired]" (%list-text (warning-listing-lines (head-session h))))
        "/notes still lists it, marked")
    (is (search "the context is nearly full" (%list-text (warning-listing-lines (head-session h))))
        "with its whole text, which is the part that must not be droppable")))

(def-test a-retired-warning-stays-retired-across-a-resync-and-a-reattach
    (:suite leticl :fixture (notes-of-its-own))
  "Both events the requirement names REPLACE the transcript from a snapshot, which is
exactly why a retirement stored on the row would be undone by them. The set is keyed by
the warning's own `(code detail ts)` and lives outside anything a snapshot carries — the
reference's `dismissed` and its `note_key` (`app.rs:5713-5732`), which `load` does not
touch while it replaces `self.notes` wholesale."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 96 :rows 24)))
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full"))
    (leticl::%notes h "notes" "dismiss all")
    (is (= 1 (length (session-retired (head-session h)))) "one dismissal recorded")
    ;; a RESYNC: a snapshot carrying the same warning replaces the transcript
    (ingest-snapshot (head-session h)
                     (list :session-id (session-session-id (head-session h)) :seq 9
                           :dropped 0 :items-dropped 0 :items nil :turn nil
                           :open-decisions nil :settled-decisions nil :heads nil
                           :warnings (list (list :code "context_wall"
                                                 :detail "the context is nearly full"
                                                 :ts 0))))
    (leticl::%render h)
    (is (not (search "the context is nearly full" (%screen-text h)))
        "the wall does NOT come back: the snapshot replants it retired")
    (is (= 1 (length (session-warnings (head-session h)))) "the record has it")
    (let ((rows (%warning-rows h)))
      (is (= 1 (length rows)) "the row is back, as one and not as two")
      (is (getf (first rows) :retired) "and it is retired"))
    ;; and a reader who was wrong can have it back
    (leticl::%notes h "notes" "restore")
    (leticl::%render h)
    (is (search "the context is nearly full" (%screen-text h))
        "/notes restore puts it back on the screen")
    (is (null (session-retired (head-session h))) "and the dismissal is undone")))

(def-test a-snapshot-warning-list-keeps-the-conversations-order
    (:suite leticl :fixture (notes-of-its-own))
  "The daemon's list is a `Vec` pushed in arrival order — OLDEST first (`view.rs:660`) —
and this slot is newest-first because a live warning is PUSHED. Both orders have to
agree, or `/notes` numbers the list backwards after a resync and `/notes dismiss N`
retires the wrong warning."
  (let ((h (%on-head :cols 96 :rows 24)))
    (ingest-snapshot (head-session h)
                     (list :session-id "s-order" :seq 9 :dropped 0 :items-dropped 0
                           :items nil :turn nil :open-decisions nil :settled-decisions nil
                           :heads nil
                           :warnings (list (list :code "first" :detail "one" :ts 1)
                                           (list :code "second" :detail "two" :ts 2))))
    (is (equal '("first" "second")
               (mapcar (lambda (w) (getf w :code)) (warning-order (head-session h))))
        "the conversation's order, oldest first, survives the snapshot")
    (leticl::%notes h "notes" "dismiss 1")
    ;; **The identity is a HASH and not the detail** (R24's shared file): letibot's own
    ;; format, `w|code|ts|fnv1a(detail)`, because the retired set now lives in a file two
    ;; heads share and a key they cannot both read is a file neither can use. So this
    ;; asserts the SHAPE, and that the two codes' keys are different — which is the
    ;; property the test is about (it retired the right one), rather than a literal
    ;; string that moves whenever the hash does.
    ;; `session-warnings` is NEWEST-first (a live warning is pushed), so the oldest — the
    ;; one `/notes` numbered 1 and `dismiss 1` retired — is the LAST of it. That ordering
    ;; is the subject of this very test, one line up.
    (is (equal "first" (getf (car (last (session-warnings (head-session h)))) :code)))
    (is (string= "w|first|1|" (subseq (first (session-retired (head-session h))) 0 10))
        "so `/notes dismiss 1` retires the OLDEST — the one the listing numbered 1")))

(def-test the-turn-failed-warning-is-not-a-second-copy-of-the-footer (:suite leticl)
  "The daemon publishes both on purpose — one is the turn's STATE, the other its HISTORY —
and on a screen they are one sentence twice, three lines apart. So the turn's footer draws
it and the warning is FILTERED, which `/status` counts, rather than also filed as a row
(app.rs:3320-3330). It is filtered out of a snapshot's notes too, and the two paths have
to agree about every filter (`bacf495`)."
  (let ((*slash-out* nil) (*job-out* nil) (h (%on-head :cols 96 :rows 24)))
    (is (eq :filtered (leticl::%handle-frame
                       h (%warning-frame "turn_failed" "the model died")))
        "consumed as filtered, which is not dropped")
    (is (null (session-warnings (head-session h))) "and not in the record")
    (is (null (%warning-rows h)) "so there is no row")
    ;; the snapshot path agrees — a resync must not put it back either
    (ingest-snapshot (head-session h)
                     (list :session-id (session-session-id (head-session h)) :seq 9
                           :dropped 0 :items-dropped 0 :items nil :turn nil
                           :open-decisions nil :settled-decisions nil :heads nil
                           :warnings (list (list :code "turn_failed" :detail "the model died" :ts 0))))
    (is (null (%warning-rows h)) "and a snapshot does not replant it")))

(def-test ctrl-n-retires-every-note-and-says-what-the-verb-says
    (:suite leticl :fixture (notes-of-its-own))
  "**R22, and both trees landed the same three answers: `ctrl-n`, ALL, and the empty
press says so.**

The chord retires every note this head holds — the same reach `/notes dismiss all` has,
which is *this screenful and no further*: a note's key carries the log's clock, so a
warning that happens again arrives with a new `ts` and is a note nobody has retired. It
cannot mute a KIND of thing, and that is a property of the identity rather than a hope.

What is asserted here is the part that would drift: **one path and one sentence.** A chord
that retired notes on its own would be a second implementation of a verb, and the second
one is the one that forgets to write the file."
  (let ((*slash-out* nil) (*job-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (h (%on-head :cols 96 :rows 24)))
    ;; --- the EMPTY press, which is the one amendment and the whole of the difference
    ;; between the first draft and what landed
    (leticl::%handle-key h (list :type :ctrl :ch #\n))
    (is (search "nothing to retire" (head-status-note h))
        "an empty press ANSWERS rather than falling silent: ~s" (head-status-note h))
    (is (null (session-retired (head-session h))) "and retires nothing")
    ;; --- two notes, and the chord takes both
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full" 1))
    (leticl::%handle-frame h (%warning-frame "gate_timeout" "nobody answered" 7))
    (leticl::%handle-key h (list :type :ctrl :ch #\n))
    (is (= 2 (length (session-retired (head-session h))))
        "every note this head holds is retired")
    (multiple-value-bind (held retired) (warning-counts (head-session h))
      (is (= 2 held) "**retired is not deleted** — they are still held, as R10 requires")
      (is (= 2 retired) "and counted as retired, so `/status` says so too"))
    (is (search "retired 2 warnings — off the screen" (head-status-note h))
        "with the verb's own sentence: ~s" (head-status-note h))
    ;; **THE SAME SENTENCE FROM THE VERB.** Back to the same state — the notes are
    ;; still in the record, so `/notes restore` is enough — and the two doors are
    ;; compared on the thing a reader would notice if they differed.
    (let ((from-the-chord (head-status-note h)))
      (leticl::%command h "notes restore")
      (is (null (session-retired (head-session h))) "the restore emptied the set")
      (leticl::%command h "notes dismiss all")
      (is (equal from-the-chord (head-status-note h))
          "`ctrl-n` and `/notes dismiss all` say the same thing: ~s against ~s"
          from-the-chord (head-status-note h)))
    ;; --- AND IT WENT WHERE THE VERB WRITES. The retired set is the file every head
    ;; shares (R24), so a chord that skipped the write would be a dismissal that
    ;; survives until this process exits.
    (is (equal (sort (copy-list (session-retired (head-session h))) #'string<)
               (sort (copy-list (read-retired-keys)) #'string<))
        "the chord persisted through the same writer the verb uses")
    (is (= 2 (length (read-retired-keys))) "both keys are on disk")
    ;; --- and the restore/empty pair reads the same way from the chord
    (leticl::%command h "notes restore")
    (leticl::%handle-key h (list :type :ctrl :ch #\n))
    (is (search "retired 2 warnings" (head-status-note h))
        "with the notes back, the same press retires them again")))

(def-test ctrl-n-is-in-the-hint-bar-inside-the-columns-an-80-wide-frame-has (:suite leticl)
  "**The placement is a measurement, and both heads measured the same number.**

This bar is 136 characters. So is letibot's, item for item — the two heads teach the same
chords in the same order with the same separator — and at the usual 80 columns everything
past column 80 is off the screen. Appending `ctrl-n notes` at the END would put it at 137
and invisible; it is placed SECOND, right after `ctrl-s sessions`, where it starts at
column 18.

That is the whole of *the hint names it*, which is the argument that made ALL the right
scope: a chord named where it acts can be silent when it has nothing to act on
(`ctrl-t`), and a chord named unconditionally has to answer unconditionally. Neither half
survives a hint the operator cannot see."
  (let* ((h (%on-head :cols 80 :rows 24))
         (text (format nil "~{~a~}" (mapcar #'car (hint-bar h 80))))
         (at (search "ctrl-n notes" text)))
    (is (integerp at) "the normal hint names the chord")
    (is (< at 80)
        "**and it is inside the first 80 columns**, where it is on the screen at the
 usual size — it starts at column ~d" at)
    (is (< (search "ctrl-s sessions" text) at)
        "`ctrl-s` keeps first place: opening the session list is what an operator with
 nothing in front of them reaches for, and `ctrl-n` is a reflex")
    (is (= 1 (length (hint-bar h 80)))
        "**one constant string**, so a narrow frame truncates it rather than re-ordering
 it — the prefix that used to move sideways is not back")))

(def-test ctrl-n-keeps-the-asks-keys-and-the-ladders
    (:suite leticl :fixture (notes-of-its-own))
  "The chord is a HEAD chord, so it runs before every view — which is what makes it work
under a pane, and is also what could make it steal a key a card owns. `n` is not one: no
card reads a letter or a `ctrl`, and the ask's own keys are the digits, the arrows and
enter.

**The fixture is load-bearing here and the first version of this test did not have it.**
Without one, the notes file is the run's own — shared by every test in the run — and
`/notes` RE-READS it, so *one warning retired* was one warning plus whatever an earlier
test had dismissed. Measured: `a head chord runs before the pane` failed with the run's
leftovers in the set."
  (let ((*slash-out* nil) (*job-out* nil) (*pick-open* nil) (*mode-confirm* nil)
        (h (%on-head :cols 96 :rows 24)))
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full" 1))
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (let ((wire (%wire h)))
      ;; the digits still answer the ask while an ask is open
      (leticl::%handle-key h (list :type :char :ch #\1))
      (is (equal "allow_once" (getf (first (%sent wire)) :option-id))
          "a digit under an ask still answers the ask"))
    ;; and the chord still works with the pane arm in front of the composer
    (setf (head-mode h) :todos)
    (leticl::%handle-key h (list :type :ctrl :ch #\n))
    (is (= 1 (length (session-retired (head-session h))))
        "a head chord runs before the pane, as `ctrl-r` and `ctrl-t` do")
    (is (eq :todos (head-mode h)) "and it does not close what is on the screen")))

(def-test the-notes-verb-lists-retires-and-restores
    (:suite leticl :fixture (notes-of-its-own))
  "`/notes`, `/notes dismiss N`, `/notes dismiss all`, `/notes restore` and `/dismiss` —
the reference's grammar (app.rs:5772-5839), so the two heads take the same sentence. The
listing is a SLASH listing, which is the pane this head already has for a verb's answer."
  (let ((*slash-out* nil) (*pane-scroll* 0) (*pane-lines* 0) (*pane-room* 0)
        (*job-out* nil)
        (h (%on-head :cols 96 :rows 24)))
    (leticl::%handle-frame h (%warning-frame "context_wall" "the context is nearly full" 1))
    (leticl::%handle-frame h (%warning-frame "gate_timeout" "nobody answered" 7))
    ;; `/notes` shows them, numbered in the conversation's order
    (leticl::%command h "notes")
    (is (eq :slash (head-mode h)) "the listing takes the screen")
    (is (equal "/notes" (car *slash-out*)) "as the notes listing")
    (let ((text (%list-text (warning-listing-lines (head-session h)))))
      (is (search "2 warnings, 0 retired" text) "with the count and how many are retired")
      (is (search "! context_wall — the context is nearly full" text)
          "the first, oldest first")
      (is (search "! gate_timeout — nobody answered" text) "and the second")
      (is (search "/notes dismiss" text) "and the verb that retires one"))
    ;; `/notes dismiss 2` retires the SECOND, which is the newest
    (leticl::%command h "notes dismiss 2")
    (is (= 1 (length (session-retired (head-session h)))) "one went")
    (is (equal "gate_timeout" (getf (first (session-warnings (head-session h))) :code))
        "and it is the second-listed one that is now hidden")
    (is (search "[retired]" (%list-text (warning-listing-lines (head-session h))))
        "the listing redrew with the mark, because it was open")
    ;; `/dismiss` with nothing after it retires every one
    (leticl::%command h "dismiss")
    (is (equal 2 (length (session-retired (head-session h)))) "the rest went")
    (multiple-value-bind (held retired) (warning-counts (head-session h))
      (is (= 2 held)) (is (= 2 retired)))
    ;; and a wrong number is a sentence, not a silence
    (leticl::%command h "notes dismiss 9")
    (is (search "there is no warning 9" (head-status-note h)) "it says so")
    ;; `/notes restore` undoes the lot
    (leticl::%command h "notes restore")
    (is (null (session-retired (head-session h))) "everything is back")
    (is (search "back on the screen" (head-status-note h)) "and it says so too")))

;;; --------------------- a counted operation the daemon reports --------------- ;;;
;;;
;;; **`SessionEvent::Filling { what, unit, done, total }`** (protocol 23, letibot
;;; `4d01aca`, which replaced `ImportProgress`). The field names and the tag are pinned
;;; here against a REAL wire line rather than against the plist this head happens to
;;; expect, because the whole reason the head folds this event is that the daemon is the
;;; only layer that knows which operation is running: a head that renamed it, or read a
;;; field that is not there, would be inferring again with extra steps.

(def-test a-filling-tick-is-read-from-the-real-wire-fields (:suite leticl)
  "The words stay the daemon's, and the tag is the daemon's spelling.

Decoded from a literal line of the shape `protocol.rs` produces — snake_case tag,
snake_case fields — so a rename on either side of the wire is a failure here rather
than a bar that draws `NIL of NIL NIL`."
  (let ((*filling* nil) (*now-ms* 1000)
        (h (%make-head)))
    (let ((frame (json-decode
                  (format nil "{\"frame\":\"event\",\"seq\":1,\"event\":\"filling\",~
                               \"what\":\"carrying the conversation onto the new prompt\",~
                               \"unit\":\"rows\",\"done\":1234,\"total\":2702}"))))
      (is (equal :filling (event-name frame))
          "the tag decodes to the keyword the fold's arm matches")
      (is (eq :dirty (apply-event (head-session h) frame)))
      (is (equal "rows" (getf *filling* :unit)) "the unit is what the daemon counted")
      (is (= 1234 (getf *filling* :done)) "and the count is its count")
      (is (= 2702 (getf *filling* :total))))
    ;; **and the daemon's own words are drawn VERBATIM.** This is the whole point of
    ;; the event: a head that renamed the operation would be naming a cause it cannot
    ;; see, which is the defect the event was landed to end.
    (let* ((f *filling*)
           (text (segs-of (filling-progress-line (getf f :what) (getf f :unit)
                                                 (getf f :done) (getf f :total) 100 1000))))
      (is (search "1234 of 2702 rows" text) "the count and the unit as the daemon named them")
      (is (search "carrying the conversation onto the new prompt" text)
          "and its sentence, not one this head composed"))
    ;; --- the units honestly differ, and both render
    (dolist (case (list (list "parts" "100 of 9570 parts")
                        (list "rows" "100 of 2702 rows")))
      (destructuring-bind (unit expect) case
        (is (search expect (segs-of (filling-progress-line
                                     "some operation" unit 100 (if (string= unit "parts") 9570 2702)
                                     100 1000)))
            (format nil "~a is drawn in its own unit" unit))))
    ;; --- and the completion clears rather than pinning the bar at the end
    (apply-event (head-session h)
                 (json-decode "{\"frame\":\"event\",\"seq\":2,\"event\":\"filling\",\"what\":\"x\",\"unit\":\"rows\",\"done\":2702,\"total\":2702}"))
    (is (null *filling*) "done == total is the operation finished, and the line goes")
    (is (not (filling-active-p)) "so nothing is drawn")
    ;; --- and a tick from a daemon that did not send the words (a skew, R5) gets the
    ;; head's own cause-free sentence rather than NIL where a noun goes
    (apply-event (head-session h)
                 (json-decode "{\"frame\":\"event\",\"seq\":3,\"event\":\"filling\",\"done\":1,\"total\":9}"))
    (let ((text (segs-of (filling-progress-line
                          (getf *filling* :what) (getf *filling* :unit) 1 9 100 1000))))
      (is (search "1 of 9" text) "the count is still drawn")
      (is (not (search "NIL" text)) "and no NIL is printed where a word goes"))
    ;; --- a tick whose count is not a count is not an operation to draw
    (dolist (line (list "{\"frame\":\"event\",\"seq\":4,\"event\":\"filling\",\"what\":\"x\",\"unit\":\"rows\",\"done\":\"lots\",\"total\":9}"
                        "{\"frame\":\"event\",\"seq\":5,\"event\":\"filling\",\"what\":\"x\",\"unit\":\"rows\",\"done\":1,\"total\":0}"))
      (setf *filling* nil)
      (apply-event (head-session h) (json-decode line))
      (is (null *filling*)
          (format nil "a tick that cannot be a fraction of anything sets nothing: ~a" line)))))

(def-test the-daemons-filling-is-drawn-and-not-only-rendered (:suite leticl)
  "**A renderer nothing calls is a screen with no line on it.**

`filling-progress-line` had exactly ONE call site — `carry-line`'s carry branch — and
`carry-line` returned NIL when a filling was active. So *\"when the daemon reports the
operation, this yields to it\"* was implemented as a yield with nothing on the other side,
and the case the function exists for was the one case it never drew.

**Measured on the glass before the fix**, during a real opencode import (9,570 parts), nine
samples over eight seconds with the filling active at every one (`320 of 9570` →
`2816 of 9570`): the screen carried no count, no bar and no operation name — while the head
asked the loop for a frame ten times a second for a line it never drew.

So this asserts the LINE, through `carry-line` and then through the render, which is what
the old test could not do: it called the renderer directly, so it passed while the screen
was empty. **The failure this test is built to catch took a live import to see**, because
the function's own output was always right."
  (let ((*filling* nil) (*now-ms* 1000) (*carry-outstanding* nil)
        (*carry-last-done* nil) (*carry-moved-at* nil) (*pane-scroll* 0)
        (*stdout* (make-string-output-stream))
        (h (%on-head :cols 100 :rows 24)))
    ;; --- the premise: the daemon says it is importing, in its own words
    (apply-event (head-session h)
                 (json-decode "{\"frame\":\"event\",\"seq\":1,\"event\":\"filling\",\"what\":\"importing an opencode conversation\",\"unit\":\"parts\",\"done\":320,\"total\":9570}"))
    (is (filling-active-p) "the head knows an operation is running")
    ;; --- **THE LINE.** Before the fix this was NIL, and the screen was empty.
    (let ((text (segs-of (carry-line h 100))))
      (is (plusp (length text))
          "**`carry-line` DRAWS the daemon's line instead of yielding to nothing** — this is
 the assertion that failed on the glass during a real import")
      (is (search "320 of 9570 parts" text)
          (format nil "with the daemon's own count and its own unit: ~s" text))
      (is (search "importing an opencode conversation" text)
          (format nil "and the daemon's own name for the operation, VERBATIM: ~s" text))
      (is (find #\▐ text) "and the bar"))
    ;; and through the render, which is where it has to end up
    (leticl::%render h)
    (let ((screen (%screen-text h)))
      (is (search "320 of 9570 parts" screen)
          (format nil "**THE LINE IS ON THE SCREEN** — the criterion is the glass, not the
 function's return value: ~s" (subseq screen 0 (min 300 (length screen)))))
      (is (search "importing an opencode conversation" screen)
          "with the operation named, so a reader knows what is being filled"))
    ;; --- and it is the DAEMON'S line, not an inferred one: no carry wording leaks in
    (is (not (search "announced, waiting for the daemon" (segs-of (carry-line h 100))))
        "nothing of the head's own inferred sentence appears: the daemon named this one")
    ;; --- a completed operation takes the line away with it
    (apply-event (head-session h)
                 (json-decode "{\"frame\":\"event\",\"seq\":2,\"event\":\"filling\",\"what\":\"x\",\"unit\":\"parts\",\"done\":9570,\"total\":9570}"))
    (is (not (filling-active-p)) "done == total ends it")
    (is (null (carry-line h 100))
        "and the line goes with it, so a finished import does not leave a bar at 100%")))

;;; ------------------------------ the carry line (§2.5) --------------------- ;;;
;;;
;;; `/reseat` and `/compact` announce every carried row before a single body follows.
;;; Drawn one per row that is a screen of placeholders — *"insane amount of grainess"* —
;;; so it is ONE line, in the cat and the bar the head already has: *"we have this cat
;;; animation for progress and we have prefill progress bar for local models. reuse
;;; that instead of spanning me with grayness"*.
;;;
;;; **And the counter is the FACT.** How many rows have arrived, out of how many there
;;; are — counted off the rows, never a tally kept alongside them and never a rendering
;;; of the count such as how many rows still lack a body.

(defun %carry-snapshot (rows &optional (filled 0))
  "A snapshot as a FORK delivers it: ROWS announced, the first FILLED with bodies.

Fed through `ingest-snapshot`, which is the real path — a fork's rows arrive as a
snapshot and the bodies follow as `transcript_content`. Anything less would be a test
about a state no frame puts the head in."
  (list :session-id "s-carry" :seq 0 :dropped 0 :items-dropped 0 :turn nil
        :open-decisions nil :settled-decisions nil :warnings nil :heads nil
        :items (loop for i from 1 to rows
                     collect (list :item-id (format nil "c~d" i) :kind "user" :ts 0
                                   :item (when (<= i filled)
                                           (list :type "user"
                                                 :parts (list (list :kind "text"
                                                                    :text (format nil "row ~d" i)))))))))

(defun %carry-head (rows &optional (filled 0))
  "A head mid-carry: a bulk announcement of ROWS rows, FILLED of their bodies arrived.

**Built the way the wire builds it, and that matters to what the two numbers mean.**
A fork's snapshot announces every row with NO bodies — that is the announcement — and
the bodies then follow as `transcript_content`. So `total` is the size of the carry and
`done` is how much of it has landed, which is the operator's own rule (*how many you
have done, out of how many there are*). A fixture that baked 1400 bodies into the
snapshot would be measuring a state no frame produces: `note-carry` records the rows
the announcement left OUTSTANDING, so a snapshot with bodies already in it announces
only the rest."
  (let ((h (%make-head)))
    (ingest-snapshot (head-session h) (%carry-snapshot rows 0))
    (when (plusp filled) (%carry-land h 1 filled))
    h))

(defun %carry-land (h from to)
  "Land the bodies for rows FROM..TO, the way `fill-item` lands them."
  (loop for i from from to to
        do (leticl::fill-item (head-session h) (format nil "c~d" i)
                              (list :type "user"
                                    :parts (list (list :kind "text"
                                                       :text (format nil "row ~d" i)))))))

(def-test an-ordinary-turn-is-not-a-carry (:suite leticl)
  "**The indicator must not be derived from a proxy.** The condition that puts this line
up has to be the fact — a BULK ANNOUNCEMENT whose bodies are still coming — and not
*any row lacking a body*, which is a different and much commoner thing.

Every ordinary turn announces a row before its body arrives: `transcript_appended`
carries no text and `transcript_content` follows. That gap is R2's own measurement —
*\"a queued prompt first reaches model, thinking starts, and after some time the prompt
goes out of queue and appears\"* — and it happens on every message of a healthy session.
A line that fires on it announces a carry that is not happening, over and over, which is
what the operator saw (letibot computes `bodies_pending` live over the whole transcript
at `app.rs:6732`; leticl's trigger is the announcement shape, and this is the test that
holds it there).

The fork case is the control: the same rows, in the same order, arriving as a snapshot
instead of as live events."
  (let ((*carry-outstanding* nil) (*carry-last-done* nil) (*carry-moved-at* nil)
        (*now-ms* 0) (*pane-scroll* 0) (*hist-cache* nil) (*hist-generation* 0))
    ;; --- AN ORDINARY TURN: a live announcement, its body in the same drain pass
    (let* ((h (%make-head))
           (s (head-session h)))
      (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
      (apply-event s (list :seq 2 :event "transcript_appended"
                           :item-id "s#t1.0" :kind "assistant"))
      (is (null (carry-line h 100))
          "a live announcement with no body yet is NOT a carry")
      (is (null *carry-outstanding*) "and nothing is outstanding")
      (apply-event s (list :seq 3 :event "transcript_content" :item-id "s#t1.0"
                           :item (list :type "assistant" :text "hi")))
      (is (null (carry-line h 100)) "and it is still not one when the body lands")
      ;; a whole turn of them, one after another: still nothing
      (dotimes (i 3)
        (let ((id (format nil "s#t1.~d" (1+ i))))
          (apply-event s (list :seq (+ 4 i i) :event "transcript_appended"
                               :item-id id :kind "assistant"))
          (is (null (carry-line h 100))
              "message after message does not add up to a carry, however many there are")
          (apply-event s (list :seq (+ 5 i i) :event "transcript_content" :item-id id
                               :item (list :type "assistant" :text "x"))))))
    ;; --- THE CONTROL: the same rows as ONE bulk announcement, above the threshold
    (let ((h (%carry-head 4000 0)))
      (is (carry-line h 100)
          "a snapshot that announces four thousand bodiless rows IS a carry")
      (is (search "4000 rows announced, waiting for the daemon to send them"
                  (segs-of (carry-line h 100)))
          "for which the head says what it knows and not why")
      ;; the bodies land, and it retires with no state behind it
      (%carry-land h 1 4000)
      (is (null (carry-line h 100)) "and it goes when the last of them lands"))))

(def-test the-carry-sentence-names-no-cause (:suite leticl)
  "**A head must not name a cause it has not observed.**

A reseat, a `/compact`, a resume and a plain attach all leave rows without bodies, and
the head sees the same thing in all four. So the live sentence says the fact — how many
rows, and that the daemon has not sent them — and the NAMED version (`carrying the
conversation onto the new prompt`) waits for a daemon that reports the operation it is
running, which is what `SessionEvent::ImportProgress` landed for at protocol 23.

This is the same rule as the counter's, one layer up: a sentence is a claim, and a claim
has to be paid for by evidence the head actually has. `letibot`'s own word for the
failure is the anti-pattern this whole document keeps finding."
  (let ((*carry-outstanding* nil) (*carry-last-done* nil) (*carry-moved-at* nil)
        (*now-ms* 0) (*pane-scroll* 0))
    (let ((text (segs-of (carry-line (%carry-head 4000 10) 100))))
      (is (search "3990 rows announced, waiting for the daemon to send them" text)
          "it says how many rows and who owes them")
      (is (not (search "reseat" text)) "and not that a reseat is happening")
      (is (not (search "carrying" text)) "nor that anything is being carried")
      (is (not (search "conversation" text)) "nor which conversation it would be"))
    ;; and the stalled sentence names a consequence rather than a cause too
    (setf *carry-moved-at* 1000 *now-ms* 1000)
    (%carry-land (%carry-head 4000 10) 1 1)
    (setf *carry-moved-at* 1000 *now-ms* (+ 1000 leticl::+body-patience-ms+))
    (let ((text (segs-of (carry-line (%carry-head 4000 10) 100))))
      (is (search "announced and never filled in" text)
          "stalled, it says what did not happen")
      (is (not (search "reseat" text)) "and still not why"))))

(def-test a-carry-is-one-line-and-not-a-screen-of-placeholders (:suite leticl)
  "The four states the operator asked for, in one place: what it says at the start,
in the middle, when it stalls, and when it is done.

    start      ▐░░░░░░░▌     0 of 2.7k rows  (=^.^=)
               carrying the conversation onto the new prompt
    middle     ▐██████████░░░▌  1.4k of 2.7k rows  (=^o^=)~
               carrying the conversation onto the new prompt
    stalled    3 rows announced and never filled in — the daemon said they exist
               and did not send them
    done       nothing at all — the line removes itself

**The bar is two-valued**: landed cells are `█` and the rest `░`, and `▓` — the
prefill's `processed`, the band that means *being computed now and costing you* —
never appears, because a carry spends nothing. The reference paints that band with its
`cache` role for exactly this reason (*\"that one is yellow\"*, on the first version),
and here it is carried in the GLYPH, so it survives a terminal with no colour at all."
  (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 1000) (*pane-scroll* 0))
    (let ((*now-ms* 0))                        ; no clock: never stalled
      ;; --- START
      (let* ((lines (carry-line (%carry-head 2702 0) 100))
             (text (segs-of lines)))
        (is (= 3 (length lines)) "a blank, the bar row, the sentence")
        (is (search "0 of 2702 rows" text) "it starts at nothing of everything")
        (is (= (length (leticl::%carry-counts-text 0 2702))
               (length (leticl::%carry-counts-text 1400 2702)))
            "and the count is right-aligned in its own denominator's width")
        (is (search "2702 rows announced, waiting for the daemon to send them" text)
            "and says what it knows — how many rows, and that they are awaited")
        (is (find #\░ text) "the bar is all remaining")
        (is (not (find #\█ text)) "no cell is filled")
        (is (not (find #\▓ text)) "and none is claimed as being worked on")
        (is (find #\= text) "with the cat in its slot"))
      ;; --- MIDDLE
      (let* ((lines (carry-line (%carry-head 2702 1400) 100))
             (text (segs-of lines)))
        (is (search "1400 of 2702 rows" text) "halfway, the count is halfway")
        (is (find #\█ text) "half the bar is settled")
        (is (find #\░ text) "and half is not")
        (is (not (find #\▓ text)) "still nothing being worked on"))
      ;; --- DONE: the line removes itself, with no state left behind
      (is (null (carry-line (%carry-head 2702 2702) 100))
          "the last body lands and the line is gone")
      (is (null *carry-last-done*) "and it forgets the carry it was measuring"))
    ;; --- STALLED: the count has not moved for longer than the window
    (setf *carry-last-done* nil *carry-moved-at* nil *now-ms* 1000)
    (let ((h (%carry-head 2702 1)))
      ;; **the premise first**: while the count MOVES, the bar is drawn — so the
      ;; stall assertion below cannot pass by the line drawing nothing ever
      (is (search "announced, waiting for the daemon" (segs-of (carry-line h 100)))
          "the premise: a fresh carry draws the bar")
      (%carry-land h 1 1)
      (setf *now-ms* 1100)                     ; it moved
      (is (search "1 of 2702 rows" (segs-of (carry-line h 100)))
          "the premise: a body arriving moves the count")
      (setf *now-ms* (+ 1100 leticl::+body-patience-ms+))
      (let* ((lines (carry-line h 100))
             (text (segs-of lines)))
        (is (= 2 (length lines)) "stalled, it is TWO rows: the blank and the sentence")
        (is (not (search "announced, waiting for the daemon" text))
            "and it no longer claims rows are still coming")
        (is (not (find #\░ text)) "the bar is gone too")
        (is (search "2701 rows announced and never filled in" text)
            "it says how many rows the daemon said exist and did not send")
        (is (search "did not send them" text) "and whose fault that is")))))

(def-test the-carry-line-counts-the-rows-in-front-of-it (:suite leticl)
  "**The reference's own regression, and the operator's ruling: the counter is the fact,
not a rendering of it.**

It was an incremental tally — `+1` per announcement, `-1` per body. That is correct for
the live case and wrong for the case the line exists for: a fork delivers a SNAPSHOT,
the item vector is replaced wholesale, and the tally then describes rows that are no
longer there. Every later arrival missed its lookup and the bar sat at zero for the
whole carry — *\"so, counter wasnt moving - 0 always\"*.

So the assertion is that the count follows the ROWS THAT ARE THERE NOW, after the
vector has been replaced under it — and the premise is asserted first, because a test
that replaces nothing proves nothing."
  (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 0) (*pane-scroll* 0)
        (h (%carry-head 100 0)))
    ;; premise: a first carry is under way, and it is being measured
    (is (search "0 of 100 rows" (segs-of (filling-progress-line nil "rows" 0 100 100)))
        "an hundred rows, none landed — the renderer, called directly, so this premise
         does not depend on the threshold")
    ;; **the fork lands**: the vector is REPLACED by a different one, and this is what a
    ;; tally cannot survive
    (let ((before (session-items (head-session h))))
      ;; **the fork lands**: a snapshot with every one of its four rows bodiless, then
      ;; one body follows — the wire's order, and the order a tally cannot survive
      (ingest-snapshot (head-session h) (%carry-snapshot 4000 0))
      (%carry-land h 1 1)
      (is (not (eq before (session-items (head-session h))))
          "the premise: the snapshot really does replace the item vector")
      (is (= 4000 (length (session-items (head-session h)))))
      ;; a tally would still be counting the old hundred. The fact is these four
      ;; thousand.
      (is (search "1 of 4000 rows" (segs-of (carry-line h 100)))
          "the count is the rows that are here now, and how many of them arrived"))
    ;; and the two numbers are ONE measurement, off the same walk
    (multiple-value-bind (total done) (leticl::%carry-counts (head-session h))
      (is (= 4000 total) "the denominator is the rows there are")
      (is (= 1 done) "and the numerator the rows that have arrived"))))

(def-test the-carry-line-holds-still-while-it-runs (:suite leticl)
  "**Every field that can change width sits to the LEFT of everything that cannot.**

The operator: *\"move cat to the right most position or thngs jump around\"*. Two things
vary as a carry runs — the numerator, which grows from `0` to `2.7k`, and the cat,
whose frames are eight and nine columns — so the numerator is right-aligned in the
width of its own denominator and the cat occupies a fixed slot. The bar's width is
fixed by the columns rather than by the fraction, which leaves the bar's edge as the
one thing on the row that is meant to move.

Both premises are asserted before the conclusion, because a constant width proves
nothing if nothing varied."
  (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*pane-scroll* 0)
        (widths nil) (cats nil))
    ;; premise one: the numerator really does change width across the run
    (is (not (= (length (thousands 0)) (length (thousands 2702))))
        "the premise: the numerator grows from one column to four")
    ;; premise two: the sampled ticks really do walk the animation
    (dolist (tick (list 0 200 400 600 800 1000))
      (pushnew (cat-frame tick) cats :test #'string=))
    (is (> (length cats) 1) "the premise: the ticks hit more than one cat frame")
    (dolist (done (list 0 7 99 100 999 1000 1400 2701))
      (dolist (tick (list 0 200 400 600 800 1000))
        (let ((*now-ms* tick))
          (let ((row (second (carry-line (%carry-head 2702 done) 100))))
            (push (leticl::%carry-row-width row) widths)))))
    (is (= 1 (length (remove-duplicates widths)))
        (format nil "one width throughout; got ~s" (remove-duplicates widths)))))

(def-test the-carry-line-degrades-by-deletion-like-the-prefill-line (:suite leticl)
  "A carry on a narrow terminal still has to say how far along it is.

`prefill-line`'s own rule, and the same order: the bar is the most expensive field and
the least load-bearing, the count is the fact, the cat is decoration. A row that
overflowed would have its tail silently dropped by the painter — the `§6` gap — and
`1400 of` is not a progress line."
  (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 0) (*pane-scroll* 0))
    (flet ((row (cols) (segs-of (list (second (carry-line (%carry-head 2702 1400) cols))))))
      ;; wide: bar, count and cat
      (let ((wide (row 100)))
        (is (find #\▐ wide) "an hundred columns holds the bar")
        (is (search "1400 of 2702 rows" wide) "the count")
        (is (find #\= wide) "and the cat"))
      ;; the bar goes first, and the count and the cat stay
      (let ((narrow (row 30)))
        (is (not (find #\▐ narrow)) "thirty columns gives the bar up")
        (is (search "1400 of 2702 rows" narrow) "and keeps the count, which is the fact")
        (is (find #\= narrow) "and the cat"))
      ;; then the cat, and the count alone is still true
      (let ((narrower (row 20)))
        (is (not (find #\= narrower)) "twenty gives up the cat too")
        (is (search "1400 of 2702 rows" narrower) "leaving the count"))
      ;; and past that the count itself is cut with disclosure rather than silently
      (let ((tiny (row 12)))
        (is (<= (string-width tiny) 12) "twelve columns is twelve columns")
        (is (find #\… tiny) "and what was cut says so")))))

(def-test a-small-batch-draws-no-bar-but-is-still-diagnosed (:suite leticl)
  "**The threshold gates the BAR, not the sentence** — and the difference is the only
place a row the daemon announced and never sent is ever reported.

A batch under `+carry-min-rows+` gets no bar: a bar with a cat on it for three rows is
noise dressed as information. But if those rows never land, the operator is told, which
is how they learned about a real daemon-side hole in the first place (letibot `7b9ca62`:
a row exists only on `transcript_appended` and a body only on `transcript_content`, so a
turn that ends between the two leaves the hole in the daemon's log and no head can close
it).

The bug this test was written for: the threshold arm used to CLEAR the movement clock on
every frame, so a small batch could never reach the patience arm at all. Measured on the
live head — a two-row batch that never landed drew nothing, which is the one thing the
sentence exists to prevent."
  (let ((*carry-outstanding* nil) (*carry-last-done* nil) (*carry-moved-at* nil)
        (*now-ms* 1000) (*pane-scroll* 0))
    (let ((h (%make-head)))
      (note-carry (list (list :item-id "tiny1" :item nil)
                        (list :item-id "tiny2" :item nil)))
      (setf (session-items (head-session h))
            (coerce (list (list :item-id "tiny1" :kind "user" :item nil)
                          (list :item-id "tiny2" :kind "user" :item nil))
                    'vector))
      ;; moving: no bar, and no sentence either — nothing is wrong yet
      (is (null (carry-line h 100))
          "two rows under the threshold draw no bar")
      ;; past the patience: the sentence, and STILL no bar
      (setf *now-ms* (+ 1000 leticl::+body-patience-ms+ 1))
      (let* ((lines (carry-line h 100))
             (text (segs-of lines)))
        (is (= 2 (length lines)) "the blank and the sentence")
        (is (search "2 rows announced and never filled in" text)
            "a batch too small for a bar is still worth the truth")
        (is (not (find #\▐ text)) "and it draws no bar")))
    ;; the control: one row over the threshold DOES get a bar
    (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 1000)
          (h (%make-head)))
      (note-carry (loop for i from 1 to 100 collect (list :item-id (format nil "b~d" i) :item nil)))
      (setf (session-items (head-session h))
            (coerce (loop for i from 1 to 100
                          collect (list :item-id (format nil "b~d" i) :kind "user" :item nil))
                    'vector))
      (is (find #\▐ (segs-of (carry-line h 100)))
          "a hundred rows is a carry and gets the bar"))))

(def-test a-carry-does-not-grow-the-screen (:suite leticl)
  "The reason the line exists: two thousand seven hundred announced rows used to be two
thousand seven hundred placeholder rows — *\"insane amount of grainess\"* — and the
screen must not grow with the carry at all."
  (let ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 1000) (*pane-scroll* 0)
        (*hist-cache* nil) (*hist-generation* 0))
    ;; **the big one FIRST**: the carry is one announcement, and building the small head
    ;; second would replace it — the same single-defvar shape the head has in production,
    ;; where there is one of it. (Two heads in one IMAGE share it; the suite runs
    ;; hundreds, so a fixture measures one carry at a time.)
    (let* ((big (%carry-head 2702 0))
           (big-lines (leticl::%viewport-lines big 100 20))
           (small (%carry-head 3 0))
           (small-lines (leticl::%viewport-lines small 100 20)))
      ;; **the claim is "not proportional"**: three rows is the whole cost, and under the
      ;; design this replaces it would have been 2702 rows each with its own placeholder.
      ;; The small frame is not a shorter version of the big one — with no line to draw and
      ;; no rows to show, it is the empty-session banner, which is a different screen and
      ;; not a smaller one.
      (is (= 3 (length big-lines))
          "2702 announced rows draw three lines: the blank, the bar and the sentence")
      (is (not (search "said nothing yet" (segs-of big-lines)))
          "and the screen is not the empty-session banner")
      (is (search "announced, waiting for the daemon" (segs-of big-lines))
          "and the one line is on the screen, at the tail")
      (is (not (search "announced, waiting for the daemon" (segs-of small-lines)))
          "while three rows — under the threshold — draw no line at all"))))

(def-test the-carry-line-goes-when-the-last-body-lands (:suite leticl)
  "It removes itself: the last body to arrive takes the count to zero, and the block
leaves the frame with no state behind it — so the next carry measures itself and not
the one before."
  (let* ((*carry-last-done* nil) (*carry-moved-at* nil) (*now-ms* 0) (*pane-scroll* 0)
         (*hist-cache* nil) (*hist-generation* 0)
         (h (%carry-head 4000 0)))
    (is (search "announced, waiting for the daemon"
                (segs-of (leticl::%viewport-lines h 100 20)))
        "the carry is on the screen")
    (%carry-land h 1 4000)
    (is (not (search "announced" (segs-of (leticl::%viewport-lines h 100 20))))
        "and it is gone once every row has arrived")
    (is (null leticl::*carry-last-done*) "with nothing remembered about it")
    (is (null leticl::*carry-outstanding*) "and the carry itself is forgotten")))

;;; ------------------------- what landed in letibot 2deceb8..03cb812 (2026-09-20) ;;;

(def-test a-provider-switch-reaches-an-already-attached-head (:suite leticl)
  "The reference's own reproduction (`03cb812`): the `model` settings row is read
once at attach and never pushed again, so a provider switch left the header on
`qwen-3.8-27b` while `/config` said `deepseek/deepseek-flash`. The header takes
whichever it was told more recently, by seq."
  (let* ((leticl::*model-from-settings-at* 0) (leticl::*model-from-turn-at* 0)
         (h (%make-head))
         (s (head-session h))
         (*head* h))
    ;; **contiguous seqs on purpose**: the ordering this asserts is by seq, and a
    ;; deliberate jump would be a gap the head now reports instead of folding (see
    ;; `a-gap-in-the-event-stream-is-said-counted-and-filed`)
    (setf (session-seq s) 5
          (head-settings h) (list (list :key "model" :value "qwen-3.8-27b"))
          leticl::*model-from-settings-at* 5)
    (is (string= "qwen-3.8-27b" (leticl::%model-name s)) "the attach state")
    ;; a turn starts on another provider, later in the stream
    (apply-event s (list :seq 6 :event "turn_started" :turn-id "t1"
                         :model "deepseek/deepseek-flash" :ledger-head "0000"))
    (is (string= "deepseek/deepseek-flash" (leticl::%model-name s))
        "the switch reaches the header: the turn's word is newer")
    ;; and a fresh settings row, newer still, wins back
    (setf (session-seq s) 7
          (head-settings h) (list (list :key "model" :value "grok/grok-4"))
          leticl::*model-from-settings-at* 7)
    (is (string= "grok/grok-4" (leticl::%model-name s)) "the row is the newest again")))

(def-test a-subagents-answer-is-its-output (:suite leticl)
  "letibot `2ac6200`: *\"when i go to subagents pane … when i enter - no output\"*.
A digest subagent calls no tools and answers in prose; the pane drew only tool
results and said there was nothing. Its answer is rendered in order beside them,
reasoning stays out, and the empty case says what it means."
  (let ((lines (leticl::subagent-out-lines
                (list (list :seq 1 :event "transcript_content" :item-id "a"
                            :item (list :type "reasoning" :text "hmm"))
                      (list :seq 2 :event "transcript_content" :item-id "b"
                            :item (list :type "tool_result" :name "bash"
                                        :outcome (list :outcome "ok")
                                        :payload (format nil "one~%two~%")))
                      (list :seq 3 :event "transcript_content" :item-id "c"
                            :item (list :type "assistant"
                                        :text "**Nothing here bears on it.**"))))))
    (is (equal '("· bash — ok" "  one" "  two" "" "**Nothing here bears on it.**" "") lines)
        "tool result, then the answer, in order; the reasoning is not there"))
  (let* ((h (%make-head))
         (leticl::*peeked-session* "s-1#sub-42") (leticl::*peeked-dropped* 0))
    (setf (head-peeked h) nil)
    (let ((text (lines-text (peek-lines h 120))))
      (is (search "subagent output — " (first text)) "the title names the subagent")
      (is (some (lambda (l) (search "neither an answer nor tool output" l)) text)
          "and the empty case says what it means, not \"no tool output\""))))


(def-test ctrl-c-draws-the-quit-card-and-a-second-press-stays (:suite leticl)
  "The operator: *\"Cc doesnt work - scrolls up one line, status shows 1/2 and
nothing\"*. `%render` measured the card's height from the DECISION card — NIL when
ctrl-c opens this one — so the quit card was placed a row below the body while the
transcript still gave up the rows for it. And the reference's second ctrl-c CLOSES
the card (its hint bar stopped promising \"again to exit\" the day a card started
opening); ours left."
  (let* ((*stdout* (make-string-output-stream))
         (leticl::*ctrlc-at* nil)
         (h (%on-head :cols 80 :rows 24)))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (not (head-quit-open h)) "one ctrl-c on an empty composer only ARMS")
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (head-quit-open h) "and the second within the window opens the card")
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "leave — and what happens to the daemon" text) "and the card is ON the screen")
      (is (search "▸  1  leave this head" text) "with its first choice picked")
      (is (search "prefills cold" text)
          "and its LAST line is on the screen too, not under the box's top edge")
      (is (search "╭" text) "with the box still whole"))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (not (head-quit-open h)) "a ctrl-c with the card up closes it")
    (is (leticl::head-running h) "and the head stays")
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (leticl::%handle-key h (list :type :down))
    (is (= 1 (leticl::head-quit-sel h)) "down picks the second choice")
    (leticl::%handle-key h (list :type :char :ch #\1))
    (is (not (leticl::head-running h)) "and a digit chooses: 1 leaves")))


(def-test a-socket-that-is-not-there-is-no-daemon (:suite leticl)
  "The operator: *\"why when I opened leticl in a folder that doesnt belong to any
running or known project it brought me to the latest leticl conversation?\"*.
`discover-daemons` answered the WHOLE run dir when `$LETIBOT_SOCKET` matched
nothing, and `run` took the first daemon listed. A named socket that is not there
is no daemon."
  (let ((dir (uiop:ensure-directory-pathname
              (format nil "/tmp/claude-1000/-home-dead-Projects-leticl/3603a50c-c42f-4b18-87ce-b917064534c9/scratchpad/daemons-~d/" (random 100000)))))
    (ensure-directories-exist dir)
    (with-open-file (o (merge-pathnames "abc.json" dir) :direction :output :if-exists :supersede)
      (write-string "{\"socket\":\"/run/x/abc.sock\",\"workspace\":\"/home/dead/Projects/other\"}" o))
    (let ((real (symbol-function 'leticl::daemon-dir)))
      (unwind-protect
           (progn
             (setf (symbol-function 'leticl::daemon-dir) (lambda () dir))
             (setf (uiop:getenv "LETIBOT_SOCKET") "/run/x/nothing-here.sock")
             (is (null (discover-daemons))
                 "a socket nobody listens at is no daemon — not the first one in the run dir")
             (setf (uiop:getenv "LETIBOT_SOCKET") "/run/x/abc.sock")
             (is (equal "/run/x/abc.sock" (getf (first (discover-daemons)) :socket))
                 "and the one that is there is found"))
        (setf (symbol-function 'leticl::daemon-dir) real)
        (setf (uiop:getenv "LETIBOT_SOCKET") "")))))

(def-test the-caret-follows-the-text-being-typed (:suite leticl)
  "Where the caret sits is a position in the BUFFER, so the composer's rows have
to be the buffer wrapped — they used to be its lines truncated at the box's edge,
which put the caret off the screen as soon as a line ran long. The prompt is on
the first row only, and a continuation row is indented by its width."
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 40 :rows 24)))
    (leticl::%render h)
    ;; an empty composer: the caret is just after `│ › `
    (destructuring-bind (row . col) leticl::*caret*
      (is (= (+ 2 4) col) "four columns in: the wall, its space, and the prompt")
      (is (plusp row) "on the composer's first body row"))
    ;; typed text moves it along, and the row does not
    (composer-insert (head-composer h) "hello")
    (leticl::%render h)
    (is (= (+ 2 4 5) (cdr leticl::*caret*)) "five characters later, five columns on")
    ;; a newline puts it on the next row, at the indent rather than the prompt
    (composer-insert (head-composer h) (format nil "~%ab"))
    (leticl::%render h)
    (is (= (+ 2 4 2) (cdr leticl::*caret*)) "the second row's text starts under the first's")
    ;; and a line longer than the box WRAPS rather than being cut
    (setf (composer-buffer (head-composer h)) (make-string 100 :initial-element #\x)
          (composer-cursor (head-composer h)) 100)
    (leticl::%render h)
    (let ((rows (count-if (lambda (l) (search "xxx" l))
                          (uiop:split-string (%screen-text h) :separator '(#\newline)))))
      ;; the frame hands the composer cols less the gutter and the right margin,
      ;; and the box's walls and prompt take four more: 100 columns at 30 is four
      (is (= 4 rows) "the long line wraps to four rows rather than being cut at the box's edge")
      (is (< (cdr leticl::*caret*) 40) "and the caret is on the screen"))))

(def-test a-boolean-field-goes-out-as-a-boolean (:suite leticl)
  "`/mode NAME` closed the connection. `Mode.consented` is `consented: bool` with
`#[serde(default)]` (protocol.rs:452) — serde's default accepts a MISSING key, not
a present `null` — and our encoder writes NIL as `null`, so the daemon's read loop
broke with an Err and dropped the socket. Every mode but `allow-all` took that
path. Measured by encoding the frame."
  (let ((h (%make-head))
        (wire (make-string-output-stream)))
    (setf (leticl::head-stream h) wire (head-connected h) t)
    (leticl::%send-mode h "always-ask" nil)
    (let ((line (string-trim '(#\newline) (get-output-stream-string wire))))
      (is (search "\"consented\":false" line) "false, not null: ~a" line)
      (is (not (search "null" line)) "and nothing else on the frame is null either"))
    (leticl::%send-mode h "allow-all" t)
    (is (search "\"consented\":true" (get-output-stream-string wire)) "and the true side")))

(def-test the-head-says-what-it-has-to-say (:suite leticl)
  "**21 write sites of `head-status-note` went nowhere.** They rode `status-line`,
which `%render` drew only when there was no composer box — and a box is any screen
of eight rows or more, so on every real terminal the head was silent: `resync: …`,
`bye: …`, `detached — reconnecting…`, every `say`. The reference puts the notice
and the stall sentence in the chrome above the box (app.rs:5069-5075)."
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 80 :rows 24)))
    (say h "resync: the daemon lost our place")
    (leticl::%render h)
    (is (search "· resync: the daemon lost our place" (%screen-text h))
        "the note is on the screen, above the box")
    (is (search "╭" (%screen-text h)) "and the box is still whole")
    ;; and it is the magenta the reference paints it
    (is (equal '(:fg :magenta) (cdr (first (first (notice-line h 80))))))
    ;; the stall sentence only while a turn is RUNNING: a head between turns is
    ;; quiet because nothing is happening, and calling that a stall is an alarm
    ;; about ordinary rest
    (let ((*now-ms* 100000) (*last-event-ms* 0))
      (is (null (stall-row h 80)) "no running turn, no stall")
      (setf (session-turn (head-session h))
            (list :turn-id "t1" :model "deepseek/deepseek-flash"
                  :state (list :state "running")))
      (let ((text (lines-text (stall-row h 200))))
        (is (search "deepseek/deepseek-flash" (car text)) "with one, it names the model")
        (is (search "nothing received for" (car text)) "how long the silence has been")
        (is (search "esc esc interrupts it" (car text)) "and the key that ends it"))
      ;; and it is TRIMMED to the width, as the reference's is: a narrow screen
      ;; gets the front of the sentence rather than a wrapped paragraph
      (is (<= (string-width (car (lines-text (stall-row h 80)))) 80)
          "trimmed to the width it has")
      (leticl::%render h)
      (is (search "nothing received for" (%screen-text h)) "and it reaches the screen"))))

(def-test the-terminal-comes-back-from-anywhere (:suite leticl)
  "**A crash must not cost the operator their terminal.** The head runs raw, on
the alternate screen, with the cursor hidden, and `with-tui-terminal`'s
`unwind-protect` gives all three back when the stack UNWINDS — which an unhandled
error in a saved executable does not do: it enters the debugger, which prints onto
a raw alternate screen nobody will ever leave. `reset` was the only way out. The
image's toplevel now restores from its debugger hook, the way the reference
restores from its panic hook (term.rs:191-197)."
  (let ((out (make-string-output-stream)))
    (is (eq t (restore-terminal out)) "it answers, and does not signal")
    (let ((bytes (get-output-stream-string out)))
      (dolist (seq '("[?2026l" "[?1006l" "[?1002l" "[?2004l" "[0 q" "[?25h" "[?1049l"))
        (is (search seq bytes)
            "~a — synchronized output, the mouse, bracketed paste, the cursor shape, the cursor and the alternate screen all come back"
            seq))))
  ;; twice in a row is a no-op, because it runs where things are already wrong
  (is (eq t (restore-terminal (make-string-output-stream))) "idempotent"))

(def-test an-unreadable-prefs-file-is-a-note-not-a-refusal (:suite leticl)
  "The parser already treated a bad LINE that way, but the READ was unguarded: a
`head.toml` owned by another user, or holding bytes that are not UTF-8, signalled
out of `load-prefs-into` and the head never started — the operator's own
preferences file locking them out of the tool."
  (let* ((dir "/tmp/claude-1000/-home-dead-Projects-leticl/3603a50c-c42f-4b18-87ce-b917064534c9/scratchpad/")
         (path (merge-pathnames (format nil "badprefs-~d.toml" (random 100000)) dir)))
    (ensure-directories-exist dir)
    ;; bytes that are not valid UTF-8
    (with-open-file (o path :direction :output :element-type '(unsigned-byte 8)
                            :if-exists :supersede)
      (write-sequence (coerce '(255 254 253 10) '(vector (unsigned-byte 8))) o))
    (multiple-value-bind (p notes) (load-prefs path)
      (is (not (null p)) "it still answers a prefs")
      (is (string= "split" (prefs-diff p)) "with the defaults kept")
      (is (some (lambda (n) (search "cannot be read" n)) notes)
          "and says so once, rather than refusing to start"))))

;;; ------------------- the protocol surface, measured (docs/parity/wire.md) ;;;
;;;
;;; Every test below is one finding from `docs/parity/wire.md` — the frames, the
;;; events, the session fold and the exchange, each cited on both sides against
;;; letibot at 8af671e. A fold that writes nowhere and a frame that does not
;;; survive contact with the daemon look identical from inside this head: the
;;; state is simply not there. These are the assertions that tell them apart.

(defun %fake-daemon (head)
  "Put a string stream where HEAD's socket would be, and answer a reader of
every frame it has written since, decoded, NEWEST FIRST.

The pattern the picker tests use (`tests.lisp:1772`): the assertion is what went
out ON THE WIRE, not what a function returned, because a frame that is built and
never sent is the defect this whole document is about."
  (let ((wire (make-string-output-stream)))
    (setf (leticl::head-stream head) wire (head-connected head) t)
    (lambda ()
      (nreverse (mapcar #'json-decode
                        (remove "" (uiop:split-string (get-output-stream-string wire)
                                                      :separator '(#\newline))
                                :test #'string=))))))

(defun %repo-file (relative)
  "One file from the repo root, for a test that greps a source rather than
trusting a rule in a document."
  (let ((p (merge-pathnames relative (or *load-truename* #p"./"))))
    (if (probe-file p)
        (uiop:read-file-string p)
        (uiop:read-file-string (merge-pathnames relative #p"/home/dead/Projects/leticl/")))))

(def-test a-hello-with-no-snapshot-is-a-resume-not-a-crash (:suite leticl)
  "**No reconnect and no resume had ever worked.** `%try-reconnect` re-attaches
with `since_seq = session-seq`, which is nonzero, so the daemon serves the gap
from its ring and answers `Hello { snapshot: null, resumed_from: N }`
(hub.rs:628-652). `ingest-hello` called `ingest-snapshot` unconditionally, which
assigned `session-session-id` to \"\" and then `(getf nil :seq)` = NIL into a
`:type fixnum` slot and signalled a TYPE-ERROR — swallowed by `run-loop` into
`*last-render-error*`, so the head neither crashed nor recovered. Measured:
`RESUME-ERROR: TYPE-ERROR` against `SNAPSHOT-OK` for the same Hello with a
snapshot. What follows the raise is the whole of the injury: the id already
wiped, `head_id`/`wiring`/`sessions`/title/`resumed_from` never read, the
settings never asked for, and `*attach-started-ms*` never cleared — the attach
cat walking forever over a head folding a backlog into a session whose id it had
just forgotten."
  (let* ((line "{\"frame\":\"hello\",\"protocol_version\":22,\"session_id\":\"s-1\",\"head_id\":\"h1\",\"dropped\":2,\"snapshot\":null,\"resumed_from\":42,\"scrubbed\":{\"deltas\":3,\"tool_progress\":1},\"wiring\":{\"model\":\"deepseek/deepseek-flash\",\"role\":\"main\"},\"sessions\":[{\"session_id\":\"s-1\",\"title\":\"the resumed one\"}]}")
         (hello (json-decode line))
         (s (make-session))
         (*scrubbed-total* 0)
         (leticl::*turn-started-ms* nil))
    (finishes (ingest-hello s hello))
    (is (string= "s-1" (session-session-id s)) "the id is the Hello's own, not the empty string")
    (is (= 42 (session-seq s)) "the mark is where we asked to resume from")
    (is (= 42 (session-expected-seq s)) "and so is what the next command carries")
    (is (string= "h1" (session-head-id s)) "the head id is read")
    (is (equal "deepseek/deepseek-flash" (getf (session-wiring s) :model)) "the wiring is read")
    (is (string= "the resumed one" (session-title s)) "and the title, out of the session list")
    (is (= 2 (session-dropped s)) "the dropped count is taken")
    (is (= 4 *scrubbed-total*) "and the scrub report is summed")
    ;; and at the head: connected, the cat stood down, and the settings asked for
    (let* ((h (%make-head))
           (sent (%fake-daemon h))
           (*attach-started-ms* 1234))
      (leticl::%handle-frame h hello)
      (is (eq t (head-connected h)) "the head is attached")
      (is (null *attach-started-ms*) "the attach clock is cleared")
      (is (member "settings" (mapcar (lambda (f) (getf f :frame)) (funcall sent))
                  :test #'equal)
          "and the settings the `hello` arm owes are on the wire"))))

(def-test a-started-tool-is-running-not-proposed (:suite leticl)
  "`ensure-call` was `(or (leticl::call-view …) (push …))`, so a call that already
existed as `proposed` was returned UNCHANGED: measured,
`CALL-STATE-AFTER-STARTED = \"proposed\"`, and the card drew `○ … · proposed`
for the whole run instead of `◐ … · 1.4s`. The reference sets Running, restarts
the clock and clears the note (app.rs:2356-2400, view.rs:523-536)."
  (let ((s (make-session))
        (leticl::*turn-started-ms* nil) (*call-facts* nil) (*call-started-ms* nil)
        (*call-targets* nil))
    (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 2 :event "tool_call_proposed" :turn-id "t1"
                         :call-id "c1" :name "bash" :args-digest "d" :target "ls"))
    (apply-event s (list :seq 3 :event "tool_started" :turn-id "t1"
                         :call-id "c1" :name "bash"))
    (let ((call (leticl::call-view (session-turn s) "c1")))
      (is (equal "running" (getf (getf call :state) :state))
          "the proposed row MOVED to running")
      (is (equal "ls" (getf call :target)) "and kept the target only the proposal carried"))
    (is (= 1 (length (getf (session-turn s) :calls))) "one row, not two")
    ;; a call whose proposal this head never saw still gets a row
    (apply-event s (list :seq 4 :event "tool_started" :turn-id "t1"
                         :call-id "c2" :name "read"))
    (is (equal "running" (getf (getf (leticl::call-view (session-turn s) "c2") :state) :state))
        "a call first seen as started is created, running")))

(def-test a-progress-note-lands-on-the-call-in-the-turn (:suite leticl)
  "`(setf (getf call :progress-note) …)` on a LOCAL holding a plist whose key is
ABSENT conses a new head and assigns the local — the list inside `turn.calls` is
never touched. Measured: `PROGRESS-NOTE-AFTER-FINISH = NIL`. Every tool-progress
note this head had ever folded went nowhere, with the card's slot for it
(cards.lisp:942) permanently empty. Read back off the TURN, never off the return
value of the setter."
  (let ((s (make-session))
        (leticl::*turn-started-ms* nil) (*call-facts* nil) (*call-started-ms* nil)
        (*call-targets* nil))
    (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 2 :event "tool_call_proposed" :turn-id "t1"
                         :call-id "c1" :name "bash" :args-digest "d" :target "ls"))
    (apply-event s (list :seq 3 :event "tool_progress" :turn-id "t1"
                         :call-id "c1" :note "asking the guard"))
    (is (equal "asking the guard"
               (getf (leticl::call-view (session-turn s) "c1") :progress-note))
        "the note is on the call the TURN holds")
    ;; and the note a call collects while PROPOSED is about the decision, so the
    ;; run clears it: a stale one cost an operator an hour (app.rs:2365-2386)
    (apply-event s (list :seq 4 :event "tool_started" :turn-id "t1"
                         :call-id "c1" :name "bash"))
    (is (null (getf (leticl::call-view (session-turn s) "c1") :progress-note))
        "starting the tool clears the note that was about the decision")
    (apply-event s (list :seq 5 :event "tool_progress" :turn-id "t1"
                         :call-id "c1" :note "12 of 40"))
    (apply-event s (list :seq 6 :event "tool_finished" :turn-id "t1"
                         :call-id "c1" :outcome "ok" :inline-bytes 3 :full-bytes 3))
    (is (null (getf (leticl::call-view (session-turn s) "c1") :progress-note))
        "and finishing clears it: the note measured a moment that has passed")))

(def-test the-token-counter-is-taken-not-assigned (:suite leticl)
  "`setf` walks the counter BACKWARDS on a reordered or duplicated frame —
measured, `50` then `10` left `10`. Both the reference and the view use `max`
for exactly that (app.rs:2281, view.rs:419)."
  (let ((s (make-session)) (leticl::*turn-started-ms* nil))
    (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 2 :event "tokens_generated" :turn-id "t1" :tokens 50))
    (apply-event s (list :seq 3 :event "tokens_generated" :turn-id "t1" :tokens 10))
    (is (= 50 (getf (session-turn s) :tokens)) "the counter cannot move backwards")
    (apply-event s (list :seq 4 :event "tokens_generated" :turn-id "t1" :tokens 188))
    (is (= 188 (getf (session-turn s) :tokens)) "and still climbs")))

(def-test a-finished-turn-has-no-progress (:suite leticl)
  "*\"A progress frame is true only while it is happening\"* (view.rs:254-256).
Nothing cleared it, so a finished turn kept the prefill bar of the prompt it had
already answered: measured, `:progress` still held `(:TOTAL 10 …)` after
`turn_finished`. All three terminal arms clear it on both sides (app.rs:2565,
2596, 2619; view.rs:572, 588, 608)."
  (dolist (ending '("turn_finished" "turn_interrupted" "turn_failed"))
    (let ((s (make-session)) (leticl::*turn-started-ms* nil))
      (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
      (apply-event s (list :seq 2 :event "prompt_progress" :turn-id "t1"
                           :total 10 :cache 2 :processed 4 :time-ms 90))
      (is (consp (getf (session-turn s) :progress)) "while it runs, the progress is there")
      (apply-event s (list :seq 3 :event ending :turn-id "t1" :finish-reason "stop"))
      (is (null (getf (session-turn s) :progress))
          (format nil "~a clears the progress" ending)))))

(def-test the-rows-a-turn-published-are-recorded-in-order (:suite leticl)
  "`turn.appended` was initialised at `turn_started` and written by NOTHING, so
the field was dead — measured, `:appended` was NIL before and after.
`view.rs:246-253` says what it is for: *\"a head shows a running turn from
text/reasoning and a finished one from the transcript, and it needs to know which
rows are the finished form or it renders the answer twice\"* (app.rs:2650-2651)."
  (let ((s (make-session)) (leticl::*turn-started-ms* nil))
    (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 2 :event "transcript_appended" :item-id "i1" :kind "assistant"))
    (apply-event s (list :seq 3 :event "transcript_appended" :item-id "i2" :kind "tool_result"))
    (is (equal '("i1" "i2") (getf (session-turn s) :appended))
        "both ids, in the order they landed")))

(def-test a-frame-from-another-turn-is-consumed-and-not-folded (:suite leticl)
  "Measured: a `delta` carrying `turn_id \"OTHER\"` appended to the CURRENT
turn's text and reported `:dirty`. The reference and the view both require the id
to match before folding and return Filtered when it does not (app.rs:2278-2297,
view.rs:406-419). Benign on one turn at a time, load-bearing the moment
concurrent subagents publish on one hub — and the seq still advances, because a
filtered frame is consumed."
  (let ((s (make-session)) (leticl::*turn-started-ms* nil))
    (apply-event s (list :seq 1 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 2 :event "delta" :turn-id "t1" :target "text" :text "mine"))
    (is (eq :quiet (apply-event s (list :seq 3 :event "delta" :turn-id "OTHER"
                                        :target "text" :text " stranger")))
        "a stranger's delta is filtered")
    (is (equal "mine" (getf (session-turn s) :text)) "and nothing of it is folded")
    (is (= 3 (session-seq s)) "but it IS consumed: the read mark advanced")
    (is (eq :quiet (apply-event s (list :seq 4 :event "tokens_generated"
                                        :turn-id "OTHER" :tokens 999))))
    (is (= 0 (getf (session-turn s) :tokens)) "tokens_generated the same")
    (is (eq :quiet (apply-event s (list :seq 5 :event "prompt_progress"
                                        :turn-id "OTHER" :total 9))))
    (is (null (getf (session-turn s) :progress)) "prompt_progress the same")
    (is (eq :quiet (apply-event s (list :seq 6 :event "turn_finished"
                                        :turn-id "OTHER" :finish-reason "stop"))))
    (is (equal "running" (leticl::turn-state-name (session-turn s)))
        "and a stranger's ending does not end this turn")
    ;; an EMPTY turn_id is not a stranger: a turn can fail before it ever
    ;; published a TurnStarted (view.rs:595-606)
    (is (eq :dirty (apply-event s (list :seq 7 :event "turn_failed" :turn-id ""
                                        :error "boom")))
        "an empty id is folded, not filtered")))

(def-test a-switch-does-not-carry-the-old-sessions-state (:suite leticl)
  "`ingest-snapshot` cleared nothing a snapshot does not carry, so a `/switch`
arrived wearing the last conversation's clothes — `app.rs:1902-1934` clears each
of these with a measured reason, the loudest being *\"1 subagent running\" on the
composer of the very subagent being looked at*. The running turn's clock went
with them: nothing cleared `leticl::*turn-started-ms*`, so the previous session's start
time kept walking under the new session's composer."
  (let ((s (make-session))
        (leticl::*turn-started-ms* nil) (*call-facts* nil) (*call-started-ms* nil))
    (ingest-snapshot s (list :session-id "s-1" :seq 1 :dropped 0 :items-dropped 0
                             :items nil :turn nil))
    (apply-event s (list :seq 2 :event "turn_started" :turn-id "t1" :model "m"))
    (apply-event s (list :seq 3 :event "subagent" :subagent-id "sa1" :state "running"))
    (apply-event s (list :seq 4 :event "job_settled" :job "j1" :state "exited 0"))
    (apply-event s (list :seq 5 :event "denial_raised" :request-id "d1" :tool "bash"))
    (apply-event s (list :seq 6 :event "command_issued" :head-id "other"
                         :identity "someone" :command "/mode" :note "ok"))
    (is (consp (session-subagents s)) "the old session had a subagent tree")
    (is (consp (session-jobs s)) "and job settlements")
    (is (consp (session-denials s)) "and denials")
    (is (consp (leticl::session-notices s)) "and notices")
    (is (numberp leticl::*turn-started-ms*) "and a running turn's clock")
    ;; the same session again: a resync is not a switch
    (ingest-snapshot s (list :session-id "s-1" :seq 7 :dropped 0 :items-dropped 0
                             :items nil :turn nil))
    (is (consp (session-subagents s)) "a resync of the SAME session keeps what it has")
    ;; a different one: none of it belongs here
    (ingest-snapshot s (list :session-id "s-2" :seq 8 :dropped 0 :items-dropped 0
                             :items nil :turn nil))
    (is (null (session-subagents s)) "the subagent tree is the PARENT's fact")
    (is (null (session-jobs s)) "the job rows are the old session's ids")
    (is (null (session-denials s)) "the denials were about another conversation")
    (is (null (leticl::session-notices s)) "and so were the notices")
    (is (null leticl::*turn-started-ms*) "and the turn clock is not this session's")))

(def-test a-hello-filters-subagents-and-adds-up-its-dropped (:suite leticl)
  "Three findings on one frame. Subagents are not sessions a picker lists — the
reference filters `parent_session_id` before STORING, on both frames that carry
the list (app.rs:1668-1671, 1732-1735). `dropped` accumulates, and was assigned,
so a reattach reset this head's running count of what it will never see. And
`head_id` was stored and read by nothing, so this head announced its OWN commands
back to itself — *\"seeing who did what is the point, and seeing yourself do what
you just did is not\"* (app.rs:2815)."
  (let ((s (make-session)) (*scrubbed-total* 0) (leticl::*turn-started-ms* nil)
        (leticl::*verbosity* :normal))
    (ingest-hello s (list :session-id "s-1" :head-id "h1" :dropped 2
                          :sessions (list (list :session-id "s-1" :title "mine")
                                          (list :session-id "sa-9" :title "a subagent"
                                                :parent-session-id "s-1"))))
    (is (= 1 (length (session-sessions s))) "the subagent row is not in the list")
    (is (equal "s-1" (getf (first (session-sessions s)) :session-id)) "the session is")
    (is (equal "mine" (session-title s)) "and the title is still found")
    (is (= 2 (session-dropped s)) "the first Hello's dropped")
    (ingest-hello s (list :session-id "s-1" :head-id "h1" :dropped 2 :sessions nil))
    (is (= 4 (session-dropped s)) "the second ADDS to it rather than replacing it")
    (is (eq :quiet (apply-event s (list :seq 9 :event "command_issued" :head-id "h1"
                                        :identity "leticl" :command "/mode"
                                        :note "ok")))
        "our own command is not said back to us")
    (is (null (leticl::session-notices s)) "and not kept as a notice either")
    (apply-event s (list :seq 10 :event "command_issued" :head-id "h2"
                         :identity "someone else" :command "/mode" :note "ok"))
    (is (= 1 (length (leticl::session-notices s))) "another head's is")))

(def-test a-settled-decision-keeps-the-advice-and-the-call (:suite leticl)
  "Three things are read off the open decision BEFORE it is removed, because the
answer event carries only the `req_id` (app.rs:2503-2524, view.rs:494-516): the
summary, the call to put the outcome on, and the oracle's ADVICE. The last is the
one the answer can never carry — its `basis` is the DECIDER's — so dropping it
here was the loss *\"nothing downstream can recover\"*."
  (let ((s (make-session)) (*call-facts* nil) (*call-started-ms* nil))
    (apply-event s (list :seq 1 :event "decision_requested" :req-id "r1"
                         :kind "permission" :call-id "c1" :summary "rm -rf /tmp/x"
                         :advice "the oracle says this is outside the workspace"
                         :options nil :ts 5))
    (apply-event s (list :seq 2 :event "decision_answered" :req-id "r1"
                         :outcome "allow_once" :by "deadtrickster" :basis "operator"
                         :late nil))
    (let ((settled (first (leticl::session-settled-decisions s))))
      (is (consp settled) "the answer settles the decision")
      (is (equal "c1" (getf settled :call-id)) "the call it gated is kept")
      (is (equal "the oracle says this is outside the workspace" (getf settled :advice))
          "and so is the advice, which nothing else carries")
      (is (equal "rm -rf /tmp/x" (getf settled :summary)) "with the summary")
      (is (null (session-open-decisions s)) "and the open one is gone"))))

(def-test a-new-session-is-seated-where-this-head-is (:suite leticl)
  "`NewSession.workspace` was always the empty string, and `protocol.rs:599-607`
records what that costs: the daemon seats the new session's read-only tools at
its OWN directory, *\"and every path in it resolved, so the only symptom was
answers about the wrong tree\"*. The reference sends its cwd (driver.rs:147-150)."
  (let* ((h (%make-head)) (sent (%fake-daemon h)))
    (leticl::%send h (make-new-session "a name" ""))
    (let ((f (first (funcall sent))))
      (is (equal "new_session" (getf f :frame)))
      (is (plusp (length (getf f :workspace))) "the workspace is not empty")
      (is (equal (leticl::%cwd-string) (getf f :workspace))
          "and it is where this head is running")
      (is (not (uiop:string-suffix-p (getf f :workspace) "/"))
          "written the way a path is written"))))

(def-test a-created-session-is-the-one-you-end-up-in (:suite leticl)
  "`Sessions.current` and `.created` were both dropped, so `/new` and
`--new TITLE` created a session and left the operator in the old one — a command
whose effect is invisible. The reference sets `session_id = current` and, when
`created` answers a request THIS head made, queues a Switch to it
(app.rs:1736-1744)."
  (let* ((h (%make-head)) (sent (%fake-daemon h)))
    ;; this head asks for one
    (leticl::%send h (make-new-session "fresh" ""))
    (is (eq t (head-want-new h)) "the ask is remembered by the sender")
    (funcall sent)                      ; drain the new_session frame
    (leticl::%handle-frame h (list :frame "sessions" :current "s-1" :created "s-2"
                                   :sessions (list (list :session-id "s-1")
                                                   (list :session-id "s-2"))))
    (let ((f (first (funcall sent))))
      (is (equal "switch" (getf f :frame)) "a switch went out")
      (is (equal "s-2" (getf f :session-id)) "to the session that was just created"))
    (is (null (head-want-new h)) "and the ask is spent, not standing")
    (is (equal "s-1" (session-session-id (head-session h)))
        "`current` is read: it is the daemon's word for where this connection is")
    ;; a plain listing moves nothing
    (leticl::%handle-frame h (list :frame "sessions" :current "s-1"
                                   :sessions (list (list :session-id "s-1")
                                                   (list :session-id "sa-1"
                                                         :parent-session-id "s-1"))))
    (is (null (funcall sent)) "a listing with no `created` sends nothing")
    (is (= 1 (length (session-sessions (head-session h))))
        "and the subagent row is filtered out of the picker's list here too")))

;;; --------------- R16: a queued echo across a compaction -------------------- ;;;
;;;
;;; MEASURED with the instruction R16 itself gives — *"queue a prompt and force a
;;; compaction under it"* — and this head FAILED it:
;;;
;;;     queued before the compaction      ("third thing" "second thing" "first thing")
;;;     the snapshot LANDED (seq/items)   (900 4)
;;;     the rows the echoes wait for       ("first thing" "second thing" "third thing")
;;;     queued AFTER                      ("third thing" "second thing" "first thing")
;;;
;;; All three prompts were in the transcript the snapshot carried and all three
;;; echoes still read `queued`. `%retire-pending` is reached from the live
;;; `transcript_content` arm and NOWHERE ELSE, so **a row that arrives inside a
;;; snapshot retires nothing, for the life of the session.**

(defun %snapshot-with (items &key (id "s-r16") (dropped 0))
  (list :session-id id :seq 900 :dropped 0 :items-dropped dropped
        :turn nil :open-decisions nil :settled-decisions nil :warnings nil :heads nil
        :items items))

(defun %a-user-row (item-id text)
  (list :item-id item-id :kind "user" :ts 0
        :item (list :type "user" :parts (list (list :kind "text" :text text)))))

(def-test a-snapshot-retires-the-echoes-whose-rows-it-carries (:suite leticl)
  "R16's own instruction, run: queue prompts, then force a compaction whose snapshot
carries their rows.

The prompt's row arriving INSIDE a snapshot is the case the live path cannot see — the
transcript takes the words over by being them, and a snapshot is not a
`transcript_content` frame. So the same TEXT match has to be made against the snapshot
too, and through the SAME function, or the two paths retire different things."
  (let* ((leticl::*queued-unconfirmed* nil)
         (h (%on-head :cols 90 :rows 24))
         (s (head-session h)))
    (setf (session-session-id s) "s-r16"
          (head-queued h) (list "third thing" "second thing" "first thing"))
    (leticl::%handle-frame
     h (list :frame "resync" :reason "auto-compaction" :dropped 0 :scrubbed nil
             :snapshot (%snapshot-with (list (%a-user-row "u1" "first thing")
                                             (%a-user-row "u2" "second thing")
                                             (%a-user-row "u3" "third thing")))))
    (is (null (head-queued h))
        "every echo whose row the snapshot carried is retired; still queued: ~s"
        (head-queued h))
    (is (null leticl::*queued-unconfirmed*)
        "and nothing is left unresolved, because each one WAS resolved")
    ;; and the same through a HELLO, the other frame a snapshot arrives on
    (let ((h2 (%on-head :cols 90 :rows 24)))
      (setf (session-session-id (head-session h2)) "s-r16b"
            (head-queued h2) (list "second thing" "first thing"))
      (leticl::%handle-frame
       h2 (list :frame "hello" :protocol-version 23 :session-id "s-r16b"
                :head-id "h1" :dropped 0 :sessions nil :wiring nil
                :resumed-from nil :scrubbed nil
                :snapshot (%snapshot-with (list (%a-user-row "u1" "first thing")
                                                (%a-user-row "u2" "second thing"))
                                          :id "s-r16b")))
      (is (null (head-queued h2)) "a HELLO's snapshot resolves them too"))))

(def-test an-echo-a-snapshot-cannot-resolve-stops-saying-queued (:suite leticl)
  "**R16's second clause, and the reason it is a third mark and not a deletion.**

A `queued` echo is a claim about the daemon's queue — *I sent this and have not seen
its row* — and the head made it on the strength of a transcript that a compaction has
just REPLACED. So when the snapshot does not carry the row, the claim has lost its
footing in both directions: a prompt that landed may have had its row summarised away,
and a prompt that has not landed looks exactly the same from here.

Neither `queued` (which the head can no longer support) nor a silent drop (the opposite
lie, and it would lose the one signal R2 exists to give) is honest. It is
`unconfirmed` — and **it retires the ordinary way the moment its row does land**, so
the mark is transient for a prompt that is genuinely still queued and permanent only
for one whose row is never coming."
  (let* ((leticl::*queued-unconfirmed* nil)
         (h (%on-head :cols 90 :rows 24))
         (s (head-session h)))
    (setf (session-session-id s) "s-r16d"
          (head-queued h) (list "summarised away" "also gone"))
    (leticl::%handle-frame
     h (list :frame "resync" :reason "auto-compaction" :dropped 0 :scrubbed nil
             :snapshot (%snapshot-with
                        (list (list :item-id "s1" :kind "assistant" :ts 0
                                    :item (list :type "assistant" :text "the summary"
                                                :tool-calls nil)))
                        :id "s-r16d" :dropped 40)))
    (is (equal '("also gone" "summarised away") (head-queued h))
        "the echoes are HELD — the head cannot prove they landed")
    (is (equal (head-queued h) leticl::*queued-unconfirmed*)
        "and every one of them is marked unresolved")
    ;; **the invariant**, and it is what keeps the two from drifting
    (is (every (lambda (txt) (member txt (head-queued h) :test #'equal))
               leticl::*queued-unconfirmed*)
        "every unconfirmed text is still a held echo")
    ;; the mark on the screen is the OTHER word
    (let ((text (segs-of (leticl::queued-lines h 90))))
      (is (search "unconfirmed · also gone" text) "the row says unconfirmed: ~s" text)
      (is (not (search "queued · also gone" text))
          "and does NOT say queued, which the head can no longer support"))
    ;; and a row that lands retires it out of BOTH lists
    (leticl::%handle-frame
     h (list :frame "event" :seq 901 :event "transcript_content" :item-id "u9"
             :item (list :type "user" :parts (list (list :kind "text"
                                                         :text "summarised away")))))
    (is (equal '("also gone") (head-queued h)) "its row landed, so it is retired")
    (is (equal '("also gone") leticl::*queued-unconfirmed*)
        "and it leaves the unresolved set with it")))

(def-test the-coalesced-echo-is-resolved-the-same-way-on-both-paths (:suite leticl)
  "One rule, two callers. Behind a running turn the daemon merges consecutive messages
into one, so a landing row can be the FRONT PIECE of a coalesced echo — `row ＋ newline`
is a prefix of the queued text, and the front comes off with the rest staying queued
(`app.rs:4685-4703`). A snapshot has to resolve it exactly as a live row does, or the
merged prompt stays on the screen for the rest of the session.

This is the case my first attempt at the fix got WRONG, and the test exists because of
it: I compared the queue's LENGTH rather than the queue, and the coalesced branch keeps
the same number of entries with a shorter one."
  (let* ((leticl::*queued-unconfirmed* nil)
         (h (%on-head :cols 90 :rows 24))
         (s (head-session h)))
    (setf (session-session-id s) "s-r16e"
          (head-queued h) (list (format nil "a~%b")))
    (leticl::%handle-frame
     h (list :frame "resync" :reason "auto-compaction" :dropped 0 :scrubbed nil
             :snapshot (%snapshot-with (list (%a-user-row "u1" "a")) :id "s-r16e")))
    (is (equal '("b") (head-queued h))
        "the front piece came off and the rest stayed queued")
    (is (equal '("b") leticl::*queued-unconfirmed*)
        "and the remainder is unresolved, not confirmed")))

(def-test a-landed-row-retires-the-prompt-it-echoes (:suite leticl)
  "The queue was retired by `pop` on `transcript_appended` — the NEWEST entry,
for a row that is almost certainly the OLDEST prompt — so with two queued prompts
of different text the wrong one came off first. The transcript takes the words
over by BEING them, so the row's TEXT is the match (app.rs:4685-4703, 4744-4751),
one row per entry, with the prefix rule for the daemon's coalescing."
  (let ((h (%make-head)))
    (setf (head-queued h) (list "second" "first"))   ; newest first, as sent
    (leticl::%handle-frame
     h (list :frame "event" :seq 1 :event "transcript_content" :item-id "i1"
             :item (list :type "user" :parts (list (list :text "first")))))
    (is (equal '("second") (head-queued h))
        "the row that landed retired ITS prompt, not the newest one")
    ;; the coalesced case: one row is the front piece of a merged echo
    (setf (head-queued h) (list (format nil "a~%b")))
    (leticl::%handle-frame
     h (list :frame "event" :seq 2 :event "transcript_content" :item-id "i2"
             :item (list :type "user" :parts (list (list :text "a")))))
    (is (equal (list "b") (head-queued h))
        "a row that is the front of a coalesced echo strips itself off it")
    ;; and a row nobody queued retires nothing
    (setf (head-queued h) (list "only"))
    (leticl::%handle-frame
     h (list :frame "event" :seq 3 :event "transcript_content" :item-id "i3"
             :item (list :type "user" :parts (list (list :text "somebody else's")))))
    (is (equal '("only") (head-queued h)) "another head's prompt retires nothing")))

(def-test a-refused-head-does-not-claim-the-session-is-quiet (:suite leticl)
  "**The screen after a `Bye` must not say the conversation is empty.**

`attached, and this session has said nothing yet` is a claim about a SESSION, and a head
the daemon just refused is in no position to make it: the daemon said why it ended, and
a cheerful banner about a quiet conversation is the same defect as the walking cat
standing in for a session nobody has described. Momentary — the loop exits on the next
pass and `run` prints the farewell to stderr once the terminal is back — but it is the
first frame on the screen, and on a version skew (R5) it is the frame somebody will
screenshot while asking what broke.

Found by refusing a 23 head against this box's 22 daemon for real: the attach came back
`{\"frame\":\"bye\",\"reason\":\"protocol version 23, this daemon speaks 22\"}` and the
head drew the banner under it."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (h (%on-head :cols 100 :rows 20)))
    (setf (head-connected h) t)
    ;; the premise: an empty, attached head DOES draw the banner
    (leticl::%render h)
    (is (search "said nothing yet" (%screen-text h))
        "the premise: an attached empty session says so")
    ;; and after a refusal it must not
    (leticl::%handle-frame
     h (list :frame "bye" :reason "protocol version 23, this daemon speaks 22"))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (not (search "said nothing yet" text))
          "a refused head does not claim the session is quiet")
      (is (search "bye: protocol version 23" text)
          "it says what the daemon said instead")
      (is (not (leticl::head-running h)) "and it is on its way out"))))

(def-test a-bye-is-the-end-of-the-conversation (:suite leticl)
  "The daemon writes a `Bye` and returns; the reference's pump stops on it and
the head leaves (client.rs:548, app.rs:1886-1889). This head only dropped
`connected`, so `%try-reconnect` re-attached every two seconds forever — a
refusal the daemon meant as final became a loop, and a version skew became
unreadable AND unescapable."
  (let* ((h (%make-head)) (sent (%fake-daemon h)))
    (leticl::%handle-frame h (list :frame "bye"
                                   :reason "protocol version 21, this daemon speaks 22"))
    (is (null (leticl::head-running h)) "the head is leaving")
    (is (null (head-connected h)) "and not attached")
    (is (search "speaks 22" (head-status-note h)) "with the daemon's own sentence kept")
    (funcall sent)
    (setf (leticl::head-last-reconnect h) 0)
    (leticl::%try-reconnect h)
    (is (null (funcall sent)) "and no further attach goes out, however long we wait")))

(def-test a-protocol-skew-says-its-direction-and-the-head-stays (:suite leticl)
  "**The version is compared at the HANDSHAKE, the DIRECTION is named, and the head
does not exit.** *\"A silent version skew looks like a bug in the other half,
forever\"* (server.rs:332-342).

Nothing read `Hello.protocol_version`, and then the check that was added EXITED:
`head-running` nil, the sentence on a status note that expires. That is the failure
framing the fix — a head that quits at the handshake never gets to use `R3`, which is
the mechanism that makes surviving a skew real, and the operator loses the
conversation over a number.

The two directions are NOT the same sentence, because they are not the same problem.
A NEWER daemon is a READING problem: the frames the two share read fine, and the
first one they do not is reported and skipped. An OLDER daemon is a WRITING problem
this head cannot survive from its side: a `ClientFrame` it has never heard of fails
ITS deserialiser and its read loop closes the socket — silent until fatal, which the
operator is entitled to know before they spend an hour in that session."
  ;; the sentence itself, as a question about two numbers
  (is (null (protocol-skew-said +protocol-version+ +protocol-version+))
      "equal versions say nothing at all — a line here would be furniture")
  (let ((newer (protocol-skew-said 99 +protocol-version+))
        (older (protocol-skew-said 9 +protocol-version+)))
    (is (search "NEWER" newer) "a newer daemon is named as newer")
    (is (search "OLDER" older) "and an older one as older")
    (is (search (format nil "~d" +protocol-version+) newer)
        "both name this head's version")
    (is (not (equal newer older)) "and they are not the same sentence")
    (is (search "reported" newer) "a newer daemon means frames reported and skipped")
    (is (search "closing the socket" older)
        "an older one means a command it cannot read ends the session")
    (is (search "stays up" newer) "the newer case says the connection survives")
    (dolist (s (list newer older))
      (is (not (search "leave" s)) "and neither tells anybody to leave")))
  ;; and the behaviour, both directions, through a real Hello
  (flet ((hello (h version)
           (leticl::%handle-frame
            h (list :frame "hello" :protocol-version version
                    :session-id "s-1" :snapshot nil :sessions nil :wiring nil))
           h))
    (let ((h (%make-head))
          (*daemon-protocol* nil) (*skew-said-pending* nil) (*skew-last-said* nil))
      ;; **before the handshake the row says so**, which is a different statement
      ;; from a version number — and it cannot be read as "we agree".
      (is (some (lambda (l) (string= "  protocol    not told yet" l))
                (lines-text (status-screen-lines h 120)))
          "/status says `not told yet` before anything has been heard")
      (hello h 99)
      (is (leticl::head-running h) "a newer daemon does not stop the head")
      (is (head-connected h) "and it stays attached")
      (is (equal 99 *daemon-protocol*) "the version it was TOLD is what is kept")
      (let* ((s (head-session h))
             (item (aref (session-items s) (1- (length (session-items s)))))
             (row (format nil "~{~a~^ ~}"
                          (lines-text (item-lines item 120 (head-prefs h))))))
        (is (search "NEWER" row) "the conversation says which way round it is")
        (is (search "protocol 99" row) "with both numbers in it")
        (is (search (format nil "~d" +protocol-version+) row)
            "including this head's own"))
      (is (some (lambda (l) (string= (format nil "  protocol    99 · this head speaks ~d — NEWER build"
                                              +protocol-version+)
                                    l))
                (lines-text (status-screen-lines h 120)))
          "and /status carries the direction after the row has scrolled away")
      ;; said once, however many Hellos a Switch produces
      (let ((n (length (session-items (head-session h)))))
        (hello h 99)
        (hello h 99)
        (is (= n (length (session-items (head-session h))))
            "three Hellos are one sentence, not three"))
      ;; and the older direction, on a fresh head
      (let ((h2 (%make-head))
            (*daemon-protocol* nil) (*skew-said-pending* nil) (*skew-last-said* nil))
        (hello h2 9)
        (is (leticl::head-running h2) "an older daemon does not stop the head either")
        (let* ((item (aref (session-items (head-session h2))
                           (1- (length (session-items (head-session h2))))))
               (row (format nil "~{~a~^ ~}"
                            (lines-text (item-lines item 120 (head-prefs h2))))))
          (is (search "OLDER" row) "the older direction is named as older")
          (is (search "closing the socket" row)
              "and says the session can end on the next thing typed"))
        (is (some (lambda (l) (string= (format nil "  protocol    9 · this head speaks ~d — OLDER build"
                                              +protocol-version+)
                                    l))
                  (lines-text (status-screen-lines h2 120)))
            "and /status names it"))))
  ;; the headers say the number the constant says
  (is (search (format nil "protocol version ~d" +protocol-version+)
              (source-of "protocol"))
      "src/protocol.lisp's header names the version it sends")
  (is (search (format nil "protocol ~d" +protocol-version+) (%repo-file "leticl.asd"))
      "and so does the system definition"))

(def-test a-question-answer-can-carry-a-typed-reply (:suite leticl)
  "Only `{\"option\":N}` was ever built. `QuestionAnswer` has `note` and `free`
too (question.rs:55-65), and `free` is the half the requirement names —
*\"opencode style free user reply input\"* (question.rs:10-20) — so a typed answer
to a question was unreachable."
  (is (equal '(:free "no, use the other branch")
             (question-answer :free "no, use the other branch"))
      "a typed reply alone")
  (is (equal '(:option 2 :note "because it is read-only")
             (question-answer :option 2 :note "because it is read-only"))
      "an option and a note together")
  (is (equal '(:option 0) (question-answer :option 0)) "an option alone")
  (is (null (question-answer)) "and nothing is not an answer: deferring is not sending")
  (let ((line (encode-frame (make-answer-question "r1" (question-answer :free "yes")))))
    (is (search "\"answer\":{\"free\":\"yes\"}" line)
        (format nil "and it goes out as the payload: ~a" line))
    (is (not (search "null" line)) "with no null anywhere on the frame")))

(def-test an-empty-answer-is-not-a-frame (:suite leticl)
  "**§4.5, the latent one.** `question-answer` returns NIL for *nothing to say*, the
encoder wrote NIL as `null`, and `AnswerQuestion.answer` is a plain `QuestionAnswer`
struct and not an `Option` (protocol.rs:644-648, question.rs:55-65) — so
`\"answer\": null` fails the WHOLE `ClientFrame` deserialiser, not one frame: the
daemon's read loop, and the socket goes with it.

Not reachable today, because the only caller passes `(list :option idx)`. But this is
the THIRD instance of one hazard, and the previous two were fixed by hand at their call
sites: `Mode.consented` (`%send-mode`) and `ReseatSession.summarise` (commands.lisp)
both had to become `:false` rather than NIL, because `#[serde(default)]` accepts a
MISSING key and not a present `null`.

So both halves of the general answer are here:

  · **`%encode-object` elides a NIL-valued key** (json.lisp) — that is the general fix,
    and it closes the `#[serde(default)]` and `Option<T>` cases for every future site:
    an absent key takes serde's default, a present null is an error.
  · **`make-answer-question` refuses an empty answer** — and this is the part no encoder
    rule can reach: for a BARE required field both absent and null are fatal, so the
    frame must not be built at all. Deferring is not sending."
  (is (null (question-answer)) "nothing to say is NIL, which is the whole problem")
  (signals error (make-answer-question "r1" (question-answer)))
  (signals error (make-answer-question "r1" nil))
  ;; **and the encoder cannot rescue it, which is the point of the refusal living
  ;; here.** Eliding the nil removes the KEY, and a bare required field is fatal both
  ;; absent and null — so a caller that built this frame by hand would still hand the
  ;; daemon a frame it cannot read. The elision closes the OTHER two shapes; a required
  ;; field has to be refused where the frame is made.
  (let ((line (encode-frame (list :frame "answer_question" :req-id "r1" :answer nil))))
    (is (not (search "null" line)) "the elision leaves no null to break the deserialiser")
    (is (not (search "\"answer\":" line))
        "and no `answer` KEY either (the frame's own name has the word in it) —
         a missing required field is rejected just as hard as a null one")))

(def-test no-client-frame-this-head-can-build-carries-a-null (:suite leticl)
  "**The invariant, over every constructor rather than over the one that was fixed.**

A `null` value on a client frame is a hazard in three shapes and helpful in none:
`Option<T>` accepts it but so does absence, `#[serde(default)]` rejects it, and a bare
`T` rejects it — so a null can only ever lose. This walks `protocol.lisp`'s own
constructors, at the arguments their call sites use, and asserts that none of them
encodes one.

The two hand-fixed sites are checked too, because their explicit `:false` is the
SPELLING and not the rule: it is a value, and it must survive as one."
  (flet ((calls ()
           `(("make-attach" . ,(make-attach))
             ("make-ack" . ,(make-ack 7 3 4))
             ("make-resync" . ,(make-resync))
             ("make-prompt" . ,(make-prompt 3 "hi"))
             ("make-interrupt" . ,(make-interrupt 3 "why"))
             ("make-withdraw-prompts" . ,(leticl::make-withdraw-prompts 3))
             ("make-stop" . ,(leticl::make-stop 3 "leticl"))
             ("make-answer" . ,(make-answer "d1" "allow_once"))
             ("make-answer+pattern+note" . ,(make-answer "d1" "allow_always" "/tmp/*" "why"))
             ("make-answer-question" . ,(make-answer-question "r1" (question-answer :option 0)))
             ("make-answer-question+free" . ,(make-answer-question "r1" (question-answer :free "yes")))
             ("make-list-sessions" . ,(make-list-sessions))
             ("make-list-todos" . ,(leticl::make-list-todos))
             ("make-list-jobs" . ,(leticl::make-list-jobs))
             ("make-read-job-output" . ,(leticl::make-read-job-output "j1" 0))
             ("make-new-session" . ,(make-new-session "t" "/tmp"))
             ("make-resume-session" . ,(make-resume-session "s1"))
             ("make-rename-session" . ,(make-rename-session "s1" "t"))
             ("make-switch" . ,(make-switch "s1" 0))
             ("make-peek" . ,(make-peek "s1"))
             ("make-settings" . ,(make-settings))
             ("make-detach" . ,(make-detach))
             ;; the size is an argument now, so this one is spelled out
             ("make-screen-answer" . ,(make-screen-answer "q1" 80 24 (list "abc"))))))
    (dolist (c (calls))
      (destructuring-bind (name . frame) c
        (let ((line (encode-frame frame)))
          (is (not (search "null" line))
              (format nil "~a encodes a null: ~a" name line))
          ;; and it is still JSON that decodes, which the first version of the elision
          ;; broke with a leading comma
          (is (consp (json-decode line))
              (format nil "~a does not decode: ~a" name line))
          (is (equal (getf frame :frame) (getf (json-decode line) :frame))
              (format nil "~a round-trips its frame name" name))))))
  ;; the two hand-fixed sites, whose `:false` must stay a VALUE
  (let ((h (%make-head)) (wire (make-string-output-stream)))
    (setf (leticl::head-stream h) wire (head-connected h) t)
    (leticl::%send-mode h "always-ask" nil)
    (let ((line (string-trim '(#\newline) (get-output-stream-string wire))))
      (is (search "\"consented\":false" line)
          (format nil "the mode frame still says false, not nothing: ~a" line))
      (is (not (search "null" line)) "and no null"))))

(def-test the-screen-answer-is-the-frame-that-was-just-drawn (:suite leticl)
  "The one frame whose whole point is *what the operator is looking at right
now* was answered during the drain, from `head-last-rows` — the PREVIOUS frame.
The reference queues the id and answers after `screen()` with the rows it just
put on the terminal (driver.rs:93-99, app.rs:2723-2732)."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (h (%on-head :cols 80 :rows 24))
         (sent (%fake-daemon h)))
    (setf (head-last-rows h) (list "the frame before"))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "screen_requested"
                                   :req-id "q1"))
    (is (equal '("q1") (head-screen-reqs h)) "the id is queued, not answered")
    (is (null (funcall sent)) "nothing is on the wire yet")
    (is (eq t (head-dirty h)) "and a frame is owed, so one is drawn")
    (leticl::%render-and-paint h)
    (leticl::%answer-screen-requests h)
    (let ((f (first (funcall sent))))
      (is (equal "screen" (getf f :frame)) "the answer goes out after the paint")
      (is (equal "q1" (getf f :req-id)) "for the id that asked")
      (is (not (equal (list "the frame before") (getf f :rows)))
          "and it is NOT the frame before")
      (is (= 24 (getf f :rows-n)) "it is this head's real size")
      (is (= 80 (getf f :cols)) "in both directions")
      (is (equal (head-last-rows h) (getf f :rows)) "and the rows it just painted"))
    (is (null (head-screen-reqs h)) "the queue is spent")))

(def-test the-screen-answer-reports-columns-and-not-characters (:suite leticl)
  "**§4.4: the width was the CHARACTER LENGTH OF ROW ZERO, ANSI BYTES INCLUDED.**

It parsed, and it reported a number that is not the width, and the daemon believed
it — the worst available kind of wrong. The reference sends its terminal size
(`driver.rs:287`), and its own doc on this frame asks for *\"last rendered, ANSI and
all, at its real terminal size\"*.

Measured on a painted frame: an 80-column row is 80 cells and 80 + every SGR byte in
it characters, so the two differ by hundreds on a row with two escapes in it."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (h (%on-head :cols 80 :rows 24))
         (sent (%fake-daemon h)))
    (leticl::%render-and-paint h)
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "screen_requested"
                                   :req-id "q1"))
    (leticl::%answer-screen-requests h)
    (let* ((f (first (funcall sent)))
           (rows (getf f :rows)))
      (is (= 80 (getf f :cols)) "the width is the frame's column count")
      (is (= 24 (getf f :rows-n)) "and the height its row count")
      (is (= (length rows) (getf f :rows-n)) "with one string per row")
      ;; every row is exactly the frame's width in CELLS, which is why a character
      ;; count cannot be one: at least one row carries escapes and they cost bytes
      (is (every (lambda (r) (= 80 (string-width r))) rows)
          "and every row measures the frame's width by the one rule this tree has")
      (let ((chars (loop for r in rows maximize (length r))))
        (is (> chars 80)
            "while its CHARACTER length is larger — the escape bytes are in it, which
             is the number the daemon used to be told")
        (is (not (= chars (getf f :cols)))
            "so the two are not the same number and the frame carries the right one")))))

(def-test a-resync-adds-its-dropped-and-its-scrubbed (:suite leticl)
  "Both counts travel on the `Resync` frame and both were discarded on that path,
so `/status`'s `dropped` and `scrubbed` under-reported after a resync — which is
exactly when they are worth reading (app.rs:1843-1845)."
  (let* ((h (%make-head))
         (*scrubbed-total* 0) (*resyncs* 0) (leticl::*turn-started-ms* nil))
    (setf (session-dropped (head-session h)) 1
          (session-session-id (head-session h)) "s-1")
    (leticl::%handle-frame h (list :frame "resync" :reason "the daemon lost our place"
                                   :dropped 3
                                   :scrubbed (list :deltas 2 :reasoning 1 :tool-progress 1)
                                   :snapshot (list :session-id "s-1" :seq 9 :dropped 0
                                                   :items-dropped 0 :items nil :turn nil)))
    (is (= 4 (session-dropped (head-session h))) "the frame's dropped is added to ours")
    (is (= 4 *scrubbed-total*) "and its ScrubReport is summed in")
    (is (= 1 *resyncs*) "the resync is counted, as it was")
    (is (= 9 (session-seq (head-session h))) "and the snapshot still lands")))

(def-test a-settled-secret-takes-the-card-down (:suite leticl)
  "`SecretSettled` reached nothing — measured, disposition `:QUIET` and no other
effect — so the masked field stayed up over a `sudo` another head had already
answered. The daemon's own `secret_late` warning, which would explain it, is a
`Warning`, which this head does not draw either (app.rs:2750-2765)."
  (let ((h (%make-head)))
    (setf (head-secret-req h) (list :req-id "r1" :prompt "password:")
          (leticl::head-secret-buf h) "half-typed")
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "secret_settled"
                                   :req-id "r2" :given t :by "another head"))
    (is (consp (head-secret-req h)) "a settlement for ANOTHER ask leaves this one up")
    (is (equal "half-typed" (leticl::head-secret-buf h)) "and does not drop the keystrokes")
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "secret_settled"
                                   :req-id "r1" :given t :by "claude-host"))
    (is (null (head-secret-req h)) "ours comes down when it is answered")
    (is (equal "" (leticl::head-secret-buf h)) "with nothing left in the field")
    (is (search "claude-host" (head-status-note h)) "and it says who answered")))

(def-test a-settled-job-updates-the-row-the-pane-draws (:suite leticl)
  "`JobSettled` was pushed to `session-jobs`, which nothing draws: the pane draws
`head-jobs`, which is only ever the `Jobs` reply. So an open pane showed
`running` for a job that had exited until `/jobs` was run again — the exact lie
event.rs:857-864 says the event exists to prevent. Folded into the row the daemon
gave us and NEVER invented: a settlement for a job this head has not been told
about arrives with the next `ListJobs` (app.rs:2176-2195)."
  (let ((h (%make-head)))
    (leticl::%handle-frame h (list :frame "jobs" :session-id "s-1"
                                   :jobs (list (list :id "j1" :command "cargo test"
                                                     :how "bash" :state "running"
                                                     :running t :produced 12
                                                     :elapsed-ms 0))))
    (is (eq t (getf (first (head-jobs h)) :running)) "the reply's row is running")
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "job_settled"
                                   :job "j1" :state "exited 0" :produced 4096
                                   :elapsed-ms 3400))
    (let ((row (first (head-jobs h))))
      (is (null (getf row :running)) "the settlement stops it running")
      (is (equal "exited 0" (getf row :state)) "with the state the daemon named")
      (is (= 4096 (getf row :produced)) "the bytes it produced")
      (is (= 3400 (getf row :elapsed-ms)) "and how long it ran")
      (is (equal "cargo test" (getf row :command)) "keeping what only the reply knows"))
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "job_settled"
                                   :job "j9" :state "exited 1" :produced 0 :elapsed-ms 1))
    (is (= 1 (length (head-jobs h))) "a settlement for an unknown job invents no row")))

(def-test there-is-one-way-to-build-an-ack (:suite leticl)
  "`protocol.rs:717-720`: the ack's seq comes from the batch, *\"and there is
deliberately no other way to obtain one\"*. Two ways existed here, and the unused
one was the bug the rule names — `ack-frame` read `session-seq`, the last seq
FOLDED, where `run-loop` reads `last-seq`, the last seq READ. They disagree on
every batch that ends in a frame this head filtered, which is every batch at
terse. Deleted rather than fixed, and pinned here so it cannot come back."
  (let ((s (find-symbol "ACK-FRAME" :leticl)))
    (is (or (null s) (not (fboundp s)))
        "there is no second spelling of the ack in the image"))
  (is (search "(make-ack last-seq" (source-of "head"))
      "the loop acks the last seq it READ")
  (dolist (name '("session" "commands" "editor" "cards" "chrome" "panes" "render"))
    (is (not (search "(make-ack" (source-of name)))
        (format nil "and src/~a.lisp does not build one of its own" name))))

;;; ------------------------------------- the operator's input, measured (keys.md) ;;;
;;;
;;; `docs/parity/keys.md` read every chord, every slash verb and the composer
;;; against letibot `8af671e` and wrote down what would stop an operator trying to
;;; make this head their daily driver. These are those findings, one test each,
;;; and each docstring says what was MEASURED rather than what the code now does.

(defun %wire (head)
  "Give HEAD a stream to write frames to. Returns the stream, which `%sent`
decodes — the head's own socket path, with a string stream standing in for it."
  (let ((wire (make-string-output-stream)))
    (setf (leticl::head-stream head) wire (head-connected head) t)
    wire))

(defun %sent (wire)
  "Every frame written to WIRE since the last read, decoded, NEWEST FIRST."
  (let ((text (get-output-stream-string wire)))
    (nreverse (mapcar #'json-decode
                      (remove "" (uiop:split-string text :separator '(#\newline))
                              :test #'string=)))))

(defun %sessions (head &rest titles)
  "Put TITLES on HEAD as the daemon's session list, `s-1` … `s-N`.

`:live t` by default, because that is what a daemon's own `Sessions` reply means by a
session it is holding — and the flag decides whether picking the row is a `switch` or
a `resume`. A test that wants the other kind passes `(list :title \"x\" :live nil)`
itself; see `picking-a-session-on-disk-resumes-it`."
  (setf (session-sessions (head-session head))
        (loop for title in titles
              for i from 1
              collect (list* :session-id (format nil "s-~d" i)
                             :live t
                             (if (consp title) title (list :title title)))))
  head)

(def-test esc-esc-is-two-keys-and-not-one-alt (:suite leticl)
  "G1. `read-key` saw ESC, polled 60 ms, got the second ESC and fell to the alt
arm — `(:type :alt :ch #\\Esc)` — which the composer drops. So a FAST double tap,
which is how anybody who means it presses it, was eaten, and the one key that
stops a runaway turn did nothing. The reference names this exact trap and guards
it the same way (term.rs:707-711): two keys out of two bytes."
  (let ((s (make-string-input-stream (format nil "~C~C" +esc+ +esc+))))
    (is (equal (read-key s) (list :type :esc)) "the first ESC is a key on its own")
    (is (equal (read-key s) (list :type :esc)) "and the second is still there to read")))

(def-test the-decoder-reads-the-chords-the-composer-answers (:suite leticl)
  "G7/G8. `alt+b`, `alt+f`, `alt+z` and `alt+backspace` arrived as `(:type :alt)`
and were thrown away by the one arm that reads an alt chord (alt+enter), and the
CSI modifier parameter was parsed and never looked at — so `ctrl-←` was a plain
`←`. SS3 Home and End were not in the table at all (term.rs:715-743, 773-780)."
  (is (equal (key-from (format nil "~C[1;5D" +esc+)) (list :type :word-left))
      "ctrl-← is word-left, not left")
  (is (equal (key-from (format nil "~C[1;5C" +esc+)) (list :type :word-right))
      "and ctrl-→ word-right")
  (is (equal (key-from (format nil "~C[D" +esc+)) (list :type :left))
      "a bare arrow is still a bare arrow")
  (is (equal (key-from (format nil "~Cb" +esc+)) (list :type :word-left)) "alt+b")
  (is (equal (key-from (format nil "~Cf" +esc+)) (list :type :word-right)) "alt+f")
  (is (equal (key-from (format nil "~Cz" +esc+)) (list :type :redo)) "alt+z is redo")
  (is (equal (key-from (format nil "~C~C" +esc+ (code-char 127)))
             (list :type :kill-word-back))
      "alt+backspace kills the word back")
  (is (equal (key-from (format nil "~COH" +esc+)) (list :type :home)) "SS3 Home")
  (is (equal (key-from (format nil "~COF" +esc+)) (list :type :end)) "SS3 End"))

(def-test a-pane-open-is-not-a-head-you-cannot-talk-to (:suite leticl)
  "G2. The pane arm claimed every key for the nine full-body modes and read only
`q` out of a printable one, so NO character reached the composer while a pane was
open — including the session picker, whose own hint bar says *\"type a number to
switch · /new [title]\"* (chrome.lisp:363) and meant neither. The reference lets a
pane's text fall through and gates only Enter on an empty line (app.rs:3508-3548)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (%sessions h "first" "second")
    (setf (head-mode h) :picker)
    (leticl::%handle-key h (list :type :char :ch #\2))
    (is (eq :picker (head-mode h)) "typing does not close the list")
    (is (string= "2" (composer-buffer (head-composer h))) "and the digit is in the composer")
    (leticl::%handle-key h (list :type :enter))
    (let ((f (first (%sent wire))))
      (is (equal "switch" (getf f :frame)) "enter on the typed number switches")
      (is (equal "s-2" (getf f :session-id)) "to the session on that row"))
    ;; and `q` is a letter again once a line is being typed
    (setf (head-mode h) :todos)
    (composer-insert (head-composer h) "why")
    (leticl::%handle-key h (list :type :char :ch #\q))
    (is (eq :todos (head-mode h)) "q with a line typed does not close the pane")
    (is (string= "whyq" (composer-buffer (head-composer h))) "it types a q")))

(def-test picking-a-session-on-disk-resumes-it (:suite leticl)
  "§6. **A row labelled `on disk` is not in this daemon, so `switch` is the wrong
frame** — the daemon has never opened it. The reference brings it in first
(`switch_to`, `app.rs:5105-5118`): send `ResumeSession`, remember that this head
wants the session the answer names, and send the switch when the daemon answers. The
flag is the same one `/new` uses, because \"go to the session the daemon just told me
about\" is one behaviour.

MEASURED before the fix: the picker listed the stored session, the row said `on disk`,
Enter sent `{\"frame\":\"switch\",\"session_id\":\"s-2\"}` — and nothing happened,
because the daemon had nothing under that id.

And **`already here` is said**: picking the row you are on is not nothing, and without
the sentence the screen looks the same either way."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-session-id (head-session h)) "s-1")
    (%sessions h "here and live" "stored, not open")
    ;; make the second row the stored one
    (setf (getf (second (session-sessions (head-session h))) :live) nil
          (getf (second (session-sessions (head-session h))) :stored-items) 1799)
    (leticl::%switch-to h "s-2")
    (let ((f (first (%sent wire))))
      (is (equal "resume_session" (getf f :frame)) "a stored row is RESUMED, not switched to")
      (is (equal "s-2" (getf f :session-id)) "the id the row carried"))
    (is (leticl::head-want-new h) "and the head is waiting to follow the answer")
    (is (search "resuming s-2 from the store" (head-status-note h)) "saying so")
    ;; a LIVE row switches, one frame, and does not set the flag
    (let* ((h2 (%on-head :cols 80 :rows 24))
           (wire2 (%wire h2)))
      (setf (session-session-id (head-session h2)) "s-1")
      (%sessions h2 "one" "two")
      (leticl::%switch-to h2 "s-2")
      (let ((f (first (%sent wire2))))
        (is (equal "switch" (getf f :frame)) "a live row switches")
        (is (equal "s-2" (getf f :session-id)) "to the session on that row"))
      (is (not (leticl::head-want-new h2)) "and nothing is being awaited"))
    ;; and the row you are on says so instead of sending anything
    (let* ((h3 (%on-head :cols 80 :rows 24))
           (wire3 (%wire h3)))
      (setf (session-session-id (head-session h3)) "s-1")
      (%sessions h3 "one" "two")
      (leticl::%switch-to h3 "s-1")
      (is (null (%sent wire3)) "no frame for the session you are already in")
      (is (search "already here" (head-status-note h3)) "and it says so"))))

(def-test ctrl-x-shows-the-raw-call-on-a-settled-row-too (:suite leticl)
  "§6. The reference draws the raw tool call behind `ctrl-x` in TWO places
(`app.rs:7061-7062` live, `:11055-11061` settled), and this head drew only the live
turn's — so the pref did nothing on a transcript, which is every row but the one being
written.

The two are different text for the same fact: a live turn shows the `<function=…>`
markup the model WROTE, from the `ToolCall` deltas; a settled row has no markup left —
the parser ate it — so it shows the name and the arguments it read. Both go through
one renderer, because two would drift into two different-looking blocks for one
control."
  (let ((h (%make-head)))
    ;; the block itself, which is labelled, fenced and faint: it is EVIDENCE, and
    ;; evidence that looks like prose is how the defect started
    (let ((block (leticl::raw-call-lines "{\"path\": \"a.rs\"}" 80)))
      (is (search "raw tool call · ctrl-x" (segs-of block)) "the block is labelled")
      (is (search "│ " (segs-of block)) "and the text is railed")
      (is (search "└─" (segs-of block)) "and closed"))
    ;; on a SETTLED assistant row: one call with a result, one without
    (let* ((body (list :type "assistant" :text ""
                       :tool-calls (list (list :id "c1" :name "read"
                                               :arguments "{\"path\":\"a.rs\"}")
                                         (list :id "c2" :name "bash"
                                               :arguments "{\"command\":\"ls\"}")))))
      (setf leticl::*answered-calls* (list "c1")
            leticl::*item-facts* nil)
      (flet ((lines (prefs)
               (segs-of (item-lines (list :item-id "i1" :kind "assistant"
                                          :item body)
                                    80 prefs))))
        (is (not (search "raw tool call" (lines (list :show-tools nil :raw-calls nil))))
            "off by default: the markup the default view must never show")
        (let ((on (lines (list :show-tools nil :raw-calls t))))
          (is (search "raw tool call · ctrl-x" on) "and shown when ctrl-x asks")
          (is (search "read {\"path\":\"a.rs\"}" on)
              "with the name and the arguments the parser read")
          (is (search "→ Ran ls · no result" on)
              "and the UNANSWERED call still draws its `no result` row — the two "
              "cases are different rows and both are wanted"))))))

(def-test an-attach-that-is-never-answered-ends-with-the-two-commands-that-reach-it (:suite leticl)
  "§6. The reference's `ATTACH_WAIT` is 30 seconds and its failure names
`letibot --status` and `letibot --stop` (`bin/letibot-tui.rs:167, 611-652`); this head
waited FOR EVER, with a two-second line saying `ctrl-c twice, or wait` and nothing
about the daemon being hung.

**The deadline is the point rather than the number**, and so is the distinction it
draws: a daemon that accepted the connection and sent no `Hello` is a HUNG daemon, not
an absent one — absent means start one, hung means find out why — and the two commands
that answer it are not on any screen the head can draw, because the head is the thing
that is stuck."
  (let ((leticl::*fixed-clock-ms* 1000000)
        (leticl::*attach-started-ms* 1000000))
    (is (not (leticl::attach-overdue-p)) "a fresh attach is not overdue")
    (is (leticl::attaching-p (%make-head)) "and the head is waiting")
    (setf leticl::*fixed-clock-ms* (+ 1000000 (1- +attach-wait-ms+)))
    (is (not (leticl::attach-overdue-p)) "one millisecond early is still waiting")
    (setf leticl::*fixed-clock-ms* (+ 1000000 +attach-wait-ms+))
    (is (leticl::attach-overdue-p) "and the millisecond it is due, it is overdue")
    (let ((said (leticl::attach-gave-up-said)))
      (is (search "did not answer within 30s" said) "the sentence names how long")
      (is (search "hung daemon rather than an absent one" said)
          "and which kind of daemon this is")
      (is (search "letibot --status" said) "and the first command that reaches it")
      (is (search "letibot --stop" said) "and the second"))
    ;; a Hello clears the clock, so a head that was answered is never overdue
    (setf (leticl::head-running (%make-head)) t)
    (setf leticl::*attach-started-ms* nil)
    (is (not (leticl::attach-overdue-p)) "an answered attach is not overdue")))

(def-test switch-resolves-a-row-number-or-a-title-the-same-way-the-picker-does (:suite leticl)
  "§6. The reference resolves `/switch WHAT` through the same `pick()` its picker's
Enter uses (`app.rs:4806-4855`, called from `:5186`), so one line cannot mean two
things depending on which door it came through.

This sent the text to the daemon as an id, so `/switch 3` and `/switch parity` were a
round trip that answered nothing — while the picker TWO KEYS AWAY accepted exactly
those. An ambiguous match is refused with the count rather than resolved to the first:
switching to the wrong session is not a keystroke you can take back, because the prompt
you type next lands there."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-session-id (head-session h)) "s-1")
    (%sessions h "the parity pass" "the parity notes" "zzz")
    ;; a ROW NUMBER
    (leticl::%command h "switch 2")
    (let ((f (first (%sent wire))))
      (is (equal "switch" (getf f :frame)) "a row number switches")
      (is (equal "s-2" (getf f :session-id)) "to the row it names"))
    ;; a TITLE SUBSTRING — ambiguous here, so refused with the count
    (leticl::%command h "switch parity")
    (is (search "2 sessions match" (head-status-note h))
        "an ambiguous substring is refused, with the count: ~s" (head-status-note h))
    ;; an ID PREFIX
    (leticl::%command h "switch s-3")
    (let ((f (first (%sent wire))))
      (is (equal "s-3" (getf f :session-id)) "an id prefix switches"))
    ;; a word nothing matches
    (leticl::%command h "switch nothing-here")
    (is (search "no session matches" (head-status-note h)) "and a miss says so")
    ;; with no list at all the text goes to the daemon as an id, which is the one
    ;; case the old behaviour could serve
    (let* ((h2 (%on-head :cols 80 :rows 24))
           (wire2 (%wire h2)))
      (leticl::%command h2 "switch s-9")
      (is (equal "s-9" (getf (first (%sent wire2)) :session-id))
          "a head with no list still passes an id through"))))

(def-test rename-is-guarded-against-an-empty-session-id (:suite leticl)
  "§6. `(session-session-id …)` is `\"\"` before the first `Hello`, and this sent
`rename_session` for the empty id — a frame about a session that does not exist,
answered by nothing. The reference says so and stops (`app.rs:5195-5198`).

**And an empty NAME still goes**, which is the other half and a different half: that is
how a name is CLEARED, and the sentence it prints says so."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    ;; no session id yet
    (setf (session-session-id (head-session h)) "")
    (leticl::%command h "rename a name")
    (is (null (%sent wire)) "nothing is sent for a session that does not exist")
    (is (search "not attached to a session yet" (head-status-note h))
        "and it says which of the two problems it is: ~s" (head-status-note h))
    ;; attached, and a name given
    (setf (session-session-id (head-session h)) "s-1")
    (leticl::%command h "rename the parity pass")
    (let ((f (first (%sent wire))))
      (is (equal "rename_session" (getf f :frame)) "a real id renames")
      (is (equal "s-1" (getf f :session-id)) "the session this head is in")
      (is (equal "the parity pass" (getf f :title)) "to what was typed"))
    ;; attached, and NOTHING after the verb — the clear, with its warning
    (leticl::%command h "rename")
    (is (search "clears the name" (head-status-note h))
        "an empty name says what it is about to do: ~s" (head-status-note h))
    (is (equal "" (getf (first (%sent wire)) :title))
        "and sends it, because that is how a name is cleared")))

;;; ------------- §3.1: content the head did not author cannot drive the terminal ----
;;;
;;; The section's claim: *control characters in anything the head did not write are
;;; neutralised before they reach the tty.* MEASURED here rather than assumed, and
;;; the answer is that this head does it with ONE invariant rather than a list of
;;; sanitised call sites — which is the sentence letibot needs, because it tells them
;;; what to build toward rather than which four places to patch.

(defun %terminal-driving-chars (s)
  "Every character in S that could drive a terminal if it reached one: ESC, DEL, and
the C1 range (`0x9B` is 8-bit CSI)."
  (loop for c across s for i from 0
        when (or (char= c #\Esc)
                 (= (char-code c) 127)
                 (<= #x80 (char-code c) #x9f))
          collect (cons i (char-code c))))

(defun %segments-of (lines)
  "SEGMENT LINES as one string, so a whole row can be swept with one call."
  (format nil "~{~a~^~%~}"
          (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))

(defparameter +§3-1-payloads+
  (list (format nil "~C[31mred~C[0m" #\Esc #\Esc)          ; an SGR pair
        (format nil "~C[?1002h" #\Esc)                      ; mouse reporting
        (format nil "~C[?1006h" #\Esc)                      ; SGR mouse
        (format nil "~C[?1049h" #\Esc)                      ; alternate screen
        (format nil "~C[?2004h" #\Esc)                      ; bracketed paste
        (format nil "~C[?2026h" #\Esc)                      ; synchronized output
        (format nil "~C]0;pwned~C" #\Esc #\Bel)            ; an OSC title
        (format nil "~C[2J" #\Esc)                          ; clear screen
        (format nil "~C[8m" #\Esc)                          ; conceal
        (format nil "~C[31m" (code-char #x9b))               ; 8-bit CSI
        (format nil "~Ctext" (code-char #x9c))               ; another C1
        (format nil "a~cb" (code-char #x7f)))                ; DEL
  "The real bytes rather than invented ones: 44 `tool_result` rows in the operator's
own store carry an escape and 20 carry a mode string (`?1002`, `?1006`, `?1049`,
`?2004`), which is what made ctrl-t break the mouse wheel.")

(def-test every-source-a-model-can-reach-goes-through-the-same-painter (:suite leticl)
  "**The guarantee, stated where it lives.** This head composes styled SEGMENTS into a
CELL GRID, and every cell is written by `screen-put-string`, which walks CLUSTERS and
**skips any cluster of zero columns** (`cells.lisp:243-248`). A control character
measures zero columns (`%code-width`: `%c1-control-p` covers C0, C1 and DEL,
`width.lisp:136-150`) and `plain-columns-p` refuses any string containing `+esc+`, so
the fast path cannot store one either (`width.lisp:421`). **A zero-width cluster is
never written to a cell, so it cannot reach the terminal** — not because six call sites
sanitise, but because the painter cannot author a cell it did not measure.

That is why the sanitising this head HAS (`%without-control`, on the tool payload and
the job pane) is belt-and-braces rather than the rule: the model's prose, its reasoning,
the user's own message, the system row, a fence body and a diff excerpt read off disk
are all UNSANITISED in the segments and all safe on the wire.

The test sweeps each source through the real pipeline — `item-lines`, then the frame —
and asserts two things at once: the value's TEXT may survive (harmless), and its
INTRODUCER never does."
  (let* ((h (%make-head))
         (s (head-session h))
         (items nil))
    (dolist (p +§3-1-payloads+)
      (push (list :item-id (format nil "u~d" (length items)) :kind "user" :ts 0
                  :item (list :type "user" :parts (list (list :kind "text" :text p))))
            items)
      (push (list :item-id (format nil "a~d" (length items)) :kind "assistant" :ts 0
                  :item (list :type "assistant" :text p :tool-calls nil))
            items)
      (push (list :item-id (format nil "s~d" (length items)) :kind "system" :ts 0
                  :item (list :type "system" :text p))
            items)
      ;; a fence body, with the payload between two fences
      (push (list :item-id (format nil "f~d" (length items)) :kind "assistant" :ts 0
                  :item (list :type "assistant" :tool-calls nil
                              :text (concatenate 'string "before" (string #\newline)
                                                 "```" (string #\newline) p
                                                 (string #\newline) "```")))
            items)
      ;; a diff excerpt, whose sides came off DISK — nothing sanitises these
      (push (list :item-id (format nil "e~d" (length items)) :kind "tool_result" :ts 0
                  :item (list :type "tool_result" :call-id "c" :name "edit"
                              :outcome (list :outcome "ok") :payload ""
                              :edit (list :path "/tmp/probe.lisp"
                                          :before (format nil "keep~%~a~%" p)
                                          :after (format nil "keep~%~a~%" p))))
            items))
    (setf (session-items s) (coerce (nreverse items) 'vector)
          (head-cols h) 100 (head-rows h) 40)
    (screen-resize (head-screen h) 100 40)
    (screen-resize (head-prev-screen h) 100 40)
    ;; **EVERY SOURCE'S SEGMENTS CARRY THE BYTES**, which is the honest half: this head
    ;; does NOT sanitise the model's prose, and the reader should know that the safety
    ;; is at the painter rather than at the source
    (let ((carried 0))
      (dolist (p +§3-1-payloads+)
        (let ((row (segs-of (item-lines (list :item-id "x" :kind "assistant" :ts 0
                                              :item (list :type "assistant" :text p
                                                          :tool-calls nil))
                                        90 (list :show-tools nil)))))
          (when (%terminal-driving-chars row) (incf carried))))
      (is (plusp carried)
          "the SEGMENTS are unsanitised: ~d of ~d payloads reach them whole — the
 safety is the painter's, not the source's"
          carried (length +§3-1-payloads+)))
    ;; **AND NOT ONE REACHES THE FRAME.** What goes to fd 1 is `screen-rows-ansi`,
    ;; which is also what `/cells` sends and what ScreenRequested answers.
    (leticl::%render h)
    (let* ((rows (leticl::screen-rows-ansi (head-screen h)))
           (frame (apply #'concatenate 'string rows)))
      ;; **NOT "no ESC anywhere"** — the frame is FULL of the head's own, which is
      ;; what makes this a real measurement rather than a vacuous pass:
      (is (plusp (count #\Esc frame))
          "the frame carries the head's own escapes, so this is not a plain frame")
      ;; what must be absent is the CONTENT's introducer followed by its own text:
      ;; `ESC[31m`, `ESC[?1002h`, `ESC]0;`. Each is the payload with its leading
      ;; control character re-attached, because that is what makes it a sequence —
      ;; the letters on their own are harmless and are expected to survive.
      (dolist (p +§3-1-payloads+)
        (let ((needle (concatenate 'string
                                   (string #\Esc)
                                   (subseq p 1 (min (length p) 8)))))
          (is (not (search needle frame))
              (format nil "no ~s anywhere on the frame — the introducer was dropped"
                      needle))))
      ;; and every sequence the frame DOES carry begins one of the head's own forms,
      ;; which is the positive half of the same statement
      (let ((seqs (leticl::%esc-sequences frame)))
        (is (plusp (length seqs)) "the frame has sequences, all the head's")
        (dolist (q seqs)
          (is (every (lambda (c) (or (char= c #\Esc)
                                     (digit-char-p c)
                                     (member c '(#\[ #\; #\? #\m #\l #\h #\K #\J #\A #\B #\C #\D #\H #\q #\s #\u))))
                     (subseq q 1))
              (format nil "~s is a form this head authors" q)))))))

(def-test the-cell-grid-cannot-store-a-zero-width-cluster (:suite leticl)
  "The mechanism, at its own layer, so a change to the painter breaks this test rather
than the guarantee.

`screen-put-string` skips a cluster of zero columns, and a control character measures
zero — so a control character cannot reach a CELL, whatever the caller does. And
`plain-columns-p` refuses a string containing `+esc+`, so the one-character fast path
cannot be the hole either: anything with an escape in it takes the cluster walk."
  (is (= 0 (leticl::%code-width 27)) "ESC (0x1B) is zero columns")
  (is (= 0 (leticl::%code-width #x9b)) "so is 8-bit CSI")
  (is (= 0 (leticl::%code-width #x7f)) "so is DEL")
  (is (not (leticl::plain-columns-p (format nil "a~C[31mb" #\Esc)))
      "and a string holding one is never taken down the fast path")
  (is (leticl::plain-columns-p "plain ascii")
      "while a plain string still is, which is what makes the fast path worth having")
  (let ((scr (leticl::make-screen 20 2)))
    (leticl::screen-put-string scr 0 0 (format nil "a~C[31mb~C[0mc" #\Esc #\Esc))
    (let ((row (loop for c from 0 below 20 collect (leticl::cell-ch (leticl::screen-cell scr 0 c)))))
      (is (equal '(#\a #\b #\c) (remove #\space (subseq row 0 4)))
          "only the letters land in cells: ~s" (subseq row 0 6))
      (is (not (find #\Esc row))
          "and the escape is in none of them"))))

;;; ------------------ FetchRow: the rows above this head's window ------------------ ;;;
;;;
;;; `items_dropped` is stored and read by NOTHING: a head on a long session holds the
;;; NEWEST slice of the conversation and its transcript simply begins there, which is
;;; what a session whose first row that is also looks like. The two facts must not look
;;; alike — R17's rule, for a row nobody has rather than for a body nobody has yet.
;;;
;;; The wire spelling below is pinned against a REAL daemon, not against the plist this
;;; head happens to expect (`tools/rowfetch2.py` in the notes):
;;;
;;;     asking: {"frame": "fetch_row", "session_id": "s-…", "row": 99999, …}
;;;     <- {"frame":"row_fetched","session_id":"s-…","row":99999,"at":0,"body":null,"total":0}
;;;     (unknown session) <- {"frame":"rejected","reason":"no such session "s-not-here""}

(defun %session-with-a-window (&key (dropped 5) (rows 3))
  "A head holding ROWS rows with DROPPED before them — a window, not a conversation."
  (let* ((h (%on-head :cols 80 :rows 24))
         (s (head-session h)))
    (setf (session-items s)
          (coerce (loop for i from 0 below rows
                        collect (list :item-id (format nil "w~d" i) :kind "user" :ts 0
                                      :item (list :type "user"
                                                  :parts (list (list :kind "text"
                                                                     :text (format nil "row ~d" i))))))
                  'vector)
          (session-items-dropped s) dropped
          (session-session-id s) "s-window")
    h))

(def-test a-row-is-asked-for-by-its-ordinal-and-not-by-an-index (:suite leticl)
  "The frame's shape, against what the daemon accepted.

`row` is the row's **position in the session, oldest first** — `0` is the first row
ever — and not an index into the daemon's window (`protocol.rs:783-797`). The
arithmetic that makes it expressible is `items_dropped - 1`: a head knows how many rows
came before the ones it holds, so *the row above my oldest* has a name even though the
row itself is nowhere in the head."
  (is (equal "fetch_row" (getf (make-fetch-row "s-1" 7) :frame))
      "the tag is the wire's, snake_case, as the daemon's serde expects")
  (let ((f (make-fetch-row "s-1" 7 :at 100 :len 4096)))
    (is (equal "s-1" (getf f :session-id)) "the session, named as the head names it")
    (is (= 7 (getf f :row)) "the ordinal")
    (is (= 100 (getf f :at)) "where in the body to start")
    (is (= 4096 (getf f :len)) "and how much to send"))
  (is (= +row-fetch-len+ (getf (make-fetch-row "s" 0) :len))
      "the default window is the daemon's own cap")
  ;; the ordinal arithmetic, on a head that holds a window
  (let ((h (%session-with-a-window :dropped 5)))
    (is (= 4 (rows-above (head-session h)))
        "the row above the oldest held one is `items_dropped - 1`"))
  (let ((h (%session-with-a-window :dropped 0)))
    (is (null (rows-above (head-session h)))
        "and a head holding the WHOLE conversation has nothing above it")))

(def-test reaching-the-top-asks-for-the-row-above (:suite leticl)
  "**On demand, and the trigger is the reader reaching the oldest line they have.** The
other option — eager filling — would fetch exactly what `ViewBounds` refused to put in
the snapshot: thousands of rows, over a socket that already costs the daemon a clone
per attaching head, for an operator who is looking at the newest end of the
conversation.

Three refusals, and each is a fact rather than a guard: nothing above, a request
already in flight, and the daemon having already said those rows are gone."
  (let* ((leticl::*row-fetch* nil) (leticl::*rows-above-gone* nil)
         (h (%session-with-a-window :dropped 5))
         (wire (%wire h)))
    (is (fetch-row-above h) "the ask goes out")
    (let ((f (first (%sent wire))))
      (is (equal "fetch_row" (getf f :frame)) "as a fetch_row")
      (is (equal "s-window" (getf f :session-id)) "for this session")
      (is (= 4 (getf f :row)) "and for the ordinal above the window"))
    (is (not (null leticl::*row-fetch*)) "the request is recorded")
    ;; ONE IN FLIGHT: a transcript has one top, and this is what stops a wheel that
    ;; keeps turning from sending a request per tick. `%sent` DRAINS the stream, so the
    ;; second call is the check that nothing new was written — which is the fact, rather
    ;; than a count of what the first call already took away.
    (is (null (fetch-row-above h)) "a second ask is refused")
    (is (null (%sent wire)) "and nothing further goes on the wire")
    ;; the daemon says they are gone: the seam stops offering, and so does the head
    (setf leticl::*row-fetch* nil leticl::*rows-above-gone* t)
    (is (null (fetch-row-above h))
        "and a head that has been told the rows are gone does not ask again")
    ;; nothing above at all
    (let* ((leticl::*rows-above-gone* nil)
           (h2 (%session-with-a-window :dropped 0))
           (wire2 (%wire h2)))
      (is (null (fetch-row-above h2)) "a full transcript asks for nothing")
      (is (null (%sent wire2)) "and sends nothing"))))

(def-test scrolling-past-the-top-fires-the-ask (:suite leticl)
  "The trigger, through the key loop — the reader's own gesture rather than a test
calling the function.

`*scroll-max*` is what the renderer last clamped the scroll to, so `(>= scroll max)`
BEFORE the increment means *the reader was already at the top and has asked to go
further*. It is a key handler and not the renderer that sends, because a render with a
side effect on the socket is a render that behaves differently on a second paint."
  (let* ((leticl::*row-fetch* nil) (leticl::*rows-above-gone* nil)
         (leticl::*scroll-max* 40)
         (h (%session-with-a-window :dropped 5))
         (wire (%wire h)))
    ;; not at the top yet: a scroll is a scroll
    (setf (head-scroll h) 10)
    (leticl::%handle-key h (list :type :wheel-up))
    (is (null (%sent wire)) "scrolling in the middle of the transcript asks for nothing")
    (is (= 13 (head-scroll h)) "and it just scrolls")
    ;; AT the top: the reader has asked for more than the head has
    (setf (head-scroll h) 40)
    (leticl::%handle-key h (list :type :wheel-up))
    (let ((f (first (%sent wire))))
      (is (equal "fetch_row" (getf f :frame)) "at the top, the wheel asks for the row above")
      (is (= 4 (getf f :row)) "the ordinal above the window"))
    ;; and PageUp does the same, because it is the same gesture
    (setf leticl::*row-fetch* nil (head-scroll h) 40)
    (leticl::%handle-key h (list :type :page-up))
    (is (equal "fetch_row" (getf (first (%sent wire)) :frame)) "PageUp too")))

(def-test a-fetched-row-goes-at-the-top-and-the-count-follows (:suite leticl)
  "**A prepend, and the count with it.** The transcript is oldest-first and grows at the
END, so a row discovered on the older side goes in FRONT of every row held.

`items_dropped` is decremented in the same breath, and that is not bookkeeping: the
count and the items must keep summing to the session's length, or `rows-above` starts
naming the wrong row — the next scroll would ask for a row it has already got."
  (let* ((leticl::*row-fetch* (list :row 4 :at 0))
         (leticl::*rows-above-gone* nil)
         (h (%session-with-a-window :dropped 5 :rows 3))
         (s (head-session h)))
    (is (eq :dirty (note-row-fetched s 4 "the body of row four" 994))
        "the fold is a visible change")
    (is (null leticl::*row-fetch*) "and it clears the request")
    (is (= 4 (length (session-items s))) "the transcript gained the row")
    (let ((item (aref (session-items s) 0)))
      (is (equal "leticl-row-4" (getf item :item-id)) "at the FRONT, where its ordinal puts it")
      (is (equal "4" (format nil "~a" (getf (getf item :item) :row))) "carrying its ordinal")
      (is (equal "the body of row four" (getf (getf item :item) :text)) "and its body"))
    (is (equal "w0" (getf (aref (session-items s) 1) :item-id))
        "in front of the row that was oldest")
    (is (= 4 (session-items-dropped s))
        "and the count of rows before the window came down with it")
    (is (= 3 (rows-above s)) "so the NEXT row named is the one above this one")))

(def-test a-row-the-daemon-does-not-hold-is-not-an-empty-row (:suite leticl)
  "`body: null` is the daemon saying it does not hold that ordinal — trimmed from ITS
view, which is bounded by the same `ViewBounds` — and *\"nobody has it\"* and *\"it is
empty\"* must not look alike (`view.rs:732-740`, `server.rs:683-690`).

Measured against a real daemon: an ordinal past the end answers
`{\"frame\":\"row_fetched\",…,\"body\":null,\"total\":0}` — the row is not there, and
NOT a row of nothing. The head marks the rows above unreachable rather than asking
again for each of them, which is one request per scroll to be told the same thing."
  (let* ((leticl::*row-fetch* (list :row 4 :at 0))
         (leticl::*rows-above-gone* nil)
         (h (%session-with-a-window :dropped 5 :rows 3))
         (s (head-session h)))
    (is (eq :dirty (note-row-fetched s 4 nil 0)) "the answer is a visible change")
    (is (null leticl::*row-fetch*) "the request is over")
    (is (not (null leticl::*rows-above-gone*)) "and the rows above are known to be gone")
    (is (= 3 (length (session-items s))) "NOTHING is prepended: a missing row is not a row")
    (is (= 5 (session-items-dropped s)) "and the count does not move either")
    (is (null (fetch-row-above h)) "so the head does not ask again")
    ;; and a row that arrives while nothing is pending is ignored, not appended
    (let* ((leticl::*row-fetch* nil)
           (h2 (%session-with-a-window :dropped 5 :rows 3))
           (s2 (head-session h2)))
      (is (eq :quiet (note-row-fetched s2 4 "unsolicited" 11))
          "an answer to a question this head is not asking is not a row")
      (is (= 3 (length (session-items s2)))))))

(def-test the-seam-above-the-window-says-what-is-above-it (:suite leticl)
  "**A window that does not say it is a window is read as the whole conversation.**
Scroll to the top of a long session and the transcript ends as cleanly as a session
whose first row that is — and the operator has no way to tell the two apart.

Three states, because there are three facts: rows above that this head will load,
a request in flight, and rows the daemon does not hold either. The last is the one that
matters most — it stops promising a fetch that cannot happen."
  ;; nothing above: no seam at all, because a head holding everything has nothing to say
  (let ((h (%session-with-a-window :dropped 0)))
    (is (null (rows-above-line (head-session h) 80))
        "a head holding the whole conversation draws no seam"))
  (let* ((leticl::*row-fetch* nil) (leticl::*rows-above-gone* nil)
         (h (%session-with-a-window :dropped 5))
         (text (segs-of (rows-above-line (head-session h) 80))))
    (is (search "5 rows above" text) "the count, from the snapshot's own number: ~s" text)
    (is (search "scroll to this line" text) "and the gesture that loads one")
    (is (equal '(:dim t) (cdr (first (first (rows-above-line (head-session h) 80)))))
        "dim, like every other seam in this tree: an instrument, not the conversation")
    ;; asking
    (setf leticl::*row-fetch* (list :row 4 :at 0))
    (is (search "asking the daemon for row 4" (segs-of (rows-above-line (head-session h) 80)))
        "a request in flight names the row it is waiting for")
    ;; gone
    (setf leticl::*row-fetch* nil leticl::*rows-above-gone* t)
    (let ((text (segs-of (rows-above-line (head-session h) 80))))
      (is (search "does not hold them any more" text) "and gone rows say so: ~s" text)
      (is (not (search "scroll to this line" text))
          "and stop offering a fetch that cannot happen"))))

(def-test the-seam-is-drawn-at-the-top-of-the-viewport (:suite leticl)
  "And it reaches the glass: the first line of the transcript, above the oldest row."
  (let* ((leticl::*row-fetch* nil) (leticl::*rows-above-gone* nil)
         (h (%session-with-a-window :dropped 5 :rows 3)))
    ;; scrolled all the way up, so the top of the transcript is on screen
    (setf (head-scroll h) 1000)
    (let* ((lines (leticl::%viewport-lines h 80 20))
           (text (segs-of lines)))
      (is (search "5 rows above" text) "the seam is on the screen: ~s" (subseq text 0 (min 200 (length text))))
      ;; and it is ABOVE the oldest row, not below it
      (is (< (search "5 rows above" text) (search "row 0" text))
          "above the first row the head holds"))))

;;; ------------------- the eval socket: a client's failure is not the head's ------- ;;;
;;;
;;; The live-modification surface (HACKING.md). MEASURED on a scratch head: a client
;;; that vanished between its request and its reply killed the PROCESS —
;;;
;;;     round 1: head alive after the client vanished mid-reply: False
;;;     VERDICT: THE HEAD IS DEAD
;;;     ... (HACK-SERVE) ... (SB-IMPL::%WRITE-LINE ...)
;;;     unhandled condition in --disable-debugger mode, quitting
;;;
;;; — because `hack-serve`'s write was unguarded and it ran in a non-main thread,
;;; where an unhandled error quits a `--disable-debugger` image. A `tui-eval`
;;; interrupted at the wrong moment took the operator's session with it.

(defun %socket-pair ()
  "A connected `(values SERVER CLIENT)` pair of unix sockets, and their path.

Built rather than taken from `sb-bsd-sockets`, which has no `socket-pair`
(`find-symbol` answers NIL). The path is under the test's own scratch directory so
a stale file cannot collide with anything.
"
  (let* ((path (format nil "/tmp/leticl-test-hack-~d.sock" (sb-posix:getpid)))
         (listen (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
    (ignore-errors (delete-file path))
    (sb-bsd-sockets:socket-bind listen path)
    (sb-bsd-sockets:socket-listen listen 1)
    (let ((client (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (sb-bsd-sockets:socket-connect client path)
      (let ((server (sb-bsd-sockets:socket-accept listen)))
        (ignore-errors (sb-bsd-sockets:socket-close listen))
        (values server client path)))))

(def-test a-client-that-vanishes-mid-reply-does-not-take-the-head-down (:suite leticl)
  "**A client that has gone is a client, not a head failure.**

`hack-serve`'s `write-line` and `force-output` ran unguarded in a thread made by
`hack-accept-loop`, and a client that disappeared between its request and its reply
signalled `BROKEN-PIPE` out of a NON-MAIN thread — where, in an image saved with
`--disable-debugger`, an unhandled error QUITS THE PROCESS. Measured end to end
against a scratch head: the head was dead before its first sleep was over.

**`unwind-protect` was already there and is not the fix** — it closes the connection
on the way out and then RE-RAISES, which is exactly why the process died rather than
the connection. The guard has to be a `handler-case`.

The write is what meets the gone client, so the test drives it: the client asks a
question and closes without reading, which is what a killed `tui-eval` looks like.
The form is `(sleep 0.2)` so there is a window in which the client can leave — the
same window the real one has."
  (multiple-value-bind (server client path) (%socket-pair)
    (unwind-protect
         (progn
           ;; the client asks, then goes, exactly as a killed tui-eval does
           (let ((cstream (sb-bsd-sockets:socket-make-stream
                           client :input t :output t :element-type 'character
                           :external-format :utf-8 :buffering :none)))
             ;; hold the client open to send, then close it BEFORE the reply is written
             (write-line "eval (progn (sleep 0.2) :answered)" cstream)
             (force-output cstream)
             (close cstream))
           (let ((h (leticl::%make-head)))
             ;; in the MAIN thread: a regression is a test failure, not a dead image
             (finishes (leticl::hack-serve h server)
                       "the connection ends quietly instead of signalling")))
      (ignore-errors (sb-bsd-sockets:socket-close server))
      (ignore-errors (sb-bsd-sockets:socket-close client))
      (ignore-errors (delete-file path)))))

(def-test a-failed-accept-is-retried-and-counted-rather-than-ending-the-loop (:suite leticl)
  "**A failed accept is not a reason to stop accepting.**

`hack-accept-loop` read `(error () (return))`: ANY accept error ended the loop for the
REST OF THE HEAD'S LIFE, and the socket file stayed on disk because `hack-stop` owns
the `delete-file`. A path with nothing listening behind it is what this file's own
watchdog already describes — *\"the process was alive, logged nothing, looked healthy,
and was permanently deaf\"* — and here the loss is the whole live-modification surface
HACKING.md documents. It is the same defect the session daemon paid for and wrote down
(`sessionlog/src/server.rs`: *\"a failed accept is almost never a reason to stop
accepting\"*).

**What I could NOT reproduce, said plainly, and one thing I found instead:**

- the TRIGGER is unproven. Eight connect-and-vanish clients in a row raised no accept
  error — a socket that closes before being picked up is accepted cleanly and ends at
  `read-line` — so the hazard is visible in the source and has no field reproduction.
  The fix is kept because the failure mode is silent and permanent if it does happen;
- **and `socket-accept` on a listener closed UNDERNEATH it neither errors nor returns
  — it blocks for ever** (measured). So the retry covers the errors that RETURN
  (`BAD-FILE-DESCRIPTOR-ERROR` when the fd is already gone, `EMFILE` under pressure),
  and `hack-stop`'s slot-clearing is a courtesy that the loop usually cannot read,
  because it is asleep inside accept. Worth knowing before anyone tries to stop this
  thread on purpose.

This test uses the shape that IS deterministic: the listener is closed before any
accept is attempted, so every accept errors at once and the behaviour is pinned
rather than raced."
  (let* ((before *hack-accept-errors*)
         (path (format nil "/tmp/leticl-test-accept-~d.sock" (sb-posix:getpid)))
         (head (leticl::%make-head))
         (listen (make-instance 'sb-bsd-sockets:local-socket :type :stream))
         (thread nil))
    (ignore-errors (delete-file path))
    (sb-bsd-sockets:socket-bind listen path)
    (sb-bsd-sockets:socket-listen listen 4)
    (sb-bsd-sockets:socket-close listen)      ; gone BEFORE the loop ever looks
    (setf (head-hack-listener head) listen)
    (unwind-protect
         (progn
           (setf thread (sb-thread:make-thread
                         (lambda () (hack-accept-loop head))
                         :name "leticl hack test"))
           (sleep 0.3)
           (is (sb-thread:thread-alive-p thread)
               "an accept that fails does NOT end the loop: it is still listening")
           (is (> *hack-accept-errors* before)
               "and the failure is COUNTED, because a head that stopped accepting and
 did not say so cannot be told from a head nobody has asked")
           ;; **and it still ends when it SHOULD** — the listener being gone for good,
           ;; which is `hack-stop` and nothing else. Here the accept returns an error
           ;; at once rather than blocking, so the loop reaches its top and sees it.
           (setf (head-hack-listener head) nil)
           (loop repeat 40 until (not (sb-thread:thread-alive-p thread)) do (sleep 0.02))
           (is (not (sb-thread:thread-alive-p thread))
               "and it ends when the listener is cleared, which is `hack-stop` and
 nothing else"))
      (setf (head-hack-listener head) nil)
      (when (and thread (sb-thread:thread-alive-p thread))
        (ignore-errors (sb-thread:join-thread thread :timeout 1)))
      (ignore-errors (sb-bsd-sockets:socket-close listen))
      (ignore-errors (delete-file path))
      (setf *hack-accept-errors* before))))

(def-test the-status-screen-says-whether-the-head-can-still-be-evaluated (:suite leticl)
  "A head that has stopped accepting eval connections runs on with a socket file and
nothing behind it — so whether it is still listening, and how many accepts failed, is
a `/status` row: *a number a head keeps and does not show is a number nobody can act
on*, which this file's own docstring says about the counters it replaced.

0 failed accepts on a head that has never had one, and that is a DIFFERENT reading
from a head that does not count them — the rule the `unreadable` row already keeps."
  (let ((*hack-accept-errors* 0)
        (h (%pane-head)))
    (let ((text (lines-text (leticl::status-screen-lines h 210))))
      (is (some (lambda (l) (search "NO listening · 0 failed accept" l)) text)
          "a head with no listener says so, and calls it NO: ~s"
          (find-if (lambda (l) (search "listening" l)) text)))
    ;; and a live listener reads yes, with the count of failures it has survived
    (let ((*hack-accept-errors* 3)
          (h2 (%pane-head)))
      (setf (head-hack-listener h2) :a-listener)
      (let ((text (lines-text (leticl::status-screen-lines h2 210))))
        (is (some (lambda (l) (search "yes listening · 3 failed accepts" l)) text)
            "a listening head says yes and counts its failures: ~s"
            (find-if (lambda (l) (search "listening" l)) text))))))

(def-test a-gap-in-the-event-stream-is-said-counted-and-filed (:suite leticl)
  "**MISSING IN BOTH HEADS**, and the last item of §10: *neither checks `seq`
continuity*.

`session-dropped` is what the DAEMON says it threw away — it arrives on a `Hello` and
on a `Resync`, so a head that attached before the daemon's scrollback overflowed is
told, and a head that merely fell behind mid-batch is not. A jump of eleven on the
wire is the second kind, and it turns a transcript into a document with a hole in it
and no mark in it.

**A step of one is not a gap, and neither is a step backwards.** A reconnect replays
from the read mark by design (§13.2b: *a crash then costs a duplicate, never a
silence*), so both of those are the protocol working, and a head that reported them
would cry wolf on every reconnect."
  (let* ((leticl::*filed-notes* 0) (leticl::*seq-gaps* 0)
         (h (%make-head))
         (s (head-session h)))
    (flet ((rows () (loop for i across (session-items s)
                          when (equal (getf (getf i :item) :type) "note") collect i)))
      ;; a mark of ZERO is nothing-folded-yet, and a first event at any seq is not a
      ;; gap: a head attaching to a session already at seq 5 is told by `resumed_from`
      (apply-event s (list :seq 40 :event "head_attached" :head-id "h" :kind "tui"
                           :identity "x"))
      (is (zerop leticl::*seq-gaps*) "the first event is never a gap")
      (is (null (rows)) "and files nothing")
      ;; **the gap**: 40 -> 52 is eleven events nobody will ever see
      (apply-event s (list :seq 52 :event "head_detached" :head-id "h"))
      (is (= 1 leticl::*seq-gaps*) "a jump forward is counted")
      (let ((r (first (rows))))
        (is (not (null r)) "and filed as a row in the conversation")
        (is (search "jumped from 40 to 52" (getf (getf r :item) :text))
            "naming both ends: ~s" (getf (getf r :item) :text))
        (is (search "11 event" (getf (getf r :item) :text)) "and how many went missing")
        (is (search "/resync" (getf (getf r :item) :text))
            "and the verb that takes a fresh snapshot"))
      ;; **not a gap**: the next one is contiguous
      (apply-event s (list :seq 53 :event "head_detached" :head-id "h"))
      (is (= 1 leticl::*seq-gaps*) "a step of one is not a gap")
      ;; **not a gap**: a redelivery after a reconnect, which goes BACKWARDS
      (apply-event s (list :seq 50 :event "head_detached" :head-id "h"))
      (is (= 1 leticl::*seq-gaps*) "a step backwards is a redelivery, not a hole")
      (is (= 1 (length (rows))) "so only one row was ever filed"))))

(def-test the-emacs-motions-the-reference-decodes-are-bound (:suite leticl)
  "§6. The reference binds `ctrl-b`, `ctrl-f` and `ctrl-_` in its DECODER
(`term.rs:562-576, 590-594`: `0x02` → Left, `0x06` → Right, `0x1f` → Undo) and this
head had no arm for any of the three — so the chords did nothing on a head carrying
the rest of the emacs set (`ctrl-a`, `ctrl-e`, `ctrl-k`, `ctrl-u`, `ctrl-w`, `ctrl-y`,
`ctrl-z`).

**`ctrl-_` is `0x1f`, which `read-key` maps to `(code-char 127)`** — the character
SBCL names `#\Rubout`. It cannot collide with a backspace: a literal `0x7f` is matched
EARLIER in `read-key`, as `:type :backspace`, so only `0x1f` ever arrives as a `:ctrl`
holding Rubout. Both spellings of undo therefore work and neither eats the other."
  (let ((h (%on-head :cols 80 :rows 24 :buffer "hello world")))
    (flet ((chord (ch)
             (leticl::%handle-key h (list :type :ctrl :ch ch))))
      ;; ctrl-b / ctrl-f move the cursor, and neither touches the text
      (setf (leticl::composer-cursor (head-composer h)) 5)
      (chord #\b)
      (is (= 4 (leticl::composer-cursor (head-composer h))) "ctrl-b goes left")
      (chord #\f)
      (is (= 5 (leticl::composer-cursor (head-composer h))) "ctrl-f goes right")
      (is (string= "hello world" (leticl::composer-buffer (head-composer h)))
          "and neither one edits the line")
      ;; at the ends they stop rather than wrap or refuse
      (setf (leticl::composer-cursor (head-composer h)) 0)
      (chord #\b)
      (is (zerop (leticl::composer-cursor (head-composer h))) "ctrl-b at the start stays")
      (setf (leticl::composer-cursor (head-composer h)) 11)
      (chord #\f)
      (is (= 11 (leticl::composer-cursor (head-composer h))) "ctrl-f at the end stays"))
    ;; ctrl-_ undoes, the same thing ctrl-z does — **and it is pressed through the
    ;; DECODER**, because the conversion from byte to key is half of what this binds:
    ;; `0x1f` arrives as a `:ctrl` holding Rubout and never as `0x1f`
    (leticl::%undo-push (head-composer h))
    (leticl::composer-insert (head-composer h) "!")
    (is (string= "hello world!" (leticl::composer-buffer (head-composer h)))
        "a keystroke landed")
    (leticl::%handle-key h (leticl::read-key
                            (make-string-input-stream (string (code-char 31)))))
    (is (string= "hello world" (leticl::composer-buffer (head-composer h)))
        "ctrl-_ takes it back")
    ;; and the decode itself: 0x1f is a ctrl key holding Rubout, 0x7f is a backspace
    (let ((s (make-string-input-stream (string (code-char 31)))))
      (is (equal (list :type :ctrl :ch (code-char 127)) (leticl::read-key s))
          "0x1f decodes to ctrl-Rubout"))
    (let ((s (make-string-input-stream (string (code-char 127)))))
      (is (equal (list :type :backspace) (leticl::read-key s))
          "and 0x7f is still a backspace, which is why they cannot collide"))))

(def-test a-slash-command-still-works-under-the-session-picker (:suite leticl)
  "G2. The picker's hint promises `/new [title]` in the same breath as the number.
`%submit-line` checked the picker arms BEFORE the slash, so the line was read as
the name of a session to switch to (app.rs:3961-3963 puts the command first)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (%sessions h "first")
    (setf (head-mode h) :picker)
    (dolist (ch (coerce "/new notes" 'list))
      (leticl::%handle-key h (list :type :char :ch ch)))
    (leticl::%handle-key h (list :type :enter))
    (let ((f (first (%sent wire))))
      (is (equal "new_session" (getf f :frame)) "the line was a command")
      (is (equal "notes" (getf f :title)) "carrying the title typed after it"))))

(def-test the-session-picker-answers-a-name-and-refuses-an-ambiguous-one (:suite leticl)
  "G2. `pick`: a row number, or enough of an id to be unique, or a word in a
title — and an ambiguous prefix is REFUSED WITH THE COUNT rather than resolved to
the first match, because switching to the wrong session is not a keystroke you can
take back (app.rs:4068-4109)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (%sessions h "the parity pass" "the parity notes")
    (setf (head-mode h) :picker)
    (leticl::%pick-session h "parity")
    (is (null (%sent wire)) "two titles match: nothing is switched")
    (is (search "2 sessions match" (head-status-note h)) "and the count is said")
    (leticl::%pick-session h "notes")
    (is (equal "s-2" (getf (first (%sent wire)) :session-id)) "a unique word switches")))

(def-test the-ladder-moves-with-a-half-typed-line-and-holds-the-words (:suite leticl)
  "G21. The operator, 2026-09-20: *\"suppose i type a prompt and permission ask
arrives — until i press down arrow I wont get into the permissions menu, by which
time my prompt is erased and gone\"*. The whole ladder was gated on an empty
composer (editor.lisp:332), so the words you were writing were the price of
choosing an option.

**Up and Down move whether or not a line is being typed; Enter on a line that
NAMES no option answers NOTHING.** That last part is a departure from the
reference, and it was this test that pinned the old behaviour: the words are held
either way, but the ask used to be answered at the MARKED ROW while the status line
said *\"answered the ask\"* — a gate sending an answer the operator did not give.
The line is still held, and the ask is still open."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (composer-insert (head-composer h) "some prose")
    (leticl::%handle-key h (list :type :down))
    (is (= 1 (leticl::head-decision-sel h)) "down moves the ladder with a line typed")
    (is (string= "some prose" (composer-buffer (head-composer h))) "and takes nothing from it")
    (is (null (%sent wire)) "and answers nothing yet")
    (leticl::%handle-key h (list :type :enter))
    (is (null (%sent wire))
        "enter on a line that names no option answers NOTHING — not the marked row")
    (is (string= "some prose" (composer-buffer (head-composer h)))
        "and the words are held, not sent under the ask")
    (is (search "names no option" (head-status-note h)) "and it says why")))

(def-test a-typed-word-that-names-no-option-sends-nothing (:suite leticl)
  "THE REQUESTED TEST, and the whole point of the item: a gate that can send an
answer the operator did not give.

Typing `allow` against the live ladder matched nothing — there was no prefix
fallback — fell through to the arm that answers the MARKED ROW, and reported
*\"answered the ask\"*. So the assertion is not only that the ask stays open: it is
that **nothing at all reaches the wire**, which is the only version of this that
cannot be satisfied by accident.

Every word here names no option: a typo, a word from the question, and a bare
number past the end of the ladder."
  (dolist (typed '("alow" "maybe" "the file please" "9" "%"))
    (let* ((h (%on-head :cols 80 :rows 24))
           (wire (%wire h)))
      (setf (session-open-decisions (head-session h)) (list (%decision-with)))
      (composer-insert (head-composer h) typed)
      (leticl::%handle-key h (list :type :enter))
      (is (null (%sent wire))
          (format nil "~s names no option, so no frame is sent" typed))
      (is (string= typed (composer-buffer (head-composer h)))
          "the line is held, not consumed")
      (is (search "names no option" (head-status-note h)) "and the reason is said")
      (is (= 1 (length (session-open-decisions (head-session h))))
          "and the ask is still open"))))

(def-test a-prefix-names-an-option-when-it-is-unambiguous (:suite leticl)
  "The fallback the docstring promised and the body never implemented.

`reject_` prefixes `reject_always` and nothing else, so it resolves. `deny` is
exact. Both spellings were words that matched nothing at all before this."
  (let ((d (%decision-with)))
    (multiple-value-bind (id tag extra) (match-option d "reject_")
      (is (string= "reject_always" id) "an unambiguous prefix resolves")
      (is (eq :option tag) "as an option id, which the tag says")
      (is (null extra) "with no extra"))
    (multiple-value-bind (id tag extra) (match-option d "deny")
      (is (string= "deny" id) "and an exact id still wins over any prefix")
      (is (eq :option tag))
      (is (null extra)))
    ;; case-insensitively, on the id and on the label. A multi-word label is split
    ;; at its first space — as the reference does, and it is the reason the ID is
    ;; the spelling that always works: `Allow Once` leaves `Once` as trailing
    ;; words, which a plain option refuses.
    (multiple-value-bind (id tag extra) (match-option d "REJECT_ALWAYS")
      (is (string= "reject_always" id) "the id is case-insensitive")
      (is (eq :option tag))
      (is (null extra)))
    ;; **A MULTI-WORD LABEL DOES NOT RESOLVE, and that is shared with the
    ;; reference** rather than being a divergence: the line is split at its first
    ;; space before anything is matched, so `Always allow` arrives as the word
    ;; `Always`, which prefixes no id. The ID is the spelling that always works;
    ;; a label is for reading. Asserted so the limit is recorded rather than
    ;; discovered.
    (multiple-value-bind (m tag why) (match-option d "Always allow")
      (is (null m) "`Always allow` names no option — its first word is `Always`")
      (is (null tag) "and nothing is picked")
      (is (search "names no option" why) "and the reason says so"))
    ;; the prefix still yields its note the way an exact match does
    (multiple-value-bind (id tag note) (match-option d "reject_always because")
      (is (string= "reject_always" id))
      (is (eq :note tag) "and the tag names the field the words go in")
      (is (string= "because" note) "and the trailing words are the note"))))

(def-test an-ambiguous-prefix-is-refused-and-names-the-candidates (:suite leticl)
  "**Why this refuses rather than taking the first match.**

The live ladder is `allow_once, allow_session, allow_always`: `allow` prefixes
three options, so *\"the option whose id it matches\"* has no single referent.
Granting one of them by its position in a list is an answer the operator did not
give — `allow_once` if the list happens to start that way, `allow_always` if it
does not, and the difference is a standing rule versus a single call.

The reference takes the first match, which it can afford because its fallback is to
answer the marked row anyway. Here the fallback is to decline, so declining costs
one more character and cannot grant what was not named."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h))
         (d (list :req-id "adj-9" :kind "permission" :summary "run"
                  :options (list (list :option-id "allow_once" :kind "allow_once")
                                 (list :option-id "allow_session" :kind "allow_session")
                                 (list :option-id "allow_always" :kind "allow_always")))))
    (multiple-value-bind (m tag why) (match-option d "allow")
      (is (null m) "an ambiguous prefix does not resolve")
      (is (null tag))
      (is (search "allow_once" why) "and the candidates are named")
      (is (search "allow_session" why) "all of them")
      (is (search "allow_always" why) "not just the first"))
    ;; and on a live head it sends nothing and keeps the ask
    (setf (session-open-decisions (head-session h)) (list d))
    (composer-insert (head-composer h) "allow")
    (leticl::%handle-key h (list :type :enter))
    (is (null (%sent wire)) "an ambiguous word sends nothing")
    (is (search "matches" (head-status-note h)) "and says which options it matched")))

(def-test a-new-decision-starts-with-the-first-row-marked (:suite leticl)
  "The reference's own reason (app.rs:3582-3590): *\"the highlight must never be
somewhere the operator did not put it when Enter is one key away\"*.

This head never reset the cursor — `endp-open` in `session.lisp` was called on
every ask and did nothing, and the slot was zeroed only after an answer went out.
So an ask inherited the cursor of the last one, and combined with the no-match arm
answering the marked row, a typed line that named nothing was answered at a row
selected for a decision already dealt with."
  (let ((h (%on-head :cols 80 :rows 24)))
    ;; the operator moves the cursor on the FIRST ask
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (leticl::%handle-key h (list :type :down))
    (leticl::%handle-key h (list :type :down))
    (is (= 2 (leticl::head-decision-sel h)) "two downs, row 2")
    ;; and a NEW ask arrives
    (leticl::%handle-frame
     h (list :frame "event" :event "decision_requested" :seq 7
             :req-id "adj-2" :kind "permission" :summary "another"
             :options (list (list :option-id "allow_once" :kind "allow_once")
                            (list :option-id "allow_always" :kind "allow_always"))))
    (is (= 0 (leticl::head-decision-sel h))
        "the fresh ask starts at its FIRST row, not the row the last one was left on")
    (is (head-dirty h) "and the frame is marked for a repaint")))

(def-test a-redelivered-ask-is-the-same-question-not-a-fresh-one (:suite leticl)
  "A reconnect replays from the read mark, so a `decision_requested` the head has
ALREADY drawn arrives a second time, same `req_id`. Measured on the live head,
two deliveries of one `req_id` left the open list at 2 and three left it at 3,
and a `down` that put the cursor on row 1 was undone by the redelivery putting
it back to 0 — which is exactly what *\"the selector does not work\"* looked like.

One `req_id` names one question for its whole life, so a redelivery REPLACES the
open entry instead of appending a twin: the reference does it in one line ahead
of its push (app.rs:2596, `self.open.retain(|d| d.req_id != req_id)`). The
reference also zeroes its cursor inside that same arm, where the old entry is
already gone; this head's cursor hook runs BEFORE `apply-event` drops the twin,
so the twin is still in the list to be asked about — and a redelivery is not the
FRESH question its reset is for."
  ;; the session's own rule, without a head in the way
  (let ((s (make-session)))
    (apply-event s (list :seq 1 :event "decision_requested" :req-id "r1"
                         :kind "permission" :summary "run a program" :options nil))
    (apply-event s (list :seq 1 :event "decision_requested" :req-id "r1"
                         :kind "permission" :summary "run a program" :options nil))
    (is (= 1 (length (session-open-decisions s)))
        "the same req_id twice is still one open decision")
    (apply-event s (list :seq 2 :event "decision_requested" :req-id "r2"
                         :kind "permission" :summary "another" :options nil))
    (is (= 2 (length (session-open-decisions s))) "a new req_id is a second one"))
  (let ((h (%on-head :cols 80 :rows 24)))
    (flet ((deliver (req)
             (leticl::%handle-frame
              h (list :frame "event" :event "decision_requested" :seq 40
                      :req-id req :kind "permission" :summary "run a program"
                      :options (list (list :option-id "allow_once" :kind "allow_once")
                                     (list :option-id "allow_always" :kind "allow_always"))))))
      (deliver "adj-1")
      (leticl::%handle-key h (list :type :down))
      (is (= 1 (leticl::head-decision-sel h)) "the operator moved the cursor to row 1")
      (deliver "adj-1")
      (is (= 1 (length (session-open-decisions (head-session h))))
          "a redelivery replaces the open entry rather than adding a twin")
      (is (= 1 (leticl::head-decision-sel h))
          "and does NOT undo the keystroke — the same question is not a fresh one")
      (deliver "adj-1")
      (is (= 1 (length (session-open-decisions (head-session h))))
          "still one entry however often it replays")
      (deliver "adj-2")
      (is (= 2 (length (session-open-decisions (head-session h))))
          "a genuinely new ask is a new entry")
      (is (= 0 (leticl::head-decision-sel h))
          "and a fresh question still starts at its first row"))))

(def-test an-open-ask-outranks-every-list-on-the-screen (:suite leticl)
  "T5. The reference asks the decision ladder BEFORE the session picker
(app.rs:3609 before :3643), the mode and models pickers (:3736) and the subagent,
todos and jobs panes (:3795, :3852, :3917) — and AFTER the subagent-output view,
the job-output view and the config pane (:3384, :3417, :3481), each opened
deliberately and each keeping the arrows it was opened for.

This head asked all of them first, because the ladder was the tail of
`%ladder-key`: with a permission up over an open session list, Up and Down moved
the PICKER and the ladder could not be reached at all until the list was closed.
Two cursors on one screen and one of them unreachable is the whole of the bug.

The cursors are read AND written on purpose, and both start at 1 for every case,
so each `is` is a measurement rather than a report: `the ladder is at 2` says the
ask took the key, `still at 1` says it did not. `%decision-key`'s Down does NOT
wrap, so the starting value has to be set per case."
  (let ((h (%head-with-settings))
        (mark 1))
    (flet ((ladder (v) (setf (leticl::head-decision-sel h) v)))
      ;; --- the session list, a LIST the ask outranks ---
      (%sessions h "one" "two" "three")
      (setf (head-mode h) :picker (head-picker-sel h) mark)
      (setf (session-open-decisions (head-session h)) (list (%decision-with)))
      (ladder 1)
      (leticl::%handle-key h (list :type :down))
      (is (= 2 (leticl::head-decision-sel h)) "down moves the LADDER over the session list")
      (is (= mark (head-picker-sel h)) "and the list's cursor has not moved")
      (ladder 1)
      (leticl::%handle-key h (list :type :up))
      (is (= 0 (leticl::head-decision-sel h)) "up moves the ladder back")
      (is (= mark (head-picker-sel h)) "and the list is still where it was")
      ;; --- the jobs pane, another one ---
      (setf (head-mode h) :jobs (head-picker-sel h) mark
            (head-jobs h) (list (list :id "j1") (list :id "j2") (list :id "j3")))
      (ladder 1)
      (leticl::%handle-key h (list :type :down))
      (is (= 2 (leticl::head-decision-sel h)) "down moves the ladder over the jobs pane")
      (is (= mark (head-picker-sel h)) "and the jobs cursor has not moved")
      ;; --- the mode picker's card ---
      (setf (head-mode h) :normal leticl::*pick-open* :mode (head-picker-sel h) mark)
      ;; **Non-vacuity first**: with no ask up, the card DOES take the Down. Without
      ;; this the case below passed for the wrong reason before the fix — the card
      ;; declined the key and the ladder at the tail of the chain happened to be
      ;; reached anyway, which is a test of the fixture and not of the order.
      (setf (session-open-decisions (head-session h)) nil)
      (leticl::%handle-key h (list :type :down))
      (is (= (1+ mark) (head-picker-sel h)) "the mode card takes Down when no ask is up")
      (setf (session-open-decisions (head-session h)) (list (%decision-with))
            (head-picker-sel h) mark)
      (ladder 1)
      (leticl::%handle-key h (list :type :down))
      (is (= 2 (leticl::head-decision-sel h)) "down moves the ladder over the mode card")
      (is (= mark (head-picker-sel h)) "and the card's cursor has not moved")
      ;; --- but the config pane was opened deliberately and keeps the arrows ---
      (setf leticl::*pick-open* nil (head-mode h) :config (head-picker-sel h) mark)
      (let ((n (length (config-rows h))))
        (is (> n 2) "the config pane has rows for its cursor to walk")
        (ladder 1)
        (leticl::%handle-key h (list :type :down))
        (is (= (1+ mark) (head-picker-sel h)) "the config pane keeps down")
        (is (= 1 (leticl::head-decision-sel h)) "and the ladder does not move"))
      ;; --- and a key the ask does NOT own falls through to the composer, which
      ;; is what `%decision-key` answering NIL is for ---
      (setf (head-mode h) :normal leticl::*pick-open* nil)
      (ladder 1)
      (leticl::%handle-key h (list :type :char :ch #\z))
      (is (string= "z" (composer-buffer (head-composer h)))
          "a letter the ask does not own is still the composer's")
      (is (= 1 (leticl::head-decision-sel h)) "and it did not move the ladder"))))

(def-test a-digit-that-names-no-row-is-the-composers (:suite leticl)
  "G21. The ladder's digits take a row; a digit past the last one is a character.
The old arm answered on any digit, so `7` on a four-option ask answered the
fourth — `(min index …)` read a typo as a decision."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (leticl::%handle-key h (list :type :char :ch #\7))
    (is (null (%sent wire)) "seven names no row, so nothing is answered")
    (is (string= "7" (composer-buffer (head-composer h))) "it is typed instead")))

(def-test ctrl-c-clears-the-line-and-takes-two-presses-to-leave (:suite leticl)
  "G10. `ctrl-c` on a half-written paragraph offered to QUIT — while `/help` and
the hint bar both promised the clear (panes.lisp:164, chrome.lisp:358) — and on an
empty composer the FIRST press opened the quit card, with no armed window and
nothing on the hint bar in between (editor.rs:466-484, `QUIT_WINDOW_MS`)."
  (let ((leticl::*ctrlc-at* nil)
        (h (%on-head :cols 80 :rows 24 :buffer "half a thought")))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (string= "" (composer-buffer (head-composer h))) "a non-empty composer is cleared")
    (is (not (head-quit-open h)) "and nothing offers to leave")
    ;; empty now: one press arms and says so, two leave
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (not (head-quit-open h)) "the first press on an empty composer only arms")
    (is (search "ctrl+c again to exit"
                (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))
        "and the hint bar says what the second press does")
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (head-quit-open h) "the second within the window opens the card")
    ;; and a press two seconds later is a fresh gesture, not the second half of one
    (setf (head-quit-open h) nil
          leticl::*ctrlc-at* (- (get-internal-real-time)
                                (* 2 internal-time-units-per-second)))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (not (head-quit-open h)) "a press two seconds after the last one arms again")))

(def-test ctrl-c-closes-what-is-on-the-screen (:suite leticl)
  "G11. The pane arm, `pick-key-event` and the secret arm had no `:ctrl` case, so
ctrl-c fell through all three and offered to quit the head instead of closing the
thing in front of the operator. With a PASSWORD ask up that left no way to refuse
it with the key a person reaches for (app.rs:3003-3011, 3273, 3306, 3321, 3379)."
  (let* ((leticl::*ctrlc-at* nil)
         (leticl::*pick-open* nil)
         (h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (head-mode h) :jobs)
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (eq :normal (head-mode h)) "ctrl-c closes a pane")
    (is (not (head-quit-open h)) "and does not offer to leave")
    (setf leticl::*pick-open* :mode)
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (null leticl::*pick-open*) "ctrl-c closes the picker card")
    (is (not (head-quit-open h)) "and does not offer to leave")
    ;; the password ask: ctrl-c REFUSES it
    (setf (head-secret-req h) (list :req-id "s1" :prompt "password"))
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (let ((f (first (%sent wire))))
      (is (equal "secret" (getf f :frame)) "a secret frame goes back")
      (is (null (getf f :secret)) "carrying no secret — the refusal"))
    (is (null (head-secret-req h)) "and the card is gone")))

(def-test the-secret-card-takes-a-typed-character (:suite leticl)
  "Found closing G11. The `:char` arm concatenated `(getf key :ch)` — a
CHARACTER — onto the buffer with `concatenate 'string`, which is a type error:
every keystroke into a password ask threw. The arm that reads a paste trims the
trailing newline the copy took with it, as the reference's does (app.rs:2988)."
  (let ((h (%on-head :cols 80 :rows 24)))
    (setf (head-secret-req h) (list :req-id "s1" :prompt "password"))
    (leticl::%handle-key h (list :type :char :ch #\h))
    (leticl::%handle-key h (list :type :char :ch #\i))
    (is (string= "hi" (leticl::head-secret-buf h)) "the characters land in the field")
    (leticl::%handle-key h (list :type :paste :text (format nil "there~%")))
    (is (string= "hithere" (leticl::head-secret-buf h)) "a pasted secret loses its trailing newline")
    (leticl::%handle-key h (list :type :ctrl :ch #\u))
    (is (string= "" (leticl::head-secret-buf h)) "and ctrl-u clears the field")))

(def-test ctrl-d-does-not-throw-away-a-line (:suite leticl)
  "G12. `ctrl-d` set `head-running` to NIL unconditionally, so the chord that
means *end of input* also meant *throw away the paragraph I am in the middle
of*. The reference quits only on an empty composer (editor.rs:485-491)."
  (let ((h (%on-head :cols 80 :rows 24 :buffer "x")))
    (leticl::%handle-key h (list :type :ctrl :ch #\d))
    (is (leticl::head-running h) "with text typed, ctrl-d does nothing")
    (leticl::%handle-key h (list :type :ctrl :ch #\c))   ; clears the line
    (leticl::%handle-key h (list :type :ctrl :ch #\d))
    (is (not (leticl::head-running h)) "on an empty one it leaves")))

(def-test the-pane-chords-toggle-and-the-globals-reach-under-a-pane (:suite leticl)
  "G14/G18. The global chords ran LAST, inside `%normal-key` and under the pane
arm, so a pane swallowed every one of them: `ctrl-l` could not repaint a torn
screen while a pane was up, `ctrl-o` could not background a command while you read
the jobs list, and the second press of a pane chord did nothing — so every one of
them opened and none of them closed (app.rs:3017-3245, 3071-3137)."
  (let ((*pane-scroll* 0)
        (h (%on-head :cols 80 :rows 24)))
    (leticl::%handle-key h (list :type :ctrl :ch #\s))
    (is (eq :picker (head-mode h)) "ctrl-s opens the session list")
    (leticl::%handle-key h (list :type :ctrl :ch #\s))
    (is (eq :normal (head-mode h)) "and ctrl-s closes it again")
    ;; the head's own chords still answer with a pane up
    (setf (head-mode h) :jobs)
    (let ((before (getf (head-prefs h) :show-reasoning)))
      (leticl::%handle-key h (list :type :ctrl :ch #\r))
      (is (not (eq before (getf (head-prefs h) :show-reasoning)))
          "ctrl-r flips the thinking fold under a pane"))
    (setf (leticl::head-full-repaint h) nil)
    (leticl::%handle-key h (list :type :ctrl :ch #\l))
    (is (leticl::head-full-repaint h) "and ctrl-l repaints under one")
    (is (eq :jobs (head-mode h)) "with the pane still open")))

(def-test tab-on-a-pane-that-is-not-the-todos-leaves-the-frame-alone (:suite leticl)
  "G16. `(when (not (eq mode :todos)) (setf (head-dirty head) nil))` — against
the comment right above it, which says Tab does what Enter does. It suppressed the
next repaint instead. The reference binds Tab in the todos pane only
(app.rs:3753-3768)."
  (let ((h (%on-head :cols 80 :rows 24)))
    (setf (head-mode h) :jobs (head-dirty h) t)
    (leticl::%handle-key h (list :type :tab))
    (is (head-dirty h) "the frame is still due")))

(def-test the-esc-arming-is-disarmed-by-the-next-key (:suite leticl)
  "G9. `*esc-at*` was set by Esc and cleared only by a SECOND Esc, so: press Esc,
type a paragraph, press Esc four seconds later — and the turn was interrupted,
with the hint bar promising exactly that the whole time. Any key that is not Esc
disarms it (editor.rs:304-306)."
  (let* ((leticl::*esc-at* nil)
         (h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-turn (head-session h))
          (list :turn-id "t" :text "" :reasoning "" :calls nil
                :state (list :state "running")))
    (leticl::%handle-key h (list :type :esc))
    (is (search "esc again to interrupt"
                (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))
        "the first esc arms, and says so")
    (leticl::%handle-key h (list :type :char :ch #\x))
    (is (not (search "esc again to interrupt"
                     (format nil "~{~a~}" (mapcar #'car (hint-bar h 100)))))
        "a typed character disarms it, and the hint stops promising")
    (leticl::%handle-key h (list :type :esc))
    (is (null (find "interrupt" (%sent wire)
                    :key (lambda (f) (getf f :frame)) :test #'string=))
        "so the next esc arms again rather than interrupting")))

(def-test a-paste-marker-is-unique-and-the-ledger-is-forgotten (:suite leticl)
  "G3. `%paste-marker` keyed on the LINE COUNT alone, so two twelve-line pastes in
one prompt produced the same marker and `expand-pastes` replaced both occurrences
with whichever text the ledger found first: two stack traces pasted into one
prompt became the same stack trace twice. And `*paste-ledger*` was never cleared —
it grew for the life of the process (editor.rs:564-566, 475, 596)."
  (let* ((*paste-ledger* nil)
         (h (%on-head :cols 80 :rows 24))
         (c (head-composer h))
         (a (format nil "~{a~d~%~}" (loop for i from 1 to 12 collect i)))
         (b (format nil "~{b~d~%~}" (loop for i from 1 to 12 collect i)))
         (m1 (composer-insert-paste c a))
         (m2 (composer-insert-paste c b)))
    (is (not (string= m1 m2)) "two pastes of the same line count get two markers")
    (let ((out (expand-pastes (composer-buffer c))))
      (is (search a out) "the first paste comes back")
      (is (search b out) "and so does the second")
      (is (< (search a out) (search b out)) "in the order they were pasted"))
    (%wire h)
    (leticl::%submit-line h)
    (is (null *paste-ledger*) "and the ledger goes with the line that carried it")))

(def-test a-short-but-heavy-paste-still-collapses (:suite leticl)
  "G3. Five lines was the only test, so a three-line four-kilobyte log filled the
composer and pushed the transcript off the screen — the line count said `3`. The
reference has a byte threshold beside the line one (`PASTE_BYTES`, editor.rs:217).
A bracketed paste's CRLF and bare CR are normalised there too: ConPTY sends CR-only
newlines, and left alone they are control characters in the prompt."
  (let* ((*paste-ledger* nil)
         (c (make-composer))
         (heavy (format nil "~a~%~a~%~a" (make-string 300 :initial-element #\x)
                        (make-string 300 :initial-element #\y)
                        (make-string 300 :initial-element #\z))))
    (is (= 3 (leticl::%paste-lines heavy)) "three lines")
    (is (composer-insert-paste c heavy) "and it collapses anyway, on its size")
    (is (string= heavy (expand-pastes (composer-buffer c))) "and expands back whole"))
  (let* ((*paste-ledger* nil)
         (c (make-composer)))
    (composer-insert-paste c (format nil "a~C~Cb~Cc" #\return #\newline #\return))
    (is (string= (format nil "a~%b~%c") (composer-buffer c))
        "CRLF and a bare CR both become one newline")))

(def-test the-arrows-move-inside-a-multi-line-prompt (:suite leticl)
  "G5. `/help` promises *\"↑ ↓ move inside the prompt\"* (panes.lisp:164) and `↑`
always walked history instead — on a head that has had `alt+enter` since S4. A
multi-line prompt you cannot navigate is a prompt you retype (editor.rs:500-516)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (c (head-composer h)))
    (composer-push-history c "an older prompt")
    (composer-insert c (format nil "aaa~%bbb"))
    (setf (composer-cursor c) 7)          ; end of the second line
    (leticl::%handle-key h (list :type :up))
    (is (string= (format nil "aaa~%bbb") (composer-buffer c))
        "↑ inside the prompt does not touch the buffer")
    (is (= 3 (composer-cursor c)) "the cursor is on the first row, at the same column")
    (leticl::%handle-key h (list :type :up))
    (is (string= "an older prompt" (composer-buffer c))
        "and a second ↑, from the top row, walks history")))

(def-test up-recalls-the-queued-prompt-and-withdraws-it (:suite leticl)
  "G6. Recall-and-withdraw was on `ctrl-u`, which also means kill-to-start — two
meanings on one chord, and the one key readline taught for *the previous entry*
did not do it. The reference puts it on `↑` with an empty composer at the tail
(app.rs:3851-3861)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (head-queued h) (list "the prompt I sent"))
    (leticl::%handle-key h (list :type :up))
    (is (string= "the prompt I sent" (composer-buffer (head-composer h)))
        "↑ on an empty composer takes the queued prompt back")
    (is (equal "withdraw_prompts" (getf (first (%sent wire)) :frame))
        "and tells the daemon to drop it")
    ;; with a line being typed it is history's key again, and sends nothing
    (setf (head-queued h) (list "another"))
    (leticl::%handle-key h (list :type :up))
    (is (null (%sent wire)) "with a line typed, ↑ withdraws nothing")))

(def-test word-motion-and-the-lines-own-ends (:suite leticl)
  "G5/G7. There was no word motion at all, and `ctrl-a`/`home` went to the start
of the BUFFER rather than of the LINE — wrong on every multi-line prompt
(editor.rs:687-758)."
  (let ((c (make-composer)))
    (composer-insert c "one two three")
    (is (= 13 (composer-cursor c)))
    (composer-move c :word-left)
    (is (= 8 (composer-cursor c)) "one word left is the start of `three`")
    (composer-move c :word-left)
    (is (= 4 (composer-cursor c)) "and again, the start of `two`")
    (composer-move c :word-right)
    (is (= 8 (composer-cursor c)) "word right lands past the gap, on the next word"))
  (let ((c (make-composer)))
    (composer-insert c (format nil "first~%second"))
    (composer-move c :home)
    (is (= 6 (composer-cursor c)) "home is the start of the LINE")
    (composer-move c :end)
    (is (= 12 (composer-cursor c)) "and end is the end of it")
    ;; and a kill takes the line, not the buffer
    (setf (composer-cursor c) 6)
    (composer-kill-to-end c)
    (is (string= (format nil "first~%") (composer-buffer c))
        "ctrl-k kills to the end of the line and leaves the one above it")))

(def-test redo-brings-back-what-undo-took (:suite leticl)
  "G8. There was no redo stack: `ctrl-z` past the point you meant was a word you
retyped. `alt+z` is the binding, because Ctrl+Shift+Z arrives byte-identical to
Ctrl+Z in many terminals (editor.rs:441-454, term.rs:740-742)."
  (let* ((*undo-stack* nil) (leticl::*redo-stack* nil)
         (h (%on-head :cols 80 :rows 24)))
    (dolist (ch (coerce "abc" 'list))
      (leticl::%handle-key h (list :type :char :ch ch)))
    (is (string= "abc" (composer-buffer (head-composer h))))
    (leticl::%handle-key h (list :type :ctrl :ch #\z))
    (is (string= "" (composer-buffer (head-composer h))) "ctrl-z takes the word back")
    (leticl::%handle-key h (list :type :redo))
    (is (string= "abc" (composer-buffer (head-composer h))) "and alt+z brings it back")
    ;; and an edit abandons the branch
    (leticl::%handle-key h (list :type :ctrl :ch #\z))
    (leticl::%handle-key h (list :type :char :ch #\d))
    (leticl::%handle-key h (list :type :redo))
    (is (string= "d" (composer-buffer (head-composer h)))
        "typing after an undo drops the redo branch")))

(def-test tab-walks-the-matches-and-names-a-miss (:suite leticl)
  "G15. `%complete` inserted only on a UNIQUE prefix and otherwise printed the
candidates to the status line, so `/re` — four commands — did nothing to the line;
`/help` says *\"more tabs walk the matches\"* (panes.lisp:164). And a prefix
nothing matches was silent (app.rs:4292-4324)."
  (let ((leticl::*completion* nil)
        (h (%on-head :cols 80 :rows 24 :buffer "/re")))
    (flet ((tab () (leticl::%handle-key h (list :type :tab))
             (composer-buffer (head-composer h))))
      (let ((walk (loop repeat 5 collect (tab))))
        (is (equal "/rename" (first walk)) "the first match")
        (is (equal "/resync" (second walk)) "the second")
        (is (equal "/resume" (third walk)) "the third")
        (is (equal "/reseat" (fourth walk)) "the fourth")
        ;; the reference lists `reseat summarise` as its own row too, and its
        ;; cycle stops on one the same way: a line with a space in it is not a
        ;; bare verb, so the next Tab leaves it alone rather than clobbering it
        (is (equal "/reseat summarise" (fifth walk)) "the fifth, which is two words")
        (is (equal "/reseat summarise" (tab)) "and the cycle stops there"))))
  (let ((leticl::*completion* nil)
        (h (%on-head :cols 80 :rows 24 :buffer "/mode x")))
    (leticl::%handle-key h (list :type :tab))
    (is (string= "/mode x" (composer-buffer (head-composer h)))
        "a line with an argument on it is not a verb to complete"))
  (let ((leticl::*completion* nil)
        (h (%on-head :cols 80 :rows 24 :buffer "/zz")))
    (leticl::%handle-key h (list :type :tab))
    (is (string= "/zz" (composer-buffer (head-composer h))) "what was typed is kept")
    (is (search "no /command starts with" (head-status-note h)) "and the miss is named")))

(def-test the-peek-panes-arrows-and-enter-do-what-it-says (:suite leticl)
  "G19. `:peek` was in the generic pane list but `pane-row-count` returns 0 for
it, so `move-cursor` moved nothing, and `:peek` was not in the Enter case at all —
while the pane's own hint bar says *\"arrows scroll · enter re-reads\"*
(chrome.lisp:369). A hint bar that names two keys and means neither
(app.rs:3255-3280)."
  (let* ((*pane-scroll* 4) (*pane-lines* 100) (*pane-room* 10)
         (leticl::*peeked-session* "s-child")
         (h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (head-mode h) :peek)
    ;; **TAIL-ORIGIN.** `peek-lines` windows `end = total - scroll`, because a
    ;; subagent's ANSWER is at the end and that is what the pane was opened for —
    ;; so `*pane-scroll*` counts lines hidden BELOW the bottom and `↑` adds to
    ;; it. Called with the top-origin sign, `↑` walked toward the end while the
    ;; hint bar said *"arrows scroll"* and meant the other way.
    (leticl::%handle-key h (list :type :up))
    (is (= 5 *pane-scroll*) "↑ moves toward the BEGINNING of the scrollback")
    (leticl::%handle-key h (list :type :down))
    (is (= 4 *pane-scroll*) "and ↓ comes back toward the end")
    (leticl::%handle-key h (list :type :enter))
    (let ((f (first (%sent wire))))
      (is (equal "peek" (getf f :frame)) "enter re-reads")
      (is (equal "s-child" (getf f :session-id)) "the same subagent"))))

(def-test o-switches-into-a-subagent-and-enter-waits-for-one-opening (:suite leticl)
  "G22. The subagent pane's own last line says *\"o switches into it\"* and the
key did not exist — the pane arm read only `q` out of a printable character. And
Enter had no `opening` guard, so it peeked at a subagent with nothing to read and
the daemon refused it by name (app.rs:3660-3709)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-subagents (head-session h))
          (list (list :subagent-id "s-kid" :state "running" :prompt "go" :role "worker")))
    (setf (head-mode h) :subagents (head-picker-sel h) 0)
    (leticl::%handle-key h (list :type :char :ch #\o))
    (let ((f (first (%sent wire))))
      (is (equal "switch" (getf f :frame)) "o switches into it")
      (is (equal "s-kid" (getf f :session-id)) "by id"))
    ;; one still opening has nothing to read, and says so rather than being refused
    (setf (session-subagents (head-session h))
          (list (list :subagent-id "s-new" :state "opening" :prompt "go" :role "worker"))
          (head-mode h) :subagents)
    (leticl::%handle-key h (list :type :enter))
    (is (null (%sent wire)) "enter on one still opening sends nothing")
    (is (search "still opening" (head-status-note h)) "and says which silence it is")))

;;; ----------------------------------------- the job-output overlay (R21) ;;;
;;;
;;; The operator, 2026-09-20: *"on the job pane when i press enter im not shown
;;; the tailed job output but brought back to the conversation with /job <id>
;;; sent. we addressed it in letibot multiple times"*. letibot settled it at
;;; `3aabe4f`; these are that settlement's checks, on this head.

(defun %job-head (&key (cols 100) (rows 24))
  "A head with the jobs pane open on two rows, the cursor on the second — the
state the operator is in when they press Enter."
  (let ((h (%on-head :cols cols :rows rows)))
    (setf (session-session-id (head-session h)) "s-1"
          (head-jobs h)
          (list (list :id "j1" :command "sleep 10" :how "asked" :state "running"
                      :running t :produced 1500 :elapsed-ms 0)
                (list :id "j12" :command "cargo build --release" :how "bash"
                      :state "exited 0" :running nil :produced 40000
                      :elapsed-ms 3400))
          (head-mode h) :jobs
          (head-picker-sel h) 1)
    h))

(defun %pane-text (lines)
  "A pane's segment lines as plain strings — a blank line is NIL."
  (mapcar (lambda (l) (if (null l) "" (format nil "~{~a~}" (mapcar #'car l))))
          lines))

(def-test enter-on-a-jobs-row-reads-its-output-into-a-pane (:suite leticl)
  "The operator, 2026-09-20: *\"on the job pane when i press enter im not shown the
tailed job output but brought back to the conversation with /job <id> sent\"*, and
the earlier narrowing that says which half was broken: *\"entering the running job
works fine - but finished does /job <id>\"*.

One path served both rows — `Action::Slash { line: \"job jID\" }` — and what
differed was the SIZE of the reply: a slash reply is a `Warning` on the session
log, one sentence for a running job and a 16 KB dump for a finished one, and the
pane closed either way. Measured here on the wire: Enter sends `read_job_output`
for the row under the cursor at offset 0, sends NO slash, and leaves the jobs list
standing behind the overlay so Esc can come back to it (letibot `3aabe4f`,
app.rs:3776-3805)."
  (let* ((leticl::*job-out* nil)
         (h (%job-head))
         (wire (%wire h)))
    (leticl::%handle-key h (list :type :enter))
    (let ((sent (%sent wire)))
      (is (= 1 (length sent)) "one frame goes out, and it is not a slash line")
      (let ((f (first sent)))
        (is (equal "read_job_output" (getf f :frame))
            "enter asks for the output as a command, not as a slash line")
        (is (equal "j12" (getf f :job)) "for the row the cursor was on, by the daemon's id")
        (is (= 0 (getf f :offset)) "from the first byte")
        (is (plusp (length (getf f :client-request-id)))
            "carrying a request id, like every other command")))
    (is (eq :job-out (head-mode h)) "and the overlay is up at once")
    (is (equal "j12" (getf leticl::*job-out* :job)) "opened on that job")
    (is (eq t (getf leticl::*job-out* :loading))
        "saying it is reading, rather than showing a window it cannot yet fill")
    (is (= 2 (length (head-jobs h)))
        "the jobs list is untouched: the overlay covers it, it does not replace it")
    (is (= 1 (head-picker-sel h)) "and the row stays chosen, for the Esc back to it")))

(def-test the-job-output-window-fills-the-overlay-and-it-pages (:suite leticl)
  "The answer to Enter is `SessionEvent::JobOutput`, published on the log because
job output lives in the exec host and a frame answered on the asking connection
would block the server's own read loop on a worker (letibot `bacf495`).

What it adds over `/job`'s prose is the OFFSETS beside the text, and this is the
check that the pane draws them rather than parsing a footer sentence. Then the
paging: `→` takes the page the daemon NAMED and `←` walks back by an offset the
head was GIVEN — never `from - page`, because the page size is the daemon's
(`JOB_OUTPUT_WINDOW`) and a second copy of it here would page the two sides in
circles. At the front of the log there is no page before the first byte, so `←`
sends nothing."
  (let* ((leticl::*job-out* nil)
         (*pane-scroll* 0)
         (h (%job-head))
         (wire (%wire h)))
    (leticl::%handle-key h (list :type :enter))
    (%sent wire)
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "job_output"
                                   :job "j12" :from 0 :to 32 :produced 40000
                                   :dropped 0 :state "exited 0"
                                   :lines (list "   Compiling letibot-tui"
                                                "    Finished `release`")
                                   :next 32))
    (let ((v leticl::*job-out*))
      (is (null (getf v :loading)) "the answer ends the wait")
      (is (equal "exited 0" (getf v :state)) "with the daemon's own state word")
      (is (= 2 (length (getf v :lines)))
          "and the lines the daemon split, so two heads cannot disagree where one ends")
      (is (= 32 (getf v :next)) "the offset to ask at next, which the daemon decides"))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (equal "job output — j12" (first text)) "the header names the job")
      (is (search "exited 0 — bytes 0..32 of 40000" (second text))
          "and draws the OFFSETS it was sent: ~s" (second text))
      (is (find-if (lambda (l) (search "Compiling letibot-tui" l)) text)
          "the window itself is on the pane")
      (is (find-if (lambda (l) (search "→ next page" l)) text)
          "and the footer names the key that takes the page the daemon named"))
    ;; → asks for the page the daemon named, and remembers where it was
    (leticl::%handle-key h (list :type :right))
    (let ((f (first (%sent wire))))
      (is (equal "read_job_output" (getf f :frame)) "→ pages forward")
      (is (= 32 (getf f :offset)) "by the offset the daemon named, not one computed here"))
    (is (equal '(0) (getf leticl::*job-out* :back))
        "and the offset it came from is remembered, so ← can walk back to it")
    (leticl::%handle-key h (list :type :left))
    (let ((f (first (%sent wire))))
      (is (equal "read_job_output" (getf f :frame)) "← pages back")
      (is (= 0 (getf f :offset)) "to the offset it was given"))
    (is (null (getf leticl::*job-out* :back)) "the stack is empty at the front of the log")
    (leticl::%handle-key h (list :type :left))
    (is (null (%sent wire)) "and there is no page before the first byte, so ← sends nothing")
    ;; Esc goes back to the JOBS LIST, which never closed
    (is (eq :jobs (pane-escape-target :job-out))
        "esc from the overlay means back to the list the row was chosen from")
    (leticl::%handle-key h (list :type :esc))
    (is (eq :jobs (head-mode h)) "esc goes back to jobs, not out of everything")
    (is (null leticl::*job-out*)
        "and the overlay goes with the key, so a late answer is not taken into a pane nobody watches")))

(def-test the-job-output-overlay-scrolls-and-discloses-what-fell-off (:suite leticl)
  "Two things the window has to say that `/job`'s reply could only put in prose.

**`dropped` is disclosed in the HEADER**: a window that begins mid-log is
otherwise read as the job's beginning, which is a lie about what the job did
rather than a detail about paging (`SessionEvent::JobOutput`, event.rs:924).

**A job that has written nothing is a different statement from a window of
nothing**, and the daemon's own state word says which — tested literally, for the
same reason the jobs pane tests `exited 0` literally: the head renders the
daemon's vocabulary and keeps no second copy of the enum.

And the arrows SCROLL here rather than walking a cursor, because the overlay has
no rows to select — the same fault `peek-row-count` was written for: a pane that
answers 0 for its row count has its arrows clamped to `(1- 0)` while its own last
line advertises that they scroll."
  (let* ((leticl::*job-out* nil)
         (*pane-scroll* 0) (*pane-room* 10) (*pane-lines* 100)
         (h (%job-head)))
    (leticl::%handle-key h (list :type :enter))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "job_output"
                                   :job "j12" :from 16384 :to 16400 :produced 40000
                                   :dropped 512 :state "exited 0"
                                   :lines (list "a" "b" "c" "d" "e" "f" "g" "h")
                                   :next 16400))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (search "512 earlier bytes gone off the front" (second text))
          "the bytes that fell off the ring are disclosed beside the range: ~s" (second text)))
    (is (= 8 (leticl::pane-row-count h :job-out))
        "the overlay's rows are its BODY lines, which is what the arrows may scroll")
    ;; the overlay's origin is its TAIL — `job-out-lines` windows
    ;; `end = total - scroll` — so the offset counts rows hidden BELOW the
    ;; bottom and moving toward the beginning ADDS to it. Every scrolling key
    ;; goes through one sign-aware place for exactly this reason.
    ;; what the render would have left behind: the pane's total and its room
    (setf *pane-lines* 13 *pane-room* 6)
    (leticl::%handle-key h (list :type :up))
    (is (= 1 *pane-scroll*) "↑ moves back toward the beginning of the loaded window")
    (leticl::%handle-key h (list :type :down))
    (is (= 0 *pane-scroll*) "and ↓ comes back to the tail, where a running job appends")
    (leticl::%handle-key h (list :type :page-up))
    (is (plusp *pane-scroll*) "PgUp pages the same way, as the hint bar says")
    (leticl::%handle-key h (list :type :page-down))
    (is (= 0 *pane-scroll*) "and PgDn comes back")
    (leticl::%handle-key h (list :type :mouse :kind :wheel-up))
    (is (plusp *pane-scroll*) "the wheel pages it too — it was swallowed here once")
    (setf *pane-scroll* 0)
    ;; a job that produced nothing says WHICH silence it is
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0
                                   :dropped 0 :state "running" :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "running and has written nothing yet" l)) text)
          "a running job that wrote nothing says so"))
    (leticl::%handle-frame h (list :frame "event" :seq 3 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0
                                   :dropped 0 :state "exited 0" :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "wrote nothing at all" l)) text)
          "and a finished one that wrote nothing says the other thing")
      (is (find-if (lambda (l) (search "arrows scroll · Esc to jobs" l)) text)
          "with a footer naming only the keys that do something here"))))

;;; --------- §11.6: a job that never ran is not a job that wrote nothing -------- ;;;
;;;
;;; RULED by letibot `e1cd2b0`, 2026-09-22 07:38, and the operand is *A rules the words;
;;; both heads render the same string*. Two heads drawing one state two ways is a new
;;; drift rather than a fix, so the string is asserted LITERALLY here — that is the whole
;;; of what the two have to agree about.
;;;
;;; The shape it replaces, on both heads:
;;;
;;;     not run (could not join its scope)      <- the header
;;;     it wrote nothing at all.                <- and it never started
;;;
;;; which is the operator's own R17 rule, read backwards: *a row with no output must not
;;; look like a row whose output is empty*. The window's emptiness is identical in both
;;; cases and cannot carry the difference, so the DAEMON's `never_ran` does.

(def-test a-job-that-never-ran-says-so-rather-than-wrote-nothing (:suite leticl)
  "The overlay's empty-window line, for the two states an empty window has, and the
literal is letibot's ruling — this is the assertion that makes the two heads agree.

`never_ran` is the daemon's field on the window (`SessionEvent::JobOutput`, defaulted, no
version bump), set for `JobState::NotScoped` — the wrapper could not join the process's
cgroup, so **nothing started**. `false` is what an older daemon's silence means, and it
renders what it rendered before."
  (let* ((leticl::*job-out* nil)
         (h (%job-head)))
    (leticl::%handle-key h (list :type :enter))
    (%sent (%wire h))
    ;; (1) NEVER RAN — the case that was wrong
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0 :dropped 0
                                   :state "not run (could not join its scope)"
                                   :never-ran t :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "it never ran, so there is nothing it could have written." l))
                   text)
          "**THE RULING'S OWN SENTENCE, VERBATIM** — a different wording here is a new drift,
not a fix: ~s" text)
      (is (not (find-if (lambda (l) (search "wrote nothing" l)) text))
          "and NOT `wrote nothing at all`, which is the contradiction this replaces: the
header above it already says the command did not run"))
    ;; (2) RAN AND WROTE NOTHING — unchanged, and this is the half that must not move
    (leticl::%handle-frame h (list :frame "event" :seq 2 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0 :dropped 0
                                   :state "exited 0" :never-ran nil :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "it wrote nothing at all." l)) text)
          "a job that ran and wrote nothing keeps its own sentence"))
    ;; (3) RUNNING AND SILENT — the third state, chosen off the state word because that
    ;; fact has no field of its own on the frame
    (leticl::%handle-frame h (list :frame "event" :seq 3 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0 :dropped 0
                                   :state "running" :never-ran nil :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "it is running and has written nothing yet." l)) text)
          "and a running one says it is still going"))))

(def-test a-window-whose-daemon-never-heard-of-never-ran-draws-what-it-always-drew (:suite leticl)
  "**The old-daemon contract, asserted rather than promised.** `never_ran` is an added,
defaulted field: a daemon from before letibot `e1cd2b0` does not send it, this head reads
NIL, and the pane must draw exactly the sentence it drew before — because such a daemon had
only one answer for an empty window, and `false` is the honest reading of that silence.

Two ways the field can be absent, and both are the same plist: the key is not there at all,
and the key is there and false. (The decoder elides nothing, so a `false` arrives as `:never-ran
nil`; the pane asks `(getf view :never-ran)`, which answers NIL for both.)"
  (let* ((leticl::*job-out* nil)
         (h (%job-head)))
    (leticl::%handle-key h (list :type :enter))
    (%sent (%wire h))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "job_output"
                                   :job "j12" :from 0 :to 0 :produced 0 :dropped 0
                                   :state "exited 0" :lines nil :next nil))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "it wrote nothing at all." l)) text)
          "no `never-ran` key at all: the pre-e1cd2b0 sentence, unchanged"))
    (is (null (getf leticl::*job-out* :never-ran))
        "and the overlay holds NIL rather than a guessed T")))

(def-test a-job-that-never-ran-has-no-duration-on-its-row-either (:suite leticl)
  "**The second place the same lie was told, and it is the one the wire made easy to miss.**

The jobs pane's row read

    not run (could not join its scope) · 0 B out · ran 0.0s

— the state word denying *ran* two fields before the row said it. **The byte count stays**
(`0 B out` is a measurement that exists and the word beside it says why) and the duration
clause goes, because a job that never ran has no run to have taken time. R17 once more: *a
row with nothing behind it must not look like a row with an empty something behind it*, and
here the something is the run itself.

The fact rides the ROW too (`JobEntry.never_ran`, defaulted, no version bump) — the pane
draws `head-jobs`, which is the daemon's listing, so the listing has to carry it."
  (let ((h (%make-head)))
    (setf (head-jobs h) (list (list :id "j9" :command "cargo build" :how "bash"
                                    :state "not run (could not join its scope)"
                                    :running nil :never-ran t
                                    :produced 0 :elapsed-ms 0)))
    (let ((text (segs-of (jobs-lines h 200))))
      (is (search "not run (could not join its scope) · 0 B out" text)
          "the state and the byte count, which is a real measurement: ~s" text)
      (is (not (search "ran 0.0s" text))
          "**and no duration clause** — the job had no run to measure")
      (is (not (search "· ran " text))
          "nor any other duration: nothing on this row may claim elapsed time"))
    ;; the ordinary case is untouched, which is the half that must not move
    (setf (head-jobs h) (list (list :id "j4" :command "cargo test" :how "bash"
                                    :state "exited 0" :running nil :never-ran nil
                                    :produced 1536 :elapsed-ms 3400)))
    (let ((text (segs-of (jobs-lines h 200))))
      (is (search "exited 0 · 1.5 KB out · ran 3.4s" text)
          "a job that ran keeps its duration and its byte count: ~s" text))
    ;; and a running one still says so, without a duration it does not have yet
    (setf (head-jobs h) (list (list :id "j5" :command "cargo build" :how "bash"
                                    :state "running" :running t :never-ran nil
                                    :produced 12 :elapsed-ms 0)))
    (let ((text (segs-of (jobs-lines h 200))))
      (is (search "running · 12 B out so far" text)
          "the running row is unchanged: ~s" text))))

(def-test a-refused-job-output-read-lands-in-the-pane (:suite leticl)
  "A job can fall out of the exec host's table between the listing and Enter, and
the daemon then answers the read with a `job_output_refused` warning instead of a
window. The overlay must SAY so: left alone it sits at `reading…` for ever,
waiting for a window that is not coming (app.rs:2764-2774).

The warning is still pushed onto the session's own list. Suppressing it here was
the first shortcut letibot ruled out — *\"suppressing it here would make this
head's screen disagree with the log every other head sees\"* (`bacf495`)."
  (let* ((leticl::*job-out* nil)
         (h (%job-head)))
    (leticl::%handle-key h (list :type :enter))
    (is (eq t (getf leticl::*job-out* :loading)) "the overlay is waiting")
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "warning"
                                   :code "job_output_refused"
                                   :detail "no job `j12` here; `/job` with no argument lists them"))
    (let ((v leticl::*job-out*))
      (is (null (getf v :loading)) "the refusal ends the wait")
      (is (search "no job `j12` here" (getf v :error)) "and the daemon's own sentence is kept"))
    (let ((text (%pane-text (job-out-lines h 100))))
      (is (find-if (lambda (l) (search "the daemon refused this read" l)) text)
          "the pane says it was refused, rather than drawing an empty log")
      (is (find-if (lambda (l) (search "no job `j12` here" l)) text)
          "with what the daemon said")
      (is (find-if (lambda (l) (search "Esc back to jobs" l)) text)
          "and the way out"))
    (is (equal "job_output_refused"
               (getf (first (session-warnings (head-session h))) :code))
        "and the conversation still gets it: this head's screen must not disagree with the log")
    ;; ctrl-c leaves a pane the way Esc does, and the overlay has to go with it:
    ;; it is a SPECIAL, not a mode flag, so leaving the mode is not leaving it —
    ;; an open one would go on taking windows into a pane nobody can see
    (leticl::%handle-key h (list :type :ctrl :ch #\c))
    (is (null leticl::*job-out*) "ctrl-c closes the overlay, not only the mode")
    (is (eq :normal (head-mode h)) "and closes the screen, as it does for every pane")))

(def-test a-job-output-window-is-ephemeral-and-never-stored (:suite leticl)
  "*\"A window from four minutes ago is a lie about now\"* — so `scrub::is_interactive`
returns true for `JobOutput`, `StoredProjection::keep` strips it, and the count
lands in `ScrubReport::job_output` (letibot `3aabe4f`).

Two halves, measured. **Nothing enters the projection**: the window lives in
`*job-out*`, which no snapshot writes and no reconnect carries, and a window for a
job no overlay is open on is dropped rather than kept for a pane that might open
later. **The scrub count is summed**: `%scrub-total` sums a `ScrubReport` by SHAPE,
so the field letibot added needed no change here — a head that enumerated the four
names it knew would have dropped the fifth silently, and the whole point of the
number is to keep *\"busy, none of it was for me\"* apart from *\"quiet\"*."
  (let* ((leticl::*job-out* nil)
         (s (make-session))
         (leticl::*turn-started-ms* nil))
    (is (eq :quiet (apply-event s (list :seq 1 :event "job_output" :job "j12" :from 0 :to 4
                                        :produced 4 :dropped 0 :state "exited 0"
                                        :lines (list "hi") :next nil)))
        "a window for a job nobody is looking at moves nothing on the screen")
    (is (null leticl::*job-out*) "and is not kept against a pane that might open later")
    (is (null (session-jobs s)) "it is not a job row either — those are the daemon's listing")
    ;; and with an overlay open it IS taken, for that job only
    (setf leticl::*job-out* (list :job "j12" :loading t :back nil))
    (is (eq :quiet (apply-event s (list :seq 2 :event "job_output" :job "j7" :from 0 :to 4
                                        :produced 4 :dropped 0 :state "exited 0"
                                        :lines (list "hi") :next nil)))
        "another job's window is not this overlay's")
    (is (eq t (getf leticl::*job-out* :loading)) "so the wait is still on")
    (is (eq :dirty (apply-event s (list :seq 3 :event "job_output" :job "j12" :from 0 :to 4
                                        :produced 4 :dropped 0 :state "exited 0"
                                        :lines (list "hi") :next nil)))
        "its own window moves the screen")
    ;; the scrub count
    (let ((*scrubbed-total* 0))
      (ingest-hello s (list :head-id "h1" :session-id "s-1" :dropped 0
                            :resumed-from 3
                            :scrubbed (list :deltas 2 :job-output 3)))
      (is (= 5 *scrubbed-total*)
          "and a ScrubReport's job_output is summed with the rest, by shape"))))

(def-test an-old-daemon-drops-the-socket-and-the-head-says-which-frame-did-it (:suite leticl)
  "**The compatibility cost of an additive frame, paid where it is felt.**

`ClientFrame` is an internally-tagged serde enum, so a daemon that does not know
`read_job_output` does not fail one message — it fails the DESERIALIZER, which
ends its read loop and closes the connection. This head has been bitten by that
exact class once already: `consented: null` on `/mode NAME` broke the read loop
the same way and the whole symptom was a head that went quiet
(`a-boolean-field-goes-out-as-a-boolean`).

No version negotiation is invented for it: the server side landed without a
`PROTOCOL_VERSION` bump, so the version cannot tell us, and a handshake this head
made up would be a second, private protocol. What is chosen is that the head is
never left silently dead — the reconnect path brings it back, and the read that
was in flight is NAMED, in the overlay that asked and on the status line, with the
verb that still works on an old daemon."
  (let* ((leticl::*job-out* nil)
         (h (%job-head)))
    (leticl::%handle-key h (list :type :enter))
    (is (eq t (getf leticl::*job-out* :loading)) "the overlay is waiting on the read")
    (leticl::%handle-frame h (list :disconnected))
    (let ((v leticl::*job-out*))
      (is (null (getf v :loading)) "the socket dying ends the wait")
      (is (search "read_job_output" (getf v :error))
          "and the pane names the frame that did it: ~s" (getf v :error))
      (is (search "/job j12" (getf v :error))
          "with the verb that still reads this job on a daemon that old"))
    (is (search "read_job_output" (head-status-note h))
        "the status line says it too, because the overlay may already be closed")
    (is (null (head-connected h)) "and the head is detached, for the reconnect below it")
    ;; a disconnect with no read in flight is the ordinary one and says the ordinary thing
    (setf leticl::*job-out* nil)
    (leticl::%handle-frame h (list :disconnected))
    (is (equal "detached — reconnecting…" (head-status-note h))
        "an ordinary detach is not blamed on a frame nobody sent")))

(def-test the-hint-bar-names-the-job-output-overlays-keys (:suite leticl)
  "The bottom row is where a key is learned, and this pane's Esc goes BACK ONE
LEVEL rather than closing everything — a row that said `esc closes` would teach
the wrong thing about it (app.rs:5421-5426)."
  (let* ((leticl::*job-out* (list :job "j12" :loading t :back nil))
         (h (%on-head :cols 100 :rows 24)))
    (setf (head-mode h) :job-out)
    (let ((text (format nil "~{~a~}" (mapcar #'car (hint-bar h 100)))))
      (is (search "→ next page" text) "the page keys are named: ~s" text)
      (is (search "esc back to jobs" text) "and Esc says where it goes"))))

(def-test a-click-on-the-mode-picker-card-marks-a-row (:suite leticl)
  "G17. The click arm tested `head-mode`, and the mode/model picker runs with
`head-mode` :normal and `*pick-open*` set — so a click on the card fell through to
the composer and was dropped. Select and confirm stay two acts: the click marks
the row and takes nothing, because a gesture that commits on press is how a
misclick moves somebody's session (app.rs:3639-3651)."
  (let* ((*stdout* (make-string-output-stream))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (h (%on-head :cols 100 :rows 24))
         (wire (%wire h)))
    (setf (head-settings h)
          (list (list :key "mode" :value "read-only"
                      :choices (list "read-only" "always-ask" "writes allowed"))))
    (open-pick h :mode)
    (leticl::%render h)
    (let* ((rows (uiop:split-string (%screen-text h) :separator '(#\newline)))
           (row (position-if (lambda (l) (search "writes allowed" l)) rows)))
      (is (not (null row)) "the third choice is on the screen")
      (leticl::%handle-key h (list :type :mouse :kind :press :x 10 :y row))
      (is (= 2 (head-picker-sel h)) "the click marks the row it landed on")
      (is (eq :mode leticl::*pick-open*) "the card stays open")
      (is (null (%sent wire)) "and nothing is taken"))))

(def-test history-is-capped-deduplicated-and-stops-on-an-edit (:suite leticl)
  "G25. The history was an uncapped vector with no duplicate rule, empty Enters
were pushed into it, and nothing stopped the walk once a recalled line had been
edited — so one more `↑` silently destroyed the edit. The last of those is the one
that costs work (editor.rs:519-548, 591-593, 219)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (c (head-composer h)))
    (%wire h)
    (flet ((submit (text)
             (leticl::composer-buffer-set c text)
             (leticl::%submit-line h)))
      (submit "a") (submit "a") (submit "b")
      (is (equal '("a" "b") (coerce (leticl::composer-history c) 'list))
          "a line that repeats the one before it is not remembered twice")
      (submit "")
      (is (= 2 (length (leticl::composer-history c))) "and an empty Enter adds nothing")
      ;; the walk stops once the recalled line has been edited. (Nothing is
      ;; queued by the time this runs on a live head — a `↑` with prompts still
      ;; in flight takes the last one back instead, which is G6's arm.)
      (setf (head-queued h) nil)
      (leticl::%handle-key h (list :type :up))
      (is (string= "b" (composer-buffer c)) "↑ recalls the newest")
      (leticl::%handle-key h (list :type :char :ch #\!))
      (leticl::%handle-key h (list :type :up))
      (is (string= "b!" (composer-buffer c))
          "and a second ↑ after an edit leaves the edit alone")
      ;; fifty-one submissions leave fifty
      (loop for i from 1 to 51 do (submit (format nil "line ~d" i)))
      (is (= leticl::*history-max* (length (leticl::composer-history c)))
          "the history is capped, oldest dropped"))))

(def-test reseat-summarise-asks-for-the-lossy-kind-by-name (:suite leticl)
  "G23. `%command` split the verb, bound `rest` and then ignored it, and the frame
carried no `summarise` at all — so the operator asked for the destructive variant
by name and got the other one, with no word either way. The reference says which
one ran (app.rs:4590-4608)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (leticl::%command h "reseat summarise")
    (let ((f (first (%sent wire))))
      (is (equal "reseat_session" (getf f :frame)) "the frame goes")
      (is (eq t (getf f :summarise)) "carrying the ask to summarise"))
    (is (search "summarising" (head-status-note h)) "and it says which one ran")
    (leticl::%command h "reseat")
    (let ((f (first (%sent wire))))
      (is (equal "reseat_session" (getf f :frame)))
      (is (null (getf f :summarise)) "a bare /reseat carries the lossless kind"))
    (is (search "carrying the conversation" (head-status-note h)) "and says so too")))

(def-test the-short-verbs-are-the-heads-and-not-the-daemons (:suite leticl)
  "G24. `/s` and `/i` were not in `%command`, so the catch-all forwarded them to
the daemon as slash lines — a round trip for the two verbs whose whole point is to
be short (app.rs:4443, 4567)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (leticl::%command h "s")
    (is (eq :picker (head-mode h)) "/s opens the session picker")
    (is (null (find "slash" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=))
        "and nothing travelled to the daemon")
    (leticl::%command h "i")
    (let ((f (first (%sent wire))))
      (is (equal "interrupt" (getf f :frame)) "/i interrupts the turn"))))

(def-test the-unified-card-draws-no-line-the-file-does-not-have (:suite leticl)
  "`str::lines()` yields no final empty line for a text ending in a newline and
`uiop:split-string` does, so the unified edit card drew a signed, numbered blank
row at the foot of every diff whose side ended in one — a line claimed that is not
in the file. The split view was fixed with `%lines-of`; this is its other caller,
which had kept its own copy of the rule.

And the emphasis: both reference call sites pass `intra_line: false`
(app.rs:8817, 9934). Ours passed T against wiring that was dead, so repairing the
wiring would have started emitting what the reference suppresses."
  (let* ((*item-facts* nil)
         (edit (list :path "src/f.lisp" :created nil
                     :before-start 1 :after-start 1
                     :before-lines 1 :after-lines 1 :truncated nil
                     :before (format nil "a~%") :after (format nil "b~%")))
         (lines (edit-lines edit 80))
         (text (lines-text lines)))
    (is (= 1 (count-if (lambda (l) (search "-a" l)) text)) "the removal")
    (is (= 1 (count-if (lambda (l) (search "+b" l)) text)) "the addition")
    (is (notany (lambda (l) (let ((tr (string-trim " -+0123456789│" l)))
                              (and (zerop (length tr)) (search "2" l))))
                text)
        "and no numbered blank row after them: ~s" text))
  (is (search ":intra-line nil" (source-of "cards"))
      "the call site suppresses word emphasis, as both of the reference's do"))

;;; ----------------------------- the frame, the cards and the pane cursors ;;;
;;;
;;; docs/parity/panes.md G5, G6, G11-G16, G19, G21 and docs/parity/rendering.md
;;; §4's gaps 16-20, each measured against `/home/dead/Projects/letibot/letibot`
;;; at `8af671e` and each with the reference's own function named in the
;;; docstring. Every test below FAILS on the commit before this one.

(def-test the-picker-opens-on-the-session-you-are-in (:suite leticl)
  "**Ctrl+S then Enter moved you off your own session.** `%open-pane` seeds every
pane's cursor at row 0 (`src/commands.lisp:178-191`), so the session picker
opened on row 1 of the list and Enter — the obvious thing to press on a list you
did not mean to change — switched. The reference seeds `picker_sel` from the
current session when it opens the list (app.rs:3080-3087) precisely so that Enter
on an untouched picker is a no-op.

`picker-initial-sel` is the fact `%open-pane` is missing; the subagent filter is
the same one the pane draws from, so the cursor and the rows cannot disagree
about which row is which."
  (let* ((h (%pane-head))
         (s (head-session h)))
    ;; the head is in the FIRST session of `%pane-head`; put it in the second
    (is (= 0 (leticl::picker-initial-sel h)) "row 0 when you are the first row")
    (setf (session-session-id s) "s-1789418841049398558")
    (is (= 1 (leticl::picker-initial-sel h))
        "and row 1 when you are the second — subagents are not counted, so the
child session between them does not move it")
    ;; a session the daemon has not listed is row 0: there is nowhere else to be
    (setf (session-session-id s) "s-not-listed")
    (is (= 0 (leticl::picker-initial-sel h)) "0 when the list does not hold it")
    ;; and every other pane opens at the top, which is what one shared cursor
    ;; can honestly promise
    (setf (session-session-id s) "s-1789418841049398558")
    (is (= 1 (leticl::pane-initial-sel h :picker)) "the picker is seeded")
    (dolist (mode '(:jobs :subagents :config :todos))
      (is (= 0 (leticl::pane-initial-sel h mode))
          (format nil "and the ~(~a~) pane opens at the top" mode)))))

(def-test the-peek-pane-shows-the-tail-and-names-its-spill-file (:suite leticl)
  "**The pane advertised three keys and a file, and had none of them.**
`pane-row-count` answers 0 for `:peek` (`src/editor.lisp:749`) so its cursor has
nowhere to walk; the generic pane window took the TOP of the read, so a subagent
that had written two hundred lines showed its first screenful while its ANSWER,
which is at the end, was off the bottom; and `spill_sub_out` (app.rs:8025-8060)
had no counterpart at all — `grep -rn spill src/*.lisp` found only the per-call
`:spill` field.

The reference's `sub_out_lines` (app.rs:6844-6892) is a TERMINAL, not a document:
the tail shows by default and `scroll` is clamped where the visible height is
known, because *a key handler cannot clamp what it cannot see*."
  (let* ((h (%pane-head))
         (leticl::*peeked-session* "s-child")
         (leticl::*peeked-dropped* 0)
         (leticl::*peek-spill* nil)
         (*pane-scroll* 0))
    ;; a read long enough to need a window: thirty assistant rows
    (setf (head-peeked h)
          (loop for i from 0 below 30
                collect (list :event "transcript_content"
                              :item (list :type "assistant"
                                          :text (format nil "line-~2,'0d" i)))))
    (is (plusp (leticl::peek-row-count h))
        "the pane has rows for a cursor to walk — `pane-row-count` answers 0")
    (let ((text (lines-text (leticl::peek-lines h 80 12))))
      (is (search "line-29" (format nil "~{~a~^|~}" text))
          "the TAIL is what a fresh peek shows: the answer is at the end")
      (is (not (search "line-00" (format nil "~{~a~^|~}" text)))
          "and the head of a long read is off the top, not the bottom")
      (is (= 12 (length text)) "and it fills exactly the room it was given")
      (is (search "full: " (car (last text)))
          "the footer names the spill file, as the reference's does"))
    ;; the file the footer names is a file that exists
    (let ((path (leticl::spill-peek "s-child" (list "a" "b"))))
      (is (and path (probe-file path))
          "and `spill-peek` wrote it — a footer that promises a path it did not
write is worse than one that promises nothing"))
    ;; Esc goes back to the tree, not out of everything (app.rs:3251-3262)
    (is (eq :subagents (leticl::pane-escape-target :peek))
        "Esc from the peek means back to the subagent tree")
    (is (eq :normal (leticl::pane-escape-target :jobs))
        "and everywhere else it still means close")))

(defun %decision-head (&key advice (options :full))
  "A head with one open permission on it, shaped the way the daemon sends one."
  (let ((h (%pane-head)))
    (setf (session-open-decisions (head-session h))
          (list (list :req-id "r1"
                      :kind "exec"
                      :summary "`bash` wants exec access to `cargo test --workspace`"
                      :target "cargo test --workspace"
                      :detail "the guard read this as a build, in this project"
                      :advice advice
                      :options (if (eq options :full)
                                   (list (list :option-id "allow_once" :label "Allow once"
                                               :kind "allow_once")
                                         (list :option-id "allow_always" :label "Always allow `cargo test *`"
                                               :kind "allow_always")
                                         (list :option-id "reject_once" :label "Deny" :kind "reject_once")
                                         (list :option-id "reject_always" :label "Deny, and tell the model why"
                                               :kind "reject_always"))
                                   (list (list :option-id "allow_once" :label "Allow once"
                                               :kind "allow_once")
                                         (list :option-id "reject_once" :label "Deny"
                                               :kind "reject_once"))))))
    h))

(def-test the-permission-card-draws-the-oracles-verdict (:suite leticl)
  "**The head RECEIVES the oracle's advice and never drew it.** `:advice` is
folded onto the open decision at `src/session.lisp:324` and nothing read it, so
under `/mode supervised` — where the question is not *should this run* but *do
you agree with the model* — the model's answer was off-screen.

`decision_lines` (app.rs:7329-7466) line for line, and four things the old card
had none of: the verdict with its basis, its citations and `{by} · {N} ms`; the
option IDS, so the ladder and the typed path show one choice and not two; the
glob hint, **only** when `allow_always` is on offer; and `ask_without_target`
(app.rs:7865-7874), without which the command is printed twice — once inside the
summary sentence and once on its own line under it."
  ;; the target comes off the end of the sentence, and the sentence's " to" with it
  (is (equal "`bash` wants exec access"
             (leticl::ask-without-target "`bash` wants exec access to `cargo test`"
                                         "cargo test"))
      "the heading is the ask without the thing being asked about")
  (is (null (leticl::ask-without-target "some other builder wrote this" "cargo test"))
      "and NIL when the sentence does not end in the target — then nothing is lost")
  (let* ((h (%decision-head
             :advice (list :would "allow"
                           :by "oracle-local"
                           :basis "it is the project's own test command"
                           :cites (list "trail entry 4" "trail entry 9")
                           :latency-ms 310)))
         (text (%card-text h 120)))
    (is (search "? `bash` wants exec access [exec]" text)
        "the ask, in the reference's shape, with the target taken off it")
    (is (= 1 (count-substring "cargo test --workspace" text))
        "and the command appears ONCE, on its own line — it was printed twice")
    (is (search "model says allow: it is the project's own test command" text)
        "the oracle's verdict, above the ladder")
    (is (search "oracle-local · cites trail entry 4 · trail entry 9 · 310 ms" text)
        "with who said it, what it grounded the answer in, and how long it took")
    (is (search "(allow_always)" text)
        "every option carries its id, so the ladder and the typed path agree")
    (is (search "`allow_always <glob>`" text)
        "the glob hint, because an always-allow is on offer")
    (is (search "`deny_and_tell <why>`" text)
        "and where the words go, because a reject-always is")
    (is (not (search "no oracle" text)) "nothing claims an oracle was skipped"))
  ;; an oracle that AUTHORISED while citing nothing is the case worth a look; one
  ;; that did not authorise has nothing to cite, and saying so about it claims a
  ;; search that was never the question
  (let ((text (format nil "~{~a~^~%~}"
                      (lines-text (leticl::advice-lines
                                   (list :would "admit" :by "oracle-local" :basis "b"
                                         :cites nil :latency-ms 12)
                                   120)))))
    (is (search "cites nothing from your words" text) "an `admit` with no cites says so"))
  (let ((text (format nil "~{~a~^~%~}"
                      (lines-text (leticl::advice-lines
                                   (list :would "refuse" :by "oracle-local" :basis "b"
                                         :cites nil :latency-ms 12)
                                   120)))))
    (is (not (search "cites nothing" text))
        "and a refusal does not — it had nothing to cite and was not asked to"))
  ;; no always-allow on offer, no glob hint: a hint for an option this request
  ;; does not have teaches the operator to stop reading the hints
  (let* ((h (%decision-head :options :short))
         (text (%card-text h 120)))
    (is (not (search "`allow_always <glob>`" text)) "no always-allow, no glob line")
    (is (not (search "`deny_and_tell" text)) "no reject-always, no words line")
    (is (search "no oracle was consulted for this one" text)
        "and the absence of a verdict is SAID: `not asked` and `said nothing`
are different facts and looked identical on a card that drew neither")))

;;; ---------------- §1.6: the gate card says what silence will do ---------------- ;;;
;;;
;;; MISSING IN BOTH HEADS before this, and the operator was bitten by it the same
;;; night: *"two gate cards timed out unanswered at 300 seconds with `not_run by
;;; gate:timeout` — nothing on the card had said that was coming."* Both heads carry
;;; the two fields (`deadline`, `on_timeout`, `event.rs:569-574`) and both drew
;;; neither, while both drew a countdown on the SECRET card. The instrument existed
;;; in both trees and was never pointed at the gate, where the consequence of silence
;;; is a decision rather than a missing password.

(def-test a-deadline-is-drawn-coarse-until-it-is-worth-counting (:suite leticl)
  "**The operator's question, as a table**: *a countdown that ticks for five minutes is
furniture and one that ticks for ten seconds is a pressure the operator did not ask
for*. Both are avoided by a LADDER rather than by a number, and the daemon's own
budget is what the ladder is measured against — `ANSWER_BUDGET` is 300 s
(`harnessd/src/answers.rs:66`), so the card reads `5 min` for its first three minutes
and counts in seconds for the last two.

Minutes round UP, because the sentence is *expires in …* and a rounded-down figure
claims less time than there is."
  (let ((leticl::*fixed-clock-ms* 10000000)
        (now 10000000))
    (flet ((said (secs) (deadline-said (+ now (* secs 1000)))))
      (is (equal "expires in 5 min" (said 300)) "the daemon's own budget, at the start")
      (is (equal "expires in 5 min" (said 250)) "and still five, one minute later")
      (is (equal "expires in 4 min" (said 181)) "rounding up: 3m01s is not 3 min")
      (is (equal "expires in 3 min" (said 180)) "on the minute")
      (is (equal "expires in 2 min" (said 120)) "two minutes out")
      (is (equal "1m59s left" (said 119)) "and from here it counts in seconds")
      (is (equal "59s left" (said 59)) "under a minute, whole seconds")
      (is (equal "47s left" (said 47)) "the number the secret card already spelled")
      (is (equal "0s left" (said 0)) "at the last second, not `0.0s`")
      ;; **and it never says a NEGATIVE number** — a countdown into minus is a
      ;; rendering fault, not a fact, and a card whose clock ran out is a different
      ;; state with its own sentence
      (is (search "past its deadline by 12s" (said -12))
          "past it says so, and says how long ago rather than counting down")
      (is (not (search "-" (said -12))) "without a minus sign on a duration"))))

(def-test a-deadline-is-read-on-this-heads-clock-not-the-daemons (:suite leticl)
  "**R13's trap in a second place, and the one the SECRET card had been living
with.** `DecisionRequested.deadline` and `SecretRequested.deadline` are *Unix
millis* (`event.rs:573`, `:746`) and `internal-real-time-ms` is SBCL's counter since
process start, so subtracting one from the other is a duration across two clocks —
silently wrong by an enormous constant. Measured before the fix: the secret card's
countdown read a number in the hundreds of thousands of seconds.

The conversion happens **where the frame arrives** (R13's *anchor on arrival*: the one
place the two readings describe the same moment) and the card then subtracts two
readings of ONE clock."
  (let ((leticl::*unix-offset-ms* nil))
    (let* ((wall (unix-now-ms))
           (mono (internal-real-time-ms)))
      (is (> (abs (- wall mono)) 1000000)
          "the two clocks really are in different units: a Unix instant is 1.8e12 ms
 and this head's counter is a process-relative count, which is why the conversion
 exists — subtracting one from the other is what the secret card used to draw")
      (let ((converted (wire-deadline->monotonic (+ wall 300000))))
        (is (<= 299000 (deadline-remaining-ms converted) 300500)
            "a 300 s wire deadline becomes 300 s of this head's time: ~d"
            (deadline-remaining-ms converted))))
    ;; and the same conversion is what the fold does, so the card sees one clock
    (is (null (wire-deadline->monotonic nil))
        "no deadline in, no deadline out — §11.5's `deadline: null` is a policy")
    (is (null (wire-deadline->monotonic 0))
        "and a zero is not an instant anybody meant")))

(def-test a-card-with-no-deadline-says-nothing-about-time (:suite leticl)
  "§13.2b in the other direction, and deliberately.

`deadline: null` is *\"wait forever\"* (`event.rs:571-573`) — a policy, not missing
information — so an ask that cannot expire draws no countdown, and *\"I was not told\"*
cannot be manufactured by a card that never had a clock to show. The contrast is
`unreadable 0` on `/status`, which IS shown at zero: a head that does not count frames
it cannot read is a different head, while a countdown on an ask with no deadline is a
number nobody took.

`permission.jsonl` is exactly this case — `\"deadline\": null` — so this is the fixture
the golden renders."
  (is (null (deadline-said nil)) "no deadline, no clause")
  (is (null (deadline-said 0)) "and a zero is treated as none")
  (let ((leticl::*fixed-clock-ms* 10000000)
        (h (%make-head)))
    (setf (session-open-decisions (head-session h))
          (list (list :req-id "d" :kind "permission" :summary "`bash` wants exec access"
                      :options (list (list :option-id "allow_once" :label "Allow once")))))
    (let ((text (%card-text h 90)))
      (is (search "Allow once" text) "the card is there")
      (is (not (search "left" text)) "and nothing counts down")
      (is (not (search "expires" text)) "and nothing expires"))))

;;; --------------- R18: the deadline in a SNAPSHOT, and the label the daemon wrote ;;;
;;;
;;; MEASURED LIVE 2026-09-22, on the operator's own permission card, because they asked
;;; what this head draws for a label that needs a tool name. Two answers came off the
;;; glass in the same minute:
;;;
;;;  · the LABEL: `Allow \`head\` (this class) for the rest of the session` when the
;;;    daemon can name the program, and `Allow \`<tool>\` (this class) …` when it
;;;    cannot. This head drew BOTH, verbatim, exactly as letibot drew them.
;;;  · the CLOCK: `expires in 29833973 min · if nobody answers, nothing runs`, on a card
;;;    whose real remaining time was 229308 ms.

(def-test a-decision-that-arrives-in-a-snapshot-counts-down-on-this-heads-clock (:suite leticl)
  "**R18, and the fourth instance of the two-clocks trap.** The wire's deadline is Unix
millis (`event.rs:573`); `internal-real-time-ms` is a counter since this process
started. The live `decision_requested` arm converted one to the other and the
snapshot's `open_decisions` did not — so a head that ATTACHED to a session with an ask
already open drew a countdown to the year 2083 while a head that watched the ask arrive
drew the right one.

Measured on the operator's live card rather than reasoned about: `:DEADLINE
1790038382308` (a Unix instant, unconverted), `:DEADLINE-WIRE NIL`, `unix-now
1790038153000`, and the card read `expires in 29833973 min` for a remaining 229308 ms.

The fix is one rule in one function (`%decision-clock-rule`), called from both folds,
because a rule applied at two call sites is the rule that drifts — R16's lesson one
field over."
  (let ((leticl::*fixed-clock-ms* 5000000)
        (leticl::*unix-offset-ms* 1789000000000)
        (h (%make-head)))
    (let* ((wall (unix-now-ms))
           (wire (+ wall 300000)))
      ;; (1) THE LIVE PATH: an ask that arrives while this head is watching
      (leticl::%handle-frame
       h (list :frame "event" :seq 1 :event "decision_requested"
               :req-id "live" :kind "permission"
               :summary "`bash` wants exec access" :target "cargo test"
               :options (list (list :option-id "allow_once" :label "Allow this one"))
               :deadline wire :on-timeout "deny"))
      (let ((d (first (session-open-decisions (head-session h)))))
        (is (equal "expires in 5 min" (deadline-said (getf d :deadline)))
            "the live ask counts down from the daemon's instant: ~s"
            (deadline-said (getf d :deadline)))
        (is (= wire (getf d :deadline-wire))
            "and the wire's own value is kept beside it"))
      ;; (2) THE SNAPSHOT PATH: the same ask, read by a head that attached afterwards
      (leticl::%handle-frame
       h (list :frame "resync" :reason "attach" :dropped 0 :scrubbed nil
               :snapshot (list :session-id "s-r18" :seq 900 :items nil :turn nil
                               :dropped 0 :items-dropped 0 :warnings nil :heads nil
                               :settled-decisions nil
                               :open-decisions
                               (list (list :req-id "snap" :kind "permission"
                                           :summary "`bash` wants exec access"
                                           :target "cargo test"
                                           :options (list (list :option-id "allow_once"
                                                                :label "Allow this one"))
                                           :deadline wire :on-timeout "deny")))))
      (let ((d (first (session-open-decisions (head-session h)))))
        (is (equal "snap" (getf d :req-id)) "the snapshot's ask is the open one now")
        (is (equal "expires in 5 min" (deadline-said (getf d :deadline)))
            "**AND IT COUNTS DOWN THE SAME WAY** — this is the assertion that was
false: the snapshot path left the Unix instant on the slot and the card read it as a
monotonic one, ~s"
            (deadline-said (getf d :deadline)))
        (is (= wire (getf d :deadline-wire))
            "with the wire's value kept, as the live path keeps it")
        ;; the card itself, which is what the operator read
        (let ((text (segs-of (%card-lines-all h 90))))
          (is (search "expires in 5 min" text) "and the card says so: ~s" text)
          (is (not (search "29833973" text)) "not the year 2083"))))))

(def-test the-clock-in-a-snapshot-is-the-same-rule-as-the-clock-on-the-wire (:suite leticl)
  "One rule, two folds — the R16 shape, stated as an invariant rather than as two cases
that happen to agree.

Every open decision this head holds has its `:deadline` on **this head's** clock,
whether it arrived on the wire or inside a snapshot; and every one of them keeps the
wire's own value on `:deadline-wire`, so the conversion is inspectable rather than
merely right. A head that converted on one path and not the other passed every test in
this suite and drew 56 years of countdown on the operator's screen."
  (let ((leticl::*fixed-clock-ms* 5000000)
        (leticl::*unix-offset-ms* 1789000000000)
        (h (%make-head)))
    (leticl::%handle-frame
     h (list :frame "event" :seq 1 :event "decision_requested"
             :req-id "live" :kind "permission" :summary "s"
             :deadline (+ (unix-now-ms) 60000)
             :options nil))
    (leticl::%handle-frame
     h (list :frame "resync" :reason "attach" :dropped 0 :scrubbed nil
             :snapshot (list :session-id "s-r18b" :seq 2 :items nil :turn nil
                             :dropped 0 :items-dropped 0 :warnings nil :heads nil
                             :settled-decisions nil
                             :open-decisions
                             (list (list :req-id "snap" :kind "permission" :summary "s"
                                         :deadline (+ (unix-now-ms) 120000)
                                         :options nil)))))
    (dolist (d (session-open-decisions (head-session h)))
      (is (integerp (getf d :deadline-wire))
          "every open decision keeps the wire's value: ~s" (getf d :req-id))
      (let ((left (deadline-remaining-ms (getf d :deadline))))
        (is (and (integerp left) (<= 0 left 180000))
            "and its own deadline is a DURATION on this head's counter, not an instant
in 2026: ~s left for ~s" left (getf d :req-id))))))

(def-test the-option-label-is-drawn-as-the-daemon-wrote-it (:suite leticl)
  "**The head half of R18's fifth wrong thing, answered by measurement.**

The operator's card carried `Allow \`<tool>\` (this class) for the rest of the session`.
That string is the DAEMON's: `grant_program` falls back to the literal `<tool>` when the
call has no command to take a program name from (`adjudicate.rs:1592-1600`), and
`exec_options` writes it into the label (`adjudicate.rs:602-625`). Measured on the glass
2026-09-22, both heads on one daemon:
`Allow \`head\` (this class) …` for the bash card whose last stage was `| head -30`, and
`Allow \`<tool>\` (this class) …` for the `job_kill` card — identical on letibot and on
this head, because **neither head composes an option label**: both draw the one the
daemon sent.

So this is not a drift between the heads and there is no head-side fix: a head that
rewrote the backticked clause would be guessing which part of a sentence is a name, and
would leave the daemon writing templates at the flowy, ACP and Android heads. What the
head owes is that its half be a MEASUREMENT rather than an opinion — which is this test,
and it fails the day somebody applies R15's placeholder rule (drop what has no subject)
to a label whose subject is the daemon's to state."
  (flet ((card-for (label)
           (let ((h (%make-head)))
             (setf (session-open-decisions (head-session h))
                   (list (list :req-id "d" :kind "permission"
                               :summary "`job_kill` wants exec access"
                               :target "<no target argument>"
                               :detail "ask — intents [read_file] — auto (a read inside the boundary)"
                               :options (list (list :option-id "allow_once"
                                                    :label "Allow this one")
                                              (list :option-id "allow_session"
                                                    :label label))
                               :on-timeout "ask")))
             (segs-of (%card-lines-all h 120)))))
    ;; (1) the name is PRESENT — the daemon named the program
    (let ((text (card-for "Allow `head` (this class) for the rest of the session")))
      (is (search "Allow `head` (this class) for the rest of the session  (allow_session)"
                  text)
          "the name the daemon sent is drawn, with the id beside it: ~s" text))
    ;; (2) the name is ABSENT — the daemon sent its own placeholder
    (let ((text (card-for "Allow `<tool>` (this class) for the rest of the session")))
      (is (search "Allow `<tool>` (this class) for the rest of the session  (allow_session)"
                  text)
          "and so is its placeholder — this head invents no name and strips none: ~s"
          text))
    ;; (3) and the one other string on that card that is the daemon's too
    (let ((text (card-for "Allow this class for the rest of the session")))
      (is (search "<no target argument>" text)
          "the target placeholder is the daemon's as well, and is drawn as sent"))))

;;; -------------------- R20: the options are pinned, the content shrinks ------------ ;;;
;;;
;;; Ruled by the operator, 2026-09-22, on a permission card carrying a giant `replace`
;;; or a commit message: *"I'm shown a permission prompt and I just can't see the
;;; selector."* And the shape, in their words:
;;;
;;; > those selectors are staying pinned to bottom and not scrollable — the scrollable
;;; > viewport shrinks vertically tho.
;;;
;;; **MEASURED BEFORE THE FIX, and it is the reason this file has five tests rather than
;;; one.** A 40-line diff on a 30-row screen: not one option, not the hint, not the
;;; deadline — `card-rows` shrank from the end of one list and the end is where the
;;; choices are. At EVERY size from 8 rows to 30. Same defect as letibot's
;;; `dec_rows -= 1` (`app.rs:6641`), which is what the ruling points at.

(defun %r20-card (head &key (diff-lines 40) (req-id "adj-r20") (deadline nil))
  "The card the operator was looking at: unbounded content above the ladder."
  (setf (session-open-decisions (head-session head))
        (list (list :req-id req-id :kind "permission"
                    :summary "`edit` wants write access to `src/panes.lisp`"
                    :target "src/panes.lisp"
                    :detail (format nil "the patch:~%~{~a~%~}"
                                    (loop for i from 1 to diff-lines
                                          collect (format nil "-old ~d~%+new ~d" i i)))
                    :because "workspace: /tmp"
                    :advice (list :would "ask" :basis "it touches the render loop"
                                  :by "oracle-local" :latency-ms 310)
                    :options (list (list :option-id "allow_once" :label "Allow this one"
                                         :kind "allow_once")
                                   (list :option-id "allow_session"
                                         :label "Allow `edit` (this class) for the rest of the session"
                                         :kind "allow_session")
                                   (list :option-id "deny" :label "Deny" :kind "deny")
                                   (list :option-id "deny_and_tell"
                                         :label "Deny, and tell the model why"
                                         :kind "reject_and_tell"))
                    :deadline deadline
                    :on-timeout "deny")))
  head)

(defun %r20-screen (rows &optional (cols 100))
  "The rendered frame at ROWS x COLS, as plain strings.

**The clocks are bound around the RENDER and not around `%on-head`** — measured: bound
around the constructor alone, the render that draws the card reads the real wall clock,
the deadline `(+ 10000000 300000)` is read as an instant in 1970, and the card says
`expires in 172 min` where this asserts `expires in 5 min`. The binding has to cover the
thing being measured."
  (let* ((leticl::*fixed-clock-ms* 10000000)
         (leticl::*unix-offset-ms* 0)
         (h (%on-head :cols cols :rows rows)))
    (%r20-card h :deadline (+ 10000000 300000))
    (leticl::%render h)
    (loop for y from 0 below rows
          collect (let ((out (make-string-output-stream)))
                    (loop for x from 0 below cols
                          for cell = (screen-cell (head-screen h) y x)
                          do (write-char (if cell (cell-ch cell) #\space) out))
                    (string-right-trim " " (get-output-stream-string out))))))

(defun %r20-text (rows &optional (cols 100))
  (format nil "~{~a~%~}" (%r20-screen rows cols)))

(def-test the-ladder-survives-a-card-too-big-for-the-screen (:suite leticl)
  "**R20, and this is the operator's own measurement turned into an assertion.**

Before the fix, at every size from 8 rows to 30, with a 40-line diff: no
`allow_once`, no `deny`, no `deny_and_tell`, no hint, no deadline. The fit loop
shrank the card from the END of one list and the end is where the ladder is.

The rule: **the ladder is pinned to the bottom and is never trimmed**, the content
above it shrinks into a viewport, and that viewport scrolls. So this asserts the
ladder at six sizes — and asserts that the CONTENT is what got small, which is the
other half: a fix that kept everything by drawing the card over the frame would pass
a ladder-only check."
  (dolist (rows '(40 30 24 16 12 10))
    (let* ((leticl::*unix-offset-ms* 0)
           (text (%r20-text rows)))
      (is (search "Allow this one  (allow_once)" text)
          (format nil "~d rows: the first option is on the screen" rows))
      (is (search "Deny  (deny)" text)
          (format nil "~d rows: and so is Deny" rows))
      (is (search "Deny, and tell the model why" text)
          (format nil "~d rows: and the last one" rows))
      (is (search "↑↓ to choose" text)
          (format nil "~d rows: with the keys that answer it" rows))
      (is (search "expires in 5 min" text)
          (format nil "~d rows: **and what silence does** — it is part of the ladder, \
because the consequence of not answering is about the answer" rows))
      ;; and the content is NOT all there: the card cannot be claiming to show a diff it
      ;; has no rows for
      (is (not (search "+new 40" text))
          (format nil "~d rows: the content is windowed, not drawn in full" rows)))))

(def-test the-content-viewport-says-how-much-is-out-of-view (:suite leticl)
  "**The seam counts, and it does not say *more*.**

The operator's own correction: *\"it says how much is out of view, not that there is
more.\"* A count is a fact the reader can act on; *\"there is more\"* is a shrug. So the
seam carries the number, and the number is the arithmetic — total rows minus what the
window shows.

It also names the key, and the key has to work: a seam that advertises `PgDn` and is
swallowed by the composer is the lie this repo keeps refusing to ship."
  (let* ((text (%r20-text 16))
         (seam (find-if (lambda (l) (search "out of view" l)) (%r20-screen 16))))
    (is (not (null seam)) "a windowed card says so: ~s" text)
    (is (search "below" seam) "below, because it opens at the top: ~s" seam)
    (is (search "PgDn scrolls" seam) "and names the key that moves it: ~s" seam)
    ;; the count is the real one: 40 diff lines are 81 rows, plus the headline and the
    ;; target and `the patch:` — the window shows a few, the seam accounts for the rest
    (let* ((mark (search "… " seam))
           (digits (subseq seam (+ mark 2)))
           (n (parse-integer (subseq digits 0 (position #\space digits)))))
      (is (> n 60) "the count is the whole of what is not shown, not a sample: ~d" n))
    ;; a card that FITS has no seam: a seam on a card with nothing to scroll is a
    ;; promise of content that is not there
    (let* ((leticl::*fixed-clock-ms* 10000000)
           (leticl::*unix-offset-ms* 0)
           (h (%on-head :cols 100 :rows 40)))
      (%r20-card h :diff-lines 0 :deadline (+ 10000000 300000))
      (leticl::%render h)
      (let ((small (format nil "~{~a~}"
                           (loop for y from 0 below 40
                                 collect (let ((o (make-string-output-stream)))
                                           (loop for x from 0 below 100
                                                 for c = (screen-cell (head-screen h) y x)
                                                 do (write-char (if c (cell-ch c) #\space) o))
                                           (get-output-stream-string o))))))
        (is (not (search "out of view" small))
            "everything fits, so there is nothing to disclose and no seam: ~s" small)
        (is (search "Deny  (deny)" small) "and the ladder is still there")))))

(def-test the-card-viewport-scrolls-and-the-ladder-does-not-move (:suite leticl)
  "**The second half of the ruling: *the scrollable viewport shrinks vertically tho***
— and it still scrolls, so the whole diff is readable without the choices leaving the
screen.

Driven through `%handle-key`, so this is a test of the BINDING and not of a `setf`: the
seam names `PgDn`, and a seam that names a key the composer swallows is exactly the
class of lie this head keeps finding."
  (let* ((leticl::*fixed-clock-ms* 10000000)
         (leticl::*unix-offset-ms* 0)
         (leticl::*card-scroll* 0)
         (leticl::*card-scroll-for* nil)
         (h (%on-head :cols 100 :rows 16)))
    (%r20-card h :deadline (+ 10000000 300000))
    (flet ((frame ()
             (leticl::%render h)
             (format nil "~{~a~%~}"
                     (loop for y from 0 below 16
                           collect (let ((o (make-string-output-stream)))
                                     (loop for x from 0 below 100
                                           for c = (screen-cell (head-screen h) y x)
                                           do (write-char (if c (cell-ch c) #\space) o))
                                     (string-right-trim " " (get-output-stream-string o)))))))
      (let ((top (frame)))
        (is (search "-old 1" top) "the viewport starts at the head of the content")
        (is (search "out of view below" top) "with the seam below it")
        ;; PgDn through the real key handler
        (leticl::%handle-key h (list :type :page-down))
        (is (= *card-page* leticl::*card-scroll*) "PgDn pages by the page unit")
        (let ((paged (frame)))
          (is (not (search "-old 1" paged)) "the content moved: the head is gone")
          ;; **the seam names BOTH sides at once, which is the honest shape** — measured,
          ;; it reads `… 30 rows above, 53 below out of view · PgUp/PgDn scrolls`
          (is (search "above" paged) "**and the seam counts what is behind the window**")
          (is (search "below" paged) "as well as what is ahead of it")
          (is (search "PgUp/PgDn scrolls" paged) "naming both keys, because both work")
          (is (search "Allow this one  (allow_once)" paged)
              "**AND THE LADDER DID NOT MOVE** — the whole point of the ruling")
          (is (search "expires in 5 min" paged) "nor did what silence does"))
        ;; End goes to the bottom, and the seam says only `above`
        (leticl::%handle-key h (list :type :end))
        (let ((end (frame)))
          (is (search "+new 40" end) "the last row of the content is readable")
          (is (search "out of view above" end) "with everything behind it counted")
          (is (not (search "out of view below" end)) "and nothing ahead")
          (is (search "Deny, and tell the model why" end) "and the ladder is still there"))
        ;; Home comes back, and the wheel and PgUp walk the same axis
        (leticl::%handle-key h (list :type :home))
        (is (= 0 leticl::*card-scroll*) "Home is the top")
        (leticl::%handle-key h (list :type :mouse :kind :wheel-down))
        (is (= *card-page* leticl::*card-scroll*) "the wheel pages it too")
        (leticl::%handle-key h (list :type :page-up))
        (is (= 0 leticl::*card-scroll*) "and PgUp comes back, clamped at the top")))))

(def-test a-card-that-does-not-fit-never-loses-its-choices-to-the-fit-loop (:suite leticl)
  "**The fit ladder, at the level the defect happened.**

The old floor was `(> dec 1)` — the card could shrink to a single row, and because the
card is drawn from the front of one list every row it gave up came off the end. The floor
is now the ladder plus one row of content, and everything else on the screen is still
given up first, in the same order: completions, hint, notice, composer rows, stall, box.

This is the test that fails if somebody 'simplifies' the floor back, so it asserts the
floor itself rather than a screen: `%fit-ladder` is asked for a card of 100 content rows
and 9 ladder rows on a 20-row screen, and must not return less than 10."
  (let* ((leticl::*fixed-clock-ms* 10000000)
         (leticl::*unix-offset-ms* 0)
         (h (%on-head :cols 100 :rows 20)))
    (%r20-card h)
    ;; **PARAMETERISED OVER THE SIZES THAT DISCRIMINATE, and the first version of this
    ;; test did not.** At 20 rows the old floor `(> dec 1)` still left the card 18 rows —
    ;; more than a 9-row ladder — so the assertion held with the defect restored and
    ;; proved nothing. Measured: it takes a frame small enough that the old floor would
    ;; take the card BELOW its ladder. Falsified by restoring `(> dec 1)`, which fails
    ;; this at 10 and 8 rows.
    (dolist (rows '(20 16 12 10 8))
      (multiple-value-bind (card-rows)
          (leticl::%fit-ladder h 100 rows 100 9 nil nil nil)
        (is (>= card-rows 10)
            (format nil "~d rows: **THE CARD KEEPS ITS LADDER AND A ROW OF CONTENT** — \
~d rows for 100 rows of content and 9 of choices" rows card-rows))
        (is (< card-rows 100)
            (format nil "~d rows: and it is still a window, not the whole card" rows))))
    ;; a card with NO ladder is ordinary content and may shrink the old way
    (multiple-value-bind (card-rows)
        (leticl::%fit-ladder h 100 20 100 0 nil nil nil)
      (is (>= card-rows 1) "a card with no choices still gets a row: ~d" card-rows))))

(def-test a-new-ask-opens-at-its-own-top (:suite leticl)
  "A scroll offset is an offset into ONE diff. Carried to the next ask it would open a
card already scrolled past its own headline — the same defect `*payload-view*` avoids by
keying its window to the row's item id, and this keys to the decision's `req-id`."
  (let ((leticl::*fixed-clock-ms* 10000000)
        (leticl::*card-scroll* 0)
        (leticl::*card-scroll-for* nil)
        (h (%on-head :cols 100 :rows 16)))
    (%r20-card h :diff-lines 40 :req-id "ask-1" :deadline (+ 10000000 300000))
    (leticl::%render h)
    (leticl::%handle-key h (list :type :end))
    (is (plusp leticl::*card-scroll*) "the reader scrolled to the bottom")
    ;; THE SAME ASK: the offset is the reader's and it stays
    (leticl::%render h)
    (is (plusp leticl::*card-scroll*) "redrawing the same card does not move it")
    ;; A NEW ASK: it opens at its own top
    (%r20-card h :diff-lines 40 :req-id "ask-2" :deadline (+ 10000000 300000))
    (leticl::%render h)
    (is (zerop leticl::*card-scroll*)
        "**a new ask starts at its own top**, not at the previous diff's offset")))

(def-test the-card-says-what-silence-will-do (:suite leticl)
  "The fact that does not change, and the one an operator who walked away needs.

`deny` costs one refused call; `allow` runs it UNATTENDED. An operator who left
believing the default was `deny` when it was `allow` has been told nothing by a clock
— so the consequence is drawn on every card that has a deadline, in the daemon's own
three words (`deny | allow | ask`, `event.rs:250-257`). The upper case on `RUNS` is
deliberate: it is the only one of the three that does something nobody asked for.

A word this head does not know draws no clause rather than a guess, which is the same
rule the unreadable-frame path keeps: a wrong consequence is worse than an absent one."
  (is (equal "if nobody answers, nothing runs" (on-timeout-said "deny")))
  (is (search "RUNS" (on-timeout-said "allow")) "the unattended one shouts")
  (is (search "guard model" (on-timeout-said "ask")) "the third answers by itself")
  (is (null (on-timeout-said "timeout")) "a word this head does not know says nothing")
  (is (null (on-timeout-said nil)) "and neither does an absent one")
  ;; on the card, under the options, where the answer is being asked for
  (let ((leticl::*fixed-clock-ms* 10000000)
        (h (%make-head)))
    (setf (session-open-decisions (head-session h))
          (list (list :req-id "d" :kind "permission" :summary "`bash` wants exec access"
                      :target "cargo test --workspace"
                      :options (list (list :option-id "allow_once" :label "Allow once"))
                      :deadline (+ 10000000 47000)
                      :on-timeout "deny")))
    (let* ((lines (%card-lines-all h 90))
           (text (lines-text lines))
           (clause (find-if (lambda (l) (search "47s left" (format nil "~{~a~}" (mapcar #'car l))))
                            lines)))
      (is (not (null clause)) "the time clause is on the card")
      (is (search "if nobody answers, nothing runs" (format nil "~{~a~}" (mapcar #'car clause)))
          "with what silence does, on the same line")
      (is (equal '(:dim t) (cdr (first clause)))
          "dim — the ladder is what the card is asking for and a second yellow line
 competes with it")
      (is (> (position-if (lambda (l) (search "Allow once" l)) text)
             (position-if (lambda (l) (search "wants exec access" l)) text))
          "and below the options, which is the order the consequence matters in"))))

(def-test a-countdown-is-a-reason-to-repaint-but-not-a-tenth-one (:suite leticl)
  "**The link to R13.** A clock on a card is a reason to repaint for the same reason a
spinner is — the frame is a snapshot and nothing else would ask for another one — so
an open ask with a deadline joins `live-frame-p`.

**But not at the tenth-of-a-second rate.** A countdown says whole minutes far out and
whole seconds near, so ten frames a second would draw the same characters nine times:
the interval is `+live-frame-ms+` when something is drawn in tenths (a spinner, a
running call's elapsed, the carry bar) and `+live-frame-coarse-ms+` when the only live
part is a countdown."
  (let ((leticl::*last-paint-ms* 0)
        (h (%make-head)))
    (setf (head-dirty h) nil)
    (is (not (live-frame-p h)) "idle: no clock on the frame")
    (is (= +live-frame-coarse-ms+ (live-frame-interval-ms h)) "and the slow rate waiting")
    (setf (session-open-decisions (head-session h))
          (list (list :req-id "d" :deadline (+ (internal-real-time-ms) 60000))))
    (is (live-frame-p h) "an open ask with a deadline is a function of time")
    (is (not (live-frame-tenths-p h)) "but nothing on the frame moves in tenths")
    (is (= +live-frame-coarse-ms+ (live-frame-interval-ms h))
        "so it asks for one frame a second")
    ;; a running turn joins it, and takes the rate back to tenths
    (setf (session-turn (head-session h)) (list :state (list :state "running") :calls nil))
    (is (live-frame-tenths-p h))
    (is (= +live-frame-ms+ (live-frame-interval-ms h)) "a spinner is drawn in tenths")
    ;; an ask WITHOUT a deadline is not a clock and must not ask for frames
    (setf (session-turn (head-session h)) nil
          (session-open-decisions (head-session h)) (list (list :req-id "d")))
    (is (not (live-frame-p h)) "an ask that cannot expire is not a clock")))

(def-test the-password-card-counts-down-and-the-dots-are-in-the-field (:suite leticl)
  "`secret_lines` (app.rs:7305-7327) and `composer_rows` (app.rs:5343-5348).

Two measured breakages. `SecretAsk.deadline` arrives on the frame and was folded
onto `head-secret-req` and never read, so a sudo ask about to time out looked
exactly like one that had just arrived. And the dots were drawn INSIDE the card
while the composer under it kept painting the ordinary buffer — so whatever had
been typed before sudo asked sat on the screen while a password was entered over
the top of it. The reference renders the dots in the composer box and never even
measures the text."
  (let* ((*stdout* (make-string-output-stream))
         ;; **the deadline on `head-secret-req` is already on THIS head's clock**,
         ;; converted where the frame arrived — so the test's clock is the fixed one
         ;; `internal-real-time-ms` answers, and 47 s from now is what it means
         (leticl::*fixed-clock-ms* 1000000)
         (h (%on-head :cols 80 :rows 24 :buffer "the sentence I was typing")))
    (setf (head-secret-req h) (list :req-id "r" :prompt "[sudo] password for dead:"
                                    :command "apt install ripgrep"
                                    :deadline 1047000)
          (leticl::head-secret-buf h) "hunter2")
    ;; at 120 columns, where the sentence fits — the reference trims this row to
    ;; the width it has (`trim_to`), so a narrow screen loses the tail of it
    (let ((text (format nil "~{~a~^~%~}" (lines-text (leticl::secret-ask-lines h 120)))))
      (is (search "sudo wants a password — [sudo] password for dead:" text))
      (is (search "for: apt install ripgrep" text))
      (is (search "· 47s left" text) "the countdown, from the deadline on the frame"))
    ;; **no deadline, no clause.** §11.5's `deadline: null` is "wait forever", which
    ;; is a policy rather than missing information, so a card whose ask cannot expire
    ;; says nothing about time — an ask with no clock must not have one invented for
    ;; it, and "I was not told" must not be manufacturable by a card that never had a
    ;; countdown to show. The gate card's own rule is `deadline-said`'s.
    (setf (getf (head-secret-req h) :deadline) nil)
    (is (not (search "s left" (format nil "~{~a~}"
                                      (lines-text (leticl::secret-ask-lines h 120)))))
        "and no countdown at all when the daemon sent no deadline")
    (leticl::%render h)
    (let ((screen (%screen-text h)))
      (is (search "•••••••" screen) "a dot per character, in the composer's own box")
      (is (not (search "the sentence I was typing" screen))
          "and the buffer underneath is not on the screen while sudo is asking"))))

(def-test the-header-prefers-the-prompt-being-sent (:suite leticl)
  "`header_line` (app.rs:6274-6281): **live prefill numbers win while a turn
runs**, because \"how big is this prompt\" is a question about the prompt being
sent and not about the last one that finished. Ours read `state.usage` or
`turn.usage` and had no `progress` path at all, so through the whole of a long
turn the header showed the PREVIOUS turn's context while the bar on the
composer's edge expanded a different one.

`src/session.lisp:218-223` has folded `PromptProgress` onto the turn as
`(:total :cache :processed :time-ms)` since it was written; nothing read it."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-turn s)
          (list :turn-id "t1"
                :state (list :state "running"
                             :usage (list :prompt-tokens 900 :cached-tokens 100))
                :progress (list :total 41200 :cache 37000 :processed 1000 :time-ms 500)))
    (let ((parts (format nil "~{~a~^ · ~}" (leticl::%usage-numbers s))))
      (is (search "41.2k ctx" parts) "the prompt being sent, not the one that finished")
      (is (not (search "900 ctx" parts)) "the kept usage does not win while one is in flight")
      (is (search "90% cached" parts) "and the live cache fraction beside it"))
    ;; with nothing in flight the kept usage is what there is
    (setf (getf (session-turn s) :progress) nil)
    (let ((parts (format nil "~{~a~^ · ~}" (leticl::%usage-numbers s))))
      (is (search "900 ctx" parts) "and the kept usage when no prefill is running"))))

;;; ------------------------ R8: the context outlives the head -------------- ;;;
;;;
;;; The operator: *"leticl doesnt show context size for whatever reason"*. Measured,
;;; and it is not the header — the header builds the same `(total cached
;;; cache-measured)` triple the reference does and draws `633.5k ctx` correctly while a
;;; turn's usage is in hand. **The divergence is the fallback under it.** A daemon that
;;; restarted has no turn state in the snapshot, so after a reattach, a resume, or a
;;; session opened from disk the usage is empty and the whole `ctx` segment vanished —
;;; which is most of the time, and precisely when somebody asks how big the
;;; conversation is. The daemon writes the answer on the session's OWN row at every
;;; round finish (`persist_context`, harness.rs:4930-4941) and the reference reads it
;;; there (app.rs:2116-2140).

(defun %header-facts (h)
  "The header's right-hand numbers as one string — `%usage-numbers`, which is what the
header draws, so an assertion here is about the row and not about a helper.

`top-border` is asserted separately in the criterion test: it is the same numbers,
and asserting on both is how `the header says X` stays a claim about the header."
  (format nil "~{~a~^ · ~}" (leticl::%usage-numbers (head-session h))))

(defun %session-with-row (&key context-tokens context-cached (turn nil))
  "The head R8 is about: a session whose turn state is GONE, with a daemon row."
  (let* ((h (%make-head))
         ;; `let*`: `(head-session h)` is evaluated in the same binding list `h` is
         ;; introduced by, so a plain `let` had `h` unbound — the error was three
         ;; tests deep and looked like a missing helper
         (s (head-session h)))
    (setf (session-session-id s) "s-r8"
          (session-title s) "the cache question"
          (session-turn s) turn
          (session-sessions s)
          (list (list :session-id "s-r8" :title "the cache question"
                      :stored-items 2647
                      :context-tokens context-tokens
                      :context-cached context-cached)))
    h))

(def-test the-context-size-survives-a-daemon-restart (:suite leticl)
  "R8, in the operator's terms: **attach to a session that is not running and the
header still says how big it is.**

No turn, no usage, no snapshot turn state — only the session's own row, which the
daemon writes at the end of every round. Before this the header showed nothing at all
here, which is the screen a reattach lands on."
  (let ((leticl::*write-prefs* nil))
    ;; the size, and the fraction when the row knows it
    (let* ((h (%session-with-row :context-tokens 633512 :context-cached 590000))
           (parts (%header-facts h)))
      (is (search "633.5k ctx" parts) "the header says how big the conversation is")
      (is (search "93% cached" parts) "and the fraction the row measured")
      ;; and on the ROW itself, which is the claim — `%usage-numbers` is what it draws
      (let ((text (format nil "~{~a~}" (mapcar #'car (top-border h (head-cols h))))))
        (is (search "633.5k ctx · 93% cached" text)
            "the assembled header row carries both numbers")
        (is (not (search "$" text)) "and no money, which this row never measured")))
    ;; **THE SIZE WITHOUT THE FRACTION.** A row that predates the `context_cached`
    ;; column knows how big the prompt was and not how much of it was cached, so the
    ;; percentage is ABSENT — not `0% cached`, which would be a measurement nobody made.
    (let* ((h (%session-with-row :context-tokens 633512))
           (parts (%header-facts h)))
      (is (search "633.5k ctx" parts) "a row with no cached count still knows the size")
      (is (not (search "cached" parts)) "and says nothing about the cache at all"))
    ;; a row with neither, and a row whose count is zero, are both "not measured"
    (dolist (h (list (%session-with-row)
                     (%session-with-row :context-tokens 0 :context-cached 0)))
      (is (not (search "ctx" (%header-facts h)))
          "a row that has never measured a prompt says nothing"))
    ;; **NO COST FROM A BACKFILLED ROW.** A zero there would report a metered session as
    ;; free — §13.2b in its most expensive form — so the meter stays silent.
    (let ((h (%session-with-row :context-tokens 633512 :context-cached 590000)))
      (leticl::reset-spent)
      (is (null (spent-text)) "a size from the row is not a bill")
      (is (search "633.5k ctx" (%header-facts h)))
      (is (null (spent-text)) "and drawing the header still does not light the meter"))))

(def-test a-live-turn-still-wins-over-the-sessions-own-row (:suite leticl)
  "The fallback is a FALLBACK. The order is the reference's: the prompt being sent,
what the last turn cost, and only then the row — because the row is a round behind by
construction, it is written when a round FINISHES."
  (let* ((leticl::*write-prefs* nil)
         (h (%session-with-row
             :context-tokens 1000 :context-cached 100
             :turn (list :turn-id "t1"
                         :state (list :state "running"
                                      :usage (list :prompt-tokens 5000 :cached-tokens 2500)))))
         (s (head-session h)))
    (is (search "5000 ctx" (%header-facts h))
        "a turn this head saw beats the session row (`thousands` shortens past 9999)")
    ;; and the live prefill beats even that, which is the rule R8 must not disturb
    (setf (getf (session-turn s) :progress)
          (list :total 41200 :cache 37000 :processed 1000 :time-ms 500))
    (let ((parts (%header-facts h)))
      (is (search "41.2k ctx" parts) "and the prompt being sent beats everything")
      (is (not (search "5000 ctx" parts)) "including the last turn's"))
    ;; a turn with no usage of its own falls through to the row
    (setf (session-turn s) (list :turn-id "t2" :state (list :state "running")))
    (is (search "1000 ctx" (%header-facts h))
        "a turn that has measured nothing does not hide the session's own number")))

(def-test the-session-row-is-read-not-invented (:suite leticl)
  "The `sessions` frame and the `Hello` both carry the brief, so a `/switch` gets the
new session's number with it — and the head never guesses one.

The wire spellings are the daemon's (`context_tokens`, `context_cached`,
`registry.rs:238-244`); the decoder turns them into the keywords the rest of this head
speaks, and this is the assertion that the two agree."
  (let* ((leticl::*write-prefs* nil)
         (h (%session-with-row :context-tokens 100))
         (s (head-session h)))
    ;; as decoded off the wire, through the same path a real frame takes
    (let ((frame (json-decode
                  (format nil "{\"frame\":\"sessions\",\"current\":\"s-r8\",\"created\":null,\"sessions\":[{\"session_id\":\"s-r8\",\"title\":\"t\",\"created_ms\":0,\"stored_items\":3,\"live\":false,\"context_tokens\":633512,\"context_cached\":590000}]}"))))
      (leticl::%handle-frame h frame)
      (is (search "633.5k ctx" (%header-facts h))
          "the row's own numbers, off the wire")))
  (let* ((leticl::*write-prefs* nil)
         (h (%session-with-row :context-tokens 633512))
         (s (head-session h)))
    ;; a session the daemon no longer lists has no row to read
    (setf (session-sessions s) nil)
    (is (not (search "ctx" (%header-facts h)))
        "and a session with no row claims nothing")))

(def-test a-scrubbed-head-shows-the-triangle (:suite leticl)
  "`alarmed()` is `dropped + scrubbed + resyncs > 0` (app.rs:7619-7620 in the old
tree, `:7929-7931` on the current pin, where R3 added a fourth term) and
`alarm-counts` carried the first and the third. A head that had had secrets
stripped out of its rows and nothing else wrong showed **no ⚠ at all** — the one
counter whose entire purpose is that the operator learns about it was the one
kept quiet."
  (let ((h (%make-head))
        (leticl::*resyncs* 0)
        ;; bound with its siblings because `alarmed-p` reads it and it is a global
        (leticl::*unreadable-total* 0)
        (leticl::*scrubbed-total* 0))
    (setf (head-connected h) t)
    (is (not (alarmed-p h)) "a clean head is clean")
    (let ((leticl::*scrubbed-total* 2))
      (is (alarmed-p h) "scrubbed alone is an alarm")
      (is (search "scrubbed 2" (format nil "~{~a ~a~^ · ~}"
                                       (loop for (k . v) in (alarm-counts h)
                                             append (list k v))))
          "and it is named, not merely counted"))))

(def-test a-failed-save-is-said-out-loud (:suite leticl)
  "`app.rs:6413-6423,6541-6545` appends ` (not saved: …)` to the notice. Ours
swallowed the write under `ignore-errors` and said only `key → value`, so a
read-only `head.toml` left the pane claiming a change the file did not have and
the next start of the head silently undid it. A setting that did not persist is a
different fact from one that did."
  (let ((h (%pane-head))
        (real (symbol-function 'save-head-prefs)))
    (unwind-protect
         (progn
           (setf (symbol-function 'save-head-prefs)
                 (lambda (head &optional path)
                   (declare (ignore head path))
                   (error "Permission denied")))
           (setf (head-picker-sel h) 0)      ; `diff view`, a head row
           (leticl::config-change h)
           (is (search "(not saved:" (head-status-note h))
               "the note says the write did not land")
           (is (search "diff view →" (head-status-note h))
               "and still says what the live value became"))
      (setf (symbol-function 'save-head-prefs) real))
    ;; and a save that works says nothing extra
    (setf (head-picker-sel h) 0)
    (leticl::config-change h)
    (is (not (search "(not saved:" (head-status-note h)))
        "a save that landed adds no apology")))

(def-test o-on-a-subagent-row-switches-into-it (:suite leticl)
  "The subagents pane's own footer has advertised `o switches into it` since it
was written (`src/panes.lisp:686`) and **no key was ever bound to it** — the one
row on the screen that names a key named a key that did nothing. The reference
binds it at app.rs:3696-3707.

This is the act; the key is `src/editor.lisp:283-296`'s, whose `:char` arm
handles only `#\\q`."
  (let ((h (%pane-head))
        (sent nil)
        (real (symbol-function 'leticl::%send)))
    (unwind-protect
         (progn
           (setf (symbol-function 'leticl::%send)
                 (lambda (head frame) (declare (ignore head)) (push frame sent)))
           ;; a subagent whose latest state is `opening` — the row says
           ;; `— not attachable yet` and there is nothing to switch to
           (setf (session-subagents (head-session h))
                 (list (list :subagent-id "s-child" :state "opening"
                             :prompt "Fix an auto-compaction failure" :role "worker")))
           (setf (head-picker-sel h) 0 (head-mode h) :subagents)
           (is (null (leticl::subagent-switch h))
               "a subagent that is still opening has no session to switch to")
           (is (null sent) "and nothing went out")
           (is (search "not attachable yet" (head-status-note h))
               "and it says so in the same words the row does")
           ;; make it running, which is what `[~]` on the row means
           (setf (session-subagents (head-session h))
                 (list (list :subagent-id "s-child" :state "running"
                             :prompt "Fix an auto-compaction failure" :role "worker")))
           (is (leticl::subagent-switch h) "a running one switches")
           (is (equal "switch" (getf (first sent) :frame)) "a switch frame went out")
           (is (equal "s-child" (getf (first sent) :session-id)) "for that subagent")
           (is (eq :normal (head-mode h)) "and the pane closed behind it"))
      (setf (symbol-function 'leticl::%send) real))))

(def-test the-gutter-is-the-first-thing-a-narrow-screen-gives-up (:suite leticl)
  "`gutter` (app.rs:5320-5327): two columns at forty or more and **zero below**,
because \"four columns out of forty is a tenth of the line, and out of twenty it
is a fifth.\" Ours were two constants that never moved at any width, so on a
30-column terminal the reference wrapped the body at 30 and this head wrapped it
at 26 and drew a margin nobody had the columns for."
  (is (= 2 (leticl::frame-gutter 40)) "two at the threshold")
  (is (= 0 (leticl::frame-gutter 39)) "and none below it")
  (let ((*stdout* (make-string-output-stream)))
    (let ((h (%on-head :cols 30 :rows 20)))
      (leticl::%render h)
      (let ((row (find-if (lambda (l) (search "╭" l))
                          (uiop:split-string (%screen-text h) :separator '(#\newline)))))
        (is (and row (= 0 (position #\╭ row)))
            "at 30 columns the box starts at the very first column")
        (is (and row (= 29 (position #\╮ row)))
            "and ends at the last one: all thirty go to the frame")))
    (let ((h (%on-head :cols 60 :rows 20)))
      (leticl::%render h)
      (let ((row (find-if (lambda (l) (search "╭" l))
                          (uiop:split-string (%screen-text h) :separator '(#\newline)))))
        (is (and row (= 2 (position #\╭ row)))
            "and at 60 the gutter is back")))))

(def-test the-chrome-is-given-up-in-the-references-order (:suite leticl)
  "**There was no fit ladder and no backstop.** `boxed = (>= rows 8)` was the
whole of this head's degradation — one step, taken whether or not anything else
could have been given up first — and nothing clamped the result, so on a short
terminal the composer's first row came out at a NEGATIVE index and the head
returned more rows than the terminal has.

The reference drops in a named order (app.rs:5094-5126) — completions, the hint
bar, the notice, a composer row down to one, the stall sentence, the box, a
decision row — and then clamps (app.rs:5206-5208). Every position in that order
is an argument; this asserts the order itself."
  (let* ((*stdout* (make-string-output-stream))
         (leticl::*now-ms* 100000)
         (leticl::*last-event-ms* 0)
         (h (%on-head :cols 80 :rows 20 :buffer "/he")))
    (say h "the head has something to say")
    (setf (session-turn (head-session h))
          (list :turn-id "t1" :model "a-model" :state (list :state "running")))
    (flet ((frame (rows)
             (setf (head-rows h) rows)
             (screen-resize (head-screen h) 80 rows)
             (screen-resize (head-prev-screen h) 80 rows)
             (leticl::%render h)
             (%screen-text h)))
      (let ((wide (frame 20)))
        (is (search "/help" wide) "at 20 rows the completions row is there")
        (is (search "ctrl-s sessions" wide) "and the hint bar")
        (is (search "the head has something to say" wide) "and the notice")
        (is (search "nothing received for" wide) "and the stall sentence")
        (is (search "╭" wide) "and the box"))
      (let ((r7 (frame 7)))
        (is (not (search "/help" r7)) "the completions row goes first")
        (is (search "ctrl-s sessions" r7) "the hint bar is still there"))
      (let ((r6 (frame 6)))
        (is (not (search "ctrl-s sessions" r6)) "the hint bar goes next")
        (is (search "the head has something to say" r6) "the notice is still there"))
      (let ((r5 (frame 5)))
        (is (not (search "the head has something to say" r5)) "then the notice")
        (is (search "nothing received for" r5) "the stall outlives it — it is the
only thing on the screen saying why nothing is happening"))
      (let ((r4 (frame 4)))
        (is (not (search "nothing received for" r4)) "then the stall")
        (is (search "╭" r4) "the box outlives it"))
      (let ((r3 (frame 3)))
        (is (not (search "╭" r3)) "and the box is last of the chrome")
        (is (search "›" r3) "the composer is what is left")))))

(def-test the-frame-never-returns-more-rows-than-the-terminal-has (:suite leticl)
  "The backstop (app.rs:5206-5208): `the ladder above cannot always win — h can
be 2 — and a head that returns more lines than the terminal has scrolls its own
composer off the bottom`. Ours had none, and `cursor` could go negative.

Here it is a one-row terminal with a four-row card on it, which the ladder cannot
fit: everything that does not fit is placed above row 0 and dropped by
`screen-put`, which is the frame the reference gets by draining the front of its
chrome vector. The caret is clamped at both ends for the same reason."
  (let ((*stdout* (make-string-output-stream)))
    (dolist (rows '(1 2 3 5))
      (let ((h (%on-head :cols 40 :rows rows)))
        (setf (head-quit-open h) t)       ; a four-row card
        (screen-resize (head-screen h) 40 rows)
        (screen-resize (head-prev-screen h) 40 rows)
        (setf (head-rows h) rows)
        (finishes (leticl::%render h))
        (is (= rows (length (uiop:split-string (%screen-text h) :separator '(#\newline))))
            (format nil "at ~d row~:p the frame is ~d rows" rows rows))
        (is (and (>= (car *caret*) 0) (< (car *caret*) rows))
            (format nil "and the caret is on the screen at ~d row~:p" rows))
        (is (>= (cdr *caret*) 0) "and never at a negative column")))
    ;; and the header is not drawn on a screen too short for it (app.rs:5231)
    (let ((h (%on-head :cols 40 :rows 5)))
      (leticl::%render h)
      (is (not (search "▌" (%screen-text h)))
          "a five-row frame does not spend one of its five on a header")
      (setf (head-rows h) 6)
      (screen-resize (head-screen h) 40 6)
      (screen-resize (head-prev-screen h) 40 6)
      (leticl::%render h)
      (is (search "▌" (%screen-text h)) "and at six it is back"))))

(def-test the-turn-status-leads-with-the-spinner (:suite leticl)
  "`turn_status` (app.rs:7538-7566): `{spin} Responding{since}{count}`. Ours was
`Responding{count}{since} · {spin}` — the spinner last, where a narrow border
truncates the one moving glyph away first, and the count and the elapsed swapped.

And there was **no prefill arm at all**: while the prompt is still expanding the
reference replaces the whole status with the bar. `prefill-line`
(`src/progress.lisp:172`) was written, tested and called from nowhere, so the one
number this harness exists to move never reached the composer's edge."
  (let* ((h (%make-head))
         (leticl::*now-ms* 5000)
         (leticl::*turn-started-ms* nil))
    (setf (session-turn (head-session h))
          (list :turn-id "t1" :state (list :state "running") :tokens 1200))
    (let ((s (turn-status h 120)))
      (is (find (char s 0) "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
          "the spinner is the FIRST thing on the line, not the last")
      (is (search "Responding · started before this head attached · 1200 tok" s)
          "and the elapsed comes before the count"))
    ;; a prompt still expanding is a bar, not a word
    (setf (getf (session-turn (head-session h)) :progress)
          (list :total 41200 :cache 37000 :processed 12000 :time-ms 800))
    (let ((s (turn-status h 120)))
      (is (search "prefill" s) "while it prefills, the bar is the status")
      (is (not (search "Responding" s)) "and it replaces the word, as the reference's does")
      (is (find (char s 0) "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏") "the spinner still leads"))
    ;; prefill finished: back to the word
    (setf (getf (getf (session-turn (head-session h)) :progress) :processed) 41200)
    (is (search "Responding" (turn-status h 120))
        "and once the prompt is in, the word is back")))

(def-test the-stall-sentence-is-the-references-fifteen-seconds (:suite leticl)
  "`stuck_line` (app.rs:7594) fires at 15 000 ms. Ours was 20 000 — five extra
seconds of a turn that has stopped talking and nothing on the screen saying so."
  (is (= 15000 leticl::*stall-ms*) "the reference's own number")
  (let ((h (%make-head)))
    (setf (session-turn (head-session h))
          (list :turn-id "t1" :model "a-model" :state (list :state "running")))
    (let ((leticl::*now-ms* 15500) (leticl::*last-event-ms* 0))
      (is (stall-text h) "fifteen and a half seconds of silence is a stall"))
    (let ((leticl::*now-ms* 14500) (leticl::*last-event-ms* 0))
      (is (null (stall-text h)) "fourteen and a half is not"))))

(def-test the-box-edges-pin-their-legends-right-and-frame-them (:suite leticl)
  "`box_edge` (app.rs:5384-5411). Ours put the top legend hard against the `╭`
and painted it bold — the header's register — where the reference pins it RIGHT
in `Role::Pending` (yellow, style.rs:174) and frames it as ` {legend} ─`. Neither
edge had the framing. Invisible until a subagent runs, which is why it survived
two rounds of `compare-heads`.

Gated as the reference gates it: nothing below `inner >= 10`, and the right
legend is dropped rather than squeezed below four columns of room — a legend
squeezed to two characters is a legend nobody can read occupying room the border
needs."
  (let ((wide (car (lines-text (list (leticl::box-edge 40 #\╭ #\╮ "" "2 subagents running"))))))
    (is (search " 2 subagents running ─╮" wide) "framed and pinned right")
    (is (char= #\╭ (char wide 0)) "the corner is still the corner")
    (is (char= #\─ (char wide 1)) "and the fill starts immediately after it")
    (is (= 40 (string-width wide)) "the edge is exactly its width"))
  (is (equal '(:fg :yellow)
             (cdr (find "2 subagents running"
                        (leticl::box-edge 40 #\╭ #\╮ "" "2 subagents running" '(:fg :yellow))
                        :key #'car :test #'string=)))
      "and the legend is Pending, not Strong")
  (let ((narrow (car (lines-text (list (leticl::box-edge 9 #\╭ #\╮ "" "legend"))))))
    (is (not (search "legend" narrow)) "no legend at all below inner >= 10")
    (is (= 9 (string-width narrow)) "and the edge is still whole"))
  (let ((tight (car (lines-text (list (leticl::box-edge 14 #\╭ #\╮ "" "a much longer legend"))))))
    (is (= 14 (string-width tight)) "a legend never makes the edge wider than its width")))

(def-test the-completions-row-lists-what-tab-would-take (:suite leticl)
  "`completions_line` (app.rs:4342-4358). Tab has completed since this head was
written (`src/editor.lisp:118`) and **nothing was ever drawn**, so the only way
to learn what a prefix matched was to press Tab and watch the buffer change under
you. A bare `/` lists everything; a prefix nothing matches draws nothing, because
a row that appears and disappears is noise."
  (let ((h (%on-head :cols 100 :rows 24 :buffer "/mod")))
    (let ((text (car (lines-text (leticl::completions-line h 200)))))
      (is (search "/mode" text) "the verb")
      (is (search "the mode picker" text) "and its hint, as the reference joins them")
      (is (search "/models" text) "and every other match"))
    (setf (composer-buffer (head-composer h)) "/zzz")
    (is (null (leticl::completions-line h 200)) "a prefix nothing matches is no row")
    (setf (composer-buffer (head-composer h)) "/mode allow-all")
    (is (null (leticl::completions-line h 200))
        "and a line with an argument on it is not a name being completed")
    (setf (composer-buffer (head-composer h)) "hello")
    (is (null (leticl::completions-line h 200)) "nor is ordinary prose"))
  ;; and it reaches the screen, above the composer
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 100 :rows 24 :buffer "/mod")))
    (leticl::%render h)
    (is (search "/mode" (%screen-text h)) "it is drawn, above the box")))

(def-test an-empty-session-says-what-it-is (:suite leticl)
  "app.rs:6112-6131: `an empty screen with a status line under it is
indistinguishable from a head that attached to the wrong socket`. Ours had no
banner at all.

Guarded on `attaching-p` the way the reference guards it on `!self.attaching`:
the walking cat covers *not answered yet* and this covers *attached and quiet*,
and an empty screen must never be left to mean both."
  (let* ((*stdout* (make-string-output-stream))
         (leticl::*attach-started-ms* nil)
         (h (%on-head :cols 80 :rows 24)))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "attached, and this session has said nothing yet" text)
          "the banner is on the screen")
      (is (search "/help lists the keys." text) "and it says where the keys are"))
    ;; while the daemon has not answered, the cat has the screen and the banner
    ;; must not claim the session is empty
    (let ((leticl::*attach-started-ms* (internal-real-time-ms)))
      (leticl::%render h)
      (is (not (search "said nothing yet" (%screen-text h)))
          "and it is silent while nobody has reported")
      (is (search "asking the daemon for this session" (%screen-text h))
          "because that is the cat's screen, not this one's"))))

;;; --------------- the call sites the panes strand could not reach (2026-09-20) ;;;

(def-test a-pane-opens-on-the-row-that-means-something (:suite leticl)
  "panes.md G14: `ctrl-s` then enter moved you OFF your own session, because
`%open-pane` set the shared cursor to 0 and row 0 is somebody else's session.
Every other pane opens at the top, which is the honest place when one cursor is
shared between them."
  (let* ((h (%make-head))
         (s (head-session h)))
    (setf (session-session-id s) "s-2"
          (session-sessions s) (list (list :session-id "s-1" :title "one")
                                     (list :session-id "s-2" :title "two")
                                     (list :session-id "s-3" :title "three")))
    (leticl::%open-pane h :picker)
    (is (= 1 (head-picker-sel h)) "the picker opens on the session you are in")
    (leticl::%open-pane h :todos)
    (is (= 0 (head-picker-sel h)) "and every other pane at its top")))

(def-test the-peek-panes-arrows-have-rows-to-walk (:suite leticl)
  "panes.md G5: `pane-row-count` answered 0 for `:peek`, so `move-cursor` clamped
to `(1- 0)` and Up and Down moved nothing — while the pane's own last line
advertised that they scroll. And Esc left to `:normal` where the reference's
`sub_out` arm goes back to the TREE (app.rs:3251-3262)."
  (let ((h (%make-head)))
    (setf (head-peeked h)
          (list (list :seq 1 :event "transcript_content" :item-id "a"
                      :item (list :type "assistant" :text (format nil "one~%two~%three")))))
    (is (plusp (leticl::pane-row-count h :peek)) "the peek pane has rows")
    (is (eq :subagents (pane-escape-target :peek)) "esc goes back to the tree")
    (is (eq :normal (pane-escape-target :todos)) "and elsewhere it closes")
    (setf (head-mode h) :peek)
    (leticl::%handle-key h (list :type :esc))
    (is (eq :subagents (head-mode h)) "which is where esc lands from the peek pane")))

(def-test o-switches-into-the-subagent-under-the-cursor (:suite leticl)
  "panes.md G13: `o` on the subagents pane switches into that subagent
(app.rs:3696-3707); anywhere else it promotes the running command, which is what
the chord has always meant here."
  (let* ((h (%make-head))
         (wire (make-string-output-stream)))
    (setf (leticl::head-stream h) wire (head-connected h) t
          (head-mode h) :subagents
          (session-subagents (head-session h))
          ;; `subagent_id` is the CHILD's own id; the envelope's `session_id` is
          ;; the parent's, which is why the fold keys on the first
          (list (list :subagent-id "s-sub-1" :session-id "s-parent" :state "running"
                      :prompt "scout the transcript" :role "digest")))
    (leticl::%handle-key h (list :type :ctrl :ch #\o))
    (let ((line (get-output-stream-string wire)))
      (is (search "switch" line) "a switch frame went out: ~a" line)
      (is (search "s-sub-1" line) "naming the subagent's session"))))

;;; =========================================================================
;;; The parity pass of 2026-09-20, closing `docs/parity/rendering.md`.
;;;
;;; Every test below names what was MEASURED against
;;; `~/Projects/letibot/letibot` @ `8af671e` and the reference function that
;;; settles the question. Segment-level assertions where the style is part of
;;; the finding: a segment is `(TEXT . STYLE)`, so one `is` pins both.
;;; =========================================================================

(defun %draw-segs (lines &key (cols 100))
  "LINES painted onto a real screen and read back as ANSI — what the head
ACTUALLY draws, cells and all, rather than the segments handed to the painter.

The distinction is the whole point of the sanitising test below: a segment can
hold any bytes at all, and the question is which of them reach a terminal."
  (let ((s (make-screen cols (max 1 (length lines)))))
    (loop for line in lines
          for r from 0
          do (let ((c 0))
               (dolist (seg line)
                 (setf c (screen-put-string s r c (car seg)
                                            (leticl::style-index (cdr seg)))))))
    (format nil "~{~a~^~%~}" (leticl::screen-rows-ansi s))))

(def-test a-tool-payload-cannot-reconfigure-the-operators-terminal (:suite leticl)
  "**The reference's `f36d927`, ported.** A payload is whatever the command
wrote. Counted in the operator's own store, 2026-09-20: 44 `tool_result` rows
carry an escape and 20 carry a MODE string — `?1002`/`?1006` are mouse
reporting, `?1049` the alternate screen, `?2004` bracketed paste. Turning mouse
reporting off is why *\"when i expand tools with Ct scroll stops working, even
after collapsing back\"*.

`without_control` (app.rs:369) maps every control character to a SPACE before
the row is built (app.rs:9712) — a space and not a deletion, because the wrapper
about to measure these lines counts columns.

Asserted as the PAIRING, as the reference asserts it: `[?1002l` as text is six
harmless characters and it is the `ESC` in front of it that a terminal acts on.
Deliberately not \"no ESC anywhere in the frame\" — this head's own colour is
made of them."
  (let* ((*item-facts* nil)
         (esc (%ch 27))
         (payload (format nil "before~C[?1002l~C[?1006l~%~C[1;1Hmoved~%~C[0;90mdim~%after"
                          esc esc esc esc))
         (body (list :type "tool_result" :call-id "c" :name "bash"
                     :outcome (list :outcome "ok") :payload payload))
         (lines (item-lines (list :item-id "p1" :kind "tool_result" :item body)
                            100 (list :show-tools t)))
         (drawn (%draw-segs lines :cols 100))
         (segs (segs-of lines)))
    (dolist (bad '("[?1002" "[?1006" "[?1049" "[?2004" "[1;1H"))
      (let ((seq (format nil "~C~a" esc bad)))
        (is (not (search seq drawn))
            (format nil "a payload's ESC~a reached a drawn cell" bad))
        ;; and it never even reaches the segment: sanitised at render, which is
        ;; where the record stops being the record and starts being a screen
        (is (not (search seq segs))
            (format nil "a payload's ESC~a survived into a segment" bad))))
    ;; And the text itself survives, which is the point of showing it at all.
    (is (search "before" segs) "the words before the escape")
    (is (search "moved" segs) "the words after a cursor move")
    (is (search "after" segs) "and the last line")))

(def-test a-control-character-in-a-payload-costs-a-column (:suite leticl)
  "Gap 28. The painter drops an escape-only cluster, so an unsanitised
`ESC[?1002l` measured ZERO columns here and eight there — and every wrap and
truncation downstream of the row then disagreed with the reference's. A SPACE
per control character is what `without_control` leaves behind, so the columns
agree again."
  (let ((esc (%ch 27)))
    (is (equal "a  b" (leticl::%without-control (format nil "a~C~Cb" esc (%ch 7))))
        "two control characters, two spaces")
    (is (= 8 (string-width (leticl::%without-control (format nil "~C[?1002l" esc))))
        "a mode string is eight columns of spaces, as the reference measures it")
    (is (equal "plain" (leticl::%without-control "plain")) "and prose is untouched")))

(def-test an-envelope-line-is-matched-by-its-whole-shape (:suite leticl)
  "`is_envelope` (app.rs:7925-7928) is `<<<` AND `>>>` AND longer than six. Ours
tested the opening alone, so a payload line that merely begins `<<<` — a
heredoc, a conflict marker, a model quoting this very format — was dropped from
the output with nothing to say it had been."
  (is (leticl::%envelope-line-p "<<<TOOL_ERROR 5ebfdef6>>>") "a real marker")
  (is (leticl::%envelope-line-p "  <<<END_OK abc>>>  ") "trimmed first")
  (is (not (leticl::%envelope-line-p "<<<EOF")) "an opening alone is content")
  (is (not (leticl::%envelope-line-p "<<<<<<< HEAD")) "and so is a conflict marker")
  (is (not (leticl::%envelope-line-p "<<<>>>")) "six characters is no envelope")
  (let* ((*item-facts* nil)
         (body (list :type "tool_result" :call-id "c" :name "bash"
                     :outcome (list :outcome "ok")
                     :payload (format nil "<<<EOF~%body")))
         (lines (item-lines (list :item-id "e1" :kind "tool_result" :item body)
                            80 (list :show-tools t))))
    (is (search "<<<EOF" (segs-of lines)) "and it survives onto the screen")))

(def-test two-spellings-of-one-style-are-one-style (:suite leticl)
  "Gap 29. `'(:fg :red :bold t)` and `'(:bold t :fg :red)` are the same
rendition and interned at two indices with two different escapes —
`ESC[0;31;1m` against `ESC[0;1;31m`. Both spellings are in the tree today
(`src/chrome.lisp:271,329` against `src/cards.lisp:1065`), so a row drawn by one
and repainted by the other emitted a style change where nothing had changed."
  (is (= (leticl::style-index '(:fg :red :bold t))
         (leticl::style-index '(:bold t :fg :red)))
      "one index")
  (is (equal (leticl::%sgr (leticl::style-index '(:fg :red :bold t)))
             (leticl::%sgr (leticl::style-index '(:bold t :fg :red))))
      "and one escape")
  (is (= 0 (leticl::style-index '(:bold nil)))
      "an attribute that is off is no attribute, not a second way of being plain")
  (is (= (leticl::style-index '(:dim t))
         (leticl::style-index '(:dim t :dim t)))
      "and a doubled key is the key once — `appendf-attr` writes these")
  (is (equal '(:bold t :dim t :italic t :fg :cyan)
             (leticl::%canonical-style '(:fg :cyan :italic t :dim t :bold t)))
      "the canonical order is the order the escape is emitted in"))

(def-test a-zwj-does-not-swallow-the-control-after-it (:suite leticl)
  "Gap 30. The cluster rules are tried in an ORDER and ours had the ZWJ test
before the zero-width one, inverting `width.rs:116` against `:134`. So a ZWJ
immediately followed by a C0 byte absorbed the control — and absorbing a
newline hides a row break inside a cell, which is the exact defect the
zero-width branch's own comment exists to name."
  (let* ((zwj (%ch #x200d))
         (s (format nil "a~C~Cb" zwj (%ch 10))))
    (is (= 3 (length (clusters s)))
        "`a` + ZWJ, then the newline, then `b` — the control is its own cluster")
    (is (= 2 (string-width s))
        "and the one-pass walker agrees with the cluster walk")
    (is (= (string-width s)
           (reduce #'+ (mapcar #'cluster-cols (clusters s))))
        "which is the invariant `string-width-agrees-with-clusters` holds")))

;;; ------------------------------------------------- the transcript row ;;;

(def-test a-path-subject-is-cut-at-a-separator (:suite leticl)
  "Gap 3. `ellipsise_left` (app.rs:9074-9109) drops WHOLE segments, so what is
left is a real path. Ours cut at a character index — `…/1f0655c6-…/scratchpad`
was the operator's example, *\"two lies in twenty-two columns\"*: the first
ellipsis says a prefix went, which is true, and the second says a directory has
a shorter name than it does, which is not. Neither half can be pasted back into
a shell. On a non-ASCII path a character count also overshoots the budget.

The two cases below are the reference's own, measured at the widths it measured
them at."
  (let ((p "/home/dead/Projects/leticl/.claude/worktrees/agent-a19da2/crates/tui"))
    (let ((cut (leticl::%shorten-subject p 24)))
      (is (<= (string-width cut) 24) "inside the budget it was given")
      (is (char= #\… (char cut 0)) "eaten from the left")
      (is (char= #\/ (char cut 1)) "and at a SEPARATOR, so what is left is a path")
      (is (search "crates/tui" cut) "keeping the end, which is what names it")))
  ;; a glob is prose: read from the start, cut from the right
  (let* ((glob "**/*.{md,json,toml,yaml,yml} 40")
         (cut (leticl::%shorten-subject glob 20)))
    (is (<= (string-width cut) 20) "inside the budget")
    (is (eql 0 (search "**/*.{md" cut))
        "the front is kept: left-cutting a glob throws away the fact that it IS one")
    (is (char= #\… (char cut (1- (length cut)))) "and the elision is marked"))
  ;; and the budget is COLUMNS, which is where the character count overshot
  (let* ((wide (format nil "/~C~C~C/~C~C~C/end" (%ch #x4e2d) (%ch #x6587) (%ch #x5b57)
                       (%ch #x4e2d) (%ch #x6587) (%ch #x5b57)))
         (cut (leticl::%shorten-subject wide 10)))
    (is (<= (string-width cut) 10)
        "a CJK path does not overshoot: the walk counts columns, not characters"))
  ;; a single segment with no separator to cut on still fits
  (let ((cut (leticl::%shorten-subject "/averyveryverylongsinglesegmentname" 10)))
    (is (<= (string-width cut) 10) "no separator to cut on, so the characters are all there is")
    (is (char= #\… (char cut 0)) "still marked")))

(def-test a-call-with-no-result-says-it-has-no-result (:suite leticl)
  "Gap 4. `→ {verb} {target} · no result`, the whole row in `Role::Attention`
(app.rs:9614-9645). Ours drew `  → ` dim, the verb dim, the target plain, no
tag, no `Attention`, a hard-coded two-column indent and no truncation. The
reference's note is that this row's ONLY meaning is \"asked for, nothing came
back\" — *\"a row that looks like every other tool row and quietly has no output
is the shape a person reads straight past.\"*"
  (let* ((*answered-calls* nil)
         (*call-targets* nil)
         (body (list :type "assistant" :text ""
                     :tool-calls (list (list :id "c1" :name "read"
                                             :arguments "{\"path\":\"src/cards.lisp\"}"))))
         (line (first (item-lines (list :item-id "a1" :kind "assistant" :item body)
                                  80 nil))))
    (is (equal (list (cons "  " nil)
                     (cons "→ Read src/cards.lisp · no result" '(:bold t :fg :yellow)))
               line)
        "the whole line in Attention, stepped in by the activity indent")
    ;; below sixty columns the step is given up, and this row went with it
    (let ((narrow (first (item-lines (list :item-id "a1" :kind "assistant" :item body)
                                     50 nil))))
      (is (equal "" (car (first narrow))) "no indent at 50 columns")))
  ;; an empty target earns the call id its columns: it is then the only thing
  ;; distinguishing two calls to the same tool
  (let* ((*answered-calls* nil)
         (body (list :type "assistant" :text ""
                     :tool-calls (list (list :id "c7" :name "bash" :arguments ""))))
         (line (first (item-lines (list :item-id "a2" :kind "assistant" :item body)
                                  80 nil))))
    (is (search "(c7)" (segs-of (list line))) "the id, when there is nothing better"))
  ;; and it is trimmed to the width like every other row
  (let* ((*answered-calls* nil)
         (body (list :type "assistant" :text ""
                     :tool-calls (list (list :id "c1" :name "read"
                                             :arguments
                                             (format nil "{\"path\":\"~a\"}"
                                                     (make-string 200 :initial-element #\x))))))
         (line (first (item-lines (list :item-id "a3" :kind "assistant" :item body)
                                  40 nil))))
    (is (<= (leticl::%segs-width line) 40) "never past the width it was given")))

(def-test a-segment-boundary-is-a-row (:suite leticl)
  "Gap 5. `SegmentMark` → `dim(\"─── {label} ───\")` (app.rs:10042-10044). The
`case` had no arm for it, so a `/compact` boundary — the one place in a
transcript where the model's memory of everything above it changed — drew
nothing at all."
  (let ((lines (item-lines (list :item-id "m1" :kind "segment_mark"
                                 :item (list :type "segment_mark" :segment-id "s"
                                             :label "compacted" :kind "compact"
                                             :edge "open"))
                           80 nil)))
    (is (equal (list (list (cons "─── compacted ───" '(:dim t)))) lines)
        "one dim row, and it is the label between two rules")))

(def-test a-row-whose-body-has-not-arrived-draws-nothing (:suite leticl)
  "Gap 6. app.rs:9525-9542. This drew `[{kind} — content not loaded]` in RED,
one row per announcement. A `/reseat` publishes an announcement for every item
before a single body follows, so the operator got thousands at once — *\"i again
so insane amount of grainess with s- and whatever tool lines\"*. A screen full
of identical placeholders is not a diagnostic, it is noise with the shape of
one, and both callers drop a render with no lines."
  (is (null (item-lines (list :item-id "x" :kind "tool_result" :item nil) 80 nil))
      "no body, no rows")
  (is (null (item-lines (list :item-id "x" :kind "assistant") 80 nil))
      "and the same when the key is absent rather than null"))

(def-test a-screen-that-came-with-a-message-is-replaced-by-a-note (:suite leticl)
  "Gap 8. `fold_cells` (app.rs:8980-9001) REPLACES the block with
`· {rows} rows of this screen ({size}) went with this message`. Ours kept the
operator's words, kept the marker head, appended ` …`, and kept whatever
followed the close marker — a different string, a different shape, and text the
reference drops. Redrawing sixty rows of somebody else's terminal inside this
one is a picture of a picture."
  (let* ((text (format nil "~a~%~a210x63 — the sentence~a~%row one~%row two~%row three~%~a~%tail"
                       "look at this" leticl::*cells-open* leticl::*cells-mark-end*
                       leticl::*cells-close*))
         (folded (leticl::%fold-cells text)))
    (is (equal (format nil "look at this~%· 3 rows of this screen (210x63) went with this message")
               folded)
        "the words, then one line naming what went with them — and the tail is gone")
    (is (not (search leticl::*cells-open* folded)) "no marker survives"))
  ;; a message that is ONLY a screen is only the note
  (let ((folded (leticl::%fold-cells
                 (format nil "~a80x24 — s~a~%r~%~a~%"
                         leticl::*cells-open* leticl::*cells-mark-end*
                         leticl::*cells-close*))))
    (is (equal "· 1 rows of this screen (80x24) went with this message" folded)))
  (is (equal "no screen here" (leticl::%fold-cells "no screen here"))
      "and a message with no screen in it is untouched"))

(def-test a-users-parts-are-joined-and-the-rest-are-named (:suite leticl)
  "Gap 10. app.rs:8550-8558 joins the parts with a SPACE and names the others —
`[image {media_type}]`, `[file {path}]`. Ours concatenated the text parts, so a
two-part message ran its parts together into a word that is in neither of them,
and rendered every non-text part as the empty string: an attached image was
invisible on the row that attached it."
  (let ((body (list :type "user"
                    :parts (list (list :kind "text" :text "look at")
                                 (list :kind "text" :text "this")))))
    (is (equal "look at this" (leticl::%user-parts-text body))
        "joined with a space, not run together"))
  (let ((body (list :type "user"
                    :parts (list (list :kind "text" :text "what is wrong with")
                                 (list :kind "image" :media-type "image/png"
                                       :data-ref "r1")
                                 (list :kind "file_ref" :path "src/cards.lisp"
                                       :sha256 "abc")))))
    (is (equal "what is wrong with [image image/png] [file src/cards.lisp]"
               (leticl::%user-parts-text body))
        "and an attachment is named where it sat")
    (is (search "[image image/png]"
                (segs-of (item-lines (list :item-id "u1" :kind "user" :item body :ts 0)
                                     80 nil)))
        "which is what reaches the screen")))

(def-test a-system-row-names-its-origin-and-is-dim (:suite leticl)
  "Gap 11. `dim(\"system ({origin:?})\")` and then the text, every line dim
(app.rs:9544-9548). Ours drew `◦ ` and the text in YELLOW and no origin at all —
and the origin is the fact: the prompt a session opened with and a later change
to it are different events, and only the second means somebody reconfigured the
model mid-conversation. Yellow is `Pending`, which says something is happening;
a system row is the quietest thing in a transcript."
  (let ((lines (item-lines (list :item-id "s1" :kind "system"
                                 :item (list :type "system" :text "tools were changed"
                                             :origin "update"))
                           80 nil)))
    (is (equal (cons "system (Update)" '(:dim t)) (first (first lines)))
        "the origin on its own line, dim")
    (is (search "tools were changed" (segs-of lines)) "then the text")
    (is (every (lambda (l) (every (lambda (seg) (equal '(:dim t) (cdr seg))) l)) lines)
        "and every segment of every row is dim — nothing here is yellow")))

(def-test a-failed-turns-reason-is-wrapped-not-cut (:suite leticl)
  "Gap 13. app.rs:8232-8245 wraps a `Failed` footer at `cfg.width`; ours declared
`cols` ignored and emitted one line. The rule was already written in the
function's own docstring — *\"wrapped rather than truncated, because the reason
is the whole content of the event\"* — and the code did the opposite, so a long
provider error was cut at the frame's edge."
  (let* ((err (format nil "~{~a~^ ~}" (loop repeat 40 collect "reason")))
         (lines (turn-footer-lines
                 (list :turn-id "t" :state (list :state "failed" :error err
                                                 :partial-kept nil))
                 60)))
    (is (> (length lines) 1) "more than one row at sixty columns")
    (is (every (lambda (l) (<= (leticl::%segs-width l) 60)) lines) "none of them over the width")
    (is (search "reason reason" (segs-of lines)) "and the reason is all there")
    (is (every (lambda (l) (every (lambda (seg) (equal '(:fg :red :bold t) (cdr seg))) l)) lines)
        "every row in the failure register, not just the first")))

(def-test a-queued-prompt-takes-the-shape-of-the-row-it-becomes (:suite leticl)
  "Gap 14. `queued_lines` (app.rs:9017-9046): `▌` in `UserAccent`, the tag
`queued · ` in `Role::Pending` where the timestamp goes, the text `Faint`, and
continuation rows indented by `width(\"queued\") + 3`. Ours drew a bright-cyan
`›`, put the tag at the END, and showed only the FIRST line — so a pasted
paragraph queued as one sentence and grew into a block when the boundary landed,
which reads as the head having changed what was sent."
  (let ((h (%make-head)))
    (setf (head-queued h) (list (format nil "~{~a~^ ~}" (loop repeat 30 collect "word"))))
    (let ((lines (queued-lines h 40)))
      (is (equal (cons "▌ " '(:fg :blue)) (first (first lines))) "the bar, UserAccent")
      (is (equal (cons "queued · " '(:fg :yellow)) (second (first lines)))
          "the tag where the timestamp goes, in Pending")
      (is (equal '(:dim t) (cdr (third (first lines)))) "the words faint")
      (is (> (length lines) 1) "and a long prompt is WRAPPED, not cut to its first line")
      (is (equal "         " (car (second (second lines))))
          "continuations hang under the text, by the tag's own columns")
      (is (every (lambda (l) (<= (leticl::%segs-width l) 40)) lines)
          "and nothing exceeds the width"))))

(def-test attention-is-not-pending (:suite leticl)
  "Gap 23. `Role::Attention` is `ESC[1;33m` and `Role::Pending` is `ESC[33m`,
kept apart on purpose (style.rs:174,180, pinned there by a test): \"needs a
person\" and \"is happening\" are close enough that a WEIGHT is the right
distinction, and the cube's orange is not a slot any theme defines. Ours folded
them together — abstained and denied were plain yellow, backgrounded was
`Code`'s cyan — so §8.2's rule about abstention had no display to stand on."
  (is (string= (format nil "~C[0;1;33m" (%ch 27))
               (leticl::%sgr (leticl::style-index leticl::+role-attention+)))
      "Attention is bold yellow")
  (is (string= (format nil "~C[0;33m" (%ch 27))
               (leticl::%sgr (leticl::style-index leticl::+role-pending+)))
      "Pending is plain yellow")
  (is (not (equal leticl::+role-attention+ leticl::+role-pending+)) "and they are two roles")
  ;; the outcomes the reference maps onto each
  (dolist (word '("abstained" "denied" "backgrounded"))
    (is (equal leticl::+role-attention+ (leticl::%outcome-style (list :outcome word)))
        (format nil "~a needs a person, so it is Attention" word)))
  (dolist (word '("failed" "timeout" "not_run"))
    (is (equal leticl::+role-failure+ (leticl::%outcome-style (list :outcome word)))
        (format nil "~a is Failure — `display_outcome` maps it onto Failed" word)))
  (is (equal leticl::+role-success+ (leticl::%outcome-style (list :outcome "ok")))))

(def-test a-decision-says-what-it-was-grounded-in (:suite leticl)
  "Gap 9. `decision_detail` (app.rs:9462-9507) is five parts and we drew one.
The two that carry the obligation: *\"empty cites is loud\"* — an authorisation
the oracle could not ground in anything the operator said is a different fact
from one grounded in four utterances — and `no oracle was consulted for this
one`, because \"no oracle was asked\" and \"an oracle was asked and said
nothing\" are different and a blank reads as the second."
  (let ((d (list :summary "run `rm -rf build`"
                 :outcome (list :option-id "allow_once")
                 :by (list :kind "operator" :identity "dead")
                 :basis "dead chose `allow_once` at the head")))
    (let ((lines (leticl::%decision-detail d 200)))
      (is (equal "asked: run `rm -rf build`" (first lines)) "what was asked")
      (is (equal "operator: dead chose `allow_once` at the head" (second lines))
          "named by the DECIDER's own kind, so `decided:` never stands in for a model")
      (is (equal "no oracle was consulted for this one" (third lines))
          "said out loud rather than left blank"))
    ;; an oracle that was asked and grounded its answer in nothing
    (let* ((with-advice (append d (list :advice (list :by "guard" :latency-ms 40
                                                      :would "admit" :basis "it is a build dir"
                                                      :cites nil))))
           (lines (leticl::%decision-detail with-advice 200)))
      (is (search "oracle (guard, 40ms) would admit: it is a build dir" (format nil "~{~a~%~}" lines))
          "the oracle's own verdict, separate from the decider's basis")
      (is (member "oracle cited: nothing — it could not ground this in anything you said"
                  lines :test #'equal)
          "and the emptiness is RENDERED, not the absence of a list"))
    (let* ((cited (append d (list :advice (list :by "guard" :latency-ms 40
                                                :would "admit" :basis "b"
                                                :cites (list "you said build/ is disposable")))))
           (lines (leticl::%decision-detail cited 200)))
      (is (member "oracle cited: you said build/ is disposable" lines :test #'equal)
          "one line per citation"))
    ;; ours, and the reference has no counterpart: the decider's line is dropped
    ;; when the payload below already carries it — *"how many times is 'nothing
    ;; ran' needed?"*
    (let ((lines (leticl::%decision-detail d 200 :skip-basis t)))
      (is (not (find-if (lambda (l) (search "operator:" l)) lines))
          "the decider's line goes")
      (is (member "no oracle was consulted for this one" lines :test #'equal)
          "and the oracle's do not, because they are nowhere else")))
  ;; and it reaches the open settled row
  (let* ((*item-facts* (list (cons "d1" (list :decision
                                              (list :summary "run it"
                                                    :outcome (list :option-id "allow_once")
                                                    :by (list :kind "operator" :identity "dead")
                                                    :basis "because")))))
         (body (list :type "tool_result" :call-id "c" :name "bash"
                     :outcome (list :outcome "ok") :payload "done"))
         (text (segs-of (item-lines (list :item-id "d1" :kind "tool_result" :item body)
                                    80 (list :show-tools t)))))
    (is (search "· allowed, by operator dead" text) "the folded line stays")
    (is (search "asked: run it" text) "and the detail is under it when the tools are open")
    (is (search "no oracle was consulted" text) "including the one that says nobody was asked")))

(def-test a-live-card-discloses-its-bytes-its-decision-and-its-budget (:suite leticl)
  "Gap 12. Three of the live card's four body parts were absent.

The §8.3 bytes disclosure (app.rs:8767-8780) is the one with an obligation
attached, and it lives in the BODY rather than the header tail because a header
tail is dropped whole when it does not fit — \"there is more, and here is how to
get it\" is not a line that may vanish on a narrow terminal.

The decision block (app.rs:8842-8864) was on the settled row and not here, so
the one moment a person can still act on an approval was the one moment it was
not shown.

`head_tail` with `Budget::for_verb` (card.rs:482-511) is what stops a folded
card filling the screen: a live `edit` with a sixty-row diff drew all sixty rows
here and fourteen there."
  (let* ((*call-facts* nil)
         (call (list :call-id "c1" :name "bash" :target "ls"
                     :state (list :state "finished" :outcome (list :outcome "ok")
                                  :inline-bytes 512)))
         (text (segs-of (call-lines call 80 nil))))
    (is (search "512 B" text) "a finished call says how much went to the model"))
  ;; spilled: how much went, how much there was, and the handle for the rest
  (let* ((*call-facts* nil)
         (call (list :call-id "c1" :name "bash" :target "ls"
                     :state (list :state "finished" :outcome (list :outcome "ok")
                                  :inline-bytes 1024 :full-bytes 1048576
                                  :spill "deadbeef")))
         (text (segs-of (call-lines call 200 nil))))
    (is (search "1.0 KB of 1.0 MB went to the model, the rest is kept — read_spill hash=deadbeef"
                text)
        "the whole sentence, in units a person reads"))
  ;; the decision the call was gated by, on the card that can still be acted on
  (let* ((*call-facts* (list (cons "c1" (list :decision
                                              (list :summary "run it"
                                                    :outcome (list :option-id "deny")
                                                    :by (list :kind "policy")
                                                    :basis "outside the boundary")))))
         (call (list :call-id "c1" :name "bash" :target "ls"
                     :state (list :state "running")))
         (text (segs-of (call-lines call 80 (list :show-tools t)))))
    (is (search "· refused, by policy" text) "who decided and how")
    (is (search "policy: outside the boundary" text) "and, open, what it was grounded in"))
  ;; the budget: a shell verb keeps two rows of head and three of tail
  (let* ((*call-facts* nil)
         (body (loop for i from 1 to 60 collect (format nil "line ~d" i)))
         (rows (leticl::head-tail-lines
                (mapcar (lambda (l) (list (cons l nil))) body) 2 3)))
    (is (= 6 (length rows)) "two, a marker, three")
    (is (equal (cons "… +55 lines" '(:dim t)) (first (third rows)))
        "and the marker is a separator row that says how many went, never a silent cut")
    (is (equal "line 60" (car (first (car (last rows))))) "the tail is the end"))
  (is (equal '(5 . 3) (leticl::%budget-for-verb "read")) "Read: enough head to see what it is")
  (is (equal '(5 . 3) (leticl::%budget-for-verb "ls")) "List with it")
  (is (equal '(2 . 3) (leticl::%budget-for-verb "bash")) "a shell command's tail is what matters")
  (is (equal '(10 . 3) (leticl::%budget-for-verb "some_unknown_tool")) "anything else")
  ;; and a short body is not touched
  (let ((rows (list (list (cons "a" nil)) (list (cons "b" nil)))))
    (is (equal rows (leticl::head-tail-lines rows 5 3))
        "nothing is hidden when nothing needs to be")))

;;; ------------------------------------------------- the markdown lexer ;;;

(def-test emphasis-markers-never-reach-the-screen (:suite leticl)
  "M1. `***both***` is ONE BoldItalic run (markdown.rs:1947-1956). Ours let the
`**` rule take two of the three asterisks and printed the third — and a marker
on the screen is the one failure this whole surface exists to remove."
  (is (equal (list (cons "both" '(:bold t :italic t))) (inline-spans "***both***"))
      "three asterisks, one run, no marker")
  (is (equal (list (cons "both" '(:bold t :italic t))) (inline-spans "___both___"))
      "and the underscore spelling")
  (let ((segs (inline-spans "**bold *and italic***")))
    (is (not (find #\* (format nil "~{~a~}" (mapcar #'car segs))))
        "a run longer than the delimiter closes at its END, so no asterisk is left over")
    (is (equal (cons "bold " '(:bold t)) (first segs)))
    (is (equal (cons "and italic" '(:bold t :italic t)) (second segs))
        "and the inner italic nests rather than becoming a second marker"))
  ;; the guards that were already right stay right
  (is (equal (list (cons "2 * 3 = 6" nil)) (inline-spans "2 * 3 = 6"))
      "a star that is not emphasis stays literal"))

(def-test an-autolink-is-its-url (:suite leticl)
  "M7. `<https://x>` is what a model writes for a bare URL (markdown.rs:599-608);
`<` and `>` were ordinary characters here, so the brackets reached the screen."
  (is (equal (list (cons "https://x" nil)) (inline-spans "<https://x>")) "a URL")
  (is (equal (list (cons "a@b.c" nil)) (inline-spans "<a@b.c>")) "an email")
  (is (equal (list (cons "a " nil) (cons "https://x/y?z=1" nil) (cons " b" nil))
             (inline-spans "a <https://x/y?z=1> b"))
      "in the middle of a sentence")
  ;; and a `<` that is not an autolink is still a `<`
  (is (equal (list (cons "a < b and 3 > 2" nil)) (inline-spans "a < b and 3 > 2"))
      "arithmetic is not markup")
  (is (equal (list (cons "<Generic>" nil)) (inline-spans "<Generic>"))
      "nor is a type parameter")
  ;; an image is its alt text, not `!alt`
  (is (equal (list (cons "a diagram" nil)) (inline-spans "![a diagram](x.png)"))
      "an image is its alt text"))

(def-test a-fence-cannot-be-closed-by-a-shorter-one (:suite leticl)
  "M3. A closing fence must be at least as long as the opener
(markdown.rs:819-834). Four backticks is how a model quotes a fence when it is
TEACHING, and any run of three closed anything here — so the demonstration was
cut in half and the rest spilled out as prose."
  (let ((blocks (leticl::markdown-blocks (format nil "````~%```rust~%let a = 1;~%```~%````"))))
    (is (= 1 (length blocks)) "one block, not three")
    (is (eq :code (getf (first blocks) :kind)))
    (is (equal '("```rust" "let a = 1;" "```") (getf (first blocks) :lines))
        "the inner fence is CONTENT of the outer one")
    (is (getf (first blocks) :closed) "and the outer one closed"))
  ;; `~~~` is a fence opener too
  (let ((blocks (leticl::markdown-blocks (format nil "~apython~%x = 1~%~a" "~~~" "~~~"))))
    (is (eq :code (getf (first blocks) :kind)) "a tilde fence is a fence")
    (is (equal '("x = 1") (getf (first blocks) :lines)))
    (is (equal "python" (getf (first blocks) :lang))))
  ;; and a backtick run does not close a tilde fence
  (let ((blocks (leticl::markdown-blocks (format nil "~a~%```~%~a" "~~~" "~~~"))))
    (is (equal '("```") (getf (first blocks) :lines))
        "the character has to match as well as the length"))
  ;; the rule that was already right: a line that merely ENDS in backticks is
  ;; content, which is the box art the reference keeps a test for
  (let ((blocks (leticl::markdown-blocks (format nil "```~%│ a ```~%```"))))
    (is (equal '("│ a ```") (getf (first blocks) :lines)) "box art survives")))

(def-test indented-code-is-code-and-not-mangled-prose (:suite leticl)
  "M4. A four-space indent is a code block (markdown.rs:971,1161-1177). Ours ran
it through the paragraph arm, which `string-trim`s the indent away and JOINS the
lines — so the code was not merely uncoloured, it was mangled, and indentation
is most of what code written without a fence has."
  (let ((blocks (leticl::markdown-blocks (format nil "text~%~%    def f():~%        return 1~%~%after"))))
    (is (= 3 (length blocks)) "paragraph, code, paragraph")
    (is (eq :code (getf (second blocks) :kind)))
    (is (equal '("def f():" "    return 1") (getf (second blocks) :lines))
        "four columns come off and the rest is the code's own")
    (is (equal "" (getf (second blocks) :lang)) "with no language claimed"))
  ;; a nested list item is not code: this head renders nesting by indent, and
  ;; reading `    - sub` as code would take that away
  (let ((blocks (leticl::markdown-blocks (format nil "    - sub"))))
    (is (eq :list (getf (first blocks) :kind)) "a list item keeps being one")))

(def-test a-setext-heading-is-a-heading (:suite leticl)
  "M8. `Title` over `====` is a level-one heading and over `----` a level-two one
(markdown.rs:950,993-994). Ours joined the `====` into the paragraph and drew it
as text, and read the `----` as a thematic break under a paragraph that was the
heading."
  (let ((blocks (leticl::markdown-blocks (format nil "Title~%===="))))
    (is (equal '(:kind :heading :level 1 :text "Title") (first blocks))))
  (let ((blocks (leticl::markdown-blocks (format nil "Subtitle~%----"))))
    (is (equal '(:kind :heading :level 2 :text "Subtitle") (first blocks))))
  ;; a bare rule with no paragraph over it is still a rule
  (let ((blocks (leticl::markdown-blocks (format nil "a~%~%----~%~%b"))))
    (is (eq :rule (getf (second blocks) :kind)) "nothing above it, so nothing to underline")))

(def-test a-task-list-item-does-not-keep-its-checkbox (:suite leticl)
  "M8. `- [x] done` → `· done` (markdown.rs:1050-1052,1242-1244). Ours drew
`· [x] done`, which is a marker on the screen with a bullet already beside it."
  (let ((blocks (leticl::markdown-blocks (format nil "- [ ] open~%- [x] done~%- [X] also"))))
    (is (equal '("open" "done" "also")
               (mapcar (lambda (it) (getf it :text)) (getf (first blocks) :items))))))

(def-test an-ordered-list-counts-up-from-its-own-start (:suite leticl)
  "M5. `start + i` (render.rs:408-414). `1. / 1. / 1.` is very common model
output and rendered as three `1.`s — numbers that refer to nothing, when a
number in an ordered list is exactly what the prose refers back to.

And a loose list is ONE block (markdown.rs:2016-2040): a blank line between
items closed the list here, so a six-point answer came out N blocks with N−1
blank rows between them, twice the height of the reference's."
  (let ((lines (markdown-lines (format nil "1. one~%1. two~%1. three") :width 80)))
    (is (equal '("1. " "2. " "3. ") (mapcar (lambda (l) (car (first l))) lines))
        "counted up, not repeated"))
  (let ((lines (markdown-lines (format nil "4. four~%4. five") :width 80)))
    (is (equal '("4. " "5. ") (mapcar (lambda (l) (car (first l))) lines))
        "from the number the model wrote first"))
  (let ((lines (markdown-lines (format nil "1. one~%~%2. two~%~%3. three") :width 80)))
    (is (= 3 (length lines)) "a loose list is one block: three rows, no blanks between")
    (is (equal '("1. " "2. " "3. ") (mapcar (lambda (l) (car (first l))) lines))
        "and the numbering runs across the blanks"))
  ;; …but only for another item of the SAME kind. A bullet list under an ordered
  ;; one is a second list, and swallowing the blank between them renumbers the
  ;; bullets into it.
  (let ((blocks (leticl::markdown-blocks (format nil "- a~%- b~%~%1. one~%2. two"))))
    (is (= 2 (length blocks)) "two lists, not one")
    (is (not (getf (first (getf (first blocks) :items)) :ordered)))
    (is (getf (first (getf (second blocks) :items)) :ordered)))
  (let ((lines (markdown-lines (format nil "- a~%~%1. one") :width 80)))
    (is (= 3 (length lines)) "and the blank row between them survives")
    (is (null (second lines)))))

(def-test a-fence-inside-a-quote-is-a-code-box (:suite leticl)
  "M2. `%fence-at` never fired on a `>` line, so a fence inside a quote rendered
as quote prose with literal backticks in it — which is exactly what
`split_container` exists for (markdown.rs:713-747,842-860)."
  (let ((blocks (leticl::markdown-blocks (format nil "> ```rust~%> let a = 1;~%> ```"))))
    (is (= 1 (length blocks)) "no empty quote left behind")
    (is (eq :code (getf (first blocks) :kind)))
    (is (equal "rust" (getf (first blocks) :lang)))
    (is (equal '("let a = 1;") (getf (first blocks) :lines)))
    (is (getf (first blocks) :closed))
    (is (not (find-if (lambda (l) (find #\> l)) (getf (first blocks) :lines)))
        "and the quote marker is gone from the code"))
  ;; a fence ON a list marker's line is a code box, not item text
  (dolist (src (list (format nil "- ```rust~%  let a = 1;~%  ```")
                     (format nil "1. ```rust~%   let a = 1;~%   ```")))
    (let ((blocks (leticl::markdown-blocks src)))
      (is (= 1 (length blocks)) "one block")
      (is (eq :code (getf (first blocks) :kind)) "and it is code, not item text")
      (is (equal "rust" (getf (first blocks) :lang)))
      (is (equal '("let a = 1;") (getf (first blocks) :lines))
          "the marker's columns are the container's, not the code's")))
  ;; a fence INSIDE an item keeps the code's own indentation and loses the
  ;; item's — `stripping_a_content_column_does_not_eat_content`
  (let* ((blocks (leticl::markdown-blocks (format nil "- item~%~%  ```rust~%  if x {~%      y~%  }~%  ```")))
         (code (find :code blocks :key (lambda (b) (getf b :kind)))))
    (is (equal '("if x {" "    y" "}") (getf code :lines))
        "two columns of container indent come off; the four the code wrote stay")))

(def-test a-table-inside-a-quote-keeps-its-cells-and-not-its-pipes (:suite leticl)
  "M12. The pipes survived into the quote text (markdown.rs:1063-1081). A quote
is a CONTAINER: its content is lexed like any other text and flattened back to
the lines the rail carries."
  (let ((blocks (leticl::markdown-blocks (format nil "> | a | b |~%> |---|---|~%> | 1 | 2 |"))))
    (is (eq :quote (getf (first blocks) :kind)))
    (is (member "1 2" (getf (first blocks) :lines) :test #'equal) "the row survives")
    (is (not (find-if (lambda (l) (find #\| l)) (getf (first blocks) :lines)))
        "and no pipe does"))
  ;; a list inside a quote loses its markers the same way
  (let ((blocks (leticl::markdown-blocks (format nil "> - one~%> - two"))))
    (is (equal '("one" "two") (getf (first blocks) :lines))
        "the words, without the bullets the rail already stands in for"))
  ;; and a plain quote is unchanged
  (let ((blocks (leticl::markdown-blocks (format nil "> a~%> b"))))
    (is (equal '("a" "b") (getf (first blocks) :lines)))))

(def-test a-fence-header-names-the-grammar-that-ran (:suite leticl)
  "M9. `render.rs:296-298,375-379`: a recognised fence is named by the grammar
that actually coloured it, so the header cannot claim one language over a fence
parsed as another. Ours printed the raw info string, so `sh`, `shell`, `bash`
and `zsh` — the same grammar — read as four different boxes."
  (is (equal "┌─ bash" (car (first (first (markdown-lines (format nil "```sh~%ls~%```") :width 80)))))
      "`sh` is bash")
  (is (equal "┌─ rust" (car (first (first (markdown-lines (format nil "```rs~%x~%```") :width 80)))))
      "`rs` is rust")
  (is (equal "┌─ typescript"
             (car (first (first (markdown-lines (format nil "```ts~%x~%```") :width 80)))))
      "`ts` is typescript")
  ;; a language nobody can colour keeps the name the model wrote: naming a
  ;; language we are not colouring is honest, inventing one we are is not
  (is (equal "┌─ brainfuck"
             (car (first (first (markdown-lines (format nil "```brainfuck~%+~%```") :width 80)))))
      "an unknown name is printed as written")
  (is (equal "┌─ code" (car (first (first (markdown-lines (format nil "```~%x~%```") :width 80)))))
      "and a bare fence is `code`"))

(def-test a-bounded-blocks-title-is-its-text-and-not-its-source (:suite leticl)
  "M10. `Block::title` is `runs_text` — the markers are already gone
(markdown.rs:184-199). Ours returned the raw source, so the one row standing in
for a block nobody can see showed `**markers**`.

And the truncation is `trim_to(title, w)` and THEN `▸ ` (render.rs:631): the row
may be `w + 2`, because those two columns belong to the affordance rather than
to the name. Truncating the whole string took two characters off the title
instead."
  (let* ((text (format nil "~{~a~^~%~}"
                       (cons "- **The measurement** and what it showed"
                             (loop for i from 1 to 30 collect (format nil "- line ~d" i)))))
         (lines (markdown-lines text :width 80 :limit 10)))
    (is (equal "▸ The measurement and what it showed" (car (first (first lines))))
        "the title with its markers consumed"))
  ;; the fence title names the grammar too
  (let* ((text (format nil "```sh~%~{~a~%~}```"
                       (loop for i from 1 to 30 collect (format nil "echo ~d" i))))
         (lines (markdown-lines text :width 80 :limit 6)))
    (is (search "▸ bash · 30 lines" (car (first (first lines))))
        "and says which grammar and how many lines"))
  ;; `▸ ` is outside the budget, so the title itself gets the whole width
  (let* ((title (make-string 40 :initial-element #\t))
         (text (format nil "~a~%~{~a~%~}" title
                       (loop for i from 1 to 30 collect (format nil "line ~d" i))))
         (row (car (first (first (markdown-lines text :width 20 :limit 6))))))
    (is (= 20 (string-width (subseq row 2)))
        "the title is trimmed to the width, and the mark is added after")))

(def-test a-table-row-does-not-end-in-a-space (:suite leticl)
  "M11. `row.trim_end()` over the WHOLE row (render.rs:528). Ours trimmed the
last segment only, so a row whose last cell is empty kept the padded blank AND
the ` │ ` separator before it — invisible until copied, and the reference
explicitly fixed exactly this."
  (let ((lines (markdown-lines (format nil "| a | b |~%|---|---|~%| 1 | |") :width 80)))
    (is (every (lambda (l) (let ((s (segs-of (list l))))
                             (string= s (string-right-trim " " s))))
               lines)
        "no row ends in whitespace")
    (let ((row (segs-of (last lines))))
      (is (eql (1- (length row)) (search "│" row :from-end t))
          "a row whose last cell is empty ends AT the separator — the padded blank
after it and the separator's own trailing space are both gone, which is what
trimming one segment could not do"))))

(def-test a-user-row-says-what-was-attached (:suite leticl)
  "`item-display-text` joined a user message's parts with NOTHING, so two parts
ran into one word — and an image or a file attachment was invisible: the operator
sent something and the row showed no sign of it. The reference names each part
(`app.rs:8489-8497`); the rendering was fixed with it, this is the text the panes
and the search read."
  (let ((item (list :item-id "u1" :kind "user"
                    :item (list :type "user"
                                :parts (list (list :kind "text" :text "look at")
                                             (list :kind "image" :media-type "image/png")
                                             (list :kind "file_ref" :path "src/f.lisp")
                                             (list :kind "text" :text "and say"))))))
    (is (string= "look at [image image/png] [file src/f.lisp] and say"
                 (leticl::item-display-text item))
        "each part named, joined with a space")))

(def-test the-hint-bar-does-not-move-sideways (:suite leticl)
  "**I made this worse this morning, from a stale commit.** The reference's
`hint_bar` opens with `Editor::hint`, which — at `8af671e` — returns the empty
string unless a two-tap gesture is armed (editor.rs:820-834). It used to return
`enter send · ctrl+c exit` idle and `esc interrupt · ctrl+c clear` while a turn
ran, and the reference DELETED that with its reason at app.rs:5001-5004: three
different lengths in front of one tail make the line move sideways whenever a
turn starts or the first character is typed. I read the older shape and copied
it, and the 1:1 rig found the row differing on every frame of all ten fixtures."
  (let* ((*stdout* (make-string-output-stream))
         (h (%on-head :cols 100 :rows 24))
         (text (lambda () (format nil "~{~a~}" (mapcar #'car (hint-bar h 100))))))
    (let ((idle (funcall text)))
      (is (uiop:string-prefix-p "ctrl-s sessions" idle)
          "idle, the row opens with the constant tail: ~s" idle)
      (is (not (search "enter send" idle)) "and not with the keys that change")
      ;; a turn starting must not move it
      (setf (session-turn (head-session h))
            (list :turn-id "t" :state (list :state "running")))
      (is (string= idle (funcall text)) "a turn starting moves nothing")
      ;; nor does typing
      (composer-insert (head-composer h) "half a thought")
      (is (string= idle (funcall text)) "nor does the first character"))
    ;; but an ARMED gesture still says so, which is what the reference kept
    (let ((leticl::*esc-at* (get-internal-real-time)))
      (is (uiop:string-prefix-p "esc again to interrupt" (funcall text))
          "a gesture half-made is the one thing the bottom row must say"))))

(def-test a-unix-timestamp-is-not-a-universal-time (:suite leticl)
  "Every prompt was stamped an hour early all summer. The epochs differ by
2 208 988 800 seconds — a whole number of days — so H:M:S survived the mistake
while the DATE landed in 1956, and the local offset was then taken for 1956 (CET,
no summer time) instead of 2026 (CEST). Measured against letibot on the same row:
`15:00:08` against `14:00:08`."
  (let* ((ts 1789639478000)                     ; 2026-09-17, in epoch ms
         (shown (leticl::%clock-time ts)))
    (multiple-value-bind (s m h) (decode-universal-time (+ (floor ts 1000) 2208988800))
      (is (string= (format nil "~2,'0d:~2,'0d:~2,'0d" h m s) shown)
          "the clock reads the local time of THAT instant: ~a" shown))
    (multiple-value-bind (ignore-s ignore-m ignore-h date month year)
        (decode-universal-time (+ (floor ts 1000) 2208988800))
      (declare (ignore ignore-s ignore-m ignore-h date month))
      (is (= 2026 year) "and the instant is in 2026, not 1956")))
  (is (string= "" (leticl::%clock-time nil)) "no timestamp is no time, not midnight"))

(def-test leaving-and-stopping-the-daemon-asks-and-waits-for-the-outcome (:suite leticl)
  "The operator, twice: *\"leticl is unable to properly stop the daemon so when I
exited and asked to kill the daemon too - it didnt\"*.

The first fix got the ORDER right — `Stop` has to reach the daemon while this head
is still attached, because a detach closes the socket the request travels on
(driver.rs:202-211) — and the order was never the whole of it. MEASURED against a
scratch daemon afterwards, with the head's own exit sequence byte for byte: the stop
arrives (the daemon's `daemon_stopping` warning is in the next snapshot), the daemon
publishes it, writes `Accepted` into a socket with no reader, takes `EPIPE` — and
`registry.close()` sits BEHIND that write (`sessionlog/src/server.rs:776-778`), so
it serves on. One millisecond of pause saves it: close 0 ms after the stop →
STUCK, 1 ms → gone in 221 ms. A race the head always lost, because it closed the
socket in the same breath as it asked.

So the frame's ORDER is asserted here, and then the two facts about the OUTCOME:
the head does not leave on the ask, and it records a wait — the loop's tick is what
ends it. See `a-stop-is-over-when-the-daemon-is-gone`."
  (let ((leticl::*stop-request* nil))
    (let* ((h (%make-head))
           (wire (%wire h)))
      (setf (head-quit-open h) t (leticl::head-quit-sel h) 1)
      (leticl::%handle-key h (list :type :enter))
      (let ((sent (%sent wire)))
        (is (equal "stop" (getf (first sent) :frame)) "the stop goes out")
        (is (equal "leticl" (getf (first sent) :who)) "under this head's own name"))
      (is (leticl::head-running h) "and the head does NOT leave: an ask is not an outcome")
      (is (not (null leticl::*stop-request*)) "the wait is recorded")
      (is (search "waiting for it to go" (leticl::stop-wait-text))
          "and it says what it is waiting for")))
  ;; and the first row — leave, keep the daemon — is still instant: there is no
  ;; outcome to wait for when nothing was asked. Its own binding, because the head
  ;; above set the one it was given (`setf` of a special inside a `let` writes that
  ;; binding), and this half is about a head that never asked
  (let ((leticl::*stop-request* nil))
    (let* ((h2 (%make-head))
           (wire2 (%wire h2)))
      (setf (head-quit-open h2) t (leticl::head-quit-sel h2) 0)
      (leticl::%handle-key h2 (list :type :enter))
      (is (null (remove "detach" (%sent wire2)
                        :key (lambda (f) (getf f :frame)) :test #'string=))
          "leaving this head sends no stop")
      (is (null leticl::*stop-request*) "records no wait")
      (is (not (leticl::head-running h2)) "and leaves at once"))))

;;; ------------------------------- a request is not an OUTCOME (a stop) ------- ;;;
;;;
;;; The requirement: *"when the operator chooses to stop the daemon, the head does not
;;; exit until the daemon has actually gone, or until it can say that it has not."*
;;; Three clauses, and a test each: the wait is entered and SAID; it ends when the
;;; daemon is gone; and it ends with a farewell that NAMES what is still running.

(defun %live-pid ()
  "This process's own pid — a pid that is certainly alive. `sb-unix` is in the SBCL
core, so this needs no `require` the test image does not already do."
  (sb-unix:unix-getpid))

(defun %dead-pid ()
  "A pid that cannot exist: `pid_max` is the first number the kernel never hands
out, so `/proc/<pid_max>` is absent by construction rather than by luck."
  (or (ignore-errors (parse-integer (uiop:read-file-string "/proc/sys/kernel/pid_max")))
      999999))

(defun %stop-request-for (&key socket pid (asked-ago 0) (deadline-in 5000))
  "A request plist shaped exactly as `begin-stop-request` leaves one — every key
present, including the two the tick writes through."
  (let ((now (internal-real-time-ms)))
    (list :asked-at (- now asked-ago)
          :deadline (+ now deadline-in)
          :socket socket
          :pid pid
          :heard nil
          :shown nil)))

(def-test the-wait-for-a-stopped-daemon-is-said-on-the-screen (:suite leticl)
  "**A row, not a status note.** A note expires on `*notice-ttl-frames*` ≈ 0.55 s and
the whole defect was a request whose outcome nobody ever learned; a sentence that
disappears while the wait runs is that defect with a sentence attached.

And the daemon's ANSWER is a different sentence from the ask, because it is a
different fact: `Accepted` is the daemon saying it heard, which is not the same as
the daemon being gone — and it is the second that the operator asked for."
  (let* ((leticl::*stop-request* (%stop-request-for :socket nil :pid (%live-pid)))
         (h (%on-head :cols 100 :rows 24)))
    (leticl::%render h)
    (let ((text (%screen-text h)))
      (is (search "the daemon was asked to stop" text) "the wait is on the screen")
      (is (search "waiting for it to go" text) "saying what it is waiting for")
      (is (search "of 5.0s" text) "against the deadline it is waiting on")
      (is (not (search "answered" text)) "and nothing has answered it yet"))
    (leticl::heard-stop h "stopping")
    (leticl::%render h)
    (is (search "answered \"stopping\"" (%screen-text h))
        "an answered ask says so — and still waits, because it is not gone")
    ;; the wait outranks the note: nothing may expire it
    (setf (head-status-note h) "a note that is not about this at all")
    (leticl::%render h)
    (is (not (search "a note that is not about this at all" (%screen-text h)))
        "the wait displaces the head's note while it is up")
    (is (search "waiting for it to go" (%screen-text h)) "and stays on the screen"))
  ;; and no wait, no row: the frame is exactly as it was
  (let* ((leticl::*stop-request* nil)
         (h (%on-head :cols 100 :rows 24)))
    (leticl::%render h)
    (is (null (leticl::stop-wait-row h 100)) "with nothing pending the row is absent")
    (is (not (search "asked to stop" (%screen-text h))) "and nothing is drawn for it")))

(def-test a-stop-is-over-when-the-daemon-is-gone (:suite leticl)
  "**The fact waited on is the daemon's ABSENCE.** It takes its pid and its socket
with it, and that — not the acknowledgement — is what was asked for. The head leaves
with the outcome said, naming which daemon went."
  (let* ((leticl::*stop-request* (%stop-request-for :socket "/tmp/leticl-gone.sock"
                                                    :pid (%dead-pid)))
         (h (%make-head)))
    (is (leticl::tick-stop-request h) "the tick ends the wait")
    (is (not (leticl::head-running h)) "and the head may leave")
    (is (search "the daemon has stopped" (head-farewell h)) "with the outcome said")
    (is (search (format nil "pid ~d" (%dead-pid)) (head-farewell h))
        "naming which daemon went")
    ;; a daemon that is still there is NOT gone, however quiet it is — a FRESH head,
    ;; because the tick above has already ended the first one's wait
    (let* ((leticl::*stop-request* (%stop-request-for :socket nil :pid (%live-pid)))
           (h2 (%make-head)))
      (is (null (leticl::tick-stop-request h2)) "a live daemon keeps the wait open")
      (is (leticl::head-running h2) "and the head stays"))))

(def-test a-daemon-that-will-not-go-is-named-on-the-way-out (:suite leticl)
  "The requirement's third clause, and the one the operator's wedged morning needed:
the head leaves anyway — it must not hold a terminal hostage to a process that is
not going — and the farewell says which daemon is still running and what stops it
from outside. That failure was invisible twice over: the head had already exited,
and its last words were on the alternate screen, which is thrown away one line
later."
  (let* ((leticl::*stop-request* (%stop-request-for
                                  :socket "/run/user/1000/letibot/abc.sock"
                                  :pid (%live-pid)
                                  :asked-ago 5000
                                  :deadline-in -1))
         (h (%make-head)))
    (is (leticl::tick-stop-request h) "the deadline ends the wait")
    (is (not (leticl::head-running h)) "and the head leaves — the deadline is the escape")
    (let ((said (head-farewell h)))
      (is (search "and has NOT stopped" said) "saying the daemon did not go")
      (is (search "5.0s" said) "how long it waited")
      (is (search (format nil "pid ~d" (%live-pid)) said) "naming the pid")
      (is (search "letibot --stop" said) "and what stops it from outside"))))

(def-test a-bye-during-a-stop-answers-it-without-ending-it (:suite leticl)
  "The `bye` arm normally ends the head, and that is right: a refusal the daemon meant
as final must not become a two-second reconnect loop, and a version skew must not be
unescapable. **With a stop pending it is the daemon's ANSWER to that stop**, and the
outcome is still its absence — leaving here would be the same defect one frame later,
with the operator no better off."
  (let* ((leticl::*stop-request* (%stop-request-for :socket nil :pid (%live-pid)))
         (*stdout* (make-string-output-stream))
         (h (%on-head :cols 90 :rows 20)))
    (leticl::%handle-frame h (list :frame "bye" :reason "daemon shutting down"))
    (is (leticl::head-running h) "the head does not leave on the answer")
    (is (search "bye — daemon shutting down" (getf leticl::*stop-request* :heard))
        "and what the daemon said is recorded")
    (is (not (head-connected h)) "with the socket known to be going")
    ;; and a head with NO stop pending still leaves, which is the skew case
    (let* ((leticl::*stop-request* nil)
           (h2 (%on-head :cols 90 :rows 20)))
      (leticl::%handle-frame h2 (list :frame "bye"
                                      :reason "protocol version 23, this daemon speaks 22"))
      (is (not (leticl::head-running h2)) "without a stop pending a bye is still final")
      (is (search "protocol version 23" (head-farewell h2)) "and names the skew"))))

(def-test a-head-waiting-for-a-stop-does-not-reconnect (:suite leticl)
  "The daemon it asked to stop is closing this socket ON PURPOSE. Re-attaching would
be asking a dying daemon for a session — and the reconnect would race the very wait
that exists to turn the ask into an outcome, which is how a head that gave up on the
answer would end up quieter than one that did not."
  (let* ((leticl::*stop-request* (%stop-request-for :socket "/tmp/leticl-nope.sock"
                                                    :pid (%live-pid)))
         (h (%make-head)))
    (setf (leticl::head-socket-path h) "/tmp/leticl-nope.sock"
          (head-status-note h) nil)
    (leticl::%try-reconnect h)
    (is (null (head-status-note h)) "no reconnect was tried, so none failed")
    (is (zerop (leticl::head-last-reconnect h)) "and the reconnect stamp never moved")))

(def-test a-live-socket-is-a-daemon-even-with-no-record-beside-it (:suite leticl)
  "**My own fix this morning, measured and wrong.** Refusing a folder with no
daemon was right; testing it by looking for the `.json` record `~/bin/letibot`
writes was not. A `harnessd` started any other way — by hand, by a test, by a
harness with its own launcher — has a live socket and no record, and the head
refused it with *\"nothing listens at X\"* while something was listening at X.
Found by starting a scratch daemon to test the stop path and being unable to
attach to it. The socket is the daemon; the record is only what a launcher left
beside it."
  (let ((sock "/tmp/claude-1000/-home-dead-Projects-leticl/3603a50c-c42f-4b18-87ce-b917064534c9/scratchpad/probe.sock"))
    (ignore-errors (delete-file sock))
    (is (not (leticl::%socket-exists-p sock)) "nothing there is nothing")
    (is (not (leticl::%socket-exists-p "/home/dead/Projects/leticl/PARITY.md"))
        "and a regular file of the same name is not a daemon either")
    (let ((s (make-instance 'sb-bsd-sockets:local-socket :type :stream)))
      (unwind-protect
           (progn (sb-bsd-sockets:socket-bind s sock)
                  (is (leticl::%socket-exists-p sock) "a real socket is one"))
        (ignore-errors (sb-bsd-sockets:socket-close s))
        (ignore-errors (delete-file sock))))))

(def-test a-table-with-an-empty-header-still-opens (:suite leticl)
  "A GFM table whose HEADER cells are empty is a table.

The guard rejected any line made only of spaces, dashes, colons and pipes, so
`| | |` was not a row — and then `|---|---|` was not a delimiter either, because a
delimiter row only counts when the table is already open. The whole table fell
through to the paragraph path and rendered as ONE LINE of raw pipes joined by
spaces. Measured on the operator's screen, in a session that is not this one:

    The three commits that are now on GitHub:

    | | | |---|---| | 2cd1dae | TODO: record the markdown inline regression | …

A model writes an empty header when the first column is a LIST rather than a name,
which is what that table was: three commits, two columns, nothing to call them."
  (let* ((text (format nil "The three commits:~%~%| | |~%|---|---|~%| `2cd1dae` | TODO: the regression |~%| `f11738b` | markdown: one node at a time |~%"))
         (lines (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l)))
                        (markdown-lines text))))
    (is (notany (lambda (l) (search "|---|---|" l)) lines)
        "the delimiter row is consumed, never painted")
    (is (notany (lambda (l) (search "| | |" l)) lines)
        "and the empty header is not painted as raw pipes either")
    (is (some (lambda (l) (search "2cd1dae" l)) lines) "the first row is there")
    (is (some (lambda (l) (search "f11738b" l)) lines) "and the second")
    ;; the columns are ALIGNED, which is the whole point of a table
    (let ((rows (remove-if (lambda (l) (zerop (length (string-trim " " l))))
                           lines)))
      (is (>= (length rows) 3) "a header-with-no-names, a rule, and two rows"))))

;;; ------------------------------------------ synchronized output is balanced ;;;
;;;
;;; `ESC[?2026h` ENABLES synchronized output, which SUSPENDS every update until
;;; `ESC[?2026l` arrives. If a paint signals between them and the close is skipped,
;;; the terminal is left with sync ENABLED and the screen never changes again.
;;;
;;; Measured by the operator on a live head: expanding a tool card or a thinking
;;; block froze the screen, scroll looked dead, and switching byobu windows
;;; restored it — because tmux re-asserts the terminal's state on focus. The cause
;;; was NOT a content escape (every path for those is closed: `%without-control`,
;;; `plain-columns-p`, the zero-width cluster skip, C1 zeroed in the width table).
;;; It was this: the paint loop had no `unwind-protect`, so an error inside it —
;;; and `paint-diff` deliberately keeps default safety on its cell reads, so a bad
;;; cell SIGNALS rather than faults, i.e. inside the unprotected region — left the
;;; sequence open. `%render-and-paint` then caught the error into
;;; `*last-render-error*` and carried on painting into a terminal that had stopped
;;; showing anything.

(defun %emit-count (out needle)
  "How many times NEEDLE appears in the string OUT has collected."
  (let ((text (get-output-stream-string out)))
    (values (let ((n 0) (i 0))
              (loop for j = (search needle text :start2 i)
                    while j do (incf n) (setf i (1+ j)))
              n)
            text)))

(defun %without-ansi (s)
  "S with every escape sequence taken out — so an assertion can be about what a frame
SAYS rather than about the byte order the painter happened to choose. `%esc-sequences`
is the same reader the §3.1 test uses, so the two cannot disagree about where a
sequence ends."
  (let ((out (make-string-output-stream))
        (seqs (leticl::%esc-sequences s))
        (i 0))
    (loop while (< i (length s))
          do (let ((hit (find-if (lambda (q) (eql (search q s :start2 i) i)) seqs)))
               (if hit (incf i (length hit))
                   (progn (write-char (char s i) out) (incf i)))))
    (get-output-stream-string out)))

(defun %two-screens ()
  "A pair of screens with one cell changed, so the paint has work to do."
  (let ((prev (make-screen 20 3))
        (cur (make-screen 20 3)))
    (screen-put-string cur 0 0 "hello")
    (values prev cur)))

(def-test synchronized-output-is-closed-when-the-paint-signals (:suite leticl)
  "THE regression: a signal inside the paint must not leave sync ENABLED.

The paint is driven with a stub that signals partway through, which is what a bad
cell does. The close must still reach the terminal, exactly once, and the frame
must not be left mid-style."
  (let ((leticl::*caret* nil))
    (multiple-value-bind (prev cur) (%two-screens)
      (let ((out (make-string-output-stream)))
        ;; **A CELL HOLDING SOMETHING THAT IS NOT A CELL.** This used to arrange the
        ;; signal by shortening `*style-sgrs*` so the painter's own `aref` was out of
        ;; range. `%sgr` is bounds-checked now — that check IS the fix for the
        ;; operator's frozen screen — so the paint no longer dies there at all, and a
        ;; regression test that cannot fail guards nothing. This is the other real
        ;; one, named in `paint-diff`'s own docstring: *"the vector holds whatever a
        ;; hack put there"*, and `(fill (screen-cells s) nil)` is one line off the
        ;; eval socket.
        (setf (svref (leticl::screen-cells cur) 7) nil)
        (signals error (paint-diff prev cur out :sync t))
        (multiple-value-bind (closes text) (%emit-count out (format nil "~C[?2026l" leticl::+esc+))
          (is (= 1 closes)
              "the sync is CLOSED exactly once even though the paint signalled —
without this the terminal keeps synchronized output ENABLED and stops updating")
          (is (search (format nil "~C[?2026h" leticl::+esc+) text)
              "and it was opened, so the pair is real"))))))

(def-test an-out-of-range-style-costs-a-colour-and-not-the-frame (:suite leticl)
  "**The fix for the operator's frozen screen, and the one place it belongs.**

`*styles*` and `*style-sgrs*` are parallel by construction, and a live push that
redefines the style vocabulary rebuilds them under cells written with the OLD
numbering. `(aref *style-sgrs* index)` then reads past the end and SIGNALS — from
inside `paint-diff`'s write loop, which is the recorded `df9bd3f` incident and the
only mechanism that accounts for all of the operator's report.

The chain, each step measured or in the tree: every paint dies at its first style
change; `%paint-failure` writes `ESC[2J` and dies in the same place, so the terminal
is CLEARED while `head-prev-screen` records the frame the head *intended*; a diff then
writes only what CHANGED against a record that is already a lie, so **nothing in the
head can repair it** (*\"even after collapsing back\"*); and a byobu window switch
resizes the pane, which allocates a FRESH cell vector (`screen-resize`) — the
out-of-range cells are gone and the paints succeed again. **That is why only a window
switch fixes it.**

Measured, on a scratch head with the paint injected to die after `ESC[2J`: the head
believed it had drawn 30 rows and the terminal had none of them.

A wrong index is a fact about a CELL, so it costs that cell's colour and nothing
else."
  (let ((*caret* nil))
    (multiple-value-bind (prev cur) (%two-screens)
      (let ((out (make-string-output-stream))
            (real leticl::*style-sgrs*))
        (unwind-protect
             (progn
               ;; a cell holding an index the table no longer has — exactly what a
               ;; rebuild under live cells leaves behind. The `hello` in it is the
               ;; text that must survive the poisoned style.
               (screen-put-string cur 0 0 "hello")
               (setf (cell-style (screen-cell cur 0 0)) 9999)
               (finishes (paint-diff prev cur out :sync t))
               (let ((text (get-output-stream-string out)))
                 (is (search "hello" (%without-ansi text))
                     "the frame is still painted: the text reached the terminal")
                 (is (search (format nil "~C[?2026l" leticl::+esc+) text)
                     "and the sync closed, because nothing signalled")
                 ;; **the fallback is style 0's escape, which is a RESET.** Not
               ;; nothing — a cell drawn in the PREVIOUS cell's style is a lie about
               ;; the text — and not a mode sequence either: the only `ESC[?…` forms
               ;; on this frame are the ones the painter itself writes.
               (is (string= (aref leticl::*style-sgrs* 0) (leticl::%sgr 9999))
                   "an out-of-range index answers with style 0's escape")
               (dolist (esc (leticl::%esc-sequences text))
                 (is (or (string= esc (format nil "~C[?2026h" leticl::+esc+))
                         (string= esc (format nil "~C[?2026l" leticl::+esc+))
                         (string= esc (format nil "~C[?25l" leticl::+esc+))
                         (string= esc (format nil "~C[?25h" leticl::+esc+))
                         (string= esc (aref leticl::*style-sgrs* 0))
                         (search "H" esc))
                     (format nil "~s is a form the painter itself writes" esc)))))
          (setf leticl::*style-sgrs* real))))
    ;; and the fallback is the DEFAULT style, not an empty string: `(aref sgrs 0)` is
    ;; the reset, so a poisoned cell draws plainly rather than leaving the terminal in
    ;; whatever style the cell before it set
    (is (string= (aref leticl::*style-sgrs* 0) (leticl::%sgr 9999))
        "an out-of-range index answers with style 0's escape")
    (is (string= (aref leticl::*style-sgrs* 0) (leticl::%sgr -1))
        "and so does a negative one")))

(def-test a-paint-that-failed-forces-the-next-one-to-be-full (:suite leticl)
  "**A failed paint means the head no longer knows what is on the terminal.**

`head-prev-screen` is the head's only record of it, and every later diff is computed
against that record: a cell where the record and the new frame AGREE is a cell nothing
is ever written to again. So a record written by a paint that did not complete is not
stale, it is a permanent hole — and measured on a scratch head, an ordinary paint
could not repair one.

Two halves, and both are needed: the failure path records `head-prev-screen` only for
a paint that got out, and it asks for a FULL repaint whichever way it went. The second
is what makes recovery independent of the next frame happening to differ — which is
the coincidence the operator's symptom consisted of, and which a byobu window switch
supplied instead, by resizing."
  (let ((head (leticl::%make-head)))
    ;; a render that cannot compose: `%render` is entered and dies straight away
    (flet ((boom (h)
             (declare (ignore h))
             (error "hunt: the render is broken")))
      (declare (ignore #'boom)))
    ;; drive it through the real entry point with a broken `%render`
    (let ((real (symbol-function 'leticl::%render))
          (out (make-string-output-stream))
          (*stdout* nil))
      (unwind-protect
           (progn
             (setf (symbol-function 'leticl::%render)
                   (lambda (h) (declare (ignore h)) (error "the render is broken")))
             (setf (head-prev-screen head) (leticl::make-screen 20 3)
                   (head-screen head) (leticl::make-screen 20 3)
                   (head-cols head) 20 (head-rows head) 3
                   leticl::*caret* nil)
             ;; the paint runs, dies, and the failure frame is drawn
             (leticl::%render-and-paint head)
             (is (not (null leticl::*last-render-error*))
                 "the failure was recorded, as it always was")
             (is (head-full-repaint head)
                 "**and the next paint is a FULL one** — nothing the failed paint wrote
 (or failed to write) can then persist, which is the half that makes recovery not
 depend on luck"))
        (setf (symbol-function 'leticl::%render) real)))))

(def-test synchronized-output-is-closed-on-the-happy-path-too (:suite leticl)
  "Exactly one pair, the close LAST, and the frame's reset inside it.

A fix that closed the sync twice, or closed it before the reset, would pass the
regression above and still be wrong. Measured output for a one-word frame:

    ESC[?2026h  ESC[1;1H  hello  ESC[0m  ESC[?25l  ESC[?2026l
    ^open       ^move     ^content ^reset ^caret   ^close, and last"
  (let ((leticl::*caret* nil))
    (multiple-value-bind (prev cur) (%two-screens)
      (let ((out (make-string-output-stream))
            (begin (format nil "~C[?2026h" leticl::+esc+))
            (end (format nil "~C[?2026l" leticl::+esc+)))
        (paint-diff prev cur out :sync t)
        (let ((text (get-output-stream-string out)))
          (is (= 1 (count-substring begin text)) "the sync is opened once")
          (is (= 1 (count-substring end text)) "and closed once, not twice")
          (is (eql 0 (search begin text)) "it is the FIRST byte")
          (is (= (- (length text) (length end)) (search end text))
              "and the close is the LAST — nothing is painted after it")
          (is (search (format nil "~C[0m" leticl::+esc+) text)
              "the frame still resets the style")
          (is (< (search begin text) (search "hello" text))
              "the content is inside the pair"))))))

(def-test the-sync-pair-brackets-every-painted-byte (:suite leticl)
  "Nothing is painted outside the pair. This is the property a future edit is most
likely to break: writing to OUT before `sync-begin` or after `sync-end` is a byte
the terminal can show half-drawn."
  (let ((leticl::*caret* nil))
    (multiple-value-bind (prev cur) (%two-screens)
      (let ((out (make-string-output-stream))
            (begin (format nil "~C[?2026h" leticl::+esc+))
            (end (format nil "~C[?2026l" leticl::+esc+)))
        (paint-diff prev cur out :sync t)
        (let* ((text (get-output-stream-string out))
               (b (search begin text))
               (e (search end text))
               (body (subseq text (+ b (length begin)) e)))
          (is (and b e (< b e)) "begin precedes end")
          (is (search "hello" body) "the frame's content is inside the pair")
          (is (search (format nil "~C[0m" leticl::+esc+) body)
              "and so is the reset, so a style cannot leak past the close")
          (is (search (format nil "~C[?25l" leticl::+esc+) body)
              "and the caret, so the pair encloses the whole frame"))))))

;;; ---------------------------------------- a render error is reachable ;;;
;;;
;;; The operator: *"surface `*last-render-error*` somewhere reachable — right now a
;;; render error that freezes the screen leaves its own explanation only in
;;; /status, which cannot be read once the screen is frozen."*

(def-test a-render-error-raises-the-alarm (:suite leticl)
  "A broken renderer must not be able to hide its own report.

The failure is normally PAINTED into the screen, so when the failure is in the
painting that frame is the one thing that does not arrive. The alarm triangle on
the composer's edge is drawn by a path that has to keep working for the screen to
exist at all, and `/status` carries the message."
  (let ((h (%make-head))
        (*last-render-error* nil)
        ;; **Bound, because `alarmed-p` reads it and it is a GLOBAL.** A suite runs
        ;; this head after two hundred others in one image, and a counter that
        ;; survives between them stops being about the thing it names: this test
        ;; failed against the new code because three earlier tests had handed the
        ;; fold an event it does not know, and "nothing wrong, no alarm" was reading
        ;; somebody else's number. `*unreadable-total*` is not part of the render
        ;; error's business at all — it is here so that it cannot be.
        (*unreadable-total* 0)
        (*scrubbed-total* 0)
        (*resyncs* 0))
    (setf (head-connected h) t)          ; a fresh head starts disconnected
    (is (not (alarmed-p h)) "nothing wrong, no alarm")
    (setf *last-render-error* (make-condition 'simple-error :format-control "boom"))
    (is (alarmed-p h) "a render error raises the alarm")
    (setf *last-render-error* nil)
    (is (not (alarmed-p h)) "and clearing it lowers the alarm again")))

(def-test status-carries-the-render-error (:suite leticl)
  "The message survives in a place that does not depend on the renderer working."
  (let* ((h (%make-head))
         (*last-render-error* nil))
    (let ((text (segs-of (status-screen-lines h 120))))
      (is (not (search "THE LAST FRAME FAILED" text))
          "no error, no row"))
    (setf *last-render-error* (make-condition 'simple-error :format-control "the message"))
    (let ((text (segs-of (status-screen-lines h 120))))
      (is (search "THE LAST FRAME FAILED" text) "the row appears")
      (is (search "the message" text) "with the message itself")
      (is (search "is not the fix" text)
          "and it says what to do, because 'clear the flag' is not the fix"))))

;;; ------------------- a frame this head cannot read (R3) ------------------- ;;;
;;;
;;; **Said, counted, and survived.** The alternatives are both worse and both are
;;; what this head had: exiting takes the session with it and says nothing, and
;;; stepping over the frame in silence makes *"this daemon is sending me something I
;;; do not understand"* look exactly like a quiet daemon — which is how an afternoon
;;; goes into debugging the wrong half. Silence is the same failure as exiting, one
;;; decibel down.

(defun %unknown-event (&optional (seq 9))
  "One envelope from a daemon build that has one more tag than this one, exactly as
the reader hands it to the fold — `:wire-line` included, because the reader attaches
it to every frame it decodes and the sentence about an unreadable one carries it."
  (let ((line (format nil "{\"frame\":\"event\",\"seq\":~d,\"event\":\"peeked_v2\"}" seq)))
    (list* :wire-line line
           (json-decode line))))

(def-test a-frame-this-head-cannot-read-is-said-counted-and-survived (:suite leticl)
  "The criterion entire, in the operator's terms.

**When the daemon sends a frame this head cannot parse, the operator sees a row in
the CONVERSATION where it arrived** — not a status note, which expires on a TTL and
would be gone by the time anybody looked for it, which is the failure again — naming
this head's protocol version and carrying the offending line; the session carries on,
the next real frame applies, and `/status` reads 0 before it has ever happened.

**The zero is the point.** A head that has never met one says `0`, which is a
different statement from a head that does not count them at all — the same
present-and-zero rule the reference's own counters keep, and the reason the row is
written unconditionally instead of appearing when it first moves."
  (let* ((h (%make-head))
         (*unreadable-total* 0)
         (*resyncs* 0) (*scrubbed-total* 0) (*filtered-total* 0) (*rendered-total* 0))
    (let ((s (head-session h)))
      ;; **Before anything has happened: present, and zero.**
      (is (some (lambda (l) (string= "  unreadable  0" l))
                (lines-text (status-screen-lines h 120)))
          "/status reads 0 on a head that has never met one")
      (is (null (alarm-counts h)) "and nothing on the border")
      (let ((before (session-seq s)))
        ;; a real event first, so there is a transcript for the row to land in
        (leticl::%handle-frame h (list :frame "event" :seq 1 :event "turn_started" :turn-id "t1"))
        (is (= 1 (session-seq s)) "the session is folding frames")
        ;; --- ONE THIS BUILD CANNOT READ ---
        (leticl::%handle-frame h (%unknown-event 2))
        (is (= 1 *unreadable-total*) "the count moves")
        (is (head-dirty h) "and the frame is marked, so the row is drawn")
        (let* ((item (aref (session-items s) (1- (length (session-items s)))))
               ;; joined with a SPACE: the sentence wraps, and a wrap can break between
               ;; any two of its words — the first version of this searched
               ;; `"The line was:"` in a newline-joined render and read the break
               ;; between `The` and `line` as a missing sentence.
               (row (format nil "~{~a~^ ~}"
                            (lines-text (item-lines item 100 (head-prefs h))))))
          (is (search "cannot read" row) "the conversation says so where it arrived")
          (is (search "peeked_v2" row) "and names the tag")
          (is (search (format nil "protocol ~d" +protocol-version+) row)
              "and names THIS head's version, so the two numbers can be compared")
          (is (search "The line was: {\"frame\":\"event\"" row)
              "and carries the offending line AS IT ARRIVED, not a re-encoding")
          (is (not (search "wire_line" row))
              "and not the frame's own bookkeeping — the line inside the line")
          (is (search "connection is still up" row) "and says the head is still here")
          (is (string= "note" (leticl::item-kind item)) "as a row of this head's own"))
        ;; --- the session carries on ---
        (leticl::%handle-frame h (list :frame "event" :seq 3 :event "delta" :turn-id "t1"
                               :target "text" :text "still here"))
        (is (= 3 (session-seq s)) "the next real frame still applies")
        (is (search "still here" (getf (session-turn s) :text))
            "and its content is in the turn")
        ;; --- and a second one counts twice ---
        (leticl::%handle-frame h (%unknown-event 4))
        (is (= 2 *unreadable-total*) "a second one is two")
        ;; --- **the read mark.** This is the distinction the requirement turns on,
        ;; and it is not the one I first wrote down: an unknown EVENT was PARSED — it
        ;; is an envelope and its `seq` is a fact — so it advances the mark like any
        ;; other frame and the head acks it. That is what keeps an unknown event from
        ;; stalling the stream behind it. Only a LINE that would not decode has no seq
        ;; at all, and that is the one that must move nothing; asserted in
        ;; `an-undecodable-line-is-the-same-fact-as-an-unknown-tag`.
        (is (= 4 (session-seq s))
            "a decoded-but-unknown event advances the read mark so the stream is not stuck")
        (is (zerop *filtered-total*)
            "and it is not `filtered`: that is events this head CHOSE not to show")
        (is (zerop *rendered-total*) "nor rendered, which counts a fold that succeeded")
        ;; --- /status and the border ---
        (is (some (lambda (l) (string= "  unreadable  2" l))
                  (lines-text (status-screen-lines h 120)))
            "/status carries the true count")
        (is (search "unreadable 2"
                    (format nil "~{~a ~a~^ · ~}"
                            (loop for (k . v) in (alarm-counts h) append (list k v))))
            "and the border names it once it has moved")
        ;; --- the head is still running, which is the whole of "survived" ---
        (is (leticl::head-running h) "the head is still here")
        (is (> (session-seq s) before) "and it went on reading")))))

(def-test an-unknown-frame-tag-is-unreadable-too (:suite leticl)
  "Two ways to meet one, and the second is the one this reader has and the
reference does not.

`ServerFrame` is internally tagged, so a tag serde does not know fails the whole
LINE there. This reader is structural: it decodes whatever is on the wire and hands
the plist to `%handle-frame`, whose last arm used to answer `:control` and say
nothing. A daemon one version ahead is exactly that shape, and being structural and
silent is strictly worse than being strict and loud."
  (let* ((h (%make-head))
         (*unreadable-total* 0) (*resyncs* 0) (*scrubbed-total* 0))
    (is (= 0 *unreadable-total*) "nothing yet")
    ;; a frame tag this build has never heard of, with the line it arrived as
    (leticl::%handle-frame h (list :frame "peeked_v2" :wire-line "{\"frame\":\"peeked_v2\"}"))
    (is (= 1 *unreadable-total*) "an unknown FRAME tag is counted")
    (let* ((item (aref (session-items (head-session h))
                       (1- (length (session-items (head-session h))))))
           (row (segs-of (item-lines item 100 (head-prefs h)))))
      (is (search "unknown frame" row) "and named as one")
      (is (search "peeked_v2" row) "with the tag"))
    ;; the line it arrived as rides on the frame, so an unknown tag can still show
    ;; the bytes — the evidence a decoder's complaint would have dropped
    (leticl::%handle-frame h (list :frame "something_else" :wire-line "{\"frame\":\"something_else\"}"))
    (let* ((item (aref (session-items (head-session h))
                       (1- (length (session-items (head-session h))))))
           (row (segs-of (item-lines item 120 (head-prefs h)))))
      (is (search "The line was: {\"frame\":\"something_else\"}" row)
          "and the offending line is carried, not just described"))
    (is (= 2 *unreadable-total*) "both counted")))

(def-test an-undecodable-line-is-the-same-fact-as-an-unknown-tag (:suite leticl)
  "A line that is not JSON at all arrives on the READER thread, which used to turn
it into a `warning` with code `malformed-frame`: one line above the composer, gone
on the next frame's TTL, and counted nowhere. One conversation, one counter."
  (let* ((h (%make-head))
         (*unreadable-total* 0) (*resyncs* 0) (*scrubbed-total* 0))
    (leticl::%handle-frame h (list :unreadable t :detail "not json: eof" :line "{not json at all"))
    (is (= 1 *unreadable-total*) "counted")
    ;; **Nothing is acked and the read mark does not move.** No frame was parsed, so
    ;; there is no seq to report, and inventing one would rewind this head's mark over
    ;; frames it has already read — the one thing a mark must never do. This is the
    ;; half that differs from an unknown EVENT, which was parsed and does have a seq.
    (is (zerop (session-seq (head-session h)))
        "a line that would not decode moves no read mark at all")
    (let* ((item (aref (session-items (head-session h))
                       (1- (length (session-items (head-session h))))))
           (row (segs-of (item-lines item 120 (head-prefs h)))))
      (is (search "{not json at all" row) "the bytes are kept")
      (is (search (format nil "protocol ~d" +protocol-version+) row)
          "and the version is named"))
    ;; a LONG line is truncated rather than pasted as a wall
    (let ((long (make-string 5000 :initial-element #\x)))
      (leticl::%handle-frame h (list :unreadable t :detail "too long" :line long))
      (let* ((item (aref (session-items (head-session h))
                         (1- (length (session-items (head-session h))))))
             (row (segs-of (item-lines item 200 (head-prefs h)))))
        (is (search "…" row) "a 5 KB line comes back cut")
        (is (< (length row) 4000) "and it is not a wall")))
    (is (= 2 *unreadable-total*) "both counted")))

(def-test an-event-this-head-knows-and-does-not-fold-is-not-unreadable (:suite leticl)
  "**The counter must not cry wolf.** `screen_requested`, `secret_requested` and
`secret_settled` are read perfectly well — they are answered by the head LOOP, which
owns the last painted frame and the input focus, and `apply-event` is the session's
folder and can do none of those. `explain` is known and has no renderer, which the
reference answers `Filtered` too (app.rs:3017).

Without this list `an-unreadable-frame-...` and half the suite reported frames the
head reads fine, which is a counter that stops meaning anything."
  (let* ((h (%make-head))
         (*unreadable-total* 0) (*resyncs* 0) (*scrubbed-total* 0))
    (dolist (env (list (list :frame "event" :seq 1 :event "screen_requested" :req-id "q1")
                       (list :frame "event" :seq 2 :event "explain" :plan nil)
                       (list :frame "event" :seq 3 :event "secret_settled"
                             :req-id "r1" :given t :by "another head")))
      (leticl::%handle-frame h env))
    (is (zerop *unreadable-total*)
        "three events this head reads and does not fold are not three failures")
    (is (zerop (length (session-items (head-session h))))
        "and nothing was filed into the conversation")))

;;; ------------------------------------- a fold flip changes what is DRAWN ;;;
;;;
;;; The operator: *"thinking and tools are no longer togglable"*. The pref flipped
;;; and the screen did not, because the render cache — added the same hour — keys
;;; on a generation counter, the width and the items vector's identity, and a
;;; PREFERENCE change is invisible to all three. `ctrl-t` set the flag, marked the
;;; head dirty, repainted, and got the previous lines back from the cache.
;;;
;;; These assert the property the cache broke: a preference change changes the
;;; LINES, not only the pref.

(defun %rows-with-a-tool (prefs)
  "The lines for one transcript with a tool result in it, under PREFS."
  (let* ((*hist-cache* nil)
         (h (%make-head))
         (s (head-session h)))
    ;; PREFS is the argument; the head's own plist is what the renderer reads
    (setf (getf (head-prefs h) :show-tools) (getf prefs :show-tools)
          (getf (head-prefs h) :show-reasoning) (getf prefs :show-reasoning))
    (setf (session-items s)
          (vector (list :item-id "t1" :kind "tool_result" :ts 0
                        :item (list :type "tool_result" :call-id "c" :name "bash"
                                    :outcome (list :outcome "ok")
                                    ;; SHORTER THAN THE BUDGET, deliberately: with 40
                                    ;; lines the open fold draws 39 of them and spends
                                    ;; the fortieth on the seam, which is the reference's
                                    ;; arithmetic and a different property from this one
                                    ;; (`a-payload-at-the-budget-shows-all-but-one-line`)
                                    :payload (format nil "~{~a~^~%~}"
                                                     (loop for i from 1 to 30
                                                           collect (format nil "line ~a" i)))))))
    (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l)))
            (leticl::%viewport-lines h 120 30))))

(def-test flipping-a-fold-changes-the-drawn-lines (:suite leticl)
  "The cache must not serve the previous fold's lines back.

`ctrl-t` folds the tool output, `ctrl-r` the thinking. Both change how a row
RENDERS, so both must reach the screen — and the cache added for scroll speed
keyed on a generation the preference change did not bump, so neither did.

Folded is not EMPTY: it keeps the first line, which is where a tool puts what it
did, then `… +N lines · ctrl-t`. So the assertion is how much, and an earlier
version of this test wrongly asserted `line 1` was absent — the same mistake as
reading a summary as a loss."
  (let ((folded (%rows-with-a-tool (list :show-tools nil :show-reasoning nil)))
        (open (%rows-with-a-tool (list :show-tools t :show-reasoning nil))))
    (is (not (equal folded open))
        "folding the tools changes the lines — the whole point of the chord")
    (is (some (lambda (l) (search "line 1" l)) folded)
        "folded keeps the FIRST line, which is what the tool did")
    (is (some (lambda (l) (search "… +" l)) folded)
        "and says how much it is hiding")
    (is (some (lambda (l) (search "line 30" l)) open) "open, the whole body is there")
    (is (notany (lambda (l) (search "line 30" l)) folded) "folded, it is not")
    (is (< (length folded) (length open)) "and folded is the shorter of the two")))

(def-test a-preference-change-bumps-the-render-generation (:suite leticl)
  "The property, not the instance: the SETTER is what invalidates, so a fifth
preference cannot be added without the cache noticing."
  (let ((*hist-generation* 0)
        (h (%make-head)))
    (setf (head-pref h :show-tools) t)
    (is (= 1 *hist-generation*) "setting a preference bumps the generation")
    (setf (head-pref h :show-tools) t)
    (is (= 2 *hist-generation*) "and again, so a same-value set is still safe")
    (is (head-dirty h) "and the head is marked for a repaint")))

(def-test every-preference-write-goes-through-the-setter (:suite leticl)
  "Four sites mutated `head-prefs` directly and each of them changed the render —
`%flip-fold`, ctrl-x, the config pane and `prefs-into-head`. This checks the
source, because the defect was a site that forgot, and the fifth one will."
  (dolist (file '("editor" "panes" "commands"))
    ;; NOT prefs.lisp: that file DEFINES the setter, so it is the one place the
    ;; direct write belongs
    (let ((text (source-of file)))
      (is (not (search "(setf (getf (head-prefs" text))
          (format nil "src/~a.lisp writes head-prefs directly instead of through ~
(head-pref head …), so the render cache will serve the old fold back" file)))))

(def-test the-transcript-renders-oldest-first (:suite leticl)
  "Rows in the order they happened, and a card's body top-down.

This is the test that was MISSING when `%history-until` used `revappend` and every
tool card rendered upside-down — the header last and its output `line 6 … line 1`.
1845 checks passed while the transcript was reversed, because every one of them
asserted CONTENT (`is this text present`) and none asserted ORDER. A screen
comparison would have caught it in a second; the suite could not.

Three orders, all of them things a reader relies on without noticing:
  · messages oldest-first;
  · a card's HEADER above its body;
  · and the body top-down."
  (let* ((*hist-cache* nil)
         (h (%make-head))
         (s (head-session h)))
    (setf (getf (head-prefs h) :show-tools) t)
    (setf (session-items s)
          (vector (list :item-id "a" :kind "assistant" :ts 0
                        :item (list :type "assistant" :text "AAA"))
                  (list :item-id "b" :kind "assistant" :ts 0
                        :item (list :type "assistant" :text "BBB"))
                  (list :item-id "c" :kind "assistant" :ts 0
                        :item (list :type "assistant" :text "CCC"))))
    (let ((rows (mapcar (lambda (l) (and l (format nil "~{~a~}" (mapcar #'car l))))
                        (leticl::%viewport-lines h 120 20))))
      (is (< (position-if (lambda (l) (and l (search "AAA" l))) rows)
             (position-if (lambda (l) (and l (search "BBB" l))) rows))
          "the first message is above the second")
      (is (< (position-if (lambda (l) (and l (search "BBB" l))) rows)
             (position-if (lambda (l) (and l (search "CCC" l))) rows))
          "and the second above the third")))
  ;; a card: header first, then its body in the order the tool wrote it
  (let* ((*hist-cache* nil)
         (h (%make-head))
         (s (head-session h)))
    (setf (getf (head-prefs h) :show-tools) t)
    (setf (session-items s)
          (vector (list :item-id "t" :kind "tool_result" :ts 0
                        :item (list :type "tool_result" :call-id "c" :name "bash"
                                    :outcome (list :outcome "ok")
                                    :payload (format nil "~{~a~^~%~}"
                                                     (loop for i from 1 to 4
                                                           collect (format nil "row ~a" i)))))))
    (let* ((rows (mapcar (lambda (l) (and l (format nil "~{~a~}" (mapcar #'car l))))
                         (leticl::%viewport-lines h 120 20)))
           (head-at (position-if (lambda (l) (and l (search "Ran" l))) rows))
           (one-at (position-if (lambda (l) (and l (search "row 1" l))) rows))
           (four-at (position-if (lambda (l) (and l (search "row 4" l))) rows)))
      (is (and head-at one-at four-at) "the header and both ends of the body are drawn")
      (is (< head-at one-at) "the header is ABOVE the body, not below it")
      (is (< one-at four-at) "and the body reads top-down, not bottom-up"))))
