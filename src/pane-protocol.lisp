;;;; pane-protocol.lisp — the PANE protocol: one class per full-body screen, and the
;;;; generics the rest of the head asks it through.
;;;;
;;;; **Why this exists.** A pane used to be a keyword dispatched through a `case` in
;;;; each of several files: the frame's lines and total (`render.lisp`), the cursor's
;;;; row count and what Enter does (`editor.lisp`), where Esc goes and where the
;;;; cursor opens (`panes.lisp`), the hint bar's tail (`chrome.lisp`). Adding a pane
;;;; meant remembering all of them, and the copies had already drifted: the hint bar
;;;; carried a second, DEAD `:jobs` arm, and the dashboard's `case` arm returned a
;;;; vector where a line number was wanted (`render failed — the head is alive`,
;;;; MEASURED). One class per pane and one generic per question is the same fix the
;;;; cards got, for the same reason.
;;;;
;;;; **What is deliberately NOT here: the key map.** `%pane-key` (`editor.lisp`) is
;;;; ONE key map, not twelve: the panes share one cursor (`head-picker-sel`), one
;;;; scroll offset, one Esc, and the page/wheel/arrow handling is genuinely common —
;;;; its arms differ by a handful of mode tests, not by pane. Twelve `pane-key`
;;;; methods would be twelve copies of the same movement code. So the facts a key
;;;; NEEDS are per pane and live here (`pane-row-count`, `pane-escape-target`), and
;;;; the map that reads them stays one function.
;;;;
;;;; **A pane holds no state.** Everything a pane draws comes from the head or from a
;;;; global, exactly as the functions it delegates to always did; the instances below
;;;; are singletons because the dispatch needs an object and nothing else.

