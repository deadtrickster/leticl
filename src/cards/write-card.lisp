;;;; write-card.lisp — the WRITE card: the paths a write access opens, as the lines a
;;;; card draws them.
;;;;
;;;; The decision card (panes.lisp) and the edit excerpt both read what is here; a write
;;;; made by the `write` tool and one made by a script the gate read out of a heredoc are
;;;; the SAME FACT, which is why the derivation is one function (#3b in `%write-targets`).

(in-package #:leticl)

(defclass write-card   (tool-result-card) ())

(defun %write-targets (d)
  "The paths a decision's action OPENS FOR WRITING, as a list of
`(:path STRING :unresolved BOOLEAN)`, or NIL when it opens none.

**The one place the two mechanisms meet** (R35), which is the whole of why this function exists:
a write made through the `write`/`edit` tool and a write made by a script the gate read out of a
heredoc body are the SAME FACT — *this action writes this file* — and a card that drew them from
two code paths would drift into two shapes for one fact. The operator's requirement is that a
reader comparing two cards must not have to know which mechanism produced them, so both arrive
here and are drawn once.

    · **the daemon's own field**, when it sends one: `write_targets`, an array of
      `{path, unresolved}`, on the same frame that carries `access` and `target`. That is the
      ask filed for it (R35's wire); until it arrives this branch is never taken, which is the
      same *inert without the row* shape R32's argument-kind has.
    · **the edit tool's own `target`**, which is already on the wire and already a path: when the
      action's declared `access` is `write` and the field is absent, the single `target` IS the
      write target. This is what makes today's edit card and the coming heredoc card one shape.

**An `unresolved` entry is NOT an absent one**, and the difference is the requirement's own
sentence: *a write whose target could not be read* is exactly the case the operator most needs to
see — `open(sys.argv[1], 'w')`, a path built from `pathlib.Path.home()`. A head that folded it
into *no write* would be throwing away the one fact a person cannot get any other way.

**A `write` access with no target and no field is NIL, not an empty entry.** That is a real case
(a tool that declares a write and names nothing) and it draws nothing, which is what every
daemon draws today."
  (let ((field (getf d :write-targets)))
    (cond
      (field
       (loop for w in field
             ;; the field is the daemon's, so its shape is read defensively: an entry that is
             ;; not an object, or one with neither a path nor the unresolved mark, is not a
             ;; target and is dropped rather than drawn as a blank row
             when (and (consp w)
                       (or (and (stringp (getf w :path)) (plusp (length (getf w :path))))
                           (getf w :unresolved)))
               collect (list :path (or (getf w :path) "")
                             :unresolved (and (getf w :unresolved) t))))
      ;; the edit tool's target, which is already a path on the wire
      ((and (equal (getf d :access) "write")
            (stringp (getf d :target))
            (plusp (length (getf d :target))))
       (list (list :path (getf d :target) :unresolved nil))))))

(defun write-target-lines (targets cols)
  "TARGETS (from `%write-targets`) as card lines, in the card's own target register.

**One drawing for both mechanisms**, at the place and in the style the single `target` has always
had — indented four, bold (see `permission-card-lines`, where *a command is the one thing here
worth the rows*). The first resolved path therefore renders BYTE FOR BYTE as today's edit card
renders its target, which is the operator's requirement made checkable rather than asserted.

**The count is said on the line that names them, and that is R25's rule at this surface.** The
paths themselves are content and elide to the card's viewport like any other content — the
viewport's seam counts rows, not files — so the number of FILES goes where no elision can reach
it: above them, as `N files:`, and only when there is more than one. A single write is unchanged,
which is why the edit card does not grow a header.

**An unresolved write is drawn in `+role-attention+`** — *somebody has to look* — and never in
the path register. The requirement's words: it is *the one the operator most needs to see*, and a
sentence that looks like a path is a sentence that gets skimmed past. The same role a tool row's
own `no result` takes, for the same reason: it is the row whose whole meaning is *this is not what
you think it is*.

**The count of unresolved writes is in the sentence**, not in a header of its own: one such write
says *a write whose target could not be read* and two say *2 writes whose targets could not be
read*, which is a number a reader cannot misplace."
  (let ((w (max 20 cols))
        (out nil)
        (resolved (remove-if (lambda (x) (getf x :unresolved)) targets))
        (unresolved (remove-if-not (lambda (x) (getf x :unresolved)) targets)))
    ;; the count, above the names, so a window cannot hide it
    (when (> (length resolved) 1)
      (push (list (cons (format nil "    ~d files:" (length resolved)) '(:dim t))) out))
    (dolist (x resolved)
      (dolist (l (wrap-text (format nil "    ~a" (getf x :path)) w))
        (push (list (cons l '(:bold t))) out)))
    ;; **and the unresolved ones say what they are.** One sentence, in the attention register,
    ;; with its own count when there is more than one.
    (when unresolved
      (dolist (l (wrap-text (if (= 1 (length unresolved))
                                "    ✎ a write whose target could not be read — the script builds it at runtime, so the gate cannot name the file"
                                (format nil "    ✎ ~d writes whose targets could not be read — the script builds them at runtime, so the gate cannot name the files"
                                        (length unresolved)))
                            w))
        (push (list (cons l +role-attention+)) out)))
    (nreverse out)))

