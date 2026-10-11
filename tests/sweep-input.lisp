;;;; tests/sweep-input.lisp — the 2026-10-11 sweep's tests for the input area (TODO.md, "Sweep 2026-10-11").
(in-package #:leticl/tests)

;;; Every test here drives `%handle-key` (through `%press`) or `%submit-line` and asserts on head
;;; state or on the frames that left — the path the operator's keys actually take, not the
;;; function behind it. Each one failed on the code before its item landed; the docstrings say
;;; what the old code did.

(defun %sweep-term-head ()
  "A head with a live terminal pane and a wire to read what the keys send: the daemon's
`term_attached` is folded as it arrives, and the `term_resize` the attach sends back is drained
so each test reads only what its own keys sent."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (leticl::%handle-frame h (list :frame "term_attached" :cols 78 :rows 20))
    (%sent wire)
    (values h wire)))

(defun %term-inputs (wire)
  "The `term_input` frames on WIRE since the last read, newest first, each as the STRING its
`bytes` spell — the constructor encodes the text it is handed as UTF-8 octets (`make-term-input`,
section A of the sweep), and these tests are about which text each key hands it."
  (loop for f in (%sent wire)
        when (string= (getf f :frame) "term_input")
          collect (let ((octets (coerce (getf f :bytes) 'list)))
                    (map 'string #'code-char octets))))

;;; ------------------------------------------------------------ B.2 — the terminal's keys ;;;

(def-test ctrl-c-in-the-terminal-reaches-the-program-as-etx (:suite leticl)
  "B.2. `:term` sat in the ctrl-c close list, so the chord every shell user types to stop a
runaway program closed the PANE and the program never saw it. It goes to the program as ETX
(0x03) now, through `make-term-input` as a one-character string, and the pane stays."
  (multiple-value-bind (h wire) (%sweep-term-head)
    (is (eq :term (head-mode h)) "the attach opened the pane")
    (%press h (list :type :ctrl :ch #\c))
    (is (eq :term (head-mode h)) "**the pane is still up** — ctrl-c is the program's")
    (is (equal (list (string (code-char 3))) (%term-inputs wire))
        "**and the program got ETX**, one byte, as a string")
    (is (null (head-quit-open h)) "and nothing offered to quit the head")
    ;; the other chords a program reads go the same way — nano's ctrl-x, ctrl-o
    (%press h (list :type :ctrl :ch #\x) (list :type :ctrl :ch #\o))
    (is (equal (list (string (code-char 15)) (string (code-char 24))) (%term-inputs wire))
        "ctrl-x and ctrl-o are the program's bytes, not the head's raw-calls fold and promote")
    (is (eq :term (head-mode h)) "and the pane is still the pane")))

(def-test ctrl-backslash-detaches-and-leaves-the-program-running (:suite leticl)
  "B.2, the reference's `app/term_pane.rs`: `ctrl-\\` (0x1c, which the decoder spells `(:ctrl #\\|)`)
closes the PANE and sends NOTHING — the program keeps running on the daemon's pty and `/term`
attaches back. `q` used to send `term_close` on an empty composer, so `q` typed at a shell prompt
ENDED THE SHELL; it is the program's letter now."
  (multiple-value-bind (h wire) (%sweep-term-head)
    ;; --- q is a letter for the program
    (%press h (list :type :char :ch #\q))
    (is (eq :term (head-mode h)) "**`q` does not close the pane**")
    (let* ((sent (%sent wire))
           (frames (mapcar (lambda (f) (getf f :frame)) sent)))
      (is (not (member "term_close" frames :test #'string=))
          "**and sends no `term_close`** — a letter never ends the shell")
      (is (equal (list "term_input") frames) "one frame: the letter, to the program")
      (is (equal (list 113) (coerce (getf (first sent) :bytes) 'list)) "and it is `q`"))
    ;; --- ctrl-\ detaches
    (%press h (list :type :ctrl :ch #\|))
    (is (eq :normal (head-mode h)) "**ctrl-\\ closes the pane**")
    (is (null (%sent wire)) "**and sends nothing at all** — detaching is not ending")
    (is (head-term h) "the terminal is still known, so /term attaches back rather than opening a second")
    (is (search "still running" (head-status-note h)) "and the note says the program lives")
    ;; --- /term returns to it without a second open
    (leticl::%command h "term")
    (is (eq :term (head-mode h)) "/term attaches back")
    (is (null (find "term_open" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=))
        "with no second `term_open`")
    ;; --- esc detaches too, and ends nothing
    ;; Esc is the PROGRAM's (the reference's rule — vi, less and nano read it); the way out is ctrl-\
    (let ((inputs (count "term_input" (%sent wire) :key #'frame-name :test #'string=)))
      (%press h (list :type :esc))
      (is (= (1+ inputs) (count "term_input" (%sent wire) :key #'frame-name :test #'string=))
          "esc reaches the program as its byte")
      (is (eq :term (head-mode h)) "and does not leave the pane"))
    (%press h (list :type :ctrl :ch #\|))
    (is (eq :normal (head-mode h)) "ctrl-\\ leaves the pane")
    (is (null (find "term_close" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=))
        "and sends no `term_close` either")
    ;; --- the ending is the typed `/term close`, with the pane down or up
    (setf (composer-buffer (head-composer h)) "/term close"
          (composer-cursor (head-composer h)) 11)
    (leticl::%submit-line h)
    (is (equal (list "term_close") (mapcar (lambda (f) (getf f :frame)) (%sent wire)))
        "**`/term close` is what sends `term_close`** — the one path that ends the program")
    (is (search "ending the" (head-status-note h)) "and says it is asking for the end")))

;;; ------------------------------------------------------------ B.3 — the mouse on cards ;;;

(def-test the-allow-all-card-ignores-the-mouse (:suite leticl)
  "B.3, the reference's `key_mode_confirm` (`app/keys/cards.rs:31-36`): the card took every
non-y key as *no*, a wheel notch and a click included — `/mode allow-all`, a scroll up to reread
what it means, and the card said *allow-all not taken*. A wheel falls through to scroll and a
click is swallowed; the card stands through both, and a real key still answers."
  (let* ((leticl::*mode-confirm* "allow-all")
         (leticl::*pick-open* nil)
         (leticl::*scroll-anchor* nil) (leticl::*scroll-max* 1000)
         (h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
    (%press h (list :type :mouse :kind :wheel-up))
    (is (equal "allow-all" leticl::*mode-confirm*) "**a wheel notch leaves the card standing**")
    (is (null (%sent wire)) "and answers nothing")
    (%press h (list :type :mouse :kind :press :x 3 :y 3))
    (is (equal "allow-all" leticl::*mode-confirm*) "**a click leaves the card standing**")
    (is (null (%sent wire)) "and answers nothing either")
    (%press h (list :type :char :ch #\n))
    (is (null leticl::*mode-confirm*) "a key still cancels")
    (is (search "not taken" (head-status-note h)) "and says so")))

(defun %sweep-screen-rows (head)
  (uiop:split-string (%screen-text head) :separator '(#\newline)))

(def-test a-click-on-the-ask-cards-rung-selects-it-and-answers-nothing (:suite leticl)
  "B.3. The click router had no card arm, so a click on `▸ Allow once` fell through to the
transcript and did nothing while the picker card one row over took clicks. A click selects the
rung — Enter still answers — and a click on the card's hint row selects nothing."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (leticl::*card-scroll* 0) (leticl::*card-scroll-for* nil)
         (h (%on-head :cols 100 :rows 24))
         (wire (%wire h)))
    (setf (session-open-decisions (head-session h)) (list (%decision-with))
          (leticl::head-decision-sel h) 0)
    (leticl::%render h)
    (let* ((rows (%sweep-screen-rows h))
           (always (position-if (lambda (l) (search "Always allow  (allow_always)" l)) rows))
           (deny (position-if (lambda (l) (search "Deny  (deny)" l)) rows))
           (hint (position-if (lambda (l) (search "to choose" l)) rows)))
      (is (integerp always) "the second rung is on the screen")
      (%press h (list :type :mouse :kind :press :x 6 :y always))
      (is (= 1 (leticl::head-decision-sel h)) "**the click selected the rung under the pointer**")
      (is (null (%sent wire)) "**and answered nothing** — select and confirm are two acts")
      (%press h (list :type :mouse :kind :press :x 6 :y deny))
      (is (= 3 (leticl::head-decision-sel h))
          "`Deny` is the fourth rung, not the third — the longer label's row is not claimed by the shorter")
      (when hint
        (%press h (list :type :mouse :kind :press :x 6 :y hint))
        (is (= 3 (leticl::head-decision-sel h)) "a click on the hint row moves nothing"))
      (is (session-open-decisions (head-session h)) "the ask is still open"))))

(def-test a-click-on-the-quit-card-selects-a-choice-and-leaves-nothing (:suite leticl)
  "B.3. The quit card owns every key, so a click reached nothing; it selects the choice under
the pointer now — the dim consequence under a choice counts as that choice — and takes nothing:
the head is still running and the card is still up."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (h (%on-head :cols 100 :rows 24))
         (wire (%wire h)))
    (setf (head-quit-open h) t (leticl::head-quit-sel h) 0)
    (leticl::%render h)
    (let* ((rows (%sweep-screen-rows h))
           (stop (position-if (lambda (l) (search "leave and stop the daemon" l)) rows))
           (leave (position-if (lambda (l) (search "leave this head" l)) rows)))
      (is (integerp stop) "the second choice is on the screen")
      (%press h (list :type :mouse :kind :press :x 6 :y stop))
      (is (= 1 (leticl::head-quit-sel h)) "**the click selected the second choice**")
      (is (head-quit-open h) "and the card is still up")
      (is (leticl::head-running h) "and the head is still running — nothing was taken")
      (is (null (%sent wire)) "and the daemon was asked nothing")
      ;; the consequence row under the first choice is that choice
      (%press h (list :type :mouse :kind :press :x 6 :y (1+ leave)))
      (is (= 0 (leticl::head-quit-sel h)) "a click on a choice's consequence line selects that choice")
      ;; a wheel is swallowed, card up — the fail-closed rule
      (%press h (list :type :mouse :kind :wheel-down))
      (is (head-quit-open h) "a wheel notch does not take the card down"))))

(def-test a-click-on-the-verbosity-card-maps-two-rows-to-one-rung (:suite leticl)
  "B.3. `%pick-click` assumed one row per choice while the verbosity card draws two — the rung and
its gloss (`pick-card-lines`, R38) — so a click on `loud` selected a rung two above it and a click
on a gloss line fell between two. The card's own layout decides now: either row of a pair is the
rung."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (h (%on-head :cols 100 :rows 30))
         (wire (%wire h)))
    (open-pick h :verbosity)
    (%sent wire)                        ; the open asks for the settings rows; not this test's
    (leticl::%render h)
    (let* ((rows (%sweep-screen-rows h))
           (loud (position-if (lambda (l) (search "  loud" l)) rows))
           (terse (position-if (lambda (l) (search "  terse" l)) rows)))
      (is (integerp loud) "the last rung is on the screen")
      (%press h (list :type :mouse :kind :press :x 6 :y loud))
      (is (= 4 (head-picker-sel h)) "**`loud` is the fifth rung, and the click lands on it**")
      (%press h (list :type :mouse :kind :press :x 6 :y (1+ loud)))
      (is (= 4 (head-picker-sel h)) "**and its gloss line is the same rung**")
      (%press h (list :type :mouse :kind :press :x 6 :y terse))
      (is (= 2 (head-picker-sel h)) "`terse` is the third")
      (is (eq :verbosity leticl::*pick-open*) "the card stays open")
      (is (null (%sent wire)) "and nothing was taken"))))

;;; ------------------------------------------------------ B.4 / B.5 — a row read whole ;;;

(def-test enter-on-your-own-todo-opens-it-whole-and-esc-returns-to-the-row (:suite leticl)
  "B.4 (the reference's `todos_open_lines`). `pane-enter` on the todos pane knew `:add` and
`:repo` only, so Enter on the operator's own row did nothing and a title or detail wider than the
pane was cut at the right edge and read by nobody. Enter opens the row whole over the list; Esc
returns to the list with the cursor where it was, and the list's letters are inert meanwhile."
  (let* ((leticl::*operator-todos*
           (list (list :id "t1" :content "check the daemon log, not the head's" :detail "the one under /var/tmp, after the restart that lost the socket" :status "open")))
         (leticl::*read-overlay* nil) (leticl::*repo-todo-open* nil) (leticl::*todo-draft* nil)
         (leticl::*todos-hide-done* nil) (leticl::*pane-scroll* 0) (leticl::*pane-room* 20)
         (h (%on-head :cols 100 :rows 24))
         (wire (%wire h)))
    (setf (head-mode h) :todos (head-picker-sel h) 1) ; stop 0 is the add control, 1 is t1
    (%press h (list :type :enter))
    (is (eq :todos (head-mode h)) "**the mode is still the pane's** — the view is over the list, not a mode")
    (is (not (null leticl::*read-overlay*)) "**and the row is open whole**")
    (let ((text (lines-text (leticl::pane-lines (leticl::pane-for :todos) h 100 24))))
      (is (some (lambda (l) (search "check the daemon log" l)) text) "the title is drawn")
      (is (some (lambda (l) (search "after the restart that lost the socket" l)) text)
          "**and the detail, whole**")
      (is (some (lambda (l) (search "esc returns to the list" l)) text) "and the way back is named"))
    (is (null (%sent wire)) "no frame went out — the row is the head's own")
    ;; the list's letters do not act on the row behind the view
    (%press h (list :type :char :ch #\space))
    (is (equal "open" (getf (first leticl::*operator-todos*) :status))
        "space does not mark the row nobody can see")
    (%press h (list :type :esc))
    (is (null leticl::*read-overlay*) "**esc closes the view**")
    (is (eq :todos (head-mode h)) "and the list is back")
    (is (= 1 (head-picker-sel h)) "**on the row the reader chose**")))

(def-test enter-on-a-standing-note-opens-it-whole (:suite leticl)
  "B.5. The standing-notes pane had a cursor and no Enter. Enter opens the note's row whole —
path, form, the abstract unwrapped, and whose line the abstract is — and Esc returns to the row.
No frame goes out: the fields are the ones `standing_notes` delivered."
  (let* ((leticl::*read-overlay* nil) (leticl::*pane-scroll* 0) (leticl::*pane-room* 20)
         (h (%on-head :cols 100 :rows 24))
         (wire (%wire h)))
    (setf (head-standing-notes h)
          (list (list :path "/n/one.md" :form "verbatim" :abstract "a" :abstract-written t)
                (list :path "/n/two.md" :form "indexed"
                      :abstract "the second note's abstract, which the pane's row would have cut at its edge had it been any longer than this"
                      :abstract-written nil))
          (head-mode h) :standing
          (head-picker-sel h) 1)
    (%press h (list :type :enter))
    (is (eq :standing (head-mode h)) "the mode is still the pane's")
    (is (not (null leticl::*read-overlay*)) "**the note is open whole**")
    (let* ((lines (lines-text (leticl::pane-lines (leticl::pane-for :standing) h 100 24)))
           (text (format nil "~{~a~^ ~}" lines)))
      (is (search "/n/two.md" text) "the second note — the one under the cursor")
      (is (and (search "the second note's abstract" text) (search "longer than this" text))
          "its abstract, whole — head and tail both on the view (wrapped, never cut)")
      (is (search "derived by the harness" text)
          "and whose line it is — the harness's reading, not the author's")
      (is (not (search "/n/one.md" text)) "and not the other note"))
    (is (null (%sent wire)) "no frame went out")
    (%press h (list :type :esc))
    (is (null leticl::*read-overlay*) "esc closes the view")
    (is (eq :standing (head-mode h)) "the list is back")
    (is (= 1 (head-picker-sel h)) "on the row the reader chose")))

(def-test a-long-todo-title-is-capped-where-it-is-written (:suite leticl)
  "B.4, the reference's `title_refusal` (`app/todos.rs:390`): a title is at most 135 characters —
the width the pane draws a row at — and the rest is the DETAIL. Applied on the card's Enter, where
this head writes the row: the row that lands has a title within the cap, the overflow at the head
of its detail, and the operator is told."
  (let* ((leticl::*operator-todos* nil)
         (leticl::*todo-draft* nil) (leticl::*write-prefs* nil)
         (h (%on-head :cols 100 :rows 24))
         (leticl::*head* h)                 ; `operator-todo-add` pushes the board through `*head*`
         (wire (%wire h))
         (words (format nil "~{~a~^ ~}" (loop repeat 40 collect "word")))) ; 199 characters
    (setf (session-session-id (head-session h)) "s-1")
    (leticl::%todo-draft-open h)
    (setf (composer-buffer (head-composer h)) words
          (composer-cursor (head-composer h)) (length words))
    (%press h (list :type :enter))
    (is (= 1 (length leticl::*operator-todos*)) "the row was added")
    (let ((item (first leticl::*operator-todos*)))
      (is (<= (length (getf item :content)) 135) "**the title is within the cap**")
      (is (uiop:string-prefix-p (getf item :content) words) "and is the head of what was typed")
      (is (plusp (length (getf item :detail))) "**the rest became the detail**")
      (is (string= words (format nil "~a ~a" (getf item :content) (getf item :detail)))
          "nothing was lost between the two"))
    (is (search "at most 135" (head-status-note h)) "and the operator is told")
    (is (null leticl::*todo-draft*) "the card closed")
    (is (find "set_operator_todos" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=)
        "and the board was pushed")))

;;; ------------------------------------------------------------------ B.9 — /help rows ;;;

(def-test the-help-names-the-chords-and-verbs-it-was-missing (:suite leticl)
  "B.9. `ctrl-g`, `ctrl-j` (the jobs pane — the operator's ruling, not ctrl-q), `ctrl-o`, `/queue`,
`/standing` and `/term` were bound and taught nowhere; the wheel row said *the transcript* when the
wheel has scrolled panes and cards for as long as they existed; the click row named one surface of
the nine. The help is the contract page, and a key it does not name is a key nobody presses."
  (let ((text (format nil "~{~a~^~%~}" (lines-text (help-lines 200)))))
    (dolist (row '("ctrl-g" "ctrl-j" "ctrl-o" "/queue" "/standing" "/term"))
      (is (search row text) (format nil "the help names ~a" row)))
    (is (not (search "ctrl-q" text)) "and not ctrl-q, which is nobody's")
    (is (search "whatever is in front" text) "the wheel row says it scrolls what is in front")
    (dolist (surface '("session list" "todos" "config" "picker card" "rungs" "quit card" "dashboard" "jobs running"))
      (is (search surface text) (format nil "the click row names the ~a" surface)))
    (is (search "ctrl-\\ detaches" text) "and the /term row teaches the way out")))

;;; ------------------------------------------------------- B.10 — the review's open highs ;;;

(def-test enter-does-not-answer-a-prompt-whose-card-is-away (:suite leticl)
  "The review, dispatch.lisp:51. The esc arm was gated on `*prompt-away*` and the Enter arm was
not, so with the card put away the operator's line went to the running command instead of being
held — the reference gates both. Card away, a line, Enter: nothing is sent, the request stays
open, the words stay in the composer."
  (let* ((h (%on-head :cols 90 :rows 24))
         (wire (%wire h))
         (leticl::*prompt-away* nil))
    (leticl::%handle-frame h (list :frame "event" :seq 1 :event "prompt_requested"
                                   :req-id "r1" :job "j1" :command "apt install mc"
                                   :question "Continue? [Y/n]" :reading "blocked"))
    (%press h (list :type :esc))
    (is (eq t leticl::*prompt-away*) "the card is away")
    (setf (composer-buffer (head-composer h)) "y"
          (composer-cursor (head-composer h)) 1)
    (%press h (list :type :enter))
    (is (null (find "prompt_answer" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=))
        "**no `prompt_answer` went out** — the card is away, so Enter is not answering it")
    (is (leticl::head-prompt-req h) "the request is still open")
    (is (string= "y" (composer-buffer (head-composer h))) "and the words are held, not spent")
    ;; the card back up, Enter answers
    (setf leticl::*prompt-away* nil)
    (%press h (list :type :enter))
    (is (find "prompt_answer" (%sent wire) :key (lambda (f) (getf f :frame)) :test #'string=)
        "with the card up, Enter answers")))

(def-test ctrl-c-closes-the-dashboard-and-ctrl-d-asks-before-leaving (:suite leticl)
  "Two of the review's highs. `:dash` was missing from the ctrl-c close list, so ctrl-c on the
dashboard offered to quit the head; and `ctrl-d` on an empty composer set `head-running` to NIL
at once, where `ctrl-c ctrl-c` on the same empty composer opens the card that asks *leave, or
leave and stop the daemon?* — the reference routes both through the card."
  (let* ((leticl::*dash-nav* (list :sel 0 :scroll 0 :open nil))
         (leticl::*ctrlc-at* nil)
         (h (%on-head :cols 80 :rows 24)))
    (setf (head-mode h) :dash)
    (%press h (list :type :ctrl :ch #\c))
    (is (eq :normal (head-mode h)) "**ctrl-c closes the dashboard**")
    (is (null (head-quit-open h)) "and does not offer to quit")
    ;; ctrl-d on an empty composer: the card, not the exit
    (%press h (list :type :ctrl :ch #\d))
    (is (leticl::head-running h) "**ctrl-d does not leave at once**")
    (is (head-quit-open h) "**it opens the quit card**")
    (is (= 0 (leticl::head-quit-sel h)) "on `leave this head`")
    (%press h (list :type :esc))
    (is (null (head-quit-open h)) "and esc stays, as the card's hint says")
    (is (leticl::head-running h) "still running")))

(def-test bang-send-is-a-word-not-a-prefix (:suite leticl)
  "The review, submit.lisp:92. `!send` matched five raw characters, so `!sender foo` reached the
running command as `er foo` and a bare `!send` ran a shell command called `send`. The word, then a
space or the end: `!sender foo` is the operator's shell command, bare `!send` is refused with a
note, `!send y` still answers."
  (let* ((h (%on-head :cols 80 :rows 24))
         (wire (%wire h)))
   ;; `make-operator-shell` reads the live image's `*session*`, which is never defvar'd — PROGV
   ;; is the one spelling that binds it dynamically (the paste tests' own note)
   (progv '(leticl::*session*) (list (head-session h))
    (flet ((submit (line)
             (setf (composer-buffer (head-composer h)) line
                   (composer-cursor (head-composer h)) (length line))
             (leticl::%submit-line h)
             (%sent wire)))
      (let ((sent (submit "!sender foo")))
        (is (equal "operator_shell" (getf (first sent) :frame))
            "**`!sender foo` is a shell command**, not a send")
        (is (equal "!sender foo" (getf (first sent) :line)) "sent verbatim, bang included"))
      (setf (head-status-note h) nil)
      (let ((sent (submit "!send")))
        (is (null sent) "**bare `!send` sends nothing** — not an empty line to the command, not a shell command")
        (is (search "needs the line" (head-status-note h)) "and says what it needs"))
      (let ((sent (submit "!send y")))
        (is (equal "send_line" (getf (first sent) :frame)) "`!send y` still answers")
        (is (equal "y" (getf (first sent) :line)) "with the line"))))))

(def-test marker-seam-flips-from-the-config-pane (:suite leticl)
  "The review, config.lisp:70-87. The pane drew the row with the edit mark and `%flip-head-setting`
had no arm for it: Enter wrote head.toml, changed nothing, and reported the value unchanged.
`%set-marker-seam` is its writer, and the pane calls it now."
  (let* ((leticl::*marker-seam* nil)
         (leticl::*write-prefs* nil)
         (leticl::*prefs* (make-prefs))
         (h (%make-head)))
    (is (string= "hidden" (leticl::%head-setting-value h "marker_seam")) "off to start")
    (leticl::%flip-head-setting h "marker_seam")
    (is (eq t leticl::*marker-seam*) "**the flip reached the seam's own writer**")
    (is (string= "shown" (leticl::%head-setting-value h "marker_seam")) "and the row says so")
    (leticl::%flip-head-setting h "marker_seam")
    (is (null leticl::*marker-seam*) "and back")))

(def-test an-ask-claims-the-page-keys-only-when-its-card-can-scroll (:suite leticl)
  "The review, overlay-keys.lisp:65-72. The ask's page and wheel arms were gated on an empty
composer alone, so a four-line permission card that fit on the screen still took PgDn and the
wheel away from the transcript for as long as it stood. A card with nothing out of view hands the
keys back to the transcript; a card with a seam keeps them."
  (let* ((leticl::*stdout* (make-string-output-stream))
         (leticl::*card-scroll* 0) (leticl::*card-scroll-for* nil)
         (leticl::*scroll-anchor* nil) (leticl::*scroll-max* 1000)
         (leticl::*pick-open* nil) (leticl::*mode-confirm* nil)
         (h (%on-head :cols 100 :rows 24)))
    ;; --- a short card: the transcript scrolls
    (setf (session-open-decisions (head-session h)) (list (%decision-with))
          (head-scroll h) 0)
    (leticl::%render h)
    (is (not (leticl::%card-scrollable-p h)) "a card that fits has nothing out of view")
    (%press h (list :type :page-down))
    (is (= 0 leticl::*card-scroll*) "**the card did not move** — it had nowhere to go")
    (%press h (list :type :page-up))
    (is (plusp (head-scroll h)) "**and the transcript did** — the key fell through to it")
    (%press h (list :type :mouse :kind :wheel-up))
    (is (= 0 leticl::*card-scroll*) "the wheel leaves a card that fits alone")
    ;; --- a tall card: the card scrolls, as before
    (setf (head-scroll h) 0 leticl::*card-scroll* 0)
    (%r20-card h)
    (leticl::%render h)
    (is (leticl::%card-scrollable-p h) "a card with a seam can scroll")
    (%press h (list :type :page-down))
    (is (plusp leticl::*card-scroll*) "and PgDn pages it")
    (is (= 0 (head-scroll h)) "not the transcript")))

(def-test esc-in-the-terminal-reaches-the-program-and-only-ctrl-backslash-detaches (:suite leticl)
  "The reference forwards Esc to the program (`app/term_pane.rs`): `vi` leaves insert mode on it,
`less` and `nano` read it. A first cut of the sweep made Esc detach, which is a terminal `vi`
cannot be used in. Esc goes out as its byte; `ctrl-\\` is the one way out."
  (let* ((h (%make-head))
         (wire (%wire h)))
    (setf (head-term h) (list :cols 80 :rows 20 :output "") (head-mode h) :term)
    (leticl::%handle-key h (list :type :esc))
    (let ((sent (remove "term_input" (%sent wire) :key #'frame-name :test-not #'string=)))
      (is (= 1 (length sent)) "Esc went to the program as a term_input")
      (is (eq :term (head-mode h)) "and the pane stays up"))
    (leticl::%handle-key h (list :type :ctrl :ch #\|))
    (is (eq :normal (head-mode h)) "ctrl-\\ detaches")
    (is (head-term h) "and the program is still this session's — nothing ended it")))

(def-test the-queue-panes-letters-and-tab-act-on-the-row-under-the-cursor (:suite leticl)
  "`a`/`v`/`d`/`r` on an empty composer send the daemon's verb for the selected row through the
same path `/queue VERB ID` takes (reference 74de81a: verb letters only on an empty composer), and
Tab flips the view between the two queues (the reference's tab strip)."
  (let* ((h (%make-head))
         (wire (%wire h)))
    (setf (head-connected h) t (head-mode h) :queue)
    (setf (leticl::head-merge-queue h)
          ;; a review-queue branch waiting for a verdict: the one row `approve` acts on
          (list (list :id "e1" :state "waiting" :kind "branch" :branch "topic-a" :queue "review")))
    (setf (head-picker-sel h) 0)
    (let ((before (length (%sent wire))))
      (leticl::%handle-key h (list :type :char :ch #\a))
      (is (> (length (%sent wire)) before) "a sends something for the row under the cursor: ~s"
          (mapcar #'frame-name (%sent wire))))
    (let ((view leticl::*queue-view*))
      (leticl::%handle-key h (list :type :tab))
      (is (not (eq view leticl::*queue-view*)) "Tab flips the view")
      (leticl::%handle-key h (list :type :tab))
      (is (eq view leticl::*queue-view*) "and back"))))