(in-package #:leticl)

;;; ------------------------------------------------------------- the classes ;;;

(defclass pane ()
  ((mode :initarg :mode :reader pane-mode))
  (:documentation "One full-body screen. The mode keyword IS the pane's identity —
the head stores the keyword (a struct slot, and a slot change is a RESTART), and
`pane-for` is the one place that keyword becomes a class."))

(defclass conversation-pane (pane) ()
  (:documentation "`:normal` — the transcript, and the answer for a mode nobody
registered. It replaces nothing and draws nothing of its own: the frame falls
through to the conversation, which is what the old `member` test's absence meant."))

(defclass help-pane        (pane) ())
(defclass status-pane      (pane) ())
(defclass config-pane      (pane) ())
(defclass jobs-pane        (pane) ())
(defclass subagents-pane   (pane) ())
(defclass peek-pane        (pane) ())
(defclass job-out-pane     (pane) ())
(defclass picker-pane      (pane) ())
(defclass todos-pane       (pane) ())
(defclass slash-pane       (pane) ())
(defclass dash-pane        (pane) ())
(defclass lisp-pane        (pane) ())

;;; ------------------------------------------------------------ the registry ;;;
;;;
;;; **One alist, and it is the list of panes.** The old dispatch kept the same
;;; twelve keywords in four files; a pane that is missing here has no lines, no
;;; cursor, no Esc and no hint, which is the honest answer for a mode nobody
;;; registered and the reason the fallback is `conversation-pane` rather than an
;;; error.

(defparameter *pane-classes*
  '((:help . help-pane)
    (:status . status-pane)
    (:config . config-pane)
    (:jobs . jobs-pane)
    (:subagents . subagents-pane)
    (:peek . peek-pane)
    (:job-out . job-out-pane)
    (:picker . picker-pane)
    (:todos . todos-pane)
    (:slash . slash-pane)
    (:dash . dash-pane)
    (:lisp . lisp-pane))
  "The full-body screens, by the mode keyword that opens them.")

(defvar *panes* nil
  "The one instance per pane class, made on first ask.

 A `defvar` rather than a `defparameter`, for the reason every live table here is: a
 push of this file must not drop a running head's instances into a fresh list. They
 hold nothing but their mode, so rebuilding them would be harmless — which is
 exactly why the rule is worth keeping rather than arguing about.")

(defun pane-for (mode)
  "The pane MODE names, or `conversation-pane` — the fallback that replaces nothing.

 **An unknown mode is not an error and never was**: the old tests were `member`
 against a list, so a keyword nobody knew fell through to the conversation. That
 direction is kept deliberately — a new mode arrives with a class, and until it does
 the frame draws the transcript rather than a blank screen or a condition.”"
  (let ((class (cdr (assoc mode *pane-classes* :test #'eq))))
    (if (null class)
        (or (getf *panes* :normal)
            (setf (getf *panes* :normal) (make-instance 'conversation-pane :mode :normal)))
        (or (getf *panes* mode)
            (setf (getf *panes* mode) (make-instance class :mode mode))))))

(defun current-pane (head)
  "The pane the head is showing. One line, so no caller has to remember `pane-for`."
  (pane-for (head-mode head)))

;;; ------------------------------------------------------------- the protocol ;;;

(defgeneric pane-lines (pane head cols room)
  (:documentation "The pane's lines, and as a second value the LINE its cursor is on
(or NIL when it has no cursor).

**The second value is a LINE and not a row**, and that contract has a measurement
behind it: the frame feeds this into `scroll-pane-into-view`, and `:dash` once
returned a vector of panel starts as its second value, which died as
`#(2 9) is not of type REAL` — *render failed — the head is alive*. A pane with
something else to say returns ONE value."))

(defgeneric pane-total (pane head lines)
  (:documentation "How many lines the scroll clamps against.

The default is what the pane DREW; the two tail windows (`:peek`, `:job-out`) answer
the daemon's own total instead, because what they drew is a window into it — and the
count is what the keys clamp against, so the two cannot be the same number."))

(defgeneric pane-replaces-transcript-p (pane)
  (:documentation "Does this pane draw INSTEAD of the conversation? Every registered
pane does; `conversation-pane` does not, which is the whole of the fallback."))

(defgeneric pane-self-windows-p (pane)
  (:documentation "Does the pane window ITSELF, tail-first?

`:peek` and `:job-out` do, because the tail is where a subagent's answer and a
running job's newest bytes are, and the clamp needs the frame's height — so the
frame must hand them the room and NOT window them a second time."))

(defgeneric pane-enter (pane head)
  (:documentation "What Enter does in this pane: T when the pane took it.

The arms of the old `%pane-enter` `case`, one method each — the only key whose
behaviour was never shared: each pane's Enter is its own act. The shared tail (mark
the head dirty) stayed in the door, because it was shared."))

(defgeneric pane-cursor-rows (pane head)
  (:documentation "How many ROWS the cursor has to walk — one answer, read by the
arrow keys and by the click conversion alike, so the two cannot disagree about what
the last row is. 0 means *this pane has no cursor* (see the REPL's own method),
which is why the base method answers 0 rather than being absent.

Named `pane-cursor-rows` and not `pane-row-count` because that name is the DOOR the
key map calls (`pane-row-count head mode`, `editor.lisp`) — the door asks this."))

(defgeneric pane-opens-at (pane head)
  (:documentation "Where the cursor belongs the moment the pane opens. The top, for
every pane but the session picker — one cursor is shared, so a position left by the
last pane means nothing to the next. The door keeps the old name
(`pane-initial-sel head mode`)."))

(defgeneric pane-esc-target (pane)
  (:documentation "The mode Esc goes to from this pane. `:normal` unless the pane is
an OVERLAY over another list, where the list never closed and Esc means back. The
door keeps the old name (`pane-escape-target mode`)."))

(defgeneric pane-hint (pane head)
  (:documentation "The hint bar's tail for this pane, or NIL when it has no words of
its own. The bar keeps its order around these — the quit prompt and the secret card
outrank any pane's hint."))

;;; ------------------------------------------------------------ the fallbacks ;;;
;;;
;;; Each base method below is the arm the old `case`/`cond` fell through to, kept
;;; verbatim so that a pane nobody has written yet behaves exactly as it did.

(defmethod pane-lines ((pane pane) head cols room)
  (declare (ignore head cols room))
  nil)

(defmethod pane-total ((pane pane) head lines)
  (declare (ignore head))
  (length lines))

(defmethod pane-replaces-transcript-p ((pane pane)) nil)
(defmethod pane-self-windows-p ((pane pane)) nil)
(defmethod pane-cursor-rows ((pane pane) head) (declare (ignore head)) 0)
(defmethod pane-opens-at ((pane pane) head) (declare (ignore head)) 0)
(defmethod pane-esc-target ((pane pane)) :normal)
(defmethod pane-hint ((pane pane) head) (declare (ignore head)) nil)
(defmethod pane-enter ((pane pane) head) (declare (ignore head)) nil)

;;; ------------------------------------------------------- lines, per pane ;;;

(defmethod pane-lines ((pane help-pane) head cols room)
  (declare (ignore head room))
  (help-lines cols))

(defmethod pane-lines ((pane status-pane) head cols room)
  (declare (ignore room))
  (status-screen-lines head cols))

(defmethod pane-lines ((pane config-pane) head cols room)
  (declare (ignore room))
  (config-lines head (head-settings head) cols))

(defmethod pane-lines ((pane jobs-pane) head cols room)
  (declare (ignore room))
  (jobs-lines head cols))

(defmethod pane-lines ((pane subagents-pane) head cols room)
  (declare (ignore room))
  (subagent-lines head cols))

(defmethod pane-lines ((pane peek-pane) head cols room)
  (peek-lines head cols room))

(defmethod pane-lines ((pane job-out-pane) head cols room)
  (job-out-lines head cols room))

(defmethod pane-lines ((pane picker-pane) head cols room)
  (declare (ignore room))
  (picker-lines (head-session head) (head-picker-sel head) cols))

(defmethod pane-lines ((pane todos-pane) head cols room)
  (declare (ignore room))
  (todos-lines head cols))

(defmethod pane-lines ((pane slash-pane) head cols room)
  (slash-out-lines head cols room))

(defmethod pane-lines ((pane lisp-pane) head cols room)
  (declare (ignore room))
  ;; the REPL's second value is NIL on purpose — ↑↓ walk the forms you evaluated, so
  ;; a cursor here would be a second meaning for one key (`lisp-pane-lines` says so).
  (lisp-pane-lines head cols))

(defmethod pane-lines ((pane dash-pane) head cols room)
  (declare (ignore head room))
  ;; **ONE VALUE, and that is a requirement rather than a style** — the frame's
  ;; `multiple-value-setq` would take the panel-starts vector as a cursor LINE.
  (values (dash-frame-lines cols :nav *dash-nav*)))

;;; ------------------------------------------------------- totals, per pane ;;;

(defmethod pane-total ((pane peek-pane) head lines)
  (declare (ignore head lines))
  *peek-total*)

(defmethod pane-total ((pane job-out-pane) head lines)
  (declare (ignore head lines))
  *job-out-total*)

;;; ------------------------------------------------------- the frame's questions ;;;

(dolist (class '(help-pane status-pane config-pane jobs-pane subagents-pane peek-pane
                 job-out-pane picker-pane todos-pane slash-pane dash-pane lisp-pane))
  (eval `(defmethod pane-replaces-transcript-p ((pane ,class)) t)))

(defmethod pane-self-windows-p ((pane peek-pane)) t)
(defmethod pane-self-windows-p ((pane job-out-pane)) t)

;;; ----------------------------------------------------------- the cursor ;;;

(defmethod pane-cursor-rows ((pane subagents-pane) head) (length (subagent-rows head)))
(defmethod pane-cursor-rows ((pane jobs-pane) head) (length (head-jobs head)))
(defmethod pane-cursor-rows ((pane todos-pane) head)
  (length (repo-todo-rows-cached
           (getf (session-wiring (head-session head)) :workspace))))
(defmethod pane-cursor-rows ((pane picker-pane) head)
  (length (picker-sessions (head-session head))))
(defmethod pane-cursor-rows ((pane config-pane) head) (length (config-rows head)))
;; the peek pane's rows are its BODY lines, and answering 0 was the whole of its arrow
;; keys: `move-cursor` clamped to `(1- 0)` while the pane's own last line advertised
;; that they scroll
(defmethod pane-cursor-rows ((pane peek-pane) head) (peek-row-count head))
(defmethod pane-cursor-rows ((pane job-out-pane) head) (job-out-row-count head))
;; **THE REPL HAS NO CURSOR, and this line is a CLAIM rather than a default** (the old
;; `case` said the same): ↑↓ are the composer's history here, so a count that answered
;; anything else would let `move-cursor` walk a selection nobody can see. Written out
;; rather than left to the base method so that a later edit cannot quietly make it
;; selectable.
(defmethod pane-cursor-rows ((pane lisp-pane) head) (declare (ignore head)) 0)

(defmethod pane-opens-at ((pane picker-pane) head) (picker-initial-sel head))

(defmethod pane-esc-target ((pane peek-pane)) :subagents)
(defmethod pane-esc-target ((pane job-out-pane)) :jobs)

;;; ------------------------------------------------------------- the hint bar ;;;
;;;
;;; The strings moved here from `chrome.lisp`'s `cond`, unchanged — including the
;;; `:jobs` arm that asked the PANELS whether `d` would do anything, because a hint
;;; that offers a key which does nothing on this row is worse than a shorter hint.
;;;
;;; **A second, DEAD `:jobs` arm is not carried over.** The old `cond` had one at
;;; `chrome.lisp:1415` reading *"background jobs this session started · …"*, and the
;;; arm above it matched `:jobs` first, so it had never been drawn. Same words, same
;;; place, one arm.

(defmethod pane-hint ((pane help-pane) head) (declare (ignore head)) "esc closes this")
(defmethod pane-hint ((pane status-pane) head) (declare (ignore head)) "esc closes this")

(defmethod pane-hint ((pane slash-pane) head)
  (declare (ignore head))
  "↑↓ and the wheel scroll · esc closes")

(defmethod pane-hint ((pane picker-pane) head)
  (declare (ignore head))
  "type a number to switch · /new [title] · esc closes")

(defmethod pane-hint ((pane todos-pane) head)
  (declare (ignore head))
  "↑↓ moves · enter or tab unfolds · pgup/pgdn and the wheel scroll · esc closes")

;; the dashboard's hint is GENERATED FROM ITS OWN BINDING TABLE (dash.lisp), so a pane
;; that offers a key it does not have cannot describe itself that way — serenedash's
;; rule, and the same reason the key bar there is built from `BINDINGS` rather than typed
(defmethod pane-hint ((pane dash-pane) head)
  (declare (ignore head))
  (format nil "~a · esc closes" (dash-bindings)))

(defmethod pane-hint ((pane config-pane) head)
  (declare (ignore head))
  "arrows move · enter changes a row marked ✎ · esc closes")

(defmethod pane-hint ((pane subagents-pane) head)
  (declare (ignore head))
  "subagents this session spawned · enter reads one (live) · p its prompt · o attaches to it · esc closes")

(defmethod pane-hint ((pane jobs-pane) head)
  (if (dash-panel-for-job (nth (head-picker-sel head) (head-jobs head)))
      "↑↓ moves · enter reads the output · d opens its dashboard · esc closes"
      "↑↓ moves · enter reads the output · esc closes"))

;; enter IS the pane here, so the hint names it — and it names the arrows as the
;; COMPOSER's, which is what they are (`%pane-key` refuses them for `:lisp` so they walk
;; the forms you evaluated). A hint bar that called them "scroll" would be teaching a
;; key this pane does not have.
(defmethod pane-hint ((pane lisp-pane) head)
  (declare (ignore head))
  "enter evaluates the prompt · ↑↓ walks the forms you evaluated · pgup/pgdn scrolls · esc closes")

(defmethod pane-hint ((pane peek-pane) head)
  (declare (ignore head))
  "tails live · arrows scroll · esc back")

(defmethod pane-hint ((pane job-out-pane) head)
  (declare (ignore head))
  ;; ESC BACK TO JOBS, not "closes": the jobs list never closed under it, and a bottom
  ;; row that says `esc closes` on a pane that goes back one level teaches the wrong
  ;; thing about the key (app.rs:5424). **And the PAGE keys are named only where they
  ;; act** (R41), through `job-out-pages` — the same function the pane's own footer
  ;; uses. Two plain conditionals and not two `~@[ … ~]`: measured on this SBCL,
  ;; `(format nil "|~@[A~]~@[B~]|" 1 nil)` answers `"|AB|"`, so the compressed spelling
  ;; would promise the very keys this exists to drop.
  (let ((pages (job-out-pages)))
    (format nil "↑↓ scroll~a~a · enter re-reads · esc back to jobs"
            (if (getf pages :next) " · → next page" "")
            (if (getf pages :back) " · ← back" ""))))
