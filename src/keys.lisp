;;;; keys.lisp — terminal input decoding.
;;;;
;;;; The decoder mirrors crates/tui/src/term.rs's tables: CSI sequences,
;;;; application cursor keys, SGR mouse (?1006) and bracketed paste (?2004) —
;;;; the modes enter-tui switches on. A lone ESC is disambiguated by a short
;;;; wait: a terminal sends a sequence in one write, so silence after ESC means
;;;; ESC.
;;;;
;;;; The composer and the key ladder are in `editor.lisp`. This file turns bytes
;;;; into key plists and knows nothing about what a key means.

(in-package #:leticl)

(defparameter *escape-wait-ms* 60
  "How long a lone ESC waits for company before deciding it is alone.")

;;; Key events are plists: (:type :char :ch #\a), (:type :enter),
;;; (:type :ctrl :ch #\c), (:type :up), (:type :paste :text "…"),
;;; (:type :mouse :x 3 :y 7 :button 0 :kind :press) …
(defun %poll-char (stream deadline)
  "One char when one is available before DEADLINE (internal-time units).

**What is already in the buffer is taken before the clock is consulted.** The
first version checked the deadline first, and under a burst of wheel events the
input thread was stopped for longer than the 60 ms gesture window — the main
thread renders a full frame per event and the collector stops every thread — so
the byte after an ESC was on the fd, and this returned NIL anyway. `read-key` then
called the ESC a lone escape and the rest of the sequence arrived as text:
`[<65;120;30M` in the composer, once per event. Measured on the operator's head,
and reproduced with fifteen events injected into the pane: eight leaked.

Waits on the fd rather than polling listen — the same race wait-for-input exists
for (smoke-head, measured). nil on timeout or EOF; callers already read nil as
\"nothing came\"."
  (or (read-char-no-hang stream nil nil)
      (let ((now (get-internal-real-time)))
        (when (and (<= now deadline)
                   (wait-for-input stream
                                   (/ (- deadline now) internal-time-units-per-second)))
          (read-char stream nil nil)))))

(defparameter *csi-wait-ms* 1000
  "How long to wait for the NEXT byte once inside a CSI. A CSI is never a lone
escape — `ESC[` has committed to a sequence — so the gesture window that tells a
lone ESC from an ESC-prefixed key does not apply here, and a byte that is late
because the terminal, the pty or ssh split the write must still be waited for
rather than turned into text.")

(defun %read-csi (stream)
  "Everything after ESC[ up to the final byte (0x40-0x7E), as a string."
  (with-output-to-string (s)
    (loop
      for deadline = (+ (get-internal-real-time)
                        (* *csi-wait-ms* (/ internal-time-units-per-second) 0.001))
      for ch = (%poll-char stream deadline)
      while ch
      do (write-char ch s)
         (when (<= 64 (char-code ch) 126)
           (return)))))

(defun %decode-csi (stream params final)
  "One CSI sequence to a key event, or nil when we do not know it. 200~ is
bracketed paste's opener: the text follows, terminated by ESC[201~ — read it
here, because the paste IS the key event."
  ;; SGR mouse params carry a leading < (ESC[<b;x;yM); strip it so the button
  ;; parses as an integer rather than NIL.
  (let* ((params (if (and (plusp (length params)) (char= (char params 0) #\<))
                     (subseq params 1)
                     params))
         (nums (mapcar #'parse-integer-or-nil (uiop:split-string params :separator ";"))))
    (cond
      ((string= final "A") (list :type :up))
      ((string= final "B") (list :type :down))
      ((string= final "C") (list :type :right))
      ((string= final "D") (list :type :left))
      ((string= final "H") (list :type :home))
      ((string= final "F") (list :type :end))
      ((string= final "~")
       (case (first nums)
         (1 (list :type :home))
         (3 (list :type :delete))
         (4 (list :type :end))
         (5 (list :type :page-up))
         (6 (list :type :page-down))
         (7 (list :type :home))
         (8 (list :type :end))
         (200 (%read-paste stream))
         (t nil)))
      ((string= final "M")                  ; SGR mouse press/motion
       (mouse-event (first nums) (second nums) (third nums) :press))
      ((string= final "m")                  ; SGR mouse release
       (mouse-event (first nums) (second nums) (third nums) :release))
      (t nil))))

(defun %read-paste (stream)
  "Everything up to ESC[201~, as one paste event. A nested ESC that is not the
terminator is kept as content — a paste may contain anything."
  ;; with-output-to-string returns the string, not the body's value — so the
  ;; plist is built outside, around the captured text.
  (let ((text (with-output-to-string (s)
                (loop
                  for ch = (read-char stream nil nil)
                  while ch
                  do (if (char= ch +esc+)
                         (let ((next (%poll-char stream
                                                 (+ (get-internal-real-time)
                                                    (* *escape-wait-ms* (/ internal-time-units-per-second) 0.001)))))
                           (cond ((and next (char= next #\[))
                                  (let ((body (%read-csi stream)))
                                    (if (string= body "201~")
                                        (return)
                                        (progn (write-char ch s) (write-char next s)
                                               (write-string body s)))))
                                (t (write-char ch s)
                                   (when next (write-char next s)))))
                         (write-char ch s))))))
    (list :type :paste :text text)))

(defun parse-integer-or-nil (s)
  (ignore-errors (parse-integer (string-trim " " s))))

(defun mouse-event (button x y kind)
  "SGR mouse encoding: button 0-2 press, 32+ motion, 64/65 wheel (term.rs's
?1002 motion + ?1006 SGR pair)."
  (cond ((>= button 64)
         (list :type :mouse :x x :y y :kind (if (= button 64) :wheel-up :wheel-down)))
        ((>= button 32)
         (list :type :mouse :x x :y y :button (- button 32) :kind :motion))
        (t
         (list :type :mouse :x x :y y :button button :kind kind))))

(defun read-key (stream)
  "One key event from a raw terminal stream; :eof when the input closed."
  (let ((ch (read-char stream nil nil)))
    (cond
      ((null ch) (list :type :eof))
      ((char= ch +esc+)
       (let ((next (%poll-char stream
                               (+ (get-internal-real-time)
                                  (* *escape-wait-ms* (/ internal-time-units-per-second) 0.001)))))
         (cond
           ((null next) (list :type :esc))
           ((char= next #\[)
            (let ((body (%read-csi stream)))
              (%decode-csi stream (subseq body 0 (1- (length body)))
                           (subseq body (1- (length body))))))
           ((char= next #\O)
            (let ((c (%poll-char stream
                                 (+ (get-internal-real-time)
                                    (* *escape-wait-ms* (/ internal-time-units-per-second) 0.001)))))
              (case (and c (char-code c))
                (65 (list :type :up))
                (66 (list :type :down))
                (67 (list :type :right))
                (68 (list :type :left))
                (t (list :type :esc)))))
           (t (list :type :alt :ch next)))))
      ((char= ch #\return) (list :type :enter))
      ((char= ch #\newline) (list :type :enter))
      ((char= ch #\tab) (list :type :tab))
      ((or (char= ch #\backspace) (char= ch (code-char 127))) (list :type :backspace))
      ((< (char-code ch) 32)
       (list :type :ctrl :ch (code-char (+ 96 (char-code ch)))))
      (t (list :type :char :ch ch)))))


