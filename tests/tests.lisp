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

(def-test json-encode-nil-is-null-never-elided (:suite leticl)
  (is (equal "{\"a\":null}" (json-encode-to-string (list :a nil)))
      "absent and empty must not be the same bytes"))

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
  (is
   (equal
    "{\"frame\":\"attach\",\"protocol_version\":21,\"session_id\":\"\",\"since_seq\":0,\"kind\":\"tui\",\"identity\":\"\",\"caps\":{\"queue\":1024,\"can_decide\":true}}"
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
    (encode-frame (make-screen-answer "q1" (list "abc"))))))

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
    (is (find (cons "a " '(:bg 52)) (first rows) :test #'equal)
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
reader line 4 changed when it was line 313."
  (let ((old (list "a" "b" "c"))
        (new (list "a" "B" "c")))
    (let ((text (diff-lines-text
                 (render-diff old new :width 80 :context 1 :line-numbers t
                              :intra-line nil :old-start 310 :new-start 310))))
      (is (search "311     -b" text) "the removed line is numbered 311")
      (is (search "    311 +B" text) "the added line is numbered 311")
      (is (null (search " 1 " text)) "not numbered from 1"))))

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

(def-test fence-language-names-map-to-the-highlighter (:suite leticl)
  "A fence carries a NAME; the shim takes a PATH. Both spellings work."
  (is (eq 0 (lang-for-fence "no-such-language")) "an unknown name is 0, not a guess")
  (is (integerp (lang-for-fence "lisp")) "a known name answers an id")
  (is (integerp (lang-for-fence "rust")) "and so does another"))

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
    (is (equal "prefil" (prefill-line p 6))
        "and narrower than the head itself it truncates rather than wrapping")))

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
      (ignore-errors (delete-file p)))))

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
      (ignore-errors (delete-file p)))))

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
      (ignore-errors (delete-file p)))))

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
      (ignore-errors (delete-file p)))))

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
status line for the rest of the session."
  (let ((*notice-ttl* 0) (h (%make-head)))
    (say h "hello")
    (is (equal "hello" (head-status-note h)) "the note is there")
    (is (= *notice-ttl-frames* *notice-ttl*) "and its clock started")
    ;; it survives its TTL and then goes
    (dotimes (i (1- *notice-ttl-frames*)) (tick-notice h))
    (is (equal "hello" (head-status-note h)) "still there before the last tick")
    (tick-notice h)
    (is (null (head-status-note h)) "and gone on it")
    ;; a note with no TTL is not aged — an alarm persists
    (setf (head-status-note h) "detached" *notice-ttl* 0)
    (dotimes (i 100) (tick-notice h))
    (is (equal "detached" (head-status-note h))
        "a note nobody started a clock on is not on the TTL")))

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
    (dolist (chord '("ctrl-r" "ctrl-t" "ctrl-x" "ctrl-s" "ctrl-p" "ctrl-c"
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
    (destructuring-bind (id pattern note) (match-option d "reject_always use the scratch dir")
      (is (string= "reject_always" id) "the option is named")
      (is (null pattern) "and no glob is sent")
      (is (string= "use the scratch dir" note) "and the words ARE the note"))))

(def-test the-glob-still-goes-to-the-option-that-writes-a-rule (:suite leticl)
  "The change must not take the glob away from always-allow: both trailing-word
cases live in one matcher and only one of them may win per option."
  (let ((d (%decision-with)))
    (destructuring-bind (id pattern note) (match-option d "allow_always /tmp/*")
      (is (string= "allow_always" id))
      (is (string= "/tmp/*" pattern) "the glob rides on always-allow")
      (is (null note) "and no note"))))

(def-test an-option-that-promised-nothing-refuses-trailing-words (:suite leticl)
  "Somebody who typed them meant them, and answering as though they had not is the
answer they did not give — so the words are refused, not silently dropped."
  (let ((d (%decision-with)))
    (is (null (match-option d "deny because I said so"))
        "a plain deny takes no words")))

(def-test a-ladder-answer-needs-no-words (:suite leticl)
  "The ladder answers by id alone, which is what most answers are."
  (let ((d (%decision-with)))
    (destructuring-bind (id pattern note) (match-option d "allow_once")
      (is (string= "allow_once" id) "the id matches")
      (is (null pattern) "with nothing extra")
      (is (null note)))))

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
    (is (equal "    … +2 lines · ctrl-t" (segs-of (list (third lines)))) "the seam, stepped in, with the chord"))
  (let* ((*item-facts* nil)
         (two (list :type "tool_result" :call-id "c" :name "bash"
                    :outcome (list :outcome "ok") :payload (format nil "a~%b")))
         (lines (item-lines (list :item-id "t2" :kind "tool_result" :item two)
                            80 (list :show-tools nil))))
    (is (= 3 (length lines)) "two lines fit under the limit: both shown, no seam")
    (is (not (search "ctrl-t" (segs-of lines))) "and nothing to unfold")))

