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
    "{\"frame\":\"attach\",\"protocol_version\":20,\"session_id\":\"\",\"since_seq\":0,\"kind\":\"tui\",\"identity\":\"\",\"caps\":{\"queue\":1024,\"can_decide\":true}}"
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
  (let ((lines (markdown-lines "# Title
- item one
```lisp
(+ 1 2)
```
> quoted
plain")))
    (is (equal (first lines) (list (cons "Title" '(:bold t :underline t)))) "heading")
    (is (member (cons "• " '(:fg :bright-cyan)) (second lines) :test #'equal) "list bullet")
    (is (member (cons "── lisp " '(:fg :bright-black)) (third lines) :test #'equal) "fence marker")
    (is (member (cons "│ " '(:fg :bright-black)) (fifth lines) :test #'equal) "blockquote")
    (is (= 6 (length lines)) "one line in, one line out per construct")))

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
               (is (search "first" (line-text (nth sel-line lines)))
                   "pointing at the selected session todo")))
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
        (is (= 3 (length lines)) "header + two rows")
        (let ((text (lines-text lines)))
          (is (search "current" text) "the current session is shown")
          (is (search "other" text) "the other session is shown")
          (is (search "●" text) "the current one is marked"))))))

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
  (is (equal (role-style 1) '(:fg :bright-black)) "comment")
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
                               (equal (cdr s) '(:fg :bright-black))))
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
    (is (equal '(:fg :bright-black) (cdr first-seg)) "and is dim, not dropped")))

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
      (is (search "leticl" text) "the top border is drawn")
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
      (is (search "grep" text) "the tool is named")
      (is (search "ok" text) "and its outcome")
      (is (search "4.1s" text)
          "and the DURATION, which only the head could have kept"))))

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
      (is (search "read" text) "the row still renders")
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
      (is (search "⚖" text) "the decision is marked on the row")
      (is (search "selected" text) "with its outcome")
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
    (setf (head-subagents h) (list (list :session-id "sub-1" :kind "task")
                                   (list :session-id "sub-2" :kind "task")))
    (setf (head-picker-sel h) 1)
    (multiple-value-bind (lines sel-line) (subagent-lines h 80)
      (is (< 1 sel-line) "the second ROW is not line 1 — there are headers above it")
      (is (< sel-line (length lines)) "and it is a line that exists")
      (is (search "sub-2" (format nil "~{~a~}" (mapcar #'car (nth sel-line lines))))
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
  (let ((*todos-open* nil))
    (let* ((with (first (leticl::%todo-row-lines (list :indent 4 :mark :open :text "x"
                                               :body (list "detail") :item t))))
           (without (first (leticl::%todo-row-lines (list :indent 4 :mark :open :text "y"
                                                  :body nil :item t)))))
      (is (search "···" (format nil "~{~a~}" (mapcar #'car with)))
          "an item with detail says there is more")
      (is (not (search "···" (format nil "~{~a~}" (mapcar #'car without))))
          "and one without stays quiet"))))

(def-test an-unfolded-item-shows-its-detail (:suite leticl)
  "The operator: *\"if a todo has some associated text? should i be able to expand
it somehow?\"*. Unfolded, the detail is drawn under the row."
  (let ((*todos-open* (list "item one")))
    (let* ((row (list :indent 4 :mark :open :text "item one"
                      :body (list "pin: abc123" "Deps: T2") :item t))
           (lines (leticl::%todo-row-lines row))
           (text (format nil "~{~a~^~%~}" (mapcar (lambda (l) (format nil "~{~a~}" (mapcar #'car l))) lines))))
      (is (= 3 (length lines)) "the row, and both detail lines")
      (is (search "pin: abc123" text) "the detail is drawn")
      (is (search "Deps: T2" text) "all of it, in file order"))))

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
  (let ((*pane-scroll* 0) (*todos-open* nil)
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
operator has to guess."
  (let* ((text (format nil "~{~a~^~%~}" (lines-text (help-lines 100)))))
    (dolist (chord '("ctrl-r" "ctrl-t" "ctrl-x" "ctrl-s" "ctrl-p" "ctrl-g"
                     "ctrl-q" "ctrl-o" "ctrl-y" "ctrl-z" "alt+enter" "esc esc"))
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
                                                                :outcome (list :outcome "denied")
                                                                :basis basis)))))
      (let ((text (segs-of (item-lines item 120 (list :show-tools t)))))
        (is (<= (count-substring basis text) 1)
            "the reason is said at most ONCE, not once per place that knows it —
and here it is not repeated at all, because the payload renders its first line
and the decision line would have been the second copy")
        (is (search "⚖ denied" text)
            "and the verdict is still there, which is what the row adds"))))
  ;; and a reason the payload does NOT carry is still said
  (let ((*item-facts* nil))
    (let ((basis "the operator declined this because the path is outside every grant the session holds"))
      (setf *item-facts* (list (cons "r2" (list :decision (list :req-id "a"
                                                                :outcome (list :outcome "denied")
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
    ;; the picker's header is one line, so screen row 2 (line 1) is row 0
    (is (= 0 (click-row->sel h :picker 1)) "the first row is the first session")
    (is (= 1 (click-row->sel h :picker 2)) "and the second is the second")
    (is (= 2 (click-row->sel h :picker 3)) "and the third")
    (is (null (click-row->sel h :picker 0)) "the header is not a row")
    (is (null (click-row->sel h :picker 4)) "nor is the blank space below")))

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
    (is (integerp (click-row->sel h :picker 1)) "a visible row is selectable")
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
