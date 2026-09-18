;;;; keys.lisp — terminal input decoding and the composer.
;;;;
;;;; The decoder mirrors crates/tui/src/term.rs's tables: CSI sequences,
;;;; application cursor keys, SGR mouse (?1006) and bracketed paste (?2004) —
;;;; the modes enter-tui switches on. A lone ESC is disambiguated by a short
;;;; wait: a terminal sends a sequence in one write, so silence after ESC
;;;; means ESC.

(in-package #:leticl)

(defparameter *escape-wait-ms* 60
  "How long a lone ESC waits for company before deciding it is alone.")

;;; Key events are plists: (:type :char :ch #\a), (:type :enter),
;;; (:type :ctrl :ch #\c), (:type :up), (:type :paste :text "…"),
;;; (:type :mouse :x 3 :y 7 :button 0 :kind :press) …

(defun %poll-char (stream deadline)
  "One char when one is available before DEADLINE (internal-time units).
Waits on the fd rather than polling listen — the same race wait-for-input
exists for (smoke-head, measured). nil on timeout or EOF; callers already
read nil as \"nothing came\"."
  (let ((now (get-internal-real-time)))
    (if (> now deadline)
        nil
        (when (wait-for-input stream
                              (/ (- deadline now) internal-time-units-per-second))
          (read-char stream nil nil)))))

(defun %read-csi (stream)
  "Everything after ESC[ up to the final byte (0x40-0x7E), as a string."
  (with-output-to-string (s)
    (loop
      for deadline = (+ (get-internal-real-time)
                        (* *escape-wait-ms* (/ internal-time-units-per-second) 0.001))
      for ch = (%poll-char stream deadline)
      while ch
      do (write-char ch s)
         (when (<= 64 (char-code ch) 126)
           (return)))))

(defun %decode-csi (stream params final)
  "One CSI sequence to a key event, or nil when we do not know it. 200~ is
bracketed paste's opener: the text follows, terminated by ESC[201~ — read it
here, because the paste IS the key event."
  (let ((nums (mapcar #'parse-integer-or-nil (uiop:split-string params :separator ";"))))
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
  (with-output-to-string (s)
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
             (write-char ch s)))
    (list :type :paste :text (get-output-stream-string s))))

(defun parse-integer-or-nil (s)
  (ignore-errors (parse-integer (string-trim " " s))))

(defun mouse-event (button x y kind)
  "SGR mouse encoding: button 0-2 press, 32+ motion, 64/65 wheel (term.rs's
?1002 motion + ?1006 SGR pair)."
  (cond ((>= button 64)
         (list :type :mouse :x x :y y :kind (if (= button 64) :wheel-up :wheel-down)))
        ((>= button 32)
         (list :type :mouse :x x :y y :kind :motion :button (- button 32)))
        (t
         (list :type :mouse :x x :y y :kind kind :button button))))

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

;;; ------------------------------------------------------------ composer ;;;

(defstruct (composer (:constructor make-composer ()))
  (buffer "" :type string)
  (cursor 0 :type fixnum)
  (history (make-array 0 :adjustable t :fill-pointer 0) :type vector)
  (hist-pos 0 :type fixnum))

(defun composer-insert (c string)
  (setf (composer-buffer c)
        (concatenate 'string
                     (subseq (composer-buffer c) 0 (composer-cursor c))
                     string
                     (subseq (composer-buffer c) (composer-cursor c))))
  (incf (composer-cursor c) (length string)))

(defun composer-delete-backward (c)
  (when (plusp (composer-cursor c))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (1- (composer-cursor c)))
                       (subseq (composer-buffer c) (composer-cursor c))))
    (decf (composer-cursor c))))

(defun composer-delete-forward (c)
  (when (< (composer-cursor c) (length (composer-buffer c)))
    (setf (composer-buffer c)
          (concatenate 'string
                       (subseq (composer-buffer c) 0 (composer-cursor c))
                       (subseq (composer-buffer c) (1+ (composer-cursor c)))))))

(defun composer-move (c key)
  (case key
    (:left (setf (composer-cursor c) (max 0 (1- (composer-cursor c)))))
    (:right (setf (composer-cursor c) (min (length (composer-buffer c))
                                           (1+ (composer-cursor c)))))
    (:home (setf (composer-cursor c) 0))
    (:end (setf (composer-cursor c) (length (composer-buffer c))))))

(defun composer-kill-to-end (c)
  (setf (composer-buffer c) (subseq (composer-buffer c) 0 (composer-cursor c))))

(defun composer-kill-line (c)
  (setf (composer-buffer c) (subseq (composer-buffer c) (composer-cursor c))
        (composer-cursor c) 0))

(defun composer-kill-word (c)
  "Ctrl+W: back to the start of the word before the cursor."
  (let ((i (composer-cursor c))
        (buf (composer-buffer c)))
    (loop while (and (plusp i) (char= (char buf (1- i)) #\space)) do (decf i))
    (loop while (and (plusp i) (char/= (char buf (1- i)) #\space)) do (decf i))
    (setf (composer-buffer c) (concatenate 'string (subseq buf 0 i) (subseq buf (composer-cursor c)))
          (composer-cursor c) i)))

(defun composer-push-history (c line)
  (vector-push-extend line (composer-history c))
  (setf (composer-hist-pos c) (length (composer-history c))))

(defun composer-history-step (c delta)
  "Up/Down through sent lines. The in-progress line is kept at position
`length`, so leaving history restores what was half-typed."
  (let* ((n (length (composer-history c)))
         (target (+ (composer-hist-pos c) delta)))
    (when (<= 0 target n)
      (when (= (composer-hist-pos c) n)
        (setf (get 'composer :draft) (composer-buffer c)))
      (setf (composer-hist-pos c) target)
      (setf (composer-buffer c)
            (if (= target n)
                (or (get 'composer :draft) "")
                (aref (composer-history c) target)))
      (setf (composer-cursor c) (length (composer-buffer c))))))
