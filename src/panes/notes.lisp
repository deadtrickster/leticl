;;;; notes.lisp — the /notes listing: the warnings the session has filed
;;;;
;;;; Split out of `panes.lisp`, which was one 3,578-line file holding every
;;;; full-body screen; the ranges are consecutive, so every reference kept its
;;;; direction. The protocol the screens answer through is `pane-protocol.lisp`.


;;;; **The `*.rs:NNNN` citations here are to the reference as of 2026-10-08**, before its widget
;;;; files moved into the `rano` crate — a reading, not a path that can be followed. See HACKING.md,
;;;; "What a Rust citation means", for how to re-check one.

(in-package #:leticl)

;;; ------------------------------------------------------------- the notes ;;;
;;;
;;; R10's reader: what this head has warned about, and how to retire one. The listing
;;; is a slash listing — content that arrived, read from the top — so it is
;;; `*slash-out*` and `:slash`, not a pane of its own.

(defun warning-listing-lines (session)
  "The `/notes` listing: every warning this head holds, in the order the conversation
has them, numbered for `/notes dismiss N`.

**The whole text, not the fold.** A listing that hid the tail of the very thing it
exists to make findable would be the defect it is the answer to; the reference
renders it with the transcript's own unfolded renderer for the same reason
(app.rs:5860-5864). Lines come back UNWRAPPED — the slash pane wraps at its own
width, and wrapping here as well would wrap twice."
  (let* ((ws (warning-order session))
         (held (length ws))
         (retired (count-if (lambda (w) (session-retired-p session w)) ws))
         (out (if (zerop held)
                  (list "this head holds no warnings. A warning is the daemon's own \
sentence about this session — a compaction, a context wall, an interrupted turn — and \
the session log holds it whether or not this head is showing it.")
                  (list (format nil "~d warning~a, ~d retired — the log holds the durable \
fact and this head shows it once"
                                held (if (= held 1) "" "s") retired)))))
    (loop for w in ws
          for i from 1
          do (push (format nil "~3d  ~a" i
                           (if (session-retired-p session w) "[retired]" ""))
                   out)
             (push (format nil "~a ~a" (warning-glyph w) (warning-note-text w)) out))
    (when (plusp held)
      (push "" out)
      (push "/notes dismiss [N|all] retires one, or every one · /notes restore brings them all back"
            out))
    (nreverse out)))

(defun open-notes-listing (session)
  "Open the `/notes` listing in the slash pane. T when there is a listing.

Fills `*slash-out*` and does NOT touch the mode: the mode is head state, and the one
thing the head has to do with what arrived here is the same thing it does with a
listing the daemon sent — follow the state after the fold (`head.lisp:495-497`)."
  (setf *slash-out* (cons "/notes" (warning-listing-lines session)))
  (reset-pane-scroll)
  t)

(defun notes-listing-open-p ()
  "Is the listing on the screen the NOTES one? Used to decide whether a retirement
should redraw it: a daemon slash reply that happens to be up is not this head's to
replace."
  (and (consp *slash-out*) (equal (car *slash-out*) "/notes")))

(defun standing-notes-lines (head cols)
  "The STANDING notes — what the harness is reading into this session's prompt right now, one row
per note, and the rows the `:standing` pane will draw (landed ahead of the pane, as
`merge-queue-lines` was, so the pane is registration rather than a pile of drawing).

**THE FIELDS ARE THE DAEMON'S, MEASURED 2026-10-11** (`sessionlog/src/protocol.rs:1352`,
`NoteEntry`): `path` (the file as the index names it — *the absolute path the section's heading
carries, so a `read` of it and this row are the same file*), `abstract` (the index's line for the
note, ABSENT for a file that is nothing but headings), `abstract_written` (true when that line is
the author's own `<!-- abstract: … -->`, false when the harness derived it from the first
sentence), and `form` (verbatim or indexed — *what fits what is left of the budget is injected
verbatim; what does not arrives indexed*).

**AND `abstract_written` IS DRAWN, which is the field's own reason**: *a derived abstract is the
harness's reading of a note, and a reader who cannot tell it from the author's is taking a guess
for a statement.* So the row says which it is rather than showing the line bare.

COLS is accepted and unused for now: the row's own truncation belongs to the pane's drawing, and a
renderer that wrapped here would wrap twice."
  (declare (ignore cols))
  ;; **`let*` AND NOT `let`**: the heading's initialiser READS `notes`, and a parallel `let` binds
  ;; the name only for the body — MEASURED on this function's first run as `UNBOUND-VARIABLE NOTES`.
  (let* ((notes (head-standing-notes head))
         ;; **THE CURSOR'S ROW IS DRAWN**, because Enter acts on it now (sweep 2026-10-11, B.5): a
         ;; pane whose cursor walks rows nobody can see is a selection the operator cannot make.
         ;; Clamped the way every pane clamps when it draws, so a list that shrank under the
         ;; cursor still marks a real row.
         (sel (if notes (min (max 0 (head-picker-sel head)) (1- (length notes))) 0))
         (out (list (list (cons "standing notes" '(:bold t))
                         (cons (format nil "  ~d" (length (or notes nil))) '(:dim t))))))
    (push nil out)
    (if (null notes)
        (push (list (cons "    none — the harness is reading no notes into this session" '(:dim t))) out)
        (loop for n in notes
              for i from 0
              do
          (let ((path (or (getf n :path) "?"))
                (abstract (getf n :abstract))
                (written (getf n :abstract-written))
                (form (or (getf n :form) "?"))
                (here (= i sel)))
            (push (list (cons "  ▸ " (if here '(:bold t) '(:dim t)))
                        (cons path (and here '(:reverse t)))
                        (cons (format nil "  [~a]" form)
                              (if (string-equal form "verbatim") +role-success+ +role-pending+)))
                  out)
            (push (list (cons "         " '(:dim t))
                        (cond ((null abstract)
                               (cons "no abstract — nothing but headings" '(:dim t)))
                              (written (cons (format nil "~a" abstract) nil))
                              (t (cons (format nil "~a" abstract) '(:dim t)))))
                  out)
            ;; **AND IT SAYS WHICH KIND OF LINE IT IS**, because the difference is a fact about
            ;; authority: the author's words, or the harness's reading of them.
            (push (list (cons (format nil "         ~a"
                                      (cond ((null abstract) "")
                                            (written "— the author's own abstract")
                                            (t "— derived by the harness from the first sentence")))
                              '(:dim t)))
                  out))))
    (push nil out)
    (push (list (cons "    asked when this pane opens, as ListJobs is — a list is a question, not an act"
                      '(:dim t)))
          out)
    (when notes
      (push (list (cons "    ↑↓ moves · enter opens the row whole · esc returns to the list"
                        '(:dim t)))
            out))
    (nreverse out)))

(defun standing-note-whole-lines (note cols)
  "ONE standing note, whole — the read overlay's body (sweep 2026-10-11, B.5).

The reference opens the note's FILE in rano; this head embeds no editor (TODO.md, section C), so
what it can show whole is **what the daemon sent about the note**: the path, the form, and the
abstract unwrapped and untruncated — the row's own truncation is the pane's, and this is the
view that has none. The abstract's authority is said in the same words the row uses, because the
difference between the author's line and the harness's reading of it is the fact this field
exists for."
  (let* ((w (max 20 cols))
         (path (or (getf note :path) "?"))
         (abstract (getf note :abstract))
         (written (getf note :abstract-written))
         (form (or (getf note :form) "?")))
    (append
     (list (list (cons "  path  " '(:dim t)) (cons path nil))
           (list (cons "  form  " '(:dim t))
                 (cons form (if (string-equal form "verbatim") +role-success+ +role-pending+))
                 (cons (if (string-equal form "verbatim")
                           "  — injected into the prompt as written"
                           "  — an index entry; the model reads the file when it needs it")
                       '(:dim t)))
           nil)
     (cond ((null abstract)
            (list (list (cons "  no abstract — the file is nothing but headings" '(:dim t)))))
           (t (append
               (mapcar (lambda (l) (list (cons (format nil "  ~a" l) nil)))
                       (wrap-text abstract (max 8 (- w 2))))
               (list nil
                     (list (cons (if written
                                     "  — the author's own abstract"
                                     "  — derived by the harness from the first sentence")
                                 '(:dim t))))))))))
