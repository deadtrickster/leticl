;;;; pick.lisp — the pickers: a list of choices the operator answers by number or name
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.

(in-package #:leticl)

;;; ------------------------------------------------------------ pickers ;;;
;;;
;;; The MODE and MODELS pickers, to the reference's shape (`mode_picker_lines`,
;;; app.rs): a CARD above the composer with the transcript still visible, not a
;;; full-body pane — the operator, looking at ours: *"in letibot it is not a full
;;; pane"*. Both read their choices from the daemon's own settings rows
;;; (`SettingRow.choices`, protocol 18), so the head keeps no list to drift.
;;;
;;; One flag for both, one cursor (`head-picker-sel`), one drawing, because the
;;; one thing this file has already been burned by is a second copy of a list that
;;; then drifts. The flag is a defvar: a head slot is a struct layout change, which
;;; is a restart.

(defvar *pick-unseeded* nil
  "Has the picker's cursor been placed by US, with nobody having moved it yet?

T when `open-pick` could not compute the seed — its list had not arrived — so the settings arm may
place it once the rows land, and any key that moves the cursor clears it so a move the operator made
is never overwritten. Reset by `close-pick` and by `with-replay-globals`.")

(defvar *pick-open* nil
  "Which picker is up: NIL, `:mode`, `:model` or `:verbosity`.

**Three, and `:verbosity` joined last** (R38). It is the same card and the same keys rather than a
fourth mechanism, because the requirement's own words are *one picker vocabulary per head, not a
third*: a reader who has chosen a mode has learned how to choose a verbosity.")

(defvar *mode-confirm* nil
  "The mode name awaiting the operator's [y]/[enter], or NIL. `allow-all` is the
one mode that asks first — it is the point where privilege escalation, deletes
outside the project and first contact with a new host all stop asking.")

(defun setting-choices (head key)
  "The choices the daemon reports for setting KEY, or NIL.

From the settings rows the head asks for at attach, which is why it asks: a
picker whose list is empty because nobody ever asked the daemon is a picker that
looks broken (P44 in TODO.md is the same bug one layer down)."
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :choices)))

(defun setting-value (head key)
  (let ((row (and (head-settings head)
                  (find key (head-settings head)
                        :key (lambda (r) (getf r :key)) :test #'string=))))
    (getf row :value)))

(defun pick-key (which)
  "The DAEMON's settings key a picker reads its choices from, or NIL for a choice that is the
head's own.

**`verbosity` is not a daemon setting**, so it has no key — and that is a fact about which half
owns the value rather than a gap. The mode and the model arrive on rows the daemon publishes; what
this head draws is its own business, so its choices are its own list."
  (ecase which (:mode "mode") (:model "model") (:verbosity nil)))

(defparameter +verbosity-said+
  '(("reading" . "the conversation only — nothing the head did to produce it")
    ;; **OURS, not letibot's**: it names a rung this head has and that one does not (yet), so
    ;; there is no reference sentence to borrow — and it has to say the one thing that separates it
    ;; from the row above it, because that difference IS the setting.
    ("read-edits" . "the conversation and the cards that say what the head changed")
    ("terse" . "the conversation and every tool row")
    ("normal" . "terse, plus the model's reasoning")
    ("loud" . "normal, plus head arrivals and who issued each command"))
  "What each rung MEANS, in the reader's terms — R38's requirement, and the reason this card is not
just a list of names.

*Terse, Normal, Loud and R37's rung are not self-describing*, and a reader is choosing between what
will be on their screen. So each row says what they will see. **The three sentences are letibot's
own** (`Verbosity`'s variant docstrings: *assistant text and tool outcomes only*, *plus reasoning*,
*plus head arrivals and who issued which command*), because a setting spelled differently on two
heads is two settings — and the fourth is this head's, pending the name letibot owes (filed).")

(defun pick-choices (head &optional (which *pick-open*))
  "The rows the picker offers: the daemon's choices for its settings, or this head's own ladder."
  (when which
    (if (eq which :verbosity)
        (mapcar (lambda (v) (string-downcase (symbol-name v))) +verbosity-ladder+)
        (setting-choices head (pick-key which)))))

(defun pick-current (head &optional (which *pick-open*))
  "The choice that answers NOW, as the picker's list spells it: the mode row's
value is `allow-all (this box, consented)` and the list says `allow-all`, so the
first word; the model row's is `local (qwen-3.8-27b)` or `deepseek/…`, and the
list says the bare form the header shows."
  (ecase which
    (:verbosity (verbosity-name))
    (:mode (let ((v (or (setting-value head "mode") "")))
             (subseq v 0 (or (position #\space v) (length v)))))
    (:model (%header-model (or (setting-value head "model") "")))
    ((nil) "")))

(defun %keyed-providers (head)
  "The providers this box holds a key for, from the daemon's OWN row (`models.keys`).

**Empty means NO greening rather than every row greened** - letibot's rule for the same row (their
c25c7c8, the rule `daemon_verbs` follows): a row that is not there is a daemon older than the one
that publishes it, and colouring every model on no evidence is a claim a reader cannot check."
  (remove ""
          (mapcar (lambda (s) (string-trim " " s))
                  (uiop:split-string (or (setting-value head "models.keys") "") :separator '(#\,)))
          :test #'string=))

(defun %model-keyed-p (head choice)
  "Does this box hold a key for CHOICE - the operator's question as they press enter.

**`local` is ready for a reason of its own**: it needs no credential, and leaving it uncoloured
would read as *this row has no key* about the one row that never wanted one."
  (let* ((str (or choice ""))
         (provider (if (alexandria:starts-with-subseq "local" str)
                       "local"
                       (subseq str 0 (or (position #\/ str) (length str))))))
    (or (string= provider "local")
        (member provider (%keyed-providers head) :test #'string=))))

(defun %header-model (value)
  "`local (qwen-3.8-27b)` → `qwen-3.8-27b`; anything else as written — the
reference's `header_model`."
  (if (and (alexandria:starts-with-subseq "local (" value)
           (alexandria:ends-with #\) value))
      (subseq value 7 (1- (length value)))
      value))

(defun open-pick (head which)
  "Open the picker for WHICH, seeded on what answers now so enter on an untouched
list is a no-op — the courtesy the reference pays. One list on the screen at a
time: any pane closes."
  (unless (head-settings head) (%send head (make-settings)))
  (setf *pick-open* which
        (head-mode head) :normal
        (head-picker-sel head)
        (or (position (pick-current head which) (pick-choices head which) :test #'string=) 0)
        ;; **THE SEED IS A PROMISE, AND IT CANNOT BE KEPT YET.** The line above is right, and it
        ;; is computed against a list that does not exist the first time — `/mode` asks for the
        ;; settings here and the rows come back a frame later. So the cursor falls to `0`, and
        ;; this flag records that NOBODY HAS CHOSEN IT: the settings arm re-seeds from the real
        ;; list when it arrives, and any key that moves the cursor clears the flag so their own
        ;; choice is never overwritten. See the operator's report — *"mode selectors has selection
        ;; on the first not on the current again"* — in `head.lisp`'s settings arm.
        *pick-unseeded* (null (pick-choices head which))
        (head-dirty head) t))

(defun close-pick (head)
  (setf *pick-open* nil *pick-unseeded* nil (head-dirty head) t))

(defun pick-card-lines (head cols)
  "The picker's card — `mode_picker_lines` row for row: a bold title, each choice
as `▸  1  name` with the cursor's row reversed whole and `← now` at the right of
the one that answers, then the two dim hint rows (three for models)."
  (let* ((models (eq *pick-open* :model))
         (verbosity (eq *pick-open* :verbosity))
         (choices (pick-choices head))
         (current (pick-current head))
         (n (length choices))
         (sel (min (head-picker-sel head) (max 0 (1- n))))
         (w (max 20 cols)))
    (append
     (list (list (cons (cond (models "what answers this conversation")
                             (verbosity "what the transcript shows")
                             (t "the mode this session runs under"))
                       '(:bold t))))
     (unless choices
       (list (list (cons (cond (models "  this daemon has not named its models — `/models PROVIDER/MODEL` still works, if you know the name.")
                             (verbosity "  no rungs to offer — this head starts at normal")
                             (t "  this daemon has not named its modes — `/mode NAME` still works, if you know the name."))
                         '(:dim t)))))
     (loop for name in choices
           for i from 0
           for here = (string= name current)
           for picked = (= i sel)
           append (let* ((left (list (cons (format nil "~a ~2d  " (if picked "▸" " ") (1+ i)) nil)
                                      (cons name (cond ((and models (%model-keyed-p head name))
                                            (if here '(:bold t :fg :green) '(:fg :green)))
                                           (here '(:bold t))
                                           (t nil)))))
                          (right (if here (list (cons "← now" '(:dim t))) nil))
                          ;; the cursor's row is reversed over its TEXT — mark,
                          ;; number, name — and the padding is plain: the
                          ;; reference wraps `left` in REVERSE…RESET before
                          ;; `split_row` pads it. Measured on its raw row.
                          (left (if picked
                                    (mapcar (lambda (seg) (cons (car seg) (append (cdr seg) '(:reverse t))))
                                            left)
                                    left)))
                     (cons (split-row left right w)
                           ;; **WHAT EACH RUNG MEANS, under its own name** (R38): *Terse, Normal,
                           ;; Loud and R37's rung are not self-describing, and a reader is
                           ;; choosing between what will be on their screen.* Drawn as a sub-row
                           ;; in the dim register so the list still reads as a list of CHOICES —
                           ;; the mark, the number and the name are the row, and the sentence is
                           ;; its gloss.
                           (when verbosity
                             (list (list (cons (format nil "       ~a"
                                                       (or (cdr (assoc name +verbosity-said+
                                                                       :test #'string=))
                                                           ""))
                                               '(:dim t))))))))
     (list (list (cons "  ↑↓ moves · enter switches · or type a name or the number on the left · esc closes"
                       '(:dim t)))
           (list (cons (cond (models "  this conversation only, from the next turn; the transcript and the tools are untouched")
                             ;; **THE ONE THING A READER MUST BE TOLD ABOUT THIS CARD** (R38):
                             ;; verbosity applies to the whole transcript at once, because it is
                             ;; read at draw time. A reader who does not know that expects it to
                             ;; apply only to what comes next and concludes it did nothing.
                             (verbosity "  every row above is redrawn — this is a VIEW: nothing leaves the transcript, the ledger or the corpus, and switching back restores every row including the span you were on")
                             (t "  a mode change moves THIS session from its next call, and every later session in this project."))
                       '(:dim t))))
     (when models
       (list (list (cons "  `/default-model NAME` is what new sessions start on · this is not that"
                         '(:dim t)))
             (list (cons "  green: this box holds a key for it; the others need `/models NAME --key PASTE`"
                         '(:dim t)))))
     ;; **and the two typed paths are named, because the card's own hint row promises one of
     ;; them** (*or type a name or the number on the left*) and a reader who wants none of this
     ;; should not have to press esc to find out they could have typed it.
     (when verbosity
       (list (list (cons "  `/verbosity NAME` sets it without the card · esc closes this and changes nothing"
                         '(:dim t))))))))

(defun mode-confirm-lines (cols)
  "The `allow-all` question, wrapped rather than trimmed: this one is read, not
glanced at."
  (when *mode-confirm*
    (mapcar (lambda (l) (mapcar (lambda (seg) (cons (car seg) '(:bold t :fg :yellow))) l))
            (wrap-segments
             (list (cons "allow-all: privilege escalation, deletes outside the project and first contact with a new host all stop asking. On this box that is this box. It lasts for this session only, and a daemon restart drops it.  [y] or [enter] confirm   [esc] or any other key cancels"
                         nil))
             (max 20 cols)))))

(defun %send-mode (head name consented)
  "The mode frame. CONSENTED is a JSON **boolean**, never null.

`Mode.consented` is `consented: bool` with `#[serde(default)]` (protocol.rs:452):
serde's default accepts a MISSING key, not a present `null`. Our encoder writes
NIL as `null`, so `:consented nil` made the daemon's read loop break with an Err
and **close the connection** — every mode but `allow-all` went through that path.
The encoder has `:false` for exactly this, and `t` is the true side."
  (%send head (list :frame "mode"
                    :client-request-id (next-request-id)
                    :expected-seq (session-expected-seq (head-session head))
                    :name name
                    :consented (if consented t :false))))

(defun mode-action (head name)
  "Move the session to mode NAME — `allow-all` asks first (`mode_action`)."
  (if (string= name "allow-all")
      (setf *mode-confirm* name (head-dirty head) t)
      (progn (%send-mode head name nil)
             (say head (format nil "mode → ~a" name)))))

(defun take-pick (head name)
  "The picker's choice NAME, taken: the card closes; a mode already in force is
said and not sent; a model goes as the slash line the operator would have typed
(`take_pick`, `take_mode`)."
  (let ((which *pick-open*))
    (close-pick head)
    (ecase which
      (:mode (if (string= name (pick-current head :mode))
                 (say head "already that mode")
                 (mode-action head name)))
      ;; **R38: it applies to the transcript ALREADY DRAWN, and the card says so.** Verbosity is
      ;; read at DRAW time over the whole conversation, so this is a view change and not a
      ;; setting for what comes next — and the writer is where the render cache is invalidated:
      ;; without that the lines already rendered would be served back out of the cache and the new
      ;; rung would appear to do nothing.
      ;;
      ;; **`%choose-verbosity` and not `set-verbosity`** (the persistence gap): the card is the
      ;; second interactive path to the rung, so it must write the choice down as the verb does.
      (:verbosity (if (string= name (pick-current head :verbosity))
                      (say head (format nil "verbosity is already ~a" name))
                      (let ((note (%choose-verbosity head (verbosity-for-word name))))
                        (say head (format nil "verbosity → ~a — the whole transcript, including everything above this line~@[~a~]"
                                          (verbosity-name) note)))))
      (:model (say head (format nil "switching to ~a…" name))
              (%send-slash head (format nil "models ~a" name))
              (%send head (make-settings))))))

(defun %pick-noun ()
  "What the list on the screen is a list OF, for the sentences that say *no X matches*."
  (ecase *pick-open* (:model "model") (:verbosity "verbosity") (:mode "mode")))

(defun pick-by-text (head typed)
  "What the operator TYPED while the picker was up, at enter — `pick_mode`: the
row's number, an exact name (case, `_` and spaces forgiven), or a unique prefix;
otherwise say why not and keep the card."
  (let* ((choices (pick-choices head))
         (typed (string-trim " " typed)))
    (cond
      ((zerop (length typed)) (close-pick head))
      ((null choices)
       (say head (ecase *pick-open*
                   (:model "this daemon does not send the model list; use `/models PROVIDER/MODEL`")
                   (:verbosity "this head has no rungs to offer, which cannot happen — the ladder is the head's own list")
                   (:mode "this daemon does not send the mode list; use `/mode NAME`"))))
      (t
       (let* ((n (ignore-errors (parse-integer typed)))
              (norm (lambda (s) (substitute #\- #\space (substitute #\- #\_ (string-downcase s)))))
              (want (funcall norm typed))
              (exact (find want choices :key norm :test #'string=))
              (hits (remove-if-not (lambda (c) (alexandria:starts-with-subseq want (funcall norm c)))
                                   choices)))
         (cond
           ((and n (<= 1 n (length choices))) (take-pick head (nth (1- n) choices)))
           (exact (take-pick head exact))
           ((= (length hits) 1) (take-pick head (first hits)))
           ((null hits)
            (say head (format nil "no ~a matches ~s — esc closes the list"
                              (%pick-noun) typed)))
           (t (say head (format nil "~d ~as match ~s; type the number on the left instead"
                                (length hits) (%pick-noun) typed)))))))))

(defun pick-key-event (head key)
  "The picker's own keys — the reference's arm: ↑↓ wrap, enter takes the cursor's
row and a digit takes that row, both only when nothing is typed; esc closes.
Returns T when the key was the picker's; anything else is the composer's, which is
how a name gets typed."
  (let* ((which *pick-open*)
         (type (getf key :type))
         (n (length (pick-choices head)))
         (empty (zerop (length (composer-buffer (head-composer head))))))
    (cond
      ((and (eq type :up) (plusp n))
       (setf (head-picker-sel head) (mod (1- (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :down) (plusp n))
       (setf (head-picker-sel head) (mod (1+ (head-picker-sel head)) n) (head-dirty head) t) t)
      ((and (eq type :enter) empty)
       (if (zerop n)
           (say head (if (eq *pick-open* :model)
                         "this daemon does not send the model list; use `/models PROVIDER/MODEL`"
                         "this daemon does not send the mode list; use `/mode NAME`"))
           (take-pick head (nth (min (head-picker-sel head) (1- n)) (pick-choices head))))
       t)
      ((and (eq type :char) empty (digit-char-p (getf key :ch))
            (<= 1 (digit-char-p (getf key :ch)) n))
       (let ((at (1- (digit-char-p (getf key :ch)))))
         (setf (head-picker-sel head) at)
         (take-pick head (nth at (pick-choices head))))
       t)
      ;; **R38: esc is a REAL ANSWER, and it says so.** *Dismissed leaves the setting alone and
      ;; says nothing was changed.* The other two lists are silent on esc because what they choose
      ;; is the daemon's and the screen behind them has not moved; this one changes what the whole
      ;; transcript looks like, so a reader who pressed esc has to be able to tell that it did not
      ;; happen — the same rule the payload window keeps (*esc closes the view and leaves the fold
      ;; open*), said out loud.
      ((eq type :esc)
       (close-pick head)
       (when (eq which :verbosity)
         (say head (format nil "verbosity left as ~a — nothing was changed"
                           (pick-current head :verbosity))))
       t)
      (t nil))))

(defun mode-confirm-key (head key)
  "The `allow-all` question owns every key while it is up: [y] or [enter] send the
mode with consent; anything else cancels."
  (let ((type (getf key :type)))
    (if (or (eq type :enter)
            (and (eq type :char) (member (getf key :ch) '(#\y #\Y))))
        (let ((name *mode-confirm*))
          (setf *mode-confirm* nil)
          (%send-mode head name t)
          (say head (format nil "mode → ~a (consented)" name)))
        (progn (setf *mode-confirm* nil)
               (say head "allow-all not taken")))
    (setf (head-dirty head) t)
    t))