(def-test a-whitespace-bearing-target-is-debug-quoted (:suite leticl)
  "letibot shows a heredoc command as `<<'MSG'\\nthe step…`, Rust's `{:?}`; ours
printed the newline and then flattened it to a space."
  (is (equal "\"a\\nb\"" (leticl::%debug-quote (format nil "a~%b"))) "newline as \\n")
  (is (equal "\"say \\\"hi\\\"\"" (leticl::%debug-quote "say \"hi\"")) "quotes escaped")
  (is (search "<<'MSG'\\nthe step" (display-target "{\"command\":\"cd x <<'MSG'\\nthe step\\nMSG\"}"))
      "and so on the row"))

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
    (dolist (pair (list (cons "permission card" (leticl::permission-card-lines h 210))
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
    ;; still shows 36 — the source is the reference here, the binary the evidence)
    (is (= 37 (count-if (lambda (l) (plusp (length l))) text))
        "37 non-blank rows at the capture's width: the reference's 36 plus /config")
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
have and one of which printed `NIL`."
  (let* ((h (%pane-head))
         (*rendered-total* 23144) (*filtered-total* 46) (*scrubbed-total* 0) (*resyncs* 0)
         (*verbosity* :normal))
    (setf (session-seq (head-session h)) 27485
          (session-heads (head-session h)) (list (list :head-id "h3") (list :head-id "h18")))
    (let* ((lines (status-screen-lines h 210))
           (text (lines-text lines)))
      (is (string= "this head" (first text)) "the title")
      (is (= 21 (count-if (lambda (l) (plusp (length l))) text))
          "21 non-blank rows — 26 on the reference's screen with the header and the four chrome rows")
      (is (string= "  session     s-1789639478142928813" (third text)) "the key twelve wide, the value plain")
      (is (equal '(:dim t) (cdr (first (third lines)))) "the key dim")
      (is (null (cdr (second (third lines)))) "the value not")
      (is (uiop:string-prefix-p "              In full, because this is the form a command takes."
                                (fourth text))
          "the explanation fourteen in")
      (is (some (lambda (l) (string= "  head        h3 · 2 attached" l)) text) "the head and how many")
      (is (some (lambda (l) (string= "  seq         27485 · 23144 rendered" l)) text) "seq and rendered")
      (is (some (lambda (l) (string= "  filtered    46 (normal)" l)) text) "filtered at the verbosity")
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

(def-test split-words-keeps-every-space-and-drops-nothing-else (:suite leticl)
  "`%split-words` went from a string stream to `subseq`; re-joining the words
must give the text back exactly, and no chunk may be empty."
  (dolist (text (list "" " " "a" "a b" "a  b" " a" "a " "a b " "  " "one two  three   four "))
    (let ((words (leticl::%split-words text)))
      (is (string= text (apply #'concatenate 'string words))
          (format nil "~s re-joins to itself" text))
      (is (notany (lambda (w) (zerop (length w))) words)
          (format nil "~s has no empty chunk" text)))))

(def-test wrap-measures-the-visible-word-in-place (:suite leticl)
  "The visible width of a word is measured without the trimmed copy; the
break decisions must not move."
  (flet ((texts (lines) (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines)))
    ;; words that fit exactly: the trailing space is not counted against the width
    (is (equal '("abc def" "ghi") (texts (wrap-segments (list (cons "abc def ghi" nil)) 7)))
        "a row whose words fit exactly is not broken early")
    ;; an over-wide word hard-breaks on its VISIBLE part: the trailing space is
    ;; not a chunk (the chunks' row shape is the old one and not asserted here)
    (is (equal "abcdefx" (apply #'concatenate 'string
                                (texts (wrap-segments (list (cons "abcdef x" nil)) 4))))
        "every visible character survives the hard break and the space is gone")
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
  (is (null (leticl::%split-words nil)) "NIL splits to no words")
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
    (setf (session-seq s) 5
          (head-settings h) (list (list :key "model" :value "qwen-3.8-27b"))
          leticl::*model-from-settings-at* 5)
    (is (string= "qwen-3.8-27b" (leticl::%model-name s)) "the attach state")
    ;; a turn starts on another provider, later in the stream
    (apply-event s (list :seq 9 :event "turn_started" :turn-id "t1"
                         :model "deepseek/deepseek-flash" :ledger-head "0000"))
    (is (string= "deepseek/deepseek-flash" (leticl::%model-name s))
        "the switch reaches the header: the turn's word is newer")
    ;; and a fresh settings row, newer still, wins back
    (setf (session-seq s) 12
          (head-settings h) (list (list :key "model" :value "grok/grok-4"))
          leticl::*model-from-settings-at* 12)
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
  (let* ((line "{\"frame\":\"hello\",\"protocol_version\":21,\"session_id\":\"s-1\",\"head_id\":\"h1\",\"dropped\":2,\"snapshot\":null,\"resumed_from\":42,\"scrubbed\":{\"deltas\":3,\"tool_progress\":1},\"wiring\":{\"model\":\"deepseek/deepseek-flash\",\"role\":\"main\"},\"sessions\":[{\"session_id\":\"s-1\",\"title\":\"the resumed one\"}]}")
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

(def-test a-protocol-skew-stops-the-head-and-names-both-numbers (:suite leticl)
  "*\"A silent version skew looks like a bug in the other half, forever\"*
(server.rs:332-342). Nothing read `Hello.protocol_version`, and the stale
`protocol 18` headers in `src/protocol.lisp` and `leticl.asd` said a number that
was not the constant — a comment, not a fact. The grep half is the same shape as
`live-state-tables-are-defvar`: a rule in a document has already failed to
prevent this once."
  (let ((h (%make-head)) (*attach-started-ms* nil))
    (leticl::%handle-frame h (list :frame "hello" :protocol-version 99
                                   :session-id "s-1" :snapshot nil))
    (is (null (leticl::head-running h)) "a head that cannot be understood stops")
    (is (search (format nil "~d" +protocol-version+) (head-status-note h))
        "the note names what we speak")
    (is (search "99" (head-status-note h)) "and what the daemon speaks")
    (is (equal "" (session-session-id (head-session h)))
        "and nothing of the frame is folded"))
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
        (format nil "and it goes out as the payload: ~a" line))))

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
      (is (equal (head-last-rows h) (getf f :rows)) "and the rows it just painted"))
    (is (null (head-screen-reqs h)) "the queue is spent")))

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
  "Put TITLES on HEAD as the daemon's session list, `s-1` … `s-N`."
  (setf (session-sessions (head-session head))
        (loop for title in titles
              for i from 1
              collect (list :session-id (format nil "s-~d" i) :title title)))
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
choosing an option. Up and Down move whether or not a line is being typed; Enter
keeps the guard, answers the MARKED row and HOLDS the line (app.rs:3474-3498,
3983-4000)."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (setf (session-open-decisions (head-session h)) (list (%decision-with)))
    (composer-insert (head-composer h) "some prose")
    (leticl::%handle-key h (list :type :down))
    (is (= 1 (leticl::head-decision-sel h)) "down moves the ladder with a line typed")
    (is (string= "some prose" (composer-buffer (head-composer h))) "and takes nothing from it")
    (is (null (%sent wire)) "and answers nothing yet")
    (leticl::%handle-key h (list :type :enter))
    (let ((f (first (%sent wire))))
      (is (equal "answer" (getf f :frame)) "enter answers the ask")
      (is (equal "allow_always" (getf f :option-id)) "with the row the cursor was on"))
    (is (string= "some prose" (composer-buffer (head-composer h)))
        "and the words are back in the composer, not sent under the ask")
    (is (search "your line is held" (head-status-note h)) "and it says so")))

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
         (text (format nil "~{~a~^~%~}" (lines-text (leticl::permission-card-lines h 120)))))
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
         (text (format nil "~{~a~^~%~}" (lines-text (leticl::permission-card-lines h 120)))))
    (is (not (search "`allow_always <glob>`" text)) "no always-allow, no glob line")
    (is (not (search "`deny_and_tell" text)) "no reject-always, no words line")
    (is (search "no oracle was consulted for this one" text)
        "and the absence of a verdict is SAID: `not asked` and `said nothing`
are different facts and looked identical on a card that drew neither")))

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
         (leticl::*now-ms* 1000000)
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
    ;; no clock, no number: a head that was never told the time must not guess
    (let ((leticl::*now-ms* 0))
      (is (not (search "s left" (format nil "~{~a~}"
                                        (lines-text (leticl::secret-ask-lines h 120)))))
          "and no countdown at all when nobody has said what time it is"))
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

(def-test a-scrubbed-head-shows-the-triangle (:suite leticl)
  "`alarmed()` is `dropped + scrubbed + resyncs > 0` (app.rs:7619-7620) and
`alarm-counts` carried the first and the third. A head that had had secrets
stripped out of its rows and nothing else wrong showed **no ⚠ at all** — the one
counter whose entire purpose is that the operator learns about it was the one
kept quiet."
  (let ((h (%make-head))
        (leticl::*resyncs* 0)
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
