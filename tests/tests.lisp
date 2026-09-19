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
  (flet ((line-text (line)
           (if (null line)
               ""
               (format nil "~{~a~}" (mapcar #'car line)))))
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
               (format out "# TODO~%~%~%## Alpha~%~%~%- [ ] one~%~%- [x] two~%~%~%## Beta~%~%~%- [ ] three~%~%"))
             ;; repo-todo-lines: two sections, counted
             (let ((lines (repo-todo-lines dir)))
               (is (= 2 (length lines)) "two sections")
               (is (string= (first lines) "    Alpha — 1 open, 1 done") "alpha counts")
               (is (string= (second lines) "    Beta — 1 open, 0 done") "beta counts"))
             ;; todos-lines: the session's plan, with marks, and the repo's TODO.md
             (setf (session-todos (head-session head))
                   (list (list :content "first" :status "pending")
                         (list :content "second" :status "in_progress")
                         (list :content "third" :status "completed"))
                   (session-wiring (head-session head))
                   (list :workspace dir)))
             (let ((lines (todos-lines head 80)))
               (is (string= (line-text (first lines)) " todos ") "header")
               (is (some (lambda (l) (search "[ ] first" (line-text l))) lines)
                   "pending mark")
               (is (some (lambda (l) (search "[~] second" (line-text l))) lines)
                   "in-progress mark")
               (is (some (lambda (l) (search "[x] third" (line-text l))) lines)
                   "completed mark")
               (is (some (lambda (l) (search "Alpha — 1 open, 1 done" (line-text l))) lines)
                   "the repo's TODO.md is in the pane")))
           (ignore-errors (delete-file path)))))

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
