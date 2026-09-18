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

(def-test ack-seq-round-trips-the-wire (:suite leticl)
  (for-all ((n (gen-integer :min 0 :max 1000000)))
    (is (= n (getf (decode-frame (encode-frame (make-ack n 1 0))) :seq))
        "seq survives encode/decode at the protocol boundary")))

(def-test printable-ascii-is-one-column (:suite leticl)
  (for-all ((i (gen-integer :min 32 :max 126)))
    (is (= 1 (char-width (code-char i)))
        "every printable ASCII char is one column")))

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
