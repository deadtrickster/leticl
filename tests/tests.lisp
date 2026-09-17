;;;; tests/tests.lisp — asserts on cell buffers and emitted escape strings
;;;; (PLAN.md §11). Protocol goldens are hand-written from the serde semantics:
;;;; field order is irrelevant to us, presence is not.

(in-package #:leticl/tests)

;;; ------------------------------------------------------------- width ;;;

(deftest width-ascii-is-one
  (check= 1 (char-width #\a) "ascii")
  (check= 1 (char-width #\space) "space")
  (check= 5 (string-width "hello") "string"))

(deftest width-control-is-zero
  (check= 0 (char-width (code-char 7)) "bell")
  (check= 0 (char-width (code-char #x7f)) "del")
  (check= 0 (char-width (code-char #x85)) "c1 NEL"))

(deftest width-cjk-is-two
  (check= 2 (char-width (code-char #x4e00)) "CJK ideograph")
  (check= 2 (char-width (code-char #x3042)) "hiragana")
  (check= 2 (char-width (code-char #xac00)) "hangul")
  (check= 2 (char-width (code-char #xff21)) "fullwidth A"))

(deftest width-zero-width
  (check= 0 (char-width (code-char #x301)) "combining acute")
  (check= 0 (char-width (code-char #x200d)) "ZWJ")
  (check= 0 (char-width (code-char #xfe0f)) "variation selector"))

(deftest width-emoji
  (check= 2 (char-width (code-char #x1f680)) "rocket")
  (check= 2 (char-width (code-char #x2757)) "heavy exclamation"))

;;; ------------------------------------------------------------- cells ;;;

(deftest put-string-advances-by-width
  (let ((s (make-screen 20 1)))
    (check= 4 (screen-put-string s 0 0 "a漢b") "a(1) 漢(2) b(1)")
    (check= #\a (cell-ch (screen-cell s 0 0)))
    (check= (code-char 0) (cell-ch (screen-cell s 0 2)) "wide continuation")
    (check= #\b (cell-ch (screen-cell s 0 3)))))

(deftest put-string-wide-at-edge-degrades
  (let ((s (make-screen 3 1)))
    ;; "ab漢" — the 漢 would need columns 2 and 3; only 2 exists
    (check= 3 (screen-put-string s 0 0 "ab漢"))
    (check= #\a (cell-ch (screen-cell s 0 0)))
    (check= #\b (cell-ch (screen-cell s 0 1)))
    (check= #\space (cell-ch (screen-cell s 0 2)) "degraded to space")))

(deftest put-out-of-range-is-dropped
  (let ((s (make-screen 4 2)))
    (screen-put s 5 0 #\x)
    (screen-put s 0 9 #\x)
    (check= #\space (cell-ch (screen-cell s 0 0)) "nothing written")))

;;; ------------------------------------------------------------ painter ;;;

(defun esc-seq (&rest params)
  (format nil "~C[~{~a~}" (code-char 27) params))

(deftest paint-diff-blank-to-text
  (let ((cur (make-screen 10 2)))
    (screen-put-string cur 0 0 "ab")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      ;; move to row1 col1, write "ab", then the trailing reset
      (check= (format nil "~C[1;1Hab~C[0m" (code-char 27) (code-char 27))
              (get-output-stream-string out)
              "one run, one move"))))

(deftest paint-diff-emits-sgr-on-style-change
  (let ((cur (make-screen 10 1))
        (bold-cyan (style-index '(:bold t :fg :cyan))))
    (screen-put cur 0 0 #\x 0)
    (screen-put cur 0 1 #\y bold-cyan)
    (with-output-to-string (out)
      (paint-diff nil cur out :sync nil)
      (check= (format nil "~C[1;1Hx~C[0;1;36my~C[0m" (code-char 27) (code-char 27) (code-char 27))
              (get-output-stream-string out)
              "default then bold-cyan"))))

(deftest paint-diff-writes-only-changes
  (let ((prev (make-screen 10 1))
        (cur (make-screen 10 1)))
    (screen-put-string prev 0 0 "abcdef")
    (screen-put-string cur 0 0 "abXdef")
    (with-output-to-string (out)
      (paint-diff prev cur out :sync nil)
      (check= (format nil "~C[1;3HX~C[0m" (code-char 27) (code-char 27))
              (get-output-stream-string out)
              "only the X moves and writes"))))

(deftest paint-diff-sync-wraps-in-2026
  (let ((cur (make-screen 4 1)))
    (screen-put-string cur 0 0 "hi")
    (with-output-to-string (out)
      (paint-diff nil cur out :sync t)
      (check= (format nil "~C[?2026h~C[1;1Hhi~C[0m~C[?2026l"
                      (code-char 27) (code-char 27) (code-char 27) (code-char 27))
              (get-output-stream-string out)
              "synchronized output brackets the frame"))))

;;; --------------------------------------------------------------- json ;;;

(deftest json-encode-frame-golden
  (check= "{\"frame\":\"ack\",\"seq\":3,\"rendered\":1,\"filtered\":2}"
          (json-encode-to-string (list :frame "ack" :seq 3 :rendered 1 :filtered 2))
          "field order follows the plist, keys snake_case"))

(deftest json-encode-nil-is-null-never-elided
  (check= "{\"a\":null}" (json-encode-to-string (list :a nil))
          "absent and empty must not be the same bytes"))

(deftest json-encode-keyword-value-is-snake-string
  (check= "{\"status\":\"in_progress\"}"
          (json-encode-to-string (list :status :in_progress))
          "enum vocabulary travels as snake_case strings"))

(deftest json-encode-nested-and-arrays
  (check= "{\"caps\":{\"queue\":1024,\"can_decide\":true},\"rows\":[\"a\",\"b\"]}"
          (json-encode-to-string
           (list :caps (list :queue 1024 :can-decide t) :rows (list "a" "b")))
          "plist inside, list array outside"))

(deftest json-decode-keys-become-keywords
  (let ((p (json-decode "{\"frame\":\"hello\",\"session_id\":\"s-1\",\"dropped\":0}")))
    (check= "hello" (getf p :frame))
    (check= "s-1" (getf p :session-id))
    (check= 0 (getf p :dropped))))

(deftest json-round-trip
  (let ((frame (list :frame "prompt" :client-request-id "r1" :expected-seq 12
                     :text "héllo 漢")))
    (check= frame (json-decode (json-encode-to-string frame))
            "unicode survives, keys normalize back")))

;;; --------------------------------------------------------------- wire ;;;

(deftest wire-skips-blank-lines
  (with-input-from-string (in (format nil "~%~%~a~%" "{\"a\":1}"))
    (multiple-value-bind (line eof) (read-frame in)
      (check= nil eof)
      (check= "{\"a\":1}" line))))

(deftest wire-eof-is-detach-not-error
  (with-input-from-string (in "")
    (multiple-value-bind (line eof) (read-frame in)
      (check= :eof eof "the second value names the close")
      (check= nil line))))

(deftest wire-crlf-trimmed
  (with-input-from-string (in (format nil "{\"a\":1}~a~%" #\return))
    (check= "{\"a\":1}" (read-frame in))))

;;; ------------------------------------------------------------ protocol ;;;

(deftest attach-golden
  (check=
   "{\"frame\":\"attach\",\"protocol_version\":18,\"session_id\":\"\",\"since_seq\":0,\"kind\":\"tui\",\"identity\":\"\",\"caps\":{\"queue\":1024,\"can_decide\":true}}"
   (encode-frame (make-attach))
   "defaults, serde-default fields omitted, caps present"))

(deftest ack-golden
  (check= "{\"frame\":\"ack\",\"seq\":7,\"rendered\":3,\"filtered\":4}"
          (encode-frame (make-ack 7 3 4))))

(deftest prompt-golden
  (let* ((frame (let ((*request-counter* 0)) (make-prompt 12 "hello")))
         (json (encode-frame frame)))
    (check= "{\"frame\":\"prompt\",\"client_request_id\":\"leticl-1\",\"expected_seq\":12,\"text\":\"hello\"}"
            json)
    (check= "leticl-1" (getf frame :client-request-id))))

(deftest answer-with-pattern-golden
  (check=
   "{\"frame\":\"answer\",\"client_request_id\":\"leticl-2\",\"req_id\":\"d1\",\"option_id\":\"allow_always\",\"pattern\":\"crates/**/*.rs\"}"
   (encode-frame (let ((*request-counter* 1)) (make-answer "d1" "allow_always" "crates/**/*.rs")))
   "the operator's own glob travels only when given"))

(deftest decode-hello-shape
  (let ((hello (decode-frame
                "{\"frame\":\"hello\",\"protocol_version\":18,\"session_id\":\"s-1\",\"head_id\":\"h1\",\"dropped\":0,\"snapshot\":null,\"resumed_from\":null,\"scrubbed\":{\"events\":0,\"items\":0},\"wiring\":{\"endpoint\":\"\",\"model\":\"\",\"dialect\":\"\",\"role\":\"\"},\"sessions\":[]}")))
    (check= "hello" (frame-name hello))
    (check= 0 (getf hello :dropped) "present and zero, the disclosure")
    (check= nil (getf hello :snapshot))))

(deftest decode-malformed-keeps-the-line
  (handler-case (decode-frame "{\"frame\":\"nope")
    (wire-error (e)
      (check= "{\"frame\":\"nope" (wire-error-line e) "the offending line is kept")
      t)
    (:no-error (v) (declare (ignore v)) (error "should have raised wire-error"))))

(deftest screen-answer-golden
  (check=
   "{\"frame\":\"screen\",\"req_id\":\"q1\",\"cols\":3,\"rows_n\":1,\"rows\":[\"abc\"]}"
   (encode-frame (make-screen-answer "q1" (list "abc")))))
