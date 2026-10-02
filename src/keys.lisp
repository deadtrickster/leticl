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
         (nums (mapcar #'parse-integer-or-nil (uiop:split-string params :separator ";")))
         ;; `1;5C` — the MODIFIER is the second parameter and 5 is Ctrl
         ;; (term.rs:773). The parameters were already parsed here and the
         ;; second one was never read, so `ctrl-→` decoded as a plain `→` and
         ;; the word motion every editor binds to it moved one character.
         (ctrl (eql 5 (second nums))))
    (cond
      ((string= final "A") (list :type :up))
      ((string= final "B") (list :type :down))
      ((string= final "C") (list :type (if ctrl :word-right :right)))
      ((string= final "D") (list :type (if ctrl :word-left :left)))
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
?1002 motion + ?1006 SGR pair).

**THE MODIFIERS LIVE IN THE SAME BYTE, AND THIS DID NOT MASK THEM — so SHIFT INVERTED the wheel.**
SGR packs shift +4, meta +8, ctrl +16, motion +32 and wheel +64 into one number, and the old
classification was a `(>= button 64)` test answered by `(if (= button 64) :wheel-up :wheel-down)`:

    wheel up             64      :wheel-up     correct
    wheel down           65      :wheel-down   correct
    SHIFT + wheel up     68      :wheel-down   WRONG — the operator's jerk
    shift + wheel down   69      :wheel-down   right by accident
    ctrl  + wheel up     80      :wheel-down   wrong
    shift + drag motion  32+b+4  button (b+4)  a button id nobody has

The operator: *\"when shift holds the scrollback jerks and selection is reset\"*. Every modified
wheel-UP was reported as a wheel-DOWN, so the view ran away from the reader in the one gesture where
they were holding still — and **the selection loss followed from it**, because the runaway scroll
repainted, and a repaint is what clears a terminal's own selection. Fixing the inversion is what
makes both complaints go away.

**THE SHAPE OUTLIVES THE ARITHMETIC.** That old form was a catch-all mapping everything which is not
exactly 64 to the OPPOSITE of 64: an unrecognised code did not become *unknown*, it became a
confident wrong answer in the other direction. That is the collapse `ToolOutcome`'s closed vocabulary
exists to prevent one layer up — *a tool runtime that collapses no answer into success with an empty
payload makes that failure invisible* — and here it was visible only because the operator could feel
it.

**AND letibot DOES NOT HAVE THIS BUG, which is the lesson rather than a contrast.** `term.rs:993`
matches 64 and 65 exactly, so 68 and 69 match neither and decode to `None`. That is not better by
design; it is better by being narrow — it refuses what it does not recognise instead of guessing.

**The modifiers are masked and NOT KEPT.** `(logandc2 button 28)` clears 4, 8 and 16, and that is
the whole fix — a `:mods` field would be carried, read by nothing, and is exactly the shape letibot
DELETED rather than wired when `Preset::echo_reasoning` had been *declared once, set false three
times, and read nowhere*. If shift+wheel is ever given its own meaning, the byte is still there to
decode; a field with no reader is not a placeholder, it is a claim."
  (let* ((rest (logandc2 button 28))        ; shift 4, meta 8, ctrl 16 — who is holding what
         (motion (logand rest 32))
         (code (logandc2 rest 32)))         ; and now what the button IS
    (cond
      ;; **EXACTLY 64 AND 65.** 66 and 67 are wheel-left and wheel-right on terminals that send
      ;; them, and no arm in this tree acts on those. Naming them `:wheel-other` matches nothing,
      ;; which is the honest outcome for a gesture this head does not implement — and is the
      ;; opposite of the old catch-all, which answered them with a direction.
      ((= code 64) (list :type :mouse :x x :y y :kind :wheel-up))
      ((= code 65) (list :type :mouse :x x :y y :kind :wheel-down))
      ((>= code 64) (list :type :mouse :x x :y y :kind :wheel-other))
      ;; `(plusp motion)` AND NOT `motion`: `(logand rest 32)` returns 0 for a plain press, and
      ;; **0 is TRUE in Common Lisp**, so a bare `motion` test sent every button press down the
      ;; motion arm. The bit is a number here, not a boolean, and only NIL is false.
      ((plusp motion) (list :type :mouse :x x :y y :button code :kind :motion))
      (t (list :type :mouse :x x :y y :button code :kind kind)))))

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
           ;; TWO of them. `esc esc` is how a turn is interrupted, and a fast
           ;; double tap arrives inside the 60 ms gesture window — which fell to
           ;; the alt arm below as `(:type :alt :ch #\Esc)` and was dropped, so
           ;; the one key that stops a runaway turn did nothing for exactly the
           ;; operator who pressed it quickly. The reference names the same trap
           ;; and guards it the same way (term.rs:707-711): the first ESC is a
           ;; key on its own and the second is PUT BACK for the next read, which
           ;; then sees a lone ESC and says so.
           ((char= next +esc+)
            (unread-char next stream)
            (list :type :esc))
           ((char= next #\[)
            (let ((body (%read-csi stream)))
              (%decode-csi stream (subseq body 0 (1- (length body)))
                           (subseq body (1- (length body))))))
           ((char= next #\O)
            (let ((c (%poll-char stream
                                 (+ (get-internal-real-time)
                                    (* *escape-wait-ms* (/ internal-time-units-per-second) 0.001)))))
              ;; SS3, what a terminal sends after `smkx`. `H` and `F` were not
              ;; in the table and fell through to a lone ESC, so Home and End
              ;; did nothing on a keyboard in application mode (term.rs:715-733).
              (case (and c (char-code c))
                (65 (list :type :up))
                (66 (list :type :down))
                (67 (list :type :right))
                (68 (list :type :left))
                (72 (list :type :home))
                (70 (list :type :end))
                (t (list :type :esc)))))
           ;; The ESC-prefixed chords the composer answers, decoded here rather
           ;; than left as `(:type :alt …)` for the editor to guess at: the alt
           ;; arm inserts nothing but a newline, so every one of these was read
           ;; and thrown away (term.rs:738-743).
           ((char= next #\b) (list :type :word-left))
           ((char= next #\f) (list :type :word-right))
           ;; Ctrl+Shift+Z is byte-identical to Ctrl+Z in many terminals, so redo
           ;; needs a second binding and this is the one the reference chose.
           ((char= next #\z) (list :type :redo))
           ((or (char= next #\backspace) (char= next (code-char 127)))
            (list :type :kill-word-back))
           (t (list :type :alt :ch next)))))
      ((char= ch #\return) (list :type :enter))
      ((char= ch #\newline) (list :type :enter))
      ((char= ch #\tab) (list :type :tab))
      ((or (char= ch #\backspace) (char= ch (code-char 127))) (list :type :backspace))
      ((< (char-code ch) 32)
       (list :type :ctrl :ch (code-char (+ 96 (char-code ch)))))
      (t (list :type :char :ch ch)))))


