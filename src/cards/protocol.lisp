;;;; protocol.lisp — the card protocol: the classes a row's KIND and its TOOL
;;;; select, the generics a card answers (`card-lines`, `card-indent`, `card-verb`,
;;;; `card-body-budget`), and the two factories that build one.
;;;;
;;;; **A card is a VIEW over the wire plist, never the state** (D4) — the item a
;;;; card holds is the plist the daemon sent, untouched.
;;;;
;;;; Split out of `cards.lisp`; see `roles.lisp`'s header for what the split is.

(in-package #:leticl)

;;; ------------------------------------------------------- the card protocol ;;;
;;;
;;; **A card is a VIEW, never the state.** The item stays the wire plist D4 keeps
;;; raw — an eval reading `(getf item :item)` still sees the daemon's own bytes,
;;; never this head's opinion of them — and the card is the object that says how
;;; one KIND of row becomes lines. What the protocol buys over the `case` it
;;; replaces: a new kind arrives as one class and one `card-lines` method instead
;;; of an edit inside a four-hundred-line function, the trailing second `case`
;;; that re-derived the step-in indent from the same type string becomes
;;; `card-indent` beside the lines it measures, and the live card and the settled
;;; row — which the docstrings below record drifting twice (`%outcome-style`,
;;; spelled again in `call-lines` and again in the settled row) — can share one
;;; method instead of agreeing by convention.
;;;
;;; **The additive rule survives the classes.** An unknown body type maps to
;;; `unknown-card`, whose `card-lines` is NIL — exactly what the `case`'s `(t nil)`
;;; drew: a row this head has never met renders nothing rather than erroring, and
;;; the head never has to know the wire's whole vocabulary.

(defclass card ()
  ((item :initarg :item :reader card-item
         :documentation "The wire ITEM, untouched (D4): the plist the daemon sent,
what `tui-eval` reads and what the cache's signature is taken over.")
   (body :initarg :body :reader card-body
         :documentation "`(item-body item)`, held so every method reads one spelling."))
  (:documentation "One transcript row as a rendering: the view over the wire plist."))


(defgeneric card-verb (card &key running)
  (:documentation "The TOOL's word — `Read`/`Reading` — from its class, so the live
card and the settled row cannot spell it differently. The WORDS stay in `*verb-map*`
(exported `verb-label` is the one spelling); this is the card-side door to it. A row
may still state its OWN verb (R24: `:verb` on the body, a compaction's numbers) —
that override is the ROW's, in `%tool-row-verb`, not the tool's."))

(defgeneric card-body-budget (card)
  (:documentation "(FIRST . LAST) body rows a tool's card deserves —
`Budget::for_verb` (card.rs:298-304). Reading wants head and tail, a shell command
lives in its tail, anything else takes the default. The numbers are grok-build's,
kept because they were measured there and not here."))


(defclass unknown-card (card) ())

(defgeneric card-lines (card cols prefs)
  (:documentation "The row as segment lines. NIL is a drawn row that draws
nothing — `unknown-card`, a hidden row, an empty one — which is what `(t nil)`
meant when this was a `case`."))

(defgeneric card-indent (card cols)
  (:documentation "How far the row's lines step in: the model's WORKING sits under
the answer (`activity-indent`), speech at the body's own column. Was the second
`case` on the same type string, one `case` after the first."))

(defmethod card-lines ((card unknown-card) cols prefs)
  nil)

(defmethod card-indent ((card card) cols)
  0)

