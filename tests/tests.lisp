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
  (let ((cur (make-screen 10 2)))
    (screen-put-string cur 0 0 "ab")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      ;; move to row1 col1, write "ab", then the trailing reset
      (is (equal (format nil "~C[1;1Hab~C[0m" (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "one run, one move"))))

(def-test paint-diff-emits-sgr-on-style-change (:suite leticl)
  (let ((cur (make-screen 10 1))
        (bold-cyan (style-index '(:bold t :fg :cyan))))
    (screen-put cur 0 0 #\x 0)
    (screen-put cur 0 1 #\y bold-cyan)
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      (is (equal (format nil "~C[1;1Hx~C[0;1;36my~C[0m"
                         (code-char 27) (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "default then bold-cyan"))))

(def-test paint-diff-writes-only-changes (:suite leticl)
  (let ((prev (make-screen 10 1))
        (cur (make-screen 10 1)))
    (screen-put-string prev 0 0 "abcdef")
    (screen-put-string cur 0 0 "abXdef")
    (with-output-to-string (out)
      (paint-diff prev cur out :sync nil)
      (is (equal (format nil "~C[1;3HX~C[0m" (code-char 27) (code-char 27))
                 (get-output-stream-string out))
          "only the X moves and writes"))))

(def-test paint-diff-sync-wraps-in-2026 (:suite leticl)
  (let ((cur (make-screen 4 1)))
    (screen-put-string cur 0 0 "hi")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync t)
      (is (equal (format nil "~C[?2026h~C[1;1Hhi~C[0m~C[?2026l"
                         (code-char 27) (code-char 27) (code-char 27) (code-char 27))
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
      (let ((lines (quit-card-lines head 80)))
        (is (= 4 (length lines)) "header, two options, footer")
        (is (search "leave" (lines-text lines)) "the leave option is shown")
        (is (search "stop the daemon" (lines-text lines))
            "the stop option is shown")))))

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
  (is (equal (role-style 3) '(:fg :bright-yellow)) "number")
  (is (equal (role-style 4) '(:fg :cyan)) "type")
  (is (equal (role-style 5) '(:fg :magenta)) "keyword")
  (is (equal (role-style 6) '(:fg :bright-cyan)) "function")
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
  "With the shim, a Rust snippet gets keyword/number/comment roles."
  (unless (hl-available-p)
    (skip "the rano shim is not built"))
  (let* ((src (format nil "fn main() {~%    let x = 42; // c~%}"))
         (lines (highlight-lines src (lang-for "a.rs"))))
    (is (= 3 (length lines)) "three lines")
    (is (some (lambda (s) (and (string= "fn" (car s))
                               (equal (cdr s) '(:fg :magenta))))
              (first lines)) "fn is a keyword")
    (is (some (lambda (s) (and (string= "42" (car s))
                               (equal (cdr s) '(:fg :bright-yellow))))
              (second lines)) "42 is a number")
    (is (some (lambda (s) (and (string= "// c" (car s))
                               (equal (cdr s) '(:dim t))))
              (second lines)) "// c is a comment")))

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
  "A fence with no highlighter renders dim, exactly as it did before P4.

The point of `highlight-fence` is that wiring the engine cannot REGRESS a
terminal with no syntax colour: an unknown language, or a shim that is not
built, still gives one readable segment per line rather than dropping the code."
  (let* ((lines (highlight-fence (list "let x = 1;" "let y = 2;") "some-unknown-language"))
         (first-seg (first (first lines))))
    (is (= 2 (length lines)) "one line per input line")
    (is (equal "let x = 1;" (car first-seg)) "the text survives verbatim")
    (is (equal '(:dim t) (cdr first-seg)) "and is dim, not dropped")))

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
          (list (list :key "mode" :value "automode-edits"
                      :choices (list "read-only" "always-ask" "automode-edits"))
                (list :key "model" :value "deepseek/deepseek-flash"
                      :choices (list "local" "deepseek/deepseek-flash" "glm/glm-5.3-flash"))))
    h))

(def-test the-mode-picker-lists-the-daemons-own-choices (:suite leticl)
  "The head keeps no list of modes to drift: `SettingRow.choices` is the
daemon's, and this is why the head asks for the settings at attach."
  (let* ((h (%head-with-settings)))
    (multiple-value-bind (lines sel-line) (mode-picker-lines h 80)
      (let ((text (format nil "~{~a~^~%~}" (lines-text lines))))
        (is (search "read-only" text) "a choice is listed")
        (is (search "automode-edits" text) "and another")
        (is (search "●" text) "the CURRENT value is marked")
        (is (integerp sel-line) "and the cursor's line comes back")))))

(def-test a-picker-with-no-choices-says-why-not-guesses (:suite leticl)
  "A picker whose list is empty because nobody asked the daemon is a picker that
looks broken — so it says which it is."
  (let ((h (%make-head)))                ; no settings at all
    (let ((text (format nil "~{~a~^~%~}" (lines-text (mode-picker-lines h 80)))))
      (is (search "reports no choices" text) "it names the problem")
      (is (search "asked" text) "and points at the cause"))))

(def-test the-models-picker-lists-models-not-modes (:suite leticl)
  (let* ((h (%head-with-settings)))
    (let ((text (format nil "~{~a~^~%~}" (lines-text (models-picker-lines h 80)))))
      (is (search "deepseek/deepseek-flash" text) "the model row's choices")
      (is (search "glm/glm-5.3-flash" text) "all of them")
      (is (not (search "read-only" text)) "and NOT the mode row's"))))

(def-test a-picker-selection-travels-as-the-daemons-own-word (:suite leticl)
  "The mode goes as its own frame carrying the name the daemon LISTED, and the
model as the slash line the operator would have typed — so neither vocabulary is
copied into the head to drift."
  (let* ((h (%head-with-settings)))
    (setf (head-mode h) :mode-picker (head-picker-sel h) 1)
    ;; the key handler builds the frame; assert on what it would send
    (is (string= "always-ask" (nth (head-picker-sel h) (setting-choices h "mode")))
        "the cursor picks a choice by the daemon's word")
    (is (string= "automode-edits" (setting-value h "mode"))
        "and the current value is the daemon's, not the head's")))

(def-test a-picker-opens-only-when-the-rows-are-asked-for (:suite leticl)
  "The picker's list IS the daemon's choices, so opening it asks if it has to."
  (let ((h (%make-head)))
    (is (null (setting-choices h "mode")) "with no rows, there is nothing to list")
    (setf (head-settings h) (list (list :key "mode" :value "x" :choices (list "x" "y"))))
    (is (equal '("x" "y") (setting-choices h "mode")) "and once asked, there is")))

;;; ------------------------------------------------------- bindings (S9) ;;;

(defun %press (head &rest keys)
  "Press each key in order on HEAD, as the key loop would."
  (dolist (k keys) (leticl::%normal-key head k)))

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
  "Half a ZWJ sequence is a different glyph and half a flag is a letter."
  (let ((family (format nil "~C~C~C~C~C" (%ch #x1f468) (%ch #x200d)
                        (%ch #x1f469) (%ch #x200d) (%ch #x1f467))))
    (is (string= family (truncate-to-width family 2))
        "a two-column cluster survives a two-column budget whole")
    (is (string= "" (truncate-to-width family 1))
        "and is dropped rather than halved when it does not fit")
    (is (= 2 (string-width (truncate-to-width (concatenate 'string family family) 2)))
        "two of them in a two-column budget is one of them")))

(def-test fit-reaches-exactly-the-columns-asked-for (:suite leticl)
  (is (string= "ab   " (fit-to-width "ab" 5)) "padded")
  (is (string= "abc" (fit-to-width "abcdef" 3)) "truncated")
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
    (is (search "10 a" text) "the left gutter numbers from the FILE, not the excerpt")
    (is (search "11-b" text) "the removed line is signed MINUS on the left")
    (is (search "11+B" text) "and the added line PLUS on the right")
    (is (search "│" text) "the panels are separated")
    ;; and the two SIDES differ where the change is: a bug that filled one table
    ;; from both sides drew the after-text in both panels, which looks like a
    ;; correctly aligned row and is exactly what it must not be
    (let* ((row (second (mapcar (lambda (l) (mapcar #'car l))
                                (render-split old new :width 60
                                              :old-start 10 :new-start 10))))
           (left (first row))
           (right (third row)))
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
    (is (search "+b" text) "the inserted line is signed")
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
    (is (search "-b" text) "the deleted line is signed")))

(def-test a-narrow-pane-degrades-rather-than-refusing (:suite leticl)
  "A narrow pane gets a narrow split rather than no diff — an edit drawn cramped is
still an edit the operator can read, and an edit NOT drawn is one they approved
blind — but below the point where a panel can hold a gutter and code at once it
says so instead of overprinting."
  (let ((text (%split-text (render-split (list "a" "b") (list "a" "B")
                                         :width 20 :old-start 1 :new-start 1))))
    (is (search "too narrow" text) "it says the pane is too narrow")
    (is (search "unified" text) "and names the alternative")))

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
  (let ((h (%pane-head)))
    (dolist (mode '(:help :status :config :jobs :subagents :peek :picker :todos
                    :mode-picker :models-picker))
      (setf (head-mode h) mode (head-picker-sel h) 1)
      (let ((lines (case mode
                     (:help (help-lines 210))
                     (:status (status-screen-lines h 210))
                     (:config (config-lines h (head-settings h) 210))
                     (:jobs (jobs-lines h 210))
                     (:subagents (subagent-lines h 210))
                     (:peek (peek-lines h 210))
                     (:picker (picker-lines (head-session h) (head-picker-sel h) 210))
                     (:todos (todos-lines h 210))
                     (:mode-picker (mode-picker-lines h 210))
                     (:models-picker (models-picker-lines h 210)))))
        (is (plusp (length lines)) (format nil "the ~(~a~) pane has rows" mode))
        (is (%well-formed-lines-p lines)
            (format nil "and every one of the ~(~a~) pane's segments is (string . plist)" mode))))
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
    (is (string= " 1 subagent running " (leticl::composer-title h))
        "and the box's top edge counts the same fold")))

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
    (is (= 36 (count-if (lambda (l) (plusp (length l))) text))
        "36 non-blank rows at the capture's width, as the reference has — 41 on its screen with the header and the four chrome rows")
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
    (multiple-value-bind (lines sel-line) (picker-lines s 0 210)
      (let ((text (lines-text lines)))
        (is (string= "sessions in this daemon" (first text)) "the title")
        (is (string= "" (second text)) "a blank")
        (is (uiop:string-prefix-p "▸  1  hello, what we are doing here" (third text))
            "the cursor's row: mark, number, name")
        (is (= (pane-width 210) (string-width (third text)))
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
